import XCTest
@testable import Persistence
import CoreModel

/// Retention caps for high-volume tables.
/// WHY these tests matter:
///   - agent_provider_event_logs is unbounded per thread; without a cap it grows forever.
///   - terminal_output_chunks is unbounded per surface; a long-lived terminal session
///     can exhaust storage and memory. delete-on-close must remove all chunks for a surface.
final class RetentionCapTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func makeThread(db: SQLiteDB, title: String = "t") throws -> AgentThread {
        let thread = AgentThread(title: title, provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        return thread
    }

    private func makeRun(db: SQLiteDB, threadId: AgentThreadID) throws -> AgentRun {
        let run = AgentRun(threadId: threadId, provider: .codex, model: "m", status: .running)
        try AgentRunRepository(db: db).upsert(run)
        return run
    }

    /// The per-thread row cap applies to finished runs; a running run is bound by bytes only.
    private func makeFinishedRun(db: SQLiteDB, threadId: AgentThreadID) throws -> AgentRun {
        let run = AgentRun(threadId: threadId, provider: .codex, model: "m", status: .completed)
        try AgentRunRepository(db: db).upsert(run)
        return run
    }

    private func appendEvent(runs: AgentRunRepository, run: AgentRun, index: Int) throws {
        let event = ProviderRuntimeEvent(
            id: "evt-\(index)",
            provider: .codex,
            source: "codex.app-server",
            method: "item/completed",
            providerTurnId: "turn-\(index)",
            providerItemId: "item-\(index)",
            providerRequestId: nil,
            payloadJSON: #"{"i":\#(index)}"#,
            receivedAtMs: Int64(index)
        )
        try runs.appendProviderEventLog(threadId: run.threadId, runId: run.id, event: event)
    }

    // MARK: - agent_provider_event_logs

    func test_pruneProviderEventLogs_removesOldestDownToCap() throws {
        // WHY: inserting 20 events then capping at 10 must remove rows 0-9,
        // keeping only the newest 10. Validates the per-thread growth bound.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)

        for i in 0..<20 {
            try appendEvent(runs: runs, run: run, index: i)
        }

        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 20,
                       "pre-condition: 20 rows present before prune")

