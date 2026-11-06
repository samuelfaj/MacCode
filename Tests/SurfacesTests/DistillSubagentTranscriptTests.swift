import XCTest
import CoreModel
@testable import Surfaces

final class DistillSubagentTranscriptTests: XCTestCase {
    private func line(_ update: [String: Any]) throws -> String {
        let row: [String: Any] = ["method": "session/update", "params": ["sessionId": "child", "update": update]]
        return String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self) + "\n"
    }

    func test_readerFindsChildSessionAndStreamsAppendedToolCalls() throws {
        // WHY: clicking a running subagent must show its task and live tool calls, and keep updating as it works.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions/%2Fsome%2Fcwd/child")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("updates.jsonl")
        try (try line(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Review the plan"]])
            + line(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read plan.md", "rawInput": ["path": "plan.md"]]))
            .write(to: file, atomically: true, encoding: .utf8)

        let reader = DistillSubagentTranscriptReader(sessionId: "child", distillHome: home)
        var timeline = AssistantTimelineState()
        let first = reader.read(finish: false)
        first.events.forEach { timeline.apply($0) }
        XCTAssertTrue(first.found)
        XCTAssertEqual(first.prompt, "Review the plan")
        XCTAssertEqual(timeline.turns.last?.items.map(\.id), ["t1"])
        XCTAssertEqual(timeline.turns.last?.finished, false, "a running subagent's turn stays live")

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data(try line(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Score 4/5"]]).utf8))
        try handle.close()
        reader.read(finish: true).events.forEach { timeline.apply($0) }
        XCTAssertEqual(timeline.turns.last?.finished, true)
        XCTAssertEqual(timeline.turns.last?.finalAssistantMessage, "Score 4/5", "only appended bytes are read, once")
    }

    func test_readerReportsMissingSession() {
        let reader = DistillSubagentTranscriptReader(sessionId: "nope", distillHome: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertFalse(reader.read(finish: false).found)
    }
}

final class SubagentDetailLabelTests: XCTestCase {
    private func item(model: String? = "auto", effort: AgentReasoningEffort? = nil) -> SubagentActivityItem {
        SubagentActivityItem(id: UUID(), runId: AgentRunID(), threadId: AgentThreadID(), nodeId: "native.distill.x",
                             displayName: "Native - Distill - aeb2", provider: .distill, model: model,
                             reasoningEffort: effort, phase: .working, lifecycleStatus: .accepted, finalRunStatus: nil,
                             admittedAt: Date(), finalizedAt: nil, lifecycleUpdatedAt: Date(), isActive: true)
    }

    func test_metaShowsTheModelAndEffortTheSubagentActuallyUses() {
        // WHY: the receipt only knows "auto"; the row must show what Distill reported the child is running.
        let detail = DistillLiveStatus.SubagentDetail(type: "explore", description: "Review the kitchen plan",
            model: "claude/claude-haiku-5-5", effort: "high", tokensUsed: 12_400, durationMs: 0, activity: nil)
        XCTAssertEqual(SubagentActivityProjection.metaLabel(for: item(), detail: detail),
                       "Distill · claude/claude-haiku-5-5 · High · 12k tokens")
        XCTAssertEqual(SubagentActivityProjection.taskLabel(for: item(), detail: detail), "explore · Review the kitchen plan")
        XCTAssertEqual(SubagentActivityProjection.metaLabel(for: item(effort: .low), detail: nil), "Distill · auto · Low",
                       "without provider detail the receipt route is still shown")
    }

    func test_summaryDetailReadsTheChildSessionAfterTheLiveEventsAreGone() throws {
        // WHY: a reopened conversation or a Bot desk never saw subagent_progress; the saved session still knows the model.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("sessions/%2Fcwd/child-1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("updates.jsonl"))
        try #"{"current_model_id":"claude/claude-haiku-5-5","reasoning_effort":"medium","agent_name":"general-purpose","generated_title":"geral:apartamento"}"#
            .write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let detail = try XCTUnwrap(DistillSubagentTranscriptReader.summaryDetail(sessionId: "child-1", distillHome: home))
        XCTAssertEqual(detail.model, "claude/claude-haiku-5-5")
        XCTAssertEqual(detail.effort, "medium")
        XCTAssertEqual(SubagentActivityProjection.taskLabel(for: item(), detail: detail), "general-purpose · geral:apartamento")
    }
}
