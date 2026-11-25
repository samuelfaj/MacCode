import Foundation
import CoreModel
import Persistence

public enum DistillGuestEnvironmentError: LocalizedError, Equatable {
    case invalidName(String)
    case invalidRunID(String)
    case invalidValue(key: String)
    case writeFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "\"\(name)\" cannot be passed to the Linux agent: it is not an environment variable name."
        case .invalidRunID(let runID):
            return "\"\(runID)\" is not a run id."
        case .invalidValue(let key):
            return "\(key) cannot be passed to the Linux agent: its value has a line break or NUL."
        case .writeFailed(let path, let code):
            return "Could not write the Linux agent's environment file \(path): \(String(cString: strerror(code)))."
        }
    }
}

/// The environment of an in-guest Distill run, passed with
/// `docker exec --env-file` so no value appears in the host process list.
///
/// It is an allowlist: the Mac provider environment is full of host paths and
/// host-only lanes (PATH, HOME, app support, the app socket, managed bin) that
/// mean nothing, or the wrong thing, inside the guest.
public enum DistillGuestEnvironment {
    public static let guestPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    public static let distillHome = "\(BotComputerGuestSpec.guestUserHome)/.distill"
    public static let runIDEnvironmentKey = "RC_GUEST_RUN_ID"

    /// - Parameters:
    ///   - providerEnvironment: what the same run would get on the Mac; only the
    ///     bot and thread identity and the bot's own secrets are taken from it.
    ///   - modelSecrets: `DistillGuestConfig.Rendered.secretEnvironment`.
    ///   - codexClientVersion: `DistillCodexClientVersion.resolve` for the Mac
    ///     run. Let through on purpose, for catalog parity: the
    ///     ChatGPT backend lists models by the client version asking, the
    ///     guest has no `codex` to read one from, and the model picker offers
    ///     what the Mac's Distill lists. It is a version number, not a secret,
    ///     so it needs no `[shell_environment_policy]` exclude. Nil, or a
    ///     value that is not a version, sets nothing: the guest then uses
    ///     Distill's built-in default.
    public static func build(
        providerEnvironment: [String: String],
        runID: String,
        gatewayToken: String,
        modelSecrets: [String: String],
        gitIdentity: GitIdentity?,
        codexClientVersion: String? = nil
    ) -> [String: String] {
        var env = modelSecrets
        // Bot secrets the user gave this bot, as the Mac run would see them.
        let names = providerEnvironment[BotSecretEnvironment.secretNamesEnvironmentKey] ?? ""
        for name in names.split(separator: ",").map(String.init)
        where BotKeychainSecretStore.isValidName(name) {
            if let value = providerEnvironment[name] { env[name] = value }
        }
        for key in [BotSecretEnvironment.botIDEnvironmentKey, BotPeerDelegation.threadEnvironmentKey] {
            if let value = providerEnvironment[key] { env[key] = value }
        }
        // The host decides the run's nesting ceiling (`AgentHostEnvironmentMerge`),
        // and a guest run gets the same subagents, so it gets the same value.
        if let depth = providerEnvironment[AgentHostEnvironmentMerge.highParallelismEnvironmentKey] {
            env[AgentHostEnvironmentMerge.highParallelismEnvironmentKey] = depth
        }
        if let gitIdentity {
            env["GIT_AUTHOR_NAME"] = gitIdentity.name
            env["GIT_AUTHOR_EMAIL"] = gitIdentity.email
            env["GIT_COMMITTER_NAME"] = gitIdentity.name
            env["GIT_COMMITTER_EMAIL"] = gitIdentity.email
        }
        // Workspaces are bound from the Mac and owned by its uid, not the
        // guest user's; without this git refuses them as "dubious ownership".
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "safe.directory"
        env["GIT_CONFIG_VALUE_0"] = "*"
        env["HOME"] = BotComputerGuestSpec.guestUserHome
        env["USER"] = BotComputerGuestSpec.agentUser
        env["DISTILL_HOME"] = distillHome
        env["PATH"] = guestPath
        env["DISPLAY"] = ":1"
        env["LANG"] = "C.UTF-8"
        // Distill would otherwise also load MCP servers from Claude Code and
        // Cursor configs it finds; the guest's set is exactly its config.toml.
        env["GROK_CLAUDE_MCPS_ENABLED"] = "0"
        env["GROK_CURSOR_MCPS_ENABLED"] = "0"
        // Every guest run is a bot run: same reply style as a Mac bot launch,
        // set after the secrets so none of them can make the bot terse.
        env.merge(BotRunMCPAdmission.distillBotReplyStyleEnvironment(environment: providerEnvironment)) { _, forced in forced }
        // After the secrets, like every guest value: no model key or bot
        // secret of the same name can set the version the guest asks as.
        env[DistillCodexClientVersion.environmentKey] = codexClientVersion
            .flatMap { DistillCodexClientVersion.isAcceptable($0) ? $0 : nil }
        env[runIDEnvironmentKey] = runID
        env[DistillGuestConfig.gatewayTokenEnvironmentKey] = gatewayToken
        return env
    }

