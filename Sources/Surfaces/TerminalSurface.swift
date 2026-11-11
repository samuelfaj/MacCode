import Foundation
import AppKit
import Darwin
import Carbon.HIToolbox
import CoreModel
import Persistence
import RemoteCodeCSystem
import DesignSystemKit
import os

private let terminalLog = Logger(subsystem: "io.remotecode.surfaces", category: "terminal")

/// An NSTextView that behaves like a real terminal: every keystroke is
/// translated to bytes and written straight to the pty (via `onKey`),
/// nothing is edited locally — the shell echoes back through the read
/// loop. Selection + ⌘C copy still work; ⌘V pastes into the pty.
@MainActor
final class TerminalTextView: NSTextView {
    var onKey: ((Data) -> Void)?
    /// Called when a paste is classified as requiring confirmation.
    /// The receiver should present a sheet and, on confirmation, call
    /// `onKey` with the text encoded as UTF-8.
    var onPasteNeedsConfirm: ((String) -> Void)?

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hideAppKitCaret()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        hideAppKitCaret()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        hideAppKitCaret()
    }

    private func hideAppKitCaret() {
        // The PTY cursor is drawn into the attributed terminal buffer by
        // ANSIRenderer. Hiding AppKit's caret prevents a second cursor
        // from appearing when the text view is first responder.
        insertionPointColor = .clear
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if TerminalKeyboardInput.shouldUseTextInput(for: event) {
            if let text = TerminalKeyboardInput.literalShellText(for: event),
               let data = text.data(using: .utf8) {
                onKey?(data)
                return
            }
            interpretKeyEvents([event])
            return
        }
        guard let bytes = TerminalTextView.encode(event) else { return }
        onKey?(bytes)
    }

    // Forward direct text insertions (including AppKit text drops) to the pty;
    // the shell still owns the rendered buffer through the read loop.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String?
        if let string = string as? String {
            text = string
        } else if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else {
            text = nil
        }
        guard let text, let data = text.data(using: .utf8) else { return }
        onKey?(data)
    }
    override func doCommand(by selector: Selector) {}

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return super.performDragOperation(sender) }
        guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return false }
        onKey?(data)
        return true
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let paths = DroppedFilePaths.paths(from: pasteboard)
        guard !paths.isEmpty else { return super.readSelection(from: pasteboard, type: type) }
        guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return false }
        onKey?(data)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c":
                if selectedRange().length > 0 { copy(nil); return true }
                return false
            case "v":
                let s = NSPasteboard.general.string(forType: .string) ?? ""
                switch PasteGuard.classify(s) {
                case .safe:
                    if let d = s.data(using: .utf8) { onKey?(d) }
                case .needsConfirm:
                    onPasteNeedsConfirm?(s)
                }
                return true
            case "a", "x": // select-all / cut-as-copy fall through to default copy
                return super.performKeyEquivalent(with: event)
            default:
                return super.performKeyEquivalent(with: event)
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Map an NSEvent to the byte sequence a VT100/xterm app expects.
    static func encode(_ event: NSEvent) -> Data? {
        let flags = event.modifierFlags
        let ctrl = flags.contains(.control)
        let opt = flags.contains(.option)

        // Special keys by keyCode.
        switch event.keyCode {
        case 36, 76: return Data([0x0D])              // Return / Enter → CR
        case 48:     return Data([0x09])              // Tab
        case 51:     return Data([0x7F])              // Delete (backspace)
        case 117:    return Data([0x1B, 0x5B, 0x33, 0x7E]) // Forward delete ESC[3~
        case 53:     return Data([0x1B])              // Esc
        case 126:    return Data([0x1B, 0x5B, 0x41])  // Up
        case 125:    return Data([0x1B, 0x5B, 0x42])  // Down
        case 124:    return Data([0x1B, 0x5B, 0x43])  // Right
        case 123:    return Data([0x1B, 0x5B, 0x44])  // Left
        case 115:    return Data([0x1B, 0x5B, 0x48])  // Home
        case 119:    return Data([0x1B, 0x5B, 0x46])  // End
        case 116:    return Data([0x1B, 0x5B, 0x35, 0x7E]) // Page Up
        case 121:    return Data([0x1B, 0x5B, 0x36, 0x7E]) // Page Down
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }

        if ctrl, let scalar = chars.unicodeScalars.first {
            let v = scalar.value
            // Ctrl-A..Ctrl-Z and friends → 0x01..0x1A etc.
            if v >= 0x40 && v < 0x80 {
                return Data([UInt8(v & 0x1F)])
            }
            if scalar == " " { return Data([0x00]) } // Ctrl-Space → NUL
        }

        let text = event.characters ?? chars
        guard var data = text.data(using: .utf8) else { return nil }
        if opt { // Option as Meta: prefix ESC
            data.insert(0x1B, at: data.startIndex)
        }
        return data
    }
}

enum TerminalKeyboardInput {
    static func shouldUseTextInput(for event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }
        return !isRawTerminalKey(event.keyCode)
    }

    static func isRawTerminalKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 36, 76, 48, 51, 117, 53, 126, 125, 124, 123, 115, 119, 116, 121:
            return true
        default:
            return false
        }
    }

    static func literalShellText(for event: NSEvent) -> String? {
        guard shouldUseTextInput(for: event) else { return nil }
        if let text = event.characters, !text.isEmpty {
            return text == "\"" || text == "~" ? text : nil
        }

        let shifted = event.modifierFlags.contains(.shift)
        switch (event.keyCode, shifted) {
        case (50, true):
            return "~"
        case (50, false):
            return "`"
        case (39, true):
            return "\""
        case (39, false):
            return "'"
        default:
            return translatedTextIgnoringDeadKeys(for: event)
        }
    }

    private static func translatedTextIgnoringDeadKeys(for event: NSEvent) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        let modifierKeyState = UInt32((event.modifierFlags.rawValue >> 16) & 0xFF)
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var unicode = [UniChar](repeating: 0, count: 8)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout,
                UInt16(event.keyCode),
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                unicode.count,
                &actualLength,
                &unicode
            )
        }
        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: unicode, count: actualLength)
    }
}

@MainActor
private final class TerminalDropContainerView: NSView {
    var onFileDrop: (([String]) -> Void)?
    var onLayout: (() -> Void)?
    var onWindowChanged: ((NSWindow?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        onFileDrop?(paths)
        return true
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?()
        onWindowChanged?(window)
    }
}

// MARK: - Drag payload resolver (pure, non-MainActor, testable)

/// Resolves an NSDraggingInfo pasteboard into the text that should be sent to
/// the terminal when the user drops a plain-text item or a file URL onto the
/// terminal view.
///
/// Keeping this pure (no AppKit UI, no actor) lets unit tests cover the
/// conversion logic without a live drag session or window server.
///
/// Rules:
/// - If the pasteboard carries a plain `.string` value, that string is returned
///   as-is (the caller is responsible for applying `PasteGuard` before sending).
/// - If no plain string is present but a file URL can be read, the POSIX path
///   of the first URL is returned. The caller uses `DroppedFilePaths` for
///   multi-file drops with shell-escaping; this helper is for the single-item
///   plain-text seam.
/// - Returns `nil` when neither type is readable.
public enum TerminalDragPayload {
    public enum PlainTextDropDecision: Equatable {
        case send(String)
        case confirm(String)
        case reject
    }

    /// Extract the plain-text value from a pasteboard for terminal input.
    /// Returns `nil` when the pasteboard has no readable `.string` content.
    public nonisolated static func plainText(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)
    }

    /// Sanitise `text` for terminal drag input.
    ///
    /// Returns the same string when it is safe to send immediately (single-line,
    /// no dangerous control characters, per `PasteGuard`). Returns `nil` when the
    /// content needs confirmation — the caller must invoke the confirm callback
    /// before sending.
    ///
    /// This is the pure seam tests exercise: `PasteGuard.classify` is the
    /// underlying rule; drag re-uses those semantics so the terminal never
    /// silently executes a multi-line command dropped from another source.
    public nonisolated static func safeTextToSend(_ text: String) -> String? {
        switch PasteGuard.classify(text) {
        case .safe: return text
        case .needsConfirm: return nil
        }
    }

    public nonisolated static func plainTextDropDecision(
        from pasteboard: NSPasteboard,
        confirmationAvailable: Bool
    ) -> PlainTextDropDecision {
        guard let text = plainText(from: pasteboard), !text.isEmpty else { return .reject }
        if let safe = safeTextToSend(text) { return .send(safe) }
        return confirmationAvailable ? .confirm(text) : .reject
    }
}

// MARK: - Restart decision helper (pure, non-MainActor, testable)

/// Captures the minimal information needed to decide whether and how to
/// restart a dead terminal, and to produce the parameters for the new spawn.
/// Keeping this pure (no AppKit, no actor) lets unit tests cover the logic
/// without a live UI.
public enum TerminalRestartDecision {
    /// Returns `(cwd, title)` if `descriptor` represents a restartable local
    /// shell (type `.terminal`, non-empty cwd). Returns `nil` for SSH surfaces
    /// and placeholders — those have their own reconnect flow.
    public static func spawnRequest(from descriptor: SurfaceDescriptor) -> (cwd: String, title: String)? {
        guard descriptor.type == .terminal,
              let cwd = descriptor.metadata["cwd"], !cwd.isEmpty else { return nil }
        return (cwd, descriptor.title)
    }
}

// MARK: - Paste guard (pure, non-MainActor, testable)

/// Classifies a candidate paste payload so the terminal can confirm before
/// sending multi-line or control-character content to the shell.
///
/// Keeping this pure (no AppKit, no actor) lets unit tests cover the logic
/// without a live UI.
public enum PasteGuard {
    /// The result of classifying a paste string.
    public enum Classification: Equatable {
        /// Safe to send immediately (single-line, no control characters).
        case safe
        /// Requires user confirmation before sending; `reason` is a
        /// short human-readable explanation.
        case needsConfirm(reason: String)
    }

    /// Whether bracketed-paste mode is enabled by default.
    /// When `true`, the terminal should send the bracketed-paste escape
    /// sequences (ESC[?2004h / ESC[?2004l) around pasted content.
    public static let bracketedPasteEnabled = true

    /// Classify `text` as safe or requiring confirmation.
    ///
    /// Rules:
    /// - Empty → `.safe`
    /// - Contains a newline character (`\n`, `\r`) → `.needsConfirm(reason: "multi-line")`
    /// - Contains a C0 control character (U+0000–U+001F, excluding `\t`),
    ///   DEL (U+007F), or ESC (U+001B) → `.needsConfirm(reason: "control-characters")`
    /// - Otherwise → `.safe`
    public static func classify(_ text: String) -> Classification {
        guard !text.isEmpty else { return .safe }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Newlines
            if v == 0x0A || v == 0x0D { return .needsConfirm(reason: "multi-line") }
            // C0 controls (0x00-0x1F) except horizontal tab (0x09)
            // ESC (0x1B) is in this range and also blocked
            if v <= 0x1F && v != 0x09 { return .needsConfirm(reason: "control-characters") }
            // DEL
            if v == 0x7F { return .needsConfirm(reason: "control-characters") }
        }
        return .safe
    }

    public static func confirmationLineCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 1
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                count += 1
                previousWasCR = true
            case 0x0A:
                if !previousWasCR { count += 1 }
                previousWasCR = false
            default:
                previousWasCR = false
            }
        }
        return count
    }
}

// MARK: - Bell detector (pure, non-MainActor, testable)

/// Detects whether a PTY data chunk contains a real BEL (0x07) — one that is
/// NOT the OSC string-terminator in an `ESC ] ... BEL` sequence.
///
/// Background: OSC (Operating System Command) sequences use BEL as one of the
/// two legal string terminators (the other is `ESC \`). A title-set sequence
/// looks like: `ESC (0x1B) ] (0x5D) 0 ; <title> BEL (0x07)`. The 0x07 there
/// terminates the OSC and must NOT be treated as an audible bell — doing so
/// produces spurious "unread" activity dots every time the shell changes the tab
/// title (UX-TERM-BEL-FALSE-POSITIVE).
///
/// Keeping this pure (no AppKit, no actor) lets unit tests cover the scanning
/// logic without a live terminal.
public enum BellDetector {
    /// Returns `true` when `data` contains at least one BEL byte (0x07) that
    /// is NOT acting as an OSC string-terminator.
    ///
    /// State machine:
    /// - Scanning normally: 0x1B starts `.afterESC`.
    /// - `.afterESC + 0x5D` → `.inOSC` (inside OSC payload).
    /// - `.inOSC + 0x07` → OSC-terminator BEL, ignored; back to `.scanning`.
    /// - `.inOSC + 0x1B` → starts `.afterESCinOSC` (two-byte ST path).
    /// - `.afterESCinOSC + 0x5C` → two-byte ST, back to `.scanning`.
    /// - `.afterESCinOSC + anything-else` → ESC aborted the OSC; re-evaluate the
    ///   byte in ground state (a following 0x07 is a real BEL).
    /// - `.scanning + 0x07` → real BEL, return `true`.
    /// - Any other byte resets `.afterESC` back to `.scanning`.
    public nonisolated static func containsStandaloneBEL(_ data: Data) -> Bool {
        var state: State = .scanning
        for byte in data {
            switch state {
            case .scanning:
                if byte == 0x07 { return true }
                if byte == 0x1B { state = .afterESC }
            case .afterESC:
                if byte == 0x5D { state = .inOSC } else { state = .scanning }
            case .inOSC:
                if byte == 0x07 { state = .scanning }      // OSC BEL terminator
                else if byte == 0x1B { state = .afterESCinOSC }
                // else: still inside OSC payload — remain in .inOSC
            case .afterESCinOSC:
                // 0x5C = '\\' completes the two-byte ST (ESC \), terminating the
                // OSC with no bell. Any other byte means the ESC did NOT form ST:
                // a bare ESC aborts the OSC string and returns to ground (xterm
                // treats ESC as an anywhere->escape transition), so this byte is
                // re-evaluated as if scanning -- a following 0x07 is a real BEL.
                if byte == 0x5C {
                    state = .scanning
                } else {
                    state = .scanning
                    if byte == 0x07 { return true }
                    if byte == 0x1B { state = .afterESC }
                }
            }
        }
        return false
    }

    private enum State { case scanning, afterESC, inOSC, afterESCinOSC }
}

// MARK: - Bell preferences (pure, non-MainActor, testable)

/// User-configurable bell preferences.
///
/// Keeping this pure (no AppKit, no actor) lets unit tests cover the logic
/// without a live UI. The surface reads this at bell time and passes it to
/// `BellHandler.effects(prefs:)` to decide which side-effects to apply.
public struct BellPreferences: Equatable {
    /// Play the system beep (`NSSound.beep()`) when a bell is received.
    public var sound: Bool
    /// Show a brief visual flash on the terminal view when a bell is received.
    public var flash: Bool

    /// Default: silent — no sound, no flash. New installs must not produce
    /// unexpected audio or visual disturbance without explicit user opt-in.
    public init(sound: Bool = false, flash: Bool = false) {
        self.sound = sound
        self.flash = flash
    }
}

/// The resolved set of side-effects to apply for a single bell event.
public struct BellEffects: Equatable {
    /// Whether to call `NSSound.beep()`.
    public let playSound: Bool
    /// Whether to trigger a visual flash on the terminal view.
    public let flash: Bool
    /// Whether to mark the surface as having unread activity (dot).
    /// Always `true` — the dot is the lowest-distraction baseline feedback.
    public let dot: Bool
}

/// Pure mapping from bell preferences to bell effects.
///
/// Keeping this non-MainActor lets unit tests cover the logic without AppKit.
/// The surface is responsible for executing the returned effects on the main actor.
public enum BellHandler {
    /// Map `prefs` to the set of effects that should be applied on the next bell.
    /// `dot` is always `true`; `playSound` and `flash` mirror the preference flags.
    public nonisolated static func effects(prefs: BellPreferences) -> BellEffects {
        BellEffects(playSound: prefs.sound, flash: prefs.flash, dot: true)
    }
}

// MARK: - Export format helpers (pure, non-MainActor, testable)

/// Supported export formats for terminal output.
public enum TerminalExportFormat {
    /// Plain UTF-8 text (ANSI escape sequences stripped by the caller).
    case txt
    /// Raw ANSI escape sequence text.
    case ansi
}

/// Pure helpers for the "Save Output..." action.
public enum TerminalExportHelpers {
    /// Returns the file extension string for a given export format.
    /// Used to derive the default filename presented to the user.
    public nonisolated static func fileExtension(for format: TerminalExportFormat) -> String {
        switch format {
        case .txt:  return "txt"
        case .ansi: return "ansi"
        }
    }
}

// MARK: - Copy-on-select decision (pure, non-MainActor, testable)

/// Pure gate for the copy-on-select preference.
public enum TerminalCopyOnSelect {
    /// Returns `true` only when the preference is enabled AND a non-empty
    /// selection exists. Either condition alone must not trigger a copy.
    public nonisolated static func shouldCopy(prefEnabled: Bool, hasSelection: Bool) -> Bool {
        prefEnabled && hasSelection
    }
}

// MARK: - TerminalSurface

private final class TerminalReaderMainHandoffHook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func set(_ action: (@Sendable () -> Void)?) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let action = action
        lock.unlock()
        action?()
    }
}

private final class TerminalReaderWillPublishHook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable (Data) -> Void)?

    func set(_ action: (@Sendable (Data) -> Void)?) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func fire(_ data: Data) {
        lock.lock()
        let action = action
        lock.unlock()
        action?(data)
    }
}

/// Process-wide hot-memory authority for open terminals. Entries hold owners
/// weakly and callbacks also capture them weakly, so a missed explicit unregister
/// cannot turn this registry into a lifetime leak. Enforcement reclaims hidden
/// surfaces first, then least-recently-used visible surfaces, and the focused
/// terminal last. Priority affects order, never grants an unbounded exemption.
@MainActor
final class TerminalMemoryBudgetAuthority {
    static let shared = TerminalMemoryBudgetAuthority(maxRetainedBytes: 64 * 1024 * 1024)

    /// What OS memory-pressure relief may do with an owner. Only the normal
    /// budget (`enforceBudget`) may take an already compacted owner further,
    /// to dormant; pressure relief stops at the compact stage.
    enum PressureState {
        case reclaimable
        /// A program is running in the foreground. Spared on a warning.
        case liveForegroundJob
        /// Already compacted or dormant. Never reclaimed again by pressure.
        case compacted
    }

    private final class Entry {
        weak var owner: AnyObject?
        let retainedBytes: () -> Int
        let priority: () -> Int
        let reclaim: () -> Void
        let pressureState: () -> PressureState
        var lastTouched: UInt64

        init(
            owner: AnyObject,
            retainedBytes: @escaping () -> Int,
            priority: @escaping () -> Int,
            reclaim: @escaping () -> Void,
            pressureState: @escaping () -> PressureState,
            lastTouched: UInt64
        ) {
            self.owner = owner
            self.retainedBytes = retainedBytes
            self.priority = priority
            self.reclaim = reclaim
            self.pressureState = pressureState
            self.lastTouched = lastTouched
        }
    }

    let maxRetainedBytes: Int
    private var entries: [UUID: Entry] = [:]
    private var clock: UInt64 = 0

    init(maxRetainedBytes: Int) {
        self.maxRetainedBytes = max(0, maxRetainedBytes)
    }

    @discardableResult
    func register(
        owner: AnyObject,
        retainedBytes: @escaping () -> Int,
        priority: @escaping () -> Int,
        reclaim: @escaping () -> Void,
        pressureState: @escaping () -> PressureState = { .reclaimable }
    ) -> UUID {
        purgeReleasedOwners()
        clock &+= 1
        let token = UUID()
        entries[token] = Entry(
            owner: owner,
            retainedBytes: retainedBytes,
            priority: priority,
            reclaim: reclaim,
            pressureState: pressureState,
            lastTouched: clock
        )
        return token
    }

    func unregister(_ token: UUID) {
        entries.removeValue(forKey: token)
    }

    func touch(_ token: UUID, enforce: Bool = true) {
        purgeReleasedOwners()
        if let entry = entries[token] {
            clock &+= 1
            entry.lastTouched = clock
        }
        if enforce { enforceBudget() }
    }

    func enforceBudget() {
        purgeReleasedOwners()
        var attempted = Set<UUID>()
        while retainedBytesForTesting > maxRetainedBytes {
            // PERF: single pass instead of filter-then-min (two dictionary
            // traversals per eviction). Entries are few; the win is avoiding
            // the filtered intermediate on every pressure loop iteration.
            var candidate: (key: UUID, value: Entry)?
            for (token, entry) in entries {
                guard !attempted.contains(token), entry.owner != nil else { continue }
                guard let best = candidate else { candidate = (token, entry); continue }
                let p = entry.priority()
                let bp = best.value.priority()
                if p < bp || (p == bp && entry.lastTouched < best.value.lastTouched) {
                    candidate = (token, entry)
                }
            }
            guard let victim = candidate else {
                return
            }
            attempted.insert(victim.key)
            let before = max(0, victim.value.retainedBytes())
            victim.value.reclaim()
            let after = max(0, victim.value.retainedBytes())
            if after < before {
                attempted.removeAll(keepingCapacity: true)
            }
        }
    }

