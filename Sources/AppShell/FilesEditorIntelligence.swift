import Foundation
import Darwin
import AgentRuntime

// MARK: - Editor completions

/// A single editor completion. The engine is pure so the editor popup, the
/// acceptance path and the tests all drive the same values.
struct FileCompletionItem: Equatable {
    enum Kind: Int, Equatable {
        case variable
        case function
        case property
        case type
        case keyword
        case snippet
    }

    let label: String
    let insertText: String
    let kind: Kind
    let detail: String?

    init(_ label: String, insert: String? = nil, kind: Kind, detail: String? = nil) {
        self.label = label
        self.insertText = insert ?? label
        self.kind = kind
        self.detail = detail
    }
}

/// Language-aware word completion for the Files editor.
///
/// Sources, in priority order: keywords and built-in types for the file's
/// language, snippets, then identifiers already present in the document
/// (local symbols). The prefix under the caret filters every source, so the
/// list narrows exactly as the user types.
enum FileCompletionEngine {
    /// UTF-16 range of the identifier immediately before `caret`.
    static func replacementRange(in text: String, caret: Int) -> NSRange? {
        let ns = text as NSString
        let clamped = max(0, min(caret, ns.length))
        var start = clamped
        while start > 0 {
            let scalar = ns.character(at: start - 1)
            guard isIdentifierCharacter(scalar) else { break }
            start -= 1
        }
        guard start < clamped else { return nil }
        return NSRange(location: start, length: clamped - start)
    }

    static func completions(
        in text: String,
        caret: Int,
        language: String?,
        limit: Int = 60
    ) -> [FileCompletionItem] {
        guard let range = replacementRange(in: text, caret: caret) else { return [] }
        let prefix = (text as NSString).substring(with: range).lowercased()
        guard !prefix.isEmpty else { return [] }

        var seen = Set<String>()
        var items: [FileCompletionItem] = []
        func append(_ item: FileCompletionItem) {
            let key = item.insertText
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            items.append(item)
        }

        for item in languageItems(for: language) where item.label.lowercased().hasPrefix(prefix) {
            append(item)
        }
        for item in snippets(for: language) where item.label.lowercased().hasPrefix(prefix) {
            append(item)
        }
        for word in documentWords(in: text, excluding: range)
        where word.count >= 2 && word.lowercased().hasPrefix(prefix) && seen.contains(word) == false {
            append(FileCompletionItem(word, kind: .variable, detail: "Document"))
        }
        return Array(items.prefix(limit))
    }

