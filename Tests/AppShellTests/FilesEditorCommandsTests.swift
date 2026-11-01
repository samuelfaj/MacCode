import AppKit
import XCTest
@testable import AppShell

@MainActor
final class FilesEditorCommandsTests: XCTestCase {
    private func makeEditor(_ text: String, language: String? = "swift") -> CodeEditorTextView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let view = CodeEditorTextView()
        view.configureForEditing()
        view.applyEditorStyle(EditorColorPalette.resolve(isDark: true))
        view.allowsUndo = true
        window.contentView = view
        view.string = text
        view.language = language
        return view
    }

    private func type(_ s: String, in view: CodeEditorTextView) {
        view.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func test_toggleCommentAddsAtCommonIndentAndRemoves() {
        let view = makeEditor("a\n    b\n\n    c")
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        view.toggleLineComment()
        XCTAssertEqual(view.string, "// a\n//     b\n\n//     c", "comment goes at the smallest indent; blank lines are skipped")
        view.toggleLineComment()
        XCTAssertEqual(view.string, "a\n    b\n\n    c", "a second toggle restores the original text")
    }

    func test_toggleCommentUsesLanguageTokensAndUndoesInOneStep() {
        let py = makeEditor("x = 1\ny = 2", language: "python")
        py.setSelectedRange(NSRange(location: 0, length: 11))
        py.toggleLineComment()
        XCTAssertEqual(py.string, "# x = 1\n# y = 2")
        py.undoManager?.undo()
        XCTAssertEqual(py.string, "x = 1\ny = 2", "toggle over several lines is one undo step")
        let html = makeEditor("<p>hi</p>", language: "html")
        html.toggleLineComment()
        XCTAssertEqual(html.string, "<!-- <p>hi</p> -->")
        html.toggleLineComment()
        XCTAssertEqual(html.string, "<p>hi</p>")
    }

    func test_returnCopiesIndentAndAddsLevelAfterOpener() {
        let view = makeEditor("    if x {")
        view.setSelectedRange(NSRange(location: 10, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "    if x {\n        ", "indent + one level after '{'")
        let py = makeEditor("def f():", language: "python")
        py.setSelectedRange(NSRange(location: 8, length: 0))
        py.insertNewline(nil)
        XCTAssertEqual(py.string, "def f():\n    ", "':' opens a block in Python")
        let plain = makeEditor("  abc")
        plain.setSelectedRange(NSRange(location: 5, length: 0))
        plain.insertNewline(nil)
        XCTAssertEqual(plain.string, "  abc\n  ")
    }

    func test_returnBetweenBracesSplitsBlock() {
        let view = makeEditor("  f {}")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "  f {\n      \n  }")
        XCTAssertEqual(view.selectedRange().location, 12, "caret lands on the indented middle line")
    }

    func test_autoCloseSkipOverAndPairBackspace() {
        let view = makeEditor("")
        type("(", in: view)
        XCTAssertEqual(view.string, "()")
        type(")", in: view)
        XCTAssertEqual(view.string, "()", "typing the closer skips over it")
        XCTAssertEqual(view.selectedRange().location, 2)
        view.string = ""
        type("[", in: view)
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "", "backspace inside an empty pair removes both")
        view.string = "don"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        type("'", in: view)
        XCTAssertEqual(view.string, "don'", "an apostrophe after a word must not auto-close")
        view.string = "ab"
        view.setSelectedRange(NSRange(location: 0, length: 2))
        type("\"", in: view)
        XCTAssertEqual(view.string, "\"ab\"", "typing a quote over a selection surrounds it")
    }

    func test_tabInsertsSpacesToStopAndIndentsOutdentsSelectedLines() {
        let view = makeEditor("ab")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "ab  ", "tab pads to the next 4-column stop with spaces")
        view.string = "a\nb\nc"
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "    a\n    b\nc")
        view.setSelectedRange(NSRange(location: 0, length: 11))
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "a\nb\nc", "shift-tab removes one level")
    }

    func test_goToLineClampsAndMovesCaret() {
        let view = makeEditor("one\ntwo\nthree")
        view.goToLine(2)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
        view.goToLine(99)
        XCTAssertEqual(view.selectedRange().location, 8, "past the end clamps to the last line")
        view.goToLine(0)
        XCTAssertEqual(view.selectedRange().location, 0)
    }

    func test_typingBlockKeepsCaretAndUndoThroughHighlighting() {
        let view = makeEditor("")
        let coordinator = CodeTextEditor.Coordinator(onChange: { _ in }, onCaretChange: { _, _ in })
        coordinator.textView = view
        coordinator.language = "swift"
        view.delegate = coordinator
        type("{", in: view)
        view.insertNewline(nil)
        type("value", in: view)
        XCTAssertEqual(view.string, "{\n    value\n}")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 11, length: 0))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "", "typing in the same event remains one undo group")
        view.undoManager?.redo()
        XCTAssertEqual(view.string, "{\n    value\n}")
        coordinator.tearDown()
    }
}

final class FilesLineEndingTests: XCTestCase {
    func test_detectsFirstLineBreak() {
        XCTAssertEqual(FilesViewModel.detectLineEnding("a\r\nb\n"), "CRLF")
        XCTAssertEqual(FilesViewModel.detectLineEnding("a\nb\r\n"), "LF")
        XCTAssertEqual(FilesViewModel.detectLineEnding("single line"), "LF")
    }

    @MainActor
    func test_returnInCRLFDocumentInsertsCRLF() {
        let view = CodeEditorTextView()
        view.configureForEditing()
        view.string = "a {\r\nb"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "a {\r\n    \r\nb", "new line in a CRLF file must use CRLF so saves keep one line-ending style")
    }

    @MainActor
    func test_blockReturnAndIndentPreserveCRLFAndCaret() {
        let view = CodeEditorTextView()
        view.configureForEditing()
        view.string = "{}\r\nnext"
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "{\r\n    \r\n}\r\nnext")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 7, length: 0), "caret stays before the second CRLF")

        view.string = "a\r\nb\r\nc"
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "    a\r\n    b\r\nc")
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "a\r\nb\r\nc")
    }
}
