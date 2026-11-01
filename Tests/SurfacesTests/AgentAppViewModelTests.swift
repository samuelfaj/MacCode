import XCTest
import AppKit
import MachO
import Combine
import CryptoKit
import SwiftUI
@testable import Surfaces
import CoreModel
@testable import Persistence
@testable import AgentRuntime

/// Behavioural coverage for thread rename/delete in the agent app view
/// model. Proves the sidebar contract: rename trims + persists, deleting
/// the selected thread never strands the UI on a dead selection.
@MainActor
final class AgentAppViewModelTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }


    private func distillAttestation(
        type: AssistantItemType = .tool,
        body: String,
        output: String?
    ) -> AssistantItemHostAttestation {
        func fingerprint(_ text: String) -> AssistantContentFingerprint {
            let bytes = Data(text.utf8)
            return AssistantContentFingerprint(
                byteCount: bytes.count,
                sha256: Data(SHA256.hash(data: bytes))
            )
        }
        return AssistantItemHostAttestation(
            itemType: type,
            body: fingerprint(body),
            output: output.map(fingerprint)
        )
    }

    override func setUp() {
        super.setUp()
        // AgentLastModelStore.shared persists to the test runner's
        // UserDefaults, so model choices remembered by EARLIER test runs leak
        // into preferredModelForCurrentProvider and make these tests
        // machine-dependent. Key literal mirrors AgentLastModelStore.key.
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
    }

    private func makeVM(provider: AgentProviderRunner? = nil) throws -> (AgentAppViewModel, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        var providers: [AgentProvider: AgentProviderRunner] = [
            .codex: FakeProviderRunner(provider: .codex),
            .claude: FakeProviderRunner(provider: .claude),
            .distill: FakeProviderRunner(provider: .distill)
        ]
        if let provider { providers[provider.provider] = provider }
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: providers)
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coord, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   draftRepo: AgentThreadDraftRepository(db: db),
                                   attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")),
                                   promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        wireCanonicalThreadRead(vm, repo: threadRepo)
        return (vm, threadRepo)
    }

    private func makeVM(adapter: AgentProviderAdapter) throws -> (AgentAppViewModel, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo,
                                        messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providerAdapters: [.codex: adapter])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   draftRepo: AgentThreadDraftRepository(db: db),
                                   attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")),
                                   promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        wireCanonicalThreadRead(vm, repo: threadRepo)
        return (vm, threadRepo)
    }

    private func installRunnableProviderFixtures(on vm: AgentAppViewModel) {
        vm.providerSnapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true
            ),
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true
            )
        ]
    }

    private func wireCanonicalThreadRead(_ vm: AgentAppViewModel, repo: AgentThreadRepository) {
        vm.markThreadRead = { id in
            guard var thread = try repo.get(id: id) else {
                throw NSError(domain: "AgentAppViewModelTests", code: 404)
            }
            guard thread.hasUnread else { return }
            thread.hasUnread = false
            try repo.upsert(thread)
        }
    }

    private func crashSafeForkSnapshot() -> AgentProviderSnapshot {
        AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5", label: "GPT-5", provider: .codex)],
            // Runnable on any machine: send()'s fail-closed provider gate probes
            // the real binary path, so a fixture path that only exists on some
            // dev machines silently blocks the sends this test asserts on.
            binaryPath: "/usr/bin/true",
            authenticated: true,
            capabilitiesOverride: AgentProviderCapabilities(
                supportsAttachments: true,
                supportedAttachmentKinds: [.file, .image],
                supportedAttachmentMediaTypes: ["*/*"],
                supportsApprovals: true,
                supportsUserInput: true,
                supportsStreaming: true,
                supportsFork: true,
                supportsRollback: true,
                supportsPlanReview: true
            )
        )
    }

    func test_cancelPendingUserInputResolvesOnlyQuestionAndKeepsProviderSession() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "cancel question")
        let request = AssistantUserInputRequest(
            id: "ask-cancel",
            turnId: "turn-1",
            prompt: "Choose a target",
            options: ["macOS", "iOS"],
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.cancelPendingUserInput(request)
        await waitAsync("question cancellation reaches adapter") {
            adapter.cancelledUserInputs.contains { $0.requestId == request.id }
        }

        XCTAssertEqual(adapter.cancelledUserInputs.first?.threadId, vm.selectedThreadId,
                       "cancel must target the question's owning thread")
        XCTAssertEqual(adapter.stopSessionCount, 0,
                       "cancelling AskUserQuestion must not stop or discard the provider session")
        XCTAssertTrue(vm.openPendingUserInputs.isEmpty,
                      "a cancelled question must leave no actionable callback card")
    }

    func test_errorRecoveryClassifierMapsProviderFailuresToSafeActions() {
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(
            provider: .codex,
            message: "[auth-required] 401 Unauthorized",
            recoverable: false
        ), .signIn, "expired Codex auth must expose Sign in instead of a dead generic error")
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(
            provider: .grok,
            message: "Grok ACP RPC error: rate limit exceeded",
            recoverable: false
        ), .retry, "Grok rate limits must expose Retry")
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(
            provider: .grok,
            message: "Grok ACP network connection timed out",
            recoverable: false
        ), .retry, "Grok network failures must expose Retry")
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(
            provider: .grok,
            message: "Grok ACP session/load failed: session not found",
            recoverable: false
        ), .startFresh, "an invalid resume cursor must not retry the same broken session")
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(
            provider: .distill,
            message: "[fresh-session:incompatible-history] The model rejected this Distill session's history; Retry starts a new Distill session: Distill ACP RPC error: API error (status 400 Bad Request): Invalid `signature` in `thinking` block",
            recoverable: false
        ), .retry, "the adapter retires the poisoned session, so Retry keeps the thread (and a bot desk link) instead of Start fresh")
        XCTAssertNil(AgentAppViewModel.errorRecoveryAction(
            provider: .codex,
            message: "invalid request payload",
            recoverable: false
        ), "fatal non-recovery errors must not offer a misleading action")
    }

    func test_terminalCodexAuthFailureSurfacesSignInAction() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "expired auth")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let runId = AgentRunID()

        vm.runCoordinator(
            vm.coordinator,
            didFinish: runId,
            threadId: threadId,
            status: .failed,
            finalMessage: "[auth-required] Unauthorized",
            providerThreadId: "codex-thread"
        )
        await waitAsync("terminal auth failure reaches timeline") {
            vm.timeline.error != nil
        }

        XCTAssertEqual(vm.displayedErrorRecoveryAction, .signIn,
                       "a terminal Codex auth marker must render an actionable Sign in CTA")
        XCTAssertEqual(vm.status, .failed)
    }

    func test_providerSnapshotSignInUsesHostActionAndOffersHonestRetry() async throws {
        let (vm, _) = try makeVM()
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
            binaryPath: "/usr/bin/true",
            authenticated: false
        )
        vm.provider = .claude
        vm.providerInstanceId = snapshot.id
        vm.providerSnapshots = [snapshot]
        var openedProvider: AgentProvider?
        vm.providerSignInAction = { openedProvider = $0 }

        XCTAssertEqual(vm.providerRecoveryActionTitle, "Sign in",
                       "an unauthenticated provider card must expose the real Sign in flow, not a clipboard action")

        await vm.performProviderRecoveryAction()

        XCTAssertEqual(openedProvider, .claude)
        XCTAssertEqual(vm.providerRecoveryActionTitle, "Retry",
                       "after Terminal opens, the next action must re-check authentication instead of claiming success")
        XCTAssertEqual(
            vm.providerRecoveryStatusMessage,
            "Opened Claude sign-in in Terminal. Complete sign-in there, then choose Retry."
        )
    }

    func test_nonAuthenticationErrorNeverLaunchesProviderSignIn() async throws {
        let (vm, _) = try makeVM()
        vm.timeline.apply(.error(message: "invalid request payload", recoverable: false))
        var launchCount = 0
        vm.providerSignInAction = { _ in launchCount += 1 }

        XCTAssertNil(vm.displayedErrorRecoveryAction)
        await vm.performDisplayedErrorRecoveryAction()

        XCTAssertEqual(launchCount, 0,
                       "non-authentication errors must never execute an authentication command")
    }

    func test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "auth retry")
        vm.prompt = "resume only after auth"
        await vm.send()
        // Terminal, not `.completed`: CapturingProviderRunner captures requests and
        // emits no assistant output, and ProviderStderrClassifier reclassifies a silent
        // `.completed` to `.failed` by contract ("a success with no assistant output is
        // not success"). Waiting on `.completed` could never settle, which hid the
        // retry contract this spec is about.
        await waitAsync("initial request completes") {
            runner.prompts == ["resume only after auth"]
                && AgentRunCoordinator.isTerminalThreadStatus(vm.status)
        }

        func authSnapshot(_ authenticated: Bool) -> AgentProviderSnapshot {
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: authenticated
            )
        }
        let unauthenticated = authSnapshot(false)
        vm.providerSnapshots = [unauthenticated]
        vm.providerInstanceId = unauthenticated.id
        vm.timeline.apply(.error(message: "[auth-required] token expired", recoverable: false))
        vm.providerSignInAction = { _ in }
        var authenticationConfirmed = false
        vm.providerAuthenticationRefresher = { _ in
            [authSnapshot(authenticationConfirmed)]
        }

        XCTAssertEqual(vm.displayedErrorRecoveryAction, .signIn)
        await vm.performDisplayedErrorRecoveryAction()
        XCTAssertEqual(vm.displayedErrorRecoveryAction, .retry)

        await vm.performDisplayedErrorRecoveryAction()
        XCTAssertEqual(runner.prompts, ["resume only after auth"],
                       "Retry must not reach the provider while the fresh snapshot remains unauthenticated")
        XCTAssertEqual(
            vm.providerRecoveryStatusMessage,
            "Sign-in is not confirmed yet. Complete it in Terminal, then choose Retry."
        )

        authenticationConfirmed = true
        await vm.performDisplayedErrorRecoveryAction()
        await waitAsync("authenticated retry reaches provider") {
            runner.prompts.filter { $0 == "resume only after auth" }.count == 2
        }
        XCTAssertNil(vm.timeline.error)
        XCTAssertEqual(vm.providerRecoveryStatusMessage, "Authentication confirmed. Retrying the request.")
    }

    func test_disabledUnavailableAndUnauthenticatedSnapshotsBlockRunStart() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "provider gate")
        let model = AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        let snapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex, models: [model], binaryPath: "/usr/bin/true", enabled: false
            ),
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex, models: [model], binaryPath: "/usr/bin/true", authenticated: false
            ),
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex, models: [model], binaryPath: ""
            )
        ]

        for snapshot in snapshots {
            vm.providerSnapshots = [snapshot]
            vm.providerInstanceId = snapshot.id
            // send() re-probes via loadProviderSnapshots(); with no injected loader it
            // would fall back to the REAL machine (CLIs installed) and admit the run,
            // making the test non-hermetic. Pin the reload to the same unrunnable snapshot.
            vm.providerSnapshotLoader = { [snapshot] }
            vm.prompt = "must not send"
            await vm.send()
            XCTAssertFalse(vm.selectedProviderCanRun,
                           "snapshot state \(snapshot.status.rawValue) must disable provider-backed controls")
            XCTAssertNotNil(vm.providerExecutionUnavailableReason)
        }
        XCTAssertTrue(adapter.sentTurns.isEmpty,
                      "no disabled, unavailable, or unauthenticated provider snapshot may start a turn")
    }

    func test_attachmentCapabilityRejectsUnsupportedControlBeforeStaging() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "attachment capability")
        vm.providerSnapshots = [AgentProviderSnapshot(
            id: "codex-no-attachments",
            provider: .codex,
            driverKind: .codexCLI,
            displayName: "Codex Read-only",
            accentColor: "#2F80ED",
            continuationGroup: "codex",
            interactionModes: [.default],
            permissionModes: [.supervised, .fullAccess],
            enabled: true,
            installed: true,
            status: .available,
            authenticated: true,
            models: [AgentModelDescriptor(id: "m", label: "M", provider: .codex)],
            slashCommands: [],
            capabilities: .conservative
        )]
        vm.providerInstanceId = "codex-no-attachments"

        vm.addAttachments(["/tmp/never-stage-this.txt"])

        XCTAssertTrue(vm.attachments.isEmpty)
        XCTAssertTrue(vm.statusMessage.contains("does not support attachments"),
                      "attachment controls must obey the selected instance capability before filesystem work")
    }

    func test_isAwaitingBackgroundWork_flagsCompletedStallButNotNormalCompletion() throws {
        // UX-MAC_AGENT-BG-AWAIT: a run that ends while the agent is still waiting on
        // a background job it launched must read "awaiting", not a green "completed".
        let (vm, _) = try makeVM()
        vm.status = .completed

        vm.timeline.apply(.turnStarted(turnId: "t1"))
        vm.timeline.apply(.turnCompleted(turnId: "t1", finalMessage: "Standing by for the demo recording to complete."))
        XCTAssertTrue(vm.isAwaitingBackgroundWork,
                      "a completed run whose final message is a background-await stall must surface as awaiting, so the user knows the task is not actually finished")

        vm.timeline.apply(.turnStarted(turnId: "t2"))
        vm.timeline.apply(.turnCompleted(turnId: "t2", finalMessage: "All four steps are done; the build is green and the PR is open."))
        XCTAssertFalse(vm.isAwaitingBackgroundWork,
                       "a completed run with a real final answer must not be flagged as awaiting")

        // A running thread is never 'awaiting a background task', even mid-narration.
        vm.timeline.apply(.turnStarted(turnId: "t3"))
        vm.timeline.apply(.turnCompleted(turnId: "t3", finalMessage: "Standing by for the demo recording to complete."))
        vm.status = .running
        XCTAssertFalse(vm.isAwaitingBackgroundWork,
                       "a running thread must not surface the awaiting badge")
    }

    func test_isAwaitingBackgroundWork_flagsClaudeFutureTenseDeployPollerStall() throws {
        // The reported Claude-provider stall: the agent ends its turn saying it will
        // wait for a deploy poller that "notifies me". This completed run must read
        // "awaiting" (warning) with the Continue banner, not a green "completed", so
        // the user can tell the task is not actually finished.
        let (vm, _) = try makeVM()
        vm.status = .completed

        vm.timeline.apply(.turnStarted(turnId: "t1"))
        vm.timeline.apply(.turnCompleted(turnId: "t1", finalMessage: "I'll wait for the deploy poller to complete (it notifies me), then run the summer-gate Chrome verification across multiple accounts."))
        XCTAssertTrue(vm.isAwaitingBackgroundWork,
                      "a completed Claude run waiting on a background deploy poller must surface as awaiting")
    }

    func test_isAwaitingBackgroundWork_marker_surfacesForAnyPhrasing() throws {
        // The deterministic path: when the agent self-declares the stall with the
        // marker, the badge must surface even for phrasing the heuristic misses.
        let (vm, _) = try makeVM()
        vm.status = .completed
        let novel = "Holding here until the canary bake finishes and the gate flips."
        vm.timeline.apply(.turnStarted(turnId: "t1"))
        vm.timeline.apply(.turnCompleted(turnId: "t1", finalMessage: novel))
        XCTAssertFalse(vm.isAwaitingBackgroundWork,
                       "control: novel phrasing without the marker is beyond the heuristic")
        vm.timeline.apply(.turnStarted(turnId: "t2"))
        vm.timeline.apply(.turnCompleted(turnId: "t2", finalMessage: "\(BackgroundAwaitContinuation.awaitingMarker)\n\(novel)"))
        XCTAssertTrue(vm.isAwaitingBackgroundWork,
                      "a marker-declared stall must surface as awaiting regardless of phrasing")
    }

    func test_composerPlaceholder_reflectsIncompleteTurnStateInsteadOfReadingFinished() throws {
        // UX-MAC_AGENT-BG-AWAIT: the reported defect — a run that ended still awaiting
        // background work presented a normal "Ask <Provider> for changes…" composer, so
        // the thread read as finished. The composer placeholder must instead reflect the
        // incomplete state (background-await vs mid-workflow), while staying a redirect,
        // and must revert to the neutral prompt for genuinely finished / running threads.
        let (vm, _) = try makeVM()
        let neutral = "Ask \(vm.provider.rawValue.capitalized) for changes…"

        // Genuinely finished turn → neutral composer (regression guard for the else branch).
        vm.status = .completed
        vm.timeline.apply(.turnStarted(turnId: "done"))
        vm.timeline.apply(.turnCompleted(turnId: "done", finalMessage: "All steps are done; the build is green and the PR is open."))
        XCTAssertEqual(vm.composerPlaceholder, neutral,
                       "a real final answer must keep the normal composer prompt")

        // Background-await stall → awaiting-specific copy, not the finished-state default.
        vm.timeline.apply(.turnStarted(turnId: "await"))
        vm.timeline.apply(.turnCompleted(turnId: "await", finalMessage: "Standing by for the demo recording to complete."))
        XCTAssertEqual(vm.composerPlaceholder, "Waiting on a background task — send to redirect…",
                       "an awaiting run must make the composer read as not-finished so the user does not mistake it for a done thread")

        // Mid multi-phase workflow handoff → handoff-specific copy.
        vm.timeline.apply(.turnStarted(turnId: "phase"))
        vm.timeline.apply(.turnCompleted(turnId: "phase", finalMessage: "Phase 2 done.\nNext: Phase 3 — Review"))
        XCTAssertEqual(vm.composerPlaceholder, "Paused mid-workflow — send to redirect…",
                       "a run stopped between numbered workflow phases must say so in the composer, not invite a fresh unrelated ask")

        // A running turn is never incomplete: incompleteTurnReason is nil (its own
        // status==.completed guard), so the composer returns to the neutral prompt.
        vm.status = .running
        XCTAssertEqual(vm.composerPlaceholder, neutral,
                       "a running thread must not show the awaiting placeholder")
    }

    // MARK: - CLAUDE-BG-LIFECYCLE: live "N shells" chip

    func test_backgroundShellCount_isReadFromClaudeSessionSnapshotOnly() {
        // The provider's pending background-work set reaches the UI ONLY through the
        // claude.session.snapshot runtime payload — nothing else exports it. This is
        // what makes running background shells visible at all (previously the app had
        // no equivalent of the Claude CLI's own "1 shell" indicator).
        let snapshot = { (payload: String) in
            AssistantEvent.providerRuntime(ProviderRuntimeEvent(
                id: "snap",
                provider: .claude,
                source: "claude.stream-json.session",
                method: "claude.session.snapshot",
                payloadJSON: payload,
                receivedAtMs: 1
            ))
        }
        XCTAssertEqual(
            AgentAppViewModel.backgroundShellCount(fromRuntimeEvent: snapshot(#"{"reason":"tool_started","pendingBackgroundTaskIds":["T1","T2"]}"#)),
            2,
            "two CLI-tracked background shells must be reported so the chip can show them"
        )
        XCTAssertEqual(
            AgentAppViewModel.backgroundShellCount(fromRuntimeEvent: snapshot(#"{"reason":"tool_started","pendingBackgroundTaskIds":[]}"#)),
            0,
            "an empty set is authoritative — background work finished, so the chip must clear"
        )
        // nil (not 0) for anything that does not carry the field: an unrelated event
        // must never silently clear a live count.
        XCTAssertNil(
            AgentAppViewModel.backgroundShellCount(fromRuntimeEvent: snapshot(#"{"reason":"turn_started"}"#)),
            "a snapshot without the field (older payload / SDK-bridge route) must not clear the count"
        )
        XCTAssertNil(
            AgentAppViewModel.backgroundShellCount(fromRuntimeEvent: .turnStarted(turnId: "t1")),
            "a non-runtime event carries no background state"
        )
        XCTAssertNil(
            AgentAppViewModel.backgroundShellCount(fromRuntimeEvent: .providerRuntime(ProviderRuntimeEvent(
                id: "other", provider: .claude, source: "claude.stream-json",
                method: "assistant", payloadJSON: #"{"pendingBackgroundTaskIds":["T1"]}"#, receivedAtMs: 1
            ))),
            "only the session snapshot is authoritative; another method must be ignored even if it happens to carry the key"
        )
    }

    func test_visibleBackgroundShellCount_hidesStaleCountOnceRunIsNoLongerLive() {
        // The adapter clears its pending set inside emitTerminal WITHOUT emitting a
        // further snapshot, so the last count the UI receives for a run can be
        // non-zero. Without the live-run gate a finished thread would keep claiming
        // shells are running forever.
        XCTAssertEqual(AgentAppViewModel.visibleBackgroundShellCount(reported: 2, runIsLive: true), 2,
                       "while the run is live the reported count is shown")
        XCTAssertEqual(AgentAppViewModel.visibleBackgroundShellCount(reported: 2, runIsLive: false), 0,
                       "a finished run must not keep advertising background shells (the awaiting pill covers the after-case)")
    }

    func test_backgroundShellLabel_matchesClaudeCLIWording() {
        // Same wording as the CLI status line ("1 shell") so the two surfaces read
        // consistently; the chip is hidden at 0 by the call site.
        XCTAssertEqual(AgentAppView.backgroundShellLabel(1), "1 shell")
        XCTAssertEqual(AgentAppView.backgroundShellLabel(3), "3 shells")
    }

    func test_backgroundTasks_readIdsFromSnapshot() {
        let snapshot = { (payload: String) in
            AssistantEvent.providerRuntime(ProviderRuntimeEvent(
                id: "snap",
                provider: .claude,
                source: "claude.stream-json.session",
                method: "claude.session.snapshot",
                payloadJSON: payload,
                receivedAtMs: 1
            ))
        }
        let idsOnly = AgentAppViewModel.backgroundTasks(fromRuntimeEvent: snapshot(
            #"{"reason":"background_work","pendingBackgroundTaskIds":["T1"]}"#
        ))
        XCTAssertEqual(idsOnly, [
            AgentBackgroundTask(id: "T1", kind: .unknown)
        ], "the adapter snapshot exports ids only; task details come from exact timeline rows")
        XCTAssertEqual(
            AgentAppViewModel.backgroundShellCount(fromRuntimeEvent: snapshot(
                #"{"reason":"background_work","pendingBackgroundTaskIds":["T1"]}"#
            )),
            1,
            "count must stay in lockstep with the producer's id list"
        )
        XCTAssertEqual(
            AgentAppViewModel.backgroundTasks(fromRuntimeEvent: snapshot(
                #"{"reason":"tool_started","pendingBackgroundTaskIds":["T1","T2"]}"#
            )),
            [
            AgentBackgroundTask(id: "T1", kind: .unknown),
            AgentBackgroundTask(id: "T2", kind: .unknown)
            ],
            "the producer's complete id set must preserve every holder"
        )
        XCTAssertEqual(
            AgentAppViewModel.backgroundTasks(fromRuntimeEvent: snapshot(#"{"reason":"turn_started"}"#)),
            nil,
            "a snapshot without either field must not clear live tasks"
        )
        XCTAssertEqual(
            AgentAppViewModel.visibleBackgroundTasks(
                reported: [AgentBackgroundTask(id: "T1", kind: .shell, description: "Wait for CI")],
                runIsLive: false
            ),
            [],
            "a finished run must not keep advertising the shell that held Stop"
        )
    }

    func test_enrichingBackgroundTasks_matchesTimelineDetailsByExactTaskId() {
        var timeline = AssistantTimelineState()
        timeline.apply(.turnStarted(turnId: "t1"))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "T1",
            turnId: "t1",
            type: .tool,
            summary: "Background shell",
            body: "Wait for CI",
            startedAtMs: 1
        )))
        let anonymous = [AgentBackgroundTask(id: "T1", kind: .unknown)]
        let enriched = AgentAppViewModel.enrichingBackgroundTasks(anonymous, timeline: timeline)
        XCTAssertEqual(enriched, [
            AgentBackgroundTask(id: "T1", kind: .shell, description: "Wait for CI")
        ], "a single live shell must show the CLI description already on the timeline")
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "T2",
            turnId: "t1",
            type: .tool,
            summary: "Background agent",
            body: "Review PR",
            startedAtMs: 2
        )))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "unrelated",
            turnId: "t1",
            type: .tool,
            summary: "Background shell",
            body: "Wrong task",
            startedAtMs: 3
        )))
        let two = [
            AgentBackgroundTask(id: "T1", kind: .unknown),
            AgentBackgroundTask(id: "T2", kind: .unknown)
        ]
        XCTAssertEqual(
            AgentAppViewModel.enrichingBackgroundTasks(two, timeline: timeline),
            [
                AgentBackgroundTask(id: "T1", kind: .shell, description: "Wait for CI"),
                AgentBackgroundTask(id: "T2", kind: .agent, description: "Review PR")
            ],
            "each task must receive only the human details from its exact timeline id; unrelated rows must not cross-assign"
        )

        var unrelatedTimeline = AssistantTimelineState()
        unrelatedTimeline.apply(.turnStarted(turnId: "t-unrelated"))
        unrelatedTimeline.apply(.itemStarted(item: AssistantItem(
            id: "other-task",
            turnId: "t-unrelated",
            type: .tool,
            summary: "Background shell",
            body: "Wrong task",
            startedAtMs: 4
        )))
        XCTAssertEqual(
            AgentAppViewModel.enrichingBackgroundTasks(anonymous, timeline: unrelatedTimeline),
            anonymous,
            "a task must not borrow the newest timeline row when its id is absent"
        )

        var rawTimeline = AssistantTimelineState()
        rawTimeline.apply(.turnStarted(turnId: "t2"))
        rawTimeline.apply(.itemStarted(item: AssistantItem(
            id: "T1",
            turnId: "t2",
            type: .tool,
            summary: "Background shell",
            body: #"{"task_type":"local_bash","command":"sleep 30"}"#,
            startedAtMs: 2
        )))
        XCTAssertEqual(
            AgentAppViewModel.enrichingBackgroundTasks(anonymous, timeline: rawTimeline),
            [AgentBackgroundTask(id: "T1", kind: .shell)],
            "raw provider JSON must not leak into the Stop strip as a task description"
        )
    }

    func test_reduceStreamQuantum_appliesBackgroundTaskIdsFromSnapshot() {
        let tid = AgentThreadID()
        let run = AgentRunID()
        let event = AssistantEvent.providerRuntime(ProviderRuntimeEvent(
            id: "snap",
            provider: .claude,
            source: "claude.stream-json.session",
            method: "claude.session.snapshot",
            payloadJSON: #"{"reason":"background_work","pendingBackgroundTaskIds":["T1"]}"#,
            receivedAtMs: 1
        ))
        let input = StreamQuantumReduceInput(
            selectedThreadId: tid,
            timeline: AssistantTimelineState(),
            suppressStaleActivePlanUpdates: false,
            newestUserMessageAt: nil,
            runStartedAt: Date(),
            hasQueuedFollowUp: false,
            currentRunId: run,
            status: .running,
            lastErrorRecoverable: false,
            liveBackgroundShellCount: 0,
            liveBackgroundTasks: [],
            runsAllowedToMarkActive: [run],
            entries: [StreamQuantumEntry(event: event, run: run, threadId: tid)]
        )
        let reduced = AgentAppViewModel.reduceStreamQuantum(input)
        XCTAssertEqual(reduced.liveBackgroundShellCount, 1)
        XCTAssertEqual(reduced.liveBackgroundTasks, [
            AgentBackgroundTask(id: "T1", kind: .unknown)
        ])
    }

    func test_reduceStreamQuantum_clearsRetainedBackgroundTasksWhenNewRunStarts() {
        let tid = AgentThreadID()
        let oldRun = AgentRunID()
        let newRun = AgentRunID()
        let input = StreamQuantumReduceInput(
            selectedThreadId: tid,
            timeline: AssistantTimelineState(),
            suppressStaleActivePlanUpdates: false,
            newestUserMessageAt: nil,
            runStartedAt: nil,
            hasQueuedFollowUp: false,
            currentRunId: oldRun,
            status: .completed,
            lastErrorRecoverable: false,
            liveBackgroundShellCount: 1,
            liveBackgroundTasks: [
                AgentBackgroundTask(id: "old-task", kind: .shell, description: "Old run")
            ],
            runsAllowedToMarkActive: [newRun],
            entries: [
                StreamQuantumEntry(
                    event: .providerRuntime(ProviderRuntimeEvent(
                        id: "old-snapshot",
                        provider: .claude,
                        source: "claude.stream-json.session",
                        method: "claude.session.snapshot",
                        payloadJSON: #"{"pendingBackgroundTaskIds":["old-task"]}"#,
                        receivedAtMs: 1
                    )),
                    run: oldRun,
                    threadId: tid
                ),
                StreamQuantumEntry(
                    event: .turnStarted(turnId: "new-turn"),
                    run: newRun,
                    threadId: tid
                )
            ]
        )

        let reduced = AgentAppViewModel.reduceStreamQuantum(input)
        XCTAssertEqual(reduced.liveBackgroundShellCount, 0,
                       "a new run must not inherit the prior run's holder count")
        XCTAssertEqual(reduced.liveBackgroundTasks, [],
                       "a new run must not inherit the prior run's Stop-strip task details")
    }

    func test_composerPlaceholder_staysNeutralWhenRunIsLiveDespiteStaleCompletedStatus() throws {
        // The load-bearing `!selectedThreadRunIsStartingOrRunning` guard: this VM's
        // `status` can be a stale `.completed` (e.g. a run started/owned elsewhere —
        // a scheduled LaunchAgent run or another tab sharing the thread) while a run is
        // actually live. In that state `incompleteTurnReason` is non-nil (status is
        // completed) yet the thread is NOT idle, so the composer must stay neutral — an
        // "awaiting/redirect" prompt on top of a live run would be wrong. Removing the
        // guard from composerPlaceholder makes this assertion fail.
        let (vm, _) = try makeVM()
        vm.createThread(title: "live in another tab")
        vm.isScheduledThreadRunning = { _ in true }   // force selectedThreadRunIsStartingOrRunning == true
        vm.status = .completed                          // stale completed status
        vm.timeline.apply(.turnStarted(turnId: "await"))
        vm.timeline.apply(.turnCompleted(turnId: "await", finalMessage: "Standing by for the demo recording to complete."))

        XCTAssertNotNil(vm.incompleteTurnReason,
                        "precondition: the stale-completed final message classifies as incomplete")
        XCTAssertTrue(vm.selectedThreadRunIsStartingOrRunning,
                      "precondition: a live/scheduled run is tracked for the selected thread")
        XCTAssertEqual(vm.composerPlaceholder, "Ask \(vm.provider.rawValue.capitalized) for changes…",
                       "a live run must keep the neutral composer even when status is a stale completed with an awaiting final message")
    }

    func test_renameThread_trimsUpdatesAndPersists() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "first")
        let id = vm.selectedThreadId!
        vm.renameThread(id, to: "  Renamed Thread  ")
        XCTAssertEqual(vm.threads.first(where: { $0.id == id })?.title, "Renamed Thread",
                       "rename must trim and update the in-memory list")
        XCTAssertEqual(try repo.get(id: id)?.title, "Renamed Thread",
                       "rename must persist to the repository, not just the view")
    }

    func test_providerLocked_onlyAfterConversationStarts() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        XCTAssertFalse(vm.providerLocked, "an empty thread can still switch source")
        let id = vm.selectedThreadId!
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "hi"))
        XCTAssertTrue(vm.providerLocked, "once it has a message the source is fixed")
    }

    func test_distillSelectionRejectsAutomaticModelRouting() throws {
        // WHY: Distill ACP requires an explicit Main model; switching from
        // orchestration must not leave the UI in model-auto.
        let (vm, _) = try makeVM()
        XCTAssertTrue(vm.setAutoModelRoutingEnabled(true))
        XCTAssertEqual(vm.routingMode, .auto)

        vm.setProvider(.distill)

        XCTAssertEqual(vm.routingMode, .manual)
        XCTAssertFalse(vm.setAutoModelRoutingEnabled(true))
        XCTAssertEqual(vm.routingMode, .manual)
        XCTAssertEqual(vm.provider, .distill)

        vm.setProvider(.grok)
        XCTAssertTrue(vm.setAutoModelRoutingEnabled(true),
                      "other providers keep the existing automatic-routing behavior")
    }

    func test_providerChangeIsIgnoredAfterConversationStarts() throws {
        let (vm, repo) = try makeVM()
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                authenticated: true,
                accountLabel: "codex@example.com",
                accountAuthMethod: "codex",
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: []
            ),
            AgentProviderSnapshot(
                id: "claude-cli",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                authenticated: true,
                accountLabel: "claude@example.com",
                accountAuthMethod: "claude.ai",
                models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
                slashCommands: []
            )
        ]
        vm.setProviderInstance("codex-cli")
        // Pin the model the UI way (setModel remembers it for the provider) so
        // createThread's preferred-model re-resolution lands on it.
        vm.setModel("gpt-5.5")
        vm.createThread(title: "locked source")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "first turn"))

        vm.setProvider(.claude)
        vm.setProviderInstance("claude-cli")

        XCTAssertEqual(vm.provider, .codex,
                       "after the first user message, source changes must be ignored so a resumed run cannot switch provider mid-thread")
        XCTAssertEqual(vm.providerInstanceId, "codex-cli",
                       "provider instance must stay aligned with the locked source")
        XCTAssertEqual(vm.model, "gpt-5.5",
                       "blocking a source change must not clear the selected model")
        let persisted = try XCTUnwrap(repo.get(id: id))
        XCTAssertEqual(persisted.provider, .codex,
                       "a blocked source change must not persist into the thread configuration")
        XCTAssertEqual(persisted.providerInstanceId, "codex-cli")
        XCTAssertEqual(persisted.model, "gpt-5.5")
    }

    func test_modelChangePersistsAfterConversationStarts() throws {
        let (vm, repo) = try makeVM()
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex),
            AgentModelDescriptor(id: "gpt-5.6", label: "GPT-5.6", provider: .codex)
        ]
        vm.createThread(title: "locked model")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.setModel("gpt-5.5")
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "first turn"))

        vm.setModel("gpt-5.6")

        XCTAssertEqual(vm.model, "gpt-5.6",
                       "provider/source locks after the first message, but model changes must still apply to the next run")
        XCTAssertEqual(try repo.get(id: id)?.model, "gpt-5.6",
                       "model changes after the first message must persist to the thread configuration")
    }

    func test_modelListLoadingAndRetryStateIsVisible() async throws {
        let (vm, _) = try makeVM()
        vm.modelListLoader = { _ in
            try await Task.sleep(nanoseconds: 20_000_000)
            return []
        }

        let load = Task { await vm.loadModels() }
        // F35: progress is signalled by modelListLoading only — reusing the
        // error-styled status message rendered a red duplicate "Loading
        // models..." with a Retry row while the fetch was still in flight.
        await waitAsync("model list loading state becomes visible without an error-styled status") {
            vm.modelListLoading == true && vm.modelListStatusMessage == nil
        }
        await load.value

        XCTAssertEqual(vm.modelListStatusMessage, "No models returned for Codex. Retry from the model menu.",
                       "an empty model list must leave visible retry guidance instead of a silent Default-only picker")
        XCTAssertFalse(vm.modelListLoading)
    }

    func test_modelSnapshotFailureFailsLoud() async throws {
        let (vm, _) = try makeVM()
        vm.providerSnapshots = []
        struct SnapshotFailure: Error {}
        vm.providerSnapshotLoader = { throw SnapshotFailure() }

        await vm.loadProviderSnapshots()

        XCTAssertEqual(vm.providerSnapshotStatusMessage, "Provider snapshot failed. Retry from the model menu.",
                       "provider/model snapshot fetch failures must be visible so the user can distinguish stale local models from a loaded provider list")
        // Fail open for composer usability: seed a local fallback so send is not
        // stuck on missingSnapshot after a transient probe failure.
        XCTAssertFalse(vm.providerSnapshots.isEmpty,
                       "snapshot load failure must still seed local provider rows so Full access/Grok is not permanently blocked")
        XCTAssertNotNil(vm.providerSnapshots.first(where: { $0.provider == .grok }),
                        "fallback seed must include Grok, not only Codex/Claude")
    }

    /// WHY: new threads must reopen the last model the user used for that
    /// provider; Codex without history defaults to gpt-5.6-sol.
    func test_createThread_usesLastModelThenCodexBuiltInDefault() throws {
        let (vm, repo) = try makeVM()
        let suiteName = "rc2-last-model-" + UUID().uuidString
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = AgentLastModelStore(defaults: suite)
        vm.lastModelStore = store

        XCTAssertEqual(vm.preferredModelForCurrentProvider(), "gpt-5.6-sol",
                       "Codex with no last-used model defaults to gpt-5.6-sol")

        // Fixture snapshots expose gpt-5.5; remember only accepts known/custom ids.
        vm.setModel("gpt-5.5")
        XCTAssertEqual(store.model(for: .codex), "gpt-5.5")

        // Simulate browsing an older thread whose model differs from last-used.
        vm.model = "gpt-5.2"
        vm.createThread(title: "from last used")
        let id = try XCTUnwrap(vm.selectedThreadId)
        let thread = try XCTUnwrap(try repo.get(id: id))
        XCTAssertEqual(thread.model, "gpt-5.5",
                       "createThread must not inherit a stale selected-thread model")
        XCTAssertEqual(vm.model, "gpt-5.5")
    }

    /// WHY: council SC-ux-1 — auto-rebind must reset model like setProvider,
    /// not keep gpt-5.6-sol (Codex) after switching to Claude.
    func test_autoRebind_appliesPreferredModelForNewProvider() async throws {
        let (vm, _) = try makeVM()
        let suiteName = "rc2-rebind-model-" + UUID().uuidString
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        vm.lastModelStore = AgentLastModelStore(defaults: suite)
        vm.sourceSelectionUserPinned = false
        vm.provider = .codex
        vm.providerInstanceId = "codex"
        vm.model = "gpt-5.6-sol"
        let missingCodex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "",
            id: "codex-cli"
        )
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [
                AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude),
                AgentModelDescriptor(id: "sonnet", label: "Sonnet", provider: .claude)
            ],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "claude-cli"
        )
        vm.providerSnapshotLoader = { [missingCodex, claude] }
        await vm.loadProviderSnapshots()
        XCTAssertEqual(vm.provider, .claude)
        XCTAssertEqual(vm.model, "opus",
                       "auto-rebind must apply preferred Claude model, not keep Codex gpt-5.6-sol")
        XCTAssertNotEqual(vm.model, "gpt-5.6-sol")
    }

    /// WHY: the router stores bot/iOS-created threads under the raw provider id
    /// ("distill") when no configured instance matches. Mapping that alias to the
    /// snapshot id ("distill-acp") is the same source; treating it as a source
    /// switch silently replaced the thread's model with the last-used one after
    /// turn 1, and the next turn sent a foreign model into the same session.
    func test_defaultInstanceAliasRemap_keepsThreadPinnedModel() async throws {
        let (vm, repo) = try makeVM()
        let suiteName = "rc2-alias-model-" + UUID().uuidString
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = AgentLastModelStore(defaults: suite)
        store.remember(model: "claude/claude-opus-5-5", for: .distill)
        vm.lastModelStore = store
        let thread = AgentThread(
            workspaceId: vm.workspaceID,
            title: "bot thread",
            provider: .distill,
            providerInstanceId: "distill",
            model: "muse-spark-1.3-contributor"
        )
        try repo.upsert(thread)
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.providerInstanceId, "distill")
        XCTAssertEqual(vm.model, "muse-spark-1.3-contributor")

        // The custom model is deliberately absent from the discovered list.
        let distillACP = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "claude/claude-opus-5-5", label: "Claude Opus 5.5", provider: .distill)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp"
        )
        vm.providerSnapshotLoader = { [distillACP] }
        await vm.loadProviderSnapshots()

        XCTAssertEqual(vm.providerInstanceId, "distill-acp", "the alias still maps to the real snapshot id")
        XCTAssertEqual(vm.model, "muse-spark-1.3-contributor",
                       "an alias remap is not a source change and must not swap in the last-used model")
    }

    /// WHY: loading real provider snapshots must restore canonical draft state only for selected thread.
    /// WHY: canonical draft must return only to its owner thread after alias mapping.
    func test_defaultInstanceAliasRemapRestoresCanonicalPersistedDraftAcrossThreads() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-alias-draft-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let store = AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments"))
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
                                              providers: [.distill: FakeProviderRunner(provider: .distill)])
        let a = AgentThread(workspaceId: workspaceID, title: "A", provider: .distill, providerInstanceId: "distill", model: "muse")
        let b = AgentThread(workspaceId: workspaceID, title: "B", provider: .distill, providerInstanceId: "distill", model: "muse")
        try threadRepo.upsert(a)
        try threadRepo.upsert(b)
        let source = URL(fileURLWithPath: tmp).appendingPathComponent("private.png")
        try Data("image".utf8).write(to: source)
        let attachment = AgentAttachment(path: source.path, kind: .image, mimeType: "image/png", sizeBytes: 5)
        try draftRepo.upsert(AgentThreadDraft(threadId: a.id, providerInstanceId: "distill-acp",
                                              text: "canonical draft", attachments: [attachment], interactionMode: .default))

        let cold = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp, coordinator: coordinator,
                                     threadRepo: threadRepo, messageRepo: messageRepo,
                                     draftRepo: draftRepo, attachmentStore: store, initialThreadId: a.id)
        let distillACP = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "muse", label: "Muse", provider: .distill)],
            binaryPath: "/usr/bin/true", authenticated: true, id: "distill-acp"
        )
        cold.providerSnapshotLoader = { [distillACP] }
        await cold.loadProviderSnapshots()
        XCTAssertEqual(cold.prompt, "canonical draft")
        XCTAssertEqual(cold.attachments, [attachment])
        XCTAssertEqual(cold.interactionMode, .default)

        XCTAssertEqual(cold.interactionMode, .default)
        cold.selectThread(b.id)
        await cold.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(cold.prompt, "")
        XCTAssertTrue(cold.attachments.isEmpty)
        XCTAssertEqual(cold.interactionMode, .default)
        cold.selectThread(a.id)
        await cold.waitForSelectThreadHydrationForTesting()
        await cold.loadProviderSnapshots()
        XCTAssertEqual(cold.prompt, "canonical draft")
        XCTAssertEqual(cold.attachments, [attachment])
        XCTAssertEqual(cold.interactionMode, .default)
    }

    /// WHY: a user's cleared raw-alias edit must not revive stale canonical draft.
    /// WHY: a user's cleared raw-alias edit must not revive stale canonical draft.
    func test_defaultInstanceAliasRemapPreservesPlanDraftOnlyOnItsThread() async throws {
        let (vm, threads) = try makeVM()
        defer { vm.dispose(); try? FileManager.default.removeItem(atPath: vm.cwd) }
        let drafts = try XCTUnwrap(vm.draftRepo)
        let a = AgentThread(workspaceId: vm.workspaceID, title: "Plan draft A", provider: .codex, providerInstanceId: "codex", model: "gpt-test")
        let b = AgentThread(workspaceId: vm.workspaceID, title: "Empty B", provider: .codex, providerInstanceId: "codex", model: "gpt-test")
        try threads.upsert(a)
        try threads.upsert(b)
        let file = URL(fileURLWithPath: vm.cwd).appendingPathComponent("plan-draft.png")
        try Data("image".utf8).write(to: file)
        let attachment = AgentAttachment(path: file.path, kind: .image, mimeType: "image/png", sizeBytes: 5)
        try drafts.upsert(AgentThreadDraft(threadId: a.id, providerInstanceId: "codex-cli", text: "Plan only for A", attachments: [attachment], interactionMode: .plan))
        vm.selectThread(a.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.providerInstanceId, "codex")
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-test", label: "GPT", provider: .codex)],
            binaryPath: "/usr/bin/true", authenticated: true, id: "codex-cli"
        )
        XCTAssertTrue(snapshot.interactionModes.contains(.plan))
        vm.providerSnapshotLoader = { [snapshot] }
        await vm.loadProviderSnapshots()
        XCTAssertEqual(vm.prompt, "Plan only for A")
        XCTAssertEqual(vm.attachments, [attachment])
        XCTAssertEqual(vm.interactionMode, .plan)
        vm.selectThread(b.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertTrue(vm.prompt.isEmpty)
        XCTAssertTrue(vm.attachments.isEmpty)
        XCTAssertEqual(vm.interactionMode, .default)
        vm.selectThread(a.id)
        await vm.waitForSelectThreadHydrationForTesting()
        await vm.loadProviderSnapshots()
        XCTAssertEqual(vm.prompt, "Plan only for A")
        XCTAssertEqual(vm.attachments, [attachment])
        XCTAssertEqual(vm.interactionMode, .plan)
    }

    func test_defaultInstanceAliasRemapDoesNotRestoreCanonicalDraftAfterRawEditCleared() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-alias-clear-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let repo = AgentThreadRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo, threadRepo: repo,
                                              providers: [.distill: FakeProviderRunner(provider: .distill)])
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp, coordinator: coordinator,
                                   threadRepo: repo, messageRepo: messageRepo, draftRepo: draftRepo,
                                   attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")),
                                   promptHistoryStore: PromptHistoryStore(db: db))
        let thread = AgentThread(workspaceId: workspaceID, title: "A", provider: .distill,
                                 providerInstanceId: "distill", model: "muse")
        try repo.upsert(thread)
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        let canonical = AgentThreadDraft(threadId: thread.id, providerInstanceId: "distill-acp",
                                         text: "old canonical", attachments: [], interactionMode: .default)
        // Write canonical row through the real repository owned by the VM setup.
        try draftRepo.upsert(canonical)
        vm.prompt = "temporary raw edit"
        vm.promptWasEdited()
        vm.prompt = ""
        vm.promptWasEdited()
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "muse", label: "Muse", provider: .distill)],
            binaryPath: "/usr/bin/true", authenticated: true, id: "distill-acp"
        )
        vm.providerSnapshotLoader = { [snapshot] }
        await vm.loadProviderSnapshots()
        XCTAssertEqual(vm.prompt, "")
    }

    /// WHY: a thread pinned to a vanished configured instance changed sources and must use preferred model.
    func test_realInstanceChange_stillAppliesPreferredModel() async throws {
        let (vm, repo) = try makeVM()
        let suiteName = "rc2-instance-model-" + UUID().uuidString
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = AgentLastModelStore(defaults: suite)
        store.remember(model: "claude/claude-opus-5-5", for: .distill)
        vm.lastModelStore = store
        let thread = AgentThread(
            workspaceId: vm.workspaceID,
            title: "work account thread",
            provider: .distill,
            providerInstanceId: "distill-work",
            model: "work-only-model"
        )
        try repo.upsert(thread)
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()

        let distillACP = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "claude/claude-opus-5-5", label: "Claude Opus 5.5", provider: .distill)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp"
        )
        vm.providerSnapshotLoader = { [distillACP] }
        await vm.loadProviderSnapshots()

        XCTAssertEqual(vm.providerInstanceId, "distill-acp")
        XCTAssertEqual(vm.model, "claude/claude-opus-5-5",
                       "a different configured instance is a source change and keeps the reset")
    }

    /// WHY: explicit Source pick of an unrunnable provider must stay sticky so
    /// recovery UI is not thrashed by snapshot refresh.
    func test_userPinnedUnrunnableSource_notReboundOnSnapshotRefresh() async throws {
        let (vm, _) = try makeVM()
        let missingCodex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "",
            id: "codex-cli"
        )
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "claude-cli"
        )
        vm.providerSnapshotLoader = { [missingCodex, claude] }
        await vm.loadProviderSnapshots()
        XCTAssertEqual(vm.provider, .claude)
        vm.setProviderInstance("codex-cli")
        XCTAssertTrue(vm.sourceSelectionUserPinned)
        XCTAssertEqual(vm.provider, .codex)
        await vm.loadProviderSnapshots()
        XCTAssertEqual(vm.provider, .codex,
                       "pinned unrunnable Codex must survive snapshot refresh for recovery")
    }

    /// WHY: Airton had Claude + Grok installed, Codex path missing. Empty Agent
    /// App defaulted to Codex and blocked send — no provider is mandatory.
    func test_missingCodexDoesNotBlockClaudeOrGrokOnEmptyAgentApp() async throws {
        let (vm, _) = try makeVM()
        // Fresh empty surface defaults to Codex before discovery.
        vm.provider = .codex
        vm.providerInstanceId = "codex"
        vm.model = "gpt-5.5"
        let missingCodex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "",
            id: "codex-cli"
        )
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
            binaryPath: "/Users/airtonempath/.local/bin/claude",
            authenticated: true,
            id: "claude-cli"
        )
        let grok = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
            binaryPath: "/Users/airtonjunior/.grok/bin/grok",
            authenticated: true,
            id: "grok-cli"
        )
        vm.providerSnapshotLoader = { [missingCodex, claude, grok] }

        await vm.loadProviderSnapshots()

        XCTAssertNotEqual(vm.provider, .codex,
                          "missing Codex CLI must not remain selected when Claude/Grok can run")
        XCTAssertEqual(vm.provider, .claude,
                       "rebind to first runnable provider in allCases order (Claude before Grok)")
        XCTAssertEqual(vm.providerInstanceId, "claude-cli")
        XCTAssertTrue(vm.selectedProviderCanRun,
                      "composer send/controls must enable on a runnable non-Codex provider")
        XCTAssertEqual(vm.model, "opus",
                       "model list must follow the rebound provider")
    }

    /// WHY: nil snapshot used to look runnable (canRun true), so send hit
    /// preflight and only then showed "Provider capabilities are not loaded yet."
    func test_nilProviderSnapshotFailsClosedBeforeSend() async throws {
        let adapter = CapturingProviderAdapter(provider: .grok)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.provider = .grok
        vm.providerInstanceId = "grok"
        vm.providerSnapshots = []
        vm.providerSnapshotLoader = { [] }
        vm.prompt = "should not send without capabilities"

        XCTAssertEqual(
            AgentAppViewModel.providerExecutionUnavailableReason(for: nil),
            AgentProviderRunPreflightError.missingSnapshot.description,
            "nil snapshot must fail closed with the same user-facing capabilities message as preflight"
        )
        XCTAssertFalse(vm.selectedProviderCanRun)

        await vm.send()

        // send reloads snapshots; empty loader still leaves canRun false if no row.
        XCTAssertTrue(adapter.sentTurns.isEmpty,
                      "send must not start a provider turn while capabilities are unloaded")
        XCTAssertEqual(vm.statusMessage, AgentProviderRunPreflightError.missingSnapshot.description)
    }

    func test_executionModeControlsPersistBeforeConversationAndLockAfterStart() throws {
        let (vm, repo) = try makeVM()
        vm.gitBranch = "main"
        vm.createThread(title: "isolated")
        vm.setExecutionMode(.worktree)
        vm.setBaseBranch("feature-base")

        let id = try XCTUnwrap(vm.selectedThreadId)
        var thread = try XCTUnwrap(try repo.get(id: id))
        XCTAssertEqual(thread.executionMode, .worktree,
                       "macOS Agent App must expose and persist worktree execution before the first provider turn")
        XCTAssertEqual(thread.baseBranch, "feature-base")

        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "started"))
        vm.setExecutionMode(.local)
        thread = try XCTUnwrap(try repo.get(id: id))
        XCTAssertEqual(thread.executionMode, .worktree,
                       "execution mode must lock after conversation start so a long-running agent cannot silently move between local and worktree cwd")
    }

    func test_newThreadDoesNotInheritWorktreeExecution() throws {
        let (vm, repo) = try makeVM()
        vm.gitBranch = "production"
        vm.createThread(title: "isolated source")
        vm.setExecutionMode(.worktree)
        vm.setBaseBranch("production")

        vm.createThread(title: "local successor")

        let thread = try XCTUnwrap(try repo.get(id: try XCTUnwrap(vm.selectedThreadId)))
        XCTAssertEqual(thread.executionMode, .local,
                       "a new thread must not create a worktree just because the previous thread used one")
        XCTAssertNil(thread.baseBranch,
                     "a local new thread must not retain the previous worktree base branch")
        XCTAssertNil(thread.worktreePath,
                     "a new thread must not point at a workspace it did not explicitly create")
    }

    func test_providerStatusMessageComesFromSnapshot() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex Work",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: false,
                status: .unavailable,
                statusDetail: "Codex binary missing.",
                authenticated: true,
                accountLabel: "work@example.com",
                accountAuthMethod: "oauth",
                models: [],
                slashCommands: ["/goal"]
            )
        ]

        XCTAssertEqual(vm.providerDisplayName(.codex), "Codex Work")
        XCTAssertEqual(vm.providerStatusMessage, "Codex binary missing.",
                       "macOS Agent App must surface provider status from the host/provider snapshot before the user sends")
        XCTAssertEqual(vm.providerAccountStatusMessage, "Codex Work: work@example.com via oauth",
                       "macOS Agent App provider cards must surface account label and auth method before a long run starts")
        XCTAssertEqual(vm.providerRecoveryActionTitle, "Copy install command",
                       "provider cards must expose an immediate recovery action when the selected CLI is unavailable")
    }

    func test_providerRecoveryActionRunsInstanceScopedUpdateAndRefreshesSnapshots() async throws {
        let (vm, _) = try makeVM()
        vm.provider = .claude
        vm.providerInstanceId = "claude-work"
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "claude-work",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude Work",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .warning,
                statusDetail: "Update available: Claude Code 2.2.0",
                authenticated: true,
                models: [AgentModelDescriptor(id: "claude-sonnet-4-5", label: "Claude Sonnet 4.5", provider: .claude)],
                slashCommands: ["/status"],
                advisory: "Update available: Claude Code 2.2.0",
                updateState: "update_available"
            )
        ]
        var updatedProvider: AgentProvider?
        var updatedInstance: String?
        vm.providerRecoveryAction = { provider, instanceId in
            updatedProvider = provider
            updatedInstance = instanceId
            return "updated claude\n"
        }
        vm.providerSnapshotLoader = {
            [AgentProviderSnapshot(
                id: "claude-work",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude Work",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                statusDetail: nil,
                authenticated: true,
                models: [AgentModelDescriptor(id: "claude-sonnet-4-5", label: "Claude Sonnet 4.5", provider: .claude)],
                slashCommands: ["/status"],
                advisory: nil,
                updateState: nil
            )]
        }

        XCTAssertEqual(vm.providerRecoveryActionTitle, "Update Claude Work")

        await vm.performProviderRecoveryAction()

        XCTAssertEqual(updatedProvider, .claude)
        XCTAssertEqual(updatedInstance, "claude-work",
                       "provider recovery actions must stay instance-scoped so work/personal provider cards do not update the wrong account")
        XCTAssertEqual(vm.providerRecoveryStatusMessage, "updated claude")
        XCTAssertEqual(vm.selectedProviderSnapshot?.status, .available,
                       "provider cards must refresh after recovery so stale warnings do not remain before long runs")
    }

    func test_preparePullRequestThreadUsesCurrentAgentConfigAndSelectsWorktreeThread() async throws {
        let (vm, repo) = try makeVM()
        vm.providerSnapshots = []
        vm.provider = .codex
        vm.providerInstanceId = "codex-work"
        vm.availableModels = [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, supportsReasoning: true, supportsServiceTier: true)]
        vm.model = "gpt-5.5"
        vm.permissionMode = .fullAccess
        vm.reasoningEffort = .high
        vm.serviceTier = .fast
        vm.pullRequestURL = " https://github.com/acme/widget/pull/7 "
        var captured: (String, AgentProvider, String, AgentPermissionMode, AgentReasoningEffort, AgentServiceTier, String?)?
        vm.pullRequestThreadPreparer = { url, provider, model, permission, reasoning, serviceTier, _, providerInstanceId in
            captured = (url, provider, model, permission, reasoning, serviceTier, providerInstanceId)
            let thread = AgentThread(
                workspaceId: vm.workspaceID,
                title: "PR #7: acme/widget",
                provider: provider,
                providerInstanceId: providerInstanceId,
                model: model,
                permissionMode: permission,
                reasoningEffort: reasoning,
                executionMode: .worktree,
                baseBranch: "rc-pr/github-com/acme-widget-7",
                worktreePath: "/tmp/rc-pr-7",
                serviceTier: serviceTier
            )
            try repo.upsert(thread)
            return thread
        }

        await vm.preparePullRequestThread()

        XCTAssertEqual(captured?.0, "https://github.com/acme/widget/pull/7")
        XCTAssertEqual(captured?.1, .codex)
        XCTAssertEqual(captured?.2, "gpt-5.5")
        XCTAssertEqual(captured?.3, .fullAccess)
        XCTAssertEqual(captured?.4, .high)
        XCTAssertEqual(captured?.5, .fast)
        XCTAssertEqual(captured?.6, "codex-work",
                       "opening a PR as an Agent thread must preserve the selected provider instance so work/personal sessions do not collapse")
        XCTAssertEqual(vm.selectedThreadId.flatMap { try? repo.get(id: $0) }?.worktreePath, "/tmp/rc-pr-7",
                       "the macOS Agent App must select the isolated PR worktree thread after preparation")
        XCTAssertEqual(vm.pullRequestURL, "")
    }

    func test_providerInstanceSelectionPersistsAndReachesProviderRun() async throws {
        let capture = CapturingProviderRunner(provider: .codex)
        let (vm, repo) = try makeVM(provider: capture)
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-personal",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex Personal",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: ["/goal"]
            ),
            AgentProviderSnapshot(
                id: "codex-work",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex Work",
                accentColor: "#125A9C",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "gpt-5.4", label: "GPT-5.4", provider: .codex)],
                slashCommands: ["/goal"]
            )
        ]
        vm.providerLaunchConfig = { _, instanceId in
            ("/usr/bin/env", instanceId == "codex-work" ? ["CODEX_HOME": "/tmp/codex-work"] : [:])
        }

        vm.setProviderInstance("codex-work")
        vm.createThread(title: "instance")
        vm.prompt = "check instance routing"
        await vm.send()

        let thread = try XCTUnwrap(vm.selectedThreadId.flatMap { try? repo.get(id: $0) })
        XCTAssertEqual(thread.providerInstanceId, "codex-work",
                       "the selected provider instance must persist on the thread before the first turn starts")
        XCTAssertEqual(capture.providerInstanceIds.last, "codex-work",
                       "macOS Agent App must route the actual run by selected provider instance, not just provider type")
        XCTAssertEqual(capture.providerBinaries.last, "/usr/bin/env")
        XCTAssertEqual(capture.environments.last?["CODEX_HOME"], "/tmp/codex-work")
    }

    func test_distillProviderRunsAndResumesWithPersistedSessionInAgentApp() async throws {
        // WHY: the Agent App must send through the selected provider and restore its provider session after reopening.
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-distill-restart-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let history = PromptHistoryStore(db: db)
        let capture = CapturingProviderRunner(provider: .distill, completionDelayNanoseconds: 20_000_000, finalMessage: "Distill reply")
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "gpt-6-luna", label: "GPT-6 Luna", provider: .distill)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill",
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )

        let firstCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.distill: capture]
        )
        let firstVM = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: firstCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            promptHistoryStore: history,
            initialThreadId: nil
        )
        firstVM.providerSnapshots = [snapshot]
        firstVM.setProvider(.distill)
        firstVM.createThread(title: "Distill session")
        let threadID = try XCTUnwrap(firstVM.selectedThreadId)
        firstVM.setModel("gpt-6-luna")
        firstVM.prompt = "first Distill turn"
        await firstVM.send()
        await waitAsync("Distill response and provider cursor persist") {
            (try? messageRepo.list(threadId: threadID))?.contains { $0.role == .assistant && $0.content == "Distill reply" } == true
                && (try? threadRepo.get(id: threadID)?.providerThreadId)?.isEmpty == false
        }
        let savedProviderThreadID = try XCTUnwrap(try threadRepo.get(id: threadID)?.providerThreadId)
        XCTAssertEqual(try XCTUnwrap(threadRepo.get(id: threadID)).provider, .distill)
        XCTAssertEqual(try XCTUnwrap(threadRepo.get(id: threadID)).model, "gpt-6-luna")

        let secondCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.distill: capture]
        )
        let reopenedVM = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: secondCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            promptHistoryStore: history,
            initialThreadId: threadID
        )
        reopenedVM.providerSnapshots = [snapshot]
        XCTAssertEqual(reopenedVM.provider, .distill)
        XCTAssertEqual(reopenedVM.model, "gpt-6-luna")
        reopenedVM.prompt = "follow-up Distill turn"
        await reopenedVM.send()
        await waitAsync("Distill follow-up reaches the restored provider session") {
            capture.prompts.count == 2
        }
        XCTAssertEqual(capture.providerInstanceIds, ["distill", "distill"])
        XCTAssertEqual(capture.requestProviderThreadIds.first ?? nil, nil)
        XCTAssertEqual(capture.requestProviderThreadIds.dropFirst().first ?? nil, savedProviderThreadID)
    }

    func test_legacyProviderThreadIsReadOnly_becauseRemoteCodeRunsDistillOnly() async throws {
        AgentProvider.selectableForTesting = nil
        defer { AgentProvider.selectableForTesting = AgentProvider.allCases }
        let tmp = NSTemporaryDirectory() + "rc2-vm-legacy-provider-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let capture = CapturingProviderRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
                                              providers: [.codex: capture])
        let legacy = AgentThread(workspaceId: workspaceID, title: "old codex chat", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(legacy)
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp, coordinator: coordinator,
                                   threadRepo: threadRepo, messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db), initialThreadId: legacy.id)
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/bin/true",
            authenticated: true
        )]

        XCTAssertEqual(vm.selectedThreadId, legacy.id)
        XCTAssertTrue(vm.isLegacyProviderThread, "the banner and disabled composer key off this flag")
        XCTAssertEqual(
            vm.legacyProviderBannerText,
            "This conversation used Codex. MacCode now runs Distill only, so it is read-only."
        )

        vm.prompt = "hello?"
        await vm.send()
        await vm.retryLastPrompt()
        XCTAssertTrue(capture.prompts.isEmpty, "a read-only thread must never spawn a provider process")
        XCTAssertEqual(try messageRepo.list(threadId: legacy.id).count, 0)
        XCTAssertNotNil(vm.statusMessage)
        let threadCountBeforeFork = try threadRepo.list(workspaceId: workspaceID).count
        await vm.forkCurrentThread()
        XCTAssertEqual(try threadRepo.list(workspaceId: workspaceID).count, threadCountBeforeFork,
                       "forking a read-only thread would start the legacy provider")

        vm.createThread(title: "fresh")
        XCTAssertEqual(vm.provider, .distill, "the banner's new-conversation action starts a Distill thread")
        XCTAssertFalse(vm.isLegacyProviderThread)
    }

    func test_newThreadFromLegacyThreadWithHistoryCreatesDistillThread_becausePlusMustWorkOnReadOnlyThreads() throws {
        AgentProvider.selectableForTesting = nil
        defer { AgentProvider.selectableForTesting = AgentProvider.allCases }
        let tmp = NSTemporaryDirectory() + "rc2-vm-legacy-provider-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo, providers: [:])
        let legacy = AgentThread(workspaceId: workspaceID, title: "old grok chat", provider: .grok, model: "grok-4")
        try threadRepo.upsert(legacy)
        try messageRepo.append(AgentMessage(threadId: legacy.id, role: .user, content: "old message"))
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp, coordinator: coordinator,
                                   threadRepo: threadRepo, messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db), initialThreadId: legacy.id)

        XCTAssertEqual(vm.selectedThreadId, legacy.id)
        vm.selectThread(legacy.id)
        vm.messages = try messageRepo.list(threadId: legacy.id)
        XCTAssertTrue(vm.providerLocked, "legacy history locks provider switching")
        let countBefore = try threadRepo.list(workspaceId: workspaceID).count
        // The "+" and "New Distill conversation" buttons call createThread while a read-only thread is selected.
        vm.createThread(title: "New thread")

        XCTAssertEqual(try threadRepo.list(workspaceId: workspaceID).count, countBefore + 1)
        let newThreadId = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertNotEqual(newThreadId, legacy.id)
        XCTAssertEqual(try threadRepo.get(id: newThreadId)?.provider, .distill)
        XCTAssertEqual(try threadRepo.get(id: legacy.id)?.provider, .grok)
    }

    func test_restartedAgentAppSendsFollowupWithPersistedProviderThreadId() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-restart-continuity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let history = PromptHistoryStore(db: db)
        let capture = CapturingProviderRunner(provider: .codex, completionDelayNanoseconds: 20_000_000)
        let firstCoordinator = AgentRunCoordinator(runRepo: runRepo,
                                                   messageRepo: messageRepo,
                                                   threadRepo: threadRepo,
                                                   providers: [.codex: capture])
        let firstVM = AgentAppViewModel(workspaceID: workspaceID,
                                        cwd: tmp,
                                        coordinator: firstCoordinator,
                                        threadRepo: threadRepo,
                                        messageRepo: messageRepo,
                                        promptHistoryStore: history)
        installRunnableProviderFixtures(on: firstVM)

        firstVM.createThread(title: "restart continuity")
        let threadId = try XCTUnwrap(firstVM.selectedThreadId)
        firstVM.prompt = "first turn"
        await firstVM.send()
        await waitAsync("first turn persists provider cursor") {
            (try? threadRepo.get(id: threadId)?.providerThreadId)?.isEmpty == false
        }
        let persistedProviderThreadId = try XCTUnwrap(try threadRepo.get(id: threadId)?.providerThreadId)

        let secondCoordinator = AgentRunCoordinator(runRepo: runRepo,
                                                    messageRepo: messageRepo,
                                                    threadRepo: threadRepo,
                                                    providers: [.codex: capture])
        // Per-surface binding: restore reopens the surface's bound thread. The
        // host restore path (reinstantiateRestoredSurfaces) reads the persisted
        // `selected_thread` metadata and passes it as initialThreadId; we mirror
        // that here instead of relying on the removed auto-select-first behavior.
        let restartedVM = AgentAppViewModel(workspaceID: workspaceID,
                                            cwd: tmp,
                                            coordinator: secondCoordinator,
                                            threadRepo: threadRepo,
                                            messageRepo: messageRepo,
                                            promptHistoryStore: history,
                                            initialThreadId: threadId)
        installRunnableProviderFixtures(on: restartedVM)

        XCTAssertEqual(restartedVM.selectedThreadId, threadId,
                       "after app restart, Agent App must reopen the persisted thread before follow-up sends")
        restartedVM.prompt = "second turn after restart"
        await restartedVM.send()
        await waitAsync("follow-up request captured") { capture.prompts.count >= 2 }

        XCTAssertEqual(capture.requestProviderThreadIds.first ?? nil, nil,
                       "the first turn should start a fresh provider session")
        XCTAssertEqual(capture.requestProviderThreadIds.dropFirst().first ?? nil, persistedProviderThreadId,
                       "after app restart, Agent App must send follow-ups with the persisted provider thread id instead of forking a disconnected agent session")
    }

    func test_contextHealthMessageShowsTokenBudgetAndCompaction() throws {
        let (vm, _) = try makeVM()
        // Percentage is driven by per-request contextTokens, not cumulative totalTokens.
        vm.timeline.apply(.tokenUsage(AssistantTokenUsage(
            inputTokens: 400,
            outputTokens: 100,
            totalTokens: 500,
            contextWindow: 1_000,
            compactsAutomatically: true,
            contextTokens: 500
        )))

        XCTAssertEqual(vm.contextHealthMessage, "Context 50% · 500 / 1000 tokens · auto-compacts",
                       "macOS Agent App must expose context usage and automatic compaction capability so long agent runs do not silently approach the context limit")

        vm.timeline.apply(.contextCompaction(summary: "older turns summarized"))
        XCTAssertEqual(vm.contextHealthMessage, "Context 50% · 500 / 1000 tokens · auto-compacts · compacted",
                       "macOS Agent App must surface compaction state so long-run behavior is visible")
    }

    func test_timelineItemPresentationKeepsProgressAndChannelsDistinct() {
        let running = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "cmd-1",
            turnId: "turn-1",
            type: .commandExecution,
            state: .streaming,
            summary: "swift test",
            startedAtMs: 1
        ))
        XCTAssertEqual(running.icon, "circle.dotted")
        XCTAssertEqual(running.verb, "Running")
        XCTAssertEqual(running.label, "swift test")

        let failed = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "cmd-2",
            turnId: "turn-1",
            type: .commandExecution,
            state: .failed,
            body: "xcodebuild test",
            startedAtMs: 2
        ))
        XCTAssertEqual(failed.icon, "xmark.octagon")
        XCTAssertEqual(failed.verb, "Failed")

        let changed = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "file-1",
            turnId: "turn-1",
            type: .fileChange,
            state: .completed,
            summary: "Edited AgentThreadView.swift",
            output: "1 file changed",
            startedAtMs: 3
        ))
        XCTAssertEqual(changed.icon, "doc.badge.gearshape")
        XCTAssertEqual(changed.verb, "Changed")
        XCTAssertEqual(changed.detail, "1 file changed")

        let reasoning = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "think-1",
            turnId: "turn-1",
            type: .reasoning,
            state: .completed,
            summary: "Need provider parity",
            startedAtMs: 4
        ))
        XCTAssertEqual(reasoning.detail, "Need provider parity",
                       "reasoning summaries must stay visible even when providers send summary-only deltas")

        let issue = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "err-1",
            turnId: "turn-1",
            type: .error,
            state: .completed,
            body: "Unsupported realtime event",
            startedAtMs: 5
        ))
        XCTAssertEqual(issue.icon, "exclamationmark.triangle")
        XCTAssertEqual(issue.verb, "Issue")
    }

    func test_composerSuggestsProviderSlashCommandsAndSkills() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [],
                slashCommands: ["/goal", "/review"],
                skills: ["sam-fix-bug", "sam-review-code"]
            )
        ]

        vm.prompt = "/go"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["/goal "],
                       "provider-owned slash commands must be discoverable instead of requiring memorized syntax")

        vm.prompt = "use $sam-f"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["$sam-fix-bug "],
                       "Codex skills from the provider snapshot must be selectable from the composer")

        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "grok-cli",
                provider: .grok,
                driverKind: .grokCLI,
                displayName: "Grok",
                accentColor: "#1DA1F2",
                continuationGroup: "xai-grok",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                models: [],
                slashCommands: ["/status"],
                skills: ["sam-work", "sam-codex-advisor", "sam-fix-bug"]
            )
        ]
        vm.provider = .grok
        vm.providerInstanceId = "grok-cli"
        vm.prompt = "$sam-work"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["$sam-work "],
                       "Grok skills must autocomplete from the provider snapshot with $ prefix")
        XCTAssertEqual(vm.composerSuggestions.first?.subtitle, "Grok skill",
                       "skill subtitle must use the active provider display name, not a hard-coded Codex label")
        vm.prompt = "$sam-codex"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["$sam-codex-advisor "],
                       "partial $ skill queries must rank prefix matches for every provider")

        // Shared catalog: either trigger surfaces skills and modes with the typed prefix.
        vm.prompt = "/sam-work"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["/sam-work "],
                       "/sam-work must autocomplete skills under the slash trigger")
        XCTAssertEqual(vm.composerSuggestions.first?.kind, .skill)
        vm.prompt = "$stat"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["$status "],
                       "$status must autocomplete modes under the dollar trigger")
        XCTAssertEqual(vm.composerSuggestions.first?.kind, .slashCommand)
    }

    // WHY: real Codex/Grok skill dirs often have 50–80 skills. Ranking them with
    // modes under a shared limit of 8 buried /goal and /plan under ads-* on bare `/`.
    func test_composerPrioritizesCommandsOverSkillsUnderCatalogFlood() throws {
        let flood = (0..<40).map { "ads-skill-\($0)" }
        let suggestions = AgentComposerSuggestions.suggestions(
            for: "/",
            snapshot: AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [],
                slashCommands: ["/goal", "/review"],
                skills: flood
            ),
            localSlashCommands: AgentAppViewModel.localSlashCommands,
            limit: 8
        )
        let titles = suggestions.map(\.title)
        XCTAssertTrue(titles.contains("/goal"),
                      "/goal must remain discoverable on bare / even when dozens of skills exist")
        XCTAssertTrue(titles.contains("/plan"),
                      "/plan must remain discoverable on bare / even when dozens of skills exist")
        XCTAssertTrue(suggestions.filter { $0.kind == .slashCommand }.count >= 6,
                      "the first page of bare-/ suggestions must be dominated by commands, not skills")
        // Commands are never truncated and always rank ahead; skills then get
        // their OWN bounded budget (they must stay discoverable, not banned —
        // the old page-exclusion hid every project/user skill on bare `/`).
        let lastCommandIndex = suggestions.lastIndex { $0.kind == .slashCommand }
        let firstSkillIndex = suggestions.firstIndex { $0.kind == .skill }
        if let lastCommandIndex, let firstSkillIndex {
            XCTAssertLessThan(lastCommandIndex, firstSkillIndex,
                              "every command must rank ahead of the first ads-* skill")
        }
        XCTAssertLessThanOrEqual(suggestions.filter { $0.kind == .skill }.count, 8,
                                 "flooding skills stay within their own page budget")
    }

    func test_normalizingComposerTriggerPrefix_commandsAndSkillsWithEitherTrigger() {
        let local = AgentAppViewModel.localSlashCommands
        let provider = ["/goal", "/review"]
        let skills = ["sam-work", "sam-codex-advisor"]

        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "$goal continue until done",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "/goal continue until done",
            "$goal must become /goal so providers receive a command token"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/goal continue until done",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "/goal continue until done",
            "/goal must stay a slash command"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "$sam-work implement the fix",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "$sam-work implement the fix",
            "$skill must stay the canonical skill trigger"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/sam-work implement the fix",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "$sam-work implement the fix",
            "/skill must normalize to $skill so skills work with either trigger"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/sam-codex-advisor review this",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "$sam-codex-advisor review this",
            "any known skill under / must rewrite to $"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/plan ship it",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "/plan ship it",
            "commands win over skills on name collision — plan stays a mode"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/unknown-thing keep me",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "/unknown-thing keep me",
            "unknown first tokens must not be rewritten"
        )
    }

    // WHY: users autocomplete skills under / or $; send must forward the canonical $ form.
    func test_slashSkillSendNormalizesToDollarSkillForProvider() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .grok)
        vm.coordinator.replaceProvider(.grok, runner: runner)
        vm.provider = .grok
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "grok-cli",
                provider: .grok,
                driverKind: .grokCLI,
                displayName: "Grok",
                accentColor: "#1DA1F2",
                continuationGroup: "xai-grok",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
                slashCommands: ["/status", "/goal"],
                skills: ["sam-work", "sam-codex-advisor"]
            )
        ]
        vm.providerInstanceId = "grok-cli"
        vm.createThread(title: "slash-skill")
        vm.prompt = "/sam-work implement the fix"

        await vm.send()

        await waitAsync("slash skill normalizes to dollar skill") {
            runner.prompts.contains("$sam-work implement the fix")
        }
        XCTAssertFalse(runner.prompts.contains(where: { $0.hasPrefix("/sam-work") }),
                       "/sam-work must not be forwarded literally — skills use $")
    }

    func test_applyComposerSuggestionReplacesOnlyActiveToken() throws {
        let (vm, _) = try makeVM()
        vm.prompt = "before $sam-r"
        vm.applyComposerSuggestion(AgentComposerSuggestion(
            title: "$sam-review-code",
            subtitle: "Codex skill",
            insertText: "$sam-review-code ",
            kind: .skill
        ))

        XCTAssertEqual(vm.prompt, "before $sam-review-code ",
                       "selecting a composer suggestion must preserve surrounding prompt text")
    }

    func test_providerCallbacksExposePendingAndStaleRowsForActionAndDiagnosis() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "callbacks")
        vm.timeline.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1
        )))
        vm.timeline.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-2",
            turnId: "turn-1",
            kind: .fileChange,
            title: "Edit file",
            state: .stale,
            createdAtMs: 2
        )))
        vm.timeline.apply(.userInputRequested(AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Pick mode",
            options: ["Plan", "Run"],
            createdAtMs: 3
        )))
        vm.timeline.apply(.requestResolved(requestId: "approval-1", state: .approved))

        XCTAssertEqual(vm.openPendingRequests, [],
                       "resolved and stale callbacks must never remain actionable")
        XCTAssertEqual(vm.visiblePendingRequests.map(\.id), ["approval-2"],
                       "stale provider callbacks must remain visible as read-only diagnostics after the turn can no longer answer them")
        XCTAssertEqual(vm.openPendingUserInputs.map(\.id), ["question-1"],
                       "macOS Agent App must surface provider questions so the user can unblock Codex/Claude")
    }

    func test_selectThreadRehydratesPersistedStaleCallbacksIntoTimeline() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-callback-rehydrate-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let callbackRepo = ProviderPendingCallbackRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "callbacks", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try callbackRepo.record(threadId: thread.id, request: AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1_000
        ))
        try callbackRepo.record(threadId: thread.id, userInput: AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Continue?",
            options: ["Plan", "Run"],
            createdAtMs: 2_000
        ))
        _ = try callbackRepo.markOpenStale(reason: "Provider callback state does not survive app restart.")
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coord,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   pendingCallbackRepo: callbackRepo)

        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()

        XCTAssertEqual(vm.timeline.pendingRequests.first?.state, .stale,
                       "persisted stale approvals must remain in timeline state for diagnostics after restart/reload")
        XCTAssertEqual(vm.timeline.pendingUserInputs.first?.state, .stale,
                       "persisted stale provider questions must remain in timeline state for diagnostics after restart/reload")
        XCTAssertEqual(vm.openPendingRequests, [],
                       "stale approvals must remain non-actionable after restart/reload")
        XCTAssertEqual(vm.openPendingUserInputs, [],
                       "stale provider questions must remain non-actionable after restart/reload")
        XCTAssertEqual(vm.visiblePendingRequests.map(\.id), ["approval-1"],
                       "stale approvals must reappear as read-only diagnostics after restart/reload")
        XCTAssertEqual(vm.visiblePendingUserInputs.map(\.id), ["question-1"],
                       "stale provider questions must reappear as read-only diagnostics after restart/reload")
    }

    // SEP-3: the off-main open bundle shares one callback decoder under a
    // lock instead of allocating per open. Seeded callbacks must decode into
    // pending events exactly like the MainActor rehydrate path.
    func test_gatherThreadOpenBundle_decodesPendingCallbacks() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-callback-bundle-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let callbackRepo = ProviderPendingCallbackRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "callbacks", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try callbackRepo.record(threadId: thread.id, request: AssistantPendingRequest(
            id: "approval-9",
            turnId: "turn-9",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 9_000
        ))
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: FakeProviderRunner(provider: .codex)])
        let bundle = await AgentAppViewModel.gatherThreadOpenBundle(
            threadId: thread.id,
            coordinator: coord,
            proposedPlanRepo: nil,
            pendingCallbackRepo: callbackRepo,
            checkpointRepo: nil,
            planNotesStore: nil,
            queuedMessageRepo: nil,
            includeRunStartedAt: false
        )
        XCTAssertTrue(bundle.pendingCallbackEvents.contains {
            if case .requestOpened(let req) = $0 { return req.id == "approval-9" }
            return false
        }, "off-main bundle must decode seeded approval callbacks via the shared decoder")
    }

    func test_failedPendingCallbackResponsesBecomeStaleAndNonActionable() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-callback-fail-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FailingCallbackRunner()])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        vm.createThread(title: "callbacks")
        await vm.waitForSelectThreadHydrationForTesting()
        vm.timeline.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1
        )))
        vm.timeline.apply(.userInputRequested(AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Continue?",
            options: ["Plan", "Run"],
            createdAtMs: 2
        )))

        vm.respondToPendingRequest(vm.openPendingRequests[0], response: .approve)
        vm.answerPendingUserInput(vm.openPendingUserInputs[0], answer: "Run")
        // respondToPendingRequest now drives the (async) coordinator.respondToRequest
        // off the main run loop; let that @MainActor task drain before asserting.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(vm.timeline.pendingRequests.first?.state, .stale,
                       "failed provider approval responses must be retained as stale diagnostics")
        XCTAssertEqual(vm.timeline.pendingUserInputs.first?.state, .stale,
                       "failed provider question responses must be retained as stale diagnostics")
        XCTAssertEqual(vm.openPendingRequests, [],
                       "failed provider approval responses must not leave a dead approve button")
        XCTAssertEqual(vm.openPendingUserInputs, [],
                       "failed provider question responses must not leave a dead answer card")
        XCTAssertTrue(vm.timeline.error?.contains("Provider user-input response failed") == true,
                      "callback loss must leave visible activity explaining why the user needs to restart the turn")
    }

    func test_multiSelectUserInputBuildsOneFinalAnswer() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "multi input")
        let request = AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Pick checks",
            options: ["Unit", "UI", "Docs"],
            allowsMultipleSelection: true,
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.toggleUserInputOption("UI", for: request)
        vm.toggleUserInputOption("Unit", for: request)
        let answer = vm.selectedUserInputAnswer(for: request)

        XCTAssertEqual(answer, "UI\nUnit",
                       "multi-select questions must submit one final answer atomically instead of resuming once per selected option")
    }

    func test_callbackDraftsAndSelectionsAreIsolatedByThreadAndRequestId() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "A")
        let threadA = try XCTUnwrap(vm.selectedThreadId)
        let requestA = AssistantUserInputRequest(
            id: "shared-request",
            turnId: "turn-a",
            prompt: "Pick A",
            options: ["A", "B"],
            createdAtMs: 1
        )
        vm.toggleUserInputOption("A", for: requestA)
        vm.userInputDrafts[vm.userInputStateKey(requestA)] = "draft-a"

        vm.createThread(title: "B")
        let requestB = AssistantUserInputRequest(
            id: "shared-request",
            turnId: "turn-b",
            prompt: "Pick B",
            options: ["A", "B"],
            createdAtMs: 2
        )

        XCTAssertEqual(vm.selectedUserInputAnswer(for: requestB), "",
                       "thread B must not inherit thread A's selection when provider request ids collide")
        XCTAssertNil(vm.userInputDrafts[vm.userInputStateKey(requestB)],
                     "thread B must not inherit thread A's freeform draft when request ids collide")

        vm.selectThread(threadA)
        XCTAssertEqual(vm.selectedUserInputAnswer(for: requestA), "A",
                       "returning to thread A must restore A's selection under the composite key")
        XCTAssertEqual(vm.userInputDrafts[vm.userInputStateKey(requestA)], "draft-a")
    }

    // Claude AskUserQuestion screenshot bug: the card showed raw JSON / an empty
    // "Input required" box. A structured request must collect each question's choice
    // and submit ONE answer map keyed by question text (the shape the Claude SDK
    // expects), then clear the card so it does not linger on screen.
    func test_submitAskUserQuestionBuildsAnswersKeyedByQuestionText() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "ask user question")
        let request = AssistantUserInputRequest(
            id: "ask-1",
            turnId: "turn-1",
            prompt: "Framework: Pick the framework?\nTargets: Which targets?",
            questions: [
                AssistantUserInputQuestion(
                    prompt: "Pick the framework?",
                    header: "Framework",
                    options: [
                        AssistantUserInputOption(label: "SwiftUI", detail: "Declarative"),
                        AssistantUserInputOption(label: "AppKit", detail: "Imperative"),
                    ],
                    allowsMultipleSelection: false
                ),
                AssistantUserInputQuestion(
                    prompt: "Which targets?",
                    header: "Targets",
                    options: [
                        AssistantUserInputOption(label: "macOS"),
                        AssistantUserInputOption(label: "iPadOS"),
                    ],
                    allowsMultipleSelection: true
                ),
            ],
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        XCTAssertFalse(vm.askUserQuestionIsComplete(request),
                       "submit must stay disabled until every question is answered")
        vm.selectAskUserQuestionOption("SwiftUI", question: request.questions[0], request: request)
        XCTAssertFalse(vm.askUserQuestionIsComplete(request),
                       "one answered question is not enough — all are required")
        vm.selectAskUserQuestionOption("macOS", question: request.questions[1], request: request)
        vm.selectAskUserQuestionOption("iPadOS", question: request.questions[1], request: request)
        XCTAssertTrue(vm.askUserQuestionIsComplete(request))

        vm.submitAskUserQuestion(request)
        await waitAsync("structured answer reaches adapter") {
            adapter.lastUserInputResponse?.requestId == "ask-1"
        }

        let text = try XCTUnwrap(adapter.lastUserInputResponse?.text)
        let answers = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(answers["Pick the framework?"], "SwiftUI",
                       "single-select answers must be keyed by the question text the Claude SDK expects")
        XCTAssertEqual(answers["Which targets?"], "iPadOS, macOS",
                       "multi-select answers must be one deterministically-ordered, comma-joined string")
        await waitAsync("structured question card clears") { vm.openPendingUserInputs.isEmpty }
        XCTAssertEqual(vm.openPendingUserInputs, [],
                       "answering a structured question must clear the card instead of leaving a stuck Input-required box")
    }

    func test_askUserQuestionOtherFreeformOverridesSelection() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask other")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-2", turnId: "turn-2", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.userInputDrafts[vm.askUserQuestionKey(request, question)] = "SQLite"
        XCTAssertTrue(vm.askUserQuestionIsComplete(request),
                      "a freeform Other answer must satisfy the question even with no option selected")
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "SQLite",
                       "Other freeform text must be usable as the answer (the SDK auto-provides an Other option)")
    }

    func test_askUserQuestionOptionAndOtherAreMutuallyExclusive() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask exclusive")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-3", turnId: "turn-3", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        // Typing Other clears any prior option selection.
        vm.selectAskUserQuestionOption("Postgres", question: question, request: request)
        vm.setAskUserQuestionOther("SQLite", question: question, request: request)
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "SQLite")
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("Postgres", question: question, request: request),
                       "typing an Other answer must clear a stale option selection")

        // Re-selecting an option clears the Other draft — so toggling it back off
        // cannot resurrect stale Other text and falsely satisfy the question.
        vm.selectAskUserQuestionOption("MySQL", question: question, request: request)
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "MySQL",
                       "selecting an option must supersede and clear the Other draft")
        vm.selectAskUserQuestionOption("MySQL", question: question, request: request) // toggle off (single-select)
        XCTAssertNil(vm.askUserQuestionAnswer(for: question, in: request),
                     "deselecting the last option must leave the question unanswered, not fall back to stale Other text")
        XCTAssertFalse(vm.askUserQuestionIsComplete(request))
    }

    // Screenshot bug: with a single-select option already chosen, the user could not
    // move the selection to "Other" because the option radio stayed marked and the
    // bare "Other…" field had no radio to claim the selection. The Other field must
    // be a real member of the radio group: clicking its radio selects Other and
    // deselects any chosen option; an empty Other selection is not yet a submittable
    // answer; typing then satisfies it; and picking an option again clears Other.
    func test_askUserQuestionOtherRadioSelectsOtherAndIsExclusiveWithOptions() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask other radio")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-other-radio", turnId: "turn-other-radio", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request),
                       "Other must start unselected so its radio renders empty on first display")

        // A listed option is chosen first — this is the state the user was stuck in.
        vm.selectAskUserQuestionOption("Postgres", question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOptionIsSelected("Postgres", question: question, request: request))

        // Clicking the Other radio moves the single selection to Other.
        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request),
                      "clicking the Other radio must mark Other as the selected choice")
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("Postgres", question: question, request: request),
                       "selecting Other must deselect the previously chosen option (single-select group)")
        XCTAssertFalse(vm.askUserQuestionIsComplete(request),
                       "Other selected with no text is not yet a submittable answer")

        // Typing then satisfies the question with the freeform text.
        vm.setAskUserQuestionOther("SQLite", question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "SQLite")
        XCTAssertTrue(vm.askUserQuestionIsComplete(request))

        // Picking a listed option again must take selection back from Other.
        vm.selectAskUserQuestionOption("MySQL", question: question, request: request)
        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request),
                       "choosing a listed option must clear the Other selection and its draft")
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "MySQL")
    }

    func test_askUserQuestionOtherRadioToggleOffLeavesQuestionUnanswered() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask other toggle")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-other-toggle", turnId: "turn-other-toggle", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        // Clicking the active Other radio again clears it, matching how listed options
        // toggle off — leaving nothing selected and the question unanswered.
        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertNil(vm.askUserQuestionAnswer(for: question, in: request))
        XCTAssertFalse(vm.askUserQuestionIsComplete(request))
    }

    // The option radio and the Other radio must never both read as selected. Typing
    // directly into the field (without first tapping the Other radio) — including a
    // whitespace-only first keystroke that trims to empty — must still claim the
    // exclusive selection and drop the previously chosen option, so the UI cannot show
    // two filled radios while the answer silently stays the option.
    func test_askUserQuestionTypingOtherClearsOptionEvenForWhitespace() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask other whitespace")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-other-ws", turnId: "turn-other-ws", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.selectAskUserQuestionOption("Postgres", question: question, request: request)
        // A whitespace-only first keystroke into the Other field.
        vm.setAskUserQuestionOther(" ", question: question, request: request)
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("Postgres", question: question, request: request),
                       "editing the Other field must drop the chosen option so two radios are never both filled")
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request),
                      "the Other radio must read as selected once its field is being edited")
        XCTAssertNil(vm.askUserQuestionAnswer(for: question, in: request),
                     "whitespace-only Other text trims empty, so the question is not yet answered")
        XCTAssertFalse(vm.askUserQuestionIsComplete(request))
    }

    // Multi-select: Other is exclusive by design (selecting Other replaces checked
    // options, and checking an option clears Other), so the Other control renders as a
    // radio rather than a checkbox. This pins the intended exclusivity so a later glyph
    // or model change cannot silently start dropping the user's combined choices without
    // a failing test.
    func test_askUserQuestionMultiSelectOtherIsExclusiveByDesign() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask multi other")
        let question = AssistantUserInputQuestion(
            prompt: "Which targets?",
            header: "Targets",
            options: [AssistantUserInputOption(label: "macOS"), AssistantUserInputOption(label: "iPadOS")],
            allowsMultipleSelection: true
        )
        let request = AssistantUserInputRequest(
            id: "ask-multi-other", turnId: "turn-multi-other", prompt: "Which targets?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.selectAskUserQuestionOption("macOS", question: question, request: request)
        vm.selectAskUserQuestionOption("iPadOS", question: question, request: request)
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "iPadOS, macOS")

        // Selecting Other replaces the checked options (exclusive).
        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("macOS", question: question, request: request))
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("iPadOS", question: question, request: request))
        vm.setAskUserQuestionOther("Linux", question: question, request: request)
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "Linux",
                       "in multi-select, an Other answer replaces the checked options by design")

        // Checking an option again clears Other.
        vm.selectAskUserQuestionOption("macOS", question: question, request: request)
        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "macOS")
    }

    // End-to-end: an Other answer must reach the provider as the question's answer, and
    // submit must clear the draft so a re-displayed card never starts pre-filled.
    func test_submitAskUserQuestionDeliversOtherDraftAndClearsItAfterward() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "ask other submit")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-other-submit", turnId: "turn-1", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))
        let key = vm.askUserQuestionKey(request, question)

        // Empty Other (radio picked, no text) must NOT satisfy Submit.
        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertFalse(vm.askUserQuestionIsComplete(request),
                       "an empty Other selection must keep Submit disabled")

        // Typing through the Other path unblocks Submit.
        vm.setAskUserQuestionOther("SQLite", question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionIsComplete(request))

        vm.submitAskUserQuestion(request)
        await waitAsync("Other answer reaches adapter") {
            adapter.lastUserInputResponse?.requestId == "ask-other-submit"
        }
        let text = try XCTUnwrap(adapter.lastUserInputResponse?.text)
        let answers = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(answers["Which database?"], "SQLite",
                       "Other freeform text must be delivered to the provider as the question's answer")
        XCTAssertNil(vm.userInputDrafts[key],
                     "submit must clear the Other draft so a re-shown card does not start pre-filled")
        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request))
    }

    func test_freeTextUserInputDraftCanAnswerProviderQuestion() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "free text input")
        let request = AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Which branch should I inspect?",
            options: [],
            isSecret: true,
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        let stateKey = vm.userInputStateKey(request)
        vm.userInputDrafts[stateKey] = "release/next"
        vm.answerPendingUserInput(request, answer: vm.userInputDrafts[stateKey] ?? "")
        await waitAsync("free-text provider response reaches adapter") {
            adapter.lastUserInputResponse?.requestId == "question-1"
        }

        XCTAssertEqual(adapter.lastUserInputResponse?.requestId, "question-1")
        XCTAssertEqual(adapter.lastUserInputResponse?.text, "release/next",
                       "free-text provider questions must have an editable draft path so the user can unblock the waiting provider request")
        XCTAssertNil(vm.userInputDrafts[stateKey],
                     "resolved provider questions must clear their local draft so stale text is not reused for a later request")
        XCTAssertTrue(request.isSecret,
                      "secret free-text questions use the same draft/submit path but must be distinguishable for masked rendering")
    }

    func test_answeringProviderQuestionClearsStaleVisibleError() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "free text input retry")
        let request = AssistantUserInputRequest(
            id: "question-2",
            turnId: "turn-1",
            prompt: "Which branch should I inspect?",
            options: [],
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))
        vm.timeline.apply(.error(message: "Provider user-input response failed: stale", recoverable: true))

        vm.answerPendingUserInput(request, answer: "main")

        XCTAssertNil(vm.timeline.error,
                     "submitting a new provider-answer message must immediately clear the stale error banner so the UI reflects the new attempt")
        await waitAsync("free-text provider response reaches adapter") {
            adapter.lastUserInputResponse?.requestId == "question-2"
        }
    }

    func test_approveForSessionPromotesThreadPermissionToFullAccess() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, repo) = try makeVM(adapter: adapter)
        vm.createThread(title: "approval")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let request = AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "npm create vite",
            createdAtMs: 1
        )
        vm.timeline.apply(.requestOpened(request))

        vm.respondToPendingRequest(request, response: .approveForSession)
        // respondToPendingRequest now drives the (async) coordinator.respondToRequest
        // off the main run loop; let that @MainActor task drain before asserting.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(adapter.lastRequestResponse?.response, .approveForSession,
                       "Approve Session must still send the provider session-scoped decision so the current run stops asking")
        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "Approve Session must visibly move the macOS thread from Supervised to Full Access")
        XCTAssertEqual(try repo.get(id: threadId)?.permissionMode, .fullAccess,
                       "Approve Session must persist Full Access so later messages in the same thread auto-approve")
    }

    func test_dynamicApproveForSessionKeepsThreadPermissionModeUnchanged() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, repo) = try makeVM(adapter: adapter)
        vm.createThread(title: "dynamic approval")
        vm.setPermissionMode(.supervised)
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let request = AssistantPendingRequest(
            id: "dynamic-permissions-1",
            turnId: "turn-1",
            kind: .dynamic,
            title: "Provider approval",
            detail: "Requested profile: network only",
            createdAtMs: 1
        )
        vm.timeline.apply(.requestOpened(request))

        vm.respondToPendingRequest(request, response: .approveForSession)
        await waitAsync("dynamic session response reaches adapter") {
            adapter.lastRequestResponse?.requestId == request.id
        }

        XCTAssertEqual(adapter.lastRequestResponse?.response, .approveForSession,
                       "the provider must receive its native session-scoped decision")
        XCTAssertEqual(vm.permissionMode, .supervised,
                       "a narrow dynamic permission profile must not widen the visible thread mode")
        XCTAssertEqual(try repo.get(id: threadId)?.permissionMode, .supervised,
                       "dynamic session scope must stay provider-native and leave durable thread authority unchanged")
    }

    func test_approveForSessionAfterThreadSwitchPromotesOnlyOriginThread() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex, responseDelayNanoseconds: 100_000_000)
        let (vm, repo) = try makeVM(adapter: adapter)
        vm.createThread(title: "A")
        vm.setPermissionMode(.supervised)
        let threadA = try XCTUnwrap(vm.selectedThreadId)
        vm.createThread(title: "B")
        vm.setPermissionMode(.supervised)
        let threadB = try XCTUnwrap(vm.selectedThreadId)
        vm.selectThread(threadA)
        let request = AssistantPendingRequest(
            id: "approval-shared",
            turnId: "turn-a",
            kind: .commandExecution,
            title: "Run A",
            createdAtMs: 1
        )
        vm.timeline.apply(.requestOpened(request))

        vm.respondToPendingRequest(request, response: .approveForSession)
        vm.selectThread(threadB)
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(adapter.lastRequestResponse?.threadId, threadA,
                       "the provider decision must remain bound to the thread that owned the approval card")
        XCTAssertEqual(try repo.get(id: threadA)?.permissionMode, .fullAccess,
                       "Approve Session must promote the origin thread even if selection changes during await")
        XCTAssertEqual(try repo.get(id: threadB)?.permissionMode, .supervised,
                       "the newly selected thread must never inherit another thread's approval escalation")
        XCTAssertEqual(vm.permissionMode, .supervised,
                       "visible config must remain that of the newly selected thread")
        XCTAssertTrue(vm.timeline.pendingRequests.isEmpty,
                      "completion for thread A must not resolve or inject a callback into thread B's timeline")
    }

    func test_approveForSessionConfirmationAfterThreadSwitchRoutesToOriginThread() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, repo) = try makeVM(adapter: adapter)
        vm.createThread(title: "A")
        vm.setPermissionMode(.supervised)
        let threadA = try XCTUnwrap(vm.selectedThreadId)
        vm.createThread(title: "B")
        vm.setPermissionMode(.supervised)
        let threadB = try XCTUnwrap(vm.selectedThreadId)
        vm.selectThread(threadA)
        let request = AssistantPendingRequest(
            id: "approval-confirmation-a",
            turnId: "turn-a",
            kind: .commandExecution,
            title: "Run A",
            createdAtMs: 1
        )
        vm.timeline.apply(.requestOpened(request))

        // The confirmation dialog captures A when it opens. Selection may move
        // before the destructive confirmation callback runs.
        vm.selectThread(threadB)
        vm.respondToPendingRequest(
            request,
            response: .approveForSession,
            originThreadId: threadA
        )
        await waitAsync("session approval confirmation reaches origin thread") {
            adapter.lastRequestResponse?.threadId == threadA
        }

        XCTAssertEqual(adapter.lastRequestResponse?.threadId, threadA,
                       "confirming after a thread switch must route through the dialog's captured origin")
        XCTAssertEqual(try repo.get(id: threadA)?.permissionMode, .fullAccess,
                       "the approval escalation belongs to the thread that opened the dialog")
        XCTAssertEqual(try repo.get(id: threadB)?.permissionMode, .supervised,
                       "the currently selected thread must remain unchanged")
        XCTAssertEqual(vm.selectedThreadId, threadB,
                       "confirming an origin-bound approval must not force a selection change")
    }

    func test_staleCallbacksRehydratedAfterRelaunchAreNeverActionable() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "relaunch")
        await vm.waitForSelectThreadHydrationForTesting()
        let approval = AssistantPendingRequest(
            id: "stale-approval",
            turnId: "turn-old",
            kind: .commandExecution,
            title: "Old command",
            state: .stale,
            createdAtMs: 1
        )
        let question = AssistantUserInputRequest(
            id: "stale-question",
            turnId: "turn-old",
            prompt: "Old question",
            options: [],
            state: .stale,
            createdAtMs: 2
        )
        vm.timeline.apply(.requestOpened(approval))
        vm.timeline.apply(.userInputRequested(question))

        vm.respondToPendingRequest(approval, response: .approve)
        vm.answerPendingUserInput(question, answer: "should not send")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(adapter.lastRequestResponse,
                     "stale relaunch approvals are read-only diagnostics and must never reach the provider")
        XCTAssertNil(adapter.lastUserInputResponse,
                     "stale relaunch questions are read-only diagnostics and must never resume a dead continuation")
        XCTAssertEqual(vm.visiblePendingRequests.first?.state, .stale)
        XCTAssertEqual(vm.visiblePendingUserInputs.first?.state, .stale)
    }

    func test_selectThreadReplaysProviderReadThreadSnapshotWhenAvailable() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex, readEvents: [
            .threadStarted(threadId: "provider-thread-1", providerThreadId: "provider-thread-1"),
            .turnStarted(turnId: "provider-turn-1"),
            .itemStarted(item: AssistantItem(
                id: "provider-message-1",
                turnId: "provider-turn-1",
                type: .assistantMessage,
                state: .streaming,
                summary: "Assistant message",
                startedAtMs: 1
            )),
            .itemDelta(itemId: "provider-message-1", bodyAppend: "Recovered from provider snapshot", outputAppend: nil, summary: nil),
            .turnCompleted(turnId: "provider-turn-1", finalMessage: "Recovered from provider snapshot")
        ])
        let (vm, _) = try makeVM(adapter: adapter)

        vm.createThread(title: "recover")

        // PERF: selectThread now opens instantly from persisted events and replays
        // the provider readThread snapshot one main-actor hop later (the freeze
        // fix). The provider snapshot still REPLACES the stale local rows; we just
        // drain that one hop before asserting the final, identical timeline state.
        await waitAsync("provider snapshot replayed") {
            vm.timeline.turns.map(\.turnId) == ["provider-turn-1"]
        }

        XCTAssertEqual(vm.timeline.providerThreadId, "provider-thread-1")
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), ["provider-turn-1"])
        XCTAssertEqual(vm.timeline.latestAssistantMessage, "Recovered from provider snapshot",
                       "selecting a thread with a live provider session must reload the provider snapshot instead of relying only on stale local stream rows")
    }

    func test_restartedAgentAppRehydratesCodexThreadFromProviderSnapshotAfterLocalEventLoss() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-provider-snapshot-restart-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "recovered provider thread",
            provider: .codex,
            model: "gpt-5.5",
            providerThreadId: "provider-thread-after-restart",
            status: .completed
        )
        try threadRepo.upsert(thread)
        try messageRepo.append(AgentMessage(threadId: thread.id, role: .assistant, content: "stale local final"))

        let adapter = CapturingProviderAdapter(provider: .codex, readEvents: [
            .threadStarted(threadId: "provider-thread-after-restart", providerThreadId: "provider-thread-after-restart"),
            .turnStarted(turnId: "provider-turn-after-restart"),
            .itemStarted(item: AssistantItem(
                id: "provider-message-after-restart",
                turnId: "provider-turn-after-restart",
                type: .assistantMessage,
                state: .streaming,
                summary: "Assistant message",
                startedAtMs: 1
            )),
            .itemDelta(itemId: "provider-message-after-restart", bodyAppend: "Recovered provider state after restart", outputAppend: nil, summary: nil),
            .turnCompleted(turnId: "provider-turn-after-restart", finalMessage: "Recovered provider state after restart")
        ])
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.codex: adapter])

        // Per-surface binding: the host restore path passes the persisted
        // `selected_thread` as initialThreadId; mirror that here.
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db),
                                   initialThreadId: thread.id)

        XCTAssertEqual(vm.selectedThreadId, thread.id,
                       "after app restart, Agent App must reopen the persisted Codex thread")
        // PERF: the provider snapshot replay on auto-reopen is now deferred one
        // main-actor hop behind the instant local open (the freeze fix). Drain it
        // before asserting that the provider snapshot still REPLACED the stale
        // local final-message rows -- final timeline state is unchanged.
        await waitAsync("restart provider snapshot replayed") {
            vm.timeline.turns.map(\.turnId) == ["provider-turn-after-restart"]
        }
        XCTAssertEqual(vm.timeline.providerThreadId, "provider-thread-after-restart")
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), ["provider-turn-after-restart"])
        XCTAssertEqual(vm.timeline.latestAssistantMessage, "Recovered provider state after restart",
                       "app restart must prefer provider readThread state over stale local final-message rows when the provider session is recoverable")
    }

    func test_persistThreadConfig_writesProviderModelPermissionAndReasoningToThread() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        vm.provider = .claude
        vm.model = "claude-opus-4-7"
        vm.permissionMode = .fullAccess
        vm.reasoningEffort = .high
        vm.persistThreadConfig()
        let t = try repo.get(id: id)
        XCTAssertEqual(t?.provider, .claude)
        XCTAssertEqual(t?.model, "claude-opus-4-7", "model change must persist for resume")
        XCTAssertEqual(t?.permissionMode, .fullAccess)
        XCTAssertEqual(t?.reasoningEffort, .high)

        vm.permissionMode = .supervised
        vm.reasoningEffort = .low
        vm.selectThread(id)
        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "reopening an existing thread must restore its saved permission mode")
        XCTAssertEqual(vm.reasoningEffort, .high,
                       "reopening an existing thread must restore its saved reasoning effort")
    }

    func test_distillEffortsRestorePerThreadAcrossSoftReselectionAndReachRunRequest() async throws {
        // WHY: switching conversations must restore both Distill effort choices before constructing the next provider request.
        let runner = CapturingProviderRunner(provider: .distill)
        let (vm, repo) = try makeVM(provider: runner)
        let efforts: [AgentReasoningEffort] = [.low, .high]
        let models = [
            AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: efforts),
            AgentModelDescriptor(id: "reason-a", label: "Reason A", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: efforts),
            AgentModelDescriptor(id: "main-b", label: "Main B", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: efforts),
            AgentModelDescriptor(id: "reason-b", label: "Reason B", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: efforts),
        ]
        vm.availableModels = models
        vm.providerSnapshots = [AgentProviderSnapshot(
            id: AgentProvider.distill.rawValue,
            provider: .distill,
            driverKind: .distillACP,
            displayName: "Distill",
            accentColor: "#6E56CF",
            continuationGroup: "distill",
            interactionModes: [.default],
            permissionModes: [.supervised],
            enabled: true,
            installed: true,
            status: .available,
            authenticated: true,
            models: models,
            slashCommands: [],
            capabilities: AgentProviderCapabilities(
                supportsDistillMainEffortAuto: true,
                supportsDistillReasoningModelEffort: true
            )
        )]
        vm.provider = .distill
        vm.providerInstanceId = AgentProvider.distill.rawValue

        func makeDistillThread(
            title: String,
            mainModel: String,
            reasoningModel: String,
            mainEffort: AgentReasoningEffort,
            reasoningEffort: AgentReasoningEffort
        ) -> AgentThread {
            let selection = AgentModelSelection(
                provider: .distill,
                modelId: mainModel,
                reasoningEffort: mainEffort,
                distillMainEffortSelection: .fixed(mainEffort),
                distillReasoningEffortSelection: .fixed(reasoningEffort)
            )
            return AgentThread(
                workspaceId: vm.workspaceID,
                title: title,
                provider: .distill,
                model: mainModel,
                reasoningEffort: mainEffort,
                reasoningModel: reasoningModel,
                modelSelection: selection,
                routingConfiguration: AgentRoutingConfiguration(
                    mode: .manual,
                    manualSelection: selection,
                    manualProviderInstanceId: AgentProvider.distill.rawValue
                )
            )
        }

        let threadA = makeDistillThread(
            title: "A",
            mainModel: "main-a",
            reasoningModel: "reason-a",
            mainEffort: .high,
            reasoningEffort: .low
        )
        let threadB = makeDistillThread(
            title: "B",
            mainModel: "main-b",
            reasoningModel: "reason-b",
            mainEffort: .low,
            reasoningEffort: .high
        )
        let legacyThread = AgentThread(
            workspaceId: vm.workspaceID,
            title: "Legacy",
            provider: .distill,
            model: "main-a",
            reasoningEffort: .high,
            reasoningModel: "reason-a"
        )
        try repo.upsert(threadA)
        try repo.upsert(threadB)
        try repo.upsert(legacyThread)
        vm.reloadThreads()

        vm.selectThread(threadA.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(vm.distillReasoningEffortSelection, .fixed(.low))
        XCTAssertEqual(vm.currentModelSelection.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(vm.currentModelSelection.distillReasoningEffortSelection, .fixed(.low))

        vm.selectThread(threadB.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.distillMainEffortSelection, .fixed(.low))
        XCTAssertEqual(vm.distillReasoningEffortSelection, .fixed(.high))

        vm.selectThread(threadA.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(vm.distillReasoningEffortSelection, .fixed(.low))
        XCTAssertEqual(vm.currentModelSelection.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(vm.currentModelSelection.distillReasoningEffortSelection, .fixed(.low))

        vm.prompt = "Use thread A's Distill routing"
        await vm.send()
        await waitAsync("thread A request captured") { runner.requests.count == 1 }
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.threadId, threadA.id)
        XCTAssertEqual(request.model, "main-a")
        XCTAssertEqual(request.reasoningModel, "reason-a")
        XCTAssertEqual(request.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(request.distillReasoningEffortSelection, .fixed(.low))

        vm.selectThread(legacyThread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.distillMainEffortSelection, .fixed(.high),
                       "legacy threads continue to derive Main effort from their stored reasoningEffort")
        XCTAssertEqual(vm.distillReasoningEffortSelection, .automatic,
                       "legacy threads without a Reasoning effort pin restore Auto")

        vm.selectThread(threadB.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.distillMainEffortSelection, .fixed(.low))
        XCTAssertEqual(vm.distillReasoningEffortSelection, .fixed(.high))
        XCTAssertEqual(try repo.get(id: threadA.id)?.modelSelection.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(try repo.get(id: threadA.id)?.modelSelection.distillReasoningEffortSelection, .fixed(.low))
        XCTAssertEqual(try repo.get(id: threadB.id)?.modelSelection.distillMainEffortSelection, .fixed(.low))
        XCTAssertEqual(try repo.get(id: threadB.id)?.modelSelection.distillReasoningEffortSelection, .fixed(.high))
    }

    func test_settingPermissionPersistsImmediatelyBeforeAnyMessageIsSent() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!

        vm.setPermissionMode(.fullAccess)
        vm.permissionMode = .supervised
        vm.selectThread(id)

        XCTAssertEqual(try repo.get(id: id)?.permissionMode, .fullAccess,
                       "permission changes must persist immediately so app restart does not reset to supervised")
        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "reopening the thread must restore the saved permission mode before any message is sent")
    }

    func test_permissionChangeDuringRunDoesNotMisrepresentActiveAuthority() async throws {
        let runner = SlowStartRunner()
        let (vm, repo) = try makeVM(provider: runner)
        vm.createThread(title: "active authority")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.setPermissionMode(.fullAccess)
        vm.prompt = "hold active authority"
        await vm.send()

        vm.setPermissionMode(.supervised)

        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "the visible permission chip must keep the authority captured by the active run")
        XCTAssertEqual(try repo.get(id: id)?.permissionMode, .fullAccess,
                       "a blocked mid-run gesture must not persist next-turn authority as if it were active")
        XCTAssertTrue(vm.activeRunConfigurationLocked)
        vm.stop()
    }

    func test_createThreadCopiesCurrentConfigFromLastThread() throws {
        let (vm, repo) = try makeVM()
        vm.provider = .codex
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        // createThread re-resolves the model from the last one the USER chose
        // for the provider (setModel → rememberCurrentModel), not from whatever
        // an older selected thread left on the VM — so choose it the UI way.
        vm.setModel("gpt-5.5")
        vm.permissionMode = .fullAccess
        vm.reasoningEffort = .medium
        vm.createThread(title: "next")

        let id = try XCTUnwrap(vm.selectedThreadId)
        let t = try repo.get(id: id)
        XCTAssertEqual(t?.model, "gpt-5.5", "new threads must inherit the last model the user chose for the provider")
        XCTAssertEqual(t?.permissionMode, .fullAccess,
                       "new threads must inherit the last active permission mode")
        XCTAssertEqual(t?.reasoningEffort, .medium,
                       "new threads must inherit the last active reasoning effort")
    }

    func test_setThreadColor_persistsAndClears() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        vm.setThreadColor(id, "purple")
        XCTAssertEqual(try repo.get(id: id)?.color, "purple")
        vm.setThreadColor(id, "")
        XCTAssertNil(try repo.get(id: id)?.color, "empty selection clears the color")
    }

    func test_persistentThreadMutationsRollbackVisualStateAndDoNotPublishSuccessWhenSQLiteRejectsWrite() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "durable")
        let id = try XCTUnwrap(vm.selectedThreadId)
        let original = try XCTUnwrap(try repo.get(id: id))
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        var configEvents: [AgentThread] = []
        vm.onThreadLifecycle = { lifecycleEvents.append($0) }
        vm.onThreadConfigPersisted = { configEvents.append($0) }
        try repo.db.execute("""
            CREATE TRIGGER reject_agent_thread_update
            BEFORE UPDATE ON agent_threads
            BEGIN SELECT RAISE(ABORT, 'simulated disk full'); END;
        """)

        vm.model = "model-that-must-rollback"
        XCTAssertFalse(vm.persistThreadConfig())
        XCTAssertEqual(vm.model, original.model,
                       "a failed config write must roll the picker back to the durable model")
        XCTAssertEqual(try repo.get(id: id)?.model, original.model)
        XCTAssertTrue(configEvents.isEmpty,
                      "failed persistence must not publish a config-success event to mirrors")

        vm.renameThread(id, to: "phantom rename")
        XCTAssertEqual(try repo.get(id: id)?.title, original.title)
        vm.setThreadColor(id, "purple")
        XCTAssertEqual(try repo.get(id: id)?.color, original.color)
        vm.setThreadPinned(id, true)
        XCTAssertEqual(try repo.get(id: id)?.pinned, original.pinned)
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "rename/color/pin failures must not announce phantom success")
        XCTAssertTrue(vm.statusMessage.contains("Could not"),
                      "every rejected persistent mutation must fail loud in the Agent App")
    }

    func test_createThreadDoesNotAppearOrPublishWhenSQLiteRejectsInsert() throws {
        let (vm, repo) = try makeVM()
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        vm.onThreadLifecycle = { lifecycleEvents.append($0) }
        try repo.db.execute("""
            CREATE TRIGGER reject_agent_thread_insert
            BEFORE INSERT ON agent_threads
            BEGIN SELECT RAISE(ABORT, 'simulated read only database'); END;
        """)

        vm.createThread(title: "phantom")

        XCTAssertTrue(try repo.list(workspaceId: vm.workspaceID).isEmpty)
        XCTAssertTrue(vm.threads.isEmpty)
        XCTAssertNil(vm.selectedThreadId)
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a rejected INSERT must never publish a created event")
        XCTAssertTrue(vm.statusMessage.contains("Could not create thread"))
    }

    func test_grokFallbackSnapshotDrivesBuiltInDefaultsWarning() async throws {
        let (vm, _) = try makeVM()
        let fallbackModels = GrokRunner.listModels(installedVersion: nil)
        let fallback = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: fallbackModels,
            binaryPath: "/definitely/missing/grok",
            modelDiscoverySource: .builtInFallback,
            modelDiscoveryCacheKey: "opaque-test-key"
        )
        vm.providerSnapshotLoader = { [fallback] in [fallback] }
        vm.providerLaunchConfig = { _, _ in ("/definitely/missing/grok", [:]) }

        await vm.loadProviderSnapshots()
        vm.setProvider(.grok)
        await vm.loadModels()

        XCTAssertEqual(vm.modelOptionsForSelectedProvider.map(\.id), fallbackModels.map(\.id))
        XCTAssertTrue(vm.displayedModelListIsFallback,
                      "Grok discovery failure must drive the visible 'Using built-in defaults' warning")
    }

    func test_renameThread_blankIsNoOp() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "keep")
        let id = vm.selectedThreadId!
        vm.renameThread(id, to: "   ")
        XCTAssertEqual(vm.threads.first(where: { $0.id == id })?.title, "keep",
                       "a blank rename must not wipe an existing title")
    }

    func test_deleteSelectedThread_reselectsRemaining() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "a")
        let a = vm.selectedThreadId!
        vm.createThread(title: "b")
        let b = vm.selectedThreadId!
        XCTAssertNotEqual(a, b)
        vm.selectThread(a)
        await vm.deleteThread(a)
        XCTAssertFalse(vm.threads.contains { $0.id == a }, "deleted thread must be gone")
        XCTAssertEqual(vm.selectedThreadId, b,
                       "deleting the selected thread must fall back to a remaining one")
    }

    func test_deleteLastThread_clearsSelectionAndMessages() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "only")
        let id = vm.selectedThreadId!
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "hi"))
        await vm.deleteThread(id)
        XCTAssertNil(vm.selectedThreadId, "deleting the last thread must clear selection")
        XCTAssertTrue(vm.messages.isEmpty, "stale messages must not linger after the thread is gone")
    }

    // MARK: B5 — draft title derivation

    func test_deriveTitle_preservesFullFirstMessageForPersistence() {
        let long = "  Fix the login bug and keep every detail in the persisted thread title.  "
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: long),
                       "Fix the login bug and keep every detail in the persisted thread title",
                       "the persisted title must keep the full first message; only display should truncate")
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: "### Heading"),
                       "Heading", "leading markdown punctuation must be stripped")
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: "   \n  "),
                       "New thread", "an empty prompt must fall back, never be blank")
        XCTAssertEqual(AgentThreadTitle.display(String(repeating: "x", count: 80)),
                       String(repeating: "x", count: AgentThreadTitle.displayLimit) + "...",
                       "thread rows must show a bounded title while the stored title remains complete")
    }

    func test_send_firstMessage_derivesThreadTitleFromDefault() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "New thread")
        let id = vm.selectedThreadId!
        vm.prompt = "Refactor the auth module please"
        await vm.send()
        XCTAssertEqual(try repo.get(id: id)?.title, "Refactor the auth module please",
                       "the first message must rename a still-default thread")
        // send() and the didFinish fan-out each schedule an off-main history
        // reload; poll until the durable user row lands in the published array.
        await waitAsync("user message lands in reloaded history", timeout: 2) {
            vm.messages.contains { $0.role == .user && $0.content == "Refactor the auth module please" }
        }
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "Refactor the auth module please" })
    }

    func test_sendMentionStartsWithPrimaryAI_becauseOnlyItMayAuthorThePeerPrompt() async throws {
        // WHY: the app must not treat @quinn as a routing command. The primary
        // AI needs the complete request before it can decide what Quinn receives.
        let hostRunner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: hostRunner)
        vm.createThread(title: "New thread")
        let quinn = BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )
        vm.mentionableBotsProvider = { [quinn] }
        let prompt = "pergunte ao @quinn o nome dele e então decida o próximo passo"
        vm.prompt = prompt
        await vm.send()
        XCTAssertEqual(
            hostRunner.prompts,
            [prompt],
            "the primary AI must receive the complete user turn verbatim"
        )
        XCTAssertEqual(
            hostRunner.environments.first?[BotPeerDelegation.turnContextEnvironmentKey],
            BotPeerDelegation.turnDirective(mentionedBots: [quinn]),
            "resolved identity must travel separately from the user's words"
        )
        XCTAssertEqual(
            vm.messages.filter { $0.role == .user && $0.content == prompt }.count,
            1,
            "the original request must remain one durable user turn"
        )
    }

    func test_send_emptyPendingThreadStartsRunInsteadOfQueueing() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-empty-pending-send-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = CapturingProviderRunner(provider: .codex)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: runner])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   queuedMessageRepo: queuedRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "New thread")
        let id = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertEqual(try threadRepo.get(id: id)?.status, .pending,
                       "a newly created empty thread may be persisted as pending, but it is not an active provider run")

        vm.prompt = "Run this now"
        await vm.send()

        XCTAssertEqual(runner.prompts, ["Run this now"],
                       "when no provider run is active, the first prompt must start immediately instead of being stranded in the queue")
        XCTAssertTrue((try? queuedRepo.list(threadId: id))?.isEmpty ?? false,
                      "the queue is only for follow-up prompts while a real run is active")
        XCTAssertTrue(vm.queuedMessages.isEmpty,
                      "the empty-thread send path must not render a queued-message row")
    }

    func test_sendClearsStaleActivePlanAndRestoresBottomFollow() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "stale plan")
        vm.timeline.apply(.activePlanUpdated(AssistantActivePlan(
            explanation: "Done checklist",
            steps: [AssistantPlanStep(id: "step-1", title: "Report", status: .completed)],
            updatedAtMs: 42
        )))
        let initialFocusTick = vm.focusTick

        vm.prompt = "next message"
        await vm.send()

        XCTAssertNil(vm.activePlan,
                     "sending the next user message must remove the previous turn's active plan so the transcript bottom is the new message")
        XCTAssertGreaterThan(vm.focusTick, initialFocusTick,
                             "a user send must re-pin the timeline to the bottom instead of relying on a pre-layout message-count change")
        XCTAssertEqual(runner.prompts, ["next message"],
                       "clearing stale plan state must not block the provider run")
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "next message" },
                      "the user bubble must appear in the transcript immediately on send")
    }

    func test_queuedFollowupStaysOutOfTranscriptAndClearsActivePlan() async throws {
        // WHY: while a provider turn is live, follow-ups enqueue instead of
        // starting. The queue UI is the only place they should appear until
        // drain starts the turn — a transcript bubble would look like the agent
        // already received the message. The prior Active plan still leaves the
        // bottom of the view because the user has superseded it.
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-queue-plan-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = SlowStartRunner()
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: runner])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   queuedMessageRepo: queuedRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "busy plan")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.prompt = "start slow run"
        Task { await vm.send() }
        await waitAsync("selected thread becomes a real active run") {
            vm.status == .running && vm.currentRunId != nil
        }
        vm.timeline.apply(.activePlanUpdated(AssistantActivePlan(
            explanation: "Still running checklist",
            steps: [
                AssistantPlanStep(id: "s1", title: "Done step", status: .completed),
                AssistantPlanStep(id: "s2", title: "In progress", status: .inProgress)
            ],
            updatedAtMs: 99
        )))
        XCTAssertNotNil(vm.activePlan)

        vm.prompt = "follow up after current run"
        await vm.send()

        XCTAssertEqual((try? queuedRepo.list(threadId: id).map(\.text)) ?? [], ["follow up after current run"],
                       "follow-up must still enqueue while the provider turn is active")
        XCTAssertEqual(vm.queuedMessages.map(\.text), ["follow up after current run"],
                       "queued follow-ups must render in the queue UI")
        XCTAssertFalse(vm.messages.contains { $0.role == .user && $0.content == "follow up after current run" },
                       "queued follow-ups must not appear as a transcript bubble until the turn starts")
        XCTAssertEqual(vm.queueStatusMessage, "Queued — will run after the current turn.")
        XCTAssertNil(vm.activePlan,
                     "sending a follow-up must clear the prior turn's Active plan even when the turn is still running")

        // Plan events from the still-running prior turn must not resurrect the
        // checklist while a follow-up is only queued — even with a *current*
        // updatedAtMs (timestamp freshness alone is not run ownership).
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        vm.runCoordinator(
            vm.coordinator,
            didReceive: .activePlanUpdated(AssistantActivePlan(
                explanation: "live plan from still-running prior turn",
                steps: [AssistantPlanStep(id: "sx", title: "Should not show", status: .inProgress)],
                updatedAtMs: nowMs
            )),
            run: try XCTUnwrap(vm.currentRunId),
            threadId: id
        )
        await waitAsync("queued-follow-up suppresses prior-turn plan stream events") {
            vm.activePlan == nil
        }

        vm.stop()
        await waitAsync("slow run can still be stopped after queueing") {
            runner.cancelled
        }
    }

    func test_hostStartedRunShowsDurableUserRowWithoutWaitingForRunEnd() async throws {
        // WHY: a queue drain or Force starts the run from the host; the user row is
        // persisted before the run goes live. The transcript must show it at run start,
        // not only when the run ends, or the started follow-up looks lost.
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-host-start-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: SlowStartRunner()])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   queuedMessageRepo: queuedRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "host started")
        let id = try XCTUnwrap(vm.selectedThreadId)
        // Let selection's own message load finish before the row exists, so
        // only the running-status path can pull it into the transcript.
        await vm.waitForMessageHistoryLoad()
        let runId = AgentRunID()
        try messageRepo.append(AgentMessage(id: AgentMessageID(runId.value), threadId: id,
                                            role: .user, content: "drained follow-up"))
        XCTAssertFalse(vm.messages.contains { $0.content == "drained follow-up" })

        vm.runCoordinator(coord, didChangeStatus: .running, runId: runId, threadId: id)

        await waitAsync("host-started user row reaches the transcript before run end") {
            vm.messages.contains { $0.content == "drained follow-up" }
        }
        XCTAssertTrue(vm.messages.contains { $0.content == "drained follow-up" },
                      "the host-started user row must render at run start")
    }

    func test_mergeLoadedMessagesPreservesInMemoryUserMirror() {
        // WHY: concurrent same-thread reloads must not drop the optimistic user
        // bubble before the coordinator has persisted the durable run-id row.
        // Merge is by id so two legitimate identical prompts stay distinct.
        let tid = AgentThreadID()
        let sharedId = AgentMessageID()
        let durable = AgentMessage(threadId: tid, role: .assistant, content: "prior answer")
        let mirror = AgentMessage(id: sharedId, threadId: tid, role: .user, content: "just sent")
        let merged = AgentAppViewModel.mergeLoadedMessagesWithInMemoryMirrors(
            loadedRows: [durable],
            inMemory: [durable, mirror],
            threadId: tid
        )
        XCTAssertEqual(merged.map(\.content), ["prior answer", "just sent"],
                       "in-memory user mirrors absent from the durable page must survive the merge")
        let afterDurableUser = AgentAppViewModel.mergeLoadedMessagesWithInMemoryMirrors(
            loadedRows: [
                durable,
                AgentMessage(id: sharedId, threadId: tid, role: .user, content: "just sent")
            ],
            inMemory: [mirror],
            threadId: tid
        )
        XCTAssertEqual(afterDurableUser.filter { $0.id == sharedId }.count, 1,
                       "id-merge must collapse the optimistic mirror once the durable run-id row lands")
        let firstId = AgentMessageID()
        let secondId = AgentMessageID()
        let twoIdentical = AgentAppViewModel.mergeLoadedMessagesWithInMemoryMirrors(
            loadedRows: [AgentMessage(id: firstId, threadId: tid, role: .user, content: "same")],
            inMemory: [AgentMessage(id: secondId, threadId: tid, role: .user, content: "same")],
            threadId: tid
        )
        XCTAssertEqual(twoIdentical.filter { $0.content == "same" }.count, 2,
                       "identical prompt text with distinct ids must not be collapsed")
    }

    func test_send_runningThreadQueuesFollowupPrompt() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-running-queue-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = SlowStartRunner()
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: runner])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   queuedMessageRepo: queuedRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "busy")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.prompt = "start slow run"

        Task { await vm.send() }
        await waitAsync("selected thread becomes a real active run") {
            vm.status == .running && vm.currentRunId != nil
        }
        vm.prompt = "follow up after current run"
        await vm.send()

        XCTAssertEqual((try? queuedRepo.list(threadId: id).map(\.text)) ?? [], ["follow up after current run"],
                       "follow-up prompts should queue only while a real provider run is active")
        vm.stop()
        await waitAsync("slow run can still be stopped after queueing") {
            runner.cancelled
        }
    }

    func test_send_runningThreadHandlesLocalSlashCommandInsteadOfQueueing() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-running-slash-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = SlowStartRunner()
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: runner])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   queuedMessageRepo: queuedRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "busy slash")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.prompt = "start slow run"

        Task { await vm.send() }
        await waitAsync("selected thread becomes a real active run") {
            vm.status == .running && vm.currentRunId != nil
        }
        vm.interactionMode = .plan
        vm.prompt = "/default"

        await vm.send()

        XCTAssertEqual(vm.interactionMode, .default,
                       "local slash commands must update composer run mode even while a provider run is active")
        XCTAssertEqual((try? queuedRepo.list(threadId: id).map(\.text)) ?? [], [],
                       "local slash commands must not be queued as follow-up provider prompts")
        XCTAssertEqual(vm.prompt, "", "handled local slash commands must clear the composer")
        vm.stop()
        await waitAsync("slow run can still be stopped after local slash command") {
            runner.cancelled
        }
    }

    func test_reloadThreadsBackfillsPlaceholderTitleFromFirstUserMessage() async throws {
        let (vm, repo) = try makeVM()
        let thread = AgentThread(workspaceId: vm.workspaceID, title: "Thread", provider: .claude, model: "fake-model")
        try repo.upsert(thread)
        let firstMessage = "git add commit and push all repos here with this long exact wording"
        try vm.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: firstMessage))

        vm.reloadThreads()
        await vm.awaitTitleRepairForTesting()

        XCTAssertEqual(vm.threads.first(where: { $0.id == thread.id })?.title, firstMessage,
                       "existing placeholder threads must be repaired from the first user message")
        XCTAssertEqual(try repo.get(id: thread.id)?.title, firstMessage,
                       "the repair must persist the full title, not only update the visible rail")
    }

    func test_finishCallback_persistsAssistantReplyForRestart() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        let runId = AgentRunID()
        vm.runCoordinator(vm.coordinator, didFinish: runId, threadId: id, status: .completed,
                          finalMessage: "final answer", providerThreadId: "session-1")
        await waitAsync("assistant reply persisted") {
            ((try? vm.messageRepo.list(threadId: id)) ?? []).contains {
                $0.role == .assistant && $0.content == "final answer"
            }
        }
        vm.runCoordinator(vm.coordinator, didFinish: runId, threadId: id, status: .completed,
                          finalMessage: "final answer", providerThreadId: "session-1")
        await waitAsync("assistant reply remains deduplicated") {
            (((try? vm.messageRepo.list(threadId: id)) ?? []).filter {
                $0.role == .assistant && $0.content == "final answer"
            }.count) == 1
        }
    }

    func test_finishCallbackReloadsSelectedMessagesWhenLiveTimelineMissedFinal() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        try vm.messageRepo.append(AgentMessage(threadId: id, role: .user, content: "count"))
        vm.messages = (try? vm.messageRepo.list(threadId: id)) ?? []

        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "O: 1 2 3", providerThreadId: nil)

        await waitAsync("selected messages include final assistant reply") {
            vm.messages.contains { $0.role == .assistant && $0.content == "O: 1 2 3" }
        }
    }

    func test_finishCallbackClearsActivePlanWhenFinalAssistantMessageArrives() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        vm.timeline.apply(.activePlanUpdated(AssistantActivePlan(
            explanation: "Done checklist",
            steps: [AssistantPlanStep(id: "step-1", title: "Report", status: .completed)],
            updatedAtMs: 42
        )))

        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "O: completed", providerThreadId: nil)

        await waitAsync("final assistant message clears stale active plan") {
            vm.activePlan == nil &&
            vm.messages.contains { $0.role == .assistant && $0.content == "O: completed" }
        }
    }

    func test_turnViewRendersFinalWhenAssistantItemHasNoBody() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, body: "", startedAtMs: 1)
            ],
            finalAssistantMessage: "O: I counted integers from 1 to 15.",
            finished: true
        )

        XCTAssertTrue(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                      "an empty assistant item must not hide the completed final answer")
    }

    func test_completedTurnCollapsesWorkAndKeepsFinalAssistantItemVisible() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "reason", turnId: "turn-1", type: .reasoning, state: .completed, body: "thinking", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "tool", turnId: "turn-1", type: .tool, state: .completed, summary: "Bash", output: "ok", startedAtMs: 2_000, finishedAtMs: 3_000),
                AssistantItem(id: "final", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Final answer", startedAtMs: 3_000, finishedAtMs: 4_000)
            ],
            finished: true
        )
        let renderable = AgentAppView.renderableItems(in: turn)

        XCTAssertEqual(AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable).map(\.id), ["final"],
                       "when the provider has no separate final text, the last assistant message is the final answer and must stay outside the Worked disclosure")
        XCTAssertEqual(AgentAppView.completedWorkItems(in: turn, renderableItems: renderable).map(\.id), ["reason", "tool"],
                       "reasoning and tool rows from a completed turn must collapse into the Worked disclosure")
        XCTAssertEqual(AgentAppView.completedWorkLabel(turn), "Worked for 3s",
                       "completed work disclosure must show elapsed work time in the Codex-style label")
    }

    func test_completedTurnWithSeparateFinalCollapsesNonFinalAssistantDrafts() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "draft", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "I will inspect first.", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "tool", turnId: "turn-1", type: .commandExecution, state: .completed, summary: "swift test", output: "PASS", startedAtMs: 2_000, finishedAtMs: 4_000)
            ],
            finalAssistantMessage: "Final answer",
            finished: true
        )
        let renderable = AgentAppView.renderableItems(in: turn)

        XCTAssertTrue(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                      "the separate final assistant message must remain the visible completed answer")
        XCTAssertTrue(AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable).isEmpty,
                      "non-final assistant drafts must not stay as visible transcript rows after the turn completes")
        XCTAssertEqual(AgentAppView.completedWorkItems(in: turn, renderableItems: renderable).map(\.id), ["draft", "tool"],
                       "everything that is not the final answer, including assistant drafts, must move into the Worked disclosure")
    }

    func test_completedTurnWithLastMessageFinalDemotesEarlierPreamblesToWorkLog() {
        // A Codex turn emits several preamble messages before the real answer. Only
        // the LAST assistant message is the answer; the earlier preambles must
        // collapse into the Worked disclosure instead of stacking up as the visible
        // final answer (the bug this fix addresses).
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Let me read the config first.", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Now running the test suite.", startedAtMs: 2_000, finishedAtMs: 3_000),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "All checks passed and the build is green.", startedAtMs: 3_000, finishedAtMs: 4_000)
            ],
            finalAssistantMessage: "All checks passed and the build is green.",
            finished: true
        )
        let renderable = AgentAppView.renderableItems(in: turn)

        XCTAssertEqual(AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable).map(\.id), ["msg-3"],
                       "only the last assistant message must remain the visible answer when a turn emits multiple preamble messages")
        XCTAssertEqual(AgentAppView.completedWorkItems(in: turn, renderableItems: renderable).map(\.id), ["msg-1", "msg-2"],
                       "earlier preamble assistant messages must collapse into the Worked disclosure, not show as the final answer")
    }

    func test_completedLegacyGrokConcatenatedFinalKeepsLastAnswerVisible() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-grok-legacy",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-grok-legacy", type: .assistantMessage, state: .completed, body: "I'll inspect first.", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "msg-2", turnId: "turn-grok-legacy", type: .assistantMessage, state: .completed, body: "Done.", startedAtMs: 2_000, finishedAtMs: 3_000)
            ],
            finalAssistantMessage: "I'll inspect first.Done.",
            finished: true
        )
        let renderable = AgentAppView.renderableItems(in: turn)

        XCTAssertEqual(
            AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable).map(\.id),
            ["msg-2"],
            "legacy Grok concatenated finals must keep the last answer outside the Worked disclosure"
        )
        XCTAssertEqual(
            AgentAppView.completedWorkItems(in: turn, renderableItems: renderable).map(\.id),
            ["msg-1"],
            "legacy Grok preambles must remain in the Worked disclosure"
        )
    }

    func test_persistedLastMessageRendersOnceWhilePreamblesStayInWorkLog() {
        // After the run finishes, the turn final is the chat answer. Preambles
        // stay in the Worked disclosure; the persisted bubble must not paint
        // the same last message beside it.
        let threadId = AgentThreadID()
        let persisted = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "All checks passed and the build is green."
        )
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Let me read the config first.", startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Now running the test suite.", startedAtMs: 2),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "All checks passed and the build is green.", startedAtMs: 3)
            ],
            finalAssistantMessage: "All checks passed and the build is green.",
            finished: true
        )

        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(messages: [persisted], timelineTurns: [turn]),
            [persisted.id],
            "the turn final is the chat answer after Work so far; the persisted copy must not paint beside it"
        )

        // Once the persisted answer has filtered the matching last item out of the
        // renderable set, NO timeline item is the final answer, so every preamble
        // demotes to the work log and the persisted bubble is the sole answer.
        // (Before the fix this returned all preamble items, double-rendering them.)
        let renderableWithPersisted = AgentAppView.renderableItems(in: turn, persistedAssistantTexts: ["All checks passed and the build is green."])
        XCTAssertTrue(
            AgentAppView.completedFinalAssistantItemIDs(in: turn, renderableItems: renderableWithPersisted, persistedAssistantTexts: ["All checks passed and the build is green."]).isEmpty,
            "no preamble may be promoted to the visible final answer once the real answer is shown by the persisted bubble"
        )
    }

    func test_turnViewRendersFinalWhenAssistantItemBodyIsOnlyPartial() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S count: 1 2 3 4 5 6 7 8 9 10 now count to 15",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "S count: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15",
            finished: true
        )

        XCTAssertTrue(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                      "a partial live assistant body must not hide the completed final answer")
    }

    func test_turnViewDoesNotDuplicateFinalWhenAssistantItemAlreadyRenderedBody() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, body: "final answer", startedAtMs: 1)
            ],
            finalAssistantMessage: "final answer",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                       "a non-empty assistant item already renders the final answer")
    }

    func test_turnViewDoesNotDuplicateFinalWhenOnlyWhitespaceDiffers() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "D count only.\n\n1 2 3 4 5 6 7 8 9 10",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "D count only. 1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                       "formatting-only differences between live and final assistant text must not duplicate the visible answer")
    }

    func test_turnViewDoesNotDuplicateFinalWhenWhitespaceBeforeNumberDiffers() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "D count only.\n\n1 2 3 4 5 6 7 8 9 10",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "D count only.1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                       "streamed and final assistant text can differ only by a missing space before the first token; that must stay one visible answer")
    }

    func test_turnViewDoesNotDuplicateFinalWhenMultipleAssistantItemsAlreadyRenderedIt() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S e2e-fullaccess-start. D run pwd.",
                              startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "S e2e-fullaccess-after-pwd. D run git status.",
                              startedAtMs: 2),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage,
                              body: "O e2e-fullaccess-done.",
                              startedAtMs: 3)
            ],
            finalAssistantMessage: "S e2e-fullaccess-start. D run pwd.S e2e-fullaccess-after-pwd. D run git status.O e2e-fullaccess-done.",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                       "when a turn streams several assistant updates, the persisted final can equal their combined text and must not be rendered as a duplicate block")
    }

    func test_turnViewUsesPersistedAssistantMessageAsCompletedAnswer() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "tool-1", turnId: "turn-1", type: .mcpToolCall,
                              summary: "MCP server status", startedAtMs: 1)
            ],
            finalAssistantMessage: "1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        // Turn has tool work → own the final after Work so far (message is hidden).
        XCTAssertTrue(AgentAppView.shouldRenderFinalAssistantMessage(
            turn,
            persistedAssistantTexts: ["1 2 3 4 5 6 7 8 9 10"]
        ), "when Work so far exists, the turn must own the final after the disclosure even if a persisted row also holds the text")
        let hidden = AgentAppView.hiddenPersistedAssistantMessageIDs(
            messages: [
                AgentMessage(
                    threadId: AgentThreadID(),
                    role: .assistant,
                    content: "1 2 3 4 5 6 7 8 9 10"
                )
            ],
            timelineTurns: [turn]
        )
        XCTAssertEqual(hidden.count, 1,
                       "matching persisted assistant row must hide so the answer is not painted above Work so far")
    }

    func test_turnViewKeepsAssistantPartialVisibleWhenPersistedAnswerContainsIt() {
        let persisted = """
        The wrapper is not a Git repository.
        Memory confirms the wrapper workspace; Git lives in nested folders.
        Locate nested repositories, then stage, commit, and push each dirty repository.
        """

        XCTAssertTrue(AgentAppView.shouldRenderAssistantItemBody(
            """
            The wrapper is not a Git repository.
            """,
            persistedAssistantTexts: [persisted]
        ), "live partial updates must stay visible even when an older persisted answer contains the same prefix")
    }

    func test_turnViewHidesDuplicateAssistantItemBodiesWithinTurn() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "Pre-commit hooks passed. Push.",
                              startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "Pre-commit hooks passed. Push.",
                              startedAtMs: 2),
                AssistantItem(id: "tool-1", turnId: "turn-1", type: .tool,
                              summary: "Ran Bash",
                              startedAtMs: 3)
            ],
            finished: true
        )

        let visibleAssistantBodies = AgentAppView.renderableItems(in: turn)
            .filter { $0.type == .assistantMessage }
            .map(\.body)
        XCTAssertEqual(visibleAssistantBodies, ["Pre-commit hooks passed. Push."],
                       "Claude can replay the same assistant text block with a new item id; the macOS transcript must still render that text once")
        XCTAssertTrue(AgentAppView.renderableItems(in: turn).contains { $0.type == .tool },
                      "deduping assistant text must not hide adjacent work-log/tool rows")
    }

    func test_persistedAssistantMessageHidesWhenLiveItemsAlreadyRenderCombinedText() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S e2e-fullaccess2-start. D run pwd.",
                              startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "S e2e-fullaccess2-after-pwd. D run git status in macos-app.",
                              startedAtMs: 2),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage,
                              body: "O e2e-fullaccess2-done.",
                              startedAtMs: 3)
            ],
            finalAssistantMessage: "S e2e-fullaccess2-start. D run pwd.S e2e-fullaccess2-after-pwd. D run git status in macos-app.O e2e-fullaccess2-done.",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderPersistedAssistantMessage(
            "S e2e-fullaccess2-start. D run pwd.S e2e-fullaccess2-after-pwd. D run git status in macos-app.O e2e-fullaccess2-done.",
            timelineTurns: [turn]
        ), "the persisted assistant row must not duplicate the live macOS timeline when all partial updates already render")
    }

    func test_persistedAssistantMessageRendersWhenOnlyLiveItemIsDuplicateFinal() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "1 2 3 4 5 6 7 8 9 10",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertTrue(AgentAppView.shouldRenderPersistedAssistantMessage(
            "1 2 3 4 5 6 7 8 9 10",
            timelineTurns: [turn]
        ), "when the only live assistant item duplicates the persisted final, the live item is suppressed so the persisted answer must remain visible")
    }

    func test_persistedAssistantMessageRendersWhenLiveItemsAreOnlyPartial() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S count: 1 2 3 4 5",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "S count: 1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertTrue(AgentAppView.shouldRenderPersistedAssistantMessage(
            "S count: 1 2 3 4 5 6 7 8 9 10",
            timelineTurns: [turn]
        ), "if the live timeline has only a partial response, the persisted assistant answer must still render")
    }

    func test_hiddenPersistedAssistantMessageIDsHidesCombinedLiveAnswerOnce() {
        let threadId = AgentThreadID()
        let persisted = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "S start. D inspect. O done."
        )
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S start. D inspect.",
                              startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "O done.",
                              startedAtMs: 2)
            ],
            finished: true
        )

        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(messages: [persisted], timelineTurns: [turn]),
            [persisted.id],
            "persisted assistant rows must be hidden when the live timeline already renders the same combined answer"
        )
    }

    func test_hiddenPersistedAssistantMessageIDsHidesEachPersistedProgressMessageOwnedByTurn() {
        // WHY: the shared turn chrome paints every assistant progress item. If
        // those same updates are also durable AgentMessages, keeping both rows
        // produces the doubled progress text and copy buttons seen in Agent App.
        let threadId = AgentThreadID()
        let first = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "State intact. Verifying the unrelated failure."
        )
        let second = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "Confirmed pre-existing. Running the isolated suite."
        )
        let final = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "Zero failures across every touched module."
        )
        let turn = AssistantTurnSnapshot(
            turnId: "turn-progress",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-progress", type: .assistantMessage,
                              state: .completed, body: first.content, startedAtMs: 1, finishedAtMs: 2),
                AssistantItem(id: "tool-1", turnId: "turn-progress", type: .commandExecution,
                              state: .completed, summary: "Bash", startedAtMs: 3, finishedAtMs: 4),
                AssistantItem(id: "msg-2", turnId: "turn-progress", type: .assistantMessage,
                              state: .completed, body: second.content, startedAtMs: 5, finishedAtMs: 6),
                AssistantItem(id: "msg-3", turnId: "turn-progress", type: .assistantMessage,
                              state: .completed, body: final.content, startedAtMs: 7, finishedAtMs: 8),
            ],
            finalAssistantMessage: final.content,
            finished: true
        )

        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(
                messages: [first, second, final],
                timelineTurns: [turn]
            ),
            [first.id, second.id, final.id],
            "each durable copy already owned by the turn must be hidden, including intermediate progress"
        )
    }

    func test_hiddenPersistedAssistantMessageIDsKeepsPersistedAnswerWhenLiveDuplicateIsSuppressed() {
        let threadId = AgentThreadID()
        let persisted = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "1 2 3 4 5 6 7 8 9 10"
        )
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "1 2 3 4 5 6 7 8 9 10",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(messages: [persisted], timelineTurns: [turn]),
            [persisted.id],
            "the turn final is the chat answer; the persisted copy must not paint beside it"
        )
    }

    /// WHY: user messages must never be character-truncated in the bubble; long
    /// paths and full prompts stay intact (layout wraps / Show more by lines only).
    func test_userMessageDisplayTextPreservesFullPromptWithoutCharacterCap() {
        let longPrompt = String(repeating: "a", count: 2_500)
        let pathPrompt = "/Users/samuelfajreldines/Desktop/Screenshot 2026-07-18 at 5.23.56 PM.png"
        XCTAssertEqual(AgentAppView.userMessageDisplayText(longPrompt), longPrompt,
                       "user bubbles must show the full stored prompt, not a character-capped preview")
        XCTAssertEqual(AgentAppView.userMessageDisplayText(pathPrompt), pathPrompt,
                       "file-path prompts must keep the full path visible without ellipsis in the model text")
    }

    func test_visibleLiveTurnItemsKeepsOnlyRecentUpdatesWhileRunning() {
        let itemCount = 5_000
        let items = (0..<itemCount).map { index in
            AssistantItem(id: "item-\(index)", turnId: "turn-1", type: .assistantMessage, body: "\(index)", startedAtMs: Int64(index))
        }
        let visible = AgentAppView.visibleLiveTurnItems(items, running: true)

        XCTAssertEqual(visible.count, AgentAppView.liveTurnRenderableItemLimit,
                       "active turns must render a bounded tail so manual scrolling cannot force LazyVStack to place thousands of live rows")
        XCTAssertEqual(visible.first?.id, "item-\(itemCount - AgentAppView.liveTurnRenderableItemLimit)",
                       "the bounded tail must keep the newest live updates instead of the oldest ones")
        XCTAssertEqual(AgentAppView.visibleLiveTurnItems(items, running: false).count, items.count,
                       "completed or idle turns must retain full renderable history")
    }

    func test_visibleLiveTurnItemsCapsLargeLiveStringsOnlyForRendering() {
        let hugeBody = String(repeating: "b", count: AgentAppView.liveTurnBodyCharacterLimit + 5_000)
        let hugeOutput = String(repeating: "o", count: AgentAppView.liveTurnOutputCharacterLimit + 5_000)
        let hugeSummary = String(repeating: "s", count: AgentAppView.liveTurnSummaryCharacterLimit + 5_000)
        let item = AssistantItem(id: "huge", turnId: "turn-1", type: .commandExecution, summary: hugeSummary,
                                 body: hugeBody, output: hugeOutput, startedAtMs: 1)

        let visible = AgentAppView.visibleLiveTurnItems([item], running: true)

        XCTAssertEqual(visible.count, 1)
        XCTAssertLessThan(visible[0].body.count, hugeBody.count,
                          "live rendering must not carry full command bodies through SwiftUI layout")
        XCTAssertLessThan(visible[0].output?.count ?? 0, hugeOutput.count,
                          "live rendering must not carry full command outputs through SwiftUI layout")
        XCTAssertLessThan(visible[0].summary?.count ?? 0, hugeSummary.count,
                          "live rendering must not carry full summaries through SwiftUI layout")
        XCTAssertEqual(AgentAppView.visibleLiveTurnItems([item], running: false)[0].output, hugeOutput,
                       "stored/completed data remains full; only active live UI copies are capped")
    }

    /// Streaming Thought must show the *latest* tokens (terminal UX), not a frozen
    /// head of the chain-of-thought that freezes while later reasoning keeps growing.
    func test_streamingReasoningLiveCapKeepsTailNotHead() {
        let head = String(repeating: "A", count: 80)
        let tail = "LATEST-THOUGHT-TOKEN"
        let pad = String(repeating: "b", count: AgentAppView.liveTurnBodyCharacterLimit)
        let body = head + pad + tail
        let item = AssistantItem(id: "r1", turnId: "t1", type: .reasoning, state: .streaming,
                                 body: body, startedAtMs: 1)
        let visible = AgentAppView.visibleLiveTurnItems([item], running: true)
        XCTAssertEqual(visible.count, 1)
        XCTAssertTrue(visible[0].body.contains(tail),
                      "live Thinking… must show the newest reasoning tokens like the Grok TUI")
        XCTAssertFalse(visible[0].body.hasPrefix(head),
                       "capping the head freezes early thoughts while later ones rewrite 'on top' of the answer")
        let completed = AssistantItem(id: "r2", turnId: "t1", type: .reasoning, state: .completed,
                                      body: body, startedAtMs: 1)
        let completedVisible = AgentAppView.visibleLiveTurnItems([completed], running: true)
        XCTAssertTrue(completedVisible[0].body.hasPrefix(head),
                      "completed Thought rows keep the conventional head cap for stable collapsed previews")
        XCTAssertFalse(completedVisible[0].body.contains(tail),
                       "completed head-cap must not keep the tail window used only while streaming")
    }

    func test_streamingToolBodyAndOutputLiveCapKeepsTailNotHead() {
        // WHY: head-capping tool body/output froze mid-run Work so far streams.
        let head = String(repeating: "A", count: 80)
        let bodyTail = "LATEST-BODY-TOKEN"
        let outTail = "LATEST-OUT-TOKEN"
        let bodyPad = String(repeating: "b", count: AgentAppView.liveTurnBodyCharacterLimit)
        let outPad = String(repeating: "o", count: AgentAppView.liveTurnOutputCharacterLimit)
        let item = AssistantItem(
            id: "cmd", turnId: "t1", type: .commandExecution, state: .streaming,
            body: head + bodyPad + bodyTail,
            output: head + outPad + outTail,
            startedAtMs: 1
        )
        let visible = AgentAppView.visibleLiveTurnItems([item], running: true)
        XCTAssertTrue(visible[0].body.contains(bodyTail))
        XCTAssertFalse(visible[0].body.hasPrefix(head))
        XCTAssertTrue(visible[0].output?.contains(outTail) == true)
        XCTAssertFalse(visible[0].output?.hasPrefix(head) == true)
    }

    func test_toolCommandPreviewCapsLongCommandsForCollapsedRows() {
        let command = "gh api graphql " + String(repeating: "x", count: AgentAppView.commandPreviewCharacterLimit + 200)
        let body = #"{"command":"\#(command)"}"#
        let item = AssistantItem(id: "cmd", turnId: "turn-1", type: .commandExecution, body: body, startedAtMs: 1)

        let preview = AgentAppView.toolCommandPreview(for: item)

        XCTAssertNotNil(preview)
        XCTAssertLessThan(preview?.count ?? 0, command.count,
                          "collapsed command rows should not feed huge command strings into SwiftUI text layout")
        XCTAssertTrue(preview?.contains("hidden from preview") == true)
    }

    func test_finishCallbackReflectsCoordinatorOwnedUnreadUntilOpened() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "done")
        let id = try XCTUnwrap(vm.selectedThreadId)
        var completed = try XCTUnwrap(repo.get(id: id))
        completed.status = .completed
        completed.hasUnread = true
        try repo.upsert(completed)
        let callbackFinished = expectation(description: "finish callback applied")
        vm.onRunCompleted = { callbackFinished.fulfill() }
        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "done", providerThreadId: nil)
        await fulfillment(of: [callbackFinished], timeout: 2)

        // The rail reload is coalesced (scheduleReloadThreads, ~50ms) so many
        // open Agent Apps don't stampede on one finish fan-out — poll for it.
        await waitAsync("rail reflects coordinator-owned unread", timeout: 2) {
            vm.threads.first { $0.id == id }?.hasUnread == true
        }
        XCTAssertTrue(vm.threads.first { $0.id == id }?.hasUnread ?? false,
                      "the callback must reflect coordinator-owned unread state in the rail")

        vm.selectThread(id)
        XCTAssertEqual(try repo.get(id: id)?.hasUnread, false,
                       "clicking/opening the completed thread must clear the indicator")
    }

    func test_delayedFinishCallbackNeverResurrectsCoordinatorUnreadAfterRead() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "done")
        let id = try XCTUnwrap(vm.selectedThreadId)
        var completed = try XCTUnwrap(repo.get(id: id))
        completed.status = .completed
        completed.hasUnread = true
        try repo.upsert(completed)
        vm.reloadThreads()
        vm.selectThread(id)
        XCTAssertFalse(try XCTUnwrap(repo.get(id: id)).hasUnread,
            "the canonical read must clear coordinator-owned completion attention")
        let callbackFinished = expectation(description: "delayed finish callback applied")
        vm.onRunCompleted = { callbackFinished.fulfill() }

        vm.runCoordinator(
            vm.coordinator,
            didFinish: AgentRunID(),
            threadId: id,
            status: .completed,
            finalMessage: "done",
            providerThreadId: nil
        )
        await fulfillment(of: [callbackFinished], timeout: 2)

        XCTAssertFalse(try XCTUnwrap(repo.get(id: id)).hasUnread,
            "a delayed view callback must never overwrite a newer canonical read")
        vm.reloadThreads()
        XCTAssertFalse(vm.threads.first(where: { $0.id == id })?.hasUnread ?? true,
            "the local rail must keep the newer read state")
    }

    func test_runningStatusCallbackReflectsCoordinatorClearedUnreadIndicator() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "rerun")
        let id = try XCTUnwrap(vm.selectedThreadId)
        var completed = try XCTUnwrap(repo.get(id: id))
        completed.status = .completed
        completed.hasUnread = true
        try repo.upsert(completed)
        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "done", providerThreadId: nil)
        await waitAsync("completion callback reflects coordinator unread") {
            vm.threads.first(where: { $0.id == id })?.hasUnread == true
        }
        var running = try XCTUnwrap(repo.get(id: id))
        running.status = .running
        running.hasUnread = false
        try repo.upsert(running)

        vm.runCoordinator(vm.coordinator, didChangeStatus: .running, runId: AgentRunID(), threadId: id)

        await waitAsync("running callback reflects coordinator read state") {
            vm.threads.first(where: { $0.id == id })?.hasUnread == false
        }
        XCTAssertFalse(vm.threads.first { $0.id == id }?.hasUnread ?? true,
                       "the rail must reflect the coordinator's running-state unread reset")
    }

    func test_threadRowSelectionCheckNeverAppearsForClickedThread() {
        XCTAssertFalse(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .running,
            selected: false,
            surfaceStatus: .pending,
            multiSelected: true
        ), "running work must show the spinner without also implying completion")

        XCTAssertFalse(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .pending,
            selected: true,
            surfaceStatus: .running,
            multiSelected: true
        ), "the selected thread must suppress the check while its run is still active")

        XCTAssertFalse(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .completed,
            selected: true,
            surfaceStatus: .completed,
            multiSelected: true
        ), "clicking a thread selects it via highlight only; no trailing check icon")

        XCTAssertTrue(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .completed,
            selected: false,
            surfaceStatus: .completed,
            multiSelected: true
        ), "bulk-selected, non-open rows can still show the selection check")
    }

    func test_completedUnreadThreadShowsOnlyTrailingDot() {
        XCTAssertFalse(AgentThreadRowPresentation.showsLeadingStatus(
            threadStatus: .completed,
            selected: true,
            surfaceStatus: .completed,
            hasUnread: true,
            pinned: false
        ), "completed unread work must use the trailing dot only, without a second idle dot on the left")

        XCTAssertTrue(AgentThreadRowPresentation.showsLeadingStatus(
            threadStatus: .completed,
            selected: true,
            surfaceStatus: .completed,
            hasUnread: true,
            pinned: true
        ), "pinned rows keep their pin because it is not a completion indicator")
    }

    func test_pendingStatusTracksRunIdBeforeStartRunReturnsSoStopWorks() async throws {
        let (vm, repo) = try makeVM()
        let runner = PendingStartRunner()
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "slow")
        vm.prompt = "start slow run"

        let sendTask = Task { await vm.send() }
        await waitAsync("provider start is blocked after pending state persists") {
            runner.enteredStart
        }

        XCTAssertEqual(vm.status, .pending,
                       "a provider start that has not returned must remain visibly stoppable")
        XCTAssertTrue(vm.selectedThreadRunIsStartingOrRunning,
                      "the pending start must render the same Stop affordance as a running turn")
        XCTAssertNotNil(vm.currentRunId,
                        "Stop needs the stable run id before the provider handle exists")
        XCTAssertEqual(try repo.get(id: vm.selectedThreadId!)?.status, .pending,
                       "the pending state must survive a surface or process restart")

        vm.stop()
        runner.releaseStart()

        await waitAsync("pending stop cancels after handle registration") {
            runner.cancelled
        }
        await sendTask.value
    }

    /// WHY: between the user's bubble appearing and a run id existing, the surface
    /// does real work — transcript load, git subprocesses,
    /// prompt compression, provider spawn. That window rendered NOTHING, so a slow
    /// dependency looked like the app had hung. "Loading…" must fill exactly that gap
    /// and must hand over to "Working for Xs" the moment the run is tracked, never
    /// showing both and never leaking onto a sibling thread.
    func test_loadingStatusCoversPrepareWindowThenYieldsToWorking() async throws {
        let runner = PendingStartRunner()
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "prepare window")
        let sendingThreadId = vm.selectedThreadId!

        // providerLaunchConfig is invoked mid-prepare: after the bubble, before the
        // run exists. It is the only synchronous observation point in that window.
        var preparingMidWindow: Bool?
        var runActiveMidWindow: Bool?
        var preparingForSiblingThread: Bool?
        vm.providerLaunchConfig = { _, _ in
            preparingMidWindow = vm.selectedThreadIsPreparingRun
            runActiveMidWindow = vm.selectedThreadRunIsStartingOrRunning
            let restore = vm.selectedThreadId
            vm.selectedThreadId = AgentThreadID()
            preparingForSiblingThread = vm.selectedThreadIsPreparingRun
            vm.selectedThreadId = restore
            return (binary: nil, environment: [:])
        }
        vm.prompt = "prepare then work"

        let sendTask = Task { await vm.send() }
        await waitAsync("provider start reached, so the prepare window has closed") {
            runner.enteredStart
        }

        XCTAssertEqual(preparingMidWindow, true,
                       "the prepare window must render Loading… — leaving it blank is what read as a hang while preparation shelled out to git")
        XCTAssertEqual(runActiveMidWindow, false,
                       "precondition: no run is tracked yet mid-prepare, so Working cannot be what covers this window")
        XCTAssertEqual(preparingForSiblingThread, false,
                       "Loading… is scoped to the sending thread; switching tabs mid-prepare must not mark a sibling thread busy")

        XCTAssertFalse(vm.selectedThreadIsPreparingRun,
                       "once the run is tracked, Working takes over — both lines rendering at once would double the status row")
        XCTAssertTrue(vm.selectedThreadRunIsStartingOrRunning,
                      "the tracked run is what Working renders from")

        vm.stop()
        runner.releaseStart()
        await waitAsync("stop cancels the pending start") { runner.cancelled }
        await sendTask.value

        XCTAssertNil(vm.preparingRunThreadId,
                     "the prepare marker must be cleared once send returns, or the thread stays Loading… forever")
    }

    /// WHY: the prepare marker is set before several failure exits (thread vanished,
    /// provider start refused). If any of them skips the cleanup the transcript is
    /// stuck on a spinner with no run behind it and no way to clear it.
    func test_preparingRunClearsWhenProviderStartFails() async throws {
        let (vm, _) = try makeVM(provider: ThrowingStartRunner())
        vm.createThread(title: "refused start")
        vm.prompt = "this start will be refused"

        await vm.send()

        XCTAssertNil(vm.preparingRunThreadId,
                     "a refused provider start must clear the prepare marker — otherwise Loading… outlives the failure")
        XCTAssertFalse(vm.selectedThreadIsPreparingRun,
                       "no spinner may survive a failed start")
        XCTAssertEqual(vm.status, .failed,
                       "precondition: the start really did fail, so this test is exercising the error exit")
    }

    func test_streamEventsFanOutToEveryAgentSurfaceViewingTheThread() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-fanout-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: ImmediateStreamRunner()]
        )
        let workspaceID = WorkspaceID()
        let firstSurface = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                             coordinator: coordinator, threadRepo: threadRepo,
                                             messageRepo: messageRepo)
        let secondSurface = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                              coordinator: coordinator, threadRepo: threadRepo,
                                              messageRepo: messageRepo)
        installRunnableProviderFixtures(on: firstSurface)
        firstSurface.createThread(title: "shared")
        let threadId = firstSurface.selectedThreadId!
        secondSurface.reloadThreads()
        secondSurface.selectThread(threadId)

        firstSurface.prompt = "stream please"
        await firstSurface.send()

        await waitAsync("sender surface receives live partial stream") {
            firstSurface.timeline.turns.flatMap(\.items).contains {
                $0.type == .assistantMessage && $0.body.contains("partial stream")
            }
        }
        await waitAsync("second surface viewing same thread receives live partial stream") {
            secondSurface.timeline.turns.flatMap(\.items).contains {
                $0.type == .assistantMessage && $0.body.contains("partial stream")
            }
        }
    }

    func test_timelineBuffersAssistantDeltaUntilItemStartedArrives() {
        var timeline = AssistantTimelineState()

        timeline.apply(.turnStarted(turnId: "turn-1"))
        timeline.apply(.itemDelta(itemId: "assistant-1", bodyAppend: "O: 1 2 3", outputAppend: nil, summary: nil))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "assistant-1",
            turnId: "turn-1",
            type: .assistantMessage,
            startedAtMs: 1
        )))

        XCTAssertEqual(timeline.turns.first?.items.first?.body, "O: 1 2 3",
                       "provider notifications can reach the SwiftUI surface out of order; the first assistant delta must not be dropped or the user sees only tool/status rows")
    }

    func test_timelineIgnoresDuplicateTurnStartedForSameTurn() {
        var timeline = AssistantTimelineState()

        timeline.apply(.turnStarted(turnId: "turn-1"))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "assistant-1",
            turnId: "turn-1",
            type: .assistantMessage,
            startedAtMs: 1
        )))
        timeline.apply(.itemDelta(itemId: "assistant-1", bodyAppend: "partial stream", outputAppend: nil, summary: nil))
        timeline.apply(.turnStarted(turnId: "turn-1"))

        XCTAssertEqual(timeline.turns.map(\.turnId), ["turn-1"],
                       "duplicate provider turn-start notifications must not duplicate the visible macOS transcript")
        XCTAssertEqual(timeline.turns.first?.items.first?.body, "partial stream",
                       "deduping the turn must preserve already streamed assistant text")
    }

    func test_promptComposerEnterSendsAndShiftEnterInsertsNewline() {
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r",
                                     isARepeat: false, keyCode: 36)!
        let shiftEnter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "\r", charactersIgnoringModifiers: "\r",
                                          isARepeat: false, keyCode: 36)!

        XCTAssertEqual(PromptComposerKeyAction.action(for: enter), .send,
                       "plain Enter must send the prompt")
        XCTAssertEqual(PromptComposerKeyAction.action(for: shiftEnter), .insertNewline,
                       "Shift+Enter must keep editing and insert a line break")
    }

    func test_promptComposerArrowKeysRequestHistoryNavigation() {
        let up = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: 0, windowNumber: 0, context: nil,
                                  characters: "", charactersIgnoringModifiers: "",
                                  isARepeat: false, keyCode: 126)!
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: 125)!

        XCTAssertEqual(PromptComposerKeyAction.action(for: up), .previousHistory,
                       "Up arrow must behave like Terminal history when the composer is empty")
        XCTAssertEqual(PromptComposerKeyAction.action(for: down), .nextHistory,
                       "Down arrow must walk back toward the empty composer after history recall")
    }

    func test_emptyPromptRecallsSubmittedCommandHistoryLikeTerminal() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        vm.prompt = "/status"
        await vm.send()
        vm.prompt = "/model none"
        await vm.send()

        XCTAssertTrue(vm.recallPreviousPrompt())
        XCTAssertEqual(vm.prompt, "/model none",
                       "an empty composer Up arrow must restore the last submitted command")
        XCTAssertTrue(vm.recallPreviousPrompt())
        XCTAssertEqual(vm.prompt, "/status",
                       "a second Up arrow must continue through older submitted commands")
        XCTAssertTrue(vm.recallNextPrompt())
        XCTAssertEqual(vm.prompt, "/model none",
                       "Down arrow must move forward through recalled command history")
        XCTAssertTrue(vm.recallNextPrompt())
        XCTAssertEqual(vm.prompt, "",
                       "Down arrow after the newest recalled command must return to an empty composer")
    }

    func test_promptHistoryDoesNotOverwriteTypedDraft() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        vm.prompt = "/status"
        await vm.send()
        vm.prompt = "typed draft"

        XCTAssertFalse(vm.recallPreviousPrompt())

        XCTAssertEqual(vm.prompt, "typed draft",
                       "history recall must not replace text the user is already typing")
    }

    func test_unknownSlashCommandPassesThroughToProviderForAgentOwnedCommands() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .codex)
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "goal")
        vm.prompt = "/goal continue until the audit is implemented"

        await vm.send()

        await waitAsync("provider-owned slash command reaches runner") {
            runner.prompts.contains("/goal continue until the audit is implemented")
        }
        XCTAssertFalse(vm.messages.contains { $0.role == .system && $0.content.contains("Unknown command") },
                       "unknown slash commands must not be converted into local errors because providers own commands such as /goal")
    }

    // WHY: autocomplete insert keeps the typed `$` trigger; every provider expects /goal.
    func test_dollarGoalSendNormalizesToSlashGoalForProvider() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .codex)
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.provider = .codex
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: ["/goal", "/review"],
                skills: ["sam-work"]
            )
        ]
        vm.providerInstanceId = "codex-cli"
        vm.createThread(title: "dollar-goal")
        vm.prompt = "$goal continue until the audit is implemented"

        await vm.send()

        await waitAsync("dollar-goal normalizes to slash-goal for the provider") {
            runner.prompts.contains("/goal continue until the audit is implemented")
        }
        XCTAssertFalse(runner.prompts.contains(where: { $0.hasPrefix("$goal") }),
                       "$goal must not be forwarded literally — providers expect /goal as the command")
    }

    // WHY: Grok/Claude snapshots previously omitted /goal; $goal must still normalize
    // and autocomplete must still surface /goal via the universal pass-through list.
    func test_goalWorksOnGrokAndClaudeEvenWhenSnapshotOmitsGoal() async throws {
        for provider in [AgentProvider.grok, .claude] {
            let (vm, _) = try makeVM()
            let runner = CapturingProviderRunner(provider: provider)
            vm.coordinator.replaceProvider(provider, runner: runner)
            vm.provider = provider
            let instanceId = "\(provider.rawValue)-cli"
            vm.providerSnapshots = [
                AgentProviderSnapshot(
                    id: instanceId,
                    provider: provider,
                    driverKind: provider == .grok ? .grokCLI : .claudeCLI,
                    displayName: provider.rawValue.capitalized,
                    accentColor: "#000000",
                    continuationGroup: provider.rawValue,
                    interactionModes: [.default],
                    enabled: true,
                    installed: true,
                    status: .available,
                    models: [AgentModelDescriptor(
                        id: "m",
                        label: "M",
                        provider: provider
                    )],
                    // Deliberately omit /goal — pass-through must still supply it.
                    slashCommands: ["/status"],
                    skills: ["sam-work"]
                )
            ]
            vm.providerInstanceId = instanceId

            vm.prompt = "/go"
            XCTAssertTrue(vm.composerSuggestions.map(\.insertText).contains("/goal "),
                          "\(provider.rawValue) must autocomplete /goal even when the snapshot omits it")

            vm.prompt = "$go"
            XCTAssertTrue(vm.composerSuggestions.map(\.insertText).contains("$goal "),
                          "\(provider.rawValue) must autocomplete $goal even when the snapshot omits it")

            vm.createThread(title: "goal-\(provider.rawValue)")
            vm.prompt = "$goal ship the fix"
            await vm.send()
            await waitAsync("\(provider.rawValue) $goal normalizes to /goal") {
                runner.prompts.contains("/goal ship the fix")
            }
        }
    }

    func test_sendingNewPromptClearsStaleVisibleError() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "retry prompt")
        vm.timeline.apply(.error(message: "Previous provider failure", recoverable: true))
        vm.prompt = "try again"

        await vm.send()

        XCTAssertNil(vm.timeline.error,
                     "sending a new prompt must clear the stale error banner immediately so the next attempt is not shown under an old failure")
        await waitAsync("new prompt reaches runner") {
            runner.prompts.contains("try again")
        }
    }

    func test_queueingNewPromptWhileRunningClearsStaleVisibleError() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "queue retry")
        vm.status = .running
        vm.timeline.apply(.error(message: "Previous provider failure", recoverable: true))
        vm.prompt = "queue this"

        await vm.send()

        XCTAssertNil(vm.timeline.error,
                     "queueing a new prompt is still a new user message and must clear the stale visible error before the queued turn runs")
    }

    func test_retryLastPromptClearsStaleVisibleError() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "retry button")
        vm.prompt = "first attempt"
        await vm.send()
        await waitAsync("first attempt reaches runner") {
            runner.prompts.contains("first attempt")
        }
        vm.timeline.apply(.error(message: "Previous provider failure", recoverable: true))

        await vm.retryLastPrompt()

        XCTAssertNil(vm.timeline.error,
                     "retrying the last prompt sends a new user message and must clear the stale error banner before the retried run starts")
        await waitAsync("retry reaches runner") {
            runner.prompts.filter { $0 == "first attempt" }.count >= 2
        }
    }

    func test_retryResendsValidatedManagedAttachments() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "retry attachment")
        let source = URL(fileURLWithPath: vm.cwd).appendingPathComponent("retry.txt")
        try Data("retry attachment bytes".utf8).write(to: source)
        vm.prompt = "inspect attachment"
        vm.addAttachments([source.path])
        await vm.send()
        await waitAsync("first attachment turn reaches runner") { runner.attachments.count == 1 }
        vm.timeline.apply(.error(message: "retryable provider failure", recoverable: true))

        await vm.retryLastPrompt()
        await waitAsync("retried attachment turn reaches runner") { runner.attachments.count == 2 }

        XCTAssertEqual(runner.attachments[1].map(\.sha256), runner.attachments[0].map(\.sha256),
                       "Retry must resend the exact content-addressed managed blob from the failed request")
        XCTAssertNil(vm.pendingAttachmentRetryConfirmation)
    }

    func test_retryWithMissingManagedAttachmentRequiresConfirmation() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "retry missing attachment")
        let source = URL(fileURLWithPath: vm.cwd).appendingPathComponent("missing-after-send.txt")
        try Data("temporary".utf8).write(to: source)
        vm.prompt = "inspect missing attachment"
        vm.addAttachments([source.path])
        await vm.send()
        await waitAsync("first missing-attachment turn reaches runner") { runner.attachments.count == 1 }
        let managedPath = try XCTUnwrap(runner.attachments.first?.first?.path)
        try FileManager.default.removeItem(atPath: managedPath)
        vm.timeline.apply(.error(message: "retryable provider failure", recoverable: true))

        await vm.retryLastPrompt()

        XCTAssertEqual(runner.prompts.filter { $0 == "inspect missing attachment" }.count, 1,
                       "Retry must pause before dropping an unavailable attachment")
        XCTAssertEqual(vm.pendingAttachmentRetryConfirmation?.unavailableAttachmentNames,
                       ["missing-after-send.txt"])
        XCTAssertNotNil(vm.timeline.error,
                        "the original error remains visible until the user confirms the lossy retry")

        await vm.confirmRetryWithoutUnavailableAttachments()
        await waitAsync("confirmed lossy retry reaches runner") {
            runner.prompts.filter { $0 == "inspect missing attachment" }.count == 2
        }
        XCTAssertEqual(runner.attachments.last, [])
        XCTAssertNil(vm.pendingAttachmentRetryConfirmation)
        XCTAssertTrue(vm.messages.contains { $0.role == .system && $0.content.contains("missing-after-send.txt") },
                      "the confirmed omission must remain explicit in the transcript")
    }

    func test_retryUsesFailedRunPromptWhenNewerPromptIsQueued() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-retry-envelope-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let queueRepo = AgentQueuedMessageRepository(db: db)
        let runner = SlowStartRunner()
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
                                              providers: [.codex: runner])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp, coordinator: coordinator,
                                   threadRepo: threadRepo, messageRepo: messageRepo,
                                   queuedMessageRepo: queueRepo, promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "retry identity")
        vm.prompt = "failed request A"
        await vm.send()
        vm.prompt = "queued request B"
        await vm.send()
        vm.stop()
        vm.status = .failed

        await vm.retryLastPrompt()

        XCTAssertEqual(runner.prompts.last, "failed request A",
                       "Retry must replay the provider request that failed, not the newer workspace history tail")
        XCTAssertEqual(try queueRepo.list(threadId: XCTUnwrap(vm.selectedThreadId)).map(\.text), ["queued request B"],
                       "retrying A must neither duplicate nor consume queued request B")
    }

    func test_planCommandMakesNextProviderRunUsePlanInteractionMode() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .codex)
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "plan")
        vm.prompt = "/plan"
        await vm.send()
        vm.prompt = "inspect before editing"

        await vm.send()

        await waitAsync("plan mode reaches runner") {
            runner.interactionModes.contains(.plan)
        }
        XCTAssertEqual(runner.prompts.last, "inspect before editing",
                       "plan mode must alter request metadata without corrupting the user-visible prompt")
    }

    func test_inlinePlanCommandSendsRemainingPromptInPlanMode() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .codex)
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "inline plan")

        vm.prompt = "/plan What's the best way to create the snake game?"
        await vm.send()

        await waitAsync("inline plan prompt reaches runner") {
            runner.interactionModes.contains(.plan)
        }
        XCTAssertEqual(runner.prompts.last, "What's the best way to create the snake game?",
                       "mobile and desktop users must be able to type /plan plus the actual question in one send without dropping the user prompt")
    }

    func test_inlinePlanCommandWorksForClaudeProvider() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .claude)
        vm.coordinator.replaceProvider(.claude, runner: runner)
        vm.createThread(title: "inline plan claude")
        vm.provider = .claude
        vm.model = "claude-sonnet-4-6"

        vm.prompt = "/plan What's the best way to create the snake game?"
        await vm.send()

        await waitAsync("inline plan prompt reaches Claude runner") {
            runner.interactionModes.contains(.plan)
        }
        XCTAssertEqual(runner.prompts.last, "What's the best way to create the snake game?",
                       "Claude plan mode must receive the prompt text when /plan and the question are sent together")
    }

    func test_inlinePlanCommandFailsClosedForProviderWithoutPlanCapability() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .grok)
        vm.coordinator.replaceProvider(.grok, runner: runner)
        vm.createThread(title: "unsupported plan")
        vm.provider = .grok
        vm.providerInstanceId = "grok-cli"
        vm.interactionMode = .default
        vm.prompt = "/plan Inspect without editing"

        await vm.send()

        XCTAssertEqual(vm.interactionMode, .default)
        XCTAssertEqual(vm.prompt, "Inspect without editing",
                       "the user's question must remain editable after an unsupported /plan command")
        XCTAssertTrue(runner.prompts.isEmpty,
                      "an unsupported Plan request must not silently run in Default mode")
        XCTAssertTrue(vm.messages.contains { $0.role == .system && $0.content.contains("does not support Plan") })
    }

    func test_grokPermissionPickerFailsClosedForUnadvertisedMode() throws {
        let (vm, _) = try makeVM()
        let grok = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-live", label: "Grok Live", provider: .grok)],
            binaryPath: "/tmp/grok",
            permissionModesOverride: [.supervised]
        )
        vm.providerSnapshots = [grok]
        vm.setProviderInstance(grok.id)

        vm.setPermissionMode(.fullAccess)

        XCTAssertEqual(vm.permissionMode, .supervised,
                       "the UI must not persist a Grok permission mode absent from ACP session modes")
        XCTAssertTrue(vm.statusMessage.contains("does not support Full access"))
    }

    func test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .claude)
        vm.coordinator.replaceProvider(.claude, runner: runner)
        vm.createThread(title: "default")
        vm.provider = .claude
        vm.model = "claude-sonnet-4-6"
        vm.prompt = "/plan"
        await vm.send()
        vm.prompt = "inspect before editing"
        await vm.send()
        // Terminal, not `.completed`: the capture-only double emits no assistant
        // output, so the classifier resolves its silent finish to `.failed`.
        await waitAsync("plan mode reaches runner and completes") {
            runner.interactionModes.contains(.plan) &&
            runner.prompts.last == "inspect before editing" &&
            AgentRunCoordinator.isTerminalThreadStatus(vm.status)
        }

        vm.prompt = "/default"
        await vm.send()
        vm.prompt = "now implement"
        await vm.send()

        await waitAsync("default mode reaches runner") {
            runner.interactionModes.last == .default &&
            runner.prompts.last == "now implement"
        }
        XCTAssertEqual(runner.prompts.last, "now implement",
                       "/default must restore provider runtime behavior without sending a local command as user prompt")
    }

    func test_typingAfterHistoryRecallTurnsRecalledPromptIntoEditableDraft() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        vm.prompt = "/status"
        await vm.send()

        XCTAssertTrue(vm.recallPreviousPrompt())
        vm.prompt += " now"
        vm.promptWasEdited()

        XCTAssertEqual(vm.prompt, "/status now",
                       "after history recall the restored command must remain editable")
        XCTAssertFalse(vm.recallNextPrompt(),
                       "typing after recall must stop history navigation from owning the draft")
        XCTAssertEqual(vm.prompt, "/status now",
                       "history navigation must not clear or replace a recalled prompt after the user edits it")
    }

    func test_promptHistoryPersistsPerWorkspaceAndReloads() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-history-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: FakeProviderRunner(provider: .codex)])
        let store = PromptHistoryStore(db: db)
        let firstWorkspace = WorkspaceID()
        let secondWorkspace = WorkspaceID()
        let first = AgentAppViewModel(workspaceID: firstWorkspace, cwd: tmp,
                                      coordinator: coord, threadRepo: threadRepo,
                                      messageRepo: messageRepo, promptHistoryStore: store)
        let second = AgentAppViewModel(workspaceID: secondWorkspace, cwd: tmp,
                                       coordinator: coord, threadRepo: threadRepo,
                                       messageRepo: messageRepo, promptHistoryStore: store)

        first.createThread(title: "first")
        first.prompt = "/status first"
        await first.send()
        second.createThread(title: "second")
        second.prompt = "/status second"
        await second.send()

        let reloadedFirst = AgentAppViewModel(workspaceID: firstWorkspace, cwd: tmp,
                                              coordinator: coord, threadRepo: threadRepo,
                                              messageRepo: messageRepo, promptHistoryStore: store)
        XCTAssertTrue(reloadedFirst.recallPreviousPrompt())
        XCTAssertEqual(reloadedFirst.prompt, "/status first",
                       "prompt history must persist by workspace and must not leak another workspace's commands")
    }

    func test_promptHistoryEvictsOldestBeyondCap() async throws {
        // WHY: history must retain the newest `PromptHistoryStore.limit` entries
        // and evict the oldest. Limit-relative so a future cap change (it was
        // raised 20 -> 200 in commit 43a126d for :93) does not silently rot this
        // test: send cap+1 commands, then `/status 1` must be the one evicted.
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        let cap = PromptHistoryStore.limit
        for index in 1...(cap + 1) {
            vm.prompt = "/status \(index)"
            await vm.send()
        }

        for _ in 0..<cap {
            XCTAssertTrue(vm.recallPreviousPrompt())
        }
        XCTAssertEqual(vm.prompt, "/status 2",
                       "prompt history must retain the newest \(cap) entries and evict the oldest command")
        XCTAssertTrue(vm.recallPreviousPrompt())
        XCTAssertEqual(vm.prompt, "/status 2",
                       "pressing Up past the retained history must stay on the oldest retained command")
    }

    // MARK: B2 — slash commands

    func test_send_slashCommand_neverBecomesAUserMessageOrRun() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "keep")
        let before = vm.threads.count
        vm.prompt = "/clear"
        await vm.send()
        XCTAssertEqual(vm.prompt, "", "the composer must clear after a slash command")
        XCTAssertFalse(vm.messages.contains { $0.role == .user && $0.content == "/clear" },
                       "/clear must not be sent to the provider as a user message")
        XCTAssertEqual(vm.threads.count, before + 1, "/clear must open a fresh thread")
    }

    func test_slashFork_createsNativeProviderBranchAndCopiesVisibleHistory() async throws {
        let adapter = CapturingProviderAdapter(
            provider: .codex,
            forkThreadResult: "provider-child",
            forkSafety: .keyedIdempotent(compensationSupported: true)
        )
        let (vm, threadRepo) = try makeVM(adapter: adapter)
        vm.providerSnapshots = [crashSafeForkSnapshot()]
        vm.createThread(title: "source")
        let src = vm.selectedThreadId!
        var parent = try XCTUnwrap(try threadRepo.get(id: src))
        parent.providerThreadId = "provider-parent"
        try threadRepo.upsert(parent)
        vm.reloadThreads()
        vm.selectThread(src)
        try? vm.messageRepo.append(AgentMessage(threadId: src, role: .user, content: "q1"))
        try? vm.messageRepo.append(AgentMessage(threadId: src, role: .assistant, content: "a1"))
        XCTAssertTrue(vm.handleSlashCommand("/fork"))
        await waitAsync("provider-native fork") { vm.selectedThreadId != src }
        let forkedId = vm.selectedThreadId!
        XCTAssertNotEqual(forkedId, src, "/fork must select the new thread")
        XCTAssertEqual(vm.threads.first(where: { $0.id == forkedId })?.title, "source (fork)")
        XCTAssertEqual(vm.threads.first(where: { $0.id == forkedId })?.providerThreadId, "provider-child",
                       "the dependent child question must resume the provider-native branch")
        XCTAssertEqual(adapter.forkedThreadIds, [src])
        let copied = (try? vm.messageRepo.list(threadId: forkedId)) ?? []
        XCTAssertEqual(copied.map(\.content), ["q1", "a1"],
                       "the local transcript remains visible while provider context comes from native fork")

        vm.prompt = "dependent child question"
        await vm.send()
        vm.selectThread(src)
        vm.prompt = "parent-only follow-up"
        await vm.send()

        XCTAssertTrue(adapter.sentTurns.contains {
            $0.threadId == forkedId && $0.providerThreadId == "provider-child" && $0.prompt == "dependent child question"
        }, "the first dependent child question must run against the provider-native branch")
        XCTAssertTrue(adapter.sentTurns.contains {
            $0.threadId == src && $0.providerThreadId == "provider-parent" && $0.prompt == "parent-only follow-up"
        }, "later parent work must remain on the original provider session")
    }

    func test_forkCurrentThread_atCapAppliesAndPublishesCommittedVictimBeforeSelectingChild() async throws {
        let adapter = CapturingProviderAdapter(
            provider: .codex,
            forkThreadResult: "provider-child",
            forkSafety: .keyedIdempotent(compensationSupported: true)
        )
        let (vm, threadRepo) = try makeVM(adapter: adapter)
        vm.providerSnapshots = [crashSafeForkSnapshot()]
        vm.createThread(title: "source")
        let parentID = try XCTUnwrap(vm.selectedThreadId)
        var parent = try XCTUnwrap(try threadRepo.get(id: parentID))
        parent.providerThreadId = "provider-parent"
        parent.status = .completed
        parent.updatedAt = Date()
        try threadRepo.upsert(parent)
        var victim = AgentThread(
            workspaceId: vm.workspaceID,
            title: "old victim",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        victim.updatedAt = Date(timeIntervalSince1970: 1)
        try threadRepo.upsert(victim)
        var originalIDs: Set<AgentThreadID> = [parentID, victim.id]
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 2) {
            var thread = AgentThread(
                workspaceId: vm.workspaceID,
                title: "protected \(index)",
                provider: .codex,
                model: "fake-model"
            )
            thread.status = .running
            try threadRepo.upsert(thread)
            originalIDs.insert(thread.id)
        }
        try vm.messageRepo.append(AgentMessage(threadId: parentID, role: .user, content: "copy me"))
        vm.reloadThreads()
        vm.selectThread(parentID)
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        var selectedThreadAtDeletion: AgentThreadID?
        var victimWasAbsentAtDeletion = false
        vm.onThreadLifecycle = { event in
            lifecycleEvents.append(event)
            if case .deleted = event {
                selectedThreadAtDeletion = vm.selectedThreadId
                victimWasAbsentAtDeletion = (try? threadRepo.get(id: victim.id)) == nil
            }
        }
        vm.setReloadThreadListForTesting {
            throw NSError(domain: "AgentAppViewModelTests.forkCapReload", code: 1)
        }

        await vm.forkCurrentThread()
        vm.setReloadThreadListForTesting(nil)

        let childID = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertNotEqual(childID, parentID)
        XCTAssertEqual(
            Set(try threadRepo.list(workspaceId: vm.workspaceID).map(\.id)),
            originalIDs.subtracting([victim.id]).union([childID])
        )
        XCTAssertFalse(vm.threads.contains(where: { $0.id == victim.id }))
        XCTAssertEqual(lifecycleEvents.count, 1)
        guard case .deleted(let deletedIDs)? = lifecycleEvents.first else {
            return XCTFail("the surface must publish the committed retention victim before selection")
        }
        XCTAssertEqual(deletedIDs, [victim.id])
        XCTAssertEqual(selectedThreadAtDeletion, parentID,
                       "the authoritative victim must be applied and published before selecting the child")
        XCTAssertTrue(victimWasAbsentAtDeletion,
                      "the deletion callback must observe the committed victim, never a speculative delete")
        XCTAssertTrue(vm.statusMessage.contains("Could not reload threads"),
                      "a failed post-commit rail read must remain visible while the durable child is selected")
    }

    func test_forkCurrentThread_transcriptWriteFailureLeavesNoChildAndKeepsParentSelected() async throws {
        let adapter = CapturingProviderAdapter(
            provider: .codex,
            forkThreadResult: "provider-child",
            forkSafety: .keyedIdempotent(compensationSupported: true)
        )
        let (vm, threadRepo) = try makeVM(adapter: adapter)
        vm.providerSnapshots = [crashSafeForkSnapshot()]
        vm.createThread(title: "source")
        let parentId = try XCTUnwrap(vm.selectedThreadId)
        var parent = try XCTUnwrap(try threadRepo.get(id: parentId))
        parent.providerThreadId = "provider-parent"
        try threadRepo.upsert(parent)
        try vm.messageRepo.append(AgentMessage(threadId: parentId, role: .user, content: "must remain atomic"))
        var victim = AgentThread(
            workspaceId: vm.workspaceID,
            title: "victim must roll back",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        victim.updatedAt = Date(timeIntervalSince1970: 1)
        try threadRepo.upsert(victim)
        var originalIDs: Set<AgentThreadID> = [parentId, victim.id]
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 2) {
            var protected = AgentThread(
                workspaceId: vm.workspaceID,
                title: "protected \(index)",
                provider: .codex,
                model: "fake-model"
            )
            protected.status = .running
            try threadRepo.upsert(protected)
            originalIDs.insert(protected.id)
        }
        try threadRepo.db.execute("""
            CREATE TRIGGER fail_fork_message_copy
            BEFORE INSERT ON agent_messages
            WHEN NEW.thread_id != '\(parentId.value.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected child message failure'); END;
            """)
        vm.reloadThreads()
        vm.selectThread(parentId)
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        vm.onThreadLifecycle = { lifecycleEvents.append($0) }

        await vm.forkCurrentThread()

        XCTAssertEqual(vm.selectedThreadId, parentId,
                       "a failed local fork transaction must never select a partial child")
        XCTAssertEqual(Set(try threadRepo.list(workspaceId: vm.workspaceID).map(\.id)), originalIDs,
                       "message-copy failure must roll back the child thread instead of leaving a partial rail item")
        XCTAssertNotNil(try threadRepo.get(id: victim.id),
                        "the failed child graph transaction must roll back its tentative cap victim")
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a rolled-back child graph and victim delete must publish no lifecycle")
        XCTAssertTrue(vm.statusMessage.contains("Could not fork thread"),
                      "the parent surface must report the atomic fork failure")
    }

    func test_slashFork_isDisabledForGrokWithoutNegotiatedForkCapability() async throws {
        let adapter = CapturingProviderAdapter(provider: .grok, forkThreadResult: "must-not-fork")
        let (vm, _) = try makeVM(adapter: adapter)
        vm.provider = .grok
        vm.providerInstanceId = "grok-cli"
        vm.model = "grok-4.5"
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok", provider: .grok)],
            binaryPath: "/usr/local/bin/grok"
        )]
        vm.createThread(title: "grok source")
        let sourceId = try XCTUnwrap(vm.selectedThreadId)

        XCTAssertTrue(vm.handleSlashCommand("/fork"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(vm.selectedThreadId, sourceId)
        XCTAssertTrue(adapter.forkedThreadIds.isEmpty,
                      "Grok ACP 0.2.101 must not receive fork until the negotiated capability advertises it")
        XCTAssertTrue(vm.messages.last?.content.contains("does not support provider-side fork") == true)
    }

    func test_slashModel_setsModelOnMatchAndListsOtherwise() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        vm.availableModels = [AgentModelDescriptor(id: "gpt-5", label: "GPT-5", provider: .codex),
                              AgentModelDescriptor(id: "o4", label: "O4 Mini", provider: .codex)]
        vm.handleSlashCommand("/model o4")
        XCTAssertEqual(vm.model, "o4", "/model <arg> must switch to the matching model")
        vm.handleSlashCommand("/model")
        XCTAssertTrue(vm.messages.last?.content.contains("GPT-5") ?? false,
                      "bare /model must list available models as a system note")
        XCTAssertEqual(vm.messages.last?.role, .system)
    }

    func test_slashStatus_appendsSystemSummary() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        vm.provider = .codex
        vm.handleSlashCommand("/status")
        XCTAssertEqual(vm.messages.last?.role, .system)
        XCTAssertTrue(vm.messages.last?.content.contains("provider=") ?? false,
                      "/status must surface the run configuration")
    }

    func test_distillSlashStatus_reachesAgentBecauseDistillOwnsSessionInfoAlias() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        vm.provider = .distill
        XCTAssertFalse(vm.handleSlashCommand("/status"))
    }

    func test_slashUnknown_returnsFalseSoProviderCanHandleIt() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        XCTAssertFalse(vm.handleSlashCommand("/wat"),
                       "unknown slash commands must be left for Codex or Claude instead of becoming local errors")
        XCTAssertFalse(vm.messages.contains { $0.content.contains("Unknown command") })
    }

    // MARK: Side chat / btw / branch (feat/side-chat)

    func test_localSlashCommands_includeSideAndBtw() {
        let local = AgentAppViewModel.localSlashCommands
        XCTAssertTrue(local.contains("/side"), "/side must be a local command")
        XCTAssertTrue(local.contains("/btw"), "/btw must be a local command")
    }

    func test_slashSide_invokesHostSideChatRequestWithInlineText() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.providerSnapshots = [crashSafeForkSnapshot()]
        vm.createThread(title: "source")
        var requested: String?
        vm.onRequestSideChat = { requested = $0 }
        XCTAssertTrue(vm.handleSlashCommand("/side hello side"))
        XCTAssertEqual(requested, "hello side",
                       "/side must hand the inline text to the host (which creates the ephemeral thread)")
    }

    func test_slashSide_refusedInsideSideChat() throws {
        let (vm, threadRepo) = try makeVM()
        vm.provider = .codex
        vm.providerSnapshots = [crashSafeForkSnapshot()]
        vm.createThread(title: "source")
        let parentId = try XCTUnwrap(vm.selectedThreadId)
        let side = AgentThread(
            workspaceId: vm.workspaceID,
            title: "Side · source",
            provider: .codex,
            model: "gpt-5.5",
            parentThreadId: parentId,
            isEphemeral: true
        )
        try threadRepo.upsert(side)
        vm.selectThread(side.id)
        XCTAssertTrue(vm.selectedThreadIsEphemeral)
        var requested = false
        vm.onRequestSideChat = { _ in requested = true }
        XCTAssertTrue(vm.handleSlashCommand("/side"))
        XCTAssertFalse(requested, "/side inside a side chat must not fork another side thread")
        XCTAssertTrue(vm.messages.last?.content.contains("already in a side chat") ?? false)
    }

    func test_slashBtw_handsQuestionToHostAndRefusesEmpty() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        var requested: String?
        vm.onRequestBtw = { requested = $0 }
        XCTAssertTrue(vm.handleSlashCommand("/btw what changed?"))
        XCTAssertEqual(requested, "what changed?")
        requested = nil
        XCTAssertTrue(vm.handleSlashCommand("/btw"))
        XCTAssertNil(requested, "empty /btw must not reach the host")
        XCTAssertTrue(vm.messages.last?.content.contains("/btw") ?? false)
    }

    func test_appendBtwNote_appendsNonPersistedSystemMessage() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        vm.appendBtwNote(question: "q", answer: "a")
        XCTAssertEqual(vm.messages.last?.role, .system)
        XCTAssertTrue(vm.messages.last?.content.contains("BTW · q") ?? false)
        let persisted = (try? vm.messageRepo.list(threadId: tid)) ?? []
        XCTAssertFalse(persisted.contains { $0.content.contains("BTW · q") },
                       "a /btw answer must stay in memory only")
    }

    func test_slashFork_prefersRouterCallbackWhenWired() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        var branched = false
        vm.onForkInNewChat = { _ in branched = true }
        XCTAssertTrue(vm.handleSlashCommand("/fork"))
        XCTAssertTrue(branched, "a wired /fork must route through the host's forkAgentThread callback")
    }

    // MARK: B4 — read/unread, active count, provider-model coherence

    /// Async wait — `Task.sleep` yields the main-actor executor so the
    /// coordinator's observer callbacks (`Task { @MainActor … }`) run.
    /// RunLoop pumping does NOT service Swift concurrency, hence this.
    private func waitAsync(_ desc: String, timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }

    private func runGit(_ args: [String], cwd: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "git failed"
            throw NSError(domain: "AgentAppViewModelTests.git", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func currentProcessFootprintKB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1024)
    }

    private func renderedPNGData<V: View>(for rootView: V, size: NSSize = NSSize(width: 1000, height: 720)) -> Data? {
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: size)
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func test_selectThread_marksItRead() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "a")
        let a = vm.selectedThreadId!
        vm.createThread(title: "b")
        let b = vm.selectedThreadId!
        // Mark a unread out-of-band (as a background completion would).
        var ta = try repo.get(id: a)!; ta.hasUnread = true; try repo.upsert(ta)
        vm.reloadThreads()
        XCTAssertTrue(vm.threads.first { $0.id == a }?.hasUnread ?? false)
        vm.selectThread(b)
        vm.selectThread(a)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(try repo.get(id: a)?.hasUnread, false,
                       "opening a thread must clear its unread flag in the store")
        XCTAssertFalse(vm.threads.first { $0.id == a }?.hasUnread ?? true,
                       "the rail must drop the unread dot without a full requery")
    }

    func test_activeThreadCount_countsRunningThreads() async throws {
        let runner = SlowStartRunner()
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "idle")
        vm.createThread(title: "busy")
        vm.prompt = "keep this run active"
        await vm.send()

        XCTAssertEqual(vm.activeThreadCount, 1, "only threads with a real tracked run are active")
        vm.stop()
    }

    func test_chromeBusy_ignoresStaleLocalRunningStatusWithoutRunningWork() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "completed")
        let id = try XCTUnwrap(vm.selectedThreadId)
        var thread = try XCTUnwrap(repo.get(id: id))
        thread.status = .completed
        try repo.upsert(thread)
        vm.reloadThreads()
        vm.status = .running

        XCTAssertFalse(vm.hasRunningWorkForChrome,
                       "tab/sidebar spinners must reflect actual running work, not a stale local status after the selected thread completed")
    }

    func test_loadModels_keepsModelValidForProvider() async throws {
        // Auto-routing update: setProvider no longer clears the model — it
        // immediately resolves the provider's preferred model (last-used →
        // built-in default → first listed) so the composer never shows an
        // empty or foreign model while the async list loads.
        let (vm, _) = try makeVM()
        vm.providerSnapshots = []
        vm.setProvider(.codex)
        XCTAssertEqual(vm.model, AgentDefaultModelSelection.codexBuiltInDefault,
                       "a provider switch resolves the built-in default before the async load")
        await vm.loadModels()
        if !vm.availableModels.isEmpty {
            XCTAssertTrue(vm.availableModels.contains { $0.id == vm.model },
                          "a provider switch must leave a model valid for that provider")
        }
    }

    func test_providerSwitchClearsStaleModelBeforeAsyncLoad() throws {
        let (vm, _) = try makeVM()
        vm.providerSnapshots = []
        vm.provider = .codex
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        vm.model = "gpt-5.5"

        vm.setProvider(.claude)

        XCTAssertEqual(vm.provider, .claude)
        XCTAssertEqual(vm.availableModels, [],
                       "macOS Source changes must clear stale Codex model rows immediately while Claude models load")
        XCTAssertEqual(vm.model, "",
                       "macOS must not keep sending the old Codex model after the user switches Source to Claude")
    }

    func test_providerSwitchToGrokClearsStaleCodexAndClaudeModels() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        vm.model = "gpt-5.5"

        vm.setProvider(.grok)

        XCTAssertEqual(vm.provider, .grok)
        XCTAssertEqual(vm.providerInstanceId, AgentProvider.grok.rawValue)
        XCTAssertEqual(vm.availableModels, [],
                       "macOS Source→Grok must clear stale Codex model rows while Grok models load")
        XCTAssertEqual(vm.model, "",
                       "macOS must not keep sending a Codex model id after Source switches to Grok")

        vm.provider = .claude
        vm.availableModels = [
            AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)
        ]
        vm.model = "claude-sonnet-4-6"
        vm.setProvider(.grok)

        XCTAssertEqual(vm.provider, .grok)
        XCTAssertEqual(vm.availableModels, [])
        XCTAssertEqual(vm.model, "",
                       "macOS must not keep sending a Claude model id after Source switches to Grok")
    }

    func test_sourceAlwaysResolvesToASelectedSnapshotId() throws {
        let (vm, _) = try makeVM()
        // Simulate the common mismatch: thread/default stores "codex" while
        // host snapshots advertise "codex-cli".
        vm.provider = .codex
        vm.providerInstanceId = "codex"
        let snapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: []
            ),
            AgentProviderSnapshot(
                id: "claude-cli",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
                slashCommands: []
            ),
            AgentProviderSnapshot(
                id: "grok-cli",
                provider: .grok,
                driverKind: .grokCLI,
                displayName: "Grok",
                accentColor: "#1DA1F2",
                continuationGroup: "xai-grok",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
                slashCommands: []
            )
        ]
        // applyProviderSnapshots is private; load through the public snapshot path
        // used by the UI by setting snapshots and re-applying via setProviderInstance
        // after remapping: first set snapshots, then use setProvider which remaps.
        vm.providerSnapshots = snapshots
        // Force remap the way applyProviderSnapshots does when id is stale:
        // setProvider on current provider should bind to the real snapshot id.
        vm.setProvider(.codex)

        XCTAssertEqual(vm.providerInstanceId, "codex-cli",
                       "Source must bind to a real snapshot id so the menu can mark one row")
        XCTAssertEqual(vm.selectedProviderSnapshot?.id, "codex-cli")
        XCTAssertEqual(vm.selectedProviderSnapshot?.provider, .codex)
        // Exactly one Source is selected for the checkmark.
        let selectedCount = snapshots.filter { $0.id == vm.selectedProviderSnapshot?.id }.count
        XCTAssertEqual(selectedCount, 1, "exactly one Source must be marked in the picker")

        vm.setProvider(.grok)
        XCTAssertEqual(vm.providerInstanceId, "grok-cli")
        XCTAssertEqual(vm.selectedProviderSnapshot?.displayName, "Grok")
        XCTAssertEqual(vm.model, "grok-4.5")
    }

    func test_providerInstanceSwitchToGrokReplacesForeignModels() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.providerInstanceId = "codex-cli"
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        vm.model = "gpt-5.5"
        let grokModels = [
            AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok, supportsReasoning: true)
        ]
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: []
            ),
            AgentProviderSnapshot(
                id: "grok-cli",
                provider: .grok,
                driverKind: .grokCLI,
                displayName: "Grok",
                accentColor: "#1DA1F2",
                continuationGroup: "xai-grok",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: grokModels,
                slashCommands: []
            )
        ]

        vm.setProviderInstance("grok-cli")

        XCTAssertEqual(vm.provider, .grok)
        XCTAssertEqual(vm.providerInstanceId, "grok-cli")
        XCTAssertEqual(vm.availableModels.map(\.id), ["grok-4.5"],
                       "instance switch to Grok must replace Codex model rows with Grok snapshot models")
        XCTAssertEqual(vm.model, "grok-4.5",
                       "foreign Codex model id must be replaced by the first Grok model after instance switch")
    }

    func test_providerInstancePickerCannotShowClaudeSourceWithCodexModels() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.providerInstanceId = "codex-cli"
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        vm.model = "gpt-5.5"
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                authenticated: true,
                accountLabel: "codex@example.com",
                accountAuthMethod: "codex",
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: []
            ),
            AgentProviderSnapshot(
                id: "claude-cli",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                authenticated: true,
                accountLabel: "claude@example.com",
                accountAuthMethod: "claude.ai",
                models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
                slashCommands: []
            )
        ]

        // The Source picker row calls setProviderInstance (AgentAppSurface
        // :9484); a raw property write is not a product path.
        vm.setProviderInstance("claude-cli")

        XCTAssertEqual(vm.selectedProviderSnapshot?.provider, .claude)
        XCTAssertEqual(vm.modelOptionsForSelectedProvider.map(\.provider), [.claude],
                       "the model menu must follow the selected Source snapshot immediately; otherwise the user sees Claude with Codex GPT models until changing Source twice")
        XCTAssertFalse(vm.modelOptionsForSelectedProvider.contains { $0.id.hasPrefix("gpt-") },
                       "the model menu must not keep Codex GPT rows after the selected Source snapshot is Claude")
    }

    func test_DistillModelSwitchClearsUnsupportedMainEffortAndPreservesChoiceWhileLoading() throws {
        let (vm, repo) = try makeVM()
        vm.provider = .distill
        vm.availableModels = [
            AgentModelDescriptor(id: "previous", label: "Previous", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: [.medium, .high]),
            AgentModelDescriptor(id: "deepseek-v4.1-flash", label: "DeepSeek V4.1 Flash", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: [.low, .high, .max])
        ]
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: vm.availableModels,
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp",
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )]
        vm.providerInstanceId = "distill-acp"
        vm.createThread(title: "Distill Main effort")
        let threadID = try XCTUnwrap(vm.selectedThreadId)
        vm.model = "previous"
        vm.distillMainEffortSelection = .fixed(.medium)

        vm.setModel("deepseek-v4.1-flash")

        XCTAssertEqual(vm.model, "deepseek-v4.1-flash")
        XCTAssertEqual(vm.distillMainEffortSelection, .automatic)
        XCTAssertEqual(try repo.get(id: threadID)?.modelSelection.modelId, "deepseek-v4.1-flash")
        XCTAssertEqual(try repo.get(id: threadID)?.modelSelection.distillMainEffortSelection, .automatic)

        vm.distillMainEffortSelection = .fixed(.high)
        vm.normalizeSelectedModelOptions()
        XCTAssertEqual(vm.distillMainEffortSelection, .fixed(.high))
        vm.distillMainEffortSelection = .automatic
        vm.normalizeSelectedModelOptions()
        XCTAssertEqual(vm.distillMainEffortSelection, .automatic)

        vm.distillMainEffortSelection = .fixed(.max)
        vm.providerSnapshots = []
        vm.availableModels = []
        vm.normalizeSelectedModelOptions()
        XCTAssertEqual(vm.distillMainEffortSelection, .fixed(.max), "loading model metadata must not erase an explicit effort")
    }

    func test_modelDescriptorControlsClampIllegalReasoningAndServiceTier() throws {
        let (vm, _) = try makeVM()
        vm.providerSnapshots = []
        vm.provider = .claude
        vm.availableModels = [
            AgentModelDescriptor(id: "haiku", label: "Haiku", provider: .claude, supportsReasoning: false, supportsCustomModel: true),
            AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude, supportsReasoning: true, supportedReasoningEfforts: [.high], supportsCustomModel: true)
        ]

        vm.model = "haiku"
        vm.reasoningEffort = .xhigh
        vm.serviceTier = .fast
        vm.normalizeSelectedModelOptions()

        XCTAssertFalse(vm.supportsReasoningForSelectedModel,
                       "models without thinking support must not render a reasoning picker")
        XCTAssertEqual(vm.reasoningEffort, .medium,
                       "unsupported reasoning selections must be clamped before persistence/send")
        XCTAssertEqual(vm.serviceTier, .auto,
                       "Claude/non-service-tier models must not preserve Codex fast mode")

        vm.setModel("opus")
        vm.setReasoningEffort(.xhigh)

        XCTAssertEqual(vm.supportedReasoningEffortsForSelectedModel, [.high])
        XCTAssertEqual(vm.reasoningEffort, .high,
                       "reasoning controls must use the selected model descriptor, not a global effort list")
    }

    func test_modelDescriptorControlsPreserveCustomModelAndContextWindow() throws {
        let (vm, _) = try makeVM()
        vm.providerSnapshots = []
        vm.provider = .codex
        vm.availableModels = [
            AgentModelDescriptor(id: "", label: "Default", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true, contextWindowTokens: 400_000),
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true, contextWindowTokens: 1_000_000)
        ]

        vm.setCustomModel("gpt-experimental")

        XCTAssertEqual(vm.model, "gpt-experimental",
                       "custom-capable providers must not collapse a user-entered model back to the first known descriptor")
        XCTAssertTrue(vm.supportsCustomModelForSelectedProvider)
        XCTAssertEqual(vm.selectedModelContextWindowLabel, "400k ctx",
                       "custom model selections should inherit the provider custom descriptor's context-window metadata for the UI")
        XCTAssertTrue(vm.supportsServiceTierForSelectedModel,
                      "custom Codex model selections should preserve descriptor-specific service-tier controls")

        vm.availableModels = [
            AgentModelDescriptor(id: "haiku", label: "Haiku", provider: .claude, supportsReasoning: false, supportsCustomModel: false)
        ]
        vm.provider = .claude
        vm.setCustomModel("claude-custom")

        XCTAssertEqual(vm.model, "gpt-experimental",
                       "providers without custom-model support must ignore custom model entry instead of persisting an unsupported id")
    }

    func test_customModelSelectionPersistsForFutureAgentModelMenus() throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-custom-model-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let customStore = AgentCustomModelStore(db: db)
        let models = [
            AgentModelDescriptor(id: "", label: "Default", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.4", label: "GPT-5.4", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.4-mini", label: "GPT-5.4-Mini", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true)
        ]
        let first = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            customModelStore: customStore
        )
        first.availableModels = models

        first.setCustomModel("gpt-5.5-experimental")

        XCTAssertEqual(first.customModelsForSelectedProvider, ["gpt-5.5-experimental"],
                       "the Custom option must save the user-entered model so it appears in later model menus")
        XCTAssertEqual(first.currentModelSelection.customModelId, "gpt-5.5-experimental",
                       "custom selections must be sent as customModelId instead of masquerading as a built-in descriptor")

        let reloaded = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            customModelStore: customStore
        )
        reloaded.availableModels = models

        XCTAssertEqual(reloaded.customModelsForSelectedProvider, ["gpt-5.5-experimental"],
                       "custom model IDs must persist until the user edits or removes them in Settings")
    }

    // MARK: Full-thread message history (replaces the old viewport window)

    func test_selectingThreadLoadsEntireThreadWithBodiesRetained() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "long")
        let tid = vm.selectedThreadId!
        let base = Date(timeIntervalSince1970: 1_000_000)
        let page = AgentAppViewModel.messageHistoryPageLimit
        for i in 0..<page {
            try vm.messageRepo.append(AgentMessage(threadId: tid, role: .user,
                content: "m\(i)", createdAt: base.addingTimeInterval(Double(i))))
        }
        vm.selectThread(tid)
        // selectThread hydrates history via a bounded off-main first-paint page
        // so thread-open never blocks MainActor; await it before asserting.
        // A thread that fits the page still loads every body (no blanking).
        await vm.waitForMessageHistoryLoad()
        XCTAssertEqual(vm.messages.count, page,
                       "a thread that fits the first-paint page loads fully, not a smaller viewport")
        XCTAssertEqual(vm.messages.first?.content, "m0", "oldest message present and ordered first")
        XCTAssertEqual(vm.messages.last?.content, "m\(page - 1)", "newest message present and ordered last")
        XCTAssertTrue(vm.messages.allSatisfy { !$0.content.isEmpty },
                      "every body stays hydrated — no eviction that would change a row's height on scroll")
    }

    func test_revealMessagePagesToExactOlderRunFinalInsteadOfNewestRun() async throws {
        // WHY: Activity targets durable run-message IDs; paging must expose that exact older run,
        // not substitute the newest final from a later run in the same thread.
        let (vm, _) = try makeVM()
        vm.createThread(title: "two runs")
        let threadID = try XCTUnwrap(vm.selectedThreadId)
        let base = Date(timeIntervalSince1970: 2_000_000)
        let olderRun = AgentRunID()
        let newerRun = AgentRunID()
        let olderFinal = AgentMessage(
            id: AgentMessageID(olderRun.value), threadId: threadID, role: .assistant,
            content: "older final", createdAt: base
        )
        try vm.messageRepo.append(olderFinal)
        for index in 0..<(AgentAppViewModel.messageHistoryPageLimit - 1) {
            try vm.messageRepo.append(AgentMessage(
                threadId: threadID, role: .user, content: "between \(index)",
                createdAt: base.addingTimeInterval(Double(index + 1))
            ))
        }
        let newerFinal = AgentMessage(
            id: AgentMessageID(newerRun.value), threadId: threadID, role: .assistant,
            content: "newer final", createdAt: base.addingTimeInterval(30)
        )
        try vm.messageRepo.append(newerFinal)
        vm.selectThread(threadID, markRead: false)

        try await vm.revealMessage(id: olderFinal.id)

        XCTAssertTrue(vm.messages.contains(where: { $0.id == olderFinal.id }))
        XCTAssertEqual(vm.messageScrollTarget?.anchor, "message-\(olderFinal.id.value.uuidString)")
        XCTAssertNotEqual(vm.messageScrollTarget?.anchor, "message-\(newerFinal.id.value.uuidString)")
    }

    func test_revealMessageRejectsSelectionChangedDuringLookup() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "A")
        let threadA = try XCTUnwrap(vm.selectedThreadId)
        let message = AgentMessage(threadId: threadA, role: .user, content: "target")
        try vm.messageRepo.append(message)
        let threadB = AgentThread(workspaceId: vm.workspaceID, title: "B", provider: .codex, model: "gpt-5.5")
        try vm.threadRepo.upsert(threadB)

        let lookupStarted = expectation(description: "lookup paused")
        var releaseLookup: CheckedContinuation<Void, Never>?
        vm.beforeMessageRevealLookupForTesting = {
            lookupStarted.fulfill()
            await withCheckedContinuation { releaseLookup = $0 }
        }
        let reveal = Task { @MainActor in
            try await vm.revealMessage(id: message.id)
        }
        await fulfillment(of: [lookupStarted])
        vm.selectThread(threadB.id, markRead: false)
        releaseLookup?.resume()
        do {
            try await reveal.value
            XCTFail("newer selection must reject stale reveal")
        } catch let error as AgentAppSurfaceMessageRevealError {
            guard case .selectionChanged = error else { return XCTFail("unexpected reveal error: \(error)") }
        }
        XCTAssertEqual(vm.selectedThreadId, threadB.id)
        XCTAssertNil(vm.messageScrollTarget)
    }

    func test_revealMessageRejectsMismatchedExpectedThreadBeforeSelection() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "selected")
        let selected = try XCTUnwrap(vm.selectedThreadId)
        let other = AgentThread(workspaceId: vm.workspaceID, title: "other", provider: .codex, model: "gpt-5.5")
        try vm.threadRepo.upsert(other)
        let message = AgentMessage(threadId: other.id, role: .user, content: "target")
        try vm.messageRepo.append(message)

        do {
            try await vm.revealMessage(id: message.id, expectedThreadID: selected)
            XCTFail("mismatched expected thread must reject reveal")
        } catch let error as AgentAppSurfaceMessageRevealError {
            guard case .messageNotFound(let id) = error else { return XCTFail("unexpected reveal error: \(error)") }
            XCTAssertEqual(id, message.id)
        }
        XCTAssertEqual(vm.selectedThreadId, selected)
        XCTAssertNil(vm.messageScrollTarget)
    }

    func test_revealMessageMissingIDThrowsInsteadOfChoosingNewest() async throws {
        // WHY: deleted Activity targets must report failure, never jump to a plausible but wrong message.
        let (vm, _) = try makeVM()
        vm.createThread(title: "missing target")
        let missingID = AgentMessageID()
        do {
            try await vm.revealMessage(id: missingID)
            XCTFail("missing message must return explicit error")
        } catch let error as AgentAppSurfaceMessageRevealError {
            guard case .messageNotFound(let id) = error else {
                return XCTFail("unexpected reveal error: \(error)")
            }
            XCTAssertEqual(id, missingID)
        }
        XCTAssertNil(vm.messageScrollTarget)
    }

    // MARK: First message page state (pending / failed are not "No messages")

    /// The transcript's empty-placeholder decision, fed from the view model
    /// the way `AgentAppView.timeline` feeds it.
    private func showsEmptyConversation(_ vm: AgentAppViewModel) -> Bool {
        AgentAppView.shouldShowEmptyConversation(
            messagesEmpty: vm.messages.isEmpty,
            turnsEmpty: vm.timeline.turns.isEmpty,
            hasTimelineError: vm.timeline.error != nil,
            isHidden: vm.isHiddenFromSurface,
            messagePageLoadState: vm.messagePageLoadState
        )
    }

    func test_selectThreadKeepsEmptyPlaceholderOffUntilFirstMessagePageLands() async throws {
        // WHY: the selection publishes on the click turn and the page is read
        // off-main afterwards. In that gap `messages` is empty, and painting
        // "No messages" over a thread that has messages tells the user their
        // history is gone.
        let (vm, threadRepo) = try makeVM()
        let thread = AgentThread(
            workspaceId: vm.workspaceID,
            title: "has history",
            provider: .codex,
            model: "gpt-5.5"
        )
        try threadRepo.upsert(thread)
        try vm.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "hello"))

        vm.selectThread(thread.id)

        XCTAssertTrue(vm.messages.isEmpty, "fixture: the page has not landed on the selection turn")
        XCTAssertTrue(vm.timeline.turns.isEmpty, "fixture: nothing else keeps the placeholder off")
        XCTAssertEqual(vm.messagePageLoadState, .pending)
        XCTAssertFalse(
            showsEmptyConversation(vm),
            "an unread first page must not present the thread as empty"
        )

        await vm.waitForMessageHistoryLoad()

        XCTAssertEqual(vm.messagePageLoadState, .idle)
        XCTAssertEqual(vm.messages.map(\.content), ["hello"])
    }

    func test_emptyThreadShowsPlaceholderOnceFirstPageResolves_andSameThreadReloadDoesNotBlinkIt() async throws {
        // WHY: the pending state must end. A thread that really has no
        // messages still says so, and a same-thread reload (soft reselect
        // re-reads an empty thread's page) must not take the placeholder away
        // and bring it back on every host refresh.
        let (vm, threadRepo) = try makeVM()
        let thread = AgentThread(
            workspaceId: vm.workspaceID,
            title: "really empty",
            provider: .codex,
            model: "gpt-5.5"
        )
        try threadRepo.upsert(thread)

        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        await vm.waitForMessageHistoryLoad()

        XCTAssertEqual(vm.messagePageLoadState, .idle)
        XCTAssertTrue(showsEmptyConversation(vm), "a resolved empty page is an empty thread")

        vm.selectThread(thread.id)

        XCTAssertTrue(
            showsEmptyConversation(vm),
            "re-reading the open thread's page must not blink the placeholder"
        )
        await vm.waitForMessageHistoryLoad()
        XCTAssertTrue(showsEmptyConversation(vm))
    }

    func test_rapidThreadSwitchResolvesPageStateForTheWinningThread() async throws {
        // WHY: latest wins. The cancelled page load of A must neither leave B
        // stuck in `pending` (B would never show its placeholder) nor land
        // A's rows on B.
        let (vm, threadRepo) = try makeVM()
        let threadA = AgentThread(workspaceId: vm.workspaceID, title: "A", provider: .codex, model: "gpt-5.5")
        let threadB = AgentThread(workspaceId: vm.workspaceID, title: "B", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(threadA)
        try threadRepo.upsert(threadB)
        try vm.messageRepo.append(AgentMessage(threadId: threadA.id, role: .user, content: "from A"))

        vm.selectThread(threadA.id)
        vm.selectThread(threadB.id)

        XCTAssertEqual(vm.messagePageLoadState, .pending)
        await vm.waitForMessageHistoryLoad()

        XCTAssertEqual(vm.selectedThreadId, threadB.id)
        XCTAssertEqual(vm.messagePageLoadState, .idle)
        XCTAssertTrue(vm.messages.isEmpty, "A's cancelled page must not land on B")
        XCTAssertTrue(showsEmptyConversation(vm), "B is empty and its own page resolved")
    }

    func test_failedFirstMessagePageShowsRetryBanner_notEmptyConversation() async throws {
        // WHY: the page read used `try?`, so a thrown SQLite error became
        // zero rows and the thread read "No messages". An unreadable thread
        // is not an empty one, and an error is never hidden.
        let (vm, threadRepo) = try makeVM()
        let thread = AgentThread(
            workspaceId: vm.workspaceID,
            title: "unreadable",
            provider: .codex,
            model: "gpt-5.5"
        )
        try threadRepo.upsert(thread)
        try vm.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "hello"))
        // A real read failure, not a mock: the message table stops resolving.
        try vm.messageRepo.db.execute("ALTER TABLE agent_messages RENAME TO agent_messages_unreadable;")

        vm.selectThread(thread.id)
        await vm.waitForMessageHistoryLoad()

        XCTAssertTrue(vm.messages.isEmpty, "fixture: the failed read delivered no rows")
        let failure = try XCTUnwrap(
            vm.messagePageLoadFailureMessage,
            "a thrown page read must reach the banner"
        )
        XCTAssertTrue(failure.hasPrefix("Could not load messages: "), failure)
        XCTAssertFalse(
            showsEmptyConversation(vm),
            "a failed read must not present the thread as empty"
        )

        try vm.messageRepo.db.execute("ALTER TABLE agent_messages_unreadable RENAME TO agent_messages;")
        vm.retryMessagePageLoad()

        XCTAssertEqual(vm.messagePageLoadState, .pending)
        await vm.waitForMessageHistoryLoad()

        XCTAssertEqual(vm.messagePageLoadState, .idle)
        XCTAssertEqual(
            vm.messages.map(\.content),
            ["hello"],
            "Retry must load the page that failed"
        )
    }

    func test_failedPageStripHasNoDismiss_becauseHidingItLeftABlankThreadWithNoRetry() throws {
        // WHY: the failed-read strip carries the only Retry. With an x, one
        // click left a blank transcript: no error, no "No messages", no
        // recovery. On a Bot Desk a second click on the open thread does not
        // re-read it, so the thread stayed blank. The shared strip therefore
        // draws its x only when the owner passes a dismiss, and this mount
        // passes none.
        let surfaces = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Surfaces")
        let source = try String(
            contentsOf: surfaces.appendingPathComponent("AgentAppSurface.swift"), encoding: .utf8
        )
        let mountStart = try XCTUnwrap(source.range(of: "if let failure = vm.messagePageLoadFailureMessage {"))
        let mountEnd = try XCTUnwrap(source.range(of: "systemStatusStrip", range: mountStart.upperBound..<source.endIndex))
        let mount = String(source[mountStart.lowerBound..<mountEnd.lowerBound])
        XCTAssertTrue(mount.contains("identifier: \"agent.messages.loadFailed\""))
        XCTAssertTrue(mount.contains("onRetry: { vm.retryMessagePageLoad() }"))
        XCTAssertFalse(mount.contains("onDismiss"), "the failed read must stay on screen until Retry succeeds")

        let chrome = try String(
            contentsOf: surfaces.appendingPathComponent("AgentChatSharedChrome.swift"), encoding: .utf8
        )
        let stripStart = try XCTUnwrap(chrome.range(of: "public struct AgentChatErrorStrip"))
        let dismissLabel = try XCTUnwrap(chrome.range(
            of: ".accessibilityLabel(\"Dismiss error\")",
            range: stripStart.upperBound..<chrome.endIndex
        ))
        let strip = String(chrome[stripStart.lowerBound..<dismissLabel.lowerBound])
        XCTAssertTrue(strip.contains("if let onDismiss {"), "no handler, no x")
    }

    func test_restoredTabHoldsPagePendingUntilItsThreadOpens_becauseNoMessagesFlashedOverARestoredThread() throws {
        // WHY: a restored tab selects its thread only after the rail is read
        // off the main actor. Until then nothing is selected, the state was
        // `idle`, and "No messages" painted over a thread that has history.
        // If the thread is gone, or the user opened another one meanwhile,
        // the state must not stay `pending` (a real empty composer would
        // never show its placeholder) and must not overwrite that other
        // thread's own `failed`. That branch does not run under XCTest (the
        // init takes the same-stack path here), so this is a source pin.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "let pendingInitialThreadId = initialThreadId"))
        let end = try XCTUnwrap(source.range(of: "loadGitBranch()", range: start.upperBound..<source.endIndex))
        let restore = String(source[start.lowerBound..<end.lowerBound])
        let hold = try XCTUnwrap(
            restore.range(of: "if pendingInitialThreadId != nil { messagePageLoadState = .pending }")
        )
        let railRead = try XCTUnwrap(restore.range(of: "await self.loadRailSnapshotOffMainActor()"))
        XCTAssertLessThan(hold.lowerBound, railRead.lowerBound, "pending is set on the turn the tab is built")
        let open = try XCTUnwrap(restore.range(of: "self.selectThread(pendingInitialThreadId)"))
        let release = try XCTUnwrap(
            restore.range(of: "if self.selectedThreadId == nil { self.messagePageLoadState = .idle }"),
            "only an unopened tab is released to idle"
        )
        XCTAssertLessThan(open.lowerBound, release.lowerBound)
    }

    func test_emptyConversationKeepsSideChatAndEmbeddingCopy_becauseTwoChangesMeetInThisView() throws {
        // WHY: a side chat shows its own empty state, and every other thread
        // shows the shared DSEmptyState with the embedding's copy (a Bot desk
        // says "Message <bot>"). Losing the first hides what a side chat is;
        // losing the second puts "Start a new agent run." on a Bot desk.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var emptyConversation: some View {"))
        let end = try XCTUnwrap(source.range(
            of: "private var sideChatEmptyConversation: some View {",
            range: start.upperBound..<source.endIndex
        ))
        let view = String(source[start.lowerBound..<end.lowerBound])
        let sideChat = try XCTUnwrap(view.range(of: "if vm.selectedThreadIsEphemeral {"))
        let shared = try XCTUnwrap(view.range(of: "AgentNewConversationEmptyState("))
        XCTAssertLessThan(sideChat.lowerBound, shared.lowerBound, "a side chat is asked first")
        XCTAssertTrue(view.contains("sideChatEmptyConversation"))
        XCTAssertTrue(view.contains("title: vm.embedding?.emptyConversationTitle ?? \"No messages\""))
        XCTAssertTrue(view.contains("subtitle: vm.embedding?.emptyConversationSubtitle ?? \"Start a new agent run.\""))
        // WHY: the side chat subtitle is the only place that says a side chat
        // is temporary. Hand-drawn it was textTertiary (4.06:1 on bg, see
        // DSContrastTests); the shared component keeps it at textSecondary.
        let stripStart = try XCTUnwrap(source.range(
            of: "private var sideChatParentStatusStrip: some View {",
            range: end.upperBound..<source.endIndex
        ))
        let sideChatBody = String(source[end.lowerBound..<stripStart.lowerBound])
        XCTAssertTrue(sideChatBody.contains("DSEmptyState("))
        XCTAssertTrue(sideChatBody.contains("Side chats are temporary and disappear when you close the app."))
        XCTAssertFalse(sideChatBody.contains("textTertiary"))
        // "Parent thread running / idle" is status the owner reads, not decoration.
        let statusStart = try XCTUnwrap(source.range(
            of: "Text(running ? \"Parent thread running\" : \"Parent thread idle\")",
            range: stripStart.upperBound..<source.endIndex
        ))
        let statusEnd = try XCTUnwrap(source.range(
            of: "Spacer(minLength: 0)",
            range: statusStart.upperBound..<source.endIndex
        ))
        let status = String(source[statusStart.lowerBound..<statusEnd.lowerBound])
        XCTAssertTrue(status.contains(".foregroundColor(DS.Palette.textSecondary)"))
        XCTAssertFalse(status.contains("textTertiary"))
    }

    func test_branchInNewChatRequiresTheHostCallback_becauseTheOwningSurfaceMustOpenTheBranch() throws {
        // WHY: the reply draws "Branch in new chat" whenever onBranch is not
        // nil. Only Agent App tabs get onForkInNewChat from the router; a Bot
        // desk or group room embeds this view without it, so an always
        // present closure drew a button that did nothing on every reply.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "onBranch: vm.onForkInNewChat == nil ? nil : { vm.onForkInNewChat?(").count - 1, 3)
        XCTAssertFalse(source.contains("onBranch: {"), "an unconditional closure shows the button on a Bot desk")
    }

    func test_truncatedBranchKeepsATooltipAndEarlierHistoryRevealIsReadable_becauseBothAreInformationNotDecoration() throws {
        // WHY: the header branch is cut in the middle to stay on one line, and
        // it is drawn nowhere else, so without a tooltip a long branch cannot
        // be read at all. "Earlier in this thread · show N more" is 11pt text
        // on a control that opens hidden history; textTertiary is 3.88:1 on
        // its fill, textSecondary 7.39:1.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let branchStart = try XCTUnwrap(source.range(of: "Text(vm.gitBranch ?? \"no branch\")"))
        let branchEnd = try XCTUnwrap(source.range(
            of: "if let context = vm.contextHealthMessage",
            range: branchStart.upperBound..<source.endIndex
        ))
        let branch = String(source[branchStart.lowerBound..<branchEnd.lowerBound])
        XCTAssertTrue(branch.contains(".truncationMode(.middle)"))
        XCTAssertTrue(branch.contains(".help(vm.gitBranch ?? \"no branch\")"))

        let revealStart = try XCTUnwrap(source.range(of: "Text(Self.hiddenTranscriptRevealLabel("))
        let revealEnd = try XCTUnwrap(source.range(of: ".lineLimit(1)", range: revealStart.upperBound..<source.endIndex))
        let reveal = String(source[revealStart.lowerBound..<revealEnd.lowerBound])
        XCTAssertTrue(reveal.contains(".foregroundColor(DS.Palette.textSecondary)"), reveal)
        XCTAssertFalse(reveal.contains("textTertiary"), reveal)
    }

    func test_applyBodyBudgetBlanksOldestBodiesOnPathologicalThread() {
        let tid = AgentThreadID()
        let base = Date(timeIntervalSince1970: 1)
        let rows = (0..<5).map { i in
            AgentMessage(threadId: tid, role: .user,
                         content: String(repeating: "x", count: 10),
                         createdAt: base.addingTimeInterval(Double(i)))
        }
        // 5 x 10 bytes = 50 > budget 25 -> blank oldest until <= 25 (blank 3 -> 20 bytes).
        let (out, blanked) = AgentAppViewModel.applyBodyBudget(rows, budget: 25)
        XCTAssertEqual(blanked, 3, "memory safety-valve blanks oldest bodies until total <= budget")
        XCTAssertEqual(out.prefix(3).map(\.content), ["", "", ""], "oldest bodies blanked first")
        XCTAssertEqual(out.suffix(2).map(\.content).filter { $0.count == 10 }.count, 2,
                       "newest bodies are retained in full — the user lands at the bottom")
    }

    func test_applyBodyBudgetKeepsEverythingForANormalThread() {
        let tid = AgentThreadID()
        let rows = (0..<3).map { _ in AgentMessage(threadId: tid, role: .user, content: "hi") }
        let (out, blanked) = AgentAppViewModel.applyBodyBudget(rows, budget: 1_000_000)
        XCTAssertEqual(blanked, 0, "a normal thread loads in full with nothing blanked")
        XCTAssertEqual(out.map(\.content), ["hi", "hi", "hi"])
    }

    private func startedItems(_ n: Int) -> [AssistantEvent] {
        (0..<n).map { .itemStarted(item: AssistantItem(id: "i\($0)", turnId: "t\($0)", type: .tool, startedAtMs: Int64($0))) }
    }

    func test_chooseReplayPrefersFullPersistedOverCompactedProviderSnapshot() {
        // The reported "thread cortado": the provider (Codex) thread/read is context-compacted
        // and returns only the recent tail; our persisted stream events are the full record.
        let persisted = startedItems(83)
        let compactedSnapshot = startedItems(20)
        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: compactedSnapshot)
        XCTAssertEqual(AgentAppViewModel.renderableItemCount(chosen), 83,
                       "a context-compacted snapshot must not truncate the reopened thread — show 100% of persisted history")
    }

    func test_chooseReplayUsesSnapshotWhenPersistedIsThinner() {
        // Imported-from-external-session thread: persisted history is thin, the provider has it all.
        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: startedItems(2), snapshot: startedItems(40))
        XCTAssertEqual(AgentAppViewModel.renderableItemCount(chosen), 40,
                       "when persisted history is thinner, the provider snapshot fills it in")
    }

    func test_chooseReplayCarriesHostDistillTruthByUniqueProviderItemIdentity() {
        // WHY: provider item IDs may repeat across turns, while Codex live and
        // thread/read assign different turn IDs and timestamps to the same item.
        // Turn occurrence plus in-turn (id,type) ordinal is the stable identity.
        let persisted: [AssistantEvent] = [
            .turnStarted(turnId: "persisted-first"),
            .itemStarted(item: AssistantItem(id: "shared", turnId: "persisted-first", type: .tool, startedAtMs: 101)),
            .turnStarted(turnId: "persisted-second"),
            .itemStarted(item: AssistantItem(id: "shared", turnId: "persisted-second", type: .tool, startedAtMs: 202)),
            .itemHostMetadata(turnId: "persisted-second", itemId: "shared", distillApplied: true)
        ]
        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "snapshot-first"),
            .itemStarted(item: AssistantItem(id: "extra-first", turnId: "snapshot-first", type: .tool, startedAtMs: 0)),
            .itemStarted(item: AssistantItem(id: "shared", turnId: "snapshot-first", type: .tool, startedAtMs: 1)),
            .turnStarted(turnId: "snapshot-second"),
            .itemStarted(item: AssistantItem(id: "extra-second", turnId: "snapshot-second", type: .tool, startedAtMs: 1)),
            .itemStarted(item: AssistantItem(id: "shared", turnId: "snapshot-second", type: .tool, startedAtMs: 2)),
            .turnStarted(turnId: "snapshot-extra"),
            .itemStarted(item: AssistantItem(id: "extra", turnId: "snapshot-extra", type: .tool, startedAtMs: 3))
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: snapshot)
        let timeline = AgentAppViewModel.timelineByReplaying(chosen)

        XCTAssertNil(timeline.turns[0].items[0].distillApplied,
                     "an extra snapshot item before the match must remain unbadged")
        XCTAssertNil(timeline.turns[0].items[1].distillApplied,
                     "the same itemId in the first turn occurrence must remain unbadged")
        XCTAssertNil(timeline.turns[1].items[0].distillApplied,
                     "an inserted item must not inherit truth by absolute item index")
        XCTAssertEqual(timeline.turns[1].items[1].distillApplied, true,
                       "host truth must follow the matching id/type occurrence inside the paired turn")
        XCTAssertNil(timeline.turns[2].items[0].distillApplied)
    }

    func test_chooseReplayRetainsPersistedHostTruthWhenSnapshotMappingIsAmbiguous() {
        // WHY: a richer provider snapshot may insert or reorder turns. If the
        // paired turn occurrence lacks the attested (id,type), no target is safe.
        let persisted: [AssistantEvent] = [
            .turnStarted(turnId: "persisted"),
            .itemStarted(item: AssistantItem(id: "shared", turnId: "persisted", type: .tool, startedAtMs: 7)),
            .itemHostMetadata(turnId: "persisted", itemId: "shared", distillApplied: true)
        ]
        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "inserted-leading"),
            .itemStarted(item: AssistantItem(id: "other", turnId: "inserted-leading", type: .tool, startedAtMs: 7)),
            .turnStarted(turnId: "reordered-match"),
            .itemStarted(item: AssistantItem(id: "shared", turnId: "reordered-match", type: .tool, startedAtMs: 8))
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: snapshot)
        let timeline = AgentAppViewModel.timelineByReplaying(chosen)

        XCTAssertEqual(chosen, persisted,
                       "ambiguous provider replay must retain the authoritative persisted source")
        XCTAssertEqual(timeline.turns[0].items[0].distillApplied, true)
    }

    func test_chooseReplayRetainsPersistedHostTruthWhenSnapshotMutatesAttestedBytes() {
        // WHY: adapters may retain a raw late delta that the live coordinator
        // rejected after attestation. Reopening must never carry the trusted
        // badge onto that richer but byte-different provider snapshot.
        let persisted: [AssistantEvent] = [
            .turnStarted(turnId: "persisted"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "persisted", type: .tool,
                state: .completed, body: "trusted body", output: "trusted output",
                startedAtMs: 7, finishedAtMs: 8
            )),
            .itemHostMetadata(turnId: "persisted", itemId: "tool", distillApplied: true)
        ]
        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "snapshot"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "snapshot", type: .tool,
                state: .completed, body: "trusted body", output: "trusted output",
                startedAtMs: 7, finishedAtMs: 8
            )),
            .itemDelta(
                itemId: "tool",
                bodyAppend: nil,
                outputAppend: " unsigned late output",
                summary: nil
            ),
            .itemStarted(item: AssistantItem(
                id: "richer", turnId: "snapshot", type: .tool, startedAtMs: 9
            ))
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: snapshot)
        let timeline = AgentAppViewModel.timelineByReplaying(chosen)

        XCTAssertEqual(chosen, persisted,
                       "byte-different provider history must not inherit persisted host truth")
        XCTAssertEqual(timeline.turns[0].items[0].output, "trusted output")
        XCTAssertEqual(timeline.turns[0].items[0].distillApplied, true)
    }

    func test_chooseReplayCountsRawDuplicateStartsBeforeTransferringHostTruth() {
        // WHY: the paint reducer merges duplicate IDs within one turn. Replay
        // correlation must count the raw occurrences first, or an inserted same
        // (id,type) start can be overwritten by trusted-looking bytes and badged.
        let persisted: [AssistantEvent] = [
            .turnStarted(turnId: "persisted"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "persisted", type: .tool,
                state: .completed, body: "trusted body", output: "trusted output",
                startedAtMs: 1, finishedAtMs: 2
            )),
            .itemHostMetadata(turnId: "persisted", itemId: "tool", distillApplied: true)
        ]
        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "snapshot"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "snapshot", type: .tool,
                state: .completed, body: "inserted body", output: "inserted output",
                startedAtMs: 10, finishedAtMs: 11
            )),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "snapshot", type: .tool,
                state: .completed, body: "trusted body", output: "trusted output",
                startedAtMs: 12, finishedAtMs: 13
            ))
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: snapshot)

        XCTAssertEqual(chosen, persisted,
                       "an earlier same-tuple occurrence must shift correlation and fail closed")
    }

    func test_chooseReplayHashesBytesBeforeUICapsWhenPrefixChanges() {
        // WHY: both paint timelines retain only a long output's suffix. Replay
        // trust must hash the full delta stream or a changed evicted prefix can
        // inherit a badge from byte-different provider history.
        let trusted = String(repeating: "a", count: AssistantTimelineState.liveOutputLimit + 1)
        let changed = "b" + trusted.dropFirst()
        let attestation = distillAttestation(body: "", output: trusted)
        let persisted: [AssistantEvent] = [
            .turnStarted(turnId: "persisted"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "persisted", type: .tool,
                body: "", output: nil, startedAtMs: 1
            )),
            .itemDelta(itemId: "tool", bodyAppend: nil, outputAppend: trusted, summary: nil),
            .itemHostMetadata(
                turnId: "persisted", itemId: "tool", distillApplied: true,
                attestation: attestation
            )
        ]
        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "snapshot"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "snapshot", type: .tool,
                body: "", output: nil, startedAtMs: 2
            )),
            .itemDelta(itemId: "tool", bodyAppend: nil, outputAppend: String(changed), summary: nil),
            .itemStarted(item: AssistantItem(
                id: "richer", turnId: "snapshot", type: .tool, startedAtMs: 3
            ))
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: snapshot)

        XCTAssertEqual(chosen, persisted,
                       "a prefix mutation outside the UI suffix must fail closed")
    }

    func test_chooseReplayUsesTerminalAttestationAfterStartRowPruning() throws {
        // WHY: production keeps only 100 stream rows per thread. A long tool can
        // evict its own itemStarted before reopen, so the terminal host event must
        // carry enough bounded proof to recover the badge from provider history.
        let chunks = (0..<101).map { "chunk-\($0);" }
        let output = chunks.joined()
        let attestation = distillAttestation(body: "", output: output)
        var fullPersisted: [AssistantEvent] = [
            .turnStarted(turnId: "persisted"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "persisted", type: .tool,
                body: "", output: nil, startedAtMs: 1
            ))
        ]
        fullPersisted.append(contentsOf: chunks.map {
            .itemDelta(itemId: "tool", bodyAppend: nil, outputAppend: $0, summary: nil)
        })
        fullPersisted.append(.itemHostMetadata(
            turnId: "persisted", itemId: "tool", distillApplied: true,
            attestation: attestation
        ))
        fullPersisted.append(.turnCompleted(turnId: "persisted", finalMessage: nil))
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let thread = AgentThread(title: "pruned receipt", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "m",
            status: .completed
        )
        let runs = AgentRunRepository(db: db)
        try runs.upsert(run)
        let encoder = JSONEncoder()
        for (offset, event) in fullPersisted.enumerated() {
            try runs.appendStreamEvent(
                runId: run.id,
                seq: offset + 1,
                kind: event.debugDescription,
                payloadJSON: String(decoding: try encoder.encode(event), as: UTF8.self)
            )
        }
        let retained = try runs.listLatestStreamEvents(
            threadId: thread.id,
            limit: 500,
            strictDecoding: true
        )
        XCTAssertEqual(retained.count, 100, "production persistence must apply its real row cap")
        XCTAssertFalse(retained.contains { if case .itemStarted = $0 { return true }; return false },
                       "the regression requires itemStarted to be physically evicted")
        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "snapshot"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "snapshot", type: .tool,
                state: .completed, body: "", output: output,
                startedAtMs: 2, finishedAtMs: 3
            ))
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: retained, snapshot: snapshot)
        let timeline = AgentAppViewModel.timelineByReplaying(chosen)

        XCTAssertEqual(timeline.turns[0].items[0].distillApplied, true,
                       "a retained terminal proof must survive itemStarted eviction")
    }

    func test_chooseReplayCountsRepeatedTurnIDsAsSeparateOccurrences() {
        // WHY: paint deduplicates provider turn IDs, but replay identity must not.
        // A repeated ID cannot move second-turn trust onto the first occurrence.
        let attestation = distillAttestation(body: "trusted", output: nil)
        let persisted: [AssistantEvent] = [
            .turnStarted(turnId: "same"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "same", type: .tool,
                body: "first", startedAtMs: 1
            )),
            .turnStarted(turnId: "same"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "same", type: .tool,
                body: "trusted", startedAtMs: 2
            )),
            .itemHostMetadata(
                turnId: "same", itemId: "tool", distillApplied: true,
                attestation: attestation
            )
        ]
        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "same"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "same", type: .tool,
                body: "first", startedAtMs: 10
            )),
            .turnStarted(turnId: "same"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "same", type: .tool,
                body: "trusted", startedAtMs: 11
            ))
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: snapshot)
        let timeline = AgentAppViewModel.timelineByReplaying(chosen)

        XCTAssertEqual(timeline.turns[0].items[0].body, "trusted")
        XCTAssertEqual(timeline.turns[0].items[0].distillApplied, true)
    }

    func test_chooseReplayPinsFirstAttestedRepeatedTurnOccurrence() {
        // WHY: the paint reducer collapses repeated turn IDs. Host proof for the
        // first raw turn must land before the second occurrence can replace it.
        let attestation = distillAttestation(body: "first trusted", output: nil)
        let persisted: [AssistantEvent] = [
            .turnStarted(turnId: "same"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "same", type: .tool,
                body: "first trusted", startedAtMs: 1
            )),
            .itemHostMetadata(
                turnId: "same", itemId: "tool", distillApplied: true,
                attestation: attestation
            ),
            .turnStarted(turnId: "same"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "same", type: .tool,
                body: "later untrusted", startedAtMs: 2
            ))
        ]
        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "same"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "same", type: .tool,
                body: "first trusted", startedAtMs: 10
            )),
            .turnStarted(turnId: "same"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "same", type: .tool,
                body: "later untrusted", startedAtMs: 11
            )),
            .itemStarted(item: AssistantItem(
                id: "extra", turnId: "same", type: .tool,
                body: "richer snapshot", startedAtMs: 12
            ))
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: snapshot)
        let timeline = AgentAppViewModel.timelineByReplaying(chosen)

        XCTAssertEqual(timeline.turns[0].items[0].body, "first trusted",
                       "first-occurrence proof must freeze its bytes before the repeated turn")
        XCTAssertEqual(timeline.turns[0].items[0].distillApplied, true)
        XCTAssertEqual(timeline.turns[0].items[1].body, "richer snapshot")
    }

    func test_chooseReplayPinsFirstAttestedDuplicateItemOccurrenceWithinTurn() {
        // WHY: duplicate provider item IDs are merged for paint. The metadata
        // insertion point, not a newest-by-ID lookup, must select the raw item.
        let attestation = distillAttestation(body: "first trusted", output: nil)
        let persisted: [AssistantEvent] = [
            .turnStarted(turnId: "turn"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "turn", type: .tool,
                body: "first trusted", startedAtMs: 1
            )),
            .itemHostMetadata(
                turnId: "turn", itemId: "tool", distillApplied: true,
                attestation: attestation
            ),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "turn", type: .tool,
                body: "later untrusted", startedAtMs: 2
            ))
        ]
        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "turn"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "turn", type: .tool,
                body: "first trusted", startedAtMs: 10
            )),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "turn", type: .tool,
                body: "later untrusted", startedAtMs: 11
            )),
            .itemStarted(item: AssistantItem(
                id: "extra", turnId: "turn", type: .tool,
                body: "richer snapshot", startedAtMs: 12
            ))
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: snapshot)
        let timeline = AgentAppViewModel.timelineByReplaying(chosen)

        XCTAssertEqual(timeline.turns[0].items[0].body, "first trusted",
                       "first duplicate proof must freeze that occurrence before replacement")
        XCTAssertEqual(timeline.turns[0].items[0].distillApplied, true)
        XCTAssertEqual(timeline.turns[0].items[1].body, "richer snapshot")
    }

    func test_chooseReplayUsesDurableAttestationAfterLaterRowsPruneMetadata() throws {
        // WHY: a completed tool can be followed by hundreds of later events.
        // Its host proof must survive outside the 100-row rolling window and be
        // available through both macOS replay and bounded iOS thread reads.
        let output = "durably distilled output"
        let attestation = distillAttestation(body: "", output: output)
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let thread = AgentThread(title: "durable receipt", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .completed)
        let runs = AgentRunRepository(db: db)
        try runs.upsert(run)
        let events: [AssistantEvent] = [
            .turnStarted(turnId: "persisted"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "persisted", type: .tool,
                state: .completed, body: "", output: output,
                startedAtMs: 1, finishedAtMs: 2
            )),
            .itemHostMetadata(
                turnId: "persisted", itemId: "tool", distillApplied: true,
                attestation: attestation
            )
        ] + (0..<101).map { .turnStarted(turnId: "later-\($0)") }
        let encoder = JSONEncoder()
        for (offset, event) in events.enumerated() {
            try runs.appendStreamEvent(
                runId: run.id,
                seq: offset + 1,
                kind: event.debugDescription,
                payloadJSON: String(decoding: try encoder.encode(event), as: UTF8.self)
            )
        }

        let rollingMetadata = try db.prepare("""
            SELECT COUNT(*) FROM agent_stream_events
            WHERE run_id = ? AND event_kind LIKE 'itemHostMetadata(%';
            """)
        try rollingMetadata.bind(1, run.id.value.uuidString)
        XCTAssertTrue(try rollingMetadata.step())
        XCTAssertEqual(rollingMetadata.columnInt64(0), 0,
                       "the regression requires the original metadata row to age out")
        let durableCount = try db.prepare("""
            SELECT COUNT(*) FROM agent_item_host_attestations WHERE run_id = ?;
            """)
        try durableCount.bind(1, run.id.value.uuidString)
        XCTAssertTrue(try durableCount.step())
        XCTAssertEqual(durableCount.columnInt64(0), 1)

        let retained = try runs.listLatestStreamEvents(
            threadId: thread.id,
            limit: 500,
            strictDecoding: true
        )
        XCTAssertTrue(retained.contains {
            if case .itemHostMetadata(_, "tool", true, let proof) = $0 {
                return proof == attestation
            }
            return false
        }, "macOS replay must union durable host proof back into chronology")
        let mobile = try runs.listLatestStreamEventsForThreadReadV1(
            threadId: thread.id,
            eventLimit: 200,
            maxPayloadBytes: 1 * 1_024 * 1_024,
            strictDecoding: true
        )
        XCTAssertTrue(mobile.events.contains {
            if case .itemHostMetadata(_, "tool", true, let proof) = $0 {
                return proof == attestation
            }
            return false
        }, "bounded mirror replay must use the same durable proof source")

        let snapshot: [AssistantEvent] = [
            .turnStarted(turnId: "snapshot"),
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "snapshot", type: .tool,
                state: .completed, body: "", output: output,
                startedAtMs: 10, finishedAtMs: 11
            ))
        ]
        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: retained, snapshot: snapshot)
        let timeline = AgentAppViewModel.timelineByReplaying(chosen)
        XCTAssertEqual(timeline.turns[0].items[0].distillApplied, true,
                       "reopen must recover the badge after later rows prune metadata")
    }

    func test_chooseReplayRejectsProviderOwnedHostMetadata() {
        // WHY: snapshot/parser events are provider-owned and may not mint the
        // host-only badge even when local persisted history is empty.
        let snapshot: [AssistantEvent] = [
            .itemStarted(item: AssistantItem(
                id: "tool", turnId: "snapshot", type: .tool, startedAtMs: 1
            )),
            .itemHostMetadata(turnId: "snapshot", itemId: "tool", distillApplied: true)
        ]

        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: [], snapshot: snapshot)
        let timeline = AgentAppViewModel.timelineByReplaying(chosen)

        XCTAssertNil(timeline.turns[0].items[0].distillApplied)
    }

    func test_chooseReplayFallsBackToPersistedWhenNoSnapshot() {
        let persisted = startedItems(5)
        XCTAssertEqual(AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: nil).count, 5)
    }

    /// WHY: opening an old completed thread used to wipe `timeline = []` then
    /// re-apply the same (or equivalent) events when the provider snapshot
    /// landed — SwiftUI rematerialized the transcript 2–3 times (blink).
    func test_shouldSkipDeferredTimelineRebuild_whenSnapshotMatchesFirstPaint() {
        let local = startedItems(12) + [
            .turnCompleted(turnId: "t11", finalMessage: "done")
        ]
        XCTAssertTrue(
            AgentAppViewModel.shouldSkipDeferredTimelineRebuild(
                firstPaintEvents: local,
                deferredChosenEvents: local
            ),
            "identical local + deferred sources must not trigger a second full rebuild"
        )
        let thinnerSnapshot = startedItems(4)
        XCTAssertFalse(
            AgentAppViewModel.shouldSkipDeferredTimelineRebuild(
                firstPaintEvents: local,
                deferredChosenEvents: thinnerSnapshot
            ),
            "a thinner deferred stream must not be treated as the same paint"
        )
        let richer = startedItems(20)
        XCTAssertFalse(
            AgentAppViewModel.shouldSkipDeferredTimelineRebuild(
                firstPaintEvents: local,
                deferredChosenEvents: richer
            ),
            "a richer deferred stream must rebuild so recovery still lands"
        )
    }

    /// WHY: equal-count provider snapshots still differed in event identity from
    /// local stream history, so fingerprint skip failed and every open rebuilt.
    /// Gate requires substantial richness once local already painted text.
    func test_shouldApplyDeferredSnapshotReplay_onlyWhenStrictlyRicher() {
        XCTAssertFalse(
            AgentAppViewModel.shouldApplyDeferredSnapshotReplay(
                firstPaintItemCount: 40,
                deferredSnapshotItemCount: 40
            ),
            "equal item counts must not rebuild (completed-thread multi-blink)"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldApplyDeferredSnapshotReplay(
                firstPaintItemCount: 40,
                deferredSnapshotItemCount: 12
            ),
            "thinner compacted snapshots must not rebuild over full local history"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldApplyDeferredSnapshotReplay(
                firstPaintItemCount: 2,
                deferredSnapshotItemCount: 40
            ),
            "strictly richer snapshot must still recover thin local history"
        )
        // Residual blink: first paint already has a full transcript; provider
        // +1 itemStarted must not wipe/rebuild (user sees text flash again).
        XCTAssertFalse(
            AgentAppViewModel.shouldApplyDeferredSnapshotReplay(
                firstPaintItemCount: 40,
                deferredSnapshotItemCount: 41
            ),
            "micro count noise must not rebuild a completed thread that already has text"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldApplyDeferredSnapshotReplay(
                firstPaintItemCount: 40,
                deferredSnapshotItemCount: 48
            ),
            "substantially richer provider history still recovers missing local turns"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldApplyDeferredSnapshotReplay(
                firstPaintItemCount: 0,
                deferredSnapshotItemCount: 3
            ),
            "empty first paint still accepts any provider recovery"
        )
        // Terminal + painted: never deferred rebuild (user residual multipass).
        XCTAssertFalse(
            AgentAppViewModel.shouldApplyDeferredSnapshotReplay(
                firstPaintItemCount: 10,
                deferredSnapshotItemCount: 200,
                threadIsTerminal: true
            ),
            "completed thread with local text must not multipass-rebuild from provider"
        )
    }

    /// WHY: background provider thread/read after open was the multipass flash on
    /// completed threads that already painted local history.
    func test_shouldFetchProviderSnapshotOnOpen_skipsTerminalWithLocalPaint() {
        XCTAssertFalse(
            AgentAppViewModel.shouldFetchProviderSnapshotOnOpen(
                hasRecoverableContext: true,
                firstPaintItemCount: 0,
                threadStatus: .completed
            ),
            "recoverable interrupted sessions must not auto-read"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldFetchProviderSnapshotOnOpen(
                hasRecoverableContext: false,
                firstPaintItemCount: 12,
                threadStatus: .completed
            ),
            "terminal + painted local history must not start deferred fetch"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldFetchProviderSnapshotOnOpen(
                hasRecoverableContext: false,
                firstPaintItemCount: 0,
                threadStatus: .completed
            ),
            "empty local history still needs provider recovery even if terminal"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldFetchProviderSnapshotOnOpen(
                hasRecoverableContext: false,
                firstPaintItemCount: 5,
                threadStatus: .running
            ),
            "live runs may still snapshot for recovery"
        )
    }

    /// WHY: soft reselect reassigned identical chrome fields and multipass-
    /// churned the open Agent App body on every host refresh / rail re-click.
    func test_shouldAssignIfChanged_onlyWhenValueDiffers() {
        XCTAssertFalse(
            AgentAppViewModel.shouldAssignIfChanged(current: "m", next: "m"),
            "identical values must not re-publish"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldAssignIfChanged(current: "m", next: "n"),
            "changed values must assign"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldAssignIfChanged(
                current: Optional<String>.none,
                next: Optional<String>.none
            )
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldAssignIfChanged(
                current: Optional<String>.none,
                next: Optional("x")
            )
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldAssignIfChanged(
                current: AgentRunStatus.completed,
                next: .completed
            )
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldAssignIfChanged(
                current: AgentRunStatus.running,
                next: .completed
            )
        )
    }

    /// Soft reselect must not re-fetch the message page when it already shows
    /// this thread — that async messages= swap was a visible multipass flash.
    func test_shouldReloadMessagesOnSoftReselect_onlyWhenListStale() {
        let tid = AgentThreadID()
        let other = AgentThreadID()
        XCTAssertTrue(
            AgentAppViewModel.shouldReloadMessagesOnSoftReselect(
                selectedThreadId: tid,
                messagesThreadIds: []
            )
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldReloadMessagesOnSoftReselect(
                selectedThreadId: tid,
                messagesThreadIds: [tid, tid]
            )
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldReloadMessagesOnSoftReselect(
                selectedThreadId: tid,
                messagesThreadIds: [tid, other]
            )
        )
    }

    /// WHY: soft reselect + 2s poll reassigned identical subagent snapshots,
    /// republishing nested-worker chrome with no state change.
    func test_shouldPublishSubagentActivity_skipsEqualSnapshot() {
        XCTAssertFalse(
            AgentAppViewModel.shouldPublishSubagentActivity(
                current: .empty,
                next: .empty
            ),
            "identical empty snapshot must not re-publish"
        )
        // Different bound forces inequality without inventing activity rows.
        let changed = SubagentActivitySnapshot(
            active: [],
            done: [],
            unknown: [],
            completedBound: SubagentActivityProjection.defaultCompletedBound + 1
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishSubagentActivity(
                current: .empty,
                next: changed
            ),
            "changed snapshot must publish"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldPublishSubagentActivity(
                current: changed,
                next: changed
            ),
            "identical non-empty-bound snapshot must not re-publish"
        )
    }

    /// WHY: soft reselect always reassigned the queue array even when unchanged,
    /// republishing composer queue chrome on every host refresh / rail re-click.
    func test_shouldPublishQueuedMessagesReload_skipsEqualListAndStatus() {
        let tid = AgentThreadID()
        let msg = AgentQueuedMessage(
            id: AgentQueuedMessageID(),
            threadId: tid,
            text: "follow up",
            attachments: [],
            interactionMode: .default,
            position: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldPublishQueuedMessagesReload(
                current: [msg],
                next: [msg],
                currentStatus: nil,
                nextStatus: nil
            ),
            "identical queue + status must not re-publish"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishQueuedMessagesReload(
                current: [msg],
                next: [msg],
                currentStatus: nil,
                nextStatus: "busy"
            ),
            "status-only change must publish"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishQueuedMessagesReload(
                current: [],
                next: [msg],
                currentStatus: nil,
                nextStatus: nil
            ),
            "new queue rows must publish"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldPublishQueuedMessagesReload(
                current: [],
                next: [],
                currentStatus: nil,
                nextStatus: nil
            ),
            "empty→empty must not clear/publish again"
        )
    }

    /// WHY: soft reselect always called reloadCheckpoints, re-assigning the same
    /// list and re-selecting the same checkpoint (diff preview multipass publish).
    func test_shouldPublishCheckpointReload_skipsEqualListWithValidSelection() {
        let tid = AgentThreadID()
        let run = AgentRunID()
        let cp = AgentTurnCheckpointSummary(
            threadId: tid,
            runId: run,
            turnId: "t1",
            checkpointTurnCount: 1,
            checkpointRef: "ref",
            status: .ready,
            files: []
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldPublishCheckpointReload(
                current: [cp],
                next: [cp],
                selectedTurnCount: 1
            ),
            "identical checkpoint list with valid selection must not re-publish"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishCheckpointReload(
                current: [cp],
                next: [cp],
                selectedTurnCount: nil
            ),
            "non-empty equal list with no selection still needs default select"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishCheckpointReload(
                current: [],
                next: [cp],
                selectedTurnCount: nil
            ),
            "new checkpoints after a run must publish"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldPublishCheckpointReload(
                current: [],
                next: [],
                selectedTurnCount: nil
            ),
            "empty→empty must not clear/publish again"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishCheckpointReload(
                current: [],
                next: [],
                selectedTurnCount: 3
            ),
            "empty list with stale selection must clear selection"
        )
    }

    /// Mark-read must clear unread without rewriting activity time (rail "now").
    func test_applyingMarkReadPreservingActivity_clearsUnreadOnly() {
        var thread = AgentThread(title: "Old", provider: .claude, model: "m", status: .completed)
        thread.hasUnread = true
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = past
        let marked = AgentAppViewModel.applyingMarkReadPreservingActivity(thread)
        XCTAssertFalse(marked.hasUnread)
        XCTAssertEqual(marked.updatedAt, past, "open/mark-read must not bump rail activity time")
        XCTAssertEqual(thread.updatedAt, past, "input must not be mutated")
        XCTAssertTrue(thread.hasUnread, "input must not be mutated")
    }

    func test_selectThread_sameThreadSoftReselectDoesNotClearTimeline() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "stable")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        // Seed a visible turn so we can detect a wipe.
        vm.timeline.apply(.turnStarted(turnId: "keep-me"))
        vm.timeline.apply(.turnCompleted(turnId: "keep-me", finalMessage: "hello"))
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), ["keep-me"])
        // Same-thread re-select (host refresh / rail re-click).
        vm.selectThread(tid, markRead: false)
        XCTAssertEqual(
            vm.timeline.turns.map(\.turnId),
            ["keep-me"],
            "soft reselect must not wipe an already-painted timeline for the open thread"
        )
        XCTAssertEqual(vm.timeline.latestAssistantMessage, "hello")
    }

    func test_timelineByReplaying_appliesWithoutPartialPublishPath() {
        // Pure builder used for atomic open: one value, fully applied.
        let events: [AssistantEvent] = [
            .turnStarted(turnId: "t1"),
            .itemStarted(item: AssistantItem(id: "i1", turnId: "t1", type: .assistantMessage, body: "hi", startedAtMs: 1)),
            .turnCompleted(turnId: "t1", finalMessage: "hi")
        ]
        let timeline = AgentAppViewModel.timelineByReplaying(events)
        XCTAssertEqual(timeline.turns.count, 1)
        XCTAssertEqual(timeline.latestAssistantMessage, "hi")
    }

    func test_loadWindowClipsHugePersistedMessagesBeforeRendering() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "huge")
        let tid = vm.selectedThreadId!
        try vm.messageRepo.append(AgentMessage(
            threadId: tid,
            role: .assistant,
            content: String(repeating: "x", count: AssistantTimelineState.liveTextLimit + 10)
        ))

        vm.selectThread(tid)
        await vm.waitForMessageHistoryLoad()

        XCTAssertEqual(vm.messages.first?.content.count, AssistantTimelineState.liveTextLimit,
                       "a huge persisted transcript must be clipped before SwiftUI renders it")
    }

    func test_agentAppLongRunStressStaysBoundedAndReleasesRunState() async throws {
        let runner = LongRunStreamRunner(turns: 90, runtimeEvents: 650)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "long stress")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let beforeKB = currentProcessFootprintKB()

        vm.prompt = "exercise a long running agent stream"
        await vm.send()

        await waitAsync("long Agent App stream completes", timeout: 15) {
            vm.status == .completed && vm.timeline.latestAssistantMessage == "LONG_ASSISTANT_89"
        }
        let afterKB = currentProcessFootprintKB()

        XCTAssertEqual(vm.currentRunId, nil,
                       "completed long runs must clear the selected Agent App run id instead of leaving Stop/Working state stuck")
        XCTAssertEqual(vm.runStartedAt, nil,
                       "completed long runs must clear the Working-for timer")
        XCTAssertTrue(vm.coordinator.activeThreadIdsSnapshot().isEmpty,
                      "the coordinator must release active thread handles after a long Agent App run")
        XCTAssertLessThanOrEqual(vm.timeline.turns.count, AssistantTimelineState.liveTurnLimit,
                                 "turns stay under the memory-ceiling backstop")
        XCTAssertEqual(vm.timeline.turns.last?.turnId, "long-turn-89",
                       "the newest long-run turn stays visible")
        XCTAssertTrue(vm.timeline.turns.contains { $0.turnId == "long-turn-0" },
                      "the WHOLE run is retained now (90 turns < 5000 ceiling) — no mid-thread truncation")
        XCTAssertEqual(vm.timeline.turns.count, 90,
                       "all 90 turns of the long run are kept (full thread, 100%)")
        XCTAssertLessThanOrEqual(vm.timeline.providerRuntimeEvents.count, AssistantTimelineState.providerRuntimeEventLimit,
                                 "raw provider runtime events must stay capped during long runs")
        XCTAssertLessThanOrEqual(vm.timeline.workActivities.count, AssistantTimelineState.workActivityLimit,
                                 "work-log rows must stay capped during long runs")
        XCTAssertTrue(vm.contextHealthMessage?.contains("compacted") ?? false,
                      "the Agent App must expose context compaction during long runs")

        // Reopen exercises first-paint page (older rows via load-older). Live run
        // already proved the full in-memory timeline; reopen must stay bounded.
        vm.selectThread(threadId)
        await vm.waitForMessageHistoryLoad()
        XCTAssertLessThanOrEqual(
            vm.messages.count,
            AgentAppViewModel.messageHistoryPageLimit + 2,
            "reopening a long thread must not hydrate unbounded message history on MainActor"
        )
        XCTAssertFalse(vm.messages.isEmpty,
                       "reopen must still show the hot message page for a long completed thread")

        // The full load must still stay bounded: the LazyVStack only realizes visible rows
        // and the turn ceiling/event-prune keep it bounded, so footprint can't balloon.
        if beforeKB >= 0 && afterKB >= 0 {
            XCTAssertLessThan(afterKB - beforeKB, 250_000,
                              "macOS Agent App long-run stress must not grow process footprint by more than 250 MB")
        }
    }

    func test_agentAppLongRunStressRendersMacSurfaceWithoutBlankingOrStuckRun() async throws {
        let runner = LongRunStreamRunner(turns: 50, runtimeEvents: 300)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "visual long stress")

        vm.prompt = "exercise a rendered long running agent stream"
        await vm.send()

        await waitAsync("rendered long Agent App stream completes", timeout: 15) {
            vm.status == .completed && vm.timeline.latestAssistantMessage == "LONG_ASSISTANT_49"
        }

        let png = try XCTUnwrap(renderedPNGData(for: AgentAppView(vm: vm)),
                                "the macOS Agent App SwiftUI surface must render to a non-empty bitmap after a long provider stream")
        XCTAssertGreaterThan(png.count, 25_000,
                             "long-run stress must leave a visible macOS Agent App surface instead of a blank or collapsed view")
        XCTAssertEqual(vm.currentRunId, nil,
                       "rendering after a long provider stream must not leave the macOS Agent App stuck in a selected run")
        XCTAssertEqual(vm.runStartedAt, nil,
                       "rendering after a long provider stream must not leave the Working timer active")
        XCTAssertEqual(vm.timeline.turns.last?.turnId, "long-turn-49",
                       "the rendered long-run surface must keep the newest assistant turn available")
        XCTAssertLessThanOrEqual(vm.timeline.providerRuntimeEvents.count, AssistantTimelineState.providerRuntimeEventLimit,
                                 "rendering must consume the bounded runtime-event window instead of retaining all provider events")
        XCTAssertLessThanOrEqual(vm.timeline.workActivities.count, AssistantTimelineState.workActivityLimit,
                                 "rendering must consume the bounded work-log window instead of retaining every long-run row")
        XCTAssertTrue(vm.contextHealthMessage?.contains("compacted") ?? false,
                      "rendering must keep long-run context/compaction telemetry visible")
    }

    func test_selectThread_scheduledOwnedRun_seedsWorkingClockFromDurableAgentRun() throws {
        // WHY: Path B LaunchAgent runs have no local coordinator session. The old
        // selectThread branch cleared runStartedAt, so "Working for 0s" stuck while
        // tools ran in the other process. Durable agent_runs.started_at is shared SQLite.
        let tmp = NSTemporaryDirectory() + "rc2-vm-sched-clock-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coord,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        installRunnableProviderFixtures(on: vm)
        wireCanonicalThreadRead(vm, repo: threadRepo)

        var thread = AgentThread(
            workspaceId: workspaceID,
            title: "Elephant - Task 1",
            provider: .codex,
            model: "gpt-5.5"
        )
        thread.status = .running
        try threadRepo.upsert(thread)
        vm.reloadThreads()

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let run = AgentRun(
            id: AgentRunID(),
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5.5",
            status: .running,
            startedAt: startedAt
        )
        try runRepo.upsert(run)

        // No local coordinator session — only the SQLite scheduled-ownership signal.
        vm.isScheduledThreadRunning = { $0 == thread.id }
        XCTAssertNil(coord.activeRunId(threadId: thread.id),
                     "fixture must not plant a local coordinator session")

        vm.selectThread(thread.id)

        XCTAssertEqual(vm.runStartedAt, startedAt,
                       "Working for Xs must count from durable agent_runs.started_at for LaunchAgent-owned runs")
        XCTAssertEqual(vm.currentRunId, run.id,
                       "Stop must target the durable agent run id written by the LaunchAgent")
        XCTAssertTrue(vm.selectedThreadRunIsStartingOrRunning,
                      "scheduled ownership alone must keep the Working/Stop chrome visible")

        // Store-change rebind must not wipe the clock again.
        vm.selectThread(thread.id, markRead: false)
        XCTAssertEqual(vm.runStartedAt, startedAt,
                       "re-select on scheduled store change must keep the durable start clock")
        vm.dispose()
    }

    // MARK: B3 — composer attachments

    func test_attachments_addDedupesAndRemove() throws {
        let (vm, _) = try makeVM()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-attachment-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)

        vm.addAttachments([a.path, b.path, a.path])

        XCTAssertEqual(vm.attachments.map(\.displayName), ["a.txt", "b.txt"], "duplicate content must not stack")
        XCTAssertTrue(vm.attachments.allSatisfy { $0.path != a.path && $0.path != b.path },
                      "composer chips must point at managed storage instead of retaining private picker paths")
        vm.removeAttachment(vm.attachments[0])
        XCTAssertEqual(vm.attachments.map(\.displayName), ["b.txt"])
    }

    func test_droppedFilePaths_insertPathsIntoPromptWithoutCreatingAttachments() throws {
        let (vm, _) = try makeVM()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-attachment-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plain = root.appendingPathComponent("plain.txt")
        let spaced = root.appendingPathComponent("has space.txt")
        try "one".write(to: plain, atomically: true, encoding: .utf8)
        try "two".write(to: spaced, atomically: true, encoding: .utf8)
        vm.prompt = "review"

        vm.insertDroppedFilePaths([plain.path, spaced.path])

        XCTAssertEqual(vm.prompt, "review \(plain.path) \(spaced.path)",
                       "drop and paste must insert file paths as ordinary composer text so every provider can receive them")
        XCTAssertTrue(vm.attachments.isEmpty,
                      "drop and paste must not create provider-specific attachments")
    }

    func test_attachmentCapabilityErrorDoesNotBlockLaterTextSend() async throws {
        let runner = CapturingProviderRunner(provider: .grok)
        let (vm, _) = try makeVM(provider: runner)
        vm.coordinator.replaceProvider(.grok, runner: runner)
        vm.createThread(title: "send after attachment error")
        vm.provider = .grok
        vm.providerSnapshots = [AgentProviderSnapshot(
            id: "grok-no-attachments",
            provider: .grok,
            driverKind: .grokCLI,
            displayName: "Grok",
            accentColor: "#000000",
            continuationGroup: "grok",
            interactionModes: [.default],
            permissionModes: [.supervised],
            enabled: true,
            installed: true,
            status: .available,
            authenticated: true,
            models: [AgentModelDescriptor(id: "grok-4", label: "Grok 4", provider: .grok)],
            slashCommands: [],
            capabilities: .conservative
        )]
        vm.providerInstanceId = "grok-no-attachments"
        vm.model = "grok-4"
        vm.permissionMode = .supervised

        vm.addAttachments(["/tmp/unsupported.png"])
        vm.prompt = "send this text"
        await vm.send()

        XCTAssertEqual(runner.prompts, ["send this text"],
                       "a previous attachment error must never block a later ordinary text message")
        XCTAssertTrue(vm.statusMessage.isEmpty,
                      "a successful new send must clear the obsolete attachment error")
    }

    /// WHY: sqlite "database is locked" banners are durability noise. Once the
    /// thread streams more content, the outage is over — keep the banner and
    /// users think the run is still broken.
    func test_transientPersistenceError_autoClearsWhenStreamProgresses() {
        let locked = "Persistence failure during run.stream_event.append: sqlite step: database is locked"
        XCTAssertTrue(AgentAppViewModel.isTransientPersistenceTimelineError(locked),
                      "the exact banner text from stream_event.append must classify as transient")
        XCTAssertTrue(
            AgentAppViewModel.shouldAutoClearTransientTimelineError(
                errorAfterBatch: locked,
                appliedEvents: [
                    .error(message: locked, recoverable: false),
                    .itemDelta(itemId: "i1", bodyAppend: "ok", outputAppend: nil, summary: nil),
                ]
            ),
            "progress after a lock error must clear the banner"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldAutoClearTransientTimelineError(
                errorAfterBatch: locked,
                appliedEvents: [.turnStarted(turnId: "t2")]
            ),
            "a later batch with only progress must clear a sticky lock banner from an earlier batch"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldAutoClearTransientTimelineError(
                errorAfterBatch: locked,
                appliedEvents: [.error(message: locked, recoverable: false)]
            ),
            "a batch that is only the lock error must keep the banner visible"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldAutoClearTransientTimelineError(
                errorAfterBatch: "Provider request failed: 401 unauthorized",
                appliedEvents: [.itemDelta(itemId: "i1", bodyAppend: "x", outputAppend: nil, summary: nil)]
            ),
            "real provider failures must stay until the user dismisses or retries — not auto-clear on progress"
        )
    }

    func test_partialHotReplayUsesInformationalNotice_notErrorBanner() {
        // WHY: partial hot replay still loads, but the user-facing banner copy is
        // suppressed so the strip never shows the hot-replay budget notice.
        XCTAssertNil(
            AgentAppViewModel.replayNoticeText(isPartial: true),
            "partial hot replay must not surface the history window notice"
        )
        XCTAssertNil(
            AgentAppViewModel.replayNoticeText(isPartial: false),
            "complete replay must not leave a stale history notice"
        )
        XCTAssertFalse(
            AgentAppViewModel.historyReplayNoticeText.isEmpty,
            "constant retained for any residual references but never assigned for display"
        )
    }

    func test_errorDismissActionsClearEachVisibleErrorChannel() throws {
        let (vm, _) = try makeVM()
        vm.timeline.apply(.error(message: "provider failed", recoverable: true))
        vm.statusMessage = "attachment failed"
        vm.queueStatusMessage = "queue failed"
        vm.modelListStatusMessage = "model load failed"
        vm.providerSnapshotStatusMessage = "provider load failed"
        vm.providerRecoveryStatusMessage = "provider recovery failed"
        vm.pullRequestStatusMessage = "PR preparation failed"
        vm.checkpointStatusMessage = "Revert failed"
        let unavailable = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: ""
        )
        vm.providerSnapshots = [unavailable]
        vm.providerInstanceId = unavailable.id
        XCTAssertNotNil(vm.providerStatusMessage,
                        "an unavailable selected provider must expose its error before dismissal")

        vm.dismissDisplayedError()
        vm.dismissStatusMessage()
        vm.dismissQueueStatusMessage()
        vm.dismissModelListStatusMessage()
        vm.dismissProviderSnapshotStatusMessage()
        vm.dismissProviderRecoveryStatusMessage()
        vm.dismissPullRequestStatusMessage()
        vm.dismissCheckpointStatusMessage()
        vm.dismissProviderStatusMessage()

        XCTAssertNil(vm.timeline.error, "the transcript error X must remove the visible error row")
        XCTAssertFalse(vm.lastErrorRecoverable, "dismissing the transcript error must remove its stale retry state")
        XCTAssertTrue(vm.statusMessage.isEmpty, "the status banner X must remove the visible status error")
        XCTAssertNil(vm.queueStatusMessage, "the queue banner X must remove the visible queue error")
        XCTAssertNil(vm.modelListStatusMessage, "the model-menu error X must clear its status")
        XCTAssertNil(vm.providerSnapshotStatusMessage, "the provider-load error X must clear its status")
        XCTAssertNil(vm.providerRecoveryStatusMessage, "the provider-recovery error X must clear its status")
        XCTAssertNil(vm.pullRequestStatusMessage, "the PR-menu error X must clear its status")
        XCTAssertNil(vm.checkpointStatusMessage, "the checkpoint error X must clear its status")
        XCTAssertNil(vm.providerStatusMessage, "the selected-provider error X must hide the derived status")
    }

    func test_send_withAttachments_composesPromptAndClears() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "t")
        let tid = vm.selectedThreadId!
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-attachment-\(UUID().uuidString).swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        vm.prompt = "review these"
        vm.addAttachments([file.path])
        await vm.send()

        XCTAssertTrue(vm.attachments.isEmpty, "attachments must clear after send")
        XCTAssertEqual(runner.prompts.last, "review these",
                       "attachment metadata must not be folded into provider prompt text")
        let providerAttachment = try XCTUnwrap(runner.attachments.last?.first)
        XCTAssertNotEqual(providerAttachment.path, file.path,
                          "provider runs must receive the durable managed reference, not the original picker path")
        XCTAssertEqual(try String(contentsOfFile: providerAttachment.path), "let x = 1\n")
        let persistedMessages: [AgentMessage] = (try? vm.messageRepo.list(threadId: tid)) ?? []
        let user = persistedMessages.first { $0.role == .user }
        XCTAssertFalse(user?.content.contains(file.path) ?? true,
                       "persisted transcript must not leak raw attachment paths into prompt text")
        XCTAssertTrue(user?.content.contains(file.lastPathComponent) ?? false,
                      "the persisted transcript should keep a friendly attachment summary")
        XCTAssertEqual(user?.attachments.first?.sha256, providerAttachment.sha256,
                       "the persisted user message must retain durable attachment metadata for retry/relaunch")
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content.contains("📎") },
                      "the transcript shows a friendly attachment summary, not raw paths")
    }

    func test_send_withImageAttachment_showsLiteralImageMarker() async throws {
        // WHY: Agent App and Bot Desk share displayUserLine. A one-image turn
        // must persist `[Image #1]` in the user bubble, not 📎 photo.png.
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "t")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-shot-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        vm.prompt = "What is in this picture?"
        vm.addAttachments([file.path])
        await vm.send()

        XCTAssertEqual(runner.prompts.last, "What is in this picture?",
                       "image markers are display-only; the provider prompt stays the user's words")
        XCTAssertTrue(
            vm.messages.contains { $0.role == .user && $0.content.contains("[Image #1]") },
            "the transcript must show the literal [Image #1] marker"
        )
        XCTAssertFalse(
            vm.messages.contains { $0.role == .user && $0.content.contains("📎") },
            "an image-only turn must not fall back to the file paperclip suffix"
        )
    }

    func test_send_withMissingAttachmentErrorStillSendsOrdinaryTextWithoutAttachment() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "t")
        vm.prompt = "review"
        vm.addAttachments(["/tmp/remote-code-missing-\(UUID().uuidString).png"])

        await vm.send()

        XCTAssertEqual(runner.prompts, ["review"],
                       "a missing attachment error must not block the user's ordinary text message")
        XCTAssertEqual(runner.attachments.last, [],
                       "the provider must receive no attachment rather than the invalid path")
        XCTAssertTrue(vm.statusMessage.isEmpty,
                      "the successful text send must clear the obsolete attachment error")
        XCTAssertTrue(vm.prompt.isEmpty,
                      "the text draft must clear after its successful send")
        XCTAssertTrue(vm.attachments.isEmpty,
                      "an invalid path must never become a misleading successful attachment chip")
    }

    func test_threadDraftRestoresTextAttachmentsAndModeAcrossRelaunch() throws {
        let tmp = NSTemporaryDirectory() + "rc2-agent-draft-relaunch-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let store = AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments"))
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let a = AgentThread(workspaceId: workspaceID, title: "A", provider: .codex, model: "gpt", interactionMode: .plan)
        let b = AgentThread(workspaceId: workspaceID, title: "B", provider: .codex, model: "gpt", interactionMode: .default)
        try threadRepo.upsert(a)
        try threadRepo.upsert(b)
        let source = URL(fileURLWithPath: tmp).appendingPathComponent("private.png")
        try Data("image".utf8).write(to: source)

        let first = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp, coordinator: coordinator,
                                      threadRepo: threadRepo, messageRepo: messageRepo,
                                      draftRepo: draftRepo, attachmentStore: store, initialThreadId: a.id)
        installRunnableProviderFixtures(on: first)
        first.prompt = "private draft"
        first.promptWasEdited()
        first.addAttachments([source.path])
        first.interactionMode = .plan
        first.persistThreadConfig()
        first.selectThread(b.id)
        XCTAssertEqual(first.prompt, "")
        XCTAssertTrue(first.attachments.isEmpty, "thread B must not inherit thread A's private attachment")

        try FileManager.default.removeItem(at: source)
        let relaunched = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp, coordinator: coordinator,
                                           threadRepo: threadRepo, messageRepo: messageRepo,
                                           draftRepo: draftRepo, attachmentStore: store, initialThreadId: a.id)

        XCTAssertEqual(relaunched.prompt, "private draft")
        XCTAssertEqual(relaunched.attachments.map(\.displayName), ["private.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: relaunched.attachments[0].path),
                      "draft attachment must survive after the original picked file is removed")
        XCTAssertEqual(relaunched.interactionMode, .plan)
    }

    func test_sameThreadProviderSwitchRestoresOnlyMatchingProviderDraft() async throws {
        let (vm, _) = try makeVM()
        let codex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-test", label: "GPT", provider: .codex)],
            binaryPath: "/tmp/codex",
            id: "codex-work"
        )
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "claude-test", label: "Claude", provider: .claude)],
            binaryPath: "/tmp/claude",
            id: "claude-personal"
        )
        vm.providerSnapshotLoader = { [codex, claude] in [codex, claude] }
        await vm.loadProviderSnapshots()
        vm.createThread(title: "shared")
        vm.setProvider(.codex)
        vm.prompt = "codex-only draft"
        vm.interactionMode = .plan
        vm.promptWasEdited()

        vm.setProvider(.claude)
        XCTAssertEqual(vm.prompt, "",
                       "switching provider instances in one thread must not leak the prior provider's draft")
        XCTAssertEqual(vm.interactionMode, .default)
        vm.prompt = "claude-only draft"
        vm.promptWasEdited()

        vm.setProvider(.codex)
        XCTAssertEqual(vm.prompt, "codex-only draft")
        XCTAssertEqual(vm.interactionMode, .plan)
        vm.setProvider(.claude)
        XCTAssertEqual(vm.prompt, "claude-only draft")
        XCTAssertEqual(vm.interactionMode, .default)
    }

    // PERF-IMPROVE-28: a warm in-session draft cache must serve thread-switch
    // restore without a synchronous MainActor SQLite read; the durable row is
    // consulted only on a cache miss (fresh VM, relaunch).
    func test_warmCacheThreadSwitchRestoresDraftWithoutDurableRead() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "A")
        let threadA = vm.selectedThreadId!
        vm.createThread(title: "B")
        let threadB = vm.selectedThreadId!

        vm.selectThread(threadA)
        vm.prompt = "hello-a"
        vm.promptWasEdited()
        // promptWasEdited caches the draft synchronously; only the durable
        // write is debounced, so the next restore for A must come from memory.
        vm.selectThread(threadB)
        XCTAssertEqual(vm.prompt, "", "thread B must not inherit thread A's draft")
        let readsBeforeWarmRestore = vm.durableComposerDraftReadCountForTesting
        vm.selectThread(threadA)
        XCTAssertEqual(vm.prompt, "hello-a",
                       "the warm cache must restore the draft exactly as before")
        XCTAssertEqual(vm.durableComposerDraftReadCountForTesting, readsBeforeWarmRestore,
                       "a warm-cache restore must not issue a durable SQLite read")
    }

    // PERF-IMPROVE-28: the debounced background save now writes off the
    // MainActor; the durable row must still land (exactly once, no failure
    // copy) after the debounce window.
    func test_debouncedDraftSavePersistsDurableRowOffMain() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "debounce")
        let tid = vm.selectedThreadId!
        vm.prompt = "typed draft"
        vm.promptWasEdited()
        try await Task.sleep(nanoseconds: 600_000_000) // > 250 ms debounce window
        let durable = try vm.draftRepo?.get(threadId: tid, providerInstanceId: vm.providerInstanceId)
        XCTAssertEqual(durable?.text, "typed draft",
                       "the off-main debounced save must still persist the typed draft")
        XCTAssertFalse(vm.statusMessage.contains("Draft save failed"),
                       "a successful off-main save must not surface a failure")
    }

    func test_send_persistsExactlyOneUserAndOneAssistantMessage() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "convo")
        let tid = vm.selectedThreadId!
        vm.prompt = "hello there"
        await vm.send()
        // Deterministic: the coordinator persists the user message inside
        // (awaited) startRun; the VM must NOT also persist it.
        let afterSend = (try? vm.messageRepo.list(threadId: tid)) ?? []
        XCTAssertEqual(afterSend.filter { $0.role == .user && $0.content == "hello there" }.count, 1,
                       "the user message must be persisted exactly once (coordinator is the single writer)")
        await waitAsync("fake run completes") { vm.status == .completed }
        let assistants = ((try? vm.messageRepo.list(threadId: tid)) ?? []).filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1, "the assistant reply must be persisted exactly once, not double-written")
    }

    func test_completedSelectedRunKeepsLiveTimelineVisible() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-completed-timeline-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: HoldOpenStreamRunner()]
        )
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "live")
        vm.prompt = "stream please"
        await vm.send()

        await waitAsync("run completes") { vm.status == .completed }

        XCTAssertTrue(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("partial stream")
        }, "the completed selected run must keep live stream/history items visible instead of collapsing to the final answer only")
    }

    func test_secondSendKeepsPriorTimelineHistoryVisible() async throws {
        let (vm, _) = try makeVM()
        vm.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(
            provider: .codex,
            scenario: .withTool(toolName: "Bash", output: "tool output", reply: "first answer")
        ))
        vm.createThread(title: "convo")

        vm.prompt = "first prompt"
        await vm.send()
        await waitAsync("first answer completes") { vm.status == .completed }
        XCTAssertTrue(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .tool && $0.output == "tool output"
        }, "after completion the selected thread may keep tools and updates in the live timeline")

        vm.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "second answer")))
        vm.prompt = "second prompt"
        await vm.send()
        // The second run settles asynchronously: the user message is mirrored
        // in-memory immediately, but a trailing run-state callback can reload
        // `vm.messages` from the DB before the second prompt is durably
        // persisted. Wait for the second turn to fully settle so the assertions
        // observe a stable state instead of a mid-reload snapshot.
        await waitAsync("second turn settles with prior history intact") {
            vm.status == .completed &&
            vm.messages.contains { $0.role == .user && $0.content == "second prompt" } &&
            vm.messages.contains { $0.role == .assistant && $0.content == "first answer" }
        }

        XCTAssertTrue(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .tool && $0.output == "tool output"
        }, "sending a follow-up must not clear prior agent timeline history such as tool calls and outputs")
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "first prompt" })
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "second prompt" })
        let persistedAssistantTexts = vm.messages.compactMap { $0.role == .assistant ? $0.content : nil }
        XCTAssertTrue(persistedAssistantTexts.contains("first answer"),
                      "the persisted assistant answer must remain available as the durable completed response")
        XCTAssertFalse(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage &&
            $0.body == "first answer" &&
            AgentAppView.shouldRenderAssistantItemBody($0.body, persistedAssistantTexts: persistedAssistantTexts)
        }, "the replayed assistant timeline must not render a duplicate of the persisted final answer")
    }

    func test_selectThreadReplaysPersistedStreamHistoryWithoutDuplicatingFinalAnswer() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-replay-timeline-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: HoldOpenStreamRunner()]
        )
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "live")
        let streamedThread = vm.selectedThreadId!
        vm.prompt = "stream please"
        await vm.send()
        await waitAsync("run completes") { vm.status == .completed }
        await waitAsync("stream timeline is persisted before reload") {
            vm.timeline.turns.flatMap(\.items).contains {
                $0.type == .assistantMessage && $0.body.contains("partial stream")
            }
        }
        await waitAsync("stream event store contains assistant partial before reload") {
            coordinator.latestStreamEvents(threadId: streamedThread).contains { event in
                if case .itemDelta(let itemId, let bodyAppend, _, _) = event {
                    return !itemId.isEmpty && (bodyAppend ?? "").contains("partial stream")
                }
                return false
            }
        }

        vm.createThread(title: "other")
        let reloadedVM = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                           coordinator: coordinator, threadRepo: threadRepo,
                                           messageRepo: messageRepo)
        reloadedVM.selectThread(streamedThread)
        await reloadedVM.waitForMessageHistoryLoad()
        await reloadedVM.waitForSelectThreadHydrationForTesting()

        XCTAssertTrue(reloadedVM.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("partial stream")
        }, "reopening a thread must replay persisted stream items, not just show the final answer")
        let persistedAssistantTexts = reloadedVM.messages.compactMap { $0.role == .assistant ? $0.content : nil }
        XCTAssertEqual(persistedAssistantTexts.filter { $0 == "partial stream final" }.count, 1,
                       "the persisted final answer must remain available as the durable completed response")
        XCTAssertFalse(reloadedVM.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage &&
            $0.body == "partial stream final" &&
            AgentAppView.shouldRenderAssistantItemBody($0.body, persistedAssistantTexts: persistedAssistantTexts)
        }, "the replayed assistant stream must not render a duplicate of the persisted final answer")
    }

    func test_selectThreadReplaysPersistedContextTelemetryAfterRestart() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-replay-context-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: ContextTelemetryRunner()]
        )
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "telemetry")
        let streamedThread = vm.selectedThreadId!
        vm.prompt = "report context"
        await vm.send()
        await waitAsync("telemetry run completes") { vm.status == .completed }

        let reloadedVM = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                           coordinator: coordinator, threadRepo: threadRepo,
                                           messageRepo: messageRepo)
        reloadedVM.selectThread(streamedThread)
        await reloadedVM.waitForSelectThreadHydrationForTesting()

        XCTAssertEqual(reloadedVM.contextHealthMessage, "Context 50% · 500 / 1000 tokens · auto-compacts · compacted",
                       "reopening a thread after app restart must replay persisted token/compaction telemetry so long-run context pressure stays visible")
    }

    private func realCodexProviderSnapshot() -> AgentProviderSnapshot {
        AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: ProcessLocator.resolve("codex"),
            capabilitiesOverride: AgentProviderCapabilities(
                supportsAttachments: true,
                supportedAttachmentKinds: [.file, .image],
                supportedAttachmentMediaTypes: ["*/*", "image/jpeg", "image/png", "image/gif", "image/webp"],
                supportsApprovals: true,
                supportsUserInput: true,
                supportsStreaming: true,
                supportsFork: true,
                supportsRollback: true,
                supportsPlanReview: true
            )
        )
    }

    func test_realCodexAppServerAgentSurfaceSurvivesAppRestartAndRehydratesProviderHistory() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server Agent App surface E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-agent-app-" + UUID().uuidString
        let isolatedCodexHome = tmp + "-codex-home"
        let installedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        guard FileManager.default.fileExists(atPath: installedCodexAuth) else {
            throw XCTSkip("installed Codex auth.json is unavailable")
        }
        try FileManager.default.createDirectory(atPath: isolatedCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: isolatedCodexHome + "/auth.json",
            withDestinationPath: installedCodexAuth
        )
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: isolatedCodexHome)
        }
        let isolatedCodexLaunch: (AgentProvider, String?) -> (binary: String?, environment: [String: String]) = { provider, _ in
            provider == .codex
                ? (nil, ["CODEX_HOME": isolatedCodexHome])
                : (nil, [:])
        }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()

        let firstAdapter = CodexAppServerAdapter()
        defer { firstAdapter.stopAll() }
        let firstCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: firstAdapter]
        )
        let firstSurface = AgentAppViewModel(workspaceID: workspaceID,
                                             cwd: tmp,
                                             coordinator: firstCoordinator,
                                             threadRepo: threadRepo,
                                             messageRepo: messageRepo)
        firstSurface.providerLaunchConfig = isolatedCodexLaunch
        firstSurface.providerSnapshots = [realCodexProviderSnapshot()]
        firstSurface.createThread(title: "real codex")
        firstSurface.provider = .codex
        firstSurface.model = "gpt-5.5"
        firstSurface.reasoningEffort = .minimal
        firstSurface.permissionMode = .supervised
        firstSurface.prompt = "Reply exactly RC_AGENT_APP_REAL_1 and nothing else."

        await firstSurface.send()
        await waitAsync("first real Codex app-server Agent App turn completes", timeout: 240) {
            firstSurface.status == .completed
        }

        let threadId = try XCTUnwrap(firstSurface.selectedThreadId)
        let providerThreadId = try XCTUnwrap(try threadRepo.get(id: threadId)?.providerThreadId)
        XCTAssertTrue(firstSurface.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("RC_AGENT_APP_REAL_1")
        }, "the macOS Agent App surface must render the first real Codex app-server response")

        firstAdapter.stopAllForAppTermination()

        let secondAdapter = CodexAppServerAdapter()
        defer { secondAdapter.stopAll() }
        let secondCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: secondAdapter]
        )
        let secondSurface = AgentAppViewModel(workspaceID: workspaceID,
                                              cwd: tmp,
                                              coordinator: secondCoordinator,
                                              threadRepo: threadRepo,
                                              messageRepo: messageRepo)
        secondSurface.providerLaunchConfig = isolatedCodexLaunch
        secondSurface.providerSnapshots = [realCodexProviderSnapshot()]
        secondSurface.selectThread(threadId)
        XCTAssertTrue(secondSurface.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("RC_AGENT_APP_REAL_1")
        }, "after app/coordinator restart, selecting the thread must recover provider history through Codex thread/read")

        secondSurface.prompt = "Reply exactly RC_AGENT_APP_REAL_2 and nothing else."
        await secondSurface.send()
        await waitAsync("second real Codex app-server Agent App turn completes after restart", timeout: 240) {
            secondSurface.status == .completed
        }

        let resumedThread = try XCTUnwrap(try threadRepo.get(id: threadId))
        XCTAssertEqual(resumedThread.providerThreadId, providerThreadId,
                       "the app restart follow-up must resume the same Codex app-server provider thread instead of forking a disconnected session")
        XCTAssertTrue(secondSurface.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("RC_AGENT_APP_REAL_2")
        }, "the macOS Agent App surface must render the real Codex follow-up after restart")

        secondAdapter.stopAll()

        let readbackAdapter = CodexAppServerAdapter()
        defer { readbackAdapter.stopAll() }
        let readbackCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: readbackAdapter]
        )
        let readbackSurface = AgentAppViewModel(workspaceID: workspaceID,
                                                cwd: tmp,
                                                coordinator: readbackCoordinator,
                                                threadRepo: threadRepo,
                                                messageRepo: messageRepo)
        readbackSurface.providerLaunchConfig = isolatedCodexLaunch
        readbackSurface.selectThread(threadId)
        let renderedBodies = readbackSurface.timeline.turns.flatMap(\.items).map(\.body).joined(separator: "\n")
        XCTAssertTrue(renderedBodies.contains("RC_AGENT_APP_REAL_1"))
        XCTAssertTrue(renderedBodies.contains("RC_AGENT_APP_REAL_2"),
                      "final app restart readback must prove both real Codex app-server turns remain visible in provider history")
        readbackAdapter.stopAll()
    }

    func test_realCodexAppServerLocalImageAttachmentChangesTheAnswer() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server image E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-image-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let isolatedCodexHome = tmp + "-codex-home"
        defer { try? FileManager.default.removeItem(atPath: isolatedCodexHome) }
        let installedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        guard FileManager.default.fileExists(atPath: installedCodexAuth) else {
            throw XCTSkip("installed Codex auth.json is unavailable")
        }
        try FileManager.default.createDirectory(atPath: isolatedCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: isolatedCodexHome + "/auth.json",
            withDestinationPath: installedCodexAuth
        )

        let nonce = "RC_IMAGE_42A7"
        let image = NSImage(size: NSSize(width: 900, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 240).fill()
        nonce.draw(
            at: NSPoint(x: 55, y: 80),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 72, weight: .bold),
                .foregroundColor: NSColor.black
            ]
        )
        image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let imagePath = tmp + "/nonce.png"
        try png.write(to: URL(fileURLWithPath: imagePath))

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp + "-db").run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: ProviderSessionRuntimeRepository(db: db),
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        surface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": isolatedCodexHome]) : (nil, [:])
        }
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "real image")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .supervised
        surface.addAttachments([imagePath])
        XCTAssertEqual(surface.attachments.count, 1)
        surface.prompt = "Read the exact code shown in the attached image. Reply with only that code."

        await surface.send()
        await waitAsync("real Codex local-image turn completes", timeout: 240) {
            surface.status == .completed
        }
        let rendered = surface.timeline.turns.flatMap(\.items).map(\.body).joined(separator: "\n")
        XCTAssertTrue(rendered.contains(nonce) || (surface.messages.last?.content.contains(nonce) ?? false),
                      "the real Codex answer must depend on bytes delivered through localImage/path")
        XCTAssertFalse(rendered.contains(imagePath),
                       "the visible transcript must not expose the private absolute attachment path")
    }

    func test_realCodexAppServerMissingAuthSurfacesSignInRecovery() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server auth E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-no-auth-" + UUID().uuidString
        let emptyCodexHome = tmp + "-codex-home"
        try FileManager.default.createDirectory(atPath: emptyCodexHome, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: emptyCodexHome)
        }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: ProviderSessionRuntimeRepository(db: db),
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp, coordinator: coordinator,
            threadRepo: threadRepo, messageRepo: messageRepo
        )
        surface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": emptyCodexHome]) : (nil, [:])
        }
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "missing auth")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .supervised
        surface.prompt = "Reply exactly SHOULD_NOT_RUN."

        await surface.send()
        await waitAsync("real Codex auth failure reaches Agent App", timeout: 120) {
            surface.status == .failed && surface.timeline.error != nil
        }
        XCTAssertEqual(surface.displayedErrorRecoveryAction, .signIn,
                       "a real unauthenticated app-server turn must expose Sign in instead of a dead generic error")
        XCTAssertFalse(surface.messages.contains { $0.role == .assistant && $0.content.contains("SHOULD_NOT_RUN") },
                       "an unauthenticated turn must not be misrepresented as successful provider output")
    }

    func test_realCodexAppServerForkRetainsParentContextAndIsolatesChildChanges() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server fork E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-fork-" + UUID().uuidString
        let isolatedCodexHome = tmp + "-codex-home"
        let installedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        guard FileManager.default.fileExists(atPath: installedCodexAuth) else {
            throw XCTSkip("installed Codex auth.json is unavailable")
        }
        try FileManager.default.createDirectory(atPath: isolatedCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: isolatedCodexHome + "/auth.json",
            withDestinationPath: installedCodexAuth
        )
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: isolatedCodexHome)
        }

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db), messageRepo: messageRepo, threadRepo: threadRepo,
            providerSessionRepo: ProviderSessionRuntimeRepository(db: db), providerAdapters: [.codex: adapter]
        )
        coordinator.recoveryEnvironmentProvider = { provider, _ in
            provider == .codex ? ["CODEX_HOME": isolatedCodexHome] : [:]
        }
        let surface = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp, coordinator: coordinator,
            threadRepo: threadRepo, messageRepo: messageRepo
        )
        surface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": isolatedCodexHome]) : (nil, [:])
        }
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "real fork parent")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .supervised
        surface.prompt = "Remember that the base label is RC_FORK_BASE_42A7. Reply exactly READY."
        await surface.send()
        await waitAsync("real Codex parent context turn completes", timeout: 240) {
            surface.status == .completed
        }
        let parentId = try XCTUnwrap(surface.selectedThreadId)
        let parentProviderId = try XCTUnwrap(try threadRepo.get(id: parentId)?.providerThreadId)

        await surface.forkCurrentThread()
        let childId = try XCTUnwrap(surface.selectedThreadId)
        XCTAssertNotEqual(childId, parentId)
        let childProviderId = try XCTUnwrap(try threadRepo.get(id: childId)?.providerThreadId)
        XCTAssertNotEqual(childProviderId, parentProviderId,
                          "a real fork must create a distinct provider-native branch identity")

        surface.prompt = "Remember that the child-only label is RC_FORK_CHILD_73B9. Reply exactly CHILD_SET."
        await surface.send()
        await waitAsync("real Codex child turn completes", timeout: 240) { surface.status == .completed }

        surface.selectThread(parentId)
        surface.prompt = "What is the base label? Did any prior message in this conversation set a child-only label? Reply BASE_LABEL|YES_OR_NO only."
        await surface.send()
        await waitAsync("real Codex parent isolation turn completes", timeout: 240) { surface.status == .completed }
        let parentReply = surface.messages.last(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertTrue(parentReply.contains("RC_FORK_BASE_42A7") && parentReply.uppercased().contains("|NO"),
                      "the parent must retain its base context without receiving child-only mutations; got: \(parentReply)")

        surface.selectThread(childId)
        surface.prompt = "What are the base label and child-only label? Reply BASE_LABEL|CHILD_LABEL only."
        await surface.send()
        await waitAsync("real Codex fork context turn completes", timeout: 240) { surface.status == .completed }
        let childReply = surface.messages.last(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertTrue(childReply.contains("RC_FORK_BASE_42A7") && childReply.contains("RC_FORK_CHILD_73B9"),
                      "the provider-native child must inherit parent context and retain its own later context; got: \(childReply)")
        XCTAssertEqual(try threadRepo.get(id: parentId)?.providerThreadId, parentProviderId)
        XCTAssertEqual(try threadRepo.get(id: childId)?.providerThreadId, childProviderId)
    }

    func test_realCodexRelaunchContinueUsesPersistedCursorAndContext() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex relaunch E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-relaunch-" + UUID().uuidString
        let isolatedCodexHome = tmp + "-codex-home"
        let installedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        guard FileManager.default.fileExists(atPath: installedCodexAuth) else {
            throw XCTSkip("installed Codex auth.json is unavailable")
        }
        try FileManager.default.createDirectory(atPath: isolatedCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: isolatedCodexHome + "/auth.json",
            withDestinationPath: installedCodexAuth
        )
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: isolatedCodexHome)
        }

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let providerSnapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: ProcessLocator.resolve("codex")
        )

        let firstAdapter = CodexAppServerAdapter()
        let firstCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: firstAdapter]
        )
        firstCoordinator.recoveryEnvironmentProvider = { provider, _ in
            provider == .codex ? ["CODEX_HOME": isolatedCodexHome] : [:]
        }
        let firstSurface = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: firstCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        firstSurface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": isolatedCodexHome]) : (nil, [:])
        }
        firstSurface.providerSnapshots = [providerSnapshot]
        firstSurface.createThread(title: "real relaunch")
        firstSurface.provider = .codex
        firstSurface.model = "gpt-5.5"
        firstSurface.reasoningEffort = .minimal
        firstSurface.permissionMode = .supervised
        firstSurface.prompt = "Remember RC_RELAUNCH_CONTEXT_91D4. If asked to continue interrupted work, reply exactly CONTINUED|RC_RELAUNCH_CONTEXT_91D4. For now reply exactly READY."

        await firstSurface.send()
        await waitAsync("real Codex pre-relaunch context turn completes", timeout: 240) {
            firstSurface.status == .completed
        }
        let threadId = try XCTUnwrap(firstSurface.selectedThreadId)
        let providerThreadId = try XCTUnwrap(try threadRepo.get(id: threadId)?.providerThreadId)
        firstSurface.permissionMode = .fullAccess
        firstSurface.prompt = "Run the shell command `sleep 60` now. After it finishes, reply exactly LONG_TURN_FINISHED."
        await firstSurface.send()
        await waitAsync("real Codex long turn is durably running", timeout: 30) {
            guard let runId = firstSurface.currentRunId else { return false }
            return (try? runRepo.get(id: runId)?.status) == .running
                && (try? sessionRepo.get(threadId: threadId)?.status) == .running
                && (try? sessionRepo.get(threadId: threadId)?.resumeCursor) == providerThreadId
        }
        let interruptedRunId = try XCTUnwrap(firstSurface.currentRunId)
        XCTAssertEqual(try runRepo.get(id: interruptedRunId)?.status, .running,
                       "precondition: force-quit must land inside a real active provider turn")
        let userMessageCount = try messageRepo.list(threadId: threadId).filter { $0.role == .user }.count

        // Simulate the app process disappearing: kill the real app-server without
        // delivering a synthetic terminal callback or rewriting durable statuses.
        firstAdapter.stopAllForAppTermination()

        let relaunchedAdapter = CodexAppServerAdapter()
        defer { relaunchedAdapter.stopAll() }
        let relaunchedCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: relaunchedAdapter]
        )
        relaunchedCoordinator.recoveryEnvironmentProvider = { provider, _ in
            provider == .codex ? ["CODEX_HOME": isolatedCodexHome] : [:]
        }
        try relaunchedCoordinator.reconcileOnLaunch()
        XCTAssertEqual(try threadRepo.get(id: threadId)?.status, .interrupted)
        XCTAssertEqual(try runRepo.get(id: interruptedRunId)?.status, .interrupted)
        XCTAssertTrue(relaunchedCoordinator.hasRecoverableContext(threadId: threadId),
                      "relaunch reconciliation must retain a cursor-backed Codex session as recoverable")

        let relaunchedSurface = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: relaunchedCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            initialThreadId: threadId
        )
        relaunchedSurface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": isolatedCodexHome]) : (nil, [:])
        }
        relaunchedSurface.providerSnapshots = [providerSnapshot]
        XCTAssertTrue(relaunchedSurface.selectedThreadHasRecoverableContext)

        await relaunchedSurface.continueInterruptedThread()
        await waitAsync("real Codex interrupted context continues after relaunch", timeout: 240) {
            relaunchedSurface.status == .completed
        }
        let reply = relaunchedSurface.messages.last(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertTrue(reply.contains("CONTINUED|RC_RELAUNCH_CONTEXT_91D4"),
                      "Continue must resume the same real Codex context; got: \(reply)")
        XCTAssertEqual(try threadRepo.get(id: threadId)?.providerThreadId, providerThreadId,
                       "relaunch continuation must retain the original provider cursor")
        XCTAssertEqual(try messageRepo.list(threadId: threadId).filter { $0.role == .user }.count, userMessageCount,
                       "the provider-only Continue instruction must not invent a user transcript message")
    }

    func test_realCodexAppServerPlanModeSurfaceRendersAndImplementsProposedPlan() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server Plan Mode surface E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-plan-surface-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: tmp + "-db")
        }
        let sentinel = tmp + "/sentinel.txt"
        try "RC_PLAN_SENTINEL_ORIGINAL\n".write(toFile: sentinel, atomically: true, encoding: .utf8)

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp + "-db").run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()

        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(workspaceID: workspaceID,
                                        cwd: tmp,
                                        coordinator: coordinator,
                                        threadRepo: threadRepo,
                                        messageRepo: messageRepo)
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "real plan")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        // Plan mode may inspect local instructions before proposing a plan. Keep
        // approvals out of this lifecycle gate; Plan's read-only collaboration
        // sandbox still proves the no-mutation contract below.
        surface.permissionMode = .fullAccess
        surface.interactionMode = .plan
        surface.prompt = """
        Create a proposed implementation plan only. Do not edit files.
        The plan must include this exact marker: RC_AGENT_APP_PLAN_SURFACE.
        The plan must include one implementation step that says to reply exactly RC_AGENT_APP_PLAN_IMPLEMENTED.
        """

        await surface.send()
        await waitAsync("real Codex Plan Mode surface completes", timeout: 240) {
            surface.status == .completed
        }
        let threadId = try XCTUnwrap(surface.selectedThreadId)
        await waitAsync("real Codex Plan Mode proposed plan is rendered", timeout: 20) {
            (surface.latestPlanText ?? "").contains("RC_AGENT_APP_PLAN_SURFACE")
        }

        XCTAssertEqual(try String(contentsOfFile: sentinel), "RC_PLAN_SENTINEL_ORIGINAL\n",
                       "Plan Mode through the macOS Agent App surface must not mutate workspace files")
        let providerThreadId = try XCTUnwrap(try threadRepo.get(id: threadId)?.providerThreadId)
        let proposedPlan = try XCTUnwrap(surface.latestProposedPlan,
                                         "the rendered plan card must be backed by a first-class proposed-plan artifact")
        XCTAssertTrue(proposedPlan.markdown.contains("RC_AGENT_APP_PLAN_SURFACE"))

        await surface.implementLatestPlan()
        await waitAsync("real Codex proposed plan implementation completes", timeout: 240) {
            surface.status == .completed
        }

        let resumedThread = try XCTUnwrap(try threadRepo.get(id: threadId))
        XCTAssertEqual(resumedThread.providerThreadId, providerThreadId,
                       "implementing a rendered proposed-plan card must continue the same provider thread")
        let renderedText = surface.timeline.turns.flatMap(\.items).map(\.body).joined(separator: "\n")
        XCTAssertTrue(renderedText.contains("RC_AGENT_APP_PLAN_IMPLEMENTED") ||
                      (surface.messages.last?.content.contains("RC_AGENT_APP_PLAN_IMPLEMENTED") ?? false),
                      "the rendered proposed-plan card action must run through the real Codex app-server surface end-to-end")
        XCTAssertTrue(surface.timeline.proposedPlans.contains {
            $0.id == proposedPlan.id && $0.implementedAtMs != nil
        }, "acting on the proposed-plan card must mark the plan as implemented in the visible surface state")
        adapter.stopAll()
    }

    func test_realCodexAppServerTokenUsageSurfaceSurvivesReload() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server token telemetry E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-token-usage-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()

        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(workspaceID: workspaceID,
                                        cwd: tmp,
                                        coordinator: coordinator,
                                        threadRepo: threadRepo,
                                        messageRepo: messageRepo)
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "real token usage")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .supervised
        surface.prompt = "Reply exactly RC_AGENT_APP_TOKEN_USAGE and nothing else."

        await surface.send()
        await waitAsync("real Codex token-usage turn completes", timeout: 240) {
            surface.status == .completed
        }
        let threadId = try XCTUnwrap(surface.selectedThreadId)
        await waitAsync("real Codex token usage reaches Agent App surface", timeout: 20) {
            surface.contextHealthMessage?.contains("Context ") == true &&
            surface.contextHealthMessage?.contains("tokens") == true
        }
        let liveContext = try XCTUnwrap(surface.contextHealthMessage)
        XCTAssertTrue(liveContext.contains("/"),
                      "real Codex app-server token usage must include used/context-window counts, not just a generic activity flag")
        XCTAssertTrue(liveContext.contains("auto-compacts"),
                      "real Codex app-server token usage must surface automatic compaction capability so long-run context pressure is not mistaken for a hard stop")
        adapter.stopAll()

        let reloadedCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: CodexAppServerAdapter()]
        )
        let reloadedSurface = AgentAppViewModel(workspaceID: workspaceID,
                                                cwd: tmp,
                                                coordinator: reloadedCoordinator,
                                                threadRepo: threadRepo,
                                                messageRepo: messageRepo)
        reloadedSurface.selectThread(threadId)

        XCTAssertEqual(reloadedSurface.contextHealthMessage, liveContext,
                       "reloading a real Codex app-server Agent App thread must replay persisted token usage so long-run context pressure stays visible")
    }

    func test_realCodexAppServerCheckpointRevertSurfaceRollsBackWorkspaceAndProviderAfterRestart() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server checkpoint/revert E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let repoDir = NSTemporaryDirectory() + "rc2-real-codex-checkpoint-repo-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: repoDir, withIntermediateDirectories: true)
        try "BASE\n".write(toFile: repoDir + "/tracked.txt", atomically: true, encoding: .utf8)
        try runGit(["init"], cwd: repoDir)
        try runGit(["config", "user.email", "remotecode@example.test"], cwd: repoDir)
        try runGit(["config", "user.name", "RemoteCode Test"], cwd: repoDir)
        try runGit(["add", "tracked.txt"], cwd: repoDir)
        try runGit(["commit", "-m", "base"], cwd: repoDir)

        let appSupport = NSTemporaryDirectory() + "rc2-real-codex-checkpoint-db-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: repoDir)
            try? FileManager.default.removeItem(atPath: appSupport)
        }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let workspaceID = WorkspaceID()

        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            checkpointRepo: checkpointRepo,
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(workspaceID: workspaceID,
                                        cwd: repoDir,
                                        coordinator: coordinator,
                                        threadRepo: threadRepo,
                                        messageRepo: messageRepo)
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "real checkpoint")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .fullAccess

        surface.prompt = """
        Use shell to run:
        python3 - <<'PY'
        open('tracked.txt','w').write('RC_AGENT_APP_CHECKPOINT_ONE\\n')
        PY
        Then reply exactly RC_AGENT_APP_CHECKPOINT_ONE.
        """
        await surface.send()
        await waitAsync("first real checkpoint mutation completes", timeout: 240) {
            surface.status == .completed
        }
        let threadId = try XCTUnwrap(surface.selectedThreadId)
        await waitAsync("first checkpoint is captured", timeout: 20) {
            ((try? checkpointRepo.list(threadId: threadId)) ?? []).count >= 1
        }

        surface.prompt = """
        Use shell to run:
        python3 - <<'PY'
        open('tracked.txt','w').write('RC_AGENT_APP_CHECKPOINT_TWO\\n')
        open('new.txt','w').write('RC_AGENT_APP_CHECKPOINT_TWO\\n')
        PY
        Then reply exactly RC_AGENT_APP_CHECKPOINT_TWO.
        """
        await surface.send()
        await waitAsync("second real checkpoint mutation completes", timeout: 240) {
            surface.status == .completed
        }
        await waitAsync("second checkpoint is captured", timeout: 20) {
            ((try? checkpointRepo.list(threadId: threadId)) ?? []).count >= 2
        }
        XCTAssertEqual(try String(contentsOfFile: repoDir + "/tracked.txt"), "RC_AGENT_APP_CHECKPOINT_TWO\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoDir + "/new.txt"))
        adapter.stopAll()

        let restartedAdapter = CodexAppServerAdapter()
        defer { restartedAdapter.stopAll() }
        let restartedCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            checkpointRepo: checkpointRepo,
            providerAdapters: [.codex: restartedAdapter]
        )
        _ = try await restartedCoordinator.revertThreadToCheckpoint(threadId: threadId, checkpointTurnCount: 1, cwd: repoDir)

        XCTAssertEqual(try String(contentsOfFile: repoDir + "/tracked.txt"), "RC_AGENT_APP_CHECKPOINT_ONE\n",
                       "checkpoint revert after app restart must restore the workspace to the selected real Codex turn")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDir + "/new.txt"),
                       "checkpoint revert must remove files introduced after the selected real Codex turn")
        let readback = try await restartedCoordinator.readThread(threadId: threadId)
        let readbackText = readback.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertTrue(readbackText.contains("RC_AGENT_APP_CHECKPOINT_ONE"))
        XCTAssertFalse(readbackText.contains("RC_AGENT_APP_CHECKPOINT_TWO"),
                       "provider rollback after app restart must prune newer real Codex turns from provider history")
        restartedAdapter.stopAll()
    }

    func test_selectThreadRehydratesPersistedProposedPlansForMainTimeline() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-rehydrate-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
        )
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   proposedPlanRepo: proposedPlanRepo)

        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()

        XCTAssertEqual(vm.timeline.proposedPlans.map(\.id), ["plan-1"])
        XCTAssertEqual(vm.latestPlanText, "1. Inspect\n2. Patch",
                       "proposed plans must rehydrate into the Agent App main timeline after restart/reload")
    }

    func test_selectThreadRehydratesCheckpointsAndFileDiffPreview() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-checkpoint-browser-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "checkpoint", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let runId = AgentRunID()
        try runRepo.upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: runId,
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:test:turn-1",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "Sources/App.swift", kind: "modified", additions: 2, deletions: 1)],
            diffPatch: "diff --git a/Sources/App.swift b/Sources/App.swift\n+visible checkpoint",
            fileDiffs: [AgentTurnCheckpointFileDiff(path: "Sources/App.swift", patch: "@@ file diff\n+visible file checkpoint")]
        ))
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   checkpointRepo: checkpointRepo)

        // WHY (perf AA-02/AA-03): opening a thread must hydrate the checkpoint
        // browser from metadata only — the diff blobs (108 MB table at audit
        // time) are fetched per selection while the sidebar shows them.
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()

        XCTAssertEqual(vm.checkpoints.map(\.checkpointTurnCount), [1])
        XCTAssertEqual(
            checkpointRepo.fullRowListReadCountForTesting, 0,
            "opening a thread must not read any checkpoint diff/blob rows (metadata list only)"
        )
        XCTAssertGreaterThanOrEqual(checkpointRepo.summaryListReadCountForTesting, 1)
        XCTAssertEqual(checkpointRepo.fullRowListReadCountForTesting, 0,
                       "the checkpoint list must not fetch diff rows until a revert needs them")

        try await vm.revealCheckpoint(checkpointTurnCount: 1, expectedRunID: runId, path: "Sources/App.swift")
        XCTAssertEqual(vm.selectedCheckpointPath, "Sources/App.swift")
        XCTAssertEqual(vm.selectedCheckpointTurnCount, 1)
        do {
            try await vm.revealCheckpoint(checkpointTurnCount: 1, expectedRunID: AgentRunID(), path: "Sources/App.swift")
            XCTFail("a checkpoint from another run must not be revealed")
        } catch is AgentAppSurfaceCheckpointRevealError {
            XCTAssertEqual(vm.selectedCheckpointPath, "Sources/App.swift",
                           "a rejected reveal must keep the previous checkpoint selection")
        }
    }

    func test_selectThreadLoadsQueueAndDropsStaleOpenBundles() async throws {
        // WHY (perf AA-02/AA-04): the open bundle is gathered off-main; a rapid
        // A→B switch must reject A's bundle (stale-result rejection) while the
        // winning thread still gets its queue rows and checkpoint list exactly.
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-open-bundle-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let queuedMessageRepo = AgentQueuedMessageRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let workspaceID = WorkspaceID()
        let threadA = AgentThread(workspaceId: workspaceID, title: "A", provider: .codex, model: "gpt-5.5")
        let threadB = AgentThread(workspaceId: workspaceID, title: "B", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(threadA)
        try threadRepo.upsert(threadB)
        let runId = AgentRunID()
        try runRepo.upsert(AgentRun(id: runId, threadId: threadA.id, provider: .codex, model: "gpt-5.5", status: .completed))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: threadA.id,
            runId: runId,
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:test:turn-1",
            status: .ready,
            files: [],
            diffPatch: "+A checkpoint"
        ))
        let queued = AgentQueuedMessage(threadId: threadB.id, text: "queued on B")
        try queuedMessageRepo.upsert(queued)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   draftRepo: draftRepo,
                                   queuedMessageRepo: queuedMessageRepo,
                                   checkpointRepo: checkpointRepo)

        // Rapid A→B: A's bundle (with its checkpoint) must never land on B.
        vm.selectThread(threadA.id)
        vm.selectThread(threadB.id)
        await vm.waitForSelectThreadHydrationForTesting()

        XCTAssertEqual(vm.selectedThreadId, threadB.id)
        XCTAssertTrue(
            vm.checkpoints.isEmpty,
            "the stale A bundle must be rejected; B's checkpoint list (empty) is what stays"
        )
        XCTAssertEqual(
            vm.queuedMessages.map(\.text), ["queued on B"],
            "the winning thread's queue rows must still load through the open bundle"
        )

        // Opening A afterwards still applies A's own bundle (no stale-cache lockout).
        vm.selectThread(threadA.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.checkpoints.map(\.checkpointTurnCount), [1])
        XCTAssertEqual(vm.queuedMessages.map(\.text), [],
                       "switching to A clears B's queue rows")
    }

    func test_selectThreadStashesLeavingDraftOffMainAndKeepsQueueStatus() async throws {
        // WHY (perf AA-04): the leaving thread's draft write and the new
        // thread's queue read no longer block the first paint; both must still
        // land exactly once.
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-open-draft-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let queuedMessageRepo = AgentQueuedMessageRepository(db: db)
        let workspaceID = WorkspaceID()
        let threadA = AgentThread(workspaceId: workspaceID, title: "A", provider: .codex, model: "gpt-5.5")
        let threadB = AgentThread(workspaceId: workspaceID, title: "B", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(threadA)
        try threadRepo.upsert(threadB)
        try queuedMessageRepo.upsert(AgentQueuedMessage(threadId: threadB.id, text: "queued on B"))
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   draftRepo: draftRepo,
                                   queuedMessageRepo: queuedMessageRepo)

        vm.selectThread(threadA.id)
        await vm.waitForSelectThreadHydrationForTesting()
        vm.prompt = "unsent words on A"
        vm.selectThread(threadB.id)
        await vm.waitForSelectThreadHydrationForTesting()

        // The off-main stash lands within a moment; poll the durable row.
        try await waitForCondition(timeout: 2.0) {
            (try? draftRepo.get(threadId: threadA.id, providerInstanceId: vm.providerInstanceId))??.text == "unsent words on A"
        }
        XCTAssertEqual(vm.queuedMessages.map(\.text), ["queued on B"])
    }

    /// Polls `condition` until it returns true or `timeout` elapses.
    private func waitForCondition(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)s")
    }

    func test_implementLatestPlanStartsRunAndMarksPlanTraceability() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-implement-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
        )
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   proposedPlanRepo: proposedPlanRepo)
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/local/bin/codex"
        )]
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        vm.timeline.apply(.error(message: "Previous provider failure", recoverable: true))

        await vm.implementLatestPlan()

        XCTAssertNil(vm.timeline.error,
                     "implementing a proposed plan submits a new provider message and must clear any stale error banner")
        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertTrue(messages.contains {
            $0.role == .user && $0.content.contains("Implement this proposed plan now") && $0.content.contains("1. Inspect")
        }, "implementing a plan must submit a concrete implementation prompt, not just toggle UI state")
        let storedPlan = try XCTUnwrap(proposedPlanRepo.list(threadId: thread.id).first { $0.plan.id == "plan-1" })
        XCTAssertEqual(storedPlan.implementationThreadId, thread.id,
                       "the source plan must keep a link to the thread that implements it")
        XCTAssertNotNil(storedPlan.plan.implementedAtMs,
                        "implemented plans must be marked so repeat actions are traceable")
        XCTAssertFalse(storedPlan.plan.showsImplementationActions,
                       "implemented plan cards must hide Implement and New thread instead of leaving disabled repeat actions visible")
        XCTAssertTrue(AssistantProposedPlan(id: "draft", turnId: "turn-1", markdown: "1. Inspect").showsImplementationActions,
                      "unimplemented plan cards must keep their implementation actions available")
    }

    func test_implementLatestPlanDoesNotPublishImplementedStateWhenPersistenceFails() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-implement-failure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let thread = AgentThread(workspaceId: WorkspaceID(), title: "plan", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-fail", turnId: "turn-1", markdown: "1. Persist")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: thread.workspaceId!,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            proposedPlanRepo: proposedPlanRepo
        )
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/local/bin/codex"
        )]
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        try db.execute("DROP TABLE agent_proposed_plans;")

        await vm.implementLatestPlan()

        XCTAssertTrue(vm.statusMessage.contains("implementation state could not be saved"))
        XCTAssertNil(vm.latestProposedPlan?.implementedAtMs,
                     "the plan card must remain actionable when its durable implemented state did not commit")
    }

    func test_fullAccessSuppressesProposedPlanReviewAndAutoImplements() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-fullaccess-auto-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let runner = SlowStartRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let workspaceID = WorkspaceID()
        var thread = AgentThread(
            workspaceId: workspaceID,
            title: "full-access-plan",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .fullAccess
        )
        try threadRepo.upsert(thread)
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedRepo,
            proposedPlanRepo: proposedPlanRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vm)
        vm.selectThread(thread.id)
        vm.permissionMode = .fullAccess
        XCTAssertTrue(vm.suppressesProposedPlanReview,
                      "full access must suppress plan Approve/Reject review")

        // Start a long turn so auto-implement must queue rather than fail in-flight.
        vm.prompt = "plan while autonomous"
        Task { await vm.send() }
        await waitAsync("active run under full access") {
            vm.status == .running && vm.currentRunId != nil
        }

        vm.timeline.apply(.proposedPlan(AssistantProposedPlan(
            id: "auto-plan-1",
            turnId: "turn-1",
            markdown: "1. Inspect\n2. Patch"
        )))
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "auto-plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
        )
        XCTAssertNil(vm.reviewableProposedPlan,
                     "full access must not expose a reviewable proposed plan card")
        vm.scheduleFullAccessPlanAutoImplementIfNeeded()

        await waitAsync("auto-implement queues the plan prompt") {
            ((try? queuedRepo.list(threadId: thread.id)) ?? []).contains {
                $0.text.contains("Implement this proposed plan now")
            }
        }
        let queued = try queuedRepo.list(threadId: thread.id)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].interactionMode, .default)
        XCTAssertTrue(vm.queueStatusMessage?.contains("Queued") == true)
        XCTAssertFalse(vm.statusMessage.contains("in-flight"))
        // Dedup: second schedule must not enqueue again.
        vm.scheduleFullAccessPlanAutoImplementIfNeeded()
        XCTAssertEqual(try queuedRepo.list(threadId: thread.id).count, 1,
                       "auto-implement must not double-queue the same plan")
        vm.stop()
        await waitAsync("slow run stops") { runner.cancelled }
    }

    /// WHY: Pet / sidebar reopen calls selectThread. Full-access auto-implement
    /// must not fire on mere view open — that auto-sends "Implement this proposed
    /// plan now..." when the user only wanted to open Agent App.
    func test_selectThread_doesNotAutoImplementUnimplementedPlanUnderFullAccess() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-select-no-auto-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let runner = CapturingProviderRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "reopen-full-access",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .fullAccess
        )
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(
                id: "reopen-plan",
                turnId: "turn-1",
                markdown: "1. [completed] Phase\n2. [completed] Phase"
            )
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedRepo,
            proposedPlanRepo: proposedPlanRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vm)

        // Pet / openAgentThread path: selectThread rehydrates plans but must not send.
        vm.selectThread(thread.id)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(runner.prompts.count, 0,
                       "reopening a full-access thread must not auto-start implement-plan")
        XCTAssertEqual(try queuedRepo.list(threadId: thread.id).count, 0,
                       "reopening must not queue Implement this proposed plan now")
        XCTAssertFalse(
            runner.prompts.contains(where: { $0.contains("Implement this proposed plan now") }),
            "pet/open path must never inject the implement-plan prompt"
        )
        XCTAssertNotNil(vm.latestProposedPlan,
                        "the proposed plan must still be visible after reopen")
        XCTAssertTrue(vm.latestProposedPlan?.showsImplementationActions == true,
                      "unimplemented plan stays reviewable for explicit Approve/auto paths")
    }

    func test_supervisedKeepsProposedPlanReviewable() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-supervised-review-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "supervised-plan",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised
        )
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "sup-plan", turnId: "t1", markdown: "1. Review me")
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: AgentRunCoordinator(
                runRepo: AgentRunRepository(db: db),
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providers: [.codex: FakeProviderRunner(provider: .codex)]
            ),
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            proposedPlanRepo: proposedPlanRepo
        )
        installRunnableProviderFixtures(on: vm)
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        vm.permissionMode = .supervised
        XCTAssertFalse(vm.suppressesProposedPlanReview)
        XCTAssertNotNil(vm.reviewableProposedPlan)
        XCTAssertTrue(vm.reviewableProposedPlan?.showsImplementationActions == true)
    }

    func test_implementLatestPlanQueuesWhileProviderTurnIsRunning() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-implement-queue-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = SlowStartRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan-busy", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-queue", turnId: "turn-plan", markdown: "1. Inspect\n2. Patch")
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedRepo,
            proposedPlanRepo: proposedPlanRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vm)
        vm.selectThread(thread.id)

        vm.prompt = "produce plan while running"
        Task { await vm.send() }
        await waitAsync("plan thread becomes a real active run") {
            vm.status == .running && vm.currentRunId != nil
        }

        await vm.implementLatestPlan()

        let queued = try queuedRepo.list(threadId: thread.id)
        XCTAssertEqual(queued.count, 1,
                       "Approve must queue implementation while the plan-producing turn is still open")
        XCTAssertTrue(queued[0].text.contains("Implement this proposed plan now"),
                      "queued follow-up must be the plan implementation prompt, not a silent no-op")
        XCTAssertEqual(queued[0].interactionMode, .default,
                       "Approve must leave Plan mode when the queued turn eventually starts")
        XCTAssertTrue(vm.queueStatusMessage?.contains("Queued") == true,
                      "user must see that Approve was accepted into the queue instead of a hard start failure")
        XCTAssertFalse(vm.statusMessage.contains("in-flight"),
                       "Approve while running must not surface the adapter concurrent-turn error")
        let stored = try XCTUnwrap(proposedPlanRepo.list(threadId: thread.id).first { $0.plan.id == "plan-queue" })
        XCTAssertNotNil(stored.plan.implementedAtMs,
                        "user intent to implement is durable once Approve queues successfully")
        XCTAssertEqual(runner.prompts, ["produce plan while running"],
                       "Approve must not open a concurrent provider turn while one is already in flight")
        vm.stop()
        await waitAsync("slow run can still be stopped after plan Approve queueing") {
            runner.cancelled
        }
    }

    func test_rejectLatestPlanQueuesWhileProviderTurnIsRunning() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-reject-queue-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let runner = SlowStartRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan-reject", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-reject", turnId: "turn-plan", markdown: "1. Inspect")
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedRepo,
            proposedPlanRepo: proposedPlanRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vm)
        vm.selectThread(thread.id)

        vm.prompt = "plan still open"
        Task { await vm.send() }
        await waitAsync("reject path waits for active run") {
            vm.status == .running && vm.currentRunId != nil
        }

        await vm.rejectLatestPlan()

        let queued = try queuedRepo.list(threadId: thread.id)
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(queued[0].text.contains("Reject this proposed plan"))
        XCTAssertEqual(queued[0].interactionMode, .plan,
                       "Reject must keep Plan mode for the revised-plan turn")
        XCTAssertNil(try proposedPlanRepo.list(threadId: thread.id).first?.plan.implementedAtMs,
                     "Reject must not mark the plan implemented")
        vm.stop()
        await waitAsync("slow run stops after reject queueing") { runner.cancelled }
    }

    func test_sendKeepsVisibleDraftAndReportsFailureWhenDurableDraftDeletionFails() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-draft-delete-failure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let workspaceID = WorkspaceID()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: draftRepo
        )
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/local/bin/codex"
        )]
        vm.createThread(title: "draft failure")
        vm.prompt = "send exactly once"
        vm.promptWasEdited()
        try db.execute("DROP TABLE agent_thread_drafts;")

        await vm.send()

        XCTAssertEqual(vm.prompt, "send exactly once",
                       "a failed durable delete must not clear the visible recovery copy")
        XCTAssertTrue(vm.statusMessage.contains("draft cleanup failed"),
                      "the surface must not present silent send success when draft durability failed")
    }

    // WHY: send() normalizes `$goal` → `/goal` before startProviderRun. When
    // durable draft deletion fails after provider start, recovery must restore
    // the exact pre-normalization visible input — not the provider command.
    func test_sendKeepsExactPreNormalizationDraftWhenDurableDraftDeletionFailsAfterStart() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-draft-delete-norm-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let runner = CapturingProviderRunner(provider: .codex)
        let workspaceID = WorkspaceID()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: draftRepo
        )
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/local/bin/codex",
            slashCommands: ["/goal"]
        )]
        vm.createThread(title: "draft norm failure")
        let visibleInput = "  $goal ship the recovery fix  "
        vm.prompt = visibleInput
        vm.promptWasEdited()
        try db.execute("DROP TABLE agent_thread_drafts;")

        await vm.send()

        XCTAssertEqual(vm.prompt, visibleInput,
                       "draft-cleanup failure after start must restore the exact visible input, not the normalized /goal command")
        XCTAssertNotEqual(vm.prompt, "/goal ship the recovery fix",
                          "must not restore the provider-normalized form as the recovery draft")
        XCTAssertTrue(vm.statusMessage.contains("draft cleanup failed"),
                      "the surface must report draft durability failure")
        await waitAsync("provider received exactly one normalized start") {
            runner.prompts == ["/goal ship the recovery fix"]
        }
        XCTAssertEqual(runner.prompts, ["/goal ship the recovery fix"],
                       "provider must receive the normalized command once; recovery must not re-send")
        XCTAssertFalse(runner.prompts.contains(where: { $0.contains("$goal") }),
                       "literal $goal must not reach the provider")
    }

    func test_rejectLatestPlanStartsAPlanRevisionWithoutMarkingImplementation() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-reject-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan", provider: .grok, model: "grok-4.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "grok-plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.grok: FakeProviderRunner(provider: .grok)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            proposedPlanRepo: proposedPlanRepo
        )
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
            binaryPath: "/usr/local/bin/grok",
            interactionModesOverride: [.default, .plan],
            capabilitiesOverride: AgentProviderCapabilities(supportsStreaming: true, supportsPlanReview: true)
        )]
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()

        await vm.rejectLatestPlan()

        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertTrue(messages.contains {
            $0.role == .user && $0.content.contains("Reject this proposed plan") && $0.content.contains("Stay in Plan mode")
        }, "Reject must start a provider-backed revision turn, not only hide the plan card locally")
        let storedPlan = try XCTUnwrap(proposedPlanRepo.list(threadId: thread.id).first?.plan)
        XCTAssertNil(storedPlan.implementedAtMs,
                     "rejecting a plan must not mark it implemented")
    }

    func test_saveLatestProposedPlanWritesMarkdownFile() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-save-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let markdown = "# Fix Agent Freeze\n\n1. Inspect\n2. Patch"
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: markdown)
        )
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   proposedPlanRepo: proposedPlanRepo)
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()

        let plan = try XCTUnwrap(vm.latestProposedPlan,
                                 "opening a thread must rehydrate its durable proposed plan")
        let url = URL(fileURLWithPath: tmp).appendingPathComponent(plan.exportFileName)
        try vm.saveLatestProposedPlan(to: url)

        XCTAssertEqual(try String(contentsOf: url), markdown,
                       "saving a proposed plan must write the exact markdown artifact, not a truncated sidebar preview")
    }

    /// Regression: the VM defaulted to "gpt-5" — a dead id on codex
    /// 0.130.0, so a brand-new Codex thread's first run failed with no
    /// output. The default must be a model the CLI actually accepts.
    func test_defaultModel_isARealCodexModel() async throws {
        let (vm, _) = try makeVM()
        XCTAssertEqual(vm.model, AgentDefaultModelSelection.codexBuiltInDefault,
                       "fresh threads must start on the product's built-in codex default")
        await vm.loadModels()
        XCTAssertTrue(vm.availableModels.contains { $0.id == vm.model },
                      "the default model must be one the picker actually offers")
    }

    // F9: deleting a thread must evict its per-thread VM caches and the coordinator's
    // per-thread auto-continuation bookkeeping, which previously leaked one entry per
    // deleted thread for the life of the surface.
    @MainActor
    func test_deleteThread_evictsPerThreadVMCachesAndCoordinatorState() async throws {
        let (vm, threadRepo) = try makeVM()
        let a = AgentThread(title: "A", provider: .claude, model: "m")
        let b = AgentThread(title: "B", provider: .claude, model: "m")
        try threadRepo.upsert(a)
        try threadRepo.upsert(b)
        vm.reloadThreads()

        // Populate a per-thread VM cache: type a draft on A, then switch away so it
        // is stashed in composerDraftsByThread[A].
        vm.selectThread(a.id)
        vm.prompt = "unsent draft for A"
        vm.selectThread(b.id)
        // Seed the coordinator's per-thread auto-continuation state for A.
        vm.coordinator.seedAutoContinuationStateForTesting(a.id)
        vm.seedAdditionalThreadCachesForTesting(a.id)

        XCTAssertTrue(vm.threadCacheResidueForTesting.contains(a.id),
                      "precondition: A is present in a per-thread VM cache")
        XCTAssertTrue(vm.coordinator.autoContinuationThreadIdsForTesting.contains(a.id),
                      "precondition: A is present in coordinator auto-continuation state")

        await vm.deleteThread(a.id)

        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(a.id),
                       "deleting a thread must leave no residue in any per-thread VM cache (F9)")
        XCTAssertFalse(vm.coordinator.autoContinuationThreadIdsForTesting.contains(a.id),
                       "deleting a thread must drop its coordinator auto-continuation state (F9)")
    }

    /// PERF-MAC_AGENT-013: coordinator broadcasts are shared by Agent App
    /// surfaces. Reloading workspace A must not treat workspace B's cached event
    /// state as an automatically pruned local thread and forget B in the shared
    /// coordinator.
    func test_reloadThreads_preservesForeignWorkspaceCacheAndCoordinatorState() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-shared-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let workspaceA = WorkspaceID()
        let workspaceB = WorkspaceID()
        let vmA = AgentAppViewModel(
            workspaceID: workspaceA,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("attachments-a")),
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        let vmB = AgentAppViewModel(
            workspaceID: workspaceB,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("attachments-b")),
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vmA)
        installRunnableProviderFixtures(on: vmB)
        wireCanonicalThreadRead(vmA, repo: threadRepo)
        wireCanonicalThreadRead(vmB, repo: threadRepo)

        let threadA = AgentThread(workspaceId: workspaceA, title: "A", provider: .claude, model: "m")
        let threadB = AgentThread(workspaceId: workspaceB, title: "B", provider: .claude, model: "m")
        try threadRepo.upsert(threadA)
        try threadRepo.upsert(threadB)
        vmA.reloadThreads()
        vmB.reloadThreads()
        vmB.selectThread(threadB.id)
        vmB.prompt = "foreign draft"
        vmB.seedAdditionalThreadCachesForTesting(threadB.id)
        coordinator.seedAutoContinuationStateForTesting(threadB.id)

        // This is the real multi-workspace coordinator status path: A learns B's
        // workspace membership, rejects the status as foreign, but retains the
        // membership cache for future event filtering.
        vmA.runCoordinator(
            coordinator,
            didChangeStatus: .running,
            runId: AgentRunID(),
            threadId: threadB.id
        )
        await waitAsync("foreign coordinator status is filtered") {
            vmA.threadCacheResidueForTesting.contains(threadB.id)
        }
        vmA.handleQueueLifecycleEvent(
            kind: "agent.message.queue.failed",
            threadId: threadB.id.value.uuidString,
            message: "foreign queue status"
        )

        XCTAssertTrue(vmA.threadCacheResidueForTesting.contains(threadB.id),
                      "precondition: A holds B's foreign event/cache state")
        XCTAssertTrue(vmB.threadCacheResidueForTesting.contains(threadB.id),
                      "precondition: B owns its visible draft and per-thread caches")
        XCTAssertTrue(coordinator.autoContinuationThreadIdsForTesting.contains(threadB.id),
                      "precondition: B owns shared coordinator state")

        vmA.reloadThreads()

        XCTAssertTrue(vmA.threadCacheResidueForTesting.contains(threadB.id),
                      "reloading A must retain foreign event/cache state rather than classify B as locally pruned")
        XCTAssertTrue(vmB.threadCacheResidueForTesting.contains(threadB.id),
                      "reloading A must not change B's ViewModel caches")
        XCTAssertTrue(coordinator.autoContinuationThreadIdsForTesting.contains(threadB.id),
                      "reloading A must not forget B's shared coordinator state")
    }

    /// PERF-MAC_AGENT-013: a same-workspace coordinator event can arrive before
    /// the surface has loaded that thread into its rail. If another producer
    /// prunes the row before the debounced reload, workspace membership — not
    /// rail membership alone — must still identify the local cache as evictable.
    func test_reloadThreads_evictsLocalWorkspaceCacheLearnedBeforeRail() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-pre-rail-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let localWorkspace = WorkspaceID()
        let foreignWorkspace = WorkspaceID()
        let vm = AgentAppViewModel(
            workspaceID: localWorkspace,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("attachments")),
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vm)
        wireCanonicalThreadRead(vm, repo: threadRepo)

        var localVictim = AgentThread(workspaceId: localWorkspace, title: "local victim", provider: .codex, model: "m")
        localVictim.status = .completed
        localVictim.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var localSurvivor = AgentThread(workspaceId: localWorkspace, title: "local survivor", provider: .codex, model: "m")
        localSurvivor.status = .completed
        localSurvivor.updatedAt = localVictim.updatedAt.addingTimeInterval(1)
        let foreign = AgentThread(workspaceId: foreignWorkspace, title: "foreign", provider: .codex, model: "m")
        try threadRepo.upsert(localVictim)
        try threadRepo.upsert(localSurvivor)
        try threadRepo.upsert(foreign)
        XCTAssertTrue(vm.threads.isEmpty,
                      "precondition: neither post-init local row has entered this surface's rail")

        coordinator.seedAutoContinuationStateForTesting(localVictim.id)
        coordinator.seedAutoContinuationStateForTesting(foreign.id)
        // Hold the debounce open so the status callbacks can populate ownership
        // before this test performs the external prune deterministically.
        vm.scheduleReloadThreads(delayMilliseconds: 1_000)
        vm.runCoordinator(coordinator, didChangeStatus: .running, runId: AgentRunID(), threadId: localVictim.id)
        vm.runCoordinator(coordinator, didChangeStatus: .running, runId: AgentRunID(), threadId: foreign.id)
        await waitAsync("coordinator status caches local and foreign workspace membership") {
            vm.threadCacheResidueForTesting.contains(localVictim.id)
                && vm.threadCacheResidueForTesting.contains(foreign.id)
        }

        let pruned = try threadRepo.enforceWorkspaceThreadLimit(workspaceId: localWorkspace, limit: 1)
        XCTAssertEqual(pruned, [localVictim.id],
                       "precondition: another producer prunes the locally cached row before the rail reload")
        vm.reloadThreads()

        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(localVictim.id),
                       "reload must evict a locally owned cache learned before rail insertion")
        XCTAssertFalse(coordinator.autoContinuationThreadIdsForTesting.contains(localVictim.id),
                       "reload must forget coordinator state for that pre-rail local victim")
        XCTAssertTrue(vm.threadCacheResidueForTesting.contains(foreign.id),
                      "workspace-scoped reconciliation must preserve the foreign membership cache")
        XCTAssertTrue(coordinator.autoContinuationThreadIdsForTesting.contains(foreign.id),
                      "workspace-scoped reconciliation must preserve foreign coordinator state")
        vm.dispose()
    }

    /// PERF-MAC_AGENT-013: once cap enforcement commits its delete, a later
    /// thread-list failure must not keep the returned victims alive in memory.
    func test_reloadThreads_evictsCapVictimsBeforeSubsequentListFailure() async throws {
        let (vm, threadRepo) = try makeVM()
        var victim = AgentThread(workspaceId: vm.workspaceID, title: "old victim", provider: .claude, model: "m")
        victim.status = .completed
        victim.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try threadRepo.upsert(victim)
        vm.reloadThreads()
        vm.selectThread(victim.id)
        vm.prompt = "preserve this unsent draft"
        let attachmentURL = URL(fileURLWithPath: vm.cwd).appendingPathComponent("preserve.txt")
        try Data("preserve attachment".utf8).write(to: attachmentURL)
        let preservedAttachments = [AgentAttachment(path: attachmentURL.path, kind: .file)]
        vm.attachments = preservedAttachments
        vm.seedAdditionalThreadCachesForTesting(victim.id)
        vm.seedSelectedThreadChromeForTesting(victim.id)
        vm.seedRunThreadProjectionForTesting(victim.id)
        vm.coordinator.seedAutoContinuationStateForTesting(victim.id)

        for index in 0..<AgentThreadRepository.maxThreadsPerWorkspace {
            var thread = AgentThread(workspaceId: vm.workspaceID,
                                     title: "newer \(index)",
                                     provider: .claude,
                                     model: "m")
            thread.status = .completed
            thread.updatedAt = victim.updatedAt.addingTimeInterval(TimeInterval(index + 1))
            try threadRepo.upsert(thread)
        }
        XCTAssertEqual(try threadRepo.count(workspaceId: vm.workspaceID),
                       AgentThreadRepository.maxThreadsPerWorkspace + 1,
                       "precondition: the next reload must prune the selected cached victim")

        vm.setReloadThreadListForTesting {
            throw NSError(domain: "AgentAppViewModelTests.reload", code: 1)
        }
        vm.reloadThreads()
        vm.setReloadThreadListForTesting(nil)

        XCTAssertNil(try threadRepo.get(id: victim.id),
                     "cap enforcement must have committed the victim delete before list failed")
        XCTAssertFalse(vm.threads.contains(where: { $0.id == victim.id }),
                       "an authoritative cap victim must leave the rail before the fallible list")
        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(victim.id),
                       "a post-cap list failure must not retain any victim VM cache")
        XCTAssertFalse(vm.coordinator.autoContinuationThreadIdsForTesting.contains(victim.id),
                       "a post-cap list failure must not retain coordinator state")
        XCTAssertNil(vm.selectedThreadId,
                     "a selected cap victim must become unbound even when the rail list fails")
        vm.selectThread(victim.id)
        XCTAssertNil(vm.selectedThreadId,
                     "a deleted stale ID must not rebind the surface after the failed rail list")
        XCTAssertEqual(vm.prompt, "preserve this unsent draft",
                      "selection recovery must keep unsent user input in the fresh composer")
        XCTAssertEqual(vm.attachments, preservedAttachments,
                       "selection recovery must keep unsent attachments in the fresh composer")
        XCTAssertEqual(vm.subagentActivity, .empty,
                       "partial-failure recovery must synchronously clear deleted-thread Subagents chrome")
        XCTAssertTrue(vm.statusMessage.contains("Could not reload threads"),
                      "the partial list failure must still fail loud")
        XCTAssertTrue(vm.statusMessage.contains("your unsent draft was kept"),
                      "draft recovery and the reload error must coexist in the system strip")

        vm.createThread(title: "continue preserved draft")

        XCTAssertNotNil(vm.selectedThreadId,
                        "New Thread must bind the recovered fresh composer")
        XCTAssertEqual(vm.prompt, "preserve this unsent draft",
                       "New Thread must transfer the recovered prompt into its thread draft")
        XCTAssertEqual(vm.attachments, preservedAttachments,
                       "New Thread must transfer the recovered attachments into its thread draft")
        XCTAssertFalse(vm.statusMessage.contains("your unsent draft was kept"),
                       "the composer-scoped recovery notice must clear after binding a valid thread")
    }

    /// A workspace can be oversized while every row is active or belongs to
    /// recoverable work. Reload must fail loud and retain all rows rather than
    /// reporting a successful cap pass or publishing an unsafe deletion.
    func test_reloadThreads_hardCapFailurePreservesProtectedRowsAndPublishesNothing() throws {
        let (vm, threadRepo) = try makeVM()
        var protectedIDs = Set<AgentThreadID>()
        for index in 0...AgentThreadRepository.maxThreadsPerWorkspace {
            var thread = AgentThread(
                workspaceId: vm.workspaceID,
                title: "protected \(index)",
                provider: .codex,
                model: "m"
            )
            thread.status = .running
            try threadRepo.upsert(thread)
            protectedIDs.insert(thread.id)
        }
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        vm.onThreadLifecycle = { lifecycleEvents.append($0) }

        vm.reloadThreads()

        XCTAssertEqual(try threadRepo.count(workspaceId: vm.workspaceID),
                       AgentThreadRepository.maxThreadsPerWorkspace + 1)
        XCTAssertEqual(Set(try threadRepo.list(workspaceId: vm.workspaceID).map(\.id)), protectedIDs)
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a hard cap failure must not publish a deletion that did not commit")
        XCTAssertTrue(
            vm.statusMessage.localizedCaseInsensitiveContains("capacity"),
            "reload must fail loud when no protected row is eligible; got: \(vm.statusMessage)"
        )
    }

    /// WHY: the 21/20 banner must self-heal. Pinned terminal history is not a
    /// preferred victim, but overflow still drops the oldest so reload cannot
    /// strand the rail with "Could not reload threads".
    func test_reloadThreads_overCapFallsBackToOldestPinnedHistoryWithoutError() throws {
        let (vm, threadRepo) = try makeVM()
        var oldestPinned: AgentThread?
        for index in 0..<AgentThreadRepository.maxThreadsPerWorkspace {
            var thread = AgentThread(
                workspaceId: vm.workspaceID,
                title: "pinned \(index)",
                provider: .codex,
                model: "m"
            )
            thread.status = .completed
            thread.pinned = true
            thread.updatedAt = Date(timeIntervalSince1970: TimeInterval(index + 1))
            try threadRepo.upsert(thread)
            if index == 0 { oldestPinned = thread }
        }
        var running = AgentThread(
            workspaceId: vm.workspaceID,
            title: "running",
            provider: .codex,
            model: "m"
        )
        running.status = .running
        running.updatedAt = Date(timeIntervalSince1970: 100)
        try threadRepo.upsert(running)
        XCTAssertEqual(try threadRepo.count(workspaceId: vm.workspaceID),
                       AgentThreadRepository.maxThreadsPerWorkspace + 1)

        vm.reloadThreads()

        XCTAssertEqual(try threadRepo.count(workspaceId: vm.workspaceID),
                       AgentThreadRepository.maxThreadsPerWorkspace)
        XCTAssertNil(try threadRepo.get(id: try XCTUnwrap(oldestPinned).id),
                     "overflow must drop the oldest pinned history row")
        XCTAssertNotNil(try threadRepo.get(id: running.id),
                        "the live run must survive overflow reclaim")
        XCTAssertFalse(vm.statusMessage.contains("Could not reload threads"),
                       "reload must self-heal instead of painting the capacity banner; got: \(vm.statusMessage)")
        XCTAssertEqual(vm.threads.count, AgentThreadRepository.maxThreadsPerWorkspace)
    }

    /// Deleted-many is the existing EventBus contract for multiple victims. It
    /// must apply every authoritative ID before any subscriber reload can fail.
    func test_deletedManyLifecycleEvent_evictsEveryVictim() throws {
        let (vm, threadRepo) = try makeVM()
        let first = AgentThread(workspaceId: vm.workspaceID, title: "first victim", provider: .claude, model: "m")
        let second = AgentThread(workspaceId: vm.workspaceID, title: "second victim", provider: .claude, model: "m")
        try threadRepo.upsert(first)
        try threadRepo.upsert(second)
        vm.reloadThreads()

        for thread in [first, second] {
            vm.selectThread(thread.id)
            vm.prompt = "draft for \(thread.title)"
            vm.seedAdditionalThreadCachesForTesting(thread.id)
            vm.seedRunThreadProjectionForTesting(thread.id)
            vm.coordinator.seedAutoContinuationStateForTesting(thread.id)
        }
        let victimIDs = Set([first.id, second.id])
        XCTAssertEqual(vm.threadCacheResidueForTesting.intersection(victimIDs), victimIDs)

        vm.handleThreadLifecycleEvent(
            kind: "agent.thread.deleted_many",
            threadId: nil,
            threadIds: victimIDs.map { $0.value.uuidString }
        )

        XCTAssertTrue(vm.threadCacheResidueForTesting.isDisjoint(with: victimIDs),
                      "every deleted-many victim must leave all ViewModel caches and run projections")
        XCTAssertTrue(vm.coordinator.autoContinuationThreadIdsForTesting.isDisjoint(with: victimIDs),
                      "every deleted-many victim must leave shared coordinator state")
        XCTAssertTrue(vm.threads.allSatisfy { !victimIDs.contains($0.id) },
                      "every deleted-many victim must leave the rail synchronously")
        XCTAssertNil(vm.selectedThreadId,
                     "a selected deleted-many victim must recover to the fresh composer")
        XCTAssertEqual(vm.prompt, "draft for second victim",
                       "selected unsent input remains preserved during deleted-many recovery")
    }

    func test_selectThread_rejectsRepositoryMissingStaleRailRow() async throws {
        let (vm, threadRepo) = try makeVM()
        let deleted = AgentThread(workspaceId: vm.workspaceID, title: "stale rail", provider: .claude, model: "m")
        try threadRepo.upsert(deleted)
        vm.reloadThreads()
        XCTAssertTrue(vm.threads.contains(where: { $0.id == deleted.id }))
        try threadRepo.delete(id: deleted.id)
        vm.setReloadThreadListForTesting {
            throw NSError(domain: "AgentAppViewModelTests.staleRail", code: 1)
        }
        vm.reloadThreads()
        vm.setReloadThreadListForTesting(nil)
        XCTAssertTrue(vm.threads.contains(where: { $0.id == deleted.id }),
                      "precondition: the failed cross-process reconciliation leaves a stale rail snapshot")
        let reloadFailureStatus = vm.statusMessage
        vm.seedAdditionalThreadCachesForTesting(deleted.id)

        vm.selectThread(deleted.id, markRead: false)
        await vm.waitForSelectThreadHydrationForTesting()

        XCTAssertNil(vm.selectedThreadId,
                     "repository absence must win over stale in-memory rail membership")
        XCTAssertEqual(vm.statusMessage, reloadFailureStatus,
                       "a missing stale row must not overwrite the more relevant reload failure")
        XCTAssertFalse(vm.threads.contains(where: { $0.id == deleted.id }),
                       "a stale rail row the store no longer backs must be dropped, not left clickable")
        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(deleted.id),
                       "retiring an unbacked rail row must evict its per-thread caches")
    }

    func test_selectThread_rejectsRailRowThatNowBelongsToAnotherWorkspace() async throws {
        let (vm, threadRepo) = try makeVM()
        let moved = AgentThread(workspaceId: vm.workspaceID, title: "moved row", provider: .claude, model: "m")
        try threadRepo.upsert(moved)
        vm.reloadThreads()
        XCTAssertTrue(vm.threads.contains(where: { $0.id == moved.id }),
                      "precondition: the row is painted on this workspace's rail")
        // Durable rows never change workspace in place, so re-create the row under
        // another workspace: the rail snapshot is now the stale half of the pair.
        var reassigned = moved
        reassigned.workspaceId = WorkspaceID()
        try threadRepo.delete(id: moved.id)
        try threadRepo.upsert(reassigned)
        vm.seedAdditionalThreadCachesForTesting(moved.id)

        vm.selectThread(moved.id, markRead: false)
        await vm.waitForSelectThreadHydrationForTesting()

        XCTAssertNil(vm.selectedThreadId,
                     "a rail row whose durable owner is another workspace must not stay bound")
        XCTAssertTrue(vm.statusMessage.contains("another workspace"),
                      "cross-workspace rail rows must fail loud")
        XCTAssertFalse(vm.threads.contains(where: { $0.id == moved.id }),
                       "the cross-workspace rail row must be dropped from this surface")
        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(moved.id),
                       "a cross-workspace rail row must not keep per-thread caches alive")
    }

    func test_selectThread_repositoryFallbackCachesLocalOwnershipAndRejectsForeignRow() throws {
        let (vm, threadRepo) = try makeVM()
        let local = AgentThread(workspaceId: vm.workspaceID, title: "local fallback", provider: .claude, model: "m")
        let foreign = AgentThread(workspaceId: WorkspaceID(), title: "foreign fallback", provider: .claude, model: "m")
        try threadRepo.upsert(local)
        try threadRepo.upsert(foreign)
        XCTAssertTrue(vm.threads.isEmpty,
                      "precondition: both rows were inserted after the initial rail load")

        vm.selectThread(local.id, markRead: false)
        XCTAssertEqual(vm.selectedThreadId, local.id,
                       "a persisted local row must remain selectable before rail insertion")

        vm.selectThread(foreign.id, markRead: false)
        XCTAssertEqual(vm.selectedThreadId, local.id,
                       "a surface must not bind a repository row owned by another workspace")
        XCTAssertTrue(vm.statusMessage.contains("Could not open thread"),
                      "cross-workspace selection must fail loud")

        vm.seedAdditionalThreadCachesForTesting(local.id)
        vm.seedRunThreadProjectionForTesting(local.id)
        vm.coordinator.seedAutoContinuationStateForTesting(local.id)
        vm.coordinator.seedAutoContinuationStateForTesting(foreign.id)
        try threadRepo.delete(id: local.id)

        vm.reloadThreads()

        XCTAssertNil(vm.selectedThreadId,
                     "a selected fallback row deleted externally must recover to the fresh composer")
        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(local.id),
                       "fallback selection must cache local ownership so reload can evict every deleted-thread projection")
        XCTAssertFalse(vm.coordinator.autoContinuationThreadIdsForTesting.contains(local.id),
                       "deleted local fallback ownership must leave the shared coordinator")
        XCTAssertTrue(vm.coordinator.autoContinuationThreadIdsForTesting.contains(foreign.id),
                      "local reconciliation must preserve foreign coordinator ownership")
    }

    func test_queueLifecycleEvents_cacheOnlyLocalPreRailOwnershipAcrossReloadFailures() throws {
        let (vm, threadRepo) = try makeVM()
        let local = AgentThread(workspaceId: vm.workspaceID, title: "local queue", provider: .claude, model: "m")
        let foreign = AgentThread(workspaceId: WorkspaceID(), title: "foreign queue", provider: .claude, model: "m")
        try threadRepo.upsert(local)
        try threadRepo.upsert(foreign)
        vm.coordinator.seedAutoContinuationStateForTesting(foreign.id)
        XCTAssertTrue(vm.threads.isEmpty,
                      "precondition: queue events arrive before either row enters this rail")

        vm.handleQueueLifecycleEvent(
            kind: "agent.message.queue.failed",
            threadId: local.id.value.uuidString,
            message: "local queue failure"
        )
        vm.handleQueueLifecycleEvent(
            kind: "agent.message.queue.failed",
            threadId: foreign.id.value.uuidString,
            message: "foreign queue failure"
        )

        XCTAssertTrue(vm.threadCacheResidueForTesting.contains(local.id),
                      "a local pre-rail queue event must cache workspace ownership for later reconciliation")
        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(foreign.id),
                       "a foreign queue event must not retain ViewModel state")

        vm.setReloadThreadListForTesting {
            throw NSError(domain: "AgentAppViewModelTests.queuePreRail", code: 1)
        }
        vm.reloadThreads()
        vm.setReloadThreadListForTesting(nil)
        XCTAssertTrue(vm.threadCacheResidueForTesting.contains(local.id),
                      "a failed list must retain valid local queue state while its row still exists")
        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(foreign.id),
                       "a failed list must not manufacture foreign queue state")

        try threadRepo.delete(id: local.id)
        vm.reloadThreads()

        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(local.id),
                       "the next successful reload must evict the externally deleted local queue state")
        XCTAssertTrue(vm.coordinator.autoContinuationThreadIdsForTesting.contains(foreign.id),
                      "local queue reconciliation must not forget foreign coordinator ownership")
    }

    /// PERF-MAC_AGENT-013: a create/RPC producer can enforce the cap before an
    /// open surface reloads, discarding the victim IDs. The next scheduled reload
    /// must reconcile its known thread/cache IDs against SQLite, including a
    /// currently selected victim, rather than retaining stale drafts or state.
    func test_scheduledReloadThreads_evictsCachesForAutomaticallyPrunedThreads() async throws {
        var samples: [ThreadCapEvictionSample] = []
        for index in 0..<7 { // two warm-ups, then five measured repetitions
            let sample = try await runThreadCapEvictionWorkload()
            samples.append(sample)
            let phase = index < 2 ? "warmup" : "measured"
            print("CACHE_EVICTION_SAMPLE phase=\(phase) index=\(index + 1) db_victims=\(sample.databaseVictimCount) cache_victims=\(sample.cachedVictimCount) coordinator_victims=\(sample.coordinatorVictimCount) cached_composer_utf8_bytes=\(sample.cachedComposerUTF8Bytes) selected_prompt_before_utf8_bytes=\(sample.selectedPromptBeforeEvictionUTF8Bytes) selected_prompt_after_utf8_bytes=\(sample.selectedPromptAfterEvictionUTF8Bytes) selected_thread_bound_state_released=\(sample.selectedThreadBoundStateReleased) selected_recovered=\(sample.selectedThreadRecovered) automatic_prune_undo=\(sample.automaticPruneCreatedUndo) footprint_before_kb=\(sample.footprintBeforeReloadKB) footprint_settled_kb=\(sample.footprintAfterSettleKB)")
        }

        let measured = samples.dropFirst(2)
        XCTAssertEqual(measured.count, 5, "the performance proof requires five measured repetitions after warm-up")
        XCTAssertTrue(measured.allSatisfy { $0.databaseVictimCount == 0 },
                      "automatic reload must preserve SQLite's cap decision")
        XCTAssertTrue(measured.allSatisfy { $0.cachedVictimCount == 0 },
                      "automatic cap pruning must leave no pruned thread ID in VM caches")
        XCTAssertTrue(measured.allSatisfy { $0.coordinatorVictimCount == 0 },
                      "automatic cap pruning must also forget coordinator per-thread state")
        XCTAssertTrue(measured.allSatisfy { $0.cachedComposerUTF8Bytes == 0 },
                      "automatic cap pruning must release only large memory-only composer cache entries retained by pruned IDs")
        XCTAssertTrue(measured.allSatisfy(\.selectedThreadRecovered),
                      "a selected victim must recover the surface to its fresh, unbound state")
        XCTAssertTrue(measured.allSatisfy {
            $0.selectedPromptAfterEvictionUTF8Bytes == $0.selectedPromptBeforeEvictionUTF8Bytes
        }, "recovering a selected victim must preserve its unsent draft in the fresh composer")
        XCTAssertTrue(measured.allSatisfy(\.draftRecoveryNoticeShown),
                      "successful recovery must explain that the unsent draft was preserved")
        XCTAssertTrue(measured.allSatisfy(\.selectedThreadBoundStateReleased),
                      "recovering a selected victim must clear its transcript, queue, and provider snapshot state")
        XCTAssertTrue(measured.allSatisfy { !$0.automaticPruneCreatedUndo },
                      "automatic cap pruning must not create the explicit-delete undo affordance")
    }

    private struct ThreadCapEvictionSample {
        let databaseVictimCount: Int
        let cachedVictimCount: Int
        let coordinatorVictimCount: Int
        let cachedComposerUTF8Bytes: Int
        let selectedPromptBeforeEvictionUTF8Bytes: Int
        let selectedPromptAfterEvictionUTF8Bytes: Int
        let draftRecoveryNoticeShown: Bool
        let selectedThreadBoundStateReleased: Bool
        let selectedThreadRecovered: Bool
        let automaticPruneCreatedUndo: Bool
        let footprintBeforeReloadKB: Int
        let footprintAfterSettleKB: Int
    }

    private func runThreadCapEvictionWorkload() async throws -> ThreadCapEvictionSample {
        let (vm, threadRepo) = try makeVM()
        let victimCount = 3
        let cachedBytesPerVictim = 1_048_576
        let oldest = Date(timeIntervalSince1970: 1_700_000_000)
        var victims: [AgentThread] = []
        for index in 0..<victimCount {
            var victim = AgentThread(workspaceId: vm.workspaceID,
                                     title: "old victim \(index)",
                                     provider: .claude,
                                     model: "m")
            victim.status = .completed
            victim.updatedAt = oldest.addingTimeInterval(TimeInterval(index))
            try threadRepo.upsert(victim)
            victims.append(victim)
        }
        var survivor = AgentThread(workspaceId: vm.workspaceID,
                                   title: "survivor",
                                   provider: .claude,
                                   model: "m")
        survivor.status = .completed
        survivor.updatedAt = oldest.addingTimeInterval(TimeInterval(victimCount))
        try threadRepo.upsert(survivor)
        vm.reloadThreads()

        for (index, victim) in victims.enumerated() {
            vm.seedComposerDraftCacheForTesting(
                victim.id,
                providerInstanceId: AgentProvider.claude.rawValue,
                text: String(
                    repeating: index == 0 ? "A" : index == 1 ? "B" : "C",
                    count: cachedBytesPerVictim
                )
            )
            vm.coordinator.seedAutoContinuationStateForTesting(victim.id)
            vm.seedAdditionalThreadCachesForTesting(victim.id)
        }
        let victimIDs = Set(victims.map(\.id))
        XCTAssertEqual(vm.threadCacheResidueForTesting.intersection(victimIDs).count, victimCount,
                       "precondition: every future victim is present in a VM cache")
        XCTAssertEqual(vm.coordinator.autoContinuationThreadIdsForTesting.intersection(victimIDs).count, victimCount,
                       "precondition: every future victim is present in coordinator state")
        XCTAssertEqual(vm.cachedComposerDraftUTF8BytesForTesting, victimCount * cachedBytesPerVictim,
                       "precondition: the cache retains all unique memory-only entries before automatic pruning")
        for victim in victims {
            XCTAssertNil(
                try vm.draftRepo?.get(
                    threadId: victim.id,
                    providerInstanceId: AgentProvider.claude.rawValue
                ),
                "benchmark fixtures must not count durable user drafts as cap-reclaimable memory"
            )
        }

        // Keep a deleted thread selected. reloadThreads must publish the unbound
        // selection rather than leaving the surface bound to a row gone from SQLite.
        let selectedVictim = victims[0]
        vm.selectThread(selectedVictim.id)
        vm.seedAdditionalThreadCachesForTesting(selectedVictim.id)
        let selectedPromptBeforeEvictionUTF8Bytes = vm.prompt.utf8.count
        XCTAssertEqual(selectedPromptBeforeEvictionUTF8Bytes, cachedBytesPerVictim,
                       "precondition: the selected victim visibly retains its unique large cache entry")
        try vm.messageRepo.append(AgentMessage(threadId: selectedVictim.id,
                                               role: .assistant,
                                               content: "selected victim transcript"))
        await waitAsync("selected victim transcript loads") {
            vm.messages.contains { $0.threadId == selectedVictim.id }
        }
        vm.timeline.apply(.turnStarted(turnId: "selected-victim-turn"))
        vm.seedSelectedThreadChromeForTesting(selectedVictim.id)
        XCTAssertEqual(vm.queueStatusMessage, "test queue status",
                       "precondition: the selected victim owns the seeded queue status")
        XCTAssertNotNil(vm.providerThreadSnapshotLastConfirmedAt,
                        "precondition: the selected victim owns the seeded provider snapshot timestamp")
        var recoveredSelection: AgentThreadID? = selectedVictim.id
        vm.onSelectedThreadChanged = { recoveredSelection = $0 }

        // Simulate externally-created/scheduled threads. The scheduled reload below
        // is the automatic UI path that notices the oversized workspace and prunes it.
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 1) {
            var thread = AgentThread(workspaceId: vm.workspaceID,
                                     title: "new thread \(index)",
                                     provider: .claude,
                                     model: "m")
            thread.status = .completed
            try threadRepo.upsert(thread)
        }
        XCTAssertEqual(try threadRepo.count(workspaceId: vm.workspaceID),
                       AgentThreadRepository.maxThreadsPerWorkspace + victimCount,
                       "precondition: the automatic reload receives an oversized workspace")

        // This represents createThread/AppCommandRouter enforcing before the
        // surface sees a lifecycle event. Its return is intentionally discarded.
        let discardedPrunedThreadIDs = try threadRepo.enforceWorkspaceThreadLimit(workspaceId: vm.workspaceID)
        XCTAssertEqual(Set(discardedPrunedThreadIDs), victimIDs,
                       "precondition: the producer removes exactly the cached selected victims before reload")
        XCTAssertEqual(try threadRepo.count(workspaceId: vm.workspaceID),
                       AgentThreadRepository.maxThreadsPerWorkspace,
                       "precondition: reload must recover already-pruned IDs without a new cap result")

        let footprintBeforeReloadKB = currentProcessFootprintKB()
        vm.scheduleReloadThreads(delayMilliseconds: 1)
        await waitAsync("scheduled reload recovers the pre-pruned selected victim") {
            vm.selectedThreadId == nil
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        return ThreadCapEvictionSample(
            databaseVictimCount: victims.filter { (try? threadRepo.get(id: $0.id)) != nil }.count,
            cachedVictimCount: vm.threadCacheResidueForTesting.intersection(victimIDs).count,
            coordinatorVictimCount: vm.coordinator.autoContinuationThreadIdsForTesting.intersection(victimIDs).count,
            cachedComposerUTF8Bytes: vm.cachedComposerDraftUTF8BytesForTesting,
            selectedPromptBeforeEvictionUTF8Bytes: selectedPromptBeforeEvictionUTF8Bytes,
            selectedPromptAfterEvictionUTF8Bytes: vm.prompt.utf8.count,
            draftRecoveryNoticeShown: vm.statusMessage.contains("unsent draft was kept"),
            selectedThreadBoundStateReleased: vm.messages.isEmpty
                && vm.timeline.turns.isEmpty
                && vm.queueStatusMessage == nil
                && vm.providerThreadSnapshotLastConfirmedAt == nil
                && vm.subagentActivity == .empty,
            selectedThreadRecovered: vm.selectedThreadId == nil && recoveredSelection == nil,
            automaticPruneCreatedUndo: vm.pendingThreadDeletionUndo != nil,
            footprintBeforeReloadKB: footprintBeforeReloadKB,
            footprintAfterSettleKB: currentProcessFootprintKB()
        )
    }

    // F2: computeTurnRenderInputs is the single per-turn derivation that replaced the
    // re-run-every-body-pass logic in turnView. It must produce EXACTLY what the prior
    // composition of the (independently tested) helpers produced.
    func test_computeTurnRenderInputs_matchesPriorHelperComposition() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Let me read the config first.", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "tool", turnId: "turn-1", type: .commandExecution, state: .completed, summary: "swift test", output: "PASS", startedAtMs: 2_000, finishedAtMs: 4_000),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "All checks passed.", startedAtMs: 4_000, finishedAtMs: 5_000)
            ],
            finalAssistantMessage: "All checks passed.",
            finished: true
        )
        let inputs = AgentAppView.computeTurnRenderInputs(
            turn: turn, persistedAssistantTexts: [], proposedPlans: [], running: false,
            expandCompletedWork: true)

        let renderable = AgentAppView.renderableItems(in: turn)
        let expectedVisible = AgentAppView.turnRenderBlocks(
            AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable))
        let expectedWork = AgentAppView.turnRenderBlocks(
            AgentAppView.completedWorkItems(in: turn, renderableItems: renderable))

        XCTAssertEqual(inputs.visibleBlocks, expectedVisible,
                       "visible blocks must match turnRenderBlocks(completedVisibleAssistantItems)")
        XCTAssertEqual(inputs.completedWorkBlocks, expectedWork,
                       "work blocks must match turnRenderBlocks(completedWorkItems) — the finalIDs split is computed once but identically")
        XCTAssertEqual(inputs.completedWorkBlockCount, expectedWork.count,
                       "work block count must match the expanded work list")
        XCTAssertEqual(inputs.shouldRenderFinal,
                       AgentAppView.shouldRenderFinalAssistantMessage(turn, persistedAssistantTexts: []),
                       "shouldRenderFinal must match the helper — here the last item already renders the answer, so the separate final block is suppressed (no double answer)")
        XCTAssertFalse(inputs.shouldRenderFinal,
                       "when the final text equals the last visible assistant item, the separate final block must not render")
        XCTAssertEqual(inputs.hiddenLiveItemCount, 0, "finished turns hide nothing as live overflow")

        let collapsed = AgentAppView.computeTurnRenderInputs(
            turn: turn, persistedAssistantTexts: [], proposedPlans: [], running: false,
            expandCompletedWork: false)
        XCTAssertTrue(collapsed.completedWorkBlocks.isEmpty,
                      "collapsed finished work skips full block materialization")
        XCTAssertEqual(collapsed.completedWorkBlockCount, expectedWork.count,
                       "collapsed finished work still reports the correct step count")
    }

    func test_computeTurnRenderInputs_runningTurnKeepsLiveItemsAndNoFinal() {
        let turn = AssistantTurnSnapshot(
            turnId: "live",
            items: [AssistantItem(id: "t", turnId: "live", type: .tool, state: .streaming, startedAtMs: 1_000)],
            finished: false
        )
        let inputs = AgentAppView.computeTurnRenderInputs(
            turn: turn, persistedAssistantTexts: [], proposedPlans: [], running: true)
        // Chat parity: live tools live inside Work so far, never as outside rows.
        XCTAssertTrue(inputs.visibleBlocks.isEmpty,
                      "live turns paint no tool rows outside Work so far")
        XCTAssertEqual(inputs.completedWorkBlockCount, 1,
                       "the sole streaming tool still counts as Work so far · 1 step")
        XCTAssertTrue(inputs.completedWorkBlocks.isEmpty,
                      "collapsed disclosure stays count-only")
        XCTAssertFalse(inputs.shouldRenderFinal, "a running turn has no final answer yet")
    }

    func test_computeTurnRenderInputs_filtersPlanItemsWhenPlanCardPresent() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-p",
            items: [AssistantItem(id: "plan", turnId: "turn-p", type: .plan, state: .completed, body: "1. step", startedAtMs: 1_000, finishedAtMs: 2_000)],
            finished: true
        )
        let plan = AssistantProposedPlan(id: "plan-1", turnId: "turn-p", markdown: "1. step")
        let inputs = AgentAppView.computeTurnRenderInputs(
            turn: turn, persistedAssistantTexts: [], proposedPlans: [plan], running: false)
        XCTAssertEqual(inputs.turnPlans.map(\.id), ["plan-1"], "the turn's proposed plan card is surfaced")
        XCTAssertTrue(inputs.visibleBlocks.isEmpty,
                      "an inline plan item is suppressed when a proposed-plan card already renders it")
    }

    // F2: the finished-turn render signature must invalidate the memo when any external
    // dependency changes (turn items, persisted texts, proposed plans) and stay stable
    // otherwise — so finished turns are served from cache without going stale.
    func test_finishedTurnRenderSignature_invalidationSemantics() {
        let turn = AssistantTurnSnapshot(turnId: "t", items: [
            AssistantItem(id: "a", turnId: "t", type: .tool, startedAtMs: 0)
        ], finished: true)
        let base = AgentAppView.finishedTurnRenderSignature(turn: turn, assistantTextsKey: "m1|x", plansKey: "0|-")
        XCTAssertEqual(base, AgentAppView.finishedTurnRenderSignature(turn: turn, assistantTextsKey: "m1|x", plansKey: "0|-"),
                       "identical inputs must yield an identical signature (a cache hit)")

        let turn2 = AssistantTurnSnapshot(turnId: "t", items: turn.items + [
            AssistantItem(id: "b", turnId: "t", type: .tool, startedAtMs: 1)
        ], finished: true)
        XCTAssertNotEqual(base, AgentAppView.finishedTurnRenderSignature(turn: turn2, assistantTextsKey: "m1|x", plansKey: "0|-"),
                          "an added item must invalidate the cache")
        XCTAssertNotEqual(base, AgentAppView.finishedTurnRenderSignature(turn: turn, assistantTextsKey: "m2|y", plansKey: "0|-"),
                          "a persisted-message change must invalidate the cache (it changes the answer/worklog split)")
        XCTAssertNotEqual(base, AgentAppView.finishedTurnRenderSignature(turn: turn, assistantTextsKey: "m1|x", plansKey: "1|p"),
                          "a proposed-plan change must invalidate the cache")
    }

    // F1: a composer keystroke must publish the composer state ONLY, never the
    // transcript-bearing view model — otherwise the whole transcript subtree
    // re-evaluates on every keypress on a long thread (the reported lag).
    @MainActor
    func test_promptChange_publishesComposerStateNotViewModel() throws {
        let (vm, _) = try makeVM()
        var vmEmissions = 0
        var composerEmissions = 0
        let vmSub = vm.objectWillChange.sink { _ in vmEmissions += 1 }
        let composerSub = vm.composerState.objectWillChange.sink { _ in composerEmissions += 1 }
        defer { vmSub.cancel(); composerSub.cancel() }

        // Simulate two keystrokes via the same proxy the composer binding writes to.
        vm.prompt = "h"
        vm.prompt = "hi"

        XCTAssertEqual(vmEmissions, 0,
                       "typing must NOT republish AgentAppViewModel — that would re-evaluate the whole transcript body per keystroke (F1)")
        XCTAssertGreaterThanOrEqual(composerEmissions, 2,
                                    "each composer text change must publish the composer state so the composer subtree updates")
        XCTAssertEqual(vm.prompt, "hi", "the prompt proxy still reads/writes the composer text")
    }

    @MainActor
    func test_focusTick_publishesComposerStateNotViewModel() throws {
        // WHY: PF-12 — tab focus used to bump a @Published on the 78-field VM
        // and rebuild AgentAppView. Focus belongs on the composer object.
        let (vm, _) = try makeVM()
        var vmEmissions = 0
        var composerEmissions = 0
        let vmSub = vm.objectWillChange.sink { _ in vmEmissions += 1 }
        let composerSub = vm.composerState.objectWillChange.sink { _ in composerEmissions += 1 }
        defer { vmSub.cancel(); composerSub.cancel() }

        vm.focusTick &+= 1
        vm.focusTick &+= 1

        XCTAssertEqual(vmEmissions, 0, "focus() must not rebuild the Agent App transcript")
        XCTAssertGreaterThanOrEqual(composerEmissions, 2, "the composer must still observe focusTick")
        XCTAssertEqual(vm.focusTick, 2)
        XCTAssertEqual(vm.composerState.focusTick, 2)
    }

    @MainActor
    func test_softReselect_readsQueueOffMainAndDropsHiddenAndStale() async throws {
        // WHY: PF-20 — host refreshAgentSurfaces used to list the queue,
        // runStartedAt, and recoverable context on MainActor behind the writer.
        // Hidden tabs must skip the refresh; a thread switch must reject the stale apply.
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-soft-reselect-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let queuedMessageRepo = AgentQueuedMessageRepository(db: db)
        let workspaceID = WorkspaceID()
        let threadA = AgentThread(workspaceId: workspaceID, title: "A", provider: .codex, model: "gpt-5.5")
        let threadB = AgentThread(workspaceId: workspaceID, title: "B", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(threadA)
        try threadRepo.upsert(threadB)
        try queuedMessageRepo.upsert(AgentQueuedMessage(threadId: threadA.id, text: "queued on A"))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            queuedMessageRepo: queuedMessageRepo
        )
        installRunnableProviderFixtures(on: vm)
        wireCanonicalThreadRead(vm, repo: threadRepo)

        vm.selectThread(threadA.id)
        await vm.waitForSelectThreadHydrationForTesting()
        await vm.waitForSoftReselectDurableRefreshForTesting()
        XCTAssertEqual(vm.queuedMessages.map(\.text), ["queued on A"])

        PerfSwitchMetrics.resetForTesting()
        let before = vm.softReselectDurableRefreshCountForTesting
        for _ in 0..<20 {
            vm.selectThread(threadA.id, markRead: false)
        }
        await vm.waitForSoftReselectDurableRefreshForTesting()
        XCTAssertEqual(
            vm.softReselectDurableRefreshCountForTesting,
            before + 20,
            "each visible soft reselect still schedules the off-main bundle"
        )
        XCTAssertEqual(vm.queuedMessages.map(\.text), ["queued on A"])
        XCTAssertEqual(
            PerfSwitchMetrics.mainThreadSyncCountForTesting(),
            0,
            "soft reselect must not performSync on the main thread"
        )

        vm.setVisibility(.hidden)
        let hiddenBefore = vm.softReselectDurableRefreshCountForTesting
        vm.selectThread(threadA.id, markRead: false)
        XCTAssertEqual(
            vm.softReselectDurableRefreshCountForTesting,
            hiddenBefore,
            "hidden Agent App tabs must not soft-reselect SQLite"
        )
        vm.setVisibility(.visible)

        vm.selectThread(threadA.id, markRead: false)
        vm.selectThread(threadB.id)
        await vm.waitForSelectThreadHydrationForTesting()
        await vm.waitForSoftReselectDurableRefreshForTesting()
        XCTAssertEqual(vm.selectedThreadId, threadB.id)
        XCTAssertTrue(
            vm.queuedMessages.isEmpty,
            "a stale A soft-reselect bundle must not land on B"
        )
    }

    @MainActor
    func test_paintedTimelineByThread_evictsLRUAndDeletedThreads() throws {
        // WHY (AA-07 / F3): paintedTimelineByThread grew for every thread
        // visited in the session. Cap at 2 plus the selected/live run, and
        // drop deleted ids. 3→2 cuts peak switch-cache capacity by ~33%.
        let (vm, repo) = try makeVM()
        var ids: [AgentThreadID] = []
        for index in 0..<5 {
            let thread = AgentThread(
                workspaceId: vm.workspaceID,
                title: "t\(index)",
                provider: .codex,
                model: "gpt-5.5"
            )
            try repo.upsert(thread)
            ids.append(thread.id)
            vm.selectThread(thread.id)
        }
        XCTAssertLessThanOrEqual(
            vm.paintedTimelineCountForTesting,
            2,
            "visiting 5 threads must not keep every painted timeline"
        )

        vm.selectThread(ids[0])
        XCTAssertLessThanOrEqual(vm.paintedTimelineCountForTesting, 2)
    }

    @MainActor
    func test_paintedTimelineLimit_retentionEstimate_3to2() {
        // WHY: document the F3 inactive-cache capacity cut. Selected/live
        // timelines can still remain above this inactive bound.
        let prior = 3
        let limit = AgentAppViewModel.paintedTimelineLimit
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertEqual(limit, 2)
        XCTAssertEqual(reduction, 1.0 / 3.0, accuracy: 0.001)
    }

    @MainActor
    func test_didChangeStatus_doesNotReloadThreadList() throws {
        // WHY (X-02): every run status hop used to list the workspace rail
        // (ISO parse × N) in idle with 5 runs.
        let (vm, repo) = try makeVM()
        let thread = AgentThread(workspaceId: vm.workspaceID, title: "live", provider: .codex, model: "gpt-5.5")
        try repo.upsert(thread)
        vm.selectThread(thread.id)
        let before = repo.durableListCountForTesting
        vm.runCoordinator(
            vm.coordinator,
            didChangeStatus: .running,
            runId: AgentRunID(),
            threadId: thread.id
        )
        XCTAssertEqual(
            repo.durableListCountForTesting,
            before,
            "status-only events must patch the in-memory rail, not re-list SQLite"
        )
    }

    // F5: the single-pass cap+budget that replaced `map(cap) + applyBodyBudget` on the
    // thread-open path must be byte-for-byte equivalent to the prior two-pass version.
    func test_cappedRowsWithinBudget_matchesMapThenBudgetComposition() {
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        func msg(_ i: Int, _ content: String) -> AgentMessage {
            AgentMessage(threadId: AgentThreadID(), role: .user, content: content, createdAt: base.addingTimeInterval(Double(i)))
        }
        func reference(_ rows: [AgentMessage], budget: Int) -> (rows: [AgentMessage], blanked: Int) {
            AgentAppViewModel.applyBodyBudget(rows.map { var m = $0; m.content = AssistantTimelineState.cappedText($0.content); return m }, budget: budget)
        }

        // Under budget: caps each body, blanks nothing.
        let small = (0..<5).map { msg($0, "row-\($0)") }
        let fused = AgentAppViewModel.cappedRowsWithinBudget(small, budget: 1_000_000)
        let ref = reference(small, budget: 1_000_000)
        XCTAssertEqual(fused.blanked, 0)
        XCTAssertEqual(fused.rows.map(\.content), ref.rows.map(\.content),
                       "single-pass cap+budget must equal map(cap)+applyBodyBudget under budget")

        // Over budget: blanks the oldest bodies, identically.
        let big = (0..<4).map { msg($0, String(repeating: "x", count: 10)) }
        let fusedBig = AgentAppViewModel.cappedRowsWithinBudget(big, budget: 25)
        let refBig = reference(big, budget: 25)
        XCTAssertGreaterThan(fusedBig.blanked, 0, "a pathological thread must blank oldest bodies")
        XCTAssertEqual(fusedBig.blanked, refBig.blanked)
        XCTAssertEqual(fusedBig.rows.map(\.content), refBig.rows.map(\.content),
                       "single-pass cap+budget must equal map(cap)+applyBodyBudget over budget (oldest blanked)")
    }

    func test_mentionCatalogSurvivesKeystrokesAndPaintPassesWithoutSQLite() throws {
        // WHY (perf AA-01): 20 keystrokes + 10 transcript paint passes used to cost
        // >=30 synchronous botStore.list() trips on the main thread (composer
        // suggestions recompute per keystroke, the transcript body re-reads the
        // catalog per paint pass) — each waiting behind the stream-persist writer.
        // With the router serving BotStore.listCached(), the whole burst must cost
        // exactly one query, and a bot created later must still appear in suggestions.
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let botStore = BotStore(db: db)
        try botStore.create(name: "Piper", title: "Scout", description: "", handle: "piper")

        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp, coordinator: coord, threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")),
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        // Same wiring AppCommandRouter.configureAgentAppBotMentions installs.
        vm.mentionableBotsProvider = { (try? botStore.listCached()) ?? [] }

        // 20 keystrokes: each prompt write recomputes composerSuggestions.
        for index in 0..<20 {
            vm.prompt = "typing \(index)"
            _ = vm.composerSuggestions
        }
        // 10 transcript paint passes: the body re-reads the mention catalog.
        for _ in 0..<10 { _ = vm.mentionableBotsProvider() }

        XCTAssertEqual(
            botStore.listQueryCountForTesting, 1,
            "30 catalog reads during typing/painting must hit SQLite exactly once"
        )

        // A bot created later appears on the next suggestion pass (cache refresh).
        try botStore.create(name: "Rio", title: "Ops", description: "", handle: "rio")
        let bots = vm.mentionableBotsProvider()
        XCTAssertTrue(bots.contains { $0.name == "Rio" },
                      "a bot created after the cache must appear in the next catalog read")
        XCTAssertEqual(botStore.listQueryCountForTesting, 2)
    }

    func test_hiddenSurface_coalescesStreamPublishesAndStopsTicks() async throws {
        // WHY: PF-10 — a hidden Agent App tab with a live run used to flush and
        // tick at 30 Hz. Hidden must keep reducing so reveal matches a tab that
        // stayed visible, but must not publish every token or schedule ticks.
        let (hidden, hiddenRepo) = try makeVM()
        let (visible, visibleRepo) = try makeVM()
        let hiddenThread = AgentThread(
            workspaceId: hidden.workspaceID,
            title: "live",
            provider: .codex,
            model: "gpt-5.5",
            status: .running
        )
        let visibleThread = AgentThread(
            workspaceId: visible.workspaceID,
            title: "live",
            provider: .codex,
            model: "gpt-5.5",
            status: .running
        )
        try hiddenRepo.upsert(hiddenThread)
        try visibleRepo.upsert(visibleThread)
        hidden.selectThread(hiddenThread.id)
        visible.selectThread(visibleThread.id)
        await hidden.waitForSelectThreadHydrationForTesting()
        await visible.waitForSelectThreadHydrationForTesting()

        hidden.hiddenTimelinePublishIntervalForTesting = 3_600
        hidden.setVisibility(.hidden)
        XCTAssertTrue(hidden.isHiddenFromSurface)

        pumpStream(on: hidden, threadId: hiddenThread.id, run: AgentRunID(), deltas: 200)
        pumpStream(on: visible, threadId: visibleThread.id, run: AgentRunID(), deltas: 200)
        await settleStream(hidden)
        await settleStream(visible)

        XCTAssertTrue(
            hidden.timeline.turns.isEmpty,
            "hide must drop the published timeline so the tab does not retain two trees"
        )
        XCTAssertFalse(
            AgentAppView.shouldShowEmptyConversation(
                messagesEmpty: hidden.messages.isEmpty,
                turnsEmpty: hidden.timeline.turns.isEmpty,
                hasTimelineError: hidden.timeline.error != nil,
                isHidden: hidden.isHiddenFromSurface,
                messagePageLoadState: .idle
            ),
            "a hidden live run must not be treated as an empty conversation"
        )
        XCTAssertEqual(
            hidden.timelineTickScheduleCountForTesting,
            0,
            "hidden surfaces must not arm the 33 ms transcript tick"
        )
        XCTAssertLessThanOrEqual(
            hidden.hiddenTimelinePublishCountForTesting,
            1,
            "hidden stream must coalesce publishes to at most one per interval"
        )
        XCTAssertGreaterThan(
            visible.timelineTickScheduleCountForTesting,
            0,
            "the visible twin must still tick so the comparison is honest"
        )

        hidden.setVisibility(.visible)
        XCTAssertEqual(
            hidden.timeline.turns.map(\.turnId),
            visible.timeline.turns.map(\.turnId),
            "revealing a hidden tab must match a surface that stayed visible"
        )
        XCTAssertEqual(
            hidden.timeline.turns.map { $0.items.map(\.body) },
            visible.timeline.turns.map { $0.items.map(\.body) }
        )
    }

    func test_2000DeltaDistillReplyPublishesBoundedAndKeepsFullText() async throws {
        // WHY (Distill terminal parity): a 2,000-token Distill reply must cost a
        // bounded number of transcript publishes, not one per token, and every
        // delta must land in order.
        let (vm, repo) = try makeVM()
        let thread = AgentThread(workspaceId: vm.workspaceID, title: "distill budget",
                                 provider: .distill, model: "meta/muse", status: .running)
        try repo.upsert(thread)
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        var publishes = 0
        let sink = vm.transcriptState.$timeline.dropFirst().sink { _ in publishes += 1 }
        defer { sink.cancel() }
        let run = AgentRunID()
        vm.runCoordinator(vm.coordinator, didReceive: .turnStarted(turnId: "t"), run: run, threadId: thread.id)
        vm.runCoordinator(vm.coordinator, didReceive: .itemStarted(item: AssistantItem(id: "a", turnId: "t", type: .assistantMessage, startedAtMs: 1)), run: run, threadId: thread.id)
        let clock = ContinuousClock()
        let memBefore = perfPhysFootprintBytes()
        let start = clock.now
        for i in 0..<2_000 {
            vm.runCoordinator(vm.coordinator, didReceive: .itemDelta(itemId: "a", bodyAppend: "w\(i) ", outputAppend: nil, summary: nil), run: run, threadId: thread.id)
            if i % 50 == 49 { await Task.yield() }
        }
        let sentAt = clock.now
        for _ in 0..<5_000 {
            if vm.timeline.turns.first?.items.first?.body.hasSuffix("w1999 ") == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let elapsed = start.duration(to: clock.now)
        let tailLag = sentAt.duration(to: clock.now)
        let body = vm.timeline.turns.first?.items.first?.body ?? ""
        print("PERF vmStream tailLag=\(tailLag)")
        let memGrowth = Int64(perfPhysFootprintBytes()) - Int64(memBefore)
        print("PERF vmStream deltas=2000 timelinePublishes=\(publishes) elapsed=\(elapsed) memGrowthKB=\(memGrowth / 1024)")
        XCTAssertLessThan(memGrowth, 64 * 1024 * 1024, "a ~16 KB streamed reply must not grow resident memory by tens of MB")
        XCTAssertTrue(body.hasPrefix("w0 ") && body.hasSuffix("w1999 "), "every delta must land in order (turns=\(vm.timeline.turns.map { "\($0.turnId):\($0.items.count)" }) len=\(body.count) tail=\(body.suffix(30)) head=\(body.prefix(12)))")
        XCTAssertLessThan(publishes, 200, "deltas must coalesce into batched publishes, not one per token")
        XCTAssertLessThan(tailLag, .milliseconds(100), "the last token must paint right after the provider sends it, not ~40 hops later")
    }

    func test_hiddenSurface_dropsStaleStreamAfterThreadSwitch() async throws {
        // WHY: hide → switch thread → show must not paint the leaving thread.
        let (vm, repo) = try makeVM()
        let first = AgentThread(
            workspaceId: vm.workspaceID,
            title: "first",
            provider: .codex,
            model: "gpt-5.5",
            status: .running
        )
        let second = AgentThread(
            workspaceId: vm.workspaceID,
            title: "second",
            provider: .codex,
            model: "gpt-5.5"
        )
        try repo.upsert(first)
        try repo.upsert(second)
        vm.selectThread(first.id)
        await vm.waitForSelectThreadHydrationForTesting()
        vm.setVisibility(.hidden)
        pumpStream(on: vm, threadId: first.id, run: AgentRunID(), deltas: 20)
        await settleStream(vm)
        vm.selectThread(second.id)
        await vm.waitForSelectThreadHydrationForTesting()
        vm.setVisibility(.visible)
        XCTAssertFalse(
            vm.timeline.turns.contains { turn in
                turn.items.contains { $0.body.contains("hidden-delta") }
            },
            "a thread switch while hidden must drop the leaving thread's coalesced stream"
        )
    }

    private func pumpStream(
        on vm: AgentAppViewModel,
        threadId: AgentThreadID,
        run: AgentRunID,
        deltas: Int
    ) {
        vm.runCoordinator(
            vm.coordinator,
            didReceive: .turnStarted(turnId: "turn-hidden"),
            run: run,
            threadId: threadId
        )
        vm.runCoordinator(
            vm.coordinator,
            didReceive: .itemStarted(
                item: AssistantItem(
                    id: "asst",
                    turnId: "turn-hidden",
                    type: .assistantMessage,
                    startedAtMs: 1
                )
            ),
            run: run,
            threadId: threadId
        )
        for _ in 0..<deltas {
            vm.runCoordinator(
                vm.coordinator,
                didReceive: .itemDelta(
                    itemId: "asst",
                    bodyAppend: "hidden-delta",
                    outputAppend: nil,
                    summary: nil
                ),
                run: run,
                threadId: threadId
            )
        }
    }

    private func settleStream(_ vm: AgentAppViewModel) async {
        for _ in 0..<40 {
            await Task.yield()
            if !vm.timeline.turns.isEmpty { return }
        }
    }
}

private final class SlowStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var _cancelled = false
    private var _prompts: [String] = []
    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    var prompts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _prompts
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        _prompts.append(request.prompt)
        lock.unlock()
        onEvent(.status(.running))
        try? await Task.sleep(nanoseconds: 100_000_000)
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.lock.lock()
            self?._cancelled = true
            self?.lock.unlock()
        }
    }
}

/// Refuses the provider start so the prepare-window state machine can be checked
/// on its error exit (the "Loading…" line must not outlive a failed start).
private final class ThrowingStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        throw AgentProviderAdapterError.unsupported("provider start refused in test")
    }
}

private final class PendingStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var _enteredStart = false
    private var _cancelled = false

    var enteredStart: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enteredStart
    }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        await withCheckedContinuation { continuation in
            lock.lock()
            _enteredStart = true
            startContinuation = continuation
            lock.unlock()
        }
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.lock.lock()
            self?._cancelled = true
            self?.lock.unlock()
        }
    }

    func releaseStart() {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class FailingCallbackRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        throw AgentProviderAdapterError.unsupported("dead approval callback")
    }

    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("dead user-input callback")
    }
}

private final class HoldOpenStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            let turnId = UUID().uuidString
            let itemId = UUID().uuidString
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, startedAtMs: now))))
            onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: "partial stream", outputAppend: nil, summary: nil)))
            try? await Task.sleep(nanoseconds: 500_000_000)
            onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "partial stream final")))
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: "partial stream final", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class LongRunStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    let turns: Int
    let runtimeEvents: Int

    init(turns: Int, runtimeEvents: Int) {
        self.turns = turns
        self.runtimeEvents = runtimeEvents
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let turns = self.turns
        let runtimeEvents = self.runtimeEvents
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            for index in 0..<turns {
                let turnId = "long-turn-\(index)"
                let itemId = "long-item-\(index)"
                onEvent(.event(.turnStarted(turnId: turnId)))
                onEvent(.event(.itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: turnId,
                    type: .commandExecution,
                    summary: "stress command \(index)",
                    startedAtMs: startedAt + Int64(index)
                ))))
                onEvent(.event(.itemProgress(itemId: itemId, progress: Double(index + 1) / Double(max(turns, 1)))))
                onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: "ok \(index)\n", summary: nil)))
                onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
                onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "LONG_ASSISTANT_\(index)")))
            }
            for index in 0..<runtimeEvents {
                onEvent(.event(.providerRuntime(ProviderRuntimeEvent(
                    id: "runtime-\(index)",
                    provider: .codex,
                    source: "long-run-test",
                    method: "stress.event",
                    providerTurnId: "long-turn-\(min(index, max(turns - 1, 0)))",
                    payloadJSON: "{\"index\":\(index)}",
                    receivedAtMs: startedAt + Int64(index)
                ))))
            }
            onEvent(.event(.tokenUsage(AssistantTokenUsage(
                inputTokens: 300_000,
                outputTokens: 20_000,
                totalTokens: 320_000,
                contextWindow: 400_000
            ))))
            onEvent(.event(.contextCompaction(summary: "long-run history compacted")))
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: "LONG_ASSISTANT_\(max(turns - 1, 0))", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class ContextTelemetryRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let turnId = "context-turn"
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.tokenUsage(AssistantTokenUsage(
                inputTokens: 400,
                outputTokens: 100,
                totalTokens: 500,
                contextWindow: 1_000,
                compactsAutomatically: true,
                contextTokens: 500
            ))))
            onEvent(.event(.contextCompaction(summary: "older turns summarized")))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "context ready")))
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: "context ready", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class ImmediateStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let turnId = UUID().uuidString
        let itemId = UUID().uuidString
        let providerThreadId = request.providerThreadId ?? UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        onEvent(.status(.running))
        onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
        onEvent(.event(.turnStarted(turnId: turnId)))
        onEvent(.event(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, startedAtMs: now))))
        onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: "partial stream", outputAppend: nil, summary: nil)))
        onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
        onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "partial stream final")))
        onEvent(.status(.completed))
        onEvent(.finished(.completed, finalMessage: "partial stream final", providerThreadId: providerThreadId))
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class CapturingProviderAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    let forkSafety: AgentProviderForkSafety
    let readEvents: [AssistantEvent]
    let responseDelayNanoseconds: UInt64
    let forkThreadResult: String
    private let lock = NSLock()
    private var _lastRequestResponse: (threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse)?
    private var _lastUserInputResponse: (threadId: AgentThreadID, requestId: String, text: String)?
    private var _cancelledUserInputs: [(threadId: AgentThreadID, requestId: String)] = []
    private var _stopSessionCount = 0
    private var _forkedThreadIds: [AgentThreadID] = []
    private var _sentTurns: [(threadId: AgentThreadID, providerThreadId: String?, prompt: String)] = []

    var lastRequestResponse: (threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse)? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestResponse
    }

    var lastUserInputResponse: (threadId: AgentThreadID, requestId: String, text: String)? {
        lock.lock(); defer { lock.unlock() }
        return _lastUserInputResponse
    }

    var cancelledUserInputs: [(threadId: AgentThreadID, requestId: String)] {
        lock.lock(); defer { lock.unlock() }
        return _cancelledUserInputs
    }

    var stopSessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopSessionCount
    }

    var forkedThreadIds: [AgentThreadID] {
        lock.lock(); defer { lock.unlock() }
        return _forkedThreadIds
    }

    var sentTurns: [(threadId: AgentThreadID, providerThreadId: String?, prompt: String)] {
        lock.lock(); defer { lock.unlock() }
        return _sentTurns
    }

    init(
        provider: AgentProvider,
        readEvents: [AssistantEvent] = [],
        responseDelayNanoseconds: UInt64 = 0,
        forkThreadResult: String = "provider-child",
        forkSafety: AgentProviderForkSafety = .unsupported
    ) {
        self.provider = provider
        self.readEvents = readEvents
        self.responseDelayNanoseconds = responseDelayNanoseconds
        self.forkThreadResult = forkThreadResult
        self.forkSafety = forkSafety
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        recordTurn(request)
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        recordTurn(request)
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        if responseDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: responseDelayNanoseconds)
        }
        lock.lock()
        _lastRequestResponse = (threadId, requestId, response)
        lock.unlock()
    }
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        lock.lock()
        _lastUserInputResponse = (threadId, requestId, text)
        lock.unlock()
    }
    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        lock.lock()
        _cancelledUserInputs.append((threadId, requestId))
        lock.unlock()
    }
    func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        _stopSessionCount += 1
        lock.unlock()
    }
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { true }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { readEvents }
    func forkThread(threadId: AgentThreadID) async throws -> String {
        lock.withLock { _forkedThreadIds.append(threadId) }
        return forkThreadResult
    }
    func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        lock.withLock { _forkedThreadIds.append(request.sourceThreadId) }
        return forkThreadResult
    }
    func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws {}
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}

    private func recordTurn(_ request: AgentRunRequest) {
        lock.lock()
        _sentTurns.append((request.threadId, request.providerThreadId, request.prompt))
        lock.unlock()
    }
}

private final class CapturingProviderRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let completionDelayNanoseconds: UInt64
    private let finalMessage: String?
    private let lock = NSLock()
    private var _prompts: [String] = []
    private var _interactionModes: [AgentInteractionMode] = []
    private var _attachments: [[AgentAttachment]] = []
    private var _providerInstanceIds: [String?] = []
    private var _providerBinaries: [String?] = []
    private var _environments: [[String: String]] = []
    private var _requestProviderThreadIds: [String?] = []
    private var _requests: [AgentRunRequest] = []

    var requests: [AgentRunRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var prompts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _prompts
    }
    var interactionModes: [AgentInteractionMode] {
        lock.lock(); defer { lock.unlock() }
        return _interactionModes
    }
    var attachments: [[AgentAttachment]] {
        lock.lock(); defer { lock.unlock() }
        return _attachments
    }
    var providerInstanceIds: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _providerInstanceIds
    }
    var providerBinaries: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _providerBinaries
    }
    var environments: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return _environments
    }
    var requestProviderThreadIds: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _requestProviderThreadIds
    }
    init(provider: AgentProvider, completionDelayNanoseconds: UInt64 = 0, finalMessage: String? = nil) {
        self.provider = provider
        self.completionDelayNanoseconds = completionDelayNanoseconds
        self.finalMessage = finalMessage
    }

    func listModels() async -> [AgentModelDescriptor] {
        [AgentModelDescriptor(id: "capture-model", label: "Capture Model", provider: provider)]
    }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        _requests.append(request)
        _prompts.append(request.prompt)
        _interactionModes.append(request.interactionMode)
        _attachments.append(request.attachments)
        _providerInstanceIds.append(request.providerInstanceId)
        _providerBinaries.append(request.providerBinary)
        _environments.append(request.environment)
        _requestProviderThreadIds.append(request.providerThreadId)
        lock.unlock()
        let completionDelayNanoseconds = self.completionDelayNanoseconds
        Task.detached {
            if completionDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: completionDelayNanoseconds)
            }
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: self.finalMessage, providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

