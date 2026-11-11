import AppKit
import CoreModel
import Darwin
import DesignSystemKit
import GhosttyKit
import Persistence
import QuartzCore

private final class RemoteCodeGhosttyIOContext {
    weak var view: GhosttyTerminalView?
    /// Slot generation of the native surface that owns this userdata. Written
    /// only while no native surface exists, so native threads read a stable value.
    var generation: UInt64 = 0
}

final class GhosttySurfaceSlot {
    enum State: Equatable {
        case empty
        case creating(UInt64)
        case live(UInt64)
        case closing(UInt64)
        case closed(UInt64)
    }

    private(set) var state: State = .empty
    private(set) var generation: UInt64 = 0
    private var surface: ghostty_surface_t?
    private var feedInFlight = false
    /// Test doubles are fed and freed through the driver but must never reach
    /// the other C entry points (`liveSurface()` hides them).
    private var isSynthetic = false
    /// Surface removed by close while a native feed was running. Only the feed's
    /// completion may free it, so the free never races the C parser.
    private var deferredFree: ghostty_surface_t?

    var isFeedInFlight: Bool { feedInFlight }
    var isClosingWithDeferredFree: Bool { deferredFree != nil }

    var isLive: Bool {
        guard case .live = state else { return false }
        return surface != nil
    }

    func beginCreate() -> UInt64? {
        guard surface == nil else { return nil }
        switch state {
        case .creating, .closing:
            return nil
        case .empty, .live, .closed:
            generation &+= 1
            state = .creating(generation)
            return generation
        }
    }

    func install(
        _ newSurface: ghostty_surface_t,
        generation expectedGeneration: UInt64,
        synthetic: Bool = false
    ) -> Bool {
        guard case .creating(let activeGeneration) = state,
              activeGeneration == expectedGeneration else { return false }
        surface = newSurface
        isSynthetic = synthetic
        state = .live(expectedGeneration)
        return true
    }

    func cancelCreate(generation expectedGeneration: UInt64) {
        guard case .creating(let activeGeneration) = state,
              activeGeneration == expectedGeneration else { return }
        state = .closed(expectedGeneration)
    }

    func liveSurface() -> ghostty_surface_t? {
        guard case .live = state, !isSynthetic else { return nil }
        return surface
    }

    /// Live pointer including test doubles; only close uses it to stop rendering.
    var rawLiveSurface: ghostty_surface_t? {
        guard case .live = state else { return nil }
        return surface
    }

    /// Starts the single native feed allowed per slot. Only a live surface can be fed.
    func beginFeed() -> ghostty_surface_t? {
        guard !feedInFlight, case .live = state, let surface else { return nil }
        feedInFlight = true
        return surface
    }

    /// Ends the in-flight feed. Returns the surface whose free close deferred, if any.
    func endFeed() -> ghostty_surface_t? {
        feedInFlight = false
        defer { deferredFree = nil }
        return deferredFree
    }

    /// Makes the surface unavailable immediately. Returns it for freeing now, or
    /// nil when a feed is running and `endFeed()` will hand it back instead.
    func removeForClose() -> ghostty_surface_t? {
        guard deferredFree == nil else { return nil }
        guard let current = surface else {
            state = .closed(generation)
            return nil
        }
        surface = nil
        state = .closing(generation)
        if feedInFlight {
            deferredFree = current
            return nil
        }
        return current
    }

    func markClosed() {
        guard deferredFree == nil else { return }
        state = .closed(generation)
    }
}

private func ghosttyTerminalIOWriteCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ length: UInt
) {
    guard let userdata, let bytes, length > 0 else { return }
    let context = Unmanaged<RemoteCodeGhosttyIOContext>.fromOpaque(userdata).takeUnretainedValue()
    let generation = context.generation
    let data = Data(bytes: bytes, count: Int(length))
    DispatchQueue.main.async { [weak context] in
        context?.view?.writeInputData(data, fromNativeGeneration: generation)
    }
}

private func ghosttyRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    return false
}

// MARK: - Action effect mapper

/// Classifies a raw string token from a Ghostty open-url action into the
/// appropriate host action. Pure value type: nonisolated, no AppKit imports.
///
/// Rules:
/// - `http://` or `https://` → `.url`  (open in default browser)
/// - `file://` → `.filePath` (extract POSIX path, route to FilePreview)
/// - Starts with `/` → `.filePath`     (absolute POSIX path, route to FilePreview)
/// - Anything else → `.none`
///
/// Relative paths (e.g. `./foo`) are intentionally `.none`: Ghostty resolves
/// paths against the terminal cwd before firing `GHOSTTY_ACTION_OPEN_URL`, so
/// a relative-path token is not a genuine Ghostty-generated file reference.
enum TerminalLinkClassifier {
    enum Result {
        case url(URL)
        case filePath(String)
        case none
    }

    nonisolated static func classify(_ raw: String) -> Result {
        guard !raw.isEmpty else { return .none }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            guard let url = URL(string: raw) else { return .none }
            return .url(url)
        }
        if raw.hasPrefix("file://") {
            guard let url = URL(string: raw),
                  let path = url.path.isEmpty ? nil : Optional(url.path) else { return .none }
            return .filePath(path)
        }
        if raw.hasPrefix("/") {
            return .filePath(raw)
        }
        return .none
    }
}

/// The side-effect a Ghostty surface action should produce in the host app.
/// Pure value type: no @MainActor, no AppKit imports needed to construct it.
enum GhosttyActionEffect {
    /// OSC 2 / escape-set title — update the tab label.
    case setTitle(String)
    /// CSS cursor name from the terminal program — update the system cursor shape.
    case mouseShape(ghostty_action_mouse_shape_e)
    /// Cmd+click on a http/https URL — open in the default browser.
    case openURL(URL)
    /// Cmd+click on an absolute file path or file:// URL — route to FilePreview.
    case openFilePath(String)
    /// OSC 9;4 progress: true while a task reports SET/INDETERMINATE/ERROR.
    case progressReport(active: Bool)
    /// Shell integration reported a finished command (nil exit code = unknown).
    case commandFinished(exitCode: Int?)
}

/// Pure mapper from a raw Ghostty action struct to an optional host effect.
/// `nonisolated` so it can be called from the runtime action_cb off main.
/// Returns `nil` for actions the host does not need to handle.
enum GhosttyActionMapper {
    nonisolated static func map(_ action: ghostty_action_s) -> GhosttyActionEffect? {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
            return .setTitle(title)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return .mouseShape(action.action.mouse_shape)
        case GHOSTTY_ACTION_OPEN_URL:
            guard let ptr = action.action.open_url.url else { return nil }
            let raw = String(cString: ptr)
            switch TerminalLinkClassifier.classify(raw) {
            case .url(let url):
                return .openURL(url)
            case .filePath(let path):
                return .openFilePath(path)
            case .none:
                return nil
            }
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let active: Bool
            switch action.action.progress_report.state {
            case GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_INDETERMINATE, GHOSTTY_PROGRESS_STATE_ERROR:
                active = true
            default:
                active = false
            }
            return .progressReport(active: active)
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let code = Int(action.action.command_finished.exit_code)
            return .commandFinished(exitCode: code >= 0 ? code : nil)
        default:
            return nil
        }
    }
}

/// Pure search/match layer for the terminal find bar (Cmd+F). Operates on a
/// plain-text snapshot of the terminal scrollback (read via GHOSTTY_POINT_SCREEN)
/// so the logic is testable without a live Ghostty surface or window server.
/// GhosttyKit exposes no `set_selection`/`scroll_to_point` API to embedders, so
/// the find bar drives match *location + navigation* over this snapshot (match
/// count and a current index that wraps); it cannot paint an in-terminal
/// highlight. Keeping the matching here keeps that boundary explicit and tested.
enum TerminalScrollbackSearch {
    /// All match ranges of `query` in `text`, case-insensitive, in document
    /// order, non-overlapping. Empty query returns no matches.
    static func matchRanges(in text: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            ranges.append(found)
            // Advance by at least one character so overlapping/zero-width cases
            // cannot loop forever; `found.lowerBound < found.upperBound` always
            // holds for a non-empty query, so we move past the start of the match.
            searchStart = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
        }
        return ranges
    }

    /// Next match index for prev/next navigation. `current == nil` means no match
    /// is selected yet: forward starts at 0, backward starts at the last match.
    /// With `wrap` true, stepping past either end wraps around. Returns nil when
    /// there are no matches.
    static func nextIndex(current: Int?, count: Int, forward: Bool, wrap: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        let candidate = forward ? current + 1 : current - 1
        if candidate < 0 {
            return wrap ? count - 1 : 0
        }
        if candidate >= count {
            return wrap ? 0 : count - 1
        }
        return candidate
    }
}

/// Per-workspace font zoom persistence helper.
///
/// Zoom is tracked as an integer step delta where each step equals 1 pt
/// (matching Ghostty's `increase_font_size:1` / `decrease_font_size:1`
/// binding actions). Storing the delta — rather than an absolute pt size —
/// avoids needing to know the user's configured base font size at restore
/// time: the app simply replays the same number of zoom steps.
///
/// All members are `nonisolated` so this can be tested without @MainActor.
enum FontZoomLevel {
    /// Inclusive lower bound on stored steps (20-pt reduction is an extreme
    /// floor; below this text becomes invisible on any sane base font size).
    static let minSteps: Int = -20
    /// Inclusive upper bound on stored steps (40-pt increase is generous;
    /// above this the font grid no longer fits usable terminal content).
    static let maxSteps: Int = 40

    /// Clamp `steps` to the safe `[minSteps, maxSteps]` range.
    nonisolated static func clamp(_ steps: Int) -> Int {
        min(maxSteps, max(minSteps, steps))
    }

    /// Serialize a (pre-clamped) step delta to a KV-storable string.
    nonisolated static func serialize(_ steps: Int) -> String {
        String(clamp(steps))
    }

    /// Deserialize a KV string back to a clamped step delta.
    /// Returns `nil` when the string is empty or non-numeric — the caller
    /// should treat `nil` as \"no stored zoom\" (delta 0).
    nonisolated static func deserialize(_ raw: String) -> Int? {
        guard !raw.isEmpty, let parsed = Int(raw) else { return nil }
        return clamp(parsed)
    }
}

/// Base terminal font-size preference. `0` preserves Ghostty's configured default.
public enum TerminalFontSizeSetting {
    public static let defaultSize: Double = 0
    public static let minSize: Double = 8
    public static let maxSize: Double = 32

    public nonisolated static func normalized(_ size: Double) -> Double {
        guard size.isFinite else { return defaultSize }
        guard size > defaultSize else { return defaultSize }
        return min(maxSize, max(minSize, size.rounded()))
    }

    public nonisolated static func displayLabel(_ size: Double) -> String {
        let normalized = normalized(size)
        guard normalized != defaultSize else { return L("Ghostty default") }
        return "\(Int(normalized)) pt"
    }
}

/// Pure helper that formats a human-readable scrollback position label.
///
/// Rules (matches common terminal conventions):
/// - `offset == 0` (at bottom, no lines above viewport): returns "Bottom"
/// - `offset >= total` (at top, cannot scroll further): returns "Top"
/// - Otherwise: "\(offset) lines from bottom" or, when total > 0, the percent
///   distance from the bottom expressed as 0-100%.
///
/// `offset` = lines scrolled above the bottom (0 = bottom).
/// `total`  = total scrollback line count (> 0 for a meaningful percent).
/// Both must be >= 0; negative inputs are treated as 0.
enum ScrollbackPositionLabel {
    /// Returns a display string for the current scrollback position.
    /// Pure: nonisolated, no AppKit.
    nonisolated static func label(offset: Int, total: Int) -> String {
        let safeOffset = max(0, offset)
        let safeTotal  = max(0, total)
        if safeOffset == 0 { return "Bottom" }
        if safeTotal > 0, safeOffset >= safeTotal { return "Top" }
        if safeTotal > 0 {
            let pct = Int(Double(safeOffset) / Double(safeTotal) * 100.0)
            let clamped = min(100, max(1, pct))
            return L("%1$@% from bottom", clamped)
        }
        return L("%1$@ lines from bottom", safeOffset)
    }
}

/// Maps a keyboard event (keyCode + modifiers) to the Ghostty binding-action
/// string for scrollback navigation, or nil if the event is not a scroll shortcut.
///
/// Handled bindings:
///   Shift+Page Up   -> "scroll_page_up"
///   Shift+Page Down -> "scroll_page_down"
///   Cmd+Home        -> "scroll_to_top"
///   Cmd+End         -> "scroll_to_bottom"
///
/// Pure: nonisolated static, no AppKit import dependency beyond NSEvent types.
/// Tested without a live surface or window server.
enum ScrollbackKeyAction {
    // macOS virtual key codes for navigation keys (hardware-independent).
    private static let keyCodePageUp:   UInt16 = 116
    private static let keyCodePageDown: UInt16 = 121
    private static let keyCodeHome:     UInt16 = 115
    private static let keyCodeEnd:      UInt16 = 119

