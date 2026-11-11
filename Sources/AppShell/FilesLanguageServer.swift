import CoreModel
import Foundation

struct LSPPosition: Equatable, Sendable {
    var line: Int
    var character: Int
}

struct LSPRange: Equatable, Sendable {
    var start: LSPPosition
    var end: LSPPosition
}

struct LSPCompletionItem: Equatable, Sendable {
    var label: String
    var kind: Int?
    var detail: String?
    var documentation: String?
    var insertText: String
    var filterText: String?
    var sortText: String?
    var replaceRange: LSPRange?
}

struct LSPDiagnostic: Equatable, Sendable {
    var range: LSPRange
    var severity: Int
    var message: String
    var source: String?
}

enum LanguageServerError: Error, Equatable {
    case notRunning, timedOut, serverError(code: Int, message: String), launchFailed
}

enum LanguageServerRegistry {
    private static let servers: [String: [[String]]] = [
        "swift": [["sourcekit-lsp"]],
        "ts": [["typescript-language-server", "--stdio"]],
        "py": [["pyright-langserver", "--stdio"], ["pylsp"]],
        "go": [["gopls"]],
        "rs": [["rust-analyzer"]],
        "c": [["clangd"]],
    ]

    /// Returns argv for the first installed server for this file, or nil.
    static func command(forPath path: String, language: String?, searchPath: [String] = defaultSearchPath) -> [String]? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard let family = family(forExtension: ext) ?? family(forLanguage: language) else { return nil }
        for candidate in servers[family] ?? [] {
            if let exe = resolve(candidate[0], in: searchPath) {
                return [exe] + Array(candidate.dropFirst())
            }
        }
        return nil
    }

    static func languageID(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "ts": return "typescript"
        case "tsx": return "typescriptreact"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "javascriptreact"
        case "py": return "python"
        case "go": return "go"
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cpp", "cc", "hpp": return "cpp"
        case "m", "mm": return "objective-c"
        default: return "plaintext"
        }
    }

    static var defaultSearchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fromEnv = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return fromEnv + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", home + "/.cargo/bin", home + "/.local/bin", home + "/go/bin"]
    }

    private static func family(forExtension ext: String) -> String? {
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return "ts"
        case "py": return "py"
        case "go": return "go"
        case "rs": return "rs"
        case "c", "h", "cpp", "cc", "hpp", "m", "mm": return "c"
        default: return nil
        }
    }

    private static func family(forLanguage language: String?) -> String? {
        switch language {
        case "swift": return "swift"
        case "typescript", "typescriptreact", "javascript", "javascriptreact": return "ts"
        case "python": return "py"
        case "go": return "go"
        case "rust": return "rs"
        case "c", "cpp", "objective-c": return "c"
        default: return nil
        }
    }

    private static func resolve(_ name: String, in searchPath: [String]) -> String? {
        for dir in searchPath {
            let full = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }
}

/// PIDs of language servers still running. Read synchronously at app exit.
private final class LanguageServerProcessRegistry: @unchecked Sendable {
    static let shared = LanguageServerProcessRegistry()
    private let lock = NSLock()
    private var pids = Set<pid_t>()

    func insert(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.insert(pid)
    }

    func remove(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.remove(pid)
    }

    func terminateAll() {
        lock.lock()
        let running = pids
        pids = []
        lock.unlock()
        for pid in running { kill(pid, SIGTERM) }
    }
}

