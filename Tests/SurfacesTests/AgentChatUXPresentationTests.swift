import XCTest
import CoreModel
@testable import Surfaces

final class AgentChatUXPresentationTests: XCTestCase {

    // MARK: System strip

    func test_systemStrip_collapse_ordersErrorBeforeInfo_andCapsVisible() {
        let items = [
            AgentSystemStripItem(id: "info", severity: .info, message: "replay"),
            AgentSystemStripItem(id: "err", severity: .error, message: "send failed"),
            AgentSystemStripItem(id: "warn", severity: .warning, message: "stale snapshot"),
            AgentSystemStripItem(id: "q", severity: .warning, message: "queue issue")
        ]
        let result = AgentSystemStripPresentation.collapse(items, maxVisible: 2)
        XCTAssertEqual(result.visible.map(\.id), ["err", "warn"])
        XCTAssertEqual(result.overflowCount, 2)
        // WHY: errors must surface first so recovery is not buried under info banners.
        XCTAssertEqual(result.visible.first?.severity, .error)
    }

    func test_systemStrip_items_skipsEmpty_andClassifiesFailures() {
        let items = AgentSystemStripPresentation.items(
            historyReplayNotice: "  ",
            statusMessage: "Run failed: timeout",
            providerSnapshotStatus: "Snapshot stale",
            standaloneQueueStatus: nil
        )
        XCTAssertEqual(items.map(\.id), ["agent.status.message", "agent.provider.snapshot.stale"])
        XCTAssertEqual(items[0].severity, .error)
        XCTAssertTrue(items[1].offersRetry)
    }

    func test_systemStrip_similarWorkIsADismissibleInfoRowBelowErrors() {
        let items = AgentSystemStripPresentation.items(
            historyReplayNotice: nil, statusMessage: "Run failed", providerSnapshotStatus: nil,
            standaloneQueueStatus: nil, similarWork: "Similar work already exists: “Fix login”."
        )
        let similar = items.first { $0.id == "agent.similar.work" }
        XCTAssertEqual(similar?.severity, .info)
        XCTAssertEqual(similar?.offersDismiss, true)
        XCTAssertEqual(AgentSystemStripPresentation.collapse(items, maxVisible: 1).visible.map(\.id), ["agent.status.message"], "a similar-work hint never pushes out an error")
        XCTAssertFalse(AgentSystemStripPresentation.items(historyReplayNotice: nil, statusMessage: nil, providerSnapshotStatus: nil, standaloneQueueStatus: nil).contains { $0.id == "agent.similar.work" })
    }

    func test_similarWorkNoticeNamesUpToThreeThreadsAndIsEmptyWithoutAny() {
        func work(_ title: String) -> SimilarWork {
            SimilarWork(threadID: AgentThreadID(), threadTitle: title, isRunning: true, finishedAt: nil, files: [], resultSummary: nil, score: 1)
        }
        let saved = AppLocalization.setting
        defer { AppLocalization.setting = saved }
        AppLocalization.setting = "en"
        XCTAssertNil(AgentAppViewModel.similarWorkNoticeText([]))
        let text = AgentAppViewModel.similarWorkNoticeText([work("A"), work("B  \n b"), work("C"), work("D")])
        XCTAssertEqual(text, "Similar work already exists: “A”, “B b”, “C”. Check it before repeating it.")
    }

    func test_similarWorkNoticeRendersTranslatedInEveryLanguage() {
        let saved = AppLocalization.setting
        defer { AppLocalization.setting = saved }
        let work = [SimilarWork(threadID: AgentThreadID(), threadTitle: "Fix login", isRunning: true, finishedAt: nil, files: [], resultSummary: nil, score: 1)]
        for language in AppLanguage.allCases where language != .en {
            AppLocalization.setting = language.rawValue
            let text = AgentAppViewModel.similarWorkNoticeText(work) ?? ""
            XCTAssertTrue(text.contains("“Fix login”"), "\(language.rawValue): \(text)")
            XCTAssertFalse(text.contains("Similar work"), "\(language.rawValue) fell back to English: \(text)")
            XCTAssertFalse(text.contains("%1$@"), text)
        }
    }

    // MARK: Working strip

    func test_workingPhase_prefersAwaitingOverTools() {
        let phase = AgentWorkingStripPresentation.phase(
            runIsLive: true,
            isAwaitingBackground: true,
            backgroundShellCount: 0,
            activeSubagentCount: 2,
            hasStreamingTools: true
        )
        XCTAssertEqual(phase, .awaitingBackground)
    }

    func test_workingLabel_includesElapsed() {
        let label = AgentWorkingStripPresentation.label(phase: .thinking, elapsedSeconds: 95)
        XCTAssertEqual(label, "Thinking · 1m 35s")
        XCTAssertNil(AgentWorkingStripPresentation.label(phase: .idle, elapsedSeconds: 10))
    }

    func test_workingLabel_namesTheShellHoldingStopInsteadOfGenericAwaiting() {
        // WHY: "Awaiting · 3h 36m" hid a sticky local_bash (Wait for CI). The
        // pill must name the CLI task so Stop is diagnosable without expanding
        // work logs.
        let hold = AgentBackgroundHoldSummary(tasks: [
            AgentBackgroundTask(id: "T1", kind: .shell, description: "Wait for CI")
        ])
        XCTAssertEqual(
            AgentWorkingStripPresentation.label(
                phase: .awaitingBackground,
                elapsedSeconds: 3 * 3600 + 36 * 60,
                hold: hold
            ),
            "1 shell — Wait for CI · 3h 36m"
        )
        XCTAssertEqual(
            AgentWorkingStripPresentation.label(phase: .awaitingBackground, elapsedSeconds: 12),
            "Awaiting · 12s",
            "completed-awaiting (no live CLI tasks) keeps the generic pill"
        )
    }

    func test_holdSummary_nounAndPrimaryDescriptionRules() {
        let ci = AgentBackgroundTask(id: "T1", kind: .shell, description: "Wait for CI")
        let record = AgentBackgroundTask(id: "T2", kind: .shell, description: "Playwright record")
        let agent = AgentBackgroundTask(id: "A1", kind: .agent, description: "Review PR")
        XCTAssertEqual(AgentBackgroundHoldSummary(tasks: [ci]).pillBase, "1 shell — Wait for CI")
        XCTAssertEqual(AgentBackgroundHoldSummary(tasks: [ci]).holdingHeadline, "Holding: 1 shell — Wait for CI")
        XCTAssertEqual(
            AgentBackgroundHoldSummary(tasks: [ci, record]).pillBase,
            "2 shells",
            "two descriptions must not pick one title as if it were the only job"
        )
        XCTAssertEqual(
            AgentBackgroundHoldSummary(tasks: [ci, record]).extraDescriptionsLine,
            "Wait for CI · Playwright record"
        )
        XCTAssertEqual(
            AgentBackgroundHoldSummary(tasks: [ci, AgentBackgroundTask(id: "T3", kind: .shell)]).pillBase,
            "2 shells",
            "one known title must not be attributed to an aggregate with another untitled task"
        )
        XCTAssertEqual(AgentBackgroundHoldSummary(tasks: [ci, agent]).nounLabel, "1 shell · 1 agent")
        XCTAssertEqual(
            AgentBackgroundHoldSummary(tasks: [
                AgentBackgroundTask(id: "old", kind: .unknown)
            ]).nounLabel,
            "1 shell",
            "id-only snapshots keep Claude CLI '1 shell' wording"
        )
    }

