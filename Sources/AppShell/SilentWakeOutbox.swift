import Foundation
import Persistence
import os

/// Durable record for a failed silent catch-up APNs send.
///
/// Retries must reuse the original `idempotencyKey`: the backend only caches a
/// result when `delivered` or `shouldDropSubscription` is true, so replaying a
/// failed attempt with the same key is always safe.
public struct SilentWakeOutboxRecord: Codable, Equatable, Sendable {
    public let coalesceClass: String
    public let hostHint: String
    public let force: Bool
    public let reason: String?
    public let watermark: String?
    public let sinceSeq: String?
    public let bootEpoch: String?
    public let idempotencyKey: String
    public let attempts: Int
    public let nextAttemptAt: Date?
    /// Wall-clock enqueue time for offline backlog age bounds.
    public let enqueuedAt: Date
    /// Bounded thread delta (`PushConnectionHints.delta`) of the original send,
    /// so a replay still tells the phone which thread changed and to which seq.
    /// Nil on records stored before the delta was kept.
    public let delta: [String: String]?

    public init(
        coalesceClass: MaterialWakeCoalesceClass,
        hostHint: String,
        force: Bool,
        payload: SilentCatchUpV1,
        idempotencyKey: String,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        enqueuedAt: Date = Date(),
        delta: [String: String] = [:]
    ) {
        self.coalesceClass = coalesceClass.rawValue
        self.hostHint = hostHint
        self.force = force
        self.reason = payload.reason
        self.watermark = payload.watermark
        self.sinceSeq = payload.sinceSeq
        self.bootEpoch = payload.bootEpoch
        self.idempotencyKey = idempotencyKey
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.enqueuedAt = enqueuedAt
        self.delta = delta.isEmpty ? nil : delta
    }

    public init(
        coalesceClass: String,
        hostHint: String,
        force: Bool,
        reason: String?,
        watermark: String?,
        sinceSeq: String?,
        bootEpoch: String?,
        idempotencyKey: String,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        enqueuedAt: Date = Date(),
        delta: [String: String] = [:]
    ) {
        self.coalesceClass = coalesceClass
        self.hostHint = hostHint
        self.force = force
        self.reason = reason
        self.watermark = watermark
        self.sinceSeq = sinceSeq
        self.bootEpoch = bootEpoch
        self.idempotencyKey = idempotencyKey
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.enqueuedAt = enqueuedAt
        self.delta = delta.isEmpty ? nil : delta
    }

    /// Unique per enqueued unit. Incorporates `idempotencyKey` so the identity
    /// changes on every supersession (keys already rotate per attempt/bucket).
    /// `acknowledge` / `recordFailure` must target this exact unit — never the
    /// coarser coalesce class, or a successful mid-flight send would delete a
    /// newer same-class row that replaced this one while it was in flight.
    public var recordID: String { idempotencyKey + "|" + coalesceClass }

    /// Concurrent-progress key only: at most one in-flight send per class.
    /// Same-class supersession also groups on this value; it is intentionally
    /// coarser than `recordID`.
    public var laneIdentity: String { coalesceClass }

    public var payload: SilentCatchUpV1 {
        SilentCatchUpV1(
            catchUp: true,
            watermark: watermark,
            sinceSeq: sinceSeq,
            bootEpoch: bootEpoch,
            reason: reason
        )
    }

    public var coalesceClassValue: MaterialWakeCoalesceClass {
        MaterialWakeCoalesceClass(rawValue: coalesceClass) ?? .other
    }
}

/// Shared silent-wake outbox policy (deadlines, lanes, backlog).
/// Mirrors `LiveActivityDeliveryPolicy` shape with quieter caps: silent wakes
/// coalesce to at most one pending unit per class, so count/byte budgets stay small.
public enum SilentWakeDeliveryPolicy: Sendable {
    public static let requestTimeoutSeconds: TimeInterval = 11
    /// One lane per coalesce class is enough; cap concurrent progress modestly.
    public static let maximumConcurrentLanes: Int = 4
    /// Pending records older than this are no longer actionable.
    public static let pendingRecordRetention: TimeInterval = 7 * 24 * 60 * 60
    /// Hard count cap after same-class supersession / age compaction.
    public static let pendingRecordCap: Int = 32
    /// Encoded snapshot budget; oldest non-protected rows drop first.
    public static let encodedByteCap: Int = 64 * 1024
    /// Slightly above the per-request URL deadline so adapter overhead cannot pin a lane.
    public static let sendTimeoutSeconds: TimeInterval = 12
}

