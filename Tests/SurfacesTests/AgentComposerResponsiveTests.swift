import XCTest
import SwiftUI
import AppKit
import UniformTypeIdentifiers
@testable import Surfaces

/// WHY: panes are resized and split; the composer controls must not push the card wider
/// than its pane (they used to overflow past the right edge).
@MainActor
final class AgentComposerResponsiveTests: XCTestCase {
    func test_droppingImageAndDocumentUsesPathsInsteadOfAttachments() async {
        var text = "Review"
        var attachments: [String] = []
        let dropped = expectation(description: "Both file paths inserted")
        dropped.expectedFulfillmentCount = 2
        let bar = AgentChatComposerBar(
            text: Binding(get: { text }, set: { text = $0 }), placeholder: "Ask", sendEnabled: true,
            onSend: {}, onAttach: { attachments += $0 },
            onFileDrop: { paths in
                text = DroppedFilePaths.appending(DroppedFilePaths.composerInputText(for: paths), to: text)
                dropped.fulfill()
            }
        )
        let paths = ["/tmp/image with spaces.png", "/tmp/report.pdf"]
        let providers = paths.map { NSItemProvider(item: NSURL(fileURLWithPath: $0), typeIdentifier: UTType.fileURL.identifier) }
        XCTAssertTrue(bar.loadDroppedFiles(from: providers))
        await fulfillment(of: [dropped], timeout: 3)
        XCTAssertTrue(attachments.isEmpty, "Dropping files must never call the explicit attachment action")
        for path in paths { XCTAssertTrue(text.contains(path)) }
        XCTAssertTrue(text.hasPrefix("Review "), "Keep the existing draft")
    }

    func test_fileDropWithoutACallbackStillInsertsPlainText() {
        var text = "Review"
        var attachments: [String] = []
        let bar = AgentChatComposerBar(
            text: Binding(get: { text }, set: { text = $0 }), placeholder: "Ask", sendEnabled: true,
            onSend: {}, onAttach: { attachments += $0 }
        )
        bar.insertDroppedFilePaths(["/tmp/a.png", "/tmp/b.pdf"])
        XCTAssertEqual(text, "Review /tmp/a.png /tmp/b.pdf")
        XCTAssertTrue(attachments.isEmpty)
        XCTAssertFalse(bar.loadDroppedFiles(from: [NSItemProvider(object: "plain text" as NSString)]))
    }

    func test_wideControlRowFitsANarrowPane() {
        let chips = AnyView(HStack(spacing: 8) {
            ForEach(0..<8, id: \.self) { i in Text("very long control chip \(i)").fixedSize() }
        })
        let bar = AgentChatComposerBar(
            text: .constant(""), attachments: [], placeholder: "Ask", sendEnabled: true,
            runActive: false, isStopping: false, attachEnabled: true,
            onSend: {}, onStop: {}, onAttach: { _ in }, onRemoveAttachment: { _ in },
            composerIdentifier: "c", sendIdentifier: "s", leadingControls: chips
        )
        // Same bar hosts the Bots Desk footer (run-as, models, fixed-size Ultracode, permission).
        let controller = NSHostingController(rootView: bar)
        for width in [320.0, 360.0, 500.0, 900.0] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 400))
            XCTAssertLessThanOrEqual(size.width, width + 1,
                "a long control row must scroll inside the composer, not widen a \(Int(width)) pt pane")
        }
    }
}
