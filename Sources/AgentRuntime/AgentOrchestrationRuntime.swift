import CryptoKit
import Foundation
import CoreModel
import Persistence
import Darwin

public struct AgentOrchestrationRoute: Sendable, Equatable {
    public let provider: AgentProvider
    public let providerInstanceId: String
    public let capabilitySnapshotId: String
    public let selection: AgentModelSelection

    public init(
        provider: AgentProvider,
        providerInstanceId: String,
        capabilitySnapshotId: String,
        selection: AgentModelSelection
    ) {
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.capabilitySnapshotId = capabilitySnapshotId
        self.selection = selection
    }
}

public struct AgentOrchestrationLaunchConfiguration: Sendable, Equatable {
    public let binary: String?
    public let environment: [String: String]

    public init(binary: String? = nil, environment: [String: String] = [:]) {
        self.binary = binary
        self.environment = environment
    }
}

/// Immutable input captured by the caller before a queued run crosses into the
/// coordinator. Admission and provider launch both consume this exact snapshot.
public struct AgentOrchestrationRoutingSnapshot: Sendable, Equatable {
    public let configuration: AgentRoutingConfiguration
    public let providerSnapshots: [AgentProviderSnapshot]
    public let launchConfigurations: [String: AgentOrchestrationLaunchConfiguration]
    public let admissionSnapshot: AgentQueuedMessageRoutingSnapshot?

    public init(
        configuration: AgentRoutingConfiguration,
        providerSnapshots: [AgentProviderSnapshot],
        launchConfigurations: [String: AgentOrchestrationLaunchConfiguration] = [:],
        admissionSnapshot: AgentQueuedMessageRoutingSnapshot? = nil
    ) {
        self.configuration = configuration
        self.providerSnapshots = providerSnapshots
        self.launchConfigurations = launchConfigurations
        self.admissionSnapshot = admissionSnapshot
    }
}

public enum AgentOrchestrationReceiptLifecycleStatus: String, Codable, Sendable, Equatable {
    case accepted
    case unknown
    case finalized
}

/// Cryptographic bearer used only in memory and child process environments.
///
/// Receipts store `sha256Hex(_:)`; the plaintext capability must never be
/// encoded into an audit row, event, provider argument, or diagnostic.
public enum AgentDelegationCapability {
    private static let digestByteCount = 32

    /// PERF: nibble table instead of per-byte `String(format:)` so capability /
    /// policy digests avoid 32 formatter calls while keeping CryptoKit lowercase hex.
    fileprivate static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    fileprivate static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    /// PERF: fill 32 random bytes then nibble-hex once (not 32 `String(format:)`
    /// calls). Output remains 64-char lowercase hex for capability tokens.
    public static func issue() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return hexDigest(bytes)
    }

    public static func sha256Hex(_ capability: String) -> String {
        hexDigest(SHA256.hash(data: Data(capability.utf8)))
    }

    public static func matches(
        _ capability: String,
        sha256Hex expectedHex: String?
    ) -> Bool {
        guard AgentDelegationCapabilityTransport.isWellFormed(capability),
              let expectedHex,
              let expected = decodedHex(expectedHex),
              expected.count == digestByteCount else {
            return false
        }
        let actual = Array(SHA256.hash(data: Data(capability.utf8)))
        var difference: UInt8 = 0
        for index in 0..<digestByteCount {
            difference |= expected[index] ^ actual[index]
        }
        return difference == 0
    }

    private static func decodedHex(_ value: String) -> [UInt8]? {
        guard value.utf8.count == digestByteCount * 2 else { return nil }
        let bytes = Array(value.utf8)
        var decoded = [UInt8]()
        decoded.reserveCapacity(digestByteCount)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]),
                  let low = nibble(bytes[index + 1]) else {
                return nil
            }
            decoded.append((high << 4) | low)
        }
        return decoded
    }

    private static func nibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: return value - 48
        case 97...102: return value - 87
        default: return nil
        }
    }
}

/// Opaque receipt handle returned by the provider-neutral telemetry bridge.
///
/// The UUID identifies the lifecycle row while the independent bearer proves
/// that the caller owns that exact child. Only the bearer's SHA-256 digest is
/// persisted; this capability cannot authorize descendants.
public enum AgentExternalReceiptHandle {
    public static func encode(
        runId: AgentRunID,
        finalizationCapability: String
    ) -> String? {
        guard AgentDelegationCapabilityTransport.isWellFormed(
            finalizationCapability
        ) else {
            return nil
        }
        return "\(runId.value.uuidString.lowercased()).\(finalizationCapability)"
    }

    public static func decode(
        _ value: String
    ) -> (runId: AgentRunID, finalizationCapability: String)? {
        let parts = value.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              let runUUID = UUID(uuidString: String(parts[0])),
              AgentDelegationCapabilityTransport.isWellFormed(String(parts[1]))
        else {
            return nil
        }
        return (AgentRunID(runUUID), String(parts[1]))
    }
}

public enum AgentProviderCatalogProvenance {
    /// A missing provenance marker is promoted only when both the catalog and
    /// streaming capability were independently verified. Every uncertain or
    /// fallback path remains explicitly blocked from Auto admission.
    public static func resolvedSource(
        reportedSource: AgentModelDiscoverySource?,
        liveCatalogVerified: Bool,
        streamingCapabilityVerified: Bool
    ) -> AgentModelDiscoverySource {
        if reportedSource == .builtInFallback { return .builtInFallback }
        if reportedSource == .live {
            return streamingCapabilityVerified ? .live : .builtInFallback
        }
        return liveCatalogVerified && streamingCapabilityVerified ? .live : .builtInFallback
    }
}

public struct AgentOrchestrationAdmissionReceipt: Codable, Sendable, Equatable {
    public let id: UUID
    /// Parent admission for a controlled nested worker. Nil means this is the
    /// root route or a legacy receipt that predates child telemetry.
    public let parentReceiptId: UUID?
    public let runId: AgentRunID?
    public let threadId: AgentThreadID
    public let nodeId: String
    public let attemptId: UUID?
    public let routingRevision: Int
    public let policyDigest: String
    public let policyVersion: String
    public let packageRevision: String
    public let provider: AgentProvider
    public let providerInstanceId: String
    public let model: String
    /// Bound reasoning effort for this run. Nil on legacy receipts that predate
    /// the field — UI must not invent a default effort from absence.
    public let reasoningEffort: AgentReasoningEffort?
    public let capabilitySnapshotId: String
    public let decisionReason: String
    public let admittedAt: Date
    public let lifecycleStatus: AgentOrchestrationReceiptLifecycleStatus
    public let lifecycleUpdatedAt: Date
    public let finalizedAt: Date?
    public let finalRunStatus: AgentRunStatus?
    public let deadlineAt: Date?
    public let budgetTokens: Int?
    public let budgetCostMicros: Int?
    public let reservationId: String?
    public let reservedTokens: Int?
    public let reservedCostMicros: Int?
    public let permissionMode: AgentPermissionMode
    /// SHA-256 of the per-generation delegation bearer. Legacy and
    /// telemetry-only receipts have nil and cannot authorize descendants.
    public let delegationCapabilitySHA256: String?
    /// SHA-256 of the one-child finalization bearer returned by `subagent
    /// begin`. It is independent from delegation authority.
    public let finalizationCapabilitySHA256: String?
    /// OS process that owns an external receipt. Content-free and used only as
    /// a liveness signal alongside the bounded lease.
    public let ownerProcessID: Int32?
    public let actualTokens: Int?
    public let actualCostMicros: Int?
    public let latencyMilliseconds: Int64?
    public let qualityOutcome: String?

    public init(
        id: UUID = UUID(),
        parentReceiptId: UUID? = nil,
        runId: AgentRunID? = nil,
        threadId: AgentThreadID,
        nodeId: String = "root",
        attemptId: UUID? = nil,
        routingRevision: Int,
        policyDigest: String,
        policyVersion: String = AgentOrchestrationRuntime.policyContractVersion,
        packageRevision: String,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        reasoningEffort: AgentReasoningEffort? = nil,
        capabilitySnapshotId: String,
        decisionReason: String,
        admittedAt: Date = Date(),
        lifecycleStatus: AgentOrchestrationReceiptLifecycleStatus = .unknown,
        lifecycleUpdatedAt: Date? = nil,
        finalizedAt: Date? = nil,
        finalRunStatus: AgentRunStatus? = nil,
        deadlineAt: Date? = nil,
        budgetTokens: Int? = nil,
        budgetCostMicros: Int? = nil,
        reservationId: String? = nil,
        reservedTokens: Int? = nil,
        reservedCostMicros: Int? = nil,
        permissionMode: AgentPermissionMode = .supervised,
        delegationCapabilitySHA256: String? = nil,
        finalizationCapabilitySHA256: String? = nil,
        ownerProcessID: Int32? = nil,
        actualTokens: Int? = nil,
        actualCostMicros: Int? = nil,
        latencyMilliseconds: Int64? = nil,
        qualityOutcome: String? = nil
    ) {
        self.id = id
        self.parentReceiptId = parentReceiptId
        self.runId = runId
        self.threadId = threadId
        self.nodeId = nodeId
        self.attemptId = attemptId
        self.routingRevision = routingRevision
        self.policyDigest = policyDigest
        self.policyVersion = policyVersion
        self.packageRevision = packageRevision
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.capabilitySnapshotId = capabilitySnapshotId
        self.decisionReason = decisionReason
        self.admittedAt = admittedAt
        self.lifecycleStatus = lifecycleStatus
        self.lifecycleUpdatedAt = lifecycleUpdatedAt ?? admittedAt
        self.finalizedAt = finalizedAt
        self.finalRunStatus = finalRunStatus
        self.deadlineAt = deadlineAt
        self.budgetTokens = budgetTokens
        self.budgetCostMicros = budgetCostMicros
        self.reservationId = reservationId
        self.reservedTokens = reservedTokens
        self.reservedCostMicros = reservedCostMicros
        self.permissionMode = permissionMode
        self.delegationCapabilitySHA256 = delegationCapabilitySHA256
        self.finalizationCapabilitySHA256 = finalizationCapabilitySHA256
        self.ownerProcessID = ownerProcessID
        self.actualTokens = actualTokens
        self.actualCostMicros = actualCostMicros
        self.latencyMilliseconds = latencyMilliseconds
        self.qualityOutcome = qualityOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentReceiptId, runId, threadId, nodeId, attemptId, routingRevision, policyDigest
        case policyVersion, packageRevision, provider, providerInstanceId, model, reasoningEffort
        case capabilitySnapshotId, decisionReason, admittedAt, lifecycleStatus
        case lifecycleUpdatedAt, finalizedAt, finalRunStatus, deadlineAt
        case budgetTokens, budgetCostMicros, reservationId, reservedTokens
        case reservedCostMicros, permissionMode, delegationCapabilitySHA256
        case finalizationCapabilitySHA256
        case ownerProcessID, actualTokens, actualCostMicros
        case latencyMilliseconds, qualityOutcome
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let admittedAt = try values.decode(Date.self, forKey: .admittedAt)
        id = try values.decode(UUID.self, forKey: .id)
        parentReceiptId = try values.decodeIfPresent(UUID.self, forKey: .parentReceiptId)
        runId = try values.decodeIfPresent(AgentRunID.self, forKey: .runId)
        threadId = try values.decode(AgentThreadID.self, forKey: .threadId)
        nodeId = try values.decodeIfPresent(String.self, forKey: .nodeId) ?? "unknown"
        attemptId = try values.decodeIfPresent(UUID.self, forKey: .attemptId)
        routingRevision = try values.decode(Int.self, forKey: .routingRevision)
        policyDigest = try values.decode(String.self, forKey: .policyDigest)
        policyVersion = try values.decodeIfPresent(String.self, forKey: .policyVersion) ?? "unknown"
        packageRevision = try values.decode(String.self, forKey: .packageRevision)
        provider = try values.decode(AgentProvider.self, forKey: .provider)
        providerInstanceId = try values.decode(String.self, forKey: .providerInstanceId)
        model = try values.decode(String.self, forKey: .model)
        reasoningEffort = try values.decodeIfPresent(AgentReasoningEffort.self, forKey: .reasoningEffort)
        capabilitySnapshotId = try values.decode(String.self, forKey: .capabilitySnapshotId)
        decisionReason = try values.decode(String.self, forKey: .decisionReason)
        self.admittedAt = admittedAt
        lifecycleStatus = try values.decodeIfPresent(
            AgentOrchestrationReceiptLifecycleStatus.self,
            forKey: .lifecycleStatus
        ) ?? .unknown
        lifecycleUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .lifecycleUpdatedAt) ?? admittedAt
        finalizedAt = try values.decodeIfPresent(Date.self, forKey: .finalizedAt)
        finalRunStatus = try values.decodeIfPresent(AgentRunStatus.self, forKey: .finalRunStatus)
        deadlineAt = try values.decodeIfPresent(Date.self, forKey: .deadlineAt)
        budgetTokens = try values.decodeIfPresent(Int.self, forKey: .budgetTokens)
        budgetCostMicros = try values.decodeIfPresent(Int.self, forKey: .budgetCostMicros)
        reservationId = try values.decodeIfPresent(String.self, forKey: .reservationId)
        reservedTokens = try values.decodeIfPresent(Int.self, forKey: .reservedTokens)
        reservedCostMicros = try values.decodeIfPresent(Int.self, forKey: .reservedCostMicros)
        permissionMode = try values.decodeIfPresent(AgentPermissionMode.self, forKey: .permissionMode) ?? .supervised
        delegationCapabilitySHA256 = try values.decodeIfPresent(
            String.self,
            forKey: .delegationCapabilitySHA256
        )
        finalizationCapabilitySHA256 = try values.decodeIfPresent(
            String.self,
            forKey: .finalizationCapabilitySHA256
        )
        ownerProcessID = try values.decodeIfPresent(Int32.self, forKey: .ownerProcessID)
        actualTokens = try values.decodeIfPresent(Int.self, forKey: .actualTokens)
        actualCostMicros = try values.decodeIfPresent(Int.self, forKey: .actualCostMicros)
        latencyMilliseconds = try values.decodeIfPresent(Int64.self, forKey: .latencyMilliseconds)
        qualityOutcome = try values.decodeIfPresent(String.self, forKey: .qualityOutcome)
    }

    func updatingLifecycle(
        _ status: AgentOrchestrationReceiptLifecycleStatus,
        finalRunStatus: AgentRunStatus? = nil,
        at: Date
    ) -> AgentOrchestrationAdmissionReceipt {
        AgentOrchestrationAdmissionReceipt(
            id: id,
            parentReceiptId: parentReceiptId,
            runId: runId,
            threadId: threadId,
            nodeId: nodeId,
            attemptId: attemptId,
            routingRevision: routingRevision,
            policyDigest: policyDigest,
            policyVersion: policyVersion,
            packageRevision: packageRevision,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            reasoningEffort: reasoningEffort,
            capabilitySnapshotId: capabilitySnapshotId,
            decisionReason: decisionReason,
            admittedAt: admittedAt,
            lifecycleStatus: status,
            lifecycleUpdatedAt: at,
            finalizedAt: status == .finalized ? at : finalizedAt,
            finalRunStatus: status == .finalized ? finalRunStatus : self.finalRunStatus,
            deadlineAt: deadlineAt,
            budgetTokens: budgetTokens,
            budgetCostMicros: budgetCostMicros,
            reservationId: reservationId,
            reservedTokens: reservedTokens,
            reservedCostMicros: reservedCostMicros,
            permissionMode: permissionMode,
            delegationCapabilitySHA256: delegationCapabilitySHA256,
            finalizationCapabilitySHA256: finalizationCapabilitySHA256,
            ownerProcessID: ownerProcessID,
            actualTokens: actualTokens,
            actualCostMicros: actualCostMicros,
            latencyMilliseconds: latencyMilliseconds,
            qualityOutcome: qualityOutcome
        )
    }

    func updatingUsage(
        _ usage: AssistantTokenUsage?,
        latencyMilliseconds: Int64,
        actualCostMicros: Int? = nil,
        qualityOutcome: String? = nil,
        lifecycleUpdatedAt: Date? = nil
    ) -> AgentOrchestrationAdmissionReceipt {
        AgentOrchestrationAdmissionReceipt(
            id: id,
            parentReceiptId: parentReceiptId,
            runId: runId,
            threadId: threadId,
            nodeId: nodeId,
            attemptId: attemptId,
            routingRevision: routingRevision,
            policyDigest: policyDigest,
            policyVersion: policyVersion,
            packageRevision: packageRevision,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            reasoningEffort: reasoningEffort,
            capabilitySnapshotId: capabilitySnapshotId,
            decisionReason: decisionReason,
            admittedAt: admittedAt,
            lifecycleStatus: lifecycleStatus,
            lifecycleUpdatedAt: lifecycleUpdatedAt ?? self.lifecycleUpdatedAt,
            finalizedAt: finalizedAt,
            finalRunStatus: finalRunStatus,
            deadlineAt: deadlineAt,
            budgetTokens: budgetTokens,
            budgetCostMicros: budgetCostMicros,
            reservationId: reservationId,
            reservedTokens: reservedTokens,
            reservedCostMicros: reservedCostMicros,
            permissionMode: permissionMode,
            delegationCapabilitySHA256: delegationCapabilitySHA256,
            finalizationCapabilitySHA256: finalizationCapabilitySHA256,
            ownerProcessID: ownerProcessID,
            actualTokens: usage?.totalTokens,
            actualCostMicros: actualCostMicros ?? self.actualCostMicros,
            latencyMilliseconds: latencyMilliseconds,
            qualityOutcome: qualityOutcome ?? self.qualityOutcome
        )
    }

    func renewingLease(
        deadlineAt: Date,
        lifecycleUpdatedAt: Date
    ) -> AgentOrchestrationAdmissionReceipt {
        AgentOrchestrationAdmissionReceipt(
            id: id,
            parentReceiptId: parentReceiptId,
            runId: runId,
            threadId: threadId,
            nodeId: nodeId,
            attemptId: attemptId,
            routingRevision: routingRevision,
            policyDigest: policyDigest,
            policyVersion: policyVersion,
            packageRevision: packageRevision,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            reasoningEffort: reasoningEffort,
            capabilitySnapshotId: capabilitySnapshotId,
            decisionReason: decisionReason,
            admittedAt: admittedAt,
            lifecycleStatus: lifecycleStatus,
            lifecycleUpdatedAt: lifecycleUpdatedAt,
            finalizedAt: finalizedAt,
            finalRunStatus: finalRunStatus,
            deadlineAt: deadlineAt,
            budgetTokens: budgetTokens,
            budgetCostMicros: budgetCostMicros,
            reservationId: reservationId,
            reservedTokens: reservedTokens,
            reservedCostMicros: reservedCostMicros,
            permissionMode: permissionMode,
            delegationCapabilitySHA256: delegationCapabilitySHA256,
            finalizationCapabilitySHA256: finalizationCapabilitySHA256,
            ownerProcessID: ownerProcessID,
            actualTokens: actualTokens,
            actualCostMicros: actualCostMicros,
            latencyMilliseconds: latencyMilliseconds,
            qualityOutcome: qualityOutcome
        )
    }
}

