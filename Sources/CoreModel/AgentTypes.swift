import CryptoKit
import Foundation

public enum AgentPermissionMode: String, Codable, Sendable, CaseIterable {
    case supervised
    case autoAcceptEdits = "auto_accept_edits"
    case fullAccess = "full_access"

    /// Human label for composer chips and menus. One string so Agent App and
    /// Bots Desk cannot drift ("Auto-edit" vs "Auto-accept edits").
    public var displayName: String {
        switch self {
        case .supervised: return "Supervised"
        case .autoAcceptEdits: return "Auto-edit"
        case .fullAccess: return L("Full access")
        }
    }

    public var pickerHelpText: String {
        switch self {
        case .supervised: return L("Ask before tool actions")
        case .autoAcceptEdits: return L("Apply edits without asking")
        case .fullAccess: return L("Run tools without asking")
        }
    }
}

public enum AgentReasoningEffort: String, Codable, Sendable, CaseIterable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    /// Codex app-server / model-catalog wire value (codex-cli 0.154+). Distinct
    /// from Claude-only `ultracode`.
    case ultra
    case ultracode

    public static var supportedCases: [AgentReasoningEffort] {
        [.low, .medium, .high, .xhigh]
    }

    /// `supportedCases` is the conservative provider-neutral fallback. Live
    /// Codex catalogs may expose `max` and `ultra` for specific models; callers
    /// with that observable model contract should preserve them rather than
    /// using this list.
    /// `ultracode` remains Claude-only and is not Codex's distinct `ultra` value.
    /// Claude Code 2.1.203+ accepts it as a native effort selector meaning
    /// "xhigh effort + standing dynamic workflow orchestration"; RemoteCode also
    /// carries the equivalent settings contract for CLI/SDK consistency.
    public static var claudeSupportedCases: [AgentReasoningEffort] {
        [.low, .medium, .high, .xhigh, .max, .ultracode]
    }

    /// Human label for menus. `xhigh` is shown as "Extra High" to match
    /// the Codex CLI's effort picker.
    public var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        case .ultra: return "Ultra"
        case .ultracode: return "Ultracode"
        }
    }

    public var pickerHelpText: String {
        switch self {
        case .minimal: return L("Fastest — minimal reasoning")
        case .low: return L("Light reasoning for simple tasks")
        case .medium: return L("Balanced reasoning (default)")
        case .high: return L("Deeper reasoning for harder tasks")
        case .xhigh: return L("Very deep reasoning for hard problems")
        case .max: return L("Deepest reasoning the model supports — slowest, most tokens")
        case .ultra: return L("Codex ultra reasoning — beyond max for supported models")
        case .ultracode: return L("Extra High effort + autonomous workflow orchestration")
        }
    }
}

/// Current provider-advertised Grok reasoning contract shared by the primary
/// runtime and nested CLI middleware. Keeping normalization in CoreModel avoids
/// the two launch paths silently emitting different, unsupported wire values.
public enum GrokReasoningPolicy {
    /// Static fallback for Grok 4.6 when ACP discovery is unavailable.
    /// Live grok 1.0.25 advertises `low|medium|high|xhigh` on model `_meta`
    /// (no `minimal`). Prefer discovered `supportedReasoningEfforts` when present.
    public static let grok46Efforts: [AgentReasoningEffort] = [.low, .medium, .high, .xhigh]
    public static let grok45Efforts: [AgentReasoningEffort] = [.low, .medium, .high]
    /// Live grok 1.0.30 GLM catalog aliases `medium→high` and `xhigh→max`.
    /// Keep alias ids selectable so medium is not clamped to max.
    public static let glm53Efforts: [AgentReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
    /// Live grok 1.0.30 muse-spark accepts low/medium/high/xhigh (rejects max)
    /// even when `_meta.reasoningEfforts` is omitted.
    public static let museSparkEfforts: [AgentReasoningEffort] = [.low, .medium, .high, .xhigh]

    public static func supportedEfforts(for model: String) -> [AgentReasoningEffort] {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Live grok 1.0.41 default is grok-4.7; grok-build lists the same
        // low|medium|high|xhigh menu as grok-4.6. The build-fast sibling is a
        // non-reasoning lane and must fail closed instead of inheriting xhigh.
        if id.hasPrefix("grok-4.7-build-fast") { return [] }
        if id.isEmpty || id.hasPrefix("grok-4.7") || id.hasPrefix("grok-4.6") {
            return grok46Efforts
        }
        if id.hasPrefix("grok-4.5") { return grok45Efforts }
        if id == "glm-5.3" || id.hasPrefix("glm-5.3-") { return glm53Efforts }
        if id.hasPrefix("muse-spark") { return museSparkEfforts }
        if id.hasPrefix("qwen38") { return [] }
        if id.hasPrefix("grok-composer") { return [] }
        // A custom/future model has no observable reasoning contract. Fail
        // closed instead of guessing that it inherits a known model's limits.
        return []
    }

    public static func normalizedEffort(
        _ effort: AgentReasoningEffort,
        model: String
    ) -> AgentReasoningEffort {
        let supported = supportedEfforts(for: model)
        guard let deepest = supported.last else { return .medium }
        switch effort {
        case .minimal:
            if supported.contains(.minimal) { return .minimal }
            return supported.contains(.low) ? .low : (supported.first ?? deepest)
        case .low, .medium, .high, .xhigh:
            return supported.contains(effort) ? effort : deepest
        case .max, .ultra, .ultracode:
            return deepest
        }
    }
}

public enum AgentInteractionMode: String, Codable, Sendable, CaseIterable {
    case `default`
    case plan
}

public enum AgentExecutionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case worktree
}

public enum AgentServiceTier: String, Codable, Sendable, Equatable, CaseIterable {
    case auto
    case fast
}

public enum AgentAttachmentKind: String, Codable, Sendable, Equatable, Hashable {
    case file
    case image
}

public struct AgentProviderCapabilities: Codable, Sendable, Equatable {
    public let supportsAttachments: Bool
    public let supportedAttachmentKinds: [AgentAttachmentKind]
    public let supportedAttachmentMediaTypes: [String]
    public let supportsApprovals: Bool
    public let supportsUserInput: Bool
    public let supportsStreaming: Bool
    public let supportsFork: Bool
    public let supportsRollback: Bool
    public let supportsPlanReview: Bool
    public let supportsDistillMainEffortAuto: Bool
    public let supportsDistillReasoningModelEffort: Bool

    public init(
        supportsAttachments: Bool = false,
        supportedAttachmentKinds: [AgentAttachmentKind] = [],
        supportedAttachmentMediaTypes: [String] = [],
        supportsApprovals: Bool = false,
        supportsUserInput: Bool = false,
        supportsStreaming: Bool = false,
        supportsFork: Bool = false,
        supportsRollback: Bool = false,
        supportsPlanReview: Bool = false,
        supportsDistillMainEffortAuto: Bool = false,
        supportsDistillReasoningModelEffort: Bool = false
    ) {
        self.supportsAttachments = supportsAttachments
        self.supportedAttachmentKinds = supportedAttachmentKinds
        self.supportedAttachmentMediaTypes = supportedAttachmentMediaTypes
        self.supportsApprovals = supportsApprovals
        self.supportsUserInput = supportsUserInput
        self.supportsStreaming = supportsStreaming
        self.supportsFork = supportsFork
        self.supportsRollback = supportsRollback
        self.supportsPlanReview = supportsPlanReview
        self.supportsDistillMainEffortAuto = supportsDistillMainEffortAuto
        self.supportsDistillReasoningModelEffort = supportsDistillReasoningModelEffort
    }

    public static let conservative = AgentProviderCapabilities()

    private enum CodingKeys: String, CodingKey {
        case supportsAttachments, supportedAttachmentKinds, supportedAttachmentMediaTypes
        case supportsApprovals, supportsUserInput, supportsStreaming
        case supportsFork, supportsRollback, supportsPlanReview
        case supportsDistillMainEffortAuto, supportsDistillReasoningModelEffort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportsAttachments = try container.decodeIfPresent(Bool.self, forKey: .supportsAttachments) ?? false
        supportedAttachmentKinds = try container.decodeIfPresent([AgentAttachmentKind].self, forKey: .supportedAttachmentKinds) ?? []
        supportedAttachmentMediaTypes = try container.decodeIfPresent([String].self, forKey: .supportedAttachmentMediaTypes) ?? []
        supportsApprovals = try container.decodeIfPresent(Bool.self, forKey: .supportsApprovals) ?? false
        supportsUserInput = try container.decodeIfPresent(Bool.self, forKey: .supportsUserInput) ?? false
        supportsStreaming = try container.decodeIfPresent(Bool.self, forKey: .supportsStreaming) ?? false
        supportsFork = try container.decodeIfPresent(Bool.self, forKey: .supportsFork) ?? false
        supportsRollback = try container.decodeIfPresent(Bool.self, forKey: .supportsRollback) ?? false
        supportsPlanReview = try container.decodeIfPresent(Bool.self, forKey: .supportsPlanReview) ?? false
        supportsDistillMainEffortAuto = try container.decodeIfPresent(Bool.self, forKey: .supportsDistillMainEffortAuto) ?? false
        supportsDistillReasoningModelEffort = try container.decodeIfPresent(Bool.self, forKey: .supportsDistillReasoningModelEffort) ?? false
    }
}

public struct AgentAttachment: Codable, Sendable, Equatable, Hashable {
    public let id: String?
    public let path: String
    public let displayName: String
    public let kind: AgentAttachmentKind
    public let mimeType: String?
    public let sha256: String?
    public let sizeBytes: Int?

    public init(
        id: String? = nil,
        path: String,
        displayName: String? = nil,
        kind: AgentAttachmentKind,
        mimeType: String? = nil,
        sha256: String? = nil,
        sizeBytes: Int? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.kind = kind
        self.mimeType = mimeType
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

/// Path-free attachment metadata safe to expose to paired clients. `id` is an
/// opaque host-owned attachment-reference identifier; clients must return it unchanged and
/// never receive or manufacture the provider-visible host path.
public struct AgentAttachmentReference: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let kind: AgentAttachmentKind
    public let mimeType: String?
    public let sha256: String
    public let sizeBytes: Int

    public init(
        id: String,
        displayName: String,
        kind: AgentAttachmentKind,
        mimeType: String?,
        sha256: String,
        sizeBytes: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.mimeType = mimeType
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    public init?(_ attachment: AgentAttachment) {
        guard let id = attachment.id ?? attachment.sha256,
              let sha256 = attachment.sha256 ?? Self.legacyDigest(id),
              let sizeBytes = attachment.sizeBytes else { return nil }
        self.init(
            id: id,
            displayName: attachment.displayName,
            kind: attachment.kind,
            mimeType: attachment.mimeType,
            sha256: sha256,
            sizeBytes: sizeBytes
        )
    }

    private static func legacyDigest(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy(\.isHexDigit) else { return nil }
        return normalized
    }
}

public struct AgentAttachmentUploadResult: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let kind: AgentAttachmentKind
    public let mimeType: String?
    public let sha256: String
    public let sizeBytes: Int
    /// Absolute host path for paired clients to insert into composer text
    /// (macOS drag/drop parity). Not a structured-attachment wire field.
    public let composerInsertionText: String

    public init(
        id: String,
        displayName: String,
        kind: AgentAttachmentKind,
        mimeType: String?,
        sha256: String,
        sizeBytes: Int,
        composerInsertionText: String
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.mimeType = mimeType
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.composerInsertionText = composerInsertionText
    }

    public init(_ reference: AgentAttachmentReference, composerInsertionText: String) {
        self.init(
            id: reference.id,
            displayName: reference.displayName,
            kind: reference.kind,
            mimeType: reference.mimeType,
            sha256: reference.sha256,
            sizeBytes: reference.sizeBytes,
            composerInsertionText: composerInsertionText
        )
    }
}

public enum AgentAttachmentResolverError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case notReadableFile(String)
    case exceedsMaximumSize(String, Int)
    case malformedReference(String)

