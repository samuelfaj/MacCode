import Foundation
import CoreGraphics
import CoreFoundation

public final class SessionToolsBackend: ComputerUseToolBackend, @unchecked Sendable {
    public static let shared = SessionToolsBackend()
    public static let observationTools = ["get_session_state", "get_agent_cursor_state", "get_recording_state"]
    public static let mutationTools = ["start_session", "end_session", "set_agent_cursor_enabled", "set_agent_cursor_theme", "set_agent_cursor_motion", "start_recording", "stop_recording", "replay_trajectory"]
    public typealias Dispatcher = @Sendable (String, [String: Any]) async -> ComputerUseToolResult
    private let lock = NSLock()
    private var dispatcher: Dispatcher?
    public var replayDispatcher: Dispatcher? {
        get { lock.lock(); defer { lock.unlock() }; return dispatcher }
        set { lock.lock(); dispatcher = newValue; lock.unlock() }
    }
    private let state: SessionState

    public init() { state = SessionState(capture: { await ComputerUseNativeHostBackend.NativePlatform.capture(target: $0) }, overlayEnabled: true) }
    public init(capture: @escaping @Sendable (ComputerUseNativeHostTarget) async -> ComputerUseNativeCaptureResult, overlayEnabled: Bool = false) {
        state = SessionState(capture: capture, overlayEnabled: overlayEnabled)
    }

    public static func description(for name: String) -> String? {
        let descriptions = [
            "start_session": "Create a named agent session with an independent visual cursor and capture scope.",
            "end_session": "Remove a session cursor and stop recording owned by that session.",
            "get_session_state": "Inspect a named session and its capture scope.",
            "set_agent_cursor_enabled": "Enable or disable the visual agent cursor; never moves the real pointer.",
            "set_agent_cursor_theme": "Set the agent cursor glyph and #RRGGBB color.",
            "set_agent_cursor_motion": "Set cursor speed in screen points per second, animation duration and auto-hide delay in milliseconds.",
            "get_agent_cursor_state": "Inspect visual cursor settings and last screen point.",
            "start_recording": "Record action turns and optional macOS 15+ desktop video in a new output directory. Arguments are stored with typed content, scripts and secret inputs redacted.",
            "stop_recording": "Stop the active trajectory recording and finalize video.",
            "get_recording_state": "Inspect trajectory recording status, turn count and video availability.",
            "replay_trajectory": "Replay action.json turns in lexical order through the tool dispatcher, or list them with dry_run. Replay may repeat consequential actions."
        ]
        return descriptions[name]
    }

    public static func inputSchema(for name: String) -> [String: Any]? {
        guard description(for: name) != nil else { return nil }
        let string: [String: Any] = ["type": "string", "minLength": 1]
        var properties: [String: Any] = [:]
        var required: [String] = []
        if name.contains("session") || name.contains("cursor") {
            properties["session"] = string; required = ["session"]
        }
        switch name {
        case "start_session": properties["capture_scope"] = ["type": "string", "enum": ["auto", "window", "desktop"]]; properties["color"] = ["type": "string", "pattern": "^#[0-9A-Fa-f]{6}$"]
        case "set_agent_cursor_enabled": properties["enabled"] = ["type": "boolean"]; required.append("enabled")
        case "set_agent_cursor_theme": properties["theme"] = ["type": "string", "enum": ["default", "arrow", "dot", "crosshair"]]; properties["color"] = ["type": "string", "pattern": "^#[0-9A-Fa-f]{6}$"]; required.append("theme")
        case "set_agent_cursor_motion":
            for key in ["speed", "duration_ms", "hide_after_ms"] { properties[key] = ["type": "number", "minimum": key == "speed" ? 1 : 0, "maximum": 60000] }
        case "start_recording": properties = ["output_dir": string, "record_video": ["type": "boolean"], "session": string]; required = ["output_dir"]
        case "stop_recording", "get_recording_state": properties["session"] = string
        case "replay_trajectory": properties = ["dir": string, "dry_run": ["type": "boolean"]]; required = ["dir"]
        default: break
        }
        return ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        await state.invoke(name: name, arguments: arguments, dispatcher: replayDispatcher)
    }

