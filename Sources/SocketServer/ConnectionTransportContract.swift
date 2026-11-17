import Foundation
import CryptoKit
import Persistence
import RemoteCodeTreaty

public struct ConnectionDomainRevisions: Codable, Equatable, Sendable {
    public let shell: Int64
    public let surfaces: Int64
    public let agentThreads: Int64
    public let browser: Int64
    public let files: Int64

    public init(shell: Int64, surfaces: Int64, agentThreads: Int64, browser: Int64, files: Int64) {
        self.shell = shell
        self.surfaces = surfaces
        self.agentThreads = agentThreads
        self.browser = browser
        self.files = files
    }

    public static let zero = ConnectionDomainRevisions(
        shell: 0, surfaces: 0, agentThreads: 0, browser: 0, files: 0
    )

    var jsonValue: JSONValue {
        .object([
            "shell": .number(Double(shell)),
            "surfaces": .number(Double(surfaces)),
            "agentThreads": .number(Double(agentThreads)),
            "browser": .number(Double(browser)),
            "files": .number(Double(files)),
        ])
    }

    /// Domains whose host revision is strictly ahead of `known` (Wave 4 incremental).
    public func domainsChanged(since known: ConnectionDomainRevisions) -> Set<String> {
        var out = Set<String>()
        if shell > known.shell { out.insert("shell") }
        if surfaces > known.surfaces { out.insert("surfaces") }
        if agentThreads > known.agentThreads { out.insert("agentThreads") }
        if browser > known.browser { out.insert("browser") }
        if files > known.files { out.insert("files") }
        return out
    }

    public static func parse(_ any: Any?) -> ConnectionDomainRevisions? {
        guard let object = any as? [String: Any] else { return nil }
        func rev(_ key: String) -> Int64? {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number) else { return nil }
            return Int64(truncating: number)
        }
        guard let shell = rev("shell"),
              let surfaces = rev("surfaces"),
              let agentThreads = rev("agentThreads"),
              let browser = rev("browser"),
              let files = rev("files") else { return nil }
        return ConnectionDomainRevisions(
            shell: shell,
            surfaces: surfaces,
            agentThreads: agentThreads,
            browser: browser,
            files: files
        )
    }

    static let domainNames = ["shell", "surfaces", "agentThreads", "browser", "files"]

    func revision(of domain: String) -> Int64 {
        switch domain {
        case "shell": return shell
        case "surfaces": return surfaces
        case "agentThreads": return agentThreads
        case "browser": return browser
        default: return files
        }
    }

    init(byDomain: [String: Int64]) {
        self.init(
            shell: byDomain["shell"] ?? 0,
            surfaces: byDomain["surfaces"] ?? 0,
            agentThreads: byDomain["agentThreads"] ?? 0,
            browser: byDomain["browser"] ?? 0,
            files: byDomain["files"] ?? 0
        )
    }
}

/// Durable `domainRevisions`, advertised on welcome as `capability`.
///
/// EventBus revisions are event seqs, and seqs restart from the event log on
/// each boot (live-only events are never logged), so after a Mac restart a
/// revision a client already holds can be reused or lowered. Clients therefore
/// dropped `knownDomainRevisions` on every new boot and downloaded everything.
/// This ledger serves wire revisions from one persisted counter instead:
/// - Within a boot a domain keeps its wire revision until its EventBus
///   revision moves; it then takes the next counter value, which is above
///   every wire revision any boot served.
/// - The counter is reserved in blocks and persisted before a value in the
///   block is served, so even a crash never lets a later boot reuse one.
/// - A clean quit (`seal`) keeps each domain that did not change after its
///   revision was served, with a digest of its snapshot content. The next
///   boot keeps that revision only when the previous quit was clean, no event
///   touched the domain since boot, and the content digest still matches.
///   Anything else (crash, change, digest mismatch) gets a new revision.
public final class ConnectionDurableDomainRevisions: @unchecked Sendable {
    public static let capability = "snapshot.domain_revisions.durable_v1"
    public static let settingsKey = "connection.domain_revisions.durable.v1"
    static let reservationBlock: Int64 = 1_024
    /// Builds before this ledger served EventBus seqs as revisions, and a crash
    /// could have served seqs above the logged head. One jump past the head on
    /// first use puts every durable revision above any of them.
    static let legacyRevisionJump: Int64 = 1 << 32

    struct Sealed: Codable, Equatable {
        let revision: Int64
        let digest: String
    }

    struct Stored: Codable, Equatable {
        let bootEpoch: UInt64
        /// Every wire revision ever served is at or below this.
        let ceiling: Int64
        /// Written only by a clean quit.
        let sealed: [String: Sealed]?
    }

    private struct Live {
        let revision: Int64
        /// Normalized EventBus revision the wire revision stands for.
        let mark: Int64
        var digest: String?
        /// Content to digest if the background digest has not run yet.
        var pendingState: ConnectionSnapshotReadState?
    }

    private let lock = NSLock()
    private let bootEpoch: UInt64
    /// EventBus seq at install. Revisions at or below it were not published by
    /// a live event of this boot, so they normalize to 0 ("unchanged since boot").
    private let bootFloor: Int64
    private let save: (String) throws -> Void
    private var lastServed: Int64
    private var reserved: Int64
    private var candidates: [String: Sealed]
    private var live: [String: Live] = [:]
    private var sealedOnDisk = false

