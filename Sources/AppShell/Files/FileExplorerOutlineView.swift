import AppKit
import SwiftUI

/// VS Code Dark Modern explorer metrics and colors.
enum ExplorerStyle {
    /// vscode: src/vs/workbench/contrib/files/browser/media/explorerviewlet.css `.explorer-item { height: 22px }`.
    static let rowHeight: CGFloat = 22
    /// vscode: src/vs/platform/list/browser/listService.ts `workbench.tree.indent` default 8.
    static let indent: CGFloat = 8
    /// vscode: src/vs/base/browser/ui/tree/media/tree.css `.monaco-tl-twistie { width: 16px }`.
    static let twistieWidth: CGFloat = 16
    /// vscode: tree.css `.monaco-tl-indent { left: 16px }` base offset (twistie column).
    static let leadingInset: CGFloat = 8
    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    // vscode: extensions/theme-defaults/themes/dark_modern.json sideBar.background / foreground.
    static let background = color(0x181818)
    static let foreground = color(0xCCCCCC)
    // vscode: src/vs/platform/theme/common/colors/listColors.ts (dark defaults).
    static let hover = color(0x2A2D2E)
    static let activeSelection = color(0x04395E)
    static let inactiveSelection = color(0x37373D)
    static let focusOutline = color(0x0078D4)
    static let dropBackground = color(0x062F4A)
    static let indentGuide = color(0x585858)
}

/// Stable reference item so NSOutlineView keeps expansion/selection across reloads.
final class ExplorerNode: NSObject {
    var entry: FileEntry
    init(_ entry: FileEntry) { self.entry = entry }
}

/// The explorer tree: an AppKit `NSOutlineView` hosted in SwiftUI.
struct FileExplorerOutline: NSViewRepresentable {
    @ObservedObject var model: FilesViewModel
    var showHidden: Bool
    var onNewFile: (String) -> Void
    var onNewFolder: (String) -> Void
    var onRequestDelete: ([FileEntry]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ExplorerOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = ExplorerStyle.rowHeight
        outline.indentationPerLevel = ExplorerStyle.indent
        outline.indentationMarkerFollowsCell = false
        outline.intercellSpacing = .zero
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.backgroundColor = ExplorerStyle.background
        outline.gridStyleMask = []
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.focusRingType = .none
        outline.setAccessibilityIdentifier("files.sidebar.list")
        outline.registerForDraggedTypes([.fileURL, ExplorerOutlineView.movePasteboardType])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)

