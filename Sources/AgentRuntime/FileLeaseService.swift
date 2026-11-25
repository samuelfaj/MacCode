import CoreModel
import Foundation

/// The answer to "may this run edit these files now?".
public enum PreEditVerdict: Equatable, Sendable {
    case allow
    /// The edit may go ahead; the text tells the agent which file another run is editing.
    case warn(String)
    /// The edit must not happen; the text tells the agent why.
    case deny(String)

    public var message: String? {
        switch self {
        case .allow: return nil
        case .warn(let text), .deny(let text): return text
        }
    }
}

/// Provider adapters ask this before an edit tool runs.
public protocol PreEditChecking: AnyObject, Sendable {
    /// `enforce` false is the after-the-fact check (the provider already edited): a conflict never denies.
    func checkEdit(threadId: AgentThreadID, paths: [String], cwd: String?, enforce: Bool) async -> PreEditVerdict
}

/// Something the user should hear about without the agent's help.
public struct FileLeaseNotice: Sendable, Equatable {
    public enum Kind: String, Sendable { case conflictWarned, leaseDenied, staleWriteRefused }

    public let kind: Kind
    public let runID: AgentRunID
    public let threadID: AgentThreadID
    public let path: String
    /// The agent-facing text (English).
    public let message: String
    /// The run that holds the file; nil for a refused stale write.
    public let holder: FileLeaseHolder?
}

/// Turns one run's edits into file leases. Holds each run's checkout identity (resolved once, off the caller's
/// thread), applies the warn/block setting and reports conflicts the user should see.
public final class FileLeaseService: PreEditChecking, @unchecked Sendable {
    public typealias IdentityResolver = @Sendable (_ cwd: String) -> RunRepoIdentity?
    public typealias Describer = @Sendable (_ threadID: AgentThreadID) -> (title: String, botLabel: String?)

    private struct RunState {
        let threadID: AgentThreadID
        let cwd: String
        let identity: Task<RunRepoIdentity?, Never>
    }

    public let store: FileLeaseStore
    /// Called once per (run, file, kind) while a lease lives, never on the caller's critical path.
    public var onNotice: (@Sendable (FileLeaseNotice) -> Void)?
    /// Called after the leased files changed (a lease taken or a run's leases released).
    public var onChange: (@Sendable () -> Void)?

    private let mode: @Sendable () -> FileLeaseMode
    private let describe: Describer
    private let resolveIdentity: IdentityResolver
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var runs: [AgentRunID: RunState] = [:]
    private var reported = Set<String>()

    public init(
        store: FileLeaseStore = FileLeaseStore(),
        mode: @escaping @Sendable () -> FileLeaseMode = { .warn },
        describe: @escaping Describer = { _ in ("", nil) },
        resolveIdentity: @escaping IdentityResolver = { GitDiff.repoIdentity(in: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.mode = mode
        self.describe = describe
        self.resolveIdentity = resolveIdentity
        self.now = now
    }

    /// Registers a run and starts the one identity probe. Later calls for the same run are ignored.
    public func begin(runId: AgentRunID, threadId: AgentThreadID, cwd: String?) {
        guard let cwd, !cwd.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard runs[runId] == nil else { return }
        let resolve = resolveIdentity
        runs[runId] = RunState(threadID: threadId, cwd: cwd, identity: Task.detached(priority: .utility) { resolve(cwd) })
    }

    /// The run's turn ended or the run died: its leases free up.
    public func end(runId: AgentRunID) {
        lock.lock()
        runs.removeValue(forKey: runId)
        reported = reported.filter { !$0.hasPrefix(runId.description + "|") }
        lock.unlock()
        if store.release(runID: runId) > 0 { onChange?() }
    }

    public func checkEdit(threadId: AgentThreadID, paths: [String], cwd: String?, enforce: Bool) async -> PreEditVerdict {
        lock.lock()
        let runId = runs.first { $0.value.threadID == threadId }?.key
        lock.unlock()
        guard let runId else { return .allow }
        return await checkEdit(runId: runId, paths: paths, cwd: cwd, enforce: enforce)
    }

    public func checkEdit(runId: AgentRunID, paths: [String], cwd: String?, enforce: Bool) async -> PreEditVerdict {
        lock.lock()
        let state = runs[runId]
        lock.unlock()
        // An unknown run or a checkout outside git has nothing to protect: never get in the way.
        guard let state, let identity = await state.identity.value else { return .allow }
        let base = cwd.flatMap { $0.isEmpty ? nil : $0 } ?? state.cwd
        var seen = Set<String>()
        let relative = paths.compactMap { RunFileTouchPaths.relativize(path: $0, repoRoot: identity.repoRoot, cwd: base) }
            .filter { seen.insert($0).inserted }
        let current = now()
        var conflicts: [(path: String, message: String, holder: FileLeaseHolder)] = []
        for path in relative {
            if let holder = store.conflict(repoRoot: identity.repoRoot, path: path, runID: runId) {
                conflicts.append((path, FileLeaseMessage.conflict(path: path, holder: holder, now: current), holder))
            }
        }
        let denies = enforce && mode() == .block && !conflicts.isEmpty
        if !denies, !relative.isEmpty {
            let described = describe(state.threadID)
            let holder = FileLeaseHolder(runID: runId, threadID: state.threadID, threadTitle: described.title, botLabel: described.botLabel, since: current)
            var tookNew = false
            for path in relative {
                if store.conflict(repoRoot: identity.repoRoot, path: path, runID: runId) == nil,
                   !store.holds(repoRoot: identity.repoRoot, path: path, runID: runId) { tookNew = true }
                store.acquire(repoRoot: identity.repoRoot, path: path, holder: holder)
            }
            if tookNew { onChange?() }
        }
        guard !conflicts.isEmpty else { return .allow }
        let text = conflicts.map(\.message).joined(separator: "\n")
        for conflict in conflicts {
            notify(denies ? .leaseDenied : .conflictWarned, state: state, runId: runId, path: conflict.path, message: conflict.message, holder: conflict.holder)
        }
        return denies ? .deny(text) : .warn(text)
    }

    /// Reports a refused stale write once per file and run.
    public func reportStaleWrite(runId: AgentRunID, path: String?, message: String) {
        lock.lock()
        let state = runs[runId]
        lock.unlock()
        guard let state else { return }
        notify(.staleWriteRefused, state: state, runId: runId, path: path ?? "", message: message, holder: nil)
    }

    private func notify(_ kind: FileLeaseNotice.Kind, state: RunState, runId: AgentRunID, path: String, message: String, holder: FileLeaseHolder?) {
        // A refusal still reaches the user after a warning for the same file; a warning never repeats a refusal.
        let prefix = "\(runId.description)|"
        let conflictKey = prefix + "conflict|" + path
        lock.lock()
        let isNew: Bool
        switch kind {
        case .conflictWarned: isNew = reported.insert(conflictKey).inserted
        case .leaseDenied:
            reported.insert(conflictKey)
            isNew = reported.insert(prefix + "denied|" + path).inserted
        case .staleWriteRefused: isNew = reported.insert(prefix + "stale|" + path).inserted
        }
        lock.unlock()
        guard isNew else { return }
        onNotice?(FileLeaseNotice(kind: kind, runID: runId, threadID: state.threadID, path: path, message: message, holder: holder))
    }
}

/// Distill's refusal of a write over a file that changed since the session last read it.
public enum StaleWriteRefusal {
    public static func message(in toolOutput: String) -> String? {
        toolOutput.split(separator: "\n").first { $0.contains("changed since") }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
