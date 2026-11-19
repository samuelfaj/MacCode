import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

/// 2026-11-19 samples of the running MacCode: while an agent streamed, the
/// serial Agent App read queue spent most of its busy time in
/// `ActivityService.list` (with `BotStore.listConversations` inside). Every
/// item start/completion re-synced the active runs and republished the Live
/// Activity surface, and that surface reads the full Activity page even though
/// the active set had not changed and `PetLiveActivityCopy.makeActivity(page:)`
/// never uses the progress preview. Each such read delayed the other Agent App
/// reads queued behind it. Item progress must only refresh the cached rows.
@MainActor
final class PetLiveActivityProgressReadTests: XCTestCase {
    func test_progressPreviewsDoNotReadTheActivityPage() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetLAProgressRead-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "progress", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "streaming thread",
            provider: .claude,
            model: "opus",
            status: .running,
            hasUnread: false
        )
        try context.threadRepo.upsert(thread)
        let runID = AgentRunID()
        try context.runRepo.upsert(AgentRun(
            id: runID,
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date().addingTimeInterval(-30)
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        context.coordinator.bindActiveThreadForTesting(threadId: thread.id, runId: runID)
        context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: [.init(threadId: thread.id, runId: runID)]),
            .started
        )
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNotNil(controller.modelForTests.activeThreads.first, "precondition: the run is projected as active")

        let readsBefore = AgentAppReadGateway.readCallCountForTesting
        let skippedBefore = AgentAppReadGateway.readSkippedCancelledCountForTesting
        for step in 0..<5 {
            let item: JSONValue = .object([
                "id": .string("item-\(step)"),
                "type": .string("commandExecution"),
                "summary": .string("step \(step)"),
                "body": .string("echo \(step)")
            ])
            EventBus.shared.publish(kind: .agentItemStarted, payload: .object([
                "thread_id": .string(thread.id.value.uuidString),
                "item": item
            ]))
            try await Task.sleep(nanoseconds: 30_000_000)
            EventBus.shared.publish(kind: .agentItemCompleted, payload: .object([
                "thread_id": .string(thread.id.value.uuidString),
                "item": item
            ]))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(controller.progressRepublishUsedCachedChromeForTesting, "precondition: the progress path ran")
        XCTAssertEqual(
            controller.modelForTests.activeThreads.first?.lastUpdatePreview,
            "Running: step 4",
            "progress must still refresh the active row preview"
        )
        let pageReads = (AgentAppReadGateway.readCallCountForTesting - readsBefore)
            + (AgentAppReadGateway.readSkippedCancelledCountForTesting - skippedBefore)
        XCTAssertEqual(pageReads, 0, "item progress on an unchanged active set must not queue an Activity page read")
        XCTAssertEqual(controller.modelForTests.activeThreads.map(\.threadID), [thread.id], "the run stays projected")
    }

    /// Viewing a finished run lowers the "new results" count the Live Activity
    /// shows while another run keeps streaming. That refresh must come from the
    /// view event itself, not from item progress happening to re-read the page.
    func test_viewingAFinishedRunStillRefreshesTheSurfaceWhileARunStreams() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetLAViewedRead-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "viewed", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "streaming thread",
            provider: .claude,
            model: "opus",
            status: .running,
            hasUnread: false
        )
        try context.threadRepo.upsert(thread)
        let runID = AgentRunID()
        try context.runRepo.upsert(AgentRun(
            id: runID,
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date().addingTimeInterval(-30)
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }
        context.coordinator.bindActiveThreadForTesting(threadId: thread.id, runId: runID)
        context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: [.init(threadId: thread.id, runId: runID)]),
            .started
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        let readsBefore = AgentAppReadGateway.readCallCountForTesting
        let skippedBefore = AgentAppReadGateway.readSkippedCancelledCountForTesting
        // Same event AppCommandRouter publishes after markFinishedRunsViewed / activity.set_viewed.
        EventBus.shared.publish(kind: .notificationRead, payload: .object([
            "id": .string("activity:run:\(UUID().uuidString.lowercased())"),
            "activity_item_ids": .array([.string("run:\(UUID().uuidString.lowercased())")]),
            "reason": .string("viewed")
        ]))
        try await Task.sleep(nanoseconds: 200_000_000)

        let pageReads = (AgentAppReadGateway.readCallCountForTesting - readsBefore)
            + (AgentAppReadGateway.readSkippedCancelledCountForTesting - skippedBefore)
        XCTAssertGreaterThanOrEqual(pageReads, 1, "a viewed run must re-read the page so the new-results count drops")
    }
}
