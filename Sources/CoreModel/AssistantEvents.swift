import Foundation

public enum AssistantItemType: String, Codable, Sendable {
    case reasoning
    case plan
    case tool
    case assistantMessage
    case commandExecution
    case fileChange
    case mcpToolCall
    case dynamicToolCall
    case collabToolCall
    case webSearch
    case imageView
    case review
    case contextCompaction
    case error
}

public enum AssistantItemState: String, Codable, Sendable {
    case streaming
    case completed
    case failed
    case cancelled
}

public struct AssistantItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let turnId: String
    public var type: AssistantItemType
    public var state: AssistantItemState
    public var summary: String?
    public var body: String
    public var output: String?
    /// Private action target. Normal transcript rendering must show only a safe display name.
    public var resourcePath: String?
    public var progress: Double?
    /// Decode-only host-attested result of the removed Token Saver (old
    /// transcripts). Provider/parser-owned item payloads are
    /// never trusted to set this; `AssistantTimelineState` only admits `true`
    /// through `AssistantEvent.itemHostMetadata`.
    public internal(set) var distillApplied: Bool?
    public var startedAtMs: Int64
    public var finishedAtMs: Int64?

    public init(id: String, turnId: String, type: AssistantItemType, state: AssistantItemState = .streaming, summary: String? = nil, body: String = "", output: String? = nil, resourcePath: String? = nil, progress: Double? = nil, startedAtMs: Int64, finishedAtMs: Int64? = nil) {
        self.id = id; self.turnId = turnId; self.type = type; self.state = state
        self.summary = summary; self.body = body; self.output = output; self.resourcePath = resourcePath; self.progress = progress
        self.distillApplied = nil
        self.startedAtMs = startedAtMs; self.finishedAtMs = finishedAtMs
    }

    /// Returns provider-owned item content with host-only attestation removed.
    /// Callers may clear trust at a parser boundary but cannot manufacture it.
    public func withoutHostMetadata() -> AssistantItem {
        var copy = self
        copy.distillApplied = nil
        return copy
    }
}

/// Exact terminal UTF-8 identity for one provider item content channel.
/// The digest is persisted instead of another copy of potentially huge output.
public struct AssistantContentFingerprint: Codable, Sendable, Equatable {
    public let byteCount: Int
    public let sha256: Data

    public init(byteCount: Int, sha256: Data) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public var isWellFormed: Bool {
        byteCount >= 0 && sha256.count == 32
    }
}

/// Decode-only host proof that bound a (removed) Token Saver badge to the
/// complete provider bytes.
/// Optional on the wire so historical persisted metadata remains decodable.
public struct AssistantItemHostAttestation: Codable, Sendable, Equatable {
    public let itemType: AssistantItemType
    public let body: AssistantContentFingerprint
    public let output: AssistantContentFingerprint?

    public init(
        itemType: AssistantItemType,
        body: AssistantContentFingerprint,
        output: AssistantContentFingerprint?
    ) {
        self.itemType = itemType
        self.body = body
        self.output = output
    }

    public var isWellFormed: Bool {
        body.isWellFormed && (output?.isWellFormed ?? true)
    }
}

public struct AssistantSR1Translation: Codable, Sendable, Equatable {
    public var itemId: String?
    public var messageId: String?
    public var originalText: String
    public var rewrittenText: String
    /// Present only on new RCW1 records. Optional so persisted historical SR1
    /// events remain decodable without a schema migration.
    public var wireRequestText: String?

    public init(itemId: String? = nil, messageId: String? = nil, originalText: String, rewrittenText: String, wireRequestText: String? = nil) {
        self.itemId = itemId
        self.messageId = messageId
        self.originalText = originalText
        self.rewrittenText = rewrittenText
        self.wireRequestText = wireRequestText
    }
}

/// Decode-only: RCW1 request/response metadata written by Token Saver
/// (removed). Kept, like the SR1 type, so existing transcripts keep decoding.
public struct AssistantWireTranslation: Codable, Sendable, Equatable {
    public var itemId: String?
    public var messageId: String?
    public var originalText: String
    public var rewrittenText: String
    public var protocolVersion: String
    public var fallbackReason: String?
    public var wireRequestText: String?

    public init(
        itemId: String? = nil,
        messageId: String? = nil,
        originalText: String,
        rewrittenText: String,
        protocolVersion: String = "RCW1",
        fallbackReason: String? = nil,
        wireRequestText: String? = nil
    ) {
        self.itemId = itemId
        self.messageId = messageId
        self.originalText = originalText
        self.rewrittenText = rewrittenText
        self.protocolVersion = protocolVersion
        self.fallbackReason = fallbackReason
        self.wireRequestText = wireRequestText
    }
}

public enum AssistantRequestKind: String, Codable, Sendable {
    case commandExecution
    case fileRead
    case fileChange
    case applyPatch
    case exec
    case toolUserInput
    case dynamic
    case authTokensRefresh
}

public enum AssistantRequestState: String, Codable, Sendable {
    case pending
    case approved
    case declined
    case cancelled
    case resolved
    case stale
    case acknowledged
}

public struct AssistantPendingRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let turnId: String?
    public let kind: AssistantRequestKind
    public var title: String
    public var detail: String?
    public var state: AssistantRequestState
    public var createdAtMs: Int64
    public var resolvedAtMs: Int64?
    public var supportsSessionApproval: Bool?

    public var allowsSessionApproval: Bool {
        supportsSessionApproval ?? true
    }

    public init(id: String, turnId: String?, kind: AssistantRequestKind, title: String, detail: String? = nil, state: AssistantRequestState = .pending, createdAtMs: Int64, resolvedAtMs: Int64? = nil, supportsSessionApproval: Bool? = nil) {
        self.id = id
        self.turnId = turnId
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.createdAtMs = createdAtMs
        self.resolvedAtMs = resolvedAtMs
        self.supportsSessionApproval = supportsSessionApproval
    }
}

/// One selectable choice inside a structured AskUserQuestion question.
public struct AssistantUserInputOption: Codable, Sendable, Equatable, Identifiable {
    public var label: String
    public var detail: String?
    public var id: String { label }

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }
}

/// A single question inside a structured AskUserQuestion request. `id` is a
/// position-stable identity (set per request so duplicate prompt text cannot
/// collide in SwiftUI identity or per-question UI state); `prompt` is the question
/// text the provider expects back as the `answers` map key. Defaults to `prompt`
/// when no explicit id is supplied (e.g. older payloads / direct construction).
public struct AssistantUserInputQuestion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var prompt: String
    public var header: String?
    public var options: [AssistantUserInputOption]
    public var allowsMultipleSelection: Bool

    public init(id: String? = nil, prompt: String, header: String? = nil, options: [AssistantUserInputOption] = [], allowsMultipleSelection: Bool = false) {
        self.id = id ?? prompt
        self.prompt = prompt
        self.header = header
        self.options = options
        self.allowsMultipleSelection = allowsMultipleSelection
    }

    /// Stable per-question option rows. Duplicate labels stay unique without
    /// using `ForEach(..., id: \.offset)` (AvdLee list-patterns).
    public struct IdentifiedOption: Identifiable, Equatable, Sendable {
        public let id: String
        public let option: AssistantUserInputOption
    }

    public var identifiedOptions: [IdentifiedOption] {
        options.enumerated().map { index, option in
            IdentifiedOption(id: "\(id)#\(index)#\(option.label)", option: option)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, prompt, header, options, allowsMultipleSelection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? prompt
        header = try c.decodeIfPresent(String.self, forKey: .header)
        options = try c.decodeIfPresent([AssistantUserInputOption].self, forKey: .options) ?? []
        allowsMultipleSelection = try c.decodeIfPresent(Bool.self, forKey: .allowsMultipleSelection) ?? false
    }
}

public struct AssistantUserInputRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let turnId: String?
    public var prompt: String
    public var options: [String]
    public var allowsMultipleSelection: Bool
    public var isSecret: Bool
    /// Structured multi-question payload for the Claude AskUserQuestion tool.
    /// Empty for plain free-text / single-list elicitations, which keep using
    /// `prompt` + `options`.
    public var questions: [AssistantUserInputQuestion]
    /// True when this request must render as the structured AskUserQuestion picker
    /// rather than the legacy `prompt` + flat-`options` card. Single-question
    /// structured requests intentionally also mirror `options`/`allowsMultipleSelection`
    /// for the work log + legacy consumers, so branch on this, not on `options`.
    public var isStructured: Bool { !questions.isEmpty }
    public var answer: String?
    public var state: AssistantRequestState
    public var createdAtMs: Int64
    public var resolvedAtMs: Int64?

    public init(id: String, turnId: String?, prompt: String, options: [String] = [], allowsMultipleSelection: Bool = false, isSecret: Bool = false, questions: [AssistantUserInputQuestion] = [], answer: String? = nil, state: AssistantRequestState = .pending, createdAtMs: Int64, resolvedAtMs: Int64? = nil) {
        self.id = id
        self.turnId = turnId
        self.prompt = prompt
        self.options = options
        self.allowsMultipleSelection = allowsMultipleSelection
        self.isSecret = isSecret
        self.questions = questions
        self.answer = answer
        self.state = state
        self.createdAtMs = createdAtMs
        self.resolvedAtMs = resolvedAtMs
    }

    /// Stable legacy option rows. Duplicate labels stay unique without `id: \.self`.
    public struct IdentifiedOption: Identifiable, Equatable, Sendable {
        public let id: String
        public let option: String
    }

    public var identifiedOptions: [IdentifiedOption] {
        options.enumerated().map { index, option in
            IdentifiedOption(id: "\(id)#\(index)#\(option)", option: option)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, turnId, prompt, options, allowsMultipleSelection, isSecret, questions, answer, state, createdAtMs, resolvedAtMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
        prompt = try c.decode(String.self, forKey: .prompt)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        allowsMultipleSelection = try c.decodeIfPresent(Bool.self, forKey: .allowsMultipleSelection) ?? false
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        questions = try c.decodeIfPresent([AssistantUserInputQuestion].self, forKey: .questions) ?? []
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        state = try c.decodeIfPresent(AssistantRequestState.self, forKey: .state) ?? .pending
        createdAtMs = try c.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        resolvedAtMs = try c.decodeIfPresent(Int64.self, forKey: .resolvedAtMs)
    }
}

public struct AssistantPendingCallbacksSnapshot: Codable, Sendable, Equatable {
    public var requests: [AssistantPendingRequest]
    public var userInputs: [AssistantUserInputRequest]

    public init(requests: [AssistantPendingRequest] = [], userInputs: [AssistantUserInputRequest] = []) {
        self.requests = requests
        self.userInputs = userInputs
    }
}

public enum AssistantTokenUsageSemantics: String, Codable, Sendable {
    /// This event is an independent provider charge and must be added to earlier
    /// incremental events from the same RemoteCode run.
    case incremental
    /// This event replaces an earlier snapshot for the same RemoteCode run.
    case cumulative
}

