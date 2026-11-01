import Foundation

public enum DistillAccountProvider: String, CaseIterable, Codable, Sendable {
    case grok, chatgpt, claude, openrouter

    public var displayName: String {
        switch self {
        case .grok: return "Grok"
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .openrouter: return "OpenRouter"
        }
    }

    public var legacyID: String { "legacy-\(rawValue)" }

    var cliLoginArguments: [String]? {
        switch self {
        case .grok: return ["login"]
        case .chatgpt: return ["login", "--chatgpt"]
        case .claude: return ["login", "--claude"]
        case .openrouter: return ["accounts", "login", legacyID]
        }
    }

    var credentialFileName: String {
        switch self {
        case .grok: return "auth.json"
        case .chatgpt: return "codex-auth.json"
        case .claude: return "claude-auth.json"
        case .openrouter: return "openrouter-auth.json"
        }
    }
}

public struct DistillAccountStatus: Equatable, Codable, Sendable {
    public let id: String
    public let provider: DistillAccountProvider
    public let label: String
    public let legacy: Bool
    public let connected: Bool
    public let email: String?
    public let connectionError: String?
    public let quota: DistillAccountQuota?

    public init(provider: DistillAccountProvider, connected: Bool, email: String? = nil,
                id: String? = nil, label: String? = nil, legacy: Bool = true,
                connectionError: String? = nil, quota: DistillAccountQuota? = nil) {
        self.id = id ?? provider.legacyID
        self.provider = provider
        self.label = label ?? provider.displayName
        self.legacy = legacy
        self.connected = connected
        self.email = email
        self.connectionError = connectionError
        self.quota = quota
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, label, legacy, connected, email, quota
        case connectionError = "connection_error"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(DistillAccountProvider.self, forKey: .provider)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? provider.legacyID
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? provider.displayName
        legacy = try c.decodeIfPresent(Bool.self, forKey: .legacy) ?? true
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        email = try c.decodeIfPresent(String.self, forKey: .email)
        connectionError = try c.decodeIfPresent(String.self, forKey: .connectionError)
        quota = try c.decodeIfPresent(DistillAccountQuota.self, forKey: .quota)
    }
}

public struct DistillAccountQuota: Equatable, Codable, Sendable {
    public let accountID: String
    public let checkedAt: String
    public let fetchedAt: String?
    public let status: String
    public let remainingPercent: Double?
    public let detail: Detail?

    public init(accountID: String, checkedAt: String, fetchedAt: String? = nil, status: String,
                remainingPercent: Double? = nil, detail: Detail? = nil) {
        self.accountID = accountID
        self.checkedAt = checkedAt
        self.fetchedAt = fetchedAt
        self.status = status
        self.remainingPercent = remainingPercent
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id", checkedAt = "checked_at", fetchedAt = "fetched_at"
        case status, remainingPercent = "remaining_percent", detail
    }

    public indirect enum Detail: Equatable, Codable, Sendable {
        case object([String: Detail]), array([Detail]), string(String), number(Double), bool(Bool), null

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let value = try? c.decode(Bool.self) { self = .bool(value) }
            else if let value = try? c.decode(Double.self) { self = .number(value) }
            else if let value = try? c.decode(String.self) { self = .string(value) }
            else if let value = try? c.decode([Detail].self) { self = .array(value) }
            else { self = .object(try c.decode([String: Detail].self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .object(let value): try c.encode(value)
            case .array(let value): try c.encode(value)
            case .string(let value): try c.encode(value)
            case .number(let value): try c.encode(value)
            case .bool(let value): try c.encode(value)
            case .null: try c.encodeNil()
            }
        }
    }
}

public enum DistillAutoRoutingError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    case disabled, missingOptions, noConnectedAccounts

    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .disabled: return "Auto routing is off. Open Auto profile, enable it, and save before running Auto."
        case .missingOptions: return "Auto routing has no saved options. Open Auto profile, add an option, and save before running Auto."
        case .noConnectedAccounts: return "Auto routing has no connected account eligible for its saved options. Connect an account in Auto profile before running Auto."
        }
    }
}

