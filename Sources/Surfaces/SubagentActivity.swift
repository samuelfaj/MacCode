import Foundation
import SwiftUI
import CoreModel
import AgentRuntime
import DesignSystemKit

// MARK: - Provider-neutral activity model
//
// Source of truth: `AgentOrchestrationAdmissionReceipt` lifecycle fields only.
// Missing values stay nil / `.unknown` — never invented zeros or success.

/// Lifecycle phase shown in the Subagents surface. Distinct from provider identity.
public enum SubagentActivityPhase: String, Sendable, Equatable, CaseIterable {
    case working
    case completed
    case failed
    case cancelled
    case unknown
}

/// Normalized provider identity for glyph/color. Unknown stays explicit.
public enum SubagentProviderKind: String, Sendable, Equatable, CaseIterable {
    case codex
    case claude
    case grok
    case distill
    case unknown
}

/// One row in the Subagents Active / Done lists.
public struct SubagentActivityItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let runId: AgentRunID?
    public let threadId: AgentThreadID
    public let nodeId: String
    public let displayName: String
    public let provider: SubagentProviderKind
    public let model: String?
    public let reasoningEffort: AgentReasoningEffort?
    public let phase: SubagentActivityPhase
    public let lifecycleStatus: AgentOrchestrationReceiptLifecycleStatus
    public let finalRunStatus: AgentRunStatus?
    public let admittedAt: Date
    public let finalizedAt: Date?
    public let lifecycleUpdatedAt: Date
    /// True when this row belongs in the Active section (not yet terminal).
    public let isActive: Bool

    public init(
        id: UUID,
        runId: AgentRunID?,
        threadId: AgentThreadID,
        nodeId: String,
        displayName: String,
        provider: SubagentProviderKind,
        model: String?,
        reasoningEffort: AgentReasoningEffort? = nil,
        phase: SubagentActivityPhase,
        lifecycleStatus: AgentOrchestrationReceiptLifecycleStatus,
        finalRunStatus: AgentRunStatus?,
        admittedAt: Date,
        finalizedAt: Date?,
        lifecycleUpdatedAt: Date,
        isActive: Bool
    ) {
        self.id = id
        self.runId = runId
        self.threadId = threadId
        self.nodeId = nodeId
        self.displayName = displayName
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.phase = phase
        self.lifecycleStatus = lifecycleStatus
        self.finalRunStatus = finalRunStatus
        self.admittedAt = admittedAt
        self.finalizedAt = finalizedAt
        self.lifecycleUpdatedAt = lifecycleUpdatedAt
        self.isActive = isActive
    }

    /// Secondary line: phase label; model is available for expanded detail.
    public var statusLabel: String {
        switch phase {
        case .working: return "Working"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown"
        }
    }

    /// Compact meta: `Provider · model · effort` (omits missing segments).
    public var providerModelLabel: String? {
        let providerName: String
        switch provider {
        case .codex: providerName = "Codex"
        case .claude: providerName = "Claude"
        case .grok: providerName = "Grok"
        case .distill: providerName = "Distill"
        case .unknown: providerName = "Unknown"
        }
        var parts = [providerName]
        if let model, !model.isEmpty {
            parts.append(model)
        }
        if let reasoningEffort {
            parts.append(reasoningEffort.displayName)
        }
        if provider == .unknown && model == nil && reasoningEffort == nil {
            return nil
        }
        return parts.joined(separator: " · ")
    }
}

/// Projected snapshot ready for the compact badge and expanded popover.
public struct SubagentActivitySnapshot: Sendable, Equatable {
    public let active: [SubagentActivityItem]
    public let done: [SubagentActivityItem]
    public let unknown: [SubagentActivityItem]
    public let activeVisibleLimit: Int
    public let doneVisibleLimit: Int
    public let unknownVisibleLimit: Int
    public let completedBound: Int

    public static let empty = SubagentActivitySnapshot(
        active: [],
        done: [],
        unknown: [],
        activeVisibleLimit: SubagentActivityProjection.defaultActiveVisibleLimit,
        doneVisibleLimit: SubagentActivityProjection.defaultDoneVisibleLimit,
        unknownVisibleLimit: SubagentActivityProjection.defaultDoneVisibleLimit,
        completedBound: SubagentActivityProjection.defaultCompletedBound
    )

