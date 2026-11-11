import Foundation
import Combine
import CoreModel
import Surfaces

/// Keeps both live composer fields off the Desk view model that owns transcript
/// and replay state. Cursor movement is part of typing and must not republish
/// the enclosing Desk body either.
@MainActor
public final class BotsComposerState: ObservableObject {
    @Published public var text = ""
    @Published public var cursorOffset: Int? = nil
}

/// Maps a linked Agent run onto Bot Desk / Attention so a teammate turn
/// does not stay stuck on "Working…".
enum BotsDeskFollowThrough {
    static func conversationState(
        for status: AgentRunStatus,
        terminalReason: String? = nil
    ) -> BotAttentionState {
        switch status {
        case .pending, .running:
            return .working
        case .completed:
            return .unreadActivity
        case .failed, .interrupted:
            return .needsAttention
        case .cancelled:
            if terminalReason == "userStop" { return .none }
            return .needsAttention
        }
    }

    /// A completed turn on the open Desk is already being read — do not badge it Unread.
    static func conversationState(
        for status: AgentRunStatus,
        viewingDesk: Bool,
        terminalReason: String? = nil
    ) -> BotAttentionState {
        let state = conversationState(for: status, terminalReason: terminalReason)
        if viewingDesk && state == .unreadActivity { return .none }
        return state
    }

    static func attentionKind(
        for status: AgentRunStatus,
        terminalReason: String? = nil
    ) -> BotAttentionItemKind? {
        switch status {
        case .pending, .running, .completed:
            return nil
        case .failed, .interrupted:
            return .blocked
        case .cancelled:
            if terminalReason == "userStop" { return nil }
            return .blocked
        }
    }

    static func attentionTitle(for status: AgentRunStatus, terminalReason: String? = nil) -> String {
        if status == .cancelled && terminalReason == "userStop" { return L("Stopped by you") }
        return status == .failed ? L("Bot run failed") : L("Bot run interrupted")
    }

    static let workingPlaceholder = L("Working…")
    static let noRouterPlaceholder =
        L("This Bot could not start. Check its configuration, then send your request again.")

    static func visibleDeskMessages(
        cached: [BotDeskMessage],
        persisted: [BotDeskMessage]
    ) -> [BotDeskMessage] {
        let persistedHasResult = persisted.contains { message in
            message.role == .assistant &&
            message.text != workingPlaceholder &&
            message.text != noRouterPlaceholder
        }
        if persistedHasResult { return persisted }
        if persisted.isEmpty { return cached }
        return persisted
    }

