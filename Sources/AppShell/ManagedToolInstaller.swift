import CryptoKit
import Foundation
import os
import AgentRuntime
import CoreModel

private let managedToolLog = Logger(subsystem: "io.remotecode.agent", category: "managed.tools")

/// Launch and onboarding can request the same first-run download together.
private actor ManagedToolInstalls {
    static let shared = ManagedToolInstalls()
    private var running: [String: Task<Void, Error>] = [:]

    func perform(_ key: String, operation: @escaping @Sendable () async throws -> Void) async throws {
        if let task = running[key] { return try await task.value }
        let task = Task { try await operation() }
        running[key] = task
        defer { running[key] = nil }
        try await task.value
    }
}

func sleepSeconds(_ seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Connection-level failures worth one more try; permanent errors are not in this set.
func isTransientNetworkError(_ error: Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet: return true
    default: return false
    }
}

func isRetryableHTTPStatus(_ code: Int) -> Bool {
    code == 429 || (500...599).contains(code)
}

/// Runs `operation` again after each `delays` entry while `retryError` or `retryResult` says the
/// outcome is transient. The last outcome is returned or thrown unchanged once retries run out.
func retryingTransientFailures<T>(
    delays: [TimeInterval],
    sleep: (TimeInterval) async throws -> Void = sleepSeconds,
    retryError: (Error) -> Bool = isTransientNetworkError,
    retryResult: (T) -> Bool = { _ in false },
    operation: () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            let result = try await operation()
            if attempt == delays.count || !retryResult(result) { return result }
        } catch where attempt < delays.count && retryError(error) {
        }
        try await sleep(delays[attempt])
        attempt += 1
    }
}

/// Installs the latest GitHub release of mac-use (on the Mac, registered in
/// Distill) and linux-use (into the bot VMs' read-only agent kit) once per
/// launch, in the background. Every asset is checked against the release's
/// SHA256SUMS before anything is replaced; a failure keeps what is installed.
enum ManagedToolInstaller {
    struct Release: Equatable {
        let tag: String
        let assets: [String: URL]
    }

