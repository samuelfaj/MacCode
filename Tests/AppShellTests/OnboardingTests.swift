import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence
import Surfaces

@MainActor
final class OnboardingTests: XCTestCase {
    private final class Accounts: DistillAccountManaging, @unchecked Sendable {
        var statusesValue: [DistillAccountStatus] = []
        var routing = DistillAutoRouting()
        var saveFails = false
        func statuses() -> [DistillAccountStatus] { statusesValue }
        func loadState() async throws -> DistillAccountsState { .init(accounts: statusesValue, routing: routing) }
        func add(id: String, provider: DistillAccountProvider, label: String) async throws {}
        func rename(id: String, label: String) async throws {}
        func remove(id: String) async throws {}
        func login(id: String, onURL: @escaping @Sendable (URL) -> Void) async throws {}
        func logout(id: String) async throws {}
        func refreshUsage(id: String) async throws -> DistillAccountQuota { throw DistillAccountError.failed("n/a") }
        func saveRouting(_ routing: DistillAutoRouting) async throws {
            if saveFails { throw DistillAccountError.failed("disk full") }
            self.routing = routing
        }
    }

    private final class Services: OnboardingServices {
        let accountsController: DistillAccountsController
        var models: [AgentModelDescriptor] = []
        var user: PrivateAccountUser?
        var signInError: Error?
        var workspaces: Set<WorkspaceID> = []
        var bots: Set<BotID> = []
        var openCalls = 0
        var createCalls = 0
        var failCreate = false
        var handOffs: [(WorkspaceID, BotID?, String)] = []
        var bindings: [(BotID, WorkspaceID)] = []

        init(accounts: Accounts) {
            accountsController = DistillAccountsController(accounts: accounts, installer: { "/tmp/distill" }, resolveBinary: { "/tmp/distill" })
        }
        func loadModels() async -> [AgentModelDescriptor] { models }
        func signIn(email: String, password: String) async throws -> PrivateAccountUser {
            if let signInError { throw signInError }
            return user!
        }
        func register(email: String, password: String) async throws -> PrivateAccountUser { try await signIn(email: email, password: password) }
        func signedInUser() -> PrivateAccountUser? { nil }
        func workspaceExists(_ id: WorkspaceID) -> Bool { workspaces.contains(id) }
        func botExists(_ id: BotID) -> Bool { bots.contains(id) }
        func openWorkspace(folder: URL) throws -> WorkspaceID {
            openCalls += 1
            let id = WorkspaceID()
            workspaces.insert(id)
            return id
        }
        func createDeveloper(name: String, workspace: WorkspaceID) throws -> BotID {
            createCalls += 1
            if failCreate { throw DistillAccountError.failed("bot store locked") }
            let id = BotID()
            bots.insert(id)
            return id
        }
        func bindDeveloper(_ bot: BotID, workspace: WorkspaceID) throws { bindings.append((bot, workspace)) }
        func handOff(workspace: WorkspaceID, developer: BotID?, prompt: String) { handOffs.append((workspace, developer, prompt)) }
        var opened: [URL] = []
        func openInBrowser(_ url: URL) { opened.append(url) }
    }

