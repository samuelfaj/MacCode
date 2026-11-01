import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// F5: the push bridge's hourly silent-wake budget and its two Live Activity rules.
///
/// The bridge has no clock seam, so every test runs inside one instant: budget
/// sends are forced (the 30 s bucket is not what is measured), the rolling
/// window is exercised by writing the stored budget value, and the 30 s bucket
/// key is removed before each send that stands for a later wake.
final class SilentWakeBudgetBridgeTests: XCTestCase {
    private static let legacyBucketKey = "private.silentCatchUp.lastBucket"
    private static let bucketsKey = "private.silentCatchUp.lastBuckets"
    private static let budgetKey = "private.silentWake.budget.v1"

    private var wakeOutboxFlagBefore: Bool?

    override func setUp() {
        super.setUp()
        wakeOutboxFlagBefore = UserDefaults.standard.object(forKey: ConnectionFeatureFlags.wakeOutboxKey) as? Bool
        // Flag off: a failed send is dropped, so no background replay adds a request.
        ConnectionFeatureFlags.wakeOutboxEnabled = false
        UserDefaults.standard.removeObject(forKey: Self.legacyBucketKey)
        clearCoalesceBuckets()
    }

    override func tearDown() {
        if let wakeOutboxFlagBefore {
            UserDefaults.standard.set(wakeOutboxFlagBefore, forKey: ConnectionFeatureFlags.wakeOutboxKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ConnectionFeatureFlags.wakeOutboxKey)
        }
        super.tearDown()
    }

    // MARK: - Hourly budget (table B1, table P1)

    func testHourlyBudgetDropsExcessAndKeepsTheAttentionSlot() async throws {
        // WHY: Apple's guidance is two or three silent pushes per hour. Inside
        // it the plan's order holds: progress, git and `other` take only the
        // first slot, a notification or a boot wake the first two, and the
        // third is kept for attention.
        let fixture = try makeFixture()
        let bridge = fixture.makeBridge()
        let droppedBefore = HostWakeMetrics.shared.count(.budgetDropped)

        let order: [MaterialWakeCoalesceClass] = [
            .runProgress, .git, .other, .notification, .boot, .boot, .attention, .attention,
        ]
        for coalesceClass in order {
            await send(coalesceClass, on: bridge)
        }

        XCTAssertEqual(
            fixture.api.requests.map { $0.data["rc2_reason"] },
            ["run_progress", "notification", "attention"],
            "three wakes an hour: the first of any class, the second not progress, the third attention only"
        )
        XCTAssertTrue(fixture.api.requests.allSatisfy(\.silent))
        XCTAssertEqual(
            HostWakeMetrics.shared.count(.budgetDropped) - droppedBefore,
            5,
            "git, other, boot, boot and the fourth attention wake are dropped and counted, never deferred"
        )
    }

    func testBudgetSlotsReturnAfterTheWindow() async throws {
        // WHY: the hour is rolling. Three delivered wakes must not silence the
        // phone for ever: the stored list is counted through its window, never
        // by its length.
        let fixture = try makeFixture()
        let bridge = fixture.makeBridge()

        try fixture.settings.set(Self.budgetKey, Self.budgetValue(device: "device-1", sentSecondsAgo: 3601))
        await send(.runProgress, on: bridge)
        await send(.boot, on: bridge)
        await send(.attention, on: bridge)
        XCTAssertEqual(fixture.api.requests.count, 3, "wakes older than one hour cost no slot")

        try fixture.settings.set(Self.budgetKey, Self.budgetValue(device: "device-1", sentSecondsAgo: 10))
        await send(.attention, on: bridge)
        XCTAssertEqual(fixture.api.requests.count, 3, "three wakes inside the hour leave no slot, not even for attention")
    }

    func testUndeliveredAnswerNeitherConsumesNorLeaksASlot() async throws {
        // WHY: the budget counts delivered pushes. A send the backend answers
        // "not delivered" costs no slot, and it must give back its in-flight
        // count: a leak would shrink the budget until the next relaunch.
        let fixture = try makeFixture()
        let bridge = fixture.makeBridge()
        fixture.api.script([.notDelivered, .notDelivered, .notDelivered])

        for _ in 0..<6 {
            await send(.attention, on: bridge)
        }
        XCTAssertEqual(fixture.api.requests.count, 6, "three undelivered answers leave all three slots free")

        await send(.attention, on: bridge)
        XCTAssertEqual(fixture.api.requests.count, 6, "the three delivered wakes used the hour")
    }

