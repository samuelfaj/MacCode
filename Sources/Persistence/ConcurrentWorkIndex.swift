import CoreModel
import Foundation

/// Read side of live per-run file touches: which other runs are working in the same repository
/// (every worktree shares one git common dir) and which files they are editing.
public final class ConcurrentWorkIndex: @unchecked Sendable {
    public static let maxEditingFiles = 20

    private let db: SQLiteDB
    private let touchRepo: AgentRunFileTouchRepository
    /// Runs the host still owns. Rows left `running` by a crash are not live; nil trusts the status column.
    private let liveRunIDs: (@Sendable () -> Set<AgentRunID>)?

    public init(db: SQLiteDB, liveRunIDs: (@Sendable () -> Set<AgentRunID>)? = nil) {
        self.db = db
        self.touchRepo = AgentRunFileTouchRepository(db: db)
        self.liveRunIDs = liveRunIDs
    }

    /// Live runs whose checkout shares `repoCommonDir`, oldest first, without `excludingRun`.
    public func liveRuns(repoCommonDir: String, excludingRun: AgentRunID? = nil) throws -> [ConcurrentRunSummary] {
        let live = liveRunIDs?()
        struct Row {
            let runID: AgentRunID, threadID: AgentThreadID, title: String, repoRoot: String
            let branch: String?, firstMessage: String?, botID: UUID?, botName: String?, startedAt: Date
        }
        let rows: [Row] = try db.performSync { database in
            let statement = try database.prepare("""
                SELECT r.id, r.thread_id, r.started_at, t.title, i.repo_root, i.branch,
                       (SELECT substr(m.content, 1, 600) FROM agent_messages m
                         WHERE m.thread_id = r.thread_id AND m.role = 'user'
                         ORDER BY m.created_at ASC, m.rowid ASC LIMIT 1),
                       b.id, b.name
                FROM agent_runs r
                JOIN agent_run_repo_identity i ON i.run_id = r.id
                JOIN agent_threads t ON t.id = r.thread_id
                LEFT JOIN bot_conversations c ON c.linked_agent_thread_id = r.thread_id COLLATE NOCASE
                LEFT JOIN bots b ON b.id = c.bot_id
                WHERE i.git_common_dir = ? AND r.status IN ('pending', 'running')
                GROUP BY r.id
                ORDER BY r.started_at ASC, r.id ASC;
                """)
            try statement.bind(1, repoCommonDir)
            var result: [Row] = []
            while try statement.step() {
                guard let runRaw = statement.columnText(0), let run = UUID(uuidString: runRaw),
                      let threadRaw = statement.columnText(1), let thread = UUID(uuidString: threadRaw),
                      let root = statement.columnText(4) else { continue }
                result.append(Row(
                    runID: AgentRunID(run), threadID: AgentThreadID(thread),
                    title: statement.columnText(3) ?? "", repoRoot: root, branch: statement.columnText(5),
                    firstMessage: statement.columnText(6), botID: statement.columnText(7).flatMap(UUID.init(uuidString:)),
                    botName: statement.columnText(8),
                    startedAt: statement.columnText(2).flatMap { isoFractional.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
                ))
            }
            return result
        }
        let candidates = rows.filter { $0.runID != excludingRun && (live?.contains($0.runID) ?? true) }
        let touches = try touchRepo.touches(runIds: candidates.map(\.runID))
        return candidates.map { row in
            ConcurrentRunSummary(
                runID: row.runID, threadID: row.threadID, threadTitle: row.title,
                botID: row.botID, botName: row.botName,
                objective: RunObjective.make(title: row.title, firstUserMessage: row.firstMessage),
                branch: row.branch, worktreePath: row.repoRoot,
                editingFiles: Array((touches[row.runID] ?? []).suffix(Self.maxEditingFiles)), startedAt: row.startedAt
            )
        }
    }

    /// Git common dir of a run's checkout; nil until the run's identity resolved or outside git.
    public func repoCommonDir(ofRun runId: AgentRunID) throws -> String? {
        try db.performSync { database in
            let statement = try database.prepare("SELECT git_common_dir FROM agent_run_repo_identity WHERE run_id = ? LIMIT 1;")
            try statement.bind(1, runId.description)
            return try statement.step() ? statement.columnText(0) : nil
        }
    }

    /// Main checkout path a common dir belongs to, so worktrees of one repo report one `repo`.
    public static func repoPath(forCommonDir commonDir: String) -> String {
        let url = URL(fileURLWithPath: commonDir)
        return url.lastPathComponent == ".git" ? url.deletingLastPathComponent().path : commonDir
    }
}
