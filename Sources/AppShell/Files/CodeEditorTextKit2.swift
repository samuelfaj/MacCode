import AppKit

/// Editor geometry shared by the text view, the gutter and the tests.
enum EditorMetrics {
    /// vscode: src/vs/editor/common/config/fontInfo.ts GOLDEN_LINE_HEIGHT_RATIO (1.5 × 12pt on macOS).
    static let lineHeight: CGFloat = 18
    static let fontSize: CGFloat = 12
    /// Space between the gutter and the first glyph.
    static let leftPadding: CGFloat = 4
    static let tabWidth = 4
    /// vscode: src/vs/editor/common/config/editorOptions.ts lineNumbersMinChars.
    static let lineNumbersMinChars = 5
    /// vscode: src/vs/editor/common/config/editorOptions.ts lineDecorationsWidth.
    static let lineDecorationsWidth: CGFloat = 10

    static var font: NSFont {
        NSFont(name: "Menlo", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }
}

/// TextKit 2 geometry helpers. Nothing here touches `layoutManager`, which would silently
/// downgrade the view to TextKit 1.
extension NSTextView {
    /// `NSTextRange` for a UTF-16 range of the backing storage.
    func textKit2Range(_ range: NSRange) -> NSTextRange? {
        guard let manager = textLayoutManager?.textContentManager else { return nil }
        let doc = manager.documentRange
        guard let start = manager.location(doc.location, offsetBy: range.location),
              let end = manager.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// UTF-16 offset of a text location from the start of the document.
    func textKit2Offset(of location: NSTextLocation) -> Int? {
        guard let manager = textLayoutManager?.textContentManager else { return nil }
        return manager.offset(from: manager.documentRange.location, to: location)
    }

    /// Frames (text-view coordinates) covering `range`, one per line segment.
    func textKit2SegmentRects(for range: NSRange) -> [NSRect] {
        guard let layout = textLayoutManager, let textRange = textKit2Range(range) else { return [] }
        layout.ensureLayout(for: textRange)
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return rects
    }

    /// Caret rectangle for a UTF-16 insertion index, in text-view coordinates.
    func textKit2InsertionRect(at index: Int) -> NSRect {
        let length = (string as NSString).length
        let caret = max(0, min(index, length))
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let fallback = NSRect(x: origin.x + padding, y: origin.y, width: 1, height: EditorMetrics.lineHeight)
        if caret < length, let rect = textKit2SegmentRects(for: NSRange(location: caret, length: 1)).first {
            return NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
        }
        guard length > 0 else { return fallback }
        guard let last = textKit2SegmentRects(for: NSRange(location: length - 1, length: 1)).last else { return fallback }
        let lastChar = (string as NSString).character(at: length - 1)
        if lastChar == 0x0A || lastChar == 0x0D {
            return NSRect(x: origin.x + padding, y: last.maxY, width: 1, height: last.height)
        }
        return NSRect(x: last.maxX, y: last.minY, width: 1, height: last.height)
    }
}
