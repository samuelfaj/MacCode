import XCTest
@testable import Persistence
import CoreModel

/// Tests for AgentTurnCheckpointRepository.decodableCheckpoints (pure seam) and
/// listTolerant/list corruption tolerance.
///
/// WHY these tests matter:
///   - One corrupt checkpoint row in a thread must NOT hide the user's other good
///     checkpoints. Before this fix, list() threw on the first corrupt row, making
///     ALL checkpoints in that thread unreachable. The seam enforces the invariant:
///     healthy rows survive; corruptCount is always reported (never silently zero'd).
final class AgentTurnCheckpointRepositoryTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func makeThreadId() -> AgentThreadID {
        AgentThreadID(UUID())
    }

    /// Seeds the parent thread + run a checkpoint FK-references, returning the run id
    /// so the caller can attach checkpoints to it (DB round-trip tests only).
    private func seedThreadAndRun(db: SQLiteDB) throws -> (threadId: AgentThreadID, runId: AgentRunID) {
        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .running)
        try AgentRunRepository(db: db).upsert(run)
        return (thread.id, run.id)
    }

    private func seedThreadAndLegacyRun(db: SQLiteDB) throws -> (threadId: AgentThreadID, runId: AgentRunID) {
        // WHY: migration fixtures stop at the shared v56 base. They must seed a
        // row using only columns that actually existed then, not today's writer.
        let threadID = AgentThreadID(UUID())
        let now = ISO8601DateFormatter().string(from: Date())
        let threadInsert = try db.prepare("""
            INSERT INTO agent_threads(id, title, provider, model, status, created_at, updated_at)
            VALUES (?, 't', 'codex', 'm', 'pending', ?, ?);
            """)
        try threadInsert.bind(1, threadID.value.uuidString)
        try threadInsert.bind(2, now)
        try threadInsert.bind(3, now)
        _ = try threadInsert.step()
        let runID = AgentRunID()
        let insert = try db.prepare("""
            INSERT INTO agent_runs(id, thread_id, provider, model, status, started_at)
            VALUES (?, ?, 'codex', 'm', 'running', ?);
            """)
        try insert.bind(1, runID.value.uuidString)
        try insert.bind(2, threadID.value.uuidString)
        try insert.bind(3, now)
        _ = try insert.step()
        return (threadID, runID)
    }

    private func makeCheckpoint(
        threadId: AgentThreadID,
        turnCount: Int,
        turnId: String? = nil,
        runId: AgentRunID? = nil
    ) -> AgentTurnCheckpointSummary {
        AgentTurnCheckpointSummary(
            threadId: threadId,
            runId: runId ?? AgentRunID(UUID()),
            turnId: turnId ?? "turn-\(turnCount)",
            checkpointTurnCount: turnCount,
            checkpointRef: "ref-\(turnCount)",
            status: .ready,
            files: [],
            fileSnapshots: [],
            diffPatch: nil,
            fileDiffs: [],
            assistantMessageId: nil,
            errorMessage: nil,
            completedAt: Date(timeIntervalSince1970: Double(turnCount))
        )
    }

    // MARK: - Pure seam: decodableCheckpoints

    func testSeam_mixedValidCorrupt_returnsHealthyPlusCount() {
        // WHY: [valid, corrupt, valid] must yield 2 healthy and corruptCount=1.
        // This is the core invariant -- one bad row must not hide the surrounding good ones.
        let tid = makeThreadId()
        let cp1 = makeCheckpoint(threadId: tid, turnCount: 1)
        let cp2 = makeCheckpoint(threadId: tid, turnCount: 2)
        let fakeError = PersistenceDataError.corruptCheckpoint("bad json")

        let attempts: [Result<AgentTurnCheckpointSummary, Error>] = [
            .success(cp1),
            .failure(fakeError),
            .success(cp2)
        ]
        let result = AgentTurnCheckpointRepository.decodableCheckpoints(attempts)

        XCTAssertEqual(result.healthy.count, 2)
        XCTAssertEqual(result.corruptCount, 1)
        XCTAssertEqual(result.healthy[0].checkpointTurnCount, 1)
        XCTAssertEqual(result.healthy[1].checkpointTurnCount, 2)
    }

    func testSeam_allCorrupt_returnsEmptyPlusCount() {
        // WHY: a fully corrupt thread must yield empty healthy list and accurate count.
        let attempts: [Result<AgentTurnCheckpointSummary, Error>] = [
            .failure(PersistenceDataError.corruptCheckpoint("a")),
            .failure(PersistenceDataError.corruptCheckpoint("b"))
        ]
        let result = AgentTurnCheckpointRepository.decodableCheckpoints(attempts)

        XCTAssertEqual(result.healthy.count, 0)
        XCTAssertEqual(result.corruptCount, 2)
    }

    func testSeam_allValid_returnsAllPlusZeroCount() {
        // WHY: a fully healthy thread must pass through unchanged with corruptCount=0.
        let tid = makeThreadId()
        let attempts: [Result<AgentTurnCheckpointSummary, Error>] = [
            .success(makeCheckpoint(threadId: tid, turnCount: 1)),
            .success(makeCheckpoint(threadId: tid, turnCount: 2)),
            .success(makeCheckpoint(threadId: tid, turnCount: 3))
        ]
        let result = AgentTurnCheckpointRepository.decodableCheckpoints(attempts)

        XCTAssertEqual(result.healthy.count, 3)
        XCTAssertEqual(result.corruptCount, 0)
    }

    func testSeam_empty_returnsEmptyZeroCount() {
        let result = AgentTurnCheckpointRepository.decodableCheckpoints([])
        XCTAssertEqual(result.healthy.count, 0)
        XCTAssertEqual(result.corruptCount, 0)
    }

    func testSeam_preservesOrderOfHealthyRows() {
        // WHY: healthy rows must remain in original (checkpoint_turn_count ASC) order.
        // Out-of-order checkpoints would show the wrong restore point to the user.
        let tid = makeThreadId()
        let cp1 = makeCheckpoint(threadId: tid, turnCount: 1)
        let cp3 = makeCheckpoint(threadId: tid, turnCount: 3)
        let cp5 = makeCheckpoint(threadId: tid, turnCount: 5)
        let attempts: [Result<AgentTurnCheckpointSummary, Error>] = [
            .success(cp1),
            .failure(PersistenceDataError.corruptCheckpoint("turn 2")),
            .success(cp3),
            .failure(PersistenceDataError.corruptCheckpoint("turn 4")),
            .success(cp5)
        ]
        let result = AgentTurnCheckpointRepository.decodableCheckpoints(attempts)

        XCTAssertEqual(result.healthy.map(\.checkpointTurnCount), [1, 3, 5])
        XCTAssertEqual(result.corruptCount, 2)
    }

    // MARK: - listTolerant integration (DB round-trip)

    func testListTolerant_allValid_returnsAllZeroCount() throws {
        // WHY: listTolerant must not degrade the happy path -- all good rows come back.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        try repo.upsert(makeCheckpoint(threadId: tid, turnCount: 1, runId: rid))
        try repo.upsert(makeCheckpoint(threadId: tid, turnCount: 2, runId: rid))

        let result = try repo.listTolerant(threadId: tid)

        XCTAssertEqual(result.healthy.count, 2)
        XCTAssertEqual(result.corruptCount, 0)
    }

    func testListTolerant_emptyThread_returnsEmptyZeroCount() throws {
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let tid = makeThreadId()

        let result = try repo.listTolerant(threadId: tid)

        XCTAssertEqual(result.healthy.count, 0)
        XCTAssertEqual(result.corruptCount, 0)
    }

    // MARK: - latestAssistantMessageReference

    func testLatestAssistantMessageReference_latestCheckpointOfTheRunWins_withoutReadingBlobs() throws {
        // WHY: bot hand-off settles only need one run's assistant message id.
        // They used list(threadId:), which decodes every snapshot and diff of
        // the thread on the MainActor; the narrow read must give the same answer
        // (the run's latest checkpoint) without touching those columns.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let other = AgentRun(threadId: tid, provider: .codex, model: "m", status: .running)
        try AgentRunRepository(db: db).upsert(other)
        let big = [AgentTurnCheckpointFileSnapshot(
            path: "big.bin", kind: "file", contentsBase64: String(repeating: "A", count: 512 * 1024)
        )]
        let first = AgentMessageID(), latest = AgentMessageID(), otherReply = AgentMessageID()
        for (turn, run, message) in [(1, rid, first), (2, rid, latest), (3, other.id, otherReply)] {
            try repo.upsert(AgentTurnCheckpointSummary(
                threadId: tid, runId: run, turnId: "turn-\(turn)", checkpointTurnCount: turn,
                checkpointRef: "ref-\(turn)", status: .ready, files: [], fileSnapshots: big,
                assistantMessageId: message, completedAt: Date(timeIntervalSince1970: Double(turn))
            ))
        }
        let expected = try repo.list(threadId: tid).last(where: { $0.runId == rid })?.assistantMessageId
        XCTAssertEqual(expected, latest)
        var stepped: [String] = []
        db.beforeStatementStepForTesting = { stepped.append($0) }
        let fullReadsBefore = repo.fullRowListReadCountForTesting

        let reference = try XCTUnwrap(try repo.latestAssistantMessageReference(threadId: tid, runId: rid))

        XCTAssertEqual(reference.threadId, tid)
        XCTAssertEqual(reference.assistantMessageId, latest, "same answer as list(threadId:).last(where:)")
        XCTAssertEqual(repo.fullRowListReadCountForTesting, fullReadsBefore)
        XCTAssertFalse(stepped.contains { $0.contains("file_snapshots_json") || $0.contains("diff_patch") },
                       "the lookup must not select blob columns: \(stepped)")
        XCTAssertNil(try repo.latestAssistantMessageReference(threadId: tid, runId: AgentRunID()),
                     "a run with no checkpoint has no reply")
    }

    // MARK: - list backward-compat: now returns healthy only, does not throw on corrupt

    func testList_allValid_returnsAll() throws {
        // WHY: existing callers rely on list() returning all good checkpoints unchanged.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        try repo.upsert(makeCheckpoint(threadId: tid, turnCount: 1, runId: rid))
        try repo.upsert(makeCheckpoint(threadId: tid, turnCount: 2, runId: rid))

        let result = try repo.list(threadId: tid)

        XCTAssertEqual(result.count, 2)
    }

    // MARK: - listMetadataPage (response_version 1 projection)

    private func makeHeavyCheckpoint(
        threadId: AgentThreadID,
        turnCount: Int,
        turnId: String,
        runId: AgentRunID,
        completedAt: Date
    ) -> AgentTurnCheckpointSummary {
        AgentTurnCheckpointSummary(
            threadId: threadId,
            runId: runId,
            turnId: turnId,
            checkpointTurnCount: turnCount,
            checkpointRef: "ref-\(turnId)",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "a.swift", kind: "modified", additions: 1, deletions: 0)],
            fileSnapshots: [
                AgentTurnCheckpointFileSnapshot(
                    path: "a.swift",
                    kind: "modified",
                    contentsBase64: Data("HEAVY-SNAPSHOT-\(turnId)".utf8).base64EncodedString()
                )
            ],
            diffPatch: "diff --git a/a.swift b/a.swift\n+HEAVY-\(turnId)\n",
            fileDiffs: [AgentTurnCheckpointFileDiff(path: "a.swift", patch: "@@\n+HEAVY-\(turnId)\n")],
            assistantMessageId: nil,
            errorMessage: nil,
            completedAt: completedAt
        )
    }

    func testListMetadataPage_sqlProjectsLightColumnsWithLimit_andIgnoresCorruptHeavyBlobs() throws {
        // WHY: mobile/3G clients must not pay to read or decode file_snapshots_json,
        // diff_patch, or file_diffs_json. The observed SQL must prove explicit projection
        // + LIMIT, and corrupt heavy blobs must not poison the metadata result.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 1...3 {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: i,
                turnId: "turn-\(i)",
                runId: rid,
                completedAt: base.addingTimeInterval(TimeInterval(i))
            ))
        }

        // Corrupt the heavy columns after a normal upsert so list() would struggle
        // if those columns were selected; metadata page must still succeed.
        let corrupt = try db.prepare("""
            UPDATE agent_turn_checkpoints
            SET files_json = 'NOT-JSON{{{',
                file_snapshots_json = 'NOT-JSON{{{',
                diff_patch = 'x',
                file_diffs_json = '{bad'
            WHERE thread_id = ?;
        """)
        try corrupt.bind(1, tid.value.uuidString)
        _ = try corrupt.step()

        var observedSQL: [String] = []
        db.beforeStatementStepForTesting = { sql in
            if sql.contains("FROM agent_turn_checkpoints") {
                observedSQL.append(sql)
            }
        }
        defer { db.beforeStatementStepForTesting = nil }

        let page = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: nil)

        XCTAssertEqual(page.items.count, 2, "LIMIT max_entries must cap emitted items")
        XCTAssertTrue(page.truncated, "LIMIT max_entries+1 must detect another page")
        XCTAssertNotNil(page.nextBefore, "cursor of final emitted item only when another page exists")
        XCTAssertEqual(page.items.map(\.turnId), ["turn-3", "turn-2"],
                       "DESC keyset must emit newest checkpoint_turn_count first")
        for item in page.items {
            XCTAssertEqual(item.fileSnapshots, [], "metadata page must never surface snapshots")
            XCTAssertNil(item.diffPatch, "metadata page must never surface diff_patch")
            XCTAssertEqual(item.fileDiffs, [], "metadata page must never surface file diffs")
            XCTAssertEqual(item.files.count, 1, "bounded file summary metadata remains available")
        }
        XCTAssertEqual(page.filesTruncated, [false, false])

        let metadataSQL = observedSQL.first { $0.contains("LIMIT") && $0.contains("ORDER BY") }
        XCTAssertNotNil(metadataSQL, "metadata page must issue an ordered LIMIT query")
        let sql = metadataSQL ?? ""
        XCTAssertTrue(
            sql.contains("files_summary_json"),
            "production v1 projection must read only the capture-time bounded file summary"
        )
        XCTAssertFalse(
            sql.replacingOccurrences(of: "files_summary_json", with: "").contains("files_json"),
            "production v1 path must not select the authoritative full files_json"
        )
        XCTAssertFalse(sql.contains("file_snapshots_json"),
                       "production v1 path must not select file_snapshots_json")
        XCTAssertFalse(sql.contains("diff_patch"),
                       "production v1 path must not select diff_patch")
        XCTAssertFalse(sql.contains("file_diffs_json"),
                       "production v1 path must not select file_diffs_json")
        // WHY: SELECT must never materialize raw turn_id/checkpoint_ref/error_message
        // for up-to-101 page rows; only capture-time list_* projections are legal.
        let selectClause = sql.components(separatedBy: "FROM").first ?? sql
        let cleanedSelect = selectClause
            .replacingOccurrences(of: "list_turn_id_encoded_bytes", with: "")
            .replacingOccurrences(of: "list_turn_id_sha256", with: "")
            .replacingOccurrences(of: "list_turn_id_truncated", with: "")
            .replacingOccurrences(of: "list_turn_id", with: "")
            .replacingOccurrences(of: "list_checkpoint_ref_encoded_bytes", with: "")
            .replacingOccurrences(of: "list_checkpoint_ref_sha256", with: "")
            .replacingOccurrences(of: "list_checkpoint_ref_truncated", with: "")
            .replacingOccurrences(of: "list_checkpoint_ref", with: "")
            .replacingOccurrences(of: "list_error_message_encoded_bytes", with: "")
            .replacingOccurrences(of: "list_error_message_sha256", with: "")
            .replacingOccurrences(of: "list_error_message_truncated", with: "")
            .replacingOccurrences(of: "list_error_message", with: "")
        XCTAssertFalse(cleanedSelect.contains("turn_id"),
                       "page SELECT must exclude raw turn_id (ORDER BY may still reference it)")
        XCTAssertFalse(cleanedSelect.contains("checkpoint_ref"),
                       "page SELECT must exclude raw checkpoint_ref")
        XCTAssertFalse(cleanedSelect.contains("error_message"),
                       "page SELECT must exclude raw error_message")
        XCTAssertTrue(sql.contains("list_turn_id"),
                      "page SELECT must read capture-time projected turn id")
        XCTAssertTrue(sql.contains("list_checkpoint_ref"),
                      "page SELECT must read capture-time checkpoint_ref preview")
        XCTAssertTrue(sql.contains("list_error_message"),
                      "page SELECT must read capture-time error_message preview")
        XCTAssertTrue(sql.contains("LIMIT ?") || sql.contains("LIMIT"),
                      "must use LIMIT max_entries+1 paging")
        XCTAssertTrue(
            sql.contains("checkpoint_turn_count DESC")
                && sql.contains("list_completed_at DESC")
                && sql.contains("list_turn_id DESC"),
            "ORDER BY must use only the bounded DESC keyset"
        )
        XCTAssertFalse(
            sql.contains(" completed_at DESC") || sql.contains(" turn_id DESC"),
            "page source ordering must never read or compare raw metadata columns"
        )
    }

    func testUpsert_keepsAuthoritativeFilesAndPersistsBoundedMobileSummary() throws {
        // WHY: bounding only during serialization still forces every list refresh
        // to read and decode the complete files_json. Capture the mobile summary
        // once while leaving authoritative checkpoint metadata untouched.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let segment = String(repeating: "quote-\"-slash-\\-emoji-🙂-", count: 10)
        let files = (0..<200).map {
            AgentTurnCheckpointFile(
                path: "Sources/\(segment)\($0).swift",
                kind: "modified",
                additions: $0,
                deletions: $0 / 2
            )
        }
        let checkpoint = AgentTurnCheckpointSummary(
            threadId: tid,
            runId: rid,
            turnId: "bounded-summary",
            checkpointTurnCount: 1,
            checkpointRef: "ref",
            status: .ready,
            files: files,
            completedAt: Date(timeIntervalSince1970: 1_700_000_050)
        )
        try repo.upsert(checkpoint)
        XCTAssertLessThanOrEqual(
            repo.fileSummaryEncodedElementCountForTesting,
            AgentTurnCheckpointListWireProjection.maxFiles,
            "capture-time bounding must encode each admitted file at most once"
        )

        let lengths = try db.prepare("""
            SELECT length(files_json), length(files_summary_json), files_summary_truncated
            FROM agent_turn_checkpoints
            WHERE thread_id = ? AND turn_id = ?;
            """)
        try lengths.bind(1, tid.value.uuidString)
        try lengths.bind(2, checkpoint.turnId)
        XCTAssertTrue(try lengths.step())
        XCTAssertGreaterThan(Int(lengths.columnInt64(0)), 6 * 1_024)
        XCTAssertLessThanOrEqual(Int(lengths.columnInt64(1)), 6 * 1_024)
        XCTAssertEqual(lengths.columnInt64(2), 1)

        let page = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 1,
            before: nil
        )
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.filesTruncated, [true])
        XCTAssertGreaterThan(page.items[0].files.count, 0)
        XCTAssertLessThan(page.items[0].files.count, 64)
        XCTAssertEqual(
            try repo.list(threadId: tid).first?.files.count,
            200,
            "legacy/detail reads must retain the authoritative complete file list"
        )
    }

    func testListMetadataPage_tieBreaksOnTurnId_withoutDuplicatesAcrossPages() throws {
        // WHY: when checkpoint_turn_count and completed_at tie, turn_id is the only
        // deterministic final tie-breaker. Page boundaries must not skip or duplicate rows.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let sameCompleted = Date(timeIntervalSince1970: 1_700_000_100)
        // Same turn count + completed_at; lexicographic turn_id order: a < b < c < d
        for turnId in ["tie-a", "tie-b", "tie-c", "tie-d"] {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: 7,
                turnId: turnId,
                runId: rid,
                completedAt: sameCompleted
            ))
        }

        let first = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: nil)
        XCTAssertEqual(first.items.map(\.turnId), ["tie-d", "tie-c"],
                       "DESC turn_id tie-break must prefer larger turn_id first")
        XCTAssertTrue(first.truncated)
        guard let cursor = first.nextBefore else {
            return XCTFail("first page must expose next_before when truncated")
        }
        XCTAssertEqual(cursor.turnId, "tie-c")
        XCTAssertEqual(cursor.checkpointTurnCount, 7)

        let second = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: cursor)
        XCTAssertEqual(second.items.map(\.turnId), ["tie-b", "tie-a"],
                       "second page must continue after the cursor without duplicates")
        XCTAssertFalse(second.truncated)
        XCTAssertNil(second.nextBefore, "final page must not emit next_before")

        let allIds = first.items.map(\.turnId) + second.items.map(\.turnId)
        XCTAssertEqual(allIds, ["tie-d", "tie-c", "tie-b", "tie-a"])
        XCTAssertEqual(Set(allIds).count, 4, "pages must be duplicate-free across the keyset")
    }

    func testListMetadataPage_usesBoundedOversizedCursorAcrossMutation() throws {
        // WHY: an oversized provider turn id must not brick history or be echoed
        // unbounded. Its persisted bounded identity must resume the same source-
        // bounded SQL keyset after a between-page insert.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let sameCompleted = Date(timeIntervalSince1970: 1_700_000_200)
        let prefix = String(repeating: "oversized-\"-\\-🙂-", count: 40)
        func raw(_ suffix: String) -> String { prefix + suffix }
        for suffix in ["a", "b", "c", "d"] {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: 9,
                turnId: raw(suffix),
                runId: rid,
                completedAt: sameCompleted
            ))
        }

        let first = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 2,
            before: nil
        )
        let expectedWire = ["a", "b", "c", "d"].map {
            AgentTurnCheckpointWireIdentity.projectedTurnID(raw($0))
        }.sorted(by: >)
        XCTAssertEqual(first.items.map(\.turnId), Array(expectedWire.prefix(2)),
                       "list page must emit capture-time projected identities, not raw oversized turn ids")
        guard let rawCursor = first.nextBefore else {
            return XCTFail("oversized first page must expose a cursor")
        }
        XCTAssertTrue(AgentTurnCheckpointWireIdentity.isDigestIdentity(rawCursor.turnId))
        XCTAssertEqual(rawCursor.turnId, expectedWire[1])

        // Choose a bounded identity that sorts before the already-emitted boundary.
        // A between-page insert there must not leak into the continuation.
        let inserted = (0..<10_000).lazy.map { raw("insert-\($0)") }.first {
            AgentTurnCheckpointWireIdentity.projectedTurnID($0) > rawCursor.turnId
        }
        guard let inserted else {
            return XCTFail("fixture must find an identity before the cursor")
        }
        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 9,
            turnId: inserted,
            runId: rid,
            completedAt: sameCompleted
        ))
        var observedSQL: [String] = []
        db.beforeStatementStepForTesting = { sql in
            if sql.contains("FROM agent_turn_checkpoints") {
                observedSQL.append(sql)
            }
        }
        defer { db.beforeStatementStepForTesting = nil }

        let second = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 2,
            before: rawCursor
        )
        XCTAssertEqual(second.items.map(\.turnId), Array(expectedWire.suffix(2)))
        XCTAssertFalse(second.truncated)
        let combined = first.items.map(\.turnId) + second.items.map(\.turnId)
        XCTAssertEqual(Set(combined).count, 4)
        XCTAssertFalse(combined.contains(inserted))
        XCTAssertFalse(
            combined.contains(
                AgentTurnCheckpointWireIdentity.projectedTurnID(inserted)
            )
        )
        XCTAssertTrue(
            observedSQL.contains {
                $0.contains("checkpoint_turn_count = ?")
                    && $0.contains("list_completed_at = ?")
                    && $0.contains("list_turn_id < ?")
                    && !$0.contains("SELECT turn_id")
            },
            "continuation must compare only the bounded keyset"
        )
    }

    func testListMetadataPage_usesStoredBoundedProjections_notRawAtReadTime() throws {
        // WHY: list must ship capture-time projections. If a later mutation rewrites
        // raw turn_id/ref/error without recapturing list_*, list still returns the
        // stored bounded values and never re-hashes the adversarial raw columns.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let hugeTurn = String(repeating: "turn-\"-\\-🙂-", count: 40)
        let hugeRef = String(repeating: "ref-\"-\\-🙂-", count: 80)
        let hugeError = String(repeating: "err-\"-\\-🙂-", count: 100)
        let captured = AgentTurnCheckpointListWireProjection.capture(
            turnId: hugeTurn,
            checkpointRef: hugeRef,
            errorMessage: hugeError
        )
        try repo.upsert(AgentTurnCheckpointSummary(
            threadId: tid,
            runId: rid,
            turnId: hugeTurn,
            checkpointTurnCount: 1,
            checkpointRef: hugeRef,
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "a.swift", kind: "modified", additions: 1, deletions: 0)],
            errorMessage: hugeError,
            completedAt: Date(timeIntervalSince1970: 1_700_000_400)
        ))

        let poisonTurn = String(repeating: "POISON-TURN-", count: 80)
        let poisonRef = String(repeating: "POISON-REF-", count: 80)
        let poisonError = String(repeating: "POISON-ERR-", count: 80)
        let poison = try db.prepare("""
            UPDATE agent_turn_checkpoints
            SET turn_id = ?, checkpoint_ref = ?, error_message = ?
            WHERE thread_id = ?;
            """)
        try poison.bind(1, poisonTurn)
        try poison.bind(2, poisonRef)
        try poison.bind(3, poisonError)
        try poison.bind(4, tid.value.uuidString)
        _ = try poison.step()

        let page = try repo.listMetadataPage(threadId: tid, maxEntries: 1, before: nil)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].turnId, captured.turnId.value)
        XCTAssertEqual(page.items[0].checkpointRef, captured.checkpointRef.value)
        XCTAssertEqual(page.items[0].errorMessage, captured.errorMessage.value)
        XCTAssertEqual(page.listMetadata.count, 1)
        XCTAssertEqual(page.listMetadata[0], captured)
        XCTAssertNotEqual(page.items[0].turnId, poisonTurn)
        XCTAssertNotEqual(page.items[0].checkpointRef, poisonRef)
        XCTAssertNotEqual(page.items[0].errorMessage, poisonError)
        XCTAssertTrue(page.listMetadata[0].turnId.truncated)
        XCTAssertTrue(page.listMetadata[0].checkpointRef.truncated)
        XCTAssertTrue(page.listMetadata[0].errorMessage.truncated)
        XCTAssertEqual(page.listMetadata[0].turnId.sha256, captured.turnId.sha256)
        XCTAssertEqual(
            page.listMetadata[0].turnId.totalEncodedBytes,
            captured.turnId.totalEncodedBytes
        )

        // Legacy/detail path still sees the mutated authoritative raw columns.
        let legacy = try repo.list(threadId: tid)
        XCTAssertEqual(legacy.first?.turnId, poisonTurn)
        XCTAssertEqual(legacy.first?.checkpointRef, poisonRef)
        XCTAssertEqual(legacy.first?.errorMessage, poisonError)
    }

    func testListMetadataPage_fractionalCompletedAtPageBoundaryDoesNotSkipOrDuplicate() throws {
        // WHY: sub-second completed_at is part of the keyset. Truncating to whole
        // seconds collapses page boundaries and either duplicates or skips items.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let base = Date(timeIntervalSince1970: 1_700_000_500.0)
        for i in 0..<4 {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: i + 1,
                turnId: "frac-\(i)",
                runId: rid,
                completedAt: base.addingTimeInterval(Double(i) * 0.250)
            ))
        }

        let first = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: nil)
        XCTAssertEqual(first.items.map(\.turnId), ["frac-3", "frac-2"])
        XCTAssertTrue(first.truncated)
        guard let cursor = first.nextBefore else {
            return XCTFail("fractional first page must expose next_before")
        }
        // Cursor Date must retain the exact fractional instant of the boundary item.
        XCTAssertEqual(
            cursor.completedAt.timeIntervalSince1970,
            base.addingTimeInterval(0.500).timeIntervalSince1970,
            accuracy: 0.000_5
        )

        let second = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 2,
            before: cursor
        )
        XCTAssertEqual(second.items.map(\.turnId), ["frac-1", "frac-0"])
        XCTAssertFalse(second.truncated)
        let all = first.items.map(\.turnId) + second.items.map(\.turnId)
        XCTAssertEqual(all, ["frac-3", "frac-2", "frac-1", "frac-0"])
        XCTAssertEqual(Set(all).count, 4, "fractional keyset must not skip or duplicate")
    }

    func testMigratedRowsExposeExplicitUnavailableMetadataWithoutRawBackfill() throws {
        // WHY: migration must not scan raw large columns. A pre-checkpoint-list
        // row (shared base v56) remains visible/actionable through a stable
        // bounded surrogate while every unavailable metadata total/hash stays
        // honestly empty.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(
            db,
            Schema.steps.filter { $0.version <= Schema.sharedIntegrationBaseVersion }
        )
        let (tid, rid) = try seedThreadAndLegacyRun(db: db)
        let completed = Date(timeIntervalSince1970: 1_700_000_600)
        let insert = try db.prepare("""
            INSERT INTO agent_turn_checkpoints(
                thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status,
                files_json, assistant_message_id, error_message, completed_at, created_at,
                file_snapshots_json, diff_patch, file_diffs_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, '[]', NULL, '[]');
            """)
        try insert.bind(1, tid.value.uuidString)
        try insert.bind(2, rid.value.uuidString)
        try insert.bind(3, "legacy-turn")
        try insert.bind(4, Int64(1))
        try insert.bind(5, "legacy-ref")
        try insert.bind(6, "ready")
        try insert.bind(7, "[]")
        try insert.bind(8, "legacy-error")
        try insert.bind(9, ISO8601DateFormatter().string(from: completed))
        try insert.bind(10, ISO8601DateFormatter().string(from: completed))
        _ = try insert.step()
        try Schema.migrateSteps(db, Schema.steps)

        let repo = AgentTurnCheckpointRepository(db: db)
        let page = try repo
            .listMetadataPage(threadId: tid, maxEntries: 1, before: nil)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertTrue(page.items[0].turnId.hasPrefix("rc2-legacy-row:"))
        XCTAssertEqual(page.items[0].turnId.utf8.count, 47)
        XCTAssertEqual(page.items[0].checkpointRef, "")
        XCTAssertNil(page.items[0].errorMessage)
        XCTAssertEqual(page.items[0].checkpointTurnCount, 1)
        XCTAssertEqual(page.listMetadata.count, 1)
        XCTAssertTrue(page.listMetadata[0].metadataUnavailable)
        XCTAssertTrue(page.listMetadata[0].turnId.truncated)
        XCTAssertTrue(page.listMetadata[0].checkpointRef.truncated)
        XCTAssertTrue(page.listMetadata[0].errorMessage.truncated)
        XCTAssertEqual(page.listMetadata[0].turnId.totalEncodedBytes, 0)
        XCTAssertNil(page.listMetadata[0].turnId.sha256)
        XCTAssertEqual(page.listMetadata[0].checkpointRef.totalEncodedBytes, 0)
        XCTAssertNil(page.listMetadata[0].checkpointRef.sha256)
        XCTAssertEqual(page.listMetadata[0].errorMessage.totalEncodedBytes, 0)
        XCTAssertNil(page.listMetadata[0].errorMessage.sha256)
        XCTAssertEqual(page.filesTruncated, [true])
        XCTAssertEqual(page.completedAtTokens, ["2023-11-14T22:23:20.000Z"])
        XCTAssertEqual(
            try repo.get(threadId: tid, checkpointTurnCount: 1)?.turnId,
            "legacy-turn",
            "turn-count actions must still resolve the authoritative legacy row"
        )
    }

    func testListMetadataPageFailsLoudOnInvalidBoundedRunStatusOrDate() throws {
        // WHY: UUID(), Date(), and `.error` fallbacks make identical corrupt rows
        // produce different successful pages. The bounded source must reject
        // corrupt scalar metadata instead of inventing identity, time, or state.
        for (column, value) in [
            ("run_id", "not-a-uuid"),
            ("status", "not-a-checkpoint-status"),
            ("list_completed_at", "not-a-fixed-iso-token"),
        ] {
            let db = try makeDB()
            let repo = AgentTurnCheckpointRepository(db: db)
            let (tid, rid) = try seedThreadAndRun(db: db)
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: 1,
                turnId: "turn-\(column)",
                runId: rid,
                completedAt: Date(timeIntervalSince1970: 1_700_000_650)
            ))
            if column == "run_id" {
                // Corruption can come from an old/manual DB even though current
                // writes are FK-protected; disable the guard only to construct it.
                try db.execute("PRAGMA foreign_keys = OFF;")
            }
            let corrupt = try db.prepare("""
                UPDATE agent_turn_checkpoints
                SET \(column) = ?
                WHERE thread_id = ?;
                """)
            try corrupt.bind(1, value)
            try corrupt.bind(2, tid.value.uuidString)
            _ = try corrupt.step()

            for attempt in 1...2 {
                XCTAssertThrowsError(
                    try repo.listMetadataPage(
                        threadId: tid,
                        maxEntries: 1,
                        before: nil
                    ),
                    "\(column) attempt \(attempt) must fail instead of fabricating metadata"
                ) { error in
                    XCTAssertTrue(
                        error is PersistenceDataError,
                        "\(column) must surface a typed corrupt-checkpoint failure"
                    )
                }
            }
        }
    }

    func testListMetadataPageFailsLoudBeforeMaterializingHostileBoundedProjections() throws {
        // WHY: list_* and files_summary_json are persisted optimization columns,
        // not trusted input. A manually damaged/old database must not make the
        // metadata-only cellular path allocate an unbounded Swift String, nor may
        // inconsistent totals/flags be serialized as an apparently valid page.
        let hostile = String(repeating: "hostile-🙂-\"-\\-", count: 16_384)
        let corruptions: [(label: String, column: String, value: String)] = [
            ("oversized projected turn id", "list_turn_id", hostile),
            ("oversized projected checkpoint ref", "list_checkpoint_ref", hostile),
            ("oversized projected error", "list_error_message", hostile),
            ("oversized file summary", "files_summary_json", hostile),
            ("oversized projection hash", "list_turn_id_sha256", hostile),
            (
                "inconsistent nontruncated total",
                "list_checkpoint_ref_encoded_bytes",
                "999"
            ),
            ("invalid projection flag", "list_turn_id_truncated", "2"),
            ("invalid files flag", "files_summary_truncated", "2"),
        ]

        for corruption in corruptions {
            let db = try makeDB()
            let repo = AgentTurnCheckpointRepository(db: db)
            let (tid, rid) = try seedThreadAndRun(db: db)
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: 1,
                turnId: "turn-\(corruption.column)",
                runId: rid,
                completedAt: Date(timeIntervalSince1970: 1_700_000_675)
            ))
            let corrupt = try db.prepare("""
                UPDATE agent_turn_checkpoints
                SET \(corruption.column) = ?
                WHERE thread_id = ?;
                """)
            try corrupt.bind(1, corruption.value)
            try corrupt.bind(2, tid.value.uuidString)
            _ = try corrupt.step()

            for attempt in 1...2 {
                XCTAssertThrowsError(
                    try repo.listMetadataPage(
                        threadId: tid,
                        maxEntries: 1,
                        before: nil
                    ),
                    "\(corruption.label) attempt \(attempt) must fail closed"
                ) { error in
                    XCTAssertTrue(
                        error is PersistenceDataError,
                        "\(corruption.label) must surface typed persisted corruption"
                    )
                }
            }
        }
    }

    func testListMetadataPage_mixedLegacyAndCapturedRowsPaginatesWithoutLoss() throws {
        // WHY: an upgraded DB is mixed until old checkpoints age out. v1 must
        // return every old and new row exactly once while making unavailable
        // metadata distinguishable from ordinary truncation.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(
            db,
            Schema.steps.filter { $0.version <= Schema.sharedIntegrationBaseVersion }
        )
        let (tid, rid) = try seedThreadAndLegacyRun(db: db)
        let insert = try db.prepare("""
            INSERT INTO agent_turn_checkpoints(
                thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status,
                files_json, completed_at, created_at, file_snapshots_json, file_diffs_json
            ) VALUES (?, ?, ?, ?, ?, 'ready', '[]', ?, ?, '[]', '[]');
            """)
        for count in [1, 3, 5] {
            insert.reset()
            try insert.bind(1, tid.value.uuidString)
            try insert.bind(2, rid.value.uuidString)
            try insert.bind(3, "legacy-\(count)")
            try insert.bind(4, Int64(count))
            try insert.bind(5, "legacy-ref-\(count)")
            let token = ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: Double(1_700_001_000 + count))
            )
            try insert.bind(6, token)
            try insert.bind(7, token)
            _ = try insert.step()
        }
        try Schema.migrateSteps(db, Schema.steps)
        let repo = AgentTurnCheckpointRepository(db: db)
        for count in [2, 4, 6] {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: count,
                turnId: "captured-\(count)",
                runId: rid,
                completedAt: Date(timeIntervalSince1970: Double(1_700_001_000 + count))
            ))
        }

        var cursor: AgentTurnCheckpointCursor?
        var counts: [Int] = []
        var unavailable: [Bool] = []
        repeat {
            let page = try repo.listMetadataPage(
                threadId: tid,
                maxEntries: 2,
                before: cursor
            )
            counts.append(contentsOf: page.items.map(\.checkpointTurnCount))
            unavailable.append(
                contentsOf: page.listMetadata.map(\.metadataUnavailable)
            )
            cursor = page.nextBefore
            if !page.truncated { break }
        } while cursor != nil

        XCTAssertEqual(counts, [6, 5, 4, 3, 2, 1])
        XCTAssertEqual(Set(counts).count, 6, "mixed keyset must not skip or duplicate")
        XCTAssertEqual(unavailable, [false, true, false, true, false, true])
    }

    func testUpsertFailsLoudOnProjectedKeysetIdentityCollision() throws {
        // WHY: even a deliberately constructed digest alias must fail loud at
        // capture; a non-unique bounded keyset could skip a row on continuation.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let completed = Date(timeIntervalSince1970: 1_700_000_300)
        let oversized = String(repeating: "collision-source-🙂", count: 40)
        let digestIdentity = AgentTurnCheckpointWireIdentity.projectedTurnID(oversized)
        XCTAssertTrue(AgentTurnCheckpointWireIdentity.isDigestIdentity(digestIdentity))
        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 11,
            turnId: oversized,
            runId: rid,
            completedAt: completed
        ))
        XCTAssertThrowsError(try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 11,
            turnId: digestIdentity,
            runId: rid,
            completedAt: completed
        )))
    }

    func testWireIdentityEncodedByteCountMatchesJSONEncoderForEscapedAndUnicodeStrings() throws {
        // WHY: every metadata cap and disclosed total is expressed in actual wire
        // bytes. A hand-counting drift for escaping or multi-byte scalars could let
        // one adversarial checkpoint exceed the mobile response budget.
        let values = [
            "",
            "plain",
            "\"/\\\u{8}\t\n\u{c}\r\u{1}",
            "accent-é emoji-🙂 separator-\u{2028}"
        ]

        for value in values {
            XCTAssertEqual(
                AgentTurnCheckpointWireIdentity.encodedJSONStringByteCount(value),
                try JSONEncoder().encode(value).count,
                "wire byte count drifted for \(String(reflecting: value))"
            )
        }
    }

    func testProjectionStopsAtFirstOversizedGrapheme() {
        // WHY: a single extended grapheme can exceed the preview cap. The bounded
        // prefix must stop there; admitting a later small character would persist
        // the oversized grapheme and make checkpoint-list reads fail closed.
        let oversizedGrapheme = "e" + String(repeating: "\u{301}", count: 600)
        let raw = oversizedGrapheme + "x"

        let projected = AgentTurnCheckpointListWireProjection.projectString(
            raw,
            maximumEncodedBytes: AgentTurnCheckpointListWireProjection.maxEncodedErrorMessageBytes
        )

        XCTAssertTrue(projected.truncated)
        XCTAssertEqual(projected.value, "")
        XCTAssertGreaterThan(projected.totalEncodedBytes, AgentTurnCheckpointListWireProjection.maxEncodedErrorMessageBytes)
        XCTAssertLessThanOrEqual(
            AgentTurnCheckpointWireIdentity.encodedJSONStringByteCount(projected.value ?? ""),
            AgentTurnCheckpointListWireProjection.maxEncodedErrorMessageBytes
        )
    }

    func testProjectionStopsAfterOversizedGraphemeEvenWhenPrefixFits() {
        // WHY: a bounded prefix may contain a valid small grapheme before the next
        // grapheme exceeds the byte cap. Once that boundary is reached, a later
        // suffix must not be admitted or the projection is no longer a prefix.
        let oversizedGrapheme = "e" + String(repeating: "\u{301}", count: 600)
        let raw = "a" + oversizedGrapheme + "x"

        let projected = AgentTurnCheckpointListWireProjection.projectString(
            raw,
            maximumEncodedBytes: AgentTurnCheckpointListWireProjection.maxEncodedErrorMessageBytes
        )

        XCTAssertTrue(projected.truncated)
        XCTAssertEqual(projected.value, "a")
    }

    func testCatalogRevisionIncrementsTransactionallyWithInsertUpsertDelete() throws {
        // WHY: page fences must move with every mutation that can change list
        // fields/order; a non-transactional or O(N) digest would mix revisions.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let before = try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tid)

        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 1,
            turnId: "rev-insert",
            runId: rid,
            completedAt: Date(timeIntervalSince1970: 1_700_002_000)
        ))
        let afterInsert = try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tid)
        XCTAssertEqual(afterInsert, before + 1, "insert bumps exactly once")

        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 1,
            turnId: "rev-insert",
            runId: rid,
            completedAt: Date(timeIntervalSince1970: 1_700_002_001)
        ))
        let afterUpsert = try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tid)
        XCTAssertEqual(afterUpsert, afterInsert + 1, "list-emitted upsert bumps exactly once")

        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 2,
            turnId: "rev-second",
            runId: rid,
            completedAt: Date(timeIntervalSince1970: 1_700_002_002)
        ))
        let page = try repo.listMetadataPage(threadId: tid, maxEntries: 10, before: nil)
        XCTAssertEqual(
            page.catalogRevision,
            try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tid)
        )
        XCTAssertEqual(page.items.count, 2)

        try repo.deleteAfter(threadId: tid, checkpointTurnCount: 1)
        let afterDelete = try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tid)
        XCTAssertEqual(afterDelete, page.catalogRevision + 1, "single-row delete bumps once")
        let page2 = try repo.listMetadataPage(threadId: tid, maxEntries: 10, before: nil)
        XCTAssertEqual(page2.catalogRevision, afterDelete)
        XCTAssertEqual(page2.items.count, 1)
    }

    func testListMetadataPageRevisionStableAcrossSameRevisionRetry() throws {
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let base = Date(timeIntervalSince1970: 1_700_002_100.25)
        for n in 1...5 {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: n,
                turnId: "stable-\(n)",
                runId: rid,
                completedAt: base.addingTimeInterval(TimeInterval(n))
            ))
        }
        let first = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: nil)
        XCTAssertTrue(first.truncated)
        let cursor = try XCTUnwrap(first.nextBefore)
        let second = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 2,
            before: cursor
        )
        XCTAssertEqual(second.catalogRevision, first.catalogRevision)
        let retry = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 2,
            before: cursor
        )
        XCTAssertEqual(retry.catalogRevision, first.catalogRevision)
        XCTAssertEqual(
            retry.items.map(\.turnId),
            second.items.map(\.turnId),
            "same-revision retry must be stable"
        )
    }

    func testUnrelatedThreadMutationsDoNotInvalidateThreadAPagination() throws {
        // WHY: a busy thread B must never bump thread A's revision fence or
        // starve A's keyset walk mid-pagination.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tidA, ridA) = try seedThreadAndRun(db: db)
        let (tidB, ridB) = try seedThreadAndRun(db: db)
        let base = Date(timeIntervalSince1970: 1_700_003_000)
        for n in 1...6 {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tidA,
                turnCount: n,
                turnId: "A-\(n)",
                runId: ridA,
                completedAt: base.addingTimeInterval(TimeInterval(n))
            ))
        }
        let first = try repo.listMetadataPage(threadId: tidA, maxEntries: 2, before: nil)
        XCTAssertTrue(first.truncated)
        let revisionA = first.catalogRevision
        var collected = first.items.map(\.turnId)
        var cursor = try XCTUnwrap(first.nextBefore)

        var bTurn = 0
        while collected.count < 6 {
            // Continuously mutate unrelated thread B between every page of A.
            for _ in 0..<3 {
                bTurn += 1
                try repo.upsert(makeHeavyCheckpoint(
                    threadId: tidB,
                    turnCount: bTurn,
                    turnId: "B-\(bTurn)",
                    runId: ridB,
                    completedAt: base.addingTimeInterval(TimeInterval(100 + bTurn))
                ))
            }
            let page = try repo.listMetadataPage(
                threadId: tidA,
                maxEntries: 2,
                before: cursor
            )
            XCTAssertEqual(
                page.catalogRevision,
                revisionA,
                "thread B mutations must not invalidate thread A catalog revision"
            )
            collected.append(contentsOf: page.items.map(\.turnId))
            if page.truncated {
                cursor = try XCTUnwrap(page.nextBefore)
            } else {
                break
            }
        }
        XCTAssertEqual(collected, ["A-6", "A-5", "A-4", "A-3", "A-2", "A-1"])
        let revB = try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tidB)
        XCTAssertGreaterThan(revB, 1)
        XCTAssertEqual(
            try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tidA),
            revisionA
        )
    }

    func testSameThreadMutationBetweenPagesSurfacesStaleRevisionAtRepositoryFence() throws {
        // WHY: same-thread insert/delete between pages must advance the fence so
        // Dispatcher can return typed restart_once before mixing generations.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let base = Date(timeIntervalSince1970: 1_700_003_500)
        for n in 1...4 {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: n,
                turnId: "stale-\(n)",
                runId: rid,
                completedAt: base.addingTimeInterval(TimeInterval(n))
            ))
        }
        let first = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: nil)
        let cursor = try XCTUnwrap(first.nextBefore)
        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 99,
            turnId: "stale-new",
            runId: rid,
            completedAt: base.addingTimeInterval(99)
        ))
        let second = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 2,
            before: cursor
        )
        XCTAssertGreaterThan(second.catalogRevision, first.catalogRevision)
    }

    func testListMetadataPageUsesDeferredReadSnapshotWithoutPerRequestDDL() throws {
        // WHY: BEGIN IMMEDIATE would reserve the writer and serialize agent
        // upserts behind every list page. Per-request CREATE IF NOT EXISTS is
        // also writer DDL and belongs only in migration/setup.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 1,
            turnId: "read-seam",
            runId: rid,
            completedAt: Date(timeIntervalSince1970: 1_700_005_000)
        ))

        var executed: [String] = []
        db.beforeExecuteForTesting = { sql in executed.append(sql) }
        defer { db.beforeExecuteForTesting = nil }

        let page = try repo.listMetadataPage(threadId: tid, maxEntries: 10, before: nil)
        XCTAssertEqual(page.items.count, 1)

        let upper = executed.map { $0.uppercased() }
        XCTAssertTrue(
            upper.contains(where: { $0.contains("BEGIN DEFERRED") }),
            "list must open a deferred read snapshot: \(executed)"
        )
        XCTAssertFalse(
            upper.contains(where: { $0.contains("BEGIN IMMEDIATE") }),
            "list must not reserve the writer via BEGIN IMMEDIATE: \(executed)"
        )
        XCTAssertFalse(
            upper.contains(where: { $0.contains("CREATE ") }),
            "list/current must not run per-request DDL: \(executed)"
        )

        // current() alone must also stay free of DDL.
        executed.removeAll()
        _ = try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tid)
        let currentUpper = executed.map { $0.uppercased() }
        XCTAssertFalse(
            currentUpper.contains(where: { $0.contains("CREATE ") }),
            "CatalogRevision.current must not CREATE IF NOT EXISTS: \(executed)"
        )
    }

    func testStaleExpectedCatalogRevisionFailsBeforePageQueryDecode() throws {
        // WHY: a stale continuation must fail closed inside the same read
        // snapshot without paying for page row scan/decode work.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let base = Date(timeIntervalSince1970: 1_700_005_100)
        for n in 1...4 {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: n,
                turnId: "preclaim-\(n)",
                runId: rid,
                completedAt: base.addingTimeInterval(TimeInterval(n))
            ))
        }
        let first = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: nil)
        let cursor = try XCTUnwrap(first.nextBefore)
        let expected = first.catalogRevision

        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 99,
            turnId: "preclaim-new",
            runId: rid,
            completedAt: base.addingTimeInterval(99)
        ))

        var steppedSQL: [String] = []
        db.beforeStatementStepForTesting = { sql in steppedSQL.append(sql) }
        defer { db.beforeStatementStepForTesting = nil }

        XCTAssertThrowsError(
            try repo.listMetadataPage(
                threadId: tid,
                maxEntries: 2,
                before: cursor,
                expectedCatalogRevision: expected
            )
        ) { error in
            guard case AgentTurnCheckpointListError.staleCatalogRevision(let current) = error else {
                return XCTFail("expected staleCatalogRevision, got \(error)")
            }
            XCTAssertGreaterThan(current, expected)
        }

        // Only the revision SELECT may step — never the page projection SELECT.
        let pageSelects = steppedSQL.filter {
            $0.contains("FROM agent_turn_checkpoints")
                && $0.contains("list_turn_id")
        }
        XCTAssertEqual(
            pageSelects.count,
            0,
            "stale preclaim must not scan/decode page rows: \(steppedSQL)"
        )
        XCTAssertTrue(
            steppedSQL.contains(where: {
                $0.contains("agent_turn_checkpoint_catalog_meta")
            }),
            "revision must still be read inside the snapshot"
        )
    }

    func testDetailOnlyMutationDoesNotBumpCatalogRevision() throws {
        // WHY: rewriting non-emitted payloads (diff/snapshots/raw files_json)
        // must not spuriously invalidate an in-flight pagination session.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let completed = Date(timeIntervalSince1970: 1_700_003_800)
        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 1,
            turnId: "detail-only",
            runId: rid,
            completedAt: completed
        ))
        let before = try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tid)

        // Direct SQL rewrite of detail-only columns; list_* projections unchanged.
        let st = try db.prepare("""
            UPDATE agent_turn_checkpoints
            SET files_json = ?,
                file_snapshots_json = ?,
                diff_patch = ?,
                file_diffs_json = ?
            WHERE thread_id = ? AND turn_id = ?;
            """)
        try st.bind(1, #"[ {"path":"only-detail.swift","kind":"modified","additions":9,"deletions":0} ]"#)
        try st.bind(2, #"[{"path":"only-detail.swift","before":"a","after":"b"}]"#)
        try st.bind(3, "@@\n+detail-only\n")
        try st.bind(4, #"[{"path":"only-detail.swift","patch":"@@\n+x\n"}]"#)
        try st.bind(5, tid.value.uuidString)
        try st.bind(6, "detail-only")
        _ = try st.step()

        let after = try AgentTurnCheckpointCatalogRevision.current(db: db, threadId: tid)
        XCTAssertEqual(after, before, "detail-only rewrite must not bump list revision")
    }

    func testGatewayListMetadataPageNeverRunsOnMainThread() async throws {
        // WHY: Dispatcher/AppCommandRouter are @MainActor; SQLite query/decode
        // must hop to the gateway queue. Executor counters — not timing alone —
        // prove the off-main contract.
        let db = try makeDB()
        let gateway = AgentTurnCheckpointListGateway(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let repo = AgentTurnCheckpointRepository(db: db)
        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 1,
            turnId: "gw-1",
            runId: rid,
            completedAt: Date(timeIntervalSince1970: 1_700_004_000)
        ))

        AgentTurnCheckpointListGateway.resetExecutionProbesForTesting()
        AgentTurnCheckpointListGateway.queryDelayNanosecondsForTesting = 40_000_000
        defer { AgentTurnCheckpointListGateway.resetExecutionProbesForTesting() }

        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                heartbeats += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        let page = try await gateway.listMetadataPage(
            threadId: tid,
            maxEntries: 10,
            before: nil
        )
        heartbeat.cancel()
        _ = await heartbeat.result

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(AgentTurnCheckpointListGateway.queryCallCountForTesting, 1)
        XCTAssertEqual(AgentTurnCheckpointListGateway.queryOnMainActorCountForTesting, 0)
        XCTAssertEqual(AgentTurnCheckpointListGateway.queryOffMainActorCountForTesting, 1)
        XCTAssertGreaterThan(
            heartbeats,
            3,
            "MainActor run loop must keep pumping while gateway SQLite work is delayed"
        )
    }

    func testGatewayLegacyFullListNeverRunsOnMainThread() async throws {
        // WHY: an iPhone that falls back to the legacy agent.checkpoint.list
        // made the Mac read hundreds of MB of checkpoint blobs on MainActor,
        // freezing the host past the iPhone's 15 s snapshot deadline so the
        // phone stayed "connecting" forever. The full-row read must hop off main.
        let db = try makeDB()
        let gateway = AgentTurnCheckpointListGateway(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        try AgentTurnCheckpointRepository(db: db).upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 1,
            turnId: "gw-full-1",
            runId: rid,
            completedAt: Date(timeIntervalSince1970: 1_700_005_000)
        ))

        AgentTurnCheckpointListGateway.resetExecutionProbesForTesting()
        AgentTurnCheckpointListGateway.queryDelayNanosecondsForTesting = 40_000_000
        defer { AgentTurnCheckpointListGateway.resetExecutionProbesForTesting() }

        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                heartbeats += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        let rows = try await gateway.listFull(threadId: tid)
        heartbeat.cancel()
        _ = await heartbeat.result

        XCTAssertEqual(rows.map(\.turnId), ["gw-full-1"])
        XCTAssertFalse(rows[0].fileSnapshots.isEmpty, "legacy list keeps full rows")
        XCTAssertEqual(AgentTurnCheckpointListGateway.queryOnMainActorCountForTesting, 0)
        XCTAssertEqual(AgentTurnCheckpointListGateway.queryOffMainActorCountForTesting, 1)
        XCTAssertGreaterThan(
            heartbeats,
            3,
            "MainActor run loop must keep pumping while the legacy full list reads"
        )
    }
}