public enum DistillAutoStrategy: String, CaseIterable, Codable, Sendable {
    case orderedFirst = "ordered_first", highestRemaining = "highest_remaining"
}

public struct DistillAutoOption: Equatable, Codable, Sendable {
    public var id: String
    public var accountID: String
    public var mainModel: String
    public var workerModel: String?

    public init(id: String, accountID: String, mainModel: String, workerModel: String? = nil) {
        self.id = id; self.accountID = accountID; self.mainModel = mainModel; self.workerModel = workerModel
    }

    enum CodingKeys: String, CodingKey {
        case id, accountID = "account_id", mainModel = "main_model", workerModel = "worker_model"
    }
}

public struct DistillAutoRouting: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var strategy: DistillAutoStrategy
    public var options: [DistillAutoOption]

    public init(enabled: Bool = false, strategy: DistillAutoStrategy = .orderedFirst, options: [DistillAutoOption] = []) {
        self.enabled = enabled; self.strategy = strategy; self.options = options
    }
}

public struct DistillAccountsState: Equatable, Sendable {
    public let accounts: [DistillAccountStatus]
    public let routing: DistillAutoRouting

    public init(accounts: [DistillAccountStatus], routing: DistillAutoRouting) {
        self.accounts = accounts; self.routing = routing
    }
}

/// The disk shape is metadata only; credentials are read separately by descriptor.
struct DistillAccountRegistry: Codable {
    var version: Int
    var accounts: [DistillAccountStatus]
    var routing: DistillAutoRouting
}

public enum DistillAccountError: Error, Equatable, LocalizedError {
    case updateRequired
    case cancelled
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .updateRequired: return "Update Distill to use named accounts and Auto routing."
        case .cancelled: return "Sign-in was cancelled."
        case .timedOut: return "Sign-in timed out. Please try again."
        case .failed(let message): return message
        }
    }
}

/// Safe account metadata and operations; Distill CLI owns registry and credential mutations.
public final class DistillAccounts: Sendable {
    /// Status code and body of a host OAuth renewal POST.
    public typealias HTTPPost = @Sendable (_ url: URL, _ jsonBody: Data) async throws -> (data: Data, status: Int)

    private let home: URL
    private let binaryPath: String
    private let environment: [String: String]

    public init(home: URL, binaryPath: String, environment: [String: String],
                openURL: @escaping @Sendable (URL) -> Void) {
        self.home = home
        self.binaryPath = binaryPath
        self.environment = environment
    }

    // MARK: Status

    public func statuses() -> [DistillAccountStatus] {
        Self.connectedAccounts(home: home)
    }

