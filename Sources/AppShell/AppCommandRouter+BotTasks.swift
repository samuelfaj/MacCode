import AgentRuntime
import CoreModel
import Foundation
import Persistence
import SocketServer
import Surfaces

extension AppCommandRouter {
    func configureBotTaskLinks(on model: AgentAppViewModel) {
        model.parallelTaskStatus = { [weak self] task, source in
            guard let self else { return nil }
            let context = try self.authorizedBotTask(task, source: source)
            let runs = context.runRepo
            return try await Task.detached(priority: .utility) {
                guard let run = try runs.get(id: task.runID), run.threadId == task.threadID else { return nil }
                return run.status
            }.value
        }
        model.parallelTaskLoader = { [weak self, weak model] task, source in
            guard let self else { throw JSONRPCError.internalError }
            let context = try self.authorizedBotTask(task, source: source)
            guard let thread = try context.threadRepo.get(id: task.threadID) else {
                throw JSONRPCError(code: -32004, message: "The task conversation no longer exists.")
            }
            let bot = try context.botStore.get(id: task.botID)
            let botName = BotsViewModel.displayName(bot?.name ?? "")
            // The composer sends to this Bot conversation the way the Bot window does:
            // a follow-up queues behind the running task, otherwise it starts a run.
            let preview = AgentAppViewModel(
                workspaceID: thread.workspaceId ?? BotsViewModel.botDeskWorkspaceID,
                cwd: thread.worktreePath ?? context.appSupportDirectory.path,
                coordinator: context.coordinator,
                threadRepo: context.threadRepo,
                messageRepo: context.messageRepo,
                initialThreadId: task.threadID,
                orchestrationRuntime: context.orchestrationRuntime,
                embedding: AgentAppEmbedding(
                    pinnedThreadId: task.threadID,
                    sendInterceptor: { [weak self] text, attachments, _ in
                        guard let self, let bots = self.botsViewModel else {
                            throw JSONRPCError(code: -32045, message: "MacCode Bot runtime is unavailable.")
                        }
                        let context = try self.authorizedBotTask(task, source: source)
                        // Keep the task's own route; the Bot's desk default may be another provider.
                        let routing = try context.threadRepo.get(id: task.threadID).map { BotDeskRouting(thread: $0) }
                        _ = try bots.enqueueHostMessage(botID: task.botID, text: text,
                            conversationID: task.conversationID, attachments: attachments, routing: routing)
                        return []
                    },
                    composerPlaceholder: BotsViewModel.deskComposerPlaceholder(botName: botName),
                    pinnedThread: thread,
                    ownsComposerDraft: false
                )
            )
            preview.hidesToolActivity = model?.hidesToolActivity ?? false
            let workspace = thread.workspaceId.flatMap { context.state.workspaces[$0]?.name }
            return (preview, [botName, workspace].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// Only an exact link persisted in this source chat can open its task.
    func authorizedBotTask(_ task: BotParallelTask, source: AgentThreadID) throws -> AppContext {
        guard let context,
              let link = try context.messageRepo.get(id: AgentMessageID(task.runID.value)),
              link.threadId == source, link.role == .assistant,
              BotParallelTask.parse(link.content) == task,
              let conversation = try context.botStore.conversation(id: task.conversationID),
              conversation.botID == task.botID, conversation.linkedAgentThreadID == task.threadID,
              let bot = try context.botStore.get(id: task.botID), bot.deletedAt == nil else {
            throw JSONRPCError(code: -32050, message: "This task is not available to this conversation.")
        }
        for threadID in [source, task.threadID] {
            if let pin = try context.botStore.conversationContextPin(linkedTo: threadID) {
                guard try context.botStore.authorizes(hostID: pin.hostID, botID: pin.botID,
                    context: pin.context, action: .read, policyRevision: pin.policyRevision) else {
                    throw JSONRPCError(code: -32047, message: "Access to this task's context is no longer available.")
                }
            }
        }
        return context
    }
}
