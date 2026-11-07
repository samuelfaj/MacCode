import Foundation
import CoreModel
import Darwin

public enum RunAsUserProcessBootstrapError: Error, LocalizedError, Equatable {
    case helperUnavailable(String)
    case invalidTarget(String)
    case binaryNotAbsolute(String)
    case binaryNotAllowlisted(String)
    case invalidPMSetRequest(String)

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable(let detail):
            return "Run-as-user helper unavailable: \(detail)"
        case .invalidTarget(let detail):
            return "Cannot run as that macOS user: \(detail)"
        case .binaryNotAbsolute(let path):
            return "Provider binary must be an absolute path for run-as-user: \(path)"
        case .binaryNotAllowlisted(let name):
            return "Executable is not allowlisted for run-as-user: \(name)"
        case .invalidPMSetRequest(let detail):
            return "Invalid Insomnia pmset request: \(detail)"
        }
    }
}

/// Builds launches through the one-time installed root-owned helper. The
/// helper is the only place where RemoteCode crosses a macOS user boundary or
/// changes the system-wide clamshell sleep setting. Its installation may ask
/// for the current user's password once; the password is never persisted.
public enum RunAsUserProcessBootstrap {
    public static let sudoPath = "/usr/bin/sudo"
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/io.remotecode.RunAsUserHelper"
    public static let helperVersion = 4
    public static let helperExecutableNames = [
        "RemoteCodeRunAsUserHelper",
        "io.remotecode.RunAsUserHelper"
    ]

    public static let allowlistedBasenames: Set<String> = [
        "codex",
        "claude",
        "grok",
        "node",
        "npm"
    ]

    private static let installationLock = NSLock()
    public static var isHelperReady: Bool { isUsableInstalledHelper(at: installedHelperPath) }

    public struct LaunchPlan: Equatable, Sendable {
        public var executablePath: String
        public var arguments: [String]
        public var environment: [String: String]
        public var currentDirectory: String
        public var usesHelper: Bool

