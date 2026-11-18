import Foundation
import Darwin
import CoreModel
import CryptoKit
import SQLite3

/// Offline restore only: caller must own the host instance lock, with no live AppContext.
public enum HostDatabaseRestore {
    public enum QueueKind: String { case agent, bot }

    public struct Review {
        public let schemaVersion: Int
        public let fingerprint: String
        public let agentQueueIDs: [String]
        public let botQueueIDs: [String]
        public let routineIDs: [String]
        public let scheduledTaskIDs: [String]
        public var requiresConfirmation: Bool {
            !agentQueueIDs.isEmpty || !botQueueIDs.isEmpty || !routineIDs.isEmpty || !scheduledTaskIDs.isEmpty
        }
    }

    public static func inspect(backupURL: URL) throws -> Review {
        _ = try regularFile(backupURL)
        let db = try SQLiteDB(path: backupURL.path, readonly: true)
        try db.execute("BEGIN;")
        defer { try? db.execute("ROLLBACK;") }
        let version = try validateBackupSchema(db)
        let review = try reviewSnapshot(db, version: version)
        try db.execute("COMMIT;")
        return review
    }

    public static func requiresQueueReview(kind: QueueKind, id: String, db: SQLiteDB) throws -> Bool {
        let statement = try db.prepare("SELECT 1 FROM host_restore_queue_holds WHERE kind=? AND queue_id=? AND approved=0;")
        defer { statement.reset() }
        try statement.bind(1, kind.rawValue)
        try statement.bind(2, id)
        return try statement.step()
    }

    /// Only an explicit force-send action may release this exact restored intent.
    public static func approveQueue(kind: QueueKind, id: String, db: SQLiteDB) throws {
        let statement = try db.prepare("UPDATE host_restore_queue_holds SET approved=1 WHERE kind=? AND queue_id=?;")
        defer { statement.reset() }
        try statement.bind(1, kind.rawValue)
        try statement.bind(2, id)
        _ = try statement.step()
    }

    public static func recoverQueueApprovals(db: SQLiteDB) throws {
        try db.execute("UPDATE host_restore_queue_holds SET approved=0 WHERE approved<>0;")
    }

    public static func pauseQueue(kind: QueueKind, id: String, db: SQLiteDB) throws {
        let statement = try db.prepare("INSERT INTO host_restore_queue_holds(kind,queue_id,approved) VALUES(?,?,0) ON CONFLICT(kind,queue_id) DO UPDATE SET approved=0;")
        defer { statement.reset() }
        try statement.bind(1, kind.rawValue)
        try statement.bind(2, id)
        _ = try statement.step()
    }

    public static func recordQueueAttempt(kind: QueueKind, id: String, runID: AgentRunID, db: SQLiteDB) throws {
        let sql = kind == .agent
            ? "UPDATE host_restore_queue_holds SET attempt_run_id=? WHERE kind=? AND queue_id=?;"
            : "INSERT INTO host_restore_queue_holds(kind,queue_id,approved,attempt_run_id) VALUES(?,?,1,?) ON CONFLICT(kind,queue_id) DO UPDATE SET attempt_run_id=excluded.attempt_run_id;"
        let statement = try db.prepare(sql)
        defer { statement.reset() }
        if kind == .agent {
            try statement.bind(1, runID.value.uuidString)
            try statement.bind(2, kind.rawValue)
            try statement.bind(3, id)
        } else {
            try statement.bind(1, kind.rawValue)
            try statement.bind(2, id)
            try statement.bind(3, runID.value.uuidString)
        }
        _ = try statement.step()
    }

    public static func queueAttempt(kind: QueueKind, id: String, db: SQLiteDB) throws -> AgentRunID? {
        let statement = try db.prepare("SELECT attempt_run_id FROM host_restore_queue_holds WHERE kind=? AND queue_id=?;")
        defer { statement.reset() }
        try statement.bind(1, kind.rawValue)
        try statement.bind(2, id)
        guard try statement.step(), let raw = statement.columnText(0) else { return nil }
        guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw.lowercased() else {
            throw SQLiteError.execute("restored queue has an invalid attempt identity")
        }
        return AgentRunID(uuid)
    }

