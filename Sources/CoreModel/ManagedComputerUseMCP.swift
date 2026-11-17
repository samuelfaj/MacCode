import AppKit
import Foundation

public struct ComputerUseContentPart: Sendable, Equatable {
    public var type: String
    public var text: String?
    public var data: String?
    public var mimeType: String?

    public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
    }

    public static func text(_ value: String) -> ComputerUseContentPart {
        ComputerUseContentPart(type: "text", text: value)
    }

    public static func image(data: String, mimeType: String) -> ComputerUseContentPart {
        ComputerUseContentPart(type: "image", data: data, mimeType: mimeType)
    }

    /// Decode one zavora / MCP content item. Image parts keep data + mimeType.
    public static func parse(_ object: [String: Any]) -> ComputerUseContentPart? {
        guard let type = object["type"] as? String, !type.isEmpty else { return nil }
        return ComputerUseContentPart(
            type: type,
            text: object["text"] as? String,
            data: object["data"] as? String,
            mimeType: object["mimeType"] as? String
        )
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["type": type]
        if let text { object["text"] = text }
        if let data { object["data"] = data }
        if let mimeType { object["mimeType"] = mimeType }
        return object
    }
}

public struct ComputerUseToolResult: Sendable, Equatable {
    public var content: [ComputerUseContentPart]
    public var isError: Bool

    public init(content: [ComputerUseContentPart], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public init(text: String, isError: Bool = false) {
        self.content = [.text(text)]
        self.isError = isError
    }

    /// Decode an injected/backend tools/call result so screenshot/zoom images survive.
    public static func parseUpstream(_ object: [String: Any]) -> ComputerUseToolResult {
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? String(describing: error)
            return ComputerUseToolResult(text: message, isError: true)
        }
        let result = object["result"] as? [String: Any] ?? object
        let raw = result["content"] as? [[String: Any]] ?? []
        let parts = raw.compactMap(ComputerUseContentPart.parse)
        return ComputerUseToolResult(
            content: parts,
            isError: result["isError"] as? Bool ?? false
        )
    }

    public func jsonContent() -> [[String: Any]] {
        content.map { $0.jsonObject() }
    }
}

public protocol ComputerUseToolBackend: Sendable {
    func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult
}

/// Test backend: records that the host queue admitted the call. Production uses
/// the shipped native backend; callers can inject another backend for tests.
public struct ComputerUseQueuedPassthroughBackend: ComputerUseToolBackend {
    public init() {}

    public func invoke(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        let keys = arguments.keys.sorted().joined(separator: ",")
        return ComputerUseToolResult(
            text: "queued \(name)\(keys.isEmpty ? "" : " keys=\(keys)")",
            isError: false
        )
    }
}

/// MCP request handler for the shipped native host backend: screenshot plus
/// targeted semantic/input operations. Mutating and observation tools share
/// `ComputerUseHostQueue` so two bots never interleave HID.
public struct ManagedComputerUseMCP: Sendable {
    public static let serverName = ComputerUseHostQueue.serverName
    public static let screenshotTool = "screenshot"
    public static let leftClickTool = "left_click"
    public static let typeTool = "type"

    public static let observationTools: [String] = [
        screenshotTool,
        "zoom",
        "cursor_position",
        "list_windows",
        "get_ui_tree",
        "jev_decide",
        "run_subtask",
        "doctor",
        "cua_status",
    ]

    public static let mutationTools: [String] = [
        leftClickTool,
        typeTool,
        "click_element",
        "set_value",
        "menu_shortcut",
        "restore_window",
        "right_click",
        "mouse_move",
        "scroll",
        "key",
    ]

    /// cua-driver parity tools served by separate backends.
    static let desktopTools = DesktopToolsBackend.observationTools + DesktopToolsBackend.mutationTools
    static let inputTools = InputToolsBackend.observationTools + InputToolsBackend.mutationTools
    static let sessionTools = SessionToolsBackend.observationTools + SessionToolsBackend.mutationTools
    static let recordedTools = Set(mutationTools + DesktopToolsBackend.mutationTools + InputToolsBackend.mutationTools
        + ChromeProfileComputerUseBackend.mutationTools)

