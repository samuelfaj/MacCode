import Foundation
import os

/// S-002 host-side push funnel counters for silent catch-up (Mac producer).
public enum HostWakeMetricKey: String, Sendable, CaseIterable {
    case outboxCoalesced = "outbox_coalesced"
    case silentAttempt = "silent_attempt"
    case silent429 = "silent_429"
    case silentSent = "silent_sent"
    case silentFailed = "silent_failed"
    /// Attempt never left the host: unsubscribed account and/or no push target.
    /// Distinguishes "host pushed nothing" from a successful silent send.
    case wakeNotSent = "wake_not_sent"
    /// F5: refused by the hourly silent-wake budget (`MaterialWakeBudget`).
    case budgetDropped = "budget_dropped"
}

public final class HostWakeMetrics: @unchecked Sendable {
    public static let shared = HostWakeMetrics()
    private static let log = Logger(subsystem: "io.remotecode.app", category: "wake")

    private let lock = NSLock()
    private var counters: [HostWakeMetricKey: Int] = [:]

    public init() {}

    public func reset() {
        lock.lock()
        counters.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func increment(_ key: HostWakeMetricKey, by delta: Int = 1) {
        guard delta != 0 else { return }
        lock.lock()
        counters[key, default: 0] += delta
        let value = counters[key] ?? 0
        lock.unlock()
        Self.log.info("\(key.rawValue, privacy: .public)=\(value, privacy: .public)")
    }

    public func count(_ key: HostWakeMetricKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counters[key] ?? 0
    }

    public func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var map: [String: Int] = [:]
        for (k, v) in counters { map[k.rawValue] = v }
        return map
    }
}
