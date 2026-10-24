import XCTest
import CoreModel
@testable import SocketServer

final class EventStreamFilterDiagnosticsTests: XCTestCase {
    func test_fullDropsProviderRuntimeAndAdmitsMirroredLifecycle() {
        // WHY: default WS / in-process `.full` must stop hopping for ~5 Hz
        // provider traces, while iOS-mirrored workspace/surface/thread/item/run
        // kinds still pass. map() == nil is the onFilteredEvent admission hole.
        let runtime = event("agent.provider_runtime.event")
        XCTAssertFalse(
            EventStreamFilter.full.allows(runtime),
            "default full must not admit agent.provider_runtime.event"
        )
        XCTAssertNil(
            EventStreamFilter.full.map(runtime),
            "a dropped provider-runtime seq must take the onFilteredEvent path, not a frame"
        )
        XCTAssertTrue(
            EventStreamFilter.diagnostics.allows(runtime),
            "explicit diagnostics is the only filter that admits provider-runtime"
        )
        XCTAssertEqual(EventStreamFilter.diagnostics.map(runtime)?.kind, runtime.kind)

        XCTAssertTrue(EventStreamFilter.full.allows(event("agent.item.started")))
        XCTAssertTrue(EventStreamFilter.full.allows(event("agent.run.started")))
        XCTAssertTrue(EventStreamFilter.full.allows(event("agent.item.completed")))
        XCTAssertTrue(EventStreamFilter.full.allows(event("agent.item.delta")))
        XCTAssertTrue(EventStreamFilter.full.allows(event("workspace.updated")))
        XCTAssertTrue(EventStreamFilter.full.allows(event("surface.created")))
        XCTAssertTrue(EventStreamFilter.full.allows(event("agent.thread.created")))
        XCTAssertFalse(
            EventStreamFilter.cellularSafe().allows(runtime),
            "cellular-safe is not the diagnostics filter"
        )
    }

    func test_parseDiagnosticsOnlyWhenHeaderIsDiagnostics() {
        XCTAssertEqual(EventStreamFilter.parse(nil), .full)
        XCTAssertEqual(EventStreamFilter.parse("diagnostics"), .diagnostics)
        XCTAssertEqual(EventStreamFilter.parse("DIAGNOSTICS"), .diagnostics)
        XCTAssertEqual(
            EventStreamFilter.parse(filterHeader: "diagnostics", interestThreadHeader: "t1"),
            .diagnostics
        )

        let mixed = EventStreamFilter.parse("cellular-safe,diagnostics")
        XCTAssertTrue(
            mixed.isCellularSafe,
            "mixed cellular-safe + diagnostics stays cellular-safe so volume gating is not lost"
        )
        XCTAssertNotEqual(mixed, .diagnostics)
        XCTAssertEqual(
            EventStreamFilter.parse(filterHeader: "cellular-safe", interestThreadHeader: nil),
            .cellularSafe(interestThreadIds: [])
        )
    }

    func test_applyingInterestAndHeartbeatKeepDiagnosticsOnWifiProfile() {
        XCTAssertEqual(
            EventStreamFilter.diagnostics.applyingInterestThreadIds(["t1"]),
            .diagnostics
        )
        XCTAssertEqual(
            DirectHTTPServer.heartbeatProfile(forWSFilter: .diagnostics),
            DirectHTTPServer.heartbeatProfile(forWSFilter: .full),
            "diagnostics uses the Wi-Fi heartbeat profile like .full"
        )
        XCTAssertFalse(EventStreamFilter.diagnostics.isCellularSafe)
    }

    func test_fullSubscriberRecordsFilteredProviderRuntimeWithoutDelivering() {
        // WHY: EventBus publish already calls onFilteredEvent when map returns nil;
        // Pet/Bots on .full must not receive the kind, and the seq hole is accounted.
        let bus = EventBus(recentLimit: 32, recentByteLimit: 1_000_000)
        var delivered: [String] = []
        var filtered: [Int64] = []
        _ = bus.subscribeDetectingReplayExpiry(
            since: 0,
            filter: .full,
            onReplayExpired: { _ in XCTFail("fresh bus must not expire replay") },
            onFilteredEvent: { filtered.append($0) }
        ) { event in
            delivered.append(event.kind)
        }

        bus.publish(kind: .agentProviderRuntimeEvent, payload: .object(["thread_id": .string("t1")]))
        bus.publish(kind: .agentItemStarted, payload: .object(["thread_id": .string("t1")]))
        bus.publish(kind: .agentRunStarted, payload: .object(["thread_id": .string("t1")]))

        XCTAssertEqual(filtered, [1])
        XCTAssertEqual(delivered, ["agent.item.started", "agent.run.started"])
    }

    func test_deviceStreamsAdmitDistillLiveStatusCarriersOnly() {
        // WHY: the iOS chat strip (running tool, subagents, Linux VM stage) folds
        // the same Distill runtime events the Mac strip folds. Before this the
        // default device filter dropped every one, so the phone showed only a
        // generic working line while the Mac listed subagents and tool phases.
        // Other providers' traces and non-carrier methods stay diagnostics-only.
        func runtime(provider: String, method: String) -> EventBus.Event {
            EventBus.Event(seq: 1, kind: "agent.provider_runtime.event", payload: .object([
                "thread_id": .string("t1"),
                "provider": .string(provider),
                "method": .string(method),
                "payload_json": .string("{}")
            ]), ts: 0)
        }
        let carriers = [
            runtime(provider: "distill", method: "_remotecode/operation"),
            runtime(provider: "distill", method: "x.ai/session_notification"),
            runtime(provider: "distill", method: "remotecode/guest_stage"),
        ]
        for event in carriers {
            XCTAssertTrue(EventStreamFilter.full.allows(event))
            XCTAssertTrue(EventStreamFilter.cellularSafe(interestThreadIds: ["t1"]).allows(event))
        }
        XCTAssertFalse(EventStreamFilter.full.allows(runtime(provider: "distill", method: "available_commands_update")))
        XCTAssertFalse(EventStreamFilter.full.allows(runtime(provider: "claude", method: "x.ai/session_notification")))
        XCTAssertFalse(EventStreamFilter.agentThreadAndQueue.allows(carriers[0]),
                       "in-process prefix subscribers keep their own admission")
    }

    private func event(_ kind: String) -> EventBus.Event {
        EventBus.Event(seq: 1, kind: kind, payload: .object([:]), ts: 0)
    }
}
