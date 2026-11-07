import Foundation
import CoreModel
import Persistence

public enum AgentRunError: Error, CustomStringConvertible {
    case missingBinary(String)
    case spawnFailed(String)
    case alreadyRunning

    public var description: String {
        switch self {
        case .missingBinary(let b): return "CLI not found in PATH: \(b)"
        case .spawnFailed(let m): return "Failed to spawn agent: \(m)"
        case .alreadyRunning: return "Run already in progress"
        }
    }
}

public enum ProcessLocator {
    public static func resolve(_ name: String) -> String? {
        resolve(name,
                environmentPath: ProcessInfo.processInfo.environment["PATH"],
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    public static func resolve(_ name: String, environmentPath: String?, homeDirectory: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        // Prefer a co-located privileged helper next to MacCode.app/Contents/MacOS.
        if trimmed == "RemoteCodeRunAsUserHelper" || trimmed == "io.remotecode.RunAsUserHelper" {
            let candidates = [
                "/Library/PrivilegedHelperTools/io.remotecode.RunAsUserHelper",
                "/Library/PrivilegedHelperTools/RemoteCodeRunAsUserHelper",
                Bundle.main.bundleURL
                    .appendingPathComponent("Contents/MacOS/RemoteCodeRunAsUserHelper").path,
                (Bundle.main.executableURL?.deletingLastPathComponent()
                    .appendingPathComponent("RemoteCodeRunAsUserHelper").path) ?? ""
            ]
            for path in candidates where !path.isEmpty {
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        // Host top-level turns must resolve the REAL provider CLI, never the
        // nested-provider PATH proxy installed under ~/.remote-code/bin.
        let managedBin = "\(homeDirectory)/.remote-code/bin"
        let skipManagedProviderProxy = ProviderProxyCatalog.isProviderProxyCommand(trimmed)
        for component in searchPath(environmentPath: environmentPath, homeDirectory: homeDirectory) {
            if skipManagedProviderProxy, Self.normalizedDirectory(component) == Self.normalizedDirectory(managedBin) {
                continue
            }
            let full = component + "/" + trimmed
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    public static func resolveDistillAgent(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return resolveDistillAgent(
            name,
            environmentPath: ProcessInfo.processInfo.environment["PATH"],
            homeDirectory: home,
            managedHomes: [home]
        )
    }

    static func resolveDistillAgent(
        _ name: String,
        environmentPath: String?,
        homeDirectory: String,
        managedHomes: [String]
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let path = (trimmed as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path),
                  !managedHomes.contains(where: { isManagedDistillShim(path, homeDirectory: $0) })
            else { return nil }
            return path
        }
        for directory in searchPath(environmentPath: environmentPath, homeDirectory: homeDirectory) {
            if Self.normalizedDirectory(directory) == Self.normalizedDirectory("\(homeDirectory)/.remote-code/bin") {
                continue
            }
            let path = directory + "/" + trimmed
            if FileManager.default.isExecutableFile(atPath: path),
               !managedHomes.contains(where: { isManagedDistillShim(path, homeDirectory: $0) }) {
                return path
            }
        }
        return nil
    }

    public static func resolveDistillAgentForRunAsUser(
        _ name: String,
        runAsUser: AgentRunAsUser?,
        currentUID: uid_t = getuid()
    ) -> String? {
        let currentHome = FileManager.default.homeDirectoryForCurrentUser.path
        let homes = [currentHome, runAsUser?.homePath].compactMap { $0 }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let path = (trimmed as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path),
                  !homes.contains(where: { isManagedDistillShim(path, homeDirectory: $0) })
            else { return nil }
            return path
        }
        if let runAsUser, runAsUser.uid != currentUID,
           let path = resolveDistillAgent(
                trimmed,
                environmentPath: nil,
                homeDirectory: runAsUser.homePath,
                managedHomes: homes
           ) {
            return path
        }
        return resolveDistillAgent(
            trimmed,
            environmentPath: ProcessInfo.processInfo.environment["PATH"],
            homeDirectory: currentHome,
            managedHomes: homes
        )
    }

    /// True for RemoteCode's own `distill` (the managed link, or anything that
    /// resolves to the `RemoteCodeDistillService` binary, such as a leftover
    /// `~/.local/bin/distill` from the removed Token Saver), which is never
    /// the Distill agent.
    private static func isManagedDistillShim(_ path: String, homeDirectory: String) -> Bool {
        let managedURL = URL(fileURLWithPath: "\(homeDirectory)/.remote-code/bin/distill")
        let managedPath = managedURL.standardizedFileURL.path
        let managedTarget = managedURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidateURL = URL(fileURLWithPath: path)
        let candidatePath = candidateURL.standardizedFileURL.path
        let candidateTarget = candidateURL.resolvingSymlinksInPath().standardizedFileURL
        return candidatePath == managedPath
            || candidateTarget.path == managedTarget
            || candidateTarget.lastPathComponent == "RemoteCodeDistillService"
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Binary resolution for Auto admission + shared-helper execution (same rules).
    /// 1) Absolute Settings path when executable (e.g. /Users/airtonjunior/.local/bin/claude)
    /// 2) Target run-as-user home search
    /// 3) Current user home / PATH search
    /// So Auto can admit the same CLI the streaming adapter will spawn.
    public static func resolveForRunAsUser(
        _ name: String,
        runAsUser: AgentRunAsUser?,
        currentUID: uid_t = getuid()
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        if let runAsUser, runAsUser.uid != currentUID {
            if let target = resolve(trimmed, environmentPath: nil, homeDirectory: runAsUser.homePath) {
                return target
            }
        }
        return resolve(trimmed)
    }

    public static func expandedPath(environmentPath: String?, homeDirectory: String) -> String {
        searchPath(environmentPath: environmentPath, homeDirectory: homeDirectory).joined(separator: ":")
    }

    private static func searchPath(environmentPath: String?, homeDirectory: String) -> [String] {
        var paths = (environmentPath ?? "")
            .split(separator: ":")
            .map(String.init)
        paths.insert("\(homeDirectory)/.local/share/maccode-node/bin", at: 0)
        paths.insert("\(homeDirectory)/.remote-code/bin", at: 0)
        paths.append(contentsOf: [
            // Official Distill install.sh target; GUI apps never have it on PATH.
            "\(homeDirectory)/.local/share/distill/bin",
            "\(homeDirectory)/.grok/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin",
            "/usr/bin",
            "/bin"
        ])
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public final class CodexRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider = .codex
    private let binaryNameOverride: String?

    public init(binaryNameOverride: String? = nil) {
        self.binaryNameOverride = binaryNameOverride
    }

    static let astraModel = AgentModelDescriptor(id: "gpt-6-astra", label: "GPT-6-Astra", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true)

    public func listModels() async -> [AgentModelDescriptor] {
        // Explicit Codex model options, including Astra for catalogs that omit it.
        // id "" = account default (always works regardless of plan). The
        // earlier ids (gpt-5/gpt-5-codex/o3) are dead on this CLI and made
        // `codex --model …` fail with no output.
        [
            AgentModelDescriptor(id: "", label: "Default (account)", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            Self.astraModel,
            AgentModelDescriptor(id: "gpt-6-sol", label: "GPT-6-Sol", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-6-luna", label: "GPT-6-Luna", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.6-sol", label: "GPT-5.6-Sol", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.4", label: "GPT-5.4", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.4-mini", label: "GPT-5.4-Mini", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.3-codex", label: "GPT-5.3-Codex", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.3-codex-spark", label: "GPT-5.3-Codex-Spark", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.2", label: "GPT-5.2", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true)
        ]
    }

    /// Builds the `codex` argv. Pure + static for regression tests.
    /// With a prior session id it uses `exec resume <id>` so the model
    /// keeps full context; otherwise a fresh `exec`. An empty model id
    /// means "account default" (omit -m).
    public static func buildArgs(_ request: AgentRunRequest) -> [String] {
        let ptid = request.providerThreadId
        let resuming = (ptid?.isEmpty == false)
        // `codex exec resume` usage:
        //   exec resume [FLAGS] -c k=v <SESSION_ID> [PROMPT]
        // It does NOT accept --model/--sandbox (the session keeps the
        // model + sandbox it was created with — that's correct for a
        // continued conversation).
        var args: [String] = ["exec"]
        if resuming { args.append("resume") }
        args += ["--json", "--skip-git-repo-check"]
        if let r = request.reasoningEffort?.rawValue {
            args += ["-c", "model_reasoning_effort=\"\(r)\""]
        }
        if request.serviceTier == .fast {
            // Upstream config key is `service_tier` (openai/codex config_toml).
            // `model_service_tier` is not recognized and Fast on exec was a no-op.
            args += ["-c", "service_tier=\"fast\""]
        }
        args += botCatalogMCPOverrides(environment: request.environment)
        args += computerUseMCPOverrides(environment: request.environment)
        if !resuming {
            let model = request.model.trimmingCharacters(in: .whitespaces)
            if !model.isEmpty, model.lowercased() != "default" {
                args += ["--model", model]
            }
            switch request.permissionMode {
            case .supervised:
                args += ["-c", #"approval_policy="untrusted""#, "--sandbox", "read-only"]
            case .autoAcceptEdits:
                args += ["-c", #"approval_policy="on-request""#, "--sandbox", "workspace-write"]
            case .fullAccess:
                args += ["-c", #"approval_policy="never""#, "--sandbox", "danger-full-access"]
            }
        }
        for attachment in request.attachments where attachment.kind == .image {
            args += ["--image", attachment.path]
        }
        args += request.extraArgs
        if resuming, let ptid { args.append(ptid) }   // SESSION_ID before PROMPT
        args.append(request.providerPrompt)
        return args
    }

    /// Codex has no per-turn MCP JSON input. `-c` overrides are scoped to this
    /// process, so host MCP can be admitted without persisting it in the user's
    /// global `~/.codex/config.toml` (ChatGPT.app shares that file and otherwise
    /// leaks one stdio server per conversation).
    public static func computerUseMCPOverrides(
        environment: [String: String],
        command: String? = nil
    ) -> [String] {
        guard environment[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey] == "1" else {
            return []
        }
        let resolved = command
            ?? AgentSkillInstaller.resolveServiceBinary()?.path
            ?? ComputerUseMCPAdmit.fallbackCommand
        return stdioMCPServerOverrides(
            serverName: ComputerUseMCPAdmit.serverName,
            cliArgument: ComputerUseMCPAdmit.cliArgument,
            command: resolved
        )
    }

    /// Bot catalog MCPs (`bot-self-config` / `bot-browser` / `bot-computer` /
    /// `bot-web`), matching Grok's per-session ACP list. bot-self-config is
    /// admitted on every RemoteCode-spawned Codex; the bot-only servers only on
    /// bot runs (`BotRunMCPAdmission`). Must not be written to the user-global
    /// config.toml.
    public static func botCatalogMCPOverrides(
        command: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let resolved = command
            ?? AgentSkillInstaller.resolveServiceBinary()?.path
            ?? BotSelfConfigMCPAdmit.fallbackCommand
        let servers: [(name: String, argument: String, environment: [String: String])] = [
            (
                BotSelfConfigMCPAdmit.serverName,
                BotSelfConfigMCPAdmit.cliArgument,
                mcpEnvironment(for: BotSelfConfigMCPAdmit.serverName, from: environment)
            ),
            (
                BotBrowserMCPAdmit.serverName,
                BotBrowserMCPAdmit.cliArgument,
                mcpEnvironment(for: BotBrowserMCPAdmit.serverName, from: environment)
            ),
            (
                BotComputerMCPAdmit.serverName,
                BotComputerMCPAdmit.cliArgument,
                mcpEnvironment(for: BotComputerMCPAdmit.serverName, from: environment)
            ),
            (
                BotWebMCPAdmit.serverName,
                BotWebMCPAdmit.cliArgument,
                mcpEnvironment(for: BotWebMCPAdmit.serverName, from: environment)
            ),
        ]
        let isBotRun = BotRunMCPAdmission.isBotRun(environment: environment)
        return servers
            .filter { isBotRun || !BotRunMCPAdmission.botOnlyServerNames.contains($0.name) }
            .flatMap {
                stdioMCPServerOverrides(
                    serverName: $0.name,
                    cliArgument: $0.argument,
                    command: resolved,
                    environment: $0.environment,
                    toolTimeoutSeconds: $0.name == BotComputerMCPAdmit.serverName
                        ? BotComputerMCPAdmit.toolTimeoutSeconds
                        : nil
                )
            }
    }

    /// `codex app-server` accepts the same `-c` overrides as `exec`. Keep the
    /// subcommand first so fork-protocol probing can still recognize production
    /// app-server argv (`arguments.first == "app-server"`).
    public static func appServerArguments(
        command: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        ["app-server"]
            + botCatalogMCPOverrides(command: command, environment: environment)
    }

    static func stdioMCPServerOverrides(
        serverName: String,
        cliArgument: String,
        command: String,
        environment: [String: String] = [:],
        toolTimeoutSeconds: Int? = nil
    ) -> [String] {
        let prefix = "mcp_servers.\(serverName)"
        var overrides = [
            "-c", "\(prefix).command=\"\(tomlBasicString(command))\"",
            "-c", "\(prefix).args=[\"\(tomlBasicString(cliArgument))\"]",
        ]
        if let toolTimeoutSeconds {
            overrides += ["-c", "\(prefix).tool_timeout_sec=\(toolTimeoutSeconds)"]
        }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            overrides += [
                "-c", "\(prefix).env.\(key)=\"\(tomlBasicString(value))\"",
            ]
        }
        return overrides
    }

    private static func mcpEnvironment(
        for serverName: String,
        from environment: [String: String]
    ) -> [String: String] {
        var keys = [
            BotSelfConfigCatalog.callerEnvironmentKey,
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY",
        ]
        if serverName == BotComputerMCPAdmit.serverName {
            keys.append(BotComputerCatalog.threadEnvironmentKey)
        }
        if serverName == BotBrowserMCPAdmit.serverName {
            keys.append(BotBrowserCatalog.threadEnvironmentKey)
        }
        if serverName == BotSelfConfigMCPAdmit.serverName {
            keys += [
                BotPeerDelegation.threadEnvironmentKey,
                BotPeerDelegation.runEnvironmentKey,
                BotPeerDelegation.socketEnvironmentKey,
                BotPeerDelegation.capabilityEnvironmentKey,
            ]
        }
        return keys.reduce(into: [String: String]()) { result, key in
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return
            }
            result[key] = value
        }
    }

    private static func tomlBasicString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? request.providerBinary! : (binaryNameOverride ?? "codex")
        guard let path = ProcessLocator.resolve(binary) else {
            onEvent(.error("\(binary) not found in PATH"))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.missingBinary(binary)
        }

        let args = Self.buildArgs(request)
        let proc: Process
        do {
            proc = try ProviderSubprocessLauncher.makeProcess(
                provider: .codex,
                executablePath: path,
                arguments: args,
                currentDirectory: request.cwd,
                environment: request.environment,
                runAsUser: request.runAsUser
            )
        } catch {
            onEvent(.error(error.localizedDescription))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }

        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        // `codex exec` otherwise prints "Reading additional input from
        // stdin..." and can block — the prompt is already an arg.
        proc.standardInput = FileHandle.nullDevice

        let parser = CodexParser()
        let timeline = TimelineAggregator()
        let outBuf = LineBuffer()
        // Serializes the stdout readabilityHandler against the termination
        // drain: nil-ing a readabilityHandler does not wait for a callback
        // already running, and LineBuffer/CodexParser are not thread-safe.
        // Matches ClaudeRunner / GrokRunner so concurrent Dictionary mutation
        // cannot SIGABRT on the same teardown race class.
        let stdoutReadLock = NSLock()
        let cancelFlag = AgentCancelFlag()
        let emitLine: (String) -> Void = { line in
            let interpreted = Self.interpretStreamJSONLine(line, parser: parser)
            if let runtimeEvent = interpreted.runtimeEvent {
                let ev = AssistantEvent.providerRuntime(runtimeEvent)
                timeline.apply(ev)
                onEvent(.event(ev))
            }
            for ev in interpreted.parsedEvents {
                timeline.apply(ev)
                onEvent(.event(ev))
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutReadLock.lock()
            defer { stdoutReadLock.unlock() }
            let data = handle.availableData
            if data.isEmpty { return }
            for line in outBuf.take(data) {
                emitLine(line)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            let s = String(data: data, encoding: .utf8) ?? ""
            if let visible = Self.displayableStderr(s) {
                onEvent(.event(.providerRuntime(ProviderStderrClassifier.runtimeEvent(
                    message: visible,
                    provider: .codex,
                    source: "codex.exec.stderr"
                ))))
                onEvent(.error("[codex stderr] " + visible))
            }
        }

        proc.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Foundation may not deliver the bytes between the last read
            // and EOF via the handler — drain them explicitly, then flush
            // the final unterminated line. Without this the closing
            // `turn.completed` (and the answer) is regularly lost.
            // Under the lock: an in-flight readabilityHandler callback may
            // still be reading/parsing concurrently.
            stdoutReadLock.lock()
            let tail = BoundedPipeDrain.readRemaining(
                from: stdoutPipe.fileHandleForReading,
                maxBytes: BoundedPipeDrain.defaultStdoutMaxBytes
            )
            for line in outBuf.take(tail) + outBuf.flush() {
                emitLine(line)
            }
            stdoutReadLock.unlock()
            let status: AgentRunStatus
            if cancelFlag.isCancelled || p.terminationReason == .uncaughtSignal { status = .cancelled }
            else if p.terminationStatus == 0 { status = .completed }
            else { status = .failed }
            let finalMsg = timeline.finalAssistantMessage
            onEvent(.status(status))
            onEvent(.finished(status, finalMessage: finalMsg, providerThreadId: timeline.providerThreadId))
        }

        do {
            try proc.run()
            try ProcessSpawnTagger.tagProcess(proc, provider: .codex)
            onEvent(.status(.running))
        } catch {
            onEvent(.error("spawn: \(error.localizedDescription)"))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }

        return AgentRunHandle(runId: request.runId, process: proc) {
            cancelFlag.cancel()
            ProcessTerminator.terminateTree(proc)
        }
    }

#if DEBUG
    static var streamJSONDecodeCountForTesting = 0
#endif

    static func jsonObject(from line: String) -> [String: Any]? {
#if DEBUG
        streamJSONDecodeCountForTesting += 1
#endif
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Decode once, then runtime + parser events.
    static func interpretStreamJSONLine(
        _ line: String,
        parser: CodexParser,
        receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> (runtimeEvent: ProviderRuntimeEvent?, parsedEvents: [AssistantEvent]) {
        let object = jsonObject(from: line)
        return (
            object.flatMap {
                ProviderRuntimeEvent.fromJSONObjectIfNeeded(
                    $0, provider: .codex, source: "codex.exec.json", receivedAtMs: receivedAtMs
                )
            },
            object.map { parser.parseObject($0, now: receivedAtMs) } ?? []
        )
    }

    public static func shouldDisplayStderr(_ raw: String) -> Bool {
        displayableStderr(raw) != nil
    }

    public static func displayableStderr(_ raw: String) -> String? {
        ProviderStderrClassifier.displayableStderr(raw, provider: .codex)
    }

    /// Why a spawn's environment is being built. REQUIRED (no default) so every call
    /// site is forced by the compiler to classify itself — a spawn that runs user
    /// agent-turn code (`.agentTurn`) imports the login-shell env; a support/helper
    /// spawn (`.supportProcess`: model discovery, capability probe, node/npm helpers,
    /// usage refreshers) must NOT, so profile secrets never reach non-turn processes.
    public enum EnvironmentPurpose {
        case agentTurn(AgentProvider)
        case supportProcess

        var provider: AgentProvider? {
            if case .agentTurn(let p) = self { return p }
            return nil
        }
        var importsLoginEnvironment: Bool {
            if case .agentTurn = self { return true }
            return false
        }
    }

    /// GUI/launchd owns these — never overlay them from the login shell (identity +
    /// sandbox/XPC transport). Exact keys + prefixes.
    private static let guiOwnedExactKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
        "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_SESSION_ID"
    ]
    private static let guiOwnedPrefixes = ["XPC_", "__CF", "APP_SANDBOX_"]
    /// Shell-local vars that describe the capture shell, not the provider process.
    private static let volatileDropKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]
    /// Execution/loader controls: a profile export here could inject code or MITM a
    /// credentialed agent + its MCP/hook children. Prefix-matched so unknown future
    /// variants (e.g. a new DYLD_*) are also removed (fail-safe), plus exact names.
    private static let loaderControlPrefixes = ["DYLD_", "LD_"]
    private static let loaderControlExactKeys: Set<String> = [
        "NODE_OPTIONS", "BASH_ENV", "ENV", "NODE_EXTRA_CA_CERTS",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "GIT_SSH_COMMAND", "PERL5OPT", "PYTHONSTARTUP"
    ]
    /// Claude auth-routing keys deleted for provider `.claude` so claude.ai OAuth
    /// stays the default no matter what the profile/GUI env exports. A per-instance
    /// `overrides` value can re-add them explicitly (opt-in). Applied on BOTH the
    /// capture-success and fail-open branches when import is enabled.
    /// Only the non-`ANTHROPIC_`-prefixed keys are listed: the strip site pairs this
    /// with a `key.hasPrefix("ANTHROPIC_")` clause that already covers the entire
    /// `ANTHROPIC_*` namespace (incl. every base-URL variant), so listing those here
    /// would be redundant — and the literal base-URL key name in source trips the B6
    /// no-provider-redirect scanner even though this is a strip, not a redirect.
    private static let claudeAuthStripKeys: Set<String> = [
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"
    ]

    private static func isGuiOwned(_ key: String) -> Bool {
        guiOwnedExactKeys.contains(key) || guiOwnedPrefixes.contains { key.hasPrefix($0) }
    }
    private static func isLoaderControl(_ key: String) -> Bool {
        loaderControlExactKeys.contains(key) || loaderControlPrefixes.contains { key.hasPrefix($0) }
    }

    public static func processEnvironment(
        overrides: [String: String],
        purpose: EnvironmentPurpose,
        base gui: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // Login-shell env import applies only to real agent turns, and only when the
        // kill-switch is not off (default ON). When inactive, behavior is identical
        // to the pre-parity implementation (GUI env, no strips).
        let importEnabled = (gui["RC_LOGIN_SHELL_ENV_IMPORT"] ?? "1") != "0"
        let active = purpose.importsLoginEnvironment && importEnabled
        let login: [String: String]? = active
            ? LoginShellEnvironment.current(parentEnvironment: gui)
            : nil

        // Scrub each inherited source before overlaying them so one source's
        // marker cannot hide marked secrets from the other source.
        var base = BotSecretEnvironment.scrubbingInherited(from: gui)
        if let login {
            let login = BotSecretEnvironment.scrubbingInherited(from: login)
            // delta-over-GUI: overlay login keys that differ/are new, except the
            // GUI-owned identity/sandbox keys; drop shell-local volatile keys.
            for (key, value) in login where !isGuiOwned(key) {
                base[key] = value
            }
            for key in volatileDropKeys { base.removeValue(forKey: key) }
        }
        if active {
            // Fail-safe strips on BOTH branches (login imported OR capture-not-ready).
            for key in Array(base.keys) where isLoaderControl(key) {
                base.removeValue(forKey: key)
            }
            if case .agentTurn(.claude) = purpose {
                // Fail-safe: strip the whole ANTHROPIC_* namespace (catches unknown
                // future auth/routing keys) plus the exact CLAUDE_CODE_* auth keys.
                for key in Array(base.keys)
                where key.hasPrefix("ANTHROPIC_") || claudeAuthStripKeys.contains(key) {
                    base.removeValue(forKey: key)
                }
            }
        }

        // Host-injected keys belong to the exact host request, not the
        // RemoteCode process' inherited GUI/login environment. This keeps a
        // parent shell value from leaking into support or cross-user launches.
        base = AgentHostEnvironmentMerge.stripHostInjects(from: base)
        var env = base.merging(overrides) { _, override in override }

        let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        // Prepend the login PATH so profile PATH additions resolve; expandedPath then
        // fronts the managed-wrapper dir (~/.remote-code/bin) + standard fallbacks.
        // (Duplicate entries with the override PATH are harmless.)
        if let loginPath = login?["PATH"], !loginPath.isEmpty {
            let existing = env["PATH"].flatMap { $0.isEmpty ? nil : loginPath + ":" + $0 } ?? loginPath
            env["PATH"] = existing
        }
        env["PATH"] = ProcessLocator.expandedPath(environmentPath: env["PATH"], homeDirectory: home)

        if let provider = purpose.provider {
            env["REMOTE_CODE_AGENT_PROVIDER"] = provider.rawValue
        }
        // Agent turns drop any leftover Token Saver / Graphify keys and the
        // managed bin (re-asserted below when the host set it). Support/probe
        // processes drop every host-injected key.
        if case .agentTurn = purpose {
            env = AgentHostEnvironmentMerge.scrubLegacyOptimizationKeys(env)
        } else {
            env = AgentHostEnvironmentMerge.stripHostInjects(from: env)
        }
        // Re-assert managed bin first on PATH after login-shell / expandedPath merges.
        // Host sets RC_REMOTE_CODE_MANAGED_BIN for thread-scoped provider launches so
        // nested provider proxies win lookup. Without this, a login PATH overlay can bury or drop the managed dir
        // before the child process starts (shell bridge re-prepends for zsh tools, but
        // the provider process itself must also start with a correct PATH).
        if case .agentTurn = purpose,
           let managedBin = env["RC_REMOTE_CODE_MANAGED_BIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !managedBin.isEmpty {
            let current = env["PATH"] ?? ""
            let parts = current
                .split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { $0 != managedBin }
            env["PATH"] = ([managedBin] + parts).joined(separator: ":")
        }
        // Expose the `RefreshMcpTools` tool for Claude turns so the agent can pick
        // up remote MCP servers (Linear, etc.) that finish their async connect a
        // few seconds into the session — see mcpConnectWaitDirective. A caller-set
        // override wins (so it can be forced off).
        if case .agentTurn(.claude) = purpose, env["CLAUDE_CODE_ENABLE_REFRESH_MCP_TOOLS"] == nil {
            env["CLAUDE_CODE_ENABLE_REFRESH_MCP_TOOLS"] = "1"
        }
        // Apply Claude thinking controls after every GUI/login/override merge.
        // Removing a key from the caller's overrides is not a tombstone: an
        // inherited shell value would otherwise reappear and override the
        // explicit CLI/SDK effort or disable interleaved thinking.
        if case .agentTurn(.claude) = purpose {
            env = ClaudeRunner.thinkingEnvironment(env)
        }
        return env
    }
}

/// Reassembles newline-delimited JSON from a pipe. The
/// `readabilityHandler` hands us arbitrary byte chunks: a single read
/// routinely splits a JSON line — and even a multi-byte UTF-8 sequence —
/// across two deliveries. Decoding each raw chunk directly (the previous
/// behaviour) silently dropped every straddling event, so large agent
/// outputs lost their terminal `agent_message`/`turn.completed` and the
/// run hung "running" forever. Only complete lines are emitted; the
/// trailing partial is held until the next read (or `flush()` at EOF).
///
/// The unterminated partial is capped: a single tool-result JSON line (or a
/// hung provider that never sends `\n`) must not pin RAM = line size. Bytes
/// past the cap are drained until the next newline so a later
/// `turn.completed` frame is still parsed. Overflow is fail-open: the truncated
/// line is replaced with a small valid NDJSON `error` record (recoverable,
/// `[[rc:line-overflow]]`) so `emitLine` still JSON-decodes and surfaces it.
/// The 2 MiB prefix is not re-emitted. No SQLite write on the pipe thread.
final class LineBuffer {
    /// Peak retained unterminated line. 2 MiB sits in the 1–4 MiB band:
    /// legitimate NDJSON still fits; an 8 MiB blob drops 75%.
    static let maxPartialBytes = 2 * 1024 * 1024
    static let truncationMarker = "[RemoteCode] NDJSON line truncated[[rc:line-overflow]]"
    /// Identification snippet inside the overflow JSON — not the 2 MiB prefix.
    static let overflowPrefixBytes = 128

    private var buffer = Data()
    /// Bytes in the trailing partial line that were already checked for a
    /// newline. Pipe deliveries commonly split one long record into many small
    /// chunks; resuming from this offset avoids rescanning the whole partial on
    /// every delivery.
    private var scannedByteCount = 0
    /// Current partial exceeded `maxPartialBytes`; further bytes are discarded
    /// until the next newline so later frames still parse.
    private var droppingUntilNewline = false
    private var truncatedPartial = false

    var retainedByteCountForTesting: Int { buffer.count }
    var truncatedPartialForTesting: Bool { truncatedPartial || droppingUntilNewline }

    /// Append a chunk, return any now-complete lines (trimmed, non-empty).
    func take(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        if !droppingUntilNewline,
           buffer.count + data.count <= Self.maxPartialBytes {
            return takeFast(data)
        }
        return takeCapped(data)
    }

    /// Emit any final, unterminated line (last record before EOF).
    func flush() -> [String] {
        droppingUntilNewline = false
        guard !buffer.isEmpty || truncatedPartial else { return [] }
        let rest = buffer
        let wasTruncated = truncatedPartial
        buffer.removeAll()
        scannedByteCount = 0
        truncatedPartial = false
        return Self.decode(rest, truncated: wasTruncated).map { [$0] } ?? []
    }

    /// Unchanged under-cap path: one prefix removal, resume scan from
    /// `scannedByteCount`. Must stay faster than per-line `removeSubrange`.
    private func takeFast(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        var lineStart = buffer.startIndex
        var searchStart = buffer.index(
            buffer.startIndex,
            offsetBy: min(scannedByteCount, buffer.count)
        )
        while searchStart < buffer.endIndex,
              let nl = buffer[searchStart...].firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: lineStart..<nl)
            if let s = Self.decode(lineData) { lines.append(s) }
            searchStart = buffer.index(after: nl)
            lineStart = searchStart
        }
        if lineStart != buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
        scannedByteCount = buffer.count
        return lines
    }

    private func takeCapped(_ data: Data) -> [String] {
        var lines: [String] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            if droppingUntilNewline {
                if let nl = data[offset...].firstIndex(of: 0x0A) {
                    if let s = emitBuffer() { lines.append(s) }
                    offset = data.index(after: nl)
                    continue
                }
                return lines
            }
            if let nl = data[offset...].firstIndex(of: 0x0A) {
                appendCapped(data[offset..<nl])
                if let s = emitBuffer() { lines.append(s) }
                offset = data.index(after: nl)
            } else {
                appendCapped(data[offset...])
                break
            }
        }
        scannedByteCount = buffer.count
        return lines
    }

    private func appendCapped(_ piece: Data.SubSequence) {
        if droppingUntilNewline { return }
        let room = Self.maxPartialBytes - buffer.count
        if piece.count <= room {
            buffer.append(contentsOf: piece)
            return
        }
        if room > 0 {
            buffer.append(contentsOf: piece.prefix(room))
        }
        truncatedPartial = true
        droppingUntilNewline = true
    }

    private func emitBuffer() -> String? {
        let s = Self.decode(buffer, truncated: truncatedPartial)
        buffer.removeAll(keepingCapacity: true)
        scannedByteCount = 0
        truncatedPartial = false
        droppingUntilNewline = false
        return s
    }

    private static func decode(_ data: Data, truncated: Bool = false) -> String? {
        var d = data
        if d.last == 0x0D { d.removeLast() }   // strip a CRLF's CR
        if truncated {
            return overflowRecordJSON(retained: d)
        }
        // Lines are now complete, so no UTF-8 sequence is split; decode
        // is lossless. (Lossy `String(decoding:)` never returns nil — far
        // safer than the old guard that dropped the whole chunk.)
        let s = String(decoding: d, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Valid NDJSON so `interpretStreamJSONLine` cannot drop the overflow.
    /// CodexParser `error` + ProviderRuntimeEvent both surface it.
    static func overflowRecordJSON(retained: Data) -> String {
        let prefix = String(decoding: retained.prefix(overflowPrefixBytes), as: UTF8.self)
        let payload: [String: Any] = [
            "type": "error",
            "message": truncationMarker,
            "recoverable": true,
            "truncated": true,
            "retained_bytes": retained.count,
            "prefix": prefix,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return #"{"message":"\#(truncationMarker)","recoverable":true,"type":"error"}"#
    }
}

final class TimelineAggregator: @unchecked Sendable {
    private var state = AssistantTimelineState()
    private let lock = NSLock()
    var finalAssistantMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return state.latestAssistantMessage
    }
    var providerThreadId: String? {
        lock.lock(); defer { lock.unlock() }
        return state.providerThreadId
    }
    func apply(_ ev: AssistantEvent) {
        lock.lock(); defer { lock.unlock() }
        state.apply(ev)
    }
}
