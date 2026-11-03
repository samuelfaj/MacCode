import XCTest
import AppKit

@testable import AppShell
@testable import CoreModel
@testable import Persistence
@testable import Surfaces

final class SidebarViewTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func test_shellInstallersMountBeforeFreshnessPass() throws {
        let main = try source("Sources/AppShell/MainWindowController.swift")
        for method in ["installScheduledTasksContent", "installActiveThreadsContent", "installBotsContent"] {
            let start = try XCTUnwrap(main.range(of: "private func \(method)"))
            let tail = main[start.upperBound...]
            let end = tail.range(of: "\n    private func")?.lowerBound ?? tail.endIndex
            let body = String(tail[..<end])
            XCTAssertTrue(body.contains("scheduleFreshnessPass") || body.contains("enableNavigationFirstFrameDeferral"), method)
            XCTAssertFalse(body.contains("vm.reload()"), "\(method) must not hydrate synchronously")
        }
        XCTAssertTrue(main.contains("currentShellHostingView"))
        XCTAssertTrue(main.contains("removePreviousShellHostAfterFirstFrame"))
        XCTAssertTrue(main.contains("cachedWorkspaceContentViews.forEach { $0.isHidden = true }"))
    }

    func test_workspaceExitUsesCachedContentAndDeferredRebuild() throws {
        let main = try source("Sources/AppShell/MainWindowController.swift")
        let start = try XCTUnwrap(main.range(of: "func presentWorkspaceContent()"))
        let body = main[start.lowerBound...]
        XCTAssertTrue(body.contains("cachedWorkspaceContentViews"))
        XCTAssertTrue(body.contains("scheduleWorkspaceRebuild()"))
    }

    func test_sameShellDestinationIsIdempotent() throws {
        let main = try source("Sources/AppShell/MainWindowController.swift")
        XCTAssertTrue(main.contains("guard shellContentMode != .scheduledTasks"))
        XCTAssertTrue(main.contains("guard shellContentMode != .activeThreads"))
        XCTAssertTrue(main.contains("scheduledTasksViewModel?.scheduleFreshnessPass()"))
        XCTAssertTrue(main.contains("activeThreadsViewModel?.scheduleFreshnessPass()"))
    }

    func test_destinationPersistenceIsDeferredForVisibleShell() throws {
        let main = try source("Sources/AppShell/MainWindowController.swift")
        let start = try XCTUnwrap(main.range(of: "private func persistBotsShellDestination()"))
        let tail = main[start.upperBound...]
        let end = tail.range(of: "\n    private func")?.lowerBound ?? tail.endIndex
        let body = String(tail[..<end])
        XCTAssertTrue(body.contains("destinationPersistenceTask"))
        XCTAssertTrue(body.contains("waitForCommittedFrame"))
        XCTAssertTrue(body.contains("window.isVisible"))
    }

    func test_restoreDestinationUsesDeferredDestinationVM() throws {
        let main = try source("Sources/AppShell/MainWindowController.swift")
        XCTAssertTrue(main.contains("restoreBotsShellDestinationIfNeeded()"))
        XCTAssertTrue(main.contains("scheduleFreshnessPass()"))
    }

    func test_workspaceSelectionDefersSurfaceReconciliation() throws {
        let router = try source("Sources/AppShell/AppCommandRouter.swift")
        let start = try XCTUnwrap(router.range(of: "public func selectWorkspace(_ id: WorkspaceID)"))
        let tail = router[start.upperBound...]
        let end = tail.range(of: "\n    public func")?.lowerBound ?? tail.endIndex
        let body = String(tail[..<end])
        XCTAssertTrue(body.contains("DispatchQueue.main.async"))
        XCTAssertTrue(body.contains("reconcileSurfaceVisibility()"))
        XCTAssertTrue(body.contains("repairSelectedTerminalFocus"))
    }

    func test_workspaceBotsBoundaryMountsWithoutAnimation() throws {
        let sidebar = try source("Sources/AppShell/SidebarView.swift")
        XCTAssertFalse(sidebar.contains("BotsRosterList("), "the unified sidebar mounts no Bots roster, so there is no content boundary to animate")
        XCTAssertFalse(
            sidebar.contains(".animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.isBotsSelected)"),
            "the Workspaces/Bots boundary must not animate for 200ms"
        )
        let bots = try source("Sources/AppShell/BotsWindow.swift")
        XCTAssertTrue(bots.contains("publishedRoster"))
        XCTAssertTrue(bots.contains("waitForCommittedFrame"))
    }
}

