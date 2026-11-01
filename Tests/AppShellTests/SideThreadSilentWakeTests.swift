import XCTest
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

/// A side chat (`/side`) is hidden from the phone's thread list, so its finish
/// is no news for the phone. It must not cost the phone a silent wake either:
/// the hourly budget (F5, table B1) admits a progress or `other` wake only
/// while nothing was delivered in the last hour, so one finished side turn
/// took the slot the main run's own finish needed.
@MainActor
final class SideThreadSilentWakeTests: XCTestCase {
    private static let budgetKey = "private.silentWake.budget.v1"

    func testSideChatFinishTakesNoBudgetSlotFromTheMainRun() async throws {
        // WHY: under an active Live Activity card a finish reaches the phone as
        // one forced `other` wake, the class with a single slot per hour. The
        // usual `/side` case is a side turn that ends while the main run still
        // works: its wake left the main run's finish with no banner (the card
        // hides it) and no catch-up (the budget dropped it).
        let api = SilentWakeRecordingAPI()
        let ctx = try makeContext(api: api)
        try pairPhone(with: ctx, api: api, liveActivityActive: true)
        let (main, side) = try makeMainAndSideThread(in: ctx)
        let sideRun = try makeFinishedRun(of: side, in: ctx)
        let mainRun = try makeFinishedRun(of: main, in: ctx)

        ctx.coordinator.onRunFinished?(side.id, sideRun.id, .completed)
        await wait(seconds: 1) { !api.requests.isEmpty }
        XCTAssertEqual(api.requests, [], "a side chat's finish sends the phone nothing")
        XCTAssertNil(try ctx.settingsRepo.get(Self.budgetKey), "and takes no slot of the hour")

        ctx.coordinator.onRunFinished?(main.id, mainRun.id, .completed)
        await wait(seconds: 30) { api.requests.contains { !$0.silent } }
        let requests = api.requests
        XCTAssertEqual(requests.filter { !$0.silent }.count, 1, "the main run's finish is told to the phone once")
        XCTAssertTrue(
            requests.allSatisfy { $0.silent || !$0.idempotencyKey.localizedCaseInsensitiveContains(sideRun.id.value.uuidString) },
            "the alert that was sent is the main thread's, not the side chat's"
        )
    }

    func testClosingASideChatMidTurnSendsThePhoneNothing() async throws {
        // WHY: closing a side chat stops its run and deletes its row in one call,
        // so the finish is handled after the row is gone. Read then, the thread
        // looks like any other and the phone gets "Thread cancelled" for a thread
        // it cannot open: whether a thread is a side chat is read before the hop.
        let api = SilentWakeRecordingAPI()
        let ctx = try makeContext(api: api)
        try pairPhone(with: ctx, api: api, liveActivityActive: false)
        let (main, side) = try makeMainAndSideThread(in: ctx)
        let sideRun = try makeFinishedRun(of: side, in: ctx)
        let mainRun = try makeFinishedRun(of: main, in: ctx)

        ctx.coordinator.onRunFinished?(side.id, sideRun.id, .cancelled)
        try ctx.threadRepo.delete(id: side.id)
        await wait(seconds: 1) { !api.requests.isEmpty }
        XCTAssertEqual(api.requests, [], "a closed side chat's cancelled turn sends the phone nothing")

        ctx.coordinator.onRunFinished?(main.id, mainRun.id, .completed)
        await wait(seconds: 30) { api.requests.contains { $0.data["threadId"] == main.id.value.uuidString } }
        let banners = api.requests.filter { !$0.silent }
        XCTAssertEqual(banners.map(\.title), ["Thread finished"], "the main run's finish still shows its banner")
        XCTAssertEqual(banners.first?.data["threadId"], main.id.value.uuidString)
    }

