import Foundation
import AppKit
import SwiftUI
import CoreModel
import Surfaces
import DesignSystemKit
import os

/// QA-MAC_SHELL_WINDOW-006: structured logging for shell state
/// transitions (sidebar collapse, detach/return/close, container
/// rebuilds) so "my layout flashed / lost focus" reports are
/// diagnosable and the PERF-002 rebuild cost is measurable.
private let shellLog = Logger(subsystem: "io.remotecode.appshell", category: "shell")

@MainActor
protocol PaneKeyboardResizeHandling: AnyObject {
    func resizeFocusedPane(_ direction: SplitDirection) -> Bool
}

/// UX-MAC_SHELL_WINDOW-003/004: keyboard target resolution shared by the main
/// window and the workspaces detached into their own windows. The keyboard
/// command belongs to the workspace whose window owns it, so both classes
/// resolve "the focused pane of *this* workspace" the same way: the workspace's
/// focused pane, falling back to the first mounted pane.
@MainActor
private func keyboardTargetPane(in workspace: Workspace, controllers: [PaneTabsView]) -> PaneTabsView? {
    let focusedPaneID = workspace.focusedPaneID ?? workspace.layout.paneIDs().first
    guard let focusedPaneID else { return nil }
    return controllers.first(where: { $0.pane.id == focusedPaneID }) ?? controllers.first
}

@MainActor
private func closeKeyboardTargetSurface(in workspace: Workspace, controllers: [PaneTabsView]) -> Bool {
    guard let controller = keyboardTargetPane(in: workspace, controllers: controllers) else { return false }
    return controller.closeSelectedSurface()
}

@MainActor
private func splitKeyboardTargetPane(
    _ direction: SplitDirection,
    in workspace: Workspace,
    controllers: [PaneTabsView]
) -> Bool {
    guard let controller = keyboardTargetPane(in: workspace, controllers: controllers) else { return false }
    // UX-P3: default to the active tab's surface type so ⌘D/⌘⇧] mirror
    // what the mouse split-buttons would open. Fall back to Terminal when
    // no surface is selected.
    let selectedSurface = controller.pane.selectedSurfaceID
        .flatMap { id in controller.pane.surfaces.first(where: { $0.id == id }) }
        ?? controller.pane.surfaces.first
    let splitType = selectedSurface?.type ?? .terminal
    let splitTitle = selectedSurface.flatMap { WorkspaceTool.from(metadata: $0.metadata, title: $0.title)?.title }
        ?? PaneTabsView.surfaceChoices.first(where: { $0.1 == splitType })?.0 ?? L("Terminal")
    return controller.performSplit(direction, type: splitType, title: splitTitle) != nil
}

@MainActor
private func resizeKeyboardTargetPane(
    _ direction: SplitDirection,
    in workspace: Workspace,
    controllers: [PaneTabsView]
) -> Bool {
    guard let controller = keyboardTargetPane(in: workspace, controllers: controllers) else { return false }
    return controller.performKeyboardPaneResize(direction: direction)
}

final class InteractiveTitlebarWindow: NSWindow {
    /// QA-MAC_SHELL_WINDOW-005: the interactive titlebar band height. The
    /// tab strip / header lives in the top `titlebarBandHeight` points of
    /// the content view; clicks there route to tabs/zoom instead of a
    /// window drag.
    static let titlebarBandHeight: CGFloat = 44
    private weak var titlebarTabDragTarget: PaneTabButton?
    private var frameBeforeTitlebarZoom: NSRect?
    private var lastTitlebarClick: (time: TimeInterval, point: NSPoint)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           let direction = PaneKeyboardResizeKey.direction(keyCode: event.keyCode, modifiers: event.modifierFlags),
           let handler = delegate as? PaneKeyboardResizeHandling,
           handler.resizeFocusedPane(direction) {
            return
        }
        if event.type == .leftMouseDown, dispatchTitlebarDoubleClick(event) {
            return
        }
        if routeTitlebarTabDrag(event) {
            return
        }
        if event.type == .leftMouseDown, dispatchInteractiveTitlebarClick(event) {
            return
        }
        super.sendEvent(event)
    }

    private func routeTitlebarTabDrag(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard let tab = titlebarTab(at: event) else { return false }
            titlebarTabDragTarget = tab
            tab.mouseDown(with: event)
            return true
        case .leftMouseDragged:
            guard let tab = titlebarTabDragTarget else { return false }
            tab.mouseDragged(with: event)
            return true
        case .leftMouseUp:
            guard let tab = titlebarTabDragTarget else { return false }
            tab.mouseUp(with: event)
            titlebarTabDragTarget = nil
            return true
        default:
            return false
        }
    }

    private func dispatchTitlebarDoubleClick(_ event: NSEvent) -> Bool {
        guard let point = titlebarZoomPoint(for: event) else { return false }

        let isDoubleClick = event.clickCount == 2 || isRepeatedTitlebarClick(event, at: point)
        lastTitlebarClick = (event.timestamp, point)
        guard isDoubleClick else { return false }

        toggleTitlebarZoom()
        lastTitlebarClick = nil
        return true
    }

    private func titlebarZoomPoint(for event: NSEvent) -> NSPoint? {
        guard styleMask.contains(.fullSizeContentView),
              let contentView else { return nil }

        let point = contentView.convert(event.locationInWindow, from: nil)
        guard Self.isInTitlebarBand(point: point, contentHeight: contentView.bounds.height) else { return nil }
        guard let hit = contentView.hitTest(point) else { return point }
        guard enclosingView(from: hit, as: NoDragButton.self) == nil,
              enclosingView(from: hit, as: PaneTabButton.self) == nil else { return nil }
        return point
    }

    private func isRepeatedTitlebarClick(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard let last = lastTitlebarClick else { return false }
        let interval = event.timestamp - last.time
        let distance = hypot(point.x - last.point.x, point.y - last.point.y)
        return interval <= NSEvent.doubleClickInterval && distance <= 4
    }

    private func toggleTitlebarZoom() {
        guard let screen else {
            performZoom(nil)
            return
        }
        if let previous = frameBeforeTitlebarZoom {
            setFrame(previous, display: true, animate: true)
            frameBeforeTitlebarZoom = nil
        } else {
            frameBeforeTitlebarZoom = frame
            setFrame(screen.visibleFrame, display: true, animate: true)
        }
    }

    private func titlebarTab(at event: NSEvent) -> PaneTabButton? {
        guard styleMask.contains(.fullSizeContentView),
              let contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard Self.isInTitlebarBand(point: point, contentHeight: contentView.bounds.height),
              let hit = contentView.hitTest(point),
              enclosingView(from: hit, as: NoDragButton.self) == nil else { return nil }
        return enclosingView(from: hit, as: PaneTabButton.self)
    }

    private func dispatchInteractiveTitlebarClick(_ event: NSEvent) -> Bool {
        guard styleMask.contains(.fullSizeContentView),
              let contentView else { return false }

        let point = contentView.convert(event.locationInWindow, from: nil)
        guard Self.isInTitlebarBand(point: point, contentHeight: contentView.bounds.height),
              let hit = contentView.hitTest(point) else { return false }

        if let button = enclosingView(from: hit, as: NoDragButton.self) {
            button.performClick(nil)
            return true
        }

        return false
    }

    private func enclosingView<T: NSView>(from view: NSView, as type: T.Type) -> T? {
        var current: NSView? = view
        while let candidate = current {
            if let typed = candidate as? T { return typed }
            current = candidate.superview
        }
        return nil
    }

    /// QA-MAC_SHELL_WINDOW-005: testable band predicate. True when a
    /// content-space point falls inside the interactive titlebar band of a
    /// content view of the given height. Exposed so the routing decision
    /// can be unit-tested with synthetic geometry instead of live events.
    static func isInTitlebarBand(point: NSPoint, contentHeight: CGFloat) -> Bool {
        point.y >= contentHeight - titlebarBandHeight
    }
}

private extension NSWindow {
    func configureRemoteCodeWindowAccessibility(title: String, identifier: String) {
        setAccessibilityRole(.window)
        setAccessibilitySubrole(.standardWindow)
        setAccessibilityTitle(title)
        setAccessibilityIdentifier(identifier)
    }
}

enum PaneKeyboardResizeKey {
    private static let requiredModifiers: NSEvent.ModifierFlags = [.control, .option]
    private static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    nonisolated static func direction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> SplitDirection? {
        guard modifiers.intersection(relevantModifiers) == requiredModifiers else { return nil }
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default: return nil
        }
    }
}

private extension NSRect {
    func isNearlyEqual(to other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) < 2 &&
        abs(origin.y - other.origin.y) < 2 &&
        abs(size.width - other.size.width) < 2 &&
        abs(size.height - other.size.height) < 2
    }
}

public extension Notification.Name {
    /// Posted by any sidebar-toggle button (sidebar header or pane header).
    static let rc2ToggleSidebar = Notification.Name("rc2.toggleSidebar")
    /// Posted by the window controller after the sidebar collapses /
    /// expands. userInfo["collapsed"] = Bool.
    static let rc2SidebarVisibility = Notification.Name("rc2.sidebarVisibility")
}

/// Hide/show motion for the shell sidebar, matching DS.Motion.standard
/// (0.22s ease-out) like the inspector / thread rail. The glass panel
/// keeps its width and slides off the leading edge — translating never
/// reflows the sidebar content or resizes the vibrancy backdrop, so
/// there is nothing to squeeze, snap, or drift.
public enum ShellSidebarToggleMotion {
    public static let duration: TimeInterval = 0.22
    public static let minimumSidebarWidth: CGFloat = 180
    /// Smallest main window: the narrowest sidebar beside a 360 pt content pane.
    public static let minimumWindowWidth: CGFloat = minimumSidebarWidth + 380
    public static let maximumSidebarWidth: CGFloat = 560

    /// Leading offset of the constant-width sidebar panel.
    public static func leadingOffset(collapsed: Bool, width: CGFloat) -> CGFloat {
        collapsed ? -width : 0
    }

    /// Whole pixels only, floored/capped to the product bounds and to
    /// what the window can grant (content keeps at least 520pt). A
    /// fractional edge antialiases the seam into a blurry stray line.
    public static func clampedSidebarWidth(_ width: CGFloat, contentWidth: CGFloat) -> CGFloat {
        let maxAllowed = min(maximumSidebarWidth, max(220, contentWidth - 520))
        return min(max(width.rounded(), minimumSidebarWidth), maxAllowed)
    }

    public static func splitTopInset(collapsed: Bool, headerHeight: CGFloat) -> CGFloat {
        collapsed ? headerHeight : 0
    }

    public static func workspaceContentTopInset(
        collapsed: Bool,
        hidesVisibleHeader: Bool,
        headerHeight: CGFloat
    ) -> CGFloat {
        (collapsed || hidesVisibleHeader) ? 0 : headerHeight
    }
}

