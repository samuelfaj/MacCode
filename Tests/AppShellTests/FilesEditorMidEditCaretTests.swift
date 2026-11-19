import AppKit
import XCTest
@testable import AppShell

/// Same AppKit ordering as the Agent App composer crash of 2026-11-18 18:07 -03:
/// a keystroke's selection change arrives before textDidChange hands the new text
/// to `onChange`. Publishing the caret line/column at that moment lets SwiftUI
/// re-render synchronously while `draftText` still holds the old text, and
/// updateNSView then writes that old text over the document mid-edit, dropping
/// the keystroke. The caret may only be published once `onChange` has the edit.
@MainActor
final class FilesEditorMidEditCaretTests: XCTestCase {
    @MainActor
    private final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let view = CodeEditorTextView()
        var draft = "let a"
        var carets: [(line: Int, column: Int)] = []
        var staleCaretReports = 0
        /// Runs after each caret publish, like the SwiftUI update it can trigger.
        var caretHook: () -> Void = {}
        var coordinator: CodeTextEditor.Coordinator!

        init() {
            window.isReleasedWhenClosed = false
            view.configureForEditing()
            view.string = draft
            window.contentView = view
            window.makeFirstResponder(view)
            coordinator = CodeTextEditor.Coordinator(
                onChange: { [unowned self] in draft = $0 },
                onCaretChange: { [unowned self] line, column in
                    carets.append((line, column))
                    if draft != view.string { staleCaretReports += 1 }
                    caretHook()
                }
            )
            coordinator.textView = view
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: 5, length: 0))
            carets.removeAll()
        }

        func close() {
            coordinator.tearDown()
            window.close()
        }
    }

    func test_typingPublishesTheCaretOnlyAfterOnChangeHasTheKeystroke() {
        let harness = Harness()
        defer { harness.close() }

        harness.view.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(harness.draft, "let ab")
        XCTAssertEqual(harness.staleCaretReports, 0,
                       "a caret publish while draftText lags lets updateNSView write the old text back")
        XCTAssertEqual(harness.carets.last?.line, 1)
        XCTAssertEqual(harness.carets.last?.column, 7, "the status bar must still follow typing")
    }

    /// What a synchronous re-render does on a caret publish: updateNSView's sync
    /// step writes the binding back into the view.
    func test_synchronousRerenderOnCaretPublishKeepsTheKeystroke() {
        let harness = Harness()
        defer { harness.close() }
        harness.caretHook = {
            if harness.view.string != harness.draft {
                harness.view.replaceTextPreservingSelection(harness.draft)
            }
        }

        harness.view.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(harness.view.string, "let ab", "the typed character must survive a synchronous re-render")
        XCTAssertEqual(harness.draft, "let ab")
    }

    func test_newlinePublishesTheNewLineAfterOnChangeHasIt() {
        let harness = Harness()
        defer { harness.close() }

        harness.view.insertNewline(nil)

        XCTAssertEqual(harness.staleCaretReports, 0)
        XCTAssertEqual(harness.carets.last?.line, 2)
        XCTAssertEqual(harness.draft, harness.view.string)
    }

    func test_caretMoveWithoutEditStillPublishes() {
        let harness = Harness()
        defer { harness.close() }

        harness.view.setSelectedRange(NSRange(location: 1, length: 0))

        XCTAssertEqual(harness.carets.count, 1)
        XCTAssertEqual(harness.carets.last?.column, 2)
        XCTAssertEqual(harness.staleCaretReports, 0)
    }
}