@MainActor
final class WorkspaceRebuildSchedulingTests: XCTestCase {
    private var retainedControllers: [MainWindowController] = []

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    override func tearDown() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        retainedControllers.removeAll()
        super.tearDown()
    }

    func test_presentBotsReusesHostingViewAcrossWorkspaceReturn() throws {
        let directory = NSTemporaryDirectory() + "RC2BotsHostReuse-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        retainedControllers.append(controller)

        controller.presentBotsInMainContent()
        let first = controller.botsHostingViewForTesting
        XCTAssertNotNil(first, "first Bots present must mount a host")
        controller.presentWorkspaceContent()
        XCTAssertTrue(
            first === controller.botsHostingViewForTesting,
            "leaving Bots must retain the host off-tree"
        )
        XCTAssertNil(first?.superview, "retained Bots host must not stay in workspaceContent")
        controller.presentBotsInMainContent()
        XCTAssertTrue(
            first === controller.botsHostingViewForTesting,
            "returning to Bots must reattach the same NSHostingView"
        )
        XCTAssertNotNil(first?.superview, "reattached Bots host must be in the window")
    }

    /// WHY: a refresh can win after the workspace return has queued its
    /// deferred rebuild. The winning refresh must reconcile/build the exact
    /// selected workspace once; the older task must not remove that newly
    /// mounted cache before its fingerprint check can make the pass a no-op.
    func test_refreshWinningBeforeDeferredWorkspaceRebuildPreservesMountedCache() throws {
        let directory = NSTemporaryDirectory() + "RC2WorkspaceRebuildRace-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let first = try router.createWorkspace(name: "first", cwd: NSTemporaryDirectory())
        let firstSurface = try router.createSurface(
            workspace: first.id,
            type: .browser,
            paneID: nil,
            title: "cached"
        )
        let second = try router.createWorkspace(name: "second", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        retainedControllers.append(controller)
        controller.flushPendingRefresh()

        // Establish a cached workspace tree, then enter Bots so the return
        // path queues a workspace rebuild instead of rebuilding synchronously.
        try router.selectWorkspace(second.id)
        controller.flushPendingRefresh()
        controller.presentBotsInMainContent()

        let before = controller.rebuildCount
        try router.selectWorkspace(first.id) // queues refreshFromState first
        controller.presentWorkspaceContent() // queues the deferred rebuild second
        controller.flushPendingRefresh() // force the refresh winner before Task.yield()
        drainMainQueue()

        XCTAssertEqual(
            controller.rebuildCount,
            before + 1,
            "the refresh winner and deferred workspace task must share one structural rebuild"
        )
        guard let surfaceView = SurfaceRegistry.shared.surface(firstSurface.id)?.view,
              let contentView = controller.window.contentView else {
            XCTFail("expected the selected workspace surface to remain mounted")
            return
        }
        XCTAssertTrue(
            allSubviews(of: contentView).contains { $0 === surfaceView },
            "the owner-only deferred task must not remove the cache mounted by the winning refresh"
        )
    }
}

extension ActiveThreadsWindowTests {
    func test_activeThreadsUsesDeferredFreshnessPass() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ActivityWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".onAppear {") && source.contains("else { model.refreshAfterFrame() }"),
                      "ActivityRootView owns its deferred initial refresh")
        XCTAssertTrue(source.contains("if !applyingInitialTabChoice { refreshAfterFrame() }"),
                      "tab changes must refresh the selected Activity section after acknowledgement")
        XCTAssertTrue(source.contains("func refreshAfterFrame()"))
        XCTAssertTrue(source.contains("Self.listParams(tab: self.tab"),
                      "refresh must request the currently selected Activity section")
    }

    func test_activeThreadsTabSwitchUsesScopedDeferredRefresh_becauseOnlyVisibleProjectionNeedsHydration() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ActivityWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("var tab: Tab { didSet"),
                      "tab choice must publish before its freshness request")
        XCTAssertTrue(source.contains("if !applyingInitialTabChoice { refreshAfterFrame() }"))
        XCTAssertTrue(source.contains("func refreshAfterFrame()"))
        XCTAssertTrue(source.contains("Self.listParams(tab: self.tab"),
                      "freshness must request the currently selected Activity section")
    }

    func test_activeThreadOpenDefersExactRoute() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ActiveThreadsWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("router.windowController?.presentWorkspaceContent()"))
        XCTAssertTrue(source.contains("waitForCommittedFrame"))
        XCTAssertTrue(source.contains("openAgentThread(thread: threadID"))
    }
}