    /// `KEY=value` lines. A bare `KEY` line would make the docker CLI copy the
    /// Mac's own value of KEY into the guest, so every line carries `=`, and a
    /// value cannot span lines.
    public static func envFileContents(_ environment: [String: String]) throws -> String {
        var lines = ""
        for key in environment.keys.sorted() {
            guard DistillGuestConfig.isEnvironmentName(key) else {
                throw DistillGuestEnvironmentError.invalidName(key)
            }
            let value = environment[key] ?? ""
            guard !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{0}" }) else {
                throw DistillGuestEnvironmentError.invalidValue(key: key)
            }
            lines += "\(key)=\(value)\n"
        }
        return lines
    }

    /// Writes one guest run's config and private environment file.
    public static func writeRunFiles(
        rendered: DistillGuestConfig.Rendered,
        configDirectory: URL,
        guestDistillHome: String,
        providerEnvironment: [String: String],
        runID: String,
        gatewayToken: String,
        gitIdentity: GitIdentity?,
        codexClientVersion: String?,
        runsDirectory: URL
    ) throws -> URL {
        guard UUID(uuidString: runID) != nil else { throw DistillGuestEnvironmentError.invalidRunID(runID) }
        var environment = build(
            providerEnvironment: providerEnvironment,
            runID: runID,
            gatewayToken: gatewayToken,
            modelSecrets: rendered.secretEnvironment,
            gitIdentity: gitIdentity,
            codexClientVersion: codexClientVersion
        )
        environment["DISTILL_HOME"] = guestDistillHome
        _ = try envFileContents(environment)
        let distillDirectory = try PrivateDirectory(configDirectory, create: true)
        defer { distillDirectory.close() }
        try distillDirectory.writeAtomically(Data(rendered.toml.utf8), to: "config.toml")
        return try writeEnvFile(environment, runID: runID, directory: runsDirectory)
    }

    /// `<AppSupport>/guest-runs`: one env file per live run, swept at launch.
    public static func runsDirectory(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("guest-runs", isDirectory: true)
    }

    /// Writes `<directory>/<runID>.env` readable only by this user, in a
    /// directory only this user can list.
    @discardableResult
    public static func writeEnvFile(
        _ environment: [String: String],
        runID: String,
        directory: URL
    ) throws -> URL {
        // run-agent only accepts a UUID, and the id names a file here.
        guard UUID(uuidString: runID) != nil else { throw DistillGuestEnvironmentError.invalidRunID(runID) }
        let contents = try envFileContents(environment)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, 0o700) == 0 else {
            throw DistillGuestEnvironmentError.writeFailed(path: directory.path, errno: errno)
        }
        let file = directory.appendingPathComponent("\(runID).env")
        unlink(file.path)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw DistillGuestEnvironmentError.writeFailed(path: file.path, errno: errno)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(contents.utf8))
        } catch {
            unlink(file.path)
            throw DistillGuestEnvironmentError.writeFailed(path: file.path, errno: EIO)
        }
        return file
    }
}