public struct SilentWakeOutboxLimits: Equatable, Sendable {
    public let recordRetention: TimeInterval
    public let recordCap: Int
    public let encodedByteCap: Int

    public init(
        recordRetention: TimeInterval = SilentWakeDeliveryPolicy.pendingRecordRetention,
        recordCap: Int = SilentWakeDeliveryPolicy.pendingRecordCap,
        encodedByteCap: Int = SilentWakeDeliveryPolicy.encodedByteCap
    ) {
        self.recordRetention = max(0, recordRetention)
        self.recordCap = max(1, recordCap)
        self.encodedByteCap = max(1, encodedByteCap)
    }
}

public final class SilentWakeOutboxStore: @unchecked Sendable {
    private static let key = "silent_wake.outbox.v1"
    private static let log = Logger(
        subsystem: "io.remotecode.app",
        category: "silent-wake-outbox"
    )

    public static var pendingRecordRetention: TimeInterval {
        SilentWakeDeliveryPolicy.pendingRecordRetention
    }
    public static var pendingRecordCap: Int { SilentWakeDeliveryPolicy.pendingRecordCap }
    public static var encodedByteCap: Int { SilentWakeDeliveryPolicy.encodedByteCap }

    /// Result of a bounds compaction pass. Dropped rows are never treated as
    /// backend success (no invented acknowledgements).
    public struct CompactionReport: Equatable, Sendable {
        public let droppedRecords: Int

        public var didDrop: Bool { droppedRecords > 0 }
    }

    private let settings: SettingsRepository
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date
    private let limits: SilentWakeOutboxLimits

    public init(
        settings: SettingsRepository,
        now: @escaping () -> Date = { Date() },
        limits: SilentWakeOutboxLimits = SilentWakeOutboxLimits()
    ) {
        self.settings = settings
        self.now = now
        self.limits = limits
    }

    /// Enqueue a failed silent catch-up. Same-class pending work is superseded
    /// (newest payload/idempotency key wins). Bounded by age/count/bytes.
    @discardableResult
    public func enqueue(_ record: SilentWakeOutboxRecord) throws -> CompactionReport {
        try lock.withLock {
            var records = try loadUnlocked()
            let stamp = now()
            let incoming = SilentWakeOutboxRecord(
                coalesceClass: record.coalesceClass,
                hostHint: record.hostHint,
                force: record.force,
                reason: record.reason,
                watermark: record.watermark,
                sinceSeq: record.sinceSeq,
                bootEpoch: record.bootEpoch,
                idempotencyKey: record.idempotencyKey,
                attempts: 0,
                nextAttemptAt: nil,
                enqueuedAt: stamp,
                delta: record.delta ?? [:]
            )
            // Coalesce by class (lane), not unique recordID: only the newest
            // pending item per class needs to survive. recordID is per-unit so
            // it cannot be the supersession key.
            records.removeAll { $0.laneIdentity == incoming.laneIdentity }
            records.append(incoming)
            let report = Self.compactBacklog(
                &records,
                now: stamp,
                encoder: encoder,
                limits: limits
            )
            try saveUnlocked(records)
            return report
        }
    }

    public func pending() throws -> [SilentWakeOutboxRecord] {
        try lock.withLock { try loadUnlocked() }
    }

    /// Apply age/count/byte bounds without enqueueing new work (used on resume).
    @discardableResult
    public func compactBacklog() throws -> CompactionReport {
        try lock.withLock {
            var records = try loadUnlocked()
            let report = Self.compactBacklog(
                &records,
                now: now(),
                encoder: encoder,
                limits: limits
            )
            try saveUnlocked(records)
            return report
        }
    }

    func candidates() throws -> [SilentWakeOutboxRecord] {
        try lock.withLock { try loadUnlocked() }
    }

    func recordFailure(
        recordID: String,
        nextAttemptAt: Date
    ) throws -> SilentWakeOutboxRecord? {
        try lock.withLock {
            var records = try loadUnlocked()
            guard let index = records.firstIndex(where: { $0.recordID == recordID }) else {
                return nil
            }
            let existing = records[index]
            records[index] = SilentWakeOutboxRecord(
                coalesceClass: existing.coalesceClass,
                hostHint: existing.hostHint,
                force: existing.force,
                reason: existing.reason,
                watermark: existing.watermark,
                sinceSeq: existing.sinceSeq,
                bootEpoch: existing.bootEpoch,
                idempotencyKey: existing.idempotencyKey,
                attempts: existing.attempts + 1,
                nextAttemptAt: nextAttemptAt,
                enqueuedAt: existing.enqueuedAt,
                delta: existing.delta ?? [:]
            )
            try saveUnlocked(records)
            return records[index]
        }
    }

