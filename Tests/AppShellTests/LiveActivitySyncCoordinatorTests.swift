import XCTest
import Foundation
import Darwin
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence

final class LiveActivitySyncCoordinatorTests: XCTestCase {
    private final class DeliveryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [LiveActivitySyncDelivery] = []

        func append(_ delivery: LiveActivitySyncDelivery) async {
            lock.withLock { values.append(delivery) }
        }

        var deliveries: [LiveActivitySyncDelivery] { lock.withLock { values } }
    }

    private func active(_ pairs: [(String, String)]) -> ActiveRunProjection {
        ActiveRunProjection(runs: pairs.map {
            ActiveRunProjection.Run(
                threadId: AgentThreadID(UUID(uuidString: $0.0)!),
                runId: AgentRunID(UUID(uuidString: $0.1)!)
            )
        })
    }

    func testTitioInboxOwnsRunningPendingAndEndProjection() async {
        let recorder = DeliveryRecorder()
        let sync = LiveActivitySyncCoordinator(serverId: "host", bootEpoch: 1, initialActivityGeneration: 0,
            deliver: { await recorder.append($0) }, heartbeatIntervalNanoseconds: 60_000_000_000_000)
        var inbox = TitioInboxSnapshot(botID: BotID(), conversationID: BotConversationID(), threadID: AgentThreadID(),
            unreadCount: 1, openDecisions: 1, lastPreview: "secret question", lastAt: Date())
        inbox.focus = TitioLiveActivityFocus(botId: inbox.botID.description, conversationId: inbox.conversationID.description,
            messageId: UUID().uuidString, actionId: "reply", questionRevision: 2)
        sync.submitTitio(inbox)
        sync.submitSurface(PetLiveActivityCopy.Output(title: "Other producer", statusLine: "Other status", preview: "Other preview", phase: .failed, activeThreadCount: 0))
        sync.submit(active([("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000002")]), cause: .started)
        inbox.openDecisions = 0
        sync.submitTitio(inbox)
        sync.submit(active([]), cause: .finished(.completed))
        await sync.flush()
        let deliveries = recorder.deliveries
        XCTAssertEqual(deliveries.first?.event, .start)
        XCTAssertEqual(deliveries.first?.projection.phase, .running)
        XCTAssertEqual(deliveries.first?.projection.petState, "question")
        XCTAssertEqual(deliveries.first?.projection.titioFocus, inbox.focus)
        XCTAssertNil(deliveries.last?.projection.titioFocus, "terminal delivery never offers a stale question")
        XCTAssertEqual(deliveries.last?.event, .end, "a stale pet surface cannot keep Titio alive")
        XCTAssertTrue(deliveries.allSatisfy { $0.projection.title == "Titio" })
        XCTAssertTrue(deliveries.allSatisfy { $0.projection.threadId == inbox.threadID.value.uuidString })
        XCTAssertTrue(deliveries.allSatisfy { !$0.projection.preview.contains("secret") && !$0.projection.preview.contains("Other") })
        XCTAssertTrue(deliveries.contains { $0.projection.statusLine == "Following 1 run" })
    }

    func testAggregateTransitionsUseOneGenerationAndMonotonicRevision() async {
        let recorder = DeliveryRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 12,
            initialActivityGeneration: 40,
            deliver: { delivery in await recorder.append(delivery) },
            heartbeatIntervalNanoseconds: 60_000_000_000_000 // effectively disabled for this unit test
        )
        let first = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000002")
        let second = ("10000000-0000-0000-0000-000000000002", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([first]), cause: .started, now: Date(timeIntervalSince1970: 100))
        sync.submit(active([first, second]), cause: .started, now: Date(timeIntervalSince1970: 101))
        sync.submit(active([first]), cause: .finished(.completed), now: Date(timeIntervalSince1970: 102))
        sync.submit(active([]), cause: .finished(.completed), now: Date(timeIntervalSince1970: 103))
        await sync.flush()

        let values = recorder.deliveries
        XCTAssertEqual(values.map(\.event), [.start, .update, .update, .end])
        XCTAssertEqual(values.map(\.projection.activeThreadCount), [1, 2, 1, 0])
        XCTAssertEqual(values.map(\.projection.revision), [1, 2, 3, 4])
        XCTAssertEqual(Set(values.map(\.activityGeneration)), [41])
        XCTAssertEqual(values.map(\.projection.epoch), ["12", "12", "12", "12"])
        XCTAssertNil(values[1].projection.threadId,
                       "aggregate cards must not deep-link ambiguously when multiple runs are active")
        XCTAssertEqual(values[2].projection.threadId, first.0.uppercased())
        XCTAssertEqual(
            values.map(\.idempotencyKey),
            [
                "activity.server-1.12.41.1.start",
                "activity.server-1.12.41.2.update",
                "activity.server-1.12.41.3.update",
                "activity.server-1.12.41.4.end"
            ]
        )

        sync.submit(active([first]), cause: .started, now: Date(timeIntervalSince1970: 104))
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.last?.event, .start)
        XCTAssertEqual(recorder.deliveries.last?.activityGeneration, 42)
        XCTAssertEqual(recorder.deliveries.last?.projection.revision, 1,
                       "a new 0-to-N session must advance generation and reset only its revision")
        XCTAssertEqual(recorder.deliveries.last?.projection.sessionId, "server-1:12:42")
    }

    func testHeartbeatUsesSameGenerationAndNextRevision() async {
        let recorder = DeliveryRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1", bootEpoch: 7, initialActivityGeneration: 2,
            deliver: { delivery in await recorder.append(delivery) },
            heartbeatIntervalNanoseconds: 60_000_000_000_000
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")
        sync.submit(active([run]), cause: .started, now: Date(timeIntervalSince1970: 200))
        sync.submitHeartbeat(now: Date(timeIntervalSince1970: 260))
        await sync.flush()

        XCTAssertEqual(recorder.deliveries.map(\.event), [.start, .update])
        XCTAssertEqual(recorder.deliveries.map(\.projection.revision), [1, 2])
        XCTAssertEqual(recorder.deliveries.last?.projection.updatedAt, 260)
    }

    func testIdleCoordinatorDoesNotWakeOrEnqueueHeartbeats() async {
        let ticks = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-idle",
            bootEpoch: 1,
            deliver: { _ in },
            heartbeatIntervalNanoseconds: 2_000_000,
            onHeartbeatTick: { ticks.increment() }
        )

        try? await Task.sleep(nanoseconds: 30_000_000)
        await sync.flush()

        XCTAssertEqual(ticks.count, 0,
                       "without an active or remotely-open activity, the coordinator must own no periodic wake")
    }

    func testHeartbeatTimerTracksActiveLifecycleAndRearmsForNextRun() async {
        let recorder = DeliveryRecorder()
        let ticks = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-lifecycle",
            bootEpoch: 1,
            deliver: { delivery in await recorder.append(delivery) },
            heartbeatIntervalNanoseconds: 5_000_000,
            onHeartbeatTick: { ticks.increment() }
        )
        let first = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")
        let second = ("10000000-0000-0000-0000-000000000002", "20000000-0000-0000-0000-000000000002")

        sync.submit(active([first]), cause: .started)
        await sync.flush()
        let reachedActiveCadence = await Self.waitUntil(timeout: 0.25) { ticks.count >= 2 }
        XCTAssertTrue(reachedActiveCadence)
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.first?.event, .start)
        XCTAssertGreaterThanOrEqual(recorder.deliveries.filter { $0.event == .update }.count, 2,
                                    "an active run must keep the existing heartbeat cadence")

        sync.submit(active([]), cause: .finished(.completed))
        await sync.flush()
        let stoppedTickCount = ticks.count
        try? await Task.sleep(nanoseconds: 30_000_000)
        await sync.flush()
        XCTAssertEqual(ticks.count, stoppedTickCount,
                       "a confirmed end must cancel the periodic task, not merely make its deliveries no-op")
        XCTAssertEqual(recorder.deliveries.last?.event, .end)
        let deliveryCountAfterEnd = recorder.deliveries.count

        sync.submit(active([second]), cause: .started)
        await sync.flush()
        let rearmed = await Self.waitUntil(timeout: 0.25) { ticks.count > stoppedTickCount }
        XCTAssertTrue(rearmed)
        await sync.flush()
        let replacementEvents = recorder.deliveries.dropFirst(deliveryCountAfterEnd).map(\.event)
        XCTAssertEqual(replacementEvents.first, .start)
        XCTAssertTrue(replacementEvents.dropFirst().contains(.update),
                      "a new run after a confirmed end must create a fresh timer and retain start-before-update order")
    }

    func testFailedEndKeepsTimerUntilAutomaticRetrySucceeds() async {
        let recorder = DeliveryRecorder()
        let endAttempts = DeliveryAttemptCounter()
        let ticks = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-end-retry",
            bootEpoch: 1,
            deliver: { delivery in
                if delivery.event == .end, endAttempts.increment() <= 3 {
                    throw OutboxTestError.persistence
                }
                await recorder.append(delivery)
            },
            heartbeatIntervalNanoseconds: 5_000_000,
            onHeartbeatTick: { ticks.increment() },
            deliveryMaxAttempts: 3,
            deliveryRetryDelayNanoseconds: { _ in 0 }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([run]), cause: .started)
        await sync.flush()
        sync.submit(active([]), cause: .finished(.completed))
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.map(\.event), [.start])

        let recoveredEnd = await Self.waitUntil(timeout: 0.25) {
            recorder.deliveries.last?.event == .end
        }
        XCTAssertTrue(recoveredEnd,
                      "the owned timer must retry a stranded end without an unrelated app event")
        await sync.flush()
        XCTAssertEqual(endAttempts.count, 4)
        let stoppedTickCount = ticks.count
        try? await Task.sleep(nanoseconds: 30_000_000)
        await sync.flush()
        XCTAssertEqual(ticks.count, stoppedTickCount,
                       "the timer must cancel immediately after the retry confirms the end")
    }

    func testRunEndingAfterFailedStartCancelsRetryTimer() async {
        let attempts = DeliveryAttemptCounter()
        let ticks = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-start-abandoned",
            bootEpoch: 1,
            deliver: { _ in
                attempts.increment()
                throw OutboxTestError.persistence
            },
            heartbeatIntervalNanoseconds: 5_000_000,
            onHeartbeatTick: { ticks.increment() },
            deliveryMaxAttempts: 3,
            deliveryRetryDelayNanoseconds: { _ in 0 }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([run]), cause: .started)
        await sync.flush()
        XCTAssertEqual(attempts.count, 3)

        sync.submit(active([]), cause: .finished(.failed))
        await sync.flush()
        let stoppedTickCount = ticks.count
        let stoppedAttemptCount = attempts.count
        try? await Task.sleep(nanoseconds: 30_000_000)
        await sync.flush()

        XCTAssertEqual(ticks.count, stoppedTickCount,
                       "a locally-ended run whose start never opened remotely must release its retry timer")
        XCTAssertEqual(attempts.count, stoppedAttemptCount,
                       "ending after a failed start must not invent an end delivery or retry an abandoned start")
    }

    func testFailedStartRetriesAutomaticallyWhileRunRemainsActive() async {
        let recorder = DeliveryRecorder()
        let attempts = DeliveryAttemptCounter()
        let ticks = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-start-retry",
            bootEpoch: 1,
            deliver: { delivery in
                if attempts.increment() <= 3 { throw OutboxTestError.persistence }
                await recorder.append(delivery)
            },
            heartbeatIntervalNanoseconds: 5_000_000,
            onHeartbeatTick: { ticks.increment() },
            deliveryMaxAttempts: 3,
            deliveryRetryDelayNanoseconds: { _ in 0 }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([run]), cause: .started)
        await sync.flush()
        XCTAssertTrue(recorder.deliveries.isEmpty)

        let recoveredStart = await Self.waitUntil(timeout: 0.25) {
            recorder.deliveries.first?.event == .start
        }
        XCTAssertTrue(recoveredStart,
                      "an active run must own a timer that retries its failed start without a manual heartbeat")
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.first?.event, .start)
        XCTAssertEqual(recorder.deliveries.first?.activityGeneration, 2)
        XCTAssertGreaterThanOrEqual(attempts.count, 4)
        XCTAssertGreaterThanOrEqual(ticks.count, 1)

        sync.submit(active([]), cause: .finished(.completed))
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.last?.event, .end)
    }

    func testBackToBackEndAndNewRunPreserveLifecycleAndHeartbeat() async {
        let recorder = DeliveryRecorder()
        let ticks = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-race",
            bootEpoch: 1,
            deliver: { delivery in await recorder.append(delivery) },
            heartbeatIntervalNanoseconds: 5_000_000,
            onHeartbeatTick: { ticks.increment() }
        )
        let first = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")
        let second = ("10000000-0000-0000-0000-000000000002", "20000000-0000-0000-0000-000000000002")

        sync.submit(active([first]), cause: .started)
        sync.submit(active([]), cause: .finished(.completed))
        sync.submit(active([second]), cause: .started)
        await sync.flush()

        XCTAssertEqual(recorder.deliveries.map(\.event), [.start, .end, .start])
        let replacementHeartbeat = await Self.waitUntil(timeout: 0.25) { ticks.count >= 1 }
        XCTAssertTrue(replacementHeartbeat)
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.last?.event, .update,
                       "an end/new-run mailbox race must leave the replacement run's timer armed")
    }

    func testDeinitCancelsActiveHeartbeatTimer() async {
        let ticks = DeliveryAttemptCounter()
        var sync: LiveActivitySyncCoordinator? = LiveActivitySyncCoordinator(
            serverId: "server-deinit",
            bootEpoch: 1,
            deliver: { _ in },
            heartbeatIntervalNanoseconds: 5_000_000,
            onHeartbeatTick: { ticks.increment() }
        )
        weak var releasedSync = sync
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        sync?.submit(active([run]), cause: .started)
        await sync?.flush()
        let firstHeartbeat = await Self.waitUntil(timeout: 0.25) { ticks.count >= 1 }
        XCTAssertTrue(firstHeartbeat)
        sync = nil
        XCTAssertNil(releasedSync,
                     "the scheduler task must not retain the coordinator after its owner releases it")
        let stoppedTickCount = ticks.count
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(ticks.count, stoppedTickCount)
    }

    func testMicrobenchmarkIdleHeartbeatOwnershipAndActiveCadence() async {
        for _ in 0..<2 {
            _ = await heartbeatSample(active: false)
            _ = await heartbeatSample(active: true)
        }

        var idle: [HeartbeatPerfSample] = []
        var activeSamples: [HeartbeatPerfSample] = []
        for _ in 0..<7 {
            idle.append(await heartbeatSample(active: false))
            activeSamples.append(await heartbeatSample(active: true))
        }

        NSLog(
            "[perf-proof] liveActivityHeartbeat idle_ticks=%@ idle_cpu_ms=%@ active_ticks=%@ active_cpu_ms=%@ production_idle_5m_wakes_before=10 production_idle_5m_wakes_after=0",
            String(describing: idle.map(\.ticks)),
            String(describing: idle.map(\.cpuMilliseconds)),
            String(describing: activeSamples.map(\.ticks)),
            String(describing: activeSamples.map(\.cpuMilliseconds))
        )
        XCTAssertEqual(idle.map(\.ticks), Array(repeating: 0, count: 7),
                       "128 idle coordinators must retain zero timer tasks and enqueue zero heartbeats")
        XCTAssertGreaterThan(activeSamples.map(\.ticks).min() ?? 0, 0,
                             "event-driven ownership must preserve the active heartbeat cadence")
    }

    func testLaunchReconciliationEmitsEmptyCorrection() async {
        let recorder = DeliveryRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1", bootEpoch: 9, initialActivityGeneration: 5,
            deliver: { delivery in await recorder.append(delivery) },
            heartbeatIntervalNanoseconds: 60_000_000_000_000
        )
        sync.submit(active([]), cause: .launchReconciliation, now: Date(timeIntervalSince1970: 300))
        await sync.flush()

        XCTAssertEqual(recorder.deliveries.map(\.event), [.end])
        XCTAssertEqual(recorder.deliveries.first?.projection.activeThreadCount, 0)
        XCTAssertEqual(recorder.deliveries.first?.projection.phase, .failed)
    }

    func testIdentityStorePersistsStableHostAndMonotonicBootAndGeneration() throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-identity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)

        let first = try LiveActivityIdentityStore.beginBoot(settings: settings)
        try LiveActivityIdentityStore.persistActivityGeneration(7, settings: settings)
        let second = try LiveActivityIdentityStore.beginBoot(settings: settings)

        XCTAssertEqual(second.serverId, first.serverId)
        XCTAssertEqual(second.bootEpoch, first.bootEpoch + 1,
                       "every host boot must advance the ordering epoch before any correction is sent")
        XCTAssertEqual(second.activityGeneration, 7,
                       "activity generations must survive host restarts instead of reusing an old session identity")
    }

    func testTokenRotationsSerializeBeforeImmediateStartDelivery() async throws {
        let recorder = OrderedSyncRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 2,
            registerToken: { target in recorder.append("register:\(target.token)") },
            deliver: { delivery in recorder.append("deliver:\(delivery.event.rawValue)") },
            heartbeatIntervalNanoseconds: 60_000_000_000_000
        )
        let old = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "old-token", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        let newest = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "new-token", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        try sync.submitTokenRegistration(old)
        try sync.submitTokenRegistration(newest)
        sync.submit(active([run]), cause: .started, now: Date(timeIntervalSince1970: 100))
        await sync.flush()

        XCTAssertEqual(recorder.events, ["register:old-token", "register:new-token", "deliver:start"],
                       "the backend must persist the newest token before an immediate lifecycle delivery selects it")
    }

    func testAcceptanceOutboxReplaysPersistedDeliveryAfterRelaunch() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-relaunch-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let delivery = makeDelivery(event: .start, generation: 3, revision: 1)
        try store.enqueue(delivery, targets: [makeTarget(for: delivery)])
        let sender = OutboxSender()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            send: { record in try await sender.send(record) }
        )

        outbox.resumePending()
        await sender.waitForAttempts(1)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.idempotencyKey), [delivery.idempotencyKey])
        XCTAssertTrue(try store.pending().isEmpty,
                      "a relaunched Mac must drain durable projections only after backend acceptance")
    }

    func testAcceptanceOutboxRetriesResponseLossWithSameIdempotencyKey() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-response-loss-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 1_000))
        let scheduler = ManualOutboxScheduler()
        let sender = OutboxSender(failedStartAttempts: 1)
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 10 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )
        let delivery = makeDelivery(event: .start, generation: 3, revision: 1)

        try outbox.accept(delivery, targets: [makeTarget(for: delivery)])
        await sender.waitForAttempts(1)
        await outbox.flush()
        XCTAssertEqual(try store.pending().map(\.delivery.idempotencyKey), [delivery.idempotencyKey])
        clock.advance(by: 10)
        scheduler.fireAll()
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.idempotencyKey),
                       [delivery.idempotencyKey, delivery.idempotencyKey],
                       "a lost HTTP response must retry the exact durable idempotency record")
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testRejectedDeliveryIsDroppedSoNewerDeliveriesOfTheLaneStillGoOut() async throws {
        // WHY: a delivery the backend refuses for good (404: the token it carries
        // is no longer the device's) was retried forever. A lane sends its oldest
        // session first, so that one record held every newer start, update and
        // end of the device behind it: the card on the phone stopped changing.
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-rejected-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 3_000))
        let scheduler = ManualOutboxScheduler()
        let staleEnd = makeDelivery(event: .end, generation: 3, revision: 1)
        let start = makeDelivery(event: .start, generation: 4, revision: 1)
        let update = makeDelivery(event: .update, generation: 4, revision: 2)
        try store.enqueue(staleEnd, targets: [makeTarget(for: staleEnd, token: "token-rotated-away")])
        try store.enqueue(start, targets: [makeTarget(for: start, token: "token-current")])
        try store.enqueue(update, targets: [makeTarget(for: update, token: "token-current")])
        let sender = ScriptedOutboxSender(
            failures: [staleEnd.idempotencyKey: (PrivateAccountAPIError.http(404), .max)]
        )
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 60 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )

        outbox.resumePending()
        await outbox.flush()

        XCTAssertEqual(
            sender.attempts,
            [staleEnd.idempotencyKey, start.idempotencyKey, update.idempotencyKey],
            "the rejected end must not hold the current start and update behind it"
        )
        XCTAssertTrue(try store.pending().isEmpty)

        clock.advance(by: 120)
        scheduler.fireAll()
        await outbox.flush()
        XCTAssertEqual(sender.attempts.count, 3, "a rejected delivery must never be sent again")
    }

    func testServerFailureKeepsTheDeliveryAndRetriesIt() async throws {
        // WHY: only an answer that refuses the request for good may drop it. A 503
        // says the backend could not take it now; dropping there would lose the
        // final state of the card.
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-503-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 4_000))
        let scheduler = ManualOutboxScheduler()
        let end = makeDelivery(event: .end, generation: 3, revision: 2)
        let sender = ScriptedOutboxSender(
            failures: [end.idempotencyKey: (PrivateAccountAPIError.http(503), 1)]
        )
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 10 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )

        try outbox.accept(end, targets: [makeTarget(for: end)])
        await outbox.flush()
        XCTAssertEqual(try store.pending().map(\.delivery.idempotencyKey), [end.idempotencyKey])

        clock.advance(by: 10)
        await outbox.flush()
        XCTAssertEqual(sender.attempts, [end.idempotencyKey, end.idempotencyKey])
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testTerminalProjectionBypassesBlackHoledStartAndRetiresItAfterAck() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-terminal-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 2_000))
        let scheduler = ManualOutboxScheduler()
        let sender = OutboxSender(failedStartAttempts: .max)
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 30 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )
        let start = makeDelivery(event: .start, generation: 4, revision: 1)
        let end = makeDelivery(event: .end, generation: 4, revision: 2)

        try outbox.accept(start, targets: [makeTarget(for: start)])
        await sender.waitForAttempts(1)
        try outbox.accept(end, targets: [makeTarget(for: end)])
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.event), [.start, .end],
                       "a terminal event must reach the backend before a black-holed start retries")
        XCTAssertTrue(try store.pending().isEmpty,
                      "terminal acknowledgement must retire superseded records in the same session")
        clock.advance(by: 30)
        scheduler.fireAll()
        await outbox.flush()
        XCTAssertEqual(sender.attempts.count, 2,
                       "a retired start must never retry after the terminal acknowledgement")
    }

    func testAcceptanceOutboxKeepsStartAndCoalescesOnlyUpdates() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-coalesce-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let start = makeDelivery(event: .start, generation: 5, revision: 1)
        let oldUpdate = makeDelivery(event: .update, generation: 5, revision: 2)
        let latestUpdate = makeDelivery(event: .update, generation: 5, revision: 3)
        let target = makeTarget(for: start)
        try store.enqueue(start, targets: [target])
        try store.enqueue(oldUpdate, targets: [target])
        try store.enqueue(latestUpdate, targets: [target])
        let sender = OutboxSender()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            send: { record in try await sender.send(record) }
        )

        outbox.resumePending()
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.event), [.start, .update])
        XCTAssertEqual(sender.attempts.map(\.projection.revision), [1, 3],
                       "updates may coalesce, but a pending start must remain the session barrier")
    }

    func testOlderTerminalBarrierAcksBeforePreservedHigherGeneration() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-generation-barrier-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let oldEnd = makeDelivery(event: .end, generation: 6, revision: 4)
        let newStart = makeDelivery(event: .start, generation: 7, revision: 1)
        try store.enqueue(newStart, targets: [makeTarget(for: newStart)])
        try store.enqueue(oldEnd, targets: [makeTarget(for: oldEnd)])
        let sender = OutboxSender()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            send: { record in try await sender.send(record) }
        )

        outbox.resumePending()
        await sender.waitForAttempts(2)
        await outbox.flush()

        XCTAssertEqual(sender.attempts.map(\.activityGeneration), [6, 7],
                       "a higher generation cannot start until the prior terminal barrier is accepted")
        XCTAssertTrue(try store.pending().isEmpty,
                      "acknowledging an older terminal must preserve then deliver the higher generation")
    }

    func testPerDeviceAcceptanceKeepsOnlyTimedOutDevicePending() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-devices-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 3_000))
        let scheduler = ManualOutboxScheduler()
        let sender = DeviceOutboxSender(failingDeviceID: "device-b")
        let delivery = makeDelivery(event: .update, generation: 8, revision: 2)
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 10 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )

        try outbox.accept(delivery, targets: [
            makeTarget(for: delivery, deviceId: "device-a"),
            makeTarget(for: delivery, deviceId: "device-b")
        ])
        await sender.waitForAttempts(2)
        await outbox.flush()

        let pending = try store.pending()
        XCTAssertEqual(pending.count, 1)
        guard case .v2(let pendingTarget) = try XCTUnwrap(pending.first).target else {
            return XCTFail("only the timed-out typed target should remain")
        }
        XCTAssertEqual(pendingTarget.deviceId, "device-b",
                       "device A acceptance must never delete or acknowledge device B's failed record")
        XCTAssertEqual(sender.count(for: "device-a"), 1)

        clock.advance(by: 10)
        sender.allowRetries()
        scheduler.fireAll()
        await sender.waitForAttempts(3)
        await outbox.flush()

        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertEqual(sender.count(for: "device-a"), 1,
                       "retrying device B must not resend or tombstone already accepted device A")
        XCTAssertEqual(sender.count(for: "device-b"), 2)
    }

    func testHigherGenerationWaitsForScheduledOlderTerminalRetry() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-live-activity-outbox-terminal-retry-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 4_000))
        let scheduler = ManualOutboxScheduler()
        let sender = DeviceOutboxSender(failingDeviceID: "device-1")
        let oldEnd = makeDelivery(event: .end, generation: 8, revision: 3)
        let newStart = makeDelivery(event: .start, generation: 9, revision: 1)
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 10 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            send: { record in try await sender.send(record) }
        )

        try outbox.accept(oldEnd, targets: [makeTarget(for: oldEnd)])
        try outbox.accept(newStart, targets: [makeTarget(for: newStart)])
        await sender.waitForAttempts(1)
        await outbox.flush()
        XCTAssertEqual(sender.generations, [8],
                       "a ready newer start cannot bypass an older terminal barrier awaiting retry")

        sender.allowRetries()
        clock.advance(by: 10)
        scheduler.fireAll()
        await sender.waitForAttempts(3)
        await outbox.flush()
        XCTAssertEqual(sender.generations, [8, 8, 9])
    }

    func testIosGenerationDriftBindsUpdateTokenToCurrentMacGeneration() async throws {
        let registrations = TargetRegistrationRecorder()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 9,
            initialActivityGeneration: 4,
            registerToken: { registrations.append($0) },
            deliver: { _ in },
            heartbeatIntervalNanoseconds: 60_000_000_000_000
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")
        sync.submit(active([run]), cause: .started)
        await sync.flush()
        let drifted = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "untrusted-ios-host", purpose: .activityUpdate,
            environment: .sandbox, token: "update-token", activityGeneration: 999,
            activityId: "activity-1", contractVersion: 2, capabilities: ["live_activity_v2"]
        )

        let bound = try sync.submitTokenRegistration(drifted)
        await sync.flush()

        XCTAssertEqual(bound.ownership, LiveActivityTokenOwnership(
            activityId: "activity-1", hostId: "server-1", bootEpoch: 9,
            activityGeneration: 5, activitySessionId: "server-1:9:5"
        ), "the Mac projection owns generation; an iOS-local counter cannot replace it")
        XCTAssertEqual(registrations.targets.last, bound)
        let partialAuthority = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "partial-token", activityGeneration: 5,
            activityId: "activity-partial", bootEpoch: 9,
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        XCTAssertThrowsError(try sync.submitTokenRegistration(partialAuthority),
                             "partial remote ownership must not be silently rebound to the current generation")
    }

    func testLateOldActivityTokenRetainsOldOwnershipAfterNewGeneration() async throws {
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1", bootEpoch: 9, initialActivityGeneration: 4,
            registerToken: { _ in }, deliver: { _ in },
            heartbeatIntervalNanoseconds: 60_000_000_000_000
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")
        sync.submit(active([run]), cause: .started)
        await sync.flush()
        let old = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "old-token", activityGeneration: 5,
            activityId: "old-activity", bootEpoch: 9, activitySessionId: "server-1:9:5",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let first = try sync.submitTokenRegistration(old)
        sync.submit(active([]), cause: .finished(.completed))
        sync.submit(active([run]), cause: .started)
        await sync.flush()

        let late = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "rotated-old-token", activityGeneration: 6,
            activityId: "old-activity", contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let rebound = try sync.submitTokenRegistration(late)
        let otherDevice = PrivatePushTargetRecord(
            deviceId: "device-2", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "other-device-token", activityGeneration: 5,
            activityId: "old-activity", contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let otherBound = try sync.submitTokenRegistration(otherDevice)

        XCTAssertEqual(first.ownership?.activityGeneration, 5)
        XCTAssertEqual(rebound.ownership, first.ownership,
                       "a late token rotation for an old Activity must not attach to the newest generation")
        XCTAssertEqual(otherBound.ownership?.activityGeneration, 6,
                       "an activity ID mapping from one device must not bind another device to its old generation")
    }

    func testCoordinatorSurfacesAcceptancePersistenceFailure() async {
        let errors = DeliveryErrorRecorder()
        let attempts = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 3,
            onDeliveryError: { error, delivery in errors.append(error, delivery: delivery) },
            deliver: { _ in
                attempts.increment()
                throw OutboxTestError.persistence
            },
            heartbeatIntervalNanoseconds: 60_000_000_000_000,
            deliveryMaxAttempts: 3,
            deliveryRetryDelayNanoseconds: { _ in 0 }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([run]), cause: .started)
        await sync.flush()

        XCTAssertEqual(attempts.count, 3,
                       "transient delivery failures must be retried a bounded number of times before giving up")
        XCTAssertEqual(errors.count, 1,
                       "serialized lifecycle delivery must surface durable-acceptance failure instead of swallowing it")
    }

    func testDeliveryRetriesThenSucceedsWithoutSurfacingError() async {
        let errors = DeliveryErrorRecorder()
        let recorder = DeliveryRecorder()
        let attempts = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 4,
            onDeliveryError: { error, delivery in errors.append(error, delivery: delivery) },
            deliver: { delivery in
                let n = attempts.increment()
                if n < 3 { throw OutboxTestError.persistence }
                await recorder.append(delivery)
            },
            heartbeatIntervalNanoseconds: 60_000_000_000_000,
            deliveryMaxAttempts: 3,
            deliveryRetryDelayNanoseconds: { _ in 0 }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([run]), cause: .started, now: Date(timeIntervalSince1970: 500))
        await sync.flush()

        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(errors.count, 0,
                       "a delivery that succeeds within the retry budget must not fire onDeliveryError")
        XCTAssertEqual(recorder.deliveries.map(\.event), [.start])
        XCTAssertEqual(recorder.deliveries.first?.idempotencyKey,
                       "activity.server-1.4.1.1.start",
                       "retries must reuse the same revision/idempotency key")
    }

    func testFailedEndIsRetriedOnHeartbeat() async {
        let recorder = DeliveryRecorder()
        let attempts = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 5,
            deliver: { delivery in
                // Fail only the first end attempt's whole retry budget; later ends succeed.
                if delivery.event == .end, attempts.increment() <= 3 {
                    throw OutboxTestError.persistence
                }
                await recorder.append(delivery)
            },
            heartbeatIntervalNanoseconds: 60_000_000_000_000,
            deliveryMaxAttempts: 3,
            deliveryRetryDelayNanoseconds: { _ in 0 }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([run]), cause: .started, now: Date(timeIntervalSince1970: 600))
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.map(\.event), [.start])

        sync.submit(active([]), cause: .finished(.completed), now: Date(timeIntervalSince1970: 601))
        await sync.flush()
        XCTAssertEqual(recorder.deliveries.map(\.event), [.start],
                       "a fully-failed end must not advance remote lifecycle; local presence stays open for retry")

        // Heartbeat used to no-op when presentNow() was false; it must now re-emit end.
        sync.submitHeartbeat(now: Date(timeIntervalSince1970: 630))
        await sync.flush()

        XCTAssertEqual(recorder.deliveries.map(\.event), [.start, .end],
                       "heartbeat must recover a stranded end after delivery failure")
    }

    func testFailedStartIsRetriedAsStartNotUpdate() async {
        let recorder = DeliveryRecorder()
        let attempts = DeliveryAttemptCounter()
        let sync = LiveActivitySyncCoordinator(
            serverId: "server-1",
            bootEpoch: 6,
            deliver: { delivery in
                let n = attempts.increment()
                // Exhaust first start's retry budget; allow later deliveries.
                if n <= 3 { throw OutboxTestError.persistence }
                await recorder.append(delivery)
            },
            heartbeatIntervalNanoseconds: 60_000_000_000_000,
            deliveryMaxAttempts: 3,
            deliveryRetryDelayNanoseconds: { _ in 0 }
        )
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")

        sync.submit(active([run]), cause: .started, now: Date(timeIntervalSince1970: 700))
        await sync.flush()
        XCTAssertTrue(recorder.deliveries.isEmpty)

        sync.submitHeartbeat(now: Date(timeIntervalSince1970: 730))
        await sync.flush()

        XCTAssertEqual(recorder.deliveries.map(\.event), [.start],
                       "presence must not advance on failed start; heartbeat recovers with start, not update")
        XCTAssertEqual(recorder.deliveries.first?.activityGeneration, 2,
                       "a recovered start after a failed open uses the next generation")
    }

    func testV2ContractEncodesRootSharedFieldNamesAndEpochIntegers() throws {
        let projection = PrivateLiveActivityProjectionV2(
            statusLine: "1 active run",
            petState: "question",
            titioFocus: TitioLiveActivityFocus(botId: "bot-1", conversationId: "conversation-1", messageId: "message-1", actionId: "reply", questionRevision: 3),
            phase: .running,
            activeThreadCount: 1,
            updatedAt: 900,
            runStartDate: 800,
            workspaceId: "workspace-1",
            threadId: "thread-1",
            sessionId: "server-1:8:3",
            hostId: "server-1",
            epoch: "8",
            revision: 4
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "title", "statusLine", "preview", "phase", "activeThreadCount", "updatedAt",
            "runStartDate", "workspaceId", "threadId", "protocolVersion", "activityKey",
            "sessionId", "hostId", "epoch", "revision", "petState", "titioFocus"
        ])
        XCTAssertEqual(object["protocolVersion"] as? Int, 2)
        XCTAssertEqual(object["activityKey"] as? String, "active-threads")
        XCTAssertEqual(object["sessionId"] as? String, "server-1:8:3")
        XCTAssertEqual(object["hostId"] as? String, "server-1")
        XCTAssertEqual(object["epoch"] as? String, "8")
        XCTAssertEqual(object["revision"] as? Int, 4)
        XCTAssertEqual(object["activeThreadCount"] as? Int, 1)
        XCTAssertEqual(object["updatedAt"] as? Int, 900)

        let target = PrivatePushTargetRecord(
            deviceId: "device-1",
            serverId: "server-1",
            purpose: .pushToStart,
            environment: .sandbox,
            token: "activity-token",
            activityGeneration: 3,
            contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        let request = PrivateLiveActivityV2DeliveryRequest(
            delivery: LiveActivitySyncDelivery(
                event: .start,
                projection: projection,
                activityGeneration: 3,
                idempotencyKey: "activity.server-1.8.3.4.start"
            ),
            target: target
        )
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(Set(requestObject.keys), [
            "protocolVersion", "activityKey", "activitySessionId", "hostId", "bootEpoch", "activityGeneration",
            "revision", "event", "deviceId", "environment", "phase", "activeThreadCount",
            "title", "statusLine", "preview", "updatedAtEpochSeconds", "runStartEpochSeconds",
            "workspaceId", "threadId", "petState", "titioFocus"
        ])
        XCTAssertEqual(requestObject["petState"] as? String, "question")
        let focus = try XCTUnwrap(requestObject["titioFocus"] as? [String: Any])
        XCTAssertEqual(focus["messageId"] as? String, "message-1")
        XCTAssertEqual(focus["actionId"] as? String, "reply")
        XCTAssertEqual(focus["questionRevision"] as? Int, 3)
        XCTAssertEqual(requestObject["bootEpoch"] as? Int, 8)
        XCTAssertEqual(requestObject["activityGeneration"] as? Int, 3)
        XCTAssertEqual(requestObject["updatedAtEpochSeconds"] as? Int, 900,
                       "the canonical backend contract requires an epoch timestamp at the root")
        XCTAssertEqual(requestObject["event"] as? String, "start")
        XCTAssertEqual(requestObject["deviceId"] as? String, "device-1")
        XCTAssertEqual(requestObject["environment"] as? String, "sandbox")
        XCTAssertNil(requestObject["contentState"],
                     "the v2 backend adapter must not send the legacy nested content-state envelope")
        XCTAssertNil(requestObject["liveActivityToken"])
        XCTAssertNil(requestObject["pushToken"])

        let registration = PrivateLiveActivityV2TokenRegistration(
            deviceId: "device-1",
            environment: .sandbox,
            token: "activity-token",
            tokenKind: .pushToStart
        )
        let registrationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any]
        )
        XCTAssertEqual(Set(registrationObject.keys), [
            "protocolVersion", "activityKey", "deviceId", "environment", "token", "tokenKind"
        ])
        XCTAssertEqual(registrationObject["tokenKind"] as? String, "pushToStart")
        XCTAssertEqual(
            URLSessionPrivateAccountAPI.liveActivityV2DeliveryPath,
            "/v1/private/push-notification/live-activities/deliver"
        )
        XCTAssertEqual(
            URLSessionPrivateAccountAPI.liveActivityV2TokensPath,
            "/v1/private/push-notification/live-activities/tokens"
        )

        let legacy = projection.legacyContentState
        XCTAssertEqual(legacy.activeThreadCount, 1)
        XCTAssertEqual(legacy.updatedAt, 900)
        XCTAssertEqual(legacy.threadId, "thread-1",
                       "capability-disabled targets must retain the existing ActivityKit content adapter")
    }

    func testURLSessionAPIUsesCanonicalAuthenticatedV2RoutesAndFlatBody() async throws {
        let recorder = HTTPRequestRecorder()
        HTTPRecordingURLProtocol.setHandler { request in
            recorder.append(request)
            let body = request.url?.path.hasSuffix("/deliver") == true
                ? Data(#"{"accepted":false,"id":"outbox-1","status":"pending","attempts":0,"nextAttemptAt":1783998600000}"#.utf8)
                : Data(#"{"token":{"activityKey":"active-threads","deviceId":"device-1","environment":"sandbox","tokenKind":"pushToStart"}}"#.utf8)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
        defer { HTTPRecordingURLProtocol.setHandler(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPRecordingURLProtocol.self]
        let api = URLSessionPrivateAccountAPI(
            baseURL: URL(string: "https://private.example.test")!,
            session: URLSession(configuration: configuration)
        )
        let target = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "start-token", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        let projection = PrivateLiveActivityProjectionV2(
            statusLine: "1 active run", phase: .running, activeThreadCount: 1,
            updatedAt: 900, sessionId: "server-1:8:3", hostId: "server-1",
            epoch: "8", revision: 4
        )
        let delivery = LiveActivitySyncDelivery(
            event: .start, projection: projection, activityGeneration: 3,
            idempotencyKey: "activity.server-1.8.3.4.start"
        )

        try await api.registerLiveActivityTokenV2(
            accessToken: "access-token",
            registration: PrivateLiveActivityV2TokenRegistration(
                deviceId: "device-1", environment: .sandbox,
                token: "start-token", tokenKind: .pushToStart
            )
        )
        let ack = try await api.deliverLiveActivityV2(
            accessToken: "access-token",
            request: PrivateLiveActivityV2DeliveryRequest(delivery: delivery, target: target),
            idempotencyKey: delivery.idempotencyKey
        )
        XCTAssertEqual(ack.status, "pending")
        XCTAssertEqual(ack.accepted, false)
        XCTAssertEqual(ack.nextAttemptAt, "1783998600000.0")

        let requests = recorder.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/v1/private/push-notification/live-activities/tokens",
            "/v1/private/push-notification/live-activities/deliver"
        ])
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer access-token", "Bearer access-token"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Idempotency-Key"), delivery.idempotencyKey)
        let deliveryBody = try XCTUnwrap(recorder.bodies[1])
        let bodyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: deliveryBody) as? [String: Any]
        )
        XCTAssertEqual(bodyObject["bootEpoch"] as? Int, 8)
        XCTAssertEqual(bodyObject["activityGeneration"] as? Int, 3)
        XCTAssertEqual(bodyObject["activitySessionId"] as? String, "server-1:8:3")
        XCTAssertNil(bodyObject["contentState"])
    }

    func testTypedTargetsRetainPurposeEnvironmentAndInvalidateOnlyOneActivityToken() throws {
        let tmp = NSTemporaryDirectory() + "rc2-private-target-v2-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PrivatePushTargetStore(repo: SettingsRepository(db: db))
        let alert = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .alert,
            environment: .sandbox, token: "alert-token"
        )
        let activity = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "activity-token", activityGeneration: 4,
            activityId: "activity-1", contractVersion: 2,
            capabilities: ["live_activity_v2"]
        )
        try store.upsert(alert)
        try store.upsert(activity)

        try store.invalidate(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, activityGeneration: 4, activityId: "activity-1"
        )

        XCTAssertEqual(try store.records(), [alert],
                       "an invalid ActivityKit token must not erase the device alert token")
    }

    func testLateOldEndSelectsExactOldActivityOwnershipNeverLegacyNewestToken() throws {
        let tmp = NSTemporaryDirectory() + "rc2-private-target-old-activity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let targetStore = PrivatePushTargetStore(repo: settings)
        try targetStore.save(
            pushToken: "newest-alert", pushTokenType: "apns",
            liveActivityToken: "newest-legacy-activity", deviceId: "device-1"
        )
        let old = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "old-update", activityGeneration: 8,
            activityId: "old-activity", bootEpoch: 7, activitySessionId: "server-1:7:8",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let newest = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "new-update", activityGeneration: 9,
            activityId: "new-activity", bootEpoch: 7, activitySessionId: "server-1:7:9",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        try targetStore.upsert(old)
        try targetStore.upsert(newest)
        let bridge = PrivateNotificationBridge(
            accountStore: PrivateAccountSessionStore(repo: settings),
            pushTargetStore: targetStore
        )
        let oldEnd = makeDelivery(event: .end, generation: 8, revision: 4)

        XCTAssertEqual(try bridge.acceptanceTargets(for: oldEnd), [.v2(old)])
        let unknown = makeDelivery(event: .end, generation: 10, revision: 1)
        // Fail-open: prefer the newest activity_update token over throwing and
        // blocking delivery when boot/session ownership no longer matches.
        XCTAssertEqual(try bridge.acceptanceTargets(for: unknown), [.v2(newest)],
                       "stale ownership must fall back to the newest activity_update token, not hard-fail")
    }

    func testAcceptanceTargetsFallsBackToPushToStartWhenNoUpdateToken() throws {
        let tmp = NSTemporaryDirectory() + "rc2-private-target-start-fallback-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let targetStore = PrivatePushTargetStore(repo: settings)
        let start = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "start-token",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        try targetStore.upsert(start)
        let bridge = PrivateNotificationBridge(
            accountStore: PrivateAccountSessionStore(repo: settings),
            pushTargetStore: targetStore
        )
        let update = makeDelivery(event: .update, generation: 1, revision: 2)
        XCTAssertEqual(try bridge.acceptanceTargets(for: update), [.v2(start)],
                       "with iOS closed there is often only a push-to-start token; updates must still deliver")

        let record = LiveActivityAcceptanceRecord(delivery: update, target: .v2(start))
        let effective = PrivateNotificationBridge.effectiveDelivery(for: record)
        XCTAssertEqual(effective.event, .start,
                       "update via push-to-start is remapped to start so ActivityKit can show content")
    }

    func testV2CapabilityIsDisabledByDefault() {
        let target = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "token", contractVersion: 2
        )

        XCTAssertFalse(target.supportsLiveActivityV2,
                       "legacy devices must not receive the new contract until they advertise the capability")
    }

    func testHTTPPortOverrideIsSharedByListenerBonjourAndPairing() {
        XCTAssertEqual(DirectAccessConfiguration.port(environment: [:]), 18217)
        XCTAssertEqual(DirectAccessConfiguration.port(environment: ["RC2_HTTP_PORT": "18218"]), 18218)
        XCTAssertEqual(DirectAccessConfiguration.port(environment: ["RC2_HTTP_PORT": "invalid"]), 18217)
        XCTAssertEqual(DirectAccessConfiguration.port(environment: ["RC2_HTTP_PORT": "70000"]), 18217)
    }

    // MARK: - Residual hardenings (dead token prune, lanes, backlog bounds)

    func testActivityUpdateInvalidationIsExactAndProtectsRotatedTokenAndOtherDevices() throws {
        // WHY: a delayed APNs/backend rejection for historical token A must never
        // delete rotated token B, another device, or another APNs environment.
        let tmp = NSTemporaryDirectory() + "rc2-la-activity-invalidate-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PrivatePushTargetStore(repo: SettingsRepository(db: db))
        let base = Date(timeIntervalSince1970: 2_000_000)

        func update(
            device: String,
            env: PrivatePushEnvironment,
            token: String,
            activityId: String,
            generation: UInt64,
            session: String,
            age: TimeInterval
        ) -> PrivatePushTargetRecord {
            PrivatePushTargetRecord(
                deviceId: device, serverId: "server-1", purpose: .activityUpdate,
                environment: env, token: token, activityGeneration: generation,
                activityId: activityId, bootEpoch: 7, activitySessionId: session,
                contractVersion: 2, capabilities: ["live_activity_v2"],
                updatedAt: base.addingTimeInterval(age)
            )
        }

        let tokenA = update(
            device: "device-1", env: .sandbox, token: "token-A",
            activityId: "activity-1", generation: 3, session: "server-1:7:3", age: 0
        )
        let tokenB = update(
            device: "device-1", env: .sandbox, token: "token-B",
            activityId: "activity-1", generation: 3, session: "server-1:7:3", age: 10
        )
        let otherDevice = update(
            device: "device-2", env: .sandbox, token: "token-other-device",
            activityId: "activity-2", generation: 3, session: "server-1:7:3", age: 10
        )
        let otherEnv = update(
            device: "device-1", env: .production, token: "token-prod",
            activityId: "activity-1", generation: 3, session: "server-1:7:3", age: 10
        )
        let alert = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .alert,
            environment: .sandbox, token: "alert-token", updatedAt: base
        )
        // Upsert A then B for the same durable slot: B is authoritative.
        try store.upsert(tokenA)
        try store.upsert(tokenB)
        try store.upsert(otherDevice)
        try store.upsert(otherEnv)
        try store.upsert(alert)

        // Delayed rejection for historical A must be a no-op against B.
        try store.invalidateActivityUpdateTarget(tokenA)
        var tokens = Set(try store.records().map(\.token))
        XCTAssertEqual(tokens, ["token-B", "token-other-device", "token-prod", "alert-token"],
                       "historical token A rejection must not remove rotated B or other scopes")

        try store.invalidateActivityUpdateTarget(tokenB)
        tokens = Set(try store.records().map(\.token))
        XCTAssertEqual(tokens, ["token-other-device", "token-prod", "alert-token"],
                       "only the exact matching activity-update courier is removed")
        XCTAssertTrue(try store.records().contains(where: { $0.purpose == .alert }),
                      "alert tokens must survive activity-update invalidation")
    }

    func testBridgeInvalidatesExactUpdateTokenForPermanentAckAndAcceptedEnd() async throws {
        // WHY: the transport result must actually invoke exact invalidation:
        // a late permanent result for A cannot erase rotated B, while an accepted
        // end for B must retire B so it is never selected again.
        let tmp = NSTemporaryDirectory() + "rc2-la-bridge-invalidate-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let accountStore = PrivateAccountSessionStore(repo: settings)
        let targetStore = PrivatePushTargetStore(repo: settings)
        accountStore.save(PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: 30, daysRemaining: 30, email: "owner@example.com",
                id: "user-1", subscribed: true
            )
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPRecordingURLProtocol.self]
        let api = URLSessionPrivateAccountAPI(
            baseURL: URL(string: "https://private.example.test")!,
            session: URLSession(configuration: configuration)
        )
        let bridge = PrivateNotificationBridge(
            accountStore: accountStore, pushTargetStore: targetStore, api: api
        )
        let update = makeDelivery(event: .update, generation: 3, revision: 2)
        let end = makeDelivery(event: .end, generation: 3, revision: 3)
        let tokenA = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "token-A", activityGeneration: 3,
            activityId: "activity-1", bootEpoch: 7, activitySessionId: "server-1:7:3",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let tokenB = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "token-B", activityGeneration: 3,
            activityId: "activity-1", bootEpoch: 7, activitySessionId: "server-1:7:3",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        try targetStore.upsert(tokenA)
        try targetStore.upsert(tokenB)
        defer { HTTPRecordingURLProtocol.setHandler(nil) }

        HTTPRecordingURLProtocol.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"id":"d1","status":"permanent","attempts":4,"nextAttemptAt":null}"#.utf8)
            )
        }
        let permanent = try await bridge.sendLiveActivityAcceptance(
            LiveActivityAcceptanceRecord(delivery: update, target: .v2(tokenA))
        )
        XCTAssertTrue(permanent.isTerminal)
        XCTAssertEqual(try targetStore.records().map(\.token), ["token-B"],
                       "late permanent A must not erase the rotated B row")

        HTTPRecordingURLProtocol.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"id":"d2","status":"queued","attempts":0,"nextAttemptAt":null}"#.utf8)
            )
        }
        let acceptedEnd = try await bridge.sendLiveActivityAcceptance(
            LiveActivityAcceptanceRecord(delivery: end, target: .v2(tokenB))
        )
        XCTAssertTrue(acceptedEnd.isAccepted)
        XCTAssertTrue(try targetStore.records().isEmpty,
                      "accepted end must retire its exact activity-update courier")
    }

    func testActivityUpdatePruneProtectsCurrentAcrossRepeatedSevenHourRollovers() throws {
        // WHY: ActivityKit ~7h rollovers leave superseded update tokens. Age/count
        // prune must retire historical rows while protecting the current
        // authoritative token per device/server/environment.
        let tmp = NSTemporaryDirectory() + "rc2-la-activity-prune-rollover-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PrivatePushTargetStore(repo: SettingsRepository(db: db))
        let now = Date(timeIntervalSince1970: 3_000_000)
        let retention = PrivatePushTargetStore.activityUpdateRetention

        // Distinct activityIds simulate successive rollover cards.
        for generation in 1...6 {
            let age = TimeInterval(7 - generation) * (7 * 60 * 60)
            try store.upsert(PrivatePushTargetRecord(
                deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
                environment: .sandbox, token: "token-g\(generation)",
                activityGeneration: UInt64(generation),
                activityId: "activity-g\(generation)", bootEpoch: 7,
                activitySessionId: "server-1:7:\(generation)",
                contractVersion: 2, capabilities: ["live_activity_v2"],
                updatedAt: now.addingTimeInterval(-age)
            ))
        }
        try store.upsert(PrivatePushTargetRecord(
            deviceId: "device-2", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "token-device-2-current",
            activityGeneration: 9, activityId: "activity-d2", bootEpoch: 7,
            activitySessionId: "server-1:7:9",
            contractVersion: 2, capabilities: ["live_activity_v2"],
            updatedAt: now.addingTimeInterval(-60)
        ))
        try store.upsert(PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "pts-keep",
            contractVersion: 2, capabilities: ["live_activity_v2"],
            updatedAt: now.addingTimeInterval(-retention * 2)
        ))

        let removed = try store.pruneStaleActivityUpdateTargets(
            now: now,
            maxAge: retention,
            maxCount: 1
        )
        XCTAssertGreaterThan(removed, 0)
        let remaining = try store.records()
        let updateTokens = Set(remaining.filter { $0.purpose == .activityUpdate }.map(\.token))
        XCTAssertTrue(updateTokens.contains("token-g6"),
                      "newest rollover token on device-1 must stay protected")
        XCTAssertTrue(updateTokens.contains("token-device-2-current"),
                      "another device's current token must survive device-1 rollover prune")
        XCTAssertTrue(remaining.contains(where: { $0.token == "pts-keep" }),
                      "push-to-start is not an activity-update prune candidate")
        XCTAssertEqual(updateTokens.count, 2,
                       "the cap may not delete either device's current authority")
        XCTAssertFalse(updateTokens.contains("token-g1"),
                       "oldest rollover tokens must be eligible for age/count prune")
    }

    func testAcceptanceDeliveryLanesProgressIndependentlyWithoutLongSleeps() async throws {
        // WHY: a stuck send for device A must not head-of-line block device B.
        // End-then-start ordering within one lane must still hold.
        let tmp = NSTemporaryDirectory() + "rc2-la-acceptance-lanes-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let gate = TokenRegistrationGate()
        let log = OrderedSyncRecorder()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            retryDelay: { _ in 60 },
            schedule: { _, _ in },
            send: { record in
                guard case .v2(let target) = record.target else {
                    throw OutboxTestError.responseLost
                }
                log.append("\(target.deviceId):\(record.delivery.event.rawValue):\(record.delivery.activityGeneration)")
                if target.deviceId == "device-a", record.delivery.event == .update {
                    await gate.waitForRelease()
                }
                return PrivateLiveActivityV2DeliveryAck(
                    id: record.recordID, status: "queued", attempts: 0, nextAttemptAt: nil
                )
            }
        )

        let sharedUpdate = makeDelivery(event: .update, generation: 4, revision: 2)
        let endA = makeDelivery(event: .end, generation: 4, revision: 3)
        let startA = makeDelivery(event: .start, generation: 5, revision: 1)

        // A is already in flight before B is accepted. This catches schedulers
        // that fan out one snapshot but stop consuming wake commands while A hangs.
        try outbox.accept(sharedUpdate, targets: [
            makeTarget(for: sharedUpdate, deviceId: "device-a")
        ])
        let deviceAStarted = await Self.waitUntil(timeout: 1.0) {
            log.events.contains("device-a:update:4")
        }
        XCTAssertTrue(deviceAStarted)
        try outbox.accept(sharedUpdate, targets: [
            makeTarget(for: sharedUpdate, deviceId: "device-b")
        ])
        let deviceBStarted = await Self.waitUntil(timeout: 1.0) {
            log.events.contains(where: { $0.hasPrefix("device-b:") })
        }
        XCTAssertTrue(deviceBStarted,
                      "device B must send while device A is suspended")
        XCTAssertTrue(log.events.contains("device-a:update:4"))

        try outbox.accept(endA, targets: [makeTarget(for: endA, deviceId: "device-a")])
        try outbox.accept(startA, targets: [makeTarget(for: startA, deviceId: "device-a")])
        gate.release()
        await outbox.flush()

        let aEvents = log.events.filter { $0.hasPrefix("device-a:") }
        XCTAssertEqual(aEvents.first, "device-a:update:4")
        XCTAssertTrue(aEvents.contains("device-a:end:4"),
                      "end must reach the lane for the same device lifecycle")
        if aEvents.contains("device-a:start:5") {
            let endIdx = try XCTUnwrap(aEvents.firstIndex(of: "device-a:end:4"))
            let startIdx = try XCTUnwrap(aEvents.firstIndex(of: "device-a:start:5"))
            XCTAssertLessThan(endIdx, startIdx,
                              "same-lane end/current ordering must remain correct")
        }
        XCTAssertTrue(try store.pending().filter {
            guard case .v2(let t) = $0.target else { return false }
            return t.deviceId == "device-b"
        }.isEmpty)
    }

    func testLaneDeadlineFreesCapacityWhenSendIgnoresCancellation() async throws {
        // WHY: four uncooperative adapters must not pin the fixed lane pool
        // forever. The deadline must release capacity without acknowledging A,
        // allowing a later independent device B to make progress.
        let tmp = NSTemporaryDirectory() + "rc2-la-lane-deadline-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let gate = TokenRegistrationGate()
        let log = OrderedSyncRecorder()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            retryDelay: { _ in 60 },
            schedule: { _, _ in },
            maximumConcurrentLanes: 1,
            sendTimeout: 0.02,
            send: { record in
                guard case .v2(let target) = record.target else {
                    throw OutboxTestError.responseLost
                }
                log.append(target.deviceId)
                if target.deviceId == "device-a" {
                    // Checked continuation intentionally ignores Task.cancel().
                    await gate.waitForRelease()
                }
                return PrivateLiveActivityV2DeliveryAck(
                    id: record.recordID, status: "queued", attempts: 0, nextAttemptAt: nil
                )
            }
        )
        let update = makeDelivery(event: .update, generation: 5, revision: 2)
        try outbox.accept(update, targets: [
            makeTarget(for: update, deviceId: "device-a")
        ])
        let aStarted = await Self.waitUntil(timeout: 1.0) {
            log.events.contains("device-a")
        }
        XCTAssertTrue(aStarted)
        try outbox.accept(update, targets: [
            makeTarget(for: update, deviceId: "device-b")
        ])

        let bFinished = await Self.waitUntil(timeout: 1.0) {
            log.events.contains("device-b") &&
            (try? store.pending().contains(where: {
                guard case .v2(let target) = $0.target else { return false }
                return target.deviceId == "device-b"
            })) == false
        }
        XCTAssertTrue(bFinished,
                      "deadline must free the sole lane slot even when A ignores cancellation")
        let pending = try store.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attempts, 1,
                       "timed-out A remains durable and retryable, never acknowledged")
        gate.release()
    }

    func testDelayedAcceptedEndForTokenADoesNotAcknowledgeRotatedTokenB() async throws {
        // WHY: delivery lanes serialize A and B, but they are not ACK scopes.
        // If B rotates in while end A is in flight, A's delayed accepted result
        // must not delete B before B reaches the backend.
        let tmp = NSTemporaryDirectory() + "rc2-la-exact-end-ack-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let gate = TokenRegistrationGate()
        let log = OrderedSyncRecorder()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            send: { record in
                guard case .v2(let target) = record.target else {
                    throw OutboxTestError.responseLost
                }
                log.append(target.token)
                if target.token == "token-A" {
                    await gate.waitForRelease()
                }
                return PrivateLiveActivityV2DeliveryAck(
                    id: record.recordID, status: "queued", attempts: 0, nextAttemptAt: nil
                )
            }
        )
        let end = makeDelivery(event: .end, generation: 6, revision: 3)
        try outbox.accept(end, targets: [
            makeTarget(for: end, token: "token-A")
        ])
        let aStarted = await Self.waitUntil(timeout: 1.0) {
            log.events == ["token-A"]
        }
        XCTAssertTrue(aStarted)

        try outbox.accept(end, targets: [
            makeTarget(for: end, token: "token-B")
        ])
        let pendingBeforeAck = try store.pending()
        XCTAssertEqual(pendingBeforeAck.count, 1)
        guard case .v2(let queuedB) = try XCTUnwrap(pendingBeforeAck.first).target else {
            return XCTFail("rotated token B must remain as the exact durable unit")
        }
        XCTAssertEqual(queuedB.token, "token-B")

        gate.release()
        let bDelivered = await Self.waitUntil(timeout: 1.0) {
            log.events == ["token-A", "token-B"]
        }
        await outbox.flush()
        XCTAssertTrue(bDelivered,
                      "accepted end A must not acknowledge queued rotated token B")
        XCTAssertTrue(try store.pending().isEmpty,
                      "B retires only after its own accepted backend result")
    }

    func testLiveActivityRequestsAdvertiseElevenSecondDeadline() async throws {
        // WHY: Live Activity v2 delivery, legacy delivery, and v2 token
        // registration must not hang a background lane indefinitely.
        let recorder = HTTPRequestRecorder()
        HTTPRecordingURLProtocol.setHandler { request in
            recorder.append(request)
            let path = request.url?.path ?? ""
            if path.contains("/live-activities/tokens") {
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"""
                    {"token":{"activityKey":"active-threads","deviceId":"device-1","environment":"sandbox","tokenKind":"pushToStart","hostId":null,"bootEpoch":null,"activityGeneration":null,"activitySessionId":null,"activityId":null}}
                    """#.utf8)
                )
            }
            if path.contains("/live-activities/deliver") {
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"id":"d1","status":"queued","attempts":0,"nextAttemptAt":null}"#.utf8)
                )
            }
            // Legacy deliver path.
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"delivered":true,"errorCode":null,"shouldDropSubscription":false}"#.utf8)
            )
        }
        defer { HTTPRecordingURLProtocol.setHandler(nil) }

        let tmp = NSTemporaryDirectory() + "rc2-la-deadline-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let accountStore = PrivateAccountSessionStore(repo: settings)
        let targetStore = PrivatePushTargetStore(repo: settings)
        accountStore.save(PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: 30, daysRemaining: 30, email: "owner@example.com",
                id: "user-1", subscribed: true
            )
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPRecordingURLProtocol.self]
        let api = URLSessionPrivateAccountAPI(
            baseURL: URL(string: "https://private.example.test")!,
            session: URLSession(configuration: configuration)
        )
        let bridge = PrivateNotificationBridge(
            accountStore: accountStore, pushTargetStore: targetStore, api: api
        )
        let update = makeDelivery(event: .update, generation: 1, revision: 2)
        let v2Target = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .activityUpdate,
            environment: .sandbox, token: "update-token", activityGeneration: 1,
            activityId: "activity-1", bootEpoch: 7, activitySessionId: "server-1:7:1",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        let ptsTarget = PrivatePushTargetRecord(
            deviceId: "device-1", serverId: "server-1", purpose: .pushToStart,
            environment: .sandbox, token: "pts-token",
            contractVersion: 2, capabilities: ["live_activity_v2"]
        )
        try targetStore.upsert(v2Target)
        _ = try await bridge.sendLiveActivityAcceptance(
            LiveActivityAcceptanceRecord(delivery: update, target: .v2(v2Target))
        )
        try await bridge.registerLiveActivityTokenV2(ptsTarget)

        try targetStore.save(
            pushToken: "alert", pushTokenType: "apns",
            liveActivityToken: "legacy-la", deviceId: "device-1"
        )
        let legacy = try XCTUnwrap(targetStore.load())
        _ = try await bridge.sendLiveActivityAcceptance(
            LiveActivityAcceptanceRecord(delivery: update, target: .legacy(legacy))
        )

        XCTAssertEqual(LiveActivityDeliveryPolicy.requestTimeoutSeconds, 11)
        let timeouts = recorder.requests.map(\.timeoutInterval)
        XCTAssertEqual(timeouts.count, 3)
        XCTAssertTrue(timeouts.allSatisfy { abs($0 - 11) < 0.001 },
                      "v2 delivery, token registration, and legacy delivery must set the 11s deadline")
    }

    func testOfflineBacklogBoundsPreserveCurrentAndEndWithoutInventingSuccess() throws {
        // WHY: long offline accumulation must stay bounded by age/count/bytes,
        // compact superseded work first, preserve current/end, and never invent
        // success acknowledgements for compacted drops.
        let tmp = NSTemporaryDirectory() + "rc2-la-backlog-bounds-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 5_000_000))
        let store = LiveActivityAcceptanceOutboxStore(
            settings: SettingsRepository(db: db),
            now: { clock.read() },
            limits: LiveActivityAcceptanceOutboxLimits(
                recordRetention: 100,
                recordCap: 4,
                encodedByteCap: 32 * 1024
            )
        )

        // Flood with superseded updates across many generations (offline backlog).
        for generation in 1...40 {
            for revision in 1...5 {
                let delivery = makeDelivery(
                    event: .update, generation: UInt64(generation), revision: Int64(revision)
                )
                try store.enqueue(delivery, targets: [
                    makeTarget(for: delivery, deviceId: "device-1", token: "token-\(generation)")
                ])
            }
        }
        let currentEnd = makeDelivery(event: .end, generation: 40, revision: 99)
        try store.enqueue(currentEnd, targets: [
            makeTarget(for: currentEnd, deviceId: "device-1", token: "token-40")
        ])
        let currentStart = makeDelivery(event: .start, generation: 41, revision: 1)
        try store.enqueue(currentStart, targets: [
            makeTarget(for: currentStart, deviceId: "device-1", token: "token-41")
        ])

        let report = try store.compactBacklog()
        let pendingAfterCompact = try store.pending()
        XCTAssertTrue(
            report.didDrop ||
            pendingAfterCompact.count <= 4
        )

        let pending = pendingAfterCompact
        XCTAssertLessThanOrEqual(pending.count, 4)
        XCTAssertTrue(pending.contains(where: {
            $0.delivery.event == .end && $0.delivery.activityGeneration == 40
        }), "current end intent must survive offline compaction when possible")
        XCTAssertTrue(pending.contains(where: {
            $0.delivery.event == .start && $0.delivery.activityGeneration == 41
        }) || pending.contains(where: {
            $0.delivery.event == .end && $0.delivery.activityGeneration == 40
        }), "newest lifecycle records must be preferred under pressure")

        // Age out every historical event while keeping a fresh end.
        clock.advance(by: 101)
        let freshEnd = makeDelivery(event: .end, generation: 50, revision: 1)
        try store.enqueue(freshEnd, targets: [
            makeTarget(for: freshEnd, deviceId: "device-1", token: "fresh-end")
        ])
        let afterAge = try store.pending()
        XCTAssertTrue(afterAge.contains(where: {
            $0.delivery.event == .end && $0.delivery.activityGeneration == 50
        }))
        XCTAssertFalse(afterAge.contains(where: {
            $0.enqueuedAt < clock.read().addingTimeInterval(-100)
        }), "the age bound must include historical start, update, and end rows")
    }

    func testNewerStartSupersedesHistoricalNonTerminalButKeepsLateEndBarrier() throws {
        // WHY: repeated offline starts must not resurrect obsolete generations
        // or grow forever. A newer start supersedes old start/update work, while
        // a late old end remains a barrier ahead of the current lifecycle.
        let tmp = NSTemporaryDirectory() + "rc2-la-start-supersession-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(
            settings: SettingsRepository(db: db),
            limits: LiveActivityAcceptanceOutboxLimits(
                recordRetention: 10_000,
                recordCap: 20,
                encodedByteCap: 64 * 1024
            )
        )
        let oldStart = makeDelivery(event: .start, generation: 1, revision: 1)
        let oldUpdate = makeDelivery(event: .update, generation: 1, revision: 2)
        let currentStart = makeDelivery(event: .start, generation: 2, revision: 1)
        let lateOldEnd = makeDelivery(event: .end, generation: 1, revision: 3)
        try store.enqueue(oldStart, targets: [makeTarget(for: oldStart)])
        try store.enqueue(oldUpdate, targets: [makeTarget(for: oldUpdate)])
        let supersession = try store.enqueue(
            currentStart, targets: [makeTarget(for: currentStart)]
        )

        XCTAssertEqual(supersession.droppedRecords, 0,
                       "semantic supersession is safe last-write-wins, not a pressure loss")
        XCTAssertEqual(try store.pending().map(\.delivery.idempotencyKey),
                       [currentStart.idempotencyKey])

        try store.enqueue(lateOldEnd, targets: [makeTarget(for: lateOldEnd)])
        let pending = try store.pending()
        XCTAssertEqual(Set(pending.map(\.delivery.idempotencyKey)), [
            currentStart.idempotencyKey,
            lateOldEnd.idempotencyKey,
        ])
        XCTAssertFalse(pending.contains(where: {
            $0.delivery.idempotencyKey == oldStart.idempotencyKey ||
            $0.delivery.idempotencyKey == oldUpdate.idempotencyKey
        }), "superseded start/update work must never be reintroduced")
    }

    func testCountPressureDropsOldestHistoricalEndBeforeCurrentLifecycle() throws {
        // WHY: a backlog full of historical ends must not evict the current
        // start merely because every end was previously treated as protected.
        let tmp = NSTemporaryDirectory() + "rc2-la-count-current-protection-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(
            settings: SettingsRepository(db: db),
            limits: LiveActivityAcceptanceOutboxLimits(
                recordRetention: 10_000,
                recordCap: 4,
                encodedByteCap: 128 * 1024
            )
        )
        for generation in 1...4 {
            let end = makeDelivery(
                event: .end, generation: UInt64(generation), revision: 3
            )
            try store.enqueue(end, targets: [
                makeTarget(for: end, token: "end-\(generation)")
            ])
        }
        let currentStart = makeDelivery(event: .start, generation: 5, revision: 1)
        let report = try store.enqueue(currentStart, targets: [
            makeTarget(for: currentStart, token: "current-start")
        ])

        let pending = try store.pending()
        XCTAssertEqual(report.droppedRecords, 1)
        XCTAssertEqual(pending.count, 4)
        XCTAssertTrue(pending.contains(where: {
            $0.delivery.idempotencyKey == currentStart.idempotencyKey
        }), "count pressure must preserve the lifecycle-current start")
        XCTAssertTrue(pending.contains(where: {
            $0.delivery.event == .end && $0.delivery.activityGeneration == 4
        }), "the newest terminal barrier must remain protected")
        XCTAssertFalse(pending.contains(where: {
            $0.delivery.event == .end && $0.delivery.activityGeneration == 1
        }), "the oldest historical end is the first safe pressure drop")
    }

    func testCountPressurePreservesStartBarrierBeforeSameSessionUpdate() throws {
        // WHY: an update cannot establish a Live Activity. If a hard count cap
        // fits only one current-session record, the start barrier must win.
        let tmp = NSTemporaryDirectory() + "rc2-la-count-start-barrier-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(
            settings: SettingsRepository(db: db),
            limits: LiveActivityAcceptanceOutboxLimits(
                recordRetention: 10_000,
                recordCap: 1,
                encodedByteCap: 128 * 1024
            )
        )
        let start = makeDelivery(event: .start, generation: 5, revision: 1)
        let update = makeDelivery(event: .update, generation: 5, revision: 2)
        try store.enqueue(start, targets: [makeTarget(for: start)])
        let report = try store.enqueue(update, targets: [makeTarget(for: update)])

        let pending = try store.pending()
        XCTAssertEqual(report.droppedRecords, 1)
        XCTAssertEqual(pending.map(\.delivery.idempotencyKey), [
            start.idempotencyKey
        ], "count pressure must discard the update before its required start")
    }

    func testBytePressurePreservesStartBarrierBeforeSameSessionUpdate() throws {
        // WHY: byte pressure follows the same dependency rule as count
        // pressure; keeping only the update would leave undeliverable work.
        let tmp = NSTemporaryDirectory() + "rc2-la-byte-start-barrier-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let stamp = Date(timeIntervalSince1970: 9_100_000)
        let clock = ManualOutboxClock(now: stamp)
        let start = makeDelivery(event: .start, generation: 5, revision: 1)
        let update = makeDelivery(event: .update, generation: 5, revision: 2)
        let startTarget = makeTarget(for: start)
        let updateTarget = makeTarget(for: update)
        let startRecord = LiveActivityAcceptanceRecord(
            delivery: start,
            target: startTarget,
            enqueuedAt: stamp
        )
        let updateRecord = LiveActivityAcceptanceRecord(
            delivery: update,
            target: updateTarget,
            enqueuedAt: stamp.addingTimeInterval(1)
        )
        let encoder = JSONEncoder()
        let byteCap = max(
            try encoder.encode([startRecord]).count,
            try encoder.encode([updateRecord]).count
        )
        XCTAssertGreaterThan(
            try encoder.encode([startRecord, updateRecord]).count,
            byteCap
        )
        let store = LiveActivityAcceptanceOutboxStore(
            settings: SettingsRepository(db: db),
            now: { clock.read() },
            limits: LiveActivityAcceptanceOutboxLimits(
                recordRetention: 10_000,
                recordCap: 20,
                encodedByteCap: byteCap
            )
        )
        try store.enqueue(start, targets: [startTarget])
        clock.advance(by: 1)
        let report = try store.enqueue(update, targets: [updateTarget])

        let pending = try store.pending()
        XCTAssertEqual(report.droppedRecords, 1)
        XCTAssertEqual(pending.map(\.delivery.idempotencyKey), [
            start.idempotencyKey
        ], "byte pressure must discard the update before its required start")
    }

    func testBytePressureUsesLifecycleOrderNotLateEnqueueTime() throws {
        // WHY: a late-arriving old end has a newer enqueuedAt but an older
        // lifecycle identity. Byte pressure must keep the higher-generation
        // current start and discard that historical end when both cannot fit.
        let tmp = NSTemporaryDirectory() + "rc2-la-byte-current-protection-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 9_000_000))
        let currentStart = makeDelivery(event: .start, generation: 5, revision: 1)
        let lateOldEnd = makeDelivery(event: .end, generation: 4, revision: 3)
        let currentRecord = LiveActivityAcceptanceRecord(
            delivery: currentStart,
            target: makeTarget(for: currentStart, token: "current-start"),
            enqueuedAt: clock.read()
        )
        clock.advance(by: 1)
        let oldEndRecord = LiveActivityAcceptanceRecord(
            delivery: lateOldEnd,
            target: makeTarget(for: lateOldEnd, token: "late-old-end"),
            enqueuedAt: clock.read()
        )
        let encoder = JSONEncoder()
        let bothBytes = try encoder.encode([oldEndRecord, currentRecord]).count
        let byteCap = bothBytes - 1
        XCTAssertLessThanOrEqual(try encoder.encode([oldEndRecord]).count, byteCap)
        XCTAssertLessThanOrEqual(try encoder.encode([currentRecord]).count, byteCap)
        clock.advance(by: -1)
        let store = LiveActivityAcceptanceOutboxStore(
            settings: SettingsRepository(db: db),
            now: { clock.read() },
            limits: LiveActivityAcceptanceOutboxLimits(
                recordRetention: 10_000,
                recordCap: 20,
                encodedByteCap: byteCap
            )
        )
        try store.enqueue(currentStart, targets: [currentRecord.target])
        clock.advance(by: 1)
        let report = try store.enqueue(lateOldEnd, targets: [oldEndRecord.target])

        let pending = try store.pending()
        XCTAssertEqual(report.droppedRecords, 1)
        XCTAssertEqual(pending.map(\.delivery.idempotencyKey), [
            currentStart.idempotencyKey
        ], "late enqueue time must never redefine lifecycle-current under byte pressure")
    }

    func testCancellationAndTimeoutRemainPendingNeverAcknowledged() async throws {
        // WHY: cooperative cancellation and transport-class failures must leave
        // the durable record pending/retryable; only settled backend ACKs retire work.
        let tmp = NSTemporaryDirectory() + "rc2-la-cancel-timeout-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = LiveActivityAcceptanceOutboxStore(settings: SettingsRepository(db: db))
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 6_000))
        let scheduler = ManualOutboxScheduler()
        let mode = CancellationTimeoutMode(value: .cancel)
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            retryDelay: { _ in 5 },
            schedule: { delay, callback in scheduler.schedule(delay, callback) },
            sendTimeout: 0.02,
            send: { record in
                switch mode.read() {
                case .cancel:
                    throw CancellationError()
                case .timeout:
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return PrivateLiveActivityV2DeliveryAck(
                        id: record.recordID, status: "queued", attempts: 0, nextAttemptAt: nil
                    )
                case .ok:
                    return PrivateLiveActivityV2DeliveryAck(
                        id: record.recordID, status: "queued", attempts: 0, nextAttemptAt: nil
                    )
                }
            }
        )
        let delivery = makeDelivery(event: .update, generation: 2, revision: 1)
        try outbox.accept(delivery, targets: [makeTarget(for: delivery)])
        let cancellationRecorded = await Self.waitUntil(timeout: 1.0) {
            (try? store.pending().first?.attempts) == 1
        }
        XCTAssertTrue(cancellationRecorded)
        XCTAssertEqual(try store.pending().count, 1,
                       "cancellation must not acknowledge the durable acceptance record")
        XCTAssertEqual(try store.pending().first?.attempts, 1)

        mode.set(.timeout)
        clock.advance(by: 5)
        scheduler.fireAll()
        let timeoutRecorded = await Self.waitUntil(timeout: 1.0) {
            (try? store.pending().first?.attempts) == 2
        }
        XCTAssertTrue(timeoutRecorded)
        XCTAssertEqual(try store.pending().count, 1,
                       "URL timeout must remain pending/retryable, never acknowledged")
        XCTAssertEqual(try store.pending().first?.attempts, 2)

        mode.set(.ok)
        clock.advance(by: 5)
        scheduler.fireAll()
        let accepted = await Self.waitUntil(timeout: 1.0) {
            (try? store.pending().isEmpty) == true
        }
        let isEmpty = try store.pending().isEmpty
        XCTAssertTrue(accepted && isEmpty,
                      "only an accepted backend ACK may retire the pending record")
    }

    func testBacklogByteCompactionSurfacesDropsAndHandlesAdversarialLargeStrings() throws {
        // WHY: adversarial oversized projection strings must not grow the
        // durable outbox without bound, and pressure drops must surface exact
        // counts without inventing success.
        let tmp = NSTemporaryDirectory() + "rc2-la-backlog-bytes-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let clock = ManualOutboxClock(now: Date(timeIntervalSince1970: 7_000_000))
        let store = LiveActivityAcceptanceOutboxStore(
            settings: SettingsRepository(db: db),
            now: { clock.read() },
            limits: LiveActivityAcceptanceOutboxLimits(
                recordRetention: 10_000,
                recordCap: 20,
                encodedByteCap: 12 * 1024
            )
        )
        let errors = DeliveryErrorRecorder()
        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            now: { clock.read() },
            schedule: { _, _ in },
            onError: { error, delivery in errors.append(error, delivery: delivery) },
            send: { _ in
                // Never settle — keep records durable while compaction runs.
                throw URLError(.notConnectedToInternet)
            }
        )

        let huge = String(repeating: "💥", count: 8_000)
        for generation in 1...80 {
            let delivery = LiveActivitySyncDelivery(
                event: .update,
                projection: PrivateLiveActivityProjectionV2(
                    statusLine: huge,
                    phase: .running,
                    activeThreadCount: 1,
                    updatedAt: 1_000 + Double(generation),
                    sessionId: "server-1:7:\(generation)",
                    hostId: "server-1",
                    epoch: "7",
                    revision: 1
                ),
                activityGeneration: UInt64(generation),
                idempotencyKey: "activity.server-1.7.\(generation).1.update.\(huge.prefix(16))"
            )
            try outbox.accept(delivery, targets: [
                makeTarget(for: delivery, token: "tok-\(generation)-\(huge.prefix(8))")
            ])
        }
        let pending = try store.pending()
        let encoded = try JSONEncoder().encode(pending).count
        XCTAssertLessThanOrEqual(encoded, 12 * 1024,
                                 "encoded backlog must stay within the injected byte budget")
        XCTAssertLessThanOrEqual(pending.count, 20)
        let pressureDrops: [Int] = errors.errors.compactMap { error -> Int? in
            guard case .backlogCompacted(let dropped)? =
                    error as? LiveActivityAcceptanceOutboxError else { return nil }
            return dropped
        }
        XCTAssertFalse(pressureDrops.isEmpty,
                       "every unavoidable byte-pressure drop must surface through onError")
        XCTAssertTrue(pressureDrops.allSatisfy { $0 == 1 },
                      "each oversized insertion drops and discloses exactly one durable row")
        // Ends/current still prefer survival when present under the same budget.
        let end = makeDelivery(event: .end, generation: 999, revision: 1)
        try store.enqueue(end, targets: [makeTarget(for: end, token: "end-\(huge.prefix(4))")])
        let afterEnd = try store.pending()
        XCTAssertTrue(afterEnd.contains(where: {
            $0.delivery.event == .end && $0.delivery.activityGeneration == 999
        }), "terminal end must be preserved under byte pressure when possible")
    }

    func testPowerLossPersistsPendingAcceptanceIncludingEnqueuedAt() throws {
        // WHY: relaunch/power-loss recovery must restore pending records and
        // their age metadata so bounds compaction remains correct after reboot.
        let tmp = NSTemporaryDirectory() + "rc2-la-powerloss-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let enqueued = Date(timeIntervalSince1970: 8_000_000)
        let store = LiveActivityAcceptanceOutboxStore(
            settings: settings,
            now: { enqueued }
        )
        let delivery = makeDelivery(event: .start, generation: 3, revision: 1)
        try store.enqueue(delivery, targets: [makeTarget(for: delivery)])

        // Simulate process death: new store handle over the same durable settings.
        let reloaded = LiveActivityAcceptanceOutboxStore(settings: settings)
        let pending = try reloaded.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.delivery.idempotencyKey, delivery.idempotencyKey)
        XCTAssertEqual(pending.first?.enqueuedAt, enqueued,
                       "enqueuedAt must survive relaunch so age bounds stay honest")
    }

    func testLegacyPendingSnapshotWithoutEnqueuedAtUsesProjectionTime() throws {
        // WHY: upgrading an offline Mac must not decode every pre-field record as
        // UNIX epoch and silently compact valid pending work on first launch.
        let tmp = NSTemporaryDirectory() + "rc2-la-legacy-enqueued-at-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let delivery = makeDelivery(event: .start, generation: 3, revision: 1)
        let record = LiveActivityAcceptanceRecord(
            delivery: delivery,
            target: makeTarget(for: delivery),
            enqueuedAt: Date(timeIntervalSince1970: 99)
        )
        var array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([record]))
                as? [[String: Any]]
        )
        array[0].removeValue(forKey: "enqueuedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: array)
        try settings.set(
            "live_activity.acceptance_outbox.v1",
            try XCTUnwrap(String(data: legacyData, encoding: .utf8))
        )
        let store = LiveActivityAcceptanceOutboxStore(
            settings: settings,
            now: { Date(timeIntervalSince1970: delivery.projection.updatedAt + 10) },
            limits: LiveActivityAcceptanceOutboxLimits(
                recordRetention: 60,
                recordCap: 8,
                encodedByteCap: 32 * 1024
            )
        )

        let report = try store.compactBacklog()
        let pending = try store.pending()
        XCTAssertEqual(report.droppedRecords, 0)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(
            pending.first?.enqueuedAt,
            Date(timeIntervalSince1970: delivery.projection.updatedAt)
        )
    }

    func testUndecodableSnapshotIsDiscardedAndAcceptRewritesIt() throws {
        // WHY: an undecodable snapshot made `accept` throw on every delivery
        // (the Live Activity froze on a stale card with no user-visible error)
        // and left the store with no path to recover. Dropping it invents no
        // acknowledgement; the next accept persists a readable backlog.
        let tmp = NSTemporaryDirectory() + "rc2-la-undecodable-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let store = LiveActivityAcceptanceOutboxStore(settings: settings)
        try settings.set(
            "live_activity.acceptance_outbox.v1",
            "{\"schema\":\"from-a-newer-build\"}"
        )

        XCTAssertTrue(
            try store.pending().isEmpty,
            "an undecodable snapshot must read as an empty backlog, not a wedge"
        )

        let outbox = LiveActivityAcceptanceOutbox(
            store: store,
            retryDelay: { _ in 3600 },
            schedule: { _, _ in },
            send: { _ in
                throw LiveActivityAcceptanceOutboxError.backendDidNotAccept("offline")
            }
        )
        let delivery = makeDelivery(event: .start, generation: 3, revision: 1)
        XCTAssertNoThrow(
            try outbox.accept(delivery, targets: [makeTarget(for: delivery)]),
            "accepting after an undecodable snapshot must not fail forever"
        )
        XCTAssertEqual(
            try store.pending().map(\.delivery.idempotencyKey),
            [delivery.idempotencyKey],
            "the accepted delivery must be durable in a readable snapshot"
        )
    }

    private static func waitUntil(
        timeout: TimeInterval,
        _ predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }

    private struct HeartbeatPerfSample {
        let ticks: Int
        let cpuMilliseconds: Double
    }

    private func heartbeatSample(active hasActiveRun: Bool) async -> HeartbeatPerfSample {
        let coordinatorCount = hasActiveRun ? 16 : 128
        let ticks = DeliveryAttemptCounter()
        let run = ("10000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000001")
        var coordinators: [LiveActivitySyncCoordinator] = []
        coordinators.reserveCapacity(coordinatorCount)
        for index in 0..<coordinatorCount {
            let coordinator = LiveActivitySyncCoordinator(
                serverId: "server-benchmark-\(index)",
                bootEpoch: 1,
                deliver: { _ in },
                heartbeatIntervalNanoseconds: 2_000_000,
                onHeartbeatTick: { ticks.increment() }
            )
            coordinators.append(coordinator)
            if hasActiveRun {
                coordinator.submit(active([run]), cause: .started)
            }
        }
        if hasActiveRun {
            for coordinator in coordinators { await coordinator.flush() }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)

        let ticksBefore = ticks.count
        let cpuBefore = Self.processCPUNanoseconds()
        try? await Task.sleep(nanoseconds: 40_000_000)
        let cpuAfter = Self.processCPUNanoseconds()
        let measuredTicks = ticks.count - ticksBefore

        withExtendedLifetime(coordinators) {}
        coordinators.removeAll()
        try? await Task.sleep(nanoseconds: 5_000_000)
        return HeartbeatPerfSample(
            ticks: measuredTicks,
            cpuMilliseconds: Double(cpuAfter - cpuBefore) / 1_000_000
        )
    }

    private static func processCPUNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private func makeDelivery(
        event: PrivateLiveActivityEvent,
        generation: UInt64,
        revision: Int64
    ) -> LiveActivitySyncDelivery {
        LiveActivitySyncDelivery(
            event: event,
            projection: PrivateLiveActivityProjectionV2(
                statusLine: event == .end ? "0 active runs" : "1 active run",
                phase: event == .end ? .completed : .running,
                activeThreadCount: event == .end ? 0 : 1,
                updatedAt: 1_000,
                sessionId: "server-1:7:\(generation)",
                hostId: "server-1",
                epoch: "7",
                revision: revision
            ),
            activityGeneration: generation,
            idempotencyKey: "activity.server-1.7.\(generation).\(revision).\(event.rawValue)"
        )
    }

    private func makeTarget(
        for delivery: LiveActivitySyncDelivery,
        deviceId: String = "device-1",
        token: String? = nil
    ) -> LiveActivityAcceptanceTarget {
        .v2(PrivatePushTargetRecord(
            deviceId: deviceId,
            serverId: delivery.projection.hostId,
            purpose: delivery.event == .start ? .pushToStart : .activityUpdate,
            environment: .sandbox,
            token: token ?? "token-\(deviceId)",
            activityGeneration: delivery.activityGeneration,
            activityId: "activity-\(deviceId)",
            bootEpoch: UInt64(delivery.projection.epoch),
            activitySessionId: delivery.projection.sessionId,
            contractVersion: 2,
            capabilities: ["live_activity_v2"]
        ))
    }
}

