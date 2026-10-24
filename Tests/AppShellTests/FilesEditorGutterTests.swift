import AppKit
import XCTest
@testable import AppShell

/// The gutter must put each number on the same line as its text (the old TextKit 1 ruler drew
/// 1–4 below the text) and the editor must stay on TextKit 2.
@MainActor
final class FilesEditorGutterTests: XCTestCase {
    private func makeEditor(_ text: String) -> (NSWindow, NSScrollView, CodeEditorTextView, CodeLineNumberRulerView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let textView = CodeEditorTextView()
        textView.configureForEditing()
        textView.applyEditorStyle(EditorColorPalette.resolve(isDark: true))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        let ruler = CodeLineNumberRulerView(textView: textView)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = ruler
        window.contentView?.addSubview(scroll)
        textView.string = text
        window.layoutIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        return (window, scroll, textView, ruler)
    }

    /// Top of the n-th (0-based) logical line's text, measured down from the ruler's top edge.
    private func expectedTop(of line: Int, in textView: CodeEditorTextView, ruler: NSRulerView) -> CGFloat {
        let ns = textView.string as NSString
        var start = 0
        for _ in 0..<line { start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0))) }
        let rect = start < ns.length
            ? textView.textKit2SegmentRects(for: NSRange(location: start, length: 1))[0]
            : textView.textKit2InsertionRect(at: start)
        let inRuler = ruler.convert(rect, from: textView)
        return ruler.isFlipped ? inRuler.minY : ruler.bounds.height - inRuler.maxY
    }

    private func assertAligned(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let (window, _, textView, ruler) = makeEditor(text)
        _ = window
        let layout = ruler.lineNumberLayout()
        let lineCount = text.components(separatedBy: "\n").count
        XCTAssertEqual(layout.map(\.line), Array(1...lineCount), "one number per logical line", file: file, line: line)
        for entry in layout {
            XCTAssertEqual(entry.y, expectedTop(of: entry.line - 1, in: textView, ruler: ruler), accuracy: 1,
                           "number \(entry.line) must sit on its own line's text", file: file, line: line)
        }
        XCTAssertEqual(layout.map(\.y), layout.map(\.y).sorted(), "numbers must increase downwards", file: file, line: line)
        XCTAssertEqual(Set(layout.map(\.y)).count, layout.count, "numbers must be strictly increasing", file: file, line: line)
        if let first = layout.first {
            XCTAssertLessThan(first.y, EditorMetrics.lineHeight * 2,
                              "line 1 must start at the top, not below the text", file: file, line: line)
        }
    }

    func test_fourLinesAlignWithTheirText() {
        assertAligned("one\ntwo\nthree\nfour")
    }

    func test_leadingBlankLinesAlignWithTheirText() {
        assertAligned("\n\n\nlet x = 1\nlet y = 2")
    }

    func test_trailingNewlineGetsItsOwnNumber() {
        assertAligned("a\nb\n")
    }

    func test_emptyDocumentShowsLineOne() {
        let (_, _, _, ruler) = makeEditor("")
        XCTAssertEqual(ruler.lineNumberLayout().map(\.line), [1])
    }

    func test_wrappedLinesGetOneNumber() {
        let long = String(repeating: "word ", count: 200)
        let (window, scroll, textView, ruler) = makeEditor(long + "\nsecond")
        _ = window
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(ruler.lineNumberLayout().map(\.line), [1, 2],
                       "a wrapped paragraph is one logical line, so continuation rows get no number")
    }

    func test_gutterWidthFollowsMinCharsAndDigits() {
        let narrow = CodeLineNumberRulerView.thickness(forLineCount: 4)
        let wide = CodeLineNumberRulerView.thickness(forLineCount: 1_000_000)
        let digit = ("0" as NSString).size(withAttributes: [.font: EditorMetrics.font]).width
        XCTAssertEqual(narrow, ceil(5 * digit) + 10, accuracy: 1, "min 5 chars + 10pt decorations column")
        XCTAssertGreaterThan(wide, narrow, "seven digits need more room than the five-char minimum")
    }

    func test_editorStaysOnTextKit2ThroughLoadTypingHighlightAndCaret() {
        let (_, _, textView, ruler) = makeEditor("let a = 1\nlet b = 2")
        XCTAssertNotNil(textView.textLayoutManager, "created editor must use TextKit 2")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertText("x", replacementRange: textView.selectedRange())
        textView.textStorage?.setAttributedString(highlightedCodeAttributedString(textView.string, palette: .resolve(isDark: true)))
        textView.applyDiagnostics([LSPDiagnostic(
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3)),
            severity: 2, message: "w", source: nil)])
        _ = textView.caretRect()
        _ = ruler.lineNumberLayout()
        XCTAssertNotNil(textView.textLayoutManager, "no editor operation may downgrade to TextKit 1")
    }
}