    public var description: String {
        switch self {
        case .notFound(let path): return L("Attachment not found: %1$@", path)
        case .notReadableFile(let path): return L("Attachment is not a readable file: %1$@", path)
        case .exceedsMaximumSize(let name, let maximumBytes):
            return L("Attachment exceeds the %1$@-byte limit: %2$@", maximumBytes, name)
        case .malformedReference(let value): return L("Malformed attachment reference: %1$@", value)
        }
    }
}

public enum AgentAttachmentResolver {
    public static func resolve(paths: [String], fileManager: FileManager = .default) throws -> [AgentAttachment] {
        var seen = Set<String>()
        var resolved: [AgentAttachment] = []
        for raw in paths {
            let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard !expanded.isEmpty else { continue }
            let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw AgentAttachmentResolverError.notFound(raw)
            }
            guard !isDirectory.boolValue, fileManager.isReadableFile(atPath: url.path) else {
                throw AgentAttachmentResolverError.notReadableFile(raw)
            }
            guard seen.insert(url.path).inserted else { continue }
            resolved.append(AgentAttachment(
                path: url.path,
                displayName: url.lastPathComponent,
                kind: imageExtensions.contains(url.pathExtension.lowercased()) ? .image : .file,
                mimeType: mimeType(forExtension: url.pathExtension.lowercased())
            ))
        }
        return resolved
    }

    private static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg", "avif"])

    private static func mimeType(forExtension ext: String) -> String? {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "avif": return "image/avif"
        case "txt", "log", "csv", "swift", "m", "mm", "h", "c", "cc", "cpp", "js", "ts", "tsx", "jsx", "css", "html", "xml", "yaml", "yml": return "text/plain"
        case "md", "markdown": return "text/markdown"
        case "json": return "application/json"
        case "pdf": return "application/pdf"
        default: return nil
        }
    }
}

/// Distill session execution mode: exactly one is active per session.
/// Wire values match `_x.ai/session/execution_mode/set`.
public enum DistillExecutionMode: String, Sendable, CaseIterable, Equatable, Hashable {
    case auto
    case normal
    case ultrafast
    case ultracode
    case ultrasave

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .normal: return "Normal"
        case .ultrafast: return "Ultrafast"
        case .ultracode: return "Ultracode"
        case .ultrasave: return "Ultrasave"
        }
    }

    public var pickerHelpText: String {
        switch self {
        case .auto: return L("Distill picks the best mode for each step, balancing quality, time and cost")
        case .normal: return L("Standard behavior: plans, delegates and verifies as needed")
        case .ultrafast: return L("Direct execution and parallel independent work")
        case .ultracode: return L("Plan, fan out to parallel subagents, then integrate and verify")
        case .ultrasave: return L("Prioritize token economy with direct-work tools only")
        }
    }

    /// Integer kept in `scheduled_tasks.distill_ultracode`. 1 keeps the legacy Ultracode meaning; the legacy
    /// default 0 now reads as Auto, so an explicit Normal is stored as 5.
    public var storageValue: Int {
        switch self {
        case .ultracode: return 1
        case .ultrafast: return 2
        case .ultrasave: return 3
        case .auto: return 4
        case .normal: return 5
        }
    }

    public init(storageValue: Int) {
        switch storageValue {
        case 1: self = .ultracode
        case 2: self = .ultrafast
        case 3: self = .ultrasave
        case 5: self = .normal
        default: self = .auto
        }
    }
}

/// Ultracode persists as the legacy Bool `true`; every other mode persists as its wire string. A legacy
/// `false` (the old default) decodes to Auto, matching Distill's own legacy migration.
extension DistillExecutionMode: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let legacy = try? container.decode(Bool.self) {
            self = legacy ? .ultracode : .auto
            return
        }
        let raw = try container.decode(String.self)
        guard let mode = DistillExecutionMode(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown Distill execution mode \(raw)")
        }
        self = mode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ultracode: try container.encode(true)
        case .auto, .normal, .ultrafast, .ultrasave: try container.encode(rawValue)
        }
    }
}

public struct AgentEffortSelection: Codable, Sendable, Equatable, Hashable {
    /// Nil means Auto; a value pins an advertised effort level.
    public var effort: AgentReasoningEffort?

    public init(effort: AgentReasoningEffort? = nil) {
        self.effort = effort
    }

    public static let automatic = AgentEffortSelection()
    public static func fixed(_ effort: AgentReasoningEffort) -> AgentEffortSelection {
        AgentEffortSelection(effort: effort)
    }

    public var isAutomatic: Bool { effort == nil }

    public func normalized(
        for supportedEfforts: [AgentReasoningEffort],
        supportsAutomatic: Bool = true
    ) -> Self {
        // Empty discovery results do not establish which efforts a model supports.
        guard !supportedEfforts.isEmpty else { return self }
        guard let effort, !supportedEfforts.contains(effort) else { return self }
        if supportsAutomatic { return .automatic }
        return .fixed(supportedEfforts.contains(.high) ? .high : supportedEfforts[0])
    }

    /// Pill/menu label: the pinned effort name, or Auto when unset.
    public var pickerDisplayName: String { effort?.displayName ?? "Auto" }
}

public struct AgentModelSelection: Codable, Sendable, Equatable, Hashable {
    public var provider: AgentProvider
    public var modelId: String
    public var customModelId: String?
    public var reasoningEffort: AgentReasoningEffort
    public var serviceTier: AgentServiceTier
    /// Nil preserves legacy Distill threads, which used `reasoningEffort` as Main effort.
    public var distillMainEffortSelection: AgentEffortSelection?
    /// Nil means Auto for a selected Reasoning model and Off when no model is selected.
    public var distillReasoningEffortSelection: AgentEffortSelection?
    /// Distill session-level Ultracode orchestration mode; independent of effort.
    public var distillExecutionMode: DistillExecutionMode

    public var effectiveModel: String {
        let custom = customModelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? modelId : custom
    }

    public init(
        provider: AgentProvider,
        modelId: String,
        customModelId: String? = nil,
        reasoningEffort: AgentReasoningEffort = .medium,
        serviceTier: AgentServiceTier = .auto,
        distillMainEffortSelection: AgentEffortSelection? = nil,
        distillReasoningEffortSelection: AgentEffortSelection? = nil,
        distillExecutionMode: DistillExecutionMode = .auto
    ) {
        self.provider = provider
        self.modelId = modelId
        self.customModelId = customModelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.distillMainEffortSelection = distillMainEffortSelection
        self.distillReasoningEffortSelection = distillReasoningEffortSelection
        self.distillExecutionMode = distillExecutionMode
    }

    private enum CodingKeys: String, CodingKey {
        case provider, modelId, customModelId, reasoningEffort, serviceTier
        case distillMainEffortSelection, distillReasoningEffortSelection
        case distillExecutionMode = "distillUltracode"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        modelId = try c.decode(String.self, forKey: .modelId)
        customModelId = try c.decodeIfPresent(String.self, forKey: .customModelId)
        reasoningEffort = try c.decode(AgentReasoningEffort.self, forKey: .reasoningEffort)
        serviceTier = try c.decode(AgentServiceTier.self, forKey: .serviceTier)
        distillMainEffortSelection = try c.decodeIfPresent(AgentEffortSelection.self, forKey: .distillMainEffortSelection)
        distillReasoningEffortSelection = try c.decodeIfPresent(AgentEffortSelection.self, forKey: .distillReasoningEffortSelection)
        distillExecutionMode = try c.decodeIfPresent(DistillExecutionMode.self, forKey: .distillExecutionMode) ?? .auto
    }
}

public enum AgentRoutingMode: String, Codable, Sendable, Equatable, CaseIterable {
    case manual
    case auto
}

public enum AgentRoutingRevisionError: Error, Sendable, Equatable {
    case conflict(expected: Int, actual: Int)
}

/// Thread-owned model-routing state. The manual selection remains authoritative
/// while Auto is enabled so turning Auto off restores every picker value exactly.
public struct AgentRoutingConfiguration: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var mode: AgentRoutingMode
    public var manualSelection: AgentModelSelection
    public var manualProviderInstanceId: String?
    public var eligibleProviders: [AgentProvider]
    public var policyDigest: String
    public var revision: Int
    public var updatedAt: Date

    public init(
        schemaVersion: Int = AgentRoutingConfiguration.currentSchemaVersion,
        mode: AgentRoutingMode,
        manualSelection: AgentModelSelection,
        manualProviderInstanceId: String? = nil,
        eligibleProviders: [AgentProvider] = AgentProvider.selectable,
        policyDigest: String = "",
        revision: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.manualSelection = manualSelection
        self.manualProviderInstanceId = manualProviderInstanceId
        self.eligibleProviders = eligibleProviders
        self.policyDigest = policyDigest
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public static func legacyManual(
        selection: AgentModelSelection,
        providerInstanceId: String? = nil,
        updatedAt: Date = Date()
    ) -> AgentRoutingConfiguration {
        AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: selection,
            manualProviderInstanceId: providerInstanceId,
            updatedAt: updatedAt
        )
    }

    public func replacing(
        expectedRevision: Int,
        mode: AgentRoutingMode,
        manualSelection: AgentModelSelection,
        manualProviderInstanceId: String?,
        eligibleProviders: [AgentProvider],
        policyDigest: String,
        updatedAt: Date = Date()
    ) throws -> AgentRoutingConfiguration {
        guard expectedRevision == revision else {
            throw AgentRoutingRevisionError.conflict(expected: expectedRevision, actual: revision)
        }
        return AgentRoutingConfiguration(
            schemaVersion: schemaVersion,
            mode: mode,
            manualSelection: manualSelection,
            manualProviderInstanceId: manualProviderInstanceId,
            eligibleProviders: eligibleProviders,
            policyDigest: policyDigest,
            revision: revision + 1,
            updatedAt: updatedAt
        )
    }
}

public enum AgentRunAcceptanceError: Error, LocalizedError, Sendable {
    case cancelled

    public var errorDescription: String? {
        L("Provider start was cancelled before prompt acceptance.")
    }
}

