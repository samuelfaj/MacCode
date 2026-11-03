import Foundation
import Darwin
import CoreModel
import RemoteCodeCSystem

public struct ProviderAccountUsageRefreshRequest: Sendable, Equatable {
    public static let defaultGrokCreditsAPIURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    )!
    public static let defaultClaudeUsageAPIURL = URL(
        string: "https://api.anthropic.com/api/oauth/usage"
    )!
    public static let defaultCodexUsageAPIURL = URL(
        string: "https://chatgpt.com/backend-api/wham/usage"
    )!

    public let codexBinary: String
    public let claudeBinary: String
    public let grokBinary: String
    /// Override for tests; default is `~/.grok/logs/unified.jsonl`.
    public let grokBillingLogURL: URL?
    /// When set, Grok usage prefers the live CLI credits API using this auth file.
    /// Tests leave it nil so they never hit the network.
    public let grokAuthFileURL: URL?
    /// Override for tests; default is `defaultGrokCreditsAPIURL`.
    public let grokCreditsAPIURL: URL?
    /// When set, Claude prefers `GET /api/oauth/usage`. Tests leave it nil.
    public let claudeAuthFileURL: URL?
    public let claudeUsageAPIURL: URL?
    /// When set, Claude next tries Claude Code's own usage cache
    /// (`~/.claude.json`) before launching the CLI. Tests leave it nil.
    public let claudeUsageCacheURL: URL?
    /// When false, Claude stops after the OAuth API and the cache: no
    /// `claude -p /usage` launch (~10 CPU-s, ~600 MB per run) this time.
    public let allowClaudeCLIProbe: Bool
    /// When false, a failed `claude -p /usage` does not fall back to the
    /// interactive PTY screen.
    public let allowClaudeUsageScreen: Bool
    /// When set, Codex prefers `GET …/wham/usage`. Tests leave it nil.
    public let codexAuthFileURL: URL?
    public let codexUsageAPIURL: URL?
    /// Periodic refreshes run a dedicated Grok probe first so it cannot be
    /// starved by slower Codex/Claude work. Those full refreshes exclude Grok
    /// to avoid issuing the same credits request twice in one tick.
    public let includeGrok: Bool
    public let cwd: String
    public let environment: [String: String]

    public init(
        codexBinary: String = "codex",
        claudeBinary: String = "claude",
        grokBinary: String = "grok",
        grokBillingLogURL: URL? = nil,
        grokAuthFileURL: URL? = nil,
        grokCreditsAPIURL: URL? = nil,
        claudeAuthFileURL: URL? = nil,
        claudeUsageAPIURL: URL? = nil,
        claudeUsageCacheURL: URL? = nil,
        allowClaudeCLIProbe: Bool = true,
        allowClaudeUsageScreen: Bool = true,
        codexAuthFileURL: URL? = nil,
        codexUsageAPIURL: URL? = nil,
        includeGrok: Bool = true,
        cwd: String = NSHomeDirectory(),
        environment: [String: String] = [:]
    ) {
        self.codexBinary = codexBinary
        self.claudeBinary = claudeBinary
        self.grokBinary = grokBinary
        self.grokBillingLogURL = grokBillingLogURL
        self.grokAuthFileURL = grokAuthFileURL
        self.grokCreditsAPIURL = grokCreditsAPIURL
        self.claudeAuthFileURL = claudeAuthFileURL
        self.claudeUsageAPIURL = claudeUsageAPIURL
        self.claudeUsageCacheURL = claudeUsageCacheURL
        self.allowClaudeCLIProbe = allowClaudeCLIProbe
        self.allowClaudeUsageScreen = allowClaudeUsageScreen
        self.codexAuthFileURL = codexAuthFileURL
        self.codexUsageAPIURL = codexUsageAPIURL
        self.includeGrok = includeGrok
        self.cwd = cwd
        self.environment = environment
    }
}

public protocol ProviderAccountUsageRefreshing: Sendable {
    func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage]
    func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage?
}

extension ProviderAccountUsageRefreshing {
    public func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        let url = request.grokBillingLogURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/logs/unified.jsonl")
        return AssistantAccountUsageParser.grokFromBillingLogFile(at: url)
    }
}

public final class ProviderAccountUsageRefresher: ProviderAccountUsageRefreshing, @unchecked Sendable {
    private struct CommandResult {
        let status: Int32
        let stdout: String
    }