    func acknowledge(_ record: SilentWakeOutboxRecord) throws {
        try lock.withLock {
            var records = try loadUnlocked()
            records.removeAll { $0.recordID == record.recordID }
            try saveUnlocked(records)
        }
    }

    private func loadUnlocked() throws -> [SilentWakeOutboxRecord] {
        guard let json = try settings.get(Self.key),
              !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        do {
            return try decoder.decode([SilentWakeOutboxRecord].self, from: data)
        } catch {
            // A snapshot we cannot decode can never be acknowledged or retried,
            // and keeping it would fail every enqueue/candidates call forever.
            // Treat it as an empty backlog (no acknowledgement is invented) so
            // the next write persists a valid snapshot again.
            Self.log.error(
                "silent-wake outbox snapshot undecodable bytes=\(data.count, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private func saveUnlocked(_ records: [SilentWakeOutboxRecord]) throws {
        let data = try encoder.encode(records)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try settings.set(Self.key, json)
    }

    /// Compact same-class supersession is done at enqueue; this pass applies
    /// age/count/byte bounds. Oldest rows drop first. Dropped rows leave no ack.
    private static func compactBacklog(
        _ records: inout [SilentWakeOutboxRecord],
        now: Date,
        encoder: JSONEncoder,
        limits: SilentWakeOutboxLimits
    ) -> CompactionReport {
        let beforeBoundedDrops = records.count

        // 1) Hard age bound.
        let recordCutoff = now.addingTimeInterval(-limits.recordRetention)
        records.removeAll { $0.enqueuedAt < recordCutoff }

        // 2) Count cap: drop oldest first.
        records.sort { lhs, rhs in
            if lhs.enqueuedAt != rhs.enqueuedAt {
                return lhs.enqueuedAt < rhs.enqueuedAt
            }
            return lhs.recordID < rhs.recordID
        }
        while records.count > limits.recordCap {
            records.removeFirst()
        }

        // 3) Encoded-byte budget: drop oldest first.
        while encodedByteCount(records, encoder: encoder) > limits.encodedByteCap {
            guard !records.isEmpty else { break }
            records.removeFirst()
        }

        return CompactionReport(
            droppedRecords: max(0, beforeBoundedDrops - records.count)
        )
    }

    private static func encodedByteCount(
        _ records: [SilentWakeOutboxRecord],
        encoder: JSONEncoder
    ) -> Int {
        (try? encoder.encode(records).count) ?? Int.max
    }
}

public enum SilentWakeOutboxError: Error, Equatable {
    case notDelivered(String?)
    case missingSessionOrTarget
    case bridgeUnavailable
    /// Offline backlog exceeded age/count/byte bounds. Dropped work is never
    /// treated as backend success — records are removed without inventing acks.
    case backlogCompacted(droppedRecords: Int)
}

public final class SilentWakeOutbox: @unchecked Sendable {
    public typealias Now = @Sendable () -> Date
    public typealias RetryDelay = @Sendable (Int) -> TimeInterval
    public typealias Schedule = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    public typealias Send = @Sendable (SilentWakeOutboxRecord) async throws -> Void
    public typealias ErrorHandler = @Sendable (Error, SilentWakeOutboxRecord?) -> Void
    public typealias FlagEnabled = @Sendable () -> Bool

    private enum Command: @unchecked Sendable {
        case wake
        case flush(CheckedContinuation<Void, Never>)
    }

    private static let log = Logger(
        subsystem: "io.remotecode.app",
        category: "silent-wake-outbox"
    )
    private let store: SilentWakeOutboxStore
    private let onError: ErrorHandler
    private let isEnabled: FlagEnabled
    private let continuation: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?

    public init(
        store: SilentWakeOutboxStore,
        now: @escaping Now = { Date() },
        retryDelay: @escaping RetryDelay = { attempt in
            // Mirror LiveActivityAcceptanceOutbox: 1, 2, 4, … capped at 60s.
            min(60, pow(2, Double(max(0, attempt - 1))))
        },
        schedule: @escaping Schedule = { delay, callback in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0, delay),
                execute: callback
            )
        },
        maximumConcurrentLanes: Int = SilentWakeDeliveryPolicy.maximumConcurrentLanes,
        sendTimeout: TimeInterval = SilentWakeDeliveryPolicy.sendTimeoutSeconds,
        isEnabled: @escaping FlagEnabled = { ConnectionFeatureFlags.wakeOutboxEnabled },
        onError: @escaping ErrorHandler = { _, _ in },
        send: @escaping Send
    ) {
        self.store = store
        self.onError = onError
        self.isEnabled = isEnabled
        var capturedContinuation: AsyncStream<Command>.Continuation?
        let stream = AsyncStream<Command> { capturedContinuation = $0 }
        let commandContinuation = capturedContinuation!
        self.continuation = commandContinuation
        let scheduler = SilentWakeLaneScheduler(
            store: store,
            now: now,
            retryDelay: retryDelay,
            schedule: schedule,
            maximumConcurrentLanes: maximumConcurrentLanes,
            sendTimeout: sendTimeout,
            isEnabled: isEnabled,
            send: send,
            onError: onError
        )
        self.worker = Task {
            for await command in stream {
                switch command {
                case .wake:
                    await scheduler.wake()
                case .flush(let barrier):
                    await scheduler.flush()
                    barrier.resume()
                }
            }
            await scheduler.stop()
        }
    }

