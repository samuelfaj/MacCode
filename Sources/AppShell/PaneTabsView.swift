import Foundation
import AppKit
import CoreModel
import Persistence
import SocketServer
import Surfaces
import DesignSystemKit

@MainActor
public struct PaneSplitContext {
    public let splitID: UUID
    public let paneIndex: Int
    public let ratios: [Double]
    public let orientation: SplitOrientation

    public init(splitID: UUID, paneIndex: Int, ratios: [Double], orientation: SplitOrientation = .horizontal) {
        self.splitID = splitID
        self.paneIndex = paneIndex
        self.ratios = ratios
        self.orientation = orientation
    }
}

@MainActor
public final class PaneTabsView: NSObject {
    public let view: NSView
    public private(set) var pane: PaneNode
    public weak var router: AppCommandRouter?
    private let splitContext: PaneSplitContext?
    private let workspaceIDOverride: WorkspaceID?
    private let tabStrip = PaneTabDropStack()
    private let tabScrollView = HorizontalTabScrollView()
    private let contentArea = NSView()
    private let addMenu = NSMenu()
    private let splitRightMenu = NSMenu()
    private let splitDownMenu = NSMenu()
    // UX: overflow menu button -- always visible at the leading edge of the
    // right-control cluster. Pops an NSMenu listing all tabs; selecting one
    // routes through selectSurface so scroll-into-view fires via reconcile.
    private let overflowButton: NSButton = {
        let b = NoDragButton(frame: .zero)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isBordered = false
        b.bezelStyle = .inline
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("All tabs"))
        b.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        b.contentTintColor = DS.NS.textSecondary
        b.toolTip = L("All tabs")
        b.wantsLayer = true
        b.layer?.cornerRadius = DS.Radius.control
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 22),
            b.heightAnchor.constraint(equalToConstant: 22)
        ])
        b.setAccessibilityIdentifier("pane.overflowMenu")
        return b
    }()
    private var tabButtons: [SurfaceID: PaneTabButton] = [:]
    /// PF-11: keep each tab's surface view mounted and toggle `isHidden`
    /// instead of removeFromSuperview/addSubview on every click.
    private var mountedContentViews: [SurfaceID: NSView] = [:]
    // PERF: ordered SurfaceIDs currently rendered in the strip. The diff
    // seam (`PaneTabsView.diffTabs`) compares this against the fresh pane
    // order to patch the strip in place instead of rebuilding it.
    private var currentSurfaceIDs: [SurfaceID] = []
    // UX: last-known selected surface ID so the non-structural reconcile path
    // can skip scrolling when only dirty/busy/title changed (no selection change).
    private var currentSelectedID: SurfaceID?
    private var eventToken: UUID?
    // UX-P3: holds the surface ID shown in a missing-surface placeholder so
    // the "Close Tab" recovery button can route through closeSurface.
    private var pendingMissingSurfaceID: SurfaceID?
    // PERF: cache for files-tab dirty state resolved asynchronously.
    // Key present => state known (true=dirty). Key absent => unknown (async resolve pending or not yet triggered).
    // Staleness window: up to one event-loop turn after tab construction before the async RPC result arrives
    // and updates the button; subsequent updates arrive via files.state.updated events (no polling needed).
    // Peak keys retained (closed-tab churn otherwise pins SurfaceID→Bool forever;
    // structural rebuild also prunes to live surface ids).
    nonisolated static let dirtyStateCacheCountLimit = 256
    private var dirtyStateCache: [SurfaceID: Bool] = [:]

    public init(pane: PaneNode, router: AppCommandRouter?, showsWorkspaceControls: Bool = true, splitContext: PaneSplitContext? = nil, workspaceID: WorkspaceID? = nil) {
        self.pane = pane
        self.router = router
        self.splitContext = splitContext
        self.workspaceIDOverride = workspaceID
        let v = PaneRootView()
        v.paneID = pane.id
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor
        v.layer?.masksToBounds = true
        self.view = v

        super.init()

        // Custom tab strip: icon + truncating title + close button.
        let selectedID = pane.selectedSurfaceID ?? pane.surfaces.first?.id
        let paneMinimized = splitContext.map {
            Self.isPaneMinimized(paneIndex: $0.paneIndex, ratios: $0.ratios)
        } ?? false
        if paneMinimized, splitContext?.orientation == .horizontal {
            buildMinimizedSideRail(in: v, selectedSurfaceID: selectedID)
            return
        }

        tabStrip.orientation = .horizontal
        tabStrip.spacing = 0
        tabStrip.alignment = .centerY
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onDropSurface = { [weak self] sid in self?.appendDroppedSurface(sid) ?? false }
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.documentView = tabStrip
        let initialRunning = Self.runningWorkspaceIDs(for: pane.surfaces, router: router)
        for desc in pane.surfaces {
            let tab = makeTabButton(for: desc, in: pane, selectedID: selectedID, runningWorkspaceIDs: initialRunning)
            tabButtons[desc.id] = tab
            currentSurfaceIDs.append(desc.id)
            tabStrip.addArrangedSubview(tab)
        }

        // Content area: the selected surface (or a styled placeholder).
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.wantsLayer = true
        contentArea.layer?.backgroundColor = DS.NS.bg.cgColor
        contentArea.layer?.masksToBounds = true
        contentArea.isHidden = paneMinimized
        installSelectedContent(selectedID: selectedID, in: pane)

        // Chrome-style flat "+" that sits right after the last tab.
        // Clicking it pops the surface-type menu under the button.
        let addButton = Self.makeIconButton(
            symbol: "plus",
            help: L("New surface"),
            target: self, action: #selector(showAddMenu(_:)))
        addButton.setAccessibilityIdentifier("pane.add")
        Self.populateSurfaceMenu(addMenu, target: self, action: #selector(addFromMenu(_:)))
        Self.populateSurfaceMenu(splitRightMenu, target: self, action: #selector(splitFromMenu(_:)), direction: .right)
        Self.populateSurfaceMenu(splitDownMenu, target: self, action: #selector(splitFromMenu(_:)), direction: .down)
        tabStrip.addArrangedSubview(addButton)

        // Split controls live on the RIGHT of the toolbar as two icon
        // buttons: columns (side-by-side, .right) and rows (stacked, .down).
        let splitColumns = Self.makeIconButton(
            symbol: "rectangle.split.2x1",
            help: L("Split right (side by side)"),
            target: self, action: #selector(showSplitRightMenu(_:)))
        splitColumns.setAccessibilityIdentifier("pane.splitRight")
        let splitRows = Self.makeIconButton(
            symbol: "rectangle.split.1x2",
            help: L("Split down (stacked)"),
            target: self, action: #selector(showSplitDownMenu(_:)))
        splitRows.setAccessibilityIdentifier("pane.splitDown")

        // UX: wire overflow button; target/action set here (not in the lazy
        // stored-property closure) so `self` is available.
        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu(_:))

        var rightControls: [NSView] = [overflowButton, splitColumns, splitRows]
        if let splitContext {
            let minimized = Self.isPaneMinimized(paneIndex: splitContext.paneIndex, ratios: splitContext.ratios)
            let paneZoom = Self.makeIconButton(
                symbol: minimized ? "arrow.up.left.and.arrow.down.right" : "minus",
                help: minimized ? L("Maximize pane") : L("Minimize pane"),
                target: self, action: #selector(togglePaneMinimized))
            rightControls.insert(paneZoom, at: 0)
        }

        let rightCluster = NoDragStack(views: rightControls)
        rightCluster.orientation = .horizontal
        rightCluster.spacing = DS.Space.sm
        rightCluster.translatesAutoresizingMaskIntoConstraints = false
        rightCluster.setContentHuggingPriority(.required, for: .horizontal)

        let headerBG = NSView()
        headerBG.wantsLayer = true
        headerBG.layer?.backgroundColor = DS.NS.surface.cgColor
        headerBG.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.NS.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(headerBG)
        headerBG.addSubview(tabScrollView)
        headerBG.addSubview(rightCluster)
        v.addSubview(divider)
        v.addSubview(contentArea)
        NSLayoutConstraint.activate([
            headerBG.topAnchor.constraint(equalTo: v.topAnchor),
            headerBG.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            headerBG.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            headerBG.heightAnchor.constraint(equalToConstant: 34),

            tabScrollView.leadingAnchor.constraint(equalTo: headerBG.leadingAnchor),
            tabScrollView.topAnchor.constraint(equalTo: headerBG.topAnchor),
            tabScrollView.bottomAnchor.constraint(equalTo: headerBG.bottomAnchor),
            tabScrollView.trailingAnchor.constraint(equalTo: rightCluster.leadingAnchor, constant: -DS.Space.sm),

            tabStrip.leadingAnchor.constraint(equalTo: tabScrollView.contentView.leadingAnchor),
            tabStrip.topAnchor.constraint(equalTo: tabScrollView.contentView.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: tabScrollView.contentView.bottomAnchor),
            tabStrip.heightAnchor.constraint(equalTo: tabScrollView.heightAnchor),

            rightCluster.trailingAnchor.constraint(equalTo: headerBG.trailingAnchor, constant: -DS.Space.md),
            rightCluster.centerYAnchor.constraint(equalTo: headerBG.centerYAnchor),

            divider.topAnchor.constraint(equalTo: headerBG.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            contentArea.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentArea.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: v.trailingAnchor)
        ])

        // Appearance-change: wire chrome subviews so PaneRootView can
        // re-apply their CGColors when the effective appearance changes.
        v.chromeHeaderBG = headerBG
        v.chromeContentArea = contentArea
        v.chromeDividers = [divider]

        // UX: double-clicking the empty header bar maximizes/minimizes this pane,
        // mirroring the zoom button — so the user doesn't have to hit the small
        // control precisely. Scoped to split panes (the only case where a zoom
        // toggle exists). The delegate restricts recognition to the bar's empty
        // chrome: double-clicking a tab still renames it; control buttons keep
        // their own actions.
        if splitContext != nil {
            let zoomDoubleClick = NSClickGestureRecognizer(target: self, action: #selector(headerBarDoubleClicked))
            zoomDoubleClick.numberOfClicksRequired = 2
            zoomDoubleClick.delaysPrimaryMouseButtonEvents = false
            zoomDoubleClick.delegate = self
            headerBG.addGestureRecognizer(zoomDoubleClick)
        }

        // Focus-follows-click: a mouseDown anywhere inside the pane root
        // (content area or tab header) records this pane as focused so
        // Cmd+W / Cmd+D act on the right pane. The closure is pure-ID
        // routing: no surface selection, no UI side effects.
        let paneID = pane.id
        v.onContentAreaMouseDown = { [weak self] in
            guard let self,
                  let wid = currentWorkspaceID(),
                  let ws = router?.context?.state.workspaces[wid],
                  let target = Self.focusPaneCommand(
                      currentFocusedPaneID: ws.focusedPaneID,
                      paneID: paneID,
                      workspaceID: wid) else { return }
            try? router?.focusPane(workspace: target.workspace, pane: target.pane)
        }

        currentSelectedID = selectedID

        // PERF-MAC_SHELL_WINDOW-001: the tab strip only reacts to
        // `files.state.updated`. Drop every other kind on the publishing
        // thread instead of bouncing the full EventBus firehose to main
        // just to discard it in `receive`.
        eventToken = EventBus.shared.subscribe(since: nil) { [weak self] event in
            guard event.kind == "files.state.updated" else { return }
            DispatchQueue.main.async { self?.receive(event) }
        }
        DispatchQueue.main.async { [weak self] in self?.scrollSelectedTabIntoView(selectedID) }
    }

    private func scrollSelectedTabIntoView(_ selectedID: SurfaceID?) {
        guard let selectedID, let tab = tabButtons[selectedID] else { return }
        tabScrollView.scrollDocumentViewToVisible(tab)
    }

    /// Test seam: views currently parented in the pane content area, in order.
    var contentAreaSubviewsForTesting: [NSView] { contentArea.subviews }

    /// Test seam: whether a previously selected tab's view stayed mounted and hidden.
    func isMountedContentHiddenForTesting(_ id: SurfaceID) -> Bool? {
        mountedContentViews[id]?.isHidden
    }

    @discardableResult
    private func installSelectedContent(selectedID: SurfaceID?, in pane: PaneNode) -> Bool {
        defer {
            PerfSwitchMetrics.endTabSwitchInstall()
            CATransaction.setCompletionBlock {
                PerfSwitchMetrics.endTabSwitchCommitted()
            }
        }
        let liveIDs = Set(pane.surfaces.map(\.id))
        var removedClosed = false
        for (id, view) in mountedContentViews where !liveIDs.contains(id) {
            view.removeFromSuperview()
            mountedContentViews.removeValue(forKey: id)
            removedClosed = true
        }
        let mountedSet = Set(mountedContentViews.values.map { ObjectIdentifier($0) })
        for subview in contentArea.subviews where !mountedSet.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }
        pendingMissingSurfaceID = nil

        let selectedView = selectedID.flatMap { SurfaceRegistry.shared.surface($0)?.view }
        if let selectedID, let selectedView {
            pinMountedContent(selectedID, view: selectedView)
            var changed = removedClosed
            for (id, view) in mountedContentViews {
                let hide = id != selectedID
                if view.isHidden != hide {
                    view.isHidden = hide
                    changed = true
                }
            }
            return changed
        } else if pane.surfaces.isEmpty {
            let label = NSTextField(labelWithString: L("Empty pane \u{2014} use + to add a surface"))
            label.textColor = DS.NS.textTertiary
            label.font = NSFont.systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            contentArea.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor)
            ])
        } else {
            // UX-P3: surface registered in the pane model but not in
            // SurfaceRegistry (e.g. session-restore failure). Show
            // user-readable copy and a recovery action.
            let label = NSTextField(labelWithString: L("This tab could not be loaded"))
            label.textColor = DS.NS.textTertiary
            label.font = NSFont.systemFont(ofSize: 13)
            label.translatesAutoresizingMaskIntoConstraints = false

            let hint = NSTextField(labelWithString: L("The surface is unavailable. Close the tab to continue."))
            hint.textColor = DS.NS.textTertiary
            hint.font = NSFont.systemFont(ofSize: 11)
            hint.translatesAutoresizingMaskIntoConstraints = false

            let closeBtn = NSButton(title: L("Close Tab"), target: nil, action: nil)
            closeBtn.bezelStyle = .rounded
            closeBtn.controlSize = .small
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            if let failedID = selectedID {
                pendingMissingSurfaceID = failedID
                closeBtn.target = self
                closeBtn.action = #selector(closeMissingSurface(_:))
            }

            let stack = NSStackView(views: [label, hint, closeBtn])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = DS.Space.sm
            stack.translatesAutoresizingMaskIntoConstraints = false
            contentArea.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor)
            ])
        }
        return true
    }

    private func pinMountedContent(_ id: SurfaceID, view: NSView) {
        if mountedContentViews[id] === view, view.superview === contentArea {
            return
        }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = false
        contentArea.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentArea.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor)
        ])
        mountedContentViews[id] = view
    }

    /// Test seam: the live button bound to `id` (nil if none), so the
    /// reconcile's in-place patching can be asserted without a window.
    func tabButtonForTesting(_ id: SurfaceID) -> PaneTabButton? { tabButtons[id] }

    /// Test seam: the SurfaceIDs currently rendered, in display order.
    var currentSurfaceIDsForTesting: [SurfaceID] { currentSurfaceIDs }

    /// Builds one tab button bound to `desc` within `pane`. Shared by the
    /// initial strip build and the reconcile's insert path so a freshly
    /// inserted button is wired identically to an initially-built one.
    private func makeTabButton(for desc: SurfaceDescriptor, in pane: PaneNode, selectedID: SurfaceID?, runningWorkspaceIDs: Set<WorkspaceID>? = nil) -> PaneTabButton {
        let sid = desc.id
        let busy: Bool
        if let running = runningWorkspaceIDs {
            busy = Self.isSurfaceBusy(desc, runningWorkspaceIDs: running, router: router)
        } else {
            busy = Self.isSurfaceBusy(desc, router: router)
        }
        let btn = PaneTabButton(
            surfaceID: sid,
            title: desc.title,
            symbol: Self.symbol(for: desc),
            selected: desc.id == selectedID,
            busy: busy,
            dirty: surfaceIsUnsaved(sid),
            colorHex: TabColor.from(desc.metadata["color"])?.hex,
            onSelect: { [weak self] in self?.selectSurface(sid) },
            onClose: { [weak self] in self?.closeSurface(sid) },
            onCloseOthers: pane.surfaces.count > 1 ? { [weak self] in _ = self?.performCloseAllOthers(around: sid) } : nil,
            onCloseToLeft: Self.surfaceIDs(in: pane, before: sid).isEmpty ? nil : { [weak self] in _ = self?.performCloseToLeft(of: sid) },
            onCloseToRight: Self.surfaceIDs(in: pane, after: sid).isEmpty ? nil : { [weak self] in _ = self?.performCloseToRight(of: sid) },
            onRename: { [weak self] in self?.beginInlineRename(sid, current: desc.title) },
            onSetColor: { [weak self] raw in
                guard let wid = self?.currentWorkspaceID() else { return }
                try? self?.router?.setSurfaceColor(wid, sid, raw)
            },
            onDropSurface: { [weak self] draggedID in
                self?.dropSurface(draggedID, before: sid) ?? false
            },
            onSplitSurface: { [weak self] draggedID, targetPane, direction in
                self?.performSplitSurface(draggedID, targetPane: targetPane, direction: direction) ?? false
            }
        )
        btn.setUnread(desc.type == .terminal && desc.hasUnreadActivity)
        btn.toolTip = WorkspaceTool.from(metadata: desc.metadata, title: desc.title).map { "\(desc.title) -- \($0.title)" }
            ?? Self.tabTooltipString(title: desc.title, type: desc.type)
        return btn
    }

    /// PERF (P1): in-place tab-strip reconcile keyed by SurfaceID. Drives
    /// the pure `diffTabs` seam: when the SurfaceID set and order are
    /// unchanged, every surviving button is patched in place
    /// (selection / title / color / dirty) with NO structural mutation of
    /// the strip -- eliminating the full-rebuild flash. Structural deltas
    /// (insert / remove / reorder) rebuild only this pane's buttons; pane
    /// identity for the unchanged-shape case is preserved.
    ///
    /// Returns true when the strip was patched in place (no structural
    /// change), so the caller can skip a container teardown entirely.
    @discardableResult
    public func reconcile(to pane: PaneNode) -> Bool {
        self.pane = pane
        let newIDs = pane.surfaces.map(\.id)
        let diff = Self.diffTabs(old: currentSurfaceIDs, new: newIDs)
        let selectedID = pane.selectedSurfaceID ?? pane.surfaces.first?.id
        let structural = !diff.inserts.isEmpty || !diff.removes.isEmpty || diff.reordered

        if structural {
            // Set or order changed: rebuild this pane's buttons. Cheaper
            // than the old whole-workspace teardown and still keyed off the
            // diff decision.
            for view in tabStrip.arrangedSubviews where view is PaneTabButton {
                tabStrip.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            tabButtons.removeAll(keepingCapacity: true)
            currentSurfaceIDs.removeAll(keepingCapacity: true)
            let structuralRunning = Self.runningWorkspaceIDs(for: pane.surfaces, router: router)
            var insertIndex = 0
            for desc in pane.surfaces {
                let tab = makeTabButton(for: desc, in: pane, selectedID: selectedID, runningWorkspaceIDs: structuralRunning)
                tabButtons[desc.id] = tab
                currentSurfaceIDs.append(desc.id)
                tabStrip.insertArrangedSubview(tab, at: insertIndex)
                insertIndex += 1
            }
            currentSelectedID = selectedID
            // Drop dirty-cache entries for closed surfaces so tab churn cannot
            // pin unbounded SurfaceID→Bool pairs across structural rebuilds.
            Self.pruneDirtyStateCache(&dirtyStateCache, retaining: Set(currentSurfaceIDs))
            installSelectedContent(selectedID: selectedID, in: pane)
            DispatchQueue.main.async { [weak self] in self?.scrollSelectedTabIntoView(selectedID) }
            return false
        }

        // Unchanged shape: patch each surviving button in place.
        let patchRunning = Self.runningWorkspaceIDs(for: pane.surfaces, router: router)
        for desc in pane.surfaces {
            guard let tab = tabButtons[desc.id] else { continue }
            tab.setSelected(desc.id == selectedID)
            tab.setTitle(desc.title)
            tab.setColorHex(TabColor.from(desc.metadata["color"])?.hex)
            tab.setDirty(surfaceIsUnsaved(desc.id))
            tab.setUnread(desc.type == .terminal && desc.hasUnreadActivity)
            tab.setBusy(Self.isSurfaceBusy(desc, runningWorkspaceIDs: patchRunning, router: router))
        }
        // UX: scroll the newly selected tab into view ONLY when selection
        // changed (non-structural path). Trigger: Cmd+Shift+] / overflow-menu /
        // rename. Skip if only dirty/busy/title changed to avoid fighting
        // the user's manual scroll position.
        if selectedID != currentSelectedID {
            currentSelectedID = selectedID
            installSelectedContent(selectedID: selectedID, in: pane)
            DispatchQueue.main.async { [weak self] in self?.scrollSelectedTabIntoView(selectedID) }
        }
        return true
    }

    private func buildMinimizedSideRail(in root: NSView, selectedSurfaceID: SurfaceID?) {
        let restore = Self.makeIconButton(
            symbol: "arrow.up.left.and.arrow.down.right",
            help: L("Maximize pane"),
            target: self, action: #selector(togglePaneMinimized))

        let selected = selectedSurfaceID.flatMap { id in
            pane.surfaces.first(where: { $0.id == id })
        } ?? pane.surfaces.first
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: selected.map { Self.symbol(for: $0) } ?? "rectangle.dashed",
                             accessibilityDescription: selected?.title ?? L("Minimized pane"))
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = DS.NS.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        // UX-P2: tooltip lists all tab titles so the user knows what is
        // hidden behind the minimized rail without having to restore it.
        let allTitles = pane.surfaces.map(\.title).joined(separator: "\n")
        icon.toolTip = allTitles.isEmpty ? L("Minimized pane") : allTitles

        // UX-P2: show a tab-count badge when more than one tab is hidden
        // so the user knows there are additional surfaces in this pane.
        var stackViews: [NSView] = [restore, icon]
        if pane.surfaces.count > 1 {
            let badge = NSTextField(labelWithString: "\(pane.surfaces.count)")
            badge.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            badge.textColor = DS.NS.textSecondary
            badge.alignment = .center
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.setAccessibilityIdentifier("pane.minimized.tabCount")
            badge.toolTip = L("%1$@ tabs", pane.surfaces.count)
            stackViews.append(badge)
        }

        let stack = NoDragStack(views: stackViews)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = DS.Space.md
        stack.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.NS.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        root.addSubview(divider)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: DS.Space.sm),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1)
        ])
        // Appearance-change: wire the rail divider so PaneRootView re-applies
        // its CGColor when the effective appearance changes.
        (root as? PaneRootView)?.chromeDividers = [divider]
    }

    private func selectSurface(_ id: SurfaceID) {
        guard let wid = currentWorkspaceID() else { return }
        try? router?.focusSurface(workspace: wid, surface: id)
    }

    /// Starts an inline rename editor on the tab button for `id`.
    /// When the user commits, routes the new name through the router.
    /// Falls back to no-op if the tab button is not found (structural delta in flight).
    private func beginInlineRename(_ id: SurfaceID, current: String) {
        guard let wid = currentWorkspaceID(), let tab = tabButtons[id] else { return }
        tab.beginInlineRename { [weak self] newName in
            guard let self else { return }
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try? self.router?.renameSurface(wid, id, trimmed)
        }
    }

    private func closeSurface(_ id: SurfaceID) {
        guard let wid = currentWorkspaceID() else { return }
        if surfaceIsUnsaved(id), !confirmCloseUnsavedSurface(id) { return }
        try? router?.closeSurface(workspace: wid, surface: id)
    }

    /// UX-MAC_SHELL_WINDOW-003: ⌘W close-tab seam. Closes this pane's
    /// selected surface through the same unsaved-changes confirm the tab
    /// "×" uses. Returns false when the pane has no surface to close so
    /// the caller can fall back to closing the window.
    @discardableResult
    public func closeSelectedSurface() -> Bool {
        guard let id = pane.selectedSurfaceID ?? pane.surfaces.first?.id else { return false }
        closeSurface(id)
        return true
    }

    @discardableResult
    public func performCloseAllOthers(around id: SurfaceID) -> Bool {
        closeSurfaces(Self.surfaceIDs(excluding: id, in: pane))
    }

    @discardableResult
    public func performCloseToLeft(of id: SurfaceID) -> Bool {
        closeSurfaces(Self.surfaceIDs(in: pane, before: id))
    }

    @discardableResult
    public func performCloseToRight(of id: SurfaceID) -> Bool {
        closeSurfaces(Self.surfaceIDs(in: pane, after: id))
    }

    private func closeSurfaces(_ ids: [SurfaceID]) -> Bool {
        guard let wid = currentWorkspaceID(), let router, !ids.isEmpty else { return false }
        for id in ids where surfaceIsUnsaved(id) {
            if !confirmCloseUnsavedSurface(id) { return false }
        }
        do {
            try router.closeSurfaces(workspace: wid, surfaces: ids)
        } catch {
            return false
        }
        return true
    }

    private static func surfaceIDs(excluding id: SurfaceID, in pane: PaneNode) -> [SurfaceID] {
        var ids: [SurfaceID] = []
        ids.reserveCapacity(pane.surfaces.count)
        for surface in pane.surfaces where surface.id != id {
            ids.append(surface.id)
        }
        return ids
    }

    private static func surfaceIDs(in pane: PaneNode, before id: SurfaceID) -> [SurfaceID] {
        guard let index = pane.surfaces.firstIndex(where: { $0.id == id }), index > 0 else { return [] }
        return pane.surfaces[..<index].map(\.id)
    }

    private static func surfaceIDs(in pane: PaneNode, after id: SurfaceID) -> [SurfaceID] {
        guard let index = pane.surfaces.firstIndex(where: { $0.id == id }),
              index < pane.surfaces.index(before: pane.surfaces.endIndex) else { return [] }
        return pane.surfaces[pane.surfaces.index(after: index)...].map(\.id)
    }

    /// PERF: pure seam for the synchronous dirty-state decision.
    /// Returns the known dirty state without issuing any RPC.
    /// - isDirty: the descriptor's isDirty flag (always trusted).
    /// - metadataDirtyCount: the descriptor's "dirty_count" metadata string, or nil when absent.
    /// - cachedDirty: last async-resolved value for this surface, or nil when unknown.
    /// WHY: sync RPC x tabs x rebuilds = main-thread stall on every tab operation;
    /// extracting this seam lets callers (and tests) reason about the decision without
    /// triggering IO. nil return means "state unknown -- trigger async resolve".
    nonisolated static func dirtyStateForTab(isDirty: Bool, metadataDirtyCount: String?, cachedDirty: Bool?) -> Bool? {
        if isDirty { return true }
        if let raw = metadataDirtyCount { return (Int(raw) ?? 0) > 0 }
        return cachedDirty // nil => unknown; caller must async-resolve
    }

    /// Pure insert/evict for files-tab dirty memo. Keeps `id`; drops arbitrary
    /// other surface ids when over `countLimit`.
    nonisolated static func noteDirtyStateCacheEntry(
        _ cache: inout [SurfaceID: Bool],
        id: SurfaceID,
        isDirty: Bool,
        countLimit: Int = dirtyStateCacheCountLimit
    ) {
        cache[id] = isDirty
        let cap = max(1, countLimit)
        while cache.count > cap {
            if let victim = cache.keys.first(where: { $0 != id }) ?? cache.keys.first {
                cache.removeValue(forKey: victim)
            } else {
                break
            }
        }
    }

    /// Drop cache entries for surfaces no longer present in the strip.
    nonisolated static func pruneDirtyStateCache(
        _ cache: inout [SurfaceID: Bool],
        retaining liveIDs: Set<SurfaceID>
    ) {
        guard !cache.isEmpty else { return }
        cache = cache.filter { liveIDs.contains($0.key) }
    }

    private func surfaceIsUnsaved(_ id: SurfaceID) -> Bool {
        guard let desc = pane.surfaces.first(where: { $0.id == id }) else { return false }
        // Fast path: pure decision from descriptor flags + cache. No RPC.
        if let known = Self.dirtyStateForTab(
            isDirty: desc.isDirty,
            metadataDirtyCount: desc.metadata["dirty_count"],
            cachedDirty: dirtyStateCache[id]
        ) { return known }
        // State unknown (files tab, no dirty_count metadata, no cached value).
        // Return false now; trigger async resolve to update cache + button.
        guard desc.type == .files else { return false }
        scheduleAsyncDirtyResolve(id)
        return false
    }

    /// Fires the RPC off the main thread, caches the result, and patches the
    /// tab button on the MainActor. Safe to call from init context: the Task
    /// captures only [weak self] so it cannot extend PaneTabsView lifetime.
    private func scheduleAsyncDirtyResolve(_ id: SurfaceID) {
        guard let router else { return }
        Task { [weak self] in
            let isDirty: Bool
            do {
                let state = try router.filesStateGet(surface: id).objectValue
                if case .array(let values) = state?["dirty_paths"] ?? .array([]) {
                    isDirty = values.contains { $0.stringValue != nil }
                } else {
                    isDirty = false
                }
            } catch {
                isDirty = false
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                Self.noteDirtyStateCacheEntry(&self.dirtyStateCache, id: id, isDirty: isDirty)
                self.tabButtons[id]?.setDirty(isDirty)
            }
        }
    }

    private func confirmCloseUnsavedSurface(_ id: SurfaceID) -> Bool {
        let title = pane.surfaces.first(where: { $0.id == id })?.title ?? L("this tab")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Close “%1$@” with unsaved changes?", title)
        alert.informativeText = L("Unsaved file edits in this tab will be discarded if you close it.")
        alert.addButton(withTitle: L("Close Without Saving"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func receive(_ event: EventBus.Event) {
        guard event.kind == "files.state.updated",
              let payload = event.payload.objectValue,
              let raw = payload["surface_id"]?.stringValue,
              let uuid = UUID(uuidString: raw) else { return }
        let surfaceID = SurfaceID(uuid)
        guard let state = payload["state"]?.objectValue,
              case .array(let values) = state["dirty_paths"] ?? .array([]) else { return }
        let isDirty = values.contains { $0.stringValue != nil }
        Self.noteDirtyStateCacheEntry(&dirtyStateCache, id: surfaceID, isDirty: isDirty)
        tabButtons[surfaceID]?.setDirty(isDirty)
    }

    /// H3: in-place label patch for a title-only change (no reconcile pass).
    func setTabTitle(_ surfaceID: SurfaceID, title: String) {
        guard let index = pane.surfaces.firstIndex(where: { $0.id == surfaceID }) else { return }
        pane.surfaces[index].title = title
        tabButtons[surfaceID]?.setTitle(title)
    }

    func refreshBusyStates() {
        // PF-13: hidden workspace windows still hosted pane controllers.
        // Skip the busy walk when this pane's window is not visible.
        if let window = contentArea.window, !window.isVisible { return }
        let running = Self.runningWorkspaceIDs(for: pane.surfaces, router: router)
        for desc in pane.surfaces {
            tabButtons[desc.id]?.setUnread(desc.type == .terminal && desc.hasUnreadActivity)
            tabButtons[desc.id]?.setBusy(Self.isSurfaceBusy(desc, runningWorkspaceIDs: running, router: router))
        }
    }

    static func symbol(for desc: SurfaceDescriptor) -> String {
        WorkspaceTool.from(metadata: desc.metadata, title: desc.title)?.symbol ?? symbol(for: desc.type)
    }

    static func symbol(for type: SurfaceType) -> String {
        switch type {
        case .terminal: return "terminal"
        case .ssh: return "network"
        case .browser: return "globe"
        case .agentApp: return "sparkles"
        case .files: return "folder"
        case .markdown: return "doc.richtext"
        case .filePreview: return "doc"
        case .rightSidebarTool: return "sidebar.right"
        }
    }

    static func isSurfaceBusy(_ desc: SurfaceDescriptor, router: AppCommandRouter?) -> Bool {
        _ = router
        // The live registry is the only source of truth for tab busy state.
        // A stale or unregistered descriptor must not synchronously consult
        // persistence, and is therefore treated as idle.
        return SurfaceRegistry.shared.surface(desc.id)?.isBusy == true
    }

    /// PERF: batch overload kept for call-site compatibility. Busy is
    /// per-surface now, so the workspace running set is ignored and the
    /// single-surface check is authoritative.
    static func isSurfaceBusy(_ desc: SurfaceDescriptor, runningWorkspaceIDs: Set<WorkspaceID>, router: AppCommandRouter?) -> Bool {
        _ = runningWorkspaceIDs
        return isSurfaceBusy(desc, router: router)
    }

    /// PERF: retained for call sites that still batch tab busy refresh.
    /// The batch busy overload ignores this prefilter, so do not read
    /// persistence here; an empty set preserves the API without blocking UI.
    static func runningWorkspaceIDs(for surfaces: [SurfaceDescriptor], router: AppCommandRouter?) -> Set<WorkspaceID> {
        _ = surfaces
        _ = router
        return []
    }

    private func currentWorkspaceID() -> WorkspaceID? {
        workspaceIDOverride ?? router?.context?.state.window.selectedWorkspaceID
    }

    /// Surfaces offered by the + and Split menus, in display order.
    static let surfaceChoices: [(String, SurfaceType)] = [
        (L("Terminal"), .terminal),
        ("SSH", .ssh),
        (L("Browser"), .browser),
        (L("Agent App"), .agentApp),
        (L("Files"), .files),
        (L("Git"), .rightSidebarTool),
        (L("Bots"), .rightSidebarTool),
        (L("VMs"), .rightSidebarTool)
    ]

    private static func title(for type: SurfaceType) -> String {
        surfaceChoices.first(where: { $0.1 == type })?.0 ?? type.rawValue
    }

    @objc private func closeMissingSurface(_ sender: NSButton) {
        guard let id = pendingMissingSurfaceID else { return }
        closeSurface(id)
    }

    /// A token-styled square icon button used for the split controls.
    private static func makeIconButton(symbol: String, help: String,
                                       target: AnyObject, action: Selector) -> NSButton {
        let b = NoDragButton(frame: .zero)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isBordered = false
        b.bezelStyle = .inline
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        b.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        b.contentTintColor = DS.NS.textSecondary
        b.toolTip = help
        b.target = target
        b.action = action
        b.wantsLayer = true
        b.layer?.cornerRadius = DS.Radius.control
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 26),
            b.heightAnchor.constraint(equalToConstant: 22)
        ])
        return b
    }

    private static func populateSurfaceMenu(_ menu: NSMenu, target: AnyObject, action: Selector, direction: SplitDirection? = nil) {
        menu.removeAllItems()
        for (label, type) in surfaceChoices {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = target
            // Bots and VMs share Git's surface type; the label picks the tool.
            let choice = "\(type.rawValue)#\(label)"
            item.representedObject = direction.map { "\($0.rawValue)|\(choice)" } ?? choice
            let image = NSImage(systemSymbolName: WorkspaceTool.allCases.first { $0.title == label }?.symbol ?? symbol(for: type), accessibilityDescription: label)
            image?.isTemplate = true
            item.image = image?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            menu.addItem(item)
        }
    }

    deinit {
        if let eventToken { EventBus.shared.unsubscribe(eventToken) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        showMenu(addMenu, from: sender)
    }

    @objc private func showSplitRightMenu(_ sender: NSButton) {
        showMenu(splitRightMenu, from: sender)
    }

    @objc private func showSplitDownMenu(_ sender: NSButton) {
        showMenu(splitDownMenu, from: sender)
    }

    /// Pure seam: builds NSMenuItems for the overflow menu from `surfaces` and
    /// `selectedID`. Each item carries the SurfaceID as its representedObject.
    /// Checkmark on the selected tab. Testable without a real NSButton or window.
    static func overflowMenuItems(
        surfaces: [SurfaceDescriptor],
        selectedID: SurfaceID?,
        target: AnyObject,
        action: Selector
    ) -> [NSMenuItem] {
        surfaces.map { desc in
            let item = NSMenuItem(title: desc.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = desc.id
            item.state = desc.id == selectedID ? .on : .off
            let img = NSImage(systemSymbolName: PaneTabsView.symbol(for: desc),
                              accessibilityDescription: desc.title)
            img?.isTemplate = true
            item.image = img?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            return item
        }
    }

    @objc private func showOverflowMenu(_ sender: NSButton) {
        let selectedID = pane.selectedSurfaceID ?? pane.surfaces.first?.id
        let menu = NSMenu()
        for item in Self.overflowMenuItems(
            surfaces: pane.surfaces,
            selectedID: selectedID,
            target: self,
            action: #selector(overflowMenuSelected(_:))
        ) {
            menu.addItem(item)
        }
        showMenu(menu, from: sender)
    }

    @objc private func overflowMenuSelected(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? SurfaceID else { return }
        selectSurface(sid)
        // Scroll-into-view is driven by the state update that selectSurface
        // triggers (reconcile -> structural or patch path). Belt-and-suspenders:
        // also scroll immediately so the strip follows even if reconcile is
        // delayed or the state is already up to date.
        DispatchQueue.main.async { [weak self] in self?.scrollSelectedTabIntoView(sid) }
    }

    private func showMenu(_ menu: NSMenu, from sender: NSButton) {
        // Defer: popping the menu inside the mouse-up that triggered the
        // action makes the same event dismiss it immediately.
        DispatchQueue.main.async { [weak sender] in
            guard let sender else { return }
            let origin = NSPoint(x: 0, y: sender.bounds.maxY + 4)
            menu.popUp(positioning: nil, at: origin, in: sender)
        }
    }

    @objc private func addFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let (type, title) = Self.menuChoice(raw) else { return }
        performAdd(type, title: title)
    }

    /// "<type>#<label>" from the surface menus.
    static func menuChoice(_ raw: String) -> (SurfaceType, String)? {
        let parts = raw.split(separator: "#", maxSplits: 1).map(String.init)
        guard let type = SurfaceType(rawValue: parts[0]) else { return nil }
        return (type, parts.count == 2 ? parts[1] : title(for: type))
    }

    @objc private func splitFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let direction = SplitDirection(rawValue: parts[0]),
              let (type, title) = Self.menuChoice(parts[1]) else { return }
        performSplit(direction, type: type, title: title)
    }

    /// Testable seam shared by the @objc button handlers.
    @discardableResult
    public func performAdd(_ type: SurfaceType, title: String) -> SurfaceDescriptor? {
        guard let wid = currentWorkspaceID() else { return nil }
        let desc = try? router?.createSurface(workspace: wid, type: type, paneID: pane.id, title: title)
        if let desc { focusNewlyCreatedSurface(desc.id, in: wid) }
        return desc
    }

    @discardableResult
    public func performSplit(_ direction: SplitDirection, type: SurfaceType, title: String) -> SurfaceDescriptor? {
        guard let wid = currentWorkspaceID() else { return nil }
        let desc = try? router?.splitPane(workspace: wid, paneID: pane.id, direction: direction, surfaceType: type, title: title)
        if let desc { focusNewlyCreatedSurface(desc.id, in: wid) }
        return desc
    }

    /// UX-MAC_SHELL_WINDOW-001: route a freshly created surface through
    /// the focus path so its input is first responder immediately — no
    /// extra click before the user can type.
    private func focusNewlyCreatedSurface(_ id: SurfaceID, in workspace: WorkspaceID) {
        try? router?.focusSurface(workspace: workspace, surface: id)
        router?.windowController?.repairSelectedTerminalFocus(reason: "new_surface")
    }

    @discardableResult
    public func performTogglePaneMinimized() -> Bool {
        guard let wid = currentWorkspaceID(), let splitContext else { return false }
        let ratios = Self.toggledPaneMinimizedRatios(paneIndex: splitContext.paneIndex, ratios: splitContext.ratios)
        do {
            try router?.paneResize(workspace: wid, splitID: splitContext.splitID, ratios: ratios)
            return true
        } catch {
            return false
        }
    }

    @objc private func togglePaneMinimized() {
        _ = performTogglePaneMinimized()
    }

    @objc private func headerBarDoubleClicked() {
        _ = performTogglePaneMinimized()
    }

    public static func toggledPaneMinimizedRatios(paneIndex: Int, ratios: [Double]) -> [Double] {
        guard ratios.indices.contains(paneIndex), ratios.count > 1 else { return ratios }
        if isPaneMinimized(paneIndex: paneIndex, ratios: ratios) {
            return Array(repeating: 1.0 / Double(ratios.count), count: ratios.count)
        }
        let minimized = 0.04
        let remaining = 1.0 - minimized
        let otherTotal = ratios.indices
            .filter { $0 != paneIndex }
            .map { ratios[$0] }
            .reduce(0, +)
        return ratios.indices.map {
            if $0 == paneIndex { return minimized }
            guard otherTotal > 0 else { return remaining / Double(ratios.count - 1) }
            return remaining * ratios[$0] / otherTotal
        }
    }

    public static func isPaneMinimized(paneIndex: Int, ratios: [Double]) -> Bool {
        guard ratios.indices.contains(paneIndex) else { return false }
        let normalized = SplitNode.normalize(ratios)
        return normalized[paneIndex] <= 0.08
    }

    /// Pure keyboard-resize helper. Maps (direction, current ratios, paneIndex, step)
    /// to new ratios with the target pane grown or shrunk by `step`.
    ///
    /// Direction semantics (matches tmux / iTerm muscle memory):
    ///   .right / .down  -- grow the target pane (increase its ratio)
    ///   .left  / .up    -- shrink the target pane (decrease its ratio)
    ///
    /// Invariants upheld:
    ///   - sum of returned ratios == 1.0
    ///   - every ratio is clamped to [min, 1 - min]
    ///   - out-of-bounds paneIndex or single-pane ratios return input unchanged
    ///
    /// Pure: only arithmetic -- no AppKit, no MainActor.
    nonisolated public static func paneResizeRatios(
        direction: SplitDirection,
        ratios: [Double],
        paneIndex: Int,
        step: Double = 0.05,
        min: Double = 0.05
    ) -> [Double] {
        guard ratios.count > 1, ratios.indices.contains(paneIndex) else { return ratios }

        let delta: Double = (direction == .right || direction == .down) ? step : -step

        // Compute new target ratio, clamped.
        let maxRatio = 1.0 - min
        let rawTarget = ratios[paneIndex] + delta
        let clampedTarget = Swift.max(min, Swift.min(maxRatio, rawTarget))

        // If clamping absorbed the full delta the target pane is at a bound -- no-op.
        guard clampedTarget != ratios[paneIndex] else { return ratios }

        let actualDelta = clampedTarget - ratios[paneIndex]

        // Distribute the opposite delta evenly among the other panes.
        let otherCount = Double(ratios.count - 1)
        let sharePerOther = -actualDelta / otherCount

        var result = ratios.indices.map { i -> Double in
            if i == paneIndex { return clampedTarget }
            return ratios[i] + sharePerOther
        }

        // Re-normalize to guarantee sum == 1 despite floating-point drift.
        result = SplitNode.normalize(result)
        return result
    }

    /// Keyboard pane resize: adjust the enclosing split's ratios by one step in
    /// the given arrow direction and route through the paneResize reducer.
    /// Returns false when there is no splitContext or the router call fails.
    @discardableResult
    public func performKeyboardPaneResize(direction: SplitDirection, step: Double = 0.05) -> Bool {
        guard let wid = currentWorkspaceID(), let splitContext else { return false }
        let newRatios = Self.paneResizeRatios(
            direction: direction,
            ratios: splitContext.ratios,
            paneIndex: splitContext.paneIndex,
            step: step
        )
        // No-op if ratios are unchanged (already at bound).
        guard newRatios != splitContext.ratios else { return false }
        do {
            try router?.paneResize(workspace: wid, splitID: splitContext.splitID, ratios: newRatios)
            return true
        } catch {
            return false
        }
    }

    /// Pure half-tab drop placement. Returns the insertion index for a
    /// surface dropped onto the tab at `index`: left half -> `index`
    /// (insert before), right half -> `index + 1` (insert after).
    /// Pure: only CGRect geometry and arithmetic -- no AppKit, no MainActor.
    nonisolated public static func halfTabDropIndex(pointerX: CGFloat, tabFrame: NSRect, index: Int) -> Int {
        pointerX < tabFrame.midX ? index : index + 1
    }

    /// Pure tooltip string for a tab button. Format: "<title> -- <type label>".
    /// Pure: only string operations -- no AppKit, no MainActor.
    nonisolated public static func tabTooltipString(title: String, type: SurfaceType) -> String {
        let label: String
        switch type {
        case .terminal: label = L("Terminal")
        case .ssh: label = L("SSH")
        case .browser: label = L("Browser")
        case .agentApp: label = L("Agent App")
        case .files: label = L("Files")
        case .markdown: label = L("Markdown")
        case .filePreview: label = L("File Preview")
        case .rightSidebarTool: label = L("Git")
        @unknown default: label = type.rawValue
        }
        return "\(title) -- \(label)"
    }

    /// PERF: in-place tab-strip reconcile. Pure diff between the old and
    /// new ordered SurfaceID lists so the strip can be patched in place —
    /// existing buttons keep their identity (no container rebuild, no
    /// resize-end flash). Buttons whose id survives are *updated* in
    /// place; only `inserts`/`removes` change the button set, and
    /// `reordered` flags when the surviving ids changed relative order.
    public struct TabStripDiff: Equatable {
        /// ids present in `old` but absent from `new` — buttons to remove.
        public let removes: [SurfaceID]
        /// (id, index-in-new) for ids absent from `old` — buttons to
        /// insert at that position in the new order.
        public let inserts: [(id: SurfaceID, index: Int)]
        /// ids present in BOTH lists, in new order — buttons to update in
        /// place (selection/title/color/dirty) without rebuilding.
        public let updates: [SurfaceID]
        /// true when the relative order of surviving ids differs between
        /// old and new (buttons must be reordered, not just updated).
        public let reordered: Bool

        public static func == (lhs: TabStripDiff, rhs: TabStripDiff) -> Bool {
            lhs.removes == rhs.removes
                && lhs.updates == rhs.updates
                && lhs.reordered == rhs.reordered
                && lhs.inserts.count == rhs.inserts.count
                && zip(lhs.inserts, rhs.inserts).allSatisfy { $0.id == $1.id && $0.index == $1.index }
        }
    }

    /// Pure focus-follows-click resolver. Returns the (workspaceID, paneID)
    /// that should receive focus when the user clicks into a pane's content
    /// area. Returns nil when the pane is already the focused one so the
    /// caller can skip a redundant state write (idempotent path).
    ///
    /// Pure: only ID comparisons — no AppKit, no MainActor dependency.
    nonisolated public static func focusPaneCommand(
        currentFocusedPaneID: PaneID?,
        paneID: PaneID,
        workspaceID: WorkspaceID
    ) -> (workspace: WorkspaceID, pane: PaneID)? {
        guard currentFocusedPaneID != paneID else { return nil }
        return (workspaceID, paneID)
    }

    /// Pure cross-window drop hit-test. Resolves a screen-coordinate drop
    /// point against a set of window frames and returns the id of the window
    /// that should receive the drop, or nil when the point is outside every
    /// frame.
    ///
    /// Ordering contract: `windows` must be supplied in back-to-front order
    /// (matching NSApp.windows, where index 0 is the rearmost window). When
    /// two frames overlap the last match wins — i.e. the topmost window.
    ///
    /// Pure: only NSRect geometry — no AppKit, no MainActor dependency.
    nonisolated public static func windowTarget(
        forScreenPoint point: NSPoint,
        in windows: [(id: UUID, frame: NSRect)]
    ) -> UUID? {
        var result: UUID? = nil
        for entry in windows where entry.frame.contains(point) {
            result = entry.id
        }
        return result
    }

    /// Pure tab-strip diff. Order-preserving: `updates` and the surviving
    /// order are taken from `new`. `reordered` compares the surviving ids'
    /// order in `old` vs `new`.
    public static func diffTabs(old: [SurfaceID], new: [SurfaceID]) -> TabStripDiff {
        let oldSet = Set(old)
        let newSet = Set(new)
        let removes = old.filter { !newSet.contains($0) }
        var inserts: [(id: SurfaceID, index: Int)] = []
        var updates: [SurfaceID] = []
        for (index, id) in new.enumerated() {
            if oldSet.contains(id) {
                updates.append(id)
            } else {
                inserts.append((id: id, index: index))
            }
        }
        // Surviving ids in each list's own order; if those sequences
        // differ, the survivors were reordered.
        let survivorsOld = old.filter { newSet.contains($0) }
        let survivorsNew = new.filter { oldSet.contains($0) }
        let reordered = survivorsOld != survivorsNew
        return TabStripDiff(removes: removes, inserts: inserts, updates: updates, reordered: reordered)
    }

    public static func splitDropDirection(in bounds: NSRect, at point: NSPoint) -> SplitDirection? {
        guard bounds.contains(point) else { return nil }
        let rightIntent = point.x - bounds.midX
        // downIntent positive when point is in the lower half (NSRect: y=0 at bottom).
        let downIntent = bounds.midY - point.y
        let absH = abs(rightIntent)
        let absV = abs(downIntent)
        guard absH > 0 || absV > 0 else { return nil }
        if absH >= absV {
            return rightIntent >= 0 ? .right : .left
        } else {
            return downIntent >= 0 ? .down : .up
        }
    }

    @discardableResult
    public func performReorderSurface(_ surface: SurfaceID, toPane targetPane: PaneID, position: Int) -> Bool {
        guard let wid = currentWorkspaceID() else { return false }
        do {
            try router?.surfaceReorder(workspace: wid, surface: surface, toPane: targetPane, position: position)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func performSplitSurface(_ surface: SurfaceID, direction: SplitDirection) -> Bool {
        performSplitSurface(surface, targetPane: pane.id, direction: direction)
    }

    @discardableResult
    public func performSplitSurface(_ surface: SurfaceID, targetPane: PaneID, direction: SplitDirection) -> Bool {
        guard let wid = currentWorkspaceID() else { return false }
        do {
            try router?.splitSurface(workspace: wid, paneID: targetPane, surface: surface, direction: direction)
            return true
        } catch {
            return false
        }
    }

    private func dropSurface(_ surface: SurfaceID, before target: SurfaceID) -> Bool {
        guard surface != target,
              let position = dropPosition(for: surface, before: target) else { return false }
        return performReorderSurface(surface, toPane: pane.id, position: position)
    }

    private func appendDroppedSurface(_ surface: SurfaceID) -> Bool {
        // Guard the lone-tab self-drop: re-dropping a pane's only surface onto its
        // own tab strip would remove-then-reinsert into a pane that the removal can
        // prune, risking data loss. It is also a visual no-op, so refuse it early.
        if pane.surfaces.count == 1, pane.surfaces.first?.id == surface {
            return false
        }
        let position = adjustedPositionForSamePane(surface, targetPosition: pane.surfaces.count)
        return performReorderSurface(surface, toPane: pane.id, position: position)
    }

    private func dropPosition(for surface: SurfaceID, before target: SurfaceID) -> Int? {
        guard let targetIndex = pane.surfaces.firstIndex(where: { $0.id == target }) else { return nil }
        return adjustedPositionForSamePane(surface, targetPosition: targetIndex)
    }

    private func adjustedPositionForSamePane(_ surface: SurfaceID, targetPosition: Int) -> Int {
        Self.adjustedSamePanePosition(
            sourceIndex: pane.surfaces.firstIndex(where: { $0.id == surface }),
            targetPosition: targetPosition
        )
    }

    /// QA-cross:36 -- the same-pane reorder position rule, shared in semantics with
    /// iOS `TabReorderPlan.plan`: a RIGHTWARD same-pane move must offset its target
    /// by its own removal (target - 1); a LEFTWARD move (sourceIndex >= target) or a
    /// drop with no resolvable source keeps the target. Extracted as a pure seam so
    /// the math is unit-testable and provably matches the iOS plan() offset rule.
    nonisolated static func adjustedSamePanePosition(sourceIndex: Int?, targetPosition: Int) -> Int {
        guard let sourceIndex, sourceIndex < targetPosition else { return targetPosition }
        return max(0, targetPosition - 1)
    }

}

extension PaneTabsView: NSGestureRecognizerDelegate {
    // Gate the header double-click: only the bar's empty chrome toggles the pane.
    // A double-click on a tab (PaneTabButton) opens inline rename; a click on a
    // control button (NSControl) keeps its own action. Both must be left alone.
    public nonisolated func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        MainActor.assumeIsolated {
            guard let host = gestureRecognizer.view else { return true }
            let pointInSuper = (host.superview ?? host).convert(event.locationInWindow, from: nil)
            return Self.headerBarDoubleClickToggles(hitView: host.hitTest(pointInSuper), host: host)
        }
    }

    /// Pure seam: a header double-click toggles the pane only when it lands on the
    /// bar's empty chrome. If the hit view is (or descends from) a tab button or any
    /// control before reaching `host`, the double-click belongs to that element
    /// (tab rename / button action) and must not toggle the pane.
    nonisolated static func headerBarDoubleClickToggles(hitView: NSView?, host: NSView) -> Bool {
        var node = hitView
        while let current = node, current !== host {
            if current is PaneTabButton || current is NSControl { return false }
            node = current.superview
        }
        return true
    }
}

