import Foundation
import Persistence
import os

public struct PrivateLiveActivityV2DeliveryAck: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let attempts: Int
    public let nextAttemptAt: String?
    public let accepted: Bool?

    public init(id: String, status: String, attempts: Int, nextAttemptAt: String?, accepted: Bool? = nil) {
        self.id = id
        self.status = status
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.accepted = accepted
    }

    public var isAccepted: Bool {
        ["pending", "queued", "processing", "delivered"].contains(status)
    }

    /// Backend-settled outcomes that must not be retried. They do not prove
    /// delivery, but they do prove this exact token/unit cannot make progress.
    public var isTerminal: Bool {
        ["permanent", "superseded"].contains(status)
    }

    public var isSettled: Bool {
        isAccepted || isTerminal
    }

    private enum CodingKeys: String, CodingKey { case id, status, attempts, nextAttemptAt, accepted }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        status = try values.decode(String.self, forKey: .status)
        attempts = try values.decode(Int.self, forKey: .attempts)
        accepted = try values.decodeIfPresent(Bool.self, forKey: .accepted)
        if let string = try? values.decodeIfPresent(String.self, forKey: .nextAttemptAt) {
            nextAttemptAt = string
        } else if let number = try? values.decode(Double.self, forKey: .nextAttemptAt) {
            nextAttemptAt = String(number)
        } else {
            nextAttemptAt = nil
        }
    }
}

public enum LiveActivityAcceptanceTarget: Codable, Equatable, Sendable {
    case v2(PrivatePushTargetRecord)
    case legacy(PrivatePushTarget)

    var unitIdentity: String {
        switch self {
        case .v2(let target):
            return Self.identity([
                "v2",
                target.serverId,
                target.deviceId,
                target.environment.rawValue,
                target.purpose.rawValue,
                target.activityId ?? "",
                target.bootEpoch.map(String.init) ?? "",
                target.activityGeneration.map(String.init) ?? "",
                target.activitySessionId ?? "",
                target.token,
            ])
        case .legacy(let target):
            return Self.identity([
                "legacy",
                target.deviceId ?? "unknown",
                target.pushTokenType,
                target.liveActivityToken ?? "",
            ])
        }
    }

    /// Concurrent-progress key. This app owns one `active-threads` activity
    /// stream per paired device/server/environment. Every token and lifecycle
    /// generation in that stream stays serialized, while another device or
    /// environment can progress independently. Purpose, ActivityKit instance
    /// ID, generation, session, and token are intentionally excluded: all may
    /// rotate between a start and its terminal barrier.
    var laneIdentity: String {
        switch self {
        case .v2(let target):
            return Self.identity([
                "v2-lane",
                "active-threads",
                target.serverId,
                target.deviceId,
                target.environment.rawValue,
            ])
        case .legacy(let target):
            return Self.identity([
                "legacy-lane",
                "active-threads",
                target.deviceId ?? "unknown",
                target.pushTokenType,
            ])
        }
    }