@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate, PaneKeyboardResizeHandling {
    public let window: NSWindow
    public weak var context: AppContext?
    public weak var router: AppCommandRouter?

    private let sidebar: SidebarView
    /// Side-by-side host for the sliding sidebar panel and the content
    /// column. Plain Auto Layout — no NSSplitView, no divider strip.
    private let columns = NSView()
    private let sidebarResizeHandle = SidebarResizeHandleView()
    private var sidebarLeadingConstraint: NSLayoutConstraint?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private let workspaceContainer = NSView()
    private let workspaceContent = NSView()
    private let collapsedWorkspaceHeader = NoDragView()
    private let collapsedWorkspaceLabel = NSTextField(labelWithString: "")
    private let collapsedPlusButton = NoDragButton(frame: .zero)
    private let collapsedSidebarButton = NoDragButton(frame: .zero)
    private let visibleWorkspaceHeader = NoDragView()
    private let visibleWorkspaceLabel = NSTextField(labelWithString: "")
    private let visibleFinderButton = NoDragButton(frame: .zero)
    private let visibleNewWindowButton = NoDragButton(frame: .zero)
    private let toolbarLabel = NSTextField(labelWithString: "MacCode")
    /// Retains the live pane controllers; their @objc button and tab
    /// targets die with them, so they must outlive a layout rebuild.
    private var paneControllers: [PaneTabsView] = []
    private var sidebarCollapsed = false
    static let defaultSidebarWidth: CGFloat = 444
    static let sidebarWidthSettingsKey = "sidebar.width"
    static let sidebarCollapsedSettingsKey = "sidebar.collapsed"
    static let botsShellSettingsKey = "shell.botsSelected"
    /// IMP-MAC_SHELL_WINDOW-005: AppKit frame-autosave key for the main
    /// window so its size/position survive relaunch.
    private static let mainWindowFrameAutosaveName = "io.remotecode.mainWindow"
    /// The user's chosen sidebar width. The width constraint may hold a
    /// window-clamped value; this keeps the preference so growing the
    /// window restores it. Persisted once per drag gesture (mouse up).
    private var sidebarWidth: CGFloat = MainWindowController.defaultSidebarWidth
    private var sidebarToggleGeneration = 0
    private var headerVisibilityAnimated = false
    /// PERF-MAC_SHELL_WINDOW-004: coalesce refreshFromState calls per
    /// runloop tick. Multiple requests arriving within one tick (e.g. an
    /// agent event burst) share one scheduled async flush instead of each
    /// triggering a full sidebar reload + signature walk.
    private var hasPendingRefresh = false
    private var hasPendingActiveThreadsChange = false
    private let collapsedHeaderHeight: CGFloat = 34
    private var columnsTopConstraint: NSLayoutConstraint?
    private var workspaceContentTopConstraint: NSLayoutConstraint?
    private var workspaceWindows: [WorkspaceID: WorkspaceWindowController] = [:]
    private var detachedWorkspaceIDs: Set<WorkspaceID> = []
    private var botWindows: [BotID: BotDeskWindowController] = [:]
    private var botGuestWindows: [BotID: BotGuestDesktopWindowController] = [:]
    /// PERF-MAC_SHELL_WINDOW-002: signature of the last container build
    /// (selected workspace + pane/surface/selection structure). When an
    /// unchanged signature comes back through `refreshFromState` (app
    /// become-key/active/reopen) the full teardown/rebuild is skipped.
    private var lastWorkspaceContainerSignature: String?
    /// Cached workspace content stays mounted (but hidden) while a shell
    /// destination is visible. Keeping this tree alive lets a shell switch
    /// paint from the existing workspace cache instead of tearing down panes
    /// on the click-to-first-frame path.
    private var cachedWorkspaceContentViews: [NSView] = []
    private var cachedWorkspaceID: WorkspaceID?
    /// UX-MAC_SHELL_WINDOW-014: true between launch and the first refresh
    /// after restored surfaces are reinstantiated. While restoring, an
    /// empty container shows a "Restoring workspaces…" affordance instead
    /// of the bare no-workspace empty state.
    private var isRestoringLayout = true
    /// PERF-MAC_SHELL_WINDOW-002 (test seam): incremented each time
    /// `rebuildWorkspaceContainer` performs a full teardown/rebuild (i.e.
    /// the layout signature changed or the controller set is empty).
    /// The early-return / reconcile-in-place path does NOT increment.
    /// Production code never reads this; tests assert it to catch silent
    /// rebuild regressions that os.log alone cannot surface.
    var rebuildCount: Int = 0

    /// Shell main-content destination. Scheduled Tasks, Active Threads, and
    /// Bots open here (same place as workspaces), not in a separate NSWindow.
    private enum ShellContentMode: Equatable {
        case workspace
        case scheduledTasks
        case activeThreads
        case bots
        case settings
    }
    private var shellContentMode: ShellContentMode = .workspace {
        didSet {
            // The cached Scheduled Tasks model keeps no active-run poll while
            // another destination is shown; its next mount re-arms it.
            if oldValue == .scheduledTasks, shellContentMode != .scheduledTasks {
                scheduledTasksViewModel?.setVisible(false)
            }
        }
    }
    /// The main content shows the Bots destination (Titio inbox "viewing", hub spec §8).
    var isShowingBotsContent: Bool { shellContentMode == .bots }
    /// The main content shows the workspace layout (focused-success suppression, §2).
    var isShowingWorkspaceContent: Bool { shellContentMode == .workspace }
    private var scheduledTasksViewModel: ScheduledTasksViewModel?
    private var scheduledTasksHostingView: NSView?
    private var activeThreadsViewModel: ActiveThreadsViewModel?
    private var activeThreadsHostingView: NSView?
    private var settingsViewModel: SettingsViewModel?
    private var settingsHostingView: NSView?
    private var settingsFreshnessTask: Task<Void, Never>?
    private var settingsFreshnessGeneration: UInt64 = 0
    private var botsViewModel: BotsViewModel?
    private var botsHostingView: NSView?
    private var currentShellHostingView: NSView?
    /// Test seam: Workspaces <-> Bots must reattach this instance, not remount.
    var botsHostingViewForTesting: NSView? { botsHostingView }
    var sidebarWorkspacesForTesting: [Workspace] { sidebar.workspacesForTesting }
    var sidebarViewModelForTesting: SidebarViewModel { sidebar.viewModelForTesting }
    var sidebarBotsViewModelForTesting: BotsViewModel { sidebar.botsViewModel }
    /// Same callback the sidebar's "Manage Bots and Teams" footer runs.
    private var destinationPersistenceTask: Task<Void, Never>?
    private var workspaceRebuildTask: Task<Void, Never>?
    private var workspaceRebuildGeneration: UInt64 = 0

    public init(
        context: AppContext,
        router: AppCommandRouter,
        updater: AppUpdateChecking? = nil
    ) {
        self.context = context
        self.router = router
        self.sidebar = SidebarView(
            context: context,
            router: router,
            updater: updater
        )
        self.sidebarWidth = Self.storedSidebarWidth(context: context)

        let style: NSWindow.StyleMask = [.titled, .resizable, .closable, .miniaturizable]
        let win = InteractiveTitlebarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        win.title = "MacCode"
        win.configureRemoteCodeWindowAccessibility(title: "MacCode", identifier: "window.main")
        // Unified titlebar: content runs full height, the system title
        // bar is transparent and titleless, so the traffic-light buttons
        // float over the app's own header row (the sidebar header).
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = false
        win.collectionBehavior.insert(.moveToActiveSpace)
        // Narrowest sidebar (180 pt) plus a 360 pt content pane; every screen fits 360 pt.
        win.minSize = NSSize(width: ShellSidebarToggleMotion.minimumWindowWidth, height: 480)
        RemoteCodeAppearance.apply(to: win)
        self.window = win

        super.init()
        win.delegate = self
        setupLayout()
        // Schedule Tasks / workspace selection share the main content pane
        // (not a separate window). Sidebar routes both through this controller.
        sidebar.onPresentScheduledTasks = { [weak self] in
            self?.presentScheduledTasksInMainContent()
        }
        sidebar.onPresentActiveThreads = { [weak self] in
            self?.presentActiveThreadsInMainContent()
        }
        sidebar.onPresentSettings = { [weak self] in
            self?.presentSettingsInMainContent()
        }
        sidebar.botsViewModel.onLeaveBots = { [weak self] in
            self?.presentWorkspaceContent()
        }
        sidebar.onWorkspaceContentActivated = { [weak self] in
            self?.presentWorkspaceContent()
        }
        // UX-MAC_SHELL_WINDOW-009: restore the collapsed sidebar state so a
        // user who works collapsed does not have to re-collapse on launch.
        if Self.storedSidebarCollapsed(context: context) {
            applyStoredCollapsedLayout()
        }
        refreshFromState()
        restoreBotsShellDestinationIfNeeded()
        // IMP-MAC_SHELL_WINDOW-005: persist and restore the main window
        // frame across launches (matching the sidebar width/collapse state
        // that already persist). AppKit returns false when no saved frame
        // exists, so first launch still centers.
        if !win.setFrameUsingName(Self.mainWindowFrameAutosaveName) {
            win.center()
        }
        win.setFrameAutosaveName(Self.mainWindowFrameAutosaveName)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToggleSidebar),
            name: .rc2ToggleSidebar, object: nil)
    }

    deinit {
        destinationPersistenceTask?.cancel()
        workspaceRebuildTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleToggleSidebar() {
        sidebarCollapsed.toggle()
        sidebarToggleGeneration += 1
        let generation = sidebarToggleGeneration
        let collapsed = sidebarCollapsed
        shellLog.debug("sidebar.toggle collapsed=\(self.sidebarCollapsed, privacy: .public)")
        sidebar.view.isHidden = false
        sidebarResizeHandle.isHidden = sidebarCollapsed
        headerVisibilityAnimated = true
        NSAnimationContext.runAnimationGroup({ [self] ctx in
            ctx.duration = ShellSidebarToggleMotion.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            sidebarLeadingConstraint?.animator().constant = ShellSidebarToggleMotion.leadingOffset(
                collapsed: sidebarCollapsed,
                width: sidebarWidthConstraint?.constant ?? sidebarWidth
            )
            updateCollapsedWorkspaceHeader()
            window.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, generation == self.sidebarToggleGeneration else { return }
            // Off-window or transparent views remain hit-testable / VoiceOver-reachable.
            self.sidebar.view.isHidden = collapsed
            self.collapsedWorkspaceHeader.isHidden = !collapsed
        })
        headerVisibilityAnimated = false
        NotificationCenter.default.post(
            name: .rc2SidebarVisibility, object: nil,
            userInfo: ["collapsed": sidebarCollapsed])
        // UX-MAC_SHELL_WINDOW-009: persist so the state survives relaunch.
        try? context?.settingsRepo.set(Self.sidebarCollapsedSettingsKey, sidebarCollapsed ? "1" : "0")
    }

    /// UX-MAC_SHELL_WINDOW-009: apply the collapsed layout synchronously at
    /// launch (no animation) so a restored collapsed sidebar renders
    /// correctly on the first frame.
    private func applyStoredCollapsedLayout() {
        sidebarCollapsed = true
        sidebar.view.isHidden = true
        sidebarResizeHandle.isHidden = true
        sidebarLeadingConstraint?.constant = ShellSidebarToggleMotion.leadingOffset(
            collapsed: true,
            width: sidebarWidthConstraint?.constant ?? sidebarWidth
        )
        updateCollapsedWorkspaceHeader()
    }

    /// Live drag from the seam handle: move the width constraint only.
    /// No DB writes while dragging — one durable write on mouse up.
    func sidebarDragUpdated(toWidth proposed: CGFloat) {
        guard !sidebarCollapsed, let content = window.contentView else { return }
        let clamped = ShellSidebarToggleMotion.clampedSidebarWidth(
            proposed, contentWidth: content.bounds.width
        )
        sidebarWidth = clamped
        sidebarWidthConstraint?.constant = clamped
        content.layoutSubtreeIfNeeded()
    }

    func sidebarDragEnded() {
        guard let ctx = context else { return }
        try? ctx.settingsRepo.set(Self.sidebarWidthSettingsKey, "\(Double(sidebarWidth))")
    }

    /// Shrinking the window must not push content off; growing it back
    /// restores the user's chosen width.
    public func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window,
              let content = window.contentView, content.bounds.width > 0 else { return }
        let clamped = ShellSidebarToggleMotion.clampedSidebarWidth(
            sidebarWidth, contentWidth: content.bounds.width
        )
        guard let widthConstraint = sidebarWidthConstraint,
              abs(widthConstraint.constant - clamped) > 0.5 else { return }
        widthConstraint.constant = clamped
        if sidebarCollapsed {
            sidebarLeadingConstraint?.constant = ShellSidebarToggleMotion.leadingOffset(
                collapsed: true, width: clamped
            )
        }
    }

    private func setupLayout() {
        window.backgroundColor = DS.NS.bg
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = DS.NS.bg.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.setAccessibilityIdentifier("shell.columns")
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.setAccessibilityIdentifier("shell.sidebar")
        workspaceContainer.translatesAutoresizingMaskIntoConstraints = false
        workspaceContent.translatesAutoresizingMaskIntoConstraints = false

        workspaceContainer.wantsLayer = true
        workspaceContainer.layer?.backgroundColor = DS.NS.bg.cgColor
        workspaceContent.wantsLayer = true
        workspaceContent.layer?.backgroundColor = DS.NS.bg.cgColor
        workspaceContainer.addSubview(workspaceContent)
        let workspaceTop = workspaceContent.topAnchor.constraint(equalTo: workspaceContainer.topAnchor, constant: collapsedHeaderHeight)
        workspaceContentTopConstraint = workspaceTop
        NSLayoutConstraint.activate([
            workspaceTop,
            workspaceContent.bottomAnchor.constraint(equalTo: workspaceContainer.bottomAnchor),
            workspaceContent.leadingAnchor.constraint(equalTo: workspaceContainer.leadingAnchor),
            workspaceContent.trailingAnchor.constraint(equalTo: workspaceContainer.trailingAnchor)
        ])
        configureCollapsedWorkspaceHeader()
        configureVisibleWorkspaceHeader()
        columns.addSubview(sidebar.view)
        columns.addSubview(workspaceContainer)
        columns.addSubview(sidebarResizeHandle)
        sidebarResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        sidebarResizeHandle.currentWidth = { [weak self] in
            self?.sidebarWidthConstraint?.constant ?? MainWindowController.defaultSidebarWidth
        }
        sidebarResizeHandle.onDrag = { [weak self] proposed in
            self?.sidebarDragUpdated(toWidth: proposed)
        }
        sidebarResizeHandle.onDragEnded = { [weak self] in
            self?.sidebarDragEnded()
        }
        // The glass panel never resizes during the toggle — it keeps the
        // user's width and slides off the leading edge; the content
        // column's leading is pinned to its trailing, so one animated
        // constraint drives the whole motion with no divider strip.
        let sidebarLeading = sidebar.view.leadingAnchor.constraint(
            equalTo: columns.leadingAnchor,
            constant: ShellSidebarToggleMotion.leadingOffset(collapsed: sidebarCollapsed, width: sidebarWidth)
        )
        sidebarLeadingConstraint = sidebarLeading
        let sidebarWidthC = sidebar.view.widthAnchor.constraint(equalToConstant: sidebarWidth)
        sidebarWidthConstraint = sidebarWidthC

        content.addSubview(columns)
        content.addSubview(visibleWorkspaceHeader)
        content.addSubview(collapsedWorkspaceHeader)
        collapsedWorkspaceHeader.isHidden = true
        let columnsTop = columns.topAnchor.constraint(equalTo: content.topAnchor, constant: 0)
        columnsTopConstraint = columnsTop
        NSLayoutConstraint.activate([
            sidebarLeading,
            sidebarWidthC,
            sidebar.view.topAnchor.constraint(equalTo: columns.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
            workspaceContainer.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            workspaceContainer.topAnchor.constraint(equalTo: columns.topAnchor),
            workspaceContainer.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
            workspaceContainer.trailingAnchor.constraint(equalTo: columns.trailingAnchor),
            sidebarResizeHandle.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor, constant: -2),
            sidebarResizeHandle.widthAnchor.constraint(equalToConstant: 5),
            sidebarResizeHandle.topAnchor.constraint(equalTo: columns.topAnchor),
            sidebarResizeHandle.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
            columnsTop,
            columns.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            columns.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            visibleWorkspaceHeader.topAnchor.constraint(equalTo: content.topAnchor),
            visibleWorkspaceHeader.leadingAnchor.constraint(equalTo: workspaceContainer.leadingAnchor),
            visibleWorkspaceHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            visibleWorkspaceHeader.heightAnchor.constraint(equalToConstant: collapsedHeaderHeight),
            collapsedWorkspaceHeader.topAnchor.constraint(equalTo: content.topAnchor),
            collapsedWorkspaceHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            collapsedWorkspaceHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            collapsedWorkspaceHeader.heightAnchor.constraint(equalToConstant: collapsedHeaderHeight)
        ])
        window.contentView = content
    }

    public func show() {
        if LocalAuthAdapter.isE2EPairingAutoApproveEnabled {
            // Keep the session alive for paired HTTP without becoming key/frontmost.
            window.orderFrontRegardless()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    public func disableInsomniaForAppClose() {
        sidebar.disableInsomniaForAppClose()
    }

	    private func configureCollapsedWorkspaceHeader() {
	        collapsedWorkspaceHeader.translatesAutoresizingMaskIntoConstraints = false
	        collapsedWorkspaceHeader.wantsLayer = true
	        collapsedWorkspaceHeader.layer?.backgroundColor = DS.NS.surface.cgColor
	        collapsedWorkspaceHeader.layer?.masksToBounds = true

	        collapsedWorkspaceLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
	        collapsedWorkspaceLabel.textColor = DS.NS.text
	        collapsedWorkspaceLabel.alignment = .center
	        collapsedWorkspaceLabel.lineBreakMode = .byTruncatingTail
	        collapsedWorkspaceLabel.translatesAutoresizingMaskIntoConstraints = false

	        configureHeaderButton(collapsedPlusButton, symbol: "plus",
	                              help: L("New workspace"),
	                              action: #selector(newWorkspace))
	        collapsedPlusButton.setAccessibilityIdentifier("shell.collapsed.newWorkspace")
	        configureHeaderButton(collapsedSidebarButton, symbol: "sidebar.left",
	                              help: L("Toggle sidebar"),
	                              action: #selector(handleToggleSidebar))
	        collapsedSidebarButton.setAccessibilityIdentifier("shell.collapsed.toggleSidebar")

	        let divider = NSView()
	        divider.wantsLayer = true
	        divider.layer?.backgroundColor = DS.NS.line.cgColor
	        divider.translatesAutoresizingMaskIntoConstraints = false

	        collapsedWorkspaceHeader.addSubview(collapsedWorkspaceLabel)
	        collapsedWorkspaceHeader.addSubview(collapsedPlusButton)
	        collapsedWorkspaceHeader.addSubview(collapsedSidebarButton)
	        collapsedWorkspaceHeader.addSubview(divider)
	        NSLayoutConstraint.activate([
	            collapsedWorkspaceLabel.centerXAnchor.constraint(equalTo: collapsedWorkspaceHeader.centerXAnchor),
	            collapsedWorkspaceLabel.centerYAnchor.constraint(equalTo: collapsedWorkspaceHeader.centerYAnchor),
		            collapsedWorkspaceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: collapsedSidebarButton.trailingAnchor, constant: DS.Space.sm),
		            collapsedWorkspaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: collapsedPlusButton.leadingAnchor, constant: -DS.Space.sm),
		            collapsedPlusButton.trailingAnchor.constraint(equalTo: collapsedWorkspaceHeader.trailingAnchor, constant: -DS.Space.sm),
		            collapsedPlusButton.centerYAnchor.constraint(equalTo: collapsedWorkspaceHeader.centerYAnchor),
		            collapsedSidebarButton.leadingAnchor.constraint(equalTo: collapsedWorkspaceHeader.leadingAnchor, constant: 92),
		            collapsedSidebarButton.centerYAnchor.constraint(equalTo: collapsedWorkspaceHeader.centerYAnchor),
	            divider.leadingAnchor.constraint(equalTo: collapsedWorkspaceHeader.leadingAnchor),
	            divider.trailingAnchor.constraint(equalTo: collapsedWorkspaceHeader.trailingAnchor),
	            divider.bottomAnchor.constraint(equalTo: collapsedWorkspaceHeader.bottomAnchor),
	            divider.heightAnchor.constraint(equalToConstant: 1)
	        ])
	        updateCollapsedWorkspaceHeader()
	    }

        private func configureVisibleWorkspaceHeader() {
            visibleWorkspaceHeader.translatesAutoresizingMaskIntoConstraints = false
            visibleWorkspaceHeader.wantsLayer = true
            visibleWorkspaceHeader.layer?.backgroundColor = DS.NS.surface.cgColor
            visibleWorkspaceHeader.layer?.masksToBounds = true

            visibleWorkspaceLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            visibleWorkspaceLabel.textColor = DS.NS.text
            visibleWorkspaceLabel.alignment = .center
            visibleWorkspaceLabel.lineBreakMode = .byTruncatingTail
            visibleWorkspaceLabel.translatesAutoresizingMaskIntoConstraints = false
            configureHeaderButton(
                visibleNewWindowButton,
                symbol: "rectangle.on.rectangle",
                help: L("Open in New Window"),
                action: #selector(openSelectedWorkspaceInNewWindow)
            )
            visibleNewWindowButton.setAccessibilityIdentifier("workspaceHeader.openInNewWindow")
            configureHeaderButton(
                visibleFinderButton,
                symbol: "folder",
                help: L("Open in Finder"),
                action: #selector(openSelectedWorkspaceInFinder)
            )
            visibleFinderButton.setAccessibilityIdentifier("workspaceHeader.openInFinder")

            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = DS.NS.line.cgColor
            divider.translatesAutoresizingMaskIntoConstraints = false

            visibleWorkspaceHeader.addSubview(visibleWorkspaceLabel)
            visibleWorkspaceHeader.addSubview(visibleFinderButton)
            visibleWorkspaceHeader.addSubview(visibleNewWindowButton)
            visibleWorkspaceHeader.addSubview(divider)
            NSLayoutConstraint.activate([
                visibleWorkspaceLabel.centerXAnchor.constraint(equalTo: visibleWorkspaceHeader.centerXAnchor),
                visibleWorkspaceLabel.centerYAnchor.constraint(equalTo: visibleWorkspaceHeader.centerYAnchor),
                visibleWorkspaceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: visibleWorkspaceHeader.leadingAnchor, constant: DS.Space.lg),
                visibleWorkspaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: visibleFinderButton.leadingAnchor, constant: -DS.Space.sm),
                visibleNewWindowButton.trailingAnchor.constraint(equalTo: visibleWorkspaceHeader.trailingAnchor, constant: -DS.Space.sm),
                visibleNewWindowButton.centerYAnchor.constraint(equalTo: visibleWorkspaceHeader.centerYAnchor),
                visibleFinderButton.trailingAnchor.constraint(equalTo: visibleNewWindowButton.leadingAnchor, constant: -DS.Space.xs),
                visibleFinderButton.centerYAnchor.constraint(equalTo: visibleWorkspaceHeader.centerYAnchor),
                divider.leadingAnchor.constraint(equalTo: visibleWorkspaceHeader.leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: visibleWorkspaceHeader.trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: visibleWorkspaceHeader.bottomAnchor),
                divider.heightAnchor.constraint(equalToConstant: 1)
            ])
            updateCollapsedWorkspaceHeader()
        }

	    private func configureHeaderButton(_ button: NSButton, symbol: String, help: String, action: Selector) {
	        button.translatesAutoresizingMaskIntoConstraints = false
	        button.isBordered = false
	        button.bezelStyle = .inline
	        button.imagePosition = .imageOnly
	        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
	        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
	        button.contentTintColor = DS.NS.textSecondary
	        button.toolTip = help
	        button.target = self
	        button.action = action
	        button.wantsLayer = true
	        button.layer?.cornerRadius = DS.Radius.control
	        NSLayoutConstraint.activate([
	            button.widthAnchor.constraint(equalToConstant: 26),
	            button.heightAnchor.constraint(equalToConstant: 22)
	        ])
	    }

    func refreshBotsChromeTitle() {
        guard shellContentMode == .bots else { return }
        updateCollapsedWorkspaceHeader()
    }

        /// Desk / Studio already paint the teammate header. The shell "Bots"
        /// row is a second title above it. Collapsed sidebar still needs its
        /// full-width bar for the sidebar toggle.
        private func applyWorkspaceHeaderVisibility() {
            let showCollapsed = sidebarCollapsed
            let hideVisible = showCollapsed || shellContentMode == .bots
            visibleWorkspaceHeader.isHidden = hideVisible
            if headerVisibilityAnimated {
                if showCollapsed {
                    if collapsedWorkspaceHeader.isHidden {
                        collapsedWorkspaceHeader.alphaValue = 0
                        collapsedWorkspaceHeader.isHidden = false
                    }
                    collapsedWorkspaceHeader.animator().alphaValue = 1
                } else if !collapsedWorkspaceHeader.isHidden {
                    collapsedWorkspaceHeader.animator().alphaValue = 0
                }
            } else {
                collapsedWorkspaceHeader.isHidden = !showCollapsed
                collapsedWorkspaceHeader.alphaValue = 1
            }
            let splitTop = ShellSidebarToggleMotion.splitTopInset(
                collapsed: showCollapsed,
                headerHeight: collapsedHeaderHeight
            )
            let contentTop = ShellSidebarToggleMotion.workspaceContentTopInset(
                collapsed: showCollapsed,
                hidesVisibleHeader: shellContentMode == .bots,
                headerHeight: collapsedHeaderHeight
            )
            if headerVisibilityAnimated {
                columnsTopConstraint?.animator().constant = splitTop
                workspaceContentTopConstraint?.animator().constant = contentTop
            } else {
                columnsTopConstraint?.constant = splitTop
                workspaceContentTopConstraint?.constant = contentTop
            }
        }

	    private func updateCollapsedWorkspaceHeader() {
            defer { applyWorkspaceHeaderVisibility() }
            // Schedule Tasks is a shell destination, not a workspace — title and
            // header must not keep the last workspace name.
            if shellContentMode == .scheduledTasks {
                collapsedWorkspaceLabel.stringValue = L("Schedule Tasks")
                visibleWorkspaceLabel.stringValue = L("Schedule Tasks")
                window.title = L("Schedule Tasks")
                visibleFinderButton.isHidden = true
                visibleNewWindowButton.isHidden = true
                return
            }
            if shellContentMode == .activeThreads {
                collapsedWorkspaceLabel.stringValue = L("Active Threads")
                visibleWorkspaceLabel.stringValue = L("Active Threads")
                window.title = L("Active Threads")
                visibleFinderButton.isHidden = true
                visibleNewWindowButton.isHidden = true
                return
            }
            if shellContentMode == .settings {
                collapsedWorkspaceLabel.stringValue = L("Settings")
                visibleWorkspaceLabel.stringValue = L("Settings")
                window.title = L("Settings")
                visibleFinderButton.isHidden = true
                visibleNewWindowButton.isHidden = true
                return
            }
            if shellContentMode == .bots {
                let title = sidebar.botsViewModel.chromeTitle
                collapsedWorkspaceLabel.stringValue = title
                visibleWorkspaceLabel.stringValue = title
                window.title = title
                visibleFinderButton.isHidden = true
                visibleNewWindowButton.isHidden = true
                return
            }
	        guard let ctx = context,
	              let wid = ctx.state.window.selectedWorkspaceID,
	              let ws = ctx.state.workspaces[wid] else {
	            collapsedWorkspaceLabel.stringValue = "MacCode"
	            visibleWorkspaceLabel.stringValue = "MacCode"
                window.title = "MacCode"
                visibleFinderButton.isHidden = true
                visibleNewWindowButton.isHidden = true
	            return
	        }
	        collapsedWorkspaceLabel.stringValue = ws.name
	        visibleWorkspaceLabel.stringValue = ws.name
            window.title = ws.name
            visibleFinderButton.isHidden = false
            visibleNewWindowButton.isHidden = isWorkspaceOpenInNewWindow(wid)
	    }

	    @objc private func newWorkspace() {
	        let panel = NSOpenPanel()
	        panel.canChooseFiles = false
	        panel.canChooseDirectories = true
	        if panel.runModal() == .OK, let url = panel.url {
	            // Header "+" and empty-state "New Workspace" share the sidebar's
	            // canonical add path: DEDUP-P2 (flash the existing workspace
	            // instead of duplicating its cwd), File ▸ Open Recent, and a
	            // visible failure when the folder cannot be added. Creating the
	            // workspace here directly skipped all three.
	            sidebar.createWorkspace(fromFolder: url)
	        }
	    }

        @objc private func openSelectedWorkspaceInNewWindow() {
            guard let wid = context?.state.window.selectedWorkspaceID,
                  !isWorkspaceOpenInNewWindow(wid) else { return }
            openWorkspaceInNewWindow(wid)
        }

        @objc private func openSelectedWorkspaceInFinder() {
            guard let wid = context?.state.window.selectedWorkspaceID,
                  let ws = context?.state.workspaces[wid],
                  let url = SidebarViewModel.finderURL(for: ws) else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open(url)
        }

    public func refreshFromState() {
        guard refreshCoalesceShouldSchedule(wasPending: hasPendingRefresh) else { return }
        hasPendingRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.hasPendingRefresh else { return }
            self.hasPendingRefresh = false
            self._performRefreshFromState()
        }
    }

    /// Exact-route callers need the destination view mounted before they can
    /// verify its owning window and acknowledge unread attention.
    func flushPendingRefresh() {
        guard hasPendingRefresh else { return }
        hasPendingRefresh = false
        _performRefreshFromState()
    }

    private func _performRefreshFromState() {
        let focusedInput = protectedFocusedView()
        sidebar.refresh()
        updateCollapsedWorkspaceHeader()
        rebuildWorkspaceContainer()
        for (workspaceID, controller) in Array(workspaceWindows) {
            guard context?.state.workspaces[workspaceID] != nil else {
                workspaceWindows.removeValue(forKey: workspaceID)
                detachedWorkspaceIDs.remove(workspaceID)
                controller.closeFromOwner()
                continue
            }
            controller.refreshFromState()
        }
        restoreProtectedFocus(focusedInput)
    }

    /// Busy terminals / agent runs changed: refresh badge and Active Threads
    /// screen, coalesced to one pass per runloop turn.
    public func activeThreadsDidChange() {
        guard !hasPendingActiveThreadsChange else { return }
        hasPendingActiveThreadsChange = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingActiveThreadsChange = false
            self.sidebar.refreshActiveCount()
            self.activeThreadsViewModel?.refreshLive()
        }
    }

    /// H3: title-only change. Patches the matching tab label in place across the
    /// main and detached windows instead of a full refreshFromState pass.
    public func updateSurfaceTabTitle(_ surfaceID: SurfaceID, title: String) {
        for controller in paneControllers {
            controller.setTabTitle(surfaceID, title: title)
        }
        for controller in workspaceWindows.values {
            controller.updateSurfaceTabTitle(surfaceID, title: title)
        }
        // Busy tooltips read titles from the sidebar's workspace snapshot.
        sidebar.refresh()
    }

    public func refreshSurfaceRuntimeState() {
        sidebar.refresh()
        activeThreadsDidChange()
        for controller in paneControllers {
            controller.refreshBusyStates()
        }
        for controller in workspaceWindows.values {
            controller.refreshSurfaceRuntimeState()
        }
    }

    /// UX-MAC_SHELL_WINDOW-014: called once restored surfaces have been
    /// reinstantiated so subsequent empty states render as the normal
    /// no-workspace view rather than the restoring affordance.
    public func markRestorationComplete() {
        guard isRestoringLayout else { return }
        isRestoringLayout = false
        lastWorkspaceContainerSignature = nil
        refreshFromState()
    }

    public func detachedVisibleWorkspaceIDsForSurfaceReconciliation() -> Set<WorkspaceID> {
        Set(workspaceWindows.compactMap { workspaceID, controller in
            guard controller.window.isVisible,
                  context?.state.workspaces[workspaceID] != nil else { return nil }
            return workspaceID
        })
    }

    public func focusSurface(_ id: SurfaceID) {
        if let s = SurfaceRegistry.shared.surface(id) {
            s.focus()
        }
    }

    /// PERF-MAC_SHELL_WINDOW-125: focus-only fast path.
    ///
    /// When a tab selection or pane-focus change arrives, only the focused
    /// surface / pane highlight changed -- the structural layout (pane id set,
    /// surface id set, order) is unchanged. A full refreshFromState teardown is
    /// not needed; instead:
    ///   1. reconcilePaneControllersInPlace() patches each live strip's tab
    ///      highlight and scroll position in place.
    ///   2. focusSurface(_:) gives the surface first-responder focus.
    ///
    /// Fallback: when paneControllers is empty (first focus before any rebuild,
    /// initial mount) the RatioSplitView has not been created yet, so we must
    /// fall back to refreshFromState() to produce the initial container.
    ///
    /// Signature boundary: this method is only correct when the STRUCTURAL
    /// signature (workspace id, pane id set + order, surface id set + order)
    /// has NOT changed.  Callers (focusSurface/focusPane in AppCommandRouter)
    /// must only reach here after apply(.focusSurface) / apply(.focusPane)
    /// mutations -- mutations that, by contract, never alter the structural
    /// signature.
    public func applyFocusChangeInPlace(surfaceToFocus: SurfaceID?) {
        applyDetachedFocusChangeInPlace(surfaceToFocus: surfaceToFocus)
        if paneControllers.isEmpty {
            // Container not yet built (initial mount / first focus before any
            // rebuild). Fall back to full refresh so RatioSplitView is created.
            refreshFromState()
            return
        }
        reconcilePaneControllersInPlace()
        if let sid = surfaceToFocus {
            focusSurface(sid)
        }
        shellLog.debug("applyFocusChangeInPlace surface=\(surfaceToFocus.map { $0.value.uuidString } ?? "nil", privacy: .public)")
    }

    private func applyDetachedFocusChangeInPlace(surfaceToFocus: SurfaceID?) {
        guard let surfaceToFocus,
              let ctx = context,
              let workspaceID = ctx.state.workspaces.first(where: { _, workspace in
                  workspace.layout.paneIDs().contains { paneID in
                      workspace.layout.find(paneID: paneID)?.surfaces.contains { $0.id == surfaceToFocus } == true
                  }
              })?.key,
              let controller = workspaceWindows[workspaceID] else { return }
        controller.applyFocusChangeInPlace(surfaceToFocus: surfaceToFocus)
    }

    /// UX-MAC_SHELL_WINDOW-003: close the focused pane's selected surface
    /// (with its unsaved-changes confirm). Returns false when there is no
    /// surface to close so ⌘W can fall back to closing the window.
    ///
    /// `window` is the window that owns the keyboard (`AppDelegate` passes
    /// `NSApp.keyWindow`): a workspace detached into its own window owns its
    /// own panes, so ⌘W must close the tab the user is looking at rather than
    /// one in the main window behind it. `nil` keeps the main-window target.
    @discardableResult
    public func closeFocusedSurface(in window: NSWindow? = nil) -> Bool {
        if let detached = detachedWindowController(owning: window) {
            return detached.closeFocusedSurface()
        }
        // A key bot Desk/Guest window or an additional window presents no tab
        // of the workspace behind it, and ⌘W belongs to that window (returning
        // false closes it). Acting on `selectedWorkspaceID` here would close
        // and delete the persisted history of a surface the user cannot see.
        guard presentsWorkspacePanes(window) else { return false }
        // A shell destination (Bots / Schedule Tasks / Active Threads) hides
        // the workspace panes but keeps their controllers alive, so acting on
        // `selectedWorkspaceID` here would close a surface the user cannot
        // see — and that closes and deletes its persisted history.
        guard shellContentMode == .workspace else { return false }
        guard let ctx = context,
              let wid = ctx.state.window.selectedWorkspaceID,
              let ws = ctx.state.workspaces[wid],
              !detachedWorkspaceIDs.contains(wid) else { return false }
        return closeKeyboardTargetSurface(in: ws, controllers: paneControllers)
    }

    /// UX-MAC_SHELL_WINDOW-004: split the focused pane (defaulting to a
    /// Terminal surface) via the keyboard. Returns false when there is no
    /// focused pane controller to split. `window` follows the same
    /// keyboard-owner rule as `closeFocusedSurface(in:)`.
    @discardableResult
    public func splitFocusedPane(_ direction: SplitDirection, in window: NSWindow? = nil) -> Bool {
        if let detached = detachedWindowController(owning: window) {
            return detached.splitFocusedPane(direction)
        }
        // Same key-window rule as `closeFocusedSurface(in:)`: ⌘D over a bot or
        // additional window must not split the workspace behind it.
        guard presentsWorkspacePanes(window) else { return false }
        // Same off-screen target rule as `closeFocusedSurface()`: ⌘D must not
        // split a pane that a shell destination is covering.
        guard shellContentMode == .workspace else { return false }
        guard let ctx = context,
              let wid = ctx.state.window.selectedWorkspaceID,
              let ws = ctx.state.workspaces[wid],
              !detachedWorkspaceIDs.contains(wid) else { return false }
        return splitKeyboardTargetPane(direction, in: ws, controllers: paneControllers)
    }

    @discardableResult
    public func resizeFocusedPane(_ direction: SplitDirection) -> Bool {
        // Same off-screen target rule as `closeFocusedSurface()`. Detached
        // windows never reach this entry point: their own
        // `InteractiveTitlebarWindow` dispatches to their controller.
        guard shellContentMode == .workspace else { return false }
        guard let ctx = context,
              let wid = ctx.state.window.selectedWorkspaceID,
              let ws = ctx.state.workspaces[wid],
              !detachedWorkspaceIDs.contains(wid) else { return false }
        return resizeKeyboardTargetPane(direction, in: ws, controllers: paneControllers)
    }

    public func repairSelectedTerminalFocus(reason: String) {
        guard protectedFocusedView() == nil else { return }
        router?.repairSelectedTerminalFocus(reason: reason)
    }

    public var hasProtectedInputFocus: Bool {
        protectedFocusedView() != nil
    }

    static func protectedTextFocusOwner(firstResponder: NSResponder?, within workspaceContent: NSView) -> NSView? {
        if let textView = firstResponder as? NSTextView,
           textView.isDescendant(of: workspaceContent) {
            return textView
        }
        if let text = firstResponder as? NSText,
           let delegateView = text.delegate as? NSView,
           delegateView.isDescendant(of: workspaceContent) {
            return delegateView
        }
        return nil
    }

    private func protectedFocusedView() -> NSView? {
        Self.protectedTextFocusOwner(firstResponder: window.firstResponder, within: workspaceContent)
    }

    private func restoreProtectedFocus(_ focusedView: NSView?) {
        guard let focusedView,
              focusedView.window === window,
              focusedView.isDescendant(of: workspaceContent) else { return }
        window.makeFirstResponder(focusedView)
    }

    private var extraWindows: [WindowID: NSWindow] = [:]
    private var extraWindowAttachHandlers: [WindowID: OrphanWindowAttachHandler] = [:]

    public func openAdditionalWindow(for w: AppWindow) {
        if let existing = extraWindows[w.id] { existing.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = w.title
        win.configureRemoteCodeWindowAccessibility(title: w.title, identifier: "window.additional")
        RemoteCodeAppearance.apply(to: win)
        let handler = OrphanWindowAttachHandler(windowID: w.id, window: win, context: context, router: router)
        extraWindowAttachHandlers[w.id] = handler
        win.contentView = handler.buildEmptyStateView()
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        extraWindows[w.id] = win
    }

    public func openWorkspaceInNewWindow(_ workspaceID: WorkspaceID) {
        guard let ctx = context, let router, ctx.state.workspaces[workspaceID] != nil else { return }
        if let existing = workspaceWindows[workspaceID] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        detachedWorkspaceIDs.insert(workspaceID)
        shellLog.debug("workspace.detach id=\(workspaceID.value.uuidString, privacy: .public)")
        if ctx.state.window.selectedWorkspaceID == workspaceID,
           let fallback = ctx.state.window.workspaces.first(where: { $0 != workspaceID }) {
            try? router.selectWorkspace(fallback)
        } else {
            refreshFromState()
        }
        let controller = WorkspaceWindowController(
            workspaceID: workspaceID,
            context: ctx,
            router: router,
            onBack: { [weak self] in self?.returnWorkspaceToSidebar(workspaceID) },
            onClose: { [weak self] in self?.workspaceWindowClosed(workspaceID) }
        )
        workspaceWindows[workspaceID] = controller
        updateCollapsedWorkspaceHeader()
        controller.show()
        router.reconcileSurfaceVisibility()
        controller.repairSelectedTerminalFocus(reason: "detached_workspace_open")
    }

    public func workspaceWindow(for workspaceID: WorkspaceID) -> NSWindow? {
        workspaceWindows[workspaceID]?.window
    }

    /// The detached workspace window that owns `window`, when `window` is one
    /// of the workspaces detached into its own window. `nil` for the main
    /// window, for `nil`, and for any other window (Settings, bot windows).
    private func detachedWindowController(owning window: NSWindow?) -> WorkspaceWindowController? {
        guard let window else { return nil }
        return workspaceWindows.values.first { $0.window === window }
    }

    /// The workspace a detached window presents; `nil` for the main window, for
    /// `nil`, and for any other window (Settings, bot windows).
    private func detachedWorkspaceID(owning window: NSWindow?) -> WorkspaceID? {
        guard let window else { return nil }
        return workspaceWindows.first { $0.value.window === window }?.key
    }

    /// Whether the keyboard target `window` presents this controller's
    /// workspace panes. `nil` and the main window do; a detached workspace
    /// window does. A bot Desk/Guest window or an additional window does not:
    /// it owns the keyboard but shows no tab of the workspace behind it, so
    /// ⌘W/⌘D must fall through to that window instead of the hidden workspace.
    /// Sheets and child windows keep the previous main-window target.
    private func presentsWorkspacePanes(_ window: NSWindow?) -> Bool {
        guard let window else { return true }
        if window === self.window { return true }
        if detachedWorkspaceID(owning: window) != nil { return true }
        return window.sheetParent != nil || window.parent != nil
    }

    /// UX-MAC_SHELL_WINDOW-002/003: the workspace whose tabs ⌘⇧[ / ⌘⇧] / ⌘1..9
    /// step through. The key window picks it, and `nil` means "no target": a
    /// detached workspace window owns its own tabs, while a bot/additional
    /// window owns none, so the command must not step the tabs of the workspace
    /// behind it. A shell destination covering the workspace is refused for the
    /// same reason as ⌘W/⌘D: the tabs are not on screen.
    public func tabNavigationWorkspace(in window: NSWindow? = nil) -> WorkspaceID? {
        if let detachedID = detachedWorkspaceID(owning: window) { return detachedID }
        guard presentsWorkspacePanes(window), shellContentMode == .workspace else { return nil }
        return context?.state.window.selectedWorkspaceID
    }

    public func isWorkspaceOpenInNewWindow(_ workspaceID: WorkspaceID) -> Bool {
        workspaceWindows[workspaceID] != nil
    }

    public func openBotInNewWindow(_ botID: BotID) {
        guard let ctx = context, let router else { return }
        guard (try? ctx.botStore.get(id: botID)) != nil else { return }
        if let existing = botWindows[botID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = BotDeskWindowController(
            botID: botID,
            context: ctx,
            router: router,
            onClose: { [weak self] in self?.botWindowClosed(botID) }
        )
        botWindows[botID] = controller
        controller.show()
    }

    public func botWindow(for botID: BotID) -> NSWindow? {
        botWindows[botID]?.window
    }

    public func openBotGuestDesktopInNewWindow(_ botID: BotID) {
        guard let ctx = context, let router else { return }
        guard (try? ctx.botStore.get(id: botID)) != nil else { return }
        if let existing = botGuestWindows[botID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = BotGuestDesktopWindowController(
            botID: botID,
            context: ctx,
            router: router,
            onClose: { [weak self] in self?.botGuestWindowClosed(botID) }
        )
        botGuestWindows[botID] = controller
        controller.show()
    }

    public func botGuestDesktopWindow(for botID: BotID) -> NSWindow? {
        botGuestWindows[botID]?.window
    }

    private func botWindowClosed(_ botID: BotID) {
        botWindows.removeValue(forKey: botID)
    }

    private func botGuestWindowClosed(_ botID: BotID) {
        botGuestWindows.removeValue(forKey: botID)
    }

    private func returnWorkspaceToSidebar(_ workspaceID: WorkspaceID) {
        shellLog.debug("workspace.return id=\(workspaceID.value.uuidString, privacy: .public)")
        let controller = workspaceWindows.removeValue(forKey: workspaceID)
        detachedWorkspaceIDs.remove(workspaceID)
        if sidebarCollapsed {
            handleToggleSidebar()
        }
        try? router?.selectWorkspace(workspaceID)
        refreshFromState()
        window.makeKeyAndOrderFront(nil)
        controller?.closeFromOwner()
        router?.reconcileSurfaceVisibility()
        repairSelectedTerminalFocus(reason: "detached_workspace_return")
    }

    private func workspaceWindowClosed(_ workspaceID: WorkspaceID) {
        shellLog.debug("workspace.windowClosed id=\(workspaceID.value.uuidString, privacy: .public)")
        workspaceWindows.removeValue(forKey: workspaceID)
        detachedWorkspaceIDs.remove(workspaceID)
        if context?.state.workspaces[workspaceID] != nil {
            try? router?.selectWorkspace(workspaceID)
        }
        refreshFromState()
        window.makeKeyAndOrderFront(nil)
        router?.reconcileSurfaceVisibility()
        repairSelectedTerminalFocus(reason: "detached_workspace_close")
    }

    /// UX: Schedule Tasks opens in the main content column (same place as
    /// workspace panes), not a floating NSWindow. Workspace rows are fully
    /// deselected and the title bar reads "Schedule Tasks".
    func presentScheduledTasksInMainContent() {
        guard shellContentMode != .scheduledTasks else {
            scheduledTasksViewModel?.scheduleFreshnessPass()
            return
        }
        shellContentMode = .scheduledTasks
        sidebar.setScheduledTasksSelected(true)
        sidebar.setActiveThreadsSelected(false)
        sidebar.setBotsSelected(false)
        sidebar.setSettingsSelected(false)
        persistBotsShellDestination()
        installScheduledTasksContent()
        updateCollapsedWorkspaceHeader()
        shellLog.debug("shellContentMode=scheduledTasks")
    }

    /// Settings shell destination: System Settings-style categories in the main
    /// content column. A non-nil route selects its category first.
    func presentSettingsInMainContent(route: PetSettingsRoute? = nil) {
        if let route, let vm = settingsShellViewModel() {
            vm.select(route: route)
        }
        guard shellContentMode != .settings else {
            scheduleSettingsFreshnessPass()
            return
        }
        shellContentMode = .settings
        sidebar.setSettingsSelected(true)
        sidebar.setScheduledTasksSelected(false)
        sidebar.setActiveThreadsSelected(false)
        sidebar.setBotsSelected(false)
        persistBotsShellDestination()
        installSettingsContent()
        updateCollapsedWorkspaceHeader()
        shellLog.debug("shellContentMode=settings")
    }

    func openActivityRoute(intent: NotificationRouteIntent) {
        presentActiveThreadsInMainContent()
        activeThreadsViewModel?.pendingActivityRoute = intent
    }

    /// Active Threads shell destination: live actives + recent finished runs.
    func presentActiveThreadsInMainContent() {
        guard shellContentMode != .activeThreads else {
            activeThreadsViewModel?.scheduleFreshnessPass()
            return
        }
        shellContentMode = .activeThreads
        sidebar.setActiveThreadsSelected(true)
        sidebar.setScheduledTasksSelected(false)
        sidebar.setBotsSelected(false)
        sidebar.setSettingsSelected(false)
        persistBotsShellDestination()
        installActiveThreadsContent()
        updateCollapsedWorkspaceHeader()
        shellLog.debug("shellContentMode=activeThreads")
    }

    /// Bots shell destination: Fleet / Studio / Desk / Attention.
    func presentBotsInMainContent() {
        guard shellContentMode != .bots else { return }
        shellContentMode = .bots
        sidebar.setBotsSelected(true)
        sidebar.setScheduledTasksSelected(false)
        sidebar.setActiveThreadsSelected(false)
        sidebar.setSettingsSelected(false)
        persistBotsShellDestination()
        installBotsContent()
        updateCollapsedWorkspaceHeader()
        shellLog.debug("shellContentMode=bots")
    }

    /// Return the main content column to the selected workspace layout.
    func presentWorkspaceContent() {
        guard shellContentMode != .workspace else { return }
        shellContentMode = .workspace
        sidebar.setScheduledTasksSelected(false)
        sidebar.setActiveThreadsSelected(false)
        sidebar.setBotsSelected(false)
        sidebar.setSettingsSelected(false)
        persistBotsShellDestination()
        currentShellHostingView?.removeFromSuperview()
        currentShellHostingView = nil
        let selectedWorkspaceID = context?.state.window.selectedWorkspaceID
        let cachedWorkspaceIsCurrent = cachedWorkspaceID == selectedWorkspaceID
        cachedWorkspaceContentViews.forEach { $0.isHidden = !cachedWorkspaceIsCurrent }
        if !cachedWorkspaceIsCurrent || cachedWorkspaceContentViews.isEmpty {
            scheduleWorkspaceRebuild()
        } else if workspaceContainerSignature() != lastWorkspaceContainerSignature {
            scheduleWorkspaceRebuild()
        }
        updateCollapsedWorkspaceHeader()
        shellLog.debug("shellContentMode=workspace")
    }

    private func installScheduledTasksContent() {
        guard let context, let router else {
            let empty = makeEmptyState()
            workspaceContent.addSubview(empty)
            pin(empty, to: workspaceContent)
            return
        }
        let vm = scheduledTasksViewModel ?? ScheduledTasksViewModel(
            context: context,
            router: router,
            loadImmediately: false
        )
        scheduledTasksViewModel = vm
        vm.setVisible(true)
        vm.scheduleFreshnessPass()
        if let existing = scheduledTasksHostingView {
            attachShellHost(existing)
            return
        }
        let host = NSHostingView(rootView: ScheduledTasksRootView(vm: vm, botsVM: sidebar.botsViewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = DS.NS.bg.cgColor
        RemoteCodeAppearance.apply(to: host)
        scheduledTasksHostingView = host
        attachShellHost(host)
    }

    private func settingsShellViewModel() -> SettingsViewModel? {
        if let settingsViewModel { return settingsViewModel }
        guard let context else { return nil }
        let vm = (NSApp.delegate as? AppDelegate)?.settings?.viewModel
            ?? SettingsViewModel(context: context, loadImmediately: false)
        settingsViewModel = vm
        return vm
    }

    private func installSettingsContent() {
        guard let vm = settingsShellViewModel() else {
            let empty = makeEmptyState()
            workspaceContent.addSubview(empty)
            pin(empty, to: workspaceContent)
            return
        }
        scheduleSettingsFreshnessPass()
        if let existing = settingsHostingView {
            attachShellHost(existing)
            return
        }
        let host = NSHostingView(rootView: SettingsView(vm: vm, onClose: nil))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = DS.NS.bg.cgColor
        RemoteCodeAppearance.apply(to: host)
        settingsHostingView = host
        attachShellHost(host)
    }

    /// Latest-wins: a newer presenter call cancels the pending pass.
    private func scheduleSettingsFreshnessPass() {
        guard let vm = settingsViewModel else { return }
        settingsFreshnessTask?.cancel()
        settingsFreshnessGeneration &+= 1
        let generation = settingsFreshnessGeneration
        settingsFreshnessTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self, !Task.isCancelled, self.settingsFreshnessGeneration == generation,
                  self.shellContentMode == .settings else { return }
            self.settingsFreshnessTask = nil
            vm.reload()
            await vm.refreshNotificationStatus()
        }
    }

    private func installActiveThreadsContent() {
        guard let context, let router else {
            let empty = makeEmptyState()
            workspaceContent.addSubview(empty)
            pin(empty, to: workspaceContent)
            return
        }
        let vm = activeThreadsViewModel ?? ActiveThreadsViewModel(
            context: context,
            router: router,
            loadImmediately: false
        )
        activeThreadsViewModel = vm
        vm.scheduleFreshnessPass()
        if let existing = activeThreadsHostingView {
            attachShellHost(existing)
            return
        }
        let host = NSHostingView(rootView: ActiveThreadsRootView(vm: vm, botsVM: sidebar.botsViewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = DS.NS.bg.cgColor
        RemoteCodeAppearance.apply(to: host)
        activeThreadsHostingView = host
        attachShellHost(host)
    }

    private func installBotsContent() {
        guard context != nil, router != nil else {
            let empty = makeEmptyState()
            workspaceContent.addSubview(empty)
            pin(empty, to: workspaceContent)
            return
        }
        let vm = sidebar.botsViewModel
        botsViewModel = vm
        vm.enableNavigationFirstFrameDeferral()
        vm.onLeaveBots = { [weak self] in
            self?.presentWorkspaceContent()
        }
        // Keep Desk / Studio / Attention. openFleet() here kicked users
        // home every time they left Bots and came back.
        if let existing = botsHostingView {
            attachShellHost(existing)
            vm.scheduleFreshnessPass()
            return
        }
        let host = makeBotsShellHost(vm: vm)
        botsHostingView = host
        attachShellHost(host)
    }

    /// Reattach a retained shell host. Leaving Workspaces/Bots only
    /// removeFromSuperviews; rebuilding workspace must not see these views
    /// as children, or it would wipe the kept instance.
    private func attachShellHost(_ host: NSView) {
        let previous = currentShellHostingView
        if previous !== host {
            prepareShellMount(previous)
        } else {
            cachedWorkspaceContentViews.forEach { $0.isHidden = true }
        }
        if host.superview !== workspaceContent {
            workspaceContent.addSubview(host)
            pin(host, to: workspaceContent)
        }
        host.isHidden = false
        currentShellHostingView = host
        if previous !== host {
            removePreviousShellHostAfterFirstFrame(previous)
        }
    }

    private func makeBotsShellHost(vm: BotsViewModel) -> NSView {
        let host = ContentColumnHostingView(rootView: BotsRootView(vm: vm))
        host.cancelHorizontalTitlebarGutter = BotsViewModel.cancelsWindowLeadingTitlebarGutter(
            presentsAsDetachedWindow: vm.presentsAsDetachedWindow
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = DS.NS.bg.cgColor
        RemoteCodeAppearance.apply(to: host)
        return host
    }

    private func prepareShellMount(_ previous: NSView?) {
        cachedWorkspaceContentViews.forEach { $0.isHidden = true }
        previous?.isHidden = true
    }

    private func removePreviousShellHostAfterFirstFrame(_ previous: NSView?) {
        guard let previous, previous !== currentShellHostingView else { return }
        DispatchQueue.main.async { [weak self, weak previous] in
            guard let previous else { return }
            previous.removeFromSuperview()
        }
    }

    private static func waitForCommittedFrame() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func scheduleWorkspaceRebuild() {
        workspaceRebuildTask?.cancel()
        workspaceRebuildGeneration &+= 1
        let generation = workspaceRebuildGeneration
        workspaceRebuildTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer {
                if self.workspaceRebuildGeneration == generation {
                    self.workspaceRebuildTask = nil
                }
            }
            guard !Task.isCancelled,
                  self.workspaceRebuildGeneration == generation,
                  self.shellContentMode == .workspace else { return }
            // Let rebuildWorkspaceContainer inspect its structural fingerprint
            // first. A refresh may already have won the race and reconciled the
            // existing cached tree in place; removing that cache here would make
            // the idempotent pass paint an empty content column.
            self.rebuildWorkspaceContainer()
        }
    }

    private func rebuildWorkspaceContainer() {
        // Keep Schedule Tasks / Active Threads / Bots mounted across refreshFromState
        // bursts while the user is on that shell destination.
        if shellContentMode == .scheduledTasks {
            if scheduledTasksHostingView?.superview === workspaceContent {
                scheduledTasksViewModel?.scheduleFreshnessPass()
                return
            }
            installScheduledTasksContent()
            return
        }
        if shellContentMode == .activeThreads {
            if activeThreadsHostingView?.superview === workspaceContent {
                activeThreadsViewModel?.scheduleFreshnessPass()
                return
            }
            installActiveThreadsContent()
            return
        }
        if shellContentMode == .settings {
            if settingsHostingView?.superview === workspaceContent {
                scheduleSettingsFreshnessPass()
                return
            }
            installSettingsContent()
            return
        }
        if shellContentMode == .bots {
            if botsHostingView?.superview === workspaceContent {
                botsViewModel?.scheduleFreshnessPass()
                return
            }
            installBotsContent()
            return
        }

        // PERF-MAC_SHELL_WINDOW-002: a refresh whose layout signature
        // matches the live tree (e.g. app become-key/active/reopen) does
        // not need a teardown/rebuild — the existing pane controllers are
        // already correct.
        let signature = workspaceContainerSignature()
        if signature == lastWorkspaceContainerSignature, !paneControllers.isEmpty {
            // P1: structure unchanged. Selection/title/color/dirty are NOT
            // in the structural signature, so patch each live pane strip in
            // place via PaneTabsView.reconcile(to:) (diffTabs seam) instead
            // of tearing the container down -- this is what removes the
            // resize-end strip flash on focus/rename/color changes.
            // PERF-MAC_SHELL_WINDOW-MED-126: ratios are also excluded from the
            // structural signature. When only ratios changed (divider mouse-up),
            // apply them in place on the live RatioSplitView tree instead of
            // re-parenting surfaces.
            if let ctx = context,
               let wid = ctx.state.window.selectedWorkspaceID,
               !detachedWorkspaceIDs.contains(wid),
               let ws = ctx.state.workspaces[wid],
               let rootView = workspaceContent.subviews.first {
                Self.applyRatiosInPlace(view: rootView, node: ws.layout)
            }
            reconcilePaneControllersInPlace()
            shellLog.debug("rebuildWorkspaceContainer reconciled in place (structure unchanged)")
            return
        }
        lastWorkspaceContainerSignature = signature
        rebuildCount += 1
        let rebuildStart = DispatchTime.now()

        window.disableScreenUpdatesUntilFlush()
        for sub in workspaceContent.subviews { sub.removeFromSuperview() }
        // Drop references to the previous pane controllers; new ones are
        // created below. Without retaining them their @objc button/tab
        // targets are deallocated and clicks silently no-op.
        paneControllers.removeAll()
        guard let ctx = context,
              let wid = ctx.state.window.selectedWorkspaceID,
              let ws = ctx.state.workspaces[wid],
              !detachedWorkspaceIDs.contains(wid) else {
            // UX-MAC_SHELL_WINDOW-014: during launch restoration, show a
            // "Restoring workspaces…" affordance when state has workspaces
            // but their surfaces are not reinstantiated yet.
            let hasWorkspaces = !(context?.state.window.workspaces.isEmpty ?? true)
            let empty = (isRestoringLayout && hasWorkspaces) ? makeRestoringState() : makeEmptyState()
            workspaceContent.addSubview(empty)
            pin(empty, to: workspaceContent)
            shellLog.debug("rebuildWorkspaceContainer empty restoring=\(self.isRestoringLayout && hasWorkspaces, privacy: .public)")
            return
        }
        var primaryControlsAvailable = true
        let layoutView = buildLayoutView(node: ws.layout, primaryControlsAvailable: &primaryControlsAvailable)
        attachRootLayoutView(layoutView)
        cachedWorkspaceContentViews = [layoutView]
        cachedWorkspaceID = wid
        let rebuildMs = Double(DispatchTime.now().uptimeNanoseconds - rebuildStart.uptimeNanoseconds) / 1_000_000
        shellLog.debug("rebuildWorkspaceContainer panes=\(self.paneControllers.count, privacy: .public) ms=\(rebuildMs, privacy: .public)")
        // Freshly built pane headers default to "sidebar visible"; if it
        // is actually collapsed, re-sync them so the workspace name shows.
        if sidebarCollapsed {
            NotificationCenter.default.post(
                name: .rc2SidebarVisibility, object: nil,
                userInfo: ["collapsed": true])
        }
    }

    /// P1: applies non-structural changes (selection / title / color /
    /// dirty) to the existing pane strips in place. Reached only when the
    /// structural signature is unchanged, so every controller's pane still
    /// exists in the live layout with the same id set/order.
    private func reconcilePaneControllersInPlace() {
        guard let ctx = context,
              let wid = ctx.state.window.selectedWorkspaceID,
              let ws = ctx.state.workspaces[wid] else { return }
        for controller in paneControllers {
            guard let freshPane = ws.layout.find(paneID: controller.pane.id) else { continue }
            controller.reconcile(to: freshPane)
        }
    }

    /// Structural fingerprint of what `rebuildWorkspaceContainer` would
    /// produce: selected workspace, sidebar/detached state, and the
    /// pane/surface shape (id set + order) of the layout tree.
    private func workspaceContainerSignature() -> String {
        guard let ctx = context,
              let wid = ctx.state.window.selectedWorkspaceID,
              let ws = ctx.state.workspaces[wid],
              !detachedWorkspaceIDs.contains(wid) else {
            return "empty"
        }
        var parts: [String] = ["ws:\(wid.value.uuidString)", "collapsed:\(sidebarCollapsed)"]
        Self.appendLayoutSignature(ws.layout, into: &parts)
        return parts.joined(separator: "|")
    }

    fileprivate static func appendLayoutSignature(_ node: LayoutNode, into parts: inout [String]) {
        switch node {
        case .pane(let p):
            // P1: STRUCTURAL fingerprint only -- pane id + ordered surface
            // id SET. Selection and title are deliberately excluded so a
            // focus/rename does NOT trigger a full teardown; those are
            // applied in place by PaneTabsView.reconcile(to:) (driven by
            // the diffTabs seam). Only an id-set/order change rebuilds.
            // Ratios are intentionally excluded: a ratio-only change is
            // applied in place by applyRatiosInPlace (PERF-MAC_SHELL_WINDOW-MED-126)
            // and must NOT trigger a teardown/rebuild.
            let surfaces = p.surfaces.map { $0.id.value.uuidString }.joined(separator: ",")
            parts.append("pane(\(p.id.value.uuidString);[\(surfaces)])")
        case .split(let s):
            // Ratios excluded from structural signature: ratio-only changes are
            // applied in place without a rebuild (PERF-MAC_SHELL_WINDOW-MED-126).
            // Minimized state is chrome-affecting, though: PaneTabsView swaps
            // controls/content when a pane crosses the threshold, so that
            // boundary must rebuild while ordinary ratio changes stay in-place.
            let minimized = s.ratios.indices.map {
                PaneTabsView.isPaneMinimized(paneIndex: $0, ratios: s.ratios) ? "1" : "0"
            }.joined(separator: ",")
            parts.append("split(\(s.orientation);\(s.id.uuidString);min:[\(minimized)]{")
            for child in s.children { appendLayoutSignature(child, into: &parts) }
            parts.append("}")
        }
    }

    // PERF-MAC_SHELL_WINDOW-MED-126: pure seam — given two layout trees with
    // the same structure (same split ids / child count / orientation / pane ids),
    // returns true when they differ only in split ratios. This is the boundary
    // condition that gates the in-place apply: if this returns false, a genuine
    // structural change has occurred and a full rebuild is required.
    static func ratiosOnlyChanged(old: LayoutNode, new: LayoutNode) -> Bool {
        switch (old, new) {
        case (.pane(let op), .pane(let np)):
            // Panes have no ratios; if ids / surface ids match, nothing changed.
            return op.id == np.id
                && op.surfaces.map(\.id) == np.surfaces.map(\.id)
        case (.split(let os), .split(let ns)):
            guard os.id == ns.id,
                  os.orientation == ns.orientation,
                  os.children.count == ns.children.count else { return false }
            return zip(os.children, ns.children).allSatisfy { ratiosOnlyChanged(old: $0, new: $1) }
        default:
            return false
        }
    }

    // PERF-MAC_SHELL_WINDOW-MED-126: walk the live RatioSplitView tree rooted
    // at `view` and apply new ratios from `node` in place. Called only when
    // ratiosOnlyChanged confirmed a ratio-only update — no views are added,
    // removed, or re-parented.
    fileprivate static func applyRatiosInPlace(view: NSView, node: LayoutNode) {
        if case .split(let s) = node, let split = view as? RatioSplitView {
            split.ratios = s.ratios.map { CGFloat($0) }
            split.relayoutNow()
            for (child, childNode) in zip(split.subviews, s.children) {
                applyRatiosInPlace(view: child, node: childNode)
            }
        }
        // .pane nodes have no ratios; leaf NSViews (PaneRootView) are left as-is.
    }

    private func attachRootLayoutView(_ layoutView: NSView) {
        layoutView.translatesAutoresizingMaskIntoConstraints = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            workspaceContent.addSubview(layoutView)
            NSLayoutConstraint.activate([
                layoutView.topAnchor.constraint(equalTo: workspaceContent.topAnchor),
                layoutView.bottomAnchor.constraint(equalTo: workspaceContent.bottomAnchor),
                layoutView.leadingAnchor.constraint(equalTo: workspaceContent.leadingAnchor),
                layoutView.trailingAnchor.constraint(equalTo: workspaceContent.trailingAnchor)
            ])
            layoutView.needsLayout = true
            layoutView.layoutSubtreeIfNeeded()
            if let split = layoutView as? RatioSplitView {
                split.relayoutNow()
            }
        }
    }

    private func makeEmptyState() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .light)
        icon.contentTintColor = DS.NS.textTertiary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L("No workspace selected"))
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = DS.NS.textSecondary
        title.translatesAutoresizingMaskIntoConstraints = false

        let sub = NSTextField(labelWithString: L("Open a folder as a workspace to get started."))
        sub.font = NSFont.systemFont(ofSize: 12)
        sub.textColor = DS.NS.textTertiary
        sub.alignment = .center
        sub.translatesAutoresizingMaskIntoConstraints = false

        // UX-MAC_SHELL_WINDOW-010: an actionable button instead of copy
        // that points at a control which may be off-screen when collapsed.
        let action = NSButton(title: L("New Workspace"), target: self, action: #selector(newWorkspace))
        action.bezelStyle = .rounded
        action.keyEquivalent = "\r"
        action.translatesAutoresizingMaskIntoConstraints = false
        action.setAccessibilityIdentifier("shell.emptyState.newWorkspace")

        let stack = NSStackView(views: [icon, title, sub, action])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: sub)
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        return v
    }

    private func buildLayoutView(node: LayoutNode, primaryControlsAvailable: inout Bool, splitContext: PaneSplitContext? = nil) -> NSView {
        switch node {
        case .pane(let p):
            let showsWorkspaceControls = primaryControlsAvailable
            primaryControlsAvailable = false
            let ptv = PaneTabsView(
                pane: p,
                router: router,
                showsWorkspaceControls: showsWorkspaceControls,
                splitContext: splitContext
            )
            paneControllers.append(ptv)
            return ptv.view
        case .split(let s):
            let split = RatioSplitView()
            split.isVertical = (s.orientation == .horizontal)
            split.dividerStyle = .thin
            split.ratios = s.ratios.map { CGFloat($0) }
            let splitID = s.id
            if let wid = context?.state.window.selectedWorkspaceID {
                split.onRatiosChanged = { [weak self] ratios in
                    try? self?.router?.paneResize(workspace: wid, splitID: splitID, ratios: ratios.map(Double.init))
                }
            }
            for (index, child) in s.children.enumerated() {
                let childSplitContext = PaneSplitContext(splitID: s.id, paneIndex: index, ratios: s.ratios, orientation: s.orientation)
                let cv = buildLayoutView(node: child, primaryControlsAvailable: &primaryControlsAvailable, splitContext: childSplitContext)
                // Frame-managed (NOT arranged / NOT autolayout): the
                // RatioSplitView owns every subview frame so the split
                // is exactly proportional.
                cv.translatesAutoresizingMaskIntoConstraints = true
                cv.autoresizingMask = []
                split.addSubview(cv)
            }
            return split
        }
    }

    private func pin(_ child: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        ])
    }

    /// UX-MAC_SHELL_WINDOW-014: a brief restoring affordance shown while a
    /// saved layout is being reinstantiated, so a large restore does not
    /// flash the bare "No workspace selected" empty state.
    private func makeRestoringState() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L("Restoring workspaces…"))
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = DS.NS.textSecondary
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        return v
    }

    // MARK: NSWindowDelegate
    public func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === window {
            context?.saveSnapshot()
            disableInsomniaForAppClose()
        } else {
            extraWindowAttachHandlers = extraWindowAttachHandlers.filter { $0.value.window !== closing }
            extraWindows = extraWindowsRemoving(closing, from: extraWindows)
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Extra windows (openAdditionalWindow) are allowed to close normally;
        // windowWillClose handles removing them from extraWindows.
        guard sender === window else { return true }
        context?.saveSnapshot()
        sender.orderOut(nil)
        router?.reconcileSurfaceVisibility()
        return false
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        repairSelectedTerminalFocus(reason: "main_window_key")
    }

    static func storedSidebarWidth(context: AppContext) -> CGFloat {
        guard let raw = (try? context.settingsRepo.get(sidebarWidthSettingsKey)) ?? nil,
              let value = Double(raw) else {
            return defaultSidebarWidth
        }
        // Whole pixels: a fractional stored width would put the sidebar
        // seam on a half pixel and antialias it into a blurry line.
        return min(560, max(180, CGFloat(value).rounded()))
    }

    private static func storedSidebarCollapsed(context: AppContext) -> Bool {
        ((try? context.settingsRepo.get(sidebarCollapsedSettingsKey)) ?? nil) == "1"
    }

    private func persistBotsShellDestination() {
        let value: String
        switch shellContentMode {
        case .bots: value = "bots"
        case .scheduledTasks: value = "scheduledTasks"
        case .activeThreads: value = "activeThreads"
        case .settings: value = "settings"
        case .workspace: value = "workspace"
        }
        // Construction/restoration tests and first-launch setup happen before
        // the window is visible; retain their crash-safe synchronous receipt.
        // User clicks on a live shell window take the deferred path below.
        guard window.isVisible else {
            try? context?.settingsRepo.set(Self.botsShellSettingsKey, value)
            return
        }
        destinationPersistenceTask?.cancel()
        destinationPersistenceTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self, !Task.isCancelled else { return }
            try? self.context?.settingsRepo.set(Self.botsShellSettingsKey, value)
            self.destinationPersistenceTask = nil
        }
    }

    private func restoreBotsShellDestinationIfNeeded() {
        let raw = (try? context?.settingsRepo.get(Self.botsShellSettingsKey)) ?? nil
        switch raw {
        case "1", "bots":
            presentBotsInMainContent()
        case "scheduledTasks":
            presentScheduledTasksInMainContent()
        case "activeThreads":
            presentActiveThreadsInMainContent()
        case "settings":
            presentSettingsInMainContent()
        default:
            break
        }
    }
}