    /// Every name that can be called.
    /// The order of work in a few lines. MacCode agents may not have the mac-use skill installed
    /// (it ships with a mac-use release, for Distill), so these lines must stand on their own.
    static let instructions = [
        "RemoteCode computer-use drives macOS windows and Chrome tabs.",
        "1. Web pages: call browser_status. When state is connected, use browser_open and the browser_* tools: your own background tab in the user's Chrome profile through the MacCode extension, elements by ref. Selecting the tab gives it to the user. Finish with browser_close on the same connection and check its result.",
        "2. Native windows: list_windows gives target_pid and target_window_id. Read with get_ui_tree and a query, so you get only the rows you need: - [ax_n] role \"title\".",
        "3. Act on an element: click_element, set_value, click or type_text with element_id, passing the state token of the read it came from as expected_state_token. The id keeps meaning the element you read while the window changes. Use screenshot and pixel x,y only for what the tree does not show; x,y are pixels of the returned image (image_size).",
        "4. Read the result. effect is ui_changed when the app was seen to react, otherwise unverified; ok alone only means the input was accepted. On unverified, read the window again before repeating anything, above all a toggle. run_steps acts and reads in one call.",
        "5. Stay out of the user's way first: background tabs, Accessibility actions and background delivery never take focus, and a mutation yields with human_activity while the user is on the target. When no quiet route can do the work, retry with allow_while_user_active: true (and delivery_mode foreground or restore_window where needed) instead of stopping, then say what you interrupted. Never escalate when the user said not to interrupt them.",
        "6. Close what you opened (tabs, sessions, recordings) on success and on failure, and report cleanup you could not verify. Keep what the user took over.",
        "With OPENROUTER_API_KEY (or a Jev key), jev_decide, verify_state criteria and run_subtask give cheap typed decisions from liquid/d1.2-ultra, with Jev only as fallback; engine names the model that answered. Native jev_decide and verify_state also send the window screenshot unless it has a secure field. The screenshot shows what the window shows; field values are never sent as text, and the model never authorizes an action. cua_status reports cua Spaces for work that does not need the user's own apps.",
    ].joined(separator: "\n")

    public static var callableToolNames: [String] {
        observationTools + mutationTools + ChromeProfileComputerUseBackend.tools
            + desktopTools + inputTools + sessionTools + ["run_steps"]
    }

    /// Earlier names whose job a listed tool now does: click, type_text, press_key, move_cursor and
    /// get_cursor_position. Two families with different contracts for one action cost callers a
    /// failed call each time they mixed them, so only one is listed; the others still work.
    static let unlistedToolNames: Set<String> = ["left_click", "right_click", "type", "key", "mouse_move", "cursor_position"]

    public static var advertisedToolNames: [String] {
        callableToolNames.filter { !unlistedToolNames.contains($0) }
    }

    private let queue: ComputerUseHostQueue
    private let backend: any ComputerUseToolBackend
    private let jev: JevDecision
    private let browser: any ComputerUseToolBackend
    private let jevAvailable: @Sendable () -> Bool
    private let cua: CuaSpaces
    private let jevTransport: any JevTransport
    private let desktop: any ComputerUseToolBackend
    private let input: any ComputerUseToolBackend
    private let sessions: SessionToolsBackend

    public init(
        queue: ComputerUseHostQueue = .shared,
        backend: any ComputerUseToolBackend = ComputerUseNativeHostBackend(),
        jev: JevDecision = JevDecision(),
        browser: any ComputerUseToolBackend = ChromeProfileComputerUseBackend(),
        jevAvailable: @escaping @Sendable () -> Bool = {
            TypeSafeJevTransport.isConfigured()
        },
        cua: CuaSpaces = CuaSpaces(),
        jevTransport: any JevTransport = TypeSafeJevTransport(),
        desktop: any ComputerUseToolBackend = DesktopToolsBackend(),
        input: any ComputerUseToolBackend = InputToolsBackend(),
        sessions: SessionToolsBackend = .shared
    ) {
        self.queue = queue
        self.backend = backend
        self.jev = jev
        self.browser = browser
        self.jevAvailable = jevAvailable
        self.cua = cua
        self.jevTransport = jevTransport
        self.desktop = desktop
        self.input = input
        self.sessions = sessions
        let replay = self
        sessions.replayDispatcher = { name, arguments in
            await replay.replayCall(name: name, arguments: arguments)
        }
    }

    /// Called when the client goes away. An agent that never reached browser_close would leave
    /// its tab open with Chrome's debugging bar showing; nothing else is listening to close it.
    public func closeBrowser(extensionConnected: () -> Bool = { ChromeProfileConnection.hostListening() }) async {
        guard extensionConnected() else { return }
        _ = await browser.invoke(name: "browser_close", arguments: [:])
    }

