import Foundation

/// How a provider tool call changed a file. Reads never produce a touch.
public enum FileTouchKind: String, Codable, Sendable, CaseIterable {
    case edit, delete, move, write
}

public struct ProviderFileTouch: Codable, Sendable, Equatable {
    public let path: String
    public let kind: FileTouchKind

    public init(path: String, kind: FileTouchKind) {
        self.path = path
        self.kind = kind
    }
}

/// Pure per-provider parsers for the files a tool call edits, plus the
/// `ProviderRuntimeEvent` envelope the adapters use to hand them to the host.
/// The host consumes the envelope before persistence, so it never reaches
/// stored transcripts or paired devices.
public enum ProviderFileTouchParser {
    public static let runtimeSource = "rc.file_touch"
    public static let runtimeMethod = "rc.file_touch"

    private static let claudeKinds: [String: FileTouchKind] = [
        "edit": .edit, "multiedit": .edit, "notebookedit": .edit, "write": .write,
    ]

    /// Claude Edit / MultiEdit / NotebookEdit / Write. Other tools (Read, Grep, Bash, MCP) touch nothing.
    public static func claude(toolName: String?, input: [String: Any]?) -> [ProviderFileTouch] {
        let normalized = (toolName ?? "").lowercased().replacingOccurrences(of: "_", with: "")
        guard let kind = claudeKinds[normalized], let input else { return [] }
        for key in ["file_path", "notebook_path", "path"] {
            if let path = nonEmpty(input[key] as? String) { return [ProviderFileTouch(path: path, kind: kind)] }
        }
        return []
    }

    /// ACP `tool_call` / `tool_call_update`: `kind` plus `locations[].path`, falling back to the
    /// raw input path when the agent sends no locations. Only edit/delete/move/write kinds count.
    public static func distillACP(_ update: [String: Any]) -> [ProviderFileTouch] {
        guard let raw = update["kind"] as? String, let kind = FileTouchKind(rawValue: raw.lowercased()) else { return [] }
        if let status = update["status"] as? String, ["failed", "cancelled"].contains(status) { return [] }
        var paths = (update["locations"] as? [[String: Any]] ?? []).compactMap { nonEmpty($0["path"] as? String) }
        if paths.isEmpty, let input = update["rawInput"] as? [String: Any] {
            paths = ["file_path", "path"].compactMap { nonEmpty(input[$0] as? String) }.prefix(1).map { $0 }
        }
        return unique(paths).map { ProviderFileTouch(path: $0, kind: kind) }
    }

    /// Codex `fileChange` item: `changes[]` of `{path, kind: add|update|delete (+move_path)}`.
    public static func codex(item: [String: Any]) -> [ProviderFileTouch] {
        let type = (item["type"] as? String ?? "").lowercased().replacingOccurrences(of: "_", with: "")
        guard type == "filechange" else { return [] }
        if let status = (item["status"] as? String)?.lowercased(),
           ["declined", "failed", "cancelled", "canceled"].contains(status) { return [] }
        var touches: [ProviderFileTouch] = []
        for change in item["changes"] as? [[String: Any]] ?? [] {
            guard let path = nonEmpty(change["path"] as? String) ?? nonEmpty(change["file"] as? String) else { continue }
            let kindObject = change["kind"] as? [String: Any]
            let rawKind = (kindObject?["type"] as? String ?? change["kind"] as? String ?? "update").lowercased()
            if let moved = nonEmpty(kindObject?["move_path"] as? String) ?? nonEmpty(kindObject?["movePath"] as? String) {
                touches.append(ProviderFileTouch(path: path, kind: .move))
                touches.append(ProviderFileTouch(path: moved, kind: .move))
                continue
            }
            switch rawKind {
            case "add": touches.append(ProviderFileTouch(path: path, kind: .write))
            case "delete": touches.append(ProviderFileTouch(path: path, kind: .delete))
            default: touches.append(ProviderFileTouch(path: path, kind: .edit))
            }
        }
        return touches
    }

    public static func runtimeEvent(
        provider: AgentProvider,
        touches: [ProviderFileTouch],
        itemId: String? = nil,
        receivedAtMs: Int64
    ) -> AssistantEvent? {
        guard !touches.isEmpty,
              let data = try? JSONEncoder().encode(touches),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return .providerRuntime(ProviderRuntimeEvent(
            provider: provider,
            source: runtimeSource,
            method: runtimeMethod,
            providerItemId: itemId,
            payloadJSON: json,
            receivedAtMs: receivedAtMs
        ))
    }

