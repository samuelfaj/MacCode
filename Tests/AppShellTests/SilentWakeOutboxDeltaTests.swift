import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// A silent wake that failed is replayed from the durable outbox. The replay
/// must still carry the thread delta (thread_id, workspace_id, state, seq,
/// preview): without it the woken phone cannot tell which thread changed or
/// which seq to catch up to.
final class SilentWakeOutboxDeltaTests: XCTestCase {
    private final class SentRecords: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SilentWakeOutboxRecord] = []
        func append(_ record: SilentWakeOutboxRecord) { lock.withLock { values.append(record) } }
        var records: [SilentWakeOutboxRecord] { lock.withLock { values } }
    }

    private var wakeOutboxFlagBefore: Bool?
    private let delta = PushConnectionHints.delta(
        threadId: "10000000-0000-0000-0000-000000000001",
        workspaceId: "30000000-0000-0000-0000-000000000003",
        state: "failed",
        kind: "agent.run.failed",
        preview: "Run ended with an error.",
        seq: "981"
    )

    override func setUp() {
        super.setUp()
        wakeOutboxFlagBefore = UserDefaults.standard.object(forKey: ConnectionFeatureFlags.wakeOutboxKey) as? Bool
        UserDefaults.standard.removeObject(forKey: "private.silentCatchUp.lastBuckets")
    }

    override func tearDown() {
        if let wakeOutboxFlagBefore {
            UserDefaults.standard.set(wakeOutboxFlagBefore, forKey: ConnectionFeatureFlags.wakeOutboxKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ConnectionFeatureFlags.wakeOutboxKey)
        }
        super.tearDown()
    }

    private func settings() throws -> SettingsRepository {
        let tmp = NSTemporaryDirectory() + "rc2-silent-delta-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return SettingsRepository(db: db)
    }

    // WHY: records written by the previous release have no delta and must still
    // load, or the whole durable backlog would be lost on update.
    func testRecordStoredWithoutDeltaStillDecodes() throws {
        let legacy = #"{"coalesceClass":"attention","hostHint":"h","force":false,"idempotencyKey":"k","attempts":0,"enqueuedAt":0}"#
        let record = try JSONDecoder().decode(SilentWakeOutboxRecord.self, from: Data(legacy.utf8))
        XCTAssertNil(record.delta)
        XCTAssertEqual(record.idempotencyKey, "k")
    }

    // WHY: the store rebuilds the record on enqueue and on every failed attempt;
    // each rebuild used to drop fields it did not know about.
    func testStoreKeepsTheDeltaThroughEnqueueAndRetry() throws {
        let store = SilentWakeOutboxStore(settings: try settings())
        try store.enqueue(SilentWakeOutboxRecord(
            coalesceClass: .attention, hostHint: "agent.run.failed", force: false,
            payload: SilentCatchUpV1(reason: "agent_run_failed"), idempotencyKey: "catchup.attention.1", delta: delta
        ))
        let stored = try XCTUnwrap(try store.pending().first)
        XCTAssertEqual(stored.delta, delta)
        let retried = try store.recordFailure(recordID: stored.recordID, nextAttemptAt: Date())
        XCTAssertEqual(retried?.delta, delta)
        XCTAssertEqual(try store.pending().first?.delta, delta)
    }

    // WHY: end to end — a live send fails, the outbox keeps it, and the replay
    // the outbox makes reaches the backend with the original thread delta.
    func testFailedSendIsReplayedWithItsThreadDelta() async throws {
        ConnectionFeatureFlags.wakeOutboxEnabled = true
        let repo = try settings()
        let accountStore = PrivateAccountSessionStore(repo: repo)
        let targetStore = PrivatePushTargetStore(repo: repo)
        let api = SilentWakeRecordingAPI()
        accountStore.save(api.session)
        try targetStore.save(pushToken: "apns-token", pushTokenType: "apns", liveActivityToken: nil, deviceId: "device-1")
        let sent = SentRecords()
        let outbox = SilentWakeOutbox(
            store: SilentWakeOutboxStore(settings: repo),
            isEnabled: { true },
            send: { record in sent.append(record) }
        )
        let bridge = PrivateNotificationBridge(
            accountStore: accountStore, pushTargetStore: targetStore, api: api, settings: repo, silentWakeOutbox: outbox
        )
        api.script([.fail])

        await bridge.deliverSilentCatchUp(
            hostHint: "agent.run.failed",
            force: false,
            payload: SilentCatchUpV1(sinceSeq: "981", reason: "agent_run_failed"),
            coalesceClass: .attention,
            delta: delta
        )
        await outbox.flush()
        let deadline = Date().addingTimeInterval(5)
        while sent.records.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let record = try XCTUnwrap(sent.records.first, "the failed send was queued and handed back for replay")
        XCTAssertEqual(record.delta, delta)

        try await bridge.performSilentCatchUpDelivery(record)
        let replay = try XCTUnwrap(api.requests.last)
        XCTAssertTrue(replay.silent)
        for (key, value) in delta {
            XCTAssertEqual(replay.data[key], value, key)
        }
        XCTAssertEqual(replay.data["rc2_since_seq"], "981")
    }
}
