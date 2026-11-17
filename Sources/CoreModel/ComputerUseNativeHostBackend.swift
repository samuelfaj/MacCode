import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ScreenCaptureKit

/// Exact host identity. A PID without a window ID is deliberately not enough
/// for a mutating operation: one process can own several independent windows.
enum NativeWindowRestoreSequence {
    static func run(
        wasMinimized: Bool,
        unminimize: () -> Bool,
        focusExactWindow: () -> Bool,
        activateApp: () -> Bool,
        rollbackMinimized: () -> Void
    ) -> Bool {
        if wasMinimized && !unminimize() { return false }
        guard focusExactWindow() else {
            if wasMinimized { rollbackMinimized() }
            return false
        }
        guard activateApp() else {
            if wasMinimized { rollbackMinimized() }
            return false
        }
        return true
    }
}

enum NativeSemanticTargetSearch {
    static func uniqueMatch<Node>(
        root: Node,
        role: String,
        label: String,
        attributesOf: (Node) -> (role: String?, title: String?, description: String?)?,
        childrenOf: (Node) -> [Node]?
    ) -> Node? {
        var matches: [Node] = []
        var complete = true
        func visit(_ node: Node, depth: Int) {
            guard complete else { return }
            guard depth < 32, let attributes = attributesOf(node) else {
                complete = false
                return
            }
            if attributes.role == role && (attributes.title == label || attributes.description == label) {
                matches.append(node)
                if matches.count > 1 { complete = false; return }
            }
            guard let children = childrenOf(node) else {
                complete = false
                return
            }
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return complete && matches.count == 1 ? matches[0] : nil
    }
}

/// Decides when the UI has stopped reacting to a mutation. Notification source
/// and clock are injected so the timing logic is testable without AX.
public enum NativeSettle {
    public static let firstNotificationWindow: TimeInterval = 0.6
    public static let quietWindow: TimeInterval = 0.15
    public static let maximumDuration: TimeInterval = 2.0

    public struct Result: Sendable, Equatable {
        public let settled: Bool
        public let elapsedMilliseconds: Int
        /// Whether the app reported any change after the action; nil when nothing was listening.
        public let reacted: Bool?

        public init(settled: Bool, elapsedMilliseconds: Int, reacted: Bool? = nil) {
            self.settled = settled
            self.elapsedMilliseconds = elapsedMilliseconds
            self.reacted = reacted
        }

        func combined(with other: Result) -> Result {
            Result(
                settled: settled && other.settled,
                elapsedMilliseconds: elapsedMilliseconds + other.elapsedMilliseconds,
                reacted: reacted == nil && other.reacted == nil ? nil : (reacted ?? false) || (other.reacted ?? false)
            )
        }

        /// An accepted action is not a delivered one, so say when a change was seen. Silence is
        /// not evidence of the opposite: a page with its accessibility tree off changes without
        /// telling anyone, and calling that a no-op would invite repeating a toggle.
        public var effect: String { reacted == true ? "ui_changed" : "unverified" }
    }

    /// `waitForNotification(timeout)` blocks up to `timeout` seconds and returns
    /// true when a notification arrived. No reaction within the first window
    /// counts as settled; only hitting the cap while still busy is unsettled.
    public static func wait(
        now: () -> TimeInterval,
        waitForNotification: (TimeInterval) -> Bool
    ) -> Result {
        let start = now()
        var sawNotification = false
        while true {
            let elapsed = now() - start
            if elapsed >= maximumDuration {
                return Result(settled: false, elapsedMilliseconds: milliseconds(elapsed), reacted: sawNotification)
            }
            let window = sawNotification ? quietWindow : firstNotificationWindow
            let timeout = min(window, maximumDuration - elapsed)
            if waitForNotification(timeout) {
                sawNotification = true
                continue
            }
            let total = now() - start
            return Result(settled: timeout >= window, elapsedMilliseconds: milliseconds(total), reacted: sawNotification)
        }
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        Int((max(0, interval) * 1000).rounded())
    }
}

/// Registered before the mutation so no notification is missed; `wait` is
/// called after the action and `cancel` is always safe to call.
public struct NativeSettleWatcher: @unchecked Sendable {
    public var wait: @Sendable () -> NativeSettle.Result
    public var cancel: @Sendable () -> Void

    public init(
        wait: @escaping @Sendable () -> NativeSettle.Result,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.wait = wait
        self.cancel = cancel
    }

    public static let immediate = NativeSettleWatcher(
        wait: { NativeSettle.Result(settled: true, elapsedMilliseconds: 0) }
    )
}

/// `ax_<n>` ids from get_ui_tree: depth-first index under the same node and
/// depth limits as the serializer. Only valid with that observation's token.
enum NativeElementID {
    static let maximumNodes = 1_000
    static let maximumDepth = 32

    static func index(_ id: String) -> Int? {
        guard id.hasPrefix("ax_") else { return nil }
        let digits = id.dropFirst(3)
        guard !digits.isEmpty, digits.count <= 3,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits == "0" || !digits.hasPrefix("0"),
              let value = Int(digits), value < maximumNodes else { return nil }
        return value
    }
}

enum NativeElementSelector: Equatable {
    case roleLabel(role: String, label: String)
    case id(String)

    /// Exactly one of `element_id` or `role`+`label`.
    static func parse(_ arguments: [String: Any]) -> (selector: NativeElementSelector?, error: String?) {
        if let rawID = arguments["element_id"] {
            guard arguments["role"] == nil, arguments["label"] == nil else {
                return (nil, "provide either element_id or role+label, not both")
            }
            guard let id = rawID as? String, NativeElementID.index(id) != nil else {
                return (nil, "element_id is out of range or malformed; use an ax_<n> id from get_ui_tree")
            }
            return (.id(id), nil)
        }
        let role = arguments["role"] as? String ?? ""
        let label = arguments["label"] as? String ?? ""
        guard !role.isEmpty, !label.isEmpty else {
            return (nil, "provide either element_id or role and label")
        }
        return (.roleLabel(role: role, label: label), nil)
    }
}

public enum ComputerUseNativeSetValueResult: Sendable, Equatable {
    case applied
    case failed(String)
}

public enum ComputerUseNativeMenuShortcutResult: Sendable, Equatable {
    case applied
    case noMenuItem
    case ambiguous
    case failed
    case refused(String)
}

/// Refuses a menu item whose title names a risk category the caller did not allow.
enum NativeRiskGuard {
    static func refusal(title: String?, allowed: Set<RiskCategory>?) -> String? {
        guard let allowed, let title else { return nil }
        let missing = RiskCategory.categories(title).subtracting(allowed)
        guard !missing.isEmpty else { return nil }
        return "risky menu item '\(title)' requires allowed_risks \(missing.map(\.rawValue).sorted().joined(separator: ", "))"
    }

    /// Presses the single titled pop-up item unless its title is risky; the menu is cancelled otherwise.
    static func selectPopUpItem<Node>(
        items: [Node], title: String, titleOf: (Node) -> String?, allowed: Set<RiskCategory>?,
        press: (Node) -> Bool, cancel: () -> Void
    ) -> ComputerUseNativeSetValueResult {
        let matches = items.filter { titleOf($0) == title }
        guard matches.count == 1 else {
            cancel()
            return .failed(matches.isEmpty ? "no pop-up item titled \(title)" : "more than one pop-up item titled \(title)")
        }
        if let refusal = refusal(title: title, allowed: allowed) {
            cancel()
            return .failed(refusal)
        }
        guard press(matches[0]) else {
            cancel()
            return .failed("could not press the pop-up item")
        }
        return .applied
    }

    /// Presses the single menu-shortcut match unless its title is risky.
    static func pressShortcutMatch<Node>(
        matches: [Node], titleOf: (Node) -> String?, allowed: Set<RiskCategory>?, press: (Node) -> Bool
    ) -> ComputerUseNativeMenuShortcutResult {
        guard matches.count == 1 else { return matches.isEmpty ? .noMenuItem : .ambiguous }
        if let refusal = refusal(title: titleOf(matches[0]), allowed: allowed) { return .refused(refusal) }
        return press(matches[0]) ? .applied : .failed
    }
}

/// "MOD+S" style chord: MOD=Cmd, CTRL, ALT, SHIFT plus one key character.
public struct ComputerUseNativeMenuChord: Sendable, Equatable {
    public let key: String
    public let command: Bool
    public let control: Bool
    public let option: Bool
    public let shift: Bool

    /// AXMenuItemCmdModifiers bitmask: shift=1, option=2, control=4, no-command=8.
    public var axModifiers: Int {
        (shift ? 1 : 0) | (option ? 2 : 0) | (control ? 4 : 0) | (command ? 0 : 8)
    }

    public var isSelectAll: Bool {
        key == "A" && command && !control && !option && !shift
    }

    public static func parse(_ value: Any?) -> ComputerUseNativeMenuChord? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        let key: String
        let modifierNames: [Substring]
        if text.hasSuffix("++") {
            key = "+"
            modifierNames = text.dropLast(2).split(separator: "+", omittingEmptySubsequences: false)
        } else {
            let parts = text.split(separator: "+", omittingEmptySubsequences: false)
            guard parts.count >= 2, let last = parts.last else { return nil }
            key = String(last)
            modifierNames = Array(parts.dropLast())
        }
        guard key.unicodeScalars.count == 1,
              let scalar = key.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains(scalar),
              !modifierNames.isEmpty else { return nil }
        var command = false, control = false, option = false, shift = false
        for name in modifierNames {
            switch name.uppercased() {
            case "MOD", "CMD", "COMMAND":
                guard !command else { return nil }
                command = true
            case "CTRL", "CONTROL":
                guard !control else { return nil }
                control = true
            case "ALT", "OPTION":
                guard !option else { return nil }
                option = true
            case "SHIFT":
                guard !shift else { return nil }
                shift = true
            default:
                return nil
            }
        }
        return ComputerUseNativeMenuChord(
            key: key.uppercased(), command: command, control: control, option: option, shift: shift
        )
    }
}

enum NativeMenuShortcutSearch {
    static let maximumNodes = 4_000

    /// Up to two enabled menu items carrying the chord; two means ambiguous.
    static func enabledMatches<Node>(
        root: Node,
        chord: ComputerUseNativeMenuChord,
        attributesOf: (Node) -> (role: String?, enabled: Bool, cmdChar: String?, cmdModifiers: Int?)?,
        childrenOf: (Node) -> [Node]?
    ) -> [Node] {
        var matches: [Node] = []
        var visited = 0
        func visit(_ node: Node, depth: Int) {
            guard matches.count < 2, depth < 10, visited < maximumNodes,
                  let attributes = attributesOf(node) else { return }
            visited += 1
            guard attributes.enabled else { return }
            if attributes.role == "AXMenuItem",
               let cmdChar = attributes.cmdChar,
               cmdChar.uppercased() == chord.key,
               (attributes.cmdModifiers ?? 0) == chord.axModifiers {
                matches.append(node)
                return
            }
            for child in childrenOf(node) ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return matches
    }
}

public enum ComputerUseNativeClickResult: Sendable {
    case applied
    case noAXTarget
    case failed
}

public struct ComputerUseNativeHostTarget: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let windowID: UInt32

    public init(pid: Int32, windowID: UInt32) {
        self.pid = pid
        self.windowID = windowID
    }
}

public typealias ComputerUseHostTarget = ComputerUseNativeHostTarget

public struct ComputerUseNativeWindow: Sendable, Equatable {
    public let target: ComputerUseNativeHostTarget
    public let title: String
    public let bundleIdentifier: String?
    public let isOnScreen: Bool
    public let isMinimized: Bool
    public let bounds: CGRect

    public init(
        target: ComputerUseNativeHostTarget,
        title: String = "",
        bundleIdentifier: String? = nil,
        isOnScreen: Bool = true,
        isMinimized: Bool = false,
        bounds: CGRect = .zero
    ) {
        self.target = target
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.bounds = bounds
    }
}

public struct ComputerUseNativeCapture: Sendable, Equatable {
    public let data: String
    public let mimeType: String
    /// Full-frame pixel size before any zoom crop. Set when the capture
    /// source retained a live `CGImage` so zoom can skip a second PNG inflate.
    public let sourcePixelSize: [Int]?
    /// Size of the encoded image when it was scaled down from the frame.
    public let outputPixelSize: [Int]?

    public init(data: String, mimeType: String, sourcePixelSize: [Int]? = nil, outputPixelSize: [Int]? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.sourcePixelSize = sourcePixelSize
        self.outputPixelSize = outputPixelSize
    }
}

public enum ComputerUseNativeCaptureResult: Sendable, Equatable {
    case success(ComputerUseNativeCapture)
    case quartzFallback(ComputerUseNativeCapture)
    case unavailable(String)
}

public enum ComputerUseNativeUserActivity: String, Sendable, Equatable {
    case none
    case human
    case synthetic
}

public struct ComputerUseNativeActivityEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case keyboard
        case mouse
    }

    public let kind: Kind
    public let pid: Int32
    public let windowID: UInt32?
    public let timestampNanoseconds: UInt64
    public let isSynthetic: Bool

    public init(
        kind: Kind,
        pid: Int32,
        windowID: UInt32? = nil,
        timestampNanoseconds: UInt64,
        isSynthetic: Bool = false
    ) {
        self.kind = kind
        self.pid = pid
        self.windowID = windowID
        self.timestampNanoseconds = timestampNanoseconds
        self.isSynthetic = isSynthetic
    }
}

/// Target-scoped physical activity. Keyboard events belong to the frontmost
/// PID; mouse events belong to the exact window under the pointer. Events
/// tagged by RemoteCode's synthetic input path are intentionally ignored.
public final class ComputerUseNativeActivityMonitor: @unchecked Sendable {
    public static let quietWindowNanoseconds: UInt64 = 2_000_000_000
    public static let syntheticEventUserData: Int64 = 0x5243_4355
    static let maximumTrackedActivityEntries = 512

    private let lock = NSLock()
    private let quietWindowNanoseconds: UInt64
    private let now: @Sendable () -> UInt64
    private var keyboardActivity: [Int32: UInt64] = [:]
    private var mouseActivity: [ComputerUseNativeHostTarget: UInt64] = [:]
    private var activityOverflowedUntil: UInt64?
    private var lastPrunedAt: UInt64?

    public init(
        quietWindowNanoseconds: UInt64 = ComputerUseNativeActivityMonitor.quietWindowNanoseconds,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.quietWindowNanoseconds = quietWindowNanoseconds
        self.now = now
    }

    public func record(_ event: ComputerUseNativeActivityEvent) {
        guard !event.isSynthetic else { return }
        lock.lock()
        defer { lock.unlock() }
        pruneExpired(at: event.timestampNanoseconds)
        if let activityOverflowedUntil,
           event.timestampNanoseconds <= activityOverflowedUntil {
            return
        }
        switch event.kind {
        case .keyboard:
            keyboardActivity[event.pid] = event.timestampNanoseconds
        case .mouse:
            guard let windowID = event.windowID else { return }
            mouseActivity[.init(pid: event.pid, windowID: windowID)] = event.timestampNanoseconds
        }
        guard keyboardActivity.count + mouseActivity.count > Self.maximumTrackedActivityEntries else {
            return
        }
        keyboardActivity.removeAll()
        mouseActivity.removeAll()
        let (quietEnd, overflow) = event.timestampNanoseconds.addingReportingOverflow(quietWindowNanoseconds)
        activityOverflowedUntil = overflow ? UInt64.max : quietEnd
    }

    public func activity(for target: ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity {
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        pruneExpired(at: current)
        if let activityOverflowedUntil,
           current <= activityOverflowedUntil {
            // We cannot retain every recent target without making this map an
            // unbounded memory sink. Unknown activity is conservative here:
            // mutation callers fail closed while the quiet window drains.
            return .human
        }
        if let timestamp = keyboardActivity[target.pid], isRecent(timestamp, at: current) {
            return .human
        }
        if let timestamp = mouseActivity[target], isRecent(timestamp, at: current) {
            return .human
        }
        return .none
    }

    public func reset() {
        lock.lock()
        keyboardActivity.removeAll()
        mouseActivity.removeAll()
        activityOverflowedUntil = nil
        lastPrunedAt = nil
        lock.unlock()
    }

    private func pruneExpired(at current: UInt64) {
        if let lastPrunedAt,
           current >= lastPrunedAt,
           current - lastPrunedAt < quietWindowNanoseconds {
            return
        }
        keyboardActivity = keyboardActivity.filter { isRecent($0.value, at: current) }
        mouseActivity = mouseActivity.filter { isRecent($0.value, at: current) }
        self.lastPrunedAt = current
        if let activityOverflowedUntil,
           current > activityOverflowedUntil {
            self.activityOverflowedUntil = nil
        }
    }

    private func isRecent(_ timestamp: UInt64, at current: UInt64) -> Bool {
        current >= timestamp && current - timestamp <= quietWindowNanoseconds
    }
}

public struct ComputerUseNativeHostObservation: Sendable, Equatable {
    public let target: ComputerUseNativeHostTarget
    public let stateToken: String
    public let captureMode: String
    public let capabilities: [String]
    public let userActivity: ComputerUseNativeUserActivity
    public let accessibilityPermission: Bool
    public let screenCapturePermission: Bool
    public let isMinimized: Bool
    public let isOnScreen: Bool

