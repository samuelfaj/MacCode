import XCTest
@testable import CoreModel

/// Encodes the contract for detecting an autonomous run that stalled while
/// awaiting a background job, and the bounded auto-continue decision.
///
/// WHY: a full-access run that spawns a background process (e.g. a Playwright
/// demo recording) and then ends its turn saying "Standing by for the demo
/// recording to complete." is marked `.completed` even though the task is not
/// done and nothing resumes the agent. The host must (a) recognise that stall and
/// (b) auto-nudge the agent to finish — but only for autonomous runs, only when
/// the agent really is waiting, and only a bounded number of times.
final class BackgroundAwaitContinuationTests: XCTestCase {

    // MARK: - Detector: real stall messages from the reported 114-min session.

    func test_detectsRealAwaitingBackgroundMessages() {
        // These are the verbatim trailing assistant messages from the session that
        // stalled. Each must be recognised as "waiting on a background job", or the
        // run will be silently marked completed while unfinished.
        let stalls = [
            "Standing by for the demo recording to complete.",
            "Awaiting the background completion notification.",
            "Demo recording in progress (rebuild + record). Awaiting completion notification.",
            "Build is underway (Vite rebuild). Awaiting the background completion notification.",
            "I'll await the demo recording (Vite rebuild → preview → record). Standing by for completion."
        ]
        for message in stalls {
            XCTAssertTrue(BackgroundAwaitContinuation.isAwaitingBackgroundWork(message),
                          "must detect a background-await stall: \(message)")
        }
    }

    // MARK: - Detector: the reported Claude-provider stall family.

    func test_detectsClaudeFutureTenseWaitOnAsyncJob() {
        // Verbatim (and close-variant) trailing messages from the reported Claude
        // full-access run that sat at "completed" instead of finishing: the agent
        // ended its turn saying it would *wait* (future tense, first person) on a
        // background job — a deploy poller that "notifies me" — before continuing.
        // The original detector only knew present-tense "waiting/standing by" + the
        // demo-recording vocabulary, so these slipped through and nothing auto-nudged
        // the agent to resume.
        let stalls = [
            "I'll wait for the deploy poller to complete (it notifies me), then run the summer-gate Chrome verification across multiple accounts.",
            "I'll wait for the deploy poller to complete (it notifies me), then run the Chrome verification for both flows.",
            "I'll wait for the background build to finish, then run the tests.",
            "I'm waiting for the deploy job to complete; it notifies me when it's done."
        ]
        for message in stalls {
            XCTAssertTrue(BackgroundAwaitContinuation.isAwaitingBackgroundWork(message),
                          "must detect a Claude future-tense background-await stall: \(message)")
        }
    }

    func test_doesNotAutoNudgeWhenWaitingOnTheUser() {
        // Precision guard: broadening to first-person "I'll wait" must NOT make the
        // detector fire when the agent is genuinely DONE and parked on the *human*
        // (a review, a confirmation, a copy decision). Auto-nudging these in
        // full-access mode would push the agent to act without the approval it is
        // waiting for — a worse failure than the stall this feature fixes. The
        // distinction is the absence of an agent-owned background-job noun:
        // "notify the team" (an action the agent will take) is not "it notifies me"
        // (a job signalling the agent), and a bare "...to complete the rollout" is
        // not a background job.
        let userWaits = [
            "I'll wait for you to confirm the copy before I notify the team.",
            "All set. I'll wait for your review before I run the migration to complete the rollout.",
            "Done. The PR is up; I'll wait for CI to go green and the merge to finish on your end."
        ]
        for message in userWaits {
            XCTAssertFalse(BackgroundAwaitContinuation.isAwaitingBackgroundWork(message),
                           "must NOT treat a wait-on-the-user as a background-await stall: \(message)")
        }
    }