    private static func identity(_ parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

public struct LiveActivityAcceptanceRecord: Codable, Equatable, Sendable {
    public let delivery: LiveActivitySyncDelivery
    public let target: LiveActivityAcceptanceTarget
    public let attempts: Int
    public let nextAttemptAt: Date?
    /// Wall-clock enqueue time for offline backlog age bounds.
    public let enqueuedAt: Date

    public init(
        delivery: LiveActivitySyncDelivery,
        target: LiveActivityAcceptanceTarget,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        enqueuedAt: Date = Date()
    ) {
        self.delivery = delivery
        self.target = target
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.enqueuedAt = enqueuedAt
    }

    private enum CodingKeys: String, CodingKey {
        case delivery, target, attempts, nextAttemptAt, enqueuedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        delivery = try values.decode(LiveActivitySyncDelivery.self, forKey: .delivery)
        target = try values.decode(LiveActivityAcceptanceTarget.self, forKey: .target)
        attempts = try values.decode(Int.self, forKey: .attempts)
        nextAttemptAt = try values.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        enqueuedAt = try values.decodeIfPresent(Date.self, forKey: .enqueuedAt)
            ?? Date(timeIntervalSince1970: delivery.projection.updatedAt)
    }

    var recordID: String { delivery.idempotencyKey + "|" + target.unitIdentity }
}

/// Shared Live Activity HTTPS / outbox policy (deadlines, lanes, backlog).
public enum LiveActivityDeliveryPolicy: Sendable {
    /// Live Activity v2 delivery, legacy delivery, and v2 token registration
    /// share the same 10–12s request deadline band.
    public static let requestTimeoutSeconds: TimeInterval = 11
    /// Independent device/environment lanes may progress together; each lane
    /// still serializes its own lifecycle.
    public static let maximumConcurrentLanes: Int = 4
    /// Pending acceptance records older than this are no longer actionable.
    public static let pendingRecordRetention: TimeInterval = 7 * 24 * 60 * 60
    /// Hard count cap after superseded/age compaction.
    public static let pendingRecordCap: Int = 256
    /// Encoded snapshot budget; superseded work is compacted before current/end.
    public static let encodedByteCap: Int = 256 * 1024
    /// The outbox deadline is slightly above the per-request URL deadline so
    /// refresh/adapter overhead cannot pin a lane indefinitely.
    public static let sendTimeoutSeconds: TimeInterval = 12
}

public struct LiveActivityAcceptanceOutboxLimits: Equatable, Sendable {
    public let recordRetention: TimeInterval
    public let recordCap: Int
    public let encodedByteCap: Int

    public init(
        recordRetention: TimeInterval = LiveActivityDeliveryPolicy.pendingRecordRetention,
        recordCap: Int = LiveActivityDeliveryPolicy.pendingRecordCap,
        encodedByteCap: Int = LiveActivityDeliveryPolicy.encodedByteCap
    ) {
        self.recordRetention = max(0, recordRetention)
        self.recordCap = max(1, recordCap)
        self.encodedByteCap = max(1, encodedByteCap)
    }
}

public final class LiveActivityAcceptanceOutboxStore: @unchecked Sendable {
    private static let key = "live_activity.acceptance_outbox.v1"
    private static let log = Logger(
        subsystem: "io.remotecode.app",
        category: "live-activity-acceptance"
    )

    public static var pendingRecordRetention: TimeInterval {
        LiveActivityDeliveryPolicy.pendingRecordRetention
    }
    public static var pendingRecordCap: Int { LiveActivityDeliveryPolicy.pendingRecordCap }
    public static var encodedByteCap: Int { LiveActivityDeliveryPolicy.encodedByteCap }

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
    private let limits: LiveActivityAcceptanceOutboxLimits

    public init(
        settings: SettingsRepository,
        now: @escaping () -> Date = { Date() },
        limits: LiveActivityAcceptanceOutboxLimits = LiveActivityAcceptanceOutboxLimits()
    ) {
        self.settings = settings
        self.now = now
        self.limits = limits
    }

    @discardableResult
    public func enqueue(
        _ delivery: LiveActivitySyncDelivery,
        targets: [LiveActivityAcceptanceTarget]
    ) throws -> CompactionReport {
        try lock.withLock {
            var records = try loadUnlocked()
            let stamp = now()
            for target in targets {
                let incoming = LiveActivityAcceptanceRecord(
                    delivery: delivery,
                    target: target,
                    enqueuedAt: stamp
                )
                guard !records.contains(where: { $0.recordID == incoming.recordID }) else { continue }
                if delivery.event == .update {
                    records.removeAll {
                        $0.target.laneIdentity == target.laneIdentity &&
                        $0.delivery.event == .update &&
                        Self.isSameSession($0.delivery, delivery)
                    }
                }
                records.append(incoming)
            }
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

    public func pending() throws -> [LiveActivityAcceptanceRecord] {
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

    func candidates() throws -> [LiveActivityAcceptanceRecord] {
        try lock.withLock {
            let records = try loadUnlocked()
            let groups = Dictionary(grouping: records, by: { $0.target.laneIdentity })
            return groups.values.compactMap { lane -> LiveActivityAcceptanceRecord? in
                guard let oldestSession = lane.min(by: {
                    Self.isOrderedBefore($0.delivery, $1.delivery)
                }) else { return nil }
                // Single pass over the lane: oldest session's terminal (max
                // revision), start (min revision), and overall max. Strict
                // comparisons keep filter+max (last maximal) / filter+min
                // (first minimal) tie behavior; no filter intermediates.
                var terminal: LiveActivityAcceptanceRecord?
                var start: LiveActivityAcceptanceRecord?
                var overall: LiveActivityAcceptanceRecord?
                for record in lane where Self.isSameSession(record.delivery, oldestSession.delivery) {
                    let revision = record.delivery.projection.revision
                    if record.delivery.event == .end,
                       terminal.map({ $0.delivery.projection.revision < revision }) ?? true {
                        terminal = record
                    }
                    if record.delivery.event == .start,
                       start.map({ revision < $0.delivery.projection.revision }) ?? true {
                        start = record
                    }
                    if overall.map({ $0.delivery.projection.revision < revision }) ?? true {
                        overall = record
                    }
                }
                return terminal ?? start ?? overall
            }
        }
    }

    func recordFailure(
        recordID: String,
        nextAttemptAt: Date
    ) throws -> LiveActivityAcceptanceRecord? {
        try lock.withLock {
            var records = try loadUnlocked()
            guard let index = records.firstIndex(where: {
                $0.recordID == recordID
            }) else { return nil }
            records[index] = LiveActivityAcceptanceRecord(
                delivery: records[index].delivery,
                target: records[index].target,
                attempts: records[index].attempts + 1,
                nextAttemptAt: nextAttemptAt,
                enqueuedAt: records[index].enqueuedAt
            )
            try saveUnlocked(records)
            return records[index]
        }
    }

    func acknowledge(_ record: LiveActivityAcceptanceRecord) throws {
        try lock.withLock {
            var records = try loadUnlocked()
            // ACK scope is the exact delivery+target unit. A delayed accepted
            // end for token A must never acknowledge rotated token B merely
            // because both share one serialized lifecycle lane.
            records.removeAll { $0.recordID == record.recordID }
            try saveUnlocked(records)
        }
    }

    private func loadUnlocked() throws -> [LiveActivityAcceptanceRecord] {
        guard let json = try settings.get(Self.key),
              !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        do {
            return try decoder.decode([LiveActivityAcceptanceRecord].self, from: data)
        } catch {
            // A snapshot we cannot decode can never be acknowledged or retried,
            // and keeping it would fail every enqueue/candidates call forever.
            // Treat it as an empty backlog (no acknowledgement is invented) so
            // the next write persists a valid snapshot again.
            Self.log.error(
                "live-activity outbox snapshot undecodable bytes=\(data.count, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private func saveUnlocked(_ records: [LiveActivityAcceptanceRecord]) throws {
        let data = try encoder.encode(records)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try settings.set(Self.key, json)
    }

    /// Compact superseded lifecycle work first, then age/count/byte bounds.
    /// Newest/current lifecycle and terminal/end records are preserved wherever
    /// possible. Dropped rows leave no acknowledgement — success is never invented.
    private static func compactBacklog(
        _ records: inout [LiveActivityAcceptanceRecord],
        now: Date,
        encoder: JSONEncoder,
        limits: LiveActivityAcceptanceOutboxLimits
    ) -> CompactionReport {
        // 1) Superseded lifecycle work: keep terminal barriers, the current
        // start/update, and no stale non-terminal generations.
        compactSupersededLifecycle(&records)
        // Semantic supersession is routine last-write-wins work, not pressure.
        // Only age/count/byte losses are disclosed through the error seam.
        let beforeBoundedDrops = records.count

        // 2) Hard age bound for every event, including start/end. ActivityKit
        // and backend retention are both much shorter than an unbounded queue.
        let recordCutoff = now.addingTimeInterval(-limits.recordRetention)
        records.removeAll { $0.enqueuedAt < recordCutoff }

        // 3) Count cap: sort by lifecycle identity, not enqueue time. Protect
        // current content/start barriers and the newest terminal barrier per lane.
        records.sort(by: recordIsOrderedBefore)
        if records.count > limits.recordCap {
            while records.count > limits.recordCap {
                let current = currentLifecycleRecordIDs(records)
                let startBarriers = currentStartBarrierRecordIDs(
                    records,
                    currentRecordIDs: current
                )
                let terminal = neededTerminalBarrierIDs(records)
                let protected = current.union(terminal)
                if let idx = records.firstIndex(where: {
                    !protected.contains($0.recordID)
                }) {
                    records.remove(at: idx)
                } else if let idx = records.firstIndex(where: {
                    terminal.contains($0.recordID) &&
                    !current.contains($0.recordID)
                }) {
                    records.remove(at: idx)
                } else if let idx = records.firstIndex(where: {
                    !current.contains($0.recordID)
                }) {
                    records.remove(at: idx)
                } else if let idx = records.firstIndex(where: {
                    !startBarriers.contains($0.recordID)
                }) {
                    // If a cap cannot hold both, the start barrier is the
                    // deliverable foundation; a later update is disposable.
                    records.remove(at: idx)
                } else {
                    records.removeFirst()
                }
            }
        }

        // 4) Encoded-byte budget: keep compacting oldest non-end work first.
        while encodedByteCount(records, encoder: encoder) > limits.encodedByteCap {
            guard !records.isEmpty else { break }
            let current = currentLifecycleRecordIDs(records)
            let startBarriers = currentStartBarrierRecordIDs(
                records,
                currentRecordIDs: current
            )
            let terminal = neededTerminalBarrierIDs(records)
            let protected = current.union(terminal)
            if let idx = records.firstIndex(where: {
                !protected.contains($0.recordID)
            }) {
                records.remove(at: idx)
                continue
            }
            if let idx = records.firstIndex(where: {
                terminal.contains($0.recordID) &&
                !current.contains($0.recordID)
            }) {
                records.remove(at: idx)
                continue
            }
            if let idx = records.firstIndex(where: {
                !current.contains($0.recordID)
            }) {
                records.remove(at: idx)
            } else if let idx = records.firstIndex(where: {
                !startBarriers.contains($0.recordID)
            }) {
                records.remove(at: idx)
            } else {
                records.removeFirst()
            }
        }

        return CompactionReport(
            droppedRecords: max(0, beforeBoundedDrops - records.count)
        )
    }

    private static func compactSupersededLifecycle(
        _ records: inout [LiveActivityAcceptanceRecord]
    ) {
        var keepIDs = Set<String>()
        for lane in Dictionary(grouping: records, by: { $0.target.laneIdentity }).values {
            guard let newestLifecycle = newestLifecycleRecord(in: lane) else { continue }
            let currentSession = sessionIdentity(newestLifecycle.delivery)
            let sessions = Dictionary(grouping: lane, by: {
                sessionIdentity($0.delivery)
            })

            for (sessionKey, session) in sessions {
                // Every historical terminal remains a lifecycle barrier. Within
                // one session the newest end supersedes its start/update.
                if let newestEnd = newestRecord(in: session, event: .end) {
                    keepIDs.insert(newestEnd.recordID)
                    continue
                }
                // Once a newer lifecycle exists, historical non-terminal work
                // must not resurrect an obsolete Live Activity.
                guard sessionKey == currentSession else { continue }
                if let newestStart = newestRecord(in: session, event: .start) {
                    keepIDs.insert(newestStart.recordID)
                }
                if let newestUpdate = newestRecord(in: session, event: .update) {
                    keepIDs.insert(newestUpdate.recordID)
                }
            }
        }
        records.removeAll { !keepIDs.contains($0.recordID) }
    }

    private static func newestLifecycleRecord(
        in records: [LiveActivityAcceptanceRecord]
    ) -> LiveActivityAcceptanceRecord? {
        records.reduce(nil) { current, candidate in
            guard let current else { return candidate }
            if isOrderedBefore(current.delivery, candidate.delivery) {
                return candidate
            }
            if isOrderedBefore(candidate.delivery, current.delivery) {
                return current
            }
            if current.delivery.projection.sessionId != candidate.delivery.projection.sessionId {
                return current.delivery.projection.sessionId <
                    candidate.delivery.projection.sessionId ? candidate : current
            }
            // Same lifecycle identity: later enqueue/array position represents
            // the rotated target that superseded the prior unit.
            return candidate.enqueuedAt >= current.enqueuedAt ? candidate : current
        }
    }

    private static func newestRecord(
        in records: [LiveActivityAcceptanceRecord],
        event: PrivateLiveActivityEvent,
        sameSessionAs sessionAnchor: LiveActivitySyncDelivery? = nil
    ) -> LiveActivityAcceptanceRecord? {
        records.reduce(nil) { current, candidate in
            guard candidate.delivery.event == event else { return current }
            if let sessionAnchor, !isSameSession(candidate.delivery, sessionAnchor) { return current }
            guard let current else { return candidate }
            if candidate.delivery.projection.revision > current.delivery.projection.revision {
                return candidate
            }
            if candidate.delivery.projection.revision == current.delivery.projection.revision,
               candidate.enqueuedAt >= current.enqueuedAt {
                return candidate
            }
            return current
        }
    }

    private static func sessionIdentity(_ delivery: LiveActivitySyncDelivery) -> String {
        [
            delivery.projection.hostId,
            delivery.projection.epoch,
            String(delivery.activityGeneration),
            delivery.projection.sessionId,
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func currentLifecycleRecordIDs(
        _ records: [LiveActivityAcceptanceRecord]
    ) -> Set<String> {
        var result = Set<String>()
        for lane in Dictionary(grouping: records, by: { $0.target.laneIdentity }).values {
            guard let current = newestLifecycleRecord(in: lane) else { continue }
            result.insert(current.recordID)
            if let start = newestRecord(
                in: lane,
                event: .start,
                sameSessionAs: current.delivery
            ) {
                // An update is not deliverable until its generation start has
                // crossed the backend lifecycle barrier.
                result.insert(start.recordID)
            }
        }
        return result
    }

    private static func currentStartBarrierRecordIDs(
        _ records: [LiveActivityAcceptanceRecord],
        currentRecordIDs: Set<String>
    ) -> Set<String> {
        Set(records.compactMap { record in
            guard currentRecordIDs.contains(record.recordID),
                  record.delivery.event == .start else { return nil }
            return record.recordID
        })
    }

    private static func neededTerminalBarrierIDs(
        _ records: [LiveActivityAcceptanceRecord]
    ) -> Set<String> {
        var result = Set<String>()
        for lane in Dictionary(grouping: records, by: { $0.target.laneIdentity }).values {
            // Single pass: newest terminal end per lane, no filter intermediate.
            var terminal: LiveActivityAcceptanceRecord?
            for record in lane where record.delivery.event == .end {
                if let current = terminal {
                    if recordIsOrderedBefore(current, record) { terminal = record }
                } else {
                    terminal = record
                }
            }
            if let terminal {
                result.insert(terminal.recordID)
            }
        }
        return result
    }

    private static func recordIsOrderedBefore(
        _ lhs: LiveActivityAcceptanceRecord,
        _ rhs: LiveActivityAcceptanceRecord
    ) -> Bool {
        if isOrderedBefore(lhs.delivery, rhs.delivery) { return true }
        if isOrderedBefore(rhs.delivery, lhs.delivery) { return false }
        if lhs.delivery.projection.sessionId != rhs.delivery.projection.sessionId {
            return lhs.delivery.projection.sessionId < rhs.delivery.projection.sessionId
        }
        if lhs.enqueuedAt != rhs.enqueuedAt {
            return lhs.enqueuedAt < rhs.enqueuedAt
        }
        return lhs.recordID < rhs.recordID
    }

    private static func encodedByteCount(
        _ records: [LiveActivityAcceptanceRecord],
        encoder: JSONEncoder
    ) -> Int {
        (try? encoder.encode(records).count) ?? Int.max
    }

    private static func isOrderedBefore(
        _ lhs: LiveActivitySyncDelivery,
        _ rhs: LiveActivitySyncDelivery
    ) -> Bool {
        let lhsBoot = UInt64(lhs.projection.epoch) ?? 0
        let rhsBoot = UInt64(rhs.projection.epoch) ?? 0
        if lhsBoot != rhsBoot { return lhsBoot < rhsBoot }
        if lhs.activityGeneration != rhs.activityGeneration {
            return lhs.activityGeneration < rhs.activityGeneration
        }
        if lhs.projection.revision != rhs.projection.revision {
            return lhs.projection.revision < rhs.projection.revision
        }
        return eventRank(lhs.event) < eventRank(rhs.event)
    }

    private static func isSameSession(
        _ lhs: LiveActivitySyncDelivery,
        _ rhs: LiveActivitySyncDelivery
    ) -> Bool {
        lhs.projection.hostId == rhs.projection.hostId &&
        lhs.projection.epoch == rhs.projection.epoch &&
        lhs.activityGeneration == rhs.activityGeneration &&
        lhs.projection.sessionId == rhs.projection.sessionId
    }

    private static func eventRank(_ event: PrivateLiveActivityEvent) -> Int {
        switch event {
        case .start: 0
        case .update: 1
        case .end: 2
        }
    }
}

public enum LiveActivityAcceptanceOutboxError: Error, Equatable {
    case backendDidNotAccept(String)
    /// Offline backlog exceeded age/count/byte bounds. Dropped work is never
    /// treated as backend success — records are removed without inventing acks.
    case backlogCompacted(droppedRecords: Int)
}

public final class LiveActivityAcceptanceOutbox: @unchecked Sendable {
    public typealias Now = @Sendable () -> Date
    public typealias RetryDelay = @Sendable (Int) -> TimeInterval
    public typealias Schedule = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    public typealias Send = @Sendable (LiveActivityAcceptanceRecord) async throws -> PrivateLiveActivityV2DeliveryAck
    public typealias ErrorHandler = @Sendable (Error, LiveActivitySyncDelivery?) -> Void

    private enum Command: @unchecked Sendable {
        case wake
        case flush(CheckedContinuation<Void, Never>)
    }

    private static let log = Logger(
        subsystem: "io.remotecode.app",
        category: "live-activity-acceptance"
    )
    private let store: LiveActivityAcceptanceOutboxStore
    private let onError: ErrorHandler
    private let continuation: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?

    public init(
        store: LiveActivityAcceptanceOutboxStore,
        now: @escaping Now = { Date() },
        retryDelay: @escaping RetryDelay = { attempt in
            min(60, pow(2, Double(max(0, attempt - 1))))
        },
        schedule: @escaping Schedule = { delay, callback in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0, delay),
                execute: callback
            )
        },
        maximumConcurrentLanes: Int = LiveActivityDeliveryPolicy.maximumConcurrentLanes,
        sendTimeout: TimeInterval = LiveActivityDeliveryPolicy.sendTimeoutSeconds,
        onError: @escaping ErrorHandler = { _, _ in },
        send: @escaping Send
    ) {
        self.store = store
        self.onError = onError
        var capturedContinuation: AsyncStream<Command>.Continuation?
        let stream = AsyncStream<Command> { capturedContinuation = $0 }
        let commandContinuation = capturedContinuation!
        self.continuation = commandContinuation
        let scheduler = LiveActivityAcceptanceLaneScheduler(
            store: store,
            now: now,
            retryDelay: retryDelay,
            schedule: schedule,
            maximumConcurrentLanes: maximumConcurrentLanes,
            sendTimeout: sendTimeout,
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

    public func accept(
        _ delivery: LiveActivitySyncDelivery,
        targets: [LiveActivityAcceptanceTarget]
    ) throws {
        let report = try store.enqueue(delivery, targets: targets)
        surfaceCompaction(report, delivery: delivery)
        continuation.yield(.wake)
    }

    public func resumePending() {
        do {
            surfaceCompaction(try store.compactBacklog(), delivery: nil)
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
        _ report: LiveActivityAcceptanceOutboxStore.CompactionReport,
        delivery: LiveActivitySyncDelivery?
    ) {
        guard report.didDrop else { return }
        // Surface dropped offline backlog via the existing diagnostic seam
        // without inventing a settled backend success.
        Self.log.info(
            "live-activity backlog compacted droppedRecords=\(report.droppedRecords, privacy: .public)"
        )
        onError(
            LiveActivityAcceptanceOutboxError.backlogCompacted(
                droppedRecords: report.droppedRecords
            ),
            delivery
        )
    }

    fileprivate static func isPreferred(
        _ lhs: LiveActivityAcceptanceRecord,
        _ rhs: LiveActivityAcceptanceRecord
    ) -> Bool {
        if lhs.delivery.event != rhs.delivery.event {
            if lhs.delivery.event == .end { return true }
            if rhs.delivery.event == .end { return false }
        }
        if lhs.delivery.activityGeneration != rhs.delivery.activityGeneration {
            return lhs.delivery.activityGeneration < rhs.delivery.activityGeneration
        }
        return lhs.delivery.projection.revision < rhs.delivery.projection.revision
    }
}

private actor LiveActivityAcceptanceLaneScheduler {
    private enum SendOutcome: @unchecked Sendable {
        case settled
        case failed(Error)
    }

    /// One-shot race that lets the lane deadline win even if a test adapter or
    /// future transport ignores cooperative task cancellation. Production
    /// URLSession work is still cancelled, but the scheduler never waits for an
    /// uncooperative child before freeing the bounded lane.
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

    private static let log = Logger(
        subsystem: "io.remotecode.app",
        category: "live-activity-acceptance"
    )

    /// HTTP answers that refuse this exact request for good: 400 (the backend
    /// rejects the body) and 404 (it no longer knows the token the record
    /// carries). Every other failure can change on a retry and stays retryable.
    private static func isDefinitiveRejection(_ error: Error) -> Bool {
        guard case .http(let status)? = error as? PrivateAccountAPIError else { return false }
        return status == 400 || status == 404
    }

    private let store: LiveActivityAcceptanceOutboxStore
    private let now: LiveActivityAcceptanceOutbox.Now
    private let retryDelay: LiveActivityAcceptanceOutbox.RetryDelay
    private let schedule: LiveActivityAcceptanceOutbox.Schedule
    private let maximumConcurrentLanes: Int
    private let sendTimeout: TimeInterval
    private let send: LiveActivityAcceptanceOutbox.Send
    private let onError: LiveActivityAcceptanceOutbox.ErrorHandler

    private var inFlight: [String: (recordID: String, task: Task<Void, Never>)] = [:]
    private var scheduled = Set<String>()
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false

    init(
        store: LiveActivityAcceptanceOutboxStore,
        now: @escaping LiveActivityAcceptanceOutbox.Now,
        retryDelay: @escaping LiveActivityAcceptanceOutbox.RetryDelay,
        schedule: @escaping LiveActivityAcceptanceOutbox.Schedule,
        maximumConcurrentLanes: Int,
        sendTimeout: TimeInterval,
        send: @escaping LiveActivityAcceptanceOutbox.Send,
        onError: @escaping LiveActivityAcceptanceOutbox.ErrorHandler
    ) {
        self.store = store
        self.now = now
        self.retryDelay = retryDelay
        self.schedule = schedule
        self.maximumConcurrentLanes = max(1, maximumConcurrentLanes)
        self.sendTimeout = max(0.001, sendTimeout)
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
        let candidates: [LiveActivityAcceptanceRecord]
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
            .sorted(by: LiveActivityAcceptanceOutbox.isPreferred)
        for record in ready {
            guard inFlight.count < maximumConcurrentLanes else { break }
            let lane = record.target.laneIdentity
            guard inFlight[lane] == nil else { continue }
            start(record, lane: lane)
        }
        resumeFlushWaitersIfIdle()
    }

    private func start(_ record: LiveActivityAcceptanceRecord, lane: String) {
        let send = self.send
        let timeout = sendTimeout
        let task = Task { [weak self] in
            let outcome = await Self.performSend(record, timeout: timeout, send: send)
            await self?.finish(record, lane: lane, outcome: outcome)
        }
        inFlight[lane] = (record.recordID, task)
    }

    private func finish(
        _ record: LiveActivityAcceptanceRecord,
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
                onError(error, record.delivery)
            }
        case .failed(let error):
            onError(error, record.delivery)
            if Self.isDefinitiveRejection(error) {
                // A retry cannot succeed, and a lane sends its oldest session
                // first: keeping this record would hold every newer start,
                // update and end of the device behind it.
                Self.log.error(
                    "live-activity delivery rejected, dropped key=\(record.delivery.idempotencyKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                do {
                    try store.acknowledge(record)
                } catch {
                    onError(error, record.delivery)
                }
                break
            }
            Self.log.error(
                "live-activity delivery failed attempt=\(record.attempts + 1, privacy: .public) key=\(record.delivery.idempotencyKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
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
                onError(error, record.delivery)
            }
        }
        pump()
    }

    private static func performSend(
        _ record: LiveActivityAcceptanceRecord,
        timeout: TimeInterval,
        send: @escaping LiveActivityAcceptanceOutbox.Send
    ) async -> SendOutcome {
        let race = SendRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)

                let sendTask = Task {
                    do {
                        let ack = try await send(record)
                        guard ack.isSettled else {
                            race.resolve(.failed(
                                LiveActivityAcceptanceOutboxError.backendDidNotAccept(
                                    ack.status
                                )
                            ))
                            return
                        }
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
