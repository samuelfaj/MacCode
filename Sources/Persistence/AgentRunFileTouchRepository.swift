import CoreModel
import Foundation

/// Per-run repo identity and the files each run edited. Paths are relative to the run's `repo_root`.
public final class AgentRunFileTouchRepository: @unchecked Sendable {
    private let db: SQLiteDB

    public init(db: SQLiteDB) { self.db = db }

    public func saveIdentity(runId: AgentRunID, threadId: AgentThreadID, identity: RunRepoIdentity, at date: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO agent_run_repo_identity(run_id, thread_id, repo_root, git_common_dir, branch, resolved_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET repo_root = excluded.repo_root,
                    git_common_dir = excluded.git_common_dir, branch = excluded.branch, resolved_at = excluded.resolved_at;
                """)
            try statement.bind(1, runId.description)
            try statement.bind(2, threadId.value.uuidString)
            try statement.bind(3, identity.repoRoot)
            try statement.bind(4, identity.gitCommonDir)
            try statement.bind(5, identity.branch)
            try statement.bind(6, isoFractional.string(from: date))
            _ = try statement.step()
        }
    }

    public func identity(runId: AgentRunID) throws -> RunRepoIdentity? {
        try db.performSync { database in
            let statement = try database.prepare("SELECT repo_root, git_common_dir, branch FROM agent_run_repo_identity WHERE run_id = ? LIMIT 1;")
            try statement.bind(1, runId.description)
            guard try statement.step(), let root = statement.columnText(0), let common = statement.columnText(1) else { return nil }
            return RunRepoIdentity(repoRoot: root, gitCommonDir: common, branch: statement.columnText(2))
        }
    }

    public func identities(runIds: [AgentRunID]) throws -> [AgentRunID: RunRepoIdentity] {
        guard !runIds.isEmpty else { return [:] }
        var byRun: [AgentRunID: RunRepoIdentity] = [:]
        try db.performSync { database in
            for start in stride(from: 0, to: runIds.count, by: 500) {
                let batch = Array(runIds[start..<min(start + 500, runIds.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let statement = try database.prepare("SELECT run_id, repo_root, git_common_dir, branch FROM agent_run_repo_identity WHERE run_id IN (\(marks));")
                for (offset, id) in batch.enumerated() { try statement.bind(Int32(offset + 1), id.description) }
                while try statement.step() {
                    guard let raw = statement.columnText(0), let uuid = UUID(uuidString: raw),
                          let root = statement.columnText(1), let common = statement.columnText(2) else { continue }
                    byRun[AgentRunID(uuid)] = RunRepoIdentity(repoRoot: root, gitCommonDir: common, branch: statement.columnText(3))
                }
                statement.reset()
            }
        }
        return byRun
    }

    /// Run ids (uppercase UUID text) whose checkout shares the git common dir of `runId`; empty when `runId` has no identity.
    public func runIDsSharingRepo(with runId: AgentRunID) throws -> Set<String> {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT run_id FROM agent_run_repo_identity
                WHERE git_common_dir = (SELECT git_common_dir FROM agent_run_repo_identity WHERE run_id = ?);
                """)
            try statement.bind(1, runId.description)
            var ids = Set<String>()
            while try statement.step() { if let id = statement.columnText(0) { ids.insert(id) } }
            return ids
        }
    }

    /// Upserts one touch per (run, path, kind): `first_at` keeps the earliest edit, `last_at` the latest.
    public func recordTouches(runId: AgentRunID, threadId: AgentThreadID, repoRoot: String, touches: [ProviderFileTouch], at date: Date = Date()) throws {
        guard !touches.isEmpty else { return }
        let stamp = isoFractional.string(from: date)
        try db.performSync { database in
            try database.transaction {
                let statement = try database.prepare("""
                    INSERT INTO agent_run_file_touches(run_id, thread_id, repo_root, path, kind, first_at, last_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(run_id, path, kind) DO UPDATE SET last_at = MAX(last_at, excluded.last_at);
                    """)
                for touch in touches {
                    try statement.bind(1, runId.description)
                    try statement.bind(2, threadId.value.uuidString)
                    try statement.bind(3, repoRoot)
                    try statement.bind(4, touch.path)
                    try statement.bind(5, touch.kind.rawValue)
                    try statement.bind(6, stamp)
                    try statement.bind(7, stamp)
                    _ = try statement.step()
                    statement.reset()
                }
            }
        }
    }

    /// Distinct paths the run edited, oldest first.
    public func touches(runId: AgentRunID) throws -> [ConcurrentRunFile] {
        try touches(runIds: [runId])[runId] ?? []
    }

    public func touches(runIds: [AgentRunID]) throws -> [AgentRunID: [ConcurrentRunFile]] {
        guard !runIds.isEmpty else { return [:] }
        var byRun: [AgentRunID: [ConcurrentRunFile]] = [:]
        try db.performSync { database in
            for start in stride(from: 0, to: runIds.count, by: 500) {
                let batch = Array(runIds[start..<min(start + 500, runIds.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let statement = try database.prepare("""
                    SELECT run_id, path, MIN(first_at) FROM agent_run_file_touches
                    WHERE run_id IN (\(marks)) GROUP BY run_id, path ORDER BY MIN(first_at), path;
                    """)
                for (offset, id) in batch.enumerated() { try statement.bind(Int32(offset + 1), id.description) }
                while try statement.step() {
                    guard let raw = statement.columnText(0), let uuid = UUID(uuidString: raw),
                          let path = statement.columnText(1) else { continue }
                    let since = statement.columnText(2).flatMap { isoFractional.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
                    byRun[AgentRunID(uuid), default: []].append(ConcurrentRunFile(path: path, since: since))
                }
                statement.reset()
            }
        }
        return byRun
    }
}
