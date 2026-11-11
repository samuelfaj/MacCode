import AppKit
import Foundation
import AgentRuntime
import CoreModel

enum OnboardingTool: String, CaseIterable, Sendable {
    case distill, git, node, automation, chrome, docker, helper

    var title: String {
        switch self {
        case .distill: return "Distill"
        case .git: return L("Git & Command Line Tools")
        case .node: return "Node.js & npm"
        case .automation: return L("Computer automation")
        case .chrome: return "Google Chrome"
        case .docker: return "Docker Desktop"
        case .helper: return L("MacCode helper")
        }
    }

    var detail: String {
        switch self {
        case .distill: return L("Runs your AI accounts. No Homebrew or developer tools needed.")
        case .git: return L("Project history, checkpoints, worktrees and coding tools. Apple confirms the installation.")
        case .node: return L("Browser automation and the optional Claude SDK. Installs Node 24 LTS in your home folder.")
        case .automation: return L("Installs mac-use and linux-use, and connects mac-use to Distill.")
        case .chrome: return L("Optional · Use browser sessions and existing logins. Connect the extension below after installation.")
        case .docker: return L("Optional · Linux computers for Bots. Open Docker to accept its terms and finish setup. Existing OrbStack also works.")
        case .helper: return L("Optional · Run as another Mac user, scheduled tasks and Insomnia. macOS asks for your password once.")
        }
    }
}

enum OnboardingToolState: Equatable, Sendable {
    case checking, missing, installing, ready(String), needsAction(String), failed(String)
    var isReady: Bool { if case .ready = self { return true }; return false }
    var isBusy: Bool { self == .checking || self == .installing }
    var message: String {
        switch self {
        case .checking: return L("Checking…")
        case .missing: return L("Not installed")
        case .installing: return L("Installing…")
        case .ready(let message), .needsAction(let message), .failed(let message): return message
        }
    }
}

/// The setup window reports the existing installers' results. It never stores
/// an OS grant or a successful installation based on a button press alone.
@MainActor
final class OnboardingSetupController: ObservableObject {
    @Published private(set) var states: [OnboardingTool: OnboardingToolState] = [:]
    private let check: @Sendable (OnboardingTool) async throws -> OnboardingToolState
    private let installAction: @Sendable (OnboardingTool) async throws -> Void
    private var running: Set<OnboardingTool> = []

    init(check: @escaping @Sendable (OnboardingTool) async throws -> OnboardingToolState,
         install: @escaping @Sendable (OnboardingTool) async throws -> Void) {
        self.check = check
        self.installAction = install
    }

    convenience init(appSupport: URL, distillOverride: String?) {
        self.init(check: { tool in
            try await Task.detached(priority: .utility) {
                try OnboardingToolInstaller.check(tool, appSupport: appSupport, distillOverride: distillOverride)
            }.value
        }, install: { tool in
            try await OnboardingToolInstaller.install(tool, appSupport: appSupport, distillOverride: distillOverride)
        })
    }

    func state(_ tool: OnboardingTool) -> OnboardingToolState { states[tool] ?? .checking }
    var requiredToolsReady: Bool { [OnboardingTool.git, .node, .automation].allSatisfy { state($0).isReady } }

    func refresh(_ tool: OnboardingTool) async {
        guard running.insert(tool).inserted else { return }
        defer { running.remove(tool) }
        do { states[tool] = try await check(tool) }
        catch { states[tool] = .failed(String(describing: error)) }
    }

    func install(_ tool: OnboardingTool) async {
        guard running.insert(tool).inserted else { return }
        states[tool] = .installing
        defer { running.remove(tool) }
        do {
            try await installAction(tool)
            let result = try await check(tool)
            states[tool] = tool == .git && result == .missing
                ? .needsAction(L("Finish Apple's installation, then check again.")) : result
        } catch { states[tool] = .failed(String(describing: error)) }
    }

    func prepareDistill() async {
        await refresh(.distill)
        if state(.distill) == .missing { await install(.distill) }
    }

    func prepareTools() async {
        let required: [OnboardingTool] = [.git, .node, .automation]
        for tool in required {
            await refresh(tool)
            if state(tool) == .missing { await install(tool) }
        }
        for tool in [OnboardingTool.chrome, .docker, .helper] { await refresh(tool) }
    }
}