    /// Sibling of the pre-restore recovery database that receives quarantined orphan rows.
    public static func quarantineURL(forRecovery recoveryURL: URL) -> URL {
        recoveryURL.deletingLastPathComponent().appendingPathComponent(
            recoveryURL.lastPathComponent.replacingOccurrences(of: ".restore-recovery-", with: ".restore-quarantine-"))
    }

    /// `quarantineOrphans` opts in to moving rows whose parent no longer exists out of the restored
    /// database into `quarantineURL(forRecovery:)` instead of refusing the restore. Nothing is dropped
    /// without being saved there.
    public static func restore(backupURL: URL, currentURL: URL, reviewToken: String? = nil,
                               quarantineOrphans: Bool = false,
                               beforeCommit: ((URL, URL) throws -> Void)? = nil,
                               didCommit: (() -> Void)? = nil) throws -> URL {
        let sourceInfo = try regularFile(backupURL)
        let currentInfo = try regularFile(currentURL)
        guard sourceInfo.st_dev != currentInfo.st_dev || sourceInfo.st_ino != currentInfo.st_ino else {
            throw SQLiteError.open("restore source and current database are the same file")
        }
        let directory = currentURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let stageURL = directory.appendingPathComponent(".restore-stage-\(token).sqlite")
        let recoveryURL = directory.appendingPathComponent(".restore-recovery-\(token).sqlite")
        var recoveryCreated = false
        var committed = false
        do {
            try restore(backupURL: backupURL, currentURL: currentURL, stageURL: stageURL,
                        recoveryURL: recoveryURL, recoveryCreated: &recoveryCreated, reviewToken: reviewToken,
                        quarantineOrphans: quarantineOrphans, beforeCommit: beforeCommit,
                        didCommit: { committed = true; didCommit?() })
            do {
                try removeStage(stageURL)
            } catch {
                throw SQLiteError.execute("database restore committed but staging cleanup failed: \(error)")
            }
            return recoveryURL
        } catch {
            try? removeStage(stageURL)
            // After the commit the quarantine is the only copy of the removed rows: keep it.
            if !committed { try? removeStage(quarantineURL(forRecovery: recoveryURL)) }
            if recoveryCreated {
                throw SQLiteError.execute("\(error); pre-restore recovery database: \(recoveryURL.path)")
            }
            try? removeStage(recoveryURL)
            throw error
        }
    }

