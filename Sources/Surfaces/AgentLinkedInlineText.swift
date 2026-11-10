import CoreModel
import AppKit
import SwiftUI
import DesignSystemKit

// MARK: - Pointing-hand cursor for split-opening controls

extension View {
    /// Show the pointing-hand cursor while the pointer is over this control.
    ///
    /// WHY: SwiftUI `.plain` buttons keep the default arrow on macOS 14. AppKit
    /// cursor rects need hit-testing, so a transparent overlay steals clicks;
    /// `NSCursor.push/pop` on hover matches Pet / Ghostty patterns and does not
    /// intercept mouse-down. Use only on discrete controls (not large text blocks).
    func dsPointingHandCursor() -> some View {
        modifier(DSPointingHandCursorModifier())
    }
}

private struct DSPointingHandCursorModifier: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                guard !pushed else { return }
                NSCursor.pointingHand.push()
                pushed = true
            } else if pushed {
                NSCursor.pop()
                pushed = false
            }
        }
        .onDisappear {
            if pushed {
                NSCursor.pop()
                pushed = false
            }
        }
    }
}

// MARK: - Selectable linked transcript text (AppKit)

/// Selectable attributed transcript text where **link runs use the pointing-hand cursor**.
///
/// WHY: SwiftUI `Text(AttributedString)` + `.textSelection(.enabled)` renders
/// `.link` runs with accent color/underline but keeps the I-beam over them on
/// macOS 14. AppKit `NSTextView.linkTextAttributes` defaults include
/// `NSCursor.pointingHand` (Apple docs) and `textView(_:clickedOnLink:at:)` routes
/// clicks through the same `openURL` environment used for open-in-split.
struct AgentLinkedInlineText: View {
    let text: String
    var fontSize: CGFloat = 13
    var fontWeight: NSFont.Weight = .regular
    var monospaced: Bool = false
    var textColor: NSColor = DS.NS.text
    var lineFragmentPadding: CGFloat = 0
    /// Extra spacing between lines (points), matching SwiftUI `.lineSpacing`.
    var lineSpacing: CGFloat = 0
    /// When false, skip NSCache store for live streaming partials (R4-B).
    var cacheResults: Bool = true

    var body: some View {
        // AA-28/AA-32: ONE UTF-8 hash of the source text per body pass serves
        // both the inline cache key and the text view's content identity (which
        // lets it skip the grapheme count + AttributedString deep-equality).
        let fingerprint = AgentMessageMarkdown.sourceFingerprint(for: text)
        AgentLinkedAttributedText(
            attributed: AgentMessageMarkdown.attributedInline(text, cache: cacheResults, fingerprint: fingerprint),
            font: Self.nsFont(size: fontSize, weight: fontWeight, monospaced: monospaced),
            textColor: textColor,
            lineFragmentPadding: lineFragmentPadding,
            lineSpacing: lineSpacing,
            sourceFingerprint: fingerprint
        )
    }

