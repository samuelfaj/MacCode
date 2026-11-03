import CryptoKit
import Foundation
import CoreModel

/// `major.minor.patch` of a distill release, compared numerically (2.0.10 > 2.0.9).
public struct DistillVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses exactly `X.Y.Z`.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    /// `distill 2.0.30 (d8b69029122f)` → 2.0.30.
    public static func parseVersionOutput(_ output: String) -> DistillVersion? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "distill" else { return nil }
        return DistillVersion(String(fields[1]))
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: DistillVersion, rhs: DistillVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum DistillGuestBinaryError: LocalizedError, Equatable {
    case unsupportedArchitecture(String)
    case assetNotInChecksums(asset: String, version: DistillVersion)
    case checksumMismatch(asset: String, expected: String, actual: String)
    case downloadFailed(url: String, status: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let arch):
            return "Distill has no Linux build for the Docker architecture \"\(arch)\"."
        case .assetNotInChecksums(let asset, let version):
            return "Distill \(version) has no \(asset) in its release checksums."
        case .checksumMismatch(let asset, let expected, let actual):
            return "Downloaded \(asset) failed SHA-256 verification (expected \(expected), got \(actual))."
        case .downloadFailed(let url, let status):
            return "Downloading \(url) failed with HTTP \(status)."
        }
    }
}

/// A verified Linux distill binary cached on the host, and where the guest sees it.
public struct DistillGuestBinary: Equatable, Sendable {
    public let version: DistillVersion
    /// The version this run wanted. Differs from `version` only when that one
    /// could not be downloaded in time.
    public let requestedVersion: DistillVersion
    public let assetName: String
    public let hostURL: URL
    /// Path inside the container, through the read-only agent kit bind.
    public let guestPath: String
}

