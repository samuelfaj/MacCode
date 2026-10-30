import AppKit
import Combine
import Foundation
import AgentRuntime
import CoreModel
import Persistence
import Surfaces

/// What setup needs from the app. The live implementation reuses the
/// existing services; tests substitute a fake.
@MainActor
public protocol OnboardingServices: AnyObject {
    var accountsController: DistillAccountsController { get }
    func loadModels() async -> [AgentModelDescriptor]
    func signIn(email: String, password: String) async throws -> PrivateAccountUser
    func register(email: String, password: String) async throws -> PrivateAccountUser
    func signedInUser() -> PrivateAccountUser?
    func workspaceExists(_ id: WorkspaceID) -> Bool
    func botExists(_ id: BotID) -> Bool
    /// Opens (or reuses) the workspace for `folder`.
    func openWorkspace(folder: URL) throws -> WorkspaceID
    func createDeveloper(name: String, workspace: WorkspaceID) throws -> BotID
    /// Grants an existing Developer read/send on `workspace` (idempotent).
    func bindDeveloper(_ bot: BotID, workspace: WorkspaceID) throws
    /// Selects the workspace's Agent App with an unsent first prompt.
    func handOff(workspace: WorkspaceID, developer: BotID?, prompt: String)
}

@MainActor
public final class OnboardingViewModel: ObservableObject {
    @Published public private(set) var state: OnboardingState
    @Published public var email = ""
    @Published public var password = ""
    @Published public var creatingAccount = false
    @Published public private(set) var accountBusy = false
    @Published public private(set) var accountError: String?
    @Published public private(set) var signedInEmail: String?
    @Published public private(set) var routingDraft = DistillAutoRouting()
    @Published public private(set) var routingNote: String?
    @Published public private(set) var folder: URL?
    @Published public private(set) var finishing = false
    @Published public private(set) var finishError: String?
    @Published public private(set) var persistenceError: String?
    /// +1 forward, -1 back: picks the slide direction between steps.
    @Published public private(set) var direction = 1

    public let services: OnboardingServices
    private let store: OnboardingStateStore
    private let onClose: (OnboardingState) -> Void
    private var closed = false

    public init(services: OnboardingServices, store: OnboardingStateStore, initial: OnboardingState,
                onClose: @escaping (OnboardingState) -> Void = { _ in }) {
        self.services = services
        self.store = store
        self.onClose = onClose
        var state = initial
        // Resources that disappeared since the last run are created again.
        if let id = state.workspaceID, !services.workspaceExists(id) { state.workspaceID = nil }
        if let id = state.developerBotID, !services.botExists(id) { state.developerBotID = nil }
        self.state = state
        signedInEmail = services.signedInUser()?.email
    }

    public var accounts: DistillAccountsController { services.accountsController }

    // MARK: Navigation

    public func goBack() {
        guard let previous = state.step.previous else { return }
        direction = -1
        update { $0.step = previous }
    }

    public func advance(completing step: OnboardingStep) {
        direction = 1
        update {
            $0.complete(step)
            if let next = step.next { $0.step = next }
        }
    }

    public func skip(_ step: OnboardingStep) {
        direction = 1
        update {
            $0.skip(step)
            if let next = step.next { $0.step = next }
        }
    }

    public func jump(to step: OnboardingStep) {
        guard step.index <= furthestReachable.index else { return }
        direction = step.index >= state.step.index ? 1 : -1
        update { $0.step = step }
    }

    /// Steps before the furthest decided one stay reachable from the stepper.
    public var furthestReachable: OnboardingStep {
        let decided = state.completedSteps.union(state.skippedSteps)
        return OnboardingStep.allCases.first { !decided.contains($0) } ?? .workspace
    }

    /// Closing keeps progress; launch no longer reopens the window.
    /// Idempotent: the window's own close path calls back into here.
    public func close() {
        guard !closed else { return }
        closed = true
        if state.status == .inProgress { update { $0.status = .dismissed } }
        onClose(state)
    }

    private func update(_ change: (inout OnboardingState) -> Void) {
        var next = state
        change(&next)
        state = next
        persistenceError = store.save(next) ? nil : "Progress could not be saved. Your choices still apply in this window."
    }

    // MARK: Account