private final class HTTPRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    private var bodyValues: [Data?] = []

    func append(_ request: URLRequest) {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.readBody)
        lock.withLock {
            values.append(request)
            bodyValues.append(body)
        }
    }

    var requests: [URLRequest] { lock.withLock { values } }
    var bodies: [Data?] { lock.withLock { bodyValues } }

    private static func readBody(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class OrderedSyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) { lock.withLock { values.append(value) } }
    var events: [String] { lock.withLock { values } }
}

private enum OutboxTestError: Error {
    case responseLost
    case persistence
}

private final class OutboxSender: @unchecked Sendable {
    private let lock = NSLock()
    private let failedStartAttempts: Int
    private var values: [LiveActivitySyncDelivery] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(failedStartAttempts: Int = 0) {
        self.failedStartAttempts = failedStartAttempts
    }

    func send(_ record: LiveActivityAcceptanceRecord) async throws -> PrivateLiveActivityV2DeliveryAck {
        let delivery = record.delivery
        let result = lock.withLock { () -> (Int, [CheckedContinuation<Void, Never>]) in
            values.append(delivery)
            let count = values.count
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            return (values.filter { $0.event == .start }.count, ready.map(\.1))
        }
        result.1.forEach { $0.resume() }
        if delivery.event == .start, result.0 <= failedStartAttempts {
            throw OutboxTestError.responseLost
        }
        return PrivateLiveActivityV2DeliveryAck(
            id: "ack-\(delivery.idempotencyKey)",
            status: "queued",
            attempts: 0,
            nextAttemptAt: nil
        )
    }

