import Foundation
import CoreModel

/// Copies the in-guest agent kit (Resources/GuestAgentKit) into
/// `<AppSupport>/guest-tools`, which every bot container binds read-only at
/// `BotComputerGuestSpec.agentKitMountPoint`. The guest cannot change it.
enum BotGuestAgentKit {
    /// Every kit file with its mode; the read-only bind keeps the host mode,
    /// so the scripts must be executable here.
    static let files: [(path: String, mode: Int)] = [
        ("bin/run-agent", 0o755),
        ("bin/kill-agent", 0o755),
        ("linux-use/server.py", 0o644),
        ("linux-use/UPSTREAM", 0o644),
    ]

    enum Failure: Error, Equatable, CustomStringConvertible {
        case missingKit

        var description: String {
            L("The MacCode app is missing its Linux agent kit (GuestAgentKit). Reinstall MacCode.")
        }
    }

    /// Idempotent. A file whose bytes and mode already match is left alone; a
    /// changed one is replaced by rename, so a run already reading the old
    /// script keeps reading it. Other guest-tools content (the guest distill
    /// cache) is not touched.
    static func materialize(
        appSupport: URL,
        source: URL? = AppShellResourceBundle.guestAgentKitURL()
    ) throws {
        guard let source else { throw Failure.missingKit }
        let fileManager = FileManager.default
        let root = BotComputerGuestSpec.guestToolsURL(appSupport: appSupport)
        // A linux-use release downloaded from GitHub replaces the bundled copy.
        let downloadedLinuxUse = fileManager.fileExists(atPath: ManagedToolInstaller.linuxUseDirectory(appSupport: appSupport)
            .appendingPathComponent(ManagedToolInstaller.linuxUseVersionFile).path)
        for file in files {
            if downloadedLinuxUse, file.path.hasPrefix("linux-use/") { continue }
            let data = try Data(contentsOf: source.appendingPathComponent(file.path))
            let target = root.appendingPathComponent(file.path)
            let currentMode = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
            if currentMode == file.mode, (try? Data(contentsOf: target)) == data { continue }
            let directory = target.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)")
            do {
                try data.write(to: temporary)
                try fileManager.setAttributes([.posixPermissions: file.mode], ofItemAtPath: temporary.path)
                guard rename(temporary.path, target.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        }
    }
}
