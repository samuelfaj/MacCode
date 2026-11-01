import XCTest
import AgentRuntime
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// P1: paired `bot.send` runs exactly the route the Mac desk shows for that
/// conversation, Worker included, and that route is persisted per
/// conversation in the DB.
@MainActor
final class BotDeskRoutingParityTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        AgentProvider.selectableForTesting = nil
        directory = NSTemporaryDirectory() + "rc-bot-desk-routing-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
        // A view model reads the shared last-used model before a test injects its own store.
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
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
    }

    private func makeFixture(lastUsed: String? = nil) throws -> Fixture {
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
            id: "distill-acp",
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )
        router.providerSnapshotsOverrideForTesting = [snapshot]
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let suiteName = "rc2-bot-desk-routing-" + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let lastModels = AgentLastModelStore(defaults: suite)
        if let lastUsed { lastModels.remember(model: lastUsed, for: .distill) }
        vm.lastModelStore = lastModels
        vm.replaceProvidersForTests([snapshot])
        return Fixture(context: context, router: router, runner: runner, vm: vm)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func test_receiptlessHostSendToANonSelectedConversation_runsThatConversationsRoute() async throws {
        // WHY: an iOS send without a routing receipt used to fall back to a
        // hardcoded grok route; it must run what the Mac desk set for that
        // conversation, even when another conversation is open.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let planned = try XCTUnwrap(f.vm.selectedConversation)
        f.vm.setDeskModel("main-b")
        f.vm.setDeskReasoningModel("main-a")
        XCTAssertTrue(f.vm.createDeskThread())
        f.vm.setDeskModel("main-a")
        f.vm.setDeskReasoningModel(nil)
        XCTAssertNotEqual(f.vm.selectedConversation?.id, planned.id)

        let sent = try f.vm.enqueueHostMessage(botID: bot.id, text: "go", conversationID: planned.id)

        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.provider, .distill)
        XCTAssertEqual(request.model, "main-b", "the planned conversation's Main, not the open one's")
        XCTAssertEqual(request.reasoningModel, "main-a", "its Worker too")
        let effective = try XCTUnwrap(sent.objectValue?["effective_routing"]?.objectValue)
        XCTAssertEqual(effective["model"]?.stringValue, "main-b")
        XCTAssertEqual(effective["worker_model"]?.stringValue, "main-a")
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_receiptlessHostSendToANewConversation_resolvesTheDistillDefault() async throws {
        // WHY: an unlinked, never-opened conversation has no saved route; the
        // send must resolve like a new Agent App thread (last-used Distill
        // model), never an empty model or a legacy provider.
        let f = try makeFixture(lastUsed: "main-b")
        let bot = try f.vm.create(name: "Piper", title: "Scout")

        let sent = try f.vm.enqueueHostMessage(botID: bot.id, text: "go", conversationID: nil)

        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.provider, .distill)
        XCTAssertEqual(request.model, "main-b")
        XCTAssertEqual(sent.objectValue?["effective_routing"]?.objectValue?["model"]?.stringValue, "main-b")
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_pairedRoutingSetForAConversation_isWhatTheMacShowsAndWhatTheReceiptSendRuns() async throws {
        // WHY: iOS and the Mac desk kept two route stores; a conversation-scoped
        // bot.routing.set must update the Mac desk route (and tell paired
        // devices), and the receipt-bound send must run its Worker.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let conversation = try XCTUnwrap(f.vm.selectedConversation)
        let botID = bot.id.value.uuidString.lowercased()
        let conversationID = conversation.id.value.uuidString.lowercased()
        let before = EventBus.shared.snapshot().lastSeq
        var params: [String: JSONValue] = [
            "client_request_id": .string("route"), "bot_id": .string(botID),
            "host_id": .string("paired-host"), "conversation_id": .string(conversationID),
            "provider": .string("distill"), "provider_instance_id": .string("distill-acp"),
            "model": .string("main-b"), "routing_mode": .string("manual"),
            "permission_mode": .string("supervised"), "reasoning_effort": .string("medium"),
            "service_tier": .string("auto"), "worker_model": .string("main-a"),
            "worker_effort": .string("high"), "distill_main_effort": .string("low"),
        ]
        let routed = try await f.router.dispatchPairedBotRemote(method: "bot.routing.set", params: params)
        let readback = try XCTUnwrap(routed.objectValue?["readback"]?.objectValue)
        let receiptID = try XCTUnwrap(routed.objectValue?["receipt_id"]?.stringValue)

        XCTAssertEqual(f.vm.deskRouting.model, "main-b", "the open Mac desk shows the paired route")
        XCTAssertEqual(f.vm.deskRouting.reasoningModel, "main-a")
        XCTAssertEqual(f.vm.deskRouting.distillReasoningEffortSelection, .fixed(.high))
        XCTAssertEqual(f.vm.deskRouting.distillMainEffortSelection, .fixed(.low))
        let stored = await waitUntil {
            (try? f.context.botStore.deskRoutingJSON(conversationID: conversation.id))??.contains("main-a") == true
        }
        XCTAssertTrue(stored, "the route is persisted per conversation in the DB")
        let events = EventBus.shared.recentEvents(since: before, maxBytes: nil).events
        XCTAssertTrue(events.contains { event in
            event.kind == "bot.conversation.updated"
                && event.payload.objectValue?["method"]?.stringValue == "bot.conversation.desk_routing"
                && event.payload.objectValue?["conversation_id"]?.stringValue == conversationID
                && event.payload.objectValue?["desk_routing"]?.objectValue?["worker_model"]?.stringValue == "main-a"
        }, "paired devices learn the conversation's new route")
        let effective = try XCTUnwrap(readback["effective"]?.objectValue)
        XCTAssertEqual(effective["routing_receipt_id"]?.stringValue, receiptID,
                       "effective keeps the receipt keys iOS reads, with or without conversation_id")
        XCTAssertEqual(effective["host_id"]?.stringValue, "paired-host")
        XCTAssertEqual(effective["bot_id"]?.stringValue, botID)
        XCTAssertEqual(effective["worker_model"]?.stringValue, "main-a")

        let listed = try await f.router.dispatchPairedBotRemote(
            method: "bot.conversation.list", params: ["bot_id": .string(botID)]
        )
        let row = listed.objectValue?["conversations"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(row?["desk_routing"]?.objectValue?["model"]?.stringValue, "main-b")

        params["client_request_id"] = .string("send")
        params["routing_receipt_id"] = .string(receiptID)
        params["text"] = .string("go")
        params["run_as_user"] = readback["run_as_user"]
        let sent = try await f.router.dispatchPairedBotRemote(method: "bot.send", params: params)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.model, "main-b")
        XCTAssertEqual(request.reasoningModel, "main-a", "the paired send runs the Worker it chose")
        XCTAssertEqual(request.distillReasoningEffortSelection, .fixed(.high))
        // The receipt-bound readback is the route that ran, receipt keys kept.
        let sendReadback = try XCTUnwrap(sent.objectValue?["readback"]?.objectValue)
        let ran = try XCTUnwrap(sendReadback["effective_routing"]?.objectValue)
        XCTAssertEqual(ran["model"]?.stringValue, "main-b")
        XCTAssertEqual(ran["worker_model"]?.stringValue, "main-a")
        XCTAssertEqual(ran["routing_receipt_id"]?.stringValue, receiptID)
        XCTAssertEqual(ran["host_id"]?.stringValue, "paired-host")
        let runRouting = try XCTUnwrap(sendReadback["run"]?.objectValue?["routing"]?.objectValue)
        XCTAssertEqual(runRouting["worker_model"]?.stringValue, "main-a")
        XCTAssertEqual(runRouting["routing_receipt_id"]?.stringValue, receiptID)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_conversationRoutingSetForAnEmptyMain_issuesTheResolvedRouteAsTheReceipt() async throws {
        // WHY: iOS echoes the receipt route and requires the send readback to
        // equal it; an unlinked conversation's empty Main resolves on the Mac,
        // so the receipt itself must carry the resolved model or an honest
        // readback would never match.
        let f = try makeFixture(lastUsed: "main-b")
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let conversation = try XCTUnwrap(f.vm.selectedConversation)
        var params: [String: JSONValue] = [
            "client_request_id": .string("route"), "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "host_id": .string("paired-host"),
            "conversation_id": .string(conversation.id.value.uuidString.lowercased()),
            "provider": .string("distill"), "provider_instance_id": .string("distill-acp"),
            "model": .string(""), "routing_mode": .string("manual"),
            "permission_mode": .string("supervised"), "reasoning_effort": .string("medium"),
            "service_tier": .string("auto"),
        ]
        let routed = try await f.router.dispatchPairedBotRemote(method: "bot.routing.set", params: params)
        let readback = try XCTUnwrap(routed.objectValue?["readback"]?.objectValue)
        let receiptID = try XCTUnwrap(routed.objectValue?["receipt_id"]?.stringValue)
        XCTAssertEqual(readback["model"]?.stringValue, "main-b", "the receipt is the resolved route")
        XCTAssertEqual(readback["effective"]?.objectValue?["model"]?.stringValue, "main-b")

        for key in ["model", "worker_model", "worker_effort", "distill_main_effort", "run_as_user"] {
            params[key] = readback[key]
        }
        params["client_request_id"] = .string("send")
        params["routing_receipt_id"] = .string(receiptID)
        params["text"] = .string("go")
        let sent = try await f.router.dispatchPairedBotRemote(method: "bot.send", params: params)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.model, "main-b")
        let ran = sent.objectValue?["readback"]?.objectValue?["effective_routing"]?.objectValue
        XCTAssertEqual(ran?["model"]?.stringValue, readback["model"]?.stringValue,
                       "what ran equals the receipt the device holds")
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_hostCatalogSendToTheOpenConversation_runsTheCallerRouteWithoutTouchingTheDeskRoute() async throws {
        // WHY: an Agent App -> Bot delegation runs the caller's exact frozen
        // provider/model for that one run; it must never rewrite the route
        // the user picked for that conversation on the Mac (pill, DB, event).
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let conversation = try XCTUnwrap(f.vm.selectedConversation)
        f.vm.setDeskModel("main-a")
        f.vm.setDeskReasoningModel("main-b")
        let saved = f.vm.deskRouting
        let persisted = await waitUntil {
            (try? f.context.botStore.deskRoutingJSON(conversationID: conversation.id))??.contains("main-b") == true
        }
        XCTAssertTrue(persisted)
        let storedBefore = try f.context.botStore.deskRoutingJSON(conversationID: conversation.id)
        let callerThread = AgentThread(
            title: "Caller", provider: .distill, model: "main-b", status: .running, permissionMode: .supervised
        )
        let callerRun = AgentRun(threadId: callerThread.id, provider: .distill, model: "main-b", status: .running)
        try f.context.threadRepo.upsert(callerThread)
        try f.context.runRepo.upsert(callerRun)
        let before = EventBus.shared.snapshot().lastSeq

        _ = try await f.router.sendHostBot(
            botID: bot.id,
            text: "go",
            conversationID: conversation.id,
            callerThread: callerThread.id,
            callerRun: callerRun.id
        )
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.model, "main-b", "the caller's model")
        XCTAssertNil(request.reasoningModel, "not the desk's Worker")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(f.vm.deskRouting, saved, "the open desk pill keeps the user's route")
        XCTAssertEqual(try f.context.botStore.deskRoutingJSON(conversationID: conversation.id), storedBefore)
        let routeEvents = EventBus.shared.recentEvents(since: before, maxBytes: nil).events.filter {
            $0.payload.objectValue?["reason"]?.stringValue == "desk_routing"
        }
        XCTAssertTrue(routeEvents.isEmpty, "no route change is announced")
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_legacyProviderReceiptSend_neverOverwritesTheSavedMainAndWorker() async throws {
        // WHY: an older iOS client still sends grok/claude receipts; that
        // route is reset to Distill defaults (no Worker) and must not replace
        // the Main/Worker the user chose on the Mac. The readback reports the
        // Distill route that really ran.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let conversation = try XCTUnwrap(f.vm.selectedConversation)
        f.vm.setDeskModel("main-a")
        f.vm.setDeskReasoningModel("main-b")
        let saved = f.vm.deskRouting
        let persisted = await waitUntil {
            (try? f.context.botStore.deskRoutingJSON(conversationID: conversation.id))??.contains("main-b") == true
        }
        XCTAssertTrue(persisted)
        let storedBefore = try f.context.botStore.deskRoutingJSON(conversationID: conversation.id)
        let botID = bot.id.value.uuidString.lowercased()
        var params: [String: JSONValue] = [
            "client_request_id": .string("route"), "bot_id": .string(botID),
            "host_id": .string("paired-host"),
            "provider": .string("grok"), "provider_instance_id": .string("grok"),
            "model": .string("grok-4.6"), "routing_mode": .string("auto"),
            "permission_mode": .string("supervised"), "reasoning_effort": .string("medium"),
            "service_tier": .string("auto"),
        ]
        var scoped = params
        scoped["conversation_id"] = .string(conversation.id.value.uuidString.lowercased())
        scoped["client_request_id"] = .string("route-scoped")
        var scopedRejected = false
        do {
            let scopedResult = try await f.router.dispatchPairedBotRemote(method: "bot.routing.set", params: scoped)
            scopedRejected = scopedResult.objectValue?["status"]?.stringValue == "failed"
        } catch {
            scopedRejected = true
        }
        XCTAssertTrue(scopedRejected, "a legacy provider is never a conversation's desk route")
        XCTAssertEqual(f.vm.deskRouting, saved)

        let routed = try await f.router.dispatchPairedBotRemote(method: "bot.routing.set", params: params)
        let readback = try XCTUnwrap(routed.objectValue?["readback"]?.objectValue)
        let receiptID = try XCTUnwrap(routed.objectValue?["receipt_id"]?.stringValue)
        params["client_request_id"] = .string("send")
        params["routing_receipt_id"] = .string(receiptID)
        params["conversation_id"] = .string(conversation.id.value.uuidString.lowercased())
        params["text"] = .string("go")
        params["run_as_user"] = readback["run_as_user"]
        let before = EventBus.shared.snapshot().lastSeq
        let sent = try await f.router.dispatchPairedBotRemote(method: "bot.send", params: params)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.provider, .distill)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(f.vm.deskRouting, saved, "the Mac keeps its Main and Worker")
        XCTAssertEqual(try f.context.botStore.deskRoutingJSON(conversationID: conversation.id), storedBefore)
        XCTAssertTrue(EventBus.shared.recentEvents(since: before, maxBytes: nil).events.filter {
            $0.payload.objectValue?["reason"]?.stringValue == "desk_routing"
        }.isEmpty)
        let ran = sent.objectValue?["readback"]?.objectValue?["effective_routing"]?.objectValue
        XCTAssertEqual(ran?["provider"]?.stringValue, "distill", "the readback is the route that ran")
        XCTAssertEqual(ran?["routing_receipt_id"]?.stringValue, receiptID)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_selectDeskThreadWritesTheResolvedRouteAfterTheTurn_latestWins() async throws {
        // WHY: navigation must not wait on SQLite (AGENTS loading rules); the
        // route an unlinked conversation resolves on open is still stored and
        // announced exactly once, and only the latest route is written.
        let f = try makeFixture(lastUsed: "main-b")
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let target = try XCTUnwrap(f.vm.selectedConversation)
        XCTAssertTrue(f.vm.createDeskThread())
        let other = try XCTUnwrap(f.vm.selectedConversation)
        let empty = BotDeskRouting(provider: .distill, providerInstanceID: "distill-acp", model: "")
        let emptyJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(empty), encoding: .utf8))
        // Both rows exist and the first view model has no write left that
        // could land after the route below is emptied.
        let drained = await waitUntil {
            (try? f.context.botStore.listDeskRoutingJSON().count) == 2 && !f.vm.deskRoutingWritesPendingForTesting
        }
        XCTAssertTrue(drained)
        XCTAssertTrue(try f.context.botStore.setDeskRoutingJSON(emptyJSON, conversationID: target.id))

        let restarted = BotsViewModel(context: f.context, router: f.router)
        restarted.lastModelStore = f.vm.lastModelStore
        restarted.replaceProvidersForTests(f.vm.providers)
        restarted.openDesk(bot)
        restarted.selectDeskThread(other.id)
        let before = EventBus.shared.snapshot().lastSeq

        restarted.selectDeskThread(target.id)

        XCTAssertEqual(restarted.deskRouting.model, "main-b", "the chip resolves on the interaction turn")
        XCTAssertEqual(try f.context.botStore.deskRoutingJSON(conversationID: target.id), emptyJSON,
                       "no synchronous DB write on navigation")
        XCTAssertTrue(EventBus.shared.recentEvents(since: before, maxBytes: nil).events.filter {
            $0.payload.objectValue?["reason"]?.stringValue == "desk_routing"
        }.isEmpty, "no synchronous event on navigation")

        restarted.setDeskModel("main-a")
        restarted.setDeskModel("main-b")
        restarted.setDeskModel("main-a")
        let written = await waitUntil {
            (try? f.context.botStore.deskRoutingJSON(conversationID: target.id))??.contains("main-a") == true
        }
        XCTAssertTrue(written, "the latest route is stored after the turn")
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = EventBus.shared.recentEvents(since: before, maxBytes: nil).events.filter {
            $0.payload.objectValue?["reason"]?.stringValue == "desk_routing"
                && $0.payload.objectValue?["conversation_id"]?.stringValue == target.id.value.uuidString.lowercased()
        }
        XCTAssertEqual(events.count, 1, "one coalesced event per conversation")
        XCTAssertEqual(
            events.first?.payload.objectValue?["desk_routing"]?.objectValue?["model"]?.stringValue, "main-a",
            "latest wins"
        )
    }

    func test_deskRouteSurvivesRestartFromTheDB_andTheDefaultsStoreMovesOnce() async throws {
        // WHY: user choices must survive closing RemoteCode; the route now
        // lives in the DB and the old UserDefaults map is moved, then dropped.
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        let kept = try XCTUnwrap(f.vm.selectedConversation)
        f.vm.setDeskModel("main-b")
        XCTAssertTrue(f.vm.createDeskThread())
        let legacy = try XCTUnwrap(f.vm.selectedConversation)
        let flushed = await waitUntil {
            (try? f.context.botStore.deskRoutingJSON(conversationID: kept.id))??.contains("main-b") == true
        }
        XCTAssertTrue(flushed)
        let legacyRoute: [String: Any] = [
            "provider": "distill", "providerInstanceID": "distill-acp", "model": "main-a",
            "routingMode": "manual", "permissionMode": "supervised", "reasoningModel": "main-b",
        ]
        UserDefaults.standard.set(
            try JSONSerialization.data(withJSONObject: [
                legacy.id.value.uuidString.lowercased(): legacyRoute,
                UUID().uuidString.lowercased(): legacyRoute,
            ]),
            forKey: "bots.deskThreadRouting"
        )

        let restarted = BotsViewModel(context: f.context, router: f.router)
        restarted.replaceProvidersForTests(f.vm.providers)
        restarted.openDesk(bot)
        restarted.selectDeskThread(kept.id)
        XCTAssertEqual(restarted.deskRouting.model, "main-b")
        restarted.selectDeskThread(legacy.id)
        XCTAssertEqual(restarted.deskRouting.reasoningModel, "main-b", "the old store is migrated")
        XCTAssertNil(UserDefaults.standard.data(forKey: "bots.deskThreadRouting"),
                     "the move happens once")
        XCTAssertEqual(try f.context.botStore.listDeskRoutingJSON().count, 2,
                       "only live conversations get a row")
    }
}