    deinit {
        continuation.finish()
        worker?.cancel()
    }

    /// Enqueue a failed silent catch-up and pump when the feature flag is on.
    /// Callers must only invoke this when `ConnectionFeatureFlags.wakeOutboxEnabled`
    /// is true (or inject a test `isEnabled` that returns true).
    public func accept(_ record: SilentWakeOutboxRecord) throws {
        guard isEnabled() else { return }
        let report = try store.enqueue(record)
        surfaceCompaction(report, record: record)
        continuation.yield(.wake)
    }

    public func resumePending() {
        guard isEnabled() else { return }
        do {
            surfaceCompaction(try store.compactBacklog(), record: nil)
        } catch {
            onError(error, nil)
        }
        continuation.yield(.wake)
    }

    public func flush() async {
        await withCheckedContinuation { barrier in
            continuation.yield(.flush(barrier))
        }
    }

    private func surfaceCompaction(
        _ report: SilentWakeOutboxStore.CompactionReport,
        record: SilentWakeOutboxRecord?
    ) {
        guard report.didDrop else { return }
        Self.log.info(
            "silent-wake backlog compacted droppedRecords=\(report.droppedRecords, privacy: .public)"
        )
        onError(
            SilentWakeOutboxError.backlogCompacted(droppedRecords: report.droppedRecords),
            record
        )
    }
}

