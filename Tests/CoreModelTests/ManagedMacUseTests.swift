import XCTest
@testable import CoreModel

final class ManagedMacUseTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("managed-mac-use-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func install(_ version: String, executable: Bool = true) throws {
        let directory = ManagedMacUse.root(home: home).appendingPathComponent(version)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent(ManagedMacUse.binaryName)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: binary.path)
    }

    private func registerChromeHost(_ name: String) throws {
        let directory = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("\(name).json"))
    }

    func test_newestReleaseWinsByNumberNotByText() throws {
        // WHY: agents must run the latest mac-use. Sorted as text, 1.9.3 beats 1.10.0 and the
        // fix shipped in 1.10.0 would never run.
        XCTAssertNil(ManagedMacUse.newestBinary(home: home))
        try install("1.9.3")
        try install("1.10.0")
        try install("1.5.3")
        XCTAssertEqual(ManagedMacUse.newestBinary(home: home)?.path,
                       ManagedMacUse.root(home: home).appendingPathComponent("1.10.0/mac-use-mcp").path)
    }

    func test_onlyRunnableReleasesCount() throws {
        // WHY: the folder also holds backups and half-finished downloads; handing the agent's
        // server to something that cannot start would leave it with no computer-use tools.
        try install("1.6.1")
        try install("2.0.0", executable: false)
        try FileManager.default.createDirectory(
            at: ManagedMacUse.root(home: home).appendingPathComponent("backups/pre-fix"), withIntermediateDirectories: true)
        try install("9.9.9-broken")
        XCTAssertEqual(ManagedMacUse.newestBinary(home: home)?.deletingLastPathComponent().lastPathComponent, "1.6.1")
    }

    func test_installedReleaseReplacesTheBuiltInServerUnlessOnlyMacCodesExtensionIsSetUp() throws {
        // WHY: MacCode must always use the up-to-date mac-use, but the two servers reach Chrome
        // through different extensions. Someone who set up only MacCode's extension would lose
        // their browser tools if the server changed under them.
        XCTAssertNil(ManagedMacUse.serverBinary(home: home), "nothing installed: the built-in server stays")
        try install("1.6.1")
        XCTAssertNotNil(ManagedMacUse.serverBinary(home: home), "no Chrome setup at all: nothing to lose")
        try registerChromeHost(ChromeProfileConnection.hostName)
        XCTAssertNil(ManagedMacUse.serverBinary(home: home), "only MacCode's extension: keep the server that talks to it")
        try registerChromeHost(ManagedMacUse.chromeHostName)
        XCTAssertEqual(ManagedMacUse.serverBinary(home: home)?.lastPathComponent, ManagedMacUse.binaryName,
                       "mac-use's extension is set up: the release is complete on its own")
    }
}