public struct AssistantTokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var contextWindow: Int?
    public var compactsAutomatically: Bool?
    /// Cache-token split (G3). `inputTokens` stays the billed total
    /// (uncached + creation + read) for back-compat; these break it out so net
    /// dollars are computable (a cache read is ~0.1x an uncached token). nil when
    /// the provider does not report a breakdown. Optional => decode tolerates older
    /// rows/payloads that omit the keys (version-skew safe).
    public var uncachedInputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var cacheReadInputTokens: Int?
    /// Provider-reported billed cost in micros. Nil means this provider/runtime
    /// did not return a verifiable monetary amount for the turn.
    public var reportedCostMicros: Int?
    /// Current context-window occupancy for a single request/turn.
    /// Distinct from `totalTokens`, which may be session-cumulative billing
    /// (e.g. Claude/Grok `modelUsage` cache re-reads summed across the session).
    /// nil when the payload is only cumulative, or when older rows omit the key.
    public var contextTokens: Int?
    /// Provider accounting contract for this event. Optional so persisted
    /// timelines written before the field existed remain decodable. Callers that
    /// do not specify a value retain the historical cumulative-snapshot contract.
    public var semantics: AssistantTokenUsageSemantics?

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
        contextWindow: Int? = nil,
        compactsAutomatically: Bool? = nil,
        uncachedInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        reportedCostMicros: Int? = nil,
        contextTokens: Int? = nil,
        semantics: AssistantTokenUsageSemantics? = .cumulative
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.contextWindow = contextWindow
        self.compactsAutomatically = compactsAutomatically
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.reportedCostMicros = reportedCostMicros
        self.contextTokens = contextTokens
        self.semantics = semantics
    }

    public var resolvedSemantics: AssistantTokenUsageSemantics {
        semantics ?? .cumulative
    }

    public var billedInputTokenUnits: Double {
        let uncached = uncachedInputTokens ?? max(0, inputTokens - (cacheCreationInputTokens ?? 0) - (cacheReadInputTokens ?? 0))
        let creation = cacheCreationInputTokens ?? 0
        let read = cacheReadInputTokens ?? 0
        return TokenBillingWeights.default.inputUnits(
            uncached: uncached,
            cacheCreation: creation,
            cacheRead: read
        )
    }

    public var billedTotalTokenUnits: Double {
        billedInputTokenUnits + (Double(max(0, outputTokens)) * TokenBillingWeights.default.output)
    }

    /// Merge a later tokenUsage event with the one already on the timeline.
    /// - `contextTokens`: latest non-nil wins (a cumulative event must not erase
    ///   a known per-request occupancy).
    /// - Billing totals (`totalTokens` / cache split / cost): the larger
    ///   `totalTokens` wins so a small per-request payload cannot wipe
    ///   session-cumulative modelUsage billing figures.
    public static func merging(_ existing: AssistantTokenUsage, with incoming: AssistantTokenUsage) -> AssistantTokenUsage {
        let preferIncomingBilling = incoming.totalTokens >= existing.totalTokens
        let billing = preferIncomingBilling ? incoming : existing
        let other = preferIncomingBilling ? existing : incoming
        return AssistantTokenUsage(
            inputTokens: billing.inputTokens,
            outputTokens: billing.outputTokens,
            totalTokens: billing.totalTokens,
            contextWindow: incoming.contextWindow ?? existing.contextWindow,
            compactsAutomatically: incoming.compactsAutomatically ?? existing.compactsAutomatically,
            uncachedInputTokens: billing.uncachedInputTokens ?? other.uncachedInputTokens,
            cacheCreationInputTokens: billing.cacheCreationInputTokens ?? other.cacheCreationInputTokens,
            cacheReadInputTokens: billing.cacheReadInputTokens ?? other.cacheReadInputTokens,
            reportedCostMicros: billing.reportedCostMicros ?? other.reportedCostMicros,
            contextTokens: incoming.contextTokens ?? existing.contextTokens,
            semantics: billing.semantics ?? other.semantics
        )
    }
}

public struct TokenBillingWeights: Codable, Sendable, Equatable {
    public let uncachedInput: Double
    public let cacheCreationInput: Double
    public let cacheReadInput: Double
    public let output: Double

    public init(
        uncachedInput: Double = 1.0,
        cacheCreationInput: Double = 1.25,
        cacheReadInput: Double = 0.1,
        output: Double = 1.0
    ) {
        self.uncachedInput = max(0, uncachedInput)
        self.cacheCreationInput = max(0, cacheCreationInput)
        self.cacheReadInput = max(0, cacheReadInput)
        self.output = max(0, output)
    }

    public static let `default` = TokenBillingWeights()

    public func inputUnits(uncached: Int, cacheCreation: Int, cacheRead: Int) -> Double {
        (Double(max(0, uncached)) * uncachedInput)
            + (Double(max(0, cacheCreation)) * cacheCreationInput)
            + (Double(max(0, cacheRead)) * cacheReadInput)
    }
}

public struct AssistantAccountUsage: Codable, Sendable, Equatable {
    public let provider: AgentProvider
    public let weeklyUsedPercent: Double
    public let weeklyWindowDurationMinutes: Int?
    public let weeklyResetsAtMs: Int64?
    public let currentSessionUsedPercent: Double?
    public let currentSessionResetsAtMs: Int64?

    public init(
        provider: AgentProvider,
        weeklyUsedPercent: Double,
        weeklyWindowDurationMinutes: Int? = nil,
        weeklyResetsAtMs: Int64? = nil,
        currentSessionUsedPercent: Double? = nil,
        currentSessionResetsAtMs: Int64? = nil
    ) {
        self.provider = provider
        self.weeklyUsedPercent = min(max(weeklyUsedPercent, 0), 100)
        self.weeklyWindowDurationMinutes = weeklyWindowDurationMinutes
        self.weeklyResetsAtMs = weeklyResetsAtMs
        self.currentSessionUsedPercent = currentSessionUsedPercent.map { min(max($0, 0), 100) }
        self.currentSessionResetsAtMs = currentSessionResetsAtMs
    }
}

