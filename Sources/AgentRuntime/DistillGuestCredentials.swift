import Foundation
import os

private let guestCredentialLog = Logger(subsystem: "io.remotecode.agent", category: "distill.guest.credentials")

public enum DistillGuestCredentialError: LocalizedError, Equatable {
    case notSignedIn(DistillAccountProvider)
    case unreadable(DistillAccountProvider)
    case lockTimeout(DistillAccountProvider)
    case refreshTokenMissing(DistillAccountProvider)
    /// The provider refused this refresh token (it is spent or revoked).
    case refreshRejected(DistillAccountProvider, status: Int, code: String?)
    /// A transient failure (network, 429, 5xx): the same token may work later.
    case refreshFailed(DistillAccountProvider, status: Int, code: String?)
    case refreshResponseInvalid(DistillAccountProvider)
    case accountChanged(DistillAccountProvider)
    case grokLoginExpiring(expiresAt: Date)
    case unsafeDirectory(path: String)
    case writeFailed(path: String, errno: Int32)
    case watchFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn(let provider):
            return "\(provider.displayName) is not signed in on this Mac. Sign in under Settings › Accounts (or run `\(Self.loginCommand(provider))`), then send again."
        case .unreadable(let provider):
            return "The \(provider.displayName) sign-in file on this Mac (\(provider.credentialFileName)) cannot be read. Sign in to \(provider.displayName) again under Settings › Accounts, then send again."
        case .lockTimeout(let provider):
            return "Another Distill process on this Mac is still refreshing the \(provider.displayName) sign-in. Send again in a moment."
        case .refreshTokenMissing(let provider):
            return "The \(provider.displayName) sign-in on this Mac has expired and cannot be renewed. Sign in again under Settings › Accounts (or run `\(Self.loginCommand(provider))`), then send again."
        case .refreshRejected(let provider, let status, let code):
            return "\(provider.displayName) rejected the sign-in renewal on this Mac (HTTP \(status)\(code.map { ", \($0)" } ?? "")). Sign in to \(provider.displayName) again under Settings › Accounts (or run `\(Self.loginCommand(provider))`), then send again."
        case .refreshFailed(let provider, let status, let code):
            let cause = status == 0 ? "the sign-in server could not be reached" : "HTTP \(status)\(code.map { ", \($0)" } ?? "")"
            return "Could not renew the \(provider.displayName) sign-in on this Mac (\(cause)). The Linux agent was not started; send again in a moment."
        case .refreshResponseInvalid(let provider):
            return "\(provider.displayName) answered the sign-in renewal with something this app does not understand. The sign-in on this Mac was left unchanged; send again, or sign in again under Settings › Accounts."
        case .accountChanged(let provider):
            return "\(provider.displayName) renewed the sign-in for a different account. The sign-in on this Mac was left unchanged; sign in again under Settings › Accounts."
        case .grokLoginExpiring(let expiresAt):
            let when = expiresAt.timeIntervalSinceNow <= 0
                ? "has expired"
                : "expires at \(DateFormatter.localizedString(from: expiresAt, dateStyle: .none, timeStyle: .short))"
            return "The Grok login on this Mac \(when). Open a Distill thread on the Mac to refresh it, or run `distill login`, then send again."
        case .unsafeDirectory(let path):
            return "\(path) is not a plain directory, so the Linux agent's sign-in copies were not written there."
        case .writeFailed(let path, let code):
            return "Could not write \(path): \(String(cString: strerror(code)))."
        case .watchFailed(let path, let code):
            return "Could not watch \(path) for sign-in changes (\(String(cString: strerror(code)))), so the Linux agent's sign-in copies could not be kept fresh. The Linux agent was not started."
        }
    }

    static func loginCommand(_ provider: DistillAccountProvider) -> String {
        (["distill"] + (provider.cliLoginArguments ?? ["login"])).joined(separator: " ")
    }
}

