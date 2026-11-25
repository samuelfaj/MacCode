import XCTest
import CoreModel
@testable import AgentRuntime

/// The guest run's environment is an allowlist: the Mac provider environment
/// is full of host paths and host-only lanes that would point the guest agent
/// at the wrong home, the wrong binaries or the Mac app's private socket.
final class DistillGuestEnvironmentTests: XCTestCase {
    private let botID = "6F1D1E64-6D43-4C35-8E57-2D2C70E1B0AA"
    private let threadID = "0C2D8185-1111-2222-3333-444455556666"
    private let runID = "A1382CD6-0000-4000-8000-000000000001"

    /// Everything a Mac Distill bot run gets today.
    private var macProviderEnvironment: [String: String] {
        [
            "PATH": "/Users/me/.remote-code/bin:/opt/homebrew/bin:/usr/bin",
            "HOME": "/Users/me",
            "DISTILL_HOME": "/Users/me/.distill",
            "REMOTE_CODE_AGENT_PROVIDER": "distill",
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            "RC_TOKEN_SAVER_THREAD_ID": threadID,
            "RC_GRAPHIFY_ROOT": "/Users/me/dev/app",
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": "/Users/me/Library/Application Support/RemoteCode",
            "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": "/tmp/RemoteCode.sock",
            "RC_REMOTE_CODE_MANAGED_BIN": "/Users/me/.remote-code/bin",
            "RC_REMOTE_CODE_DELEGATION_CAPABILITY": "cap-secret",
            "RC_REMOTE_CODE_ROOT_RUN_ID": runID,
            "RC_REMOTE_CODE_BOT_ID": botID,
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": threadID,
            "RC_REMOTE_CODE_BOT_SECRET_NAMES": "STRIPE_KEY,PATH,GITHUB_TOKEN",
            "STRIPE_KEY": "sk_test_bot",
            "GITHUB_TOKEN": "ghp_bot",
            "OPENROUTER_API_KEY": "or-host",
            "SSH_AUTH_SOCK": "/private/tmp/launchd/Listeners",
        ]
    }

    private func build(
        providerEnvironment: [String: String]? = nil,
        modelSecrets: [String: String] = [:],
        gitIdentity: GitIdentity? = GitIdentity(name: "Ada Lovelace", email: "ada@example.com"),
        codexClientVersion: String? = nil
    ) -> [String: String] {
        DistillGuestEnvironment.build(
            providerEnvironment: providerEnvironment ?? macProviderEnvironment,
            runID: runID,
            gatewayToken: "gw-token",
            modelSecrets: modelSecrets,
            gitIdentity: gitIdentity,
            codexClientVersion: codexClientVersion
        )
    }

    /// The nesting ceiling is a host setting that lands in the Mac run's
    /// environment; a guest run gets the same subagents, so it must get the
    /// same ceiling, and nothing when the setting is off.
    func test_highParallelismNestingDepthFollowsTheHostRun() {
        var configured = macProviderEnvironment
        configured[AgentHostEnvironmentMerge.highParallelismEnvironmentKey] =
            AgentHostEnvironmentMerge.highParallelismDepth
        XCTAssertEqual(
            build(providerEnvironment: configured)["GROK_SUBAGENTS_MAX_DEPTH"], "2",
            "the VM Bot run must keep the host's nesting ceiling"
        )
        XCTAssertEqual(
            build(providerEnvironment: configured, modelSecrets: ["GROK_SUBAGENTS_MAX_DEPTH": "9"])["GROK_SUBAGENTS_MAX_DEPTH"],
            "2",
            "a model secret cannot raise the ceiling past the host's value"
        )
        XCTAssertNil(build()["GROK_SUBAGENTS_MAX_DEPTH"], "off: the key is not set")
    }

    func test_macPathsTokenSaverAndHostLanesNeverReachTheGuest() {
        let env = build()
        XCTAssertTrue(env.keys.filter { $0.hasPrefix("RC_TOKEN_SAVER") || $0.hasPrefix("RC_GRAPHIFY") }.isEmpty)
        XCTAssertEqual(env.keys.filter { $0.hasPrefix("RC_REMOTE_CODE_") }.sorted(),
                       ["RC_REMOTE_CODE_BOT_ID", "RC_REMOTE_CODE_SUBAGENT_THREAD_ID"])
        XCTAssertNil(env["REMOTE_CODE_AGENT_PROVIDER"])
        XCTAssertNil(env["SSH_AUTH_SOCK"])
        XCTAssertNil(env["OPENROUTER_API_KEY"], "model keys come only from the rendered config's secrets")
        XCTAssertFalse(env.values.contains { $0.contains("/Users") || $0.contains("RemoteCode.sock") })
        XCTAssertEqual(env["HOME"], "/home/remotecode")
        XCTAssertEqual(env["USER"], "remotecode")
        XCTAssertEqual(env["DISTILL_HOME"], "/home/remotecode/.distill")
        XCTAssertEqual(env["PATH"], "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        XCTAssertEqual(env["DISPLAY"], ":1")
    }

    /// Gateway calls and kill-agent identify the run; the bot's own secrets
    /// are what its tools use on the Mac, so they follow it into the guest.
    func test_runIdentityBotIdentityAndBotSecretsFollowTheRun() {
        let env = build()
        XCTAssertEqual(env["RC_GUEST_RUN_ID"], runID)
        XCTAssertEqual(env["RC_GUEST_GATEWAY_TOKEN"], "gw-token")
        XCTAssertEqual(env["RC_REMOTE_CODE_BOT_ID"], botID)
        XCTAssertEqual(env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], threadID)
        XCTAssertEqual(env["STRIPE_KEY"], "sk_test_bot")
        XCTAssertEqual(env["GITHUB_TOKEN"], "ghp_bot")
    }

