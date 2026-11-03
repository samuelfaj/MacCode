import XCTest
import SwiftUI
import AppKit
import Combine
import CoreModel
@testable import AppShell
@testable import Persistence

final class ScheduledTasksWindowTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    func test_distillModelsResolveLegacyInstanceId_becauseSavedTasksMustKeepTheirConnectedAccount() {
        let model = AgentModelDescriptor(id: "main", label: "Main", provider: .distill)
        let snapshot = AgentProviderSnapshot(
            id: "distill-acp", provider: .distill, driverKind: .distillACP,
            displayName: "Distill", accentColor: "#6E56CF", continuationGroup: "distill",
            interactionModes: [.default], enabled: true, installed: true, status: .available,
            authenticated: true, models: [model], slashCommands: []
        )
        XCTAssertEqual([snapshot].resolvedSnapshot(provider: .distill, instanceID: "distill")?.models, [model])

        let exact = AgentProviderSnapshot(
            id: "distill", provider: .distill, driverKind: .distillACP,
            displayName: "Exact", accentColor: "#6E56CF", continuationGroup: "distill",
            interactionModes: [.default], enabled: false, installed: true, status: .available,
            models: [], slashCommands: []
        )
        XCTAssertEqual([snapshot, exact].resolvedSnapshot(provider: .distill, instanceID: "distill")?.id, "distill")
    }

    func test_editorBuildsFullTaskWithNextRun_becauseSavedSchedulesMustBeImmediatelyRunnable() throws {
        var draft = ScheduledTaskEditorDraft(now: Date(timeIntervalSince1970: 100))
        draft.title = "Audit"
        draft.prompt = "Inspect"
        draft.workspaceID = WorkspaceID()
        draft.workspacePathSnapshot = "/tmp"
        draft.runAsUser = NSUserName()
        draft.runAsUID = ScheduledSystemUserCatalog.user(named: NSUserName())?.uid ?? 501
        draft.providerInstanceID = "codex"
        draft.model = "gpt-5"
        draft.frequencyRules[0].frequency = .hourly
        draft.frequencyRules[0].intervalHours = 2
        draft.frequencyRules[0].scheduledDate = Date(timeIntervalSince1970: 200)

        let task = try draft.makeTask(now: Date(timeIntervalSince1970: 150))

        XCTAssertEqual(task.permissionModeForScheduledExecution, .fullAccess)
        XCTAssertEqual(task.effectiveRoutingMode, .auto)
        XCTAssertEqual(task.nextRunAt, Date(timeIntervalSince1970: 200))
    }

    func test_distillScheduleRestoresAndRunsManually_becauseItCannotAutoRouteModels() throws {
        let now = Date(timeIntervalSince1970: 100)
        var draft = ScheduledTaskEditorDraft(now: now)
        draft.title = "Distill task"
        draft.prompt = "Inspect"
        draft.workspaceID = WorkspaceID()
        draft.workspacePathSnapshot = "/tmp"
        draft.runAsUser = NSUserName()
        draft.runAsUID = ScheduledSystemUserCatalog.user(named: NSUserName())?.uid ?? 501
        draft.provider = .distill
        draft.providerInstanceID = "distill"
        draft.model = "grok-4.6"
        draft.reasoningModel = "chatgpt/gpt-6-sol"
        draft.distillMainEffortSelection = .fixed(.high)
        draft.distillReasoningEffortSelection = .automatic
        draft.routingMode = .auto

        let task = try draft.makeTask(now: now)
        XCTAssertEqual(task.routingMode, .manual)
        XCTAssertEqual(task.effectiveRoutingMode, .manual)
        XCTAssertEqual(task.reasoningModel, "chatgpt/gpt-6-sol")
        XCTAssertEqual(task.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(task.distillReasoningEffortSelection, .automatic)
        let restoredDraft = ScheduledTaskEditorDraft(task: task, now: now)
        XCTAssertEqual(restoredDraft.reasoningModel, "chatgpt/gpt-6-sol")
        XCTAssertEqual(restoredDraft.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(restoredDraft.distillReasoningEffortSelection, .automatic)

        var persistedTask = task
        persistedTask.routingMode = .auto
        XCTAssertEqual(persistedTask.effectiveRoutingMode, .manual)
        XCTAssertEqual(ScheduledTaskEditorDraft(task: persistedTask, now: now).routingMode, .manual)
    }

    @MainActor
    func test_botTaskEditorReplacesTheOverviewTheMomentTheBotsModelPublishesADraft() async throws {
        let directory = NSTemporaryDirectory() + "RC2SchedBots-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        _ = try context.botStore.create(name: "Writer", title: "", description: "", handle: "writer")
        let botsVM = BotsViewModel(context: context, router: router)
        let viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        let hosting = NSHostingView(rootView: ScheduledTasksRootView(vm: viewModel, botsVM: botsVM).frame(width: 1000, height: 700))
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func snapshot() throws -> Data {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let overview = try snapshot()

        botsVM.createScheduleTask()
        let editor = try snapshot()
        XCTAssertNotEqual(editor, overview, "New Bot Task must replace the overview with the editor without any other state change")

        botsVM.scheduleTaskDraft = nil
        XCTAssertEqual(try snapshot(), overview, "Back/Save must return to the overview")
    }

    func test_overviewHasOneNewTaskButton_becauseBotsAreChosenInRunAs() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("New Bot Task"))
        XCTAssertFalse(source.contains("scheduledTasks.newBot"))
        XCTAssertTrue(source.contains("botsProvider:"), "Run as must list Bots like the Agent App composer")
    }

    @MainActor
    func test_choosingABotKeepsEverythingTyped_becauseOneEditorCreatesBothKinds() throws {
        let directory = NSTemporaryDirectory() + "RC2SchedCarry-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let bot = try context.botStore.create(name: "Writer", title: "", description: "", handle: "writer")
        let botsVM = BotsViewModel(context: context, router: router)
        var draft = ScheduledTaskEditorDraft()
        draft.title = "Digest"
        draft.prompt = "Summarize"
        draft.provider = .distill
        draft.model = "auto"
        draft.distillExecutionMode = .ultrafast
        draft.permissionMode = .autoAcceptEdits

        botsVM.beginScheduleTask(botID: bot.id, carrying: draft)

        let carried = try XCTUnwrap(botsVM.scheduleTaskDraft)
        XCTAssertEqual(carried.botID, bot.id)
        XCTAssertEqual(carried.name, "Digest")
        XCTAssertEqual(carried.prompt, "Summarize")
        XCTAssertEqual(carried.spec.model, "auto")
        XCTAssertEqual(carried.spec.distillExecutionMode, .ultrafast)
        XCTAssertEqual(carried.spec.permissionMode, .autoAcceptEdits)
        XCTAssertEqual(carried.spec.frequencyRules, draft.frequencyRules)
    }

    func test_sidebarPlacesScheduleTasksAfterActivity_becauseNavigationOrderIsContractual() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let newWorkspace = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.new\")"))
        let activeThreads = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.activity\")"))
        let scheduleTasks = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.scheduleTasks\")"))
        let reportBug = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.reportBug\")"))
        let updateControl = try XCTUnwrap(source.range(of: "if vm.showsUpdateControl"))

        XCTAssertLessThan(reportBug.lowerBound, newWorkspace.lowerBound,
                          "Report Bug is a header icon, not a dest row under Schedule Tasks")
        XCTAssertLessThan(newWorkspace.lowerBound, activeThreads.lowerBound)
        XCTAssertLessThan(activeThreads.lowerBound, scheduleTasks.lowerBound)
        XCTAssertLessThan(scheduleTasks.lowerBound, updateControl.lowerBound)
    }

    func test_sidebarReportBugOpensMailtoToMaintainer_becauseBugReportsMustReachSupport() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("accessibilityLabel(\"Report Bug\")"),
                      "sidebar must expose Report Bug as a header icon")
        XCTAssertTrue(source.contains(".help(\"Report a bug via email\")"),
                      "the header ladybug must keep a tooltip")
        XCTAssertTrue(source.contains("samuelfajreldines@gmail.com"),
                      "Report Bug must address the maintainer mailbox")
        XCTAssertTrue(source.contains("mailto"),
                      "Report Bug must open a mailto: compose window")
        XCTAssertTrue(source.contains("NSWorkspace.shared.open"),
                      "Report Bug must hand off to the system mail client")
    }

    func test_scheduleTasksOpensInMainContent_notOnlyDetachedWindow() throws {
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("presentScheduledTasksInMainContent"),
                      "Schedule Tasks must mount in the main workspace content column")
        XCTAssertTrue(main.contains("installScheduledTasksContent"),
                      "main shell must install ScheduledTasksRootView into workspaceContent")
        XCTAssertTrue(sidebar.contains("onPresentScheduledTasks"),
                      "sidebar must route Schedule Tasks to the main shell presenter")
        XCTAssertTrue(sidebar.contains("onWorkspaceContentActivated"),
                      "selecting a workspace must leave the Schedule Tasks shell destination")
        XCTAssertTrue(main.contains("visibleWorkspaceLabel.stringValue = \"Schedule Tasks\""),
                      "title bar must read Schedule Tasks while that shell destination is active")
        XCTAssertTrue(sidebar.contains("isScheduledTasksSelected"),
                      "sidebar must track Schedule Tasks selection so workspace rows can fully deselect")
    }

    func test_overviewSearchFieldAutofocusesOnOpen_becauseTypingMustStartWithoutAClick() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        let searchStart = try XCTUnwrap(source.range(of: "private var searchField"))
        let searchEnd = try XCTUnwrap(source.range(of: "private func shortProviderModel"))
        let search = String(source[searchStart.lowerBound..<searchEnd.lowerBound])
        XCTAssertTrue(search.contains("AgentListSearchField("),
                      "overview search must stay on the shared AgentListSearchField")
        XCTAssertTrue(search.contains("autofocus: true"),
                      "opening Schedule Tasks must focus Search tasks so the user can type immediately")
        XCTAssertTrue(search.contains("identifier: \"scheduledTasks.search\""))
    }

    func test_editorDoesNotForceUnwrapPublishedDraft_becauseSaveClearsItDuringRender() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("vm.editorDraft!"))
        // Plan mockups use a full-page editor route (not a modal sheet).
        XCTAssertTrue(source.contains("case .editor"),
                      "editor must be a navigation screen so Cancel/Save match the plan chrome")
        XCTAssertTrue(source.contains("if let draft = vm.editorDraft"),
                      "editor must bind the optional draft without force-unwrap after save clears it")
    }

    func test_savePreflightsBeforePersist_becauseInvalidTasksMustNotBeSavedActive() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        // WHY: save still preflights provider/workspace before persisting. Login
        // Items approval is retired — schedules run in-process while the app is open.
        XCTAssertTrue(source.contains(".preflight(task)"))
        XCTAssertTrue(source.contains("router.scheduledTaskScheduler"))
        XCTAssertFalse(source.contains("scheduledTasks.openLoginItems"))
        XCTAssertFalse(source.contains("Task saved paused."))
    }

    func test_failureDetailsCanExpand_becauseSafeHistoryErrorsMustRemainInspectable() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("expandedRunIDs"))
        XCTAssertTrue(source.contains("Show details"))
        XCTAssertTrue(source.contains("Hide details"))
        XCTAssertTrue(source.contains("scheduledTasks.history.toggleDetails"),
                      "failure disclosure must be a dedicated control, not the whole row")
    }

    func test_failedHistoryRowShowsReasonWithoutExpansion_becauseFailureMustNotBeOpaque() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        let primaryStart = try XCTUnwrap(source.range(of: "private func historyRowPrimaryContent"))
        let primaryEnd = try XCTUnwrap(source.range(of: "private func agentTaskTitle"))
        let primary = String(source[primaryStart.lowerBound..<primaryEnd.lowerBound])

        XCTAssertTrue(primary.contains("if run.status == .failed, let error = run.errorSummary"))
        XCTAssertTrue(primary.contains("Text(error)"))
        XCTAssertTrue(primary.contains(".lineLimit(1)"),
                      "the visible reason must keep history rows compact; full text stays in details")
    }

    func test_historyRowOpensThreadOnPrimaryClick_becauseCompletedRunsMustStayNavigable() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        // WHY: completed runs used to wrap the row in a disabled Button, which also
        // disabled the nested Agent Task control and blocked openThread navigation.
        XCTAssertTrue(source.contains("scheduledTasks.history.openThread"))
        XCTAssertTrue(source.contains("vm.openThread(run)"))
        XCTAssertTrue(source.contains("canOpenThread"))
        XCTAssertTrue(source.contains("historyRowPrimaryContent"))
        XCTAssertFalse(
            source.contains(".disabled(run.errorSummary == nil && run.status != .failed)"),
            "history rows must not disable open-thread hit targets on successful runs"
        )
    }

    func test_runNowSetsQueuedImmediately_becauseUsersNeedSameClickFeedback() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        // WHY: Run Now used to wait for the XPC claim before any badge change,
        // so the overview card stayed Active until the agent replied.
        XCTAssertTrue(source.contains("activeRunStatuses[task.id] = .queued"))
        XCTAssertTrue(source.contains("DSPill(\"Queued\""))
        XCTAssertTrue(source.contains("activeRunStatus: vm.activeRunStatus(for: task.id)"))
        XCTAssertTrue(source.contains("ensureActiveRunPolling"))
    }

    func test_searchAndSelectionUseScopedDeferredPasses_becauseOverviewHydrationMustNotRepeat() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("scheduleTasksRefreshPass()"))
        XCTAssertTrue(source.contains("scheduleRunsRefreshPass()"))
        XCTAssertTrue(source.contains("tasksRefreshGeneration &+= 1"))
        XCTAssertTrue(source.contains("runsRefreshGeneration &+= 1"))
        XCTAssertTrue(source.contains("finishTasksRefreshTask(ownedBy: generation)"))
        XCTAssertTrue(source.contains("finishRunsRefreshTask(ownedBy: generation)"))
        XCTAssertFalse(
            source.contains("if deferHydration { scheduleFreshnessPass() } else { reloadTasks() }"),
            "typing in the overview must not re-run unrelated workspace/provider hydration"
        )
        XCTAssertFalse(
            source.contains("if deferHydration { scheduleFreshnessPass() } else { reloadRuns() }"),
            "selecting a task must not re-run unrelated overview hydration"
        )
    }

    @MainActor
    func test_scopedRefreshPublishesExactTaskAndRunResults_latestSearchWins() async throws {
        let directory = NSTemporaryDirectory() + "rc-scheduled-refresh-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let store = ScheduledTaskStore(db: context.db)
        let workspaceID = WorkspaceID()
        let older = ScheduledTask(
            title: "Alpha task", prompt: "Alpha prompt", workspaceID: workspaceID,
            workspacePathSnapshot: "/tmp", runAsUser: NSUserName(), runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC",
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = ScheduledTask(
            title: "Beta task", prompt: "Beta prompt", workspaceID: workspaceID,
            workspacePathSnapshot: "/tmp", runAsUser: NSUserName(), runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC",
            createdAt: Date(timeIntervalSince1970: 20), updatedAt: Date(timeIntervalSince1970: 20)
        )
        try store.save(older)
        try store.save(newer)
        let claim = try store.claimManual(
            taskID: older.id,
            now: Date(timeIntervalSince1970: 30),
            owner: "scheduled-refresh-test"
        )
        try store.finish(
            runID: claim.run.id,
            status: .failed,
            errorCode: "provider_unavailable",
            errorSummary: "provider unavailable",
            at: Date(timeIntervalSince1970: 40)
        )
        let expectedTasks = try store.list()

        let viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.tasks, expectedTasks,
                       "the initial pass must publish the exact persisted task order")
        XCTAssertEqual(viewModel.fullHydrationCountForTesting, 1)

        viewModel.selectedTaskID = older.id
        XCTAssertEqual(viewModel.selectedTaskID, older.id,
                       "selection must be acknowledged before the scoped history read")
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.runs.map(\.id), [claim.run.id])
        XCTAssertEqual(viewModel.runs.first?.taskID, older.id)
        XCTAssertEqual(viewModel.runs.first?.status, .failed)
        XCTAssertEqual(viewModel.runs.first?.errorCode, "provider_unavailable")
        XCTAssertEqual(viewModel.runs.first?.errorSummary, "provider unavailable")

        let hydrationCount = viewModel.fullHydrationCountForTesting
        viewModel.searchText = "Alpha"
        viewModel.searchText = "Beta"
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.tasks.map(\.id), [newer.id],
                       "the latest search must win and publish only its exact task projection")
        XCTAssertEqual(viewModel.fullHydrationCountForTesting, hydrationCount,
                       "search refreshes must not repeat the full overview hydration")

        let publishedTasksBeforeFailure = viewModel.tasks
        try context.db.execute("DROP TABLE scheduled_tasks")
        viewModel.searchText = "Beta"
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.tasks, publishedTasksBeforeFailure,
                       "a failed scoped read must not replace the last known task projection")
        XCTAssertNotNil(viewModel.errorMessage,
                        "a failed scoped read must remain visible to the user")
    }

    @MainActor
    func test_activeRunPollReloadsHistoryOnlyWhenAnActiveRowChanges_becauseItTicksEverySecondOnMain() async throws {
        // WHY: the 1 s poll used to reload and republish 200 history rows on
        // the main thread every tick (~56 ms on a real database) while any
        // scheduled run was active, re-rendering the window each second.
        let directory = NSTemporaryDirectory() + "rc-scheduled-poll-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let store = ScheduledTaskStore(db: context.db)
        let task = ScheduledTask(
            title: "Poll task", prompt: "Poll prompt", workspaceID: WorkspaceID(),
            workspacePathSnapshot: "/tmp", runAsUser: NSUserName(), runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC",
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 30), owner: "poll-test")

        let viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.activeRunStatus(for: task.id), .queued)
        // History is a detail-screen read; open the task's detail first.
        viewModel.selectedTaskID = task.id
        await viewModel.waitForFreshnessForTesting()
        defer { viewModel.setVisible(false) }
        var runPublishes = 0, statusPublishes = 0
        let runsSink = viewModel.$runs.dropFirst().sink { _ in runPublishes += 1 }
        let statusSink = viewModel.$activeRunStatuses.dropFirst().sink { _ in statusPublishes += 1 }
        defer { runsSink.cancel(); statusSink.cancel() }

        viewModel.pollActiveRunsOnce()
        viewModel.pollActiveRunsOnce()
        XCTAssertEqual(runPublishes, 0, "an unchanged active run must not reload the history")
        XCTAssertEqual(statusPublishes, 0, "an unchanged status map must not republish")

        // Thread attached while still running: the row's Open-thread target must appear.
        try store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID())
        viewModel.pollActiveRunsOnce()
        XCTAssertEqual(runPublishes, 1)
        XCTAssertEqual(viewModel.activeRunStatus(for: task.id), .running)
        XCTAssertNotNil(viewModel.runs.first { $0.id == claim.run.id }?.threadID)

        try store.finish(runID: claim.run.id, status: .completed, at: Date(timeIntervalSince1970: 60))
        viewModel.pollActiveRunsOnce()
        XCTAssertEqual(runPublishes, 2, "finishing must refresh the history exactly once")
        XCTAssertNil(viewModel.activeRunStatus(for: task.id))
        XCTAssertEqual(viewModel.runs.first { $0.id == claim.run.id }?.status, .completed)
    }

    @MainActor
    private func makePollFixture(_ name: String) throws -> (
        directory: String, context: AppContext, router: AppCommandRouter, store: ScheduledTaskStore, task: ScheduledTask
    ) {
        let directory = NSTemporaryDirectory() + "rc-scheduled-\(name)-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let store = ScheduledTaskStore(db: context.db)
        let task = ScheduledTask(
            title: "Poll task", prompt: "Poll prompt", workspaceID: WorkspaceID(),
            workspacePathSnapshot: "/tmp", runAsUser: NSUserName(), runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC",
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        try store.save(task)
        return (directory, context, router, store, task)
    }

    @MainActor
    func test_overviewPollNeverReadsHistoryAndHeartbeatsAreNotChanges_becauseOnlyTheDetailShowsHistory() async throws {
        // WHY: the overview never renders `runs`, yet every active-row change
        // decoded the 200 newest runs of all tasks on the main thread; and the
        // scheduler rewrites heartbeat_at every 30 s, which forced that reload
        // (and a history republish) twice a minute for the whole run.
        let f = try makePollFixture("overview-poll")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let claim = try f.store.claimManual(taskID: f.task.id, now: Date(timeIntervalSince1970: 30), owner: "poll-test")
        let viewModel = ScheduledTasksViewModel(context: f.context, router: f.router, loadImmediately: false)
        defer { viewModel.setVisible(false) }
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertNil(viewModel.selectedTaskID)
        XCTAssertEqual(viewModel.runHistoryReadCountForTesting, 0, "the overview's freshness pass must not read history")

        try f.store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID())
        viewModel.pollActiveRunsOnce()
        XCTAssertEqual(viewModel.activeRunStatus(for: f.task.id), .running, "badges still follow the store")
        XCTAssertEqual(viewModel.runHistoryReadCountForTesting, 0, "an active-row change on the overview reads no history")

        viewModel.selectedTaskID = f.task.id
        await viewModel.waitForFreshnessForTesting()
        let readsOnDetail = viewModel.runHistoryReadCountForTesting
        XCTAssertEqual(readsOnDetail, 1)
        var runPublishes = 0
        let sink = viewModel.$runs.dropFirst().sink { _ in runPublishes += 1 }
        defer { sink.cancel() }
        for second in 1...30 {
            try f.store.heartbeat(runID: claim.run.id, at: Date(timeIntervalSince1970: 100 + Double(second * 30)))
            viewModel.pollActiveRunsOnce()
        }
        XCTAssertEqual(viewModel.runHistoryReadCountForTesting, readsOnDetail, "heartbeat-only polls must not reload history")
        XCTAssertEqual(runPublishes, 0)

        try f.store.finish(runID: claim.run.id, status: .completed, at: Date(timeIntervalSince1970: 2_000))
        viewModel.pollActiveRunsOnce()
        XCTAssertEqual(viewModel.runHistoryReadCountForTesting, readsOnDetail + 1, "finishing refreshes history once")
        XCTAssertEqual(runPublishes, 1)
        XCTAssertEqual(viewModel.runs.first { $0.id == claim.run.id }?.status, .completed)
        XCTAssertNil(viewModel.activeRunStatus(for: f.task.id))
    }

    @MainActor
    func test_hiddenHostStopsThePollAndRemountShowsTheStoreTruth_becauseTheModelOutlivesTheScreen() async throws {
        // WHY: MainWindowController caches this model, so the 1 s main-thread
        // poll kept running for hours after the user left Scheduled Tasks.
        // Coming back must show what happened meanwhile, including a run that
        // was queued in the store and finished while nobody polled.
        let f = try makePollFixture("hidden-poll")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let claim = try f.store.claimManual(taskID: f.task.id, now: Date(timeIntervalSince1970: 30), owner: "poll-test")
        let viewModel = ScheduledTasksViewModel(context: f.context, router: f.router, loadImmediately: false)
        defer { viewModel.setVisible(false) }
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.activeRunStatus(for: f.task.id), .queued)
        XCTAssertTrue(viewModel.isPollingActiveRunsForTesting, "an active run keeps its badge live while shown")

        viewModel.setVisible(false)
        XCTAssertFalse(viewModel.isPollingActiveRunsForTesting, "a detached host must not poll")
        viewModel.scheduleFreshnessPass() // a refresh that lands after leaving must not re-arm it
        await viewModel.waitForFreshnessForTesting()
        XCTAssertFalse(viewModel.isPollingActiveRunsForTesting)

        try f.store.finish(runID: claim.run.id, status: .failed, errorSummary: "boom", at: Date(timeIntervalSince1970: 40))
        viewModel.setVisible(true)
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertNil(viewModel.activeRunStatus(for: f.task.id),
                     "a store-confirmed Queued that finished while hidden must not stick as Queued")
        XCTAssertFalse(viewModel.isPollingActiveRunsForTesting, "nothing active, nothing to poll")

        _ = try f.store.claimManual(taskID: f.task.id, now: Date(timeIntervalSince1970: 50), owner: "poll-test")
        viewModel.setVisible(false)
        viewModel.setVisible(true)
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.activeRunStatus(for: f.task.id), .queued)
        XCTAssertTrue(viewModel.isPollingActiveRunsForTesting, "remount re-arms the poll after its one reload")
    }

    @MainActor
    func test_selectingAnotherTaskNeverPresentsThePreviousTasksHistory_becauseHistoryLoadsAfterTheFirstFrame() async throws {
        // WHY: selection is acknowledged first and history loads after a
        // committed frame; until then `runs` still holds the previous task's
        // rows, so the view must know whose rows they are.
        let f = try makePollFixture("select-history")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let other = ScheduledTask(
            title: "Other task", prompt: "Other prompt", workspaceID: f.task.workspaceID,
            workspacePathSnapshot: "/tmp", runAsUser: NSUserName(), runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC",
            createdAt: Date(timeIntervalSince1970: 20), updatedAt: Date(timeIntervalSince1970: 20)
        )
        try f.store.save(other)
        let claim = try f.store.claimManual(taskID: f.task.id, now: Date(timeIntervalSince1970: 30), owner: "select-test")
        try f.store.finish(runID: claim.run.id, status: .completed, at: Date(timeIntervalSince1970: 40))
        let viewModel = ScheduledTasksViewModel(context: f.context, router: f.router, loadImmediately: false)
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertNil(viewModel.runsTaskID, "the overview loads no history")

        viewModel.selectedTaskID = f.task.id
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.runsTaskID, f.task.id)
        XCTAssertEqual(viewModel.runs.map(\.id), [claim.run.id])

        viewModel.selectedTaskID = other.id
        XCTAssertNotEqual(viewModel.runsTaskID, other.id,
                          "before the deferred read, the held rows must not be attributed to the new task")
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.runsTaskID, other.id)
        XCTAssertEqual(viewModel.runs, [])
    }

    func test_historyListIsLazyAndGatedOnItsTask_becauseEagerRowsFormatEveryDate() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func runHistorySection("))
        let end = try XCTUnwrap(source.range(of: "private var historyHeaderRow"))
        let section = String(source[start.lowerBound..<end.lowerBound])
        // Up to 200 rows, each formatting 2-3 dates: only visible rows may build.
        XCTAssertTrue(section.contains("LazyVStack(spacing: 0)"))
        XCTAssertFalse(section.contains("                VStack(spacing: 0) {"))
        XCTAssertTrue(section.contains("if vm.runsTaskID != task.id"),
                      "another task's rows must never render under this task's header")
    }

    func test_mainWindowPausesScheduledTasksWhenItLeaves_becauseTheCachedModelWouldKeepPolling() throws {
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("if oldValue == .scheduledTasks, shellContentMode != .scheduledTasks {\n                scheduledTasksViewModel?.setVisible(false)"))
        XCTAssertTrue(main.contains("vm.setVisible(true)\n        vm.scheduleFreshnessPass()"),
                      "the remount marks the model visible before its one freshness reload")
    }

    @MainActor
    func test_backToOverviewClearsTheSelectionSoPollAndRemountReadNoHistory_becauseTheOverviewNeverShowsIt() async throws {
        // WHY: Back only switched the screen, so after any detail visit the
        // overview kept a selection and every active-row change and remount
        // freshness pass still decoded up to 200 history rows nobody sees.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func detailHeader("))
        let end = try XCTUnwrap(source.range(of: ".accessibilityIdentifier(\"scheduledTasks.back\")"))
        XCTAssertTrue(String(source[start.lowerBound..<end.lowerBound]).contains("vm.selectedTaskID = nil\n                screen = .overview"),
                      "Back must drop the selection, not only the screen")

        let f = try makePollFixture("back-poll")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let claim = try f.store.claimManual(taskID: f.task.id, now: Date(timeIntervalSince1970: 30), owner: "poll-test")
        let viewModel = ScheduledTasksViewModel(context: f.context, router: f.router, loadImmediately: false)
        defer { viewModel.setVisible(false) }
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        viewModel.selectedTaskID = f.task.id
        await viewModel.waitForFreshnessForTesting()
        let readsOnDetail = viewModel.runHistoryReadCountForTesting
        XCTAssertEqual(readsOnDetail, 1)

        viewModel.selectedTaskID = nil // what Back does
        await viewModel.waitForFreshnessForTesting()
        try f.store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID())
        viewModel.pollActiveRunsOnce()
        XCTAssertEqual(viewModel.activeRunStatus(for: f.task.id), .running, "overview badges still follow the store")
        viewModel.setVisible(false)
        viewModel.setVisible(true)
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.runHistoryReadCountForTesting, readsOnDetail,
                       "after Back, neither the poll nor a remount may read history")

        viewModel.selectedTaskID = f.task.id
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.runHistoryReadCountForTesting, readsOnDetail + 1, "reopening the detail reads it once")
        XCTAssertEqual(viewModel.runsTaskID, f.task.id)
        XCTAssertEqual(viewModel.runs.first { $0.id == claim.run.id }?.status, .running)
    }

    func test_runningRowDurationRunsOnItsOwnClock_becauseHeartbeatPollsNoLongerRepublishHistory() throws {
        // WHY: a running row's elapsed time is computed at render time. Since
        // heartbeat-only polls stopped republishing `runs`, nothing re-rendered
        // the detail during a run, so Duration froze at "0s" while looking live.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func historyRowPrimaryContent("))
        let end = try XCTUnwrap(source.range(of: "private func agentTaskTitle("))
        let row = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(row.contains("if run.status == .running {\n                    TimelineView(.periodic(from: .now, by: 1)) { timeline in\n                        Text(durationLabel(run, now: timeline.date))"))
        XCTAssertTrue(source.contains("private func durationLabel(_ run: ScheduledTaskRun, now: Date) -> String {"))
        XCTAssertTrue(source.contains("let s = Int(now.timeIntervalSince(started))"),
                      "the running label must use the timeline's date, not a fresh Date() frozen at the last render")
    }

    func test_scopedTaskAndRunRefreshesKeepLatestWinsAndFailureVisible() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        for marker in [
            "guard !Task.isCancelled,\n                  self.tasksRefreshGeneration == generation else { return }",
            "guard !Task.isCancelled,\n                  self.runsRefreshGeneration == generation else { return }",
            "self.reloadTasks()",
            "self.reloadRuns()",
            "errorMessage = String(describing: error)"
        ] {
            XCTAssertTrue(source.contains(marker), "scoped refresh contract missing: \(marker)")
        }
        XCTAssertTrue(source.contains("self.selectedTaskID = nil"),
                      "a stale selection must clear when the winning task projection no longer contains it")
        XCTAssertTrue(source.contains("activeRunStatuses = next"),
                      "exact run status results must republish the overview badge state")
    }

    func test_scheduledExecutionUsesHeadlessSendPath_becauseSchedulesMustNotStealFocus() throws {
        let runtime = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)
        let main = try String(contentsOf: sourceURL("Sources/AppShell/AppDelegate.swift"), encoding: .utf8)
        let router = try String(contentsOf: sourceURL("Sources/AppShell/AppCommandRouter.swift"), encoding: .utf8)
        // Headless in-process: createAgentThread(surfaceID: nil) + sendAgentMessage.
        // Main app owns the scheduler; legacy LaunchAgent is unregistered.
        // openAgentAppForSchedule remains for intentional focus deep-links only.
        XCTAssertTrue(runtime.contains("router.createAgentThread("))
        XCTAssertTrue(runtime.contains("router.sendAgentMessage("))
        XCTAssertTrue(runtime.contains("surfaceID: nil"))
        XCTAssertTrue(runtime.contains("func stop(threadID:"))
        XCTAssertTrue(runtime.contains("ScheduledTaskCrossProcess.notifyStoreChanged"))
        XCTAssertTrue(runtime.contains("skipMissedOccurrencesOnLaunch"))
        XCTAssertTrue(main.contains("startInProcessScheduledTaskScheduler"))
        XCTAssertTrue(main.contains("installScheduledTaskStoreObserver"))
        XCTAssertTrue(router.contains("openAgentAppForSchedule"))
        XCTAssertTrue(router.contains("scheduledTaskScheduler"))
        XCTAssertFalse(runtime.contains("openAgentAppForSchedule"))
        XCTAssertFalse(runtime.contains("await vm.send()"))
        XCTAssertFalse(
            runtime.contains("context.coordinator.startRun("),
            "scheduled execute must start via sendAgentMessage, not a raw coordinator call"
        )
    }

    func test_rootViewUsesDesignSystemSurfaces_becauseScheduledTasksMustMatchLatestRemoteCodeChrome() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("DSPrimaryButtonStyle()"))
        XCTAssertTrue(source.contains("DSSecondaryButtonStyle()"))
        XCTAssertTrue(source.contains("DSPill("))
        XCTAssertTrue(source.contains("DSEmptyState("))
        XCTAssertTrue(source.contains("dsPanel("))
        XCTAssertTrue(source.contains("serviceRequiresApproval"))
        XCTAssertTrue(source.contains("Runs inside MacCode while the app is open"))
        // Plan-faithful chrome: full-width card list + full-page editor groups.
        XCTAssertTrue(source.contains("ScheduledTaskCard("))
        XCTAssertTrue(source.contains("Automate recurring agent work"))
        XCTAssertTrue(source.contains("editorGroup(\"Details\")"))
        XCTAssertTrue(source.contains("editorGroup(\"Frequency\")"))
        XCTAssertTrue(source.contains("Run History"))
        XCTAssertTrue(source.contains("Save Task"))
        XCTAssertFalse(source.contains("HSplitView"),
                       "plan mockups use a single-column stack, not master-detail split")
        XCTAssertFalse(source.contains("Open Login Items"),
                       "Login Items approval is retired with LaunchAgent Path B")
    }

    func test_overviewExposesGlobalActiveToggle_becauseTravelPauseMustStopAllSchedules() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        let runtime = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)
        let settings = try String(contentsOf: sourceURL("Sources/Persistence/SettingsStore.swift"), encoding: .utf8)
        // WHY: users need one switch to pause every automatic occurrence (e.g. travel)
        // without deleting or individually pausing each task.
        XCTAssertTrue(source.contains("scheduledTasks.globalActive"))
        XCTAssertTrue(source.contains("setSchedulerActive"))
        XCTAssertTrue(source.contains("schedulerActive"))
        XCTAssertTrue(source.contains("schedulerActiveControl"))
        XCTAssertTrue(source.contains("AgentKillSwitchControl("))
        // UX: state is not color-only — icon + Active/Paused label + switch.
        // Paint lives on AgentKillSwitchControl; this window only mounts it.
        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentListChrome.swift"), encoding: .utf8)
        XCTAssertTrue(chrome.contains("bolt.fill"))
        XCTAssertTrue(chrome.contains("pause.fill"))
        XCTAssertTrue(chrome.contains("\"Paused\""))
        XCTAssertTrue(chrome.contains("Travel pause"))
        XCTAssertTrue(settings.contains("scheduledTasksActive"))
        XCTAssertTrue(runtime.contains("scheduledTasksActive"))
        XCTAssertTrue(runtime.contains("global_active=false")
                      || runtime.contains("settings.scheduledTasksActive"))
        // Layout: Active control sits to the right of New Task.
        let newTask = try XCTUnwrap(source.range(of: "scheduledTasks.new"))
        let globalActive = try XCTUnwrap(source.range(of: "scheduledTasks.globalActive"))
        XCTAssertLessThan(newTask.lowerBound, globalActive.lowerBound,
                          "Active toggle must appear after New Task in the overview header")
        // Footer uses status pill (icon+text), not a color-only dot.
        XCTAssertTrue(source.contains("Scheduler paused"))
        XCTAssertTrue(source.contains("DSPill("))
    }

    func test_editorKeepsProviderPickersWithAuto_becauseAutoOnlySelectsModel() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("scheduledTasks.editor.autoRouting"))
        XCTAssertTrue(source.contains("scheduledTasks.editor.provider"))
        // Agent App parity: one Provider/Source picker only — no account row.
        XCTAssertFalse(source.contains("scheduledTasks.editor.providerAccount"))
        XCTAssertFalse(source.contains("formRow(\"Provider account\")"))
        XCTAssertTrue(source.contains("if draft.routingMode == .auto"))
        // Auto must never claim it picks the provider — only the model for the chosen Source.
        XCTAssertTrue(source.contains("Auto selects the best model for the selected provider at run time."))
        XCTAssertFalse(source.contains("Auto selects the best available provider and model at run time."))
        XCTAssertTrue(source.contains("ProgressView()"))
        // Provider pickers live outside the Auto-only branch so they stay visible.
        let providerPicker = try XCTUnwrap(source.range(of: "scheduledTasks.editor.provider"))
        let autoBranch = try XCTUnwrap(source.range(of: "if draft.routingMode == .auto"))
        XCTAssertLessThan(providerPicker.lowerBound, autoBranch.lowerBound,
                          "Provider picker must render before the Auto-only model branch")
        // Labels must keep the chosen Source when Auto is on (not "Provider: Auto").
        XCTAssertTrue(source.contains("\\(host) · Auto"))
        XCTAssertTrue(source.contains("\\(task.provider.rawValue.capitalized) · Auto"))
        // Auto → Manual must restore model from the selected provider instance.
        XCTAssertTrue(source.contains("$0.id == draft.providerInstanceID && $0.provider == draft.provider"))
        XCTAssertFalse(source.contains("vm.providers.first(where: { $0.enabled && $0.installed }) ?? vm.providers.first"))
    }

    func test_mainUnregistersLegacyScheduledAgent_becauseSchedulesRunInProcess() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/Main.swift"), encoding: .utf8)
        // WHY: leftover LaunchAgent installs must not dual-claim after upgrade.
        XCTAssertTrue(source.contains("--scheduled-task-agent"))
        XCTAssertTrue(source.contains("ScheduledTaskAgentServiceManager().unregister()"))
        XCTAssertTrue(source.contains("background agent unregistered"))
        XCTAssertFalse(source.contains("ScheduledTaskAgentAppDelegate("))
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative)
    }
}

