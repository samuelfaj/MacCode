import Combine
import CoreModel
import Persistence
import RemoteCodeTreaty
import SocketServer
import XCTest
@testable import AppShell

@MainActor
final class PetActivityCountsTests: XCTestCase {
    func testProjectionUsesServiceCountsNotLoadedItemCount() {
        let pageCounts = ActivityCounts(running: 7, queued: 2, needsYou: 3, finished: 20, newResults: 5)
        let projection = PetActivityCounts(pageCounts)

        XCTAssertEqual(projection.running, 7)
        XCTAssertEqual(projection.needsYou, 3)
        XCTAssertEqual(projection.newResults, 5)
    }

    func testWorkspaceIndicatorUsesOnlyConcreteActivityStates() {
        XCTAssertEqual(
            SidebarRootView.workspaceActivityLabel(PetActivityCounts(running: 2, needsYou: 1, newResults: 3)),
            "2 running · 1 needs you"
        )
        XCTAssertEqual(
            SidebarRootView.workspaceActivityLabel(PetActivityCounts(running: 0, needsYou: 0, newResults: 3)),
            "New result"
        )
        XCTAssertEqual(
            SidebarRootView.workspaceActivityLabel(PetActivityCounts.zero),
            "Activity unavailable"
        )
        XCTAssertEqual(
            SidebarRootView.workspaceActivityLabel(PetActivityCounts(running: 0, needsYou: 0, newResults: 0)),
            ""
        )
        XCTAssertEqual(
            SidebarViewModel.workspaceRowAccessibilityValue(
                busyDescription: nil,
                unreadCount: 0,
                activityDescription: "2 needs you",
                pinned: false,
                checked: false
            ),
            "2 needs you",
            "Legacy unread-event totals must never leak into workspace Activity status."
        )
    }

    func testNotificationReadEventRefreshesObserverWithoutWorkspaceReselection() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("PetActivityCounts-\(UUID().uuidString)")
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let id = try router.notificationCreate(
            workspaceId: workspace.id,
            title: "Agent input requested",
            body: "Review the active Agent thread",
            category: PetNotificationCategory.agentAttention.rawValue
        )
        let projection = PetActivityCountsProjection.shared
        var observed = PetActivityCounts.zero
        let token = projection.observe { counts, _ in observed = counts }
        defer { projection.removeObserver(token) }