    /// Returns the Ghostty binding-action string, or nil if not a scroll shortcut.
    nonisolated static func action(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        let device = modifiers.intersection(.deviceIndependentFlagsMask)
        switch keyCode {
        case keyCodePageUp   where device == .shift:  return "scroll_page_up"
        case keyCodePageDown where device == .shift:  return "scroll_page_down"
        case keyCodeHome     where device == .command: return "scroll_to_top"
        case keyCodeEnd      where device == .command: return "scroll_to_bottom"
        default: return nil
        }
    }
}

enum GhosttyTerminalKeyInput {
    /// How printable keyDowns must reach Ghostty.
    ///
    /// Full-screen TUIs (Grok, vim, etc.) enable Kitty keyboard progressive
    /// enhancement and treat `ghostty_surface_text` as *paste*, not typing.
    /// Space and other committed printables must go through `ghostty_surface_key`
    /// so the encoder emits proper key events. Dead keys / IME marked text still
    /// need AppKit `interpretKeyEvents` so composition can run.
    enum PrintableRoute: Equatable {
        /// Dead-key / IME composition — call `interpretKeyEvents` only.
        case composeViaTextInput
        /// Committed printable (incl. Space) — send `ghostty_surface_key` PRESS.
        case surfaceKey
    }

    static func printableRoute(hasMarkedText: Bool, characters: String?) -> PrintableRoute {
        if hasMarkedText { return .composeViaTextInput }
        if characters?.isEmpty != false { return .composeViaTextInput }
        return .surfaceKey
    }

    static func text(for event: NSEvent) -> String? {
        guard let text = event.characters, !text.isEmpty else { return nil }
        if text.count == 1, let scalar = text.unicodeScalars.first {
            if isControlCharacter(scalar) {
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                        ?? event.charactersIgnoringModifiers
                }
                return nil
            }
            if isPrivateUseArea(scalar) {
                return nil
            }
        }
        return text
    }

    static func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let text = event.characters(byApplyingModifiers: [])
                ?? event.charactersIgnoringModifiers
                ?? event.characters,
              let scalar = text.unicodeScalars.first else {
            return 0
        }
        return scalar.value
    }

    private static func isControlCharacter(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func isPrivateUseArea(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }
}

private final class RemoteCodeGhosttyRuntime {
    static let shared = RemoteCodeGhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private let tickCoalescer = TerminalTickCoalescer()

    private init() {
        initialize()
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }

    private func initialize() {
        configureGhosttyEnvironment()
        unsetenv("NO_COLOR")

        // ghostty_init starts Ghostty's embedded Breakpad, which takes over the
        // crash handlers and turns native crashes into a silent _exit. Give them
        // back to macOS ReportCrash once Ghostty is up, on every return path.
        let crashHandlerGuard = GhosttyCrashHandlerGuard.begin()
        defer { crashHandlerGuard.end() }

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            NSLog("RemoteCode Ghostty init failed: %d", result)
            return
        }

        guard let primaryConfig = makeConfig(loadUserFiles: true) else {
            NSLog("RemoteCode Ghostty config allocation failed")
            return
        }

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { _ in
            RemoteCodeGhosttyRuntime.shared.scheduleTick()
        }
        runtimeConfig.action_cb = { _, target, action in
            // The surface userdata is the pinned IO context, which outlives the
            // native surface. The generation tag drops effects that outlive
            // their surface (closed view, or a recreated surface on the same view).
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let ud = ghostty_surface_userdata(target.target.surface),
                  let effect = GhosttyActionMapper.map(action) else {
                return true
            }
            let context = Unmanaged<RemoteCodeGhosttyIOContext>.fromOpaque(ud).takeUnretainedValue()
            let generation = context.generation
            DispatchQueue.main.async { [weak context] in
                guard let view = context?.view, view.isCurrentNativeGeneration(generation) else { return }
                view.applyActionEffect(effect)
            }
            return true
        }
        runtimeConfig.read_clipboard_cb = ghosttyRuntimeReadClipboardCallback
        runtimeConfig.write_clipboard_cb = { _, _, content, length, _ in
            guard let content, length > 0 else { return }
            let items = UnsafeBufferPointer(start: content, count: Int(length))
            var fallback: String?
            for item in items {
                guard let data = item.data else { continue }
                let value = String(cString: data)
                if let mime = item.mime.map({ String(cString: $0) }),
                   mime.hasPrefix("text/plain") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    return
                }
                if fallback == nil {
                    fallback = value
                }
            }
            if let fallback {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fallback, forType: .string)
            }
        }
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.close_surface_cb = { _, _ in }

        if let app = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = app
            self.config = primaryConfig
            return
        }

        NSLog("RemoteCode Ghostty app allocation failed with user config: %@", diagnosticsSummary(for: primaryConfig))
        ghostty_config_free(primaryConfig)

        guard let fallbackConfig = makeConfig(loadUserFiles: false) else {
            NSLog("RemoteCode Ghostty fallback config allocation failed")
            return
        }
        guard let fallbackApp = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
            NSLog("RemoteCode Ghostty fallback app allocation failed")
            ghostty_config_free(fallbackConfig)
            return
        }

        self.app = fallbackApp
        self.config = fallbackConfig
    }

    private func makeConfig(loadUserFiles: Bool) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        if loadUserFiles {
            ghostty_config_load_default_files(config)
            ghostty_config_load_recursive_files(config)
        }
        loadInlineConfig(
            """
            macos-background-from-layer = true
            macos-titlebar-proxy-icon = hidden
            shell-integration = none
            scrollback-limit = 2000000
            window-padding-x = 0
            window-padding-y = 0
            keybind = super+d=unbind
            keybind = super+shift+d=unbind
            keybind = super+w=unbind
            keybind = super+alt+w=unbind
            keybind = super+shift+w=unbind
            """,
            into: config,
            prefix: "remote-code"
        )
        ghostty_config_finalize(config)
        return config
    }

    private func loadInlineConfig(_ text: String, into config: ghostty_config_t, prefix: String) {
        text.withCString { ptr in
            prefix.withCString { prefixPtr in
                ghostty_config_load_string(config, ptr, UInt(strlen(ptr)), prefixPtr)
            }
        }
    }

    private func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let bundledGhosttyURL = Self.bundledGhosttyResourcesURL(fileManager: fileManager)
        let ghosttyAppResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"

        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            if let bundledGhosttyURL,
               fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
                setenv("GHOSTTY_RESOURCES_DIR", bundledGhosttyURL.path, 1)
            } else if fileManager.fileExists(atPath: ghosttyAppResources) {
                setenv("GHOSTTY_RESOURCES_DIR", ghosttyAppResources, 1)
            }
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").map({ String(cString: $0) }) {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            appendEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: resourcesURL.deletingLastPathComponent().path,
                defaultValue: "/usr/local/share:/usr/share"
            )
            setenv("TERMINFO", resourcesURL.appendingPathComponent("terminfo").path, 0)
        }

        if getenv("TERM") == nil {
            setenv("TERM", "xterm-256color", 1)
        }
        if getenv("COLORTERM") == nil {
            setenv("COLORTERM", "truecolor", 1)
        }
        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "ghostty", 1)
        }
    }

    private static func bundledGhosttyResourcesURL(fileManager: FileManager) -> URL? {
        let candidates: [URL] = [
            Bundle.main.resourceURL?
                .appendingPathComponent("RemoteCode_Surfaces.bundle")
                .appendingPathComponent("ghostty"),
            Bundle.main.bundleURL
                .appendingPathComponent("RemoteCode_Surfaces.bundle")
                .appendingPathComponent("ghostty"),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("RemoteCode_Surfaces.bundle")
                .appendingPathComponent("ghostty")
        ].compactMap { $0 }

        return candidates.first { url in
            fileManager.fileExists(atPath: url.appendingPathComponent("themes").path)
        }
    }

    private func appendEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        guard !path.isEmpty else { return }
        let current = getenv(key).map { String(cString: $0) } ?? defaultValue ?? ""
        let parts = current.split(separator: ":").map(String.init)
        guard !parts.contains(path) else { return }
        let next = current.isEmpty ? path : "\(path):\(current)"
        setenv(key, next, 1)
    }

    private func scheduleTick() {
        guard tickCoalescer.trySchedule() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickCoalescer.complete()
            if let app = self.app {
                ghostty_app_tick(app)
            }
        }
    }

    func diagnosticsSummary() -> String {
        guard let config else { return "config=nil" }
        return diagnosticsSummary(for: config)
    }

    /// Read the resolved ANSI palette (indices 0-15) from the active Ghostty
    /// config and return it as an `ANSIThemeColors`.
    ///
    /// Uses `ghostty_config_get` with key `"palette"` to obtain the full 256-entry
    /// palette struct, then extracts only indices 0-15 (the SGR color range that
    /// `ANSIRenderer` uses). Returns `nil` when no config is loaded.
    ///
    /// WHY: `ANSIRenderer` is initialised with `themeColors: ANSIThemeColors?`.
    /// Without this extraction the renderer always falls back to its hardcoded
    /// defaults, producing a different visual palette than the Ghostty-rendered
    /// Mac surface — causing color drift in the iOS mirror.
    func resolvedANSIThemeColors() -> ANSIThemeColors? {
        guard let config else { return nil }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return nil
        }
        // ghostty_config_palette_s.colors is a C fixed-size array [256] which Swift
        // imports as a tuple. Access it safely via raw pointer to avoid Swift's
        // tuple-index limitations.
        let entries: [(index: Int, r: UInt8, g: UInt8, b: UInt8)] = withUnsafeBytes(of: palette.colors) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: ghostty_config_color_s.self)
            return (0..<16).map { i in
                let c = base[i]
                return (index: i, r: c.r, g: c.g, b: c.b)
            }
        }
        return ANSIRenderer.ansiThemeColors(from: entries)
    }

    private func diagnosticsSummary(for config: ghostty_config_t) -> String {
        let count = Int(ghostty_config_diagnostics_count(config))
        guard count > 0 else { return "diagnostics=0" }
        var parts: [String] = []
        for index in 0..<min(count, 5) {
            let diagnostic = ghostty_config_get_diagnostic(config, UInt32(index))
            let message = diagnostic.message.map { String(cString: $0) } ?? "(null)"
            parts.append("[\(index)] \(message)")
        }
        return "diagnostics=\(count) " + parts.joined(separator: " ")
    }
}

@MainActor
final class GhosttyTerminalView: NSView {
    var onInputData: ((Data) -> Void)?
    var onTerminalSizeChange: ((TerminalViewportSize) -> Void)?
    /// Called on the main thread when the terminal program changes its title (OSC 2).
    var onTitleChange: ((String) -> Void)?
    /// Called on the main thread when the terminal program reports or clears OSC 9;4 progress.
    var onProgressReport: ((Bool) -> Void)?
    /// Called on the main thread when shell integration reports a finished command.
    var onCommandFinished: ((Int?) -> Void)?
    /// Called on the main thread when the user Cmd+clicks an absolute file path
    /// (or file:// URL) in the terminal. The owning surface routes this to
    /// FilePreview / Diff. When nil, file-path Cmd+clicks are silently ignored.
    var onCmdClickFilePath: ((String) -> Void)?

    /// Called when a plain-text drag payload requires user confirmation before
    /// being sent to the PTY (same semantics as `TerminalTextView.onPasteNeedsConfirm`:
    /// multi-line or control-character content). The receiver should present a
    /// confirmation sheet and, on approval, call `writeInputData` with the
    /// UTF-8-encoded string. When nil, the text is sent without confirmation.
    var onPlainTextDragNeedsConfirm: ((String) -> Void)?

    /// Called when a Cmd+V paste payload requires user confirmation before
    /// being sent to the PTY (multi-line or control-character content).
    /// The receiver should present a confirmation sheet and, on approval, call
    /// `writeInputData` with the UTF-8-encoded string. When nil, the text is
    /// sent without confirmation (same fall-through as the drag path).
    var onPasteNeedsConfirm: ((String) -> Void)?

    /// Set by the owning TerminalSurface so the view can tell a legitimate teardown
    /// (the owner is closing) from a stray close of a still-visible instance
    /// (audit #4). Defaults to reporting "closing" so a view with no owner never
    /// spuriously resurrects a deliberately-closed surface.
    var ownerIsClosing: (() -> Bool)?

