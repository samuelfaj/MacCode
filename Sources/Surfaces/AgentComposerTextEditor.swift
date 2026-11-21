import AppKit
import DesignSystemKit
import SwiftUI

/// Shared Desk + Agent App prompt editor. One NSTextView owns IME, caret,
/// popup keys, file drop, and auto-height. Callers keep chrome and policy.
public struct AgentComposerTextEditor: NSViewRepresentable {
    public static let minHeight: CGFloat = 30
    public static let maxHeight: CGFloat = 132

    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    @Binding var height: CGFloat
    let focusTick: Int
    let placeholder: String
    let accessibilityIdentifier: String
    let onSend: () -> Void
    let onPreviousHistory: () -> Bool
    let onNextHistory: () -> Bool
    let onTextEdited: () -> Void
    let onFileDrop: ([String]) -> Void
    let onCursorMoved: (Int) -> Void
    let onCaretRectChanged: (CGRect) -> Void
    let popupIsOpen: () -> Bool
    let onPopupNavUp: () -> Void
    let onPopupNavDown: () -> Void
    let onPopupApply: () -> Void
    let onPopupDismiss: () -> Void
    let onFocusChanged: (Bool) -> Void

    public init(
        text: Binding<String>,
        height: Binding<CGFloat>,
        focusTick: Int,
        placeholder: String,
        accessibilityIdentifier: String,
        onSend: @escaping () -> Void,
        onPreviousHistory: @escaping () -> Bool,
        onNextHistory: @escaping () -> Bool,
        onTextEdited: @escaping () -> Void,
        onFileDrop: @escaping ([String]) -> Void,
        onCursorMoved: @escaping (Int) -> Void,
        onCaretRectChanged: @escaping (CGRect) -> Void,
        popupIsOpen: @escaping () -> Bool,
        onPopupNavUp: @escaping () -> Void,
        onPopupNavDown: @escaping () -> Void,
        onPopupApply: @escaping () -> Void,
        onPopupDismiss: @escaping () -> Void,
        onFocusChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self._text = text
        self._height = height
        self.focusTick = focusTick
        self.placeholder = placeholder
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSend = onSend
        self.onPreviousHistory = onPreviousHistory
        self.onNextHistory = onNextHistory
        self.onTextEdited = onTextEdited
        self.onFileDrop = onFileDrop
        self.onCursorMoved = onCursorMoved
        self.onCaretRectChanged = onCaretRectChanged
        self.popupIsOpen = popupIsOpen
        self.onPopupNavUp = onPopupNavUp
        self.onPopupNavDown = onPopupNavDown
        self.onPopupApply = onPopupApply
        self.onPopupDismiss = onPopupDismiss
        self.onFocusChanged = onFocusChanged
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = FilePathDropScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.onFileDrop = onFileDrop

        let textView = PromptComposerTextView()
        textView.registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.backgroundColor = .clear
        textView.textColor = DS.NS.text
        textView.insertionPointColor = DS.NS.text
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.minSize = NSSize(width: 0, height: Self.minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        // makeNSView runs inside a SwiftUI update: attach the delegate after the
        // initial text so a draft's caret is reported on the next turn, not from here.
        textView.delegate = context.coordinator
        if !text.isEmpty { context.coordinator.reportCursorAfterUpdate(of: textView, holding: text) }
        textView.onSend = onSend
        textView.onPreviousHistory = onPreviousHistory
        textView.onNextHistory = onNextHistory
        textView.onFileDrop = onFileDrop
        textView.popupIsOpen = popupIsOpen
        textView.onPopupNavUp = onPopupNavUp
        textView.onPopupNavDown = onPopupNavDown
        textView.onPopupApply = onPopupApply
        textView.onPopupDismiss = onPopupDismiss
        textView.onFocusChanged = onFocusChanged
        textView.placeholderString = placeholder
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        context.coordinator.textView = textView
        context.coordinator.recalculateHeight()
        scroll.documentView = textView
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scroll.documentView as? PromptComposerTextView else { return }
        if let dropScroll = scroll as? FilePathDropScrollView {
            dropScroll.onFileDrop = onFileDrop
        }
        textView.isEditable = isEnabled
        textView.onSend = onSend
        textView.onPreviousHistory = onPreviousHistory
        textView.onNextHistory = onNextHistory
        textView.onFileDrop = onFileDrop
        textView.popupIsOpen = popupIsOpen
        textView.onPopupNavUp = onPopupNavUp
        textView.onPopupNavDown = onPopupNavDown
        textView.onPopupApply = onPopupApply
        textView.onPopupDismiss = onPopupDismiss
        textView.onFocusChanged = onFocusChanged
        textView.placeholderString = placeholder
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        // Do not clobber an in-progress dead-key / IME composition: replacing
        // `string` while marked text is active aborts accents (ç/á/é) and CJK.
        // Also refuse external apply while the coordinator still owns an active
        // composition cycle (binding intentionally not synced mid-preedit).
        let marked = textView.hasMarkedText()
        if !marked { context.coordinator.isIMEComposing = false }
        if textView.string != text,
           PromptComposerKeyAction.shouldSyncComposerBinding(hasMarkedText: marked),
           !context.coordinator.isIMEComposing {
            context.coordinator.applyExternalText(text, to: textView)
        }
        // Perf CH-10: every unrelated SwiftUI update of this representable used
        // to force a full layoutManager.ensureLayout of the prompt. Layout is
        // only needed when external text was applied or the container width
        // changed; textDidChange keeps its single per-keystroke pass.
        if context.coordinator.needsHeightRecalculation(for: textView) {
            context.coordinator.recalculateHeight()
        }
        scroll.hasVerticalScroller = height >= Self.maxHeight
        if context.coordinator.appliedFocusTick != focusTick {
            context.coordinator.appliedFocusTick = focusTick
            DispatchQueue.main.async {
                guard let window = textView.window, window.firstResponder !== textView else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            height: $height,
            onTextEdited: onTextEdited,
            onCursorMoved: onCursorMoved,
            onCaretRectChanged: onCaretRectChanged
        )
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var height: CGFloat
        let onTextEdited: () -> Void
        let onCursorMoved: (Int) -> Void
        let onCaretRectChanged: (CGRect) -> Void
        weak var textView: PromptComposerTextView?
        var appliedFocusTick: Int?
        /// True while AppKit reports marked text (dead-key / IME preedit).
        /// Blocks SwiftUI→NSTextView applies that would abort composition.
        var isIMEComposing = false
        private var externallyAppliedText: String?
        /// True while applyExternalText moves the text and caret from updateNSView.
        private var isApplyingExternalText = false
        /// Width the last height layout ran at (perf CH-10).
        private var lastCalculatedWidth: CGFloat?
        /// Set when external text was applied and the height must be re-laid-out
        /// even at an unchanged width (perf CH-10).
        private var pendingExternalTextHeightRecalc = false
#if DEBUG
        var recalculateHeightCountForTesting = 0
#endif

        /// Whether `updateNSView` must run a layout pass: external text applied,
        /// or the container width changed since the last one (perf CH-10).
        func needsHeightRecalculation(for textView: NSTextView) -> Bool {
            if pendingExternalTextHeightRecalc { return true }
            guard let container = textView.textContainer else { return false }
            if lastCalculatedWidth == nil { return true }
            return abs(container.size.width - (lastCalculatedWidth ?? 0)) > 0.5
        }

        /// Pure gate for tests: external applies always need layout; otherwise
        /// only a width change does.
        nonisolated static func shouldRecalculateHeight(
            appliedExternalText: Bool,
            currentWidth: CGFloat,
            lastCalculatedWidth: CGFloat?
        ) -> Bool {
            if appliedExternalText { return true }
            guard let lastCalculatedWidth else { return true }
            return abs(currentWidth - lastCalculatedWidth) > 0.5
        }

        init(
            text: Binding<String>,
            height: Binding<CGFloat>,
            onTextEdited: @escaping () -> Void,
            onCursorMoved: @escaping (Int) -> Void,
            onCaretRectChanged: @escaping (CGRect) -> Void
        ) {
            _text = text
            _height = height
            self.onTextEdited = onTextEdited
            self.onCursorMoved = onCursorMoved
            self.onCaretRectChanged = onCaretRectChanged
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let marked = textView.hasMarkedText()
            isIMEComposing = marked
            // Hold the SwiftUI binding during preedit. Pushing marked/partial
            // strings re-enters updateNSView and can wipe á/é/í composition.
            guard PromptComposerKeyAction.shouldSyncComposerBinding(hasMarkedText: marked) else {
                textView.needsDisplay = true
                recalculateHeight()
                return
            }
            text = textView.string
            if textView.string == externallyAppliedText {
                externallyAppliedText = nil
            } else {
                onTextEdited()
            }
            textView.needsDisplay = true
            recalculateHeight()
            reportCursor(for: textView)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let marked = textView.hasMarkedText()
            isIMEComposing = marked
            guard PromptComposerKeyAction.shouldSyncComposerBinding(hasMarkedText: marked) else { return }
            guard !isApplyingExternalText else { return }
            // AppKit posts this while an edit is still being applied, before
            // textDidChange copies it into the binding. Publishing the caret then
            // can re-render SwiftUI synchronously, and updateNSView would push the
            // stale binding back into the view mid-edit (lost keystroke,
            // NSRangeException). textDidChange reports the caret once in sync.
            guard textView.string == text else { return }
            reportCursor(for: textView)
        }

        private func reportCursor(for textView: NSTextView) {
            let offset = textView.selectedRange().location
            onCursorMoved(offset)
            onCaretRectChanged(caretRect(for: textView, insertionUTF16: offset))
        }

        private func caretRect(for textView: NSTextView, insertionUTF16: Int) -> CGRect {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else {
                return CGRect(origin: textView.textContainerOrigin, size: .zero)
            }
            let origin = textView.textContainerOrigin
            let length = (textView.string as NSString).length
            let location = max(0, min(insertionUTF16, length))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: location, length: 0),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            if rect.isEmpty, location > 0 {
                let priorGlyphs = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: location - 1, length: 1),
                    actualCharacterRange: nil
                )
                let prior = layoutManager.boundingRect(forGlyphRange: priorGlyphs, in: container)
                if !prior.isEmpty {
                    rect = CGRect(x: prior.maxX, y: prior.minY, width: 0, height: prior.height)
                }
            }
            if rect.isEmpty {
                rect = CGRect(x: 0, y: 0, width: 0, height: textView.font?.pointSize ?? 13)
            }
            return rect.offsetBy(dx: origin.x, dy: origin.y)
        }

