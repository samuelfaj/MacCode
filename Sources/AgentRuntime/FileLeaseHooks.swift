import Foundation
import Persistence

/// The hooks file MacCode hands to Distill (`GROK_EXTRA_HOOKS_FILE`): one PreToolUse hook on the
/// edit tools that runs the service's `lease-hook` mode.
public enum FileLeaseHooks {
    public static let environmentKey = "GROK_EXTRA_HOOKS_FILE"
    public static let fileName = "concurrent-work-hooks.json"

    public static func contents(serviceExecutable: String) throws -> Data {
        let hooks: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": LeaseHookCommand.editToolMatcher,
                    "hooks": [[
                        "type": "command",
                        "command": "\(shellQuoted(serviceExecutable)) \(LeaseHookCommand.cliArgument)",
                        "timeout": LeaseHookCommand.hookTimeoutSeconds,
                    ]],
                ]],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes the file when its content changed; the same path every run, so Distill reads a stable file.
    @discardableResult
    public static func write(serviceExecutable: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        let data = try contents(serviceExecutable: serviceExecutable)
        if (try? Data(contentsOf: url)) != data {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