    /// Inserts `item` over `range`. Returns the new text and the caret offset.
    static func apply(_ item: FileCompletionItem, to text: String, replacing range: NSRange) -> (text: String, caret: Int) {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return (text, range.location) }
        let updated = ns.replacingCharacters(in: range, with: item.insertText)
        return (updated, range.location + (item.insertText as NSString).length)
    }

    static func isIdentifierCharacter(_ scalar: unichar) -> Bool {
        guard let value = Unicode.Scalar(scalar) else { return false }
        return CharacterSet.alphanumerics.contains(value) || value == "_" || value == "$"
    }

    private static func documentWords(in text: String, excluding range: NSRange) -> [String] {
        var words: [String] = []
        var seen = Set<String>()
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .substringNotRequired]) { _, wordRange, _, _ in
            guard NSIntersectionRange(wordRange, range).length == 0 else { return }
            let word = ns.substring(with: wordRange)
            guard word.count >= 2, word.count <= 80,
                  word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }),
                  seen.insert(word).inserted else { return }
            words.append(word)
        }
        return words
    }

    private static func snippets(for language: String?) -> [FileCompletionItem] {
        switch normalized(language) {
        case "swift":
            return [
                FileCompletionItem("guard let", insert: "guard let ", kind: .snippet, detail: "Snippet"),
                FileCompletionItem("if let", insert: "if let ", kind: .snippet, detail: "Snippet"),
                FileCompletionItem("DispatchQueue.main.async", insert: "DispatchQueue.main.async { }", kind: .snippet, detail: "Snippet"),
            ]
        case "typescript", "javascript":
            return [
                FileCompletionItem("console.log", insert: "console.log()", kind: .snippet, detail: "Snippet"),
                FileCompletionItem("describe", insert: "describe(\"\", () => {\n    \n})", kind: .snippet, detail: "Snippet"),
            ]
        case "python":
            return [
                FileCompletionItem("if __name__", insert: "if __name__ == \"__main__\":\n    ", kind: .snippet, detail: "Snippet"),
            ]
        default:
            return []
        }
    }

    static func languageItems(for language: String?) -> [FileCompletionItem] {
        switch normalized(language) {
        case "swift":
            return swiftItems
        case "typescript", "javascript":
            return typeScriptItems
        case "python":
            return pythonItems
        case "go":
            return goItems
        case "rust":
            return rustItems
        default:
            return genericItems
        }
    }

    private static func normalized(_ language: String?) -> String {
        let raw = (language ?? "").lowercased()
        switch raw {
        case "ts", "tsx", "typescriptreact": return "typescript"
        case "js", "jsx", "javascriptreact": return "javascript"
        case "py": return "python"
        case "rs": return "rust"
        case "golang": return "go"
        default: return raw
        }
    }

    private static func keyword(_ word: String) -> FileCompletionItem {
        FileCompletionItem(word, kind: .keyword, detail: "Keyword")
    }

    private static func builtin(_ word: String, _ detail: String) -> FileCompletionItem {
        FileCompletionItem(word, kind: .type, detail: detail)
    }

    private static let swiftItems: [FileCompletionItem] = [
        "func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum",
        "protocol", "extension", "import", "switch", "case", "default", "for", "while",
        "repeat", "break", "continue", "defer", "throws", "rethrows", "try", "catch",
        "async", "await", "actor", "init", "self", "super", "nil", "true", "false",
        "private", "fileprivate", "internal", "public", "open", "static", "mutating",
        "nonisolated", "where", "some", "any", "in", "is", "as", "typealias", "associatedtype",
    ].map { keyword($0) } + [
        builtin("String", "Swift standard library"), builtin("Int", "Swift standard library"),
        builtin("Double", "Swift standard library"), builtin("Bool", "Swift standard library"),
        builtin("Array", "Swift standard library"), builtin("Dictionary", "Swift standard library"),
        builtin("Set", "Swift standard library"), builtin("Optional", "Swift standard library"),
        builtin("Result", "Swift standard library"), builtin("Void", "Swift standard library"),
        builtin("print", "Swift standard library"), builtin("min", "Swift standard library"),
        builtin("max", "Swift standard library"), builtin("abs", "Swift standard library"),
        builtin("Task", "Swift concurrency"), builtin("MainActor", "Swift concurrency"),
    ]

    private static let typeScriptItems: [FileCompletionItem] = [
        "function", "const", "let", "var", "return", "if", "else", "for", "while", "do",
        "switch", "case", "default", "break", "continue", "class", "extends", "implements",
        "interface", "type", "enum", "namespace", "import", "export", "from", "as", "new",
        "this", "super", "try", "catch", "finally", "throw", "async", "await", "yield",
        "static", "readonly", "public", "private", "protected", "abstract", "declare",
        "typeof", "instanceof", "keyof", "in", "of", "true", "false", "null", "undefined",
    ].map { keyword($0) } + [
        builtin("console", "JavaScript global"), builtin("Promise", "JavaScript built-in"),
        builtin("Array", "JavaScript built-in"), builtin("Object", "JavaScript built-in"),
        builtin("String", "JavaScript built-in"), builtin("Number", "JavaScript built-in"),
        builtin("Boolean", "JavaScript built-in"), builtin("JSON", "JavaScript built-in"),
        builtin("Map", "JavaScript built-in"), builtin("Set", "JavaScript built-in"),
        builtin("Date", "JavaScript built-in"), builtin("Error", "JavaScript built-in"),
        builtin("document", "Browser global"), builtin("window", "Browser global"),
    ]

    private static let pythonItems: [FileCompletionItem] = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue",
        "import", "from", "as", "try", "except", "finally", "raise", "with", "pass", "lambda",
        "yield", "async", "await", "global", "nonlocal", "assert", "del", "in", "is", "not",
        "and", "or", "None", "True", "False", "self",
    ].map { keyword($0) } + [
        builtin("print", "Python built-in"), builtin("len", "Python built-in"),
        builtin("range", "Python built-in"), builtin("enumerate", "Python built-in"),
        builtin("str", "Python built-in"), builtin("int", "Python built-in"),
        builtin("float", "Python built-in"), builtin("list", "Python built-in"),
        builtin("dict", "Python built-in"), builtin("set", "Python built-in"),
        builtin("tuple", "Python built-in"), builtin("Exception", "Python built-in"),
    ]

    private static let goItems: [FileCompletionItem] = [
        "func", "var", "const", "type", "struct", "interface", "package", "import", "return",
        "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go",
        "defer", "select", "chan", "map", "make", "new", "nil", "true", "false", "fallthrough",
    ].map { keyword($0) } + [
        builtin("fmt", "Go standard library"), builtin("error", "Go built-in"),
        builtin("string", "Go built-in"), builtin("int", "Go built-in"),
        builtin("bool", "Go built-in"), builtin("byte", "Go built-in"),
    ]

    private static let rustItems: [FileCompletionItem] = [
        "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "mod", "use",
        "pub", "crate", "self", "super", "return", "if", "else", "match", "for", "while", "loop",
        "break", "continue", "move", "ref", "as", "in", "where", "async", "await", "dyn",
        "Some", "None", "Ok", "Err", "true", "false",
    ].map { keyword($0) } + [
        builtin("String", "Rust standard library"), builtin("Vec", "Rust standard library"),
        builtin("Option", "Rust standard library"), builtin("Result", "Rust standard library"),
        builtin("println!", "Rust macro"), builtin("format!", "Rust macro"),
    ]

    private static let genericItems: [FileCompletionItem] = [
        "return", "if", "else", "for", "while", "function", "class", "const", "var",
    ].map { keyword($0) }
}

