import XCTest
import CoreModel
@testable import Surfaces

/// Chat contract: every transcript update appends in arrival order. A turn
/// that receives bot peer rows mid-run is split into chronological segments
/// around them instead of repainting the whole turn above the messages.
final class AgentChatTurnSegmentationTests: XCTestCase {

    private static let tid = AgentThreadID()

    private func item(_ id: String, turnId: String = "t1", ms: Int64, type: AssistantItemType = .tool) -> AssistantItem {
        AssistantItem(id: id, turnId: turnId, type: type, startedAtMs: ms)
    }

    private func turn(
        _ turnId: String = "t1",
        items: [AssistantItem],
        final: String? = nil,
        finished: Bool = false
    ) -> AssistantTurnSnapshot {
        AssistantTurnSnapshot(
            turnId: turnId,
            items: items,
            finalAssistantMessage: final,
            finished: finished,
            startedAtMs: items.first?.startedAtMs
        )
    }

    private func following(
        _ timeMs: Int64,
        can: Bool = true,
        row: String
    ) -> AgentChatTurnSegmentation.FollowingRow<String> {
        AgentChatTurnSegmentation.FollowingRow(timeMs: timeMs, canInterleave: can, row: row)
    }

    private func describe(_ elements: [AgentChatTurnSegmentation.WeaveElement<String>]) -> [String] {
        elements.map { element in
            switch element {
            case .segment(let segment):
                return "seg(\(segment.snapshot.items.map(\.id).joined(separator: "+")))"
            case .row(let row):
                return "row(\(row))"
            }
        }
    }

    // MARK: segmentCuts

    func test_segmentCuts_splitAtBoundaryTime_itemsAtOrBeforeBoundaryStayAbove() {
        // WHY: an item that started before (or exactly when) the reply arrived
        // belongs above it — the reply answers work that was already visible.
        let cuts = AgentChatTurnSegmentation.segmentCuts(
            itemTimesMs: [1_000, 2_000, 5_000],
            boundaryTimesMs: [2_000]
        )
        XCTAssertEqual(cuts, [2], "items at 1s and 2s stay above a boundary at 2s; 5s goes below")
    }

    func test_segmentCuts_headClamp_boundaryBeforeFirstItemStillCutsAfterTheTurnHead() {
        // WHY: the turn row precedes its following messages in entry order, so
        // a skewed early message must never paint above the turn's first item.
        let cuts = AgentChatTurnSegmentation.segmentCuts(
            itemTimesMs: [5_000, 6_000],
            boundaryTimesMs: [1_000]
        )
        XCTAssertEqual(cuts, [1], "boundary earlier than every item clamps to after the first item")
    }

    func test_segmentCuts_monotonicClamp_outOfOrderItemStampsCannotReorderAppendOrder() {
        // WHY: items are painted in append order; a later item with an earlier
        // stamp inherits its predecessor's effective time instead of jumping.
        let cuts = AgentChatTurnSegmentation.segmentCuts(
            itemTimesMs: [5_000, 1_000],
            boundaryTimesMs: [5_500]
        )
        XCTAssertEqual(cuts, [2], "item stamped 1s after an item stamped 5s is treated as ≥5s")
    }

    func test_segmentCuts_unsortedBoundariesProduceNonDecreasingCuts() {
        let cuts = AgentChatTurnSegmentation.segmentCuts(
            itemTimesMs: [1_000, 2_000, 3_000, 4_000],
            boundaryTimesMs: [3_000, 1_000]
        )
        XCTAssertEqual(cuts, [3, 3], "an out-of-order boundary clamps to its predecessor's cut")
    }

    // MARK: interleaved

    func test_interleaved_weavesSegmentsAndRowsInArrivalOrder() throws {
        let t = turn(items: [item("a", ms: 1_000), item("b", ms: 2_000), item("c", ms: 5_000)], final: "done")
        let woven = AgentChatTurnSegmentation.interleaved(
            turn: t,
            following: [following(3_000, row: "fromCeo"), following(4_000, row: "fromNexus")]
        )
        XCTAssertEqual(
            describe(try XCTUnwrap(woven)),
            ["seg(a+b)", "row(fromCeo)", "row(fromNexus)", "seg(c)"],
            "work before the replies paints above them; work after paints below — a chat, not a repaint"
        )
    }

