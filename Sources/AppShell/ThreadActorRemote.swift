import CoreModel
import Foundation
import Persistence
import SocketServer
import Surfaces

/// Paired-device side of the thread actor (`agent.thread.actor.set`,
/// `agent.mac_execution.*`, and the actor fields on every thread payload).
/// The lock rules and the lock itself are the Mac composer's.
extension AppCommandRouter {
    public func threadGuestRuntime(thread: AgentThreadID) -> String? {
        (try? context?.threadRepo.guestPlacement(of: thread))??.guestRuntime
    }

    public func pendingMacExecutionReason(thread: AgentThreadID) -> String? {
        pendingMacExecution[thread]
    }

    public func setAgentThreadActor(
        thread: AgentThreadID,
        actor: RunActor,
        executionTarget requestedTarget: ExecutionTarget?
    ) async throws -> AgentThread {
        guard let ctx = context, let stored = try ctx.threadRepo.get(id: thread) else {
            throw actorRefusal(code: ManualActionWire.notFoundCode, kind: "not_found", message: L("Agent thread not found."))
        }
        // Asking for what the thread already is changes nothing, and so does
        // `none` on a thread whose actor is not locked (the Mac chip's choice
        // only counts at the first send).
        switch actor {
        case .none where stored.actor == .none || stored.actorLockedAt == nil:
            return stored
        case .bot(let id) where stored.actorLockedAt != nil && stored.actor == .bot(id)
            && (requestedTarget == nil || requestedTarget == stored.executionTarget):
            return stored
        default:
            break
        }
        // AgentRunAsUserPresentation.identityLocked, plus the composer's
        // "refused while a run is starting or running".
        let runActive = (try? activeAgentRun(thread: thread)) != nil
            || ctx.coordinator.hasPendingProviderStart(threadId: thread)
        let identityLocked = AgentRunAsUserPresentation.identityLocked(
            providerLocked: try ctx.messageRepo.hasAny(threadId: thread),
            actorLockedAt: stored.actorLockedAt
        )
        guard !identityLocked, !runActive, actor != .none else {
            throw actorRefusal(
                code: ThreadActorWire.lockedCode, kind: "locked",
                message: runActive
                    ? L("A run is active on this thread.")
                    : L("This thread's actor is fixed after the first message. Start a new thread to run as a different actor.")
            )
        }
        guard try ctx.botStore.group(roomThreadID: thread) == nil else {
            throw actorRefusal(
                code: ThreadActorWire.lockedCode, kind: "locked",
                message: L("A group conversation has no actor; its bots answer on their own threads.")
            )
        }
        guard case .bot(let botID) = actor,
              let bot = try ctx.botStore.get(id: botID), bot.deletedAt == nil else {
            throw actorRefusal(code: ManualActionWire.notFoundCode, kind: "not_found", message: L("Bot not found."))
        }
        let revision = try bot.currentRevisionID.flatMap { try ctx.botStore.getRevision(id: $0) }
        let defaultTarget = BotExecutionDefault.target(for: revision)
        if requestedTarget == .vm, defaultTarget != .vm {
            throw actorRefusal(
                code: ThreadActorWire.targetUnavailableCode, kind: "target_unavailable",
                message: L("This bot has no VM; it runs on the Mac.")
            )
        }
        guard let hooks = botWorkspaceRunHooks else {
            throw actorRefusal(code: -32000, kind: "bots_unavailable", message: L("Bots are not available on this Mac right now."))
        }
        let target = requestedTarget ?? defaultTarget
        let lockedAt: Date
        do {
            lockedAt = try AgentAppViewModel.lockThreadToBot(
                botID: botID,
                threadID: thread,
                target: target,
                composerProvider: nil,
                threadRepo: ctx.threadRepo,
                linker: hooks.link
            )
        } catch is ThreadActorAlreadyLockedError {
            throw actorRefusal(
                code: ThreadActorWire.lockedCode, kind: "locked",
                message: L("This thread's actor is fixed after the first message. Start a new thread to run as a different actor.")
            )
        } catch BotStoreError.invalidInput(let message) {
            throw actorRefusal(code: -32602, kind: "invalid_context", message: message)
        }
        for viewModel in botThreadViewModels {
            viewModel.mirrorActorLock(actor, lockedAt: lockedAt, target: target, thread: thread)
        }
        // Read back: the event, the result and later lists show the stored lock date.
        guard let updated = try ctx.threadRepo.get(id: thread) else {
            throw actorRefusal(code: ManualActionWire.notFoundCode, kind: "not_found", message: L("Agent thread not found."))
        }
        publishAgentThreadUpdated(updated)
        return updated
    }

    public func resolveMacExecutionRemote(thread: AgentThreadID, approve: Bool) async throws -> MacExecutionResolveOutcome {
        guard let ctx = context, try ctx.threadRepo.get(id: thread) != nil else {
            throw macExecutionRefusal(code: ManualActionWire.notFoundCode, kind: "not_found", message: L("Agent thread not found."))
        }
        do {
            if let outcome = try await resolveMacExecution(thread: thread, approve: approve) { return outcome }
        } catch let failure as MacExecutionStoreError {
            throw macExecutionRefusal(
                code: -32000, kind: "store_unavailable",
                message: L("The answer could not be saved; the request is still open: %1$@", failure.underlying.localizedDescription)
            )
        }
        guard try ctx.threadRepo.get(id: thread) != nil else {
            throw macExecutionRefusal(code: ManualActionWire.notFoundCode, kind: "not_found", message: L("Agent thread not found."))
        }
        throw macExecutionRefusal(
            code: ThreadActorWire.notPendingCode, kind: "not_pending",
            message: L("This bot's request to run on the Mac was already answered.")
        )
    }

    private func actorRefusal(code: Int, kind: String, message: String) -> DefiniteMutationRejection {
        DefiniteMutationRejection(ThreadActorWire.refusal(domain: "thread_actor", code: code, kind: kind, message: message))
    }

    private func macExecutionRefusal(code: Int, kind: String, message: String) -> DefiniteMutationRejection {
        DefiniteMutationRejection(ThreadActorWire.refusal(domain: "mac_execution", code: code, kind: kind, message: message))
    }
}
