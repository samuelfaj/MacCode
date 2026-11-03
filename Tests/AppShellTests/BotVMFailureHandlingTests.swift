import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// WHY: a bot VM failure or a Mac-execution request must never move a thread to the Mac without the user's click.
@MainActor
final class BotVMFailureHandlingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }
    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    func test_botFailureMessagesUseEnglishRegardlessOfUserConversationLanguage() {
        XCTAssertEqual(DistillGuestLaunchError.unavailable("Docker is stopped").errorDescription,
                       "VM unavailable: Docker is stopped")
        XCTAssertEqual(ThreadActorAlreadyLockedError().errorDescription,
                       "This conversation is already assigned to another actor. Review the actor and try sending again.")
    }

    private struct Fixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let botsVM: BotsViewModel
        let surface: AgentAppSurface
        let runner: ControlledBotHandoffRunner
        let bot: BotDefinition
        let thread: AgentThread
        let workspaceDir: URL
        @MainActor var vm: AgentAppViewModel { surface.viewModel }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2BotVMFail-\(UUID().uuidString)", isDirectory: true)
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
        let bot = try botsVM.create(name: "Vera", title: "Scout", soul: "soul")
        let workspace = try router.createWorkspace(name: "vm-ws", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "VM thread",
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
        surface.viewModel.botExecutionTargetProvider = { _ in .vm }
        surface.viewModel.providerSnapshots = snapshots
        surface.viewModel.providerLaunchConfig = { _, _ in ("/usr/bin/true", [:]) }
        surface.viewModel.selectThread(thread.id)
        return Fixture(
            ctx: ctx, router: router, botsVM: botsVM, surface: surface, runner: runner,
            bot: bot, thread: thread, workspaceDir: workspaceDir
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

    /// Linked and locked the way the app stores a VM-bot thread: the follow-ups
    /// after an approval run as bot turns, which need the linked conversation.
    private func lockOnVM(_ f: Fixture) throws {
        f.botsVM.dockerGuestReadyOverrideForTesting = true
        try XCTUnwrap(f.vm.botThreadLinker)(f.bot.id, f.thread.id)
        XCTAssertTrue(try f.ctx.threadRepo.setActor(
            id: f.thread.id, actor: .bot(f.bot.id), lockedAt: Date(), executionTarget: .vm
        ))
        f.vm.selectThread(f.thread.id)
    }

    private func requestMacExecution(_ f: Fixture) async {
        NotificationCenter.default.post(
            name: .botMacExecutionRequested, object: nil,
            userInfo: [
                BotHostNotificationKey.botID: f.bot.id,
                BotHostNotificationKey.threadID: f.thread.id,
                BotHostNotificationKey.reason: "preciso do Xcode",
            ]
        )
        _ = await waitUntil { f.router.pendingMacExecution[f.thread.id] != nil }
    }

    func test_approveMacExecutionSwitchesTargetKeepsActorAndSendsOneFollowUp() async throws {
        let f = try makeFixture()
        try lockOnVM(f)
        let before = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        await requestMacExecution(f)
        XCTAssertEqual(f.router.pendingMacExecution[f.thread.id], "preciso do Xcode")
        XCTAssertEqual(try f.ctx.threadRepo.get(id: f.thread.id)?.executionTarget, .vm, "request alone never switches")

        try await f.router.resolveMacExecution(thread: f.thread.id, approve: true)
        let after = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(after.executionTarget, .mac)
        XCTAssertEqual(after.actor, before.actor)
        XCTAssertEqual(after.actorLockedAt, before.actorLockedAt)
        XCTAssertNil(f.router.pendingMacExecution[f.thread.id])
        let sent = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(f.runner.requests.first?.userMessageContent, "The user approved running on the Mac. Continue.")
    }

    func test_declineMacExecutionKeepsVMAndSendsDeclineFollowUp() async throws {
        let f = try makeFixture()
        try lockOnVM(f)
        await requestMacExecution(f)
        try await f.router.resolveMacExecution(thread: f.thread.id, approve: false)
        XCTAssertEqual(try f.ctx.threadRepo.get(id: f.thread.id)?.executionTarget, .vm)
        let sent = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(
            f.runner.requests.first?.userMessageContent,
            "The user declined running on the Mac. Continue in the VM, or stop and explain."
        )
        XCTAssertEqual(
            f.runner.requests.first?.prompt.contains(BotStandingInstructions.vmThreadRules), true,
            "the follow-up is a bot turn: without its VM rules the bot does not know its tools"
        )
        try await f.router.resolveMacExecution(thread: f.thread.id, approve: true)
        XCTAssertEqual(try f.ctx.threadRepo.get(id: f.thread.id)?.executionTarget, .vm, "no pending request, no switch")
    }

    func test_preflightFailureBlocksSendWithoutFallbackThenRunOnMacSwitches() async throws {
        let f = try makeFixture()
        f.vm.botVMPreflight = { _, _, _ in "docker parado" }
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "oi"
        await f.vm.send()
        XCTAssertTrue(f.vm.statusMessage.contains("docker parado"), f.vm.statusMessage)
        XCTAssertEqual(f.vm.vmUnavailableBotID, f.bot.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty, "no request while the VM is down")
        let blocked = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertNil(blocked.executionTarget, "no silent fallback to the Mac")
        XCTAssertNil(blocked.actorLockedAt)

        f.vm.runSelectedThreadOnMac()
        let moved = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(moved.executionTarget, .mac)
        XCTAssertEqual(moved.actor, .bot(f.bot.id))
        XCTAssertNil(f.vm.vmUnavailableBotID)
    }

    /// WHY: a detached Desk or Linux desktop window builds its own short-lived Bots
    /// model. If it took over the router-wide run hooks, closing it left them pointing
    /// at a dead model and every workspace bot send failed with "Bot unavailable.".
    func test_closedDetachedBotsWindowDoesNotBreakWorkspaceBotRunHooks() throws {
        let f = try makeFixture()
        autoreleasepool {
            let detached = BotsViewModel(context: f.ctx, router: f.router, loadImmediately: false)
            detached.prepareDetachedDesk(botID: f.bot.id)
        }
        try XCTUnwrap(f.router.botWorkspaceRunHooks).link(f.bot.id, f.thread.id)
        XCTAssertEqual(
            try f.ctx.botStore.conversationLinked(to: f.thread.id)?.botID, f.bot.id,
            "the hooks must still reach the live Bots model after the detached window closed"
        )
    }

    // MARK: - Guest thread → Mac handoff (plan A M10)

    /// Makes the fixture thread a guest thread with a transcript whose Distill
    /// session `guestSession` lives inside the bot's Linux VM: marker on a `.vm`
    /// lock, and the cursor on both the thread and its provider session row.
    private func makeGuestThreadWithHistory(_ f: Fixture, guestSession: String) throws {
        try f.ctx.messageRepo.append(AgentMessage(
            threadId: f.thread.id, role: .user, content: "primeira tarefa", createdAt: Date().addingTimeInterval(-10)
        ))
        try f.ctx.messageRepo.append(AgentMessage(
            threadId: f.thread.id, role: .assistant, content: "feito na VM", createdAt: Date().addingTimeInterval(-5)
        ))
        try f.ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: f.thread.id, provider: .codex, status: .completed, resumeCursor: guestSession,
            runtimePayloadJSON: "{\"providerThreadId\":\"\(guestSession)\"}"
        ))
        try writeGuestCursor(f, guestSession)
        try XCTUnwrap(f.router.botWorkspaceRunHooks).link(f.bot.id, f.thread.id)
        try lockOnVM(f)
        try f.ctx.threadRepo.setGuestRuntime(id: f.thread.id, BotGuestRuntime.distillV1)
        f.vm.reloadThreads()
        f.vm.selectThread(f.thread.id)
    }

    /// What a guest turn's finish persists: its session as the thread's cursor.
    private func writeGuestCursor(_ f: Fixture, _ guestSession: String) throws {
        try f.ctx.threadRepo.updateProviderThreadId(id: f.thread.id, providerThreadId: guestSession)
        try f.ctx.providerSessionRuntimeRepo.stampResumeCursor(threadId: f.thread.id, resumeCursor: guestSession)
    }

    func test_approvingMacExecutionOnAGuestThreadStartsANewMacSessionWithTheHandoffSummary() async throws {
        // WHY (M10): the guest's Distill session lives in the VM's home; the Mac
        // cannot load it. The Mac run must drop that cursor (thread and provider
        // session) and the marker, and carry the recent transcript instead, or the
        // follow-up either fails to load the session or loses the conversation.
        let f = try makeFixture()
        try makeGuestThreadWithHistory(f, guestSession: "guest-session-1")
        await requestMacExecution(f)
        try await f.router.resolveMacExecution(thread: f.thread.id, approve: true)
        let sent = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(sent)
        let followUp = try XCTUnwrap(f.runner.requests.last)
        XCTAssertNil(followUp.providerThreadId, "the guest session must not be resumed on the Mac")
        XCTAssertTrue(followUp.prompt.hasPrefix("Continuação da thread \"VM thread\""), followUp.prompt)
        XCTAssertTrue(followUp.prompt.contains("Usuário: primeira tarefa"))
        XCTAssertTrue(followUp.prompt.contains("Assistente: feito na VM"))
        XCTAssertTrue(followUp.prompt.hasSuffix(AppCommandRouter.macExecutionApprovedFollowUp))
        XCTAssertEqual(followUp.userMessageContent, AppCommandRouter.macExecutionApprovedFollowUp,
                       "the transcript keeps the follow-up text, not the summary")
        let placement = try XCTUnwrap(try f.ctx.threadRepo.guestPlacement(of: f.thread.id))
        XCTAssertEqual(placement.executionTarget, .mac)
        XCTAssertNil(placement.guestRuntime, "the marker is gone once the Mac session takes over")
        XCTAssertNotEqual(try f.ctx.providerSessionRuntimeRepo.resumeCursor(of: f.thread.id), "guest-session-1")
    }

    func test_approvalDuringAStillRunningGuestTurnHandsOffWhenTheFollowUpStarts() async throws {
        // WHY: the bot asks for the Mac mid-turn, so the user can approve before the
        // guest turn ends. That turn's finish writes the guest cursor back; clearing
        // at approval time would be undone, and the queued follow-up would try to
        // load the guest session on the Mac.
        let f = try makeFixture()
        try makeGuestThreadWithHistory(f, guestSession: "guest-session-1")
        // The guest turn that asked for the Mac is still running.
        try f.ctx.threadRepo.updateStatus(id: f.thread.id, status: .running, hasUnread: false)
        await requestMacExecution(f)
        try await f.router.resolveMacExecution(thread: f.thread.id, approve: true)
        XCTAssertEqual(try f.ctx.queuedMessageRepo.list(threadId: f.thread.id).count, 1, "the follow-up waits")
        XCTAssertTrue(f.runner.requests.isEmpty)
        // The guest turn ends after the approval and persists its session.
        try writeGuestCursor(f, "guest-session-1")
        try f.ctx.threadRepo.updateStatus(id: f.thread.id, status: .completed, hasUnread: false)
        try await f.router.drainNextQueuedAgentMessage(thread: f.thread.id)
        let drained = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(drained)
        let followUp = try XCTUnwrap(f.runner.requests.last)
        XCTAssertNil(followUp.providerThreadId)
        XCTAssertTrue(followUp.prompt.hasPrefix("Continuação da thread"), followUp.prompt)
        XCTAssertEqual(followUp.userMessageContent, AppCommandRouter.macExecutionApprovedFollowUp)
        XCTAssertNil(try f.ctx.threadRepo.guestPlacement(of: f.thread.id)?.guestRuntime)
    }

    func test_approvingMacExecutionOnALegacyVMThreadKeepsItsMacSession() async throws {
        // WHY (D5): a `.vm` thread without the guest marker always ran on the Mac;
        // its session is a Mac session and must keep resuming.
        let f = try makeFixture()
        try lockOnVM(f)
        try f.ctx.threadRepo.updateProviderThreadId(id: f.thread.id, providerThreadId: "mac-session-1")
        await requestMacExecution(f)
        try await f.router.resolveMacExecution(thread: f.thread.id, approve: true)
        let sent = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(sent)
        let followUp = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(followUp.providerThreadId, "mac-session-1")
        XCTAssertEqual(followUp.prompt.contains("Continuação da thread"), false)
    }

    func test_runOnMacFromTheVMBannerHandsAGuestThreadOffOnItsNextSend() async throws {
        // WHY (D11 + M10): "Run this thread on the Mac" is the only way a guest
        // thread reaches the Mac; its next send must start a Mac session from the
        // transcript, not try to load the guest session.
        let f = try makeFixture()
        try makeGuestThreadWithHistory(f, guestSession: "guest-session-1")
        f.vm.botVMPreflight = { _, _, _ in "docker parado" }
        f.vm.prompt = "continua"
        await f.vm.send()
        XCTAssertEqual(f.vm.vmUnavailableBotID, f.bot.id, f.vm.statusMessage)
        XCTAssertTrue(f.runner.requests.isEmpty, "no run while the VM is down")
        f.vm.runSelectedThreadOnMac()
        XCTAssertEqual(try f.ctx.threadRepo.guestPlacement(of: f.thread.id)?.macHandoffPending, true)
        f.vm.prompt = "continua"
        await f.vm.send()
        let sent = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(sent, f.vm.statusMessage)
        let request = try XCTUnwrap(f.runner.requests.last)
        XCTAssertNil(request.providerThreadId)
        XCTAssertTrue(request.prompt.hasPrefix("Continuação da thread"), request.prompt)
        XCTAssertEqual(request.userMessageContent, "continua")
        XCTAssertNil(try f.ctx.threadRepo.guestPlacement(of: f.thread.id)?.guestRuntime)
    }

    func test_aHandoffStartThatFailsBeforeTheProviderTookItHandsOffAgainOnTheNextSend() async throws {
        // WHY (M10): the handoff summary exists only in that run's request. If the
        // marker went with a start that then failed before the provider took the
        // turn (admission, a Stop during preparation, a Mac sign-in error), the next
        // send would open a Mac session with none of the guest conversation.
        let f = try makeFixture()
        try makeGuestThreadWithHistory(f, guestSession: "guest-session-1")
        f.vm.botVMPreflight = { _, _, _ in "docker parado" }
        f.vm.prompt = "continua"
        await f.vm.send()
        f.vm.runSelectedThreadOnMac()
        let attempts = AttemptCounter()
        f.ctx.coordinator.providerAdmissionCheck = { _, _ in
            if attempts.next() == 1 {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mac Distill not signed in"])
            }
        }
        f.vm.prompt = "primeira tentativa"
        await f.vm.send()
        _ = await waitUntil { attempts.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty, "the first start failed before the provider")
        XCTAssertEqual(
            try f.ctx.threadRepo.guestPlacement(of: f.thread.id)?.macHandoffPending, true,
            "a failed start must leave the handoff pending"
        )

        f.vm.prompt = "segunda tentativa"
        await f.vm.send()
        let sent = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(sent, f.vm.statusMessage)
        let request = try XCTUnwrap(f.runner.requests.last)
        XCTAssertNil(request.providerThreadId, "still a new Mac session, never the guest's")
        XCTAssertTrue(request.prompt.hasPrefix("Continuação da thread"), request.prompt)
        XCTAssertTrue(request.prompt.contains("Assistente: feito na VM"), "the guest conversation reaches the Mac")
        XCTAssertNil(
            try f.ctx.threadRepo.guestPlacement(of: f.thread.id)?.guestRuntime,
            "once the provider took the turn, the thread stops handing off"
        )
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    func test_removedWorkspaceRefusesBotSend() async throws {
        let f = try makeFixture()
        try FileManager.default.removeItem(at: f.workspaceDir)
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "oi"
        await f.vm.send()
        XCTAssertEqual(f.vm.statusMessage, "Workspace removed")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty)
    }

    func test_ensureWorkspaceMountedDropsStoredBindsWhoseDirectoryIsGone() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-prune-\(UUID().uuidString)", isDirectory: true)
        let live = support.appendingPathComponent("live", isDirectory: true)
        let fresh = support.appendingPathComponent("fresh", isDirectory: true)
        let gone = support.appendingPathComponent("gone", isDirectory: true)
        for dir in [live, fresh] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let botID = BotID()
        let url = BotComputerGuestSpec.workspacesURL(appSupport: support, botID: botID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([live.path, gone.path]).write(to: url)
        let service = BotComputerGuestService(
            appSupport: support,
            docker: BotComputerDockerCLI(run: { _ in throw BotComputerGuestError.dockerUnavailable }),
            observeAttempts: 1,
            observeDelay: 0
        )
        try? service.ensureWorkspaceMounted(
            botID: botID, workspace: fresh.path, registered: [live.path, fresh.path, gone.path]
        )
        let saved = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved, [fresh.path, live.path].sorted())
        XCTAssertFalse(saved.contains(gone.path), "a removed workspace must not break container create")
    }

    private final class RecordingDockerRun: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var calls: [[String]] { lock.withLock { recorded } }
        func run(_ args: [String]) throws -> Data {
            lock.withLock { recorded.append(args) }
            switch args.first {
            case "inspect":
                if args.contains(where: { $0.contains("Config.Labels\"") }) {
                    return Data(BotComputerGuestSpec.recipeRevision.utf8)
                }
                if args.contains("{{.Id}}") { return Data("img".utf8) }
                return Data("true img 49152  {}".utf8)
            case "create": return Data("cid".utf8)
            case "exec": return BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)
            default: return Data()
            }
        }
    }

    func test_workspaceVMPreflightAcceptsItsThreadsWorktreeAndRejectsAnotherWorkspace() async throws {
        let f = try makeFixture()
        let workspaceID = try XCTUnwrap(f.thread.workspaceId)
        let bot = try f.ctx.botStore.create(name: "Builder", title: "", description: "", workspaceID: workspaceID)
        let machine = try f.ctx.botStore.saveVirtualMachine(name: "Build", workspaceID: workspaceID)
        try f.ctx.botStore.setExecutionDestination(.virtualMachine(machine.id), botID: bot.id)
        try f.ctx.threadRepo.setActor(id: f.thread.id, actor: .bot(bot.id), lockedAt: Date(), executionTarget: .vm)
        let docker = RecordingDockerRun()
        f.router.botVMDocker = BotComputerDockerCLI(run: { try docker.run($0) })
        let worktree = f.workspaceDir.appendingPathComponent("worktree").path
        let allowed = await f.router.botVMPreflight(bot.id, workspace: worktree, threadID: f.thread.id)
        XCTAssertNil(allowed, "the worktree still belongs to the thread's workspace")

        let foreign = AgentThread(workspaceId: WorkspaceID(), title: "Other workspace", provider: .distill, model: "auto")
        try f.ctx.threadRepo.upsert(foreign)
        try f.ctx.botStore.pinExecutionDestination(threadID: foreign.id, botID: bot.id, destination: .virtualMachine(machine.id))
        let rejected = await f.router.botVMPreflight(bot.id, workspace: f.workspaceDir.path, threadID: foreign.id)
        XCTAssertNotNil(rejected, "a matching path cannot authorize a foreign workspace")
    }

    /// WHY: a thread's workspace must be bind-mounted in the bot VM before the send is allowed, or the bot edits nothing.
    func test_preflightMountsRunWorkspaceBeforeAllowingSend() async throws {
        let f = try makeFixture()
        let docker = RecordingDockerRun()
        f.router.botVMDocker = BotComputerDockerCLI(run: { try docker.run($0) })
        let failure = await f.router.botVMPreflight(f.bot.id, workspace: f.workspaceDir.path)
        XCTAssertNil(failure)
        let create = try XCTUnwrap(docker.calls.first { $0.first == "create" })
        let ws = f.workspaceDir.path
        XCTAssertTrue(create.contains("\(ws):\(ws)"), "missing bind in \(create)")
    }

    /// WHY: the guest distill build is ~224 MB; a bot VM preflight with Docker up
    /// must start its download in the background for the daemon's architecture,
    /// so the first in-guest run (or the first after a host update) does not wait for it.
    func test_preflightPrefetchesGuestDistillForTheDockerArchitecture() async throws {
        let f = try makeFixture()
        let docker = RecordingDockerRun()
        f.router.botVMDocker = BotComputerDockerCLI(run: { args in
            args.first == "info" ? Data(" OSType: linux\n Architecture: aarch64\n".utf8) : try docker.run(args)
        })
        try f.ctx.settingsRepo.set("cli.distill.path", "/usr/bin/true")
        let requested = LockedURLs()
        f.ctx.distillGuestBinaries = DistillGuestBinaryProvisioner(
            guestToolsRoot: f.workspaceDir.appendingPathComponent("guest-tools"),
            fetch: { url, _ in
                requested.append(url)
                throw DistillGuestBinaryError.downloadFailed(url: url.absoluteString, status: 404)
            },
            versionProbe: { _ in "distill 2.0.31 (test)" }
        )
        let failure = await f.router.botVMPreflight(f.bot.id, workspace: f.workspaceDir.path)
        XCTAssertNil(failure, "a prefetch must never block or fail the send")
        let deadline = Date().addingTimeInterval(5)
        while requested.urls.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(
            requested.urls.first?.absoluteString,
            "https://github.com/samuelfaj/distill/releases/download/v2.0.31/SHA256SUMS"
        )
    }

    /// WHY: after the Mac's Distill updates itself the bot VMs must follow at
    /// once, with Docker stopped too: the guest build for the new host version
    /// starts downloading for the architecture the VMs already run. A Mac that
    /// never ran a bot VM must not download ~224 MB it has no use for.
    func test_hostDistillUpdate_prefetchesTheNewGuestBuildForCachedArchitectures() async throws {
        let f = try makeFixture()
        f.router.botVMDocker = BotComputerDockerCLI(run: { _ in
            XCTFail("following a host update must not need Docker")
            return Data()
        })
        try f.ctx.settingsRepo.set("cli.distill.path", "/usr/bin/true")
        let guestTools = f.workspaceDir.appendingPathComponent("guest-tools")
        let requested = LockedURLs()
        f.ctx.distillGuestBinaries = DistillGuestBinaryProvisioner(
            guestToolsRoot: guestTools,
            fetch: { url, _ in
                requested.append(url)
                throw DistillGuestBinaryError.downloadFailed(url: url.absoluteString, status: 404)
            },
            versionProbe: { _ in "distill 2.0.42 (test)" }
        )
        await f.router.guestDistillFollowHostUpdate()()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(requested.urls, [], "no bot VM ever ran here")

        let cached = guestTools.appendingPathComponent("distill/2.0.41", isDirectory: true)
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)
        try Data("v41".utf8).write(to: cached.appendingPathComponent("distill-linux-aarch64"))
        await f.router.guestDistillFollowHostUpdate()()
        let deadline = Date().addingTimeInterval(5)
        while requested.urls.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(
            requested.urls.first?.absoluteString,
            "https://github.com/samuelfaj/distill/releases/download/v2.0.42/SHA256SUMS"
        )
    }

    private final class LockedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        var urls: [URL] { lock.withLock { stored } }
        func append(_ url: URL) { lock.withLock { stored.append(url) } }
    }

    /// WHY (B5): a Bots Desk thread runs in BotHome, which is never a registered
    /// workspace; mounting it always failed, so every desk send showed "VM
    /// indisponível". A workspace-less thread only needs the container up.
    func test_preflightWithoutWorkspaceProvisionsWithoutMountingAnything() async throws {
        let f = try makeFixture()
        let docker = RecordingDockerRun()
        f.router.botVMDocker = BotComputerDockerCLI(run: { try docker.run($0) })
        let failure = await f.router.botVMPreflight(f.bot.id, workspace: nil)
        XCTAssertNil(failure)
        let create = try XCTUnwrap(docker.calls.first { $0.first == "create" }, "the VM must be brought up")
        XCTAssertFalse(create.contains { $0.contains(f.workspaceDir.path) }, "nothing is mounted: \(create)")
    }

    /// WHY: an unregistered path must block the send instead of mounting arbitrary host directories.
    func test_preflightRefusesUnregisteredWorkspace() async throws {
        let f = try makeFixture()
        let docker = RecordingDockerRun()
        f.router.botVMDocker = BotComputerDockerCLI(run: { try docker.run($0) })
        let failure = await f.router.botVMPreflight(f.bot.id, workspace: "/tmp/rc-not-registered/x")
        XCTAssertNotNil(failure)
        XCTAssertFalse(docker.calls.contains { $0.first == "create" })
    }

    func test_deletingBotClosesManualRequestsAndForgetsControl() async throws {
        let f = try makeFixture()
        let request = ManualActionRequest(botID: f.bot.id, threadID: f.thread.id, kind: .login, reason: "Entre")
        try f.router.manualActionStore.upsert(request)
        BotComputerControl.shared.requestHelp(request)
        BotComputerControl.shared.take(f.bot.id)
        XCTAssertNotNil(f.router.manualActionStore.open(threadID: f.thread.id))
        f.botsVM.delete(id: f.bot.id, navigate: false)
        XCTAssertNil(f.router.manualActionStore.open(threadID: f.thread.id), "deleted bot leaves no open request")
        XCTAssertNil(BotComputerControl.shared.openRequest(f.bot.id))
        XCTAssertFalse(BotComputerControl.shared.isControlledByUser(f.bot.id))
    }

    /// WHY: a transient Docker provision failure must heal without the user pressing retry, while a permanent one fails at once.
    func test_provisionRetry_transientThenSuccessNeedsNoUserAction() throws {
        var attempts = 0
        var slept: [TimeInterval] = []
        let value = try BotVMProvisionRetry.run(sleep: { slept.append($0) }) {
            attempts += 1
            if attempts == 1 { throw BotComputerDockerError.probeTimedOut }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(slept, [2])
    }

    func test_provisionRetry_permanentErrorFailsWithoutRetry() {
        // WHY: a missing CLI or stopped daemon will not heal by waiting; retrying only delays the message.
        var attempts = 0
        var slept: [TimeInterval] = []
        XCTAssertThrowsError(try BotVMProvisionRetry.run(sleep: { slept.append($0) }) {
            attempts += 1
            throw BotComputerDockerError.cliMissing
        }) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .cliMissing)
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(slept.isEmpty)
    }

    func test_provisionRetry_persistentTransientFailsWithOriginalErrorAfterThreeAttempts() {
        // WHY: a daemon that stays busy must surface the real Docker error, bounded in time.
        var attempts = 0
        var slept: [TimeInterval] = []
        XCTAssertThrowsError(try BotVMProvisionRetry.run(sleep: { slept.append($0) }) {
            attempts += 1
            throw BotComputerDockerError.provisioningFailed
        }) { error in
            XCTAssertEqual(error as? BotComputerDockerError, .provisioningFailed)
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(slept, [2, 5])
    }

    private final class TopDocker: BotComputerDockerClienting, @unchecked Sendable {
        var tops: [String: String] = [:]
        var execs: [(name: String, command: [String], user: String?)] = []
        func info() throws -> String { "" }
        func imageExists(tag: String) throws -> Bool { true }
        func imageLabel(tag: String, key: String) throws -> String { "" }
        func imageID(tag: String) throws -> String { "" }
        func build(context: URL, tag: String) throws {}
        func create(options: BotComputerContainerCreateOptions) throws -> String { "" }
        func start(name: String) throws {}
        func stop(name: String) throws {}
        func inspect(name: String) throws -> BotComputerContainerInspect { throw BotComputerGuestError.notReady }
        func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data {
            execs.append((name, command, user))
            return Data()
        }
        func rename(from: String, to: String) throws {}
        func ensureNetwork(name: String) throws {}
        func remove(name: String) throws {}
        func removeMatching(namePrefix: String) throws {}
        func top(name: String) throws -> String { tops[name] ?? "" }
    }

    /// WHY: a restart must not leave an unowned `bash -lc` driving a bot VM, and idle VMs must stay untouched.
    func test_orphanScan_reapsOnlyContainersWithBashLc() {
        let docker = TopDocker()
        docker.tops["busy"] = "PID CMD\n42 bash -lc sleep 999"
        docker.tops["idle"] = "PID CMD\n1 supervisord"
        let found = BotVMOrphanScan.reap(docker: docker, names: ["busy", "idle"])
        XCTAssertEqual(found, ["busy"])
        XCTAssertEqual(docker.execs.count, 1)
        XCTAssertEqual(docker.execs.first?.name, "busy")
        XCTAssertEqual(docker.execs.first?.command, ["pkill", "-f", "bash -lc"])
        XCTAssertEqual(docker.execs.first?.user, "root")
    }

    func test_deskHeaderHasNoContextMenu_becauseContextIsAutomatic() throws {
        // WHY: the owner (2026-10-19) did not know what "Context: Legacy" did. A new
        // conversation inherits its context and workspace bots get theirs at creation.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Text(\"Context: \\(vm.selectedPinnedContextLabel)\")"))
        XCTAssertFalse(source.contains("bots.desk.context\")"))
    }
}
