import CoreModel
import Foundation

/// The command Distill runs as a PreToolUse hook before an edit tool. It reads the hook JSON on
/// stdin, asks MacCode over the run's own socket whether another run holds the file, and prints a
/// hook decision. It never gets in the way when MacCode cannot be reached.
public enum LeaseHookCommand {
    public static let cliArgument = "lease-hook"
    public static let rpcMethod = "bot.peer.lease_check"
    /// Distill tools that write files. `apply_patch` carries paths inside its patch text.
    public static let editToolMatcher = "write|search_replace|apply_patch|edit|hashline_edit"
    /// Seconds Distill waits for the hook before it gives up and allows the edit.
    public static let hookTimeoutSeconds = 10
    private static let socketTimeout: TimeInterval = 8

    public struct Request: Equatable {
        public let tool: String
        public let paths: [String]
        public let cwd: String?
    }

    /// The edited paths of a PreToolUse hook payload; nil for a tool that edits nothing.
    public static func request(fromHookInput input: [String: Any]) -> Request? {
        let tool = (input["tool_name"] as? String) ?? (input["toolName"] as? String) ?? ""
        let toolInput = (input["tool_input"] as? [String: Any]) ?? (input["toolInput"] as? [String: Any]) ?? [:]
        let paths: [String]
        if tool == "apply_patch" {
            paths = patchPaths(toolInput["patch"] as? String ?? toolInput["input"] as? String ?? "")
        } else {
            paths = ["file_path", "filePath", "path"].compactMap { (toolInput[$0] as? String)?.nilIfBlank }.prefix(1).map { $0 }
        }
        guard !paths.isEmpty else { return nil }
        return Request(tool: tool, paths: paths, cwd: (input["cwd"] as? String)?.nilIfBlank)
    }

    /// Files named by `*** Add|Update|Delete File:` and `*** Move to:` lines of a codex-format patch.
    static func patchPaths(_ patch: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            for marker in ["*** Add File:", "*** Update File:", "*** Delete File:", "*** Move to:"] where line.hasPrefix(marker) {
                let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, seen.insert(path).inserted { paths.append(path) }
            }
        }
        return paths
    }

    /// The JSON a hook prints for a MacCode answer; nil prints nothing, which Distill reads as allow.
    /// Warn adds context only, so the user's own permission prompts still decide whether the edit runs.
    public static func hookOutput(verdict: String, message: String?) -> String? {
        guard let message = message?.nilIfBlank else { return nil }
        var specific: [String: Any] = ["hookEventName": "PreToolUse"]
        switch verdict {
        case "deny":
            specific["permissionDecision"] = "deny"
            specific["permissionDecisionReason"] = message
        case "warn":
            specific["additionalContext"] = message
        default:
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": specific], options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One hook run. `call` performs the socket request; any error leaves the edit allowed.
    public static func run(
        stdin: Data,
        call: (_ method: String, _ arguments: [String: Any]) throws -> Any
    ) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let request = request(fromHookInput: object) else { return nil }
        var arguments: [String: Any] = ["tool_name": request.tool, "paths": request.paths]
        if let cwd = request.cwd { arguments["cwd"] = cwd }
        guard let answer = (try? call(rpcMethod, arguments)) as? [String: Any],
              let verdict = answer["verdict"] as? String else { return nil }
        return hookOutput(verdict: verdict, message: answer["message"] as? String)
    }

    /// Entry point of the service's `lease-hook` mode: returns what to print.
    public static func runFromProcess(stdin: Data, environment: [String: String]) -> String? {
        let client = BotPeerRPCClient(environment: environment, timeoutOverride: socketTimeout)
        return run(stdin: stdin) { method, arguments in
            try client.call(method: method, arguments: arguments, budget: .hostOperation)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
