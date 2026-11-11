import AppKit
import CoreModel
import DesignSystemKit
import Surfaces
import SwiftUI

extension AppCommandRouter {
    /// The live text of the terminal behind an Activity item; nil once its tab is gone.
    func activityTerminalSnapshot(_ item: ActivityWireItem) -> TerminalTextSnapshot? {
        guard let surfaceID = item.surface_id.flatMap(UUID.init(uuidString:)).map(SurfaceID.init),
              let terminal = SurfaceRegistry.shared.surface(surfaceID) as? TerminalRuntimeRoutingSurface else { return nil }
        return terminal.routedTextSnapshot()
    }
}

/// Activity's right pane for a terminal run: its output, mirrored read-only and refreshed while shown.
/// Input stays in the real terminal tab ("Open terminal").
struct ActivityTerminalView: View {
    let initial: TerminalTextSnapshot
    let read: () -> TerminalTextSnapshot?

    @State private var snapshot: TerminalTextSnapshot?

    var body: some View {
        ActivityTerminalText(snapshot: snapshot ?? initial)
            .background(Color(nsColor: DS.NS.terminalBG))
            .accessibilityIdentifier("activity.terminal")
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let next = read(), next.ansiText != (snapshot ?? initial).ansiText || next.text != (snapshot ?? initial).text {
                        snapshot = next
                    }
                }
            }
    }
}

private struct ActivityTerminalText: NSViewRepresentable {
    let snapshot: TerminalTextSnapshot

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.isHorizontallyResizable = true
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainerInset = NSSize(width: DS.Space.lg, height: DS.Space.lg)
            text.setAccessibilityLabel(L("Terminal output"))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView,
              context.coordinator.rendered != snapshot else { return }
        context.coordinator.rendered = snapshot
        let clip = scroll.contentView
        let wasAtBottom = clip.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 24
        text.textStorage?.setAttributedString(Self.attributed(snapshot))
        if wasAtBottom { text.scrollToEndOfDocument(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var rendered: TerminalTextSnapshot? }

    /// Replays the snapshot's styled text through the ANSI renderer; plain text when it carries no styling.
    static func attributed(_ snapshot: TerminalTextSnapshot) -> NSAttributedString {
        let font = DS.NS.terminalFont()
        guard let ansi = snapshot.ansiText, !ansi.isEmpty else {
            return NSAttributedString(string: snapshot.text.trimmingTrailingBlankLines(), attributes: [
                .font: font, .foregroundColor: DS.NS.terminalFG,
            ])
        }
        let longest = ansi.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0
        let renderer = ANSIRenderer(rows: 40, cols: max(snapshot.cols, longest, 1))
        renderer.showCursor = false
        renderer.feed(Data(ansi.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        let rendered = NSMutableAttributedString(attributedString: renderer.snapshot())
        while rendered.string.last?.isNewline == true || rendered.string.last == " " {
            rendered.deleteCharacters(in: NSRange(location: rendered.length - 1, length: 1))
        }
        return rendered
    }
}

private extension String {
    func trimmingTrailingBlankLines() -> String {
        var copy = self
        while copy.last?.isWhitespace == true { copy.removeLast() }
        return copy
    }
}