    func testForcedWakeIsInsideTheBudget() async throws {
        // WHY: `force` exists to pass the 30 s bucket. No push is outside the
        // hourly budget, the forced boot wake included (plan section 9, item 4).
        let fixture = try makeFixture()
        let bridge = fixture.makeBridge()
        for _ in 0..<3 {
            await send(.attention, on: bridge)
        }

        await bridge.deliverSilentCatchUp(
            hostHint: "host.boot_epoch",
            force: true,
            payload: SilentCatchUpV1(reason: "host_boot_epoch"),
            coalesceClass: .boot
        )

        XCTAssertEqual(fixture.api.requests.count, 3)
        XCTAssertFalse(fixture.api.requests.contains { $0.data["rc2_reason"] == "host_boot_epoch" })
    }

    func testFailedSilentSendDoesNotConsumeBudget() async throws {
        // WHY: three backend failures must not silence attention for an hour.
        let fixture = try makeFixture()
        let bridge = fixture.makeBridge()
        fixture.api.script([.fail, .fail, .fail])

        for _ in 0..<6 {
            await send(.attention, on: bridge)
        }
        XCTAssertEqual(fixture.api.requests.count, 6, "a send that threw costs no slot and releases its in-flight count")

        await send(.attention, on: bridge)
        XCTAssertEqual(fixture.api.requests.count, 6, "the three delivered wakes used the hour")
    }

    func testBudgetSurvivesANewBridgeOnTheSameSettings() async throws {
        // WHY: a relaunch or a crash loop must not mint a fresh budget, so the
        // delivered times are on disk, not in the bridge.
        let fixture = try makeFixture()
        let first = fixture.makeBridge()
        for _ in 0..<3 {
            await send(.attention, on: first)
        }
        XCTAssertEqual(fixture.api.requests.count, 3)

        let relaunched = fixture.makeBridge()
        await send(.attention, on: relaunched)

        XCTAssertEqual(fixture.api.requests.count, 3, "the relaunched bridge reads the hour its predecessor used")
    }

    func testBudgetBelongsToThePushTargetDevice() async throws {
        // WHY: the counter is the phone's, not the Mac's. iOS throttles per
        // device, so another push target starts with its own hour.
        let fixture = try makeFixture()
        let bridge = fixture.makeBridge()
        for _ in 0..<4 {
            await send(.attention, on: bridge)
        }
        XCTAssertEqual(fixture.api.requests.count, 3, "device-1 used its hour")

        try fixture.targetStore.save(
            pushToken: "apns-token-2",
            pushTokenType: "apns",
            liveActivityToken: nil,
            deviceId: "device-2"
        )
        await send(.attention, on: bridge)

        XCTAssertEqual(fixture.api.requests.count, 4, "device-2 has a budget of its own")
    }

    func testLegacyBudgetEntryMigratesWithoutDroppingItsThreeWakeHistory() async throws {
        // WHY: upgraded clients must honor the device budget written by earlier builds.
        let fixture = try makeFixture()
        let now = Date().timeIntervalSince1970
        try fixture.settings.set(
            Self.budgetKey,
            "{\"device\":\"device-1\",\"sent\":[\(now),\(now),\(now)]}"
        )

        await send(.attention, on: fixture.makeBridge())

        XCTAssertTrue(fixture.api.requests.isEmpty, "three legacy wakes already used device-1's hourly budget")
    }