    /// Injected by the owning TerminalSurface to persist font zoom per workspace.
    /// When nil, zoom changes are session-only (not persisted).
    var fontZoomStore: (any SettingsWriteRepository)?
    /// KV key suffix that scopes zoom persistence to the workspace.
    /// Set to the workspace UUID string before the surface is first shown.
    var fontZoomWorkspaceID: String?
    /// Base font size passed to Ghostty at surface creation. 0 = Ghostty default.
    var baseFontSize: Double = TerminalFontSizeSetting.defaultSize
    /// Lets the PTY owner release reader backpressure only after every restored
    /// byte has entered the same Ghostty parser in order.
    var onHistoryReplayDrainCompleted: (() -> Void)?
    /// Transfers ownership of a whole live-output handoff back into the replay
    /// pump after the current buffer drains. This keeps one parser stream while
    /// allowing the owner to hold the bounded in-flight PTY handoff separately.
    var nextHistoryReplayContinuation: (() -> Data?)?
    /// Fires on the main actor whenever queued bytes shrink (a native chunk
    /// finished or the surface closed), so a paused PTY owner can resume.
    var onOutputCapacityAvailable: (() -> Void)?

    private let surfaceSlot = GhosttySurfaceSlot()
    private let ioContext = RemoteCodeGhosttyIOContext()
    /// Retained reference that pins ioContext for the Ghostty IO-thread lifetime.
    /// Set once in setup(), released in deinit after ghostty_surface_free returns
    /// so the raw userdata pointer passed to Ghostty can never dangle.
    private var ioContextRetain: Unmanaged<RemoteCodeGhosttyIOContext>?
    /// True while the IO-context retain is held; false after deinit releases it.
    /// Exposed for lifecycle tests only — do not use in production code paths.
    var ioContextIsPinned: Bool { ioContextRetain != nil }
    private var pendingOutput = Data()
    private var pendingOutputHead = 0
    private var pendingOutputCompactions = 0
    /// Bytes of the single chunk currently inside the C parser on `feedQueue`.
    private var feedInFlightBytes = 0
    /// In-flight chunk of a surface that close/reset already retired. Counted in
    /// memory accounting but not against the next generation's queue cap.
    private var retiredFeedBytes = 0
    /// One-shot actions waiting for the parser to absorb all queued output.
    private var drainActions: [String: () -> Void] = [:]
    private var lastViewportText: String?
    private var findCountPlaceholder: String?
    /// Destination of "Copy All"; tests replace it so the user's pasteboard stays untouched.
    var clipboardWriter: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Latched by renderable callers; consumed when the queue drains.
    private var refreshWhenOutputDrains = false
    /// Serial executor for every `ghostty_surface_process_output`. The C call can
    /// block on Ghostty's 64-slot app mailbox until `ghostty_app_tick` runs on the
    /// main thread, so it must never run on main or on the cooperative pool.
    private let feedQueue = DispatchQueue(
        label: "rc2.terminal.ghostty-feed.\(UUID().uuidString)",
        qos: .userInitiated
    )
    /// Replaces the C surface lifecycle so pump/close/reset can be tested without Ghostty.
    struct NativeDriverForTesting {
        var create: () -> ghostty_surface_t?
        var feed: @Sendable (ghostty_surface_t, Data) -> Void
        var free: (ghostty_surface_t) -> Void
        var setOcclusion: ((ghostty_surface_t, Bool) -> Void)?
        /// Native text read (`true` = scrollback, `false` = viewport).
        var read: ((Bool) -> String?)?
    }
    var nativeDriverForTesting: NativeDriverForTesting?
    private var historyReplayDrainInProgress = false
    private var surfaceCreationCount = 0
    private var maximumPendingOutputBytesObserved = 0
    private var nativeScrollbackBytesEstimate = 0
    private var releasedForTerminalMemoryBudget = false
    private var lastPixelSize = NSSize(width: 0, height: 0)
    private var lastScale = NSSize(width: 0, height: 0)
    private var visibleInUI = false
    /// Accumulated font zoom step delta for this surface (1 step = 1 pt).
    /// Persisted to and restored from the KV settings store keyed by workspace.
    private var zoomDelta: Int = 0
    /// Latched true by closeSurface() so a queued AppKit pass (layout/backing/move)
    /// cannot resurrect a freed surface via ensureSurface() on a view that is being
    /// torn down — that would bind a fresh ghostty surface (renderer + IO threads)
    /// to a dying view (use-after-free). Cleared only by the explicit reuse path
    /// resetSurfaceOutput().
    private var surfaceClosed = false
    private var dropHighlightLayer: CALayer?
    private var mouseTrackingArea: NSTrackingArea?
    /// In-progress IME composition (marked text). Empty when not composing.
    private var markedText = ""
    /// Count of bytes discarded from the front of `pendingOutput` on overflow
    /// while truly unrenderable (no live surface). Should stay 0 in normal
    /// operation; exposed via runtime health so tests/telemetry catch the drop
    /// path being hit (QA-006, guards PERF-009).
    var droppedOutputBytes = 0

    var pendingOutputDiagnosticsForTesting: (
        logicalBytes: Int,
        storageBytes: Int,
        compactions: Int
    ) {
        (pendingOutputByteCount, pendingOutput.count, pendingOutputCompactions)
    }

    private var pendingOutputByteCount: Int {
        max(0, pendingOutput.count - pendingOutputHead)
    }

    private var hasPendingOutput: Bool {
        pendingOutputByteCount > 0
    }

    /// Bytes queued for or inside the C parser. This is the figure the PTY owner
    /// paces against; it never counts owner-held handoffs.
    var outputBytesOwned: Int { pendingOutputByteCount + feedInFlightBytes }
    var feedInFlightForTesting: Bool { surfaceSlot.isFeedInFlight }
    var nativeSurfaceGenerationForTesting: UInt64 { surfaceSlot.generation }
    var nativeSurfaceStateForTesting: GhosttySurfaceSlot.State { surfaceSlot.state }

    /// True while the C parser drains this view's queue, so a full queue means the
    /// producer must wait. Without a live surface (pre-attach) the bounded
    /// drop-oldest contract applies instead and pausing would never resume.
    var drainsOutputNatively: Bool { surfaceSlot.isLive }

    /// Whether one more whole handoff of `bytes` fits below the queue cap.
    func hasOutputCapacity(forHandoffBytes bytes: Int) -> Bool {
        outputBytesOwned + bytes <= Self.maxPendingOutputBytes
    }

    var isRenderableForTesting: Bool { isRenderable }
    var hasLiveSurfaceForTesting: Bool { surfaceSlot.isLive }
    var historyReplayDrainInProgressForTesting: Bool { historyReplayDrainInProgress }
    var surfaceCreationCountForTesting: Int { surfaceCreationCount }
    var maximumPendingOutputBytesObservedForTesting: Int { maximumPendingOutputBytesObserved }
    var retainedTerminalBytesEstimate: Int {
        pendingOutput.count + feedInFlightBytes + retiredFeedBytes + nativeScrollbackBytesEstimate
    }
    var wasReleasedForTerminalMemoryBudgetForTesting: Bool {
        releasedForTerminalMemoryBudget
    }

    /// Creates the C parser on an attached (including hidden parking) host, but
    /// never requires the window to be visible/renderable. Returns false when a
    /// display is unavailable so callers must not suspend their PTY reader.
    func prepareHistoryReplayHost() -> Bool {
        if releasedForTerminalMemoryBudget {
            releasedForTerminalMemoryBudget = false
            surfaceClosed = false
        }
        ensureSurface()
        // A surface waiting for its last feed to finish is recreated by that feed's
        // completion, so the host is still available.
        return surfaceSlot.isLive || (surfaceSlot.isClosingWithDeferredFree && !surfaceClosed)
    }

    /// Find-in-scrollback (Cmd+F) overlay state. The bar is lazily built on first
    /// open. `findMatchCount`/`findCurrentMatch` are the navigation cursor over
    /// the last computed match set; they have no effect on rendering because
    /// GhosttyKit exposes no selection-set/scroll-to API (see
    /// `TerminalScrollbackSearch`).
    private var findBar: NSView?
    private var findField: NSTextField?
    private var findCountLabel: NSTextField?
    private var findMatchCount = 0
    private var findCurrentMatch: Int?

    /// Scrollback position indicator overlay (bottom-right corner). Lazily created
    /// on first `updateScrollbackPosition` call. Hidden when at the bottom.
    private var scrollbackIndicator: NSTextField?

    /// The most recent OSC 2 / SET_TITLE value received from the running program.
    /// Used to form the VoiceOver accessibility label "Terminal — <title>".
    /// Empty string means no title has been set yet; the label falls back to "Terminal".
    private var currentTitle: String = ""

    /// Transient font-zoom HUD overlay (bottom-left corner). Lazily created on
    /// first zoom action and auto-hidden after a brief delay.
    private var fontZoomHUD: NSTextField?
    /// Generation counter so only the most-recent zoom action dismisses the HUD.
    private var fontZoomHUDGeneration = 0

    /// Timestamp of the last VoiceOver `valueChanged` notification. Used to
    /// coalesce rapid-output notifications so VO is not spammed every 20ms.
    private var lastVOValueChangedAt: TimeInterval = 0
    /// Minimum interval between VoiceOver `valueChanged` notifications (seconds).
    private static let voValueChangedInterval: TimeInterval = 0.5

    static let maxPendingOutputBytes = 4 * 1024 * 1024
    /// Matches the enforced Ghostty config below. This is an accounting ceiling,
    /// not an additional allocation: Ghostty owns the native scrollback bytes.
    static let maxNativeScrollbackBytesEstimate = 2_000_000
    /// Largest chunk inside the C parser at once, for live output and replay alike.
    static let historyReplayChunkBytes = 8 * 1024

    // MARK: - Theme palette seam