    func test_interleaved_finalAnswerStaysOnLastSegmentOnly() throws {
        let t = turn(
            items: [item("a", ms: 1_000), item("b", ms: 5_000)],
            final: "the answer",
            finished: true
        )
        let woven = try XCTUnwrap(AgentChatTurnSegmentation.interleaved(
            turn: t,
            following: [following(3_000, row: "reply")]
        ))
        let segments = woven.compactMap { element -> AgentChatTurnSegmentation.TurnSegment? in
            if case .segment(let segment) = element { return segment }
            return nil
        }
        XCTAssertEqual(segments.count, 2)
        XCTAssertNil(segments[0].snapshot.finalAssistantMessage, "a mid-turn slice must not repeat the final")
        XCTAssertEqual(segments[1].snapshot.finalAssistantMessage, "the answer")
        XCTAssertTrue(segments[0].isFirst)
        XCTAssertFalse(segments[0].isLast)
        XCTAssertTrue(segments[1].isLast)
        XCTAssertTrue(segments.allSatisfy(\.snapshot.finished))
        XCTAssertEqual(
            segments.map(AgentChatLiveTurnChrome.showsWorkHeader(for:)),
            [true, false],
            "finishing a split turn must not duplicate its Work header below an interleaved row"
        )
    }

    func test_interleaved_rowIds_firstKeepsTurnRowIdentity_laterKeyOnFirstItem() throws {
        // WHY: the head of a turn must not remount when its first boundary
        // arrives (scroll/expansion state), and later segments need stable ids.
        let t = turn("t9", items: [item("a", turnId: "t9", ms: 1_000), item("b", turnId: "t9", ms: 5_000)])
        let woven = try XCTUnwrap(AgentChatTurnSegmentation.interleaved(
            turn: t,
            following: [following(2_000, row: "x")]
        ))
        let ids = woven.compactMap { element -> String? in
            if case .segment(let segment) = element { return segment.rowId }
            return nil
        }
        XCTAssertEqual(ids, ["turn-t9", "turnseg-t9-b"])
    }

    func test_interleaved_nilWhenNothingSplits_soCallersKeepTheOriginalRow() {
        let t = turn(items: [item("a", ms: 1_000), item("b", ms: 2_000)])
        XCTAssertNil(
            AgentChatTurnSegmentation.interleaved(turn: t, following: [] as [AgentChatTurnSegmentation.FollowingRow<String>]),
            "no following rows → passthrough"
        )
        XCTAssertNil(
            AgentChatTurnSegmentation.interleaved(turn: t, following: [following(9_000, row: "late")]),
            "a message after every item does not split — order was already correct"
        )
        XCTAssertNil(
            AgentChatTurnSegmentation.interleaved(turn: t, following: [following(1_500, can: false, row: "user")]),
            "a non-interleavable row never splits the turn"
        )
        XCTAssertNil(
            AgentChatTurnSegmentation.interleaved(
                turn: turn(items: []),
                following: [following(1_000, row: "x")]
            ),
            "a turn without items has nothing to split"
        )
    }

    func test_interleaved_stopRowEndsBoundaryCollection_restPaintAfterSegmentsInOrder() throws {
        // WHY: entry order is primary — a row that must not interleave (user
        // prompt, durable final) pins itself and everything after it below.
        let t = turn(items: [item("a", ms: 1_000), item("b", ms: 6_000)])
        let woven = try XCTUnwrap(AgentChatTurnSegmentation.interleaved(
            turn: t,
            following: [
                following(2_000, row: "peer1"),
                following(3_000, can: false, row: "final"),
                following(4_000, row: "peer2")
            ]
        ))
        XCTAssertEqual(
            describe(woven),
            ["seg(a)", "row(peer1)", "seg(b)", "row(final)", "row(peer2)"],
            "rows after the stop row keep entry order below the last segment"
        )
    }

    // MARK: AgentAppView.chatFlowRows

    private func message(
        _ content: String,
        role: AgentMessageRole = .assistant,
        secs: TimeInterval
    ) -> AgentMessage {
        AgentMessage(
            id: AgentMessageID(),
            threadId: Self.tid,
            role: role,
            content: content,
            createdAt: Date(timeIntervalSince1970: secs)
        )
    }

    private var ceo: BotDefinition {
        BotDefinition(handle: "ceo", name: "Ceo", title: "CEO", description: "", avatarSymbol: "star.fill")
    }