    /// OS memory-pressure relief. Reclaims owners whose priority is at most
    /// `maxPriority`, least recently used first, until retained bytes are at or
    /// below `ceiling`. Unlike `enforceBudget`, it only ever takes the compact
    /// step: owners already compacted are skipped, on this event and on every
    /// later one, so repeated warnings or criticals never make a hidden
    /// terminal dormant and blank its mirror. With `spareLiveForegroundJobs`,
    /// owners running a foreground program are skipped too. Returns how many
    /// owners actually shrank.
    @discardableResult
    func relieveMemoryPressure(ceiling: Int, maxPriority: Int, spareLiveForegroundJobs: Bool) -> Int {
        purgeReleasedOwners()
        let candidates = entries.values
            .filter { $0.owner != nil && $0.priority() <= maxPriority }
            .sorted { $0.lastTouched < $1.lastTouched }
        var reclaimed = 0
        for entry in candidates {
            guard retainedBytesForTesting > max(0, ceiling) else { break }
            guard entry.owner != nil else { continue }
            switch entry.pressureState() {
            case .compacted:
                continue
            case .liveForegroundJob where spareLiveForegroundJobs:
                continue
            case .reclaimable, .liveForegroundJob:
                break
            }
            let before = max(0, entry.retainedBytes())
            entry.reclaim()
            if max(0, entry.retainedBytes()) < before { reclaimed += 1 }
        }
        return reclaimed
    }

    var retainedBytesForTesting: Int {
        entries.values.reduce(into: 0) { total, entry in
            guard entry.owner != nil else { return }
            total += max(0, entry.retainedBytes())
        }
    }

    var registeredCountForTesting: Int {
        purgeReleasedOwners()
        return entries.count
    }

    private func purgeReleasedOwners() {
        entries = entries.filter { $0.value.owner != nil }
    }
}

/// The terminal's single system-output stream. Reserve it before producing the
/// text (so a busy terminal refuses before any work), then `deliver` the text
/// plus its trailing notice: slices are cut lazily from those strings, so no
/// full `Data` copy exists and the notice cannot be overtaken by other output.
@MainActor
public final class SystemOutputLease {
    fileprivate weak var surface: TerminalSurface?
    fileprivate var parts: [String] = []
    fileprivate var partIndex = 0
    fileprivate var offset = 0
    fileprivate var delivering = false
    fileprivate var finished = false

    fileprivate init(surface: TerminalSurface) { self.surface = surface }

    /// Bytes of the captured strings not yet handed to the terminal.
    var remainingBytes: Int {
        guard partIndex < parts.count else { return 0 }
        return parts[partIndex...].reduce(0) { $0 + $1.utf8.count } - offset
    }

    /// The current string stays retained in full until its last slice is consumed.
    var retainedBytes: Int {
        guard partIndex < parts.count else { return 0 }
        return parts[partIndex...].reduce(0) { $0 + $1.utf8.count }
    }

    public func deliver(_ text: String, trailing: String = "") {
        guard !finished, !delivering, let surface else { return }
        var text = text
        var trailing = trailing
        text.makeContiguousUTF8()
        trailing.makeContiguousUTF8()
        parts = [text, trailing]
        surface.startSystemOutput(self)
    }

    /// Releases an undelivered reservation; a stream already delivering finishes itself.
    public func cancel() {
        guard !delivering else { return }
        surface?.finishSystemOutput(self)
    }

    /// Next slice of at most `maxBytes`, ending on a UTF-8 scalar boundary.
    fileprivate func nextSlice(maxBytes: Int) -> Data? {
        while partIndex < parts.count {
            let part = parts[partIndex]
            let count = part.utf8.count
            guard offset < count else {
                parts[partIndex] = ""
                partIndex += 1
                offset = 0
                continue
            }
            let start = offset
            let slice = part.utf8.withContiguousStorageIfAvailable { buf -> (Data, Int) in
                var end = min(start + maxBytes, count)
                while end < count, end > start + 1, buf[end] & 0xC0 == 0x80 { end -= 1 }
                return (Data(bytes: buf.baseAddress! + start, count: end - start), end)
            }
            guard let (data, end) = slice else { return nil }
            offset = end
            return data
        }
        return nil
    }
}

/// PTY-backed shell surface. Spawns the user's shell via `forkpty(3)`
/// and renders its output through `ANSIRenderer`. The terminal view is
/// directly interactive — no separate input field (cmux model).
@MainActor
public final class TerminalSurface: NSObject, Surface, TerminalHistoryCoordinatorDelegate {
    public enum Launch {
        case shell(cwd: String)
        case ssh(profile: SSHHostProfile, cwd: String)
        case sshPlaceholder(cwd: String)
    }

    /// Includes disposition work whose immediate owner no longer has a surface
    /// (for example, PTY preparation that failed after fork). App termination
    /// waits this registry in addition to registered surface barriers.
    public static func activeProcessDispositionBarrier() -> SurfaceTerminationBarrier? {
        let works = TerminalPTYProcessRuntime.activeProcessDispositionWorksSnapshot()
        guard !works.isEmpty else { return nil }
        return SurfaceTerminationBarrier(
            groups: works.map(\.group),
            completionChecks: works.map(\.succeeded)
        )
    }

    public static func pendingHistoryDeleteBarrier() -> SurfaceTerminationBarrier? {
        TerminalHistoryCoordinator.pendingFinalDeleteBarrier()
    }

    /// Rehydrates metadata-only final-delete tombstones at process launch.
    /// The registry owns repository/ID state only; no Surface is retained.
    @discardableResult
    public static func replayPendingHistoryDeletes(
        repository: TerminalOutputRepository
    ) -> SurfaceTerminationBarrier? {
        TerminalHistoryCoordinator.replayPendingFinalDeletes(repository: repository)
    }

    /// Starts an unconditional history delete for wrappers that no longer own
    /// a TerminalSurface. The global registry keeps only repository/ID state so
    /// a failed cleanup remains retryable without retaining the closed wrapper.
    @discardableResult
    public static func scheduleOwnerlessHistoryDelete(
        repository: TerminalOutputRepository,
        surfaceID: String
    ) -> SurfaceTerminationBarrier {
        TerminalHistoryCoordinator.scheduleOwnerlessFinalDelete(
            repository: repository,
            surfaceID: surfaceID
        )
    }

    /// Clears a reusable stable-ID terminal without granting an old runtime an
    /// unconditional final-delete right over a future writer generation.
    @discardableResult
    public static func scheduleOwnerlessHistoryClearForReuse(
        repository: TerminalOutputRepository,
        surfaceID: String
    ) -> SurfaceTerminationBarrier {
        TerminalHistoryCoordinator.scheduleOwnerlessClearForReuse(
            repository: repository,
            surfaceID: surfaceID
        )
    }

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let ghosttyView: GhosttyTerminalView
    private var masterFD: Int32 = -1
    private var masterFDLease: TerminalFileDescriptorLease?
    private var childPID: pid_t = -1
    private var childReapInFlightPID: pid_t?
    private var childReapForegroundGroup: TerminalPTYProcessRuntime.CapturedForegroundProcessGroup?
    private var lastCapturedForegroundGroup: TerminalPTYProcessRuntime.CapturedForegroundProcessGroup?
    private var processAlive = false
    private var exitStatus: Int32?
    private var terminationSignal: Int32?
    private var terminalDeadReason: String?
    private var didAppendProcessExitedBanner = false
    private var lastOutputAt: Date?
    private var inputPump: TerminalInputPump?
    private var readSource: DispatchSourceRead?
    private var historyReplayBackpressureActive = false
    /// Live Ghostty queue saturation. The reader stays paused while a full
    /// handoff might not fit, or while rejected handoffs wait in the owner FIFO.
    private var liveOutputBackpressureActive = false
    /// One balanced `DispatchSource` suspension shared by replay and live pressure.
    private var readSourceSuspendedForBackpressure = false
    private var deferredUnhostedGhosttyReplay: Data?
    private var ownedGhosttyReplayOutput: [Data] = []
    private var ownedGhosttyReplayOutputBytes = 0
    private static let maxOwnedGhosttyReplayOutputBytes = 4 * 1024 * 1024
    /// One full PTY event (`maxPTYReadEventBytes`) must always fit after the
    /// reader is allowed to run, so the pause point leaves exactly this reserve.
    private static let ptyHandoffReserveBytes = 256 * 1024
    /// Reserved or streaming system output. While streaming, the PTY reader is
    /// paused and every other writer waits in `heldBehindSystemOutput` (one
    /// in-flight PTY batch plus small notices, bounded by the owner cap).
    private var systemOutput: SystemOutputLease?
    private var systemOutputPumpScheduled = false
    private enum HeldOutput {
        case pty(Data, renderAllowedAtRead: Bool)
        case system(Data)
    }
    private var heldBehindSystemOutput: [HeldOutput] = []
    private var heldBehindSystemOutputBytes = 0
    private var systemOutputStreaming: Bool { systemOutput?.delivering == true }
    private var applicationTerminationBarrier: SurfaceTerminationBarrier?
    private var runtimeRestartRequiredHistoryBarrier: SurfaceTerminationBarrier?
    private var runtimeDispositionBarrierFactoryForTesting:
        ((pid_t) -> SurfaceTerminationBarrier)?
    private let readerWillPublishHook = TerminalReaderWillPublishHook()
    private let readerMainHandoffHook = TerminalReaderMainHandoffHook()
    private let readerHandoffState = TerminalReaderHandoffState()
    private let childReapCompletionHook = TerminalReaderMainHandoffHook()
    private var processTreeSignalCountForTesting = 0
    private var publishesRuntimeHealth = true
    private static let activeANSIScrollbackRows = 2_000
    private static let reclaimedANSIScrollbackRows = 128
    private var renderer = ANSIRenderer(
        rows: TerminalViewportGeometry.fallbackSize.rows,
        cols: TerminalViewportGeometry.fallbackSize.cols,
        scrollbackLimit: activeANSIScrollbackRows
    )
    private var terminalSize = TerminalViewportGeometry.fallbackSize
    /// Last geometry actually pushed to the live PTY via `TIOCSWINSZ`.
    /// Distinct from `terminalSize` so Ghostty/ANSI can track intermediate
    /// AppKit frames while we freeze the shell's idea of COLUMNS/LINES during
    /// hide/park/layout thrash (workspace switch garbling).
    private var lastCommittedPTYSize: TerminalViewportSize?
    private var pendingPTYWinsize: TerminalViewportSize?
    private var ptyWinsizeDebounceWorkItem: DispatchWorkItem?
    private var ptyWinsizeCommitCountForTestingValue = 0
    private static let ptyWinsizeDebounceInterval: TimeInterval = 0.05
    private var savedSSHPassword: String?
    private var didSendSavedSSHPassword = false
    private var passwordPromptCount = 0
    private var awaitingSSHFirstOutput = false
    private var isVisible = false
    private let historyCoordinator: TerminalHistoryCoordinator
    private let outputBus: SurfaceOutputBus
    /// How long a utility worker observes a child disposition before reporting
    /// `process_reap_timeout`; the disposition itself keeps running and keeps ownership.
    public static let defaultChildDispositionObserverTimeout: TimeInterval = 30
    private let childDispositionObserverTimeout: TimeInterval
    private var isClosing = false
    private var outputPartial = false
    private var outputPartialReason: String?
    private var outputPendingBytes = 0
    // Legacy heal buffer retained for the pure heal-plan seam / reveal path.
    // Live hidden output no longer grows this toward 4 MiB permanently: the
    // mirror uses the same force-flushed pendingRendererEvents path as visible
    // surfaces (capped ANSI ring). We still track overflow against the 4 MiB
    // recoverability budget so partial truth stays honest.
    private var hiddenRendererBuffer = Data()
    private var hiddenRendererBufferOverflowed = false
    /// Bytes accepted on the hidden mirror path since the last hide transition.
    /// Caps recoverability accounting at `maxHiddenRendererBufferBytes` without
    /// pinning a permanent second raw copy alongside Ghostty scrollback.
    private var hiddenMirrorAcceptedBytes = 0
    private var totalOutputBytes = 0
    private var outputBytesAtLastTelemetry = 0
    private var maxPTYReadBatchBytesObserved = 0
    private var maxPTYReadCallsObserved = 0
    private var lastOutputTelemetryAt = Date.distantPast
    private var readerAllowsRender = false
    /// Set while a deferred audit-#3 stuck-hidden self-heal is pending, so output
    /// arriving every few ms during the desync doesn't schedule (or log) it repeatedly.
    private var stuckHiddenHealScheduled = false
    private var isDrainingHiddenBacklog = false
    private var hiddenBacklogDrainGeneration = 0
    /// Absolute deadline after which the hidden-backlog drain stops re-arming and
    /// force-completes, so a continuous stream can't latch canRender false (#5).
    private var hiddenBacklogDrainDeadline: Date?
    private var focusRepairGeneration = 0
    private var busyStatePollDeadline: Date?
    private var busyStatePollGeneration: UInt64 = 0
    private var busyStatePollWorkItem: DispatchWorkItem?
#if DEBUG
    private var busyStatePollCallbackEntryCountForTestingValue = 0
#endif
    private var busyStateProbeUntil = Date.distantPast
    private var lastPublishedBusyState = false
    private var progressActive = false
    private var busySince: Date?
    private var lastCommandExitCode: Int?
    private var didBeepForDeadInput = false
    // MARK: - readTextSnapshot cache
    // Tracks how many times TerminalSurface has mutated the ANSIRenderer (via
    // renderer.feed / renderer.resize). Used as the renderer-side key for the
    // readTextSnapshot cache so we do not have to reach into ANSIRenderer's
    // private contentVersion.
    private var rendererMutationCount: UInt64 = 0
    // MARK: - Lazy mirror-renderer feeding (PERF-136)
    // The ANSIRenderer (`renderer`) exists ONLY to produce the mirror snapshot
    // (readTextSnapshot / saveOutput). On the VISIBLE hot path we used to feed it
    // byte-by-byte on the main thread for every output chunk, in addition to
    // feeding the ghostty display — a full double-emulation that dominated CPU
    // during high-rate output (`yes`, build logs).
    //
    // Instead we now RECORD visible feed/resize operations into an ordered pending
    // buffer and replay them into `renderer` only when a snapshot is actually read
    // (ensureRendererCurrent). The renderer's state is observable ONLY via snapshot
    // reads, and every read flushes the buffer first, so the deferral is
    // unobservable: the replayed sequence is byte-identical to eager feeding BY
    // CONSTRUCTION (same feed/resize ops, same order). `rendererMutationCount`
    // still advances on every BUFFERED event so cached snapshots invalidate
    // correctly while pending work exists.
    enum PendingRendererEvent {
        case bytes(Data)
        case resize(rows: Int, cols: Int)
    }
    static let maxPendingRendererEvents = 4_096
    private var pendingRendererEvents: [PendingRendererEvent] = []
    private var pendingRendererByteCount = 0

    static func pendingRendererBufferExceeded(byteCount: Int, eventCount: Int) -> Bool {
        // Inclusive bounds: a queue at exactly 4 MiB / 4096 events must flush.
        // Using `>` allowed a permanent 4 MiB-1 raw pin (and 3 MiB after a
        // 5 MiB flush with 1 MiB chunks) under continuous producers.
        byteCount >= maxHiddenRendererBufferBytes || eventCount >= maxPendingRendererEvents
    }

    /// Replays recorded renderer events into `target` in order. This is the SAME
    /// code path the production flush (`ensureRendererCurrent`) uses, exposed as a
    /// pure static seam so the equivalence test drives identical logic.
    static func replay(_ events: [PendingRendererEvent], into target: ANSIRenderer) {
        for event in events {
            switch event {
            case .bytes(let data):
                target.feed(data)
            case .resize(let rows, let cols):
                target.resize(rows: rows, cols: cols)
            }
        }
    }

    /// Flushes all pending renderer events into `renderer`, then clears the buffer.
    /// Idempotent: a no-op when nothing is pending. MUST be called at the top of
    /// every renderer-read site so the snapshot reflects all deferred events.
    private func ensureRendererCurrent() {
        guard !pendingRendererEvents.isEmpty else { return }
        Self.replay(pendingRendererEvents, into: renderer)
        pendingRendererEvents.removeAll(keepingCapacity: true)
        pendingRendererByteCount = 0
    }

    /// Conservative accounting for the large screen-retention owners controlled
    /// by this surface. Cached UTF-8 snapshots and ANSI cells count alongside raw
    /// queues and Ghostty's native scrollback.
    private var terminalMemoryRetainedBytes: Int {
        let populatedRows = renderer.rows + renderer.scrollbackCount
        let cellBytes = populatedRows * renderer.cols * MemoryLayout<ANSIRenderer.Cell>.stride
        let retainedRowSlots: Int
        if terminalMemoryIsDormant {
            retainedRowSlots = 1
        } else if terminalMemoryUsesCompactRenderer {
            retainedRowSlots = Self.reclaimedANSIScrollbackRows
        } else {
            retainedRowSlots = Self.activeANSIScrollbackRows
        }
        let rowSlots = retainedRowSlots * MemoryLayout<[ANSIRenderer.Cell]>.stride
        let cachedBytes: Int
        if let cachedTextSnapshot {
            cachedBytes = cachedTextSnapshot.value.text.utf8.count
                + (cachedTextSnapshot.value.ansiText?.utf8.count ?? 0)
                + (cachedTextSnapshot.viewportText?.utf8.count ?? 0)
        } else {
            cachedBytes = 0
        }
        return ghosttyView.retainedTerminalBytesEstimate
            + cellBytes
            + rowSlots
            + pendingRendererByteCount
            + hiddenRendererBuffer.count
            + (deferredUnhostedGhosttyReplay?.count ?? 0)
            + ownedGhosttyReplayOutputBytes
            + heldBehindSystemOutputBytes
            + (systemOutput?.retainedBytes ?? 0)
            + cachedBytes
    }

    private func touchTerminalMemoryBudget(addedBytes: Int = 0, force: Bool = true) {
        guard let terminalMemoryBudgetToken else { return }
        terminalMemoryBytesSinceBudgetCheck += max(0, addedBytes)
        guard force || terminalMemoryBytesSinceBudgetCheck >= 256 * 1024 else { return }
        terminalMemoryBytesSinceBudgetCheck = 0
        TerminalMemoryBudgetAuthority.shared.touch(terminalMemoryBudgetToken)
    }

    private var terminalMemoryReclaimPriority: Int {
        if historyReplayBackpressureActive { return 3 }
        guard isVisible else { return 0 }
        return view.window?.firstResponder === ghosttyView ? 2 : 1
    }

    private var terminalMemoryPressureState: TerminalMemoryBudgetAuthority.PressureState {
        if terminalMemoryWasReclaimed || terminalMemoryIsDormant { return .compacted }
        return foregroundJobAlive ? .liveForegroundJob : .reclaimable
    }