    func test_workingCopy_holdBeatsCatRotation() {
        let hold = AgentBackgroundHoldSummary(tasks: [
            AgentBackgroundTask(id: "T1", kind: .shell, description: "Wait for CI")
        ])
        XCTAssertEqual(
            AgentChatWorkingCopy.statusLabel(
                context: nil,
                elapsedSeconds: 95,
                seed: 42,
                hold: hold
            ),
            "Holding: 1 shell — Wait for CI · 1m 35s"
        )
        XCTAssertEqual(
            AgentChatWorkingCopy.accessibilityLabel(
                context: nil,
                elapsedSeconds: 95,
                hold: hold
            ),
            "Holding: 1 shell — Wait for CI · 1m 35s"
        )
        XCTAssertNotEqual(
            AgentChatWorkingCopy.statusLabel(context: nil, elapsedSeconds: 95, seed: 42, hold: hold),
            AgentWorkingCatCopy.statusLabel(elapsedSeconds: 95, seed: 42),
            "a named shell must not hide behind rotating cat copy"
        )
    }

    func test_peerActivityCopyNamesWaitingBotAndWork() {
        let waiting = BotPeerActivitySnapshot(
            phase: .waiting,
            name: "Quinn",
            title: "CRM Controller",
            handle: "quinn"
        )
        XCTAssertEqual(AgentPeerActivityPresentation.title(for: waiting), "Waiting for Quinn")
        XCTAssertEqual(
            AgentPeerActivityPresentation.detail(for: waiting, elapsedSeconds: 95),
            "Quinn is working for 1m 35s"
        )

        let attention = BotPeerActivitySnapshot(
            phase: .needsAttention,
            name: "Quinn",
            title: "CRM Controller",
            handle: "quinn"
        )
        XCTAssertEqual(AgentPeerActivityPresentation.title(for: attention), "Quinn could not reply")
        XCTAssertEqual(
            AgentPeerActivityPresentation.detail(for: attention, elapsedSeconds: 95),
            "The run stopped. Send a new instruction to retry the handoff."
        )
    }

    func test_contextualWorkingCopyNamesAgentAndReviewedPeer() {
        XCTAssertEqual(
            AgentChatWorkingCopy.statusLabel(context: nil, elapsedSeconds: 95, seed: 42),
            AgentWorkingCatCopy.statusLabel(elapsedSeconds: 95, seed: 42),
            "ordinary runs must retain the existing rotating cat copy"
        )
        XCTAssertEqual(
            AgentChatWorkingCopy.accessibilityLabel(context: nil, elapsedSeconds: 95),
            AgentWorkingCatCopy.accessibilityLabel(elapsedSeconds: 95),
            "ordinary runs must retain the existing stable accessibility copy"
        )
        XCTAssertEqual(
            AgentChatWorkingCopy.statusLabel(
                context: .agent(name: "Quinn"),
                elapsedSeconds: 95,
                seed: 42
            ),
            "Quinn is working for 1m 35s"
        )
        XCTAssertEqual(
            AgentChatWorkingCopy.statusLabel(
                context: .reviewing(peerName: "Quinn"),
                elapsedSeconds: 95,
                seed: 42
            ),
            "Reviewing Quinn's reply for 1m 35s"
        )
        XCTAssertEqual(
            AgentChatWorkingCopy.accessibilityLabel(
                context: .reviewing(peerName: "Quinn"),
                elapsedSeconds: 95
            ),
            "Reviewing Quinn's reply for 1m 35s"
        )
    }

    func test_workingCatCopy_hasOneHundredEnglishActivities() {
        // WHY: product asks for 100 kitten activities rotating every 15s.
        XCTAssertEqual(AgentWorkingCatCopy.activities.count, 100)
        XCTAssertEqual(Set(AgentWorkingCatCopy.activities).count, 100,
                       "activities must be unique so rotation does not feel stuck")
        XCTAssertEqual(AgentWorkingCatCopy.rotationSeconds, 15)
        XCTAssertTrue(
            AgentWorkingCatCopy.activities.allSatisfy {
                !$0.isEmpty && $0.unicodeScalars.allSatisfy(\.isASCII)
            },
            "all phrases stay English ASCII for the strip"
        )
    }

    func test_workingCatCopy_firstWindowIsWorkingThenRandomStable() {
        // WHY: first status is always Working; later windows are random but
        // stable within the 15s slot (no flicker on TimelineView ticks).
        XCTAssertEqual(AgentWorkingCatCopy.activity(elapsedSeconds: 0, seed: 42), "Working")
        XCTAssertEqual(AgentWorkingCatCopy.activity(elapsedSeconds: 14, seed: 42), "Working")
        let at15 = AgentWorkingCatCopy.activity(elapsedSeconds: 15, seed: 42)
        let at29 = AgentWorkingCatCopy.activity(elapsedSeconds: 29, seed: 42)
        XCTAssertEqual(at15, at29, "same 15s window must not reshuffle mid-window")
        XCTAssertNotEqual(at15, "Working", "after the first window, pick from the cat pool")
        XCTAssertTrue(AgentWorkingCatCopy.activities.contains(at15))
        // Different seeds (different runs) should usually diverge after Working.
        let other = AgentWorkingCatCopy.activity(elapsedSeconds: 15, seed: 99)
        XCTAssertNotEqual(at15, "Working")
        XCTAssertTrue(AgentWorkingCatCopy.activities.contains(other))
        XCTAssertEqual(
            AgentWorkingCatCopy.statusLabel(elapsedSeconds: 95, seed: 42),
            "\(AgentWorkingCatCopy.activity(elapsedSeconds: 95, seed: 42)) for 1m 35s"
        )
        XCTAssertEqual(
            AgentWorkingCatCopy.accessibilityLabel(elapsedSeconds: 95),
            "Working for 1m 35s",
            "VoiceOver / UITests keep a stable Working-for label"
        )
    }

    // MARK: Composer chrome

    func test_composerChrome_simpleHidesPermissionAndSource() {
        XCTAssertTrue(AgentComposerChromePresentation.shows(.model, mode: .simple))
        XCTAssertTrue(AgentComposerChromePresentation.shows(.sendStop, mode: .simple))
        XCTAssertFalse(AgentComposerChromePresentation.shows(.permission, mode: .simple))
        XCTAssertFalse(AgentComposerChromePresentation.shows(.source, mode: .simple))
        XCTAssertTrue(AgentComposerChromePresentation.shows(.permission, mode: .power))
        // WHY: Simple mode must keep send reachable while parking advanced identity/safety chrome.
    }

