import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// When several runs finish together the phone gets one "N runs completed"
/// alert. The private backend refuses the whole push when any `data` value
/// passes 512 characters, so the completion of a burst of runs never reached
/// a paused iPhone.
final class GroupedOutcomePushBoundsTests: XCTestCase {
    private func outcome(runId: String) -> RemoteCodeNotificationContent {
        RemoteCodeNotificationContent.threadOutcome(
            threadId: UUID().uuidString,
            runId: runId,
            workspaceId: "30000000-0000-0000-0000-000000000003",
            title: nil,
            phase: .completed
        )!
    }

    // WHY: a few runs keep every id, unchanged from before.
    func testSmallGroupKeepsEveryRunId() throws {
        let ids = (0..<3).map { _ in UUID().uuidString }
        let grouped = try XCTUnwrap(RemoteCodeNotificationContent.groupedOutcomes(ids.map(outcome(runId:))))
        XCTAssertEqual(grouped.userInfo["runIds"], ids.joined(separator: ","))
    }

    // WHY: twenty runs used to make a 739-character value. The bound keeps the
    // newest runs, in order.
    func testLargeGroupKeepsTheNewestRunIdsInsideTheLimit() throws {
        let ids = (0..<20).map { _ in UUID().uuidString }
        let grouped = try XCTUnwrap(RemoteCodeNotificationContent.groupedOutcomes(ids.map(outcome(runId:))))
        let runIds = try XCTUnwrap(grouped.userInfo["runIds"])
        XCTAssertLessThanOrEqual(runIds.utf16.count, 512)
        let kept = runIds.split(separator: ",").map(String.init)
        XCTAssertEqual(kept, Array(ids.suffix(kept.count)), "the newest runs are kept, in order")
        XCTAssertEqual(kept.count, 13)
    }

    // WHY: what the backend receives is what counts — every value of the
    // grouped alert's push data must be inside the 512-character limit.
    func testGroupedAlertSentToTheBackendFitsItsValueLimit() async throws {
        let grouped = try XCTUnwrap(RemoteCodeNotificationContent.groupedOutcomes(
            (0..<20).map { _ in outcome(runId: UUID().uuidString) }
        ))
        let tmp = NSTemporaryDirectory() + "rc2-grouped-bounds-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let accountStore = PrivateAccountSessionStore(repo: settings)
        let targetStore = PrivatePushTargetStore(repo: settings)
        let api = SilentWakeRecordingAPI()
        accountStore.save(api.session)
        try targetStore.save(pushToken: "apns-token", pushTokenType: "apns", liveActivityToken: nil, deviceId: "device-1")
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api, settings: settings)

        _ = await bridge.deliver(grouped)
        let alert = try XCTUnwrap(api.requests.first { !$0.silent })
        let longest = alert.data.max { $0.value.utf16.count < $1.value.utf16.count }
        XCTAssertLessThanOrEqual(longest?.value.utf16.count ?? 0, 512, "longest data value: \(longest?.key ?? "-")")
    }
}