    /// Persist stores the provider envelope; the desk must show the teammate line.
    static func displayUserText(from persisted: String) -> String {
        let marker = "User request:"
        guard let range = persisted.range(of: marker) else { return persisted }
        return persisted[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func workLogRows(
        for run: AgentRun?,
        mode: AgentPermissionMode = .supervised
    ) -> [BotDeskWorkLogRow] {
        guard let run else { return [] }
        return [workLogRow(for: run, mode: mode)]
    }

    static func workLogRow(
        for run: AgentRun,
        mode: AgentPermissionMode = .supervised
    ) -> BotDeskWorkLogRow {
        BotDeskWorkLogRow(
            id: run.id.value,
            title: L("%1$@ run", mode.displayName),
            detail: workLogDetail(provider: run.provider, model: run.model),
            statusLabel: workLogStatusLabel(for: run.status),
            createdAt: run.finishedAt ?? run.startedAt,
            runID: run.id
        )
    }

    static func workLogDetail(provider: AgentProvider, model: String) -> String {
        let route: String
        switch provider {
        case .claude: route = "Claude"
        case .codex: route = "Codex"
        case .grok: route = "Grok"
        case .distill: route = "Distill"
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return route }
        return "\(route) · \(trimmed)"
    }

    static func workLogStatusLabel(for status: AgentRunStatus) -> String {
        switch status {
        case .pending, .running:
            return "Working"
        case .completed:
            return L("Done")
        case .failed:
            return L("Failed")
        case .interrupted:
            return L("Interrupted")
        case .cancelled:
            return L("Cancelled")
        }
    }

    /// Messages stay the conversation; a work-log row appears only when a
    /// linked Agent run exists. Same-timestamp work-log sits between You and
    /// the assistant so it reads as the turn's activity, not a fake Desktop.
    ///
    /// When the linked thread has live-turn chrome (Thinking / Work so far),
    /// hide the generic Supervised-run card and the Working… placeholder so
    /// Desk matches Agent App: user → work disclosure → final markdown.
    static func timeline(
        messages: [BotDeskMessage],
        workLog: [BotDeskWorkLogRow],
        turns: [AssistantTurnSnapshot] = [],
        hideWorkLog: Bool = false,
        hideWorkingPlaceholder: Bool = false
    ) -> [BotDeskTimelineItem] {
        let visibleMessages = messages.filter { message in
            guard message.role == .assistant else { return true }
            if hideWorkingPlaceholder, message.text == workingPlaceholder { return false }
            if AgentChatLiveTurnChrome.messageDuplicatesTurn(message.text, turns: turns) {
                return false
            }
            return true
        }
        let logs = hideWorkLog ? [] : workLog
        let visibleTurns = turns.filter { turn in
            let composition = AgentChatLiveTurnChrome.compose(turn)
            return !composition.activity.isEmpty
                || AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn)
                || turn.items.contains {
                    $0.type == .assistantMessage
                        && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }
        var previousNormalizedFinals = Set<String>()
        previousNormalizedFinals.reserveCapacity(visibleTurns.count)
        var liveItems: [BotDeskTimelineItem] = []
        liveItems.reserveCapacity(visibleTurns.count)
        for turn in visibleTurns.sorted(
            by: { AgentChatLiveTurnChrome.turnSortDate($0) < AgentChatLiveTurnChrome.turnSortDate($1) }
        ) {
            let hide = AgentChatLiveTurnChrome.shouldHideAssistantOutput(
                turn,
                previousNormalizedFinals: previousNormalizedFinals
            )
            AgentChatLiveTurnChrome.insertNormalizedAssistantFinals(
                from: turn,
                into: &previousNormalizedFinals
            )
            liveItems.append(.liveTurn(turn, hideAssistantOutput: hide))
        }
        return interleavingTurnSegments(composeConversationOrder(
            messages: visibleMessages,
            workLog: logs,
            liveTurns: liveItems
        ))
    }

    /// Keep the current streaming turn and every later chronological row out
    /// of LazyVStack. This matches Agent App's history/live-tail layout split.
    static func splitLiveTail(
        _ items: [BotDeskTimelineItem],
        latestLiveTurnID: String?
    ) -> (history: [BotDeskTimelineItem], liveTail: [BotDeskTimelineItem]) {
        guard let latestLiveTurnID,
              let index = items.firstIndex(where: { $0.turnID == latestLiveTurnID }) else {
            return (items, [])
        }
        return (
            Array(items.prefix(index)),
            Array(items.suffix(from: index))
        )
    }

    /// Chat flow: weave each turn with the peer rows (Mentions/From bubbles,
    /// waiting indicators) that arrived mid-turn so desk chat appends in
    /// arrival order. Turns without interleaving boundaries pass through
    /// unchanged, so plain conversations paint exactly as before.
    static func interleavingTurnSegments(_ items: [BotDeskTimelineItem]) -> [BotDeskTimelineItem] {
        var out: [BotDeskTimelineItem] = []
        out.reserveCapacity(items.count)
        var index = 0
        while index < items.count {
            guard case .liveTurn(let turn, let hideAssistantOutput) = items[index] else {
                out.append(items[index])
                index += 1
                continue
            }
            var following: [AgentChatTurnSegmentation.FollowingRow<BotDeskTimelineItem>] = []
            var next = index + 1
            var stopped = false
            scan: while next < items.count {
                switch items[next] {
                case .message(let message):
                    // Only peer chrome interleaves; a plain user prompt or
                    // unattributed assistant reply ends boundary collection.
                    let can = !stopped && message.peer != nil
                    if !can { stopped = true }
                    following.append(AgentChatTurnSegmentation.FollowingRow(
                        timeMs: Int64(message.createdAt.timeIntervalSince1970 * 1000),
                        canInterleave: can,
                        row: items[next]
                    ))
                case .workLog(let row):
                    stopped = true
                    following.append(AgentChatTurnSegmentation.FollowingRow(
                        timeMs: Int64(row.createdAt.timeIntervalSince1970 * 1000),
                        canInterleave: false,
                        row: items[next]
                    ))
                case .liveTurn, .liveTurnSegment:
                    break scan
                }
                next += 1
            }
            if let woven = AgentChatTurnSegmentation.interleaved(turn: turn, following: following) {
                for element in woven {
                    switch element {
                    case .segment(let segment):
                        out.append(.liveTurnSegment(
                            segment,
                            hideAssistantOutput: segment.isLast ? hideAssistantOutput : false
                        ))
                    case .row(let item):
                        out.append(item)
                    }
                }
            } else {
                out.append(items[index])
                for item in following { out.append(item.row) }
            }
            index = next
        }
        return out
    }

    /// User bubble, then that turn's work, then the answer — never a pile of
    /// user bubbles followed by every Worked row at the bottom.
    static func composeConversationOrder(
        messages: [BotDeskMessage],
        workLog: [BotDeskWorkLogRow],
        liveTurns: [BotDeskTimelineItem]
    ) -> [BotDeskTimelineItem] {
        var users: [BotDeskMessage] = []
        var assistants: [BotDeskMessage] = []
        users.reserveCapacity(messages.count)
        assistants.reserveCapacity(messages.count)
        for message in messages {
            if message.role == .user { users.append(message) } else { assistants.append(message) }
        }
        users.sort { $0.createdAt < $1.createdAt }
        assistants.sort { $0.createdAt < $1.createdAt }
        let logs = workLog.sorted { $0.createdAt < $1.createdAt }
        let turns = liveTurns.sorted { $0.createdAt < $1.createdAt }
        if users.isEmpty {
            return (assistants.map(BotDeskTimelineItem.message)
                + logs.map(BotDeskTimelineItem.workLog)
                + turns)
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.stableOrder < rhs.stableOrder
                }
        }
        var result: [BotDeskTimelineItem] = []
        var turnIndex = 0
        var assistantIndex = 0
        var logIndex = 0
        func appendDue(before limit: Date) {
            while true {
                var next: BotDeskTimelineItem?
                if turnIndex < turns.count, turns[turnIndex].createdAt < limit {
                    next = turns[turnIndex]
                }
                if assistantIndex < assistants.count, assistants[assistantIndex].createdAt < limit {
                    let item = BotDeskTimelineItem.message(assistants[assistantIndex])
                    if next == nil || item.createdAt < next!.createdAt
                        || (item.createdAt == next!.createdAt && item.stableOrder < next!.stableOrder) {
                        next = item
                    }
                }
                if logIndex < logs.count, logs[logIndex].createdAt < limit {
                    let item = BotDeskTimelineItem.workLog(logs[logIndex])
                    if next == nil || item.createdAt < next!.createdAt
                        || (item.createdAt == next!.createdAt && item.stableOrder < next!.stableOrder) {
                        next = item
                    }
                }
                guard let item = next else { return }
                result.append(item)
                switch item {
                case .liveTurn, .liveTurnSegment: turnIndex += 1
                case .message: assistantIndex += 1
                case .workLog: logIndex += 1
                }
            }
        }
        for (index, user) in users.enumerated() {
            appendDue(before: user.createdAt)
            result.append(.message(user))
            let nextUserDate = index + 1 < users.count ? users[index + 1].createdAt : Date.distantFuture
            appendDue(before: nextUserDate)
        }
        appendDue(before: Date.distantFuture)
        return result
    }

    static func isTerminal(_ status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .pending, .running:
            return false
        }
    }

    static func composeRunPrompt(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memoryFiles: [BotMemoryFileText] = [],
        skills: [BotSkillBinding] = [],
        ownedSkills: [BotOwnedSkillText] = [],
        routines: [BotRoutine] = [],
        workspace: BotWorkspaceHonesty? = nil,
        browser: BotBrowserTarget? = nil
    ) -> String {
        BotBrainCompiler.composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: userText,
            memoryFiles: memoryFiles,
            skills: skills,
            ownedSkills: ownedSkills,
            routines: routines,
            workspace: workspace,
            browser: browser
        )
    }
}