    private static func restore(backupURL: URL, currentURL: URL, stageURL: URL,
                                recoveryURL: URL, recoveryCreated: inout Bool, reviewToken: String?,
                                quarantineOrphans: Bool,
                                beforeCommit: ((URL, URL) throws -> Void)?,
                                didCommit: (() -> Void)?) throws {
        let source = try SQLiteDB(path: backupURL.path, readonly: true)
        try createPrivateFile(stageURL)
        do {
            let stage = try SQLiteDB(path: stageURL.path)
            try source.backup(to: stage)
            let version = try validateBackupSchema(stage)
            let review = try reviewSnapshot(stage, version: version)
            if let reviewToken {
                guard reviewToken == review.fingerprint else {
                    throw SQLiteError.execute("restore review fingerprint changed; inspect the backup again")
                }
            } else if review.requiresConfirmation {
                throw SQLiteError.execute("backup contains queued work or schedules requiring explicit review")
            }
            try Schema.migrate(stage)
            let orphans = try orphanRows(stage)
            if !orphans.isEmpty {
                guard quarantineOrphans else {
                    let summary = Dictionary(grouping: orphans, by: \.table).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
                    throw SQLiteError.execute("restore foreign key check failed: rows without a parent (\(summary)); restore with orphan quarantine to keep them aside")
                }
                try quarantine(orphansIn: stage, at: quarantineURL(forRecovery: recoveryURL))
            }
            try stage.enableFullDurability()
        }

        let current = try SQLiteDB(path: currentURL.path)
        try current.enableFullDurability()
        try current.execute("PRAGMA locking_mode=EXCLUSIVE;")
        try current.execute("BEGIN EXCLUSIVE;")
        try current.execute("COMMIT;")
        try validateVersion(current)
        try Schema.migrate(current)
        try createPrivateFile(recoveryURL)
        let recovery = try SQLiteDB(path: recoveryURL.path)
        try recovery.enableFullDurability()
        try current.backup(to: recovery)
        try recovery.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try recovery.execute("PRAGMA journal_mode=DELETE;")
        recoveryCreated = true

        do {
            let attach = try current.prepare("ATTACH DATABASE ? AS restored;")
            defer { attach.reset() }
            try attach.bind(1, stageURL.path)
            _ = try attach.step()
        }
        var columns: [String] = []
        do {
            let info = try current.prepare("PRAGMA table_info(bots);")
            defer { info.reset() }
            while try info.step() {
                if let name = info.columnText(1), name != "id" {
                    columns.append(name.replacingOccurrences(of: "\"", with: "\"\""))
                }
            }
        }
        let botUpdates = columns.map { "\"\($0)\"=latest.\"\($0)\"" }.joined(separator: ",")
        do {
            try current.transaction {
                let conflicts = try current.prepare("""
                    SELECT 1 WHERE EXISTS (
                        SELECT 1 FROM main.agent_queued_messages c LEFT JOIN restored.agent_queued_messages r ON r.id=c.id COLLATE NOCASE
                        WHERE r.id IS NULL OR r.thread_id<>c.thread_id COLLATE NOCASE OR r.text<>c.text OR r.attachments_json<>c.attachments_json OR r.interaction_mode IS NOT c.interaction_mode)
                    OR EXISTS (
                        SELECT r.* FROM main.agent_queued_message_routing r WHERE queued_message_id COLLATE NOCASE IN (SELECT id FROM main.agent_queued_messages)
                        EXCEPT SELECT r.* FROM restored.agent_queued_message_routing r WHERE queued_message_id COLLATE NOCASE IN (SELECT id FROM main.agent_queued_messages))
                    OR EXISTS (
                        SELECT r.* FROM restored.agent_queued_message_routing r WHERE queued_message_id COLLATE NOCASE IN (SELECT id FROM main.agent_queued_messages)
                        EXCEPT SELECT r.* FROM main.agent_queued_message_routing r WHERE queued_message_id COLLATE NOCASE IN (SELECT id FROM main.agent_queued_messages))
                    OR EXISTS (
                        SELECT 1 FROM main.agent_queued_messages q
                        JOIN restored.agent_threads source_thread ON source_thread.id=q.thread_id COLLATE NOCASE
                        LEFT JOIN main.agent_threads current_thread ON current_thread.id=q.thread_id COLLATE NOCASE
                        WHERE NOT EXISTS (SELECT 1 FROM restored.agent_queued_message_routing qr WHERE qr.queued_message_id=q.id COLLATE NOCASE)
                          AND (current_thread.id IS NULL
                            OR source_thread.provider IS NOT current_thread.provider
                            OR source_thread.provider_instance_id IS NOT current_thread.provider_instance_id
                            OR source_thread.model IS NOT current_thread.model
                            OR source_thread.permission_mode IS NOT current_thread.permission_mode
                            OR source_thread.reasoning_effort IS NOT current_thread.reasoning_effort
                            OR source_thread.service_tier IS NOT current_thread.service_tier
                            OR source_thread.model_selection_json IS NOT current_thread.model_selection_json
                            OR source_thread.reasoning_model IS NOT current_thread.reasoning_model
                            OR EXISTS (
                                SELECT sr.* FROM restored.agent_thread_routing sr
                                WHERE sr.thread_id=source_thread.id
                                EXCEPT SELECT cr.* FROM main.agent_thread_routing cr WHERE cr.thread_id=current_thread.id)
                            OR EXISTS (
                                SELECT cr.* FROM main.agent_thread_routing cr
                                WHERE cr.thread_id=current_thread.id
                                EXCEPT SELECT sr.* FROM restored.agent_thread_routing sr WHERE sr.thread_id=source_thread.id))
                    )
                    OR EXISTS (
                        SELECT 1 FROM main.bot_queued_follow_ups c LEFT JOIN restored.bot_queued_follow_ups r ON r.id=c.id COLLATE NOCASE
                        WHERE r.id IS NULL OR r.bot_id<>c.bot_id OR r.conversation_id IS NOT c.conversation_id OR r.text<>c.text OR r.payload_json<>c.payload_json);
                    """)
                defer { conflicts.reset() }
                guard try !conflicts.step() else {
                    throw SQLiteError.execute("restore would lose or change a current queued intent")
                }
                conflicts.reset()
                try current.execute("""
                    INSERT INTO restored.bots SELECT b.* FROM main.bots AS b
                    WHERE b.id IN (SELECT bot_id FROM main.bot_context_bindings)
                      AND NOT EXISTS (SELECT 1 FROM restored.bots WHERE restored.bots.id=b.id);
                    INSERT INTO restored.bot_revisions SELECT r.* FROM main.bot_revisions AS r
                    WHERE r.bot_id IN (SELECT id FROM restored.bots)
                      AND NOT EXISTS (SELECT 1 FROM restored.bot_revisions WHERE id=r.id);
                    UPDATE restored.bots AS old SET \(botUpdates)
                    FROM main.bots AS latest WHERE old.id=latest.id;
                    DELETE FROM restored.bot_handles WHERE bot_id IN (SELECT id FROM main.bots);
                    INSERT INTO restored.bot_handles SELECT h.* FROM main.bot_handles AS h
                    WHERE h.bot_id IN (SELECT id FROM restored.bots);
                    INSERT INTO restored.bot_handle_tombstones SELECT t.* FROM main.bot_handle_tombstones AS t
                    WHERE NOT EXISTS (SELECT 1 FROM restored.bot_handle_tombstones WHERE handle=t.handle);
                    DELETE FROM restored.bot_context_bindings;
                    INSERT INTO restored.bot_context_bindings SELECT * FROM main.bot_context_bindings;
                    DELETE FROM restored.settings;
                    INSERT INTO restored.settings SELECT * FROM main.settings;
                    DELETE FROM restored.command_receipts;
                    INSERT INTO restored.command_receipts SELECT * FROM main.command_receipts;
                    INSERT INTO restored.host_restore_queue_holds(kind,queue_id)
                    SELECT 'agent',id FROM restored.agent_queued_messages WHERE true ON CONFLICT(kind,queue_id) DO UPDATE SET approved=0;
                    INSERT INTO restored.host_restore_queue_holds(kind,queue_id)
                    SELECT 'bot',id FROM restored.bot_queued_follow_ups WHERE true ON CONFLICT(kind,queue_id) DO UPDATE SET approved=0;
                    UPDATE restored.host_restore_queue_holds AS old SET attempt_run_id=latest.attempt_run_id
                    FROM main.host_restore_queue_holds AS latest WHERE old.kind=latest.kind AND old.queue_id=latest.queue_id COLLATE NOCASE;
                    UPDATE restored.agent_queued_messages SET lease_id=NULL,lease_started_at=NULL;
                    UPDATE restored.bot_routine_activations SET is_enabled=0;
                    UPDATE restored.scheduled_tasks SET enabled=0,lease_owner=NULL,lease_expires_at=NULL;
                    UPDATE restored.scheduled_task_runs AS old
                    SET status=latest.status,finished_at=latest.finished_at,error_code=latest.error_code,error_summary=latest.error_summary
                    FROM main.scheduled_task_runs AS latest WHERE old.id=latest.id AND latest.status NOT IN ('queued','running');
                    INSERT INTO restored.agent_runs SELECT run.* FROM main.agent_runs AS run
                    WHERE (EXISTS (SELECT 1 FROM restored.agent_queued_messages q WHERE q.id=run.id COLLATE NOCASE AND q.thread_id=run.thread_id COLLATE NOCASE)
                        OR EXISTS (SELECT 1 FROM restored.host_restore_queue_holds h WHERE h.attempt_run_id=run.id COLLATE NOCASE))
                      AND NOT EXISTS (SELECT 1 FROM restored.agent_runs WHERE id=run.id);
                    UPDATE restored.agent_runs AS old
                    SET status=latest.status, finished_at=latest.finished_at,
                        error_message=latest.error_message, terminal_reason=latest.terminal_reason
                    FROM main.agent_runs AS latest
                    WHERE old.id=latest.id AND latest.status NOT IN ('running','pending');
                    """)
            }
        } catch {
            try? current.execute("DETACH DATABASE restored;")
            throw error
        }
        try current.execute("DETACH DATABASE restored;")
        let stage = try SQLiteDB(path: stageURL.path)
        try stage.enableFullDurability()
        try CommandReceiptRepository(db: stage).recoverInterruptedClaims()
        _ = try AgentRunRepository(db: stage).reconcileRunningOnLaunch()
        try AgentThreadRepository(db: stage).reconcileRunningOnLaunch()
        let schedules = ScheduledTaskStore(db: stage)
        for run in try schedules.listActiveRuns() {
            try schedules.finish(runID: run.id, status: .cancelled, errorCode: "database_restore_review", errorSummary: "Imported run stopped pending restore review.")
        }
        let terminalStatuses = try current.prepare("""
            SELECT thread_id, status FROM provider_session_runtime
            WHERE status NOT IN ('running', 'pending');
            """)
        defer { terminalStatuses.reset() }
        var terminalByThread: [String: String] = [:]
        while try terminalStatuses.step() {
            guard let threadID = terminalStatuses.columnText(0), let status = terminalStatuses.columnText(1) else {
                throw SQLiteError.execute("current provider session has invalid terminal status")
            }
            terminalByThread[threadID.lowercased()] = status
        }
        let importedProviderThreads = try stage.prepare("SELECT thread_id, status FROM provider_session_runtime;")
        defer { importedProviderThreads.reset() }
        let providerSessions = ProviderSessionRuntimeRepository(db: stage)
        while try importedProviderThreads.step() {
            guard let rawID = importedProviderThreads.columnText(0), let id = UUID(uuidString: rawID) else {
                throw SQLiteError.execute("restored provider session has an invalid thread identity")
            }
            let threadID = AgentThreadID(id)
            let importedStatus = AgentRunStatus(rawValue: importedProviderThreads.columnText(1) ?? "")
            if let terminalStatus = terminalByThread[rawID.lowercased()] {
                let update = try stage.prepare("UPDATE provider_session_runtime SET status=? WHERE thread_id=? COLLATE NOCASE;")
                try update.bind(1, terminalStatus)
                try update.bind(2, rawID)
                _ = try update.step()
                update.reset()
            } else if importedStatus == .running || importedStatus == .pending {
                try providerSessions.markStopped(threadId: threadID, status: .interrupted)
                let normalize = try stage.prepare("UPDATE provider_session_runtime SET status='interrupted' WHERE thread_id=? COLLATE NOCASE;")
                try normalize.bind(1, rawID)
                _ = try normalize.step()
                normalize.reset()
            }
        }
        let delegationRoots = try stage.prepare("SELECT parent_run_id FROM bot_context_delegations UNION SELECT child_run_id FROM bot_context_delegations;")
        defer { delegationRoots.reset() }
        let botStore = BotStore(db: stage)
        var delegationRunIDs: [AgentRunID] = []
        while try delegationRoots.step() {
            guard let rawID = delegationRoots.columnText(0), let id = UUID(uuidString: rawID) else {
                throw SQLiteError.execute("restored context delegation has an invalid run identity")
            }
            delegationRunIDs.append(AgentRunID(id))
        }
        for runID in delegationRunIDs {
            _ = try botStore.closeContextDelegationTree(runID: runID)
        }
        do {
            let check = try stage.prepare("PRAGMA integrity_check;")
            defer { check.reset() }
            guard try check.step(), check.columnText(0) == "ok", try !check.step() else {
                throw SQLiteError.execute("restore integrity check failed")
            }
        }
        guard try orphanRows(stage).isEmpty else { throw SQLiteError.execute("restore foreign key check failed") }
        try beforeCommit?(stageURL, recoveryURL)
        try stage.backup(to: current)
        didCommit?()
    }

