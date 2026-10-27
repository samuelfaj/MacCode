import AppKit
import XCTest
@testable import AppShell

@MainActor
final class FilesEditorLSPIntegrationTests: XCTestCase {
    private func makeEditor(_ text: String) -> (NSWindow, CodeEditorTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let textView = CodeEditorTextView()
        textView.allowsUndo = true
        window.contentView = textView
        textView.string = text
        return (window, textView)
    }

    private func keyEvent(_ keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private func entry(_ label: String, insert: String? = nil, replace: NSRange? = nil) -> SuggestEntry {
        SuggestEntry(label: label, insertText: insert ?? label, kind: .variable, detail: nil,
                     documentation: nil, sortText: nil, filterText: nil, replaceRange: replace, source: .word)
    }

    func test_acceptingSuggestionWithReplaceRangeReplacesOnlyThatRangeAndUndoesAsOneEdit() {
        let (_, textView) = makeEditor("let value = foo")
        textView.acceptSuggestion(entry("barbaz", replace: NSRange(location: 12, length: 3)))
        XCTAssertEqual(textView.string, "let value = barbaz",
            "the server replace range must be replaced exactly, not the word under the caret")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "let value = foo",
            "one undo must restore the text replaced by the suggestion")
    }

    func test_acceptingWordEntryWithoutRangeReplacesIdentifierPrefixUnderCaret() {
        let (_, textView) = makeEditor("pri")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.acceptSuggestion(entry("print"))
        XCTAssertEqual(textView.string, "print",
            "a word entry without a range must replace the identifier prefix before the caret")
    }

    func test_downThenReturnWithWidgetVisibleAcceptsSecondEntryWithoutNewline() {
        let (_, textView) = makeEditor("")
        textView.suggest.show(entries: [entry("alpha"), entry("beta")], prefix: "",
                              anchor: textView.caretRect(), in: textView)
        XCTAssertTrue(textView.suggest.isVisible, "precondition: widget must be visible for key routing")
        textView.keyDown(with: keyEvent(125))
        textView.keyDown(with: keyEvent(36, characters: "\r"))
        XCTAssertEqual(textView.string, "beta",
            "Down then Return must accept the second entry; Return must not insert a newline while the list is open")
        XCTAssertFalse(textView.suggest.isVisible, "accepting must dismiss the list")
    }

    func test_multilineGhostKeepsLeadingWhitespaceAndTabAcceptsWholeGhost() {
        let (_, textView) = makeEditor("if x {\n")
        textView.showGhost("  bar()\n}", at: (textView.string as NSString).length)
        textView.keyDown(with: keyEvent(48, characters: "\t"))
        XCTAssertEqual(textView.string, "if x {\n  bar()\n}",
            "multi-line ghost must keep its leading indentation and newlines on Tab accept")
    }

    func test_commandRightAcceptsNextWordChunkAndLeavesRemainderAsGhost() {
        let (_, textView) = makeEditor("if x {\n")
        textView.showGhost("  bar()\n}", at: (textView.string as NSString).length)
        textView.keyDown(with: keyEvent(124, characters: "", modifiers: .command))
        XCTAssertEqual(textView.string, "if x {\n  bar",
            "Cmd+Right must accept the leading whitespace plus the next word only")
        XCTAssertTrue(textView.hasGhost, "the remainder must stay as ghost text after a partial accept")
        textView.keyDown(with: keyEvent(48, characters: "\t"))
        XCTAssertEqual(textView.string, "if x {\n  bar()\n}",
            "accepting the remainder must yield the original ghost with no duplicated or lost text")
    }

    func test_applyDiagnosticsUnderlinesOnlyTheReportedRange() {
        let (_, textView) = makeEditor("let value = 1")
        let diagnostic = LSPDiagnostic(
            range: LSPRange(start: LSPPosition(line: 0, character: 4), end: LSPPosition(line: 0, character: 9)),
            severity: 1, message: "x", source: nil
        )
        textView.applyDiagnostics([diagnostic])
        XCTAssertEqual(textView.diagnostics.map(\.0), [NSRange(location: 4, length: 5)],
            "only the reported range may be painted as a diagnostic")
        let underlines = textView.diagnosticUnderlineRects()
        XCTAssertFalse(underlines.isEmpty, "the diagnostic range must be underlined so the error is visible")
        let glyph0 = textView.textKit2SegmentRects(for: NSRange(location: 0, length: 1))[0]
        XCTAssertTrue(underlines.allSatisfy { $0.rect.minX > glyph0.maxX },
            "text outside the diagnostic range must not be underlined")
        XCTAssertNotNil(textView.textLayoutManager, "diagnostics must not downgrade the view to TextKit 1")
    }

    /// Opt-in: needs `sourcekit-lsp` on PATH. Run with RC_LIVE_LSP=1.
    func test_liveSourceKitCompletionReturnsAppend() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RC_LIVE_LSP"] == "1",
                          "live LSP test is opt-in via RC_LIVE_LSP=1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Live\")\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("a.swift").path
        let text = "var a = [1]; a.ap"
        try text.write(toFile: file, atomically: true, encoding: .utf8)

        let command = try XCTUnwrap(LanguageServerRegistry.command(forPath: file, language: "swift"),
                                    "sourcekit-lsp must be resolvable when RC_LIVE_LSP=1")
        let client = try await LanguageServerPool.shared.client(command: command, rootPath: root.path)
        await client.didOpen(path: file, languageID: "swift", version: 1, text: text)
        let items = try await client.completion(path: file, position: LSPText.position(forUTF16Offset: text.utf16.count, in: text))
        await client.didClose(path: file)
        XCTAssertTrue(items.contains { $0.label.hasPrefix("append") },
                      "sourcekit-lsp must return append for a.ap on an array")
    }
}