public enum AgentRunAcceptanceOutcome: Sendable, Equatable {
    case notAccepted
    case accepted
    case unknown
}

/// Completion for a provider write that already claimed its acceptance permit.
/// Invalidation never waits on provider I/O; destructive callers may await this
/// object asynchronously after issuing provider stop.
public final class AgentRunAcceptanceAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    fileprivate init() {}

    public func wait() async {
        if lock.withLock({ isComplete }) { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard !isComplete else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    fileprivate func complete() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isComplete else { return [] }
            isComplete = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

/// Linearizes a queued dispatch's final cancellation check with the provider's
/// actual prompt write without holding a lock across provider I/O. A claimed
/// write linearizes before later invalidation; destructive flows then stop and
/// await that provider instead of blocking the MainActor on a pipe write.
public final class AgentRunAcceptancePermit: @unchecked Sendable {
    private enum State {
        case pending
        case invalidated
        case claimed(AgentRunAcceptanceAttempt)
        case accepted
        case unknown
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var invalidationHandlers: [@Sendable () -> Void] = []

    public init() {}

    @discardableResult
    public func invalidate() -> AgentRunAcceptanceAttempt? {
        let (attempt, handlers) = lock.withLock { () -> (AgentRunAcceptanceAttempt?, [@Sendable () -> Void]) in
            if case .pending = state {
                state = .invalidated
                defer { invalidationHandlers = [] }
                return (nil, invalidationHandlers)
            }
            if case .claimed(let attempt) = state {
                return (attempt, [])
            }
            return (nil, [])
        }
        handlers.forEach { $0() }
        return attempt
    }

    /// Runs `handler` once if the permit is invalidated before anything claims
    /// it (Stop while the start is still preparing), at once when it already
    /// is. Never runs once a prompt write claimed or was accepted: work that
    /// must stop with the start (a long launch preparation) cancels itself here.
    public func onInvalidate(_ handler: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            switch state {
            case .pending:
                invalidationHandlers.append(handler)
                return false
            case .invalidated:
                return true
            case .claimed, .accepted, .unknown:
                return false
            }
        }
        if runNow { handler() }
    }

    public var outcome: AgentRunAcceptanceOutcome {
        lock.withLock {
            switch state {
            case .pending, .invalidated:
                return .notAccepted
            case .accepted:
                return .accepted
            case .claimed, .unknown:
                return .unknown
            }
        }
    }

    public func withAcceptance<T>(
        failureOutcome: AgentRunAcceptanceOutcome = .unknown,
        _ body: () throws -> T
    ) throws -> T {
        let attempt = try lock.withLock { () throws -> AgentRunAcceptanceAttempt in
            guard case .pending = state else {
                throw AgentRunAcceptanceError.cancelled
            }
            let attempt = AgentRunAcceptanceAttempt()
            state = .claimed(attempt)
            invalidationHandlers = []
            return attempt
        }
        defer { attempt.complete() }
        do {
            let result = try body()
            lock.withLock { state = .accepted }
            return result
        } catch {
            lock.withLock {
                state = failureOutcome == .notAccepted ? .invalidated : .unknown
            }
            throw error
        }
    }
}

public struct AgentRunRequest: Codable, Sendable, Equatable {
    public let runId: AgentRunID
    public let threadId: AgentThreadID
    public let provider: AgentProvider
    public let providerInstanceId: String?
    public let model: String
    public let cwd: String
    public let prompt: String
    public let userMessageContent: String?
    public let attachments: [AgentAttachment]
    public let providerThreadId: String?
    public let permissionMode: AgentPermissionMode
    public let reasoningEffort: AgentReasoningEffort?
    /// Resolved per-conversation selection. Nil explicitly disables Reasoning.
    public let reasoningModel: String?
    /// Distill role-specific effort choices. Nil preserves legacy request behavior.
    public let distillMainEffortSelection: AgentEffortSelection?
    public let distillReasoningEffortSelection: AgentEffortSelection?
    /// Distill Ultracode mode for this turn's session.
    public let distillExecutionMode: DistillExecutionMode
    public let serviceTier: AgentServiceTier
    public let interactionMode: AgentInteractionMode
    public let providerBinary: String?
    public let environment: [String: String]
    public let extraArgs: [String]
    public let runAsUser: AgentRunAsUser?
    /// Runtime-only queue dispatch gate. Intentionally excluded from Codable and
    /// value equality; it has no meaning outside the current host process.
    public var acceptancePermit: AgentRunAcceptancePermit?
    /// Canonical prior conversation captured before provider start. Runtime-only.
    public var contextSnapshot: ConversationContextSnapshot?
    /// Prepared RCSEED1 document for a confirmed fresh-fallback destination.
    public var preparedContextSeed: PreparedConversationContextSeed?
    /// Main model of the last prompt the persisted provider session
    /// (`providerThreadId`) accepted. Runtime-only. Lets Distill detect a
    /// cross-family Main switch when it must `session/load` that session after
    /// an app restart.
    public var priorProviderSessionModel: String?
    /// The provider rejected the persisted session's history. Runtime-only.
    /// Distill opens a new session instead of loading it, after a restart too.
    public var priorProviderSessionRetired: Bool = false
    /// Newest prior user/assistant messages, oldest first, excluding the current
    /// prompt. Runtime-only. Set only when Distill must replace the provider
    /// session; unlike `contextSnapshot` it has no all-or-nothing size limit, so
    /// a long thread still hands its most recent context to the new session.
    public var priorConversationTail: [AgentMessage]?
    /// Provider-initiated turn (Distill `/loop` wake) to adopt instead of sending a prompt. Runtime-only.
    public var attachToProviderPromptId: String?

    public init(
        runId: AgentRunID = AgentRunID(),
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String? = nil,
        model: String,
        cwd: String,
        prompt: String,
        userMessageContent: String? = nil,
        attachments: [AgentAttachment] = [],
        providerThreadId: String? = nil,
        permissionMode: AgentPermissionMode = .supervised,
        reasoningEffort: AgentReasoningEffort? = nil,
        reasoningModel: String? = nil,
        distillMainEffortSelection: AgentEffortSelection? = nil,
        distillReasoningEffortSelection: AgentEffortSelection? = nil,
        distillExecutionMode: DistillExecutionMode = .auto,
        serviceTier: AgentServiceTier = .auto,
        interactionMode: AgentInteractionMode = .default,
        providerBinary: String? = nil,
        environment: [String: String] = [:],
        extraArgs: [String] = [],
        runAsUser: AgentRunAsUser? = nil,
        acceptancePermit: AgentRunAcceptancePermit? = nil,
        contextSnapshot: ConversationContextSnapshot? = nil,
        preparedContextSeed: PreparedConversationContextSeed? = nil
    ) {
        self.runId = runId
        self.threadId = threadId
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.model = model
        self.cwd = cwd
        self.prompt = prompt
        self.userMessageContent = userMessageContent
        self.attachments = attachments
        self.providerThreadId = providerThreadId
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.reasoningModel = reasoningModel
        self.distillMainEffortSelection = distillMainEffortSelection
        self.distillReasoningEffortSelection = distillReasoningEffortSelection
        self.distillExecutionMode = distillExecutionMode
        self.serviceTier = serviceTier
        self.interactionMode = interactionMode
        self.providerBinary = providerBinary
        self.environment = environment
        self.extraArgs = extraArgs
        self.runAsUser = runAsUser
        self.acceptancePermit = acceptancePermit
        self.contextSnapshot = contextSnapshot
        self.preparedContextSeed = preparedContextSeed
    }

    private enum CodingKeys: String, CodingKey {
        case runId, threadId, provider, providerInstanceId, model, cwd, prompt, userMessageContent, attachments, providerThreadId, permissionMode, reasoningEffort, reasoningModel, distillMainEffortSelection, distillReasoningEffortSelection, serviceTier, interactionMode, providerBinary, environment, extraArgs, runAsUser
        case distillExecutionMode = "distillUltracode"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decodeIfPresent(AgentRunID.self, forKey: .runId) ?? AgentRunID()
        threadId = try c.decode(AgentThreadID.self, forKey: .threadId)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        providerInstanceId = try c.decodeIfPresent(String.self, forKey: .providerInstanceId)
        model = try c.decode(String.self, forKey: .model)
        cwd = try c.decode(String.self, forKey: .cwd)
        prompt = try c.decode(String.self, forKey: .prompt)
        userMessageContent = try c.decodeIfPresent(String.self, forKey: .userMessageContent)
        attachments = try c.decodeIfPresent([AgentAttachment].self, forKey: .attachments) ?? []
        providerThreadId = try c.decodeIfPresent(String.self, forKey: .providerThreadId)
        permissionMode = try c.decodeIfPresent(AgentPermissionMode.self, forKey: .permissionMode) ?? .supervised
        reasoningEffort = try c.decodeIfPresent(AgentReasoningEffort.self, forKey: .reasoningEffort)
        reasoningModel = try c.decodeIfPresent(String.self, forKey: .reasoningModel)
        distillMainEffortSelection = try c.decodeIfPresent(AgentEffortSelection.self, forKey: .distillMainEffortSelection)
        distillReasoningEffortSelection = try c.decodeIfPresent(AgentEffortSelection.self, forKey: .distillReasoningEffortSelection)
        distillExecutionMode = try c.decodeIfPresent(DistillExecutionMode.self, forKey: .distillExecutionMode) ?? .auto
        serviceTier = try c.decodeIfPresent(AgentServiceTier.self, forKey: .serviceTier) ?? .auto
        interactionMode = try c.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode) ?? .default
        providerBinary = try c.decodeIfPresent(String.self, forKey: .providerBinary)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
        runAsUser = try c.decodeIfPresent(AgentRunAsUser.self, forKey: .runAsUser)
        acceptancePermit = nil
    }

    public static func == (lhs: AgentRunRequest, rhs: AgentRunRequest) -> Bool {
        lhs.runId == rhs.runId
            && lhs.threadId == rhs.threadId
            && lhs.provider == rhs.provider
            && lhs.providerInstanceId == rhs.providerInstanceId
            && lhs.model == rhs.model
            && lhs.cwd == rhs.cwd
            && lhs.prompt == rhs.prompt
            && lhs.userMessageContent == rhs.userMessageContent
            && lhs.attachments == rhs.attachments
            && lhs.providerThreadId == rhs.providerThreadId
            && lhs.permissionMode == rhs.permissionMode
            && lhs.reasoningEffort == rhs.reasoningEffort
            && lhs.reasoningModel == rhs.reasoningModel
            && lhs.distillMainEffortSelection == rhs.distillMainEffortSelection
            && lhs.distillReasoningEffortSelection == rhs.distillReasoningEffortSelection
            && lhs.distillExecutionMode == rhs.distillExecutionMode
            && lhs.serviceTier == rhs.serviceTier
            && lhs.interactionMode == rhs.interactionMode
            && lhs.providerBinary == rhs.providerBinary
            && lhs.environment == rhs.environment
            && lhs.extraArgs == rhs.extraArgs
            && lhs.runAsUser == rhs.runAsUser
    }

    public var providerPrompt: String {
        AgentProviderInstructionText.providerPrompt(for: interactionMode, prompt: prompt)
    }

    public func attachingContext(
        snapshot: ConversationContextSnapshot? = nil,
        seed: PreparedConversationContextSeed? = nil
    ) -> AgentRunRequest {
        var copy = self
        if let snapshot {
            copy.contextSnapshot = snapshot
        }
        if let seed {
            copy.preparedContextSeed = seed
        }
        return copy
    }
}

public enum AgentProviderInstructionText {
    public static func providerPrompt(for mode: AgentInteractionMode, prompt: String) -> String {
        """
        \(providerPreamble(for: mode))

        User request:
        \(prompt)
        """
    }

    /// The base mode instruction Codex receives every turn as `developer_instructions`.
    public static func developerInstructions(for mode: AgentInteractionMode) -> String {
        switch mode {
        case .default:
            return "Implement clear requests; keep scope; preserve unrelated work; verify; ask before ambiguous/risky edits."
        case .plan:
            return "Plan only. Do not edit, run destructive commands, or implement until user approval."
        }
    }

    public static func providerPreamble(for mode: AgentInteractionMode) -> String {
        switch mode {
        case .default:
            return "Default mode. Implement clear requests; keep scope; preserve unrelated work; verify; ask before ambiguous/risky edits."
        case .plan:
            return "Plan mode. Produce a concrete plan only. Do not edit files, run destructive commands, or implement until approved. If available, call ExitPlanMode once with the final plan, then wait."
        }
    }
}

public enum AgentRunStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
    case interrupted
}

