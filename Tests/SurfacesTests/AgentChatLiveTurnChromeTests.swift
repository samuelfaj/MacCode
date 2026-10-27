import XCTest
import AgentRuntime
import CoreModel
import SwiftUI
@testable import Surfaces

final class AgentChatLiveTurnChromeTests: XCTestCase {
    func test_runningToolsTrackRealTimelineDeltasAndParallelCompletion() {
        let start = Date(timeIntervalSince1970: 100)
        var timeline = AssistantTimelineState()
        timeline.apply(.turnStarted(turnId: "t"), nowMs: 100_000)
        for id in ["build", "tests"] {
            timeline.apply(.itemStarted(item: AssistantItem(id: id, turnId: "t", type: .tool,
                                                          body: "command \(id)", startedAtMs: 100_001)))
        }
        XCTAssertEqual(AgentChatLiveTurnChrome.runningTools(in: timeline.turns, since: start).map(\.id), ["build", "tests"])
        timeline.apply(.itemDelta(itemId: "build", bodyAppend: nil, outputAppend: "Building module\n", summary: nil))
        XCTAssertEqual(AgentChatLiveTurnChrome.recentToolOutput(AgentChatLiveTurnChrome.runningTools(in: timeline.turns, since: start)[0]),
                       "Building module\n", "running details must consume actual timeline output deltas")
        timeline.apply(.itemCompleted(itemId: "build", finalState: .completed))
        XCTAssertEqual(AgentChatLiveTurnChrome.runningTools(in: timeline.turns, since: start).map(\.id), ["tests"])
        timeline.apply(.itemCompleted(itemId: "tests", finalState: .cancelled))
        XCTAssertTrue(AgentChatLiveTurnChrome.runningTools(in: timeline.turns, since: start).isEmpty,
                      "cancelled or finished commands must not leave a phantom running panel")
    }

    func test_recentToolOutputIsBoundedAndKeepsNewestUnicodeOutput() {
        var item = AssistantItem(id: "shell", turnId: "t", type: .tool, startedAtMs: 0)
        XCTAssertNil(AgentChatLiveTurnChrome.recentToolOutput(item))
        item.output = ""
        XCTAssertNil(AgentChatLiveTurnChrome.recentToolOutput(item))
        item.output = String(repeating: "old", count: 2_000) + "🛠 latest line"
        let tail = AgentChatLiveTurnChrome.recentToolOutput(item)
        XCTAssertEqual(tail?.count, 2_000, "live status must bound output rendering independently of full transcript size")
        XCTAssertTrue(tail?.hasSuffix("🛠 latest line") == true, "the newest output matters when following a long command")
        XCTAssertEqual(item.output?.count, 6_013, "display projection must not truncate the persisted tool output")
    }

    func test_runningToolsFollowCurrentRunAndKeepRealCommandOutput() {
        let start = Date(timeIntervalSince1970: 100)
        let active = AssistantItem(id: "current", turnId: "t", type: .commandExecution,
                                   body: "swift test --filter Example", output: "Test started\n", startedAtMs: 100_001)
        var done = active
        done.state = .completed
        let old = AssistantItem(id: "old", turnId: "old", type: .tool, startedAtMs: 99_000)
        let reasoning = AssistantItem(id: "thought", turnId: "t", type: .reasoning, startedAtMs: 100_001)
        let turns = [AssistantTurnSnapshot(turnId: "t", items: [old, reasoning, active, done]),
                     AssistantTurnSnapshot(turnId: "finished", items: [active], finished: true)]
        XCTAssertEqual(AgentChatLiveTurnChrome.runningTools(in: turns, since: start), [active],
                       "the running strip must not borrow tools from earlier runs or completed turns")
        XCTAssertTrue(AgentChatLiveTurnChrome.runningTools(in: turns, since: nil).isEmpty)
        var updated = active
        updated.output = "Test passed\n"
        XCTAssertEqual(AgentChatLiveTurnChrome.runningTools(in: [.init(turnId: "t", items: [updated])], since: start).first?.output,
                       "Test passed\n", "provider output must stay live, not freeze when tool identity stays the same")
        updated.state = .failed
        XCTAssertTrue(AgentChatLiveTurnChrome.runningTools(in: [.init(turnId: "t", items: [updated])], since: start).isEmpty)
    }

