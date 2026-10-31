import XCTest
import CoreModel
@testable import Surfaces

// F7: AgentAppView.mergeTranscriptEntries must produce EXACTLY the same ordering
// as the canonical full sort it replaces — the O(N) merge is only allowed when it
// is provably identical, with a full-sort fallback otherwise.
final class MergeTranscriptEntriesTests: XCTestCase {

    private static let tid = AgentThreadID()

    private func msg(_ id: UUID, _ secs: TimeInterval) -> AgentMessage {
        AgentMessage(id: AgentMessageID(id), threadId: Self.tid, role: .user,
                     content: "m", createdAt: Date(timeIntervalSince1970: secs))
    }

    private func turn(_ turnId: String, _ startMs: Int64) -> AssistantTurnSnapshot {
        AssistantTurnSnapshot(turnId: turnId,
                              items: [AssistantItem(id: "i-\(turnId)", turnId: turnId, type: .tool, startedAtMs: startMs)])
    }

    private func reference(_ m: [AgentMessage], _ t: [AssistantTurnSnapshot]) -> [String] {
        (m.map(AgentAppView.TranscriptEntry.message) + t.map(AgentAppView.TranscriptEntry.turn))
            .sorted(by: AgentAppView.transcriptEntryOrdersBefore).map(\.id)
    }

    private func merged(_ m: [AgentMessage], _ t: [AssistantTurnSnapshot]) -> [String] {
        AgentAppView.mergeTranscriptEntries(messages: m, turns: t).map(\.id)
    }

    private func assertMatchesSort(_ m: [AgentMessage], _ t: [AssistantTurnSnapshot],
                                   _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(merged(m, t), reference(m, t), message, file: file, line: line)
    }

    func test_taskLinksFollowSameSecondUserMessagesRegardlessOfRandomIDs() {
        let task = BotParallelTask(botID: BotID(), conversationID: BotConversationID(),
            threadID: Self.tid, runID: AgentRunID(), title: "Inspect webhooks")
        let user = msg(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, 5)
        let link = AgentMessage(id: AgentMessageID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            threadId: Self.tid, role: .assistant, content: task.transcript, createdAt: user.createdAt)
        let entries = AgentAppView.mergeTranscriptEntries(messages: [user, link], turns: [])
        XCTAssertEqual(entries.map(\.id), [AgentAppView.TranscriptEntry.message(user).id,
                                         AgentAppView.TranscriptEntry.message(link).id],
            "The task must never appear above the user's instruction after timestamp precision is lost on disk")
    }

    func test_merge_interleavedDistinctTimestamps_matchesSort() {
        let m = [msg(UUID(), 1), msg(UUID(), 3), msg(UUID(), 5)]
        let t = [turn("a", 2000), turn("b", 4000)]   // sortTime = ms/1000 -> 2s, 4s
        assertMatchesSort(m, t, "fast-path merge of two ordered sides must interleave exactly like the full sort")
    }

    func test_merge_messageAndTurnShareSortTime_breaksTieByIdPrefix() {
        // A message and a turn at the same instant: id prefixes ("message-" < "turn-")
        // give a deterministic order that the merge must reproduce.
        let m = [msg(UUID(), 2)]
        let t = [turn("x", 2000)]
        assertMatchesSort(m, t, "equal-time message/turn tie must order identically to the canonical sort")
    }

    func test_merge_messagesOutOfIdOrderAtEqualTime_fallsBackToSort() {
        // Two messages at the SAME createdAt but supplied largest-id-first violates
        // canonical (sortTime, id) order, so the merge precondition fails and the
        // function must fall back to a full sort and still match exactly.
        let lo = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let hi = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let m = [msg(hi, 5), msg(lo, 5)]             // out of canonical order on purpose
        let t = [turn("a", 5000)]
        XCTAssertFalse(AgentAppView.isOrderedByTranscriptOrder(m.map(AgentAppView.TranscriptEntry.message)),
                       "precondition: the message side is intentionally out of canonical order")
        assertMatchesSort(m, t, "out-of-order ties must fall back to the full sort and remain identical")
    }

    func test_merge_emptySides() {
        assertMatchesSort([], [turn("a", 1000)], "empty messages must yield the turns in order")
        assertMatchesSort([msg(UUID(), 1)], [], "empty turns must yield the messages in order")
        assertMatchesSort([], [], "both empty must yield empty")
    }

    func test_merge_allMessagesBeforeAllTurns_andViceVersa() {
        let mEarly = [msg(UUID(), 1), msg(UUID(), 2)]
        let tLate = [turn("a", 10_000), turn("b", 11_000)]
        assertMatchesSort(mEarly, tLate, "non-overlapping ranges must concatenate in order")
        let mLate = [msg(UUID(), 100)]
        let tEarly = [turn("a", 1000)]
        assertMatchesSort(mLate, tEarly, "a turn entirely before a message must come first")
    }

    /// Empty turns (turnStarted, no items yet) used to report sortTime=0 and
    /// jump *above* the just-sent user bubble until the first thought arrived.
    func test_emptyTurnWithStartedAtSortsAfterUserMessage() {
        let userAt: TimeInterval = 1_700_000_000
        let m = [msg(UUID(), userAt)]
        let empty = AssistantTurnSnapshot(turnId: "live",
                                          items: [],
                                          startedAtMs: Int64((userAt + 0.05) * 1000))
        let ids = AgentAppView.mergeTranscriptEntries(messages: m, turns: [empty]).map(\.id)
        XCTAssertEqual(ids.first, AgentAppView.TranscriptEntry.message(m[0]).id,
                       "user message must stay above the live turn while it has no items yet")
        XCTAssertEqual(ids.last, AgentAppView.TranscriptEntry.turn(empty).id)

        let emptySort = AgentAppView.TranscriptEntry.turn(empty).sortTime
        XCTAssertGreaterThan(emptySort, 0,
                             "empty turns must not fall back to epoch 0 (which reorders them before every message)")
        XCTAssertGreaterThanOrEqual(emptySort, userAt)
    }

