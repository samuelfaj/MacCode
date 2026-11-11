import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// WHY: a bot that pauses for a manual action must survive restarts as a card, and the user's
/// answer must reach the bot exactly once no matter how many surfaces or taps race.
@MainActor
final class ManualActionCardTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private struct Fixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let botsVM: BotsViewModel
        let surface: AgentAppSurface
        let runner: ControlledBotHandoffRunner
        let bot: BotDefinition
        let thread: AgentThread
        let workspaceCwd: String
        @MainActor var vm: AgentAppViewModel { surface.viewModel }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ManualAction-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: TerminalRetiringOneShotAdapter(runner: runner))
        let snapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "codex"
            )
        ]
        router.rememberProviderSnapshotsForSend(snapshots)
        let botsVM = BotsViewModel(context: ctx, router: router)
        router.botsViewModel = botsVM
        let bot = try botsVM.create(name: "Quinn", title: "Scout", soul: "soul")
        let workspace = try router.createWorkspace(name: "manual-ws", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Manual thread",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let surface = AgentAppSurface(
            workspaceID: workspace.id,
            cwd: workspaceDir.path,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo,
            queuedMessageRepo: ctx.queuedMessageRepo,
            providerSessionRepo: ctx.providerSessionRuntimeRepo,
            checkpointRepo: ctx.turnCheckpointRepo,
            initialThreadId: thread.id
        )
        router.configureAgentAppBotMentions(surface)
        surface.viewModel.providerSnapshots = snapshots
        surface.viewModel.providerLaunchConfig = { _, _ in ("/usr/bin/true", ["ACTOR_TEST_ENV": "kept"]) }
        surface.viewModel.selectThread(thread.id)
        return Fixture(
            ctx: ctx, router: router, botsVM: botsVM, surface: surface, runner: runner,
            bot: bot, thread: thread, workspaceCwd: workspaceDir.path
        )
    }

    private func waitUntil(timeout: TimeInterval = 6, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }


    private func makeSurface(_ f: Fixture, control: BotComputerControl = BotComputerControl()) -> AgentAppViewModel {
        let surface = AgentAppSurface(
            workspaceID: f.vm.workspaceID,
            cwd: f.workspaceCwd,
            coordinator: f.ctx.coordinator,
            threadRepo: f.ctx.threadRepo,
            messageRepo: f.ctx.messageRepo,
            queuedMessageRepo: f.ctx.queuedMessageRepo,
            providerSessionRepo: f.ctx.providerSessionRuntimeRepo,
            checkpointRepo: f.ctx.turnCheckpointRepo,
            initialThreadId: f.thread.id
        )
        f.router.configureAgentAppBotMentions(surface)
        surface.viewModel.providerSnapshots = f.vm.providerSnapshots
        surface.viewModel.providerLaunchConfig = { _, _ in ("/usr/bin/true", [:]) }
        surface.viewModel.botComputerControl = control
        surface.viewModel.selectThread(f.thread.id)
        extraSurfaces.append(surface)
        return surface.viewModel
    }

    private var extraSurfaces: [AgentAppSurface] = []

    private func post(_ f: Fixture, control: BotComputerControl) -> ManualActionRequest {
        let request = ManualActionRequest(botID: f.bot.id, threadID: f.thread.id, kind: .login, reason: "Entre na conta")
        control.requestHelp(request)
        NotificationCenter.default.post(
            name: .botManualActionRequested, object: nil,
            userInfo: [BotHostNotificationKey.request: request]
        )
        return request
    }

    func test_manualAction_1_requestOpensCardAndThreadAwaits() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        XCTAssertNil(f.vm.openManualAction)
        let request = post(f, control: control)
        let opened = await waitUntil { f.vm.openManualAction?.id == request.id }
        XCTAssertTrue(opened, "card must open for the thread the request names")
        XCTAssertEqual(f.vm.statusLabel, "Waiting for you")
    }

    /// WHY: the handoff card and the bot VM banners are product UI: their English source copy
    /// goes through L() and never carries Portuguese, whatever language the bot writes in.
    func test_handoffCardAndBotVMBannersAreEnglish() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let card = try String(contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentManualActionCard.swift"), encoding: .utf8)
        for copy in [
            "is waiting for you\"", "L(\"Note for the bot (optional)\")", "L(\"Control taken\") : L(\"Take control\")",
            "Button(L(\"Ready, continue\"))", "Button(L(\"Decline\"))", "L(\"declined\") : L(\"continued\")", "L(\"You took over for ",
        ] {
            XCTAssertTrue(card.contains(copy), copy)
        }
        let banners = try String(contentsOf: root.appendingPathComponent("Sources/Surfaces/BotVMBanners.swift"), encoding: .utf8)
        for copy in ["L(\"The bot asked to run on the Mac: ", "Button(L(\"Approve\"))", "Button(L(\"Start VM\"))", "Button(L(\"Run this thread on the Mac\"))"] {
            XCTAssertTrue(banners.contains(copy), copy)
        }
        for portuguese in ["aguarda", "Pronto", "Recusar", "Assumir", "Nota para", "Aprovar", "Iniciar", "Rodar"] {
            XCTAssertFalse(card.contains(portuguese) || banners.contains(portuguese), portuguese)
        }
    }

    /// Starts a bot turn the runner holds open, like a bot that is mid-browse when it asks for help.
    private func startHeldRun(_ f: Fixture) async throws -> AgentRunID {
        f.vm.prompt = "go"
        await f.vm.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(f.runner.requests.first).runId
        XCTAssertNotNil(try f.ctx.runRepo.latestActive(for: f.thread.id), "the bot turn is running")
        return runID
    }

    private func waitUntilPaused(_ f: Fixture, run: AgentRunID) async -> Bool {
        await waitUntil {
            (try? f.ctx.runRepo.latestActive(for: f.thread.id)) == nil
                && (try? f.ctx.runRepo.status(of: run)) == .cancelled
        }
    }

    /// WHY: the bot must not keep acting on the shared computer once it asks the user to step in.
    /// The model is only asked to end its turn; the host must stop the run, and only the user's
    /// answer starts the next turn, exactly once, carrying the note.
    func test_manualAction_requestStopsActiveBotRunUntilUserAnswers() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let firstRun = try await startHeldRun(f)

        _ = post(f, control: control)
        let paused = await waitUntilPaused(f, run: firstRun)
        XCTAssertTrue(paused, "opening the handoff card must stop the bot's running turn")
        XCTAssertNotNil(f.vm.openManualAction, "the card stays open while the bot is paused")
        XCTAssertEqual(f.vm.statusLabel, "Waiting for you", "a paused bot reads as waiting, not stopped")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "no new turn starts while the user has not answered")

        await f.vm.continueManualAction(note: "done")
        let resumed = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(resumed, "Ready, continue resumes the bot")
        XCTAssertEqual(
            f.runner.requests.last?.prompt,
            ManualActionRequest.continueFollowUp(kind: .login, note: "done")
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 2, "the resume is exactly one turn")
    }

    /// WHY: a message the user queued before the handoff must not restart the bot behind the
    /// open card; it runs only after the bot has heard the user's answer.
    func test_manualAction_queuedMessageWaitsForTheAnswerThenRunsAfterTheFollowUp() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let firstRun = try await startHeldRun(f)
        f.vm.prompt = "queued while busy"
        await f.vm.send()
        XCTAssertEqual(try f.ctx.queuedMessageRepo.list(threadId: f.thread.id).count, 1)

        _ = post(f, control: control)
        let paused = await waitUntilPaused(f, run: firstRun)
        XCTAssertTrue(paused)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "the queued message must not start a turn while the card is open")
        XCTAssertEqual(try f.ctx.queuedMessageRepo.list(threadId: f.thread.id).count, 1, "the queued message is kept")

        await f.vm.declineManualAction()
        let declined = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(declined)
        XCTAssertEqual(f.runner.requests.last?.prompt, ManualActionRequest.declineFollowUp, "the answer goes first")
        XCTAssertTrue(f.runner.finish(promptContaining: ManualActionRequest.declineFollowUp, reply: "ok"))
        let drained = await waitUntil { f.runner.requests.count == 3 }
        XCTAssertTrue(drained, "the queued message runs once the bot has the answer")
        XCTAssertTrue(f.runner.requests.last?.prompt.contains("queued while busy") == true)
    }

    /// WHY: `bot_browser_wait_login` without a caller thread falls back to the bot's first linked
    /// thread, which may not be the one browsing; stopping it could halt an unrelated turn.
    func test_manualAction_fallbackThreadRequestDoesNotStopThatThreadsRun() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        _ = try await startHeldRun(f)
        let request = ManualActionRequest(botID: f.bot.id, threadID: f.thread.id, kind: .login, reason: "Sign in")
        control.requestHelp(request)
        NotificationCenter.default.post(
            name: .botManualActionRequested, object: nil,
            userInfo: [BotHostNotificationKey.request: request, BotHostNotificationKey.threadIsFallback: true]
        )
        _ = await waitUntil { f.vm.openManualAction?.id == request.id }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(try f.ctx.runRepo.latestActive(for: f.thread.id), "a guessed thread is never stopped")
    }

    /// WHY: "run on the Mac?" is the same fire-and-forget pause as the handoff card: the bot must
    /// stop until the user approves or declines, and the answer resumes it once.
    func test_macExecutionRequest_stopsActiveRunUntilTheUserAnswers() async throws {
        let f = try makeFixture()
        let firstRun = try await startHeldRun(f)
        NotificationCenter.default.post(
            name: .botMacExecutionRequested, object: nil,
            userInfo: [
                BotHostNotificationKey.botID: f.bot.id,
                BotHostNotificationKey.threadID: f.thread.id,
                BotHostNotificationKey.reason: "needs Xcode",
            ]
        )
        let paused = await waitUntilPaused(f, run: firstRun)
        XCTAssertTrue(paused, "the Mac-execution request must stop the bot's running turn")
        XCTAssertEqual(f.router.pendingMacExecution[f.thread.id], "needs Xcode")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1)

        try await f.router.resolveMacExecution(thread: f.thread.id, approve: false)
        let resumed = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(resumed, "the answer resumes the bot")
        XCTAssertEqual(f.runner.requests.last?.userMessageContent, AppCommandRouter.macExecutionDeclinedFollowUp)
    }

    func test_manualAction_2_continueSendsSingleFollowUpWithNote() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        async let first: Void = f.vm.continueManualAction(note: "logado")
        async let second: Void = f.vm.continueManualAction(note: "logado")
        _ = await (first, second)
        await f.vm.continueManualAction(note: "logado")
        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "double tap must produce exactly one follow-up")
        let prompt = try XCTUnwrap(f.runner.requests.first).prompt
        XCTAssertTrue(prompt.contains("logado"))
        XCTAssertTrue(prompt.contains("login"))
        XCTAssertNil(f.vm.openManualAction)
        XCTAssertEqual(f.vm.resolvedManualActions.first?.state, .continued)
        XCTAssertNil(control.openRequest(f.bot.id))
    }

    func test_manualAction_4_declineSendsDeclineFollowUp() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        await f.vm.declineManualAction()
        _ = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertEqual(f.runner.requests.first?.prompt, ManualActionRequest.declineFollowUp)
        XCTAssertEqual(f.vm.resolvedManualActions.first?.state, .declined)
    }

    func test_manualAction_5_restartKeepsCardAndResetsControl() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let request = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        f.vm.takeManualControl()
        XCTAssertTrue(control.isControlledByUser(f.bot.id))
        XCTAssertEqual(f.vm.openManualAction?.state, .taken)
        let restartedControl = BotComputerControl()
        let restarted = makeSurface(f, control: restartedControl)
        XCTAssertEqual(restarted.openManualAction?.id, request.id, "card survives restart")
        XCTAssertFalse(restartedControl.isControlledByUser(f.bot.id), "control is not persisted")
        XCTAssertEqual(restarted.openManualAction?.state, .open, "taken request is handed back after restart")
    }

    func test_manualAction_7_deskAndWorkspaceShareOneFollowUp() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let other = makeSurface(f, control: control)
        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil && other.openManualAction != nil }
        XCTAssertNotNil(other.openManualAction)
        await f.vm.continueManualAction(note: "ok")
        await other.continueManualAction(note: "ok")
        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "second surface must see the request already resolved")
    }

    private func lockToBotVM(_ f: Fixture) throws {
        let lockedAt = Date()
        XCTAssertTrue(try f.ctx.threadRepo.setActor(
            id: f.thread.id, actor: .bot(f.bot.id), lockedAt: lockedAt, executionTarget: .vm
        ))
        let index = try XCTUnwrap(f.vm.threads.firstIndex(where: { $0.id == f.thread.id }))
        f.vm.threads[index].actor = .bot(f.bot.id)
        f.vm.threads[index].actorLockedAt = lockedAt
        f.vm.mirrorExecutionTarget(.vm, thread: f.thread.id)
    }

    /// WHY: the user must be able to take the VM screen and hand it back; handing back mid-request resumes the bot once.
    func test_botScreen_takeThenDevolverWithOpenRequestContinuesOnce() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        try lockToBotVM(f)
        f.vm.botVMPreflight = { _, _, _ in nil }
        f.vm.botThreadLinker = { _, _ in }
        f.vm.botPromptTransform = { _, text, _, _ in text }
        f.vm.botRunStarted = { _, _, _ in }
        XCTAssertEqual(f.vm.botScreenBotID, f.bot.id)
        var opened: [BotID] = []
        f.vm.openBotScreen = { opened.append($0) }
        f.vm.viewBotScreen()
        XCTAssertEqual(opened, [f.bot.id])

        await f.vm.toggleBotScreenControl()
        XCTAssertTrue(control.isControlledByUser(f.bot.id))
        XCTAssertTrue(f.vm.botScreenControlled)

        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        await f.vm.toggleBotScreenControl()
        XCTAssertFalse(control.isControlledByUser(f.bot.id))
        XCTAssertFalse(f.vm.botScreenControlled)
        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1)
        XCTAssertEqual(f.vm.resolvedManualActions.first?.state, .continued)
    }

    func test_manualActionStore_unwritableStoreDoesNotContinueOrFollowUp() async throws {
        // WHY: continuing without a durable resolve would resend the follow-up after restart.
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let request = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualActionBroken-\(UUID().uuidString)", isDirectory: true)
        let broken = ManualActionRequestStore(appSupportDirectory: dir)
        try broken.upsert(request)
        let actions = dir.appendingPathComponent("ManualActions")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: actions.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: actions.path) }
        f.vm.manualActionStore = broken
        f.vm.openManualAction = request
        await f.vm.continueManualAction(note: "ok")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 0, "no follow-up when the resolve was not persisted")
        XCTAssertFalse(f.vm.statusMessage.isEmpty)
        XCTAssertNotNil(control.openRequest(f.bot.id), "control request stays open")
        XCTAssertEqual(broken.open(threadID: f.thread.id)?.state, .open, "request stays open on disk")
    }

    func test_manualActionStore_staleSecondSurfaceTakeIsRefusedAfterContinue() async throws {
        // WHY: a stale card on another surface must not revive a continued request or add a follow-up.
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let other = makeSurface(f, control: control)
        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil && other.openManualAction != nil }
        let stale = try XCTUnwrap(other.openManualAction)
        await f.vm.continueManualAction(note: "ok")
        _ = await waitUntil { f.runner.requests.count >= 1 }
        other.openManualAction = stale
        other.takeManualControl()
        XCTAssertEqual(f.router.manualActionStore.all(threadID: f.thread.id).first?.state, .continued)
        XCTAssertFalse(control.isControlledByUser(f.bot.id))
        await other.continueManualAction(note: "ok")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1)
        let refreshed = await waitUntil { other.openManualAction == nil }
        XCTAssertTrue(refreshed, "stale card refreshes via state-change notification or take refresh")
    }
}