    // MARK: Completed work perf gate

    func test_completedWork_shouldBuildBlocks_onlyWhenExpanded() {
        XCTAssertFalse(AgentCompletedWorkPresentation.shouldBuildBlocks(
            expandCompletedWork: false, workItemCount: 12
        ))
        XCTAssertTrue(AgentCompletedWorkPresentation.shouldBuildBlocks(
            expandCompletedWork: true, workItemCount: 3
        ))
        XCTAssertFalse(AgentCompletedWorkPresentation.shouldBuildBlocks(
            expandCompletedWork: true, workItemCount: 0
        ))
    }

    func test_collapsedLabel_prefersDuration() {
        XCTAssertEqual(
            AgentCompletedWorkPresentation.collapsedLabel(workBlockCount: 4, durationText: "12s"),
            "Worked for 12s"
        )
        XCTAssertEqual(
            AgentCompletedWorkPresentation.collapsedLabel(workBlockCount: 4, durationText: nil),
            "Worked · 4 steps"
        )
    }

    // MARK: Work so far expand policy + append growth

    func test_workExpandPolicy_defaultOpenLatestLive_andCollapseOnFinal() {
        // WHY: latest live Work so far must open by default so users see in-flight tools.
        XCTAssertTrue(
            AgentCompletedWorkExpandPolicy.isExpanded(
                isLive: true,
                isLatestLiveTurn: true,
                userExplicitlyExpanded: false,
                userCollapsedWhileLive: false
            ),
            "latest live work disclosure defaults open"
        )
        XCTAssertFalse(
            AgentCompletedWorkExpandPolicy.isExpanded(
                isLive: true,
                isLatestLiveTurn: true,
                userExplicitlyExpanded: false,
                userCollapsedWhileLive: true
            ),
            "user can manually collapse the live default-open disclosure"
        )
        XCTAssertFalse(
            AgentCompletedWorkExpandPolicy.isExpanded(
                isLive: false,
                isLatestLiveTurn: false,
                userExplicitlyExpanded: false,
                userCollapsedWhileLive: false
            ),
            "finished work stays collapsed unless the user re-opens it"
        )
        XCTAssertTrue(
            AgentCompletedWorkExpandPolicy.isExpanded(
                isLive: false,
                isLatestLiveTurn: false,
                userExplicitlyExpanded: true,
                userCollapsedWhileLive: false
            ),
            "user can re-open a finished Worked disclosure"
        )
        let cleared = AgentCompletedWorkExpandPolicy.clearedExpansionState()
        XCTAssertTrue(cleared.expanded.isEmpty && cleared.collapsedLive.isEmpty,
                      "final answer clears every work-disclosure override")
    }

    func test_workExpandPolicy_toggle_liveCollapseAndReopen() {
        let collapsed = AgentCompletedWorkExpandPolicy.toggle(
            turnId: "t1",
            currentlyExpanded: true,
            isLive: true,
            isLatestLiveTurn: true,
            userExpanded: [],
            userCollapsedLive: []
        )
        XCTAssertTrue(collapsed.collapsedLive.contains("t1"))
        XCTAssertFalse(collapsed.expanded.contains("t1"))
        let reopened = AgentCompletedWorkExpandPolicy.toggle(
            turnId: "t1",
            currentlyExpanded: false,
            isLive: true,
            isLatestLiveTurn: true,
            userExpanded: collapsed.expanded,
            userCollapsedLive: collapsed.collapsedLive
        )
        XCTAssertFalse(reopened.collapsedLive.contains("t1"))
        XCTAssertTrue(reopened.expanded.contains("t1"))
    }

    func test_workBlockGrowth_prefixStableAppend_reusesPriorIdentities() {
        // N settled → N+1 settled while expanded must be append/reuse, not full_rebuild.
        let previousItems = ["i0", "i1", "i2"]
        let previousBlocks = ["block-item-i0", "block-item-i1", "block-item-i2"]
        let nextItems = ["i0", "i1", "i2", "i3"]
        let nextBlocks = ["block-item-i0", "block-item-i1", "block-item-i2", "block-item-i3"]
        let growth = AgentCompletedWorkBlockGrowth.growthDecision(
            previousItemIds: previousItems,
            previousBlockIds: previousBlocks,
            nextItemIds: nextItems,
            nextBlockIds: nextBlocks
        )
        XCTAssertEqual(growth.mode, "append",
                       "settled tail growth must append rather than rematerialize the full prior set")
        XCTAssertEqual(growth.reusedCount, 3)
        XCTAssertEqual(growth.appendedBlockIds, ["block-item-i3"])

        let identical = AgentCompletedWorkBlockGrowth.growthDecision(
            previousItemIds: nextItems,
            previousBlockIds: nextBlocks,
            nextItemIds: nextItems,
            nextBlockIds: nextBlocks
        )
        XCTAssertEqual(identical.mode, "reuse")
        XCTAssertTrue(identical.appendedBlockIds.isEmpty)

        let rebuilt = AgentCompletedWorkBlockGrowth.growthDecision(
            previousItemIds: ["a", "b"],
            previousBlockIds: ["block-a", "block-b"],
            nextItemIds: ["x", "y"],
            nextBlockIds: ["block-x", "block-y"]
        )
        XCTAssertEqual(rebuilt.mode, "full_rebuild")
    }

    func test_splitTrailingLiveTurns_preservesOrder_andKeepsLiveEager() {
        // WHY: Lazy history + eager live tail must reassemble to the same sequence;
        // a finished entry after a live turn must stay in the eager suffix so the
        // still-streaming row never migrates into LazyVStack.
        let finished = AssistantTurnSnapshot(
            turnId: "done",
            items: [AssistantItem(id: "i", turnId: "done", type: .tool, state: .completed, startedAtMs: 1, finishedAtMs: 2)],
            finished: true
        )
        let live = AssistantTurnSnapshot(
            turnId: "live",
            items: [AssistantItem(id: "j", turnId: "live", type: .tool, state: .streaming, startedAtMs: 3)],
            finished: false
        )
        let afterLive = AssistantTurnSnapshot(
            turnId: "after",
            items: [AssistantItem(id: "k", turnId: "after", type: .tool, state: .completed, startedAtMs: 4, finishedAtMs: 5)],
            finished: true
        )
        let msg = AgentMessage(
            id: AgentMessageID(),
            threadId: AgentThreadID(),
            role: .user,
            content: "hi",
            createdAt: Date(timeIntervalSince1970: 0.5)
        )
        let entries: [AgentAppView.TranscriptEntry] = [
            .message(msg),
            .turn(finished),
            .turn(live),
            .turn(afterLive),
        ]
        let split = AgentAppView.splitTrailingLiveTurns(entries, latestLiveTurnId: "live")
        XCTAssertEqual(split.history.map(\.id), [entries[0].id, entries[1].id])
        XCTAssertEqual(split.liveTail.map(\.id), [entries[2].id, entries[3].id])
        XCTAssertEqual(
            (split.history + split.liveTail).map(\.id),
            entries.map(\.id),
            "history+liveTail must equal original order"
        )
    }