    static func nsFont(size: CGFloat, weight: NSFont.Weight, monospaced: Bool) -> NSFont {
        if monospaced {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}

public struct AgentSelectablePlainText: View {
    let text: String
    var fontSize: CGFloat = 13
    var fontWeight: NSFont.Weight = .regular
    var monospaced: Bool = false
    var textColor: NSColor = DS.NS.text
    var lineSpacing: CGFloat = 0
    var maximumNumberOfLines: Int? = nil

    public init(
        text: String,
        fontSize: CGFloat = 13,
        fontWeight: NSFont.Weight = .regular,
        monospaced: Bool = false,
        textColor: NSColor = DS.NS.text,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.monospaced = monospaced
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
    }

    public var body: some View {
        AgentLinkedAttributedText(
            attributed: AttributedString(text),
            font: AgentLinkedInlineText.nsFont(size: fontSize, weight: fontWeight, monospaced: monospaced),
            textColor: textColor,
            lineFragmentPadding: 0,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines
        )
    }
}

struct AgentLinkedAttributedText: View {
    let attributed: AttributedString
    let font: NSFont
    let textColor: NSColor
    let lineFragmentPadding: CGFloat
    let lineSpacing: CGFloat
    var maximumNumberOfLines: Int? = nil
    /// Optional content identity of `attributed`'s source (AA-28). When set,
    /// equal fingerprints mean equal content and the representable skips the
    /// O(text) `AttributedString` comparison on every layout pass.
    var sourceFingerprint: Int? = nil

    @Environment(\.openURL) private var openURL

    var body: some View {
        AgentLinkedInlineTextRepresentable(
            attributed: attributed,
            font: font,
            textColor: textColor,
            lineFragmentPadding: lineFragmentPadding,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            sourceFingerprint: sourceFingerprint,
            openURL: openURL
        )
    }
}

/// Last presentation applied to an `NSTextView` for a linked transcript cell.
///
/// WHY: SwiftUI re-calls `updateNSView` for every parent body refresh (e.g. one
/// streaming token). Rebuilding `NSAttributedString` for every stable older row
/// saturates the main thread. Cache the full semantic presentation so equal
/// rows skip conversion and layout; plain-string fingerprints are insufficient
/// because identical characters can carry different link destinations.
struct AgentLinkedInlineTextAppliedState {
    let attributed: AttributedString
    let font: NSFont
    let textColor: NSColor
    let lineSpacing: CGFloat
    let maximumNumberOfLines: Int?
    let lineFragmentPadding: CGFloat
    let sourceFingerprint: Int
    /// True when `sourceFingerprint` hashes the source CONTENT (AA-28), not
    /// just its length; only then may equal fingerprints skip the deep compare.
    let contentFingerprinted: Bool

    init(
        attributed: AttributedString,
        font: NSFont,
        textColor: NSColor,
        lineSpacing: CGFloat,
        maximumNumberOfLines: Int?,
        lineFragmentPadding: CGFloat,
        sourceFingerprint: Int = 0,
        contentFingerprinted: Bool = false
    ) {
        self.attributed = attributed
        self.font = font
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
        self.lineFragmentPadding = lineFragmentPadding
        self.sourceFingerprint = sourceFingerprint
        self.contentFingerprinted = contentFingerprinted
    }
}

/// Pure dirty-flag plan for transcript text updates (test seam).
struct AgentLinkedInlineTextUpdatePlan: Equatable {
    let storageDirty: Bool
    let heightDirty: Bool
    let maximumNumberOfLinesDirty: Bool
    let lineFragmentPaddingDirty: Bool

    var isNoOp: Bool {
        !storageDirty && !heightDirty && !maximumNumberOfLinesDirty && !lineFragmentPaddingDirty
    }

    /// Compare previous applied state to the next presentation.
    ///
    /// - storageDirty: rebuild attributed storage (text, font, color, line spacing).
    /// - heightDirty: intrinsic height / layout may change (not color-only).
    static func make(
        previous: AgentLinkedInlineTextAppliedState?,
        next: AgentLinkedInlineTextAppliedState
    ) -> AgentLinkedInlineTextUpdatePlan {
        guard let previous else {
            return AgentLinkedInlineTextUpdatePlan(
                storageDirty: true,
                heightDirty: true,
                maximumNumberOfLinesDirty: true,
                lineFragmentPaddingDirty: true
            )
        }
        // AA-28: with content fingerprints on both sides, equal fingerprints ARE
        // equal content; the O(text) AttributedString compare only remains for
        // callers that did not provide one (length-only fingerprint).
        let attributedChanged = previous.sourceFingerprint != next.sourceFingerprint
            || (!(previous.contentFingerprinted && next.contentFingerprinted)
                && previous.attributed != next.attributed)
        let fontChanged = !previous.font.isEqual(next.font)
        let textColorChanged = !previous.textColor.isEqual(next.textColor)
        let lineSpacingChanged = previous.lineSpacing != next.lineSpacing
        let maximumLinesChanged = previous.maximumNumberOfLines != next.maximumNumberOfLines
        let paddingChanged = previous.lineFragmentPadding != next.lineFragmentPadding
        return AgentLinkedInlineTextUpdatePlan(
            storageDirty: attributedChanged || fontChanged || textColorChanged || lineSpacingChanged,
            heightDirty: attributedChanged || fontChanged || lineSpacingChanged
                || maximumLinesChanged || paddingChanged,
            maximumNumberOfLinesDirty: maximumLinesChanged,
            lineFragmentPaddingDirty: paddingChanged
        )
    }
}

/// Internal so unit tests can assert link runs carry pointingHand after conversion.
struct AgentLinkedInlineTextRepresentable: NSViewRepresentable {
    let attributed: AttributedString
    let font: NSFont
    let textColor: NSColor
    let lineFragmentPadding: CGFloat
    let lineSpacing: CGFloat
    var maximumNumberOfLines: Int? = nil
    var sourceFingerprint: Int? = nil
    let openURL: OpenURLAction

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL)
    }

