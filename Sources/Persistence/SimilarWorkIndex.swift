import CoreModel
import Foundation

/// Finds live runs and runs finished in the last day whose request reads like a new one.
/// Word overlap only (`DuplicateWorkDetector`); the result is a warning, never a gate.
public final class SimilarWorkIndex: @unchecked Sendable {
    public static let maxRows = 200

    private let db: SQLiteDB
    private let touchRepo: AgentRunFileTouchRepository
    private let liveRunIDs: (@Sendable () -> Set<AgentRunID>)?

    public init(db: SQLiteDB, liveRunIDs: (@Sendable () -> Set<AgentRunID>)? = nil) {
        self.db = db
        self.touchRepo = AgentRunFileTouchRepository(db: db)
        self.liveRunIDs = liveRunIDs
    }

    /// True when `threadId` has no run row yet, i.e. the run being started is its first.
    public func isFirstRun(ofThread threadId: AgentThreadID) throws -> Bool {
        try db.performSync { database in
            let statement = try database.prepare("SELECT 1 FROM agent_runs WHERE thread_id = ? COLLATE NOCASE LIMIT 1;")
            try statement.bind(1, threadId.value.uuidString)
            return try !statement.step()
        }
    }

    /// Workspace and Bot a thread belongs to; nil parts when it has none.
    public func scope(ofThread threadId: AgentThreadID) throws -> (workspaceID: String?, botID: String?) {
        try db.performSync { database in
            let id = threadId.value.uuidString
            let workspace = try database.prepare("SELECT workspace_id FROM agent_threads WHERE id = ? COLLATE NOCASE LIMIT 1;")
            try workspace.bind(1, id)
            let workspaceID = try workspace.step() ? workspace.columnText(0) : nil
            let bot = try database.prepare("SELECT bot_id FROM bot_conversations WHERE linked_agent_thread_id = ? COLLATE NOCASE LIMIT 1;")
            try bot.bind(1, id)
            let botID = try bot.step() ? bot.columnText(0) : nil
            return (workspaceID, botID)
        }
    }

    /// Similar work for a request, best match first. Candidates come from the same repository, the same workspace
    /// or any conversation of the same Bot; a nil scope is not searched. `excludingThread` is never a candidate.
    public func find(
        request: String,
        excludingThread: AgentThreadID?,
        repoCommonDir: String?,
        workspaceID: String?,
        botID: String?,
        now: Date = Date()
    ) throws -> [SimilarWork] {
        guard repoCommonDir != nil || workspaceID != nil || botID != nil else { return [] }
        let wanted = DuplicateWorkDetector.words(request)
        guard !wanted.isEmpty else { return [] }
        let live = liveRunIDs?()
        let cutoff = isoFractional.string(from: now.addingTimeInterval(-DuplicateWorkDetector.lookback))
        struct Row {
            let runID: AgentRunID, threadID: AgentThreadID, title: String, running: Bool
            let finishedAt: Date?, firstMessage: String?, summary: String?
        }
        let rows: [Row] = try db.performSync { database in
            let statement = try database.prepare("""
                SELECT r.id, r.thread_id, r.status, r.finished_at, t.title,
                       (SELECT substr(m.content, 1, 600) FROM agent_messages m
                         WHERE m.thread_id = r.thread_id AND m.role = 'user'
                         ORDER BY m.created_at ASC, m.rowid ASC LIMIT 1),
                       (SELECT substr(m.content, 1, 600) FROM agent_messages m
                         WHERE m.thread_id = r.thread_id AND m.role = 'assistant' AND length(m.content) > 0
                         ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1)
                FROM agent_runs r
                JOIN agent_threads t ON t.id = r.thread_id
                LEFT JOIN agent_run_repo_identity i ON i.run_id = r.id
                WHERE (? IS NULL OR r.thread_id <> ? COLLATE NOCASE)
                  AND (r.status IN ('pending', 'running') OR (r.status = 'completed' AND r.finished_at >= ?))
                  AND (
                    (? IS NOT NULL AND i.git_common_dir = ?)
                    OR (? IS NOT NULL AND t.workspace_id = ?)
                    OR (? IS NOT NULL AND r.thread_id COLLATE NOCASE IN (
                        SELECT linked_agent_thread_id FROM bot_conversations WHERE bot_id = ? COLLATE NOCASE))
                  )
                ORDER BY r.started_at DESC LIMIT \(Self.maxRows);
                """)
            let excluded = excludingThread?.value.uuidString
            var index: Int32 = 1
            func bind(_ value: String?) throws {
                if let value { try statement.bind(index, value) }
                index += 1
            }
            try bind(excluded); try bind(excluded)
            try bind(cutoff)
            try bind(repoCommonDir); try bind(repoCommonDir)
            try bind(workspaceID); try bind(workspaceID)
            try bind(botID); try bind(botID)
            var result: [Row] = []
            while try statement.step() {
                guard let runRaw = statement.columnText(0), let run = UUID(uuidString: runRaw),
                      let threadRaw = statement.columnText(1), let thread = UUID(uuidString: threadRaw),
                      let status = statement.columnText(2) else { continue }
                let running = status == "pending" || status == "running"
                result.append(Row(
                    runID: AgentRunID(run), threadID: AgentThreadID(thread), title: statement.columnText(4) ?? "",
                    running: running, finishedAt: statement.columnText(3).flatMap { isoFractional.date(from: $0) },
                    firstMessage: statement.columnText(5), summary: statement.columnText(6)
                ))
            }
            return result
        }
        // Newest run per thread; a stale `running` row the host no longer owns is not live work.
        var seen = Set<AgentThreadID>()
        var matches: [(row: Row, score: Double)] = []
        for row in rows where seen.insert(row.threadID).inserted {
            if row.running, !(live?.contains(row.runID) ?? true) { continue }
            let title = AgentThreadTitle.isPlaceholder(row.title) ? nil : row.title
            guard let score = DuplicateWorkDetector.score(request: request, candidateTitle: title, candidateRequest: row.firstMessage) else { continue }
            matches.append((row, score))
        }
        matches.sort { $0.score > $1.score }
        let top = Array(matches.prefix(ConcurrentWorkDirective.maxSimilar))
        let touches = try touchRepo.touches(runIds: top.map(\.row.runID))
        return top.map { match in
            let row = match.row
            let summary = row.running ? nil : row.summary.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            return SimilarWork(
                threadID: row.threadID,
                threadTitle: RunObjective.make(title: row.title, firstUserMessage: row.firstMessage),
                isRunning: row.running, finishedAt: row.finishedAt,
                files: (touches[row.runID] ?? []).prefix(ConcurrentWorkDirective.maxFilesPerRun).map(\.path),
                resultSummary: summary.map { String($0.prefix(ConcurrentWorkDirective.maxSummaryLength)) },
                score: match.score
            )
        }
    }
}