extension ScheduledTasksWindowTests {
    @MainActor
    func test_internalSelectionClearDoesNotRequeueOwningHydration() async throws {
        let directory = NSTemporaryDirectory() + "rc-scheduled-navigation-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let task = ScheduledTask(
            title: "Active target", prompt: "Run", workspaceID: WorkspaceID(),
            workspacePathSnapshot: "/tmp", runAsUser: NSUserName(), runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC"
        )
        try ScheduledTaskStore(db: context.db).save(task)
        let viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        let beforeFilter = viewModel.fullHydrationCountForTesting
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        viewModel.selectedTaskID = task.id
        await viewModel.waitForFreshnessForTesting()
        let beforeScopedSearch = viewModel.fullHydrationCountForTesting

        viewModel.searchText = "does-not-match"
        await viewModel.waitForFreshnessForTesting()

        XCTAssertEqual(viewModel.selectedTaskID, task.id, "a task hidden by search keeps its selection")
        XCTAssertEqual(viewModel.fullHydrationCountForTesting, beforeScopedSearch,
                       "search changes use the scoped task projection and must not re-run full overview hydration")

        try ScheduledTaskStore(db: context.db).delete(id: task.id)
        viewModel.searchText = ""
        await viewModel.waitForFreshnessForTesting()

        XCTAssertNil(viewModel.selectedTaskID, "a deleted task clears the selection")
        XCTAssertEqual(viewModel.fullHydrationCountForTesting, beforeFilter + 1)
    }

    func test_scheduledTasksCoalescesDeferredFreshnessByGeneration() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ScheduledTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("loadImmediately: Bool = true"))
        XCTAssertTrue(source.contains("public func scheduleFreshnessPass()"))
        XCTAssertTrue(source.contains(".onAppear { vm.scheduleFreshnessPass() }"))
        XCTAssertTrue(source.contains("freshnessTask?.cancel()"))
        XCTAssertTrue(source.contains("freshnessGeneration &+= 1"))
        XCTAssertTrue(source.contains("waitForCommittedFrame"))
        XCTAssertTrue(source.contains("defer { self.finishFreshnessTask(ownedBy: generation) }"))
        XCTAssertTrue(source.contains("guard freshnessGeneration == generation else { return }"))
    }

    func test_scheduledTaskSelectionDefersRunHistory() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ScheduledTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("guard !suppressSelectedTaskReload else { return }"))
        XCTAssertTrue(source.contains("reloadRunsOrDefer()"))
        XCTAssertTrue(source.contains("statusFilter: ScheduledTaskStatusFilter = .all { didSet { reloadTasksOrDefer() } }"))
    }

    func test_scheduledTaskFilterDefersHydration() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ScheduledTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("private func reloadTasksOrDefer()"))
        XCTAssertTrue(source.contains("if deferHydration { scheduleTasksRefreshPass() }"))
    }

    func test_scheduledTaskFilterUsesScopedProjectionWithoutOverviewHydration() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ScheduledTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("if deferHydration { scheduleTasksRefreshPass() }"))
        XCTAssertFalse(source.contains("if deferHydration { scheduleFreshnessPass() } else { reloadTasks() }"))
    }

    func test_scheduledHistoryOpenDefersExactRoute() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ScheduledTasksWindow.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func openThread(_ run: ScheduledTaskRun)"))
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    public func providerSnapshots"))
        let body = String(tail[..<end.lowerBound])
        XCTAssertTrue(body.contains("router.windowController?.presentWorkspaceContent()"))
        XCTAssertTrue(body.contains("navigationTask?.cancel()"))
        XCTAssertTrue(body.contains("navigationGeneration &+= 1"))
        XCTAssertTrue(body.contains("waitForCommittedFrame"))
        XCTAssertTrue(body.contains("openAgentThread(thread: threadID, markRead: true)"))
        XCTAssertTrue(body.contains("defer { self.finishNavigationTask(ownedBy: generation) }"))
        XCTAssertTrue(source.contains("guard navigationGeneration == generation else { return }"))
    }

    func test_scheduledTasksFallbackDoesNotReloadInShow() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ScheduledTasksWindow.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public final class ScheduledTasksWindowController"))
        let body = source[start.lowerBound...]
        XCTAssertTrue(body.contains("loadImmediately: false"))
        XCTAssertTrue(body.contains("showWindow(nil)"))
        XCTAssertFalse(body.contains("viewModel.reload()"))
    }
}