// MARK: - Custom tab button (icon · truncating title · close ×)

@MainActor
final class PaneTabButton: NSView {
    private static weak var highlightedTab: PaneTabButton?
    private static weak var highlightedStrip: PaneTabDropStack?
    private static weak var highlightedSplitRoot: PaneRootView?
    private static weak var dragGhost: TabDragGhostView?
    private let surfaceID: SurfaceID
    private var title: String
    private let symbol: String
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let onCloseOthers: (() -> Void)?
    private let onCloseToLeft: (() -> Void)?
    private let onCloseToRight: (() -> Void)?
    private let onRename: (() -> Void)?
    private let onSetColor: ((String) -> Void)?
    private let onDropSurface: ((SurfaceID) -> Bool)?
    private let onSplitSurface: ((SurfaceID, PaneID, SplitDirection) -> Bool)?
    private let iconContainer = NSView()
    private let dropIndicator = NSView()
    private var hovering = false
    private var dragStarted = false
    private var mouseDownLocation: NSPoint?
    private var selected: Bool
    private var busy = false
    private var unread = false
    private var dirty = false
    // PERF: in-place tab reconcile. These subviews used to be local to
    // init (baked once, then the whole strip was rebuilt on any change).
    // Storing them lets `setSelected`/`setTitle`/`setColor` patch a tab in
    // place keyed by SurfaceID, so a selection/title/color change does not
    // tear down and recreate the button (no resize-end flash).
    private let label = NSTextField(labelWithString: "")
    private let underline = NSView()
    private let colorRail = NSView()
    private let dirtyBadge = NSView()
    private let sep = NSView()
    private static let dragActivationDistance: CGFloat = 8

