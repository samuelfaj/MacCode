import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel
@testable import Surfaces
import Persistence

/// WHY: Bots / Schedule Tasks / Active Threads mount into the shell's main
/// content column (`MainWindowController.shellContentMode`) and hide the
/// selected workspace's panes without tearing their controllers down --
/// `rebuildWorkspaceContainer()` early-returns while a destination owns the
/// shell, so `paneControllers` keeps pointing at the off-screen workspace.
///
/// `AppDelegate` routes ⌘W / ⌘D straight into `closeFocusedSurface()`,
/// `splitFocusedPane(_:)` and `resizeFocusedPane(_:)`, and those three used to
/// resolve their target from `selectedWorkspaceID` alone. With another
/// destination on screen the keyboard therefore acted on the workspace the
/// user cannot see:
///   - ⌘W closed a hidden tab. That path is destructive, not cosmetic:
///     `AppCommandRouter.closeSurfaces` calls
///     `permanentlyCloseRuntimeSurface`, which unregisters the surface and
///     runs `closeAndDeletePersistedHistory()` on terminal/SSH surfaces. The
///     scrollback is gone and nothing on screen explains why.
///   - ⌘D split or resized a hidden pane, so returning to the workspace showed
///     a layout the user never asked for.
///
/// These methods are documented fall-throughs (returning `false` means "no
/// target"), which is what lets ⌘W fall back to closing the window and ⌘D beep
/// instead of touching an off-screen pane.
@MainActor
final class ShellDestinationKeyboardTargetTests: XCTestCase {
    private var retainedControllers: [MainWindowController] = []

    override func tearDown() {
        for window in Array(NSApplication.shared.windows) {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            if let parent = window.sheetParent { parent.endSheet(window) }
        }
        for window in Array(NSApplication.shared.windows) { window.orderOut(nil) }
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        retainedControllers.removeAll()
        super.tearDown()
    }

