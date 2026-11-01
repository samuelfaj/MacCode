import AppKit
import XCTest
@testable import AppShell

@MainActor
final class FilesEditorTypingTests: XCTestCase {
    private func editor(_ text: String) -> (NSWindow, CodeEditorTextView, CodeTextEditor.Coordinator) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = CodeEditorTextView()
        view.configureForEditing()
        view.string = text
        window.contentView = view
        window.makeFirstResponder(view)
        let coordinator = CodeTextEditor.Coordinator(onChange: { _ in }, onCaretChange: { _, _ in })
        coordinator.textView = view
        view.delegate = coordinator
        view.onCompletionRequest = { [weak coordinator, weak view] explicit in
            guard let coordinator, let view else { return }
            coordinator.requestCompletion(in: view, explicit: explicit)
        }
        view.suggest.onDismiss = { [weak coordinator] in coordinator?.cancelCompletion() }
        return (window, view, coordinator)
    }

    func test_nativePairedTypingAndNewlineUndoAndRedoRestoreContentAndSelection() {
        let (window, view, coordinator) = editor("if ready ")
        defer { coordinator.tearDown(); window.close() }
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText("{", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "if ready {}")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 10, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "if ready {\n    \n}")
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        view.undo(nil)
        XCTAssertEqual(view.string, "if ready {}", "smart newline must be an undoable native text edit")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 10, length: 0))
        view.redo(nil)
        XCTAssertEqual(view.string, "if ready {\n    \n}")
    }

    func test_compositionDoesNotOpenSuggestionsAndCommitPreservesUnicode() {
        let (window, view, coordinator) = editor("let café = \"🧑🏽‍💻\"\n")
        defer { coordinator.tearDown(); window.close() }
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.suggest.isVisible, "completion must not intercept IME candidate navigation")
        view.insertText("日本語", replacementRange: view.markedRange())
        XCTAssertEqual(view.string, "let café = \"🧑🏽‍💻\"\n日本語")
        XCTAssertEqual(view.selectedRange().location, view.string.utf16.count)
    }

    func test_liveSourceKitFlowsThroughEditorStartupRequestAndKeyboardAcceptance() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RC_LIVE_LSP"] == "1", "requires live SourceKit")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editor-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"EditorLive\")\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let text = "var values = [1]\nvalues.ap"
        let path = root.appendingPathComponent("main.swift").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let (window, view, coordinator) = editor(text)
        defer { coordinator.tearDown(); window.close() }
        coordinator.rootPath = root.path
        coordinator.absolutePath = path
        coordinator.language = "swift"
        view.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        coordinator.switchLanguageServer(to: path)
        // A request made before initialization finishes must still reach the server.
        coordinator.requestCompletion(in: view, explicit: true)
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, view.suggest.model?.items.contains(where: {
            $0.source == .languageServer && $0.label.hasPrefix("append")
        }) != true {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let model = try XCTUnwrap(view.suggest.model, "the editor must show semantic results after server startup")
        let index = try XCTUnwrap(model.items.firstIndex { $0.source == .languageServer && $0.label.hasPrefix("append") })
        for _ in 0..<index { _ = view.suggest.handle(keyCode: 125) }
        XCTAssertTrue(view.suggest.handle(keyCode: 48))
        XCTAssertTrue(view.string.hasPrefix("var values = [1]\nvalues.append"), "keyboard acceptance must apply the server's member edit in the real view")
        view.undo(nil)
        XCTAssertEqual(view.string, text, "accepting a semantic member must undo without deleting the typed prefix")

        coordinator.requestCompletion(in: view, explicit: true)
        coordinator.absolutePath = nil
        coordinator.switchLanguageServer(to: nil)
        view.string = "another file"
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(view.suggest.isVisible, "a response for the old file must not reopen suggestions in the new file")
        XCTAssertEqual(view.string, "another file")
    }

    func test_movingCaretDismissesSuggestionsFromOldPosition() {
        let (window, view, coordinator) = editor("apple\nap")
        defer { coordinator.tearDown(); window.close() }
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        coordinator.requestCompletion(in: view, explicit: true)
        XCTAssertTrue(view.suggest.isVisible)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(view.suggest.isVisible, "a suggestion computed at another caret must not intercept Return or Tab")
    }

    func test_typingNewPrefixAfterMovingCaretRefreshesLocalSuggestions() {
        let (window, view, coordinator) = editor("apple banana\nap\nba")
        defer { coordinator.tearDown(); window.close() }
        view.setSelectedRange(NSRange(location: 15, length: 0))
        coordinator.requestCompletion(in: view, explicit: true)
        XCTAssertTrue(view.suggest.model?.items.contains { $0.label == "apple" } == true)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText("n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.suggest.model?.items.contains { $0.label == "banana" } == true,
                      "local completion must recompute entries, not only refilter the previous prefix's list")
        XCTAssertFalse(view.suggest.model?.items.contains { $0.label == "apple" } == true)
    }
}