private extension ScheduledTask {
    var permissionModeForScheduledExecution: AgentPermissionMode { .fullAccess }
}

extension ScheduledTasksWindowTests {
    func test_draftWithTwoFrequenciesBuildsMultipleAndRestores_becauseEditingMustNotDropRules() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var draft = ScheduledTaskEditorDraft(now: now)
        draft.title = "Audit"
        draft.prompt = "Inspect"
        draft.workspaceID = WorkspaceID()
        draft.workspacePathSnapshot = "/tmp"
        draft.runAsUser = NSUserName()
        draft.runAsUID = ScheduledSystemUserCatalog.user(named: NSUserName())?.uid ?? 501
        draft.providerInstanceID = "codex"
        draft.model = "gpt-5"
        draft.timeZoneIdentifier = "UTC"
        let early = ScheduledFrequencyRule(frequency: .daily, localTimeHour: 10, localTimeMinute: 10)
        let late = ScheduledFrequencyRule(frequency: .daily, localTimeHour: 13, localTimeMinute: 10)
        draft.frequencyRules = [late, early]

        let task = try draft.makeTask(now: now)

        XCTAssertEqual(task.recurrence, .multiple([
            .daily(at: ScheduledLocalTime(hour: 13, minute: 10)!),
            .daily(at: ScheduledLocalTime(hour: 10, minute: 10)!),
        ]))
        let expected = try XCTUnwrap(ScheduledTaskOccurrenceCalculator.nextOccurrence(
            after: now.addingTimeInterval(-0.001),
            recurrence: .daily(at: ScheduledLocalTime(hour: 10, minute: 10)!),
            timeZone: TimeZone(identifier: "UTC")!,
            calendar: Calendar(identifier: .gregorian)
        ))
        let lateNext = try XCTUnwrap(ScheduledTaskOccurrenceCalculator.nextOccurrence(
            after: now.addingTimeInterval(-0.001),
            recurrence: .daily(at: ScheduledLocalTime(hour: 13, minute: 10)!),
            timeZone: TimeZone(identifier: "UTC")!,
            calendar: Calendar(identifier: .gregorian)
        ))
        XCTAssertEqual(task.nextRunAt, min(expected, lateNext))

