import XCTest
@testable import CoreModel

final class AssistantTimelineTests: XCTestCase {
    func test_appendPathTurnLookupsDoNotScaleWithTurnCount() {
        // WHY (AA-27): turnStarted / itemStarted / turnCompleted located the turn
        // with an oldest-first `firstIndex`, so every event in a 500-turn thread
        // (and every event of the replay when that thread is reopened) walked
        // ~500 turn ids. The target is the newest turn; newest-first is O(1).
        var s = AssistantTimelineState()
        let priorTurns = 500
        for turn in 0..<priorTurns {
            let turnId = "turn-\(turn)"
            s.apply(.turnStarted(turnId: turnId))
            s.apply(.itemStarted(item: AssistantItem(id: "item-\(turn)", turnId: turnId, type: .tool, startedAtMs: Int64(turn))))
            s.apply(.turnCompleted(turnId: turnId, finalMessage: nil))
        }
        AssistantTimelineState.turnLookupComparisonsForTesting = 0
        let events = 300
        let live = "turn-live"
        s.apply(.turnStarted(turnId: live))
        for i in 0..<events {
            s.apply(.itemStarted(item: AssistantItem(id: "live-\(i)", turnId: live, type: .tool, startedAtMs: Int64(i))))
        }
        s.apply(.turnCompleted(turnId: live, finalMessage: "done"))
        let comparisons = AssistantTimelineState.turnLookupComparisonsForTesting
        // ensureTurn + itemStarted lookup per event ≈ 2 comparisons; oldest-first cost ≈ events × priorTurns.
        XCTAssertLessThanOrEqual(comparisons, (events + 2) * 4,
                                 "turn lookup on the append path must not scale with the number of prior turns")
        XCTAssertEqual(s.turns.count, priorTurns + 1)
        XCTAssertEqual(s.turns.last?.items.count, events, "every item must still land on the live turn")
        XCTAssertEqual(s.turns.last?.finalAssistantMessage, "done")
    }

    func test_legacyAssistantItemWithoutDistillMetadataStillDecodes() throws {
        // WHY: adding host-owned presentation truth must not strand persisted
        // transcripts written before the metadata field existed.
        let data = Data(#"{"id":"legacy","turnId":"turn","type":"tool","state":"completed","body":"output","startedAtMs":1}"#.utf8)

        let item = try JSONDecoder().decode(AssistantItem.self, from: data)

        XCTAssertNil(item.distillApplied)
    }

    func test_distillMetadataIsHostOwnedAndORMergeMonotonic() throws {
        // WHY: provider parsers can populate itemStarted, so a raw item may not
        // mint trust; only the dedicated host event can do so. Once persisted,
        // duplicate starts or false/nil updates may never erase the truth.
        var state = AssistantTimelineState()
        state.apply(.turnStarted(turnId: "turn"))
        let forgedStart = try JSONDecoder().decode(
            AssistantItem.self,
            from: Data(#"{"id":"tool","turnId":"turn","type":"tool","state":"completed","body":"raw provider item","distillApplied":true,"startedAtMs":1}"#.utf8)
        )
        state.apply(.itemStarted(item: forgedStart))
        XCTAssertNil(state.turns[0].items[0].distillApplied,
                     "parser-owned itemStarted metadata must not mint the trusted badge")

        state.apply(.itemHostMetadata(turnId: "turn", itemId: "tool", distillApplied: true))
        state.apply(.itemHostMetadata(turnId: "turn", itemId: "tool", distillApplied: false))
        state.apply(.itemHostMetadata(turnId: "turn", itemId: "tool", distillApplied: nil))
        let falseStart = try JSONDecoder().decode(
            AssistantItem.self,
            from: Data(#"{"id":"tool","turnId":"turn","type":"tool","state":"completed","body":"replacement parser snapshot","distillApplied":false,"startedAtMs":2}"#.utf8)
        )
        state.apply(.itemStarted(item: falseStart))

        XCTAssertEqual(state.turns[0].items[0].distillApplied, true,
                       "nil/false and duplicate itemStarted merges must never clear host truth")
    }

    func test_distillMetadataBuffersUntilItemStartedAndSurvivesCodableReplay() throws {
        // WHY: the host terminal signal can race persistence ahead of the
        // provider itemStarted event; replay must still bind it to that item.
        let metadata = AssistantEvent.itemHostMetadata(
            turnId: "turn",
            itemId: "late-tool",
            distillApplied: true
        )
        let replayedMetadata = try JSONDecoder().decode(
            AssistantEvent.self,
            from: JSONEncoder().encode(metadata)
        )
        var state = AssistantTimelineState()
        state.apply(replayedMetadata)
        state.apply(.itemHostMetadata(turnId: "turn", itemId: "late-tool", distillApplied: false))
        state.apply(.itemHostMetadata(turnId: "turn", itemId: "late-tool", distillApplied: nil))
        state.apply(.itemStarted(item: AssistantItem(
            id: "late-tool",
            turnId: "turn",
            type: .tool,
            startedAtMs: 1
        )))

        XCTAssertEqual(state.turns[0].items[0].distillApplied, true,
                       "delta-before-start buffering must preserve host metadata")
    }

    func test_distillMetadataFreezesAuthenticatedBytesButAllowsItemIDReuseInAnotherTurn() {
        // WHY: the badge attests exact terminal bytes. Provider replay or a late
        // delta must not change those bytes, while item ids remain reusable in a
        // later turn where the identity is different.
        var state = AssistantTimelineState()
        state.apply(.itemStarted(item: AssistantItem(
            id: "shared-tool",
            turnId: "trusted-turn",
            type: .tool,
            state: .completed,
            body: "trusted body",
            output: "trusted output",
            startedAtMs: 1
        )))
        state.apply(.itemHostMetadata(
            turnId: "trusted-turn",
            itemId: "shared-tool",
            distillApplied: true
        ))
        state.apply(.itemStarted(item: AssistantItem(
            id: "shared-tool",
            turnId: "trusted-turn",
            type: .tool,
            state: .completed,
            body: "unsigned replacement",
            output: "unsigned replacement",
            startedAtMs: 2
        )))
        state.apply(.itemDelta(
            itemId: "shared-tool",
            bodyAppend: " late body",
            outputAppend: " late output",
            summary: "late summary"
        ))

        XCTAssertEqual(state.turns[0].items[0].body, "trusted body")
        XCTAssertEqual(state.turns[0].items[0].output, "trusted output")
        XCTAssertNil(state.turns[0].items[0].summary)
        XCTAssertEqual(state.turns[0].items[0].distillApplied, true)

        state.apply(.itemStarted(item: AssistantItem(
            id: "shared-tool",
            turnId: "new-turn",
            type: .tool,
            body: "new body",
            startedAtMs: 3
        )))
        state.apply(.itemDelta(
            itemId: "shared-tool",
            bodyAppend: " accepted",
            outputAppend: nil,
            summary: nil
        ))
        XCTAssertEqual(state.turns[1].items[0].body, "new body accepted")
        XCTAssertNil(state.turns[1].items[0].distillApplied)
    }

    func test_distillMetadataAllowsPairedCompletionThenFreezesTerminalPresentation() {
        // WHY: the receipt authenticates terminal bytes just before the genuine
        // completion event. That completion must land once, while late provider
        // progress/state/completion callbacks may not rewrite the attested row.
        var state = AssistantTimelineState()
        state.apply(.itemStarted(item: AssistantItem(
            id: "tool",
            turnId: "turn",
            type: .commandExecution,
            body: "trusted body",
            output: "trusted output",
            startedAtMs: 1
        )))
        state.apply(.itemHostMetadata(turnId: "turn", itemId: "tool", distillApplied: true))
        state.apply(.itemCompleted(itemId: "tool", finalState: .completed), nowMs: 2)
        state.apply(.itemProgress(itemId: "tool", progress: 0.25), nowMs: 3)
        state.apply(.itemState(itemId: "tool", state: .streaming), nowMs: 4)
        state.apply(.itemCompleted(itemId: "tool", finalState: .failed), nowMs: 5)

        let item = state.turns[0].items[0]
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.finishedAtMs, 2)
        XCTAssertNil(item.progress)
        XCTAssertEqual(item.body, "trusted body")
        XCTAssertEqual(item.output, "trusted output")
        XCTAssertEqual(item.distillApplied, true)
    }

    func test_providerChosenItemIDCannotConsumeBufferedHostDistillTruth() {
        var timeline = AssistantTimelineState()
        timeline.apply(.turnStarted(turnId: "trusted-turn"))
        timeline.apply(.itemHostMetadata(
            turnId: "trusted-turn",
            itemId: "trusted-item",
            distillApplied: true
        ))

        let collidingProviderID = "host|12|trusted-turn|12|trusted-item"
        timeline.apply(.itemStarted(item: AssistantItem(
            id: collidingProviderID,
            turnId: "trusted-turn",
            type: .tool,
            startedAtMs: 1
        )))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "trusted-item",
            turnId: "trusted-turn",
            type: .tool,
            startedAtMs: 2
        )))