    public func aroundAction(tool: String, arguments: [String: Any], targetPID: Int32?, windowID: UInt32?, point: CGPoint?, perform: () async -> ComputerUseToolResult) async -> ComputerUseToolResult {
        await state.move(arguments: arguments, point: point)
        let target = targetPID.flatMap { pid in windowID.map { ComputerUseNativeHostTarget(pid: pid, windowID: $0) } }
        let turn: URL?
        do { turn = try await state.before(tool: tool, arguments: arguments, target: target) }
        catch { return SessionState.result(["error": "recording_write_failed", "detail": error.localizedDescription], error: true) }
        let result = await perform()
        if let turn {
            do { try await state.after(turn: turn, target: target, result: result) }
            catch { return SessionState.result(["error": "recording_write_failed", "detail": error.localizedDescription, "action_performed": true, "action_is_error": result.isError], error: true) }
        }
        return result
    }
}

private actor SessionState {
    struct Session {
        var scope = "auto"
        var enabled = true
        var theme = "default"
        var color = "#42A5F5"
        var speed = 1000.0
        var duration = 200.0
        var hideAfter = 1500.0
        var point: CGPoint?
        func json(_ id: String) -> [String: Any] {
            var value: [String: Any] = ["session": id, "capture_scope": scope, "enabled": enabled, "theme": theme, "color": color, "speed": speed, "duration_ms": duration, "hide_after_ms": hideAfter]
            if let point { value["point"] = ["x": point.x, "y": point.y] }
            return value
        }
    }
    private var sessions: [String: Session] = [:]
    private var output: URL?
    private var owner: String?
    private var turns = 0
    private var video: AnyObject?
    private var videoStatus = "not_requested"
    private var replaying = false
    private var transitioning = false
    private var pending = 0
    private let capture: @Sendable (ComputerUseNativeHostTarget) async -> ComputerUseNativeCaptureResult
    private let overlayEnabled: Bool
    private var overlay: AgentCursorOverlay?

    init(capture: @escaping @Sendable (ComputerUseNativeHostTarget) async -> ComputerUseNativeCaptureResult, overlayEnabled: Bool) {
        self.capture = capture; self.overlayEnabled = overlayEnabled
    }
    static func result(_ object: [String: Any], error: Bool = false) -> ComputerUseToolResult {
        do { return ComputerUseToolResult(text: String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self), isError: error) }
        catch { return ComputerUseToolResult(text: "JSON serialization failed", isError: true) }
    }
    private func fail(_ message: String) -> ComputerUseToolResult { Self.result(["error": message], error: true) }
    private func recordingState() -> [String: Any] {
        var value: [String: Any] = ["recording": output != nil, "turns": turns, "video": videoStatus]
        if let output { value["output_dir"] = output.path }
        if let owner { value["session"] = owner }
        return value
    }
    func invoke(name: String, arguments a: [String: Any], dispatcher: SessionToolsBackend.Dispatcher?) async -> ComputerUseToolResult {
        guard let schema = SessionToolsBackend.inputSchema(for: name), let properties = schema["properties"] as? [String: [String: Any]] else { return fail("unknown_tool") }
        for key in schema["required"] as? [String] ?? [] { if a[key] == nil { return fail("missing_\(key)") } }
        for (key, value) in a {
            guard let rule = properties[key] else { return fail("unexpected_\(key)") }
            switch rule["type"] as? String {
            case "string": guard let s = value as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.count <= 4096 else { return fail("invalid_\(key)") }
            case "boolean": guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return fail("invalid_\(key)") }
            case "number": guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= ((rule["minimum"] as? NSNumber)?.doubleValue ?? 0), n.doubleValue <= 60000 else { return fail("invalid_\(key)") }
            default: break
            }
            if let options = rule["enum"] as? [String], !options.contains(value as? String ?? "") { return fail("invalid_\(key)") }
        }
        if let color = a["color"] as? String, color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil { return fail("invalid_color") }
        let id = a["session"] as? String
        switch name {
        case "start_session":
            guard let id, sessions[id] == nil else { return fail("session_exists") }
            var s = Session(); s.scope = a["capture_scope"] as? String ?? "auto"; s.color = a["color"] as? String ?? s.color
            sessions[id] = s; return Self.result(s.json(id))
        case "end_session":
            guard let id, sessions[id] != nil else { return fail("session_not_found") }
            if owner == id { let result = await stop(); if result.isError { return result } }
            sessions.removeValue(forKey: id)
            await overlay?.remove(id)
            return Self.result(["session": id, "ended": true])
        case "get_session_state", "get_agent_cursor_state", "set_agent_cursor_enabled", "set_agent_cursor_theme", "set_agent_cursor_motion":
            guard let id, var s = sessions[id] else { return fail("session_not_found") }
            if name == "set_agent_cursor_enabled" { s.enabled = a["enabled"] as? Bool ?? false }
            if name == "set_agent_cursor_theme" { s.theme = a["theme"] as? String ?? s.theme; s.color = a["color"] as? String ?? s.color }
            if name == "set_agent_cursor_motion" {
                guard ["speed", "duration_ms", "hide_after_ms"].contains(where: { a[$0] != nil }) else { return fail("missing_motion") }
                s.speed = (a["speed"] as? NSNumber)?.doubleValue ?? s.speed
                s.duration = (a["duration_ms"] as? NSNumber)?.doubleValue ?? s.duration
                s.hideAfter = (a["hide_after_ms"] as? NSNumber)?.doubleValue ?? s.hideAfter
            }
            sessions[id] = s
            if !s.enabled { await overlay?.remove(id) }
            return Self.result(s.json(id))
        case "start_recording":
            guard output == nil, !transitioning else { return fail("recording_active") }
            if let id, sessions[id] == nil { return fail("session_not_found") }
            let url = URL(fileURLWithPath: a["output_dir"] as! String, isDirectory: true).standardizedFileURL
            guard !FileManager.default.fileExists(atPath: url.path) else { return fail("output_dir_exists") }
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch { return fail(error.localizedDescription) }
            output = url; owner = id; turns = 0; videoStatus = "not_requested"
            if a["record_video"] as? Bool == true {
                transitioning = true
                if #available(macOS 15.0, *) {
                    let recorder = TrajectoryVideo()
                    do { try await recorder.start(url: url.appendingPathComponent("recording.mp4")); video = recorder; videoStatus = "recording" }
                    catch { videoStatus = "video_unavailable: \(error.localizedDescription)" }
                } else { videoStatus = "video_unavailable: requires macOS 15" }
                transitioning = false
            }
            return Self.result(recordingState())
        case "stop_recording":
            if let id, id != owner { return fail("recording_session_mismatch") }
            return await stop()
        case "get_recording_state": return Self.result(recordingState())
        case "replay_trajectory":
            guard !replaying else { return fail("replay_active") }
            let root = URL(fileURLWithPath: a["dir"] as! String, isDirectory: true)
            do {
                let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.range(of: "^turn-[0-9]+$", options: .regularExpression) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                var actions: [[String: Any]] = []
                for dir in dirs {
                    guard let action = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("action.json"))) as? [String: Any], let tool = action["tool"] as? String, !tool.isEmpty, action["arguments"] is [String: Any], tool != "replay_trajectory" else { return fail("invalid_action") }
                    actions.append(action)
                }
                if a["dry_run"] as? Bool == true { return Self.result(["dry_run": true, "actions": actions]) }
                guard let dispatcher else { return fail("replay_dispatcher_unavailable") }
                replaying = true; defer { replaying = false }
                var completed = 0
                for action in actions {
                    let result = await dispatcher(action["tool"] as! String, action["arguments"] as! [String: Any])
                    if result.isError { return Self.result(["error": "replay_action_failed", "completed": completed, "tool": action["tool"]!], error: true) }
                    completed += 1
                }
                return Self.result(["replayed": completed])
            } catch { return fail(error.localizedDescription) }
        default: return fail("unknown_tool")
        }
    }
    private func stop() async -> ComputerUseToolResult {
        guard !transitioning, pending == 0 else { return fail("recording_busy") }
        transitioning = true; defer { transitioning = false }
        if #available(macOS 15.0, *), let video = video as? TrajectoryVideo {
            do { try await video.stop(); videoStatus = "finished" }
            catch { videoStatus = "video_error: \(error.localizedDescription)"; return fail(videoStatus) }
        }
        video = nil; output = nil
        return Self.result(recordingState())
    }
    func move(arguments: [String: Any], point: CGPoint?) async {
        // Without an explicit session, mouse actions still show a default agent cursor.
        let id = arguments["session"] as? String ?? "default"
        if arguments["session"] == nil, sessions[id] == nil { sessions[id] = Session() }
        guard var s = sessions[id], s.enabled, let point, point.x.isFinite, point.y.isFinite else { return }
        let distance = s.point.map { hypot($0.x - point.x, $0.y - point.y) } ?? 0
        s.point = point; sessions[id] = s
        guard overlayEnabled else { return }
        if overlay == nil { overlay = await AgentCursorOverlay() }
        await overlay?.move(session: id, point: point, theme: s.theme, color: s.color, duration: min(s.duration, distance / s.speed * 1000), hideAfter: s.hideAfter)
    }
    private func redact(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, pair in
                if ["text", "value", "secret_inputs", "prompt_text", "javascript"].contains(pair.key) {
                    result[pair.key] = "[REDACTED]"
                } else if pair.key == "inputs", var inputs = redact(pair.value) as? [String: Any] {
                    for key in object["secret_inputs"] as? [String] ?? [] where inputs[key] != nil { inputs[key] = "[REDACTED]" }
                    result[pair.key] = inputs
                } else { result[pair.key] = redact(pair.value) }
            }
        }
        if let array = value as? [Any] { return array.map { redact($0) } }
        return value
    }
    private func write(_ value: [String: Any], to url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic) }
    func before(tool: String, arguments: [String: Any], target: ComputerUseNativeHostTarget?) async throws -> URL? {
        guard let output, !transitioning, owner == nil || owner == arguments["session"] as? String else { return nil }
        turns += 1; let dir = output.appendingPathComponent(String(format: "turn-%05d", turns))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try write(["tool": tool, "arguments": redact(arguments)], to: dir.appendingPathComponent("action.json"))
        pending += 1
        do { try await snapshot(target, dir: dir, phase: "before") }
        catch { pending -= 1; throw error }
        return dir
    }
    func after(turn: URL, target: ComputerUseNativeHostTarget?, result: ComputerUseToolResult) async throws {
        defer { pending -= 1 }
        try await snapshot(target, dir: turn, phase: "after", isError: result.isError)
    }
    private func snapshot(_ target: ComputerUseNativeHostTarget?, dir: URL, phase: String, isError: Bool? = nil) async throws {
        var evidence: [String: Any] = [:]
        let file = dir.appendingPathComponent("evidence.json")
        if FileManager.default.fileExists(atPath: file.path) { evidence = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:] }
        if let target {
            evidence["target_pid"] = target.pid; evidence["window_id"] = target.windowID
            switch await capture(target) {
            case .success(let image), .quartzFallback(let image):
                if image.mimeType == "image/png", let data = Data(base64Encoded: image.data) {
                    try data.write(to: dir.appendingPathComponent("\(phase).png"), options: .atomic); evidence[phase] = "captured"
                } else { evidence[phase] = "skipped: invalid PNG capture" }
            case .unavailable(let reason): evidence[phase] = "skipped: \(reason)"
            }
        } else { evidence[phase] = "skipped: target PID and window ID unknown" }
        if let isError { evidence["action_is_error"] = isError }
        try write(evidence, to: file)
    }
}