    static func validID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        return (1...64).contains(bytes.count) && bytes.first.map(alphanumeric) == true
            && bytes.allSatisfy { alphanumeric($0) || $0 == 95 || $0 == 45 }
    }

    static func readRegistry(home: URL) throws -> DistillAccountRegistry? {
        let directory: PrivateDirectory
        do { directory = try PrivateDirectory(home.resolvingSymlinksInPath(), create: false) }
        catch DistillGuestCredentialError.writeFailed(_, let code) where code == ENOENT { return nil }
        defer { directory.close() }
        guard directory.entries().contains("accounts.json") else { return nil }
        guard let data = directory.read("accounts.json"),
              let registry = try? JSONDecoder().decode(DistillAccountRegistry.self, from: data),
              registry.version == 1,
              Set(registry.accounts.map(\.id)).count == registry.accounts.count,
              registry.accounts.allSatisfy({ validID($0.id) && ($0.legacy
                  ? $0.id == $0.provider.legacyID : !$0.id.hasPrefix("legacy-")) }) else {
            throw DistillAccountError.failed("Distill account metadata cannot be read safely.")
        }
        return registry
    }

    public static func autoRoutingAccounts(home: URL) throws -> [DistillAccountStatus] {
        guard let registry = try readRegistry(home: home), registry.routing.enabled else {
            throw DistillAutoRoutingError.disabled
        }
        guard !registry.routing.options.isEmpty else { throw DistillAutoRoutingError.missingOptions }
        let eligibleIDs = Set(registry.routing.options.map(\.accountID))
        let eligible = connectedAccounts(home: home).filter { eligibleIDs.contains($0.id) && $0.connected }
        guard !eligible.isEmpty else { throw DistillAutoRoutingError.noConnectedAccounts }
        return eligible
    }

    public static func connectedAccounts(home: URL) -> [DistillAccountStatus] {
        let legacy = DistillAccountProvider.allCases.map { DistillAccountStatus(provider: $0, connected: false) }
        let registry: DistillAccountRegistry?
        do { registry = try readRegistry(home: home) } catch { return legacy }
        return (registry?.accounts ?? legacy).map { account in
            let details = accountDetails(account, home: home)
            return DistillAccountStatus(provider: account.provider, connected: details.connected, email: details.email,
                id: account.id, label: account.label, legacy: account.legacy)
        }
    }

    /// No named account is ever substituted for a legacy provider entry point.
    public static func credentialHome(account: DistillAccountStatus, home: URL) throws -> URL {
        guard validID(account.id), account.legacy ? account.id == account.provider.legacyID : !account.id.hasPrefix("legacy-") else {
            throw DistillAccountError.failed("Invalid Distill account id.")
        }
        if account.legacy { return home }
        let directory = try PrivateDirectory(home.resolvingSymlinksInPath(), create: false)
        defer { directory.close() }
        let accounts = try directory.child("accounts", create: false)
        defer { accounts.close() }
        let child = try accounts.child(account.id, create: false)
        defer { child.close() }
        return URL(fileURLWithPath: child.path, isDirectory: true)
    }

    private static func accountDetails(_ account: DistillAccountStatus, home: URL) -> (connected: Bool, email: String?) {
        let provider = account.provider
        guard let childHome = try? credentialHome(account: account, home: home),
              let directory = try? PrivateDirectory(childHome, create: false) else { return (false, nil) }
        defer { directory.close() }
        guard let data = directory.read(provider.credentialFileName),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (false, nil) }
        func nonEmpty(_ value: Any?) -> Bool {
            guard let text = value as? String else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch provider {
        case .chatgpt:
            return (nonEmpty((root["tokens"] as? [String: Any])?["access_token"]), nil)
        case .claude:
            let connected = nonEmpty(root["access_token"])
            let email = (root["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (connected, email?.isEmpty == false ? email : nil)
        case .openrouter:
            return (nonEmpty(root["key"]), nil)
        case .grok:
            // Scoped map of OAuth sessions; the `xai::api_key` scope is a plain API key, not an account sign-in.
            let oauth = root.sorted { $0.key < $1.key }.first { scope, value in
                scope != "xai::api_key" && nonEmpty((value as? [String: Any])?["key"])
            }
            let email = ((oauth?.value as? [String: Any])?["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (oauth != nil, email?.isEmpty == false ? email : nil)
        }
    }

    public func loadState() async throws -> DistillAccountsState {
        let accounts: [DistillAccountStatus] = try await jsonCLI(["accounts", "list"])
        let routing = try await loadRouting()
        return DistillAccountsState(accounts: accounts, routing: routing)
    }

    public func loadRouting() async throws -> DistillAutoRouting {
        try await jsonCLI(["accounts", "routing", "get"])
    }

    public func add(id: String, provider: DistillAccountProvider, label: String) async throws {
        let _: DistillAccountStatus = try await jsonCLI(["accounts", "add", id, "--provider", provider.rawValue, "--label", label])
    }

    public func rename(id: String, label: String) async throws {
        let _: DistillAccountStatus = try await jsonCLI(["accounts", "rename", id, "--label", label])
    }

    private struct MutationResult: Decodable { let ok: Bool }

    private func mutate(_ arguments: [String], onURL: (@Sendable (URL) -> Void)? = nil) async throws {
        let result: MutationResult = try await jsonCLI(arguments, onURL: onURL)
        guard result.ok else { throw DistillAccountError.failed("Distill did not confirm the account operation.") }
    }

    public func remove(id: String) async throws { try await mutate(["accounts", "remove", id]) }
    public func login(id: String, onURL: @escaping @Sendable (URL) -> Void) async throws {
        try await mutate(["accounts", "login", id], onURL: onURL)
    }
    public func logout(id: String) async throws { try await mutate(["accounts", "logout", id]) }
    public func refreshUsage(id: String) async throws -> DistillAccountQuota {
        try await jsonCLI(["accounts", "usage", id])
    }
    public func saveRouting(_ routing: DistillAutoRouting) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("distill-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("routing.json")
        let privateDirectory = try PrivateDirectory(directory, create: false)
        defer { privateDirectory.close() }
        try privateDirectory.writeAtomically(JSONEncoder().encode(routing), to: "routing.json")
        let saved: DistillAutoRouting = try await jsonCLI(["accounts", "routing", "set", "--file", file.path])
        guard saved == routing else { throw DistillAccountError.failed("Distill did not confirm the saved Auto routing.") }
    }

    public func login(_ provider: DistillAccountProvider, onURL: @escaping @Sendable (URL) -> Void) async throws {
        try await login(id: provider.legacyID, onURL: onURL)
    }
    public func logout(_ provider: DistillAccountProvider) async throws { try await logout(id: provider.legacyID) }

    private func jsonCLI<T: Decodable>(_ arguments: [String], onURL: (@Sendable (URL) -> Void)? = nil) async throws -> T {
        let data = try await runCLI(arguments, onURL: onURL)
        guard let value = try? JSONDecoder().decode(T.self, from: data) else {
            // An old CLI fails on stderr (runCLI); exit 0 with unreadable JSON means a wrong binary.
            throw DistillAccountError.failed("\(binaryPath) returned an unreadable account response. Check the Distill path in Settings.")
        }
        return value
    }

    // MARK: CLI child

    private func runCLI(
        _ arguments: [String],
        onURL: (@Sendable (URL) -> Void)?
    ) async throws -> Data {
        if Task.isCancelled { throw DistillAccountError.cancelled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        var env = environment
        env["DISTILL_HOME"] = home.path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe
        let output = CLIOutput()
        let errPipe = Pipe()
        process.standardError = errPipe

        let collector = StderrCollector(onURL: onURL)
        let eofGroup = DispatchGroup()
        eofGroup.enter()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finish()
                eofGroup.leave()
            } else {
                collector.append(data)
            }
        }

        eofGroup.enter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                eofGroup.leave()
            } else { output.append(data) }
        }

        let exit = OneShot<Int32>()
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            // A grandchild may keep stderr open; do not wait for EOF forever.
            DispatchQueue.global().async {
                _ = eofGroup.wait(timeout: .now() + 1)
                exit.finish(.success(status))
            }
        }

        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            outPipe.fileHandleForReading.readabilityHandler = nil
            throw DistillAccountError.failed("Could not start distill: \(error.localizedDescription)")
        }

        let status = try await withTaskCancellationHandler {
            try await exit.wait()
        } onCancel: {
            Self.terminate(process)
        }

        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        if Task.isCancelled { throw DistillAccountError.cancelled }
        guard status == 0 else {
            let message = collector.lastLine ?? "distill exited with status \(status)"
            if collector.requiresUpdate {
                throw DistillAccountError.updateRequired
            }
            throw DistillAccountError.failed(message)
        }
        guard let data = output.data else { throw DistillAccountError.failed("Distill account response exceeded its size limit.") }
        return data
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    @Sendable
    public static func urlSessionPost(url: URL, body: Data) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Single-result rendezvous that tolerates finish-before-wait.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func finish(_ value: Result<T, Error>) {
        let pending: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: value)
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<T, Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// Splits child stderr into lines; reports the first https URL and remembers the last non-empty line.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onURL: (@Sendable (URL) -> Void)?
    private var pending = ""
    private var urlSent = false
    private var last: String?
    private var unsupportedCLI = false

    init(onURL: (@Sendable (URL) -> Void)?) { self.onURL = onURL }

    var lastLine: String? { lock.withLock { last } }
    var requiresUpdate: Bool { lock.withLock { unsupportedCLI } }

    func append(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending += String(decoding: data, as: UTF8.self)
            var out: [String] = []
            while let newline = pending.firstIndex(of: "\n") {
                out.append(String(pending[..<newline]))
                pending = String(pending[pending.index(after: newline)...])
            }
            return out
        }
        lines.forEach(handle)
    }

    func finish() {
        let rest: String = lock.withLock {
            defer { pending = "" }
            return pending
        }
        handle(rest)
    }

    private func handle(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let found: URL? = lock.withLock {
            last = line
            if line.contains("unrecognized subcommand") || line.contains("unexpected argument") {
                unsupportedCLI = true
            }
            guard !urlSent, let range = line.range(of: "https://") else { return nil }
            let token = line[range.lowerBound...].prefix { !$0.isWhitespace }
            guard let url = URL(string: String(token)) else { return nil }
            urlSent = true
            return url
        }
        if let found { onURL?(found) }
    }
}