    /// WHY: open-thread hydration can timestamp a durable final before the turn's
    /// first tool stamp, painting the answer above "Work so far".
    func test_paintOrdered_placesPersistedFinalAfterItsTurn() {
        let tid = Self.tid
        let user = AgentMessage(
            id: AgentMessageID(),
            threadId: tid,
            role: .user,
            content: "ship it",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        // Final persisted *before* turn sortTime (first tool at 200s).
        let final = AgentMessage(
            id: AgentMessageID(),
            threadId: tid,
            role: .assistant,
            content: "Phases\n| A | B |",
            createdAt: Date(timeIntervalSince1970: 150)
        )
        let workTurn = AssistantTurnSnapshot(
            turnId: "long-turn",
            items: [
                AssistantItem(id: "tool-1", turnId: "long-turn", type: .tool, startedAtMs: 200_000)
            ],
            finalAssistantMessage: "Phases\n| A | B |",
            finished: true,
            startedAtMs: 200_000
        )
        let timeOrdered = AgentAppView.mergeTranscriptEntries(messages: [user, final], turns: [workTurn])
        // Sanity: raw time order puts final message before the turn.
        XCTAssertEqual(
            timeOrdered.map(\.id),
            [
                AgentAppView.TranscriptEntry.message(user).id,
                AgentAppView.TranscriptEntry.message(final).id,
                AgentAppView.TranscriptEntry.turn(workTurn).id,
            ],
            "precondition: time order alone inverts final above Work so far"
        )
        let paint = AgentAppView.paintOrderedTranscriptEntries(timeOrdered)
        XCTAssertEqual(
            paint.map(\.id),
            [
                AgentAppView.TranscriptEntry.message(user).id,
                AgentAppView.TranscriptEntry.turn(workTurn).id,
                AgentAppView.TranscriptEntry.message(final).id,
            ],
            "paint order must be user → Work so far turn → final answer"
        )
        // With work + final, the turn owns the answer after Work so far and the
        // message row is suppressed — so even if order slipped, only one answer.
        XCTAssertTrue(
            AgentAppView.shouldRenderFinalAssistantMessage(
                workTurn,
                persistedAssistantTexts: [final.content]
            )
        )
        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(
                messages: [user, final],
                timelineTurns: [workTurn]
            ),
            [final.id]
        )
    }

    /// WHY: screenshot class — long Phases final + 200-step Work so far; answer
    /// must not sit above the disclosure when a durable message row also exists.
    func test_workTurnOwnsFinal_hidesMatchingMessage_whenToolsPresent() {
        let tid = Self.tid
        let longFinal = """
        Soft-deletes FrontEgg profiles
        Proof
        Phases
        | Phase | Result |
        | plan | READY |
        | work | implement |
        """
        let final = AgentMessage(
            id: AgentMessageID(),
            threadId: tid,
            role: .assistant,
            content: longFinal,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let turn = AssistantTurnSnapshot(
            turnId: "t-work",
            items: (0..<5).map { i in
                AssistantItem(
                    id: "tool-\(i)",
                    turnId: "t-work",
                    type: .commandExecution,
                    summary: "shell \(i)",
                    startedAtMs: Int64(i + 1)
                )
            },
            finalAssistantMessage: longFinal,
            finished: true,
            startedAtMs: 1
        )
        XCTAssertTrue(AgentAppView.turnHasWorkDisclosureContent(turn))
        XCTAssertTrue(
            AgentAppView.shouldRenderFinalAssistantMessage(
                turn,
                persistedAssistantTexts: [longFinal]
            ),
            "turn with tools must paint final after Work so far"
        )
        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(
                messages: [final],
                timelineTurns: [turn]
            ),
            [final.id],
            "persisted duplicate must not paint above Work so far"
        )
    }

    func test_merge_omitsInternalHostHopUserMessage() {
        // WHY: Agent App persisted the host hop as a user bubble, so the
        // follow-up window anchored on "Quinn replied:" instead of the @mention
        // and painted raw markdown. Desk already hides that row.
        let ask = AgentMessage(
            id: AgentMessageID(),
            threadId: Self.tid,
            role: .user,
            content: "@quinn what is in the inbox?",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let hop = AgentMessage(
            id: AgentMessageID(),
            threadId: Self.tid,
            role: .user,
            content: BotPeerTranscript.hostHopPrompt(
                peerName: "Quinn",
                reply: "**Nome:** Quinn",
                userText: "@quinn what is in the inbox?"
            ),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertTrue(AgentAppView.isInternalPeerHopUserMessage(hop))
        XCTAssertFalse(AgentAppView.isInternalPeerHopUserMessage(ask))
        let ids = merged([ask, hop], [])
        XCTAssertTrue(ids.contains("message-\(ask.id.value.uuidString)"))
        XCTAssertFalse(
            ids.contains("message-\(hop.id.value.uuidString)"),
            "internal hop prompt must not enter the Agent App transcript"
        )

    }
}