    func makeNSView(context: Context) -> IntrinsicHeightTextView {
        let tv = IntrinsicHeightTextView(usingTextLayoutManager: false)
        // Rounded inline-code pills (see AgentMarkdownLayoutManager).
        tv.textContainer?.replaceLayoutManager(AgentMarkdownLayoutManager())
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = lineFragmentPadding
        // SwiftUI proposes a concrete column width via sizeThatFits. Tracking
        // the still-stale NSView frame fights that proposal and retriggers
        // LazyVStack placement (live freeze: 100% main thread in sizeThatFits).
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: 10_000,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.minSize = .zero
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        // macOS 14+ NSView.clipsToBounds defaults off. Without this, a stale
        // SwiftUI height lets wrapped Thinking… paint over Working for / Stop.
        tv.clipsToBounds = true
        // Apple: default linkTextAttributes are blue + underline + pointing hand.
        // Keep pointing hand even when we restyle color to the DS accent.
        tv.linkTextAttributes = [
            .foregroundColor: DS.NS.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        apply(to: tv, context: context)
        return tv
    }

    /// SwiftUI proposes a concrete width; we return the wrapped height.
    /// Measuring here (instead of `layout()` → `invalidateIntrinsicContentSize()`)
    /// is what stops LazyVStack AttributeGraph from growing without bound.
    ///
    /// Unspecified / infinite / zero proposals are the hug path. Returning a
    /// 0×N size there collapses user bubbles into a 2-glyph column.
    ///
    /// Apply the current presentation *before* measuring. Live Thinking… tokens
    /// change `attributed` while the NSTextView still holds the previous
    /// snapshot; measuring first keeps the same-width wrap cache and paints
    /// extra lines over "Working for Xs".
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: IntrinsicHeightTextView,
        context: Context
    ) -> CGSize {
        apply(to: nsView, context: context)
        return nsView.sizeThatFitsProposal(width: proposal.width)
    }

    func updateNSView(_ tv: IntrinsicHeightTextView, context: Context) {
        // Always refresh routing even when presentation is unchanged.
        context.coordinator.openURL = openURL
        context.coordinator.textView = tv
        apply(to: tv, context: context)
    }