/// Content-free ledger row used for reconciliation and rollout decisions.
/// Prompt and provider output are intentionally absent.
public struct AgentOrchestrationLedgerEntry: Codable, Sendable, Equatable {
    public let runId: AgentRunID?
    public let threadIdHash: String
    public let nodeId: String
    public let attemptId: UUID?
    public let provider: AgentProvider
    public let providerInstanceId: String
    public let model: String
    public let capabilitySnapshotId: String
    public let policyDigest: String
    public let routingRevision: Int
    public let reservationId: String?
    public let admittedAt: Date
    public let finalizedAt: Date?
    public let tokenUsage: Int?
    public let costMicros: Int?
    public let latencyMilliseconds: Int64?
    public let outcome: String

    public init(receipt: AgentOrchestrationAdmissionReceipt, outcome: String, finalizedAt: Date? = nil) {
        runId = receipt.runId
        threadIdHash = AgentDelegationCapability.hexDigest(
            SHA256.hash(data: Data(receipt.threadId.value.uuidString.utf8))
        )
        nodeId = receipt.nodeId
        attemptId = receipt.attemptId
        provider = receipt.provider
        providerInstanceId = receipt.providerInstanceId
        model = receipt.model
        capabilitySnapshotId = receipt.capabilitySnapshotId
        policyDigest = receipt.policyDigest
        routingRevision = receipt.routingRevision
        reservationId = receipt.reservationId
        admittedAt = receipt.admittedAt
        self.finalizedAt = finalizedAt
        tokenUsage = receipt.actualTokens
        costMicros = receipt.actualCostMicros
        latencyMilliseconds = receipt.latencyMilliseconds
        self.outcome = outcome
    }
}

