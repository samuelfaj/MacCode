import Foundation
import CoreModel
import Persistence

public final class ClaudeRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider = .claude
    private let binaryNameOverride: String?

    public init(binaryNameOverride: String? = nil) {
        self.binaryNameOverride = binaryNameOverride
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await listModelsResult().models
    }

    /// Like `listModels` but returns a `ModelListResult` so callers can
    /// inspect whether the static fallback was used.
    /// `environment` and `session` are injected for testing; production
    /// callers use the defaults.
    public func listModelsResult(
        environment: [String: String] = [:],
        session: URLSession = .shared,
        cwd: String = FileManager.default.currentDirectoryPath,
        runAsUser: AgentRunAsUser? = nil
    ) async -> ModelListResult {
        let harnessModels = await ClaudeHarnessModelDiscovery.listModels(
            binary: binaryNameOverride ?? "claude",
            cwd: cwd,
            environment: environment,
            runAsUser: runAsUser
        )
        if !harnessModels.isEmpty {
            return ModelListResult(models: harnessModels, isFallback: false)
        }
        let result = await AnthropicModelDiscovery.listModelsResult(environment: environment, session: session)
        if result.isFallback {
            return ModelListResult(models: Self.listModels(installedVersion: nil), isFallback: true)
        }
        return result
    }

    public static func listModels(installedVersion: String?) -> [AgentModelDescriptor] {
        AnthropicModelDiscovery.latestAliasModels()
    }

    static func supportedReasoningEfforts(for model: String) -> [AgentReasoningEffort] {
        let rawID = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = rawID.hasSuffix("[1m]") ? String(rawID.dropLast(4)) : rawID
        if id.contains("haiku") { return [] }
        if id.hasPrefix("claude-opus-4-5") {
            return [.low, .medium, .high]
        }
        if id.hasPrefix("claude-mythos-preview")
            || id.hasPrefix("claude-sonnet-4-6")
            || id.hasPrefix("claude-opus-4-6") {
            return [.low, .medium, .high, .max]
        }
        if id == "best" || id == "default" || id == "fable" || id == "mythos" || id == "opus" || id == "sonnet"
            || id.hasPrefix("claude-fable") || id.hasPrefix("claude-mythos-5")
            || id.hasPrefix("claude-opus-5")
            || id.hasPrefix("claude-opus-4-7") || id.hasPrefix("claude-opus-4-8")
            || id.hasPrefix("claude-sonnet-5") {
            return AgentReasoningEffort.claudeSupportedCases
        }
        // Claude effort support is an explicit model allowlist. Unknown/custom
        // and legacy families keep manual thinking settings but expose no flag.
        return []
    }

    static func defaultReasoningEffort(for model: String) -> AgentReasoningEffort {
        let rawID = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = rawID.hasSuffix("[1m]") ? String(rawID.dropLast(4)) : rawID
        if id.hasPrefix("claude-opus-4-7") { return .xhigh }
        // Claude Code 2.1.282 catalog: Opus 5.5 default_effort is medium.
        // The live `default` and `opus` aliases resolve to claude-opus-5-5.
        if id == "default" || id == "opus" || id.hasPrefix("claude-opus-5-5") {
            return .medium
        }
        return .high
    }

    static func normalizedReasoningEffort(
        _ effort: AgentReasoningEffort?,
        model: String
    ) -> AgentReasoningEffort? {
        let supported = supportedReasoningEfforts(for: model)
        guard !supported.isEmpty else { return nil }
        // Claude Code defaults to high on effort-capable models except
        // Opus 4.7 (xhigh) and Opus 5.5 / live opus and default aliases (medium).
        let requested = effort ?? Self.defaultReasoningEffort(for: model)
        if requested == .minimal { return .low }
        if supported.contains(requested) { return requested }
        switch requested {
        case .xhigh, .ultracode:
            return supported.contains(.high) ? .high : supported.last
        case .max, .ultra:
            return supported.last
        case .minimal, .low, .medium, .high:
            return supported.contains(.medium) ? .medium : supported.last
        }
    }

    /// Claude Code 2.1.203+ accepts `ultracode` as a native effort selector
    /// meaning xhigh effort plus standing dynamic-workflow orchestration. Keep
    /// that wire value and the equivalent settings payload below aligned.
    /// Unsupported levels are normalized per model, and models such as Haiku
    /// that expose no effort control omit the flag entirely.
    static func effortArgs(
        _ effort: AgentReasoningEffort?,
        model: String = "opus"
    ) -> [String] {
        guard let effort = normalizedReasoningEffort(effort, model: model) else { return [] }
        switch effort {
        case .minimal, .low: return ["--effort", "low"]
        case .high: return ["--effort", "high"]
        case .xhigh: return ["--effort", "xhigh"]
        case .max, .ultra: return ["--effort", "max"]
        case .ultracode: return ["--effort", "ultracode"]
        case .medium: return ["--effort", "medium"]
        }
    }

    /// TypeScript `Options.effort` is `low|medium|high|xhigh|max` only.
    /// Ultracode is settings `ultracode: true`, never `effort: "ultracode"`.
    static func sdkEffortToken(
        _ effort: AgentReasoningEffort?,
        model: String = "opus"
    ) -> String? {
        guard let token = effortArgs(effort, model: model).last else { return nil }
        return token == "ultracode" ? "xhigh" : token
    }

    /// One-shot CLI fork argv: resume the source, fork, pin the child id.
    static func buildForkArgs(sourceProviderThreadId: String, childProviderThreadId: String) -> [String] {
        [
            "--print",
            "--output-format", "json",
            "--verbose",
            "--resume", sourceProviderThreadId,
            "--fork-session",
            "--session-id", childProviderThreadId
        ]
    }

    /// Claude treats effort and extended thinking as separate controls. Keep
    /// thinking explicitly enabled for every provider session; Ultracode adds
    /// workflow orchestration to the same single settings payload.
    static let ultracodeSettingsJSON = #"{"alwaysThinkingEnabled":true,"enableWorkflows":true,"env":{"CLAUDE_CODE_DISABLE_THINKING":"0","CLAUDE_CODE_EFFORT_LEVEL":"xhigh","DISABLE_INTERLEAVED_THINKING":"0","MAX_THINKING_TOKENS":"32000"},"showThinkingSummaries":true,"ultracode":true}"#

    /// Environment overrides that keep a saved shell/user configuration from
    /// silently disabling thinking after RemoteCode selected a reasoning effort.
    /// A budget at or above Claude's 1024-token minimum is ignored by adaptive
    /// models and remains a safe fixed-budget fallback for older supported models.
    static func thinkingEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        // Claude gives this inherited env var precedence over the explicit
        // CLI/SDK session effort selected by RemoteCode.
        result.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL")
        result.removeValue(forKey: "DISABLE_INTERLEAVED_THINKING")
        result["CLAUDE_CODE_DISABLE_THINKING"] = "0"
        let budget = environment["MAX_THINKING_TOKENS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidBudget = budget.flatMap(Int.init).map { $0 >= 1024 } ?? false
        if !hasValidBudget {
            result["MAX_THINKING_TOKENS"] = "32000"
        }
        return result
    }

    /// Programmatic settings load after user/project/local settings and can
    /// therefore reintroduce environment overrides after process launch. Pin
    /// only the four thinking controls in our single high-precedence payload;
    /// effort is aligned to the effective CLI/SDK value, or empty when the
    /// selected model exposes no effort control. Enterprise managed policy
    /// remains authoritative over programmatic settings.
    private static func thinkingSettingsEnvironment(
        _ environment: [String: String],
        effort: AgentReasoningEffort?
    ) -> [String: String] {
        let normalized = thinkingEnvironment(environment)
        let wireEffort: String = {
            switch effort {
            case .minimal, .low: return "low"
            case .medium: return "medium"
            case .high: return "high"
            case .xhigh, .ultracode: return "xhigh"
            case .max, .ultra: return "max"
            case .none: return ""
            }
        }()
        return [
            "CLAUDE_CODE_DISABLE_THINKING": "0",
            "CLAUDE_CODE_EFFORT_LEVEL": wireEffort,
            "DISABLE_INTERLEAVED_THINKING": "0",
            "MAX_THINKING_TOKENS": normalized["MAX_THINKING_TOKENS"] ?? "32000"
        ]
    }

    /// Builds a single `--settings <json>` pair (never two) for the Claude CLI.
    ///
    /// - Every effort injects thinking enablement + visible summaries.
    /// - Ultracode effort also injects `ultracode` + `enableWorkflows`.
    /// Shape is always `["--settings", "<json>"]` so consumers that
    /// take `.last` (SDK bridge payload) still receive the JSON string alone.
    static func ultracodeSettingsArgs(
        _ effort: AgentReasoningEffort?,
        environment: [String: String] = [:]
    ) -> [String] {
        let wantsUltracode = effort == .ultracode
        var settings: [String: Any] = [
            "alwaysThinkingEnabled": true,
            "showThinkingSummaries": true,
            "env": thinkingSettingsEnvironment(environment, effort: effort)
        ]
        if wantsUltracode {
            settings["ultracode"] = true
            settings["enableWorkflows"] = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            // Fail open: drop settings rather than emit invalid JSON.
            return []
        }
        return ["--settings", json]
    }

    /// RemoteCode owns the single settings payload that configures thinking
    /// and merges managed hooks. Drop caller duplicates so a later extra arg
    /// cannot silently disable that contract; preserve every unrelated arg.
    private static func extraArgsWithoutSettings(_ extraArgs: [String]) -> [String] {
        var sanitized: [String] = []
        var index = 0
        while index < extraArgs.count {
            let argument = extraArgs[index]
            if argument == "--settings" {
                index += min(2, extraArgs.count - index)
                continue
            }
            if argument.hasPrefix("--settings=") {
                index += 1
                continue
            }
            sanitized.append(argument)
            index += 1
        }
        return sanitized
    }

    /// Builds the `claude` CLI argv. Pure + static so the exact flag
    /// combination is regression-tested without spawning a process.
    /// `--print --output-format stream-json` MUST be accompanied by
    /// `--verbose` or the CLI rejects the run.
    public static func buildArgs(_ request: AgentRunRequest) -> [String] {
        var args: [String] = ["--print", "--output-format", "stream-json", "--verbose"]
        args.append(contentsOf: ["--mcp-config", botPeerMCPConfigJSON(environment: request.environment)])
        args.append(contentsOf: ["--allowedTools", automaticallyAllowedTools(environment: request.environment).joined(separator: ",")])
        args.append(contentsOf: ["--model", request.model])
        let prompt = request.providerPrompt
        let effort = normalizedReasoningEffort(request.reasoningEffort, model: request.model)
        args.append(contentsOf: effortArgs(effort, model: request.model))
        args.append(contentsOf: ultracodeSettingsArgs(effort, environment: request.environment))
        // Resume the prior session so the model keeps full context.
        if let ptid = request.providerThreadId, !ptid.isEmpty {
            args.append(contentsOf: ["--resume", ptid])
        }
        if request.interactionMode == .plan {
            args.append(contentsOf: ["--permission-mode", "plan"])
        } else {
            switch request.permissionMode {
            // CLI 2.1.250+ help lists `manual` (`default` remains an accepted alias).
            case .supervised: args.append(contentsOf: ["--permission-mode", "manual"])
            case .autoAcceptEdits: args.append(contentsOf: ["--permission-mode", "acceptEdits"])
            case .fullAccess: args.append(contentsOf: ["--permission-mode", "bypassPermissions"])
            }
        }
        args.append(contentsOf: extraArgsWithoutSettings(request.extraArgs))
        args.append(prompt)
        return args
    }

    public static func buildStreamingArgs(_ request: AgentRunRequest, forkFrom sourceProviderThreadId: String? = nil) -> [String] {
        var args: [String] = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--replay-user-messages",
            "--forward-subagent-text",
            "--include-hook-events",
            // Load the SAME filesystem settings an interactive `claude` session
            // does: user + project + local. Without this, `--print` mode ignores
            // ~/.claude and ./.claude entirely, so project/user SKILLS and custom
            // slash commands (e.g. `/task`), MCP servers, agents, and hooks are
            // all invisible — the agent could not run a skill the user sees in
            // interactive claude. Matches the old SDK bridge's settingSources.
            "--setting-sources", "user,project,local"
        ]
        args.append(contentsOf: ["--mcp-config", botPeerMCPConfigJSON(environment: request.environment)])
        args.append(contentsOf: ["--allowedTools", automaticallyAllowedTools(environment: request.environment).joined(separator: ",")])
        args.append(contentsOf: ["--model", request.model])
        let effort = normalizedReasoningEffort(request.reasoningEffort, model: request.model)
        args.append(contentsOf: effortArgs(effort, model: request.model))
        args.append(contentsOf: ultracodeSettingsArgs(effort, environment: request.environment))
        if let source = sourceProviderThreadId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty,
           let child = request.providerThreadId, !child.isEmpty {
            args.append(contentsOf: ["--resume", source, "--fork-session", "--session-id", child])
        } else if let ptid = request.providerThreadId, !ptid.isEmpty {
            args.append(contentsOf: ["--resume", ptid])
        } else {
            args.append(contentsOf: ["--session-id", request.threadId.value.uuidString])
        }
        if request.interactionMode == .plan {
            args.append(contentsOf: ["--permission-mode", "plan"])
        } else {
            switch request.permissionMode {
            // CLI 2.1.250+ help lists `manual` (`default` remains an accepted alias).
            case .supervised: args.append(contentsOf: ["--permission-mode", "manual"])
            case .autoAcceptEdits: args.append(contentsOf: ["--permission-mode", "acceptEdits"])
            case .fullAccess: args.append(contentsOf: ["--permission-mode", "bypassPermissions"])
            }
        }
        // CLAUDE-CLI-014: non-image attachments outside cwd need --add-dir so Read/Edit
        // can touch those parent directories. Images ride base64 content blocks instead.
        for dir in extraAddDirs(cwd: request.cwd, attachments: request.attachments) {
            args.append(contentsOf: ["--add-dir", dir])
        }
        // UX-MAC_AGENT-BG-AWAIT: always make the agent self-declare a background-await
        // stall with `awaitingMarker` so the host recovers it regardless of phrasing.
        // Also carries the MCP-tool-availability rule so the agent does not preemptively
        // refuse a connected MCP tool as "unauthenticated" in a non-interactive run
        // (both live via `alwaysOnClaudeDirectives`).
        // `--append-system-prompt` adds to the CLI's default prompt, so it stays additive.
        let providerDirectives = BotPeerDelegation.appendingTurnContext(
            to: BackgroundAwaitContinuation.alwaysOnClaudeDirectives,
            environment: request.environment
        )
        let appendedSystemPrompt = AgentSkillInstaller.nestedAgentProviderPrompt(
            providerDirectives,
            environment: request.environment
        )
        args.append(contentsOf: ["--append-system-prompt", appendedSystemPrompt])
        args.append(contentsOf: extraArgsWithoutSettings(request.extraArgs))
        return args
    }

    /// Parent directories for non-image attachments that live outside `cwd`.
    /// Sorted + de-duplicated so argv stays stable for tests.
    nonisolated static func extraAddDirs(cwd: String, attachments: [AgentAttachment]) -> [String] {
        guard !attachments.isEmpty else { return [] }
        let cwdPath = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        var dirs = Set<String>()
        for attachment in attachments {
            let mime = attachment.mimeType ?? ""
            let isImage = attachment.kind == .image || mime.hasPrefix("image/")
            if isImage { continue }
            let parent = URL(fileURLWithPath: attachment.path)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .standardizedFileURL
            let parentPath = parent.path
            guard !parentPath.isEmpty else { continue }
            if parentPath == cwdPath { continue }
            if parentPath.hasPrefix(cwdPath.hasSuffix("/") ? cwdPath : cwdPath + "/") { continue }
            dirs.insert(parentPath)
        }
        return dirs.sorted()
    }

    /// Claude Code does not discover `mcpServers` from settings.json. Admit the
    /// managed peer server through the documented per-process `--mcp-config`
    /// input so every CLI turn gets the exact run context authored by the host.
    /// User/project MCP sources remain enabled because this is not strict mode.
    /// Provider tool names auto-approved for supervised Claude runs: the bot
    /// peer tools always (matching the servers actually admitted for the run).
    static func automaticallyAllowedTools(environment: [String: String]) -> [String] {
        var tools = BotSelfConfigMCPAdmit.claudeAutomaticallyAllowedTools
        if environment[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey] == "1" {
            // The server may be the installed mac-use release, whose tools have other names
            // (see ManagedMacUse), so the server is allowed as a whole as well as by tool.
            tools.append("mcp__\(ComputerUseMCPAdmit.serverName)")
            tools += ManagedComputerUseMCP.advertisedToolNames.map {
                "mcp__\(ComputerUseMCPAdmit.serverName)__\($0)"
            }
        }
        return tools
    }

    static func botPeerMCPConfigJSON(
        environment: [String: String],
        command: String? = nil
    ) -> String {
        let resolved = command
            ?? AgentSkillInstaller.resolveServiceBinary()?.path
            ?? BotSelfConfigMCPAdmit.fallbackCommand
        var servers: [String: Any] = [
            BotSelfConfigMCPAdmit.serverName: BotSelfConfigMCPAdmit.claudeSDKServer(
                command: resolved,
                environment: environment
            )
        ]
        if environment[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey] == "1" {
            servers[ComputerUseMCPAdmit.serverName] = ComputerUseMCPAdmit.stdioConfig(command: resolved)
        }
        let object: [String: Any] = ["mcpServers": servers]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"mcpServers":{}}"#
        }
        return json
    }

    /// Human-readable error shown when the provider binary is absent from PATH.
    /// Includes the most common install paths so users can diagnose the issue
    /// without opening a terminal.
    nonisolated static func missingBinaryMessage(_ binary: String) -> String {
        "\(binary) not found. Install the Claude CLI (native installer: " +
        "curl -fsSL https://claude.ai/install.sh | bash, or Homebrew), then reopen the app. " +
        "Searched: ~/.remote-code/bin, /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.npm-global/bin. " +
        "Or set a custom path in Settings \u{2192} Diagnostics."
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? request.providerBinary! : (binaryNameOverride ?? "claude")
        guard let path = ProcessLocator.resolve(binary) else {
            onEvent(.error(Self.missingBinaryMessage(binary)))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: nil))
            throw AgentRunError.missingBinary(binary)
        }

        let args = Self.buildArgs(request)
        let proc: Process
        do {
            proc = try ProviderSubprocessLauncher.makeProcess(
                provider: .claude,
                executablePath: path,
                arguments: args,
                currentDirectory: request.cwd,
                environment: Self.thinkingEnvironment(request.environment),
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
        // Never block waiting on stdin — the prompt is an arg. Without this
        // a provider can sit "running" forever reading a TTY that isn't there.
        proc.standardInput = FileHandle.nullDevice

        let parser = ClaudeParser()
        let timeline = TimelineAggregator()
        let outBuf = LineBuffer()
        // Serializes the stdout readabilityHandler against the termination
        // drain: nil-ing a readabilityHandler does not wait for a callback
        // already running, and LineBuffer is not thread-safe. Taken BEFORE
        // the fd read so byte order is preserved across the two readers.
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
                    provider: .claude,
                    source: "claude.stream-json.stderr"
                ))))
                onEvent(.error("[claude stderr] " + visible))
            }
        }

        proc.terminationHandler = { p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Drain bytes that arrived between the last read and EOF, plus
            // the final unterminated line, before finalizing the parser.
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
            // Mirror the stdout drain for stderr: a CLI that exits instantly
            // (auth error, crash banner) writes the only explanation to
            // stderr, and the async handler can lose the race with the
            // teardown above, leaving the bytes undelivered in the pipe.
            let stderrTail = BoundedPipeDrain.readRemaining(
                from: stderrPipe.fileHandleForReading,
                maxBytes: BoundedPipeDrain.defaultStderrMaxBytes
            )
            if !stderrTail.isEmpty,
               let visible = Self.displayableStderr(String(data: stderrTail, encoding: .utf8) ?? "") {
                onEvent(.event(.providerRuntime(ProviderStderrClassifier.runtimeEvent(
                    message: visible,
                    provider: .claude,
                    source: "claude.stream-json.stderr"
                ))))
                onEvent(.error("[claude stderr] " + visible))
            }
            for ev in parser.finalize() {
                timeline.apply(ev)
                onEvent(.event(ev))
            }
            let status = Self.terminalStatus(
                cancelRequested: cancelFlag.isCancelled,
                terminationReason: p.terminationReason,
                terminationStatus: p.terminationStatus
            )
            onEvent(.status(status))
            onEvent(.finished(status, finalMessage: timeline.finalAssistantMessage, providerThreadId: timeline.providerThreadId))
        }

        do {
            try proc.run()
            try ProcessSpawnTagger.tagProcess(proc, provider: .claude)
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
        parser: ClaudeParser,
        receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> (runtimeEvent: ProviderRuntimeEvent?, parsedEvents: [AssistantEvent]) {
        let object = jsonObject(from: line)
        return (
            object.flatMap {
                ProviderRuntimeEvent.fromJSONObjectIfNeeded(
                    $0, provider: .claude, source: "claude.stream-json", receivedAtMs: receivedAtMs
                )
            },
            object.map { parser.parseObject($0, now: receivedAtMs) } ?? []
        )
    }

    public static func shouldDisplayStderr(_ raw: String) -> Bool {
        displayableStderr(raw) != nil
    }

    nonisolated static func terminalStatus(
        cancelRequested: Bool,
        terminationReason: Process.TerminationReason,
        terminationStatus: Int32
    ) -> AgentRunStatus {
        if cancelRequested { return .cancelled }
        return terminationReason == .exit && terminationStatus == 0 ? .completed : .failed
    }

    public static func displayableStderr(_ raw: String) -> String? {
        ProviderStderrClassifier.displayableStderr(raw, provider: .claude)
    }
}
