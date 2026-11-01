import AppKit

// MARK: - Model

struct SuggestEntry: Equatable {
    var label: String
    var insertText: String
    var kind: SuggestKind
    var detail: String?
    var documentation: String?
    var sortText: String?
    var filterText: String?
    /// UTF-16 range in the document to replace; nil replaces the current word.
    var replaceRange: NSRange?
    var source: Source

    enum Source: Equatable { case languageServer, word }
}

/// Cases follow LSP `CompletionItemKind` order (1...25).
enum SuggestKind: Int, CaseIterable {
    case text, method, function, constructor, field, variable, `class`, interface, module, property,
         unit, value, `enum`, keyword, snippet, color, file, reference, folder, enumMember, constant,
         `struct`, event, `operator`, typeParameter

    init(lspKind: Int?) {
        guard let k = lspKind, (1...25).contains(k) else { self = .text; return }
        self = SuggestKind.allCases[k - 1]
    }

    init(_ kind: FileCompletionItem.Kind) {
        switch kind {
        case .variable: self = .variable
        case .function: self = .function
        case .property: self = .property
        case .type: self = .class
        case .keyword: self = .keyword
        case .snippet: self = .snippet
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "textformat"
        case .method: return "cube"
        case .function: return "function"
        case .constructor: return "hammer"
        case .field: return "wrench.adjustable"
        case .variable: return "cube.transparent"
        case .class: return "square.stack.3d.up"
        case .interface: return "square.on.square"
        case .module: return "shippingbox"
        case .property: return "wrench"
        case .unit: return "ruler"
        case .value: return "number"
        case .enum: return "list.number"
        case .keyword: return "key"
        case .snippet: return "text.badge.plus"
        case .color: return "paintpalette"
        case .file: return "doc"
        case .reference: return "arrow.turn.up.right"
        case .folder: return "folder"
        case .enumMember: return "list.bullet"
        case .constant: return "pi"
        case .struct: return "square.stack"
        case .event: return "bolt"
        case .operator: return "plusminus"
        case .typeParameter: return "textformat.abc"
        }
    }

    var tintHex: UInt32 {
        switch self {
        case .method, .function, .constructor: return 0xB180D7
        case .field, .variable, .property, .enumMember: return 0x75BEFF
        case .class, .struct, .interface, .enum, .typeParameter: return 0xEE9D28
        default: return 0xCCCCCC
        }
    }
}

struct FuzzyMatch: Equatable {
    var score: Int
    /// Matched character indices (Character offsets) in the word.
    var matches: [Int]
}

enum SuggestFuzzy {
    /// Greedy left-to-right subsequence match, case-insensitive.
    static func score(pattern: String, word: String) -> FuzzyMatch? {
        if pattern.isEmpty { return FuzzyMatch(score: 0, matches: []) }
        let w = Array(word)
        var score = 0
        var matches: [Int] = []
        var cursor = 0
        for pc in pattern {
            let lower = String(pc).lowercased()
            guard let idx = (cursor..<w.count).first(where: { String(w[$0]).lowercased() == lower }) else {
                return nil
            }
            if idx == 0 { score += 8 }
            if let last = matches.last, last == idx - 1 { score += 5 }
            if idx > 0 {
                let prev = w[idx - 1]
                if "_-. ".contains(prev) || (prev.isLowercase && w[idx].isUppercase) { score += 3 }
            }
            if w[idx] == pc { score += 1 }
            matches.append(idx)
            cursor = idx + 1
        }
        return FuzzyMatch(score: score, matches: matches)
    }
}

struct SuggestModel {
    private(set) var items: [SuggestEntry] = []
    /// Highlight indices in `label`, parallel to `items`.
    private(set) var matches: [FuzzyMatch] = []
    private(set) var selectedIndex: Int = 0

    private var entries: [SuggestEntry]
    private var prefix: String

    private static let maxItems = 200

    init(entries: [SuggestEntry], prefix: String) {
        self.entries = entries
        self.prefix = prefix
        refilter(keepingLabel: nil)
    }