public enum AgentOrchestrationAdmissionError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case packageUnavailable
    case rolloutDisabled
    case killSwitchEnabled
    case invalidPolicy
    case deadlineExpired
    case invalidBudget
    case costBudgetUnavailable
    case quotaExceeded
    case invalidRoutingMode
    case noEligibleProvider
    case invalidChildAdmission(String)
    /// Source picker host is eligible in policy but not runnable (missing binary,
    /// unauthenticated, empty models). Fail closed — do not silently route to another host.
    /// `detail` is an optional concrete status (e.g. "Claude is not authenticated") so
    /// the banner is actionable instead of a generic install/auth/models blob.
    case preferredSourceUnavailable(AgentProvider, detail: String? = nil)
    case receiptPersistenceFailed(String)

    public var description: String {
        switch self {
        case .packageUnavailable:
            return "The pinned remote-code-orchestrate package is unavailable or invalid."
        case .rolloutDisabled:
            return "Auto model routing is disabled by the orchestration rollout flag."
        case .killSwitchEnabled:
            return "Auto model routing is disabled by the orchestration kill switch."
        case .invalidPolicy:
            return "The Auto routing policy is invalid or no longer current."
        case .deadlineExpired:
            return "The Auto routing deadline has already expired."
        case .invalidBudget:
            return "The Auto routing budget or reservation is invalid."
        case .costBudgetUnavailable:
            return "Auto routing cannot admit a cost budget until live provider pricing is available."
        case .quotaExceeded:
            return "The Auto routing quota is unavailable for this run."
        case .invalidRoutingMode:
            return "Orchestration admission requires an Auto routing configuration."
        case .noEligibleProvider:
            return "No eligible provider has a live model catalog and confirmed streaming capability."
        case .invalidChildAdmission(let detail):
            return "Nested worker admission is invalid: \(detail)"
        case .preferredSourceUnavailable(let provider, let detail):
            let reason = (detail?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "that Source is not runnable on this Mac (install/auth/models)"
            return "Auto cannot start on \(provider.rawValue): \(reason). Fix the Source or switch it before using Auto — RemoteCode will not silently fall back to another provider."
        case .receiptPersistenceFailed(let message):
            return "Could not persist the orchestration admission receipt: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// Durable, content-free audit storage for orchestration admission decisions.
/// It deliberately reuses the app's existing audit table instead of creating a
/// second schema owner inside AgentRuntime.
public final class AgentOrchestrationRepository: @unchecked Sendable {
    private static let admissionAction = "agent.orchestration.admitted"
    private static let lifecycleAction = "agent.orchestration.lifecycle"
    private static let ledgerAction = "agent.orchestration.ledger"
    private static let processTransactionLock = NSLock()
    private enum Storage {
        case database(SQLiteDB, DeviceTrustRepository)
        case file(URL)
    }

    private let storage: Storage
    private let transactionLockURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Append-signature activity cache (perf X-01)

    /// Receipt rows in `audit_log` are append-only, so `(count, max id)` over
    /// the two receipt actions is a cheap cross-process-safe signature: other
    /// processes (distill provider proxies) append receipts too, so a cache fed
    /// only by local writes would go stale. A `nil` signature (file storage,
    /// empty table, query failure) disables caching entirely — callers then pay
    /// the uncached path exactly as before.
    private struct ReceiptSetSignature: Equatable {
        let count: Int
        let maxID: Int64
    }

    private let activityCacheLock = NSLock()
    private var cachedThreadActivityFetch: (
        key: String,
        signature: ReceiptSetSignature,
        receipts: [AgentOrchestrationAdmissionReceipt]
    )?
    private var cachedRunReceipts:
        [AgentRunID: (signature: ReceiptSetSignature, receipt: AgentOrchestrationAdmissionReceipt?)] = [:]
    private static let runReceiptMemoCap = 256
    private var cachedReceiptsByIDs: (
        signature: ReceiptSetSignature,
        results: [Set<UUID>: [UUID: AgentOrchestrationAdmissionReceipt]]
    )?
    private static let receiptsByIDsMemoCap = 16
#if DEBUG
    public private(set) var receiptDetailDecodeCountForTesting = 0
#endif

    /// Must be called under `withReceiptRead`/`withReceiptMutation` so the
    /// signature read joins the caller's transaction.
    private func receiptSetSignatureUnlocked() -> ReceiptSetSignature? {
        switch storage {
        case .database(_, let repository):
            guard let signature = try? repository.auditLogSignature(
                actions: [Self.admissionAction, Self.lifecycleAction]
            ) else { return nil }
            return ReceiptSetSignature(count: signature.count, maxID: signature.maxID)
        case .file:
            return nil
        }
    }

    private func cachedThreadActivityUnlocked(
        threadIds: Set<AgentThreadID>,
        limit: Int,
        childRecordLimit: Int,
        signature: ReceiptSetSignature?
    ) -> [AgentOrchestrationAdmissionReceipt]? {
        guard let signature else { return nil }
        let key = Self.threadActivityCacheKey(
            threadIds: threadIds, limit: limit, childRecordLimit: childRecordLimit
        )
        return activityCacheLock.withLock { () -> [AgentOrchestrationAdmissionReceipt]? in
            guard let cached = cachedThreadActivityFetch,
                  cached.key == key,
                  cached.signature == signature else { return nil }
            return cached.receipts
        }
    }

    private func storeThreadActivityCache(
        threadIds: Set<AgentThreadID>,
        limit: Int,
        childRecordLimit: Int,
        signature: ReceiptSetSignature?,
        receipts: [AgentOrchestrationAdmissionReceipt]
    ) {
        guard let signature else { return }
        let key = Self.threadActivityCacheKey(
            threadIds: threadIds, limit: limit, childRecordLimit: childRecordLimit
        )
        activityCacheLock.withLock {
            cachedThreadActivityFetch = (key, signature, receipts)
        }
    }

    private static func threadActivityCacheKey(
        threadIds: Set<AgentThreadID>,
        limit: Int,
        childRecordLimit: Int
    ) -> String {
        let ids = threadIds.map(\.value.uuidString).sorted().joined(separator: ",")
        return "\(ids)#\(limit)#\(childRecordLimit)"
    }

    public init(db: SQLiteDB) {
        storage = .database(db, DeviceTrustRepository(db: db))
        let databaseURL = URL(fileURLWithPath: db.path).standardizedFileURL
        transactionLockURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(".\(databaseURL.lastPathComponent).orchestration.lock")
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public init(auditLogURL: URL = AgentOrchestrationRepository.defaultAuditLogURL()) {
        storage = .file(auditLogURL)
        transactionLockURL = auditLogURL.deletingLastPathComponent()
            .appendingPathComponent(".admission-receipts.lock")
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ receipt: AgentOrchestrationAdmissionReceipt) throws {
        try withReceiptMutation {
            try persistUnlocked(receipt, action: Self.admissionAction)
        }
    }

    public func update(_ receipt: AgentOrchestrationAdmissionReceipt) throws {
        try withReceiptMutation {
            try persistUnlocked(receipt, action: Self.lifecycleAction)
        }
    }

    public func saveLedger(_ entry: AgentOrchestrationLedgerEntry) throws {
        try withReceiptMutation {
            try saveLedgerUnlocked(entry)
        }
    }

    fileprivate func withReceiptMutation<T>(_ body: () throws -> T) throws -> T {
        try withCrossProcessLock {
            switch storage {
            case .database(let db, _):
                return try db.transaction(body)
            case .file:
                return try body()
            }
        }
    }

    fileprivate func appendAdmissionUnlocked(_ receipt: AgentOrchestrationAdmissionReceipt) throws {
        try persistUnlocked(receipt, action: Self.admissionAction)
    }

    fileprivate func appendLifecycleUnlocked(_ receipt: AgentOrchestrationAdmissionReceipt) throws {
        try persistUnlocked(receipt, action: Self.lifecycleAction)
    }

    fileprivate func appendLedgerUnlocked(_ entry: AgentOrchestrationLedgerEntry) throws {
        try saveLedgerUnlocked(entry)
    }

    private func saveLedgerUnlocked(_ entry: AgentOrchestrationLedgerEntry) throws {
        let data = try encoder.encode(entry)
        guard let detail = String(data: data, encoding: .utf8) else {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed("invalid UTF-8")
        }
        switch storage {
        case .database(_, let repository):
            try repository.audit(actor: "RemoteCode", action: Self.ledgerAction, detail: detail, at: entry.finalizedAt ?? entry.admittedAt)
        case .file(let url):
            try appendFileRecordUnlocked(data, to: url)
        }
    }

    public func ledger(limit: Int = 50) throws -> [AgentOrchestrationLedgerEntry] {
        try withReceiptRead {
            try ledgerUnlocked(limit: limit)
        }
    }

    private func ledgerUnlocked(limit: Int) throws -> [AgentOrchestrationLedgerEntry] {
        let details: [String]
        switch storage {
        case .database(_, let repository):
            details = try repository.listAuditLogDetails(
                actions: [Self.ledgerAction],
                limit: max(1, limit) * 4
            )
        case .file(let url):
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let text = String(data: data, encoding: .utf8) else { return [] }
            // Match the audit database contract: callers see the newest
            // append-only correction first on either storage backend.
            details = text.split(separator: "\n").reversed().map(String.init)
        }
        return details.compactMap { try? decoder.decode(AgentOrchestrationLedgerEntry.self, from: Data($0.utf8)) }
            .prefix(max(1, limit)).map { $0 }
    }

    private func persistUnlocked(_ receipt: AgentOrchestrationAdmissionReceipt, action: String) throws {
        let data = try encoder.encode(receipt)
        guard let detail = String(data: data, encoding: .utf8) else {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed("invalid UTF-8")
        }
        switch storage {
        case .database(_, let repository):
            try repository.audit(
                actor: "RemoteCode",
                action: action,
                detail: detail,
                at: receipt.lifecycleUpdatedAt
            )
        case .file(let url):
            try appendFileRecordUnlocked(data, to: url)
        }
    }

    public func receipts(limit: Int = 50) throws -> [AgentOrchestrationAdmissionReceipt] {
        try withReceiptRead {
            try receiptsUnlocked(limit: limit)
        }
    }

    fileprivate func receiptsUnlocked(limit: Int) throws -> [AgentOrchestrationAdmissionReceipt] {
        let records: [AgentOrchestrationAdmissionReceipt]
        switch storage {
        case .database(_, let repository):
            records = try repository.listAuditLogDetails(
                actions: [Self.admissionAction, Self.lifecycleAction],
                limit: max(1, limit) * 4
            ).compactMap(decodeReceiptDetail)
        case .file(let url):
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            records = text.split(separator: "\n")
                .compactMap { try? decoder.decode(AgentOrchestrationAdmissionReceipt.self, from: Data($0.utf8)) }
        }
        return latestReceipts(from: records, limit: limit)
    }

    /// Scoped activity fetch: selected-thread rows (LIKE prefilter on thread UUID)
    /// plus a bounded window of nested-worker rows (`"parentReceiptId"` key present).
    /// Exact thread / parent-chain membership is enforced by the caller after decode.
    ///
    /// WHY: the Subagents badge polls on the MainActor every ~2s. Decoding up to
    /// 40k global JSON blobs dominated refresh cost; this cuts decode volume to
    /// the selected thread plus nested children without a schema migration.
    fileprivate func receiptsUnlocked(
        matchingThreadIds threadIds: Set<AgentThreadID>,
        limit: Int,
        childRecordLimit: Int
    ) throws -> [AgentOrchestrationAdmissionReceipt] {
        guard !threadIds.isEmpty else { return [] }
        // Signature-guarded cache: the 2s badge poll re-runs this fetch with
        // identical parameters; when no process appended or pruned receipt rows
        // the previous result is still exact (perf X-01).
        let signature = receiptSetSignatureUnlocked()
        if let cached = cachedThreadActivityUnlocked(
            threadIds: threadIds, limit: limit, childRecordLimit: childRecordLimit, signature: signature
        ) {
            return cached
        }
        let threadBound = max(1, limit)
        let childBound = max(1, childRecordLimit)
        let headroom = 4
        var records: [AgentOrchestrationAdmissionReceipt] = []

        switch storage {
        case .database(_, let repository):
            let actions = [Self.admissionAction, Self.lifecycleAction]
            for threadId in threadIds {
                // AgentThreadID encodes as {"value":"<UUID>"}; needle is the raw
                // uuid string only. LIKE is a prefilter — exact threadId checked later.
                let details = try repository.listAuditLogDetails(
                    actions: actions,
                    detailContains: threadId.value.uuidString,
                    limit: threadBound * headroom
                )
                records.append(contentsOf: details.compactMap(decodeReceiptDetail))
            }
            // Synthesized Codable omits nil parentReceiptId, so this key appears
            // only on nested-worker rows (a small ledger fraction).
            let childDetails = try repository.listAuditLogDetails(
                actions: actions,
                detailContains: "\"parentReceiptId\"",
                limit: childBound * headroom
            )
            records.append(contentsOf: childDetails.compactMap(decodeReceiptDetail))
        case .file:
            try forEachReceiptRecordUnlocked(containing: nil) { receipt in
                if threadIds.contains(receipt.threadId) || receipt.parentReceiptId != nil {
                    records.append(receipt)
                }
            }
        }

        // Dedupe latest-by-id, then keep newest thread-bound and child-bound
        // windows separately so an explosion of children cannot starve thread rows.
        var latestByID: [UUID: AgentOrchestrationAdmissionReceipt] = [:]
        for receipt in records {
            if let current = latestByID[receipt.id],
               current.lifecycleUpdatedAt >= receipt.lifecycleUpdatedAt {
                continue
            }
            latestByID[receipt.id] = receipt
        }
        let latest = latestByID.values.sorted { $0.lifecycleUpdatedAt > $1.lifecycleUpdatedAt }
        var kept: [AgentOrchestrationAdmissionReceipt] = []
        var keptIDs = Set<UUID>()
        var threadCount = 0
        var childCount = 0
        for receipt in latest {
            let onThread = threadIds.contains(receipt.threadId)
            let isChild = receipt.parentReceiptId != nil
            if onThread {
                if threadCount >= threadBound { continue }
                threadCount += 1
            } else if isChild {
                if childCount >= childBound { continue }
                childCount += 1
            } else {
                continue
            }
            if keptIDs.insert(receipt.id).inserted {
                kept.append(receipt)
            }
        }
        storeThreadActivityCache(
            threadIds: threadIds,
            limit: limit,
            childRecordLimit: childRecordLimit,
            signature: signature,
            receipts: kept
        )
        return kept
    }

    private func decodeReceiptDetail(_ detail: String) -> AgentOrchestrationAdmissionReceipt? {
#if DEBUG
        activityCacheLock.withLock { receiptDetailDecodeCountForTesting += 1 }
#endif
        guard let data = detail.data(using: .utf8) else { return nil }
        return try? decoder.decode(AgentOrchestrationAdmissionReceipt.self, from: data)
    }

    private func latestReceipts(
        from records: [AgentOrchestrationAdmissionReceipt],
        limit: Int
    ) -> [AgentOrchestrationAdmissionReceipt] {
        var latestByID: [UUID: AgentOrchestrationAdmissionReceipt] = [:]
        for receipt in records {
            if let current = latestByID[receipt.id],
               current.lifecycleUpdatedAt >= receipt.lifecycleUpdatedAt {
                continue
            }
            latestByID[receipt.id] = receipt
        }
        return latestByID.values
            .sorted { $0.lifecycleUpdatedAt > $1.lifecycleUpdatedAt }
            .prefix(max(1, limit))
            .map { $0 }
    }

    /// Parent-chain lookup for activity reads. The badge poll's child window is
    /// global, so its parents usually live on other threads and miss the
    /// primary fetch on every tick. This used to scan, sort (temp-file spill)
    /// and decode every receipt row per tick while holding the writer
    /// connection. Now SQL returns only the requested ids, in the same
    /// `ORDER BY id` order so the first-wins tie-break is unchanged, and an
    /// unchanged receipt set is served from the signature memo.
    fileprivate func receiptsUnlocked(
        ids: Set<UUID>
    ) throws -> [UUID: AgentOrchestrationAdmissionReceipt] {
        guard !ids.isEmpty else { return [:] }
        let signature = receiptSetSignatureUnlocked()
        if let signature,
           let cached = activityCacheLock.withLock({ cachedReceiptsByIDs }),
           cached.signature == signature,
           let receipts = cached.results[ids] {
            return receipts
        }
        var latestByID: [UUID: AgentOrchestrationAdmissionReceipt] = [:]
        try forEachReceiptRecordUnlocked(withIDs: ids) { receipt in
            guard ids.contains(receipt.id) else { return }
            if let current = latestByID[receipt.id],
               current.lifecycleUpdatedAt >= receipt.lifecycleUpdatedAt {
                return
            }
            latestByID[receipt.id] = receipt
        }
        if let signature {
            activityCacheLock.withLock {
                var results = cachedReceiptsByIDs?.signature == signature
                    ? cachedReceiptsByIDs?.results ?? [:]
                    : [:]
                if results.count >= Self.receiptsByIDsMemoCap {
                    results.removeAll(keepingCapacity: true)
                }
                results[ids] = latestByID
                cachedReceiptsByIDs = (signature, results)
            }
        }
        return latestByID
    }

    private func forEachReceiptRecordUnlocked(
        withIDs ids: Set<UUID>,
        _ body: (AgentOrchestrationAdmissionReceipt) -> Void
    ) throws {
        switch storage {
        case .database(let db, _):
            // JSONEncoder writes UUIDs uppercase; `upper` also matches a
            // lowercase writer, which JSONDecoder accepts. The CASE keeps one
            // malformed row from failing the whole read (decode skips it).
            let statement = try db.prepare("""
                SELECT detail FROM audit_log
                WHERE action IN (?, ?)
                  AND upper(CASE WHEN json_valid(detail) THEN json_extract(detail, '$.id') END)
                      IN (SELECT value FROM json_each(?))
                ORDER BY id ASC;
            """)
            try statement.bind(1, Self.admissionAction)
            try statement.bind(2, Self.lifecycleAction)
            try statement.bind(3, "[" + ids.map { "\"\($0.uuidString)\"" }.joined(separator: ",") + "]")
            while try statement.step() {
                guard let detail = statement.columnText(0),
                      let receipt = try? decoder.decode(
                        AgentOrchestrationAdmissionReceipt.self,
                        from: Data(detail.utf8)
                      ) else {
                    continue
                }
                body(receipt)
            }
        case .file:
            try forEachReceiptRecordUnlocked(containing: nil, body)
        }
    }

    public func receipt(runId: AgentRunID) throws -> AgentOrchestrationAdmissionReceipt? {
        try withReceiptRead {
            try receiptUnlocked(runId: runId)
        }
    }

    fileprivate func receiptUnlocked(runId: AgentRunID) throws -> AgentOrchestrationAdmissionReceipt? {
        // Signature-guarded memo: `isNestedAgentWorker` resolves the same run
        // repeatedly after terminal events; the memo avoids the full audit scan
        // when no receipt rows changed (perf X-01).
        let signature = receiptSetSignatureUnlocked()
        if let signature,
           let cached = activityCacheLock.withLock({ cachedRunReceipts[runId] }),
           cached.signature == signature {
            return cached.receipt
        }
        let receipt = try latestReceiptUnlocked(containing: runId.value.uuidString) { $0.runId == runId }
        if let signature {
            activityCacheLock.withLock {
                if cachedRunReceipts.count >= Self.runReceiptMemoCap {
                    cachedRunReceipts.removeAll(keepingCapacity: true)
                }
                cachedRunReceipts[runId] = (signature, receipt)
            }
        }
        return receipt
    }

    fileprivate func receiptUnlocked(id: UUID) throws -> AgentOrchestrationAdmissionReceipt? {
        try latestReceiptUnlocked(containing: id.uuidString) { $0.id == id }
    }

    private func latestReceiptUnlocked(
        containing needle: String,
        matching predicate: (AgentOrchestrationAdmissionReceipt) -> Bool
    ) throws -> AgentOrchestrationAdmissionReceipt? {
        var latest: AgentOrchestrationAdmissionReceipt?
        try forEachReceiptRecordUnlocked(containing: needle) { receipt in
            guard predicate(receipt) else { return }
            if let current = latest,
               current.lifecycleUpdatedAt > receipt.lifecycleUpdatedAt {
                return
            }
            latest = receipt
        }
        return latest
    }

    private func forEachReceiptRecordUnlocked(
        containing needle: String?,
        _ body: (AgentOrchestrationAdmissionReceipt) -> Void
    ) throws {
        switch storage {
        case .database(let db, _):
            let filter = needle == nil ? "" : " AND detail LIKE ?"
            let statement = try db.prepare("""
                SELECT detail FROM audit_log
                WHERE action IN (?, ?)\(filter)
                ORDER BY id ASC;
            """)
            try statement.bind(1, Self.admissionAction)
            try statement.bind(2, Self.lifecycleAction)
            if let needle {
                try statement.bind(3, "%\(needle)%")
            }
            while try statement.step() {
                guard let detail = statement.columnText(0),
                      let receipt = try? decoder.decode(
                        AgentOrchestrationAdmissionReceipt.self,
                        from: Data(detail.utf8)
                      ) else {
                    continue
                }
                body(receipt)
            }
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var pending = Data()
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    // Own the bytes before mutating `pending`; a Data slice may
                    // otherwise share the storage whose prefix is removed next.
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    decodeReceiptLine(line, containing: needle, body)
                }
            }
            if !pending.isEmpty {
                decodeReceiptLine(pending, containing: needle, body)
            }
        }
    }

    private func decodeReceiptLine(
        _ line: Data,
        containing needle: String?,
        _ body: (AgentOrchestrationAdmissionReceipt) -> Void
    ) {
        if let needle,
           String(decoding: line, as: UTF8.self).localizedCaseInsensitiveContains(needle) == false {
            return
        }
        guard let receipt = try? decoder.decode(
            AgentOrchestrationAdmissionReceipt.self,
            from: line
        ) else {
            return
        }
        body(receipt)
    }

    private func appendFileRecordUnlocked(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data([0x0A]))
        try handle.synchronize()
    }

    fileprivate func withReceiptRead<T>(_ body: () throws -> T) throws -> T {
        try withCrossProcessLock {
            switch storage {
            case .database(let db, _):
                // BEGIN DEFERRED: shared read lock only so the 2s badge poll and
                // other readers do not reserve the writer against live agent upserts.
                return try db.readTransaction(body)
            case .file:
                return try body()
            }
        }
    }

    private func withCrossProcessLock<T>(_ body: () throws -> T) throws -> T {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }

        let directory = transactionLockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let ownerReadWrite = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = Darwin.open(
            transactionLockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            ownerReadWrite
        )
        guard descriptor >= 0 else {
            throw lockError(operation: "open")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, ownerReadWrite) == 0 else {
            throw lockError(operation: "fchmod")
        }

        // The file lock is taken before the SQLite transaction (see
        // withReceiptMutation/withReceiptRead) and is shared with the Distill
        // sidecars. Wait at most 2 s: a stuck or suspended peer must not hang
        // the app. Database storage fails open, because BEGIN IMMEDIATE already
        // serializes writers across processes; the JSONL file has no other
        // guard, so it fails instead.
        switch BoundedFileLock.acquireExclusive(
            descriptor: descriptor,
            style: .posixRecord,
            label: "orchestration-receipts",
            onTimeout: isDatabaseStorage ? .failOpen : .fail
        ) {
        case .acquired:
            defer { BoundedFileLock.unlock(descriptor: descriptor, style: .posixRecord) }
            return try body()
        case .timedOut:
            guard isDatabaseStorage else {
                throw AgentOrchestrationAdmissionError.receiptPersistenceFailed(
                    "lock orchestration lock: timed out"
                )
            }
            return try body()
        case .failed(let code):
            errno = code
            throw lockError(operation: "lock")
        }
    }

    private var isDatabaseStorage: Bool {
        if case .database = storage { return true }
        return false
    }

    private func lockError(operation: String) -> AgentOrchestrationAdmissionError {
        let code = errno
        return .receiptPersistenceFailed(
            "\(operation) orchestration lock: \(String(cString: strerror(code)))"
        )
    }

    public static func defaultAuditLogURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteCode/Orchestration", isDirectory: true)
            .appendingPathComponent("admission-receipts.jsonl")
    }
}

/// Native single-route admission. Provider execution remains owned by
/// AgentRunCoordinator, which dispatches the returned route through its existing
/// Claude, Codex, or Grok adapter.
public final class AgentOrchestrationRuntime: @unchecked Sendable {
    public static let packageID = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage.skillID
    public static let requiredPackageRevision = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage.sourceRevision
    public static let policyContractVersion = "1"
    public static let rolloutFlagKey = "agent.orchestration.rollout-enabled"
    public static let defaultExternalLeaseDuration: TimeInterval = 24 * 60 * 60
    private static let maxConcurrentReservations = 32
    private static let maximumReceiptAncestorDepth = 64
    // PERF: nested child admission validates node ids on every admit path;
    // `"-_.".unicodeScalars.contains` built a temporary view per scalar.
    // Share one alphanumerics+`-_.` set (same membership contract).
    private static let safeNodeIdScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_."))

    public let policyDigest: String
    private let repository: AgentOrchestrationRepository
    private let packageVerification: @Sendable () -> Bool
    private let rolloutGate: @Sendable () -> Bool
    private let killSwitch: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let costEstimator: (@Sendable (AgentOrchestrationAdmissionReceipt, AssistantTokenUsage?) -> Int?)?
    private let externalLeaseDuration: TimeInterval
    private let processIsAlive: @Sendable (Int32) -> Bool
    private let nativeChildLivenessLock = NSLock()
    private var nativeChildLiveness: (@Sendable (AgentOrchestrationAdmissionReceipt) -> Bool)?
    private let reservationLock = NSLock()
    private var reservations: [String: (tokens: Int?, costMicros: Int?, deadlineAt: Date?)] = [:]
    /// Records whether `activityReceipts` (JSON/SQLite decode) ran on the MainActor.
    public let activityReceiptsThreadProbeForTesting = ActivityReceiptsThreadProbe()

    public init(
        repository: AgentOrchestrationRepository = AgentOrchestrationRepository(),
        packageVerification: @escaping @Sendable () -> Bool = AgentOrchestrationRuntime.verifyInstalledPackage,
        rolloutGate: @escaping @Sendable () -> Bool = AgentOrchestrationRuntime.defaultRolloutEnabled,
        killSwitch: @escaping @Sendable () -> Bool = AgentOrchestrationRuntime.defaultKillSwitch,
        now: @escaping @Sendable () -> Date = { Date() },
        costEstimator: (@Sendable (AgentOrchestrationAdmissionReceipt, AssistantTokenUsage?) -> Int?)? = nil,
        externalLeaseDuration: TimeInterval = AgentOrchestrationRuntime.defaultExternalLeaseDuration,
        processIsAlive: @escaping @Sendable (Int32) -> Bool = {
            AgentOrchestrationRuntime.defaultProcessIsAlive($0)
        }
    ) {
        self.repository = repository
        self.packageVerification = packageVerification
        self.rolloutGate = rolloutGate
        self.killSwitch = killSwitch
        self.now = now
        self.costEstimator = costEstimator
        self.externalLeaseDuration = max(1, externalLeaseDuration)
        self.processIsAlive = processIsAlive
        policyDigest = Self.sha256Hex(
            "\(Self.packageID)|\(Self.requiredPackageRevision)|\(Self.policyContractVersion)"
        )
    }

    /// Host answer to "is the provider still running this native subagent?".
    ///
    /// WHY: Distill ends its turn while its subagents keep running in the same
    /// process. A child whose parent turn ended is then still live, and only
    /// the provider session that runs it can say so. Called inside receipt
    /// transactions, so the answer must not take locks that wait on receipts.
    public func setProviderNativeChildLiveness(
        _ liveness: (@Sendable (AgentOrchestrationAdmissionReceipt) -> Bool)?
    ) {
        nativeChildLivenessLock.withLock { nativeChildLiveness = liveness }
    }