public struct AgentModelDescriptor: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let label: String
    public let provider: AgentProvider
    public let supportsReasoning: Bool
    public let supportedReasoningEfforts: [AgentReasoningEffort]
    public let supportsServiceTier: Bool
    public let supportsCustomModel: Bool
    public let contextWindowTokens: Int?
    public let accountProvider: String?

    public init(
        id: String,
        label: String,
        provider: AgentProvider,
        supportsReasoning: Bool = false,
        supportedReasoningEfforts: [AgentReasoningEffort]? = nil,
        supportsServiceTier: Bool = false,
        supportsCustomModel: Bool = false,
        contextWindowTokens: Int? = nil,
        accountProvider: String? = nil
    ) {
        self.id = id
        self.label = label
        self.provider = provider
        self.supportsReasoning = supportsReasoning
        self.supportedReasoningEfforts = supportedReasoningEfforts ?? (supportsReasoning ? AgentReasoningEffort.supportedCases : [])
        self.supportsServiceTier = supportsServiceTier
        self.supportsCustomModel = supportsCustomModel
        self.contextWindowTokens = contextWindowTokens
        self.accountProvider = accountProvider
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, provider, supportsReasoning, supportedReasoningEfforts, supportsServiceTier, supportsCustomModel, contextWindowTokens, accountProvider
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        supportsReasoning = try c.decodeIfPresent(Bool.self, forKey: .supportsReasoning) ?? false
        supportedReasoningEfforts = try c.decodeIfPresent([AgentReasoningEffort].self, forKey: .supportedReasoningEfforts)
            ?? (supportsReasoning ? AgentReasoningEffort.supportedCases : [])
        supportsServiceTier = try c.decodeIfPresent(Bool.self, forKey: .supportsServiceTier) ?? false
        supportsCustomModel = try c.decodeIfPresent(Bool.self, forKey: .supportsCustomModel) ?? false
        contextWindowTokens = try c.decodeIfPresent(Int.self, forKey: .contextWindowTokens)
        accountProvider = try c.decodeIfPresent(String.self, forKey: .accountProvider)
    }

    /// Compact context label for pills and picker rows ("128k ctx"). Nil when unknown.
    public var contextWindowLabel: String? {
        guard let tokens = contextWindowTokens, tokens > 0 else { return nil }
        if tokens >= 1_000_000, tokens % 1_000_000 == 0 { return "\(tokens / 1_000_000)M ctx" }
        if tokens >= 1_000, tokens % 1_000 == 0 { return "\(tokens / 1_000)k ctx" }
        return "\(tokens) ctx"
    }
}

public enum AgentProviderDriverKind: String, Codable, Sendable {
    case codexCLI = "codex_cli"
    case claudeCLI = "claude_cli"
    case grokCLI = "grok_cli"
    case distillACP = "distill_acp"
}

public enum AgentProviderSnapshotStatus: String, Codable, Sendable {
    case available
    case unavailable
    case warning
    case disabled
}

public enum AgentModelDiscoverySource: String, Codable, Sendable {
    case live
    case builtInFallback
}

public struct AgentProviderSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: AgentProvider
    public let driverKind: AgentProviderDriverKind
    public let displayName: String
    public let accentColor: String
    public let continuationGroup: String
    public let interactionModes: [AgentInteractionMode]
    public let permissionModes: [AgentPermissionMode]?
    public let enabled: Bool
    public let installed: Bool
    public let version: String?
    public let status: AgentProviderSnapshotStatus
    public let statusDetail: String?
    public let authenticated: Bool?
    public let accountLabel: String?
    public let accountAuthMethod: String?
    public let binaryPath: String?
    public let homePath: String?
    public let environmentKeys: [String]
    public let models: [AgentModelDescriptor]
    public let slashCommands: [String]
    public let skills: [String]
    public let advisory: String?
    public let updateState: String?
    public let capabilities: AgentProviderCapabilities?
    public let modelDiscoverySource: AgentModelDiscoverySource?
    /// Opaque cache identity. It contains no raw environment values or account data.
    public let modelDiscoveryCacheKey: String?

    public var effectiveCapabilities: AgentProviderCapabilities {
        capabilities ?? .conservative
    }

    public var effectivePermissionModes: [AgentPermissionMode] {
        permissionModes ?? [.supervised]
    }

    public var modelListIsFallback: Bool {
        modelDiscoverySource == .builtInFallback
    }

    public var accountSummary: String? {
        let label = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let method = accountAuthMethod?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty && !method.isEmpty { return "\(label) via \(method)" }
        if !label.isEmpty { return label }
        if !method.isEmpty { return L("Authenticated via %1$@", method) }
        return nil
    }

    public var recoveryActionTitle: String? {
        if updateState == "update_available" || (advisory?.localizedCaseInsensitiveContains("update") == true) {
            return "Update \(displayName)"
        }
        if authenticated == false {
            return L("Copy login command")
        }
        if !installed {
            return L("Copy install command")
        }
        return nil
    }

    public init(
        id: String,
        provider: AgentProvider,
        driverKind: AgentProviderDriverKind,
        displayName: String,
        accentColor: String,
        continuationGroup: String,
        interactionModes: [AgentInteractionMode],
        permissionModes: [AgentPermissionMode]? = nil,
        enabled: Bool,
        installed: Bool,
        version: String? = nil,
        status: AgentProviderSnapshotStatus,
        statusDetail: String? = nil,
        authenticated: Bool? = nil,
        accountLabel: String? = nil,
        accountAuthMethod: String? = nil,
        binaryPath: String? = nil,
        homePath: String? = nil,
        environmentKeys: [String] = [],
        models: [AgentModelDescriptor],
        slashCommands: [String],
        skills: [String] = [],
        advisory: String? = nil,
        updateState: String? = nil,
        capabilities: AgentProviderCapabilities? = nil,
        modelDiscoverySource: AgentModelDiscoverySource? = nil,
        modelDiscoveryCacheKey: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.driverKind = driverKind
        self.displayName = displayName
        self.accentColor = accentColor
        self.continuationGroup = continuationGroup
        self.interactionModes = interactionModes
        self.permissionModes = permissionModes
        self.enabled = enabled
        self.installed = installed
        self.version = version
        self.status = status
        self.statusDetail = statusDetail
        self.authenticated = authenticated
        self.accountLabel = accountLabel
        self.accountAuthMethod = accountAuthMethod
        self.binaryPath = binaryPath
        self.homePath = homePath
        self.environmentKeys = environmentKeys
        self.models = models
        self.slashCommands = slashCommands
        self.skills = skills
        self.advisory = advisory
        self.updateState = updateState
        self.capabilities = capabilities
        self.modelDiscoverySource = modelDiscoverySource
        self.modelDiscoveryCacheKey = modelDiscoveryCacheKey
    }
}

public extension Array where Element == AgentProviderSnapshot {
    /// Exact instance first; a stale or legacy id (e.g. "distill") falls back to the
    /// provider's enabled instance so saved tasks keep resolving after migration.
    func resolvedSnapshot(provider: AgentProvider, instanceID: String) -> AgentProviderSnapshot? {
        first { $0.provider == provider && $0.id == instanceID }
            ?? first { $0.provider == provider && $0.enabled }
            ?? first { $0.provider == provider }
    }
}

public enum AgentProviderRunPreflightError: Error, CustomStringConvertible, Equatable {
    case missingSnapshot
    case disabled(String)
    case unavailable(String)
    case unauthenticated(String)
    case unsupportedInteractionMode(String, AgentInteractionMode)
    case unsupportedPermissionMode(String, AgentPermissionMode)
    case attachmentsUnsupported(String)
    case attachmentKindUnsupported(String, AgentAttachmentKind)
    case attachmentMediaTypeUnsupported(String, String)

    public var description: String {
        switch self {
        case .missingSnapshot:
            return L("Provider capabilities are not loaded yet.")
        case .disabled(let provider):
            return L("%1$@ is disabled.", provider)
        case .unavailable(let provider):
            return L("%1$@ is unavailable.", provider)
        case .unauthenticated(let provider):
            return L("%1$@ is not authenticated. Sign in to continue.", provider)
        case .unsupportedInteractionMode(let provider, let mode):
            return L("%1$@ does not support %2$@ mode for this session.", provider, mode.rawValue)
        case .unsupportedPermissionMode(let provider, let mode):
            return L("%1$@ does not support %2$@ permission for this session.", provider, mode.rawValue)
        case .attachmentsUnsupported(let provider):
            return L("%1$@ does not support attachments for this session.", provider)
        case .attachmentKindUnsupported(let provider, let kind):
            return L("%1$@ does not support %2$@ attachments for this session.", provider, kind.rawValue)
        case .attachmentMediaTypeUnsupported(let provider, let mediaType):
            return L("%1$@ does not support attachment media type %2$@.", provider, mediaType)
        }
    }
}

/// Shared snapshot pick for host preflight and surface selection.
/// Prefer exact instance+provider, then same-provider fallback (covers
/// raw "grok" vs "grok-cli" and stale instance ids without cross-provider bleed).
public enum AgentProviderSnapshotSelection {
    public static func resolve(
        snapshots: [AgentProviderSnapshot],
        provider: AgentProvider,
        instanceId: String?
    ) -> AgentProviderSnapshot? {
        // Prefer exact instance id only when it belongs to the requested
        // provider. Cross-provider ids (e.g. stale "codex-cli" while selecting
        // Grok) must fall through so preflight never runs the wrong CLI.
        if let instanceId,
           let exact = snapshots.first(where: { $0.id == instanceId && $0.provider == provider }) {
            return exact
        }
        return snapshots.first(where: { $0.provider == provider })
    }
}