    public init(
        target: ComputerUseNativeHostTarget,
        stateToken: String,
        captureMode: String,
        capabilities: [String],
        userActivity: ComputerUseNativeUserActivity,
        accessibilityPermission: Bool,
        screenCapturePermission: Bool,
        isMinimized: Bool,
        isOnScreen: Bool
    ) {
        self.target = target
        self.stateToken = stateToken
        self.captureMode = captureMode
        self.capabilities = capabilities
        self.userActivity = userActivity
        self.accessibilityPermission = accessibilityPermission
        self.screenCapturePermission = screenCapturePermission
        self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen
    }
}

/// Native host implementation for the RemoteCode-owned computer-use MCP.
///
/// The hooks are intentionally small: production uses AppKit, Quartz,
/// Accessibility, and ScreenCaptureKit-adjacent permission checks, while unit
/// tests can prove every fail-closed branch without posting an input event.
public final class ComputerUseNativeHostBackend: ComputerUseToolBackend, @unchecked Sendable {
    public struct Hooks: @unchecked Sendable {
        public var listWindows: @Sendable (String?) -> [ComputerUseNativeWindow]
        public var userActivity: @Sendable (ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity
        public var activityMonitorAvailable: @Sendable () -> Bool
        public var accessibilityPermission: @Sendable () -> Bool
        public var axTargetAvailable: @Sendable (ComputerUseNativeHostTarget) -> Bool
        public var screenCapturePermission: @Sendable () -> Bool
        public var capture: @Sendable (ComputerUseNativeHostTarget) async -> ComputerUseNativeCaptureResult
        public var uiTree: @Sendable (ComputerUseNativeHostTarget) -> String?
        public var semanticAction: @Sendable (ComputerUseNativeHostTarget, String, String) -> Bool
        public var leftClick: @Sendable (ComputerUseNativeHostTarget, [Double]) -> ComputerUseNativeClickResult
        public var focusedTarget: @Sendable (ComputerUseNativeHostTarget) -> Bool
        public var typeText: @Sendable (ComputerUseNativeHostTarget, String) -> Bool
        public var pixelAction: @Sendable (ComputerUseNativeHostTarget, String, [Double]) -> Bool
        public var activate: @Sendable (ComputerUseNativeHostTarget) -> Bool
        /// Executable of the app that launched this MCP (TCC attributes Screen
        /// Recording / Accessibility to that responsible app, not to this helper).
        public var hostLauncherPath: @Sendable () -> String? = {
            NativePlatform.hostLauncherExecutablePath()
        }
        /// Unique role+label element set to `value` through AX; no focus change.
        public var setValue: @Sendable (ComputerUseNativeHostTarget, String, String, String, Set<RiskCategory>?) -> ComputerUseNativeSetValueResult = {
            NativePlatform.setValue(target: $0, role: $1, label: $2, value: $3, allowedRisks: $4)
        }
        /// AXPress on the enabled menu item carrying the chord; no activation.
        public var menuShortcut: @Sendable (ComputerUseNativeHostTarget, ComputerUseNativeMenuChord, Set<RiskCategory>?) -> ComputerUseNativeMenuShortcutResult = {
            NativePlatform.menuShortcut(target: $0, chord: $1, allowedRisks: $2)
        }
        /// AXConfirm on a unique role+label element.
        public var semanticConfirm: @Sendable (ComputerUseNativeHostTarget, String, String) -> Bool = {
            NativePlatform.semanticConfirm(target: $0, role: $1, label: $2)
        }
        /// True when the app's AX-focused element is the unique role+label element.
        public var isFocusedElement: @Sendable (ComputerUseNativeHostTarget, String, String) -> Bool = {
            NativePlatform.isFocusedElement(target: $0, role: $1, label: $2)
        }
        /// Registered before a mutation; waits for the UI to settle afterwards.
        public var settleWatcher: @Sendable (ComputerUseNativeHostTarget) -> NativeSettleWatcher = {
            NativePlatform.settleWatcher(target: $0)
        }
        /// The app in front, and a request to put one back there (see `returnFocus`).
        public var frontmostPID: @Sendable () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        public var activateApp: @Sendable (Int32) -> Bool = { NSRunningApplication(processIdentifier: $0)?.activate(options: []) ?? false }
        /// Long-edge limit for a window screenshot when the call does not give one.
        public var maxImageDimension: @Sendable () -> Int = { DesktopToolsBackend.windowImageDimension() }
        /// Same as the role+label hooks, addressed by a get_ui_tree `ax_<n>` id.
        public var semanticActionByID: @Sendable (ComputerUseNativeHostTarget, String) -> Bool = {
            NativePlatform.semanticAction(target: $0, elementID: $1)
        }
        public var setValueByID: @Sendable (ComputerUseNativeHostTarget, String, String, Set<RiskCategory>?) -> ComputerUseNativeSetValueResult = {
            NativePlatform.setValue(target: $0, elementID: $1, value: $2, allowedRisks: $3)
        }
        public var semanticConfirmByID: @Sendable (ComputerUseNativeHostTarget, String) -> Bool = {
            NativePlatform.semanticConfirm(target: $0, elementID: $1)
        }
        public var isFocusedElementByID: @Sendable (ComputerUseNativeHostTarget, String) -> Bool = {
            NativePlatform.isFocusedElement(target: $0, elementID: $1)
        }
        /// Text recognition on a captured window image; evidence only.
        public var recognizeText: @Sendable (CGImage) async throws -> [OCRElement] = {
            try await OCRPerception.recognize($0)
        }

        public init(
            listWindows: @escaping @Sendable (String?) -> [ComputerUseNativeWindow] = {
                NativePlatform.listWindows(bundleID: $0)
            },
            userActivity: @escaping @Sendable (ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity = {
                NativePlatform.userActivity(target: $0)
            },
            activityMonitorAvailable: @escaping @Sendable () -> Bool = {
                NativePlatform.activityMonitoringAvailable()
            },
            accessibilityPermission: @escaping @Sendable () -> Bool = {
                NativePlatform.accessibilityPermission()
            },
            axTargetAvailable: @escaping @Sendable (ComputerUseNativeHostTarget) -> Bool = {
                NativePlatform.axTargetAvailable(target: $0)
            },
            screenCapturePermission: @escaping @Sendable () -> Bool = {
                NativePlatform.screenCapturePermission()
            },
            capture: @escaping @Sendable (ComputerUseNativeHostTarget) async -> ComputerUseNativeCaptureResult = {
                await NativePlatform.capture(target: $0)
            },
            uiTree: @escaping @Sendable (ComputerUseNativeHostTarget) -> String? = {
                NativePlatform.uiTree(target: $0)
            },
            semanticAction: @escaping @Sendable (ComputerUseNativeHostTarget, String, String) -> Bool = {
                NativePlatform.semanticAction(target: $0, role: $1, label: $2)
            },
            leftClick: @escaping @Sendable (ComputerUseNativeHostTarget, [Double]) -> ComputerUseNativeClickResult = {
                NativePlatform.leftClick(target: $0, coordinate: $1)
            },
            focusedTarget: @escaping @Sendable (ComputerUseNativeHostTarget) -> Bool = {
                NativePlatform.focusedTarget(target: $0)
            },
            typeText: @escaping @Sendable (ComputerUseNativeHostTarget, String) -> Bool = {
                NativePlatform.typeText(target: $0, text: $1)
            },
            pixelAction: @escaping @Sendable (ComputerUseNativeHostTarget, String, [Double]) -> Bool = {
                NativePlatform.pixelAction(target: $0, name: $1, coordinate: $2)
            },
            activate: @escaping @Sendable (ComputerUseNativeHostTarget) -> Bool = {
                NativePlatform.restoreWindow(target: $0)
            },
            hostLauncherPath: @escaping @Sendable () -> String? = {
                NativePlatform.hostLauncherExecutablePath()
            },
            setValue: @escaping @Sendable (ComputerUseNativeHostTarget, String, String, String, Set<RiskCategory>?) -> ComputerUseNativeSetValueResult = {
                NativePlatform.setValue(target: $0, role: $1, label: $2, value: $3, allowedRisks: $4)
            },
            menuShortcut: @escaping @Sendable (ComputerUseNativeHostTarget, ComputerUseNativeMenuChord, Set<RiskCategory>?) -> ComputerUseNativeMenuShortcutResult = {
                NativePlatform.menuShortcut(target: $0, chord: $1, allowedRisks: $2)
            },
            semanticConfirm: @escaping @Sendable (ComputerUseNativeHostTarget, String, String) -> Bool = {
                NativePlatform.semanticConfirm(target: $0, role: $1, label: $2)
            },
            isFocusedElement: @escaping @Sendable (ComputerUseNativeHostTarget, String, String) -> Bool = {
                NativePlatform.isFocusedElement(target: $0, role: $1, label: $2)
            },
            settleWatcher: @escaping @Sendable (ComputerUseNativeHostTarget) -> NativeSettleWatcher = {
                NativePlatform.settleWatcher(target: $0)
            },
            semanticActionByID: @escaping @Sendable (ComputerUseNativeHostTarget, String) -> Bool = {
                NativePlatform.semanticAction(target: $0, elementID: $1)
            },
            setValueByID: @escaping @Sendable (ComputerUseNativeHostTarget, String, String, Set<RiskCategory>?) -> ComputerUseNativeSetValueResult = {
                NativePlatform.setValue(target: $0, elementID: $1, value: $2, allowedRisks: $3)
            },
            semanticConfirmByID: @escaping @Sendable (ComputerUseNativeHostTarget, String) -> Bool = {
                NativePlatform.semanticConfirm(target: $0, elementID: $1)
            },
            isFocusedElementByID: @escaping @Sendable (ComputerUseNativeHostTarget, String) -> Bool = {
                NativePlatform.isFocusedElement(target: $0, elementID: $1)
            },
            recognizeText: @escaping @Sendable (CGImage) async throws -> [OCRElement] = {
                try await OCRPerception.recognize($0)
            }
        ) {
            self.semanticActionByID = semanticActionByID
            self.setValueByID = setValueByID
            self.semanticConfirmByID = semanticConfirmByID
            self.isFocusedElementByID = isFocusedElementByID
            self.recognizeText = recognizeText
            self.setValue = setValue
            self.menuShortcut = menuShortcut
            self.semanticConfirm = semanticConfirm
            self.isFocusedElement = isFocusedElement
            self.settleWatcher = settleWatcher
            self.hostLauncherPath = hostLauncherPath
            self.listWindows = listWindows
            self.userActivity = userActivity
            self.activityMonitorAvailable = activityMonitorAvailable
            self.accessibilityPermission = accessibilityPermission
            self.axTargetAvailable = axTargetAvailable
            self.screenCapturePermission = screenCapturePermission
            self.capture = capture
            self.uiTree = uiTree
            self.semanticAction = semanticAction
            self.leftClick = leftClick
            self.focusedTarget = focusedTarget
            self.typeText = typeText
            self.pixelAction = pixelAction
            self.activate = activate
        }
    }

    private enum Failure: String {
        case invalid_target
        case target_not_found
        case missing_state_token
        case stale_state_token
        case human_activity
        case activity_monitor_unavailable
        case permission_required
        case pixel_target_not_renderable
        case focus_required
        case activation_forbidden
        case semantic_action_failed
        case capture_unavailable
        case capture_too_large
        case ui_tree_unavailable
        case invalid_region
    }

    private enum TokenKind: String {
        case semantic
        case pixel
        case geometry
    }

    // PERF: nibble table instead of per-byte String(format:) — same lowercase hex.
    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(Self.hexAlphabet[Int(byte >> 4)])
            out.append(Self.hexAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private struct PixelScope: Equatable {
        let fullImageSize: [Int]
        let region: [Int]?
        /// Size of the image the caller received when it was scaled down; its coordinates are in this space.
        var imageSize: [Int]? = nil

        var outputImageSize: [Int] {
            if let imageSize, imageSize.count == 2 { return imageSize }
            guard let region, region.count == 4 else { return fullImageSize }
            return [region[2], region[3]]
        }
    }

    private struct PixelTokenEnvelope: Codable, Equatable {
        let version: Int
        let targetPID: Int32
        let targetWindowID: UInt32
        let windowBounds: [Double]
        let accessibilityPermission: Bool
        let screenCapturePermission: Bool
        let fullImageSize: [Int]
        let region: [Int]?
        let pixelsDigest: String
        var imageSize: [Int]? = nil

        var scope: PixelScope {
            PixelScope(
                fullImageSize: fullImageSize,
                region: region,
                imageSize: imageSize
            )
        }
    }

    private let hooks: Hooks

    // A native screenshot is retained as decoded pixels, PNG bytes, base64,
    // and then once more in the MCP JSON envelope. Rejecting before base64
    // keeps the wire shape unchanged while bounding the peak allocation.
    static let maximumCapturePixelDimension = 8_192
    static let maximumCapturePixelCount = 24_000_000
    static let maximumCaptureEncodedBytes = 8 * 1_024 * 1_024
    static let maximumCaptureBase64Characters =
        ((maximumCaptureEncodedBytes + 2) / 3) * 4

    // PNG-inflate metrics for zoom/screenshot tests. Incremented only when
    // `NSBitmapImageRep(data:)` expands encoded PNG into pixels — not when a
    // live `CGImage` is cropped or wrapped for encode.
    private static let pngInflateLock = NSLock()
    private static var pngPixelInflateCountStorage = 0
    private static var lastPNGInflatePixelCountStorage = 0

    static var pngPixelInflateCount: Int {
        pngInflateLock.lock()
        defer { pngInflateLock.unlock() }
        return pngPixelInflateCountStorage
    }

    static var lastPNGInflatePixelCount: Int {
        pngInflateLock.lock()
        defer { pngInflateLock.unlock() }
        return lastPNGInflatePixelCountStorage
    }

    static func resetPNGPixelInflateMetrics() {
        pngInflateLock.lock()
        pngPixelInflateCountStorage = 0
        lastPNGInflatePixelCountStorage = 0
        pngInflateLock.unlock()
    }

    private static func recordPNGPixelInflate(pixelCount: Int) {
        pngInflateLock.lock()
        pngPixelInflateCountStorage += 1
        lastPNGInflatePixelCountStorage = pixelCount
        pngInflateLock.unlock()
    }

    /// Zoom region for the in-flight capture. NativePlatform reads this so a
    /// live `CGImage` can be cropped before PNG/base64 without changing the
    /// public capture-hook arity used by DistillService/rc2.
    enum CaptureZoomContext {
        @TaskLocal static var region: CGRect?
        /// Long-edge limit for the encoded window image; 0 keeps the native frame.
        @TaskLocal static var maxDimension: Int = 0
    }

    /// Models see screenshots resized by their client. A Retina frame leaves no way to know by how
    /// much, so clicks read from it land elsewhere; a frame this size is passed through unchanged.
    public static let defaultMaxImageDimension = 1366

    public init(hooks: Hooks = Hooks()) {
        self.hooks = hooks
    }

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        if name == "list_windows" {
            let bundleID = arguments["bundle_id"] as? String
                ?? arguments["target_app"] as? String
            let windows = hooks.listWindows(bundleID)
            return ComputerUseToolResult(text: encodeWindows(windows))
        }

        guard let target = Self.target(from: arguments) else {
            return failure(.invalid_target, "target_pid and target_window_id are required")
        }
        guard let window = resolve(target: target, arguments: arguments) else {
            return failure(.target_not_found, "the exact PID/window target is not present")
        }

        switch name {
        case "screenshot", "zoom":
            let requestedRegion: CGRect?
            if name == "zoom" {
                guard let region = Self.pixelRegion(arguments["region"]) else {
                    let observation = await makeObservation(
                        window: window,
                        kind: .pixel,
                        content: "<invalid-region>"
                    )
                    return failure(.invalid_region, encodeObservation(observation))
                }
                requestedRegion = region
            } else {
                requestedRegion = nil
            }

            let limit: Int
            if name == "zoom" {
                limit = 0
            } else if let raw = arguments["max_image_dimension"] {
                guard let requested = Self.exactPixelInteger(raw), requested >= 0 else {
                    return failure(.invalid_target, "max_image_dimension must be a non-negative integer; 0 keeps the native frame")
                }
                limit = requested
            } else {
                limit = hooks.maxImageDimension()
            }
            var capture: ComputerUseNativeCapture?
            let captureFailure: String?
            if hooks.screenCapturePermission(), window.isOnScreen, !window.isMinimized {
                switch await CaptureZoomContext.$region.withValue(requestedRegion, operation: {
                    await CaptureZoomContext.$maxDimension.withValue(limit) { await hooks.capture(target) }
                }) {
                case .success(let image), .quartzFallback(let image):
                    if Self.captureDataExceedsBudget(image) {
                        capture = nil
                        captureFailure = "capture_too_large"
                    } else {
                        capture = image
                        captureFailure = nil
                    }
                case .unavailable(let reason):
                    if requestedRegion != nil, reason == Failure.invalid_region.rawValue {
                        let observation = await makeObservation(
                            window: window,
                            kind: .pixel,
                            content: "<invalid-region>"
                        )
                        return failure(.invalid_region, encodeObservation(observation))
                    }
                    capture = nil
                    captureFailure = reason
                }
            } else {
                capture = nil
                captureFailure = nil
            }
            var pixelScope: PixelScope?
            if let captured = capture {
                if let applied = Self.applyPixelRegion(captured, region: requestedRegion) {
                    capture = applied.capture
                    pixelScope = PixelScope(
                        fullImageSize: applied.fullImageSize,
                        region: requestedRegion.map {
                            [
                                Int($0.origin.x), Int($0.origin.y),
                                Int($0.width), Int($0.height),
                            ]
                        },
                        imageSize: requestedRegion == nil ? applied.capture.outputPixelSize : nil
                    )
                } else {
                    let observation = await makeObservation(
                        window: window,
                        kind: .pixel,
                        content: requestedRegion == nil ? "<pixels-unavailable>" : "<invalid-region>"
                    )
                    return failure(
                        requestedRegion == nil ? .capture_unavailable : .invalid_region,
                        encodeObservation(observation)
                    )
                }
            }
            let observation = await makeObservation(
                window: window,
                kind: .pixel,
                content: capture?.data ?? "<pixels-unavailable>",
                pixelScope: pixelScope
            )
            if name == "screenshot", capture != nil, let pixelScope {
                NativeSnapshotStore.shared.recordScreenshot(target: target, imageSize: pixelScope.outputImageSize, windowSize: window.bounds.size)
            }
            return captureResult(
                observation: observation,
                imageSize: capture == nil ? nil : pixelScope?.outputImageSize,
                windowSize: window.bounds.size,
                image: capture,
                failureReason: captureFailure
            )
        case "doctor":
            let observation = await makeObservation(window: window, kind: .semantic)
            return ComputerUseToolResult(text: encodeObservation(observation))
        case "get_ui_tree":
            let ocrMode = (arguments["ocr"] as? String) ?? "auto"
            guard arguments["ocr"] == nil || ["auto", "always", "never"].contains(ocrMode) else {
                return failure(.invalid_target, "ocr must be auto, always or never")
            }
            let tree = hooks.uiTree(target)
            let observation = await makeObservation(window: window, kind: .semantic, content: tree)
            guard observation.accessibilityPermission,
                  let tree else {
                return failure(.ui_tree_unavailable, encodeObservation(observation))
            }
            NativeSnapshotStore.shared.deliver(token: observation.stateToken, target: target)
            // OCR is evidence appended after the AX tree; it never changes the
            // semantic token and never fails the call.
            let perception = await ocrPerception(mode: ocrMode, tree: tree, target: target, observation: observation)
            var extra: [String: Any] = ["perception_sources": perception.elements == nil ? ["ax"] : ["ax", "ocr"]]
            if let error = perception.error { extra["ocr_error"] = error }
            var text = encodeObservation(observation, extra: extra) + "\nui_tree: \(tree)"
            if let elements = perception.elements {
                text += "\nocr: \(encode(OCRPerception.jsonObject(elements)))"
            }
            return ComputerUseToolResult(text: text)
        case "cursor_position":
            let observation = await makeObservation(window: window, kind: .geometry)
            return ComputerUseToolResult(text: encodeObservation(observation) + "\n"
                + "cursor_position: \(Self.cursorPosition())")
        case "left_click", "right_click", "mouse_move", "scroll", "type", "key", "click_element", "set_value", "menu_shortcut", "open_application", "restore_window":
            let kind: TokenKind = name == "restore_window" || name == "key" ? .geometry : (["type", "click_element", "set_value", "menu_shortcut"].contains(name) ? .semantic : .pixel)
            // Preflight only needs metadata. Read the expensive pixels/AX tree
            // once, after the human-activity check, in mutate's final validation.
            let observation = await makeObservation(window: window, kind: .geometry)
            let frontBefore = hooks.frontmostPID()
            let result = await NativeSnapshotStore.$actionToken.withValue(arguments["expected_state_token"] as? String) {
                await mutate(
                    name: name,
                    target: target,
                    window: window,
                    observation: observation,
                    tokenKind: kind,
                    arguments: arguments
                )
            }
            return returnFocus(result, name: name, target: target, frontBefore: frontBefore)
        default:
            return failure(.invalid_target, "unsupported native computer-use operation: \(name)")
        }
    }

    private func resolve(
        target: ComputerUseNativeHostTarget,
        arguments: [String: Any]
    ) -> ComputerUseNativeWindow? {
        let bundleID = arguments["target_app"] as? String
        return hooks.listWindows(bundleID).first { $0.target == target }
    }

    private func makeObservation(
        window: ComputerUseNativeWindow,
        kind: TokenKind,
        content: String? = nil,
        pixelScope: PixelScope? = nil
    ) async -> ComputerUseNativeHostObservation {
        let accessibility = hooks.accessibilityPermission()
        let screenCapture = hooks.screenCapturePermission()
        let renderable = screenCapture && window.isOnScreen && !window.isMinimized
        let semanticAXAvailable = accessibility && hooks.axTargetAvailable(window.target)
        var capabilities = ["observe", "targeted"]
        if renderable { capabilities.append("window_capture") }
        if semanticAXAvailable { capabilities.append("semantic_ax") }
        let activity = hooks.userActivity(window.target)
        let observedContent: String
        var effectivePixelScope = pixelScope
        if kind == .pixel, !renderable {
            effectivePixelScope = nil
        }
        switch kind {
        case .semantic:
            observedContent = content ?? hooks.uiTree(window.target) ?? "<ui-tree-unavailable>"
        case .pixel:
            if let content {
                observedContent = content
            } else if renderable {
                let captureRegion: CGRect? = {
                    guard let region = pixelScope?.region, region.count == 4 else { return nil }
                    return CGRect(x: region[0], y: region[1], width: region[2], height: region[3])
                }()
                switch await CaptureZoomContext.$region.withValue(captureRegion, operation: {
                    await hooks.capture(window.target)
                }) {
                case .success(let capture), .quartzFallback(let capture):
                    guard !Self.captureDataExceedsBudget(capture) else {
                        observedContent = "<pixels-unavailable>"
                        effectivePixelScope = nil
                        break
                    }
                    if let pixelScope,
                       let applied = Self.applyPixelRegion(capture, region: captureRegion) {
                        observedContent = applied.capture.data
                        effectivePixelScope = PixelScope(
                            fullImageSize: applied.fullImageSize,
                            region: pixelScope.region,
                            imageSize: pixelScope.imageSize
                        )
                    } else {
                        observedContent = capture.data
                        effectivePixelScope = nil
                    }
                case .unavailable:
                    observedContent = "<pixels-unavailable>"
                    effectivePixelScope = nil
                }
            } else {
                observedContent = "<pixels-unavailable>"
            }
        case .geometry:
            observedContent = "<geometry-only>"
        }
        let token = stateToken(
            window: window,
            accessibilityPermission: accessibility,
            screenCapturePermission: screenCapture,
            kind: kind,
            content: observedContent,
            pixelScope: effectivePixelScope
        )
        if kind == .semantic { NativeSnapshotStore.shared.bind(token: token, tree: observedContent, target: window.target) }
        return ComputerUseNativeHostObservation(
            target: window.target,
            stateToken: token,
            captureMode: renderable ? "window" : "unavailable",
            capabilities: capabilities,
            userActivity: activity,
            accessibilityPermission: accessibility,
            screenCapturePermission: screenCapture,
            isMinimized: window.isMinimized,
            isOnScreen: window.isOnScreen
        )
    }

    private func captureResult(
        observation: ComputerUseNativeHostObservation,
        imageSize: [Int]? = nil,
        windowSize: CGSize = .zero,
        image: ComputerUseNativeCapture?,
        failureReason: String?
    ) -> ComputerUseToolResult {
        guard observation.screenCapturePermission,
              !observation.isMinimized,
              observation.isOnScreen else {
            return failure(.pixel_target_not_renderable, encodeObservation(observation))
        }
        guard let image else {
            if failureReason == Failure.capture_too_large.rawValue {
                return failure(.capture_too_large, encodeObservation(observation))
            }
            let diagnostic = failureReason.map { "\n capture_failure: \($0)" } ?? ""
            return failure(.capture_unavailable, encodeObservation(observation) + diagnostic)
        }
        // Say what the pixels mean: without the size the caller cannot tell a resized image from this one.
        var extra: [String: Any] = [:]
        if let imageSize {
            extra["image_size"] = imageSize
            extra["window_size"] = [Double(windowSize.width), Double(windowSize.height)]
            extra["coordinates"] = "x,y for click tools are pixels of this image (image_size), top-left origin"
        }
        return ComputerUseToolResult(content: [
            .text(encodeObservation(observation, extra: extra)),
            .image(data: image.data, mimeType: image.mimeType),
        ])
    }

    private func mutate(
        name: String,
        target: ComputerUseNativeHostTarget,
        window: ComputerUseNativeWindow,
        observation: ComputerUseNativeHostObservation,
        tokenKind: TokenKind,
        arguments: [String: Any]
    ) async -> ComputerUseToolResult {
        // Check the physical user before any permission or action probe: human
        // activity wins unless the caller escalated with allow_while_user_active,
        // and cannot be hidden by a stale automation call.
        guard hooks.activityMonitorAvailable() else {
            return failure(.activity_monitor_unavailable, encodeObservation(observation))
        }
        let yieldsToUser = arguments["allow_while_user_active"] as? Bool != true
        if yieldsToUser, hooks.userActivity(target) == .human {
            return failure(.human_activity, encodeObservation(observation))
        }
        if observation.isMinimized,
           ["left_click", "right_click", "mouse_move", "scroll", "type", "key"].contains(name) {
            return failure(
                .pixel_target_not_renderable,
                "\(name) needs input events; restore_window first\n\(encodeObservation(observation))"
            )
        }
        guard let expected = arguments["expected_state_token"] as? String,
              !expected.isEmpty else {
            return failure(.missing_state_token, encodeObservation(observation))
        }
        let expectedPixelScope: PixelScope?
        if tokenKind == .pixel {
            guard let envelope = Self.decodePixelToken(expected),
                  envelope.targetPID == target.pid,
                  envelope.targetWindowID == target.windowID else {
                return failure(.stale_state_token, encodeObservation(observation))
            }
            expectedPixelScope = envelope.scope
        } else {
            expectedPixelScope = nil
        }
        // Re-read the capability-specific content immediately before the
        // mutation. The observation token is never a substitute for this
        // final race check.
        guard let freshWindow = resolve(target: target, arguments: arguments) else {
            return failure(.target_not_found, encodeObservation(observation))
        }
        let freshObservation = await makeObservation(
            window: freshWindow,
            kind: tokenKind,
            pixelScope: expectedPixelScope
        )
        guard expected == freshObservation.stateToken
                || survivesChange(name: name, target: target, expected: expected, fresh: freshObservation.stateToken, arguments: arguments) else {
            return failure(.stale_state_token, encodeObservation(freshObservation))
        }
        // The content read above can take time (AX traversal or a screenshot).
        // Give a physical user event observed during that window priority too.
        if yieldsToUser, hooks.userActivity(target) == .human {
            return failure(.human_activity, encodeObservation(freshObservation))
        }

        switch name {
        case "left_click", "right_click", "mouse_move", "scroll":
            guard freshObservation.accessibilityPermission else {
                return failure(.permission_required, encodeObservation(freshObservation))
            }
            guard let localCoordinate = Self.localCoordinate(arguments["coordinate"]),
                  let coordinate = pixelCoordinate(
                    local: localCoordinate,
                    window: freshWindow,
                    observation: freshObservation,
                    scope: expectedPixelScope
                  ) else {
                return failure(.semantic_action_failed, encodeObservation(freshObservation))
            }
            guard freshObservation.screenCapturePermission,
                  freshObservation.isOnScreen,
                  !freshObservation.isMinimized else {
                return failure(.pixel_target_not_renderable, encodeObservation(freshObservation))
            }
            guard let currentWindow = resolve(target: target, arguments: arguments), currentWindow == freshWindow else {
                return failure(.stale_state_token, encodeObservation(freshObservation))
            }
            if yieldsToUser, hooks.userActivity(target) == .human {
                return failure(.human_activity, encodeObservation(freshObservation))
            }
            let watcher = hooks.settleWatcher(target)
            defer { watcher.cancel() }
            if name == "left_click" {
                switch hooks.leftClick(target, coordinate) {
                case .applied:
                    break
                case .failed:
                    return failure(.semantic_action_failed, encodeObservation(freshObservation))
                case .noAXTarget:
                    guard hooks.focusedTarget(target) else {
                        return failure(.focus_required, encodeObservation(freshObservation))
                    }
                    guard hooks.pixelAction(target, name, coordinate) else {
                        return failure(.semantic_action_failed, encodeObservation(freshObservation))
                    }
                }
            } else {
                var actionCoordinate = coordinate
                if name == "scroll" {
                    guard let deltaX = Self.finiteNumber(arguments["delta_x"]),
                          let deltaY = Self.finiteNumber(arguments["delta_y"]),
                          abs(deltaX) <= 10_000, abs(deltaY) <= 10_000 else {
                        return failure(.semantic_action_failed, encodeObservation(freshObservation))
                    }
                    actionCoordinate += [deltaX, deltaY]
                }
                guard hooks.focusedTarget(target) else {
                    return failure(.focus_required, encodeObservation(freshObservation))
                }
                guard hooks.pixelAction(target, name, actionCoordinate) else {
                    return failure(.semantic_action_failed, encodeObservation(freshObservation))
                }
            }
            guard let postWindow = resolve(target: target, arguments: arguments) else {
                return failure(.target_not_found, encodeObservation(freshObservation))
            }
            let settle = watcher.wait()
            let postObservation = await makeObservation(window: postWindow, kind: .pixel, pixelScope: expectedPixelScope)
            return ComputerUseToolResult(text: "native \(name) applied\n\(encodeObservation(postObservation, settle: settle))")
        case "key":
            guard hooks.focusedTarget(target),
                  let parsedKey = Self.parsedKey(arguments["key"], modifiers: arguments["modifiers"]) else {
                return failure(.focus_required, encodeObservation(freshObservation))
            }
            guard !yieldsToUser || hooks.userActivity(target) != .human else {
                return failure(.human_activity, encodeObservation(freshObservation))
            }
            guard let currentWindow = resolve(target: target, arguments: arguments) else {
                return failure(.target_not_found, encodeObservation(freshObservation))
            }
            guard currentWindow == freshWindow else {
                return failure(.stale_state_token, encodeObservation(freshObservation))
            }
            let watcher = hooks.settleWatcher(target)
            defer { watcher.cancel() }
            guard hooks.pixelAction(target, "key", [Double(parsedKey.keyCode), Double(parsedKey.flags)]) else {
                return failure(.focus_required, encodeObservation(freshObservation))
            }
            guard let postWindow = resolve(target: target, arguments: arguments) else {
                return failure(.target_not_found, encodeObservation(freshObservation))
            }
            let settle = watcher.wait()
            let postObservation = await makeObservation(window: postWindow, kind: .geometry)
            return ComputerUseToolResult(text: "native key applied; target remained explicitly focused\n\(encodeObservation(postObservation, settle: settle))")
        case "click_element":
            guard freshObservation.accessibilityPermission,
                  freshObservation.capabilities.contains("semantic_ax") else {
                return failure(.permission_required, encodeObservation(freshObservation))
            }
            let parsed = NativeElementSelector.parse(arguments)
            guard let selector = parsed.selector else {
                return failure(.semantic_action_failed, "\(parsed.error ?? "invalid element selector")\n\(encodeObservation(freshObservation))")
            }
            guard let currentWindow = resolve(target: target, arguments: arguments) else {
                return failure(.target_not_found, encodeObservation(freshObservation))
            }
            guard currentWindow == freshWindow else {
                return failure(.stale_state_token, encodeObservation(freshObservation))
            }
            let watcher = hooks.settleWatcher(target)
            defer { watcher.cancel() }
            let pressed: Bool
            switch selector {
            case .roleLabel(let role, let label): pressed = hooks.semanticAction(target, role, label)
            case .id(let id): pressed = hooks.semanticActionByID(target, id)
            }
            guard pressed else {
                return failure(.semantic_action_failed, encodeObservation(freshObservation))
            }
            let settle = watcher.wait()
            return await semanticResult(
                "native semantic action applied", target: target, arguments: arguments,
                fallback: freshObservation, settle: settle
            )
        case "set_value":
            guard freshObservation.accessibilityPermission,
                  freshObservation.capabilities.contains("semantic_ax") else {
                return failure(.permission_required, encodeObservation(freshObservation))
            }
            let parsed = NativeElementSelector.parse(arguments)
            guard let selector = parsed.selector else {
                return failure(.semantic_action_failed, "\(parsed.error ?? "invalid element selector")\n\(encodeObservation(freshObservation))")
            }
            guard let value = arguments["value"] as? String else {
                return failure(.semantic_action_failed, "string value is required\n\(encodeObservation(freshObservation))")
            }
            let submitKey = (arguments["submit_key"] as? String)?.uppercased()
            if arguments["submit_key"] != nil, submitKey != "ENTER", submitKey != "TAB" {
                return failure(.semantic_action_failed, "submit_key must be ENTER or TAB\n\(encodeObservation(freshObservation))")
            }
            let allowedRisks: Set<RiskCategory>?
            switch Self.allowedRisks(arguments["allowed_risks"]) {
            case .success(let value): allowedRisks = value
            case .failure(let message):
                return failure(.semantic_action_failed, "\(message)\n\(encodeObservation(freshObservation))")
            }
            guard let currentWindow = resolve(target: target, arguments: arguments) else {
                return failure(.target_not_found, encodeObservation(freshObservation))
            }
            guard currentWindow == freshWindow else {
                return failure(.stale_state_token, encodeObservation(freshObservation))
            }
            let watcher = hooks.settleWatcher(target)
            defer { watcher.cancel() }
            let setResult: ComputerUseNativeSetValueResult
            switch selector {
            case .roleLabel(let role, let label): setResult = hooks.setValue(target, role, label, value, allowedRisks)
            case .id(let id): setResult = hooks.setValueByID(target, id, value, allowedRisks)
            }
            if case .failed(let reason) = setResult {
                return failure(.semantic_action_failed, "\(reason)\n\(encodeObservation(freshObservation))")
            }
            var settle = watcher.wait()
            var message = "native value set"
            func isFocused(_ selector: NativeElementSelector) -> Bool {
                switch selector {
                case .roleLabel(let role, let label): return hooks.isFocusedElement(target, role, label)
                case .id(let id): return hooks.isFocusedElementByID(target, id)
                }
            }
            func confirm(_ selector: NativeElementSelector) -> Bool {
                switch selector {
                case .roleLabel(let role, let label): return hooks.semanticConfirm(target, role, label)
                case .id(let id): return hooks.semanticConfirmByID(target, id)
                }
            }
            if let submitKey {
                let submitWatcher = hooks.settleWatcher(target)
                defer { submitWatcher.cancel() }
                var submitted = false
                // The value is already set; a user takeover or window change during the settle must block both submit paths.
                func submitBlocked() -> ComputerUseToolResult? {
                    if yieldsToUser, hooks.userActivity(target) == .human {
                        return failure(.human_activity, "value set; submit_key \(submitKey) not applied\n\(encodeObservation(freshObservation))")
                    }
                    guard let current = resolve(target: target, arguments: arguments) else {
                        return failure(.target_not_found, encodeObservation(freshObservation))
                    }
                    guard current == freshWindow else {
                        return failure(.stale_state_token, encodeObservation(freshObservation))
                    }
                    return nil
                }
                if let blocked = submitBlocked() { return blocked }
                if hooks.focusedTarget(target), isFocused(selector),
                   let key = Self.parsedKey(submitKey == "ENTER" ? "return" : "tab", modifiers: nil) {
                    submitted = hooks.pixelAction(target, "key", [Double(key.keyCode), Double(key.flags)])
                    message += submitted ? "; \(submitKey) key posted" : ""
                }
                if !submitted, submitKey == "ENTER" {
                    if let blocked = submitBlocked() { return blocked }
                }
                if !submitted, submitKey == "ENTER", confirm(selector) {
                    submitted = true
                    message += "; AXConfirm performed"
                }
                if submitted {
                    settle = settle.combined(with: submitWatcher.wait())
                } else {
                    message += "; submit_key \(submitKey) not applied: target not focused (use restore_window first)"
                }
            }
            return await semanticResult(message, target: target, arguments: arguments, fallback: freshObservation, settle: settle)
        case "menu_shortcut":
            guard freshObservation.accessibilityPermission,
                  freshObservation.capabilities.contains("semantic_ax") else {
                return failure(.permission_required, encodeObservation(freshObservation))
            }
            guard let chord = ComputerUseNativeMenuChord.parse(arguments["chord"]) else {
                return failure(.semantic_action_failed, "invalid chord; use MOD/CTRL/ALT/SHIFT plus one key, e.g. MOD+S\n\(encodeObservation(freshObservation))")
            }
            let allowedRisks: Set<RiskCategory>?
            switch Self.allowedRisks(arguments["allowed_risks"]) {
            case .success(let value): allowedRisks = value
            case .failure(let message):
                return failure(.semantic_action_failed, "\(message)\n\(encodeObservation(freshObservation))")
            }
            guard let currentWindow = resolve(target: target, arguments: arguments) else {
                return failure(.target_not_found, encodeObservation(freshObservation))
            }
            guard currentWindow == freshWindow else {
                return failure(.stale_state_token, encodeObservation(freshObservation))
            }
            let watcher = hooks.settleWatcher(target)
            defer { watcher.cancel() }
            switch hooks.menuShortcut(target, chord, allowedRisks) {
            case .applied:
                break
            case .refused(let reason):
                return failure(.semantic_action_failed, "\(reason)\n\(encodeObservation(freshObservation))")
            case .noMenuItem:
                return failure(.semantic_action_failed, "no enabled menu item has this shortcut\n\(encodeObservation(freshObservation))")
            case .ambiguous:
                return failure(.semantic_action_failed, "more than one enabled menu item has this shortcut\n\(encodeObservation(freshObservation))")
            case .failed:
                return failure(.semantic_action_failed, encodeObservation(freshObservation))
            }
            let settle = watcher.wait()
            return await semanticResult(
                "native menu shortcut applied", target: target, arguments: arguments,
                fallback: freshObservation, settle: settle
            )
        case "restore_window":
            guard let currentWindow = resolve(target: target, arguments: arguments) else {
                return failure(.target_not_found, encodeObservation(freshObservation))
            }
            guard currentWindow == freshWindow else {
                return failure(.stale_state_token, encodeObservation(freshObservation))
            }
            guard hooks.activate(target) else {
                return failure(.activation_forbidden, encodeObservation(freshObservation))
            }
            guard let restoredWindow = resolve(target: target, arguments: arguments),
                  restoredWindow.target == target else {
                return failure(.target_not_found, encodeObservation(freshObservation))
            }
            let restoredObservation = await makeObservation(window: restoredWindow, kind: .geometry)
            return ComputerUseToolResult(text: "native exact window restored; use this fresh state token before further actions\n\(encodeObservation(restoredObservation))")
        case "open_application":
            // Activation changes the human's active app and is never implicit.
            return failure(.activation_forbidden, encodeObservation(freshObservation))
        case "type":
            let text = arguments["text"] as? String ?? ""
            guard freshObservation.capabilities.contains("semantic_ax"), !text.isEmpty else {
                return failure(.focus_required, encodeObservation(freshObservation))
            }
            guard let currentWindow = resolve(target: target, arguments: arguments) else {
                return failure(.target_not_found, encodeObservation(freshObservation))
            }
            guard currentWindow == freshWindow else {
                return failure(.stale_state_token, encodeObservation(freshObservation))
            }
            let watcher = hooks.settleWatcher(target)
            defer { watcher.cancel() }
            guard hooks.typeText(target, text) else {
                return failure(.focus_required, encodeObservation(freshObservation))
            }
            let settle = watcher.wait()
            return await semanticResult(
                "native background typing applied", target: target, arguments: arguments,
                fallback: freshObservation, settle: settle
            )
        default:
            return failure(.invalid_target, "unsupported native mutation")
        }
    }

    private func ocrPerception(
        mode: String,
        tree: String,
        target: ComputerUseNativeHostTarget,
        observation: ComputerUseNativeHostObservation
    ) async -> (elements: [OCRElement]?, error: String?) {
        guard mode != "never" else { return (nil, nil) }
        if mode == "auto" {
            guard let data = tree.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  OCRPerception.needsOCR(uiTree: root) else { return (nil, nil) }
        }
        guard observation.captureMode == "window" else {
            return (nil, "window is not renderable or screen capture is not granted")
        }
        let capture: ComputerUseNativeCapture
        switch await hooks.capture(target) {
        case .success(let image), .quartzFallback(let image):
            capture = image
        case .unavailable(let reason):
            return (nil, "capture failed: \(reason)")
        }
        guard !Self.captureDataExceedsBudget(capture),
              let decoded = Self.decodedCaptureImage(capture) else {
            return (nil, "capture could not be decoded")
        }
        do {
            return (try await hooks.recognizeText(decoded.image), nil)
        } catch {
            return (nil, "ocr failed: \(String(describing: error).prefix(200))")
        }
    }

    /// Fresh semantic observation after a settled AX mutation; its token is
    /// the one to use for the next action.
    private func semanticResult(
        _ message: String,
        target: ComputerUseNativeHostTarget,
        arguments: [String: Any],
        fallback: ComputerUseNativeHostObservation,
        settle: NativeSettle.Result
    ) async -> ComputerUseToolResult {
        guard let postWindow = resolve(target: target, arguments: arguments) else {
            return failure(.target_not_found, encodeObservation(fallback))
        }
        let post = await makeObservation(window: postWindow, kind: .semantic)
        return ComputerUseToolResult(text: "\(message)\n\(encodeObservation(post, settle: settle))")
    }

    /// nil when the argument is absent; an empty list allows no risky category.
    private static func allowedRisks(_ raw: Any?) -> Result<Set<RiskCategory>?, SubtaskError> {
        guard let raw else { return .success(nil) }
        guard let names = raw as? [String] else {
            return .failure(.invalid(field: "allowed_risks", reason: "must be an array of strings"))
        }
        var categories = Set<RiskCategory>()
        for name in names {
            guard let category = RiskCategory(rawValue: name) else {
                return .failure(.invalid(field: "allowed_risks", reason: "every entry must be one of delete, send, purchase, close"))
            }
            categories.insert(category)
        }
        return .success(categories)
    }

    /// A background action must leave the user's app in front. Pressing or focusing a control makes
    /// some apps bring themselves forward; when the target did that and the user did not go there
    /// themselves, the front is handed back. restore_window is the one tool whose purpose is focus.
    private func returnFocus(_ result: ComputerUseToolResult, name: String, target: ComputerUseNativeHostTarget,
                             frontBefore: Int32?) -> ComputerUseToolResult {
        guard name != "restore_window", let frontBefore, frontBefore != target.pid, hooks.frontmostPID() == target.pid,
              hooks.userActivity(target) != .human else { return result }
        let returned = hooks.activateApp(frontBefore)
        var result = result
        result.content.append(.text("focus: the target app brought itself to the front; \(returned ? "the app that was in front was reactivated" : "reactivating the app that was in front failed")"))
        return result
    }

    /// What to do next, for the refusals a caller can act on. A bare code sent agents into
    /// repeating the same call.
    private static func hint(for error: Failure) -> String? {
        switch error {
        case .human_activity: return ChromeProfileComputerUseBackend.humanActivityHint
        case .stale_state_token: return "the element or frame this action was read from is no longer current. Read the window again (get_ui_tree, or screenshot for pixel tools) and retry with what it returns."
        case .missing_state_token: return "pass expected_state_token from the get_ui_tree or screenshot this action is based on."
        case .target_not_found: return "that pid and window id are not on the window list now. Call list_windows."
        case .focus_required: return "this route needs the exact window focused. Use click, press_key or hotkey with delivery_mode: \"foreground\", or restore_window, when the work cannot be done in the background."
        case .semantic_action_failed: return "the accessibility action was not accepted or the selector did not match exactly one element. Read the window again; if the element is there, use click with element_id and action: \"pointer\"."
        case .pixel_target_not_renderable: return "the window is minimized or off screen, so there are no pixels to act on. Use the accessibility tools, or restore_window."
        default: return nil
        }
    }

    private func failure(_ error: Failure, _ detail: String) -> ComputerUseToolResult {
        let hint = Self.hint(for: error).map { ": " + $0 } ?? ""
        return ComputerUseToolResult(
            text: "native computer-use error: \(error.rawValue)\(hint)\n\(detail)",
            isError: true
        )
    }

    /// Why a permission is false is invisible from inside the helper: the
    /// grant lives on the app that launched the provider (TCC "responsible
    /// process"). Name that app and the exact remediation so an agent or the
    /// owner can act without guessing.
    static func permissionRemediation(
        accessibility: Bool,
        screenCapture: Bool,
        launchedBy: String?
    ) -> String? {
        guard !accessibility || !screenCapture else { return nil }
        var missing: [String] = []
        if !screenCapture { missing.append("Screen Recording") }
        if !accessibility { missing.append("Accessibility") }
        let app = launchedBy.map { path -> String in
            if let range = path.range(of: ".app/") {
                return String(path[..<range.lowerBound]) + ".app"
            }
            return path
        } ?? "the app that launched this run"
        return "Missing \(missing.joined(separator: " and ")) for \(app). macOS grants these to the launching app, not to this helper: in System Settings › Privacy & Security enable it for that app; if it is already listed, remove the entry and add the app again (the entry may belong to an older build), then start a new run."
    }

    private func encodeObservation(
        _ observation: ComputerUseNativeHostObservation,
        settle: NativeSettle.Result? = nil,
        extra: [String: Any] = [:]
    ) -> String {
        var object: [String: Any] = [
            "target_pid": Int(observation.target.pid),
            "target_window_id": Int(observation.target.windowID),
            "state_token": observation.stateToken,
            "capture_mode": observation.captureMode,
            "capabilities": observation.capabilities,
            "user_activity": observation.userActivity.rawValue,
            "permissions": [
                "accessibility": observation.accessibilityPermission,
                "screen_capture": observation.screenCapturePermission,
            ],
            "is_minimized": observation.isMinimized,
            "is_on_screen": observation.isOnScreen,
        ]
        object.merge(extra) { _, new in new }
        if let settle {
            object["settle_ms"] = settle.elapsedMilliseconds
            object["settled"] = settle.settled
            object["effect"] = settle.effect
        }
        if !observation.accessibilityPermission || !observation.screenCapturePermission {
            let launchedBy = hooks.hostLauncherPath()
            object["launched_by"] = launchedBy as Any
            object["remediation"] = Self.permissionRemediation(
                accessibility: observation.accessibilityPermission,
                screenCapture: observation.screenCapturePermission,
                launchedBy: launchedBy
            ) as Any
        }
        return encode(object)
    }

    private func encodeWindows(_ windows: [ComputerUseNativeWindow]) -> String {
        let object = windows.map { window in
            [
                "target_pid": Int(window.target.pid),
                "target_window_id": Int(window.target.windowID),
                "title": window.title,
                "bundle_id": window.bundleIdentifier as Any,
                "is_on_screen": window.isOnScreen,
                "is_minimized": window.isMinimized,
            ] as [String: Any]
        }
        return encode(object)
    }

    private func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return result
    }

