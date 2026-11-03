import CryptoKit
import XCTest
@testable import AgentRuntime

final class DistillGuestBinaryTests: XCTestCase {
    /// Serves fake release files and records every URL requested. A URL can be
    /// held until `release(_:)` so a test observes a download in flight. A
    /// cancelled fetch fails, as a URLSession download does.
    private final class FakeRelease: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: Data] = [:]
        private var held: [String: [CheckedContinuation<Void, Never>]] = [:]
        private var holding: Set<String> = []
        private var fetched: [String] = []

        var requests: [String] { lock.withLock { fetched } }

        func publish(_ version: String, assets: [String: Data], sums: String? = nil) {
            lock.withLock {
                let base = "\(DistillGuestBinaryProvisioner.releaseBaseURL)/v\(version)/"
                let lines = assets.keys.sorted().map { "\(Self.hex(assets[$0]!))  \($0)" }
                files[base + "SHA256SUMS"] = Data((sums ?? lines.joined(separator: "\n") + "\n").utf8)
                for (name, data) in assets { files[base + name] = data }
            }
        }

        func hold(_ url: String) { lock.withLock { _ = holding.insert(url) } }

        func release(_ url: String) {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                holding.remove(url)
                return held.removeValue(forKey: url) ?? []
            }
            waiters.forEach { $0.resume() }
        }

        var fetch: DistillGuestBinaryProvisioner.Fetch {
            { url, destination in
                let key = url.absoluteString
                let mustWait = self.lock.withLock { () -> Bool in
                    self.fetched.append(key)
                    return self.holding.contains(key)
                }
                if mustWait {
                    await withCheckedContinuation { continuation in
                        let resumeNow = self.lock.withLock { () -> Bool in
                            guard self.holding.contains(key) else { return true }
                            self.held[key, default: []].append(continuation)
                            return false
                        }
                        if resumeNow { continuation.resume() }
                    }
                }
                // URLSession drops a cancelled transfer; so does this fake, so a
                // run that cancels the shared download is seen by the tests.
                try Task.checkCancellation()
                guard let data = self.lock.withLock({ self.files[key] }) else {
                    throw DistillGuestBinaryError.downloadFailed(url: key, status: 404)
                }
                try data.write(to: destination)
            }
        }

        static func hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var output: String
        private var count = 0
        init(_ output: String) { self.output = output }
        var calls: Int { lock.withLock { count } }
        func set(_ value: String) { lock.withLock { output = value } }
        var probe: DistillGuestBinaryProvisioner.VersionProbe {
            { _ in self.lock.withLock { self.count += 1; return self.output } }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private var root: URL!
    private let asset = "distill-linux-aarch64"
    private let v31 = DistillVersion(2, 0, 31)
    private let v32 = DistillVersion(2, 0, 32)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-guest-distill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ version: String, _ file: String) -> String {
        "\(DistillGuestBinaryProvisioner.releaseBaseURL)/v\(version)/\(file)"
    }

    /// A real file stands in for the host binary: the version cache keys on its path and mtime.
    private func hostBinary() throws -> String {
        let path = root.appendingPathComponent("host-distill").path
        if !FileManager.default.fileExists(atPath: path) {
            try Data("host".utf8).write(to: URL(fileURLWithPath: path))
        }
        return path
    }

    private func provisioner(
        _ release: FakeRelease,
        probe: ProbeCounter = ProbeCounter("distill 2.0.31 (abc)")
    ) -> DistillGuestBinaryProvisioner {
        DistillGuestBinaryProvisioner(guestToolsRoot: root, fetch: release.fetch, versionProbe: probe.probe)
    }

    /// A provisioner with 2.0.31 cached whose host distill was then updated to 2.0.32.
    private func provisionerAfterHostUpdate(
        _ release: FakeRelease
    ) async throws -> (subject: DistillGuestBinaryProvisioner, host: String) {
        release.publish("2.0.31", assets: [asset: Data("v31".utf8)])
        let probe = ProbeCounter("distill 2.0.31 (a)")
        let subject = provisioner(release, probe: probe)
        let host = try hostBinary()
        _ = try await subject.resolve(hostBinary: host, dockerArch: "arm64")
        probe.set("distill 2.0.32 (b)")
        try Data("updated host".utf8).write(to: URL(fileURLWithPath: host))
        return (subject, host)
    }

    private func assetFetches(_ release: FakeRelease, _ version: String) -> Int {
        release.requests.filter { $0 == url(version, asset) }.count
    }

    private func installedPath(_ version: String) -> String {
        root.appendingPathComponent("distill/\(version)/\(asset)").path
    }

    // MARK: Policy

    func test_versionParsing_readsTheReleaseFromTheBinaryBanner() {
        XCTAssertEqual(DistillVersion.parseVersionOutput("distill 2.0.30 (d8b69029122f)\n"), DistillVersion(2, 0, 30))
        XCTAssertNil(DistillVersion.parseVersionOutput("grok 2.0.30"), "another CLI's banner is not a distill version")
        XCTAssertNil(DistillVersion.parseVersionOutput("distill dev"))
        XCTAssertNil(DistillVersion("2.0"))
        // Lexical order would keep 2.0.9 over 2.0.10 and run a stale guest build.
        XCTAssertGreaterThan(DistillVersion(2, 0, 10), DistillVersion(2, 0, 9))
    }

    /// 2.0.30 linux-aarch64 SIGILLs on Apple Silicon, so an older or unknown
    /// host never selects it; a newer host is followed so guest features match.
    func test_guestVersion_isHostVersionRaisedToTheMinimum() {
        XCTAssertEqual(DistillGuestBinaryProvisioner.minimumVersion, v31)
        XCTAssertEqual(DistillGuestBinaryProvisioner.guestVersion(host: DistillVersion(2, 0, 30)), v31)
        XCTAssertEqual(DistillGuestBinaryProvisioner.guestVersion(host: nil), v31)
        XCTAssertEqual(DistillGuestBinaryProvisioner.guestVersion(host: v32), v32)
    }

    func test_assetName_mapsDockerArchitecturesAndRejectsOthers() throws {
        XCTAssertEqual(try DistillGuestBinaryProvisioner.assetName(dockerArch: "arm64"), "distill-linux-aarch64")
        XCTAssertEqual(try DistillGuestBinaryProvisioner.assetName(dockerArch: "aarch64"), "distill-linux-aarch64")
        XCTAssertEqual(try DistillGuestBinaryProvisioner.assetName(dockerArch: "amd64"), "distill-linux-x86_64")
        XCTAssertEqual(try DistillGuestBinaryProvisioner.assetName(dockerArch: "x86_64"), "distill-linux-x86_64")
        XCTAssertThrowsError(try DistillGuestBinaryProvisioner.assetName(dockerArch: "s390x")) {
            XCTAssertEqual($0 as? DistillGuestBinaryError, .unsupportedArchitecture("s390x"))
        }
    }

    func test_dockerArchitecture_readsTheDockerInfoLine() {
        let info = " Operating System: OrbStack\n OSType: linux\n Architecture: aarch64\n CPUs: 8\n"
        XCTAssertEqual(DistillGuestBinaryProvisioner.dockerArchitecture(fromInfo: info), "aarch64")
        XCTAssertNil(DistillGuestBinaryProvisioner.dockerArchitecture(fromInfo: ""))
    }

    // MARK: Download and cache

    /// The guest executes this file, so it must be the published, checksummed
    /// asset, executable, and reachable through the read-only agent kit bind.
    func test_resolve_downloadsVerifiesAndInstallsTheReleaseAsset() async throws {
        let release = FakeRelease()
        let payload = Data("linux binary".utf8)
        release.publish("2.0.31", assets: [asset: payload])
        let binary = try await provisioner(release).resolve(hostBinary: try hostBinary(), dockerArch: "arm64")

        XCTAssertEqual(release.requests, [url("2.0.31", "SHA256SUMS"), url("2.0.31", asset)])
        XCTAssertEqual(binary.version, v31)
        XCTAssertEqual(binary.requestedVersion, v31)
        XCTAssertEqual(binary.hostURL.path, installedPath("2.0.31"))
        XCTAssertEqual(binary.guestPath, "/opt/remotecode-agent/distill/2.0.31/distill-linux-aarch64")
        XCTAssertEqual(try Data(contentsOf: binary.hostURL), payload)
        let mode = try FileManager.default.attributesOfItem(atPath: binary.hostURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o755)
        let sidecar = try String(contentsOfFile: installedPath("2.0.31") + ".sha256", encoding: .utf8)
        XCTAssertEqual(sidecar, "\(FakeRelease.hex(payload))  \(asset)\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".partial").path), [])
    }

    /// The asset is ~224 MB; a verified cache must never touch the network,
    /// including after an app restart (a fresh provisioner on the same directory).
    func test_cacheHit_makesZeroFetches() async throws {
        let release = FakeRelease()
        release.publish("2.0.31", assets: [asset: Data("bin".utf8)])
        _ = try await provisioner(release).resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
        let restarted = FakeRelease()
        let binary = try await provisioner(restarted).resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
        XCTAssertEqual(binary.version, v31)
        XCTAssertEqual(restarted.requests, [])
    }

    /// A tampered or truncated cached binary is not trusted: it is fetched again.
    func test_cachedFileNotMatchingItsSidecar_isDownloadedAgain() async throws {
        let release = FakeRelease()
        release.publish("2.0.31", assets: [asset: Data("bin".utf8)])
        _ = try await provisioner(release).resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: installedPath("2.0.31")))

        let again = FakeRelease()
        again.publish("2.0.31", assets: [asset: Data("bin".utf8)])
        let binary = try await provisioner(again).resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
        XCTAssertEqual(again.requests.count, 2)
        XCTAssertEqual(try Data(contentsOf: binary.hostURL), Data("bin".utf8))
    }

    /// A corrupted or substituted download never reaches the guest-visible path.
    func test_checksumMismatch_rejectsAndDeletesThePartialFile() async throws {
        let release = FakeRelease()
        release.publish("2.0.31", assets: [asset: Data("evil".utf8)], sums: "\(FakeRelease.hex(Data("good".utf8)))  \(asset)\n")
        do {
            _ = try await provisioner(release).resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
            XCTFail("a checksum mismatch must fail")
        } catch DistillGuestBinaryError.checksumMismatch(let name, _, _) {
            XCTAssertEqual(name, asset)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedPath("2.0.31")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".partial").path), [])
    }

    /// A release without this architecture fails before the large download starts.
    func test_assetMissingFromChecksums_failsWithoutDownloadingTheAsset() async throws {
        let release = FakeRelease()
        release.publish("2.0.31", assets: ["distill-linux-x86_64": Data("x".utf8)])
        do {
            _ = try await provisioner(release).resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
            XCTFail("a missing asset must fail")
        } catch {
            XCTAssertEqual(error as? DistillGuestBinaryError, .assetNotInChecksums(asset: asset, version: v31))
        }
        XCTAssertEqual(release.requests, [url("2.0.31", "SHA256SUMS")])
    }

    /// A failed download is not remembered: the next run tries again.
    func test_failedDownload_isRetriedByTheNextResolve() async throws {
        let release = FakeRelease()
        let subject = provisioner(release)
        do {
            _ = try await subject.resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
            XCTFail("nothing published yet")
        } catch {}
        release.publish("2.0.31", assets: [asset: Data("bin".utf8)])
        let binary = try await subject.resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
        XCTAssertEqual(binary.version, v31)
    }

    /// Two bot runs starting together download the asset once.
    func test_concurrentResolves_shareOneDownload() async throws {
        let release = FakeRelease()
        release.publish("2.0.31", assets: [asset: Data("bin".utf8)])
        release.hold(url("2.0.31", asset))
        let subject = provisioner(release)
        let host = try hostBinary()
        async let first = subject.resolve(hostBinary: host, dockerArch: "arm64")
        async let second = subject.resolve(hostBinary: host, dockerArch: "arm64")
        try await waitUntil { release.requests.contains(self.url("2.0.31", self.asset)) }
        release.release(url("2.0.31", asset))
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(release.requests.filter { $0.hasSuffix(asset) }.count, 1)
    }

    // MARK: Host version changes

    /// A host update must not make the next bot message wait minutes for
    /// ~224 MB: the cached previous build runs at once while the new one
    /// downloads, and the run after the download gets the new build.
    func test_hostUpdate_runsTheCachedPreviousVersionAtOnceWhileTheNewOneDownloads() async throws {
        let release = FakeRelease()
        release.publish("2.0.32", assets: [asset: Data("v32".utf8)])
        let (subject, host) = try await provisionerAfterHostUpdate(release)
        release.hold(url("2.0.32", asset))
        let during = try await subject.resolve(hostBinary: host, dockerArch: "arm64")
        XCTAssertEqual(during.version, v31)
        XCTAssertEqual(during.requestedVersion, v32)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedPath("2.0.32")))

        release.release(url("2.0.32", asset))
        try await waitUntil { FileManager.default.fileExists(atPath: self.installedPath("2.0.32") + ".sha256") }
        let after = try await subject.resolve(hostBinary: host, dockerArch: "arm64")
        XCTAssertEqual(after.version, v32)
        XCTAssertEqual(try Data(contentsOf: after.hostURL), Data("v32".utf8))
        XCTAssertEqual(assetFetches(release, "2.0.32"), 1, "the run that fell back must not cancel or restart the download")
    }

    /// Offline, or a release without the asset: the bot still runs, on the
    /// newest build it has, and the result says it is not the wanted one.
    func test_hostUpdate_fallsBackToTheCachedPreviousVersionWhenTheNewDownloadFails() async throws {
        let release = FakeRelease()
        let (subject, host) = try await provisionerAfterHostUpdate(release)
        let binary = try await subject.resolve(hostBinary: host, dockerArch: "arm64")
        XCTAssertEqual(binary.version, v31)
        XCTAssertEqual(binary.requestedVersion, v32)
        try await waitUntil { release.requests.last == self.url("2.0.32", "SHA256SUMS") }
    }

    /// With no build cached there is nothing older to run: the first run
    /// waits for the download instead of failing.
    func test_nothingCached_waitsForTheDownload() async throws {
        let release = FakeRelease()
        release.publish("2.0.31", assets: [asset: Data("v31".utf8)])
        release.hold(url("2.0.31", asset))
        let subject = provisioner(release)
        let host = try hostBinary()
        let pending = Task { try await subject.resolve(hostBinary: host, dockerArch: "arm64") }
        try await waitUntil { self.assetFetches(release, "2.0.31") == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        release.release(url("2.0.31", asset))
        let binary = try await pending.value
        XCTAssertEqual(binary.version, v31)
    }

    /// A first run waits for the download without a bound, so Stop is the
    /// only way out: it must end the run at once instead of holding it until
    /// ~224 MB arrive, and must not throw away the download the next run needs.
    func test_nothingCached_stopEndsTheWaitAndLeavesTheDownloadUsable() async throws {
        let release = FakeRelease()
        release.publish("2.0.31", assets: [asset: Data("v31".utf8)])
        release.hold(url("2.0.31", asset))
        let subject = provisioner(release)
        let host = try hostBinary()
        let ended = Flag()
        let stopped = Task { () -> Result<DistillGuestBinary, Error> in
            defer { ended.set() }
            do {
                return .success(try await subject.resolve(hostBinary: host, dockerArch: "arm64"))
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil { self.assetFetches(release, "2.0.31") == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(ended.isSet, "with nothing cached the run waits for the download")
        stopped.cancel()
        try await waitUntil(timeout: 2) { ended.isSet }
        // Released either way so a regression fails here instead of hanging the suite.
        release.release(url("2.0.31", asset))
        switch await stopped.value {
        case .success(let binary): XCTFail("a stopped run must not get a binary, got \(binary.version)")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }

        let next = try await subject.resolve(hostBinary: host, dockerArch: "arm64")
        XCTAssertEqual(next.version, v31)
        XCTAssertEqual(assetFetches(release, "2.0.31"), 1, "the stopped run's download finished and was reused")
    }

    /// Cached 2.0.30 must never be the fallback: it crashes in the guest. A
    /// failed download of the minimum therefore fails the run.
    func test_fallback_ignoresCachedVersionsBelowTheMinimum() async throws {
        let old = root.appendingPathComponent("distill/2.0.30", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let bin = Data("v30".utf8)
        try bin.write(to: old.appendingPathComponent(asset))
        try Data("\(FakeRelease.hex(bin))  \(asset)\n".utf8).write(to: old.appendingPathComponent("\(asset).sha256"))
        do {
            let binary = try await provisioner(FakeRelease()).resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
            XCTFail("2.0.31 cannot be downloaded and \(binary.version) must not run instead")
        } catch {
            XCTAssertEqual(error as? DistillGuestBinaryError, .downloadFailed(url: url("2.0.31", "SHA256SUMS"), status: 404))
        }
    }

    /// The host version is probed once per binary file, and probed again when
    /// an update replaces the file; prefetch then downloads the new guest build.
    func test_prefetch_downloadsTheNewGuestBuildWhenTheHostBinaryChanges() async throws {
        let release = FakeRelease()
        release.publish("2.0.31", assets: [asset: Data("v31".utf8)])
        release.publish("2.0.32", assets: [asset: Data("v32".utf8)])
        let probe = ProbeCounter("distill 2.0.31 (a)")
        let subject = provisioner(release, probe: probe)
        let host = try hostBinary()

        subject.prefetch(hostBinary: host, dockerArch: "aarch64")
        try await waitUntil { FileManager.default.fileExists(atPath: self.installedPath("2.0.31") + ".sha256") }
        subject.prefetch(hostBinary: host, dockerArch: "aarch64")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.calls, 1, "an unchanged host binary is not re-probed")
        XCTAssertEqual(release.requests.filter { $0.hasSuffix(asset) }.count, 1, "a cached build is not refetched")

        probe.set("distill 2.0.32 (b)")
        try Data("updated host binary".utf8).write(to: URL(fileURLWithPath: host))
        subject.prefetch(hostBinary: host, dockerArch: "aarch64")
        try await waitUntil { FileManager.default.fileExists(atPath: self.installedPath("2.0.32") + ".sha256") }
        XCTAssertEqual(probe.calls, 2)
    }

    /// After a host update the app prefetches for the architectures its bot
    /// VMs already run, without asking Docker (which may be stopped).
    func test_cachedArchitectures_listsTheArchitecturesWithACachedBuild() async throws {
        let release = FakeRelease()
        release.publish("2.0.31", assets: [asset: Data("v31".utf8)])
        let subject = provisioner(release)
        let none = await subject.cachedArchitectures()
        XCTAssertEqual(none, [], "a Mac that never ran a bot VM prefetches nothing")
        _ = try await subject.resolve(hostBinary: try hostBinary(), dockerArch: "arm64")
        let cached = await subject.cachedArchitectures()
        XCTAssertEqual(cached, ["aarch64"])
        XCTAssertEqual(try DistillGuestBinaryProvisioner.assetName(dockerArch: "aarch64"), asset)
    }

    // MARK: Garbage collection

    func test_collectGarbage_keepsCurrentAndPreviousVersionsOnly() async throws {
        for version in ["2.0.31", "2.0.32", "2.0.33", "2.0.34"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("distill/\(version)"), withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".partial"), withIntermediateDirectories: true
        )
        await provisioner(FakeRelease()).collectGarbage(current: DistillVersion(2, 0, 33))
        let left = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("distill").path).sorted()
        XCTAssertEqual(left, ["2.0.32", "2.0.33"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".partial").path))
    }

    /// The launch trim follows the host's version: every automatic host
    /// update adds a ~224 MB guest build, so without it the cache only grows.
    /// A host whose version cannot be read (Distill missing, a slow probe at
    /// launch) must remove nothing, or an offline bot loses its fallbacks.
    func test_collectGarbageForTheHost_trimsToItsVersionAndRemovesNothingWhenItIsUnreadable() async throws {
        let versions = ["2.0.31", "2.0.32", "2.0.33", "2.0.34"]
        for version in versions {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("distill/\(version)"), withIntermediateDirectories: true
            )
        }
        let cached = { try FileManager.default.contentsOfDirectory(atPath: self.root.appendingPathComponent("distill").path).sorted() }
        let host = try hostBinary()

        await provisioner(FakeRelease(), probe: ProbeCounter("not a version")).collectGarbage(hostBinary: host)
        XCTAssertEqual(try cached(), versions)

        await provisioner(FakeRelease(), probe: ProbeCounter("distill 2.0.33 (a)")).collectGarbage(hostBinary: host)
        XCTAssertEqual(try cached(), ["2.0.32", "2.0.33"])
    }

    private final class AttemptLog: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private var sleeps: [TimeInterval] = []
        var count: Int { lock.withLock { attempts } }
        var slept: [TimeInterval] { lock.withLock { sleeps } }
        func attempt() -> Int { lock.withLock { attempts += 1; return attempts } }
        func sleep(_ seconds: TimeInterval) { lock.withLock { sleeps.append(seconds) } }
    }

    func test_transientDownloadFailure_retriesAndSucceedsWithoutUserAction() async throws {
        // WHY: a single timed-out or dropped connection must not fail the guest binary download the user is waiting on.
        let log = AttemptLog()
        let fetch = DistillGuestBinaryProvisioner.retryingTransientDownloads(
            sleep: { log.sleep($0) },
            perform: { _, _ in
                if log.attempt() == 1 { throw URLError(.timedOut) }
            }
        )
        try await fetch(URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b"))
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log.slept, [2])
    }

    func test_permanentDownloadFailure_failsImmediatelyWithoutRetry() async {
        // WHY: a 404 will not change on retry, so retrying would only delay the real error.
        let log = AttemptLog()
        let fetch = DistillGuestBinaryProvisioner.retryingTransientDownloads(
            sleep: { log.sleep($0) },
            perform: { _, _ in
                _ = log.attempt()
                throw DistillGuestBinaryError.downloadFailed(url: "u", status: 404)
            }
        )
        do {
            try await fetch(URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b"))
            XCTFail("404 must fail")
        } catch {
            XCTAssertEqual(error as? DistillGuestBinaryError, .downloadFailed(url: "u", status: 404))
        }
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.slept, [])
    }

    func test_persistentTransientDownloadFailure_throwsTheOriginalErrorAfterThreeAttempts() async {
        // WHY: a host that stays down must still surface its real error, after a bounded number of tries.
        let log = AttemptLog()
        let fetch = DistillGuestBinaryProvisioner.retryingTransientDownloads(
            sleep: { log.sleep($0) },
            perform: { _, _ in
                _ = log.attempt()
                throw URLError(.networkConnectionLost)
            }
        )
        do {
            try await fetch(URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b"))
            XCTFail("persistent failure must throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(log.count, 3)
        XCTAssertEqual(log.slept, [2, 5])
    }

    func test_isTransientDownloadFailure_classifiesNetworkAndHTTPStatus() {
        // WHY: checksum mismatches and 4xx other than 429 are permanent; retrying them would hide a bad release.
        XCTAssertTrue(DistillGuestBinaryProvisioner.isTransientDownloadFailure(URLError(.timedOut)))
        XCTAssertTrue(DistillGuestBinaryProvisioner.isTransientDownloadFailure(URLError(.dnsLookupFailed)))
        XCTAssertTrue(DistillGuestBinaryProvisioner.isTransientDownloadFailure(DistillGuestBinaryError.downloadFailed(url: "u", status: 429)))
        XCTAssertTrue(DistillGuestBinaryProvisioner.isTransientDownloadFailure(DistillGuestBinaryError.downloadFailed(url: "u", status: 503)))
        XCTAssertFalse(DistillGuestBinaryProvisioner.isTransientDownloadFailure(DistillGuestBinaryError.downloadFailed(url: "u", status: 404)))
        XCTAssertFalse(DistillGuestBinaryProvisioner.isTransientDownloadFailure(URLError(.cancelled)))
        XCTAssertFalse(DistillGuestBinaryProvisioner.isTransientDownloadFailure(
            DistillGuestBinaryError.checksumMismatch(asset: "a", expected: "x", actual: "y")
        ))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met in \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
