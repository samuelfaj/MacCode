import XCTest
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import SocketServer

/// WHY: the iPhone edits the same Schedule Tasks as the Mac (owner, 2026-10-19).
/// Frequencies and efforts must survive the wire exactly, and the list must
/// carry Bot schedules too so one screen shows both kinds.
final class ScheduledTaskRemoteTests: XCTestCase {
    func test_frequencyAndEffortRoundTripTheWire() throws {
        let rule = ScheduledFrequencyRule(frequency: .weekly, scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
                                          intervalHours: 3, localTimeHour: 7, localTimeMinute: 45,
                                          weekdays: [.monday, .friday], monthlyDay: 12)
        XCTAssertEqual(try ScheduledTaskRemoteWire.decodeRule(ScheduledTaskRemoteWire.encodeRule(rule)), rule)
        XCTAssertEqual(ScheduledTaskRemoteWire.effort(ScheduledTaskRemoteWire.effort(.automatic)), .automatic)
        XCTAssertEqual(ScheduledTaskRemoteWire.effort(ScheduledTaskRemoteWire.effort(.fixed(.high))), .fixed(.high))
        XCTAssertThrowsError(try ScheduledTaskRemoteWire.decodeRule(.object(["frequency": .string("yearly")])))
    }

    @MainActor
    func test_listCarriesWorkspaceAndBotSchedules() throws {
        let directory = NSTemporaryDirectory() + "RC2SchedRemote-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let bot = try context.botStore.create(name: "Writer", title: "", description: "", handle: "writer")
        var spec = BotScheduleSpec(provider: .distill, providerInstanceID: "distill", model: "auto")
        spec.distillExecutionMode = .ultracode
        try context.botStore.saveRoutine(BotRoutineDefinition(botID: bot.id, name: "Digest", prompt: "Summarize",
                                                               scheduleNote: spec.displayNote(), scheduleSpecJSON: spec.encodedJSON()))
        let list = try router.listScheduledTasksRemote()
        let botTask = try XCTUnwrap(list.objectValue?["bot_tasks"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(botTask["title"], .string("Digest"))
        XCTAssertEqual(botTask["bot_handle"], .string("writer"))
        XCTAssertEqual(botTask["ultracode"], .bool(true))
        XCTAssertEqual(list.objectValue?["tasks"]?.arrayValue?.count, 0)
    }

    func test_maxConcurrentRunsReadsBackOnTheWire_becauseClientsMustSeeTheLimitTheyWrote() throws {
        // WHY: iPhone edits the same limit; a missing readback key would show the default and overwrite it on save.
        var task = try makeWireTask()
        task.maxConcurrentRuns = 3
        let encoded = ScheduledTaskRemoteWire.encodeTask(task, workspaceName: nil, active: nil)
        XCTAssertEqual(encoded.objectValue?["max_concurrent_runs"], .number(3))
    }

    func test_scheduledTaskMutationsEnterTheHostMutationGate() {
        for method in ScheduledTaskRemoteWire.methods {
            XCTAssertTrue(JSONRPCDispatcher.hostMutationMethods.contains(method), method)
            XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod(method), method)
        }
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("scheduled_task.list"))
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "scheduled_task.list"), "read")
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "scheduled_task.save"), "write")
    }

    @MainActor
    func test_saveBotSchedulePinsTheRequestedDestinationAndReplaysWithoutDuplication() async throws {
        let directory = NSTemporaryDirectory() + "RC2SharedVMSchedule-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true }
        let bot = try context.botStore.create(name: "Writer", title: "", description: "")
        let machine = try context.botStore.saveVirtualMachine(name: "Research")
        let spec = BotScheduleSpec(model: "auto")
        let params: [String: JSONValue] = [
            "client_request_id": .string(UUID().uuidString),
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "title": .string("Research"), "prompt": .string("Summarize"),
            "enabled": .bool(true),
            "schedule_spec_json": .string(spec.encodedJSON()),
            "execution_destination": .string(BotExecutionDestination.virtualMachine(machine.id).storageValue),
        ]
        let dispatcher = JSONRPCDispatcher(router: router)
        let mutation = MutationRequestContext(ownerFingerprint: "titio-schedule-test", hostId: context.liveActivityHostIdentity.serverId, bootEpoch: 0)
        func save(_ values: [String: JSONValue]) async throws {
            let response = await dispatcher.dispatch(.init(jsonrpc: "2.0", id: .number(1), method: "scheduled_task.save", params: values), mutationContext: mutation)
            XCTAssertNil(response.error, "\(String(describing: response.error))")
        }
        try await save(params)
        try await save(params)
        let routines = try context.botStore.listRoutines(botID: bot.id)
        XCTAssertEqual(routines.count, 1)
        XCTAssertTrue(try XCTUnwrap(routines.first).activation.isEnabled)
        let saved = try XCTUnwrap(routines.first?.definition.scheduleSpec)
        XCTAssertEqual(saved.executionDestination, .virtualMachine(machine.id))
        XCTAssertEqual(BotsViewModel.routineRouting(saved, base: BotDeskRouting()).executionDestination, saved.executionDestination)

        var edit = params
        edit["client_request_id"] = .string(UUID().uuidString)
        edit["task_id"] = .string(try XCTUnwrap(routines.first).definition.id.value.uuidString.lowercased())
        edit["enabled"] = .bool(false)
        try await save(edit)
        XCTAssertFalse(try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first).activation.isEnabled)
        edit["client_request_id"] = .string(UUID().uuidString)
        edit.removeValue(forKey: "enabled")
        try await save(edit)
        XCTAssertFalse(try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first).activation.isEnabled)
    }

    @MainActor
    func test_oldBotScheduleSavePreservesOmittedOptionsAndExplicitDestinationClear() async throws {
        let directory = NSTemporaryDirectory() + "RC2ScheduleLegacy-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true }
        let bot = try context.botStore.create(name: "Writer", title: "", description: "")
        let otherBot = try context.botStore.create(name: "Other", title: "", description: "")
        let machine = try context.botStore.saveVirtualMachine(name: "Research")
        var original = BotScheduleSpec(model: "original")
        original.executionDestination = .virtualMachine(machine.id)
        original.distillExecutionMode = .ultrasave
        original.permissionMode = .autoAcceptEdits
        original.reasoningModel = "worker"
        let routine = BotRoutineDefinition(
            botID: bot.id, name: "Research", prompt: "Summarize", scheduleSpecJSON: original.encodedJSON()
        )
        try context.botStore.saveRoutine(routine)
        var params: [String: JSONValue] = [
            "client_request_id": .string(UUID().uuidString),
            "bot_id": .string(bot.id.value.uuidString), "task_id": .string(routine.id.value.uuidString),
            "title": .string("Updated"), "prompt": .string("Review"),
            "schedule_spec_json": .string(BotScheduleSpec(model: "updated").encodedJSON()),
        ]
        let result = try await router.saveScheduledTaskRemote(params: params)
        XCTAssertEqual(result.objectValue?["status"], .string("completed"))
        let saved = try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first?.definition.scheduleSpec)
        XCTAssertEqual(saved.model, "updated")
        XCTAssertEqual(saved.executionDestination, original.executionDestination)
        XCTAssertEqual(saved.distillExecutionMode, .ultrasave)
        XCTAssertEqual(saved.permissionMode, .autoAcceptEdits)
        XCTAssertEqual(saved.reasoningModel, "worker")

        params["client_request_id"] = .string(UUID().uuidString)
        params["execution_destination"] = .null
        let cleared = try await router.saveScheduledTaskRemote(params: params)
        XCTAssertEqual(cleared.objectValue?["status"], .string("completed"))
        XCTAssertNil(try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first?.definition.scheduleSpec).executionDestination)

        params["client_request_id"] = .string(UUID().uuidString)
        params["bot_id"] = .string(otherBot.id.value.uuidString)
        let rejected = try await router.saveScheduledTaskRemote(params: params)
        XCTAssertEqual(rejected.objectValue?["status"], .string("failed"))
        XCTAssertTrue(try context.botStore.listRoutines(botID: otherBot.id).isEmpty)
        XCTAssertEqual(try context.botStore.listRoutines(botID: bot.id).count, 1)
    }

    @MainActor
    func test_invalidBotScheduleDoesNotCreateAnUnrunnableTask() async throws {
        let directory = NSTemporaryDirectory() + "RC2InvalidBotSchedule-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true }
        let bot = try context.botStore.create(name: "Writer", title: "", description: "")
        var spec = BotScheduleSpec(model: "auto")
        spec.timeZoneIdentifier = "invalid"
        let params: [String: JSONValue] = [
            "client_request_id": .string(UUID().uuidString),
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "title": .string("Digest"), "prompt": .string("Summarize"),
            "schedule_spec_json": .string(spec.encodedJSON()), "enabled": .bool(true)
        ]
        let result = try await router.saveScheduledTaskRemote(params: params)
        XCTAssertEqual(result.objectValue?["status"], .string("failed"))
        XCTAssertEqual(result.objectValue?["readback"]?.objectValue?["error_code"], .number(-32602))
        XCTAssertTrue(result.objectValue?["readback"]?.objectValue?["error"]?.stringValue?.contains("time zone") == true)
        let replay = try await router.saveScheduledTaskRemote(params: params)
        XCTAssertEqual(replay, result)
        XCTAssertTrue(try context.botStore.listRoutines(botID: bot.id).isEmpty)
    }

    @MainActor
    func test_invalidSystemUserCannotSilentlyBecomeTheCurrentAccount() async throws {
        let directory = NSTemporaryDirectory() + "RC2ScheduleUser-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Schedule", cwd: directory)
        do {
            _ = try await router.saveScheduledTaskRemote(params: [
                "workspace_id": .string(workspace.id.value.uuidString),
                "title": .string("Task"), "prompt": .string("Build"),
                "run_as_user": .string("missing-user-" + UUID().uuidString)
            ])
            XCTFail("an unavailable account must not be substituted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("eligible system user"), "\(error)")
        }
        XCTAssertTrue(try ScheduledTaskStore(db: context.db).list().isEmpty)
    }

    private func makeWireTask() throws -> ScheduledTask {
        ScheduledTask(
            title: "Audit", prompt: "Inspect", workspaceID: WorkspaceID(),
            workspacePathSnapshot: "/tmp", runAsUser: "sam", runAsUID: 501,
            provider: .distill, providerInstanceID: "distill-acp", model: "auto", reasoningEffort: .high,
            recurrence: .daily(at: ScheduledLocalTime(hour: 8, minute: 15)!),
            timeZoneIdentifier: "UTC", isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