    public init(
        active: [SubagentActivityItem],
        done: [SubagentActivityItem],
        unknown: [SubagentActivityItem] = [],
        activeVisibleLimit: Int = SubagentActivityProjection.defaultActiveVisibleLimit,
        doneVisibleLimit: Int = SubagentActivityProjection.defaultDoneVisibleLimit,
        unknownVisibleLimit: Int = SubagentActivityProjection.defaultDoneVisibleLimit,
        completedBound: Int = SubagentActivityProjection.defaultCompletedBound
    ) {
        self.active = active
        self.done = done
        self.unknown = unknown
        self.activeVisibleLimit = max(0, activeVisibleLimit)
        self.doneVisibleLimit = max(0, doneVisibleLimit)
        self.unknownVisibleLimit = max(0, unknownVisibleLimit)
        self.completedBound = max(1, completedBound)
    }

    public var activeCount: Int { active.count }
    public var doneCount: Int { done.count }
    public var unknownCount: Int { unknown.count }
    public var isEmpty: Bool { active.isEmpty && done.isEmpty && unknown.isEmpty }
    public var isLive: Bool { !active.isEmpty }

    public func visibleActive(expanded: Bool) -> [SubagentActivityItem] {
        SubagentActivityProjection.visibleSlice(active, limit: activeVisibleLimit, expanded: expanded)
    }

    public func hiddenActiveCount(expanded: Bool) -> Int {
        expanded ? 0 : max(0, active.count - activeVisibleLimit)
    }

    public func visibleDone(expanded: Bool) -> [SubagentActivityItem] {
        SubagentActivityProjection.visibleSlice(done, limit: doneVisibleLimit, expanded: expanded)
    }

    public func hiddenDoneCount(expanded: Bool) -> Int {
        expanded ? 0 : max(0, done.count - doneVisibleLimit)
    }

    public func visibleUnknown(expanded: Bool) -> [SubagentActivityItem] {
        SubagentActivityProjection.visibleSlice(unknown, limit: unknownVisibleLimit, expanded: expanded)
    }

    public func hiddenUnknownCount(expanded: Bool) -> Int {
        expanded ? 0 : max(0, unknown.count - unknownVisibleLimit)
    }

    /// Distinct providers among recent rows (legacy / tests). Prefer
    /// `compactAvatarItems` for chrome so each worker keeps its own face.
    public var compactGlyphProviders: [SubagentProviderKind] {
        var seen = Set<SubagentProviderKind>()
        var ordered: [SubagentProviderKind] = []
        for item in compactAvatarItems {
            if seen.insert(item.provider).inserted {
                ordered.append(item.provider)
            }
        }
        return ordered
    }

    /// Newest workers for the compact avatar strip (capped). Each item carries a
    /// stable per-run identity so two Claude children never share one face.
    public var compactAvatarItems: [SubagentActivityItem] {
        var ordered: [SubagentActivityItem] = []
        ordered.reserveCapacity(6)
        for item in active + done + unknown {
            ordered.append(item)
            if ordered.count >= 6 { break }
        }
        return ordered
    }
}

// MARK: - Pure projection

/// Maps admission receipts + coordinator active-run set into the Subagents snapshot.
///
/// WHY: UI must never invent lifecycle; every row and count comes from persisted
/// receipts, with coordinator state only refining “still active” for accepted work.
public enum SubagentActivityProjection {
    public static let defaultActiveVisibleLimit = 4
    public static let defaultDoneVisibleLimit = 4
    public static let defaultUnknownVisibleLimit = 4
    public static let defaultCompletedBound = 50
    // Primary thread window for the scoped activity fetch. Nested workers use a
    // separate child bound on the runtime (`defaultChildActivityReceiptLimit`).
    // Projection still scopes by selected thread + parent-chain as defense in depth.
    // Matches AgentOrchestrationRuntime.defaultActivityReceiptLimit (was 10_000, then 500, then 256).
    public static let defaultReceiptFetchLimit = 128

    /// Child bound for the 2s badge poll only (perf X-01): the badge paints at
    /// most `defaultActiveVisibleLimit + defaultDoneVisibleLimit +
    /// defaultUnknownVisibleLimit` avatars, so fetching 64 children (×4
    /// headroom = 256 nested-worker rows decoded per tick) was excessive. The
    /// wider reconciliation default stays on the runtime for launch-style reads.
    public static let defaultBadgeChildReceiptLimit = 16

