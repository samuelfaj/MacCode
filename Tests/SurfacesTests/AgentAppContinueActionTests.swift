import XCTest
@testable import Surfaces
import AgentRuntime
import CoreModel
import Persistence

/// Tests for UX-MAC_AGENT-CONTINUE: showsContinueAction seam.
///
/// WHY: a relaunch-interrupted thread must be one-click resumable via the
/// inline Continue action. The pure seam is tested in isolation so the
/// preconditions are precisely expressed and cannot regress silently.
///
/// showsContinueAction(hasRecoverableContext:runActive:) must return:
///   true  when the thread has a recoverable context AND no run is active
///   false when the run is already active (Continue would start a duplicate run)
///   false when there is no recoverable context (nothing to resume)
@MainActor
final class AgentAppContinueActionTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }


    // MARK: - showsContinueAction seam

    /// WHY: the primary case -- a relaunch-interrupted thread with a saved
    /// resume cursor and no run in flight must show the Continue button so
    /// the user can resume without retyping.
    func test_showsContinueAction_recoverableAndNotRunning_returnsTrue() {
        XCTAssertTrue(
            AgentAppViewModel.showsContinueAction(hasRecoverableContext: true, runActive: false),
            "Continue must be shown when the thread has a recoverable context and no run is active"
        )
    }

    /// WHY: if a run is already active the thread is resuming; showing Continue
    /// at the same time would let the user start a duplicate run on the same
    /// provider session.
    func test_showsContinueAction_recoverableButRunActive_returnsFalse() {
        XCTAssertFalse(
            AgentAppViewModel.showsContinueAction(hasRecoverableContext: true, runActive: true),
            "Continue must be hidden while a run is already active on this thread"
        )
    }

    /// WHY: without a recoverable context there is nothing for Continue to
    /// resume -- showing the button would produce a no-op or error.
    func test_showsContinueAction_noRecoverableContext_returnsFalse() {
        XCTAssertFalse(
            AgentAppViewModel.showsContinueAction(hasRecoverableContext: false, runActive: false),
            "Continue must be hidden when the thread has no recoverable provider session"
        )
    }

    /// WHY: the worst-case combination -- both guards false -- must also return
    /// false; the function must never produce true when context is absent.
    func test_showsContinueAction_noRecoverableAndRunActive_returnsFalse() {
        XCTAssertFalse(
            AgentAppViewModel.showsContinueAction(hasRecoverableContext: false, runActive: true),
            "Continue must be hidden when there is no recoverable context and a run is active"
        )
    }

    func test_interruptedRecoverableThreadDefersProviderSnapshotUntilContinueOwnsRecovery() {
        XCTAssertFalse(AgentAppViewModel.shouldReadProviderSnapshot(hasRecoverableContext: true),
                       "an interrupted thread must not race background snapshot recovery against Continue")
        XCTAssertTrue(AgentAppViewModel.shouldReadProviderSnapshot(hasRecoverableContext: false),
                      "normal live and completed threads must keep provider snapshot refresh")
    }

    func test_displayedErrorRecoverabilityRestoresRetryFromPersistedReplay() {
        let replay: [AssistantEvent] = [
            .turnStarted(turnId: "turn-1"),
            .error(message: "temporary network failure", recoverable: true),
            .providerRuntime(ProviderRuntimeEvent(
                id: "runtime-after-error",
                provider: .claude,
                source: "claude.agent-sdk",
                method: "status",
                payloadJSON: "{}",
                receivedAtMs: 1
            ))
        ]

        XCTAssertTrue(AgentAppViewModel.displayedErrorIsRecoverable(in: replay),
                      "thread switching and relaunch must restore Retry from the recoverable error that still owns the displayed banner")
        XCTAssertFalse(AgentAppViewModel.displayedErrorIsRecoverable(in: replay + [
            .error(message: "fatal", recoverable: false)
        ]), "a later fatal error replaces the banner and must hide Retry")
    }

    /// WHY: recoveryState maps completed+cursor to recoverable for multi-turn
    /// startRun, but that must not drive the app-restart Continue banner when
    /// the thread was left interrupted and the session already finished.
    func test_interruptedThreadWithCompletedSessionDoesNotShowContinue() throws {
        let tmp = NSTemporaryDirectory() + "rc2-continue-interrupted-completed-session-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()
        var thread = AgentThread(
            workspaceId: workspaceID,
            title: "thread interrupted session done",
            provider: .codex,
            model: "gpt-5.5",
            providerThreadId: "codex-cursor"
        )
        thread.status = .interrupted
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            resumeCursor: "codex-cursor",
            cwd: tmp,
            model: "gpt-5.5"
        ))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            initialThreadId: thread.id
        )

        XCTAssertFalse(coordinator.hasRecoverableContext(threadId: thread.id),
                       "completed provider sessions must not arm Continue even when the thread row is still interrupted")
        XCTAssertFalse(vm.selectedThreadHasRecoverableContext)
    }

    /// WHY: pet open / thread switch must not show "interrupted by an app restart"
    /// for finished work. Live data had many completed threads with stale
    /// interrupted provider sessions still holding a resume cursor; Continue is
    /// only for relaunch-interrupted threads.
    func test_completedThreadWithStaleInterruptedSessionDoesNotShowContinue() throws {
        let tmp = NSTemporaryDirectory() + "rc2-continue-completed-stale-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()
        var thread = AgentThread(
            workspaceId: workspaceID,
            title: "finished work",
            provider: .grok,
            model: "grok-4.5",
            providerThreadId: "grok-session-cursor"
        )
        thread.status = .completed
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .grok,
            status: .interrupted,
            resumeCursor: "grok-session-cursor",
            cwd: tmp,
            model: "grok-4.5"
        ))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.grok: FakeProviderRunner(provider: .grok)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            initialThreadId: thread.id
        )

        XCTAssertFalse(coordinator.hasRecoverableContext(threadId: thread.id),
                       "a completed thread must not be treated as relaunch-recoverable just because a stale session row is interrupted")
        XCTAssertFalse(vm.selectedThreadHasRecoverableContext,
                       "opening a finished thread (e.g. via pet) must not show the app-restart Continue banner")
        XCTAssertFalse(
            AgentAppViewModel.showsContinueAction(
                hasRecoverableContext: vm.selectedThreadHasRecoverableContext,
                runActive: false
            ),
            "Continue UI must stay hidden for completed threads"
        )
    }

    func test_unavailableProviderDoesNotConsumeContinueRecoveryAction() async throws {
        let fixture = try makeRecoverableContinueFixture(runner: FakeProviderRunner(provider: .distill))
        fixture.vm.providerSnapshots = [providerSnapshot(status: .unavailable, installed: false)]

        await waitForRecoverableContext(fixture.vm)
        XCTAssertTrue(fixture.vm.selectedThreadHasRecoverableContext,
                      "the off-main open bundle must arm Continue for a relaunch-interrupted thread")
        await fixture.vm.continueInterruptedThread()

        XCTAssertTrue(fixture.vm.selectedThreadHasRecoverableContext,
                      "an unavailable provider guard must leave Continue visible for the same interrupted thread")
        XCTAssertTrue(fixture.coordinator.hasRecoverableContext(threadId: fixture.threadId),
                      "a UI availability failure must not consume the durable provider cursor")
        XCTAssertTrue(fixture.vm.statusMessage.contains("unavailable"))
    }

    func test_throwingProviderStartDoesNotConsumeContinueRecoveryAction() async throws {
        let fixture = try makeRecoverableContinueFixture(runner: ContinueStartFailingRunner())
        fixture.vm.providerSnapshots = [providerSnapshot(status: .available, installed: true)]

        await waitForRecoverableContext(fixture.vm)
        XCTAssertTrue(fixture.vm.selectedThreadHasRecoverableContext,
                      "the off-main open bundle must arm Continue for a relaunch-interrupted thread")
        await fixture.vm.continueInterruptedThread()
        for _ in 0..<200 where !fixture.vm.statusMessage.contains("Failed to start") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(fixture.vm.selectedThreadHasRecoverableContext,
                      "a transient provider start failure must restore Continue on the same selected thread")
        XCTAssertTrue(fixture.coordinator.hasRecoverableContext(threadId: fixture.threadId),
                      "the failed attempt must preserve the durable cursor for a later retry")
        XCTAssertTrue(fixture.vm.statusMessage.contains("Failed to start"))
    }

    func test_checkpointRevertRequiresNegotiatedProviderRollbackCapability() {
        XCTAssertFalse(AgentAppViewModel.canRevertCheckpoint(
            status: .ready,
            capabilities: .conservative
        ), "Grok and unknown provider contracts must not expose a Revert action that the adapter will reject")
        XCTAssertTrue(AgentAppViewModel.canRevertCheckpoint(
            status: .ready,
            capabilities: AgentProviderCapabilities(supportsRollback: true)
        ))
        XCTAssertFalse(AgentAppViewModel.canRevertCheckpoint(
            status: .error,
            capabilities: AgentProviderCapabilities(supportsRollback: true)
        ), "provider capability cannot make a failed checkpoint restorable")
    }

    func test_providerSnapshotFailureMessageDeclaresStaleStateAndLastConfirmation() {
        let message = AgentAppViewModel.providerThreadSnapshotFailureMessage(
            lastConfirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(message.contains("Provider snapshot unavailable"))
        XCTAssertTrue(message.contains("Showing persisted local state"),
                      "a readThread failure must not silently present local replay as provider-confirmed current state")
        XCTAssertFalse(message.contains("not yet confirmed"),
                       "a known confirmation timestamp must be rendered instead of erased")
        XCTAssertTrue(AgentAppViewModel.providerThreadSnapshotFailureMessage(lastConfirmedAt: nil)
            .contains("not yet confirmed this session"))
    }

    func test_readThreadFailureSurfacesStaleStateAndRetryInsteadOfFailingSilently() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-provider-snapshot-failure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "provider context",
            provider: .codex,
            model: "gpt-5.5",
            providerThreadId: "codex-thread-stale"
        )
        try threadRepo.upsert(thread)
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
            initialThreadId: thread.id
        )

        let deadline = Date().addingTimeInterval(2)
        while vm.providerThreadSnapshotStatusMessage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(vm.providerThreadSnapshotStatusMessage?.contains("Showing persisted local state") == true,
                      "readThread failure must render explicit stale state with a Retry action")
        XCTAssertNil(vm.providerThreadSnapshotLastConfirmedAt,
                     "a failed provider read must not invent a confirmation timestamp")
    }

    /// The recoverable flag is applied from the off-main thread-open bundle
    /// (gatherThreadOpenBundle), not synchronously in init; wait (bounded) for it.
    private func waitForRecoverableContext(_ vm: AgentAppViewModel) async {
        let deadline = Date().addingTimeInterval(2)
        while !vm.selectedThreadHasRecoverableContext, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeRecoverableContinueFixture(
        runner: AgentProviderRunner
    ) throws -> (vm: AgentAppViewModel, coordinator: AgentRunCoordinator, threadId: AgentThreadID) {
        let tmp = NSTemporaryDirectory() + "rc2-continue-action-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()
        var thread = AgentThread(
            workspaceId: workspaceID,
            title: "recoverable",
            provider: .distill,
            model: "claude/claude-opus-5-5",
            providerThreadId: "distill-recovery-cursor"
        )
        thread.status = .interrupted
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .distill,
            status: .interrupted,
            resumeCursor: "distill-recovery-cursor",
            cwd: tmp,
            model: "claude/claude-opus-5-5"
        ))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.distill: runner]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            initialThreadId: thread.id
        )
        return (vm, coordinator, thread.id)
    }

    private func providerSnapshot(
        status: AgentProviderSnapshotStatus,
        installed: Bool
    ) -> AgentProviderSnapshot {
        AgentProviderSnapshot(
            id: AgentProvider.distill.rawValue,
            provider: .distill,
            driverKind: .distillACP,
            displayName: "Distill",
            accentColor: "#2F80ED",
            continuationGroup: "distill",
            interactionModes: [.default, .plan],
            permissionModes: [.supervised, .fullAccess],
            enabled: true,
            installed: installed,
            status: status,
            statusDetail: status == .unavailable ? "Distill is unavailable." : nil,
            authenticated: true,
            models: [AgentModelDescriptor(id: "claude/claude-opus-5-5", label: "Claude Opus 5.5", provider: .distill)],
            slashCommands: [],
            capabilities: AgentProviderCapabilities(supportsStreaming: true)
        )
    }
}

private final class ContinueStartFailingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .distill

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        throw NSError(
            domain: "RemoteCode.ContinueStartFailingRunner",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "simulated transient provider start failure"]
        )
    }
}