    private static func orphanRows(_ db: SQLiteDB) throws -> [(table: String, rowid: Int64)] {
        let check = try db.prepare("PRAGMA foreign_key_check;")
        defer { check.reset() }
        var rows: [(table: String, rowid: Int64)] = []
        while try check.step() {
            guard let table = check.columnText(0), !check.columnIsNull(1) else {
                throw SQLiteError.execute("restore foreign key check failed on a table without rowid")
            }
            rows.append((table, check.columnInt64(1)))
        }
        return rows
    }

    /// Moves orphan rows, and rows orphaned by their removal, into a private quarantine database.
    private static func quarantine(orphansIn stage: SQLiteDB, at url: URL) throws {
        try createPrivateFile(url)
        try stage.execute("PRAGMA foreign_keys=OFF;")
        defer { try? stage.execute("PRAGMA foreign_keys=ON;") }
        let attach = try stage.prepare("ATTACH DATABASE ? AS quarantine;")
        try attach.bind(1, url.path)
        _ = try attach.step()
        attach.reset()
        do {
            var settled = false
            for _ in 0..<16 {
                let orphans = try orphanRows(stage)
                if orphans.isEmpty { settled = true; break }
                var byTable: [String: Set<Int64>] = [:]
                for orphan in orphans { byTable[orphan.table, default: []].insert(orphan.rowid) }
                for (table, rowids) in byTable {
                    let name = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    try stage.execute("CREATE TABLE IF NOT EXISTS quarantine.\(name) AS SELECT * FROM main.\(name) WHERE 0;")
                    let sorted = rowids.sorted()
                    for start in stride(from: 0, to: sorted.count, by: 500) {
                        let list = sorted[start..<min(start + 500, sorted.count)].map(String.init).joined(separator: ",")
                        try stage.execute("INSERT INTO quarantine.\(name) SELECT * FROM main.\(name) WHERE rowid IN (\(list)); DELETE FROM main.\(name) WHERE rowid IN (\(list));")
                    }
                }
            }
            guard settled else { throw SQLiteError.execute("restore foreign key check failed: orphan quarantine did not settle") }
        } catch {
            try? stage.execute("DETACH DATABASE quarantine;")
            throw error
        }
        try stage.execute("DETACH DATABASE quarantine;")
    }

