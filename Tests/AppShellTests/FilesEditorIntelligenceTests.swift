import XCTest
import AppKit
@testable import AppShell

/// Covers the shipped completion engine, the AppKit completion/ghost path and
/// the Distill inline-completion boundary. The engine drives the real editor
/// popup; these tests call the same functions `CodeEditorTextView` calls.
final class FilesEditorIntelligenceTests: XCTestCase {
    private func caret(at text: String) -> Int { (text as NSString).length }

    // MARK: Word completion engine

    func test_swiftPrefixOffersLanguageKeyword() {
        let text = "let total = 1\nfun"
        let items = FileCompletionEngine.completions(in: text, caret: caret(at: text), language: "swift")
        XCTAssertEqual(items.first?.insertText, "func",
            "typing `fun` in Swift must offer `func` from the language dictionary")
        XCTAssertTrue(items.contains { $0.kind == .keyword })
    }

    func test_typescriptPrefixOffersLanguageKeyword() {
        let text = "const x = 1;\nfun"
        let items = FileCompletionEngine.completions(in: text, caret: caret(at: text), language: "typescript")
        XCTAssertEqual(items.first?.insertText, "function",
            "the same prefix in TypeScript must offer the language-appropriate keyword, not Swift's")
    }

    func test_longerPrefixNarrowsTheList() {
        let short = FileCompletionEngine.completions(in: "p", caret: 1, language: "swift")
        let long = FileCompletionEngine.completions(in: "pri", caret: 3, language: "swift")
        XCTAssertGreaterThan(short.count, long.count,
            "a longer typed prefix must narrow the suggestion list")
        XCTAssertEqual(long.map(\.insertText), ["private", "print"],
            "`pri` must narrow to the two Swift matches, in source order")
    }

    func test_documentSymbolsAppearInCompletions() {
        let text = "let totalCount = 1\nprint(total"
        let items = FileCompletionEngine.completions(in: text, caret: caret(at: text), language: "swift")
        XCTAssertTrue(items.contains { $0.insertText == "totalCount" },
            "identifiers already in the document are valid local completions")
    }

    func test_emptyPrefixReturnsNoCompletions() {
        XCTAssertTrue(FileCompletionEngine.completions(in: "let x = ", caret: 8, language: "swift").isEmpty,
            "whitespace caret must not pop the completion list")
    }

    func test_applyReplacesOnlyTheTypedPrefix() {
        let item = FileCompletionItem("print", kind: .function)
        let result = FileCompletionEngine.apply(item, to: "let x = pri", replacing: NSRange(location: 8, length: 3))
        XCTAssertEqual(result.text, "let x = print")
        XCTAssertEqual(result.caret, 13)
    }

    // MARK: AppKit editor path

    @MainActor
    func test_completionListIsServedByTheRealEditorTextView() {
        let textView = CodeEditorTextView()
        textView.string = "fun"
        textView.language = "swift"
        textView.completionItemsForPrefix = { text, caret in
            FileCompletionEngine.completions(in: text, caret: caret, language: "swift")
        }
        var index = 0
        let words = textView.completions(
            forPartialWordRange: NSRange(location: 0, length: 3),
            indexOfSelectedItem: &index
        ) ?? []
        XCTAssertEqual(words.first, "func",
            "the native completion popup must be fed by the same language engine")
    }

    @MainActor
    func test_ghostCompletionDoesNotChangeDocumentUntilAccepted() {
        let textView = CodeEditorTextView()
        textView.string = "let x = "
        textView.showGhost("42", at: (textView.string as NSString).length)
        XCTAssertEqual(textView.string, "let x = ",
            "AI completion is painted as ghost text and must not mutate the document")
        XCTAssertTrue(textView.hasGhost)

        textView.acceptGhost()
        XCTAssertEqual(textView.string, "let x = 42",
            "Tab acceptance inserts the ghost text at the caret")
        XCTAssertFalse(textView.hasGhost)
    }