    func testSwitchingDevicesDoesNotEraseHourlyWakeHistory() async throws {
        // WHY: switching the registered target must not mint another hourly budget for a device.
        let fixture = try makeFixture()
        let bridge = fixture.makeBridge()

        await send(.attention, on: bridge)
        await send(.attention, on: bridge)
        try fixture.targetStore.save(
            pushToken: "apns-token-2",
            pushTokenType: "apns",
            liveActivityToken: nil,
            deviceId: "device-2"
        )
        await send(.attention, on: bridge)
        try fixture.targetStore.save(
            pushToken: "apns-token-1",
            pushTokenType: "apns",
            liveActivityToken: nil,
            deviceId: "device-1"
        )
        await send(.attention, on: bridge)
        XCTAssertEqual(fixture.api.requests.count, 4, "device-1's third wake remains admitted after switching away and back")

        await send(.attention, on: bridge)
        XCTAssertEqual(fixture.api.requests.count, 4, "device-1's fourth wake is refused across device switches")
    }

    func testInFlightWakeBudgetIsScopedToItsDeviceAcrossSwitches() async throws {
        // WHY: one device's pending sends must not reduce another device's independent budget.
        let fixture = try makeFixture()
        let bridge = fixture.makeBridge()
        fixture.api.script([.hold])
        let pendingA = Task {
            await send(.attention, on: bridge)
        }
        await fixture.api.waitUntilHeld()

        try fixture.targetStore.save(
            pushToken: "apns-token-2",
            pushTokenType: "apns",
            liveActivityToken: nil,
            deviceId: "device-2"
        )
        for _ in 0..<3 {
            await send(.attention, on: bridge)
        }
        XCTAssertEqual(fixture.api.requests.count, 4, "device-2 gets all three slots while device-1 send remains pending")

        fixture.api.releaseHeld()
        await pendingA.value
    }

    func testOutboxReplayIsInsideTheBudget() async throws {
        // WHY: the durable replay must not be a way around the budget. A
        // refused record throws, so the outbox keeps it instead of dropping it.
        let fixture = try makeFixture()
        let bridge = fixture.makeBridge()
        for _ in 0..<3 {
            await send(.attention, on: bridge)
        }
        let record = SilentWakeOutboxRecord(
            coalesceClass: .runProgress,
            hostHint: "agent.run.completed",
            force: true,
            payload: SilentCatchUpV1(reason: "agent_run_completed"),
            idempotencyKey: "catchup.run_progress.replay"
        )

        do {
            try await bridge.performSilentCatchUpDelivery(record)
            XCTFail("a replay the budget refuses must not report success")
        } catch {
            XCTAssertEqual(error as? SilentWakeOutboxError, .notDelivered("budget"))
        }
        XCTAssertEqual(fixture.api.requests.count, 3, "the refused replay makes no request")
    }

    func testOutboxReplaySettlesItsBudgetSlotOnEveryExit() async throws {
        // WHY: a replay takes an in-flight slot like any send. An exit that
        // does not give it back shrinks the hour until the next relaunch, and
        // a delivered replay that is not written down is a wake outside the
        // budget after one.
        let record = SilentWakeOutboxRecord(
            coalesceClass: .attention,
            hostHint: "agent.run.failed",
            force: true,
            payload: SilentCatchUpV1(reason: "attention"),
            idempotencyKey: "catchup.attention.replay"
        )

        let undelivered = try makeFixture()
        let undeliveredBridge = undelivered.makeBridge()
        undelivered.api.script([.notDelivered])
        do {
            try await undeliveredBridge.performSilentCatchUpDelivery(record)
            XCTFail("an undelivered replay must stay queued")
        } catch {
            XCTAssertEqual(error as? SilentWakeOutboxError, .notDelivered("apns/throttled"))
        }
        for _ in 0..<4 {
            await send(.attention, on: undeliveredBridge)
        }
        XCTAssertEqual(undelivered.api.requests.count, 4, "an undelivered replay leaves all three slots free")

        let thrown = try makeFixture()
        let thrownBridge = thrown.makeBridge()
        thrown.api.script([.fail])
        do {
            try await thrownBridge.performSilentCatchUpDelivery(record)
            XCTFail("a replay that threw must stay queued")
        } catch {
            XCTAssertNil(error as? SilentWakeOutboxError, "the backend's own error is passed on")
        }
        for _ in 0..<4 {
            await send(.attention, on: thrownBridge)
        }
        XCTAssertEqual(thrown.api.requests.count, 4, "a replay that threw leaves all three slots free")

        let delivered = try makeFixture()
        try await delivered.makeBridge().performSilentCatchUpDelivery(record)
        // A second bridge reads the disk only: no in-flight count can explain the refusal.
        let relaunched = delivered.makeBridge()
        for _ in 0..<3 {
            await send(.attention, on: relaunched)
        }
        XCTAssertEqual(delivered.api.requests.count, 3, "the delivered replay used one of the three slots")
    }

