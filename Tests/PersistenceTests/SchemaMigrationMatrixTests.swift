import XCTest
@testable import Persistence
import CoreModel

private final class ForkIntentMaintenanceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstBatchGate: DispatchSemaphore?
    private let drainedExpectation: XCTestExpectation
    private let errorExpectation: XCTestExpectation?
    private var didBlockFirstBatch = false
    private var didObserveDrain = false
    private var didObserveError = false
    private var storedReceipts: [ForkIntentMaintenanceReceipt] = []
    private var storedReceiptTimes: [UInt64] = []

    init(
        firstBatchGate: DispatchSemaphore? = nil,
        drainedExpectation: XCTestExpectation,
        errorExpectation: XCTestExpectation? = nil
    ) {
        self.firstBatchGate = firstBatchGate
        self.drainedExpectation = drainedExpectation
        self.errorExpectation = errorExpectation
    }

    func beforeBatch() {
        lock.lock()
        let shouldBlock = !didBlockFirstBatch && firstBatchGate != nil
        if shouldBlock { didBlockFirstBatch = true }
        lock.unlock()
        if shouldBlock { firstBatchGate?.wait() }
    }

    func record(_ receipt: ForkIntentMaintenanceReceipt) {
        lock.lock()
        storedReceipts.append(receipt)
        storedReceiptTimes.append(DispatchTime.now().uptimeNanoseconds)
        let shouldFulfillError = receipt.errorKind != nil && !didObserveError
        if shouldFulfillError { didObserveError = true }
        let shouldFulfillDrain = receipt.errorKind == nil
            && !receipt.hasMore
            && !didObserveDrain
        if shouldFulfillDrain { didObserveDrain = true }
        lock.unlock()
        if shouldFulfillError { errorExpectation?.fulfill() }
        if shouldFulfillDrain { drainedExpectation.fulfill() }
    }

    var receipts: [ForkIntentMaintenanceReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return storedReceipts
    }

    var receiptTimes: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedReceiptTimes
    }
}

private final class ForkIntentFairnessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstReceiptExpectation: XCTestExpectation
    private let secondReceiptExpectation: XCTestExpectation
    private var storedReceipts: [ForkIntentMaintenanceReceipt] = []
    private var receiptTimes: [UInt64] = []

    init(
        firstReceiptExpectation: XCTestExpectation,
        secondReceiptExpectation: XCTestExpectation
    ) {
        self.firstReceiptExpectation = firstReceiptExpectation
        self.secondReceiptExpectation = secondReceiptExpectation
    }

    func record(_ receipt: ForkIntentMaintenanceReceipt) {
        guard receipt.errorKind == nil else { return }
        lock.lock()
        storedReceipts.append(receipt)
        receiptTimes.append(DispatchTime.now().uptimeNanoseconds)
        let count = storedReceipts.count
        lock.unlock()
        if count == 1 { firstReceiptExpectation.fulfill() }
        if count == 2 { secondReceiptExpectation.fulfill() }
    }

    var snapshot: (receipts: [ForkIntentMaintenanceReceipt], times: [UInt64]) {
        lock.lock()
        defer { lock.unlock() }
        return (storedReceipts, receiptTimes)
    }
}

private final class NoopSQLiteMaintenance: SQLiteDBOwnedMaintenance {
    func cancel() {}
}

private final class WeakSQLiteDBBox {
    weak var value: SQLiteDB?
}

/// P1 — Migration-path matrix: historical -> head.
///
/// WHY: `SchemaMigrationTransactionTests` covers transaction semantics (rollback,
/// re-run) but starts from an empty DB. The real migration risk is a partially-
/// deployed schema: a user on v13 who upgrades to head must get all intermediate
/// steps applied without data loss.  A missing ALTER or a step that fails mid-way
/// bricks the user's DB silently.
///
/// Strategy: `replay steps.prefix(n)` — apply the first n SchemaSteps to build
/// an "old version" DB in memory, seed representative data that those steps would
/// have created, then apply the remaining steps to head and assert:
///   1. `Schema.currentVersion` is reached (all steps applied).
///   2. Data seeded at the old version survives (no silent DROP/TRUNCATE).
///   3. New columns added after the old version are present and readable.
///
/// Key versions exercised (anchor points where new tables / non-trivial ALTERs land):
///   v1  — baseline (all core tables)
///   v2  — device_trust / audit_log / pairing_codes / notifications added
///   v13 — agent_turn_checkpoints added (checkpoint feature birth)
///   v25 — token_saver_savings added
///   v27 — rc_reversible_content added (CCR store)
///   v30 — token_saver_encoder_manifests added
///   v31 — shared_memory_blocks added
///   head — current  [identity: migrate from head is a no-op]
///
/// Each test follows the pattern:
///   1. Build old-version DB in memory via `Schema.migrateSteps(db, steps.prefix(n))`.
///   2. Seed a row in a table that existed at version n.
///   3. Migrate to head via `Schema.migrateSteps(db, steps)` (idempotent: already-applied steps skip).
///   4. Assert `maxVersion == currentVersion`.
///   5. Assert the seeded row survives and is readable.
final class SchemaMigrationMatrixTests: XCTestCase {

    // MARK: - Helpers

    private func maxVersion(_ db: SQLiteDB) throws -> Int {
        let st = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        defer { st.reset() }
        guard try st.step(), !st.columnIsNull(0) else { return 0 }
        return Int(st.columnInt64(0))
    }

    private func rowCount(_ db: SQLiteDB, table: String) throws -> Int {
        let st = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { st.reset() }
        guard try st.step() else { return 0 }
        return Int(st.columnInt64(0))
    }