    func test_splitTrailingLiveTurns_staleUnfinishedDoesNotDisableLazy() {
        // WHY: a stuck unfinished turn near the top must stay Lazy; only the
        // current live (or trailing unfinished) is eager.
        let stuckLive = AssistantTurnSnapshot(
            turnId: "stuck",
            items: [AssistantItem(id: "s", turnId: "stuck", type: .tool, state: .streaming, startedAtMs: 1)],
            finished: false
        )
        let laterFinished = AssistantTurnSnapshot(
            turnId: "later",
            items: [AssistantItem(id: "l", turnId: "later", type: .tool, state: .completed, startedAtMs: 2, finishedAtMs: 3)],
            finished: true
        )
        let currentLive = AssistantTurnSnapshot(
            turnId: "now",
            items: [AssistantItem(id: "n", turnId: "now", type: .tool, state: .streaming, startedAtMs: 4)],
            finished: false
        )
        let paint: [AgentAppView.TranscriptEntry] = [
            .turn(stuckLive),
            .turn(laterFinished),
            .turn(currentLive),
        ]
        let split = AgentAppView.splitTrailingLiveTurns(paint, latestLiveTurnId: "now")
        XCTAssertEqual(split.history.map(\.id), [paint[0].id, paint[1].id])
        XCTAssertEqual(split.liveTail.map(\.id), [paint[2].id])
        // Without latest id: only trailing unfinished peels.
        let peel = AgentAppView.splitTrailingLiveTurns(paint)
        XCTAssertEqual(peel.liveTail.map(\.id), [paint[2].id])
        XCTAssertEqual(peel.history.map(\.id), [paint[0].id, paint[1].id])
    }

    func test_turnSortTime_usesOnlyFirstItemStartedAt() {
        // WHY: min() pulls the turn backward when a later parallel tool has an
        // earlier host stamp — Lazy identity thrash mid-stream.
        let turn = AssistantTurnSnapshot(
            turnId: "t",
            items: [
                AssistantItem(id: "a", turnId: "t", type: .tool, state: .streaming, startedAtMs: 5_000),
                AssistantItem(id: "b", turnId: "t", type: .tool, state: .streaming, startedAtMs: 1_000),
            ],
            finished: false
        )
        XCTAssertEqual(
            AgentAppView.TranscriptEntry.turn(turn).sortTime,
            5.0,
            "must use first item startedAtMs, not min across items"
        )
        let empty = AssistantTurnSnapshot(turnId: "empty", items: [], finished: false, startedAtMs: 7_000)
        XCTAssertEqual(
            AgentAppView.TranscriptEntry.turn(empty).sortTime,
            7.0,
            "empty turn falls back to turn.startedAtMs"
        )
    }

    func test_transcriptOrder_ensuringOrdered_fixesInversionWithoutDuplicates() {
        // WHY: Lazy lists require a stable total order; disorder would reshuffle rows mid-stream.
        struct E: Equatable { let id: String; let t: TimeInterval }
        let disordered = [
            E(id: "message-b", t: 2),
            E(id: "message-a", t: 1),
            E(id: "turn-z", t: 1.5),
        ]
        let ordered = AgentTranscriptOrder.ensuringOrdered(disordered, time: \.t, id: \.id)
        XCTAssertEqual(ordered.map(\.id), ["message-a", "turn-z", "message-b"])
        let already = AgentTranscriptOrder.ensuringOrdered(ordered, time: \.t, id: \.id)
        XCTAssertEqual(already.map(\.id), ordered.map(\.id), "already-ordered list must not reshuffle")
        XCTAssertTrue(
            AgentTranscriptOrder.isOrdered(times: ordered.map(\.t), ids: ordered.map(\.id))
        )
        let remat = AgentTranscriptOrder.rematerializePreservingOrder(
            orderedIds: ["message-a", "turn-z", "message-b"],
            payloadsById: ["message-a": "A", "message-b": "B", "turn-z": "T", "extra": "X"]
        )
        XCTAssertEqual(remat, ["A", "T", "B"], "rematerialize keeps sequence; never inserts unknown mid-list")
    }

    /// WHY: opening a long thread sometimes painted the persisted final *above*
    /// "Work so far" when message.createdAt sorted before the turn sort anchor.
    func test_placingMatchingFinalsAfterTurns_movesAnswerBelowWorkSoFar() {
        struct Row: Equatable {
            enum Kind { case user, turn, assistant }
            let id: String
            let kind: Kind
            let text: String?
        }
        let inverted: [Row] = [
            Row(id: "user", kind: .user, text: "do the work"),
            Row(id: "final-msg", kind: .assistant, text: "Here is the Phases table answer"),
            Row(id: "turn-1", kind: .turn, text: "Here is the Phases table answer"),
        ]
        let fixed = AgentTranscriptOrder.placingMatchingFinalsAfterTurns(
            inverted,
            turnFinalText: { $0.kind == .turn ? $0.text : nil },
            assistantMessageText: { $0.kind == .assistant ? $0.text : nil },
            normalizedText: AgentTranscriptOrder.normalizedFinalText
        )
        XCTAssertEqual(
            fixed.map(\.id),
            ["user", "turn-1", "final-msg"],
            "final answer must paint after its turn (Work so far → final)"
        )
        let alreadyGood = AgentTranscriptOrder.placingMatchingFinalsAfterTurns(
            fixed,
            turnFinalText: { $0.kind == .turn ? $0.text : nil },
            assistantMessageText: { $0.kind == .assistant ? $0.text : nil },
            normalizedText: AgentTranscriptOrder.normalizedFinalText
        )
        XCTAssertEqual(alreadyGood.map(\.id), fixed.map(\.id), "idempotent when order is already correct")
    }

    /// WHY: scrolling recomputes transcript paint order. Normalizing every turn
    /// final again for every persisted message made that render path explode on
    /// long histories even though each source string only needs one compact form.
    func test_placingMatchingFinalsAfterTurns_normalizesEachCandidateOnceAtScale() {
        struct Row: Equatable {
            enum Kind { case turn, assistant }
            let id: String
            let kind: Kind
            let text: String
        }
        let messages = (0..<25).map {
            Row(id: "message-\($0)", kind: .assistant, text: "answer-\($0)")
        }
        let turns = (0..<5_000).map {
            Row(id: "turn-\($0)", kind: .turn, text: "answer-\($0)")
        }
        var normalizationCount = 0

        let fixed = AgentTranscriptOrder.placingMatchingFinalsAfterTurns(
            messages + turns,
            turnFinalText: { $0.kind == .turn ? $0.text : nil },
            assistantMessageText: { $0.kind == .assistant ? $0.text : nil },
            normalizedText: { text in
                normalizationCount += 1
                return text
            }
        )

        XCTAssertEqual(normalizationCount, messages.count + turns.count)
        XCTAssertEqual(fixed.first?.id, "turn-0")
        XCTAssertEqual(fixed.dropFirst().first?.id, "message-0")
    }

