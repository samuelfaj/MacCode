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
            let preview = AgentAppViewModel(
                workspaceID: thread.workspaceId ?? BotsViewModel.botDeskWorkspaceID,
                cwd: thread.worktreePath ?? context.appSupportDirectory.path,
                coordinator: context.coordinator,
                threadRepo: context.threadRepo,
                messageRepo: context.messageRepo,
                initialThreadId: task.threadID,
                orchestrationRuntime: context.orchestrationRuntime,
                embedding: AgentAppEmbedding(pinnedThreadId: task.threadID,
                    pinnedThread: thread, ownsComposerDraft: false)
            )
            preview.hidesToolActivity = model?.hidesToolActivity ?? false
            return preview
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