        projection.refresh(router: router, workspaceIDs: [workspace.id])
        await waitForCount(1, observed: { observed.needsYou })
        XCTAssertEqual(observed.needsYou, 1)
        try router.notificationMarkRead(id: id)
        await waitForCount(0, observed: { observed.needsYou })
        XCTAssertEqual(observed.needsYou, 0)
    }

    func testUnchangedRefreshesDoNotReachObservers() async throws {
        // WHY: the sidebar and the Pet rebuild their whole view on every observer call, and
        // refreshes run on every workspace click, title change and agent lifecycle event.
        // Counts that did not change must not reach them; a real change still must.
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("PetActivityCounts-\(UUID().uuidString)")
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        _ = try router.notificationCreate(
            workspaceId: workspace.id,
            title: "Agent input requested",
            body: "Review the active Agent thread",
            category: PetNotificationCategory.agentAttention.rawValue
        )
        let projection = PetActivityCountsProjection.shared
        var calls: [PetActivityCounts] = []
        let token = projection.observe { counts, _ in calls.append(counts) }
        defer { projection.removeObserver(token) }

        projection.refresh(router: router, workspaceIDs: [workspace.id])
        await waitForCount(1, observed: { calls.last?.needsYou ?? -1 })
        let settled = calls.count
        for _ in 0..<10 {
            let completed = projection.completedRefreshCountForTests
            projection.refresh(router: router, workspaceIDs: [workspace.id])
            await waitForCount(completed + 1, observed: { projection.completedRefreshCountForTests })
        }
        XCTAssertEqual(calls.count, settled, "identical counts must not republish")
        XCTAssertEqual(projection.byWorkspace[workspace.id.value.uuidString]?.needsYou, 1)

        _ = try router.notificationCreate(
            workspaceId: workspace.id,
            title: "Agent input requested",
            body: "Review another Agent thread",
            category: PetNotificationCategory.agentAttention.rawValue
        )
        projection.refresh(router: router, workspaceIDs: [workspace.id])
        await waitForCount(2, observed: { calls.last?.needsYou ?? -1 })
        XCTAssertEqual(calls.count, settled + 1, "a changed count publishes exactly once")
    }

    func testFailedRefreshAfterRouterChangeStillShowsUnavailable() async throws {
        // WHY: a router change drops the previous router's counts. If the new router's first
        // refresh fails, the sidebar and the Pet must show "unavailable", not keep presenting
        // the old router's numbers as fresh because the unchanged-count guard saw nothing new.
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("PetActivityCounts-\(UUID().uuidString)")
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let routerA = AppCommandRouter(context: context)
        context.router = routerA
        let workspace = try routerA.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        _ = try routerA.notificationCreate(
            workspaceId: workspace.id,
            title: "Agent input requested",
            body: "Review the active Agent thread",
            category: PetNotificationCategory.agentAttention.rawValue
        )
        let projection = PetActivityCountsProjection.shared
        var observed = PetActivityCounts.zero
        var observedWorkspace: PetActivityCounts?
        let token = projection.observe { counts, workspaces in
            observed = counts
            observedWorkspace = workspaces[workspace.id.value.uuidString]
        }
        defer { projection.removeObserver(token) }

        projection.refresh(router: routerA, workspaceIDs: [workspace.id])
        await waitForCount(1, observed: { observed.needsYou })
        XCTAssertTrue(observed.isAvailable)

        // No context: activityCountsOffMain throws.
        let routerB = AppCommandRouter(context: context)
        routerB.context = nil
        let completed = projection.completedRefreshCountForTests
        projection.refresh(router: routerB, workspaceIDs: [workspace.id])
        await waitForCount(completed + 1, observed: { projection.completedRefreshCountForTests })
        XCTAssertFalse(observed.isAvailable, "a failed refresh must surface as unavailable")
        XCTAssertEqual(observed.needsYou, 0, "the previous router's counts must not stay on screen")
        XCTAssertNotEqual(observedWorkspace?.isAvailable, true, "workspace rows must not keep the old counts as fresh")
    }

    func testCountsOnlyPathMatchesTheActivityPage() throws {
        // WHY: the Pet and sidebar read counts through a path that skips checkpoints, sorting
        // and JSON. Their numbers must stay the ones the Activity window shows, for every
        // rule that decides a count: canonical running vs needs-you, pending-callback blocking,
        // unacknowledged failures, unread results, needs-you notifications deduped against
        // runs, and workspace scoping.
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("PetActivityCounts-\(UUID().uuidString)")
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let workspaceA = WorkspaceID(), workspaceB = WorkspaceID()
        var activeRuns: [AgentThreadID: AgentRunID] = [:]
        for (index, workspace) in [workspaceA, workspaceB, nil].enumerated() {
            let thread = AgentThread(workspaceId: workspace, title: "Counts \(index)", provider: .codex, model: "test")
            try context.threadRepo.upsert(thread)
            for (offset, status) in [AgentRunStatus.completed, .failed, .interrupted, .cancelled, .pending].enumerated() {
                let at = Date(timeIntervalSince1970: Double(1_000 + index * 100 + offset))
                try context.runRepo.upsert(AgentRun(threadId: thread.id, provider: .codex, model: "test", status: status, startedAt: at, finishedAt: status == .pending ? nil : at))
            }
            let running = AgentRun(threadId: thread.id, provider: .codex, model: "test", status: .running, startedAt: Date(timeIntervalSince1970: Double(2_000 + index)))
            try context.runRepo.upsert(running)
            if index != 1 { activeRuns[thread.id] = running.id }
            if index == 0 {
                try context.providerPendingCallbackRepo.record(threadId: thread.id, request: AssistantPendingRequest(id: "approval", turnId: nil, kind: .commandExecution, title: "not exposed", createdAtMs: 1))
            }
            try NotificationRepository(db: context.db).insert(AppNotification(
                id: "run-note-\(index)", workspaceId: workspace, title: "safe",
                body: "{\"run_id\":\"\(running.id.description)\"}", category: PetNotificationCategory.agentAttention.rawValue
            ))
            try NotificationRepository(db: context.db).insert(AppNotification(
                id: "note-\(index)", workspaceId: workspace, title: "safe", category: PetNotificationCategory.agentAttention.rawValue
            ))
            try NotificationRepository(db: context.db).insert(AppNotification(
                id: "git-\(index)", workspaceId: workspace, title: "safe", category: PetNotificationCategory.gitFailed.rawValue
            ))
        }
        context.projectScriptRuns.register(workspaceID: workspaceA, surfaceID: SurfaceID(), name: "Build")
        let service = ActivityService(context: context, activeRunIDProvider: { activeRuns[$0] })
        let readFirst = try service.list(["limit": .number(1)])
        let page = try ActivityPage.makeJSONDecoder().decode(ActivityPage.self, from: JSONEncoder().encode(readFirst))
        XCTAssertGreaterThan(page.counts.running, 0)
        XCTAssertGreaterThan(page.counts.needsYou, 0)
        XCTAssertGreaterThan(page.counts.queued, 0)
        XCTAssertGreaterThan(page.counts.newResults, 0)

        let counts = try service.counts()
        XCTAssertEqual(counts.global, page.counts)
        XCTAssertEqual(counts.runningOutsideAgentCoordinator, 1, "count the script independently of active agent runs")
        XCTAssertEqual(counts.byWorkspace, page.workspaceCounts)
        XCTAssertEqual(counts.byWorkspace.count, 2)
    }

    func testPetModelIgnoresUnchangedCounts() {
        // WHY: every PetViewModel publish re-renders the sprite panel and any open popover.
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let counts = PetActivityCounts(running: 1, needsYou: 2, newResults: 3)
        var changes = 0
        let sink = model.objectWillChange.sink { changes += 1 }
        defer { sink.cancel() }

        for _ in 0..<10 { model.apply(activityCounts: counts) }
        XCTAssertEqual(changes, 1)
        model.apply(activityCounts: PetActivityCounts(running: 2, needsYou: 2, newResults: 3))
        XCTAssertEqual(changes, 2)
    }

    private func waitForCount(
        _ expected: Int,
        observed: () -> Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if observed() == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for count \(expected); got \(observed())", file: file, line: line)
    }

    func testPetBadgeAddsJustFinishedToNeedsYouAndKeepsExistingPreference() {
        // WHY: the pet dot and the Dock badge must show the same total; the accessibility value still
        // speaks only of items that need attention, so the spoken count is unchanged.
        let enabled = PetViewModel(settings: AppSettings(petEnabled: true, petReadyCounterEnabled: true))
        enabled.apply(activityCounts: PetActivityCounts(running: 4, needsYou: 2, newResults: 4))
        XCTAssertEqual(enabled.badgeText, "6")
        XCTAssertTrue(enabled.accessibilityValue.contains("4 running"))
        XCTAssertTrue(enabled.accessibilityValue.contains("2 items need attention"))

        let disabled = PetViewModel(settings: AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        disabled.apply(activityCounts: PetActivityCounts(running: 4, needsYou: 2, newResults: 4))
        XCTAssertNil(disabled.badgeText)
    }
}