    @MainActor
    func test_acceptingGhostIsASingleUndoableEdit() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let textView = CodeEditorTextView()
        textView.allowsUndo = true
        window.contentView = textView
        textView.string = "let x = "
        textView.showGhost("42", at: (textView.string as NSString).length)
        textView.acceptGhost()
        XCTAssertEqual(textView.string, "let x = 42")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "let x = ",
            "one undo must remove the accepted completion as a single edit")
    }

    @MainActor
    func test_editorConfiguresUndoAndNativeFindBar() {
        let textView = CodeEditorTextView()
        textView.configureForEditing()
        XCTAssertTrue(textView.allowsUndo)
        XCTAssertTrue(textView.usesFindBar, "Cmd+F must open the native find-in-file bar")
        XCTAssertTrue(textView.isIncrementalSearchingEnabled)
        XCTAssertFalse(textView.isRichText)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled,
            "code must never turn straight quotes into smart quotes")
    }

    @MainActor
    func test_externalTextUpdateKeepsCaretAndSelection() {
        let textView = CodeEditorTextView()
        textView.string = "let value = 1"
        textView.selectedRange = NSRange(location: 4, length: 5)
        let old = textView.replaceTextPreservingSelection("let other = 2")
        XCTAssertEqual(old, "let value = 1")
        XCTAssertEqual(textView.string, "let other = 2")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 5),
            "a disk/remote update must not move the user's caret or selection")
    }

    @MainActor
    func test_undoAndRedoRestoreTyping() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let textView = CodeEditorTextView()
        textView.configureForEditing()
        window.contentView = textView
        textView.string = "let a = "
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.insertText("1", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "let a = 1")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "let a = ")
        textView.undoManager?.redo()
        XCTAssertEqual(textView.string, "let a = 1")
    }

    func test_lineNumberOffsetsMatchDocumentLines() {
        let text = "one\ntwo\nthree"
        let offsets = buildLineStartOffsets(text: text)
        XCTAssertEqual(offsets, [0, 4, 8])
        XCTAssertEqual(lineIndex(forCharOffset: 0, in: offsets), 0)
        XCTAssertEqual(lineIndex(forCharOffset: 5, in: offsets), 1,
            "a character in the second line must report line index 1 for the ruler")
        XCTAssertEqual(lineIndex(forCharOffset: 9, in: offsets), 2)
    }

    @MainActor
    func test_acceptingWordCompletionIsOneUndoableEdit() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let textView = CodeEditorTextView()
        textView.allowsUndo = true
        window.contentView = textView
        textView.string = "pri"
        textView.insertCompletion("print", forPartialWordRange: NSRange(location: 0, length: 3), movement: 0, isFinal: true)
        XCTAssertEqual(textView.string, "print")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "pri",
            "accepting an IntelliSense item must be a single undo step")
    }

    // MARK: Inline completion request/provider boundary

    @MainActor
    func test_switchingDocumentsKeepsUndoAndCaretWithEachFile() {
        let view = CodeEditorTextView()
        view.configureForEditing()
        let paths: Set<String> = ["a.swift", "b.swift"]
        view.switchDocument(to: "a.swift", text: "first", openPaths: paths)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertText(" edited", replacementRange: view.selectedRange())
        view.switchDocument(to: "b.swift", text: "second", openPaths: paths)
        XCTAssertFalse(view.undoManager?.canUndo ?? true, "Undo in B must never apply an edit from A")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertText("!", replacementRange: view.selectedRange())
        view.switchDocument(to: "a.swift", text: "first edited", openPaths: paths)
        XCTAssertEqual(view.selectedRange().location, 12)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "first")
        view.undoManager?.redo()
        XCTAssertEqual(view.string, "first edited")
        view.switchDocument(to: "b.swift", text: "second!", openPaths: paths)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "second")
    }

    @MainActor
    func test_movingCaretClearsGhostAndExternalReplacementClearsStaleUndo() {
        let view = CodeEditorTextView()
        view.configureForEditing()
        view.string = "abc"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.showGhost("def", at: 3)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(view.hasGhost, "a completion must not be accepted at the previous caret")
        view.acceptGhost()
        XCTAssertEqual(view.string, "abc")
        view.insertText("x", replacementRange: view.selectedRange())
        view.replaceTextPreservingSelection("remote")
        XCTAssertFalse(view.undoManager?.canUndo ?? true, "old undo ranges are invalid after a full external replacement")
    }

    func test_requestCarriesPathLanguageAndSurroundingContext() {
        let text = "let value = compute(\nnext"
        let caret = (text as NSString).range(of: "compute(").upperBound
        let request = InlineCompletionRequest(path: "/w/Sources/App.swift", language: "swift", text: text, caret: caret)
        XCTAssertEqual(request.path, "/w/Sources/App.swift")
        XCTAssertEqual(request.language, "swift")
        XCTAssertTrue(request.prefix.hasSuffix("compute("),
            "the request must carry the prefix immediately before the caret")
        XCTAssertTrue(request.suffix.hasPrefix("\nnext"),
            "the request must carry the suffix immediately after the caret")
        let prompt = request.prompt
        XCTAssertTrue(prompt.contains("App.swift"))
        XCTAssertTrue(prompt.contains("swift"))
        XCTAssertTrue(prompt.contains("<cursor/>"))
        XCTAssertTrue(prompt.contains(request.suffix),
            "the prompt must carry the text after the caret so the model can complete in context")
    }

    func test_providerReturnsSanitizedCompletionAndRecordsPrompt() async throws {
        let recorder = PromptRecorder()
        let provider = DistillInlineCompletionProvider { prompt in
            await recorder.record(prompt)
            return "```swift\n42\n```"
        }
        let request = InlineCompletionRequest(path: "/w/a.swift", language: "swift", text: "let x = ", caret: 8)
        let completion = try await provider.complete(request)
        XCTAssertEqual(completion, "42",
            "markdown fences from the model must be stripped before ghost text is shown")
        let prompts = await recorder.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("let x = "))
    }

    func test_sanitizeKeepsLeadingWhitespaceOfIndentedCompletion() {
        XCTAssertEqual(DistillInlineCompletionProvider.sanitize("  bar()\n}", prefix: "", suffix: ""), "  bar()\n}",
            "leading indentation is part of the completion; trimming it breaks the inserted block")
    }

    func test_providerRejectsCompletionThatOnlyRepeatsTheSuffix() {
        XCTAssertNil(DistillInlineCompletionProvider.sanitize("next()", prefix: "x.", suffix: "next()"),
            "a completion duplicating existing following text must be dropped")
    }

    func test_providerTimeoutSurfacesAsErrorAndLeavesCallerAbleToContinue() async {
        let provider = DistillInlineCompletionProvider(timeout: 0.05) { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            return "too late"
        }
        let request = InlineCompletionRequest(path: "/w/a.swift", language: "swift", text: "let x = ", caret: 8)
        do {
            _ = try await provider.complete(request)
            XCTFail("a slow provider must time out instead of blocking the editor")
        } catch {
            XCTAssertEqual(error as? InlineCompletionError, .timedOut)
        }
    }

    @MainActor
    func test_providerFailureLeavesTheEditorDocumentUnchanged() async {
        let textView = CodeEditorTextView()
        textView.string = "let x = "
        let provider = DistillInlineCompletionProvider { _ in throw InlineCompletionError.timedOut }
        let request = InlineCompletionRequest(
            path: "/w/a.swift", language: "swift", text: textView.string,
            caret: (textView.string as NSString).length
        )
        _ = try? await provider.complete(request)
        XCTAssertEqual(textView.string, "let x = ",
            "a failed or timed-out AI completion must leave the editor content untouched")
        XCTAssertFalse(textView.hasGhost)
    }

    private func completionFixture(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inline-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("distill-fixture")
        try ("#!/bin/sh\n" + body + "\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary
    }

    func test_realTransportCannotDeadlockOnUndrainedDiagnostics() async throws {
        let binary = try completionFixture("exec /usr/bin/perl -e 'print STDERR \"x\" x 131072; print qq({\"type\":\"text\",\"data\":\"done\"}\\n);'")
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let text = try await DistillCLIInlineCompletionTransport(binary: binary.path).send(prompt: "fixture")
        XCTAssertEqual(text, "done", "Diagnostics larger than the pipe buffer must not block an editor completion")
    }

    func test_realTransportCancellationHonorsProviderDeadlineAndReapsOwnedProcess() async throws {
        let binary = try completionFixture("trap '' TERM\necho $$ > \"$0.pid\"\n/bin/sleep 30 &\necho $! > \"$0.child\"\nwait")
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let transport = DistillCLIInlineCompletionTransport(binary: binary.path)
        let provider = DistillInlineCompletionProvider(timeout: 0.5) { try await transport.send(prompt: $0) }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await provider.complete(InlineCompletionRequest(path: "/w/a.swift", language: "swift", text: "let x = ", caret: 8))
            XCTFail("A suspended CLI must not outlive the completion deadline")
        } catch {
            XCTAssertEqual(error as? InlineCompletionError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: binary.path + ".pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let child = try XCTUnwrap(Int32(String(contentsOfFile: binary.path + ".child", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<200 where kill(pid, 0) == 0 || kill(child, 0) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "Cancelling ghost text must terminate the exact child even when it ignores SIGTERM")
        XCTAssertNotEqual(kill(child, 0), 0, "The owned descendant holding stdout must be reaped with its isolated process group")
    }

    func test_providerErrorPropagatesWithoutMutatingAnything() async {
        let provider = DistillInlineCompletionProvider { _ in throw InlineCompletionError.unavailable }
        let request = InlineCompletionRequest(path: "/w/a.swift", language: "swift", text: "let x = ", caret: 8)
        do {
            _ = try await provider.complete(request)
            XCTFail("provider failure must surface")
        } catch {
            XCTAssertEqual(error as? InlineCompletionError, .unavailable)
        }
    }
}

private actor PromptRecorder {
    private(set) var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
}
