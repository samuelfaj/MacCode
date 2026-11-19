import XCTest
import AppKit
import SwiftUI
@testable import Surfaces

/// Crash 2026-11-18 18:07 -03 (NSRangeException, Agent App composer): while a
/// keystroke is still being applied, AppKit posts the selection change before
/// `textDidChange` copies the new string into the SwiftUI binding. The caret
/// report published SwiftUI state at that moment; SwiftUI re-rendered
/// synchronously, `updateNSView` took the lagging binding for an external edit
/// and replaced the text mid-edit, which reverts the keystroke and makes AppKit
/// throw. The caret may only be published once the binding matches the text view.
final class AgentComposerTextEditorMidEditCursorTests: XCTestCase {
    private struct CursorReport {
        let offset: Int
        let bindingMatchesTextView: Bool
    }

    private final class Harness {
        let text = BindingBox("abc")
        var reports: [CursorReport] = []
        /// Runs after each caret report, like a SwiftUI update the publish triggers.
        var reportHook: () -> Void = {}
        let storage = NSTextStorage()
        let textView: PromptComposerTextView
        let coordinator: AgentComposerTextEditor.Coordinator

        init() {
            let size = NSSize(width: 480, height: 44)
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(containerSize: NSSize(width: size.width, height: .greatestFiniteMagnitude))
            layoutManager.addTextContainer(container)
            textView = PromptComposerTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
            textView.font = .systemFont(ofSize: 13)
            textView.string = text.value
            let box = text
            var onCursorMoved: (Int) -> Void = { _ in }
            coordinator = AgentComposerTextEditor.Coordinator(
                text: Binding(get: { box.value }, set: { box.value = $0 }),
                height: .constant(44),
                onTextEdited: {},
                onCursorMoved: { onCursorMoved($0) },
                onCaretRectChanged: { _ in }
            )
            textView.delegate = coordinator
            coordinator.textView = textView
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            onCursorMoved = { [unowned self] offset in
                reports.append(CursorReport(offset: offset, bindingMatchesTextView: text.value == textView.string))
                reportHook()
            }
        }
    }

    func test_typingPublishesTheCaretOnlyAfterTheBindingHasTheKeystroke() {
        let harness = Harness()

        harness.textView.insertText("d", replacementRange: harness.textView.selectedRange())

        XCTAssertEqual(harness.text.value, "abcd")
        XCTAssertFalse(harness.reports.isEmpty, "the keystroke must still report the caret for suggestion anchoring")
        XCTAssertTrue(
            harness.reports.allSatisfy(\.bindingMatchesTextView),
            "a caret report while the binding lags lets SwiftUI push the old text back mid-edit"
        )
        XCTAssertEqual(harness.reports.last?.offset, 4)
    }

    func test_deletingPublishesTheCaretOnlyAfterTheBindingHasTheEdit() {
        let harness = Harness()

        harness.textView.deleteBackward(nil)

        XCTAssertEqual(harness.text.value, "ab")
        XCTAssertFalse(harness.reports.isEmpty)
        XCTAssertTrue(harness.reports.allSatisfy(\.bindingMatchesTextView))
        XCTAssertEqual(harness.reports.last?.offset, 2)
    }

    /// What the crash did to the user: SwiftUI handled the caret publish at once
    /// and ran `updateNSView`, whose sync step pushes the binding into the view.
    func test_synchronousRerenderOnCaretReportKeepsTheKeystroke() {
        let harness = Harness()
        let textView = harness.textView
        let coordinator = harness.coordinator
        let text = harness.text
        var rerenders = 0
        harness.reportHook = {
            rerenders += 1
            if textView.string != text.value, !textView.hasMarkedText() {
                coordinator.applyExternalText(text.value, to: textView)
            }
        }

        textView.insertText("d", replacementRange: textView.selectedRange())

        XCTAssertGreaterThan(rerenders, 0)
        XCTAssertEqual(textView.string, "abcd", "the typed character must survive a synchronous re-render")
        XCTAssertEqual(text.value, "abcd")
    }

    func test_caretMoveWithoutEditStillReports() {
        let harness = Harness()

        harness.textView.setSelectedRange(NSRange(location: 1, length: 0))

        XCTAssertEqual(harness.reports.map(\.offset), [1], "plain caret moves keep anchoring @/slash suggestions")
        XCTAssertTrue(harness.reports.allSatisfy(\.bindingMatchesTextView))
    }
}
