import Foundation

/// What a pre-edit lease conflict does: `warn` lets the edit through and tells the agent, `block` refuses it.
public enum FileLeaseMode: String, Codable, Sendable, CaseIterable {
    case warn, block
}

/// What a new `.local` run does when another live run is already editing in the same checkout.
public enum LocalRunConflictPolicy: String, Codable, Sendable, CaseIterable {
    case warn, autoWorktree, ask
}

/// The run that currently owns a file lease, with what a conflict message needs to name it.
public struct FileLeaseHolder: Codable, Sendable, Equatable {
    public let runID: AgentRunID
    public let threadID: AgentThreadID
    public let threadTitle: String
    /// "@handle" (or the Bot's name) when a Bot conversation owns the thread.
    public let botLabel: String?
    /// When the holder first took the lease; renewals keep it.
    public var since: Date

    public init(runID: AgentRunID, threadID: AgentThreadID, threadTitle: String, botLabel: String?, since: Date) {
        self.runID = runID
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.botLabel = botLabel
        self.since = since
    }
}

public struct FileLease: Sendable, Equatable {
    public let repoRoot: String
    /// Relative to `repoRoot`.
    public let path: String
    public let holder: FileLeaseHolder
    public let expiresAt: Date
}

/// In-memory (checkout, path) -> run leases. A lease lasts `ttl` and each edit by its holder renews it;
/// the host releases a run's leases when its turn ends. A held lease is never taken over by another run.
public final class FileLeaseStore: @unchecked Sendable {
    public static let ttl: TimeInterval = 10 * 60

    public enum Outcome: Equatable, Sendable {
        case granted
        case heldByOther(FileLeaseHolder)
    }

    private struct Key: Hashable {
        let repoRoot: String
        let path: String
    }

    private var leases: [Key: FileLease] = [:]
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// The live holder of a file when it is not `runID`, without taking or renewing anything.
    public func conflict(repoRoot: String, path: String, runID: AgentRunID) -> FileLeaseHolder? {
        lock.lock(); defer { lock.unlock() }
        guard let lease = liveLease(Key(repoRoot: repoRoot, path: path)), lease.holder.runID != runID else { return nil }
        return lease.holder
    }

    /// True when `runID` already holds a live lease on the file.
    public func holds(repoRoot: String, path: String, runID: AgentRunID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveLease(Key(repoRoot: repoRoot, path: path))?.holder.runID == runID
    }

    /// Takes a free lease or renews the caller's own. Another run's live lease is reported, never replaced.
    @discardableResult
    public func acquire(repoRoot: String, path: String, holder: FileLeaseHolder) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        let key = Key(repoRoot: repoRoot, path: path)
        let current = now()
        if let existing = liveLease(key) {
            guard existing.holder.runID == holder.runID else { return .heldByOther(existing.holder) }
            leases[key] = FileLease(repoRoot: repoRoot, path: path, holder: existing.holder, expiresAt: current.addingTimeInterval(Self.ttl))
            return .granted
        }
        var fresh = holder
        fresh.since = current
        leases[key] = FileLease(repoRoot: repoRoot, path: path, holder: fresh, expiresAt: current.addingTimeInterval(Self.ttl))
        return .granted
    }

    /// Takes every free file for `holder` (and renews the ones it already holds) in one step, so two runs that edit
    /// the same file at the same moment cannot both win. Returns the files another run holds, with their holders.
    /// `allOrNothing` leaves every file untouched when any is held by another run.
    public func acquireAll(
        repoRoot: String, paths: [String], holder: FileLeaseHolder, allOrNothing: Bool
    ) -> (taken: Int, conflicts: [(path: String, holder: FileLeaseHolder)]) {
        lock.lock(); defer { lock.unlock() }
        let current = now()
        var conflicts: [(path: String, holder: FileLeaseHolder)] = []
        for path in paths {
            if let lease = liveLease(Key(repoRoot: repoRoot, path: path)), lease.holder.runID != holder.runID {
                conflicts.append((path, lease.holder))
            }
        }
        if allOrNothing && !conflicts.isEmpty { return (0, conflicts) }
        let blocked = Set(conflicts.map(\.path))
        var taken = 0
        for path in paths where !blocked.contains(path) {
            let key = Key(repoRoot: repoRoot, path: path)
            let since = liveLease(key)?.holder.since ?? current
            var owner = holder
            owner.since = since
            if leases[key] == nil { taken += 1 }
            leases[key] = FileLease(repoRoot: repoRoot, path: path, holder: owner, expiresAt: current.addingTimeInterval(Self.ttl))
        }
        return (taken, conflicts)
    }

    /// Drops every lease of a finished run and returns how many it held.
    @discardableResult
    public func release(runID: AgentRunID) -> Int {
        lock.lock(); defer { lock.unlock() }
        let owned = leases.filter { $0.value.holder.runID == runID }.map(\.key)
        for key in owned { leases.removeValue(forKey: key) }
        return owned.count
    }

    /// Live leases, optionally narrowed to one checkout.
    public func activeLeases(repoRoot: String? = nil) -> [FileLease] {
        lock.lock(); defer { lock.unlock() }
        purgeExpired()
        return leases.values.filter { repoRoot == nil || $0.repoRoot == repoRoot }
            .sorted { ($0.holder.since, $0.path) < ($1.holder.since, $1.path) }
    }

    private func liveLease(_ key: Key) -> FileLease? {
        guard let lease = leases[key] else { return nil }
        guard lease.expiresAt > now() else {
            leases.removeValue(forKey: key)
            return nil
        }
        return lease
    }

    private func purgeExpired() {
        let current = now()
        for (key, lease) in leases where lease.expiresAt <= current { leases.removeValue(forKey: key) }
    }
}

