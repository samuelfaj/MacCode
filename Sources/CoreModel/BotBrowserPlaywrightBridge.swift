import Foundation

/// Errors from the app-owned Playwright bridge. `description` is the bare
/// message because the pending-action mailbox surfaces `String(describing:)`
/// to the bot verbatim (fail loud, never swallow).
public enum BotBrowserPlaywrightBridgeError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }

    public var errorDescription: String? { description }
}

/// Host-action kinds the bridge serves. Mirrors `BotBrowserCatalog` in
/// Persistence (which layers above CoreModel and cannot be imported here);
/// BotBrowserPlaywrightBridgeTests pins these literals against drift.
enum BotBrowserPlaywrightKind {
    static let open = "bot_browser_open"
    static let snapshot = "bot_browser_snapshot"
    static let act = "bot_browser_act"
    /// Live page-state poll for login wait. A host action, never a bot tool.
    static let state = "state"
}

/// Pure mapping between bot_browser_* host actions and the Playwright MCP
/// tool surface (verified live 2026-08-21 against `npx @playwright/mcp@latest`).
public enum BotBrowserPlaywrightTranslator {
    /// `refParameterName` is "target" on current servers and "ref" on older
    /// ones; the child introspects `browser_click.inputSchema` once at
    /// handshake and passes its finding here.
    public static func request(
        kind: String,
        action: String,
        ref: String,
        text: String,
        url: String,
        refParameterName: String
    ) throws -> (name: String, arguments: [String: Any]) {
        switch kind {
        case BotBrowserPlaywrightKind.open:
            return ("browser_navigate", ["url": url])
        case BotBrowserPlaywrightKind.snapshot, BotBrowserPlaywrightKind.state:
            // browser_snapshot requires no properties; its text carries the
            // Page URL / Page Title lines both kinds need.
            return ("browser_snapshot", [:])
        case BotBrowserPlaywrightKind.act:
            switch action {
            case "click":
                return ("browser_click", ["element": "ref \(ref)", refParameterName: ref])
            case "type", "fill":
                return ("browser_type", ["element": "ref \(ref)", refParameterName: ref, "text": text])
            case "scroll":
                return ("browser_press_key", ["key": "PageDown"])
            default:
                throw BotBrowserPlaywrightBridgeError.invalid("action must be click, type, fill, or scroll.")
            }
        default:
            throw BotBrowserPlaywrightBridgeError.invalid("unknown bot browser action kind: \(kind)")
        }
    }

    /// Accepts a full JSON-RPC response or a bare MCP result. Joins the text
    /// content parts; a protocol `error` object or `isError: true` reports
    /// the upstream text verbatim.
    public static func parse(result: [String: Any]) -> (text: String, isError: Bool) {
        if let error = result["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? String(describing: error)
            return (message, true)
        }
        let payload = (result["result"] as? [String: Any]) ?? result
        let parts = (payload["content"] as? [[String: Any]]) ?? []
        let texts = parts.compactMap { part -> String? in
            guard part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }
        return (texts.joined(separator: "\n"), (payload["isError"] as? Bool) ?? false)
    }

    /// Tolerant scan of the `### Page` section: `- Page URL: <url>` /
    /// `- Page Title: <title>`, with or without the leading `- `.
    public static func pageState(fromSnapshotText text: String) -> (url: String?, title: String?) {
        var url: String?
        var title: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                line = String(line.dropFirst(2))
            }
            if url == nil, line.hasPrefix("Page URL:") {
                url = String(line.dropFirst("Page URL:".count)).trimmingCharacters(in: .whitespaces)
            } else if title == nil, line.hasPrefix("Page Title:") {
                title = String(line.dropFirst("Page Title:".count)).trimmingCharacters(in: .whitespaces)
            }
            if url != nil, title != nil { break }
        }
        if url?.isEmpty == true { url = nil }
        if title?.isEmpty == true { title = nil }
        return (url, title)
    }
}

