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
    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let workspace: Workspace
        let controller: PetController
        let thread: AgentThread
        let runID: AgentRunID
    }

    private func makeStreamingFixture(_ name: String) async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "RC2PetLA\(name)-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: name, cwd: NSTemporaryDirectory())
        let (thread, runID) = try makeRunningThread(context: context, workspace: workspace, title: "streaming thread")
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        context.coordinator.bindActiveThreadForTesting(threadId: thread.id, runId: runID)
        context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: [.init(threadId: thread.id, runId: runID)]),
            .started
        )
        try await waitUntil("the run is projected as active and its bot link resolved") {
            controller.modelForTests.activeThreads.map(\.threadID) == [thread.id]
                && controller.linkedBotDurableLookupCountForTesting >= 1
        }
        try await waitForSurfacePublishesToSettle(controller)
        return Fixture(context: context, router: router, workspace: workspace, controller: controller, thread: thread, runID: runID)
    }

    private func makeRunningThread(context: AppContext, workspace: Workspace, title: String) throws -> (AgentThread, AgentRunID) {
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: title,
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
        return (thread, runID)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Setup work (start's attention refresh, the projection) may still publish;
    /// wait until no publish happens for 150 ms so a late one is not counted.
    private func waitForSurfacePublishesToSettle(_ controller: PetController) async throws {
        var last = controller.liveActivitySurfacePublishCountForTesting
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(3)
        while Date().timeIntervalSince(stableSince) < 0.15, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            let now = controller.liveActivitySurfacePublishCountForTesting
            if now != last { last = now; stableSince = Date() }
        }
    }

    /// Creating threads and Bot conversations publishes events that can
    /// re-apply the rows on their own; let them pass so only the step under
    /// test can apply.
    private func waitForPetEventsToSettle(_ controller: PetController) async throws {
        var last = controller.handledEventCountForTests
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(3)
        while Date().timeIntervalSince(stableSince) < 0.15, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            let now = controller.handledEventCountForTests
            if now != last { last = now; stableSince = Date() }
        }
    }

    func test_progressPreviewsDoNotReadTheActivityPage() async throws {
        let fixture = try await makeStreamingFixture("progress")
        let controller = fixture.controller
        defer { controller.stop() }

        let publishesBefore = controller.liveActivitySurfacePublishCountForTesting
        for step in 0..<5 {
            let item: JSONValue = .object([
                "id": .string("item-\(step)"),
                "type": .string("commandExecution"),
                "summary": .string("step \(step)"),
                "body": .string("echo \(step)")
            ])
            EventBus.shared.publish(kind: .agentItemStarted, payload: .object([
                "thread_id": .string(fixture.thread.id.value.uuidString),
                "item": item
            ]))
            try await Task.sleep(nanoseconds: 30_000_000)
            EventBus.shared.publish(kind: .agentItemCompleted, payload: .object([
                "thread_id": .string(fixture.thread.id.value.uuidString),
                "item_id": .string("item-\(step)"),
                "item": item
            ]))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await waitUntil("the last item reaches the active row") {
            controller.modelForTests.activeThreads.first?.lastUpdatePreview == "Running: step 4"
        }
        try await waitForSurfacePublishesToSettle(controller)

        XCTAssertTrue(controller.progressRepublishUsedCachedChromeForTesting, "precondition: the progress path ran")
        XCTAssertEqual(
            controller.liveActivitySurfacePublishCountForTesting - publishesBefore, 0,
            "item progress on an unchanged active set must not queue an Activity page read"
        )
        XCTAssertEqual(controller.modelForTests.activeThreads.map(\.threadID), [fixture.thread.id], "the run stays projected")
    }

    /// Viewing a finished run lowers the "new results" count the Live Activity
    /// shows while another run keeps streaming. That refresh must come from the
    /// view event itself, not from item progress happening to re-read the page.
    func test_viewingAFinishedRunStillRefreshesTheSurfaceWhileARunStreams() async throws {
        let fixture = try await makeStreamingFixture("viewed")
        let controller = fixture.controller
        defer { controller.stop() }

        let publishesBefore = controller.liveActivitySurfacePublishCountForTesting
        // Same event AppCommandRouter publishes after markFinishedRunsViewed / activity.set_viewed.
        EventBus.shared.publish(kind: .notificationRead, payload: .object([
            "id": .string("activity:run:\(UUID().uuidString.lowercased())"),
            "activity_item_ids": .array([.string("run:\(UUID().uuidString.lowercased())")]),
            "reason": .string("viewed")
        ]))
        try await waitUntil("a viewed run republishes the Live Activity surface") {
            controller.liveActivitySurfacePublishCountForTesting > publishesBefore
        }
    }

    /// Run B starts (its row is fetched off main) and ends before that fetch
    /// lands. The resync for the remaining run A must win: B's late fetch must
    /// not put a finished run back on the pet and the Live Activity.
    func test_aResyncSupersedesAChromeFetchForAnOlderActiveSet() async throws {
        let fixture = try await makeStreamingFixture("stalefetch")
        let controller = fixture.controller
        defer { controller.stop() }
        let (threadB, runB) = try makeRunningThread(context: fixture.context, workspace: fixture.workspace, title: "short run")

        // Both resyncs run in this main-actor turn, before the fetch can land.
        fixture.context.coordinator.bindActiveThreadForTesting(threadId: threadB.id, runId: runB)
        controller.refreshActiveThreadsFromCoordinatorForTests()
        fixture.context.coordinator.unbindActiveThreadForTesting(threadId: threadB.id)
        controller.refreshActiveThreadsFromCoordinatorForTests()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            controller.modelForTests.activeThreads.map(\.threadID), [fixture.thread.id],
            "a fetch for the older set {A, B} must not overwrite the newer set {A}"
        )
    }

    /// Bot runs B and C start together: B's bot lookup is dropped while C's is
    /// in flight, and C's result does not re-apply the newer set. The next
    /// resync must still resolve B, or B keeps the plain agent row (no Bots
    /// desk route, no Bot name) on the pet and the Live Activity until the set
    /// changes.
    func test_aResyncStillResolvesABotLinkDroppedWhileAnotherWasInFlight() async throws {
        let fixture = try await makeStreamingFixture("botlink")
        let controller = fixture.controller
        defer { controller.stop() }
        let context = fixture.context
        let (threadB, runB) = try makeRunningThread(context: context, workspace: fixture.workspace, title: "bot run B")
        let (threadC, runC) = try makeRunningThread(context: context, workspace: fixture.workspace, title: "bot run C")
        let bot = try context.botStore.create(name: "Ceo", title: "Lead", description: "", provider: .claude)
        // Separate BotStore: the controller's in-memory link cache stays cold,
        // so only the durable off-main lookup can resolve the links.
        let writer = BotStore(db: context.db)
        try writer.upsertConversation(BotConversation(botID: bot.id, title: "B", linkedAgentThreadID: threadB.id))
        try writer.upsertConversation(BotConversation(botID: bot.id, title: "C", linkedAgentThreadID: threadC.id))
        try await waitForPetEventsToSettle(controller)

        let lookupsBefore = controller.linkedBotDurableLookupCountForTesting
        controller.applyActiveThreadIDsForTests([fixture.thread.id, threadC.id])
        controller.applyActiveThreadIDsForTests([fixture.thread.id, threadB.id, threadC.id])
        try await waitUntil("C's bot lookup completes") {
            controller.linkedBotDurableLookupCountForTesting > lookupsBefore
        }

        context.coordinator.bindActiveThreadForTesting(threadId: threadB.id, runId: runB)
        context.coordinator.bindActiveThreadForTesting(threadId: threadC.id, runId: runC)
        controller.refreshActiveThreadsFromCoordinatorForTests()
        try await waitUntil("B's bot lookup completes") {
            controller.linkedBotDurableLookupCountForTesting > lookupsBefore + 1
        }
        let rowB = try XCTUnwrap(controller.modelForTests.activeThreads.first { $0.threadID == threadB.id })
        XCTAssertEqual(rowB.route, .botsDesk(botID: bot.id), "B routes to its Bot desk")
        XCTAssertTrue(rowB.detail?.contains("Ceo") == true, "B shows its Bot's name, got \(rowB.detail ?? "nil")")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.linkedBotDurableLookupCountForTesting, lookupsBefore + 2, "lookups stop once every link is resolved")
    }

    /// Bot runs B and C start (one lookup for both), then C ends before that
    /// lookup returns. Its result is for {A, B, C}, not the rows' {A, B}; B's
    /// link must still reach B's row instead of waiting for the set to change.
    func test_aBotLinkFoundForAnOlderSetStillReachesTheNewerRows() async throws {
        let fixture = try await makeStreamingFixture("botlinkolder")
        let controller = fixture.controller
        defer { controller.stop() }
        let context = fixture.context
        let (threadB, runB) = try makeRunningThread(context: context, workspace: fixture.workspace, title: "bot run B")
        let (threadC, _) = try makeRunningThread(context: context, workspace: fixture.workspace, title: "bot run C")
        let bot = try context.botStore.create(name: "Ceo", title: "Lead", description: "", provider: .claude)
        let writer = BotStore(db: context.db)
        try writer.upsertConversation(BotConversation(botID: bot.id, title: "B", linkedAgentThreadID: threadB.id))
        try writer.upsertConversation(BotConversation(botID: bot.id, title: "C", linkedAgentThreadID: threadC.id))
        try await waitForPetEventsToSettle(controller)

        let lookupsBefore = controller.linkedBotDurableLookupCountForTesting
        controller.applyActiveThreadIDsForTests([fixture.thread.id, threadB.id, threadC.id])
        controller.applyActiveThreadIDsForTests([fixture.thread.id, threadB.id])
        try await waitUntil("the lookup for {B, C} completes") {
            controller.linkedBotDurableLookupCountForTesting > lookupsBefore
        }

        // Item events of A and B keep re-checking the same set.
        context.coordinator.bindActiveThreadForTesting(threadId: threadB.id, runId: runB)
        controller.refreshActiveThreadsFromCoordinatorForTests()
        // The lock-free cache may already paint the Bots route; the Bot's name
        // comes only from the durable lookup's result being applied.
        let rowB = try XCTUnwrap(controller.modelForTests.activeThreads.first { $0.threadID == threadB.id })
        XCTAssertEqual(rowB.route, .botsDesk(botID: bot.id), "B routes to its Bot desk")
        XCTAssertTrue(rowB.detail?.contains("Ceo") == true, "B shows its Bot's name, got \(rowB.detail ?? "nil")")
        XCTAssertEqual(controller.modelForTests.activeThreads.map(\.threadID).sorted { $0.value.uuidString < $1.value.uuidString },
                       [fixture.thread.id, threadB.id].sorted { $0.value.uuidString < $1.value.uuidString },
                       "C stays gone")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.linkedBotDurableLookupCountForTesting, lookupsBefore + 1, "lookups stop once every link is resolved")
    }

    /// A failed hidden-task lookup shows no active rows. The next resync for the
    /// same set must apply it again instead of treating it as already applied.
    func test_aResyncRetriesTheActiveSetAfterAFailedHiddenTaskLookup() async throws {
        let fixture = try await makeStreamingFixture("hiddenretry")
        let controller = fixture.controller
        defer { controller.stop() }
        let (threadB, _) = try makeRunningThread(context: fixture.context, workspace: fixture.workspace, title: "second run")

        // The set {A, B} fails to apply: hidden-task lookup cannot read its table.
        try fixture.context.db.execute("ALTER TABLE bot_conversations RENAME TO bot_conversations_offline;")
        controller.applyActiveThreadIDsForTests([fixture.thread.id, threadB.id])
        try fixture.context.db.execute("ALTER TABLE bot_conversations_offline RENAME TO bot_conversations;")
        XCTAssertEqual(controller.modelForTests.activeThreads.map(\.threadID), [], "precondition: the lookup failed")

        // B ended meanwhile; the coordinator holds only A, the set applied before the failure.
        controller.refreshActiveThreadsFromCoordinatorForTests()
        XCTAssertEqual(
            controller.modelForTests.activeThreads.map(\.threadID), [fixture.thread.id],
            "the resync must re-apply the running set after the failed lookup"
        )
    }
}