    var selected: SuggestEntry? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }
    var isEmpty: Bool { items.isEmpty }

    mutating func update(prefix: String) {
        let kept = selected?.label
        self.prefix = prefix
        refilter(keepingLabel: kept)
    }

    mutating func selectNext() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }

    mutating func selectPrevious() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    mutating func pageDown(_ n: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(items.count - 1, selectedIndex + max(0, n))
    }

    mutating func pageUp(_ n: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - max(0, n))
    }

    mutating func select(index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
    }

    private mutating func refilter(keepingLabel label: String?) {
        var scored: [(entry: SuggestEntry, score: Int)] = []
        for entry in entries {
            guard let m = SuggestFuzzy.score(pattern: prefix, word: entry.filterText ?? entry.label) else { continue }
            scored.append((entry, m.score))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.entry.source != b.entry.source { return a.entry.source == .languageServer }
            let sa = a.entry.sortText ?? a.entry.label
            let sb = b.entry.sortText ?? b.entry.label
            if sa != sb { return sa < sb }
            return a.entry.label.count < b.entry.label.count
        }

        var seen = Set<String>()
        var outItems: [SuggestEntry] = []
        var outMatches: [FuzzyMatch] = []
        for s in scored {
            guard outItems.count < Self.maxItems else { break }
            guard seen.insert(s.entry.insertText).inserted else { continue }
            outItems.append(s.entry)
            let labelMatches = SuggestFuzzy.score(pattern: prefix, word: s.entry.label)?.matches ?? []
            outMatches.append(FuzzyMatch(score: s.score, matches: labelMatches))
        }

        items = outItems
        matches = outMatches
        if let label, let idx = items.firstIndex(where: { $0.label == label }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
    }
}

// MARK: - Controller

@MainActor
final class SuggestWidgetController: NSObject {
    var onAccept: ((SuggestEntry) -> Void)?
    /// Called when Escape hides the widget.
    var onDismiss: (() -> Void)?
    private(set) var isVisible = false
    private(set) var model: SuggestModel?

    private enum Key {
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let pageDown: UInt16 = 121
        static let pageUp: UInt16 = 116
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
    }

    private static let rowHeight: CGFloat = 22
    private static let maxRows = 12
    private static let listWidth: CGFloat = 430
    private static let detailsWidth: CGFloat = 300

    private let panel: NSPanel
    private let background = NSView()
    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private let detailsView = NSView()
    private let detailText = NSTextField(wrappingLabelWithString: "")
    private var detailsShown = false
    private weak var textView: NSTextView?
    private var anchor: NSRect = .zero

    override init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = background

        background.wantsLayer = true
        background.layer?.backgroundColor = suggestColor(0x202020).cgColor
        background.layer?.borderColor = suggestColor(0x454545).cgColor
        background.layer?.borderWidth = 1
        background.layer?.cornerRadius = 3
        background.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggest"))
        column.width = Self.listWidth
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        detailText.font = .systemFont(ofSize: 12)
        detailText.textColor = suggestColor(0xCCCCCC)
        detailText.isSelectable = false
        detailsView.addSubview(detailText)

        background.addSubview(scrollView)
        background.addSubview(detailsView)
        detailsView.isHidden = true
    }

    func show(entries: [SuggestEntry], prefix: String, anchor: NSRect, in textView: NSTextView) {
        let m = SuggestModel(entries: entries, prefix: prefix)
        guard !m.isEmpty, let window = textView.window else {
            hide()
            return
        }
        self.textView = textView
        self.anchor = anchor
        model = m
        isVisible = true
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        table.reloadData()
        syncSelection()
        relayout()
        panel.orderFront(nil)
    }

    func update(prefix: String) {
        guard var m = model else { return }
        m.update(prefix: prefix)
        if m.isEmpty {
            hide()
            return
        }
        model = m
        table.reloadData()
        syncSelection()
        relayout()
    }

    func hide() {
        isVisible = false
        model = nil
        textView = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        handle(keyCode: event.keyCode)
    }

    func handle(keyCode: UInt16) -> Bool {
        guard isVisible, model != nil else { return false }
        switch keyCode {
        case Key.down:
            mutateModel { $0.selectNext() }
        case Key.up:
            mutateModel { $0.selectPrevious() }
        case Key.pageDown:
            mutateModel { $0.pageDown(Self.maxRows) }
        case Key.pageUp:
            mutateModel { $0.pageUp(Self.maxRows) }
        case Key.returnKey, Key.tab:
            acceptSelected()
        case Key.escape:
            hide()
            onDismiss?()
        default:
            return false
        }
        return true
    }

    func toggleDetails() {
        detailsShown.toggle()
        guard isVisible else { return }
        relayout()
        updateDetails()
    }

    // MARK: Private

    private func mutateModel(_ body: (inout SuggestModel) -> Void) {
        guard var m = model else { return }
        body(&m)
        model = m
        syncSelection()
    }

    private func acceptSelected() {
        guard let entry = model?.selected else {
            hide()
            return
        }
        hide()
        onAccept?(entry)
    }

    @objc private func rowClicked() {}

    @objc private func rowDoubleClicked() {
        acceptSelected()
    }

    private func syncSelection() {
        guard let idx = model?.selectedIndex, idx < table.numberOfRows else { return }
        if table.selectedRow != idx {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        table.scrollRowToVisible(idx)
        updateDetails()
    }

    private func updateDetails() {
        guard let entry = model?.selected else {
            detailText.attributedStringValue = NSAttributedString()
            return
        }
        let text = NSMutableAttributedString()
        if let detail = entry.detail, !detail.isEmpty {
            text.append(NSAttributedString(string: detail, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: suggestColor(0xCCCCCC),
            ]))
        }
        if let doc = entry.documentation, !doc.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(NSAttributedString(string: doc, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: suggestColor(0xCCCCCC),
            ]))
        }
        detailText.attributedStringValue = text
    }

    private func relayout() {
        guard let textView, let window = textView.window, let m = model, !m.isEmpty else { return }
        let rows = min(m.items.count, Self.maxRows)
        let height = CGFloat(rows) * Self.rowHeight
        let width = Self.listWidth + (detailsShown ? Self.detailsWidth : 0)

        let caret = window.convertToScreen(textView.convert(anchor, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? caret
        var origin = NSPoint(x: caret.minX, y: caret.minY - height)
        if origin.y < screen.minY { origin.y = caret.maxY }
        if origin.x + width > screen.maxX { origin.x = max(screen.minX, screen.maxX - width) }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)

        background.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.listWidth, height: height)
        detailsView.isHidden = !detailsShown
        detailsView.frame = NSRect(x: Self.listWidth, y: 0, width: Self.detailsWidth, height: height)
        detailText.frame = detailsView.bounds.insetBy(dx: 8, dy: 8)
    }
}