/// The in-guest agent's copies of the user's Distill sign-ins.
///
/// The guest gets its own `DISTILL_HOME` (a directory on the guest-home bind,
/// never the Mac's `~/.distill` and never single-file binds, which a
/// rename-replace would pin to the old inode). The copies carry the access
/// token but a blank refresh token: Claude and ChatGPT rotate refresh tokens
/// and treat a reused one as theft, so only the Mac may ever spend one. Claude
/// and Codex re-read the file on every request, and Grok adopts newer tokens
/// from disk, so re-copying after the Mac renews a token is enough.
///
/// Every file operation is relative to a directory descriptor opened without
/// following symlinks: the guest owns that directory and could otherwise point
/// it at the Mac's own `~/.distill`, which these writes and deletes would then
/// destroy.
public enum DistillGuestCredentials {
    /// What one sync did, by provider. Never carries file contents.
    public struct SyncResult: Equatable, Sendable {
        public var written: [DistillAccountProvider] = []
        public var unchanged: [DistillAccountProvider] = []
        /// Signed out on the Mac: the guest copy was deleted.
        public var removed: [DistillAccountProvider] = []
        /// The Mac file is not a JSON object: not copied, guest copy deleted.
        public var unreadable: [DistillAccountProvider] = []
    }

    static let temporaryPrefix = ".rc-credential-"

    /// `<guest home>/.distill`, the guest run's `DISTILL_HOME` seen from the Mac.
    public static func distillHome(guestHome: URL) -> URL {
        guestHome.appendingPathComponent(".distill", isDirectory: true)
    }

    // MARK: - Guest copies

