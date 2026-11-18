import CoreModel
import Foundation
import Persistence
import Surfaces

/// The live conversation shown in Activity's detail pane.
@MainActor
final class ActivityConversation {
    let viewModel: AgentAppViewModel
    /// True when the pane shows the same composer a workspace tab would.
    let showsComposer: Bool
    /// Set for a Bot conversation the Desk's Agent App cannot host here (Titio's inbox, a
    /// group room): replies go through the Bot runtime.
    let botTarget: ActivityBotTarget?
    private let onClose: () -> Void

    init(viewModel: AgentAppViewModel, showsComposer: Bool, botTarget: ActivityBotTarget? = nil, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.showsComposer = showsComposer
        self.botTarget = botTarget
        self.onClose = onClose
    }

    func close() { onClose() }
}

@MainActor
struct ActivityBotTarget {
    let botID: BotID
    let conversationID: BotConversationID
    let send: (String) throws -> Void
    let stop: () throws -> Void
    let isRunActive: () -> Bool
}

enum ActivityBotSendError: LocalizedError {
    case runtimeUnavailable
    var errorDescription: String? { L("Bot runtime is unavailable.") }
}

extension AppCommandRouter {
    /// A thread whose workspace is open gets a real Agent App wired exactly like a
    /// workspace tab (composer, bot prompts, queue, providers), but never registered as
    /// a tab. A Bot conversation with no open workspace gets the Desk's own Agent App,
    /// so its reply has the Desk's composer options and runs on the same thread.
    /// Anything else stays a read-only pinned view.
    func makeActivityConversation(_ item: ActivityWireItem) -> ActivityConversation? {
        guard let context, let threadID = item.thread_id.flatMap(UUID.init(uuidString:)).map(AgentThreadID.init),
              let thread = try? context.threadRepo.get(id: threadID) else { return nil }
        let linked: BotConversation?
        do { linked = try context.botStore.conversationsLinked(to: [threadID])[threadID] }
        catch { return nil }
        guard linked?.isHiddenTask != true else { return nil }
        if let workspaceID = thread.workspaceId, let workspace = context.state.workspaces[workspaceID] {
            let agent = AgentAppSurface(
                workspaceID: workspaceID, cwd: workspace.cwd, coordinator: context.coordinator,
                threadRepo: context.threadRepo, messageRepo: context.messageRepo,
                draftRepo: AgentThreadDraftRepository(db: context.db),
                attachmentStore: AgentAttachmentStore(root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)),
                queuedMessageRepo: context.queuedMessageRepo, providerSessionRepo: context.providerSessionRuntimeRepo,
                pendingCallbackRepo: context.providerPendingCallbackRepo, proposedPlanRepo: context.proposedPlanRepo,
                checkpointRepo: context.turnCheckpointRepo, promptHistoryStore: PromptHistoryStore(db: context.db),
                customModelStore: AgentCustomModelStore(repo: context.settingsRepo), planNotesStore: PlanNotesStore(db: context.db),
                initialThreadId: threadID, orchestrationRuntime: context.orchestrationRuntime
            )
            wireWorkspaceAgentSurface(agent, workspace: workspaceID, ctx: context)
            return ActivityConversation(viewModel: agent.viewModel, showsComposer: true) { [weak context] in
                agent.close()
                context?.threadRepo.setLiveSurfaceBinding(surfaceID: agent.descriptor.id, threadID: nil)
            }
        }
        if let linked, let desk = botsViewModel?.makeActivityDeskAgent(conversation: linked, thread: thread) {
            return ActivityConversation(viewModel: desk.viewModel, showsComposer: true, onClose: desk.close)
        }
        let viewModel = AgentAppViewModel(
            workspaceID: thread.workspaceId ?? BotsViewModel.botDeskWorkspaceID,
            cwd: context.appSupportDirectory.path,
            coordinator: context.coordinator,
            threadRepo: context.threadRepo,
            messageRepo: context.messageRepo,
            // No draft repository: this host has no composer, and the unsent draft belongs to the real chat.
            attachmentStore: AgentAttachmentStore(
                root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
            ),
            queuedMessageRepo: context.queuedMessageRepo,
            providerSessionRepo: context.providerSessionRuntimeRepo,
            pendingCallbackRepo: context.providerPendingCallbackRepo,
            proposedPlanRepo: context.proposedPlanRepo,
            checkpointRepo: context.turnCheckpointRepo,
            promptHistoryStore: PromptHistoryStore(db: context.db),
            customModelStore: AgentCustomModelStore(repo: context.settingsRepo),
            planNotesStore: PlanNotesStore(db: context.db),
            initialThreadId: threadID,
            initialRoutingMode: .manual,
            orchestrationRuntime: context.orchestrationRuntime,
            embedding: AgentAppEmbedding(pinnedThreadId: threadID, pinnedThread: thread, ownsComposerDraft: false)
        )
        configureBotTaskLinks(on: viewModel)
        viewModel.botNameProvider = { [weak context] botID in
            (try? context?.botStore.get(id: botID))??.name
        }
        viewModel.markThreadRead = { [weak self] id in
            try self?.markAgentThreadRead(thread: id)
        }
        var botTarget: ActivityBotTarget?
        if let linked {
            botTarget = ActivityBotTarget(
                botID: linked.botID,
                conversationID: linked.id,
                send: { [weak self] text in
                    guard let bots = self?.botsViewModel else { throw ActivityBotSendError.runtimeUnavailable }
                    _ = try bots.enqueueHostMessage(botID: linked.botID, text: text, conversationID: linked.id)
                },
                stop: { [weak self] in
                    guard let self else { return }
                    try self.stopAgentRun(thread: threadID)
                },
                isRunActive: { [weak self] in self?.context?.coordinator.activeRunId(threadId: threadID) != nil }
            )
        }
        return ActivityConversation(viewModel: viewModel, showsComposer: false, botTarget: botTarget) { viewModel.dispose() }
    }
}