// MARK: - AI inline completion

/// Everything the completion prompt needs. Captured on the main actor at the
/// caret so the provider sees a stable snapshot of the document.
struct InlineCompletionRequest: Equatable, Sendable {
    let path: String
    let language: String?
    let prefix: String
    let suffix: String
    /// Characters before the caret, enough for local context.
    static let contextLimit = 4_000

    init(path: String, language: String?, text: String, caret: Int) {
        self.path = path
        self.language = language
        let ns = (text as NSString)
        let clamped = max(0, min(caret, ns.length))
        let start = max(0, clamped - Self.contextLimit)
        self.prefix = ns.substring(with: NSRange(location: start, length: clamped - start))
        let end = min(ns.length, clamped + Self.contextLimit)
        self.suffix = ns.substring(with: NSRange(location: clamped, length: end - clamped))
    }

    var prompt: String {
        let languageName = (language?.isEmpty == false ? language! : "plain text")
        return """
        You are an inline code completion engine inside a macOS code editor.
        Complete the code at the <cursor> marker. Reply with ONLY the characters to insert at the cursor.
        Do not repeat the prefix, do not add markdown fences, do not explain.
        Complete the current statement or block; at most 8 lines.

        File: \((path as NSString).lastPathComponent)
        Language: \(languageName)
        <prefix>\(prefix)</prefix><cursor/><suffix>\(suffix)</suffix>
        """
    }
}

protocol InlineCompletionProviding: Sendable {
    func complete(_ request: InlineCompletionRequest) async throws -> String?
}

enum InlineCompletionError: Error, Equatable {
    case timedOut
    case unavailable
    case empty
}

/// Distill-backed inline completion.
///
/// The provider is a thin, testable shell around one transport closure: it
/// enforces the timeout, normalizes the model output and rejects anything
/// that would duplicate existing text at the caret. The editor never mutates
/// the document from here; it only stores the returned string as ghost text.
final class DistillInlineCompletionProvider: InlineCompletionProviding {
    typealias Transport = @Sendable (String) async throws -> String

    let timeout: TimeInterval
    private let transport: Transport