enum OnboardingToolInstaller {
    private static let fm = FileManager.default
    static let chromeDownloadURL = URL(string: "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg")!
    static var dockerDownloadURL: URL {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return URL(string: "https://desktop.docker.com/mac/main/\(arch)/Docker.dmg")!
    }

    static func check(_ tool: OnboardingTool, appSupport: URL, distillOverride: String?) throws -> OnboardingToolState {
        switch tool {
        case .distill:
            guard let binary = DistillProvisioner.resolveInstalledBinary(override: distillOverride) else { return .missing }
            guard let version = ProviderCLIProbe.version(binaryPath: binary, timeoutSeconds: 10) else {
                return .failed(L("Distill is present but cannot run. Retry installation, or review its path in Settings."))
            }
            return .ready(version)
        case .git:
            guard let binary = ProcessLocator.resolve("git") else { return .missing }
            if binary == "/usr/bin/git", try ManagedToolInstaller.run("/usr/bin/xcode-select", ["-p"], environment: [:]) != 0 {
                return .missing
            }
            guard let version = ProviderCLIProbe.version(binaryPath: binary, timeoutSeconds: 10) else {
                return .needsAction(L("Finish Apple's developer tools installation or accept the Xcode license, then check again."))
            }
            return .ready(version)
        case .node:
            guard let binary = ProcessLocator.resolve("node"),
                  let version = ProviderCLIProbe.version(binaryPath: binary),
                  nodeMajor(version).map({ $0 >= 20 }) == true,
                  (try? BotBrowserPlaywrightHost.resolveNPXExecutable()) != nil else { return .missing }
            return .ready(version)
        case .automation:
            let marker = appSupport.appendingPathComponent("onboarding-automation-ready")
            let root = ManagedToolInstaller.macUseRoot()
            let versions = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let macUse = versions.contains { fm.isExecutableFile(atPath: $0.appendingPathComponent("mac-use-mcp").path) }
            return fm.fileExists(atPath: marker.path) && macUse
                && fm.fileExists(atPath: ManagedToolInstaller.linuxUseDirectory(appSupport: appSupport).appendingPathComponent("server.py").path)
                ? .ready(L("mac-use & linux-use installed")) : .missing
        case .chrome:
            return ManagedChromeHostBrowserBridge.installedChromeExecutable() == nil ? .missing : .ready(L("Installed"))
        case .docker:
            do { _ = try BotComputerDockerResolver().resolveHealthyExecutable(); return .ready(L("Docker is running")) }
            catch let error as BotComputerDockerError {
                return error == .cliMissing && installedApp("Docker.app") == nil && installedApp("OrbStack.app") == nil
                    ? .missing : .needsAction(error.description)
            }
        case .helper:
            return RunAsUserProcessBootstrap.isHelperReady ? .ready(L("Installed and verified")) : .missing
        }
    }

    static func install(_ tool: OnboardingTool, appSupport: URL, distillOverride: String?) async throws {
        switch tool {
        case .distill:
            _ = try await Task.detached(priority: .utility) {
                try DistillProvisioner.ensureInstalled(override: distillOverride)
            }.value
        case .git:
            _ = try await Task.detached {
                try ManagedToolInstaller.run("/usr/bin/xcode-select", ["--install"], environment: [:])
            }.value
            // xcode-select starts Apple's installer; its exit is not proof
            // that Git has finished installing. check() verifies it later.
        case .node: try await installNode()
        case .automation:
            guard let binary = DistillProvisioner.resolveInstalledBinary(override: distillOverride) else {
                throw ManagedToolInstaller.Failure(L("Install Distill first, then retry computer automation."))
            }
            try await ManagedToolInstaller.installMacUse(distillBinary: binary, environment: ProcessInfo.processInfo.environment)
            try await ManagedToolInstaller.installLinuxUse(appSupport: appSupport)
            try Data().write(to: appSupport.appendingPathComponent("onboarding-automation-ready"))
        case .chrome:
            _ = try await installApp(name: "Google Chrome.app", bundleID: "com.google.Chrome",
                url: chromeDownloadURL)
        case .docker:
            let existing = installedApp("OrbStack.app") ?? installedApp("Docker.app")
            let app: URL
            if let existing { app = existing }
            else {
                app = try await installApp(name: "Docker.app", bundleID: "com.docker.docker",
                    url: dockerDownloadURL)
            }
            await MainActor.run { _ = NSWorkspace.shared.open(app) }
        case .helper:
            _ = try await Task.detached { try RunAsUserProcessBootstrap.ensureHelperInstalled() }.value
        }
    }

