import CoreModel
import Foundation
import Persistence

/// Resolves each run's repo identity once at run start and records the files its provider edits.
/// Git and SQLite work runs off the caller's thread; touches of one run stay ordered.
public final class RunFileTouchTracker: @unchecked Sendable {
    public typealias IdentityResolver = @Sendable (_ cwd: String) -> RunRepoIdentity?

    private struct RunState {
        let threadId: AgentThreadID
        let cwd: String
        let identity: Task<RunRepoIdentity?, Never>
        var chain: Task<Void, Never>?
    }

    private let store: AgentRunFileTouchRepository
    private let resolveIdentity: IdentityResolver
    private let lock = NSLock()
    private var runs: [AgentRunID: RunState] = [:]

    public init(
        store: AgentRunFileTouchRepository,
        resolveIdentity: @escaping IdentityResolver = { GitDiff.repoIdentity(in: $0) }
    ) {
        self.store = store
        self.resolveIdentity = resolveIdentity
    }

    /// Starts the one identity probe for `runId`; later calls for the same run are ignored.
    public func begin(runId: AgentRunID, threadId: AgentThreadID, cwd: String?) {
        guard let cwd, !cwd.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard runs[runId] == nil else { return }
        let store = store, resolve = resolveIdentity
        let identity = Task.detached(priority: .utility) { () -> RunRepoIdentity? in
            guard let identity = resolve(cwd) else { return nil }
            try? store.saveIdentity(runId: runId, threadId: threadId, identity: identity)
            return identity
        }
        runs[runId] = RunState(threadId: threadId, cwd: cwd, identity: identity, chain: nil)
    }

    /// Queues `touches` for `runId`. Paths outside the run's checkout are dropped.
    public func record(runId: AgentRunID, touches: [ProviderFileTouch], at date: Date = Date()) {
        guard !touches.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var state = runs[runId] else { return }
        let previous = state.chain
        let store = store
        let (threadId, cwd, identity) = (state.threadId, state.cwd, state.identity)
        state.chain = Task.detached(priority: .utility) {
            await previous?.value
            guard let identity = await identity.value else { return }
            let relative = touches.compactMap { touch in
                RunFileTouchPaths.relativize(path: touch.path, repoRoot: identity.repoRoot, cwd: cwd)
                    .map { ProviderFileTouch(path: $0, kind: touch.kind) }
            }
            try? store.recordTouches(runId: runId, threadId: threadId, repoRoot: identity.repoRoot, touches: relative, at: date)
        }
        runs[runId] = state
    }

    /// Waits for every queued touch of `runId`, forgets the run and returns what it edited.
    /// Nil means the run has no repo identity (not a git checkout, or probing failed).
    public func complete(runId: AgentRunID) async -> RunTouchResult? {
        lock.lock()
        let state = runs.removeValue(forKey: runId)
        lock.unlock()
        guard let state else { return nil }
        await state.chain?.value
        guard let identity = await state.identity.value else { return nil }
        let paths = ((try? store.touches(runId: runId)) ?? []).map(\.path)
        return RunTouchResult(identity: identity, cwd: state.cwd, touchedPaths: Set(paths))
    }
}

public struct RunTouchResult: Sendable, Equatable {
    public let identity: RunRepoIdentity
    public let cwd: String
    /// Repo-root-relative paths; empty when the provider reported no edits.
    public let touchedPaths: Set<String>
}
