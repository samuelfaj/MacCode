import Foundation
import XCTest
import CoreModel
@testable import AgentRuntime

final class DistillProcessResolutionTests: ProviderProcessTestCase {
    func test_distillResolverRejectsShimsButKeepsGenericManagedResolution() throws {
        // WHY: provider launches must use the Distill agent, while generic
        // executable resolution must stay unchanged for a managed `distill`.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-resolution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let managed = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        let local = home.appendingPathComponent(".local/bin", isDirectory: true)
        let providerBin = root.appendingPathComponent("provider-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerBin, withIntermediateDirectories: true)

        let compressor = managed.appendingPathComponent("distill")
        let bridge = local.appendingPathComponent("distill")
        let agent = providerBin.appendingPathComponent("distill")
        try "#!/bin/sh\nexit 0\n".write(to: compressor, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compressor.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
        try FileManager.default.createSymbolicLink(at: bridge, withDestinationURL: compressor)

        XCTAssertEqual(
            ProcessLocator.resolveDistillAgent(
                "distill",
                environmentPath: "\(local.path):\(providerBin.path)",
                homeDirectory: home.path,
                managedHomes: [home.path]
            ),
            agent.path
        )
        XCTAssertNil(
            ProcessLocator.resolveDistillAgent(
                compressor.path,
                environmentPath: nil,
                homeDirectory: home.path,
                managedHomes: [home.path]
            )
        )
        XCTAssertNil(
            ProcessLocator.resolveDistillAgent(
                bridge.path,
                environmentPath: nil,
                homeDirectory: home.path,
                managedHomes: [home.path]
            )
        )
        let renamedShim = root.appendingPathComponent("distill-agent")
        try FileManager.default.createSymbolicLink(at: renamedShim, withDestinationURL: compressor)
        XCTAssertNil(
            ProcessLocator.resolveDistillAgent(
                renamedShim.path,
                environmentPath: nil,
                homeDirectory: home.path,
                managedHomes: [home.path]
            ),
            "A renamed symlink must not bypass canonical-target rejection."
        )
        XCTAssertEqual(
            ProcessLocator.resolve("distill", environmentPath: nil, homeDirectory: home.path),
            compressor.path,
            "Generic bare-name resolution must retain the managed executable."
        )
        XCTAssertEqual(
            ProcessLocator.resolve(compressor.path, environmentPath: nil, homeDirectory: home.path),
            compressor.path,
            "Generic explicit-path resolution must retain the managed executable."
        )

        let foreignHome = root.appendingPathComponent("foreign-home", isDirectory: true)
        let foreignManaged = foreignHome.appendingPathComponent(".remote-code/bin", isDirectory: true)
        let foreignLocal = foreignHome.appendingPathComponent(".local/bin", isDirectory: true)
        let foreignGrokBin = foreignHome.appendingPathComponent(".grok/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignManaged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreignLocal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreignGrokBin, withIntermediateDirectories: true)
        let foreignCompressor = foreignManaged.appendingPathComponent("distill")
        let foreignBridge = foreignLocal.appendingPathComponent("distill")
        try "#!/bin/sh\nexit 0\n".write(to: foreignCompressor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: foreignCompressor.path)
        try FileManager.default.createSymbolicLink(at: foreignBridge, withDestinationURL: foreignCompressor)
        let runAsUser = AgentRunAsUser(
            generatedUID: "foreign",
            shortName: "foreign",
            uid: getuid() + 1,
            gid: getgid(),
            homePath: foreignHome.path
        )
        XCTAssertNil(
            ProcessLocator.resolveDistillAgentForRunAsUser(foreignBridge.path, runAsUser: runAsUser),
            "An explicit bridge for the execution account must be rejected."
        )
        try FileManager.default.createSymbolicLink(
            at: foreignGrokBin.appendingPathComponent("distill"),
            withDestinationURL: compressor
        )
        XCTAssertEqual(
            ProcessLocator.resolveDistillAgent(
                "distill",
                environmentPath: "\(foreignGrokBin.path):\(providerBin.path)",
                homeDirectory: foreignHome.path,
                managedHomes: [home.path, foreignHome.path]
            ),
            agent.path,
            "The resolver must reject a cross-home compressor bridge and continue to the real harness."
        )
    }

    func test_distillACPClientLaunchesResolvedAgentAndReceivesInitialize() async throws {
        // WHY: resolver-only assertions cannot prove the ACP launch boundary
        // uses the selected agent executable rather than a managed `distill` shim.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-acp-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let marker = root.appendingPathComponent("initialize-received")
        let compressorMarker = root.appendingPathComponent("compressor-invoked")
        let home = root.appendingPathComponent("fake-home", isDirectory: true)
        let managed = home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        let local = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let compressor = managed.appendingPathComponent("distill")
        let bridge = local.appendingPathComponent("distill")
        let compressorSource = """
        #!/bin/sh
        printf invoked > "\(compressorMarker.path)"
        """
        try compressorSource.write(to: compressor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compressor.path)
        try FileManager.default.createSymbolicLink(at: bridge, withDestinationURL: compressor)
        let runAsUser = AgentRunAsUser(
            generatedUID: "same-user-test",
            shortName: "same-user-test",
            uid: getuid(),
            gid: getgid(),
            homePath: home.path
        )
        XCTAssertThrowsError(
            try DistillACPClient(binary: bridge.path, cwd: root.path, launchArguments: [], runAsUser: runAsUser)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: compressorMarker.path))

        let harness = root.appendingPathComponent("distill-agent")
        let source = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        marker = pathlib.Path(\(String(reflecting: marker.path)))
        for line in sys.stdin:
            message = json.loads(line)
            if message.get("method") == "initialize":
                marker.write_text("yes")
                result = {"protocolVersion": 1, "agentCapabilities": {"promptCapabilities": {}, "sessionCapabilities": {}}}
                print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
        """
        try source.write(to: harness, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.path)

        let client = try DistillACPClient(binary: harness.path, cwd: root.path, launchArguments: [])
        defer { client.stop() }
        let initialized = try await client.initialize()

        XCTAssertEqual(initialized.protocolVersion, 1)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "yes")
    }
}

final class DistillProvisionerBoundedInstallerTests: XCTestCase {
    func test_downloadFailureIsNotMaskedByTheInstallerShell() {
        let official = DistillProvisioner.installPlan()
        var arguments = official.shellArguments
        arguments[arguments.count - 1] = "/usr/bin/false | /bin/sh"
        let failedDownload = DistillInstallPlan(shellPath: official.shellPath, shellArguments: arguments, commandLine: "failed download")
        XCTAssertNotEqual(DistillProvisioner.runInstaller(failedDownload, timeoutSeconds: 5), 0)
    }
    func test_officialInstallLayoutResolvesWithoutShellPath_becauseTheGUIAppMustFindAFreshAutoInstall() throws {
        // WHY: install.sh puts the binary in ~/.local/share/distill/bin, which a GUI app's PATH never contains.
        // After an auto-install RemoteCode must still find it, or every run keeps failing as "not installed".
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("distill-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/share/distill/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = bin.appendingPathComponent("distill")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        XCTAssertNil(DistillProvisioner.resolveInstalledBinary(environmentPath: "/usr/bin:/bin", homeDirectory: home.path + "-missing"))
        let resolved = try XCTUnwrap(DistillProvisioner.resolveInstalledBinary(environmentPath: "/usr/bin:/bin", homeDirectory: home.path))
        XCTAssertEqual(URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path, binary.resolvingSymlinksInPath().path)
    }

    func test_installerRunnerIsBounded_becauseAHungInstallerMustNotParkTheAppForever() {
        let plan = DistillInstallPlan(shellPath: "/bin/sh", shellArguments: ["-c", "sleep 30"], commandLine: "sleep 30")
        let start = Date()
        let status = DistillProvisioner.runInstaller(plan, timeoutSeconds: 1)
        XCTAssertNotEqual(status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func test_installerRunnerReturnsSuccessForSuccessfulInstaller() {
        let plan = DistillInstallPlan(shellPath: "/bin/sh", shellArguments: ["-c", "exit 0"], commandLine: "exit 0")
        XCTAssertEqual(DistillProvisioner.runInstaller(plan, timeoutSeconds: 5), 0)
    }
}