/// One Playwright MCP child (spawn / call / terminate). Class-bound so the
/// host can terminate the same instance it registered.
public protocol BotBrowserPlaywrightChildProcessing: AnyObject {
    /// Introspected once per child at handshake: "target" (current servers)
    /// or "ref" (older servers).
    func resolveRefParameterName() throws -> String
    func call(name: String, arguments: [String: Any]) throws -> [String: Any]
    func terminate()
}

/// Long-lived stdio JSON-RPC child (Zavora forward-backend pattern) with per
/// call read deadlines. On a deadline the child is terminated and the call
/// throws; the next call respawns. Driven only from the host's serial queue.
public final class BotBrowserPlaywrightChild: BotBrowserPlaywrightChildProcessing, @unchecked Sendable {
    private let argv: [String]
    private let environment: [String: String]?
    private let callDeadlineSeconds: TimeInterval
    private var process: Process?
    private var stdin: FileHandle?
    private var lines: LockedLineBuffer?
    private var nextID = 100
    private var refParameterName: String?

    public init(
        argv: [String],
        environment: [String: String]? = nil,
        callDeadlineSeconds: TimeInterval = 60
    ) {
        self.argv = argv
        self.environment = environment
        self.callDeadlineSeconds = max(1, callDeadlineSeconds)
    }

    deinit {
        terminate()
    }

    public func resolveRefParameterName() throws -> String {
        try ensureChild()
        return refParameterName ?? "target"
    }

    public func call(name: String, arguments: [String: Any]) throws -> [String: Any] {
        try ensureChild()
        let id = try send(method: "tools/call", params: ["name": name, "arguments": arguments])
        return try readResponse(id: id)
    }

    public func terminate() {
        process?.terminate()
        process = nil
        try? stdin?.close()
        stdin = nil
        lines = nil
        refParameterName = nil
    }

    private func ensureChild() throws {
        if process?.isRunning == true, stdin != nil, lines != nil {
            return
        }
        terminate()
        guard let executable = argv.first, !executable.isEmpty else {
            throw BotBrowserPlaywrightBridgeError.invalid("Playwright bridge argv is empty.")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = Array(argv.dropFirst())
        if let environment {
            child.environment = environment
        }
        let inPipe = Pipe()
        let outPipe = Pipe()
        child.standardInput = inPipe
        child.standardOutput = outPipe
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            throw BotBrowserPlaywrightBridgeError.invalid(
                "Could not start the Playwright browser (\(executable)): \(error.localizedDescription)"
            )
        }
        process = child
        stdin = inPipe.fileHandleForWriting
        let buffer = LockedLineBuffer()
        lines = buffer
        let reader = outPipe.fileHandleForReading
        // Reader pump keeps the pipe drained; callers poll the buffer with a
        // deadline instead of blocking on FileHandle reads.
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? reader.read(upToCount: 4_096), !chunk.isEmpty {
                buffer.append(chunk)
            }
            buffer.markClosed()
        }
        do {
            let initID = try send(method: "initialize", params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "remotecode-bot-browser", "version": "1"],
            ])
            _ = try readResponse(id: initID)
            _ = try send(method: "notifications/initialized", params: [String: Any](), id: nil)
            // The click/type ref parameter was renamed across server versions
            // (`ref` → `target`); introspect once and cache per child.
            let listID = try send(method: "tools/list", params: [String: Any]())
            refParameterName = Self.refParameterName(fromToolsList: try readResponse(id: listID))
        } catch {
            terminate()
            throw error
        }
    }

    static func refParameterName(fromToolsList response: [String: Any]) -> String {
        let result = (response["result"] as? [String: Any]) ?? response
        let tools = (result["tools"] as? [[String: Any]]) ?? []
        guard let click = tools.first(where: { $0["name"] as? String == "browser_click" }),
              let schema = click["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else {
            return "target"
        }
        return properties["target"] != nil ? "target" : "ref"
    }

    @discardableResult
    private func send(method: String, params: [String: Any], id: Int? = 0) throws -> Int {
        guard let stdin else {
            throw BotBrowserPlaywrightBridgeError.invalid("Playwright browser stdin is closed.")
        }
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        var usedID = 0
        if id != nil {
            nextID += 1
            usedID = nextID
            payload["id"] = usedID
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        do {
            try stdin.write(contentsOf: data)
            try stdin.write(contentsOf: Data("\n".utf8))
        } catch {
            terminate()
            throw BotBrowserPlaywrightBridgeError.invalid(
                "Playwright browser is not reachable: \(error.localizedDescription)"
            )
        }
        return usedID
    }

    private func readResponse(id: Int) throws -> [String: Any] {
        guard let lines else {
            throw BotBrowserPlaywrightBridgeError.invalid("Playwright browser stdout is closed.")
        }
        let deadline = Date().addingTimeInterval(callDeadlineSeconds)
        while Date() < deadline {
            while let line = lines.popLine() {
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                if let value = object["id"] as? NSNumber, value.intValue == id {
                    return object
                }
                // Notification or a response abandoned by an earlier deadline.
            }
            if lines.isClosed {
                terminate()
                throw BotBrowserPlaywrightBridgeError.invalid("Playwright browser exited unexpectedly.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Deadline: kill the wedged child so the next call respawns cleanly.
        terminate()
        throw BotBrowserPlaywrightBridgeError.invalid(
            "Playwright browser did not answer in \(Int(callDeadlineSeconds))s. Try again."
        )
    }
}

private final class LockedLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var closed = false

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        // Bytes already buffered still parse after EOF; closed means drained AND gone.
        return closed && data.firstIndex(of: UInt8(ascii: "\n")) == nil
    }

    func popLine() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = data.subdata(in: data.startIndex..<newline)
        data.removeSubrange(data.startIndex...newline)
        return line
    }
}

