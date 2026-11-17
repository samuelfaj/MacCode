import XCTest
@testable import AppShell
@testable import SocketServer
@testable import CoreModel
@testable import Surfaces

@MainActor
final class AgentEventWorkspaceFilterTests: XCTestCase {
    private let workspaceID = WorkspaceID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    private let foreignWorkspaceID = WorkspaceID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

    private func makeRouter(_ directory: String) throws -> (AppContext, AppCommandRouter) {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        return (context, router)
    }

    private func agentSurfaces(in workspaceID: WorkspaceID) -> [AgentAppSurface] {
        SurfaceRegistry.shared.all().compactMap { $0 as? AgentAppSurface }
            .filter { $0.viewModel.workspaceID == workspaceID }
    }

    private func closeAndUnregisterAgentSurfaces(in workspaceID: WorkspaceID) {
        for surface in agentSurfaces(in: workspaceID) {
            surface.close()
            SurfaceRegistry.shared.unregister(surface.descriptor.id)
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func publishForeignDeletion(of threadID: AgentThreadID) {
        EventBus.shared.publish(kind: .agentThreadDeleted, payload: .object([
            "workspace_id": .string(foreignWorkspaceID.value.uuidString),
            "thread_id": .string(threadID.value.uuidString)
        ]))
    }

    private func assertForeignDeletionWasNotHandled(
        by surface: AgentAppSurface,
        threadID: AgentThreadID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            surface.viewModel.selectedThreadId,
            threadID,
            "a foreign lifecycle event must not clear the selected local thread",
            file: file,
            line: line
        )
        XCTAssertTrue(
            surface.viewModel.threadCacheResidueForTesting.contains(threadID),
            "a foreign lifecycle event must not reach the local deletion handler",
            file: file,
            line: line
        )
    }

    func test_foreignWorkspaceEventIsRejectedBeforeMainDispatch() {
        let payload: JSONValue = .object([
            "workspace_id": .string(foreignWorkspaceID.value.uuidString),
            "thread_id": .string("foreign-thread")
        ])

        XCTAssertFalse(
            AppCommandRouter.shouldAdmitAgentLifecycleEvent(payload: payload, workspaceID: workspaceID),
            "a known foreign workspace must be rejected before the lifecycle callback schedules main-queue work"
        )
    }

    func test_matchingWorkspaceEventKeepsExistingDispatchPath() {
        let payload: JSONValue = .object([
            "workspace_id": .string(workspaceID.value.uuidString),
            "thread_id": .string("matching-thread")
        ])

        XCTAssertTrue(
            AppCommandRouter.shouldAdmitAgentLifecycleEvent(payload: payload, workspaceID: workspaceID),
            "a matching workspace event must continue through the existing lifecycle and queue handlers"
        )
    }

    func test_missingWorkspaceIdentityFailsOpenForLegacyEvents() {
        let payload: JSONValue = .object([
            "thread_id": .string("legacy-thread")
        ])

        XCTAssertTrue(
            AppCommandRouter.shouldAdmitAgentLifecycleEvent(payload: payload, workspaceID: workspaceID),
            "workspace-less legacy events must preserve existing handling"
        )
    }

    func test_malformedWorkspaceIdentityFailsOpen() {
        let payloads: [JSONValue] = [
            .object(["workspace_id": .string("not-a-uuid")]),
            .object(["workspace_id": .number(42)]),
            .object(["workspace_id": .null])
        ]

        for payload in payloads {
            XCTAssertTrue(
                AppCommandRouter.shouldAdmitAgentLifecycleEvent(payload: payload, workspaceID: workspaceID),
                "malformed workspace identity must preserve existing handling: \(payload)"
            )
        }
    }

    func test_createdSurfaceSubscriptionRejectsForeignEventBeforeLifecycleHandlers() async throws {
        let directory = NSTemporaryDirectory() + "RC2AgentEventCreated-" + UUID().uuidString
        let (context, router) = try makeRouter(directory)
        let workspace = try router.createWorkspace(name: "created", cwd: NSTemporaryDirectory())
        defer {
            closeAndUnregisterAgentSurfaces(in: workspace.id)
            try? FileManager.default.removeItem(atPath: directory)
        }
        let surface = try XCTUnwrap(agentSurfaces(in: workspace.id).first)
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "created subscription canary",
            provider: .codex,
            model: "test"
        )
        try context.threadRepo.upsert(thread)
        surface.viewModel.reloadThreads()
        surface.viewModel.selectThread(thread.id)
        surface.viewModel.seedAdditionalThreadCachesForTesting(thread.id)
        XCTAssertTrue(surface.viewModel.threadCacheResidueForTesting.contains(thread.id))

        publishForeignDeletion(of: thread.id)
        await drainMainQueue()

        assertForeignDeletionWasNotHandled(by: surface, threadID: thread.id)
    }

    func test_restoredSurfaceSubscriptionRejectsForeignEventBeforeLifecycleHandlers() async throws {
        let directory = NSTemporaryDirectory() + "RC2AgentEventRestored-" + UUID().uuidString
        var restoredWorkspaceID: WorkspaceID!
        var restoredThreadID: AgentThreadID!

        do {
            let (context, router) = try makeRouter(directory)
            let workspace = try router.createWorkspace(name: "restored", cwd: NSTemporaryDirectory())
            restoredWorkspaceID = workspace.id
            let thread = AgentThread(
                workspaceId: workspace.id,
                title: "restored subscription canary",
                provider: .codex,
                model: "test"
            )
            restoredThreadID = thread.id
            try context.threadRepo.upsert(thread)
            let surface = try XCTUnwrap(agentSurfaces(in: workspace.id).first)
            surface.viewModel.reloadThreads()
            surface.viewModel.selectThread(thread.id)
            context.saveSnapshot()
            closeAndUnregisterAgentSurfaces(in: workspace.id)
        }

        let (_, restoredRouter) = try makeRouter(directory)
        defer {
            closeAndUnregisterAgentSurfaces(in: restoredWorkspaceID)
            try? FileManager.default.removeItem(atPath: directory)
        }
        restoredRouter.reinstantiateRestoredSurfaces()
        let restoredSurface = try XCTUnwrap(agentSurfaces(in: restoredWorkspaceID).first)
        XCTAssertEqual(restoredSurface.viewModel.selectedThreadId, restoredThreadID)
        restoredSurface.viewModel.seedAdditionalThreadCachesForTesting(restoredThreadID)
        XCTAssertTrue(restoredSurface.viewModel.threadCacheResidueForTesting.contains(restoredThreadID))

        publishForeignDeletion(of: restoredThreadID)
        await drainMainQueue()

        assertForeignDeletionWasNotHandled(by: restoredSurface, threadID: restoredThreadID)
    }

}