/// Model defaults for a new / rebound provider selection.
/// Prefer the last model the user explicitly used for that provider; otherwise
/// a built-in default (Codex → `gpt-5.6-sol`); otherwise the first listed id.
public enum AgentDefaultModelSelection {
    public static let codexBuiltInDefault = "gpt-5.6-sol"

    public static func builtInDefault(for provider: AgentProvider) -> String {
        switch provider {
        case .codex: return codexBuiltInDefault
        case .claude, .grok, .distill: return ""
        }
    }

    public static func resolve(
        provider: AgentProvider,
        lastUsed: String?,
        availableModelIds: [String],
        supportsCustomModel: Bool = true
    ) -> String {
        // 1) Last model the user chose for this provider always wins — even when
        // the current discovery list omits it (custom id / stale baked-in list).
        let last = lastUsed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !last.isEmpty { return last }
        // 2) Provider built-in (Codex → gpt-5.6-sol) before first list row so a
        // stale list still open on the product default.
        let builtIn = builtInDefault(for: provider)
        if !builtIn.isEmpty { return builtIn }
        // 3) First named id from discovery (skip empty "account default" row).
        _ = supportsCustomModel // reserved for callers that already computed it
        if let firstNamed = availableModelIds.first(where: { !$0.isEmpty }) {
            return firstNamed
        }
        return availableModelIds.first ?? ""
    }
}

/// No provider is mandatory. When the preferred selection cannot run (missing
/// binary, disabled, unauthenticated), pick another installed provider so
/// Claude/Grok still work without Codex CLI (and vice versa).
public enum AgentProviderRunnableSelection {
    /// Basic runnability for account selection — same gates as send preflight
    /// for enabled / installed / authenticated, without mode or attachment checks.
    public static func isRunnable(_ snapshot: AgentProviderSnapshot) -> Bool {
        guard snapshot.enabled, snapshot.status != .disabled else { return false }
        guard snapshot.installed, snapshot.status != .unavailable else { return false }
        guard snapshot.authenticated != false else { return false }
        return true
    }

    /// Prefer the current selection when runnable; otherwise the first runnable
    /// snapshot in `AgentProvider.selectable` order. If nothing is runnable,
    /// keep the preferred row so recovery UI can still name the failure.
    public static func resolve(
        snapshots: [AgentProviderSnapshot],
        preferredProvider: AgentProvider,
        preferredInstanceId: String?
    ) -> AgentProviderSnapshot? {
        if let current = AgentProviderSnapshotSelection.resolve(
            snapshots: snapshots,
            provider: preferredProvider,
            instanceId: preferredInstanceId
        ), isRunnable(current) {
            return current
        }
        for provider in AgentProvider.selectable {
            if let snap = snapshots.first(where: { $0.provider == provider && isRunnable($0) }) {
                return snap
            }
        }
        return AgentProviderSnapshotSelection.resolve(
            snapshots: snapshots,
            provider: preferredProvider,
            instanceId: preferredInstanceId
        )
            ?? snapshots.first(where: \.enabled)
            ?? snapshots.first
    }
}

/// Single fail-closed provider gate shared by desktop and mirror execution.
/// This must run before a draft, queue, user message, thread, or run is mutated.
public enum AgentProviderRunPreflight {
    public static func validate(
        snapshot: AgentProviderSnapshot?,
        interactionMode: AgentInteractionMode,
        permissionMode: AgentPermissionMode,
        attachments: [AgentAttachment]
    ) throws {
        guard let snapshot else { throw AgentProviderRunPreflightError.missingSnapshot }
        let name = snapshot.displayName
        guard snapshot.enabled, snapshot.status != .disabled else {
            throw AgentProviderRunPreflightError.disabled(name)
        }
        guard snapshot.installed, snapshot.status != .unavailable else {
            throw AgentProviderRunPreflightError.unavailable(name)
        }
        guard snapshot.authenticated != false else {
            throw AgentProviderRunPreflightError.unauthenticated(name)
        }
        guard snapshot.interactionModes.contains(interactionMode) else {
            throw AgentProviderRunPreflightError.unsupportedInteractionMode(name, interactionMode)
        }
        guard snapshot.effectivePermissionModes.contains(permissionMode) else {
            throw AgentProviderRunPreflightError.unsupportedPermissionMode(name, permissionMode)
        }
        guard attachments.isEmpty || snapshot.effectiveCapabilities.supportsAttachments else {
            throw AgentProviderRunPreflightError.attachmentsUnsupported(name)
        }
        let capabilities = snapshot.effectiveCapabilities
        let supportedMediaTypes = Set(capabilities.supportedAttachmentMediaTypes.map(normalizedMediaType))
        for attachment in attachments {
            guard capabilities.supportedAttachmentKinds.contains(attachment.kind) else {
                throw AgentProviderRunPreflightError.attachmentKindUnsupported(name, attachment.kind)
            }
            let mediaType = normalizedMediaType(attachment.mimeType ?? "")
            guard !mediaType.isEmpty,
                  supportedMediaTypes.contains(mediaType) ||
                    (attachment.kind == .file && supportedMediaTypes.contains("*/*")) else {
                throw AgentProviderRunPreflightError.attachmentMediaTypeUnsupported(
                    name,
                    mediaType.isEmpty ? "unknown" : mediaType
                )
            }
        }
    }