    // MARK: - Live Activity (D6)

    func testNoProgressWakeWhileLiveActivityActiveForDevice() async throws {
        // WHY: while a card is active for the phone it already shows progress,
        // so the run-progress wake is withheld and costs nothing. Errors still
        // wake. A card older than ActivityKit's 8 h, or another phone's card,
        // withholds nothing.
        let active = try makeFixture()
        try active.targetStore.upsert(Self.activityRow(deviceId: "device-1"))
        let bridge = active.makeBridge()
        let suppressedBefore = HostWakeMetrics.shared.count(.liveActivitySuppressed)

        await send(.runProgress, on: bridge)
        XCTAssertTrue(active.api.requests.isEmpty, "no progress wake while the card is active for this phone")
        XCTAssertEqual(HostWakeMetrics.shared.count(.liveActivitySuppressed) - suppressedBefore, 1)

        await send(.attention, on: bridge)
        XCTAssertEqual(active.api.requests.map { $0.data["rc2_reason"] }, ["attention"], "errors still wake")
        // The notification limit is 2: it is admitted only when the withheld
        // wake neither used a slot nor left an in-flight count behind.
        await send(.notification, on: bridge)
        XCTAssertEqual(active.api.requests.map { $0.data["rc2_reason"] }, ["attention", "notification"])

        let stale = try makeFixture()
        try stale.targetStore.upsert(Self.activityRow(
            deviceId: "device-1",
            updatedAt: Date().addingTimeInterval(-(PrivatePushTargetStore.activityUpdateRetention + 1))
        ))
        await send(.runProgress, on: stale.makeBridge())
        XCTAssertEqual(stale.api.requests.count, 1, "a row older than 8 h is not an active card")

        let foreign = try makeFixture()
        try foreign.targetStore.upsert(Self.activityRow(deviceId: "device-2"))
        await send(.runProgress, on: foreign.makeBridge())
        XCTAssertEqual(foreign.api.requests.count, 1, "another phone's card does not withhold this phone's wake")
    }

    func testReplayedProgressWakeIsDroppedWhileLiveActivityActiveForDevice() async throws {
        // WHY: a progress wake that failed before the card started must not
        // come back through the outbox while the card shows that progress.
        // Returning normally acknowledges the record, so it is not retried.
        let fixture = try makeFixture()
        try fixture.targetStore.upsert(Self.activityRow(deviceId: "device-1"))
        let record = SilentWakeOutboxRecord(
            coalesceClass: .runProgress,
            hostHint: "agent.run.completed",
            force: true,
            payload: SilentCatchUpV1(reason: "agent_run_completed"),
            idempotencyKey: "catchup.run_progress.replay"
        )

        try await fixture.makeBridge().performSilentCatchUpDelivery(record)

        XCTAssertTrue(fixture.api.requests.isEmpty, "no replayed progress wake while the card is active")
    }

    func testFinishWithAStaleOrForeignActivityRowShowsTheBanner() async throws {
        // WHY: the wake that replaces a suppressed finish banner can now be
        // dropped by the budget. A stale row, or another phone's row, must not
        // hide the banner too: a finish must not end with neither.
        let content = try XCTUnwrap(RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-1",
            workspaceId: "ws-1",
            title: "Build fix",
            phase: .completed
        ))

        let stale = try makeFixture()
        try stale.targetStore.upsert(Self.activityRow(
            deviceId: "device-1",
            updatedAt: Date().addingTimeInterval(-(PrivatePushTargetStore.activityUpdateRetention + 1))
        ))
        await stale.makeBridge().deliverThreadOutcomeRemote(content, phase: .completed)
        let staleFirst = try XCTUnwrap(stale.api.requests.first)
        XCTAssertFalse(staleFirst.silent, "a card that ended hours ago does not hide the banner")
        XCTAssertEqual(staleFirst.title, "Thread finished")

