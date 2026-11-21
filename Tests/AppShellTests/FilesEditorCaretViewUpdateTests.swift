import AppKit
import OSLog
import SwiftUI
import XCTest
@testable import AppShell

/// Same class as the Agent App composer faults of 2026-11-20 (#110): opening the
/// Files editor, switching its tab, or reloading the file from disk swaps the
/// text from makeNSView/updateNSView. The swap moves the selection, and
/// `textViewDidChangeSelection` published the caret line/column (the Files
/// model's `@Published caretLine/caretColumn`) inside SwiftUI's update, which
/// SwiftUI reports as "Publishing changes from within view updates is not
/// allowed, this will cause undefined behavior." The status bar must still get
/// the new caret, but only after the update.
@MainActor
final class FilesEditorCaretViewUpdateTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var text: String
        @Published var filePath: String
        @Published var caretLine = 0
        @Published var caretColumn = 0
        /// Caret reports made from inside the representable's makeNSView/updateNSView.
        var reportsInsideViewUpdate = 0

        init(path: String, text: String) {
            filePath = path
            self.text = text
        }
    }

    private struct Host: View {
        @ObservedObject var model: Model

        var body: some View {
            CodeTextEditor(
                text: $model.text,
                language: nil,
                filePath: model.filePath,
                absolutePath: nil,
                rootPath: "",
                openPaths: ["a.txt", "b.txt"],
                inlineCompletionProvider: nil,
                automaticInlineSuggestions: false,
                onCaretChange: { line, column in
                    if Thread.callStackSymbols.contains(where: { $0.contains("updateNSView") || $0.contains("makeNSView") }) {
                        model.reportsInsideViewUpdate += 1
                    }
                    model.caretLine = line
                    model.caretColumn = column
                }
            ) { model.text = $0 }
            .frame(width: 600, height: 300)
        }
    }

    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func editor(in view: NSView) -> CodeEditorTextView? {
        if let editor = view as? CodeEditorTextView { return editor }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    private func host(_ model: Model) throws -> CodeEditorTextView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        self.window = window
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.orderFront(nil)
        spin()
        let editor = try XCTUnwrap(editor(in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(editor))
        return editor
    }

    /// SwiftUI's own runtime-issue fault. logd ingests it with a delay, so poll
    /// briefly before reporting none.
    private func publishDuringUpdateFaults(since start: Date) throws -> Int {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let deadline = Date().addingTimeInterval(1.5)
        while true {
            let count = try store.getEntries(at: store.position(date: start))
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.date >= start && $0.composedMessage.contains("Publishing changes from within view updates") }
                .count
            if count > 0 || Date() >= deadline { return count }
            spin(0.25)
        }
    }

    func test_openingTheEditorDoesNotPublishTheCaretDuringTheViewUpdate() throws {
        let model = Model(path: "a.txt", text: "one\ntwo")
        let start = Date()

        _ = try host(model)

        XCTAssertEqual(model.reportsInsideViewUpdate, 0)
        XCTAssertEqual(try publishDuringUpdateFaults(since: start), 0, "mounting must not publish the caret inside SwiftUI's update")
        XCTAssertEqual(model.caretLine, 1, "the status bar still shows the caret once the update is over")
        XCTAssertEqual(model.caretColumn, 1)
    }

    func test_switchingTabsPublishesTheNewCaretAfterTheViewUpdate() throws {
        let model = Model(path: "a.txt", text: "one\ntwo")
        let editor = try host(model)
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        spin()
        XCTAssertEqual(model.caretLine, 2)
        XCTAssertEqual(model.caretColumn, 4)
        model.reportsInsideViewUpdate = 0
        let start = Date()

        model.filePath = "b.txt"
        model.text = "other file"
        spin()

        XCTAssertEqual(editor.string, "other file")
        XCTAssertEqual(model.reportsInsideViewUpdate, 0)
        XCTAssertEqual(try publishDuringUpdateFaults(since: start), 0, "a tab switch must not publish the caret inside SwiftUI's update")
        XCTAssertEqual(model.caretLine, 1, "the status bar follows the new tab's caret")
        XCTAssertEqual(model.caretColumn, 1)
    }

    /// Latest wins: a keystroke that lands before the deferred publish runs
    /// already published its caret; the deferred one must not bring back the
    /// caret of the swapped-in text.
    func test_aKeystrokeBeforeTheDeferredPublishKeepsItsCaret() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = CodeEditorTextView()
        view.configureForEditing()
        window.contentView = view
        window.makeFirstResponder(view)
        var draft = "one"
        var carets: [String] = []
        let coordinator = CodeTextEditor.Coordinator(
            onChange: { draft = $0 },
            onCaretChange: { carets.append("\($0):\($1)") }
        )
        coordinator.textView = view
        view.delegate = coordinator
        defer {
            coordinator.tearDown()
            window.close()
        }

        coordinator.applyingExternalText = true
        view.switchDocument(to: "b.txt", text: "x\ny", openPaths: ["b.txt"])
        coordinator.applyingExternalText = false
        coordinator.publishCaretAfterUpdate(of: view)
        XCTAssertEqual(carets, [], "the swap itself must not publish inside the update")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.1)

        XCTAssertEqual(draft, "x\nyz")
        XCTAssertEqual(carets.last, "2:3", "the typed caret stays the published one")
        XCTAssertFalse(carets.contains("1:1"), "the swapped-in caret must not be published after the keystroke")
    }

    func test_reloadFromDiskPublishesTheMovedCaretAfterTheViewUpdate() throws {
        let model = Model(path: "a.txt", text: "one\ntwo")
        let editor = try host(model)
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        spin()
        model.reportsInsideViewUpdate = 0
        let start = Date()

        model.text = "zero\none\ntwo"
        spin()

        XCTAssertEqual(editor.string, "zero\none\ntwo")
        XCTAssertEqual(editor.selectedRange().location, 7, "a reload keeps the caret offset")
        XCTAssertEqual(model.reportsInsideViewUpdate, 0)
        XCTAssertEqual(try publishDuringUpdateFaults(since: start), 0, "a disk reload must not publish the caret inside SwiftUI's update")
        XCTAssertEqual(model.caretLine, 2, "offset 7 is now on line 2")
        XCTAssertEqual(model.caretColumn, 3)
    }
}
