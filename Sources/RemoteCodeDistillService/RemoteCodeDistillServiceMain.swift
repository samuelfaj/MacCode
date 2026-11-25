import AgentRuntime
import CoreModel
import Darwin
import Foundation
import Persistence

@main
struct RemoteCodeDistillServiceMain {
    static func main() async {
        let rawArgs = CommandLine.arguments
        let programName = (rawArgs.first as NSString?)?.lastPathComponent ?? ""
        if rawArgs.dropFirst().first == ChromeProfileConnection.hostArgument {
            do { try ChromeProfileConnection.runHost(origin: rawArgs.dropFirst(2).first ?? "") }
            catch {
                // The host exits after telling the caller why; Chrome starts a clean one when the
                // extension reconnects.
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                Darwin.exit(1)
            }
            return
        }
        // Subagent telemetry, including the legacy `distill subagent` and
        // `cli subagent` forms that older orchestrate skills still call.
        if programName == "distill", rawArgs.dropFirst().first == "subagent" {
            await runSubagentTelemetry(arguments: Array(rawArgs.dropFirst(2)))
            return
        }
        if rawArgs.dropFirst().first == "cli", rawArgs.dropFirst(2).first == "subagent" {
            await runSubagentTelemetry(arguments: Array(rawArgs.dropFirst(3)))
            return
        }
        if programName == "RemoteCodeDistillService",
           rawArgs.dropFirst().first == "subagent" {
            await runSubagentTelemetry(arguments: Array(rawArgs.dropFirst(2)))
            return
        }
        if programName == AgentSkillInstaller.agentAppMiddlewareCommand {
            let code = ProviderProxyRunner.runAgentAppCLI(
                arguments: Array(rawArgs.dropFirst())
            )
            Darwin.exit(code)
        }
        if rawArgs.dropFirst().first == LeaseHookCommand.cliArgument {
            // Distill PreToolUse hook: always exits 0 so a MacCode outage never blocks an edit.
            let input = isatty(STDIN_FILENO) == 0 ? FileHandle.standardInput.readDataToEndOfFile() : Data()
            if let output = LeaseHookCommand.runFromProcess(stdin: input, environment: ProcessInfo.processInfo.environment) {
                print(output)
            }
            Darwin.exit(0)
        }
        if programName == "rc-computer-use-mcp"
            || rawArgs.dropFirst().first == ComputerUseHostQueue.cliArgument {
            await runComputerUseMCP()
            return
        }
        if programName == "rc-bot-self-config"
            || rawArgs.dropFirst().first == BotSelfConfigCatalog.cliArgument {
            runBotSelfConfigMCP()
            return
        }
        if programName == "rc-bot-browser"
            || rawArgs.dropFirst().first == BotBrowserCatalog.cliArgument {
            runBotBrowserMCP()
            return
        }
        if programName == "rc-bot-web"
            || rawArgs.dropFirst().first == BotWebCatalog.cliArgument {
            await runBotWebMCP()
            return
        }
        if programName == "rc-bot-computer"
            || rawArgs.dropFirst().first == BotComputerCatalog.cliArgument {
            await runBotComputerMCP()
            return
        }
        // Nested provider PATH controller: invoked via managed symlinks
        // (~/.remote-code/bin/{grok,claude,codex}) or explicit `provider-proxy <name> …`.
        // Records content-free Subagents receipts and execs the real CLI outside managed bin.
        if ProviderProxyPolicy.isProviderProxy(programName) {
            let code = ProviderProxyRunner.run(command: programName, arguments: Array(rawArgs.dropFirst()))
            Darwin.exit(code)
        }
        if rawArgs.dropFirst().first == "provider-proxy", rawArgs.count >= 3 {
            let code = ProviderProxyRunner.run(command: rawArgs[2], arguments: Array(rawArgs.dropFirst(3)))
            Darwin.exit(code)
        }
        let programArguments = Array(rawArgs.dropFirst())
        switch RemoteCodeServiceFallbackArgv.route(programName: programName, arguments: programArguments) {
        case .legacyHookNoOp:
            // Drain a piped hook payload so the provider never sees a broken pipe.
            if isatty(STDIN_FILENO) == 0 {
                _ = FileHandle.standardInput.readDataToEndOfFile()
            }
            Darwin.exit(0)
        case .passthrough(let command, let arguments):
            Darwin.exit(PassthroughExec.runInheritingStreams(command: command, args: arguments))
        case .usage:
            FileHandle.standardError.write(Data(usageText.utf8))
            Darwin.exit(64)
        }
    }