    private func rowKinds(_ rows: [AgentAppView.ChatFlowRow]) -> [String] {
        rows.map { row in
            switch row {
            case .entry(.message): return "msg"
            case .entry(.turn): return "turn"
            case .segment(let segment): return "seg(\(segment.snapshot.items.map(\.id).joined(separator: "+")))"
            }
        }
    }

    func test_chatFlowRows_peerReplyAndWaitingRowsInterleaveTheLiveTurn() {
        // The reported disorder: round-2 tool groups repainted ABOVE round-1
        // peer replies because the whole turn was one row sorted at its start.
        let t = turn(items: [
            item("ask1", ms: 1_000), item("ask2", ms: 2_000), item("round2", ms: 60_000)
        ])
        let reply = message(BotPeerTranscript.encode(peer: ceo, text: "PHP hoje é adulto."), secs: 30)
        let waiting = message(BotPeerTranscript.encodeActivity(peer: ceo, phase: .waiting), secs: 65)
        let rows = AgentAppView.chatFlowRows([
            .message(message("compare php", role: .user, secs: 0)),
            .turn(t),
            .message(reply),
            .message(waiting)
        ])
        XCTAssertEqual(
            rowKinds(rows),
            ["msg", "seg(ask1+ask2)", "msg", "seg(round2)", "msg"],
            "round-2 work paints AFTER round-1 replies; the waiting row stays newest at the bottom"
        )
    }

    func test_chatFlowRows_userAndPlainAssistantMessagesNeverSplitATurn() {
        let t = turn(items: [item("a", ms: 1_000), item("b", ms: 9_000)])
        let userRows = AgentAppView.chatFlowRows([
            .turn(t),
            .message(message("follow-up prompt", role: .user, secs: 5))
        ])
        XCTAssertEqual(rowKinds(userRows), ["turn", "msg"], "a user prompt must not weave into prior work")
        let plainRows = AgentAppView.chatFlowRows([
            .turn(t),
            .message(message("a durable assistant final", secs: 5))
        ])
        XCTAssertEqual(rowKinds(plainRows), ["turn", "msg"], "unattributed assistant rows keep today's order")
    }

    func test_chatFlowRows_turnWithoutBoundariesPassesThroughUnchanged() {
        let t = turn(items: [item("a", ms: 1_000)])
        let late = message(BotPeerTranscript.encode(peer: ceo, text: "after"), secs: 99)
        let rows = AgentAppView.chatFlowRows([.turn(t), .message(late)])
        XCTAssertEqual(rowKinds(rows), ["turn", "msg"])
        XCTAssertEqual(rows.map(\.id).first, "turn-t1", "passthrough keeps the original row identity")
    }

    func test_chatFlowRows_boundariesBelongToTheirOwnTurnGroupOnly() {
        // A message between turn1 and turn2 weaves into turn1 only; turn2's
        // rows are untouched.
        let t1 = turn("t1", items: [item("a", turnId: "t1", ms: 1_000), item("b", turnId: "t1", ms: 10_000)])
        let t2 = turn("t2", items: [item("c", turnId: "t2", ms: 20_000)])
        let reply = message(BotPeerTranscript.encode(peer: ceo, text: "mid"), secs: 5)
        let rows = AgentAppView.chatFlowRows([.turn(t1), .message(reply), .turn(t2)])
        XCTAssertEqual(rowKinds(rows), ["seg(a)", "msg", "seg(b)", "turn"])
    }

    func test_messageCanInterleaveTurn_onlyPeerChromeQualifies() {
        XCTAssertTrue(AgentAppView.messageCanInterleaveTurn(
            message(BotPeerTranscript.encode(peer: ceo, text: "reply"), secs: 1)
        ))
        XCTAssertTrue(AgentAppView.messageCanInterleaveTurn(
            message(BotPeerTranscript.encodeActivity(peer: ceo, phase: .waiting), secs: 1)
        ))
        // A Bot task link must sit beside the tool call that started its run,
        // not drop below the whole turn after the final answer.
        let link = BotParallelTask(botID: BotID(), conversationID: BotConversationID(),
            threadID: AgentThreadID(), runID: AgentRunID(), title: "Sync Linear")
        XCTAssertTrue(AgentAppView.messageCanInterleaveTurn(message(link.transcript, secs: 1)))
        XCTAssertFalse(AgentAppView.messageCanInterleaveTurn(message("plain", secs: 1)))
        XCTAssertFalse(AgentAppView.messageCanInterleaveTurn(message("user", role: .user, secs: 1)))
    }
}