    /// Return the 16-entry ANSI palette resolved from the active Ghostty theme
    /// config, or `nil` when no config is loaded (e.g. Ghostty failed to init).
    ///
    /// Callers (e.g. `TerminalSurface`) pass the result to
    /// `ANSIRenderer(themeColors:)` so the mirror ANSI snapshot uses the same
    /// colors the Mac Ghostty surface renders — eliminating cross-device color drift.
    ///
    /// WHY: `TerminalSurface` creates its `ANSIRenderer` without `themeColors`,
    /// so snapshot ANSI always uses the hardcoded default palette regardless of
    /// the user's configured Ghostty theme. This accessor exposes the resolved
    /// palette so `TerminalSurface` (or any other caller) can pass it at init time.
    static func resolvedANSIThemeColors() -> ANSIThemeColors? {
        RemoteCodeGhosttyRuntime.shared.resolvedANSIThemeColors()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Pull the raw C pointer out of the slot now (while self is still valid).
        // removeForClose() zeroes surfaceSlot.surface, so the pointer can only
        // come out of here once -- no double-free is possible.
        if let live = surfaceSlot.rawLiveSurface {
            if let occlusion = nativeDriverForTesting?.setOcclusion { occlusion(live, false) }
            else if nativeDriverForTesting == nil { ghostty_surface_set_occlusion(live, false) }
        }
        let surfaceToFree: ghostty_surface_t? = surfaceSlot.removeForClose()
        surfaceSlot.markClosed()
        // Capture ioContextRetain for release after ghostty_surface_free returns.
        // Ghostty's IO thread may call io_write_cb at any time up to and including
        // during ghostty_surface_free; releasing before the free completes would
        // leave a dangling userdata pointer on the IO thread (use-after-free).
        let pinnedContext = ioContextRetain
        // ghostty_surface_free must be called on the main thread.
        // Capture only the value-type pointer; never capture self in a deinit closure.
        // A running feed pins the view (see pumpOutput), so deinit never races one.
        let freeNative = nativeDriverForTesting?.free ?? { ghostty_surface_free($0) }
        if let ptr = surfaceToFree {
            if Thread.isMainThread {
                freeNative(ptr)
                // Safe to release now: ghostty_surface_free has returned, so
                // Ghostty will not dereference io_write_userdata again.
                pinnedContext?.release()
            } else {
                DispatchQueue.main.async {
                    freeNative(ptr)
                    // Same guarantee: release only after free completes.
                    pinnedContext?.release()
                }
            }
        } else {
            // No surface was ever created (or it was already freed by closeSurface).
            // Ghostty has no live reference to io_write_userdata, so release is safe.
            pinnedContext?.release()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // Expose the live viewport text as the accessibility value so XCUITest /
    // VoiceOver can read what the terminal currently shows (QA-001).
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    /// The last valid viewport stands in while the parser is still absorbing output.
    override func accessibilityValue() -> Any? { readViewportText() ?? lastViewportText }
    /// "Terminal — <title>" when an OSC title is set, otherwise "Terminal".
    /// VoiceOver reads this on focus so users know which tab they landed on.
    override func accessibilityLabel() -> String? {
        currentTitle.isEmpty ? "Terminal" : "Terminal \u{2014} \(currentTitle)"
    }

    override func makeBackingLayer() -> CALayer {
        guard Self.nativeRendererEnabled else { return CALayer() }
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        ioContext.view = self
        // Ghostty's IO thread may invoke io_write_cb (which dereferences this
        // ioContext via its raw userdata pointer) at any time, including around
        // surface free / view dealloc with no quiescence guarantee. Pin the tiny
        // context until ghostty_surface_free returns so that pointer can never
        // dangle into freed memory (use-after-free on a ghostty thread). The weak
        // `view` inside it goes nil on dealloc, so the callback safely no-ops.
        // The retained ref is released in deinit after ghostty_surface_free returns.
        ioContextRetain = Unmanaged.passRetained(ioContext)
        // Accept both file-URL drops (paths) and plain-text drops (literal text).
        // Plain .string is added here so dragging a selection from another app or
        // from a text editor inserts the text into the terminal rather than being
        // silently rejected.
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes + [.string])
    }

    /// AppKit calls this *before* our `window` actually changes. A terminal moved
    /// to a split pane or a new window is transiently windowless during the AppKit
    /// reparent (the workspace rebuild removes the subtree from its window before
    /// re-adding it): the CAMetalLayer loses its drawable while Ghostty's renderer
    /// (an internal display link) keeps running. Drawing into a windowless layer
    /// starves `nextDrawable` — the terminal "stops updating", and the held GPU
    /// drawable can stall the WindowServer (whole-system freeze). Suspend Ghostty's
    /// renderer here, *before* the window is torn away; `syncOcclusion()` re-enables
    /// it once the view is reattached to an on-screen window. Mirrors cmux, which
    /// sets occlusion off before reparenting a surface.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, let surface = surfaceSlot.liveSurface() else { return }
        ghostty_surface_set_occlusion(surface, false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowOcclusion(window)
        ensureSurface()
        updateGhosttySize(force: true)
        updateFocus()
        // Re-evaluate whether Ghostty may render now that the window changed: on
        // reattach to an on-screen window this resumes the renderer; on detach it
        // keeps it suspended (complements viewWillMove).
        syncOcclusion()
        // Parser work is independent of the window: a hidden parking host keeps
        // draining, otherwise the PTY reader could remain suspended indefinitely.
        if ownerIsClosing?() != true {
            pumpOutput()
        }
    }

    /// Observe per-window notifications. Occlusion: rendering is gated off while
    /// the window is off screen (see `isRenderable`), so on return to screen we
    /// redraw the current state (else a stale frame shows). Screen change: the
    /// surface's display id must follow the window across monitors, otherwise
    /// Ghostty renders against the wrong display's refresh/color profile.
    private func observeWindowOcclusion(_ window: NSWindow?) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.removeObserver(self, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        guard let window else { return }
        // S-F2: the key-window override depends on the active Space, and a Space
        // switch does not always post an occlusion change, so re-derive the gate.
        workspaceCenter.addObserver(self, selector: #selector(windowOcclusionDidChange),
                                    name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(windowOcclusionDidChange),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(windowDidChangeScreen),
                           name: NSWindow.didChangeScreenNotification, object: window)
    }

    @objc private func windowOcclusionDidChange() {
        // The window went on/off screen — fold that into Ghostty's occlusion so
        // its renderer suspends off screen and resumes on screen. This is also the
        // event that re-enables rendering after a move into a *new* window, once
        // that window is ordered front.
        syncOcclusion()
        guard isRenderable else { return }
        refreshSurfaceOnly()
    }

    @objc private func windowDidChangeScreen() {
        guard let surface = surfaceSlot.liveSurface(),
              let displayID = window?.screen?.displayID, displayID != 0 else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGhosttySize(force: true)
    }

    override func layout() {
        super.layout()
        updateGhosttySize(force: false)
        repositionScrollbackIndicator()
    }

    // Without a .mouseMoved tracking area, AppKit never delivers mouseMoved:, so
    // bare hover-motion reporting (DECSET 1003) never reaches TUIs (vim/htop/etc.).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    func closeSurface(silent: Bool = false, releaseHostCallbacks: Bool = true) {
        // Audit #4 watch: closing a surface whose view is still mounted on a window
        // is the exact precondition for the permanent-freeze bug. Log loudly so the
        // (unproven) wrong-instance-close trigger is observable in the field. `silent`
        // suppresses the watch for the legitimate re-create path (resetSurfaceOutput),
        // which intentionally closes a mounted view to rebuild it.
        if !silent, window != nil, superview != nil, ownerIsClosing?() != true {
            NSLog("RemoteCode terminal closeSurface() on a still-mounted view (window+superview present, owner not closing) — audit #4 watch")
        }
        historyReplayDrainInProgress = false
        surfaceClosed = true
        // Stop the native renderer before anything else: the owner may unmount the
        // NSView/CAMetalLayer right after this, and a deferred free keeps the
        // renderer alive until the in-flight feed ends, after viewWillMove can no
        // longer find the pointer.
        if let live = surfaceSlot.rawLiveSurface { setNativeOcclusion(live, false) }
        if surfaceSlot.isFeedInFlight {
            retiredFeedBytes += feedInFlightBytes
            feedInFlightBytes = 0
        }
        drainActions.removeAll()
        findCountPlaceholder = nil
        lastViewportText = nil
        // The surface is unavailable from here on. While a feed is inside the C
        // parser the free moves to that feed's main-thread completion; the main
        // thread must never wait for it.
        if let surface = surfaceSlot.removeForClose() {
            freeNative(surface)
        }
        surfaceSlot.markClosed()
        nativeScrollbackBytesEstimate = 0
        pendingOutput.removeAll(keepingCapacity: false)
        pendingOutputHead = 0
        refreshWhenOutputDrains = false
        // Queued bytes are gone: let a paused owner resume.
        DispatchQueue.main.async { [weak self] in self?.onOutputCapacityAvailable?() }
        // Drop host-side holds that otherwise survive until late view deinit
        // (owner callbacks, Metal drawable presentation state). Ghostty scrollback
        // is freed above; this path only clears Swift/AppKit residual state.
        // `resetSurfaceOutput` must keep owner callbacks — wiping them makes the
        // terminal look alive but silently drop every keystroke (PTY never gets
        // ghostty io_write → writeToPTY).
        if releaseHostCallbacks {
            releaseHostResourcesAfterClose()
        } else {
            clearDrawablePresentationState()
        }
    }

    /// Clears owner callbacks and drawable presentation state after the C surface
    /// is freed. Safe to call more than once; used by closeSurface and owner close.
    func releaseHostResourcesAfterClose() {
        onInputData = nil
        onTerminalSizeChange = nil
        onTitleChange = nil
        onProgressReport = nil
        onCommandFinished = nil
        onPasteNeedsConfirm = nil
        onPlainTextDragNeedsConfirm = nil
        onCmdClickFilePath = nil
        onHistoryReplayDrainCompleted = nil
        nextHistoryReplayContinuation = nil
        onOutputCapacityAvailable = nil
        ownerIsClosing = { true }
        clearDrawablePresentationState()
    }