/// Bots in the main split inherits the window's traffic-light leading
/// inset even though that gutter already lives in the sidebar. Zero it
/// so Desk identity padding is only `DS.Space.xl`.
final class ContentColumnHostingView<Root: View>: NSHostingView<Root> {
    var cancelHorizontalTitlebarGutter = false

    override var safeAreaInsets: NSEdgeInsets {
        var insets = super.safeAreaInsets
        if cancelHorizontalTitlebarGutter {
            insets.left = 0
            insets.right = 0
        }
        return insets
    }

}

// MARK: - Sidebar resize handle

/// Invisible 5pt grab strip on the sidebar seam — the seam has no
/// divider strip (the 1px NSSplitView divider was the "strange line"),
/// so this is the only resize affordance. Writes nothing while
/// dragging; the controller persists once on mouse up.
final class SidebarResizeHandleView: NSView {
    var currentWidth: (() -> CGFloat)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStartWidth: CGFloat = 0
    private var dragStartX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartWidth = currentWidth?() ?? 0
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(dragStartWidth + (event.locationInWindow.x - dragStartX))
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

// MARK: - Refresh coalesce decision helper

/// Returns whether a new async refresh flush should be scheduled.
///
/// Contract (enforced by RefreshCoalesceDecisionTests):
///   - Returns true when no flush is pending (first or post-flush request).
///   - Returns false when a flush is already pending (burst suppression).
///
/// Pure function: no side effects, no AppKit, no @MainActor needed.
/// MainWindowController uses this to coalesce multiple refreshFromState()
/// calls that arrive within the same runloop tick into a single flush,
/// avoiding one sidebar.refresh() + signature walk per agent event.
nonisolated func refreshCoalesceShouldSchedule(wasPending: Bool) -> Bool {
    !wasPending
}

// MARK: - Detached workspace frame autosave helper

/// Returns the AppKit frameAutosaveName for a detached workspace window.
///
/// Contract (all enforced by DetachedFrameAutosaveNameTests):
///   - Stable: same workspaceID always returns the same string.
///   - Unique: distinct IDs produce distinct names.
///   - Namespaced under "io.remotecode.detachedWorkspace." so it cannot
///     collide with the main window key ("io.remotecode.mainWindow").
///
/// Pure function: no AppKit interaction, no side effects.
/// Called from WorkspaceWindowController.init so the detached window
/// restores its frame across launches just like the main window does.
func detachedFrameAutosaveName(workspaceID: WorkspaceID) -> String {
    "io.remotecode.detachedWorkspace.\(workspaceID.value.uuidString)"
}

/// Returns a new dictionary identical to `windows` with every entry whose
/// value is `closing` removed.
///
/// Pure function: no AppKit side-effects, no state captured.
/// Extracted so the removal policy is unit-testable without AppKit/MainActor.
///
/// WHY: closed extra windows were retained forever because the dict held the
/// only strong reference; removing on close lets ARC deallocate them.
nonisolated func extraWindowsRemoving(
    _ closing: NSWindow,
    from windows: [WindowID: NSWindow]
) -> [WindowID: NSWindow] {
    windows.filter { $0.value !== closing }
}

/// Manages the in-GUI affordance for orphan extra windows (windows with no
/// attached workspace). Presents an "Attach Workspace..." popup button that
/// lists all known workspaces and moves the selected one into this window via
/// router.moveWorkspaceToWindow -- the same path used by the sidebar / CLI.
///
/// WHY: raw instruction text ("use the sidebar / CLI") is invisible to users
/// who create an extra window via the GUI. The popup replaces the instruction
/// with an actionable control that calls the existing attach action directly.
@MainActor
private final class OrphanWindowAttachHandler: NSObject {
    let window: NSWindow
    private let windowID: WindowID
    private weak var context: AppContext?
    private weak var router: AppCommandRouter?
    private var popup: NSPopUpButton?

