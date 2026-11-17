import AppKit
import Darwin
import Foundation

/// Native messaging connects Chrome's extension to a local, user-only socket.
/// No debugging port, browser restart, profile copy, or cookie export is needed.
public enum ChromeProfileConnection {
    public static let hostName = "io.remotecode.computer_use"
    /// MacCode's extension ships a manifest `key`, so its ID is the same on every Mac.
    public static let extensionID = "ejnjfchbceelacijgldkmckpmjfpdgip"
    static var origin: String { "chrome-extension://\(extensionID)/" }
    public static let hostArgument = "chrome-native-host"
    static let maximumFrameBytes = 1_048_576

    public static var directory: URL {
        directory(in: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func directory(in home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support/RemoteCode/ChromeComputerUse")
    }

    public static var socketPath: String { directory.appendingPathComponent("bridge.sock").path }

    struct Failure: Error, LocalizedError {
        enum Kind { case notConnected, closed, timedOut, other }
        let message: String
        var kind: Kind = .other
        var errorDescription: String? { message }
    }

    /// The extension version that keeps its tab awake and answers every request before the host's limit.
    public static let minimumExtensionVersion = "1.5.0"

    public static func chromeIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }

    /// Chrome starts the host only while the extension holds its port, so a listening socket
    /// means the extension is installed, enabled and connected.
    public static func hostListening(path: String = socketPath) -> Bool {
        guard var address = try? address(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    /// What can be known about the extension without waiting on a page: installed, connected,
    /// answering and recent enough. Never throws: a status question deserves a status answer.
    public static func extensionStatus(
        session: String = UUID().uuidString, timeout: TimeInterval = 2,
        registered: Bool = isRegistered(),
        send: ([String: Any], TimeInterval) throws -> [String: Any] = { try request($0, timeout: $1) }
    ) -> [String: Any] {
        guard registered else {
            return ["connected": false, "state": "not_installed",
                    "hint": "The MacCode Chrome extension is not set up. In MacCode, open Settings > Computer Use > Set Up Chrome Extension."]
        }
        do {
            var status = try send(["operation": "browser_status", "session": session, "arguments": [String: Any]()], timeout)
            status.removeValue(forKey: "id")
            let version = status["version"] as? String
            if let version, version.compare(minimumExtensionVersion, options: .numeric) != .orderedAscending {
                status["state"] = "connected"
            } else {
                status["state"] = "outdated"
                status["hint"] = "Chrome is running an older copy of the MacCode extension than this server needs (\(minimumExtensionVersion)); background tabs can freeze. In MacCode, open Settings > Computer Use > Set Up Chrome Extension to copy the current files, then Reload it in chrome://extensions."
            }
            return status
        } catch let failure as Failure where failure.kind == .timedOut {
            return ["connected": true, "state": "busy", "hint": "The extension is connected and running another request. Retry shortly."]
        } catch {
            return ["connected": false, "state": "not_connected", "hint": error.localizedDescription]
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw Failure(message: "Chrome bridge socket path is too long.") }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { pointer in
                bytes.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: $0.count) }
            }
        }
        return address
    }