    /// Objects older builds created that this schema no longer lists. They only cache display data,
    /// are accepted when their SQL is exactly as shipped, and are carried over unchanged.
    private static let legacyOptionalObjects: [String: String] = [
        "table/agent_message_outbound_payloads": [
            "CREATE TABLE agent_message_outbound_payloads (",
            "    message_id TEXT PRIMARY KEY NOT NULL,",
            "    thread_id TEXT NOT NULL,",
            "    outbound_text TEXT NOT NULL,",
            "    created_at TEXT NOT NULL,",
            "    FOREIGN KEY(message_id) REFERENCES agent_messages(id) ON DELETE CASCADE,",
            "    FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE",
            ")"].joined(separator: "\n"),
        "index/idx_agent_message_outbound_payloads_thread": [
            "CREATE INDEX idx_agent_message_outbound_payloads_thread",
            "    ON agent_message_outbound_payloads(thread_id, created_at)"].joined(separator: "\n"),
        "table/agent_message_display_translations": [
            "CREATE TABLE agent_message_display_translations (",
            "    message_id TEXT PRIMARY KEY NOT NULL,",
            "    thread_id TEXT NOT NULL,",
            "    wire_sha256 TEXT NOT NULL,",
            "    display_text TEXT NOT NULL,",
            "    created_at TEXT NOT NULL,",
            "    FOREIGN KEY(message_id) REFERENCES agent_messages(id) ON DELETE CASCADE,",
            "    FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE",
            ")"].joined(separator: "\n"),
        "index/idx_agent_message_display_translations_thread": [
            "CREATE INDEX idx_agent_message_display_translations_thread",
            "    ON agent_message_display_translations(thread_id, created_at)"].joined(separator: "\n"),
        "table/agent_timeline_display_translations": [
            "CREATE TABLE agent_timeline_display_translations (",
            "    owner_kind TEXT NOT NULL,",
            "    owner_id TEXT NOT NULL,",
            "    thread_id TEXT NOT NULL,",
            "    wire_sha256 TEXT NOT NULL,",
            "    display_text TEXT NOT NULL,",
            "    created_at TEXT NOT NULL,",
            "    PRIMARY KEY(thread_id, owner_kind, owner_id),",
            "    FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE",
            ")"].joined(separator: "\n"),
        "index/idx_agent_timeline_display_translations_thread": [
            "CREATE INDEX idx_agent_timeline_display_translations_thread",
            "    ON agent_timeline_display_translations(thread_id, created_at)"].joined(separator: "\n"),
    ]