    private func stateToken(
        window: ComputerUseNativeWindow,
        accessibilityPermission: Bool,
        screenCapturePermission: Bool,
        kind: TokenKind,
        content: String,
        pixelScope: PixelScope? = nil
    ) -> String {
        let pid = String(window.target.pid)
        let windowID = String(window.target.windowID)
        let title = window.title
        let bundleID = window.bundleIdentifier ?? ""
        let onScreen = String(window.isOnScreen)
        let minimized = String(window.isMinimized)
        let originX = String(describing: window.bounds.origin.x)
        let originY = String(describing: window.bounds.origin.y)
        let width = String(describing: window.bounds.size.width)
        let height = String(describing: window.bounds.size.height)
        let accessibility = String(accessibilityPermission)
        let screenCapture = String(screenCapturePermission)
        let contentDigest = Self.hexDigest(SHA256.hash(data: Data(content.utf8)))
        if kind == .pixel {
            guard let pixelScope else { return "" }
            let bounds: [Double] = [
                Double(window.bounds.origin.x), Double(window.bounds.origin.y),
                Double(window.bounds.width), Double(window.bounds.height),
            ]
            let envelope = PixelTokenEnvelope(
                version: 1,
                targetPID: window.target.pid,
                targetWindowID: window.target.windowID,
                windowBounds: bounds,
                accessibilityPermission: accessibilityPermission,
                screenCapturePermission: screenCapturePermission,
                fullImageSize: pixelScope.fullImageSize,
                region: pixelScope.region,
                pixelsDigest: contentDigest,
                imageSize: pixelScope.imageSize
            )
            let encoder = Self.pixelTokenEncoder
            Self.pixelTokenCodecLock.lock()
            let data = try? encoder.encode(envelope)
            Self.pixelTokenCodecLock.unlock()
            guard let data else {
                return ""
            }
            return "native-pixel-v1:" + data.base64EncodedString()
        }
        let material = [
            pid, windowID, title, bundleID, onScreen, minimized,
            originX, originY, width, height, accessibility, screenCapture,
            kind.rawValue, contentDigest,
        ].joined(separator: "|")
        return Self.hexDigest(SHA256.hash(data: Data(material.utf8)))
    }

