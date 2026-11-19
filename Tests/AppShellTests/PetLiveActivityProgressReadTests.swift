import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

/// 2026-11-19 05:00Z samples of the running MacCode: while an agent streamed,
/// the serial SQLite read queue spent 60–98% of its time in
/// `ActivityService.list` (with `BotStore.listConversations` inside). Every
/// material progress preview (each item start/delta) republished the Live
/// Activity surface, and that surface reads the full Activity page, although
/// `PetLiveActivityCopy.makeActivity(page:)` never uses the preview. Progress
/// must refresh the cached active rows only; every read it queued delayed the
/// other Agent App reads behind it.
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

        context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: [.init(threadId: thread.id, runId: runID)]),
            .started
        )
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNotNil(controller.modelForTests.activeThreads.first, "precondition: the run is projected as active")

        let readsBefore = AgentAppReadGateway.readCallCountForTesting
        let skippedBefore = AgentAppReadGateway.readSkippedCancelledCountForTesting
        for step in 0..<5 {
            EventBus.shared.publish(kind: .agentItemStarted, payload: .object([
                "thread_id": .string(thread.id.value.uuidString),
                "item": .object([
                    "id": .string("item-\(step)"),
                    "type": .string("commandExecution"),
                    "summary": .string("step \(step)"),
                    "body": .string("echo \(step)")
                ])
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
        XCTAssertEqual(pageReads, 0, "a progress preview must not queue an Activity page read")
    }
}
