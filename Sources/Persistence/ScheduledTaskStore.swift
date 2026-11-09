import Foundation
import CoreModel

public enum ScheduledTaskStoreError: Error, CustomStringConvertible, LocalizedError {
    case invalidRow(String)
    case missingTask(UUID)

    public var description: String {
        switch self {
        case .invalidRow(let message): return "Invalid scheduled task row: \(message)"
        case .missingTask(let id): return "Scheduled task not found: \(id.uuidString)"
        }
    }

    /// WHY: LaunchAgent XPC replies use `error.localizedDescription`. Without
    /// LocalizedError the associated message is lost over the wire.
    public var errorDescription: String? { description }
}

public struct ScheduledTaskClaim: Sendable, Equatable {
    public let task: ScheduledTask
    public let run: ScheduledTaskRun
}

public final class ScheduledTaskStore: @unchecked Sendable {
    private let db: SQLiteDB
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dates = LockedISO8601Formatter({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }())

    public init(db: SQLiteDB) {
        self.db = db
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func list(search: String = "") throws -> [ScheduledTask] {
        try db.performSync { database in
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let sql: String
            if trimmed.isEmpty {
                sql = Self.taskSelect + " ORDER BY updated_at DESC;"
            } else {
                sql = Self.taskSelect + " WHERE title LIKE ? ESCAPE '\\' OR prompt LIKE ? ESCAPE '\\' ORDER BY updated_at DESC;"
            }
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            if !trimmed.isEmpty {
                let pattern = "%" + Self.escapeLike(trimmed) + "%"
                try statement.bind(1, pattern)
                try statement.bind(2, pattern)
            }
            var result: [ScheduledTask] = []
            while try statement.step() { result.append(try decodeTask(statement)) }
            return result
        }
    }

    public func get(id: UUID) throws -> ScheduledTask? {
        try db.performSync { database in
            let statement = try database.prepare(Self.taskSelect + " WHERE id = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, id.uuidString.lowercased())
            return try statement.step() ? try decodeTask(statement) : nil
        }
    }

    public func save(_ task: ScheduledTask) throws {
        let errors = task.validationErrors()
        guard errors.isEmpty else { throw ScheduledTaskStoreError.invalidRow(errors.joined(separator: " ")) }
        let recurrence = try encodeRecurrence(task.recurrence)
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO scheduled_tasks(
                    id, title, prompt, workspace_id, workspace_path_snapshot, run_as_user, run_as_uid,
                    provider, provider_instance_id,
                    model, reasoning_effort, reasoning_model, distill_main_effort_json, distill_reasoning_effort_json,
                    routing_mode, recurrence_json, timezone_id, enabled, next_run_at,
                    last_run_at, lease_owner, lease_expires_at, created_at, updated_at,
                    distill_ultracode, permission_mode, interaction_mode, execution_mode, base_branch,
                    max_concurrent_runs
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title, prompt=excluded.prompt, workspace_id=excluded.workspace_id,
                    workspace_path_snapshot=excluded.workspace_path_snapshot,
                    run_as_user=excluded.run_as_user, run_as_uid=excluded.run_as_uid, provider=excluded.provider,
                    provider_instance_id=excluded.provider_instance_id, model=excluded.model,
                    reasoning_effort=excluded.reasoning_effort, reasoning_model=excluded.reasoning_model,
                    distill_main_effort_json=excluded.distill_main_effort_json,
                    distill_reasoning_effort_json=excluded.distill_reasoning_effort_json,
                    routing_mode=excluded.routing_mode, recurrence_json=excluded.recurrence_json,
                    timezone_id=excluded.timezone_id, enabled=excluded.enabled,
                    next_run_at=excluded.next_run_at, last_run_at=excluded.last_run_at,
                    updated_at=excluded.updated_at,
                    distill_ultracode=excluded.distill_ultracode, permission_mode=excluded.permission_mode,
                    interaction_mode=excluded.interaction_mode, execution_mode=excluded.execution_mode,
                    base_branch=excluded.base_branch, max_concurrent_runs=excluded.max_concurrent_runs;
                """)
            defer { statement.reset() }
            try bindTask(task, recurrenceJSON: recurrence, statement: statement)
            _ = try statement.step()
        }
    }

    public func delete(id: UUID) throws {
        try db.transaction {
            let active = try db.prepare("SELECT COUNT(*) FROM scheduled_task_runs WHERE task_id = ? AND status IN ('queued', 'running');")
            defer { active.reset() }
            try active.bind(1, id.uuidString.lowercased())
            guard try active.step(), active.columnInt64(0) == 0 else {
                throw ScheduledTaskStoreError.invalidRow("A running task cannot be deleted. Pause it and wait for the current run to finish.")
            }
            let statement = try db.prepare("DELETE FROM scheduled_tasks WHERE id = ?;")
            defer { statement.reset() }
            try statement.bind(1, id.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func setEnabled(id: UUID, enabled: Bool, nextRunAt: Date?, updatedAt: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE scheduled_tasks
                SET enabled = ?, next_run_at = ?, updated_at = ?,
                    lease_owner = CASE WHEN ? = 0 THEN NULL ELSE lease_owner END,
                    lease_expires_at = CASE WHEN ? = 0 THEN NULL ELSE lease_expires_at END
                WHERE id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, enabled)
            try statement.bind(2, string(nextRunAt))
            try statement.bind(3, string(updatedAt))
            try statement.bind(4, enabled)
            try statement.bind(5, enabled)
            try statement.bind(6, id.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func listRuns(taskID: UUID? = nil, limit: Int = 200) throws -> [ScheduledTaskRun] {
        try db.performSync { database in
            let capped = max(1, min(limit, 1_000))
            let sql = Self.runSelect + (taskID == nil ? " ORDER BY queued_at DESC LIMIT ?;" : " WHERE task_id = ? ORDER BY queued_at DESC LIMIT ?;")
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            var index: Int32 = 1
            if let taskID {
                try statement.bind(index, taskID.uuidString.lowercased())
                index += 1
            }
            try statement.bind(index, capped)
            var result: [ScheduledTaskRun] = []
            while try statement.step() { result.append(try decodeRun(statement)) }
            return result
        }
    }

    public func listActiveRuns() throws -> [ScheduledTaskRun] {
        try db.performSync { database in
            let statement = try database.prepare(Self.runSelect + " WHERE status IN ('queued', 'running') ORDER BY queued_at ASC;")
            defer { statement.reset() }
            var result: [ScheduledTaskRun] = []
            while try statement.step() { result.append(try decodeRun(statement)) }
            return result
        }
    }

    /// Active scheduled occurrence for a given agent thread, if any.
    public func activeRun(forThreadID threadID: AgentThreadID) throws -> ScheduledTaskRun? {
        try db.performSync { database in
            let statement = try database.prepare(
                Self.runSelect
                    + " WHERE status IN ('queued', 'running') AND thread_id = ? ORDER BY queued_at DESC LIMIT 1;"
            )
            defer { statement.reset() }
            try statement.bind(1, threadID.value.uuidString.lowercased())
            guard try statement.step() else { return nil }
            return try decodeRun(statement)
        }
    }

    /// Thread IDs currently owned by a live scheduled occurrence (LaunchAgent).
    /// Used so interactive launch reconciliation does not interrupt them.
    public func activeOwnedThreadIDs() throws -> Set<AgentThreadID> {
        try db.performSync { database in
            let statement = try database.prepare(
                "SELECT thread_id FROM scheduled_task_runs WHERE status IN ('queued', 'running') AND thread_id IS NOT NULL;"
            )
            defer { statement.reset() }
            var result = Set<AgentThreadID>()
            while try statement.step() {
                if let raw = statement.columnText(0), let uuid = UUID(uuidString: raw) {
                    result.insert(AgentThreadID(uuid))
                }
            }
            return result
        }
    }

    /// Each task's newest run that was not skipped. Its thread, when it has one, is the conversation "Last run" opens.
    public func latestRuns() throws -> [UUID: ScheduledTaskRun] {
        try db.performSync { database in
            let statement = try database.prepare(
                Self.runSelect + """
                 WHERE status != 'skipped' AND queued_at = (
                     SELECT MAX(s.queued_at) FROM scheduled_task_runs s
                     WHERE s.task_id = scheduled_task_runs.task_id AND s.status != 'skipped'
                 );
                """
            )
            defer { statement.reset() }
            var result: [UUID: ScheduledTaskRun] = [:]
            while try statement.step() {
                let run = try decodeRun(statement)
                result[run.taskID] = run
            }
            return result
        }
    }

    public func runCounts() throws -> [UUID: Int] {
        try db.performSync { database in
            let statement = try database.prepare("SELECT task_id, COUNT(*) FROM scheduled_task_runs GROUP BY task_id;")
            defer { statement.reset() }
            var result: [UUID: Int] = [:]
            while try statement.step() {
                guard let raw = statement.columnText(0), let taskID = UUID(uuidString: raw) else {
                    throw ScheduledTaskStoreError.invalidRow("run count contains an invalid task ID")
                }
                result[taskID] = Int(statement.columnInt64(1))
            }
            return result
        }
    }

    public func claimDue(
        now: Date,
        owner: String,
        limit: Int = 2,
        leaseDuration: TimeInterval = 6 * 60 * 60
    ) throws -> [ScheduledTaskClaim] {
        try db.transaction {
            // `limit` is per-poll batch size only — no global active-run ceiling.
            let available = max(0, limit)
            guard available > 0 else { return [] }
            // Leases do not gate selection: a task with an active run still fires
            // up to its `maxConcurrentRuns` limit.
            let query = try db.prepare(Self.taskSelect + """
                 WHERE enabled = 1 AND next_run_at IS NOT NULL AND next_run_at <= ?
                ORDER BY next_run_at ASC LIMIT ?;
                """)
            defer { query.reset() }
            try query.bind(1, string(now))
            try query.bind(2, available)
            var due: [ScheduledTask] = []
            while try query.step() { due.append(try decodeTask(query)) }

            var claims: [ScheduledTaskClaim] = []
            for task in due {
                guard let scheduledAt = task.nextRunAt else { continue }
                let run = ScheduledTaskRun(
                    taskID: task.id,
                    occurrenceKey: ScheduledTaskOccurrenceCalculator.occurrenceKey(taskID: task.id, scheduledAt: scheduledAt),
                    trigger: now.timeIntervalSince(scheduledAt) > 60 ? .catchUp : .scheduled,
                    scheduledAt: scheduledAt,
                    queuedAt: now,
                    status: .queued,
                    leaseOwner: owner,
                    heartbeatAt: now
                )
                let active = try activeRunCount(taskID: task.id)
                if active >= task.maxConcurrentRuns {
                    // Slot at the limit is spent, not queued: record it and move on.
                    var skipped = run
                    skipped.status = .skipped
                    skipped.leaseOwner = nil
                    skipped.heartbeatAt = nil
                    skipped.finishedAt = now
                    skipped.errorCode = "concurrency_limit"
                    skipped.errorSummary = Self.concurrencyLimitSummary(active: active, limit: task.maxConcurrentRuns)
                    _ = try insertRunIfNew(skipped)
                    try advance(
                        taskID: task.id,
                        nextRunAt: task.calculatedNextRunAfterSpent(scheduledAt),
                        lastRunAt: task.lastRunAt,
                        at: now
                    )
                    continue
                }
                guard try insertRunIfNew(run) else {
                    // Duplicate occurrence_key: advance past the spent slot
                    // (not `after: scheduledAt` alone — subsecond truncation
                    // would re-select the same hourly/once instant forever).
                    try advance(
                        taskID: task.id,
                        nextRunAt: task.calculatedNextRunAfterSpent(scheduledAt),
                        lastRunAt: task.lastRunAt,
                        at: now
                    )
                    continue
                }
                let update = try db.prepare("""
                    UPDATE scheduled_tasks SET lease_owner = ?, lease_expires_at = ?, updated_at = ?
                    WHERE id = ?;
                    """)
                defer { update.reset() }
                try update.bind(1, owner)
                try update.bind(2, string(now.addingTimeInterval(leaseDuration)))
                try update.bind(3, string(now))
                try update.bind(4, task.id.uuidString.lowercased())
                _ = try update.step()
                claims.append(ScheduledTaskClaim(task: task, run: run))
            }
            return claims
        }
    }

    public func claimManual(taskID: UUID, now: Date = Date(), owner: String, leaseDuration: TimeInterval = 6 * 60 * 60) throws -> ScheduledTaskClaim {
        try db.transaction {
            guard let task = try get(id: taskID) else { throw ScheduledTaskStoreError.missingTask(taskID) }
            let active = try activeRunCount(taskID: taskID)
            guard active < task.maxConcurrentRuns else {
                throw ScheduledTaskStoreError.invalidRow(
                    "This scheduled task already has \(active) active run(s) (limit \(task.maxConcurrentRuns))."
                )
            }
            let run = ScheduledTaskRun(
                taskID: taskID,
                occurrenceKey: "\(taskID.uuidString.lowercased()):manual:\(UUID().uuidString.lowercased())",
                trigger: .manual,
                scheduledAt: now,
                queuedAt: now,
                status: .queued,
                leaseOwner: owner,
                heartbeatAt: now
            )
            _ = try insertRunIfNew(run)
            let statement = try db.prepare("UPDATE scheduled_tasks SET lease_owner = ?, lease_expires_at = ?, updated_at = ? WHERE id = ?;")
            defer { statement.reset() }
            try statement.bind(1, owner)
            try statement.bind(2, string(now.addingTimeInterval(leaseDuration)))
            try statement.bind(3, string(now))
            try statement.bind(4, taskID.uuidString.lowercased())
            _ = try statement.step()
            return ScheduledTaskClaim(task: task, run: run)
        }
    }

    /// Link a scheduled occurrence to its agent thread before provider start so
    /// main-app Stop can resolve ownership during the create→send window.
    ///
    /// Metadata-only: does **not** change status. Path B calls this while the
    /// run is still `queued`; feeding `updateRun(status: .queued)` fails because
    /// `canTransition` rejects queued→queued (identity is not a lifecycle step).
    public func attachThread(runID: UUID, threadID: AgentThreadID) throws {
        try db.performSync { database in
            let current = try database.prepare("""
                SELECT status, thread_id FROM scheduled_task_runs WHERE id = ? LIMIT 1;
                """)
            defer { current.reset() }
            try current.bind(1, runID.uuidString.lowercased())
            guard try current.step(), let statusRaw = current.columnText(0),
                  let status = ScheduledTaskRunStatus(rawValue: statusRaw) else {
                throw ScheduledTaskStoreError.invalidRow("run \(runID.uuidString) is missing")
            }
            guard status == .queued else {
                throw ScheduledTaskStoreError.invalidRow(
                    "can only attach a thread while the run is queued (current: \(status.rawValue))"
                )
            }
            if let existing = current.columnText(1),
               let existingID = UUID(uuidString: existing) {
                if existingID == threadID.value {
                    return // idempotent re-attach of the same thread
                }
                throw ScheduledTaskStoreError.invalidRow(
                    "run already linked to a different agent thread"
                )
            }
            let update = try database.prepare("""
                UPDATE scheduled_task_runs
                SET thread_id = ?, heartbeat_at = ?
                WHERE id = ? AND status = 'queued';
                """)
            defer { update.reset() }
            let now = Date()
            try update.bind(1, threadID.value.uuidString.lowercased())
            try update.bind(2, string(now))
            try update.bind(3, runID.uuidString.lowercased())
            _ = try update.step()
        }
    }

    public func markStarted(runID: UUID, threadID: AgentThreadID, agentRunID: AgentRunID) throws {
        try updateRun(
            id: runID,
            status: .running,
            startedAt: Date(),
            finishedAt: nil,
            threadID: threadID,
            agentRunID: agentRunID,
            errorSummary: nil,
            releaseTaskLease: false
        )
    }

    /// Point a running occurrence at the agent run that automatically retried
    /// its failed one, so the occurrence finishes with the retry's outcome.
    public func relinkAgentRun(runID: UUID, agentRunID: AgentRunID) throws {
        try db.performSync { database in
            let update = try database.prepare(
                "UPDATE scheduled_task_runs SET agent_run_id = ? WHERE id = ? AND status = 'running';"
            )
            defer { update.reset() }
            try update.bind(1, agentRunID.value.uuidString.lowercased())
            try update.bind(2, runID.uuidString.lowercased())
            _ = try update.step()
        }
    }

    public func finish(runID: UUID, status: ScheduledTaskRunStatus, errorCode: String? = nil, errorSummary: String? = nil, at date: Date = Date()) throws {
        guard status == .completed || status == .failed || status == .cancelled || status == .skipped else {
            throw ScheduledTaskStoreError.invalidRow("A finished run needs a terminal status.")
        }
        try updateRun(
            id: runID,
            status: status,
            startedAt: nil,
            finishedAt: date,
            threadID: nil,
            agentRunID: nil,
            errorCode: errorCode ?? (status == .completed ? nil : "scheduled_task_\(status.rawValue)"),
            errorSummary: Self.safeErrorSummary(errorSummary),
            releaseTaskLease: true
        )
    }

    public func advance(taskID: UUID, nextRunAt: Date?, lastRunAt: Date?, at date: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE scheduled_tasks
                SET next_run_at = ?, last_run_at = ?, updated_at = ?,
                    enabled = CASE WHEN ? IS NULL THEN 0 ELSE enabled END
                WHERE id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, string(nextRunAt))
            try statement.bind(2, string(lastRunAt))
            try statement.bind(3, string(date))
            try statement.bind(4, string(nextRunAt))
            try statement.bind(5, taskID.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func recoverStaleLeases(now: Date, maximumRunAge: TimeInterval = 6 * 60 * 60) throws -> Int {
        try db.transaction {
            let cutoff = now.addingTimeInterval(-maximumRunAge)
            let select = try db.prepare("SELECT id FROM scheduled_task_runs WHERE status IN ('queued', 'running') AND COALESCE(heartbeat_at, queued_at) <= ?;")
            defer { select.reset() }
            try select.bind(1, string(cutoff))
            var ids: [UUID] = []
            while try select.step() {
                if let raw = select.columnText(0), let id = UUID(uuidString: raw) { ids.append(id) }
            }
            for id in ids {
                try updateRun(
                    id: id,
                    status: .failed,
                    startedAt: nil,
                    finishedAt: now,
                    threadID: nil,
                    agentRunID: nil,
                    errorCode: "scheduler_lease_expired",
                    errorSummary: "Scheduler lease expired before completion.",
                    releaseTaskLease: true
                )
            }
            return ids.count
        }
    }

    public func heartbeat(runID: UUID, at date: Date = Date(), leaseDuration: TimeInterval = 6 * 60 * 60) throws {
        try db.transaction {
            let run = try db.prepare("UPDATE scheduled_task_runs SET heartbeat_at = ? WHERE id = ? AND status IN ('queued', 'running');")
            defer { run.reset() }
            try run.bind(1, string(date))
            try run.bind(2, runID.uuidString.lowercased())
            _ = try run.step()

            let task = try db.prepare("""
                UPDATE scheduled_tasks SET lease_expires_at = ?, updated_at = ?
                WHERE id = (SELECT task_id FROM scheduled_task_runs WHERE id = ?)
                  AND lease_owner = (SELECT lease_owner FROM scheduled_task_runs WHERE id = ?);
                """)
            defer { task.reset() }
            try task.bind(1, string(date.addingTimeInterval(leaseDuration)))
            try task.bind(2, string(date))
            try task.bind(3, runID.uuidString.lowercased())
            try task.bind(4, runID.uuidString.lowercased())
            _ = try task.step()
        }
    }

    private func activeRunCount(taskID: UUID) throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM scheduled_task_runs WHERE task_id = ? AND status IN ('queued', 'running');")
        defer { statement.reset() }
        try statement.bind(1, taskID.uuidString.lowercased())
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    /// Shared with the scheduler log so skipped rows and UI copy stay identical.
    public static func concurrencyLimitSummary(active: Int, limit: Int) -> String {
        "Skipped: \(active) run(s) of this task already running (limit \(limit))."
    }

    private func insertRunIfNew(_ run: ScheduledTaskRun) throws -> Bool {
        let existing = try db.prepare("SELECT 1 FROM scheduled_task_runs WHERE occurrence_key = ? LIMIT 1;")
        defer { existing.reset() }
        try existing.bind(1, run.occurrenceKey)
        if try existing.step() { return false }

        let statement = try db.prepare("""
            INSERT INTO scheduled_task_runs(
                id, task_id, occurrence_key, trigger, scheduled_at, queued_at, started_at, finished_at,
                status, thread_id, agent_run_id, error_code, error_summary, lease_owner, heartbeat_at, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { statement.reset() }
        try statement.bind(1, run.id.uuidString.lowercased())
        try statement.bind(2, run.taskID.uuidString.lowercased())
        try statement.bind(3, run.occurrenceKey)
        try statement.bind(4, run.trigger.rawValue)
        try statement.bind(5, string(run.scheduledAt))
        try statement.bind(6, string(run.queuedAt))
        try statement.bind(7, string(run.startedAt))
        try statement.bind(8, string(run.finishedAt))
        try statement.bind(9, run.status.rawValue)
        try statement.bind(10, run.threadID?.value.uuidString.lowercased())
        try statement.bind(11, run.agentRunID?.value.uuidString.lowercased())
        try statement.bind(12, run.errorCode)
        try statement.bind(13, Self.safeErrorSummary(run.errorSummary))
        try statement.bind(14, run.leaseOwner)
        try statement.bind(15, string(run.heartbeatAt))
        try statement.bind(16, string(run.queuedAt))
        _ = try statement.step()
        return true
    }

    private func updateRun(
        id: UUID,
        status: ScheduledTaskRunStatus,
        startedAt: Date?,
        finishedAt: Date?,
        threadID: AgentThreadID?,
        agentRunID: AgentRunID?,
        errorCode: String? = nil,
        errorSummary: String?,
        releaseTaskLease: Bool
    ) throws {
        try db.performSync { database in
            let current = try database.prepare("""
                SELECT r.task_id, r.status, r.thread_id, r.agent_run_id, t.prompt
                FROM scheduled_task_runs r
                JOIN scheduled_tasks t ON t.id = r.task_id
                WHERE r.id = ? LIMIT 1;
                """)
            defer { current.reset() }
            try current.bind(1, id.uuidString.lowercased())
            guard try current.step(), let taskRaw = current.columnText(0), let taskID = UUID(uuidString: taskRaw) else {
                throw ScheduledTaskStoreError.invalidRow("run \(id.uuidString) is missing")
            }
            guard let currentRaw = current.columnText(1), let currentStatus = ScheduledTaskRunStatus(rawValue: currentRaw),
                  Self.canTransition(from: currentStatus, to: status) else {
                throw ScheduledTaskStoreError.invalidRow("invalid run status transition")
            }
            let storedThread = current.columnText(2)
            let storedAgentRun = current.columnText(3)
            let storedPrompt = current.columnText(4)
            let update = try database.prepare("""
                UPDATE scheduled_task_runs SET status = ?, started_at = COALESCE(?, started_at), finished_at = ?,
                    thread_id = ?, agent_run_id = ?, error_code = ?, error_summary = ?, heartbeat_at = ? WHERE id = ?;
                """)
            defer { update.reset() }
            try update.bind(1, status.rawValue)
            try update.bind(2, string(startedAt))
            try update.bind(3, string(finishedAt))
            try update.bind(4, threadID?.value.uuidString.lowercased() ?? storedThread)
            try update.bind(5, agentRunID?.value.uuidString.lowercased() ?? storedAgentRun)
            try update.bind(6, errorCode)
            try update.bind(7, Self.safeErrorSummary(errorSummary, removingPrompt: storedPrompt))
            try update.bind(8, string(finishedAt ?? startedAt))
            try update.bind(9, id.uuidString.lowercased())
            _ = try update.step()
            if releaseTaskLease {
                // Keep the task lease while sibling runs of the same task are still active.
                let release = try database.prepare("""
                    UPDATE scheduled_tasks SET
                        lease_owner = CASE WHEN EXISTS (SELECT 1 FROM scheduled_task_runs WHERE task_id = scheduled_tasks.id AND status IN ('queued', 'running')) THEN lease_owner ELSE NULL END,
                        lease_expires_at = CASE WHEN EXISTS (SELECT 1 FROM scheduled_task_runs WHERE task_id = scheduled_tasks.id AND status IN ('queued', 'running')) THEN lease_expires_at ELSE NULL END,
                        last_run_at = ?, updated_at = ?
                    WHERE id = ?;
                    """)
                defer { release.reset() }
                try release.bind(1, string(finishedAt))
                try release.bind(2, string(finishedAt ?? Date()))
                try release.bind(3, taskID.uuidString.lowercased())
                _ = try release.step()
            }
        }
    }

    private func bindTask(_ task: ScheduledTask, recurrenceJSON: String, statement: SQLiteStatement) throws {
        try statement.bind(1, task.id.uuidString.lowercased())
        try statement.bind(2, task.title.trimmingCharacters(in: .whitespacesAndNewlines))
        try statement.bind(3, task.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        try statement.bind(4, task.workspaceID.value.uuidString.lowercased())
        try statement.bind(5, task.workspacePathSnapshot)
        try statement.bind(6, task.runAsUser)
        try statement.bind(7, Int64(task.runAsUID))
        try statement.bind(8, task.provider.rawValue)
        try statement.bind(9, task.providerInstanceID)
        try statement.bind(10, task.model)
        try statement.bind(11, task.reasoningEffort.rawValue)
        try statement.bind(12, task.reasoningModel)
        try statement.bind(13, encodeEffortSelection(task.distillMainEffortSelection))
        try statement.bind(14, encodeEffortSelection(task.distillReasoningEffortSelection))
        try statement.bind(15, task.effectiveRoutingMode.rawValue)
        try statement.bind(16, recurrenceJSON)
        try statement.bind(17, task.timeZoneIdentifier)
        try statement.bind(18, task.isEnabled)
        try statement.bind(19, string(task.nextRunAt))
        try statement.bind(20, string(task.lastRunAt))
        try statement.bind(21, string(task.createdAt))
        try statement.bind(22, string(task.updatedAt))
        try statement.bind(23, task.distillExecutionMode.storageValue)
        try statement.bind(24, task.permissionMode.rawValue)
        try statement.bind(25, task.interactionMode.rawValue)
        try statement.bind(26, task.executionMode.rawValue)
        try statement.bind(27, task.baseBranch)
        try statement.bind(28, Int64(min(max(task.maxConcurrentRuns, 1), 5)))
    }

    private func decodeTask(_ statement: SQLiteStatement) throws -> ScheduledTask {
        let mainEffortSelection = try decodeEffortSelection(statement.columnText(12))
        let reasoningEffortSelection = try decodeEffortSelection(statement.columnText(13))
        guard let recurrenceRaw = statement.columnText(15) else {
            throw ScheduledTaskStoreError.invalidRow("missing scheduled_tasks recurrence_json")
        }
        let recurrence = try decodeRecurrence(recurrenceRaw)
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let title = statement.columnText(1), let prompt = statement.columnText(2),
            let workspaceRaw = statement.columnText(3), let workspaceUUID = UUID(uuidString: workspaceRaw),
            let workspacePath = statement.columnText(4),
            let runAs = statement.columnText(5),
            let providerRaw = statement.columnText(7), let provider = AgentProvider(rawValue: providerRaw),
            let instance = statement.columnText(8), let model = statement.columnText(9),
            let reasoningRaw = statement.columnText(10), let reasoning = AgentReasoningEffort(rawValue: reasoningRaw),
            let routingRaw = statement.columnText(14), let routingMode = AgentRoutingMode(rawValue: routingRaw),
            let timeZone = statement.columnText(16),
            let created = date(statement.columnText(22)), let updated = date(statement.columnText(23))
        else { throw ScheduledTaskStoreError.invalidRow("missing or invalid scheduled_tasks column") }
        return ScheduledTask(
            id: id, title: title, prompt: prompt, workspaceID: WorkspaceID(workspaceUUID), workspacePathSnapshot: workspacePath,
            runAsUser: runAs, runAsUID: UInt32(statement.columnInt64(6)), provider: provider, providerInstanceID: instance, model: model,
            reasoningEffort: reasoning,
            reasoningModel: statement.columnText(11),
            distillMainEffortSelection: mainEffortSelection,
            distillReasoningEffortSelection: reasoningEffortSelection,
            routingMode: routingMode,
            distillExecutionMode: DistillExecutionMode(storageValue: Int(statement.columnInt64(24))),
            permissionMode: statement.columnText(25).flatMap(AgentPermissionMode.init(rawValue:)) ?? .fullAccess,
            interactionMode: statement.columnText(26).flatMap(AgentInteractionMode.init(rawValue:)) ?? .default,
            executionMode: statement.columnText(27).flatMap(AgentExecutionMode.init(rawValue:)) ?? .local,
            baseBranch: statement.columnText(28),
            maxConcurrentRuns: Int(statement.columnInt64(29)),
            recurrence: recurrence, timeZoneIdentifier: timeZone,
            isEnabled: statement.columnInt64(17) != 0,
            nextRunAt: date(statement.columnText(18)), lastRunAt: date(statement.columnText(19)),
            createdAt: created, updatedAt: updated
        )
    }

    private func decodeRun(_ statement: SQLiteStatement) throws -> ScheduledTaskRun {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let taskRaw = statement.columnText(1), let taskID = UUID(uuidString: taskRaw),
            let key = statement.columnText(2),
            let triggerRaw = statement.columnText(3), let trigger = ScheduledTaskRunTrigger(rawValue: triggerRaw),
            let scheduledAt = date(statement.columnText(4)), let queuedAt = date(statement.columnText(5)),
            let statusRaw = statement.columnText(8), let status = ScheduledTaskRunStatus(rawValue: statusRaw)
        else { throw ScheduledTaskStoreError.invalidRow("missing or invalid scheduled_task_runs column") }
        let threadID = statement.columnText(9).flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
        let agentRunID = statement.columnText(10).flatMap(UUID.init(uuidString:)).map(AgentRunID.init)
        return ScheduledTaskRun(
            id: id, taskID: taskID, occurrenceKey: key, trigger: trigger, scheduledAt: scheduledAt,
            queuedAt: queuedAt, startedAt: date(statement.columnText(6)), finishedAt: date(statement.columnText(7)), status: status,
            threadID: threadID, agentRunID: agentRunID, errorCode: statement.columnText(11),
            errorSummary: statement.columnText(12), leaseOwner: statement.columnText(13), heartbeatAt: date(statement.columnText(14))
        )
    }

    private func encodeRecurrence(_ recurrence: ScheduledTaskRecurrence) throws -> String {
        guard let string = String(data: try encoder.encode(recurrence), encoding: .utf8) else {
            throw ScheduledTaskStoreError.invalidRow("recurrence is not UTF-8")
        }
        return string
    }

    private func decodeRecurrence(_ string: String) throws -> ScheduledTaskRecurrence {
        guard let data = string.data(using: .utf8) else { throw ScheduledTaskStoreError.invalidRow("recurrence is not UTF-8") }
        return try decoder.decode(ScheduledTaskRecurrence.self, from: data)
    }

    private func encodeEffortSelection(_ selection: AgentEffortSelection?) throws -> String? {
        guard let selection else { return nil }
        guard let value = String(data: try JSONEncoder().encode(selection), encoding: .utf8) else {
            throw ScheduledTaskStoreError.invalidRow("Distill effort selection is not UTF-8")
        }
        return value
    }

    private func decodeEffortSelection(_ value: String?) throws -> AgentEffortSelection? {
        guard let value else { return nil }
        guard let data = value.data(using: .utf8) else {
            throw ScheduledTaskStoreError.invalidRow("Distill effort selection is not UTF-8")
        }
        return try JSONDecoder().decode(AgentEffortSelection.self, from: data)
    }

    private func string(_ date: Date?) -> String? {
        date.map { dates.string(from: ScheduledTaskOccurrenceCalculator.canonicalInstant($0)) }
    }

    private func date(_ string: String?) -> Date? {
        string.flatMap(dates.date(from:)).map(ScheduledTaskOccurrenceCalculator.canonicalInstant)
    }

    // PERF: safeErrorSummary recompiled three secret-redaction patterns via
    // replacingOccurrences(options: .regularExpression) on every run error write.
    // Compile once; same templates as the prior string forms.
    private static let errorSummaryRedactionRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"(?i)(api[_-]?key|access[_-]?token|token|secret|password)\s*[:=]\s*[^\s,;]+"#
        ),
        try! NSRegularExpression(
            pattern: #"(?i)bearer\s+[A-Za-z0-9._~+/-]+"#
        ),
        try! NSRegularExpression(
            pattern: #"\bsk-[A-Za-z0-9_-]{8,}\b"#
        ),
    ]

    private static func safeErrorSummary(_ value: String?, removingPrompt prompt: String? = nil) -> String? {
        guard let value else { return nil }
        var oneLine = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = prompt?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedPrompt, !normalizedPrompt.isEmpty {
            oneLine = oneLine.replacingOccurrences(of: normalizedPrompt, with: "[REDACTED PROMPT]")
        }
        for regex in errorSummaryRedactionRegexes {
            let range = NSRange(oneLine.startIndex..<oneLine.endIndex, in: oneLine)
            oneLine = regex.stringByReplacingMatches(
                in: oneLine,
                options: [],
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
        return String(oneLine.prefix(500))
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func canTransition(from current: ScheduledTaskRunStatus, to next: ScheduledTaskRunStatus) -> Bool {
        switch current {
        case .queued:
            return next == .running || next == .completed || next == .failed || next == .cancelled || next == .skipped
        case .running:
            return next == .completed || next == .failed || next == .cancelled || next == .skipped
        case .completed, .failed, .cancelled, .skipped:
            return false
        }
    }

    private static let taskSelect = """
        SELECT id, title, prompt, workspace_id, workspace_path_snapshot, run_as_user, run_as_uid,
               provider, provider_instance_id, model, reasoning_effort, reasoning_model,
               distill_main_effort_json, distill_reasoning_effort_json,
               routing_mode, recurrence_json, timezone_id, enabled, next_run_at,
               last_run_at, lease_owner, lease_expires_at, created_at, updated_at,
               distill_ultracode, permission_mode, interaction_mode, execution_mode, base_branch,
               max_concurrent_runs
        FROM scheduled_tasks
        """

    private static let runSelect = """
        SELECT id, task_id, occurrence_key, trigger, scheduled_at, queued_at, started_at, finished_at,
               status, thread_id, agent_run_id, error_code, error_summary, lease_owner, heartbeat_at
        FROM scheduled_task_runs
        """
}
