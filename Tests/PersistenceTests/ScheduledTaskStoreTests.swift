import XCTest
import CoreModel
@testable import Persistence

final class ScheduledTaskStoreTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private var db: SQLiteDB!
    private var store: ScheduledTaskStore!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = ScheduledTaskStore(db: db)
    }

    override func tearDown() {
        store = nil
        db = nil
    }

    func test_schemaVersionIncludesScheduledTables_becauseUpgradesMustBeAtomic() throws {
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, Schema.checkpointListSchemaVersion)
        let statement = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnInt64(0), Int64(Schema.currentVersion))
    }

    func test_storeErrorLocalizedDescriptionPreservesMessage_becauseXPCReplyMustNotShowError0() {
        // WHY: LaunchAgent replies with error.localizedDescription; without
        // LocalizedError the UI only saw "Persistence.ScheduledTaskStoreError error 0".
        let missing = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let cases: [ScheduledTaskStoreError] = [
            .invalidRow("This scheduled task already has an active run."),
            .missingTask(missing),
        ]
        for error in cases {
            XCTAssertEqual(error.localizedDescription, error.description)
            XCTAssertFalse(error.localizedDescription.contains("StoreError error"))
        }
        let asError: Error = ScheduledTaskStoreError.invalidRow("This scheduled task already has an active run.")
        XCTAssertEqual(
            asError.localizedDescription,
            "Invalid scheduled task row: This scheduled task already has an active run."
        )
    }

    func test_routingMigrationKeepsExistingTasksManual_becauseUpgradesMustNotChangeExecution() throws {
        let legacyDB = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(legacyDB, Schema.steps.filter { $0.version <= 50 })
        try legacyDB.execute("""
            INSERT INTO scheduled_tasks(
                id, title, prompt, workspace_id, workspace_path_snapshot, run_as_user, run_as_uid,
                provider, provider_instance_id, model, reasoning_effort, recurrence_json, timezone_id,
                enabled, created_at, updated_at
            ) VALUES(
                '00000000-0000-4000-8000-000000000001', 'Legacy', 'Run', '00000000-0000-4000-8000-000000000002', '/tmp', 'sam', 501,
                'codex', 'codex', 'gpt-5', 'high', '{"kind":"daily","hour":9,"minute":0}',
                'UTC', 1, '2026-07-22T00:00:00Z', '2026-07-22T00:00:00Z'
            );
        """)

        try Schema.migrate(legacyDB)

        let statement = try legacyDB.prepare("SELECT routing_mode FROM scheduled_tasks WHERE id = '00000000-0000-4000-8000-000000000001';")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnText(0), "manual")
        let legacy = try XCTUnwrap(ScheduledTaskStore(db: legacyDB).get(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        ))
        XCTAssertNil(legacy.reasoningModel, "old tasks remain without an independent Reasoning model")
        XCTAssertNil(legacy.distillMainEffortSelection, "old tasks keep the legacy shared-effort representation")
        XCTAssertNil(legacy.distillReasoningEffortSelection, "old tasks must not acquire an invented Reasoning pin")
    }

    func test_version84DatabaseRepairsScheduledTaskColumns_becauseScheduleTasksMustOpenAcrossUpgrade() throws {
        for hasScheduledTaskColumns in [false, true] {
            let legacyDB = try SQLiteDB(path: ":memory:")
            try Schema.migrateSteps(legacyDB, Schema.steps.filter { $0.version <= 83 })
            try legacyDB.execute("ALTER TABLE agent_threads ADD COLUMN reasoning_model TEXT;")
            if hasScheduledTaskColumns {
                try legacyDB.execute("""
                    ALTER TABLE scheduled_tasks ADD COLUMN reasoning_model TEXT;
                    ALTER TABLE scheduled_tasks ADD COLUMN distill_main_effort_json TEXT;
                    ALTER TABLE scheduled_tasks ADD COLUMN distill_reasoning_effort_json TEXT;
                    """)
            }
            try legacyDB.execute("INSERT INTO schema_meta(version, applied_at) VALUES(84, '2026-09-28T00:00:00Z');")

            try Schema.migrate(legacyDB)

            XCTAssertEqual(try ScheduledTaskStore(db: legacyDB).list(), [])
        }
    }

    func test_saveAndListRoundTripEveryExecutionField_becauseAgentRunsMustBeExact() throws {
        var task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        task.routingMode = .auto
        try store.save(task)

        XCTAssertEqual(try store.list(), [task])
        XCTAssertEqual(try store.get(id: task.id)?.effectiveRoutingMode, .auto)
    }

    func test_distillRoleModelsAndEffortsRoundTrip_becauseScheduledRunsMustRetainIndependentSettings() throws {
        var task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        task.provider = .distill
        task.providerInstanceID = "distill-primary"
        task.model = "main-model"
        task.reasoningModel = "reasoning-model"
        task.distillMainEffortSelection = .fixed(.high)
        task.distillReasoningEffortSelection = .automatic

        try store.save(task)

        XCTAssertEqual(try store.get(id: task.id), task)
        XCTAssertEqual(try store.list(), [task])
    }

    func test_newMessageRunOptionsRoundTrip_becauseScheduledRunsMustMatchTheAgentAppComposer() throws {
        var task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        task.provider = .distill
        task.providerInstanceID = "distill"
        task.model = "auto"
        task.distillExecutionMode = .ultrasave
        task.permissionMode = .autoAcceptEdits
        task.interactionMode = .plan
        task.executionMode = .worktree
        task.baseBranch = "production"

        try store.save(task)

        XCTAssertEqual(try store.get(id: task.id), task)
        XCTAssertEqual(try store.list(), [task])
    }

    func test_autoExecutionModeRoundTripsThroughTheIntegerColumn_becauseNewTasksDefaultToAuto() throws {
        // WHY: Auto is stored as 4 and must survive a save/load, since new rows must not collapse to Normal (0).
        var task = makeTask(nextRunAt: nil)
        task.provider = .distill
        task.providerInstanceID = "distill"
        task.model = "auto"
        XCTAssertEqual(task.distillExecutionMode, .auto)
        try store.save(task)
        XCTAssertEqual(try store.get(id: task.id)?.distillExecutionMode, .auto)
        task.distillExecutionMode = .normal
        try store.save(task)
        XCTAssertEqual(try store.get(id: task.id)?.distillExecutionMode, .normal, "explicit Normal (5) must not read back as Auto")
    }

    func test_claimDueDeduplicatesOccurrenceAndBlocksSameTaskOverlap_becauseCrashesMustNotDoubleRun() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)

        let first = try store.claimDue(now: Date(timeIntervalSince1970: 101), owner: "agent-a")
        let second = try store.claimDue(now: Date(timeIntervalSince1970: 102), owner: "agent-b")

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
        // WHY: the overlapping slot is spent as `skipped`, never queued behind the active run.
        let runs = try store.listRuns()
        XCTAssertEqual(runs.count, 1, "the second tick reuses the claimed occurrence key; no extra run row")
    }

    func test_slotAtLimitOneIsSkippedAndAdvanced_becauseSkippedSlotsMustNotQueueBehindActiveRun() throws {
        // WHY: a slot that fires while the one allowed run is active is spent, not replayed later as catch-up.
        var task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        task.maxConcurrentRuns = 1
        try store.save(task)
        _ = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 99), owner: "agent-a")
        let nextBefore = try XCTUnwrap(store.get(id: task.id)?.nextRunAt)
        let slotAt = try XCTUnwrap(task.nextRunAt)

        let claims = try store.claimDue(now: Date(timeIntervalSince1970: 101), owner: "agent-b")

        XCTAssertTrue(claims.isEmpty, "a skipped slot must never be returned as a claim")
        let skipped = try store.listRuns().filter { $0.status == .skipped }
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?.errorCode, "concurrency_limit")
        XCTAssertEqual(skipped.first?.scheduledAt, slotAt)
        XCTAssertEqual(skipped.first?.errorSummary, "Skipped: 1 run(s) of this task already running (limit 1).")
        let nextAfter = try XCTUnwrap(store.get(id: task.id)?.nextRunAt)
        XCTAssertGreaterThan(nextAfter, nextBefore, "the schedule must move past the spent slot")
    }

    func test_limitTwoClaimsSecondOverlappingSlot_becauseTwoRunsMayBeActiveAtOnce() throws {
        // WHY: a task allowed two concurrent runs must start the second run instead of skipping it.
        var task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        task.maxConcurrentRuns = 2
        try store.save(task)
        _ = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 99), owner: "agent-a")

        let claims = try store.claimDue(now: Date(timeIntervalSince1970: 101), owner: "agent-b")

        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(try store.listRuns().filter { $0.status == .skipped }.count, 0)
        XCTAssertEqual(try store.listActiveRuns().count, 2)
    }

    func test_manualRunAtLimitThrows_becauseRunNowMustObeyTheSameLimit() throws {
        // WHY: Run Now must not bypass the per-task limit the scheduler enforces.
        var task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        task.maxConcurrentRuns = 2
        try store.save(task)
        _ = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent-a")
        _ = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 102), owner: "agent-b")

        XCTAssertThrowsError(try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 103), owner: "agent-c")) { error in
            XCTAssertEqual(
                (error as? ScheduledTaskStoreError)?.description.contains("already has 2 active run(s) (limit 2)."),
                true
            )
        }
    }

    func test_missingMaxConcurrentRunsDecodesToOne_becauseOldRowsMustKeepSingleRunPolicy() throws {
        // WHY: tasks saved before the column existed must keep the one-at-a-time behavior.
        let legacy = makeTask(nextRunAt: nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any] ?? [:]
        json.removeValue(forKey: "maxConcurrentRuns")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: stripped)
        XCTAssertEqual(decoded.maxConcurrentRuns, 1)
    }

    func test_maxConcurrentRunsRoundTripsThroughTheColumn_becauseTheLimitMustSurviveRestart() throws {
        // WHY: the limit is read from the row at claim time; a dropped column silently reverts to 1.
        var task = makeTask(nextRunAt: nil)
        task.maxConcurrentRuns = 4
        try store.save(task)
        XCTAssertEqual(try store.get(id: task.id)?.maxConcurrentRuns, 4)
    }

    func test_globalConcurrencyAllowsMoreThanTwoClaims_becauseNoHardActiveCap() throws {
        // WHY: a global active-run ceiling of 2 blocked Run Now / due claims when
        // unrelated tasks were already running. Batch `limit` is not a global cap.
        for offset in 0..<3 {
            try store.save(makeTask(id: UUID(), title: "Task \(offset)", nextRunAt: Date(timeIntervalSince1970: 100)))
        }

        XCTAssertEqual(try store.claimDue(now: Date(timeIntervalSince1970: 101), owner: "agent", limit: 3).count, 3)
    }

    func test_manualRunAllowsThirdDistinctTaskWhileOthersActive_becauseGlobalCapWasRemoved() throws {
        // WHY: the user-visible alert "Two scheduled task runs are already active"
        // came from claimManual's global activeRunCount < 2 guard.
        let first = makeTask(id: UUID(), title: "First", nextRunAt: Date(timeIntervalSince1970: 100))
        let second = makeTask(id: UUID(), title: "Second", nextRunAt: Date(timeIntervalSince1970: 100))
        let third = makeTask(id: UUID(), title: "Third", nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(first)
        try store.save(second)
        try store.save(third)
        _ = try store.claimManual(taskID: first.id, now: Date(timeIntervalSince1970: 101), owner: "agent-a")
        _ = try store.claimManual(taskID: second.id, now: Date(timeIntervalSince1970: 102), owner: "agent-b")

        let thirdClaim = try store.claimManual(taskID: third.id, now: Date(timeIntervalSince1970: 103), owner: "agent-c")
        XCTAssertEqual(thirdClaim.task.id, third.id)
        XCTAssertEqual(try store.listActiveRuns().count, 3)
    }

    func test_recoverStaleLeaseMarksFailedAndPermitsFutureClaim_becauseProcessDeathMustSelfHeal() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try XCTUnwrap(store.claimDue(now: Date(timeIntervalSince1970: 101), owner: "agent").first)

        XCTAssertEqual(try store.recoverStaleLeases(now: Date(timeIntervalSince1970: 200), maximumRunAge: 50), 1)
        XCTAssertEqual(try store.listRuns().first?.status, .failed)
        XCTAssertEqual(try store.get(id: claim.task.id)?.id, task.id)
        XCTAssertTrue(try store.claimDue(now: Date(timeIntervalSince1970: 201), owner: "agent-b").isEmpty)
        XCTAssertEqual(try store.get(id: task.id)?.nextRunAt, task.calculatedNextRun(after: Date(timeIntervalSince1970: 100)))
    }

    func test_manualRunRejectsSameTaskOverlap_becauseRunNowMustNotBypassLeasePolicy() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        _ = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent-a")

        XCTAssertThrowsError(try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 102), owner: "agent-b"))
    }

    func test_attachThreadLinksWhileQueuedWithoutStatusChange_becausePathBMustNotHitQueuedToQueued() throws {
        // WHY: attachThread used updateRun(status: .queued) which canTransition
        // rejects (queued→queued). Every Run Now then failed after createAgentThread
        // with "invalid run status transition" and left an orphaned agent thread.
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")
        let threadID = AgentThreadID()

        try store.attachThread(runID: claim.run.id, threadID: threadID)

        let linked = try XCTUnwrap(store.listRuns().first { $0.id == claim.run.id })
        XCTAssertEqual(linked.status, .queued)
        XCTAssertEqual(linked.threadID, threadID)
        XCTAssertNil(linked.startedAt)
        XCTAssertNil(linked.agentRunID)

        // Idempotent same-thread re-attach.
        try store.attachThread(runID: claim.run.id, threadID: threadID)
        XCTAssertEqual(try store.listRuns().first { $0.id == claim.run.id }?.threadID, threadID)

        // Different thread while already linked must fail.
        XCTAssertThrowsError(try store.attachThread(runID: claim.run.id, threadID: AgentThreadID()))

        // Full lifecycle still works after metadata attach.
        let agentRunID = AgentRunID()
        try store.markStarted(runID: claim.run.id, threadID: threadID, agentRunID: agentRunID)
        try store.finish(runID: claim.run.id, status: .completed, at: Date(timeIntervalSince1970: 102))
        let done = try XCTUnwrap(store.listRuns().first { $0.id == claim.run.id })
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(done.threadID, threadID)
        XCTAssertEqual(done.agentRunID, agentRunID)
    }

    func test_attachThreadRejectsTerminalRuns_becauseOwnershipLinkIsPreStartOnly() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")
        try store.finish(runID: claim.run.id, status: .failed, at: Date(timeIntervalSince1970: 102))

        XCTAssertThrowsError(try store.attachThread(runID: claim.run.id, threadID: AgentThreadID()))
    }

    func test_deleteRejectsActiveRun_becauseExecutionMustNotBecomeOrphaned() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")

        XCTAssertThrowsError(try store.delete(id: task.id))

        try store.finish(runID: claim.run.id, status: .completed, at: Date(timeIntervalSince1970: 102))
        XCTAssertNoThrow(try store.delete(id: task.id))
    }

    func test_listActiveRunsIsUnboundedByHistoryLimit_becauseLongRunsMustKeepHeartbeats() throws {
        let activeTask = makeTask(id: UUID(), title: "Active", nextRunAt: nil)
        try store.save(activeTask)
        let claim = try store.claimManual(taskID: activeTask.id, now: Date(timeIntervalSince1970: 1), owner: "agent")
        try store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID())

        XCTAssertEqual(try store.listActiveRuns().map(\.id), [claim.run.id])
    }

    func test_runCountsUsesAllHistory_becauseOverviewMustNotCapAtOneThousand() throws {
        let task = makeTask(nextRunAt: nil)
        try store.save(task)
        for offset in 0..<1_001 {
            let claim = try store.claimManual(
                taskID: task.id,
                now: Date(timeIntervalSince1970: TimeInterval(offset)),
                owner: "agent"
            )
            try store.finish(
                runID: claim.run.id,
                status: .completed,
                at: Date(timeIntervalSince1970: TimeInterval(offset) + 0.5)
            )
        }

        XCTAssertEqual(try store.runCounts()[task.id], 1_001)
    }

    func test_runAuditFieldsRecordTriggerQueueLeaseAndHeartbeat_becauseHistoryMustExplainExecution() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)

        let claim = try XCTUnwrap(store.claimDue(now: Date(timeIntervalSince1970: 200), owner: "agent-a").first)

        XCTAssertEqual(claim.run.trigger, .catchUp)
        XCTAssertEqual(claim.run.queuedAt, Date(timeIntervalSince1970: 200))
        XCTAssertNil(claim.run.startedAt)
        XCTAssertEqual(claim.run.leaseOwner, "agent-a")
        XCTAssertEqual(claim.run.heartbeatAt, Date(timeIntervalSince1970: 200))
    }

    func test_terminalRunCannotReturnToRunning_becauseHistoryTransitionsMustBeMonotonic() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")
        try store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID())
        try store.finish(runID: claim.run.id, status: .completed, at: Date(timeIntervalSince1970: 102))

        XCTAssertThrowsError(try store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID()))
    }

    func test_heartbeatPreventsPrematureStaleRecovery_becauseLongRunsMustNotOverlap() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")
        try store.heartbeat(runID: claim.run.id, at: Date(timeIntervalSince1970: 190))

        XCTAssertEqual(try store.recoverStaleLeases(now: Date(timeIntervalSince1970: 200), maximumRunAge: 50), 0)
    }

    func test_failureHistoryRedactsCredentialShapes_becauseRunRowsAreSafeMetadataOnly() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")

        try store.finish(runID: claim.run.id, status: .failed, errorSummary: "token=abc123 Bearer topsecret sk-abcdefghijk")

        let summary = try XCTUnwrap(store.listRuns().first?.errorSummary)
        XCTAssertFalse(summary.contains("abc123"))
        XCTAssertFalse(summary.contains("topsecret"))
        XCTAssertFalse(summary.contains("sk-abcdefghijk"))
    }

    func test_failureHistoryRedactsSavedPrompt_becauseProviderEchoesMustNotLeakInstructions() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")

        try store.finish(
            runID: claim.run.id,
            status: .failed,
            errorSummary: "Provider rejected: \(task.prompt)"
        )

        let summary = try XCTUnwrap(store.listRuns().first?.errorSummary)
        XCTAssertFalse(summary.contains(task.prompt))
        XCTAssertTrue(summary.contains("[REDACTED PROMPT]"))
    }

    func test_pauseKeepsActiveRunRecoverable_becausePauseOnlyBlocksFutureOccurrences() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")
        try store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID())

        try store.setEnabled(id: task.id, enabled: false, nextRunAt: nil, updatedAt: Date(timeIntervalSince1970: 110))
        try store.heartbeat(runID: claim.run.id, at: Date(timeIntervalSince1970: 190))

        XCTAssertEqual(try store.recoverStaleLeases(now: Date(timeIntervalSince1970: 200), maximumRunAge: 50), 0)
        XCTAssertEqual(try store.listActiveRuns().map(\.id), [claim.run.id])
    }

    func test_dueClaimsAreFIFO_becauseOlderOccurrencesMustNotStarve() throws {
        let oldest = makeTask(id: UUID(), title: "Oldest", nextRunAt: Date(timeIntervalSince1970: 100))
        let middle = makeTask(id: UUID(), title: "Middle", nextRunAt: Date(timeIntervalSince1970: 101))
        let newest = makeTask(id: UUID(), title: "Newest", nextRunAt: Date(timeIntervalSince1970: 102))
        try store.save(newest)
        try store.save(oldest)
        try store.save(middle)

        let claims = try store.claimDue(now: Date(timeIntervalSince1970: 200), owner: "agent", limit: 2)

        XCTAssertEqual(claims.map(\.task.id), [oldest.id, middle.id])
    }

    func test_onceAdvanceDisablesTask_becauseOneShotSchedulesMustNeverRepeat() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)

        try store.advance(taskID: task.id, nextRunAt: nil, lastRunAt: nil, at: Date(timeIntervalSince1970: 101))

        let stored = try XCTUnwrap(store.get(id: task.id))
        XCTAssertFalse(stored.isEnabled)
        XCTAssertNil(stored.nextRunAt)
    }

    func test_dateRoundTripFloorsSubseconds_becauseOccurrenceKeysMustStayStable() throws {
        // WHY: default ISO8601 without fractions + raw subsecond anchors caused
        // hourly next_run_at to re-select the spent slot after claim.
        let fractional = Date(timeIntervalSince1970: 1_700_000_000.824)
        let task = makeHourlyTask(nextRunAt: fractional, anchor: fractional, intervalHours: 2)
        try store.save(task)

        let stored = try XCTUnwrap(store.get(id: task.id))
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(stored.nextRunAt, expected)
        if case .hourly(let anchor, let hours) = stored.recurrence {
            XCTAssertEqual(anchor, expected)
            XCTAssertEqual(hours, 2)
        } else {
            XCTFail("expected hourly")
        }
    }

    func test_duplicateOccurrenceAdvancesPastSpentHourly_becauseStallLoopMustSelfHeal() throws {
        // WHY: after a fire, if next_run_at is still the spent slot (legacy bug or
        // crash mid-advance), claimDue must not spin forever on occurrence_key.
        let anchor = Date(timeIntervalSince1970: 1_700_000_000.824)
        let spent = Date(timeIntervalSince1970: 1_700_000_000)
        let task = makeHourlyTask(nextRunAt: spent, anchor: anchor, intervalHours: 2)
        try store.save(task)

        let first = try store.claimDue(now: Date(timeIntervalSince1970: 1_700_000_010), owner: "agent-a")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.run.scheduledAt, spent)

        // Simulate execute advancing incorrectly to the same spent second (legacy).
        try store.advance(taskID: task.id, nextRunAt: spent, lastRunAt: spent, at: Date(timeIntervalSince1970: 1_700_000_020))
        try store.finish(runID: first[0].run.id, status: .completed, at: Date(timeIntervalSince1970: 1_700_000_030))

        // Next claim hits duplicate occurrence_key and must jump to anchor+2h.
        let second = try store.claimDue(now: Date(timeIntervalSince1970: 1_700_000_040), owner: "agent-b")
        XCTAssertTrue(second.isEmpty, "duplicate path claims nothing; it only advances next")
        let healed = try XCTUnwrap(store.get(id: task.id))
        XCTAssertEqual(healed.nextRunAt, Date(timeIntervalSince1970: 1_700_000_000 + 2 * 3600))

        // Future due time claims the advanced slot once.
        let third = try store.claimDue(
            now: Date(timeIntervalSince1970: 1_700_000_000 + 2 * 3600 + 5),
            owner: "agent-c"
        )
        XCTAssertEqual(third.count, 1)
        XCTAssertEqual(third.first?.run.scheduledAt, Date(timeIntervalSince1970: 1_700_000_000 + 2 * 3600))
        XCTAssertNotEqual(third.first?.run.occurrenceKey, first.first?.run.occurrenceKey)
    }

    func test_calculatedNextRunAfterSpentOnTask_matchesStoreHealPath() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000.5)
        let spent = Date(timeIntervalSince1970: 1_700_000_000)
        let task = makeHourlyTask(nextRunAt: spent, anchor: anchor, intervalHours: 1)
        XCTAssertEqual(
            task.calculatedNextRunAfterSpent(spent),
            Date(timeIntervalSince1970: 1_700_000_000 + 3600)
        )
    }

    func test_deleteTaskDoesNotDeleteAgentThread_becauseRunHistoryLinksAreNotOwnership() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let thread = AgentThread(workspaceId: task.workspaceID, title: "Scheduled", provider: .codex, model: "gpt-5")
        try AgentThreadRepository(db: db).upsert(thread)

        try store.delete(id: task.id)

        XCTAssertNotNil(try AgentThreadRepository(db: db).get(id: thread.id))
    }

    private func makeTask(
        id: UUID = UUID(),
        title: String = "Audit",
        nextRunAt: Date?
    ) -> ScheduledTask {
        let created = Date(timeIntervalSince1970: 10)
        return ScheduledTask(
            id: id, title: title, prompt: "Inspect the workspace", workspaceID: WorkspaceID(),
            workspacePathSnapshot: "/tmp", runAsUser: "sam", runAsUID: 501,
            provider: .codex, providerInstanceID: "codex-primary",
            model: "gpt-5", reasoningEffort: .high,
            recurrence: .daily(at: ScheduledLocalTime(hour: 8, minute: 15)!),
            timeZoneIdentifier: "America/Asuncion", isEnabled: true,
            nextRunAt: nextRunAt, createdAt: created, updatedAt: created
        )
    }

    private func makeHourlyTask(
        id: UUID = UUID(),
        nextRunAt: Date?,
        anchor: Date,
        intervalHours: Int
    ) -> ScheduledTask {
        let created = Date(timeIntervalSince1970: 10)
        return ScheduledTask(
            id: id, title: "Hourly", prompt: "Inspect the workspace", workspaceID: WorkspaceID(),
            workspacePathSnapshot: "/tmp", runAsUser: "sam", runAsUID: 501,
            provider: .codex, providerInstanceID: "codex-primary",
            model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: anchor, intervalHours: intervalHours),
            timeZoneIdentifier: "UTC", isEnabled: true,
            nextRunAt: nextRunAt, createdAt: created, updatedAt: created
        )
    }

    func test_multipleRecurrenceSurvivesSaveAndReload_becauseSchedulesMustNotCollapseToOneRule() throws {
        var task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        let morning = ScheduledTaskRecurrence.weekly(on: [.monday, .friday], at: ScheduledLocalTime(hour: 10, minute: 10)!)
        let afternoon = ScheduledTaskRecurrence.weekly(on: [.monday, .friday], at: ScheduledLocalTime(hour: 13, minute: 10)!)
        task.recurrence = .multiple([morning, afternoon])
        try store.save(task)

        let reloaded = try XCTUnwrap(store.get(id: task.id))

        XCTAssertEqual(reloaded.recurrence, .multiple([morning, afternoon]))
    }
}