    private static func normalizedMediaType(_ raw: String) -> String {
        raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

public enum AgentProviderSnapshotFactory {
    public static func snapshot(provider: AgentProvider, models: [AgentModelDescriptor], binaryPath: String? = nil, version: String? = nil, authenticated: Bool? = nil, accountLabel: String? = nil, accountAuthMethod: String? = nil, updateState: String? = nil, advisory: String? = nil, slashCommands: [String] = [], skills: [String] = [], id: String? = nil, displayName: String? = nil, accentColor: String? = nil, enabled: Bool = true, homePath: String? = nil, environmentKeys: [String] = [], interactionModesOverride: [AgentInteractionMode]? = nil, permissionModesOverride: [AgentPermissionMode]? = nil, capabilitiesOverride: AgentProviderCapabilities? = nil, modelDiscoverySource: AgentModelDiscoverySource? = nil, modelDiscoveryCacheKey: String? = nil) -> AgentProviderSnapshot {
        let installed = binaryPath.map { !$0.isEmpty } ?? !models.isEmpty
        switch provider {
        case .codex:
            let codexCapabilities = capabilitiesOverride ?? AgentProviderCapabilities(
                supportsAttachments: true,
                supportedAttachmentKinds: [.file, .image],
                supportedAttachmentMediaTypes: ["*/*", "image/jpeg", "image/png", "image/gif", "image/webp"],
                supportsApprovals: true,
                supportsUserInput: true,
                supportsStreaming: true,
                // The current app-server `thread/fork` schema has no client
                // idempotency key. `thread/delete` cannot close the crash window
                // between provider creation and local persistence, so the
                // feature must remain hidden until the provider contract changes.
                supportsFork: false,
                supportsRollback: true,
                supportsPlanReview: true
            )
            let status: AgentProviderSnapshotStatus = enabled
                ? (!installed || models.isEmpty ? .unavailable : (authenticated == false || updateState == "update_available" ? .warning : .available))
                : .disabled
            let statusDetail = Self.statusDetail(
                providerName: "Codex",
                installed: installed,
                hasModels: !models.isEmpty,
                authenticated: authenticated,
                advisory: advisory,
                updateState: updateState,
                enabled: enabled
            )
            return AgentProviderSnapshot(
                id: id ?? "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: displayName ?? "Codex",
                accentColor: accentColor ?? "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                permissionModes: AgentPermissionMode.allCases,
                enabled: enabled,
                installed: installed,
                version: version,
                status: status,
                statusDetail: statusDetail,
                authenticated: authenticated,
                accountLabel: accountLabel,
                accountAuthMethod: accountAuthMethod,
                binaryPath: binaryPath?.isEmpty == false ? binaryPath : nil,
                homePath: homePath?.isEmpty == false ? homePath : nil,
                environmentKeys: environmentKeys,
                models: models,
                slashCommands: uniqueSlashCommands(defaults: ["/clear", "/default", "/model", "/plan", "/status", "/goal"], probed: slashCommands)
                    .filter { $0 != "/fork" || codexCapabilities.supportsFork },
                skills: unique(skills),
                advisory: advisory,
                updateState: updateState,
                capabilities: codexCapabilities,
                modelDiscoverySource: modelDiscoverySource,
                modelDiscoveryCacheKey: modelDiscoveryCacheKey
            )
        case .claude:
            let status: AgentProviderSnapshotStatus = enabled
                ? (!installed || models.isEmpty ? .unavailable : (authenticated == false || updateState == "update_available" || capabilitiesOverride != nil ? .warning : .available))
                : .disabled
            let statusDetail = Self.statusDetail(
                providerName: "Claude",
                installed: installed,
                hasModels: !models.isEmpty,
                authenticated: authenticated,
                advisory: advisory,
                updateState: updateState,
                enabled: enabled
            )
            return AgentProviderSnapshot(
                id: id ?? "claude-cli",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: displayName ?? "Claude",
                accentColor: accentColor ?? "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: interactionModesOverride ?? [.default, .plan],
                permissionModes: permissionModesOverride ?? AgentPermissionMode.allCases,
                enabled: enabled,
                installed: installed,
                version: version,
                status: status,
                statusDetail: statusDetail,
                authenticated: authenticated,
                accountLabel: accountLabel,
                accountAuthMethod: accountAuthMethod,
                binaryPath: binaryPath?.isEmpty == false ? binaryPath : nil,
                homePath: homePath?.isEmpty == false ? homePath : nil,
                environmentKeys: environmentKeys,
                models: models,
                slashCommands: uniqueSlashCommands(
                    // `/goal` is a universal pass-through prompt command (Codex-native;
                    // Claude/Grok receive it as the first user token, same as `/goal` in composer).
                    defaults: (interactionModesOverride ?? [.default, .plan]).contains(.plan)
                        ? ["/clear", "/default", "/model", "/plan", "/status", "/fork", "/goal"]
                        : ["/clear", "/default", "/model", "/status", "/goal"],
                    probed: slashCommands
                ),
                skills: unique(skills),
                advisory: advisory,
                updateState: updateState,
                capabilities: capabilitiesOverride ?? AgentProviderCapabilities(
                    supportsAttachments: true,
                    supportedAttachmentKinds: [.image],
                    supportedAttachmentMediaTypes: ["image/jpeg", "image/png", "image/gif", "image/webp"],
                    supportsApprovals: true,
                    supportsUserInput: true,
                    supportsStreaming: true,
                    supportsPlanReview: true
                ),
                modelDiscoverySource: modelDiscoverySource,
                modelDiscoveryCacheKey: modelDiscoveryCacheKey
            )
        case .grok, .distill:
            let providerName = provider == .distill ? "Distill" : "Grok"
            let status: AgentProviderSnapshotStatus = enabled
                ? (!installed || models.isEmpty ? .unavailable : (authenticated == false || updateState == "update_available" ? .warning : .available))
                : .disabled
            let statusDetail = Self.statusDetail(
                providerName: providerName,
                installed: installed,
                hasModels: !models.isEmpty,
                authenticated: authenticated,
                advisory: advisory,
                updateState: updateState,
                enabled: enabled
            )
            return AgentProviderSnapshot(
                id: id ?? (provider == .distill ? "distill-acp" : "grok-cli"),
                provider: provider,
                driverKind: provider == .distill ? .distillACP : .grokCLI,
                displayName: displayName ?? providerName,
                accentColor: accentColor ?? (provider == .distill ? "#6E56CF" : "#1DA1F2"),
                continuationGroup: provider == .distill ? "distill" : "xai-grok",
                interactionModes: interactionModesOverride ?? [.default],
                permissionModes: permissionModesOverride ?? AgentPermissionMode.allCases,
                enabled: enabled,
                installed: installed,
                version: version,
                status: status,
                statusDetail: statusDetail,
                authenticated: authenticated,
                accountLabel: accountLabel,
                accountAuthMethod: accountAuthMethod,
                binaryPath: binaryPath?.isEmpty == false ? binaryPath : nil,
                homePath: homePath?.isEmpty == false ? homePath : nil,
                environmentKeys: environmentKeys,
                models: models,
                slashCommands: uniqueSlashCommands(
                    defaults: ((interactionModesOverride ?? [.default]).contains(.plan)
                        ? ["/clear", "/default", "/model", "/plan", "/status", "/goal"]
                        : ["/clear", "/default", "/model", "/status", "/goal"])
                        + (provider == .distill
                            ? ["/loop", "/compact", "/context", "/session-info", "/deep-research", "/workflow"]
                            : []),
                    probed: slashCommands
                ),
                skills: unique(skills),
                advisory: advisory,
                updateState: updateState,
                capabilities: capabilitiesOverride ?? .conservative,
                modelDiscoverySource: modelDiscoverySource,
                modelDiscoveryCacheKey: modelDiscoveryCacheKey
            )
        }
    }

    private static func statusDetail(providerName: String, installed: Bool, hasModels: Bool, authenticated: Bool?, advisory: String?, updateState: String?, enabled: Bool) -> String? {
        guard enabled else { return L("%1$@ provider instance is disabled.", providerName) }
        guard installed else { return L("%1$@ CLI binary is unavailable.", providerName) }
        guard hasModels else { return L("%1$@ CLI models are unavailable.", providerName) }
        if authenticated == false { return L("%1$@ CLI is not authenticated.", providerName) }
        if updateState == "update_available" { return advisory ?? L("%1$@ CLI update is available.", providerName) }
        if let advisory, !advisory.isEmpty { return advisory }
        return nil
    }

    private static func uniqueSlashCommands(defaults: [String], probed: [String]) -> [String] {
        var seen = Set<String>()
        return (defaults + probed)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && $0.count > 1 && seen.insert($0).inserted }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public struct AgentThread: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentThreadID
    public var projectId: ProjectID?
    public var workspaceId: WorkspaceID?
    public var title: String
    public var provider: AgentProvider
    public var providerInstanceId: String?
    public var model: String
    public var permissionMode: AgentPermissionMode
    public var reasoningEffort: AgentReasoningEffort
    /// Independent per-conversation Reasoning model; nil disables Reasoning.
    public var reasoningModel: String?
    public var providerThreadId: String?
    public var status: AgentRunStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var diffAdditions: Int
    public var diffDeletions: Int
    public var hasUnread: Bool
    public var color: String?
    public var pinned: Bool
    public var sortOrder: Int
    public var executionMode: AgentExecutionMode
    public var baseBranch: String?
    public var worktreePath: String?
    public var serviceTier: AgentServiceTier
    public var modelSelection: AgentModelSelection
    /// Nil is an intentional legacy representation. Its effective value is
    /// always Manual with the legacy provider/model/reasoning/tier precedence.
    public var routingConfiguration: AgentRoutingConfiguration?
    /// Optional only for backward-compatible decoding of pre-v34 wire snapshots.
    public var interactionMode: AgentInteractionMode?
    /// macOS account that executes provider processes for this thread through the shared helper.
    /// Nil means the current login user. Distinct from `providerInstanceId`.
    public var runAsUser: AgentRunAsUser?
    /// Who runs this thread. Locked once `actorLockedAt` is set.
    public var actor: RunActor
    public var actorLockedAt: Date?
    public var executionTarget: ExecutionTarget?
    /// Source thread this thread was forked/sided from; nil for a root thread.
    public var parentThreadId: AgentThreadID?
    /// Ephemeral side threads are hidden from `agent.thread.list` and swept on launch.
    public var isEphemeral: Bool

    public var effectiveInteractionMode: AgentInteractionMode {
        interactionMode ?? .default
    }

    public var effectiveRoutingConfiguration: AgentRoutingConfiguration {
        routingConfiguration ?? .legacyManual(
            selection: modelSelection,
            providerInstanceId: providerInstanceId,
            updatedAt: updatedAt
        )
    }

    public init(
        id: AgentThreadID = AgentThreadID(),
        projectId: ProjectID? = nil,
        workspaceId: WorkspaceID? = nil,
        title: String,
        provider: AgentProvider,
        providerInstanceId: String? = nil,
        model: String,
        providerThreadId: String? = nil,
        status: AgentRunStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        diffAdditions: Int = 0,
        diffDeletions: Int = 0,
        hasUnread: Bool = false,
        color: String? = nil,
        pinned: Bool = false,
        sortOrder: Int = 0,
        permissionMode: AgentPermissionMode = .fullAccess,
        reasoningEffort: AgentReasoningEffort = .medium,
        reasoningModel: String? = nil,
        executionMode: AgentExecutionMode = .local,
        baseBranch: String? = nil,
        worktreePath: String? = nil,
        serviceTier: AgentServiceTier = .auto,
        modelSelection: AgentModelSelection? = nil,
        interactionMode: AgentInteractionMode = .default,
        runAsUser: AgentRunAsUser? = nil,
        routingConfiguration: AgentRoutingConfiguration? = nil,
        actor: RunActor = .none,
        actorLockedAt: Date? = nil,
        executionTarget: ExecutionTarget? = nil,
        parentThreadId: AgentThreadID? = nil,
        isEphemeral: Bool = false
    ) {
        self.id = id
        self.projectId = projectId
        self.workspaceId = workspaceId
        self.title = title
        self.provider = provider
        self.providerInstanceId = providerInstanceId ?? provider.rawValue
        self.model = model
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.reasoningModel = reasoningModel
        self.providerThreadId = providerThreadId
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.diffAdditions = diffAdditions
        self.diffDeletions = diffDeletions
        self.hasUnread = hasUnread
        self.color = color
        self.pinned = pinned
        self.sortOrder = sortOrder
        self.executionMode = executionMode
        self.baseBranch = baseBranch
        self.worktreePath = worktreePath
        self.serviceTier = serviceTier
        self.modelSelection = modelSelection ?? AgentModelSelection(
            provider: provider,
            modelId: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        self.routingConfiguration = routingConfiguration
        self.interactionMode = interactionMode
        self.runAsUser = runAsUser
        self.actor = actor
        self.actorLockedAt = actorLockedAt
        self.executionTarget = executionTarget
        self.parentThreadId = parentThreadId
        self.isEphemeral = isEphemeral
    }

    /// Hand-written only so pre-actor JSON (no `actor` key) still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(AgentThreadID.self, forKey: .id)
        projectId = try c.decodeIfPresent(ProjectID.self, forKey: .projectId)
        workspaceId = try c.decodeIfPresent(WorkspaceID.self, forKey: .workspaceId)
        title = try c.decode(String.self, forKey: .title)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        providerInstanceId = try c.decodeIfPresent(String.self, forKey: .providerInstanceId)
        model = try c.decode(String.self, forKey: .model)
        permissionMode = try c.decode(AgentPermissionMode.self, forKey: .permissionMode)
        reasoningEffort = try c.decode(AgentReasoningEffort.self, forKey: .reasoningEffort)
        reasoningModel = try c.decodeIfPresent(String.self, forKey: .reasoningModel)
        providerThreadId = try c.decodeIfPresent(String.self, forKey: .providerThreadId)
        status = try c.decode(AgentRunStatus.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        diffAdditions = try c.decode(Int.self, forKey: .diffAdditions)
        diffDeletions = try c.decode(Int.self, forKey: .diffDeletions)
        hasUnread = try c.decode(Bool.self, forKey: .hasUnread)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        executionMode = try c.decode(AgentExecutionMode.self, forKey: .executionMode)
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        serviceTier = try c.decode(AgentServiceTier.self, forKey: .serviceTier)
        modelSelection = try c.decode(AgentModelSelection.self, forKey: .modelSelection)
        routingConfiguration = try c.decodeIfPresent(AgentRoutingConfiguration.self, forKey: .routingConfiguration)
        interactionMode = try c.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode)
        runAsUser = try c.decodeIfPresent(AgentRunAsUser.self, forKey: .runAsUser)
        actor = try c.decodeIfPresent(RunActor.self, forKey: .actor) ?? .none
        actorLockedAt = try c.decodeIfPresent(Date.self, forKey: .actorLockedAt)
        executionTarget = try c.decodeIfPresent(ExecutionTarget.self, forKey: .executionTarget)
        parentThreadId = try c.decodeIfPresent(AgentThreadID.self, forKey: .parentThreadId)
        isEphemeral = try c.decodeIfPresent(Bool.self, forKey: .isEphemeral) ?? false
    }
}

public enum AgentThreadTitle {
    public static let defaultTitle = "New thread"
    public static let legacyDefaultTitle = "Thread"
    public static let displayLimit = 28
    /// Nested-worker titles from AgentAppMiddleware (`"Subagent · …"`).
    public static let subagentTitlePrefix = "Subagent ·"

    public static func isPlaceholder(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized == defaultTitle || normalized == legacyDefaultTitle
    }

    /// True when the title is an orchestrated nested-worker row (not a rail entry).
    public static func isSubagentThreadTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasPrefix(subagentTitlePrefix)
    }

    // PERF: titleFromFirstMessage trims list/heading noise on every new-thread
    // title derivation (composer send + host repair paths). Share one set.
    private static let firstMessageTitleTrimSet = CharacterSet(charactersIn: " \t.-:#*")

    public static func titleFromFirstMessage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.trimmingCharacters(in: firstMessageTitleTrimSet)
        return stripped.isEmpty ? defaultTitle : stripped
    }

    public static func display(_ title: String, limit: Int = displayLimit) -> String {
        // The stored placeholder stays English (other code matches on it); show it translated.
        let title = isPlaceholder(title) && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("New thread") : title
        guard title.count > limit else { return title }
        return String(title.prefix(max(0, limit))) + "..."
    }
}