    func test_doesNotTreatNormalFinalAnswersAsBackgroundAwait() {
        // None of these should trip the detector: a real completed answer must not
        // be auto-nudged. This is the intent that matters — the detector must key
        // on "awaiting a background job", not merely mention the word "background"
        // or end with "standing by".
        let nonStalls = [
            "All checks passed and the build is green.",
            "I ran the tests in the background earlier; everything passes.",
            "Done. The deploy is complete and verified.",
            "Standing by for your next instruction.",            // waiting on the USER, not a job
            "The recording studio booking is confirmed for Tuesday.", // 'recording' but no awaiting
            "",
            "   "
        ]
        for message in nonStalls {
            XCTAssertFalse(BackgroundAwaitContinuation.isAwaitingBackgroundWork(message),
                           "must NOT treat a normal answer as a background-await stall: \(message)")
        }
        XCTAssertFalse(BackgroundAwaitContinuation.isAwaitingBackgroundWork(nil),
                       "nil final message must not be a stall")
    }

    // MARK: - Detector: the deterministic self-declared marker (phrase-independent).

    func test_marker_detectsStallRegardlessOfPhrasing() {
        // The whole point of the marker: it makes detection work for ANY phrasing,
        // including ones no phrase list covers. This message uses vocabulary the
        // heuristic lists deliberately do not match — only the marker makes it fire.
        let novel = "Holding here until the canary bake finishes and the gate flips."
        XCTAssertFalse(BackgroundAwaitContinuation.isAwaitingBackgroundWork(novel),
                       "control: without the marker, novel phrasing is (correctly) beyond the heuristic backstop")
        XCTAssertTrue(BackgroundAwaitContinuation.isAwaitingBackgroundWork("\(BackgroundAwaitContinuation.awaitingMarker)\n\(novel)"),
                      "with the self-declared marker, the same novel phrasing must be detected deterministically")
        // Case-insensitive, and detected even when not at the very start.
        XCTAssertTrue(BackgroundAwaitContinuation.isAwaitingBackgroundWork("Done with step 1.\n\(BackgroundAwaitContinuation.awaitingMarker.lowercased()) waiting on the worker."),
                      "marker detection must be case-insensitive and position-independent")
    }

    func test_strippingAwaitingMarker_removesMarkerButKeepsTheText() {
        let raw = "\(BackgroundAwaitContinuation.awaitingMarker)\nI'll wait for the deploy poller to complete."
        let shown = BackgroundAwaitContinuation.strippingAwaitingMarker(raw)
        XCTAssertFalse(shown.contains(BackgroundAwaitContinuation.awaitingMarker),
                       "the internal marker must never survive into user-facing text")
        XCTAssertEqual(shown, "I'll wait for the deploy poller to complete.",
                       "stripping the marker must preserve the real message and tidy the leading blank line")
        // A message with no marker is returned unchanged.
        XCTAssertEqual(BackgroundAwaitContinuation.strippingAwaitingMarker("All done; build is green."),
                       "All done; build is green.")
    }

    func test_strippingAwaitingMarker_noOpPreservesNonMarkerProseVerbatim() {
        // Intent of the no-op guard: `strippingAwaitingMarker` runs on EVERY rendered
        // assistant message, so a message without the marker must pass through
        // byte-for-byte — it must NOT reflow trailing whitespace or collapse the blank
        // lines that markdown rendering depends on. Without the guard, normal prose
        // would be silently rewritten.
        let prose = "Line one.   \n\n\nLine two with trailing space.   "
        XCTAssertEqual(BackgroundAwaitContinuation.strippingAwaitingMarker(prose), prose,
                       "non-marker prose must pass through unchanged (no whitespace/newline reflow)")
    }

    func test_systemPromptDirective_namesTheExactMarker() {
        // Injection and detection must stay in lockstep: the rule we inject must ask
        // for the exact token the detector keys on, or recovery silently breaks.
        XCTAssertTrue(BackgroundAwaitContinuation.systemPromptDirective.contains(BackgroundAwaitContinuation.awaitingMarker),
                      "the injected directive must reference the exact marker the detector matches")
        XCTAssertTrue(
            BackgroundAwaitContinuation.systemPromptDirective.contains("&/nohup")
                || BackgroundAwaitContinuation.systemPromptDirective.contains("nohup"),
            "directive must enumerate shell-detached background processes"
        )
        XCTAssertTrue(
            BackgroundAwaitContinuation.systemPromptDirective.lowercased().contains("ending the turn"),
            "directive must state that ending the turn stops the agent even if it intends to keep polling"
        )
    }

    func test_claudeAlwaysOnDirectivesIncludeAIDelegationContract() {
        XCTAssertTrue(
            BackgroundAwaitContinuation.alwaysOnClaudeDirectives.contains(
                BotPeerDelegation.providerDirective
            )
        )
    }

