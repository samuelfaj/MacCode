import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

public final class DesktopToolsBackend: ComputerUseToolBackend, @unchecked Sendable {
    public static let observationTools = ["list_apps", "get_accessibility_tree", "get_desktop_state", "get_screen_size", "clipboard_read", "check_permissions", "health_report", "get_config"]
    public static let mutationTools = ["launch_app", "kill_app", "bring_to_front", "set_window_frame", "clipboard_write", "set_config"]
    private static let configLock = NSLock()
    private let configURL: URL

    public convenience init() {
        self.init(configURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mac-use/config.json"))
    }

    public init(configURL: URL) { self.configURL = configURL }

    public static func maxImageDimension() -> Int {
        (try? DesktopToolsBackend().readConfig()["max_image_dimension"] as? Int) ?? 0
    }

    /// Window screenshots are always bounded: the configured limit, or the default when none is set.
    public static func windowImageDimension() -> Int {
        let configured = maxImageDimension()
        return configured > 0 ? configured : ComputerUseNativeHostBackend.defaultMaxImageDimension
    }

    public static func description(for name: String) -> String? {
        switch name {
        case "list_apps": return "List running and installed applications, including PID, bundle identity and active state."
        case "launch_app": return "Launch an application in background by bundle_id or name, restoring prior focus if needed."
        case "kill_app": return "Force terminate an application by PID, with SIGKILL fallback."
        case "bring_to_front": return "Activate an application and optionally raise its exact window. Leaves it frontmost."
        case "get_accessibility_tree": return "Describe regular running applications and on-screen windows with bounds and front-to-back z-order."
        case "get_desktop_state": return "Capture the complete main display as a PNG image, respecting max_image_dimension."
        case "get_screen_size": return "Return main display size in logical points and backing scale factor."
        case "set_window_frame": return "Set an exact window's position and size using Accessibility and verify by readback."
        case "clipboard_read": return "List clipboard types; include text only when include_text is true."
        case "clipboard_write": return "Replace clipboard with exactly one of text, image_path or file_path. Paths must be absolute and contain no symlinks."
        case "check_permissions": return "Check Accessibility and Screen Recording permissions; prompt only when requested."
        case "health_report": return "Report permissions, activity monitor availability, cua CLI, version and whether the Chrome extension is installed, connected and current (a probe bounded to 2 seconds)."
        case "get_config": return "Read persisted desktop configuration; max_image_dimension zero means no resize."
        case "set_config": return "Persist max_image_dimension, a nonnegative integer, in ~/.mac-use/config.json."
        default: return nil
        }
    }

    public static func inputSchema(for name: String) -> [String: Any]? {
        guard description(for: name) != nil else { return nil }
        let string: [String: Any] = ["type": "string"]
        let boolean: [String: Any] = ["type": "boolean", "default": false]
        let pid: [String: Any] = ["type": "integer", "minimum": 1, "maximum": Int(Int32.max)]
        let window: [String: Any] = ["type": "integer", "minimum": 1, "maximum": Int(UInt32.max)]
        var properties: [String: Any] = [:]
        var required: [String] = []
        switch name {
        case "launch_app":
            properties = ["bundle_id": string, "name": string, "urls": ["type": "array", "items": string], "additional_arguments": ["type": "array", "items": string], "creates_new_application_instance": boolean]
        case "kill_app", "bring_to_front", "set_window_frame":
            properties["pid"] = pid
            required = ["pid"]
            if name != "kill_app" { properties["window_id"] = window }
            if name == "set_window_frame" {
                required += ["window_id", "x", "y", "width", "height"]
                for key in ["x", "y", "width", "height"] { properties[key] = ["type": "number"] }
                properties["width"] = ["type": "number", "exclusiveMinimum": 0]
                properties["height"] = ["type": "number", "exclusiveMinimum": 0]
            }
        case "clipboard_read": properties["include_text"] = boolean
        case "clipboard_write": properties = ["text": string, "image_path": string, "file_path": string]
        case "check_permissions": properties["prompt"] = boolean
        case "set_config":
            properties["max_image_dimension"] = ["type": "integer", "minimum": 0]
            required = ["max_image_dimension"]
        default: break
        }
        if ["launch_app", "kill_app", "bring_to_front", "set_window_frame", "clipboard_write"].contains(name) {
            properties["allow_while_user_active"] = ChromeProfileComputerUseBackend.allowWhileUserActive
        }
        var schema: [String: Any] = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        if name == "launch_app" { schema["oneOf"] = [["required": ["bundle_id"]], ["required": ["name"]]] }
        if name == "clipboard_write" { schema["oneOf"] = ["text", "image_path", "file_path"].map { ["required": [$0]] } }
        return schema
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    static func validationError(name: String, arguments: [String: Any]) -> String? {
        guard let schema = inputSchema(for: name), let properties = schema["properties"] as? [String: [String: Any]] else { return "unknown_tool" }
        for key in arguments.keys where properties[key] == nil { return "Unknown argument: \(key)" }
        for key in schema["required"] as? [String] ?? [] where arguments[key] == nil { return "Missing argument: \(key)" }
        for (key, value) in arguments {
            let rule = properties[key]!
            switch rule["type"] as? String {
            case "string": if !(value is String) { return "\(key) must be a string" }
            case "boolean":
                guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return "\(key) must be a boolean" }
            case "array": if !(value is [String]) { return "\(key) must be an array of strings" }
            case "integer", "number":
                guard let number = number(value) else { return "\(key) must be a finite number" }
                if rule["type"] as? String == "integer", number.rounded() != number { return "\(key) must be an integer" }
                if let minimum = rule["minimum"] as? Int, number < Double(minimum) { return "\(key) is too small" }
                if let maximum = rule["maximum"] as? Int, number > Double(maximum) { return "\(key) is too large" }
                if rule["exclusiveMinimum"] != nil, number <= 0 { return "\(key) must be positive" }
                if key == "max_image_dimension", number >= Double(Int.max) { return "max_image_dimension is too large" }
            default: break
            }
        }
        if name == "launch_app" {
            let keys = ["bundle_id", "name"].filter { arguments[$0] != nil }
            guard keys.count == 1, let identity = arguments[keys[0]] as? String, !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Provide exactly one nonempty bundle_id or name" }
            for text in arguments["urls"] as? [String] ?? [] {
                guard let url = URL(string: text), url.scheme != nil else { return "urls must contain absolute URLs" }
            }
        }
        if name == "clipboard_write" {
            guard ["text", "image_path", "file_path"].filter({ arguments[$0] != nil }).count == 1 else { return "Provide exactly one of text, image_path or file_path" }
            for key in ["image_path", "file_path"] {
                if let path = arguments[key] as? String {
                    do { _ = try checkedPath(path) } catch { return error.localizedDescription }
                }
            }
        }
        return nil
    }

    private static func checkedPath(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw Failure(message: "Path must be absolute") }
        let url = URL(fileURLWithPath: path)
        var component = URL(fileURLWithPath: "/")
        for part in path.split(separator: "/") {
            component.appendPathComponent(String(part))
            let attributes = try FileManager.default.attributesOfItem(atPath: component.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure(message: "Symlinks are not allowed") }
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw Failure(message: "Path is not readable") }
        return url
    }