    private static func validateBackupSchema(_ db: SQLiteDB) throws -> Int {
        func schema(_ database: SQLiteDB) throws -> [String: String] {
            let statement = try database.prepare("SELECT type,name,sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY type,name;")
            defer { statement.reset() }
            var result: [String: String] = [:]
            while try statement.step() {
                guard let type = statement.columnText(0), let name = statement.columnText(1), let sql = statement.columnText(2) else {
                    throw SQLiteError.execute("restore backup contains an unsupported schema object")
                }
                result[type + "/" + name] = sql
            }
            return result
        }
        var actual = try schema(db)
        for (key, sql) in legacyOptionalObjects where actual[key] == sql { actual[key] = nil }
        for version in [93, 96, Schema.hostRestoreQueueHoldsSchemaVersion, Schema.relayKeysSchemaVersion, Schema.scheduledTaskConcurrencySchemaVersion, Schema.currentVersion] {
            let trusted = try Schema.trustedRestoreSchema(version: version)
            if try actual == schema(trusted) {
                let meta = try db.prepare("SELECT MAX(version),typeof(MAX(version)) FROM schema_meta;")
                defer { meta.reset() }
                guard try meta.step(), meta.columnText(1) == "integer", meta.columnInt64(0) == Int64(version) else {
                    throw SQLiteError.execute("restore schema version does not match its trusted structure")
                }
                return version
            }
        }
        throw SQLiteError.execute("restore requires an exact trusted database schema")
    }