    // PERF: pixel state tokens allocate codecs per observation/mutation race
    // check. JSONEncoder/Decoder are not thread-safe — share one sortedKeys
    // encoder + decoder under a short lock; wire JSON unchanged.
    private static let pixelTokenCodecLock = NSLock()
    private static let pixelTokenEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let pixelTokenDecoder = JSONDecoder()

    private static func decodePixelToken(_ token: String) -> PixelTokenEnvelope? {
        let prefix = "native-pixel-v1:"
        guard token.hasPrefix(prefix),
              let data = Data(base64Encoded: String(token.dropFirst(prefix.count))) else {
            return nil
        }
        pixelTokenCodecLock.lock()
        let envelope = try? pixelTokenDecoder.decode(PixelTokenEnvelope.self, from: data)
        pixelTokenCodecLock.unlock()
        guard let envelope = envelope,
              envelope.version == 1,
              envelope.targetPID > 0,
              envelope.targetWindowID > 0,
              envelope.windowBounds.count == 4,
              envelope.windowBounds.allSatisfy({ $0.isFinite }),
              envelope.fullImageSize.count == 2,
              envelope.fullImageSize.allSatisfy({ $0 > 0 }),
              !envelope.pixelsDigest.isEmpty else {
            return nil
        }
        if let imageSize = envelope.imageSize {
            guard imageSize.count == 2, imageSize.allSatisfy({ $0 > 0 }),
                  imageSize[0] <= envelope.fullImageSize[0], imageSize[1] <= envelope.fullImageSize[1] else { return nil }
        }
        if let region = envelope.region {
            guard
                  region.count == 4,
                  region[0] >= 0, region[1] >= 0,
                  region[2] > 0, region[3] > 0,
                  region[2] <= envelope.fullImageSize[0],
                  region[3] <= envelope.fullImageSize[1],
                  region[0] <= envelope.fullImageSize[0] - region[2],
                  region[1] <= envelope.fullImageSize[1] - region[3] else { return nil }
        }
        return envelope
    }