    /// Guest paths and run identity cannot be overridden by a model key or a
    /// bot secret that happens to share the name.
    func test_guestValuesWinOverSecretsWithTheSameName() {
        let env = build(modelSecrets: [
            "HOME": "/Users/me",
            "RC_GUEST_GATEWAY_TOKEN": "forged",
            "RC_GUEST_MODEL_KEY_1": "sk-model",
        ])
        XCTAssertEqual(env["HOME"], "/home/remotecode")
        XCTAssertEqual(env["RC_GUEST_GATEWAY_TOKEN"], "gw-token")
        XCTAssertEqual(env["RC_GUEST_MODEL_KEY_1"], "sk-model")
    }

    /// D6: commits the guest agent makes carry the user's name; workspaces are
    /// bound from the Mac with the Mac's uid, which git otherwise refuses.
    func test_commitsCarryTheUsersIdentityAndBoundWorkspacesAreTrusted() {
        let env = build()
        XCTAssertEqual(env["GIT_AUTHOR_NAME"], "Ada Lovelace")
        XCTAssertEqual(env["GIT_AUTHOR_EMAIL"], "ada@example.com")
        XCTAssertEqual(env["GIT_COMMITTER_NAME"], "Ada Lovelace")
        XCTAssertEqual(env["GIT_COMMITTER_EMAIL"], "ada@example.com")
        XCTAssertEqual(env["GIT_CONFIG_COUNT"], "1")
        XCTAssertEqual(env["GIT_CONFIG_KEY_0"], "safe.directory")
        XCTAssertEqual(env["GIT_CONFIG_VALUE_0"], "*")
        XCTAssertNil(build(gitIdentity: nil)["GIT_AUTHOR_NAME"], "no identity is invented")
    }

    /// Distill would otherwise also import MCP servers from Claude Code and
    /// Cursor configs; the guest's set must be exactly its config.toml.
    func test_claudeAndCursorMCPImportsAreOff() {
        let env = build()
        XCTAssertEqual(env["GROK_CLAUDE_MCPS_ENABLED"], "0")
        XCTAssertEqual(env["GROK_CURSOR_MCPS_ENABLED"], "0")
    }

    /// Every guest run is a bot run: Distill's default caveman level `full`
    /// drops articles ("Fala tarefa."), so the guest pins `lite`, and a model
    /// secret of the same name cannot set it back.
    func test_guestBotRunsUseLiteCaveman() {
        XCTAssertEqual(build()["GROK_CAVEMAN"], "lite")
        XCTAssertEqual(build(modelSecrets: ["GROK_CAVEMAN": "full"])["GROK_CAVEMAN"], "lite")
    }

    /// The guest has no `codex` to read a version from, so without the Mac's
    /// it asks ChatGPT for models as Distill's default and misses the newest
    /// ones the Mac lists (and the model picker offers).
    func test_theMacsCodexClientVersionFollowsTheRunSoTheGuestListsTheSameChatGPTModels() {
        XCTAssertEqual(build(codexClientVersion: "0.162.1")["DISTILL_CODEX_CLIENT_VERSION"], "0.162.1")
        XCTAssertFalse(build().keys.contains("DISTILL_CODEX_CLIENT_VERSION"),
                       "unresolved on the Mac: no variable at all, so the guest uses Distill's default as the Mac does")
    }

    /// The version is read from the Mac and let through the allowlist; it
    /// must not become a way to write another line into the env file, and
    /// a secret that shares its name must not choose what the guest asks as.
    func test_onlyAVersionCanBeSetAsTheCodexClientVersion() throws {
        for unsafe in ["0.162.1\nHOME=/Users/me", "", " 0.162.1", "latest"] {
            let env = build(codexClientVersion: unsafe)
            XCTAssertNil(env["DISTILL_CODEX_CLIENT_VERSION"], unsafe.debugDescription)
            XCTAssertNoThrow(try DistillGuestEnvironment.envFileContents(env),
                             "a value that is not a version is dropped; it must not fail the run")
        }
        let forged = ["DISTILL_CODEX_CLIENT_VERSION": "9.9.9"]
        XCTAssertEqual(build(modelSecrets: forged, codexClientVersion: "0.162.1")["DISTILL_CODEX_CLIENT_VERSION"], "0.162.1")
        XCTAssertNil(build(modelSecrets: forged)["DISTILL_CODEX_CLIENT_VERSION"],
                     "the Mac resolved none, so the guest gets none")
    }

