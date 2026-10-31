import Foundation
import CoreModel
import AgentRuntime
import SocketServer
import RemoteCodeTreaty

/// Provider account usage pushed to paired iOS clients for the Home Screen
/// widget and the in-app rings (Claude, Codex, Grok used percent).
///
/// It still travels on the deprecated `token_saver.digest` event until iOS
/// bumps its treaty pin. The Token Saver fields iOS decodes are sent as their
/// "off" values: `enabled` false, no estimated save, no progress ring.
public enum AccountUsageWidgetDigest {
    public static let eventKind = RemoteCodeEventKind.tokenSaverDigest
    /// Posted by EventBus when a remote subscriber is added so AppShell can
    /// re-emit the latest digest (late-connecting iOS clients).
    public static let subscriberAddedNotification = Notification.Name(
        "io.remotecode.eventbus.subscriberAdded"
    )

    public enum Scope: String, Sendable, Codable, CaseIterable {
        case today
        case week
    }

    private static let lock = NSLock()
    private static var lastBody: [String: JSONValue]?

    /// Build the EventBus / iOS payload for one scope (default: today).
    public static func payload(
        subscribed: Bool,
        scope: Scope = .today,
        claudeUsedPercent: Double?,
        codexUsedPercent: Double?,
        grokUsedPercent: Double?,
        isRefreshing: Bool,
        updatedAt: Date = Date()
    ) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "enabled": .bool(false),
            "subscribed": .bool(subscribed),
            "scope": .string(scope.rawValue),
            "estimated_save_tokens": .number(0),
            "token_saver_progress": .number(0),
            "token_saver_ring_available": .bool(false),
            "is_refreshing": .bool(isRefreshing),
            "updated_at_ms": .number((updatedAt.timeIntervalSince1970 * 1000).rounded())
        ]
        if let claudeUsedPercent {
            body["claude_used_percent"] = .number(clampedPercent(claudeUsedPercent))
        }
        if let codexUsedPercent {
            body["codex_used_percent"] = .number(clampedPercent(codexUsedPercent))
        }
        if let grokUsedPercent {
            body["grok_used_percent"] = .number(clampedPercent(grokUsedPercent))
        }
        return body
    }

    /// Publish both Today (session, else weekly percent) and Week (weekly
    /// percent) so the iOS surfaces can flip scope without another round-trip.
    public static func publish(
        subscribed: Bool,
        snapshot: ProviderUsageSnapshot,
        accounts: [AccountUsageEntry] = [],
        isRefreshing: Bool,
        updatedAt: Date = Date()
    ) {
        let claude = provider(from: snapshot, .claude)
        let codex = provider(from: snapshot, .codex)
        let grok = provider(from: snapshot, .grok)

        let weekPayload = payload(
            subscribed: subscribed,
            scope: .week,
            claudeUsedPercent: claude.effectiveWeeklyUsedPercent(),
            codexUsedPercent: codex.effectiveWeeklyUsedPercent(),
            grokUsedPercent: grok.effectiveWeeklyUsedPercent(),
            isRefreshing: isRefreshing,
            updatedAt: updatedAt
        )
        let todayPayload = payload(
            subscribed: subscribed,
            scope: .today,
            claudeUsedPercent: claude.effectiveSessionUsedPercent()
                ?? claude.effectiveWeeklyUsedPercent(),
            codexUsedPercent: codex.effectiveSessionUsedPercent()
                ?? codex.effectiveWeeklyUsedPercent(),
            grokUsedPercent: grok.effectiveSessionUsedPercent()
                ?? grok.effectiveWeeklyUsedPercent(),
            isRefreshing: isRefreshing,
            updatedAt: updatedAt
        )

        var body = todayPayload
        body["accounts"] = accountsJSON(accounts)
        body["today"] = .object(todayPayload)
        body["week"] = .object(weekPayload)
        cacheAndPublish(body)
    }

    /// Load the current account usage from disk and publish. Independent of
    /// SidebarViewModel so remote clients get data even when the sidebar has
    /// not been shown this session. Off-main safe: reads usage.json and
    /// publishes through the thread-safe EventBus.
    public static func publishFromDisk(
        appSupportDirectory: URL,
        subscribed: Bool,
        accounts: [AccountUsageEntry] = [],
        isRefreshing: Bool = false,
        updatedAt: Date = Date()
    ) {
        publish(
            subscribed: subscribed,
            snapshot: ProviderUsageStore(appSupportDirectory: appSupportDirectory).load(),
            accounts: accounts,
            isRefreshing: isRefreshing,
            updatedAt: updatedAt
        )
    }

    /// Re-emit the last cached body (no disk IO). Used when a remote client
    /// subscribes after the last live publish fell outside the replay window.
    public static func republishLast() {
        lock.lock()
        let body = lastBody
        lock.unlock()
        guard let body else { return }
        EventBus.shared.publish(kind: eventKind, payload: .object(body))
    }

    /// Latest cached body for RPC `token_saver.digest.get` (may be nil before
    /// the first publish this process).
    public static func lastCachedBody() -> [String: JSONValue]? {
        lock.lock()
        defer { lock.unlock() }
        return lastBody
    }

    public private(set) nonisolated(unsafe) static var suppressedDuplicatePublishCountForTesting = 0

    /// Tests that count digest publishes must start from a clean last body:
    /// the dedupe is process-global and an earlier test may have published an
    /// identical digest.
    public static func resetLastBodyForTesting() {
        lock.lock()
        lastBody = nil
        lock.unlock()
    }

    private static func cacheAndPublish(_ body: [String: JSONValue]) {
        lock.lock()
        let previous = lastBody
        lastBody = body
        lock.unlock()
        // EV-25: every account-usage cycle republished a structurally identical
        // digest (only `updated_at_ms` moved) — 155 persisted events + fan-out
        // per 10 min. Skip when nothing the client renders changed.
        if let previous, digestsEquivalent(previous, body) {
            lock.lock()
            suppressedDuplicatePublishCountForTesting += 1
            lock.unlock()
            return
        }
        EventBus.shared.publish(kind: eventKind, payload: .object(body))
    }

    static func digestsEquivalent(_ lhs: [String: JSONValue], _ rhs: [String: JSONValue]) -> Bool {
        func stripped(_ body: [String: JSONValue]) -> [String: JSONValue] {
            var out = body
            out["updated_at_ms"] = nil
            for scope in ["today", "week"] {
                if case .object(var nested)? = out[scope] {
                    nested["updated_at_ms"] = nil
                    out[scope] = .object(nested)
                }
            }
            return out
        }
        return stripped(lhs) == stripped(rhs)
    }

    private static func provider(
        from snapshot: ProviderUsageSnapshot,
        _ provider: AgentProvider
    ) -> ProviderTokenUsage {
        snapshot.providers.first { $0.provider == provider }
            ?? ProviderTokenUsage(provider: provider)
    }

    /// Every logged-in account, in ring order, for the iPhone rings and widget.
    static func accountsJSON(_ accounts: [AccountUsageEntry]) -> JSONValue {
        .array(accounts.map { entry in
            var row: [String: JSONValue] = [
                "id": .string(entry.id),
                "provider": .string(entry.provider.rawValue),
                "label": .string(entry.label),
                "usage_is_stale": .bool(entry.usageIsStale),
            ]
            if let email = entry.email { row["email"] = .string(email) }
            if let session = entry.usage?.sessionUsedPercent { row["session_used_percent"] = .number(session) }
            if let weekly = entry.usage?.weeklyUsedPercent { row["weekly_used_percent"] = .number(weekly) }
            if let reset = entry.usage?.weeklyResetsAt { row["weekly_resets_at_ms"] = .number((reset.timeIntervalSince1970 * 1000).rounded()) }
            if let reset = entry.usage?.sessionResetsAt { row["session_resets_at_ms"] = .number((reset.timeIntervalSince1970 * 1000).rounded()) }
            return .object(row)
        })
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