    /// Reclaims a terminal according to its visibility. Hidden terminals can
    /// release the native surface entirely. Visible terminals retain their PTY
    /// and current frame, but rebuild Ghostty from that bounded frame so old
    /// native scrollback/caches cannot bypass the process-wide hard ceiling.
    private func reclaimTerminalMemoryUnderPressure() {
        guard !isClosing,
              !historyReplayBackpressureActive else { return }
        // Owner-held handoffs are already in the ANSI mirror this rebuild seeds
        // from; replaying them again afterwards would print them twice. The budget
        // is re-checked as soon as the owner queue empties.
        guard ownedGhosttyReplayOutput.isEmpty else { return }
        if isVisible {
            compactVisibleTerminalMemory()
            return
        }
        if terminalMemoryIsDormant {
            ghosttyView.releaseForTerminalMemoryBudget()
            terminalMemoryWasReclaimed = true
            return
        }
        ensureRendererCurrent()
        if terminalMemoryWasReclaimed {
            // Extreme fan-out fallback: once every old tab is already compact,
            // make the least-recently-used one dormant. Durable history remains
            // authoritative; only its old on-screen cache is discarded.
            renderer = ANSIRenderer(rows: 1, cols: 1, scrollbackLimit: 0)
            rendererMutationCount &+= 1
            pendingRendererEvents.removeAll(keepingCapacity: false)
            pendingRendererByteCount = 0
            cachedTextSnapshot = nil
            terminalMemoryIsDormant = true
            return
        }
        let currentFrame = renderer.ansiSnapshot(includeScrollback: false)
        let compact = ANSIRenderer(
            rows: terminalSize.rows,
            cols: terminalSize.cols,
            scrollbackLimit: Self.reclaimedANSIScrollbackRows
        )
        if let data = currentFrame.data(using: .utf8), !data.isEmpty {
            compact.feed(data)
        }
        renderer = compact
        terminalMemoryUsesCompactRenderer = true
        rendererMutationCount &+= 1
        pendingRendererEvents.removeAll(keepingCapacity: false)
        pendingRendererByteCount = 0
        hiddenRendererBuffer = Data()
        cachedTextSnapshot = nil
        ghosttyView.releaseForTerminalMemoryBudget()
        terminalMemoryWasReclaimed = true
        outputPartial = true
        if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
            outputPartialReason = "terminal_memory_retention_cap"
        }
    }

    private func compactVisibleTerminalMemory() {
        ensureRendererCurrent()
        let currentFrame: String
        if let viewport = ghosttyView.readViewportText(), !viewport.isEmpty {
            currentFrame = viewport
        } else {
            currentFrame = renderer.ansiSnapshot(includeScrollback: false)
        }
        let replay = Data(currentFrame.utf8)
        guard replay.count <= GhosttyTerminalView.maxPendingOutputBytes else {
            outputPartial = true
            outputPartialReason = "terminal_memory_replay_cap"
            return
        }
        if terminalMemoryUsesCompactRenderer {
            // Second pressure pass: the visible Ghostty viewport remains the
            // responsive current frame, so the duplicate ANSI mirror can become
            // dormant. readText still prefers the live viewport; SQLite owns old
            // transcript recovery.
            renderer = ANSIRenderer(rows: 1, cols: 1, scrollbackLimit: 0)
            terminalMemoryIsDormant = true
        } else {
            let compact = ANSIRenderer(
                rows: terminalSize.rows,
                cols: terminalSize.cols,
                scrollbackLimit: Self.reclaimedANSIScrollbackRows
            )
            if !replay.isEmpty { compact.feed(replay) }
            renderer = compact
            terminalMemoryUsesCompactRenderer = true
        }
        rendererMutationCount &+= 1
        pendingRendererEvents.removeAll(keepingCapacity: false)
        pendingRendererByteCount = 0
        hiddenRendererBuffer = Data()
        cachedTextSnapshot = nil
        outputPartial = true
        if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
            outputPartialReason = "terminal_memory_retention_cap"
        }
        // This is the same ordered/backpressured parser rebuild used for durable
        // history replay. The PTY session remains alive and input callbacks stay
        // installed; only old on-screen scrollback is discarded.
        beginGhosttyHistoryReplay(replay)
    }

    private func restoreReclaimedTerminalMemoryIfNeeded() {
        guard terminalMemoryWasReclaimed else { return }
        ensureRendererCurrent()
        let recentANSI = renderer.ansiSnapshot(includeScrollback: true)
        let expanded = ANSIRenderer(
            rows: terminalSize.rows,
            cols: terminalSize.cols,
            scrollbackLimit: Self.activeANSIScrollbackRows
        )
        let replay = Data(recentANSI.utf8)
        if !replay.isEmpty {
            expanded.feed(replay)
        }
        renderer = expanded
        rendererMutationCount &+= 1
        cachedTextSnapshot = nil
        terminalMemoryWasReclaimed = false
        terminalMemoryIsDormant = false
        terminalMemoryUsesCompactRenderer = false
        if replay.count <= GhosttyTerminalView.maxPendingOutputBytes {
            beginGhosttyHistoryReplay(replay)
        } else {
            outputPartial = true
            outputPartialReason = "terminal_memory_replay_cap"
        }
    }
    // Cached result of readTextSnapshot(). Invalidated when either the renderer
    // mutation count or the ghostty viewport text changes (see snapshotCacheValid).
    private var cachedTextSnapshot: (rendererVersion: UInt64, viewportText: String?, stateSignature: String, value: TerminalTextSnapshot)?
    private var parkingWindow: NSWindow?
    private var parkingConstraints: [NSLayoutConstraint] = []
    private var restartBannerButton: NSButton?
    private var terminalMemoryBudgetToken: UUID?
    private var terminalMemoryWasReclaimed = false
    private var terminalMemoryIsDormant = false
    private var terminalMemoryUsesCompactRenderer = false
    private var terminalMemoryBytesSinceBudgetCheck = 0

    /// Bell preferences, configurable by the user. Defaults to silent (no sound,
    /// no flash) so new installs do not produce unexpected audio or visual output.
    public var bellPreferences = BellPreferences()

    /// When `true`, any non-empty mouse selection is automatically copied to the
    /// system pasteboard (copy-on-select). Defaults to `false` so existing
    /// behavior is unchanged; the user must opt in via preferences.
    public var copyOnSelectEnabled: Bool = false

    /// Called on the main actor when the user taps "Restart shell" on the
    /// dead-terminal banner. The caller (AppCommandRouter) replaces this
    /// surface with a fresh one in the same pane and cwd.
    public var onRestartRequested: (() -> Void)?
    /// Called after Ghostty accepts a new OSC terminal title.
    public var onTitleChange: ((String) -> Void)?
    /// Called when a busy span of at least `minimumFinishedBusyDuration` ends.
    /// `userIsLooking` is true when this terminal is visible in the key window.
    public var onBusyFinished: ((_ title: String, _ body: String, _ userIsLooking: Bool) -> Void)?
    /// Fires on every published busy/idle transition so paired devices see the spinner change.
    public var onBusyStateChanged: ((_ busy: Bool) -> Void)?
    /// Called when the terminal takes keyboard focus, so the host can clear its finished dot.
    public var onBecameFocused: (() -> Void)?
    private static let hiddenBacklogQuietDelay: TimeInterval = 0.25
    /// Absolute cap on how long the hidden-backlog drain may keep re-arming before it
    /// force-completes, even under a never-quiet stream (#5). Bounds the frozen frame.
    private static let hiddenBacklogMaxDrainWindow: TimeInterval = 1.0
    private static let busyStateProbeDuration: TimeInterval = 2.0
    private static let activeBusyStatePollInterval: TimeInterval = 0.25
    private static let hiddenBusyStatePollInterval: TimeInterval = 1.0
    private static let outputTelemetryByteInterval = 8 * 1024 * 1024
    private static let outputTelemetryTimeInterval: TimeInterval = 60
    private nonisolated static let maxPTYReadEventBytes = 256 * 1024
    private nonisolated static let maxPTYReadCallsPerEvent = 64
    // Maximum bytes buffered for hidden-renderer heal. Chosen large enough to
    // cover realistic hidden bursts (build output, long completions) while
    // bounding memory. Bytes beyond this cap are NOT fed to the renderer on
    // reveal; the snapshot will be partial (complete=false) but never OOM.
    private static let maxHiddenRendererBufferBytes = 4 * 1024 * 1024

    public var viewportSize: TerminalViewportSize {
        terminalSize
    }

    public var isBusy: Bool {
        Self.isBusy(
            jobAlive: foregroundJobAlive,
            progressActive: progressActive,
            lastOutputAt: lastOutputAt,
            title: descriptor.title,
            now: Date()
        )
    }

    /// Quiet window after which a live foreground job with no progress report
    /// and no spinner title reads as idle (e.g. a TUI waiting for input).
    nonisolated static let busyQuietInterval: TimeInterval = 2.0
    /// Busy spans shorter than this never produce a "finished" dot or notification.
    nonisolated static let minimumFinishedBusyDuration: TimeInterval = 3.0

    /// ponytail: a silent foreground command (e.g. `sleep 60`) reads idle after
    /// `busyQuietInterval`; only output, OSC 9;4 progress or a spinner title keep it busy.
    nonisolated static func isBusy(
        jobAlive: Bool,
        progressActive: Bool,
        lastOutputAt: Date?,
        title: String,
        now: Date
    ) -> Bool {
        guard jobAlive else { return false }
        if progressActive || hasSpinnerTitle(title) { return true }
        guard let lastOutputAt else { return false }
        return now.timeIntervalSince(lastOutputAt) < busyQuietInterval
    }

    /// True when `data` carries printable text outside escape sequences. Idle TUIs
    /// (Distill at its prompt) repaint ~10x/s with escape-only frames (cursor moves,
    /// synchronized-update brackets, kitty graphics probes); those are not work and
    /// must not keep the busy spinner on. Escape state is tracked per chunk only.
    nonisolated static func containsVisibleOutput(_ data: Data) -> Bool {
        enum State { case ground, escape, csi, string, stringEscape }
        var state = State.ground
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
                else if byte >= 0x20 && byte != 0x7F { return true }
            case .escape:
                switch byte {
                case 0x5B: state = .csi
                case 0x5D, 0x50, 0x5F, 0x5E, 0x58: state = .string
                default: state = .ground
                }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .ground }
            case .string:
                if byte == 0x07 { state = .ground } else if byte == 0x1B { state = .stringEscape }
            case .stringEscape:
                state = byte == 0x5C ? .ground : .string
            }
        }
        return false
    }

    /// TUIs animate a braille spinner in the title while working (Claude Code shows a static ✳ when idle).
    nonisolated static func hasSpinnerTitle(_ title: String) -> Bool {
        guard let scalar = title.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(scalar.value)
    }

    /// Glyphs TUIs animate or park at the start of the OSC title: braille spinners,
    /// ◐◑◒◓ / ◴◵◶◷ quarter circles, and Claude Code's ·✢✳✶✻✽ stars (✳ is its idle mark).
    nonisolated static func isTitleSpinnerGlyph(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x2800...0x28FF, 0x25D0...0x25D3, 0x25F4...0x25F7,
                 0x00B7, 0x2722, 0x2733, 0x2736, 0x273B, 0x273D, 0xFE0E, 0xFE0F:
                return true
            default:
                return false
            }
        }
    }

    /// `title` without its leading spinner-glyph run and the " - " that follows it.
    nonisolated static func stableTitle(_ title: String) -> String {
        guard let first = title.first, isTitleSpinnerGlyph(first) else { return title }
        var rest = Substring(title).drop(while: isTitleSpinnerGlyph)
        rest = rest.drop { $0.isWhitespace }
        if rest.first == "-" { rest = rest.dropFirst().drop { $0.isWhitespace } }
        return String(rest)
    }

    /// The raw title stays on the descriptor (isBusy reads the spinner); only a change
    /// to the stable title is forwarded, so spinner frames are never persisted or broadcast.
    func handleOSCTitle(_ title: String) {
        guard descriptor.title != title else { return }
        let previousStable = Self.stableTitle(descriptor.title)
        descriptor.title = title
        let stable = Self.stableTitle(title)
        guard !stable.isEmpty, stable != previousStable else { return }
        onTitleChange?(stable)
    }

    private var foregroundJobAlive: Bool {
        let foregroundProcessGroup = foregroundProcessGroup()
        guard Self.isTerminalJobBusy(
            processAlive: processAlive,
            shellPID: childPID,
            foregroundProcessGroup: foregroundProcessGroup
        ), let capturedForegroundGroup = lastCapturedForegroundGroup else {
            return false
        }
        return capturedForegroundGroup.pgid == foregroundProcessGroup
            && capturedForegroundGroup.sessionID == childPID
    }

    var foregroundJobAliveForTesting: Bool { foregroundJobAlive }

    var ownsTerminalFocusForTesting: Bool {
        view.window?.firstResponder === ghosttyView
    }

    var lastPublishedBusyStateForTesting: Bool {
        lastPublishedBusyState
    }

#if DEBUG
    var busyStatePollPendingCountForTesting: Int {
        busyStatePollWorkItem == nil ? 0 : 1
    }

    var busyStatePollCallbackEntryCountForTesting: Int {
        busyStatePollCallbackEntryCountForTestingValue
    }
