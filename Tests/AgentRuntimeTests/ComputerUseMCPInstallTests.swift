import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime

final class ComputerUseMCPInstallTests: XCTestCase {
    private func tempHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-cu-\(UUID().uuidString)", isDirectory: true)
    }

    func test_installComputerUseMCPAdmitsClaudeAndCodexWithoutClobberingUserServers() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("bin/RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark","mcpServers":{"other":{"command":"x"}}}"#.utf8).write(to: claudeSettings)
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt\"\n".utf8).write(to: codexConfig)

        let installer = AgentSkillInstaller(homeDirectory: home)
        try installer.installComputerUseMCP(serviceBinaryURL: binary)
        try installer.installComputerUseMCP(serviceBinaryURL: binary)

        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any])
        XCTAssertEqual(settings["theme"] as? String, "dark")
        let servers = try XCTUnwrap(settings["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"], "leftover user MCP remains after admit")
        let ours = try XCTUnwrap(servers[ComputerUseMCPAdmit.serverName] as? [String: Any])
        XCTAssertEqual(ours["command"] as? String, binary.path)
        XCTAssertEqual(ours["args"] as? [String], [ComputerUseMCPAdmit.cliArgument])

        let toml = try String(contentsOf: codexConfig, encoding: .utf8)
        XCTAssertTrue(toml.contains("model = \"gpt\""))
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedCodexTOML(toml))
        XCTAssertEqual(toml.components(separatedBy: ComputerUseMCPAdmit.tomlBeginMarker).count - 1, 1)
    }

    func test_grokSessionAdmitUsesTheSameServerAndKeepsLeftovers() {
        let leftover: [Any] = [["name": "user-slack", "command": "npx"]]
        let servers = GrokACPClient.sessionMCPServers(
            existing: leftover,
            command: "/tmp/RemoteCodeDistillService",
            environment: [AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey: "1"]
        )
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedGrokACP(servers))
        let names = servers.compactMap { ($0 as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("user-slack"))
        XCTAssertEqual(names.filter { $0 == ComputerUseMCPAdmit.serverName }.count, 1)
    }

    func test_dockerProviderSurfaceExcludesHostMCPButRetainsGuestComputer() {
        // WHY: a global provider config must not turn Docker into physical-host
        // control. Docker keeps its bot_computer MCP and guest browser lanes.
        let dockerEnvironment = ["RC_REMOTE_CODE_BOT_ID": UUID().uuidString]
        let servers = GrokACPClient.sessionMCPServers(
            existing: [],
            command: "/tmp/RemoteCodeDistillService",
            environment: dockerEnvironment
        )
        XCTAssertFalse(ComputerUseMCPAdmit.containsAdmittedGrokACP(servers))
        XCTAssertTrue(BotComputerMCPAdmit.containsAdmittedGrokACP(servers))
        XCTAssertTrue(BotBrowserMCPAdmit.containsAdmittedGrokACP(servers))
    }

    func test_codexHostOverrideIsPerProcessAndAbsentForDocker() {
        let host = CodexRunner.computerUseMCPOverrides(
            environment: [AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey: "1"],
            command: "/tmp/RemoteCodeDistillService"
        )
        XCTAssertEqual(host, [
            "-c", "mcp_servers.\(ComputerUseMCPAdmit.serverName).command=\"/tmp/RemoteCodeDistillService\"",
            "-c", "mcp_servers.\(ComputerUseMCPAdmit.serverName).args=[\"\(ComputerUseMCPAdmit.cliArgument)\"]",
        ])
        XCTAssertEqual(
            CodexRunner.computerUseMCPOverrides(environment: ["RC_REMOTE_CODE_BOT_ID": UUID().uuidString]),
            []
        )
    }

    func test_claudeHostMCPIsExplicitlyLogicalOnly() throws {
        let hostJSON = ClaudeRunner.botPeerMCPConfigJSON(
            environment: [AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey: "1"],
            command: "/tmp/RemoteCodeDistillService"
        )
        let host = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hostJSON.utf8)) as? [String: Any])
        let hostServers = try XCTUnwrap(host["mcpServers"] as? [String: Any])
        XCTAssertNotNil(hostServers[ComputerUseMCPAdmit.serverName])

        let dockerJSON = ClaudeRunner.botPeerMCPConfigJSON(environment: [:], command: "/tmp/RemoteCodeDistillService")
        let docker = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dockerJSON.utf8)) as? [String: Any])
        let dockerServers = try XCTUnwrap(docker["mcpServers"] as? [String: Any])
        XCTAssertNil(dockerServers[ComputerUseMCPAdmit.serverName])
    }

    func test_claudeSDKParityScopesNativeHostMCPAndAutoAllowToLogicalRuns() {
        // WHY: Claude's SDK and CLI seams must make the same per-run decision;
        // a persisted global MCP entry must never expose host control to Docker.
        let hostEnvironment = [AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey: "1"]
        let hostServers = ClaudeAgentSDKBridgeAdapter.botPeerMCPServers(
            environment: hostEnvironment,
            command: "/tmp/RemoteCodeDistillService"
        )
        XCTAssertNotNil(hostServers[ComputerUseMCPAdmit.serverName])

        let dockerServers = ClaudeAgentSDKBridgeAdapter.botPeerMCPServers(
            environment: [:],
            command: "/tmp/RemoteCodeDistillService"
        )
        XCTAssertNil(dockerServers[ComputerUseMCPAdmit.serverName])

        let nativeNames = Set(ManagedComputerUseMCP.advertisedToolNames.map {
            "mcp__\(ComputerUseMCPAdmit.serverName)__\($0)"
        })
        let hostAllowed = Set(ClaudeRunner.automaticallyAllowedTools(environment: hostEnvironment))
        let dockerAllowed = Set(ClaudeRunner.automaticallyAllowedTools(environment: [:]))
        XCTAssertEqual(hostAllowed.intersection(nativeNames), nativeNames)
        XCTAssertTrue(dockerAllowed.isDisjoint(with: nativeNames))
        // WHY: the server can be the installed mac-use release, whose tool names differ from
        // the built-in ones. Allowed only by name, every mac-use tool would ask for approval.
        XCTAssertTrue(hostAllowed.contains("mcp__\(ComputerUseMCPAdmit.serverName)"))
        XCTAssertFalse(dockerAllowed.contains("mcp__\(ComputerUseMCPAdmit.serverName)"))
    }

    func test_defaultAdmitPathCoversClaudeCodexAndGrok() {
        let command = "/tmp/RemoteCodeDistillService"
        let claude = ComputerUseMCPAdmit.admitClaude(existing: [:], command: command)
        let grok = ComputerUseMCPAdmit.admitGrokACP(existing: [], command: command)
        let codex = ComputerUseMCPAdmit.admitCodexTOML(existing: "", command: command)
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedClaude(claude))
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedGrokACP(grok))
        XCTAssertTrue(ComputerUseMCPAdmit.containsAdmittedCodexTOML(codex))
        XCTAssertEqual(
            (claude[ComputerUseMCPAdmit.serverName] as? [String: Any])?["args"] as? [String],
            [ComputerUseMCPAdmit.cliArgument]
        )
    }
}