    public static func project(
        receipts: [AgentOrchestrationAdmissionReceipt],
        threadIds: Set<AgentThreadID>? = nil,
        activeRunIds: Set<AgentRunID> = [],
        now: Date = Date(),
        activeVisibleLimit: Int = defaultActiveVisibleLimit,
        doneVisibleLimit: Int = defaultDoneVisibleLimit,
        unknownVisibleLimit: Int = defaultUnknownVisibleLimit,
        completedBound: Int = defaultCompletedBound
    ) -> SubagentActivitySnapshot {
        let scoped: [AgentOrchestrationAdmissionReceipt]
        if let threadIds {
            // One map + shared memo for the whole filter pass so parent-chain
            // attribution stays O(n) even with deep nested workers.
            let receiptByID = Dictionary(uniqueKeysWithValues: receipts.map { ($0.id, $0) })
            var memo: [UUID: Bool] = [:]
            scoped = receipts.filter {
                belongsToThreadScope(
                    receipt: $0,
                    threadIds: threadIds,
                    receiptByID: receiptByID,
                    memo: &memo,
                    visiting: []
                )
            }
        } else {
            scoped = receipts
        }

        var active: [SubagentActivityItem] = []
        var done: [SubagentActivityItem] = []
        var unknown: [SubagentActivityItem] = []
        active.reserveCapacity(scoped.count)
        done.reserveCapacity(min(scoped.count, completedBound))

        for receipt in scoped where isSubagentReceipt(receipt) {
            let item = mapItem(receipt: receipt, activeRunIds: activeRunIds, now: now)
            if item.isActive {
                active.append(item)
            } else if item.phase == .unknown {
                unknown.append(item)
            } else {
                done.append(item)
            }
        }

        // Active: most recently updated first so live workers surface at the top.
        active.sort { lhs, rhs in
            if lhs.lifecycleUpdatedAt != rhs.lifecycleUpdatedAt {
                return lhs.lifecycleUpdatedAt > rhs.lifecycleUpdatedAt
            }
            return lhs.admittedAt > rhs.admittedAt
        }

        // Done: newest-first by finalization (fall back to lifecycle update).
        done.sort { lhs, rhs in
            let l = lhs.finalizedAt ?? lhs.lifecycleUpdatedAt
            let r = rhs.finalizedAt ?? rhs.lifecycleUpdatedAt
            if l != r { return l > r }
            return lhs.admittedAt > rhs.admittedAt
        }

        let bound = max(1, completedBound)
        if done.count > bound {
            done = Array(done.prefix(bound))
        }
        if unknown.count > bound {
            unknown = Array(unknown.prefix(bound))
        }

        return SubagentActivitySnapshot(
            active: active,
            done: done,
            unknown: unknown,
            activeVisibleLimit: activeVisibleLimit,
            doneVisibleLimit: doneVisibleLimit,
            unknownVisibleLimit: unknownVisibleLimit,
            completedBound: bound
        )
    }

