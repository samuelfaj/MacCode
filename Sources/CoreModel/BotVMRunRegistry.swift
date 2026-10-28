import Foundation

/// Tracks the runs on each bot's VM. Conversations run on one VM in parallel;
/// exclusive delegated runs and VM maintenance keep others out.
public final class BotVMRunRegistry: @unchecked Sendable {
    public static let shared = BotVMRunRegistry()

    public struct Entry: Equatable, Sendable {
        public let threadID: AgentThreadID
        public let runID: AgentRunID
        public let title: String
        public let workspace: String
        /// No other run may share the VM with this delegated run or maintenance.
        public let exclusive: Bool

        public init(threadID: AgentThreadID, runID: AgentRunID, title: String, workspace: String, exclusive: Bool = false) {
            self.threadID = threadID
            self.runID = runID
            self.title = title
            self.workspace = workspace
            self.exclusive = exclusive
        }
    }

    private let lock = NSLock()
    /// Every live claim on each VM, oldest first. Two starts on one thread
    /// (router + tab, iOS + Mac) both claim; releasing the unstarted one keeps
    /// the other.
    private var claims: [BotID: [Entry]] = [:]

    private struct Waiter {
        let botID: BotID
        let threadID: AgentThreadID
    }
    /// Threads queued behind an exclusive claim.
    private var waiting: [BotID: [Waiter]] = [:]
    public init() {}

    /// Claims the VM for `entry`; returns the other thread's claim in the way.
    /// A run is kept out only by an exclusive claim; an exclusive claim by any
    /// claim of another thread (its own thread's agent may rebuild mid-run).
    /// New guest runs disable that maintenance exception, even on the same thread.
    /// `parentRunID`: a delegated run shares the VM with the parent waiting on it.
    public func tryBegin(botID: BotID, entry: Entry, resourceID: BotID? = nil, allowsSameThreadExclusive: Bool = true,
                         parentRunID: AgentRunID? = nil) -> Entry? {
        let botID = resourceID ?? botID
        return lock.withLock {
            let held = claims[botID] ?? []
            if let holder = held.first(where: {
                ($0.exclusive || entry.exclusive) && $0.runID != entry.runID && $0.runID != parentRunID
                    && (!allowsSameThreadExclusive || $0.threadID != entry.threadID)
            }) {
                return holder
            }
            if let index = held.firstIndex(where: { $0.runID == entry.runID }) {
                claims[botID]?[index] = entry
            } else {
                claims[botID, default: []].append(entry)
            }
            return nil
        }
    }
    public func addWaiting(botID: BotID, threadID: AgentThreadID, resourceID: BotID? = nil) {
        lock.withLock {
            let key = resourceID ?? botID
            if waiting[key]?.contains(where: { $0.threadID == threadID }) != true {
                waiting[key, default: []].append(Waiter(botID: botID, threadID: threadID))
            }
        }
    }
    public func waitingThreads(botID: BotID, resourceID: BotID? = nil) -> [AgentThreadID] {
        lock.withLock { waiting[resourceID ?? botID]?.map(\.threadID) ?? [] }
    }
    /// The bot `threadID` waits for and the exclusive claim holding it; nil
    /// when the thread is not waiting or nothing exclusive holds the VM.
    public func waitingHolder(threadID: AgentThreadID) -> (botID: BotID, holder: Entry)? {
        lock.withLock {
            for (key, queue) in waiting {
                if let waiter = queue.first(where: { $0.threadID == threadID }),
                   let holder = claims[key]?.first(where: { $0.exclusive && $0.threadID != threadID }) {
                    return (waiter.botID, holder)
                }
            }
            return nil
        }
    }
    /// Pops the first thread queued for a VM no exclusive claim holds: a
    /// hand-off whose thread did not start passes it on.
    public func popWaitingIfFree(botID: BotID, resourceID: BotID? = nil) -> AgentThreadID? {
        let botID = resourceID ?? botID
        return lock.withLock {
            guard claims[botID]?.contains(where: \.exclusive) != true,
                  var queue = waiting[botID], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            waiting[botID] = queue.isEmpty ? nil : queue
            return next.threadID
        }
    }
    /// Frees the claim of `runID` and pops the first thread queued for its VM.
    /// nil while an exclusive claim still holds the VM.
    public func releaseAndNextWaiting(runID: AgentRunID) -> AgentThreadID? {
        releaseAndNextWaiter(runID: runID)?.threadID
    }

    /// `releaseAndNextWaiting` with the bot the next thread waited for.
    public func releaseAndNextWaiter(runID: AgentRunID) -> (botID: BotID, threadID: AgentThreadID)? {
        lock.withLock {
            guard let botID = claims.first(where: { $0.value.contains { $0.runID == runID } })?.key else { return nil }
            removeClaim(botID: botID, runID: runID)
            guard claims[botID]?.contains(where: \.exclusive) != true, var queue = waiting[botID], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            waiting[botID] = queue.isEmpty ? nil : queue
            return (next.botID, next.threadID)
        }
    }

    /// Removes `runID`'s claim. Caller holds `lock`.
    private func removeClaim(botID: BotID, runID: AgentRunID) {
        guard var held = claims[botID], let index = held.firstIndex(where: { $0.runID == runID }) else { return }
        held.remove(at: index)
        claims[botID] = held.isEmpty ? nil : held
    }

    public func begin(botID: BotID, entry: Entry) {
        lock.withLock { claims[botID] = [entry] }
    }

    /// Clears only `runID`'s claim, so a stale finish cannot drop a newer run.
    public func end(botID: BotID, runID: AgentRunID) {
        lock.withLock { removeClaim(botID: botID, runID: runID) }
    }

    public func endRun(runID: AgentRunID) {
        lock.withLock {
            for botID in Array(claims.keys) { removeClaim(botID: botID, runID: runID) }
        }
    }

    /// The oldest claim on the VM; nil when nothing runs on it.
    public func active(botID: BotID, resourceID: BotID? = nil) -> Entry? {
        lock.withLock { claims[resourceID ?? botID]?.first }
    }

    /// The oldest claim of `threadID` on the VM.
    public func claim(botID: BotID, threadID: AgentThreadID?, resourceID: BotID? = nil) -> Entry? {
        lock.withLock { claims[resourceID ?? botID]?.first { $0.threadID == threadID } }
    }

    /// The oldest claim of a thread other than `threadID` on the VM.
    public func otherClaim(botID: BotID, threadID: AgentThreadID?, resourceID: BotID? = nil) -> Entry? {
        lock.withLock { claims[resourceID ?? botID]?.first { $0.threadID != threadID } }
    }

    /// The exclusive claim keeping `threadID` off the VM.
    public func blocker(botID: BotID, threadID: AgentThreadID?, resourceID: BotID? = nil) -> Entry? {
        lock.withLock { claims[resourceID ?? botID]?.first { $0.exclusive && $0.threadID != threadID } }
    }

    public func busyMessage(botID: BotID, threadID: AgentThreadID, resourceID: BotID? = nil) -> String? {
        blocker(botID: botID, threadID: threadID, resourceID: resourceID).map { "The VM is busy in \($0.title)" }
    }
}
