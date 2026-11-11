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
        /// Most tests start past the mandatory sign-in step.
        var session: PrivateAccountUser? = PrivateAccountUser(daysRemaing: nil, daysRemaining: 30, email: "dev@example.com", id: "u1", subscribed: true)
        func signedInUser() -> PrivateAccountUser? { session }
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

    // Existing projects or account sessions do not prove setup was handled.
    // The sidebar Sign in button is the natural door into setup for anyone
    // who never finished it, including upgraders recorded as existing users.
    // After setup is done, or once signed in, it must stay a plain sign-in.
    // MacCode cannot be used signed out: sign-in is step 1, cannot be skipped,
    // and losing the session sends the user back to it.
    func test_signInIsMandatoryFirstAndCannotBeSkipped() async throws {
        let services = Services(accounts: Accounts())
        services.session = nil
        services.user = PrivateAccountUser(daysRemaing: nil, daysRemaining: 30, email: "new@example.com", id: "u2", subscribed: false)
        var resumed = OnboardingState(); resumed.step = .chrome; resumed.complete(.signIn); resumed.complete(.setup)
        let store = try makeStore()
        let vm = OnboardingViewModel(services: services, store: store, initial: resumed)
        XCTAssertEqual(vm.state.step, .signIn, "A missing session reopens sign-in first")
        XCTAssertFalse(vm.state.completedSteps.contains(.signIn))
        vm.skip(.signIn)
        XCTAssertEqual(vm.state.step, .signIn)
        XCTAssertFalse(vm.state.skippedSteps.contains(.signIn))
        vm.skipSetup()
        XCTAssertEqual(vm.state.status, .inProgress, "Skip setup is unavailable while signed out")
        vm.jump(to: .setup)
        XCTAssertEqual(vm.state.step, .signIn, "The stepper cannot move past sign-in")
        vm.email = "new@example.com"; vm.password = "correct-horse"
        await vm.submitAccount()
        XCTAssertTrue(vm.isSignedIn)
        XCTAssertEqual(vm.state.step, .setup)
        XCTAssertTrue(vm.state.completedSteps.contains(.signIn))
        XCTAssertEqual(store.load()?.step, .setup)
    }

    func test_existingSessionSkipsPastSignIn() throws {
        let vm = OnboardingViewModel(services: Services(accounts: Accounts()), store: try makeStore(), initial: OnboardingState())
        XCTAssertEqual(vm.state.step, .setup)
        XCTAssertTrue(vm.state.completedSteps.contains(.signIn))
    }

    func test_fullDiskAccessIsDetectedFromTheTCCDatabase() {
        let home = URL(fileURLWithPath: "/Users/someone")
        var asked: URL?
        XCTAssertTrue(HostFileAccessProber.hasFullDiskAccess(home: home) { asked = $0; return true })
        XCTAssertEqual(asked?.path, "/Users/someone/Library/Application Support/com.apple.TCC/TCC.db")
        XCTAssertFalse(HostFileAccessProber.hasFullDiskAccess(home: home) { _ in false })
    }

    func test_signInButtonOpensSetupOnlyUntilSetupIsFinished() {
        XCTAssertTrue(OnboardingGate.signInOpensSetup(saved: nil, signedIn: false))
        var existing = OnboardingState(); existing.status = .existingUser
        XCTAssertTrue(OnboardingGate.signInOpensSetup(saved: existing, signedIn: false))
        var dismissed = OnboardingState(); dismissed.status = .dismissed
        XCTAssertTrue(OnboardingGate.signInOpensSetup(saved: dismissed, signedIn: false))
        var done = OnboardingState(); done.status = .completed
        XCTAssertFalse(OnboardingGate.signInOpensSetup(saved: done, signedIn: false))
        XCTAssertFalse(OnboardingGate.signInOpensSetup(saved: nil, signedIn: true))
    }

    func test_launchResumesUntilCompletedOrExplicitlySkipped() {
        XCTAssertTrue(OnboardingGate.launchDecision(saved: nil, hasWorkspaces: false, hasAccountSession: false).present)
        // Finished or skipped setup still opens when signed out: MacCode never starts without an account.
        var finished = OnboardingState(); finished.status = .completed
        XCTAssertTrue(OnboardingGate.launchDecision(saved: finished, hasWorkspaces: true, hasAccountSession: false).present)
        var skippedOut = OnboardingState(); skippedOut.status = .skipped
        XCTAssertTrue(OnboardingGate.launchDecision(saved: skippedOut, hasWorkspaces: true, hasAccountSession: false).present)
        let upgraded = OnboardingGate.launchDecision(saved: nil, hasWorkspaces: true, hasAccountSession: false)
        XCTAssertTrue(upgraded.present)
        XCTAssertEqual(upgraded.stateToSave?.status, .inProgress)
        XCTAssertTrue(OnboardingGate.launchDecision(saved: nil, hasWorkspaces: false, hasAccountSession: true).present)
        var dismissed = OnboardingState(); dismissed.status = .dismissed
        XCTAssertTrue(OnboardingGate.launchDecision(saved: dismissed, hasWorkspaces: false, hasAccountSession: false).present)
        var skipped = OnboardingState(); skipped.status = .skipped
        XCTAssertFalse(OnboardingGate.launchDecision(saved: skipped, hasWorkspaces: false, hasAccountSession: true).present)
        var completed = OnboardingState(); completed.status = .completed
        XCTAssertFalse(OnboardingGate.launchDecision(saved: completed, hasWorkspaces: true, hasAccountSession: true).present)
    }

    // A deferred step is not a success: it must stay distinguishable so the
    // app can offer it again instead of claiming it is configured.
    func test_skipIsRecordedAsSkippedAndNeverAsCompleted() throws {
        let services = Services(accounts: Accounts())
        let store = try makeStore()
        let vm = OnboardingViewModel(services: services, store: store, initial: OnboardingState())
        vm.skip(.setup)
        XCTAssertEqual(vm.state.step, .permissions)
        XCTAssertTrue(vm.state.skippedSteps.contains(.setup))
        XCTAssertFalse(vm.state.completedSteps.contains(.setup))
        XCTAssertEqual(store.load(), vm.state, "Progress survives a relaunch")
    }

    // Users cannot jump past an undecided step via the stepper.
    func test_stepperCannotSkipAheadOfUndecidedSteps() throws {
        let vm = OnboardingViewModel(services: Services(accounts: Accounts()), store: try makeStore(), initial: OnboardingState())
        vm.jump(to: .project)
        XCTAssertEqual(vm.state.step, .setup)
    }

    func test_failedSignInStaysOnStepWithActionableMessage() async throws {
        let services = Services(accounts: Accounts())
        services.signInError = PrivateAccountAPIError.http(401)
        var state = OnboardingState(); state.step = .accounts
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        vm.email = "dev@example.com"; vm.password = "correct-horse"
        await vm.submitAccount()
        XCTAssertEqual(vm.state.step, .accounts)
        XCTAssertEqual(vm.accountError, "Email or password is incorrect.")
        XCTAssertEqual(vm.password, "correct-horse", "Keep the password for a retry")
    }

    func test_registerConflictPointsToSignIn() {
        XCTAssertEqual(OnboardingViewModel.accountErrorMessage(PrivateAccountAPIError.conflict(code: "email_already_registered"), creating: true),
                       "An account with this email already exists. Sign in instead.")
    }

    func test_closeResumesButExplicitSkipPersistsAcrossLaunch() throws {
        let services = Services(accounts: Accounts())
        let store = try makeStore()
        let vm = OnboardingViewModel(services: services, store: store, initial: OnboardingState())
        vm.advance(completing: .setup)
        vm.close()
        XCTAssertEqual(store.load()?.step, .permissions)
        XCTAssertTrue(OnboardingGate.launchDecision(saved: store.load(), hasWorkspaces: true, hasAccountSession: true).present)
        let resumed = OnboardingViewModel(services: services, store: store, initial: try XCTUnwrap(store.load()))
        resumed.skipSetup()
        XCTAssertFalse(OnboardingGate.launchDecision(saved: store.load(), hasWorkspaces: true, hasAccountSession: true).present)
        XCTAssertEqual(store.load()?.status, .skipped)
    }

    // Setup was twelve steps; saved progress must fold into the five current
    // ones without repeating work the user already did or promoting a skip.
    func test_savedTwelveStepProgressFoldsIntoFiveSteps() throws {
        let json = """
        {"version":3,"status":"inProgress","step":"accounts","createDeveloper":false,"developerName":"Dev",
         "completedSteps":["distill","permissions","tools","basics","account","jev"],"skippedSteps":["chrome"]}
        """
        let old = try JSONDecoder().decode(OnboardingState.self, from: Data(json.utf8))
        XCTAssertEqual(old.version, 4)
        XCTAssertEqual(old.step, .accounts)
        XCTAssertEqual(old.completedSteps, [.setup, .permissions])
        XCTAssertEqual(old.skippedSteps, [.chrome], "A skipped Chrome step is not a completed one")
        XCTAssertFalse(old.createDeveloper)
        XCTAssertEqual(Array(OnboardingStep.allCases), [.signIn, .setup, .permissions, .chrome, .accounts, .project])
        XCTAssertEqual(OnboardingStep.signIn.index, 0, "Sign-in is step 1")
        XCTAssertEqual(OnboardingStep.allCases.count, 6)
    }

    func test_halfFinishedLegacyGroupIsNotMarkedDone() throws {
        let json = #"{"version":3,"status":"inProgress","step":"tools","completedSteps":["distill"]}"#
        let old = try JSONDecoder().decode(OnboardingState.self, from: Data(json.utf8))
        XCTAssertEqual(old.step, .setup)
        XCTAssertFalse(old.completedSteps.contains(.setup), "Tools were never completed, so Setup must stay open")
    }

    func test_legacyFinishedProjectStaysLocked() throws {
        let services = Services(accounts: Accounts())
        let workspace = WorkspaceID(); services.workspaces.insert(workspace)
        let json = #"{"version":3,"status":"inProgress","step":"follow","completedSteps":["workspace"]}"#
        var old = try JSONDecoder().decode(OnboardingState.self, from: Data(json.utf8))
        XCTAssertEqual(old.step, .project)
        XCTAssertFalse(old.completedSteps.contains(.project), "Follow was not completed, so the project step is not final")
        old.workspaceID = workspace; old.complete(.project)
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: old)
        XCTAssertTrue(vm.isLocked)
        vm.jump(to: .setup)
        XCTAssertEqual(vm.state.step, .project, "An existing project must not become editable through the stepper")
    }

    func test_failedToolInstallCanRetryAndNeverClaimsReady() async {
        let setup = OnboardingSetupController(check: { _ in .missing }, install: { _ in throw URLError(.notConnectedToInternet) })
        await setup.prepareDistill()
        guard case .failed = setup.state(.distill) else { return XCTFail("Expected an actionable failure") }
        XCTAssertFalse(setup.state(.distill).isReady)
        XCTAssertFalse(setup.requiredToolsReady, "Continue must stay disabled while required tools are unchecked or missing")
        let ready = OnboardingSetupController(check: { _ in .ready("Distill test") }, install: { _ in XCTFail("Existing tools must be reused") })
        await ready.prepareDistill()
        XCTAssertTrue(ready.state(.distill).isReady)
        await ready.prepareTools()
        XCTAssertTrue(ready.requiredToolsReady)
        let failedNode = OnboardingSetupController(check: { $0 == .node ? .failed("download failed") : .ready("ok") }, install: { _ in })
        await failedNode.prepareTools()
        XCTAssertFalse(failedNode.requiredToolsReady, "One failed prerequisite must never silently advance as a skipped step")
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
    func test_failedAutoSaveKeepsUserOnAccountsStep() async throws {
        let accounts = Accounts()
        accounts.statusesValue = [DistillAccountStatus(provider: .chatgpt, connected: true)]
        accounts.saveFails = true
        let services = Services(accounts: accounts)
        services.models = [model("gpt-6", .chatgpt)]
        var state = OnboardingState(); state.step = .accounts
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        await vm.finishAccounts()
        XCTAssertFalse(vm.routingDraft.options.isEmpty)
        XCTAssertEqual(vm.state.step, .accounts)
        XCTAssertEqual(accounts.routing, DistillAutoRouting())
        XCTAssertNotNil(vm.routingNote)
    }

    func test_leavingAccountsStepSavesRecommendedAutoAndAdvances() async throws {
        let accounts = Accounts()
        accounts.statusesValue = [DistillAccountStatus(provider: .claude, connected: true)]
        let services = Services(accounts: accounts)
        services.models = [model("sonnet", .claude)]
        var state = OnboardingState(); state.step = .accounts
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        await vm.finishAccounts()
        XCTAssertEqual(vm.state.step, .project)
        XCTAssertTrue(vm.state.completedSteps.contains(.accounts))
        XCTAssertEqual(accounts.routing.options.map(\.mainModel), ["sonnet"])
    }

    // Retrying after a partial failure resumes at the missing resource: the
    // workspace is not opened twice and the first message is never sent.
    func test_finishIsIdempotentAcrossPartialFailureAndNeverSends() throws {
        let services = Services(accounts: Accounts())
        services.failCreate = true
        let store = try makeStore()
        var state = OnboardingState(); state.step = .project
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
        XCTAssertTrue(vm.state.completedSteps.contains(.project))
        XCTAssertEqual(services.opened, [OnboardingFollow.url], "Choosing the folder opens the maker's X profile once")
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
        var state = OnboardingState(); state.step = .project; state.createDeveloper = false
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
        var state = OnboardingState(); state.step = .project; state.createDeveloper = false
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
    func test_closingAfterProjectFinishesSetupAndLocksProject() throws {
        let services = Services(accounts: Accounts())
        var state = OnboardingState(); state.step = .project; state.createDeveloper = false
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        vm.chooseFolder(URL(fileURLWithPath: NSTemporaryDirectory()))
        vm.finish()
        XCTAssertEqual(vm.state.step, .project)
        vm.goBack(); vm.jump(to: .setup)
        XCTAssertEqual(vm.state.step, .project, "The created project cannot be revisited")
        vm.close()
        XCTAssertEqual(vm.state.status, .completed)
        XCTAssertEqual(services.handOffs.count, 1)
        XCTAssertEqual(OnboardingFollow.url.absoluteString, "https://x.com/samfajreldines")
    }

    // Resuming a setup that is already on step 7 must not open the browser
    // again at launch; only the transition into the step does.
    func test_resumingFinishedProjectNeverOpensBrowser() throws {
        let services = Services(accounts: Accounts())
        let workspace = WorkspaceID(); services.workspaces.insert(workspace)
        var state = OnboardingState(); state.step = .project
        state.complete(.project); state.workspaceID = workspace
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        vm.finish()
        XCTAssertTrue(services.opened.isEmpty)
        vm.done()
        XCTAssertTrue(services.opened.isEmpty)
        XCTAssertEqual(vm.state.status, .completed)
    }

    // A project deleted while setup was open must not strand the user: the
    // project step becomes choosable again.
    func test_resumingWithDeletedProjectAllowsChoosingAgain() throws {
        let services = Services(accounts: Accounts())
        var state = OnboardingState(); state.step = .project
        state.complete(.project); state.workspaceID = WorkspaceID()
        let vm = OnboardingViewModel(services: services, store: try makeStore(), initial: state)
        XCTAssertEqual(vm.state.step, .project)
        XCTAssertFalse(vm.state.completedSteps.contains(.project))
        XCTAssertFalse(vm.isLocked)
    }

    // If the workspace vanished but the Developer survived, retry reuses the
    // Developer and grants it the new workspace instead of leaving it bound
    // to one that no longer exists.
    func test_reusedDeveloperFollowsRecreatedWorkspace() throws {
        let services = Services(accounts: Accounts())
        let bot = BotID(); services.bots.insert(bot)
        var state = OnboardingState(); state.step = .project
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