    /// The touches carried by a file-touch envelope; nil for every other runtime event.
    public static func touches(in event: ProviderRuntimeEvent) -> [ProviderFileTouch]? {
        guard event.method == runtimeMethod, event.source == runtimeSource else { return nil }
        return (try? JSONDecoder().decode([ProviderFileTouch].self, from: Data(event.payloadJSON.utf8))) ?? []
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

/// Where a run works: the checkout it edits (`repoRoot`, a worktree root for linked
/// worktrees) and the git common dir that every worktree of one repository shares.
public struct RunRepoIdentity: Codable, Sendable, Equatable {
    public let repoRoot: String
    public let gitCommonDir: String
    public let branch: String?

    public init(repoRoot: String, gitCommonDir: String, branch: String?) {
        self.repoRoot = repoRoot
        self.gitCommonDir = gitCommonDir
        self.branch = branch
    }
}

public enum RunFileTouchPaths {
    /// Path of `path` relative to `repoRoot`; nil when it lies outside the checkout.
    /// Relative inputs resolve against `cwd`. Symlinks are resolved on both sides so a
    /// `/var` spelling matches git's `/private/var` toplevel.
    public static func relativize(path: String, repoRoot: String, cwd: String) -> String? {
        let absolute = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
        let root = canonical(repoRoot)
        let target = canonical(absolute)
        guard target.hasPrefix(root + "/") else { return nil }
        let relative = String(target.dropFirst(root.count + 1))
        return relative.isEmpty ? nil : relative
    }

    /// Git changes narrowed to what the run edited itself. `touched == nil` or empty means the
    /// provider reported no edits, so the whole tree stays. `cwdPrefix` is `cwd` relative to the
    /// repo root ("" at the root): `git ls-files --others` lists untracked files relative to `cwd`.
    public static func narrow<T>(_ changes: [T], path: (T) -> String, touched: Set<String>?, cwdPrefix: String) -> [T] {
        guard let touched, !touched.isEmpty else { return changes }
        return changes.filter { touched.contains(path($0)) || touched.contains(cwdPrefix + path($0)) }
    }

    public static func cwdPrefix(cwd: String, repoRoot: String) -> String {
        let root = canonical(repoRoot)
        let dir = canonical(cwd)
        guard dir.hasPrefix(root + "/") else { return "" }
        return String(dir.dropFirst(root.count + 1)) + "/"
    }

    /// Resolves symlinks of the deepest existing ancestor and re-appends the missing tail,
    /// so files a run is about to create still canonicalize.
    static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            tail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        let resolved = url.resolvingSymlinksInPath().path
        return tail.isEmpty ? resolved : (resolved as NSString).appendingPathComponent(tail.joined(separator: "/"))
    }
}

/// One file a live run is editing and when it first touched it.
public struct ConcurrentRunFile: Codable, Sendable, Equatable {
    public let path: String
    public let since: Date

    public init(path: String, since: Date) {
        self.path = path
        self.since = since
    }
}

/// A run another run in the same repository can see: who it is, what it was asked,
/// where it works and which files it is editing.
public struct ConcurrentRunSummary: Codable, Sendable, Equatable {
    public let runID: AgentRunID
    public let threadID: AgentThreadID
    /// Raw thread title; `botName` is set when a Bot conversation owns the thread.
    public let threadTitle: String
    public let botID: UUID?
    public let botName: String?
    public let objective: String
    public let branch: String?
    /// Checkout the run edits: the worktree path for a linked worktree.
    public let worktreePath: String
    public let editingFiles: [ConcurrentRunFile]
    public let startedAt: Date

    public init(
        runID: AgentRunID, threadID: AgentThreadID, threadTitle: String, botID: UUID?, botName: String?,
        objective: String, branch: String?, worktreePath: String, editingFiles: [ConcurrentRunFile], startedAt: Date
    ) {
        self.runID = runID; self.threadID = threadID; self.threadTitle = threadTitle
        self.botID = botID; self.botName = botName; self.objective = objective
        self.branch = branch; self.worktreePath = worktreePath
        self.editingFiles = editingFiles; self.startedAt = startedAt
    }
}

public enum RunObjective {
    public static let maxLength = 160

    /// Thread title, or the first user message while the title is still the placeholder.
    public static func make(title: String, firstUserMessage: String?) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = AgentThreadTitle.isPlaceholder(trimmedTitle)
            ? (firstUserMessage ?? trimmedTitle)
            : trimmedTitle
        let collapsed = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }
}