    init(windowID: WindowID, window: NSWindow, context: AppContext?, router: AppCommandRouter?) {
        self.windowID = windowID
        self.window = window
        self.context = context
        self.router = router
    }

    func buildEmptyStateView() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = DS.NS.textTertiary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L("No workspace attached"))
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = DS.NS.textSecondary
        title.translatesAutoresizingMaskIntoConstraints = false

        let sub = NSTextField(labelWithString: L("Attach an existing workspace to this window,\nor use the sidebar / CLI (rc2 workspace.move_to_window)."))
        sub.font = NSFont.systemFont(ofSize: 12)
        sub.textColor = DS.NS.textTertiary
        sub.alignment = .center
        sub.maximumNumberOfLines = 0
        sub.translatesAutoresizingMaskIntoConstraints = false

        let btn = NSPopUpButton(frame: .zero, pullsDown: false)
        btn.setAccessibilityIdentifier("orphanWindow.attachWorkspace")
        btn.translatesAutoresizingMaskIntoConstraints = false
        rebuildPopupItems(btn)
        btn.target = self
        btn.action = #selector(attachWorkspaceSelected(_:))
        self.popup = btn

        let stack = NSStackView(views: [icon, title, sub, btn])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(16, after: sub)
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        return v
    }

    private func rebuildPopupItems(_ btn: NSPopUpButton) {
        btn.removeAllItems()
        let workspaces = context?.state.workspaces.values.sorted { $0.name < $1.name } ?? []
        if workspaces.isEmpty {
            btn.addItem(withTitle: L("No workspaces available"))
            btn.item(at: 0)?.isEnabled = false
        } else {
            btn.addItem(withTitle: L("Attach Workspace..."))
            btn.item(at: 0)?.isEnabled = false
            for ws in workspaces {
                let item = NSMenuItem(title: ws.name.isEmpty ? "Untitled" : ws.name, action: nil, keyEquivalent: "")
                item.representedObject = ws.id
                btn.menu?.addItem(item)
            }
        }
    }

    @objc private func attachWorkspaceSelected(_ sender: NSPopUpButton) {
        guard let wsID = sender.selectedItem?.representedObject as? WorkspaceID,
              let router else { return }
        do {
            try router.moveWorkspaceToWindow(workspace: wsID, target: windowID)
            let wsName = context?.state.workspaces[wsID]?.name ?? L("Workspace")
            updateToAttachedState(workspaceName: wsName)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not attach workspace")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateToAttachedState(workspaceName: String) {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = DS.NS.textTertiary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L("\"%1$@\" attached to this window.", workspaceName))
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = DS.NS.textSecondary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        window.contentView = v
        window.title = workspaceName
    }
}