    func test_finalTextsMatch_ignoresWhitespaceNoise() {
        XCTAssertTrue(
            AgentTranscriptOrder.finalTextsMatch("Hello  world\n", "Hello world"),
            "whitespace-only differences must still associate final with its turn"
        )
        XCTAssertFalse(
            AgentTranscriptOrder.finalTextsMatch("alpha", "beta"),
            "unrelated answers must not be reordered against each other"
        )
    }

    func test_workDisclosureLayout_paintSliceAndDiffPreview() {
        let all = Array(0..<100)
        let slice = AgentWorkDisclosureLayout.paintSlice(all: all, revealCount: 0)
        XCTAssertEqual(slice.rows.count, AgentWorkDisclosureLayout.expandedPaintWindow)
        XCTAssertEqual(slice.hiddenCount, 100 - AgentWorkDisclosureLayout.expandedPaintWindow)
        let more = AgentWorkDisclosureLayout.paintSlice(all: all, revealCount: 48)
        XCTAssertEqual(more.rows.count, 96)
        let lines = (0..<50).map { "L\($0)" }
        let preview = AgentWorkDisclosureLayout.visibleDiffLines(
            lines,
            isMeta: { $0.hasPrefix("M") },
            showAll: false,
            previewLimit: 10
        )
        XCTAssertEqual(preview.rows.count, 10)
        XCTAssertEqual(preview.hiddenCount, 40)
    }

    /// WHY: one outer Work-so-far block can contain thousands of grouped tool
    /// items. Expanding that single block must not eagerly mount every tool row.
    func test_workDisclosureLayout_toolGroupPaintAndThumbnailPreviewStayBounded() {
        let all = Array(0..<5_000)
        let slice = AgentWorkDisclosureLayout.toolGroupPaintSlice(all: all, revealCount: 0)
        XCTAssertEqual(slice.rows.count, AgentWorkDisclosureLayout.toolGroupPaintWindow)
        XCTAssertEqual(slice.hiddenCount, 5_000 - AgentWorkDisclosureLayout.toolGroupPaintWindow)

        let more = AgentWorkDisclosureLayout.toolGroupPaintSlice(
            all: all,
            revealCount: AgentWorkDisclosureLayout.toolGroupRevealPage
        )
        XCTAssertEqual(
            more.rows.count,
            AgentWorkDisclosureLayout.toolGroupPaintWindow + AgentWorkDisclosureLayout.toolGroupRevealPage
        )
        XCTAssertEqual(
            AgentWorkDisclosureLayout.toolGroupThumbnailPreview(
                all: all,
                isThumbnail: { $0.isMultiple(of: 100) }
            ),
            Array(
                all.filter { $0.isMultiple(of: 100) }
                    .suffix(AgentWorkDisclosureLayout.toolGroupThumbnailPreviewWindow)
            ),
            "collapsed image bursts must not decode thousands of thumbnails"
        )
    }

    func test_turnChatComposition_liveAllInWork_finishedFinalOutside() {
        // WHY: chat chrome must match iOS — user | Work so far | final only.
        let live = AgentTurnChatComposition.splitItems(
            ["tool-1", "tool-2", "stream"],
            turnFinished: false,
            isFinalItem: { $0 == "final" }
        )
        XCTAssertEqual(live.work, ["tool-1", "tool-2", "stream"])
        XCTAssertTrue(live.outside.isEmpty)
        let finished = AgentTurnChatComposition.splitItems(
            ["tool", "preamble", "final"],
            turnFinished: true,
            isFinalItem: { $0 == "final" }
        )
        XCTAssertEqual(finished.work, ["tool", "preamble"])
        XCTAssertEqual(finished.outside, ["final"])
    }

    // MARK: File edit diff presentation

    func test_fileEditDiff_parsesUnifiedHunkWithLineNumbers() {
        let diff = """
        diff --git a/src/foo.ts b/src/foo.ts
        --- a/src/foo.ts
        +++ b/src/foo.ts
        @@ -10,3 +10,4 @@
         context
        -old line
        +new line
        +another
         trail
        """
        let parsed = AgentFileEditDiffPresentation.parseUnifiedDiff(diff)
        XCTAssertEqual(parsed.inferredPath, "src/foo.ts")
        let kinds = parsed.lines.map(\.kind)
        XCTAssertTrue(kinds.contains(.deletion))
        XCTAssertTrue(kinds.contains(.addition))
        XCTAssertTrue(kinds.contains(.context))
        let firstAdd = parsed.lines.first(where: { $0.kind == .addition && $0.text.contains("new line") })
        XCTAssertEqual(firstAdd?.newLineNumber, 11,
                       "@@ -10 +10 maps first context to 10; first + is line 11")
    }

    func test_fileEditDiff_synthesizesClaudeEditJSON() {
        let body = """
        {"file_path":"/Users/me/app/generate-invoice.ts","old_string":"a = 1\\nb = 2","new_string":"a = 1\\nb = 3\\nc = 4"}
        """
        let item = AssistantItem(
            id: "edit-1",
            turnId: "t1",
            type: .tool,
            state: .completed,
            summary: "Edit",
            body: body,
            startedAtMs: 1
        )
        let model = AgentFileEditDiffPresentation.model(for: item)
        XCTAssertNotNil(model, "Claude Edit JSON must become a paint-able Edit card model")
        XCTAssertEqual(model?.path, "/Users/me/app/generate-invoice.ts")
        XCTAssertTrue(model?.hasRenderableCode == true)
        XCTAssertTrue(model?.lines.contains(where: { $0.kind == .deletion }) == true)
        XCTAssertTrue(model?.lines.contains(where: { $0.kind == .addition }) == true)
    }

    func test_fileEditDiff_codexPatchOnFileChangeItem() {
        let patch = """
        *** Update File: path/to/file.swift
        @@ -1,2 +1,2 @@
        -let x = 1
        +let x = 2
        """
        let item = AssistantItem(
            id: "fc-1",
            turnId: "t1",
            type: .fileChange,
            state: .completed,
            summary: "1 file change",
            output: patch,
            resourcePath: "path/to/file.swift",
            startedAtMs: 1
        )
        let model = AgentFileEditDiffPresentation.model(for: item)
        XCTAssertEqual(model?.path, "path/to/file.swift")
        XCTAssertTrue(model?.lines.contains(where: { $0.kind == .deletion && $0.text.contains("let x = 1") }) == true)
        XCTAssertTrue(model?.lines.contains(where: { $0.kind == .addition && $0.text.contains("let x = 2") }) == true)
    }

