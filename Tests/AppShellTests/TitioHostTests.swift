import XCTest
import Carbon.HIToolbox
import SwiftUI
import Surfaces
@testable import AgentRuntime
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// Titio is the pet turned into a chat Bot. These drive the real host
/// handlers its catalog tools reach, against a seeded store.
@MainActor
final class TitioHostTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        AgentProvider.selectableForTesting = nil
        directory = NSTemporaryDirectory() + "rc-titio-\(UUID().uuidString)"
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
        let callerThread: AgentThread
        let callerRun: AgentRun
    }

    private func makeFixture() throws -> Fixture {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp"
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        vm.replaceProvidersForTests([snapshot])
        let callerThread = AgentThread(
            title: "Titio chat", provider: .distill, model: "main-a", status: .running, permissionMode: .fullAccess
        )
        let callerRun = AgentRun(threadId: callerThread.id, provider: .distill, model: "main-a", status: .running)
        try context.threadRepo.upsert(callerThread)
        try context.runRepo.upsert(callerRun)
        return Fixture(context: context, router: router, runner: runner, vm: vm, callerThread: callerThread, callerRun: callerRun)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private func seedScheduledTask(_ f: Fixture, workspace: Workspace, title: String, nextRunAt: Date) throws -> ScheduledTask {
        let task = ScheduledTask(
            title: title,
            prompt: "Run the nightly report",
            workspaceID: workspace.id,
            workspacePathSnapshot: workspace.cwd,
            runAsUser: NSUserName(),
            runAsUID: getuid(),
            provider: .distill,
            providerInstanceID: "distill-acp",
            model: "main-a",
            reasoningEffort: .medium,
            recurrence: .daily(at: ScheduledLocalTime(hour: 3, minute: 0)!),
            timeZoneIdentifier: TimeZone.current.identifier,
            isEnabled: true,
            nextRunAt: nextRunAt
        )
        try ScheduledTaskStore(db: f.context.db).save(task)
        return task
    }

    func test_delegateResolvesBotByNameAndPreservesItsAuthorizedWorkspaceConversation() async throws {
        // WHY: "peça para o bot developer ..." must reach that Bot's desk,
        // not a guess or a silent no-op.
        let f = try makeFixture()
        let developer = try f.vm.create(name: "Developer", title: "Builds things")
        _ = try f.context.botStore.setExecutionDestination(.mac, botID: developer.id)
        _ = try f.vm.create(name: "Writer", title: "Docs")
        let workspace = try f.router.createWorkspace(name: "elephant", cwd: directory)
        let host = f.context.liveActivityHostIdentity.serverId
        let grant = try f.context.botStore.grantContext(
            hostID: host, botID: developer.id, context: .workspace(workspace.id),
            actions: [.read, .send], expectedRevision: 0
        )
        let thread = AgentThread(workspaceId: workspace.id, title: "Repository cleanup", provider: .distill, model: "main-a")
        let conversation = BotConversation(botID: developer.id, title: thread.title, linkedAgentThreadID: thread.id)
        try f.context.botStore.createContextualConversation(
            conversation, newThread: thread, hostID: host,
            context: grant.context, policyRevision: grant.policyRevision, executionDestination: .mac
        )

        let result = try await f.router.delegateHostBot(
            bot: "developer",
            text: "limpe o repositorio do elephant",
            conversationID: conversation.id,
            callerThread: f.callerThread.id,
            callerRun: f.callerRun.id
        )

        XCTAssertEqual(result.objectValue?["bot_id"]?.stringValue, developer.id.value.uuidString.lowercased())
        let conversations = try f.context.botStore.listConversations(botID: developer.id)
        XCTAssertEqual(conversations.count, 1)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.threadId, thread.id)
        XCTAssertEqual(try f.context.threadRepo.get(id: request.threadId)?.workspaceId, workspace.id)
        XCTAssertTrue(request.prompt.contains("repositorio do elephant"), request.prompt)
        _ = try f.context.botStore.revokeContext(
            hostID: host, botID: developer.id, context: grant.context, expectedRevision: grant.policyRevision
        )
        do {
            _ = try await f.router.delegateHostBot(
                bot: "developer", text: "continue", conversationID: conversation.id,
                callerThread: f.callerThread.id, callerRun: f.callerRun.id
            )
            XCTFail("a revoked workspace grant must not enqueue another run")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no longer authorized"), "\(error)")
        }
        XCTAssertTrue(try f.context.botStore.listQueuedFollowUps(botID: developer.id).isEmpty)
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_unknownBotOrWorkspaceIsAnExplicitError() async throws {
        let f = try makeFixture()
        do {
            _ = try await f.router.delegateHostBot(
                bot: "nobody", text: "hi", conversationID: nil,
                callerThread: f.callerThread.id, callerRun: f.callerRun.id
            )
            XCTFail("unknown Bot must fail")
        } catch {
            XCTAssertEqual((error as? JSONRPCError)?.code, -32044)
        }
        XCTAssertThrowsError(try f.router.runNextHostScheduledTask(workspace: "nowhere", taskID: nil)) {
            XCTAssertEqual(($0 as? JSONRPCError)?.code, -32044)
        }
        XCTAssertTrue(f.runner.requests.isEmpty)
    }

    func test_continueRestoresSavedContextWithoutAddingAUserMessage() async throws {
        let f = try makeFixture()
        let workspace = try f.router.createWorkspace(name: "Resume", cwd: directory)
        let thread = AgentThread(
            workspaceId: workspace.id, title: "Interrupted task", provider: .distill,
            model: "main-a", status: .interrupted, permissionMode: .fullAccess
        )
        try f.context.threadRepo.upsert(thread)
        try f.context.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "Finish the report"))
        try f.context.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id, provider: .distill, status: .interrupted,
            resumeCursor: "saved-report-session", cwd: directory, model: "main-a"
        ))
        let before = try f.context.messageRepo.list(threadId: thread.id).filter { $0.role == .user }

        let resumed = try await f.router.continueAgentRun(thread: thread.id)

        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.runId, resumed)
        XCTAssertEqual(request.providerThreadId, "saved-report-session")
        XCTAssertFalse(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Continue sends the provider a recovery instruction, not an empty prompt")
        XCTAssertEqual(try f.context.messageRepo.list(threadId: thread.id).filter { $0.role == .user }.map(\.id), before.map(\.id),
                       "recovery must not add a blank or invented user message")
        f.runner.finish(runID: request.runId, status: .completed, reply: "Report finished")
    }

    func test_continueWithoutSavedContextDoesNotStartOrQueueNewWork() async throws {
        let f = try makeFixture()
        let thread = AgentThread(title: "Finished", provider: .distill, model: "main-a", status: .completed)
        try f.context.threadRepo.upsert(thread)
        do {
            _ = try await f.router.continueAgentRun(thread: thread.id)
            XCTFail("Continue must not restart completed work")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("No saved interrupted context"))
        }
        XCTAssertTrue(f.runner.requests.isEmpty)
        XCTAssertTrue(try f.context.messageRepo.list(threadId: thread.id).isEmpty)
        XCTAssertTrue(try f.context.queuedMessageRepo.list(threadId: thread.id).isEmpty)
    }

    func test_focusedActivityPaginatesOnlyTheRequestedInterruptedWorkspace() async throws {
        let f = try makeFixture()
        let workspace = try f.router.createWorkspace(name: "Resume", cwd: directory)
        var expected = Set<String>()
        for index in 0..<4 {
            let thread = AgentThread(workspaceId: index == 3 ? nil : workspace.id,
                                     title: "Task \(index)", provider: .distill, model: "main-a")
            try f.context.threadRepo.upsert(thread)
            let status: AgentRunStatus = index == 2 ? .completed : .interrupted
            try f.context.runRepo.upsert(AgentRun(threadId: thread.id, provider: .distill, model: "main-a",
                                                status: status, startedAt: Date(timeIntervalSince1970: Double(100 + index)),
                                                finishedAt: Date(timeIntervalSince1970: Double(110 + index))))
            if index < 2 { expected.insert(thread.id.description.lowercased()) }
        }
        var filters: [String: JSONValue] = ["section": .string("needs_you"), "outcome": .string("interrupted"),
                                          "workspace_id": .string(workspace.id.description), "limit": .number(1)]
        let first = try await f.router.listHostActivity(params: filters)
        XCTAssertEqual(Set(first.objectValue?.keys.map { $0 } ?? []), ["activity"],
                       "a focused command must not load every Bot, thread and schedule")
        let page = try XCTUnwrap(first.objectValue?["activity"]?.objectValue)
        XCTAssertEqual(page["counts"]?.objectValue?["needs_you"], .number(2))
        let cursor = try XCTUnwrap(page["next_cursor"]?.stringValue)
        filters["cursor"] = .string(cursor)
        let second = try await f.router.listHostActivity(params: filters)
        let next = try XCTUnwrap(second.objectValue?["activity"]?.objectValue)
        XCTAssertNil(next["next_cursor"]?.stringValue)
        let items = (page["items"]?.arrayValue ?? []) + (next["items"]?.arrayValue ?? [])
        XCTAssertEqual(Set(items.compactMap { $0.objectValue?["thread_id"]?.stringValue?.lowercased() }), expected)
    }

    func test_ambiguousBotAndWorkspaceNamesNeverStartTheFirstMatch() async throws {
        let f = try makeFixture()
        let first = try f.vm.create(name: "Worker", handle: "worker-one")
        let second = try f.vm.create(name: "Worker", handle: "worker-two")
        _ = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        _ = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        do {
            _ = try await f.router.delegateHostBot(
                bot: "Worker", text: "Clean the repository", conversationID: nil,
                callerThread: f.callerThread.id, callerRun: f.callerRun.id
            )
            XCTFail("an ambiguous name must ask for a target")
        } catch {
            XCTAssertEqual((error as? JSONRPCError)?.code, -32602)
        }
        XCTAssertThrowsError(try f.router.runNextHostScheduledTask(workspace: "elephant", taskID: nil)) {
            XCTAssertEqual(($0 as? JSONRPCError)?.code, -32602)
        }
        XCTAssertTrue(f.runner.requests.isEmpty)
        let result = try await f.router.delegateHostBot(
            bot: second.id.value.uuidString, text: "Inspect the repository", conversationID: nil,
            callerThread: f.callerThread.id, callerRun: f.callerRun.id
        )
        XCTAssertEqual(result.objectValue?["bot_id"]?.stringValue, second.id.value.uuidString.lowercased())
        XCTAssertTrue(try f.context.botStore.listConversations(botID: first.id).isEmpty)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        if let request = f.runner.requests.first { f.runner.finish(runID: request.runId, status: .completed, reply: "ok") }
    }

    func test_runNextClaimsTheWorkspacesNextScheduledTaskThroughTheScheduler() throws {
        // WHY: "dispare agora a próxima schedule task do workspace elephant"
        // must use the real manual run-now claim on the earliest task there.
        let f = try makeFixture()
        let elephant = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let other = try f.router.createWorkspace(name: "zebra", cwd: NSTemporaryDirectory())
        let later = try seedScheduledTask(f, workspace: elephant, title: "Weekly", nextRunAt: Date().addingTimeInterval(7 * 86_400))
        let next = try seedScheduledTask(f, workspace: elephant, title: "Nightly", nextRunAt: Date().addingTimeInterval(3_600))
        _ = try seedScheduledTask(f, workspace: other, title: "Zebra", nextRunAt: Date().addingTimeInterval(60))
        let scheduler = ScheduledTaskScheduler(context: f.context, router: f.router)
        f.router.scheduledTaskScheduler = scheduler

        let result = try f.router.runNextHostScheduledTask(workspace: "Elephant", taskID: nil)

        XCTAssertEqual(result.objectValue?["task_id"]?.stringValue, next.id.uuidString.lowercased())
        let store = ScheduledTaskStore(db: f.context.db)
        let runs = try store.listRuns(taskID: next.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.trigger, .manual)
        XCTAssertEqual(result.objectValue?["run_id"]?.stringValue, runs.first?.id.uuidString.lowercased())
        XCTAssertTrue(try store.listRuns(taskID: later.id).isEmpty)

        let named = try f.router.runNextHostScheduledTask(workspace: "elephant", taskID: later.id)
        XCTAssertEqual(named.objectValue?["task_id"]?.stringValue, later.id.uuidString.lowercased(),
                       "an explicitly chosen routine must not be replaced by the next one")
        XCTAssertEqual(try store.listRuns(taskID: later.id).count, 1)
    }

    func test_activityListReportsRunningThreadsBotsAndScheduledTasks() async throws {
        // WHY: "Titio, quais tarefas estão sendo feitas?" is answered from this.
        let f = try makeFixture()
        let elephant = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let task = try seedScheduledTask(f, workspace: elephant, title: "Nightly report", nextRunAt: Date().addingTimeInterval(3_600))
        let developer = try f.vm.create(name: "Developer", title: "Builds things")
        _ = try await f.router.delegateHostBot(
            bot: "Developer", text: "build the snake game", conversationID: nil,
            callerThread: f.callerThread.id, callerRun: f.callerRun.id
        )
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        let routine = BotRoutineDefinition(botID: developer.id, name: "Pick a Linear task", prompt: "Work in elephant")
        try f.context.botStore.saveRoutine(routine)
        let titio = try TitioBot.ensure(store: f.context.botStore, appSupportDirectory: f.context.appSupportDirectory)
        let notices = TitioNoticeRepository(db: f.context.db)
        let fact = TitioNoticeFact(
            key: "thread.developer.attention.Q1", kind: .userInput,
            source: TitioNoticeSource(threadId: request.threadId.value.uuidString, requestId: "Q1", botId: developer.id.value.uuidString),
            facts: TitioNoticeFacts(botName: "Developer", prompt: "Which environment?"),
            actions: [.providerOption(index: 0, text: "Staging"), .openThread]
        )
        _ = try notices.ingest(fact)
        let noticeID = UUID().uuidString
        _ = try notices.flush(keys: [fact.key], postedAt: Date()) { _ in
            TitioNoticePosting(messageID: noticeID, cardOptions: [
                TitioNoticeCardOption(label: "Staging", action: .providerOption(index: 0, text: "Staging")),
                TitioNoticeCardOption(label: "Open", action: .openThread),
            ], preview: "Which environment?")
        }

        let snapshot = try await f.router.listHostActivity(params: ["include_context": .bool(true)])

        let object = try XCTUnwrap(snapshot.objectValue)
        let threads = object["threads"]?.arrayValue ?? []
        let running = threads.first { $0.objectValue?["id"]?.stringValue == request.threadId.value.uuidString.lowercased() }
        XCTAssertEqual(running?.objectValue?["status"]?.stringValue, "running")
        let tasks = object["scheduled_tasks"]?.arrayValue ?? []
        let seeded = try XCTUnwrap(tasks.first { $0.objectValue?["id"]?.stringValue == task.id.uuidString.lowercased() })
        XCTAssertEqual(seeded.objectValue?["title"]?.stringValue, "Nightly report")
        XCTAssertEqual(seeded.objectValue?["workspace"]?.stringValue, "elephant")
        XCTAssertNotEqual(seeded.objectValue?["next_run_at"], .null)
        XCTAssertTrue((object["bots"]?.arrayValue ?? []).contains {
            $0.objectValue?["id"]?.stringValue == developer.id.value.uuidString.lowercased()
        })
        XCTAssertTrue((object["workspaces"]?.arrayValue ?? []).contains { $0.objectValue?["name"]?.stringValue == "elephant" })
        let activity = try XCTUnwrap(object["activity"]?.objectValue)
        XCTAssertNotNil(activity["counts"]?.objectValue)
        XCTAssertNotNil(activity["generated_at"]?.stringValue)
        XCTAssertTrue(activity["items"]?.arrayValue?.contains {
            $0.objectValue?["thread_id"]?.stringValue?.lowercased() == request.threadId.value.uuidString.lowercased()
        } == true, "the same Activity projection identifies the delegated work")
        XCTAssertEqual(object["bot_schedules"]?.arrayValue?.first?.objectValue?["id"]?.stringValue,
                       routine.id.value.uuidString.lowercased())
        XCTAssertEqual(object["titio_bot_id"]?.stringValue, titio.id.value.uuidString.lowercased())
        let decision = try XCTUnwrap(object["open_decisions"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(decision["message_id"]?.stringValue, noticeID)
        XCTAssertEqual(decision["request_id"]?.stringValue, "Q1")
        XCTAssertEqual(decision["options"]?.arrayValue?.first?.objectValue?["option_index"]?.intValue, 0)
        XCTAssertEqual(decision["options"]?.arrayValue?.first?.objectValue?["action"]?.stringValue, "provider_option")
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_catalogMutationWithoutOperationIDIsRejectedBeforeTheHost() throws {
        let mcp = ManagedBotSelfConfigMCP(environment: [:])
        for tool in [RemoteCodeHostCatalog.botDelegate, RemoteCodeHostCatalog.scheduledTaskRunNext] {
            let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":{"bot":"developer","workspace":"elephant","text":"go"}}}"#
            let reply = try XCTUnwrap(mcp.handle(line))
            XCTAssertTrue(reply.contains("\"isError\":true"), reply)
            XCTAssertTrue(reply.contains("operation_id is required"), reply)
        }
        XCTAssertTrue(RemoteCodeHostCatalog.rpcMutationMethods.contains(RemoteCodeHostCatalog.botDelegateRPC))
        XCTAssertTrue(RemoteCodeHostCatalog.rpcMutationMethods.contains(RemoteCodeHostCatalog.scheduledTaskRunNextRPC))
        XCTAssertFalse(RemoteCodeHostCatalog.rpcMutationMethods.contains(RemoteCodeHostCatalog.activityListRPC))
    }

    func test_titioIsOnePersistedBotWhoseConversationSurvivesReopen() async throws {
        // WHY: the user's Titio chat must survive closing and reopening RemoteCode.
        let f = try makeFixture()
        let first = try f.router.openTitio()
        XCTAssertEqual(try f.router.openTitio(), first, "opening the pet again reuses Titio")
        let titio = try XCTUnwrap(try f.context.botStore.get(id: first))
        XCTAssertEqual(titio.handle, TitioBot.handle)
        XCTAssertEqual(titio.name, "Titio")

        _ = try f.vm.enqueueHostMessage(botID: first, text: "Titio, quais tarefas estão sendo feitas?", conversationID: nil)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        // Titio runs fullAccess so host catalog mutations are admitted, and
        // as a Bot so the managed MCP (with the Titio tools) is attached.
        XCTAssertEqual(request.permissionMode, .fullAccess)
        XCTAssertEqual(request.environment[BotSelfConfigCatalog.callerEnvironmentKey], first.value.uuidString.lowercased())
        f.runner.finish(runID: request.runId, status: .completed, reply: "Nightly report is running.")
        let conversation = try XCTUnwrap(try f.context.botStore.listConversations(botID: first).first)

        let reopened = try AppContext(channel: .debug, appSupportOverride: directory)
        let again = try TitioBot.ensure(store: reopened.botStore, appSupportDirectory: reopened.appSupportDirectory)
        XCTAssertEqual(again.id, first)
        XCTAssertEqual(try reopened.botStore.list(includeHidden: true).filter { $0.handle == TitioBot.handle }.count, 1)
        let reopenedConversations = try reopened.botStore.listConversations(botID: first)
        XCTAssertEqual(reopenedConversations.map(\.id), [conversation.id])
        let threadID = try XCTUnwrap(reopenedConversations.first?.linkedAgentThreadID)
        let messages = try reopened.messageRepo.list(threadId: threadID)
        XCTAssertTrue(messages.contains { $0.content.contains("quais tarefas") })
    }

    func test_titioRunToolsIncludeTitioCatalogAndKeepProviderTools() {
        // WHY: Titio needs the RemoteCode tools and must keep the normal
        // provider tools (shell, files, web) for requests outside RemoteCode.
        let advertised = Set(RemoteCodeHostCatalog.toolNames)
        for tool in [RemoteCodeHostCatalog.activityList, RemoteCodeHostCatalog.botDelegate, RemoteCodeHostCatalog.scheduledTaskRunNext,
                     RemoteCodeHostCatalog.botSend, RemoteCodeHostCatalog.workspaceCreate] {
            XCTAssertTrue(advertised.contains(tool), tool)
        }
        let env = [BotSelfConfigCatalog.callerEnvironmentKey: UUID().uuidString]
        let allowed = ClaudeRunner.automaticallyAllowedTools(environment: env)
        XCTAssertTrue(allowed.contains("mcp__\(BotSelfConfigMCPAdmit.serverName)__\(RemoteCodeHostCatalog.activityList)"))
        XCTAssertTrue(allowed.contains("mcp__\(BotSelfConfigMCPAdmit.serverName)__\(RemoteCodeHostCatalog.botDelegate)"))
        // An allowlist only auto-approves; Titio adds no tool restriction.
        XCTAssertFalse(allowed.contains { $0.hasPrefix("--disallowedTools") || $0 == "--tools" })
        XCTAssertTrue(TitioIdentity.orchestrationDirective.contains(RemoteCodeHostCatalog.activityList))
        XCTAssertTrue(TitioIdentity.orchestrationDirective.contains("available provider tools"))
    }

    func test_titioIsPinnedAndAlwaysFirstInTheRosterWithThePetAvatar() throws {
        // WHY: Titio holds the top roster slot like the CEO, with the pet's face.
        let f = try makeFixture()
        let ceo = try f.vm.create(name: "Ceo", title: "Chief of all bots")
        f.vm.setPinned(id: ceo.id, pinned: true)
        _ = try f.vm.create(name: "Developer", title: "Builds things")
        let titio = try TitioBot.ensure(store: f.context.botStore, appSupportDirectory: f.context.appSupportDirectory)
        try f.context.botStore.setPinned(id: titio.id, pinned: false)
        try f.context.botStore.setHidden(id: titio.id, hidden: true)

        let again = try TitioBot.ensure(store: f.context.botStore, appSupportDirectory: f.context.appSupportDirectory)
        XCTAssertTrue(again.pinned, "ensure re-pins Titio")
        XCTAssertFalse(again.hidden, "ensure un-hides Titio")
        f.vm.reload()
        XCTAssertEqual(f.vm.fleet.first?.handle, TitioBot.handle)

        XCTAssertNotNil(TitioBot.avatarImage, "pet avatar ships in the AppShell bundle")
        TitioBot.installAvatar()
        XCTAssertNotNil(BotsAvatarView.viewOverride(TitioBot.handle, 48))
        XCTAssertNil(BotsAvatarView.viewOverride("ceo", 48), "other Bots keep their own blobatar")
    }

    func test_titioAvatarIsThePetWithNoPlateBehindIt() throws {
        // WHY: the owner asked (2026-10-14) to drop the light plate behind
        // Titio's roster avatar; the pet is drawn straight on the row. The
        // override branch must only size the view, never paint a background.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/BotsAvatarView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "if let custom = Self.viewOverride(handle, size) {"))
        let branch = String(source[start.upperBound...].prefix(120))
        XCTAssertTrue(branch.contains("custom.frame(width: size, height: size)"))
        XCTAssertFalse(branch.contains(".background"), "no plate behind Titio")
        XCTAssertFalse(source.contains("Color(white: 0.92)"), "the old light plate is gone")
    }

    func test_titioRosterAvatarHasTheSameOpticalSizeAsBlobatars() throws {
        // WHY: the owner saw (2026-10-15) Titio's roster row look cramped next
        // to the other Bots: the cat filled the whole 48 pt avatar frame while
        // a blobatar's body spans at most ~76% of it, leaving the same vertical
        // breathing room above and below. The Bot-avatar override must keep the
        // pet inside that share; the popover keeps the full-size pet.
        TitioBot.installAvatar()
        let size: CGFloat = 48
        let rosterHeight = try opaqueHeight(of: XCTUnwrap(BotsAvatarView.viewOverride(TitioBot.handle, size)), size: size)
        let fullHeight = try opaqueHeight(of: AnyView(TitioAvatarView(size: size)), size: size)
        XCTAssertLessThanOrEqual(rosterHeight, size * TitioAvatarView.botAvatarFill + 1, "roster pet stays inside a blobatar's share")
        XCTAssertGreaterThan(rosterHeight, size * 0.6, "but is not shrunk below a blobatar's body")
        XCTAssertGreaterThan(fullHeight, rosterHeight, "the popover pet still fills its frame")
    }

    private func opaqueHeight(of view: AnyView, size: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rows = (0..<height).filter { y in (0..<width).contains { x in pixels[(y * width + x) * 4 + 3] > 16 } }
        guard let top = rows.first, let bottom = rows.last else { return 0 }
        return CGFloat(bottom - top + 1)
    }

    func test_titioAvatarAnimatesOnlyWhileMountedAndStopsWithPetMotion() {
        // WHY: the avatar moves like the pet (same idle blink / tail / ears)
        // but must cost nothing off screen, and must stop when the pet's
        // animations or reduce motion are off.
        let animator = TitioAvatarAnimator.shared
        animator.setMotionAllowed(true)
        XCTAssertEqual(animator.mountedCountForTests, 0)

        animator.mount()
        animator.mount()
        XCTAssertNotNil(animator.image, "the pet frame shows as soon as an avatar mounts")
        XCTAssertTrue(animator.isAnimatingForTests, "a mounted avatar plays the pet's idle loop")

        animator.setMotionAllowed(false)
        XCTAssertFalse(animator.isAnimatingForTests, "pet animations off or reduce motion holds a still frame")
        XCTAssertNotNil(animator.image, "a still frame, not a blank avatar")
        animator.setMotionAllowed(true)
        XCTAssertTrue(animator.isAnimatingForTests)

        animator.unmount()
        XCTAssertTrue(animator.isAnimatingForTests, "another avatar is still on screen")
        animator.unmount()
        XCTAssertFalse(animator.isAnimatingForTests, "no avatar on screen, no timer")
        animator.unmount()
        XCTAssertEqual(animator.mountedCountForTests, 0, "extra disappear never goes negative")
    }

    func test_restoreFactorySettingsPutsTitioBackAndKeepsItsConversations() async throws {
        // WHY: a user who broke Titio's profile or instructions needs one way
        // back to the built-in Titio, without losing the chats they had.
        let f = try makeFixture()
        let titioID = try f.router.openTitio()
        _ = try f.vm.enqueueHostMessage(botID: titioID, text: "oi", conversationID: nil)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "oi!")
        let conversations = try f.context.botStore.listConversations(botID: titioID).map(\.id)
        XCTAssertFalse(conversations.isEmpty)

        // The user rewrites Titio and saves.
        f.vm.reload()
        f.vm.openStudio(try XCTUnwrap(try f.context.botStore.get(id: titioID)))
        XCTAssertTrue(f.vm.studioEditsTitio)
        f.vm.studioDraft.name = "Gato"
        f.vm.studioDraft.title = "Whatever"
        f.vm.studioDraft.description = ""
        f.vm.studioDraft.soul = "Only answer in riddles."
        _ = try f.vm.saveStudio()
        XCTAssertEqual(try f.context.botStore.get(id: titioID)?.name, "Gato")

        let restored = try f.vm.restoreTitioFactorySettings()
        XCTAssertEqual(restored.id, titioID, "same Titio, not a new Bot")
        let bot = try XCTUnwrap(try f.context.botStore.get(id: titioID))
        XCTAssertEqual(bot.name, TitioBot.name)
        XCTAssertEqual(bot.title, TitioBot.title)
        XCTAssertEqual(bot.description, TitioBot.description)
        XCTAssertEqual(bot.handle, TitioBot.handle)
        let revision = try XCTUnwrap(try f.context.botStore.getRevision(id: try XCTUnwrap(bot.currentRevisionID)))
        XCTAssertEqual(revision.soul, TitioBot.soul, "the built-in instructions are back")
        XCTAssertEqual(try f.context.botStore.listConversations(botID: titioID).map(\.id), conversations,
                       "factory reset keeps every conversation")
        XCTAssertEqual(f.vm.studioDraft.soul, TitioBot.soul, "the open Studio shows the restored profile")
    }

    func test_renamingTitioInItsStudioKeepsItsSlug() throws {
        // WHY: the slug field is locked, but the name still derived a new slug
        // ("Tio Bot" → "tio-bot") and saving renamed the handle. Everything
        // finds Titio by its slug, so the next launch made a second Titio and
        // split the pet, the inbox and the notice hub.
        let f = try makeFixture()
        let titioID = try f.router.openTitio()
        f.vm.reload()
        f.vm.openStudio(try XCTUnwrap(try f.context.botStore.get(id: titioID)))
        f.vm.didEditStudioName("Tio Bot")
        XCTAssertEqual(f.vm.studioDraft.handle, TitioBot.handle, "the name never drives Titio's slug")
        _ = try f.vm.saveStudio()
        let bot = try XCTUnwrap(try f.context.botStore.get(id: titioID))
        XCTAssertEqual(bot.name, "Tio Bot")
        XCTAssertEqual(bot.handle, TitioBot.handle)
        XCTAssertThrowsError(try f.context.botStore.renameHandle(id: titioID, handle: "other"),
                             "no path (Studio or bot.handle.set) can move Titio off its slug")
        XCTAssertEqual(try TitioBot.ensure(store: f.context.botStore, appSupportDirectory: f.context.appSupportDirectory).id,
                       titioID, "still one Titio")
    }

    func test_onlyTitiosStudioHidesTheAvatarAndOffersFactoryReset() throws {
        // WHY: Titio's avatar is the pet, so its Studio has no avatar editor;
        // every other Bot keeps its blobatar editor and gets no Titio reset.
        let f = try makeFixture()
        let developer = try f.vm.create(name: "Developer", title: "Builds things")
        let titioID = try f.router.openTitio()
        f.vm.reload()
        f.vm.openStudio(developer)
        XCTAssertFalse(f.vm.studioEditsTitio)
        XCTAssertThrowsError(try f.vm.restoreTitioFactorySettings(), "never overwrite another Bot with Titio")
        XCTAssertEqual(try f.context.botStore.get(id: developer.id)?.name, "Developer")

        f.vm.openStudio(try XCTUnwrap(try f.context.botStore.get(id: titioID)))
        XCTAssertTrue(f.vm.studioEditsTitio)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let window = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(window.range(of: "private var studioProfile: some View {"))
        let profile = String(window[start.upperBound...].prefix(2_400))
        // Wide Studio has two columns; a narrow pane stacks them. Both mount the pane only for other Bots.
        XCTAssertTrue(profile.contains("if !vm.studioEditsTitio {\n                studioAvatarPane"),
                      "the wide layout mounts the avatar pane only for other Bots")
        XCTAssertTrue(profile.contains("if !vm.studioEditsTitio { studioAvatarPane }"),
                      "the stacked layout mounts the avatar pane only for other Bots")
        XCTAssertTrue(profile.contains("studioTitioFactoryReset"))
        XCTAssertTrue(window.contains(".disabled(vm.studioEditsTitio)"), "Titio's slug is how the app finds it")
    }

    func test_petPopoverSendStartsATitioConversationAndClosesThePopover() async throws {
        // WHY: the pet popover is a shortcut to talk to Titio: Return in its
        // field starts the conversation like Option+Space and gets out of the way.
        let f = try makeFixture()
        let pet = try PetController(context: f.context, router: f.router, openSettings: { _ in true })
        defer { pet.stop() }
        pet.start()
        pet.windowControllerForTests.openPopoverForTests()

        pet.sendToTitio("   ")
        XCTAssertTrue(f.runner.requests.isEmpty, "blank text sends nothing")

        pet.sendToTitio("  Titio, o que está rodando? ")
        XCTAssertFalse(pet.windowControllerForTests.isPopoverVisible)
        let titio = try XCTUnwrap(try f.context.botStore.list().first { $0.handle == TitioBot.handle })
        XCTAssertEqual(try f.context.botStore.listConversations(botID: titio.id).count, 1)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertTrue(request.prompt.contains("o que está rodando?"))
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_petPopoverGrowsOutOfTheCornerNextToThePet() {
        // WHY: the card scales in from the pet, not from its own center.
        XCTAssertEqual(PetWindowController.growthAnchor(for: .init(vertical: .above, horizontal: .leading)), .bottomLeading)
        XCTAssertEqual(PetWindowController.growthAnchor(for: .init(vertical: .above, horizontal: .trailing)), .bottomTrailing)
        XCTAssertEqual(PetWindowController.growthAnchor(for: .init(vertical: .below, horizontal: .leading)), .topLeading)
        XCTAssertEqual(PetWindowController.growthAnchor(for: .init(vertical: .below, horizontal: .trailing)), .topTrailing)
    }

    func test_quickChatSendsToANewTitioConversation() async throws {
        let f = try makeFixture()
        let conversation = try XCTUnwrap(f.router.sendTitioQuickMessage("Titio, quais tarefas estão sendo feitas?"))
        let titio = try XCTUnwrap(try f.context.botStore.list().first { $0.handle == TitioBot.handle })
        XCTAssertEqual(try f.context.botStore.conversation(id: conversation)?.botID, titio.id)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertTrue(request.prompt.contains("quais tarefas"))
        XCTAssertTrue(request.prompt.contains(TitioIdentity.orchestrationDirective),
                      "chat uses the current control-center contract")
        f.runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_quickChatRegistersOptionSpaceAndSubmitsTrimmedText() {
        let controller = TitioQuickChatController()
        var sent: [String] = []
        controller.install { sent.append($0) }
        XCTAssertEqual(TitioQuickChatController.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(TitioQuickChatController.modifiers, UInt32(optionKey))
        XCTAssertEqual(controller.registrationStatus, noErr)
        XCTAssertTrue(TitioQuickChatController.isHotKeyRegistered, "the popover hint only shows a live shortcut")
        controller.submit("   ")
        controller.submit("  oi titio ")
        XCTAssertEqual(sent, ["oi titio"])
    }

    // MARK: Reply style (2026-10-15)

    func test_deskHidesToolRowsForHumanBotsAndFollowsAVerbosityChange() async throws {
        // WHY: Verbosity Human shows only the Bot's messages; switching it to
        // Verbose (Studio or a paired device) must show the work rows again on
        // the open desk without reopening it.
        let f = try makeFixture()
        let titioID = try f.router.openTitio()
        let conversation = try XCTUnwrap(
            try f.vm.enqueueHostMessage(botID: titioID, text: "oi", conversationID: nil)
                .objectValue?["conversation_id"]?.stringValue.flatMap(UUID.init).map(BotConversationID.init)
        )
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "oi!")
        f.vm.reload()
        f.vm.openDesk(try XCTUnwrap(try f.context.botStore.get(id: titioID)))
        f.vm.selectDeskThread(conversation)
        let desk = try XCTUnwrap(f.vm.deskAgentVM)
        XCTAssertTrue(desk.hidesToolActivity, "Human is the default")

        try f.context.botStore.setReplyStyle(id: titioID, verbosity: .verbose)
        f.vm.reload()
        XCTAssertFalse(try XCTUnwrap(f.vm.deskAgentVM).hidesToolActivity, "Verbose shows today's work rows")
    }

    func test_studioSavesReplyStyleAndTitioFactoryResetPutsItBack() throws {
        // WHY: the Studio is where the owner picks Human/Verbose and Caveman;
        // the choice must persist, and Titio's reset restores Titio's defaults.
        let f = try makeFixture()
        let dev = try f.vm.create(name: "Developer", title: "Builds things")
        XCTAssertTrue(dev.cavemanEnabled, "new Bots are caveman")
        f.vm.reload()
        f.vm.openStudio(dev)
        XCTAssertEqual(f.vm.studioDraftReplyStyle.verbosity, .human, "new Bots start Simple")
        f.vm.studioDraft.verbosity = .human
        f.vm.studioDraft.cavemanEnabled = false
        XCTAssertTrue(f.vm.studioHasUnpublishedChanges, "a reply style edit is an unsaved change")
        _ = try f.vm.saveStudio()
        let saved = try XCTUnwrap(try f.context.botStore.get(id: dev.id))
        XCTAssertEqual(saved.verbosity, .human)
        XCTAssertFalse(saved.cavemanEnabled)
        XCTAssertFalse(f.vm.studioHasUnpublishedChanges)

        let titioID = try f.router.openTitio()
        XCTAssertEqual(try f.context.botStore.get(id: titioID)?.cavemanEnabled, false, "Titio is created without caveman")
        f.vm.reload()
        f.vm.openStudio(try XCTUnwrap(try f.context.botStore.get(id: titioID)))
        f.vm.studioDraft.verbosity = .verbose
        f.vm.studioDraft.cavemanEnabled = true
        _ = try f.vm.saveStudio()
        _ = try f.vm.restoreTitioFactorySettings()
        let titio = try XCTUnwrap(try f.context.botStore.get(id: titioID))
        XCTAssertEqual(titio.verbosity, .human)
        XCTAssertFalse(titio.cavemanEnabled)
    }
}

/// The choices card shows only while the newest reply still waits for an answer.
final class AgentChatChoicesPendingTests: XCTestCase {
    private func message(_ role: AgentMessageRole, _ content: String) -> AgentMessage {
        AgentMessage(threadId: AgentThreadID(), role: role, content: content)
    }

    private let block = "Qual?\n```choices\n{\"options\":[\"Sim\",\"Não\"]}\n```"

    func test_cardShowsForTheNewestReplyOnlyWhileUnanswered() {
        let reply = message(.assistant, block)
        XCTAssertEqual(AgentChatChoicesCard.Pending.latest(in: [message(.user, "oi"), reply], isRunning: false)?.choices.options,
                       ["Sim", "Não"])
        XCTAssertNil(AgentChatChoicesCard.Pending.latest(in: [reply], isRunning: true),
                     "no card while the Bot is still working")
        XCTAssertNil(AgentChatChoicesCard.Pending.latest(in: [reply, message(.user, "Sim")], isRunning: false),
                     "answered: the card goes away")
        XCTAssertNil(AgentChatChoicesCard.Pending.latest(in: [message(.assistant, "Pronto.")], isRunning: false))
    }

    func test_dismissedCardsStayClosedAndTheListIsBounded() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rc-choices-\(UUID().uuidString)"))
        for index in 0..<205 { AgentChatChoicesCard.DismissedStore.insert("m\(index)", defaults) }
        let dismissed = AgentChatChoicesCard.DismissedStore.load(defaults)
        XCTAssertEqual(dismissed.count, 200)
        XCTAssertTrue(dismissed.contains("m204"))
        XCTAssertFalse(dismissed.contains("m0"), "oldest ids roll off")
    }
}