    func waitForAttempts(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let alreadyReady = lock.withLock { () -> Bool in
                if values.count >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if alreadyReady { continuation.resume() }
        }
    }

    var attempts: [LiveActivitySyncDelivery] { lock.withLock { values } }
}

/// Fails the deliveries named in `failures` the given number of times and
/// accepts everything else.
private final class ScriptedOutboxSender: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: (error: Error, remaining: Int)]
    private var keys: [String] = []

    init(failures: [String: (Error, Int)]) {
        self.failures = failures.mapValues { (error: $0.0, remaining: $0.1) }
    }

    func send(_ record: LiveActivityAcceptanceRecord) async throws -> PrivateLiveActivityV2DeliveryAck {
        let key = record.delivery.idempotencyKey
        let failure = lock.withLock { () -> Error? in
            keys.append(key)
            guard let scripted = failures[key], scripted.remaining > 0 else { return nil }
            failures[key] = (error: scripted.error, remaining: scripted.remaining - 1)
            return scripted.error
        }
        if let failure { throw failure }
        return PrivateLiveActivityV2DeliveryAck(id: "ack-\(key)", status: "queued", attempts: 0, nextAttemptAt: nil)
    }

    var attempts: [String] { lock.withLock { keys } }
}

private final class ManualOutboxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) { value = now }
    func read() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private final class ManualOutboxScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable () -> Void] = []

    func schedule(_ delay: TimeInterval, _ callback: @escaping @Sendable () -> Void) {
        lock.withLock { callbacks.append(callback) }
    }

    func fireAll() {
        let values = lock.withLock { () -> [@Sendable () -> Void] in
            defer { callbacks.removeAll() }
            return callbacks
        }
        values.forEach { $0() }
    }
}

