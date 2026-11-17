import Foundation

/// Read-only detection of cua Spaces (https://github.com/trycua/cua).
/// RemoteCode computer-use never drives a Space itself; the agent uses the cua MCP server for that.
public struct CuaSpaces: Sendable {
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String]) -> (status: Int32, output: Data)?

    private let environment: [String: String]
    private let runner: Runner

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, runner: @escaping Runner = CuaSpaces.run) {
        self.environment = environment
        self.runner = runner
    }

    func executable() -> String? {
        if let explicit = environment["CUA_BIN"], !explicit.isEmpty {
            return FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil
        }
        // MCP clients often launch servers with a minimal PATH; also check cua's default install dir.
        let home = environment["HOME"] ?? NSHomeDirectory()
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return directories.map { "\($0)/cua" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func status() -> [String: Any] {
        let guidance = "Prefer a cua Space for tasks that do not need the user's own apps, windows, files or signed-in sessions: use the cua MCP server (list_spaces, create_space with reuse, then its computer tools) and name the Space used. Delete cloud Spaces you create. Use RemoteCode computer-use only for the user's real Mac or Chrome profile."
        guard let cua = executable() else {
            return ["available": false, "reason": "cua CLI not found", "install": "curl -fsSL https://cua.ai/install.sh | sh", "docs": "https://spaces.cua.ai/"]
        }
        guard let result = runner(cua, ["--json", "spaces", "ls"]) else {
            return ["available": false, "cli": cua, "reason": "cua spaces ls timed out or could not start", "guidance": guidance]
        }
        guard result.status == 0,
              let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let spaces = object["spaces"] as? [[String: Any]] else {
            return ["available": false, "cli": cua, "reason": "cua spaces ls failed (exit \(result.status)); try `cua auth login`", "guidance": guidance]
        }
        var output: [String: Any] = ["available": true, "cli": cua, "spaces": spaces, "guidance": guidance]
        if let relay = object["relay_error"] as? String { output["relay_error"] = relay }
        return output
    }

    public static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Read concurrently so a large listing cannot fill the pipe and stall the child.
        let reader = DispatchQueue(label: "RemoteCode.cua-read")
        var data = Data()
        let read = DispatchSemaphore(value: 0)
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        guard done.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            return nil
        }
        read.wait()
        return (process.terminationStatus, data)
    }
}