    /// WHY (perf CH-03): the live tool row re-ran the whole diff extraction (JSON
    /// parses + full-text splits) on every body pass — even for a Bash tool whose
    /// 50 KB output is not a diff. Identical growth signatures must extract once.
    func test_fileEditDiff_modelExtractsOncePerGrowthSignature() {
        let bigNonDiffOutput = String(
            repeating: "plain build log line with no diff markers at all\n", count: 1_200
        )
        var item = AssistantItem(
            id: "bash-50k",
            turnId: "t1",
            type: .tool,
            state: .streaming,
            summary: "Bash",
            body: "npm run build",
            output: bigNonDiffOutput,
            startedAtMs: 1
        )
        AgentFileEditDiffPresentation.diffModelComputeCountForTesting = 0

        let first = AgentFileEditDiffPresentation.model(for: item)
        XCTAssertNil(first, "sanity: a non-diff build log is not an Edit card")
        XCTAssertEqual(AgentFileEditDiffPresentation.diffModelComputeCountForTesting, 1)

        // Twenty body passes (tokens streaming into sibling rows): cache hits.
        for _ in 0..<20 {
            XCTAssertNil(AgentFileEditDiffPresentation.model(for: item))
        }
        XCTAssertEqual(
            AgentFileEditDiffPresentation.diffModelComputeCountForTesting, 1,
            "20 body passes of the same 50 KB non-diff output must run zero re-extractions"
        )

        // Output growth (the tool streaming more) invalidates the signature.
        item.output! += "final line\n"
        _ = AgentFileEditDiffPresentation.model(for: item)
        XCTAssertEqual(
            AgentFileEditDiffPresentation.diffModelComputeCountForTesting, 2,
            "output growth must re-extract exactly once for the new signature"
        )

        // A state transition (streaming -> completed) also invalidates.
        item.state = .completed
        _ = AgentFileEditDiffPresentation.model(for: item)
        XCTAssertEqual(AgentFileEditDiffPresentation.diffModelComputeCountForTesting, 3)
    }

    func test_diffModelCacheLimits_areHalvedFrom4MiBAnd512() {
        XCTAssertEqual(AgentFileEditDiffPresentation.diffModelCacheCountLimit, 256)
        XCTAssertEqual(AgentFileEditDiffPresentation.diffModelCacheCostLimit, 2 * 1_024 * 1_024)
    }

    /// WHY (perf CH-03): plain-text tool output must never reach
    /// JSONSerialization — only payloads starting with { or [ can be JSON.
    func test_extractDiffText_skipsJSONAttemptsForPlainText() {
        let plain = "compiling module A\ncompiling module B\nDone."
        let item = AssistantItem(
            id: "plain-1",
            turnId: "t1",
            type: .tool,
            state: .completed,
            summary: "Bash",
            body: "swift build",
            output: plain,
            startedAtMs: 1
        )
        XCTAssertNil(AgentFileEditDiffPresentation.extractDiffText(from: item),
                     "plain build output is not a diff")
        // A JSON tool output still extracts through the JSON path.
        let json = #"{"file_path":"a.ts","old_string":"x","new_string":"y"}"#
        let jsonItem = AssistantItem(
            id: "json-1",
            turnId: "t1",
            type: .tool,
            state: .completed,
            summary: "Edit",
            body: json,
            startedAtMs: 1
        )
        let extracted = AgentFileEditDiffPresentation.extractDiffText(from: jsonItem)
        XCTAssertNotNil(extracted, "Edit JSON still extracts a diff")
        XCTAssertTrue(extracted?.contains("a.ts") == true)
    }

    func test_looksLikeDiff_detectsHeadersAndPlusMinusOnSubstrings() {
        XCTAssertTrue(AgentFileEditDiffPresentation.looksLikeDiff("diff --git a/a.ts b/a.ts\n"))
        XCTAssertTrue(AgentFileEditDiffPresentation.looksLikeDiff("@@ -1,2 +1,3 @@\n"))
        XCTAssertTrue(AgentFileEditDiffPresentation.looksLikeDiff("*** Begin Patch\n*** Update File: a.ts\n"))
        XCTAssertTrue(
            AgentFileEditDiffPresentation.looksLikeDiff("+added\n-removed\n context\n"),
            "plus/minus heuristic must still fire without allocating String per line"
        )
        XCTAssertFalse(
            AgentFileEditDiffPresentation.looksLikeDiff("compiling module A\ncompiling module B\nDone.\n"),
            "plain build logs are not diffs"
        )
        XCTAssertTrue(
            AgentFileEditDiffPresentation.looksLikeDiff("\n\ndiff --git a/a.ts b/a.ts\n"),
            "leading blank lines must not hide a real diff header"
        )
    }

    func test_firstNonWhitespace_stopsAtPayload() {
        XCTAssertEqual(AgentFileEditDiffPresentation.firstNonWhitespace(in: "  {\n"), "{")
        XCTAssertEqual(AgentFileEditDiffPresentation.firstNonWhitespace(in: "\n\n["), "[")
        XCTAssertEqual(AgentFileEditDiffPresentation.firstNonWhitespace(in: "plain"), "p")
        XCTAssertNil(AgentFileEditDiffPresentation.firstNonWhitespace(in: "  \n\t"))
    }

    func test_extractDiffText_trimsPositiveDiffAndSkipsTrimOnPlainMiss() {
        let padded = "\n\ndiff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\n@@ -1 +1 @@\n-old\n+new\n"
        let item = AssistantItem(
            id: "diff-1",
            turnId: "t1",
            type: .fileChange,
            state: .completed,
            body: padded,
            startedAtMs: 1
        )
        let extracted = AgentFileEditDiffPresentation.extractDiffText(from: item)
        XCTAssertEqual(extracted?.hasPrefix("diff --git"), true, "positive hits still trim leading blanks")

        let json = "  {\"file_path\":\"a.ts\",\"old_string\":\"x\",\"new_string\":\"y\"}  "
        let jsonItem = AssistantItem(
            id: "json-ws",
            turnId: "t1",
            type: .tool,
            state: .completed,
            summary: "Edit",
            body: json,
            startedAtMs: 1
        )
        let jsonExtracted = AgentFileEditDiffPresentation.extractDiffText(from: jsonItem)
        XCTAssertNotNil(jsonExtracted, "leading-whitespace Edit JSON must still extract")
        XCTAssertTrue(jsonExtracted?.contains("a.ts") == true)
    }