    private func apply(to tv: IntrinsicHeightTextView, context: Context) {
        tv.clipsToBounds = true
        var hasher = Hasher()
        if let sourceFingerprint {
            hasher.combine(sourceFingerprint)
        } else {
            hasher.combine(attributed.characters.count)
        }
        hasher.combine(font.pointSize)
        hasher.combine(lineSpacing)
        hasher.combine(maximumNumberOfLines)
        hasher.combine(lineFragmentPadding)
        let next = AgentLinkedInlineTextAppliedState(
            attributed: attributed,
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            lineFragmentPadding: lineFragmentPadding,
            sourceFingerprint: hasher.finalize(),
            contentFingerprinted: sourceFingerprint != nil
        )
        let plan = AgentLinkedInlineTextUpdatePlan.make(
            previous: context.coordinator.applied,
            next: next
        )
        // WHY: Parent transcript refreshes re-enter updateNSView for every
        // mounted row. Skip conversion/layout when the cell is semantically
        // identical so only the actively streaming row pays rebuild cost.
        guard !plan.isNoOp else { return }

        if plan.maximumNumberOfLinesDirty {
            tv.textContainer?.maximumNumberOfLines = maximumNumberOfLines ?? 0
            tv.textContainer?.lineBreakMode = maximumNumberOfLines == nil
                ? .byWordWrapping
                : .byTruncatingTail
        }
        if plan.lineFragmentPaddingDirty {
            tv.textContainer?.lineFragmentPadding = lineFragmentPadding
        }
        if plan.storageDirty {
            let ns = Self.makeNSAttributedString(
                attributed: attributed,
                font: font,
                textColor: textColor,
                lineSpacing: lineSpacing
            )
            Self.applyTextStorage(ns, to: tv)
            // Typing attributes only: the `font` / `textColor` setters restyle
            // the WHOLE storage and erased heading sizes, bold, italic, code
            // fonts and quote colours that `makeNSAttributedString` resolved.
            tv.typingAttributes = [.font: font, .foregroundColor: textColor]
        }
        if plan.heightDirty {
            // Drop the fitted-size cache so the next sizeThatFits remeasures.
            // Cache reset alone is not enough: SwiftUI does not re-run
            // sizeThatFits just because updateNSView rewrote the storage, so a
            // streaming row kept its first-token frame while new glyphs
            // painted past it (Bots Desk: the working strip landed
            // mid-paragraph over the live Thinking text). Ask SwiftUI to
            // remeasure via a deferred, coalesced intrinsic-size invalidation
            // — never synchronously here: that was the pid 62995 LazyVStack
            // placement hang (100% main thread, 18 GB RSS).
            tv.resetFittedSizeCache()
            tv.scheduleIntrinsicInvalidationAfterContentChange()
        }
        context.coordinator.applied = next
    }

    static func applyTextStorage(_ next: NSAttributedString, to textView: NSTextView) {
        guard textView.textStorage?.isEqual(to: next) != true else { return }
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(next)
        let location = min(selection.location, next.length)
        let length = min(selection.length, next.length - location)
        textView.setSelectedRange(NSRange(location: location, length: length))
    }

    /// Marks inline-code runs so `AgentMarkdownLayoutManager` draws their
    /// background as a rounded pill; the value is the pill colour.
    static let inlineCodePillKey = NSAttributedString.Key("RCInlineCodePill")
    static let inlineCodeBackground = DS.NS.line.withAlphaComponent(0.85)

