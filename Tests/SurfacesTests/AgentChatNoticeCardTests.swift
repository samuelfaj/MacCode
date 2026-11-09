import AppKit
import CoreModel
import SwiftUI
import XCTest
@testable import Surfaces

/// Titio notice card status: the label tells the user what happened, so every
/// kind and resolved state must map to its spec label and tone.
final class AgentChatNoticeCardTests: XCTestCase {
    private func block(kind: String, state: String = "open") -> TitioNoticeBlock {
        TitioNoticeBlock(key: "k", kind: kind, source: [:], state: state)
    }

    func test_everyOpenKindMapsToItsSpecLabelAndTone() {
        // WHY: a failed run must read as failed, not as a neutral update.
        let expected: [TitioNoticeKind: (String, AgentNoticeStatus.Tone)] = [
            .runCompleted: ("Done", .success), .gitCompleted: ("Done", .success),
            .scriptCompleted: ("Done", .success), .transferCompleted: ("Done", .success),
            .runFailed: ("Failed", .danger), .scriptFailed: ("Failed", .danger),
            .gitFailed: ("Failed", .danger), .scheduledFailed: ("Failed", .danger),
            .transferFailed: ("Failed", .danger), .providerUpdateFailed: ("Failed", .danger),
            .serverListenerFailed: ("Failed", .danger),
            .runInterrupted: ("Interrupted", .warning), .botBlocked: ("Stuck", .warning),
            .approval: ("Needs approval", .warning), .manualAction: ("Action needed", .warning),
            .botReply: ("Replied", .accent), .userInput: ("Question", .accent),
            .botQuestion: ("Question", .accent),
            .sshDisconnected: ("Update", .neutral), .fileConflict: ("Update", .neutral),
            .notificationsDenied: ("Update", .neutral), .external: ("Update", .neutral),
        ]
        XCTAssertEqual(Set(expected.keys), Set(TitioNoticeKind.allCases), "every kind needs a row")
        for (kind, want) in expected {
            let status = AgentNoticeStatus.of(block(kind: kind.rawValue))
            XCTAssertEqual(status.label, want.0, "kind \(kind.rawValue)")
            XCTAssertEqual(status.tone, want.1, "kind \(kind.rawValue)")
        }
    }

    func test_everyResolvedStateReplacesTheKindStatus() {
        // WHY: a resolved notice must not still claim it needs approval.
        let expected: [(String, String)] = [
            ("answered", "Answered"), ("approved", "Approved"), ("declined", "Declined"),
            ("done", "Done"), ("elsewhere", "Handled elsewhere"), ("expired", "Expired"),
            ("acknowledged", "Seen"), ("failed", "Didn't go through"), ("unknown_effect", "Unconfirmed"),
        ]
        for (state, label) in expected {
            let status = AgentNoticeStatus.of(block(kind: "approval", state: state))
            XCTAssertEqual(status.label, label, "state \(state)")
            XCTAssertEqual(status.tone, .neutral, "state \(state)")
        }
    }

    func test_unknownKindFallsBackToUpdate() {
        // WHY: a newer host kind must still show a card, not crash or hide.
        let status = AgentNoticeStatus.of(block(kind: "futureKind"))
        XCTAssertEqual(status.label, "Update")
        XCTAssertEqual(status.symbol, "info.circle.fill")
    }

    func test_unknownStateFallsBackToNeutralUpdate() {
        // WHY: an unknown resolved state is not a success; it stays neutral.
        let status = AgentNoticeStatus.of(block(kind: "approval", state: "future_state"))
        XCTAssertEqual(status.label, "Update")
        XCTAssertEqual(status.tone, .neutral)
    }

    /// WHY: "Open conversation" must be a real button on a result notice, and a draft in the composer must not block it.
    @MainActor
    func test_resultNoticeShowsOpenConversationAsAButtonAndReportsTheTap() throws {
        let composer = AgentComposerState()
        composer.prompt = "half-written message"
        var tapped: [Int] = []
        let choices = BotChoicesBlock.parse("x\n\n" + TitioNoticeCopy.choicesBlock(question: nil, options: ["Open conversation", "Got it"], notice: "k"))
        let card = AgentChatNoticeCard(
            messageID: "m1", block: block(kind: "botReply"), choices: choices.choices, createdAt: Date(),
            content: AnyView(Text("O Developer testou os dois cards no star: falharam na primeira vez e passaram depois da correção.")),
            composerState: composer, isBlockedByDraft: { true }, isSending: false,
            onOption: { tapped.append($0) }, onReply: { _ in true }, onClear: nil
        )
        let size = CGSize(width: 640, height: 260)
        let hosting = NSHostingView(rootView: card.frame(width: size.width, height: size.height).background(Color.black))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["REMOTE_CODE_NOTICE_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("result-notice.png"))
        }
        XCTAssertEqual(choices.choices?.question, nil)
        XCTAssertTrue(tapped.isEmpty)
    }
}