    // MARK: - A11y helper (pure, no AppKit dependency, testable without MainActor)

    /// Builds the VoiceOver label string for a tab button.
    /// Pure: only string manipulation — safe to call from any context.
    nonisolated static func tabA11yLabel(title: String, isSelected: Bool, isDirty: Bool) -> String {
        var parts: [String] = [title]
        if isDirty { parts.append(L("unsaved changes")) }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    init(surfaceID: SurfaceID, title: String, symbol: String, selected: Bool, busy: Bool = false,
         dirty: Bool = false,
         colorHex: UInt32? = nil,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void,
         onCloseOthers: (() -> Void)? = nil,
         onCloseToLeft: (() -> Void)? = nil,
         onCloseToRight: (() -> Void)? = nil,
         onRename: (() -> Void)? = nil, onSetColor: ((String) -> Void)? = nil,
         onDropSurface: ((SurfaceID) -> Bool)? = nil,
         onSplitSurface: ((SurfaceID, PaneID, SplitDirection) -> Bool)? = nil) {
        self.surfaceID = surfaceID
        self.title = title
        self.symbol = symbol
        self.onSelect = onSelect
        self.onClose = onClose
        self.onCloseOthers = onCloseOthers
        self.onCloseToLeft = onCloseToLeft
        self.onCloseToRight = onCloseToRight
        self.onRename = onRename
        self.onSetColor = onSetColor
        self.onDropSurface = onDropSurface
        self.onSplitSurface = onSplitSurface
        self.selected = selected
        self.dirty = dirty
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = (selected ? DS.NS.bg : DS.NS.surface).cgColor
        // QA-MAC_SHELL_WINDOW-001: addressable tab for UI automation.
        setAccessibilityIdentifier("pane.tab.\(surfaceID.value.uuidString)")
        // A11y: role, label, selected state, and actions so VoiceOver can
        // navigate and operate tabs without a mouse.
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(Self.tabA11yLabel(title: title, isSelected: selected, isDirty: dirty))
        setAccessibilitySelected(selected)
        applyA11yCustomActions()

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.setContentHuggingPriority(.required, for: .horizontal)
        self.busy = busy
        installIcon(busy: busy)

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = selected ? DS.NS.text : DS.NS.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dirtyBadge.wantsLayer = true
        dirtyBadge.layer?.backgroundColor = DS.NS.warning.cgColor
        dirtyBadge.layer?.cornerRadius = 3.5
        dirtyBadge.translatesAutoresizingMaskIntoConstraints = false
        dirtyBadge.isHidden = !dirty
        dirtyBadge.toolTip = L("Unsaved changes")

        let close = NoDragButton(frame: .zero)
        close.isBordered = false
        close.bezelStyle = .inline
        close.imagePosition = .imageOnly
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Close tab"))
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.contentTintColor = DS.NS.textTertiary
        close.translatesAutoresizingMaskIntoConstraints = false
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = L("Close tab")
        close.setAccessibilityIdentifier("pane.tab.\(surfaceID.value.uuidString).close")

        addSubview(iconContainer); addSubview(label); addSubview(dirtyBadge); addSubview(close)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 14),
            iconContainer.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            dirtyBadge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 7),
            dirtyBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirtyBadge.widthAnchor.constraint(equalToConstant: 7),
            dirtyBadge.heightAnchor.constraint(equalToConstant: 7),