@MainActor
private final class WorkspaceWindowController: NSObject, NSWindowDelegate, PaneKeyboardResizeHandling {
    let window: NSWindow
    private let workspaceID: WorkspaceID
    private weak var context: AppContext?
    private weak var router: AppCommandRouter?
    private let content = NSView()
    private let workspaceContent = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var paneControllers: [PaneTabsView] = []
    private var lastLayoutSignature: String?
    private var closingFromOwner = false
    private let onBack: () -> Void
    private let onClose: () -> Void

    init(workspaceID: WorkspaceID, context: AppContext, router: AppCommandRouter, onBack: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.workspaceID = workspaceID
        self.context = context
        self.router = router
        self.onBack = onBack
        self.onClose = onClose
        let win = InteractiveTitlebarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 760, height: 520)
        RemoteCodeAppearance.apply(to: win)
        self.window = win
        super.init()
        win.delegate = self
        setupLayout()
        refreshFromState()
        // P2-MAC_SHELL_WINDOW: restore the saved frame for this workspace's
        // detached window, falling back to center() on first open (no saved
        // frame). The autosave name is stable per workspace UUID so each
        // workspace remembers its own position independently.
        let autosaveName = detachedFrameAutosaveName(workspaceID: workspaceID)
        if !win.setFrameUsingName(autosaveName) {
            win.center()
        }
        win.setFrameAutosaveName(autosaveName)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        repairSelectedTerminalFocus(reason: "workspace_window_show")
    }

    func closeFromOwner() {
        closingFromOwner = true
        window.orderOut(nil)
    }

    func refreshFromState() {
        guard let ws = context?.state.workspaces[workspaceID] else {
            closeFromOwner()
            return
        }
        window.title = ws.name
        window.configureRemoteCodeWindowAccessibility(title: ws.name, identifier: "window.workspace")
        titleLabel.stringValue = ws.name
        // PF-11 parity with the main window (PERF-MAC_SHELL_WINDOW-002): an
        // unchanged pane/surface structure patches the live strips in place.
        // A teardown here unmounted hidden tabs, so a refresh after a tab
        // click parked the previous terminal outside this window.
        var signatureParts: [String] = []
        MainWindowController.appendLayoutSignature(ws.layout, into: &signatureParts)
        let signature = signatureParts.joined(separator: "|")
        if signature == lastLayoutSignature, !paneControllers.isEmpty {
            if let rootView = workspaceContent.subviews.first {
                MainWindowController.applyRatiosInPlace(view: rootView, node: ws.layout)
            }
            for controller in paneControllers {
                guard let freshPane = ws.layout.find(paneID: controller.pane.id) else { continue }
                controller.reconcile(to: freshPane)
            }
            return
        }
        lastLayoutSignature = signature
        for subview in workspaceContent.subviews { subview.removeFromSuperview() }
        paneControllers.removeAll()
        var primaryControlsAvailable = true
        let layout = buildLayoutView(node: ws.layout, primaryControlsAvailable: &primaryControlsAvailable)
        layout.translatesAutoresizingMaskIntoConstraints = true
        layout.frame = workspaceContent.bounds
        layout.autoresizingMask = [.width, .height]
        workspaceContent.addSubview(layout)
        if let split = layout as? RatioSplitView {
            split.relayoutNow()
        }
    }

    func refreshSurfaceRuntimeState() {
        for controller in paneControllers {
            controller.refreshBusyStates()
        }
    }

    func updateSurfaceTabTitle(_ surfaceID: SurfaceID, title: String) {
        for controller in paneControllers {
            controller.setTabTitle(surfaceID, title: title)
        }
    }

    func applyFocusChangeInPlace(surfaceToFocus: SurfaceID?) {
        guard let ws = context?.state.workspaces[workspaceID] else {
            closeFromOwner()
            return
        }
        if paneControllers.isEmpty {
            refreshFromState()
            return
        }
        for controller in paneControllers {
            guard let freshPane = ws.layout.find(paneID: controller.pane.id) else { continue }
            controller.reconcile(to: freshPane)
        }
        if let surfaceToFocus, let surface = SurfaceRegistry.shared.surface(surfaceToFocus) {
            surface.focus()
        }
    }

    func repairSelectedTerminalFocus(reason: String) {
        guard protectedFocusedView() == nil else { return }
        router?.repairSelectedTerminalFocus(workspace: workspaceID, reason: reason)
    }

    @discardableResult
    func resizeFocusedPane(_ direction: SplitDirection) -> Bool {
        guard let ws = context?.state.workspaces[workspaceID] else { return false }
        return resizeKeyboardTargetPane(direction, in: ws, controllers: paneControllers)
    }

    /// UX-MAC_SHELL_WINDOW-003: ⌘W closes the focused tab of the window the
    /// user is looking at, with the same unsaved-changes confirm the main
    /// window uses. Returning false lets ⌘W fall back to closing the window.
    @discardableResult
    func closeFocusedSurface() -> Bool {
        guard let ws = context?.state.workspaces[workspaceID] else { return false }
        return closeKeyboardTargetSurface(in: ws, controllers: paneControllers)
    }

    /// UX-MAC_SHELL_WINDOW-004: ⌘D splits this window's focused pane.
    @discardableResult
    func splitFocusedPane(_ direction: SplitDirection) -> Bool {
        guard let ws = context?.state.workspaces[workspaceID] else { return false }
        return splitKeyboardTargetPane(direction, in: ws, controllers: paneControllers)
    }

    private func protectedFocusedView() -> NSView? {
        MainWindowController.protectedTextFocusOwner(
            firstResponder: window.firstResponder,
            within: workspaceContent
        )
    }

    private func setupLayout() {
        window.backgroundColor = DS.NS.bg
        content.wantsLayer = true
        content.layer?.backgroundColor = DS.NS.bg.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        workspaceContent.wantsLayer = true
        workspaceContent.layer?.backgroundColor = DS.NS.bg.cgColor
        workspaceContent.translatesAutoresizingMaskIntoConstraints = false

        let header = NoDragView()
        header.wantsLayer = true
        header.layer?.backgroundColor = DS.NS.surface.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let backButton = NoDragButton(frame: .zero)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isBordered = false
        backButton.bezelStyle = .inline
        backButton.imagePosition = .imageOnly
        backButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Back to sidebar")
        backButton.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        backButton.contentTintColor = DS.NS.textSecondary
        backButton.toolTip = L("Back to sidebar")
        backButton.target = self
        backButton.action = #selector(backToSidebar)
        backButton.setAccessibilityIdentifier("workspaceWindow.back")

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = DS.NS.text
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.NS.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(backButton)
        header.addSubview(titleLabel)
        header.addSubview(divider)
        content.addSubview(header)
        content.addSubview(workspaceContent)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),

            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 92),
            backButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 26),
            backButton.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: DS.Space.sm),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -DS.Space.lg),

            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            workspaceContent.topAnchor.constraint(equalTo: header.bottomAnchor),
            workspaceContent.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            workspaceContent.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            workspaceContent.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        window.contentView = content
    }

    private func buildLayoutView(node: LayoutNode, primaryControlsAvailable: inout Bool, splitContext: PaneSplitContext? = nil) -> NSView {
        switch node {
        case .pane(let pane):
            let showsWorkspaceControls = primaryControlsAvailable
            primaryControlsAvailable = false
            let ptv = PaneTabsView(
                pane: pane,
                router: router,
                showsWorkspaceControls: showsWorkspaceControls,
                splitContext: splitContext,
                workspaceID: workspaceID
            )
            paneControllers.append(ptv)
            return ptv.view
        case .split(let splitNode):
            let split = RatioSplitView()
            split.isVertical = (splitNode.orientation == .horizontal)
            split.dividerStyle = .thin
            split.ratios = splitNode.ratios.map { CGFloat($0) }
            let splitID = splitNode.id
            split.onRatiosChanged = { [weak self] ratios in
                guard let self else { return }
                try? self.router?.paneResize(workspace: self.workspaceID, splitID: splitID, ratios: ratios.map(Double.init))
            }
            for (index, child) in splitNode.children.enumerated() {
                let childSplitContext = PaneSplitContext(splitID: splitNode.id, paneIndex: index, ratios: splitNode.ratios, orientation: splitNode.orientation)
                let childView = buildLayoutView(node: child, primaryControlsAvailable: &primaryControlsAvailable, splitContext: childSplitContext)
                childView.translatesAutoresizingMaskIntoConstraints = true
                childView.autoresizingMask = []
                split.addSubview(childView)
            }
            return split
        }
    }

    @objc private func backToSidebar() {
        onBack()
    }

    func windowWillClose(_ notification: Notification) {
        if !closingFromOwner {
            onClose()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        repairSelectedTerminalFocus(reason: "workspace_window_key")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closingFromOwner else { return true }
        onBack()
        return false
    }
}

