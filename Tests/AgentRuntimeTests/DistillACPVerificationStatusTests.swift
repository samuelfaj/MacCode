import XCTest
@testable import AgentRuntime
import CoreModel

/// Distill's UltraCode turn review appends a status line to the turn's final
/// message. Live incident 2026-11-15 (Bot desk, Distill 2.0.73): a thought
/// from Distill's hidden final-check round arrived between the answer and
/// that line. The line opened a message of its own, became the turn's final
/// message, and the answer the user was waiting for was demoted to work.
final class DistillACPVerificationStatusTests: XCTestCase {
    private static let answer = "The server answers now, but it refused the password."
    private static let status = "\n\nVerification: UNVERIFIED (no repository)"

    private func message(_ text: String) -> [String: Any] {
        ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]
    }

    private func thought(_ text: String) -> [String: Any] {
        ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": text]]
    }

    /// One whole turn through the production mapper and timeline reducer.
    private func runTurn(_ updates: [[String: Any]]) throws -> (turn: AssistantTurnSnapshot, final: String?) {
        let mapper = DistillACPEventMapper(sessionId: "s")
        var timeline = AssistantTimelineState()
        for event in mapper.beginTurn() { timeline.apply(event) }
        for update in updates {
            for event in mapper.consumeSessionUpdate(update) { timeline.apply(event) }
        }
        for event in mapper.finishTurn(stopReason: "end_turn", usage: nil) { timeline.apply(event) }
        return (try XCTUnwrap(timeline.turns.last), mapper.finalAssistantMessage)
    }

    private func assistantBodies(_ turn: AssistantTurnSnapshot) -> [String] {
        turn.items.filter { $0.type == .assistantMessage }.map(\.body)
    }

    func test_statusLineAfterAThoughtStaysOnTheAnswer() throws {
        let (turn, final) = try runTurn([
            message(Self.answer),
            thought("Nothing else is left to do."),
            message(Self.status)
        ])

        XCTAssertEqual(final, Self.answer + Self.status,
                       "the persisted reply must be the answer with its status, not the status alone")
        XCTAssertEqual(turn.finalAssistantMessage, Self.answer + Self.status)
        XCTAssertEqual(assistantBodies(turn), [Self.answer + Self.status],
                       "a second assistant message would be picked as the final one and hide the answer")
        XCTAssertTrue(turn.items.allSatisfy { $0.state == .completed })
    }

    /// A refuted review lists its gaps before the status; that block is still
    /// the end of the answer, not a reply of its own.
    func test_statusWithOpenReviewGapsStaysOnTheAnswer() throws {
        let gaps = "\n\nOpen review gaps:\n- src/a.rs:3 misses the empty case\n\n"
            + "To keep working until these gaps are closed, continue this request as a /goal.\n"
            + "Verification: UNVERIFIED (still refuted after 2 rework rounds)"
        let (turn, final) = try runTurn([
            message(Self.answer),
            thought("The reviewer is right about the empty case."),
            message(gaps)
        ])

        XCTAssertEqual(final, Self.answer + gaps)
        XCTAssertEqual(assistantBodies(turn), [Self.answer + gaps])
    }

    /// The rule is only for the status line. Other text after a thought is a
    /// new message, so an earlier preamble still collapses into the work log.
    func test_ordinaryTextAfterAThoughtStillStartsANewMessage() throws {
        let (turn, final) = try runTurn([
            message("Let me check the logs."),
            thought("The logs are clean."),
            message("Nothing is wrong.")
        ])

        XCTAssertEqual(final, "Nothing is wrong.")
        XCTAssertEqual(assistantBodies(turn), ["Let me check the logs.", "Nothing is wrong."])
    }

    /// Text before a tool call is a preamble, not the answer, so a status that
    /// follows the tool does not attach to it.
    func test_statusAfterAToolCallDoesNotAttachToThePreamble() throws {
        let (turn, final) = try runTurn([
            message("Running the check."),
            thought("Run it."),
            ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "run_terminal_command",
             "rawInput": ["command": "true"]],
            ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"],
            thought("It passed."),
            message(Self.status)
        ])

        XCTAssertEqual(final, Self.status)
        XCTAssertEqual(assistantBodies(turn), ["Running the check.", Self.status])
    }

    /// When nothing separates them the status simply continues the answer, as
    /// it always did; the thought case must not change that.
    func test_statusRightAfterTheAnswerContinuesTheSameMessage() throws {
        let (turn, final) = try runTurn([message(Self.answer), message(Self.status)])

        XCTAssertEqual(final, Self.answer + Self.status)
        XCTAssertEqual(assistantBodies(turn), [Self.answer + Self.status])
    }

    func test_onlyDistillsStatusChunkIsRecognized() {
        XCTAssertTrue(DistillACPEventMapper.isVerificationStatus("\n\nVerification: REVIEWED"))
        XCTAssertTrue(DistillACPEventMapper.isVerificationStatus(Self.status))
        XCTAssertTrue(DistillACPEventMapper.isVerificationStatus(
            "\n\nOpen review gaps:\n- a gap\n\nTo keep working until these gaps are closed, continue this request as a /goal.\nVerification: UNVERIFIED (review time budget used)"
        ))

        XCTAssertFalse(DistillACPEventMapper.isVerificationStatus("Verification: REVIEWED"),
                       "the model can write this line itself; Distill's chunk opens with a blank line")
        XCTAssertFalse(DistillACPEventMapper.isVerificationStatus("\n\nVerification: REVIEWED by me, and the tests pass."))
        XCTAssertFalse(DistillACPEventMapper.isVerificationStatus("\n\nI ran the checks.\nVerification: REVIEWED"),
                       "prose that happens to end with the line is an answer, not the status")
        XCTAssertFalse(DistillACPEventMapper.isVerificationStatus("\n\nVerification: PENDING"))
    }
}