        let foreign = try makeFixture()
        try foreign.targetStore.upsert(Self.activityRow(deviceId: "device-2"))
        await foreign.makeBridge().deliverThreadOutcomeRemote(content, phase: .completed)
        let foreignFirst = try XCTUnwrap(foreign.api.requests.first)
        XCTAssertFalse(foreignFirst.silent, "another phone's card does not hide this phone's banner")
        XCTAssertEqual(foreignFirst.title, "Thread finished")

        // A fresh card no longer hides the banner either: finishes keep their
        // alert until a durable receipt proves the card covered the same run.
        let legacy = try makeFixture(deviceId: nil)
        try legacy.targetStore.upsert(Self.activityRow(deviceId: "device-1"))
        await legacy.makeBridge().deliverThreadOutcomeRemote(content, phase: .completed)
        XCTAssertEqual(legacy.api.requests.count, 1)
        XCTAssertEqual(legacy.api.requests.first?.silent, false)
    }

    // MARK: - Helpers

    private struct Fixture {
        let settings: SettingsRepository
        let accountStore: PrivateAccountSessionStore
        let targetStore: PrivatePushTargetStore
        let api: SilentWakeRecordingAPI

        /// A bridge over this fixture's stores. A second one stands for a relaunch.
        func makeBridge(silentWakeOutbox: SilentWakeOutbox? = nil) -> PrivateNotificationBridge {
            let bridge = PrivateNotificationBridge(
                accountStore: accountStore,
                pushTargetStore: targetStore,
                api: api,
                settings: settings,
                silentWakeOutbox: silentWakeOutbox
            )
            bridge.setConnectionHintSources(
                watermark: { "42" },
                bootEpoch: { "7" }
            )
            return bridge
        }
    }

    /// Its own settings database (never an `AppContext`, which builds a second
    /// bridge), a signed-in subscribed account and one push target.
    private func makeFixture(deviceId: String? = "device-1") throws -> Fixture {
        let tmp = NSTemporaryDirectory() + "rc2-silent-wake-budget-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let accountStore = PrivateAccountSessionStore(repo: settings)
        let targetStore = PrivatePushTargetStore(repo: settings)
        let api = SilentWakeRecordingAPI()
        accountStore.save(api.session)
        try targetStore.save(
            pushToken: "apns-token",
            pushTokenType: "apns",
            liveActivityToken: nil,
            deviceId: deviceId
        )
        return Fixture(
            settings: settings,
            accountStore: accountStore,
            targetStore: targetStore,
            api: api
        )
    }

    /// Forced, so the 30 s bucket is not what is measured; the reason names the class.
    private func send(_ coalesceClass: MaterialWakeCoalesceClass, on bridge: PrivateNotificationBridge) async {
        await bridge.deliverSilentCatchUp(
            hostHint: "h",
            force: true,
            payload: SilentCatchUpV1(reason: coalesceClass.rawValue),
            coalesceClass: coalesceClass
        )
    }

    /// A real renewal is 300 s later, in another 30 s bucket.
    private func clearCoalesceBuckets() {
        UserDefaults.standard.removeObject(forKey: Self.bucketsKey)
    }

    /// The stored budget value with three delivered wakes of the same age.
    private static func budgetValue(device: String, sentSecondsAgo age: TimeInterval) -> String {
        let sent = Date().timeIntervalSince1970 - age
        return "{\"device\":\"\(device)\",\"sent\":[\(sent),\(sent),\(sent)]}"
    }

    private static func activityRow(deviceId: String, updatedAt: Date = Date()) -> PrivatePushTargetRecord {
        PrivatePushTargetRecord(
            deviceId: deviceId,
            serverId: "server-1",
            purpose: .activityUpdate,
            environment: .sandbox,
            token: "activity-update-token",
            activityGeneration: 1,
            activityId: "activity-1",
            bootEpoch: 1,
            activitySessionId: "server-1:1:1",
            contractVersion: 2,
            capabilities: ["live_activity_v2"],
            updatedAt: updatedAt
        )
    }
}

// MARK: - Test doubles