    /// Fails when the boot record cannot be persisted; callers then keep the
    /// EventBus revisions and do not advertise `capability`.
    init(
        bootEpoch: UInt64,
        bootFloor: Int64,
        previousBootClean: Bool,
        load: () throws -> String?,
        save: @escaping (String) throws -> Void
    ) throws {
        let stored = (try? load())
            .flatMap { $0?.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        self.bootEpoch = bootEpoch
        self.bootFloor = bootFloor
        self.save = save
        lastServed = stored?.ceiling ?? max(0, bootFloor) + Self.legacyRevisionJump
        if previousBootClean, let stored, stored.bootEpoch &+ 1 == bootEpoch {
            candidates = stored.sealed ?? [:]
        } else {
            candidates = [:]
        }
        reserved = lastServed
        // Unsealed until this boot quits cleanly: a crash keeps nothing.
        try persist(ceiling: lastServed + Self.reservationBlock, sealed: nil)
    }

    /// Production install after the event log and C8 resume record are loaded.
    public static func install(
        settings: SettingsRepository,
        bootEpoch: UInt64,
        eventBus: EventBus,
        previousBootClean: Bool
    ) -> ConnectionDurableDomainRevisions? {
        do {
            return try ConnectionDurableDomainRevisions(
                bootEpoch: bootEpoch,
                bootFloor: eventBus.currentSeq,
                previousBootClean: previousBootClean,
                load: { try settings.get(settingsKey) },
                save: { try settings.set(settingsKey, $0) }
            )
        } catch {
            NSLog("[RC2.Snapshot] durable domain revisions disabled: %@", String(describing: error))
            return nil
        }
    }

    /// Wire revisions for one snapshot read. Throws only when a new counter
    /// block cannot be persisted: serving it could later be reused.
    func resolve(
        bus: ConnectionDomainRevisions,
        state: ConnectionSnapshotReadState
    ) throws -> ConnectionDomainRevisions {
        let marks = Dictionary(uniqueKeysWithValues: ConnectionDomainRevisions.domainNames.map {
            ($0, normalized(bus.revision(of: $0)))
        })
        // Candidate digests are computed outside the lock (once per boot).
        lock.lock()
        let toVerify = candidates.keys.filter { live[$0] == nil && marks[$0] == 0 }
        lock.unlock()
        let digests = Dictionary(uniqueKeysWithValues: toVerify.map { ($0, Self.digest(of: state, domain: $0)) })

        lock.lock()
        defer { lock.unlock() }
        var wire: [String: Int64] = [:]
        var minted: [(domain: String, revision: Int64)] = []
        for domain in ConnectionDomainRevisions.domainNames {
            let mark = marks[domain] ?? 0
            if let entry = live[domain], entry.mark == mark {
                wire[domain] = entry.revision
                continue
            }
            if live[domain] == nil, mark == 0, let carried = candidates[domain],
               let digest = digests[domain] ?? nil, digest == carried.digest {
                live[domain] = Live(revision: carried.revision, mark: 0, digest: digest)
                wire[domain] = carried.revision
                continue
            }
            if lastServed + 1 > reserved {
                try persist(ceiling: lastServed + Self.reservationBlock, sealed: nil)
            } else if sealedOnDisk {
                try persist(ceiling: reserved, sealed: nil)
            }
            lastServed += 1
            live[domain] = Live(revision: lastServed, mark: mark, digest: nil, pendingState: state)
            wire[domain] = lastServed
            minted.append((domain, lastServed))
        }
        if !minted.isEmpty {
            // Digests matter only to the next boot: keep them off the response path.
            Task.detached(priority: .utility) { [weak self] in
                for (domain, revision) in minted {
                    let digest = Self.digest(of: state, domain: domain)
                    self?.recordDigest(digest, domain: domain, revision: revision)
                }
            }
        }
        return ConnectionDomainRevisions(byDomain: wire)
    }

    /// Call on a clean quit after the C8 resume record is written. Keeps each
    /// domain whose EventBus revision did not move since its wire revision was
    /// served (or, if never served this boot, since boot).
    public func seal(bus: ConnectionDomainRevisions) {
        lock.lock()
        defer { lock.unlock() }
        var sealed: [String: Sealed] = [:]
        for domain in ConnectionDomainRevisions.domainNames {
            let mark = normalized(bus.revision(of: domain))
            if let entry = live[domain] {
                guard entry.mark == mark,
                      let digest = entry.digest
                        ?? entry.pendingState.flatMap({ Self.digest(of: $0, domain: domain) }) else { continue }
                sealed[domain] = Sealed(revision: entry.revision, digest: digest)
            } else if mark == 0, let carried = candidates[domain] {
                sealed[domain] = carried
            }
        }
        do {
            try persist(ceiling: reserved, sealed: sealed)
        } catch {
            NSLog("[RC2.Snapshot] durable domain revisions seal failed: %@", String(describing: error))
        }
    }

    private func recordDigest(_ digest: String?, domain: String, revision: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = live[domain], entry.revision == revision else { return }
        entry.digest = digest
        entry.pendingState = nil
        live[domain] = entry
    }

    private func normalized(_ busRevision: Int64) -> Int64 {
        busRevision > bootFloor ? busRevision : 0
    }

    /// Caller holds `lock` (or is the initializer). `reserved` moves only
    /// after the write succeeded.
    private func persist(ceiling: Int64, sealed: [String: Sealed]?) throws {
        let data = try JSONEncoder().encode(Stored(bootEpoch: bootEpoch, ceiling: ceiling, sealed: sealed))
        try save(String(decoding: data, as: UTF8.self))
        reserved = ceiling
        sealedOnDisk = sealed != nil
    }

    static func digest(of state: ConnectionSnapshotReadState, domain: String) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state.domainContent(domain)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ConnectionSnapshotWorkspaceItems: Equatable, Sendable {
    public let workspaceId: String
    public let items: [JSONValue]
    /// Set only on a bounded agent-thread group (`ConnectionSnapshotThreadWindow`):
    /// how many threads the workspace has in total. Emitted with `truncated`.
    public let totalCount: Int?

    public init(workspaceId: String, items: [JSONValue], totalCount: Int? = nil) {
        self.workspaceId = workspaceId
        self.items = items
        self.totalCount = totalCount
    }

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "workspaceId": .string(workspaceId),
            "items": .array(items),
        ]
        if let totalCount {
            object["totalCount"] = .number(Double(totalCount))
            object["truncated"] = .bool(items.count < totalCount)
        }
        return .object(object)
    }
}

