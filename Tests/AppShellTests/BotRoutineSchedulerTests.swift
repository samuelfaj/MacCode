import XCTest
import AgentRuntime
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// Bot scheduled tasks ("routines") never ran: nothing read an Active task's
/// schedule and started a run. These pin the executor end to end, from the
/// app timer's tick to a real provider request.
@MainActor
final class BotRoutineSchedulerTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        AgentProvider.selectableForTesting = nil
        directory = NSTemporaryDirectory() + "rc-bot-routine-scheduler-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
        directory = nil
    }

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let runner: ControlledBotHandoffRunner
        let vm: BotsViewModel
        let scheduler: BotRoutineScheduler
    }

    private func makeFixture() throws -> Fixture {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [
                AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill),
                AgentModelDescriptor(id: "main-b", label: "Main B", provider: .distill),
            ],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp"
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        vm.replaceProvidersForTests([snapshot])
        SettingsStore(db: context.db).update {
            $0.botsControlPlaneEnabled = true
            $0.botsAutonomyEnabled = true
        }
        let scheduler = BotRoutineScheduler(
            authority: { [weak router] in router?.botRoutineAuthority },
            botsViewModel: { [weak vm] in vm }
        )
        return Fixture(context: context, router: router, runner: runner, vm: vm, scheduler: scheduler)
    }

    /// An Active daily task whose slot is the first whole minute after `base`.
    private func saveActiveRoutine(
        _ f: Fixture,
        bot: BotDefinition,
        base: Date,
        destination: BotExecutionDestination? = nil,
        permission: AgentPermissionMode? = nil
    ) throws -> (routine: BotRoutineDefinition, slot: Date) {
        var spec = BotScheduleSpec(
            provider: .distill,
            providerInstanceID: "distill-acp",
            model: "main-b",
            frequency: .daily,
            localTime: base.addingTimeInterval(60),
            timeZoneIdentifier: "UTC"
        )
        spec.executionDestination = destination
        spec.permissionMode = permission
        let routine = BotRoutineDefinition(
            botID: bot.id,
            name: "Review Empath",
            prompt: "Review the open PRs and report",
            scheduleNote: spec.displayNote(),
            scheduleSpecJSON: spec.encodedJSON(),
            createdAt: base,
            updatedAt: base
        )
        try f.context.botStore.saveRoutine(routine, now: base)
        try f.context.botStore.setRoutineEnabled(id: routine.id, enabled: true, now: base)
        let minute = floor(base.addingTimeInterval(60).timeIntervalSince1970 / 60) * 60
        return (routine, Date(timeIntervalSince1970: minute))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private func routineRow(_ f: Fixture, botID: BotID) async throws -> [String: JSONValue] {
        let listed = try await f.router.dispatchPairedBotRemote(
            method: "bot.routine.list",
            params: ["bot_id": .string(botID.value.uuidString.lowercased())]
        )
        return try XCTUnwrap(listed.objectValue?["routines"]?.arrayValue?.first?.objectValue)
    }

    func test_scheduledTitioUsesTheCurrentControlCenterWithoutReplacingCustomInstructions() async throws {
        let f = try makeFixture()
        let titio = try f.vm.create(name: "Titio", handle: "titio", soul: "Always summarize in Portuguese.")
        let (_, slot) = try saveActiveRoutine(f, bot: titio, base: Date())

        f.scheduler.tick(now: slot.addingTimeInterval(5))
        await f.scheduler.settleForTesting()
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertTrue(request.prompt.contains(TitioIdentity.orchestrationDirective))
        XCTAssertTrue(request.prompt.contains("Always summarize in Portuguese."))
        XCTAssertTrue(request.prompt.contains("Review the open PRs and report"))
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_dueSlotAfterContextRevocationRunsLegacyAndNeverCreatesAPinOrGrant() async throws {
        // WHY: a routine has no contextual contract. Revoking a Bot's context grant
        // before the slot drains must neither block the legacy run nor let the
        // scheduler mint a contextual pin or a new binding on its own.
        let f = try makeFixture()
        let elephant = try f.vm.create(name: "Elephant", title: "Developer")
        let host = f.context.liveActivityHostIdentity.serverId
        let granted = try f.context.botStore.grantContext(hostID: host, botID: elephant.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        let revoked = try f.context.botStore.revokeContext(hostID: host, botID: elephant.id, context: .general, expectedRevision: granted.policyRevision)
        let bindingsBefore = try f.context.botStore.listContextBindings(hostID: host, botID: elephant.id)
        let base = Date()
        let (_, slot) = try saveActiveRoutine(f, bot: elephant, base: base)

        f.scheduler.tick(now: slot.addingTimeInterval(5))
        await f.scheduler.settleForTesting()
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started, "a revoked contextual grant does not block the legacy routine")
        let conversation = try XCTUnwrap(try f.context.botStore.listConversations(botID: elephant.id).first)
        XCTAssertNil(try f.context.botStore.conversationContextPin(conversationID: conversation.id), "the scheduler must not pin a context")
        let bindingsAfter = try f.context.botStore.listContextBindings(hostID: host, botID: elephant.id)
        XCTAssertEqual(bindingsAfter.map(\.policyRevision), bindingsBefore.map(\.policyRevision), "no grant or revision change")
        XCTAssertEqual(bindingsAfter.first?.state, .revoked)
        XCTAssertEqual(bindingsAfter.first?.policyRevision, revoked.policyRevision)
        let request = try XCTUnwrap(f.runner.requests.first)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_activeTaskRunsOnceWhenItsSlotIsDue_inANewConversationWithoutTouchingTheDesk() async throws {
        // WHY: "Review Empath — Daily" was Active with "Scheduler online" and
        // never ran. A due slot must start ONE real run of the Instruction in a
        // new conversation on the task's route, while the user keeps the
        // bot, conversation and screen they had open.
        let f = try makeFixture()
        let elephant = try f.vm.create(name: "Elephant", title: "Developer")
        let star = try f.vm.create(name: "Star", title: "Helper")
        f.vm.openDesk(star)
        XCTAssertTrue(f.vm.createDeskThread())
        let openConversation = try XCTUnwrap(f.vm.selectedConversation)
        let screen = f.vm.screen
        let base = Date()
        let (routine, slot) = try saveActiveRoutine(f, bot: elephant, base: base)

        f.scheduler.tick(now: base)
        await f.scheduler.settleForTesting()
        XCTAssertTrue(f.runner.requests.isEmpty, "nothing runs before the slot")
        XCTAssertTrue(try f.context.botStore.listConversations(botID: elephant.id).isEmpty)

        f.scheduler.tick(now: slot.addingTimeInterval(5))
        await f.scheduler.settleForTesting()
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started, "the slot must reach the provider")
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertTrue(request.prompt.contains(routine.prompt), "the Instruction is the user request")
        XCTAssertEqual(request.model, "main-b", "the task's own route runs")
        let conversations = try f.context.botStore.listConversations(botID: elephant.id)
        XCTAssertEqual(conversations.count, 1, "each execution owns a new conversation")
        let conversation = try XCTUnwrap(conversations.first)
        XCTAssertEqual(f.vm.effectiveDeskRouting(for: conversation)?.model, "main-b",
                       "follow-ups in that conversation keep the task's route")
        XCTAssertEqual(f.vm.selectedBotID, star.id, "a background run never steals the selection")
        XCTAssertEqual(f.vm.selectedConversation?.id, openConversation.id)
        XCTAssertEqual(f.vm.screen, screen)

        let row = try await routineRow(f, botID: elephant.id)
        XCTAssertEqual(row["last_result"]?.stringValue, "started")
        XCTAssertEqual(row["last_run_id"]?.stringValue, request.runId.value.uuidString.lowercased())
        XCTAssertEqual(row["last_conversation_id"]?.stringValue, conversation.id.value.uuidString.lowercased())
        XCTAssertEqual(row["next_run_at"]?.intValue, Int(slot.addingTimeInterval(86_400).timeIntervalSince1970),
                       "iOS sees the next real slot")

        f.scheduler.tick(now: slot.addingTimeInterval(35))
        await f.scheduler.settleForTesting()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "the same slot never runs twice")
        XCTAssertEqual(try f.context.botStore.listConversations(botID: elephant.id).count, 1)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_workspaceBotScheduledRunIsPinnedToItsWorkspace_becauseItMustListInThatWorkspace() async throws {
        // WHY: the workspace Conversations list shows only threads with a workspace and a
        // context pin. A workspace-exclusive Bot's scheduled run must land there, not as an
        // unpinned, workspace-less thread that no workspace can show.
        let f = try makeFixture()
        let cwd = NSTemporaryDirectory() + "rc-bot-routine-ws-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        let workspace = try f.router.createWorkspace(name: "Routine WS", cwd: cwd)
        let bot = try f.vm.create(name: "Elephant", title: "Developer", workspaceID: workspace.id)
        _ = try f.context.botStore.grantContext(
            hostID: f.context.liveActivityHostIdentity.serverId, botID: bot.id,
            context: .workspace(workspace.id), actions: [.read, .send], expectedRevision: nil
        )
        let (routine, slot) = try saveActiveRoutine(f, bot: bot, base: Date())

        f.scheduler.tick(now: slot.addingTimeInterval(5))
        await f.scheduler.settleForTesting()
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started, "the slot must reach the provider")
        let conversation = try XCTUnwrap(try f.context.botStore.listConversations(botID: bot.id).first)
        let pin = try XCTUnwrap(try f.context.botStore.conversationContextPin(conversationID: conversation.id))
        XCTAssertEqual(pin.context, .workspace(workspace.id))
        XCTAssertEqual(conversation.title, routine.name)
        let thread = try XCTUnwrap(try f.context.threadRepo.get(id: try XCTUnwrap(conversation.linkedAgentThreadID)))
        XCTAssertEqual(thread.workspaceId, workspace.id)
        XCTAssertEqual(thread.actor, .bot(bot.id))
        let request = try XCTUnwrap(f.runner.requests.first)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_workspaceScheduleUsesSavedMacDestinationWithoutStartingBotsDefaultVM() async throws {
        let f = try makeFixture()
        let workspace = try f.router.createWorkspace(name: "Schedule", cwd: directory)
        let bot = try f.vm.create(name: "Builder", title: "", workspaceID: workspace.id)
        try f.context.botStore.setExecutionDestination(.ownVM, botID: bot.id)
        _ = try f.context.botStore.grantContext(
            hostID: f.context.liveActivityHostIdentity.serverId, botID: bot.id,
            context: .workspace(workspace.id), actions: [.read, .send], expectedRevision: nil
        )
        let docker = ScheduledDocker()
        docker.startError = BotComputerDockerError.provisioningFailed
        f.vm.computerGuestService = BotComputerGuestService(
            appSupport: f.context.appSupportDirectory, docker: docker, observeAttempts: 1, observeDelay: 0
        )
        let (_, slot) = try saveActiveRoutine(f, bot: bot, base: Date(), destination: .mac, permission: .supervised)
        f.scheduler.tick(now: slot.addingTimeInterval(5))
        await f.scheduler.settleForTesting()
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started, "a Mac schedule must run even when Docker cannot start")
        XCTAssertTrue(docker.containers.isEmpty, "the saved destination must control preparation")
        let request = try XCTUnwrap(f.runner.requests.first)
        let thread = try XCTUnwrap(f.context.threadRepo.get(id: request.threadId))
        XCTAssertEqual(request.permissionMode, .supervised)
        XCTAssertEqual(thread.workspaceId, workspace.id)
        XCTAssertEqual(thread.executionTarget, .mac)
        XCTAssertEqual(try f.context.botStore.threadExecutionDestination(thread.id), .mac)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_workspaceSchedulePinsNamedVMOverrideBeforeSending() async throws {
        let f = try makeFixture()
        let workspace = try f.router.createWorkspace(name: "Schedule", cwd: directory)
        let bot = try f.vm.create(name: "Builder", title: "", workspaceID: workspace.id)
        _ = try f.context.botStore.grantContext(
            hostID: f.context.liveActivityHostIdentity.serverId, botID: bot.id,
            context: .workspace(workspace.id), actions: [.read, .send], expectedRevision: nil
        )
        let machine = try f.context.botStore.saveVirtualMachine(name: "Build", workspaceID: workspace.id)
        let (_, slot) = try saveActiveRoutine(f, bot: bot, base: Date(), destination: .virtualMachine(machine.id))
        f.scheduler.tick(now: slot.addingTimeInterval(5))
        await f.scheduler.settleForTesting()
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started, "a new contextual schedule must accept its saved destination")
        let request = try XCTUnwrap(f.runner.requests.first)
        let thread = try XCTUnwrap(f.context.threadRepo.get(id: request.threadId))
        XCTAssertEqual(thread.workspaceId, workspace.id)
        XCTAssertEqual(thread.executionTarget, .vm)
        XCTAssertEqual(try f.context.botStore.threadExecutionDestination(thread.id), .virtualMachine(machine.id))
        XCTAssertEqual(try f.context.botStore.guestResourceID(botID: bot.id, threadID: thread.id), machine.storageID)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_invalidContextualDestinationDoesNotFallBackToAnUnscopedConversation() throws {
        let f = try makeFixture()
        let legacy = try f.router.createWorkspace(name: "Old", cwd: directory)
        let workspace = try f.router.createWorkspace(name: "Current", cwd: directory + "/current")
        let bot = try f.vm.create(name: "Builder", title: "", workspaceID: legacy.id)
        _ = try f.context.botStore.grantContext(
            hostID: f.context.liveActivityHostIdentity.serverId, botID: bot.id,
            context: .workspace(workspace.id), actions: [.read, .send], expectedRevision: nil
        )
        let machine = try f.context.botStore.saveVirtualMachine(name: "Old VM", workspaceID: legacy.id)
        let (definition, _) = try saveActiveRoutine(f, bot: bot, base: Date(), destination: .virtualMachine(machine.id))
        let routine = try XCTUnwrap(f.context.botStore.listRoutines(botID: bot.id).first)
        XCTAssertEqual(routine.definition.id, definition.id)
        XCTAssertThrowsError(try f.vm.enqueueScheduledRoutine(routine)) {
            XCTAssertTrue($0.localizedDescription.contains("another workspace"), "\($0)")
        }
        XCTAssertTrue(try f.context.botStore.listConversations(botID: bot.id).isEmpty)
        XCTAssertTrue(try f.context.threadRepo.list(workspaceId: workspace.id).isEmpty)
        XCTAssertTrue(f.runner.requests.isEmpty)
    }

    func test_malformedSavedScheduleDoesNotRunWithDefaultSettings() throws {
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Builder", title: "")
        let definition = BotRoutineDefinition(botID: bot.id, name: "Broken", prompt: "Build",
            scheduleNote: "Daily 09:00", scheduleSpecJSON: "{invalid")
        try f.context.botStore.saveRoutine(definition)
        let routine = try XCTUnwrap(f.context.botStore.listRoutines(botID: bot.id).first)
        XCTAssertThrowsError(try f.vm.enqueueScheduledRoutine(routine)) {
            XCTAssertTrue($0.localizedDescription.contains("saved schedule settings are invalid"), "\($0)")
        }
        XCTAssertTrue(try f.context.botStore.listConversations(botID: bot.id).isEmpty)
        XCTAssertTrue(f.runner.requests.isEmpty)
    }

    func test_pausedSchedulerOrDisabledTaskNeverRuns() async throws {
        // WHY: "Scheduler paused" and a Paused task are promises not to run.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Elephant", title: "Developer")
        let base = Date()
        let (routine, slot) = try saveActiveRoutine(f, bot: bot, base: base)
        f.scheduler.tick(now: base)
        await f.scheduler.settleForTesting()

        SettingsStore(db: f.context.db).update { $0.botsAutonomyEnabled = false }
        f.scheduler.tick(now: slot.addingTimeInterval(5))
        await f.scheduler.settleForTesting()

        SettingsStore(db: f.context.db).update { $0.botsAutonomyEnabled = true }
        try f.context.botStore.setRoutineEnabled(id: routine.id, enabled: false)
        f.scheduler.tick(now: slot.addingTimeInterval(86_405))
        await f.scheduler.settleForTesting()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(f.runner.requests.isEmpty)
        XCTAssertTrue(try f.context.botStore.listConversations(botID: bot.id).isEmpty)
    }

    func test_pairedRunNowDoesNotRequireTheDesktopScreenCacheForGuestExecution() async throws {
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Star", title: "Developer")
        try f.context.botStore.setExecutionDestination(.ownVM, botID: bot.id)
        f.vm.dockerGuestReadyOverrideForTesting = false
        let (routine, _) = try saveActiveRoutine(f, bot: bot, base: Date())

        let ran = try await f.router.dispatchPairedBotRemote(method: "bot.routine.run", params: [
            "client_request_id": .string("run-now-cold-screen"),
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "routine_id": .string(routine.id.value.uuidString.lowercased()),
        ])

        XCTAssertEqual(ran.objectValue?["readback"]?.objectValue?["result"]?.stringValue, "started",
                       "the guest resolver prepares the VM even when no desktop screen has been opened")
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        let placement = try XCTUnwrap(f.context.threadRepo.guestPlacement(of: request.threadId))
        XCTAssertTrue(placement.runsInGuest, "admission must preserve VM execution, never fall back to the Mac")
        XCTAssertFalse(f.vm.isGuestRunning(bot.id), "no desktop screen is required for the provider run")
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_pairedRunNowStartsARealRunOfTheInstruction() async throws {
        // WHY: iOS Run now answered "accepted" and ran nothing.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Elephant", title: "Developer")
        let (routine, _) = try saveActiveRoutine(f, bot: bot, base: Date())

        let ran = try await f.router.dispatchPairedBotRemote(method: "bot.routine.run", params: [
            "client_request_id": .string("run-now"),
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "routine_id": .string(routine.id.value.uuidString.lowercased()),
        ])

        XCTAssertEqual(ran.objectValue?["status"]?.stringValue, "completed")
        XCTAssertEqual(ran.objectValue?["readback"]?.objectValue?["result"]?.stringValue, "started")
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertTrue(request.prompt.contains(routine.prompt))
        XCTAssertEqual(try f.context.botStore.listConversations(botID: bot.id).count, 1)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_dockerBotWaitsForItsComputerThenRuns_andAComputerThatCannotStartIsReported() async throws {
        // WHY: Elephant runs on a Docker desktop. A slot that finds the
        // computer stopped must start it and wait, not lose the slot to "not
        // ready"; when it cannot start, the failure is recorded and shown.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Elephant", title: "Developer")
        f.vm.desktopKindOverrideForTesting = .dockerDesktop
        f.vm.dockerGuestReadyOverrideForTesting = nil
        let docker = ScheduledDocker()
        f.vm.computerGuestService = BotComputerGuestService(
            appSupport: f.context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )
        let base = Date()
        let (_, slot) = try saveActiveRoutine(f, bot: bot, base: base)
        XCTAssertFalse(f.vm.isGuestRunning(bot.id))
        f.scheduler.tick(now: base)
        await f.scheduler.settleForTesting()

        f.scheduler.tick(now: slot.addingTimeInterval(5))
        await f.scheduler.settleForTesting()
        XCTAssertTrue(f.vm.isGuestRunning(bot.id), "the slot started the stopped computer")
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started, "and then ran the task")
        XCTAssertEqual(try f.context.botStore.listConversations(botID: bot.id).count, 1)
        let request = try XCTUnwrap(f.runner.requests.first)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")

        f.vm.guestRunningByBot[bot.id.value] = false
        docker.startError = BotComputerDockerError.provisioningFailed
        docker.containers.removeAll()
        f.scheduler.tick(now: slot.addingTimeInterval(86_405))
        await f.scheduler.settleForTesting()
        let row = try await routineRow(f, botID: bot.id)
        XCTAssertEqual(row["last_result"]?.stringValue, "failed", "never a silent success")
        XCTAssertFalse(row["last_error"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(f.runner.requests.count, 1, "no run starts on a computer that is not up")
        XCTAssertEqual(try f.context.botStore.listConversations(botID: bot.id).count, 1)
        let attention = try XCTUnwrap(try f.context.botStore.listAttention().first)
        XCTAssertEqual(attention.kind, .blocked, "the Mac Activity shows the failed task")
        XCTAssertEqual(attention.title, "Scheduled task did not start")
    }

    func test_runNowOnAStoppedDockerBotStartsItsComputerThenRuns() async throws {
        // WHY: Run Now in Schedule Tasks failed at once with "Docker desktop is
        // not ready." while a scheduled fire of the same task waits for the computer.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Star", title: "Developer")
        f.vm.desktopKindOverrideForTesting = .dockerDesktop
        f.vm.dockerGuestReadyOverrideForTesting = nil
        f.vm.computerGuestService = BotComputerGuestService(
            appSupport: f.context.appSupportDirectory,
            docker: ScheduledDocker(),
            observeAttempts: 1,
            observeDelay: 0
        )
        let (routine, _) = try saveActiveRoutine(f, bot: bot, base: Date())
        f.vm.openScheduleTasks()

        f.vm.runRoutineNow(id: routine.id)

        XCTAssertNil(f.vm.errorMessage)
        XCTAssertTrue(f.vm.isRoutineRunning(id: routine.id), "the row shows the start right away")
        XCTAssertTrue(f.vm.isRoutineStartingGuest(id: routine.id), "the row says the Bot computer is starting")
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertFalse(f.vm.isRoutineStartingGuest(id: routine.id), "the label clears once the computer is up")
        XCTAssertTrue(started, f.vm.errorMessage ?? "Run Now never reached the provider")
        XCTAssertNil(f.vm.errorMessage)
        XCTAssertTrue(f.vm.isGuestRunning(bot.id))
        let request = try XCTUnwrap(f.runner.requests.first)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }
}

private final class ScheduledDocker: BotComputerDockerClienting, @unchecked Sendable {
    var containers: [String: BotComputerContainerInspect] = [:]
    var startError: Error?

    func info() throws -> String { "ok" }
    func imageExists(tag: String) throws -> Bool { true }
    func imageLabel(tag: String, key: String) throws -> String {
        key == BotComputerGuestSpec.recipeLabelKey ? BotComputerGuestSpec.recipeRevision : ""
    }
    func imageID(tag: String) throws -> String { "img" }
    func build(context: URL, tag: String) throws {}
    func create(options: BotComputerContainerCreateOptions) throws -> String {
        containers[options.name] = BotComputerContainerInspect(running: false, imageID: "img", hostPort: 49152)
        return options.name
    }
    func start(name: String) throws {
        if let startError { throw startError }
        containers[name] = BotComputerContainerInspect(running: true, imageID: "img", hostPort: 49152)
    }
    func stop(name: String) throws {}
    func inspect(name: String) throws -> BotComputerContainerInspect {
        guard let value = containers[name] else { throw BotComputerGuestError.notReady }
        return value
    }
    func exec(
        name: String,
        command: [String],
        user: String?,
        detach: Bool,
        workdir: String?,
        environment: [String: String]
    ) throws -> Data {
        BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)
    }
    func rename(from: String, to: String) throws {
        containers[to] = containers[from]
        containers[from] = nil
    }
    func ensureNetwork(name: String) throws {}
    func remove(name: String) throws { containers[name] = nil }
    func removeMatching(namePrefix: String) throws {}
}