    /// The bytes the guest gets for one Mac credential file; nil when the Mac
    /// file is not a JSON object (copying it raw could carry a refresh token).
    static func guestCopy(_ provider: DistillAccountProvider, hostData: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: hostData)) as? [String: Any] else { return nil }
        func stripped(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.mapValues(stripped).reduce(into: [String: Any]()) { result, item in
                    result[item.key] = item.key.lowercased() == "refresh_token" ? "" : item.value
                }
            }
            if let array = value as? [Any] { return array.map(stripped) }
            return value
        }
        root = stripped(root) as? [String: Any] ?? [:]
        switch provider {
        case .claude:
            // Distill requires the key: without it the file does not parse and
            // the account looks signed out.
            if root["refresh_token"] != nil { root["refresh_token"] = "" }
        case .chatgpt:
            if var tokens = root["tokens"] as? [String: Any], tokens["refresh_token"] != nil {
                tokens["refresh_token"] = ""
                root["tokens"] = tokens
            }
        case .grok:
            // Optional in Distill's Grok store: each scope just loses it.
            for (scope, value) in root {
                guard var entry = value as? [String: Any] else { continue }
                entry.removeValue(forKey: "refresh_token")
                root[scope] = entry
            }
        case .openrouter:
            break
        }
        guard var data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Makes the guest copies match the Mac sign-ins: written atomically at
    /// 0600 when they differ, deleted when the Mac is signed out.
    @discardableResult
    public static func sync(hostHome: URL, guestDistillHome: URL) throws -> SyncResult {
        let directory = try PrivateDirectory(guestDistillHome, create: true)
        defer { directory.close() }
        var result = SyncResult()
        let host = try? PrivateDirectory(hostHome.resolvingSymlinksInPath(), create: false)
        defer { host?.close() }
        for provider in DistillAccountProvider.allCases {
            let name = provider.credentialFileName
            let hostFile = hostHome.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: hostFile.path) else {
                if directory.remove(name) { result.removed.append(provider) }
                continue
            }
            guard let hostData = host?.read(name),
                  let copy = guestCopy(provider, hostData: hostData) else {
                directory.remove(name)
                result.unreadable.append(provider)
                guestCredentialLog.error("bot.guest.credentials.unreadable file=\(name, privacy: .public)")
                continue
            }
            if directory.read(name) == copy {
                result.unchanged.append(provider)
                continue
            }
            try directory.writeAtomically(copy, to: name)
            result.written.append(provider)
        }
        try syncNamed(hostHome: hostHome, host: host, guest: directory)
        return result
    }

    private static func syncNamed(hostHome: URL, host: PrivateDirectory?, guest: PrivateDirectory) throws {
        let registry: DistillAccountRegistry?
        do { registry = try DistillAccounts.readRegistry(home: hostHome) }
        catch {
            guest.remove("accounts.json")
            guest.removeTree("accounts")
            throw error
        }
        guard let registry else {
            guest.remove("accounts.json")
            guest.removeTree("accounts")
            return
        }
        let target = try guest.child("accounts", create: true)
        defer { target.close() }
        let source = try? host?.child("accounts", create: false)
        defer { source?.close() }
        let ids = Set(registry.accounts.map(\.id))
        for entry in target.entries() where !ids.contains(entry) { target.removeTree(entry) }
        for account in registry.accounts {
            let destination = try target.child(account.id, create: true)
            defer { destination.close() }
            let origin = try? source?.child(account.id, create: false)
            defer { origin?.close() }
            // A removed provider file must also remove its stale backups/locks.
            if !account.legacy {
                let name = account.provider.credentialFileName
                if let data = origin?.read(name), let copy = guestCopy(account.provider, hostData: data) {
                    if destination.read(name) != copy { try destination.writeAtomically(copy, to: name) }
                } else {
                    for entry in destination.entries() where entry == name || entry.hasPrefix(name + ".") {
                        destination.removeTree(entry)
                    }
                }
            }
            if let data = origin?.read("quota.json"),
               let quota = try? JSONDecoder().decode(DistillAccountQuota.self, from: data),
               quota.accountID == account.id,
               ["available", "unavailable", "unsupported"].contains(quota.status),
               DistillHostCredentialRefresher.parseDate(quota.checkedAt) != nil,
               quota.fetchedAt == nil || quota.fetchedAt.flatMap(DistillHostCredentialRefresher.parseDate) != nil,
               quota.remainingPercent == nil || (0...100).contains(quota.remainingPercent ?? -1) {
                let safeQuota = DistillAccountQuota(accountID: quota.accountID, checkedAt: quota.checkedAt,
                    fetchedAt: quota.fetchedAt, status: quota.status, remainingPercent: quota.remainingPercent,
                    detail: safeQuotaDetail(quota.detail))
                // Sorted keys: a detail object's key order otherwise changes
                // between encodings, and every pass would rewrite the copy.
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let safe = try encoder.encode(safeQuota)
                if destination.read("quota.json") != safe { try destination.writeAtomically(safe, to: "quota.json") }
            } else { destination.remove("quota.json") }
        }
        let data = try JSONEncoder().encode(GuestRegistry(registry))
        if guest.read("accounts.json") != data { try guest.writeAtomically(data, to: "accounts.json") }
    }

    /// `accounts.json` exactly as Distill defines it. `DistillAccountStatus`
    /// would add its own `connected` to every account: a registry key Distill
    /// does not define, which a strict reader refuses along with the whole
    /// registry, failing every session in the guest. Distill 2.0.42 ignores an
    /// extra account key; the guest's file still carries only its own format.
    private struct GuestRegistry: Encodable {
        struct Account: Encodable {
            let id: String
            let provider: DistillAccountProvider
            let label: String
            let legacy: Bool
        }

        let version: Int
        let accounts: [Account]
        let routing: DistillAutoRouting

        init(_ registry: DistillAccountRegistry) {
            version = registry.version
            accounts = registry.accounts.map {
                Account(id: $0.id, provider: $0.provider, label: $0.label, legacy: $0.legacy)
            }
            routing = registry.routing
        }
    }

    /// Preserve only the typed quota fields in the authoritative CLI contract.
    private static func safeQuotaDetail(_ detail: DistillAccountQuota.Detail?) -> DistillAccountQuota.Detail? {
        guard let detail else { return nil }
        switch detail {
        case .object(let fields):
            let allowed: Set<String> = ["rate_limit", "additional_rate_limits", "primary_window", "secondary_window",
                "allowed", "limit_reached", "used_percent", "limit_window_seconds", "reset_after_seconds", "reset_at",
                "five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "utilization", "resets_at",
                "usage", "limit", "limit_remaining", "credit_usage_percent"]
            return .object(fields.filter { allowed.contains($0.key) }.compactMapValues(safeQuotaDetail))
        case .array(let values): return .array(values.compactMap { safeQuotaDetail($0) })
        case .string(let value):
            return DistillHostCredentialRefresher.parseDate(value) == nil ? nil : .string(value)
        case .number, .bool, .null: return detail
        }
    }

    /// Accounts this run may use. Distill remains the routing/eligibility authority.
    public static func accountsForRun(model: String?, hostConfig: String, hostHome: URL) throws -> [DistillAccountStatus] {
        if model?.trimmingCharacters(in: .whitespacesAndNewlines) == "auto" {
            return try DistillAccounts.autoRoutingAccounts(home: hostHome)
        }
        _ = try DistillAccounts.readRegistry(home: hostHome)
        let connected = DistillAccounts.connectedAccounts(home: hostHome).filter(\.connected)
        guard let provider = accountProvider(model: model, hostConfig: hostConfig) else { return [] }
        let accounts = connected.filter { $0.provider == provider }
        // Preserve the legacy preflight error when no managed account exists.
        return accounts.isEmpty ? [DistillAccountStatus(provider: provider, connected: false)] : accounts
    }

    /// Deletes every credential copy (and Distill's locks, temp and corrupt
    /// backups of them) from a guest `DISTILL_HOME`. Missing directory: no-op.
    public static func removeCopies(guestDistillHome: URL) throws {
        let directory: PrivateDirectory
        do {
            directory = try PrivateDirectory(guestDistillHome, create: false)
        } catch DistillGuestCredentialError.writeFailed(_, let code) where code == ENOENT {
            return
        }
        defer { directory.close() }
        directory.remove("accounts.json")
        directory.remove("accounts.json.lock")
        directory.removeTree("accounts")
        let names = DistillAccountProvider.allCases.map(\.credentialFileName)
        for entry in directory.entries() where entry.hasPrefix(temporaryPrefix)
            || names.contains(where: { entry == $0 || entry.hasPrefix($0 + ".") }) {
            directory.remove(entry)
        }
    }

    /// App launch: no guest run survives a quit, so no bot keeps a copy.
    public static func removeAllCopies(guestHomeRoot: URL) {
        let bots = (try? FileManager.default.contentsOfDirectory(atPath: guestHomeRoot.path)) ?? []
        for bot in bots {
            let home = guestHomeRoot.appendingPathComponent(bot, isDirectory: true)
                .appendingPathComponent("home", isDirectory: true)
            do {
                try removeCopies(guestDistillHome: distillHome(guestHome: home))
            } catch {
                guestCredentialLog.error("bot.guest.credentials.cleanup_failed bot=\(bot, privacy: .public)")
            }
        }
    }

    // MARK: - Which sign-in a model needs

    /// The Distill account a model is served with, or nil when it uses an API
    /// key or a provider this app does not manage. A nil/empty model is the
    /// host config's `[models] default`.
    public static func accountProvider(model: String?, hostConfig: String) -> DistillAccountProvider? {
        var id = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { id = DistillGuestConfig.defaultModel(hostConfig: hostConfig) ?? "" }
        let lowered = id.lowercased()
        // Distill's own catalog prefixes (claude_models.rs, codex_models.rs).
        if lowered.hasPrefix("claude/") || lowered.hasPrefix("anthropic/") { return .claude }
        if lowered.hasPrefix("chatgpt/") { return .chatgpt }
        if let endpoint = DistillGuestConfig.modelEndpoint(id: id, hostConfig: hostConfig) {
            guard !endpoint.hasOwnKey, let base = endpoint.baseURL?.lowercased() else { return nil }
            // codex_auth.rs is_codex_backend / claude_auth.rs is_claude_backend.
            if base.hasPrefix("https://chatgpt.com/backend-api") { return .chatgpt }
            if let url = URL(string: base), url.scheme == "https", url.host == "api.anthropic.com" { return .claude }
            return nil
        }
        if lowered.hasPrefix("grok") { return .grok }
        return nil
    }
}

