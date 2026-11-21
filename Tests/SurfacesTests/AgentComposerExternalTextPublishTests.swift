import XCTest
import AppKit
import OSLog
import SwiftUI
@testable import Surfaces

/// MacCode 2026-11-20 (pid 90413): SwiftUI logged "Publishing changes from
/// within view updates is not allowed, this will cause undefined behavior" 116
/// times, two per burst, each burst at a user send. A send clears the composer
/// binding; `updateNSView` pushes the new text into the NSTextView and reported
/// the caret synchronously, so the Agent App / Bot desk cursor state published
/// in the middle of SwiftUI's update. SwiftUI does not guarantee such a change
/// is rendered or ordered. The caret must still reach the composer state (it
/// anchors @ / slash suggestions), but only after the update.
@MainActor
final class AgentComposerExternalTextPublishTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var text: String
        @Published var cursorOffset: Int?
        /// Caret reports made from inside the representable's makeNSView/updateNSView.
        var reportsInsideViewUpdate = 0

        init(text: String) { self.text = text }
    }

    private struct Host: View {
        @ObservedObject var model: Model
        @State private var height: CGFloat = AgentComposerTextEditor.minHeight

        var body: some View {
            AgentComposerTextEditor(
                text: $model.text,
                height: $height,
                focusTick: 0,
                placeholder: "",
                accessibilityIdentifier: "test.composer",
                onSend: {},
                onPreviousHistory: { false },
                onNextHistory: { false },
                onTextEdited: {},
                onFileDrop: { _ in },
                onCursorMoved: { offset in
                    if Thread.callStackSymbols.contains(where: { $0.contains("updateNSView") || $0.contains("makeNSView") }) {
                        model.reportsInsideViewUpdate += 1
                    }
                    model.cursorOffset = offset
                },
                onCaretRectChanged: { _ in },
                popupIsOpen: { false },
                onPopupNavUp: {},
                onPopupNavDown: {},
                onPopupApply: {},
                onPopupDismiss: {}
            )
            .frame(width: 480, height: 132)
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

    private func composerTextView(in view: NSView) -> PromptComposerTextView? {
        if let textView = view as? PromptComposerTextView { return textView }
        return view.subviews.lazy.compactMap { self.composerTextView(in: $0) }.first
    }

    /// Hosts the real editor in a window with the text view focused, as when
    /// the user presses Return in the composer.
    private func hostFocusedComposer(_ model: Model, caret: Int?) throws -> PromptComposerTextView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 132),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        self.window = window
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.orderFront(nil)
        spin()
        let textView = try XCTUnwrap(composerTextView(in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(textView))
        if let caret {
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            spin()
        }
        return textView
    }

    /// SwiftUI's own runtime-issue fault, as the user's unified log showed it.
    /// logd ingests it with a delay, so poll briefly before reporting none.
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

    /// Opening a thread or Bot desk with a saved draft mounts the editor with
    /// text; makeNSView is part of the same SwiftUI update.
    func test_mountingAComposerWithADraftDoesNotPublishDuringTheViewUpdate() throws {
        let model = Model(text: "saved draft")
        let start = Date()

        _ = try hostFocusedComposer(model, caret: nil)

        XCTAssertEqual(model.reportsInsideViewUpdate, 0)
        XCTAssertEqual(try publishDuringUpdateFaults(since: start), 0, "mounting must not publish the caret inside SwiftUI's update")
        XCTAssertEqual(model.cursorOffset, 11, "the mounted draft still reports its caret once the update is over")
    }

    /// An empty composer has no caret to restore; mounting it must not publish
    /// composer state at all (main did not either).
    func test_mountingAnEmptyComposerReportsNoCaret() throws {
        let model = Model(text: "")

        _ = try hostFocusedComposer(model, caret: nil)

        XCTAssertNil(model.cursorOffset)
    }

    func test_sendClearingTheComposerDoesNotPublishDuringTheViewUpdate() throws {
        let model = Model(text: "draft to send")
        _ = try hostFocusedComposer(model, caret: 13)
        XCTAssertEqual(model.cursorOffset, 13)
        let start = Date()

        model.reportsInsideViewUpdate = 0
        model.text = ""
        spin()

        XCTAssertEqual(model.reportsInsideViewUpdate, 0)
        XCTAssertEqual(try publishDuringUpdateFaults(since: start), 0, "the caret report must not publish inside SwiftUI's update")
        XCTAssertEqual(model.cursorOffset, 0, "the cleared composer still reports its caret once the update is over")
    }

    func test_recalledPromptReportsItsEndCaretAfterTheUpdate() throws {
        let model = Model(text: "draft to send")
        _ = try hostFocusedComposer(model, caret: 3)
        XCTAssertEqual(model.cursorOffset, 3)
        let start = Date()

        model.reportsInsideViewUpdate = 0
        model.text = "/review the diff"
        spin()

        XCTAssertEqual(model.reportsInsideViewUpdate, 0)
        XCTAssertEqual(try publishDuringUpdateFaults(since: start), 0)
        XCTAssertEqual(model.cursorOffset, 16, "suggestions anchor at the end of the recalled prompt")
    }

    /// A keystroke that lands before the deferred report already reported its
    /// own caret; the deferred report for the replaced text must not add another.
    func test_aKeystrokeBeforeTheDeferredReportKeepsItsCaret() {
        let textView = PromptComposerTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 44))
        var text = ""
        var reports: [Int] = []
        let coordinator = AgentComposerTextEditor.Coordinator(
            text: Binding(get: { text }, set: { text = $0 }),
            height: .constant(44),
            onTextEdited: {},
            onCursorMoved: { reports.append($0) },
            onCaretRectChanged: { _ in }
        )
        textView.delegate = coordinator
        coordinator.textView = textView

        text = "hello"
        coordinator.applyExternalText("hello", to: textView)
        XCTAssertEqual(reports, [], "applyExternalText runs inside updateNSView and must not publish there")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        spin(0.1)

        XCTAssertEqual(text, "he!llo")
        XCTAssertEqual(reports, [2, 3], "the caret move and the keystroke report; the deferred report for the replaced text does not")
    }
}