    /// Provider-neutral begin/end bridge for skill-controlled nested workers
    /// that are **not** a bare `grok`/`claude`/`codex` shell invocation.
    /// Nested provider CLIs are handled automatically by the PATH provider
    /// proxy (`ProviderProxyRunner`); skills should not wrap those basenames
    /// manually. This CLI still records metadata only — prompts, output, and
    /// secrets never enter the orchestration ledger.
    private static func runSubagentTelemetry(arguments: [String]) async {
        let env = ProcessInfo.processInfo.environment
        let appSupportOverride = env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]
        do {
            let (_, db) = try Bootstrap(
                channel: .debug,
                appSupportOverride: appSupportOverride
            ).run()
            let runtime = AgentOrchestrationRuntime(
                repository: AgentOrchestrationRepository(db: db),
                packageVerification: { true },
                rolloutGate: { true },
                killSwitch: { false }
            )
            guard let operation = arguments.first else { throw TelemetryError.usage }
            switch operation {
            case "begin":
                let nodeId = try argument(named: "--node", in: arguments)
                guard let scope = RemoteCodeSubagentTelemetryScope(environment: env),
                      let provider = AgentProvider(rawValue: env["REMOTE_CODE_AGENT_PROVIDER"] ?? ""),
                      let parentRunId = scope.parentRunId,
                      let parentThreadId = scope.parentThreadId,
                      let parentCapability = scope.parentCapability else {
                    throw TelemetryError.missingScope
                }
                let finalizationCapability = AgentDelegationCapability.issue()
                let child = try runtime.recordAuthenticatedTelemetryChild(
                    runId: AgentRunID(),
                    threadId: scope.threadId,
                    provider: provider,
                    providerInstanceId: env["REMOTE_CODE_PROVIDER_INSTANCE_ID"] ?? provider.rawValue,
                    model: env["REMOTE_CODE_AGENT_MODEL"] ?? "unknown",
                    nodeId: nodeId,
                    parentRunId: parentRunId,
                    parentThreadId: parentThreadId,
                    parentCapability: parentCapability,
                    finalizationCapability: finalizationCapability,
                    ownerProcessID: getppid() > 1 ? getppid() : getpid()
                )
                guard let childRunId = child.runId,
                      let handle = AgentExternalReceiptHandle.encode(
                        runId: childRunId,
                        finalizationCapability: finalizationCapability
                      ) else {
                    throw TelemetryError.invalidReceipt
                }
                print(handle)
            case "end":
                guard let handle = AgentExternalReceiptHandle.decode(
                    try argument(named: "--run-id", in: arguments)
                ) else {
                    throw TelemetryError.usage
                }
                guard let scope = RemoteCodeSubagentTelemetryScope(environment: env),
                      let parentRunId = scope.parentRunId,
                      let parentThreadId = scope.parentThreadId,
                      let parentCapability = scope.parentCapability else {
                    throw TelemetryError.missingScope
                }
                guard let status = AgentRunStatus(
                    rawValue: try argument(named: "--status", in: arguments)
                ), [.completed, .failed, .cancelled].contains(status) else {
                    throw TelemetryError.usage
                }
                try runtime.finalizeAuthenticatedExternalReceipt(
                    runId: handle.runId,
                    status: status,
                    parentRunId: parentRunId,
                    parentThreadId: parentThreadId,
                    parentCapability: parentCapability,
                    finalizationCapability: handle.finalizationCapability,
                    ownerProcessID: getppid() > 1 ? getppid() : getpid()
                )
            default:
                throw TelemetryError.usage
            }
        } catch {
            FileHandle.standardError.write(Data("RemoteCode subagent telemetry unavailable: \(error)\n".utf8))
            Darwin.exit(1)
        }
        Darwin.exit(0)
    }

    private static func argument(named name: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            throw TelemetryError.usage
        }
        return arguments[index + 1]
    }

    private enum TelemetryError: Error {
        case usage
        case missingScope
        case invalidReceipt
    }

    /// RemoteCode-owned computer-use MCP (stdio). HID calls share ComputerUseHostQueue.
    private static func runComputerUseMCP() async {
        // The newest installed mac-use release takes over when there is one (see ManagedMacUse);
        // it speaks the same protocol on the same stdio. execv returns only if it could not start.
        if let binary = ManagedMacUse.serverBinary() {
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(binary.path), nil]
            execv(binary.path, &argv)
        }
        let server = ManagedComputerUseMCP()
        // Read stdin off the main thread: the agent-cursor overlay is AppKit and needs the main
        // run loop, which async main keeps running while this function stays suspended.
        // EOF means the client went away, so close the tab it may have left open, then exit.
        Task.detached {
            while let line = readLine(strippingNewline: true) {
                if let response = await server.handle(line) {
                    FileHandle.standardOutput.write(Data((response + "\n").utf8))
                }
            }
            await server.closeBrowser()
            Darwin.exit(0)
        }
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }

    /// Bot-owned Studio settings. Bound to RC_REMOTE_CODE_BOT_ID on the calling run.
    private static func runBotSelfConfigMCP() {
        let server = ManagedBotSelfConfigMCP()
        while let line = readLine(strippingNewline: true) {
            if let response = server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    private static func runBotBrowserMCP() {
        let server = ManagedBotBrowserMCP()
        while let line = readLine(strippingNewline: true) {
            if let response = server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    private static func runBotWebMCP() async {
        let server = ManagedBotWebMCP()
        while let line = readLine(strippingNewline: true) {
            if let response = await server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    private static func runBotComputerMCP() async {
        let server = ManagedBotComputerMCP()
        while let line = readLine(strippingNewline: true) {
            if let response = await server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }

    private static let usageText = """
    usage: RemoteCodeDistillService <mode> [arguments]

    Modes:
      subagent begin|end …              Subagents telemetry receipts
      provider-proxy <name> [args …]    nested provider PATH controller
      \(ComputerUseHostQueue.cliArgument)              MacCode computer-use MCP (stdio)
      \(BotSelfConfigCatalog.cliArgument), \(BotBrowserCatalog.cliArgument), \(BotWebCatalog.cliArgument), \(BotComputerCatalog.cliArgument)
                                        bot MCP servers (stdio)

    """
}