    func test_botDelegationDirectiveSupportsIterativeMultiBotMediation() {
        let directive = BotPeerDelegation.providerDirective
        let requiredGuidance = [
            "call `bot_ask_peer` with `consult` as often as the request requires",
            "including repeatedly for the same or different Bots",
            "After each real reply, author any follow-up prompt yourself",
            "only the prior-reply context relevant to the next Bot",
            "You remain responsible for mediation and final synthesis",
            "You decide the semantic routing and sequence",
            "`reply_only` is terminal",
            "never choose it while comparison, follow-up, mediation, or synthesis remains",
        ]

        for guidance in requiredGuidance {
            XCTAssertTrue(
                directive.contains(guidance),
                "delegation directive must tell the primary AI: \(guidance)"
            )
        }
    }

    func test_commandDetachesShellWork_classifier() {
        // Shared pure classifier used by Claude / Codex / Grok adapters when a
        // foreground shell tool backgrounds children the provider will not track.
        XCTAssertTrue(BackgroundAwaitContinuation.commandDetachesShellWork("cmd &"),
                      "trailing & backgrounds")
        XCTAssertTrue(BackgroundAwaitContinuation.commandDetachesShellWork("cmd &\nPID=$!"),
                      "background + capture PID")
        XCTAssertTrue(BackgroundAwaitContinuation.commandDetachesShellWork("nohup cmd &"),
                      "nohup detaches")
        XCTAssertTrue(BackgroundAwaitContinuation.commandDetachesShellWork("cmd 2>&1 &"),
                      "redirect then background &")
        XCTAssertFalse(BackgroundAwaitContinuation.commandDetachesShellWork("a && b"),
                       "&& is not background")
        XCTAssertFalse(BackgroundAwaitContinuation.commandDetachesShellWork("cmd > f 2>&1"),
                       "2>&1 alone is not background")
        XCTAssertFalse(BackgroundAwaitContinuation.commandDetachesShellWork("cmd & wait"),
                       "wait means the shell blocked on children")
        XCTAssertFalse(BackgroundAwaitContinuation.commandDetachesShellWork("ls -la"),
                       "plain foreground command")
    }

    func test_prefixingAwaitingMarker_isIdempotentAndHandlesEmpty() {
        let marker = BackgroundAwaitContinuation.awaitingMarker
        XCTAssertEqual(BackgroundAwaitContinuation.prefixingAwaitingMarker(nil), marker)
        XCTAssertEqual(BackgroundAwaitContinuation.prefixingAwaitingMarker(""), marker)
        XCTAssertEqual(BackgroundAwaitContinuation.prefixingAwaitingMarker("done"), "\(marker)\ndone")
        // Already stamped → no double prefix (case-insensitive).
        let already = "\(marker)\nalready"
        XCTAssertEqual(BackgroundAwaitContinuation.prefixingAwaitingMarker(already), already)
        let lower = "\(marker.lowercased())\nalready"
        XCTAssertEqual(BackgroundAwaitContinuation.prefixingAwaitingMarker(lower), lower)
    }

    // MARK: - Detector: shell-detached orchestration stalls (en + pt-BR fixtures)

    /// FIXTURE A — run 2D47AD8B-600F-4604-BFA4-A91F8445BB31 (verbatim tail).
    /// Plain text has no awaiting phrase in any language; the machine marker from
    /// the adapter (shell-detach stamp) is the intended recovery path.
    private let fixtureAShellDetachedWorkersEnglish = """
    Wrapping for token efficiency. Summary of action taken:

    **LAUNCHED 2 Additional Workers:**
    - **C-02** (non-blocking socket writes) — highest-risk Wave 2 P0, critical for write failures
    - **C-03** (snapshot budget separation) — high-complexity Wave 2 P0, essential for 3G snapshots

    **TOTAL ACTIVE WORKERS:** 7 (5 from before + C-02/C-03 launching now)

    **REMAINING TOKEN BUDGET:** ~50–55k (27–28% left)

    Given token constraints, further parallel scaling will exhaust budget before completion. Current strategy maximizes the 4 core P0s:
    - ✓ C-04/C-05/C-06 (in-progress from earlier)
    - ✓ C-02/C-03 (launching now)

    When tokens near zero, I'll provide final consolidated report with all completed items.

    **Status check:** Will auto-report when C-02/C-03 complete.
    """

