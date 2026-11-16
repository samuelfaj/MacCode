import XCTest
@testable import AgentRuntime
import CoreModel

/// Distill's final check can send the model back to work after it answered.
/// Live incident 2026-11-15: a 7,018-character answer, then tool calls, then a
/// 416-character note about what had been missing. The note was a message of
/// its own, became the turn's final message, and the answer the user asked
/// for was demoted to work. Distill now marks the answer, with an empty
/// message chunk that carries `_meta.turnAnswer`, before the reply's tool
/// calls; text that follows them belongs to the marked message.
final class DistillACPTurnAnswerTests: XCTestCase {
    private static let answer = "All six rooms are measured. The stairs are still blocked."
    private static let note = "The gate findings were missing from each room's notes. They are there now."
    private static let mark: [String: Any] = [
        "sessionUpdate": "agent_message_chunk",
        "content": ["type": "text", "text": ""],
        "_meta": ["turnAnswer": true]
    ]

    private func message(_ text: String) -> [String: Any] {
        ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]
    }

    private func thought(_ text: String) -> [String: Any] {
        ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": text]]
    }

    /// One finished tool call.
    private func tool(_ id: String) -> [[String: Any]] {
        [["sessionUpdate": "tool_call", "toolCallId": id, "title": "run_terminal_command",
          "rawInput": ["command": "true"]],
         ["sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed"]]
    }

    private func feed(_ updates: [[String: Any]], to mapper: DistillACPEventMapper,
                      _ timeline: inout AssistantTimelineState) {
        for event in mapper.beginTurn() { timeline.apply(event) }
        for update in updates {
            for event in mapper.consumeSessionUpdate(update) { timeline.apply(event) }
        }
        for event in mapper.finishTurn(stopReason: "end_turn", usage: nil) { timeline.apply(event) }
    }

    /// One whole turn through the production mapper and timeline reducer.
    private func runTurn(_ updates: [[String: Any]]) throws -> (turn: AssistantTurnSnapshot, final: String?) {
        let mapper = DistillACPEventMapper(sessionId: "s")
        var timeline = AssistantTimelineState()
        feed(updates, to: mapper, &timeline)
        return (try XCTUnwrap(timeline.turns.last), mapper.finalAssistantMessage)
    }

    private func assistantBodies(_ turn: AssistantTurnSnapshot) -> [String] {
        turn.items.filter { $0.type == .assistantMessage }.map(\.body)
    }

    func test_noteAfterTheMarkedAnswersToolCallsJoinsTheAnswer() throws {
        let (turn, final) = try runTurn(
            [message(Self.answer), Self.mark, thought("One note is missing.")]
                + tool("t1")
                + [thought("It is written now."), message(Self.note)]
        )

        let whole = Self.answer + "\n\n" + Self.note
        XCTAssertEqual(final, whole,
                       "the persisted reply must be the answer with the note, not the note alone")
        XCTAssertEqual(turn.finalAssistantMessage, whole)
        XCTAssertEqual(assistantBodies(turn), [whole],
                       "a second assistant message would be picked as the final one and hide the answer")
        XCTAssertTrue(turn.items.allSatisfy { $0.state == .completed })
    }

    /// The mark is what tells the two turns apart. Without it, text before a
    /// tool call is a preamble and must keep collapsing into the work log.
    func test_withoutTheMarkTextBeforeAToolCallIsStillAPreamble() throws {
        let (turn, final) = try runTurn(
            [message(Self.answer), thought("One note is missing.")]
                + tool("t1")
                + [message(Self.note)]
        )

        XCTAssertEqual(final, Self.note)
        XCTAssertEqual(assistantBodies(turn), [Self.answer, Self.note])
    }

    /// The note arrives in chunks and may open with its own blank lines. It
    /// is one paragraph under the answer, not one break per chunk.
    func test_aNoteStreamedInChunksStartsOneParagraph() throws {
        let (turn, final) = try runTurn(
            [message(Self.answer), Self.mark]
                + tool("t1")
                + [message("\n\n"), message("The gate findings "), message("are there now.")]
        )

        let whole = Self.answer + "\n\nThe gate findings are there now."
        XCTAssertEqual(final, whole)
        XCTAssertEqual(assistantBodies(turn), [whole])
    }

    /// The model may narrate between its tool calls. Each stretch of text is
    /// a paragraph of the answer; none opens a message that would replace it.
    func test_eachLaterStretchOfTextIsAParagraphOfTheAnswer() throws {
        let (turn, final) = try runTurn(
            [message(Self.answer), Self.mark]
                + tool("t1")
                + [message("Writing the notes.")]
                + tool("t2")
                + [message(Self.note)]
        )

        let whole = Self.answer + "\n\nWriting the notes.\n\n" + Self.note
        XCTAssertEqual(final, whole)
        XCTAssertEqual(assistantBodies(turn), [whole])
    }

    /// Distill sends text that opens the reply as the answer's next paragraph
    /// and marks afterwards. The mark covers the message as it stands then.
    func test_theMarkCoversTextAddedBeforeIt() throws {
        let (turn, final) = try runTurn(
            [message(Self.answer), message("\n\n"), message("One note is missing."), Self.mark]
                + tool("t1")
                + [message(Self.note)]
        )

        let whole = Self.answer + "\n\nOne note is missing.\n\n" + Self.note
        XCTAssertEqual(final, whole)
        XCTAssertEqual(assistantBodies(turn), [whole])
    }

    /// A thought can close the answer before the mark arrives. The mark is
    /// still about that answer.
    func test_aMarkRightAfterAThoughtStillFindsTheAnswer() throws {
        let (turn, final) = try runTurn(
            [message(Self.answer), thought("One note is missing."), Self.mark]
                + tool("t1")
                + [message(Self.note)]
        )

        let whole = Self.answer + "\n\n" + Self.note
        XCTAssertEqual(final, whole)
        XCTAssertEqual(assistantBodies(turn), [whole])
    }

    /// The extra work may end without another word. The answer is then still
    /// the turn's reply.
    func test_aTurnThatEndsOnItsToolCallsKeepsTheAnswer() throws {
        let (turn, final) = try runTurn([message(Self.answer), Self.mark] + tool("t1"))

        XCTAssertEqual(final, Self.answer)
        XCTAssertEqual(assistantBodies(turn), [Self.answer])
    }

    /// Distill's UltraCode status line ends the turn's final message, which
    /// is now the answer with its note.
    func test_theStatusLineEndsTheJoinedAnswer() throws {
        let status = "\n\nVerification: REVIEWED"
        let (turn, final) = try runTurn(
            [message(Self.answer), Self.mark]
                + tool("t1")
                + [message(Self.note), thought("Nothing else is left."), message(status)]
        )

        let whole = Self.answer + "\n\n" + Self.note + status
        XCTAssertEqual(final, whole)
        XCTAssertEqual(assistantBodies(turn), [whole])
    }

    /// A mark is about one turn. In the next one, text before a tool call is
    /// a preamble again.
    func test_theMarkDoesNotCarryIntoTheNextTurn() throws {
        let mapper = DistillACPEventMapper(sessionId: "s")
        var timeline = AssistantTimelineState()
        feed([message(Self.answer), Self.mark] + tool("t1") + [message(Self.note)], to: mapper, &timeline)
        feed([message("Let me look.")] + tool("t2") + [message("Nothing is wrong.")], to: mapper, &timeline)

        XCTAssertEqual(mapper.finalAssistantMessage, "Nothing is wrong.")
        XCTAssertEqual(assistantBodies(try XCTUnwrap(timeline.turns.last)),
                       ["Let me look.", "Nothing is wrong."])
    }

    /// A mark with no message before it has nothing to keep.
    func test_aMarkWithNoMessageChangesNothing() throws {
        let (turn, final) = try runTurn([Self.mark] + tool("t1") + [message("Nothing is wrong.")])

        XCTAssertEqual(final, "Nothing is wrong.")
        XCTAssertEqual(assistantBodies(turn), ["Nothing is wrong."])
    }

    func test_onlyDistillsMetaKeyMarksAnAnswer() {
        XCTAssertTrue(DistillACPEventMapper.marksTurnAnswer(Self.mark))
        XCTAssertFalse(DistillACPEventMapper.marksTurnAnswer(message(Self.answer)))
        XCTAssertFalse(DistillACPEventMapper.marksTurnAnswer([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": ""],
            "_meta": ["turnAnswer": false]
        ]))
        XCTAssertFalse(DistillACPEventMapper.marksTurnAnswer([
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": ""],
            "_meta": ["mergeBoundary": true]
        ]))
    }
}