    private static func reviewSnapshot(_ db: SQLiteDB, version: Int) throws -> Review {
        var hash = SHA256()
        hash.update(data: Data("host-restore-review-v1".utf8))
        func bytes(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        func ids(_ table: String, _ column: String = "id") throws -> [String] {
            let statement = try db.prepare("SELECT \(column) FROM \(table) ORDER BY \(column);")
            defer { statement.reset() }
            var result: [String] = []
            while try statement.step() {
                guard let id = statement.columnText(0), UUID(uuidString: id)?.uuidString.lowercased() == id.lowercased() else {
                    throw SQLiteError.execute("restore work has a noncanonical identifier")
                }
                result.append(id)
            }
            return result
        }
        let agentIDs = try ids("agent_queued_messages")
        let botIDs = try ids("bot_queued_follow_ups")
        let routineIDs = try ids("bot_routine_definitions")
        let taskIDs = try ids("scheduled_tasks")
        let tables = try db.prepare("SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name;")
        defer { tables.reset() }
        while try tables.step() {
            guard let table = tables.columnText(0) else { throw SQLiteError.execute("restore table has no name") }
            bytes(Data(table.utf8))
            let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
            let rows = try db.prepare("SELECT * FROM \"\(escaped)\" ORDER BY rowid;")
            defer { rows.reset() }
            while try rows.step() {
                bytes(Data("row".utf8))
                for index in 0..<sqlite3_column_count(rows.handle) {
                    let type = sqlite3_column_type(rows.handle, index)
                    bytes(Data([UInt8(type)]))
                    switch type {
                    case SQLITE_INTEGER:
                        var value = sqlite3_column_int64(rows.handle, index).bigEndian
                        withUnsafeBytes(of: &value) { bytes(Data($0)) }
                    case SQLITE_FLOAT:
                        var value = sqlite3_column_double(rows.handle, index).bitPattern.bigEndian
                        withUnsafeBytes(of: &value) { bytes(Data($0)) }
                    case SQLITE_TEXT, SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(rows.handle, index))
                        if count > 0, let pointer = sqlite3_column_blob(rows.handle, index) {
                            bytes(Data(bytes: pointer, count: count))
                        } else { bytes(Data()) }
                    default: bytes(Data())
                    }
                }
            }
        }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Review(schemaVersion: version, fingerprint: fingerprint,
                      agentQueueIDs: agentIDs, botQueueIDs: botIDs,
                      routineIDs: routineIDs, scheduledTaskIDs: taskIDs)
    }

    private static func validateVersion(_ db: SQLiteDB) throws {
        let statement = try db.prepare("SELECT MAX(version), typeof(MAX(version)) FROM schema_meta;")
        defer { statement.reset() }
        guard try statement.step(), statement.columnText(1) == "integer",
              statement.columnInt64(0) > 0, statement.columnInt64(0) <= Int64(Schema.currentVersion) else {
            throw SQLiteError.execute("restore requires a supported MacCode database schema")
        }
    }

    private static func regularFile(_ url: URL) throws -> stat {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw SQLiteError.open("restore input is not an existing regular file")
        }
        return info
    }

    private static func createPrivateFile(_ url: URL) throws {
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SQLiteError.open("cannot create private restore database") }
        close(descriptor)
    }

    private static func removeStage(_ url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
