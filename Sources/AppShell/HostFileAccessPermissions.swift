import CoreModel
import Foundation
import AppKit
import Security
import Persistence

// HostVolumeMountTable + HostSafeDirectoryListing live in Persistence so
// SocketServer can list home without touching NFS mounts (OrbStack) and without
// a circular AppShell dependency.

// MARK: - Purpose strings (must match scripts/package-app.sh Info.plist)

/// Privacy purpose strings for macOS Files and Folders TCC services.
///
/// WHY: Apple shows these when RemoteCode touches Desktop, Documents, Downloads,
/// network volumes, or removable volumes. Missing keys still show a system
/// dialog, but shipping accurate copy is required for App Store / notarized
/// builds and makes the grant durable intent clear to the user.
public enum HostFileAccessPrivacyStrings {
    public static let networkVolumes =
        "MacCode needs access to project folders on network volumes so agents, terminals, and file tools can read and edit your code."
    public static let removableVolumes =
        "MacCode needs access to project folders on removable volumes so agents, terminals, and file tools can read and edit your code."
    public static let desktop =
        "MacCode needs access to folders on your Desktop when you open them as workspaces."
    public static let documents =
        "MacCode needs access to folders in Documents when you open them as workspaces."
    public static let downloads =
        "MacCode needs access to folders in Downloads when you open them as workspaces."

    /// Info.plist keys that package-app.sh must emit. Tests and check-app-bundle
    /// assert this set so a packaging regression cannot ship without purpose text.
    public static let infoPlistKeys: [String: String] = [
        "NSNetworkVolumesUsageDescription": networkVolumes,
        "NSRemovableVolumesUsageDescription": removableVolumes,
        "NSDesktopFolderUsageDescription": desktop,
        "NSDocumentsFolderUsageDescription": documents,
        "NSDownloadsFolderUsageDescription": downloads,
    ]
}

// MARK: - System Settings deep links

/// Deep links into System Settings privacy panes.
///
/// Apple does not expose a public API that grants Files and Folders or Full
/// Disk Access programmatically. The user must toggle them in System Settings.
/// These URLs open the correct pane on modern macOS (best-effort).
public enum HostFileAccessSystemSettings {
    /// Files and Folders (Desktop / Documents / Downloads / Network / Removable).
    public static let filesAndFoldersURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    /// Full Disk Access — broader grant used when workspaces span protected paths.
    public static let fullDiskAccessURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// macOS 13+ Settings app URLs (preferred when available).
    public static let filesAndFoldersSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders")!
    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
}

// MARK: - Code identity

/// Snapshot of the running code signature identity relevant to TCC durability.
///
/// WHY: Ad-hoc signatures (`codesign --sign -`) mint a new CDHash every package.
/// macOS TCC binds Files and Folders grants to code identity, so a rebuild that
/// re-ad-hoc-signs the app looks like a new app and re-prompts. Developer ID /
/// Apple Development identities keep the same designated requirement across builds.
public struct HostCodeSignatureIdentity: Equatable, Sendable {
    public let isAdHoc: Bool
    public let teamIdentifier: String?
    public let identifier: String?

    public init(isAdHoc: Bool, teamIdentifier: String?, identifier: String?) {
        self.isAdHoc = isAdHoc
        self.teamIdentifier = teamIdentifier
        self.identifier = identifier
    }

    /// User-facing note when identity is unstable for TCC.
    public var adHocWarning: String? {
        guard isAdHoc else { return nil }
        return """
        This build is ad-hoc signed. macOS may ask for folder permissions again after every rebuild. \
        Use a Developer ID or Apple Development signed build for durable Allow grants, or re-Allow once after packaging.
        """
    }
}

public enum HostCodeSignatureReader {
    /// Reads the current process signing identity. Pure enough for unit tests
    /// when injected; production uses SecCodeCopySelf + SecCodeCopyStaticCode.
    public static func current(
        copyInfo: () -> [String: Any]? = {
            var dynamicCode: SecCode?
            guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
                  let dynamicCode else { return nil }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
                  let staticCode else { return nil }
            var info: CFDictionary?
            let status = SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &info
            )
            guard status == errSecSuccess else { return nil }
            return info as? [String: Any]
        }
    ) -> HostCodeSignatureIdentity {
        guard let info = copyInfo() else {
            // Missing signature metadata → treat as ad-hoc (unstable for TCC).
            return HostCodeSignatureIdentity(isAdHoc: true, teamIdentifier: nil, identifier: nil)
        }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        // Ad-hoc signatures have no team identifier and flags include kSecCodeSignatureAdhoc.
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
            ?? info[kSecCodeInfoFlags as String] as? UInt32
            ?? 0
        let adhocFlag: UInt32 = 2 // kSecCodeSignatureAdhoc
        let isAdHoc = team == nil || (flags & adhocFlag) != 0
        return HostCodeSignatureIdentity(isAdHoc: isAdHoc, teamIdentifier: team, identifier: identifier)
    }
}