    func testABotPausedForTheUserSendsThePhoneNoThreadCancelledAlert() async throws {
        // WHY: when a bot asks the user to step in, the host stops its run so it stops acting.
        // The phone already got "Waiting for you"; a "Thread cancelled" alert for the same
        // pause reads as a failure. A real Stop with no open request still sends it.
        let api = SilentWakeRecordingAPI()
        let ctx = try makeContext(api: api)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        try pairPhone(with: ctx, api: api, liveActivityActive: false)
        let (main, _) = try makeMainAndSideThread(in: ctx)
        let pausedRun = try makeFinishedRun(of: main, in: ctx)
        let request = ManualActionRequest(botID: BotID(), threadID: main.id, kind: .login, reason: "Sign in")
        try router.manualActionStore.upsert(request)

        ctx.coordinator.onRunFinished?(main.id, pausedRun.id, .cancelled)
        let cancelledAlert = { api.requests.contains { !$0.silent && $0.title == "Thread cancelled" } }
        await wait(seconds: 10, until: cancelledAlert)
        XCTAssertFalse(cancelledAlert(), "the handoff pause is not a cancelled thread")

        try router.manualActionStore.resolve(id: request.id, state: .declined)
        let stoppedRun = try makeFinishedRun(of: main, in: ctx)
        ctx.coordinator.onRunFinished?(main.id, stoppedRun.id, .cancelled)
        await wait(seconds: 30, until: cancelledAlert)
        XCTAssertTrue(cancelledAlert(), "a Stop with no open request still tells the phone")
    }

    func testSideChatFinishEventQueuesNoWakeAndTheNextRealFinishDoes() async throws {
        // WHY: every finished run is published as `agent.run.completed`, and the
        // wake coordinator turns that kind into a progress wake without knowing
        // the thread. The side chat's event must still be published (the Mac
        // shows it) but must queue no wake, and it must not silence the run
        // that finishes after it.
        let ctx = try makeContext(api: SilentWakeRecordingAPI())
        let coordinator = MaterialWakeCoordinator.shared
        defer { coordinator.stop() }
        let wakes = WakeLog()
        coordinator.setTestDelivererForTests { hint, _, payload, _ in
            wakes.append(hint: hint, sinceSeq: payload.sinceSeq.flatMap { Int64($0) })
        }
        coordinator.startForTests()
        let completed = CompletedRunSeqs()
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { completed.record($0) }
        defer { EventBus.shared.unsubscribe(token) }
        let (main, side) = try makeMainAndSideThread(in: ctx)
        let sideRun = try makeFinishedRun(of: side, in: ctx)
        let mainRun = try makeFinishedRun(of: main, in: ctx)

        ctx.coordinator.onRunFinished?(side.id, sideRun.id, .completed)
        await wait(seconds: 30) { completed.seq(of: sideRun.id) != nil }
        let sideSeq = try XCTUnwrap(completed.seq(of: sideRun.id), "the side chat's finish is still published")
        // The queue is first in, first out: once this later wake of another class
        // is delivered, a wake queued by the side chat's finish was delivered too.
        EventBus.shared.publish(
            kind: .hostBootEpoch,
            payload: .object(["boot_epoch": .number(1), "server_id": .string("server-1")])
        )
        await wait(seconds: 30) { wakes.contains(hint: "host.boot_epoch") }
        XCTAssertTrue(wakes.contains(hint: "host.boot_epoch"))
        XCTAssertFalse(
            wakes.contains(hint: "agent.run.completed", seq: sideSeq),
            "a side chat's finish queues no wake for the phone"
        )

        ctx.coordinator.onRunFinished?(main.id, mainRun.id, .completed)
        await wait(seconds: 30) { completed.seq(of: mainRun.id) != nil }
        let mainSeq = try XCTUnwrap(completed.seq(of: mainRun.id))
        await wait(seconds: 30) { wakes.contains(hint: "agent.run.completed", fromSeq: mainSeq) }
        XCTAssertTrue(
            wakes.contains(hint: "agent.run.completed", fromSeq: mainSeq),
            "the next real finish still wakes the phone"
        )
    }

    // MARK: - Fixture

