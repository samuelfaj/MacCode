import XCTest
@testable import AppShell
@testable import Persistence
import CoreModel
@testable import Surfaces

final class ActiveThreadsWindowTests: XCTestCase {
    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ActiveThreadsWindowTests.swift
            .deletingLastPathComponent() // AppShellTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent(relative)
    }

    func test_sidebarPlacesActivityImmediatelyAfterNewWorkspace_beforeScheduleTasks() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let newWorkspace = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.new\")"))
        let activeThreads = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.activity\")"))
        let scheduleTasks = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.scheduleTasks\")"))
        let reportBug = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.reportBug\")"))
        XCTAssertLessThan(reportBug.lowerBound, newWorkspace.lowerBound,
                          "Report Bug is a header icon, not a dest row under Active Threads")
        XCTAssertLessThan(newWorkspace.lowerBound, activeThreads.lowerBound)
        XCTAssertLessThan(activeThreads.lowerBound, scheduleTasks.lowerBound)
    }

    func test_sidebarActivityUsesServiceCountsAndExplicitLabels() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("vm.activityCounts"))
        XCTAssertTrue(source.contains("vm.activeBotCount"), "running Bots count with the Activity subtitle")
        XCTAssertTrue(source.contains("SidebarViewModel.activitySubtitle(vm.activityCounts, activeBots: vm.activeBotCount)"))
        XCTAssertTrue(source.contains("\\(counts.running) running · \\(counts.needsYou) need you"))
        XCTAssertTrue(source.contains("\"Activity, \" + SidebarViewModel.activitySubtitle"))
        XCTAssertFalse(source.contains("PetActiveThreadCountFormatter.badgeText(count: vm.activeThreadCount)"))
    }

    func test_activeThreadsOpensInMainContent_notDetachedWindow() throws {
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("presentActiveThreadsInMainContent"),
                      "Active Threads must mount in the main workspace content column")
        XCTAssertTrue(main.contains("installActiveThreadsContent"),
                      "main shell must install ActiveThreadsRootView into workspaceContent")
        XCTAssertTrue(main.contains("case activeThreads"),
                      "ShellContentMode must include activeThreads")
        XCTAssertTrue(main.contains("visibleWorkspaceLabel.stringValue = \"Active Threads\""),
                      "title bar must read Active Threads while that shell destination is active")
        XCTAssertTrue(sidebar.contains("onPresentActiveThreads"),
                      "sidebar must route Active Threads to the main shell presenter")
        XCTAssertTrue(sidebar.contains("isActiveThreadsSelected"),
                      "sidebar must track Active Threads selection so workspace rows can fully deselect")
        XCTAssertTrue(sidebar.contains("setActiveThreadsSelected"),
                      "shell must be able to select/deselect Active Threads without a floating window")
    }

    func test_activeThreadsRootViewHasActiveAndLastFinishedTabs() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ActiveThreadsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("case active"),
                      "Active tab is required")
        XCTAssertTrue(source.contains("case lastFinished"),
                      "Last Finished tab is required")
        XCTAssertTrue(source.contains("\"Active\""),
                      "Active tab label must be user-facing English")
        XCTAssertTrue(source.contains("\"Last Finished\""),
                      "Last Finished tab label must be user-facing English")
        XCTAssertTrue(source.contains("listRecentFinished"),
                      "finished tab must load durable recent terminal runs")
        XCTAssertTrue(source.contains("presentWorkspaceContent()"),
                      "opening a thread must leave the Active Threads shell first")
        XCTAssertTrue(source.contains("openAgentThread"),
                      "opening a row must route into the agent thread")
    }

    @MainActor
    func test_tabRefreshAcknowledgesSelectionAndKeepsLatestProjectionAndFailure() async throws {
        let directory = NSTemporaryDirectory() + "rc-active-refresh-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "Finished target", provider: .codex, model: "gpt-5")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id, provider: .codex, providerInstanceId: "codex", model: "gpt-5",
            status: .completed, startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 20)
        )
        try context.runRepo.upsert(run)

        let viewModel = ActiveThreadsViewModel(context: context, router: router, loadImmediately: false)
        viewModel.selectedTab = .lastFinished
        XCTAssertEqual(viewModel.selectedTab, .lastFinished,
                       "tab selection must be acknowledged before the deferred read")
        viewModel.scheduleTabRefresh(.lastFinished)
        viewModel.selectedTab = .active
        viewModel.scheduleTabRefresh(.active)
        viewModel.selectedTab = .lastFinished
        viewModel.scheduleTabRefresh(.lastFinished)
        for _ in 0..<1_000 {
            if viewModel.finishedItems.count == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(viewModel.selectedTab, .lastFinished)
        XCTAssertEqual(viewModel.finishedItems.map(\.runID), [run.id],
                       "the latest selected tab must publish the exact finished projection")
        XCTAssertEqual(viewModel.finishedItems.first?.title, "Finished target")

        try context.db.execute("DROP TABLE agent_runs")
        viewModel.selectedTab = .lastFinished
        viewModel.scheduleTabRefresh(.lastFinished)
        for _ in 0..<1_000 {
            if viewModel.errorMessage != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.errorMessage,
                        "a failed finished-run repository read must remain visible")
    }

    @MainActor
    func test_threadOpenDestinationIsKnownBeforeLeavingActivity() throws {
        // WHY: openAgentThread can only open a thread whose workspace is in the live layout.
        // Activity, Schedule Tasks and notification rows also list bot Desk threads (no
        // workspace) and threads of closed workspaces; callers must learn that before they
        // leave their screen, so a bot thread goes to its Desk and a dead one fails in place.
        let directory = NSTemporaryDirectory() + "rc-active-destination-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Open", cwd: NSTemporaryDirectory())

        let open = AgentThread(workspaceId: workspace.id, title: "open", provider: .codex, model: "m")
        let closed = AgentThread(workspaceId: WorkspaceID(), title: "closed", provider: .codex, model: "m")
        let orphan = AgentThread(workspaceId: nil, title: "orphan", provider: .codex, model: "m")
        let botThread = AgentThread(workspaceId: nil, title: "oi", provider: .claude, model: "m")
        for thread in [open, closed, orphan, botThread] { try context.threadRepo.upsert(thread) }
        let bot = try context.botStore.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let conversation = BotConversation(botID: bot.id, title: "oi", linkedAgentThreadID: botThread.id)
        try context.botStore.upsertConversation(conversation)

        XCTAssertEqual(try router.agentThreadOpenDestination(open.id), .workspace(workspace.id))
        XCTAssertEqual(try router.agentThreadOpenDestination(botThread.id), .bot(bot.id, conversation.id))
        XCTAssertEqual(try router.agentThreadOpenDestination(closed.id), .unavailable)
        XCTAssertEqual(try router.agentThreadOpenDestination(orphan.id), .unavailable)
    }

    @MainActor
    func test_activityOpensColdCanonicalBotConversationInVisibleDeskWindow() throws {
        let directory = NSTemporaryDirectory() + "rc-active-canonical-bot-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        controller.window.isReleasedWhenClosed = false
        controller.show()
        defer { controller.window.close() }

        let workspace = try router.createWorkspace(name: "Canonical Activity", cwd: NSTemporaryDirectory())
        defer {
            for surface in SurfaceRegistry.shared.all().compactMap({ $0 as? AgentAppSurface })
                where surface.viewModel.workspaceID == workspace.id {
                surface.close()
                SurfaceRegistry.shared.unregister(surface.descriptor.id)
            }
        }
        let bot = try context.botStore.create(name: "Piper", title: "Scout", description: "", provider: .distill)
        let grant = try context.botStore.grantContext(
            hostID: context.liveActivityHostIdentity.serverId, botID: bot.id,
            context: .workspace(workspace.id), actions: [.read], expectedRevision: 0
        )
        let thread = AgentThread(workspaceId: workspace.id, title: "Canonical Activity target", provider: .distill, model: "test")
        let conversation = BotConversation(botID: bot.id, title: "Canonical Activity target", linkedAgentThreadID: thread.id)
        try context.botStore.createContextualConversation(
            conversation, newThread: thread, hostID: context.liveActivityHostIdentity.serverId,
            context: .workspace(workspace.id), policyRevision: grant.policyRevision
        )
        let run = AgentRun(
            threadId: thread.id, provider: .distill, providerInstanceId: "distill", model: "test",
            status: .completed, startedAt: Date(), finishedAt: Date()
        )
        try context.runRepo.upsert(run)

        let activity = ActiveThreadsViewModel(context: context, router: router, loadImmediately: false)
        activity.reloadFinished()
        let item = try XCTUnwrap(activity.finishedItems.first { $0.runID == run.id })
        XCTAssertFalse(router.botsViewModel?.conversations.contains(where: { $0.id == conversation.id }) ?? false,
                      "cold target must not already be in the Desk view model cache")
        activity.openFinished(item)

        XCTAssertEqual(router.botsViewModel?.selectedBotID, bot.id)
        XCTAssertEqual(router.botsViewModel?.screen, .desk)
        let selectedConversation = try XCTUnwrap(router.botsViewModel?.selectedConversation)
        XCTAssertEqual(selectedConversation.id, conversation.id)
        XCTAssertEqual(selectedConversation.linkedAgentThreadID, thread.id)
        XCTAssertEqual(router.botsViewModel?.selectedPinnedContextLabel, workspace.name)
        XCTAssertTrue(controller.window.isVisible)
    }

    @MainActor
    func test_threadOpenDestinationPrioritizesAuthorizedCanonicalContextPins() throws {
        let directory = NSTemporaryDirectory() + "rc-context-destination-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspaceA = try router.createWorkspace(name: "A", cwd: NSTemporaryDirectory())
        let workspaceB = try router.createWorkspace(name: "B", cwd: NSTemporaryDirectory())
        let hostID = context.liveActivityHostIdentity.serverId
        let bot = try context.botStore.create(name: "Piper", title: "Scout", description: "", provider: .distill)

        func pin(_ contextValue: BotContext, workspaceID: WorkspaceID?, host: String) throws -> (AgentThread, BotConversation) {
            let grant = try context.botStore.grantContext(
                hostID: host, botID: bot.id, context: contextValue, actions: [.read], expectedRevision: nil
            )
            let thread = AgentThread(workspaceId: workspaceID, title: "context", provider: .distill, model: "distill")
            let conversation = BotConversation(botID: bot.id, title: "context", linkedAgentThreadID: thread.id)
            try context.botStore.createContextualConversation(
                conversation, newThread: thread, hostID: host, context: contextValue, policyRevision: grant.policyRevision
            )
            return (thread, conversation)
        }

        let workspacePin = try pin(.workspace(workspaceA.id), workspaceID: workspaceA.id, host: hostID)
        XCTAssertEqual(try router.agentThreadOpenDestination(workspacePin.0.id), .bot(bot.id, workspacePin.1.id))
        let generalPin = try pin(.general, workspaceID: nil, host: hostID)
        XCTAssertEqual(try router.agentThreadOpenDestination(generalPin.0.id), .bot(bot.id, generalPin.1.id))

        var mismatchedThread = try XCTUnwrap(context.threadRepo.get(id: workspacePin.0.id))
        mismatchedThread.workspaceId = workspaceB.id
        try context.threadRepo.upsert(mismatchedThread)
        XCTAssertEqual(try context.threadRepo.get(id: mismatchedThread.id)?.workspaceId, workspaceA.id,
                       "canonical thread placement must survive an attempted move")
        XCTAssertEqual(try router.agentThreadOpenDestination(mismatchedThread.id), .bot(bot.id, workspacePin.1.id))

        let revokedPin = try pin(.workspace(workspaceB.id), workspaceID: workspaceB.id, host: hostID)
        let revoked = try context.botStore.revokeContext(
            hostID: hostID, botID: bot.id, context: .workspace(workspaceB.id), expectedRevision: 1
        )
        XCTAssertEqual(revoked.state, .revoked)
        XCTAssertEqual(try router.agentThreadOpenDestination(revokedPin.0.id), .unavailable)

        let foreignWorkspace = try router.createWorkspace(name: "Foreign", cwd: NSTemporaryDirectory())
        let foreignPin = try pin(.workspace(foreignWorkspace.id), workspaceID: foreignWorkspace.id, host: "foreign-host")
        XCTAssertEqual(try router.agentThreadOpenDestination(foreignPin.0.id), .unavailable)

        let legacyBotThread = AgentThread(
            workspaceId: workspaceA.id, title: "legacy bot", provider: .claude, model: "m",
            actor: .bot(bot.id), actorLockedAt: Date()
        )
        try context.threadRepo.upsert(legacyBotThread)
        let legacyConversation = BotConversation(botID: bot.id, title: "legacy", linkedAgentThreadID: legacyBotThread.id)
        try context.botStore.upsertConversation(legacyConversation)
        XCTAssertEqual(try router.agentThreadOpenDestination(legacyBotThread.id), .workspace(workspaceA.id))

        let unrelatedThread = AgentThread(workspaceId: workspaceB.id, title: "mismatch", provider: .distill, model: "distill")
        let unrelatedConversation = BotConversation(botID: bot.id, title: "mismatch", linkedAgentThreadID: unrelatedThread.id)
        XCTAssertThrowsError(try context.botStore.createContextualConversation(
            unrelatedConversation, newThread: unrelatedThread, hostID: hostID,
            context: .workspace(workspaceA.id), policyRevision: 1
        ))
    }

    @MainActor
    func test_openActivity_unreachableThread_failsInPlaceWithReadableErrorAndReplacesStaleAlert() throws {
        // WHY: the open used to leave Activity first and fail a frame later on a hidden view,
        // as "CoreModel.LayoutError error 0". That alert then popped up on the next Activity
        // visit over an unrelated row (the /goal row in the report).
        let directory = NSTemporaryDirectory() + "rc-active-unreachable-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let closed = AgentThread(workspaceId: WorkspaceID(), title: "closed", provider: .codex, model: "m")
        try context.threadRepo.upsert(closed)
        let viewModel = ActiveThreadsViewModel(context: context, router: router, loadImmediately: false)
        viewModel.errorMessage = "Could not open thread: an older failure"

        viewModel.openActivity(ActivityWireItem(
            id: "run:x", kind: "agent", run_id: nil, request_id: nil, notification_id: nil,
            workspace_id: closed.workspaceId?.value.uuidString, thread_id: closed.id.value.uuidString, surface_id: nil,
            state: "completed", title: "closed", workspace_name: nil, provider: nil, summary: nil,
            occurred_at: "2026-10-14T12:00:00Z", started_at: nil, finished_at: nil, viewed_at: nil,
            attention_acknowledged_at: nil, needs_action: false, blocking: false,
            final_message_id: nil, checkpoint_id: nil, changed_files: [], error: nil
        ))

        // Same turn, no yield: the failure belongs to the click, not to a deferred task.
        let message = try XCTUnwrap(viewModel.errorMessage)
        XCTAssertEqual(message, "Could not open thread: Its workspace is closed or no longer exists.")
        XCTAssertFalse(message.contains("LayoutError"))
        XCTAssertFalse(message.contains("older failure"))
    }

    func test_appContextPublishesSidebarRefreshOnActiveCountChange_becauseBadgeMustStayLive() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/AppContext.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("lastPublishedActiveThreadCount"),
                      "projection refresh must track last published active count")
        XCTAssertTrue(source.contains("countChanged"),
                      "count-only transitions must refresh sidebar chrome")
        XCTAssertTrue(source.contains("titlesChanged || countChanged"),
                      "must not early-return when only active count changes")
    }

    func test_listRecentFinishedExcludesActiveStatuses_andRespectsLimit() throws {
        // WHY: Last Finished must never show pending/running rows and must stay capped.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "finished-list", provider: .grok, model: "grok-4.5")
        try threadRepo.upsert(thread)
        let threadID = thread.id

        let finished = AgentRun(
            id: AgentRunID(),
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok",
            model: "grok-4.5",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200)
        )
        let running = AgentRun(
            id: AgentRunID(),
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok",
            model: "grok-4.5",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 300)
        )
        let olderFinished = AgentRun(
            id: AgentRunID(),
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude",
            model: "opus",
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 50)
        )
        try runRepo.upsert(finished)
        try runRepo.upsert(running)
        try runRepo.upsert(olderFinished)

        let rows = try runRepo.listRecentFinished(limit: 1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, finished.id)
        XCTAssertEqual(rows[0].status, .completed)

        let allFinished = try runRepo.listRecentFinished(limit: 10)
        XCTAssertEqual(allFinished.count, 2)
        XCTAssertFalse(allFinished.contains(where: { $0.status == .running || $0.status == .pending }))
        XCTAssertEqual(allFinished.map(\.id), [finished.id, olderFinished.id])
    }

    @MainActor
    func test_reloadFinished_usesListChromeWithoutDurableGet() throws {
        // WHY: Last Finished used to compile one full threadRepo.get per run
        // (26 columns + routing JSON) on MainActor. Chrome is four columns.
        let directory = NSTemporaryDirectory() + "rc-active-chrome-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspaceID = WorkspaceID()
        var threads: [AgentThread] = []
        for index in 0..<20 {
            let thread = AgentThread(
                workspaceId: workspaceID,
                title: "Finished \(index)",
                provider: .codex,
                model: "gpt-5"
            )
            try context.threadRepo.upsert(thread)
            try context.runRepo.upsert(AgentRun(
                threadId: thread.id,
                provider: .codex,
                providerInstanceId: "codex",
                model: "gpt-5",
                status: .completed,
                startedAt: Date(timeIntervalSince1970: Double(index)),
                finishedAt: Date(timeIntervalSince1970: Double(100 + index))
            ))
            threads.append(thread)
        }
        let viewModel = ActiveThreadsViewModel(context: context, router: router, loadImmediately: false)
        let getsBefore = context.threadRepo.durableGetCountForTesting
        let chromeBefore = context.threadRepo.listChromeCallCountForTesting
        viewModel.reloadFinished()
        XCTAssertEqual(viewModel.finishedItems.count, 20)
        XCTAssertEqual(
            Set(viewModel.finishedItems.map(\.title)),
            Set(threads.map(\.title)),
            "finished rows must keep the durable thread title"
        )
        XCTAssertEqual(
            context.threadRepo.durableGetCountForTesting,
            getsBefore,
            "reloadFinished must not compile N full gets"
        )
        XCTAssertEqual(
            context.threadRepo.listChromeCallCountForTesting,
            chromeBefore + 1
        )
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ActiveThreadsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("listChrome(ids:"))
        XCTAssertFalse(
            source.contains("threadRepo.get(id: threadID)"),
            "reloadActive must not walk full gets for painted chrome"
        )
        XCTAssertFalse(source.contains("threadRepo.get(id: run.threadId)"))
    }

    func test_listChrome_skipsUnknownIds() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        let kept = AgentThread(title: "kept", provider: .grok, model: "grok-4")
        try threadRepo.upsert(kept)
        let missing = AgentThreadID()
        let chrome = try threadRepo.listChrome(ids: [kept.id, missing])
        XCTAssertEqual(Set(chrome.keys), [kept.id])
        XCTAssertEqual(chrome[kept.id]?.title, "kept")
        XCTAssertEqual(chrome[kept.id]?.provider, .grok)
        XCTAssertEqual(chrome[kept.id]?.model, "grok-4")
        XCTAssertNil(chrome[missing])
    }

    func test_listChrome_fasterThanNDurableGets() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        var ids: [AgentThreadID] = []
        ids.reserveCapacity(20)
        for index in 0..<20 {
            let thread = AgentThread(title: "chrome-\(index)", provider: .claude, model: "opus")
            try threadRepo.upsert(thread)
            ids.append(thread.id)
        }
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try threadRepo.listChrome(ids: ids)
            for id in ids { _ = try threadRepo.get(id: id) }
        }
        var chromeSamples: [Double] = []
        var getSamples: [Double] = []
        chromeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            chromeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.listChrome(ids: ids)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    for id in ids { _ = try threadRepo.get(id: id) }
                }
            })
        }
        let chromeMed = median(chromeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - chromeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] active-threads listChrome_ms=%@ durable_get_ms=%@ improvement_pct=%.2f chrome=%@ get=%@",
            String(chromeMed), String(getMed), improvement,
            String(describing: chromeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "batched listChrome must beat N durable gets by ≥5% (got \(improvement)%; chrome=\(chromeMed)ms get=\(getMed)ms)"
        )
    }
    private func workspace(_ name: String, _ surfaces: [SurfaceDescriptor]) -> Workspace {
        Workspace(name: name, cwd: "/tmp", layout: .pane(PaneNode(surfaces: surfaces)))
    }

    func test_projectorListsEveryBusySurfaceExceptAgentApp_inWorkspaceThenLayoutOrder() {
        let busyTerminal = SurfaceDescriptor(type: .terminal, title: "build")
        let idle = SurfaceDescriptor(type: .terminal, title: "idle")
        let busySSH = SurfaceDescriptor(type: .ssh, title: "")
        let busyBrowser = SurfaceDescriptor(type: .browser, title: "")
        let busyDiff = SurfaceDescriptor(type: .rightSidebarTool, title: "")
        let busyAgentApp = SurfaceDescriptor(type: .agentApp, title: "agent")
        let busyUntitled = SurfaceDescriptor(type: .terminal, title: "")
        let first = workspace("One", [busyTerminal, idle, busySSH, busyBrowser, busyAgentApp])
        let second = workspace("Two", [busyDiff, busyUntitled])
        let busy: Set<SurfaceID> = [busyTerminal.id, busySSH.id, busyBrowser.id, busyDiff.id, busyAgentApp.id, busyUntitled.id]

        let items = ActiveSurfaceProjector.items(workspaces: [first, second]) { busy.contains($0.id) }

        XCTAssertEqual(items.map(\.surfaceID), [busyTerminal.id, busySSH.id, busyBrowser.id, busyDiff.id, busyUntitled.id],
                       "every busy non-agentApp surface counts, ordered by workspace then layout")
        XCTAssertEqual(items.map(\.title), ["build", "Terminal", "Browser", "Diff", "Terminal"])
        XCTAssertEqual(items.map(\.workspaceName), ["One", "One", "One", "Two", "Two"])
        XCTAssertEqual(items.first?.workspaceID, first.id)
    }

    func test_projectorDropsTerminalWhenItGoesIdle() {
        let terminal = SurfaceDescriptor(type: .terminal, title: "run")
        let ws = workspace("W", [terminal])
        XCTAssertEqual(ActiveSurfaceProjector.items(workspaces: [ws]) { _ in true }.count, 1)
        XCTAssertTrue(ActiveSurfaceProjector.items(workspaces: [ws]) { _ in false }.isEmpty,
                      "busy -> idle must remove the row so the screen stops listing finished work")
    }

    @MainActor
    func test_openSurfaceSelectsWorkspaceAndFocusesTerminal() throws {
        let directory = NSTemporaryDirectory() + "rc-active-open-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        defer {
            for surface in SurfaceRegistry.shared.all() {
                surface.close()
                SurfaceRegistry.shared.unregister(surface.descriptor.id)
            }
        }
        let first = try router.createWorkspace(name: "first", cwd: NSTemporaryDirectory())
        _ = try router.createWorkspace(name: "second", cwd: NSTemporaryDirectory())
        XCTAssertNotEqual(context.state.window.selectedWorkspaceID, first.id)
        let paneID = try XCTUnwrap(context.state.workspaces[first.id]?.layout.paneIDs().first)
        let target = try XCTUnwrap(context.state.workspaces[first.id]?.layout.find(paneID: paneID)?.surfaces.first)
        let other = try router.createSurface(workspace: first.id, type: .browser, paneID: paneID, title: "other")
        XCTAssertEqual(context.state.workspaces[first.id]?.layout.find(paneID: paneID)?.selectedSurfaceID, other.id,
                       "precondition: the newer tab is selected so opening the first one must change selection")
        let item = ActiveSurfaceItem(
            id: target.id.value, workspaceID: first.id, workspaceName: "first",
            surfaceID: target.id, title: target.title, type: target.type
        )
        let viewModel = ActiveThreadsViewModel(context: context, router: router, loadImmediately: false)

        viewModel.openSurface(item)

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(context.state.window.selectedWorkspaceID, first.id,
                       "opening a busy terminal must switch to its workspace")
        XCTAssertEqual(context.state.workspaces[first.id]?.layout.find(paneID: paneID)?.selectedSurfaceID, target.id,
                       "opening a busy tab must select it inside its pane, not just its workspace")
    }

    @MainActor
    func test_selectDeskThreadOpensLegacyAndPreservesStateWhenPinnedContextRevoked() throws {
        let directory = NSTemporaryDirectory() + "rc-select-legacy-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .distill)
        vm.openDesk(bot)

        let unpinned = BotConversation(botID: bot.id, title: "uncached legacy")
        try context.botStore.upsertConversation(unpinned)
        vm.selectDeskThread(unpinned.id)
        XCTAssertEqual(vm.selectedConversation?.id, unpinned.id)

        let workspace = try AppCommandRouter(context: context).createWorkspace(name: "Ordinary", cwd: NSTemporaryDirectory())
        let thread = AgentThread(workspaceId: workspace.id, title: "ordinary", provider: .distill, model: "test")
        try context.threadRepo.upsert(thread)
        let linked = BotConversation(botID: bot.id, title: "linked legacy", linkedAgentThreadID: thread.id)
        try context.botStore.upsertConversation(linked)
        vm.selectDeskThread(linked.id)
        XCTAssertEqual(vm.selectedConversation?.id, linked.id)

        let hostID = context.liveActivityHostIdentity.serverId
        let pinnedGrant = try context.botStore.grantContext(
            hostID: hostID, botID: bot.id, context: .workspace(workspace.id), actions: [.read], expectedRevision: 0
        )
        let pinnedThread = AgentThread(workspaceId: workspace.id, title: "pinned", provider: .distill, model: "test")
        let pinned = BotConversation(botID: bot.id, title: "revoked", linkedAgentThreadID: pinnedThread.id)
        try context.botStore.createContextualConversation(
            pinned, newThread: pinnedThread, hostID: hostID, context: .workspace(workspace.id),
            policyRevision: pinnedGrant.policyRevision
        )
        _ = try context.botStore.revokeContext(
            hostID: hostID, botID: bot.id, context: .workspace(workspace.id), expectedRevision: 1
        )
        let selectionBeforeRefusal = vm.selectedConversation?.id
        let cacheBeforeRefusal = vm.conversations.map(\.id)
        vm.selectDeskThread(pinned.id)
        XCTAssertEqual(vm.selectedConversation?.id, selectionBeforeRefusal)
        XCTAssertEqual(vm.conversations.map(\.id), cacheBeforeRefusal)
        XCTAssertFalse(vm.conversations.contains { $0.id == pinned.id })
        XCTAssertFalse(vm.errorMessage?.isEmpty ?? true)
    }

    func test_activeListOrdersByRunStartNotThreadID() {
        // WHY: rows must keep run-start order; a UUID sort reshuffles the Active list as runs come and go.
        let late = AgentThreadID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let early = AgentThreadID(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!)
        let added = AgentThreadID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let starts: [AgentThreadID: Date] = [
            early: Date(timeIntervalSince1970: 100),
            late: Date(timeIntervalSince1970: 200)
        ]
        let projected = PetActiveThreadProjector.items(threadIDs: [late, early, added], now: Date(timeIntervalSince1970: 300)) { id in
            (workspaceID: nil, workspaceName: nil, providerName: nil, threadTitle: nil,
             startedAt: starts[id], lastUpdatePreview: nil)
        }
        XCTAssertEqual(projected.map(\.threadID), [early, late, added],
                       "Rows without a start stamp append after timed rows.")
    }

    func test_tabClickRefreshesTheSelectedTab() throws {
        // WHY: switching to Last Finished must reload it now, not show the list from before the switch.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ActiveThreadsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("vm.selectedTab = tab\n                    vm.scheduleTabRefresh(tab)"))
    }
}