/// Opt-in bounded agent-thread list for `sync.snapshot` and
/// `sync.snapshot.begin`. A client that sees `capability` on welcome may send
/// `parameter` (an integer >= 1). Each workspace then carries its pending and
/// running threads, its pinned threads, the threads its surfaces select, and
/// the `parameter` most recently updated others. Every thread group gains
/// `totalCount` and `truncated`; a truncated workspace's full list comes from
/// `agent.thread.list` with its `workspace_id`. Without the parameter the
/// snapshot keeps every thread (old clients).
public enum ConnectionSnapshotThreadWindow {
    public static let capability = "snapshot.agent_threads.window.v1"
    public static let parameter = "agentThreadsRecentPerWorkspace"
    /// Larger requests are clamped to this.
    public static let maximumRecentPerWorkspace = 500
    static let activeStatuses: Set<String> = ["pending", "running"]

    /// Strict parse: a non-boolean integer >= 1, clamped to the maximum.
    static func parse(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        let value = Int64(truncating: number)
        guard value >= 1 else { return nil }
        return Int(min(value, Int64(maximumRecentPerWorkspace)))
    }
}

public struct ConnectionSnapshotSurfaceState: Equatable, Sendable {
    public let workspaceId: String
    public let surfaceId: String
    public let state: JSONValue

    public init(workspaceId: String, surfaceId: String, state: JSONValue) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.state = state
    }

    var jsonValue: JSONValue {
        .object([
            "workspaceId": .string(workspaceId),
            "surfaceId": .string(surfaceId),
            "state": state,
        ])
    }
}

public struct ConnectionSnapshotReadState: Equatable, Sendable {
    public let selectedWorkspaceId: String?
    public let workspaces: [JSONValue]
    public let surfaces: [ConnectionSnapshotWorkspaceItems]
    public let agentThreads: [ConnectionSnapshotWorkspaceItems]
    public let browserStates: [ConnectionSnapshotSurfaceState]
    public let filesStates: [ConnectionSnapshotSurfaceState]

    public init(
        selectedWorkspaceId: String?,
        workspaces: [JSONValue],
        surfaces: [ConnectionSnapshotWorkspaceItems],
        agentThreads: [ConnectionSnapshotWorkspaceItems],
        browserStates: [ConnectionSnapshotSurfaceState],
        filesStates: [ConnectionSnapshotSurfaceState]
    ) {
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaces = workspaces
        self.surfaces = surfaces
        self.agentThreads = agentThreads
        self.browserStates = browserStates
        self.filesStates = filesStates
    }

    func jsonValue(domainRevisions: ConnectionDomainRevisions) -> JSONValue {
        jsonValue(domainRevisions: domainRevisions, includeDomains: nil)
    }

    /// One domain's snapshot content (unbounded), for durable revision digests.
    func domainContent(_ domain: String) -> JSONValue {
        switch domain {
        case "shell":
            return .object([
                "selectedWorkspaceId": selectedWorkspaceId.map(JSONValue.string) ?? .null,
                "workspaces": .array(workspaces),
            ])
        case "surfaces": return .array(surfaces.map(\.jsonValue))
        case "agentThreads": return .array(agentThreads.map(\.jsonValue))
        case "browser": return .array(browserStates.map(\.jsonValue))
        default: return .array(filesStates.map(\.jsonValue))
        }
    }

    /// Applies `ConnectionSnapshotThreadWindow` to every agent-thread group.
    /// Kept rows stay in their original order; surfaces are untouched, so a
    /// surface's `selected_thread` always names a row that is present.
    func boundingAgentThreads(recentPerWorkspace: Int) -> ConnectionSnapshotReadState {
        var selectedByWorkspace: [String: Set<String>] = [:]
        for group in surfaces {
            for item in group.items {
                guard let selected = item.objectValue?["metadata"]?.objectValue?["selected_thread"]?.stringValue,
                      !selected.isEmpty else { continue }
                selectedByWorkspace[group.workspaceId, default: []].insert(selected)
            }
        }
        let bounded = agentThreads.map { group -> ConnectionSnapshotWorkspaceItems in
            let selected = selectedByWorkspace[group.workspaceId] ?? []
            var keep = Set<Int>()
            var others: [(index: Int, updatedAt: Double)] = []
            for (index, item) in group.items.enumerated() {
                let row = item.objectValue ?? [:]
                let status = row["status"]?.stringValue ?? ""
                let id = row["id"]?.stringValue ?? ""
                if ConnectionSnapshotThreadWindow.activeStatuses.contains(status)
                    || row["pinned"]?.boolValue == true
                    || selected.contains(id) {
                    keep.insert(index)
                } else {
                    let updatedAt: Double
                    if case .number(let value)? = row["updatedAt"] { updatedAt = value } else { updatedAt = -.infinity }
                    others.append((index, updatedAt))
                }
            }
            others.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.index < $1.index }
            keep.formUnion(others.prefix(max(0, recentPerWorkspace)).map(\.index))
            let items = group.items.indices.filter(keep.contains).map { group.items[$0] }
            return ConnectionSnapshotWorkspaceItems(
                workspaceId: group.workspaceId,
                items: items,
                totalCount: group.items.count
            )
        }
        return ConnectionSnapshotReadState(
            selectedWorkspaceId: selectedWorkspaceId,
            workspaces: workspaces,
            surfaces: surfaces,
            agentThreads: bounded,
            browserStates: browserStates,
            filesStates: filesStates
        )
    }

    /// Wave 4: when `includeDomains` is non-nil, only those domains are emitted
    /// (plus `domainRevisions` / `partial` / `includedDomains` metadata).
    /// `nil` means full snapshot (backward compatible exact key set).
    func jsonValue(
        domainRevisions: ConnectionDomainRevisions,
        includeDomains: Set<String>?
    ) -> JSONValue {
        let all: Set<String> = ["shell", "surfaces", "agentThreads", "browser", "files"]
        let include = includeDomains ?? all
        let partial = includeDomains != nil && include != all

        if !partial {
            return .object([
                "selectedWorkspaceId": selectedWorkspaceId.map(JSONValue.string) ?? .null,
                "workspaces": .array(workspaces),
                "surfaces": .array(surfaces.map(\.jsonValue)),
                "agentThreads": .array(agentThreads.map(\.jsonValue)),
                "browserStates": .array(browserStates.map(\.jsonValue)),
                "filesStates": .array(filesStates.map(\.jsonValue)),
                "domainRevisions": domainRevisions.jsonValue,
            ])
        }

        var object: [String: JSONValue] = [
            "partial": .bool(true),
            "includedDomains": .array(include.sorted().map(JSONValue.string)),
            "domainRevisions": domainRevisions.jsonValue,
        ]
        if include.contains("shell") {
            object["selectedWorkspaceId"] = selectedWorkspaceId.map(JSONValue.string) ?? .null
            object["workspaces"] = .array(workspaces)
        }
        if include.contains("surfaces") {
            object["surfaces"] = .array(surfaces.map(\.jsonValue))
        }
        if include.contains("agentThreads") {
            object["agentThreads"] = .array(agentThreads.map(\.jsonValue))
        }
        if include.contains("browser") {
            object["browserStates"] = .array(browserStates.map(\.jsonValue))
        }
        if include.contains("files") {
            object["filesStates"] = .array(filesStates.map(\.jsonValue))
        }
        return .object(object)
    }
}