    /// FIXTURE B — run 57FF789A-D6A8-46D5-B266-99BEC004A8E4 (verbatim first/last).
    private let fixtureBPortuguesePollingStall = """
    5 workers still inicializando (expected, complex tasks). Aguardando com polling contínuo...

    **Token budget:** ~45-50k restantes

    🔄 **Mantendo polling ativo. Não para até terminar.**
    """

    func test_fixtureB_portuguesePolling_classifiesAsBackgroundAwait() {
        // pt-BR "Aguardando" + background noun "polling" must trip the heuristic
        // (English-only awaitingPhrases previously missed this user).
        XCTAssertTrue(
            BackgroundAwaitContinuation.isAwaitingBackgroundWork(fixtureBPortuguesePollingStall),
            "FIXTURE B must be detected via Portuguese awaiting phrases + poll noun"
        )
        XCTAssertEqual(
            IncompleteTurnContinuation.classify(fixtureBPortuguesePollingStall),
            .backgroundAwait
        )
    }

    func test_fixtureA_marked_classifiesAsBackgroundAwait_plainTextDoesNot() {
        // Plain FIXTURE A is deliberately NOT expected to trip the text-only
        // heuristic (no awaiting phrase); CHANGE 1 stamps the marker at the adapter.
        XCTAssertFalse(
            BackgroundAwaitContinuation.isAwaitingBackgroundWork(fixtureAShellDetachedWorkersEnglish),
            "plain FIXTURE A must remain outside the text-only heuristic"
        )
        XCTAssertNil(IncompleteTurnContinuation.classify(fixtureAShellDetachedWorkersEnglish))

        let marked = "\(BackgroundAwaitContinuation.awaitingMarker)\n\(fixtureAShellDetachedWorkersEnglish)"
        XCTAssertTrue(BackgroundAwaitContinuation.isAwaitingBackgroundWork(marked))
        XCTAssertEqual(IncompleteTurnContinuation.classify(marked), .backgroundAwait)
    }

    func test_portugueseUserWait_withoutBackgroundNoun_doesNotTrip() {
        // Keep the false-positive guard: Portuguese user-waits must not auto-nudge
        // full-access runs (no background noun present).
        let userWaits = [
            "Aguardando sua aprovação para continuar.",
            "Aguardando você revisar o plano antes de eu seguir."
        ]
        for message in userWaits {
            XCTAssertFalse(
                BackgroundAwaitContinuation.isAwaitingBackgroundWork(message),
                "must NOT treat a Portuguese user-wait as background-await: \(message)"
            )
            XCTAssertNil(
                IncompleteTurnContinuation.classify(message),
                "must not classify Portuguese user-wait as incomplete: \(message)"
            )
        }
    }

    // MARK: - Decision: bounded, autonomous-only, completed-only.

    func test_autoContinuesOnlyForCompletedAutonomousStallUnderBound() {
        let stall = "Standing by for the demo recording to complete."

        XCTAssertTrue(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: stall, isAutonomous: true, priorAutoContinuations: 0),
            "a completed full-access stall under the bound must auto-continue")

        XCTAssertFalse(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: stall, isAutonomous: false, priorAutoContinuations: 0),
            "a supervised run must never auto-continue — the user drives it manually")

        XCTAssertFalse(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: "All done. Build is green.", isAutonomous: true, priorAutoContinuations: 0),
            "a genuinely-finished answer must not auto-continue")

        XCTAssertFalse(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .failed, finalMessage: stall, isAutonomous: true, priorAutoContinuations: 0),
            "a failed/cancelled run must not auto-continue")
    }

    func test_autoContinueStopsAtTheBound() {
        let stall = "Awaiting the background completion notification."
        let max = BackgroundAwaitContinuation.maxAutoContinuations

        XCTAssertTrue(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: stall, isAutonomous: true, priorAutoContinuations: max - 1),
            "the last allowed attempt (prior == max - 1) must still fire")

        XCTAssertFalse(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: stall, isAutonomous: true, priorAutoContinuations: max),
            "once the bound is reached the host must stop auto-nudging and leave it flagged")
    }
}