    /// Re-enters tools/call so replayed turns take the same queue, guards and recording.
    private func replayCall(name: String, arguments: [String: Any]) async -> ComputerUseToolResult {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": arguments]]
        guard let line = encode(request), let response = await handle(line),
              let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ComputerUseToolResult(text: "replay call failed", isError: true)
        }
        return ComputerUseToolResult.parseUpstream(object)
    }

    /// Overlay position in screen points for pixel-addressed calls.
    private static func actionPoint(_ arguments: [String: Any], pid: Int32?, windowID: UInt32?) -> CGPoint? {
        let pair = (arguments["coordinate"] as? [NSNumber]).flatMap { $0.count == 2 ? ($0[0].doubleValue, $0[1].doubleValue) : nil }
            ?? ((arguments["x"] as? NSNumber).flatMap { x in (arguments["y"] as? NSNumber).map { (x.doubleValue, $0.doubleValue) } })
        if pair == nil, let pid, let windowID, let id = arguments["element_id"] as? String,
           let element = ComputerUseNativeHostBackend.NativePlatform.element(
               target: ComputerUseNativeHostTarget(pid: pid, windowID: windowID), id: id) {
            var origin = CGPoint.zero, size = CGSize.zero
            let position = ComputerUseNativeHostBackend.NativePlatform.attribute(kAXPositionAttribute as CFString, from: element)
            let extent = ComputerUseNativeHostBackend.NativePlatform.attribute(kAXSizeAttribute as CFString, from: element)
            if let position, let extent, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
               AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size) {
                return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            }
        }
        guard let (x, y) = pair else { return nil }
        if arguments["scope"] as? String == "desktop" { return CGPoint(x: x, y: y) }
        guard let pid, let windowID,
              let window = ComputerUseNativeHostBackend.NativePlatform.listWindows(bundleID: nil)
                .first(where: { $0.target == ComputerUseNativeHostTarget(pid: pid, windowID: windowID) }) else { return nil }
        let scale = NSScreen.screens.first { $0.frame.intersects(window.bounds) }?.backingScaleFactor ?? 2
        return CGPoint(x: window.bounds.minX + x / scale, y: window.bounds.minY + y / scale)
    }

    private func recorded(_ name: String, _ arguments: [String: Any],
                          _ perform: () async -> ComputerUseToolResult) async -> ComputerUseToolResult {
        guard Self.recordedTools.contains(name) else { return await perform() }
        let pid = Self.targetPID(from: arguments) ?? ComputerUseNativeHostBackend.exactInt32(arguments["pid"])
        let window = ComputerUseNativeHostBackend.exactUInt32(arguments["target_window_id"])
            ?? ComputerUseNativeHostBackend.exactUInt32(arguments["window_id"])
        return await sessions.aroundAction(tool: name, arguments: arguments, targetPID: pid, windowID: window,
                                           point: Self.actionPoint(arguments, pid: pid, windowID: window), perform: perform)
    }

    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorReply(id: nil, code: -32700, message: "parse error")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : errorReply(id: id, code: -32600, message: "invalid request")
        }
        if id == nil || method.hasPrefix("notifications/") { return nil }
        switch method {
        case "initialize":
            return reply(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": "1"],
                "instructions": Self.instructions,
            ])
        case "tools/list":
            return reply(id: id, result: ["tools": Self.toolCatalog()])
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            guard Self.callableToolNames.contains(name) else {
                return errorReply(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            if let refusal = Self.unknownArgument(name: name, arguments: arguments) {
                let result = ComputerUseToolResult(text: refusal, isError: true)
                return reply(id: id, result: ["content": result.jsonContent(), "isError": true])
            }
            if name == "run_steps" {
                let result = await runSteps(arguments)
                return reply(id: id, result: ["content": result.jsonContent(), "isError": result.isError])
            }
            if Self.sessionTools.contains(name) {
                let result = await sessions.invoke(name: name, arguments: arguments)
                return reply(id: id, result: ["content": result.jsonContent(), "isError": result.isError])
            }
            if Self.desktopTools.contains(name) || Self.inputTools.contains(name) {
                let tool = Self.desktopTools.contains(name) ? desktop : input
                let pid = Self.targetPID(from: arguments) ?? ComputerUseNativeHostBackend.exactInt32(arguments["pid"])
                do {
                    // `session` drives the overlay and recording only; backends validate their own keys.
                    let toolArguments = arguments.filter { $0.key != "session" }
                    let result = try await queue.withExclusive(kind: Self.recordedTools.contains(name) ? .mutation : .observation, targetPID: pid) {
                        await recorded(name, arguments) { await tool.invoke(name: name, arguments: toolArguments) }
                    }
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": result.isError])
                } catch is CancellationError {
                    return errorReply(id: id, code: -32800, message: "computer-use call cancelled")
                } catch {
                    return errorReply(id: id, code: -32000, message: String(describing: error))
                }
            }
            if ChromeProfileComputerUseBackend.tools.contains(name) {
                let result = await recorded(name, arguments) { await browser.invoke(name: name, arguments: arguments.filter { $0.key != "session" }) }
                return reply(id: id, result: ["content": result.jsonContent(), "isError": result.isError])
            }
            if name == "cua_status" {
                let result = ComputerUseToolResult(text: encode(cua.status()) ?? "{}")
                return reply(id: id, result: ["content": result.jsonContent(), "isError": false])
            }
            let kind: ComputerUseHostQueue.Kind = Self.mutationTools.contains(name) ? .mutation : .observation
            let targetPID = Self.targetPID(from: arguments)
            if name == "run_subtask" {
                guard let target = ComputerUseNativeHostBackend.exactInt32(arguments["target_pid"]),
                      let window = ComputerUseNativeHostBackend.exactUInt32(arguments["target_window_id"]),
                      target > 0, window > 0 else {
                    return errorReply(id: id, code: -32602, message: "target_pid and target_window_id are required")
                }
                let subtask: Subtask
                do {
                    subtask = try Subtask.parse(arguments)
                } catch {
                    let text = SecretRedactor(rawArguments: arguments).redact(String(describing: error))
                    let result = ComputerUseToolResult(text: text, isError: true)
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": true])
                }
                guard jevAvailable() else {
                    let result = ComputerUseToolResult(
                        text: "run_subtask needs OPENROUTER_API_KEY or a Jev key; use jev_decide for LLM-driven steps", isError: true)
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": true])
                }
                let output = await SubtaskRunner(backend: backend, transport: jevTransport, queue: queue).run(
                    target: ComputerUseNativeHostTarget(pid: target, windowID: window), subtask: subtask,
                    dryRun: subtask.dryRun, logPath: arguments["log_path"] as? String)
                let result = ComputerUseToolResult(text: encode(output) ?? "{}")
                return reply(id: id, result: ["content": result.jsonContent(), "isError": false])
            }
            if name == "jev_decide" {
                guard let goal = arguments["goal"] as? String, !goal.isEmpty else {
                    return errorReply(id: id, code: -32602, message: "goal is required")
                }
                if let raw = arguments["browser"],
                   !((raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false) {
                    return errorReply(id: id, code: -32602, message: "browser must be boolean")
                }
                let browserMode = arguments["browser"] as? Bool == true
                var allowedRisks = Set<RiskCategory>()
                var minConfidence = 0.0
                var minMargin = 0.0
                do {
                    if let raw = arguments["allowed_risks"] {
                        guard let names = raw as? [String] else {
                            throw SubtaskError.invalid(field: "allowed_risks", reason: "must be an array of strings")
                        }
                        for name in names {
                            guard let category = RiskCategory(rawValue: name) else {
                                throw SubtaskError.invalid(field: "allowed_risks", reason: "'\(name)' is not one of delete, send, purchase, close")
                            }
                            allowedRisks.insert(category)
                        }
                    }
                    for (field, key) in [("min_confidence", 0), ("min_margin", 1)] {
                        guard let raw = arguments[field] else { continue }
                        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                              number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else {
                            throw SubtaskError.invalid(field: field, reason: "must be a number between 0 and 1")
                        }
                        if key == 0 { minConfidence = number.doubleValue } else { minMargin = number.doubleValue }
                    }
                } catch {
                    let result = ComputerUseToolResult(text: String(describing: error), isError: true)
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": true])
                }
                do {
                    let observation = try await queue.withExclusive(kind: .observation, targetPID: targetPID) {
                        if browserMode { return await browser.invoke(name: "browser_snapshot", arguments: [:]) }
                        return await backend.invoke(name: "get_ui_tree", arguments: arguments.merging(["ocr": "never"]) { _, new in new })
                    }
                    guard !observation.isError, let text = observation.content.first?.text else {
                        return reply(id: id, result: ["content": observation.jsonContent(), "isError": true])
                    }
                    let outputFromModel: [String: Any]
                    if browserMode {
                        guard let data = text.data(using: .utf8),
                              let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw JevDecisionError.invalidObservation
                        }
                        var proposal: [String: Any]
                        if jevAvailable() {
                            proposal = try await jev.adviseBrowser(goal: goal, snapshot: snapshot, allowedRisks: allowedRisks,
                                                                 minConfidence: minConfidence, minMargin: minMargin).jsonObject()
                        } else {
                            proposal = try jev.localBrowserFallback(snapshot: snapshot, allowedRisks: allowedRisks)
                        }
                        proposal["state_token"] = snapshot["state_token"]
                        outputFromModel = proposal
                    } else if jevAvailable() {
                        var image: JevDecision.ImageSource?
                        if let pid = ComputerUseNativeHostBackend.exactInt32(arguments["target_pid"]),
                           let window = ComputerUseNativeHostBackend.exactUInt32(arguments["target_window_id"]) {
                            let backend = backend, queue = queue
                            image = {
                                (try? await queue.withExclusive(kind: .observation, targetPID: pid) {
                                    await DecisionImage.capture(backend, pid: pid, windowID: window)
                                }) ?? (nil, "capture_unavailable")
                            }
                        }
                        outputFromModel = try await jev.advise(
                            goal: goal, observation: text, allowedRisks: allowedRisks,
                            minConfidence: minConfidence, minMargin: minMargin, image: image).jsonObject()
                    } else {
                        outputFromModel = try jev.localFallback(observation: text, allowedRisks: allowedRisks)
                    }
                    var output = outputFromModel
                    if let prefix = text.range(of: "\nui_tree: "),
                       let header = text[..<prefix.lowerBound].data(using: .utf8),
                       let status = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
                       let token = status["state_token"] as? String {
                        output["expected_state_token"] = token
                    }
                    let result = ComputerUseToolResult(text: encode(output) ?? "{}")
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": false])
                } catch {
                    let result = ComputerUseToolResult(text: String(describing: error), isError: true)
                    return reply(id: id, result: ["content": result.jsonContent(), "isError": true])
                }
            }
            do {
                var result = try await queue.withExclusive(kind: kind, targetPID: targetPID) {
                    await recorded(name, arguments) { await backend.invoke(name: name, arguments: arguments) }
                }
                // Callers read rows; the tools inside this server that parse the tree ask the backend directly.
                if name == "get_ui_tree", !result.isError, arguments["format"] as? String != "json", let text = result.content.first?.text {
                    let limit = (arguments["max_elements"] as? NSNumber)?.intValue ?? UITreeRows.defaultMaxElements
                    result.content[0] = .text(UITreeRows.rewrite(result: text, maxElements: limit, query: arguments["query"] as? String))
                }
                if ["get_ui_tree", "screenshot", "doctor"].contains(name), let hint = Self.browserToolsHint(pid: targetPID) {
                    result.content.append(.text(hint))
                }
                return reply(id: id, result: [
                    "content": result.jsonContent(),
                    "isError": result.isError,
                ])
            } catch is CancellationError {
                return errorReply(id: id, code: -32800, message: "computer-use call cancelled")
            } catch {
                return errorReply(id: id, code: -32000, message: String(describing: error))
            }
        default:
            return errorReply(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    /// An argument that is dropped in silence looks like it was honored (a screenshot `width` was).
    static func unknownArgument(name: String, arguments: [String: Any]) -> String? {
        guard let properties = inputSchema(for: name)["properties"] as? [String: Any] else { return nil }
        guard let unknown = arguments.keys.sorted().first(where: { properties[$0] == nil && $0 != "session" }) else { return nil }
        return "unknown argument: \(unknown); accepted: \(properties.keys.sorted().joined(separator: ", "))"
    }

    static let maximumSteps = 32

    /// Several calls in one round trip, stopping at the first that fails, with one read at the end.
    /// Each step goes through tools/call, so it gets the same queue, guards and recording.
    private func runSteps(_ arguments: [String: Any]) async -> ComputerUseToolResult {
        guard let steps = arguments["steps"] as? [[String: Any]], !steps.isEmpty, steps.count <= Self.maximumSteps else {
            return ComputerUseToolResult(text: "steps must be 1 to \(Self.maximumSteps) objects of {tool, arguments}", isError: true)
        }
        var results: [[String: Any]] = []
        var failed: Int?
        for (index, step) in steps.enumerated() {
            guard let tool = step["tool"] as? String, Self.callableToolNames.contains(tool),
                  !["run_steps", "run_subtask", "replay_trajectory"].contains(tool) else {
                results.append(["tool": step["tool"] as? String ?? "", "ok": false, "text": "not a tool that can run as a step"])
                failed = index
                break
            }
            let result = await replayCall(name: tool, arguments: step["arguments"] as? [String: Any] ?? [:])
            let text = result.content.compactMap(\.text).joined(separator: "\n")
            results.append(["tool": tool, "ok": !result.isError, "text": String(text.prefix(1200))])
            if result.isError { failed = index; break }
        }
        var output: [String: Any] = ["completed": failed ?? steps.count, "total": steps.count, "results": results]
        if let failed { output["failed_step"] = failed }
        if let observe = arguments["observe"] as? [String: Any] {
            let read = await replayCall(name: "get_ui_tree", arguments: observe.merging(["ocr": "never"]) { current, _ in current })
            output["observation"] = read.content.compactMap(\.text).joined(separator: "\n")
        }
        return ComputerUseToolResult(text: encode(output) ?? "{}", isError: failed != nil)
    }

    public static func toolCatalog() -> [[String: Any]] {
        advertisedToolNames.map { name in
            var schema = inputSchema(for: name)
            if recordedTools.contains(name), var properties = schema["properties"] as? [String: Any], properties["session"] == nil {
                properties["session"] = ["type": "string", "description": "Session id from start_session; shows its agent cursor and records the turn."]
                schema["properties"] = properties
            }
            return [
                "name": name,
                "description": description(for: name),
                "inputSchema": schema,
            ]
        }
    }

    private static func description(for name: String) -> String {
        switch name {
        case screenshotTool:
            return "Capture the exact target window, scaled to max_image_dimension on its long edge. The result states image_size; click coordinates are pixels of that image, top-left origin."
        case "zoom":
            return "Return an exact integral pixel crop from the target window; crop coordinates and returned image coordinates use a top-left origin."
        case leftClickTool:
            return "Click a screenshot pixel coordinate in the exact target window using Accessibility when hit-testable. If hit testing cannot identify an AX element, uses CGEvent only when that exact target window is already focused; requires a fresh screenshot state token."
        case typeTool:
            return "Type Unicode text into a settable AX-focused element in the exact background target."
        case "right_click":
            return "Right-click a screenshot pixel coordinate in the exact target window; requires a fresh screenshot state token and the exact target window must already be focused."
        case "mouse_move":
            return "Move the pointer to a screenshot pixel coordinate in the exact focused target window; requires a fresh screenshot state token."
        case "scroll":
            return "Scroll at a screenshot pixel coordinate in the exact focused target window using bounded delta_x and delta_y; requires a fresh screenshot state token."
        case "key":
            return "Send one allowlisted key with optional command/control/option/shift modifiers only while the exact target app and window are already focused; requires a fresh state token and never focuses or activates the target."
        case "cursor_position":
            return "Read the current pointer position."
        case "list_windows":
            return "List on-screen windows, optionally filtered by bundle id."
        case "get_ui_tree":
            return "Accessibility tree for a window, one row per element: - [ax_<n>] role \"title\" (description) = \"value\". Use the ax_<n> id with click_element, set_value, click or type_text; it keeps meaning the element you read even if the window changes. Returns max_elements rows (default \(UITreeRows.defaultMaxElements)); pass query to read only what you need. Optional ocr auto, always or never (needs Screen Recording) appends an \"ocr:\" line. Contains private screen text; use jev_decide for redacted decision-model guidance."
        case "jev_decide":
            return "Prefer this cheap decision-model step over reading screenshots yourself. browser:true observes the owned Chrome tab without target_pid/window, sends labels only and proposes browser_act click only, with ref and state_token; never fill. Native mode needs target_pid and target_window_id and sends filtered labels plus the window screenshot (1024 px; none with a secure field; see image_attached). With a key, ask liquid/d1.2-ultra (Jev on fallback; see engine and fallback_reason) for one semantic action, WAIT, DONE, NEEDS_AGENT or BLOCKED, plus runner-up alternatives, risk signals and a BLOCKED reason for the session LLM to weigh. Without a key, return unambiguous labeled candidates for the session LLM to decide; no model call. Neither path posts input. The returned token is checked again before native mutation; labels, goal text and screenshots may contain private information."
        case "run_subtask":
            return "Requires OPENROUTER_API_KEY or a Jev key. Run a bounded loop (max_actions) that observes the window, asks the decision model (liquid/d1.2-ultra, Jev on fallback; no screenshot) for one semantic step (CLICK, SET_VALUE, HOTKEY, WAIT, DONE, BLOCKED or NEEDS_INPUT), executes it natively and reobserves. Literal text comes only from inputs; secret_inputs are typed but never sent to the model or returned. Risky controls (delete, send, purchase, close) are withheld unless in allowed_risks. Stops with SUBTASK_COMPLETE, BLOCKED, NEEDS_INPUT, NEEDS_AGENT or DRY_RUN; stops on human activity."
        case "click_element":
            return "Press an AX element in the exact background target, by element_id (ax_<n> from the get_ui_tree of the observation whose token is passed) or by role and label."
        case "set_value":
            return "Set the AX value of the unique element with this role and label in the exact background target: text for fields and combo boxes, a number for sliders, 0/1 for checkboxes, or an item title for AXPopUpButton (opened and pressed via AX). Optional submit_key ENTER or TAB is posted only if the exact window is already focused (ENTER falls back to AXConfirm). Waits for the UI to settle and returns a fresh observation with settle_ms and settled."
        case "menu_shortcut":
            return "Press the enabled menu bar item bound to a keyboard chord such as MOD+S (MOD=Cmd, CTRL, ALT, SHIFT) via AX, without focusing the window. MOD+A in a focused text field selects all text. Fails with \"no enabled menu item has this shortcut\". Returns a fresh observation with settle_ms and settled."
        case "restore_window":
            return "Explicitly restore and focus the exact PID/window; requires its fresh state token and returns a new observation. Use that new token for subsequent actions."
        case "browser_open":
            return "Open an HTTP(S) URL in a new background tab in the connected Chrome profile, kept rendering while it stays in the background (Chrome shows its debugging bar until browser_close). Always call browser_close on this same connection when finished or on error, before another open."
        case "browser_snapshot":
            return "Read the owned Chrome background tab and obtain fresh element refs; may contain private page text. Pass query to get only the controls you need."
        case "browser_act":
            return "Click, fill, type or scroll in the owned background tab using a fresh snapshot ref. Yields with human_activity if the user selects the tab; confirm consequential actions."
        case "browser_close":
            return "Release the session and best-effort close its tab if it remains inactive and has not been selected by the user. Check closed separately from released, then verify browser_status; release alone is not proof of removal. Chrome cannot make this activity check and removal atomic, so a selection racing with removal may still be closed."
        case "browser_status":
            return "Report whether the Chrome extension is installed, connected and current: state is connected, busy, outdated, not_connected or not_installed, with a hint for the last four. Never fails; answers within 2 seconds."
        case "doctor":
            return "Permission and native-backend diagnostics."
        case "run_steps":
            return "Run up to \(maximumSteps) tool calls in order in one round trip, stopping at the first that fails, then optionally read the window once (observe: the arguments of get_ui_tree). Use it to act and re-read together: steps:[{tool, arguments}]. Step results are text; a step cannot be run_steps, run_subtask or replay_trajectory."
        case "cua_status":
            return "Read-only: report whether the cua CLI is installed and which cua Spaces are registered. When available, prefer a Space via the cua MCP server for tasks that do not need the user's real apps or sessions."
        default:
            return DesktopToolsBackend.description(for: name) ?? InputToolsBackend.description(for: name)
                ?? SessionToolsBackend.description(for: name) ?? ChromeProfileComputerUseBackend.description(for: name) ?? name
        }
    }

    private static func inputSchema(for name: String) -> [String: Any] {
        var targeting: [String: Any] = [
            "target_app": ["type": "string"],
            "target_pid": ["type": "integer"],
            "target_window_id": ["type": "integer"],
            "expected_state_token": ["type": "string"],
        ]
        if mutationTools.contains(name) {
            targeting["allow_while_user_active"] = ChromeProfileComputerUseBackend.allowWhileUserActive
        }
        if let schema = DesktopToolsBackend.inputSchema(for: name) ?? InputToolsBackend.inputSchema(for: name)
            ?? SessionToolsBackend.inputSchema(for: name) ?? ChromeProfileComputerUseBackend.inputSchema(for: name) {
            return schema
        }
        switch name {
        case "browser_open":
            return ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]
        case "browser_act":
            return ["type": "object", "properties": [
                "action": ["type": "string", "enum": ["click", "fill", "type", "scroll"]],
                "ref": ["type": "string"], "text": ["type": "string"],
                "delta_x": ["type": "number"], "delta_y": ["type": "number"],
                "allow_while_user_active": ChromeProfileComputerUseBackend.allowWhileUserActive,
            ], "required": ["action"]]
        case "browser_snapshot":
            return ["type": "object", "properties": [
                "allow_while_user_active": ChromeProfileComputerUseBackend.allowWhileUserActive,
                "query": ["type": "string", "description": "Case-insensitive substring of an element's role, name or value; a|b for alternatives. Returns only matching elements and leaves the page text out."],
            ]]
        case "browser_close", "browser_status", "cua_status":
            return ["type": "object", "properties": [String: Any]()]
        case screenshotTool:
            return [
                "type": "object",
                "properties": targeting.merging([
                    "max_image_dimension": ["type": "integer", "minimum": 0, "description": "Long-edge limit in pixels for the returned image; default \(ComputerUseNativeHostBackend.defaultMaxImageDimension) unless configured, 0 for the native frame."],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id"],
            ]
        case "zoom":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "region": ["type": "array", "description": "Integral [x,y,width,height] pixels in the full window image, top-left origin.", "items": ["type": "integer"]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "region"],
            ]
        case leftClickTool:
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "description": "Pixel coordinates relative to the returned screenshot or zoom image, top-left origin.", "items": ["type": "number"]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "coordinate"],
            ]
        case typeTool:
            return [
                "type": "object",
                "properties": targeting.merging(["text": ["type": "string"]]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "text"],
            ]
        case "click_element":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "role": ["type": "string"],
                    "label": ["type": "string"],
                    "element_id": ["type": "string", "description": "ax_<n> id from get_ui_tree of the observation whose token is passed; use instead of role+label."],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token"],
            ]
        case "set_value":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "role": ["type": "string"],
                    "label": ["type": "string"],
                    "element_id": ["type": "string", "description": "ax_<n> id from get_ui_tree of the observation whose token is passed; use instead of role+label."],
                    "value": ["type": "string"],
                    "submit_key": ["type": "string", "enum": ["ENTER", "TAB"]],
                    "allowed_risks": ["type": "array", "items": ["type": "string", "enum": ["delete", "send", "purchase", "close"]], "description": "When present, refuse a menu item whose title names a risk category not listed."],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "value"],
            ]
        case "menu_shortcut":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "chord": ["type": "string", "description": "Modifiers MOD (Cmd), CTRL, ALT, SHIFT joined by + with one key, e.g. MOD+S or MOD+SHIFT+Z."],
                    "allowed_risks": ["type": "array", "items": ["type": "string", "enum": ["delete", "send", "purchase", "close"]], "description": "When present, refuse a menu item whose title names a risk category not listed."],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "chord"],
            ]
        case "right_click", "mouse_move":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "description": "[x,y] pixels relative to the latest screenshot.", "items": ["type": "number"]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "coordinate"],
            ]
        case "scroll":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "coordinate": ["type": "array", "description": "[x,y] pixels relative to the latest screenshot.", "items": ["type": "number"]],
                    "delta_x": ["type": "number"], "delta_y": ["type": "number"],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "coordinate", "delta_x", "delta_y"],
            ]
        case "key":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "key": ["type": "string", "description": "One allowlisted single-character key or Return, Tab, Space, Delete, Escape, Left, Right, Up, Down."],
                    "modifiers": ["type": "array", "items": ["type": "string", "enum": ["command", "control", "option", "shift"]]],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id", "expected_state_token", "key"],
            ]
        case "restore_window":
            return [
                "type": "object",
                "properties": targeting,
                "required": ["target_pid", "target_window_id", "expected_state_token"],
            ]
        case "list_windows":
            return [
                "type": "object",
                "properties": ["bundle_id": ["type": "string"], "target_app": ["type": "string"]],
            ]
        case "run_steps":
            return [
                "type": "object",
                "properties": [
                    "steps": ["type": "array", "minItems": 1, "maxItems": maximumSteps, "items": [
                        "type": "object", "properties": ["tool": ["type": "string"], "arguments": ["type": "object"]], "required": ["tool"],
                    ]],
                    "observe": ["type": "object", "description": "Arguments for one get_ui_tree read after the steps: target_pid, target_window_id, and optionally query and max_elements."],
                ],
                "required": ["steps"],
            ]
        case "jev_decide":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "browser": ["type": "boolean", "default": false, "description": "Use the owned Chrome tab DOM snapshot; native target not needed. Proposals click only."],
                    "goal": ["type": "string", "description": "Original user goal; sanitized before sending to the decision model."],
                    "allowed_risks": ["type": "array", "items": ["type": "string", "enum": ["delete", "send", "purchase", "close"]], "description": "Risk categories of controls the goal explicitly authorizes; other risky controls are withheld."],
                    "min_confidence": ["type": "number", "description": "0-1; below this the model's answer returns NEEDS_AGENT."],
                    "min_margin": ["type": "number", "description": "0-1; minimum lead over the runner-up choice."],
                ]) { _, new in new },
                "required": ["goal"],
                "anyOf": [["properties": ["browser": ["const": true]], "required": ["browser"]], ["required": ["target_pid", "target_window_id"]]],
            ]
        case "run_subtask":
            return [
                "type": "object",
                "properties": [
                    "target_pid": ["type": "integer"],
                    "target_window_id": ["type": "integer"],
                    "goal": ["type": "string"],
                    "verification": ["type": "array", "items": ["type": "string"], "description": "Criteria that must all be visibly true before SUBTASK_COMPLETE."],
                    "constraints": ["type": "array", "items": ["type": "string"]],
                    "inputs": ["type": "object", "description": "Named literal values (string, number or boolean) the loop may type; the model never invents text."],
                    "max_actions": ["type": "integer", "minimum": 1, "description": "Action budget; default 30."],
                    "shortcuts": ["type": "object", "description": "Extra chords such as {\"MOD+S\": \"Save the document\"} mapped to a description.", "additionalProperties": ["type": "string"]],
                    "allowed_risks": ["type": "array", "items": ["type": "string", "enum": ["delete", "send", "purchase", "close"]]],
                    "secret_inputs": ["type": "array", "items": ["type": "string"], "description": "Keys of inputs whose values are typed but redacted from the model, results and logs."],
                    "min_confidence": ["type": "number"],
                    "min_margin": ["type": "number"],
                    "dry_run": ["type": "boolean", "description": "Stop with DRY_RUN and planned_action after the first validated decision."],
                    "log_path": ["type": "string", "description": "Append one redacted JSONL line per decision."],
                ],
                "required": ["target_pid", "target_window_id", "goal", "verification"],
            ]
        case "get_ui_tree":
            return [
                "type": "object",
                "properties": targeting.merging([
                    "ocr": ["type": "string", "enum": ["auto", "always", "never"]],
                    "query": ["type": "string", "description": "Case-insensitive substring of a role, title, description, value or identifier; a|b for alternatives. Keeps matching rows and their ancestors."],
                    "max_elements": ["type": "integer", "minimum": 1, "maximum": UITreeRows.maximumElements, "default": UITreeRows.defaultMaxElements],
                    "format": ["type": "string", "enum": ["rows", "json"], "default": "rows"],
                ]) { _, new in new },
                "required": ["target_pid", "target_window_id"],
            ]
        case "doctor", "cursor_position":
            return [
                "type": "object",
                "properties": targeting,
                "required": ["target_pid", "target_window_id"],
            ]
        default:
            return [
                "type": "object",
                "properties": targeting,
                "required": ["target_pid", "target_window_id"],
            ]
        }
    }

    /// A page answers DOM refs in a background tab far better than clicks in the Chrome window,
    /// so say so when the caller looks at Chrome and the extension is there to use.
    static func browserToolsHint(pid: Int32?, bundleID: (Int32) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
                                 extensionConnected: () -> Bool = { ChromeProfileConnection.hostListening() }) -> String? {
        guard let pid, bundleID(pid) == "com.google.Chrome", extensionConnected() else { return nil }
        return "hint: the MacCode Chrome extension is connected. For web pages use browser_open and the browser_* tools (own background tab, DOM refs); use this window only for Chrome's own controls."
    }

    private static func targetPID(from arguments: [String: Any]) -> Int32? {
        ComputerUseNativeHostBackend.exactInt32(arguments["target_pid"])
    }

    private func reply(id: Any?, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func errorReply(id: Any?, code: Int, message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
