import XCTest
@testable import AppShell
import CoreModel
import Persistence
import SocketServer

/// 2026-11-24/25 hang reports of the running MacCode (pid 26889, 5 agents
/// streaming): 4 of the 10 kept main-thread stacks were inside
/// `PetController.refreshAttentionNow` → `PetAttentionStore.refresh`. In the
/// 00:02:27Z capture the main thread spent the whole 2.25 s waiting for the
/// read connection's lock (`AgentThreadRepository.list`) while the Agent App
/// read queue held it for an `ActivityService.list`; the others read every Bot
/// conversation on the main thread. That refresh runs for every attention
/// event (Bot attention, notifications, run start/finish), so those reads must
/// not run on the main thread, and the new rows must still show once they end.
@MainActor
final class PetAttentionOffMainRefreshTests: XCTestCase {
    private func makeStartedController(_ name: String) throws -> (PetController, AppContext) {
        let directory = NSTemporaryDirectory() + "RC2PetAttentionOffMain\(name)-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        return (controller, context)
    }

    private func insertNotification(_ id: String, context: AppContext) throws {
        try NotificationRepository(db: context.db).insert(AppNotification(
            id: id,
            title: "safe test notification",
            category: PetNotificationCategory.providerUpdateFailed.rawValue
        ))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Longest time the main actor did not get to run during `duration`.
    private func longestMainActorGap(over duration: TimeInterval) async throws -> TimeInterval {
        var longest: TimeInterval = 0
        var last = Date()
        let end = last.addingTimeInterval(duration)
        while Date() < end {
            try await Task.sleep(nanoseconds: 5_000_000)
            let now = Date()
            longest = max(longest, now.timeIntervalSince(last))
            last = now
        }
        return longest
    }

    func test_anAttentionEventWhileTheReadConnectionIsBusyLeavesTheMainThreadFree() async throws {
        let (controller, context) = try makeStartedController("Busy")
        defer { controller.stop() }
        XCTAssertEqual(controller.modelForTests.count, 0)
        try insertNotification("busy-read", context: context)

        // Another reader (the Agent App read queue in the reports) holds the
        // read connection for up to 1.5 s.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let readDB = context.readDB
        DispatchQueue.global(qos: .userInitiated).async {
            readDB.performSync { _ in
                held.signal()
                _ = release.wait(timeout: .now() + 1.5)
            }
        }
        held.wait()
        EventBus.shared.publish(kind: .notificationCreated, payload: .object([:]))

        let gap = try await longestMainActorGap(over: 0.4)
        XCTAssertLessThan(gap, 0.3, "the main thread waited \(Int(gap * 1000)) ms for the attention read")
        XCTAssertEqual(controller.modelForTests.count, 0, "the read is still waiting for the connection")

        release.signal()
        try await waitUntil("the new ready item shows") { controller.modelForTests.count == 1 }
        XCTAssertEqual(controller.modelForTests.items.map(\.id), ["notification:busy-read"])
        XCTAssertNil(controller.modelForTests.routeError)
    }

    func test_eventsDuringAReadRerunItOnceAndTheLastChangeShows() async throws {
        let (controller, context) = try makeStartedController("Burst")
        defer { controller.stop() }
        var reads = 0
        var gate: CheckedContinuation<Void, Never>?
        controller.beforeAttentionReadApplyForTests = {
            reads += 1
            guard reads == 1 else { return }
            await withCheckedContinuation { gate = $0 }
        }

        try insertNotification("burst-1", context: context)
        EventBus.shared.publish(kind: .notificationCreated, payload: .object([:]))
        try await waitUntil("the first read is waiting to apply") { gate != nil }
        for id in ["burst-2", "burst-3"] {
            try insertNotification(id, context: context)
            EventBus.shared.publish(kind: .notificationCreated, payload: .object([:]))
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertEqual(reads, 1, "events during a read must not start a second one")

        gate?.resume()
        try await waitUntil("every ready item shows") { controller.modelForTests.count == 3 }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(reads, 2, "the events that landed during the read rerun it exactly once")
        XCTAssertEqual(controller.modelForTests.count, 3)
    }

    func test_aLateEventReadNeverOverwritesANewerSynchronousRefresh() async throws {
        let (controller, context) = try makeStartedController("Stale")
        defer { controller.stop() }
        var gate: CheckedContinuation<Void, Never>?
        controller.beforeAttentionReadApplyForTests = {
            await withCheckedContinuation { gate = $0 }
        }

        try insertNotification("stale-1", context: context)
        EventBus.shared.publish(kind: .notificationCreated, payload: .object([:]))
        try await waitUntil("the event read holds one row and waits to apply") { gate != nil }

        try insertNotification("stale-2", context: context)
        NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        try await waitUntil("the settings refresh shows both rows") { controller.modelForTests.count == 2 }

        gate?.resume()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.modelForTests.count, 2, "the older one-row read must be dropped")
    }

    func test_stopDropsAnEventReadStillInFlight() async throws {
        let (controller, context) = try makeStartedController("Stop")
        var gate: CheckedContinuation<Void, Never>?
        controller.beforeAttentionReadApplyForTests = {
            await withCheckedContinuation { gate = $0 }
        }

        try insertNotification("stopped", context: context)
        EventBus.shared.publish(kind: .notificationCreated, payload: .object([:]))
        try await waitUntil("the event read waits to apply") { gate != nil }
        controller.stop()
        XCTAssertFalse(controller.hasScheduledTasksForTests)

        gate?.resume()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.modelForTests.count, 0, "a stopped pet must not apply a late read")
    }

    func test_aFailedEventReadShowsTheLoadError() async throws {
        let (controller, context) = try makeStartedController("Failure")
        defer { controller.stop() }
        XCTAssertNil(controller.modelForTests.routeError)

        try context.db.execute("DROP TABLE notifications;")
        EventBus.shared.publish(kind: .notificationCreated, payload: .object([:]))

        try await waitUntil("the load error shows") {
            controller.modelForTests.routeError == L("Ready items could not be loaded.")
        }
    }
}
