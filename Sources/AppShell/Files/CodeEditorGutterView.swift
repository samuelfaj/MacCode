import AppKit

/// Line-number gutter for `CodeEditorTextView`. Numbers come from the TextKit 2 layout fragments
/// in the viewport, so they stay aligned with the text however tall a line is.
final class CodeLineNumberRulerView: NSRulerView {
    struct Item {
        let line: Int
        /// Top of the first line box, in ruler coordinates.
        let lineRect: NSRect
        /// Baseline of the first line, in ruler coordinates.
        let baseline: CGFloat
    }

    private weak var textView: NSTextView?
    private var lastSignature = ""
    /// Mutable so `updateNSView` can push a new palette when appearance changes.
    var currentPalette: EditorColorPalette = EditorColorPalette.resolve(isDark: true) {
        didSet { needsDisplay = true }
    }
    private var cachedLineStartOffsets: [Int] = [0]
    private var cachedOffsetText: String?

    private var numberFont: NSFont { EditorMetrics.font }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        invalidateLineStartCache()
        let center = NotificationCenter.default
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
        center.addObserver(self, selector: #selector(viewportChanged), name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Rebuilds the line-start index and the gutter width after the text changed.
    func invalidateLineStartCache() {
        let text = textView?.string ?? ""
        if text != cachedOffsetText {
            cachedLineStartOffsets = buildLineStartOffsets(text: text)
            cachedOffsetText = text
        }
        let thickness = Self.thickness(forLineCount: cachedLineStartOffsets.count)
        if abs(ruleThickness - thickness) > 0.5 { ruleThickness = thickness }
    }

    /// vscode: editorOptions.ts — `max(lineNumbersMinChars, digits)` digit widths plus the decorations column.
    static func thickness(forLineCount count: Int) -> CGFloat {
        let digits = max(EditorMetrics.lineNumbersMinChars, String(max(count, 1)).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: EditorMetrics.font]).width
        return ceil(CGFloat(digits) * digitWidth) + EditorMetrics.lineDecorationsWidth
    }

    @objc private func viewportChanged() {
        needsDisplay = true
    }

    /// 1-based numbers with their top edge measured down from the ruler's top, for tests.
    func lineNumberLayout() -> [(line: Int, y: CGFloat)] {
        items().map { item in
            (item.line, isFlipped ? item.lineRect.minY : bounds.height - item.lineRect.maxY)
        }
    }

    /// Numbers for the paragraphs that start in the viewport.
    func items() -> [Item] {
        guard let textView, let layout = textView.textLayoutManager,
              let content = layout.textContentManager,
              let clip = textView.enclosingScrollView?.contentView else { return [] }
        invalidateLineStartCache()
        let origin = textView.textContainerOrigin
        let visible = clip.bounds
        let docStart = content.documentRange.location
        let startPoint = CGPoint(x: 0, y: max(0, visible.minY - origin.y))
        let startLocation = layout.textLayoutFragment(for: startPoint)?.rangeInElement.location ?? docStart
        var result: [Item] = []
        var lastFragmentMaxY: CGFloat?

        func append(line: Int, topInTextView: CGFloat, height: CGFloat, baselineInTextView: CGFloat) {
            let rect = NSRect(x: 0, y: topInTextView, width: textView.bounds.width, height: height)
            let converted = convert(rect, from: textView)
            let baseline = convert(NSPoint(x: 0, y: baselineInTextView), from: textView).y
            result.append(Item(line: line, lineRect: converted, baseline: baseline))
        }

        layout.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let top = frame.minY + origin.y
            if top > visible.maxY { return false }
            lastFragmentMaxY = frame.maxY + origin.y
            guard let first = fragment.textLineFragments.first else { return true }
            guard let offset = content.offset(from: docStart, to: fragment.rangeInElement.location) as Int? else { return true }
            let line = lineIndex(forCharOffset: offset, in: cachedLineStartOffsets) + 1
            let lineTop = top + first.typographicBounds.minY
            let baseline = lineTop + first.glyphOrigin.y
            append(line: line, topInTextView: lineTop, height: first.typographicBounds.height, baselineInTextView: baseline)
            return true
        }

        // A trailing empty line (text ends in a newline) or an empty document has no fragment.
        let total = cachedLineStartOffsets.count
        if let last = result.last, last.line == total - 1, let end = lastFragmentMaxY,
           end <= visible.maxY + EditorMetrics.lineHeight {
            append(line: total, topInTextView: end, height: last.lineRect.height,
                   baselineInTextView: end + (last.baseline - last.lineRect.minY))
        } else if result.isEmpty, total == 1 {
            let font = numberFont
            let top = origin.y
            let baseline = top + (EditorMetrics.lineHeight - (font.ascender - font.descender)) / 2 + font.ascender
            append(line: 1, topInTextView: top, height: EditorMetrics.lineHeight, baselineInTextView: baseline)
        }
        return result
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let context = NSGraphicsContext.current?.cgContext else { return }
        currentPalette.lineNumberBackground.setFill()
        bounds.fill()
        let caretLine = lineIndex(forCharOffset: textView.selectedRange().location, in: cachedLineStartOffsets) + 1
        for item in items() {
            let color = item.line == caretLine ? currentPalette.lineNumberActiveText : currentPalette.lineNumberText
            let attributed = NSAttributedString(string: "\(item.line)", attributes: [.font: numberFont, .foregroundColor: color])
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            // Right-aligned, leaving the decorations column on the right.
            let x = ruleThickness - EditorMetrics.lineDecorationsWidth - CGFloat(width)
            context.saveGState()
            context.textMatrix = isFlipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
            context.textPosition = CGPoint(x: x, y: item.baseline)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}