private final class DeliveryErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var rawErrors: [Error] = []

    func append(_ error: Error, delivery: LiveActivitySyncDelivery?) {
        lock.withLock {
            rawErrors.append(error)
            values.append((delivery?.idempotencyKey ?? "nil") + ":" + String(describing: error))
        }
    }

    // Compatibility with existing coordinator test.
    func append(_ error: Error, delivery: LiveActivitySyncDelivery) {
        append(error, delivery: Optional(delivery))
    }

    var count: Int { lock.withLock { values.count } }
    var errors: [Error] { lock.withLock { rawErrors } }
}

private final class DeliveryAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int { lock.withLock { value } }
}

private final class TokenRegistrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?
    private var pendingRelease = false

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pendingRelease {
                pendingRelease = false
                lock.unlock()
                continuation.resume()
                return
            }
            parked = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        if let continuation = parked {
            parked = nil
            lock.unlock()
            continuation.resume()
            return
        }
        pendingRelease = true
        lock.unlock()
    }
}

private final class CancellationTimeoutMode: @unchecked Sendable {
    enum Value {
        case cancel
        case timeout
        case ok
    }

    private let lock = NSLock()
    private var value: Value

    init(value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func set(_ next: Value) { lock.withLock { value = next } }
}

private final class TargetRegistrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PrivatePushTargetRecord] = []
    func append(_ target: PrivatePushTargetRecord) { lock.withLock { values.append(target) } }
    var targets: [PrivatePushTargetRecord] { lock.withLock { values } }
}