    /// `Distill · gpt-6 · High · 12k tokens · 3m 10s`: receipt route first, then what the
    /// provider reported live (it knows the model Auto actually picked and the effort in use).
    public static func metaLabel(for item: SubagentActivityItem, detail: DistillLiveStatus.SubagentDetail?) -> String? {
        guard let detail else { return item.providerModelLabel }
        var parts = [item.providerModelLabel.flatMap { $0.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } } ?? "Distill"]
        let model = detail.model?.trimmingCharacters(in: .whitespaces)
        if let model, !model.isEmpty { parts.append(model) } else if let m = item.model, !m.isEmpty { parts.append(m) }
        let effort = detail.effort?.trimmingCharacters(in: .whitespaces)
        if let effort, !effort.isEmpty { parts.append(AgentReasoningEffort(rawValue: effort)?.displayName ?? effort) }
        else if let e = item.reasoningEffort { parts.append(e.displayName) }
        if detail.tokensUsed > 0 { parts.append("\(DistillLiveStatus.formatTokens(detail.tokensUsed)) tokens") }
        return parts.joined(separator: " · ")
    }

    /// `Explore · Review the kitchen plan`: the subagent type and the task it was given.
    public static func taskLabel(for item: SubagentActivityItem, detail: DistillLiveStatus.SubagentDetail?) -> String? {
        guard let detail else { return nil }
        let description = detail.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = detail.type.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [type.isEmpty ? nil : type, description.isEmpty || description == item.displayName ? nil : description]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func mapItem(
        receipt: AgentOrchestrationAdmissionReceipt,
        activeRunIds: Set<AgentRunID> = [],
        now: Date = Date()
    ) -> SubagentActivityItem {
        let provider = normalizeProvider(receipt.provider)
        let model = normalizeModel(receipt.model)
        let phase = mapPhase(receipt: receipt, activeRunIds: activeRunIds)
        let isActive = isActiveReceipt(receipt: receipt, activeRunIds: activeRunIds)
        return SubagentActivityItem(
            id: receipt.id,
            runId: receipt.runId,
            threadId: receipt.threadId,
            nodeId: receipt.nodeId,
            displayName: displayName(nodeId: receipt.nodeId, provider: provider, model: model),
            provider: provider,
            model: model,
            reasoningEffort: receipt.reasoningEffort,
            phase: phase,
            lifecycleStatus: receipt.lifecycleStatus,
            finalRunStatus: receipt.finalRunStatus,
            admittedAt: receipt.admittedAt,
            finalizedAt: receipt.finalizedAt,
            lifecycleUpdatedAt: receipt.lifecycleUpdatedAt,
            isActive: isActive
        )
    }

    /// Root route receipts belong to the Agent App turn, not the nested-worker
    /// surface. A child is explicit when it has a parent id; the non-root
    /// fallback keeps older controller receipts visible during migration.
    public static func isSubagentReceipt(_ receipt: AgentOrchestrationAdmissionReceipt) -> Bool {
        if receipt.parentReceiptId != nil { return true }
        return receipt.nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("root") != .orderedSame
    }

    /// Whether a receipt belongs on a selected thread's Subagents badge.
    ///
    /// Includes (1) receipts whose own `threadId` is selected and (2) nested
    /// workers whose `parentReceiptId` chain reaches a receipt on a selected
    /// thread. Middleware cross-provider children run on their own Agent App
    /// thread but must still appear under the spawner; unrelated sibling-thread
    /// receipts stay excluded.
    public static func belongsToThreadScope(
        receipt: AgentOrchestrationAdmissionReceipt,
        threadIds: Set<AgentThreadID>,
        receipts: [AgentOrchestrationAdmissionReceipt]
    ) -> Bool {
        if threadIds.isEmpty { return false }
        let receiptByID = Dictionary(uniqueKeysWithValues: receipts.map { ($0.id, $0) })
        var memo: [UUID: Bool] = [:]
        return belongsToThreadScope(
            receipt: receipt,
            threadIds: threadIds,
            receiptByID: receiptByID,
            memo: &memo,
            visiting: []
        )
    }

    /// Memoized parent-chain walk used by `project`. Cycle-safe and fail-closed
    /// when an ancestor is outside the fetched receipt window.
    private static func belongsToThreadScope(
        receipt: AgentOrchestrationAdmissionReceipt,
        threadIds: Set<AgentThreadID>,
        receiptByID: [UUID: AgentOrchestrationAdmissionReceipt],
        memo: inout [UUID: Bool],
        visiting: Set<UUID>
    ) -> Bool {
        if let cached = memo[receipt.id] { return cached }
        if threadIds.contains(receipt.threadId) {
            memo[receipt.id] = true
            return true
        }
        guard let parentId = receipt.parentReceiptId,
              !visiting.contains(receipt.id),
              let parent = receiptByID[parentId] else {
            memo[receipt.id] = false
            return false
        }
        var nextVisiting = visiting
        nextVisiting.insert(receipt.id)
        let belongs = belongsToThreadScope(
            receipt: parent,
            threadIds: threadIds,
            receiptByID: receiptByID,
            memo: &memo,
            visiting: nextVisiting
        )
        memo[receipt.id] = belongs
        return belongs
    }

    /// Normalize every provider through the neutral enum. Unknown stays unknown.
    public static func normalizeProvider(_ provider: AgentProvider) -> SubagentProviderKind {
        switch provider {
        case .codex: return .codex
        case .claude: return .claude
        case .grok: return .grok
        case .distill: return .distill
        }
    }

    public static func normalizeModel(_ model: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("unknown") == .orderedSame {
            return nil
        }
        return trimmed
    }

    /// Map lifecycle + final run status without inventing success from absence.
    public static func mapPhase(
        receipt: AgentOrchestrationAdmissionReceipt,
        activeRunIds: Set<AgentRunID> = []
    ) -> SubagentActivityPhase {
        switch receipt.lifecycleStatus {
        case .accepted:
            return .working
        case .unknown:
            if AgentOrchestrationRuntime.isExternalReceipt(receipt) {
                return .unknown
            }
            if let runId = receipt.runId, activeRunIds.contains(runId) {
                return .working
            }
            return .unknown
        case .finalized:
            return mapFinalPhase(receipt.finalRunStatus)
        }
    }

    public static func mapFinalPhase(_ status: AgentRunStatus?) -> SubagentActivityPhase {
        guard let status else { return .unknown }
        switch status {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled, .interrupted: return .cancelled
        case .pending, .running: return .unknown
        }
    }

    public static func isActiveReceipt(
        receipt: AgentOrchestrationAdmissionReceipt,
        activeRunIds: Set<AgentRunID> = []
    ) -> Bool {
        switch receipt.lifecycleStatus {
        case .accepted:
            return true
        case .unknown:
            if AgentOrchestrationRuntime.isExternalReceipt(receipt) {
                return false
            }
            // Coordinator still owns the run → treat as active; otherwise stay
            // out of Done so we do not claim terminal success from uncertainty.
            if let runId = receipt.runId, activeRunIds.contains(runId) {
                return true
            }
            return false
        case .finalized:
            return false
        }
    }

    /// List title: `Nested|Native - Provider - ab12` (never empty).
    ///
    /// WHY: operators scan kind + host + a short id; the old humanized nodeId
    /// dumped pid/hex noise that hid the useful signal.
    public static func displayName(
        nodeId: String,
        provider: SubagentProviderKind = .unknown,
        model: String? = nil
    ) -> String {
        let trimmed = nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("unknown") == .orderedSame {
            if let model, !model.isEmpty { return model }
            return "Unknown"
        }
        if trimmed.caseInsensitiveCompare("root") == .orderedSame {
            // Main-route admission: prefer model, else a stable generic label.
            if let model, !model.isEmpty { return model }
            return "Root - \(providerDisplayName(provider))"
        }
        if let handle = botDelegationHandle(from: trimmed) {
            // Delegated bot peer: operators know the teammate by @handle.
            return "@\(handle)"
        }
        let kind = kindLabel(from: trimmed)
        let host = providerDisplayName(provider, nodeId: trimmed)
        let tail = lastFourIdentityChars(from: trimmed)
        return "\(kind) - \(host) - \(tail)"
    }

    /// `bot.<handle>.<runid>` → `<handle>`; nil for every other nodeId shape.
    public static func botDelegationHandle(from nodeId: String) -> String? {
        let lower = nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.lowercased().hasPrefix("bot.") else { return nil }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let handle = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return handle.isEmpty ? nil : handle
    }

    /// Resolve a delegated peer from today's Bot directory, never from the
    /// orchestration receipt, so avatar edits appear without rewriting history.
    public static func delegatedBot(
        for nodeId: String,
        among bots: [BotDefinition]
    ) -> BotDefinition? {
        guard let rawHandle = botDelegationHandle(from: nodeId),
              let handle = BotHandle.normalize(rawHandle) else { return nil }
        // Single lookup stays linear. For N avatars against one bots snapshot,
        // callers must reuse `botsByNormalizedHandle` (compact strip does).
        return bots.first { BotHandle.normalize($0.handle) == handle }
    }

    /// Shared index for avatar / peer chrome. Callers that resolve many nodeIds
    /// against one bots array should reuse this dictionary.
    public static func botsByNormalizedHandle(_ bots: [BotDefinition]) -> [String: BotDefinition] {
        var map: [String: BotDefinition] = [:]
        map.reserveCapacity(bots.count)
        for bot in bots {
            guard let key = BotHandle.normalize(bot.handle) else { continue }
            if map[key] == nil { map[key] = bot }
        }
        return map
    }

    /// `Nested` / `Native` from the durable nodeId prefix; other workers → `Worker`.
    public static func kindLabel(from nodeId: String) -> String {
        let lower = nodeId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("native.") || lower.hasPrefix("native-") || lower.hasPrefix("native_")
            || lower.hasPrefix("native ") {
            return "Native"
        }
        if lower.hasPrefix("nested.") || lower.hasPrefix("nested-") || lower.hasPrefix("nested_")
            || lower.hasPrefix("nested ") {
            return "Nested"
        }
        return "Worker"
    }

    // PERF: displayName/providerDisplayName/lastFour/humanize allocate
    // CharacterSet(charactersIn:) on every nested-worker label paint. Share
    // separator sets so multi-agent UI rebuilds do not reallocate them.
    private static let providerNodeIdSeparators = CharacterSet(charactersIn: ".-_ ")
    private static let identitySegmentSeparators = CharacterSet(charactersIn: ".-_")
    private static let humanizeNodeIdSeparators = CharacterSet(charactersIn: "-_./")

    public static func providerDisplayName(
        _ provider: SubagentProviderKind,
        nodeId: String? = nil
    ) -> String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .distill: return "Distill"
        case .unknown:
            // Fall back to a provider token embedded in the nodeId when known.
            guard let nodeId else { return "Unknown" }
            let parts = nodeId
                .lowercased()
                .components(separatedBy: providerNodeIdSeparators)
                .filter { !$0.isEmpty }
            for part in parts {
                if part == "claude" { return "Claude" }
                if part == "codex" { return "Codex" }
                if part == "grok" { return "Grok" }
            }
            return "Unknown"
        }
    }

    /// Last 4 alphanumeric characters of the trailing identity segment (uuid/hex).
    public static func lastFourIdentityChars(from nodeId: String) -> String {
        let segments = nodeId
            .components(separatedBy: identitySegmentSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidate = segments.reversed().first(where: { segment in
            segment.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
                && segment.count >= 4
        }) ?? segments.last ?? nodeId
        let compact = candidate.replacingOccurrences(of: "-", with: "")
        if compact.count >= 4 {
            return String(compact.suffix(4))
        }
        if compact.isEmpty { return "????" }
        return String((compact + String(repeating: "0", count: 4)).prefix(4))
    }

    /// `deep-worker-plan-writer` / `deep_worker_plan_writer` → "Deep worker plan writer".
    public static func humanizeNodeId(_ raw: String) -> String {
        let parts = raw
            .components(separatedBy: humanizeNodeIdSeparators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return raw }
        let words = parts.enumerated().map { index, part -> String in
            guard let first = part.first else { return part }
            // Preserve short ALLCAPS tokens (e.g. "Cp101") casing when mixed.
            if part.count <= 6, part == part.uppercased(), part.rangeOfCharacter(from: .decimalDigits) != nil {
                return part
            }
            if part == part.uppercased(), part.count <= 4 {
                return part
            }
            let normalized = first.uppercased() + part.dropFirst().lowercased()
            return index == 0 ? normalized : normalized.lowercased()
        }
        return words.joined(separator: " ")
    }

    public static func visibleSlice(
        _ items: [SubagentActivityItem],
        limit: Int,
        expanded: Bool
    ) -> [SubagentActivityItem] {
        if expanded || limit <= 0 || items.count <= limit {
            return items
        }
        return Array(items.prefix(limit))
    }

    // MARK: Duration formatting

    /// Elapsed wall time for active rows: `17d 10h 8m 37s` (omits zero high units).
    public static func formatElapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return formatElapsedSeconds(seconds)
    }

    public static func formatElapsedSeconds(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let secs = seconds % 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m \(secs)s"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m \(secs)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    /// Relative label for completed rows: `1w ago`, `2h ago`, `just now`.
    public static func formatRelative(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        let weeks = days / 7
        if weeks < 8 { return "\(weeks)w ago" }
        let months = days / 30
        if months < 24 { return "\(months)mo ago" }
        let years = days / 365
        return "\(max(1, years))y ago"
    }

    /// Trailing time label: elapsed while active, relative when done.
    public static func trailingTimeLabel(for item: SubagentActivityItem, now: Date = Date()) -> String {
        if item.isActive {
            return formatElapsed(from: item.admittedAt, to: now)
        }
        let end = item.finalizedAt ?? item.lifecycleUpdatedAt
        return formatRelative(from: end, now: now)
    }
}

