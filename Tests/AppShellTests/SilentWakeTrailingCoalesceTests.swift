import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// The 30 s coalesce bucket admits the first silent wake of a class and used to
/// drop every later one. In a burst (question asked, then the run fails a few
/// seconds later) that dropped the final state: the phone woke once, caught up
/// to the question and never learned the run had failed. The newest refused
/// wake must reach the phone when the bucket turns — inside the hourly budget.
final class SilentWakeTrailingCoalesceTests: XCTestCase {
    private static let bucketsKey = "private.silentCatchUp.lastBuckets"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.bucketsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.bucketsKey)
        super.tearDown()
    }

    private func makeBridge() throws -> (PrivateNotificationBridge, SilentWakeRecordingAPI) {
        let tmp = NSTemporaryDirectory() + "rc2-silent-trailing-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let accountStore = PrivateAccountSessionStore(repo: settings)
        let targetStore = PrivatePushTargetStore(repo: settings)
        let api = SilentWakeRecordingAPI()
        accountStore.save(api.session)
        try targetStore.save(pushToken: "apns-token", pushTokenType: "apns", liveActivityToken: nil, deviceId: "device-1")
        let bridge = PrivateNotificationBridge(accountStore: accountStore, pushTargetStore: targetStore, api: api, settings: settings)
        bridge.trailingWakeDelayForTests = 0.3
        return (bridge, api)
    }

    private func wake(_ seq: String, state: String, on bridge: PrivateNotificationBridge) async {
        await bridge.deliverSilentCatchUp(
            hostHint: "agent.\(state)",
            force: false,
            payload: SilentCatchUpV1(sinceSeq: seq, reason: "attention"),
            coalesceClass: .attention,
            delta: PushConnectionHints.delta(
                threadId: "10000000-0000-0000-0000-000000000001", workspaceId: nil,
                state: state, kind: nil, preview: nil, seq: seq
            )
        )
    }

    private func waitFor(_ count: Int, _ api: SilentWakeRecordingAPI, seconds: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while api.requests.count < count, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testNewestRefusedWakeIsSentWhenTheBucketTurns() async throws {
        let (bridge, api) = try makeBridge()
        await wake("10", state: "attention", on: bridge)
        await wake("11", state: "attention", on: bridge)
        await wake("12", state: "failed", on: bridge)
        XCTAssertEqual(api.requests.map { $0.data["seq"] }, ["10"], "the bucket admits only the first wake now")

        // The 30 s bucket turns.
        UserDefaults.standard.removeObject(forKey: Self.bucketsKey)
        try await waitFor(2, api)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(api.requests.map { $0.data["seq"] }, ["10", "12"], "one trailing wake, the newest of the burst")
        XCTAssertEqual(api.requests.last?.data["state"], "failed")
        XCTAssertEqual(api.requests.last?.data["rc2_since_seq"], "12")
        XCTAssertTrue(api.requests.allSatisfy(\.silent))
    }

    // WHY: a wake admitted after the bucket turned is newer than the one
    // waiting, so the waiting one must not follow it as a stale duplicate.
    func testNewerAdmittedWakeReplacesTheWaitingOne() async throws {
        let (bridge, api) = try makeBridge()
        await wake("10", state: "attention", on: bridge)
        await wake("11", state: "attention", on: bridge)
        UserDefaults.standard.removeObject(forKey: Self.bucketsKey)
        await wake("12", state: "failed", on: bridge)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(api.requests.map { $0.data["seq"] }, ["10", "12"])
    }

    // WHY: the trailing send is still a silent wake; the hourly budget (three
    // attention wakes) refuses it like any other and nothing is retried later.
    func testTrailingWakeStaysInsideTheHourlyBudget() async throws {
        let (bridge, api) = try makeBridge()
        for seq in ["1", "2", "3"] {
            UserDefaults.standard.removeObject(forKey: Self.bucketsKey)
            await wake(seq, state: "attention", on: bridge)
        }
        await wake("4", state: "failed", on: bridge)
        UserDefaults.standard.removeObject(forKey: Self.bucketsKey)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(api.requests.map { $0.data["seq"] }, ["1", "2", "3"])
    }
}