    func test_microbench_looksLikeDiff_substringBeatsStringCopy() {
        let log = String(repeating: "plain build log line with no diff markers at all\n", count: 1_200)
        XCTAssertGreaterThan(log.utf8.count, 40_000)
        XCTAssertFalse(AgentFileEditDiffPresentation.looksLikeDiff(log))

        let iterations = 400
        let warmup = 2
        let samplesN = 5

        /// Frozen pre-r11: two passes, String(line) per scanned line.
        func legacyLooksLikeDiff(_ text: String) -> Bool {
            for line in text.lazy.split(separator: "\n", omittingEmptySubsequences: true).prefix(60) {
                let s = String(line)
                if s.hasPrefix("diff --git ") || s.hasPrefix("@@") || s.hasPrefix("--- ") || s.hasPrefix("+++ ") {
                    return true
                }
                if s.hasPrefix("*** Begin Patch") || s.hasPrefix("*** Update File:") || s.hasPrefix("*** Add File:") {
                    return true
                }
            }
            var plus = 0, minus = 0
            for lazyLine in text.lazy.split(separator: "\n", omittingEmptySubsequences: true).prefix(80) {
                let line = String(lazyLine)
                if line.hasPrefix("+") && !line.hasPrefix("++") { plus += 1 }
                if line.hasPrefix("-") && !line.hasPrefix("--") { minus += 1 }
            }
            return plus + minus >= 2 && (plus > 0 || minus > 0)
        }

        func time(_ shape: (String) -> Bool) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations { sink &+= shape(log) ? 1 : 0 }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        XCTAssertEqual(legacyLooksLikeDiff(log), AgentFileEditDiffPresentation.looksLikeDiff(log))

        for _ in 0..<warmup { _ = time(legacyLooksLikeDiff); _ = time(AgentFileEditDiffPresentation.looksLikeDiff) }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samplesN {
            before.append(time(legacyLooksLikeDiff))
            after.append(time(AgentFileEditDiffPresentation.looksLikeDiff))
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog(
            "[perf-proof] r11_looksLikeDiff legacy_ms=%@ substring_ms=%@ improvement_pct=%.2f before=%@ after=%@",
            String(beforeMed), String(afterMed), improvement,
            String(describing: before), String(describing: after)
        )
        XCTAssertGreaterThan(
            improvement, 15.0,
            "substring looksLikeDiff must beat String(line) copies by ≥15% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
    }

    func test_microbench_extractDiffText_plainMissSkipsFullTrimCopy() {
        // Memory, not wall-clock: extractApplyPatchBlock still scans the blob
        // with contains(), so end-to-end CPU is dominated by that pre-existing
        // miss tax. The r11 change is skipping trimmingCharacters's 50 KB copy.
        let log = String(repeating: "plain build log line with no diff markers at all\n", count: 1_200)
        XCTAssertGreaterThan(log.utf8.count, 40_000)
        let iterations = 800
        let warmup = 2
        let samplesN = 5

        func time(_ work: () -> Int) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations { sink &+= work() }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup {
            _ = time { log.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count }
            _ = time { AgentFileEditDiffPresentation.firstNonWhitespace(in: log) == nil ? 0 : log.utf8.count }
        }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samplesN {
            before.append(time { log.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count })
            after.append(time {
                AgentFileEditDiffPresentation.firstNonWhitespace(in: log) == nil ? 0 : log.utf8.count
            })
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog(
            "[perf-proof] r11_extractDiffTextTrimIsolated legacy_trim_ms=%@ firstNonWS_ms=%@ improvement_pct=%.2f before=%@ after=%@",
            String(beforeMed), String(afterMed), improvement,
            String(describing: before), String(describing: after)
        )
        XCTAssertGreaterThan(
            improvement, 50.0,
            "isolated skip-trim must beat trimmingCharacters by ≥50% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
        let item = AssistantItem(
            id: "bash-r11",
            turnId: "t1",
            type: .tool,
            state: .streaming,
            summary: "Bash",
            body: "npm run build",
            output: log,
            startedAtMs: 1
        )
        XCTAssertNil(AgentFileEditDiffPresentation.extractDiffText(from: item))
    }

    private func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s[s.count / 2]
    }

    func test_appendFriendlyCompletedWorkBlocks_refreshesPayloadWhenIdsUnchanged() {
        // WHY: token deltas keep item ids; returning previous blocks froze body mid-stream.
        var first = AssistantItem(
            id: "r1", turnId: "t", type: .reasoning, state: .streaming,
            body: "thin", startedAtMs: 1
        )
        let firstBlocks = AgentAppView.turnRenderBlocks([first])
        first.body = "thinking out loud fully"
        let refreshed = AgentAppView.appendFriendlyCompletedWorkBlocks(
            previousItems: [
                AssistantItem(
                    id: "r1", turnId: "t", type: .reasoning, state: .streaming,
                    body: "thin", startedAtMs: 1
                )
            ],
            previousBlocks: firstBlocks,
            nextItems: [first]
        )
        XCTAssertEqual(refreshed.count, 1)
        if case .item(let item) = refreshed[0] {
            XCTAssertEqual(item.body, "thinking out loud fully")
        } else {
            XCTFail("expected single item block")
        }
    }

    func test_eagerAnchorTurnId_rejectsStaleLiveNearTop() {
        // WHY: stale unfinished at index 0 must not force whole paint eager.
        let stuck = AssistantTurnSnapshot(
            turnId: "stuck",
            items: [AssistantItem(id: "s", turnId: "stuck", type: .tool, state: .streaming, startedAtMs: 1)],
            finished: false
        )
        var entries: [AgentAppView.TranscriptEntry] = [.turn(stuck)]
        for i in 0..<25 {
            entries.append(.turn(AssistantTurnSnapshot(
                turnId: "f\(i)",
                items: [AssistantItem(id: "x\(i)", turnId: "f\(i)", type: .tool, state: .completed, startedAtMs: Int64(i + 2), finishedAtMs: Int64(i + 3))],
                finished: true
            )))
        }
        XCTAssertNil(
            AgentAppView.eagerAnchorTurnId(entries, latestLiveTurnId: "stuck", maxEagerTail: 20)
        )
        let live = AssistantTurnSnapshot(
            turnId: "now",
            items: [AssistantItem(id: "n", turnId: "now", type: .tool, state: .streaming, startedAtMs: 100)],
            finished: false
        )
        entries.append(.turn(live))
        XCTAssertEqual(
            AgentAppView.eagerAnchorTurnId(entries, latestLiveTurnId: "now", maxEagerTail: 20),
            "now"
        )
    }

    func test_appendFriendlyCompletedWorkBlocks_appendsNewSettledTool() {
        func item(_ id: String) -> AssistantItem {
            AssistantItem(
                id: id,
                turnId: "t1",
                type: .commandExecution,
                state: .completed,
                body: "cmd \(id)",
                startedAtMs: 1
            )
        }
        let first = [item("i0"), item("i1")]
        let firstBlocks = AgentAppView.turnRenderBlocks(first)
        let second = first + [item("i2")]
        let grown = AgentAppView.appendFriendlyCompletedWorkBlocks(
            previousItems: first,
            previousBlocks: firstBlocks,
            nextItems: second
        )
        // Pure tool run ≥ threshold folds into one group with stable first-item id.
        XCTAssertEqual(grown.count, 1)
        if case .toolGroup(let id, let items) = grown[0] {
            XCTAssertEqual(id, "i0")
            XCTAssertEqual(items.map(\.id), ["i0", "i1", "i2"])
        } else {
            XCTFail("expected single tool group after append")
        }
        let third = second + [item("i3")]
        let grownAgain = AgentAppView.appendFriendlyCompletedWorkBlocks(
            previousItems: second,
            previousBlocks: grown,
            nextItems: third
        )
        if case .toolGroup(let id, let items) = grownAgain[0] {
            XCTAssertEqual(id, "i0", "group identity must stay stable across appends")
            XCTAssertEqual(items.map(\.id), ["i0", "i1", "i2", "i3"])
        } else {
            XCTFail("expected stable tool group after second append")
        }
    }

    // MARK: Thread rail

    func test_threadRail_monogramAndRelativeTime() {
        XCTAssertEqual(AgentThreadRailRowCopy.monogram(for: .claude), "C")
        let now = Date()
        let threeMin = now.addingTimeInterval(-180)
        XCTAssertEqual(AgentThreadRailRowCopy.relativeTime(from: threeMin, now: now), "3m")
        let subtitle = AgentThreadRailRowCopy.subtitle(
            provider: .codex,
            model: "gpt-5.4-extra-long-model-name-that-should-truncate",
            updatedAt: threeMin,
            now: now
        )
        XCTAssertTrue(subtitle.contains("codex"))
        XCTAssertTrue(subtitle.contains("3m"))
        XCTAssertTrue(subtitle.contains("…"), "long models truncate for rail density")
    }

    func test_threadRailCopy_headerSearchAndClearAll_matchAgentAppChrome() throws {
        // WHY: dest and Agent App must share one rail chrome. Header,
        // search match, and Clear All visibility cannot drift per surface.
        XCTAssertEqual(AgentChatThreadRailCopy.headerTitle(activeCount: 0), "Threads")
        XCTAssertEqual(AgentChatThreadRailCopy.headerTitle(activeCount: 2), "Threads · 2 active")
        XCTAssertEqual(AgentChatThreadRailCopy.searchPlaceholder, "Search threads")
        XCTAssertEqual(AgentChatThreadRailCopy.clearAllTitle, "Clear All")
        XCTAssertTrue(AgentChatThreadRailCopy.matches(title: "Standup notes", query: "stand"))
        XCTAssertTrue(AgentChatThreadRailCopy.matches(title: "oi", extra: "grok-4.6", query: "grok"))
        XCTAssertFalse(AgentChatThreadRailCopy.matches(title: "Standup", query: "auth"))
        XCTAssertTrue(AgentChatThreadRailCopy.matches(title: "Standup", query: "  "))
        XCTAssertEqual(AgentChatThreadRailCopy.noMatchText(query: "auth"), "No threads match \"auth\"")
        XCTAssertTrue(AgentChatThreadRailCopy.showsClearAll(isEmpty: false))
        XCTAssertFalse(AgentChatThreadRailCopy.showsClearAll(isEmpty: true))

        let chrome = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentChatSharedChrome.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(chrome.contains(".lineLimit(1)"))
        XCTAssertTrue(chrome.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertTrue(chrome.contains("headerControlSpacing"))
        XCTAssertTrue(chrome.contains("DS.Space.md"))
        XCTAssertTrue(chrome.contains("DSIconButton.visualPackInset"))
        XCTAssertFalse(
            chrome.contains("DS.Space.xs - (DSIconButton.hitTargetSize"),
            "Clear All is text; packing 44pt hit boxes against it mashed the cluster"
        )
        XCTAssertTrue(chrome.contains("AgentChatThreadRowStopChrome"))
        XCTAssertTrue(chrome.contains(AgentChatThreadRowStopChrome.symbolName))
    }

    func test_threadRailOrdersActiveFirst_becauseANewIdleRowMustNotBuryALiveRun() {
        // WHY: dest and Agent App share this sort. Creating or selecting an
        // idle thread used to insert at index 0 and hide the working spinner.
        struct Row { let title: String; let running: Bool }
        let rows = [
            Row(title: "idle-new", running: false),
            Row(title: "live", running: true),
            Row(title: "idle-old", running: false),
            Row(title: "live-2", running: true),
        ]
        XCTAssertEqual(
            AgentChatThreadRailCopy.orderingActiveFirst(rows, isActive: { $0.running }).map(\.title),
            ["live", "live-2", "idle-new", "idle-old"]
        )
    }

    func test_distillModelPillCopyUsesCatalogLabelsAndHonestFallbacks() {
        let model = AgentModelDescriptor(id: "grok/test", label: "Test Model (provider)", provider: .grok)
        XCTAssertEqual(AgentDistillModelCatalog.mainPillTitle(model: "", models: []), "Select model")
        XCTAssertEqual(AgentDistillModelCatalog.mainPillTitle(model: model.id, models: [model]), "Test Model")
        XCTAssertEqual(AgentDistillModelCatalog.workerPillTitle(reasoningModel: nil, models: [], supportsSessionWorker: true, homePath: nil), "Off")
        XCTAssertTrue(AgentDistillModelCatalog.workerPillTitle(reasoningModel: nil, models: [], supportsSessionWorker: false, homePath: nil).contains("(config)"))
        XCTAssertTrue(AgentDistillModelCatalog.workerUnavailable(reasoningModel: "missing", models: []))
        XCTAssertFalse(AgentDistillModelCatalog.workerUnavailable(reasoningModel: nil, models: []))
    }

    func test_agentAndDeskMountSameDistillModelPills() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let agent = try String(contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        let bots = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(agent.contains("AgentDistillModelPills("))
        XCTAssertTrue(bots.contains("AgentAppView("), "WHY: Desk reuses Agent App, so it mounts the same Main and Worker pills.")
        XCTAssertFalse(bots.contains("AgentDistillModelSelectors("), "WHY: Desk must use the same independently presented Main and Worker controls as Agent App.")
    }

    func test_threadRowStopChromeOnlyWhenRunningWithHandler() {
        // WHY: the shared row owns the stop.circle; idle rows must not
        // paint it, and a running row without a handler is not stoppable.
        XCTAssertTrue(
            AgentChatThreadRowStopChrome.isVisible(status: .running, hasStopHandler: true)
        )
        XCTAssertFalse(
            AgentChatThreadRowStopChrome.isVisible(status: .running, hasStopHandler: false)
        )
        XCTAssertFalse(
            AgentChatThreadRowStopChrome.isVisible(status: .hidden, hasStopHandler: true)
        )
        XCTAssertFalse(
            AgentChatThreadRowStopChrome.isVisible(status: .unread, hasStopHandler: true)
        )
    }
}