public enum AgentTurnCheckpointStatus: String, Codable, Sendable, Equatable {
    case ready
    case missing
    case error
}

public struct AgentTurnCheckpointFile: Codable, Sendable, Equatable {
    public let path: String
    public let kind: String
    public let additions: Int
    public let deletions: Int

    public init(path: String, kind: String, additions: Int, deletions: Int) {
        self.path = path
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
    }
}

public struct AgentTurnCheckpointFileSnapshot: Codable, Sendable, Equatable {
    public let path: String
    public let kind: String
    public let contentsBase64: String?

    public init(path: String, kind: String, contentsBase64: String?) {
        self.path = path
        self.kind = kind
        self.contentsBase64 = contentsBase64
    }
}

public struct AgentTurnCheckpointFileDiff: Codable, Sendable, Equatable {
    public let path: String
    public let patch: String

    public init(path: String, patch: String) {
        self.path = path
        self.patch = patch
    }
}

public struct AgentTurnCheckpointSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(threadId.value.uuidString):\(turnId)" }
    public let threadId: AgentThreadID
    public let runId: AgentRunID
    public let turnId: String
    public let checkpointTurnCount: Int
    public let checkpointRef: String
    public let status: AgentTurnCheckpointStatus
    public let files: [AgentTurnCheckpointFile]
    public let fileSnapshots: [AgentTurnCheckpointFileSnapshot]
    public let diffPatch: String?
    public let fileDiffs: [AgentTurnCheckpointFileDiff]
    public let assistantMessageId: AgentMessageID?
    public let errorMessage: String?
    public let completedAt: Date

    public init(
        threadId: AgentThreadID,
        runId: AgentRunID,
        turnId: String,
        checkpointTurnCount: Int,
        checkpointRef: String,
        status: AgentTurnCheckpointStatus,
        files: [AgentTurnCheckpointFile],
        fileSnapshots: [AgentTurnCheckpointFileSnapshot] = [],
        diffPatch: String? = nil,
        fileDiffs: [AgentTurnCheckpointFileDiff] = [],
        assistantMessageId: AgentMessageID? = nil,
        errorMessage: String? = nil,
        completedAt: Date = Date()
    ) {
        self.threadId = threadId
        self.runId = runId
        self.turnId = turnId
        self.checkpointTurnCount = checkpointTurnCount
        self.checkpointRef = checkpointRef
        self.status = status
        self.files = files
        self.fileSnapshots = fileSnapshots
        self.diffPatch = diffPatch
        self.fileDiffs = fileDiffs
        self.assistantMessageId = assistantMessageId
        self.errorMessage = errorMessage
        self.completedAt = completedAt
    }
}

/// Bounded, stable identity used only by the checkpoint-list v1 wire projection.
/// Normal turn ids remain byte-for-byte exact. An oversized legacy/provider id is
/// represented by its complete SHA-256 plus original encoded length so it cannot
/// dominate a mobile response or be confused with a clipped prefix.
public enum AgentTurnCheckpointWireIdentity {
    public static let maximumEncodedTurnIDBytes = 256
    public static let digestPrefix = "sha256:"

    public static func projectedTurnID(_ raw: String) -> String {
        let encodedBytes = encodedJSONStringByteCount(raw)
        guard encodedBytes > maximumEncodedTurnIDBytes else { return raw }
        return "\(digestPrefix)\(sha256(raw)):\(encodedBytes)"
    }

    public static func isDigestIdentity(_ value: String) -> Bool {
        guard value.hasPrefix(digestPrefix) else { return false }
        let remainder = value.dropFirst(digestPrefix.count)
        let components = remainder.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].count == 64,
              components[0].allSatisfy({ $0.isHexDigit }),
              let encodedBytes = Int(components[1]),
              encodedBytes > maximumEncodedTurnIDBytes else {
            return false
        }
        return true
    }

    /// SHA-256 lowercase hex of `raw` UTF-8.
    ///
    /// PERF: hashes contiguous UTF-8 storage (no per-4KiB `Array`/`Data` chunking)
    /// and formats hex with a nibble table. Oversized turn ids / error messages on
    /// checkpoint capture can be multi-KiB–MiB; the prior byte loop + `String(format:)`
    /// paid a full-body copy and 32 formatter calls per digest.
    public static func sha256(_ raw: String) -> String {
        var hasher = SHA256()
        var copy = raw
        copy.withUTF8 { buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        return hexDigest(hasher.finalize())
    }

    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    /// Exact byte count produced by the repository's default JSONEncoder for a
    /// standalone String, without allocating a second whole-string Data buffer.
    public static func encodedJSONStringByteCount(_ raw: String) -> Int {
        var count = 2 // surrounding quotes
        for scalar in raw.unicodeScalars {
            count += encodedJSONScalarCost(scalar)
        }
        return count
    }

    /// JSON-string encoded UTF-8 cost of one scalar (content only, no quotes).
    public static func encodedJSONScalarCost(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x08, 0x09, 0x0A, 0x0C, 0x0D:
            return 2
        case 0x00...0x1F:
            return 6
        case 0x22, 0x2F, 0x5C:
            return 2
        default:
            return scalar.utf8.count
        }
    }
}

/// Capture-time bounded string projections for `agent.checkpoint.list` v1.
/// Computed once on upsert and read back for list pages so the mobile path never
/// re-materializes or re-hashes authoritative raw columns.
public enum AgentTurnCheckpointListWireProjection {
    public static let maxEncodedCheckpointRefBytes = 512
    public static let maxEncodedErrorMessageBytes = 1_024
    public static let maxFiles = 64
    public static let maxEncodedFilesBytes = 6 * 1_024
    public static let maxEntries = 100
    public static let maxEncodedItemBytes = 8 * 1_024
    public static let maxEncodedResponseBytes = 700 * 1_024

    public struct Field: Codable, Sendable, Equatable {
        public let value: String?
        public let totalEncodedBytes: Int
        public let sha256: String?
        public let truncated: Bool

        public init(
            value: String?,
            totalEncodedBytes: Int,
            sha256: String?,
            truncated: Bool
        ) {
            self.value = value
            self.totalEncodedBytes = totalEncodedBytes
            self.sha256 = sha256
            self.truncated = truncated
        }
    }

    public struct Capture: Codable, Sendable, Equatable {
        public let turnId: Field
        public let checkpointRef: Field
        public let errorMessage: Field
        /// True only for rows captured before bounded list metadata existed.
        /// These rows carry a stable opaque identity plus explicit unavailable
        /// sentinels; no hashes or byte totals are fabricated from raw columns.
        public let metadataUnavailable: Bool

        public init(
            turnId: Field,
            checkpointRef: Field,
            errorMessage: Field,
            metadataUnavailable: Bool = false
        ) {
            self.turnId = turnId
            self.checkpointRef = checkpointRef
            self.errorMessage = errorMessage
            self.metadataUnavailable = metadataUnavailable
        }
    }

    /// Project authoritative capture fields into the bounded list-wire shape.
    public static func capture(
        turnId: String,
        checkpointRef: String,
        errorMessage: String?
    ) -> Capture {
        Capture(
            turnId: projectTurnId(turnId),
            checkpointRef: projectString(
                checkpointRef,
                maximumEncodedBytes: maxEncodedCheckpointRefBytes
            ),
            errorMessage: projectString(
                errorMessage,
                maximumEncodedBytes: maxEncodedErrorMessageBytes
            )
        )
    }

    public static func projectTurnId(_ raw: String) -> Field {
        let totalEncodedBytes =
            AgentTurnCheckpointWireIdentity.encodedJSONStringByteCount(raw)
        let projected = AgentTurnCheckpointWireIdentity.projectedTurnID(raw)
        let truncated = projected != raw
        return Field(
            value: projected,
            totalEncodedBytes: totalEncodedBytes,
            sha256: truncated
                ? AgentTurnCheckpointWireIdentity.sha256(raw)
                : nil,
            truncated: truncated
        )
    }

    public static func projectString(
        _ raw: String?,
        maximumEncodedBytes: Int
    ) -> Field {
        guard let raw else {
            return Field(
                value: nil,
                totalEncodedBytes: 0,
                sha256: nil,
                truncated: false
            )
        }
        // Single Character walk: total encoded size + Character-safe preview under
        // budget. Prior path re-scanned the growing prefix with
        // `encodedJSONStringByteCount` on every Character (O(preview²)) and
        // allocated `preview + String(character)` each step — expensive when an
        // error_message / checkpoint_ref is multi-KiB and only the head is kept.
        var totalEncodedBytes = 2 // surrounding quotes
        var previewEncoded = 2
        var previewEnd = raw.startIndex
        var index = raw.startIndex
        var previewAdmissionOpen = true
        while index < raw.endIndex {
            let next = raw.index(after: index)
            var charCost = 0
            for scalar in raw[index].unicodeScalars {
                charCost += AgentTurnCheckpointWireIdentity.encodedJSONScalarCost(scalar)
            }
            totalEncodedBytes += charCost
            if previewAdmissionOpen {
                if previewEncoded + charCost <= maximumEncodedBytes {
                    previewEncoded += charCost
                    previewEnd = next
                } else {
                    previewAdmissionOpen = false
                }
            }
            index = next
        }
        guard totalEncodedBytes > maximumEncodedBytes else {
            return Field(
                value: raw,
                totalEncodedBytes: totalEncodedBytes,
                sha256: nil,
                truncated: false
            )
        }
        return Field(
            value: String(raw[..<previewEnd]),
            totalEncodedBytes: totalEncodedBytes,
            sha256: AgentTurnCheckpointWireIdentity.sha256(raw),
            truncated: true
        )
    }
}

/// Keyset cursor for `agent.checkpoint.list` response_version 1.
/// Ordered by `(checkpointTurnCount, completedAt, turnId)` descending; `turnId` is the final tie-breaker.
///
/// `completedAtToken` is the exact wire/DB `completed_at` string. Bind this for
/// keyset continuation so fractional (and legacy whole-second) storage formats
/// round-trip without reformatting drift.
public struct AgentTurnCheckpointCursor: Codable, Sendable, Equatable {
    public let checkpointTurnCount: Int
    public let completedAt: Date
    public let turnId: String
    /// Exact `completed_at` token from the wire or storage row. Empty only for
    /// older test callers that construct the cursor from a Date alone.
    public let completedAtToken: String

    public init(
        checkpointTurnCount: Int,
        completedAt: Date,
        turnId: String,
        completedAtToken: String = ""
    ) {
        self.checkpointTurnCount = checkpointTurnCount
        self.completedAt = completedAt
        self.turnId = turnId
        self.completedAtToken = completedAtToken
    }

    public init(from summary: AgentTurnCheckpointSummary, completedAtToken: String = "") {
        self.checkpointTurnCount = summary.checkpointTurnCount
        self.completedAt = summary.completedAt
        self.turnId = summary.turnId
        self.completedAtToken = completedAtToken
    }
}