private final class CLIOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    func append(_ data: Data) {
        lock.withLock {
            guard !overflow, bytes.count + data.count <= 2 * 1024 * 1024 else { overflow = true; return }
            bytes.append(data)
        }
    }
    var data: Data? { lock.withLock { overflow ? nil : bytes } }
}

/// Session (short window) and weekly limit used, read from one account's quota.
/// Claude reports `five_hour` / `seven_day`; ChatGPT reports rate-limit windows
/// by length; anything else falls back to `100 - remaining_percent` as weekly.
public struct DistillAccountUsage: Equatable, Sendable {
    public var sessionUsedPercent: Double?
    public var sessionResetsAt: Date?
    public var weeklyUsedPercent: Double?
    public var weeklyResetsAt: Date?

    public init(sessionUsedPercent: Double? = nil, sessionResetsAt: Date? = nil,
                weeklyUsedPercent: Double? = nil, weeklyResetsAt: Date? = nil) {
        self.sessionUsedPercent = sessionUsedPercent.map(Self.clamp)
        self.sessionResetsAt = sessionResetsAt
        self.weeklyUsedPercent = weeklyUsedPercent.map(Self.clamp)
        self.weeklyResetsAt = weeklyResetsAt
    }

    /// The most-used window determines availability; either limit can block use.
    public var ringPercent: Double? { [sessionUsedPercent, weeklyUsedPercent].compactMap { $0 }.max() }