/// One server process. Thread-safe via `actor`.
actor LanguageServerClient {
    private let command: [String]
    private let rootPath: String
    private var process: Process?
    private var stdin: FileHandle?
    private var pid: pid_t?
    private var alive = false
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var diagnosticsHandlers: [UUID: @Sendable (String, [LSPDiagnostic]) -> Void] = [:]
    private var openCounts: [String: Int] = [:]
    private var versions: [String: Int] = [:]
    private let stdinQueue = DispatchQueue(label: "files.lsp.stdin")

    init(command: [String], rootPath: String) {
        self.command = command
        self.rootPath = rootPath
    }

    var isRunning: Bool { alive }

    /// Spawns the process, sends `initialize` (rootUri, workspaceFolders, capabilities with
    /// textDocument.completion.completionItem.snippetSupport=false, hover contentFormat ["plaintext","markdown"],
    /// publishDiagnostics, synchronization didSave), waits for the result, sends `initialized`.
    func start() async throws {
        if alive { return }
        guard let exe = command.first else { throw LanguageServerError.launchFailed }
        let p = Process()
        if exe.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = Array(command.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = command
        }
        p.currentDirectoryURL = URL(fileURLWithPath: rootPath)
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        p.terminationHandler = { [weak self] _ in
            Task { await self?.handleExit() }
        }
        let reader = LSPFrameReader()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let bodies = reader.feed(data)
            if !bodies.isEmpty { Task { await self?.receive(bodies) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        do {
            try p.run()
        } catch {
            throw LanguageServerError.launchFailed
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = p
        pid = p.processIdentifier
        LanguageServerProcessRegistry.shared.insert(p.processIdentifier)
        stdin = input.fileHandleForWriting
        alive = true
        do {
            _ = try await request("initialize", initializeParams(), timeout: 20)
        } catch {
            abort()
            throw error
        }
        notify("initialized", [:])
    }

    /// Sends didOpen only for the first open of `path`; later opens only bump the count.
    func didOpen(path: String, languageID: String, version: Int, text: String) async {
        guard alive else { return }
        let uri = Self.uri(path)
        let count = openCounts[uri, default: 0]
        openCounts[uri] = count + 1
        guard count == 0 else { return }
        versions[uri] = version
        notify("textDocument/didOpen", [
            "textDocument": ["uri": uri, "languageId": languageID, "version": version, "text": text],
        ])
    }

    /// Full-text change with this client's own per-path version counter.
    func didChange(path: String, text: String) async {
        let uri = Self.uri(path)
        guard alive, openCounts[uri] != nil else { return }
        let version = versions[uri, default: 0] + 1
        versions[uri] = version
        notify("textDocument/didChange", [
            "textDocument": ["uri": uri, "version": version],
            "contentChanges": [["text": text]],
        ])
    }

    /// Sends didClose only when the last opener closes `path`.
    func didClose(path: String) async {
        guard alive else { return }
        let uri = Self.uri(path)
        guard let count = openCounts[uri] else { return }
        if count > 1 {
            openCounts[uri] = count - 1
            return
        }
        openCounts[uri] = nil
        versions[uri] = nil
        notify("textDocument/didClose", ["textDocument": ["uri": uri]])
    }

    func completion(path: String, position: LSPPosition) async throws -> [LSPCompletionItem] {
        let result = try await request("textDocument/completion", Self.textDocumentPosition(path, position), timeout: 5)
        return Self.parseCompletion(result)
    }

    func hover(path: String, position: LSPPosition) async throws -> String? {
        let result = try await request("textDocument/hover", Self.textDocumentPosition(path, position), timeout: 5)
        let contents = (result as? [String: Any])?["contents"]
        return Self.nonEmpty(Self.plainText(contents))
    }

    /// Adds a diagnostics subscriber. Pass the returned id to `removeDiagnosticsHandler`.
    func addDiagnosticsHandler(_ handler: @escaping @Sendable (_ path: String, _ diagnostics: [LSPDiagnostic]) -> Void) -> UUID {
        let id = UUID()
        diagnosticsHandlers[id] = handler
        return id
    }

    func removeDiagnosticsHandler(_ id: UUID) {
        diagnosticsHandlers[id] = nil
    }

    func setDiagnosticsHandler(_ handler: @escaping @Sendable (_ path: String, _ diagnostics: [LSPDiagnostic]) -> Void) {
        diagnosticsHandlers = [:]
        _ = addDiagnosticsHandler(handler)
    }

    /// `shutdown` request then `exit` notification, then terminate the process if still running after 1 s.
    func shutdown() async {
        guard alive, let p = process else { return }
        _ = try? await request("shutdown", [:], timeout: 5)
        send(["jsonrpc": "2.0", "method": "exit"])
        for _ in 0..<10 where p.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if p.isRunning { p.terminate() }
        handleExit()
    }

    private func initializeParams() -> [String: Any] {
        let uri = URL(fileURLWithPath: rootPath).absoluteString
        return [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootPath": rootPath,
            "rootUri": uri,
            "workspaceFolders": [["uri": uri, "name": (rootPath as NSString).lastPathComponent]],
            "capabilities": [
                "workspace": ["configuration": true, "workspaceFolders": true],
                "textDocument": [
                    "synchronization": ["didSave": true],
                    "completion": ["completionItem": ["snippetSupport": false]],
                    "hover": ["contentFormat": ["plaintext", "markdown"]],
                    "publishDiagnostics": [String: Any](),
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ message: [String: Any]) {
        guard alive, let stdin, let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        // Writes run off the actor so a full pipe cannot block it. The handle is retained until the write ends.
        let handle = stdin
        stdinQueue.async { [weak self] in
            if !Self.writeAll(frame, to: handle.fileDescriptor) {
                Task { await self?.abort() }
            }
        }
    }

    /// Blocking write on the stdin queue. False on EPIPE, EBADF or any other error.
    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                base += n
                remaining -= n
            }
            return true
        }
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> Any? {
        guard alive else { throw LanguageServerError.notRunning }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            pending[id] = continuation
            timers[id] = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                await self?.expire(id)
            }
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    private func expire(_ id: Int) {
        timers.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: LanguageServerError.timedOut)
    }

    private func receive(_ bodies: [Data]) {
        for body in bodies {
            guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            if let id = message["id"] {
                reply(to: message, id: id, method: method)
            } else if method == "textDocument/publishDiagnostics" {
                publish(message["params"] as? [String: Any])
            }
            return
        }
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        if let error = message["error"] as? [String: Any] {
            continuation.resume(throwing: LanguageServerError.serverError(
                code: error["code"] as? Int ?? 0,
                message: error["message"] as? String ?? ""
            ))
        } else {
            let result = message["result"]
            continuation.resume(returning: result is NSNull ? nil : result)
        }
    }

    private func reply(to message: [String: Any], id: Any, method: String) {
        switch method {
        case "workspace/configuration":
            let count = ((message["params"] as? [String: Any])?["items"] as? [Any])?.count ?? 0
            send(["jsonrpc": "2.0", "id": id, "result": Array(repeating: NSNull(), count: count)])
        case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability":
            send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func publish(_ params: [String: Any]?) {
        guard let params, let uri = params["uri"] as? String, let path = URL(string: uri)?.path else { return }
        let items = params["diagnostics"] as? [[String: Any]] ?? []
        let diagnostics = items.compactMap { Self.parseDiagnostic($0) }
        for handler in diagnosticsHandlers.values { handler(path, diagnostics) }
    }

    private func abort() {
        process?.terminate()
        handleExit()
    }

    private func handleExit() {
        alive = false
        if let pid { LanguageServerProcessRegistry.shared.remove(pid) }
        pid = nil
        process = nil
        stdin = nil
        openCounts = [:]
        versions = [:]
        for timer in timers.values { timer.cancel() }
        timers = [:]
        let failed = pending
        pending = [:]
        for continuation in failed.values {
            continuation.resume(throwing: LanguageServerError.notRunning)
        }
    }

    private static func uri(_ path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    private static func textDocumentPosition(_ path: String, _ position: LSPPosition) -> [String: Any] {
        [
            "textDocument": ["uri": uri(path)],
            "position": ["line": position.line, "character": position.character],
        ]
    }

    private static func parseCompletion(_ result: Any?) -> [LSPCompletionItem] {
        let raw: [[String: Any]]
        if let array = result as? [[String: Any]] {
            raw = array
        } else if let list = result as? [String: Any], let items = list["items"] as? [[String: Any]] {
            raw = items
        } else {
            return []
        }
        return raw.compactMap { parseCompletionItem($0) }
    }

    private static func parseCompletionItem(_ item: [String: Any]) -> LSPCompletionItem? {
        guard let label = item["label"] as? String else { return nil }
        let edit = item["textEdit"] as? [String: Any]
        let newText = (edit?["newText"] as? String) ?? (item["insertText"] as? String) ?? label
        let replaceObject = (edit?["range"] ?? edit?["replace"]) as? [String: Any]
        return LSPCompletionItem(
            label: label,
            kind: item["kind"] as? Int,
            detail: item["detail"] as? String,
            documentation: plainText(item["documentation"]),
            insertText: (item["insertTextFormat"] as? Int) == 2 ? stripSnippet(newText) : newText,
            filterText: item["filterText"] as? String,
            sortText: item["sortText"] as? String,
            replaceRange: replaceObject.flatMap { parseRange($0) }
        )
    }

    private static func parseDiagnostic(_ item: [String: Any]) -> LSPDiagnostic? {
        guard let range = (item["range"] as? [String: Any]).flatMap({ parseRange($0) }),
              let message = item["message"] as? String else { return nil }
        return LSPDiagnostic(
            range: range,
            severity: item["severity"] as? Int ?? 1,
            message: message,
            source: item["source"] as? String
        )
    }

    private static func parseRange(_ object: [String: Any]) -> LSPRange? {
        guard let start = parsePosition(object["start"]), let end = parsePosition(object["end"]) else { return nil }
        return LSPRange(start: start, end: end)
    }

    private static func parsePosition(_ value: Any?) -> LSPPosition? {
        guard let object = value as? [String: Any],
              let line = object["line"] as? Int,
              let character = object["character"] as? Int else { return nil }
        return LSPPosition(line: line, character: character)
    }

    /// MarkupContent / string / MarkedString / array -> joined plain text.
    private static func plainText(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let array = value as? [Any] {
            let parts = array.compactMap { plainText($0) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        if let object = value as? [String: Any], let text = object["value"] as? String { return text }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func stripSnippet(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\$\{\d+:([^}]*)\}"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\$\{\d+\}|\$\d+"#, with: "", options: .regularExpression)
    }
}

/// Shares one client per (rootPath, argv) and starts it lazily, single-flight.
/// Each `client` call takes a lease; pair it with `release`. The last release stops the server.
actor LanguageServerPool {
    static let shared = LanguageServerPool()

    private struct Entry {
        let id: UUID
        let task: Task<LanguageServerClient, Error>
        var leases: Int
    }

    private var clients: [String: Entry] = [:]

    /// Synchronous SIGTERM for every running server. Used at app exit, where async shutdown cannot finish.
    static func terminateAllProcessesNow() {
        LanguageServerProcessRegistry.shared.terminateAll()
    }

    func client(command: [String], rootPath: String) async throws -> LanguageServerClient {
        let key = Self.key(command: command, rootPath: rootPath)
        var attempts = 0
        while true {
            let entry: Entry
            if let existing = clients[key] {
                entry = existing
            } else {
                let task = Task { () throws -> LanguageServerClient in
                    let client = LanguageServerClient(command: command, rootPath: rootPath)
                    try await client.start()
                    return client
                }
                entry = Entry(id: UUID(), task: task, leases: 0)
                clients[key] = entry
            }
            clients[key]?.leases += 1
            do {
                let client = try await entry.task.value
                if await client.isRunning { return client }
            } catch {
                if clients[key]?.id == entry.id { clients[key] = nil }
                throw error
            }
            // Dead server: drop it once. Callers that raced here see a new id and wait on that entry.
            if clients[key]?.id == entry.id { clients[key] = nil }
            attempts += 1
            guard attempts < 2 else { throw LanguageServerError.notRunning }
        }
    }

    /// Drops one lease. The last lease stops the server and removes it from the pool.
    func release(command: [String], rootPath: String) async {
        let key = Self.key(command: command, rootPath: rootPath)
        guard var entry = clients[key] else { return }
        entry.leases -= 1
        guard entry.leases <= 0 else {
            clients[key] = entry
            return
        }
        clients[key] = nil
        if let client = try? await entry.task.value { await client.shutdown() }
    }

    func shutdownAll() async {
        let all = clients.values.map(\.task)
        clients = [:]
        for task in all {
            if let client = try? await task.value { await client.shutdown() }
        }
    }

    private static func key(command: [String], rootPath: String) -> String {
        rootPath + "\u{0}" + command.joined(separator: "\u{0}")
    }
}

/// UTF-16 offset <-> LSP position helpers (pure, nonisolated).
enum LSPText {
    static func position(forUTF16Offset offset: Int, in text: String) -> LSPPosition {
        var line = 0
        var character = 0
        var index = 0
        for unit in text.utf16 {
            if index >= offset { break }
            if unit == 10 {
                line += 1
                character = 0
            } else {
                character += 1
            }
            index += 1
        }
        return LSPPosition(line: line, character: character)
    }

    static func utf16Offset(for position: LSPPosition, in text: String) -> Int {
        let units = Array(text.utf16)
        var index = 0
        var currentLine = 0
        while currentLine < position.line && index < units.count {
            if units[index] == 10 { currentLine += 1 }
            index += 1
        }
        if currentLine < position.line { return units.count }
        var column = 0
        while column < position.character && index < units.count && units[index] != 10 {
            index += 1
            column += 1
        }
        return index
    }
}

/// Incremental Content-Length framing. Used only from one readability callback at a time.
private final class LSPFrameReader: @unchecked Sendable {
    private var buffer = Data()

    func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var bodies: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first
            guard let length else {
                buffer = Data(buffer[headerEnd.upperBound...])
                continue
            }
            let end = headerEnd.upperBound + length
            guard end <= buffer.endIndex else { break }
            bodies.append(Data(buffer[headerEnd.upperBound..<end]))
            buffer = Data(buffer[end...])
        }
        return bodies
    }
}