/// Split view that lays out its panes by explicit ratios instead of
/// AppKit's content-hugging heuristics. A fresh split has ratios
/// [0.5, 0.5], so each new pane is exactly half the old pane's width
/// (vertical divider) or height (horizontal divider). Ratios are kept
/// on live resize too.
final class RatioSplitView: NSView {
    var ratios: [CGFloat] = []
    var onRatiosChanged: (([CGFloat]) -> Void)?
    var isVertical = true { didSet { needsLayout = true } }
    var dividerStyle: NSSplitView.DividerStyle = .thin
    var dividerThickness: CGFloat { DS.ResizeDivider.thickness }
    private let collapsedRatioThreshold: CGFloat = 0.08
    private var collapsedExtent: CGFloat { isVertical ? 44 : 35 }
    private let dividerHitSlop: CGFloat = 6
    private let minimumDragRatio: CGFloat = 0.08
    private var dragDividerIndex: Int?
    private var dragStartPoint: NSPoint?
    // internal (not private) so tests can seed the pre-drag snapshot directly.
    var dragStartRatios: [CGFloat] = []
    private var dividerLayers: [CALayer] = []
    private var dividerGripLayers: [CALayer] = []

    // PERF-MAC_SHELL_WINDOW-MED-129: class-level flag indicating a divider drag
    // is in progress on ANY RatioSplitView. PaneRootView reads this to skip the
    // synchronous AutoLayout subtree solve on every setFrameSize tick — hundreds
    // of solves per drag second are replaced by a single solve on drag-end.
    // Thread-bound to @MainActor (all AppKit events are main-thread).
    static var dividerDragActive: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = DS.NS.bg.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = DS.NS.bg.cgColor
        layer?.masksToBounds = true
    }

    func relayoutNow() { layoutByRatios() }
    func adjustSubviews() { layoutByRatios() }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutByRatios() }
    override func layout() {
        super.layout()
        layoutByRatios()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutByRatios()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard subviews.count > 1 else { return }
        for index in 0..<(subviews.count - 1) {
            addCursorRect(dividerRect(afterSubviewAt: index), cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
        }
        layoutDividerLayers()
    }

    override var acceptsFirstResponder: Bool { true }

    // Pure seam: given the pre-drag snapshot, return the ratios that a
    // cancel should restore (identity -- the snapshot is authoritative).
    static func ratiosOnCancel(dragStart: [CGFloat]) -> [CGFloat] { dragStart }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dividerIndex(at: point) else {
            super.mouseDown(with: event)
            return
        }
        dragDividerIndex = index
        dragStartPoint = point
        dragStartRatios = normalizedRatios(for: subviews.count)
        // PERF-MAC_SHELL_WINDOW-MED-129: suppress per-tick AutoLayout solves
        // in PaneRootView.setFrameSize for the duration of this drag.
        RatioSplitView.dividerDragActive = true
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragDividerIndex,
              let start = dragStartPoint else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let delta = isVertical ? point.x - start.x : start.y - point.y
        applyDividerDrag(dividerIndex: index, delta: delta)
    }

    override func mouseUp(with event: NSEvent) {
        if dragDividerIndex != nil {
            // PERF-MAC_SHELL_WINDOW-MED-129: drag ended — clear the suppression
            // flag and force one final synchronous layout solve so every pane
            // settles to its exact final frame before the commit fires.
            RatioSplitView.dividerDragActive = false
            for sv in subviews {
                sv.needsLayout = true
                sv.layoutSubtreeIfNeeded()
            }
            onRatiosChanged?(ratios)
        }
        dragDividerIndex = nil
        dragStartPoint = nil
        dragStartRatios = []
        super.mouseUp(with: event)
    }

    // cancelOperation is triggered by Esc (AppKit standard responder action).
    override func cancelOperation(_ sender: Any?) {
        guard dragDividerIndex != nil else { return }
        cancelDividerDrag()
    }

    override func keyDown(with event: NSEvent) {
        // NSEscFunctionKey = 27 (0x1B); also guard on cancelOperation for
        // standard Esc routing, but keyDown catches direct Esc key presses
        // in case the window does not route cancelOperation here.
        if event.keyCode == 53, dragDividerIndex != nil {
            cancelDividerDrag()
            return
        }
        super.keyDown(with: event)
    }

    /// Restore pre-drag ratios and end the drag without committing.
    /// onRatiosChanged is NOT fired -- the original layout is kept.
    func cancelDividerDrag() {
        ratios = RatioSplitView.ratiosOnCancel(dragStart: dragStartRatios)
        // PERF-MAC_SHELL_WINDOW-MED-129: clear suppression and settle layout
        // to the restored ratios before returning.
        RatioSplitView.dividerDragActive = false
        layoutByRatios()
        for sv in subviews {
            sv.needsLayout = true
            sv.layoutSubtreeIfNeeded()
        }
        dragDividerIndex = nil
        dragStartPoint = nil
        dragStartRatios = []
    }

    func applyDividerDrag(dividerIndex: Int, delta: CGFloat) {
        let n = subviews.count
        guard n > 1,
              dividerIndex >= 0,
              dividerIndex < n - 1 else { return }

        let base = dragStartRatios.count == n ? dragStartRatios : normalizedRatios(for: n)
        let extent = max(1, (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(n - 1))
        let ratioDelta = delta / extent
        var next = base
        let first = max(minimumDragRatio, min(1 - minimumDragRatio, base[dividerIndex] + ratioDelta))
        let pairTotal = base[dividerIndex] + base[dividerIndex + 1]
        let second = pairTotal - first
        guard second >= minimumDragRatio else {
            next[dividerIndex] = pairTotal - minimumDragRatio
            next[dividerIndex + 1] = minimumDragRatio
            ratios = SplitNode.normalize(next.map(Double.init)).map { CGFloat($0) }
            layoutByRatios()
            return
        }
        next[dividerIndex] = first
        next[dividerIndex + 1] = second
        ratios = SplitNode.normalize(next.map(Double.init)).map { CGFloat($0) }
        layoutByRatios()
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        guard subviews.count > 1 else { return nil }
        for index in 0..<(subviews.count - 1) where dividerRect(afterSubviewAt: index).contains(point) {
            return index
        }
        return nil
    }

    private func dividerRect(afterSubviewAt index: Int) -> NSRect {
        let frame = subviews[index].frame
        if isVertical {
            return NSRect(
                x: frame.maxX - dividerHitSlop,
                y: bounds.minY,
                width: dividerHitSlop * 2 + dividerThickness,
                height: bounds.height
            )
        }
        return NSRect(
            x: bounds.minX,
            y: frame.minY - dividerHitSlop - dividerThickness,
            width: bounds.width,
            height: dividerHitSlop * 2 + dividerThickness
        )
    }

    private func layoutByRatios() {
        let n = subviews.count
        guard n >= 1, bounds.width > 0, bounds.height > 0 else { return }
        let dt = dividerThickness
        let norm = normalizedRatios(for: n)

        let collapsed = Set(norm.indices.filter { norm[$0] <= collapsedRatioThreshold && n > 1 })

        if isVertical {
            let fixed = min(bounds.width, CGFloat(collapsed.count) * collapsedExtent)
            let avail = max(0, bounds.width - dt * CGFloat(n - 1) - fixed)
            // PERF: single pass avoids the filter + map intermediates on the
            // resize/divider-drag layout path; total identical.
            var flexibleTotal: CGFloat = 0
            for i in norm.indices where !collapsed.contains(i) {
                flexibleTotal += norm[i]
            }
            var x: CGFloat = 0
            for (i, sv) in subviews.enumerated() {
                let w: CGFloat
                if collapsed.contains(i) {
                    w = min(collapsedExtent, max(0, bounds.width - x))
                } else if i == n - 1 {
                    w = max(0, bounds.width - x)
                } else {
                    let share = flexibleTotal > 0 ? norm[i] / flexibleTotal : 1.0 / CGFloat(max(1, n - collapsed.count))
                    w = (avail * share).rounded()
                }
                let newFrame = NSRect(x: x, y: 0, width: w, height: bounds.height)
                let sizeChanged = sv.frame.size != newFrame.size
                sv.frame = newFrame
                relayoutChild(sv, sizeChanged: sizeChanged)
                x += w + dt
            }
        } else {
            let fixed = min(bounds.height, CGFloat(collapsed.count) * collapsedExtent)
            let avail = max(0, bounds.height - dt * CGFloat(n - 1) - fixed)
            // PERF: single pass avoids the filter + map intermediates on the
            // resize/divider-drag layout path; total identical.
            var flexibleTotal: CGFloat = 0
            for i in norm.indices where !collapsed.contains(i) {
                flexibleTotal += norm[i]
            }
            var y: CGFloat = bounds.height
            for (i, sv) in subviews.enumerated() {
                let h: CGFloat
                if collapsed.contains(i) {
                    h = min(collapsedExtent, max(0, y))
                } else if i == n - 1 {
                    h = max(0, y)
                } else {
                    let share = flexibleTotal > 0 ? norm[i] / flexibleTotal : 1.0 / CGFloat(max(1, n - collapsed.count))
                    h = (avail * share).rounded()
                }
                y -= h
                let newFrame = NSRect(x: 0, y: y, width: bounds.width, height: h)
                let sizeChanged = sv.frame.size != newFrame.size
                sv.frame = newFrame
                relayoutChild(sv, sizeChanged: sizeChanged)
                y -= dt
            }
        }
        layoutDividerLayers()
    }

    private func relayoutChild(_ child: NSView, sizeChanged: Bool) {
        // PERF-MAC_SHELL_WINDOW-004: only force a synchronous subtree
        // layout when the child actually resized. A nested split still
        // re-runs its own ratio layout (its panes may have shifted even at
        // the same outer size), but unchanged leaf panes (terminal/browser)
        // skip the forced `layoutSubtreeIfNeeded` on every drag tick.
        if let split = child as? RatioSplitView {
            child.needsLayout = true
            split.layoutByRatios()
        } else if sizeChanged {
            child.needsLayout = true
            child.layoutSubtreeIfNeeded()
        }
    }

    private func normalizedRatios(for count: Int) -> [CGFloat] {
        if ratios.count == count {
            let total = ratios.reduce(0, +)
            if total > 0 { return ratios.map { $0 / total } }
        }
        return Array(repeating: 1.0 / CGFloat(max(count, 1)), count: count)
    }

    private func layoutDividerLayers() {
        let count = max(0, subviews.count - 1)
        ensureDividerLayers(count: count)
        guard count > 0 else { return }
        for index in 0..<count {
            let dividerFrame: CGRect
            if isVertical {
                dividerFrame = CGRect(x: subviews[index].frame.maxX,
                                      y: bounds.minY,
                                      width: dividerThickness,
                                      height: bounds.height)
            } else {
                dividerFrame = CGRect(x: bounds.minX,
                                      y: subviews[index].frame.minY - dividerThickness,
                                      width: bounds.width,
                                      height: dividerThickness)
            }
            let divider = dividerLayers[index]
            let grip = dividerGripLayers[index]
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            divider.frame = dividerFrame
            grip.frame = CGRect(
                x: (dividerFrame.width - (isVertical ? DS.ResizeDivider.gripThickness : DS.ResizeDivider.gripLength)) / 2,
                y: (dividerFrame.height - (isVertical ? DS.ResizeDivider.gripLength : DS.ResizeDivider.gripThickness)) / 2,
                width: isVertical ? DS.ResizeDivider.gripThickness : DS.ResizeDivider.gripLength,
                height: isVertical ? DS.ResizeDivider.gripLength : DS.ResizeDivider.gripThickness
            )
            CATransaction.commit()
        }
    }

    private func ensureDividerLayers(count: Int) {
        while dividerLayers.count < count {
            let divider = CALayer()
            divider.backgroundColor = DS.NS.line.cgColor
            divider.zPosition = 999
            let grip = CALayer()
            grip.backgroundColor = DS.NS.lineStrong.cgColor
            grip.cornerRadius = DS.ResizeDivider.gripThickness / 2
            grip.zPosition = 1_000
            divider.addSublayer(grip)
            layer?.addSublayer(divider)
            dividerLayers.append(divider)
            dividerGripLayers.append(grip)
        }
        while dividerLayers.count > count {
            dividerLayers.removeLast().removeFromSuperlayer()
            dividerGripLayers.removeLast()
        }
    }
}