    /// A bare `KEY` line makes the docker CLI copy the Mac's own value of KEY,
    /// so every line must be `KEY=value`, even for an empty value.
    func test_envFileLinesAreAlwaysKeyEqualsValue() throws {
        let contents = try DistillGuestEnvironment.envFileContents(build().merging(["EMPTY": ""]) { $1 })
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            XCTAssertEqual(parts.count, 2, String(line))
            XCTAssertTrue(DistillGuestConfig.isEnvironmentName(String(parts[0])), String(line))
        }
        XCTAssertTrue(lines.contains("EMPTY="))
        XCTAssertTrue(contents.hasSuffix("\n"))
    }

    /// A line break would smuggle a second variable into the file; the error
    /// names only the key so a secret never lands in a log or banner.
    func test_lineBreakInAValueThrowsNamingOnlyTheKey() {
        XCTAssertThrowsError(try DistillGuestEnvironment.envFileContents(["STRIPE_KEY": "sk\nHOME=/Users/me"])) { error in
            XCTAssertEqual(error as? DistillGuestEnvironmentError, .invalidValue(key: "STRIPE_KEY"))
            XCTAssertFalse(error.localizedDescription.contains("/Users/me"))
        }
        XCTAssertThrowsError(try DistillGuestEnvironment.envFileContents(["A": "x\ry"]))
        XCTAssertThrowsError(try DistillGuestEnvironment.envFileContents(["BAD KEY": "x"])) { error in
            XCTAssertEqual(error as? DistillGuestEnvironmentError, .invalidName("BAD KEY"))
        }
    }

    func test_writeRunFilesWritesConfigAndPrivateEnvWithGuestHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistillGuestRunFiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configDirectory = root.appendingPathComponent(".distill", isDirectory: true)
        let rendered = DistillGuestConfig.Rendered(toml: "model = \"test\"\n", secretEnvironment: [:], droppedModels: [:])
        let file = try DistillGuestEnvironment.writeRunFiles(
            rendered: rendered,
            configDirectory: configDirectory,
            guestDistillHome: "/guest/.distill",
            providerEnvironment: macProviderEnvironment,
            runID: runID,
            gatewayToken: "secret-gateway-token",
            gitIdentity: nil,
            codexClientVersion: nil,
            runsDirectory: root.appendingPathComponent("guest-runs", isDirectory: true)
        )
        let config = try String(contentsOf: configDirectory.appendingPathComponent("config.toml"), encoding: .utf8)
        let environment = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(config.contains("secret-gateway-token"))
        XCTAssertTrue(environment.contains("DISTILL_HOME=/guest/.distill\n"))
        XCTAssertTrue(environment.contains("RC_GUEST_GATEWAY_TOKEN=secret-gateway-token\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func test_writeRunFilesRejectsInvalidEnvironmentBeforeConfigSideEffect() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistillGuestRunFiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configDirectory = root.appendingPathComponent(".distill", isDirectory: true)
        let rendered = DistillGuestConfig.Rendered(toml: "model = \"test\"\n", secretEnvironment: [:], droppedModels: [:])
        XCTAssertThrowsError(try DistillGuestEnvironment.writeRunFiles(
            rendered: rendered,
            configDirectory: configDirectory,
            guestDistillHome: "/guest/.distill",
            providerEnvironment: macProviderEnvironment,
            runID: runID,
            gatewayToken: "bad\nvalue",
            gitIdentity: nil,
            codexClientVersion: nil,
            runsDirectory: root.appendingPathComponent("guest-runs", isDirectory: true)
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configDirectory.path))
    }

    /// The file holds model keys and the gateway bearer: owner-only, in an
    /// owner-only directory, named by a real run id.
    func test_envFileIsOwnerOnlyAndNamedByTheRunID() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("DistillGuestEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let directory = DistillGuestEnvironment.runsDirectory(appSupport: appSupport)
        let env = build()

        let file = try DistillGuestEnvironment.writeEnvFile(env, runID: runID, directory: directory)
        XCTAssertEqual(file.lastPathComponent, "\(runID).env")
        XCTAssertEqual(directory.lastPathComponent, "guest-runs")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), try DistillGuestEnvironment.envFileContents(env))
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(directoryMode, 0o700)

        // Rewriting replaces the file rather than appending to it.
        try DistillGuestEnvironment.writeEnvFile(["ONLY": "1"], runID: runID, directory: directory)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ONLY=1\n")

        XCTAssertThrowsError(try DistillGuestEnvironment.writeEnvFile(env, runID: "../escape", directory: directory)) { error in
            XCTAssertEqual(error as? DistillGuestEnvironmentError, .invalidRunID("../escape"))
        }
    }
}