        let coordinator = context.coordinator
        coordinator.outline = outline
        coordinator.parent = self
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.action = #selector(Coordinator.clicked(_:))
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.menuProvider = { [weak coordinator] row in coordinator?.menu(forRow: row) }
        outline.keyHandler = { [weak coordinator] event in coordinator?.handleKey(event) ?? false }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = ExplorerStyle.background
        scroll.borderType = .noBorder
        coordinator.reload(force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let showHiddenChanged = coordinator.parent?.showHidden != showHidden
        coordinator.parent = self
        if coordinator.lastRevision != model.treeRevision || showHiddenChanged {
            coordinator.reload(force: false)
        } else {
            coordinator.syncExpansion()
            coordinator.syncSelection()
            coordinator.refreshVisibleRows()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        var parent: FileExplorerOutline?
        weak var outline: ExplorerOutlineView?
        var lastRevision = -1
        private var nodes: [String: ExplorerNode] = [:]
        private var syncing = false
        private var renamingPath: String?

        private var model: FilesViewModel? { parent?.model }

        func node(for entry: FileEntry) -> ExplorerNode {
            if let existing = nodes[entry.relativePath] {
                existing.entry = entry
                return existing
            }
            let node = ExplorerNode(entry)
            nodes[entry.relativePath] = node
            return node
        }

        func visible(_ items: [FileEntry]) -> [FileEntry] {
            visibleFileEntries(items, showHidden: parent?.showHidden ?? false, query: "", isHidden: \.isHidden)
        }

        func children(of item: Any?) -> [FileEntry] {
            guard let model else { return [] }
            guard let node = item as? ExplorerNode else { return visible(model.entries) }
            return visible(model.childEntries(for: node.entry))
        }

        func reload(force: Bool) {
            guard let outline, let model else { return }
            lastRevision = model.treeRevision
            syncing = true
            outline.reloadData()
            syncing = false
            syncExpansion()
            syncSelection()
        }

        /// Expand rows for `model.expandedPaths`, parents first, collapse the rest.
        func syncExpansion() {
            guard let outline, let model else { return }
            syncing = true
            defer { syncing = false }
            var row = 0
            while row < outline.numberOfRows {
                if let node = outline.item(atRow: row) as? ExplorerNode, node.entry.isDirectory {
                    let shouldExpand = model.expandedPaths.contains(node.entry.relativePath)
                    if shouldExpand, !outline.isItemExpanded(node) {
                        outline.expandItem(node)
                    } else if !shouldExpand, outline.isItemExpanded(node) {
                        outline.collapseItem(node)
                    }
                }
                row += 1
            }
        }

        func syncSelection() {
            guard let outline, let model, let selected = model.selectedEntry,
                  let node = nodes[selected.relativePath] else { return }
            let row = outline.row(forItem: node)
            guard row >= 0, !outline.selectedRowIndexes.contains(row) else { return }
            syncing = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            syncing = false
        }

        func refreshVisibleRows() {
            guard let outline else { return }
            let range = outline.rows(in: outline.visibleRect)
            guard range.length > 0 else { return }
            for row in range.location..<NSMaxRange(range) {
                (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ExplorerCellView)?.needsDisplay = true
                if let item = outline.item(atRow: row) as? ExplorerNode,
                   let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ExplorerCellView {
                    configure(cell, with: item, row: row)
                }
            }
        }

        var selectedEntries: [FileEntry] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ExplorerNode)?.entry }
        }

        // MARK: Data source

        // NSOutlineView only asks for children of expanded items, so folders list lazily.
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? ExplorerNode, !node.entry.isDirectory { return 0 }
            return children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            node(for: children(of: item)[index])
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? ExplorerNode)?.entry.isDirectory ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? ExplorerNode, let model else { return false }
            _ = model.childEntries(for: node.entry)
            return true
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? ExplorerNode else { return }
            model?.expandedPaths.insert(node.entry.relativePath)
            refreshTwistie(node)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? ExplorerNode else { return }
            model?.expandedPaths.remove(node.entry.relativePath)
            refreshTwistie(node)
        }

        private func refreshTwistie(_ node: ExplorerNode) {
            guard let outline else { return }
            let row = outline.row(forItem: node)
            if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ExplorerCellView {
                configure(cell, with: node, row: row)
            }
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            ExplorerRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? ExplorerNode else { return nil }
            let id = NSUserInterfaceItemIdentifier("ExplorerCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? ExplorerCellView ?? {
                let created = ExplorerCellView()
                created.identifier = id
                return created
            }()
            configure(cell, with: node, row: outlineView.row(forItem: node))
            return cell
        }

        private func configure(_ cell: ExplorerCellView, with node: ExplorerNode, row: Int) {
            guard let outline, let model else { return }
            let entry = node.entry
            cell.level = max(0, outline.level(forItem: node))
            cell.isDirectory = entry.isDirectory
            cell.isExpanded = entry.isDirectory && outline.isItemExpanded(node)
            cell.nameField.stringValue = entry.name
            cell.iconName = entry.isDirectory ? nil : entry.icon
            cell.iconColor = ExplorerStyle.color(fileIconColorHex(for: entry.name))
            cell.gitStatus = model.gitStatuses[entry.relativePath]
            cell.isDirtyFile = model.dirtyPaths.contains(entry.relativePath)
            cell.setAccessibilityIdentifier("files.row.\(entry.relativePath)")
            cell.setAccessibilityLabel(entry.name)
            cell.nameField.delegate = self
            cell.applyStyle()
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        }

        // MARK: Actions

        @objc func clicked(_ sender: Any?) {
            guard let outline, let model else { return }
            let row = outline.clickedRow
            guard row >= 0, let node = outline.item(atRow: row) as? ExplorerNode else { return }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            guard !modifiers.contains(.command), !modifiers.contains(.shift) else { return }
            if node.entry.isDirectory {
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            } else {
                model.selectIfNeeded(node.entry)
            }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, let model else { return }
            let row = outline.clickedRow
            guard row >= 0, let node = outline.item(atRow: row) as? ExplorerNode, !node.entry.isDirectory else { return }
            model.selectIfNeeded(node.entry)
        }

        func handleKey(_ event: NSEvent) -> Bool {
            guard let outline, let model else { return false }
            let selected = selectedEntries
            switch event.keyCode {
            case 36, 76: // Return: rename (VS Code on macOS)
                guard selected.count == 1 else { return false }
                beginRename(selected[0])
                return true
            case 51 where event.modifierFlags.contains(.command): // Cmd+Backspace
                guard !selected.isEmpty else { return false }
                parent?.onRequestDelete(selected)
                return true
            case 125 where event.modifierFlags.contains(.command), 49: // Cmd+Down / Space: open
                guard let entry = selected.first else { return false }
                if entry.isDirectory {
                    let node = node(for: entry)
                    if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
                } else {
                    model.selectIfNeeded(entry)
                }
                return true
            default:
                return false
            }
        }

        func beginRename(_ entry: FileEntry) {
            guard let outline else { return }
            let row = outline.row(forItem: node(for: entry))
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ExplorerCellView else { return }
            renamingPath = entry.relativePath
            cell.beginEditing(selecting: filesBasenameSelectionRange(for: entry.name))
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let path = renamingPath, let model else { return }
            renamingPath = nil
            (field.superview as? ExplorerCellView)?.endEditing()
            let movement = obj.userInfo?["NSTextMovement"] as? Int
            guard let entry = nodes[path]?.entry else { return }
            if movement == NSTextMovement.cancel.rawValue || field.stringValue == entry.name {
                field.stringValue = entry.name
                return
            }
            model.rename(entry, to: field.stringValue)
            outline?.window?.makeFirstResponder(outline)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)), let path = renamingPath,
               let entry = nodes[path]?.entry, let field = control as? NSTextField {
                field.stringValue = entry.name
                outline?.window?.makeFirstResponder(outline)
                return true
            }
            return false
        }

        // MARK: Context menu

        func menu(forRow row: Int) -> NSMenu? {
            guard let outline, let model else { return nil }
            let clicked = row >= 0 ? (outline.item(atRow: row) as? ExplorerNode)?.entry : nil
            if row >= 0, !outline.selectedRowIndexes.contains(row) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let targets = clicked == nil ? [] : (selectedEntries.count > 1 ? selectedEntries : [clicked!])
            let menu = NSMenu()
            let directory = model.explorerTargetDirectory(for: clicked)
            menu.addItem(ExplorerMenuItem("New File…") { [weak self] in self?.parent?.onNewFile(directory) })
            menu.addItem(ExplorerMenuItem("New Folder…") { [weak self] in self?.parent?.onNewFolder(directory) })
            guard !targets.isEmpty else { return menu }
            menu.addItem(.separator())
            if targets.count == 1, let entry = targets.first {
                if !entry.isDirectory {
                    menu.addItem(ExplorerMenuItem("Open in New Tab") { model.openInNewTab(entry) })
                    menu.addItem(ExplorerMenuItem("Open with Default App") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
                    })
                }
                menu.addItem(ExplorerMenuItem("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                })
                menu.addItem(.separator())
                menu.addItem(ExplorerMenuItem("Copy Path") { Self.copy(entry.path) })
                menu.addItem(ExplorerMenuItem("Copy Relative Path") { Self.copy(entry.relativePath) })
                menu.addItem(.separator())
                menu.addItem(ExplorerMenuItem("Rename…") { [weak self] in self?.beginRename(entry) })
                menu.addItem(ExplorerMenuItem("Move to Trash") { [weak self] in self?.parent?.onRequestDelete(targets) })
            } else {
                let item = ExplorerMenuItem("Open \(targets.count) Files in New Tabs") {
                    targets.filter { !$0.isDirectory }.forEach { model.openInNewTab($0) }
                }
                item.setAccessibilityIdentifier("files.contextMenu.openAllInTabs")
                menu.addItem(item)
                let reveal = ExplorerMenuItem("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(targets.map { URL(fileURLWithPath: $0.path) })
                }
                reveal.setAccessibilityIdentifier("files.contextMenu.revealAll")
                menu.addItem(reveal)
                menu.addItem(ExplorerMenuItem("Copy Paths") { Self.copy(targets.map(\.path).joined(separator: "\n")) })
                menu.addItem(.separator())
                menu.addItem(ExplorerMenuItem("Move \(targets.count) Items to Trash") { [weak self] in self?.parent?.onRequestDelete(targets) })
            }
            return menu
        }

        private static func copy(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? ExplorerNode else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(URL(fileURLWithPath: node.entry.path).absoluteString, forType: .fileURL)
            pbItem.setString(node.entry.relativePath, forType: ExplorerOutlineView.movePasteboardType)
            if let payload = node.entry.dragPayload { pbItem.setString(payload, forType: .string) }
            return pbItem
        }

        private func dropDirectory(for item: Any?) -> String? {
            guard let model else { return nil }
            guard let node = item as? ExplorerNode else { return model.currentDirectory }
            return model.explorerTargetDirectory(for: node.entry)
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            // Retarget drops onto files to their folder, like VS Code.
            if let node = item as? ExplorerNode, !node.entry.isDirectory {
                let parentItem = outlineView.parent(forItem: node)
                outlineView.setDropItem(parentItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else if index != NSOutlineViewDropOnItemIndex {
                outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            let internalMove = info.draggingPasteboard.string(forType: ExplorerOutlineView.movePasteboardType) != nil
            return internalMove ? .move : .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let model, let destination = dropDirectory(for: item) else { return false }
            let pasteboard = info.draggingPasteboard
            let moved = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: ExplorerOutlineView.movePasteboardType) }
            if !moved.isEmpty {
                for path in moved {
                    guard let entry = nodes[path]?.entry ?? model.allKnownEntry(relativePath: path) else { continue }
                    let currentParent = (path as NSString).deletingLastPathComponent
                    if (currentParent == "." ? "" : currentParent) == destination { continue }
                    model.moveEntry(entry, intoDirWithPath: destination)
                }
                return true
            }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            let target = URL(fileURLWithPath: (model.root as NSString).appendingPathComponent(destination))
            do {
                try copyIntoFolder(urls, folder: target)
            } catch {
                model.errorText = String(describing: error)
            }
            if !destination.isEmpty { model.expandedPaths.insert(destination) }
            model.refreshTree()
            return true
        }
    }
}