    init(timeout: TimeInterval = 2.5, transport: @escaping Transport) {
        self.timeout = timeout
        self.transport = transport
    }

    func complete(_ request: InlineCompletionRequest) async throws -> String? {
        let raw = try await withTimeout(timeout) { [transport] in
            try await transport(request.prompt)
        }
        return Self.sanitize(raw, prefix: request.prefix, suffix: request.suffix)
    }

    /// Strips markdown fences, reasoning preambles and duplicated context.
    /// Returns nil when nothing safe remains.
    static func sanitize(_ raw: String, prefix: String, suffix: String) -> String? {
        var text = raw
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let lastFence = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
                lines.removeSubrange(lastFence..<lines.count)
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A model that echoes the tail of the prefix would duplicate text.
        if !prefix.isEmpty, text.hasPrefix(prefix.suffix(min(60, prefix.count))) {
            text = String(text.dropFirst(min(60, prefix.count)))
        }
        // Drop a completion that only repeats what already follows the caret.
        if !suffix.isEmpty, suffix.hasPrefix(text) {
            return nil
        }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500 else { return nil }
        return text
    }

    /// Production provider: one headless Distill turn, text deltas only.
    static func distillCLI(binary: String? = nil) -> DistillInlineCompletionProvider {
        let resolved = binary ?? resolveDistillBinary()
        return DistillInlineCompletionProvider { prompt in
            try await DistillCLIInlineCompletionTransport(binary: resolved).send(prompt: prompt)
        }
    }

    static func resolveDistillBinary() -> String {
        let environment = ProcessInfo.processInfo.environment
        return DistillProvisioner.resolveInstalledBinary(
            override: nil,
            environmentPath: environment["PATH"]
        ) ?? "distill"
    }
}

/// Runs the installed `distill` CLI in its headless streaming-json mode and
/// concatenates `text` deltas. This is the same output format the agent
/// runtime consumes; completion only needs the assistant text.
struct DistillCLIInlineCompletionTransport: Sendable {
    let binary: String
    var model: String = "auto"

    func send(prompt: String) async throws -> String {
        let owner = InlineCompletionProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try run(prompt: prompt, owner: owner))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            owner.cancel()
        }
    }

    private func run(prompt: String, owner: InlineCompletionProcess) throws -> String {
        let process = owner.process
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-p", prompt,
            "--output-format", "streaming-json",
            "--model", model,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["RC2_INLINE_COMPLETION"] = "1"
        process.environment = environment
        defer { owner.cancel() }
        do {
            try owner.start()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InlineCompletionError.unavailable
        }
        try? stdout.fileHandleForWriting.close()
        let handle = stdout.fileHandleForReading
        defer { try? handle.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        while true {
            try owner.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw InlineCompletionError.timedOut }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 20)
            if ready < 0 { throw InlineCompletionError.unavailable }
            if ready == 0 {
                if !process.isRunning { break }
                continue
            }
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            guard data.count + count <= 1_048_576 else { throw InlineCompletionError.unavailable }
            data.append(contentsOf: bytes.prefix(count))
        }
        while process.isRunning {
            try owner.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw InlineCompletionError.timedOut }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InlineCompletionError.unavailable }
        let output = String(data: data, encoding: .utf8) ?? ""
        var text = ""
        for line in output.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["type"] as? String == "text",
                  let delta = object["data"] as? String else { continue }
            text += delta
        }
        guard !text.isEmpty else { throw InlineCompletionError.empty }
        return text
    }
}

private final class InlineCompletionProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var processGroup: Int32?

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        let pid = process.processIdentifier
        _ = setpgid(pid, 0)
        guard getpgid(pid) == pid, pid != getpgrp() else {
            process.terminate()
            throw InlineCompletionError.unavailable
        }
        processGroup = pid
    }

    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        guard let processGroup else { return }
        _ = kill(-processGroup, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            _ = kill(-processGroup, SIGKILL)
        }
    }
}

private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw InlineCompletionError.timedOut
        }
        guard let result = try await group.next() else { throw InlineCompletionError.timedOut }
        group.cancelAll()
        return result
    }
}