    public init?(quota: DistillAccountQuota?) {
        guard let quota else { return nil }
        var usage = DistillAccountUsage()
        if case .object(let detail)? = quota.detail {
            if case .object(let five)? = detail["five_hour"] {
                usage.sessionUsedPercent = Self.number(five["utilization"]).map(Self.clamp)
                usage.sessionResetsAt = Self.date(five["resets_at"])
            }
            if case .object(let week)? = detail["seven_day"] {
                usage.weeklyUsedPercent = Self.number(week["utilization"]).map(Self.clamp)
                usage.weeklyResetsAt = Self.date(week["resets_at"])
            }
            if case .object(let limit)? = detail["rate_limit"] {
                for key in ["primary_window", "secondary_window"] {
                    guard case .object(let window)? = limit[key], let used = Self.number(window["used_percent"]) else { continue }
                    let reset = Self.number(window["reset_at"]).map(Date.init(timeIntervalSince1970:))
                    if (Self.number(window["limit_window_seconds"]) ?? 0) >= 86_400 {
                        usage.weeklyUsedPercent = Self.clamp(used); usage.weeklyResetsAt = reset
                    } else {
                        usage.sessionUsedPercent = Self.clamp(used); usage.sessionResetsAt = reset
                    }
                }
            }
        }
        if usage.sessionUsedPercent == nil, usage.weeklyUsedPercent == nil,
           let remaining = quota.remainingPercent, remaining.isFinite {
            usage.weeklyUsedPercent = Self.clamp(100 - remaining)
        }
        guard usage.ringPercent != nil else { return nil }
        self = usage
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 100) }

    private static func number(_ value: DistillAccountQuota.Detail?) -> Double? {
        if case .number(let n)? = value, n.isFinite { return n }
        return nil
    }

    private static func date(_ value: DistillAccountQuota.Detail?) -> Date? {
        guard case .string(let raw)? = value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