/// Keeps the guest copies of every live guest run fresh while it runs: a Mac
/// Distill process (or the pre-run refresh) renewing a token rewrites
/// `~/.distill/*.json` by rename, which changes the directory and re-syncs
/// every registered guest home after a short debounce. A run can outlive its
/// access token (Claude 8 h, Grok 6 h) with no Mac Distill renewing it, so
/// every `refreshInterval` the mirror also asks `refresh` to renew the
/// providers live runs use (a no-op unless the token is inside the refresh
/// window), then the other signed-in ones their role models may use
/// (`DistillHostCredentialRefresher.otherSignIns`, best effort), and re-syncs.
/// The copies of a guest home are deleted when its last run ends.
public final class DistillGuestCredentialMirror: @unchecked Sendable {
    /// Renews the Mac sign-in of one provider when it is close to expiry;
    /// production passes `DistillHostCredentialRefresher.prepare(provider:)`.
    public typealias Refresh = @Sendable (DistillAccountProvider) async throws -> Void
    public typealias AccountRefresh = @Sendable (DistillAccountStatus) async throws -> Void
    /// A periodic renewal failed: these runs keep copies that stop working
    /// when their access token expires. Called on the mirror's queue.
    public typealias RefreshFailure = @Sendable (_ runIDs: [String], _ error: Error) -> Void