        func applyExternalText(_ value: String, to textView: NSTextView) {
            guard PromptComposerKeyAction.shouldSyncComposerBinding(hasMarkedText: textView.hasMarkedText()) else { return }
            isIMEComposing = false
            externallyAppliedText = value
            isApplyingExternalText = true
            textView.string = value
            let endOffset = (value as NSString).length
            textView.setSelectedRange(NSRange(location: endOffset, length: 0))
            isApplyingExternalText = false
            pendingExternalTextHeightRecalc = true
            reportCursorAfterUpdate(of: textView, holding: value)
        }

        /// Publishing the caret from makeNSView/updateNSView is a SwiftUI state
        /// change during a view update. Report it on the next turn instead,
        /// unless the text changed since: an edit reports its own caret, and
        /// IME preedit reports nothing until it commits.
        func reportCursorAfterUpdate(of textView: NSTextView, holding value: String) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, textView.string == value else { return }
                self.reportCursor(for: textView)
            }
        }

        func recalculateHeight() {
            guard let textView else { return }
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
#if DEBUG
            recalculateHeightCountForTesting += 1
#endif
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let next = min(AgentComposerTextEditor.maxHeight,
                           max(AgentComposerTextEditor.minHeight, ceil(used + textView.textContainerInset.height * 2)))
            lastCalculatedWidth = container.size.width
            pendingExternalTextHeightRecalc = false
            if abs(height - next) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    self?.height = next
                }
            }
        }
    }
}

