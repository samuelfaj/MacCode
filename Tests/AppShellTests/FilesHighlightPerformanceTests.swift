import XCTest
@testable import AppShell

final class FilesHighlightPerformanceTests: XCTestCase {

    /// WHY: full-document highlighting is still used when a file first opens,
    /// when the palette changes, and when an edit replaces the whole document.
    /// A regression here stalls the editor before incremental highlighting can
    /// help, so CI needs a repeatable large-document guard.
    func test_performance_fullDocumentHighlight_largeSwiftFile() {
        let line = "let value = try await client.request(path: \"/api/items\", method: .post) // comment\n"
        let text = String(repeating: line, count: 5_000)
        let palette = EditorColorPalette.resolve(isDark: true)

        XCTAssertGreaterThan(text.utf8.count, 400_000,
                             "fixture must be large enough to exercise full-document highlight cost")

        measure {
            _ = highlightedCodeAttributedString(text, palette: palette)
        }
    }
}

@MainActor
final class FilesIncrementalHighlightTests: XCTestCase {
    private let palette = EditorColorPalette.resolve(isDark: true)

    private func color(_ s: NSAttributedString, _ needle: String, in source: String, nth: Int = 0) -> NSColor? {
        var range = NSRange(location: 0, length: 0)
        let ns = source as NSString
        for _ in 0...nth {
            range = ns.range(of: needle, options: [], range: NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range)))
        }
        return s.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    func test_vscodeTokenColors() {
        let source = "func greet() { let n = 42 // hi\n  return Foo.bar(\"s\")\n}"
        let a = highlightedCodeAttributedString(source, palette: palette, language: "swift")
        XCTAssertEqual(color(a, "func", in: source), editorHex(0x569CD6), "keyword")
        XCTAssertEqual(color(a, "return", in: source), editorHex(0xC586C0), "control keyword")
        XCTAssertEqual(color(a, "greet", in: source), editorHex(0xDCDCAA), "function call/declaration")
        XCTAssertEqual(color(a, "42", in: source), editorHex(0xB5CEA8), "number")
        XCTAssertEqual(color(a, "// hi", in: source), editorHex(0x6A9955), "comment")
        XCTAssertEqual(color(a, "Foo", in: source), editorHex(0x4EC9B0), "type")
        XCTAssertEqual(color(a, "\"s\"", in: source), editorHex(0xCE9178), "string")
        XCTAssertEqual(color(a, "bar", in: source), editorHex(0xDCDCAA), "method call")
    }

    func test_blockCommentSpansLinesAndMarkdownHeading() {
        let source = "a /* one\ntwo */ b"
        let a = highlightedCodeAttributedString(source, palette: palette, language: "javascript")
        XCTAssertEqual(color(a, "two", in: source), editorHex(0x6A9955), "second line of a block comment is a comment")
        XCTAssertNotEqual(color(a, "b", in: source), editorHex(0x6A9955), "text after */ is code again")
        let md = "# Title\nplain"
        let m = highlightedCodeAttributedString(md, palette: palette, language: "markdown")
        XCTAssertEqual(color(m, "Title", in: md), editorHex(0x569CD6), "markdown heading")
        let font = m.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true, "markdown heading is bold")
    }

    func test_bracketPairsRotateColorsByDepth() {
        let source = "f(g[h{x}])"
        let a = highlightedCodeAttributedString(source, palette: palette, language: "javascript")
        XCTAssertEqual(color(a, "(", in: source), editorHex(0xFFD700))
        XCTAssertEqual(color(a, "[", in: source), editorHex(0xDA70D6))
        XCTAssertEqual(color(a, "{", in: source), editorHex(0x179FFF))
        XCTAssertEqual(color(a, ")", in: source), editorHex(0xFFD700), "closer takes its opener's color")
    }

    /// WHY: typing must not rescan the document; a 50k-line file would stall every keystroke.
    func test_typingInLargeDocumentRehighlightsOnlyTheEditedLine() throws {
        let text = String(repeating: "let value = compute(1, 2) // note\n", count: 50_000)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let textView = CodeEditorTextView()
        textView.configureForEditing()
        window.contentView = textView
        textView.string = text
        let coordinator = CodeTextEditor.Coordinator(onChange: { _ in }, onCaretChange: { _, _ in })
        coordinator.language = "swift"
        coordinator.textView = textView
        textView.delegate = coordinator

        var elapsed = 0.0
        let start = Date()
        coordinator.applyHighlight(to: textView)
        elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 30, "full highlight of 50k lines must finish in a sane budget (took \(elapsed)s)")

        let mid = (text as NSString).range(of: "value", options: [], range: NSRange(location: 600_000, length: 100)).location
        textView.setSelectedRange(NSRange(location: mid, length: 0))
        SyntaxHighlighter.scannedLengthForTests = 0
        textView.insertText("x", replacementRange: textView.selectedRange())
        XCTAssertGreaterThan(SyntaxHighlighter.scannedLengthForTests, 0, "the edited line must be re-highlighted")
        XCTAssertLessThanOrEqual(SyntaxHighlighter.scannedLengthForTests, 200,
                                 "a keystroke may only re-scan its own paragraph, not the document")
        XCTAssertNotNil(textView.textLayoutManager)
    }

    func test_highlightingKeepsSelectionAndUndoStack() {
        let textView = CodeEditorTextView()
        textView.configureForEditing()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = textView
        textView.string = "let a = 1\nlet b = 2"
        let coordinator = CodeTextEditor.Coordinator(onChange: { _ in }, onCaretChange: { _, _ in })
        coordinator.language = "swift"
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        textView.undoManager?.removeAllActions()
        coordinator.applyHighlight(to: textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 3), "selection must survive highlighting")
        XCTAssertFalse(textView.undoManager?.canUndo ?? true, "attribute-only highlighting must not register undo")
    }
}