@MainActor
public protocol ConnectionSnapshotRouting: AnyObject {
    /// Capture host layout/surface state for `sync.snapshot`.
    ///
    /// AgentThread SQLite list/decode must hop off MainActor (see
    /// `AgentThreadListGateway`). Surface/browser capture remains MainActor-safe.
    func readConnectionSnapshotState() async throws -> ConnectionSnapshotReadState
}

enum ConnectionProtocolFailure: Error, Equatable, CustomStringConvertible {
    case frameTooLarge
    case malformedJSON
    case unsupportedVersion
    case unknownType
    case unknownFields
    case invalidFrame

    var description: String {
        switch self {
        case .frameTooLarge: return "frame_too_large"
        case .malformedJSON: return "malformed_json"
        case .unsupportedVersion: return "unsupported_version"
        case .unknownType: return "unknown_type"
        case .unknownFields: return "unknown_fields"
        case .invalidFrame: return "invalid_frame"
        }
    }
}

struct ConnectionWelcomeFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let serverTimeEpochMs: Int64
    let heartbeatIntervalMs: Int64
    let heartbeatTimeoutMs: Int64
    /// Progress-idle budget for snapshot transfer (ms). Independent of heartbeat (C-03).
    let snapshotTimeoutMs: Int64
    let currentSequence: Int64
    let oldestReplaySequence: Int64
    let capabilities: [String]
    /// C-W: present only when the client opted in with
    /// `X-RC2-Welcome-Fields: identity.v1` (see `ConnectionWelcomeIdentity`).
    /// Both are omitted, never null, on the default shape so clients that
    /// decode welcome with an exact key set keep working.
    var apiVersion: String? = nil
    var capabilitiesDigest: String? = nil
    /// C8: present only on durable-replay sockets (see `DurableReplayContract`).
    var replayFromSequence: Int64? = nil
    /// F7: the bus head read in the lock hold that subscribed this socket.
    /// Present only on a durable-replay socket that listed `resume.head.v1`
    /// and whose cursor this boot accepted as sent (see
    /// `DurableReplayContract.welcomeHeadSequence`). Omitted, never null.
    var headSequence: Int64? = nil
}

/// C-W: opt-in welcome fields that let a pinned client validate a reconnect
/// from the welcome alone. `hostId` and `bootEpoch` are on every welcome;
/// with the extension the welcome also carries `apiVersion` and
/// `capabilitiesDigest`, which equals `capabilities_digest` on
/// `GET /v1/capabilities/authenticated` while that response's `treaty` and
/// `capabilities` are unchanged. The digest is opaque: compare it, never parse it.
/// Old clients never send the header, so they keep the exact pre-C-W welcome.
enum ConnectionWelcomeIdentity {
    static let header = "x-rc2-welcome-fields"
    static let extensionName = "identity.v1"
    static let keys: Set<String> = ["apiVersion", "capabilitiesDigest"]

    /// True when the comma-separated header lists `identity.v1`.
    static func isRequested(header value: String?) -> Bool {
        guard let value else { return false }
        return value.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == extensionName
        }
    }

    static func isValidDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

/// Opt-in client features (`X-RC2-Client-Features`, comma separated).
enum ConnectionClientFeatures {
    static let header = "x-rc2-client-features"
    /// F7: capability name in the welcome and opt-in token in this header.
    static let resumeHead = "resume.head.v1"
    static let headSequenceWelcomeKey = "headSequence"

    /// True when the comma-separated header lists `resume.head.v1`.
    static func requestsResumeHead(header value: String?) -> Bool {
        guard let value else { return false }
        return value.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == resumeHead
        }
    }
}

struct ConnectionHeartbeatFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let sentAtEpochMs: Int64
    let lastReceivedSequence: Int64
    let nonce: String
}

struct ConnectionClosingFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let code: Int
    let reason: String
    let retryable: Bool
    let retryAfterMs: Int64?

    enum CodingKeys: String, CodingKey {
        case protocolVersion, type, connectionId, hostId, bootEpoch
        case code, reason, retryable, retryAfterMs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(type, forKey: .type)
        try container.encode(connectionId, forKey: .connectionId)
        try container.encode(hostId, forKey: .hostId)
        try container.encode(bootEpoch, forKey: .bootEpoch)
        try container.encode(code, forKey: .code)
        try container.encode(reason, forKey: .reason)
        try container.encode(retryable, forKey: .retryable)
        if let retryAfterMs {
            try container.encode(retryAfterMs, forKey: .retryAfterMs)
        } else {
            try container.encodeNil(forKey: .retryAfterMs)
        }
    }
}

struct ConnectionErrorFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let code: String
    let message: String
    let retryable: Bool
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion, type, connectionId, hostId, bootEpoch
        case code, message, retryable, requestId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(type, forKey: .type)
        try container.encode(connectionId, forKey: .connectionId)
        try container.encode(hostId, forKey: .hostId)
        try container.encode(bootEpoch, forKey: .bootEpoch)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(retryable, forKey: .retryable)
        if let requestId {
            try container.encode(requestId, forKey: .requestId)
        } else {
            try container.encodeNil(forKey: .requestId)
        }
    }
}