    private static func result(_ object: [String: Any], error: Bool = false) -> ComputerUseToolResult {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return ComputerUseToolResult(text: String(decoding: data, as: UTF8.self), isError: error)
        } catch { return ComputerUseToolResult(text: "{\"error\":\"json_encoding_failed\"}", isError: true) }
    }

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        if let error = Self.validationError(name: name, arguments: arguments) { return Self.result(["error": error], error: true) }
        do {
            switch name {
            case "get_config": return Self.result(try readConfig())
            case "set_config": return Self.result(try writeConfig(arguments["max_image_dimension"] as! Int))
            case "check_permissions": return Self.result(Self.permissions(prompt: arguments["prompt"] as? Bool ?? false))
            case "health_report":
                let executable = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("cua").path }.first { FileManager.default.isExecutableFile(atPath: $0) }
                return Self.result(["permissions": Self.permissions(prompt: false), "activity_monitor_available": ComputerUseNativeHostBackend.NativePlatform.activityMonitoringAvailable(), "chrome_extension": ChromeProfileConnection.extensionStatus(), "cua_cli_present": executable != nil, "cua_cli_path": executable as Any? ?? NSNull(), "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"])
            case "list_apps": return Self.result(await MainActor.run { Self.listApps() })
            case "get_accessibility_tree":
                return Self.result(await MainActor.run {
                    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                    let windows: [[String: Any]] = infos.enumerated().compactMap { index, info in
                        guard (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
                        return ["window_id": info[kCGWindowNumber as String] ?? 0, "owner_pid": info[kCGWindowOwnerPID as String] ?? 0, "title": info[kCGWindowName as String] ?? "", "bounds": info[kCGWindowBounds as String] ?? [:], "z_order": index]
                    }
                    return ["apps": NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(Self.appObject), "windows": windows]
                })
            case "get_screen_size":
                return Self.result(await MainActor.run {
                    guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }) else { return ["error": "main_display_unavailable"] }
                    return ["width": screen.frame.width, "height": screen.frame.height, "backingScaleFactor": screen.backingScaleFactor]
                })
            case "get_desktop_state":
                return await Self.boundedDesktopCapture {
                    do { return try await self.desktopScreenshot() }
                    catch { return Self.result(["error": error.localizedDescription], error: true) }
                }
            case "launch_app": return try await launch(arguments)
            case "kill_app", "bring_to_front", "set_window_frame":
                return try await MainActor.run { try Self.mutate(name: name, arguments: arguments) }
            case "clipboard_read":
                return Self.result(await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    var object: [String: Any] = ["types": pasteboard.types?.map(\.rawValue) ?? []]
                    if arguments["include_text"] as? Bool == true { object["text"] = pasteboard.string(forType: .string) as Any? ?? NSNull() }
                    return object
                })
            case "clipboard_write": return try await MainActor.run { try Self.writeClipboard(arguments) }
            default: throw Failure(message: "unknown_tool")
            }
        } catch { return Self.result(["error": error.localizedDescription], error: true) }
    }

    private func readConfig() throws -> [String: Any] {
        Self.configLock.lock()
        defer { Self.configLock.unlock() }
        return try loadConfig()
    }

    private func loadConfig() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return ["max_image_dimension": 0] }
        guard var config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] else { throw Failure(message: "Invalid config JSON") }
        let value = config["max_image_dimension"] ?? 0
        if let error = Self.validationError(name: "set_config", arguments: ["max_image_dimension": value]) { throw Failure(message: error) }
        config["max_image_dimension"] = value
        return config
    }

    private func writeConfig(_ dimension: Int) throws -> [String: Any] {
        Self.configLock.lock()
        defer { Self.configLock.unlock() }
        var config = try loadConfig()
        config["max_image_dimension"] = dimension
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
        return config
    }

    private static func permissions(prompt: Bool) -> [String: Any] {
        let accessibility = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
        var screen = CGPreflightScreenCaptureAccess()
        if prompt && !screen { screen = CGRequestScreenCaptureAccess() }
        return ["accessibility": accessibility, "screen_recording": screen]
    }

    private static func appObject(_ app: NSRunningApplication) -> [String: Any] {
        ["pid": app.processIdentifier, "bundle_id": app.bundleIdentifier as Any? ?? NSNull(), "name": app.localizedName ?? "", "running": !app.isTerminated, "active": app.isActive]
    }

    private static func listApps() -> [String: Any] {
        var apps = NSWorkspace.shared.runningApplications.map(appObject)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                enumerator.skipDescendants()
                guard !running.contains(url.standardizedFileURL.path) else { continue }
                let bundle = Bundle(url: url)
                apps.append(["pid": NSNull(), "bundle_id": bundle?.bundleIdentifier as Any? ?? NSNull(), "name": bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent, "path": url.path, "running": false, "active": false])
            }
        }
        return ["apps": apps]
    }

    private static func refuseHumanActivity(pid: Int32, windowID: UInt32? = nil) throws {
        var targets = ComputerUseNativeHostBackend.NativePlatform.listWindows(bundleID: nil).filter { $0.target.pid == pid }.map(\.target)
        if let windowID { targets = [.init(pid: pid, windowID: windowID)] }
        if targets.isEmpty { targets = [.init(pid: pid, windowID: 0)] }
        for target in targets where ComputerUseNativeHostBackend.NativePlatform.userActivity(target: target) == .human {
            throw Failure(message: "human_activity: " + ChromeProfileComputerUseBackend.humanActivityHint)
        }
    }

    @MainActor private func launch(_ arguments: [String: Any]) async throws -> ComputerUseToolResult {
        let workspace = NSWorkspace.shared
        let url: URL?
        if let bundleID = arguments["bundle_id"] as? String { url = workspace.urlForApplication(withBundleIdentifier: bundleID) }
        else { url = workspace.urlForApplication(withBundleIdentifier: arguments["name"] as! String) ?? workspace.fullPath(forApplication: arguments["name"] as! String).map { URL(fileURLWithPath: $0) } }
        guard let url else { throw Failure(message: "Application not found") }
        if arguments["allow_while_user_active"] as? Bool != true {
            for app in workspace.runningApplications where app.bundleURL == url { try Self.refuseHumanActivity(pid: app.processIdentifier) }
        }
        let previous = workspace.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = arguments["creates_new_application_instance"] as? Bool ?? false
        configuration.arguments = arguments["additional_arguments"] as? [String] ?? []
        let urls = (arguments["urls"] as? [String] ?? []).compactMap(URL.init(string:))
        let app: NSRunningApplication
        if urls.isEmpty { app = try await workspace.openApplication(at: url, configuration: configuration) }
        else { app = try await workspace.open(urls, withApplicationAt: url, configuration: configuration) }
        if workspace.frontmostApplication?.processIdentifier == app.processIdentifier, let previous, previous.processIdentifier != app.processIdentifier { _ = previous.activate(options: []) }
        var object = Self.appObject(app)
        object["windows"] = ComputerUseNativeHostBackend.NativePlatform.listWindows(bundleID: nil).filter { $0.target.pid == app.processIdentifier }.map { ["window_id": $0.target.windowID, "title": $0.title, "bounds": Self.rect($0.bounds)] as [String: Any] }
        return Self.result(object)
    }

    private static func rect(_ rect: CGRect) -> [String: Any] { ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height] }

    @MainActor private static func mutate(name: String, arguments: [String: Any]) throws -> ComputerUseToolResult {
        let pid = Int32(arguments["pid"] as! Int)
        let windowID = (arguments["window_id"] as? Int).map(UInt32.init)
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { throw Failure(message: "Application not running") }
        let yieldsToUser = arguments["allow_while_user_active"] as? Bool != true
        if yieldsToUser { try refuseHumanActivity(pid: pid, windowID: name == "set_window_frame" ? windowID : nil) }
        if name == "kill_app" {
            let terminated = app.forceTerminate()
            var fallback = false
            if !terminated || !app.isTerminated {
                if yieldsToUser { try refuseHumanActivity(pid: pid) }
                if !app.isTerminated {
                    guard Darwin.kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw Failure(message: "SIGKILL failed: \(errno)") }
                    fallback = true
                }
            }
            return result(["pid": pid, "termination_requested": true, "sigkill_fallback": fallback])
        }
        let window: AXUIElement?
        if let windowID {
            guard let exact = ComputerUseNativeHostBackend.NativePlatform.exactAXWindow(target: .init(pid: pid, windowID: windowID)) else { throw Failure(message: "Exact AX window unavailable") }
            window = exact
        } else { window = nil }
        if name == "bring_to_front" {
            guard app.activate(options: []) else { throw Failure(message: "Application activation failed") }
            if let window, AXUIElementPerformAction(window, kAXRaiseAction as CFString) != .success { throw Failure(message: "AXRaise failed") }
            return result(["pid": pid, "activated": true])
        }
        guard let window else { throw Failure(message: "window_id required") }
        var position = CGPoint(x: number(arguments["x"])!, y: number(arguments["y"])!)
        var size = CGSize(width: number(arguments["width"])!, height: number(arguments["height"])!)
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) else { throw Failure(message: "Invalid window frame") }
        let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        var positionRead: CFTypeRef?
        var sizeRead: CFTypeRef?
        var actualPosition = CGPoint.zero
        var actualSize = CGSize.zero
        let readPosition = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRead)
        let readSize = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRead)
        var verified = false
        var object: [String: Any] = ["pid": pid, "window_id": windowID!, "position_status": positionStatus.rawValue, "size_status": sizeStatus.rawValue]
        if readPosition == .success, readSize == .success, let positionRead, let sizeRead, CFGetTypeID(positionRead) == AXValueGetTypeID(), CFGetTypeID(sizeRead) == AXValueGetTypeID(), AXValueGetValue(positionRead as! AXValue, .cgPoint, &actualPosition), AXValueGetValue(sizeRead as! AXValue, .cgSize, &actualSize) {
            verified = positionStatus == .success && sizeStatus == .success && abs(actualPosition.x - position.x) < 1 && abs(actualPosition.y - position.y) < 1 && abs(actualSize.width - size.width) < 1 && abs(actualSize.height - size.height) < 1
            object["frame"] = rect(CGRect(origin: actualPosition, size: actualSize))
        }
        object["verified"] = verified
        return result(object)
    }

    @MainActor private static func writeClipboard(_ arguments: [String: Any]) throws -> ComputerUseToolResult {
        if arguments["allow_while_user_active"] as? Bool != true, let app = NSWorkspace.shared.frontmostApplication {
            try refuseHumanActivity(pid: app.processIdentifier)
        }
        let object: NSPasteboardWriting
        if let text = arguments["text"] as? String { object = text as NSString }
        else if let path = arguments["image_path"] as? String {
            let url = try checkedPath(path)
            guard let image = NSImage(contentsOf: url), image.isValid else { throw Failure(message: "Invalid image") }
            object = image
        } else { object = try checkedPath(arguments["file_path"] as! String) as NSURL }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        pasteboard.clearContents()
        guard pasteboard.writeObjects([object]) else {
            pasteboard.clearContents()
            let restored = pasteboard.writeObjects(previous)
            throw Failure(message: "Clipboard write failed; previous clipboard restored: \(restored)")
        }
        return result(["written": true, "types": pasteboard.types?.map(\.rawValue) ?? []])
    }

    static func boundedDesktopCapture(seconds: Double = 8, operation: @escaping @Sendable () async -> ComputerUseToolResult) async -> ComputerUseToolResult {
        await ComputerUseNativeHostBackend.NativePlatform.withDeadline(seconds: seconds, operation)
            ?? Self.result(["error": "desktop_capture_timeout"], error: true)
    }

    private func desktopScreenshot() async throws -> ComputerUseToolResult {
        guard CGPreflightScreenCaptureAccess() else { throw Failure(message: "Screen Recording permission required") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw Failure(message: "Main display unavailable") }
        let configuration = SCStreamConfiguration()
        configuration.width = CGDisplayPixelsWide(display.displayID)
        configuration.height = CGDisplayPixelsHigh(display.displayID)
        configuration.showsCursor = true
        let limit = try readConfig()["max_image_dimension"] as! Int
        if limit > 0, max(configuration.width, configuration.height) > limit {
            let ratio = Double(limit) / Double(max(configuration.width, configuration.height))
            configuration.width = max(1, Int(Double(configuration.width) * ratio))
            configuration.height = max(1, Int(Double(configuration.height) * ratio))
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure(message: "PNG encoding failed") }
        var result = Self.result(["width": image.width, "height": image.height, "display_id": display.displayID])
        result.content.append(.image(data: data.base64EncodedString(), mimeType: "image/png"))
        return result
    }
}