    func test_liveTurnPaintsANewestWindowOfWorkBlocksWithEarlierStepsBehindAReveal() throws {
        // WHY (AA-23): a turn with hundreds of tool groups mounted every block as
        // an eager row and, while live, re-diffed all of them on every paint
        // tick. The newest window paints; older blocks stay one tap away.
        let blocks: [AgentChatWorkBlock] = (0..<60).map { index in
            .item(AssistantItem(id: "step-\(index)", turnId: "t", type: .reasoning, body: "step \(index)", startedAtMs: Int64(index)))
        }
        let folded = AgentChatLiveTurnChrome.visibleWorkBlocks(blocks, revealCount: 0)
        XCTAssertEqual(folded.rows.count, AgentWorkDisclosureLayout.expandedPaintWindow)
        XCTAssertEqual(folded.hiddenCount, 60 - AgentWorkDisclosureLayout.expandedPaintWindow)
        XCTAssertEqual(folded.rows.last?.id, blocks.last?.id, "the newest block is always painted")
        XCTAssertEqual(folded.rows.first?.id, blocks[12].id, "the oldest painted block follows the window")

        let hiddenBase = blocks.count - AgentWorkDisclosureLayout.expandedPaintWindow
        let revealed = AgentWorkDisclosureLayout.advancedRevealCount(current: 0, hiddenBase: hiddenBase)
        let opened = AgentChatLiveTurnChrome.visibleWorkBlocks(blocks, revealCount: revealed)
        XCTAssertEqual(opened.hiddenCount, 0, "one reveal page exposes the remaining 12 older steps")
        XCTAssertEqual(opened.rows.count, 60)

        let short = AgentChatLiveTurnChrome.visibleWorkBlocks(Array(blocks.prefix(10)), revealCount: 0)
        XCTAssertEqual(short.hiddenCount, 0, "turns under the window are unchanged")
        XCTAssertEqual(short.rows.count, 10)

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentChatLiveTurnChrome.swift"),
            encoding: .utf8
        )
        let bodyStart = try XCTUnwrap(source.range(of: "let slice = AgentChatLiveTurnChrome.visibleWorkBlocks(blocks, revealCount: earlierWorkReveal)"))
        let body = String(source[bodyStart.upperBound...].prefix(2_500))
        XCTAssertTrue(body.contains("ForEach(slice.rows)"), "the turn view must paint the window, not every block")
        XCTAssertTrue(body.contains("Show earlier steps ("), "older blocks stay reachable")
    }

    func test_normalizedAssistantFinalsMemoizeFinishedTurnsOnly() {
        // WHY: the row paint context normalizes every visible turn's assistant
        // text on every body pass (per-scalar walk). Finished turns are
        // immutable in practice and must be served from the memo; live turns
        // must always reflect the current body.
        func turn(_ id: String, body: String, final: String?, finished: Bool) -> AssistantTurnSnapshot {
            var t = AssistantTurnSnapshot(turnId: id, startedAtMs: 1)
            t.items = [AssistantItem(id: "\(id)-a", turnId: id, type: .assistantMessage, body: body, startedAtMs: 1)]
            t.finalAssistantMessage = final
            t.finished = finished
            return t
        }
        let finished = turn("memo-\(UUID().uuidString)", body: "Same  answer", final: "Same answer", finished: true)
        let before = AgentChatLiveTurnChrome.normalizedFinalsComputeCountForTesting
        let first = AgentChatLiveTurnChrome.normalizedAssistantFinals(for: finished)
        XCTAssertEqual(first, [AgentTranscriptOrder.normalizedFinalText("Same  answer"), AgentTranscriptOrder.normalizedFinalText("Same answer")])
        XCTAssertEqual(AgentChatLiveTurnChrome.normalizedFinalsComputeCountForTesting, before + 1)
        _ = AgentChatLiveTurnChrome.normalizedAssistantFinals(for: finished)
        XCTAssertEqual(AgentChatLiveTurnChrome.normalizedFinalsComputeCountForTesting, before + 1, "a finished turn is served from the memo")

        var changedFinal = finished
        changedFinal.finalAssistantMessage = "Same answer, revised"
        _ = AgentChatLiveTurnChrome.normalizedAssistantFinals(for: changedFinal)
        XCTAssertEqual(AgentChatLiveTurnChrome.normalizedFinalsComputeCountForTesting, before + 2, "a different final length re-keys the memo")

        let live = turn("live-\(UUID().uuidString)", body: "streaming", final: nil, finished: false)
        _ = AgentChatLiveTurnChrome.normalizedAssistantFinals(for: live)
        _ = AgentChatLiveTurnChrome.normalizedAssistantFinals(for: live)
        XCTAssertEqual(AgentChatLiveTurnChrome.normalizedFinalsComputeCountForTesting, before + 4, "live turns are never memoized")
    }


    func test_streamingReasoningUsesThinkingLabel_becauseTheUserMustSeeLiveThought() {
        // WHY: a live turn that is still reasoning is not "Working…". Agent App
        // shows Thinking… with the streaming body so the user can watch thought.
        let item = AssistantItem(
            id: "r1",
            turnId: "t1",
            type: .reasoning,
            state: .streaming,
            body: "Considering the failing test",
            startedAtMs: 1_000
        )
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: true), "Thinking…")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(item), "Considering the failing test")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: item.state == .streaming), "Thinking…")
    }

    func test_finishedReasoningUsesThoughtLabel_becauseSettledWorkShouldCollapse() {
        // WHY: once reasoning completes, the row must collapse to Thought so
        // the final answer is not pushed down by a long chain-of-thought.
        let item = AssistantItem(
            id: "r1",
            turnId: "t1",
            type: .reasoning,
            state: .completed,
            body: "The suite is red because of a nil unwrap.",
            startedAtMs: 1_000,
            finishedAtMs: 2_000
        )
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: false), "Thought")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(item), "The suite is red because of a nil unwrap.")
        XCTAssertEqual(
            AgentChatLiveTurnChrome.reasoningTitle(isStreaming: item.state == .streaming),
            "Thought"
        )
    }

    func test_liveCompositionKeepsReasoningAndToolsInOneOrderedActivity() {
        // WHY: reasoning and tools share one provider timeline. Splitting them
        // into type buckets lets later thoughts jump above earlier tool work.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "r1", turnId: "t1", type: .reasoning, state: .streaming, body: "hmm", startedAtMs: 1),
                AssistantItem(id: "tool1", turnId: "t1", type: .tool, state: .streaming, summary: "Bash", body: #"{"command":"ls"}"#, startedAtMs: 2),
            ],
            finished: false
        )
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertEqual(composition.activity.map(\.id), ["r1", "tool1"])
        XCTAssertTrue(composition.outside.isEmpty, "live turns keep all activity in append order")
        XCTAssertEqual(AgentChatLiveTurnChrome.completedWorkLabel(turn, live: true, workBlockCount: 2),
                       "Work so far · 2 steps in this turn")
        XCTAssertFalse(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
    }

    func test_liveCompositionPreservesAppendOrder_becauseLateThoughtMustStayAfterPriorWork() {
        // WHY: Grok interleaves reasoning, tools, and progress text. Rendering
        // type-specific buckets moves every later Thought above work that was
        // already visible instead of appending it at the bottom of the turn.
        let turn = AssistantTurnSnapshot(
            turnId: "t-interleaved",
            items: [
                AssistantItem(id: "r1", turnId: "t-interleaved", type: .reasoning, state: .completed, body: "first", startedAtMs: 1, finishedAtMs: 2),
                AssistantItem(id: "tool1", turnId: "t-interleaved", type: .tool, state: .completed, summary: "Bash", startedAtMs: 3, finishedAtMs: 4),
                AssistantItem(id: "progress1", turnId: "t-interleaved", type: .assistantMessage, state: .completed, body: "Still working", startedAtMs: 5, finishedAtMs: 6),
                AssistantItem(id: "r2", turnId: "t-interleaved", type: .reasoning, state: .streaming, body: "next", startedAtMs: 7),
            ],
            finished: false
        )

        let composition = AgentChatLiveTurnChrome.compose(turn)
        let renderedIDs = (composition.activity + composition.outside).map(\.id)

        XCTAssertEqual(
            renderedIDs,
            turn.items.map(\.id),
            "live activity must render in append order instead of hoisting every Thought"
        )
    }

    func test_finalStaysOutsideWork_becauseTheAnswerIsTheChat() {
        // WHY: the finished answer is the chat. It must sit outside Worked,
        // left-aligned as assistant markdown, not buried in the disclosure.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "r1", turnId: "t1", type: .reasoning, state: .completed, body: "thought", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "tool1", turnId: "t1", type: .tool, state: .completed, summary: "Bash", startedAtMs: 2_000, finishedAtMs: 3_000),
            ],
            finalAssistantMessage: "Three failing tests remain.",
            finished: true
        )
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertEqual(composition.activity.map(\.type), [.reasoning, .tool])
        XCTAssertTrue(composition.outside.isEmpty, "final text lives on the turn, not as a duplicate item")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertEqual(AgentChatLiveTurnChrome.completedWorkLabel(turn, live: false, workBlockCount: 2),
                       "Worked for 2s")
    }

    func test_finishedCompositionKeepsProgressInOrderAndRemovesOnlyFinalDuplicate() {
        // WHY: Grok can emit progress prose between thought phases. Finishing
        // the turn must not reclassify every assistantMessage as a final reply.
        let final = "All checks passed."
        let turn = AssistantTurnSnapshot(
            turnId: "t-finished-interleaved",
            items: [
                AssistantItem(id: "r1", turnId: "t-finished-interleaved", type: .reasoning, state: .completed, body: "first", startedAtMs: 1, finishedAtMs: 2),
                AssistantItem(id: "progress", turnId: "t-finished-interleaved", type: .assistantMessage, state: .completed, body: "Running one more check", startedAtMs: 3, finishedAtMs: 4),
                AssistantItem(id: "r2", turnId: "t-finished-interleaved", type: .reasoning, state: .completed, body: "second", startedAtMs: 5, finishedAtMs: 6),
                AssistantItem(id: "final-copy", turnId: "t-finished-interleaved", type: .assistantMessage, state: .completed, body: final, startedAtMs: 7, finishedAtMs: 8),
            ],
            finalAssistantMessage: final,
            finished: true
        )

        let composition = AgentChatLiveTurnChrome.compose(turn)

        XCTAssertEqual(composition.activity.map(\.id), ["r1", "progress", "r2"])
        XCTAssertTrue(composition.outside.isEmpty, "the authoritative turn final paints exactly once")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
    }

    func test_hasStreamingToolsDrivesWorkingPhase_becauseAThinkingPillIsNotEnough() {
        // WHY: composer chrome must follow real timeline items. A hardcoded
        // hasStreamingTools:false always says Thinking even while tools run.
        var timeline = AssistantTimelineState()
        timeline.apply(.turnStarted(turnId: "t1"))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "r1", turnId: "t1", type: .reasoning, state: .streaming, body: "…", startedAtMs: 1
        )))
        XCTAssertFalse(AgentChatLiveTurnChrome.hasStreamingTools(in: timeline))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "tool1", turnId: "t1", type: .tool, state: .streaming, summary: "Bash", startedAtMs: 2
        )))
        XCTAssertTrue(AgentChatLiveTurnChrome.hasStreamingTools(in: timeline))
        XCTAssertTrue(AgentChatLiveTurnChrome.paintsLiveTurnChrome(timeline))
    }

    func test_timelineReplayRestoresThoughtAndWorked_becauseCloseMustNotEraseTheTurn() throws {
        // WHY: stream events persist on the linked thread. Replaying them must
        // rebuild Thought + Worked without starting a second provider run.
        let events: [AssistantEvent] = [
            .turnStarted(turnId: "t1"),
            .itemStarted(item: AssistantItem(
                id: "r1", turnId: "t1", type: .reasoning, state: .streaming, body: "", startedAtMs: 1_000
            )),
            .itemDelta(itemId: "r1", bodyAppend: "Checking the suite", outputAppend: nil, summary: nil),
            .itemCompleted(itemId: "r1", finalState: .completed),
            .itemStarted(item: AssistantItem(
                id: "tool1", turnId: "t1", type: .tool, state: .completed, summary: "Bash",
                body: #"{"command":"swift test"}"#, startedAtMs: 2_000, finishedAtMs: 4_000
            )),
            .turnCompleted(turnId: "t1", finalMessage: "Three failing tests remain."),
        ]
        let timeline = AgentChatLiveTurnChrome.timelineByReplaying(events)
        XCTAssertTrue(AgentChatLiveTurnChrome.paintsLiveTurnChrome(timeline))
        let turn = try XCTUnwrap(timeline.turns.first)
        XCTAssertTrue(turn.finished)
        let reasoning = try XCTUnwrap(turn.items.first { $0.type == .reasoning })
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: reasoning.state == .streaming), "Thought")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(reasoning), "Checking the suite")
        XCTAssertTrue(AgentChatLiveTurnChrome.compose(turn).activity.contains { $0.type == .reasoning })
        XCTAssertTrue(AgentChatLiveTurnChrome.workItems(in: turn).contains { $0.type == .tool })
        XCTAssertEqual(turn.finalAssistantMessage, "Three failing tests remain.")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertEqual(
            AgentChatLiveTurnChrome.completedWorkLabel(turn, live: false, workBlockCount: 1),
            AgentAppView.completedWorkLabel(turn, live: false, workBlockCount: 1)
        )
    }

    func test_replayDoesNotInventWallClockFinish_becauseDeskMustNotGrowWorkedHours() throws {
        // WHY: Bots Desk replays persisted itemCompleted events on every open.
        // apply() used Date() for missing finishedAtMs, so "Worked for 12s"
        // became "Worked for 1230m" and grew each time the user left Studio.
        let start: Int64 = 1_700_000_000_000
        let events: [AssistantEvent] = [
            .turnStarted(turnId: "t1"),
            .itemStarted(item: AssistantItem(
                id: "r1", turnId: "t1", type: .reasoning, state: .streaming,
                body: "hmm", startedAtMs: start
            )),
            .itemCompleted(itemId: "r1", finalState: .completed),
            .itemStarted(item: AssistantItem(
                id: "tool1", turnId: "t1", type: .tool, state: .completed,
                summary: "Bash", startedAtMs: start + 2_000, finishedAtMs: start + 4_000
            )),
            .turnCompleted(turnId: "t1", finalMessage: "done"),
        ]
        let first = AgentChatLiveTurnChrome.timelineByReplaying(events)
        let second = AgentChatLiveTurnChrome.timelineByReplaying(events)
        let firstTurn = try XCTUnwrap(first.turns.first)
        let secondTurn = try XCTUnwrap(second.turns.first)
        let firstReasoning = try XCTUnwrap(firstTurn.items.first { $0.id == "r1" })
        XCTAssertNil(
            firstReasoning.finishedAtMs,
            "replay must not stamp wall-clock now onto a completed item that never recorded a finish"
        )
        XCTAssertNil(
            AgentChatLiveTurnChrome.turnDurationLabel(firstTurn),
            "unknown finish must omit duration instead of now-minus-start"
        )
        XCTAssertEqual(
            AgentChatLiveTurnChrome.completedWorkLabel(firstTurn, live: false, workBlockCount: 1),
            "Worked"
        )
        XCTAssertEqual(
            AgentChatLiveTurnChrome.completedWorkLabel(firstTurn, live: false, workBlockCount: 1),
            AgentChatLiveTurnChrome.completedWorkLabel(secondTurn, live: false, workBlockCount: 1),
            "two replays hours apart must not change the Worked label"
        )
        XCTAssertEqual(
            AgentAppViewModel.timelineByReplaying(events).turns.first?.items.first { $0.id == "r1" }?.finishedAtMs,
            firstReasoning.finishedAtMs,
            "Agent App replay must share the same no-Date() finish rule"
        )
    }

    func test_messageDuplicatesTurnHidesPersistedAnswer_becauseDeskMustNotPaintTheReplyTwice() {
        // WHY: messageRepo stores the assistant row and the live turn stores
        // the same final. Painting both is the duplicate the user reported.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(
                    id: "a1",
                    turnId: "t1",
                    type: .assistantMessage,
                    state: .completed,
                    body: "Oi! Como posso ajudar?",
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
            ],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        XCTAssertTrue(
            AgentChatLiveTurnChrome.messageDuplicatesTurn("Oi! Como posso ajudar?", turns: [turn])
        )
        XCTAssertFalse(
            AgentChatLiveTurnChrome.messageDuplicatesTurn("Qual sua função?", turns: [turn])
        )
    }

    func test_turnSortDatePrefersItemTimestamps_becauseReplayTurnStartedIsNow() {
        // WHY: turnStarted replay stamps startedAtMs with Date(), which stacked
        // every historical Worked row under the latest user bubble.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(
                    id: "r1",
                    turnId: "t1",
                    type: .reasoning,
                    state: .completed,
                    body: "x",
                    startedAtMs: 1_700_000_001_000,
                    finishedAtMs: 1_700_000_002_000
                ),
            ],
            finished: true,
            startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        XCTAssertEqual(
            AgentChatLiveTurnChrome.turnSortDate(turn),
            Date(timeIntervalSince1970: 1_700_000_001),
            "item start must win over the replay wall-clock on turn.startedAtMs"
        )
    }

    func test_laterTurnHidesRepeatedFinal_becauseTwoTurnsMustNotStackTheSameReply() {
        // WHY: a reused Claude session can emit two finished turns with the
        // same greeting. The second Worked row can stay; the second answer cannot.
        let first = AssistantTurnSnapshot(
            turnId: "t1",
            items: [],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        let second = AssistantTurnSnapshot(
            turnId: "t2",
            items: [
                AssistantItem(
                    id: "tool1",
                    turnId: "t2",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
            ],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldHideAssistantOutput(second, previousTurns: [first]))
        XCTAssertFalse(AgentChatLiveTurnChrome.shouldHideAssistantOutput(first, previousTurns: []))
    }

    func test_laterTurnHidesCompactedWhitespaceDuplicate_becauseNormalizedFinalsAreTheSameAnswer() {
        // WHY: exact-set hide uses AgentTranscriptOrder.normalizedFinalText, which
        // strips whitespace. Two turns with the same compact final must still hide.
        let first = AssistantTurnSnapshot(
            turnId: "t-ws-1",
            finalAssistantMessage: "hello world",
            finished: true
        )
        let second = AssistantTurnSnapshot(
            turnId: "t-ws-2",
            finalAssistantMessage: "hello  world",
            finished: true
        )
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldHideAssistantOutput(second, previousTurns: [first]))
    }

    func test_laterTurnDoesNotHideSubstringExpansion_becauseHideIsExactNormalizedMembership() {
        // WHY: the old O(turns² × contains) path treated a longer expansion as
        // a duplicate. Exact membership keeps identical finals hidden and leaves
        // expanded/distinct answers visible.
        let first = AssistantTurnSnapshot(
            turnId: "t-sub-1",
            finalAssistantMessage: "same answer",
            finished: true
        )
        let expanded = AssistantTurnSnapshot(
            turnId: "t-sub-2",
            finalAssistantMessage: "A same answer, expanded",
            finished: true
        )
        XCTAssertFalse(AgentChatLiveTurnChrome.shouldHideAssistantOutput(expanded, previousTurns: [first]))
    }

    func test_isRicherKeepsLiveThoughtAheadOfLaggingPersist_becauseFlushMustNotEraseThinking() {
        // WHY: Desk applies coordinator events immediately. A later SQLite
        // replay that has not flushed the reasoning delta must not wipe the row.
        var live = AssistantTimelineState()
        live.apply(.turnStarted(turnId: "t1"))
        live.apply(.itemStarted(item: AssistantItem(
            id: "r1", turnId: "t1", type: .reasoning, state: .streaming,
            body: "Checking the suite", startedAtMs: 1
        )))
        var persisted = AssistantTimelineState()
        persisted.apply(.turnStarted(turnId: "t1"))
        persisted.apply(.itemStarted(item: AssistantItem(
            id: "r1", turnId: "t1", type: .reasoning, state: .streaming,
            body: "", startedAtMs: 1
        )))
        XCTAssertTrue(AgentChatLiveTurnChrome.isRicher(live, than: persisted))
        XCTAssertFalse(AgentChatLiveTurnChrome.isRicher(persisted, than: live))
    }

    func test_composeKeepsOneAssistantWhenClaudeEmitsStreamAndSnapshot() {
        // WHY: a real Claude Desk turn writes a streaming assistantMessage
        // and then a snapshot item with the same body. Two replies is a lie.
        let answer = "Sou Batatilson da Silva, Gerente de Marketing, e não alterei nenhum arquivo."
        let turn = AssistantTurnSnapshot(
            turnId: "F18B4835-C8AC-4C5B-8D0D-FD8A915CA0EF",
            items: [
                AssistantItem(
                    id: "483520EA-C4E5-471D-A409-1B8501E14F90",
                    turnId: "F18B4835-C8AC-4C5B-8D0D-FD8A915CA0EF",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
                AssistantItem(
                    id: "793AAE89-A3B1-4F24-962E-A5D76186A18E",
                    turnId: "F18B4835-C8AC-4C5B-8D0D-FD8A915CA0EF",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 2,
                    finishedAtMs: 3
                ),
            ],
            finalAssistantMessage: answer,
            finished: true
        )
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertTrue(
            composition.outside.isEmpty,
            "assistant items that match the turn final must not paint beside it"
        )
        XCTAssertTrue(
            AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn),
            "the turn final is the single chat answer after Work so far"
        )
    }

    func test_workThenMatchingItemAndFinalPaintsAnswerOnce() {
        // WHY: Agent App showed Ran N commands, then the same paragraph twice —
        // live assistant item plus turn final (and often a persisted copy).
        let answer = "Confirmed all three blockers in code."
        let turn = AssistantTurnSnapshot(
            turnId: "t-dup",
            items: [
                AssistantItem(
                    id: "cmd-1",
                    turnId: "t-dup",
                    type: .commandExecution,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
                AssistantItem(
                    id: "msg-1",
                    turnId: "t-dup",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 3,
                    finishedAtMs: 4
                ),
            ],
            finalAssistantMessage: answer,
            finished: true
        )
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertEqual(composition.activity.map(\.id), ["cmd-1"])
        XCTAssertTrue(composition.outside.isEmpty)
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertTrue(AgentChatLiveTurnChrome.messageDuplicatesTurn(answer, turns: [turn]))
    }

    /// WHY: screenshot class — live Thinking… body hugged its unwrapped width,
    /// then AppKit wrapped at the column and drew extra lines over "Working for".
    /// Column-filling reasoning must pin maxWidth so sizeThatFits gets the column.
    func test_reasoningPlainTextPinsToColumnWidth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chrome = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentChatLiveTurnChrome.swift"),
            encoding: .utf8
        )
        let marker = try XCTUnwrap(chrome.range(of: "public struct AgentChatReasoningRow"))
        let rest = chrome[marker.lowerBound...]
        let end = rest.range(of: "\n// MARK: - Tool rows")?.lowerBound ?? rest.endIndex
        let chunk = String(chrome[marker.lowerBound..<end])
        XCTAssertTrue(chunk.contains("AgentSelectablePlainText("))
        XCTAssertTrue(
            chunk.contains("lineSpacing: 3\n                )\n                .frame(maxWidth: .infinity, alignment: .leading)"),
            "Thinking… body must take the chat column, not hug one long line"
        )

        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let row = try XCTUnwrap(app.range(of: "private func reasoningRow(_ item: AssistantItem)"))
        let rowRest = app[row.lowerBound...]
        let rowEnd = rowRest.range(of: "\n    private func reasoningText")?.lowerBound ?? rowRest.endIndex
        let rowChunk = String(app[row.lowerBound..<rowEnd])
        XCTAssertTrue(rowChunk.contains("AgentSelectablePlainText("))
        XCTAssertTrue(
            rowChunk.contains("lineSpacing: 3\n                )\n                .frame(maxWidth: .infinity, alignment: .leading)"),
            "Agent App reasoningRow must pin the same column width as live-turn chrome"
        )
    }

    func test_elapsedTickSchedule_lowFrequencyPinsThe5sCadence() {
        // WHY (perf CH-12): TimelineView keeps ticking while its window is
        // occluded or minimized; several live working strips at a forced 1s
        // cadence were a steady idle wake-up source. lowFrequency (which
        // SwiftUI passes for non-visible views) must fall back to 5s.
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = AgentChatElapsedTickSchedule(start: start)
        let early = start.addingTimeInterval(10)

        var regular = schedule.entries(from: early, mode: .normal)
        XCTAssertEqual(regular.next()?.timeIntervalSince(early), 0)
        XCTAssertEqual(regular.next()?.timeIntervalSince(early), 1,
                       "a visible strip inside the first minute ticks every second")

        var lowFrequency = schedule.entries(from: early, mode: .lowFrequency)
        XCTAssertEqual(lowFrequency.next()?.timeIntervalSince(early), 0)
        XCTAssertEqual(lowFrequency.next()?.timeIntervalSince(early), 5,
                       "an occluded/minimized strip must not tick every second")
    }

    func test_agentAppElapsedTickSchedule_lowFrequencyPinsThe5sCadence() {
        // WHY: Agent App's private duplicate used to ignore TimelineScheduleMode
        // and keep 1 Hz tool clocks while occluded. It must match Desk.
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = ElapsedTickSchedule(start: start)
        let early = start.addingTimeInterval(10)

        var regular = schedule.entries(from: early, mode: .normal)
        XCTAssertEqual(regular.next()?.timeIntervalSince(early), 0)
        XCTAssertEqual(regular.next()?.timeIntervalSince(early), 1)

        var lowFrequency = schedule.entries(from: early, mode: .lowFrequency)
        XCTAssertEqual(lowFrequency.next()?.timeIntervalSince(early), 0)
        XCTAssertEqual(
            lowFrequency.next()?.timeIntervalSince(early),
            5,
            "Agent App ElapsedTickSchedule lowFrequency first step must be 5s"
        )
    }

    func test_shouldRenderFinalMessage_reusesComposition() {
        // WHY (CH-05): body used to compose(turn) twice per paint with
        // contains O(k²). Passing the already-built composition must match.
        var turn = AssistantTurnSnapshot(turnId: "t-final")
        turn.finished = true
        turn.finalAssistantMessage = "Hello"
        turn.items = [
            AssistantItem(
                id: "a1",
                turnId: "t-final",
                type: .assistantMessage,
                state: .completed,
                body: "Hello",
                startedAtMs: 1
            )
        ]
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertEqual(
            AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn),
            AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn, composition: composition)
        )
    }

    func test_liveTurnView_equatableIgnoresNewClosuresWhenValuesMatch() {
        // WHY (CH-01): historical rows carry AnyView/closures; Equatable must
        // skip body when value fields are unchanged.
        let turn = AssistantTurnSnapshot(turnId: "t-eq")
        let a = AgentChatLiveTurnView(turn: turn, live: false, hideAssistantOutput: false)
        let b = AgentChatLiveTurnView(turn: turn, live: false, hideAssistantOutput: false)
        XCTAssertEqual(a, b)
        let c = AgentChatLiveTurnView(turn: turn, live: true, hideAssistantOutput: false)
        XCTAssertNotEqual(a, c)
    }

    func test_liveThought_latestReasoningWinsOverEarlierOne() {
        // WHY: the line must show what the model thinks now; an older thought
        // left on screen reads as stale progress.
        let turn = AssistantTurnSnapshot(turnId: "t", items: [
            reasoning("r1", "Old plan"),
            tool("c1", state: .completed),
            reasoning("r2", "New plan")
        ])
        XCTAssertEqual(AgentChatLiveTurnChrome.liveThought(turn), "New plan")
    }

    func test_liveThought_persistsWhileToolRunsAfterIt() {
        // WHY: the thought stays while a tool runs; it clears only when the
        // next thought or the answer replaces it.
        let turn = AssistantTurnSnapshot(turnId: "t", items: [
            reasoning("r1", "Checking the build"),
            tool("c1", state: .streaming)
        ])
        XCTAssertEqual(AgentChatLiveTurnChrome.liveThought(turn), "Checking the build")
    }

    func test_liveThought_hiddenOnceAnswerStarts() {
        // WHY: once the answer is being written, a thought line above it would
        // duplicate reasoning the user is already reading.
        let turn = AssistantTurnSnapshot(turnId: "t", items: [
            reasoning("r1", "Thinking it through"),
            AssistantItem(id: "m1", turnId: "t", type: .assistantMessage, state: .streaming, body: "Answer", startedAtMs: 3)
        ])
        XCTAssertNil(AgentChatLiveTurnChrome.liveThought(turn))
    }

    func test_liveThought_keepsLastThreeLinesWithBoldStrippedAndCapsLength() {
        // WHY: the line is a fixed-height tail; full reasoning bodies would
        // grow the transcript on every token.
        let six = (1...6).map { "line \($0)" }.joined(separator: "\n")
        let shortTail = AgentChatLiveTurnChrome.liveThought(
            AssistantTurnSnapshot(turnId: "t", items: [reasoning("r1", six)])
        )
        XCTAssertEqual(shortTail, "line 4\nline 5\nline 6")

        let bold = AgentChatLiveTurnChrome.liveThought(
            AssistantTurnSnapshot(turnId: "t", items: [reasoning("r2", "**Plan** ok")])
        )
        XCTAssertEqual(bold, "Plan ok", "markdown bold markers must not reach the user")

        let long = AgentChatLiveTurnChrome.liveThought(
            AssistantTurnSnapshot(turnId: "t", items: [reasoning("r3", String(repeating: "x", count: 1000))])
        )
        XCTAssertNotNil(long)
        XCTAssertLessThanOrEqual(long?.count ?? .max, 281, "cap keeps the line bounded")
        XCTAssertTrue(long?.hasPrefix("…") ?? false, "a cut tail is marked with an ellipsis")
    }

    func test_liveThought_nilWithoutReasoningOrText() {
        // WHY: no provider reasoning means Simple mode must not invent thoughts.
        XCTAssertNil(AgentChatLiveTurnChrome.liveThought(AssistantTurnSnapshot(turnId: "t", items: [tool("c1", state: .streaming)])))
        XCTAssertNil(AgentChatLiveTurnChrome.liveThought(AssistantTurnSnapshot(turnId: "t", items: [reasoning("r1", "  \n ")])))
    }

    func test_simpleLiveActivityShowsThinkingAndSafeToolStatusWithoutWorkingDuplicate() {
        // WHY: Simple users need actual thought and tool progress, but must not see command inputs or duplicate placeholders.
        let toolItem = tool("c1", state: .streaming)
        let turn = AssistantTurnSnapshot(turnId: "t", items: [reasoning("r1", "Checking the fix"), toolItem])
        XCTAssertEqual(AgentChatLiveTurnChrome.liveThought(turn), "Checking the fix")
        XCTAssertEqual(AgentChatLiveTurnChrome.liveToolActivity(turn), "Command activity")
        XCTAssertNotEqual(AgentChatLiveTurnChrome.liveToolActivity(turn), "ls")
        let privateInput = AssistantItem(id: "private", turnId: "t", type: .commandExecution, state: .streaming,
                                         body: #"{"command":"cat /Users/private/secret.txt"}"#, startedAtMs: 4)
        XCTAssertEqual(AgentChatLiveTurnChrome.liveToolActivity(
            AssistantTurnSnapshot(turnId: "t", items: [privateInput])
        ), "Command activity")

        var completed = turn
        completed.finished = true
        XCTAssertNil(AgentChatLiveTurnChrome.liveThought(completed))
        XCTAssertNil(AgentChatLiveTurnChrome.liveToolActivity(completed), "finished turn must not show stale streaming item")

        let answering = AssistantTurnSnapshot(turnId: "t", items: [
            toolItem,
            AssistantItem(id: "a", turnId: "t", type: .assistantMessage, state: .streaming, body: "Answer", startedAtMs: 3)
        ])
        XCTAssertNil(AgentChatLiveTurnChrome.liveThought(answering), "assistant response replaces thinking")
        XCTAssertNil(AgentChatLiveTurnChrome.liveToolActivity(answering), "assistant response replaces prior tool activity")
    }

    @MainActor
    func test_simpleToolStatusRendersOffscreenAsNativeSwiftUIView() throws {
        // WHY: behavior tests must verify the actual SwiftUI status view renders without launching a GUI.
        let view = AgentChatHiddenWorkStatus(
            turn: AssistantTurnSnapshot(turnId: "render"),
            label: "Image activity"
        ).frame(width: 280, height: 36)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func test_liveTurnEquatableTracksCurrentSimpleToolActivityAndTransitions() {
        let first = AssistantTurnSnapshot(turnId: "t", items: [tool("c1", state: .streaming)])
        var changed = first
        changed.items[0].type = .webSearch
        let firstView = AgentChatLiveTurnView(turn: first, live: true, hidesWork: true)
        let changedView = AgentChatLiveTurnView(turn: changed, live: true, hidesWork: true)
        XCTAssertEqual(AgentChatLiveTurnChrome.liveToolActivity(first), "Command activity")
        XCTAssertEqual(AgentChatLiveTurnChrome.liveToolActivity(changed), "Web search activity")
        XCTAssertNotEqual(firstView, changedView, "changed visible activity must invalidate Equatable row")

        var completed = first
        completed.items[0].state = .completed
        XCTAssertNotEqual(firstView, AgentChatLiveTurnView(turn: completed, live: true, hidesWork: true))
        XCTAssertNil(AgentChatLiveTurnChrome.liveToolActivity(completed))
    }

    private func reasoning(_ id: String, _ body: String) -> AssistantItem {
        AssistantItem(id: id, turnId: "t", type: .reasoning, state: .streaming, body: body, startedAtMs: 1)
    }

    private func tool(_ id: String, state: AssistantItemState) -> AssistantItem {
        AssistantItem(id: id, turnId: "t", type: .commandExecution, state: state, body: "ls", startedAtMs: 2)
    }

    func test_toolGroupSummary_isMemoizedByMemberIdentity() {
        let items = [
            AssistantItem(id: "c1", turnId: "t", type: .commandExecution, state: .completed, body: "ls", startedAtMs: 1),
            AssistantItem(id: "c2", turnId: "t", type: .commandExecution, state: .completed, body: "pwd", startedAtMs: 2)
        ]
        let first = AgentChatLiveTurnChrome.toolGroupSummary(items)
        let second = AgentChatLiveTurnChrome.toolGroupSummary(items)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    /// Real Distill ACP `session/update` lines 0...9 from a live shell run
    /// (text trimmed). Line 9 is an open shell tool_call with no completion.
    func test_realDistillShellToolCallStaysRunningThroughProductionMapperAndReducer() throws {
        let fixture = #"""
[{"timestamp":1793030590,"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Run exactly this shell command and nothi"}}},{"timestamp":1793030592,"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The user wants me to execute a specific "}}},{"timestamp":1793030593,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I run command.\n\n"}}},{"timestamp":1793030593,"update":{"sessionUpdate":"tool_call","toolCallId":"chatcmpl-tool-a11f48140a1ef273","title":"run_terminal_command","rawInput":{"command":"\"for i in $(seq 1 40); do echo line-$i; sleep 1; done\"","description":"\"Run user requested loop to print lines 1-40 with a 1-second delay between each print.\""}}},{"timestamp":1793030593,"update":{"sessionUpdate":"tool_call_update","toolCallId":"chatcmpl-tool-a11f48140a1ef273","kind":"execute","title":"Execute `\"for i in $(seq 1 40); do echo line-$i; sleep 1; done\"`","content":[{"type":"content","content":{"type":"text","text":"\"Run user requested loop to print lines "}}],"locations":[],"rawInput":{"variant":"Bash","command":"\"for i in $(seq 1 40); do echo line-$i; sleep 1; done\"","description":"\"Run user requested loop to print lines 1-40 with a 1-second delay between each print.\"","is_background":false}}},{"timestamp":1793030596,"update":{"sessionUpdate":"tool_call_update","toolCallId":"chatcmpl-tool-a11f48140a1ef273","status":"completed","content":[{"type":"content","content":{"type":"text","text":"(eval):1: command not found: for i in 1\\"}}],"rawOutput":{"type":"Bash","output":[40,101,118,97,108,41,58,49,58,32,99,111,109,109,97,110,100,32,110,111,116,32,102,111,117,110,100,58,32,102,111,114,32,105,32,105,110,32,49,92,110,50,92,110,51,92,110,52,92,110,53,92,110,54,92,110,55,92,110,56,92,110,57,92,110,49,48,92,110,49,49,92,110,49,50,92,110,49,51,92,110,49,52,92,110,49,53,92,110,49,54,92,110,49,55,92,110,49,56,92,110,49,57,92,110,50,48,92,110,50,49,92,110,50,50,92,110,50,51,92,110,50,52,92,110,50,53,92,110,50,54,92,110,50,55,92,110,50,56,92,110,50,57,92,110,51,48,92,110,51,49,92,110,51,50,92,110,51,51,92,110,51,52,92,110,51,53,92,110,51,54,92,110,51,55,92,110,51,56,92,110,51,57,92,110,52,48,59,32,100,111,32,101,99,104,111,32,108,105,110,101,45,59,32,115,108,101,101,112,32,49,59,32,100,111,110,101,10],"output_for_prompt":"exit: 127\n(eval):1: command not found: for i in 1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n9\\n10\\n11\\n12\\n13\\n14\\n15\\n16\\n17\\n18\\n19\\n20\\n21\\n22\\n23\\n24\\n25\\n26\\n27\\n28\\n29\\n30\\n31\\n32\\n33\\n34\\n35\\n36\\n37\\n38\\n39\\n40; do echo line-; sleep 1; done\n","exit_code":127,"command":"\"for i in $(seq 1 40); do echo line-$i; sleep 1; done\"","truncated":false,"signal":null,"timed_out":false,"description":"\"Run user requested loop to print lines 1-40 with a 1-second delay between each print.\"","current_dir":"/var/folders/wp/st3y6js14rs708k9pgyxr7jr0000gn/T/grok-goal-26c32b2cbb4c/implementer/pr32/scratch","output_file":"/Users/samuelfajreldines/dev/remote-code/macos-app/.sandbox-worktrees/20261026T125736Z/.sandbox-state/home/.distill/sessions/%2Fvar%2Ffolders%2Fwp%2Fst3y6js14rs708k9pgyxr7jr0000gn%2FT%2Fgrok-goal-26c32b2cbb4c%2Fimplementer%2Fpr32%2Fscratch/01a178f3-8c12-7173-b3d7-859c527d1160/terminal/chatcmpl-tool-a11f48140a1ef273.log","total_bytes":218}}},{"timestamp":1793030600,"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The user wanted me to run the command `f"}}},{"timestamp":1793030603,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Command execution failed. Error message "}}},{"timestamp":1793030606,"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The user asked me to run a specific shel"}}},{"timestamp":1793030606,"update":{"sessionUpdate":"tool_call","toolCallId":"chatcmpl-tool-8110ff6e67b184a9","title":"run_terminal_command","rawInput":{"command":"zsh -c 'for i in $(seq 1 40); do echo line-$i; sleep 1; done'","description":"Execute the user requested shell loop command using zsh to ensure proper shell syntax interpretation."}}}]
"""#
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 10)
        let runStartedAt = Date(timeIntervalSince1970: TimeInterval(rows[0]["timestamp"] as? Int ?? 0))
        let mapper = DistillACPEventMapper(sessionId: "s")
        var timeline = AssistantTimelineState()
        for event in mapper.beginTurn() { timeline.apply(event) }
        for row in rows {
            let update = try XCTUnwrap(row["update"] as? [String: Any])
            for event in mapper.consumeSessionUpdate(update) { timeline.apply(event) }
        }
        let turn = try XCTUnwrap(timeline.turns.last)
        let shell = try XCTUnwrap(turn.items.first { $0.id == "chatcmpl-tool-8110ff6e67b184a9" })
        XCTAssertFalse(turn.finished, "turn must still be open while the shell runs")
        XCTAssertEqual(shell.state, .streaming)
        XCTAssertEqual(shell.type, .tool)
        XCTAssertGreaterThanOrEqual(Double(shell.startedAtMs), floor(runStartedAt.timeIntervalSince1970 * 1_000),
                                    "shell item must not predate the run start")
        XCTAssertEqual(AgentChatLiveTurnChrome.runningTools(in: timeline.turns, since: runStartedAt).map(\.id),
                       ["chatcmpl-tool-8110ff6e67b184a9"])
    }

    func test_recentToolOutputShowsLatestDistillPromptTextNotRawToolJSON() throws {
        let snapshots = ["line-1\n", "line-1\nline-2\n", "line-1\nline-2\nline-3\n", "line-1\nline-2\nline-3\nline-4\n"]
        let item = try distillShellItem(snapshots.map { ["sessionUpdate": "tool_call_update", "toolCallId": "shell", "rawOutput": distillBashRawOutput($0)] })
        XCTAssertEqual(AgentChatLiveTurnChrome.recentToolOutput(item), "line-1\nline-2\nline-3\nline-4\n",
                       "the panel must show the command text from the newest snapshot, not concatenated JSON or byte arrays")
    }

    func test_recentToolOutputReadsTaskOutputResultOutput() throws {
        let result: [String: Any] = ["type": "TaskOutput", "Result": ["task_id": "x", "command": "loop", "status": "completed",
                                                                     "exit_code": 0, "output": "line-1\nline-2\n",
                                                                     "output_file": "/x.log", "truncated": false]]
        let item = try distillShellItem([["sessionUpdate": "tool_call_update", "toolCallId": "shell", "rawOutput": result]])
        XCTAssertEqual(AgentChatLiveTurnChrome.recentToolOutput(item), "line-1\nline-2\n")
    }

    func test_recentToolOutputKeepsPlainTextOutputUnchanged() throws {
        let plain: [String: Any] = ["sessionUpdate": "tool_call_update", "toolCallId": "shell",
                                    "content": [["type": "content", "content": ["type": "text", "text": "hello\nworld"]]]]
        let item = try distillShellItem([plain])
        XCTAssertEqual(AgentChatLiveTurnChrome.recentToolOutput(item), "hello\nworld",
                       "non-Distill providers emit plain text and must not be reinterpreted as JSON")
    }

    func test_recentToolOutputSuffixesReadableDistillTextToLast2000Characters() throws {
        let prompt = String(repeating: "old\n", count: 1_000) + "tail line\n"
        let item = try distillShellItem([["sessionUpdate": "tool_call_update", "toolCallId": "shell",
                                          "rawOutput": distillBashRawOutput(prompt)]])
        let tail = try XCTUnwrap(AgentChatLiveTurnChrome.recentToolOutput(item))
        XCTAssertEqual(tail.count, 2_000)
        XCTAssertTrue(tail.hasSuffix("tail line\n"))
        XCTAssertFalse(tail.contains("output_for_prompt"), "bounded readable output must not carry tool JSON keys")
    }

    func test_recentToolOutputTreatsEmptyDistillPromptTextAsNoOutput() throws {
        let item = try distillShellItem([["sessionUpdate": "tool_call_update", "toolCallId": "shell",
                                          "rawOutput": distillBashRawOutput("")]])
        XCTAssertNil(AgentChatLiveTurnChrome.recentToolOutput(item),
                     "empty command text must fall back to the quiet-command copy")
    }

    private func distillShellItem(_ updates: [[String: Any]]) throws -> AssistantItem {
        let mapper = DistillACPEventMapper(sessionId: "s")
        var timeline = AssistantTimelineState()
        for event in mapper.beginTurn() { timeline.apply(event) }
        let start: [String: Any] = ["sessionUpdate": "tool_call", "toolCallId": "shell",
                                    "title": "run_terminal_command", "rawInput": ["command": "loop"]]
        for update in [start] + updates {
            for event in mapper.consumeSessionUpdate(update) { timeline.apply(event) }
        }
        return try XCTUnwrap(timeline.turns.last?.items.first { $0.id == "shell" })
    }

    /// Shape of a Distill Bash rawOutput: byte array in `output`, readable text in `output_for_prompt`.
    private func distillBashRawOutput(_ prompt: String) -> [String: Any] {
        ["type": "Bash", "output": prompt.utf8.map { Int($0) }, "output_for_prompt": prompt,
         "exit_code": 0, "command": "loop", "truncated": false, "signal": NSNull(),
         "timed_out": false, "total_bytes": prompt.utf8.count]
    }
}