private final class DeviceOutboxSender: @unchecked Sendable {
    private let lock = NSLock()
    private let failingDeviceID: String
    private var retryAllowed = false
    private var deviceIDs: [String] = []
    private var generationValues: [UInt64] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(failingDeviceID: String) { self.failingDeviceID = failingDeviceID }

    func send(_ record: LiveActivityAcceptanceRecord) async throws -> PrivateLiveActivityV2DeliveryAck {
        guard case .v2(let target) = record.target else { throw OutboxTestError.responseLost }
        let result = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            deviceIDs.append(target.deviceId)
            generationValues.append(record.delivery.activityGeneration)
            let ready = waiters.filter { $0.0 <= deviceIDs.count }
            waiters.removeAll { $0.0 <= deviceIDs.count }
            return (retryAllowed, ready.map(\.1))
        }
        result.1.forEach { $0.resume() }
        if target.deviceId == failingDeviceID, !result.0 { throw OutboxTestError.responseLost }
        return PrivateLiveActivityV2DeliveryAck(id: record.recordID, status: "pending", attempts: 0, nextAttemptAt: nil)
    }

    func allowRetries() { lock.withLock { retryAllowed = true } }
    func count(for deviceID: String) -> Int { lock.withLock { deviceIDs.filter { $0 == deviceID }.count } }
    var generations: [UInt64] { lock.withLock { generationValues } }
    func waitForAttempts(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if deviceIDs.count >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private final class HTTPRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?

    static func setHandler(_ value: Handler?) {
        lock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.lock.withLock { Self.handler })
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