/// Paginated metadata page for `agent.checkpoint.list` response_version 1.
/// Items are summary-compatible but heavy payload fields are always empty/null.
///
/// `catalogRevision` is the generation fence for this page: first page returns
/// it; later pages must present the same value and restart once on drift.
public struct AgentTurnCheckpointPage: Codable, Sendable, Equatable {
    public let items: [AgentTurnCheckpointSummary]
    /// Parallel to `items`; true means the persisted mobile summary omitted one
    /// or more authoritative file entries. Empty preserves older test/router callers.
    public let filesTruncated: [Bool]
    /// Parallel to `items`; capture-time bounded turn_id/ref/error projections.
    /// Empty preserves older test/router callers that still project at encode time.
    public let listMetadata: [AgentTurnCheckpointListWireProjection.Capture]
    /// Parallel to `items`; exact `completed_at` storage/wire keyset tokens.
    /// Empty preserves older test/router callers that reformat from `Date`.
    public let completedAtTokens: [String]
    public let truncated: Bool
    public let nextBefore: AgentTurnCheckpointCursor?
    /// Catalog generation observed for this page (transactional with mutations).
    public let catalogRevision: Int64

    public init(
        items: [AgentTurnCheckpointSummary],
        filesTruncated: [Bool] = [],
        listMetadata: [AgentTurnCheckpointListWireProjection.Capture] = [],
        completedAtTokens: [String] = [],
        truncated: Bool,
        nextBefore: AgentTurnCheckpointCursor?,
        catalogRevision: Int64 = 1
    ) {
        self.items = items
        self.filesTruncated = filesTruncated
        self.listMetadata = listMetadata
        self.completedAtTokens = completedAtTokens
        self.truncated = truncated
        self.nextBefore = nextBefore
        self.catalogRevision = catalogRevision
    }
}

public enum AgentMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct AgentMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentMessageID
    public let threadId: AgentThreadID
    public let role: AgentMessageRole
    public var content: String
    public let createdAt: Date
    public let attachments: [AgentAttachment]

    public init(
        id: AgentMessageID = AgentMessageID(),
        threadId: AgentThreadID,
        role: AgentMessageRole,
        content: String,
        createdAt: Date = Date(),
        attachments: [AgentAttachment] = []
    ) {
        self.id = id
        self.threadId = threadId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, threadId, role, content, createdAt, attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AgentMessageID.self, forKey: .id)
        threadId = try container.decode(AgentThreadID.self, forKey: .threadId)
        role = try container.decode(AgentMessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attachments = try container.decodeIfPresent([AgentAttachment].self, forKey: .attachments) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(threadId, forKey: .threadId)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(attachments, forKey: .attachments)
    }
}

public struct AgentMessageCursor: Codable, Sendable, Equatable {
    public let createdAt: Date
    public let id: AgentMessageID

    public init(createdAt: Date, id: AgentMessageID) {
        self.createdAt = createdAt
        self.id = id
    }
}

public struct AgentMessagePage: Codable, Sendable, Equatable {
    public let messages: [AgentMessage]
    public let hasMoreOlder: Bool
    public let hasMoreNewer: Bool
    public let nextBefore: AgentMessageCursor?
    public let nextAfter: AgentMessageCursor?

    public init(
        messages: [AgentMessage],
        hasMoreOlder: Bool,
        nextBefore: AgentMessageCursor?,
        hasMoreNewer: Bool = false,
        nextAfter: AgentMessageCursor? = nil
    ) {
        self.messages = messages
        self.hasMoreOlder = hasMoreOlder
        self.hasMoreNewer = hasMoreNewer
        self.nextBefore = nextBefore
        self.nextAfter = nextAfter
    }
}

public struct AgentThreadDraft: Codable, Sendable, Equatable {
    public let threadId: AgentThreadID
    public var providerInstanceId: String
    public var text: String
    public var attachments: [AgentAttachment]
    public var interactionMode: AgentInteractionMode
    public var updatedAt: Date

    public init(
        threadId: AgentThreadID,
        providerInstanceId: String,
        text: String,
        attachments: [AgentAttachment] = [],
        interactionMode: AgentInteractionMode = .default,
        updatedAt: Date = Date()
    ) {
        self.threadId = threadId
        self.providerInstanceId = providerInstanceId
        self.text = text
        self.attachments = attachments
        self.interactionMode = interactionMode
        self.updatedAt = updatedAt
    }
}

public enum AgentQueuedMessageDurableState: String, Codable, Sendable, Equatable {
    case queued
    case prepared
    case dispatched
}

public struct AgentQueuedMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentQueuedMessageID
    public let threadId: AgentThreadID
    public var text: String
    public var attachments: [AgentAttachment]
    public var interactionMode: AgentInteractionMode
    public var position: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var routingSnapshot: AgentQueuedMessageRoutingSnapshot?
    /// Persisted dispatch state when supplied by the host repository. Optional
    /// keeps older socket payloads decodable; locally-created rows start queued.
    public var durableState: AgentQueuedMessageDurableState?

    public init(
        id: AgentQueuedMessageID = AgentQueuedMessageID(),
        threadId: AgentThreadID,
        text: String,
        attachments: [AgentAttachment] = [],
        interactionMode: AgentInteractionMode = .default,
        position: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        routingSnapshot: AgentQueuedMessageRoutingSnapshot? = nil,
        durableState: AgentQueuedMessageDurableState? = .queued
    ) {
        self.id = id
        self.threadId = threadId
        self.text = text
        self.attachments = attachments
        self.interactionMode = interactionMode
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.routingSnapshot = routingSnapshot
        self.durableState = durableState
    }
}

/// Admission values captured with queued work. These are immutable so a later
/// thread edit cannot change the permission, deadline, or reservation used on replay.
public struct AgentQueuedMessageRoutingSnapshot: Codable, Sendable, Equatable {
    public let configuration: AgentRoutingConfiguration
    public let permissionMode: AgentPermissionMode?
    public let deadlineAt: Date?
    public let budgetTokens: Int?
    public let budgetCostMicros: Int?
    public let reservationId: String?
    public let reservedTokens: Int?
    public let reservedCostMicros: Int?
    public let admissionReceiptId: UUID?

    public init(
        configuration: AgentRoutingConfiguration,
        permissionMode: AgentPermissionMode? = nil,
        deadlineAt: Date? = nil,
        budgetTokens: Int? = nil,
        budgetCostMicros: Int? = nil,
        reservationId: String? = nil,
        reservedTokens: Int? = nil,
        reservedCostMicros: Int? = nil,
        admissionReceiptId: UUID? = nil
    ) {
        self.configuration = configuration
        self.permissionMode = permissionMode
        self.deadlineAt = deadlineAt
        self.budgetTokens = budgetTokens
        self.budgetCostMicros = budgetCostMicros
        self.reservationId = reservationId
        self.reservedTokens = reservedTokens
        self.reservedCostMicros = reservedCostMicros
        self.admissionReceiptId = admissionReceiptId
    }
}

public enum AgentMessageSendStatus: String, Codable, Sendable, Equatable {
    case started
    case queued
}

public struct AgentMessageSendResult: Codable, Sendable, Equatable {
    public let status: AgentMessageSendStatus
    public let runId: AgentRunID?
    public let queuedMessage: AgentQueuedMessage?

    public init(status: AgentMessageSendStatus, runId: AgentRunID? = nil, queuedMessage: AgentQueuedMessage? = nil) {
        self.status = status
        self.runId = runId
        self.queuedMessage = queuedMessage
    }
}

public struct AgentRun: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentRunID
    public let threadId: AgentThreadID
    public let provider: AgentProvider
    public let providerInstanceId: String?
    public let model: String
    public var status: AgentRunStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var errorMessage: String?
    /// Durable `TerminalTransitionReason.rawValue`. Nil on pre-column rows
    /// and while the run is still pending/running.
    public var terminalReason: String?

    public init(
        id: AgentRunID = AgentRunID(),
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String? = nil,
        model: String,
        status: AgentRunStatus = .running,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        errorMessage: String? = nil,
        terminalReason: String? = nil
    ) {
        self.id = id; self.threadId = threadId; self.provider = provider; self.providerInstanceId = providerInstanceId ?? provider.rawValue; self.model = model
        self.status = status; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.terminalReason = terminalReason
    }

    /// User Stop/force Stop is idle; any other cancellation stays actionable.
    public var isUserStopCancellation: Bool {
        status == .cancelled && terminalReason == "userStop"
    }
}

public struct AgentRunResult: Codable, Sendable, Equatable, Identifiable {
    public let runId: AgentRunID
    public let finalMessageId: AgentMessageID?
    public let summary: String?
    public var viewedAt: Date?
    public var attentionAcknowledgedAt: Date?

    public var id: AgentRunID { runId }

    public init(
        runId: AgentRunID,
        finalMessageId: AgentMessageID? = nil,
        summary: String? = nil,
        viewedAt: Date? = nil,
        attentionAcknowledgedAt: Date? = nil
    ) {
        self.runId = runId
        self.finalMessageId = finalMessageId
        self.summary = summary.map(AssistantToolMarkupSanitizer.strip)
            .map { String($0.prefix(500)) }
        self.viewedAt = viewedAt
        self.attentionAcknowledgedAt = attentionAcknowledgedAt
    }
}

public struct ProviderSessionRuntime: Codable, Sendable, Equatable {
    public let threadId: AgentThreadID
    public var provider: AgentProvider
    public var providerInstanceId: String?
    public var adapterKey: String?
    public var binaryIdentity: String?
    public var status: AgentRunStatus
    public var resumeCursor: String?
    public var cwd: String?
    public var model: String?
    public var serviceTier: AgentServiceTier
    public var runtimeMode: AgentPermissionMode
    public var lastRunId: AgentRunID?
    public var lastEventKind: String?
    public var lastErrorMessage: String?
    public var runtimePayloadJSON: String?
    public var updatedAt: Date

    public init(
        threadId: AgentThreadID,
        provider: AgentProvider,
        providerInstanceId: String? = nil,
        adapterKey: String? = nil,
        binaryIdentity: String? = nil,
        status: AgentRunStatus,
        resumeCursor: String? = nil,
        cwd: String? = nil,
        model: String? = nil,
        serviceTier: AgentServiceTier = .auto,
        runtimeMode: AgentPermissionMode = .supervised,
        lastRunId: AgentRunID? = nil,
        lastEventKind: String? = nil,
        lastErrorMessage: String? = nil,
        runtimePayloadJSON: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.threadId = threadId
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.adapterKey = adapterKey
        self.binaryIdentity = binaryIdentity
        self.status = status
        self.resumeCursor = resumeCursor
        self.cwd = cwd
        self.model = model
        self.serviceTier = serviceTier
        self.runtimeMode = runtimeMode
        self.lastRunId = lastRunId
        self.lastEventKind = lastEventKind
        self.lastErrorMessage = lastErrorMessage
        self.runtimePayloadJSON = runtimePayloadJSON
        self.updatedAt = updatedAt
    }
}
