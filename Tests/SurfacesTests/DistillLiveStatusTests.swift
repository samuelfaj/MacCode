import XCTest
import AgentRuntime
import CoreModel
@testable import Surfaces

final class DistillLiveStatusTests: XCTestCase {

    func test_guestRecoveryIsVisibleOverThePreviousProviderOperation() {
        var status = DistillLiveStatus()
        let start = Date(timeIntervalSince1970: 1_000)
        status.apply(method: "_remotecode/operation",
            payloadJSON: #"{"operationId":"open","sequence":1,"revision":1,"phase":"loading_configuration","lastProgressAgeMs":0,"phaseElapsedMs":0}"#,
            receivedAt: start)
        status.apply(method: DistillGuestStage.runtimeMethod,
            payloadJSON: #"{"stage":"repairing"}"#, receivedAt: start.addingTimeInterval(2))
        XCTAssertEqual(status.headline, "Repairing Linux agent catalog…")
        XCTAssertNil(status.operationHeadline(now: start.addingTimeInterval(3)), "the timed operation label must not cover recovery")
        XCTAssertEqual(status.headlineSince, start.addingTimeInterval(2))
        status.apply(method: DistillGuestStage.runtimeMethod, payloadJSON: #"{"stage":"ready"}"#)
        XCTAssertEqual(status.headline, "Loading configuration")
        XCTAssertNotNil(status.operationHeadline(now: start.addingTimeInterval(4)))
        XCTAssertNil(status.guestStageSince)
    }

    func test_operationHeartbeatDoesNotResetProgressAndOlderUpdatesCannotReplaceNewWork() throws {
        var status = DistillLiveStatus()
        let start = Date(timeIntervalSince1970: 1_000)
        func apply(_ id: String, _ revision: Int, _ age: Double, _ now: Date, stalled: Bool = false) throws {
            let payload: [String: Any] = ["operationId": id, "sequence": 1, "revision": revision,
                "phase": "executing_tool", "lastProgressAgeMs": age, "phaseElapsedMs": age, "stalled": stalled]
            let data = try JSONSerialization.data(withJSONObject: payload)
            status.apply(method: "_remotecode/operation", payloadJSON: String(decoding: data, as: UTF8.self), receivedAt: now)
        }
        try apply("first", 1, 2_000, start)
        let progress = status.operation?.lastProgressAt
        try apply("first", 2, 0, start.addingTimeInterval(5))
        XCTAssertEqual(status.operation?.lastProgressAt, progress, "a heartbeat cannot move the last real progress forward")
        XCTAssertTrue(status.operationHeadline(now: start.addingTimeInterval(5))?.contains("7s ago") == true)
        try apply("second", 3, 700_000, start.addingTimeInterval(6), stalled: true)
        try apply("first", 2, 0, start.addingTimeInterval(7))
        XCTAssertEqual(status.operation?.id, "second", "an older operation cannot replace the current one")
        XCTAssertTrue(status.operationHeadline(now: start.addingTimeInterval(7))?.contains("no progress") == true)
        XCTAssertTrue(status.operationHeadline(now: start.addingTimeInterval(7))?.contains("Stop to cancel") == true)
    }
    private let method = "x.ai/session_notification"

    private func send(_ s: inout DistillLiveStatus, _ session: String, _ update: [String: Any], at: Date = Date()) {
        var u = update
        u["sessionUpdate"] = u["sessionUpdate"] ?? ""
        let data = try! JSONSerialization.data(withJSONObject: ["sessionId": session, "update": u])
        s.apply(method: method, payloadJSON: String(data: data, encoding: .utf8)!, receivedAt: at)
    }

    private func spawn(_ s: inout DistillLiveStatus) {
        send(&s, "main", ["sessionUpdate": "subagent_spawned", "subagent_id": "a1", "child_session_id": "c1",
                          "subagent_type": "general-purpose", "description": "goal plan writer"])
        send(&s, "main", ["sessionUpdate": "subagent_progress", "subagent_id": "a1", "child_session_id": "c1",
                          "duration_ms": 51_000, "tokens_used": 10,
                          "active_model": "meta/muse-spark-1.3-contributor", "active_reasoning_effort": "low"])
    }

    /// The strip must show the effort the call really runs at, not the session's
    /// configured default, and say when Jev is choosing it.
    func test_effortApplied_replacesConfiguredDefaultWithTheEffortInUse() {
        var s = DistillLiveStatus()
        send(&s, "main", ["sessionUpdate": "model_changed", "model_id": "claude/claude-opus-5-5", "reasoning_effort": "max"])
        XCTAssertEqual(s.modelEffortText, "claude/claude-opus-5-5 max")
        send(&s, "main", ["sessionUpdate": "effort_applied", "model_id": "claude-opus-5-5", "reasoning_effort": "low", "auto": true])
        XCTAssertEqual(s.modelEffortText, "claude/claude-opus-5-5 auto (low)")
        send(&s, "main", ["sessionUpdate": "effort_applied", "model_id": "claude-opus-5-5", "reasoning_effort": "high", "auto": false])
        XCTAssertEqual(s.modelEffortText, "claude/claude-opus-5-5 high")
        XCTAssertTrue(ProviderRuntimeEvent.isLiveStatusCarrier(method: "effort_applied"))
    }

    func test_childCompaction_namesSubagentSoUserSeesWhoIsBusy() {
        var s = DistillLiveStatus()
        spawn(&s)
        send(&s, "c1", ["sessionUpdate": "auto_compact_started"])
        XCTAssertEqual(s.headline, "Subagent (goal plan writer): Compacting…")
        XCTAssertEqual(s.subagents[0].phaseText, "Compacting")
        XCTAssertEqual(s.subagents[0].typeLabel, "General")
        XCTAssertEqual(s.modelEffortText, "meta/muse-spark-1.3-contributor low")
        XCTAssertNil(s.mainCompactingSince)
    }

    func test_guestStage_showsRealStartupProgressWithItsElapsedTime_thenGivesTheStripBack() throws {
        // WHY (AGENTS.md loading rules): a guest send must be acknowledged at
        // once with what is really happening, and the strip must return to
        // the turn's own status once the guest agent is up.
        var s = DistillLiveStatus()
        let start = Date()
        func stage(_ value: DistillGuestStage, at: Date) throws {
            guard case .providerRuntime(let runtime) = value.runtimeEvent else { return XCTFail("not a runtime event") }
            XCTAssertTrue(DistillLiveStatus.isCarrierMethod(runtime.method))
            s.apply(method: runtime.method, payloadJSON: runtime.payloadJSON, receivedAt: at)
        }
        try stage(.starting, at: start)
        XCTAssertEqual(s.headline, "Starting Linux agent…")
        XCTAssertEqual(s.headlineSince, start)
        XCTAssertFalse(s.isEmpty, "the strip renders the stage")
        let later = start.addingTimeInterval(3)
        try stage(.startingVM, at: later)
        XCTAssertEqual(s.headline, "Starting the bot's Linux VM…")
        XCTAssertEqual(s.headlineSince, later, "each stage counts its own time")
        send(&s, "main", ["sessionUpdate": "auto_compact_started"])
        XCTAssertEqual(s.headline, "Compacting…", "compaction outranks the startup stage")
        send(&s, "main", ["sessionUpdate": "auto_compact_completed"])
        try stage(.ready, at: later.addingTimeInterval(1))
        XCTAssertNil(s.headline)
        XCTAssertNil(s.headlineSince)
    }

    func test_mainCompaction_togglesHeadlineOnStartAndComplete() {
        var s = DistillLiveStatus()
        XCTAssertNil(s.headline)
        send(&s, "main", ["sessionUpdate": "auto_compact_started"])
        XCTAssertEqual(s.headline, "Compacting…")
        send(&s, "main", ["sessionUpdate": "auto_compact_completed"])
        XCTAssertNil(s.headline)
    }

    func test_finished_marksStatusAndStopsCompactingHeadline() {
        var s = DistillLiveStatus()
        spawn(&s)
        send(&s, "c1", ["sessionUpdate": "auto_compact_started"])
        send(&s, "main", ["sessionUpdate": "subagent_finished", "subagent_id": "a1", "status": "failed"])
        XCTAssertNil(s.headline)
        XCTAssertEqual(s.subagents[0].phaseText, "Failed")
    }

    func test_unrelatedMethodIgnored_soOtherProvidersEventsDoNotChangeStrip() {
        var s = DistillLiveStatus()
        s.apply(method: "available_commands_update", payloadJSON: "{}")
        send(&s, "main", ["sessionUpdate": "plan"])
        XCTAssertTrue(s.isEmpty)
    }

    func test_goalActiveThenCleared_stripShowsGoalOnlyWhileItExists() {
        var s = DistillLiveStatus()
        send(&s, "main", ["sessionUpdate": "goal_updated", "goal_id": "g1", "objective": "ship it",
                          "status": "active", "phase": "executing", "token_budget": 100_000,
                          "tokens_used": 12_000, "elapsed_ms": 5_000, "total_worker_rounds": 2])
        XCTAssertEqual(s.goalHeadline, "Goal: ship it — executing")
        XCTAssertEqual(s.goal?.tokensText, "12k / 100k")
        XCTAssertEqual(s.goal?.rounds, 2)
        send(&s, "main", ["sessionUpdate": "auto_compact_started"])
        XCTAssertNil(s.goalHeadline, "compaction headline wins over the goal headline")
        send(&s, "main", ["sessionUpdate": "goal_updated", "goal_id": "g1", "status": "cleared"])
        XCTAssertNil(s.goal)
        XCTAssertTrue(s.scheduledTasks.isEmpty)
    }

    func test_scheduledTaskCreatedFiredDeleted_loopsLineTracksLiveTasks() {
        var s = DistillLiveStatus()
        let fired = Date(timeIntervalSince1970: 100)
        send(&s, "main", ["sessionUpdate": "scheduled_task_created", "task_id": "t1", "prompt": "check ci",
                          "human_schedule": "every 5m"])
        XCTAssertEqual(s.scheduledTasks.map(\.id), ["t1"])
        XCTAssertEqual(s.scheduledTasks[0].humanSchedule, "every 5m")
        send(&s, "main", ["sessionUpdate": "scheduled_task_fired", "task_id": "t1"], at: fired)
        XCTAssertEqual(s.scheduledTasks[0].lastFiredAt, fired)
        XCTAssertEqual(s.scheduledTasks[0].prompt, "check ci")
        send(&s, "main", ["sessionUpdate": "scheduled_task_deleted", "task_id": "t1"])
        XCTAssertTrue(s.isEmpty)
    }

    func test_advertisedCommands_foldIntoComposerSuggestionsWithDescriptionAndHint() throws {
        // WHY: the composer must show Distill's own catalog (skills, /loop, ...) instead of a stale static list.
        let json = #"{"availableCommands":[{"name":"loop","description":"Run on interval","input":{"hint":"<interval> <prompt>"}}]}"#
        let commands = try XCTUnwrap(DistillLiveStatus.advertisedCommands(method: "available_commands_update", payloadJSON: json))
        XCTAssertEqual(commands.map(\.name), ["loop"])
        XCTAssertNil(DistillLiveStatus.advertisedCommands(method: "plan", payloadJSON: json))

        let out = AgentComposerSuggestions.suggestions(
            for: "/lo",
            snapshot: nil,
            localSlashCommands: [],
            extraCommands: commands.map { "/\($0.name)" },
            commandSubtitles: ["loop": try XCTUnwrap(commands[0].subtitle)]
        )
        XCTAssertEqual(out.first?.title, "/loop")
        XCTAssertEqual(out.first?.subtitle, "Run on interval · <interval> <prompt>")
    }

    func test_tokenFormatting_matchesTuiStyle() {
        XCTAssertEqual(DistillLiveStatus.formatTokens(135_000), "135k")
        XCTAssertEqual(DistillLiveStatus.formatTokens(1_500), "1.5k")
        XCTAssertEqual(DistillLiveStatus.formatTokens(950), "950")
    }
}