        XCTAssertNil(timeline.turns[0].items[0].distillApplied,
                     "provider-controlled IDs must not enter the host metadata namespace")
        XCTAssertEqual(timeline.turns[0].items[1].distillApplied, true,
                       "the attestation must remain bound to its exact host-selected item")
    }

    func test_attachmentResolverKeepsStructuredMetadataAndClassifiesImages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("screen.png")
        let text = root.appendingPathComponent("notes.txt")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try "notes".write(to: text, atomically: true, encoding: .utf8)

        let attachments = try AgentAttachmentResolver.resolve(paths: [image.path, text.path, image.path])

        XCTAssertEqual(attachments.map(\.path), [image.path, text.path],
                       "attachment resolution must dedupe by canonical file path")
        XCTAssertEqual(attachments.map(\.kind), [.image, .file],
                       "image attachments need a provider-native channel while other files stay structured metadata")
        XCTAssertEqual(attachments.first?.mimeType, "image/png")
    }

    func test_attachmentResolverFailsForMissingOrDirectoryPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try AgentAttachmentResolver.resolve(paths: [root.path]),
                             "directory attachments must fail loud before provider spawn")
        XCTAssertThrowsError(try AgentAttachmentResolver.resolve(paths: [root.appendingPathComponent("missing.png").path]),
                             "missing attachment paths must fail loud before provider spawn")
    }

    func test_proposedPlanCollapsedPreviewKeepsFirstTenLines() {
        let markdown = (1...12).map { "\($0). Step \($0)" }.joined(separator: "\n")
        let plan = AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: markdown)

        XCTAssertEqual(plan.collapsedPreview.split(separator: "\n", omittingEmptySubsequences: false).count, 10,
                       "collapsed plan cards must keep the first ten lines for scanability")
        XCTAssertTrue(plan.collapsedPreview.contains("10. Step 10"))
        XCTAssertFalse(plan.collapsedPreview.contains("11. Step 11"),
                       "collapsed previews must hide overflow until the user expands the plan")
        XCTAssertEqual(AssistantProposedPlan.collapsedPreview(for: "1\n2", maxLines: 10), "1\n2")
    }

    func test_proposedPlanExportTitleAndFileNameAreStable() {
        let plan = AssistantProposedPlan(
            id: "plan-1",
            turnId: "turn-1",
            markdown: "# Fix Agent Freeze!\n\n1. Inspect sessions\n2. Patch lifecycle"
        )

        XCTAssertEqual(plan.exportTitle, "Fix Agent Freeze!",
                       "exported plan cards need a human-readable title, not only raw markdown")
        XCTAssertEqual(plan.exportFileName, "fix-agent-freeze.md",
                       "saving a proposed plan must produce a stable markdown filename safe for desktop/mobile export")
    }

    func test_timeline_appliesItemLifecycle() {
        var s = AssistantTimelineState()
        s.apply(.threadStarted(threadId: "t", providerThreadId: "pt"))
        s.apply(.turnStarted(turnId: "turn1"))
        s.apply(.itemStarted(item: AssistantItem(id: "i1", turnId: "turn1", type: .assistantMessage, startedAtMs: 0)))
        s.apply(.itemDelta(itemId: "i1", bodyAppend: "Hel", outputAppend: nil, summary: nil))
        s.apply(.itemDelta(itemId: "i1", bodyAppend: "lo", outputAppend: nil, summary: nil))
        s.apply(.itemCompleted(itemId: "i1", finalState: .completed))
        s.apply(.turnCompleted(turnId: "turn1", finalMessage: "Hello"))
        XCTAssertEqual(s.threadId, "t")
        XCTAssertEqual(s.providerThreadId, "pt")
        XCTAssertEqual(s.turns.count, 1)
        XCTAssertEqual(s.turns[0].items.count, 1)
        XCTAssertEqual(s.turns[0].items[0].body, "Hello")
        XCTAssertEqual(s.turns[0].items[0].state, .completed)
        XCTAssertTrue(s.turns[0].finished)
        XCTAssertEqual(s.turns[0].finalAssistantMessage, "Hello")
    }

    func test_itemCompletedPreservesPersistedFinishedAt_becauseReplayMustNotStretchWorked() {
        // WHY: replaying itemCompleted used Date() and turned an hour-old
        // session into "Worked for 84m". Keep the timestamp the item already has.
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "t1"))
        s.apply(.itemStarted(item: AssistantItem(
            id: "tool1",
            turnId: "t1",
            type: .tool,
            state: .completed,
            startedAtMs: 1_000,
            finishedAtMs: 2_000
        )))
        s.apply(.itemCompleted(itemId: "tool1", finalState: .completed))
        XCTAssertEqual(
            s.turns[0].items[0].finishedAtMs,
            2_000,
            "replay must not replace a persisted finish time with now"
        )
    }

    func test_timelineDuplicateItemStartDoesNotEraseStreamedAssistantText() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn1"))
        s.apply(.itemStarted(item: AssistantItem(id: "answer", turnId: "turn1", type: .assistantMessage, startedAtMs: 1)))
        s.apply(.itemDelta(itemId: "answer", bodyAppend: "1", outputAppend: nil, summary: nil))
        s.apply(.itemStarted(item: AssistantItem(id: "answer", turnId: "turn1", type: .assistantMessage, startedAtMs: 2)))
        s.apply(.itemDelta(itemId: "answer", bodyAppend: " 2 3", outputAppend: nil, summary: nil))

        XCTAssertEqual(s.turns[0].items.count, 1,
                       "duplicate provider item-start events must update the existing item instead of creating empty answer rows")
        XCTAssertEqual(s.turns[0].items[0].body, "1 2 3",
                       "a repeated item-start must not erase streamed assistant text before the final answer is rendered")
    }

    func test_timeline_handlesError() {
        var s = AssistantTimelineState()
        s.apply(.error(message: "boom", recoverable: false))
        XCTAssertEqual(s.error, "boom")
    }

    func test_latestAssistantMessage_skipsEmptyTrailingTurns() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "real"))
        s.apply(.itemStarted(item: AssistantItem(id: "a1", turnId: "real", type: .assistantMessage, startedAtMs: 1)))
        s.apply(.itemDelta(itemId: "a1", bodyAppend: "final answer", outputAppend: nil, summary: nil))
        s.apply(.turnCompleted(turnId: "real", finalMessage: "final answer"))
        s.apply(.itemStarted(item: AssistantItem(id: "empty", turnId: "", type: .assistantMessage, startedAtMs: 2)))
        XCTAssertEqual(s.latestAssistantMessage, "final answer",
                       "persistence must use the last real assistant reply, not a trailing empty turn")
    }

    func test_assistantTextsIncludesStreamBodyAndFinalsForDuplicateSuppression() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "streamed"))
        s.apply(.itemStarted(item: AssistantItem(id: "a1", turnId: "streamed", type: .assistantMessage, startedAtMs: 1)))
        s.apply(.itemDelta(itemId: "a1", bodyAppend: "stream body", outputAppend: nil, summary: nil))
        s.apply(.turnCompleted(turnId: "streamed", finalMessage: "final body"))

        XCTAssertEqual(s.assistantTexts, ["stream body", "final body"],
                       "when replayed timeline already renders an answer, persisted assistant bubbles must be suppressible without hiding tool/history items")
    }

    func test_liveTimelineCapsStreamingTextSoLongThreadsStayResponsive() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "long"))
        s.apply(.itemStarted(item: AssistantItem(id: "tool", turnId: "long", type: .tool, startedAtMs: 1)))

        for i in 0..<400 {
            s.apply(.itemDelta(itemId: "tool",
                               bodyAppend: "command \(i)\n",
                               outputAppend: String(repeating: "x", count: 1_000),
                               summary: nil))
        }

        let item = s.turns[0].items[0]
        XCTAssertLessThanOrEqual(item.body.count, AssistantTimelineState.liveTextLimit,
                                 "live tool labels must be bounded so one long thread cannot freeze the transcript")
        XCTAssertLessThanOrEqual(item.output?.count ?? 0, AssistantTimelineState.liveOutputLimit,
                                 "live tool output must be bounded because expanded output is rendered on the main UI")

        s.apply(.turnCompleted(turnId: "long", finalMessage: String(repeating: "z", count: 200_000)))
        XCTAssertLessThanOrEqual(s.turns[0].finalAssistantMessage?.count ?? 0, AssistantTimelineState.liveTextLimit,
                                 "terminal live text must also stay bounded before it is moved into persisted history")
    }

    func test_timelineRetainsFullTurnHistoryForLongSessions() {
        var s = AssistantTimelineState()

        // A long-but-realistic session (140 turns) must be retained IN FULL — reopening a
        // thread used to truncate to the last 80 turns ("thread cortado"); the cap is now a
        // pathological-OOM ceiling (>= the ~5000 DB event-prune cap), not a display window.
        for i in 0..<140 {
            let turn = "turn-\(i)"
            let item = "item-\(i)"
            s.apply(.turnStarted(turnId: turn))
            s.apply(.itemStarted(item: AssistantItem(id: item, turnId: turn, type: .assistantMessage, startedAtMs: Int64(i))))
            s.apply(.itemDelta(itemId: item, bodyAppend: "answer \(i)", outputAppend: nil, summary: nil))
            s.apply(.turnCompleted(turnId: turn, finalMessage: "answer \(i)"))
        }

        XCTAssertEqual(s.turns.count, 140,
                       "every turn of a long session must be retained — no 80-turn truncation of the reopened thread")
        XCTAssertEqual(s.turns.first?.turnId, "turn-0",
                       "the OLDEST turn must still be present (the thread is shown 100%, not from the middle)")
        XCTAssertEqual(s.latestAssistantMessage, "answer 139",
                       "the newest agent output stays visible")
        XCTAssertLessThanOrEqual(s.turns.count, AssistantTimelineState.liveTurnLimit,
                                 "the memory-ceiling backstop still bounds turns")
    }

    // Structured AskUserQuestion requests are persisted (callback snapshot) and
    // restored across app restarts — the questions/options/per-question multiSelect
    // must survive the Codable round-trip, and legacy rows without `questions` must
    // still decode (version-skew safe).
    func test_structuredUserInputRequestCodableRoundTrip() throws {
        let request = AssistantUserInputRequest(
            id: "ask-1",
            turnId: "turn-1",
            prompt: "Framework: pick one",
            questions: [
                AssistantUserInputQuestion(
                    id: "0",
                    prompt: "Pick the framework?",
                    header: "Framework",
                    options: [
                        AssistantUserInputOption(label: "SwiftUI", detail: "Declarative"),
                        AssistantUserInputOption(label: "AppKit", detail: "Imperative"),
                    ],
                    allowsMultipleSelection: false
                ),
                AssistantUserInputQuestion(
                    id: "1",
                    prompt: "Targets?",
                    header: "Targets",
                    options: [AssistantUserInputOption(label: "macOS")],
                    allowsMultipleSelection: true
                ),
            ],
            createdAtMs: 1
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(AssistantUserInputRequest.self, from: data)
        XCTAssertEqual(decoded.questions.count, 2,
                       "structured questions must survive persistence so a restored card still renders")
        XCTAssertEqual(decoded.questions.map(\.id), ["0", "1"],
                       "position-stable question ids must round-trip so duplicate prompts stay distinct")
        XCTAssertEqual(decoded.questions.first?.options.map(\.label), ["SwiftUI", "AppKit"])
        XCTAssertEqual(decoded.questions.first?.options.first?.detail, "Declarative")
        XCTAssertEqual(decoded.questions.last?.allowsMultipleSelection, true)
        XCTAssertTrue(decoded.isStructured)
        let duplicate = AssistantUserInputQuestion(
            id: "dup",
            prompt: "Choose",
            options: [
                AssistantUserInputOption(label: "Yes"),
                AssistantUserInputOption(label: "Yes"),
            ]
        )
        XCTAssertEqual(
            duplicate.identifiedOptions.map(\.id),
            ["dup#0#Yes", "dup#1#Yes"],
            "duplicate option labels must still get unique SwiftUI identities"
        )
        let legacyDup = AssistantUserInputRequest(
            id: "q",
            turnId: "t",
            prompt: "Pick",
            options: ["Yes", "Yes"],
            createdAtMs: 1
        )
        XCTAssertEqual(
            legacyDup.identifiedOptions.map(\.id),
            ["q#0#Yes", "q#1#Yes"],
            "legacy flat options with duplicate labels must still get unique SwiftUI identities"
        )

        // Legacy / version-skew payload with no `questions` key decodes to a plain
        // free-text request, not a decode failure.
        let legacy = #"{"id":"q","turnId":"t","prompt":"Branch?","createdAtMs":1}"#
        let legacyDecoded = try JSONDecoder().decode(AssistantUserInputRequest.self, from: Data(legacy.utf8))
        XCTAssertTrue(legacyDecoded.questions.isEmpty)
        XCTAssertFalse(legacyDecoded.isStructured)
    }

    func test_timelineTracksApprovalsUserInputPlansAndTokenUsage() {
        var s = AssistantTimelineState()
        s.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run tests",
            detail: "swift test",
            createdAtMs: 1
        )))
        s.apply(.userInputRequested(AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Pick mode",
            options: ["Plan", "Run"],
            createdAtMs: 2
        )))
        s.apply(.proposedPlan(AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")))
        s.apply(.tokenUsage(AssistantTokenUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15, contextWindow: 100, compactsAutomatically: true)))
        s.apply(.contextCompaction(summary: "older messages compacted"))
        s.apply(.requestResolved(requestId: "approval-1", state: .approved))
        s.apply(.userInputResolved(requestId: "question-1", answer: "Run"))

        XCTAssertEqual(s.pendingRequests.first?.state, .approved,
                       "approval state must persist in the timeline so stale requests can be diagnosed after restart")
        XCTAssertEqual(s.pendingUserInputs.first?.answer, "Run",
                       "user-input answers must remain associated with their provider request id")
        XCTAssertEqual(s.proposedPlans.first?.markdown, "1. Inspect\n2. Patch",
                       "provider plan artifacts must be structured, not only assistant text")
        XCTAssertEqual(s.tokenUsage?.totalTokens, 15,
                       "token usage must be tracked for long-running context health")
        XCTAssertEqual(s.tokenUsage?.compactsAutomatically, true,
                       "automatic compaction capability must stay attached to token usage telemetry")
        XCTAssertEqual(s.contextCompactionSummary, "older messages compacted")
    }

    func test_liveTimelineCapsRequestAndPlanDiagnosticsForLongAgentSessions() {
        var s = AssistantTimelineState()

        for i in 0..<(AssistantTimelineState.pendingRequestLimit + 40) {
            s.apply(.requestOpened(AssistantPendingRequest(
                id: "approval-\(i)",
                turnId: "turn-\(i)",
                kind: .commandExecution,
                title: "Run \(i)",
                detail: String(repeating: "x", count: 1_000),
                createdAtMs: Int64(i)
            )))
            s.apply(.requestResolved(requestId: "approval-\(i)", state: .approved))
            s.apply(.userInputRequested(AssistantUserInputRequest(
                id: "question-\(i)",
                turnId: "turn-\(i)",
                prompt: "Question \(i)",
                createdAtMs: Int64(i)
            )))
            s.apply(.userInputResolved(requestId: "question-\(i)", answer: "Answer \(i)"))
        }
        for i in 0..<(AssistantTimelineState.proposedPlanLimit + 20) {
            s.apply(.proposedPlan(AssistantProposedPlan(
                id: "plan-\(i)",
                turnId: "turn-\(i)",
                markdown: "Plan \(i)"
            )))
        }

        XCTAssertLessThanOrEqual(s.pendingRequests.count, AssistantTimelineState.pendingRequestLimit,
                                 "resolved approval diagnostics must be bounded so a 24h Agent App run cannot retain every callback card")
        XCTAssertFalse(s.pendingRequests.contains { $0.id == "approval-0" },
                       "bounded approval diagnostics must evict the oldest resolved callbacks first")
        XCTAssertEqual(s.pendingRequests.last?.id, "approval-\(AssistantTimelineState.pendingRequestLimit + 39)",
                       "bounded approval diagnostics must keep the newest callback visible")
        XCTAssertLessThanOrEqual(s.pendingUserInputs.count, AssistantTimelineState.pendingRequestLimit,
                                 "resolved user-input diagnostics must be bounded for long provider sessions")
        XCTAssertFalse(s.pendingUserInputs.contains { $0.id == "question-0" },
                       "bounded question diagnostics must evict the oldest resolved callbacks first")
        XCTAssertEqual(s.pendingUserInputs.last?.id, "question-\(AssistantTimelineState.pendingRequestLimit + 39)")
        XCTAssertLessThanOrEqual(s.proposedPlans.count, AssistantTimelineState.proposedPlanLimit,
                                 "proposed plans must not accumulate forever in the live Agent App timeline")
        XCTAssertFalse(s.proposedPlans.contains { $0.id == "plan-0" },
                       "bounded plan diagnostics must evict oldest plan artifacts first")
        XCTAssertEqual(s.proposedPlans.last?.id, "plan-\(AssistantTimelineState.proposedPlanLimit + 19)")
    }

    func test_activePlanTracksStepStateSeparatelyFromProposedPlan() {
        var s = AssistantTimelineState()
        s.apply(.proposedPlan(AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")))
        s.apply(.activePlanUpdated(AssistantActivePlan(
            explanation: "Executing plan",
            steps: [
                AssistantPlanStep(id: "step-1", title: "Inspect", status: .completed),
                AssistantPlanStep(id: "step-2", title: "Patch", status: .inProgress),
                AssistantPlanStep(id: "step-3", title: "Verify", status: .pending)
            ],
            updatedAtMs: 42
        )))

        XCTAssertEqual(s.proposedPlans.first?.id, "plan-1",
                       "proposed plans must remain durable artifacts for implementation, not be overwritten by transient step progress")
        XCTAssertEqual(s.activePlan?.steps.map(\.status), [.completed, .inProgress, .pending],
                       "active plan updates must preserve step state so long-running /goal work exposes current progress")
    }

    func test_finalAssistantMessageClearsTransientActivePlanButKeepsProposedPlanArtifact() {
        var s = AssistantTimelineState()
        s.apply(.proposedPlan(AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")))
        s.apply(.activePlanUpdated(AssistantActivePlan(
            explanation: "Executing plan",
            steps: [AssistantPlanStep(id: "step-1", title: "Verify", status: .completed)],
            updatedAtMs: 42
        )))

        s.apply(.turnCompleted(turnId: "turn-1", finalMessage: "Done."))

        XCTAssertNil(s.activePlan,
                     "once the assistant final message arrives, the active progress plan is stale and must leave the transcript bottom")
        XCTAssertEqual(s.proposedPlans.first?.id, "plan-1",
                       "clearing transient progress must not delete the durable proposed-plan artifact")
    }

    func test_richItemTypesRemainDistinct() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn"))
        for type in [AssistantItemType.commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .imageView, .review, .contextCompaction, .error] {
            s.apply(.itemStarted(item: AssistantItem(id: type.rawValue, turnId: "turn", type: type, startedAtMs: 1)))
        }

        XCTAssertEqual(s.turns[0].items.map(\.type), [.commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .imageView, .review, .contextCompaction, .error],
                       "provider runtime items must not collapse into one generic tool bucket because UI/mobile need distinct rendering and replay")
    }

    func test_providerRuntimeEventsPreserveRawProviderRefsAndPayload() {
        let line = #"{"type":"item.completed","turn_id":"turn-native","item":{"id":"item-native","type":"agent_message","text":"hi"}}"#
        guard let runtime = ProviderRuntimeEvent.fromJSONLine(line, provider: .codex, source: "codex.exec.json", receivedAtMs: 7) else {
            return XCTFail("raw provider JSON lines must become canonical runtime events")
        }

        var s = AssistantTimelineState()
        s.apply(.providerRuntime(runtime))

        XCTAssertEqual(s.providerRuntimeEvents.first?.method, "item.completed")
        XCTAssertEqual(s.providerRuntimeEvents.first?.providerTurnId, "turn-native",
                       "native provider turn id must survive normalized conversion for read/rollback/debug parity")
        XCTAssertEqual(s.providerRuntimeEvents.first?.providerItemId, "item-native",
                       "native provider item id must survive normalized conversion for tool/content traceability")
        XCTAssertTrue(s.providerRuntimeEvents.first?.payloadJSON.contains(#""agent_message""#) == true,
                      "canonical runtime events must keep the raw payload so unknown Codex/Claude fields are not lost")
    }

    func test_tokenRateStreamObjectsSkipProviderRuntimeConstruction() {
        // WHY: fromJSONObjectIfNeeded must refuse token-rate types before
        // JSONSerialization.data(.sortedKeys). fromJSONObject stays available
        // for tests/debug reconstruction of those same payloads.
        XCTAssertNil(ProviderRuntimeEvent.fromJSONObjectIfNeeded(
            ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hi"]],
            provider: .claude,
            source: "claude.stream-json",
            receivedAtMs: 1
        ))
        XCTAssertNil(ProviderRuntimeEvent.fromJSONObjectIfNeeded(
            ["type": "item.delta", "item_id": "i1", "body_delta": "Hi"],
            provider: .codex,
            source: "codex.exec.json",
            receivedAtMs: 1
        ))
        XCTAssertNil(ProviderRuntimeEvent.fromJSONObjectIfNeeded(
            [
                "type": "stream_event",
                "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hi"]],
            ],
            provider: .claude,
            source: "claude.agent-sdk",
            receivedAtMs: 1
        ))
        let lifecycle = ProviderRuntimeEvent.fromJSONObjectIfNeeded(
            ["type": "system", "subtype": "init"],
            provider: .claude,
            source: "claude.stream-json",
            receivedAtMs: 1
        )
        XCTAssertEqual(lifecycle?.method, "system")
        XCTAssertNotNil(ProviderRuntimeEvent.fromJSONObject(
            ["type": "content_block_delta"],
            provider: .claude,
            source: "debug",
            receivedAtMs: 1
        ), "debug reconstruction of a skipped type must still work via fromJSONObject")
    }

    func test_workActivitiesSummarizeToolRequestAndRuntimeProgress() {
        let runtime = ProviderRuntimeEvent(
            id: "runtime-1",
            provider: .codex,
            source: "codex.exec.json",
            method: "item.started",
            providerTurnId: "turn-native",
            providerItemId: "item-native",
            payloadJSON: #"{"type":"item.started"}"#,
            receivedAtMs: 3
        )
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn-1"))
        s.apply(.itemStarted(item: AssistantItem(
            id: "tool-1",
            turnId: "turn-1",
            type: .commandExecution,
            summary: "swift test",
            startedAtMs: 1
        )))
        s.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run tests",
            detail: "swift test",
            createdAtMs: 2
        )))
        s.apply(.providerRuntime(runtime))
        s.apply(.itemCompleted(itemId: "tool-1", finalState: .completed))

        XCTAssertTrue(s.workActivities.contains { $0.id == "item:tool-1" && $0.state == "completed" },
                      "work log must expose tool progress without forcing users to inspect raw provider output")
        XCTAssertTrue(s.workActivities.contains { $0.id == "request:approval-1" && $0.title.contains("Approval requested") },
                      "work log must include approval/request progress because pending cards can move or become stale")
        XCTAssertTrue(s.workActivities.contains { $0.id == "runtime:runtime-1" && $0.title.contains("item.started") },
                      "work log must include raw provider runtime events so unknown Codex/Claude progress remains visible")
    }

    func test_workActivityStripsReceiptOnlyAfterHostAttestation() {
        // WHY: Work log is a second presentation of tool output. It must hide
        // authenticated protocol metadata without also hiding provider text that
        // merely resembles a receipt.
        let marker = "[[rcd:v1.abcdefghijklmnopqrstuv]]"
        let wire = "compressed\n\(marker)"
        var state = AssistantTimelineState()
        state.apply(.itemStarted(item: AssistantItem(
            id: "trusted", turnId: "turn", type: .tool,
            state: .completed, output: wire, startedAtMs: 1
        )))
        XCTAssertEqual(state.workActivities.last?.detail, wire,
                       "receipt-shaped provider text stays visible before host truth")

        state.apply(.itemHostMetadata(
            turnId: "turn", itemId: "trusted", distillApplied: true
        ))
        XCTAssertEqual(state.workActivities.last?.detail, "compressed",
                       "host truth refreshes the Work log without the receipt")

        state.apply(.itemStarted(item: AssistantItem(
            id: "spoof", turnId: "turn", type: .tool,
            state: .completed, output: wire, startedAtMs: 2
        )))
        XCTAssertEqual(state.workActivities.last?.detail, wire,
                       "an unattested lookalike must remain byte-visible")
    }

    /// Grok (and Claude) stream one NDJSON line per token. Surfacing every
    /// `thought`/`text` as a Work log row puts a flickering "runtime: thought"
    /// strip *above* the user message and rewrites it on every token.
    func test_tokenStreamRuntimeEventsDoNotFloodWorkLog() {
        var s = AssistantTimelineState()
        for i in 0..<12 {
            s.apply(.providerRuntime(ProviderRuntimeEvent(
                id: "tok-\(i)",
                provider: .grok,
                source: "grok.streaming-json",
                method: i.isMultiple(of: 2) ? "thought" : "text",
                payloadJSON: #"{"type":"thought","data":"x"}"#,
                receivedAtMs: Int64(i)
            )))
        }
        s.apply(.providerRuntime(ProviderRuntimeEvent(
            id: "end-1",
            provider: .grok,
            source: "grok.streaming-json",
            method: "end",
            payloadJSON: #"{"type":"end"}"#,
            receivedAtMs: 99
        )))

        XCTAssertFalse(s.workActivities.contains { $0.id.hasPrefix("runtime:tok-") },
                       "per-token runtime activities must be suppressed so Work log stays tool/lifecycle oriented")
        XCTAssertTrue(s.workActivities.contains { $0.id == "runtime:end-1" && $0.title.contains("end") },
                      "lifecycle events like end must still surface in the Work log")
        XCTAssertEqual(s.providerRuntimeEvents.count, 13,
                       "raw runtime buffer still keeps stream events for debug/replay; only the Work log is filtered")
    }

    func test_turnStartedRecordsStartedAtMsForTranscriptOrdering() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn-live"))
        let started = s.turns.first?.startedAtMs
        XCTAssertNotNil(started, "empty turns need a start timestamp so they do not sort at epoch 0 before the user message")
        XCTAssertGreaterThan(started ?? 0, 0)
    }

    func test_workActivitiesTrackProviderPercentProgress() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn-1"))
        s.apply(.itemStarted(item: AssistantItem(
            id: "tool-1",
            turnId: "turn-1",
            type: .commandExecution,
            summary: "swift test",
            startedAtMs: 1
        )))
        s.apply(.itemProgress(itemId: "tool-1", progress: 42))

        XCTAssertEqual(s.turns.first?.items.first?.progress, 0.42,
                       "provider progress may arrive as 0-1 or 0-100 and must normalize before rendering")
        XCTAssertTrue(s.workActivities.last?.title.contains("42% swift test") == true,
                      "work log must expose current percent progress for long-running provider tools")
    }

    // REGRESSION (Agent App CPU ramp / freeze on long runs): every streamed
    // itemDelta calls mutateItem, which located the target item with a scan over
    // EVERY turn*item. The streaming item is appended last, so each token re-scanned
    // the whole accumulated timeline => O(items^2) per session on the main actor.
    // CPU ramped with transcript size and froze long workflows; pressing Stop ended
    // the delta stream and relieved it instantly. This asserts per-delta lookup cost
    // stays bounded regardless of how many items have accumulated — it FAILS on the
    // old whole-timeline scan and PASSES once the lookup targets the active item.
    func test_streamingDeltasToActiveItemStayBoundedRegardlessOfAccumulatedItems() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "run"))

        // A long workflow piles up hundreds/thousands of completed items before the
        // final answer streams. The active (streaming) item is started LAST.
        let priorItems = 3_000
        for i in 0..<priorItems {
            let id = "item-\(i)"
            s.apply(.itemStarted(item: AssistantItem(id: id, turnId: "run", type: .tool, startedAtMs: Int64(i))))
            s.apply(.itemCompleted(itemId: id, finalState: .completed))
        }
        let activeId = "answer"
        s.apply(.itemStarted(item: AssistantItem(id: activeId, turnId: "run", type: .assistantMessage, startedAtMs: Int64(priorItems))))

        // Measure ONLY the streaming deltas (setup scans are excluded by the reset).
        AssistantTimelineState.itemLookupComparisonsForTesting = 0
        let deltas = 2_000
        for i in 0..<deltas {
            s.apply(.itemDelta(itemId: activeId, bodyAppend: "tok\(i) ", outputAppend: nil, summary: nil))
        }
        let comparisons = AssistantTimelineState.itemLookupComparisonsForTesting

        // Bound: per-delta lookup must be O(1) in the accumulated item count. The old
        // forward scan costs ~deltas*(priorItems+1) (~6M here); the fix costs ~deltas.
        XCTAssertLessThanOrEqual(comparisons, deltas * 3,
                                 "per-delta item lookup must not scale with accumulated timeline size (was O(items^2)/session, the long-run CPU ramp)")

        // Intent: the deltas actually landed on the active item, and no earlier item
        // was touched — the bound must not be met by skipping/misrouting work.
        XCTAssertEqual(s.turns.count, 1)
        XCTAssertEqual(s.turns[0].items.count, priorItems + 1)
        XCTAssertEqual(s.turns[0].items.last?.id, activeId)
        XCTAssertTrue(s.turns[0].items.last?.body.hasPrefix("tok0 ") == true)
        XCTAssertTrue(s.turns[0].items.last?.body.hasSuffix("tok\(deltas - 1) ") == true)
        XCTAssertEqual(s.turns[0].items.first?.body, "",
                       "an accumulated earlier item must not be mutated by the active item's deltas")
    }

    // History replay / progress / deltas targeting OLDER items used to newest-first
    // scan from the live end, so an item near the start of a 3k-item turn cost ~N
    // comparisons per event (~O(N·M) on the main actor at the prune cap). The
    // incremental id→location map inside AssistantTimelineState must keep that
    // path at the same O(1) bound as the active-item test, without rebuilding a
    // view-model TimelineItemIndex (AA-29).
    func test_streamingDeltasToNonActiveItemStayBoundedRegardlessOfAccumulatedItems() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "run"))

        let priorItems = 3_000
        for i in 0..<priorItems {
            let id = "item-\(i)"
            s.apply(.itemStarted(item: AssistantItem(id: id, turnId: "run", type: .tool, startedAtMs: Int64(i))))
            s.apply(.itemCompleted(itemId: id, finalState: .completed))
        }

        let targetId = "item-0"
        AssistantTimelineState.itemLookupComparisonsForTesting = 0
        let deltas = 2_000
        for i in 0..<deltas {
            s.apply(.itemDelta(itemId: targetId, bodyAppend: "tok\(i) ", outputAppend: nil, summary: nil))
        }
        let comparisons = AssistantTimelineState.itemLookupComparisonsForTesting

        XCTAssertLessThanOrEqual(comparisons, deltas * 3,
                                 "non-active item lookup must not scale with accumulated timeline size (was ~distance-from-end comparisons per event)")

        XCTAssertEqual(s.turns.count, 1)
        XCTAssertEqual(s.turns[0].items.count, priorItems)
        XCTAssertEqual(s.turns[0].items.first?.id, targetId)
        XCTAssertTrue(s.turns[0].items.first?.body.hasPrefix("tok0 ") == true)
        XCTAssertTrue(s.turns[0].items.first?.body.hasSuffix("tok\(deltas - 1) ") == true)
        XCTAssertEqual(s.turns[0].items.last?.body, "",
                       "a later item must not be mutated by an earlier item's deltas")
    }

    func test_decodedTimelineNonActiveDeltasStayBounded() throws {
        // WHY: the location map is excluded from Codable. Reopen/decode must
        // rebuild it; otherwise history replay falls back to the O(N) scan.
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "run"))
        let priorItems = 400
        for i in 0..<priorItems {
            s.apply(.itemStarted(item: AssistantItem(id: "item-\(i)", turnId: "run", type: .tool, startedAtMs: Int64(i))))
        }
        let data = try JSONEncoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("itemLocations"),
                       "the derived location map must not be persisted")
        XCTAssertFalse(json.contains("turnLocations"),
                       "the derived turn index must not be persisted")
        let decoded = try JSONDecoder().decode(AssistantTimelineState.self, from: data)
        XCTAssertEqual(decoded, s,
                       "semantic equality ignores derived maps; decode rebuild keeps lookups O(1)")
        XCTAssertEqual(decoded.turns.count, s.turns.count)
        XCTAssertEqual(decoded.turns[0].items.count, priorItems)

        var replayed = decoded
        AssistantTimelineState.itemLookupComparisonsForTesting = 0
        let deltas = 200
        for i in 0..<deltas {
            replayed.apply(.itemDelta(itemId: "item-0", bodyAppend: "x\(i)", outputAppend: nil, summary: nil))
        }
        XCTAssertLessThanOrEqual(
            AssistantTimelineState.itemLookupComparisonsForTesting,
            deltas * 3,
            "decode must rebuild the item location map so reopen does not re-scan the timeline"
        )
        XCTAssertTrue(replayed.turns[0].items.first?.body.hasPrefix("x0") == true)
        XCTAssertEqual(replayed.turns[0].items.last?.body, "")
    }

    func test_equalityIgnoresDerivedLocationMaps() throws {
        // WHY: synthesized Equatable would treat an empty map and a rebuilt map
        // as unequal even when public/persisted timeline state matches.
        var live = AssistantTimelineState()
        live.apply(.turnStarted(turnId: "t"))
        live.apply(.itemStarted(item: AssistantItem(id: "same", turnId: "t", type: .tool, startedAtMs: 1)))
        let decoded = try JSONDecoder().decode(
            AssistantTimelineState.self,
            from: try JSONEncoder().encode(live)
        )
        XCTAssertEqual(live, decoded)
        var emptyMaps = decoded
        // Force a semantic-equal twin via decode of the same bytes again.
        let again = try JSONDecoder().decode(
            AssistantTimelineState.self,
            from: try JSONEncoder().encode(emptyMaps)
        )
        XCTAssertEqual(decoded, again)
    }

    func test_turnScopedLookupDoesNotPoisonNewestOccurrenceMap() {
        // WHY: a reused provider item id's late turn-scoped host-metadata on an
        // older turn must not redirect subsequent unscoped deltas away from the
        // newest occurrence (newest-first contract).
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "old"))
        s.apply(.itemStarted(item: AssistantItem(id: "reused", turnId: "old", type: .tool, startedAtMs: 1)))
        s.apply(.turnStarted(turnId: "new"))
        s.apply(.itemStarted(item: AssistantItem(id: "reused", turnId: "new", type: .tool, startedAtMs: 2)))

        // Turn-scoped mutate of the older occurrence (host-metadata style).
        s.apply(.itemHostMetadata(turnId: "old", itemId: "reused", distillApplied: true, attestation: nil))
        s.apply(.itemDelta(itemId: "reused", bodyAppend: "NEW", outputAppend: nil, summary: nil))

        XCTAssertEqual(
            s.turns.last?.items.last(where: { $0.id == "reused" })?.body,
            "NEW",
            "unscoped delta must still target the newest occurrence after turn-scoped metadata"
        )
        XCTAssertEqual(
            s.turns.first?.items.first(where: { $0.id == "reused" })?.body,
            "",
            "older occurrence must not absorb the unscoped delta"
        )
    }

    // Lookup correctness: the active-item fast path must still resolve a delta to its
    // OWN item even when newer items have started after it (e.g. trailing tool output
    // arriving after the next item began). Guards the newest-first lookup change.
    func test_itemDeltaResolvesToItsOwnItemEvenAfterNewerItemsStarted() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "t"))
        s.apply(.itemStarted(item: AssistantItem(id: "a", turnId: "t", type: .tool, startedAtMs: 1)))
        s.apply(.itemStarted(item: AssistantItem(id: "b", turnId: "t", type: .tool, startedAtMs: 2)))
        s.apply(.itemStarted(item: AssistantItem(id: "c", turnId: "t", type: .assistantMessage, startedAtMs: 3)))

        s.apply(.itemDelta(itemId: "a", bodyAppend: "A-body", outputAppend: nil, summary: nil))
        s.apply(.itemDelta(itemId: "c", bodyAppend: "C-body", outputAppend: nil, summary: nil))

        let items = s.turns[0].items
        XCTAssertEqual(items.first(where: { $0.id == "a" })?.body, "A-body",
                       "a delta must mutate its own item even when newer items exist, not just the most-recent item")
        XCTAssertEqual(items.first(where: { $0.id == "c" })?.body, "C-body")
        XCTAssertEqual(items.first(where: { $0.id == "b" })?.body, "",
                       "an unrelated item must never be mutated by another item's delta")
    }

    // F11: `cappedText` is on the thread-load + per-streaming-delta hot path. The byte
    // fast path must skip the O(n) grapheme walk for the common under-limit case while
    // still capping correctly (and identically) when the byte length exceeds the limit.
    func test_cappedText_skipsGraphemeWalkForShortStringsViaByteFastPath() {
        AssistantTimelineState.cappedTextGraphemeWalksForTesting = 0
        let underLimit = String(repeating: "a", count: 1_000)
        XCTAssertEqual(AssistantTimelineState.cappedText(underLimit, limit: 80_000), underLimit)
        XCTAssertEqual(AssistantTimelineState.cappedTextGraphemeWalksForTesting, 0,
                       "under-limit text must take the O(1) byte fast path, never the O(n) grapheme-count walk that ramped CPU on long-thread load/streaming")

        AssistantTimelineState.cappedTextGraphemeWalksForTesting = 0
        let capped = AssistantTimelineState.cappedText(String(repeating: "b", count: 10), limit: 4)
        XCTAssertEqual(capped, "bbbb", "over-limit ASCII must keep the last `limit` characters")
        XCTAssertEqual(AssistantTimelineState.cappedTextGraphemeWalksForTesting, 1,
                       "only over-byte-limit text should reach the grapheme walk")
    }

    func test_cappedText_preservesGraphemeCapForMultibyteAndEmoji() {
        // 5 graphemes but >5 UTF-8 bytes: the byte fast path must NOT over-truncate a
        // string whose grapheme count is within the limit.
        let multibyte = "héllo"
        XCTAssertGreaterThan(multibyte.utf8.count, 5)
        XCTAssertEqual(AssistantTimelineState.cappedText(multibyte, limit: 5), multibyte,
                       "capping must stay grapheme-based; a string within the grapheme limit is returned whole")
        // Multi-scalar emoji graphemes still cap by grapheme suffix, not by bytes.
        XCTAssertEqual(AssistantTimelineState.cappedText("😀😀😀😀", limit: 2), "😀😀")
    }

    // F10: when turns are evicted past `liveTurnLimit`, wire translations keyed on
    // the dropped turns' items must be pruned so the maps don't retain pre-translation
    // text for turns that no longer exist. Retained turns keep their translations.
    func test_trimTurns_prunesOrphanedItemTranslationsForEvictedTurns() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn-old"))
        s.apply(.itemStarted(item: AssistantItem(id: "old-item", turnId: "turn-old", type: .tool, startedAtMs: 0)))
        s.apply(.wireTranslation(AssistantWireTranslation(itemId: "old-item", originalText: "orig", rewrittenText: "rw")))
        XCTAssertNotNil(s.sr1TranslationsByItemId["old-item"])

        // Push the oldest turn out of the live window.
        let extra = AssistantTimelineState.liveTurnLimit + 1
        for i in 0..<extra { s.apply(.turnStarted(turnId: "turn-\(i)")) }
        // A retained (recent) turn with a translation that must survive.
        s.apply(.itemStarted(item: AssistantItem(id: "new-item", turnId: "turn-\(extra - 1)", type: .tool, startedAtMs: 1)))
        s.apply(.wireTranslation(AssistantWireTranslation(itemId: "new-item", originalText: "o2", rewrittenText: "r2")))

        XCTAssertEqual(s.turns.count, AssistantTimelineState.liveTurnLimit,
                       "turns stay bounded by liveTurnLimit")
        XCTAssertFalse(s.turns.contains { $0.turnId == "turn-old" }, "oldest turn was evicted")
        XCTAssertNil(s.sr1TranslationsByItemId["old-item"],
                     "translation keyed on an evicted turn's item must be pruned, not leaked")
        XCTAssertNotNil(s.sr1TranslationsByItemId["new-item"],
                        "translation for a retained turn's item must survive trimming")
    }

    // F10: a single turn's `items` array stays bounded by `liveTurnItemLimit`.
    // items[0] is the transcript sort anchor and is intentionally retained;
    // oldest non-anchor items in the rest are dropped; newest kept; wire metadata pruned.
    func test_trimTurnItems_boundsSingleTurnItemsAndPrunesTranslations() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "t"))
        s.apply(.itemStarted(item: AssistantItem(id: "anchor", turnId: "t", type: .tool, startedAtMs: 0)))
        s.apply(.itemStarted(item: AssistantItem(id: "victim", turnId: "t", type: .tool, startedAtMs: 1)))
        s.apply(.wireTranslation(AssistantWireTranslation(itemId: "victim", originalText: "o", rewrittenText: "r")))

        // anchor + victim + (limit - 1) more = limit + 1 → trims one non-anchor.
        let extra = AssistantTimelineState.liveTurnItemLimit - 1
        for i in 0..<extra {
            s.apply(.itemStarted(item: AssistantItem(id: "item-\(i)", turnId: "t", type: .tool, startedAtMs: Int64(i + 2))))
        }

        XCTAssertEqual(s.turns[0].items.count, AssistantTimelineState.liveTurnItemLimit,
                       "one turn's items must stay bounded by liveTurnItemLimit")
        XCTAssertTrue(s.turns[0].items.contains { $0.id == "anchor" },
                      "items[0] sort-anchor must survive trimTurnItems")
        XCTAssertFalse(s.turns[0].items.contains { $0.id == "victim" },
                       "oldest non-anchor item is trimmed when the per-turn cap is exceeded")
        XCTAssertTrue(s.turns[0].items.contains { $0.id == "item-\(extra - 1)" },
                      "the newest item (the active streaming target) is always retained")
        XCTAssertNil(s.sr1TranslationsByItemId["victim"],
                     "a trimmed item's translation must be pruned with it")
    }

    // MARK: - PERF 2026-08-05 appendCapped

    func test_appendCapped_matchesCappedPlusSemantics() {
        var target = "hello"
        AssistantTimelineState.appendCapped(&target, append: " world", limit: 80)
        XCTAssertEqual(target, "hello world")

        var over = String(repeating: "a", count: 8)
        AssistantTimelineState.appendCapped(&over, append: "bbbb", limit: 8)
        XCTAssertEqual(over, AssistantTimelineState.cappedText(String(repeating: "a", count: 8) + "bbbb", limit: 8))
    }

    /// Microbench: growing body via + vs appendCapped (n=5 medians).
    ///
    /// Scope: the timeline `itemDelta` shape only — a directly-owned `var body`.
    /// The coordinator wire hold buffer keeps its entry inside a dictionary, where
    /// copy-on-write aliasing changes the result, so it is measured separately by
    /// `test_microbench_wireHoldBuffer_inPlaceDictionaryAppendBeatsCopyOut`.
    func test_microbench_itemDeltaAppend_appendCappedFasterThanPlusRebuild() {
        let token = String(repeating: "x", count: 32)
        let deltas = 4_000
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        func timePlus() -> Double {
            var body = ""
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<deltas {
                body = AssistantTimelineState.cappedText(body + token, limit: 200_000)
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(body.utf8.count, min(200_000, deltas * token.utf8.count))
            return Double(end - start) / 1_000_000.0
        }

        func timeAppend() -> Double {
            var body = ""
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<deltas {
                AssistantTimelineState.appendCapped(&body, append: token, limit: 200_000)
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(body.utf8.count, min(200_000, deltas * token.utf8.count))
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup { _ = timePlus(); _ = timeAppend() }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timePlus())
            after.append(timeAppend())
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] itemDeltaAppend plus_ms=%@ append_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 5.0,
            "appendCapped must improve median wall time by ≥5% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
    }

    /// WHY: `AgentRunCoordinator.interceptProviderTextEvent` keeps the wire hold
    /// buffer inside `bufferedProviderTextItems[runId][itemId]`. Copying the entry
    /// out (`if var buffered = runBuffers[itemId]`) before appending leaves the
    /// String storage referenced by both the copy and the dictionary, so
    /// copy-on-write reallocates the whole accumulated body on every token —
    /// appendCapped alone does not remove the O(n)-per-token cost there. This pins
    /// that the coordinator must append *through* the dictionary subscripts, which
    /// is the shape shipped at AgentRunCoordinator.swift interceptProviderTextEvent.
    ///
    /// Measured at two sizes so the reported win is attributable to copy-on-write
    /// elimination (an O(n)-per-token cost that must grow with buffer size) rather
    /// than to the two dictionary write-backs the in-place shape also removes (a
    /// fixed O(1) cost per token, which would show a flat ratio).
    ///
    /// Scope: this measures the shape, on a proxy struct — the real
    /// `BufferedProviderTextItem` and `bufferedProviderTextItems` are private to
    /// `AgentRunCoordinator` and cannot be constructed from a test.
    func test_microbench_wireHoldBuffer_inPlaceDictionaryAppendBeatsCopyOut() {
        struct HoldBuffer { var text: String }
        let token = String(repeating: "x", count: 32)
        let warmup = 2
        let samples = 5
        let limit = AssistantTimelineState.liveTextLimit

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        /// Legacy shape: copy the entry out, append, write it back.
        func timeCopyOut(_ deltas: Int) -> Double {
            var outer: [String: [String: HoldBuffer]] = ["run": ["item": HoldBuffer(text: "")]]
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<deltas {
                var inner = outer["run"] ?? [:]
                if var buffered = inner["item"] {
                    AssistantTimelineState.appendCapped(&buffered.text, append: token, limit: limit)
                    inner["item"] = buffered
                    outer["run"] = inner
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(outer["run"]?["item"]?.text.utf8.count, min(limit, deltas * token.utf8.count))
            return Double(end - start) / 1_000_000.0
        }

        /// Shipped shape: resolve the outer key to an index once, then append
        /// through the dictionary storage so it stays uniquely referenced.
        func timeInPlace(_ deltas: Int) -> Double {
            var outer: [String: [String: HoldBuffer]] = ["run": ["item": HoldBuffer(text: "")]]
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<deltas {
                if let runIndex = outer.index(forKey: "run"),
                   outer.values[runIndex].index(forKey: "item") != nil {
                    AssistantTimelineState.appendCapped(
                        &outer.values[runIndex]["item"]!.text, append: token, limit: limit
                    )
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(outer["run"]?["item"]?.text.utf8.count, min(limit, deltas * token.utf8.count))
            return Double(end - start) / 1_000_000.0
        }

        // Both shapes must produce the identical buffer — this is a perf fix only.
        // Crosses the cap so the over-limit re-cap branch is covered too.
        var copyOut: [String: [String: HoldBuffer]] = ["run": ["item": HoldBuffer(text: "")]]
        var inPlace: [String: [String: HoldBuffer]] = ["run": ["item": HoldBuffer(text: "")]]
        for index in 0..<2_000 {
            let chunk = ["a", "não ", "这是", "😀", token][index % 5]
            var inner = copyOut["run"] ?? [:]
            if var buffered = inner["item"] {
                AssistantTimelineState.appendCapped(&buffered.text, append: chunk, limit: 4_000)
                inner["item"] = buffered
                copyOut["run"] = inner
            }
            if let runIndex = inPlace.index(forKey: "run"),
               inPlace.values[runIndex].index(forKey: "item") != nil {
                AssistantTimelineState.appendCapped(
                    &inPlace.values[runIndex]["item"]!.text, append: chunk, limit: 4_000
                )
            }
        }
        XCTAssertEqual(copyOut["run"]?["item"]?.text, inPlace["run"]?["item"]?.text,
                       "in-place dictionary append must be byte-identical to the copy-out shape")
        XCTAssertEqual(copyOut["run"]?["item"]?.text.count, 4_000,
                       "equivalence fixture must actually cross the cap")

        func ratio(_ deltas: Int) -> (before: Double, after: Double, improvement: Double) {
            for _ in 0..<warmup { _ = timeCopyOut(deltas); _ = timeInPlace(deltas) }
            var before: [Double] = []
            var after: [Double] = []
            for _ in 0..<samples {
                before.append(timeCopyOut(deltas))
                after.append(timeInPlace(deltas))
            }
            let beforeMed = median(before)
            let afterMed = median(after)
            return (beforeMed, afterMed, (beforeMed - afterMed) / beforeMed * 100.0)
        }

        let small = ratio(500)
        let large = ratio(4_000)
        NSLog("[perf-proof] wireHoldBuffer small_copyOut_ms=%@ small_inPlace_ms=%@ small_pct=%.2f large_copyOut_ms=%@ large_inPlace_ms=%@ large_pct=%.2f",
              String(small.before), String(small.after), small.improvement,
              String(large.before), String(large.after), large.improvement)
        XCTAssertGreaterThan(
            large.improvement, 5.0,
            "appending through the dictionary must beat copy-out by ≥5% (got \(large.improvement)%; before=\(large.before)ms after=\(large.after)ms)"
        )
        // Copy-on-write elimination is O(n) per token, so the absolute saving must
        // grow super-linearly with buffer size. A fixed per-token overhead (the two
        // removed dictionary writes) would scale ~8x for 8x the tokens; CoW removal
        // scales with the accumulated body, so require clearly more than that.
        //
        // `smallSaving` is a sub-0.1 ms quantity, so a single spiked sample in the
        // small arm could inflate it and flip this red on a loaded machine. Compare
        // against a floor as well so the ratio is only trusted when the small arm's
        // 8x projection is still comfortably below what the large arm measured.
        let smallSaving = small.before - small.after
        let largeSaving = large.before - large.after
        let projected = min(smallSaving * 8.0, small.before * 8.0)
        XCTAssertGreaterThan(
            largeSaving, projected,
            "saving must grow faster than token count (CoW elimination, not fixed overhead): small=\(smallSaving)ms large=\(largeSaving)ms projected=\(projected)ms"
        )
    }

    /// WHY: `appendCapped`'s cheap path only applies while the buffer is UNDER the
    /// limit. Once a held body saturates `liveTextLimit`, every further token takes
    /// the re-cap branch — `cappedText` walks graphemes and rebuilds the suffix —
    /// which for the wire hold path runs with the coordinator's lock held. This is
    /// not a regression (the pre-MR shape paid it on every token regardless), but
    /// the win must not be claimed for the saturated regime.
    ///
    /// Scope: this PINS the saturated behaviour and its equivalence with the
    /// rebuild path. It does NOT measure the saturated cost — the timed arms above
    /// push 128 KB against a 200_000 B limit and never cross it, so no benchmark
    /// in this suite covers the saturated regime. Adding an over-cap fast path is
    /// open follow-up work.
    func test_appendCapped_saturatedRegimeStillRecapsEveryToken() {
        let limit = 4_000
        var body = String(repeating: "a", count: limit)
        AssistantTimelineState.appendCapped(&body, append: "bcdef", limit: limit)
        XCTAssertEqual(body.count, limit, "at the cap the buffer must stay pinned to the limit")
        XCTAssertTrue(body.hasSuffix("bcdef"), "the newest tokens must survive the re-cap")
        XCTAssertFalse(body.hasPrefix("aaaaa" + "bcdef"), "the oldest bytes must be dropped")

        // Equivalence at saturation, which the growth benchmark never reaches.
        var viaAppend = String(repeating: "z", count: limit)
        var viaRebuild = String(repeating: "z", count: limit)
        for token in ["x", "não", "😀", String(repeating: "q", count: 64)] {
            AssistantTimelineState.appendCapped(&viaAppend, append: token, limit: limit)
            viaRebuild = AssistantTimelineState.cappedText(viaRebuild + token, limit: limit)
            XCTAssertEqual(viaAppend, viaRebuild,
                           "saturated appendCapped must still equal the rebuild path")
        }
    }


    /// After Retry or a new message, the previous failure must not stay on screen or come back on reload.
    func test_newTurnClearsPreviousError() {
        var s = AssistantTimelineState()
        s.apply(.error(message: "VM unavailable: Checking Docker timed out. Try again.", recoverable: true))
        XCTAssertNotNil(s.error)
        s.apply(.turnStarted(turnId: "next"))
        XCTAssertNil(s.error)
        s.apply(.error(message: "again", recoverable: true))
        XCTAssertEqual(s.error, "again")
    }
}