        try runs.pruneProviderEventLogs(threadId: thread.id, keepLatest: 10)

        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 10,
                       "prune must reduce count to the cap so the table cannot grow unboundedly per thread")

        let latest = try runs.listLatestProviderEventLogs(threadId: thread.id, limit: 20)
        XCTAssertEqual(latest.map(\.id), (10..<20).map { "evt-\($0)" },
                       "retained rows must be the newest N events, not a random subset")
    }

    func test_pruneProviderEventLogs_belowCapIsNoop() throws {
        // WHY: calling prune when count < cap must not delete anything — prune must
        // never silently discard events that are still within budget.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)

        for i in 0..<5 {
            try appendEvent(runs: runs, run: run, index: i)
        }

        try runs.pruneProviderEventLogs(threadId: thread.id, keepLatest: 100)

        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 5,
                       "prune with cap > count must be a no-op and must not remove any event")
    }

    func test_pruneProviderEventLogs_isolatesAcrossThreads() throws {
        // WHY: prune for threadA must not touch threadB's rows. Two threads share
        // the same table; a bug in the WHERE clause would silently lose another
        // thread's diagnostic evidence.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let threadA = try makeThread(db: db, title: "A")
        let threadB = try makeThread(db: db, title: "B")
        let runA = try makeRun(db: db, threadId: threadA.id)
        let runB = try makeRun(db: db, threadId: threadB.id)

        for i in 0..<15 { try appendEvent(runs: runs, run: runA, index: i) }
        for i in 0..<15 { try appendEvent(runs: runs, run: runB, index: i) }

        try runs.pruneProviderEventLogs(threadId: threadA.id, keepLatest: 5)

        XCTAssertEqual(try runs.countProviderEventLogs(threadId: threadA.id), 5,
                       "threadA must be pruned to cap")
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: threadB.id), 15,
                       "threadB must be untouched by a prune scoped to threadA")
    }

    // MARK: - terminal_output_chunks byte cap

    func test_pruneByteCap_removesOldestChunksUntilWithinBudget() throws {
        // WHY: a terminal surface that appends many chunks must stay within a byte
        // budget after pruning; the oldest chunks (smallest id) are sacrificed first
        // so the most-recent output is always what's visible to the user.
        let db = try makeDB()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = "surface-cap-test"

        // 5 chunks × 10 bytes each = 50 bytes total
        for i in 0..<5 {
            try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: Int64(i), data: Data("0123456789".utf8))
        }

        XCTAssertEqual(try repo.totalBytes(surfaceID: surfaceID), 50,
                       "pre-condition: 50 bytes present before prune")

        // Cap at 30 bytes: must delete oldest 2 chunks (20 bytes), keeping newest 3 (30 bytes).
        try repo.pruneByteCap(surfaceID: surfaceID, maxBytes: 30)

        XCTAssertLessThanOrEqual(try repo.totalBytes(surfaceID: surfaceID), 30,
                                 "byte cap prune must bring stored bytes within the budget")

        let window = try repo.readWindow(surfaceID: surfaceID, maxBytes: 256 * 1024)
        XCTAssertEqual(window.chunks.count, 3,
                       "three newest chunks must remain after pruning to 30-byte cap")
    }

    func test_pruneByteCap_belowBudgetIsNoop() throws {
        // WHY: pruning a surface already within the byte budget must not remove
        // anything — an over-eager prune would silently truncate valid scrollback.
        let db = try makeDB()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = "surface-noop"

        for i in 0..<3 {
            try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: Int64(i), data: Data("ab".utf8))
        }

        let before = try repo.totalBytes(surfaceID: surfaceID)
        try repo.pruneByteCap(surfaceID: surfaceID, maxBytes: 1024)
        XCTAssertEqual(try repo.totalBytes(surfaceID: surfaceID), before,
                       "pruneByteCap must be a no-op when total bytes are already within budget")
    }

    func test_pruneByteCap_isolatesAcrossSurfaces() throws {
        // WHY: pruning surfaceA must not delete chunks from surfaceB. Two terminal
        // surfaces share the same table; a scoping bug would silently erase another
        // surface's scrollback.
        let db = try makeDB()
        let repo = TerminalOutputRepository(db: db)
        let surfA = "surf-A"
        let surfB = "surf-B"

        for i in 0..<4 {
            try repo.append(surfaceID: surfA, workspaceID: nil, chunkIndex: Int64(i), data: Data("AAAA".utf8))
            try repo.append(surfaceID: surfB, workspaceID: nil, chunkIndex: Int64(i), data: Data("BBBB".utf8))
        }

        try repo.pruneByteCap(surfaceID: surfA, maxBytes: 8) // keep 2 × 4 bytes from A

        XCTAssertLessThanOrEqual(try repo.totalBytes(surfaceID: surfA), 8,
                                 "surfA must be within byte cap")
        XCTAssertEqual(try repo.totalBytes(surfaceID: surfB), 16,
                       "surfB must be untouched by a prune scoped to surfA")
    }

    // MARK: - terminal_output_chunks delete-on-close

    func test_deleteOnClose_removesAllChunksForSurface() throws {
        // WHY: when a terminal surface closes, all its chunks must be removed so
        // closed surfaces do not accumulate orphaned bytes indefinitely.
        let db = try makeDB()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = "surface-close"
        let otherID   = "surface-other"

        for i in 0..<5 {
            try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: Int64(i), data: Data("x".utf8))
        }
        try repo.append(surfaceID: otherID, workspaceID: nil, chunkIndex: 0, data: Data("y".utf8))

        try repo.delete(surfaceID: surfaceID)

        let window = try repo.readWindow(surfaceID: surfaceID, maxBytes: 256 * 1024)
        XCTAssertTrue(window.chunks.isEmpty,
                      "delete-on-close must remove all chunks for the closed surface so storage is reclaimed")

        // Other surface must be unaffected.
        let otherWindow = try repo.readWindow(surfaceID: otherID, maxBytes: 256 * 1024)
        XCTAssertEqual(otherWindow.chunks.count, 1,
                       "delete-on-close must not affect chunks belonging to other surfaces")
    }

    // MARK: - QA-mac:75 scripted heavy session -> whole-DB footprint stays bounded

    func test_heavySession_allRetentionCapsTogetherBoundTheDatabase() throws {
        // WHY: the per-cap tests prove each table is bounded in isolation. This is the
        // scripted-heavy-session integration QA-mac:75 asks for: drive ONE thread/surface
        // far past every cap, apply all three prunes, and assert every growth table lands
        // at/under its cap simultaneously -- i.e. a long-lived session cannot grow the DB
        // without bound. This composition is what "would have caught" the unbounded
        // agent_provider_event_logs / agent_stream_events / terminal_output_chunks growth.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeFinishedRun(db: db, threadId: thread.id)

        // Caps chosen small but exceeded by a wide margin (heavy load relative to cap),
        // so the assertion proves the bound regardless of how long the session runs.
        let providerCap = 100, streamCap = 100, terminalByteCap = 1_000
        let heavy = 250

        for i in 0..<heavy { try appendEvent(runs: runs, run: run, index: i) }          // provider event logs
        for i in 0..<heavy {                                                            // stream events
            try runs.appendStreamEvent(runId: run.id, seq: i, kind: "k", payloadJSON: #"{"i":\#(i)}"#)
        }
        let surfaceID = "surface-heavy"
        let chunkRepo = TerminalOutputRepository(db: db)
        for i in 0..<heavy {                                                            // terminal chunks: 250 x 10B = 2500B
            try chunkRepo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: Int64(i), data: Data("0123456789".utf8))
        }

        // Provider event logs and stream events are capped on the write path (the
        // rolling production window), so `heavy` appends never exceed the cap even
        // before an explicit prune. Terminal chunks are only bounded by the prune.
        XCTAssertGreaterThan(heavy, AgentEventRetentionPolicy.production.providerLogCountPerThread)
        XCTAssertGreaterThan(heavy, AgentEventRetentionPolicy.production.streamEventCountPerThread)
        XCTAssertLessThanOrEqual(try runs.countProviderEventLogs(threadId: thread.id),
                                 AgentEventRetentionPolicy.production.providerLogCountPerThread,
                                 "provider event logs must be bounded at write time during a heavy session")
        XCTAssertLessThanOrEqual(try runs.countStreamEvents(threadId: thread.id),
                                 AgentEventRetentionPolicy.production.streamEventCountPerThread,
                                 "stream events must be bounded at write time during a heavy session")
        XCTAssertGreaterThan(try chunkRepo.totalBytes(surfaceID: surfaceID), terminalByteCap)

        // Apply every retention cap, as the coordinator does on the write path.
        try runs.pruneProviderEventLogs(threadId: thread.id, keepLatest: providerCap)
        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: streamCap)
        try chunkRepo.pruneByteCap(surfaceID: surfaceID, maxBytes: terminalByteCap)

        // Post-condition: every growth table is bounded simultaneously.
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), providerCap,
                       "provider event logs must be capped at keepLatest after a heavy session")
        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), streamCap,
                       "stream events must be capped at keepLatest after a heavy session")
        XCTAssertLessThanOrEqual(try chunkRepo.totalBytes(surfaceID: surfaceID), terminalByteCap,
                       "terminal output bytes must stay within the byte cap after a heavy session")
    }

    func test_agentEventRetention_enforcesBytesAndCountAcrossManySmallRows() throws {
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)
        let streamPayload = String(repeating: "s", count: 100)
        let providerPayload = String(repeating: "p", count: 120)

        for index in 0..<40 {
            try runs.appendStreamEvent(runId: run.id, seq: index + 1, kind: "k", payloadJSON: streamPayload)
            try runs.appendProviderEventLog(
                threadId: thread.id,
                runId: run.id,
                event: ProviderRuntimeEvent(
                    id: "provider-\(index)",
                    provider: .codex,
                    source: "test",
                    method: "item/completed",
                    payloadJSON: providerPayload,
                    receivedAtMs: Int64(index)
                )
            )
        }

        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: 10, maxPayloadBytes: 350)
        try runs.pruneProviderEventLogs(threadId: thread.id, keepLatest: 10, maxPayloadBytes: 370)

        XCTAssertLessThanOrEqual(try runs.countStreamEvents(threadId: thread.id), 10)
        XCTAssertLessThanOrEqual(try runs.streamEventPayloadBytes(threadId: thread.id), 350,
                                 "encoded bytes, not only rows, must plateau")
        XCTAssertLessThanOrEqual(try runs.countProviderEventLogs(threadId: thread.id), 10)
        XCTAssertLessThanOrEqual(try runs.providerEventPayloadBytes(threadId: thread.id), 370)
    }

    func test_agentEventRetention_keepsNewestAndEvictsOldestUnderByteBudget() throws {
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)
        // ~700 KiB frames must admit under the 16 MB per-row ceiling (the prior
        // 512 KiB omit path is gone). Byte pressure reclaims OLDEST rows only.
        try runs.appendStreamEvent(
            runId: run.id,
            seq: 1,
            kind: "older",
            payloadJSON: String(repeating: "x", count: 12 * 1_024)
        )
        try runs.appendStreamEvent(
            runId: run.id,
            seq: 2,
            kind: "newest",
            payloadJSON: String(repeating: "y", count: 12 * 1_024)
        )

        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: 10, maxPayloadBytes: 16 * 1_024)

        // Newest must survive; total may still exceed budget if the newest alone
        // is large, but older rows must yield first.
        let kinds = try runs.listLatestStreamEvents(threadId: thread.id, limit: 10, strictDecoding: false)
        // Payloads are raw JSON strings of x/y, not AssistantEvent — list may fail
        // strict decode. Use payload byte accounting + count instead.
        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 1,
                       "byte pressure must drop the older row so the newest admits")
        XCTAssertLessThanOrEqual(try runs.streamEventPayloadBytes(threadId: thread.id), 16 * 1_024 + 64,
                                 "after reclaim, cumulative payload stays near the budget")
        _ = kinds
    }

    func test_providerEventPersistence_admitsLargeFramesAndSoftTruncatesOnlyAboveCeiling() throws {
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)
        let large = String(repeating: "p", count: 700 * 1_024)
        try runs.appendProviderEventLog(
            threadId: thread.id,
            runId: run.id,
            event: ProviderRuntimeEvent(
                id: "large-provider",
                provider: .codex,
                source: "test",
                method: "item/completed",
                payloadJSON: large,
                receivedAtMs: 1
            )
        )

        let replay = try runs.listLatestProviderEventLogs(threadId: thread.id, limit: 1)
        let event = try XCTUnwrap(replay.first)
        XCTAssertEqual(event.payloadJSON, large,
                       "700 KiB provider frames must admit fully under the 16 MB ceiling")
        XCTAssertFalse(event.payloadJSON.contains("event_size_limit"),
                       "no compact-error marker for admissible large frames")

        let pathological = String(repeating: "q", count: AgentRunRepository.maximumPersistedEventRowBytes + 40_000)
        try runs.appendProviderEventLog(
            threadId: thread.id,
            runId: run.id,
            event: ProviderRuntimeEvent(
                id: "pathological-provider",
                provider: .codex,
                source: "test",
                method: "item/completed",
                payloadJSON: pathological,
                receivedAtMs: 2
            )
        )
        // Stored row stays presentation-bounded (soft-truncate + handle).
        let st = try db.prepare(
            "SELECT payload_json FROM agent_provider_event_logs WHERE event_id = ? LIMIT 1;"
        )
        try st.bind(1, "pathological-provider")
        XCTAssertTrue(try st.step(), "pathological provider row must be persisted")
        let stored = try XCTUnwrap(st.columnText(0))
        XCTAssertLessThanOrEqual(stored.utf8.count, AgentRunRepository.maximumPersistedEventRowBytes)
        XCTAssertTrue(stored.contains("truncated"),
                      "stored form soft-truncates only above the absolute ceiling")
        XCTAssertTrue(stored.contains("[[rc:"),
                      "stored form must embed recoverable handle")

        // List path rehydrates to the byte-identical original (S3).
        let big = try XCTUnwrap(try runs.listLatestProviderEventLogs(threadId: thread.id, limit: 2)
            .first(where: { $0.id == "pathological-provider" }))
        XCTAssertEqual(big.payloadJSON, pathological,
                       "provider-log list must rehydrate oversized originals byte-identically")
    }

    func test_hotReplay_appliesEncodedByteAndCountHighWaterInFIFOOrder() throws {
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)
        let encoder = JSONEncoder()
        for index in 0..<30 {
            let event = AssistantEvent.turnStarted(turnId: "turn-\(index)-" + String(repeating: "x", count: 80))
            let json = String(decoding: try encoder.encode(event), as: UTF8.self)
            try runs.appendStreamEvent(runId: run.id, seq: index + 1, kind: event.debugDescription, payloadJSON: json)
        }

        let replay = try runs.listLatestStreamEvents(threadId: thread.id, limit: 5, maxPayloadBytes: 420)

        XCTAssertLessThanOrEqual(replay.count, 5)
        let ids = replay.compactMap { event -> String? in
            if case .turnStarted(let id) = event { return id }
            return nil
        }
        XCTAssertEqual(ids, ids.sorted { lhs, rhs in
            Int(lhs.split(separator: "-")[1])! < Int(rhs.split(separator: "-")[1])!
        }, "bounded hot replay must retain exact chronological FIFO order")
        XCTAssertTrue(ids.last?.hasPrefix("turn-29-") == true)
    }

    func test_multiThreadRetention_repeatedWavesPlateauLogicalAndPhysicalPages() throws {
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let manager = LocalStorageBudgetManager(db: db)
        var fixtures: [(AgentThread, AgentRun)] = []
        for index in 0..<6 {
            let thread = try makeThread(db: db, title: "thread-\(index)")
            fixtures.append((thread, try makeRun(db: db, threadId: thread.id)))
        }

        func writeAndPrune(wave: Int) throws {
            for (threadIndex, fixture) in fixtures.enumerated() {
                for offset in 0..<80 {
                    let seq = wave * 1_000 + offset + 1
                    try runs.appendStreamEvent(
                        runId: fixture.1.id,
                        seq: seq,
                        kind: "wave-\(wave)",
                        payloadJSON: String(repeating: "a", count: 256)
                    )
                    try runs.appendProviderEventLog(
                        threadId: fixture.0.id,
                        runId: fixture.1.id,
                        event: ProviderRuntimeEvent(
                            id: "wave-\(wave)-\(threadIndex)-\(offset)",
                            provider: .codex,
                            source: "plateau",
                            method: "item/completed",
                            payloadJSON: String(repeating: "b", count: 256),
                            receivedAtMs: Int64(seq)
                        )
                    )
                }
                try runs.pruneStreamEvents(threadId: fixture.0.id, keepLatest: 8, maxPayloadBytes: 2_048)
                try runs.pruneProviderEventLogs(threadId: fixture.0.id, keepLatest: 8, maxPayloadBytes: 2_048)
            }
        }

        try writeAndPrune(wave: 1)
        let first = try manager.snapshot()
        try writeAndPrune(wave: 2)
        let second = try manager.snapshot()

        for fixture in fixtures {
            XCTAssertEqual(try runs.countStreamEvents(threadId: fixture.0.id), 8)
            XCTAssertEqual(try runs.streamEventPayloadBytes(threadId: fixture.0.id), 2_048)
            XCTAssertEqual(try runs.countProviderEventLogs(threadId: fixture.0.id), 8)
            XCTAssertEqual(try runs.providerEventPayloadBytes(threadId: fixture.0.id), 2_048)
        }
        XCTAssertLessThanOrEqual(second.databaseBytes, first.databaseBytes + 64 * 1_024,
                                 "a repeated many-thread write/prune wave must reuse physical SQLite pages instead of preserving a linear slope")
    }

    func test_globalAgentQuotasDrainOldestAcrossThreadsInBoundedQuanta() throws {
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        var fixtures: [(AgentThread, AgentRun)] = []
        for index in 0..<4 {
            let thread = try makeThread(db: db, title: "global-\(index)")
            fixtures.append((thread, try makeRun(db: db, threadId: thread.id)))
        }
        for (threadIndex, fixture) in fixtures.enumerated() {
            for offset in 0..<6 {
                try runs.appendStreamEvent(
                    runId: fixture.1.id,
                    seq: offset + 1,
                    kind: "global",
                    payloadJSON: String(repeating: "s", count: 100)
                )
                try appendEvent(runs: runs, run: fixture.1, index: threadIndex * 100 + offset)
            }
        }
        let policy = AgentEventRetentionPolicy(
            streamEventBytesGlobal: 600,
            providerLogBytesGlobal: 100,
            pruneQuantumRows: 3,
            pruneQuantumBytes: 1_024
        )
        for _ in 0..<20 {
            _ = try runs.pruneGlobalEventPayloads(policy: policy)
        }
        let snapshot = try LocalStorageBudgetManager(db: db).snapshot()
        let stream = try XCTUnwrap(snapshot.classes.first { $0.storageClass == .streamEvents })
        let provider = try XCTUnwrap(snapshot.classes.first { $0.storageClass == .providerLogs })
        XCTAssertLessThanOrEqual(stream.payloadBytes, policy.streamEventBytesGlobal)
        XCTAssertLessThanOrEqual(provider.payloadBytes, policy.providerLogBytesGlobal)
        XCTAssertTrue(try fixtures.contains { try runs.streamHistoryWasPruned(threadId: $0.0.id) },
                      "global eviction must leave a durable partial-history signal instead of pretending the prefix still exists")
    }

    func test_globalAgentPruneUsesIncrementalCountersInsteadOfHotPathSUM() throws {
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)
        for index in 0..<2_000 {
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "counter",
                payloadJSON: String(repeating: "x", count: 64)
            )
        }

        var observedAggregateScan = false
        db.beforeStatementStepForTesting = { sql in
            if sql.uppercased().contains("SUM(") { observedAggregateScan = true }
        }
        defer { db.beforeStatementStepForTesting = nil }
        _ = try runs.pruneGlobalEventPayloads(policy: AgentEventRetentionPolicy(
            streamEventBytesGlobal: 1,
            providerLogBytesGlobal: 1,
            pruneQuantumRows: 16,
            pruneQuantumBytes: 4 * 1_024
        ))

        XCTAssertFalse(observedAggregateScan,
                       "global retention cadence must read O(1) usage counters, not rescan legacy tables")
    }

    func test_globalAgentNearMaximumEventsSelfDrainAcrossThreadsWithoutFurtherWrites() throws {
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        var fixtures: [(AgentThread, AgentRun)] = []
        for index in 0..<4 {
            let thread = try makeThread(db: db, title: "near-max-\(index)")
            fixtures.append((thread, try makeRun(db: db, threadId: thread.id)))
        }
        let payload = String(repeating: "x", count: 500 * 1_024)
        for fixture in fixtures {
            for sequence in 1...5 {
                try runs.appendStreamEvent(
                    runId: fixture.1.id,
                    seq: sequence,
                    kind: "near-maximum",
                    payloadJSON: payload
                )
            }
        }
        let policy = AgentEventRetentionPolicy(
            streamEventBytesGlobal: 1 * 1_024 * 1_024,
            providerLogBytesGlobal: 1 * 1_024 * 1_024,
            pruneQuantumRows: 1,
            pruneQuantumBytes: 512 * 1_024
        )
        try runs.persistStreamBatch(
            runId: fixtures[0].1.id,
            threadId: fixtures[0].0.id,
            items: [],
            shouldPruneStreamEvents: true,
            retentionPolicy: policy
        )
        let usage = try db.prepare(
            "SELECT payload_bytes FROM storage_usage_counters WHERE storage_class = 'stream_events';"
        )
        let deadline = Date().addingTimeInterval(5)
        var retainedBytes = Int64.max
        while Date() < deadline {
            usage.reset()
            if try usage.step() { retainedBytes = usage.columnInt64(0) }
            if retainedBytes <= policy.streamEventBytesGlobal { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertLessThanOrEqual(
            retainedBytes,
            policy.streamEventBytesGlobal,
            "one production cadence request must self-drain multiple quanta without another Agent event"
        )
        XCTAssertTrue(
            try fixtures.contains { try runs.streamHistoryWasPruned(threadId: $0.0.id) },
            "every evicted stream prefix must remain visibly marked partial"
        )
    }

    func test_globalTerminalQuotaProtectsWriterAndMarksEveryPrunedSurface() throws {
        let db = try makeDB()
        let repo = TerminalOutputRepository(db: db)
        let protected = "terminal-active"
        let dormantA = "terminal-dormant-a"
        let dormantB = "terminal-dormant-b"
        for index in 0..<5 {
            try repo.append(surfaceID: protected, workspaceID: nil, chunkIndex: Int64(index + 1), data: Data(repeating: 0x41, count: 10))
            try repo.append(surfaceID: dormantA, workspaceID: nil, chunkIndex: Int64(index + 1), data: Data(repeating: 0x42, count: 10))
            try repo.append(surfaceID: dormantB, workspaceID: nil, chunkIndex: Int64(index + 1), data: Data(repeating: 0x43, count: 10))
        }

        for _ in 0..<10 {
            let result = try repo.pruneGlobalByteCapAndMarkHistoryPartial(
                maxBytes: 60,
                protectedSurfaceID: protected,
                maxRows: 2,
                maxDeleteBytes: 20
            )
            XCTAssertLessThanOrEqual(result.deletedRows, 2, "each maintenance transaction must remain a bounded quantum")
            if !result.remainsOverBudget { break }
        }

        XCTAssertLessThanOrEqual(try repo.totalBytesAllSurfaces(), 60)
        XCTAssertEqual(try repo.totalBytes(surfaceID: protected), 50,
                       "global pruning must preserve the actively writing terminal")
        XCTAssertNotNil(try repo.partialHistoryState(surfaceID: dormantA))
        XCTAssertNotNil(try repo.partialHistoryState(surfaceID: dormantB))
        let retained = try repo.readWindow(surfaceID: dormantB, maxBytes: 1_024).chunks.map(\.chunkIndex)
        XCTAssertEqual(retained, retained.sorted(), "surviving dormant chunks must retain FIFO order")
    }

    // MARK: - persistStreamBatch prune cadence

    func test_streamBatchNeedsRetentionReclaim_honorsCadenceAndOversizedFrame() {
        // WHY: token-rate flushes (~16 events / 250ms) must not pay JOIN+window
        // DELETE. The coordinator already sets shouldPrune every 25 events; a
        // single frame over the thread byte cap still reclaims immediately.
        XCTAssertFalse(
            AgentRunRepository.streamBatchNeedsRetentionReclaim(
                shouldPruneStreamEvents: false,
                itemPayloadBytes: [32, 64, 128],
                providerPayloadBytes: [16],
                streamEventBytesPerThread: 8 * 1_024 * 1_024,
                providerLogBytesPerThread: 8 * 1_024 * 1_024
            ),
            "small token-rate batch with prune=false must skip window retention"
        )
        XCTAssertTrue(
            AgentRunRepository.streamBatchNeedsRetentionReclaim(
                shouldPruneStreamEvents: true,
                itemPayloadBytes: [32],
                providerPayloadBytes: [],
                streamEventBytesPerThread: 8 * 1_024 * 1_024,
                providerLogBytesPerThread: 8 * 1_024 * 1_024
            ),
            "coordinator prune cadence must still reclaim"
        )
        XCTAssertTrue(
            AgentRunRepository.streamBatchNeedsRetentionReclaim(
                shouldPruneStreamEvents: false,
                itemPayloadBytes: [8 * 1_024 * 1_024 + 1],
                providerPayloadBytes: [],
                streamEventBytesPerThread: 8 * 1_024 * 1_024,
                providerLogBytesPerThread: 8 * 1_024 * 1_024
            ),
            "a frame larger than the thread byte cap must reclaim immediately"
        )
    }

    func test_persistStreamBatch_skipsWindowDeleteWhenCadenceSaysNo() throws {
        // WHY: the hot stream write path used to run ROW_NUMBER/running-SUM
        // DELETE after every flush even with shouldPruneStreamEvents=false.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)
        let items = (1...8).map { index in
            AgentRunRepository.StreamWriteIntent(
                seq: index,
                kind: "delta",
                payloadJSON: #"{"n":\#(index)}"#,
                providerEvent: nil
            )
        }

        var sawWindowDelete = false
        db.beforeStatementStepForTesting = { sql in
            let upper = sql.uppercased()
            if upper.contains("ROW_NUMBER()") { sawWindowDelete = true }
        }
        defer { db.beforeStatementStepForTesting = nil }

        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: items,
            shouldPruneStreamEvents: false
        )

        XCTAssertFalse(sawWindowDelete,
                       "token-rate persist with prune=false must not run window retention SQL")
        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 8,
                       "skipping prune must still persist every flushed event")
    }

    func test_persistStreamBatch_prunesWhenCadenceDue() throws {
        // WHY: honoring the cadence must not disable the cap — 20 events with
        // keepLatest=5 must still drop the oldest 15 when prune is requested.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeFinishedRun(db: db, threadId: thread.id)
        let items = (1...20).map { index in
            AgentRunRepository.StreamWriteIntent(
                seq: index,
                kind: "delta",
                payloadJSON: #"{"n":\#(index)}"#,
                providerEvent: nil
            )
        }
        let policy = AgentEventRetentionPolicy(
            streamEventCountPerThread: 5,
            streamEventBytesPerThread: 8 * 1_024 * 1_024,
            providerLogCountPerThread: 5,
            providerLogBytesPerThread: 8 * 1_024 * 1_024
        )

        try runs.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: items,
            shouldPruneStreamEvents: true,
            retentionPolicy: policy
        )

        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 5,
                       "prune-due batch must still enforce the per-thread count cap")
        XCTAssertTrue(try runs.streamHistoryWasPruned(threadId: thread.id),
                      "count-cap eviction must mark the thread history partial")
    }

    func test_pruneStreamEvents_underCapSkipsWindowDelete() throws {
        // WHY: explicit prune (appendStreamEvent / pruneDue) must COUNT first
        // and skip JOIN+window DELETE while both caps still have headroom.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)
        for index in 1...4 {
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index,
                kind: "delta",
                payloadJSON: #"{"n":\#(index)}"#
            )
        }

        var sawWindowDelete = false
        db.beforeStatementStepForTesting = { sql in
            if sql.uppercased().contains("ROW_NUMBER()") { sawWindowDelete = true }
        }
        defer { db.beforeStatementStepForTesting = nil }

        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: 100, maxPayloadBytes: 8 * 1_024 * 1_024)

        XCTAssertFalse(sawWindowDelete,
                       "under-cap prune must not run ROW_NUMBER window DELETE")
        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 4,
                       "under-cap prune must leave every row in place")
    }

    func test_pruneProviderEventLogs_underCapSkipsWindowDelete() throws {
        // WHY: same COUNT-then-skip as stream events — belowCapIsNoop already
        // checks rows survive; this pins that the expensive SQL is not issued.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)
        for index in 0..<4 {
            try appendEvent(runs: runs, run: run, index: index)
        }

        var sawWindowDelete = false
        db.beforeStatementStepForTesting = { sql in
            if sql.uppercased().contains("ROW_NUMBER()") { sawWindowDelete = true }
        }
        defer { db.beforeStatementStepForTesting = nil }

        try runs.pruneProviderEventLogs(threadId: thread.id, keepLatest: 100)

        XCTAssertFalse(sawWindowDelete,
                       "under-cap provider prune must not run ROW_NUMBER window DELETE")
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 4)
    }

    func test_runningRunKeepsToolItemsPastRowCapUntilItFinishes() throws {
        // WHY: paired devices rebuild a running turn from these rows. With a
        // 100-row cap a long run kept only its newest chatter, so the phone lost
        // the tool items the Mac still listed. Bytes still bound the running run,
        // and the cap applies again once it is no longer running.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)
        for i in 0..<250 {
            try runs.appendStreamEvent(runId: run.id, seq: i, kind: "k", payloadJSON: #"{"i":\#(i)}"#)
        }
        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 250,
                       "the running run must keep its rows past the row cap")

        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: 100, maxPayloadBytes: 200)
        XCTAssertLessThan(try runs.countStreamEvents(threadId: thread.id), 250,
                          "the byte budget still bounds a running run")

        var finished = run
        finished.status = .completed
        try runs.upsert(finished)
        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: 10)
        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 10)
    }
}