        let restored = ScheduledTaskEditorDraft(task: task, now: now)
        XCTAssertEqual(restored.frequencyRules.map(\.localTimeHour), [13, 10])
    }

    func test_multipleFrequencySummaryGroupsTimesByPattern_becauseCardsTruncateRepeatedDayLists() throws {
        // WHY: "Weekly Mon, Fri at 10:10 AM · Weekly Mon, Fri at 1:10 PM" truncated on the
        // overview card before the second time was visible.
        let days: [ScheduledWeekday] = [.monday, .friday]
        let recurrence = ScheduledTaskRecurrence.multiple([
            .weekly(on: days, at: ScheduledLocalTime(hour: 10, minute: 10)!),
            .weekly(on: days, at: ScheduledLocalTime(hour: 13, minute: 10)!),
            .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 2),
        ])
        let first = ScheduledTaskRecurrence.weekly(on: days, at: ScheduledLocalTime(hour: 10, minute: 10)!).detailSummary
        let second = ScheduledTaskRecurrence.weekly(on: days, at: ScheduledLocalTime(hour: 13, minute: 10)!).detailSummary
        let secondTime = try XCTUnwrap(second.components(separatedBy: " at ").last)

        XCTAssertEqual(recurrence.detailSummary, "\(first), \(secondTime) · Every 2 hours")
        XCTAssertEqual(recurrence.summaryLabel, "Multiple")
    }

    @MainActor
    func test_toggleFlipsRowImmediatelyAndRevertsOnFailure_becauseTheUserMustSeeTheChangeAndTheTruthOnError() async throws {
        // WHY: enabling runs an async preflight; the row must flip at once and
        // roll back with a visible error when the preflight fails.
        let directory = NSTemporaryDirectory() + "rc-scheduled-toggle-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let store = ScheduledTaskStore(db: context.db)
        let task = ScheduledTask(
            title: "Toggle task", prompt: "Toggle prompt", workspaceID: WorkspaceID(),
            workspacePathSnapshot: "/tmp", runAsUser: NSUserName(), runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC", isEnabled: false,
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        try store.save(task)

        let viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.tasks.first { $0.id == task.id }?.isEnabled, false)

        viewModel.toggle(task)
        XCTAssertEqual(viewModel.tasks.first { $0.id == task.id }?.isEnabled, true,
                       "enable must show on the row before the preflight completes")

        for _ in 0..<200 where viewModel.errorMessage == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(viewModel.errorMessage, "a failed preflight must surface an error")
        XCTAssertEqual(viewModel.tasks.first { $0.id == task.id }?.isEnabled, false,
                       "a failed enable must revert the row to Paused")
        XCTAssertEqual(try store.list().first { $0.id == task.id }?.isEnabled, false,
                       "a failed enable must not persist")
    }

    @MainActor
    func test_deleteRemovesRowImmediatelyAndRestoresItOnFailure_becauseAFailedWriteMustNotHideAScheduleSilently() async throws {
        let directory = NSTemporaryDirectory() + "rc-scheduled-delete-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let store = ScheduledTaskStore(db: context.db)
        let first = ScheduledTask(
            title: "First", prompt: "p", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: NSUserName(), runAsUID: 501, provider: .codex, providerInstanceID: "codex",
            model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC", createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        let second = ScheduledTask(
            title: "Second", prompt: "p", workspaceID: first.workspaceID, workspacePathSnapshot: "/tmp",
            runAsUser: NSUserName(), runAsUID: 501, provider: .codex, providerInstanceID: "codex",
            model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC", createdAt: Date(timeIntervalSince1970: 20), updatedAt: Date(timeIntervalSince1970: 20)
        )
        try store.save(first)
        try store.save(second)

        let viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        let before = viewModel.tasks
        XCTAssertEqual(before.count, 2)

        viewModel.performDelete(first)
        XCTAssertEqual(viewModel.tasks.map(\.id), [second.id],
                       "the deleted row must leave the list before the write returns")
        XCTAssertEqual(try store.list().map(\.id), [second.id], "the delete must persist")

        try context.db.execute("DROP TABLE scheduled_tasks")
        viewModel.performDelete(second)
        XCTAssertEqual(viewModel.tasks.map(\.id), [second.id],
                       "a failed delete must restore the row at its position")
        XCTAssertNotNil(viewModel.errorMessage, "a failed delete must remain visible to the user")
    }

    @MainActor
    func test_activeRunPhaseIsReportedToTheCard_becauseAQueuedRunMustNotLookIdle() throws {
        let directory = NSTemporaryDirectory() + "rc-scheduled-phase-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let store = ScheduledTaskStore(db: context.db)
        let task = ScheduledTask(
            title: "Phase task", prompt: "p", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: NSUserName(), runAsUID: 501, provider: .codex, providerInstanceID: "codex",
            model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC", createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        try store.save(task)
        _ = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 30), owner: "phase-test")

        let viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        ScheduledTaskRunPhases.set("Checking provider…", taskID: task.id)
        defer { ScheduledTaskRunPhases.clear(taskID: task.id) }
        viewModel.pollActiveRunsOnce()
        XCTAssertEqual(viewModel.activeRunStatus(for: task.id), .queued)
        XCTAssertEqual(viewModel.activeRunPhase(for: task.id), "Checking provider…")

        ScheduledTaskRunPhases.set("Starting…", taskID: task.id)
        viewModel.pollActiveRunsOnce()
        XCTAssertEqual(viewModel.activeRunPhase(for: task.id), "Starting…")

        ScheduledTaskRunPhases.clear(taskID: task.id)
        viewModel.pollActiveRunsOnce()
        XCTAssertNil(viewModel.activeRunPhase(for: task.id), "a cleared phase must not stick to the card")
    }
}