/// Downloads, verifies and caches the Linux distill a bot container runs.
///
/// Cache layout: `<guest-tools>/distill/<ver>/distill-linux-<arch>` plus a
/// `.sha256` sidecar holding the release checksum. `<guest-tools>` is bound
/// read-only into every bot container at `BotComputerGuestSpec.agentKitMountPoint`.
/// The guest version is `max(host, minimumVersion)`: host and guest keep
/// separate homes, so they need not match.
public actor DistillGuestBinaryProvisioner {
    /// 2.0.30 linux-aarch64 SIGILLs on Apple Silicon (built for neoverse-v2).
    public static let minimumVersion = DistillVersion(2, 0, 31)
    public static let releaseBaseURL = "https://github.com/samuelfaj/distill/releases/download"
    public static let versionProbeTimeout: TimeInterval = 5
    /// Writes the body of `url` to `destination`; throws on a non-2xx response.
    public typealias Fetch = @Sendable (_ url: URL, _ destination: URL) async throws -> Void
    /// Runs `<binary> --version` and returns its output, nil on failure or timeout.
    public typealias VersionProbe = @Sendable (_ binaryPath: String) async -> String?

    private struct FileStamp: Hashable {
        let path: String
        let size: Int
        let modified: Date
    }

    private let root: URL
    private let fetch: Fetch
    private let versionProbe: VersionProbe
    private var hostVersions: [FileStamp: DistillVersion] = [:]
    private var verified: [FileStamp: String] = [:]
    private var inflight: [String: Task<DistillGuestBinary, Error>] = [:]

    public init(
        guestToolsRoot: URL,
        fetch: @escaping Fetch = DistillGuestBinaryProvisioner.urlSessionFetch,
        versionProbe: @escaping VersionProbe = DistillGuestBinaryProvisioner.processVersionProbe
    ) {
        self.root = guestToolsRoot
        self.fetch = fetch
        self.versionProbe = versionProbe
    }

    // MARK: Pure policy

    /// Docker reports `arm64`/`amd64` (image platforms) or `aarch64`/`x86_64` (`docker info`).
    public static func assetName(dockerArch: String) throws -> String {
        switch dockerArch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "arm64", "aarch64": return "distill-linux-aarch64"
        case "amd64", "x86_64": return "distill-linux-x86_64"
        default: throw DistillGuestBinaryError.unsupportedArchitecture(dockerArch)
        }
    }

    /// The `Architecture:` line of `docker info`.
    public static func dockerArchitecture(fromInfo info: String) -> String? {
        for line in info.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Architecture:") else { continue }
            let value = trimmed.dropFirst("Architecture:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// An unknown or older host version still gets the minimum guest build.
    public static func guestVersion(host: DistillVersion?) -> DistillVersion {
        max(host ?? minimumVersion, minimumVersion)
    }

    static func releaseURL(version: DistillVersion, file: String) -> URL {
        URL(string: "\(releaseBaseURL)/v\(version)/\(file)")!
    }

    /// `<hex>  <asset>` lines, as `install.sh` reads them; `*asset` is binary mode.
    static func checksum(for asset: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let name = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1]
            let hex = fields[0].lowercased()
            guard name == asset, hex.count == 64, hex.allSatisfy(\.isHexDigit) else { continue }
            return hex
        }
        return nil
    }

    // MARK: Resolution

    /// The host binary's version, probed once per resolved file and mtime.
    public func hostVersion(binary: String) async -> DistillVersion? {
        let resolved = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
        guard let stamp = Self.stamp(path: resolved) else { return nil }
        if let cached = hostVersions[stamp] { return cached }
        guard let output = await versionProbe(resolved),
              let version = DistillVersion.parseVersionOutput(output) else {
            NSLog("distill guest binary: could not read the host distill version from \(resolved)")
            return nil
        }
        hostVersions[stamp] = version
        return version
    }

    /// The binary a guest run launches: the wanted version when it is
    /// cached, otherwise the newest cached version at or above the minimum
    /// while the wanted one downloads in the background, so a host update
    /// never makes a run wait (the next run gets the new build). With
    /// nothing usable cached the run waits for the download; only Stop ends
    /// that wait early. The download is shared and a stopped run never
    /// cancels it.
    public func resolve(hostBinary: String?, dockerArch: String) async throws -> DistillGuestBinary {
        let asset = try Self.assetName(dockerArch: dockerArch)
        var host: DistillVersion?
        if let hostBinary { host = await hostVersion(binary: hostBinary) }
        let wanted = Self.guestVersion(host: host)
        if let cached = await cachedBinary(version: wanted, asset: asset, requested: wanted) {
            return cached
        }
        let download = startDownload(version: wanted, asset: asset)
        if let fallback = await newestCachedBinary(asset: asset, excluding: wanted, requested: wanted) {
            NSLog("distill guest binary: the bot runs the cached distill \(fallback.version) while \(wanted) downloads")
            return fallback
        }
        guard let outcome = await Self.outcome(of: download, within: nil) else { throw CancellationError() }
        return try outcome.get()
    }

    /// The result of `download`, or nil when `seconds` pass first or the
    /// waiting task is cancelled. `download` itself is never cancelled.
    private static func outcome(
        of download: Task<DistillGuestBinary, Error>, within seconds: TimeInterval?
    ) async -> Result<DistillGuestBinary, Error>? {
        let (results, signal) = AsyncStream<Result<DistillGuestBinary, Error>>.makeStream()
        Task {
            signal.yield(await download.result)
            signal.finish()
        }
        let deadline = seconds.map { seconds in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                signal.finish()
            }
        }
        var outcome: Result<DistillGuestBinary, Error>?
        // Ends when the download does, at the deadline, or when the run is stopped.
        for await result in results { outcome = result }
        deadline?.cancel()
        return outcome
    }

    /// Downloads `version` if it is not cached; returns the cached or new binary.
    public func ensure(version: DistillVersion, dockerArch: String) async throws -> DistillGuestBinary {
        let asset = try Self.assetName(dockerArch: dockerArch)
        if let cached = await cachedBinary(version: version, asset: asset, requested: version) {
            return cached
        }
        return try await startDownload(version: version, asset: asset).value
    }

    /// Starts the guest download for the host's current version in the
    /// background so a host update does not make the next run wait on it.
    public nonisolated func prefetch(hostBinary: String, dockerArch: String) {
        Task {
            do {
                let host = await self.hostVersion(binary: hostBinary)
                _ = try await self.ensure(version: Self.guestVersion(host: host), dockerArch: dockerArch)
            } catch {
                NSLog("distill guest binary prefetch failed: \(error.localizedDescription)")
            }
        }
    }

    /// The Docker architectures with a cached guest build, of any version:
    /// the ones this Mac's bot VMs run, known without asking Docker.
    public func cachedArchitectures() -> [String] {
        let prefix = "distill-linux-"
        var found = Set<String>()
        for directory in cachedVersionDirectories().values {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files where file.hasPrefix(prefix) {
                let arch = String(file.dropFirst(prefix.count))
                if (try? Self.assetName(dockerArch: arch)) == file { found.insert(arch) }
            }
        }
        return found.sorted()
    }

    /// Keeps `current` and the newest older version; removes other cached
    /// versions and abandoned partial downloads. Must not run while a guest
    /// may be executing a removed version.
    public func collectGarbage(current: DistillVersion) {
        let fm = FileManager.default
        let versions = cachedVersionDirectories()
        let previous = versions.keys.filter { $0 < current }.max()
        for (version, dir) in versions where version != current && version != previous {
            try? fm.removeItem(at: dir)
        }
        if inflight.isEmpty {
            try? fm.removeItem(at: partialDirectory)
        }
    }

    /// The launch trim for the host's current version. An unreadable host
    /// version removes nothing: `guestVersion(host: nil)` is the minimum, and
    /// collecting for it would delete every newer build, the fallbacks included.
    public func collectGarbage(hostBinary: String) async {
        guard let host = await hostVersion(binary: hostBinary) else { return }
        collectGarbage(current: Self.guestVersion(host: host))
    }

    // MARK: Cache

    private var distillDirectory: URL { root.appendingPathComponent("distill", isDirectory: true) }
    private var partialDirectory: URL { root.appendingPathComponent(".partial", isDirectory: true) }

    private func binaryURL(version: DistillVersion, asset: String) -> URL {
        distillDirectory
            .appendingPathComponent(version.description, isDirectory: true)
            .appendingPathComponent(asset, isDirectory: false)
    }

    private static func sidecarURL(for binary: URL) -> URL {
        binary.deletingLastPathComponent().appendingPathComponent("\(binary.lastPathComponent).sha256")
    }

    private func binary(version: DistillVersion, asset: String, requested: DistillVersion, url: URL) -> DistillGuestBinary {
        DistillGuestBinary(
            version: version,
            requestedVersion: requested,
            assetName: asset,
            hostURL: url,
            guestPath: "\(BotComputerGuestSpec.agentKitMountPoint)/distill/\(version)/\(asset)"
        )
    }

    /// A cache hit needs the file, its sidecar, and a file hash equal to the
    /// sidecar. The hash is computed once per file stamp; the guest executes it.
    private func cachedBinary(version: DistillVersion, asset: String, requested: DistillVersion) async -> DistillGuestBinary? {
        let url = binaryURL(version: version, asset: asset)
        guard let stamp = Self.stamp(path: url.path),
              let sidecar = try? String(contentsOf: Self.sidecarURL(for: url), encoding: .utf8),
              let expected = Self.checksum(for: asset, in: sidecar) else { return nil }
        let actual: String?
        if let known = verified[stamp] {
            actual = known
        } else {
            actual = await ProviderCLIProbe.runOffCooperativePool { try? Self.sha256Hex(of: url) }
            if let actual { verified[stamp] = actual }
        }
        return actual == expected ? binary(version: version, asset: asset, requested: requested, url: url) : nil
    }

    private func newestCachedBinary(asset: String, excluding: DistillVersion, requested: DistillVersion) async -> DistillGuestBinary? {
        let candidates = cachedVersionDirectories().keys
            .filter { $0 != excluding && $0 >= Self.minimumVersion }
            .sorted(by: >)
        for version in candidates {
            if let hit = await cachedBinary(version: version, asset: asset, requested: requested) { return hit }
        }
        return nil
    }

    private func cachedVersionDirectories() -> [DistillVersion: URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: distillDirectory, includingPropertiesForKeys: nil
        )) ?? []
        var result: [DistillVersion: URL] = [:]
        for entry in entries {
            if let version = DistillVersion(entry.lastPathComponent) { result[version] = entry }
        }
        return result
    }

    // MARK: Download

    private static func downloadKey(version: DistillVersion, asset: String) -> String {
        "\(version)/\(asset)"
    }

    private func startDownload(version: DistillVersion, asset: String) -> Task<DistillGuestBinary, Error> {
        let key = Self.downloadKey(version: version, asset: asset)
        if let running = inflight[key] { return running }
        let task = Task { [fetch, root] () throws -> DistillGuestBinary in
            do {
                let (url, hex) = try await Self.download(version: version, asset: asset, root: root, fetch: fetch)
                return self.finishDownload(key: key, version: version, asset: asset, url: url, hex: hex)
            } catch {
                self.finishDownload(key: key)
                throw error
            }
        }
        inflight[key] = task
        return task
    }

    private func finishDownload(key: String) {
        inflight[key] = nil
    }

    private func finishDownload(key: String, version: DistillVersion, asset: String, url: URL, hex: String) -> DistillGuestBinary {
        inflight[key] = nil
        if let stamp = Self.stamp(path: url.path) { verified[stamp] = hex }
        return binary(version: version, asset: asset, requested: version, url: url)
    }

    /// SHA256SUMS first, so a release without this asset fails before the large download.
    private static func download(
        version: DistillVersion, asset: String, root: URL, fetch: Fetch
    ) async throws -> (url: URL, sha256: String) {
        let fm = FileManager.default
        let partials = root.appendingPathComponent(".partial", isDirectory: true)
        try fm.createDirectory(at: partials, withIntermediateDirectories: true)
        let token = UUID().uuidString.lowercased()
        let sumsPartial = partials.appendingPathComponent("\(token)-SHA256SUMS")
        let assetPartial = partials.appendingPathComponent("\(token)-\(asset)")
        defer {
            try? fm.removeItem(at: sumsPartial)
            try? fm.removeItem(at: assetPartial)
        }

        try await fetch(releaseURL(version: version, file: "SHA256SUMS"), sumsPartial)
        let sums = try String(contentsOf: sumsPartial, encoding: .utf8)
        guard let expected = checksum(for: asset, in: sums) else {
            throw DistillGuestBinaryError.assetNotInChecksums(asset: asset, version: version)
        }

        try await fetch(releaseURL(version: version, file: asset), assetPartial)
        let actual = try await ProviderCLIProbe.runOffCooperativePool { Result { try sha256Hex(of: assetPartial) } }.get()
        guard actual == expected else {
            throw DistillGuestBinaryError.checksumMismatch(asset: asset, expected: expected, actual: actual)
        }

        let final = root
            .appendingPathComponent("distill", isDirectory: true)
            .appendingPathComponent(version.description, isDirectory: true)
            .appendingPathComponent(asset, isDirectory: false)
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: assetPartial.path)
        // rename(2) replaces atomically; a guest still running an old inode keeps it.
        guard rename(assetPartial.path, final.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: final.path])
        }
        // Written after the binary: a binary without a sidecar is never a cache hit.
        try Data("\(expected)  \(asset)\n".utf8).write(to: sidecarURL(for: final), options: .atomic)
        return (final, expected)
    }

    // MARK: Files

    private static func stamp(path: String) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileStamp(path: path, size: size, modified: modified)
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Defaults

    /// Connection timeouts, dropped connections, DNS failures and HTTP 429/5xx are worth
    /// another download. A checksum mismatch or any other 4xx is permanent.
    static func isTransientDownloadFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
                 .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        if let downloadError = error as? DistillGuestBinaryError, case .downloadFailed(_, let status) = downloadError {
            return status == 429 || (500...599).contains(status)
        }
        return false
    }

    /// Runs `perform` again after each `delays` entry while its failure is transient.
    /// The last failure is thrown unchanged once retries run out.
    static func retryingTransientDownloads(
        delays: [TimeInterval] = [2, 5],
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        perform: @escaping Fetch
    ) -> Fetch {
        { url, destination in
            var attempt = 0
            while true {
                do {
                    try await perform(url, destination)
                    return
                } catch where attempt < delays.count && isTransientDownloadFailure(error) {
                    try await sleep(delays[attempt])
                    attempt += 1
                }
            }
        }
    }

    public static let urlSessionFetch: Fetch = retryingTransientDownloads(perform: downloadOnce)

    private static let downloadOnce: Fetch = { url, destination in
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (temp, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: temp)
            throw DistillGuestBinaryError.downloadFailed(url: url.absoluteString, status: status)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    public static let processVersionProbe: VersionProbe = { path in
        await ProviderCLIProbe.runOffCooperativePool {
            ProviderCLIProbe.version(binaryPath: path, timeoutSeconds: versionProbeTimeout)
        }
    }
}