    /// The NSAttributedString actually handed to the NSTextView.
    ///
    /// AppKit only reads AppKit keys: a SwiftUI `.font` / `.foregroundColor`
    /// set on the AttributedString is stored under "SwiftUI.*" and ignored,
    /// and Foundation's markdown only records bold / italic / code /
    /// strikethrough as `inlinePresentationIntent`. Resolve both here, against
    /// each run's own font (body, heading or table cell), so the text view
    /// really draws them.
    static func makeNSAttributedString(
        attributed: AttributedString,
        font: NSFont,
        textColor: NSColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let converted = (try? NSAttributedString(attributed, including: \.agentMarkdown)) ?? NSAttributedString(attributed)
        let base = NSMutableAttributedString(attributedString: converted)
        let full = NSRange(location: 0, length: base.length)
        if full.length > 0 {
            // Apply base typography without clobbering existing link attributes.
            base.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                var next = attrs
                let intent = (next[.inlinePresentationIntent] as? NSNumber)
                    .map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
                let runFont = (next[.font] as? NSFont) ?? font
                next[.font] = intent.isEmpty ? runFont : Self.styledFont(runFont, intent: intent)
                if intent.contains(.code) {
                    next[.backgroundColor] = inlineCodeBackground
                    next[inlineCodePillKey] = inlineCodeBackground
                }
                if intent.contains(.strikethrough) {
                    next[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if next[.foregroundColor] == nil, next[.link] == nil {
                    next[.foregroundColor] = textColor
                }
                if lineSpacing > 0 {
                    let para = (next[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                        ?? NSMutableParagraphStyle()
                    para.lineSpacing = lineSpacing
                    next[.paragraphStyle] = para
                }
                // Ensure every link run carries the pointing-hand cursor attribute
                // even if conversion dropped temporary link attributes.
                if next[.link] != nil {
                    next[.cursor] = NSCursor.pointingHand
                    next[.foregroundColor] = DS.NS.accent
                    next[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                base.setAttributes(next, range: range)
            }
        }
        return base
    }

    /// Bold / italic as font traits of `font`; code switches to the monospaced
    /// system font a step smaller so it sits on the same x-height.
    static func styledFont(_ font: NSFont, intent: InlinePresentationIntent) -> NSFont {
        var result = font
        if intent.contains(.code) {
            let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            result = NSFont.monospacedSystemFont(ofSize: max(9, (font.pointSize * 0.9).rounded()), weight: bold ? .semibold : .regular)
        }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
        if intent.contains(.emphasized) { traits.insert(.italic) }
        if !traits.isEmpty {
            let descriptor = result.fontDescriptor.withSymbolicTraits(result.fontDescriptor.symbolicTraits.union(traits))
            result = NSFont(descriptor: descriptor, size: result.pointSize) ?? result
        }
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction
        weak var textView: NSTextView?
        /// Last presentation successfully applied to this view's storage/layout.
        var applied: AgentLinkedInlineTextAppliedState?

        init(openURL: OpenURLAction) {
            self.openURL = openURL
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let u = link as? URL {
                url = u
            } else if let s = link as? String {
                url = URL(string: s)
            } else {
                url = nil
            }
            guard let url else { return false }
            // Route through the same OpenURLAction as SwiftUI Text links so
            // AgentAppView's open-in-split handler stays in charge.
            _ = openURL(url)
            return true
        }
    }
}

/// NSTextView that reports vertical intrinsic size for SwiftUI layout.
final class IntrinsicHeightTextView: NSTextView {
    private(set) var intrinsicInvalidationCountForTesting = 0
    private var measuringProposedWidth = false
    private var lastFittedWidth: CGFloat = 0
    private var lastFittedSize: CGSize = .zero
    private var pendingContentChangeInvalidation = false

    /// Ask SwiftUI to re-run `sizeThatFits` after a content change, outside
    /// the current SwiftUI transaction.
    ///
    /// WHY: updating the text storage repaints the NSTextView but SwiftUI
    /// keeps the frame from the last measure — a live streaming row stayed one
    /// line tall while its glyphs painted far past the frame, so the rows laid
    /// out after it (Bots Desk working strip) landed mid-paragraph. A
    /// synchronous invalidate inside apply()/updateNSView is forbidden — that
    /// re-entered LazyVStack placement (pid 62995 hang) — so defer to the next
    /// runloop turn and coalesce bursts of streaming tokens into one
    /// invalidation.
    func scheduleIntrinsicInvalidationAfterContentChange() {
        guard !pendingContentChangeInvalidation else { return }
        pendingContentChangeInvalidation = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingContentChangeInvalidation = false
            self.invalidateIntrinsicContentSize()
        }
    }

    override func invalidateIntrinsicContentSize() {
        resetFittedSizeCache()
        intrinsicInvalidationCountForTesting += 1
        super.invalidateIntrinsicContentSize()
    }

    /// Clear wrap-height cache without asking SwiftUI to relayout the graph.
    func resetFittedSizeCache() {
        lastFittedWidth = 0
        lastFittedSize = .zero
    }

    override var intrinsicContentSize: NSSize {
        if lastFittedSize.height > 0 {
            return NSSize(width: NSView.noIntrinsicMetric, height: lastFittedSize.height)
        }
        let fitted = sizeThatFitsWidth(bounds.width)
        return NSSize(width: NSView.noIntrinsicMetric, height: fitted.height)
    }

    /// Map a SwiftUI width proposal onto wrap vs hug.
    /// Concrete column widths wrap; nil / 0 / non-finite / huge values hug.
    func sizeThatFitsProposal(width: CGFloat?) -> CGSize {
        if let width, Self.wrappingWidth(width) != nil {
            return sizeThatFitsWidth(width)
        }
        return sizeThatFitsIdeal()
    }

    /// Unwrapped used size. Unspecified SwiftUI proposals and user-bubble
    /// hug sizing ask for this. Must not return width 0 — that is the
    /// collapsed "Go / Gr" screenshot.
    func sizeThatFitsIdeal() -> CGSize {
        let fallback = font?.boundingRectForFont.height ?? 14
        guard let layoutManager, let textContainer else {
            return CGSize(width: 0, height: fallback)
        }
        let probe: CGFloat = 10_000
        let saved = textContainer.containerSize
        measuringProposedWidth = true
        defer {
            measuringProposedWidth = false
            textContainer.containerSize = saved
        }
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.containerSize = NSSize(
            width: probe,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        // usedRect includes the insertion-point extra line fragment, which is
        // the full container width (10_000). Glyph bounds are the hug width.
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let used = glyphRange.length == 0
            ? .zero
            : layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return CGSize(
            width: max(ceil(used.width + textContainerInset.width * 2), 0),
            height: max(ceil(used.height + textContainerInset.height * 2), fallback)
        )
    }

    /// Same layout engine as the live NSTextView, without mounting a view.
    private final class IdealSizeBox { let value: CGSize; init(_ v: CGSize) { value = v } }
    /// Perf CH-02: user-bubble hug measurement allocates NSTextStorage +
    /// NSLayoutManager and ensureLayouts the WHOLE prompt; it used to run on
    /// every bubble body pass. Cached per (font, padding, source fingerprint)
    /// so long prompts are not duplicated as NSCache keys.
    private static let idealSizeCache: NSCache<NSString, IdealSizeBox> = {
        let cache = NSCache<NSString, IdealSizeBox>()
        cache.countLimit = 128
        cache.totalCostLimit = 1_024 * 1_024
        return cache
    }()
    #if DEBUG
    nonisolated(unsafe) static var idealSizeComputeCountForTesting = 0
    #endif

    static func idealSize(
        string: String,
        font: NSFont,
        lineFragmentPadding: CGFloat = 0
    ) -> CGSize {
        let fingerprint = AgentMessageMarkdown.sourceFingerprint(for: string)
        let key = "\(font.fontName)|\(font.pointSize)|\(lineFragmentPadding)|\(fingerprint)" as NSString
        if let cached = idealSizeCache.object(forKey: key) { return cached.value }
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = lineFragmentPadding
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let fallback = font.boundingRectForFont.height
        let result = CGSize(
            width: max(ceil(used.width), 0),
            height: max(ceil(used.height), fallback)
        )
        idealSizeCache.setObject(IdealSizeBox(result), forKey: key, cost: max(1, string.utf8.count))
        #if DEBUG
        idealSizeComputeCountForTesting &+= 1
        #endif
        return result
    }

    func sizeThatFitsWidth(_ width: CGFloat) -> CGSize {
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        let fallback = font?.boundingRectForFont.height ?? 14
        let target = Self.wrappingWidth(width)
            ?? Self.wrappingWidth(bounds.width)
            ?? Self.wrappingWidth(lastFittedWidth)
        guard let target else {
            return sizeThatFitsIdeal()
        }
        if abs(lastFittedWidth - target) <= 0.5, lastFittedSize.height > 0 {
            return lastFittedSize
        }
        guard let layoutManager, let textContainer else {
            return CGSize(width: target, height: fallback)
        }
        measuringProposedWidth = true
        defer { measuringProposedWidth = false }
        applyContainerWidth(target)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = max(ceil(used.height + textContainerInset.height * 2), fallback)
        let size = CGSize(width: target, height: height)
        lastFittedWidth = target
        lastFittedSize = size
        return size
    }

    override func layout() {
        super.layout()
        // Track the laid-out width only. Do not invalidate here, and do not
        // overwrite a sizeThatFits proposal with the still-stale frame:
        // LazyVStack placement calls sizeThatFits, then layout, and a
        // bounds-width clobber retriggers placement (live sample: 100% main
        // thread, growing AttributeGraph RSS on ChatFlowRow + AgentLinkedInlineText).
        guard !measuringProposedWidth else { return }
        let width = bounds.width
        guard Self.wrappingWidth(width) != nil else { return }
        applyContainerWidth(width)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    private static func wrappingWidth(_ width: CGFloat) -> CGFloat? {
        guard width.isFinite, width > 0, width < 1_000_000 else { return nil }
        return width
    }

    private func applyContainerWidth(_ width: CGFloat) {
        guard let textContainer else { return }
        let target = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if abs(textContainer.containerSize.width - width) > 0.5 {
            textContainer.containerSize = target
            if abs(lastFittedWidth - width) > 0.5 {
                lastFittedWidth = 0
                lastFittedSize = .zero
            }
        }
    }
}

/// TextKit 1 layout manager that paints inline-code backgrounds as rounded
/// pills sized to the code font (not the whole line fragment, which also
/// covers the paragraph's line spacing).
final class AgentMarkdownLayoutManager: NSLayoutManager {
    static let quoteDepthKey = NSAttributedString.Key(AgentMarkdownQuoteDepthAttribute.name)
    static let quoteBarWidth: CGFloat = 3

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawQuoteBars(forGlyphRange: glyphsToShow, at: origin)
    }

    /// One continuous bar per quote level over each run of quoted lines.
    private func drawQuoteBars(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        var lines: [(depth: Int, used: NSRect)] = []
        var maxDepth = 0
        enumerateLineFragments(forGlyphRange: glyphsToShow) { _, used, _, glyphRange, _ in
            let character = self.characterIndexForGlyph(at: glyphRange.location)
            let depth = character < storage.length
                ? (storage.attribute(Self.quoteDepthKey, at: character, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
                : 0
            maxDepth = max(maxDepth, depth)
            lines.append((depth, used))
        }
        guard maxDepth > 0 else { return }
        DS.NS.accent.withAlphaComponent(0.45).setFill()
        for level in 1...maxDepth {
            var start: NSRect?
            var end: NSRect = .zero
            func flush() {
                guard let top = start else { return }
                let x = origin.x + CGFloat(level - 1) * AgentMessageMarkdown.quoteIndentStep
                let bar = NSRect(x: x, y: origin.y + top.minY, width: Self.quoteBarWidth, height: end.maxY - top.minY)
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
                start = nil
            }
            for line in lines {
                if line.depth >= level {
                    if start == nil { start = line.used }
                    end = line.used
                } else {
                    flush()
                }
            }
            flush()
        }
    }

    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        guard let storage = textStorage, charRange.location < storage.length,
              let pill = storage.attribute(
                AgentLinkedInlineTextRepresentable.inlineCodePillKey,
                at: charRange.location,
                effectiveRange: nil
              ) as? NSColor,
              pill.isEqual(color),
              let container = textContainers.first else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont
            ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let path = NSBezierPath()
        for index in 0..<rectCount {
            let rect = rectArray[index]
            var pillRect = rect.insetBy(dx: -2, dy: 0)
            let glyph = glyphIndex(for: NSPoint(x: rect.midX, y: rect.midY), in: container)
            if glyph < numberOfGlyphs {
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = line.minY + location(forGlyphAt: glyph).y
                let top = baseline - font.ascender - 1.5
                let bottom = baseline - font.descender + 1.5
                pillRect.origin.y = top
                pillRect.size.height = bottom - top
            }
            path.append(NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4))
        }
        color.setFill()
        path.fill()
    }
}
