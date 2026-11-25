import AgentRuntime
import AppKit
import CoreModel
import Foundation
import Persistence
import SocketServer

/// The user's answer when asked how a new local run should share a project with a run that is already editing.
public enum LocalRunConflictChoice: Equatable, Sendable {
    case runHere, newWorktree, cancel
}

/// What the host does with a new local run when other runs edit the same checkout.
enum LocalRunConflictAction: Equatable {
    case proceed, useWorktree, ask

    static func decide(
        policy: LocalRunConflictPolicy,
        isFirstMessage: Bool,
        executionMode: AgentExecutionMode,
        othersEditing: Bool
    ) -> LocalRunConflictAction {
        // A thread keeps the checkout of its first message: moving a running conversation would orphan its files.
        guard isFirstMessage, executionMode == .local, othersEditing else { return .proceed }
        switch policy {
        case .warn: return .proceed
        case .autoWorktree: return .useWorktree
        case .ask: return .ask
        }
    }
}

extension AppCommandRouter {
    /// Pre-edit lease check for a run, called by Distill's host-owned PreToolUse hook over the app socket.
    public func checkEditLease(
        callerThread: AgentThreadID,
        callerRun: AgentRunID,
        paths: [String],
        cwd: String?,
        delegationCapability: String?
    ) async throws -> JSONValue {
        guard let ctx = context else {
            throw JSONRPCError(code: -32004, message: "The calling Agent thread no longer exists.")
        }
        let run = try leaseCheckRun(thread: callerThread, claimedRun: callerRun, capability: delegationCapability, context: ctx)
        guard let service = ctx.fileLeaseService else { return .object(["verdict": .string("allow")]) }
        let verdict = await service.checkEdit(runId: run, paths: paths, cwd: cwd, enforce: true)
        switch verdict {
        case .allow: return .object(["verdict": .string("allow")])
        case .warn(let text): return .object(["verdict": .string("warn"), "message": .string(text)])
        case .deny(let text): return .object(["verdict": .string("deny"), "message": .string(text)])
        }
    }

    /// The run a pre-edit check speaks for: the claimed run when its capability is valid, otherwise the thread's
    /// live run. A resident provider process keeps the run id and capability of its first turn, and a lease verdict
    /// only reads or takes a lease, so a run id that once belonged to this thread is enough proof on the owner-only socket.
    func leaseCheckRun(thread: AgentThreadID, claimedRun: AgentRunID, capability: String?, context ctx: AppContext) throws -> AgentRunID {
        do {
            try authenticateManagedHostCall(
                threadID: thread, runID: claimedRun, delegationCapability: capability,
                mutation: false, method: "bot.peer.lease_check"
            )
            return claimedRun
        } catch {
            guard AgentDelegationCapabilityTransport.isWellFormed(capability ?? ""),
                  (try? ctx.runRepo.threadId(of: claimedRun)) == thread,
                  let active = ctx.coordinator.activeRunId(threadId: thread) else { throw error }
            return active
        }
    }

    /// First message of a local thread while other runs edit the same project: warn (the header already says so),
    /// move the thread to a fresh worktree, or ask. Runs before the thread's directory is prepared.
    func applyLocalRunConflictPolicy(to thread: inout AgentThread, alreadyStarted: Bool) async throws {
        guard let ctx = context, !alreadyStarted, thread.executionMode == .local, let workspaceID = thread.workspaceId,
              let workspaceCwd = ctx.state.workspaces.first(where: { $0.value.id == workspaceID })?.value.cwd else { return }
        let policy = SettingsStore(db: ctx.db).load().localRunConflictPolicy
        guard policy != .warn else { return }
        let cwd = GrokACPClient.resolvedSessionCwd(workspaceCwd)
        let index = ctx.concurrentWorkIndex
        let threadID = thread.id
        let snapshot = await Task.detached(priority: .userInitiated) {
            ConcurrentCheckoutSnapshot.snapshot(cwd: cwd, excludingThread: threadID, index: index)
        }.value
        switch LocalRunConflictAction.decide(
            policy: policy, isFirstMessage: true, executionMode: thread.executionMode, othersEditing: !snapshot.runs.isEmpty
        ) {
        case .proceed:
            return
        case .useWorktree:
            try await moveToWorktree(&thread, cwd: cwd, context: ctx)
        case .ask:
            switch await localRunConflictAsker(snapshot) {
            case .runHere: return
            case .newWorktree: try await moveToWorktree(&thread, cwd: cwd, context: ctx)
            case .cancel:
                throw JSONRPCError(code: -32000, message: L("Message not sent: another run is editing this project."))
            }
        }
    }