/// Records every `deliverAlert` call and answers it from a script. Internal
/// (not file-private) because other test files reuse it.
final class SilentWakeRecordingAPI: PrivateAccountAPI, @unchecked Sendable {
    struct Request: Equatable, Sendable {
        let title: String
        let data: [String: String]
        let idempotencyKey: String
        let silent: Bool
    }

    /// How one `deliverAlert` call is answered. A call with no scripted answer is delivered.
    enum Answer: Sendable {
        case delivered
        /// The backend answered without delivering (`delivered: false`, no throw).
        case notDelivered
        /// The call throws.
        case fail
        /// The call is recorded, then parked until `releaseHeld()`, then delivered.
        case hold
    }

    let session = PrivateAccountSession(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        user: PrivateAccountUser(
            daysRemaing: 30,
            daysRemaining: 30,
            email: "test@example.com",
            id: "user-1",
            subscribed: true
        )
    )

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var scripted: [Answer] = []
    private var heldCall: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    /// Every `deliverAlert` call so far, alert and silent, in call order.
    var requests: [Request] { lock.withLock { recorded } }

    /// Answers for the next calls, one per call, in order.
    func script(_ answers: [Answer]) {
        lock.withLock { scripted.append(contentsOf: answers) }
    }

    /// Returns once a `.hold` call is parked inside `deliverAlert`.
    func waitUntilHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyHeld = lock.withLock { () -> Bool in
                if heldCall != nil || released { return true }
                heldWaiters.append(continuation)
                return false
            }
            if alreadyHeld { continuation.resume() }
        }
    }

    /// Lets the parked call answer delivered. A later `.hold` is not parked.
    func releaseHeld() {
        lock.lock()
        released = true
        let call = heldCall
        heldCall = nil
        let waiters = heldWaiters
        heldWaiters.removeAll()
        lock.unlock()
        call?.resume()
        waiters.forEach { $0.resume() }
    }

    func deliverAlert(
        accessToken: String,
        title: String,
        body: String,
        data: [String: String],
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String,
        silent: Bool
    ) async throws -> PrivatePushDeliveryResult {
        let answer = lock.withLock { () -> Answer in
            recorded.append(Request(title: title, data: data, idempotencyKey: idempotencyKey, silent: silent))
            return scripted.isEmpty ? .delivered : scripted.removeFirst()
        }
        switch answer {
        case .delivered:
            break
        case .notDelivered:
            return PrivatePushDeliveryResult(delivered: false, errorCode: "apns/throttled", shouldDropSubscription: false)
        case .fail:
            throw PrivateAccountAPIError.http(500)
        case .hold:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    heldCall = continuation
                    let waiters = heldWaiters
                    heldWaiters.removeAll()
                    lock.unlock()
                    waiters.forEach { $0.resume() }
                }
            }
        }
        return PrivatePushDeliveryResult(delivered: true, errorCode: nil, shouldDropSubscription: false)
    }

    func login(email: String, password: String) async throws -> PrivateAccountSession { session }
    func currentUser(accessToken: String) async throws -> PrivateAccountUser { session.user }
    func refresh(refreshToken: String) async throws -> PrivateAccountSession { session }
    func logout(refreshToken: String) async throws {}
    func billingOverview(accessToken: String) async throws -> PrivateBillingOverview {
        PrivateBillingOverview(
            plan: .init(billingPeriod: "monthly", priceUsd: 4.99, provider: "test", trialDays: 0),
            subscription: PrivateSubscriptionSnapshot(
                daysRemaing: 30,
                daysRemaining: 30,
                email: "test@example.com",
                endsAt: nil,
                portalUrl: nil,
                renewsAt: nil,
                status: "active",
                subscribed: true,
                trialEndsAt: nil
            )
        )
    }
    func createPortal(accessToken: String) async throws -> URL {
        URL(string: "https://example.com")!
    }
    func deliverLiveActivity(
        accessToken: String,
        event: String,
        contentState: PrivateLiveActivityContentState,
        timestampSeconds: Int64,
        liveActivityToken: String,
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String
    ) async throws -> PrivatePushDeliveryResult {
        PrivatePushDeliveryResult(delivered: true, errorCode: nil, shouldDropSubscription: false)
    }
}