    private let timeoutSeconds: TimeInterval
    private let jsonAPIFetcher: (@Sendable (URL, [String: String]) async -> [String: Any]?)?
    private let refreshGate = NSLock()
    private var inFlightRefresh: Task<[AssistantAccountUsage], Never>?
    private var refreshGeneration: UInt64 = 0

    public init(
        timeoutSeconds: TimeInterval = 18.0,
        grokCreditsFetcher: (@Sendable (URL, String) async -> [String: Any]?)? = nil,
        jsonAPIFetcher: (@Sendable (URL, [String: String]) async -> [String: Any]?)? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        if let jsonAPIFetcher {
            self.jsonAPIFetcher = jsonAPIFetcher
        } else if let grokCreditsFetcher {
            self.jsonAPIFetcher = { url, headers in
                let token = headers["Authorization"]?
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "Bearer ", with: "", options: [.anchored])
                guard let token, !token.isEmpty else { return nil }
                return await grokCreditsFetcher(url, token)
            }
        } else {
            self.jsonAPIFetcher = nil
        }
    }

    public func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
        let task: Task<[AssistantAccountUsage], Never>
        let generation: UInt64
        refreshGate.lock()
        if let inFlightRefresh {
            task = inFlightRefresh
            refreshGate.unlock()
            return await task.value
        }
        generation = refreshGeneration &+ 1
        refreshGeneration = generation
        task = Task { await self.performRefreshAccountUsage(request) }
        inFlightRefresh = task
        refreshGate.unlock()
        let usages = await task.value
        refreshGate.lock()
        if refreshGeneration == generation {
            inFlightRefresh = nil
        }
        refreshGate.unlock()
        return usages
    }

    private func performRefreshAccountUsage(
        _ request: ProviderAccountUsageRefreshRequest
    ) async -> [AssistantAccountUsage] {
        async let codex = withProviderTimeout { await self.fetchCodexUsage(request) }
        async let claude = withProviderTimeout { await self.fetchClaudeUsage(request) }
        if request.includeGrok {
            async let grok = withProviderTimeout { await self.fetchGrokUsage(request) }
            return await [codex, claude, grok]
                .compactMap { $0 }
                .sorted { $0.provider.rawValue < $1.provider.rawValue }
        }
        return await [codex, claude]
            .compactMap { $0 }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    public func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        await fetchGrokUsage(request)
    }

    private func withProviderTimeout(
        _ operation: @escaping @Sendable () async -> AssistantAccountUsage?
    ) async -> AssistantAccountUsage? {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func resume(_ usage: AssistantAccountUsage?) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: usage)
            }
            let providerTimeout = UInt64(max(30, timeoutSeconds * 2 + 8) * 1_000_000_000)

            let work = Task.detached {
                let usage = await operation()
                resume(usage)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: providerTimeout)
                work.cancel()
                resume(nil)
            }
        }
    }

    private func fetchCodexUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        if let live = await fetchCodexWhamUsage(request) {
            return live
        }
        do {
            let client = try CodexAppServerClient(
                binary: request.codexBinary,
                arguments: ["app-server"],
                cwd: request.cwd,
                environment: request.environment
            )
            defer { client.stop() }
            _ = try await client.initialize(
                clientName: "remotecode",
                clientTitle: "RemoteCode",
                clientVersion: "0.0.0"
            )
            let response = try await client.requestJSONObject(method: "account/rateLimits/read")
            return AssistantAccountUsageParser.codex(from: response)
        } catch {
            return nil
        }
    }

    private func fetchClaudeUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        if let live = await fetchClaudeOAuthUsage(request) {
            return live
        }
        if let cacheURL = request.claudeUsageCacheURL,
           let cached = AssistantAccountUsageParser.claudeCachedUsage(fromConfigFile: cacheURL) {
            return cached
        }
        guard request.allowClaudeCLIProbe else { return nil }
        // Prefer the Process path (waitUntilExit) first — it never leaves PTY zombies.
        // Screen-capture PTY is fallback only when text /usage fails (plan-final W1).
        // Parse with claudeUsageText (which prefers claudeUsageScreen patterns) so
        // modern "Current week (all models): N% used" headless output is accepted
        // without spawning an interactive PTY. The probe only reads usage: it
        // skips the user's MCP servers and hooks, which otherwise start a dozen
        // processes (npm, MCP servers, plugin hooks) on every launch.
        let binary = request.claudeBinary
        let cwd = request.cwd
        let environment = request.environment
        let arguments = [
            "-p",
            "--output-format", "text",
            "--no-session-persistence",
            "--max-budget-usd", "0.01",
            "--strict-mcp-config",
            "--settings", #"{"disableAllHooks":true}"#,
            "/usage"
        ]
        let timeoutSeconds = self.timeoutSeconds
        let result = await ProviderCLIProbe.runOffCooperativePool {
            Self.run(binary: binary, arguments: arguments, cwd: cwd, environment: environment, timeoutSeconds: timeoutSeconds)
        }
        if let result, result.status == 0 || !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let usage = AssistantAccountUsageParser.claudeUsageText(result.stdout) {
            return usage
        }
        guard request.allowClaudeUsageScreen else { return nil }
        if let usage = await runClaudeUsageScreen(request) {
            return usage
        }
        return nil
    }

    /// Grok weekly credits: live CLI billing API first (same host the Grok
    /// Usage UI uses), then `~/.grok/logs/unified.jsonl`. A failed probe returns
    /// nil so the last known percent is kept instead of painting 0%.
    private func fetchGrokUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        if let live = await fetchGrokCreditsAPI(request) {
            return live
        }
        let url = request.grokBillingLogURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/logs/unified.jsonl")
        return AssistantAccountUsageParser.grokFromBillingLogFile(at: url)
    }

    private func fetchGrokCreditsAPI(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        guard let authFile = request.grokAuthFileURL,
              let token = AssistantAccountUsageParser.grokAccessToken(fromAuthFile: authFile) else {
            return nil
        }
        let endpoint = request.grokCreditsAPIURL
            ?? ProviderAccountUsageRefreshRequest.defaultGrokCreditsAPIURL
        guard let payload = await fetchGrokCreditsJSON(endpoint: endpoint, token: token) else {
            return nil
        }
        return AssistantAccountUsageParser.grokBillingJSON(payload)
    }

    private func fetchGrokCreditsJSON(endpoint: URL, token: String) async -> [String: Any]? {
        await fetchJSON(endpoint: endpoint, headers: [
            "Authorization": "Bearer \(token)",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "Accept": "application/json"
        ])
    }

    private func fetchClaudeOAuthUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        guard let authFile = request.claudeAuthFileURL,
              let token = AssistantAccountUsageParser.claudeAccessToken(fromAuthFile: authFile) else {
            return nil
        }
        let endpoint = request.claudeUsageAPIURL
            ?? ProviderAccountUsageRefreshRequest.defaultClaudeUsageAPIURL
        guard let payload = await fetchJSON(endpoint: endpoint, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20"
        ]) else {
            return nil
        }
        return AssistantAccountUsageParser.claudeOAuthUsage(from: payload)
    }

    private func fetchCodexWhamUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        guard let authFile = request.codexAuthFileURL,
              let creds = AssistantAccountUsageParser.codexAccessToken(fromAuthFile: authFile) else {
            return nil
        }
        let endpoint = request.codexUsageAPIURL
            ?? ProviderAccountUsageRefreshRequest.defaultCodexUsageAPIURL
        var headers = [
            "Authorization": "Bearer \(creds.token)",
            "Accept": "application/json",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop"
        ]
        if let accountID = creds.accountID {
            headers["ChatGPT-Account-ID"] = accountID
        }
        guard let payload = await fetchJSON(endpoint: endpoint, headers: headers) else {
            return nil
        }
        return AssistantAccountUsageParser.codexWhamUsage(from: payload)
    }

    private func fetchJSON(endpoint: URL, headers: [String: String]) async -> [String: Any]? {
        if let jsonAPIFetcher {
            return await jsonAPIFetcher(endpoint, headers)
        }
        var request = URLRequest(url: endpoint, timeoutInterval: min(10, max(2, timeoutSeconds)))
        request.httpMethod = "GET"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // One retry on a transient network failure. Manual and periodic refreshes share this path.
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return object
            } catch let error as URLError where attempt == 0 && Self.isTransientURLError(error) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return nil
            }
        }
        return nil
    }

    private static func isTransientURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet: return true
        default: return false
        }
    }

    private func runClaudeUsageScreen(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
        guard let path = ProcessLocator.resolve(request.claudeBinary) else {
            return nil
        }

        var environment = CodexRunner.processEnvironment(overrides: request.environment, purpose: .supportProcess)
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "C.UTF-8"
        environment["LC_ALL"] = environment["LC_ALL"] ?? "C.UTF-8"
        environment.removeValue(forKey: "NO_COLOR")
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        var envp = environment.sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }

        var masterFD: Int32 = -1
        let pid = request.cwd.withCString { cwdPointer in
            path.withCString { executablePointer in
                argv.withUnsafeMutableBufferPointer { argvPointer in
                    envp.withUnsafeMutableBufferPointer { envpPointer in
                        rc2_spawnpty_exec(
                            &masterFD,
                            cwdPointer,
                            executablePointer,
                            argvPointer.baseAddress,
                            envpPointer.baseAddress
                        )
                    }
                }
            }
        }
        guard pid > 0 else { return nil }

        defer { close(masterFD) }
        _ = rc2_set_winsize(masterFD, 40, 120)
        let flags = fcntl(masterFD, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK) }

        var output = Data()
        let readyDeadline = Date().addingTimeInterval(min(10, max(2, timeoutSeconds / 2)))
        while Date() < readyDeadline {
            if Task.isCancelled {
                terminatePTYChild(pid)
                return nil
            }
            _ = readAvailablePTY(masterFD, into: &output)
            let text = String(decoding: output.suffix(64_000), as: UTF8.self)
            if text.contains("❯") {
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        writePTY(masterFD, Data("/usage\r".utf8))
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Task.isCancelled {
                terminatePTYChild(pid)
                return nil
            }
            let childOpen = readAvailablePTY(masterFD, into: &output)
            let text = String(decoding: output.suffix(256_000), as: UTF8.self)
            if let usage = AssistantAccountUsageParser.claudeUsageScreen(text) {
                terminatePTYChild(pid)
                return usage
            }
            if !childOpen && !isChildRunning(pid) { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        writePTY(masterFD, Data("\u{1B}/exit\r".utf8))
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = readAvailablePTY(masterFD, into: &output)
        terminatePTYChild(pid)
        let text = String(decoding: output.suffix(256_000), as: UTF8.self)
        return AssistantAccountUsageParser.claudeUsageScreen(text)
    }

    private func readAvailablePTY(_ fd: Int32, into output: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer[0..<Int(count)])
                continue
            }
            if count == 0 { return false }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return true }
            return false
        }
    }

    private func writePTY(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func isChildRunning(_ pid: Int32) -> Bool {
        OwnedChildReaper.poll(pid: pid) == nil
    }

    private func terminatePTYChild(_ pid: Int32) {
        // Bounded wait only. A stuck `/usage` child must not pin overlapping
        // refreshes on blocking waitpid (freeze-class sample: two wait4).
        // A child still exiting after SIGKILL is reaped when it exits; nothing
        // else waits on a forkpty child, so it would stay `<defunct>` for the
        // app's lifetime.
        if OwnedChildReaper.terminateAndReap(pid: pid, waitForZombie: false) == .timedOutStillRunning {
            OwnedChildReaper.reapWhenExited(pid: pid)
        }
    }

    private func terminateScriptProcess(_ proc: Process) {
        guard proc.isRunning else { return }
        signalChildren(of: proc.processIdentifier, signal: "TERM")
        proc.terminate()
        let limit = Date().addingTimeInterval(0.8)
        while Date() < limit, proc.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard proc.isRunning else { return }
        signalChildren(of: proc.processIdentifier, signal: "KILL")
        kill(proc.processIdentifier, SIGKILL)
        proc.waitUntilExit()
    }

    private func signalChildren(of pid: Int32, signal: String) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pkill") else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-\(signal)", "-P", "\(pid)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {}
    }

    private static func run(
        binary: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) -> CommandResult? {
        guard let path = ProcessLocator.resolve(binary),
              let result = ProviderCLIProbe.run(
                binaryPath: path,
                arguments: arguments,
                environment: environment,
                runAsUser: nil,
                timeoutSeconds: timeoutSeconds,
                currentDirectory: cwd
              ) else { return nil }
        return CommandResult(status: result.status, stdout: result.stdout)
    }
}