/// Router seam: what executes a bot browser action for a resolved route.
/// Tests inject a recorder; the app uses `BotBrowserPlaywrightHost`.
public protocol BotBrowserBridging: Sendable {
    func perform(
        botID: BotID,
        route: BotBrowserRoute,
        kind: String,
        action: String,
        ref: String,
        text: String,
        url: String,
        appSupport: URL
    ) throws -> [String: Any]
}

/// App-owned registry of Playwright MCP children, one per bot + route.
/// `perform` is synchronous-throwing and serializes all child IO on an
/// internal queue — callers hop off the main thread before calling.
public final class BotBrowserPlaywrightHost: BotBrowserBridging, @unchecked Sendable {
    private struct Entry {
        var route: BotBrowserRoute
        var child: any BotBrowserPlaywrightChildProcessing
        var lastUsed: Date
    }

    /// Children idle this long are terminated so deleted or dormant bots do not
    /// keep a Node/Chrome process alive for the life of the app.
    public static let defaultIdleChildTimeout: TimeInterval = 2 * 60 * 60

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.remotecode.bot-browser-playwright")
    private var children: [BotID: Entry] = [:]
    private var lastKnown: [BotID: (url: String, title: String)] = [:]
    private let makeChild: @Sendable ([String], [String: String]?) -> any BotBrowserPlaywrightChildProcessing
    private let resolveNPX: @Sendable () throws -> String
    private let resolveDocker: @Sendable () throws -> String
    private let idleChildTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private var idleSweepTimer: DispatchSourceTimer?

    public init(
        makeChild: @escaping @Sendable ([String], [String: String]?) -> any BotBrowserPlaywrightChildProcessing = { argv, environment in
            BotBrowserPlaywrightChild(argv: argv, environment: environment)
        },
        resolveNPX: @escaping @Sendable () throws -> String = {
            try BotBrowserPlaywrightHost.resolveNPXExecutable()
        },
        resolveDocker: @escaping @Sendable () throws -> String = {
            try BotComputerDockerResolver.resolveSharedHealthyExecutable()
        },
        idleChildTimeout: TimeInterval = BotBrowserPlaywrightHost.defaultIdleChildTimeout,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeChild = makeChild
        self.resolveNPX = resolveNPX
        self.resolveDocker = resolveDocker
        self.idleChildTimeout = idleChildTimeout
        self.now = now
    }