    /// Current AgentRunRepository writes `terminal_reason` (v77). Partial-schema
    /// fixtures must insert the pre-column shape so upgrade tests still prove
    /// the older row survives.
    private func insertPreTerminalReasonRun(_ db: SQLiteDB, _ run: AgentRun) throws {
        let st = try db.prepare("""
            INSERT INTO agent_runs(
                id, thread_id, provider, provider_instance_id, model, status,
                started_at, finished_at, error_message
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        try st.bind(1, run.id.value.uuidString)
        try st.bind(2, run.threadId.value.uuidString)
        try st.bind(3, run.provider.rawValue)
        try st.bind(4, run.providerInstanceId ?? run.provider.rawValue)
        try st.bind(5, run.model)
        try st.bind(6, run.status.rawValue)
        try st.bind(7, ISO8601DateFormatter().string(from: run.startedAt))
        try st.bind(8, run.finishedAt.map { ISO8601DateFormatter().string(from: $0) })
        try st.bind(9, run.errorMessage)
        _ = try st.step()
    }

    /// Pre-v84 databases have no agent_threads.reasoning_model (nor the v86
    /// actor columns), so the head `AgentThreadRepository.upsert` cannot seed
    /// them. Insert only the columns an old-version schema already owns.
    private func insertPreReasoningModelThread(_ db: SQLiteDB, _ thread: AgentThread) throws {
        let st = try db.prepare("""
            INSERT INTO agent_threads(
                id, project_id, workspace_id, title, provider, provider_instance_id,
                model, provider_thread_id, status, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        try st.bind(1, thread.id.value.uuidString)
        try st.bind(2, thread.projectId?.value.uuidString)
        try st.bind(3, thread.workspaceId?.value.uuidString)
        try st.bind(4, thread.title)
        try st.bind(5, thread.provider.rawValue)
        try st.bind(6, thread.providerInstanceId ?? thread.provider.rawValue)
        try st.bind(7, thread.model)
        try st.bind(8, thread.providerThreadId)
        try st.bind(9, thread.status.rawValue)
        try st.bind(10, ISO8601DateFormatter().string(from: thread.createdAt))
        try st.bind(11, ISO8601DateFormatter().string(from: thread.updatedAt))
        _ = try st.step()
    }

    /// Build a DB that looks like "the app was at version n" by applying only the
    /// first n steps, then migrate to head and return the DB.
    private func migrateFromVersion(n: Int) throws -> SQLiteDB {
        let steps = Schema.steps
        let oldSteps = Array(steps.prefix(n))
        let db = try SQLiteDB(path: ":memory:")
        // Build the old-version schema.
        try Schema.migrateSteps(db, oldSteps)
        return db
    }

    // MARK: - v1 → head

    /// WHY: v1 is the absolute baseline — every schema above it builds on v1's
    /// core tables (agent_threads, agent_messages, agent_runs, events).  Any
    /// ALTER that collides with a v1 column name, or any step that drops a v1
    /// table, would corrupt a user who installed v1 at launch and upgraded later.
    func test_v1_to_head_dataAndVersionSurvive() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 1)

        // Seed a project row (created in v1).
        try db.execute("""
            INSERT INTO projects (id, name, path, created_at, updated_at)
            VALUES ('proj-v1', 'My Project', '/home/user/proj', '2024-01-01T00:00:00Z', '2024-01-01T00:00:00Z');
        """)
        XCTAssertEqual(try rowCount(db, table: "projects"), 1,
                       "precondition: v1 project row must be seeded before migrating to head")

        // Migrate to head.
        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v1 to head must reach currentVersion — " +
                       "any missing step leaves a user on an older schema than they expect")
        XCTAssertEqual(try rowCount(db, table: "projects"), 1,
                       "the v1 project row must survive migration to head — " +
                       "a destructive migration step silently destroys user data")
    }

    // MARK: - v2 → head

    /// WHY: v2 adds device_trust and audit_log (pairing / security tables). A user
    /// who paired a device at v2 and upgrades must keep their paired device; a
    /// migration that drops device_trust would silently de-pair all iOS clients.
    func test_v2_to_head_pairedDeviceAndAuditRowSurvive() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 2)

        // Seed a device_trust row and an audit_log row (both created in v2).
        try db.execute("""
            INSERT INTO device_trust (id, display_name, token_hash, created_at, capabilities)
            VALUES ('dev-v2', 'iPhone at v2', 'hash-abc', '2024-06-01T00:00:00Z', '*');
        """)
        try db.execute("""
            INSERT INTO audit_log (ts, actor, action, detail)
            VALUES ('2024-06-01T00:00:00Z', 'device', 'pairing.request', 'iPhone at v2');
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v2 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "device_trust"), 1,
                       "a v2 paired device must survive migration to head — " +
                       "losing device_trust rows silently de-pairs all iOS clients")
        XCTAssertEqual(try rowCount(db, table: "audit_log"), 1,
                       "a v2 audit_log row must survive migration to head — " +
                       "losing audit history breaks compliance and post-incident review")
        let st = try db.prepare("SELECT client_device_id, always_allow_pairing FROM device_trust WHERE id = 'dev-v2';")
        defer { st.reset() }
        XCTAssertTrue(try st.step(),
                      "v29 must add permanent trust columns to surviving v2 device_trust rows")
        XCTAssertTrue(st.columnIsNull(0),
                      "old paired devices have no pre-token client_device_id and must migrate as nil, not a fabricated id")
        XCTAssertEqual(st.columnInt64(1), 0,
                       "old paired devices must not silently become Always Allow during migration")
    }

    // MARK: - v13 → head

    /// WHY: v13 introduces agent_turn_checkpoints (the checkpoint feature). Users who
    /// enabled checkpoints at v13 have checkpoint rows; any migration that alters the
    /// PRIMARY KEY or drops the table would corrupt their undo history.
    func test_v13_to_head_checkpointRowSurvives() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 13)

        // Seed an agent_threads row (needed for FK in agent_turn_checkpoints).
        try db.execute("""
            INSERT INTO agent_threads
                (id, title, provider, model, status, created_at, updated_at)
            VALUES
                ('th-v13', 'Thread at v13', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
        """)
        // Seed an agent_runs row (needed for FK in agent_turn_checkpoints).
        try db.execute("""
            INSERT INTO agent_runs (id, thread_id, provider, model, status, started_at)
            VALUES ('run-v13', 'th-v13', 'claude', 'claude-3', 'idle', '2024-06-01T00:00:00Z');
        """)
        // Seed a checkpoint row (created in v13).
        try db.execute("""
            INSERT INTO agent_turn_checkpoints
                (thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref,
                 status, files_json, completed_at, created_at)
            VALUES
                ('th-v13', 'run-v13', 'turn-v13', 1, 'ref-abc',
                 'done', '[]', '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v13 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "agent_turn_checkpoints"), 1,
                       "a v13 checkpoint row must survive migration to head — " +
                       "destroying checkpoints removes the user's ability to undo agent actions")

        // Later steps add detail and bounded-list columns. Verify the v13 row
        // remains visible without fabricating metadata from its raw fields.
        let st = try db.prepare("""
            SELECT file_snapshots_json, diff_patch, file_diffs_json,
                   list_turn_id, list_completed_at, list_metadata_unavailable,
                   list_turn_id_encoded_bytes, list_turn_id_sha256
            FROM agent_turn_checkpoints
            LIMIT 1;
            """)
        defer { st.reset() }
        XCTAssertTrue(try st.step(),
                      "columns added after v13 " +
                      "must exist after migrating from v13 to head")
        XCTAssertTrue(st.columnText(3)?.hasPrefix("rc2-legacy-row:") == true)
        XCTAssertEqual(st.columnText(4), "2024-06-01T00:00:00.000Z")
        XCTAssertEqual(st.columnInt64(5), 1)
        XCTAssertEqual(st.columnInt64(6), 0)
        XCTAssertTrue(st.columnIsNull(7))
    }

    func test_v56_to_head_installsPerThreadCatalogRevisionAndListProjections() throws {
        // WHY: shared integration base is 56. Message identity (57) followed by
        // the single checkpoint step (58) must migrate as one ordered sequence.
        XCTAssertEqual(Schema.sharedIntegrationBaseVersion, 56)
        let db = try migrateFromVersion(n: Schema.sharedIntegrationBaseVersion)
        let threadID = UUID().uuidString
        let runID = UUID().uuidString
        try db.execute("""
            INSERT INTO agent_threads
                (id, title, provider, model, status, created_at, updated_at)
            VALUES
                ('\(threadID)', 'rev', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
            INSERT INTO agent_runs
                (id, thread_id, provider, model, status, started_at)
            VALUES
                ('\(runID)', '\(threadID)', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z');
            INSERT INTO agent_turn_checkpoints
                (thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref,
                 status, files_json, completed_at, created_at)
            VALUES
                ('\(threadID)', '\(runID)', 'legacy-t1', 1, 'r1', 'ready', '[]',
                 '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
            """)
        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertGreaterThanOrEqual(try maxVersion(db), Schema.checkpointListSchemaVersion)

        let legacy = try db.prepare("""
            SELECT list_turn_id, list_metadata_unavailable, files_summary_truncated
            FROM agent_turn_checkpoints WHERE thread_id = ?;
            """)
        try legacy.bind(1, threadID)
        XCTAssertTrue(try legacy.step())
        XCTAssertTrue(legacy.columnText(0)?.hasPrefix("rc2-legacy-row:") == true)
        XCTAssertEqual(legacy.columnInt64(1), 1)
        XCTAssertEqual(legacy.columnInt64(2), 1)

        // Per-thread fence: insert for this thread bumps only its row.
        try db.execute("""
            INSERT INTO agent_turn_checkpoints
                (thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref,
                 status, files_json, completed_at, created_at,
                 files_summary_json, files_summary_truncated,
                 list_turn_id, list_completed_at, list_metadata_unavailable)
            VALUES
                ('\(threadID)', '\(runID)', 't2', 2, 'r2', 'ready', '[]',
                 '2024-06-01T00:00:01.000Z', '2024-06-01T00:00:01Z',
                 '[]', 0, 't2', '2024-06-01T00:00:01.000Z', 0);
            """)
        let rev = try db.prepare("""
            SELECT revision FROM agent_turn_checkpoint_catalog_meta
            WHERE thread_id = ?;
            """)
        try rev.bind(1, threadID)
        XCTAssertTrue(try rev.step())
        XCTAssertGreaterThanOrEqual(rev.columnInt64(0), 2)
    }

    func test_precedingVersion_to_head_checkpointListStepIsSelfContained() throws {
        // WHY: the named relocatable step is self-contained from its immediate
        // predecessor. Composition renumbers `checkpointListSchemaVersion`
        // past Message slots; tests never hardcode SchemaStep57 / base+1.
        let preceding = Schema.checkpointListSchemaVersion - 1
        XCTAssertGreaterThanOrEqual(preceding, Schema.sharedIntegrationBaseVersion)
        let db = try migrateFromVersion(n: preceding)
        XCTAssertEqual(try maxVersion(db), preceding)
        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertGreaterThanOrEqual(try maxVersion(db), Schema.checkpointListSchemaVersion)

        // Table exists and is per-thread (no global id=1 singleton).
        let cols = try db.prepare(
            "PRAGMA table_info(agent_turn_checkpoint_catalog_meta);"
        )
        var names: [String] = []
        while try cols.step() {
            if let name = cols.columnText(1) { names.append(name) }
        }
        XCTAssertTrue(names.contains("thread_id"))
        XCTAssertTrue(names.contains("revision"))
        XCTAssertFalse(names.contains("id"), "must not ship the never-released global singleton schema")
    }

    func test_sharedBase_to_head_invalidLegacyCompletedAtUsesFixedBoundedSentinel() throws {
        // WHY: SQLite strftime returns NULL for malformed legacy dates. Falling
        // back to the raw completed_at value would copy attacker-sized text into
        // list_completed_at and violate the capture-time bounded source contract.
        let db = try migrateFromVersion(n: Schema.sharedIntegrationBaseVersion)
        let threadID = UUID().uuidString
        let runID = UUID().uuidString
        try db.execute("""
            INSERT INTO agent_threads
                (id, title, provider, model, status, created_at, updated_at)
            VALUES
                ('\(threadID)', 'legacy hostile date', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
            INSERT INTO agent_runs
                (id, thread_id, provider, model, status, started_at)
            VALUES
                ('\(runID)', '\(threadID)', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z');
            """)
        let hostile = "not-an-iso-date-" + String(repeating: "x", count: 128 * 1_024)
        let insert = try db.prepare("""
            INSERT INTO agent_turn_checkpoints
                (thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref,
                 status, files_json, completed_at, created_at)
            VALUES (?, ?, 'legacy-turn', 1, 'legacy-ref', 'ready', '[]', ?,
                    '2024-06-01T00:00:00Z');
            """)
        try insert.bind(1, threadID)
        try insert.bind(2, runID)
        try insert.bind(3, hostile)
        _ = try insert.step()

        try Schema.migrateSteps(db, Schema.steps)

        let row = try db.prepare("""
            SELECT list_completed_at, length(list_completed_at),
                   list_metadata_unavailable
            FROM agent_turn_checkpoints
            WHERE thread_id = ?;
            """)
        try row.bind(1, threadID)
        XCTAssertTrue(try row.step())
        XCTAssertEqual(row.columnText(0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(row.columnInt64(1), 24)
        XCTAssertEqual(row.columnInt64(2), 1)
    }

    func test_checkpointListSchemaVersion_isSingleNamedRelocatableStep() throws {
        // WHY: composition assigns one named constant atomically. Tests bind to
        // `checkpointListSchemaVersion` / `checkpointListMigrationSQL` identity,
        // never a fixed SchemaStep57 or base+1 equality that collides with Message.
        let namedSteps = Schema.steps.filter {
            $0.version == Schema.checkpointListSchemaVersion
        }
        XCTAssertEqual(namedSteps.count, 1, "exactly one step uses the named version")
        XCTAssertEqual(namedSteps[0].sql, Schema.checkpointListMigrationSQL)
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, Schema.checkpointListSchemaVersion)
        XCTAssertGreaterThan(
            Schema.checkpointListSchemaVersion,
            Schema.sharedIntegrationBaseVersion,
            "named step must sit after the shared integration base"
        )
        // The composed head has Message identity, named checkpoint list,
        // Token Saver per-thread totals (59), reserved no-op (60), lifecycle
        // support (61), bounded maintenance lookup support (62), the
        // durable RCW1 request/response/display rows (67-69), Bot
        // control-plane identity (70-71), content-free request
        // selection receipts (72-74), Bot context receipts (75), and the
        // later steps through head (76-93). Versions 63-66 are retired.
        let postBase = Schema.steps.filter {
            $0.version > Schema.sharedIntegrationBaseVersion
        }
        XCTAssertEqual(postBase.map(\.version), [
            Schema.sharedIntegrationBaseVersion + 1,
            Schema.checkpointListSchemaVersion,
            59,
            60,
            61,
            62,
            67,
            68,
            69,
            70,
            71,
            72,
            73,
            74,
            75,
            76,
            77,
            78,
            79,
            80,
            81,
            82,
            83,
            84,
            85,
            86,
            87,
            88,
            89,
            90,
            91,
            92,
            93,
            94,
            95,
            96,
            97,
            98,
            99,
            100,
            101,
            102
        ])
        XCTAssertEqual(Schema.currentVersion, 102)
        XCTAssertFalse(
            Schema.steps.contains { (63...66).contains($0.version) },
            "schema versions 63-66 are retired and must never be reused"
        )
    }

    /// WHY: v72 is the first durable, content-free request-selection receipt
    /// store. A user on v71 must gain empty tables (no historical backfill)
    /// and parent-first FK order: agent_runs/agent_threads before winner,
    /// winner before arms. Head re-migrate must stay a no-op.
    func test_v71ToHeadAddsRequestSelectionReceiptsWithoutBackfillAndEnforcesParentOrder() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 71 })
        XCTAssertEqual(try maxVersion(db), 71)
        let thread = AgentThread(title: "v71-receipts", provider: .codex, model: "gpt-test")
        try insertPreReasoningModelThread(db, thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-test",
            status: .pending
        )
        try insertPreTerminalReasonRun(db, run)

        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertEqual(Schema.currentVersion, 102)
        XCTAssertEqual(try rowCount(db, table: "agent_run_results"), 0,
                       "v91 creates empty result projection without unsafe historical backfill")

        XCTAssertEqual(try rowCount(db, table: "token_saver_run_winner_receipts"), 0,
                       "v72 must not backfill historical winners")
        XCTAssertEqual(try rowCount(db, table: "token_saver_run_arm_receipts"), 0,
                       "v72 must not backfill historical arms")

        XCTAssertThrowsError(try db.execute("""
            INSERT INTO token_saver_run_winner_receipts(
                run_id, thread_id, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_status, lifecycle, billing_claim,
                created_at, updated_at
            ) VALUES(
                'missing-run', '\(thread.id.value.uuidString)', 'codex', 'gpt-test',
                'human', 'candidate_error', 0, 'unavailable', 'provisional', 0,
                '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
            );
            """), "winner rows require an agent_runs parent")

        try db.execute("""
            INSERT INTO token_saver_run_winner_receipts(
                run_id, thread_id, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_status, lifecycle, billing_claim,
                created_at, updated_at
            ) VALUES(
                '\(run.id.value.uuidString)', '\(thread.id.value.uuidString)', 'codex',
                'gpt-test', 'human', 'candidate_error', 0, 'unavailable', 'provisional',
                0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
            );
            """)

        XCTAssertThrowsError(try db.execute("""
            INSERT INTO token_saver_run_arm_receipts(
                run_id, format, source_bound, producer_id, producer_revision,
                abi_revision, generation, structural, semantic, recovery,
                projection, availability, eligible
            ) VALUES(
                'missing-winner', 'human', 1, 'remotecode-human', '1', '1',
                'not_required', 'not_required', 'not_required', 'not_required',
                'projected', 'available', 1
            );
            """), "arm rows require a winner parent")

        try db.execute("""
            INSERT INTO token_saver_run_arm_receipts(
                run_id, format, source_bound, producer_id, producer_revision,
                abi_revision, generation, structural, semantic, recovery,
                projection, availability, eligible
            ) VALUES(
                '\(run.id.value.uuidString)', 'human', 1, 'remotecode-human', '1', '1',
                'not_required', 'not_required', 'not_required', 'not_required',
                'projected', 'available', 1
            );
            """)

        XCTAssertThrowsError(try db.execute("""
            UPDATE token_saver_run_winner_receipts
            SET selected_format = 'caveman'
            WHERE run_id = '\(run.id.value.uuidString)';
            """), "C10 selected_format must reject caveman")
        XCTAssertThrowsError(try db.execute("""
            UPDATE token_saver_run_winner_receipts
            SET billing_claim = 1
            WHERE run_id = '\(run.id.value.uuidString)';
            """), "billing_claim must stay forced 0")

        try Schema.migrate(db)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion, "head re-migrate must be a no-op at currentVersion")
        XCTAssertEqual(try rowCount(db, table: "token_saver_run_winner_receipts"), 1)
        XCTAssertEqual(try rowCount(db, table: "token_saver_run_arm_receipts"), 1)
    }

    /// WHY: origin/production and HEAD still ship schema 71. The first committed
    /// C10 step must be v72 with arm format rcs1, never a caveman-only v72 then
    /// a rename v73. Winner selected_format stays human/rcw1 until RCS1 runtime
    /// admission exists.
    func test_headOriginBaselineWas71AndV72RejectsCavemanOnWinnerAndArmWhileAcceptingRCS1Arm() throws {
        XCTAssertEqual(
            Schema.steps.filter { $0.version == 71 }.count, 1,
            "HEAD/origin production last published step is 71"
        )
        XCTAssertEqual(Schema.currentVersion, 102)
        XCTAssertEqual(
            Schema.steps.filter { $0.version > 71 }.map(\.version), [72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102],
            "v72 remains the first unpublished C10 step; v73 admits winner rcs1; v74 owns context-slot receipts; v75 owns Bot context receipts; v76 owns Bot routine schedule spec; v77 owns nullable agent_runs.terminal_reason; v78 deduplicates savings retries; v79 preserves host attestations outside rolling replay; v80 owns Bot queued follow-ups; v81 indexes running thread IDs; v82 indexes audit_log(action, id); v83 indexes agent_threads(workspace_id, updated_at DESC, id DESC) for the rail list; v84 adds agent_threads.reasoning_model; v85 adds scheduled-task model fields; v86 adds thread actor/execution target; v87 adds thread guest_runtime; v88 adds Bot teams and group conversations; v89 adds bot_conversation_routing; v90 adds thread parent/fork + is_ephemeral; v91 adds agent_run_results; v92 adds Bot reply style columns; v93 adds the Titio notice ledger; v94-v102 add Bot contexts, delegations, restore holds, relay keys, Bot sort order, scheduled-task run options, virtual machines and Titio observations"
        )
        let v72 = try XCTUnwrap(Schema.steps.first { $0.version == 72 })
        XCTAssertTrue(v72.sql.contains("CHECK(format IN ('human', 'rcw1', 'rcs1'))"))
        XCTAssertTrue(v72.sql.contains("CHECK(selected_format IN ('human', 'rcw1'))"))
        XCTAssertFalse(v72.sql.contains("'caveman'"))

        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 71 })
        XCTAssertEqual(try maxVersion(db), 71, "HEAD/origin production baseline must stop at 71")
        let thread = AgentThread(title: "v72-rcs1-contract", provider: .codex, model: "gpt-test")
        try insertPreReasoningModelThread(db, thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-test", status: .pending)
        try insertPreTerminalReasonRun(db, run)
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 72 })
        XCTAssertEqual(try maxVersion(db), 72)

        try db.execute("""
            INSERT INTO token_saver_run_winner_receipts(
                run_id, thread_id, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_status, lifecycle, billing_claim,
                created_at, updated_at
            ) VALUES(
                '\(run.id.value.uuidString)', '\(thread.id.value.uuidString)', 'codex',
                'gpt-test', 'human', 'candidate_error', 0, 'unavailable', 'provisional',
                0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
            );
            """)
        XCTAssertThrowsError(try db.execute("""
            UPDATE token_saver_run_winner_receipts
            SET selected_format = 'caveman'
            WHERE run_id = '\(run.id.value.uuidString)';
            """), "v72 winner selected_format must reject caveman")
        XCTAssertThrowsError(try db.execute("""
            UPDATE token_saver_run_winner_receipts
            SET selected_format = 'rcs1'
            WHERE run_id = '\(run.id.value.uuidString)';
            """), "v72 winner selected_format must reject rcs1 until runtime admission")
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO token_saver_run_arm_receipts(
                run_id, format, source_bound, producer_id, producer_revision,
                abi_revision, generation, structural, semantic, recovery,
                projection, availability, eligible
            ) VALUES(
                '\(run.id.value.uuidString)', 'caveman', 0, 'remotecode-rcs1-unavailable',
                'unavailable', 'unavailable', 'failed', 'failed', 'failed', 'failed',
                'not_projected', 'unavailable', 0
            );
            """), "v72 arm format must reject caveman")
        XCTAssertNoThrow(try db.execute("""
            INSERT INTO token_saver_run_arm_receipts(
                run_id, format, source_bound, producer_id, producer_revision,
                abi_revision, generation, structural, semantic, recovery,
                projection, availability, eligible
            ) VALUES(
                '\(run.id.value.uuidString)', 'rcs1', 0, 'remotecode-rcs1-unavailable',
                'unavailable', 'unavailable', 'failed', 'failed', 'failed', 'failed',
                'not_projected', 'unavailable', 0
            );
            """), "v72 arm format must accept rcs1")
    }

    /// WHY: C11 admits winner selected_format rcs1 without losing v72 rows or
    /// weakening the remaining CHECKs/FKs. Re-migrate at head must stay a no-op.
    func test_v72ToHeadRebuildsWinnerSelectedFormatToPermitRCS1WithoutDataLoss() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 72 })
        XCTAssertEqual(try maxVersion(db), 72)
        let thread = AgentThread(title: "v73-rcs1", provider: .codex, model: "gpt-test")
        try insertPreReasoningModelThread(db, thread)
        let humanRun = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-test", status: .pending)
        let rcw1Run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-test", status: .pending)
        try insertPreTerminalReasonRun(db, humanRun)
        try insertPreTerminalReasonRun(db, rcw1Run)
        try db.execute("""
            INSERT INTO token_saver_run_winner_receipts(
                run_id, thread_id, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_status, lifecycle, billing_claim,
                created_at, updated_at
            ) VALUES(
                '\(humanRun.id.value.uuidString)', '\(thread.id.value.uuidString)', 'codex',
                'gpt-test', 'human', 'candidate_error', 0, 'unavailable', 'provisional',
                0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
            );
            """)
        try db.execute("""
            INSERT INTO token_saver_run_winner_receipts(
                run_id, thread_id, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_id, counter_revision, encoding,
                counter_status, lifecycle, billing_claim, created_at, updated_at
            ) VALUES(
                '\(rcw1Run.id.value.uuidString)', '\(thread.id.value.uuidString)', 'codex',
                'gpt-test', 'rcw1', 'unique_strict_minimum', 4, 'c', '1', 'enc',
                'exact_local_tokenizer', 'delivered', 0,
                '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
            );
            """)
        try db.execute("""
            INSERT INTO token_saver_run_arm_receipts(
                run_id, format, source_bound, producer_id, producer_revision,
                abi_revision, generation, structural, semantic, recovery,
                projection, availability, eligible
            ) VALUES(
                '\(humanRun.id.value.uuidString)', 'human', 1, 'remotecode-human', '1', '1',
                'not_required', 'not_required', 'not_required', 'not_required',
                'projected', 'available', 1
            );
            """)
        try db.execute("""
            INSERT INTO token_saver_run_arm_receipts(
                run_id, format, source_bound, producer_id, producer_revision,
                abi_revision, generation, structural, semantic, recovery,
                projection, availability, eligible
            ) VALUES(
                '\(rcw1Run.id.value.uuidString)', 'rcw1', 1, 'remotecode-rcw1', '1', '1',
                'passed', 'passed', 'passed', 'passed',
                'projected', 'available', 1
            );
            """)

        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertEqual(try rowCount(db, table: "token_saver_run_winner_receipts"), 2)
        XCTAssertEqual(try rowCount(db, table: "token_saver_run_arm_receipts"), 2)

        let formats = try db.prepare(
            "SELECT selected_format FROM token_saver_run_winner_receipts ORDER BY selected_format;"
        )
        XCTAssertTrue(try formats.step())
        XCTAssertEqual(formats.columnText(0), "human")
        XCTAssertTrue(try formats.step())
        XCTAssertEqual(formats.columnText(0), "rcw1")

        let rcs1Run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-test", status: .pending)
        try AgentRunRepository(db: db).upsert(rcs1Run)
        XCTAssertNoThrow(try db.execute("""
            INSERT INTO token_saver_run_winner_receipts(
                run_id, thread_id, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_status, lifecycle, billing_claim,
                created_at, updated_at
            ) VALUES(
                '\(rcs1Run.id.value.uuidString)', '\(thread.id.value.uuidString)', 'codex',
                'gpt-test', 'rcs1', 'unique_strict_minimum', 3, 'unavailable', 'provisional',
                0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
            );
            """), "v73 must persist winner selected_format rcs1")
        XCTAssertThrowsError(try db.execute("""
            UPDATE token_saver_run_winner_receipts
            SET selected_format = 'caveman'
            WHERE run_id = '\(rcs1Run.id.value.uuidString)';
            """), "v73 winner selected_format must still reject unknown formats")
        XCTAssertThrowsError(try db.execute("""
            UPDATE token_saver_run_winner_receipts
            SET billing_claim = 1
            WHERE run_id = '\(rcs1Run.id.value.uuidString)';
            """), "billing_claim must stay forced 0")

        try Schema.migrate(db)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion, "head re-migrate must be a no-op at currentVersion")
        XCTAssertEqual(try rowCount(db, table: "token_saver_run_winner_receipts"), 3)
    }

    /// WHY: v74 adds context-slot receipts without touching request-selection
    /// rows. A v73 database must gain empty tables and keep existing winners.
    func test_v73ToHeadAddsContextSlotReceiptsWithoutTouchingRequestReceipts() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 73 })
        XCTAssertEqual(try maxVersion(db), 73)
        let thread = AgentThread(title: "v74-context", provider: .codex, model: "gpt-test")
        try insertPreReasoningModelThread(db, thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-test", status: .pending)
        try insertPreTerminalReasonRun(db, run)
        try db.execute("""
            INSERT INTO token_saver_run_winner_receipts(
                run_id, thread_id, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_status, lifecycle, billing_claim,
                created_at, updated_at
            ) VALUES(
                '\(run.id.value.uuidString)', '\(thread.id.value.uuidString)', 'codex',
                'gpt-test', 'human', 'candidate_error', 0, 'unavailable', 'provisional',
                0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
            );
            """)
        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertEqual(try rowCount(db, table: "token_saver_run_winner_receipts"), 1)
        XCTAssertEqual(try rowCount(db, table: "token_saver_context_slot_receipts"), 0)
        XCTAssertEqual(try rowCount(db, table: "token_saver_context_slot_arm_receipts"), 0)
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO token_saver_context_slot_receipts(
                run_id, destination_provider_thread_id, snapshot_digest, source_message_id,
                role, ordinal, provider, resolved_model, selected_format, reason,
                modeled_context_delta, counter_status, lifecycle, billing_claim,
                created_at, updated_at
            ) VALUES(
                'missing-run', 'dest', '\(String(repeating: "a", count: 64))', 'msg',
                'assistant', 0, 'codex', 'gpt-test', 'human', 'candidate_error',
                0, 'unavailable', 'provisional', 0,
                '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
            );
            """), "context slot rows require an agent_runs parent")
        try Schema.migrate(db)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion, "head re-migrate must be a no-op at currentVersion")
    }

    // MARK: - v25 → head

    /// WHY: v25 introduces token_saver_savings. Users who accumulated savings data at
    /// v25 expect to see their historical Token Saver statistics after upgrading. A
    /// migration that drops the table erases all historical compression metrics.
    func test_v25_to_head_tokenSaverSavingsRowSurvives() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 25)

        try db.execute("""
            INSERT INTO token_saver_savings
                (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms)
            VALUES
                ('claude', 'fill', 1000, 200, 300, '2024-06-01T00:00:00Z', 1717200000000);
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v25 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "token_saver_savings"), 1,
                       "a v25 token_saver_savings row must survive migration to head — " +
                       "losing it erases the user's historical compression metrics")

        // v28 adds content_type, engine, cache_state columns; verify they exist and have defaults.
        let st = try db.prepare("SELECT content_type, engine, cache_state FROM token_saver_savings LIMIT 1;")
        defer { st.reset() }
        XCTAssertTrue(try st.step(),
                      "columns added in v28 (content_type, engine, cache_state) must exist " +
                      "after migrating from v25 and must be readable on the surviving v25 row")
    }

    // MARK: - v27 → head

    /// WHY: v27 introduces rc_reversible_content (CCR store). Users who stored
    /// compressed blocks at v27 expect those blocks to remain retrievable after
    /// upgrading; a migration that drops the table destroys the recovery path for
    /// every compressed message in the user's history.
    func test_v27_to_head_ccrRowSurvives() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 27)

        try db.execute("""
            INSERT INTO rc_reversible_content
                (handle, original, sha256, byte_count, ref_count, created_at_ms, last_access_ms)
            VALUES
                ('deadbeef', X'48656C6C6F', 'deadbeef', 5, 0, 1717200000000, 1717200000000);
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v27 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "rc_reversible_content"), 1,
                       "a v27 CCR block must survive migration to head — " +
                       "losing it destroys the recovery path for every compressed message referencing that handle")
    }

    // MARK: - v30 → head

    /// WHY: F8 pins encoder manifest storage to its own schema bump. A later
    /// migration must not collide with or recreate that table because the
    /// manifest is the hard license/runtime gate for optional encoder lanes.
    func test_v30_to_head_encoderManifestSurvives() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 30)

        try db.execute("""
            INSERT INTO token_saver_encoder_manifests
                (role, model_id, source_url, revision, runtime, license, max_seq_len, chunk_policy, manifest_json, installed_at)
            VALUES
                ('reranker', 'example/model', 'https://example.invalid/model', 'abc123', 'coreml', 'Apache-2.0', 8192, 'sliding-window', '{}', '2026-01-01T00:00:00Z');
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v30 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "token_saver_encoder_manifests"), 1,
                       "a v30 encoder manifest row must survive migration to head")
    }

    func test_tokenSaverSchemaStepsHaveExplicitStorageOrder() {
        let byVersion = Dictionary(uniqueKeysWithValues: Schema.steps.map { ($0.version, $0.sql) })

        XCTAssertTrue(byVersion[27]?.contains("rc_reversible_content") == true)
        XCTAssertTrue(byVersion[28]?.contains("ALTER TABLE token_saver_savings ADD COLUMN cache_state") == true)
        XCTAssertTrue(byVersion[29]?.contains("always_allow_pairing") == true,
                      "v29 is already consumed by pairing and must not be reused by Token Saver storage")
        XCTAssertTrue(byVersion[30]?.contains("token_saver_encoder_manifests") == true)
        XCTAssertTrue(byVersion[31]?.contains("shared_memory_blocks") == true)
    }

    // MARK: - head → head (idempotent re-run)

    func test_v38_to_head_preservesQueuedRowsAndInitializesDispatchState() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 38 })
        // Insert with the v38 column set — AgentThreadRepository.upsert always
        // targets HEAD columns (e.g. run_as_user_json) and cannot write a
        // mid-migration schema.
        let threadId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let threadInsert = try db.prepare("""
            INSERT INTO agent_threads(
                id, title, provider, model, status, created_at, updated_at,
                diff_additions, diff_deletions, has_unread, pinned, sort_order,
                permission_mode, reasoning_effort, execution_mode, service_tier,
                interaction_mode
            ) VALUES(?, 'queue migration', 'codex', 'gpt', 'pending', ?, ?, 0, 0, 0, 0, 0,
                     'supervised', 'medium', 'local', 'auto', 'default');
        """)
        try threadInsert.bind(1, threadId)
        try threadInsert.bind(2, now)
        try threadInsert.bind(3, now)
        _ = try threadInsert.step()
        let messageId = AgentQueuedMessageID()
        let insert = try db.prepare("""
            INSERT INTO agent_queued_messages(
                id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
            ) VALUES(?, ?, 'survive', '[]', 'default', 1, ?, ?);
        """)
        try insert.bind(1, messageId.value.uuidString)
        try insert.bind(2, threadId)
        try insert.bind(3, now)
        try insert.bind(4, now)
        _ = try insert.step()

        try Schema.migrateSteps(db, Schema.steps)

        let repo = AgentQueuedMessageRepository(db: db)
        XCTAssertEqual(try repo.get(id: messageId)?.text, "survive")
        XCTAssertEqual(try repo.dispatch(id: messageId)?.state, .queued,
                       "v39 must default existing queue rows to claimable queued state without replay metadata")
        XCTAssertNil(try repo.dispatch(id: messageId)?.runId)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
    }

    /// WHY: the app may call `Schema.migrate` on every launch. If re-running a
    /// fully-migrated DB threw, every launch after the first would crash. This
    /// test pins the idempotent guarantee for the full step list at head.
    func test_headToHead_isNoop() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "first migration must reach head")

        // Re-run: must not throw and must not change recorded state.
        XCTAssertNoThrow(try Schema.migrate(db),
                         "re-running migrate on a fully-migrated DB must not throw — " +
                         "a crash here would break every launch after the first")
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "re-running must not alter the recorded version")
    }

    func test_v67ToHeadAddsDurableRCW1ResponsesWithoutChangingMessages() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 67 })
        let threadId = UUID().uuidString
        let messageId = UUID().uuidString
        try db.execute("""
            INSERT INTO agent_threads(
                id, title, provider, model, status, created_at, updated_at,
                diff_additions, diff_deletions, has_unread, pinned, sort_order,
                permission_mode, reasoning_effort, execution_mode, service_tier,
                interaction_mode
            ) VALUES(
                '\(threadId)', 'v67', 'codex', 'test', 'completed',
                '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
                0, 0, 0, 0, 0, 'supervised', 'medium', 'local', 'auto', 'default'
            );
            INSERT INTO agent_messages(
                id, thread_id, role, content, created_at, attachments_json,
                body_sha256, body_bytes, body_revision
            ) VALUES(
                '\(messageId)', '\(threadId)', 'assistant', 'Readable',
                '2026-01-01T00:00:00Z', '[]', '', 8, 1
            );
            """)

        try Schema.migrateSteps(db, Schema.steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertEqual(try rowCount(db, table: "agent_messages"), 1,
                       "the canonical human transcript must survive the v68 migration")
        XCTAssertEqual(try rowCount(db, table: "agent_message_rcw1_responses"), 0,
                       "migration creates storage but never fabricates transport bytes")
    }

    func test_v59ToHeadDoesNotScrubTheCorpusInsideMigration() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 59 })
        let payload = "[\"\(String(repeating: "x", count: 128 * 1024))\"]"
        let states = [
            "prepared", "provider_created", "compensating",
            "local_committed", "compensated", "abandoned"
        ]
        for state in states {
            let insert = try db.prepare("""
                INSERT INTO agent_thread_fork_intents(
                    child_thread_id, source_thread_id, provider, idempotency_key,
                    state, child_thread_json, source_messages_json,
                    provider_child_thread_id, last_error, created_at, updated_at
                ) VALUES(?, ?, 'codex', ?, ?, '{}', ?, NULL, NULL, 'created', 'updated');
            """)
            try insert.bind(1, "child-\(state)")
            try insert.bind(2, "source-\(state)")
            try insert.bind(3, "key-\(state)")
            try insert.bind(4, state)
            try insert.bind(5, payload)
            _ = try insert.step()
        }

        var migrationSQL: [String] = []
        db.beforeExecuteForTesting = { migrationSQL.append($0) }
        try Schema.migrate(db)
        db.beforeExecuteForTesting = nil

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertFalse(migrationSQL.contains {
            $0.uppercased().contains("UPDATE AGENT_THREAD_FORK_INTENTS")
        }, "v59 -> head must never turn schema migration into a corpus-sized transcript write")
        let preserved = try db.prepare("""
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE source_messages_json = ?;
        """)
        try preserved.bind(1, payload)
        XCTAssertTrue(try preserved.step())
        XCTAssertEqual(preserved.columnInt64(0), Int64(states.count),
                       "schema-only migration must leave every payload byte untouched")
    }

    func test_v59LargeCorpusBootstrapReturnsThenBoundedWorkerEventuallyDrains() throws {
        let root = NSTemporaryDirectory() + "rc2-fork-intent-maintenance-benchmark-" + UUID().uuidString
        let dbPath = root + "/remotecode.sqlite"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let terminalPayload = "[\"" + String(repeating: "x", count: 256 * 1024) + "\"]"
        let terminalRows = 1_000
        let preservedPayloads = [
            "prepared": "[\"recoverable-prepared\"]",
            "provider_created": "[\"recoverable-provider-created\"]",
            "compensating": "[\"recoverable-compensating\"]",
            "abandoned": "[\"ambiguous-abandoned\"]"
        ]

        do {
            let seed = try SQLiteDB(path: dbPath)
            try Schema.migrateSteps(seed, Schema.steps.filter { $0.version <= 59 })
            try seed.transaction {
                let insert = try seed.prepare("""
                    INSERT INTO agent_thread_fork_intents(
                        child_thread_id, source_thread_id, provider, idempotency_key,
                        state, child_thread_json, source_messages_json,
                        provider_child_thread_id, last_error, created_at, updated_at
                    ) VALUES(?, ?, 'codex', ?, ?, '{}', ?, NULL, NULL, 'created', ?);
                """)
                for index in 0..<terminalRows {
                    insert.reset()
                    try insert.bind(1, String(format: "terminal-%04d", index))
                    try insert.bind(2, "source-\(index)")
                    try insert.bind(3, "key-\(index)")
                    try insert.bind(4, index.isMultiple(of: 2) ? "local_committed" : "compensated")
                    try insert.bind(5, terminalPayload)
                    try insert.bind(6, String(format: "%04d", index))
                    _ = try insert.step()
                }
                for (state, payload) in preservedPayloads {
                    insert.reset()
                    try insert.bind(1, "preserved-\(state)")
                    try insert.bind(2, "source-\(state)")
                    try insert.bind(3, "key-\(state)")
                    try insert.bind(4, state)
                    try insert.bind(5, payload)
                    try insert.bind(6, "preserved-\(state)")
                    _ = try insert.step()
                }
            }
            try seed.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }

        func fileBytes(_ path: String) -> Int64 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return 0 }
            return size.int64Value
        }
        func storageBytes() -> Int64 {
            fileBytes(dbPath) + fileBytes(dbPath + "-wal")
        }

        let beforeBytes = storageBytes()
        let sampleLock = NSLock()
        var peakBytes = beforeBytes
        let sampleQueue = DispatchQueue(label: "rc2-fork-intent-maintenance-storage-sampler")
        let sampler = DispatchSource.makeTimerSource(queue: sampleQueue)
        sampler.schedule(deadline: .now(), repeating: .milliseconds(1))
        sampler.setEventHandler {
            let bytes = storageBytes()
            sampleLock.lock()
            peakBytes = max(peakBytes, bytes)
            sampleLock.unlock()
        }
        sampler.resume()

        let gate = DispatchSemaphore(value: 0)
        let drained = expectation(description: "bounded maintenance drains historical terminal rows")
        let probe = ForkIntentMaintenanceProbe(firstBatchGate: gate, drainedExpectation: drained)
        let bootstrap = Bootstrap(channel: .debug, dbPathOverride: dbPath, appSupportOverride: root)
        bootstrap.beforeForkIntentMaintenanceBatchForTesting = { probe.beforeBatch() }
        bootstrap.forkIntentMaintenanceReceiptForTesting = { probe.record($0) }

        let startupBegan = Date()
        let (_, db) = try bootstrap.run()
        let startupWallSeconds = Date().timeIntervalSince(startupBegan)
        let remainingAtReturn = try AgentThreadRepository(db: db)
            .historicalForkIntentMaintenanceCandidateCount()
        sampleLock.lock()
        let startupPeakBytes = peakBytes
        sampleLock.unlock()

        XCTAssertEqual(remainingAtReturn, terminalRows,
                       "bootstrap must return while the corpus remains queued for background maintenance")
        XCTAssertEqual(db.maintenanceInstallCountForTesting, 1)
        XCTAssertFalse(db.installOwnedMaintenance(NoopSQLiteMaintenance()),
                       "one database connection must retain at most one maintenance loop")

        gate.signal()
        wait(for: [drained], timeout: 60)
        sampler.cancel()
        sampleQueue.sync {}
        sampleLock.lock()
        peakBytes = max(peakBytes, storageBytes())
        let eventualPeakBytes = peakBytes
        sampleLock.unlock()
        let afterBytes = storageBytes()

        let repository = AgentThreadRepository(db: db)
        XCTAssertEqual(try repository.historicalForkIntentMaintenanceCandidateCount(), 0)
        let successfulReceipts = probe.receipts.filter { $0.errorKind == nil }
        XCTAssertFalse(successfulReceipts.isEmpty)
        XCTAssertTrue(successfulReceipts.allSatisfy {
            $0.batchCount > 0
                && $0.batchCount <= AgentThreadRepository.terminalForkIntentCleanupBatchSize
        }, "every transaction must process between 1 and 16 rows")
        let receiptTimes = probe.receiptTimes
        XCTAssertGreaterThanOrEqual(receiptTimes.count, 2)
        let minimumDefaultInterBatchMilliseconds = zip(receiptTimes, receiptTimes.dropFirst())
            .map { previous, next in Double(next - previous) / 1_000_000 }
            .min() ?? 0
        XCTAssertGreaterThanOrEqual(
            minimumDefaultInterBatchMilliseconds,
            5,
            "the production 10ms success delay must pace every maintenance batch"
        )
        for (state, payload) in preservedPayloads {
            let row = try db.prepare("""
                SELECT source_messages_json, provider_creation_attempted
                FROM agent_thread_fork_intents WHERE child_thread_id = ?;
            """)
            try row.bind(1, "preserved-\(state)")
            XCTAssertTrue(try row.step())
            XCTAssertEqual(row.columnText(0), payload,
                           "recoverable and ambiguous payloads must remain byte-identical")
            XCTAssertEqual(row.columnInt64(1), 1)
        }

        print("FORK_INTENT_MAINTENANCE_LOCAL startup_wall_seconds=\(String(format: "%.3f", startupWallSeconds)) before_db_wal_bytes=\(beforeBytes) startup_peak_db_wal_bytes=\(startupPeakBytes) eventual_peak_db_wal_bytes=\(eventualPeakBytes) after_db_wal_bytes=\(afterBytes) terminal_rows=\(terminalRows) batch_limit=\(AgentThreadRepository.terminalForkIntentCleanupBatchSize) batches=\(successfulReceipts.count) minimum_default_inter_batch_ms=\(String(format: "%.3f", minimumDefaultInterBatchMilliseconds))")
    }

    func test_largeMaintenanceBacklogPacesBatchesSoForegroundDatabaseWorkProgresses() throws {
        let root = NSTemporaryDirectory() + "rc2-fork-intent-maintenance-fairness-" + UUID().uuidString
        let dbPath = root + "/remotecode.sqlite"
        defer { try? FileManager.default.removeItem(atPath: root) }

        do {
            let seed = try SQLiteDB(path: dbPath)
            try Schema.migrate(seed)
            try seed.transaction {
                let insert = try seed.prepare("""
                    INSERT INTO agent_thread_fork_intents(
                        child_thread_id, source_thread_id, provider, idempotency_key,
                        state, child_thread_json, source_messages_json,
                        provider_child_thread_id, last_error, created_at, updated_at,
                        provider_creation_attempted
                    ) VALUES(?, ?, 'codex', ?, 'compensated', '{}', '[]',
                             'provider-child', NULL, 'created', ?, 1);
                """)
                for index in 0..<1_000 {
                    insert.reset()
                    try insert.bind(1, String(format: "fairness-child-%04d", index))
                    try insert.bind(2, "fairness-source-\(index)")
                    try insert.bind(3, "fairness-key-\(index)")
                    try insert.bind(4, String(format: "%04d", index))
                    _ = try insert.step()
                }
            }
        }

        let firstReceipt = expectation(description: "first bounded batch completes")
        let secondReceipt = expectation(description: "second bounded batch completes after pacing")
        let probe = ForkIntentFairnessProbe(
            firstReceiptExpectation: firstReceipt,
            secondReceiptExpectation: secondReceipt
        )
        let bootstrap = Bootstrap(channel: .debug, dbPathOverride: dbPath, appSupportOverride: root)
        bootstrap.forkIntentMaintenanceSuccessDelayNanosecondsForTesting = 250_000_000
        bootstrap.forkIntentMaintenanceReceiptForTesting = { probe.record($0) }
        let (_, db) = try bootstrap.run()

        wait(for: [firstReceipt], timeout: 5)
        let foregroundStarted = DispatchTime.now().uptimeNanoseconds
        let foreground = try db.prepare("SELECT COUNT(*) FROM schema_meta;")
        XCTAssertTrue(try foreground.step())
        XCTAssertGreaterThan(foreground.columnInt64(0), 0)
        let foregroundMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - foregroundStarted
        ) / 1_000_000
        XCTAssertLessThan(foregroundMilliseconds, 100,
                          "foreground DB work must acquire operationLock during the success pacing window")
        XCTAssertEqual(probe.snapshot.receipts.count, 1,
                       "foreground DB work must finish before the next maintenance batch starts")

        wait(for: [secondReceipt], timeout: 5)
        let snapshot = probe.snapshot
        XCTAssertGreaterThanOrEqual(snapshot.receipts.count, 2)
        XCTAssertTrue(snapshot.receipts.prefix(2).allSatisfy {
            $0.batchCount > 0
                && $0.batchCount <= AgentThreadRepository.terminalForkIntentCleanupBatchSize
                && $0.hasMore
        }, "a 1000-row backlog must mutate at most 16 rows per transaction")
        let interBatchMilliseconds = Double(snapshot.times[1] - snapshot.times[0]) / 1_000_000
        XCTAssertGreaterThanOrEqual(interBatchMilliseconds, 200,
                                    "successful batches must not spin in a tight loop")
        print("FORK_INTENT_MAINTENANCE_FAIRNESS foreground_ms=\(String(format: "%.3f", foregroundMilliseconds)) inter_batch_ms=\(String(format: "%.3f", interBatchMilliseconds)) backlog_rows=1000 batch_limit=\(AgentThreadRepository.terminalForkIntentCleanupBatchSize)")
    }

    func test_v62MaintenanceQueryPlanUsesPartialUpdatedAtIndex() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let plan = try db.prepare("""
            EXPLAIN QUERY PLAN
            SELECT child_thread_id
            FROM agent_thread_fork_intents AS intent
                 INDEXED BY idx_agent_thread_fork_intents_maintenance
            WHERE (intent.state = 'local_committed'
                   OR intent.state = 'compensated'
                   OR intent.state = 'abandoned')
              AND ((intent.state = 'local_committed'
                    AND (intent.source_messages_json != '[]'
                         OR NOT EXISTS (
                             SELECT 1 FROM agent_threads AS child
                             WHERE child.id = intent.child_thread_id
                         )))
                   OR intent.state = 'compensated'
                   OR (intent.state = 'abandoned'
                       AND intent.provider_creation_attempted = 0))
            ORDER BY intent.updated_at ASC, intent.child_thread_id ASC
            LIMIT 17;
        """)
        var details: [String] = []
        while try plan.step() {
            if let detail = plan.columnText(3) { details.append(detail) }
        }
        XCTAssertTrue(details.contains {
            $0.contains("USING INDEX idx_agent_thread_fork_intents_maintenance")
        }, "v62 must serve ordered maintenance candidates from its partial index: \(details)")
        XCTAssertFalse(details.contains {
            $0.contains("USE TEMP B-TREE")
        }, "v62 must satisfy maintenance ordering without a temporary B-tree: \(details)")
    }

    func test_v80ToV81PreservesThreadsAndIndexesRunningThreadProjection() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 80 })

        let insert = try db.prepare("""
            INSERT INTO agent_threads(id, title, provider, model, status, created_at, updated_at)
            VALUES(?, ?, 'codex', 'gpt-test', ?, '2026-08-30T00:00:00Z', '2026-08-30T00:00:00Z');
        """)
        try db.transaction {
            for index in 0..<1_024 {
                insert.reset()
                try insert.bind(1, String(format: "00000000-0000-0000-0000-%012d", index + 1))
                try insert.bind(2, "v81-thread-\(index)")
                try insert.bind(3, index < 8 ? "running" : "completed")
                _ = try insert.step()
            }
        }

        let query = """
            EXPLAIN QUERY PLAN
            SELECT t.id, r.mode, r.configuration_json, r.revision
            FROM agent_threads AS t
            LEFT JOIN agent_thread_routing AS r ON r.thread_id = t.id
            WHERE t.status = 'running';
        """
        func planDetails() throws -> [String] {
            let plan = try db.prepare(query)
            defer { plan.reset() }
            var details: [String] = []
            while try plan.step() {
                if let detail = plan.columnText(3) { details.append(detail) }
            }
            return details
        }

        XCTAssertEqual(try maxVersion(db), 80)
        let before = try planDetails()
        XCTAssertTrue(before.contains("SCAN t"), "v80 must show the pre-index full-history scan: \(before)")

        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertEqual(try rowCount(db, table: "agent_threads"), 1_024,
                       "v80 to v81 must preserve every existing thread row")
        let expected = Set((0..<8).map {
            AgentThreadID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))!)
        })
        XCTAssertEqual(try AgentThreadRepository(db: db).runningThreadIds(), expected,
                       "the migrated running-ID projection must preserve the active rows")

        let after = try planDetails()
        XCTAssertTrue(
            after.contains { $0.contains("INDEX idx_agent_threads_running") },
            "v81 must use the partial running-thread index: \(after)"
        )
        XCTAssertFalse(
            after.contains { $0.contains("SCAN t") && !$0.contains("INDEX idx_agent_threads_running") },
            "v81 must remove the full-history scan from the production-shaped query: \(after)"
        )
    }

    func test_v81ToV82IndexesAuditLogActionIdForReceiptSignatureReads() throws {
        // WHY (perf X-01): the 2s Subagents badge poll reads a
        // (COUNT, MAX(id)) append signature over audit_log receipt rows to
        // skip re-decoding receipts when nothing changed; without an index that
        // signature read is itself a full-table scan over every detail blob.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 81 })

        let insert = try db.prepare(
            "INSERT INTO audit_log(ts, actor, action, detail) VALUES(?, 'RemoteCode', ?, ?);"
        )
        try db.transaction {
            for index in 0..<512 {
                insert.reset()
                try insert.bind(1, "2026-09-01T00:00:00Z")
                try insert.bind(2, index % 4 == 0 ? "other.action" : "agent.orchestration.admitted")
                try insert.bind(3, "{\"run\":\(index),\"detail\":\"\(String(repeating: "x", count: 900))\"}")
                _ = try insert.step()
            }
        }

        let query = """
            EXPLAIN QUERY PLAN
            SELECT COUNT(*), MAX(id) FROM audit_log
            WHERE action IN ('agent.orchestration.admitted', 'agent.orchestration.lifecycle');
        """
        func planDetails() throws -> [String] {
            let plan = try db.prepare(query)
            defer { plan.reset() }
            var details: [String] = []
            while try plan.step() {
                if let detail = plan.columnText(3) { details.append(detail) }
            }
            return details
        }

        XCTAssertEqual(try maxVersion(db), 81)
        let before = try planDetails()
        XCTAssertTrue(
            before.contains { $0.contains("SCAN audit_log") },
            "v81 must show the pre-index full-table scan: \(before)"
        )

        // Scope the migration to the step under test: a later head version must
        // not silently turn this v82 contract check into a head assertion.
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 82 })
        XCTAssertEqual(try maxVersion(db), 82)
        XCTAssertEqual(try rowCount(db, table: "audit_log"), 512,
                       "v81 to v82 must preserve every audit row")

        let after = try planDetails()
        XCTAssertTrue(
            after.contains { $0.contains("INDEX idx_audit_log_action_id") },
            "v82 must serve the receipt signature read from idx_audit_log_action_id: \(after)"
        )
        XCTAssertFalse(
            after.contains { $0.contains("SCAN audit_log") && !$0.contains("INDEX idx_audit_log_action_id") },
            "v82 must remove the full-table scan from the signature read: \(after)"
        )
    }

    func test_v82ToV83IndexesWorkspaceUpdatedAtForRailList() throws {
        // WHY (perf X-02): idle rail reloads ORDER BY updated_at DESC without
        // a matching index, so 300 threads SCAN. v83 adds
        // (workspace_id, updated_at DESC, id DESC).
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 82 })
        let workspaceID = WorkspaceID()
        let repo = AgentThreadRepository(db: db)
        for index in 0..<64 {
            try insertPreReasoningModelThread(db, AgentThread(
                workspaceId: workspaceID,
                title: "rail-\(index)",
                provider: .codex,
                model: "gpt-test"
            ))
        }

        let query = """
            EXPLAIN QUERY PLAN
            SELECT t.id
            FROM agent_threads t
            WHERE t.workspace_id = ?
            ORDER BY t.updated_at DESC, t.id DESC;
            """
        func planDetails() throws -> [String] {
            let plan = try db.prepare(query)
            try plan.bind(1, workspaceID.value.uuidString)
            defer { plan.reset() }
            var details: [String] = []
            while try plan.step() {
                if let detail = plan.columnText(3) { details.append(detail) }
            }
            return details
        }

        XCTAssertEqual(try maxVersion(db), 82)
        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        let after = try planDetails()
        XCTAssertTrue(
            after.contains { $0.contains("idx_agent_threads_workspace_updated") },
            "v83 must use the workspace+updated_at rail index: \(after)"
        )
        let listed = try repo.list(workspaceId: workspaceID)
        XCTAssertEqual(listed.count, 64)
        for window in zip(listed, listed.dropFirst()) {
            XCTAssertGreaterThanOrEqual(window.0.updatedAt, window.1.updatedAt)
        }
    }

    func test_oldV61MaintenanceRollsBackFailedBatchAndRetriesToDrain() throws {
        let root = NSTemporaryDirectory() + "rc2-fork-intent-v61-recovery-" + UUID().uuidString
        let dbPath = root + "/remotecode.sqlite"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let batchSize = AgentThreadRepository.terminalForkIntentCleanupBatchSize
        let candidateCount = batchSize + 2

        func scalar(_ db: SQLiteDB, _ sql: String) throws -> Int {
            let statement = try db.prepare(sql)
            defer { statement.reset() }
            guard try statement.step() else { return 0 }
            return Int(statement.columnInt64(0))
        }

        do {
            let legacy = try SQLiteDB(path: dbPath)
            try Schema.migrateSteps(legacy, Schema.steps.filter { $0.version <= 61 })
            let insert = try legacy.prepare("""
                INSERT INTO agent_thread_fork_intents(
                    child_thread_id, source_thread_id, provider, idempotency_key,
                    state, child_thread_json, source_messages_json,
                    provider_child_thread_id, last_error, created_at, updated_at
                ) VALUES(?, ?, 'codex', ?, ?, '{}', ?, 'provider-child', NULL, 'created', 'updated');
            """)
            for index in 0..<candidateCount {
                insert.reset()
                try insert.bind(1, String(format: "candidate-%04d", index))
                try insert.bind(2, "source-\(index)")
                try insert.bind(3, "key-\(index)")
                try insert.bind(4, index.isMultiple(of: 2) ? "compensated" : "local_committed")
                try insert.bind(5, "[\"historical terminal payload\"]")
                _ = try insert.step()
            }
            insert.reset()
            try insert.bind(1, "recoverable-prepared")
            try insert.bind(2, "source-recoverable")
            try insert.bind(3, "key-recoverable")
            try insert.bind(4, "prepared")
            try insert.bind(5, "[\"recoverable transcript\"]")
            _ = try insert.step()
            insert.reset()
            try insert.bind(1, "legacy-abandoned")
            try insert.bind(2, "source-abandoned")
            try insert.bind(3, "key-abandoned")
            try insert.bind(4, "abandoned")
            try insert.bind(5, "[]")
            _ = try insert.step()
            try legacy.execute("""
                INSERT INTO agent_threads(id, title, provider, model, status, created_at, updated_at)
                VALUES('candidate-\(String(format: "%04d", 1))', 'live child', 'codex', 'm', 'completed', 'created', 'updated');
            """)
            try legacy.execute("""
                CREATE TRIGGER fail_causal_fork_cleanup
                BEFORE DELETE ON agent_thread_fork_intents
                WHEN OLD.child_thread_id = 'candidate-\(String(format: "%04d", 2))'
                BEGIN SELECT RAISE(ABORT, 'injected causal cleanup failure'); END;
            """)
        }

        let failed = expectation(description: "one bounded batch reports failure")
        let drained = expectation(description: "retry drains after injected failure is removed")
        let probe = ForkIntentMaintenanceProbe(
            drainedExpectation: drained,
            errorExpectation: failed
        )
        let bootstrap = Bootstrap(channel: .debug, dbPathOverride: dbPath, appSupportOverride: root)
        bootstrap.forkIntentMaintenanceReceiptForTesting = { probe.record($0) }
        bootstrap.forkIntentMaintenanceRetryDelayNanosecondsForTesting = 500_000_000
        let (_, afterFailure) = try bootstrap.run()
        wait(for: [failed], timeout: 10)
        XCTAssertEqual(try scalar(afterFailure, "SELECT MAX(version) FROM schema_meta;"), Schema.currentVersion,
                       "an old v61 database must advance through v62 before maintenance")
        XCTAssertEqual(try scalar(afterFailure, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE state = 'compensated'
               OR (state = 'local_committed' AND child_thread_id != 'candidate-0001');
        """), candidateCount - 1,
                       "a failed batch must roll back every tentative terminal deletion")
        XCTAssertEqual(try scalar(afterFailure, """
            SELECT provider_creation_attempted FROM agent_thread_fork_intents
            WHERE child_thread_id = 'recoverable-prepared';
        """), 1,
                       "legacy recoverable rows default to ambiguous rather than becoming deletable")
        XCTAssertEqual(try scalar(afterFailure, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE child_thread_id = 'candidate-0001'
              AND source_messages_json = '[\"historical terminal payload\"]';
        """), 1, "the failed batch must also roll back a preceding live-child scrub")
        try afterFailure.execute("DROP TRIGGER fail_causal_fork_cleanup;")

        wait(for: [drained], timeout: 10)
        let firstDB = afterFailure
        XCTAssertEqual(try scalar(firstDB, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE state = 'compensated'
               OR (state = 'local_committed' AND child_thread_id != 'candidate-0001');
        """), 0)
        XCTAssertEqual(try scalar(firstDB, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE child_thread_id = 'recoverable-prepared'
              AND source_messages_json = '["recoverable transcript"]';
        """), 1,
                       "recoverable transcript payloads must survive every maintenance retry exactly")
        XCTAssertEqual(try scalar(firstDB, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE child_thread_id IN ('candidate-0001', 'legacy-abandoned');
        """), 2,
                       "a live local child and an unproven legacy abandonment are not cleanup candidates")
        XCTAssertEqual(try scalar(firstDB, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE child_thread_id = 'candidate-0001'
              AND source_messages_json = '[]';
        """), 1, "a live-child tombstone is scrubbed but never deleted")

        XCTAssertEqual(afterFailure.maintenanceInstallCountForTesting, 1)
        XCTAssertEqual(probe.receipts.filter { $0.errorKind != nil }.count, 1)
        XCTAssertTrue(probe.receipts.filter { $0.errorKind == nil }.allSatisfy {
            $0.batchCount <= batchSize
        })
        let secondDB = afterFailure
        XCTAssertEqual(try scalar(secondDB, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE state = 'compensated'
               OR (state = 'local_committed' AND child_thread_id != 'candidate-0001');
        """), 0,
                       "the next startup resumes from the remaining causal candidates without a cursor replay")
    }

    func test_maintenanceKeepsDatabaseAliveOnlyUntilInFlightBatchReturns() throws {
        let root = NSTemporaryDirectory() + "rc2-fork-intent-maintenance-lifetime-" + UUID().uuidString
        let dbPath = root + "/remotecode.sqlite"
        defer { try? FileManager.default.removeItem(atPath: root) }

        do {
            let seed = try SQLiteDB(path: dbPath)
            try Schema.migrate(seed)
            try seed.execute("""
                INSERT INTO agent_thread_fork_intents(
                    child_thread_id, source_thread_id, provider, idempotency_key,
                    state, child_thread_json, source_messages_json,
                    provider_child_thread_id, last_error, created_at, updated_at,
                    provider_creation_attempted
                ) VALUES('lifetime-child', 'lifetime-source', 'codex', 'lifetime-key',
                         'compensated', '{}', '[]', 'provider-child', NULL,
                         'created', 'updated', 1);
            """)
        }

        let beforeBatchGate = DispatchSemaphore(value: 0)
        let batchEntered = DispatchSemaphore(value: 0)
        let batchRelease = DispatchSemaphore(value: 0)
        let didDrain = expectation(description: "in-flight batch drains its final candidate")
        let didDeinitialize = expectation(description: "database deinitializes after in-flight batch")
        let probe = ForkIntentMaintenanceProbe(drainedExpectation: didDrain)
        let bootstrap = Bootstrap(channel: .debug, dbPathOverride: dbPath, appSupportOverride: root)
        bootstrap.beforeForkIntentMaintenanceBatchForTesting = { beforeBatchGate.wait() }
        bootstrap.forkIntentMaintenanceReceiptForTesting = { probe.record($0) }
        let weakDatabase = WeakSQLiteDBBox()
        try autoreleasepool {
            var database: SQLiteDB? = try bootstrap.run().1
            weakDatabase.value = database
            database?.onDeinitForTesting = { didDeinitialize.fulfill() }
            database?.beforeStatementStepForTesting = { sql in
                guard sql.contains("SELECT child_thread_id") else { return }
                weakDatabase.value?.beforeStatementStepForTesting = nil
                batchEntered.signal()
                batchRelease.wait()
            }

            beforeBatchGate.signal()
            XCTAssertEqual(batchEntered.wait(timeout: .now() + 5), .success)
            database = nil
        }
        XCTAssertNotNil(weakDatabase.value,
                        "the synchronous batch scope must prevent SQLite close while a statement is active")
        batchRelease.signal()
        wait(for: [didDrain, didDeinitialize], timeout: 5)
        XCTAssertNil(weakDatabase.value,
                     "no SQLiteDB reference may cross the worker's next await or keep its owner cycle alive")
    }

    // MARK: - Monotonically-increasing version numbers

    /// WHY: `migrateSteps` uses `version > current` to find pending steps. If any
    /// two SchemaSteps share the same version number, one of them would be silently
    /// skipped forever. This test pins that every step has a unique, strictly
    /// monotonically-increasing version so no step is ever silently skipped.
    func test_schemaSteps_versionsAreUniqueAndMonotonic() {
        let versions = Schema.steps.map(\.version)
        // Unique: a Set drops duplicates; if counts differ there are duplicates.
        XCTAssertEqual(versions.count, Set(versions).count,
                       "all SchemaStep version numbers must be unique — " +
                       "a duplicate version causes one step to be silently skipped forever")
        // Monotonically increasing.
        let sorted = versions.sorted()
        XCTAssertEqual(versions, sorted,
                       "SchemaStep versions must be in strictly ascending order — " +
                       "an out-of-order step skips or double-applies SQL depending on the applied cursor")
        // Last step must equal currentVersion.
        XCTAssertEqual(versions.last, Schema.currentVersion,
                       "the last SchemaStep version must equal Schema.currentVersion — " +
                       "a mismatch means currentVersion does not reflect the actual schema")
    }

    /// WHY: Bot attention cannot tell userStop from providerCancelled after
    /// restart without a durable reason. v77 must add a nullable column so an
    /// older binary can ignore it on downgrade.
    func test_v77AddsNullableAgentRunTerminalReasonWithoutRewritingRows() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 76 })
        XCTAssertEqual(try maxVersion(db), 76)
        let thread = AgentThread(title: "v77-reason", provider: .codex, model: "gpt-test")
        try insertPreReasoningModelThread(db, thread)
        let runId = UUID().uuidString
        try db.execute("""
            INSERT INTO agent_runs(id, thread_id, provider, model, status, started_at, finished_at)
            VALUES('\(runId)', '\(thread.id.value.uuidString)', 'codex', 'gpt-test', 'cancelled',
                   '2026-08-21T02:54:43Z', '2026-08-21T02:54:43Z');
            """)

        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 77 })
        XCTAssertEqual(try maxVersion(db), 77)
        let info = try db.prepare("PRAGMA table_info(agent_runs);")
        var names: [String] = []
        var terminalNotNull = 1
        while try info.step() {
            let name = info.columnText(1) ?? ""
            names.append(name)
            if name == "terminal_reason" {
                terminalNotNull = Int(info.columnInt64(3))
            }
        }
        XCTAssertTrue(names.contains("terminal_reason"))
        XCTAssertEqual(terminalNotNull, 0, "terminal_reason must stay nullable for downgrade")
        let loaded = try XCTUnwrap(
            AgentRunRepository(db: db).get(id: AgentRunID(UUID(uuidString: runId)!))
        )
        XCTAssertNil(loaded.terminalReason, "v77 must not invent a reason for pre-column rows")
        XCTAssertEqual(loaded.status, .cancelled)
    }

    /// WHY: the managed CLI retries one logical ledger POST when its first HTTP
    /// response is lost. v78 must preserve historical rows while giving new
    /// non-empty request identities a uniqueness fence.
    func test_v78AddsPartialUniqueSavingsIdempotencyWithoutCollidingHistoricalRows() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 77 })
        XCTAssertEqual(try maxVersion(db), 77)
        try db.execute("""
            INSERT INTO token_saver_savings
                (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms)
            VALUES
                ('claude', 'command-output', 10, 5, 5, '2026-08-21T00:00:00Z', 1),
                ('codex', 'command-output', 20, 5, 15, '2026-08-21T00:00:00Z', 2);
            """)

        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 78 })

        XCTAssertEqual(try maxVersion(db), 78)
        XCTAssertEqual(try rowCount(db, table: "token_saver_savings"), 2,
                       "v78 must retain every historical row with the empty default key")
        try db.execute("""
            INSERT INTO token_saver_savings
                (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms,
                 idempotency_key)
            VALUES
                ('grok', 'command-output', 30, 10, 20, '2026-08-21T00:00:00Z', 3,
                 'request-1');
            """)
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO token_saver_savings
                (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms,
                 idempotency_key)
            VALUES
                ('grok', 'command-output', 30, 10, 20, '2026-08-21T00:00:00Z', 4,
                 'request-1');
            """), "a non-empty logical request identity must be unique")
    }

    /// WHY: authenticated Token Saver metadata is user-visible workflow state.
    /// v79 must promote existing host rows before rolling stream retention can
    /// evict them, while keeping the durable record owned by its run.
    func test_v79BackfillsHostAttestationsAndCascadesWithRun() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 78 })
        XCTAssertEqual(try maxVersion(db), 78)
        let thread = AgentThread(title: "v79-host-proof", provider: .codex, model: "gpt-test")
        try insertPreReasoningModelThread(db, thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-test")
        try insertPreTerminalReasonRun(db, run)
        let proof = AssistantItemHostAttestation(
            itemType: .tool,
            body: AssistantContentFingerprint(
                byteCount: 4,
                sha256: Data(repeating: 1, count: 32)
            ),
            output: nil
        )
        let payload = String(decoding: try JSONEncoder().encode(
            AssistantEvent.itemHostMetadata(
                turnId: "turn",
                itemId: "item",
                distillApplied: true,
                attestation: proof
            )
        ), as: UTF8.self)
        let insert = try db.prepare("""
            INSERT INTO agent_stream_events(
                run_id, seq, event_kind, payload_json, created_at
            ) VALUES(?, 7, 'itemHostMetadata(turn/item distill=true)', ?, '2026-08-21T00:00:00Z');
            """)
        try insert.bind(1, run.id.value.uuidString)
        try insert.bind(2, payload)
        _ = try insert.step()

        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 79 })

        XCTAssertEqual(try maxVersion(db), 79)
        XCTAssertEqual(try rowCount(db, table: "agent_item_host_attestations"), 1,
                       "v79 must preserve an already-authenticated host row before pruning")
        let restored = try db.prepare("""
            SELECT seq, payload_json FROM agent_item_host_attestations
            WHERE run_id = ? LIMIT 1;
            """)
        try restored.bind(1, run.id.value.uuidString)
        XCTAssertTrue(try restored.step())
        XCTAssertEqual(restored.columnInt64(0), 7)
        XCTAssertEqual(restored.columnText(1), payload)

        let delete = try db.prepare("DELETE FROM agent_runs WHERE id = ?;")
        try delete.bind(1, run.id.value.uuidString)
        _ = try delete.step()
        XCTAssertEqual(try rowCount(db, table: "agent_item_host_attestations"), 0,
                       "durable proof must not outlive its owning run")
    }

    func test_v87ToV88AddsTeamsAndGroupsKeepingExistingConversationsUngrouped() throws {
        // WHY: v88 is additive. Every existing bot conversation must stay a
        // desk conversation (group_id NULL) and stay listed after upgrade, and
        // re-running the migration must be a no-op.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 87 })
        XCTAssertEqual(try maxVersion(db), 87)
        let botID = BotID()
        let conversationID = BotConversationID()
        try db.execute("""
            INSERT INTO bots(id, handle, name, title, description, avatar_symbol, created_at, updated_at)
            VALUES('\(botID.value.uuidString.lowercased())', 'piper', 'Piper', 'Scout', '', 'person',
                   '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
            INSERT INTO bot_conversations(id, bot_id, title, created_at, updated_at)
            VALUES('\(conversationID.value.uuidString.lowercased())', '\(botID.value.uuidString.lowercased())',
                   'Desk', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
            """)

        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 88)
        let listed = try BotStore(db: db).listConversations(botID: botID)
        XCTAssertEqual(listed.map(\.id), [conversationID])
        XCTAssertNil(listed.first?.groupID)
        for table in ["bot_teams", "bot_team_members", "bot_group_conversations",
                      "bot_group_participants", "bot_group_turns"] {
            XCTAssertEqual(try rowCount(db, table: table), 0, "\(table) must exist and start empty")
        }
        XCTAssertNoThrow(try Schema.migrateSteps(db, Schema.steps))
        XCTAssertEqual(try rowCount(db, table: "bot_conversations"), 1)

        // The CHECKs back the store's validation.
        let group = "INSERT INTO bot_group_conversations(id, title, room_thread_id, policy, max_auto_hops, created_at, updated_at) VALUES"
        XCTAssertThrowsError(try db.execute("\(group) ('g1', 't', 'r1', 'everyone', 4, 'x', 'x');"))
        XCTAssertThrowsError(try db.execute("\(group) ('g2', 't', 'r2', 'lead', 9, 'x', 'x');"))
        XCTAssertNoThrow(try db.execute("\(group) ('g3', 't', 'r3', 'mentions_only', 8, 'x', 'x');"))
        XCTAssertThrowsError(try db.execute("\(group) ('g4', 't', 'r3', 'lead', 0, 'x', 'x');"),
                             "one room thread belongs to one group")
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO bot_group_turns(id, group_id, round_id, bot_id, ordinal, state, room_message_id, created_at, updated_at)
            VALUES('t1', 'g3', 'r', 'b', 1, 'paused', 'm1', 'x', 'x');
            """))
    }

    func test_v88IsIdempotentWhenGroupColumnAlreadyExists() throws {
        // WHY: a sibling branch may ship the same column under another version;
        // a plain ADD COLUMN would then abort every launch.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 87 })
        try db.execute("ALTER TABLE bot_conversations ADD COLUMN group_id TEXT;")
        XCTAssertNoThrow(try Schema.migrateSteps(db, Schema.steps))
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertEqual(try rowCount(db, table: "bot_group_turns"), 0)
    }
}