    private struct Run {
        var home: URL
        var provider: DistillAccountProvider?
        var accounts: [DistillAccountStatus]?
    }

    private let hostHome: URL
    private let refresh: Refresh
    private let refreshAccount: AccountRefresh?
    private let onRefreshFailure: RefreshFailure?
    private let debounce: TimeInterval
    private let refreshInterval: TimeInterval
    // Every mutable member below is touched only on this queue.
    private let queue = DispatchQueue(label: "io.remotecode.distill.guest-credentials")
    private var runs: [String: Run] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var accountSources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var refreshing = false

    public init(
        hostHome: URL,
        refresh: @escaping Refresh,
        refreshAccount: AccountRefresh? = nil,
        onRefreshFailure: RefreshFailure? = nil,
        debounce: TimeInterval = 0.5,
        refreshInterval: TimeInterval = 5 * 60
    ) {
        self.hostHome = hostHome
        self.refresh = refresh
        self.refreshAccount = refreshAccount
        self.onRefreshFailure = onRefreshFailure
        self.debounce = debounce
        self.refreshInterval = refreshInterval
    }

    deinit {
        source?.cancel()
        accountSources.forEach { $0.cancel() }
        timer?.cancel()
    }

    /// Copies the sign-ins into `guestDistillHome` now (the pre-run sync) and
    /// keeps them fresh until `end(runID:)`. `provider` is the account the
    /// run's model is served with (nil for an API key): the one renewed
    /// periodically. On a throw nothing is registered and no copy this call
    /// wrote is left behind.
    @discardableResult
    public func begin(
        runID: String, guestDistillHome: URL, provider: DistillAccountProvider?, accounts: [DistillAccountStatus]? = nil
    ) throws -> DistillGuestCredentials.SyncResult {
        try queue.sync {
            let home = guestDistillHome.standardizedFileURL
            do {
                // Watch before the initial copy so changes during that copy are observed.
                if source == nil { try startWatching() }
                let result = try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: home)
                runs[runID] = Run(home: home, provider: provider, accounts: accounts?.isEmpty == true ? nil : accounts)
                watchAccounts()
                if timer == nil { startTimer() }
                return result
            } catch {
                if !runs.values.contains(where: { $0.home == home }) { removeCopies(home, runID: runID) }
                if runs.isEmpty { stopAll() }
                throw error
            }
        }
    }

    public func resynchronize(runID: String) throws -> Bool {
        try queue.sync {
            guard let run = runs[runID] else { return false }
            _ = try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: run.home)
            return true
        }
    }

    public func end(runID: String) {
        queue.sync {
            guard let run = runs.removeValue(forKey: runID) else { return }
            if !runs.values.contains(where: { $0.home == run.home }) { removeCopies(run.home, runID: runID) }
            if runs.isEmpty { stopAll() }
        }
    }

    /// App quit: ends every run at once, deleting their copies and stopping
    /// the watcher and renewals so nothing re-copies a sign-in afterwards.
    public func endAll() {
        queue.sync {
            for home in Set(runs.values.map(\.home)) {
                removeCopies(home, runID: "app_termination")
            }
            runs = [:]
            stopAll()
        }
    }

    private func removeCopies(_ home: URL, runID: String) {
        do {
            try DistillGuestCredentials.removeCopies(guestDistillHome: home)
        } catch {
            guestCredentialLog.error("bot.guest.credentials.cleanup_failed run=\(runID, privacy: .public)")
        }
    }

    private func stopAll() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        accountSources.forEach { $0.cancel() }
        accountSources = []
        timer?.cancel()
        timer = nil
    }

    /// Throws when `~/.distill` exists but cannot be watched. A missing one
    /// (no sign-in at all) is retried on every refresh tick.
    private func startWatching() throws {
        let descriptor = open(hostHome.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            guestCredentialLog.error("bot.guest.credentials.watch_failed errno=\(code, privacy: .public)")
            if code == ENOENT { return }
            throw DistillGuestCredentialError.watchFailed(path: hostHome.path, errno: code)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            // The directory itself was replaced: watch the new one.
            if !source.data.isDisjoint(with: [.rename, .delete]) {
                source.cancel()
                self.source = nil
                try? self.startWatching()
            }
            self.scheduleResync()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    /// Directory watches catch nested atomic credential replacements, including new/deleted accounts.
    private func watchAccounts() {
        accountSources.forEach { $0.cancel() }
        accountSources = []
        guard let root = try? PrivateDirectory(hostHome.resolvingSymlinksInPath(), create: false) else { return }
        defer { root.close() }
        guard let accounts = try? root.child("accounts", create: false) else { return }
        defer { accounts.close() }
        func watch(_ directory: PrivateDirectory) {
            let fd = dup(directory.descriptor)
            guard fd >= 0 else { return }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .rename, .delete], queue: queue)
            watcher.setEventHandler { [weak self] in self?.scheduleResync() }
            watcher.setCancelHandler { close(fd) }
            accountSources.append(watcher)
            watcher.resume()
        }
        watch(accounts)
        for id in accounts.entries() where DistillAccounts.validID(id) {
            guard let child = try? accounts.child(id, create: false) else { continue }
            watch(child)
            child.close()
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        timer.setEventHandler { [weak self] in self?.refreshTick() }
        self.timer = timer
        timer.resume()
    }

    private func refreshTick() {
        if source == nil { try? startWatching() }
        guard !refreshing else { return }
        refreshing = true
        let connected = DistillAccounts.connectedAccounts(home: hostHome).filter(\.connected)
        let routing = (try? DistillAccounts.readRegistry(home: hostHome))?.routing
        let autoIDs = Set(routing?.enabled == true ? routing?.options.map(\.accountID) ?? [] : [])
        for id in Array(runs.keys) {
            guard var run = runs[id], run.accounts != nil else { continue }
            run.accounts = connected.filter { account in
                run.provider.map { account.provider == $0 } ?? autoIDs.contains(account.id)
            }
            runs[id] = run
        }
        let providers = DistillAccountProvider.allCases.filter { provider in
            runs.values.contains { $0.accounts == nil && $0.provider == provider }
        }
        let refresh = self.refresh
        let refreshAccount = self.refreshAccount
        let accounts = Dictionary(runs.values.flatMap { $0.accounts ?? [] }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let others = DistillHostCredentialRefresher.otherSignIns(
            hostHome: hostHome,
            excluding: Set(runs.values.compactMap(\.provider) + accounts.values.map(\.provider)))
        Task { [weak self] in
            var failures: [(DistillAccountProvider, Error)] = []
            for provider in providers {
                do { try await refresh(provider) } catch { failures.append((provider, error)) }
            }
            var accountFailures: [(String, Error)] = []
            if let refreshAccount {
                for account in accounts.values {
                    do { try await refreshAccount(account) } catch { accountFailures.append((account.id, error)) }
                }
            }
            // Best effort: no live run's own sign-in, so no run is told.
            for provider in others {
                do { try await refresh(provider) } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    guestCredentialLog.error(
                        "bot.guest.credentials.other_refresh_failed provider=\(provider.rawValue, privacy: .public) error=\(reason, privacy: .public)")
                }
            }
            guard let self else { return }
            self.queue.async { self.finishRefresh(failures, accountFailures: accountFailures) }
        }
    }

    private func finishRefresh(_ failures: [(DistillAccountProvider, Error)], accountFailures: [(String, Error)]) {
        refreshing = false
        for (provider, error) in failures {
            let affected = runs.filter { $0.value.provider == provider }.map(\.key).sorted()
            guard !affected.isEmpty else { continue }
            guestCredentialLog.error(
                "bot.guest.credentials.refresh_failed provider=\(provider.rawValue, privacy: .public) runs=\(affected.count, privacy: .public)")
            onRefreshFailure?(affected, error)
        }
        for (id, error) in accountFailures {
            let affected = runs.filter { ($0.value.accounts ?? []).contains { $0.id == id } }.map(\.key).sorted()
            if !affected.isEmpty { onRefreshFailure?(affected, error) }
        }
        // Also covers a renewal the watcher missed.
        resyncAll()
    }

    private func scheduleResync() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.resyncAll() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func resyncAll() {
        watchAccounts()
        pending = nil
        for home in Set(runs.values.map(\.home)) {
            do {
                try DistillGuestCredentials.sync(hostHome: hostHome, guestDistillHome: home)
            } catch {
                guestCredentialLog.error("bot.guest.credentials.resync_failed")
            }
        }
    }
}