    private static func target(from arguments: [String: Any]) -> ComputerUseNativeHostTarget? {
        guard let pid = exactInt32(arguments["target_pid"]),
              let windowID = exactUInt32(arguments["target_window_id"]),
              pid > 0,
              windowID > 0 else {
            return nil
        }
        return ComputerUseNativeHostTarget(pid: pid, windowID: windowID)
    }

    static func exactInt32(_ value: Any?) -> Int32? {
        guard !isBooleanNumber(value) else { return nil }
        if let value = value as? Int32 { return value }
        if let value = value as? Int { return Int32(exactly: value) }
        if let value = value as? NSNumber {
            guard let integer = Int(exactly: value.doubleValue) else { return nil }
            return Int32(exactly: integer)
        }
        return nil
    }

    static func exactUInt32(_ value: Any?) -> UInt32? {
        guard !isBooleanNumber(value) else { return nil }
        if let value = value as? UInt32 { return value }
        if let value = value as? UInt { return UInt32(exactly: value) }
        if let value = value as? Int { return UInt32(exactly: value) }
        if let value = value as? NSNumber {
            guard let integer = Int(exactly: value.doubleValue) else { return nil }
            return UInt32(exactly: integer)
        }
        return nil
    }

    private static func exactPixelInteger(_ value: Any?) -> Int? {
        guard !isBooleanNumber(value) else { return nil }
        if let value = value as? Int { return value }
        if let value = value as? Int32 { return Int(value) }
        if let value = value as? UInt32 { return Int(value) }
        if let value = value as? NSNumber {
            return Int(exactly: value.doubleValue)
        }
        return nil
    }

    private static func localCoordinate(_ value: Any?) -> [Double]? {
        let values: [Any]
        if let value = value as? [Any] {
            values = value
        } else if let value = value as? [Double] {
            values = value
        } else if let value = value as? [NSNumber] {
            values = value
        } else {
            return nil
        }
        guard values.count == 2 else { return nil }
        let result = values.compactMap { value -> Double? in
            guard !isBooleanNumber(value) else { return nil }
            if let value = value as? Double { return value.isFinite ? value : nil }
            if let value = value as? Int { return Double(value) }
            if let value = value as? NSNumber {
                let number = value.doubleValue
                return number.isFinite ? number : nil
            }
            return nil
        }
        return result.count == 2 ? result : nil
    }

    private struct ParsedKey {
        let keyCode: UInt16
        let flags: UInt64
    }

    private static func parsedKey(_ value: Any?, modifiers: Any?) -> ParsedKey? {
        guard let name = value as? String,
              name.count == 1 || ["return", "tab", "space", "delete", "escape", "left", "right", "up", "down"].contains(name.lowercased()) else { return nil }
        let upper = name.uppercased()
        let keyCodes: [String: UInt16] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8,
            "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25,
            "7": 26, "8": 28, "0": 29, "O": 31, "U": 32, "I": 34, "P": 35,
            "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
            "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        guard let keyCode = keyCodes[name.lowercased()] ?? keyCodes[upper] else { return nil }
        let values: [String]
        if let modifiers {
            guard let supplied = modifiers as? [String] else { return nil }
            values = supplied
        } else {
            values = []
        }
        guard values.count == Set(values).count,
              values.allSatisfy({ ["command", "control", "option", "shift"].contains($0) }) else { return nil }
        var flags: UInt64 = 0
        for modifier in values {
            switch modifier {
            case "command": flags |= 1 << 20
            case "control": flags |= 1 << 18
            case "option": flags |= 1 << 19
            case "shift": flags |= 1 << 17
            default: return nil
            }
        }
        if name != name.lowercased() && name.count == 1 { flags |= 1 << 17 }
        return ParsedKey(keyCode: keyCode, flags: flags)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard !isBooleanNumber(value) else { return nil }
        if let number = value as? Double, number.isFinite { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
        return nil
    }

    private func pixelCoordinate(
        local: [Double],
        window: ComputerUseNativeWindow,
        observation: ComputerUseNativeHostObservation,
        scope: PixelScope?
    ) -> [Double]? {
        guard observation.target == window.target,
              observation.isOnScreen, !observation.isMinimized,
              let scope,
              let envelope = Self.decodePixelToken(observation.stateToken),
              envelope.scope == scope,
              scope.fullImageSize.count == 2,
              scope.fullImageSize.allSatisfy({ $0 > 0 }),
              scope.outputImageSize.allSatisfy({ $0 > 0 }),
              local[0] >= 0, local[1] >= 0,
              local[0] < Double(scope.outputImageSize[0]),
              local[1] < Double(scope.outputImageSize[1]),
              window.bounds.origin.x.isFinite, window.bounds.origin.y.isFinite,
              window.bounds.width.isFinite, window.bounds.height.isFinite,
              window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        // `local` is in the image the caller received; scale it onto the part of the frame it shows.
        let shown: [Double] = scope.region.flatMap { $0.count == 4 ? $0.map(Double.init) : nil }
            ?? [0, 0, Double(scope.fullImageSize[0]), Double(scope.fullImageSize[1])]
        let fullCoordinate = [
            shown[0] + local[0] * shown[2] / Double(scope.outputImageSize[0]),
            shown[1] + local[1] * shown[3] / Double(scope.outputImageSize[1]),
        ]
        let scaleX = Double(scope.fullImageSize[0]) / window.bounds.width
        let scaleY = Double(scope.fullImageSize[1]) / window.bounds.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0,
              fullCoordinate[0] >= 0, fullCoordinate[1] >= 0,
              fullCoordinate[0] < Double(scope.fullImageSize[0]),
              fullCoordinate[1] < Double(scope.fullImageSize[1]) else { return nil }
        return [window.bounds.minX + fullCoordinate[0] / scaleX,
                window.bounds.minY + fullCoordinate[1] / scaleY]
    }

    /// The token hashes the whole observation, so in a live window (a new message, a counter, a
    /// caret blink) it is stale before the action arrives. What an action depends on is narrower.
    private func survivesChange(name: String, target: ComputerUseNativeHostTarget, expected: String, fresh: String,
                                arguments: [String: Any]) -> Bool {
        switch name {
        case "click_element", "set_value":
            switch NativeElementSelector.parse(arguments).selector {
            case .roleLabel:
                // Found again on the current tree, where it must still be the only match.
                return true
            case .id(let id):
                guard let index = NativeElementID.index(id) else { return false }
                if case .found = NativeSnapshotStore.shared.resolve(target: target, index: index, token: expected,
                                                                    identity: NativePlatform.identity(of:)) { return true }
                return false
            case nil:
                // Let the tool name what is wrong with the selector instead of calling it stale.
                return true
            }
        case "left_click", "right_click", "mouse_move", "scroll":
            // Coordinates depend on the frame they were read from, not on what was drawn in it.
            guard let before = Self.decodePixelToken(expected), let now = Self.decodePixelToken(fresh) else { return false }
            return before.scope == now.scope && before.windowBounds == now.windowBounds
        default:
            return false
        }
    }

    private static func isBooleanNumber(_ value: Any?) -> Bool {
        if value is Bool { return true }
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    private static func pixelRegion(_ value: Any?) -> CGRect? {
        let values: [Any]
        if let value = value as? [Any] {
            values = value
        } else if let value = value as? [Double] {
            values = value
        } else if let value = value as? [NSNumber] {
            values = value
        } else {
            return nil
        }
        guard values.count == 4,
              let x = exactPixelInteger(values[0]),
              let y = exactPixelInteger(values[1]),
              let width = exactPixelInteger(values[2]),
              let height = exactPixelInteger(values[3]),
              x >= 0, y >= 0, width > 0, height > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func applyPixelRegion(
        _ capture: ComputerUseNativeCapture,
        region: CGRect?
    ) -> (capture: ComputerUseNativeCapture, fullImageSize: [Int])? {
        guard let fullImageSize = capture.sourcePixelSize ?? imageSize(capture: capture) else {
            return nil
        }
        guard let region else {
            return (capture, fullImageSize)
        }
        if isNativeCroppedCapture(capture, region: region, fullImageSize: fullImageSize) {
            return (capture, fullImageSize)
        }
        guard let cropped = crop(capture: capture, region: region) else {
            return nil
        }
        return (cropped, fullImageSize)
    }

    private static func isNativeCroppedCapture(
        _ capture: ComputerUseNativeCapture,
        region: CGRect,
        fullImageSize: [Int]
    ) -> Bool {
        guard capture.sourcePixelSize != nil,
              fullImageSize.count == 2,
              region.origin.x >= 0,
              region.origin.y >= 0,
              region.width > 0,
              region.height > 0,
              region.maxX <= CGFloat(fullImageSize[0]),
              region.maxY <= CGFloat(fullImageSize[1]),
              let data = decodedCaptureData(capture),
              let encodedSize = pngHeaderPixelSize(data),
              encodedSize == [Int(region.width), Int(region.height)] else {
            return false
        }
        return true
    }

    private static func crop(
        capture: ComputerUseNativeCapture,
        region: CGRect
    ) -> ComputerUseNativeCapture? {
        guard let decoded = decodedCaptureImage(capture) else { return nil }
        return encodeCroppedImage(
            decoded.image,
            region: region,
            sourcePixelSize: decoded.pixelSize
        )
    }

    private static func decodedCaptureImage(
        _ capture: ComputerUseNativeCapture
    ) -> (image: CGImage, pixelSize: [Int])? {
        guard let data = decodedCaptureData(capture),
              let representation = NSBitmapImageRep(data: data),
              let image = representation.cgImage,
              image.width > 0,
              image.height > 0 else {
            return nil
        }
        recordPNGPixelInflate(pixelCount: image.width * image.height)
        return (image, [image.width, image.height])
    }

    private static func encodeCroppedImage(
        _ image: CGImage,
        region: CGRect,
        sourcePixelSize: [Int]
    ) -> ComputerUseNativeCapture? {
        guard region.maxX <= CGFloat(image.width),
              region.maxY <= CGFloat(image.height),
              let cropped = image.cropping(to: CGRect(
                  x: region.origin.x,
                  y: region.origin.y,
                  width: region.width,
                  height: region.height
              )),
              case .success(let encoded) = encodePNGCapture(
                cropped,
                sourcePixelSize: sourcePixelSize
              ) else {
            return nil
        }
        return encoded
    }

    /// The frame drawn into at most `limit` pixels on its long edge.
    static func scaled(_ image: CGImage, limit: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard limit > 0, longEdge > limit else { return nil }
        let ratio = Double(limit) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * ratio).rounded())), height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func encodePreparedCapture(
        image: CGImage,
        region: CGRect?,
        maxDimension: Int = 0
    ) -> ComputerUseNativeCaptureResult {
        guard image.width > 0,
              image.height > 0,
              image.width <= maximumCapturePixelDimension,
              image.height <= maximumCapturePixelDimension,
              image.height <= maximumCapturePixelCount / image.width else {
            return .unavailable("capture_too_large")
        }
        let sourcePixelSize = [image.width, image.height]
        let output: CGImage
        if let region {
            guard region.origin.x >= 0,
                  region.origin.y >= 0,
                  region.width > 0,
                  region.height > 0,
                  region.maxX <= CGFloat(image.width),
                  region.maxY <= CGFloat(image.height),
                  let cropped = image.cropping(to: CGRect(
                      x: region.origin.x,
                      y: region.origin.y,
                      width: region.width,
                      height: region.height
                  )) else {
                return .unavailable("invalid_region")
            }
            output = cropped
        } else {
            output = scaled(image, limit: maxDimension) ?? image
        }
        return encodePNGCapture(output, sourcePixelSize: sourcePixelSize, scaledDown: region == nil && output !== image)
    }

    private static func encodePNGCapture(
        _ image: CGImage,
        sourcePixelSize: [Int],
        scaledDown: Bool = false
    ) -> ComputerUseNativeCaptureResult {
        guard let data = NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]) else {
            return .unavailable("png_encoding_failed")
        }
        guard data.count <= maximumCaptureEncodedBytes else {
            return .unavailable("capture_too_large")
        }
        return .success(ComputerUseNativeCapture(
            data: data.base64EncodedString(),
            mimeType: "image/png",
            sourcePixelSize: sourcePixelSize,
            outputPixelSize: scaledDown ? [image.width, image.height] : nil
        ))
    }

    private static func imageSize(capture: ComputerUseNativeCapture) -> [Int]? {
        if let size = capture.sourcePixelSize,
           size.count == 2,
           size[0] > 0,
           size[1] > 0 {
            return size
        }
        guard let data = decodedCaptureData(capture) else { return nil }
        return pngHeaderPixelSize(data)
    }

    private static func captureDataExceedsBudget(_ capture: ComputerUseNativeCapture) -> Bool {
        guard capture.data.utf8.count <= maximumCaptureBase64Characters,
              let data = Data(base64Encoded: capture.data),
              data.count <= maximumCaptureEncodedBytes else {
            return true
        }
        return encodedImageDimensionsExceedBudget(data)
    }

    private static func decodedCaptureData(_ capture: ComputerUseNativeCapture) -> Data? {
        guard capture.data.utf8.count <= maximumCaptureBase64Characters,
              let data = Data(base64Encoded: capture.data),
              data.count <= maximumCaptureEncodedBytes,
              !encodedImageDimensionsExceedBudget(data) else {
            return nil
        }
        return data
    }

    private static func pngIHDRDimensions(_ data: Data) -> (width: UInt32, height: UInt32)? {
        let pngSignature: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ]
        guard data.count >= 24,
              data.prefix(pngSignature.count).elementsEqual(pngSignature) else {
            return nil
        }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (width, height)
    }

    private static func pngHeaderPixelSize(_ data: Data) -> [Int]? {
        guard let dimensions = pngIHDRDimensions(data),
              dimensions.width > 0,
              dimensions.height > 0 else {
            return nil
        }
        return [Int(dimensions.width), Int(dimensions.height)]
    }

    private static func encodedImageDimensionsExceedBudget(_ data: Data) -> Bool {
        guard let dimensions = pngIHDRDimensions(data) else {
            return false
        }
        guard dimensions.width > 0, dimensions.height > 0 else { return true }
        return dimensions.width > UInt32(maximumCapturePixelDimension)
            || dimensions.height > UInt32(maximumCapturePixelDimension)
            || UInt64(dimensions.height) > UInt64(maximumCapturePixelCount) / UInt64(dimensions.width)
    }

    private static func cursorPosition() -> String {
        let point = NSEvent.mouseLocation
        return "(\(point.x),\(point.y))"
    }

    public enum NativePlatform {
        private enum CaptureImageFailure: Error, CustomStringConvertible {
            case screenshotManager(domain: String, code: Int, description: String)
            case quartzFallback(String)