// MARK: - SwiftUI: compact badge + cat roster

public struct SubagentActivityBadge: View {
    let snapshot: SubagentActivitySnapshot
    let bots: [BotDefinition]
    let now: Date
    let orchestrateActive: Bool
    let liveActivity: [AgentRunID: String]
    let liveDetail: [AgentRunID: DistillLiveStatus.SubagentDetail]
    let onOpen: ((SubagentActivityItem) -> Void)?
    @Binding var isPresented: Bool
    @State private var activeExpanded = false
    @State private var doneExpanded = false
    @State private var unknownExpanded = false

    public init(
        snapshot: SubagentActivitySnapshot,
        bots: [BotDefinition] = [],
        now: Date = Date(),
        isPresented: Binding<Bool>,
        orchestrateActive: Bool = false,
        liveActivity: [AgentRunID: String] = [:],
        liveDetail: [AgentRunID: DistillLiveStatus.SubagentDetail] = [:],
        onOpen: ((SubagentActivityItem) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.bots = bots
        self.now = now
        self.orchestrateActive = orchestrateActive
        self.liveActivity = liveActivity
        self.liveDetail = liveDetail
        self.onOpen = onOpen
        self._isPresented = isPresented
    }

    public var body: some View {
        Button { isPresented.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                badgeLabel(compact: false)
                badgeLabel(compact: true)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs)
            .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(isPresented ? DS.Palette.accent : DS.Palette.line, lineWidth: DS.Border.hairline)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsHoverFill()
        .help(accessibilityLabel)
        .accessibilityIdentifier("agent.subagents.badge")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isPresented ? "Expanded" : "Collapsed")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SubagentActivityPopoverPanel(
                snapshot: snapshot,
                bots: bots,
                now: now,
                orchestrateActive: orchestrateActive,
                liveActivity: liveActivity,
                liveDetail: liveDetail,
                onOpen: onOpen.map { open in { item in isPresented = false; open(item) } },
                activeExpanded: $activeExpanded,
                doneExpanded: $doneExpanded,
                unknownExpanded: $unknownExpanded
            )
            .frame(minWidth: 280, idealWidth: 400, maxWidth: 400)
            .background(DS.Palette.surface)
        }
        .onChange(of: isPresented) { open in
            if !open {
                activeExpanded = false
                doneExpanded = false
                unknownExpanded = false
            }
        }
    }

    private func badgeLabel(compact: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            HStack(spacing: -DS.Space.sm) {
                ForEach(snapshot.compactAvatarItems.prefix(compact ? 1 : 3)) { item in
                    SubagentCatAvatar(cat: item.cat, size: 24)
                }
                if snapshot.isEmpty {
                    Image(systemName: "pawprint.fill")
                        .font(DS.Font.captionStrong)
                        .foregroundStyle(DS.Palette.accent)
                }
            }
            .accessibilityHidden(true)
            if !compact {
                Text("Subagents")
                    .font(DS.Font.captionStrong)
                    .foregroundStyle(DS.Palette.text)
            }
            Text(compact ? "\(snapshot.activeCount + snapshot.doneCount + snapshot.unknownCount)" : countLabel)
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(snapshot.isLive ? DS.Palette.accent : DS.Palette.textSecondary)
            Image(systemName: "chevron.down")
                .font(DS.Font.caption2)
                .foregroundStyle(DS.Palette.textSecondary)
                .accessibilityHidden(true)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var countLabel: String {
        if snapshot.isEmpty { return orchestrateActive ? "Ready" : "0" }
        var parts: [String] = []
        if snapshot.activeCount > 0 { parts.append("\(snapshot.activeCount) working") }
        if snapshot.doneCount > 0 { parts.append("\(snapshot.doneCount) done") }
        if snapshot.unknownCount > 0 { parts.append("\(snapshot.unknownCount) unknown") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        if snapshot.isEmpty, orchestrateActive {
            return "Subagents, ready to help, no workers active"
        }
        return "Subagents, \(snapshot.activeCount) active, \(snapshot.doneCount) done, \(snapshot.unknownCount) unknown"
    }
}

struct SubagentActivityPopoverPanel: View {
    let snapshot: SubagentActivitySnapshot
    let bots: [BotDefinition]
    let now: Date
    let orchestrateActive: Bool
    var liveActivity: [AgentRunID: String] = [:]
    var liveDetail: [AgentRunID: DistillLiveStatus.SubagentDetail] = [:]
    var onOpen: ((SubagentActivityItem) -> Void)? = nil
    @State private var diskDetail: [UUID: DistillLiveStatus.SubagentDetail] = [:]
    @Binding var activeExpanded: Bool
    @Binding var doneExpanded: Bool
    @Binding var unknownExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.md) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Subagents")
                        .font(DS.Font.title3)
                        .foregroundStyle(DS.Palette.text)
                    Text("Titio’s little helpers")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                if snapshot.isLive {
                    DSPill("Live", tone: .accent)
                        .accessibilityIdentifier("agent.subagents.live")
                }
            }
            .padding(DS.Space.lg)
            .dsBar(edge: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    if snapshot.isEmpty {
                        HStack(alignment: .top, spacing: DS.Space.lg) {
                            Image(systemName: "pawprint")
                                .font(DS.Font.title2)
                                .foregroundStyle(DS.Palette.accent)
                                .accessibilityHidden(true)
                            Text(orchestrateActive
                                 ? "Ready to help. Cats appear here when the agent delegates work."
                                 : "No helpers yet. Delegated work will appear here.")
                                .font(DS.Font.bodyDense)
                                .foregroundStyle(DS.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(DS.Space.lg)
                        .accessibilityIdentifier("agent.subagents.empty")
                    }
                    if !snapshot.active.isEmpty {
                        section("Active", count: snapshot.activeCount,
                                items: snapshot.visibleActive(expanded: activeExpanded),
                                hidden: snapshot.hiddenActiveCount(expanded: activeExpanded),
                                expanded: $activeExpanded)
                    }
                    if !snapshot.done.isEmpty {
                        section("Done", count: snapshot.doneCount,
                                items: snapshot.visibleDone(expanded: doneExpanded),
                                hidden: snapshot.hiddenDoneCount(expanded: doneExpanded),
                                expanded: $doneExpanded)
                    }
                    if !snapshot.unknown.isEmpty {
                        section("Unknown", count: snapshot.unknownCount,
                                items: snapshot.visibleUnknown(expanded: unknownExpanded),
                                hidden: snapshot.hiddenUnknownCount(expanded: unknownExpanded),
                                expanded: $unknownExpanded)
                    }
                }
                .padding(DS.Space.md)
            }
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("agent.subagents.popover")
        .task(id: snapshot.active.count + snapshot.done.count) {
            let missing = (snapshot.active + snapshot.done + snapshot.unknown).filter {
                $0.provider == .distill && diskDetail[$0.id] == nil && $0.runId.map { liveDetail[$0] == nil } ?? false
            }
            guard !missing.isEmpty else { return }
            let found = await Task.detached(priority: .utility) {
                Dictionary(missing.compactMap { item in
                    item.runId.flatMap { DistillSubagentTranscriptReader.summaryDetail(sessionId: $0.value.uuidString.lowercased()) }
                        .map { (item.id, $0) }
                }, uniquingKeysWith: { a, _ in a })
            }.value
            diskDetail.merge(found) { _, new in new }
        }
    }

    private func section(_ title: String, count: Int, items: [SubagentActivityItem],
                         hidden: Int, expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(title.uppercased())
                    .tracking(0.6)
                Spacer()
                Text("\(count)").monospacedDigit()
            }
            .font(DS.Font.caption2.weight(.semibold))
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.md)
            .accessibilityIdentifier("agent.subagents.section.\(title.lowercased())")
            ForEach(items) { item in row(item) }
            if hidden > 0 || expanded.wrappedValue {
                Button { expanded.wrappedValue.toggle() } label: {
                    HStack(spacing: DS.Space.xs) {
                        Text(expanded.wrappedValue ? "Show Less" : "Show \(hidden) More")
                        Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                            .accessibilityHidden(true)
                    }
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.accent)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, DS.Space.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dsHoverFill()
                .accessibilityIdentifier("agent.subagents.\(title.lowercased()).showMore")
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SubagentActivityItem) -> some View {
        let detail = item.runId.flatMap { liveDetail[$0] } ?? diskDetail[item.id]
        let view = SubagentActivityRowView(item: item, bots: bots, now: now,
                                          activity: item.isActive ? item.runId.flatMap { liveActivity[$0] } : nil,
                                          detail: detail)
        if let onOpen, DistillSubagentTranscriptPane.canOpen(item) {
            Button { onOpen(item) } label: {
                HStack(spacing: DS.Space.xs) {
                    view
                    Image(systemName: "chevron.right")
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .accessibilityHidden(true)
                }
                .padding(.trailing, DS.Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsHoverFill(cornerRadius: DS.Radius.card)
            .help("Open \(item.cat.name)’s work")
            .accessibilityHint("Opens the subagent's work in a side pane")
        } else {
            view
        }
    }
}

struct SubagentActivityRowView: View {
    let item: SubagentActivityItem
    let bots: [BotDefinition]
    let now: Date
    var activity: String? = nil
    var detail: DistillLiveStatus.SubagentDetail? = nil

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            SubagentCatAvatar(cat: item.cat, size: 48)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Text(item.cat.name)
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Palette.text)
                        .lineLimit(1)
                    Text(item.cat.shortID)
                        .font(DS.Font.monoSmall)
                        .foregroundStyle(DS.Palette.textSecondary)
                    Spacer(minLength: 0)
                    Text(SubagentActivityProjection.trailingTimeLabel(for: item, now: now))
                        .font(DS.Font.caption2.monospacedDigit())
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize()
                }
                .help(identityHelp)
                HStack(spacing: DS.Space.sm) {
                    SubagentStatusPill(item: item)
                    Text(item.cat.breed)
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                if let task = SubagentActivityProjection.taskLabel(for: item, detail: detail) {
                    Text(task)
                        .font(DS.Font.bodyDense)
                        .foregroundStyle(DS.Palette.text)
                        .lineLimit(2)
                        .help(task)
                        .accessibilityIdentifier("agent.subagents.row.task")
                }
                if let activity = activity ?? detail?.activity {
                    Text(activity)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(activity)
                        .accessibilityIdentifier("agent.subagents.row.activity")
                }
                if let meta = SubagentActivityProjection.metaLabel(for: item, detail: detail) {
                    Text(meta)
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(meta)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Space.md)
        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityIdentifier("agent.subagents.row.\(item.id.uuidString)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    private var identityHelp: String {
        let bot = SubagentActivityProjection.delegatedBot(for: item.nodeId, among: bots)
        return [item.cat.name, item.cat.breed, bot?.name, item.displayName, item.id.uuidString]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var rowAccessibilityLabel: String {
        let time = SubagentActivityProjection.trailingTimeLabel(for: item, now: now)
        let meta = SubagentActivityProjection.metaLabel(for: item, detail: detail)
        let task = SubagentActivityProjection.taskLabel(for: item, detail: detail)
        return [item.cat.name, item.cat.breed, item.cat.shortID, item.statusLabel,
                task, activity ?? detail?.activity, meta, time].compactMap { $0 }.joined(separator: ", ")
    }
}
