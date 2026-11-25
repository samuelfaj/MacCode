import CoreModel
import Foundation
import Persistence

/// Turn-start context about other runs in the same repository: who is editing what, files that changed
/// under this run since its last turn, and earlier work that looks like the new request.
///
/// Delivery per provider: Claude, Codex, Distill and Grok all receive the block at the start of every turn
/// through the turn-context environment value each adapter already forwards. Notices about files another run
/// started editing are held until the thread's next turn; no provider has a safe mid-turn channel for a
/// host-authored message (Codex `turn/steer` and a queued Distill prompt both carry a user message).
public final class ConcurrentWorkContext: @unchecked Sendable {
    public typealias IdentityResolver = @Sendable (_ cwd: String) -> RunRepoIdentity?

    public struct TurnContext: Sendable {
        /// The `<concurrent_work>` block, nil when there is nothing to tell.
        public let block: String?
        public let similar: [SimilarWork]
        fileprivate let deliveredNoticeKeys: Set<String>
    }

    public static let maxPendingNoticesPerThread = 20
    /// Longer requests compare on their opening, which states the goal.
    public static let maxRequestLength = 600
    public static let noticeLifetime: TimeInterval = 24 * 60 * 60

    private struct PendingNotice {
        let key: String
        let notice: ConcurrentWorkNotice
    }

    private let index: ConcurrentWorkIndex
    private let similarIndex: SimilarWorkIndex
    private let resolveIdentity: IdentityResolver
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var pending: [AgentThreadID: [PendingNotice]] = [:]
    /// Keys already delivered, so a run editing the same file again does not repeat the notice.
    private var delivered: [AgentThreadID: Set<String>] = [:]

    public init(
        db: SQLiteDB,
        liveRunIDs: (@Sendable () -> Set<AgentRunID>)? = nil,
        resolveIdentity: @escaping IdentityResolver = { GitDiff.repoIdentity(in: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.index = ConcurrentWorkIndex(db: db, liveRunIDs: liveRunIDs)
        self.similarIndex = SimilarWorkIndex(db: db, liveRunIDs: liveRunIDs)
        self.resolveIdentity = resolveIdentity
        self.now = now
    }

    /// Everything the agent should know at the start of a turn. Runs off the caller's thread; failures
    /// degrade to "nothing to tell" because this context is advice, never a gate.
    public func turnContext(threadId: AgentThreadID, runId: AgentRunID, cwd: String?, request: String) async -> TurnContext {
        let request = String(request.prefix(Self.maxRequestLength))
        let work = Task.detached(priority: .userInitiated) { [self] () -> TurnContext in
            let identity = cwd.flatMap { $0.isEmpty ? nil : resolveIdentity($0) }
            let commonDir = identity?.gitCommonDir
            let runs = commonDir.flatMap { try? index.liveRuns(repoCommonDir: $0, excludingRun: runId) } ?? []
            let others = runs.filter { $0.threadID != threadId }
            let taken = takeNotices(threadId: threadId)
            var similar: [SimilarWork] = []
            if (try? similarIndex.isFirstRun(ofThread: threadId)) == true {
                let scope = try? similarIndex.scope(ofThread: threadId)
                similar = (try? similarIndex.find(
                    request: request, excludingThread: threadId, repoCommonDir: commonDir,
                    workspaceID: scope?.workspaceID, botID: scope?.botID, now: now()
                )) ?? []
            }
            let block = ConcurrentWorkDirective.render(
                runs: others, notices: taken.map(\.notice), similar: similar, ownRoot: identity?.repoRoot, now: now()
            )
            return TurnContext(block: block, similar: similar, deliveredNoticeKeys: Set(taken.map(\.key)))
        }
        return await work.value
    }

    /// Drops the notices a started turn carried. A turn that never starts leaves them for the next one.
    public func commit(_ context: TurnContext, threadId: AgentThreadID) {
        guard !context.deliveredNoticeKeys.isEmpty else { return }
        lock.lock()
        pending[threadId] = pending[threadId]?.filter { !context.deliveredNoticeKeys.contains($0.key) }
        if (delivered[threadId]?.count ?? 0) > 500 { delivered[threadId] = nil }
        delivered[threadId, default: []].formUnion(context.deliveredNoticeKeys)
        if pending[threadId]?.isEmpty == true { pending[threadId] = nil }
        lock.unlock()
    }

    /// Similar work for a request in other conversations of `botID`, for the Bot delegation warning.
    public func similarWork(forBotRequest request: String, botID: BotID) async -> [SimilarWork] {
        let request = String(request.prefix(Self.maxRequestLength))
        return await Task.detached(priority: .userInitiated) { [self] in
            (try? similarIndex.find(
                request: request, excludingThread: nil, repoCommonDir: nil, workspaceID: nil,
                botID: botID.value.uuidString, now: now()
            )) ?? []
        }.value
    }

    /// A run recorded edits to `paths` (relative to `identity.repoRoot`). Every other live run in that checkout
    /// that already touched one of them gets a notice for its next turn.
    public func runEdited(runId: AgentRunID, threadId: AgentThreadID, identity: RunRepoIdentity, paths: [String]) {
        guard !paths.isEmpty,
              let all = try? index.liveRuns(repoCommonDir: identity.gitCommonDir) else { return }
        let editor = all.first { $0.runID == runId }
            .map { ConcurrentWorkDirective.label(title: $0.threadTitle, bot: $0.botName) } ?? "another run"
        let sameCheckout = all.filter { $0.runID != runId && $0.threadID != threadId && $0.worktreePath == identity.repoRoot }
        guard !sameCheckout.isEmpty else { return }
        let stamp = now()
        for other in sameCheckout {
            let owned = Set(other.editingFiles.map(\.path))
            for path in paths where owned.contains(path) {
                enqueue(ConcurrentWorkNotice(path: path, editor: editor, at: stamp), for: other.threadID, key: runId.description + "\u{0}" + path)
            }
        }
    }

    private func enqueue(_ notice: ConcurrentWorkNotice, for threadId: AgentThreadID, key: String) {
        lock.lock()
        defer { lock.unlock() }
        var list = pending[threadId] ?? []
        guard !list.contains(where: { $0.key == key }), delivered[threadId]?.contains(key) != true else { return }
        list.append(PendingNotice(key: key, notice: notice))
        if list.count > Self.maxPendingNoticesPerThread { list.removeFirst(list.count - Self.maxPendingNoticesPerThread) }
        pending[threadId] = list
    }

    private func takeNotices(threadId: AgentThreadID) -> [PendingNotice] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now().addingTimeInterval(-Self.noticeLifetime)
        let fresh = (pending[threadId] ?? []).filter { $0.notice.at >= cutoff }
        pending[threadId] = fresh.isEmpty ? nil : fresh
        return fresh
    }

    /// `base` plus the block, separated like every other turn-context addition. A block already in `base`
    /// (a retried request carries its earlier environment) is replaced, never doubled.
    public static func appending(_ block: String?, to base: String?) -> String? {
        var base = base
        if let open = base?.range(of: "<concurrent_work>"), let close = base?.range(of: "</concurrent_work>", range: open.upperBound..<base!.endIndex) {
            base?.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let trimmedBase = base?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = trimmedBase?.isEmpty == false ? trimmedBase : nil
        guard let block, !block.isEmpty else { return kept }
        guard let kept else { return block }
        return kept + "\n\n" + block
    }
}