// MARK: - Probe targets

/// Folder-class TCC probes. Each target maps to a path macOS associates with a
/// Files and Folders service. Probing is intentional user-driven (Settings or
/// onboarding) — never silent on every launch.
public enum HostFileAccessProbeTarget: String, CaseIterable, Sendable {
    case desktop
    case documents
    case downloads
    case networkVolumes
    case removableVolumes

    public var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        case .networkVolumes: return "Network volumes"
        case .removableVolumes: return "Removable volumes"
        }
    }

    /// Resolve the probe URL for this target. Network/removable use /Volumes
    /// children; home-folder targets use the user home directory.
    public func resolveURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default
    ) -> URL? {
        switch self {
        case .desktop:
            return home.appendingPathComponent("Desktop", isDirectory: true)
        case .documents:
            return home.appendingPathComponent("Documents", isDirectory: true)
        case .downloads:
            return home.appendingPathComponent("Downloads", isDirectory: true)
        case .networkVolumes, .removableVolumes:
            // Prefer a real mounted child under /Volumes. Listing only /Volumes
            // does not exercise network/removable TCC; Apple prompts when the
            // app touches files on the mounted volume itself.
            return Self.firstMountedVolumeURL(volumesRoot: volumesRoot, fileManager: fileManager)
                ?? volumesRoot
        }
    }

    /// First non-root entry under /Volumes (external/network mounts). Nil when
    /// only the boot volume (or nothing) is present.
    ///
    /// Uses name-only enumeration + root-volume path compare so we do not
    /// prefetch resource keys that can trip Network Volumes TCC early.
    public static func firstMountedVolumeURL(
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default
    ) -> URL? {
        let rootPath = volumesRoot.path
        let names = (try? fileManager.contentsOfDirectory(atPath: rootPath)) ?? []
        let bootRoots: Set<String> = ["Macintosh HD", "Macintosh HD - Data"]
        for name in names {
            if name.hasPrefix(".") { continue }
            if bootRoots.contains(name) { continue }
            return volumesRoot.appendingPathComponent(name, isDirectory: true)
        }
        return nil
    }
}

public enum HostFileAccessProbeOutcome: String, Equatable, Sendable {
    case readable
    case denied
    case missing
    case skipped
}

public struct HostFileAccessProbeResult: Equatable, Sendable {
    public let target: HostFileAccessProbeTarget
    public let outcome: HostFileAccessProbeOutcome
    public let path: String?

    public init(target: HostFileAccessProbeTarget, outcome: HostFileAccessProbeOutcome, path: String?) {
        self.target = target
        self.outcome = outcome
        self.path = path
    }
}

/// Runs intentional TCC probes. Inject `contentsOfDirectory` for unit tests.
///
/// IMPORTANT: `fileExists` alone cannot distinguish missing paths from TCC
/// denial (Apple returns false both ways). Directory listing error codes are
/// used when available; otherwise outcome is best-effort.
public enum HostFileAccessProber {
    public static func probe(
        _ target: HostFileAccessProbeTarget,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default,
        contentsOfDirectory: (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        }
    ) -> HostFileAccessProbeResult {
        guard let url = target.resolveURL(home: home, volumesRoot: volumesRoot, fileManager: fileManager) else {
            return HostFileAccessProbeResult(target: target, outcome: .skipped, path: nil)
        }
        // Touch the path so TCC can show its dialog when needed.
        do {
            _ = try contentsOfDirectory(url)
            return HostFileAccessProbeResult(target: target, outcome: .readable, path: url.path)
        } catch let error as NSError {
            // ENOENT / missing home folders → missing. EPERM / NSFileRead* → denied.
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return HostFileAccessProbeResult(target: target, outcome: .missing, path: url.path)
            }
            if error.domain == NSPOSIXErrorDomain && error.code == ENOENT {
                return HostFileAccessProbeResult(target: target, outcome: .missing, path: url.path)
            }
            if error.domain == NSPOSIXErrorDomain && (error.code == EPERM || error.code == EACCES) {
                return HostFileAccessProbeResult(target: target, outcome: .denied, path: url.path)
            }
            if error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileReadNoPermissionError || error.code == NSFileReadUnknownError) {
                return HostFileAccessProbeResult(target: target, outcome: .denied, path: url.path)
            }
            // Unknown errors after a real access attempt still count as "attempted".
            return HostFileAccessProbeResult(target: target, outcome: .denied, path: url.path)
        }
    }

    /// Probes home protected folders. Optionally probes a real mounted volume
    /// child when one exists (network/removable TCC is mount-path based).
    ///
    /// `includeVolumes` defaults to **false**: probing a network volume forces
    /// the system Allow dialog and is only appropriate when the user explicitly
    /// asks (Settings opt-in). Desktop/Documents/Downloads cover normal workspaces.
    public static func probeStandardTargets(
        includeVolumes: Bool = false,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default,
        contentsOfDirectory: (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        }
    ) -> [HostFileAccessProbeResult] {
        var targets: [HostFileAccessProbeTarget] = [.desktop, .documents, .downloads]
        if includeVolumes {
            // Skip volume probe when nothing is mounted — avoids a useless
            // /Volumes root touch that never triggers network-volume TCC.
            if HostFileAccessProbeTarget.firstMountedVolumeURL(
                volumesRoot: volumesRoot,
                fileManager: fileManager
            ) != nil {
                targets.append(.networkVolumes)
            }
        }
        return targets.map {
            probe(
                $0,
                home: home,
                volumesRoot: volumesRoot,
                fileManager: fileManager,
                contentsOfDirectory: contentsOfDirectory
            )
        }
    }
}