    static func wait(_ fd: Int32, events: Int16, until deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure(message: "Chrome bridge timed out. Check the tab before retrying an action.", kind: .timedOut) }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 30_000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, descriptor.revents & events != 0 else {
                throw Failure(message: "Chrome bridge disconnected or timed out. Check the tab before retrying an action.", kind: result == 0 ? .timedOut : .closed)
            }
            return
        }
    }

    static func readBytes(_ count: Int, fd: Int32, until deadline: Date) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try wait(fd, events: Int16(POLLIN), until: deadline)
                let size = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else {
                    throw Failure(message: "The Chrome extension stopped answering and its bridge restarted. It reconnects by itself; call browser_status, then retry.", kind: .closed)
                }
                offset += size
            }
        }
        return data
    }

    static func readFrame(fd: Int32, until deadline: Date) throws -> [String: Any] {
        let header = try readBytes(4, fd: fd, until: deadline)
        let size = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard size > 0, size <= maximumFrameBytes else { throw Failure(message: "Invalid Chrome message size.") }
        let data = try readBytes(Int(size), fd: fd, until: deadline)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Invalid Chrome message.")
        }
        return object
    }

    static func writeFrame(_ object: [String: Any], fd: Int32, until deadline: Date) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= maximumFrameBytes else { throw Failure(message: "Chrome message exceeds 1 MB.") }
        var size = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(data)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < frame.count {
                try wait(fd, events: Int16(POLLOUT), until: deadline)
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), frame.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure(message: "Could not write to Chrome bridge.") }
                offset += written
            }
        }
    }

    static func noSIGPIPE(_ fd: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    /// `timeout` outlasts the extension (30 s) and the host (35 s) by default.
    public static func request(_ object: [String: Any], path: String = socketPath, timeout: TimeInterval = 40,
                               chromeRunning: () -> Bool = chromeIsRunning) throws -> [String: Any] {
        var address = try address(path)
        let start = Date()
        var fd: Int32 = -1
        while true {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure(message: "Could not create Chrome bridge connection.") }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 { break }
            Darwin.close(fd)
            let running = chromeRunning()
            // The extension reconnects about a second after a drop; wait that out while Chrome is up.
            guard running, Date().timeIntervalSince(start) < min(3, timeout / 2) else {
                throw Failure(message: running
                    ? "The MacCode Chrome extension is not connected. It reconnects every 30 seconds; its toolbar button reconnects at once. If it is not in this Chrome profile, in MacCode open Settings > Computer Use > Set Up Chrome Extension."
                    : "Google Chrome is not running, so the MacCode extension is not connected.", kind: .notConnected)
            }
            usleep(100_000)
        }
        defer { Darwin.close(fd) }
        noSIGPIPE(fd)
        let deadline = start.addingTimeInterval(timeout)
        var request = object
        let id = UUID().uuidString
        request["id"] = id
        try writeFrame(request, fd: fd, until: deadline)
        let response = try readFrame(fd: fd, until: deadline)
        guard response["id"] as? String == id else { throw Failure(message: "Chrome response did not match this request.") }
        return response
    }

    /// Chrome launches exactly this host via its allowlisted native manifest.
    /// Blocking poll keeps the connected host idle until a real request arrives.
    public static func runHost(origin: String, path: String = socketPath, input: Int32 = STDIN_FILENO,
                               output: Int32 = STDOUT_FILENO, responseTimeout: TimeInterval = 35) throws {
        guard origin == Self.origin else {
            throw Failure(message: "Unexpected Chrome extension origin.")
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Failure(message: "Could not lock Chrome bridge.") }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure(message: "Another Chrome profile is connected. Disconnect its extension first.")
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure(message: "Could not start Chrome bridge.") }
        defer { Darwin.close(listener); unlink(path) }
        var address = try address(path)
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            throw Failure(message: "Could not listen for Chrome requests.")
        }
        signal(SIGPIPE, SIG_IGN)
        while true {
            var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: input, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 && errno == EINTR { continue }
            // Chrome's pipe closing means the extension disconnected. Never
            // leave a host daemon or an outstanding action behind.
            guard ready > 0, descriptors[1].revents == 0 else { return }
            guard descriptors[0].revents & Int16(POLLIN) != 0 else { return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            defer { Darwin.close(client) }
            noSIGPIPE(client)
            let request: [String: Any]
            do { request = try readFrame(fd: client, until: Date().addingTimeInterval(2)) }
            catch { continue }
            let deadline = Date().addingTimeInterval(responseTimeout)
            try writeFrame(request, fd: output, until: deadline)
            let response: [String: Any]
            do { response = try readFrame(fd: input, until: deadline) }
            catch {
                // Say why before exiting; a silent close reads as a dead bridge. Chrome starts a
                // clean host when the extension reconnects.
                try? writeFrame(["id": request["id"] ?? "", "ok": false,
                                 "error": "Chrome extension did not answer. It reconnects by itself; check browser_status before retrying."],
                                fd: client, until: Date().addingTimeInterval(1))
                throw error
            }
            guard response["id"] as? String == request["id"] as? String else {
                throw Failure(message: "Unexpected Chrome response. Reconnect the extension.")
            }
            // A caller can disappear after an action. Do not replay it.
            try? writeFrame(response, fd: client, until: deadline)
        }
    }

    /// Whether MacCode registered its native host for its own extension. Chrome starts the host
    /// only from this registration, so without it the extension can never connect.
    public static func isRegistered(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let registration = homeDirectory.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/" + hostName + ".json")
        guard let data = try? Data(contentsOf: registration),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origins = manifest["allowed_origins"] as? [String] else { return false }
        return origins.contains(origin)
    }

    /// Install only this extension's native host registration and resources.
    /// Loading the unpacked extension remains an explicit Chrome UI action.
    public static func install(executable: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let manager = FileManager.default
        let directory = directory(in: homeDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("extension")
        // Match the shipped Contents/Resources layout. Bundle.module embeds a
        // developer build path and can fatalError in the installed app.
        let executableDirectory = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        let bundles = [
            executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources/RemoteCode_CoreModel.bundle"),
            executableDirectory.appendingPathComponent("RemoteCode_CoreModel.bundle"),
        ]
        guard let source = bundles.compactMap({ Bundle(url: $0)?.url(forResource: "ChromeComputerUse", withExtension: nil) }).first,
              manager.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw Failure(message: "Chrome extension resources are missing from this build.")
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        // Every file, `_locales` included: Chrome refuses to load a manifest that names a
        // default_locale whose messages are missing.
        for path in manager.enumerator(atPath: source.path)?.compactMap({ $0 as? String }) ?? [] {
            var isDirectory: ObjCBool = false
            let file = source.appendingPathComponent(path)
            guard manager.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let target = destination.appendingPathComponent(path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: file).write(to: target, options: .atomic)
        }
        let host = directory.appendingPathComponent("native-host")
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try Data("#!/bin/sh\nexec \(quoted) \(hostArgument) \"$@\"\n".utf8).write(to: host, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
        let registration = homeDirectory.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try manager.createDirectory(at: registration, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": hostName, "description": "RemoteCode background Chrome control",
                                       "path": host.path, "type": "stdio",
                                       "allowed_origins": [origin]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: registration.appendingPathComponent(hostName + ".json"), options: .atomic)
        return destination
    }
}

public final class ChromeProfileComputerUseBackend: ComputerUseToolBackend, @unchecked Sendable {
    public static let observationTools = ["browser_snapshot", "browser_status"]
    public static let mutationTools = ["browser_open", "browser_act", "browser_close", "browser_navigate", "browser_click", "browser_type", "browser_pointer", "browser_dialog", "browser_set_input_files", "browser_download", "page"]
    public static let tools = observationTools + mutationTools

    public static func description(for name: String) -> String? {
        switch name {
        case "browser_navigate": return "Navigate the session's owned background tab to an HTTP, HTTPS or about URL. Invalidates previous refs and returns a fresh snapshot."
        case "browser_click": return "Trusted click on a snapshot ref or viewport x,y in the owned background tab. Returns a fresh snapshot."
        case "browser_type": return "Type text into the owned background tab, optionally focusing a ref. insert_text inserts text; keystrokes sends key events per character. Returns a fresh snapshot."
        case "browser_pointer": return "Hover, right-click, double-click, scroll or drag in the owned background tab using refs or viewport coordinates. Returns a fresh snapshot."
        case "browser_dialog": return "Inspect, accept or dismiss a JavaScript dialog. Debugger stays attached while a dialog is open, otherwise detaches after each call. Only dialogs observed while attached are tracked."
        case "browser_set_input_files": return "Set absolute local file paths on a file input ref in the owned background tab. Returns a fresh snapshot."
        case "browser_download": return "Download a link ref through Chrome Downloads, then move the completed file to an existing absolute directory. Returns final path and a fresh snapshot."
        case "page": return "Execute JavaScript, get text, query DOM attributes, click an element or type text in the owned background tab. Mutations return a fresh snapshot."
        default: return nil
        }
    }

    public static func inputSchema(for name: String) -> [String: Any]? {
        let string: [String: Any] = ["type": "string"]
        let number: [String: Any] = ["type": "number"]
        let point: [String: Any] = ["ref": string, "x": number, "y": number]
        var properties: [String: Any]
        var required: [String] = []
        switch name {
        case "browser_navigate": properties = ["url": string]; required = ["url"]
        case "browser_click":
            properties = point.merging(["button": ["type": "string", "enum": ["left", "right", "middle"]], "click_count": ["type": "integer", "enum": [1, 2, 3]]]) { _, new in new }
        case "browser_type":
            properties = ["ref": string, "text": string, "mode": ["type": "string", "enum": ["insert_text", "keystrokes"]]]; required = ["text"]
        case "browser_pointer":
            properties = point.merging(["action": ["type": "string", "enum": ["hover", "right_click", "double_click", "scroll", "drag"]], "to_ref": string, "to_x": number, "to_y": number, "delta_x": number, "delta_y": number]) { _, new in new }; required = ["action"]
        case "browser_dialog":
            properties = ["action": ["type": "string", "enum": ["inspect", "accept", "dismiss"]], "prompt_text": string]; required = ["action"]
        case "browser_set_input_files":
            properties = ["ref": string, "paths": ["type": "array", "items": string]]; required = ["ref", "paths"]
        case "browser_download": properties = ["ref": string, "directory": string]; required = ["ref", "directory"]
        case "page":
            properties = ["action": ["type": "string", "enum": ["execute_javascript", "get_text", "query_dom", "click_element", "insert_text", "type_keystrokes"]], "javascript": string, "css_selector": string, "attributes": ["type": "array", "items": string], "selector": string, "text": string]; required = ["action"]
        default: return nil
        }
        if name != "browser_dialog" { properties["allow_while_user_active"] = allowWhileUserActive }
        return ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    /// Shared by every tool that yields to the user. Stealth stays the default; this is the escalation.
    static let allowWhileUserActive: [String: Any] = [
        "type": "boolean", "default": false,
        "description": "Act even though the user is using the target. Only after the non-disturbing routes failed, and never when the user said not to interrupt them.",
    ]
    static let humanActivityHint = "the user is using this target. Prefer a route that does not disturb them (a background tab, an Accessibility action, or a short wait). If none works, retry with allow_while_user_active: true, unless the user said not to interrupt them."
    private let sessionID = UUID().uuidString
    private let send: @Sendable ([String: Any], TimeInterval) throws -> [String: Any]
    private let registered: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "io.remotecode.chrome-profile")

    /// An injected `send` stands in for a registered, connected extension.
    public init(send: (@Sendable ([String: Any]) throws -> [String: Any])? = nil) {
        if let send {
            self.send = { request, _ in try send(request) }
            registered = { true }
        } else {
            self.send = { try ChromeProfileConnection.request($0, timeout: $1) }
            registered = { ChromeProfileConnection.isRegistered() }
        }
    }

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    guard Self.tools.contains(name) else { throw ChromeProfileConnection.Failure(message: "Unknown browser tool.") }
                    if name == "browser_status" {
                        let status = ChromeProfileConnection.extensionStatus(session: sessionID, registered: registered(), send: send)
                        let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
                        continuation.resume(returning: ComputerUseToolResult(text: String(decoding: data, as: UTF8.self)))
                        return
                    }
                    var downloadDirectory: URL?
                    if name == "browser_download" {
                        var isDirectory: ObjCBool = false
                        guard let path = arguments["directory"] as? String, path.hasPrefix("/"), !path.contains("\0"),
                              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                            throw ChromeProfileConnection.Failure(message: "directory must be an existing absolute directory.")
                        }
                        downloadDirectory = URL(fileURLWithPath: path, isDirectory: true)
                    }
                    var response = try send(["operation": name, "session": sessionID, "arguments": arguments], 40)
                    if let directory = downloadDirectory, response["ok"] as? Bool == true {
                        guard let path = response["download_path"] as? String, path.hasPrefix("/"), !path.contains("\0") else {
                            throw ChromeProfileConnection.Failure(message: "Chrome did not return an absolute completed download path.")
                        }
                        let source = URL(fileURLWithPath: path)
                        let destination = directory.appendingPathComponent(source.lastPathComponent)
                        do {
                            if source.standardizedFileURL != destination.standardizedFileURL {
                                try FileManager.default.moveItem(at: source, to: destination)
                            }
                        } catch {
                            throw ChromeProfileConnection.Failure(message: "Download remains at \(path); move failed: \(error.localizedDescription)")
                        }
                        response["path"] = destination.path
                        response.removeValue(forKey: "download_path")
                    }
                    let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                    continuation.resume(returning: ComputerUseToolResult(
                        text: String(decoding: data, as: UTF8.self), isError: response["ok"] as? Bool != true
                    ))
                } catch {
                    continuation.resume(returning: ComputerUseToolResult(text: error.localizedDescription, isError: true))
                }
            }
        }
    }
}
