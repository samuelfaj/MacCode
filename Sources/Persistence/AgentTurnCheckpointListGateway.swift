import Foundation
import CoreModel

/// Genuinely non-MainActor owner for checkpoint list SQLite query/decode.
///
/// Dispatcher and AppCommandRouter are `@MainActor`. This gateway serializes
/// list work on a dedicated queue so SQLite query/decode and snapshot freeze
/// never block the main run loop. Returns only immutable `Sendable` pages.
///
/// Do not replace this with `DispatchQueue.global.sync` or a detached task that
/// races shared repository state — the queue owns the work, and `SQLiteDB`
/// already serializes connection use via FULLMUTEX + its operation lock.
public final class AgentTurnCheckpointListGateway: @unchecked Sendable {
    public static let queueLabel = "io.remotecode.agent-turn-checkpoint-list"

    private let queue: DispatchQueue
    private let db: SQLiteDB

    // MARK: - Test probes (executor proof, not latency alone)

    /// Invoked on the list queue immediately before SQLite work (tests inject delay).
    nonisolated(unsafe) public static var queryWillRunForTesting: (() -> Void)?
    /// Extra sleep on the list queue (nanoseconds). MainActor heartbeat tests use this.
    nonisolated(unsafe) public static var queryDelayNanosecondsForTesting: UInt64 = 0
    nonisolated(unsafe) public static private(set) var queryCallCountForTesting: Int = 0
    nonisolated(unsafe) public static private(set) var queryOnMainActorCountForTesting: Int = 0
    nonisolated(unsafe) public static private(set) var queryOffMainActorCountForTesting: Int = 0

    public static func resetExecutionProbesForTesting() {
        queryWillRunForTesting = nil
        queryDelayNanosecondsForTesting = 0
        queryCallCountForTesting = 0
        queryOnMainActorCountForTesting = 0
        queryOffMainActorCountForTesting = 0
    }

    public init(db: SQLiteDB) {
        self.db = db
        self.queue = DispatchQueue(label: Self.queueLabel, qos: .userInitiated)
    }

    /// Metadata page for `agent.checkpoint.list` response_version 1.
    /// Always hops to the gateway queue — never runs query/decode on MainActor.
    public func listMetadataPage(
        threadId: AgentThreadID,
        maxEntries: Int,
        before cursor: AgentTurnCheckpointCursor?,
        expectedCatalogRevision: Int64? = nil
    ) async throws -> AgentTurnCheckpointPage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                Self.recordQueryExecutorForTesting()
                Self.queryWillRunForTesting?()
                let delay = Self.queryDelayNanosecondsForTesting
                if delay > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000)
                }
                do {
                    let page = try AgentTurnCheckpointRepository(db: self.db)
                        .listMetadataPage(
                            threadId: threadId,
                            maxEntries: maxEntries,
                            before: cursor,
                            expectedCatalogRevision: expectedCatalogRevision
                        )
                    continuation.resume(returning: page)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Legacy full-row list (`agent.checkpoint.list` without response_version).
    /// Same queue as the metadata page so the blob read never runs on MainActor.
    public func listFull(threadId: AgentThreadID) async throws -> [AgentTurnCheckpointSummary] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                Self.recordQueryExecutorForTesting()
                Self.queryWillRunForTesting?()
                let delay = Self.queryDelayNanosecondsForTesting
                if delay > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000)
                }
                do {
                    let rows = try AgentTurnCheckpointRepository(db: self.db).list(threadId: threadId)
                    continuation.resume(returning: rows)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func recordQueryExecutorForTesting() {
        queryCallCountForTesting += 1
        if Thread.isMainThread {
            queryOnMainActorCountForTesting += 1
        } else {
            queryOffMainActorCountForTesting += 1
        }
    }
}