#endif

    private var historyOutstandingBytes: Int {
        historyCoordinator.outstandingBytes
    }

    private var historyWriteFailures: Int {
        historyCoordinator.writeFailures
    }

    var historyOutstandingBytesForTesting: Int {
        historyCoordinator.outstandingBytes
    }

    var ptyReadDiagnosticsForTesting: (maxBatchBytes: Int, maxReadCalls: Int) {
        (maxPTYReadBatchBytesObserved, maxPTYReadCallsObserved)
    }

    var foregroundProcessGroupForTesting: pid_t? {
        foregroundProcessGroup()
    }

    var capturedForegroundProcessGroupForTesting: TerminalPTYProcessRuntime.CapturedForegroundProcessGroup? {
        lastCapturedForegroundGroup
    }

    var historyReplayInFlightForTesting: Bool {
        historyCoordinator.replayInFlight
    }

    var historyReplayDeferredForTesting: Bool {
        historyCoordinator.isReplayDeferredForTesting
    }

    var historyPreparationStateForTesting: TerminalHistoryCoordinator.PreparationState {
        historyCoordinator.preparationStateForTesting
    }

    var historyLiveClearInFlightForTesting: Bool {
        historyCoordinator.liveClearInFlightForTesting
    }

    var historyWriterGenerationForTesting: String? {
        historyCoordinator.writerGenerationForTesting
    }

    var terminalDeadReasonForTesting: String? { terminalDeadReason }
    var inputPumpConfiguredForTesting: Bool { inputPump != nil }
    func drainInputPumpForTesting() { inputPump?.drain() }
    var readerConfiguredForTesting: Bool { readSource != nil }
    var readerPausedForHistoryReplayForTesting: Bool {
        historyReplayBackpressureActive && readSourceSuspendedForBackpressure
    }
    var readerPausedForLiveOutputForTesting: Bool {
        liveOutputBackpressureActive && readSourceSuspendedForBackpressure
    }
    var liveOutputBackpressureActiveForTesting: Bool { liveOutputBackpressureActive }
    var readerSuspendedForTesting: Bool { readSourceSuspendedForBackpressure }
    var systemOutputOwnedForTesting: Bool { systemOutput != nil }
    var systemOutputHeldBytesForTesting: Int { heldBehindSystemOutputBytes }
    func installGhosttyNativeDriverForTesting(_ driver: GhosttyTerminalView.NativeDriverForTesting) {
        ghosttyView.nativeDriverForTesting = driver
    }
    func prepareGhosttyHostForTesting() -> Bool { ghosttyView.prepareHistoryReplayHost() }
    var ghosttyReplayInProgressForTesting: Bool {
        ghosttyView.historyReplayDrainInProgressForTesting
    }
    var ghosttyMaximumPendingOutputBytesForTesting: Int {
        ghosttyView.maximumPendingOutputBytesObservedForTesting
    }
    var ghosttyPendingOutputBytesForTesting: Int {
        ghosttyView.pendingOutputDiagnosticsForTesting.logicalBytes
    }
    var ghosttySurfaceCreationCountForTesting: Int {
        ghosttyView.surfaceCreationCountForTesting
    }
    var ghosttyHasLiveSurfaceForTesting: Bool {
        ghosttyView.hasLiveSurfaceForTesting
    }
    var ownedGhosttyReplayOutputBytesForTesting: Int {
        ownedGhosttyReplayOutputBytes
    }
    var hasDeferredUnhostedGhosttyReplayForTesting: Bool {
        deferredUnhostedGhosttyReplay != nil
    }
    var terminalMemoryRetainedBytesForTesting: Int { terminalMemoryRetainedBytes }
    var terminalMemoryWasReclaimedForTesting: Bool { terminalMemoryWasReclaimed }
    static var aggregateTerminalMemoryLimitForTesting: Int {
        TerminalMemoryBudgetAuthority.shared.maxRetainedBytes
    }
    func reclaimTerminalMemoryForTesting() { reclaimTerminalMemoryUnderPressure() }
    var childPIDForTesting: pid_t { childPID }
    var masterFDForTesting: Int32 { masterFD }
    var processTreeSignalCountForTestingValue: Int { processTreeSignalCountForTesting }

    var readerAllowsRenderForTesting: Bool {
        readerAllowsRender
    }

    /// Whether Ghostty still has an owner input callback (PTY write path live).
    var ghosttyInputHandlerPresentForTesting: Bool {
        ghosttyView.hasInputDataHandlerForTesting
    }

    /// Drive the history-replay surface recreate path without a disk restore.
    func replayResetSurfaceOutputForTesting(_ data: Data) {
        beginGhosttyHistoryReplay(data)
    }

    /// Capture Ghostty→owner input writes (tests only).
    func replaceInputCaptureForTesting(_ handler: @escaping (Data) -> Void) {
        ghosttyView.onInputData = handler
    }

    /// Simulate Ghostty's io_write callback after surface recreate.
    func injectGhosttyInputWriteForTesting(_ data: Data) {
        ghosttyView.writeInputData(data)
    }

    var ptyWinsizeCommitCountForTesting: Int {
        ptyWinsizeCommitCountForTestingValue
    }

    var lastCommittedPTYSizeForTesting: TerminalViewportSize? {
        lastCommittedPTYSize
    }

    /// Test seam: drive the same size path Ghostty uses on layout/reattach.
    /// `force` mirrors the spawn one-shot path (commit even if not yet visible).
    func applyViewportSizeForTesting(_ size: TerminalViewportSize, force: Bool = false) {
        applyTerminalSize(size, sendToPTY: true, force: force)
    }

    /// Flush a pending debounced PTY winsize commit immediately (tests).
    func flushPendingPTYWinsizeForTesting() {
        flushPendingPTYWinsize()
    }

    /// Inject bytes on the live PTY reader path so tests can exercise hidden
    /// mirror pending/force-flush accounting without `forkpty` (sandbox).
    func injectReaderOutputForTesting(_ data: Data) {
        appendDataAsync(data, renderAllowedAtRead: readerAllowsRender)
    }

    /// Exercise the EOF ordering seam without reaping the test fixture's live
    /// shell. Production reaches the same reader-cancellation and banner paths
    /// from `handlePTYEOF` and its bounded reaper completion.
    func simulateReaderEOFAndExitBannerForTesting(rawStatus: Int32 = 0) {
        cancelPTYReader(preserveHistoryReplayOwnership: historyReplayBackpressureActive)
        appendProcessExitedBannerIfNeeded(rawStatus: rawStatus)
    }

    /// Raw mirror-side retention (pending force-flush queue + legacy heal buffer).
    /// Used by retention tests to prove continuous hidden producers do not pin
    /// a second permanent raw copy alongside Ghostty / history.
    var hiddenMirrorRetainedRawBytesForTesting: Int {
        pendingRendererByteCount + hiddenRendererBuffer.count
    }

    var hiddenMirrorAcceptedBytesForTesting: Int {
        hiddenMirrorAcceptedBytes
    }

    var hiddenRendererBufferOverflowedForTesting: Bool {
        hiddenRendererBufferOverflowed
    }

    func setReaderWillEnterMainHandoffForTesting(_ action: (@Sendable () -> Void)?) {
        readerMainHandoffHook.set(action)
    }

    func setReaderWillPublishForTesting(_ action: (@Sendable (Data) -> Void)?) {
        readerWillPublishHook.set(action)
    }

    func setBeforeLiveHistoryClearForTesting(_ action: (@Sendable () -> Void)?) {
        historyCoordinator.beforeLiveClearForTesting = action
    }

    func setChildReapCompletionForTesting(_ action: (@Sendable () -> Void)?) {
        childReapCompletionHook.set(action)
    }

    func beginChildReapForTesting(pid: pid_t, sendInitialHangup: Bool) {
        beginBoundedChildReap(
            pid: pid,
            foregroundPGID: nil,
            sendInitialHangup: sendInitialHangup
        )
    }

    func setRuntimeDispositionBarrierFactoryForTesting(
        _ factory: ((pid_t) -> SurfaceTerminationBarrier)?
    ) {
        runtimeDispositionBarrierFactoryForTesting = factory
    }

    var ghosttyScrollbackTextForTesting: String? {
        ghosttyView.readScrollbackText()
    }

    /// Post-close probe: Ghostty C surface must be gone after permanent close.
    var hasLiveGhosttySurfaceForTesting: Bool { ghosttyView.hasLiveSurfaceForTesting }

    /// Post-close probe: ANSI mirror ring must shrink after eager close release.
    var ansiMirrorScrollbackRowsForTesting: Int { renderer.scrollbackCount }

    /// Post-close probe: readTextSnapshot cache must not retain transcript text.
    var cachedTextSnapshotRetainedForTesting: Bool { cachedTextSnapshot != nil }

    /// Post-close probe: input pump must be dropped so stall queues cannot pin bytes.
    var inputPumpRetainedForTesting: Bool { inputPump != nil }

    public convenience init(workspaceID: WorkspaceID, cwd: String, title: String = "terminal") throws {
        try self.init(workspaceID: workspaceID, title: title, launch: .shell(cwd: cwd))
    }

    nonisolated static func shouldYieldPTYReadEvent(
        bytesRead: Int,
        readCalls: Int,
        maxBytes: Int,
        maxReadCalls: Int
    ) -> Bool {
        bytesRead >= maxBytes || readCalls >= maxReadCalls
    }

    nonisolated static func shouldAcceptHistoryBacklog(
        queuedBytes: Int,
        incomingBytes: Int,
        maxQueuedBytes: Int
    ) -> Bool {
        TerminalHistoryCoordinator.shouldAcceptBacklog(
            queuedBytes: queuedBytes,
            incomingBytes: incomingBytes,
            maxQueuedBytes: maxQueuedBytes
        )
    }

    /// Delay before the next spawn attempt, or nil when the failure is not
    /// transient. Only EAGAIN is retried: the fork never started.
    nonisolated static func ptySpawnRetryDelay(attempt: Int, errno code: Int32) -> TimeInterval? {
        let delays: [TimeInterval] = [0.1, 0.3]
        guard code == EAGAIN, delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }

    private nonisolated static func spawnPTY(
        cwd: String,
        launch: Launch,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        suspendedBeforeExec: Bool = false
    ) -> (pid: pid_t, masterFD: Int32) {
        let parent = ProcessInfo.processInfo.environment
        let executable: String
        let arguments: [String]
        switch launch {
        case .shell:
            executable = TerminalStartupEnvironment.shellPath(from: parent)
            arguments = ["-" + (executable as NSString).lastPathComponent]
        case .ssh(let profile, _):
            executable = "/usr/bin/ssh"
            arguments = ["ssh"] + SSHCommandBuilder.sshArguments(for: profile)
        case .sshPlaceholder:
            executable = "/usr/bin/false"
            arguments = ["false"]
        }
        let environment = TerminalStartupEnvironment(
            parent: parent,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ).mergedEnvironment(parent: parent)
        return TerminalPTYProcessRuntime.spawn(
            cwd: cwd,
            executable: executable,
            arguments: arguments,
            environment: environment,
            suspendedBeforeExec: suspendedBeforeExec
        )
    }

    /// Spawns and configures the replacement PTY while the current terminal is
    /// still interactive. No reader/history/output path starts until the owner
    /// consumes this runtime after crossing the restart teardown boundary.
    public static func prepareShellRuntimeForRestart(
        workspaceID: WorkspaceID,
        cwd: String,
        surfaceID: SurfaceID,
        closeOnExecEnabler: ((Int32) -> Bool)? = nil,
        nonBlockingEnabler: ((Int32) -> Bool)? = nil,
        onFailureCleanup: ((pid_t, SurfaceTerminationBarrier) -> Void)? = nil
    ) -> TerminalPreparedPTYRuntime? {
        prepareRuntimeForReplacement(
            workspaceID: workspaceID,
            cwd: cwd,
            launch: .shell(cwd: cwd),
            surfaceID: surfaceID,
            closeOnExecEnabler: closeOnExecEnabler,
            nonBlockingEnabler: nonBlockingEnabler,
            onFailureCleanup: onFailureCleanup
        )
    }

    public static func prepareRuntimeForReplacement(
        workspaceID: WorkspaceID,
        cwd: String,
        launch: Launch,
        surfaceID: SurfaceID,
        closeOnExecEnabler: ((Int32) -> Bool)? = nil,
        nonBlockingEnabler: ((Int32) -> Bool)? = nil,
        onFailureCleanup: ((pid_t, SurfaceTerminationBarrier) -> Void)? = nil
    ) -> TerminalPreparedPTYRuntime? {
        let suspendedBeforeExec: Bool
        if case .sshPlaceholder = launch {
            // The immediate-exit fixture remains unsuspended so the production
            // pre-attach liveness gate keeps covering an exited prepared child.
            suspendedBeforeExec = false
        } else {
            suspendedBeforeExec = true
        }
        let spawn = spawnPTY(
            cwd: cwd,
            launch: launch,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            suspendedBeforeExec: suspendedBeforeExec
        )
        guard spawn.pid > 0, spawn.masterFD >= 0 else {
            let failureErrno = errno
            terminalLog.error("terminal.restart_prepare_spawn_failed surface=\(surfaceID.value.uuidString, privacy: .public) errno=\(failureErrno, privacy: .public)")
            return nil
        }

        let lease = TerminalFileDescriptorLease(fd: spawn.masterFD)
        let closeOnExecSucceeded =
            (closeOnExecEnabler ?? TerminalFileDescriptorFlags.enableCloseOnExec)(spawn.masterFD)
        let nonBlockingSucceeded = closeOnExecSucceeded
            && (nonBlockingEnabler ?? TerminalFileDescriptorFlags.enableNonBlocking)(spawn.masterFD)
        guard closeOnExecSucceeded, nonBlockingSucceeded else {
            let failureErrno = errno
            terminalLog.error("terminal.restart_prepare_flags_failed surface=\(surfaceID.value.uuidString, privacy: .public) pid=\(spawn.pid, privacy: .public) errno=\(failureErrno, privacy: .public)")
            let prepared = TerminalPreparedPTYRuntime(
                pid: spawn.pid,
                masterFD: spawn.masterFD,
                lease: lease,
                suspended: suspendedBeforeExec
            )
            if let cleanup = prepared.discard() {
                onFailureCleanup?(spawn.pid, cleanup)
            }
            return nil
        }
        return TerminalPreparedPTYRuntime(
            pid: spawn.pid,
            masterFD: spawn.masterFD,
            lease: lease,
            suspended: suspendedBeforeExec
        )
    }

    public init(
        workspaceID: WorkspaceID,
        title: String,
        launch: Launch,
        restoredSurfaceID: SurfaceID? = nil,
        assignedSurfaceID: SurfaceID? = nil,
        historyRepo: TerminalOutputRepository? = nil,
        settingsRepo: (any SettingsWriteRepository)? = nil,
        terminalFontSize: Double = TerminalFontSizeSetting.defaultSize,
        outputBus: SurfaceOutputBus = .shared,
        preservedDescriptor: SurfaceDescriptor? = nil,
        closeOnExecEnabler: ((Int32) -> Bool)? = nil,
        nonBlockingEnabler: ((Int32) -> Bool)? = nil,
        nonBlockingFailureBarrierFactory: ((pid_t) -> SurfaceTerminationBarrier)? = nil,
        preparedRuntime: TerminalPreparedPTYRuntime? = nil,
        childDispositionObserverTimeout: TimeInterval = TerminalSurface.defaultChildDispositionObserverTimeout
    ) throws {
        self.outputBus = outputBus
        self.childDispositionObserverTimeout = childDispositionObserverTimeout
        let cwd: String
        let type: SurfaceType
        var metadata: [String: String]
        switch launch {
        case .shell(let shellCwd):
            cwd = shellCwd
            type = .terminal
            metadata = ["cwd": shellCwd, "workspace": workspaceID.value.uuidString]
        case .ssh(let profile, let shellCwd):
            cwd = shellCwd
            type = .ssh
            savedSSHPassword = profile.password
            metadata = [
                "cwd": shellCwd,
                "workspace": workspaceID.value.uuidString,
                "ssh_profile_id": profile.id.value.uuidString,
                "ssh_destination": profile.destination,
                "ssh_label": profile.label,
                "ssh_status": "connecting"
            ]
            if let port = profile.port { metadata["ssh_port"] = String(port) }
            if let identity = profile.identityFile { metadata["ssh_identity_file"] = identity }
            if !profile.options.isEmpty { metadata["ssh_options"] = profile.options.joined(separator: "\n") }
        case .sshPlaceholder(let shellCwd):
            cwd = shellCwd
            type = .ssh
            metadata = [
                "cwd": shellCwd,
                "workspace": workspaceID.value.uuidString,
                "ssh_status": "disconnected"
            ]
        }
        let generatedDescriptor = SurfaceDescriptor(
            id: restoredSurfaceID ?? assignedSurfaceID ?? SurfaceID(),
            type: type,
            title: title,
            iconName: type == .ssh ? "network" : "terminal",
            metadata: metadata
        )
        if let preservedDescriptor {
            precondition(
                preservedDescriptor.type == type,
                "a restarted terminal must preserve a descriptor of the same surface type"
            )
            self.descriptor = preservedDescriptor
        } else {
            self.descriptor = generatedDescriptor
        }
        self.historyCoordinator = TerminalHistoryCoordinator(
            repository: historyRepo,
            surfaceID: descriptor.id.value.uuidString,
            workspaceID: workspaceID.value.uuidString
        )

        // Match cmux/Ghostty's defensive startup sizing: begin with a
        // non-zero view so AppKit has real bounds before the first resize.
        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: 800,
            height: 600
        )
        let terminalView = GhosttyTerminalView(frame: initialFrame)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.fontZoomStore = settingsRepo
        terminalView.fontZoomWorkspaceID = workspaceID.value.uuidString
        terminalView.baseFontSize = TerminalFontSizeSetting.normalized(terminalFontSize)
        terminalView.setAccessibilityIdentifier("surface.terminal.view.\(descriptor.id.value.uuidString)")
        self.ghosttyView = terminalView
        let container = TerminalDropContainerView(frame: initialFrame)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityIdentifier("surface.terminal.\(descriptor.id.value.uuidString)")
        container.wantsLayer = true
        container.layer?.backgroundColor = DS.NS.terminalBG.cgColor
        container.layer?.masksToBounds = true
        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        self.view = container

        super.init()
        historyCoordinator.delegate = self
        let startsVisible = restoredSurfaceID == nil
        isVisible = startsVisible
        readerAllowsRender = startsVisible
        terminalView.setOcclusion(visible: startsVisible)
        // PERF (cold launch): restored tabs start hidden. Defer disk history
        // replay until the surface becomes visible (or another demand path)
        // so multi-terminal restore does not fan out N concurrent SQLite
        // reads + Ghostty resets during `reinstantiateRestoredSurfaces`.
        historyCoordinator.prepare(
            restored: restoredSurfaceID != nil,
            deferReplay: restoredSurfaceID != nil
        )

        terminalView.onInputData = { [weak self] data in
            guard let self else { return }
            let status = self.writeToPTY(data)
            if status != .accepted, !self.didBeepForDeadInput {
                self.didBeepForDeadInput = true
                NSSound.beep()
            }
        }
        terminalView.onTitleChange = { [weak self] title in
            self?.handleOSCTitle(title)
        }
        terminalView.onProgressReport = { [weak self] active in
            self?.handleProgressReport(active: active)
        }
        terminalView.onCommandFinished = { [weak self] exitCode in
            self?.handleCommandFinished(exitCode: exitCode)
        }
        // Audit #4: let the view distinguish a legitimate teardown from a stray close
        // of a still-visible instance. A deallocated owner reports "closing" (true).
        terminalView.ownerIsClosing = { [weak self] in self?.isClosing ?? true }
        terminalView.onHistoryReplayDrainCompleted = { [weak self] in
            self?.endGhosttyHistoryReplayBackpressure()
        }
        terminalView.nextHistoryReplayContinuation = { [weak self] in
            self?.takeNextOwnedGhosttyReplayOutput()
        }
        terminalView.onOutputCapacityAvailable = { [weak self] in
            self?.reconcileLiveOutputBackpressure()
            self?.pumpSystemOutput()
        }
        // Forward paste-confirmation requests from the Ghostty view to any
        // app-level handler wired on this surface (e.g. AppCommandRouter).
        terminalView.onPasteNeedsConfirm = { [weak self] (text: String) in
            self?.confirmUnsafeTerminalInput(text)
        }
        terminalView.onPlainTextDragNeedsConfirm = { [weak self] text in
            self?.confirmUnsafeTerminalInput(text)
        }
        terminalView.onTerminalSizeChange = { [weak self] size in
            guard let self else { return }
            self.applyTerminalSize(size, sendToPTY: self.masterFD >= 0)
        }
        container.onFileDrop = { [weak self] paths in
            guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return }
            _ = self?.writeToPTY(data)
        }
        container.onLayout = { [weak self, weak container] in
            guard let self,
                  !self.isClosing,
                  self.isVisible,
                  container?.window != nil else { return }
            self.ghosttyView.refreshSurfaceOnly()
        }
        container.onWindowChanged = { [weak self] window in
            self?.handleContainerWindowChanged(window)
        }
        terminalMemoryBudgetToken = TerminalMemoryBudgetAuthority.shared.register(
            owner: self,
            retainedBytes: { [weak self] in self?.terminalMemoryRetainedBytes ?? 0 },
            priority: { [weak self] in self?.terminalMemoryReclaimPriority ?? 0 },
            reclaim: { [weak self] in self?.reclaimTerminalMemoryUnderPressure() },
            pressureState: { [weak self] in self?.terminalMemoryPressureState ?? .compacted }
        )
        applyTerminalSize(TerminalViewportGeometry.fallbackSize, sendToPTY: false, force: true)
        replayPersistedHistoryIfNeeded()

        if case .sshPlaceholder = launch {
            appendString(L("[ssh disconnected]\nSelect a saved SSH host or add a new one to connect.\n"))
            terminalDeadReason = "ssh_disconnected"
            publishRuntimeHealth()
            return
        }

        let pid: pid_t
        let amaster: Int32
        let masterFDLease: TerminalFileDescriptorLease
        let descriptorFlagsAlreadyConfigured: Bool
        let preparedRuntimeWasSuspended: Bool
        if let preparedRuntime {
            let prepared = preparedRuntime.takeOwnership()
            pid = prepared.pid
            amaster = prepared.masterFD
            masterFDLease = prepared.lease
            descriptorFlagsAlreadyConfigured = true
            preparedRuntimeWasSuspended = prepared.wasSuspended
        } else {
            var spawn = Self.spawnPTY(
                cwd: cwd,
                launch: launch,
                workspaceID: workspaceID,
                surfaceID: descriptor.id
            )
            var spawnErrno = errno
            var spawnAttempt = 0
            while spawn.pid < 0, let delay = Self.ptySpawnRetryDelay(attempt: spawnAttempt, errno: spawnErrno) {
                spawnAttempt += 1
                Thread.sleep(forTimeInterval: delay)
                spawn = Self.spawnPTY(
                    cwd: cwd,
                    launch: launch,
                    workspaceID: workspaceID,
                    surfaceID: descriptor.id
                )
                spawnErrno = errno
            }
            pid = spawn.pid
            amaster = spawn.masterFD
            if pid < 0 {
                appendString(L("[forkpty failed: %1$@]\n", String(cString: strerror(spawnErrno))))
                terminalDeadReason = "fork_failed"
                terminalLog.error("terminal.spawn_failed surface=\(self.descriptor.id.value.uuidString, privacy: .public) errno=\(spawnErrno, privacy: .public)")
                publishRuntimeHealth()
                return
            }
            masterFDLease = TerminalFileDescriptorLease(fd: amaster)
            descriptorFlagsAlreadyConfigured = false
            preparedRuntimeWasSuspended = false
        }
        self.masterFD = amaster
        self.masterFDLease = masterFDLease
        self.childPID = pid
        self.childReapForegroundGroup = nil
        self.lastCapturedForegroundGroup = nil
        self.applicationTerminationBarrier = nil
        self.processAlive = true
        self.exitStatus = nil
        self.terminationSignal = nil
        self.terminalDeadReason = nil
        self.didAppendProcessExitedBanner = false
        self.lastOutputAt = Date()
        let closeOnExecSucceeded = descriptorFlagsAlreadyConfigured
            || (closeOnExecEnabler ?? TerminalFileDescriptorFlags.enableCloseOnExec)(amaster)
        let nonBlockingSucceeded = descriptorFlagsAlreadyConfigured
            || (closeOnExecSucceeded
                && (nonBlockingEnabler ?? TerminalFileDescriptorFlags.enableNonBlocking)(amaster))
        let preparedResumeSucceeded = !preparedRuntimeWasSuspended
            || TerminalPTYProcessRuntime.resumeOwnedLiveChild(pid: pid)
        if !closeOnExecSucceeded || !nonBlockingSucceeded || !preparedResumeSucceeded {
            let failure = String(cString: strerror(errno))
            let failureReason: String
            if !closeOnExecSucceeded {
                failureReason = "pty_cloexec_failed"
            } else if !nonBlockingSucceeded {
                failureReason = "pty_nonblocking_failed"
            } else {
                failureReason = "prepared_runtime_resume_failed"
            }
            terminalLog.error("terminal.flags_failed surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public) reason=\(failureReason, privacy: .public) error=\(failure, privacy: .public)")
            masterFDLease.close()
            self.masterFD = -1
            self.masterFDLease = nil
            self.processAlive = false
            self.terminalDeadReason = failureReason
            let dispositionBarrier: SurfaceTerminationBarrier
            if let nonBlockingFailureBarrierFactory {
                dispositionBarrier = nonBlockingFailureBarrierFactory(pid)
            } else {
                let work = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
                    pid: pid,
                    foregroundGroup: nil
                )
                dispositionBarrier = SurfaceTerminationBarrier(
                    groups: [work.group],
                    completionChecks: [work.succeeded]
                )
            }
            self.applicationTerminationBarrier = dispositionBarrier
            let observerDeadline = DispatchTime.now() + childDispositionObserverTimeout
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let succeeded = dispositionBarrier.wait(until: observerDeadline)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.childPID == pid else { return }
                    if succeeded {
                        self.childPID = -1
                        self.childReapInFlightPID = nil
                    } else {
                        self.terminalDeadReason = "process_reap_timeout"
                        terminalLog.error("terminal.reap_timeout surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public) reason=nonblocking_setup_failed")
                    }
                    self.publishRuntimeHealth()
                }
            }
            appendString(L("[PTY descriptor setup failed; shell stopped]\r\n"))
            publishRuntimeHealth()
            return
        }
        configureInputPump(lease: masterFDLease)
        applyTerminalSize(terminalSize, sendToPTY: true, force: true)
        startReader()
        terminalLog.info("terminal.spawned surface=\(self.descriptor.id.value.uuidString, privacy: .public) type=\(self.descriptor.type.rawValue, privacy: .public) pid=\(pid, privacy: .public) rows=\(self.terminalSize.rows, privacy: .public) cols=\(self.terminalSize.cols, privacy: .public)")
        if case .ssh(let profile, _) = launch {
            awaitingSSHFirstOutput = true
            let host = profile.label.isEmpty ? profile.destination : profile.label
            appendString(L("[connecting to %1$@…]\r\n", host))
        }
        publishRuntimeHealth()
    }

    private func applyTerminalSize(_ size: TerminalViewportSize, sendToPTY: Bool, force: Bool = false) {
        guard force || size != terminalSize else { return }
        terminalSize = size
        // Preserve ordering vs pending visible bytes (PERF-136): if visible feed
        // events are queued, this resize must be applied AFTER them, otherwise the
        // already-received bytes would be reflowed at the wrong dimensions. Record
        // it in the same ordered buffer. When nothing is pending, apply now
        // (current behavior, safe). Ghostty/ANSI track size immediately; PTY
        // winsize is gated separately so hide/park/layout thrash cannot SIGWINCH
        // the shell into prompt-spam garbling.
        if pendingRendererEvents.isEmpty {
            renderer.resize(rows: size.rows, cols: size.cols)
        } else {
            pendingRendererEvents.append(.resize(rows: size.rows, cols: size.cols))
            if Self.pendingRendererBufferExceeded(
                byteCount: pendingRendererByteCount,
                eventCount: pendingRendererEvents.count
            ) {
                ensureRendererCurrent()
            }
        }
        rendererMutationCount &+= 1
        outputBus.emitGeometry(descriptor.id, rows: size.rows, cols: size.cols)
        guard sendToPTY else { return }
        if force {
            // Spawn / explicit one-shot paths (initial geometry) may commit even
            // when the surface is not yet registry-visible.
            commitPTYWinsize(size)
            return
        }
        let parked = view.window != nil && view.window === parkingWindow
        let hasUsableBounds = view.bounds.width > 1 && view.bounds.height > 1
        guard Self.shouldPropagateInteractiveWinsize(
            isVisible: isVisible,
            parked: parked,
            hasUsableBounds: hasUsableBounds
        ) else {
            // Drop any in-flight interactive commit while hidden/parked so a
            // stale intermediate size cannot land after didBecomeHidden.
            cancelPendingPTYWinsize()
            return
        }
        scheduleDebouncedPTYWinsize(size)
    }

    /// Whether an interactive (layout/reattach-driven) geometry change may push
    /// `TIOCSWINSZ` to the live PTY. Frozen while hidden or parked so workspace
    /// switch teardown does not SIGWINCH-storm the shell into prompt garbling.
    nonisolated static func shouldPropagateInteractiveWinsize(
        isVisible: Bool,
        parked: Bool,
        hasUsableBounds: Bool
    ) -> Bool {
        isVisible && !parked && hasUsableBounds
    }

    private func scheduleDebouncedPTYWinsize(_ size: TerminalViewportSize) {
        pendingPTYWinsize = size
        ptyWinsizeDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingPTYWinsize()
        }
        ptyWinsizeDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.ptyWinsizeDebounceInterval,
            execute: work
        )
    }

    private func cancelPendingPTYWinsize() {
        ptyWinsizeDebounceWorkItem?.cancel()
        ptyWinsizeDebounceWorkItem = nil
        pendingPTYWinsize = nil
    }

    private func flushPendingPTYWinsize() {
        ptyWinsizeDebounceWorkItem = nil
        guard let size = pendingPTYWinsize else { return }
        pendingPTYWinsize = nil
        let parked = view.window != nil && view.window === parkingWindow
        let hasUsableBounds = view.bounds.width > 1 && view.bounds.height > 1
        guard Self.shouldPropagateInteractiveWinsize(
            isVisible: isVisible,
            parked: parked,
            hasUsableBounds: hasUsableBounds
        ) else { return }
        commitPTYWinsize(size)
    }

    private func commitPTYWinsize(_ size: TerminalViewportSize) {
        guard lastCommittedPTYSize != size else { return }
        lastCommittedPTYSize = size
        ptyWinsizeCommitCountForTestingValue &+= 1
        cancelPendingPTYWinsize()
        guard masterFD >= 0 else { return }
        _ = rc2_set_winsize(masterFD, Int32(size.rows), Int32(size.cols))
    }

    private func startReader() {
        let fd = masterFD
        guard let lease = masterFDLease else { return }
        let queue = DispatchQueue(
            label: "rc2.terminal.pty-reader.\(descriptor.id.value.uuidString)",
            qos: .userInitiated
        )
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource = src
        // The read source owns the fd. It is closed here — on the source's own
        // queue, after the final event handler returns — so the main thread never
        // closes masterFD out from under an in-flight background read() (data race
        // + closed-fd / fd-reuse hazard). Normal close/EOF only cancel; the
        // app-termination path may close the same lease synchronously because
        // reader and writer syscalls are serialized by its lock.
        src.setCancelHandler { lease.close() }
        let readerMainHandoffHook = self.readerMainHandoffHook
        let readerHandoffState = self.readerHandoffState
        let readerWillPublishHook = self.readerWillPublishHook
        var buf = [UInt8](repeating: 0, count: 4096)
        src.setEventHandler { [weak self] in
            guard let self, readerHandoffState.beginReadEvent() else { return }
            var output = Data()
            var shouldClose = false
            var readCalls = 0

            while true {
                let n = buf.withUnsafeMutableBytes { lease.read(into: $0) }
                if n > 0 {
                    output.append(contentsOf: buf[0..<Int(n)])
                    readCalls += 1
                    if Self.shouldYieldPTYReadEvent(
                        bytesRead: output.count,
                        readCalls: readCalls,
                        maxBytes: Self.maxPTYReadEventBytes,
                        maxReadCalls: Self.maxPTYReadCallsPerEvent
                    ) {
                        break
                    }
                    continue
                }
                if n == 0 {
                    shouldClose = true
                    break
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                shouldClose = true
                break
            }

            readerWillPublishHook.fire(output)
            let batchID = readerHandoffState.publish(
                data: output,
                shouldClose: shouldClose,
                readCalls: readCalls
            )
            guard let batchID else { return }
            // A synchronous, bounded handoff is intentional backpressure: at
            // most one 256 KiB event per terminal can wait on the main actor.
            // The batch is first placed in an ownership mailbox so quit can
            // claim bytes already read before finalizing durable history.
            readerMainHandoffHook.fire()
            let handoffBlock = {
                guard let batch = readerHandoffState.claim(batchID) else { return }
                if !batch.data.isEmpty {
                    self.maxPTYReadBatchBytesObserved = max(
                        self.maxPTYReadBatchBytesObserved,
                        batch.data.count
                    )
                    self.maxPTYReadCallsObserved = max(
                        self.maxPTYReadCallsObserved,
                        batch.readCalls
                    )
                    self.appendDataAsync(
                        batch.data,
                        renderAllowedAtRead: self.readerAllowsRender
                    )
                }
                if batch.shouldClose {
                    self.handlePTYEOF()
                }
            }
            if Thread.isMainThread {
                handoffBlock()
            } else {
                DispatchQueue.main.sync(execute: handoffBlock)
            }
        }
        if historyReplayBackpressureActive || liveOutputBackpressureActive || systemOutputStreaming {
            // Dispatch sources are created suspended. Leave this one suspended
            // until the bounded Ghostty queue drains; the PTY kernel then
            // supplies the backpressure without a second userspace byte queue.
            readSourceSuspendedForBackpressure = true
        } else {
            src.resume()
        }
    }

    private func beginGhosttyHistoryReplay(_ data: Data) {
        // A correctness-demand read can arrive while a restored terminal has no
        // pane/window. Give it a hidden AppKit host when possible. If Ghostty
        // still cannot create a parser (for example, display asleep or native
        // rendering disabled in tests), retain the bounded canonical stream and
        // keep the PTY reader moving; attachment will retry later.
        if !ghosttyView.hasLiveSurfaceForTesting, view.window == nil, !isVisible {
            parkInHiddenWindowIfNeeded()
        }
        guard ghosttyView.prepareHistoryReplayHost() else {
            deferredUnhostedGhosttyReplay = data
            return
        }
        deferredUnhostedGhosttyReplay = nil
        historyReplayBackpressureActive = true
        suspendReaderForBackpressure()
        guard ghosttyView.resetSurfaceOutput(data) else {
            endGhosttyHistoryReplayBackpressure()
            return
        }
        if !ghosttyView.historyReplayDrainInProgressForTesting {
            endGhosttyHistoryReplayBackpressure()
        }
    }

    private func endGhosttyHistoryReplayBackpressure() {
        historyReplayBackpressureActive = false
        defer { touchTerminalMemoryBudget() }
        reconcileLiveOutputBackpressure()
        resumeReaderIfBackpressureCleared()
        pumpSystemOutput()
    }

    public func reserveSystemOutput() -> SystemOutputLease? {
        guard !isClosing, systemOutput == nil else { return nil }
        let lease = SystemOutputLease(surface: self)
        systemOutput = lease
        return lease
    }

    fileprivate func startSystemOutput(_ lease: SystemOutputLease) {
        guard systemOutput === lease, !isClosing else { return }
        lease.delivering = true
        suspendReaderForBackpressure()
        scheduleSystemOutputPump()
    }

    private func scheduleSystemOutputPump() {
        guard !systemOutputPumpScheduled else { return }
        systemOutputPumpScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.systemOutputPumpScheduled = false
            self.pumpSystemOutput()
        }
    }

    /// One bounded slice per main-queue turn keeps mirror parsing responsive even
    /// without a native parser. Capacity and replay callbacks restart a paused source.
    private func pumpSystemOutput() {
        guard let lease = systemOutput, lease.delivering, !isClosing,
              !historyReplayBackpressureActive, ownedGhosttyReplayOutput.isEmpty else { return }
        if ghosttyView.drainsOutputNatively,
           !ghosttyView.hasOutputCapacity(forHandoffBytes: Self.ptyHandoffReserveBytes) { return }
        guard let slice = lease.nextSlice(maxBytes: GhosttyTerminalView.historyReplayChunkBytes) else {
            finishSystemOutput(lease)
            return
        }
        deliverSystemData(slice)
        scheduleSystemOutputPump()
    }

    /// Ends the stream (complete or cancelled), then replays what waited behind it.
    fileprivate func finishSystemOutput(_ lease: SystemOutputLease) {
        guard systemOutput === lease else { return }
        systemOutput = nil
        lease.finished = true
        lease.parts = []
        let held = heldBehindSystemOutput
        heldBehindSystemOutput = []
        heldBehindSystemOutputBytes = 0
        for item in held {
            switch item {
            case .pty(let data, let renderAllowed): appendDataAsync(data, renderAllowedAtRead: renderAllowed)
            case .system(let data): deliverSystemData(data)
            }
        }
        resumeReaderIfBackpressureCleared()
        touchTerminalMemoryBudget()
    }

    private func holdBehindSystemOutput(_ item: HeldOutput, bytes: Int) {
        guard bytes <= Self.maxOwnedGhosttyReplayOutputBytes - heldBehindSystemOutputBytes else {
            outputPartial = true
            outputPartialReason = outputPartialReason ?? "system_output_held_cap"
            terminalLog.error("terminal.system_output_held_cap surface=\(self.descriptor.id.value.uuidString, privacy: .public) bytes=\(bytes, privacy: .public)")
            return
        }
        heldBehindSystemOutput.append(item)
        heldBehindSystemOutputBytes += bytes
    }

    /// Reclaim skipped while handoffs were owner-held; run it again off this call stack.
    private func recheckTerminalMemoryBudgetSoon() {
        DispatchQueue.main.async { [weak self] in self?.touchTerminalMemoryBudget() }
    }

    private func suspendReaderForBackpressure() {
        guard let readSource, !readSourceSuspendedForBackpressure else { return }
        readSource.suspend()
        readSourceSuspendedForBackpressure = true
    }

    private func resumeReaderIfBackpressureCleared() {
        guard readSourceSuspendedForBackpressure,
              !historyReplayBackpressureActive,
              !liveOutputBackpressureActive,
              !systemOutputStreaming else { return }
        readSourceSuspendedForBackpressure = false
        readSource?.resume()
    }

    /// Live saturation control. Replays own their own pacing, so this only acts
    /// outside them: it delivers owner-held handoffs to Ghostty in FIFO order as
    /// capacity returns, pauses the PTY reader before a full handoff could be
    /// rejected, and resumes it once the queue is at most half full.
    private func reconcileLiveOutputBackpressure() {
        guard !historyReplayBackpressureActive, !isClosing else { return }
        while let next = ownedGhosttyReplayOutput.first {
            guard ghosttyView.processOutput(next, render: renderDiagnostics().canRender) else {
                return
            }
            ownedGhosttyReplayOutput.removeFirst()
            ownedGhosttyReplayOutputBytes -= next.count
            if ownedGhosttyReplayOutput.isEmpty { recheckTerminalMemoryBudgetSoon() }
        }
        let full = ghosttyView.drainsOutputNatively
            && !ghosttyView.hasOutputCapacity(forHandoffBytes: Self.ptyHandoffReserveBytes)
        if full {
            liveOutputBackpressureActive = true
            suspendReaderForBackpressure()
            return
        }
        guard liveOutputBackpressureActive else { return }
        let drained = !ghosttyView.drainsOutputNatively
            || ghosttyView.outputBytesOwned <= GhosttyTerminalView.maxPendingOutputBytes / 2
        guard drained else { return }
        liveOutputBackpressureActive = false
        resumeReaderIfBackpressureCleared()
    }

    private func takeNextOwnedGhosttyReplayOutput() -> Data? {
        guard !ownedGhosttyReplayOutput.isEmpty else { return nil }
        let next = ownedGhosttyReplayOutput.removeFirst()
        ownedGhosttyReplayOutputBytes -= next.count
        if ownedGhosttyReplayOutput.isEmpty { recheckTerminalMemoryBudgetSoon() }
        return next
    }

    private func processGhosttyOutput(_ data: Data, render: Bool) {
        // Once a handoff is owner-held, it is the FIFO gate. Offering a newer
        // chunk directly to Ghostty after one 8 KiB replay slice frees capacity
        // would allow that newer chunk to parse before the older handoff.
        if !ownedGhosttyReplayOutput.isEmpty {
            retainGhosttyReplayOutput(data)
            return
        }
        guard !ghosttyView.processOutput(data, render: render) else {
            if !historyReplayBackpressureActive { reconcileLiveOutputBackpressure() }
            return
        }
        retainGhosttyReplayOutput(data)
    }

    private func retainGhosttyReplayOutput(_ data: Data) {
        // Backpressure owns every rejected handoff explicitly. The PTY reader is
        // suspended, so production can contribute at most one 256 KiB batch; local
        // notices stay ordered behind it and are transferred back to Ghostty whole
        // by `nextHistoryReplayContinuation` (replay) or the capacity callback (live).
        guard data.count <= Self.maxOwnedGhosttyReplayOutputBytes - ownedGhosttyReplayOutputBytes else {
            // App-generated notices can still arrive while the PTY reader is
            // suspended. Bound that auxiliary queue too and fail loudly rather
            // than turning a replay fix into another weeks-long memory leak.
            outputPartial = true
            outputPartialReason = outputPartialReason ?? "ghostty_replay_owner_cap"
            terminalLog.error("terminal.ghostty_replay_owner_cap surface=\(self.descriptor.id.value.uuidString, privacy: .public) bytes=\(data.count, privacy: .public) ownedBytes=\(self.ownedGhosttyReplayOutputBytes, privacy: .public)")
            return
        }
        ownedGhosttyReplayOutput.append(data)
        ownedGhosttyReplayOutputBytes += data.count
        guard !historyReplayBackpressureActive else { return }
        liveOutputBackpressureActive = true
        suspendReaderForBackpressure()
        reconcileLiveOutputBackpressure()
    }

    private func extendDeferredUnhostedReplay(_ data: Data) {
        guard var deferred = deferredUnhostedGhosttyReplay else { return }
        let remaining = max(
            0,
            TerminalHistoryCoordinator.maxCanonicalReplayBytes - deferred.count
        )
        guard data.count <= remaining else {
            deferredUnhostedGhosttyReplay = nil
            outputPartial = true
            outputPartialReason = outputPartialReason ?? "history_replay_live_cap"
            return
        }
        deferred.append(data)
        deferredUnhostedGhosttyReplay = deferred
    }

    private func cancelPTYReader(preserveHistoryReplayOwnership: Bool = false) {
        if !preserveHistoryReplayOwnership {
            historyReplayBackpressureActive = false
        }
        if readSourceSuspendedForBackpressure {
            // A suspended DispatchSource must be balanced before cancellation
            // can deliver its cancel handler and release the file descriptor.
            readSourceSuspendedForBackpressure = false
            readSource?.resume()
        }
        readSource?.cancel()
        readSource = nil
    }

    private func handlePTYEOF() {
        terminalLog.info("terminal.pty_eof surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(self.childPID, privacy: .public)")
        let foregroundPGID = foregroundProcessGroup()
        cancelPTYReader(
            preserveHistoryReplayOwnership: historyReplayBackpressureActive
        )   // cancel handler closes the fd on the source's queue
        masterFD = -1
        let pid = childPID
        markTerminalDead(reason: "process_exited", exitStatus: nil, appendExitBanner: false)
        if pid > 0 {
            beginBoundedChildReap(
                pid: pid,
                foregroundPGID: foregroundPGID,
                sendInitialHangup: false
            )
        }
    }

    private func beginBoundedChildReap(
        pid: pid_t,
        foregroundPGID: pid_t?,
        sendInitialHangup: Bool
    ) {
        guard pid > 0 else { return }
        let foregroundGroup = resolvedForegroundGroupForReap(pid: pid, foregroundPGID: foregroundPGID)
        childReapForegroundGroup = foregroundGroup
        lastCapturedForegroundGroup = nil
        if childReapInFlightPID == pid {
            // The serial reaper already owns escalation. It may have consumed
            // waitpid while its MainActor completion is still queued; signalling
            // the stale numeric PID here can hit an unrelated reused process.
            return
        }
        childReapInFlightPID = pid
        if sendInitialHangup {
            processTreeSignalCountForTesting += 1
            TerminalPTYProcessRuntime.signalProcessTree(
                pid: pid,
                foregroundGroup: foregroundGroup,
                signal: SIGHUP
            )
        }
        // Tab close / EOF keep the normal reaper (status, banner, escalation timing).
        // reapWithEscalation registers joinable work so applicationWillTerminate can
        // wait via activeProcessDispositionBarrier after SurfaceRegistry unregister.
        TerminalPTYProcessRuntime.reapWithEscalation(
            pid: pid,
            foregroundGroup: foregroundGroup,
            initialHangupAlreadySent: sendInitialHangup
        ) { [weak self] result in
            self?.childReapCompletionHook.fire()
            DispatchQueue.main.async {
                guard let self, self.childReapInFlightPID == pid else { return }
                self.childReapInFlightPID = nil
                self.childReapForegroundGroup = nil
                guard self.childPID == pid else { return }
                if result.shellReaped {
                    self.childPID = -1
                }
                if result.timedOut {
                    self.terminalDeadReason = "process_reap_timeout"
                    terminalLog.error("terminal.reap_timeout surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public) foregroundGroupRemaining=\(result.foregroundGroupRemaining, privacy: .public)")
                }
                if let status = result.status {
                    self.exitStatus = status
                    if (status & 0x7F) != 0 {
                        self.terminationSignal = status & 0x7F
                    }
                }
                self.appendProcessExitedBannerIfNeeded(rawStatus: result.status)
                self.publishRuntimeHealth()
            }
        }
    }

    private func resolvedForegroundGroupForReap(
        pid: pid_t,
        foregroundPGID: pid_t?
    ) -> TerminalPTYProcessRuntime.CapturedForegroundProcessGroup? {
        if let freshlyCaptured = TerminalPTYProcessRuntime.captureForegroundProcessGroup(
            pgid: foregroundPGID,
            shellPID: pid
        ) {
            return freshlyCaptured
        }
        if let activeReapGroup = childReapForegroundGroup,
           activeReapGroup.sessionID == pid,
           foregroundPGID == nil || foregroundPGID == activeReapGroup.pgid {
            return activeReapGroup
        }
        return lastCapturedForegroundGroup.flatMap { captured in
            captured.sessionID == pid && (foregroundPGID == nil || foregroundPGID == captured.pgid)
                ? captured
                : nil
        }
    }

    private func appendDataAsync(_ data: Data, renderAllowedAtRead: Bool) {
        guard !isClosing else { return }
        guard !systemOutputStreaming else {
            holdBehindSystemOutput(.pty(data, renderAllowedAtRead: renderAllowedAtRead), bytes: data.count)
            return
        }
        recordHistoryReplayLiveData(data)
        // Audit #3: if output is arriving while we believe the surface is hidden but
        // its view is demonstrably on a key, on-screen window, the visibility reconcile
        // desynced (a missed/incorrect setVisibleSurfaceIDs) and readerAllowsRender +
        // occlusion are latched OFF — nothing repaints (the freeze). Recovery normally
        // depends only on a future reconcile the user cannot trigger by scrolling or
        // typing. Fail loud and self-heal locally so the live terminal un-freezes.
        if !stuckHiddenHealScheduled,
           Self.shouldRunStuckHiddenHeal(
               isClosing: isClosing,
               isVisible: isVisible,
               viewDefinitelyOnScreen: ghosttyView.isDefinitelyOnScreen
           ) {
            // DEFER the heal to the next tick: this chunk must first land in the
            // hidden path (hiddenRendererBuffer + outputPendingBytes) consistently with
            // the render decision captured for it. Healing inline would flip visibility
            // mid-chunk and orphan these bytes out of the ANSIRenderer mirror (a gap in
            // ansiText) while leaving outputPendingBytes latched. didBecomeVisible() then
            // replays the now-complete buffer. The flag bounds this to once per episode.
            stuckHiddenHealScheduled = true
            terminalLog.error("terminal.stuck_hidden_recover surface=\(self.descriptor.id.value.uuidString, privacy: .public) — output arrived while logically hidden but the view is on a key on-screen window; self-healing (audit #3)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stuckHiddenHealScheduled = false
                guard Self.shouldRunStuckHiddenHeal(
                    isClosing: self.isClosing,
                    isVisible: self.isVisible,
                    viewDefinitelyOnScreen: self.ghosttyView.isDefinitelyOnScreen
                ) else { return }
                self.didBecomeVisible()
            }
        }
        enqueueHistory(data)
        recordOutputTelemetry(bytes: data.count)
        if awaitingSSHFirstOutput {
            awaitingSSHFirstOutput = false
            descriptor.metadata["ssh_status"] = "connected"
        }
        autoSubmitSavedSSHPasswordIfNeeded(from: data)
        if Self.containsVisibleOutput(data) { lastOutputAt = Date() }
        // BEL (0x07): keep activity feedback non-visual. Some long-running CLIs
        // emit repeated bells, and repainting the terminal background reads as
        // pane flicker. Use BellDetector so that 0x07 acting as an OSC string-
        // terminator (e.g. inside ESC ] 0 ; title BEL) does not trigger a false
        // unread-activity dot (UX-TERM-BEL-FALSE-POSITIVE).
        if BellDetector.containsStandaloneBEL(data) { handleBell() }
        // HC-1: stream raw PTY output to the mirror in real time.
        outputBus.emit(descriptor.id, data)
        // PERF-136 (visible + hidden): record mirror feed/resize into the ordered
        // pending queue and force-flush into the capped ANSI ring. A separate
        // permanent raw `hiddenRendererBuffer` grew for the entire hidden lifetime
        // (up to 4 MiB per terminal) under multi-terminal soak workloads — dual
        // retention beside Ghostty scrollback — so pre-gate RSS never plateaued.
        // Force-flush keeps recoverability of recent transcript in the ANSI ring
        // (same as visible) and tracks the 4 MiB budget only for partial truth.
        pendingRendererEvents.append(.bytes(data))
        pendingRendererByteCount += data.count
        rendererMutationCount &+= 1
        if !renderAllowedAtRead {
            hiddenMirrorAcceptedBytes += data.count
            if hiddenMirrorAcceptedBytes > Self.maxHiddenRendererBufferBytes,
               !hiddenRendererBufferOverflowed {
                hiddenRendererBufferOverflowed = true
                outputPartial = true
                if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                    outputPartialReason = "hidden_output_cap"
                }
            }
        }
        if Self.pendingRendererBufferExceeded(
            byteCount: pendingRendererByteCount,
            eventCount: pendingRendererEvents.count
        ) {
            ensureRendererCurrent()
        }
        extendDeferredUnhostedReplay(data)
        if renderAllowedAtRead, renderDiagnostics().canRender {
            processGhosttyOutput(data, render: true)
        } else {
            outputPendingBytes += data.count
            // Process THIS chunk into the surface BEFORE the drain may force-complete
            // (#5): completeHiddenBacklogDrain refreshes, and refreshing before the
            // chunk is fed would paint a frame missing the latest bytes.
            processGhosttyOutput(data, render: false)
            continueHiddenBacklogDrainIfNeeded()
        }
        if ghosttyView.droppedOutputBytes > 0 {
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "ghostty_buffer_cap"
            }
        }
        touchTerminalMemoryBudget(addedBytes: data.count, force: false)
        scheduleBusyStateRefresh()
    }

    private func appendString(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        guard !systemOutputStreaming else {
            holdBehindSystemOutput(.system(data), bytes: data.count)
            return
        }
        deliverSystemData(data)
    }

    private func deliverSystemData(_ data: Data) {
        recordHistoryReplayLiveData(data)
        enqueueHistory(data)
        recordOutputTelemetry(bytes: data.count)
        // Route through the same ordered pending buffer (PERF-136) so an injected
        // string stays ordered relative to any pending visible output bytes.
        pendingRendererEvents.append(.bytes(data))
        pendingRendererByteCount += data.count
        rendererMutationCount &+= 1
        if Self.pendingRendererBufferExceeded(
            byteCount: pendingRendererByteCount,
            eventCount: pendingRendererEvents.count
        ) {
            ensureRendererCurrent()
        }
        if Self.containsVisibleOutput(data) { lastOutputAt = Date() }
        outputBus.emit(descriptor.id, data)
        extendDeferredUnhostedReplay(data)
        if renderDiagnostics().canRender {
            processGhosttyOutput(data, render: true)
        } else {
            outputPendingBytes += data.count
            processGhosttyOutput(data, render: false)
        }
        touchTerminalMemoryBudget(addedBytes: data.count, force: false)
    }

    private func renderDiagnostics() -> TerminalRenderDiagnostics {
        let window = view.window
        return TerminalRenderDiagnostics(
            logicalVisible: isVisible,
            registryVisible: SurfaceRegistry.shared.isVisible(descriptor.id),
            drainingHiddenBacklog: isDrainingHiddenBacklog,
            windowAttached: window != nil,
            parked: window != nil && window === parkingWindow,
            hasUsableBounds: view.bounds.width > 1 && view.bounds.height > 1,
            hiddenAncestor: Self.isHiddenOrHasHiddenAncestor(view)
        )
    }

    private func handleContainerWindowChanged(_ window: NSWindow?) {
        guard !isClosing else { return }
        if let window, window !== parkingWindow {
            closeParkingWindowIfNeeded()
            if let deferredUnhostedGhosttyReplay {
                beginGhosttyHistoryReplay(deferredUnhostedGhosttyReplay)
            }
            if isVisible {
                ghosttyView.refreshSurfaceOnly()
                // Reattach after parking often leaves AppKit firstResponder on the
                // window chrome; without a force repair, keys never hit Ghostty.
                repairTerminalFocus(reason: "window_reattach", force: true)
            }
            replayPersistedHistoryIfNeeded()
            return
        }
        guard window == nil else { return }
        scheduleParkingIfDetached()
    }

    /// Joins persisted history chunk payloads into a single contiguous byte
    /// sequence ready for `resetSurfaceOutput`. Pure so it can be unit-tested
    /// without AppKit or a live Ghostty surface.
    nonisolated static func assembleReplayPayload(from chunkData: [Data]) -> Data {
        TerminalHistoryCoordinator.assembleReplayPayload(from: chunkData)
    }

    private func replayPersistedHistoryIfNeeded() {
        // Passive path: respects cold-start deferral. Demand paths call
        // `requestReplayIfNeeded` (visibility / transcript read).
        historyCoordinator.replayIfNeeded()
    }

    private func recordHistoryReplayLiveData(_ data: Data) {
        historyCoordinator.recordLiveReplayData(
            data,
            maxBytes: Self.maxHiddenRendererBufferBytes
        )
    }

    var terminalHistoryIsClosing: Bool {
        isClosing
    }

    func terminalHistoryCoordinator(
        _ coordinator: TerminalHistoryCoordinator,
        didEncounter issue: TerminalHistoryCoordinator.Issue
    ) {
        switch issue {
        case .backlogCap(let outstandingBytes, let incomingBytes):
            outputPartial = true
            outputPartialReason = "history_backlog_cap"
            terminalLog.error("terminal.history_backlog_capped surface=\(self.descriptor.id.value.uuidString, privacy: .public) outstandingBytes=\(outstandingBytes, privacy: .public) incomingBytes=\(incomingBytes, privacy: .public)")
            publishRuntimeHealth()
        case .persistenceFailure:
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_persistence_failed"
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .persistenceRecovered:
            // A successful later append does not restore bytes lost by the
            // earlier failed append. The durable gap clears only with the
            // user's explicit clear/delete action.
            return
        case .retentionCap:
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_retention_cap"
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .retentionMaintenanceFailure:
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_retention_maintenance_failed"
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .retentionMaintenanceRecovered:
            guard outputPartialReason == "history_retention_maintenance_failed" else { return }
            outputPartial = false
            outputPartialReason = nil
            publishRuntimeHealth()
        case .replayReadFailure:
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            outputPartialReason = outputPartialReason ?? "history_replay_failed"
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .replayReadRecovered:
            guard outputPartialReason == "history_replay_failed" else { return }
            outputPartial = false
            outputPartialReason = nil
            publishRuntimeHealth()
        case .replayLiveCap:
            // Live bytes are already present in both renderers. A reset from the
            // capped replay buffer would erase the newest rendered tail.
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_replay_live_cap"
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .durablePartial(let reason):
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = reason
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .liveClearCompleted(let outputIsPartial):
            if !outputIsPartial {
                outputPartial = false
                outputPartialReason = nil
            }
            cachedTextSnapshot = nil
            publishRuntimeHealth()
        case .liveClearFailed:
            outputPartial = true
            outputPartialReason = "history_clear_failed"
            cachedTextSnapshot = nil
            publishRuntimeHealth()
        case .staleWriterGeneration:
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_writer_stale"
            }
            cachedTextSnapshot = nil
            publishRuntimeHealth()
        }
    }

    func terminalHistoryCoordinator(
        _ coordinator: TerminalHistoryCoordinator,
        didPrepareReplay canonical: Data
    ) {
        guard !canonical.isEmpty else { return }
        renderer = ANSIRenderer(
            rows: terminalSize.rows,
            cols: terminalSize.cols,
            scrollbackLimit: Self.activeANSIScrollbackRows
        )
        terminalMemoryUsesCompactRenderer = false
        renderer.feed(canonical)
        pendingRendererEvents.removeAll(keepingCapacity: true)
        pendingRendererByteCount = 0
        hiddenRendererBuffer = Data()
        hiddenRendererBufferOverflowed = false
        hiddenMirrorAcceptedBytes = 0
        rendererMutationCount &+= 1
        cachedTextSnapshot = nil
        beginGhosttyHistoryReplay(canonical)
    }

    /// Returns false when a payload larger than one PTY handoff is refused because
    /// another system-output stream owns the terminal (marked partial, never queued).
    @discardableResult
    public func appendSystemText(_ raw: String) -> Bool {
        guard raw.utf8.count > Self.ptyHandoffReserveBytes else {
            appendString(raw)
            return true
        }
        guard let lease = reserveSystemOutput() else {
            if !isClosing {
                outputPartial = true
                outputPartialReason = outputPartialReason ?? "system_output_busy"
                terminalLog.error("terminal.system_output_busy surface=\(self.descriptor.id.value.uuidString, privacy: .public) bytes=\(raw.utf8.count, privacy: .public)")
            }
            return false
        }
        lease.deliver(raw)
        return true
    }

    private func autoSubmitSavedSSHPasswordIfNeeded(from data: Data) {
        // PERF: case-insensitive scan avoids lowercased() copying the whole
        // PTY chunk on every output arrival; same prompt verdicts.
        guard let raw = String(data: data, encoding: .utf8),
              raw.range(of: "password:", options: .caseInsensitive) != nil
                || raw.range(of: "passphrase", options: .caseInsensitive) != nil else { return }
        passwordPromptCount += 1
        if let notice = Self.autoSubmitNotice(promptCount: passwordPromptCount) {
            appendString("\r\n" + notice + "\r\n")
        }
        guard !didSendSavedSSHPassword,
              let savedSSHPassword,
              !savedSSHPassword.isEmpty else { return }
        didSendSavedSSHPassword = true
        _ = sendTextStatus(savedSSHPassword + "\n")
    }

    // Pure decision seam -- no state, no secrets.
    // promptCount 1 -> user sees that the app submitted their saved password (not typed by ghost).
    // promptCount 2 -> user sees the server rejected it and is asking again; the app will NOT
    //                  re-submit (didSendSavedSSHPassword guards that), so the prompt is live.
    // promptCount 0 or <0 -> nil (no notice).
    nonisolated static func autoSubmitNotice(promptCount: Int) -> String? {
        switch promptCount {
        case 1:
            return L("[submitted your saved password automatically -- the app answered this prompt, not you]")
        case 2:
            return L("[server is asking for the password again -- your saved password was rejected; type it manually]")
        default:
            return nil
        }
    }

    // Pure decision seam: decides what bytes (if any) to replay into the
    // renderer when a hidden surface becomes visible again.
    //
    // - buffer: bytes accumulated while hidden (may be empty or overflowed-truncated)
    // - overflowed: true when the buffer hit the cap; the renderer snapshot will
    //   still be partial even after the replay (caller must keep complete=false)
    //
    // Returns the data that MUST be fed to renderer.feed on reveal, or nil when
    // there is nothing to replay. This seam is nonisolated/static so it can be
    // unit-tested without AppKit or a live TerminalSurface instance.
    nonisolated static func hiddenRendererHealPlan(buffer: Data, overflowed: Bool) -> Data? {
        guard !buffer.isEmpty else { return nil }
        // Even when overflowed, replay whatever was buffered: partial is better
        // than nothing; the complete=false flag already signals the gap.
        return buffer
    }

    /// Pure detection seam (audit #3): a surface that believes it is hidden
    /// (`isVisible == false`) while its view is demonstrably on a key, on-screen
    /// window is a visibility-reconcile desync — output is arriving but
    /// readerAllowsRender/occlusion are latched off so nothing repaints (the freeze).
    /// `nonisolated static` so the desync condition is unit-testable without AppKit.
    nonisolated static func isLikelyStuckHidden(isVisible: Bool, viewDefinitelyOnScreen: Bool) -> Bool {
        !isVisible && viewDefinitelyOnScreen
    }

    /// Re-check used by the deferred stuck-hidden heal before it flips the surface
    /// visible. The view can legitimately disappear between scheduling and execution.
    nonisolated static func shouldRunStuckHiddenHeal(
        isClosing: Bool,
        isVisible: Bool,
        viewDefinitelyOnScreen: Bool
    ) -> Bool {
        !isClosing && isLikelyStuckHidden(isVisible: isVisible, viewDefinitelyOnScreen: viewDefinitelyOnScreen)
    }

    @discardableResult
    private func writeToPTY(_ data: Data) -> TerminalInputStatus {
        guard !data.isEmpty else { return .accepted }
        guard processAlive, masterFD >= 0, terminalDeadReason == nil else { return .processExited }
        guard let inputPump else { return .writeFailed }
        let status = inputPump.enqueue(data)
        if status == .accepted {
            scheduleBusyStateRefresh()
        }
        if status != .accepted {
            terminalLog.error("terminal.input_rejected surface=\(self.descriptor.id.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) pid=\(self.childPID, privacy: .public)")
            publishRuntimeHealth()
        }
        return status
    }

    private func configureInputPump(lease: TerminalFileDescriptorLease) {
        let pump = TerminalInputPump(
            waitForWriteReadiness: { timeoutMicros in
                lease.waitForWritable(timeoutMicros: timeoutMicros)
            },
            writer: { data, offset in
                lease.write(data, offset: offset)
            }
        )
        attachInputPumpCallbacks(pump)
        inputPump = pump
    }

    func installInputPumpForRuntimeHealthTests(_ pump: TerminalInputPump, processAlive: Bool = true) {
        self.processAlive = processAlive
        self.terminalDeadReason = nil
        self.exitStatus = nil
        self.terminationSignal = nil
        attachInputPumpCallbacks(pump)
        inputPump = pump
    }

    private func attachInputPumpCallbacks(_ pump: TerminalInputPump) {
        pump.onTerminalFailure = { [weak self] status in
            DispatchQueue.main.async {
                if let self {
                    terminalLog.error("terminal.input_failed surface=\(self.descriptor.id.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) pid=\(self.childPID, privacy: .public)")
                }
                self?.markTerminalDead(reason: status.rawValue, exitStatus: nil)
            }
        }
        pump.onInputStalled = { [weak self] unwritten in
            DispatchQueue.main.async {
                guard let self, !self.isClosing else { return }
                // RECOVERABLE: the child is not draining stdin. Keep the terminal
                // alive, but publish input_accepting=false until the accepted bytes
                // are retried and delivered.
                terminalLog.error("terminal.input_stalled surface=\(self.descriptor.id.value.uuidString, privacy: .public) unwrittenBytes=\(unwritten, privacy: .public) pid=\(self.childPID, privacy: .public)")
                self.publishRuntimeHealth()
            }
        }
        pump.onInputResumed = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.isClosing else { return }
                terminalLog.info("terminal.input_resumed surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(self.childPID, privacy: .public)")
                self.didBeepForDeadInput = false
                self.publishRuntimeHealth()
            }
        }
    }

    public func sendTextStatus(_ text: String) -> TerminalInputStatus {
        guard let data = text.data(using: .utf8) else { return .writeFailed }
        return writeToPTY(data)
    }

    public func sendText(_ text: String) {
        _ = sendTextStatus(text)
    }

    public func runtimeHealth() -> TerminalRuntimeHealth {
        TerminalRuntimeHealth(
            processAlive: processAlive,
            childPID: childPID > 0 ? childPID : nil,
            exitStatus: exitStatus,
            terminationSignal: terminationSignal,
            ptyOpen: masterFD >= 0,
            inputAccepting: processAlive && terminalDeadReason == nil && (inputPump?.inputAccepting ?? false),
            terminalDeadReason: terminalDeadReason,
            lastOutputAt: lastOutputAt,
            outputPartial: outputPartial,
            outputPartialReason: outputPartialReason,
            outputPendingBytes: outputPendingBytes,
            historyWriteFailures: historyWriteFailures,
            droppedOutputBytes: ghosttyView.droppedOutputBytes,
            rows: terminalSize.rows,
            cols: terminalSize.cols,
            renderDiagnostics: renderDiagnostics()
        )
    }

    /// Final ownership gate used immediately before a prepared replacement is
    /// registered under an existing surface ID. Boolean runtime state alone is
    /// insufficient because a child may have exited after forkpty succeeded.
    public func runtimeProcessIsOwnedAndAliveForRestartCommit() -> Bool {
        guard processAlive,
              childPID > 0,
              masterFD >= 0,
              terminalDeadReason == nil else { return false }
        return TerminalPTYProcessRuntime.ownsLiveChild(pid: childPID)
    }

    static func isTerminalJobBusy(
        processAlive: Bool,
        shellPID: Int32,
        foregroundProcessGroup: Int32?
    ) -> Bool {
        guard processAlive, shellPID > 0, let foregroundProcessGroup else { return false }
        return foregroundProcessGroup != shellPID
    }

    static func shouldContinueBusyStatePolling(isBusy: Bool, now: Date, probeUntil: Date) -> Bool {
        isBusy || now < probeUntil
    }

    static func busyStatePollDelay(isVisible: Bool, activityTriggered: Bool) -> TimeInterval {
        if isVisible || activityTriggered { return activeBusyStatePollInterval }
        return hiddenBusyStatePollInterval
    }

    static func shouldReplaceBusyStatePoll(scheduledAt: Date?, requestedAt: Date) -> Bool {
        guard let scheduledAt else { return true }
        return requestedAt < scheduledAt
    }

    private func foregroundProcessGroup() -> Int32? {
        guard masterFD >= 0 else { return nil }
        let group = tcgetpgrp(masterFD)
        guard group > 0 else { return nil }
        if group == childPID {
            lastCapturedForegroundGroup = nil
        } else if let captured = TerminalPTYProcessRuntime.captureForegroundProcessGroup(
            pgid: group,
            shellPID: childPID
        ) {
            lastCapturedForegroundGroup = captured
        }
        return group
    }

    public func readTextSnapshot() -> TerminalTextSnapshot {
        // Correctness demand: iOS/mirror/automation may read a restored terminal
        // before the tab is selected. Kick cold-start history replay (async) so
        // subsequent snapshots include the persisted prefix.
        historyCoordinator.requestReplayIfNeeded()
        // Flush any deferred visible feed/resize events into `renderer` FIRST
        // (PERF-136), before the cache check, so rendererMutationCount and the
        // renderer's actual state agree for every read site below.
        ensureRendererCurrent()
        // Hidden PTY bytes also land in `pendingRendererEvents` (force-flushed into
        // the ANSI ring). Drain any residual pending/legacy heal buffer so
        // surface.read_text returns the authoritative transcript while still
        // hidden (release-soak aux markers).
        if !isVisible {
            applyHiddenRendererHealIfNeeded()
        }
        let diagnostics = renderDiagnostics()
        // F1: the cache key must also cover the volatile state the snapshot EMBEDS
        // (render-diagnostics, pending/partial/history-failure flags). rendererVersion
        // + viewportText alone miss a change such as canRender flipping or
        // outputPendingBytes moving with no renderer feed, so the cache could return a
        // snapshot whose embedded diagnostics are stale — masking live state as stable.
        // Fold those signals into a signature that is part of the validity check.
        let stateSignature = Self.snapshotStateSignature(
            outputPartial: outputPartial,
            outputPendingBytes: outputPendingBytes,
            historyWriteFailures: historyWriteFailures,
            diagnostics: diagnostics,
            outputPartialReason: outputPartialReason
        )
        if !isVisible {
            // Hidden surfaces: Ghostty may be parked/occluded with a blank multi-row
            // viewport even after pending drains. The healed ANSI renderer is the
            // authoritative transcript for surface.read_text / iOS mirrors.
            // The viewport key in this branch is always nil (we skip ghostty read).
            if let cached = cachedTextSnapshot,
               Self.snapshotCacheValid(
                   rendererVersion: rendererMutationCount,
                   cachedVersion: cached.rendererVersion,
                   viewportText: nil,
                   cachedViewportText: cached.viewportText,
                   stateSignature: stateSignature,
                   cachedStateSignature: cached.stateSignature
               ) {
                return cached.value
            }
            // Match the visible path: complete requires canRender. Hidden always
            // blocks render (logical_hidden), so complete stays false even after
            // the ANSI mirror is healed. Otherwise idle hidden reads (pending=0)
            // report complete=true with partial_reason=logical_hidden while the
            // wire maps partial=!complete — dishonest to surface.read_text.
            let complete = diagnostics.canRender && Self.readTextComplete(
                outputPartial: outputPartial,
                outputPendingBytes: outputPendingBytes,
                historyWriteFailures: historyWriteFailures
            )
            let partialReason = Self.readTextPartialReason(
                outputPartial: outputPartial,
                outputPendingBytes: outputPendingBytes,
                historyWriteFailures: historyWriteFailures,
                renderBlockedReason: diagnostics.blockedReason,
                outputPartialReason: outputPartialReason
            )
            var snap = TerminalTextSnapshot(
                text: renderer.snapshot().string,
                ansiText: renderer.ansiSnapshot(includeScrollback: true),
                complete: complete,
                source: "ansi_fallback",
                timestamp: Date(),
                partialReason: partialReason,
                pendingBytes: outputPendingBytes,
                rows: terminalSize.rows,
                cols: terminalSize.cols,
                renderDiagnostics: diagnostics
            )
            snap.ansiPalette = resolvedCustomPaletteHex()
            cachedTextSnapshot = (rendererMutationCount, nil, stateSignature, snap)
            return snap
        }
        // Read the ghostty viewport text first (cheap when there is no pending
        // output — just reads the existing rendered frame). We need the value
        // before the cache check because it is the viewport-side cache key.
        let currentViewportText = ghosttyView.readViewportText()
        if let cached = cachedTextSnapshot,
           Self.snapshotCacheValid(
               rendererVersion: rendererMutationCount,
               cachedVersion: cached.rendererVersion,
               viewportText: currentViewportText,
               cachedViewportText: cached.viewportText,
               stateSignature: stateSignature,
               cachedStateSignature: cached.stateSignature
           ) {
            return cached.value
        }
        var snap: TerminalTextSnapshot
        if let text = currentViewportText {
            let rendererText = renderer.snapshot().string
            let complete = diagnostics.canRender && Self.readTextComplete(
                outputPartial: outputPartial,
                outputPendingBytes: outputPendingBytes,
                historyWriteFailures: historyWriteFailures
            )
            let partialReason = Self.readTextPartialReason(
                outputPartial: outputPartial,
                outputPendingBytes: outputPendingBytes,
                historyWriteFailures: historyWriteFailures,
                renderBlockedReason: diagnostics.blockedReason,
                outputPartialReason: outputPartialReason
            )
            if Self.shouldPreferRendererSnapshotForReadText(viewportText: text, rendererText: rendererText) {
                snap = TerminalTextSnapshot(
                    text: rendererText,
                    ansiText: renderer.ansiSnapshot(includeScrollback: true),
                    complete: complete,
                    source: "ansi_renderer",
                    timestamp: Date(),
                    partialReason: partialReason,
                    pendingBytes: outputPendingBytes,
                    rows: terminalSize.rows,
                    cols: terminalSize.cols,
                    renderDiagnostics: diagnostics
                )
            } else {
                snap = TerminalTextSnapshot(
                    text: text,
                    ansiText: renderer.ansiSnapshot(matchingVisibleText: text),
                    complete: complete,
                    source: "ghostty_viewport",
                    timestamp: Date(),
                    partialReason: partialReason,
                    pendingBytes: outputPendingBytes,
                    rows: terminalSize.rows,
                    cols: terminalSize.cols,
                    renderDiagnostics: diagnostics
                )
            }
        } else {
            snap = TerminalTextSnapshot(
                text: renderer.snapshot().string,
                ansiText: renderer.ansiSnapshot(includeScrollback: true),
                complete: false,
                source: "ansi_fallback",
                timestamp: Date(),
                // A parser that is still absorbing queued output is not "unavailable":
                // the ANSI mirror above is current, only the native viewport lags.
                partialReason: outputPartialReason
                    ?? (ghosttyView.outputBytesOwned > 0 ? "ghostty_parser_draining" : "ghostty_unavailable"),
                pendingBytes: outputPendingBytes,
                rows: terminalSize.rows,
                cols: terminalSize.cols,
                renderDiagnostics: diagnostics
            )
        }
        snap.ansiPalette = resolvedCustomPaletteHex()
        cachedTextSnapshot = (rendererMutationCount, currentViewportText, stateSignature, snap)
        return snap
    }

    /// Resolve the active Ghostty theme's 16-entry ANSI palette as `#rrggbb`
    /// hex strings, or `nil` when the theme is the built-in default (so the
    /// snapshot omits `ansi_palette` and iOS uses its own default). Pure beyond
    /// the Ghostty config read.
    private func resolvedCustomPaletteHex() -> [String]? {
        ANSIPaletteMapper.customPaletteHex(from: GhosttyTerminalView.resolvedANSIThemeColors())
    }

    static func readTextComplete(outputPartial: Bool, outputPendingBytes: Int, historyWriteFailures: Int) -> Bool {
        !outputPartial && outputPendingBytes == 0 && historyWriteFailures == 0
    }

    /// Pure cache-validity decision for `readTextSnapshot()`.
    ///
    /// Returns `true` only when BOTH the renderer AND the ghostty viewport text
    /// are unchanged since the snapshot was last built, so the cached value can
    /// be returned without rebuilding.
    ///
    /// Design rationale:
    /// - `rendererVersion` tracks every `renderer.feed()` / `renderer.resize()`
    ///   call inside TerminalSurface, giving us a cheap per-mutation signal
    ///   without touching ANSIRenderer's private `contentVersion`.
    /// - `viewportText` is the full string returned by `ghosttyView.readViewportText()`
    ///   on the last build. Viewport text changes independently of the renderer
    ///   (e.g. Ghostty scrolls or repaints while the ANSIRenderer version is
    ///   unchanged), so a renderer-version-only key would return stale viewport
    ///   text. Storing the full string and checking equality is O(n) in text
    ///   length but is only paid on actual `readTextSnapshot()` calls — not on
    ///   every byte of output.
    /// - A `nil` viewportText means "ghostty returned nil on the last build"
    ///   (surface not ready / no live surface). Cache is valid only when the
    ///   current ghostty text is also nil — the moment ghostty becomes available
    ///   the viewport key diverges and the cache is rebuilt.
    ///
    /// Staleness guarantee: if either signal changes, this returns `false` and
    /// the caller must rebuild. It never returns `true` for a stale result.
    nonisolated static func snapshotCacheValid(
        rendererVersion: UInt64,
        cachedVersion: UInt64,
        viewportText: String?,
        cachedViewportText: String?,
        stateSignature: String,
        cachedStateSignature: String
    ) -> Bool {
        rendererVersion == cachedVersion
            && viewportText == cachedViewportText
            && stateSignature == cachedStateSignature
    }

    /// Compact signature of the volatile state that `readTextSnapshot()` embeds in a
    /// snapshot but that is NOT captured by `rendererVersion`/`viewportText`: the
    /// render-diagnostics outcome plus the pending/partial/history-failure flags.
    /// Folding it into the cache key (F1) means a diagnostics change (e.g. canRender
    /// flips, or `outputPendingBytes` moves with no renderer feed) correctly
    /// invalidates the cache instead of returning a snapshot with stale diagnostics.
    /// `nonisolated static` so it is pure and unit-testable.
    nonisolated static func snapshotStateSignature(
        outputPartial: Bool,
        outputPendingBytes: Int,
        historyWriteFailures: Int,
        diagnostics: TerminalRenderDiagnostics,
        outputPartialReason: String? = nil
    ) -> String {
        // Fold EVERY render-diagnostics field the snapshot embeds (not just
        // blockedReason/canRender) so a change in any of them — e.g. `parked` flipping
        // while a higher-priority blockedReason stays the same — still invalidates the
        // cache and the mirror never receives a snapshot with a stale diagnostics field.
        let d = diagnostics
        let diag = "\(d.logicalVisible ? 1 : 0)\(d.registryVisible ? 1 : 0)\(d.drainingHiddenBacklog ? 1 : 0)\(d.windowAttached ? 1 : 0)\(d.parked ? 1 : 0)\(d.hasUsableBounds ? 1 : 0)\(d.hiddenAncestor ? 1 : 0)"
        return "\(outputPartial)|\(outputPendingBytes)|\(historyWriteFailures)|\(outputPartialReason ?? "")|\(diag)|\(d.blockedReason ?? "")"
    }

    static func readTextPartialReason(
        outputPartial: Bool,
        outputPendingBytes: Int,
        historyWriteFailures: Int,
        renderBlockedReason: String? = nil,
        outputPartialReason: String? = nil
    ) -> String? {
        if let outputPartialReason { return outputPartialReason }
        if outputPartial { return "hidden_output_cap" }
        if outputPendingBytes > 0 { return "hidden_output_pending" }
        if historyWriteFailures > 0 { return "history_persistence_failed" }
        if let renderBlockedReason { return renderBlockedReason }
        return nil
    }

    /// The reason a history flush is requested.
    ///
    /// History disposition is always asynchronous. App termination and runtime
    /// replacement join its barrier against one caller-owned deadline.
    enum FlushReason: Equatable {
        /// The user closed a tab (or the surface is being torn down mid-session).
        /// A slow disk must not stall the main thread — flush asynchronously.
        case tabClose
        /// The app is about to terminate (applicationWillTerminate).
        /// Data must not be lost on quit — join the global history barrier.
        case appTermination
        /// A dead shell is being replaced behind the same stable surface ID.
        case runtimeRestart
    }

    /// Compatibility seam proving no close path performs a per-surface
    /// synchronous SQLite wait on the main actor.
    nonisolated static func flushShouldWait(reason: FlushReason) -> Bool {
        false
    }

    private func publishRuntimeHealth() {
        guard publishesRuntimeHealth else { return }
        SurfaceRuntimeBus.shared.emit(descriptor.id, runtimeHealth())
    }

    private func scheduleBusyStateRefresh() {
        let now = Date()
        busyStateProbeUntil = max(busyStateProbeUntil, now.addingTimeInterval(Self.busyStateProbeDuration))
        scheduleBusyStatePoll(activityTriggered: true, now: now)
    }

    private func scheduleBusyStatePoll(activityTriggered: Bool, now: Date) {
        let delay = Self.busyStatePollDelay(
            isVisible: isVisible,
            activityTriggered: activityTriggered
        )
        let requestedDeadline = now.addingTimeInterval(delay)
        guard Self.shouldReplaceBusyStatePoll(
            scheduledAt: busyStatePollDeadline,
            requestedAt: requestedDeadline
        ) else { return }

        busyStatePollWorkItem?.cancel()
        busyStatePollDeadline = requestedDeadline
        busyStatePollGeneration &+= 1
        let generation = busyStatePollGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
#if DEBUG
            self.busyStatePollCallbackEntryCountForTestingValue += 1
#endif
            guard self.busyStatePollGeneration == generation else { return }
            self.busyStatePollWorkItem = nil
            self.busyStatePollDeadline = nil
            guard !self.isClosing else {
                return
            }
            let busy = self.isBusy
            let now = Date()
            if busy != self.lastPublishedBusyState {
                self.lastPublishedBusyState = busy
                if busy {
                    self.busySince = now
                    self.lastCommandExitCode = nil
                } else {
                    self.handleBusyFinished(now: now)
                }
                self.onBusyStateChanged?(busy)
                self.publishRuntimeHealth()
            }
            guard Self.shouldContinueBusyStatePolling(
                isBusy: busy,
                now: now,
                probeUntil: self.busyStateProbeUntil
            ) else {
                return
            }
            self.scheduleBusyStatePoll(activityTriggered: false, now: now)
        }
        busyStatePollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func handleBusyFinished(now: Date) {
        let since = busySince
        busySince = nil
        guard let since, now.timeIntervalSince(since) >= Self.minimumFinishedBusyDuration else { return }
        let looking = isVisible && view.window?.isKeyWindow == true
        if !looking { descriptor.hasUnreadActivity = true }
        var body = foregroundJobAlive ? L("Terminal is waiting for input") : L("Process exited")
        if let code = lastCommandExitCode, code != 0 { body += L(" (exit %1$@)", code) }
        onBusyFinished?(L("%1$@ finished", descriptor.title), body, looking)
    }

    private func handleProgressReport(active: Bool) {
        progressActive = active
        scheduleBusyStateRefresh()
    }

    private func handleCommandFinished(exitCode: Int?) {
        lastCommandExitCode = exitCode
        scheduleBusyStateRefresh()
    }

    private func recordOutputTelemetry(bytes: Int) {
        guard bytes > 0 else { return }
        totalOutputBytes += bytes
        let now = Date()
        let byteDelta = totalOutputBytes - outputBytesAtLastTelemetry
        guard byteDelta >= Self.outputTelemetryByteInterval ||
                now.timeIntervalSince(lastOutputTelemetryAt) >= Self.outputTelemetryTimeInterval else { return }
        outputBytesAtLastTelemetry = totalOutputBytes
        lastOutputTelemetryAt = now
        let diagnostics = renderDiagnostics()
        terminalLog.info("terminal.output_health surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(self.childPID, privacy: .public) totalBytes=\(self.totalOutputBytes, privacy: .public) pendingBytes=\(self.outputPendingBytes, privacy: .public) ghosttyQueuedBytes=\(self.ghosttyView.outputBytesOwned, privacy: .public) ownerHeldBytes=\(self.ownedGhosttyReplayOutputBytes, privacy: .public) droppedBytes=\(self.ghosttyView.droppedOutputBytes, privacy: .public) historyOutstandingBytes=\(self.historyOutstandingBytes, privacy: .public) historyFailures=\(self.historyWriteFailures, privacy: .public) maxReadBatchBytes=\(self.maxPTYReadBatchBytesObserved, privacy: .public) maxReadCalls=\(self.maxPTYReadCallsObserved, privacy: .public) canRender=\(diagnostics.canRender, privacy: .public) blocked=\(diagnostics.blockedReason ?? "none", privacy: .public)")
    }

    func handleBell() {
        let fx = BellHandler.effects(prefs: bellPreferences)
        if fx.dot { descriptor.hasUnreadActivity = true }
        if fx.playSound { NSSound.beep() }
        if fx.flash { flashTerminalView() }
    }

    /// Applies a brief white-flash overlay on the terminal container view to
    /// provide a visual bell. The flash is implemented as a CABasicAnimation on
    /// the container layer so it is non-blocking and does not interfere with
    /// terminal rendering.
    private func flashTerminalView() {
        guard let layer = view.layer else { return }
        let flash = CALayer()
        flash.frame = layer.bounds
        flash.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        flash.opacity = 0
        layer.addSublayer(flash)
        CATransaction.begin()
        CATransaction.setCompletionBlock { flash.removeFromSuperlayer() }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.35
        anim.toValue = 0
        anim.duration = 0.15
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.opacity = 0
        flash.add(anim, forKey: "bell_flash")
        CATransaction.commit()
    }

    private func markTerminalDead(
        reason: String,
        exitStatus: Int32?,
        appendExitBanner: Bool = true
    ) {
        guard processAlive || terminalDeadReason == nil else { return }
        let wasAlive = processAlive
        processAlive = false
        self.exitStatus = exitStatus ?? self.exitStatus
        if let rawStatus = self.exitStatus, (rawStatus & 0x7F) != 0 {
            terminationSignal = rawStatus & 0x7F
        }
        terminalDeadReason = reason
        inputPump?.stop(reason: .processExited)
        terminalLog.info("terminal.dead surface=\(self.descriptor.id.value.uuidString, privacy: .public) reason=\(reason, privacy: .public) rawStatus=\(self.exitStatus ?? -1, privacy: .public) signal=\(self.terminationSignal ?? -1, privacy: .public) totalBytes=\(self.totalOutputBytes, privacy: .public) pendingBytes=\(self.outputPendingBytes, privacy: .public) droppedBytes=\(self.ghosttyView.droppedOutputBytes, privacy: .public) historyFailures=\(self.historyWriteFailures, privacy: .public)")
        if wasAlive, appendExitBanner {
            appendProcessExitedBannerIfNeeded(rawStatus: exitStatus)
        }
        publishRuntimeHealth()
    }

    private func appendProcessExitedBannerIfNeeded(rawStatus: Int32?) {
        guard !didAppendProcessExitedBanner, !isClosing else { return }
        didAppendProcessExitedBanner = true
        appendString("\r\n" + Self.processExitedBanner(rawStatus: rawStatus) + "\r\n")
        showRestartBannerIfEligible()
    }

    private static func processExitedBanner(rawStatus: Int32?) -> String {
        guard let rawStatus else { return L("[process exited]") }
        if (rawStatus & 0x7F) != 0 {
            return L("[process terminated (signal %1$@)]", rawStatus & 0x7F)
        }
        return L("[process exited (code %1$@)]", (rawStatus >> 8) & 0xFF)
    }

    // MARK: - Restart shell banner button

    private func showRestartBannerIfEligible() {
        // Only local shell terminals can be restarted inline; SSH has its own
        // reconnect flow. Also skip if the caller hasn't wired onRestartRequested
        // (e.g. unit-test stubs that don't go through AppCommandRouter).
        guard TerminalRestartDecision.spawnRequest(from: descriptor) != nil,
              onRestartRequested != nil,
              restartBannerButton == nil else { return }

        let btn = NSButton()
        btn.title = L("Restart shell")
        btn.bezelStyle = .rounded
        btn.isBordered = true
        btn.target = self
        btn.action = #selector(restartBannerTapped)
        btn.setAccessibilityIdentifier("terminal.restart-shell-button")
        btn.setAccessibilityLabel(L("Restart shell"))
        btn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            btn.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        restartBannerButton = btn
    }

    @objc private func restartBannerTapped() {
        onRestartRequested?()
    }

    private func removeRestartBanner() {
        restartBannerButton?.removeFromSuperview()
        restartBannerButton = nil
    }

    public func readText() -> String {
        readTextSnapshot().text
    }

    static func shouldPreferRendererSnapshotForReadText(viewportText: String, rendererText: String) -> Bool {
        // Prefer the ANSI mirror when Ghostty's viewport has collapsed to empty or a
        // single visible line (stale prompt / blank multi-row parked grid) while the
        // renderer still holds more visible transcript. Compare visible line counts —
        // not raw string length — so a blank 43-row grid of newlines cannot outrank a
        // shorter marker-bearing renderer snapshot (release-soak aux ready markers).
        let viewportVisible = visibleLineCount(viewportText)
        let rendererVisible = visibleLineCount(rendererText)
        guard viewportVisible <= 1 else { return false }
        guard rendererVisible > viewportVisible else { return false }
        return rendererText.contains(where: { $0.isNewline }) || viewportVisible == 0
    }

    private static func visibleLineCount(_ text: String) -> Int {
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        return count
    }

    public func focus() {
        // Explicit user request: allowed to take focus from a field editor.
        repairTerminalFocus(reason: "surface_focus", force: true)
    }

    public func repairTerminalFocus(reason: String, force: Bool = false) {
        focusRepairGeneration &+= 1
        let generation = focusRepairGeneration
        guard !applyFocusIfReady(force: force) else { return }
        scheduleFocusRetry(generation: generation, delay: nil, force: force)
        scheduleFocusRetry(generation: generation, delay: 0.05, force: force)
    }

    @discardableResult
    private func applyFocusIfReady(force: Bool = false) -> Bool {
        guard isVisible,
              !isClosing,
              let window = view.window,
              window !== parkingWindow,
              view.bounds.width > 1,
              view.bounds.height > 1,
              !Self.isHiddenOrHasHiddenAncestor(view),
              window.attachedSheet == nil,
              force || !Self.anotherResponderIsEditing(in: window, terminalView: ghosttyView) else { return false }
        window.makeFirstResponder(ghosttyView)
        ghosttyView.refreshSurfaceOnly()
        descriptor.hasUnreadActivity = false
        onBecameFocused?()
        return true
    }

    /// Don't yank focus back to the terminal if the user is actively editing
    /// another control in the same window (e.g. a sidebar text field). A field
    /// editor (`NSText`) or text view that is the current first responder and
    /// isn't our own terminal view means focus is intentionally elsewhere
    /// (UX-011).
    private static func anotherResponderIsEditing(in window: NSWindow, terminalView: NSView) -> Bool {
        guard let responder = window.firstResponder else { return false }
        guard responder !== terminalView else { return false }
        if let text = responder as? NSText {
            // The shared field editor's delegate is the control being edited.
            if let edited = text.delegate as? NSView, edited === terminalView { return false }
            return true
        }
        if let textView = responder as? NSTextView, textView !== terminalView {
            return true
        }
        return false
    }

    private static func isHiddenOrHasHiddenAncestor(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node.isHidden { return true }
            current = node.superview
        }
        return false
    }

    private func scheduleFocusRetry(generation: Int, delay: TimeInterval?, force: Bool) {
        let attempt = { [weak self] in
            guard let self else { return }
            guard self.focusRepairGeneration == generation else { return }
            _ = self.applyFocusIfReady(force: force)
        }
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: attempt)
        } else {
            DispatchQueue.main.async(execute: attempt)
        }
    }

    public func unfocus() {}

    public func didBecomeVisible() {
        guard !isVisible else { return }
        isVisible = true
        restoreReclaimedTerminalMemoryIfNeeded()
        // Demand-start cold-start history replay for restored tabs (prepare may
        // have completed while hidden with deferReplay). Live capture continues
        // during deferral; this merges persisted prefix + live tail once.
        historyCoordinator.requestReplayIfNeeded()
        // Defensive (PERF-136): drain any deferred visible events before the hidden
        // heal feeds directly into `renderer`, so the heal bytes stay ordered after
        // them. didBecomeHidden already flushes, so this is normally a no-op.
        ensureRendererCurrent()
        // Drain pending mirror events (and any legacy heal buffer) BEFORE
        // readerAllowsRender flips so live visible bytes cannot reorder ahead.
        applyHiddenRendererHealIfNeeded()
        if hiddenRendererBufferOverflowed {
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "hidden_output_cap"
            }
        }
        hiddenMirrorAcceptedBytes = 0
        readerAllowsRender = true
        ghosttyView.setOcclusion(visible: true)
        let hadHiddenOutput = outputPendingBytes > 0
        outputPendingBytes = 0
        if hadHiddenOutput {
            beginHiddenBacklogDrain()
        }
        // Paint the latest frame synchronously on reveal so a busy terminal
        // shows its current state immediately instead of a stale/partial frame
        // for the quiet-delay window; the drain timer now only settles the
        // pending/partial flags, it no longer gates the visible refresh
        // (UX-013).
        ghosttyView.forceRefresh()
        scheduleVisibleRefresh()
        // Commit the settled post-reveal geometry once (debounced through layout).
        // Hidden/park size thrash never reached the PTY; the shell gets a single
        // SIGWINCH only if the visible size actually differs from the last commit.
        scheduleDebouncedPTYWinsize(terminalSize)
        // Workspace switch rebuild races focus repair ahead of reattach. Re-drive
        // firstResponder after reveal so keyDown reaches Ghostty again.
        repairTerminalFocus(reason: "became_visible", force: true)
        scheduleBusyStatePoll(activityTriggered: true, now: Date())
        touchTerminalMemoryBudget()
    }

    /// Replays bytes buffered while `isVisible == false` into the ANSI mirror
    /// renderer and clears the buffer so a later reveal cannot double-feed.
    /// Called from `readTextSnapshot` (while still hidden) and `didBecomeVisible`.
    private func applyHiddenRendererHealIfNeeded() {
        let healBuffer = hiddenRendererBuffer
        let healOverflowed = hiddenRendererBufferOverflowed
        guard let replay = Self.hiddenRendererHealPlan(buffer: healBuffer, overflowed: healOverflowed) else {
            // Empty buffer: still clear a degenerate overflow latch if set.
            if healOverflowed {
                hiddenRendererBufferOverflowed = false
                outputPartial = true
                if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                    outputPartialReason = "hidden_output_cap"
                }
            }
            return
        }
        hiddenRendererBuffer = Data()
        hiddenRendererBufferOverflowed = false
        renderer.feed(replay)
        rendererMutationCount &+= 1
        // Invalidate any snapshot built before this heal.
        cachedTextSnapshot = nil
        if healOverflowed {
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "hidden_output_cap"
            }
        }
    }

    private func scheduleVisibleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isClosing else { return }
            self.ghosttyView.refreshSurfaceOnly()
        }
    }

    public func didBecomeHidden() {
        guard isVisible else { return }
        // Flush any deferred visible feed/resize events (PERF-136) into `renderer`
        // BEFORE switching to the hidden path so later hidden pending events stay
        // ordered after the visible prefix.
        ensureRendererCurrent()
        isVisible = false
        readerAllowsRender = false
        stuckHiddenHealScheduled = false
        isDrainingHiddenBacklog = false
        hiddenBacklogDrainDeadline = nil
        // Drop any debounced interactive winsize so park/teardown frames cannot
        // SIGWINCH the shell after the surface is already hidden.
        cancelPendingPTYWinsize()
        // Fresh hidden period: clear legacy heal buffer and recoverability budget.
        hiddenRendererBuffer = Data()
        hiddenRendererBufferOverflowed = false
        hiddenMirrorAcceptedBytes = 0
        ghosttyView.setOcclusion(visible: false)
        scheduleParkingIfDetached()
        touchTerminalMemoryBudget()
    }

    private func beginHiddenBacklogDrain() {
        isDrainingHiddenBacklog = true
        hiddenBacklogDrainDeadline = Date().addingTimeInterval(Self.hiddenBacklogMaxDrainWindow)
        hiddenBacklogDrainGeneration &+= 1
        scheduleHiddenBacklogDrainCompletion(generation: hiddenBacklogDrainGeneration)
    }

    private func continueHiddenBacklogDrainIfNeeded() {
        guard isDrainingHiddenBacklog else { return }
        // #5: a continuous post-reveal stream (chunks closer together than the quiet
        // delay) used to RE-ARM the completion on every chunk, so isDrainingHiddenBacklog
        // never cleared and canRender stayed false for the whole burst — the
        // frozen-at-reveal-frame bug. Past the absolute deadline, stop re-arming and
        // force the drain to complete.
        guard Self.shouldRearmHiddenBacklogDrain(now: Date(), deadline: hiddenBacklogDrainDeadline) else {
            completeHiddenBacklogDrain()
            return
        }
        hiddenBacklogDrainGeneration &+= 1
        scheduleHiddenBacklogDrainCompletion(generation: hiddenBacklogDrainGeneration)
    }

    /// Pure seam (#5): whether the hidden-backlog drain may re-arm its quiet-delay
    /// completion, or has exceeded its absolute deadline and must force-complete.
    /// `nonisolated static` so the deadline logic is unit-testable without AppKit.
    nonisolated static func shouldRearmHiddenBacklogDrain(now: Date, deadline: Date?) -> Bool {
        guard let deadline else { return true }
        return now < deadline
    }

    private func scheduleHiddenBacklogDrainCompletion(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hiddenBacklogQuietDelay) { [weak self] in
            guard let self,
                  self.hiddenBacklogDrainGeneration == generation,
                  self.isVisible,
                  !self.isClosing else { return }
            self.completeHiddenBacklogDrain()
        }
    }

    private func completeHiddenBacklogDrain() {
        guard isDrainingHiddenBacklog else { return }
        isDrainingHiddenBacklog = false
        hiddenBacklogDrainDeadline = nil
        outputPendingBytes = 0
        ghosttyView.refreshSurfaceOnly()
        // F5: the drain just changed render/output state — publish runtime health now
        // so the UI/mirror reconcile instead of waiting for the next busy-state poll.
        publishRuntimeHealth()
    }

    public func close() {
        _ = close(deletePersistedHistory: false, removeOutputBusState: true, reason: .tabClose)
    }

    public func closeForApplicationTermination() -> SurfaceTerminationBarrier? {
        close(deletePersistedHistory: false, removeOutputBusState: true, reason: .appTermination)
    }

    /// Stops the old runtime without deleting its durable history or resetting
    /// its mirror cursor. The replacement may spawn only after this combined
    /// history + process barrier succeeds.
    public func closeForRuntimeRestart() -> SurfaceTerminationBarrier? {
        close(deletePersistedHistory: false, removeOutputBusState: false, reason: .runtimeRestart)
    }

    public func requiredHistoryBarrierForRuntimeRestart() -> SurfaceTerminationBarrier? {
        runtimeRestartRequiredHistoryBarrier
    }

    /// Non-destructive restart gate. A caller may time out and leave this
    /// runtime fully interactive while the serial history writer continues to
    /// drain. Only a successful gate authorizes PTY/Ghostty teardown.
    public func runtimeRestartHistoryPreflightBarrier() -> SurfaceTerminationBarrier {
        historyCoordinator.flushBarrier()
    }

    /// Continues ownership-safe cleanup after an irreversible restart close
    /// whose fast disposition could not prove completion. The replacement may
    /// still take over the stable surface ID; this old runtime keeps no UI role.
    @discardableResult
    public func continueCleanupAfterFailedRuntimeRestart() -> SurfaceTerminationBarrier? {
        let pid = childPID
        guard pid > 0 else { return nil }
        let work = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
            pid: pid,
            foregroundGroup: childReapForegroundGroup
        )
        let barrier = SurfaceTerminationBarrier(
            groups: [work.group],
            completionChecks: [work.succeeded]
        )
        applicationTerminationBarrier = barrier
        childReapInFlightPID = pid
        let observerDeadline = DispatchTime.now() + childDispositionObserverTimeout
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let succeeded = barrier.wait(until: observerDeadline)
            self?.childReapCompletionHook.fire()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.childPID == pid else { return }
                self.childReapInFlightPID = nil
                self.childReapForegroundGroup = nil
                if succeeded {
                    self.childPID = -1
                } else {
                    self.terminalDeadReason = "process_reap_timeout"
                    terminalLog.error("terminal.reap_timeout surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public) reason=runtime_restart_fallback")
                }
                self.publishRuntimeHealth()
            }
        }
        return barrier
    }

    public func markRuntimeRestartDispositionIncomplete() {
        outputPartial = true
        outputPartialReason = "runtime_restart_disposition_incomplete"
        publishRuntimeHealth()
    }

    public func markRuntimeRestartHistoryIncomplete() {
        outputPartial = true
        outputPartialReason = "runtime_restart_history_incomplete"
        publishRuntimeHealth()
    }

    public func markRuntimeRestartRecoveryExhausted() {
        outputPartial = true
        outputPartialReason = "runtime_restart_recovery_exhausted"
        publishRuntimeHealth()
    }

    public func refreshRestartActionForCurrentHealth() {
        if processAlive {
            removeRestartBanner()
        } else {
            showRestartBannerIfEligible()
        }
    }

    /// Stops a retired runtime from publishing stale dead health after another
    /// runtime commits behind the same stable surface ID.
    public func relinquishRuntimeHealthOwnershipForReplacement() {
        publishesRuntimeHealth = false
    }

    /// Tears down one runtime that is being replaced behind the same registered
    /// surface ID. The mirror cursor must survive so the next runtime continues
    /// with a strictly greater sequence instead of being rejected as stale by iOS.
    @discardableResult
    public func closePreservingOutputBusState(timeout: TimeInterval = 2) -> Bool {
        let barrier = close(
            deletePersistedHistory: false,
            removeOutputBusState: false,
            reason: .runtimeRestart
        )
        guard let barrier else { return true }
        return barrier.wait(until: .now() + max(0, timeout))
    }

    public func closeAndDeletePersistedHistory() {
        _ = close(deletePersistedHistory: true, removeOutputBusState: true, reason: .tabClose)
    }

    private func close(
        deletePersistedHistory: Bool,
        removeOutputBusState: Bool,
        reason: FlushReason
    ) -> SurfaceTerminationBarrier? {
        guard !isClosing else {
            if reason == .tabClose {
                publishesRuntimeHealth = false
            }
            if deletePersistedHistory {
                historyCoordinator.discardAndDeletePersistedHistory()
            }
            switch reason {
            case .appTermination, .runtimeRestart:
                return applicationTerminationBarrier
            case .tabClose:
                return nil
            }
        }
        isClosing = true
        if let terminalMemoryBudgetToken {
            TerminalMemoryBudgetAuthority.shared.unregister(terminalMemoryBudgetToken)
            self.terminalMemoryBudgetToken = nil
        }
        deferredUnhostedGhosttyReplay = nil
        ownedGhosttyReplayOutput.removeAll(keepingCapacity: false)
        ownedGhosttyReplayOutputBytes = 0
        liveOutputBackpressureActive = false
        systemOutput?.finished = true
        systemOutput?.parts = []
        systemOutput = nil
        heldBehindSystemOutput = []
        heldBehindSystemOutputBytes = 0
        cancelPendingPTYWinsize()
        let deferredHistoryState = TerminalDeferredTerminationState()
        let readerClosingSnapshot = readerHandoffState.beginClosing {
            if reason == .appTermination {
                deferredHistoryState.complete(success: true)
            } else {
                DispatchQueue.main.async { [weak self, deferredHistoryState] in
                    guard let self else {
                        deferredHistoryState.complete(success: false)
                        return
                    }
                    self.completeDeferredReaderClose(
                        state: deferredHistoryState,
                        deletePersistedHistory: deletePersistedHistory,
                        emitOutput: !removeOutputBusState
                    )
                }
            }
        }
        removeRestartBanner()
        closeParkingWindowIfNeeded()
        let foregroundPGID = foregroundProcessGroup()
        let pid = childPID
        let foregroundGroup = pid > 0
            ? resolvedForegroundGroupForReap(pid: pid, foregroundPGID: foregroundPGID)
            : nil
        childReapForegroundGroup = foregroundGroup
        lastCapturedForegroundGroup = nil
        inputPump?.stop(reason: .processExited)
        cancelPTYReader()
        if reason == .appTermination || reason == .runtimeRestart {
            // Reader and writer both use the lease lock, so app termination can
            // close the PTY synchronously without waiting for a reader that may
            // itself be blocked on the main-actor handoff.
            masterFDLease?.close()
        }
        appendClosingReaderBatches(
            readerClosingSnapshot.batches,
            emitOutput: !removeOutputBusState
        )
        let historyBarrier: SurfaceTerminationBarrier?
        if deletePersistedHistory {
            historyCoordinator.discardAndDeletePersistedHistory()
            if !readerClosingSnapshot.awaitsPublication {
                deferredHistoryState.complete(success: true)
            }
            historyBarrier = nil
        } else if readerClosingSnapshot.awaitsPublication {
            if reason == .appTermination {
                historyBarrier = deferredHistoryState.applicationTerminationBarrier {
                    [weak self] deadline in
                    guard let self else { return false }
                    return self.completeDeferredReaderCloseForApplicationTermination(
                        deadline: deadline
                    )
                }
            } else {
                historyBarrier = deferredHistoryState.barrier()
            }
        } else {
            deferredHistoryState.complete(success: true)
            historyBarrier = historyCoordinator.flushBarrier(
                finalizing: true,
                retryTimeout: 2
            )
        }
        if pid > 0 {
            processAlive = false
            terminalDeadReason = terminalDeadReason ?? "closed"
            terminalLog.info("terminal.close surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public)")
            if reason == .tabClose {
                beginBoundedChildReap(
                    pid: pid,
                    foregroundPGID: foregroundPGID,
                    sendInitialHangup: true
                )
            }
        }
        // Normal close leaves fd disposal to the read-source cancel handler.
        // App termination already closed the lock-serialized lease above.
        masterFD = -1
        ghosttyView.closeSurface()
        // Permanent close (and retired restart instances) must drop heavy mirror /
        // viewport / pump state here — not only when ARC finally deinitializes the
        // NSObject wrapper. Post-materialization soak left ANSI rings, snapshot
        // caches, and parked/hosted views alive until late hierarchy rebuild, so
        // RSS/FD recovery missed the pre-workspace baseline within the gate window.
        releaseClosedSurfaceResources()
        if removeOutputBusState {
            outputBus.remove(surfaceId: descriptor.id)
        }
        publishRuntimeHealth()
        if reason == .tabClose {
            publishesRuntimeHealth = false
        }
        if reason == .appTermination || reason == .runtimeRestart {
            if reason == .runtimeRestart {
                runtimeRestartRequiredHistoryBarrier = historyBarrier
            }
            return runtimeDispositionBarrier(
                pid: pid,
                historyBarrier: historyBarrier
            )
        }
        return nil
    }

    /// Eagerly drops per-surface memory that is no longer observable after close.
    /// History durability already flushed/deleted above; Ghostty C surface is freed.
    /// Transcript correctness for open tabs is unaffected — this only runs when
    /// the surface is permanently leaving the registry (or a retired restart body).
    private func releaseClosedSurfaceResources() {
        pendingRendererEvents.removeAll(keepingCapacity: false)
        pendingRendererByteCount = 0
        hiddenRendererBuffer = Data()
        hiddenRendererBufferOverflowed = false
        hiddenMirrorAcceptedBytes = 0
        outputPendingBytes = 0
        cachedTextSnapshot = nil
        // Replace the full ANSI ring (up to 10k attributed rows) with a minimal
        // renderer so post-close RSS does not wait on NSObject autorelease timing.
        renderer = ANSIRenderer(rows: 1, cols: 1)
        rendererMutationCount &+= 1
        isDrainingHiddenBacklog = false
        hiddenBacklogDrainDeadline = nil
        stuckHiddenHealScheduled = false
        busyStatePollWorkItem?.cancel()
        busyStatePollWorkItem = nil
        busyStatePollDeadline = nil
        busyStatePollGeneration &+= 1

        inputPump?.stop(reason: .processExited)
        inputPump?.onTerminalFailure = nil
        inputPump?.onInputStalled = nil
        inputPump?.onInputResumed = nil
        inputPump = nil

        ghosttyView.releaseHostResourcesAfterClose()

        if let container = view as? TerminalDropContainerView {
            container.onFileDrop = nil
            container.onLayout = nil
            container.onWindowChanged = nil
        }
        // Detach from pane/parking hierarchy immediately so Metal/AppKit can
        // reclaim the view without waiting for a later refreshFromState rebuild.
        view.removeFromSuperview()
        closeParkingWindowIfNeeded()
    }

    private func appendClosingReaderBatches(
        _ batches: [TerminalReaderHandoffState.Batch],
        emitOutput: Bool
    ) {
        for batch in batches where !batch.data.isEmpty {
            maxPTYReadBatchBytesObserved = max(
                maxPTYReadBatchBytesObserved,
                batch.data.count
            )
            maxPTYReadCallsObserved = max(
                maxPTYReadCallsObserved,
                batch.readCalls
            )
            historyCoordinator.enqueue(batch.data)
            recordOutputTelemetry(bytes: batch.data.count)
            if Self.containsVisibleOutput(batch.data) { lastOutputAt = Date() }
            if emitOutput {
                outputBus.emit(descriptor.id, batch.data)
            }
        }
    }

    private func completeDeferredReaderClose(
        state: TerminalDeferredTerminationState,
        deletePersistedHistory: Bool,
        emitOutput: Bool
    ) {
        let batches = readerHandoffState.drainPublished()
        guard !deletePersistedHistory else {
            state.complete(success: true)
            return
        }
        appendClosingReaderBatches(batches, emitOutput: emitOutput)
        let historyBarrier = historyCoordinator.flushBarrier(
            finalizing: true,
            retryTimeout: 2
        )
        DispatchQueue.global(qos: .utility).async {
            state.complete(success: historyBarrier.wait(until: .distantFuture))
        }
    }

    private func completeDeferredReaderCloseForApplicationTermination(
        deadline: DispatchTime
    ) -> Bool {
        appendClosingReaderBatches(
            readerHandoffState.drainPublished(),
            emitOutput: false
        )
        return historyCoordinator.flushBarrier(
            finalizing: true,
            retryTimeout: 2
        ).wait(until: deadline)
    }

    private func runtimeDispositionBarrier(
        pid: pid_t,
        historyBarrier: SurfaceTerminationBarrier?
    ) -> SurfaceTerminationBarrier? {
        var barriers: [SurfaceTerminationBarrier] = []
        if let applicationTerminationBarrier {
            barriers.append(applicationTerminationBarrier)
        }
        if let historyBarrier {
            barriers.append(historyBarrier)
        }
        if applicationTerminationBarrier == nil, pid > 0 {
            if let runtimeDispositionBarrierFactoryForTesting {
                barriers.append(runtimeDispositionBarrierFactoryForTesting(pid))
            } else {
                let work = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
                    pid: pid,
                    foregroundGroup: childReapForegroundGroup
                )
                barriers.append(SurfaceTerminationBarrier(
                    groups: [work.group],
                    completionChecks: [work.succeeded]
                ))
            }
        }
        guard !barriers.isEmpty else { return nil }
        let barrier = SurfaceTerminationBarrier(combining: barriers)
        applicationTerminationBarrier = barrier
        return barrier
    }

    private func scheduleParkingIfDetached() {
        guard parkingWindow == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.parkInHiddenWindowIfNeeded()
        }
    }

    private func parkInHiddenWindowIfNeeded() {
        guard !isClosing,
              !isVisible,
              view.window == nil else { return }

        let frame = NSRect(x: 0, y: 0, width: max(view.bounds.width, 800), height: max(view.bounds.height, 600))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true

        let content = NSView(frame: frame)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        parkingConstraints = [
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ]
        NSLayoutConstraint.activate(parkingConstraints)
        parkingWindow = window
    }

    private func closeParkingWindowIfNeeded() {
        guard let window = parkingWindow else { return }
        NSLayoutConstraint.deactivate(parkingConstraints)
        parkingConstraints.removeAll()
        parkingWindow = nil
        if view.window === window {
            view.removeFromSuperview()
        }
        window.contentView = nil
        window.close()
    }

    public func flushPersistedHistory() {
        // The production coordinator completes ready-state flushes on its serial
        // writer queue. Never pump AppKit here: nested RunLoop execution cannot
        // drain Swift MainActor tasks and permits unrelated UI reentrancy.
        _ = historyCoordinator.flushBarrier().wait(until: .now() + 2)
    }

    public func flushPersistedHistoryBarrier() -> SurfaceTerminationBarrier {
        historyCoordinator.flushBarrier()
    }

    public func flushPersistedHistoryAsync(timeout: TimeInterval = 2) async -> Bool {
        await historyCoordinator.flushBarrier().waitAsync(
            until: .now() + max(0, timeout)
        )
    }

    /// Drops pending history and deletes durable chunks under the surface ID.
    /// In-flight writer items drain first; delete runs last on the same queue so
    /// a blocked pre-clear insert cannot repopulate after clear_history.
    public func clearPersistedHistory() {
        historyCoordinator.clearPersistedHistory()
    }

    public func readPersistedHistory(
        beforeChunkID: Int64?,
        maxBytes: Int,
        timeout: TimeInterval = 2
    ) async throws -> TerminalOutputWindow {
        try await historyCoordinator.readPersistedWindow(
            beforeChunkID: beforeChunkID,
            maxBytes: maxBytes,
            timeout: timeout
        )
    }

    private func enqueueHistory(_ data: Data) {
        guard !isClosing else { return }
        historyCoordinator.enqueue(data)
    }

    /// Exports the full scrollback (including ANSI sequences when format is
    /// `.ansi`, or raw text when format is `.txt`) to `url`.
    /// The caller is responsible for presenting the NSSavePanel and providing
    /// the destination URL.
    public func saveOutput(format: TerminalExportFormat, to url: URL) throws {
        // Flush deferred renderer events (PERF-136) so the exported scrollback
        // reflects all output, not just what was eagerly fed.
        ensureRendererCurrent()
        let content: String
        switch format {
        case .ansi:
            content = renderer.ansiSnapshot(includeScrollback: true)
        case .txt:
            content = renderer.snapshot().string
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func confirmUnsafeTerminalInput(_ text: String) {
        let lineCount = PasteGuard.confirmationLineCount(for: text)
        let lineLabel = lineCount == 1 ? L("1 line") : L("%1$@ lines", lineCount)
        let alert = NSAlert()
        alert.messageText = L("Paste %1$@ into the terminal?", lineLabel)
        alert.informativeText = L("The pasted text spans multiple lines or contains control characters and will run immediately.")
        alert.addButton(withTitle: L("Paste"))
        alert.addButton(withTitle: L("Cancel"))
        let onResponse: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let data = text.data(using: .utf8) else { return }
            _ = self?.writeToPTY(data)
        }
        if let window = ghosttyView.window {
            alert.beginSheetModal(for: window, completionHandler: onResponse)
        } else {
            onResponse(alert.runModal())
        }
    }

    public func snapshot() -> [String: String] {
        ["cwd": descriptor.metadata["cwd"] ?? "", "scrollback_chars": String(readText().count)]
    }
}
