import XCTest
@testable import AgentRuntime

/// WHY: Distill ends a turn while its subagents, background tasks and
/// workflows keep running in the same agent process. The host decides from
/// this tracker whether restarting that process would kill live work, and
/// whether a subagent whose parent turn ended is still running.
final class DistillBackgroundWorkTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testSubagentRunsFromSpawnUntilItsFinish() {
        var work = DistillBackgroundWork()
        let child = "01A1E791-91B2-79F3-9EA3-A8014B2419A6"
        work.apply(update: subagent("subagent_spawned", child), promptId: "user-prompt", live: true, at: start)
        XCTAssertTrue(work.isRunning(subagent: child.lowercased()), "a spawned subagent runs until Distill reports its end")
        XCTAssertTrue(work.isRunning(subagent: child), "receipts carry the child id upper-cased; the match must not depend on case")
        XCTAssertFalse(work.isEmpty)

        work.apply(update: subagent("subagent_finished", child, status: "completed"), promptId: nil, live: true, at: start)
        XCTAssertFalse(work.isRunning(subagent: child))
        XCTAssertTrue(work.isEmpty)
    }

    func testLoadTimeRowsOnlyEndWork() {
        // WHY: a new process never inherits its predecessor's running work, so a
        // replayed spawn must not make the host believe a subagent still runs.
        var work = DistillBackgroundWork()
        let child = UUID().uuidString
        work.apply(update: subagent("subagent_spawned", child), promptId: nil, live: false, at: start)
        XCTAssertFalse(work.isRunning(subagent: child))
        XCTAssertNil(work.lastReportAt, "load-time rows are not fresh activity")

        work.apply(update: subagent("subagent_spawned", child), promptId: nil, live: true, at: start)
        work.apply(
            update: subagent("subagent_finished", child, status: "cancelled"),
            promptId: nil, live: false, at: start
        )
        XCTAssertFalse(work.isRunning(subagent: child), "a load-time finish still ends the subagent")
    }

    func testBackgroundTasksFollowDistillsSnapshot() {
        var work = DistillBackgroundWork()
        work.apply(update: ["sessionUpdate": "task_backgrounded", "task_id": "build-1"], promptId: nil, live: true, at: start)
        work.apply(update: ["sessionUpdate": "task_backgrounded", "task_id": "tests-2"], promptId: nil, live: true, at: start)
        XCTAssertEqual(work.tasks, ["build-1", "tests-2"])

        work.apply(
            update: ["sessionUpdate": "task_completed", "task_snapshot": ["task_id": "build-1"]],
            promptId: nil, live: true, at: start
        )
        XCTAssertEqual(work.tasks, ["tests-2"])

        // The snapshot is authoritative: anything it no longer lists has ended.
        work.apply(update: ["sessionUpdate": "background_tasks", "tasks": []], promptId: nil, live: true, at: start)
        XCTAssertTrue(work.tasks.isEmpty)
    }

    func testOnlyAnActiveWorkflowRuns() {
        var work = DistillBackgroundWork()
        work.apply(update: workflow("wf_1", status: "active"), promptId: nil, live: true, at: start)
        XCTAssertEqual(work.workflows, ["wf_1"])

        work.apply(update: workflow("wf_1", status: "user_paused"), promptId: nil, live: true, at: start)
        XCTAssertTrue(work.workflows.isEmpty, "a paused workflow runs nothing a restart could kill")

        work.apply(update: workflow("wf_2", status: "active"), promptId: nil, live: true, at: start)
        work.apply(update: workflow("wf_2", status: "interrupted"), promptId: nil, live: true, at: start)
        XCTAssertTrue(work.isEmpty)
    }

    func testAgentTurnRunsUntilItsTurnCompletes() {
        // WHY: when a subagent finishes, Distill starts a turn of its own to
        // handle the result. Restarting the process mid-turn would cut it.
        var work = DistillBackgroundWork()
        let wake = "subagent-completed-01a1e791-91b2-79f3-9ea3-a8014b2419a6"
        work.apply(update: chunk(), promptId: wake, live: true, at: start)
        XCTAssertEqual(work.agentTurns, [wake])

        work.apply(update: ["sessionUpdate": "turn_completed", "prompt_id": wake], promptId: nil, live: true, at: start)
        XCTAssertTrue(work.agentTurns.isEmpty)

        // Distill stamps the session's current prompt id on later updates too;
        // a finished agent turn must not reopen from that stale id.
        work.apply(update: chunk(), promptId: wake, live: true, at: start)
        XCTAssertTrue(work.agentTurns.isEmpty)

        work.apply(update: chunk(), promptId: "3a53b13d-f1ff-47d7-83d8-cb7094d8c9b6", live: true, at: start)
        XCTAssertTrue(work.agentTurns.isEmpty, "a user prompt is the host's own turn, not background work")
    }

    func testRecentFinishKeepsTheSessionBusyUntilItsQuietPeriodPasses() {
        // WHY: the agent turn Distill starts for a finished subagent follows the
        // finish; restarting in that gap would kill the turn before it shows up.
        var work = DistillBackgroundWork()
        let child = UUID().uuidString
        work.apply(update: subagent("subagent_spawned", child), promptId: nil, live: true, at: start)
        work.apply(
            update: subagent("subagent_finished", child, status: "completed"),
            promptId: nil, live: true, at: start.addingTimeInterval(5)
        )
        XCTAssertTrue(work.isEmpty)
        XCTAssertTrue(work.isBusy(now: start.addingTimeInterval(20), quietPeriod: 30))
        XCTAssertFalse(work.isBusy(now: start.addingTimeInterval(36), quietPeriod: 30))
        XCTAssertFalse(DistillBackgroundWork().isBusy(now: start, quietPeriod: 30), "a session that never reported work is idle")
    }

    private func subagent(_ kind: String, _ id: String, status: String? = nil) -> [String: Any] {
        var update: [String: Any] = ["sessionUpdate": kind, "subagent_id": id, "child_session_id": id]
        if let status { update["status"] = status }
        return update
    }

    private func workflow(_ id: String, status: String) -> [String: Any] {
        ["sessionUpdate": "workflow_updated", "run_id": id, "status": status]
    }

    private func chunk() -> [String: Any] {
        ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "working"]]
    }
}