    /// AppContext starts the wake coordinator on its bridge and publishes
    /// `host.boot_epoch`. With phase A off that event queues no wake, so the
    /// only sends a test sees are the ones its own finishes cause.
    private func makeContext(api: SilentWakeRecordingAPI) throws -> AppContext {
        let defaults = UserDefaults.standard
        let phaseABefore = defaults.object(forKey: ConnectionFeatureFlags.wakePhaseAKey)
        ConnectionFeatureFlags.wakePhaseAEnabled = false
        defer {
            MaterialWakeCoordinator.shared.stop()
            defaults.set(phaseABefore, forKey: ConnectionFeatureFlags.wakePhaseAKey)
            XCTAssertTrue(ConnectionFeatureFlags.wakePhaseAEnabled, "these tests need the shipped default")
        }
        let tmp = NSTemporaryDirectory() + "rc2-side-thread-wake-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp, privateAccountAPI: api)
    }

    /// A signed-in subscribed account and one push target, as a paired phone
    /// leaves them; with `liveActivityActive`, a fresh card of that phone.
    private func pairPhone(with ctx: AppContext, api: SilentWakeRecordingAPI, liveActivityActive: Bool) throws {
        let targets = PrivatePushTargetStore(repo: ctx.settingsRepo)
        try targets.save(pushToken: "apns-token", pushTokenType: "apns", liveActivityToken: nil, deviceId: "device-1")
        if liveActivityActive {
            try targets.upsert(PrivatePushTargetRecord(
                deviceId: "device-1",
                serverId: "server-1",
                purpose: .activityUpdate,
                environment: .sandbox,
                token: "activity-update-token"
            ))
        }
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(api.session)
    }

    private func makeMainAndSideThread(in ctx: AppContext) throws -> (main: AgentThread, side: AgentThread) {
        let main = AgentThread(title: "Main", provider: .codex, model: "fake-model")
        let side = AgentThread(
            title: "Side · Main",
            provider: .codex,
            model: "fake-model",
            parentThreadId: main.id,
            isEphemeral: true
        )
        try ctx.threadRepo.upsert(main)
        try ctx.threadRepo.upsert(side)
        return (main, side)
    }

    private func makeFinishedRun(of thread: AgentThread, in ctx: AppContext) throws -> AgentRun {
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .completed,
            finishedAt: Date()
        )
        try ctx.runRepo.upsert(run)
        return run
    }

    /// Returns as soon as `condition` holds, or after `seconds`.
    private func wait(seconds: TimeInterval, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Wakes the coordinator handed to the test deliverer.
private final class WakeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var wakes: [(hint: String, sinceSeq: Int64?)] = []

    func append(hint: String, sinceSeq: Int64?) {
        lock.withLock { wakes.append((hint, sinceSeq)) }
    }

    func contains(hint: String) -> Bool {
        lock.withLock { wakes.contains { $0.hint == hint } }
    }

    /// A wake of this kind built from exactly this event.
    func contains(hint: String, seq: Int64) -> Bool {
        lock.withLock { wakes.contains { $0.hint == hint && $0.sinceSeq == seq } }
    }

    /// A wake of this kind built from this event or a later one: a newer event
    /// of the same class replaces a wake that is still queued.
    func contains(hint: String, fromSeq: Int64) -> Bool {
        lock.withLock { wakes.contains { $0.hint == hint && ($0.sinceSeq ?? -1) >= fromSeq } }
    }
}

/// The EventBus sequence of each `agent.run.completed`, by run id.
private final class CompletedRunSeqs: @unchecked Sendable {
    private let lock = NSLock()
    private var seqs: [String: Int64] = [:]

    func record(_ event: EventBus.Event) {
        guard event.kind == "agent.run.completed",
              let runId = event.payload.objectValue?["run_id"]?.stringValue else { return }
        lock.withLock { seqs[runId] = event.seq }
    }

    func seq(of runId: AgentRunID) -> Int64? {
        lock.withLock { seqs[runId.value.uuidString.lowercased()] }
    }
}