struct ConnectionEventFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let sequence: Int64
    let eventId: String
    let occurredAtEpochMs: Int64
    let kind: String
    let payload: JSONValue

    /// Exact encoded size without allocating/serializing the frame. JSON key
    /// order does not affect byte length.
    var encodedByteCount: Int {
        let values: [(String, Int)] = [
            ("protocolVersion", EventBus.jsonInt64ByteCount(Int64(protocolVersion))),
            ("type", EventBus.jsonStringByteCount(type)),
            ("connectionId", EventBus.jsonStringByteCount(connectionId)),
            ("hostId", EventBus.jsonStringByteCount(hostId)),
            ("bootEpoch", String(bootEpoch).utf8.count),
            ("sequence", EventBus.jsonInt64ByteCount(sequence)),
            ("eventId", EventBus.jsonStringByteCount(eventId)),
            ("occurredAtEpochMs", EventBus.jsonInt64ByteCount(occurredAtEpochMs)),
            ("kind", EventBus.jsonStringByteCount(kind)),
            ("payload", EventBus.jsonValueByteCount(payload)),
        ]
        return 2 + max(0, values.count - 1) + values.reduce(0) { count, field in
            count + EventBus.jsonStringByteCount(field.0) + 1 + field.1
        }
    }
}

/// Typed metadata carried from EventBus through transforms, batching and queue
/// pressure. Conversion to `ConnectionEventFrame` happens only at the final
/// socket write, so known event JSON is never parsed to recover metadata.
struct KnownConnectionEventFrame: Equatable, Sendable {
    let event: EventBus.KnownEvent
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64

    var wireFrame: ConnectionEventFrame {
        ConnectionEventFrame(
            protocolVersion: ConnectionTransportFrame.protocolVersion,
            type: "event",
            connectionId: connectionId,
            hostId: hostId,
            bootEpoch: bootEpoch,
            sequence: event.seq,
            eventId: "\(bootEpoch):\(event.seq)",
            occurredAtEpochMs: Int64(event.ts * 1_000),
            kind: event.kind.rawValue,
            payload: .object(event.payload)
        )
    }

    var encodedByteCount: Int { wireFrame.encodedByteCount }

    func replacingPayload(_ payload: [String: JSONValue]) -> KnownConnectionEventFrame {
        KnownConnectionEventFrame(
            event: EventBus.KnownEvent(
                seq: event.seq,
                kind: event.kind,
                payload: payload,
                ts: event.ts
            ),
            connectionId: connectionId,
            hostId: hostId,
            bootEpoch: bootEpoch
        )
    }

    func encoded() throws -> Data {
        try ConnectionTransportFrame.event(wireFrame).encoded()
    }
}

struct ConnectionBaselineRequiredFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let reason: String
    let requestedAfterSequence: Int64
    let currentSequence: Int64
    let snapshotMethod: String
}

struct ConnectionSnapshotFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let sequence: Int64
    let snapshotId: String
    let generatedAtEpochMs: Int64
    let stateVersion: Int
    let state: JSONValue
}

enum ConnectionTransportFrame: Equatable, Sendable {
    static let protocolVersion = 3
    static let maximumEncodedBytes = 1_048_576
    private static let dottedNameExpression = try! NSRegularExpression(
        pattern: #"[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+"#
    )
    // PERF: WS heartbeats/events and client frames encode/decode continuously.
    // Reuse codecs under a short lock (JSONEncoder/JSONDecoder are not thread-safe).
    private static let codecLock = NSLock()
    private static let sharedEncoder = JSONEncoder()
    private static let sharedDecoder = JSONDecoder()

    case welcome(ConnectionWelcomeFrame)
    case heartbeat(ConnectionHeartbeatFrame)
    case closing(ConnectionClosingFrame)
    case error(ConnectionErrorFrame)
    case event(ConnectionEventFrame)
    case baselineRequired(ConnectionBaselineRequiredFrame)
    case snapshot(ConnectionSnapshotFrame)
    /// C8: durable-replay sockets only.
    case streamGap(ConnectionStreamGapFrame)
    case replayComplete(ConnectionReplayCompleteFrame)

    func encoded() throws -> Data {
        Self.codecLock.lock()
        defer { Self.codecLock.unlock() }
        let data: Data
        switch self {
        case .welcome(let frame): try Self.validate(frame); data = try Self.sharedEncoder.encode(frame)
        case .heartbeat(let frame): try Self.validate(frame); data = try Self.sharedEncoder.encode(frame)
        case .closing(let frame): try Self.validate(frame); data = try Self.sharedEncoder.encode(frame)
        case .error(let frame): try Self.validate(frame); data = try Self.sharedEncoder.encode(frame)
        case .event(let frame): try Self.validate(frame); data = try Self.sharedEncoder.encode(frame)
        case .baselineRequired(let frame): try Self.validate(frame); data = try Self.sharedEncoder.encode(frame)
        case .snapshot(let frame): try Self.validate(frame); data = try Self.sharedEncoder.encode(frame)
        case .streamGap(let frame): try Self.validate(frame); data = try Self.sharedEncoder.encode(frame)
        case .replayComplete(let frame): try Self.validate(frame); data = try Self.sharedEncoder.encode(frame)
        }
        guard data.count <= Self.maximumEncodedBytes else {
            throw ConnectionProtocolFailure.frameTooLarge
        }
        return data
    }

