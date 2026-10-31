import XCTest
import AppKit
import SwiftUI
import CoreModel
import DesignSystemKit
@testable import Persistence
@testable import AgentRuntime
@testable import Surfaces

// MARK: - Chat chrome: hover, motion, tokens, copy, focus
//
// WHY: the Mac chat is used with a pointer hundreds of times a day. The row
// under the pointer has to answer, Reduce Motion has to remove movement and
// keep the fade, a copy has to be acknowledged where it was clicked, and the
// composer has to show when it holds the keyboard. None of that is checked by
// the compiler, so these tests pin the pure decisions and the mount sites.

private func chatChromeSource(
    _ relativePath: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

/// The source between two markers, markers included.
private func chatChromeSlice(
    _ source: String,
    from startMarker: String,
    to endMarker: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String {
    let start = try XCTUnwrap(source.range(of: startMarker), "\(startMarker) must exist", file: file, line: line)
    let end = try XCTUnwrap(
        source.range(of: endMarker, range: start.upperBound..<source.endIndex),
        "\(endMarker) must follow \(startMarker)",
        file: file, line: line
    )
    return String(source[start.lowerBound..<end.upperBound])
}

final class AgentChatHoverMotionChromeTests: XCTestCase {

    // MARK: Reduce Motion

    func test_reduceMotionKeepsTheFadeAndDropsTheMovement_becauseASlideIsRealMotion() {
        // WHY: with Reduce Motion on, a disclosure that slides in from the top
        // and a button that grows from 0.94 are the movement the setting asks
        // to remove. The fade stays so the change is still visible.
        XCTAssertEqual(AgentChatMotion.transitionKind(.fadeAndMove, reduceMotion: true), .fade)
        XCTAssertEqual(AgentChatMotion.transitionKind(.fadeAndScale, reduceMotion: true), .fade)
        XCTAssertEqual(AgentChatMotion.transitionKind(.fade, reduceMotion: true), .fade)
    }

    func test_fullMotionKeepsEachTransitionAsDesigned_becauseTheGateMustNotFlattenTheDefault() {
        XCTAssertEqual(AgentChatMotion.transitionKind(.fadeAndMove, reduceMotion: false), .fadeAndMove)
        XCTAssertEqual(AgentChatMotion.transitionKind(.fadeAndScale, reduceMotion: false), .fadeAndScale)
        XCTAssertEqual(AgentChatMotion.transitionKind(.fade, reduceMotion: false), .fade)
    }

    func test_disclosuresAndScrollButtonGoThroughTheReduceMotionHelper_becauseABareTransitionIgnoresTheSetting() throws {
        // WHY: the helper above only matters where it is mounted. A bare
        // `.transition(.opacity.combined(with: .move…))` plays for everyone.
        let surface = try chatChromeSource("Sources/Surfaces/AgentAppSurface.swift")
        let liveTurn = try chatChromeSource("Sources/Surfaces/AgentChatLiveTurnChrome.swift")
        let timeline = try chatChromeSource("Sources/Surfaces/AgentChatTimelineChrome.swift")
        for (name, source) in [("AgentAppSurface", surface), ("AgentChatLiveTurnChrome", liveTurn), ("AgentChatTimelineChrome", timeline)] {
            XCTAssertFalse(
                source.contains(".transition(.opacity.combined(with:"),
                "\(name): a transition that moves must be chosen by AgentChatMotion.transition"
            )
        }
        XCTAssertEqual(
            surface.components(separatedBy: "AgentChatMotion.transition(.fadeAndMove, reduceMotion: reduceMotion)").count - 1,
            3,
            "work log, completed work and tool group disclosures"
        )
        XCTAssertTrue(liveTurn.contains("AgentChatMotion.transition(.fadeAndMove, reduceMotion: reduceMotion)"))
        // The scroll-to-latest button stays inside the same overlay as
        // before: this scroll view has a crash history when the button
        // becomes a sibling of the ScrollView.
        let button = try chatChromeSlice(
            timeline,
            from: ".overlay(alignment: .bottomTrailing) {",
            to: ".onAppear { rejoin(proxy) }"
        )
        XCTAssertTrue(button.contains("AgentChatMotion.transition(.fadeAndScale, reduceMotion: reduceMotion)"))
        // Nothing animates the state that mounts the button, so it still pops
        // in and out. Animating this transition is held until scrolling away
        // and back during streaming has been recorded in the running app
        // without a crash; do not add it here without that recording.
        XCTAssertFalse(button.contains(".animation("), "held: needs the scroll round trip recorded first")
        XCTAssertFalse(timeline.contains("withAnimation"), "scroll state itself must stay unanimated")
    }

    func test_disclosureTogglesDoNotAnimateUnderReduceMotion_becauseTheRowsBelowWouldStillSlide() throws {
        // WHY: opening a disclosure moves every row below it. An opacity-only
        // transition does not stop that: the ambient animation still eases the
        // rows to their new place. With Reduce Motion on the toggle carries no
        // animation, so the layout changes in one frame.
        let expected = [
            // work log, completed work, tool group
            "Sources/Surfaces/AgentAppSurface.swift": 3,
            // tool group row, work so far
            "Sources/Surfaces/AgentChatLiveTurnChrome.swift": 2,
        ]
        for (path, gatedCount) in expected {
            let source = try chatChromeSource(path)
            XCTAssertFalse(
                source.contains("withAnimation(DS.Motion.micro)"),
                "\(path): a disclosure toggle must read Reduce Motion"
            )
            XCTAssertEqual(
                source.components(separatedBy: "withAnimation(reduceMotion ? nil : DS.Motion.micro)").count - 1,
                gatedCount,
                "\(path): every disclosure toggle is gated"
            )
        }
    }

    // MARK: Tokens

    func test_chatFilesUseRadiusColorAndMotionTokens_becauseLiteralsDriftFromTheDesignSystem() throws {
        // WHY: the user bubble was radius 10 by literal while iOS used a
        // token, ten tool blocks were radius 6 where the scale has 5 and 7,
        // and five disclosures used ease-in-out where the design system's
        // micro token is ease-out. A literal in these files is how that
        // drift starts again.
        let files = [
            "Sources/Surfaces/AgentChatSharedChrome.swift",
            "Sources/Surfaces/AgentChatTimelineChrome.swift",
            "Sources/Surfaces/AgentChatLiveTurnChrome.swift",
            "Sources/Surfaces/AgentChatTranscriptChrome.swift",
            "Sources/Surfaces/AgentComposerChrome.swift",
            "Sources/Surfaces/AgentComposerTextEditor.swift",
            "Sources/Surfaces/AgentAppSurface.swift",
        ]
        let numericRadius = try NSRegularExpression(pattern: #"cornerRadius:\s*[0-9]"#)
        for path in files {
            let source = try chatChromeSource(path)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            XCTAssertEqual(
                numericRadius.numberOfMatches(in: source, range: range),
                0,
                "\(path): corner radii come from DS.Radius"
            )
            XCTAssertFalse(source.contains("Color.white"), "\(path): fills come from DS.Palette")
            XCTAssertFalse(
                source.contains(".easeInOut(duration:"),
                "\(path): chat motion uses DS.Motion (ease-out)"
            )
        }
        XCTAssertEqual(DS.Radius.bubble, 10, "the user bubble keeps its radius; it only gained a name")
        let transcript = try chatChromeSource("Sources/Surfaces/AgentChatTranscriptChrome.swift")
        XCTAssertTrue(transcript.contains("RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)"))
    }

    // MARK: Copy acknowledgement

    func test_copyShowsACheckForOneAndAHalfSeconds_becauseASilentCopyLooksLikeNothingHappened() {
        XCTAssertEqual(AgentChatCopyChrome.symbolName(copied: false), "doc.on.doc")
        XCTAssertEqual(AgentChatCopyChrome.symbolName(copied: true), "checkmark")
        XCTAssertEqual(AgentChatCopyChrome.acknowledgementSeconds, 1.5)
    }

    func test_copyKeepsTheCheckUntilTheLatestCopyExpires_becauseAnOlderTimerMustNotClearANewerCheck() {
        // WHY: the check is the only answer to a copy click. It has to show,
        // it has to go away, and a second click inside the 1.5 s must get its
        // own full 1.5 s instead of losing the check to the first timer.
        var acknowledgement = AgentChatCopyAcknowledgement()
        XCTAssertFalse(acknowledgement.copied, "no check before a copy")

        let first = acknowledgement.copy()
        XCTAssertTrue(acknowledgement.copied, "a copy shows the check")
        let second = acknowledgement.copy()
        XCTAssertNotEqual(first, second)

        acknowledgement.expire(first)
        XCTAssertTrue(acknowledgement.copied, "the first copy's timer must not clear the second copy's check")
        acknowledgement.expire(second)
        XCTAssertFalse(acknowledgement.copied, "the latest copy's timer clears the check")
    }

    func test_copyIsAcknowledgedOnlyWhenThePasteboardTookIt_becauseACheckOnAFailedCopyIsAFalseSuccess() throws {
        // WHY: the check says "this is on your clipboard". The button reads
        // the pasteboard's own answer before it shows it.
        let shared = try chatChromeSource("Sources/Surfaces/AgentChatSharedChrome.swift")
        let button = try chatChromeSlice(
            shared,
            from: "public struct AgentChatCopyButton<Label: View>: View {",
            to: ".buttonStyle(.plain)"
        )
        XCTAssertTrue(button.contains("guard AgentChatTranscriptChrome.copyToPasteboard(text) else { return }"))
        XCTAssertTrue(button.contains("acknowledgement.expire(generation)"))
        let transcript = try chatChromeSource("Sources/Surfaces/AgentChatTranscriptChrome.swift")
        let copy = try chatChromeSlice(
            transcript,
            from: "public static func copyToPasteboard(_ text: String) -> Bool {",
            to: "}"
        )
        XCTAssertTrue(copy.contains("return NSPasteboard.general.setString(text, forType: .string)"))
    }

    func test_transcriptToolRowAndStripCopyControlsMountTheSharedButton_becauseAPrivateCopyGivesNoAcknowledgement() throws {
        // WHY: the acknowledgement lives in AgentChatCopyButton. A copy control
        // that draws its own glyph and writes the pasteboard itself is silent.
        let transcript = try chatChromeSource("Sources/Surfaces/AgentChatTranscriptChrome.swift")
        let liveTurn = try chatChromeSource("Sources/Surfaces/AgentChatLiveTurnChrome.swift")
        XCTAssertEqual(
            transcript.components(separatedBy: "AgentChatCopyButton(text: text)").count - 1,
            2,
            "user bubble and assistant reply"
        )
        XCTAssertTrue(liveTurn.contains("AgentChatCopyButton(text: full)"), "tool row command copy")
        for (name, source) in [("AgentChatTranscriptChrome", transcript), ("AgentChatLiveTurnChrome", liveTurn)] {
            XCTAssertFalse(
                source.contains("Image(systemName: \"doc.on.doc\")"),
                "\(name): the glyph comes from AgentChatCopyChrome.symbolName(copied:)"
            )
        }
        let shared = try chatChromeSource("Sources/Surfaces/AgentChatSharedChrome.swift")
        let strip = try chatChromeSlice(
            shared,
            from: "public struct AgentChatErrorStrip: View",
            to: "if let onRetry {"
        )
        XCTAssertTrue(strip.contains("AgentChatCopyButton(text: message)"), "error strip Copy")
        XCTAssertTrue(strip.contains(".accessibilityIdentifier(\"\\(identifier).copy\")"))
        let surface = try chatChromeSource("Sources/Surfaces/AgentAppSurface.swift")
        XCTAssertTrue(surface.contains("AgentChatCopyButton(text: detail)"), "approval command preview")
        XCTAssertTrue(surface.contains("AgentChatCopyButton(text: full)"), "Agent App tool row")
        XCTAssertTrue(surface.contains("AgentChatCopyButton(text: item.message)"), "system strip")
        // The two strips draw the same word-and-check label from one view.
        XCTAssertTrue(strip.contains("AgentChatCopyButton(text: message) { AgentChatCopyWordLabel(copied: $0) }"))
        XCTAssertTrue(surface.contains("AgentChatCopyButton(text: item.message) { AgentChatCopyWordLabel(copied: $0) }"))
        XCTAssertFalse(surface.contains("Text(\"Copy\")"), "the label lives in AgentChatCopyWordLabel")
        // The approval card's copy has the 22pt hit frame the design system asks for.
        let approvalCopy = try chatChromeSlice(
            surface,
            from: "AgentChatCopyButton(text: detail)",
            to: ".help(\"Copy command\")"
        )
        XCTAssertTrue(approvalCopy.contains(".frame(width: 22, height: 22)"))
        XCTAssertTrue(approvalCopy.contains(".contentShape(Rectangle())"))
    }

    // MARK: Thread row

    func test_runningThreadRowUsesTheSharedSpinnerInAFixedColumn_becauseTheRosterAlreadyDoes() throws {
        // WHY: a running thread was a static 8pt glyph in the rail while the
        // Bots roster spins DSBusySpinner for the same state. The status
        // column is the spinner's 16pt box for every state, so the title does
        // not shift when a run starts or ends.
        let shared = try chatChromeSource("Sources/Surfaces/AgentChatSharedChrome.swift")
        let row = try chatChromeSlice(
            shared,
            from: "public struct AgentChatThreadRow<",
            to: "public struct AgentThreadProviderMonogram"
        )
        let running = try chatChromeSlice(row, from: "case .running:", to: "case .unread:")
        XCTAssertTrue(running.contains("DSBusySpinner("))
        XCTAssertTrue(running.contains("label: \"Running\""))
        XCTAssertTrue(
            running.contains("identifier: runningIdentifier ?? \"\\(identifier).running\""),
            "UI tests find the running mark by this identifier"
        )
        XCTAssertFalse(running.contains("arrow.triangle.2.circlepath"))
        let column = try chatChromeSlice(row, from: "statusMark\n", to: "leading\n")
        XCTAssertTrue(column.contains(".frame(width: 16, height: 16)"))
    }

    func test_stopGlyphHasATwentyTwoPointHitBox_becauseATwelvePointGlyphIsEasyToMiss() throws {
        // WHY: missing Stop selects the thread instead of stopping the run.
        let shared = try chatChromeSource("Sources/Surfaces/AgentChatSharedChrome.swift")
        let stop = try chatChromeSlice(
            shared,
            from: "private var stopControl: some View {",
            to: ".help(AgentChatThreadRowStopChrome.help)"
        )
        XCTAssertTrue(stop.contains(".frame(width: 22, height: 22)"))
        XCTAssertTrue(stop.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(
            stop.contains(".accessibilityIdentifier(stopIdentifier ?? \"\\(identifier).stop\")"),
            "UI tests find Stop by this identifier"
        )
    }

    func test_threadRowsAndCompactMenuRowsAnswerThePointer_becauseTheyHadNoHoverState() throws {
        // WHY: a selected row keeps its own fill, so the hover is enabled only
        // when the row is not selected.
        let shared = try chatChromeSource("Sources/Surfaces/AgentChatSharedChrome.swift")
        let row = try chatChromeSlice(
            shared,
            from: "public struct AgentChatThreadRow<",
            to: "private var stopControl: some View {"
        )
        XCTAssertTrue(row.contains(".dsHoverFill(enabled: !selected)"))
        let composer = try chatChromeSource("Sources/Surfaces/AgentComposerChrome.swift")
        let menuRow = try chatChromeSlice(
            composer,
            from: "public struct AgentCompactMenuRow: View",
            to: ".buttonStyle(.plain)"
        )
        XCTAssertTrue(menuRow.contains(".dsHoverFill(enabled: !selected)"))
    }

    // MARK: Error rows

    func test_errorItemsInTheSystemStripMountTheSharedErrorStrip_becauseOneErrorRowServesTheChat() throws {
        // WHY: a failed page read and a failed send were two different rows.
        // The shared strip keeps Retry and Dismiss reachable and is spoken by
        // VoiceOver when it appears. Identifiers stay `<item.id>` and
        // `<item.id>.copy/.retry/.dismiss`.
        let surface = try chatChromeSource("Sources/Surfaces/AgentAppSurface.swift")
        let row = try chatChromeSlice(
            surface,
            from: "private func systemStripRow(_ item: AgentSystemStripItem) -> some View {",
            to: "private func retrySystemStripItem(_ id: String) {"
        )
        XCTAssertTrue(row.contains("if item.severity == .error {"))
        XCTAssertTrue(row.contains("AgentChatErrorStrip("))
        XCTAssertTrue(row.contains("identifier: item.id,"))
        XCTAssertTrue(row.contains("offersCopy: item.offersCopy,"))
        XCTAssertTrue(
            row.contains("onRetry: item.offersRetry ? { retrySystemStripItem(item.id) } : nil,"),
            "an item that offers no retry must not draw one"
        )
        XCTAssertTrue(row.contains("onDismiss: item.offersDismiss ? { dismissSystemStripItem(item.id) } : nil"))
        XCTAssertTrue(row.contains("systemStripStatusRow(item)"), "warning and info rows keep their own row")
        // The failed page read is not folded into the system strip: it has no
        // dismiss, because without it the unread thread is a blank column.
        XCTAssertTrue(surface.contains("identifier: \"agent.messages.loadFailed\","))
    }

    // MARK: Composer focus

    func test_composerCardHairlineShowsEditorFocus_andLeavesTheUltracodeBorderAlone() throws {
        // WHY: the card is the field. Its hairline is the only place that can
        // show the editor holds the keyboard. While Ultracode is on, the
        // animated border owns the edge, so the hairline stays hidden as before.
        let transcript = try chatChromeSource("Sources/Surfaces/AgentChatTranscriptChrome.swift")
        let card = try chatChromeSlice(
            transcript,
            from: ".clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))",
            to: ".modifier(UltracodeBorder(active: ultracodeBorder))"
        )
        XCTAssertTrue(card.contains("AgentChatComposerFocusChrome.showsFocus("))
        XCTAssertTrue(card.contains("editorFocused: editorFocused,"))
        XCTAssertTrue(card.contains("windowIsKey: controlActiveState == .key,"))
        XCTAssertTrue(card.contains("enabled: isEnabled"))
        XCTAssertTrue(card.contains(") ? DS.Palette.focusRing : DS.Palette.line,"))
        XCTAssertTrue(card.contains("lineWidth: DS.Border.hairline"), "a thin stroke, not the 2pt keyboard ring")
        XCTAssertTrue(card.contains(".opacity(ultracodeBorder ? 0 : 1)"))
        XCTAssertTrue(transcript.contains("onFocusChanged: { editorFocused = $0 }"))
    }

    func test_composerShowsFocusOnlyWhereKeysGoNow_becauseAppKitKeepsTheFirstResponderInABackgroundWindow() {
        // WHY: a window keeps its first responder when it stops being key,
        // when a sheet covers it and when the editor is disabled. Without the
        // other two inputs, two open chat windows both show the accent
        // hairline and only one of them takes the keyboard.
        XCTAssertTrue(AgentChatComposerFocusChrome.showsFocus(editorFocused: true, windowIsKey: true, enabled: true))
        XCTAssertFalse(
            AgentChatComposerFocusChrome.showsFocus(editorFocused: true, windowIsKey: false, enabled: true),
            "a background window's composer must not look focused"
        )
        XCTAssertFalse(
            AgentChatComposerFocusChrome.showsFocus(editorFocused: true, windowIsKey: true, enabled: false),
            "a disabled editor does not take keys"
        )
        XCTAssertFalse(AgentChatComposerFocusChrome.showsFocus(editorFocused: false, windowIsKey: true, enabled: true))
    }

    @MainActor
    func test_composerEditorReportsFocusGainedAndLost_becauseTheCardStrokeFollowsIt() {
        // WHY: the stroke is only honest if the editor reports both edges.
        // A report that never says "lost" leaves the accent on a field that
        // no longer takes keys.
        let contentSize = NSSize(width: 480, height: 44)
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(container)
        let textView = PromptComposerTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(textView)
        var reports: [Bool] = []
        textView.onFocusChanged = { reports.append($0) }

        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertEqual(reports, [], "the report is hopped off the responder change, never synchronous")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(reports, [true])

        XCTAssertTrue(window.makeFirstResponder(nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(reports, [true, false])
        textView.onFocusChanged = nil
        textView.removeFromSuperview()
    }
}

// MARK: - Undo toasts float over the transcript

@MainActor
final class AgentUndoToastOverlayTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private func makeVM() throws -> AgentAppViewModel {
        let tmp = NSTemporaryDirectory() + "rc2-vm-undo-overlay-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex), .claude: FakeProviderRunner(provider: .claude)]
        )
        return AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp,
            coordinator: coord, threadRepo: threadRepo,
            messageRepo: messageRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
    }

    private struct Measurement {
        /// Frame of the first transcript row's text, in window coordinates.
        var firstRowFrame: NSRect
        /// Colour at the top edge of the transcript, above the first row.
        var topEdgeColor: NSColor
    }

    private func findTextView(_ view: NSView, containing text: String) -> NSTextView? {
        if let textView = view as? NSTextView, textView.string.contains(text) { return textView }
        for child in view.subviews {
            if let found = findTextView(child, containing: text) { return found }
        }
        return nil
    }

    private func enclosingTranscriptScrollView(of view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var current = view.superview
        while let node = current {
            if let scroll = node as? NSScrollView { best = scroll }
            current = node.superview
        }
        return best
    }

    private func measure(_ vm: AgentAppViewModel, firstRowText: String) throws -> Measurement {
        let size = NSSize(width: 1_000, height: 700)
        let root = AgentAppView(
            vm: vm,
            layout: AgentAppViewLayout(showsThreadRail: false, showsHeader: false)
        )
        .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        // Never ordered on screen: layout and drawing happen offscreen.
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(
            findTextView(hosting, containing: firstRowText),
            "the first transcript row must be mounted"
        )
        let rowFrame = textView.convert(textView.bounds, to: nil)
        let scroll = try XCTUnwrap(enclosingTranscriptScrollView(of: textView), "the row lives in the transcript scroll view")
        let scrollFrame = scroll.convert(scroll.bounds, to: hosting)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // 12pt inside the transcript's top edge and 6pt from its left edge:
        // above the first row (the column has 32pt of top padding) and inside
        // the toast's leading padding, so no glyph is under the sample.
        let topY = hosting.isFlipped ? scrollFrame.minY + 12 : hosting.bounds.height - scrollFrame.maxY + 12
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        let color = try XCTUnwrap(
            bitmap.colorAt(x: Int((scrollFrame.minX + 6) * scale), y: Int(topY * scale))
        )
        return Measurement(firstRowFrame: rowFrame, topEdgeColor: color)
    }

    func test_secondUndoToastTakesARowInsteadOfCoveringTheFirstMessage_becauseBothUndosAreStillLive() throws {
        // WHY: one toast fits in the transcript's top padding. Reverting a
        // checkpoint and deleting a thread within 10 s arms both, and a second
        // floating toast would sit on the first message or on "Load older
        // messages". Neither can be hidden: each carries an Undo that still
        // works. So the checkpoint toast takes a row while both are armed.
        XCTAssertTrue(AgentUndoToastPlacement.checkpointRevertTakesARow(threadDeletionArmed: true, checkpointRevertArmed: true))
        XCTAssertFalse(
            AgentUndoToastPlacement.checkpointRevertTakesARow(threadDeletionArmed: false, checkpointRevertArmed: true),
            "a single toast floats: it must not push the transcript"
        )
        XCTAssertFalse(AgentUndoToastPlacement.checkpointRevertTakesARow(threadDeletionArmed: true, checkpointRevertArmed: false))
        XCTAssertFalse(AgentUndoToastPlacement.checkpointRevertTakesARow(threadDeletionArmed: false, checkpointRevertArmed: false))

        let surface = try chatChromeSource("Sources/Surfaces/AgentAppSurface.swift")
        let column = try chatChromeSlice(
            surface,
            from: "private func conversationColumn(availableHeight: CGFloat) -> some View {",
            to: "backgroundAwaitBanner"
        )
        // The floating slot holds one toast at a time...
        let overlay = try chatChromeSlice(column, from: ".overlay(alignment: .top) {", to: "backgroundAwaitBanner")
        XCTAssertTrue(overlay.contains("if let undo = vm.pendingThreadDeletionUndo {"))
        XCTAssertTrue(overlay.contains("} else if let crToast = vm.pendingCheckpointRevertUndo {"))
        // ...and the other one is still mounted, above the transcript.
        let row = try chatChromeSlice(column, from: "AgentUndoToastPlacement.checkpointRevertTakesARow(", to: "TranscriptReactiveScope(")
        XCTAssertTrue(row.contains("checkpointRevertUndoBanner(crToast)"))
        // A toast that changes place is spoken once, and a toast replaced in
        // place is spoken with its new text (two-parameter onChange).
        XCTAssertTrue(surface.contains("guard announcedUndoToasts.insert(armedAt).inserted else { return }"))
        XCTAssertTrue(surface.contains(".onChange(of: undo.capturedAt) { _, _ in"))
        XCTAssertTrue(surface.contains(".onChange(of: toast.capturedAt) { _, _ in"))
    }

    func test_undoToastCoversTheTopOfTheTranscriptWithoutMovingTheFirstRow_becauseAJumpingTranscriptLosesYourPlace() async throws {
        // WHY: as rows above the transcript the undo toasts pushed every
        // message down when they appeared and let it jump back 10 seconds
        // later. They now float over the transcript's top edge, so the first
        // row is at the same Y with and without a toast.
        let vm = try makeVM()
        vm.createThread(title: "keep")
        let keep = try XCTUnwrap(vm.selectedThreadId)
        let probe = "first row probe \(UUID().uuidString.prefix(8))"
        try vm.messageRepo.append(AgentMessage(threadId: keep, role: .user, content: probe))
        vm.createThread(title: "doomed")
        let doomed = try XCTUnwrap(vm.selectedThreadId)
        vm.selectThread(keep)
        await vm.waitForSelectThreadHydrationForTesting()
        await vm.waitForMessageHistoryLoad()
        XCTAssertNil(vm.pendingThreadDeletionUndo)

        let before = try measure(vm, firstRowText: probe)

        await vm.deleteThread(doomed)
        XCTAssertEqual(vm.selectedThreadId, keep)
        await vm.waitForSelectThreadHydrationForTesting()
        await vm.waitForMessageHistoryLoad()
        let after = try measure(vm, firstRowText: probe)
        XCTAssertNotNil(
            vm.pendingThreadDeletionUndo,
            "the toast must still be armed when the second layout is measured, or this test proves nothing"
        )

        XCTAssertEqual(after.firstRowFrame.minY, before.firstRowFrame.minY, accuracy: 0.5,
                       "the first transcript row must not move when the undo toast appears")
        XCTAssertEqual(after.firstRowFrame.height, before.firstRowFrame.height, accuracy: 0.5)
        XCTAssertNotEqual(
            after.topEdgeColor,
            before.topEdgeColor,
            "the toast must be painted over the transcript's top edge; if it is not there, an equal Y proves nothing"
        )
    }
}