/// A directory opened with `O_NOFOLLOW`; all access is relative to it. For
/// any directory the guest owns (it lives on the guest-home bind): the guest
/// can swap it for a symlink to a Mac directory at any moment, and a write or
/// delete by path would then land in that Mac directory.
public struct PrivateDirectory {
    let path: String
    let descriptor: Int32

    /// `create`: make it (0700) when missing. Throws `unsafeDirectory` when
    /// the last component is a symlink or not a directory.
    public init(_ url: URL, create: Bool) throws {
        path = url.path
        var fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT, create {
            if mkdir(path, 0o700) != 0, errno != EEXIST {
                throw DistillGuestCredentialError.writeFailed(path: path, errno: errno)
            }
            fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR { throw DistillGuestCredentialError.unsafeDirectory(path: path) }
            throw DistillGuestCredentialError.writeFailed(path: path, errno: code)
        }
        if create, fchmod(fd, 0o700) != 0 {
            let code = errno
            Darwin.close(fd)
            throw DistillGuestCredentialError.writeFailed(path: path, errno: code)
        }
        descriptor = fd
    }

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    /// Nested managed paths must be opened relative to the already trusted parent.
    public func child(_ name: String, create: Bool) throws -> PrivateDirectory {
        guard name != ".", name != "..", !name.contains("/"), !name.isEmpty else {
            throw DistillGuestCredentialError.unsafeDirectory(path: path)
        }
        var fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT, create {
            if mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST {
                throw DistillGuestCredentialError.writeFailed(path: "\(path)/\(name)", errno: errno)
            }
            fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw DistillGuestCredentialError.unsafeDirectory(path: "\(path)/\(name)")
            }
            throw DistillGuestCredentialError.writeFailed(path: "\(path)/\(name)", errno: errno)
        }
        if create, fchmod(fd, 0o700) != 0 {
            let code = errno
            Darwin.close(fd)
            throw DistillGuestCredentialError.writeFailed(path: "\(path)/\(name)", errno: code)
        }
        return PrivateDirectory(path: "\(path)/\(name)", descriptor: fd)
    }

    /// Removes a managed child; symlinks are unlinked, never traversed.
    public func removeTree(_ name: String) {
        guard name != ".", name != "..", !name.contains("/"), !name.isEmpty else { return }
        if let directory = try? child(name, create: false) {
            for entry in directory.entries() { directory.removeTree(entry) }
            directory.close()
            unlinkat(descriptor, name, AT_REMOVEDIR)
        } else { remove(name) }
    }

    public func close() { Darwin.close(descriptor) }

    public func synchronize() throws {
        guard fsync(descriptor) == 0 else {
            throw DistillGuestCredentialError.writeFailed(path: path, errno: errno)
        }
    }

    /// Far above any credential file; a bigger one is treated as differing.
    static let readLimit = 1 << 20

    /// Nil when missing, unreadable, larger than `readLimit` or not a regular
    /// file (a symlink included). The guest owns this directory: a FIFO there
    /// would block a plain open and a sparse 64 GiB file would be read whole.
    public func read(_ name: String) -> Data? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= Self.readLimit else { return nil }
        return try? handle.read(upToCount: Int(info.st_size)) ?? Data()
    }

    /// Temp file at 0600 + rename, so a reader sees the old file or the whole
    /// new one. Durable state is synced first; ephemeral leases need only
    /// visibility to readers and must not wait for a disk flush.
    public func writeAtomically(_ data: Data, to name: String, synchronize: Bool = true) throws {
        let temp = "\(DistillGuestCredentials.temporaryPrefix)\(UUID().uuidString).tmp"
        let fd = openat(descriptor, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DistillGuestCredentialError.writeFailed(path: "\(path)/\(name)", errno: errno) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0, synchronize, fsync(fd) != 0 { failure = errno }
        Darwin.close(fd)
        if failure == 0, renameat(descriptor, temp, descriptor, name) != 0 {
            failure = errno
            // An empty directory in the way is removed; a non-empty one fails.
            if failure == EISDIR, unlinkat(descriptor, name, AT_REMOVEDIR) == 0,
               renameat(descriptor, temp, descriptor, name) == 0 {
                failure = 0
            }
        }
        if failure != 0 {
            unlinkat(descriptor, temp, 0)
            throw DistillGuestCredentialError.writeFailed(path: "\(path)/\(name)", errno: failure)
        }
    }

    @discardableResult
    public func remove(_ name: String) -> Bool {
        unlinkat(descriptor, name, 0) == 0
    }

    public func entriesChecked() throws -> [String] {
        let fd = dup(descriptor)
        guard fd >= 0 else { throw DistillGuestCredentialError.writeFailed(path: path, errno: errno) }
        guard let stream = fdopendir(fd) else {
            let code = errno
            Darwin.close(fd)
            throw DistillGuestCredentialError.writeFailed(path: path, errno: code)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        let code = errno
        guard code == 0 else { throw DistillGuestCredentialError.writeFailed(path: path, errno: code) }
        return names
    }

    public func entries() -> [String] { (try? entriesChecked()) ?? [] }
}