extension SuggestWidgetController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model?.items.count ?? 0
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SuggestRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let m = model, m.items.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: SuggestCellView.identifier, owner: nil) as? SuggestCellView
            ?? SuggestCellView()
        cell.configure(entry: m.items[row], matches: m.matches[row].matches)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, model != nil, model?.selectedIndex != row else { return }
        model?.select(index: row)
        updateDetails()
    }
}

// MARK: - Cells

private final class SuggestRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        suggestColor(0x04395E).setFill()
        bounds.fill()
    }
}

private final class SuggestCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SuggestCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        for view in [icon, title, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        icon.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.usesSingleLineMode = true
        title.setContentHuggingPriority(.required, for: .horizontal)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = suggestColor(0x9D9D9D)
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.cell?.usesSingleLineMode = true
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(entry: SuggestEntry, matches: [Int]) {
        icon.image = NSImage(systemSymbolName: entry.kind.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        icon.contentTintColor = suggestColor(entry.kind.tintHex)
        title.attributedStringValue = suggestHighlighted(entry.label, matches: matches)
        detail.stringValue = entry.detail ?? ""
    }
}

private func suggestColor(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

private func suggestHighlighted(_ label: String, matches: [Int]) -> NSAttributedString {
    let text = NSMutableAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: suggestColor(0xCCCCCC),
    ])
    for i in matches where i >= 0 && i < label.count {
        let start = label.index(label.startIndex, offsetBy: i)
        let end = label.index(after: start)
        text.addAttributes([
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: suggestColor(0x2AAAFF),
        ], range: NSRange(start..<end, in: label))
    }
    return text
}

// MARK: - Ghost text

enum GhostTextLayout {
    /// First line continues after the caret; following lines render below it.
    static func split(_ text: String) -> (inline: String, lines: [String]) {
        var parts = text.components(separatedBy: "\n")
        let first = parts.removeFirst()
        return (first, parts)
    }

    /// Leading whitespace + identifier run, or a single punctuation run.
    /// Text starting with a newline yields up to and including that newline.
    static func nextWordChunk(_ text: String) -> String {
        var out = ""
        var idx = text.startIndex
        func advance() {
            out.append(text[idx])
            idx = text.index(after: idx)
        }
        while idx < text.endIndex, text[idx].isWhitespace, !isNewline(text[idx]) { advance() }
        guard idx < text.endIndex else { return out }
        if isNewline(text[idx]) {
            advance()
            return out
        }
        if isWordChar(text[idx]) {
            while idx < text.endIndex, isWordChar(text[idx]) { advance() }
        } else {
            while idx < text.endIndex, !text[idx].isWhitespace, !isWordChar(text[idx]) { advance() }
        }
        return out
    }

    private static func isNewline(_ c: Character) -> Bool {
        c == "\n" || c == "\r\n"
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