    private func clearDrawablePresentationState() {
        pendingOutput.removeAll(keepingCapacity: false)
        pendingOutputHead = 0
        layer?.contents = nil
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.removeAllAnimations()
        }
    }

    @discardableResult
    func resetSurfaceOutput(_ data: Data) -> Bool {
        // A reset is all-or-nothing. Starting from a raw suffix would begin a
        // fresh parser inside UTF-8/CSI/OSC/DCS and corrupt every later byte.
        // Production applies PTY backpressure before this call and caps the
        // canonical seed below this bound, so rejection is a defensive seam.
        guard data.count <= Self.maxPendingOutputBytes else {
            droppedOutputBytes += data.count
            return false
        }
        releasedForTerminalMemoryBudget = false
        // Recreate the Ghostty C surface only. Keep owner callbacks (input/size/
        // title/paste) so history replay never permanently kills keyboard input.
        closeSurface(silent: true, releaseHostCallbacks: false)
        // Intentional re-creation: allow ensureSurface() to build a fresh surface.
        surfaceClosed = false
        historyReplayDrainInProgress = !data.isEmpty
        refreshWhenOutputDrains = !data.isEmpty
        guard appendPendingOutput(data) else {
            // The retired feed no longer counts, so this cannot happen for an
            // admitted seed; if it ever does, end the replay instead of hanging it.
            historyReplayDrainInProgress = false
            refreshWhenOutputDrains = false
            droppedOutputBytes += data.count
            return false
        }
        // `processOutput` intentionally buffers when no live C surface exists.
        // A mounted view cannot wait for a later read/refresh to recreate it:
        // restored idle tabs would remain blank indefinitely. Recreate now when
        // AppKit already provides a valid host; pre-attach views keep buffering.
        // While a feed still runs in the old surface the slot stays `closing`;
        // that feed's completion recreates the surface and seeds this buffer.
        if window != nil, bounds.width > 0, bounds.height > 0 {
            ensureSurface()
        }
        if findBar?.isHidden == false {
            recomputeFindMatches(forward: true, advance: false)
        }
        return true
    }

    /// Test seams for find: open the bar with `query` and report its result.
    func searchForTesting(_ query: String) {
        openFindBar()
        findField?.stringValue = query
        recomputeFindMatches(forward: true, advance: false)
    }
    var findStateForTesting: (matches: Int, label: String) {
        (findMatchCount, findCountLabel?.stringValue ?? "")
    }
    func closeFindForTesting() { closeFindBar() }
    var accessibilityValueForTesting: String? { accessibilityValue() as? String }
    var pendingDrainActionCountForTesting: Int { drainActions.count }
    func sendTextToSurfaceForTesting(_ text: String) {
        guard let surface = surfaceForInput() else { return }
        sendText(text, to: surface)
    }

    /// Test seam: whether the owner still receives Ghostty→PTY input writes.
    var hasInputDataHandlerForTesting: Bool { onInputData != nil }

    @discardableResult
    func processOutput(_ data: Data, render: Bool = true) -> Bool {
        guard !data.isEmpty else { return true }
        // A hidden surface evicted by the aggregate budget keeps its authoritative
        // ordered stream in TerminalSurface's bounded ANSI mirror + SQLite. Do not
        // regrow another raw 4 MiB queue while the native parser is deliberately
        // absent; reveal rebuilds Ghostty from that compact mirror.
        if releasedForTerminalMemoryBudget {
            return true
        }
        guard appendPendingOutput(data) else { return false }
        if render { refreshWhenOutputDrains = true }
        pumpOutput()
        return true
    }

    private func appendPendingOutput(_ data: Data) -> Bool {
        if data.count > Self.maxPendingOutputBytes - outputBytesOwned,
           historyReplayDrainInProgress || surfaceSlot.isLive {
            // Reject this complete producer handoff, whatever its size. Production
            // has already paused its PTY reader and reserved one full handoff below
            // the cap; the Boolean lets the owner retain and retry the whole chunk
            // in order, and callers stream anything larger in bounded batches. No
            // raw byte is cut, nothing above the cap is allocated, and the
            // parser/session remains intact.
            return false
        }
        pendingOutput.append(data)
        maximumPendingOutputBytesObserved = max(
            maximumPendingOutputBytesObserved,
            outputBytesOwned
        )
        // Never drop from the front while a live surface exists: that splits ANSI
        // escape sequences mid-stream and garbles rendering (PERF-009). The pump
        // hands every byte to Ghostty, which owns the scrollback.
        guard !surfaceSlot.isLive else { return true }
        // No surface to feed yet (truly unrenderable): bound memory as a last
        // resort by discarding the oldest bytes.
        guard outputBytesOwned > Self.maxPendingOutputBytes else { return true }
        let dropped = outputBytesOwned - Self.maxPendingOutputBytes
        droppedOutputBytes += dropped
        pendingOutputHead += dropped
        compactPendingOutputIfNeeded()
        return true
    }

    /// A front removal for every small chunk above the cap copies the full
    /// 4 MiB tail repeatedly. Keep a logical head and compact in 1 MiB batches
    /// so both physical storage and copy frequency remain bounded.
    private func compactPendingOutputIfNeeded() {
        let compactThreshold = 1024 * 1024
        guard pendingOutputHead >= compactThreshold else { return }
        pendingOutput = Data(pendingOutput[pendingOutputHead...])
        pendingOutputHead = 0
        pendingOutputCompactions += 1
    }

    /// Single-flight pump shared by live output and history replay: at most one
    /// `historyReplayChunkBytes` slice is inside the C parser, executed on
    /// `feedQueue`. The main thread keeps running Ghostty's app ticks, which is
    /// what lets a feed blocked on a full mailbox finish. The in-flight closures
    /// retain the view so it cannot deinit under a running feed.
    private func pumpOutput() {
        guard hasPendingOutput, let surface = surfaceSlot.beginFeed() else { return }
        let byteCount = min(Self.historyReplayChunkBytes, pendingOutputByteCount)
        let start = pendingOutputHead
        let chunk = Data(pendingOutput[start..<(start + byteCount)])
        pendingOutputHead = start + byteCount
        if hasPendingOutput {
            compactPendingOutputIfNeeded()
        } else {
            // Keep capacity only for small bursts so one large handoff cannot pin
            // megabytes of idle storage for the life of the terminal.
            pendingOutput.removeAll(keepingCapacity: pendingOutput.count <= 256 * 1024)
            pendingOutputHead = 0
        }
        feedInFlightBytes = byteCount
        nativeScrollbackBytesEstimate = min(
            Self.maxNativeScrollbackBytesEstimate,
            nativeScrollbackBytesEstimate + byteCount
        )
        let feed = nativeDriverForTesting?.feed ?? Self.feedNative
        feedQueue.async {
            feed(surface, chunk)
            DispatchQueue.main.async { self.feedDidComplete() }
        }
    }

    private static let feedNative: @Sendable (ghostty_surface_t, Data) -> Void = { surface, chunk in
        chunk.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_process_output(
                surface,
                base.assumingMemoryBound(to: CChar.self),
                UInt(raw.count)
            )
        }
    }

    private func freeNative(_ surface: ghostty_surface_t) {
        if let free = nativeDriverForTesting?.free {
            free(surface)
        } else {
            ghostty_surface_free(surface)
        }
    }

    private func feedDidComplete() {
        feedInFlightBytes = 0
        retiredFeedBytes = 0
        if let doomed = surfaceSlot.endFeed() {
            // Close/reset arrived while this feed was in the parser. Free exactly
            // once now that no C call can touch the surface, then recreate for a
            // pending reset (the slot stayed `closing`, so no second renderer
            // could have been bound to this view meanwhile).
            freeNative(doomed)
            surfaceSlot.markClosed()
            if !surfaceClosed {
                ensureSurface()
            }
            runDrainActionsIfQuiescent()
            onOutputCapacityAvailable?()
            return
        }
        guard surfaceSlot.isLive else {
            onOutputCapacityAvailable?()
            return
        }
        if hasPendingOutput {
            pumpOutput()
        } else if historyReplayDrainInProgress {
            // Ownership moves as one complete handoff. Feed it through the same
            // bounded pump and the same C parser.
            if let continuation = nextHistoryReplayContinuation?(), !continuation.isEmpty {
                pendingOutput = continuation
                pendingOutputHead = 0
                maximumPendingOutputBytesObserved = max(
                    maximumPendingOutputBytesObserved,
                    continuation.count
                )
                pumpOutput()
            } else {
                historyReplayDrainInProgress = false
                refreshAfterDrain()
                onHistoryReplayDrainCompleted?()
            }
        } else {
            refreshAfterDrain()
        }
        runDrainActionsIfQuiescent()
        onOutputCapacityAvailable?()
    }

    /// Runs requests that arrived while a read had to return nil. This is the only
    /// place they run, on main, so no read ever waits for the feed.
    private func runDrainActionsIfQuiescent() {
        guard outputBytesOwned == 0, !historyReplayDrainInProgress, !drainActions.isEmpty else { return }
        let actions = drainActions
        drainActions.removeAll()
        for action in actions.values { action() }
    }

    private func onOutputDrained(key: String, _ action: @escaping () -> Void) {
        drainActions[key] = action
        pumpOutput()
    }

    private func setNativeOcclusion(_ surface: ghostty_surface_t, _ visible: Bool) {
        if let driver = nativeDriverForTesting {
            driver.setOcclusion?(surface, visible)
        } else {
            ghostty_surface_set_occlusion(surface, visible)
        }
    }

    private func refreshAfterDrain() {
        let shouldRefresh = refreshWhenOutputDrains
        refreshWhenOutputDrains = false
        guard shouldRefresh, isRenderable, let surface = surfaceSlot.liveSurface() else { return }
        // Do NOT render synchronously on the main thread. ghostty_surface_render_now
        // makes the main thread a second renderer running concurrently with Ghostty's
        // own renderer thread and its cf_release thread, which races the CoreText
        // shaper's deferred-CFRelease pool (use-after-free, EXC_BAD_ACCESS in
        // cf_release_thread). Only post an async refresh so Ghostty's single
        // renderer thread draws.
        ghostty_surface_refresh(surface)
        // Notify VoiceOver that the terminal content changed so screen readers
        // can re-read the viewport. Coalesced to avoid spamming VO on rapid output.
        postVOValueChangedIfNeeded()
    }

    /// Frees the native parser/Metal scrollback for an inactive terminal while
    /// preserving owner callbacks. TerminalSurface keeps a compact ordered mirror
    /// and reconstructs this parser on reveal. Idempotent and main-thread only.
    func releaseForTerminalMemoryBudget() {
        guard !releasedForTerminalMemoryBudget else { return }
        closeSurface(silent: true, releaseHostCallbacks: false)
        releasedForTerminalMemoryBudget = true
    }

    private func postVOValueChangedIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVOValueChangedAt >= Self.voValueChangedInterval else { return }
        lastVOValueChangedAt = now
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Apply an effect produced by the Ghostty runtime action callback.
    /// Called on the main thread (dispatched from action_cb).
    func applyActionEffect(_ effect: GhosttyActionEffect) {
        switch effect {
        case .setTitle(let title):
            currentTitle = title
            onTitleChange?(title)
        case .progressReport(let active):
            onProgressReport?(active)
        case .commandFinished(let exitCode):
            onCommandFinished?(exitCode)
        case .mouseShape(let shape):
            NSCursor.pop()
            if let cursor = Self.cursor(for: shape) {
                cursor.push()
            }
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .openFilePath(let path):
            if let handler = onCmdClickFilePath {
                handler(path)
            } else {
                // Fallback: open in the default app (e.g. Xcode for .swift files)
                // when no in-app routing is configured.
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    /// Map a Ghostty mouse-shape enum value to the closest AppKit NSCursor.
    /// Returns nil for the default cursor (pop-only, no push).
    nonisolated static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor? {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            return nil
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB, GHOSTTY_MOUSE_SHAPE_GRABBING:
            return .closedHand
        case GHOSTTY_MOUSE_SHAPE_MOVE:
            return .openHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY:
            return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS:
            return .dragLink
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_WAIT, GHOSTTY_MOUSE_SHAPE_PROGRESS:
            return .arrow
        default:
            return .arrow
        }
    }

    func writeInputData(_ data: Data) {
        onInputData?(data)
    }

    /// A native callback is current only while its own surface is live: closed
    /// views and recreated surfaces never receive effects from an older one.
    func isCurrentNativeGeneration(_ generation: UInt64) -> Bool {
        guard case .live(let current) = surfaceSlot.state else { return false }
        return current == generation
    }

    func writeInputData(_ data: Data, fromNativeGeneration generation: UInt64) {
        guard isCurrentNativeGeneration(generation) else { return }
        writeInputData(data)
    }

    func forceRefresh() {
        guard isRenderable else { return }
        ensureSurface()
        // #2: restart a possibly-stalled display link before asking it to draw.
        reassertDisplayID()
        // Renderable again (e.g. reattached to an on-screen window after a move) —
        // make sure Ghostty's renderer is resumed before we ask it to draw.
        syncOcclusion()
        updateGhosttySize(force: true)
        pumpOutput()
        if let surface = surfaceSlot.liveSurface() {
            // Async refresh only — never render on the main thread (see refreshAfterDrain).
            ghostty_surface_refresh(surface)
        }
    }

    func refreshSurfaceOnly() {
        guard isRenderable else { return }
        ensureSurface()
        // #2: restart a possibly-stalled display link on reveal/relayout.
        reassertDisplayID()
        // Resume the renderer on reattach/relayout while renderable. This is the
        // reliable resume path after a move to a new window (driven by the
        // container's layout/window-change), independent of occlusion notifications.
        syncOcclusion()
        // F2: paint any output buffered while occluded on reveal — a bare refresh
        // would only repaint the stale frame and the tail lines would be missing.
        pumpOutput()
        let refreshedByResize = updateGhosttySize(force: true)
        guard !refreshedByResize else { return }
        if let surface = surfaceSlot.liveSurface() {
            ghostty_surface_refresh(surface)
        }
    }

    func setOcclusion(visible: Bool) {
        visibleInUI = visible
        if !visible {
            // F2: do NOT silently DROP the buffered tail on hide. The pump keeps
            // feeding the live surface (Ghostty owns the scrollback) without
            // rendering, so switching away mid-stream and back doesn't lose the
            // last lines. Hiding never cancels parser bytes.
            pumpOutput()
        }
        // Drive Ghostty's occlusion from the *full* render gate, not raw tab
        // visibility: a selected tab whose window is off screen or mid-move must
        // still keep the renderer suspended. The next on-screen event resumes it.
        syncOcclusion()
    }

    /// Single source of truth for Ghostty's occlusion: the renderer may run only
    /// when the surface is actually renderable (selected tab AND an on-screen,
    /// sized, non-minimized window). Suspending it whenever that is false is what
    /// stops it from drawing into a windowless/off-screen CAMetalLayer
    /// (`nextDrawable` starvation → freeze, or an AGX trap). Cheap, idempotent,
    /// main-thread-only flag set.
    private func syncOcclusion() {
        guard let surface = surfaceSlot.liveSurface() else { return }
        ghostty_surface_set_occlusion(surface, isRenderable)
    }

    /// Reassert the surface's display id to the current screen. Ghostty's renderer
    /// runs an internal CVDisplayLink that can stop delivering frames ("stuck vsync")
    /// after a display sleep/wake or a reparent, sometimes with no
    /// `didChangeScreen` notification to re-kick it — the visible terminal then
    /// freezes while emulation continues (audit #2). Re-pinning the display id
    /// restarts the link. Called on focus, refresh, and user scroll, mirroring cmux
    /// (which reasserts after focus and before every forceRefresh). Cheap/idempotent.
    private func reassertDisplayID() {
        guard let surface = surfaceSlot.liveSurface(),
              let displayID = window?.screen?.displayID ?? NSScreen.main?.displayID,
              displayID != 0 else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    /// Whether the view is, RIGHT NOW, on a key, on-screen, non-minimized window with
    /// real bounds and not AppKit-hidden — independent of the logical tab-visibility
    /// flag (`visibleInUI`). Used by the owner to detect a "stuck hidden" desync
    /// (audit #3): the surface believes it is hidden (readerAllowsRender/occlusion
    /// latched off) while the user is actually looking at this exact view. The key +
    /// occlusion-visible + not-hidden combination cannot hold for a correctly-hidden
    /// background tab, so it is a safe trigger to self-heal.
    var isDefinitelyOnScreen: Bool {
        guard let window, !isHidden, bounds.width > 1, bounds.height > 1 else { return false }
        guard window.isVisible, !window.isMiniaturized, window.isKeyWindow else { return false }
        // A collapsed/zero-width split pane keeps a key, on-screen window but is itself
        // not visible: reject if any ancestor is hidden (matches renderDiagnostics'
        // hiddenAncestor gate) so the stuck-hidden heal can't misfire on it.
        var ancestor = superview
        while let node = ancestor {
            if node.isHidden { return false }
            ancestor = node.superview
        }
        return window.occlusionState.contains(.visible)
    }

    func readViewportText() -> String? {
        let text = readText(pointTag: GHOSTTY_POINT_VIEWPORT)
        if let text { lastViewportText = text }
        return text
    }

    /// Full terminal screen text including scrollback (GHOSTTY_POINT_SCREEN),
    /// used as the snapshot the find bar searches over.
    func readScrollbackText() -> String? {
        readText(pointTag: GHOSTTY_POINT_SCREEN)
    }

    private func readText(pointTag: ghostty_point_tag_e) -> String? {
        ensureSurface()
        guard surfaceSlot.isLive else { return nil }
        // The parser has not absorbed all output yet. Never wait for the feed (it
        // may be waiting for a main-thread tick): keep it draining and let the
        // caller fall back to its ANSI mirror instead of reading stale text.
        guard outputBytesOwned == 0 else {
            pumpOutput()
            return nil
        }
        if let driver = nativeDriverForTesting { return driver.read?(pointTag == GHOSTTY_POINT_SCREEN) }
        guard let surface = surfaceSlot.liveSurface() else { return nil }

        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    private func ensureSurface() {
        if let driver = nativeDriverForTesting {
            guard !releasedForTerminalMemoryBudget, !surfaceClosed,
                  !surfaceSlot.isLive,
                  let generation = surfaceSlot.beginCreate() else { return }
            ioContext.generation = generation
            guard let created = driver.create(),
                  surfaceSlot.install(created, generation: generation, synthetic: true) else {
                surfaceSlot.cancelCreate(generation: generation)
                return
            }
            surfaceCreationCount += 1
            pumpOutput()
            return
        }
        guard Self.nativeRendererEnabled else { return }
        guard !releasedForTerminalMemoryBudget else { return }
        if surfaceClosed {
            // Audit #4: a closed surface normally stays closed, but if this view is
            // still mounted on a window with valid bounds while the owner is NOT
            // tearing down, it was closed on the wrong (still-visible) instance —
            // recover instead of leaving the tab permanently frozen.
            guard Self.shouldResurrectClosedSurface(
                surfaceClosed: true,
                hasWindow: window != nil,
                hasNonEmptyBounds: bounds.width > 0 && bounds.height > 0,
                ownerClosing: ownerIsClosing?() ?? true
            ) else { return }
            NSLog("RemoteCode terminal resurrecting a surface closed on a still-visible view (audit #4)")
            surfaceClosed = false
        }
        guard surfaceSlot.liveSurface() == nil else { return }
        guard window != nil else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let app = RemoteCodeGhosttyRuntime.shared.app else { return }
        guard Self.hasActiveDisplay() else { return }
        guard let displayID = window?.screen?.displayID ?? NSScreen.main?.displayID,
              displayID != 0 else { return }
        guard let generation = surfaceSlot.beginCreate() else { return }
        ioContext.generation = generation

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        // The pinned IO context, not the view: callbacks that outlive the surface
        // must resolve to a generation-tagged object that never dangles.
        config.userdata = Unmanaged.passUnretained(ioContext).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        config.font_size = Float(baseFontSize)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        config.io_write_cb = ghosttyTerminalIOWriteCallback
        config.io_write_userdata = Unmanaged.passUnretained(ioContext).toOpaque()

        guard let created = ghostty_surface_new(app, &config) else {
            surfaceSlot.cancelCreate(generation: generation)
            #if DEBUG
            NSLog(
                "RemoteCode Ghostty surface allocation failed bounds=%@ window=%d layer=%d %@",
                NSStringFromRect(bounds),
                window == nil ? 0 : 1,
                layer == nil ? 0 : 1,
                RemoteCodeGhosttyRuntime.shared.diagnosticsSummary()
            )
            #endif
            return
        }

        guard surfaceSlot.install(created, generation: generation) else {
            ghostty_surface_free(created)
            return
        }
        surfaceCreationCount += 1
        ghostty_surface_set_display_id(created, displayID)
        // Restore persisted zoom before the first size update so the grid
        // dimensions reported to the PTY already reflect the correct cell size.
        // Guard: if zoomDelta is already non-zero (e.g. this surface was
        // restarted via resetSurfaceOutput and the in-memory delta is still
        // set), skip the store read to avoid a double-apply.
        if zoomDelta == 0 {
            restoreZoomDelta()
        } else {
            let bindingAction = zoomDelta > 0
                ? "increase_font_size:\(zoomDelta)"
                : "decrease_font_size:\(-zoomDelta)"
            performBindingAction(bindingAction)
        }
        updateGhosttySize(force: true)
        updateFocus()
        pumpOutput()
        // A freshly created surface inherits the current render gate: only run its
        // renderer (and ask for a first frame) when actually on screen — not merely
        // when the tab is selected (the window may be off screen / not yet ordered
        // front during a move).
        syncOcclusion()
        if isRenderable {
            ghostty_surface_refresh(created)
        }
    }

    private var isRenderable: Bool {
        let onScreen = window?.occlusionState.contains(.visible) ?? false
        let keyOverride = keyOverrideInputs(windowOnScreen: onScreen)
        return Self.canRender(
            visibleInUI: visibleInUI,
            isHidden: isHiddenOrHasHiddenAncestor,
            hasNonEmptyBounds: bounds.width > 0 && bounds.height > 0,
            windowPresent: window != nil,
            windowVisible: window?.isVisible ?? false,
            windowMiniaturized: window?.isMiniaturized ?? false,
            windowOnScreen: onScreen,
            windowIsKey: keyOverride.windowIsKey,
            windowOnActiveSpace: keyOverride.windowOnActiveSpace
        )
    }

    /// Inputs for `canRender`'s key-window override, probed lazily (see
    /// `keyOverrideInputs`) because `isRenderable` runs on every output drain.
    private func keyOverrideInputs(windowOnScreen: Bool) -> (windowIsKey: Bool, windowOnActiveSpace: Bool) {
        let window = self.window
        return Self.keyOverrideInputs(
            windowOnScreen: windowOnScreen,
            // Require a LIVE drawable (awake display), so the false-negative heal
            // can never render into an asleep display (the AGX trap the gate exists
            // to prevent).
            keyLiveDrawable: { Self.windowHasLiveKeyDrawable(window) },
            // S-F2: a key window can stay key while its Space is not shown.
            onActiveSpace: { window?.isOnActiveSpace ?? false }
        )
    }

    /// The key-window override (audit #1) only matters when occlusionState says
    /// not-visible, and the Space check only matters for a key window with a live
    /// drawable. Each probe runs only when the previous one allows the override, so
    /// an occlusion-visible window, or a non-key one (every output drain of a
    /// covered or background window), never pays for `isOnActiveSpace`, which is a
    /// WindowServer round trip on the main thread.
    nonisolated static func keyOverrideInputs(
        windowOnScreen: Bool,
        keyLiveDrawable: () -> Bool,
        onActiveSpace: () -> Bool
    ) -> (windowIsKey: Bool, windowOnActiveSpace: Bool) {
        guard !windowOnScreen, keyLiveDrawable() else { return (false, false) }
        return (true, onActiveSpace())
    }

    /// A key, visible, non-minimized window normally has a live Metal drawable — EXCEPT
    /// when its display is asleep, in which case there is no surface to render into
    /// (rendering then is the AGX trap / silent-vanish). This is the safe predicate the
    /// occlusionState-false-negative heal (audit #1) is allowed to trust.
    private static func windowHasLiveKeyDrawable(_ window: NSWindow?) -> Bool {
        guard let window, window.isKeyWindow, window.isVisible, !window.isMiniaturized else { return false }
        // Defensive: the override is for a window the user is looking at in the
        // active app. Whether `isKeyWindow` can still read true for an inactive
        // app's window on every deactivation path is not verified, so this cheap
        // local check keeps the override from depending on it.
        guard NSApp.isActive else { return false }
        guard let displayID = window.screen?.displayID, displayID != 0 else { return false }
        return CGDisplayIsAsleep(displayID) == 0
    }

    /// Whether it is safe to render the Metal surface. A minimized or ordered-out
    /// window keeps a non-nil `window`, but its CAMetalLayer has no valid
    /// drawable; rendering into it (`render_now`) dereferences a freed
    /// framebuffer texture and traps inside the GPU driver (EXC_BREAKPOINT in AGX
    /// `renderCommandEncoderWithDescriptor:`), which Ghostty's embedded crash
    /// reporter turns into a silent `_exit`. `occlusionState` is the signal
    /// AppKit guarantees for "the window's content is actually on screen". Pure
    /// so the off-screen invariant can be tested without a window server.
    nonisolated static func canRender(
        visibleInUI: Bool,
        isHidden: Bool,
        hasNonEmptyBounds: Bool,
        windowPresent: Bool,
        windowVisible: Bool,
        windowMiniaturized: Bool,
        windowOnScreen: Bool,
        windowIsKey: Bool,
        windowOnActiveSpace: Bool
    ) -> Bool {
        guard visibleInUI, !isHidden, hasNonEmptyBounds, windowPresent else { return false }
        // GPU-safety invariant is unchanged: a minimized or ordered-out (invisible)
        // window has no valid Metal drawable and must never be rendered into.
        guard windowVisible, !windowMiniaturized else { return false }
        // `windowOnScreen` (occlusionState.contains(.visible)) has documented AppKit
        // false-negatives: after a Space switch / display sleep-wake it can report
        // not-visible while the window is genuinely front and on screen, with no
        // follow-up didChangeOcclusionState notification — which latched the renderer
        // OFF permanently (audit #1: frozen frame, dead scroll, dead echo). A KEY
        // window is by definition the focused front window of the active app, so it
        // HAS a live on-screen drawable. OR it in so a stale occlusionState can never
        // freeze a window the user is actively looking at. (cmux never gates render
        // purely on occlusionState for the same reason.) The override still requires
        // the active Space (S-F2): a key window on a Space that is not shown has no
        // on-screen drawable, and rendering into it is the AGX trap again.
        return windowOnScreen || (windowIsKey && windowOnActiveSpace)
    }

    /// Decide whether a surface that was closed (`surfaceClosed == true`) should be
    /// resurrected. A closed surface normally stays closed — but if the view is still
    /// mounted on a window with valid bounds while its OWNER is not tearing down, the
    /// surface was closed on the wrong (still-visible) instance (audit #4: a permanent
    /// input + scroll freeze, dead until app relaunch). In that case rebuild so a
    /// keystroke / scroll / output recovers the tab. Pure/static so the decision is
    /// unit-testable without AppKit.
    nonisolated static func shouldResurrectClosedSurface(
        surfaceClosed: Bool,
        hasWindow: Bool,
        hasNonEmptyBounds: Bool,
        ownerClosing: Bool
    ) -> Bool {
        surfaceClosed && hasWindow && hasNonEmptyBounds && !ownerClosing
    }

    private static func hasActiveDisplay() -> Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
    }

    private static let nativeRendererEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        guard env["RC2_ENABLE_GHOSTTY_IN_TESTS"] != "1" else { return true }
        guard env["XCTestConfigurationFilePath"] == nil else { return false }
        return ProcessInfo.processInfo.processName != "xctest"
    }()

    private func updateFocus() {
        guard let surface = surfaceSlot.liveSurface() else { return }
        let focused = window?.firstResponder === self
        ghostty_surface_set_focus(surface, focused)
        // #2: focusing the terminal is the cheapest reliable moment to restart a
        // CVDisplayLink that stalled while the window was inactive/asleep.
        if focused { reassertDisplayID() }
    }

    @discardableResult
    private func updateGhosttySize(force: Bool) -> Bool {
        ensureSurface()
        guard let surface = surfaceSlot.liveSurface() else { return false }
        guard bounds.width > 0, bounds.height > 0 else { return false }

        let backing = convertToBacking(NSRect(origin: .zero, size: bounds.size)).size
        guard backing.width > 0, backing.height > 0 else { return false }

        let pixelWidth = max(UInt32(1), UInt32(floor(backing.width)))
        let pixelHeight = max(UInt32(1), UInt32(floor(backing.height)))
        let xScale = Double(backing.width / bounds.width)
        let yScale = Double(backing.height / bounds.height)
        let nextPixelSize = NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let nextScale = NSSize(width: xScale, height: yScale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = nextPixelSize
            metalLayer.contentsScale = CGFloat(max(xScale, yScale))
        }
        CATransaction.commit()

        guard force || nextPixelSize != lastPixelSize || nextScale != lastScale else { return false }
        lastPixelSize = nextPixelSize
        lastScale = nextScale

        ghostty_surface_set_content_scale(surface, xScale, yScale)
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
        let size = ghostty_surface_size(surface)
        let rows = max(1, Int(size.rows))
        let cols = max(1, Int(size.columns))
        onTerminalSizeChange?(TerminalViewportSize(rows: rows, cols: cols))
        // Gate the post-resize redraw on the *full* render gate, not raw tab
        // visibility. `viewDidMoveToWindow` calls this with `force: true` even when
        // the view is transiently windowless mid-move; refreshing then would drive
        // Ghostty into a windowless drawable and freeze (this was the bug).
        if isRenderable {
            ghostty_surface_refresh(surface)
        }
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        updateFocus()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        updateFocus()
        return ok
    }

    override func keyDown(with event: NSEvent) {
        guard let surface = surfaceForInput() else { return }
        // Re-derive a stale render gate (audit #1) before the input is handled —
        // otherwise a latched-off occlusion swallows the echo and typing looks dead.
        // This re-checks the same gate; it does not force rendering. A key window
        // can receive keystrokes while its Space is not shown, so a stuck
        // occlusionState heals here only if `isOnActiveSpace` reads true (S-F2).
        syncOcclusion()
        // Ghostty can ignore surface_key while focus is latched off after park/
        // reattach (firstResponder repair races layout). A keystroke is proof the
        // user intends this surface — force focus before dispatching the key.
        ghostty_surface_set_focus(surface, true)
        reassertDisplayID()
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c":
                copySelection(from: surface)
                return
            case "v":
                pasteText(to: surface)
                return
            case "+", "=": // Cmd-+ (and bare Cmd-= without shift) → zoom in
                changeFontSize("increase_font_size:1")
                return
            case "-", "_": // Cmd-- → zoom out
                changeFontSize("decrease_font_size:1")
                return
            case "0": // Cmd-0 → reset zoom
                changeFontSize("reset_font_size")
                return
            case "f": // Cmd-F → find in scrollback
                openFindBar()
                return
            default:
                break
            }
        }
        // Esc closes the find bar when it is open, before the keystroke reaches
        // the terminal program.
        if findBar?.isHidden == false, event.keyCode == 53 {
            closeFindBar()
            return
        }
        // Scrollback keyboard navigation: Shift+PgUp/PgDn, Cmd+Home/End.
        // Intercepted before the Ghostty key path so these bindings work
        // regardless of whether the running program handles PgUp/PgDn.
        if let scrollAction = ScrollbackKeyAction.action(for: event.keyCode, modifiers: event.modifierFlags) {
            performBindingAction(scrollAction)
            return
        }
        if TerminalKeyboardInput.shouldUseTextInput(for: event) {
            // Dead keys / IME: empty `characters` or active marked text must go
            // through AppKit so ABNT2/US-International can compose ã/é/õ.
            // Committed printables (Space, a-z, digits, punctuation) must use
            // ghostty_surface_key — not interpretKeyEvents→surface_text — so
            // TUIs like Grok receive typed key events (Kitty keyboard protocol)
            // instead of paste-style injection that they ignore for prompt input.
            switch GhosttyTerminalKeyInput.printableRoute(
                hasMarkedText: hasMarkedText(),
                characters: event.characters
            ) {
            case .composeViaTextInput:
                interpretKeyEvents([event])
                return
            case .surfaceKey:
                sendGhosttyKeyPress(event, to: surface)
                return
            }
        }
        sendGhosttyKeyPress(event, to: surface)
    }

    /// Deliver a key press/repeat to Ghostty with optional UTF-8 text attached.
    private func sendGhosttyKeyPress(_ event: NSEvent, to surface: ghostty_surface_t) {
        var key = ghosttyKeyEvent(for: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        if let text = textForEvent(event) {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surfaceForInput() else { return }
        var key = ghosttyKeyEvent(for: event, action: GHOSTTY_ACTION_RELEASE)
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // When the foreground app is reporting mouse events (TUIs like vim/htop),
        // forward the right button so it reaches the program. Otherwise let
        // AppKit present the context menu from `menu(for:)` (UX-007).
        if isMouseCaptured {
            sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isMouseCaptured else { return }
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // No AppKit menu while the program owns the mouse; the right button was
        // already forwarded in `rightMouseDown` (UX-007).
        guard !isMouseCaptured else { return nil }
        return makeContextMenu()
    }

    private var isMouseCaptured: Bool {
        guard let surface = surfaceSlot.liveSurface() else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hasSelection = surfaceSlot.liveSurface().map { ghostty_surface_has_selection($0) } ?? false
        let hasClipboardText = (NSPasteboard.general.string(forType: .string)?.isEmpty == false)

        let copy = menu.addItem(withTitle: "Copy", action: #selector(contextCopy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = hasSelection
        copy.setAccessibilityIdentifier("surface.terminal.menu.copy")

        let copyAll = menu.addItem(withTitle: "Copy All", action: #selector(contextCopyAll(_:)), keyEquivalent: "")
        copyAll.target = self
        copyAll.setAccessibilityIdentifier("surface.terminal.menu.copyAll")

        let paste = menu.addItem(withTitle: "Paste", action: #selector(contextPaste(_:)), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = hasClipboardText
        paste.setAccessibilityIdentifier("surface.terminal.menu.paste")

        menu.addItem(.separator())

        let selectAll = menu.addItem(withTitle: "Select All", action: #selector(contextSelectAll(_:)), keyEquivalent: "")
        selectAll.target = self
        selectAll.setAccessibilityIdentifier("surface.terminal.menu.selectAll")

        let jumpToBottom = menu.addItem(withTitle: "Jump to Bottom", action: #selector(contextJumpToBottom(_:)), keyEquivalent: "")
        jumpToBottom.target = self
        jumpToBottom.setAccessibilityIdentifier("surface.terminal.menu.jumpToBottom")

        let clear = menu.addItem(withTitle: "Clear", action: #selector(contextClear(_:)), keyEquivalent: "")
        clear.target = self
        clear.setAccessibilityIdentifier("surface.terminal.menu.clear")

        return menu
    }

    @objc private func contextCopy(_ sender: Any?) {
        guard let surface = surfaceSlot.liveSurface() else { return }
        copySelection(from: surface)
    }

    @objc private func contextCopyAll(_ sender: Any?) {
        copyViewportText()
    }

    func copyViewportText() {
        if let text = readViewportText() {
            if !text.isEmpty { clipboardWriter(text) }
            return
        }
        // Parser still absorbing output: copy the fresh viewport once it drains.
        guard outputBytesOwned > 0 else { return }
        onOutputDrained(key: "copyAll") { [weak self] in self?.copyViewportText() }
    }

    @objc private func contextPaste(_ sender: Any?) {
        guard let surface = surfaceForInput() else { return }
        pasteText(to: surface)
    }

    @objc private func contextSelectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }

    @objc private func contextJumpToBottom(_ sender: Any?) {
        performBindingAction("scroll_to_bottom")
    }

    @objc private func contextClear(_ sender: Any?) {
        performBindingAction("clear_screen")
    }

    // MARK: - Scrollback position indicator

    /// Update the scrollback position indicator. Call whenever the scroll
    /// position changes (driven by the owning TerminalSurface).
    /// `offset` = lines scrolled above the bottom (0 = at bottom).
    /// `total`  = total scrollback line count available.
    func updateScrollbackPosition(offset: Int, total: Int) {
        let text = ScrollbackPositionLabel.label(offset: offset, total: total)
        let atBottom = offset <= 0
        if atBottom {
            scrollbackIndicator?.isHidden = true
            return
        }
        let label = scrollbackIndicator ?? makeScrollbackIndicator()
        scrollbackIndicator = label
        label.stringValue = text
        label.isHidden = false
        label.sizeToFit()
        repositionScrollbackIndicator()
    }

    private func makeScrollbackIndicator() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = DS.NS.textSecondary
        label.backgroundColor = DS.NS.surface.withAlphaComponent(0.85)
        label.drawsBackground = true
        label.isBordered = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("terminal.scrollback-indicator")
        label.setAccessibilityLabel(L("Scrollback position"))
        addSubview(label)
        return label
    }

    private func repositionScrollbackIndicator() {
        guard let label = scrollbackIndicator else { return }
        let size = label.fittingSize
        let margin: CGFloat = 8
        label.frame = NSRect(
            x: bounds.maxX - size.width - margin,
            y: margin,
            width: size.width + 8,
            height: size.height + 2
        )
    }

    private func performBindingAction(_ action: String) {
        guard let surface = surfaceForInput() else { return }
        action.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
        if isRenderable {
            // Async refresh only — never render on the main thread (see refreshAfterDrain).
            ghostty_surface_refresh(surface)
        }
    }

    // Cmd-+/Cmd--/Cmd-0 zoom: drive Ghostty's font-size action, then re-derive
    // and re-emit the grid size so the PTY winsize follows the new cell metrics
    // (UX-008). The delta is also persisted so the zoom survives restart.
    private func changeFontSize(_ action: String) {
        performBindingAction(action)
        updateGhosttySize(force: true)
        updateZoomDelta(for: action)
        showFontZoomHUD()
    }

    /// Update `zoomDelta` to reflect the zoom action and persist to the KV store.
    private func updateZoomDelta(for action: String) {
        if action.hasPrefix("increase_font_size:"),
           let n = Int(action.dropFirst("increase_font_size:".count)) {
            zoomDelta = FontZoomLevel.clamp(zoomDelta + n)
        } else if action.hasPrefix("decrease_font_size:"),
                  let n = Int(action.dropFirst("decrease_font_size:".count)) {
            zoomDelta = FontZoomLevel.clamp(zoomDelta - n)
        } else if action == "reset_font_size" {
            zoomDelta = 0
        }
        persistZoomDelta()
    }

    private func persistZoomDelta() {
        guard let store = fontZoomStore,
              let wsID = fontZoomWorkspaceID else { return }
        let key = "terminal.font_zoom.\(wsID)"
        try? store.set(key, FontZoomLevel.serialize(zoomDelta))
    }

    private func restoreZoomDelta() {
        guard let store = fontZoomStore,
              let wsID = fontZoomWorkspaceID else { return }
        let key = "terminal.font_zoom.\(wsID)"
        // `try? store.get(key)` produces `String??`; flatten with nil-coalescing.
        let rawOptional: String?? = try? store.get(key)
        guard let raw = rawOptional ?? nil,
              let stored = FontZoomLevel.deserialize(raw),
              stored != 0 else { return }
        zoomDelta = stored
        // Replay the stored delta as binding actions so Ghostty's internal
        // font-size state matches; do NOT call changeFontSize which would
        // re-persist and call updateGhosttySize prematurely (ensureSurface
        // already calls updateGhosttySize after this).
        let bindingAction: String
        if stored > 0 {
            bindingAction = "increase_font_size:\(stored)"
        } else {
            bindingAction = "decrease_font_size:\(-stored)"
        }
        performBindingAction(bindingAction)
    }

    // MARK: - Find in scrollback (Cmd+F)

    private func openFindBar() {
        let bar = findBar ?? makeFindBar()
        findBar = bar
        bar.isHidden = false
        if let field = findField {
            window?.makeFirstResponder(field)
        }
        recomputeFindMatches(forward: true, advance: false)
    }

    private func closeFindBar() {
        drainActions["find"] = nil
        findCountPlaceholder = nil
        findBar?.isHidden = true
        findMatchCount = 0
        findCurrentMatch = nil
        window?.makeFirstResponder(self)
    }

    private func makeFindBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = DS.NS.surface.cgColor
        bar.layer?.cornerRadius = 6
        bar.setAccessibilityIdentifier("terminal.find-bar")
        bar.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField()
        field.placeholderString = L("Find in terminal")
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.target = self
        field.action = #selector(findFieldChanged(_:))
        field.setAccessibilityIdentifier("terminal.find-field")
        field.setAccessibilityLabel(L("Find in terminal"))
        field.translatesAutoresizingMaskIntoConstraints = false
        findField = field

        let count = NSTextField(labelWithString: "")
        count.textColor = DS.NS.textSecondary
        count.font = NSFont.systemFont(ofSize: 11)
        count.setAccessibilityIdentifier("terminal.find-count")
        count.translatesAutoresizingMaskIntoConstraints = false
        findCountLabel = count

        let prev = makeFindButton("chevron.up", help: L("Previous match"),
                                  axID: "terminal.find-prev", action: #selector(findPrev(_:)))
        let next = makeFindButton("chevron.down", help: L("Next match"),
                                  axID: "terminal.find-next", action: #selector(findNext(_:)))
        let close = makeFindButton("xmark", help: L("Close find"),
                                   axID: "terminal.find-close", action: #selector(findClose(_:)))

        let stack = NSStackView(views: [field, count, prev, next, close])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            field.widthAnchor.constraint(equalToConstant: 180)
        ])
        return bar
    }

    private func makeFindButton(_ glyph: String, help: String, axID: String, action: Selector) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.bezelStyle = .inline
        b.image = NSImage(systemSymbolName: glyph, accessibilityDescription: help)
        b.contentTintColor = DS.NS.textSecondary
        b.imageScaling = .scaleProportionallyDown
        b.toolTip = help
        b.target = self
        b.action = action
        b.setAccessibilityIdentifier(axID)
        b.setAccessibilityLabel(help)
        return b
    }

    @objc private func findFieldChanged(_ sender: Any?) {
        recomputeFindMatches(forward: true, advance: false)
    }

    @objc private func findNext(_ sender: Any?) {
        recomputeFindMatches(forward: true, advance: true)
    }

    @objc private func findPrev(_ sender: Any?) {
        recomputeFindMatches(forward: false, advance: true)
    }

    @objc private func findClose(_ sender: Any?) {
        closeFindBar()
    }

    /// Recompute matches for the current query against the live scrollback
    /// snapshot, optionally advancing the navigation cursor, and refresh the
    /// count label. No visible terminal highlight/scroll is possible because
    /// GhosttyKit exposes no selection-set/scroll-to API to embedders.
    private func recomputeFindMatches(forward: Bool, advance: Bool) {
        let query = findField?.stringValue ?? ""
        guard let snapshot = readScrollbackText() else {
            // No snapshot is not "no match": wait for the parser to drain, then search.
            let waitingForParser = outputBytesOwned > 0 || surfaceSlot.isClosingWithDeferredFree
            findCountPlaceholder = waitingForParser ? "…" : "—"
            updateFindCountLabel()
            if waitingForParser {
                onOutputDrained(key: "find") { [weak self] in
                    self?.recomputeFindMatches(forward: forward, advance: advance)
                }
            }
            return
        }
        findCountPlaceholder = nil
        let ranges = TerminalScrollbackSearch.matchRanges(in: snapshot, query: query)
        findMatchCount = ranges.count
        if findMatchCount == 0 {
            findCurrentMatch = nil
        } else if advance {
            findCurrentMatch = TerminalScrollbackSearch.nextIndex(
                current: findCurrentMatch, count: findMatchCount, forward: forward, wrap: true)
        } else if findCurrentMatch == nil || (findCurrentMatch ?? 0) >= findMatchCount {
            findCurrentMatch = 0
        }
        updateFindCountLabel()
    }

    private func updateFindCountLabel() {
        guard let label = findCountLabel else { return }
        if (findField?.stringValue ?? "").isEmpty {
            label.stringValue = ""
        } else if let findCountPlaceholder {
            label.stringValue = findCountPlaceholder
        } else if findMatchCount == 0 {
            label.stringValue = "0/0"
        } else {
            label.stringValue = "\((findCurrentMatch ?? 0) + 1)/\(findMatchCount)"
        }
    }

    // MARK: - Font zoom HUD

    /// Show a brief bottom-left overlay indicating the current zoom level, then
    /// auto-hide it after a short delay. "Base" means delta == 0 (no zoom).
    private func showFontZoomHUD() {
        let text = Self.fontZoomHUDText(for: zoomDelta)
        let label = fontZoomHUD ?? makeFontZoomHUD()
        fontZoomHUD = label
        label.stringValue = text
        label.isHidden = false
        label.sizeToFit()
        repositionFontZoomHUD()
        fontZoomHUDGeneration &+= 1
        let gen = fontZoomHUDGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.fontZoomHUDGeneration == gen else { return }
            self.fontZoomHUD?.isHidden = true
        }
    }

    /// Human-readable HUD text for a zoom delta. Pure, nonisolated for tests.
    nonisolated static func fontZoomHUDText(for delta: Int) -> String {
        if delta == 0 { return "Font: Base" }
        return delta > 0 ? "Font: +\(delta)pt" : "Font: \(delta)pt"
    }

    private func makeFontZoomHUD() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = DS.NS.textSecondary
        label.backgroundColor = DS.NS.surface.withAlphaComponent(0.85)
        label.drawsBackground = true
        label.isBordered = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("terminal.font-zoom-hud")
        label.setAccessibilityLabel(L("Font zoom level"))
        addSubview(label)
        return label
    }

    private func repositionFontZoomHUD() {
        guard let label = fontZoomHUD else { return }
        let size = label.fittingSize
        let margin: CGFloat = 8
        label.frame = NSRect(
            x: margin,
            y: margin,
            width: size.width + 8,
            height: size.height + 2
        )
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click pastes the current terminal selection (X11/iTerm style)
        // when the program isn't reporting mouse events; otherwise forward the
        // middle button to the program (UX-012).
        if event.buttonNumber == 2, !isMouseCaptured,
           let surface = surfaceForInput(), ghostty_surface_has_selection(surface) {
            window?.makeFirstResponder(self)
            pasteSelection(from: surface)
            return
        }
        super.otherMouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surfaceForInput() else { return }
        // Re-derive a stale render gate (audit #1) before the refresh below —
        // otherwise a latched-off occlusion makes ghostty_surface_refresh a no-op and
        // the viewport never moves (scroll looks dead). Like keyDown, this re-checks
        // the same gate, so the key override still needs the active Space (S-F2).
        // (Display-link reassert for #2 stays on the focus/refresh paths — not this
        // high-frequency momentum path.)
        syncOcclusion()
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
            mods |= 0b0000_0001
        }
        mods |= mouseMomentum(from: event) << 1
        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(mods))
        // Async refresh only — never render on the main thread (see refreshAfterDrain).
        ghostty_surface_refresh(surface)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = Self.canAcceptDrag(from: sender.draggingPasteboard)
        setDropHighlight(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.canAcceptDrag(from: sender.draggingPasteboard) ? .copy : []
    }

    /// Returns `true` when `pasteboard` carries either a file-URL drop or a
    /// plain-text string that the terminal can accept. Pure helper so the drag
    /// acceptance predicate is not duplicated across `draggingEntered` and
    /// `draggingUpdated`.
    nonisolated static func canAcceptDrag(from pasteboard: NSPasteboard) -> Bool {
        if DroppedFilePaths.canReadFileDrop(from: pasteboard) { return true }
        return pasteboard.availableType(from: [.string]) != nil
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)

        // File-URL drop: convert to shell-escaped paths and send immediately
        // (same as before; file drops have always been accepted without guard).
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        if !paths.isEmpty {
            guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return false }
            writeInputData(data)
            return true
        }

        // Plain-text drop: resolve the string from the pasteboard and apply the
        // same PasteGuard semantics used for keyboard paste (Cmd+V) so a
        // multi-line or control-character string dragged from another app does
        // not silently execute shell commands.
        switch TerminalDragPayload.plainTextDropDecision(
            from: sender.draggingPasteboard,
            confirmationAvailable: onPlainTextDragNeedsConfirm != nil
        ) {
        case .send(let safe):
            guard let data = safe.data(using: .utf8) else { return false }
            writeInputData(data)
        case .confirm(let text):
            onPlainTextDragNeedsConfirm?(text)
        case .reject:
            return false
        }
        return true
    }

    // Visual drop target: a highlighted border while a file drag is over the
    // terminal so users can tell the path will be pasted on release (UX-010).
    private func setDropHighlight(_ active: Bool) {
        if active {
            let layer = dropHighlightLayer ?? makeDropHighlightLayer()
            dropHighlightLayer = layer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = bounds
            self.layer?.addSublayer(layer)
            CATransaction.commit()
        } else {
            dropHighlightLayer?.removeFromSuperlayer()
        }
    }

    private func makeDropHighlightLayer() -> CALayer {
        let layer = CALayer()
        layer.borderWidth = 2
        layer.borderColor = NSColor.controlAccentColor.cgColor
        layer.cornerRadius = 2
        layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        return layer
    }

    private func surfaceForInput() -> ghostty_surface_t? {
        ensureSurface()
        return surfaceSlot.liveSurface()
    }

    /// Feed UTF-8 bytes to Ghostty without an intermediate `[UInt8]` copy.
    ///
    /// WHY: large pastes (logs, JSON dumps) used to allocate `Array(text.utf8)`
    /// on the main thread just to get a contiguous pointer. `withUTF8` provides
    /// a contiguous buffer for the duration of the closure; Ghostty copies the
    /// bytes before returning. Length is the true UTF-8 byte count (not strlen),
    /// so embedded NULs are preserved (same contract as the prior Array path).
    nonisolated static func withUTF8Bytes(
        _ text: String,
        _ body: (UnsafePointer<CChar>, Int) -> Void
    ) {
        guard !text.isEmpty else { return }
        var copy = text
        copy.withUTF8 { buffer in
            guard !buffer.isEmpty, let base = buffer.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { ptr in
                body(ptr, buffer.count)
            }
        }
    }

    /// Paste / multi-byte clipboard path. Ghostty may apply bracketed paste.
    private func sendText(_ text: String, to surface: ghostty_surface_t) {
        Self.withUTF8Bytes(text) { ptr, count in
            ghostty_surface_text(surface, ptr, UInt(count))
        }
    }

    /// Committed typed text from IME / dead-key composition (not paste).
    /// Uses the embedder typed-input entry so shells and TUIs treat it as
    /// keystrokes rather than a paste payload.
    private func sendTypedInput(_ text: String, to surface: ghostty_surface_t) {
        Self.withUTF8Bytes(text) { ptr, count in
            ghostty_surface_text_input(surface, ptr, UInt(count))
        }
    }

    private func pasteText(to surface: ghostty_surface_t) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        switch PasteGuard.classify(text) {
        case .safe:
            sendText(text, to: surface)
        case .needsConfirm:
            if let confirm = onPasteNeedsConfirm {
                confirm(text)
            } else {
                // No confirmation handler wired (e.g. unit tests / preview): send
                // directly as a safe fall-through, matching TerminalTextView behaviour.
                sendText(text, to: surface)
            }
        }
    }

    private func pasteSelection(from surface: ghostty_surface_t) {
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let raw = text.text, text.text_len > 0 else { return }
        let value = String(decoding: Data(bytes: raw, count: Int(text.text_len)), as: UTF8.self)
        guard !value.isEmpty else { return }
        sendText(value, to: surface)
    }

    private func copySelection(from surface: ghostty_surface_t) {
        guard ghostty_surface_has_selection(surface) else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let raw = text.text, text.text_len > 0 else { return }
        let data = Data(bytes: raw, count: Int(text.text_len))
        guard let value = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func ghosttyKeyEvent(for event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = mods(from: event.modifierFlags)
        key.consumed_mods = consumedMods(from: event.modifierFlags)
        key.unshifted_codepoint = unshiftedCodepoint(from: event)
        key.composing = false
        return key
    }

    private func textForEvent(_ event: NSEvent) -> String? {
        GhosttyTerminalKeyInput.text(for: event)
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        GhosttyTerminalKeyInput.unshiftedCodepoint(from: event)
    }

    private func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func consumedMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface = surfaceForInput() else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods(from: event.modifierFlags))
    }

    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface = surfaceForInput() else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods(from: event.modifierFlags))
        _ = ghostty_surface_mouse_button(surface, state, button, mods(from: event.modifierFlags))
    }

    private func mouseMomentum(from event: NSEvent) -> Int32 {
        switch event.momentumPhase {
        case .began:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}

// IME / dead-key / CJK composition. Without NSTextInputClient conformance,
// interpretKeyEvents (called from keyDown) cannot drive marked-text composition,
// so multi-stage input (Pinyin, Kana, dead keys) was broken. The cmux GhosttyKit
// fork exposes ghostty_surface_preedit so the engine can render the in-progress
// composition; committed text flows through the existing typed-text path.
extension GhosttyTerminalView: NSTextInputClient {
    nonisolated static func plainString(from any: Any) -> String? {
        if let s = any as? String { return s }
        if let a = any as? NSAttributedString { return a.string }
        return nil
    }

    /// Pure NSTextInputClient preedit transitions, extracted so the IME / dead-key
    /// composition contract is unit-testable without a live Ghostty surface.
    /// `.setMarked` shows the in-progress composition; `.insert` and `.unmark` BOTH
    /// clear it. The `.insert` clear is the dead-key fix: committing a character
    /// (e.g. ~ then a -> a, ' then e -> e) must drop the in-progress preedit before
    /// the character is sent, never leave the dead key rendered.
    enum IMEPreeditInput { case setMarked(Any), insert, unmark }
    nonisolated static func nextPreedit(for input: IMEPreeditInput) -> String {
        switch input {
        case .setMarked(let s): return plainString(from: s) ?? ""
        case .insert, .unmark: return ""
        }
    }

    nonisolated static func markedRange(forPreedit text: String) -> NSRange {
        text.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (text as NSString).length)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        setPreedit(Self.nextPreedit(for: .insert))
        guard let text = Self.plainString(from: string), !text.isEmpty,
              let surface = surfaceForInput() else { return }
        // IME / dead-key commit path only (keyDown printables use surface_key).
        // Must not use ghostty_surface_text — that is the paste path and breaks
        // interactive TUI prompts (Grok Space, shell autosuggest, etc.).
        sendTypedInput(text, to: surface)
    }

    /// AppKit also invokes the single-argument responder-chain form.
    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Silence beeps for unused text-system selectors from interpretKeyEvents.
    override func doCommand(by selector: Selector) {}

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        setPreedit(Self.nextPreedit(for: .setMarked(string)))
    }

    func unmarkText() {
        setPreedit(Self.nextPreedit(for: .unmark))
    }

    /// Push the marked (composing) text to Ghostty so it renders the preedit
    /// overlay. Empty string clears it. Keeps `markedText` in sync for AppKit.
    private func setPreedit(_ text: String) {
        markedText = text
        guard let surface = surfaceForInput() else { return }
        if text.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
            return
        }
        Self.withUTF8Bytes(text) { ptr, count in
            ghostty_surface_preedit(surface, ptr, UInt(count))
        }
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange { Self.markedRange(forPreedit: markedText) }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Anchor the IME candidate window to the view; ghostty does not expose a
        // per-glyph caret rect to embedders, so use the view rect in screen space.
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}