extension BotsWindowTests {
    func test_botsScreenBoundaryMountsWithoutAnimation() throws {
        let bots = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(bots.range(of: "switch vm.screen.resolvedDestination"))
        let tail = bots[start.upperBound...]
        let end = tail.range(of: "\n        }\n        .frame(maxWidth:")?.lowerBound ?? tail.endIndex
        let boundary = String(tail[..<end])
        XCTAssertFalse(boundary.contains(".transition("), "Bots screen navigation must mount without a transition")
        XCTAssertFalse(
            bots.contains(".animation(DS.Motion.standard, value: vm.screen.resolvedDestination)"),
            "Bots screen navigation must not animate for the first frame"
        )
    }

    func test_botsShellInstallEnablesCacheFirstNavigation() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/MainWindowController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("vm.enableNavigationFirstFrameDeferral()"))
        XCTAssertTrue(source.contains("BotsRootView(vm: vm)"))
        XCTAssertTrue(source.contains("removePreviousShellHostAfterFirstFrame"))
    }

    func test_cacheFirstBotSelectionNeverShowsAnotherBotsData() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("private func openDeskFromCache"))
        XCTAssertTrue(source.contains("cachedMessages(botID:"))
        XCTAssertTrue(source.contains("applyStudioSupport(snapshot, prefetchRail: false)"))
        XCTAssertTrue(source.contains("allowStoreLookup: false"))
        let guardStart = try XCTUnwrap(source.range(of: "private func navigationFreshnessIsCurrent("))
        let guardTail = source[guardStart.lowerBound...]
        let guardEnd = try XCTUnwrap(guardTail.range(of: "\n    private func performDeskFreshness"))
        let guardBody = String(guardTail[..<guardEnd.lowerBound])
        XCTAssertTrue(guardBody.contains("navigationFreshnessGeneration == generation"))
        XCTAssertTrue(guardBody.contains("selectedBotID == botID"))
        XCTAssertTrue(guardBody.contains("screen.resolvedDestination == .desk"))
    }

    func test_cacheFirstThreadSelectionClearsPreviousData() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("deskWorkLog = []"))
        XCTAssertTrue(source.contains("messagesByConversation"))
        XCTAssertTrue(source.contains("allowStoreLookup: !navigationFirstFrameDeferral"))
        XCTAssertTrue(source.contains(".thread(botID: conversation.botID, conversationID: conversation.id)"))
        XCTAssertTrue(source.contains("selectedConversation?.id == conversationID"))
    }

    func test_botsFallbackDoesNotReloadInShow() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func show()"))
        let tail = source[start.upperBound...]
        let end = tail.range(of: "\n    }\n")?.lowerBound ?? tail.endIndex
        XCTAssertFalse(String(tail[..<end]).contains("viewModel.reload()"))
    }

    func test_detachedBotWindowsDoNotReloadInShow() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("class BotDeskWindowController"))
        XCTAssertTrue(source.contains("class BotGuestDesktopWindowController"))
        XCTAssertTrue(source.contains("self.viewModel = vm"))
        XCTAssertFalse(source.contains("viewModel.reload()\n        if let bot = viewModel.selectedBot"))
        XCTAssertTrue(source.contains("loadImmediately: false"))
        XCTAssertTrue(source.contains("vm.enableNavigationFirstFrameDeferral()"))
        XCTAssertEqual(source.components(separatedBy: "vm.prepareDetachedDesk(botID: botID)").count - 1, 2)
        XCTAssertTrue(source.contains("detachedDeskBotID = botID"))
        XCTAssertTrue(source.contains("scheduleNavigationFreshness(.desk(botID: botID, reloadFirst: true))"))
        let effectsStart = try XCTUnwrap(source.range(of: "private func performDeskFreshness("))
        let effectsTail = source[effectsStart.lowerBound...]
        let effectsEnd = try XCTUnwrap(effectsTail.range(of: "\n    public func createDeskThread"))
        let effects = String(effectsTail[..<effectsEnd.lowerBound])
        XCTAssertTrue(effects.contains("navigationFreshnessIsCurrent(generation, botID: botID)"))
        XCTAssertTrue(effects.contains("markOpenedConversationRead(botID: botID)"))
        XCTAssertTrue(effects.contains("reloadSelectedBot(id: botID)"))
        XCTAssertTrue(effects.contains("syncQueuedFollowUps()"))
        XCTAssertTrue(effects.contains("drainQueuedFollowUp()"))
        XCTAssertTrue(effects.contains("deskTimelineRejoinToken &+= 1"))
        XCTAssertTrue(effects.contains("presentGuestDesktop(botID: botID)"))
        XCTAssertTrue(source.contains(".onAppear { vm.scheduleFreshnessPass() }"))
    }
}