    public var accountFormValid: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".") && password.count >= Self.minimumPasswordLength
    }

    public static let minimumPasswordLength = 8

    public func submitAccount() async {
        guard accountFormValid, !accountBusy else { return }
        accountBusy = true
        accountError = nil
        defer { accountBusy = false }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let user = creatingAccount
                ? try await services.register(email: trimmed, password: password)
                : try await services.signIn(email: trimmed, password: password)
            password = ""
            signedInEmail = user.email
            advance(completing: .account)
        } catch {
            accountError = Self.accountErrorMessage(error, creating: creatingAccount)
        }
    }

    static func accountErrorMessage(_ error: Error, creating: Bool) -> String {
        if let error = error as? OnboardingAccountError { return error.message }
        if let api = error as? PrivateAccountAPIError, case .http(let code) = api {
            switch code {
            case 409: return "An account with this email already exists. Sign in instead."
            case 400: return creating ? "Check the email address and use at least 8 characters for the password." : "Check the email address and password."
            case 401, 403: return "Email or password is incorrect."
            case 429: return "Too many attempts. Wait a minute and try again."
            case 500...599: return "The service is unavailable. Try again shortly."
            default: return "Something went wrong. Try again."
            }
        }
        if let url = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(url.code) {
            return "No internet connection."
        }
        return "Something went wrong. Try again."
    }

    // MARK: Auto

    /// Builds the recommended profile from connected accounts and the live
    /// catalog: one option per connected subscription account, in provider
    /// order, using its first listed model. OpenRouter is left out because it
    /// bills API usage separately; the editor in Settings can add it.
    public static func recommendedRouting(accounts: [DistillAccountStatus], models: [AgentModelDescriptor],
                                          strategy: DistillAutoStrategy) -> DistillAutoRouting {
        let order: [DistillAccountProvider] = [.chatgpt, .claude, .grok]
        let options = accounts
            .filter { $0.connected && $0.provider != .openrouter }
            .sorted { (order.firstIndex(of: $0.provider) ?? 9) < (order.firstIndex(of: $1.provider) ?? 9) }
            .compactMap { account -> DistillAutoOption? in
                guard let model = DistillRoutingValidation.models(for: account, catalog: models).first else { return nil }
                return DistillAutoOption(id: "onboarding-\(account.id)", accountID: account.id, mainModel: model.id)
            }
        return DistillAutoRouting(enabled: !options.isEmpty, strategy: strategy, options: options)
    }

    public func prepareRouting(strategy: DistillAutoStrategy? = nil) async {
        await accounts.refreshAndWait()
        let models = await accounts.discoverModels(using: services.loadModels)
        let chosen = strategy ?? routingDraft.strategy
        routingDraft = Self.recommendedRouting(accounts: accounts.statuses, models: models, strategy: chosen)
        routingNote = routingDraft.options.isEmpty
            ? "Connect ChatGPT, Claude or Grok to use Auto. You can also choose a model per conversation."
            : nil
    }

    public func setStrategy(_ strategy: DistillAutoStrategy) {
        routingDraft.strategy = strategy
    }

    /// Saves through the shared controller, so Settings and conversations
    /// read the same profile. Advances only after Distill confirms the save.
    public func saveRouting() async {
        guard !routingDraft.options.isEmpty else { return }
        if await accounts.saveRoutingAndWait(routingDraft) {
            advance(completing: .routing)
        } else {
            routingNote = accounts.lastError ?? "Auto was not saved. Try again."
        }
    }

    // MARK: Bots

    public func setCreateDeveloper(_ create: Bool) { update { $0.createDeveloper = create } }

    public func setDeveloperName(_ name: String) {
        update { $0.developerName = String(name.prefix(40)) }
    }

    // MARK: Workspace

    public func chooseFolder(_ url: URL) {
        folder = url.standardizedFileURL
        finishError = nil
    }

    /// Opens the workspace, creates the Developer when chosen, and hands off
    /// to the conversation with an unsent prompt. Ids are saved after each
    /// mutation, so a retry resumes at the first missing resource.
    public func finish() {
        guard !finishing else { return }
        guard let folder else { finishError = "Choose a project folder first."; return }
        finishing = true
        finishError = nil
        defer { finishing = false }
        do {
            let workspace: WorkspaceID
            var workspaceIsNew = false
            if let existing = state.workspaceID { workspace = existing } else {
                workspace = try services.openWorkspace(folder: folder)
                workspaceIsNew = true
                update { $0.workspaceID = workspace }
            }
            var developer: BotID?
            if state.createDeveloper {
                if let existing = state.developerBotID {
                    // A Developer kept from an earlier attempt follows the workspace opened now.
                    if workspaceIsNew { try services.bindDeveloper(existing, workspace: workspace) }
                    developer = existing
                } else {
                    let name = state.developerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let created = try services.createDeveloper(
                        name: name.isEmpty ? OnboardingDeveloperTemplate.defaultName : name, workspace: workspace)
                    update { $0.developerBotID = created }
                    developer = created
                }
            }
            update {
                $0.complete(.workspace)
                $0.status = .completed
                $0.completedAt = Date()
            }
            services.handOff(workspace: workspace, developer: developer, prompt: OnboardingDeveloperTemplate.firstPrompt)
            close()
        } catch {
            finishError = "Could not finish setup: \(error.localizedDescription)"
        }
    }
}

public struct OnboardingAccountError: Error, Equatable {
    public let message: String
}