    /// A child the host recorded from the provider's own lifecycle events
    /// (`recordProviderNativeChild`). It carries no delegation authority.
    public static func isProviderNativeChild(_ receipt: AgentOrchestrationAdmissionReceipt) -> Bool {
        receipt.decisionReason == "external-controlled-child"
            && receipt.parentReceiptId != nil
            && receipt.delegationCapabilitySHA256 == nil
            && receipt.finalizationCapabilitySHA256 == nil
            && receipt.nodeId.hasPrefix("native.")
    }

    /// Records a native child the provider spawned after its parent turn ended:
    /// a background workflow moving on to its next phase. That turn's receipt
    /// is already finalized, so it is not required to be active. The child
    /// holds no delegation authority, and the provider session decides its
    /// liveness. Host-observed provider events only; never reachable over IPC.
    /// Returns nil when the parent turn is not on this thread's ledger.
    func recordProviderNativeChildOfEndedTurn(
        runId: AgentRunID,
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        nodeId: String,
        parentRunId: AgentRunID
    ) throws -> AgentOrchestrationAdmissionReceipt? {
        let trimmedNodeId = nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedNodeId.hasPrefix("native."),
              trimmedNodeId.utf8.count <= 128,
              trimmedNodeId.unicodeScalars.allSatisfy({ Self.safeNodeIdScalars.contains($0) }) else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission("node id must be a provider-native token")
        }
        do {
            return try repository.withReceiptMutation { () -> AgentOrchestrationAdmissionReceipt? in
                if let existing = try repository.receiptUnlocked(runId: runId) {
                    return existing.threadId == threadId && Self.isProviderNativeChild(existing) ? existing : nil
                }
                guard let parent = try repository.receiptUnlocked(runId: parentRunId),
                      parent.threadId == threadId else {
                    return nil
                }
                let admittedAt = now()
                let child = AgentOrchestrationAdmissionReceipt(
                    parentReceiptId: parent.id,
                    runId: runId,
                    threadId: threadId,
                    nodeId: trimmedNodeId,
                    attemptId: runId.value,
                    routingRevision: parent.routingRevision,
                    policyDigest: parent.policyDigest,
                    policyVersion: parent.policyVersion,
                    packageRevision: parent.packageRevision,
                    provider: provider,
                    providerInstanceId: providerInstanceId,
                    model: model,
                    reasoningEffort: nil,
                    capabilitySnapshotId: parent.capabilitySnapshotId,
                    decisionReason: "external-controlled-child",
                    admittedAt: admittedAt,
                    lifecycleStatus: .accepted,
                    deadlineAt: admittedAt.addingTimeInterval(externalLeaseDuration),
                    permissionMode: parent.permissionMode,
                    delegationCapabilitySHA256: nil,
                    finalizationCapabilitySHA256: nil,
                    ownerProcessID: ProcessInfo.processInfo.processIdentifier
                )
                try repository.appendAdmissionUnlocked(child)
                return child
            }
        } catch let error as AgentOrchestrationAdmissionError {
            throw error
        } catch {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed(String(describing: error))
        }
    }

    /// Records the provider's own report that a native child ended.
    ///
    /// Also applies to a child already demoted to `unknown`: the provider's
    /// report replaces the host's uncertainty. Host-observed provider events
    /// only, like `recordProviderNativeChild`; never reachable over IPC.
    func finalizeProviderNativeChild(
        runId: AgentRunID,
        threadId: AgentThreadID,
        status: AgentRunStatus
    ) throws {
        switch status {
        case .completed, .failed, .cancelled:
            break
        case .pending, .running, .interrupted:
            return
        }
        let reservationId = try repository.withReceiptMutation { () -> String? in
            guard let receipt = try repository.receiptUnlocked(runId: runId),
                  receipt.threadId == threadId,
                  Self.isProviderNativeChild(receipt),
                  receipt.lifecycleStatus != .finalized else {
                return nil
            }
            return try finalizeReceiptUnlocked(receipt, status: status, usage: nil, qualityOutcome: nil)
        }
        if let reservationId { releaseReservation(reservationId) }
    }

    /// Lookup the durable admission receipt for a run, if any.
    /// Used by host notification policy to suppress subagent push banners.
    public func admissionReceipt(for runId: AgentRunID) throws -> AgentOrchestrationAdmissionReceipt? {
        try repository.receipt(runId: runId)
    }

    public func autoConfiguration(
        replacing configuration: AgentRoutingConfiguration,
        expectedRevision: Int,
        manualSelection: AgentModelSelection,
        manualProviderInstanceId: String?,
        providerSnapshots: [AgentProviderSnapshot]
    ) throws -> AgentRoutingConfiguration {
        let candidate = try configuration.replacing(
            expectedRevision: expectedRevision,
            mode: .auto,
            manualSelection: manualSelection,
            manualProviderInstanceId: manualProviderInstanceId,
            eligibleProviders: configuration.eligibleProviders.isEmpty
                ? AgentProvider.selectable
                : configuration.eligibleProviders,
            policyDigest: policyDigest,
            updatedAt: now()
        )
        _ = try route(configuration: candidate, providerSnapshots: providerSnapshots)
        return candidate
    }

    public func manualConfiguration(
        replacing configuration: AgentRoutingConfiguration,
        expectedRevision: Int
    ) throws -> AgentRoutingConfiguration {
        try configuration.replacing(
            expectedRevision: expectedRevision,
            mode: .manual,
            manualSelection: configuration.manualSelection,
            manualProviderInstanceId: configuration.manualProviderInstanceId,
            eligibleProviders: configuration.eligibleProviders,
            policyDigest: configuration.policyDigest,
            updatedAt: now()
        )
    }

    public func admit(
        runId: AgentRunID,
        threadId: AgentThreadID,
        configuration: AgentRoutingConfiguration,
        providerSnapshots: [AgentProviderSnapshot],
        interactionMode: AgentInteractionMode,
        permissionMode: AgentPermissionMode,
        attachments: [AgentAttachment],
        nodeId: String = "root",
        attemptId: UUID? = nil,
        receiptId: UUID? = nil,
        deadlineAt: Date? = nil,
        budgetTokens: Int? = nil,
        budgetCostMicros: Int? = nil,
        reservationId: String? = nil,
        reservedTokens: Int? = nil,
        reservedCostMicros: Int? = nil,
        delegationCapabilitySHA256: String? = nil
    ) throws -> (route: AgentOrchestrationRoute, receipt: AgentOrchestrationAdmissionReceipt) {
        guard delegationCapabilitySHA256.map(Self.isSHA256) ?? true else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "delegation capability digest is invalid"
            )
        }
        let resolved = try route(configuration: configuration, providerSnapshots: providerSnapshots)
        guard budgetCostMicros == nil || costEstimator != nil else {
            throw AgentOrchestrationAdmissionError.costBudgetUnavailable
        }
        let snapshot = providerSnapshots.first { $0.id == resolved.providerInstanceId }
        try AgentProviderRunPreflight.validate(
            snapshot: snapshot,
            interactionMode: interactionMode,
            permissionMode: permissionMode,
            attachments: attachments
        )
        let receipt = AgentOrchestrationAdmissionReceipt(
            id: receiptId ?? UUID(),
            runId: runId,
            threadId: threadId,
            nodeId: nodeId,
            attemptId: attemptId ?? runId.value,
            routingRevision: configuration.revision,
            policyDigest: configuration.policyDigest,
            packageRevision: Self.requiredPackageRevision,
            provider: resolved.provider,
            providerInstanceId: resolved.providerInstanceId,
            model: resolved.selection.effectiveModel,
            reasoningEffort: resolved.selection.reasoningEffort,
            capabilitySnapshotId: resolved.capabilitySnapshotId,
            decisionReason: "preferred-source-then-live-eligible-provider",
            admittedAt: now(),
            lifecycleStatus: .accepted,
            deadlineAt: deadlineAt,
            budgetTokens: budgetTokens,
            budgetCostMicros: budgetCostMicros,
            reservationId: reservationId,
            reservedTokens: reservedTokens,
            reservedCostMicros: reservedCostMicros,
            permissionMode: permissionMode,
            delegationCapabilitySHA256: delegationCapabilitySHA256
        )
        let reservation = try reserveResources(
            receiptId: receipt.id,
            deadlineAt: deadlineAt,
            budgetTokens: budgetTokens,
            budgetCostMicros: budgetCostMicros,
            reservationId: reservationId,
            reservedTokens: reservedTokens,
            reservedCostMicros: reservedCostMicros
        )
        let admittedReceipt = AgentOrchestrationAdmissionReceipt(
            id: receipt.id,
            runId: receipt.runId,
            threadId: receipt.threadId,
            nodeId: receipt.nodeId,
            attemptId: receipt.attemptId,
            routingRevision: receipt.routingRevision,
            policyDigest: receipt.policyDigest,
            policyVersion: receipt.policyVersion,
            packageRevision: receipt.packageRevision,
            provider: receipt.provider,
            providerInstanceId: receipt.providerInstanceId,
            model: receipt.model,
            reasoningEffort: receipt.reasoningEffort,
            capabilitySnapshotId: receipt.capabilitySnapshotId,
            decisionReason: receipt.decisionReason,
            admittedAt: receipt.admittedAt,
            lifecycleStatus: receipt.lifecycleStatus,
            lifecycleUpdatedAt: receipt.lifecycleUpdatedAt,
            finalizedAt: receipt.finalizedAt,
            finalRunStatus: receipt.finalRunStatus,
            deadlineAt: receipt.deadlineAt,
            budgetTokens: receipt.budgetTokens,
            budgetCostMicros: receipt.budgetCostMicros,
            reservationId: reservation.id,
            reservedTokens: reservation.tokens,
            reservedCostMicros: reservation.costMicros,
            permissionMode: receipt.permissionMode,
            delegationCapabilitySHA256: receipt.delegationCapabilitySHA256
        )
        do {
            try repository.save(admittedReceipt)
        } catch let error as AgentOrchestrationAdmissionError {
            if let reservationId = reservation.id { releaseReservation(reservationId) }
            throw error
        } catch {
            if let reservationId = reservation.id { releaseReservation(reservationId) }
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed(String(describing: error))
        }
        return (resolved, admittedReceipt)
    }

    /// Records a provider-neutral nested worker under an already-admitted root.
    /// The controller must call this immediately before spawning the child and
    /// finalize the returned run id when that child exits. It intentionally
    /// shares the parent's route/capability decision and does not reserve a
    /// second root budget.
    func admitChild(
        parentReceipt: AgentOrchestrationAdmissionReceipt,
        runId: AgentRunID,
        nodeId: String,
        attemptId: UUID? = nil,
        threadId: AgentThreadID? = nil
    ) throws -> AgentOrchestrationAdmissionReceipt {
        let trimmedNodeId = nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNodeId.isEmpty,
              trimmedNodeId.caseInsensitiveCompare("root") != .orderedSame,
              trimmedNodeId.utf8.count <= 128,
              trimmedNodeId.unicodeScalars.allSatisfy({ Self.safeNodeIdScalars.contains($0) }) else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission("node id must be a non-root safe token")
        }
        do {
            return try repository.withReceiptMutation {
                guard let currentParent = try repository.receiptUnlocked(id: parentReceipt.id),
                      currentParent.lifecycleStatus == .accepted else {
                    throw AgentOrchestrationAdmissionError.invalidChildAdmission("parent is not active")
                }
                let admittedAt = now()
                if Self.isExternalReceipt(currentParent) {
                    try validateActiveReceipt(currentParent, at: admittedAt, role: "parent")
                } else if let deadline = currentParent.deadlineAt, deadline <= admittedAt {
                    throw AgentOrchestrationAdmissionError.invalidChildAdmission("parent deadline expired")
                }
                try validateActiveAncestors(of: currentParent, at: admittedAt)
                if let existing = try repository.receiptUnlocked(runId: runId) {
                    guard existing.parentReceiptId == currentParent.id,
                          existing.nodeId == trimmedNodeId else {
                        throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                            "run id already belongs to a different orchestration receipt"
                        )
                    }
                    return existing
                }
                let child = AgentOrchestrationAdmissionReceipt(
                    parentReceiptId: currentParent.id,
                    runId: runId,
                    threadId: threadId ?? currentParent.threadId,
                    nodeId: trimmedNodeId,
                    attemptId: attemptId ?? runId.value,
                    routingRevision: currentParent.routingRevision,
                    policyDigest: currentParent.policyDigest,
                    policyVersion: currentParent.policyVersion,
                    packageRevision: currentParent.packageRevision,
                    provider: currentParent.provider,
                    providerInstanceId: currentParent.providerInstanceId,
                    model: currentParent.model,
                    reasoningEffort: currentParent.reasoningEffort,
                    capabilitySnapshotId: currentParent.capabilitySnapshotId,
                    decisionReason: "controlled-child-of-parent",
                    admittedAt: admittedAt,
                    lifecycleStatus: .accepted,
                    deadlineAt: currentParent.deadlineAt,
                    permissionMode: currentParent.permissionMode
                )
                try repository.appendAdmissionUnlocked(child)
                return child
            }
        } catch let error as AgentOrchestrationAdmissionError {
            throw error
        } catch {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed(String(describing: error))
        }
    }

    /// Creates a delegating child only after proving possession of the active
    /// parent's bearer. The caller supplies a fresh child bearer; only its
    /// digest is persisted.
    public func recordAuthorizedExternalChild(
        runId: AgentRunID,
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        reasoningEffort: AgentReasoningEffort? = nil,
        nodeId: String,
        parentRunId: AgentRunID,
        parentThreadId: AgentThreadID,
        parentCapability: String,
        childCapability: String,
        requestedPermissionMode: AgentPermissionMode? = nil,
        ownerProcessID: Int32? = nil
    ) throws -> AgentOrchestrationAdmissionReceipt {
        guard AgentDelegationCapabilityTransport.isWellFormed(childCapability) else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "child delegation capability is invalid"
            )
        }
        return try recordExternalChild(
            runId: runId,
            threadId: threadId,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            reasoningEffort: reasoningEffort,
            nodeId: nodeId,
            parentRunId: parentRunId,
            parentThreadId: parentThreadId,
            parentCapability: parentCapability,
            childCapabilitySHA256: AgentDelegationCapability.sha256Hex(childCapability),
            finalizationCapabilitySHA256: nil,
            requestedPermissionMode: requestedPermissionMode,
            ownerProcessID: ownerProcessID,
            trustedProviderEvent: false
        )
    }

    /// Authenticated lifecycle-only bridge for custom non-provider workers.
    /// Its receipt intentionally has no child capability hash and therefore
    /// cannot authorize a grandchild.
    public func recordAuthenticatedTelemetryChild(
        runId: AgentRunID,
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        reasoningEffort: AgentReasoningEffort? = nil,
        nodeId: String,
        parentRunId: AgentRunID,
        parentThreadId: AgentThreadID,
        parentCapability: String,
        finalizationCapability: String,
        requestedPermissionMode: AgentPermissionMode? = nil,
        ownerProcessID: Int32? = nil
    ) throws -> AgentOrchestrationAdmissionReceipt {
        guard AgentDelegationCapabilityTransport.isWellFormed(
            finalizationCapability
        ) else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "finalization capability is invalid"
            )
        }
        return try recordExternalChild(
            runId: runId,
            threadId: threadId,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            reasoningEffort: reasoningEffort,
            nodeId: nodeId,
            parentRunId: parentRunId,
            parentThreadId: parentThreadId,
            parentCapability: parentCapability,
            childCapabilitySHA256: nil,
            finalizationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                finalizationCapability
            ),
            requestedPermissionMode: requestedPermissionMode,
            ownerProcessID: ownerProcessID,
            trustedProviderEvent: false
        )
    }

    /// Host-observed provider-native lifecycle never crosses IPC and never
    /// receives a delegation bearer. Keep this internal so provider proxies and
    /// local RPC cannot use it as an authorization bypass.
    func recordProviderNativeChild(
        runId: AgentRunID,
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        reasoningEffort: AgentReasoningEffort? = nil,
        nodeId: String,
        parentRunId: AgentRunID,
        requestedPermissionMode: AgentPermissionMode? = nil
    ) throws -> AgentOrchestrationAdmissionReceipt {
        try recordExternalChild(
            runId: runId,
            threadId: threadId,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            reasoningEffort: reasoningEffort,
            nodeId: nodeId,
            parentRunId: parentRunId,
            parentThreadId: threadId,
            parentCapability: nil,
            childCapabilitySHA256: nil,
            finalizationCapabilitySHA256: nil,
            requestedPermissionMode: requestedPermissionMode,
            ownerProcessID: nil,
            trustedProviderEvent: true
        )
    }

    private func recordExternalChild(
        runId: AgentRunID,
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        reasoningEffort: AgentReasoningEffort?,
        nodeId: String,
        parentRunId: AgentRunID,
        parentThreadId: AgentThreadID,
        parentCapability: String?,
        childCapabilitySHA256: String?,
        finalizationCapabilitySHA256: String?,
        requestedPermissionMode: AgentPermissionMode?,
        ownerProcessID: Int32?,
        trustedProviderEvent: Bool
    ) throws -> AgentOrchestrationAdmissionReceipt {
        let trimmedNodeId = nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNodeId.isEmpty,
              trimmedNodeId.caseInsensitiveCompare("root") != .orderedSame,
              trimmedNodeId.utf8.count <= 128,
              trimmedNodeId.unicodeScalars.allSatisfy({ Self.safeNodeIdScalars.contains($0) }) else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission("node id must be a non-root safe token")
        }
        let ownerPID = ownerProcessID ?? ProcessInfo.processInfo.processIdentifier
        guard ownerPID > 0 else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission("owner process id is invalid")
        }
        do {
            return try repository.withReceiptMutation {
                let admittedAt = now()
                guard let parent = try repository.receiptUnlocked(runId: parentRunId) else {
                    throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                        "parent receipt is unavailable"
                    )
                }
                try validateExternalParent(
                    parent,
                    expectedThreadId: parentThreadId,
                    at: admittedAt
                )
                if !trustedProviderEvent {
                    guard let parentCapability,
                          AgentDelegationCapability.matches(
                            parentCapability,
                            sha256Hex: parent.delegationCapabilitySHA256
                          ) else {
                        throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                            "parent delegation capability is invalid"
                        )
                    }
                }
                if let requestedPermissionMode,
                   !Self.isPermissionMode(
                    requestedPermissionMode,
                    noBroaderThan: parent.permissionMode
                   ) {
                    throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                        "child permission mode exceeds the parent"
                    )
                }
                let permissionMode = requestedPermissionMode ?? parent.permissionMode
                if let existing = try repository.receiptUnlocked(runId: runId) {
                    guard existing.threadId == threadId,
                          existing.provider == provider,
                          existing.parentReceiptId == parent.id,
                          existing.permissionMode == permissionMode,
                          existing.delegationCapabilitySHA256 == childCapabilitySHA256,
                          existing.finalizationCapabilitySHA256
                            == finalizationCapabilitySHA256,
                          existing.nodeId.caseInsensitiveCompare("root") != .orderedSame else {
                        throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                            "run id already belongs to a different orchestration receipt"
                        )
                    }
                    return existing
                }
                let child = AgentOrchestrationAdmissionReceipt(
                    parentReceiptId: parent.id,
                    runId: runId,
                    threadId: threadId,
                    nodeId: trimmedNodeId,
                    attemptId: runId.value,
                    routingRevision: parent.routingRevision,
                    policyDigest: parent.policyDigest,
                    policyVersion: parent.policyVersion,
                    packageRevision: parent.packageRevision,
                    provider: provider,
                    providerInstanceId: providerInstanceId,
                    model: model,
                    // Record only an effort carried by the child admission or
                    // provider event. Parent effort is not child-provider ack.
                    reasoningEffort: reasoningEffort,
                    capabilitySnapshotId: parent.capabilitySnapshotId,
                    decisionReason: "external-controlled-child",
                    admittedAt: admittedAt,
                    lifecycleStatus: .accepted,
                    deadlineAt: externalLeaseDeadline(parent: parent, at: admittedAt),
                    permissionMode: permissionMode,
                    delegationCapabilitySHA256: childCapabilitySHA256,
                    finalizationCapabilitySHA256: finalizationCapabilitySHA256,
                    ownerProcessID: ownerPID
                )
                try repository.appendAdmissionUnlocked(child)
                return child
            }
        } catch let error as AgentOrchestrationAdmissionError {
            throw error
        } catch {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed(String(describing: error))
        }
    }

    private static func isPermissionMode(
        _ requested: AgentPermissionMode,
        noBroaderThan parent: AgentPermissionMode
    ) -> Bool {
        func rank(_ mode: AgentPermissionMode) -> Int {
            switch mode {
            case .supervised: return 0
            case .autoAcceptEdits: return 1
            case .fullAccess: return 2
            }
        }
        return rank(requested) <= rank(parent)
    }

    private func validateExternalParent(
        _ parent: AgentOrchestrationAdmissionReceipt,
        expectedThreadId: AgentThreadID,
        at current: Date
    ) throws {
        guard parent.threadId == expectedThreadId else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "parent receipt belongs to a different thread"
            )
        }
        try validateActiveReceipt(parent, at: current, role: "parent")
        try validateActiveAncestors(of: parent, at: current)
    }

    private func validateActiveReceipt(
        _ receipt: AgentOrchestrationAdmissionReceipt,
        at current: Date,
        role: String
    ) throws {
        guard receipt.lifecycleStatus == .accepted else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "\(role) receipt is not active"
            )
        }
        if Self.isExternalReceipt(receipt) {
            guard effectiveExternalDeadline(receipt) > current else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "\(role) external lease expired"
                )
            }
            guard let ownerProcessID = receipt.ownerProcessID else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "\(role) owner process is unavailable"
                )
            }
            guard processIsAlive(ownerProcessID) else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "\(role) owner process is not alive"
                )
            }
        } else if let deadlineAt = receipt.deadlineAt, deadlineAt <= current {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "\(role) deadline expired"
            )
        }
    }

    private func validateActiveAncestors(
        of receipt: AgentOrchestrationAdmissionReceipt,
        at current: Date
    ) throws {
        var visited = Set([receipt.id])
        var descendant = receipt
        var depth = 0
        while let parentReceiptId = descendant.parentReceiptId {
            guard depth < Self.maximumReceiptAncestorDepth else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "receipt ancestry exceeds the supported depth"
                )
            }
            guard visited.insert(parentReceiptId).inserted else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "receipt ancestry is cyclic"
                )
            }
            guard let ancestor = try repository.receiptUnlocked(id: parentReceiptId) else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "ancestor receipt is unavailable"
                )
            }
            try validateActiveReceipt(ancestor, at: current, role: "ancestor")
            descendant = ancestor
            depth += 1
        }
    }

    private func externalLeaseDeadline(
        parent: AgentOrchestrationAdmissionReceipt?,
        at admittedAt: Date
    ) -> Date {
        let ownDeadline = admittedAt.addingTimeInterval(externalLeaseDuration)
        guard let parent else { return ownDeadline }
        let parentDeadline = Self.isExternalReceipt(parent)
            ? effectiveExternalDeadline(parent)
            : parent.deadlineAt
        return parentDeadline.map { min($0, ownDeadline) } ?? ownDeadline
    }

    private func effectiveExternalDeadline(_ receipt: AgentOrchestrationAdmissionReceipt) -> Date {
        receipt.deadlineAt ?? receipt.admittedAt.addingTimeInterval(externalLeaseDuration)
    }

    public static func isExternalReceipt(_ receipt: AgentOrchestrationAdmissionReceipt) -> Bool {
        receipt.decisionReason == "manual-agent-app-controller"
            || receipt.decisionReason == "external-controlled-child"
    }

    public static func defaultProcessIsAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Renews the bounded lease for a live external controller/worker.
    ///
    /// The owner process must call this before the current deadline; an expired
    /// receipt cannot be revived. Child leases never extend beyond their parent.
    @discardableResult
    public func renewExternalReceiptLease(
        runId: AgentRunID,
        ownerProcessID: Int32? = nil,
        leaseDuration: TimeInterval? = nil
    ) throws -> AgentOrchestrationAdmissionReceipt {
        let ownerPID = ownerProcessID ?? ProcessInfo.processInfo.processIdentifier
        let duration = leaseDuration ?? externalLeaseDuration
        guard ownerPID > 0, duration > 0 else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "external lease renewal is invalid"
            )
        }
        return try repository.withReceiptMutation {
            guard let receipt = try repository.receiptUnlocked(runId: runId),
                  receipt.lifecycleStatus == .accepted,
                  Self.isExternalReceipt(receipt) else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "external receipt is not active"
                )
            }
            guard receipt.ownerProcessID == ownerPID else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "external receipt owner does not match"
                )
            }
            let current = now()
            guard effectiveExternalDeadline(receipt) > current else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "external receipt lease expired"
                )
            }
            guard processIsAlive(ownerPID) else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "external receipt owner process is not alive"
                )
            }

            var renewedDeadline = current.addingTimeInterval(duration)
            if let parentReceiptId = receipt.parentReceiptId {
                guard let parent = try repository.receiptUnlocked(id: parentReceiptId) else {
                    throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                        "parent receipt is unavailable"
                    )
                }
                try validateExternalParent(
                    parent,
                    expectedThreadId: parent.threadId,
                    at: current
                )
                let parentDeadline = Self.isExternalReceipt(parent)
                    ? effectiveExternalDeadline(parent)
                    : parent.deadlineAt
                if let parentDeadline {
                    renewedDeadline = min(renewedDeadline, parentDeadline)
                }
            }
            let updatedAt = current > receipt.lifecycleUpdatedAt
                ? current
                : receipt.lifecycleUpdatedAt.addingTimeInterval(0.001)
            let renewed = receipt.renewingLease(
                deadlineAt: renewedDeadline,
                lifecycleUpdatedAt: updatedAt
            )
            try repository.appendLifecycleUnlocked(renewed)
            return renewed
        }
    }

    /// Ensures a manually-routed Agent App turn has a root receipt so a later
    /// cross-provider child can link to the controller's real run identity.
    ///
    /// Auto routing already persists the same run id through `admit`; this
    /// method is idempotent for that case and does not reserve a budget.
    func recordExternalRoot(
        runId: AgentRunID,
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        reasoningEffort: AgentReasoningEffort? = nil,
        permissionMode: AgentPermissionMode,
        delegationCapabilitySHA256: String,
        ownerProcessID: Int32? = nil
    ) throws -> AgentOrchestrationAdmissionReceipt {
        guard Self.isSHA256(delegationCapabilitySHA256) else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "delegation capability digest is invalid"
            )
        }
        let ownerPID = ownerProcessID ?? ProcessInfo.processInfo.processIdentifier
        guard ownerPID > 0 else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission("owner process id is invalid")
        }
        do {
            return try repository.withReceiptMutation {
                if let existing = try repository.receiptUnlocked(runId: runId) {
                    guard existing.threadId == threadId,
                          existing.provider == provider,
                          existing.lifecycleStatus == .accepted,
                          existing.permissionMode == permissionMode,
                          existing.delegationCapabilitySHA256 == delegationCapabilitySHA256 else {
                        throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                            "run id already belongs to a different orchestration receipt"
                        )
                    }
                    return existing
                }
                let admittedAt = now()
                let receipt = AgentOrchestrationAdmissionReceipt(
                    runId: runId,
                    threadId: threadId,
                    nodeId: "root",
                    attemptId: runId.value,
                    routingRevision: 0,
                    policyDigest: "external",
                    policyVersion: Self.policyContractVersion,
                    packageRevision: "external",
                    provider: provider,
                    providerInstanceId: providerInstanceId,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    capabilitySnapshotId: "external",
                    decisionReason: "manual-agent-app-controller",
                    admittedAt: admittedAt,
                    lifecycleStatus: .accepted,
                    deadlineAt: admittedAt.addingTimeInterval(externalLeaseDuration),
                    permissionMode: permissionMode,
                    delegationCapabilitySHA256: delegationCapabilitySHA256,
                    ownerProcessID: ownerPID
                )
                try repository.appendAdmissionUnlocked(receipt)
                return receipt
            }
        } catch let error as AgentOrchestrationAdmissionError {
            throw error
        } catch {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed(String(describing: error))
        }
    }

    /// Decision reason for telemetry-only bot-peer delegation rows. These
    /// receipts carry no capability digests, so per the receipt contract they
    /// can never authorize descendants — they exist so a delegated bot run
    /// appears in the host thread's Subagents panel with a real lifecycle.
    public static let botDelegationDecisionReason = "bot-peer-delegation"
    /// Backstop lease so a crash-orphaned bot receipt demotes to `.unknown`
    /// during reconciliation instead of claiming Working forever.
    public static let botDelegationLeaseDuration: TimeInterval = 4 * 60 * 60

    /// Records a telemetry-only receipt for a bot peer run consulted by a
    /// primary agent (`bot_ask_peer`). `threadId` is the HOST thread so the
    /// row scopes to the host's Subagents panel; `runId` is the peer's run so
    /// the coordinator's active set refines its Working phase. Idempotent for
    /// the same runId.
    @discardableResult
    public func recordBotDelegationTelemetry(
        runId: AgentRunID,
        hostThreadId: AgentThreadID,
        nodeId: String,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        reasoningEffort: AgentReasoningEffort? = nil,
        permissionMode: AgentPermissionMode
    ) throws -> AgentOrchestrationAdmissionReceipt {
        do {
            return try repository.withReceiptMutation {
                if let existing = try repository.receiptUnlocked(runId: runId) {
                    return existing
                }
                let admittedAt = now()
                let receipt = AgentOrchestrationAdmissionReceipt(
                    runId: runId,
                    threadId: hostThreadId,
                    nodeId: nodeId,
                    attemptId: runId.value,
                    routingRevision: 0,
                    policyDigest: "bot-delegation",
                    policyVersion: Self.policyContractVersion,
                    packageRevision: "bot-delegation",
                    provider: provider,
                    providerInstanceId: providerInstanceId,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    capabilitySnapshotId: "bot-delegation",
                    decisionReason: Self.botDelegationDecisionReason,
                    admittedAt: admittedAt,
                    lifecycleStatus: .accepted,
                    deadlineAt: admittedAt.addingTimeInterval(Self.botDelegationLeaseDuration),
                    permissionMode: permissionMode
                )
                try repository.appendAdmissionUnlocked(receipt)
                return receipt
            }
        } catch let error as AgentOrchestrationAdmissionError {
            throw error
        } catch {
            throw AgentOrchestrationAdmissionError.receiptPersistenceFailed(String(describing: error))
        }
    }

    /// Finalizes exactly one bot-delegation telemetry row by its receipt id.
    /// WHY: an auto-routed peer run can also gain a routing-admission receipt
    /// under the same runId; runId-keyed finalization would then pick one of
    /// the two arbitrarily and could leave the Subagents row Working. Guarded
    /// to bot-delegation rows so this API cannot finalize admission receipts.
    public func finalizeBotDelegationReceipt(id: UUID, status: AgentRunStatus) throws {
        let reservationId = try repository.withReceiptMutation { () -> String? in
            guard let receipt = try repository.receiptUnlocked(id: id),
                  receipt.decisionReason == Self.botDelegationDecisionReason else {
                return nil
            }
            return try finalizeReceiptUnlocked(receipt, status: status, usage: nil, qualityOutcome: nil)
        }
        if let reservationId { releaseReservation(reservationId) }
    }

    public func finalizeReceipt(
        runId: AgentRunID,
        status: AgentRunStatus,
        usage: AssistantTokenUsage? = nil,
        qualityOutcome: String? = nil
    ) throws {
        let reservationId = try repository.withReceiptMutation { () -> String? in
            guard let receipt = try repository.receiptUnlocked(runId: runId) else {
                return nil
            }
            return try finalizeReceiptUnlocked(
                receipt,
                status: status,
                usage: usage,
                qualityOutcome: qualityOutcome
            )
        }
        if let reservationId { releaseReservation(reservationId) }
    }

    /// Finalizes only the exact telemetry child represented by the opaque
    /// `subagent begin` handle and the parent orchestration scope inherited by
    /// the same external owner process.
    public func finalizeAuthenticatedExternalReceipt(
        runId: AgentRunID,
        status: AgentRunStatus,
        parentRunId: AgentRunID,
        parentThreadId: AgentThreadID,
        parentCapability: String,
        finalizationCapability: String,
        ownerProcessID: Int32? = nil
    ) throws {
        switch status {
        case .completed, .failed, .cancelled:
            break
        case .pending, .running, .interrupted:
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "external finalization status is not terminal"
            )
        }
        guard AgentDelegationCapabilityTransport.isWellFormed(parentCapability),
              AgentDelegationCapabilityTransport.isWellFormed(finalizationCapability) else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "external finalization capability is invalid"
            )
        }
        let ownerPID = ownerProcessID ?? ProcessInfo.processInfo.processIdentifier
        guard ownerPID > 0 else {
            throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                "external finalization owner is invalid"
            )
        }

        let reservationId = try repository.withReceiptMutation { () -> String? in
            guard let receipt = try repository.receiptUnlocked(runId: runId),
                  Self.isExternalReceipt(receipt),
                  receipt.decisionReason == "external-controlled-child",
                  receipt.nodeId.caseInsensitiveCompare("root") != .orderedSame,
                  let parentReceiptId = receipt.parentReceiptId,
                  receipt.lifecycleStatus == .accepted
                    || receipt.lifecycleStatus == .finalized,
                  receipt.delegationCapabilitySHA256 == nil,
                  AgentDelegationCapability.matches(
                    finalizationCapability,
                    sha256Hex: receipt.finalizationCapabilitySHA256
                  ) else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "external finalization receipt is invalid"
                )
            }
            guard receipt.ownerProcessID == ownerPID,
                  processIsAlive(ownerPID) else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "external finalization owner does not match"
                )
            }
            guard let parent = try repository.receiptUnlocked(id: parentReceiptId),
                  parent.runId == parentRunId,
                  parent.threadId == parentThreadId,
                  receipt.threadId == parentThreadId,
                  AgentDelegationCapability.matches(
                    parentCapability,
                    sha256Hex: parent.delegationCapabilitySHA256
                  ) else {
                throw AgentOrchestrationAdmissionError.invalidChildAdmission(
                    "external finalization parent context is invalid"
                )
            }
            return try finalizeReceiptUnlocked(
                receipt,
                status: status,
                usage: nil,
                qualityOutcome: nil
            )
        }
        if let reservationId { releaseReservation(reservationId) }
    }

    private func finalizeReceiptUnlocked(
        _ receipt: AgentOrchestrationAdmissionReceipt,
        status: AgentRunStatus,
        usage: AssistantTokenUsage?,
        qualityOutcome: String?
    ) throws -> String? {
        guard receipt.lifecycleStatus != .finalized else { return nil }
        let finalizedAt = now()
        let actualCostMicros = costEstimator?(receipt, usage)
        let finalized = receipt
            .updatingLifecycle(.finalized, finalRunStatus: status, at: finalizedAt)
            .updatingUsage(
                usage,
                latencyMilliseconds: Int64(
                    max(0, finalizedAt.timeIntervalSince(receipt.admittedAt) * 1_000)
                ),
                actualCostMicros: actualCostMicros,
                qualityOutcome: qualityOutcome
            )
        try repository.appendLifecycleUnlocked(finalized)
        let budgetOverrun = Self.budgetOutcome(
            budgetTokens: finalized.budgetTokens,
            actualTokens: finalized.actualTokens,
            budgetCostMicros: finalized.budgetCostMicros,
            actualCostMicros: finalized.actualCostMicros
        )
        try repository.appendLedgerUnlocked(
            AgentOrchestrationLedgerEntry(
                receipt: finalized,
                outcome: [status.rawValue, budgetOverrun].compactMap { $0 }.joined(separator: ":"),
                finalizedAt: finalizedAt
            )
        )
        return receipt.reservationId
    }

    /// Reconciles an authoritative provider snapshot that arrived after the
    /// terminal receipt was written. The lifecycle remains finalized; only
    /// positive usage/cost growth is persisted as a new append-only correction.
    ///
    /// - Returns: `true` when the receipt is already finalized (including when
    ///   the incoming snapshot adds no growth), or `false` when normal terminal
    ///   finalization still owns the receipt.
    @discardableResult
    public func enrichFinalizedReceiptUsage(
        runId: AgentRunID,
        usage: AssistantTokenUsage
    ) throws -> Bool {
        try repository.withReceiptMutation {
            guard let receipt = try repository.receiptUnlocked(runId: runId),
                  receipt.lifecycleStatus == .finalized else {
                return false
            }

            let actualTokens = max(receipt.actualTokens ?? 0, max(0, usage.totalTokens))
            let estimatedCost = costEstimator?(receipt, usage)
            let actualCostMicros: Int?
            if receipt.actualCostMicros != nil || estimatedCost != nil {
                actualCostMicros = max(receipt.actualCostMicros ?? 0, estimatedCost ?? 0)
            } else {
                actualCostMicros = nil
            }
            guard actualTokens > (receipt.actualTokens ?? 0)
                    || actualCostMicros != receipt.actualCostMicros else {
                return true
            }

            let observedAt = now()
            let updatedAt = observedAt > receipt.lifecycleUpdatedAt
                ? observedAt
                : receipt.lifecycleUpdatedAt.addingTimeInterval(0.001)
            let enrichedUsage = AssistantTokenUsage(
                totalTokens: actualTokens,
                reportedCostMicros: actualCostMicros,
                semantics: .cumulative
            )
            let enriched = receipt.updatingUsage(
                enrichedUsage,
                latencyMilliseconds: receipt.latencyMilliseconds ?? Int64(
                    max(0, updatedAt.timeIntervalSince(receipt.admittedAt) * 1_000)
                ),
                actualCostMicros: actualCostMicros,
                qualityOutcome: receipt.qualityOutcome,
                lifecycleUpdatedAt: updatedAt
            )
            try repository.appendLifecycleUnlocked(enriched)
            let budgetOverrun = Self.budgetOutcome(
                budgetTokens: enriched.budgetTokens,
                actualTokens: enriched.actualTokens,
                budgetCostMicros: enriched.budgetCostMicros,
                actualCostMicros: enriched.actualCostMicros
            )
            try repository.appendLedgerUnlocked(
                AgentOrchestrationLedgerEntry(
                    receipt: enriched,
                    outcome: [
                        enriched.finalRunStatus?.rawValue,
                        budgetOverrun
                    ].compactMap { $0 }.joined(separator: ":"),
                    finalizedAt: updatedAt
                )
            )
            return true
        }
    }

    /// First-route quality evidence is content-free: the runtime records
    /// whether a completed run produced a non-empty sanitized output.
    public static func qualityOutcome(status: AgentRunStatus, finalMessage: String?) -> String {
        guard status == .completed else { return "not-verified:\(status.rawValue)" }
        return finalMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? "verified:output-present"
            : "rejected:missing-output"
    }

    public static func budgetOutcome(
        budgetTokens: Int?,
        actualTokens: Int?,
        budgetCostMicros: Int?,
        actualCostMicros: Int?
    ) -> String? {
        if budgetCostMicros != nil && actualCostMicros == nil { return "budget-cost-unverified" }
        if let budgetTokens, let actualTokens, actualTokens > budgetTokens { return "budget-overrun" }
        if let budgetCostMicros, let actualCostMicros, actualCostMicros > budgetCostMicros {
            return "budget-overrun"
        }
        return nil
    }

    public static func productionCostEstimator(
        _: AgentOrchestrationAdmissionReceipt,
        usage: AssistantTokenUsage?
    ) -> Int? {
        usage?.reportedCostMicros
    }

    public func markReceiptUnknown(runId: AgentRunID) throws {
        let reservationId = try repository.withReceiptMutation { () -> String? in
            guard let receipt = try repository.receiptUnlocked(runId: runId),
                  receipt.lifecycleStatus == .accepted else { return nil }
            let updatedAt = now()
            let unknown = receipt.updatingLifecycle(.unknown, at: updatedAt)
            try repository.appendLifecycleUnlocked(unknown)
            try repository.appendLedgerUnlocked(
                AgentOrchestrationLedgerEntry(
                    receipt: unknown,
                    outcome: "unknown",
                    finalizedAt: updatedAt
                )
            )
            return receipt.reservationId
        }
        if let reservationId { releaseReservation(reservationId) }
    }

    public func reconcileReceipts(
        statusForRun: (AgentRunID) throws -> AgentRunStatus?,
        usageForRun: ((AgentRunID) throws -> AssistantTokenUsage?)? = nil,
        qualityOutcomeForRun: ((AgentRunID, AgentRunStatus) throws -> String?)? = nil
    ) throws {
        for receipt in try repository.receipts(limit: 500) where receipt.lifecycleStatus == .accepted {
            guard let runId = receipt.runId else { continue }
            switch try statusForRun(runId) {
            case .completed?:
                try finalizeReceipt(
                    runId: runId,
                    status: .completed,
                    usage: try usageForRun?(runId),
                    qualityOutcome: try qualityOutcomeForRun?(runId, .completed)
                )
            case .failed?:
                try finalizeReceipt(
                    runId: runId,
                    status: .failed,
                    usage: try usageForRun?(runId),
                    qualityOutcome: try qualityOutcomeForRun?(runId, .failed)
                )
            case .cancelled?:
                try finalizeReceipt(
                    runId: runId,
                    status: .cancelled,
                    usage: try usageForRun?(runId),
                    qualityOutcome: try qualityOutcomeForRun?(runId, .cancelled)
                )
            default: try markReceiptUnknown(runId: runId)
            }
        }
    }

    /// Default row window for activity/recent receipt reads (global or selected-thread).
    /// Was 10_000, then 500, then 256; now 128 to match session-map / compact agent windows.
    /// Nested workers use `defaultChildActivityReceiptLimit` (must stay below this).
    public static let defaultActivityReceiptLimit = 128

    /// Read-only recent admission receipts for activity surfaces (Subagents badge/panel).
    /// Newest `lifecycleUpdatedAt` first. Does not mutate ledger or lifecycle state.
    public func recentReceipts(
        limit: Int = AgentOrchestrationRuntime.defaultActivityReceiptLimit
    ) throws -> [AgentOrchestrationAdmissionReceipt] {
        try repository.receipts(limit: max(1, limit))
    }

    /// Keyed lookup for one run. Do not use `recentReceipts` and scan — Grok
    /// session_update is on the token hot path.
    public func receipt(runId: AgentRunID) throws -> AgentOrchestrationAdmissionReceipt? {
        try repository.receipt(runId: runId)
    }

    /// Default bound for nested-worker (`parentReceiptId`) rows in a thread-scoped
    /// activity fetch. Separate from the selected-thread window so children cannot
    /// starve the thread's own history (and vice versa). Must stay strictly below
    /// `defaultActivityReceiptLimit`. Was 2_000, then 256, then 128; now 64.
    public static let defaultChildActivityReceiptLimit = 64

    /// Bounded activity read used by the Subagents surface (global window).
    ///
    /// Accepted receipts are not durable proof that work remains active.
    /// Reconcile a dead owner, missing owner, expired deadline, or inactive
    /// ancestor to persisted `unknown` before returning the snapshot so every
    /// app process and subsequent launch observes the same honest state.
    /// The global default remains large enough for launch-style reconciliation.
    /// High-frequency UI polls use the thread-scoped overload and its bounded default.
    ///
    /// Prefer `activityReceipts(threadIds:limit:)` for the live badge poll — the
    /// global form still mutates every accepted row in the window and is kept
    /// for tests / launch-style full-window reconciliation.
    public func activityReceipts(
        limit: Int = 10_000,
        persistLifecycleReconciliation: Bool = true
    ) throws -> [AgentOrchestrationAdmissionReceipt] {
        try activityReceipts(
            scope: .global,
            limit: max(1, limit),
            persistLifecycleReconciliation: persistLifecycleReconciliation
        )
    }

    /// Thread-scoped activity read for the Subagents chrome badge.
    ///
    /// Fetches only the selected thread's rows plus a bounded nested-worker window,
    /// then reconciles **scoped** receipts only. Unrelated sibling-thread dead
    /// workers are intentionally not mutated here — they reconcile when that
    /// thread is selected, via the global path, or at launch-time reconciliation.
    ///
    /// Pass `persistLifecycleReconciliation: false` for the high-frequency UI poll:
    /// dead workers are projected as `.unknown` in memory only (no write lock, no
    /// ledger append). Periodic mutating calls still persist demotions.
    public func activityReceipts(
        threadIds: Set<AgentThreadID>,
        limit: Int = AgentOrchestrationRuntime.defaultActivityReceiptLimit,
        childRecordLimit: Int = AgentOrchestrationRuntime.defaultChildActivityReceiptLimit,
        persistLifecycleReconciliation: Bool = true
    ) throws -> [AgentOrchestrationAdmissionReceipt] {
        guard !threadIds.isEmpty else { return [] }
        return try activityReceipts(
            scope: .threads(threadIds, childRecordLimit: max(1, childRecordLimit)),
            limit: max(1, limit),
            persistLifecycleReconciliation: persistLifecycleReconciliation
        )
    }

    private enum ActivityReceiptScope {
        case global
        case threads(Set<AgentThreadID>, childRecordLimit: Int)
    }

    private func activityReceipts(
        scope: ActivityReceiptScope,
        limit: Int,
        persistLifecycleReconciliation: Bool
    ) throws -> [AgentOrchestrationAdmissionReceipt] {
        activityReceiptsThreadProbeForTesting.recordCurrentThread()
        // Nested function (not a stored closure) so the existing body can share
        // mutation vs read-only transaction wrappers without explicit `self.` noise.
        func loadBody() throws -> (receipts: [AgentOrchestrationAdmissionReceipt], reservationIds: [String]) {
            var receipts: [AgentOrchestrationAdmissionReceipt]
            let scopeThreadIds: Set<AgentThreadID>?
            switch scope {
            case .global:
                receipts = try repository.receiptsUnlocked(limit: limit)
                scopeThreadIds = nil
            case .threads(let threadIds, let childRecordLimit):
                receipts = try repository.receiptsUnlocked(
                    matchingThreadIds: threadIds,
                    limit: limit,
                    childRecordLimit: childRecordLimit
                )
                scopeThreadIds = threadIds
            }

            let current = now()
            var reservationIds: [String] = []
            var receiptByID = Dictionary(uniqueKeysWithValues: receipts.map { ($0.id, $0) })
            var fetchedParentIDs: Set<UUID> = []
            var missingParentIDs = Set(receipts.compactMap(\.parentReceiptId))
                .subtracting(receiptByID.keys)

            // Parent chains normally sit inside the fetched window.
            // If an older ancestor fell outside it, resolve all missing IDs in
            // one repository scan per hierarchy level rather than issuing one
            // lookup per child.
            while !missingParentIDs.isEmpty {
                fetchedParentIDs.formUnion(missingParentIDs)
                let fetched = try repository.receiptsUnlocked(ids: missingParentIDs)
                receiptByID.merge(fetched) { current, _ in current }
                // Also surface ancestors that were outside the primary fetch so
                // parent-chain membership and liveness walks stay complete.
                for parent in fetched.values where receiptByID[parent.id] != nil {
                    if !receipts.contains(where: { $0.id == parent.id }) {
                        receipts.append(parent)
                    }
                }
                missingParentIDs = Set(fetched.values.compactMap(\.parentReceiptId))
                    .subtracting(receiptByID.keys)
                    .subtracting(fetchedParentIDs)
            }

            // For thread-scoped reads: keep only ancestor-closed membership, and
            // never reconcile out-of-scope children fetched by the parentReceiptId
            // prefilter (incomplete parent view would wrongly demote live workers).
            let reconcileIndexes: [Int]
            if let scopeThreadIds {
                var scopeMemo: [UUID: Bool] = [:]
                func inScope(
                    _ receipt: AgentOrchestrationAdmissionReceipt,
                    visiting: Set<UUID> = []
                ) -> Bool {
                    if let cached = scopeMemo[receipt.id] { return cached }
                    if scopeThreadIds.contains(receipt.threadId) {
                        scopeMemo[receipt.id] = true
                        return true
                    }
                    guard let parentId = receipt.parentReceiptId,
                          !visiting.contains(receipt.id),
                          let parent = receiptByID[parentId] else {
                        scopeMemo[receipt.id] = false
                        return false
                    }
                    var next = visiting
                    next.insert(receipt.id)
                    let belongs = inScope(parent, visiting: next)
                    scopeMemo[receipt.id] = belongs
                    return belongs
                }

                var scopedIDs = Set<UUID>()
                for receipt in receipts where inScope(receipt) {
                    var cursor: AgentOrchestrationAdmissionReceipt? = receipt
                    var visiting = Set<UUID>()
                    while let current = cursor, visiting.insert(current.id).inserted {
                        scopedIDs.insert(current.id)
                        if let parentId = current.parentReceiptId {
                            cursor = receiptByID[parentId]
                        } else {
                            cursor = nil
                        }
                    }
                }
                receipts = receipts.filter { scopedIDs.contains($0.id) }
                // Rebuild indexes after the filter so reconcile walks the scoped array.
                receiptByID = Dictionary(uniqueKeysWithValues: receipts.map { ($0.id, $0) })
                reconcileIndexes = Array(receipts.indices)
            } else {
                reconcileIndexes = Array(receipts.indices)
            }

            let nativeChildIsLive = nativeChildLivenessLock.withLock { nativeChildLiveness }
            var activeMemo: [UUID: Bool] = [:]
            func isEffectivelyActive(
                _ receipt: AgentOrchestrationAdmissionReceipt,
                visiting: Set<UUID> = []
            ) -> Bool {
                if let cached = activeMemo[receipt.id] { return cached }
                guard receipt.lifecycleStatus == .accepted,
                      !visiting.contains(receipt.id) else {
                    activeMemo[receipt.id] = false
                    return false
                }
                let ownsLiveExecution: Bool
                if Self.isExternalReceipt(receipt) {
                    ownsLiveExecution = effectiveExternalDeadline(receipt) > current
                        && receipt.ownerProcessID.map(processIsAlive) == true
                } else {
                    ownsLiveExecution = receipt.deadlineAt.map { $0 > current } ?? true
                }
                guard ownsLiveExecution else {
                    activeMemo[receipt.id] = false
                    return false
                }
                guard let parentReceiptId = receipt.parentReceiptId else {
                    activeMemo[receipt.id] = true
                    return true
                }
                // Distill ends the parent turn while its subagents keep running;
                // the provider session running the child decides, not the parent.
                if Self.isProviderNativeChild(receipt), nativeChildIsLive?(receipt) == true {
                    activeMemo[receipt.id] = true
                    return true
                }
                guard let parent = receiptByID[parentReceiptId] else {
                    activeMemo[receipt.id] = false
                    return false
                }
                var nextVisiting = visiting
                nextVisiting.insert(receipt.id)
                let active = isEffectivelyActive(parent, visiting: nextVisiting)
                activeMemo[receipt.id] = active
                return active
            }

            for index in reconcileIndexes {
                let receipt = receipts[index]
                guard receipt.lifecycleStatus == .accepted,
                      !isEffectivelyActive(receipt) else { continue }

                let updatedAt = current > receipt.lifecycleUpdatedAt
                    ? current
                    : receipt.lifecycleUpdatedAt.addingTimeInterval(0.001)
                let unknown = receipt.updatingLifecycle(.unknown, at: updatedAt)
                if persistLifecycleReconciliation {
                    try repository.appendLifecycleUnlocked(unknown)
                    try repository.appendLedgerUnlocked(
                        AgentOrchestrationLedgerEntry(
                            receipt: unknown,
                            outcome: "unknown",
                            finalizedAt: updatedAt
                        )
                    )
                    if let reservationId = receipt.reservationId {
                        reservationIds.append(reservationId)
                    }
                }
                // Always project demoted state to the caller (badge + persistence path).
                receipts[index] = unknown
            }

            receipts.sort { $0.lifecycleUpdatedAt > $1.lifecycleUpdatedAt }
            return (receipts, reservationIds)
        }

        let result: (receipts: [AgentOrchestrationAdmissionReceipt], reservationIds: [String])
        if persistLifecycleReconciliation {
            result = try repository.withReceiptMutation { try loadBody() }
            for reservationId in result.reservationIds {
                releaseReservation(reservationId)
            }
        } else {
            // High-frequency badge poll: DEFERRED read lock only, no lifecycle writes.
            result = try repository.withReceiptRead { try loadBody() }
        }
        return result.receipts
    }

    /// Direct, untruncated lookup for host-side nested-run validation.
    ///
    /// External receipts are active only while accepted, within their lease,
    /// and owned by a live process. Auto receipts retain their explicit deadline
    /// semantics and do not require an external process owner.
    public func activeReceipt(
        runId: AgentRunID,
        threadId: AgentThreadID
    ) throws -> AgentOrchestrationAdmissionReceipt? {
        try repository.withReceiptMutation {
            guard let receipt = try repository.receiptUnlocked(runId: runId),
                  receipt.threadId == threadId else {
                return nil
            }
            do {
                let current = now()
                try validateActiveReceipt(receipt, at: current, role: "receipt")
                try validateActiveAncestors(of: receipt, at: current)
                return receipt
            } catch let error as AgentOrchestrationAdmissionError {
                if case .invalidChildAdmission = error {
                    return nil
                }
                throw error
            }
        }
    }

    /// Admission-only lookup that proves possession of the exact active
    /// receipt. Legacy and telemetry-only receipts have no digest and fail.
    public func activeReceipt(
        runId: AgentRunID,
        threadId: AgentThreadID,
        delegationCapability: String
    ) throws -> AgentOrchestrationAdmissionReceipt? {
        guard let receipt = try activeReceipt(runId: runId, threadId: threadId),
              AgentDelegationCapability.matches(
                delegationCapability,
                sha256Hex: receipt.delegationCapabilitySHA256
              ) else {
            return nil
        }
        return receipt
    }

    public func route(
        configuration: AgentRoutingConfiguration,
        providerSnapshots: [AgentProviderSnapshot]
    ) throws -> AgentOrchestrationRoute {
        guard rolloutGate() else { throw AgentOrchestrationAdmissionError.rolloutDisabled }
        guard !killSwitch() else { throw AgentOrchestrationAdmissionError.killSwitchEnabled }
        guard packageVerification() else { throw AgentOrchestrationAdmissionError.packageUnavailable }
        guard configuration.mode == .auto else { throw AgentOrchestrationAdmissionError.invalidRoutingMode }
        guard configuration.schemaVersion == AgentRoutingConfiguration.currentSchemaVersion,
              configuration.revision > 0,
              configuration.policyDigest == policyDigest,
              Self.isSHA256(configuration.policyDigest),
              !configuration.eligibleProviders.isEmpty else {
            throw AgentOrchestrationAdmissionError.invalidPolicy
        }

        // Source picker is the only host Auto may start. Never walk other
        // providers (Claude selected → must not become Codex). If that host is
        // not runnable, fail closed; the run coordinator may still fall back to
        // the same host on DEEP without orchestration — never another provider.
        let preferred = configuration.manualSelection.provider
        guard configuration.eligibleProviders.contains(preferred) else {
            throw AgentOrchestrationAdmissionError.preferredSourceUnavailable(
                preferred,
                detail: Self.preferredSourceUnavailabilityDetail(
                    provider: preferred,
                    preferredInstanceId: configuration.manualProviderInstanceId,
                    providerSnapshots: providerSnapshots
                )
            )
        }
        guard let snapshot = Self.autoAdmitSnapshot(
            provider: preferred,
            preferredInstanceId: configuration.manualProviderInstanceId,
            providerSnapshots: providerSnapshots,
            requireLiveCatalog: false
        ) else {
            throw AgentOrchestrationAdmissionError.preferredSourceUnavailable(
                preferred,
                detail: Self.preferredSourceUnavailabilityDetail(
                    provider: preferred,
                    preferredInstanceId: configuration.manualProviderInstanceId,
                    providerSnapshots: providerSnapshots
                )
            )
        }
        return Self.makeRoute(
            provider: preferred,
            snapshot: snapshot,
            selection: Self.lightControllerSelection(
                provider: preferred,
                availableModels: snapshot.models
            )
        )
    }

    /// Same-host DEEP binding when Auto cannot orchestrate (package/rollout/kill
    /// switch). Still never switches provider — only drops `$remote-code-orchestrate`
    /// and uses the host-matrix DEEP row (opus / sol / grok-4.7 high).
    public func routeDeepFallback(
        configuration: AgentRoutingConfiguration,
        providerSnapshots: [AgentProviderSnapshot]
    ) throws -> AgentOrchestrationRoute {
        guard configuration.mode == .auto else {
            throw AgentOrchestrationAdmissionError.invalidRoutingMode
        }
        let preferred = configuration.manualSelection.provider
        guard let snapshot = Self.autoAdmitSnapshot(
            provider: preferred,
            preferredInstanceId: configuration.manualProviderInstanceId,
            providerSnapshots: providerSnapshots,
            requireLiveCatalog: false
        ) else {
            throw AgentOrchestrationAdmissionError.preferredSourceUnavailable(
                preferred,
                detail: Self.preferredSourceUnavailabilityDetail(
                    provider: preferred,
                    preferredInstanceId: configuration.manualProviderInstanceId,
                    providerSnapshots: providerSnapshots
                )
            )
        }
        return Self.makeRoute(
            provider: preferred,
            snapshot: snapshot,
            selection: Self.deepControllerSelection(
                provider: preferred,
                availableModels: snapshot.models
            )
        )
    }

    private static func makeRoute(
        provider: AgentProvider,
        snapshot: AgentProviderSnapshot,
        selection: AgentModelSelection
    ) -> AgentOrchestrationRoute {
        AgentOrchestrationRoute(
            provider: provider,
            providerInstanceId: snapshot.id,
            capabilitySnapshotId: capabilitySnapshotID(snapshot),
            selection: selection
        )
    }

    /// Host key used by `remote-code-orchestrate` host-runtime-matrix.
    public static func orchestrateHostKey(for provider: AgentProvider) -> String {
        switch provider {
        case .codex: return "codex"
        case .claude: return "claude-code"
        case .grok: return "grok"
        case .distill: return "distill"
        }
    }

    /// Eligible provider walk order for Auto: preferred Source host first, then
    /// the remaining list in declared order (no duplicates).
    public static func orderedEligibleProviders(
        eligible: [AgentProvider],
        preferred: AgentProvider
    ) -> [AgentProvider] {
        var ordered: [AgentProvider] = []
        var seen = Set<AgentProvider>()
        if eligible.contains(preferred), seen.insert(preferred).inserted {
            ordered.append(preferred)
        }
        for provider in eligible where seen.insert(provider).inserted {
            ordered.append(provider)
        }
        return ordered
    }

    /// Snapshot eligible for Auto admission.
    /// - `requireLiveCatalog == true`: verified live catalog + streaming (fallback hosts).
    /// - `requireLiveCatalog == false`: runnable preferred Source host may use a
    ///   built-in catalog (Claude Code OAuth without Anthropic REST credentials).
    /// When `preferredInstanceId` is set, try that instance first so personal/work
    /// accounts stay sticky.
    /// Visible to AgentRunCoordinator and Agent App surface for same-host
    /// DEEP Auto fallback and pre-send admit checks.
    public static func autoAdmitSnapshot(
        provider: AgentProvider,
        preferredInstanceId: String?,
        providerSnapshots: [AgentProviderSnapshot],
        requireLiveCatalog: Bool
    ) -> AgentProviderSnapshot? {
        func isEligible(_ snapshot: AgentProviderSnapshot) -> Bool {
            guard snapshot.provider == provider,
                  AgentProviderRunnableSelection.isRunnable(snapshot),
                  !snapshot.models.isEmpty else { return false }
            if let caps = snapshot.capabilities, caps.supportsStreaming == false {
                return false
            }
            if requireLiveCatalog {
                return snapshot.modelDiscoverySource == .live
                    && snapshot.capabilities?.supportsStreaming == true
            }
            // Preferred Source: admit when runnable. Live catalog is ideal but
            // not required — Claude Code is often OAuth-only.
            return true
        }
        if let preferredInstanceId,
           let preferred = providerSnapshots.first(where: {
               $0.id == preferredInstanceId && isEligible($0)
           }) {
            return preferred
        }
        return providerSnapshots.first(where: isEligible)
    }

    /// Concrete reason the preferred Source cannot admit Auto — prefer the
    /// snapshot's statusDetail (install / auth / models) so the UI can recover.
    /// When `runAsUser` is a foreign macOS account, mention it: Claude may be
    /// installed under the app owner (e.g. airtonjunior) while the user capsule
    /// targets another account (e.g. airtonempat) whose ~/.claude is unsigned.
    public static func preferredSourceUnavailabilityDetail(
        provider: AgentProvider,
        preferredInstanceId: String?,
        providerSnapshots: [AgentProviderSnapshot],
        runAsUser: AgentRunAsUser? = nil
    ) -> String? {
        let snapshot = AgentProviderSnapshotSelection.resolve(
            snapshots: providerSnapshots,
            provider: provider,
            instanceId: preferredInstanceId
        ) ?? providerSnapshots.first(where: { $0.provider == provider })
        guard let snapshot else {
            return "\(provider.rawValue.capitalized) is not available in the provider list on this Mac"
        }
        let foreignUser: String? = {
            guard let runAsUser, runAsUser.uid != getuid() else { return nil }
            let name = runAsUser.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }()
        let binaryHomeOwner = homeOwnerFromPath(snapshot.binaryPath)
        let mismatchHint: String? = {
            guard let foreignUser else { return nil }
            if let owner = binaryHomeOwner, owner != foreignUser {
                return "CLI is under \(owner) but run-as-user is \(foreignUser) — switch the user capsule to \(owner) or install/sign in as \(foreignUser)"
            }
            return "for macOS user \(foreignUser)"
        }()
        func withMismatch(_ base: String) -> String {
            guard let mismatchHint else { return base }
            let trimmed = base.hasSuffix(".") ? String(base.dropLast()) : base
            return "\(trimmed) — \(mismatchHint)"
        }

        if let detail = snapshot.statusDetail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty {
            if mismatchHint != nil, !detail.localizedCaseInsensitiveContains("run-as-user") {
                return withMismatch(detail)
            }
            return detail
        }
        if !snapshot.installed {
            return withMismatch("\(snapshot.displayName) CLI binary is unavailable")
        }
        if snapshot.models.isEmpty {
            return "\(snapshot.displayName) CLI models are unavailable"
        }
        if snapshot.authenticated == false {
            return withMismatch("\(snapshot.displayName) is not authenticated. Sign in to continue")
        }
        if let caps = snapshot.capabilities, caps.supportsStreaming == false {
            return "\(snapshot.displayName) does not support streaming on this Mac"
        }
        if !AgentProviderRunnableSelection.isRunnable(snapshot) {
            return "\(snapshot.displayName) is not runnable (\(snapshot.status.rawValue))"
        }
        return nil
    }

    /// `/Users/<shortName>/...` → shortName. Used only for recovery copy.
    public static func homeOwnerFromPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // ["", "Users", "airtonjunior", ".local", ...]
        guard parts.count >= 3, parts[1] == "Users" else { return nil }
        let owner = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? nil : owner
    }

    /// Back-compat alias: live-catalog gate only (non-preferred fallback hosts).
    static func liveRunnableSnapshot(
        provider: AgentProvider,
        preferredInstanceId: String?,
        providerSnapshots: [AgentProviderSnapshot]
    ) -> AgentProviderSnapshot? {
        autoAdmitSnapshot(
            provider: provider,
            preferredInstanceId: preferredInstanceId,
            providerSnapshots: providerSnapshots,
            requireLiveCatalog: true
        )
    }

    /// Skill name / package ID used for Auto invocation (`$remote-code-orchestrate`).
    public static let orchestrateSkillInvocationName =
        AgentSkillInstaller.remoteCodeOrchestratePinnedPackage.skillID

    /// Prefix every Auto provider prompt so the controller always runs
    /// `$remote-code-orchestrate`. Idempotent when the skill is already invoked
    /// (still injects the host receipt once when missing).
    ///
    /// The host binds provider/model before spawn — pass that receipt so the
    /// skill does not re-detect the host (which caused "I'm Codex" while the
    /// UI showed Claude). Do not split the skill per provider.
    public static func autoOrchestrateProviderPrompt(
        userPrompt: String,
        admittedRoute: AgentOrchestrationRoute? = nil
    ) -> String {
        let skill = orchestrateSkillInvocationName
        let hostBlock: String
        if let route = admittedRoute {
            let host = orchestrateHostKey(for: route.provider)
            let effort = route.selection.reasoningEffort.rawValue
            hostBlock = """
            Host runtime receipt (authoritative — do not re-detect, do not claim another host):
            - active_host: \(host)
            - provider: \(route.provider.rawValue)
            - provider_instance_id: \(route.providerInstanceId)
            - controller_model: \(route.selection.effectiveModel)
            - controller_effort: \(effort)
            - Bind every worker/reviewer from host-runtime-matrix.md row for active_host=\(host) only.
            """
        } else {
            hostBlock = """
            Host runtime receipt: not supplied by host; detect active host once from this session only.
            """
        }

        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.promptAlreadyInvokesOrchestrateSkill(trimmed) {
            if admittedRoute != nil, trimmed.contains("active_host:") {
                return userPrompt
            }
            if admittedRoute != nil {
                return """
                \(trimmed)

                \(hostBlock)
                """
            }
            return userPrompt
        }
        return """
        $\(skill)

        Auto is on. Run $\(skill) controller-only, token-efficient:
        - FIRST: Micro chat bypass — if the request is only conversational (who are you, hi, which model/LLM, trivial status) and does not ask for code/files/commands/PR/deploy/repo change → answer on the controller in one short reply; no workers, no DAG, no validator, no matrix load.
        - Otherwise classify T0–T3 + certainty (absolute|high|medium|low); pick Micro/Single/Multi/Critical.
        - Progressive disclosure: load only the skill sections needed for that mode; requested/returned skill content must stay complete.
        - Controller stays LIGHT; escalate workers only after capability failure.
        - Fan-out default 2 / hard cap 3; skip REVIEWER on micro absolute/high certainty when rules allow.
        - Thin prompts (slice-only); cheap proof (scope diff + one focused command); lean table report.

        \(hostBlock)

        User request:
        \(userPrompt)
        """
    }

    public static func promptAlreadyInvokesOrchestrateSkill(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "$" || first == "/" else { return false }
        let body = trimmed.dropFirst()
        let token = body.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        return token == orchestrateSkillInvocationName.lowercased()
    }

    /// LIGHT controller binding from `host-runtime-matrix.md`.
    public static func lightControllerSelection(
        provider: AgentProvider,
        availableModels: [AgentModelDescriptor]
    ) -> AgentModelSelection {
        let binding = lightMatrixBinding(for: provider)
        let providerModels = availableModels.filter { $0.provider == provider }
        // Claude's catalog also contains legacy Sonnet families whose effort
        // flag is unsupported. They cannot satisfy the LIGHT reasoning
        // contract even though their ids fuzzy-match the current alias.
        let selectableModels = provider == .claude
            ? providerModels.filter { !$0.supportedReasoningEfforts.isEmpty }
            : providerModels
        let selectedId: String
        if let exact = binding.preferredModelIds.first(where: { preferred in
            !preferred.isEmpty && selectableModels.contains(where: { $0.id == preferred })
        }) {
            selectedId = exact
        } else if let fuzzy = binding.preferredModelIds.first(where: { preferred in
            guard !preferred.isEmpty else { return false }
            let needle = preferred.lowercased()
            return selectableModels.contains {
                let id = $0.id.lowercased()
                return id == needle || id.hasPrefix(needle) || id.contains(needle)
            }
        }),
           let match = selectableModels.first(where: {
               let id = $0.id.lowercased()
               let needle = fuzzy.lowercased()
               return id == needle || id.hasPrefix(needle) || id.contains(needle)
           }) {
            selectedId = match.id
        } else {
            // Force the matrix LIGHT id even when the live catalog omitted it so
            // Auto never falls back to a DEEP/default model on the controller.
            selectedId = binding.preferredModelIds.first(where: { !$0.isEmpty })
                ?? selectableModels.first(where: { !$0.id.isEmpty })?.id
                ?? ""
        }
        let selectedDescriptor = selectableModels.first { $0.id == selectedId }
        let effort: AgentReasoningEffort
        if let selectedDescriptor,
           !selectedDescriptor.supportedReasoningEfforts.isEmpty,
           !selectedDescriptor.supportedReasoningEfforts.contains(binding.effort) {
            effort = selectedDescriptor.supportedReasoningEfforts.contains(.medium)
                ? .medium
                : (selectedDescriptor.supportedReasoningEfforts.first ?? binding.effort)
        } else {
            effort = binding.effort
        }
        return AgentModelSelection(
            provider: provider,
            modelId: selectedId,
            reasoningEffort: effort,
            serviceTier: .auto
        )
    }

    /// Preferred model ids in matrix order, then fallbacks when a host catalog
    /// renames aliases (e.g. dated Haiku ids).
    public static func lightMatrixBinding(for provider: AgentProvider) -> (preferredModelIds: [String], effort: AgentReasoningEffort) {
        switch provider {
        case .codex:
            return (["gpt-5.6-luna", "gpt-5.4-mini", "gpt-5.5"], .medium)
        case .claude:
            // LIGHT still requires observable reasoning; Haiku has no effort control.
            return (["sonnet", "claude-sonnet", "claude-sonnet-5", "claude-sonnet-4-6"], .high)
        case .grok:
            return (["grok-4.7", "grok-4.6", "grok-4.5"], .medium)
        case .distill:
            return ([], .medium)
        }
    }

    /// DEEP (non-orchestrated Auto fallback) binding — same host only.
    /// Codex → sol/high, Claude → opus/high, Grok → grok-4.7/high.
    public static func deepMatrixBinding(for provider: AgentProvider) -> (preferredModelIds: [String], effort: AgentReasoningEffort) {
        switch provider {
        case .codex:
            return (["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.5"], .high)
        case .claude:
            return (["opus", "claude-opus", "claude-4-opus", "claude-3-opus"], .high)
        case .grok:
            return (["grok-4.7", "grok-4.6", "grok-4.5"], .high)
        case .distill:
            return ([], .high)
        }
    }

    /// DEEP controller selection when Auto skips `$remote-code-orchestrate`.
    public static func deepControllerSelection(
        provider: AgentProvider,
        availableModels: [AgentModelDescriptor]
    ) -> AgentModelSelection {
        let binding = deepMatrixBinding(for: provider)
        let providerModels = availableModels.filter { $0.provider == provider }
        let selectedId: String
        if let exact = binding.preferredModelIds.first(where: { preferred in
            !preferred.isEmpty && providerModels.contains(where: { $0.id == preferred })
        }) {
            selectedId = exact
        } else if let fuzzy = binding.preferredModelIds.first(where: { preferred in
            guard !preferred.isEmpty else { return false }
            let needle = preferred.lowercased()
            return providerModels.contains {
                let id = $0.id.lowercased()
                return id == needle || id.hasPrefix(needle) || id.contains(needle)
            }
        }),
           let match = providerModels.first(where: {
               let id = $0.id.lowercased()
               let needle = fuzzy.lowercased()
               return id == needle || id.hasPrefix(needle) || id.contains(needle)
           }) {
            selectedId = match.id
        } else {
            selectedId = binding.preferredModelIds.first(where: { !$0.isEmpty })
                ?? providerModels.first(where: { !$0.id.isEmpty })?.id
                ?? ""
        }
        let selectedDescriptor = providerModels.first { $0.id == selectedId }
        let effort: AgentReasoningEffort
        if let selectedDescriptor,
           !selectedDescriptor.supportedReasoningEfforts.isEmpty,
           !selectedDescriptor.supportedReasoningEfforts.contains(binding.effort) {
            effort = selectedDescriptor.supportedReasoningEfforts.contains(.high)
                ? .high
                : (selectedDescriptor.supportedReasoningEfforts.last ?? binding.effort)
        } else {
            effort = binding.effort
        }
        return AgentModelSelection(
            provider: provider,
            modelId: selectedId,
            reasoningEffort: effort,
            serviceTier: .auto
        )
    }

    public static func defaultPackageURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteCode/AgentSkills", isDirectory: true)
            .appendingPathComponent(packageID, isDirectory: true)
    }

    public static func verifyInstalledPackage() -> Bool {
        verifyInstalledPackage(at: defaultPackageURL())
    }

    // PERF: every Auto admission package gate allocated JSONDecoder with
    // iso8601 date strategy. Share one process-wide decoder under a short
    // lock (JSONDecoder is not thread-safe; concurrent admissions can verify)
    // so package gate checks avoid per-call codec construction.
    private static let packageManifestDecodeLock = NSLock()
    private static let packageManifestDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func verifyInstalledPackage(at packageURL: URL) -> Bool {
        let pinned = AgentSkillInstaller.remoteCodeOrchestratePinnedPackage
        let canonicalPackageURL = packageURL.standardizedFileURL
        let manifestURL = canonicalPackageURL.appendingPathComponent(
            AgentSkillInstaller.remoteCodeOrchestrateManifestName
        )
        guard isRegularFileWithoutSymlink(manifestURL),
              isDirectoryWithoutSymlink(canonicalPackageURL),
              let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe) else {
            return false
        }
        packageManifestDecodeLock.lock()
        let decodedManifest = try? packageManifestDecoder.decode(
            RemoteCodeOrchestrateManifest.self,
            from: data
        )
        packageManifestDecodeLock.unlock()
        guard let manifest = decodedManifest else { return false }
        // Single map feeds both the sorted-allowlist compare and the
        // duplicate-path check below; contents identical to two maps.
        let manifestPaths = manifest.files.map(\.relativePath)
        guard manifest.schemaVersion == 1,
              manifest.managedBy == "RemoteCode",
              manifest.skillID == pinned.skillID,
              manifest.sourceURL == pinned.sourceURL,
              manifest.sourceRevision == pinned.sourceRevision,
              manifest.sourceTreeSHA256 == pinned.sourceTreeSHA256,
              manifest.localVersion == pinned.localVersion,
              URL(fileURLWithPath: manifest.installPath, isDirectory: true).standardizedFileURL == canonicalPackageURL,
              manifestPaths.sorted() == pinned.allowedPaths,
              Set(manifestPaths).count == manifest.files.count,
              AgentSkillInstaller.remoteCodeOrchestrateTreeDigest(manifest.files) == manifest.sourceTreeSHA256 else {
            return false
        }

        let root = canonicalPackageURL.path + "/"
        for file in manifest.files {
            guard isSafeRelativePath(file.relativePath),
                  file.byteCount >= 0,
                  isSHA256(file.sha256) else { return false }
            let fileURL = canonicalPackageURL.appendingPathComponent(file.relativePath).standardizedFileURL
            guard fileURL.path.hasPrefix(root),
                  isRegularFileWithoutSymlink(fileURL),
                  let fileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                  fileData.count == file.byteCount,
                  sha256Hex(fileData) == file.sha256.lowercased() else { return false }
        }
        return containsOnlyInstallerOwnedEntries(
            packageURL: canonicalPackageURL,
            filePaths: Set(manifest.files.map(\.relativePath))
        )
    }

    public static func defaultKillSwitch() -> Bool {
        UserDefaults.standard.bool(forKey: "agent.orchestration.kill-switch")
    }

    public static func defaultRolloutEnabled() -> Bool {
        // Auto is opt-out: only an explicit false preference disables the rollout.
        (UserDefaults.standard.object(forKey: rolloutFlagKey) as? Bool) ?? true
    }

    private func reserveResources(
        receiptId: UUID,
        deadlineAt: Date?,
        budgetTokens: Int?,
        budgetCostMicros: Int?,
        reservationId requestedReservationId: String?,
        reservedTokens: Int?,
        reservedCostMicros: Int?
    ) throws -> (id: String?, tokens: Int?, costMicros: Int?) {
        let current = now()
        if let deadlineAt, deadlineAt <= current { throw AgentOrchestrationAdmissionError.deadlineExpired }
        guard budgetTokens == nil || budgetTokens! > 0,
              budgetCostMicros == nil || budgetCostMicros! > 0,
              reservedTokens == nil || reservedTokens! > 0,
              reservedCostMicros == nil || reservedCostMicros! > 0,
              reservedTokens == nil || budgetTokens == nil || reservedTokens! <= budgetTokens!,
              reservedCostMicros == nil || budgetCostMicros == nil || reservedCostMicros! <= budgetCostMicros! else {
            throw AgentOrchestrationAdmissionError.invalidBudget
        }
        guard budgetTokens != nil || budgetCostMicros != nil || requestedReservationId == nil else {
            throw AgentOrchestrationAdmissionError.invalidBudget
        }
        guard budgetTokens != nil || budgetCostMicros != nil else {
            return (requestedReservationId, reservedTokens, reservedCostMicros)
        }
        let id = requestedReservationId ?? "orchestration-\(receiptId.uuidString)"
        reservationLock.lock()
        defer { reservationLock.unlock() }
        if let existing = reservations[id] {
            guard existing.tokens == reservedTokens, existing.costMicros == reservedCostMicros, existing.deadlineAt == deadlineAt else {
                throw AgentOrchestrationAdmissionError.quotaExceeded
            }
            return (id, existing.tokens, existing.costMicros)
        }
        guard reservations.count < Self.maxConcurrentReservations else {
            throw AgentOrchestrationAdmissionError.quotaExceeded
        }
        let tokens = reservedTokens ?? budgetTokens
        let costMicros = reservedCostMicros ?? budgetCostMicros
        reservations[id] = (tokens, costMicros, deadlineAt)
        return (id, tokens, costMicros)
    }

    private func releaseReservation(_ id: String) {
        reservationLock.lock()
        reservations.removeValue(forKey: id)
        reservationLock.unlock()
    }

    // PERF: Auto/orchestrate route builds fingerprint `effectiveCapabilities`
    // on every makeRoute. JSONEncoder is not thread-safe — share one sortedKeys
    // encoder under a short lock so concurrent route resolution avoids per-call
    // codec allocation (capabilitySnapshotId digests stay identical).
    private static let capabilityFingerprintEncodeLock = NSLock()
    private static let capabilityFingerprintEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func capabilitySnapshotID(_ snapshot: AgentProviderSnapshot) -> String {
        let modelIDs = snapshot.models.map(\.id).joined(separator: ",")
        let capabilityFingerprint: String = {
            capabilityFingerprintEncodeLock.lock()
            defer { capabilityFingerprintEncodeLock.unlock() }
            return (try? capabilityFingerprintEncoder.encode(snapshot.effectiveCapabilities))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "unavailable"
        }()
        let discoverySource = snapshot.modelDiscoverySource?.rawValue ?? "unknown"
        return sha256Hex(
            "\(snapshot.id)|\(snapshot.driverKind.rawValue)|\(snapshot.version ?? "")|\(modelIDs)|\(snapshot.modelDiscoveryCacheKey ?? "")|\(discoverySource)|\(capabilityFingerprint)"
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasSuffix("/") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func containsOnlyInstallerOwnedEntries(
        packageURL: URL,
        filePaths: Set<String>
    ) -> Bool {
        let optionalRuntimeManifest = AgentSkillInstaller.remoteCodeOrchestrateRuntimeManifestName
        let allowedFiles = filePaths.union([
            AgentSkillInstaller.remoteCodeOrchestrateManifestName,
            optionalRuntimeManifest
        ])
        let allowedDirectories = Set(filePaths.flatMap { path in
            let components = path.split(separator: "/").dropLast()
            return components.indices.map { index in
                components.prefix(index + 1).joined(separator: "/")
            }
        })
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else { return false }
        let root = packageURL.path + "/"
        for case let item as URL in enumerator {
            let standardized = item.standardizedFileURL
            guard standardized.path.hasPrefix(root) else { return false }
            let relativePath = String(standardized.path.dropFirst(root.count))
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { return false }
            if values.isDirectory == true {
                guard allowedDirectories.contains(relativePath) else { return false }
            } else {
                guard values.isRegularFile == true, allowedFiles.contains(relativePath) else { return false }
            }
        }
        return true
    }

    private static func sha256Hex(_ value: String) -> String {
        sha256Hex(Data(value.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        AgentDelegationCapability.hexDigest(SHA256.hash(data: data))
    }
}

/// Counts `activityReceipts` calls by thread. MainActor hits are the freeze-class hang.
public final class ActivityReceiptsThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadCalls = 0
    private var backgroundCalls = 0

    public init() {}

    public func recordCurrentThread() {
        let isMain = Thread.isMainThread
        lock.lock()
        if isMain {
            mainThreadCalls += 1
        } else {
            backgroundCalls += 1
        }
        lock.unlock()
    }

    public var mainThreadCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return mainThreadCalls
    }

    public var backgroundCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return backgroundCalls
    }

    public func reset() {
        lock.lock()
        mainThreadCalls = 0
        backgroundCalls = 0
        lock.unlock()
    }
}