            close.leadingAnchor.constraint(equalTo: dirtyBadge.trailingAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16)
        ])

        // Right-edge separator between tabs.
        sep.wantsLayer = true
        sep.layer?.backgroundColor = DS.NS.line.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)
        NSLayoutConstraint.activate([
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.topAnchor.constraint(equalTo: topAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1)
        ])

        // Always create the selection underline and color rail (hidden
        // when inactive) so `setSelected`/`setColor` can toggle them in
        // place during reconcile instead of forcing a button rebuild.
        underline.wantsLayer = true
        underline.layer?.backgroundColor = DS.NS.accent.cgColor
        underline.translatesAutoresizingMaskIntoConstraints = false
        underline.isHidden = !selected
        addSubview(underline)
        NSLayoutConstraint.activate([
            underline.leadingAnchor.constraint(equalTo: leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 2)
        ])

        colorRail.wantsLayer = true
        colorRail.layer?.backgroundColor = colorHex.map { NSColor(hex: $0).cgColor }
        colorRail.translatesAutoresizingMaskIntoConstraints = false
        colorRail.isHidden = colorHex == nil
        addSubview(colorRail)
        NSLayoutConstraint.activate([
            colorRail.leadingAnchor.constraint(equalTo: leadingAnchor),
            colorRail.topAnchor.constraint(equalTo: topAnchor),
            colorRail.bottomAnchor.constraint(equalTo: bottomAnchor),
            colorRail.widthAnchor.constraint(equalToConstant: 3)
        ])

        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = DS.NS.accent.cgColor
        dropIndicator.translatesAutoresizingMaskIntoConstraints = false
        dropIndicator.isHidden = true
        addSubview(dropIndicator)
        NSLayoutConstraint.activate([
            dropIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            dropIndicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            dropIndicator.widthAnchor.constraint(equalToConstant: 3)
        ])

        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    func setBusy(_ busy: Bool) {
        guard self.busy != busy else { return }
        self.busy = busy
        installIcon(busy: busy)
    }

    /// Finished-dot: a small success dot takes the spinner's slot until the tab is focused.
    func setUnread(_ unread: Bool) {
        guard self.unread != unread else { return }
        self.unread = unread
        installIcon(busy: busy)
    }

    /// PERF: in-place selection update used by the tab-strip reconcile.
    /// Re-styles this existing button instead of recreating it, so a focus
    /// change does not rebuild the strip.
    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        if !(hovering && !selected) {
            layer?.backgroundColor = (selected ? DS.NS.bg : DS.NS.surface).cgColor
        }
        label.font = NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = selected ? DS.NS.text : DS.NS.textSecondary
        underline.isHidden = !selected
        // Icon tint tracks selection; reinstall to recolor (cheap, and
        // preserves the spinner when busy).
        installIcon(busy: busy)
        setAccessibilitySelected(selected)
        setAccessibilityLabel(Self.tabA11yLabel(title: title, isSelected: selected, isDirty: dirty))
    }

    /// PERF: in-place title update used by the reconcile (rename).
    func setTitle(_ title: String) {
        guard self.title != title else { return }
        self.title = title
        label.stringValue = title
        setAccessibilityLabel(Self.tabA11yLabel(title: title, isSelected: selected, isDirty: dirty))
    }

    var titleForTesting: String { title }
    var selectedForTesting: Bool { selected }

    /// PERF: in-place color-rail update used by the reconcile.
    func setColorHex(_ hex: UInt32?) {
        colorRail.layer?.backgroundColor = hex.map { NSColor(hex: $0).cgColor }
        colorRail.isHidden = hex == nil
    }

    private func installIcon(busy: Bool) {
        iconContainer.subviews.forEach { $0.removeFromSuperview() }
        let icon: NSView
        if busy {
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.isIndeterminate = true
            spin.startAnimation(nil)
            icon = spin
        } else if unread {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = DS.NS.success.cgColor
            dot.layer?.cornerRadius = 3.5
            dot.toolTip = L("Finished")
            dot.setAccessibilityLabel(L("Finished"))
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7)
            ])
            icon = dot
        } else {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            image.contentTintColor = selected ? DS.NS.text : DS.NS.textTertiary
            icon = image
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            icon.widthAnchor.constraint(lessThanOrEqualTo: iconContainer.widthAnchor),
            icon.heightAnchor.constraint(lessThanOrEqualTo: iconContainer.heightAnchor)
        ])
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = contextMenu()
        guard !menu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func contextMenuForTesting() -> NSMenu {
        contextMenu()
    }

    var surfaceIDForTesting: SurfaceID { surfaceID }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        addContextItem(menu, title: L("Close all others"), action: #selector(closeOthers), enabled: onCloseOthers != nil)
        addContextItem(menu, title: L("Close all to left"), action: #selector(closeToLeft), enabled: onCloseToLeft != nil)
        addContextItem(menu, title: L("Close all to right"), action: #selector(closeToRight), enabled: onCloseToRight != nil)

        if onRename != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let r = NSMenuItem(title: L("Rename…"), action: #selector(renameTab), keyEquivalent: "")
            r.target = self
            menu.addItem(r)
        }
        if onSetColor != nil {
            let colorItem = NSMenuItem(title: L("Color"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let none = NSMenuItem(title: L("None"), action: #selector(colorTab(_:)), keyEquivalent: "")
            none.target = self; none.representedObject = ""
            sub.addItem(none)
            for c in TabColor.allCases {
                let mi = NSMenuItem(title: c.label, action: #selector(colorTab(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = c.rawValue
                mi.image = Self.colorSwatchImage(hex: c.hex)
                sub.addItem(mi)
            }
            colorItem.submenu = sub
            menu.addItem(colorItem)
        }
        return menu
    }

    private func addContextItem(_ menu: NSMenu, title: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = enabled ? self : nil
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func renameTab() { onRename?() }
    @objc private func closeOthers() { onCloseOthers?() }
    @objc private func closeToLeft() { onCloseToLeft?() }
    @objc private func closeToRight() { onCloseToRight?() }
    @objc private func colorTab(_ sender: NSMenuItem) {
        onSetColor?((sender.representedObject as? String) ?? "")
    }

    private static func colorSwatchImage(hex: UInt32) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        NSColor(hex: hex).setFill()
        path.fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    required init?(coder: NSCoder) { fatalError() }

    // In the full-size-content titlebar band, AppKit would otherwise
    // treat clicks here as a window drag and the tab/close never fire.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === self { return self }
        if let button = enclosingView(from: hit, as: NSButton.self) { return button }
        return self
    }

    // PERF-MAC_SHELL_WINDOW-005: if this tab is torn out of its window
    // mid-drag (e.g. window closed during a drag), the static drag-feedback
    // refs would otherwise leak a ghost/highlight until the next clear.
    // Clearing on detach scopes cleanup to the originating window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { Self.clearDragFeedback() }
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
        mouseDownLocation = event.locationInWindow
        Self.clearDragFeedback()
    }

    override func mouseDragged(with event: NSEvent) {
        if !dragStarted {
            guard Self.hasMovedBeyondDragThreshold(from: mouseDownLocation,
                                                   to: event.locationInWindow,
                                                   threshold: Self.dragActivationDistance) else { return }
            dragStarted = true
        }
        updateDragGhost(with: event)
        updateManualDropFeedback(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        if dragStarted {
            performManualDrop(with: event)
            Self.clearDragFeedback()
        } else if event.modifierFlags.contains(.command) {
            // IMP-MAC_SHELL_WINDOW-006: ⌘-click closes the tab (browser
            // muscle memory); ⌥⌘-click closes the other tabs instead.
            if event.modifierFlags.contains(.option) {
                (onCloseOthers ?? onClose)()
            } else {
                onClose()
            }
        } else if event.clickCount == 2 {
            // UX-P3: double-click opens inline rename editor.
            onRename?()
        } else {
            onSelect()
        }
    }

    // UX-MAC_SHELL_WINDOW-015: middle-click closes the tab (browser/editor
    // expectation). Routes through onClose so the unsaved-changes confirm
    // runs exactly as the "×" button does.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onClose()
    }

    private func performManualDrop(with event: NSEvent) {
        guard let sourceWindow = window else { return }
        let screenPoint = sourceWindow.convertPoint(toScreen: event.locationInWindow)
        let windows = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized && $0.contentView != nil }
        let indexed = windows.map { (id: UUID(), frame: $0.frame) }
        guard let targetId = PaneTabsView.windowTarget(forScreenPoint: screenPoint, in: indexed),
              let index = indexed.firstIndex(where: { $0.id == targetId }),
              let contentView = windows[index].contentView else { return }
        let pointInWindow = windows[index].convertPoint(fromScreen: screenPoint)
        let point = contentView.convert(pointInWindow, from: nil as NSView?)
        guard let hit = contentView.hitTest(point) else { return }
        routeManualDrop(hit: hit, contentPoint: point, in: contentView)
    }

    /// QA-MAC_SHELL_WINDOW-004: the drop-routing decision (tab vs strip vs
    /// split) extracted from the live mouse event so it can be exercised
    /// with a synthetic hit view + content-space point in tests, without a
    /// real drag gesture.
    func performManualDropForTesting(hit: NSView, contentPoint: NSPoint, in contentView: NSView) {
        routeManualDrop(hit: hit, contentPoint: contentPoint, in: contentView)
    }

    private func routeManualDrop(hit: NSView, contentPoint point: NSPoint, in contentView: NSView) {
        if let target = enclosingView(from: hit, as: PaneTabButton.self), target !== self {
            // UX-P3: half-tab drop placement — pointer in the right half
            // of the target tab means "insert after", so we route to the
            // NEXT sibling tab (insert before next = insert after current).
            // If there is no next tab, fall through to the strip (append).
            let targetFrameInContent = target.convert(target.bounds, to: contentView)
            let pointerX = point.x
            let wantAfter = pointerX >= targetFrameInContent.midX

            if wantAfter, let strip = target.superview as? PaneTabDropStack {
                let tabs = strip.arrangedSubviews.compactMap { $0 as? PaneTabButton }
                if let idx = tabs.firstIndex(where: { $0 === target }),
                   idx + 1 < tabs.count {
                    // There is a next tab: insert before it.
                    _ = tabs[idx + 1].onDropSurface?(surfaceID)
                } else {
                    // No next tab: append to the strip.
                    _ = strip.onDropSurface?(surfaceID)
                }
            } else {
                _ = target.onDropSurface?(surfaceID)
            }
            return
        }
        if let strip = enclosingView(from: hit, as: PaneTabDropStack.self) {
            _ = strip.onDropSurface?(surfaceID)
            return
        }
        if let target = splitTarget(for: hit, contentPoint: point, in: contentView) {
            _ = onSplitSurface?(surfaceID, target.paneID, target.direction)
        }
    }

    private func updateManualDropFeedback(with event: NSEvent) {
        guard let contentView = window?.contentView else {
            Self.clearDragFeedback()
            return
        }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else {
            Self.clearDragFeedback()
            return
        }
        if let target = enclosingView(from: hit, as: PaneTabButton.self), target !== self {
            Self.highlight(tab: target, strip: nil)
            return
        }
        if let strip = enclosingView(from: hit, as: PaneTabDropStack.self) {
            Self.highlight(tab: nil, strip: strip)
            return
        }
        if let target = splitTarget(for: hit, contentPoint: point, in: contentView) {
            Self.highlight(tab: nil, strip: nil, splitRoot: target.root, splitDirection: target.direction)
            return
        }
        Self.clearDragFeedback()
    }

    private func splitTarget(for hit: NSView, contentPoint: NSPoint, in contentView: NSView) -> (paneID: PaneID, direction: SplitDirection, root: PaneRootView)? {
        guard let root = enclosingView(from: hit, as: PaneRootView.self),
              let paneID = root.paneID else { return nil }
        let point = root.convert(contentPoint, from: contentView)
        guard let direction = PaneTabsView.splitDropDirection(in: root.bounds, at: point) else { return nil }
        return (paneID, direction, root)
    }

    private func updateDragGhost(with event: NSEvent) {
        guard let contentView = window?.contentView else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        if Self.dragGhost == nil {
            let ghost = TabDragGhostView(title: title, symbol: symbol)
            contentView.addSubview(ghost)
            Self.dragGhost = ghost
        }
        Self.dragGhost?.move(near: point, in: contentView.bounds)
    }

    private static func highlight(tab: PaneTabButton?, strip: PaneTabDropStack?, splitRoot: PaneRootView? = nil, splitDirection: SplitDirection? = nil) {
        if highlightedTab !== tab {
            highlightedTab?.setDropHighlighted(false)
            highlightedTab = tab
            highlightedTab?.setDropHighlighted(true)
        }
        if highlightedStrip !== strip {
            highlightedStrip?.setAppendHighlighted(false)
            highlightedStrip = strip
            highlightedStrip?.setAppendHighlighted(true)
        }
        if highlightedSplitRoot !== splitRoot {
            highlightedSplitRoot?.setSplitDropHighlighted(false)
            highlightedSplitRoot = splitRoot
            highlightedSplitRoot?.setSplitDropHighlighted(splitRoot != nil, direction: splitDirection)
        } else if splitRoot != nil {
            highlightedSplitRoot?.setSplitDropHighlighted(true, direction: splitDirection)
        }
    }

    private static func clearDragFeedback() {
        highlightedTab?.setDropHighlighted(false)
        highlightedTab = nil
        highlightedStrip?.setAppendHighlighted(false)
        highlightedStrip = nil
        highlightedSplitRoot?.setSplitDropHighlighted(false)
        highlightedSplitRoot = nil
        dragGhost?.removeFromSuperview()
        dragGhost = nil
    }

    private func setDropHighlighted(_ active: Bool) {
        dropIndicator.isHidden = !active
        if active {
            layer?.backgroundColor = DS.NS.surfaceRaised.cgColor
        } else if hovering && !selected {
            layer?.backgroundColor = DS.NS.surfaceRaised.cgColor
        } else {
            layer?.backgroundColor = (selected ? DS.NS.bg : DS.NS.surface).cgColor
        }
    }

    private func enclosingView<T: NSView>(from view: NSView, as type: T.Type) -> T? {
        var current: NSView? = view
        while let candidate = current {
            if let typed = candidate as? T { return typed }
            current = candidate.superview
        }
        return nil
    }

    @objc private func closeClicked() { onClose() }

    /// Starts an inline rename editor overlaid on the tab label.
    /// Calls `commit` with the trimmed new name when the user confirms
    /// (Return / Tab); cancels silently on Escape or focus-loss with empty input.
    func beginInlineRename(_ commit: @escaping (String) -> Void) {
        // Guard: don't stack editors.
        guard !subviews.contains(where: { $0 is InlineRenameField }) else { return }
        let field = InlineRenameField(frame: label.frame)
        field.stringValue = title
        field.onCommit = { [weak self, weak field] in
            guard let self, let field else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            field.removeFromSuperview()
            if !value.isEmpty { commit(value) }
        }
        field.onCancel = { [weak field] in field?.removeFromSuperview() }
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: label.centerYAnchor)
        ])
        window?.makeFirstResponder(field)
    }

    func setDirty(_ dirty: Bool) {
        self.dirty = dirty
        dirtyBadge.isHidden = !dirty
        setAccessibilityLabel(Self.tabA11yLabel(title: title, isSelected: selected, isDirty: dirty))
    }

    // Appearance-change: re-resolves all CGColors captured on CALayers at
    // construction. Called from both init (via the stored-property setters
    // above) and viewDidChangeEffectiveAppearance so there is one source of
    // truth for the color semantics.
    private func applyChromeColors() {
        if selected {
            layer?.backgroundColor = DS.NS.bg.cgColor
        } else if hovering {
            layer?.backgroundColor = DS.NS.surfaceRaised.cgColor
        } else {
            layer?.backgroundColor = DS.NS.surface.cgColor
        }
        dirtyBadge.layer?.backgroundColor = DS.NS.warning.cgColor
        sep.layer?.backgroundColor = DS.NS.line.cgColor
        underline.layer?.backgroundColor = DS.NS.accent.cgColor
        dropIndicator.layer?.backgroundColor = DS.NS.accent.cgColor
        // colorRail holds a user-chosen hex (appearance-independent); skip.
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    /// A11y: register close and rename as named custom actions so
    /// VoiceOver users can invoke them from the Actions rotor without
    /// moving focus to the sub-buttons.
    private func applyA11yCustomActions() {
        var actions: [NSAccessibilityCustomAction] = []
        actions.append(NSAccessibilityCustomAction(name: L("Close tab")) { [weak self] in
            self?.onClose()
            return true
        })
        if onRename != nil {
            actions.append(NSAccessibilityCustomAction(name: L("Rename tab")) { [weak self] in
                self?.onRename?()
                return true
            })
        }
        setAccessibilityCustomActions(actions)
    }

    /// Test seam: how many custom actions are registered on this tab.
    var accessibilityCustomActionCountForTesting: Int {
        (accessibilityCustomActions() ?? []).count
    }

    static func hasMovedBeyondDragThreshold(from start: NSPoint?, to current: NSPoint, threshold: CGFloat) -> Bool {
        guard let start else { return false }
        return hypot(current.x - start.x, current.y - start.y) >= threshold
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if !selected { layer?.backgroundColor = DS.NS.surfaceRaised.cgColor }
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !selected { layer?.backgroundColor = DS.NS.surface.cgColor }
    }
}

@MainActor
final class TabDragGhostView: NSView {
    private let width: CGFloat = 210
    private let height: CGFloat = 30

    init(title: String, symbol: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = DS.NS.surfaceRaised.withAlphaComponent(0.92).cgColor
        layer?.borderColor = DS.NS.accent.withAlphaComponent(0.65).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = DS.Radius.control
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        alphaValue = 0.96

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = DS.NS.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = DS.NS.text
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    private func applyChromeColors() {
        layer?.backgroundColor = DS.NS.surfaceRaised.withAlphaComponent(0.92).cgColor
        layer?.borderColor = DS.NS.accent.withAlphaComponent(0.65).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    func move(near point: NSPoint, in bounds: NSRect) {
        let x = min(max(point.x + 12, bounds.minX + 6), bounds.maxX - width - 6)
        let y = min(max(point.y - height - 10, bounds.minY + 6), bounds.maxY - height - 6)
        frame.origin = NSPoint(x: x, y: y)
    }
}

// MARK: - Non-draggable header containers
//
// With `.fullSizeContentView` the tab bar lives inside the titlebar
// band. Container views default `mouseDownCanMoveWindow` to true, so
// AppKit starts a window drag on mouse-down and the buttons/tabs never
// receive the click. These subclasses opt the interactive subtree out
// of window dragging. (headerBG stays a plain NSView so its empty area
// can still drag the window.)

class NoDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class PaneRootView: NoDragView {
    static let splitDropOverlayLayerName = "split-drop-preview"
    var paneID: PaneID?
    /// Called before super.mouseDown so content-area clicks route pane focus
    /// before AppKit dispatches the event into the surface subview hierarchy.
    var onContentAreaMouseDown: (() -> Void)?
    private let splitDropOverlay = CALayer()
    private var splitDropDirection: SplitDirection?
    // Appearance-change: weak refs to chrome subviews whose CGColors must be
    // re-resolved when the effective appearance changes. Wired by PaneTabsView.init
    // and buildMinimizedSideRail after those views are created.
    weak var chromeHeaderBG: NSView?
    weak var chromeContentArea: NSView?
    var chromeDividers: [NSView] = []

    override func mouseDown(with event: NSEvent) {
        onContentAreaMouseDown?()
        super.mouseDown(with: event)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSplitDropOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSplitDropOverlay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsUpdateConstraints = true
        needsLayout = true
        // PERF-MAC_SHELL_WINDOW-MED-129: during a live divider drag the parent
        // RatioSplitView fires setFrameSize on every mouse-moved tick. Forcing
        // a synchronous AutoLayout subtree solve per tick causes hundreds of
        // redundant solves per second (jank). When a drag is active, mark the
        // subtree dirty and defer — AppKit coalesces the solve at the next frame
        // boundary. On drag-end RatioSplitView clears the flag and forces one
        // final solve so the layout always converges to the correct final frame.
        guard !RatioSplitView.dividerDragActive else { return }
        updateConstraintsForSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        splitDropOverlay.frame = splitDropPreviewFrame(in: bounds, direction: splitDropDirection)
    }

    func setSplitDropHighlighted(_ active: Bool, direction: SplitDirection? = nil) {
        if splitDropOverlay.superlayer == nil {
            configureSplitDropOverlay()
        }
        splitDropDirection = active ? direction : nil
        splitDropOverlay.isHidden = !active
        splitDropOverlay.backgroundColor = DS.NS.splitPreviewFill.cgColor
        splitDropOverlay.borderColor = DS.NS.splitPreviewStroke.cgColor
        splitDropOverlay.borderWidth = active ? 2 : 0
        splitDropOverlay.frame = splitDropPreviewFrame(in: bounds, direction: splitDropDirection)
    }

    private func configureSplitDropOverlay() {
        wantsLayer = true
        splitDropOverlay.name = Self.splitDropOverlayLayerName
        splitDropOverlay.backgroundColor = DS.NS.splitPreviewFill.cgColor
        splitDropOverlay.borderColor = DS.NS.splitPreviewStroke.cgColor
        splitDropOverlay.borderWidth = 0
        splitDropOverlay.cornerRadius = 6
        splitDropOverlay.zPosition = 1_000
        splitDropOverlay.isHidden = true
        splitDropOverlay.masksToBounds = true
        layer?.addSublayer(splitDropOverlay)
    }

    // Appearance-change: re-resolves all CGColors captured on CALayers at
    // construction time so that light<->dark switches recolor the chrome.
    // Called from viewDidChangeEffectiveAppearance which already runs inside
    // the new appearance context, so plain .cgColor reads resolve correctly.
    private func applyChromeColors() {
        layer?.backgroundColor = DS.NS.bg.cgColor
        chromeHeaderBG?.layer?.backgroundColor = DS.NS.surface.cgColor
        chromeContentArea?.layer?.backgroundColor = DS.NS.bg.cgColor
        for d in chromeDividers { d.layer?.backgroundColor = DS.NS.line.cgColor }
        splitDropOverlay.backgroundColor = DS.NS.splitPreviewFill.cgColor
        splitDropOverlay.borderColor = DS.NS.splitPreviewStroke.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    private func splitDropPreviewFrame(in bounds: NSRect, direction: SplitDirection?) -> NSRect {
        let target: NSRect
        switch direction {
        case .left:
            target = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .right:
            target = NSRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .up:
            target = NSRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
        case .down:
            target = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
        case nil:
            target = bounds
        }
        return target.insetBy(dx: 2, dy: 2)
    }
}

class NoDragStack: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
final class PaneTabDropStack: NoDragStack {
    var onDropSurface: ((SurfaceID) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureDropFeedback()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDropFeedback()
    }

    func setAppendHighlighted(_ active: Bool) {
        layer?.borderWidth = active ? 1 : 0
        layer?.backgroundColor = active ? DS.NS.surfaceRaised.withAlphaComponent(0.45).cgColor : NSColor.clear.cgColor
    }

    private func configureDropFeedback() {
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        layer?.borderColor = DS.NS.accent.cgColor
        layer?.borderWidth = 0
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func applyChromeColors() {
        layer?.borderColor = DS.NS.accent.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

}

class NoDragScroll: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class HorizontalTabScrollView: NoDragScroll {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        contentView.postsBoundsChangedNotifications = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) < abs(event.scrollingDeltaY),
              abs(event.scrollingDeltaY) > 0 else {
            super.scrollWheel(with: event)
            return
        }
        scrollHorizontally(by: -event.scrollingDeltaY)
    }

    func scrollDocumentViewToVisible(_ view: NSView) {
        guard let documentView else { return }
        let rect = view.convert(view.bounds, to: documentView).insetBy(dx: -20, dy: 0)
        documentView.scrollToVisible(rect)
    }

    func scrollHorizontally(by delta: CGFloat) {
        guard let documentView else { return }
        var bounds = contentView.bounds
        let maxX = max(0, documentView.bounds.width - bounds.width)
        bounds.origin.x = min(max(0, bounds.origin.x + delta), maxX)
        contentView.scroll(to: bounds.origin)
        reflectScrolledClipView(contentView)
    }
}

final class NoDragButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Inline rename text field

/// Lightweight NSTextField subclass used for double-click tab rename.
/// Commits on Return or Tab; cancels on Escape or when it loses focus
/// with the stringValue still equal to the original value.
@MainActor
final class InlineRenameField: NSTextField {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        font = NSFont.systemFont(ofSize: 12, weight: .medium)
        textColor = DS.NS.text
        backgroundColor = DS.NS.bg
        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 48: // Return (36), Tab (48)
            onCommit?()
        case 53: // Escape
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onCommit?() }
        return result
    }
}