    static func nodeMajor(_ version: String) -> Int? {
        Int(version.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "v" }).split(separator: ".").first ?? "")
    }

    static func nodeAsset(sums: String, arch: String) -> String? {
        sums.split(separator: "\n").compactMap { $0.split(whereSeparator: \.isWhitespace).last.map(String.init) }
            .first { $0.range(of: "^node-v24\\.[0-9]+\\.[0-9]+-darwin-\(arch)\\.tar\\.gz$", options: .regularExpression) != nil }
    }

    private static func installNode() async throws {
        let base = URL(string: "https://nodejs.org/dist/latest-v24.x/")!
        let sumsURL = base.appendingPathComponent("SHASUMS256.txt")
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: sumsURL, timeoutInterval: 60))
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let asset = nodeAsset(sums: String(decoding: data, as: UTF8.self), arch: arch) else {
            throw ManagedToolInstaller.Failure(L("Could not read the official Node.js LTS release. Check your connection and retry."))
        }
        let version = String(asset.split(separator: "-")[1])
        let releaseBase = URL(string: "https://nodejs.org/dist/\(version)/")!
        let release = ManagedToolInstaller.Release(tag: version, assets: [
            asset: releaseBase.appendingPathComponent(asset), "SHA256SUMS": releaseBase.appendingPathComponent("SHASUMS256.txt")
        ])
        let extracted = try await ManagedToolInstaller.downloadVerifiedTarball(release, asset: asset)
        defer { try? fm.removeItem(at: extracted) }
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".local/share/maccode-node")
        try ManagedToolInstaller.replace(extracted.appendingPathComponent(String(asset.dropLast(7))), with: root)
    }

    private static func installedApp(_ name: String) -> URL? {
        [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            .map { $0.appendingPathComponent(name) }.first { fm.fileExists(atPath: $0.path) }
    }

    /// Uses the vendor's signed app, with no Homebrew or admin shell. Never
    /// replaces an existing app. The native first-launch prompts stay intact.
    static func installApp(name: String, bundleID: String, url: URL, applicationsDirectory: URL? = nil) async throws -> URL {
        if let applicationsDirectory {
            let existing = applicationsDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: existing.path) { return existing }
        } else if let existing = installedApp(name) { return existing }
        let (file, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 600))
        defer { try? fm.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ManagedToolInstaller.Failure(L("Download failed for %1$@. Check your connection and retry.", name)) }
        return try await Task.detached(priority: .utility) {
            let mount = fm.temporaryDirectory.appendingPathComponent("maccode-setup-\(UUID().uuidString)")
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            guard try ManagedToolInstaller.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, file.path], environment: [:]) == 0 else {
                try? fm.removeItem(at: mount)
                throw ManagedToolInstaller.Failure(L("Could not open the %1$@ installer.", name))
            }
            defer {
                if (try? ManagedToolInstaller.run("/usr/bin/hdiutil", ["detach", mount.path], environment: [:])) == 0 {
                    try? fm.removeItem(at: mount)
                }
            }
            let source = mount.appendingPathComponent(name)
            guard Bundle(url: source)?.bundleIdentifier == bundleID else {
                throw ManagedToolInstaller.Failure(L("The %1$@ download does not contain the expected app. Nothing was installed.", name))
            }
            // Gatekeeper validates the vendor signature and notarization.
            // Chrome's official DMG includes FinderInfo metadata that makes
            // codesign --strict reject an app Gatekeeper correctly accepts.
            guard try ManagedToolInstaller.run("/usr/sbin/spctl", ["--assess", "--type", "execute", source.path], environment: [:]) == 0 else {
                throw ManagedToolInstaller.Failure(L("Gatekeeper could not approve %1$@. Check your connection and try again.", name))
            }
            let applications = applicationsDirectory ?? (fm.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications")
                : fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
            try fm.createDirectory(at: applications, withIntermediateDirectories: true)
            let target = applications.appendingPathComponent(name)
            let staged = applications.appendingPathComponent(".maccode-setup-\(UUID().uuidString).app")
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: source, to: staged)
            try fm.moveItem(at: staged, to: target)
            return target
        }.value
    }
}
