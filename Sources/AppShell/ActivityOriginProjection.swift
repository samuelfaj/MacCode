import Foundation
import RemoteCodeTreaty
import CoreModel
import Persistence

struct ActivityOriginSnapshot: Sendable {
    let labelsByRunID: [String: String]
    /// Lowercased thread id → the bot conversation that owns it, so a bot thread's rows open
    /// its Desk instead of a workspace it never had. Group-member conversations are not
    /// listed here; the router's destination check finds them by thread at open time.
    let botLinksByThreadID: [String: (botID: UUID, conversationID: UUID)]
    let botRequests: [AgentActivityItem]
    let botAttentionIDs: Set<String>
    let botFailureIDsByRunID: [String: [BotAttentionItemID]]
    let resolvedBotFailureRunIDs: Set<String>
    let scheduledOccurrences: [AgentActivityItem]
}

enum ActivityOriginProjection {
    static func load(db: SQLiteDB, threads: [AgentThread]) throws -> ActivityOriginSnapshot {
        let threadByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id.value.uuidString.lowercased(), $0) })
        var labels: [String: String] = [:]
        let taskRuns = try db.performSync { database -> [(String, String)] in
            let statement = try database.prepare("""
                SELECT r.agent_run_id, t.title
                FROM scheduled_task_runs r
                JOIN scheduled_tasks t ON t.id = r.task_id
                WHERE r.agent_run_id IS NOT NULL;
                """)
            defer { statement.reset() }
            var rows: [(String, String)] = []
            while try statement.step() {
                if let runID = statement.columnText(0), let title = statement.columnText(1) {
                    rows.append((runID, title))
                }
            }
            return rows
        }
        for (runID, title) in taskRuns {
            if let id = UUID(uuidString: runID) { labels[id.uuidString] = L("Scheduled task: %1$@", PetAttentionRedactor.safeContextLabel(title) ?? L("Task")) }
        }

        let botStore = BotStore(db: db)
        // One pass: each call re-runs the correlated attention subqueries over every conversation.
        let conversations = try botStore.listConversations(attentionStates: [.none, .working, .unreadActivity, .needsAttention])
        let contextLabels = Dictionary(conversations.compactMap { conversation -> (String, String)? in
            guard let threadID = conversation.linkedAgentThreadID,
                  threadByID[threadID.value.uuidString.lowercased()] != nil else { return nil }
            return (threadID.value.uuidString.lowercased(), L("Bot conversation: %1$@", conversation.title))
        }, uniquingKeysWith: { first, _ in first })
        let botLinks = Dictionary(conversations.compactMap { conversation -> (String, (botID: UUID, conversationID: UUID))? in
            guard let threadID = conversation.linkedAgentThreadID?.value.uuidString.lowercased(),
                  threadByID[threadID] != nil else { return nil }
            return (threadID, (conversation.botID.value, conversation.id.value))
        }, uniquingKeysWith: { first, _ in first })
        let runThreads = try db.performSync { database -> [(id: String, threadID: String, status: String, startedAt: Date, reason: String?)] in
            let statement = try database.prepare("SELECT id, thread_id, status, started_at, terminal_reason FROM agent_runs ORDER BY started_at DESC, rowid DESC;")
            defer { statement.reset() }
            var rows: [(id: String, threadID: String, status: String, startedAt: Date, reason: String?)] = []
            while try statement.step() {
                if let runID = statement.columnText(0), let threadID = statement.columnText(1),
                   let status = statement.columnText(2), let startedAt = statement.columnText(3).flatMap(Self.parseDate) {
                    rows.append((runID, threadID.lowercased(), status, startedAt, statement.columnText(4)))
                }
            }
            return rows
        }
        for run in runThreads where labels[run.id] == nil {
            if let label = contextLabels[run.threadID] { labels[run.id] = label }
        }

        let allAttention = try botStore.listAttention(includeAcknowledged: true)
        let openAttention = try botStore.listAttention()
        let openIDs = Set(openAttention.map(\.id))
        let conversationByID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let latestRunByThread = Dictionary(runThreads.map { ($0.threadID, $0) }, uniquingKeysWith: { first, _ in first })
        var failureIDs: [String: [BotAttentionItemID]] = [:]
        for item in allAttention where item.kind == .blocked {
            guard let conversation = item.conversationID.flatMap({ conversationByID[$0] }),
                  let threadID = conversation.linkedAgentThreadID?.description.lowercased(),
                  let run = latestRunByThread[threadID], item.createdAt >= run.startedAt,
                  ["failed", "interrupted", "cancelled"].contains(run.status), run.reason != "userStop" else { continue }
            failureIDs[run.id, default: []].append(item.id)
        }
        let canonicalFailureIDs = Set(failureIDs.values.flatMap { $0 })
        let resolvedFailures = Set(failureIDs.compactMap { runID, ids in ids.allSatisfy { !openIDs.contains($0) } ? runID : nil })
        let requests = openAttention.compactMap { item -> AgentActivityItem? in
            // A Bot failure and its Agent run describe one decision. Keep the
            // run as the canonical row so dismissing it cannot expose a duplicate.
            guard !canonicalFailureIDs.contains(item.id) else { return nil }
            let state: AgentActivityState
            switch item.kind {
            case .question: state = .waitingAnswer
            case .approval: state = .waitingApproval
            case .blocked: state = .failed
            case .handoff, .unknownEffect: state = .needsYou
            case .unread: return nil
            }
            let conversation = item.conversationID.flatMap { id in conversations.first(where: { $0.id == id }) }
            let thread = conversation?.linkedAgentThreadID.flatMap { threadByID[$0.value.uuidString.lowercased()] }
            return AgentActivityItem(
                id: "bot-attention:\(item.id.value.uuidString.lowercased())",
                kind: .request,
                workspaceID: thread?.workspaceId?.value,
                threadID: thread?.id.value,
                state: state,
                title: item.kind.activityTitle,
                summary: item.kind.resolutionHint,
                occurredAt: item.createdAt,
                needsAction: true,
                botID: item.botID.value,
                conversationID: item.conversationID?.value,
                originLabel: conversation.flatMap { PetAttentionRedactor.safeContextLabel($0.title) }.map { L("Bot conversation: %1$@", $0) }
            )
        }
        let scheduledState = try db.performSync { database -> [String: (Date?, Date?)] in
            let statement = try database.prepare("SELECT item_id, viewed_at, acknowledged_at FROM activity_notification_state WHERE item_id LIKE 'activity:scheduled-occurrence:%';")
            defer { statement.reset() }
            var result: [String: (Date?, Date?)] = [:]
            while try statement.step() {
                guard let key = statement.columnText(0) else { continue }
                result[String(key.dropFirst("activity:".count))] = (statement.columnText(1).flatMap(Self.parseDate), statement.columnText(2).flatMap(Self.parseDate))
            }
            return result
        }
        let scheduledOccurrences = try db.performSync { database -> [AgentActivityItem] in
            let statement = try database.prepare("""
                SELECT r.id, r.status, r.queued_at, r.started_at, r.finished_at, r.error_summary,
                       t.id, t.title, t.workspace_id, t.provider,
                       NOT EXISTS (
                           SELECT 1 FROM scheduled_task_runs newer
                           WHERE newer.task_id = r.task_id
                             AND (julianday(newer.queued_at) > julianday(r.queued_at)
                                  OR (newer.queued_at = r.queued_at AND newer.rowid > r.rowid))
                       )
                FROM scheduled_task_runs r
                JOIN scheduled_tasks t ON t.id = r.task_id
                WHERE r.agent_run_id IS NULL
                ORDER BY COALESCE(r.finished_at, r.started_at, r.queued_at) DESC;
                """)
            defer { statement.reset() }
            func date(_ index: Int32) -> Date? {
                guard let raw = statement.columnText(index) else { return nil }
                return Self.parseDate(raw)
            }
            var items: [AgentActivityItem] = []
            while try statement.step() {
                guard let id = statement.columnText(0), let rawStatus = statement.columnText(1),
                      let queuedAt = date(2), let workspace = statement.columnText(8).flatMap(UUID.init(uuidString:)) else { continue }
                let state: AgentActivityState
                switch rawStatus {
                case "queued": state = .queued
                case "running": state = .running
                case "completed": state = .completed
                case "failed": state = .failed
                case "cancelled": state = .stopped
                default: continue
                }
                let finishedAt = date(4)
                let itemID = "scheduled-occurrence:\(id)"
                let storedState = scheduledState[itemID]
                items.append(AgentActivityItem(
                    id: itemID, kind: .operation, workspaceID: workspace,
                    state: state, title: PetAttentionRedactor.safeContextLabel(statement.columnText(7) ?? L("Scheduled task")) ?? L("Scheduled task"),
                    provider: statement.columnText(9), summary: statement.columnText(5),
                    occurredAt: finishedAt ?? date(3) ?? queuedAt, startedAt: date(3), finishedAt: finishedAt,
                    viewedAt: storedState?.0, attentionAcknowledgedAt: storedState?.1,
                    needsAction: state == .failed && statement.columnInt64(10) != 0 && storedState?.1 == nil, originLabel: L("Scheduled task")
                ))
            }
            return items
        }
        let attentionIDs = Set(allAttention.map { "bot-attention:\($0.id.value.uuidString.lowercased())" })
        return ActivityOriginSnapshot(labelsByRunID: labels, botLinksByThreadID: botLinks, botRequests: requests,
                                      botAttentionIDs: attentionIDs, botFailureIDsByRunID: failureIDs,
                                      resolvedBotFailureRunIDs: resolvedFailures, scheduledOccurrences: scheduledOccurrences)
    }

    // Shared and style-first: every scheduled occurrence parses three timestamps on each
    // Activity list, and ISO8601DateFormatter costs ~100 µs a parse.
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    private static func parseDate(_ raw: String) -> Date? {
        (try? plainStyle.parse(raw)) ?? (try? fractionalStyle.parse(raw))
            ?? fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}
