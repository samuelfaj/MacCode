import AppKit
import CoreModel
import DesignSystemKit
import SwiftUI

/// Shared live-turn chrome for Agent App chat composition on Bots Desk.
///
/// WHY: Desk must paint the same live turn Agent App does — user bubble →
/// Work so far (Thinking…/Thought + tools) → final markdown — from the linked
/// thread's persisted stream events. A composer Thinking pill is not enough.
public enum AgentChatLiveTurnChrome {
    /// Only live tools started by this run belong in its running strip.
    static func runningTools(in turns: [AssistantTurnSnapshot], since startedAt: Date?) -> [AssistantItem] {
        guard let startedAt else { return [] }
        let start = floor(startedAt.timeIntervalSince1970 * 1_000)
        return turns.filter { !$0.finished }.flatMap(\.items).filter { item in
            guard item.state == .streaming, Double(item.startedAtMs) >= start else { return false }
            switch item.type {
            case .tool, .commandExecution, .mcpToolCall, .dynamicToolCall, .collabToolCall: return true
            default: return false
            }
        }
    }

    static func recentToolOutput(_ item: AssistantItem) -> String? {
        guard let output = item.output, !output.isEmpty else { return nil }
        let text = promptOutputText(in: output) ?? output
        guard !text.isEmpty else { return nil }
        return String(text.suffix(2_000))
    }

    /// Distill appends raw tool JSON to `output`; the newest `output_for_prompt`
    /// (else `output` string) is the readable text.
    private static func promptOutputText(in output: String) -> String? {
        lastJSONStringField("output_for_prompt", in: output) ?? lastJSONStringField("output", in: output)
    }

    private static func lastJSONStringField(_ key: String, in output: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
              let range = Range(match.range(at: 1), in: output),
              let data = "\"\(output[range])\"".data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
        else { return nil }
        return decoded
    }

    private static let toolGroupSummaryLock = NSLock()
    private static var toolGroupSummaryMemo: [String: String] = [:]

    /// A split turn is still one turn: only its first chronological slice owns
    /// the shared Work/Worked heading, including after the turn finishes.
    public static func showsWorkHeader(for segment: AgentChatTurnSegmentation.TurnSegment) -> Bool {
        segment.isFirst
    }

    /// Render-relevant identity for live rows. Byte counts alone freeze
    /// `itemProgress` % and equal-length text replacement.
    static func liveRowItemInputsMatch(_ lhs: AssistantItem, _ rhs: AssistantItem) -> Bool {
        lhs.id == rhs.id
            && lhs.state == rhs.state
            && lhs.type == rhs.type
            && lhs.progress == rhs.progress
            && lhs.resourcePath == rhs.resourcePath
            && lhs.distillApplied == rhs.distillApplied
            && liveTextFingerprint(lhs.summary) == liveTextFingerprint(rhs.summary)
            && liveTextFingerprint(lhs.body) == liveTextFingerprint(rhs.body)
            && liveTextFingerprint(lhs.output) == liveTextFingerprint(rhs.output)
    }