    deinit {
        idleSweepTimer?.cancel()
    }

    /// Terminates every child idle longer than the timeout and forgets its page state.
    public func evictIdleChildren() {
        queue.sync { evictIdleChildrenOnQueue(keeping: nil) }
    }

    private func evictIdleChildrenOnQueue(keeping kept: BotID?) {
        let cutoff = now().addingTimeInterval(-idleChildTimeout)
        lock.lock()
        let idle = children.filter { $0.key != kept && $0.value.lastUsed < cutoff }
        for botID in idle.keys {
            children.removeValue(forKey: botID)
            lastKnown.removeValue(forKey: botID)
        }
        let stillRunning = !children.isEmpty
        lock.unlock()
        for entry in idle.values { entry.child.terminate() }
        if !stillRunning {
            idleSweepTimer?.cancel()
            idleSweepTimer = nil
        }
    }

    /// Runs on `queue`; a periodic sweep exists only while children are alive.
    private func scheduleIdleSweepIfNeeded() {
        guard idleSweepTimer == nil else { return }
        let interval = max(1, min(idleChildTimeout / 4, 10 * 60))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.evictIdleChildrenOnQueue(keeping: nil) }
        idleSweepTimer = timer
        timer.resume()
    }

    public static let npxMissingMessage =
        "Node.js (npx) was not found on this Mac. Install Node 18+ so this bot's Playwright browser can run."

    /// The GUI app's PATH is minimal; scan it plus the usual install homes.
    static func nodeSearchDirectories(
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        var ordered: [String] = []
        func append(_ directory: String) {
            guard !directory.isEmpty, !ordered.contains(directory) else { return }
            ordered.append(directory)
        }
        for directory in pathEnvironment.split(separator: ":") {
            append(String(directory))
        }
        append((homeDirectory as NSString).appendingPathComponent(".local/bin"))
        append("/opt/homebrew/bin")
        append("/usr/local/bin")
        append("/usr/bin")
        return ordered
    }

    public static func resolveNPXExecutable(
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        homeDirectory: String = NSHomeDirectory()
    ) throws -> String {
        try resolveNPXExecutable(
            searchDirectories: nodeSearchDirectories(pathEnvironment: pathEnvironment, homeDirectory: homeDirectory)
        )
    }

    static func resolveNPXExecutable(searchDirectories: [String]) throws -> String {
        for directory in searchDirectories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("npx").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw BotBrowserPlaywrightBridgeError.invalid(npxMissingMessage)
    }

    /// npx is a Node script (`#!/usr/bin/env node`): widen PATH to the same
    /// directories the npx lookup scans or the shebang cannot find node.
    static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        var path = environment["PATH"] ?? ""
        var seen = Set(path.split(separator: ":").map(String.init))
        for directory in nodeSearchDirectories(pathEnvironment: path) where !seen.contains(directory) {
            seen.insert(directory)
            path = path.isEmpty ? directory : path + ":" + directory
        }
        environment["PATH"] = path
        return environment
    }

    /// Per-bot persistent Chrome profile: `<appSupport>/BotBrowsers/<botid>/playwright`.
    public static func localProfileDirectory(appSupport: URL, botID: BotID) -> URL {
        appSupport
            .appendingPathComponent("BotBrowsers", isDirectory: true)
            .appendingPathComponent(botID.value.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("playwright", isDirectory: true)
    }

    /// `--browser chrome` drives the user-installed Google Chrome binary with
    /// the bot's own profile — the bot's browser is a Playwright-driven Chrome.
    public static func localArguments(npxPath: String, profileDirectory: String) -> [String] {
        [
            npxPath, "--yes", "--prefer-offline", "@playwright/mcp@latest",
            "--browser", "chrome",
            "--user-data-dir", profileDirectory,
        ]
    }

    /// Playwright MCP inside the bot's Docker guest, headed on the Xvfb display.
    public static func guestArguments(dockerPath: String, botID: BotID) -> [String] {
        [dockerPath, "exec", "-i", BotComputerGuestSpec.containerName(botID: botID)]
            + BotComputerGuestSpec.playwrightMCPCommand()
    }

    public func perform(
        botID: BotID,
        route: BotBrowserRoute,
        kind: String,
        action: String,
        ref: String,
        text: String,
        url: String,
        appSupport: URL
    ) throws -> [String: Any] {
        if case .refused(let message) = route {
            throw BotBrowserPlaywrightBridgeError.invalid(message)
        }
        return try queue.sync {
            evictIdleChildrenOnQueue(keeping: botID)
            var child = try resolvedChild(botID: botID, route: route, appSupport: appSupport)
            let refParameterName: String
            do {
                refParameterName = try child.resolveRefParameterName()
            } catch let handshakeError {
                // A dead handshake means a dead child: respawn once. The tool call is never retried.
                dropChild(botID: botID)
                child = try resolvedChild(botID: botID, route: route, appSupport: appSupport)
                do {
                    refParameterName = try child.resolveRefParameterName()
                } catch {
                    dropChild(botID: botID)
                    throw handshakeError
                }
            }
            let request = try BotBrowserPlaywrightTranslator.request(
                kind: kind,
                action: action,
                ref: ref,
                text: text,
                url: url,
                refParameterName: refParameterName
            )
            let response: [String: Any]
            do {
                response = try child.call(name: request.name, arguments: request.arguments)
            } catch {
                // Transport failure — drop so the next call respawns.
                dropChild(botID: botID)
                throw error
            }
            let parsed = BotBrowserPlaywrightTranslator.parse(result: response)
            if parsed.isError {
                // Tool-level error (bad ref, navigation failure): the page and
                // child are still healthy; surface the upstream text verbatim.
                throw BotBrowserPlaywrightBridgeError.invalid(parsed.text)
            }
            let page = BotBrowserPlaywrightTranslator.pageState(fromSnapshotText: parsed.text)
            lock.lock()
            var known = lastKnown[botID] ?? (url: "", title: "")
            if let pageURL = page.url {
                known.url = pageURL
                known.title = page.title ?? ""
            } else if let pageTitle = page.title {
                known.title = pageTitle
            }
            lastKnown[botID] = known
            lock.unlock()
            return ["url": known.url, "title": known.title, "content": parsed.text]
        }
    }

    /// Reuse the bot's child while its route is unchanged; a bot has one
    /// browser, so a route flip (kind republished) replaces the child.
    private func resolvedChild(
        botID: BotID,
        route: BotBrowserRoute,
        appSupport: URL
    ) throws -> any BotBrowserPlaywrightChildProcessing {
        lock.lock()
        if let entry = children[botID], entry.route == route {
            children[botID]?.lastUsed = now()
            lock.unlock()
            return entry.child
        }
        let stale = children.removeValue(forKey: botID)
        lock.unlock()
        stale?.child.terminate()

        let argv: [String]
        let environment = Self.childEnvironment()
        switch route {
        case .chromeHost:
            throw BotBrowserPlaywrightBridgeError.invalid("Native Chrome routes must use the composite browser bridge.")
        case .playwrightLocal:
            let npx = try resolveNPX()
            let profile = Self.localProfileDirectory(appSupport: appSupport, botID: botID)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            argv = Self.localArguments(npxPath: npx, profileDirectory: profile.path)
        case .playwrightGuest:
            argv = Self.guestArguments(dockerPath: try resolveDocker(), botID: botID)
        case .refused(let message):
            throw BotBrowserPlaywrightBridgeError.invalid(message)
        }
        let child = makeChild(argv, environment)
        lock.lock()
        children[botID] = Entry(route: route, child: child, lastUsed: now())
        lock.unlock()
        scheduleIdleSweepIfNeeded()
        return child
    }

    private func dropChild(botID: BotID) {
        lock.lock()
        let entry = children.removeValue(forKey: botID)
        lock.unlock()
        entry?.child.terminate()
    }
}