public enum FileLeaseMessage {
    /// What the agent reads when its edit meets another run's lease.
    public static func conflict(path: String, holder: FileLeaseHolder, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(holder.since) / 60))
        let duration = minutes == 0 ? "under 1 min" : "\(minutes) min"
        let title = holder.threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = title.isEmpty ? "Untitled" : title
        let bot = holder.botLabel.map { " (Bot \($0))" } ?? ""
        return "`\(path)` is being edited by thread '\(thread)'\(bot) for \(duration). Edit another file, wait, or use a worktree."
    }
}

extension Notification.Name {
    /// Posted when the set of leased files changed, so open Agent surfaces refresh their "also editing" notice.
    public static let concurrentWorkDidChange = Notification.Name("concurrentWorkDidChange")
}

/// What an Agent surface shows about other runs editing in its checkout.
public struct ConcurrentWorkSnapshot: Equatable, Sendable {
    /// Live runs, other than the surface's own thread, editing at least one file in this checkout.
    public var runs: [ConcurrentRunSummary]
    /// The surface's directory relative to the checkout root ("" at the root, otherwise ends with "/").
    public var cwdPrefix: String

    public static let empty = ConcurrentWorkSnapshot(runs: [], cwdPrefix: "")

    public init(runs: [ConcurrentRunSummary], cwdPrefix: String = "") {
        self.runs = runs
        self.cwdPrefix = cwdPrefix
    }

    /// Who is editing `path`. Git lists untracked files relative to the surface directory and the rest relative
    /// to the checkout root, so both spellings are tried.
    public func holders(of path: String) -> [ConcurrentRunSummary] {
        runs.filter { run in run.editingFiles.contains { $0.path == path || $0.path == cwdPrefix + path } }
    }

    public func label(for run: ConcurrentRunSummary) -> String {
        let title = run.threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? run.objective : title
        return run.botName.map { "\(name) · \($0)" } ?? name
    }
}

/// How an Agent surface reaches the host's view of concurrent work without depending on the app shell.
public final class ConcurrentWorkFeed: @unchecked Sendable {
    public static let shared = ConcurrentWorkFeed()

    public typealias Provider = @Sendable (_ cwd: String, _ excludingThread: AgentThreadID?) -> ConcurrentWorkSnapshot

    private let lock = NSLock()
    private var storedProvider: Provider?

    public var provider: Provider? {
        get { lock.lock(); defer { lock.unlock() }; return storedProvider }
        set { lock.lock(); storedProvider = newValue; lock.unlock() }
    }
}