final class PromptComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPreviousHistory: (() -> Bool)?
    var onNextHistory: (() -> Bool)?
    var onFileDrop: (([String]) -> Void)?
    var popupIsOpen: (() -> Bool)?
    var onPopupNavUp: (() -> Void)?
    var onPopupNavDown: (() -> Void)?
    var onPopupApply: (() -> Void)?
    var onPopupDismiss: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { reportFocus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { reportFocus(false) }
        return resigned
    }

    /// Hopped: a responder change can land inside a SwiftUI update, and the
    /// callback writes view state.
    private func reportFocus(_ focused: Bool) {
        guard let onFocusChanged else { return }
        DispatchQueue.main.async { onFocusChanged(focused) }
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }

        if PromptComposerKeyAction.shouldInterpretTextInput(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.characters
        ) {
            interpretKeyEvents([event])
            return
        }

        let open = popupIsOpen?() ?? false
        let resolution = PromptComposerKeyAction.resolve(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            popupOpen: open
        )
        switch resolution {
        case .navUp:
            onPopupNavUp?()
        case .navDown:
            onPopupNavDown?()
        case .applySelected:
            onPopupApply?()
        case .dismissPopup:
            onPopupDismiss?()
        case .passthrough(let action):
            switch action {
            case .send:
                onSend?()
            case .insertNewline:
                insertNewlineIgnoringFieldEditor(self)
            case .previousHistory:
                if onPreviousHistory?() != true { super.keyDown(with: event) }
            case .nextHistory:
                if onNextHistory?() != true { super.keyDown(with: event) }
            case .ignore:
                super.keyDown(with: event)
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return super.performDragOperation(sender) }
        onFileDrop?(paths)
        return true
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard isEditable else { return false }
        let paths = DroppedFilePaths.paths(from: pasteboard)
        guard !paths.isEmpty else { return super.readSelection(from: pasteboard, type: type) }
        onFileDrop?(paths)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: DS.NS.textTertiary
        ]
        placeholderString.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }
}
