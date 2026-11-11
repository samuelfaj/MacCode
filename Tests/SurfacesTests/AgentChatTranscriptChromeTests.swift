import XCTest
import AppKit
import CoreModel
import DesignSystemKit
import SwiftUI
@testable import Surfaces

final class AgentChatTranscriptChromeTests: XCTestCase {

    func test_agentAppChat_usesStableForEachIdentity() throws {
        // WHY: AvdLee list-patterns — ForEach identity must outlive the row.
        // `id: \.offset` remounts every image/option when the collection shifts
        // and was the freeze-class SwiftUI invalidation finding on Agent App chat.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains("id: \\.offset"),
            "Agent App chat/rail ForEach must not use positional identity"
        )
        XCTAssertTrue(
            source.contains("identifiedOptions"),
            "AskUserQuestion options must use a precomputed stable row id"
        )
        XCTAssertFalse(
            source.contains("ForEach(request.options, id: \\.self)"),
            "legacy user-input options must not use id:\\.self (duplicate labels collide)"
        )
        let markdown = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentMessageMarkdown.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            markdown.contains("Unary ForEach child"),
            "markdown groups must wrap the isolated/prose branch so ForEach stays unary"
        )
        XCTAssertTrue(
            AgentImageViewPresentation(
                displayName: "shot.png",
                resourceURL: URL(fileURLWithPath: "/tmp/shot.png")
            ).id.hasSuffix("shot.png"),
            "image strip identity must follow the resource URL, not the index"
        )
    }

    /// Nested SwiftUI ScrollView inside the transcript reads the parent's
    /// Observable `ScrollEnvironmentStorage` (`isScrollViewTransformClippingEnabled`)
    /// and SIGSEGVs when the outer storage is mid-update on macOS 26.
    func test_transcriptImageStripDoesNotNestSwiftUIScrollView() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private struct AgentTranscriptImageThumbStrip"))
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "// MARK: - ThreadMarkdownFormatter")?.lowerBound ?? rest.endIndex
        let slice = String(rest[..<end])
        XCTAssertTrue(slice.contains("AgentTranscriptImageThumb("))
        XCTAssertFalse(
            slice.contains("ScrollView("),
            "image citations must not nest a SwiftUI ScrollView in the transcript"
        )
    }

    func test_statusCardIsFullWidthOnItsOwnLine_becauseRunHeadersAreNotBubbles() throws {
        // WHY: Supervised-run / work-log panels hugged content next to a
        // timestamp gutter. System cards must span the transcript column.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatTranscriptChrome.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "public struct AgentChatStatusCard") else {
            return XCTFail("AgentChatStatusCard must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\npublic struct AgentChatUserBubble")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(slice.contains(".dsPanel(padding: DS.Space.lg)"))
        XCTAssertTrue(slice.contains("DSPill(statusLabel, tone: statusTone)"))
        XCTAssertTrue(slice.contains("style: .time"))
        XCTAssertFalse(
            slice.contains("frame(width: 56"),
            "status card must not recreate the timestamp gutter"
        )
    }

    func test_bubbleMetricsMatchAgentApp_becauseDeskMustShareTheSameChatChrome() {
        // WHY: Bots Desk is supposed to look like Agent App chat. If these
        // numbers drift, user bubbles wrap at a different width and the
        // copy/timestamp row hangs past the pane again.
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleMaxWidth,
            AgentAppView.userMessageBubbleMaxWidth
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleLeadingGutter,
            AgentAppView.userMessageBubbleLeadingGutter
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleMinWidth,
            AgentAppView.userMessageBubbleMinWidth
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: 900),
            AgentAppView.userMessageBubbleWidthCap(columnWidth: 900)
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: 280),
            AgentAppView.userMessageBubbleWidthCap(columnWidth: 280)
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: 40),
            AgentAppView.userMessageBubbleWidthCap(columnWidth: 40)
        )
        XCTAssertEqual(AgentChatTranscriptChrome.sendCircleSize, 28)
        XCTAssertGreaterThanOrEqual(AgentChatTranscriptChrome.sendHitTarget, 44)
    }

    func test_relativeTimestampMatchesAgentApp_includingJustNowWindow() {
        // WHY: both transcripts must say "just now" for the same instant so
        // Desk does not invent a second time language.
        let now = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 59)
        let older = Date(timeIntervalSince1970: 40)
        XCTAssertEqual(
            AgentChatTranscriptChrome.relativeTimestamp(recent, now: now),
            AgentAppView.relativeTimestamp(recent, now: now)
        )
        XCTAssertEqual(AgentChatTranscriptChrome.relativeTimestamp(recent, now: now), "just now")
        XCTAssertEqual(
            AgentChatTranscriptChrome.relativeTimestamp(older, now: now),
            AgentAppView.relativeTimestamp(older, now: now)
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.absoluteTimestamp(now),
            AgentAppView.absoluteTimestamp(now)
        )
    }

    func test_composerPlaceholderMatchesAgentAppWording() {
        // WHY: Agent App reads "Ask Grok for changes…". Desk must not drop
        // back to a custom "Message bot" / "Send" dialect.
        XCTAssertEqual(
            AgentChatTranscriptChrome.composerPlaceholder(providerDisplayName: "Grok"),
            "Ask Grok for changes…"
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.composerPlaceholder(providerDisplayName: "Claude"),
            "Ask Claude for changes…"
        )
    }

    func test_admitsSend_matchesAgentAppEmptyRule_becauseAttachmentsCountAsATurn() {
        // WHY: Agent App send is enabled with files and empty text. Desk must
        // use the same admission so attach-only turns are not silently dropped.
        XCTAssertFalse(AgentChatTranscriptChrome.admitsSend(text: "  ", attachmentCount: 0))
        XCTAssertTrue(AgentChatTranscriptChrome.admitsSend(text: "go", attachmentCount: 0))
        XCTAssertTrue(AgentChatTranscriptChrome.admitsSend(text: "", attachmentCount: 1))
    }

    func test_displayUserLine_prefixesAttachmentsLikeAgentApp() {
        // WHY: the transcript must show what was attached, the same way Agent
        // App suffixes 📎 names onto the user line.
        let file = AgentAttachment(path: "/tmp/brief.pdf", displayName: "brief.pdf", kind: .file)
        XCTAssertEqual(
            AgentChatTranscriptChrome.displayUserLine(text: "Review this", attachments: [file]),
            "Review this\n\n📎 brief.pdf"
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.displayUserLine(text: "  ", attachments: [file]),
            "📎 brief.pdf"
        )
    }

    func test_displayUserLine_emitsLiteralImageMarkers_becauseBotsAndAgentAppMustShareThem() {
        // WHY: both transcripts must show the Grok-style `[Image #1]` marker
        // for the first image, not a 📎 filename that the user cannot map.
        let shot = AgentAttachment(path: "/tmp/shot.png", displayName: "shot.png", kind: .image)
        let second = AgentAttachment(path: "/tmp/diagram.jpg", displayName: "diagram.jpg", kind: .image)
        let brief = AgentAttachment(path: "/tmp/brief.pdf", displayName: "brief.pdf", kind: .file)
        XCTAssertEqual(
            AgentChatTranscriptChrome.displayUserLine(text: "Look at this", attachments: [shot]),
            "Look at this\n\n[Image #1]"
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.displayUserLine(text: "", attachments: [shot, second]),
            "[Image #1]\n\n[Image #2]"
        )
        XCTAssertEqual(
            AgentChatTranscriptChrome.displayUserLine(
                text: "Review",
                attachments: [shot, brief, second]
            ),
            "Review\n\n[Image #1]\n\n[Image #2]\n\n📎 brief.pdf"
        )
        let stripped = AgentChatTranscriptChrome.promptByRemovingDisplayDecorations(
            from: "Look at this\n\n[Image #1]",
            attachments: [shot]
        )
        XCTAssertEqual(stripped, "Look at this")
    }

    func test_deskWorkingLabel_usesAgentAppThinkingPhase() {
        // WHY: a live bot turn must show the same working phrase Agent App
        // uses, not only a work-log pill.
        let start = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 12)
        XCTAssertNil(AgentChatTranscriptChrome.deskWorkingLabel(runIsLive: false, startedAt: start, now: now))
        XCTAssertEqual(
            AgentChatTranscriptChrome.deskWorkingLabel(runIsLive: true, startedAt: start, now: now),
            AgentWorkingStripPresentation.label(phase: .thinking, elapsedSeconds: 12)
        )
    }

    func test_deskWorkingLabel_seesStreamingTools_becauseAThinkingPillIsNotEnough() {
        // WHY: when the live turn is running tools, Desk must switch the
        // composer phase to Tools — the same signal Agent App uses — not stay
        // stuck on Thinking with hasStreamingTools hardcoded false.
        let start = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 12)
        XCTAssertEqual(
            AgentChatTranscriptChrome.deskWorkingLabel(
                runIsLive: true,
                startedAt: start,
                hasStreamingTools: true,
                now: now
            ),
            AgentWorkingStripPresentation.label(phase: .tools, elapsedSeconds: 12)
        )
    }

    func test_userMessageBubbleContentWidth_hugsShortPromptInsteadOfTwoGlyphColumn() {
        // WHY: the live screenshot showed "Go" / "Gr" because the selectable
        // NSTextView reported width 0 and wrapped at two glyphs. Short prompts
        // must hug; long prompts cap at the bubble text max.
        let short = AgentChatTranscriptChrome.userMessageBubbleContentWidth(
            text: "Go to my linear",
            columnWidth: 900
        )
        XCTAssertGreaterThan(short, 80, "must not wrap the prompt into a 2-glyph column")
        XCTAssertLessThan(
            short,
            AgentChatTranscriptChrome.userMessageBubbleMaxWidth - DS.Space.xl * 2
        )

        let long = AgentChatTranscriptChrome.userMessageBubbleContentWidth(
            text: String(repeating: "long prompt word ", count: 40),
            columnWidth: 900
        )
        let textMax = AgentChatTranscriptChrome.userMessageBubbleMaxWidth - DS.Space.xl * 2
        XCTAssertEqual(long, textMax, accuracy: 0.5)

        let narrow = AgentChatTranscriptChrome.userMessageBubbleContentWidth(
            text: String(repeating: "long prompt word ", count: 40),
            columnWidth: 280
        )
        let narrowMax = AgentChatTranscriptChrome.userMessageBubbleWidthCap(columnWidth: 280)
            - DS.Space.xl * 2
        XCTAssertEqual(narrow, narrowMax, accuracy: 0.5)
    }

    func test_userBubbleLayout_shortMessageDoesNotCollapseToTwoGlyphs() {
        // WHY: user-visible proof for the collapsed bubble. Host the same
        // AgentChatUserBubble Agent App / Desk mount and measure the NSTextView.
        let canvas = AgentChatUserBubble(
            text: "Go to my linear",
            createdAt: Date(),
            columnWidth: 800
        )
        .frame(width: 800, height: 160)
        let hosting = NSHostingView(rootView: canvas)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 160)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        guard let textView = firstTextView(in: hosting) else {
            return XCTFail("user bubble must mount AgentSelectablePlainText")
        }
        XCTAssertGreaterThan(
            textView.bounds.width,
            80,
            "hosted user bubble must hug the prompt, not a 2-glyph column"
        )
        XCTAssertLessThan(
            textView.bounds.width,
            AgentChatTranscriptChrome.userMessageBubbleMaxWidth
        )
    }

    func test_userBubbleVoiceOverSpeaksMessage_becauseRoleLabelHidThePrompt() throws {
        // WHY: Computer Use on Desk saw user bubbles as AXStaticText value
        // `user` and the copy control as AXButton `user`. The parent
        // accessibilityLabel("user") overwrote the prompt. Name the bubble
        // with the message text; keep Copy message on the button.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatTranscriptChrome.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "public struct AgentChatUserBubble") else {
            return XCTFail("AgentChatUserBubble must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\npublic struct AgentChatAssistantReply")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertFalse(
            slice.contains(".accessibilityLabel(\"user\")"),
            "parent must not name the whole bubble user"
        )
        XCTAssertTrue(
            slice.contains(".accessibilityLabel(text)"),
            "bubble body must expose the prompt as the VoiceOver name"
        )
        XCTAssertTrue(
            slice.contains(".accessibilityLabel(L(\"Copy message\"))"),
            "copy control must stay Copy message after the role label is gone"
        )
        XCTAssertTrue(
            slice.contains("userMessageBubbleContentWidth"),
            "bubble width must be measured, not left to ViewThatFits + NSTextView ideal=0"
        )
        XCTAssertFalse(
            slice.contains("ViewThatFits"),
            "ViewThatFits treated a 0-wide NSTextView as fitting and collapsed the prompt"
        )
    }

    func test_assistantReplyVoiceOverSpeaksMessage_becauseRoleLabelHidTheReply() throws {
        // WHY: Computer Use on Desk saw assistant replies as AXTextArea
        // label `assistant` while the value was the message. VoiceOver
        // speaks the label first, so the role hid the reply. Name the
        // markdown body with the message text; keep Copy message.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatTranscriptChrome.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "public struct AgentChatAssistantReply") else {
            return XCTFail("AgentChatAssistantReply must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\npublic struct AgentChatComposerBar")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertFalse(
            slice.contains(".accessibilityLabel(\"assistant\")"),
            "reply body must not be named assistant"
        )
        XCTAssertTrue(
            slice.contains(".accessibilityLabel(text)"),
            "reply body must expose the message as the VoiceOver name"
        )
        XCTAssertTrue(
            slice.contains(".accessibilityLabel(L(\"Copy message\"))"),
            "copy control must stay Copy message after the role label is gone"
        )
    }

    func test_assistantCopyMatchesUserCopyChrome_becauseTenPointIconIsInvisibleOnDesk() throws {
        // WHY: Desk assistant Copy message painted at 10x12.5 while the
        // user bubble already frames the same glyph at 18x18. Users cannot
        // find or hit the leftover tiny control.
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentChatTranscriptChrome.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "public struct AgentChatAssistantReply") else {
            return XCTFail("AgentChatAssistantReply must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\npublic struct AgentChatComposerBar")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains(".font(.system(size: 11, weight: .regular))"))
        XCTAssertTrue(slice.contains(".frame(width: 18, height: 18)"))
        XCTAssertFalse(
            slice.contains(".font(.system(size: 10))"),
            "assistant Copy must not stay a 10pt leftover icon"
        )
    }

    func test_agentAppMountsSharedTranscriptChrome_becausePrivateTwinsDrift() throws {
        // WHY: dest already extracted loading/working/pill/bubble/reply/live
        // turn/queue. Agent App painting private twins is how those controls
        // diverged (10pt copy, header DSPill, leftover workingStatus).
        let source = try String(
            contentsOf: URL(fileURLWithPath: "Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        for token in [
            "AgentChatLoadingStatusStrip(",
            "AgentChatWorkingStatusStrip(",
            "AgentChatWorkingPill(",
            "AgentChatUserBubble(",
            "AgentChatAssistantReply(",
            "AgentChatLiveTurnView(",
            "AgentQueuedRow(",
        ] {
            XCTAssertTrue(source.contains(token), "Agent App must mount \(token)")
        }
        XCTAssertFalse(source.contains("private var loadingStatus"))
        XCTAssertFalse(source.contains("private var workingStatus"))
        XCTAssertTrue(source.contains("AgentChatTranscriptChrome.displayUserLine("))
    }

    func test_isImagePath_preservesNSStringPathExtensionForLeadingDotBasenames() {
        // WHY: Foundation NSString.pathExtension treats `.png` and `foo/.png`
        // as dotfiles with no extension. The allocation-free scanner must not
        // classify them as images, while photo.PNG and ordinary multi-dot
        // names keep case-insensitive extension behavior.
        XCTAssertFalse(
            AgentChatTranscriptChrome.isImagePath(".png"),
            ".png is a leading-dot basename with no extension — not an image"
        )
        XCTAssertFalse(
            AgentChatTranscriptChrome.isImagePath("foo/.png"),
            "foo/.png is a leading-dot basename with no extension — not an image"
        )
        XCTAssertTrue(
            AgentChatTranscriptChrome.isImagePath("photo.PNG"),
            "photo.PNG must stay an image under case-insensitive extension matching"
        )
        XCTAssertTrue(
            AgentChatTranscriptChrome.isImagePath("archive.backup.png"),
            "ordinary multi-dot names must still use the last extension"
        )
        XCTAssertFalse(
            AgentChatTranscriptChrome.isImagePath("notes.tar.gz"),
            "a non-image last extension must not be classified as an image"
        )
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for child in view.subviews {
            if let found = firstTextView(in: child) {
                return found
            }
        }
        return nil
    }
}