            var allowsQuartzFallback: Bool {
                switch self {
                case .screenshotManager(let domain, let code, _):
                    return NativePlatform.allowsQuartzFallback(domain: domain, code: code)
                case .quartzFallback:
                    return false
                }
            }

            var description: String {
                switch self {
                case .screenshotManager(_, _, let value):
                    return value
                case .quartzFallback(let value):
                    return value
                }
            }
        }

        static let timeoutDomain = "RemoteCode.capture-timeout"

        static func allowsQuartzFallback(domain: String, code: Int) -> Bool {
            (domain == SCStreamErrorDomain && code == -3811) || domain == timeoutDomain
        }

        struct QuartzWindowSnapshot: Equatable {
            let pid: Int32
            let windowID: UInt32
            let isOnScreen: Bool
            let bounds: CGRect

            init(pid: Int32, windowID: UInt32, isOnScreen: Bool, bounds: CGRect) {
                self.pid = pid
                self.windowID = windowID
                self.isOnScreen = isOnScreen
                self.bounds = bounds
            }
        }

        private typealias QuartzWindowImageFunction = @convention(c) (
            CGRect,
            CGWindowListOption,
            CGWindowID,
            CGWindowImageOption
        ) -> CGImage?

        private static let quartzWindowImageFunction: QuartzWindowImageFunction? = {
            guard let symbol = dlsym(
                UnsafeMutableRawPointer(bitPattern: -2),
                "CGWindowListCreateImage"
            ) else {
                return nil
            }
            return unsafeBitCast(symbol, to: QuartzWindowImageFunction.self)
        }()

        public static func listWindows(bundleID: String?) -> [ComputerUseNativeWindow] {
            let infos = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
            var axFrames: [Int32: [CGRect]] = [:]
            func hasAXWindow(pid: Int32, bounds: CGRect) -> Bool {
                if axFrames[pid] == nil {
                    let app = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(app, 0.5)
                    let windows = attribute(kAXWindowsAttribute as CFString, from: app)
                        .flatMap(axElements(from:)) ?? []
                    axFrames[pid] = windows.compactMap(frame(of:))
                }
                return axFrames[pid]!.contains { framesEqual($0, bounds) }
            }
            return infos.compactMap { info in
                guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      pid > 0,
                      number > 0 else {
                    return nil
                }
                let app = NSRunningApplication(processIdentifier: pid)
                if let bundleID, app?.bundleIdentifier != bundleID { return nil }
                let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
                let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
                // Off-screen untitled Quartz surfaces without an AX window (e.g. SwiftUI menu-bar
                // helpers) are not minimized windows; listing them as such misleads agents.
                if !isOnScreen, (info[kCGWindowName as String] as? String ?? "").isEmpty,
                   !hasAXWindow(pid: pid, bounds: bounds) { return nil }
                return ComputerUseNativeWindow(
                    target: .init(pid: pid, windowID: number),
                    title: info[kCGWindowName as String] as? String ?? "",
                    bundleIdentifier: app?.bundleIdentifier,
                    isOnScreen: isOnScreen,
                    isMinimized: !isOnScreen,
                    bounds: bounds
                )
            }
        }

        public static func accessibilityPermission() -> Bool {
            AXIsProcessTrusted()
        }

        public static func axTargetAvailable(target: ComputerUseNativeHostTarget) -> Bool {
            AXIsProcessTrusted() && exactAXWindow(target: target) != nil
        }

        public static func restoreWindow(target: ComputerUseNativeHostTarget) -> Bool {
            guard AXIsProcessTrusted(),
                  let window = exactAXWindow(target: target),
                  let app = NSRunningApplication(processIdentifier: target.pid) else { return false }
            var minimizedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
                  let wasMinimized = minimizedValue as? NSNumber else { return false }
            return NativeWindowRestoreSequence.run(
                wasMinimized: wasMinimized.boolValue,
                unminimize: {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
                },
                focusExactWindow: {
                    AXUIElementSetAttributeValue(
                        AXUIElementCreateApplication(target.pid),
                        kAXFocusedWindowAttribute as CFString,
                        window
                    ) == .success
                },
                activateApp: { app.activate(options: []) },
                rollbackMinimized: {
                    _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            )
        }

        static func quartzTitleUniquelyIdentifiesTarget(
            _ title: String?,
            target: ComputerUseNativeHostTarget,
            windows: [ComputerUseNativeWindow]
        ) -> Bool {
            guard let title, !title.isEmpty else { return false }
            let matches = windows.filter { $0.target.pid == target.pid && $0.title == title }
            return matches.count == 1 && matches[0].target == target
        }

        public static func screenCapturePermission() -> Bool {
            CGPreflightScreenCaptureAccess()
        }

        /// First ancestor executable that lives inside an `.app` bundle (the
        /// TCC-responsible app for this helper), else the top-most non-launchd
        /// ancestor. Walks the ppid chain via sysctl; never touches TCC.
        public static func hostLauncherExecutablePath(startingAt pid: pid_t = getpid()) -> String? {
            var current = parentPID(of: pid)
            var fallback: String?
            var hops = 0
            while current > 1, hops < 32 {
                hops += 1
                if let path = executablePath(of: current) {
                    if path.contains(".app/Contents/MacOS/") { return path }
                    fallback = path
                }
                current = parentPID(of: current)
            }
            return fallback
        }

        static func parentPID(of pid: pid_t) -> pid_t {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return 0 }
            return info.kp_eproc.e_ppid
        }

        static func executablePath(of pid: pid_t) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { return nil }
            return String(cString: buffer)
        }

        private static let activityMonitor = ComputerUseNativeActivityMonitor()

        /// A global NSEvent monitor is delivered on AppKit's run loop and can
        /// stop observing while the stdio host is blocked. Keep the native tap
        /// on its own thread/run loop instead. A listen-only tap never changes
        /// the event stream and the source-user-data tag remains fail-closed.
        private final class ActivityTap: @unchecked Sendable {
            private let monitor: ComputerUseNativeActivityMonitor
            private let lock = NSLock()
            private var started = false
            private var available = false
            private var armedAtNanoseconds: UInt64?
            private var shouldStop = false
            private var runLoop: CFRunLoop?
            private var tap: CFMachPort?
            private var readiness: DispatchGroup?

            init(monitor: ComputerUseNativeActivityMonitor) {
                self.monitor = monitor
            }

            deinit {
                stop()
            }

            func start() -> Bool {
                lock.lock()
                if started {
                    let readiness = self.readiness
                    lock.unlock()
                    readiness?.wait()
                    return isReadyForMutation
                }
                started = true
                let ready = DispatchGroup()
                ready.enter()
                readiness = ready
                let thread = Thread { [weak self] in
                    self?.run(ready: ready)
                }
                thread.name = "RemoteCode.ComputerUseActivityTap"
                thread.start()
                lock.unlock()
                ready.wait()
                return isReadyForMutation
            }

            /// The tap must observe 2s of input before it can vouch for no recent human
            /// activity; wait out the remainder (outside the lock) instead of failing.
            private var isReadyForMutation: Bool {
                lock.lock()
                let armed = available ? armedAtNanoseconds : nil
                lock.unlock()
                guard let armed else { return false }
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = now >= armed ? now - armed : 0
                if elapsed < 2_000_000_000 { usleep(useconds_t((2_000_000_000 - elapsed) / 1_000)) }
                return true
            }

            func stop() {
                lock.lock()
                shouldStop = true
                let loop = runLoop
                let currentTap = tap
                tap = nil
                lock.unlock()
                if let loop {
                    CFRunLoopStop(loop)
                }
                if let currentTap {
                    CGEvent.tapEnable(tap: currentTap, enable: false)
                }
            }

            private func run(ready: DispatchGroup) {
                let mask = NativePlatform.activityEventMask
                let context = Unmanaged.passUnretained(self).toOpaque()
                guard let eventTap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: mask,
                    callback: Self.eventTapCallback,
                    userInfo: context
                ) else {
                    lock.lock()
                    available = false
                    lock.unlock()
                    ready.leave()
                    return
                }

                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
                let loop = CFRunLoopGetCurrent()
                lock.lock()
                tap = eventTap
                runLoop = loop
                let stopImmediately = shouldStop
                lock.unlock()
                guard let source, !stopImmediately else {
                    ready.leave()
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                    return
                }
                CFRunLoopAddSource(loop, source, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
                lock.lock()
                available = true
                armedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
                lock.unlock()
                ready.leave()
                CFRunLoopRun()
                CFRunLoopRemoveSource(loop, source, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: false)
                lock.lock()
                tap = nil
                runLoop = nil
                available = false
                lock.unlock()
            }

            private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<ActivityTap>.fromOpaque(refcon).takeUnretainedValue()
                tap.record(type: type, event: event)
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    tap.lock.lock()
                    let currentTap = tap.tap
                    tap.lock.unlock()
                    if let currentTap {
                        CGEvent.tapEnable(tap: currentTap, enable: true)
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            private func record(type: CGEventType, event: CGEvent) {
                let synthetic = event.getIntegerValueField(.eventSourceUserData)
                    == ComputerUseNativeActivityMonitor.syntheticEventUserData
                guard !synthetic else { return }
                let timestamp = DispatchTime.now().uptimeNanoseconds
                if type == .keyDown || type == .keyUp || type == .flagsChanged {
                    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                    monitor.record(.init(
                        kind: .keyboard,
                        pid: pid,
                        timestampNanoseconds: timestamp
                    ))
                } else if let target = NativePlatform.windowUnderPointer(event.location) {
                    monitor.record(.init(
                        kind: .mouse,
                        pid: target.pid,
                        windowID: target.windowID,
                        timestampNanoseconds: timestamp
                    ))
                }
            }
        }

        private static let activityTap = ActivityTap(monitor: activityMonitor)

        // A held drag keeps the user in control even after the initial mouse
        // down has aged out of the quiet window.
        static let activityEventMask: CGEventMask = [
            CGEventType.keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        ].reduce(0) { $0 | CGEventMask(1 << $1.rawValue) }

        public static func userActivity(target: ComputerUseNativeHostTarget) -> ComputerUseNativeUserActivity {
            _ = activityTap.start()
            return activityMonitor.activity(for: target)
        }

        public static func activityMonitoringAvailable() -> Bool {
            activityTap.start()
        }

        public static func capture(target: ComputerUseNativeHostTarget) async -> ComputerUseNativeCaptureResult {
            let limit = CaptureZoomContext.maxDimension
            if screenCaptureStalled() {
                return encodeQuartz(target: target, region: CaptureZoomContext.region, maxDimension: limit, after: .quartzFallback("screen_capture_stalled_retry_later"))
            }
            let region = CaptureZoomContext.region
            guard let result = await withDeadline(seconds: captureTotalTimeoutSeconds, {
                await capture(target: target, region: region, maxDimension: limit)
            }) else {
                markScreenCaptureStalled()
                return encodeQuartz(target: target, region: region, maxDimension: limit, after: .quartzFallback("screen_capture_timeout"))
            }
            return result
        }

        static func capture(
            target: ComputerUseNativeHostTarget,
            region: CGRect?,
            maxDimension: Int = 0
        ) async -> ComputerUseNativeCaptureResult {
            guard let content = await shareableContent() else {
                return encodeQuartz(target: target, region: region, maxDimension: maxDimension, after: .quartzFallback("shareable_content_unavailable"))
            }
            guard let window = content.windows.first(where: {
                $0.windowID == CGWindowID(target.windowID)
                    && $0.owningApplication?.processID == target.pid
            }) else {
                return .unavailable("target_window_unavailable")
            }
            guard window.isOnScreen else {
                return .unavailable("target_window_off_screen")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scaledWidth = filter.contentRect.width * CGFloat(filter.pointPixelScale)
            let scaledHeight = filter.contentRect.height * CGFloat(filter.pointPixelScale)
            guard scaledWidth.isFinite,
                  scaledHeight.isFinite,
                  scaledWidth > 0,
                  scaledHeight > 0,
                  scaledWidth <= CGFloat(ComputerUseNativeHostBackend.maximumCapturePixelDimension),
                  scaledHeight <= CGFloat(ComputerUseNativeHostBackend.maximumCapturePixelDimension) else {
                return .unavailable("capture_too_large")
            }
            let width = Int(scaledWidth)
            let height = Int(scaledHeight)
            guard width > 0, height > 0 else {
                return .unavailable("target_window_empty_content_rect")
            }
            guard height <= ComputerUseNativeHostBackend.maximumCapturePixelCount / width else {
                return .unavailable("capture_too_large")
            }
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = false
            let imageResult: Result<CGImage, CaptureImageFailure>
            let usedQuartzFallback: Bool
            switch await captureImage(filter: filter, configuration: configuration) {
            case .success(let image):
                imageResult = .success(image)
                usedQuartzFallback = false
            case .failure(let reason) where reason.allowsQuartzFallback:
                imageResult = quartzWindowImage(target: target, after: reason)
                usedQuartzFallback = true
            case .failure(let reason):
                return .unavailable(reason.description)
            }
            switch imageResult {
            case .success(let image):
                switch ComputerUseNativeHostBackend.encodePreparedCapture(
                    image: image,
                    region: region,
                    maxDimension: maxDimension
                ) {
                case .success(let capture):
                    return usedQuartzFallback ? .quartzFallback(capture) : .success(capture)
                case .quartzFallback(let capture):
                    return .quartzFallback(capture)
                case .unavailable(let reason):
                    return .unavailable(reason)
                }
            case .failure(let reason):
                return .unavailable(reason.description)
            }
        }

        private static func encodeQuartz(
            target: ComputerUseNativeHostTarget,
            region: CGRect?,
            maxDimension: Int = 0,
            after reason: CaptureImageFailure
        ) -> ComputerUseNativeCaptureResult {
            switch quartzWindowImage(target: target, after: reason) {
            case .success(let image):
                switch ComputerUseNativeHostBackend.encodePreparedCapture(image: image, region: region, maxDimension: maxDimension) {
                case .success(let capture), .quartzFallback(let capture):
                    return .quartzFallback(capture)
                case .unavailable(let failure):
                    return .unavailable(failure)
                }
            case .failure(let failure):
                return .unavailable(failure.description)
            }
        }

        // replayd/WindowServer can stop answering one client indefinitely; fail
        // fast for a while instead of paying the full timeout on every call.
        static let captureTotalTimeoutSeconds = 12.0
        static let screenCaptureRetrySeconds = 30.0
        private static let stallLock = NSLock()
        private static var stalledUntil = Date.distantPast

        static func markScreenCaptureStalled() {
            stallLock.lock()
            stalledUntil = Date().addingTimeInterval(screenCaptureRetrySeconds)
            stallLock.unlock()
        }

        static func screenCaptureStalled() -> Bool {
            stallLock.lock()
            defer { stallLock.unlock() }
            return Date() < stalledUntil
        }

        private static func quartzWindowImage(
            target: ComputerUseNativeHostTarget,
            after screenCaptureFailure: CaptureImageFailure
        ) -> Result<CGImage, CaptureImageFailure> {
            guard let before = quartzWindowSnapshot(target: target) else {
                return .failure(.quartzFallback("window_identity_or_bounds_invalid_before_\(screenCaptureFailure.description)"))
            }
            guard let imageFunction = quartzWindowImageFunction else {
                let reason = quartzFallbackValidationFailure(
                    target: target,
                    before: before,
                    symbolAvailable: false,
                    imageSize: nil,
                    after: nil
                ) ?? "quartz_fallback_symbol_unavailable"
                return .failure(.quartzFallback("\(reason)_after_\(screenCaptureFailure.description)"))
            }
            guard let image = imageFunction(
                .null,
                [.optionIncludingWindow],
                CGWindowID(target.windowID),
                [.boundsIgnoreFraming, .bestResolution]
            ) else {
                let reason = quartzFallbackValidationFailure(
                    target: target,
                    before: before,
                    symbolAvailable: true,
                    imageSize: nil,
                    after: nil
                ) ?? "quartz_fallback_image_unavailable"
                return .failure(.quartzFallback("\(reason)_after_\(screenCaptureFailure.description)"))
            }
            let after = quartzWindowSnapshot(target: target)
            if let reason = quartzFallbackValidationFailure(
                target: target,
                before: before,
                symbolAvailable: true,
                imageSize: .init(width: image.width, height: image.height),
                after: after
            ) {
                return .failure(.quartzFallback("\(reason)_after_\(screenCaptureFailure.description)"))
            }
            return .success(image)
        }

        static func quartzFallbackValidationFailure(
            target: ComputerUseNativeHostTarget,
            before: QuartzWindowSnapshot?,
            symbolAvailable: Bool,
            imageSize: CGSize?,
            after: QuartzWindowSnapshot?
        ) -> String? {
            guard let before,
                  before.pid == target.pid,
                  before.windowID == target.windowID,
                  before.isOnScreen,
                  before.bounds.width > 0,
                  before.bounds.height > 0,
                  before.bounds.origin.x.isFinite,
                  before.bounds.origin.y.isFinite,
                  before.bounds.width.isFinite,
                  before.bounds.height.isFinite else {
                return "window_identity_or_bounds_invalid_before"
            }
            guard symbolAvailable else {
                return "quartz_fallback_symbol_unavailable"
            }
            guard let imageSize,
                  imageSize.width > 0,
                  imageSize.height > 0 else {
                return "quartz_fallback_image_unavailable"
            }
            guard let after, after == before else {
                return "window_identity_or_bounds_drifted_after"
            }
            return nil
        }

        private static func quartzWindowSnapshot(
            target: ComputerUseNativeHostTarget
        ) -> QuartzWindowSnapshot? {
            let windowID = CGWindowID(target.windowID)
            let infos = (CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                windowID
            ) as? [[String: Any]]) ?? []
            guard infos.count == 1,
                  let info = infos.first,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  number == target.windowID,
                  pid == target.pid,
                  (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  bounds.width > 0,
                  bounds.height > 0,
                  bounds.origin.x.isFinite,
                  bounds.origin.y.isFinite,
                  bounds.width.isFinite,
                  bounds.height.isFinite else {
                return nil
            }
            return QuartzWindowSnapshot(
                pid: pid,
                windowID: number,
                isOnScreen: true,
                bounds: bounds
            )
        }

        private final class ResumeOnce<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<T?, Never>?

            init(_ continuation: CheckedContinuation<T?, Never>) {
                self.continuation = continuation
            }

            func resume(_ value: T?) {
                lock.lock()
                let pending = continuation
                continuation = nil
                lock.unlock()
                pending?.resume(returning: value)
            }
        }