private actor SilentWakeLaneScheduler {
    private enum SendOutcome: @unchecked Sendable {
        case settled
        case failed(Error)
    }

    /// One-shot race that lets the lane deadline win even if a test adapter or
    /// future transport ignores cooperative task cancellation.
    private final class SendRace: @unchecked Sendable {
        private let lock = NSLock()
        private var result: SendOutcome?
        private var continuation: CheckedContinuation<SendOutcome, Never>?
        private var tasks: [Task<Void, Never>] = []

        func install(_ continuation: CheckedContinuation<SendOutcome, Never>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func add(_ task: Task<Void, Never>) {
            lock.lock()
            if result == nil {
                tasks.append(task)
                lock.unlock()
            } else {
                lock.unlock()
                task.cancel()
            }
        }

        func resolve(_ result: SendOutcome) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            let tasks = self.tasks
            self.tasks.removeAll()
            lock.unlock()

            tasks.forEach { $0.cancel() }
            continuation?.resume(returning: result)
        }
    }

    private enum DeadlineError: Error {
        case exceeded
    }

    private let store: SilentWakeOutboxStore
    private let now: SilentWakeOutbox.Now
    private let retryDelay: SilentWakeOutbox.RetryDelay
    private let schedule: SilentWakeOutbox.Schedule
    private let maximumConcurrentLanes: Int
    private let sendTimeout: TimeInterval
    private let isEnabled: SilentWakeOutbox.FlagEnabled
    private let send: SilentWakeOutbox.Send
    private let onError: SilentWakeOutbox.ErrorHandler

    private var inFlight: [String: (recordID: String, task: Task<Void, Never>)] = [:]
    private var scheduled = Set<String>()
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false

    init(
        store: SilentWakeOutboxStore,
        now: @escaping SilentWakeOutbox.Now,
        retryDelay: @escaping SilentWakeOutbox.RetryDelay,
        schedule: @escaping SilentWakeOutbox.Schedule,
        maximumConcurrentLanes: Int,
        sendTimeout: TimeInterval,
        isEnabled: @escaping SilentWakeOutbox.FlagEnabled,
        send: @escaping SilentWakeOutbox.Send,
        onError: @escaping SilentWakeOutbox.ErrorHandler
    ) {
        self.store = store
        self.now = now
        self.retryDelay = retryDelay
        self.schedule = schedule
        self.maximumConcurrentLanes = max(1, maximumConcurrentLanes)
        self.sendTimeout = max(0.001, sendTimeout)
        self.isEnabled = isEnabled
        self.send = send
        self.onError = onError
    }

    func wake() {
        pump()
    }

    func retryReady(_ key: String) {
        scheduled.remove(key)
        pump()
    }

    func flush() async {
        pump()
        guard !inFlight.isEmpty else { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append(continuation)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for value in inFlight.values {
            value.task.cancel()
        }
        inFlight.removeAll()
        resumeFlushWaiters()
    }

    private func pump() {
        guard !stopped else {
            resumeFlushWaiters()
            return
        }
        // Kill switch: never drain when the feature flag is off.
        guard isEnabled() else {
            resumeFlushWaitersIfIdle()
            return
        }

        let candidates: [SilentWakeOutboxRecord]
        do {
            candidates = try store.candidates()
        } catch {
            onError(error, nil)
            resumeFlushWaitersIfIdle()
            return
        }

        let stamp = now()
        for candidate in candidates {
            guard let retryAt = candidate.nextAttemptAt, retryAt > stamp else { continue }
            let key = candidate.recordID
            if scheduled.insert(key).inserted {
                schedule(max(0, retryAt.timeIntervalSince(stamp))) { [weak self] in
                    Task { await self?.retryReady(key) }
                }
            }
        }

        let ready = candidates
            .filter { ($0.nextAttemptAt ?? .distantPast) <= stamp }
            .sorted { lhs, rhs in
                // Prefer force/boot, then older enqueues (FIFO within class).
                if lhs.force != rhs.force { return lhs.force && !rhs.force }
                if lhs.enqueuedAt != rhs.enqueuedAt {
                    return lhs.enqueuedAt < rhs.enqueuedAt
                }
                return lhs.recordID < rhs.recordID
            }
        for record in ready {
            guard inFlight.count < maximumConcurrentLanes else { break }
            let lane = record.laneIdentity
            guard inFlight[lane] == nil else { continue }
            start(record, lane: lane)
        }
        resumeFlushWaitersIfIdle()
    }

    private func start(_ record: SilentWakeOutboxRecord, lane: String) {
        let send = self.send
        let timeout = sendTimeout
        let task = Task { [weak self] in
            let outcome = await Self.performSend(record, timeout: timeout, send: send)
            await self?.finish(record, lane: lane, outcome: outcome)
        }
        inFlight[lane] = (record.recordID, task)
    }

    private func finish(
        _ record: SilentWakeOutboxRecord,
        lane: String,
        outcome: SendOutcome
    ) {
        guard !stopped,
              inFlight[lane]?.recordID == record.recordID else {
            return
        }
        inFlight.removeValue(forKey: lane)
        scheduled.remove(record.recordID)

        switch outcome {
        case .settled:
            do {
                try store.acknowledge(record)
            } catch {
                onError(error, record)
            }
        case .failed(let error):
            onError(error, record)
            let delay = retryDelay(record.attempts + 1)
            do {
                let failed = try store.recordFailure(
                    recordID: record.recordID,
                    nextAttemptAt: now().addingTimeInterval(delay)
                )
                if failed != nil, scheduled.insert(record.recordID).inserted {
                    let key = record.recordID
                    schedule(delay) { [weak self] in
                        Task { await self?.retryReady(key) }
                    }
                }
            } catch {
                onError(error, record)
            }
        }
        pump()
    }

    private static func performSend(
        _ record: SilentWakeOutboxRecord,
        timeout: TimeInterval,
        send: @escaping SilentWakeOutbox.Send
    ) async -> SendOutcome {
        let race = SendRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)

                let sendTask = Task {
                    do {
                        try await send(record)
                        race.resolve(.settled)
                    } catch {
                        race.resolve(.failed(error))
                    }
                }
                race.add(sendTask)

                let timeoutTask = Task {
                    let nanoseconds = UInt64(
                        min(Double(UInt64.max), timeout * 1_000_000_000)
                    )
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    race.resolve(.failed(DeadlineError.exceeded))
                }
                race.add(timeoutTask)
            }
        } onCancel: {
            race.resolve(.failed(CancellationError()))
        }
    }

    private func resumeFlushWaitersIfIdle() {
        guard inFlight.isEmpty else { return }
        resumeFlushWaiters()
    }

    private func resumeFlushWaiters() {
        let waiters = flushWaiters
        flushWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
