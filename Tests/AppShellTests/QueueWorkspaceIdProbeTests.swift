import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence
import SocketServer

/// WHY: queue EventBus + rail refresh used to full-get 26 columns + routing
/// JSON just to attach `workspace_id`. Reorder republishes every queued row.
@MainActor
final class QueueWorkspaceIdProbeTests: XCTestCase {
    private func makeRouter(_ label: String) throws -> (AppContext, AppCommandRouter, String) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router, tmp)
    }

    func test_reorderQueuedMessages_probesWorkspaceIdWithoutDurableGet() throws {
        let (ctx, router, _) = try makeRouter("queue-workspace-reorder")
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "queue-workspace",
            provider: .codex,
            model: "fake-model"
        )
        try ctx.threadRepo.upsert(thread)
        var queuedIDs: [AgentQueuedMessageID] = []
        queuedIDs.reserveCapacity(3)
        for index in 1...3 {
            let queued = try ctx.queuedMessageRepo.enqueue(
                threadId: thread.id,
                text: "follow-up \(index)",
                attachments: [],
                interactionMode: .default
            )
            queuedIDs.append(queued.id)
        }

        let recorder = QueueWorkspacePayloadRecorder(
            threadId: thread.id,
            workspaceId: workspaceID
        )
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            recorder.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.workspaceIdProbeCountForTesting
        try router.reorderAgentQueuedMessage(thread: thread.id, id: queuedIDs[0], position: 2)
        XCTAssertEqual(
            ctx.threadRepo.workspaceIdProbeCountForTesting,
            probesBefore + 4,
            "reorder must probe workspace_id once per queued EventBus row plus once for rail refresh"
        )
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "reorder must not compile a full 26-column get just to learn workspace_id"
        )
        XCTAssertEqual(recorder.count, 3)
        XCTAssertEqual(recorder.missingWorkspaceCount, 0)
    }

    func test_cancelQueuedMessage_probesWorkspaceIdWithoutDurableGet() throws {
        let (ctx, router, _) = try makeRouter("queue-workspace-cancel")
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "queue-cancel",
            provider: .codex,
            model: "fake-model"
        )
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "follow-up",
            attachments: [],
            interactionMode: .default
        )

        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.workspaceIdProbeCountForTesting
        _ = try router.cancelAgentQueuedMessage(id: queued.id)
        XCTAssertEqual(
            ctx.threadRepo.workspaceIdProbeCountForTesting,
            probesBefore + 2,
            "cancel must probe workspace_id for EventBus plus rail refresh"
        )
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "cancel must not compile a full 26-column get just to learn workspace_id"
        )
    }

    /// WHY: a queued message left `prepared` (its start was interrupted by a relaunch)
    /// keeps its lease. iOS Remove calls agent.message.queue.cancel; it used to throw
    /// invalidParams and the message could never be removed from the phone.
    func test_cancelQueuedMessage_removesPreparedMessageLeftByInterruptedStart() throws {
        let (ctx, router, _) = try makeRouter("queue-cancel-prepared")
        let thread = AgentThread(workspaceId: WorkspaceID(), title: "queue-cancel-prepared", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(threadId: thread.id, text: "merge all", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(try ctx.queuedMessageRepo.claim(id: queued.id))
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: AgentRunID(queued.id.value)))

        let cancelled = try router.cancelAgentQueuedMessage(id: queued.id)

        XCTAssertEqual(cancelled.id, queued.id)
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queued.id))
        XCTAssertThrowsError(try router.cancelAgentQueuedMessage(id: queued.id), "second cancel finds nothing to remove")
    }

    func test_queueChrome_sourceUsesWorkspaceIdProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let publishRange = try XCTUnwrap(
            source.range(of: "func publishQueuedMessage(kind: String, _ message: AgentQueuedMessage)")
        )
        let publishBody = String(source[publishRange.lowerBound...].prefix(1800))
        XCTAssertTrue(publishBody.contains("context?.threadRepo.workspaceId(of: message.threadId)"))
        XCTAssertFalse(publishBody.contains("threadRepo.get(id: message.threadId)"))

        let refreshRange = try XCTUnwrap(source.range(of: "private func refreshAgentSurfaces("))
        let refreshBody = String(source[refreshRange.lowerBound...].prefix(1600))
        XCTAssertTrue(refreshBody.contains("threadRepo.workspaceId(of: thread)"))
        XCTAssertFalse(refreshBody.contains("threadRepo.get(id: thread)"))
    }

    func test_workspaceIdProbe_fasterThanDurableGet() throws {
        let (ctx, _, _) = try makeRouter("queue-workspace-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try ctx.threadRepo.workspaceId(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.workspaceId(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] queue-workspace workspace_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "workspace_id probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}

private final class QueueWorkspacePayloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let threadId: String
    private let workspaceId: String
    private var value = 0
    private var missing = 0

    init(threadId: AgentThreadID, workspaceId: WorkspaceID) {
        self.threadId = threadId.value.uuidString
        self.workspaceId = workspaceId.value.uuidString
    }

    var count: Int { lock.withLock { value } }
    var missingWorkspaceCount: Int { lock.withLock { missing } }

    func record(_ event: EventBus.Event) {
        guard event.kind == "agent.message.queue.updated",
              event.payload.objectValue?["thread_id"]?.stringValue == threadId else { return }
        lock.lock()
        value += 1
        if event.payload.objectValue?["workspace_id"]?.stringValue != workspaceId {
            missing += 1
        }
        lock.unlock()
    }
}