    private func moveToWorktree(_ thread: inout AgentThread, cwd: String, context ctx: AppContext) async throws {
        let base = await Task.detached(priority: .userInitiated) { GitDiff.repoIdentity(in: cwd)?.branch }.value ?? "HEAD"
        let now = Date()
        guard try ctx.threadRepo.setExecutionConfig(of: thread.id, executionMode: .worktree, baseBranch: base, at: now) else {
            throw LayoutError.workspaceNotFound
        }
        thread.executionMode = .worktree
        thread.baseBranch = base
        thread.updatedAt = now
        publishAgentThreadUpdated(thread)
    }

    /// A parallel peer task that edits the caller's repository gets its own checkout when the policy is
    /// "run in a new worktree". Any failure keeps the shared directory and says so in the log.
    func isolatedPeerCwd(_ cwd: String?, runID: AgentRunID) async -> String? {
        guard let cwd, let ctx = context,
              SettingsStore(db: ctx.db).load().localRunConflictPolicy == .autoWorktree else { return cwd }
        let key = String(runID.value.uuidString.prefix(8)).lowercased()
        let created: String? = await Task.detached(priority: .userInitiated) {
            guard let identity = GitDiff.repoIdentity(in: cwd) else { return nil }
            let root = URL(fileURLWithPath: identity.repoRoot)
            let parent = root.deletingLastPathComponent()
            let name = root.lastPathComponent.isEmpty ? "workspace" : root.lastPathComponent
            let path = parent.appendingPathComponent("\(name)-agent-worktrees").appendingPathComponent(key).path
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let result = GitDiff.createWorktree(in: identity.repoRoot, path: path, branch: "rc-agent/\(key)", baseBranch: identity.branch ?? "HEAD")
            guard result.ok || FileManager.default.fileExists(atPath: path) else {
                NSLog("RemoteCode: peer worktree for run \(key) failed, sharing the caller's checkout: \(result.message)")
                return nil
            }
            return path
        }.value
        return created ?? cwd
    }

    /// A new `rc_bot_send` task started from a thread in a git repository gets its own worktree of that repository
    /// when the policy is "run in a new worktree"; otherwise nil keeps the task in the Bot's home as before.
    func isolatedHostTaskCwd(callerThread: AgentThreadID, callerRun: AgentRunID) async -> String? {
        guard let ctx = context,
              SettingsStore(db: ctx.db).load().localRunConflictPolicy == .autoWorktree,
              let thread = try? ctx.threadRepo.get(id: callerThread),
              let scope = try? ctx.botPeerHandoffAuthority.inheritedWorkspaceScope(thread: thread, runID: callerRun),
              let callerCwd = try? effectiveAgentExecutionCwd(for: scope) else { return nil }
        let isolated = await isolatedPeerCwd(callerCwd, runID: AgentRunID())
        return isolated == callerCwd ? nil : isolated
    }

    static func askLocalRunConflict(_ snapshot: ConcurrentWorkSnapshot) async -> LocalRunConflictChoice {
        if AppContext.isRunningUnitTests { return .runHere }
        let alert = NSAlert()
        alert.messageText = L("Another run is editing this project")
        let names = snapshot.runs.prefix(5).map { "• \(snapshot.label(for: $0))" }.joined(separator: "\n")
        alert.informativeText = names + "\n\n" + L("Run this thread in a new worktree to keep the edits apart, or run here and risk overlapping changes.")
        alert.addButton(withTitle: L("Run in a new worktree"))
        alert.addButton(withTitle: L("Run here"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .newWorktree
        case .alertSecondButtonReturn: return .runHere
        default: return .cancel
        }
    }
}