        public init(
            executablePath: String,
            arguments: [String],
            environment: [String: String],
            currentDirectory: String,
            usesHelper: Bool
        ) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.environment = environment
            self.currentDirectory = currentDirectory
            self.usesHelper = usesHelper
        }
    }

    /// Builds a launch plan for a provider running as another interactive user.
    /// The caller must install the helper first through `ensureHelperInstalled`.
    /// Keeping this function side-effect free means capability probes can fail
    /// closed without opening a password dialog.
    public static func plan(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String,
        provider: AgentProvider? = nil,
        runAsUser: AgentRunAsUser?,
        helperLocator: (String) -> String? = { name in
            guard name == RunAsUserProcessBootstrap.helperExecutableNames[0],
                  RunAsUserProcessBootstrap.isUsableInstalledHelper(at: RunAsUserProcessBootstrap.installedHelperPath) else {
                return nil
            }
            return RunAsUserProcessBootstrap.installedHelperPath
        },
        currentUID: uid_t = getuid()
    ) throws -> LaunchPlan {
        guard let runAsUser, runAsUser.uid != currentUID else {
            return LaunchPlan(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                usesHelper: false
            )
        }

        guard runAsUser.uid >= 501, runAsUser.uid != 0 else {
            throw RunAsUserProcessBootstrapError.invalidTarget("uid \(runAsUser.uid) is not an interactive user")
        }
        guard executablePath.hasPrefix("/") else {
            throw RunAsUserProcessBootstrapError.binaryNotAbsolute(executablePath)
        }
        let base = URL(fileURLWithPath: executablePath).lastPathComponent
        guard allowlistedBasenames.contains(base) else {
            throw RunAsUserProcessBootstrapError.binaryNotAllowlisted(base)
        }

        guard let helper = helperExecutableNames.compactMap(helperLocator).first else {
            throw RunAsUserProcessBootstrapError.helperUnavailable(
                "install RemoteCodeRunAsUserHelper once before selecting another macOS user"
            )
        }

        var helperArgs: [String] = [
            "exec",
            "--uid", "\(runAsUser.uid)",
            "--gid", "\(runAsUser.gid)",
            "--home", runAsUser.homePath,
            "--user", runAsUser.shortName,
            "--cwd", currentDirectory,
            "--",
            executablePath
        ]
        helperArgs.append(contentsOf: arguments)

        // The helper rebuilds HOME/USER/LOGNAME after dropping privileges. Do
        // not pass SUDO_ASKPASS through to the target user or retain a caller
        // HOME that could make the provider read the wrong account.
        var helperEnv = environment
        helperEnv.removeValue(forKey: "SUDO_ASKPASS")
        helperEnv["RC_RUN_AS_USER"] = runAsUser.shortName
        helperEnv["RC_RUN_AS_UID"] = "\(runAsUser.uid)"

        return LaunchPlan(
            executablePath: helper,
            arguments: helperArgs,
            environment: helperEnv,
            currentDirectory: currentDirectory,
            usesHelper: true
        )
    }

    /// Ensures the helper exists with root ownership and setuid-root mode.
    /// `install` is injectable so the idempotence contract can be tested
    /// without mutating `/Library` or asking for a real password.
    @discardableResult
    public static func ensureHelperInstalled(
        askpassPath: String? = nil,
        sourcePath: String? = nil,
        destinationPath: String = installedHelperPath,
        isInstalled: (String) -> Bool = { path in
            RunAsUserProcessBootstrap.isUsableInstalledHelper(at: path)
        },
        sourceIsUsable: (String) -> Bool = { path in
            FileManager.default.isExecutableFile(atPath: path)
        },
        install: (String, String, String?) -> Bool = { source, destination, askpass in
            RunAsUserProcessBootstrap.installHelper(
                sourcePath: source,
                destinationPath: destination,
                askpassPath: askpass
            )
        }
    ) throws -> String {
        installationLock.lock()
        defer { installationLock.unlock() }

        if isInstalled(destinationPath) { return destinationPath }
        guard let source = sourcePath ?? bundledHelperPath(), sourceIsUsable(source) else {
            throw RunAsUserProcessBootstrapError.helperUnavailable(
                "the packaged RemoteCodeRunAsUserHelper binary is missing"
            )
        }
        guard install(source, destinationPath, askpassPath), isInstalled(destinationPath) else {
            throw RunAsUserProcessBootstrapError.helperUnavailable(
                "one-time helper installation was cancelled or failed"
            )
        }
        return destinationPath
    }

    /// Builds the fixed signal invocation used to terminate a target-user
    /// provider subtree. The helper validates ownership of every PID before
    /// signalling it; no shell or arbitrary command crosses this boundary.
    public static func privilegedSignalArguments(
        uid: uid_t,
        signal: Int32,
        pids: [pid_t]
    ) -> [String]? {
        guard uid >= 501, signal == SIGTERM || signal == SIGKILL else { return nil }
        let targets = pids.filter { $0 > 0 }
        guard !targets.isEmpty else { return nil }
        var arguments = ["signal", "--uid", "\(uid)", "--signal", "\(signal)"]
        for pid in targets {
            arguments.append(contentsOf: ["--pid", "\(pid)"])
        }
        return arguments
    }

    /// Signals a target-user provider subtree through the already-installed
    /// helper. Teardown is deliberately fail-closed: it never installs the
    /// helper and therefore never opens a password prompt while the app exits.
    @discardableResult
    public static func runPrivilegedSignal(
        uid: uid_t,
        signal: Int32,
        pids: [pid_t]
    ) -> Bool {
        guard let arguments = privilegedSignalArguments(uid: uid, signal: signal, pids: pids),
              isUsableInstalledHelper(at: installedHelperPath) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: installedHelperPath)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs only the fixed privileged operation used by Insomnia. No shell or
    /// arbitrary command is accepted by this boundary.
    @discardableResult
    public static func runPrivilegedPMSet(
        disabled: Bool,
        watchProcessID: Int32?,
        stopFile: URL?,
        sessionDirectory: URL?
    ) -> Bool {
        let arguments: [String]
        do {
            arguments = try pmSetArguments(
                disabled: disabled,
                watchProcessID: watchProcessID,
                stopFile: stopFile,
                sessionDirectory: sessionDirectory
            )
        } catch {
            NSLog("RemoteCode Insomnia rejected privileged pmset request: %@", error.localizedDescription)
            return false
        }

        do {
            let helper = try ensureHelperInstalled()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("RemoteCode Insomnia could not use the privileged helper: %@", error.localizedDescription)
            return false
        }
    }

    /// Pure argv construction for the helper's narrow pmset command.
    public static func pmSetArguments(
        disabled: Bool,
        watchProcessID: Int32?,
        stopFile: URL?,
        sessionDirectory: URL?
    ) throws -> [String] {
        let watcherValuesPresent = watchProcessID != nil || stopFile != nil || sessionDirectory != nil
        if disabled {
            guard watcherValuesPresent,
                  let watchProcessID, watchProcessID > 0,
                  let stopFile, let sessionDirectory,
                  stopFile.path.hasPrefix("/"), sessionDirectory.path.hasPrefix("/") else {
                throw RunAsUserProcessBootstrapError.invalidPMSetRequest(
                    "enable requires a positive process id and absolute session paths"
                )
            }
            return [
                "pmset", "--disablesleep", "1",
                "--watch-pid", "\(watchProcessID)",
                "--stop-file", stopFile.path,
                "--session-directory", sessionDirectory.path
            ]
        }

        guard !watcherValuesPresent else {
            throw RunAsUserProcessBootstrapError.invalidPMSetRequest(
                "disable cannot include watcher arguments"
            )
        }
        return ["pmset", "--disablesleep", "0"]
    }

    /// The graphical askpass script is used only while installing the helper.
    /// It contains no password and is removed from the temporary directory
    /// after the installation attempt.
    public static func askpassScriptBody(targetUser: String) -> String {
        let safe = targetUser.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
        let who = safe.isEmpty ? "the selected macOS user" : safe
        return """
        #!/bin/sh
        /usr/bin/osascript \
          -e 'display dialog "MacCode needs your macOS password once to install its privileged helper for \(who). The password is not saved." with title "MacCode" default answer "" with hidden answer with icon caution' \
          -e 'text returned of result' 2>/dev/null
        """
    }

    public static func materializeAskpass(
        targetUser: String,
        directory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        let path = directory.appendingPathComponent("remotecode-sudo-askpass.sh")
        do {
            try askpassScriptBody(targetUser: targetUser).write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            return path.path
        } catch {
            return nil
        }
    }

    /// Builds a normal `sudo` installation request. It is the only sudo path
    /// and runs once per machine/helper version, not once per provider action.
    @usableFromInline
    internal static func installHelper(
        sourcePath: String,
        destinationPath: String,
        askpassPath: String?
    ) -> Bool {
        let temporaryAskpass: String?
        if let askpassPath, !askpassPath.isEmpty {
            temporaryAskpass = nil
        } else {
            temporaryAskpass = materializeInstallerAskpass()
        }
        let effectiveAskpass = askpassPath?.isEmpty == false ? askpassPath : temporaryAskpass
        guard let effectiveAskpass else { return false }
        defer {
            if let temporaryAskpass {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: temporaryAskpass))
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: temporaryAskpass).deletingLastPathComponent())
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sudoPath)
        process.arguments = [
            "-A", "--", "/usr/bin/install",
            "-o", "root", "-g", "wheel", "-m", "4755",
            sourcePath, destinationPath
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SUDO_ASKPASS": effectiveAskpass
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func materializeInstallerAskpass() -> String? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCodeAskpass-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        return materializeAskpass(targetUser: "this Mac", directory: directory)
    }

    private static func bundledHelperPath() -> String? {
        var candidates: [String] = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/RemoteCodeRunAsUserHelper").path
        ]
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent()
                .appendingPathComponent("RemoteCodeRunAsUserHelper").path)
        }
        if let argument = CommandLine.arguments.first, argument.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: argument).deletingLastPathComponent()
                .appendingPathComponent("RemoteCodeRunAsUserHelper").path)
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    @usableFromInline
    internal static func isUsableInstalledHelper(at path: String) -> Bool {
        isInstalledHelper(at: path) && helperVersionMatches(at: path)
    }

    @usableFromInline
    internal static func isInstalledHelper(at path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & mode_t(0o170000)) == mode_t(0o100000)
            && info.st_uid == 0
            && (info.st_mode & mode_t(0o7777)) == mode_t(0o4755)
    }

    @usableFromInline
    internal static func helperVersionMatches(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let version = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0
            && version == "RemoteCodeRunAsUserHelper \(helperVersion)"
    }

    /// Applies a launch plan onto a Foundation Process.
    public static func apply(_ plan: LaunchPlan, to process: Process) {
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.currentDirectory)
        process.environment = plan.environment
    }
}