    private func makeStore() throws -> OnboardingStateStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.path).run()
        return OnboardingStateStore(repo: SettingsRepository(db: db))
    }

    private func model(_ id: String, _ provider: DistillAccountProvider) -> AgentModelDescriptor {
        AgentModelDescriptor(id: id, label: id, provider: .distill, accountProvider: provider.rawValue)
    }

    // Upgrading users must never be dropped into a first-run window; only an
    // install with no projects and no account is new.
    func test_launchShowsSetupOnlyForNewInstalls() {
        XCTAssertTrue(OnboardingGate.launchDecision(saved: nil, hasWorkspaces: false, hasAccountSession: false).present)
        let upgraded = OnboardingGate.launchDecision(saved: nil, hasWorkspaces: true, hasAccountSession: false)
        XCTAssertFalse(upgraded.present)
        XCTAssertEqual(upgraded.stateToSave?.status, .existingUser)
        XCTAssertFalse(OnboardingGate.launchDecision(saved: nil, hasWorkspaces: false, hasAccountSession: true).present)
        var dismissed = OnboardingState(); dismissed.status = .dismissed
        XCTAssertFalse(OnboardingGate.launchDecision(saved: dismissed, hasWorkspaces: false, hasAccountSession: false).present,
                       "Closing setup must stop it from reappearing at every launch")
    }

    // A deferred step is not a success: it must stay distinguishable so the
    // app can offer it again instead of claiming it is configured.
    func test_skipIsRecordedAsSkippedAndNeverAsCompleted() throws {
        let services = Services(accounts: Accounts())
        let store = try makeStore()
        let vm = OnboardingViewModel(services: services, store: store, initial: OnboardingState())
        vm.skip(.account)
        XCTAssertEqual(vm.state.step, .jev)
        XCTAssertTrue(vm.state.skippedSteps.contains(.account))
        XCTAssertFalse(vm.state.completedSteps.contains(.account))
        XCTAssertEqual(store.load(), vm.state, "Progress survives a relaunch")
    }

    // Users cannot jump past an undecided step via the stepper.
    func test_stepperCannotSkipAheadOfUndecidedSteps() throws {
        let vm = OnboardingViewModel(services: Services(accounts: Accounts()), store: try makeStore(), initial: OnboardingState())
        vm.jump(to: .workspace)
        XCTAssertEqual(vm.state.step, .account)
    }

    func test_failedSignInStaysOnStepWithActionableMessage() async throws {
        let services = Services(accounts: Accounts())
        services.signInError = PrivateAccountAPIError.http(401)
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: OnboardingState())
        vm.email = "dev@example.com"; vm.password = "correct-horse"
        await vm.submitAccount()
        XCTAssertEqual(vm.state.step, .account)
        XCTAssertEqual(vm.accountError, "Email or password is incorrect.")
        XCTAssertEqual(vm.password, "correct-horse", "Keep the password for a retry")
    }

    func test_registerConflictPointsToSignIn() {
        XCTAssertEqual(OnboardingViewModel.accountErrorMessage(PrivateAccountAPIError.http(409), creating: true),
                       "An account with this email already exists. Sign in instead.")
    }

    // Auto must only contain accounts that are connected and models the live
    // catalog offers; OpenRouter bills API usage, so it is never added
    // implicitly.
    func test_recommendedRoutingUsesOnlyConnectedSubscriptionsInProviderOrder() {
        let accounts = [
            DistillAccountStatus(provider: .grok, connected: true),
            DistillAccountStatus(provider: .claude, connected: false),
            DistillAccountStatus(provider: .openrouter, connected: true),
            DistillAccountStatus(provider: .chatgpt, connected: true),
        ]
        let models = [model("grok-5", .grok), model("gpt-6", .chatgpt), model("sonnet", .claude), model("or-x", .openrouter)]
        let routing = OnboardingViewModel.recommendedRouting(accounts: accounts, models: models, strategy: .orderedFirst)
        XCTAssertTrue(routing.enabled)
        XCTAssertEqual(routing.options.map(\.mainModel), ["gpt-6", "grok-5"])
        XCTAssertNil(DistillRoutingValidation_errorFor(routing, accounts: accounts, models: models))
    }

    func test_recommendedRoutingIsDisabledWithoutAnyUsableAccount() {
        let routing = OnboardingViewModel.recommendedRouting(
            accounts: [DistillAccountStatus(provider: .chatgpt, connected: true)], models: [], strategy: .orderedFirst)
        XCTAssertFalse(routing.enabled, "No catalog model means Auto cannot be offered as ready")
        XCTAssertTrue(routing.options.isEmpty)
    }

    // A failed save must leave the user on the step with the shared profile untouched.
    func test_failedAutoSaveDoesNotAdvance() async throws {
        let accounts = Accounts()
        accounts.statusesValue = [DistillAccountStatus(provider: .chatgpt, connected: true)]
        accounts.saveFails = true
        let services = Services(accounts: accounts)
        services.models = [model("gpt-6", .chatgpt)]
        var state = OnboardingState(); state.step = .routing
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        await vm.prepareRouting()
        XCTAssertFalse(vm.routingDraft.options.isEmpty)
        await vm.saveRouting()
        XCTAssertEqual(vm.state.step, .routing)
        XCTAssertEqual(accounts.routing, DistillAutoRouting())
        XCTAssertNotNil(vm.routingNote)
    }

    func test_confirmedAutoSaveAdvances() async throws {
        let accounts = Accounts()
        accounts.statusesValue = [DistillAccountStatus(provider: .claude, connected: true)]
        let services = Services(accounts: accounts)
        services.models = [model("sonnet", .claude)]
        var state = OnboardingState(); state.step = .routing
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        await vm.prepareRouting()
        await vm.saveRouting()
        XCTAssertEqual(vm.state.step, .bots)
        XCTAssertEqual(accounts.routing.options.map(\.mainModel), ["sonnet"])
    }

    // Retrying after a partial failure resumes at the missing resource: the
    // workspace is not opened twice and the first message is never sent.
    func test_finishIsIdempotentAcrossPartialFailureAndNeverSends() throws {
        let services = Services(accounts: Accounts())
        services.failCreate = true
        let store = try makeStore()
        var state = OnboardingState(); state.step = .workspace
        let vm = OnboardingViewModel(services: services, store: store, initial: state)
        vm.chooseFolder(URL(fileURLWithPath: NSTemporaryDirectory()))
        vm.finish()
        XCTAssertNotNil(vm.finishError)
        XCTAssertEqual(services.openCalls, 1)
        XCTAssertNotNil(store.load()?.workspaceID, "The opened workspace is checkpointed before the Bot step")
        XCTAssertTrue(services.handOffs.isEmpty)

        services.failCreate = false
        vm.finish()
        XCTAssertNil(vm.finishError)
        XCTAssertEqual(services.openCalls, 1, "Retry must reuse the workspace")
        XCTAssertEqual(services.createCalls, 2)
        XCTAssertEqual(vm.state.step, .follow, "Creating the project leads to the last step")
        XCTAssertEqual(services.opened, [OnboardingFollow.url], "Reaching step 7 opens the X profile once")
        XCTAssertTrue(services.handOffs.isEmpty, "The project opens only when setup finishes")
        vm.done()
        XCTAssertEqual(vm.state.status, .completed)
        XCTAssertEqual(services.handOffs.count, 1)
        XCTAssertEqual(services.handOffs.first?.2, OnboardingDeveloperTemplate.firstPrompt)
        XCTAssertNotNil(services.handOffs.first?.1)

        vm.finish()
        XCTAssertEqual(services.createCalls, 2, "A finished setup never creates a second Developer")
    }

    func test_finishWithoutDeveloperHandsOffWithoutActor() throws {
        let services = Services(accounts: Accounts())
        var state = OnboardingState(); state.step = .workspace; state.createDeveloper = false
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        vm.chooseFolder(URL(fileURLWithPath: NSTemporaryDirectory()))
        vm.finish()
        vm.done()
        XCTAssertEqual(services.createCalls, 0)
        XCTAssertEqual(services.handOffs.count, 1)
        XCTAssertNil(services.handOffs.first?.1)
    }

    // The window closes itself from onClose and then reports windowWillClose,
    // which calls close() again; re-entering onClose recursed until the stack
    // overflowed when setup finished.
    func test_closeIsReentrantSafeAndFinishKeepsCompletedStatus() throws {
        let services = Services(accounts: Accounts())
        var state = OnboardingState(); state.step = .workspace; state.createDeveloper = false
        var closes = 0
        var vm: OnboardingViewModel!
        vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state) { _ in
            closes += 1
            vm.close()
        }
        vm.chooseFolder(URL(fileURLWithPath: NSTemporaryDirectory()))
        vm.finish()
        vm.done()
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(vm.state.status, .completed, "Closing after finish must not downgrade to dismissed")
    }

    // Step 7 only invites the user to follow on X. Closing the window there
    // must still finish setup and open the project, never leave it dismissed
    // with a workspace the user never saw; and the created project cannot be
    // re-chosen by navigating back.
    func test_followStepFinishesOnCloseAndLocksEarlierSteps() throws {
        let services = Services(accounts: Accounts())
        var state = OnboardingState(); state.step = .workspace; state.createDeveloper = false
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        vm.chooseFolder(URL(fileURLWithPath: NSTemporaryDirectory()))
        vm.finish()
        XCTAssertEqual(vm.state.step, .follow)
        vm.goBack(); vm.jump(to: .bots)
        XCTAssertEqual(vm.state.step, .follow, "The created project cannot be revisited")
        vm.close()
        XCTAssertEqual(vm.state.status, .completed)
        XCTAssertEqual(services.handOffs.count, 1)
        XCTAssertEqual(OnboardingFollow.url.absoluteString, "https://x.com/samfajreldines")
    }

    // Resuming a setup that is already on step 7 must not open the browser
    // again at launch; only the transition into the step does.
    func test_resumingOnFollowStepDoesNotReopenBrowser() throws {
        let services = Services(accounts: Accounts())
        let workspace = WorkspaceID(); services.workspaces.insert(workspace)
        var state = OnboardingState(); state.step = .follow
        state.complete(.workspace); state.workspaceID = workspace
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        vm.finish()
        XCTAssertTrue(services.opened.isEmpty)
        vm.done()
        XCTAssertTrue(services.opened.isEmpty)
        XCTAssertEqual(vm.state.status, .completed)
    }

    // A project deleted while setup waited on step 7 must not strand the user
    // on a step whose only action needs it: setup returns to step 6.
    func test_resumingOnFollowStepWithDeletedProjectReturnsToProjectStep() throws {
        let services = Services(accounts: Accounts())
        var state = OnboardingState(); state.step = .follow
        state.complete(.workspace); state.workspaceID = WorkspaceID()
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        XCTAssertEqual(vm.state.step, .workspace)
        XCTAssertFalse(vm.isLocked)
    }

    // If the workspace vanished but the Developer survived, retry reuses the
    // Developer and grants it the new workspace instead of leaving it bound
    // to one that no longer exists.
    func test_reusedDeveloperFollowsRecreatedWorkspace() throws {
        let services = Services(accounts: Accounts())
        let bot = BotID(); services.bots.insert(bot)
        var state = OnboardingState(); state.step = .workspace
        state.workspaceID = WorkspaceID(); state.developerBotID = bot
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        vm.chooseFolder(URL(fileURLWithPath: NSTemporaryDirectory()))
        vm.finish()
        XCTAssertEqual(services.createCalls, 0)
        XCTAssertEqual(services.bindings.count, 1)
        XCTAssertEqual(services.bindings.first?.0, bot)
        XCTAssertEqual(services.bindings.first?.1, vm.state.workspaceID)
    }

    // A resource deleted after setup saved its id is created again on resume.
    func test_resumeDropsIdsOfDeletedResources() throws {
        var state = OnboardingState()
        state.workspaceID = WorkspaceID(); state.developerBotID = BotID()
        let vm = OnboardingViewModel(services: Services(accounts: Accounts()), store: try makeStore(), initial: state)
        XCTAssertNil(vm.state.workspaceID)
        XCTAssertNil(vm.state.developerBotID)
    }

    private func DistillRoutingValidation_errorFor(_ routing: DistillAutoRouting, accounts: [DistillAccountStatus], models: [AgentModelDescriptor]) -> String? {
        DistillRoutingValidation.error(routing, saved: DistillAutoRouting(), accounts: accounts, models: models)
    }
}