        /// ScreenCaptureKit callbacks can never fire when replayd wedges; that
        /// held the per-PID lock forever. Returns nil after `seconds` without
        /// waiting for the abandoned operation.
        static func withDeadline<T: Sendable>(
            seconds: Double,
            _ operation: @escaping @Sendable () async -> T
        ) async -> T? {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                let gate = ResumeOnce(continuation)
                let work = Task { gate.resume(await operation()) }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    work.cancel()
                    gate.resume(nil)
                }
            }
        }

        static let shareableContentTimeoutSeconds = 5.0
        static let captureImageTimeoutSeconds = 5.0

        private static func shareableContent() async -> SCShareableContent? {
            // Capture requires an on-screen window; listing only those is ~10x faster.
            let content = await withDeadline(seconds: shareableContentTimeoutSeconds) {
                try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            return content ?? nil
        }

        private static func captureImage(
            filter: SCContentFilter,
            configuration: SCStreamConfiguration
        ) async -> Result<CGImage, CaptureImageFailure> {
            do {
                let result = await withDeadline(seconds: captureImageTimeoutSeconds) {
                    do {
                        return Result<CGImage, Error>.success(try await SCScreenshotManager.captureImage(
                            contentFilter: filter,
                            configuration: configuration
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
                guard let result else {
                    return .failure(.screenshotManager(domain: timeoutDomain, code: -1, description: "screen_capture_timeout"))
                }
                return .success(try result.get())
            } catch {
                let nsError = error as NSError
                let reason = String(describing: error)
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(256)
                return .failure(.screenshotManager(
                    domain: nsError.domain,
                    code: nsError.code,
                    description: String(reason)
                ))
            }
        }

        private static func windowUnderPointer(_ point: CGPoint) -> ComputerUseNativeHostTarget? {
            let infos = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
            for info in infos {
                let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                guard alpha > 0,
                      let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: dictionary),
                      bounds.contains(point) else {
                    continue
                }
                return .init(pid: pid, windowID: windowID)
            }
            return nil
        }

        /// Wakes `NativeSettle` waiters from AXObserver callbacks on the watcher thread.
        private final class SettleSignal: @unchecked Sendable {
            private let condition = NSCondition()
            private var received = 0
            private var consumed = 0

            func notify() {
                condition.lock()
                received += 1
                condition.broadcast()
                condition.unlock()
            }

            func wait(timeout: TimeInterval) -> Bool {
                let deadline = Date().addingTimeInterval(timeout)
                condition.lock()
                defer { condition.unlock() }
                while received == consumed {
                    if !condition.wait(until: deadline) { return false }
                }
                consumed = received
                return true
            }
        }

        private static let settleNotifications: [String] = [
            kAXValueChangedNotification, kAXUIElementDestroyedNotification, kAXCreatedNotification,
            kAXFocusedUIElementChangedNotification, kAXLayoutChangedNotification,
            kAXTitleChangedNotification, kAXWindowCreatedNotification,
            kAXSelectedChildrenChangedNotification, kAXMenuOpenedNotification,
        ]

        private static let settleCallback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<SettleSignal>.fromOpaque(refcon).takeUnretainedValue().notify()
        }

        /// Registers an AXObserver on the app element (own run-loop thread) so
        /// notifications raised by the mutation are not missed.
        public static func settleWatcher(target: ComputerUseNativeHostTarget) -> NativeSettleWatcher {
            guard AXIsProcessTrusted() else { return .immediate }
            var created: AXObserver?
            guard AXObserverCreate(target.pid, settleCallback, &created) == .success,
                  let observer = created else { return .immediate }
            let signal = SettleSignal()
            let refcon = Unmanaged.passUnretained(signal).toOpaque()
            let app = AXUIElementCreateApplication(target.pid)
            var registered = 0
            for name in settleNotifications
            where AXObserverAddNotification(observer, app, name as CFString, refcon) == .success {
                registered += 1
            }
            guard registered > 0 else { return .immediate }
            let ready = DispatchSemaphore(value: 0)
            let loopBox = RunLoopBox()
            let thread = Thread {
                let loop = CFRunLoopGetCurrent()
                loopBox.loop = loop
                CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
                ready.signal()
                CFRunLoopRun()
            }
            thread.name = "RemoteCode.SettleObserver"
            thread.start()
            ready.wait()
            return NativeSettleWatcher(
                wait: {
                    NativeSettle.wait(
                        now: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
                        waitForNotification: { signal.wait(timeout: $0) }
                    )
                },
                cancel: {
                    if let loop = loopBox.loop {
                        CFRunLoopRemoveSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
                        CFRunLoopStop(loop)
                    }
                    withExtendedLifetime(signal) {}
                }
            )
        }

        private final class RunLoopBox: @unchecked Sendable {
            var loop: CFRunLoop?
        }

        /// SwiftUI apps such as Calculator return kAXErrorNoValue for unset
        /// attributes; that means "absent", not "unreadable".
        static func attributeIsAbsent(_ status: AXError) -> Bool {
            status == .attributeUnsupported || status == .noValue
        }

        private static func uniqueElement(
            in window: AXUIElement,
            role: String,
            label: String
        ) -> AXUIElement? {
            NativeSemanticTargetSearch.uniqueMatch(
                root: window,
                role: role,
                label: label,
                attributesOf: { element in
                    func readString(_ key: String) -> (value: String?, readable: Bool) {
                        var value: CFTypeRef?
                        let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
                        if attributeIsAbsent(status) { return (nil, true) }
                        guard status == .success else { return (nil, false) }
                        guard let value else { return (nil, true) }
                        guard let string = value as? String else { return (nil, false) }
                        return (string, true)
                    }
                    let role = readString(kAXRoleAttribute)
                    let title = readString(kAXTitleAttribute)
                    let description = readString(kAXDescriptionAttribute)
                    guard role.readable, title.readable, description.readable else { return nil }
                    return (role.value, title.value, description.value)
                },
                childrenOf: { element in
                    var value: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                    if attributeIsAbsent(result) { return [] }
                    guard result == .success, let value else { return nil }
                    return axElements(from: value)
                }
            )
        }

        public static func semanticAction(
            target: ComputerUseNativeHostTarget,
            role: String,
            label: String
        ) -> Bool {
            guard AXIsProcessTrusted(),
                  let window = exactAXWindow(target: target),
                  let match = uniqueElement(in: window, role: role, label: label) else { return false }
            return AXUIElementPerformAction(match, kAXPressAction as CFString) == .success
        }

        /// Depth-first element at `ax_<index>`, using the serializer's limits.
        private static func element(atIndex wanted: Int, in window: AXUIElement) -> AXUIElement? {
            var counter = 0
            var found: AXUIElement?
            func visit(_ element: AXUIElement, depth: Int) {
                guard found == nil, depth <= NativeElementID.maximumDepth,
                      counter < NativeElementID.maximumNodes else { return }
                let index = counter
                counter += 1
                if index == wanted { found = element; return }
                for child in children(of: element) { visit(child, depth: depth + 1) }
            }
            visit(window, depth: 0)
            return found
        }

        /// The element the caller was shown as `id`. Counting to position n of today's tree
        /// would land on a different control as soon as anything above it changed.
        static func element(target: ComputerUseNativeHostTarget, id: String) -> AXUIElement? {
            guard AXIsProcessTrusted(), let index = NativeElementID.index(id) else { return nil }
            switch NativeSnapshotStore.shared.resolve(target: target, index: index, token: NativeSnapshotStore.actionToken,
                                                      identity: identity(of:)) {
            case .found(let element): return element
            case .changed: return nil
            case .unknown:
                guard let window = exactAXWindow(target: target) else { return nil }
                return element(atIndex: index, in: window)
            }
        }

        public static func semanticAction(target: ComputerUseNativeHostTarget, elementID: String) -> Bool {
            guard let match = element(target: target, id: elementID) else { return false }
            return AXUIElementPerformAction(match, kAXPressAction as CFString) == .success
        }

        public static func semanticConfirm(target: ComputerUseNativeHostTarget, elementID: String) -> Bool {
            guard let match = element(target: target, id: elementID),
                  actionNames(of: match).contains(kAXConfirmAction as String) else { return false }
            return AXUIElementPerformAction(match, kAXConfirmAction as CFString) == .success
        }

        public static func isFocusedElement(target: ComputerUseNativeHostTarget, elementID: String) -> Bool {
            guard let match = element(target: target, id: elementID),
                  let focused = elementAttribute(
                    kAXFocusedUIElementAttribute as CFString,
                    from: AXUIElementCreateApplication(target.pid)
                  ) else { return false }
            return CFEqual(match, focused)
        }

        public static func setValue(
            target: ComputerUseNativeHostTarget,
            elementID: String,
            value: String,
            allowedRisks: Set<RiskCategory>? = nil
        ) -> ComputerUseNativeSetValueResult {
            guard let match = element(target: target, id: elementID) else {
                return .failed("element_id does not resolve to an element in this window")
            }
            return setValue(element: match, value: value, allowedRisks: allowedRisks)
        }

        public static func semanticConfirm(
            target: ComputerUseNativeHostTarget,
            role: String,
            label: String
        ) -> Bool {
            guard AXIsProcessTrusted(),
                  let window = exactAXWindow(target: target),
                  let match = uniqueElement(in: window, role: role, label: label),
                  actionNames(of: match).contains(kAXConfirmAction as String) else { return false }
            return AXUIElementPerformAction(match, kAXConfirmAction as CFString) == .success
        }

        public static func isFocusedElement(
            target: ComputerUseNativeHostTarget,
            role: String,
            label: String
        ) -> Bool {
            guard AXIsProcessTrusted(),
                  let window = exactAXWindow(target: target),
                  let match = uniqueElement(in: window, role: role, label: label),
                  let focused = elementAttribute(
                    kAXFocusedUIElementAttribute as CFString,
                    from: AXUIElementCreateApplication(target.pid)
                  ) else { return false }
            return CFEqual(match, focused)
        }

        static func actionNames(of element: AXUIElement) -> [String] {
            var names: CFArray?
            guard AXUIElementCopyActionNames(element, &names) == .success,
                  let actions = names as? [String] else { return [] }
            return actions
        }

        static func title(of element: AXUIElement) -> String? {
            (attribute(kAXTitleAttribute as CFString, from: element) as? String)
        }

        static func children(of element: AXUIElement) -> [AXUIElement] {
            attribute(kAXChildrenAttribute as CFString, from: element).flatMap(axElements(from:)) ?? []
        }

        /// Sets an AX value without focusing or activating the app. Pop-up
        /// buttons are opened with AXPress and the matching item is pressed.
        public static func setValue(
            target: ComputerUseNativeHostTarget,
            role: String,
            label: String,
            value: String,
            allowedRisks: Set<RiskCategory>? = nil
        ) -> ComputerUseNativeSetValueResult {
            guard AXIsProcessTrusted(),
                  let window = exactAXWindow(target: target) else { return .failed("AX window unavailable") }
            guard let element = uniqueElement(in: window, role: role, label: label) else {
                return .failed("no unique element with this role and label")
            }
            return setValue(element: element, value: value, allowedRisks: allowedRisks)
        }

        private static func setValue(
            element: AXUIElement, value: String, allowedRisks: Set<RiskCategory>?
        ) -> ComputerUseNativeSetValueResult {
            let role = attribute(kAXRoleAttribute as CFString, from: element) as? String ?? ""
            if role == "AXPopUpButton" {
                return selectPopUpItem(element, title: value, allowedRisks: allowedRisks)
            }
            let converted: CFTypeRef
            switch role {
            case "AXSlider", "AXStepper", "AXIncrementor", "AXLevelIndicator":
                guard let number = Double(value), number.isFinite else {
                    return .failed("value must be numeric for \(role)")
                }
                converted = NSNumber(value: number)
            case "AXCheckBox", "AXRadioButton", "AXSwitch":
                guard value == "0" || value == "1" else { return .failed("value must be 0 or 1 for \(role)") }
                converted = NSNumber(value: Int(value) ?? 0)
            default:
                converted = value as CFString
            }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
                  settable.boolValue else {
                return .failed("AXValue is not settable on this element")
            }
            let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, converted)
            return status == .success ? .applied : .failed("AXValue set failed (\(status.rawValue))")
        }

        private static func selectPopUpItem(
            _ popUp: AXUIElement,
            title: String,
            allowedRisks: Set<RiskCategory>?
        ) -> ComputerUseNativeSetValueResult {
            guard AXUIElementPerformAction(popUp, kAXPressAction as CFString) == .success else {
                return .failed("could not open the pop-up button")
            }
            var menu: AXUIElement?
            let deadline = Date().addingTimeInterval(1.0)
            while menu == nil, Date() < deadline {
                menu = children(of: popUp).first {
                    (attribute(kAXRoleAttribute as CFString, from: $0) as? String) == kAXMenuRole as String
                }
                if menu == nil { Thread.sleep(forTimeInterval: 0.02) }
            }
            guard let menu else { return .failed("pop-up menu did not open") }
            let items = children(of: menu).filter {
                (attribute(kAXRoleAttribute as CFString, from: $0) as? String) == kAXMenuItemRole as String
            }
            return NativeRiskGuard.selectPopUpItem(
                items: items, title: title, titleOf: { self.title(of: $0) }, allowed: allowedRisks,
                press: { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success },
                cancel: { _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString) })
        }

        /// Presses the enabled menu item carrying the chord; works while the
        /// app is in the background. MOD+A in a focused text field selects all.
        public static func menuShortcut(
            target: ComputerUseNativeHostTarget,
            chord: ComputerUseNativeMenuChord,
            allowedRisks: Set<RiskCategory>? = nil
        ) -> ComputerUseNativeMenuShortcutResult {
            guard AXIsProcessTrusted(), let window = exactAXWindow(target: target) else { return .failed }
            let app = AXUIElementCreateApplication(target.pid)
            if chord.isSelectAll, selectAllInFocusedTextField(app: app, window: window) { return .applied }
            guard let bar = elementAttribute(kAXMenuBarAttribute as CFString, from: app) else { return .failed }
            let matches = NativeMenuShortcutSearch.enabledMatches(
                root: bar,
                chord: chord,
                attributesOf: { element in
                    guard let role = attribute(kAXRoleAttribute as CFString, from: element) as? String else { return nil }
                    let enabled = (attribute(kAXEnabledAttribute as CFString, from: element) as? NSNumber)?.boolValue ?? true
                    let cmdChar = attribute(kAXMenuItemCmdCharAttribute as CFString, from: element) as? String
                    let modifiers = (attribute(kAXMenuItemCmdModifiersAttribute as CFString, from: element) as? NSNumber)?.intValue
                    return (role, enabled, cmdChar, modifiers)
                },
                childrenOf: { children(of: $0) }
            )
            return NativeRiskGuard.pressShortcutMatch(
                matches: matches, titleOf: { title(of: $0) }, allowed: allowedRisks,
                press: { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success })
        }

        private static func selectAllInFocusedTextField(app: AXUIElement, window: AXUIElement) -> Bool {
            guard let focused = elementAttribute(kAXFocusedUIElementAttribute as CFString, from: app),
                  let owner = elementAttribute(kAXWindowAttribute as CFString, from: focused),
                  sameAXWindow(owner, window),
                  let role = attribute(kAXRoleAttribute as CFString, from: focused) as? String,
                  ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role),
                  let text = attribute(kAXValueAttribute as CFString, from: focused) as? String else { return false }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(focused, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
                  settable.boolValue else { return false }
            var range = CFRange(location: 0, length: text.utf16.count)
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }

        private static let webAccessibilityLock = NSLock()
        private static var webAccessibilityPIDs: Set<Int32> = []

        /// Chromium and Electron build the accessibility tree of their pages only when asked.
        /// Without it a browser window reads as a toolbar and nothing else. `AXManualAccessibility`
        /// is the switch they provide for this; other apps reject it and are left as they are.
        static func enableWebAccessibility(target: ComputerUseNativeHostTarget, window: AXUIElement) {
            webAccessibilityLock.lock()
            let first = webAccessibilityPIDs.insert(target.pid).inserted
            if webAccessibilityPIDs.count > 64 { webAccessibilityPIDs = [target.pid] }
            webAccessibilityLock.unlock()
            let app = AXUIElementCreateApplication(target.pid)
            guard first, webAccessibilityOptIn(
                set: { AXUIElementSetAttributeValue(app, $0 as CFString, kCFBooleanTrue) },
                chromiumFamily: { isChromiumFamily(pid: target.pid) }) != nil else { return }
            // The page tree is built asynchronously; give the first read something to read.
            func populatedWebArea(_ element: AXUIElement, depth: Int) -> Bool {
                guard depth < 12 else { return false }
                let kids = children(of: element)
                if attribute(kAXRoleAttribute as CFString, from: element) as? String == "AXWebArea" { return !kids.isEmpty }
                return kids.contains { populatedWebArea($0, depth: depth + 1) }
            }
            for _ in 0..<15 where !populatedWebArea(window, depth: 0) { usleep(100_000) }
        }

        /// The attribute that was accepted, if any. `AXManualAccessibility` has no side effects.
        /// `AXEnhancedUserInterface` is what Chrome itself answers to, but it puts a native app in
        /// screen-reader mode for the rest of its life, so it is written only to Chromium-family apps.
        static func webAccessibilityOptIn(set: (String) -> AXError, chromiumFamily: () -> Bool) -> String? {
            let manual = set("AXManualAccessibility")
            if manual == .success { return "AXManualAccessibility" }
            guard manual == .attributeUnsupported, chromiumFamily() else { return nil }
            return set("AXEnhancedUserInterface") == .success ? "AXEnhancedUserInterface" : nil
        }

        /// Whether one window in front of `target` hides all of it. Windows come front to back.
        static func windowFullyCovered(target: ComputerUseNativeHostTarget, bounds: CGRect) -> Bool {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            return covered(target: target.windowID, bounds: bounds, frontToBack: windows.compactMap { info in
                guard info[kCGWindowLayer as String] as? Int == 0, let id = info[kCGWindowNumber as String] as? UInt32,
                      let raw = info[kCGWindowBounds as String], let frame = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { return nil }
                return (id, frame)
            })
        }

        static func covered(target: UInt32, bounds: CGRect, frontToBack windows: [(id: UInt32, frame: CGRect)]) -> Bool {
            for window in windows {
                if window.id == target { return false }
                if window.frame.contains(bounds) { return true }
            }
            return false
        }

        /// Chromium embedders ship the engine as "<Name> Framework.framework" beside renderer helpers.
        static func isChromiumFamily(pid: Int32, frameworks: (URL) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.appendingPathComponent("Contents/Frameworks").path)) ?? []
        }) -> Bool {
            guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
            return isChromiumFamily(frameworks: frameworks(bundle))
        }

        static func isChromiumFamily(frameworks: [String]) -> Bool {
            frameworks.contains { name in
                name.hasSuffix(" Framework.framework")
                    && ["Chrom", "Electron", "Edge", "Brave", "Vivaldi", "Opera", "Arc"].contains { name.contains($0) }
            }
        }

        public static func uiTree(target: ComputerUseNativeHostTarget) -> String? {
            guard AXIsProcessTrusted(), let window = exactAXWindow(target: target) else { return nil }
            enableWebAccessibility(target: target, window: window)
            var budget = TreeBudget()
            let tree = serialize(element: window, depth: 0, budget: &budget)
            guard JSONSerialization.isValidJSONObject(tree),
                  let data = try? JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys]),
                  let result = String(data: data, encoding: .utf8) else {
                return nil
            }
            NativeSnapshotStore.shared.publish(target: target, tree: result, elements: budget.elements, identities: budget.identities)
            return result
        }

        public static func leftClick(
            target: ComputerUseNativeHostTarget,
            coordinate: [Double]
        ) -> ComputerUseNativeClickResult {
            guard AXIsProcessTrusted(), coordinate.count == 2,
                  let targetBounds = targetBounds(target),
                  let targetWindow = exactAXWindow(target: target),
                  targetBounds.contains(CGPoint(x: coordinate[0], y: coordinate[1])) else {
                return .failed
            }
            let app = AXUIElementCreateApplication(target.pid)
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                app,
                Float(coordinate[0]),
                Float(coordinate[1]),
                &element
            ) == .success,
            let element,
            let ownerWindow = elementAttribute(kAXWindowAttribute as CFString, from: element),
            sameAXWindow(ownerWindow, targetWindow) else {
                return .noAXTarget
            }
            var actionNames: CFArray?
            guard AXUIElementCopyActionNames(element, &actionNames) == .success,
                  let actions = actionNames as? [String] else { return .failed }
            guard actions.contains(kAXPressAction as String) else { return .noAXTarget }
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? .applied : .failed
        }

        public static func focusedTarget(target: ComputerUseNativeHostTarget) -> Bool {
            guard AXIsProcessTrusted(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
                  let targetWindow = exactAXWindow(target: target),
                  let focusedWindow = elementAttribute(
                    kAXFocusedWindowAttribute as CFString,
                    from: AXUIElementCreateApplication(target.pid)
                  ) else { return false }
            return sameAXWindow(focusedWindow, targetWindow)
        }

        public static func typeText(
            target: ComputerUseNativeHostTarget,
            text: String
        ) -> Bool {
            guard AXIsProcessTrusted(), !text.isEmpty,
                  let targetWindow = exactAXWindow(target: target) else {
                return false
            }
            let app = AXUIElementCreateApplication(target.pid)
            guard let focusedWindow = elementAttribute(kAXFocusedWindowAttribute as CFString, from: app),
                  sameAXWindow(focusedWindow, targetWindow),
                  let focused = elementAttribute(kAXFocusedUIElementAttribute as CFString, from: app) else {
                return false
            }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(
                focused,
                kAXValueAttribute as CFString,
                &settable
            ) == .success, settable.boolValue else {
                return false
            }
            return AXUIElementSetAttributeValue(
                focused,
                kAXValueAttribute as CFString,
                text as CFString
            ) == .success
        }

        static func markSyntheticInput(_ event: CGEvent) {
            event.setIntegerValueField(
                .eventSourceUserData,
                value: ComputerUseNativeActivityMonitor.syntheticEventUserData
            )
        }

        public static func pixelAction(
            target: ComputerUseNativeHostTarget,
            name: String,
            coordinate: [Double]
        ) -> Bool {
            guard AXIsProcessTrusted(),
                  let source = CGEventSource(stateID: .hidSystemState) else { return false }
            if name == "key" {
                guard coordinate.count == 2,
                      coordinate[0].isFinite, coordinate[1].isFinite,
                      coordinate[0] >= 0, coordinate[0] <= Double(UInt16.max),
                      coordinate[1] >= 0, coordinate[1] <= Double(UInt32.max),
                      focusedTarget(target: target) else { return false }
                let keyCode = CGKeyCode(coordinate[0])
                let flags = CGEventFlags(rawValue: UInt64(coordinate[1]))
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
                      focusedTarget(target: target) else { return false }
                down.flags = flags
                up.flags = flags
                markSyntheticInput(down)
                markSyntheticInput(up)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                return true
            }
            guard ["left_click", "right_click", "mouse_move", "scroll"].contains(name),
                  coordinate.count == (name == "scroll" ? 4 : 2),
                  coordinate.allSatisfy(\.isFinite),
                  let window = listWindows(bundleID: nil).first(where: { $0.target == target }),
                  window.isOnScreen, !window.isMinimized,
                  let x = coordinate.first, let y = coordinate.dropFirst().first,
                  window.bounds.contains(CGPoint(x: x, y: y)),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
                  focusedTarget(target: target),
                  windowUnderPointer(CGPoint(x: x, y: y)) == target else { return false }
            let point = CGPoint(x: x, y: y)
            if name == "mouse_move" {
                guard focusedTarget(target: target), windowUnderPointer(point) == target,
                      let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                          mouseCursorPosition: point, mouseButton: .left) else { return false }
                markSyntheticInput(event)
                event.post(tap: .cghidEventTap)
                return true
            }
            if name == "scroll" {
                guard abs(coordinate[2]) <= 10_000, abs(coordinate[3]) <= 10_000,
                      let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                          wheel1: Int32(coordinate[3]), wheel2: Int32(coordinate[2]), wheel3: 0) else { return false }
                guard focusedTarget(target: target), windowUnderPointer(point) == target else { return false }
                event.location = point
                markSyntheticInput(event)
                event.post(tap: .cghidEventTap)
                return true
            }
            let right = name == "right_click"
            let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
            let upType: CGEventType = right ? .rightMouseUp : .leftMouseUp
            let button: CGMouseButton = right ? .right : .left
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                     mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType,
                                   mouseCursorPosition: point, mouseButton: button),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
                  focusedTarget(target: target),
                  windowUnderPointer(point) == target else { return false }
            markSyntheticInput(down)
            markSyntheticInput(up)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }

        static func attribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
            return value
        }

        private static func elementAttribute(_ key: CFString, from element: AXUIElement) -> AXUIElement? {
            guard let value = attribute(key, from: element) else { return nil }
            return axElement(from: value)
        }

        private static func valueAttribute(_ key: CFString, from element: AXUIElement) -> AXValue? {
            guard let value = attribute(key, from: element) else { return nil }
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            let pointer = Unmanaged.passUnretained(value).toOpaque()
            return Unmanaged<AXValue>.fromOpaque(pointer).takeUnretainedValue()
        }

        static func exactAXWindow(target: ComputerUseNativeHostTarget) -> AXUIElement? {
            let quartzWindows = listWindows(bundleID: nil)
            guard let targetQuartzWindow = quartzWindows.first(where: { $0.target == target }) else {
                return nil
            }
            let bounds = targetQuartzWindow.bounds
            let targetTitle: String? = targetQuartzWindow.title
            let app = AXUIElementCreateApplication(target.pid)
            guard let windows = attribute(kAXWindowsAttribute as CFString, from: app)
                    .flatMap(axElements(from:)) else { return nil }
            let frameMatches = windows.filter { matches($0, bounds: bounds) }
            if frameMatches.count == 1 { return frameMatches[0] }

            // Multiple AX windows can report the same frame (for example a
            // sheet and its owner). A frame alone is not an exact identity;
            // use the Quartz title only when it disambiguates exactly one
            // candidate, and otherwise fail closed.
            guard let title = targetTitle, !title.isEmpty else { return nil }
            guard quartzTitleUniquelyIdentifiesTarget(title, target: target, windows: quartzWindows) else {
                return nil
            }
            let titleMatches = frameMatches.filter {
                (attribute(kAXTitleAttribute as CFString, from: $0) as? String) == title
            }
            if titleMatches.count == 1 { return titleMatches[0] }

            // Some macOS 26 targets expose AXWindows but temporarily reject
            // AXPosition/AXSize while the display is asleep. A unique title
            // is still an exact, non-activating identity; ambiguity remains
            // fail-closed rather than selecting the first element.
            guard frameMatches.isEmpty else { return nil }
            let titleOnlyMatches = windows.filter {
                (attribute(kAXTitleAttribute as CFString, from: $0) as? String) == title
            }
            return titleOnlyMatches.count == 1 ? titleOnlyMatches[0] : nil
        }

        static func axElements(from value: CFTypeRef) -> [AXUIElement]? {
            guard CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
            let array = value as! CFArray
            var elements: [AXUIElement] = []
            elements.reserveCapacity(CFArrayGetCount(array))
            for index in 0..<CFArrayGetCount(array) {
                guard let raw = CFArrayGetValueAtIndex(array, index) else {
                    return nil
                }
                let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
                guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
                let element = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
                elements.append(element)
            }
            return elements
        }

        static func axElement(from value: CFTypeRef) -> AXUIElement? {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            let pointer = Unmanaged.passUnretained(value).toOpaque()
            return Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
        }

        private static func sameAXWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
            CFEqual(lhs, rhs)
        }

        private static func targetBounds(_ target: ComputerUseNativeHostTarget) -> CGRect? {
            listWindows(bundleID: nil).first { $0.target == target }?.bounds
        }

        private static func matches(_ element: AXUIElement, bounds: CGRect) -> Bool {
            guard let elementFrame = frame(of: element) else { return false }
            return framesEqual(elementFrame, bounds)
        }

        private static func frame(of element: AXUIElement) -> CGRect? {
            guard let position = valueAttribute(kAXPositionAttribute as CFString, from: element),
                  let size = valueAttribute(kAXSizeAttribute as CFString, from: element) else {
                return nil
            }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position, .cgPoint, &origin),
                  AXValueGetValue(size, .cgSize, &dimensions) else {
                return nil
            }
            return CGRect(origin: origin, size: dimensions)
        }

        private static func framesEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.origin.x - rhs.origin.x) < 1
                && abs(lhs.origin.y - rhs.origin.y) < 1
                && abs(lhs.size.width - rhs.size.width) < 1
                && abs(lhs.size.height - rhs.size.height) < 1
        }

        private struct TreeBudget {
            var nodes = 0
            var elements: [AXUIElement] = []
            var identities: [NativeSnapshotStore.Identity] = []
        }

        /// The attributes a caller recognizes a control by. Values and layout are left out:
        /// they change while the control stays the same control.
        static func identity(of element: AXUIElement) -> NativeSnapshotStore.Identity? {
            guard let role = attribute(kAXRoleAttribute as CFString, from: element) as? String else { return nil }
            func text(_ name: String) -> String? {
                (attribute(name as CFString, from: element) as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            return .init(role: role, title: text(kAXTitleAttribute), description: text(kAXDescriptionAttribute),
                         identifier: text(kAXIdentifierAttribute))
        }

        private static func serialize(
            element: AXUIElement,
            depth: Int,
            budget: inout TreeBudget
        ) -> [String: Any] {
            guard depth <= NativeElementID.maximumDepth, budget.nodes < NativeElementID.maximumNodes else {
                return ["truncated": true]
            }
            var result: [String: Any] = ["id": "ax_\(budget.nodes)"]
            budget.nodes += 1
            budget.elements.append(element)
            budget.identities.append(identity(of: element) ?? .init())
            if let role = attribute(kAXRoleAttribute as CFString, from: element) as? String { result["role"] = role }
            if let subrole = attribute(kAXSubroleAttribute as CFString, from: element) as? String {
                result["subrole"] = subrole
            }
            if let title = attribute(kAXTitleAttribute as CFString, from: element) as? String, !title.isEmpty {
                result["title"] = title
            }
            if let description = attribute(kAXDescriptionAttribute as CFString, from: element) as? String,
               !description.isEmpty {
                result["description"] = description
            }
            if let identifier = attribute(kAXIdentifierAttribute as CFString, from: element) as? String,
               !identifier.isEmpty {
                result["identifier"] = identifier
            }
            if let raw = attribute(kAXValueAttribute as CFString, from: element) {
                if let value = raw as? String, !value.isEmpty {
                    result["value"] = String(value.prefix(200))
                } else if let number = raw as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() {
                    result["value"] = number.stringValue
                }
            }
            let actions = actionNames(of: element)
            if !actions.isEmpty { result["actions"] = actions }
            if let children = attribute(kAXChildrenAttribute as CFString, from: element)
                    .flatMap(axElements(from:)),
               !children.isEmpty {
                result["children"] = children.map { serialize(element: $0, depth: depth + 1, budget: &budget) }
            }
            return result
        }

        private static func matchingElements(
            element: AXUIElement,
            role: String,
            label: String,
            depth: Int = 0
        ) -> [AXUIElement] {
            guard depth < 32 else { return [] }
            let actualRole = attribute(kAXRoleAttribute as CFString, from: element) as? String
            let title = attribute(kAXTitleAttribute as CFString, from: element) as? String
            let description = attribute(kAXDescriptionAttribute as CFString, from: element) as? String
            var matches: [AXUIElement] = []
            if actualRole == role && (title == label || description == label) {
                matches.append(element)
            }
            guard let children = attribute(kAXChildrenAttribute as CFString, from: element)
                    .flatMap(axElements(from:)) else {
                return matches
            }
            for child in children {
                matches.append(contentsOf: matchingElements(
                    element: child,
                    role: role,
                    label: label,
                    depth: depth + 1
                ))
                if matches.count > 1 { return matches }
            }
            return matches
        }
    }
}