    /// Count + head/mid/tail so equal-length replacement still invalidates
    /// without walking multi-MiB tool output on every SwiftUI equality tick.
    static func liveTextFingerprint(_ text: String?) -> UInt64 {
        guard let text, !text.isEmpty else { return 0 }
        let utf8 = text.utf8
        let count = utf8.count
        func mix<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
            var h: UInt64 = 2_166_136_261
            for b in bytes {
                h ^= UInt64(b)
                h = h &* 16_777_619
            }
            return h
        }
        let head = mix(utf8.prefix(64))
        let tail = mix(utf8.suffix(64))
        let midDrop = count > 64 ? max(0, (count / 2) - 32) : 0
        let mid = mix(utf8.dropFirst(midDrop).prefix(64))
        return UInt64(count) ^ (head &* 0x9E37_79B9_7F4A_7C15) ^ mid ^ (tail &* 0xC2B2_AE3D_27D4_EB4F)
    }

    public static func timelineByReplaying(_ events: [AssistantEvent]) -> AssistantTimelineState {
        var next = AssistantTimelineState()
        for event in events {
            next.apply(event, nowMs: nil)
        }
        next.enforceAggregateHotTextBudget()
        return next
    }

    public static func turnDurationLabel(_ turn: AssistantTurnSnapshot) -> String? {
        // Sum each item's own span. Min-start to max-finish counted idle
        // hours between tools as work ("Worked for 258m" on a greeting).
        guard !turn.items.isEmpty else { return nil }
        var totalMs: Int64 = 0
        for item in turn.items {
            guard let end = item.finishedAtMs, end >= item.startedAtMs else { return nil }
            totalMs += end - item.startedAtMs
        }
        let seconds = Int(totalMs / 1000)
        guard seconds > 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    public static func completedWorkLabel(
        _ turn: AssistantTurnSnapshot,
        live: Bool = false,
        workBlockCount: Int = 0
    ) -> String {
        if live {
            if workBlockCount > 1 {
                return "Work so far · \(workBlockCount) steps in this turn"
            }
            return "Work so far"
        }
        if let duration = turnDurationLabel(turn) {
            return "Worked for \(duration)"
        }
        return "Worked"
    }

    public static func reasoningTitle(isStreaming: Bool) -> String {
        isStreaming ? "Thinking…" : "Thought"
    }

    public static func reasoningText(_ item: AssistantItem) -> String {
        item.body.isEmpty ? (AgentTimelineItemPresentation.make(for: item).detail ?? "") : item.body
    }

    /// The thought the model is on right now: the latest reasoning item, until
    /// the answer starts. Tail only, so the line stays one fixed-height box.
    public static func liveThought(_ turn: AssistantTurnSnapshot) -> String? {
        guard !turn.finished,
              let index = turn.items.lastIndex(where: { $0.type == .reasoning }) else { return nil }
        guard !turn.items[(index + 1)...].contains(where: { $0.type == .assistantMessage }) else { return nil }
        let text = reasoningText(turn.items[index])
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
        let tail = lines.joined(separator: "\n")
        return tail.count > 280 ? "…" + String(tail.suffix(280)) : tail
    }

    public static func isGroupableTool(_ type: AssistantItemType) -> Bool {
        switch type {
        case .tool, .commandExecution, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .imageView, .fileChange:
            return true
        case .reasoning, .plan, .assistantMessage, .review, .contextCompaction, .error:
            return false
        }
    }

    public static func hasStreamingTools(in timeline: AssistantTimelineState) -> Bool {
        timeline.turns.contains { turn in
            !turn.finished && turn.items.contains {
                $0.state == .streaming && isGroupableTool($0.type)
            }
        }
    }

    /// Concise, real activity for Simple mode while a provider tool is running.
    public static func liveToolActivity(_ turn: AssistantTurnSnapshot) -> String? {
        guard !turn.finished,
              let index = turn.items.lastIndex(where: { $0.state == .streaming && isGroupableTool($0.type) }),
              !turn.items[(index + 1)...].contains(where: { $0.type == .assistantMessage })
        else { return nil }
        let item = turn.items[index]
        switch item.type {
        case .commandExecution: return "Command activity"
        case .webSearch: return "Web search activity"
        case .fileChange: return "File activity"
        case .imageView: return "Image activity"
        case .tool, .mcpToolCall, .dynamicToolCall, .collabToolCall: return "Tool activity"
        case .reasoning, .plan, .assistantMessage, .review, .contextCompaction, .error:
            return nil
        }
    }

    public static func splitTurn(_ turn: AssistantTurnSnapshot) -> (activity: [AssistantItem], outside: [AssistantItem]) {
        guard turn.finished else { return (turn.items, []) }

        let final = turn.finalAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !final.isEmpty {
            return (
                turn.items.filter {
                    !($0.type == .assistantMessage && assistantTextsMatch($0.body, final))
                },
                []
            )
        }

        guard let finalIndex = turn.items.lastIndex(where: {
            $0.type == .assistantMessage
                && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return (turn.items, [])
        }
        var activity = turn.items
        let finalItem = activity.remove(at: finalIndex)
        return (activity, [finalItem])
    }

    /// Desk / Agent App composition keeps every non-final item in provider
    /// append order. Only the final answer may sit outside the activity stream.
    public static func compose(_ turn: AssistantTurnSnapshot) -> (
        activity: [AssistantItem],
        outside: [AssistantItem]
    ) {
        let split = splitTurn(turn)
        var outside = deduplicatedAssistantItems(split.outside)
        if turn.finished,
           let final = turn.finalAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !final.isEmpty {
            outside.removeAll {
                $0.type == .assistantMessage && assistantTextsMatch($0.body, final)
            }
        }
        return (split.activity, outside)
    }

    /// The work items a Verbosity Human turn still paints: its errors.
    public static func visibleErrors(in activity: [AssistantItem]) -> [AssistantItem] {
        activity.filter { $0.type == .error }
    }

    /// Claude often emits a streaming assistantMessage and then a snapshot
    /// item with the same body in one turn. Paint that answer once.
    static func deduplicatedAssistantItems(_ items: [AssistantItem]) -> [AssistantItem] {
        var result: [AssistantItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard item.type == .assistantMessage else {
                result.append(item)
                continue
            }
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = result.firstIndex(where: {
                $0.type == .assistantMessage && assistantTextsMatch($0.body, body)
            }) {
                let existing = result[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.count > existing.count {
                    result[index] = item
                }
                continue
            }
            result.append(item)
        }
        return result
    }

    public static func workItems(in turn: AssistantTurnSnapshot) -> [AssistantItem] {
        compose(turn).activity
    }

    public static func assistantBodies(in turn: AssistantTurnSnapshot) -> [String] {
        var texts: [String] = []
        for item in turn.items where item.type == .assistantMessage {
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { texts.append(body) }
        }
        if let final = turn.finalAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !final.isEmpty {
            texts.append(final)
        }
        return texts
    }

    public static func assistantTextsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Persisted assistant bubbles must not sit next to the same turn-owned answer.
    public static func messageDuplicatesTurn(_ text: String, turns: [AssistantTurnSnapshot]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return turns.contains { turn in
            assistantBodies(in: turn).contains { assistantTextsMatch(trimmed, $0) }
        }
    }

    /// Later turns that only repeat an earlier final must not paint that answer again.
    ///
    /// Hot path is exact membership in a set of compact/normalized prior finals
    /// (`AgentTranscriptOrder.normalizedFinalText`). Substring matching stays on
    /// `assistantTextsMatch` for compose/dedupe, where the lists are small.
    ///
    /// Compatibility overload: rebuilds and re-normalizes the full prior-final
    /// set on every call. Do not use this in a per-turn loop. Agent App paint
    /// context and Bots Desk timeline grow one `Set` with
    /// `insertNormalizedAssistantFinals` and call
    /// `shouldHideAssistantOutput(_:previousNormalizedFinals:)`.
    public static func shouldHideAssistantOutput(
        _ turn: AssistantTurnSnapshot,
        previousTurns: [AssistantTurnSnapshot]
    ) -> Bool {
        var previousNormalizedFinals = Set<String>()
        previousNormalizedFinals.reserveCapacity(previousTurns.count)
        for previous in previousTurns {
            insertNormalizedAssistantFinals(from: previous, into: &previousNormalizedFinals)
        }
        return shouldHideAssistantOutput(turn, previousNormalizedFinals: previousNormalizedFinals)
    }

    public static func shouldHideAssistantOutput(
        _ turn: AssistantTurnSnapshot,
        previousNormalizedFinals: Set<String>
    ) -> Bool {
        guard !previousNormalizedFinals.isEmpty else { return false }
        for normalized in normalizedAssistantFinals(for: turn)
        where previousNormalizedFinals.contains(normalized) {
            return true
        }
        return false
    }

    public static func insertNormalizedAssistantFinals(
        from turn: AssistantTurnSnapshot,
        into previousNormalizedFinals: inout Set<String>
    ) {
        for normalized in normalizedAssistantFinals(for: turn) {
            previousNormalizedFinals.insert(normalized)
        }
    }

    /// Non-empty normalized (whitespace-stripped, 32 KiB-capped) assistant
    /// bodies + final of a turn. The row paint context recomputes these for
    /// every visible turn on every body pass — a per-scalar walk over all
    /// visible assistant text per frame. Finished turns are immutable in
    /// practice, so their result is memoized by (turnId, items.count, content
    /// fingerprints); live turns are always recomputed.
    /// Peak entries / UTF-8 cost of stored normalized strings.
    nonisolated static let normalizedFinalsMemoCountLimit = 128
    nonisolated static let normalizedFinalsMemoCostLimit = 128 * 1024
    private static let normalizedFinalsMemo: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = normalizedFinalsMemoCountLimit
        cache.totalCostLimit = normalizedFinalsMemoCostLimit
        return cache
    }()
    public private(set) nonisolated(unsafe) static var normalizedFinalsComputeCountForTesting = 0

    public static func normalizedAssistantFinals(for turn: AssistantTurnSnapshot) -> [String] {
        let key: NSString? = turn.finished
            ? "\(turn.turnId)|\(turn.items.count)|\(AgentMessageMarkdown.sourceFingerprint(for: turn.finalAssistantMessage ?? ""))" as NSString
            : nil
        if let key, let cached = normalizedFinalsMemo.object(forKey: key) as? [String] {
            return cached
        }
        normalizedFinalsComputeCountForTesting &+= 1
        var result: [String] = []
        var cost = 0
        for body in assistantBodies(in: turn) {
            let normalized = AgentTranscriptOrder.normalizedFinalText(body)
            if !normalized.isEmpty {
                result.append(normalized)
                cost += normalized.utf8.count
            }
        }
        if let key {
            normalizedFinalsMemo.setObject(result as NSArray, forKey: key, cost: max(1, cost))
        }
        return result
    }

    public static func paintsLiveTurnChrome(_ timeline: AssistantTimelineState) -> Bool {
        timeline.turns.contains {
            let composition = compose($0)
            return !composition.activity.isEmpty
        }
    }

    /// Keep a live in-memory apply when SQLite replay is still catching up.
    public static func isRicher(_ lhs: AssistantTimelineState, than rhs: AssistantTimelineState) -> Bool {
        // PERF: single pass instead of filter×2 + flatMap×2 (four timeline
        // walks per replay compare on the live-stream path).
        var lhsFinished = 0, rhsFinished = 0
        var lhsItems = 0, rhsItems = 0
        var lhsWeight = 0, rhsWeight = 0
        for turn in lhs.turns {
            if turn.finished { lhsFinished += 1 }
            for item in turn.items {
                lhsItems += 1
                lhsWeight += item.body.utf8.count + (item.output?.utf8.count ?? 0)
            }
        }
        for turn in rhs.turns {
            if turn.finished { rhsFinished += 1 }
            for item in turn.items {
                rhsItems += 1
                rhsWeight += item.body.utf8.count + (item.output?.utf8.count ?? 0)
            }
        }
        if rhsFinished > lhsFinished { return false }
        if lhsItems != rhsItems { return lhsItems > rhsItems }
        return lhsWeight > rhsWeight
    }

    public static func shouldRenderFinalMessage(
        _ turn: AssistantTurnSnapshot,
        composition: (activity: [AssistantItem], outside: [AssistantItem])? = nil
    ) -> Bool {
        guard turn.finished else { return false }
        let final = turn.finalAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !final.isEmpty else { return false }
        let outside = (composition ?? compose(turn)).outside
        return !outside.contains {
            $0.type == .assistantMessage && assistantTextsMatch($0.body, final)
        }
    }

    public static func turnSortDate(_ turn: AssistantTurnSnapshot) -> Date {
        // Replay applies turnStarted with Date(), which dumps every historical
        // Worked block at "now". Item timestamps survive persist and keep
        // user → work → answer in conversation order.
        if let ms = turn.items.min(by: { $0.startedAtMs < $1.startedAtMs })?.startedAtMs, ms > 0 {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        if let ms = turn.startedAtMs {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        return Date.distantPast
    }

    /// AA-23: a turn with hundreds of steps mounted every block as an eager row
    /// and, while live, re-diffed all of them on every paint tick. Paint the
    /// newest `AgentWorkDisclosureLayout.expandedPaintWindow` blocks; older ones
    /// stay one tap away behind "Show earlier steps" (same policy the transcript
    /// already uses for older entries). Nothing is dropped — only deferred.
    public static func visibleWorkBlocks(
        _ blocks: [AgentChatWorkBlock],
        revealCount: Int
    ) -> (hiddenCount: Int, rows: [AgentChatWorkBlock]) {
        AgentWorkDisclosureLayout.paintSlice(all: blocks, revealCount: revealCount)
    }

    public static func workBlocks(from items: [AssistantItem], groupThreshold: Int = 2) -> [AgentChatWorkBlock] {
        var blocks: [AgentChatWorkBlock] = []
        var run: [AssistantItem] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count >= groupThreshold,
               !AgentTimelineItemPresentation.mustKeepToolsUngrouped(run) {
                blocks.append(.toolGroup(id: run[0].id, items: run))
            } else {
                blocks.append(contentsOf: run.map { .item($0) })
            }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            if isGroupableTool(item.type) {
                run.append(item)
            } else {
                flushRun()
                blocks.append(.item(item))
            }
        }
        flushRun()
        return blocks
    }

    public static func toolGroupSummary(_ items: [AssistantItem]) -> String {
        // Single pass feeds the memo key plus the noun/verb classification
        // below; counts, key, and verdicts identical to the reduce/map scans.
        // AA-23: the memo key used to be built AFTER a pass that ran
        // `AgentTimelineItemPresentation.make` per item and joined every id into
        // a string (~11 KB for a 300-command group) — per frame, before the memo
        // was even consulted. Hash the identity first; classify only on a miss.
        var streamingCount = 0
        var failedCount = 0
        var identity = Hasher()
        var types = Set<AssistantItemType>()
        for item in items {
            if item.state == .streaming { streamingCount += 1 }
            if item.state == .failed { failedCount += 1 }
            identity.combine(item.id)
            types.insert(item.type)
        }
        let key = "\(items.count)|\(streamingCount)|\(failedCount)|\(identity.finalize())"
        toolGroupSummaryLock.lock()
        if let cached = toolGroupSummaryMemo[key] {
            toolGroupSummaryLock.unlock()
            return cached
        }
        toolGroupSummaryLock.unlock()
        var verbs = Set<String>()
        for item in items {
            verbs.insert(AgentTimelineItemPresentation.make(for: item).verb)
        }
        let noun: String = {
            let plural = items.count != 1
            switch types {
            case [.fileChange]: return plural ? "files" : "file"
            case [.webSearch]: return plural ? "searches" : "search"
            case [.imageView]: return plural ? "images" : "image"
            default: return plural ? "commands" : "command"
            }
        }()
        let value: String
        if items.contains(where: { AgentTimelineItemPresentation.showsLiveToolElapsed(for: $0)
            && AgentTimelineItemPresentation.isTaskWaitTool(for: $0) }) {
            value = "Waiting \(items.count) \(noun)…"
        } else if streamingCount > 0 {
            value = "Running \(items.count) \(noun)…"
        } else {
            let verb = verbs.count == 1 ? (verbs.first ?? "Ran") : "Ran"
            value = "\(verb) \(items.count) \(noun)"
        }
        toolGroupSummaryLock.lock()
        if toolGroupSummaryMemo.count > 256 { toolGroupSummaryMemo.removeAll(keepingCapacity: true) }
        toolGroupSummaryMemo[key] = value
        toolGroupSummaryLock.unlock()
        return value
    }
}

public enum AgentChatWorkBlock: Identifiable, Equatable, Sendable {
    case item(AssistantItem)
    case toolGroup(id: String, items: [AssistantItem])

    public var id: String {
        switch self {
        case .item(let item): return "block-item-\(item.id)"
        case .toolGroup(let id, _): return "block-group-\(id)"
        }
    }
}

// MARK: - Reasoning

public struct AgentChatReasoningRow: View, Equatable {
    public let item: AssistantItem
    @Binding public var expandedIDs: Set<String>

    public init(item: AssistantItem, expandedIDs: Binding<Set<String>>) {
        self.item = item
        self._expandedIDs = expandedIDs
    }

    public static func == (lhs: AgentChatReasoningRow, rhs: AgentChatReasoningRow) -> Bool {
        AgentChatLiveTurnChrome.liveRowItemInputsMatch(lhs.item, rhs.item)
            && lhs.expandedIDs.contains(lhs.item.id) == rhs.expandedIDs.contains(rhs.item.id)
    }

    public var body: some View {
        let text = AgentChatLiveTurnChrome.reasoningText(item)
        let streaming = item.state == .streaming
        let expanded = !streaming && expandedIDs.contains(item.id)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard !streaming, !text.isEmpty else { return }
                if expanded { expandedIDs.remove(item.id) } else { expandedIDs.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    if !streaming, !text.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: streaming))
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(streaming ? "" : (text.isEmpty ? "" : (expanded ? "Hide reasoning" : "Show reasoning")))
            if expanded, !text.isEmpty {
                AgentSelectablePlainText(
                    text: text,
                    fontSize: 12,
                    textColor: DS.NS.textTertiary,
                    lineSpacing: 3
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.reasoning.\(item.id)")
    }
}

// MARK: - Tool rows

public struct AgentChatLiveToolRow: View, Equatable {
    public let item: AssistantItem
    @Binding public var expandedIDs: Set<String>

    public init(item: AssistantItem, expandedIDs: Binding<Set<String>>) {
        self.item = item
        self._expandedIDs = expandedIDs
    }

    public static func == (lhs: AgentChatLiveToolRow, rhs: AgentChatLiveToolRow) -> Bool {
        AgentChatLiveTurnChrome.liveRowItemInputsMatch(lhs.item, rhs.item)
            && lhs.expandedIDs.contains(lhs.item.id) == rhs.expandedIDs.contains(rhs.item.id)
    }

    public var body: some View {
        if let editModel = AgentFileEditDiffPresentation.model(for: item),
           editModel.hasRenderableCode || item.type == .fileChange {
            AgentFileEditDiffCard(
                model: editModel,
                initiallyExpanded: AgentWorkDisclosureLayout.diffDefaultExpanded
            )
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
        let presentation = AgentTimelineItemPresentation.make(for: item)
        let displayLabel = AgentTimelineItemPresentation.toolDisplayLabel(for: item)
        let commandFull = AgentTimelineItemPresentation.rawShellCommand(for: item)
            ?? AgentTimelineItemPresentation.toolCommandPreview(for: item)
        let commandSummary = AgentTimelineItemPresentation.toolCommandSummary(for: item)
        let isBackground = AgentTimelineItemPresentation.isBackgroundTool(for: item)
        let output = presentation.detail
        let hasOutput = (output?.isEmpty == false)
        let activityHint = AgentTimelineItemPresentation.toolActivityHint(for: item, hasOutput: hasOutput)
        let fullDiffersFromSummary = (commandFull != nil && commandFull != commandSummary)
        let canExpand = hasOutput
            || fullDiffersFromSummary
            || (commandFull.map { $0.count > 96 || $0.contains("\n") } ?? false)
            || AgentTimelineItemPresentation.toolCanExpandWithoutOutput(for: item)
        let expanded = expandedIDs.contains(item.id)
        let statusColor: Color = {
            switch item.state {
            case .streaming: return DS.Palette.accent
            case .failed: return DS.Palette.danger
            case .cancelled: return DS.Palette.textTertiary
            case .completed: return DS.Palette.textSecondary
            }
        }()
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard canExpand else { return }
                if expanded { expandedIDs.remove(item.id) } else { expandedIDs.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    (Text("\(presentation.verb) ")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                     + Text(displayLabel)
                        .font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text))
                    .lineLimit(1).truncationMode(.tail)
                    if isBackground {
                        Text("Background")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(DS.Palette.accent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                    if item.state == .streaming {
                        Text(AgentTimelineItemPresentation.toolStreamingStatusLabel(for: item))
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.accent)
                    } else if item.state == .failed {
                        Text("Failed")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.danger)
                    }
                    if canExpand {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentTimelineItemPresentation.toolAccessibilityLabel(for: item))

            if let summary = commandSummary, !summary.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    AgentSelectablePlainText(
                        text: summary,
                        fontSize: 11,
                        monospaced: true,
                        textColor: DS.NS.textSecondary,
                        maximumNumberOfLines: expanded ? nil : 1
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let full = commandFull, !full.isEmpty {
                        AgentChatCopyButton(text: full) { copied in
                            Image(systemName: AgentChatCopyChrome.symbolName(copied: copied))
                                .font(.system(size: 10))
                                .foregroundColor(DS.Palette.textTertiary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .help("Copy full command")
                        .accessibilityIdentifier("agent.tool.copyCommand.\(item.id)")
                    }
                }
                .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }

            if let activityHint {
                HStack(alignment: .center, spacing: DS.Space.sm) {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                    Text(activityHint)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .accessibilityIdentifier("agent.tool.activityHint.\(item.id)")
            }

            if expanded, let full = commandFull, fullDiffersFromSummary, !full.isEmpty {
                AgentSelectablePlainText(
                    text: full,
                    fontSize: 11,
                    monospaced: true,
                    textColor: DS.NS.textTertiary
                )
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .accessibilityIdentifier("agent.tool.fullCommand.\(item.id)")
            }

            if expanded, let o = output, !o.isEmpty {
                AgentSelectablePlainText(
                    text: AgentTimelineItemPresentation.cappedDetail(o, for: item),
                    fontSize: 12,
                    monospaced: true,
                    textColor: DS.NS.textSecondary
                )
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.tool.row.\(item.id)")
    }
}

public struct AgentChatToolGroupRow: View {
    public let id: String
    public let items: [AssistantItem]
    @Binding public var expandedGroupIDs: Set<String>
    @Binding public var expandedToolIDs: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        id: String,
        items: [AssistantItem],
        expandedGroupIDs: Binding<Set<String>>,
        expandedToolIDs: Binding<Set<String>>
    ) {
        self.id = id
        self.items = items
        self._expandedGroupIDs = expandedGroupIDs
        self._expandedToolIDs = expandedToolIDs
    }

    public var body: some View {
        let streaming = items.contains { $0.state == .streaming }
        let failed = items.contains { $0.state == .failed }
        let expanded = expandedGroupIDs.contains(id)
        let headerIcon = streaming
            ? "circle.dotted"
            : (failed ? "exclamationmark.triangle" : "terminal")
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Button {
                withAnimation(reduceMotion ? nil : DS.Motion.micro) {
                    if expanded { expandedGroupIDs.remove(id) } else { expandedGroupIDs.insert(id) }
                }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .frame(width: 10)
                    Image(systemName: headerIcon)
                        .font(.system(size: 11))
                        .foregroundColor(failed ? DS.Palette.danger : DS.Palette.textSecondary)
                    Text(AgentChatLiveTurnChrome.toolGroupSummary(items))
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !expanded {
                        Text("\(items.count)")
                            .font(DS.Font.caption2.weight(.semibold).monospacedDigit())
                            .foregroundColor(DS.Palette.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(DS.Palette.surface)
                            .clipShape(Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    ForEach(items) { item in
                        AgentChatLiveToolRow(item: item, expandedIDs: $expandedToolIDs)
                            .equatable()
                    }
                }
                .padding(.leading, DS.Space.md)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.toolGroup.\(id)")
    }
}

// MARK: - Work so far

public struct AgentChatWorkSoFarDisclosure: View {
    public let turn: AssistantTurnSnapshot
    public let live: Bool
    public let blocks: [AgentChatWorkBlock]
    public let workBlockCount: Int
    public let isExpanded: Bool
    public let onToggle: () -> Void
    @Binding public var expandedReasoning: Set<String>
    @Binding public var expandedTools: Set<String>
    @Binding public var expandedToolGroups: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        turn: AssistantTurnSnapshot,
        live: Bool,
        blocks: [AgentChatWorkBlock],
        workBlockCount: Int,
        isExpanded: Bool,
        onToggle: @escaping () -> Void,
        expandedReasoning: Binding<Set<String>>,
        expandedTools: Binding<Set<String>>,
        expandedToolGroups: Binding<Set<String>>
    ) {
        self.turn = turn
        self.live = live
        self.blocks = blocks
        self.workBlockCount = workBlockCount
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self._expandedReasoning = expandedReasoning
        self._expandedTools = expandedTools
        self._expandedToolGroups = expandedToolGroups
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Button {
                withAnimation(reduceMotion ? nil : DS.Motion.micro) { onToggle() }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    if live {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(AgentChatLiveTurnChrome.completedWorkLabel(
                        turn,
                        live: live,
                        workBlockCount: workBlockCount
                    ))
                    .font(DS.Font.body.weight(.medium))
                    .foregroundColor(DS.Palette.textTertiary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide work details" : "Show work details")
            .accessibilityLabel(isExpanded ? "Hide work details" : "Show work details")
            .accessibilityIdentifier(live ? "agent.liveWork.\(turn.turnId)" : "agent.completedWork.\(turn.turnId)")

            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    ForEach(blocks) { block in
                        AgentChatWorkBlockView(
                            block: block,
                            expandedReasoning: $expandedReasoning,
                            expandedTools: $expandedTools,
                            expandedToolGroups: $expandedToolGroups
                        )
                    }
                }
                .padding(.leading, DS.Space.md)
                .transition(AgentChatMotion.transition(.fadeAndMove, reduceMotion: reduceMotion))
                .accessibilityIdentifier("agent.work.lazyList.\(turn.turnId)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct AgentChatWorkBlockView: View {
    public let block: AgentChatWorkBlock
    @Binding public var expandedReasoning: Set<String>
    @Binding public var expandedTools: Set<String>
    @Binding public var expandedToolGroups: Set<String>

    public var body: some View {
        switch block {
        case .item(let item):
            AgentChatLiveItemRow(
                item: item,
                expandedReasoning: $expandedReasoning,
                expandedTools: $expandedTools
            )
            .equatable()
        case .toolGroup(let id, let items):
            AgentChatToolGroupRow(
                id: id,
                items: items,
                expandedGroupIDs: $expandedToolGroups,
                expandedToolIDs: $expandedTools
            )
        }
    }
}

public struct AgentChatLiveItemRow: View, Equatable {
    public let item: AssistantItem
    @Binding public var expandedReasoning: Set<String>
    @Binding public var expandedTools: Set<String>

    public static func == (lhs: AgentChatLiveItemRow, rhs: AgentChatLiveItemRow) -> Bool {
        AgentChatLiveTurnChrome.liveRowItemInputsMatch(lhs.item, rhs.item)
            && lhs.expandedReasoning.contains(lhs.item.id) == rhs.expandedReasoning.contains(rhs.item.id)
            && lhs.expandedTools.contains(lhs.item.id) == rhs.expandedTools.contains(rhs.item.id)
    }

    public var body: some View {
        switch item.type {
        case .reasoning:
            AgentChatReasoningRow(item: item, expandedIDs: $expandedReasoning)
                .equatable()
                .accessibilityIdentifier("bots.desk.thought.\(item.id)")
        case .assistantMessage:
            if !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if item.state == .streaming {
                    AgentMessageMarkdownView(text: item.body, cacheResults: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("bots.desk.role.assistant")
                } else {
                    AgentChatAssistantReply(text: item.body)
                }
            }
        case .plan:
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("PLAN").font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                    .foregroundColor(DS.Palette.accent)
                AgentMessageMarkdownView(text: item.body)
                    .foregroundColor(DS.Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tool, .commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall,
                .collabToolCall, .webSearch, .review, .contextCompaction, .error, .imageView:
            AgentChatLiveToolRow(item: item, expandedIDs: $expandedTools)
                .equatable()
        }
    }
}

// MARK: - Turn

public struct AgentChatLiveTurnView: View, Equatable {
    public let turn: AssistantTurnSnapshot
    public let live: Bool
    public let hideAssistantOutput: Bool
    /// False omits the "Work so far" heading for a continuation segment.
    /// Used after an interleaved bot message so the chat keeps appending
    /// instead of stacking headers.
    public var showsWorkHeader: Bool
    /// Simple verbosity hides work rows but keeps available live status.
    public var hidesWork: Bool
    public var renderFinal: ((String) -> AnyView)?
    public var afterWork: AnyView?

    @State private var expandedReasoning: Set<String> = []
    @State private var expandedTools: Set<String> = []
    @State private var expandedToolGroups: Set<String> = []
    /// AA-23: how many of the older (folded) work blocks the user has revealed.
    @State private var earlierWorkReveal = 0

    public init(
        turn: AssistantTurnSnapshot,
        live: Bool,
        hideAssistantOutput: Bool = false,
        showsWorkHeader: Bool = true,
        hidesWork: Bool = false,
        renderFinal: ((String) -> AnyView)? = nil,
        afterWork: AnyView? = nil
    ) {
        self.turn = turn
        self.live = live
        self.hideAssistantOutput = hideAssistantOutput
        self.showsWorkHeader = showsWorkHeader
        self.hidesWork = hidesWork
        self.renderFinal = renderFinal
        self.afterWork = afterWork
    }

    public static func == (lhs: AgentChatLiveTurnView, rhs: AgentChatLiveTurnView) -> Bool {
        lhs.turn.turnId == rhs.turn.turnId
            && lhs.live == rhs.live
            && lhs.hideAssistantOutput == rhs.hideAssistantOutput
            && lhs.showsWorkHeader == rhs.showsWorkHeader
            && lhs.hidesWork == rhs.hidesWork
            && lhs.turn.finished == rhs.turn.finished
            && lhs.turn.items.count == rhs.turn.items.count
            && lhs.turn.finalAssistantMessage == rhs.turn.finalAssistantMessage
            && lhs.turn.items.last?.progress == rhs.turn.items.last?.progress
            && lhs.turn.items.last.map { AgentChatLiveTurnChrome.liveTextFingerprint($0.body) }
                == rhs.turn.items.last.map { AgentChatLiveTurnChrome.liveTextFingerprint($0.body) }
            && lhs.turn.items.last.map { AgentChatLiveTurnChrome.liveTextFingerprint($0.output) }
                == rhs.turn.items.last.map { AgentChatLiveTurnChrome.liveTextFingerprint($0.output) }
            && liveThoughtFingerprint(lhs.turn) == liveThoughtFingerprint(rhs.turn)
            && liveToolActivityFingerprint(lhs.turn) == liveToolActivityFingerprint(rhs.turn)
            && (lhs.renderFinal == nil) == (rhs.renderFinal == nil)
            && (lhs.afterWork == nil) == (rhs.afterWork == nil)
    }

    public var body: some View {
        let composition = AgentChatLiveTurnChrome.compose(turn)
        let blocks = AgentChatLiveTurnChrome.workBlocks(from: composition.activity)
        let slice = AgentChatLiveTurnChrome.visibleWorkBlocks(blocks, revealCount: earlierWorkReveal)
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            if hidesWork {
                hiddenWorkSection(activity: composition.activity)
            } else if !composition.activity.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    if showsWorkHeader {
                        HStack(spacing: DS.Space.sm) {
                            if live {
                                Image(systemName: "circle.dotted")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(DS.Palette.textTertiary)
                            }
                            Text(AgentChatLiveTurnChrome.completedWorkLabel(
                                turn,
                                live: live,
                                workBlockCount: blocks.count
                            ))
                            .font(DS.Font.body.weight(.medium))
                            .foregroundColor(DS.Palette.textTertiary)
                            Spacer(minLength: 0)
                        }
                        .accessibilityIdentifier(
                            live ? "agent.liveWork.\(turn.turnId)" : "agent.completedWork.\(turn.turnId)"
                        )
                    }
                    if slice.hiddenCount > 0 {
                        Button {
                            let hiddenBase = max(0, blocks.count - AgentWorkDisclosureLayout.expandedPaintWindow)
                            earlierWorkReveal = AgentWorkDisclosureLayout.advancedRevealCount(
                                current: earlierWorkReveal,
                                hiddenBase: hiddenBase
                            )
                        } label: {
                            Text("Show earlier steps (\(slice.hiddenCount) hidden)")
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent.work.revealEarlier.\(turn.turnId)")
                    }
                    ForEach(slice.rows) { block in
                        AgentChatWorkBlockView(
                            block: block,
                            expandedReasoning: $expandedReasoning,
                            expandedTools: $expandedTools,
                            expandedToolGroups: $expandedToolGroups
                        )
                    }
                    if live, let thought = AgentChatLiveTurnChrome.liveThought(turn) {
                        AgentChatLiveThinkingLine(turnId: turn.turnId, text: thought)
                    }
                }
                .padding(.leading, showsWorkHeader ? 0 : DS.Space.md)
                .accessibilityIdentifier("agent.work.timeline.\(turn.turnId)")
            }
            if let afterWork {
                afterWork
            }
            if !hideAssistantOutput {
                ForEach(composition.outside) { item in
                    AgentChatLiveItemRow(
                        item: item,
                        expandedReasoning: $expandedReasoning,
                        expandedTools: $expandedTools
                    )
                    .equatable()
                }
                if AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn, composition: composition),
                   let final = turn.finalAssistantMessage {
                    if let renderFinal {
                        renderFinal(final)
                    } else {
                        AgentChatAssistantReply(text: final, showsImages: turn.finished)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.desk.liveTurn.\(turn.turnId)")
    }

    static func liveThoughtFingerprint(_ turn: AssistantTurnSnapshot) -> UInt64? {
        AgentChatLiveTurnChrome.liveThought(turn).map { AgentChatLiveTurnChrome.liveTextFingerprint($0) }
    }

    static func liveToolActivityFingerprint(_ turn: AssistantTurnSnapshot) -> UInt64? {
        AgentChatLiveTurnChrome.liveToolActivity(turn).map { AgentChatLiveTurnChrome.liveTextFingerprint($0) }
    }

    /// Simple verbosity keeps live status and the turn's errors, not work rows.
    /// Hidden work still owns up to its failures (iOS parity): an error the
    /// user cannot see would read as a silent success.
    @ViewBuilder
    private func hiddenWorkSection(activity: [AssistantItem]) -> some View {
        if live && !turn.finished && showsWorkHeader {
            if let thought = AgentChatLiveTurnChrome.liveThought(turn) {
                AgentChatLiveThinkingLine(turnId: turn.turnId, text: thought)
            }
            if let activity = AgentChatLiveTurnChrome.liveToolActivity(turn) {
                AgentChatHiddenWorkStatus(turn: turn, label: activity)
            } else if AgentChatLiveTurnChrome.liveThought(turn) == nil {
                AgentChatHiddenWorkStatus(turn: turn)
            }
        }
        ForEach(AgentChatLiveTurnChrome.visibleErrors(in: activity)) { item in
            AgentChatLiveItemRow(
                item: item,
                expandedReasoning: $expandedReasoning,
                expandedTools: $expandedTools
            )
            .equatable()
        }
    }
}

/// Live "thinking" line: the model's current thought, tail only.
public struct AgentChatLiveThinkingLine: View {
    public let turnId: String
    public let text: String

    public init(turnId: String, text: String) {
        self.turnId = turnId
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Thinking…")
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.liveThinking.\(turnId)")
    }
}

/// The only trace of a hidden-work turn while it runs: the Bot is working,
/// with no command, edit or tool detail.
struct AgentChatHiddenWorkStatus: View {
    let turn: AssistantTurnSnapshot
    var label = "Working…"

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            Text(label)
                .font(DS.Font.body.weight(.medium))
                .foregroundColor(DS.Palette.textTertiary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.hiddenWork.\(turn.turnId)")
    }
}

// MARK: - Working status

/// Window between the user bubble and a real run — same as Agent App Loading….
public struct AgentChatLoadingStatusStrip: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading")
                Text("Loading…")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("agent.loading.status")
            }
            Rectangle()
                .fill(DS.Palette.line)
                .frame(height: DS.Border.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.desk.loading")
    }
}

public struct AgentChatWorkingStatusStrip: View {
    public let startedAt: Date
    public let isStopping: Bool
    public let context: AgentChatWorkingContext?
    public let hold: AgentBackgroundHoldSummary?
    public let distill: DistillLiveStatus?
    public let contextTokens: Int?
    public let runningTools: [AssistantItem]
    public let onStop: () -> Void
    @State private var toolsExpanded = true
    @State private var expandedToolIDs: Set<String> = []

    public init(
        startedAt: Date,
        isStopping: Bool,
        context: AgentChatWorkingContext? = nil,
        hold: AgentBackgroundHoldSummary? = nil,
        distill: DistillLiveStatus? = nil,
        contextTokens: Int? = nil,
        runningTools: [AssistantItem] = [],
        onStop: @escaping () -> Void
    ) {
        self.distill = distill
        self.contextTokens = contextTokens
        self.runningTools = runningTools
        self.startedAt = startedAt
        self.isStopping = isStopping
        self.context = context
        self.hold = hold
        self.onStop = onStop
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            TimelineView(AgentChatElapsedTickSchedule(start: startedAt)) { timeline in
                let seconds = max(0, Int(timeline.date.timeIntervalSince(startedAt)))
                let seed = UInt64(max(0, startedAt.timeIntervalSince1970 * 1000))
                let showingHold = hold.map { !$0.isEmpty } ?? false
                HStack(alignment: .center, spacing: DS.Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(showingHold ? "Holding on background work" : "Running")
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        statusLine(seconds: seconds, seed: seed, now: timeline.date)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel(distill?.operationHeadline(now: timeline.date) ?? AgentChatWorkingCopy.accessibilityLabel(
                            context: context,
                            elapsedSeconds: seconds,
                            hold: hold
                        ))
                        .accessibilityIdentifier("agent.workingStatus")
                        if let extra = hold?.extraDescriptionsLine {
                            Text(extra)
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .accessibilityHidden(true)
                                .accessibilityIdentifier("agent.workingStatus.holdDetail")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(hold?.helpText ?? AgentChatWorkingCopy.accessibilityLabel(
                        context: context,
                        elapsedSeconds: seconds,
                        hold: hold
                    ))
                    if distill != nil, let tokens = contextTokens, tokens > 0 {
                        Text("↓\(DistillLiveStatus.formatTokens(tokens))")
                            .font(DS.Font.caption.monospacedDigit())
                            .foregroundColor(DS.Palette.textTertiary)
                            .accessibilityIdentifier("agent.workingStatus.tokens")
                    }
                    Button(isStopping ? "Stopping… (click to force)" : "Stop", action: onStop)
                        .buttonStyle(.plain)
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.danger)
                        .help(stopHelp(showingHold: showingHold))
                        .accessibilityIdentifier("agent.working.stop")
                }
            }
            if !runningTools.isEmpty {
                DisclosureGroup(isExpanded: $toolsExpanded) {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        ForEach(runningTools) { item in
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                TimelineView(.periodic(from: .now, by: 1)) { tick in
                                    let elapsed = max(0, Int(tick.date.timeIntervalSince1970 - Double(item.startedAtMs) / 1_000))
                                    Text("Running for \(elapsed)s")
                                        .font(DS.Font.caption.monospacedDigit())
                                        .foregroundColor(DS.Palette.textTertiary)
                                }
                                AgentChatLiveToolRow(item: item, expandedIDs: $expandedToolIDs)
                                    .equatable()
                                if let output = AgentChatLiveTurnChrome.recentToolOutput(item) {
                                    Text("Recent output (up to 2,000 characters)")
                                        .font(DS.Font.caption)
                                        .foregroundColor(DS.Palette.textTertiary)
                                    ScrollView {
                                        Text(output)
                                            .font(DS.Font.monoSmall)
                                            .foregroundColor(DS.Palette.textSecondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(maxHeight: 120)
                                    .defaultScrollAnchor(.bottom)
                                    .accessibilityIdentifier("agent.workingStatus.output.\(item.id)")
                                }
                                Text(item.output?.isEmpty == false
                                     ? "Expand tool for command and output details."
                                     : "No output received. A quiet command may still be running.")
                                    .font(DS.Font.caption)
                                    .foregroundColor(DS.Palette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, DS.Space.sm)
                } label: {
                    Text("Active tools (\(runningTools.count))")
                        .font(DS.Font.captionStrong)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                .accessibilityIdentifier("agent.workingStatus.tools")
            }
            if let distill, distill.goal != nil || !distill.scheduledTasks.isEmpty {
                goalLoopLine(distill)
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLine(seconds: Int, seed: UInt64, now: Date) -> Text {
        let base = AgentChatWorkingCopy.statusLabel(
            context: context,
            elapsedSeconds: seconds,
            seed: seed,
            hold: hold
        )
        guard let distill else { return Text(base) }
        var line = Text(distill.operationHeadline(now: now) ?? distill.headline.map { h in
            let secs = distill.headlineSince.map { max(0, Int(now.timeIntervalSince($0))) }
            return secs.map { "\(h) \($0)s" } ?? h
        } ?? distill.goalHeadline ?? base)
        if let meta = distill.modelEffortText {
            line = line + Text(" · \(meta)").foregroundColor(DS.Palette.success)
        }
        return line
    }

    private func goalLoopLine(_ distill: DistillLiveStatus) -> some View {
        var parts: [String] = []
        if let goal = distill.goal {
            parts.append("Goal \(goal.status.replacingOccurrences(of: "_", with: " ")) · \(goal.tokensText) tokens")
        }
        if !distill.scheduledTasks.isEmpty {
            parts.append("Loops \(distill.scheduledTasks.count)")
        }
        return Text(parts.joined(separator: " · "))
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityIdentifier("agent.workingStatus.goalLoops")
    }

    private func stopHelp(showingHold: Bool) -> String {
        if isStopping {
            return "Still stopping — click again to force-stop the provider"
        }
        if showingHold {
            return "Stop the agent and any background shells or agents holding this run (Esc)"
        }
        return "Stop running agent (press Esc to interrupt)"
    }
}

/// 1s cadence for the first minute, 5s after — same as Agent App workingStatus.
/// Perf CH-12: honours `mode == .lowFrequency` (SwiftUI passes it while the
/// view is occluded / its window is minimized) by pinning the 5s cadence, so
/// hidden working strips are not a steady 1s wake-up source.
struct AgentChatElapsedTickSchedule: TimelineSchedule {
    let start: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let current = next
            let elapsed = current.timeIntervalSince(start)
            let step: TimeInterval = (elapsed < 60 && mode != .lowFrequency) ? 1 : 5
            next = current.addingTimeInterval(step)
            return current
        }
    }
}