    static func runAll(appSupport: URL, distillBinary: String?, distillEnvironment: [String: String]) async {
        do {
            try await installMacUse(distillBinary: distillBinary, environment: distillEnvironment)
        } catch {
            managedToolLog.error("managed.tools.mac_use_failed error=\(String(describing: error), privacy: .public)")
        }
        do {
            try await installLinuxUse(appSupport: appSupport)
        } catch {
            managedToolLog.error("managed.tools.linux_use_failed error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: mac-use

    static func macUseRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/share/mac-use", isDirectory: true)
    }

    static func installMacUse(distillBinary: String?, environment: [String: String]) async throws {
        guard let distillBinary else { throw Failure(L("Install Distill before registering computer automation.")) }
        let home = DistillProvisioner.homeURL(environment: environment)
        try await ManagedToolInstalls.shared.perform("mac-use:\(home.path)") {
            try await installMacUseRelease(distillBinary: distillBinary, environment: environment)
        }
    }

    private static func installMacUseRelease(distillBinary: String?, environment: [String: String]) async throws {
        let release = try await latestRelease(repo: "samuelfaj/mac-use")
        let version = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        let root = macUseRoot()
        let binary = root.appendingPathComponent("\(version)/mac-use-mcp")
        if !FileManager.default.isExecutableFile(atPath: binary.path) {
            let extracted = try await downloadVerifiedTarball(
                release, asset: "mac-use-mcp-v\(version)-macos-arm64.tar.gz"
            )
            defer { try? FileManager.default.removeItem(at: extracted) }
            let directory = binary.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: binary)
            try FileManager.default.moveItem(at: extracted.appendingPathComponent("mac-use-mcp"), to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        if let skill = try? await downloadVerifiedTarball(release, asset: "mac-use-skill-v\(version).tar.gz") {
            defer { try? FileManager.default.removeItem(at: skill) }
            let home = DistillProvisioner.homeURL(environment: environment)
            try? replace(skill.appendingPathComponent("mac-use"), with: home.appendingPathComponent("skills/mac-use"))
        }
        if let distillBinary {
            let status = try run(distillBinary, ["mcp", "add", "mac-use", "--", binary.path], environment: environment)
            guard status == 0 else { throw Failure(L("distill mcp add mac-use exited %1$@", status)) }
        }
        managedToolLog.info("managed.tools.mac_use_ready version=\(version, privacy: .public)")
    }

    // MARK: linux-use

    static func linuxUseDirectory(appSupport: URL) -> URL {
        BotComputerGuestSpec.guestToolsURL(appSupport: appSupport).appendingPathComponent("linux-use", isDirectory: true)
    }

    /// Marker of a downloaded release: while it exists the bundled copy is not restored.
    static let linuxUseVersionFile = "VERSION"

    static func installLinuxUse(appSupport: URL) async throws {
        try await ManagedToolInstalls.shared.perform("linux-use:\(appSupport.path)") {
            try await installLinuxUseRelease(appSupport: appSupport)
        }
    }

    private static func installLinuxUseRelease(appSupport: URL) async throws {
        let release = try await latestRelease(repo: "samuelfaj/linux-use")
        let target = linuxUseDirectory(appSupport: appSupport)
        let marker = target.appendingPathComponent(linuxUseVersionFile)
        let installed = FileManager.default.fileExists(atPath: marker.path)
            ? try? String(contentsOf: marker, encoding: .utf8) : nil
        if installed?.trimmingCharacters(in: .whitespacesAndNewlines) == release.tag { return }
        let version = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        let extracted = try await downloadVerifiedTarball(release, asset: "linux-use-server-v\(version).tar.gz")
        defer { try? FileManager.default.removeItem(at: extracted) }
        guard FileManager.default.fileExists(atPath: extracted.appendingPathComponent("server.py").path) else {
            throw Failure(L("linux-use release has no server.py"))
        }
        try Data("\(release.tag)\n".utf8).write(to: extracted.appendingPathComponent(linuxUseVersionFile))
        try replace(extracted, with: target)
        managedToolLog.info("managed.tools.linux_use_ready version=\(release.tag, privacy: .public)")
    }

    // MARK: GitHub

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func latestRelease(repo: String) async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await retryingTransientFailures(
            delays: [2, 5],
            retryResult: { (result: (Data, URLResponse)) in
                (result.1 as? HTTPURLResponse).map { isRetryableHTTPStatus($0.statusCode) } ?? false
            }
        ) { try await URLSession.shared.data(for: request) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(L("%1$@ releases/latest failed", repo)) }
        return try parseRelease(data)
    }

    static func parseRelease(_ data: Data) throws -> Release {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              tag.range(of: #"^v?[0-9A-Za-z.+-]+$"#, options: .regularExpression) != nil
        else { throw Failure(L("release JSON has no valid tag_name")) }
        var assets: [String: URL] = [:]
        for asset in object["assets"] as? [[String: Any]] ?? [] {
            if let name = asset["name"] as? String, let link = asset["browser_download_url"] as? String,
               let url = URL(string: link), url.scheme == "https" {
                assets[name] = url
            }
        }
        return Release(tag: tag, assets: assets)
    }

    /// The expected digest for `asset` in a SHA256SUMS file.
    static func expectedDigest(sums: String, asset: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == asset {
                return parts[0].lowercased()
            }
        }
        return nil
    }

    /// Downloads `asset` and SHA256SUMS, verifies, and extracts into a temporary directory.
    static func downloadVerifiedTarball(_ release: Release, asset: String) async throws -> URL {
        guard let assetURL = release.assets[asset], let sumsURL = release.assets["SHA256SUMS"] else {
            throw Failure(L("release %1$@ lacks %2$@ or SHA256SUMS", release.tag, asset))
        }
        let (sumsData, _) = try await retryingTransientFailures(
            delays: [2, 5],
            retryResult: { (result: (Data, URLResponse)) in
                (result.1 as? HTTPURLResponse).map { isRetryableHTTPStatus($0.statusCode) } ?? false
            }
        ) { try await URLSession.shared.data(from: sumsURL) }
        guard let expected = expectedDigest(sums: String(decoding: sumsData, as: UTF8.self), asset: asset) else {
            throw Failure(L("SHA256SUMS has no entry for %1$@", asset))
        }
        let (file, _) = try await retryingTransientFailures(
            delays: [2, 5],
            retryResult: { (result: (URL, URLResponse)) in
                (result.1 as? HTTPURLResponse).map { isRetryableHTTPStatus($0.statusCode) } ?? false
            }
        ) { try await URLSession.shared.download(from: assetURL) }
        defer { try? FileManager.default.removeItem(at: file) }
        let actual = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure(L("checksum mismatch for %1$@", asset)) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rc-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let status = try run("/usr/bin/tar", ["-xzf", file.path, "-C", directory.path], environment: [:])
        guard status == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw Failure(L("tar exited %1$@ for %2$@", status, asset))
        }
        return directory
    }

    /// Swaps `source` into `target` (directory), keeping the old one until the move succeeds.
    static func replace(_ source: URL, with target: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staged)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: target)
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

extension AppContext {
    /// Once per launch, in the background: installs Distill if missing, then
    /// the latest mac-use and linux-use. Same gate as the Distill updater, so
    /// the isolated sandbox, the scheduled-task agent and unit tests skip it.
    @discardableResult
    func startManagedToolInstalls(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard Self.shouldReconcileManagedDistillIntegration(
            isRunningUnitTests: Self.isRunningUnitTests,
            hasSkillsHomeOverride: agentSkillsHomeOverrideForTesting != nil,
            environment: environment
        ) else { return false }
        let appSupport = appSupportDirectory
        let configured = (try? settingsRepo.get("cli.distill.path")) ?? nil
        Task.detached(priority: .utility) {
            let binary: String?
            do { binary = try DistillProvisioner.ensureInstalled(override: configured).binaryPath }
            catch {
                managedToolLog.error("managed.tools.distill_install_failed error=\(String(describing: error), privacy: .public)")
                binary = nil
            }
            await ManagedToolInstaller.runAll(appSupport: appSupport, distillBinary: binary, distillEnvironment: environment)
        }
        return true
    }
}
