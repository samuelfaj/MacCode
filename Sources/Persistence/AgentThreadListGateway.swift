import Foundation
import CoreModel

/// Genuinely non-MainActor owner for connection-snapshot AgentThread list/decode.
///
/// Dispatcher and AppCommandRouter are `@MainActor`. This gateway serializes
/// SQLite list/decode on a dedicated queue so `sync.snapshot` never blocks the
/// main run loop during thread enumeration. Returns only immutable `Sendable`
/// threads.
///
/// Do not replace this with `DispatchQueue.global.sync` or a detached task that
/// races shared repository state — the queue owns the work, and `SQLiteDB`
/// already serializes connection use via FULLMUTEX + its operation lock.
public final class AgentThreadListGateway: @unchecked Sendable {
    private final class Operation<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var cancelled = false
        private var finished = false

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if cancelled || finished {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }

        func beginWork() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !cancelled && !finished
        }

        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    public static let queueLabel = "io.remotecode.agent-thread-list"

    private let queue: DispatchQueue
    private let db: SQLiteDB
    /// WAL reader: paired-device list reads must not wait on the writer.
    private let readDB: SQLiteDB

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

    public init(db: SQLiteDB, readDB: SQLiteDB? = nil) {
        self.db = db
        self.readDB = readDB ?? db
        self.queue = DispatchQueue(label: Self.queueLabel, qos: .userInitiated)
    }

    /// Full AgentThread list for connection snapshot grouping.
    /// Always hops to the gateway queue — never runs query/decode on MainActor.
    public func list(workspaceId: WorkspaceID? = nil) async throws -> [AgentThread] {
        let operation = Operation<[AgentThread]>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AgentThread], Error>) in
                operation.install(continuation)
                queue.async {
                    guard operation.beginWork() else { return }
                Self.recordQueryExecutorForTesting()
                Self.queryWillRunForTesting?()
                let delay = Self.queryDelayNanosecondsForTesting
                if delay > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000)
                }
                guard operation.beginWork() else { return }
                do {
                    let threads = try AgentThreadRepository(db: self.db, readDB: self.readDB)
                        .list(workspaceId: workspaceId)
                    operation.finish(.success(threads))
                } catch {
                    operation.finish(.failure(error))
                }
            }
            }
        }, onCancel: {
            operation.cancel()
        })
    }

    /// Guest runtime marker per thread, read on the same connection as `list`.
    public func guestRuntimesByThread() async throws -> [AgentThreadID: String] {
        let operation = Operation<[AgentThreadID: String]>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AgentThreadID: String], Error>) in
                operation.install(continuation)
                queue.async {
                    guard operation.beginWork() else { return }
                    do {
                        let runtimes = try self.readDB.performSync { _ in
                            try AgentThreadRepository(db: self.readDB).guestRuntimesByThread()
                        }
                        operation.finish(.success(runtimes))
                    } catch {
                        operation.finish(.failure(error))
                    }
                }
            }
        }, onCancel: {
            operation.cancel()
        })
    }

    /// Returns only workspaces with a running thread. This is the cheap
    /// workspace-list projection path; it deliberately avoids decoding every
    /// thread and its routing JSON when the caller only needs busy IDs.
    public func runningWorkspaceIDs(in workspaceIDs: [WorkspaceID]) async throws -> Set<WorkspaceID> {
        guard !workspaceIDs.isEmpty else { return [] }
        let operation = Operation<Set<WorkspaceID>>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Set<WorkspaceID>, Error>) in
                operation.install(continuation)
                queue.async {
                    guard operation.beginWork() else { return }
                    Self.recordQueryExecutorForTesting()
                    Self.queryWillRunForTesting?()
                    let delay = Self.queryDelayNanosecondsForTesting
                    if delay > 0 {
                        Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000)
                    }
                    guard operation.beginWork() else { return }
                    do {
                        let placeholders = workspaceIDs.map { _ in "?" }.joined(separator: ",")
                        let result = try self.readDB.performSync { database in
                            let statement = try database.prepare(
                                "SELECT DISTINCT workspace_id FROM agent_threads WHERE workspace_id IN (\(placeholders)) AND status = 'running';"
                            )
                            for (index, workspaceID) in workspaceIDs.enumerated() {
                                try statement.bind(Int32(index + 1), workspaceID.value.uuidString)
                            }
                            var result = Set<WorkspaceID>()
                            while try statement.step() {
                                if let raw = statement.columnText(0),
                                   let uuid = UUID(uuidString: raw) {
                                    result.insert(WorkspaceID(uuid))
                                }
                            }
                            return result
                        }
                        operation.finish(.success(result))
                    } catch {
                        operation.finish(.failure(error))
                    }
                }
            }
        }, onCancel: {
            operation.cancel()
        })
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
