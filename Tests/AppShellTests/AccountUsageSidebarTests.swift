import XCTest
import Foundation
import AgentRuntime
@testable import AppShell

/// Pure copy behind the sidebar's provider account-usage control. Token Saver
/// was removed; these figures are what is left of its card, so they must stay
/// honest provider usage and never read as savings.
final class AccountUsageSidebarTests: XCTestCase {

    func testWidgetWirePreservesUnavailableQuotaWithoutDroppingLastKnownValues() {
        let entry = AccountUsageEntry(id: "claude", provider: .claude, label: "Claude",
            usage: DistillAccountUsage(sessionUsedPercent: 0, weeklyUsedPercent: 100), usageIsStale: true)
        let row = AccountUsageWidgetDigest.accountsJSON([entry]).arrayValue?.first
        XCTAssertEqual(row?.objectValue?["usage_is_stale"], .bool(true))
        XCTAssertEqual(row?.objectValue?["weekly_used_percent"], .number(100))
    }

    // MARK: - lastUpdatedLabel

    func test_lastUpdatedLabel_nil_returnsNever() {
        // WHY: the user has never refreshed; VoiceOver must read "Never" so they
        // know no data has been fetched rather than hearing a stale timestamp.
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(nil, now: Date()), "Never")
    }

    func test_lastUpdatedLabel_underOneMinute_returnsJustNow() {
        // WHY: a 30-second-old refresh should read "just now", not "0m ago" which
        // would look like a stale refresh.
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(-30), now: now), "Updated just now")
    }

    func test_lastUpdatedLabel_exactlyZeroSeconds_returnsJustNow() {
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now, now: now), "Updated just now")
    }

    func test_lastUpdatedLabel_twoMinutesAgo_returns2mAgo() {
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(-120), now: now), "Updated 2m ago")
    }

    func test_lastUpdatedLabel_oneHourAgo_returns1hAgo() {
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(-3600), now: now), "Updated 1h ago")
    }

    func test_lastUpdatedLabel_moreThan24HoursAgo_returnsCapped() {
        // WHY: very stale refreshes must not produce unwieldy strings like
        // "Updated 72h ago"; the cap keeps popover layout stable.
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(-86400 * 3), now: now), "Updated 24h+ ago")
    }

    func test_lastUpdatedLabel_futureDate_returnsJustNow() {
        // WHY: clock skew can produce a future date; elapsed < 0 must not
        // produce a negative label.
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(60), now: now), "Updated just now")
    }

    // MARK: - Account rings

    private func quota(_ json: String) throws -> DistillAccountQuota {
        try JSONDecoder().decode(DistillAccountQuota.self, from: Data(json.utf8))
    }

    func test_everyConnectedAccountIsARing_evenTwoClaudeLogins() throws {
        // WHY: the owner (2026-10-19) has two Claude logins; each must have its own ring.
        let claudeQuota = try quota(#"{"account_id":"a","checked_at":"x","status":"available","remaining_percent":44,"detail":{"five_hour":{"utilization":56,"resets_at":"2026-10-20T03:50:00.449651Z"},"seven_day":{"utilization":49,"resets_at":null}}}"#)
        let statuses = [
            DistillAccountStatus(provider: .claude, connected: true, label: "claude (default)"),
            DistillAccountStatus(provider: .claude, connected: true, email: "me@empath.example", id: "6809a890", label: "Empath", legacy: false, quota: claudeQuota),
            DistillAccountStatus(provider: .grok, connected: false),
        ]
        let entries = AccountUsageEntry.entries(statuses)
        XCTAssertEqual(entries.map(\.label), ["Claude", "Claude · Empath"], "signed-out accounts have no ring")
        XCTAssertNil(AccountUsageDisplay.ringProgress(entries[0]), "no quota yet reads as no data, never 0%")
        XCTAssertEqual(try XCTUnwrap(AccountUsageDisplay.ringProgress(entries[1])), 0.56, accuracy: 0.001, "the live session wins")
        XCTAssertEqual(AccountUsageDisplay.weeklyCaption(entries[1].usage), "Week used 49%")
    }

    func test_weeklyExhaustionWinsEvenWithAnUnusedSession() {
        let usage = DistillAccountUsage(sessionUsedPercent: 0, weeklyUsedPercent: 100)
        let entry = AccountUsageEntry(id: "claude", provider: .claude, label: "Claude", usage: usage)
        XCTAssertEqual(AccountUsageDisplay.ringProgress(entry), 1, "A weekly limit blocks use even when the session is empty")
        XCTAssertEqual(AccountUsageDisplay.ringCaption(entry), "Claude week 100%")
    }

    func test_prepaidAccountsHaveNoSubscriptionRing() {
        let entries = AccountUsageEntry.entries([
            .init(provider: .openrouter, connected: true),
            .init(provider: .claude, connected: true)
        ])
        XCTAssertEqual(entries.map(\.provider), [.claude])
    }

    func test_failedRefreshDoesNotPresentCachedPercentAsCurrent() {
        let quota = DistillAccountQuota(accountID: "claude", checkedAt: "now", status: "unavailable", remainingPercent: 6)
        let entry = AccountUsageEntry.entries([.init(provider: .claude, connected: true, quota: quota)])[0]
        XCTAssertTrue(entry.usageIsStale)
        // The ring paints the last known value faded, like the bars: an empty
        // ring hid usage the list still shows (only ChatGPT's ring painted).
        XCTAssertEqual(try XCTUnwrap(AccountUsageDisplay.ringProgress(entry)), 0.94, accuracy: 0.001)
        XCTAssertTrue(AccountUsageDisplay.ring(entry).stale, "A failed OAuth request must not paint yesterday's usage as current")
        XCTAssertEqual(entry.usage?.weeklyUsedPercent, 94, "Keep last known values available in the description")
        XCTAssertEqual(AccountUsageDisplay.ringCaption(entry), "Claude usage unavailable")
    }

    func test_chatGPTWindowsMapByLength() throws {
        let usage = try XCTUnwrap(DistillAccountUsage(quota: quota(#"{"account_id":"c","checked_at":"x","status":"available","remaining_percent":61,"detail":{"rate_limit":{"primary_window":{"used_percent":39,"limit_window_seconds":604800,"reset_at":1792874449}}}}"#)))
        XCTAssertEqual(usage.weeklyUsedPercent, 39)
        XCTAssertNil(usage.sessionUsedPercent, "a 7-day window is not a session")
    }

    func test_unknownDetailFallsBackToRemainingPercent() throws {
        let usage = try XCTUnwrap(DistillAccountUsage(quota: quota(#"{"account_id":"o","checked_at":"x","status":"available","remaining_percent":70}"#)))
        XCTAssertEqual(usage.weeklyUsedPercent, 30)
    }

    func test_helpListsAccountsAndSignedOutPromptsSignIn() {
        let entries = [AccountUsageEntry(id: "a", provider: .chatgpt, label: "ChatGPT", usage: DistillAccountUsage(weeklyUsedPercent: 37))]
        XCTAssertEqual(AccountUsageDisplay.ringsHelp(signedIn: true, entries: entries), "Account usage\nChatGPT week 37%\nClick for details")
        XCTAssertEqual(AccountUsageDisplay.ringsHelp(signedIn: false, entries: entries), AccountUsageDisplay.signedOutPrompt)
        XCTAssertEqual(AccountUsageDisplay.ringsHelp(signedIn: true, entries: []), AccountUsageDisplay.noAccountsPrompt)
    }
}
