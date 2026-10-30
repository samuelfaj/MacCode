import AppKit
import Foundation
import AgentRuntime
import CoreModel
import Persistence
import Surfaces

/// Setup backed by the app's existing account, Distill, workspace and Bot
/// services. Nothing here writes rows directly around their validation.
@MainActor
final class OnboardingLiveServices: OnboardingServices {
    private weak var context: AppContext?
    private let api: PrivateAccountAPI
    private let sessionStore: PrivateAccountSessionStore

    init(context: AppContext, api: PrivateAccountAPI = URLSessionPrivateAccountAPI()) {
        self.context = context
        self.api = api
        self.sessionStore = PrivateAccountSessionStore(repo: context.settingsRepo)
    }

    var accountsController: DistillAccountsController {
        // Setup is only presented while the context is alive.
        context!.distillAccountsController
    }

    func loadModels() async -> [AgentModelDescriptor] {
        await context?.router?.listAgentModels(provider: .distill) ?? []
    }

    func signIn(email: String, password: String) async throws -> PrivateAccountUser {
        try await persist(api.login(email: email, password: password))
    }

    func register(email: String, password: String) async throws -> PrivateAccountUser {
        try await persist(api.register(email: email, password: password))
    }

    /// An account is signed in only once its verified session is stored,
    /// because every consumer reloads it from settings.
    private func persist(_ session: PrivateAccountSession) async throws -> PrivateAccountUser {
        let user = try await api.currentUser(accessToken: session.accessToken)
        let verified = PrivateAccountSession(accessToken: session.accessToken, refreshToken: session.refreshToken, user: user)
        guard sessionStore.save(verified) else {
            throw OnboardingAccountError(message: "Signed in, but the session could not be saved on this Mac. Try again.")
        }
        return user
    }

    func signedInUser() -> PrivateAccountUser? { sessionStore.load()?.user }

    func workspaceExists(_ id: WorkspaceID) -> Bool { context?.state.workspaces[id] != nil }

    func botExists(_ id: BotID) -> Bool {
        guard let bot = (try? context?.botStore.get(id: id)) ?? nil else { return false }
        return bot.deletedAt == nil
    }

    func openWorkspace(folder: URL) throws -> WorkspaceID {
        guard let context, let router = context.router else { throw LayoutError.workspaceNotFound }
        let workspaces = Array(context.state.workspaces.values)
        if let existing = SidebarViewModel.findExistingWorkspace(byCwd: folder, in: workspaces) {
            try router.selectWorkspace(existing)
            return existing
        }
        let created = try router.createWorkspace(fromFolder: folder)
        NSDocumentController.shared.noteNewRecentDocumentURL(folder)
        return created.id
    }

    /// Same shape as Bots ▸ New Bot in a workspace: a workspace-scoped Bot
    /// with read/send on that workspace only.
    func createDeveloper(name: String, workspace: WorkspaceID) throws -> BotID {
        guard let context else { throw LayoutError.workspaceNotFound }
        let soul = OnboardingDeveloperTemplate.soul(name: name)
        let bot = try context.botStore.create(
            name: name,
            title: OnboardingDeveloperTemplate.title,
            description: OnboardingDeveloperTemplate.description,
            soul: soul,
            workspaceID: workspace
        )
        try bindDeveloper(bot.id, workspace: workspace)
        try? BotHome(appSupportDirectory: context.appSupportDirectory, bot: bot).ensure(
            name: bot.name, handle: bot.handle, title: bot.title, description: bot.description, soul: soul
        )
        context.router?.botsViewModel?.reload()
        return bot.id
    }

    func bindDeveloper(_ bot: BotID, workspace: WorkspaceID) throws {
        guard let context else { throw LayoutError.workspaceNotFound }
        try context.botStore.grantContext(
            hostID: context.liveActivityHostIdentity.serverId,
            botID: bot,
            context: .workspace(workspace),
            actions: [.read, .send],
            expectedRevision: nil
        )
    }

    func handOff(workspace: WorkspaceID, developer: BotID?, prompt: String) {
        guard let context, let router = context.router else { return }
        try? router.selectWorkspace(workspace)
        guard let ws = context.state.workspaces[workspace] else { return }
        let agents = ws.layout.paneIDs()
            .compactMap { ws.layout.find(paneID: $0) }
            .flatMap(\.surfaces)
            .filter { $0.type == .agentApp && $0.metadata["side_thread"] == nil }
        guard let descriptor = agents.first,
              let agent = SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface else { return }
        let vm = agent.viewModel
        // The first message stays a draft: sending is the user's decision.
        if let developer { vm.setRunActor(.bot(developer)) }
        if vm.prompt.isEmpty { vm.prompt = prompt }
        router.windowController?.window.makeKeyAndOrderFront(nil)
    }
}