public struct AssistantProposedPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let turnId: String?
    public var markdown: String
    public var implementedAtMs: Int64?

    public init(id: String, turnId: String?, markdown: String, implementedAtMs: Int64? = nil) {
        self.id = id
        self.turnId = turnId
        self.markdown = markdown
        self.implementedAtMs = implementedAtMs
    }

    public var exportTitle: String {
        Self.exportTitle(for: markdown)
    }

    public var exportFileName: String {
        Self.exportFileName(for: markdown)
    }

    public var collapsedPreview: String {
        Self.collapsedPreview(for: markdown)
    }

    public var isImplemented: Bool {
        implementedAtMs != nil
    }

    public var showsImplementationActions: Bool {
        !isImplemented
    }

    // PERF: exportTitle/exportFileName are read from SwiftUI proposed-plan cards
    // (title + save-as name) and recompiled markdown/list/whitespace strip patterns
    // on every body evaluation. Compile once; matching is thread-safe.
    private static let exportHeadingPrefixRegex = try! NSRegularExpression(pattern: #"^#{1,6}\s*"#)
    private static let exportNumberedPrefixRegex = try! NSRegularExpression(pattern: #"^\d+[\.)]\s*"#)
    private static let exportBulletPrefixRegex = try! NSRegularExpression(pattern: #"^[-*]\s*"#)
    private static let exportWhitespaceCollapseRegex = try! NSRegularExpression(pattern: #"\s+"#)
    private static let exportHyphenCollapseRegex = try! NSRegularExpression(pattern: #"-+"#)
    // PERF: exportFileName also allocated CharacterSet.union / charactersIn on
    // every card body evaluation for filename sanitization.
    private static let exportFileNameAllowedScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_ "))
    private static let exportFileNameEdgeTrimSet = CharacterSet(charactersIn: "-_ ")

    private static func replaceAll(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    public static func exportTitle(for markdown: String) -> String {
        let fallback = "Proposed Plan"
        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var stripped = trimmed
            stripped = replaceAll(exportHeadingPrefixRegex, in: stripped, with: "")
            stripped = replaceAll(exportNumberedPrefixRegex, in: stripped, with: "")
            stripped = replaceAll(exportBulletPrefixRegex, in: stripped, with: "")
            stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            return String(stripped.prefix(80))
        }
        return fallback
    }

    public static func exportFileName(for markdown: String) -> String {
        let title = exportTitle(for: markdown).unicodeScalars.map { scalar -> Character in
            exportFileNameAllowedScalars.contains(scalar) ? Character(scalar) : "-"
        }
        var collapsed = String(title)
        collapsed = replaceAll(exportWhitespaceCollapseRegex, in: collapsed, with: "-")
        collapsed = replaceAll(exportHyphenCollapseRegex, in: collapsed, with: "-")
        collapsed = collapsed
            .trimmingCharacters(in: exportFileNameEdgeTrimSet)
            .lowercased()
        return "\(collapsed.isEmpty ? "proposed-plan" : String(collapsed.prefix(64))).md"
    }

    public static func collapsedPreview(for markdown: String, maxLines: Int = 10) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxLines else { return markdown }
        return lines.prefix(maxLines).joined(separator: "\n")
    }
}

public enum AssistantPlanStepStatus: String, Codable, Sendable, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct AssistantPlanStep: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var status: AssistantPlanStepStatus

    public init(id: String, title: String, status: AssistantPlanStepStatus) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct AssistantActivePlan: Codable, Sendable, Equatable {
    public var explanation: String?
    public var steps: [AssistantPlanStep]
    public var updatedAtMs: Int64

    public init(explanation: String? = nil, steps: [AssistantPlanStep], updatedAtMs: Int64) {
        self.explanation = explanation
        self.steps = steps
        self.updatedAtMs = updatedAtMs
    }

    /// Upper bound of `JSONEncoder`-encoded size for compact recovery budget checks.
    ///
    /// WHY: `activePlanUpdated` used to `JSONEncoder().encode(plan)` on every plan
    /// stream event solely to enforce a byte ceiling. UTF-8 payload sums with
    /// escape headroom avoid that allocation while remaining ≥ true wire size.
    ///
    /// Escape model: every UTF-8 byte may expand to a JSON `\u00XX` sequence
    /// (6 ASCII bytes) in the worst case (control characters). Multi-byte UTF-8
    /// and ordinary ASCII are smaller on the wire, so this is intentionally
    /// conservative — may reject edge plans near the ceiling that would still
    /// fit true JSON, never admits oversize recovery state.
    public var estimatedCompactJSONBytes: Int {
        // Object skeleton + key names + updatedAtMs digits + commas/braces.
        var total = 96
        if let explanation {
            total += Self.jsonStringUpperBoundBytes(explanation)
        } else {
            total += 4 // null
        }
        total += 16 // "steps":[]
        for step in steps {
            // {"id":"...","title":"...","status":"in_progress"}
            total += 64
                + Self.jsonStringUpperBoundBytes(step.id)
                + Self.jsonStringUpperBoundBytes(step.title)
                + step.status.rawValue.utf8.count
        }
        return total
    }

    /// Worst-case JSON string payload size including surrounding quotes.
    /// Control bytes encode as `\u00XX` (6); quotes/backslashes as 2 — 6 covers both.
    private static func jsonStringUpperBoundBytes(_ value: String) -> Int {
        2 + value.utf8.count * 6
    }
}

/// Compact correctness state that survives transcript retention. Transcript
/// events are replay/display data and may be evicted; these fields are the
/// minimum needed to resume an interrupted turn without losing an active plan
/// or an outstanding provider interaction.
public struct AgentActiveThreadState: Codable, Sendable, Equatable {
    public var resumeCursor: String?
    public var activeTurnId: String?
    public var activePlan: AssistantActivePlan?
    public var pendingApprovalRequestIds: [String]
    public var pendingUserInputRequestIds: [String]

    public init(
        resumeCursor: String? = nil,
        activeTurnId: String? = nil,
        activePlan: AssistantActivePlan? = nil,
        pendingApprovalRequestIds: [String] = [],
        pendingUserInputRequestIds: [String] = []
    ) {
        self.resumeCursor = resumeCursor
        self.activeTurnId = activeTurnId
        self.activePlan = activePlan
        self.pendingApprovalRequestIds = pendingApprovalRequestIds
        self.pendingUserInputRequestIds = pendingUserInputRequestIds
    }
}

public struct ProviderRuntimeEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var provider: AgentProvider
    public var source: String
    public var method: String
    public var providerTurnId: String?
    public var providerItemId: String?
    public var providerRequestId: String?
    public var payloadJSON: String
    public var receivedAtMs: Int64

    public init(id: String = UUID().uuidString,
                provider: AgentProvider,
                source: String,
                method: String,
                providerTurnId: String? = nil,
                providerItemId: String? = nil,
                providerRequestId: String? = nil,
                payloadJSON: String,
                receivedAtMs: Int64) {
        self.id = id
        self.provider = provider
        self.source = source
        self.method = method
        self.providerTurnId = providerTurnId
        self.providerItemId = providerItemId
        self.providerRequestId = providerRequestId
        self.payloadJSON = payloadJSON
        self.receivedAtMs = receivedAtMs
    }

    public static func fromJSONLine(_ line: String, provider: AgentProvider, source: String, receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> ProviderRuntimeEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return fromJSONObject(obj, provider: provider, source: source, receivedAtMs: receivedAtMs)
    }

    /// Host bookkeeping from the Distill adapter: `{sessionId, acceptedModel}` when a
    /// Distill session accepts a prompt, `{sessionId, historyRejected: true}` when
    /// the provider rejected that session's history. The coordinator persists it in
    /// the provider session runtime payload so a restart knows the session's model
    /// family and never re-loads a rejected session.
    public static let distillSessionStateMethod = "remotecode.distill.session_state"

    /// Token-stream methods already render as Thought / answer prose. Emitting them
    /// into the Work log rewrites a strip *above* the user message on every token
    /// (Grok `thought`/`text`, Claude `content_block_delta`, …).
    public var surfacesInWorkLog: Bool {
        switch method {
        case "thought", "text",
             "content_block_delta", "content_block_start", "content_block_stop",
             "message_start", "message_delta", "message_stop",
             "ping", "input_json_delta",
             Self.distillSessionStateMethod:
            return false
        default:
            return true
        }
    }

    /// Token-rate stream types already become `itemDelta`. Building
    /// `providerRuntime` still `JSONSerialization.data(.sortedKeys)` the full
    /// payload, persists a second stream row + provider log, and EventBus-
    /// publishes `agent.provider_runtime.event` (~30 Hz). Grok CLI already
    /// omits `thought`/`text`; Codex app-server omits `/delta`;
    /// `codex exec --json` still used to emit `item.delta`.
    public static func isHighFrequencyStreamingMethod(_ method: String) -> Bool {
        switch method {
        case "thought", "text",
             "content_block_delta", "input_json_delta", "ping",
             "item.delta":
            return true
        default:
            return false
        }
    }

    /// Distill/Grok ACP `x.ai/session_notification` update that streams tool-call
    /// arguments a few bytes at a time. The same arguments arrive whole on the
    /// tool item and no client reads the chunks, but each one cost a stream row:
    /// a single tool call pushed every earlier tool item out of the per-thread
    /// replay window that paired devices hydrate from.
    public var isToolCallArgumentChunk: Bool {
        guard method == "x.ai/session_notification" || method == "_x.ai/session_notification",
              payloadJSON.contains("tool_call_delta_chunk"),
              let data = payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let update = payload["update"] as? [String: Any] else { return false }
        return update["sessionUpdate"] as? String == "tool_call_delta_chunk"
    }

    private static let liveStatusCarrierKindPrefixes = [
        "auto_compact_", "subagent_", "model_changed", "goal_updated", "scheduled_task_"
    ]

    /// Methods that drive the Distill live status strip (operation phase, guest
    /// stage, subagents, compaction, goal, model). Paired devices fold the same
    /// events, so these must reach them live, not only on the next thread read.
    public static func isLiveStatusCarrier(method: String) -> Bool {
        method == "_remotecode/operation" || method == "remotecode/guest_stage"
            || method == "x.ai/session_notification" || method == "x.ai/session/update"
            || method == "_x.ai/session_notification" || method == "_x.ai/session/update"
            || liveStatusCarrierKindPrefixes.contains(where: { method.hasPrefix($0) })
    }

    /// Skip token-rate lines (and SDK `stream_event` wrappers around them).
    /// Lifecycle / tool / error objects still emit.
    public static func shouldEmitFromDecodedStreamObject(_ obj: [String: Any]) -> Bool {
        guard let method = obj["type"] as? String else { return true }
        if isHighFrequencyStreamingMethod(method) { return false }
        if method == "stream_event",
           let inner = obj["event"] as? [String: Any],
           let innerType = inner["type"] as? String {
            return !isHighFrequencyStreamingMethod(innerType)
        }
        return true
    }

    /// Same as `fromJSONObject` but skips the sortedKeys serialize when the
    /// line is already represented as `itemDelta`.
    public static func fromJSONObjectIfNeeded(
        _ obj: [String: Any],
        provider: AgentProvider,
        source: String,
        receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> ProviderRuntimeEvent? {
        guard shouldEmitFromDecodedStreamObject(obj) else { return nil }
        return fromJSONObject(obj, provider: provider, source: source, receivedAtMs: receivedAtMs)
    }

    /// F12: dict-accepting variant so a caller that has already decoded the line
    /// (e.g. ClaudeStreamingCLIAdapter.handleLine) does not pay a second
    /// JSONSerialization decode of the same line just to build the runtime event.
    public static func fromJSONObject(_ obj: [String: Any], provider: AgentProvider, source: String, receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> ProviderRuntimeEvent? {
        guard let method = obj["type"] as? String else { return nil }
        let payload = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let nested = obj["item"] as? [String: Any]
        let message = obj["message"] as? [String: Any]
        return ProviderRuntimeEvent(
            provider: provider,
            source: source,
            method: method,
            providerTurnId: obj["turn_id"] as? String ?? message?["id"] as? String,
            providerItemId: obj["item_id"] as? String ?? nested?["id"] as? String ?? obj["id"] as? String,
            providerRequestId: obj["request_id"] as? String,
            payloadJSON: payload,
            receivedAtMs: receivedAtMs
        )
    }
}

public enum AssistantWorkActivityKind: String, Codable, Sendable, Equatable {
    case runtime
    case tool
    case request
    case userInput
    case error
}

public struct AssistantWorkActivity: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: AssistantWorkActivityKind
    public var title: String
    public var detail: String?
    public var state: String?
    public var createdAtMs: Int64

    public init(id: String,
                kind: AssistantWorkActivityKind,
                title: String,
                detail: String? = nil,
                state: String? = nil,
                createdAtMs: Int64) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.createdAtMs = createdAtMs
    }
}

public enum AgentPlanImplementationPrompt {
    public static func make(markdown: String) -> String {
        """
        Implement this proposed plan now.

        Constraints:
        - Keep the implementation scoped to this plan.
        - Preserve unrelated user changes.
        - Run the smallest reliable tests that prove the change.
        - Report proof and any remaining risk.

        Proposed plan:
        \(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}

public enum AssistantEvent: Codable, Sendable, Equatable {
    case threadStarted(threadId: String, providerThreadId: String?)
    case turnStarted(turnId: String)
    case itemStarted(item: AssistantItem)
    case itemDelta(itemId: String, bodyAppend: String?, outputAppend: String?, summary: String?)
    case itemState(itemId: String, state: AssistantItemState)
    case itemProgress(itemId: String, progress: Double?)
    case itemCompleted(itemId: String, finalState: AssistantItemState)
    /// Host-only metadata channel. Keeping trust out of parser-owned
    /// `itemStarted`/`itemDelta` payloads prevents provider text from minting UI truth.
    case itemHostMetadata(
        turnId: String,
        itemId: String,
        distillApplied: Bool?,
        attestation: AssistantItemHostAttestation? = nil
    )
    case turnCompleted(turnId: String, finalMessage: String?)
    case proposedPlan(AssistantProposedPlan)
    case activePlanUpdated(AssistantActivePlan)
    case requestOpened(AssistantPendingRequest)
    case requestResolved(requestId: String, state: AssistantRequestState)
    case userInputRequested(AssistantUserInputRequest)
    case userInputResolved(requestId: String, answer: String?)
    case tokenUsage(AssistantTokenUsage)
    case accountUsage(AssistantAccountUsage)
    case contextCompaction(summary: String?)
    case providerRuntime(ProviderRuntimeEvent)
    case wireTranslation(AssistantWireTranslation)
    case sr1Translation(AssistantSR1Translation)
    case error(message: String, recoverable: Bool)

    public var debugDescription: String {
        switch self {
        case .threadStarted(let t, _): return "threadStarted(\(t))"
        case .turnStarted(let t): return "turnStarted(\(t))"
        case .itemStarted(let i): return "itemStarted(\(i.id) \(i.type.rawValue))"
        case .itemDelta(let i, _, _, _): return "itemDelta(\(i))"
        case .itemState(let i, let s): return "itemState(\(i) -> \(s.rawValue))"
        case .itemProgress(let i, let p): return "itemProgress(\(i) -> \(p ?? -1))"
        case .itemCompleted(let i, let s): return "itemCompleted(\(i) -> \(s.rawValue))"
        case .itemHostMetadata(let t, let i, let applied, _): return "itemHostMetadata(\(t)/\(i) distill=\(applied == true))"
        case .turnCompleted(let t, _): return "turnCompleted(\(t))"
        case .proposedPlan(let p): return "proposedPlan(\(p.id))"
        case .activePlanUpdated(let p): return "activePlanUpdated(\(p.steps.count))"
        case .requestOpened(let r): return "requestOpened(\(r.id) \(r.kind.rawValue))"
        case .requestResolved(let r, let s): return "requestResolved(\(r) -> \(s.rawValue))"
        case .userInputRequested(let r): return "userInputRequested(\(r.id))"
        case .userInputResolved(let r, _): return "userInputResolved(\(r))"
        case .tokenUsage(let u): return "tokenUsage(\(u.totalTokens))"
        case .accountUsage(let u): return "accountUsage(\(u.provider.rawValue) \(Int(u.weeklyUsedPercent.rounded()))%)"
        case .contextCompaction: return "contextCompaction"
        case .providerRuntime(let e): return "providerRuntime(\(e.provider.rawValue) \(e.method))"
        case .wireTranslation(let t): return "wireTranslation(\(t.itemId ?? t.messageId ?? "-"))"
        case .sr1Translation(let t): return "sr1Translation(\(t.itemId ?? t.messageId ?? "-"))"
        case .error(let m, _): return "error(\(m))"
        }
    }

    /// Cheap upper-bound for hot-queue / hot-replay admission sizing.
    ///
    /// WHY: `JSONEncoder().encode(event)` on every stream token allocated a full
    /// encoder + Data graph thousands of times per second on the Agent App path.
    /// UTF-8 payload sums are O(1) per string and intentionally slightly high so
    /// the queue becomes *more* eviction-eager under pressure, never less
    /// protective than true wire size for typical payloads.
    public var estimatedHotQueueBytes: Int {
        // Envelope covers type tag + JSON keys + UUID/int scaffolding.
        let envelope = 128
        func s(_ value: String?) -> Int { value?.utf8.count ?? 0 }
        switch self {
        case .threadStarted(let t, let p):
            return envelope + t.utf8.count + s(p)
        case .turnStarted(let t):
            return envelope + t.utf8.count
        case .itemStarted(let item):
            return envelope
                + item.id.utf8.count + item.turnId.utf8.count
                + item.body.utf8.count + s(item.output) + s(item.summary) + s(item.resourcePath)
        case .itemDelta(let id, let body, let output, let summary):
            return envelope + id.utf8.count + s(body) + s(output) + s(summary)
        case .itemState(let id, _):
            return envelope + id.utf8.count
        case .itemProgress(let id, _):
            return envelope + id.utf8.count
        case .itemCompleted(let id, _):
            return envelope + id.utf8.count
        case .itemHostMetadata(let turnId, let itemId, _, let attestation):
            return envelope + turnId.utf8.count + itemId.utf8.count
                + (attestation == nil ? 8 : 128)
        case .turnCompleted(let t, let final):
            return envelope + t.utf8.count + s(final)
        case .proposedPlan(let plan):
            return envelope + plan.id.utf8.count + s(plan.turnId) + plan.markdown.utf8.count
        case .activePlanUpdated(let plan):
            var total = envelope + s(plan.explanation)
            for step in plan.steps {
                total += step.id.utf8.count + step.title.utf8.count
            }
            return total
        case .requestOpened(let request):
            return envelope + request.id.utf8.count + s(request.turnId)
                + request.title.utf8.count + s(request.detail)
        case .requestResolved(let id, _):
            return envelope + id.utf8.count
        case .userInputRequested(let request):
            var total = envelope + request.id.utf8.count + s(request.turnId)
                + request.prompt.utf8.count + s(request.answer)
            for option in request.options { total += option.utf8.count }
            for question in request.questions {
                total += question.id.utf8.count + question.prompt.utf8.count + s(question.header)
                for option in question.options {
                    total += option.label.utf8.count + s(option.detail)
                }
            }
            return total
        case .userInputResolved(let id, let answer):
            return envelope + id.utf8.count + s(answer)
        case .tokenUsage:
            return envelope + 64
        case .accountUsage:
            return envelope + 96
        case .contextCompaction(let summary):
            return envelope + s(summary)
        case .providerRuntime(let event):
            return envelope
                + event.id.utf8.count + event.source.utf8.count + event.method.utf8.count
                + s(event.providerTurnId) + s(event.providerItemId)
                + s(event.providerRequestId) + event.payloadJSON.utf8.count
        case .wireTranslation(let translation):
            return envelope
                + s(translation.itemId) + s(translation.messageId)
                + translation.originalText.utf8.count + translation.rewrittenText.utf8.count
                + translation.protocolVersion.utf8.count + s(translation.fallbackReason)
                + s(translation.wireRequestText)
        case .sr1Translation(let translation):
            return envelope
                + s(translation.itemId) + s(translation.messageId)
                + translation.originalText.utf8.count + translation.rewrittenText.utf8.count
                + s(translation.wireRequestText)
        case .error(let message, _):
            return envelope + message.utf8.count
        }
    }
}

public struct AssistantTurnSnapshot: Codable, Sendable, Equatable {
    public let turnId: String
    public var items: [AssistantItem]
    public var finalAssistantMessage: String?
    public var finished: Bool
    /// Wall-clock when the turn opened (turnStarted). Used for transcript ordering
    /// while the turn still has no items — without this, empty turns sort at epoch 0
    /// and briefly render *above* the user message that triggered them.
    public var startedAtMs: Int64?

    public init(turnId: String,
                items: [AssistantItem] = [],
                finalAssistantMessage: String? = nil,
                finished: Bool = false,
                startedAtMs: Int64? = nil) {
        self.turnId = turnId
        self.items = items
        self.finalAssistantMessage = finalAssistantMessage
        self.finished = finished
        self.startedAtMs = startedAtMs
    }
}

public struct AssistantTimelineState: Codable, Sendable, Equatable {
    /// Per-item live caps for a 16 GB MacBook class machine. Large enough for
    /// real tool dumps (Chrome HTML, shell) while still bounding SwiftUI paint cost.
    public static let liveTextLimit = 200_000
    public static let liveOutputLimit = 400_000
    // Memory ceiling, NOT a display window. Sized at/above the DB's per-thread stream-event
    // prune cap (~5000) so turns can never be the truncation point — reopening a long thread
    // shows 100% of its turns. The bound still exists as a pathological-OOM backstop; total
    // in-memory text stays bounded because the DB itself prunes events to ~5000 per thread,
    // and the LazyVStack only realizes on-screen rows.
    public static let liveTurnLimit = 5_000
    // F10: pathological backstop mirroring `liveTurnLimit`. A single turn with this
    // many items (e.g. thousands of tool calls in one response) trims its oldest items
    // so one turn cannot grow its `items` array without bound. Newest items are kept,
    // so the active streaming item (always newest) and its delta lookups are unaffected.
    public static let liveTurnItemLimit = 5_000
    public static let providerRuntimeEventLimit = 500
    public static let workActivityLimit = 120
    public static let pendingRequestLimit = 200
    public static let proposedPlanLimit = 50
    // F39: bound for the itemDelta-before-itemStarted pairing buffer. Orphan ids
    // (per-line UUID fallbacks, items evicted by trimTurnItems) never pair, so
    // without a cap the buffer grows monotonically for the life of the timeline.
    public static let pendingItemDeltaLimit = 64
    /// Aggregate live timeline text ceiling for one selected thread.
    /// Keeps multi-turn tool storms visible without letting one tab pin multi-GB.
    /// Was 96 MiB; 32 MiB matches hot-replay payload ceiling (memory-loop tip).
    public static let aggregateHotTextByteLimit = 32 * 1_024 * 1_024
    private static let aggregateHotElementOverhead = 128

    public var threadId: String?
    public var providerThreadId: String?
    public var turns: [AssistantTurnSnapshot]
    public var workActivities: [AssistantWorkActivity]
    public var error: String?
    public var pendingRequests: [AssistantPendingRequest]
    public var pendingUserInputs: [AssistantUserInputRequest]
    public var proposedPlans: [AssistantProposedPlan]
    public var activePlan: AssistantActivePlan?
    public var tokenUsage: AssistantTokenUsage?
    public var contextCompactionSummary: String?
    public var providerRuntimeEvents: [ProviderRuntimeEvent]
    /// Legacy persisted field names retained for decoding existing workflow state.
    /// New RCW1 events are adapted into these presentation-only maps.
    public var sr1TranslationsByItemId: [String: AssistantSR1Translation]
    public var sr1TranslationsByMessageId: [String: AssistantSR1Translation]

    /// Injective identity for an evictable provider item inside one turn.
    /// Provider item IDs may repeat after a turn boundary.
    public static func sr1TimelineItemTranslationKey(
        turnId: String,
        itemId: String
    ) -> String {
        "item|\(turnId.utf8.count)|\(turnId)|\(itemId.utf8.count)|\(itemId)"
    }
    private var pendingItemDeltas: [String: PendingItemDelta]
    // F39: insertion order of pendingItemDeltas keys so the cap evicts oldest-first
    // (Dictionary has no stable order; a legit early-arriving delta is always the
    // newest entry and must survive eviction until its itemStarted lands).
    private var pendingItemDeltaOrder: [String]
    /// Last exact `aggregateHotTextByteCount` from enforce/evict. Optional so
    /// persisted snapshots without the key still decode.
    private var lastMeasuredAggregateHotTextBytes: Int? = nil
    /// Upper bound of hot-text growth since last exact measure (`apply` event
    /// estimates). Optional for the same Codable compatibility.
    private var aggregateHotTextDirtyBytes: Int? = nil
    /// Incremental id → (turn, item) coordinates. History replay, progress, and
    /// deltas targeting older items used to newest-first scan from the live end
    /// (~N comparisons for an item near the start). The map is derived from
    /// `turns`, excluded from Codable, and rebuilt after decode/prune.
    private var itemLocations: [String: ItemLocation] = [:]
    /// Incremental turnId → index. Same derived/non-persisted contract as
    /// `itemLocations`; last occurrence wins so it matches newest-first lookup.
    private var turnLocations: [String: Int] = [:]

    private struct ItemLocation: Sendable, Equatable {
        var turnIndex: Int
        var itemIndex: Int
    }

    private struct PendingItemDelta: Codable, Sendable, Equatable {
        var body: String = ""
        var output: String = ""
        var summary: String?
        var distillApplied: Bool?
    }

    public init() {
        self.turns = []
        self.workActivities = []
        self.pendingRequests = []
        self.pendingUserInputs = []
        self.proposedPlans = []
        self.providerRuntimeEvents = []
        self.sr1TranslationsByItemId = [:]
        self.sr1TranslationsByMessageId = [:]
        self.pendingItemDeltas = [:]
        self.pendingItemDeltaOrder = []
    }

    /// Location maps are derived from `turns` and must not bloat persisted
    /// snapshots. Rebuild after decode so lookups stay O(1) on reopen.
    private enum CodingKeys: String, CodingKey {
        case threadId
        case providerThreadId
        case turns
        case workActivities
        case error
        case pendingRequests
        case pendingUserInputs
        case proposedPlans
        case activePlan
        case tokenUsage
        case contextCompactionSummary
        case providerRuntimeEvents
        case sr1TranslationsByItemId
        case sr1TranslationsByMessageId
        case pendingItemDeltas
        case pendingItemDeltaOrder
        case lastMeasuredAggregateHotTextBytes
        case aggregateHotTextDirtyBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try c.decodeIfPresent(String.self, forKey: .threadId)
        providerThreadId = try c.decodeIfPresent(String.self, forKey: .providerThreadId)
        turns = try c.decodeIfPresent([AssistantTurnSnapshot].self, forKey: .turns) ?? []
        workActivities = try c.decodeIfPresent([AssistantWorkActivity].self, forKey: .workActivities) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        pendingRequests = try c.decodeIfPresent([AssistantPendingRequest].self, forKey: .pendingRequests) ?? []
        pendingUserInputs = try c.decodeIfPresent([AssistantUserInputRequest].self, forKey: .pendingUserInputs) ?? []
        proposedPlans = try c.decodeIfPresent([AssistantProposedPlan].self, forKey: .proposedPlans) ?? []
        activePlan = try c.decodeIfPresent(AssistantActivePlan.self, forKey: .activePlan)
        tokenUsage = try c.decodeIfPresent(AssistantTokenUsage.self, forKey: .tokenUsage)
        contextCompactionSummary = try c.decodeIfPresent(String.self, forKey: .contextCompactionSummary)
        providerRuntimeEvents = try c.decodeIfPresent([ProviderRuntimeEvent].self, forKey: .providerRuntimeEvents) ?? []
        sr1TranslationsByItemId = try c.decodeIfPresent([String: AssistantSR1Translation].self, forKey: .sr1TranslationsByItemId) ?? [:]
        sr1TranslationsByMessageId = try c.decodeIfPresent([String: AssistantSR1Translation].self, forKey: .sr1TranslationsByMessageId) ?? [:]
        pendingItemDeltas = try c.decodeIfPresent([String: PendingItemDelta].self, forKey: .pendingItemDeltas) ?? [:]
        pendingItemDeltaOrder = try c.decodeIfPresent([String].self, forKey: .pendingItemDeltaOrder) ?? []
        lastMeasuredAggregateHotTextBytes = try c.decodeIfPresent(Int.self, forKey: .lastMeasuredAggregateHotTextBytes)
        aggregateHotTextDirtyBytes = try c.decodeIfPresent(Int.self, forKey: .aggregateHotTextDirtyBytes)
        rebuildLocationIndex()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(threadId, forKey: .threadId)
        try c.encodeIfPresent(providerThreadId, forKey: .providerThreadId)
        try c.encode(turns, forKey: .turns)
        try c.encode(workActivities, forKey: .workActivities)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(pendingRequests, forKey: .pendingRequests)
        try c.encode(pendingUserInputs, forKey: .pendingUserInputs)
        try c.encode(proposedPlans, forKey: .proposedPlans)
        try c.encodeIfPresent(activePlan, forKey: .activePlan)
        try c.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
        try c.encodeIfPresent(contextCompactionSummary, forKey: .contextCompactionSummary)
        try c.encode(providerRuntimeEvents, forKey: .providerRuntimeEvents)
        try c.encode(sr1TranslationsByItemId, forKey: .sr1TranslationsByItemId)
        try c.encode(sr1TranslationsByMessageId, forKey: .sr1TranslationsByMessageId)
        try c.encode(pendingItemDeltas, forKey: .pendingItemDeltas)
        try c.encode(pendingItemDeltaOrder, forKey: .pendingItemDeltaOrder)
        try c.encodeIfPresent(lastMeasuredAggregateHotTextBytes, forKey: .lastMeasuredAggregateHotTextBytes)
        try c.encodeIfPresent(aggregateHotTextDirtyBytes, forKey: .aggregateHotTextDirtyBytes)
    }

    /// Derived location maps must not affect semantic equality: two timelines
    /// with the same persisted/public state compare equal even when one map was
    /// rebuilt and the other was populated incrementally (or left empty).
    public static func == (lhs: AssistantTimelineState, rhs: AssistantTimelineState) -> Bool {
        lhs.threadId == rhs.threadId
            && lhs.providerThreadId == rhs.providerThreadId
            && lhs.turns == rhs.turns
            && lhs.workActivities == rhs.workActivities
            && lhs.error == rhs.error
            && lhs.pendingRequests == rhs.pendingRequests
            && lhs.pendingUserInputs == rhs.pendingUserInputs
            && lhs.proposedPlans == rhs.proposedPlans
            && lhs.activePlan == rhs.activePlan
            && lhs.tokenUsage == rhs.tokenUsage
            && lhs.contextCompactionSummary == rhs.contextCompactionSummary
            && lhs.providerRuntimeEvents == rhs.providerRuntimeEvents
            && lhs.sr1TranslationsByItemId == rhs.sr1TranslationsByItemId
            && lhs.sr1TranslationsByMessageId == rhs.sr1TranslationsByMessageId
            && lhs.pendingItemDeltas == rhs.pendingItemDeltas
            && lhs.pendingItemDeltaOrder == rhs.pendingItemDeltaOrder
            && lhs.lastMeasuredAggregateHotTextBytes == rhs.lastMeasuredAggregateHotTextBytes
            && lhs.aggregateHotTextDirtyBytes == rhs.aggregateHotTextDirtyBytes
    }

    public var latestAssistantMessage: String? {
        for turn in turns.reversed() {
            if let final = turn.finalAssistantMessage, !final.isEmpty { return final }
            for item in turn.items.reversed()
            where item.type == .assistantMessage && !item.body.isEmpty {
                return item.body
            }
        }
        return nil
    }

    public var assistantTexts: [String] {
        turns.flatMap { turn in
            var texts = turn.items.compactMap { item -> String? in
                guard item.type == .assistantMessage, !item.body.isEmpty else { return nil }
                return item.body
            }
            if let final = turn.finalAssistantMessage, !final.isEmpty {
                texts.append(final)
            }
            return texts
        }
    }

    public mutating func clearActivePlan() {
        activePlan = nil
    }

    public mutating func clearError() {
        error = nil
    }

    public var aggregateHotTextByteCount: Int {
        func bytes(_ value: String?) -> Int { value?.utf8.count ?? 0 }
        var total = bytes(threadId) + bytes(providerThreadId) + bytes(error)
            + bytes(contextCompactionSummary)
        var elements = turns.count + workActivities.count + pendingRequests.count
            + pendingUserInputs.count + proposedPlans.count + providerRuntimeEvents.count
            + sr1TranslationsByItemId.count + sr1TranslationsByMessageId.count
            + pendingItemDeltas.count
        for turn in turns {
            total += turn.turnId.utf8.count + bytes(turn.finalAssistantMessage)
            elements += turn.items.count
            for item in turn.items {
                total += item.body.utf8.count
                total += item.id.utf8.count + item.turnId.utf8.count
                total += bytes(item.output) + bytes(item.summary) + bytes(item.resourcePath)
            }
        }
        for activity in workActivities {
            total += activity.id.utf8.count + activity.title.utf8.count
            total += bytes(activity.detail) + bytes(activity.state)
        }
        for request in pendingRequests {
            total += request.id.utf8.count + bytes(request.turnId)
            total += request.title.utf8.count + bytes(request.detail)
        }
        for request in pendingUserInputs {
            total += request.id.utf8.count + bytes(request.turnId)
            total += request.prompt.utf8.count + bytes(request.answer)
            for option in request.options { total += option.utf8.count }
            elements += request.options.count + request.questions.count
            for question in request.questions {
                total += question.id.utf8.count + question.prompt.utf8.count + bytes(question.header)
                elements += question.options.count
                for option in question.options {
                    total += option.label.utf8.count + bytes(option.detail)
                }
            }
        }
        for plan in proposedPlans {
            total += plan.id.utf8.count + bytes(plan.turnId) + plan.markdown.utf8.count
        }
        if let activePlan {
            elements += 1 + activePlan.steps.count
            total += bytes(activePlan.explanation)
            for step in activePlan.steps {
                total += step.id.utf8.count + step.title.utf8.count
            }
        }
        for event in providerRuntimeEvents {
            total += event.id.utf8.count + event.source.utf8.count + event.method.utf8.count
            total += bytes(event.providerTurnId) + bytes(event.providerItemId)
                + bytes(event.providerRequestId) + event.payloadJSON.utf8.count
        }
        for translation in sr1TranslationsByItemId.values {
            total += bytes(translation.itemId) + bytes(translation.messageId)
                + translation.originalText.utf8.count + translation.rewrittenText.utf8.count
                + bytes(translation.wireRequestText)
        }
        for translation in sr1TranslationsByMessageId.values {
            total += bytes(translation.itemId) + bytes(translation.messageId)
                + translation.originalText.utf8.count + translation.rewrittenText.utf8.count
                + bytes(translation.wireRequestText)
        }
        for (id, delta) in pendingItemDeltas {
            total += id.utf8.count + delta.body.utf8.count + delta.output.utf8.count
                + bytes(delta.summary)
        }
        return total + elements * Self.aggregateHotElementOverhead
    }

    /// Exact contribution of one element to `aggregateHotTextByteCount` (text + overhead).
    /// Used so budget eviction can debit without re-walking the whole timeline each step.
    private static func hotTextBytes(_ value: String?) -> Int { value?.utf8.count ?? 0 }

    private static func hotTextContribution(turn: AssistantTurnSnapshot) -> Int {
        var total = turn.turnId.utf8.count + hotTextBytes(turn.finalAssistantMessage)
        var elements = 1 + turn.items.count
        for item in turn.items {
            total += item.body.utf8.count
            total += item.id.utf8.count + item.turnId.utf8.count
            total += hotTextBytes(item.output) + hotTextBytes(item.summary) + hotTextBytes(item.resourcePath)
        }
        return total + elements * aggregateHotElementOverhead
    }

    private static func hotTextContribution(activity: AssistantWorkActivity) -> Int {
        let text = activity.id.utf8.count + activity.title.utf8.count
            + hotTextBytes(activity.detail) + hotTextBytes(activity.state)
        return text + aggregateHotElementOverhead
    }

    private static func hotTextContribution(request: AssistantPendingRequest) -> Int {
        let text = request.id.utf8.count + hotTextBytes(request.turnId)
            + request.title.utf8.count + hotTextBytes(request.detail)
        return text + aggregateHotElementOverhead
    }

    private static func hotTextContribution(userInput: AssistantUserInputRequest) -> Int {
        var total = userInput.id.utf8.count + hotTextBytes(userInput.turnId)
            + userInput.prompt.utf8.count + hotTextBytes(userInput.answer)
        var elements = 1 + userInput.options.count + userInput.questions.count
        for option in userInput.options { total += option.utf8.count }
        for question in userInput.questions {
            total += question.id.utf8.count + question.prompt.utf8.count + hotTextBytes(question.header)
            elements += question.options.count
            for option in question.options {
                total += option.label.utf8.count + hotTextBytes(option.detail)
            }
        }
        return total + elements * aggregateHotElementOverhead
    }

    private static func hotTextContribution(plan: AssistantProposedPlan) -> Int {
        let text = plan.id.utf8.count + hotTextBytes(plan.turnId) + plan.markdown.utf8.count
        return text + aggregateHotElementOverhead
    }

    private static func hotTextContribution(event: ProviderRuntimeEvent) -> Int {
        let text = event.id.utf8.count + event.source.utf8.count + event.method.utf8.count
            + hotTextBytes(event.providerTurnId) + hotTextBytes(event.providerItemId)
            + hotTextBytes(event.providerRequestId) + event.payloadJSON.utf8.count
        return text + aggregateHotElementOverhead
    }

    private static func hotTextContribution(translation: AssistantSR1Translation) -> Int {
        let text = hotTextBytes(translation.itemId) + hotTextBytes(translation.messageId)
            + translation.originalText.utf8.count + translation.rewrittenText.utf8.count
            + hotTextBytes(translation.wireRequestText)
        return text + aggregateHotElementOverhead
    }

    /// Keeps the newest live transcript content while evicting old rendered text.
    /// Compact active plan and pending interaction state are deliberately untouched.
    ///
    /// PERF: under pressure the previous implementation re-ran `aggregateHotTextByteCount`
    /// (full timeline walk) after every `removeFirst`. That is O(n²) on long streams.
    /// Eviction now debits the exact contribution of each removed element; bulk clears
    /// still re-sync once via a full recount.
    ///
    /// Under the limit, skip the exact walk when `lastMeasured + dirty <= limit`.
    /// Dirty is an event-estimate watermark updated on `apply`; over-limit still
    /// takes the exact eviction path.
    /// Bounded replay can omit older mounted rows. Keep those rows while newer
    /// replayed values remain authoritative, then rebuild the derived index.
    public mutating func retainMissingTurns(
        from previous: AssistantTimelineState,
        protectedTurnIDs: Set<String>
    ) {
        guard !protectedTurnIDs.isEmpty else { return }
        let previousTurns = Dictionary(uniqueKeysWithValues: previous.turns
            .filter { protectedTurnIDs.contains($0.turnId) }.map { ($0.turnId, $0) })
        let replayedIDs = Set(turns.map(\.turnId))
        let retained = previous.turns.filter {
            protectedTurnIDs.contains($0.turnId) && !replayedIDs.contains($0.turnId)
        }
        for index in turns.indices {
            guard let old = previousTurns[turns[index].turnId] else { continue }
            let replayedItems = Set(turns[index].items.map(\.id))
            turns[index].items.insert(contentsOf: old.items.filter { !replayedItems.contains($0.id) }, at: 0)
        }
        turns.insert(contentsOf: retained, at: 0)
        lastMeasuredAggregateHotTextBytes = nil
        rebuildLocationIndex()
    }

    public mutating func enforceAggregateHotTextBudget(
        byteLimit: Int = aggregateHotTextByteLimit,
        protectedTurnIDs: Set<String> = []
    ) {
        let limit = max(1, byteLimit)
        let dirty = aggregateHotTextDirtyBytes ?? 0
        if let lastMeasured = lastMeasuredAggregateHotTextBytes,
           lastMeasured + dirty <= limit {
            return
        }
        #if DEBUG
        Self.aggregateHotTextExactWalksForTesting &+= 1
        #endif
        var total = aggregateHotTextByteCount
        defer {
            lastMeasuredAggregateHotTextBytes = total
            aggregateHotTextDirtyBytes = 0
        }
        guard total > limit else { return }
        func debit(_ amount: Int) {
            total -= amount
            if total < 0 { total = 0 }
        }
        func remove(_ value: inout String?) {
            guard total > limit, let text = value else { return }
            debit(text.utf8.count)
            value = nil
        }
        for turnIndex in turns.indices {
            guard !protectedTurnIDs.contains(turns[turnIndex].turnId) else { continue }
            for itemIndex in turns[turnIndex].items.indices {
                if total <= limit { return }
                debit(turns[turnIndex].items[itemIndex].body.utf8.count)
                turns[turnIndex].items[itemIndex].body = ""
                remove(&turns[turnIndex].items[itemIndex].output)
                remove(&turns[turnIndex].items[itemIndex].summary)
            }
            remove(&turns[turnIndex].finalAssistantMessage)
        }
        // Visible transcript and decision chrome take priority over the soft
        // memory target. Only offscreen turn payloads may be evicted here.
        guard protectedTurnIDs.isEmpty else { return }
        if total > limit, !providerRuntimeEvents.isEmpty {
            var drop = 0
            var debitSum = 0
            for ev in providerRuntimeEvents {
                if total - debitSum <= limit { break }
                debitSum += Self.hotTextContribution(event: ev)
                drop += 1
            }
            if drop > 0 {
                providerRuntimeEvents.removeFirst(drop)
                debit(debitSum)
            }
        }
        while total > limit, let key = sr1TranslationsByItemId.keys.first,
              let translation = sr1TranslationsByItemId.removeValue(forKey: key) {
            debit(Self.hotTextContribution(translation: translation))
        }
        while total > limit, let key = sr1TranslationsByMessageId.keys.first,
              let translation = sr1TranslationsByMessageId.removeValue(forKey: key) {
            debit(Self.hotTextContribution(translation: translation))
        }
        if total > limit {
            pendingItemDeltas.removeAll(keepingCapacity: true)
            pendingItemDeltaOrder.removeAll(keepingCapacity: true)
            total = aggregateHotTextByteCount
        }
        if total > limit {
            contextCompactionSummary = nil
            for index in workActivities.indices {
                workActivities[index].title = ""
                workActivities[index].detail = nil
                workActivities[index].state = nil
            }
            for index in proposedPlans.indices { proposedPlans[index].markdown = "" }
            for index in pendingRequests.indices {
                pendingRequests[index].title = ""
                pendingRequests[index].detail = nil
            }
            for index in pendingUserInputs.indices {
                pendingUserInputs[index].prompt = ""
                pendingUserInputs[index].options.removeAll(keepingCapacity: false)
                pendingUserInputs[index].answer = nil
                for questionIndex in pendingUserInputs[index].questions.indices {
                    pendingUserInputs[index].questions[questionIndex].prompt = ""
                    pendingUserInputs[index].questions[questionIndex].header = nil
                    pendingUserInputs[index].questions[questionIndex].options.removeAll(keepingCapacity: false)
                }
            }
            total = aggregateHotTextByteCount
        }
        if total > limit, workActivities.count > 1 {
            var drop = 0
            var debitSum = 0
            let keepOne = max(0, workActivities.count - 1)
            for ev in workActivities {
                if drop >= keepOne || total - debitSum <= limit { break }
                debitSum += Self.hotTextContribution(activity: ev)
                drop += 1
            }
            if drop > 0 {
                workActivities.removeFirst(drop)
                debit(debitSum)
            }
        }
        if total > limit, proposedPlans.count > 1 {
            var drop = 0
            var debitSum = 0
            let keepOne = max(0, proposedPlans.count - 1)
            for ev in proposedPlans {
                if drop >= keepOne || total - debitSum <= limit { break }
                debitSum += Self.hotTextContribution(plan: ev)
                drop += 1
            }
            if drop > 0 {
                proposedPlans.removeFirst(drop)
                debit(debitSum)
            }
        }
        if total > limit, pendingRequests.count > 1 {
            var drop = 0
            var debitSum = 0
            let keepOne = max(0, pendingRequests.count - 1)
            for ev in pendingRequests {
                if drop >= keepOne || total - debitSum <= limit { break }
                debitSum += Self.hotTextContribution(request: ev)
                drop += 1
            }
            if drop > 0 {
                pendingRequests.removeFirst(drop)
                debit(debitSum)
            }
        }
        if total > limit, pendingUserInputs.count > 1 {
            var drop = 0
            var debitSum = 0
            let keepOne = max(0, pendingUserInputs.count - 1)
            for ev in pendingUserInputs {
                if drop >= keepOne || total - debitSum <= limit { break }
                debitSum += Self.hotTextContribution(userInput: ev)
                drop += 1
            }
            if drop > 0 {
                pendingUserInputs.removeFirst(drop)
                debit(debitSum)
            }
        }
        if total > limit, turns.count > 1 {
            var drop = 0
            var debitSum = 0
            let keepOne = max(0, turns.count - 1)
            for ev in turns {
                if drop >= keepOne || total - debitSum <= limit { break }
                debitSum += Self.hotTextContribution(turn: ev)
                drop += 1
            }
            if drop > 0 {
                turns.removeFirst(drop)
                rebuildLocationIndex()
                debit(debitSum)
            }
        }
        if total > limit { remove(&error) }
        if total > limit, var plan = activePlan {
            plan.explanation = nil
            for index in plan.steps.indices { plan.steps[index].title = "" }
            activePlan = plan
            total = aggregateHotTextByteCount
        }
        if total > limit {
            workActivities.removeAll()
            proposedPlans.removeAll()
            total = aggregateHotTextByteCount
        }
        if total > limit {
            pendingRequests.removeAll()
            pendingUserInputs.removeAll()
            total = aggregateHotTextByteCount
        }
        if total > limit {
            turns.removeAll()
            rebuildLocationIndex()
            total = aggregateHotTextByteCount
        }
        if total > limit {
            activePlan = nil
            total = aggregateHotTextByteCount
        }
        if total > limit {
            threadId = nil
            providerThreadId = nil
        }
    }

    public mutating func apply(
        _ ev: AssistantEvent,
        nowMs: Int64? = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        aggregateHotTextDirtyBytes =
            (aggregateHotTextDirtyBytes ?? 0) + max(1, ev.estimatedHotQueueBytes)
        switch ev {
        case .threadStarted(let tid, let ptid):
            self.threadId = tid; self.providerThreadId = ptid
        case .turnStarted(let tid):
            ensureTurn(tid, startedAtMs: nowMs)
        case .itemStarted(let item):
            ensureTurn(item.turnId)
            if let idx = turnIndex(item.turnId) {
                let deltaKey = Self.pendingItemDeltaKey(itemId: item.id)
                let pending = pendingItemDeltas.removeValue(forKey: deltaKey)
                if pending != nil { pendingItemDeltaOrder.removeAll { $0 == deltaKey } }
                let metadataKey = Self.pendingHostMetadataKey(turnId: item.turnId, itemId: item.id)
                let pendingMetadata = pendingItemDeltas.removeValue(forKey: metadataKey)
                if pendingMetadata != nil { pendingItemDeltaOrder.removeAll { $0 == metadataKey } }
                if let itemIndex = itemIndex(item.id, inTurn: idx) {
                    let existing = turns[idx].items[itemIndex]
                    if existing.distillApplied == true {
                        // Host attestation binds to the exact terminal bytes. A
                        // duplicate provider snapshot must not replace them.
                        turns[idx].items[itemIndex] = existing
                    } else {
                        var merged = item
                        // Provider/parser item payloads never mint trust. Preserve only
                        // an already host-attested value from the local timeline.
                        merged.distillApplied = nil
                        if merged.body.isEmpty { merged.body = existing.body }
                        if merged.output == nil { merged.output = existing.output }
                        if merged.progress == nil { merged.progress = existing.progress }
                        if merged.summary == nil { merged.summary = existing.summary }
                        if merged.finishedAtMs == nil { merged.finishedAtMs = existing.finishedAtMs }
                        if merged.state == .streaming, existing.state != .streaming { merged.state = existing.state }
                        applyPendingDelta(pending, to: &merged)
                        applyPendingDelta(pendingMetadata, to: &merged)
                        turns[idx].items[itemIndex] = merged
                    }
                } else {
                    var started = item
                    started.distillApplied = nil
                    applyPendingDelta(pending, to: &started)
                    applyPendingDelta(pendingMetadata, to: &started)
                    turns[idx].items.append(started)
                    recordItemLocation(started.id, turnIndex: idx, itemIndex: turns[idx].items.count - 1)
                    trimTurnItems(at: idx)
                }
            }
            if let recorded = self.item(withId: item.id) {
                recordActivity(for: recorded, state: recorded.state)
            }
        case .itemDelta(let iid, let bodyAppend, let outputAppend, let summary):
            let applied = mutateItem(iid) { item in
                guard item.distillApplied != true else { return }
                if let b = bodyAppend {
                    Self.appendCapped(&item.body, append: b, limit: Self.liveTextLimit)
                }
                if let o = outputAppend {
                    var output = item.output ?? ""
                    Self.appendCapped(&output, append: o, limit: Self.liveOutputLimit)
                    item.output = output
                }
                if let s = summary { item.summary = s }
            }
            if !applied {
                let key = Self.pendingItemDeltaKey(itemId: iid)
                var pending = pendingItemDeltas[key] ?? PendingItemDelta()
                if pendingItemDeltas[key] == nil { pendingItemDeltaOrder.append(key) }
                if let b = bodyAppend {
                    Self.appendCapped(&pending.body, append: b, limit: Self.liveTextLimit)
                }
                if let o = outputAppend {
                    Self.appendCapped(&pending.output, append: o, limit: Self.liveOutputLimit)
                }
                if let s = summary { pending.summary = s }
                pendingItemDeltas[key] = pending
                trimPendingItemDeltas()
            }
        case .itemState(let iid, let state):
            guard item(withId: iid)?.distillApplied != true else { break }
            mutateItem(iid) { $0.state = state }
        case .itemProgress(let iid, let progress):
            guard item(withId: iid)?.distillApplied != true else { break }
            mutateItem(iid) { $0.progress = progress.map(Self.normalizedProgress) }
            if let item = item(withId: iid) {
                recordActivity(for: item, state: item.state)
            }
        case .itemCompleted(let iid, let state):
            if let item = item(withId: iid),
               item.distillApplied == true,
               item.state != .streaming {
                break
            }
            mutateItem(iid) { item in
                item.state = state
                // Replay must not invent wall-clock now. Desk/Agent App
                // rebuild timelines from persisted events; Date() here made
                // "Worked for 12s" grow into hundreds of minutes.
                if item.finishedAtMs == nil, let nowMs {
                    item.finishedAtMs = nowMs
                }
            }
            if let item = item(withId: iid) {
                recordActivity(for: item, state: state)
            }
        case .itemHostMetadata(let turnId, let itemId, let distillApplied, _):
            // OR semantics are deliberate: absent/false metadata is never an
            // instruction to erase a durable host attestation.
            guard distillApplied == true else { break }
            let applied = mutateItem(turnId: turnId, itemId: itemId) {
                $0.distillApplied = true
            }
            if !applied {
                let key = Self.pendingHostMetadataKey(turnId: turnId, itemId: itemId)
                var pending = pendingItemDeltas[key] ?? PendingItemDelta()
                if pendingItemDeltas[key] == nil { pendingItemDeltaOrder.append(key) }
                pending.distillApplied = true
                pendingItemDeltas[key] = pending
                trimPendingItemDeltas()
            } else if let item = item(turnId: turnId, itemId: itemId) {
                // A terminal itemStarted may have already populated Work log
                // before its receipt authenticated. Refresh the same activity
                // so protocol metadata disappears only after host truth lands.
                recordActivity(for: item, state: item.state)
            }
        case .turnCompleted(let tid, let final):
            if let idx = turnIndex(tid) {
                turns[idx].finalAssistantMessage = final.map { Self.cappedText($0, limit: Self.liveTextLimit) }
                turns[idx].finished = true
            }
            if let final, !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearActivePlan()
            }
            // F39: any delta still unmatched at turn end can no longer pair with a
            // live item (items open with the turn), so drop the buffer instead of
            // retaining orphan text for the life of the timeline.
            pendingItemDeltas.removeAll()
            pendingItemDeltaOrder.removeAll()
        case .proposedPlan(let plan):
            proposedPlans.removeAll { $0.id == plan.id }
            proposedPlans.append(plan)
            if proposedPlans.count > Self.proposedPlanLimit {
                proposedPlans.removeFirst(proposedPlans.count - Self.proposedPlanLimit)
            }
        case .activePlanUpdated(let plan):
            activePlan = plan
        case .requestOpened(let request):
            pendingRequests.removeAll { $0.id == request.id }
            pendingRequests.append(request)
            trimPendingRequests()
            recordActivity(AssistantWorkActivity(
                id: "request:\(request.id)",
                kind: .request,
                title: "Approval requested: \(request.title)",
                detail: request.detail,
                state: request.state.rawValue,
                createdAtMs: request.createdAtMs
            ))
        case .requestResolved(let requestId, let state):
            if let idx = pendingRequests.firstIndex(where: { $0.id == requestId }) {
                pendingRequests[idx].state = state
                pendingRequests[idx].resolvedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                let request = pendingRequests[idx]
                recordActivity(AssistantWorkActivity(
                    id: "request:\(request.id)",
                    kind: .request,
                    title: "Approval \(state.rawValue): \(request.title)",
                    detail: request.detail,
                    state: state.rawValue,
                    createdAtMs: request.resolvedAtMs ?? request.createdAtMs
                ))
            }
            trimPendingRequests()
        case .userInputRequested(let request):
            pendingUserInputs.removeAll { $0.id == request.id }
            pendingUserInputs.append(request)
            trimPendingUserInputs()
            recordActivity(AssistantWorkActivity(
                id: "user_input:\(request.id)",
                kind: .userInput,
                title: "Question requested",
                detail: request.prompt,
                state: request.state.rawValue,
                createdAtMs: request.createdAtMs
            ))
        case .userInputResolved(let requestId, let answer):
            if let idx = pendingUserInputs.firstIndex(where: { $0.id == requestId }) {
                pendingUserInputs[idx].answer = answer
                pendingUserInputs[idx].state = .resolved
                pendingUserInputs[idx].resolvedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                let request = pendingUserInputs[idx]
                recordActivity(AssistantWorkActivity(
                    id: "user_input:\(request.id)",
                    kind: .userInput,
                    title: "Question resolved",
                    detail: answer ?? request.prompt,
                    state: AssistantRequestState.resolved.rawValue,
                    createdAtMs: request.resolvedAtMs ?? request.createdAtMs
                ))
            }
            trimPendingUserInputs()
        case .tokenUsage(let usage):
            if let existing = tokenUsage {
                tokenUsage = AssistantTokenUsage.merging(existing, with: usage)
            } else {
                tokenUsage = usage
            }
        case .accountUsage:
            break
        case .contextCompaction(let summary):
            contextCompactionSummary = summary
        case .providerRuntime(let event):
            providerRuntimeEvents.append(event)
            if providerRuntimeEvents.count > Self.providerRuntimeEventLimit {
                providerRuntimeEvents.removeFirst(providerRuntimeEvents.count - Self.providerRuntimeEventLimit)
            }
            if event.surfacesInWorkLog {
                recordActivity(AssistantWorkActivity(
                    id: "runtime:\(event.id)",
                    kind: .runtime,
                    title: "\(event.provider.rawValue) runtime: \(event.method)",
                    detail: event.source,
                    state: nil,
                    createdAtMs: event.receivedAtMs
                ))
            }
        case .wireTranslation(let translation):
            let compatibility = AssistantSR1Translation(
                itemId: translation.itemId,
                messageId: translation.messageId,
                originalText: translation.originalText,
                rewrittenText: translation.rewrittenText,
                wireRequestText: translation.wireRequestText
            )
            if let itemId = translation.itemId, !itemId.isEmpty {
                indexSR1Translation(compatibility, itemId: itemId)
            }
            if let messageId = translation.messageId, !messageId.isEmpty {
                sr1TranslationsByMessageId[messageId] = compatibility
            }
        case .sr1Translation(let translation):
            if let itemId = translation.itemId, !itemId.isEmpty {
                indexSR1Translation(translation, itemId: itemId)
            }
            if let messageId = translation.messageId, !messageId.isEmpty {
                sr1TranslationsByMessageId[messageId] = translation
            }
        case .error(let m, _):
            self.error = m
            recordActivity(AssistantWorkActivity(
                id: "error:\(UUID().uuidString)",
                kind: .error,
                title: "Agent error",
                detail: m,
                state: "failed",
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))
        }
    }

    /// AA-27: turn/item lookups on the append path used oldest-first
    /// `firstIndex`, i.e. O(turns) per turnStarted/itemStarted/turnCompleted and
    /// O(items) per itemStarted (O(items²) per turn, paid again on every thread
    /// open replay). The incremental maps make known ids O(1); newest-first
    /// remains the fallback so a stale map cannot mis-route an event.
    private func turnIndex(_ tid: String) -> Int? {
        if let idx = resolvedTurnIndex(tid) { return idx }
        for index in turns.indices.reversed() {
            #if DEBUG
            Self.turnLookupComparisonsForTesting &+= 1
            #endif
            if turns[index].turnId == tid { return index }
        }
        return nil
    }

    private func itemIndex(_ iid: String, inTurn turnIndex: Int) -> Int? {
        if let loc = resolvedItemLocation(of: iid), loc.turnIndex == turnIndex {
            return loc.itemIndex
        }
        for index in turns[turnIndex].items.indices.reversed() {
            #if DEBUG
            Self.itemLookupComparisonsForTesting &+= 1
            #endif
            if turns[turnIndex].items[index].id == iid { return index }
        }
        return nil
    }

    private mutating func ensureTurn(_ tid: String, startedAtMs: Int64? = nil) {
        if let idx = turnIndex(tid) {
            // Keep the earliest start time if turnStarted arrives after itemStarted.
            if turns[idx].startedAtMs == nil, let startedAtMs {
                turns[idx].startedAtMs = startedAtMs
            }
            return
        }
        turns.append(AssistantTurnSnapshot(
            turnId: tid,
            startedAtMs: startedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        ))
        turnLocations[tid] = turns.count - 1
        trimTurns()
    }

    /// Translation events follow their item event in provider streams. Resolve
    /// newest-first so a reused provider item ID is attached to the current turn,
    /// while retaining the legacy item-only entry for old snapshots/readers.
    private mutating func indexSR1Translation(
        _ translation: AssistantSR1Translation,
        itemId: String
    ) {
        sr1TranslationsByItemId[itemId] = translation
        guard let turnId = turns.reversed().first(where: { turn in
            turn.items.contains(where: { $0.id == itemId })
        })?.turnId else { return }
        sr1TranslationsByItemId[Self.sr1TimelineItemTranslationKey(
            turnId: turnId,
            itemId: itemId
        )] = translation
    }

    private mutating func trimTurns() {
        guard turns.count > Self.liveTurnLimit else { return }
        let dropCount = turns.count - Self.liveTurnLimit
        // F10: evicted turns' items are gone, so drop any legacy SR1 translations keyed on
        // those item ids — otherwise the maps retain pre-translation text for turns
        // that no longer exist. Item ids are unique per turn, so retained turns keep
        // their translations. (messageId translations map to persisted messages
        // outside the timeline and are reset on thread switch, so they stay here.)
        if !sr1TranslationsByItemId.isEmpty {
            for turn in turns.prefix(dropCount) {
                for item in turn.items {
                    sr1TranslationsByItemId.removeValue(forKey: item.id)
                    sr1TranslationsByItemId.removeValue(forKey: Self.sr1TimelineItemTranslationKey(
                        turnId: turn.turnId,
                        itemId: item.id
                    ))
                }
            }
        }
        turns.removeFirst(dropCount)
        rebuildLocationIndex()
    }

    // F10: keep one turn's `items` array bounded (see `liveTurnItemLimit`). Trims
    // oldest items **after** index 0 — items[0].startedAtMs is the transcript sort
    // anchor; dropping it reorders Lazy rows mid-stream. Also drops orphaned translations.
    private mutating func trimTurnItems(at idx: Int) {
        guard turns[idx].items.count > Self.liveTurnItemLimit else { return }
        // PERF: single pass over the live array — drop the oldest non-anchor
        // items in place instead of copying the tail twice (dropFirst + suffix).
        let keepRest = Self.liveTurnItemLimit - 1
        let dropFromRest = turns[idx].items.count - 1 - keepRest
        if dropFromRest > 0 {
            if !sr1TranslationsByItemId.isEmpty {
                for item in turns[idx].items[1..<(1 + dropFromRest)] {
                    sr1TranslationsByItemId.removeValue(forKey: item.id)
                    sr1TranslationsByItemId.removeValue(forKey: Self.sr1TimelineItemTranslationKey(
                        turnId: turns[idx].turnId,
                        itemId: item.id
                    ))
                }
            }
            turns[idx].items.removeSubrange(1..<(1 + dropFromRest))
            rebuildLocationIndex()
        }
    }

    private mutating func trimPendingRequests() {
        guard pendingRequests.count > Self.pendingRequestLimit else { return }
        pendingRequests = Array(pendingRequests.suffix(Self.pendingRequestLimit))
    }

    // F39: keep the delta-before-itemStarted buffer bounded (see
    // `pendingItemDeltaLimit`). Evicts oldest-first so a delta that legitimately
    // raced ahead of its itemStarted (always the newest entry) survives.
    private mutating func trimPendingItemDeltas() {
        guard pendingItemDeltas.count > Self.pendingItemDeltaLimit else { return }
        let dropCount = pendingItemDeltas.count - Self.pendingItemDeltaLimit
        for key in pendingItemDeltaOrder.prefix(dropCount) {
            pendingItemDeltas.removeValue(forKey: key)
        }
        pendingItemDeltaOrder.removeFirst(dropCount)
    }

    private mutating func trimPendingUserInputs() {
        guard pendingUserInputs.count > Self.pendingRequestLimit else { return }
        pendingUserInputs = Array(pendingUserInputs.suffix(Self.pendingRequestLimit))
    }

    private static func pendingHostMetadataKey(turnId: String, itemId: String) -> String {
        "host|\(turnId.utf8.count)|\(turnId)|\(itemId.utf8.count)|\(itemId)"
    }

    private static func pendingItemDeltaKey(itemId: String) -> String {
        "provider|\(itemId.utf8.count)|\(itemId)"
    }

    @discardableResult
    private mutating func mutateItem(
        turnId: String,
        itemId: String,
        _ mut: (inout AssistantItem) -> Void
    ) -> Bool {
        if let loc = resolvedItemLocation(of: itemId),
           turns[loc.turnIndex].turnId == turnId {
            mut(&turns[loc.turnIndex].items[loc.itemIndex])
            return true
        }
        guard let turnIndex = turns.lastIndex(where: { $0.turnId == turnId }) else { return false }
        for itemIndex in turns[turnIndex].items.indices.reversed()
        where turns[turnIndex].items[itemIndex].id == itemId {
            // Do not overwrite the global newest-occurrence map from a
            // turn-scoped hit: a reused item id's late host-metadata on an
            // older turn must not poison subsequent unscoped lookups.
            mut(&turns[turnIndex].items[itemIndex])
            return true
        }
        return false
    }

    @discardableResult
    private mutating func mutateItem(_ iid: String, _ mut: (inout AssistantItem) -> Void) -> Bool {
        // Map-first: history replay and deltas to older items used to walk from
        // the newest end (~N comparisons for an item near the start of a turn).
        // The incremental location map is O(1) for any known id. Newest-first
        // remains the fallback so a stale map cannot mutate the wrong item.
        // Last recorded occurrence wins, matching previous newest-first search
        // when a provider item id is reused after a turn boundary.
        if let loc = resolvedItemLocation(of: iid) {
            mut(&turns[loc.turnIndex].items[loc.itemIndex])
            return true
        }
        for ti in turns.indices.reversed() {
            for ii in turns[ti].items.indices.reversed() {
                #if DEBUG
                Self.itemLookupComparisonsForTesting &+= 1
                #endif
                if turns[ti].items[ii].id == iid {
                    recordItemLocation(iid, turnIndex: ti, itemIndex: ii)
                    mut(&turns[ti].items[ii])
                    return true
                }
            }
        }
        return false
    }

    private func applyPendingDelta(_ pending: PendingItemDelta?, to item: inout AssistantItem) {
        guard let pending else { return }
        if !pending.body.isEmpty {
            Self.appendCapped(&item.body, append: pending.body, limit: Self.liveTextLimit)
        }
        if !pending.output.isEmpty {
            var output = item.output ?? ""
            Self.appendCapped(&output, append: pending.output, limit: Self.liveOutputLimit)
            item.output = output
        }
        if let summary = pending.summary {
            item.summary = summary
        }
        if pending.distillApplied == true {
            item.distillApplied = true
        }
    }

    private func item(withId iid: String) -> AssistantItem? {
        if let loc = resolvedItemLocation(of: iid) {
            return turns[loc.turnIndex].items[loc.itemIndex]
        }
        for ti in turns.indices.reversed() {
            for ii in turns[ti].items.indices.reversed() {
                #if DEBUG
                Self.itemLookupComparisonsForTesting &+= 1
                #endif
                if turns[ti].items[ii].id == iid {
                    return turns[ti].items[ii]
                }
            }
        }
        return nil
    }

    private func item(turnId: String, itemId: String) -> AssistantItem? {
        if let loc = resolvedItemLocation(of: itemId),
           turns[loc.turnIndex].turnId == turnId {
            return turns[loc.turnIndex].items[loc.itemIndex]
        }
        guard let turn = turns.last(where: { $0.turnId == turnId }) else { return nil }
        return turn.items.last(where: { $0.id == itemId })
    }

    /// Last occurrence wins so a reused provider item id resolves to the current
    /// turn, matching the previous newest-first scan.
    private mutating func recordItemLocation(_ iid: String, turnIndex: Int, itemIndex: Int) {
        itemLocations[iid] = ItemLocation(turnIndex: turnIndex, itemIndex: itemIndex)
    }

    private mutating func rebuildLocationIndex() {
        itemLocations.removeAll(keepingCapacity: true)
        turnLocations.removeAll(keepingCapacity: true)
        itemLocations.reserveCapacity(turns.reduce(0) { $0 + $1.items.count })
        turnLocations.reserveCapacity(turns.count)
        for ti in turns.indices {
            turnLocations[turns[ti].turnId] = ti
            for ii in turns[ti].items.indices {
                itemLocations[turns[ti].items[ii].id] = ItemLocation(turnIndex: ti, itemIndex: ii)
            }
        }
    }

    private func resolvedTurnIndex(_ tid: String) -> Int? {
        guard let idx = turnLocations[tid], turns.indices.contains(idx) else { return nil }
        #if DEBUG
        Self.turnLookupComparisonsForTesting &+= 1
        #endif
        guard turns[idx].turnId == tid else { return nil }
        return idx
    }

    private func resolvedItemLocation(of iid: String) -> ItemLocation? {
        guard let loc = itemLocations[iid],
              turns.indices.contains(loc.turnIndex),
              turns[loc.turnIndex].items.indices.contains(loc.itemIndex)
        else { return nil }
        #if DEBUG
        Self.itemLookupComparisonsForTesting &+= 1
        #endif
        guard turns[loc.turnIndex].items[loc.itemIndex].id == iid else { return nil }
        return loc
    }

    private mutating func recordActivity(for item: AssistantItem, state: AssistantItemState) {
        guard item.type != .assistantMessage, item.type != .reasoning, item.type != .plan else { return }
        let rawDetail = item.output ?? item.body
        recordActivity(AssistantWorkActivity(
            id: "item:\(item.id)",
            kind: .tool,
            title: "\(state == .streaming ? "Running" : state.rawValue.capitalized): \(Self.activityLabel(for: item))",
            detail: item.distillApplied == true
                ? DistillAppliedReceipt.strip(rawDetail)
                : rawDetail,
            state: state.rawValue,
            createdAtMs: item.finishedAtMs ?? item.startedAtMs
        ))
    }

    private mutating func recordActivity(_ activity: AssistantWorkActivity) {
        var next = activity
        next.title = Self.cappedText(next.title, limit: 240)
        next.detail = next.detail.map { Self.cappedText($0, limit: 1_000) }
        workActivities.removeAll { $0.id == activity.id }
        workActivities.append(next)
        if workActivities.count > Self.workActivityLimit {
            workActivities.removeFirst(workActivities.count - Self.workActivityLimit)
        }
    }

    private static func activityLabel(for item: AssistantItem) -> String {
        if let progress = item.progress {
            let percent = Int((normalizedProgress(progress) * 100).rounded())
            return "\(percent)% \(baseActivityLabel(for: item))"
        }
        return baseActivityLabel(for: item)
    }

    private static func baseActivityLabel(for item: AssistantItem) -> String {
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary.replacingOccurrences(of: "\n", with: " ")
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body.replacingOccurrences(of: "\n", with: " ") }
        return item.type.rawValue
    }

    public static func normalizedProgress(_ value: Double) -> Double {
        if value > 1 { return min(1, max(0, value / 100)) }
        return min(1, max(0, value))
    }

    /// Append `append` into `target`, preserving grapheme caps when over limit.
    ///
    /// WHY: `target = cappedText(target + append)` rebuilt the full growing body
    /// on every token (`O(n)` copy per delta → `O(n²)` for a long stream).
    /// Under the UTF-8 budget, `String.append` is amortized and CoW-friendly.
    public static func appendCapped(_ target: inout String, append: String, limit: Int) {
        guard !append.isEmpty else { return }
        let nextUTF8 = target.utf8.count + append.utf8.count
        if nextUTF8 <= limit {
            target.append(append)
            return
        }
        // Multi-byte graphemes can still be within the grapheme limit when UTF-8
        // exceeds it — append then apply the existing grapheme-aware cap.
        target.append(append)
        target = cappedText(target, limit: limit)
    }

    public static func cappedText(_ value: String, limit: Int = liveTextLimit) -> String {
        // PERF-MAC_AGENT (F11): `value.count` is an O(n) grapheme-cluster walk, paid on
        // every message at thread load and on every streaming delta (`item.body + b`).
        // For native Swift strings `value.utf8.count` is an O(1) stored byte length, and
        // every grapheme is >= 1 UTF-8 byte, so `utf8.count <= limit` guarantees
        // `count <= limit`. The byte fast path therefore skips the walk for the
        // overwhelmingly common under-limit case while leaving the exact grapheme-based
        // cap (and thus the output for every input) unchanged.
        guard value.utf8.count > limit else { return value }
        #if DEBUG
        cappedTextGraphemeWalksForTesting &+= 1
        #endif
        guard value.count > limit else { return value }
        return String(value.suffix(limit))
    }

    #if DEBUG
    /// Test-only observability for the id->item lookup scan length used by
    /// `mutateItem`/`item(withId:)`. A perf unit test resets this and asserts that
    /// streaming deltas to the active (most-recently-started) item do NOT re-scan
    /// the whole accumulated timeline — the O(items^2)-per-session regression that
    /// froze long Agent App runs and was relieved instantly by Stop. DEBUG-only so
    /// release builds carry no shared-mutable write on the streaming path (apply()
    /// runs on both the UI main actor and the runner's background thread).
    nonisolated(unsafe) static var itemLookupComparisonsForTesting = 0
    /// AA-27 seam: comparisons spent locating a turn by id on the append path.
    nonisolated(unsafe) static var turnLookupComparisonsForTesting = 0

    /// Test-only observability for the `cappedText` grapheme walk (F11). A perf unit
    /// test resets this and asserts that under-limit text takes the O(1) byte fast
    /// path and never the O(n) `String.count` grapheme walk. `nonisolated(unsafe)`
    /// for the same reason as above: `cappedText` runs on both the UI main actor and
    /// the runner's background thread.
    nonisolated(unsafe) static var cappedTextGraphemeWalksForTesting = 0

    /// Test-only observability for `enforceAggregateHotTextBudget`'s exact
    /// `aggregateHotTextByteCount` walk. Under-limit repeats with a dirty
    /// watermark still below the ceiling must not increment this.
    nonisolated(unsafe) static var aggregateHotTextExactWalksForTesting = 0

    /// Test-only observability for the F39 pendingItemDeltas bound: the buffer is
    /// private (pairing internals), so the memory-cap test reads its size here
    /// instead of poking at eviction side effects only.
    public var pendingItemDeltaCountForTesting: Int { pendingItemDeltas.count }
    #endif
}