/// Copies Finder items into `folder` without overwriting: collisions get a " copy" suffix.
func copyIntoFolder(_ urls: [URL], folder: URL) throws {
    let manager = FileManager.default
    for source in urls {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while manager.fileExists(atPath: candidate.path) {
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            let name = ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: candidate,
                                       options: .forReplacing, error: &coordinationError) { from, to in
            do { try manager.copyItem(at: from, to: to) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
    }
}

final class ExplorerMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

/// Outline with the default disclosure triangle removed (cells draw their own twistie).
final class ExplorerOutlineView: NSOutlineView {
    static let movePasteboardType = NSPasteboard.PasteboardType("io.remotecode.files.explorer-move")
    var menuProvider: ((Int) -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        // Cells span the full row; indentation is drawn by the cell (VS Code rows highlight edge to edge).
        return NSRect(x: 0, y: frame.minY, width: bounds.width, height: frame.height)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(row(at: point))
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        ExplorerStyle.background.setFill()
        clipRect.fill()
    }
}

/// Flat VS Code list row: hover, focused selection with outline, unfocused selection.
final class ExplorerRowView: NSTableRowView {
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var outlineHasFocus: Bool {
        guard let outline = superview as? NSOutlineView, let window = outline.window else { return false }
        return window.isKeyWindow && window.firstResponder === outline
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if dropHighlight {
            ExplorerStyle.dropBackground.setFill()
            bounds.fill()
        } else if hovering, !isSelected {
            ExplorerStyle.hover.setFill()
            bounds.fill()
        } else {
            ExplorerStyle.background.setFill()
            bounds.fill()
        }
    }

    private var dropHighlight: Bool { isTargetForDropOperation }

    override func drawSelection(in dirtyRect: NSRect) {
        if outlineHasFocus {
            ExplorerStyle.activeSelection.setFill()
            bounds.fill()
            ExplorerStyle.focusOutline.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        } else {
            ExplorerStyle.inactiveSelection.setFill()
            bounds.fill()
        }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Row content: indent guides, twistie, file icon, name, git badge / dirty dot.
final class ExplorerCellView: NSTableCellView {
    var level = 0
    var isDirectory = false
    var isExpanded = false
    var iconName: String?
    var iconColor: NSColor = ExplorerStyle.foreground
    var gitStatus: ExplorerGitStatus?
    var isDirtyFile = false
    let nameField = NSTextField(labelWithString: "")
    private let twistie = NSImageView()
    private let icon = NSImageView()
    private let badge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // vscode: 13px workbench font.
        nameField.font = .systemFont(ofSize: 13)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.cell?.usesSingleLineMode = true
        badge.font = .systemFont(ofSize: 12)
        badge.alignment = .right
        twistie.imageScaling = .scaleProportionallyDown
        icon.imageScaling = .scaleProportionallyDown
        for view in [twistie, icon, nameField, badge] {
            addSubview(view)
        }
        textField = nameField
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var indentX: CGFloat { ExplorerStyle.leadingInset + CGFloat(level) * ExplorerStyle.indent }

    func applyStyle() {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        if isDirectory {
            twistie.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            twistie.contentTintColor = ExplorerStyle.foreground
            twistie.isHidden = false
        } else {
            twistie.isHidden = true
        }
        if let iconName {
            icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            icon.contentTintColor = iconColor
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }
        let decorated = gitStatus.map { ExplorerStyle.color($0.colorHex) }
        nameField.textColor = decorated ?? ExplorerStyle.foreground
        if let status = gitStatus, let letter = status.badge {
            badge.stringValue = letter
            badge.textColor = ExplorerStyle.color(status.colorHex)
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x = indentX
        twistie.frame = NSRect(x: x, y: (h - 16) / 2, width: ExplorerStyle.twistieWidth, height: 16)
        x += ExplorerStyle.twistieWidth + 2
        if !icon.isHidden {
            icon.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
            x += 16 + 6
        }
        let trailing: CGFloat = 20
        badge.frame = NSRect(x: bounds.width - trailing - 8, y: (h - 16) / 2, width: trailing, height: 16)
        let nameHeight: CGFloat = 17
        nameField.frame = NSRect(x: x, y: (h - nameHeight) / 2, width: max(10, bounds.width - x - trailing - 10), height: nameHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // vscode: tree.css indent guides, tree.indentGuidesStroke #585858.
        if level > 0 {
            ExplorerStyle.indentGuide.withAlphaComponent(0.6).setFill()
            for depth in 0..<level {
                let x = ExplorerStyle.leadingInset + CGFloat(depth) * ExplorerStyle.indent + ExplorerStyle.twistieWidth / 2 - 1
                NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
            }
        }
        // Folder with changed descendants: VS Code shows a dot at the trailing edge.
        if gitStatus == .containsChanges || (isDirtyFile && gitStatus == nil) {
            let color = gitStatus == .containsChanges ? ExplorerStyle.color(ExplorerGitStatus.containsChanges.colorHex, alpha: 0.6) : NSColor.white
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 18, y: bounds.midY - 3, width: 6, height: 6)).fill()
        }
    }

    func beginEditing(selecting range: NSRange) {
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.drawsBackground = true
        nameField.backgroundColor = ExplorerStyle.color(0x313131)
        nameField.isBordered = true
        window?.makeFirstResponder(nameField)
        (nameField.currentEditor() as? NSTextView)?.selectedRange = range
    }

    func endEditing() {
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.drawsBackground = false
        nameField.isBordered = false
    }
}