// MARK: - Onboarding persistence

/// One-time host file-access onboarding *handled* state.
///
/// "Handled" means the user saw the explanation and chose Open Full Disk
/// Access / Not Now — **not** that macOS granted Full Disk Access or every
/// folder permission. Opening System Settings never proves a grant.
public enum HostFileAccessOnboarding {
    public static let settingsKey = "host_file_access_onboarding_handled"

    /// Legacy key from the first implementation; still treated as handled so
    /// users who already dismissed the sheet are not nagged again.
    public static let legacySettingsKey = "host_file_access_onboarding_completed"

    public static func isHandled(repo: SettingsRepository) -> Bool {
        let current = (try? repo.get(settingsKey)) == "1"
        let legacy = (try? repo.get(legacySettingsKey)) == "1"
        return current || legacy
    }

    /// Backward-compatible alias used by existing call sites/tests.
    public static func isCompleted(repo: SettingsRepository) -> Bool {
        isHandled(repo: repo)
    }

    public static func markHandled(repo: SettingsRepository) throws {
        try repo.set(settingsKey, "1")
    }

    /// Backward-compatible alias.
    public static func markCompleted(repo: SettingsRepository) throws {
        try markHandled(repo: repo)
    }

    /// Pure decision: show the onboarding sheet when not yet handled.
    public static func shouldPresent(handled: Bool) -> Bool {
        !handled
    }

    /// Backward-compatible alias.
    public static func shouldPresent(completed: Bool) -> Bool {
        shouldPresent(handled: completed)
    }

    /// Resolves the durable write for either onboarding button.
    /// Both must mark handled to avoid a launch nag loop. Does **not** probe
    /// protected folders — launch must never force multi-folder TCC dialogs.
    public static func handleAlertResponse(
        _ response: NSApplication.ModalResponse,
        markHandled: () throws -> Void,
        openFullDiskAccess: () -> Void
    ) rethrows {
        // Persist first so a crash mid-side-effect does not re-nag forever.
        try markHandled()
        switch response {
        case .alertFirstButtonReturn:
            openFullDiskAccess()
        default:
            break // Not Now — handled only.
        }
    }
}

// MARK: - User-facing copy

public enum HostFileAccessCopy {
    public static let onboardingTitle = "Fewer folder permission prompts"
    public static let onboardingMessage = """
    MacCode needs project folders for agents, terminals, and file tools.

    macOS normally asks separately for Desktop, Documents, Downloads, and other protected locations. \
    Enabling Full Disk Access once in System Settings avoids most of those repeated prompts.

    This is not a root grant: camera, microphone, and screen recording stay separate and are only \
    requested if you use those features.

    Open Full Disk Access to review the toggle. Not Now dismisses this tip — we will not ask again at launch.
    """
    public static let settingsSectionTitle = "Disk access"
    public static let settingsExplanation = """
    For the fewest prompts, enable Full Disk Access for MacCode in System Settings. \
    That covers most project folders without asking Desktop, Documents, and Downloads one by one.

    “Check folder access” is optional: it touches common folders once and may show system dialogs for any still-pending grants. \
    If you previously chose Don’t Allow, macOS will not re-prompt — open System Settings to change the grant.
    """
    public static let requestAccessButton = "Check folder access"
    public static let openFilesAndFoldersButton = "Open Files & Folders settings"
    public static let openFullDiskAccessButton = "Open Full Disk Access"
    public static let notNowButton = "Not Now"
}