    static func decodeStrict(_ data: Data) throws -> ConnectionTransportFrame {
        guard data.count <= maximumEncodedBytes else {
            throw ConnectionProtocolFailure.frameTooLarge
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConnectionProtocolFailure.malformedJSON
        }
        guard let object = value as? [String: Any] else {
            throw ConnectionProtocolFailure.invalidFrame
        }
        guard let version = object["protocolVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == Double(protocolVersion) else {
            throw ConnectionProtocolFailure.unsupportedVersion
        }
        guard let type = object["type"] as? String else {
            throw ConnectionProtocolFailure.invalidFrame
        }

        var allowedKeys: Set<String>
        switch type {
        case "welcome":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "serverTimeEpochMs", "heartbeatIntervalMs", "heartbeatTimeoutMs",
                "snapshotTimeoutMs",
                "currentSequence", "oldestReplaySequence", "capabilities",
            ]
            if !ConnectionWelcomeIdentity.keys.isDisjoint(with: object.keys) {
                allowedKeys = allowedKeys.union(ConnectionWelcomeIdentity.keys)
            }
            if object[DurableReplayContract.welcomeKey] != nil {
                allowedKeys.insert(DurableReplayContract.welcomeKey)
            }
            if object[ConnectionClientFeatures.headSequenceWelcomeKey] != nil {
                allowedKeys.insert(ConnectionClientFeatures.headSequenceWelcomeKey)
            }
        case "heartbeat":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "sentAtEpochMs", "lastReceivedSequence", "nonce",
            ]
        case "closing":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "code", "reason", "retryable", "retryAfterMs",
            ]
        case "error":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "code", "message", "retryable", "requestId",
            ]
        case "event":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "sequence", "eventId", "occurredAtEpochMs", "kind", "payload",
            ]
        case "baselineRequired":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "reason", "requestedAfterSequence", "currentSequence", "snapshotMethod",
            ]
        case "snapshot":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "sequence", "snapshotId", "generatedAtEpochMs", "stateVersion", "state",
            ]
        case "streamGap":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "sinceSequence", "throughSequence",
            ]
            if object["threadId"] != nil { allowedKeys.insert("threadId") }
            if object["surfaceId"] != nil { allowedKeys.insert("surfaceId") }
        case "replayComplete":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "throughSequence",
            ]
        default:
            throw ConnectionProtocolFailure.unknownType
        }
        guard Set(object.keys) == allowedKeys else {
            throw ConnectionProtocolFailure.unknownFields
        }
        guard hasStrictIntegerFields(object, type: type) else {
            throw ConnectionProtocolFailure.invalidFrame
        }
        if type == "snapshot", !hasStrictSnapshotRevisionFields(object) {
            throw ConnectionProtocolFailure.invalidFrame
        }

        codecLock.lock()
        defer { codecLock.unlock() }
        do {
            switch type {
            case "welcome":
                let frame = try sharedDecoder.decode(ConnectionWelcomeFrame.self, from: data)
                try validate(frame)
                return .welcome(frame)
            case "heartbeat":
                let frame = try sharedDecoder.decode(ConnectionHeartbeatFrame.self, from: data)
                try validate(frame)
                return .heartbeat(frame)
            case "closing":
                let frame = try sharedDecoder.decode(ConnectionClosingFrame.self, from: data)
                try validate(frame)
                return .closing(frame)
            case "error":
                let frame = try sharedDecoder.decode(ConnectionErrorFrame.self, from: data)
                try validate(frame)
                return .error(frame)
            case "event":
                let frame = try sharedDecoder.decode(ConnectionEventFrame.self, from: data)
                try validate(frame)
                return .event(frame)
            case "baselineRequired":
                let frame = try sharedDecoder.decode(ConnectionBaselineRequiredFrame.self, from: data)
                try validate(frame)
                return .baselineRequired(frame)
            case "snapshot":
                let frame = try sharedDecoder.decode(ConnectionSnapshotFrame.self, from: data)
                try validate(frame)
                return .snapshot(frame)
            case "streamGap":
                let frame = try sharedDecoder.decode(ConnectionStreamGapFrame.self, from: data)
                try validate(frame)
                return .streamGap(frame)
            case "replayComplete":
                let frame = try sharedDecoder.decode(ConnectionReplayCompleteFrame.self, from: data)
                try validate(frame)
                return .replayComplete(frame)
            default: throw ConnectionProtocolFailure.unknownType
            }
        } catch let failure as ConnectionProtocolFailure {
            throw failure
        } catch {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validateCommon(
        protocolVersion: Int,
        type: String,
        expectedType: String,
        connectionId: String,
        hostId: String,
        bootEpoch: UInt64
    ) throws {
        guard protocolVersion == self.protocolVersion,
              type == expectedType,
              isNonEmpty(connectionId),
              isNonEmpty(hostId) else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func hasStrictIntegerFields(_ object: [String: Any], type: String) -> Bool {
        let requiredKeys: [String]
        switch type {
        case "welcome":
            requiredKeys = [
                "bootEpoch", "serverTimeEpochMs", "heartbeatIntervalMs",
                "heartbeatTimeoutMs", "snapshotTimeoutMs",
                "currentSequence", "oldestReplaySequence",
            ] + (object[DurableReplayContract.welcomeKey] != nil
                ? [DurableReplayContract.welcomeKey] : [])
            + (object[ConnectionClientFeatures.headSequenceWelcomeKey] != nil
                ? [ConnectionClientFeatures.headSequenceWelcomeKey] : [])
        case "heartbeat":
            requiredKeys = ["bootEpoch", "sentAtEpochMs", "lastReceivedSequence"]
        case "closing":
            requiredKeys = ["bootEpoch", "code"]
        case "error":
            requiredKeys = ["bootEpoch"]
        case "event":
            requiredKeys = ["bootEpoch", "sequence", "occurredAtEpochMs"]
        case "baselineRequired":
            requiredKeys = ["bootEpoch", "requestedAfterSequence", "currentSequence"]
        case "snapshot":
            requiredKeys = ["bootEpoch", "sequence", "generatedAtEpochMs", "stateVersion"]
        case "streamGap":
            requiredKeys = ["bootEpoch", "sinceSequence", "throughSequence"]
        case "replayComplete":
            requiredKeys = ["bootEpoch", "throughSequence"]
        default:
            return false
        }
        guard requiredKeys.allSatisfy({ isStrictInteger(object[$0]) }) else { return false }
        if type == "closing", !(object["retryAfterMs"] is NSNull) {
            return isStrictInteger(object["retryAfterMs"])
        }
        return true
    }

    private static func isStrictInteger(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return false
        }
        return !CFNumberIsFloatType(number)
    }

    private static func hasStrictSnapshotRevisionFields(_ object: [String: Any]) -> Bool {
        guard let state = object["state"] as? [String: Any],
              let revisions = state["domainRevisions"] as? [String: Any],
              Set(revisions.keys) == ["shell", "surfaces", "agentThreads", "browser", "files"] else {
            return false
        }
        return revisions.values.allSatisfy(isStrictInteger)
    }

    private static func validate(_ frame: ConnectionWelcomeFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "welcome",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        // C-06: welcome may advertise Wi-Fi (10s/30s) or cellular (25s/90s) profiles.
        // C-03: snapshotTimeoutMs is an independent progress-idle transfer budget.
        guard frame.serverTimeEpochMs >= 0,
              (1...25_000).contains(frame.heartbeatIntervalMs),
              frame.heartbeatTimeoutMs > frame.heartbeatIntervalMs,
              frame.heartbeatTimeoutMs <= 90_000,
              (5_000...60_000).contains(frame.snapshotTimeoutMs),
              frame.currentSequence >= 0,
              frame.oldestReplaySequence >= 0,
              frame.oldestReplaySequence <= frame.currentSequence,
              !frame.capabilities.isEmpty,
              Set(frame.capabilities).count == frame.capabilities.count else {
            throw ConnectionProtocolFailure.invalidFrame
        }
        if let replayFrom = frame.replayFromSequence,
           !(0...frame.currentSequence).contains(replayFrom) {
            throw ConnectionProtocolFailure.invalidFrame
        }
        // F7: the head is the sequence this welcome is anchored on, and only
        // a durable socket with a real cursor is told it.
        if let head = frame.headSequence {
            guard head == frame.currentSequence,
                  let replayFrom = frame.replayFromSequence, replayFrom > 0 else {
                throw ConnectionProtocolFailure.invalidFrame
            }
        }
        // C-W: the identity extension is all-or-nothing.
        switch (frame.apiVersion, frame.capabilitiesDigest) {
        case (nil, nil):
            break
        case let (apiVersion?, digest?)
            where isNonEmpty(apiVersion) && ConnectionWelcomeIdentity.isValidDigest(digest):
            break
        default:
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionHeartbeatFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "heartbeat",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard frame.sentAtEpochMs >= 0,
              frame.lastReceivedSequence >= 0,
              isNonEmpty(frame.nonce) else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionClosingFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "closing",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        let reservedCodes: Set<Int> = [1004, 1005, 1006, 1015]
        guard (1000...4999).contains(frame.code),
              !reservedCodes.contains(frame.code),
              isNonEmpty(frame.reason),
              frame.retryAfterMs.map({ $0 >= 0 }) ?? true else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionErrorFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "error",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard isNonEmpty(frame.code),
              isNonEmpty(frame.message),
              frame.requestId.map(isNonEmpty) ?? true else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionEventFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "event",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard frame.sequence > 0,
              isNonEmpty(frame.eventId),
              frame.occurredAtEpochMs >= 0,
              isDotted(frame.kind),
              case .object = frame.payload else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionBaselineRequiredFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "baselineRequired",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        let allowedReasons: Set<String> = [
            "eventGap", "hostReset", "replayTruncated", "snapshotRejected",
        ]
        guard allowedReasons.contains(frame.reason),
              frame.requestedAfterSequence >= 0,
              frame.currentSequence >= frame.requestedAfterSequence,
              frame.snapshotMethod == "sync.snapshot" else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionStreamGapFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "streamGap",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        let streamIDs = [frame.threadId, frame.surfaceId].compactMap { $0 }
        guard streamIDs.count == 1,
              streamIDs.allSatisfy(isNonEmpty),
              frame.sinceSequence >= 0,
              frame.throughSequence > frame.sinceSequence else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionReplayCompleteFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "replayComplete",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard frame.throughSequence >= 0 else { throw ConnectionProtocolFailure.invalidFrame }
    }

    private static func validate(_ frame: ConnectionSnapshotFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "snapshot",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard frame.sequence >= 0,
              isNonEmpty(frame.snapshotId),
              frame.generatedAtEpochMs >= 0,
              frame.stateVersion == 3,
              isValidSnapshotState(frame.state) else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func isNonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isDotted(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return dottedNameExpression.firstMatch(in: value, range: range)?.range == range
    }

    private static func isValidSnapshotState(_ value: JSONValue) -> Bool {
        guard case .object(let state) = value else { return false }
        // Wave 4 partial snapshots: subset of domains + metadata.
        if case .bool(true)? = state["partial"] {
            return isValidPartialSnapshotState(state)
        }
        guard Set(state.keys) == [
                  "selectedWorkspaceId", "workspaces", "surfaces", "agentThreads",
                  "browserStates", "filesStates", "domainRevisions",
              ] else {
            return false
        }
        switch state["selectedWorkspaceId"] {
        case .null?: break
        case .string(let value)?: guard isNonEmpty(value) else { return false }
        default: return false
        }
        for key in ["workspaces", "surfaces", "agentThreads", "browserStates", "filesStates"] {
            guard case .array? = state[key] else { return false }
        }
        guard case .array(let workspaceValues)? = state["workspaces"] else { return false }
        let workspaceIDs = workspaceValues.compactMap { item -> String? in
            guard case .object(let object) = item else { return nil }
            return object["id"]?.stringValue
        }
        guard workspaceIDs.count == workspaceValues.count,
              Set(workspaceIDs).count == workspaceIDs.count,
              workspaceIDs.allSatisfy(isNonEmpty) else {
            return false
        }
        let workspaceSet = Set(workspaceIDs)
        if case .string(let selected)? = state["selectedWorkspaceId"],
           !workspaceSet.contains(selected) {
            return false
        }

        var surfaceReferences: [String: (workspaceID: String, type: String)] = [:]
        guard validateSurfaceItems(
            state["surfaces"],
            workspaceIDs: workspaceSet,
            references: &surfaceReferences
        ) else { return false }
        var threadIDs = Set<String>()
        guard validateWorkspaceItems(
            state["agentThreads"],
            workspaceIDs: workspaceSet,
            itemIDs: &threadIDs
        ) else { return false }
        var surfaceStateIDs = Set<String>()
        guard validateSurfaceStates(
            state["browserStates"],
            expectedType: "browser",
            surfaceReferences: surfaceReferences,
            stateIDs: &surfaceStateIDs
        ), validateSurfaceStates(
            state["filesStates"],
            expectedType: "files",
            surfaceReferences: surfaceReferences,
            stateIDs: &surfaceStateIDs
        ) else { return false }

        guard case .object(let revisions)? = state["domainRevisions"],
              Set(revisions.keys) == ["shell", "surfaces", "agentThreads", "browser", "files"] else {
            return false
        }
        return revisions.values.allSatisfy { value in
            guard case .number(let revision) = value else { return false }
            return revision.isFinite && revision >= 0 && revision.rounded(.towardZero) == revision
        }
    }

    /// Wave 4 partial: requires domainRevisions + includedDomains + only those domain keys.
    private static func isValidPartialSnapshotState(_ state: [String: JSONValue]) -> Bool {
        guard case .object(let revisions)? = state["domainRevisions"],
              Set(revisions.keys) == ["shell", "surfaces", "agentThreads", "browser", "files"],
              revisions.values.allSatisfy({ value in
                  guard case .number(let revision) = value else { return false }
                  return revision.isFinite && revision >= 0 && revision.rounded(.towardZero) == revision
              }),
              case .array(let includedRaw)? = state["includedDomains"] else {
            return false
        }
        let allowed = Set(["shell", "surfaces", "agentThreads", "browser", "files"])
        var included = Set<String>()
        for value in includedRaw {
            guard case .string(let name) = value, allowed.contains(name) else { return false }
            guard included.insert(name).inserted else { return false }
        }
        // Required metadata keys only + domain payloads that are included.
        var expected: Set<String> = ["partial", "includedDomains", "domainRevisions"]
        if included.contains("shell") {
            expected.formUnion(["selectedWorkspaceId", "workspaces"])
        }
        if included.contains("surfaces") { expected.insert("surfaces") }
        if included.contains("agentThreads") { expected.insert("agentThreads") }
        if included.contains("browser") { expected.insert("browserStates") }
        if included.contains("files") { expected.insert("filesStates") }
        guard Set(state.keys) == expected else { return false }
        // Lightweight presence checks (full structural validation still runs on
        // full snapshots; partials are merged client-side into a prior baseline).
        if included.contains("shell") {
            guard state["selectedWorkspaceId"] == .null
                    || state["selectedWorkspaceId"]?.stringValue != nil,
                  case .array? = state["workspaces"] else { return false }
        }
        if included.contains("surfaces"), state["surfaces"]?.arrayValue == nil { return false }
        if included.contains("agentThreads"), state["agentThreads"]?.arrayValue == nil { return false }
        if included.contains("browser"), state["browserStates"]?.arrayValue == nil { return false }
        if included.contains("files"), state["filesStates"]?.arrayValue == nil { return false }
        return true
    }

    private static func validateWorkspaceItems(
        _ value: JSONValue?,
        workspaceIDs: Set<String>,
        itemIDs: inout Set<String>
    ) -> Bool {
        guard case .array(let groups)? = value else { return false }
        var groupedWorkspaceIDs = Set<String>()
        for group in groups {
            guard case .object(let object) = group,
                  let workspaceID = object["workspaceId"]?.stringValue,
                  workspaceIDs.contains(workspaceID),
                  groupedWorkspaceIDs.insert(workspaceID).inserted,
                  case .array(let items)? = object["items"] else {
                return false
            }
            // A bounded thread window (`ConnectionSnapshotThreadWindow`) adds
            // exactly `totalCount` and `truncated`, consistent with `items`.
            if Set(object.keys) == ["workspaceId", "items", "totalCount", "truncated"] {
                guard let totalCount = object["totalCount"]?.intValue,
                      totalCount >= items.count,
                      object["truncated"]?.boolValue == (items.count < totalCount) else {
                    return false
                }
            } else if Set(object.keys) != ["workspaceId", "items"] {
                return false
            }
            for item in items {
                guard case .object(let itemObject) = item,
                      let itemID = itemObject["id"]?.stringValue,
                      let itemWorkspaceID = itemObject["workspaceId"]?.stringValue,
                      isNonEmpty(itemID),
                      isNonEmpty(itemWorkspaceID),
                      itemWorkspaceID == workspaceID,
                      itemIDs.insert(itemID).inserted else {
                    return false
                }
            }
        }
        return true
    }

    private static func validateSurfaceItems(
        _ value: JSONValue?,
        workspaceIDs: Set<String>,
        references: inout [String: (workspaceID: String, type: String)]
    ) -> Bool {
        guard case .array(let groups)? = value else { return false }
        var groupedWorkspaceIDs = Set<String>()
        for group in groups {
            guard case .object(let object) = group,
                  Set(object.keys) == ["workspaceId", "items"],
                  let workspaceID = object["workspaceId"]?.stringValue,
                  workspaceIDs.contains(workspaceID),
                  groupedWorkspaceIDs.insert(workspaceID).inserted,
                  case .array(let items)? = object["items"] else {
                return false
            }
            for item in items {
                guard case .object(let itemObject) = item,
                      let itemID = itemObject["id"]?.stringValue,
                      let type = itemObject["type"]?.stringValue,
                      isNonEmpty(itemID),
                      isNonEmpty(type),
                      references[itemID] == nil else {
                    return false
                }
                references[itemID] = (workspaceID, type)
            }
        }
        return true
    }

    private static func validateSurfaceStates(
        _ value: JSONValue?,
        expectedType: String,
        surfaceReferences: [String: (workspaceID: String, type: String)],
        stateIDs: inout Set<String>
    ) -> Bool {
        guard case .array(let values)? = value else { return false }
        var typedStateIDs = Set<String>()
        for value in values {
            guard case .object(let object) = value,
                  Set(object.keys) == ["workspaceId", "surfaceId", "state"],
                  let workspaceID = object["workspaceId"]?.stringValue,
                  let surfaceID = object["surfaceId"]?.stringValue,
                  let reference = surfaceReferences[surfaceID],
                  reference.workspaceID == workspaceID,
                  reference.type == expectedType,
                  typedStateIDs.insert(surfaceID).inserted,
                  stateIDs.insert(surfaceID).inserted,
                  case .object? = object["state"] else {
                return false
            }
        }
        let expectedIDs = Set(surfaceReferences.compactMap { id, reference in
            reference.type == expectedType ? id : nil
        })
        return typedStateIDs == expectedIDs
    }
}