    private func makeController(prefix: String) throws -> (AppContext, AppCommandRouter, MainWindowController) {
        let dir = NSTemporaryDirectory() + "RC2ShellDestinationKeys-\(prefix)-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let wc = MainWindowController(context: ctx, router: router)
        router.windowController = wc
        retainedControllers.append(wc)
        wc.window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)
        return (ctx, router, wc)
    }

    private func drainMainQueue(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    /// Non-vacuity guard: the keyboard entry points can only reach the bug if
    /// the workspace panes are actually mounted -- they return `false` for an
    /// empty `paneControllers` list too, so a green "before" leg without this
    /// check would prove nothing. `PaneTabsView` is an `NSObject` that owns an
    /// `NSView`, so the mounted pane is observed through the overflow button it
    /// installs (accessibility id `pane.overflowMenu`).
    private func assertWorkspacePanesAreMounted(_ wc: MainWindowController, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(wc.window.contentView, file: file, line: line)
        XCTAssertFalse(
            allSubviews(of: content).filter { $0.accessibilityIdentifier() == "pane.overflowMenu" }.isEmpty,
            "precondition: the workspace panes must be mounted before a shell destination takes over, otherwise the keyboard target bug cannot be reached",
            file: file, line: line
        )
    }

    private func surfaceIDs(in workspace: Workspace) -> [SurfaceID] {
        workspace.layout.paneIDs().flatMap { workspace.layout.find(paneID: $0)?.surfaces.map(\.id) ?? [] }
    }

    private func rootSplitRatios(in workspace: Workspace) -> [Double]? {
        guard case .split(let split) = workspace.layout else { return nil }
        return split.ratios
    }

    func test_activityOpenTerminal_leavesActivity_becauseTheFocusedTerminalWasHiddenBehindIt() throws {
        let (ctx, router, wc) = try makeController(prefix: "activity-open-terminal")
        let ws = try router.createWorkspace(name: "open-terminal", cwd: NSTemporaryDirectory())
        wc.refreshFromState()
        drainMainQueue()
        let surface = try XCTUnwrap(surfaceIDs(in: try XCTUnwrap(ctx.state.workspaces[ws.id])).first)
        wc.presentActiveThreadsInMainContent()
        drainMainQueue(0.2)
        XCTAssertFalse(wc.isShowingWorkspaceContent)

        let vm = ActiveThreadsViewModel(context: ctx, router: router, loadImmediately: false)
        vm.openActivity(ActivityWireItem(
            id: "surface:x", kind: "terminal", run_id: nil, request_id: nil, notification_id: nil,
            workspace_id: ws.id.value.uuidString, thread_id: nil, surface_id: surface.value.uuidString,
            state: "running", title: "t", workspace_name: nil, provider: nil, summary: nil,
            occurred_at: "2026-11-04T04:57:00Z", started_at: nil, finished_at: nil, viewed_at: nil,
            attention_acknowledged_at: nil, needs_action: false, blocking: false,
            final_message_id: nil, checkpoint_id: nil, changed_files: [], error: nil
        ))

        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(wc.isShowingWorkspaceContent, "Open terminal must show the workspace, not stay on Activity")
    }

    func test_closeFocusedSurface_isRefusedWhileBotsOwnsTheShell_becauseTheHiddenTabWouldDie() throws {
        let (ctx, router, wc) = try makeController(prefix: "bots-close")
        let ws = try router.createWorkspace(name: "hidden-close", cwd: NSTemporaryDirectory())
        wc.refreshFromState()
        drainMainQueue()
        try assertWorkspacePanesAreMounted(wc)

        let surfacesBefore = surfaceIDs(in: try XCTUnwrap(ctx.state.workspaces[ws.id]))
        XCTAssertFalse(surfacesBefore.isEmpty, "precondition: the workspace must own at least one surface")

        wc.presentBotsInMainContent()
        drainMainQueue(0.2)

        XCTAssertFalse(
            wc.closeFocusedSurface(),
            "⌘W must refuse to close a surface while Bots owns the shell: the target pane is off-screen, and closing it reaches permanentlyCloseRuntimeSurface, which deletes the terminal scrollback with no visible feedback"
        )

        let surfacesAfter = surfaceIDs(in: try XCTUnwrap(ctx.state.workspaces[ws.id]))
        XCTAssertEqual(
            surfacesAfter, surfacesBefore,
            "a refused ⌘W must leave the hidden workspace layout untouched"
        )
        for id in surfacesBefore {
            XCTAssertNotNil(
                SurfaceRegistry.shared.surface(id),
                "a refused ⌘W must not unregister the hidden surface"
            )
        }
    }

    func test_splitFocusedPane_isRefusedWhileScheduledTasksOwnsTheShell() throws {
        let (ctx, router, wc) = try makeController(prefix: "sched-split")
        let ws = try router.createWorkspace(name: "hidden-split", cwd: NSTemporaryDirectory())
        wc.refreshFromState()
        drainMainQueue()
        try assertWorkspacePanesAreMounted(wc)

        let panesBefore = try XCTUnwrap(ctx.state.workspaces[ws.id]).layout.paneIDs()

        wc.presentScheduledTasksInMainContent()
        drainMainQueue(0.2)

        XCTAssertFalse(
            wc.splitFocusedPane(.right),
            "⌘D must refuse to split while Schedule Tasks owns the shell: the split would land on the hidden workspace and only appear after the user switches back"
        )
        XCTAssertEqual(
            try XCTUnwrap(ctx.state.workspaces[ws.id]).layout.paneIDs(), panesBefore,
            "a refused ⌘D must not add a pane to the hidden workspace"
        )
    }

    func test_resizeFocusedPane_isRefusedWhileActiveThreadsOwnsTheShell() throws {
        let (ctx, router, wc) = try makeController(prefix: "threads-resize")
        let ws = try router.createWorkspace(name: "hidden-resize", cwd: NSTemporaryDirectory())
        wc.refreshFromState()
        drainMainQueue()
        try assertWorkspacePanesAreMounted(wc)

        XCTAssertTrue(
            wc.splitFocusedPane(.right),
            "precondition: in workspace mode ⌘D must split the focused pane, so the resize entry point has a live split target"
        )
        drainMainQueue(0.2)

        wc.presentActiveThreadsInMainContent()
        drainMainQueue(0.2)

        let ratiosBefore = try XCTUnwrap(rootSplitRatios(in: try XCTUnwrap(ctx.state.workspaces[ws.id])))
        XCTAssertFalse(
            wc.resizeFocusedPane(.right),
            "⌘⌥arrows must refuse to resize while Active Threads owns the shell: the ratios belong to a split the user cannot see"
        )
        XCTAssertEqual(
            rootSplitRatios(in: try XCTUnwrap(ctx.state.workspaces[ws.id])), ratiosBefore,
            "a refused resize must leave the hidden split ratios untouched"
        )
    }

    func test_tabShortcut_isRefusedWhileBotsOwnsTheShell_becauseTheTabsAreOffScreen() throws {
        let (ctx, router, wc) = try makeController(prefix: "bots-tabs")
        let delegate = AppDelegate(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "RC2ShellDestinationTabs-\(UUID().uuidString)")
        delegate.context = ctx
        delegate.router = router
        delegate.windowController = wc
        delegate.keyWindowProviderForTests = { wc.window }

        let ws = try router.createWorkspace(name: "hidden-tabs", cwd: NSTemporaryDirectory())
        _ = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "hidden-2")
        wc.refreshFromState()
        drainMainQueue()
        try assertWorkspacePanesAreMounted(wc)

        let workspace = try XCTUnwrap(ctx.state.workspaces[ws.id])
        let paneID = try XCTUnwrap(workspace.focusedPaneID ?? workspace.layout.paneIDs().first)
        let selectedBefore = try XCTUnwrap(
            workspace.layout.find(paneID: paneID)?.selectedSurfaceID,
            "precondition: the hidden pane needs a selected tab and a second one, otherwise a wrongly routed ⌘⇧] has nothing to step"
        )
        XCTAssertEqual(
            workspace.layout.find(paneID: paneID)?.surfaces.count, 2,
            "precondition: two tabs, so stepping is observable"
        )

        wc.presentBotsInMainContent()
        drainMainQueue(0.2)

        XCTAssertTrue(
            NSApp.sendAction(NSSelectorFromString("selectNextTab"), to: delegate, from: nil),
            "⌘⇧] must stay reachable through the AppDelegate responder"
        )
        drainMainQueue()

        XCTAssertEqual(
            try XCTUnwrap(ctx.state.workspaces[ws.id]).layout.find(paneID: paneID)?.selectedSurfaceID,
            selectedBefore,
            "⌘⇧] must refuse to step tabs while Bots owns the shell: those tabs belong to a workspace the user cannot see"
        )
    }
}
