import Foundation

/// The mac-use releases MacCode keeps installed (`ManagedToolInstaller`).
///
/// MacCode's own computer-use server is a copy of mac-use frozen when it was taken. Whenever an
/// installed release can do the job, that release is what runs, so a fix shipped in mac-use
/// reaches MacCode's agents without waiting for a MacCode release.
public enum ManagedMacUse {
    public static let binaryName = "mac-use-mcp"
    /// Native messaging host of the mac-use Chrome extension.
    public static let chromeHostName = "io.macuse.computer_use"

    public static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/share/mac-use", isDirectory: true)
    }

    /// The newest installed release. Versions compare as numbers: 1.10.0 is newer than 1.9.3.
    public static func newestBinary(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let root = root(home: home)
        let versions = ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).filter { name in
            name.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil
                && fileManager.isExecutableFile(atPath: root.appendingPathComponent(name).appendingPathComponent(binaryName).path)
        }
        guard let newest = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else { return nil }
        return root.appendingPathComponent(newest).appendingPathComponent(binaryName)
    }

    static func chromeHostRegistered(_ name: String, home: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(
            atPath: home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(name).json").path
        )
    }

    /// The release to run in place of the built-in server, or nil to keep the built-in one.
    ///
    /// The two servers reach Chrome through different extensions. On a Mac where only MacCode's
    /// extension was set up, the built-in server stays, so its browser tools keep working.
    public static func serverBinary(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let binary = newestBinary(home: home, fileManager: fileManager) else { return nil }
        let macUseExtension = chromeHostRegistered(chromeHostName, home: home, fileManager: fileManager)
        let ownExtension = chromeHostRegistered(ChromeProfileConnection.hostName, home: home, fileManager: fileManager)
        return macUseExtension || !ownExtension ? binary : nil
    }
}
