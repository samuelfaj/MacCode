import XCTest
@testable import SocketServer

/// Snapshot router whose read can be held off MainActor, fail, or publish
/// events inside the read window. Each read stamps its state with a counter so
/// a test can tell which physical read a caller received.
@MainActor
private final class JoinFenceSnapshotRouter: FakeRouter, ConnectionSnapshotRouting {
    let workspaceID = UUID().uuidString
    private(set) var readCount = 0
    /// Held reads wait on this off MainActor until a test signals it.
    var gate: DispatchSemaphore?
    var readStarted: DispatchSemaphore?
    /// Published on EventBus.shared inside every read (or only the first).
    var publishKindsDuringRead: [String] = []
    var publishOnlyDuringFirstRead = false
    var failure: Error?

    func readConnectionSnapshotState() async throws -> ConnectionSnapshotReadState {
        readCount += 1
        let stamp = readCount
        let gate = gate
        let started = readStarted
        let kinds = publishOnlyDuringFirstRead && stamp > 1 ? [] : publishKindsDuringRead
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "io.remotecode.test.snapshot-join").async {
                started?.signal()
                if let gate { _ = gate.wait(timeout: .now() + 5) }
                for kind in kinds {
                    EventBus.shared.publishRawForTesting(kind: kind, payload: .object([:]))
                }
                continuation.resume()
            }
        }
        if let failure { throw failure }
        return ConnectionSnapshotReadState(
            selectedWorkspaceId: workspaceID,
            workspaces: [.object(["id": .string(workspaceID), "name": .string("Read \(stamp)")])],
            surfaces: [],
            agentThreads: [],
            browserStates: [],
            filesStates: []
        )
    }
}

private struct SnapshotReadFailure: Error {}

final class ConnectionSnapshotJoinFenceTests: XCTestCase {
    // MARK: - Join

    /// WHY: two devices reconnecting together (or a retry while a read runs)
    /// used to get -32013 immediately for every caller after the first, and
    /// iOS then looped on baseline. Both must get a snapshot from one read.
    func test_twoConcurrentCallers_bothSucceedFromOnePhysicalRead() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let router = await MainActor.run {
            let router = JoinFenceSnapshotRouter()
            router.gate = gate
            router.readStarted = started
            return router
        }
        let (dispatcher, metrics) = await MainActor.run {
            (JSONRPCDispatcher(router: router), HTTPRequestPhaseMetrics())
        }

        let first = Task { @MainActor in
            try await dispatcher.readConnectionSnapshot(phaseMetrics: metrics)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let second = Task { @MainActor in
            try await dispatcher.readConnectionSnapshot(phaseMetrics: metrics)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        gate.signal()

        let a = try await first.value
        let b = try await second.value
        let reads = await MainActor.run { router.readCount }
        XCTAssertEqual(reads, 1, "a late caller must join the in-flight read, not start another")
        XCTAssertEqual(a.state, b.state)
        XCTAssertEqual(a.metadata, b.metadata, "both callers share the read's pre-read watermark")
        XCTAssertEqual(metrics.snapshot().joinedTotal, 1)
        XCTAssertEqual(metrics.snapshot().timedOutTotal, 0)
    }

    /// WHY: a caller whose deadline expired leaves its read running (it cannot
    /// be interrupted inside SQLite). The next caller must reuse that read
    /// instead of failing fast or stacking a second SQLite read.
    func test_callerAfterTimedOutCaller_joinsTheStillRunningRead() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let router = await MainActor.run {
            let router = JoinFenceSnapshotRouter()
            router.gate = gate
            router.readStarted = started
            return router
        }
        let dispatcher = await MainActor.run { JSONRPCDispatcher(router: router) }

        let timedOut: Int? = await Task { @MainActor in
            do {
                _ = try await dispatcher.readConnectionSnapshot(timeoutNanoseconds: 5_000_000)
                return nil
            } catch let error as JSONRPCError {
                return error.code
            } catch {
                return nil
            }
        }.value
        XCTAssertEqual(timedOut, JSONRPCDispatcher.snapshotTimedOut.code)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        let late = Task { @MainActor in
            try await dispatcher.readConnectionSnapshot()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        gate.signal()
        let result = try await late.value
        let reads = await MainActor.run { router.readCount }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.state.workspaces.first?.objectValue?["name"]?.stringValue, "Read 1")
    }

    /// WHY: one device disconnecting mid-snapshot cancels only its own wait.
    func test_cancelledCaller_doesNotFailTheOtherCaller() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let router = await MainActor.run {
            let router = JoinFenceSnapshotRouter()
            router.gate = gate
            router.readStarted = started
            return router
        }
        let dispatcher = await MainActor.run { JSONRPCDispatcher(router: router) }

        let leaving = Task { @MainActor in
            try await dispatcher.readConnectionSnapshot()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let staying = Task { @MainActor in
            try await dispatcher.readConnectionSnapshot()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        leaving.cancel()
        let leftCode: Int? = await {
            do { _ = try await leaving.value; return nil } catch let error as JSONRPCError { return error.code } catch { return nil }
        }()
        XCTAssertEqual(leftCode, JSONRPCDispatcher.snapshotCancelled.code)

        gate.signal()
        let result = try await staying.value
        XCTAssertEqual(result.state.workspaces.count, 1)
        let reads = await MainActor.run { router.readCount }
        XCTAssertEqual(reads, 1)
    }

    /// WHY: a failed read must fail every joined caller with the real error,
    /// then release the slot so the next caller starts a fresh read.
    func test_readFailure_reachesEveryJoinedCallerAndFreesTheSlot() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let router = await MainActor.run {
            let router = JoinFenceSnapshotRouter()
            router.gate = gate
            router.readStarted = started
            router.failure = SnapshotReadFailure()
            return router
        }
        let dispatcher = await MainActor.run { JSONRPCDispatcher(router: router) }

        let first = Task { @MainActor in try await dispatcher.readConnectionSnapshot() }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let second = Task { @MainActor in try await dispatcher.readConnectionSnapshot() }
        try await Task.sleep(nanoseconds: 20_000_000)
        gate.signal()
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("a failed read must not produce a snapshot")
            } catch {
                XCTAssertTrue(error is SnapshotReadFailure, "got \(error)")
            }
        }

        await MainActor.run {
            router.failure = nil
            router.gate = nil
        }
        let retry = try await Task { @MainActor in try await dispatcher.readConnectionSnapshot() }.value
        XCTAssertEqual(retry.state.workspaces.first?.objectValue?["name"]?.stringValue, "Read 2")
    }

    // MARK: - Fence

    /// WHY: a busy terminal title (about 1 rename/s) or an agent touching its
    /// thread row used to fail every snapshot that spanned it with -32012.
    /// These kinds set absolute values, so the snapshot succeeds and keeps the
    /// pre-read watermark: the client replays them on top and converges.
    func test_fence_toleratesIdempotentLastWriterWinsKindsAndKeepsThemReplayable() async throws {
        let kinds = Array(EventBus.snapshotFenceIdempotentKinds).sorted()
        XCTAssertEqual(Set(kinds), [
            "surface.renamed", "surface.updated", "surface.health",
            "workspace.updated", "agent.thread.updated",
        ])
        let router = await MainActor.run {
            let router = JoinFenceSnapshotRouter()
            router.publishKindsDuringRead = kinds
            return router
        }
        let metrics = HTTPRequestPhaseMetrics()
        let startSequence = EventBus.shared.currentSeq

        let result = try await Task { @MainActor in
            try await JSONRPCDispatcher(router: router).readConnectionSnapshot(phaseMetrics: metrics)
        }.value

        let reads = await MainActor.run { router.readCount }
        XCTAssertEqual(reads, 1, "idempotent kinds must not force a fence retry")
        XCTAssertEqual(result.metadata.sequence, startSequence,
                       "the watermark stays before the read so every crossing event is replayed")
        XCTAssertGreaterThanOrEqual(EventBus.shared.currentSeq, startSequence + Int64(kinds.count))
        XCTAssertEqual(metrics.snapshot().fenceToleratedTotal, 1)
        XCTAssertEqual(metrics.snapshot().fenceRetryTotal, 0)
    }

    /// WHY (A to B): a structural change landing inside read A makes A stale;
    /// the host must discard A and return read B, never the stale state.
    func test_fence_structuralChangeDuringReadDiscardsTheStaleRead() async throws {
        let router = await MainActor.run {
            let router = JoinFenceSnapshotRouter()
            router.publishKindsDuringRead = ["surface.closed"]
            router.publishOnlyDuringFirstRead = true
            return router
        }
        let metrics = HTTPRequestPhaseMetrics()

        let result = try await Task { @MainActor in
            try await JSONRPCDispatcher(router: router).readConnectionSnapshot(phaseMetrics: metrics)
        }.value

        let reads = await MainActor.run { router.readCount }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(result.state.workspaces.first?.objectValue?["name"]?.stringValue, "Read 2",
                       "the read that a close crossed must not be returned")
        XCTAssertEqual(metrics.snapshot().fenceRetryTotal, 1)
        XCTAssertEqual(metrics.snapshot().fenceToleratedTotal, 0)
    }

    func test_eventBusFenceRevision_skipsIdempotentAndLiveOnlyKinds() {
        let bus = EventBus()
        bus.publishRawForTesting(kind: "surface.created", payload: .object([:]))
        let base = bus.snapshotMetadata()
        XCTAssertEqual(base.fenceRevision, base.sequence)
        for kind in EventBus.snapshotFenceIdempotentKinds.union(EventBus.liveOnlyStreamEventKinds) {
            bus.publishRawForTesting(kind: kind, payload: .object([:]))
        }
        let after = bus.snapshotMetadata()
        XCTAssertEqual(after.fenceRevision, base.fenceRevision)
        XCTAssertGreaterThan(after.stateRevision, base.stateRevision,
                             "idempotent kinds still advance the state revision")
        bus.publishRawForTesting(kind: "agent.thread.created", payload: .object([:]))
        XCTAssertEqual(bus.snapshotMetadata().fenceRevision, bus.snapshotMetadata().sequence)
    }

    // MARK: - Bounded thread window

    private static func thread(
        _ id: String,
        workspace: String,
        status: String = "completed",
        updatedAt: Double,
        pinned: Bool = false
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "workspaceId": .string(workspace),
            "status": .string(status),
            "updatedAt": .number(updatedAt),
            "pinned": .bool(pinned),
        ])
    }

    private static func windowState(threadCount: Int) -> ConnectionSnapshotReadState {
        let workspace = "W1"
        var threads: [JSONValue] = []
        for index in 0..<threadCount {
            threads.append(thread("t\(String(format: "%03d", index))", workspace: workspace, updatedAt: Double(index)))
        }
        // Old but must stay: running, pending, pinned, and surface-selected.
        threads[0] = thread("t000", workspace: workspace, status: "running", updatedAt: 0)
        threads[1] = thread("t001", workspace: workspace, status: "pending", updatedAt: 1)
        threads[2] = thread("t002", workspace: workspace, updatedAt: 2, pinned: true)
        return ConnectionSnapshotReadState(
            selectedWorkspaceId: workspace,
            workspaces: [.object(["id": .string(workspace)])],
            surfaces: [ConnectionSnapshotWorkspaceItems(workspaceId: workspace, items: [
                .object([
                    "id": .string("S1"),
                    "type": .string("agentApp"),
                    "metadata": .object(["selected_thread": .string("t003")]),
                ]),
            ])],
            agentThreads: [ConnectionSnapshotWorkspaceItems(workspaceId: workspace, items: threads)],
            browserStates: [],
            filesStates: []
        )
    }

    /// WHY: 177 threads is about 270 KB on every baseline. A client that opts
    /// in gets active + pinned + selected + the N most recent, and is told how
    /// many exist so it never mistakes the window for the whole list.
    func test_threadWindow_keepsActivePinnedSelectedAndRecent_withinSizeBound() throws {
        let state = Self.windowState(threadCount: 180)
        let bounded = state.boundingAgentThreads(recentPerWorkspace: 5)
        let group = try XCTUnwrap(bounded.agentThreads.first)
        let ids = group.items.compactMap { $0.objectValue?["id"]?.stringValue }

        XCTAssertEqual(ids, ["t000", "t001", "t002", "t003", "t175", "t176", "t177", "t178", "t179"],
                       "always-kept rows plus the 5 most recent, in the original order")
        XCTAssertLessThanOrEqual(group.items.count, 4 + 5, "size bound: always-kept + N")
        XCTAssertEqual(group.totalCount, 180)
        XCTAssertEqual(group.jsonValue.objectValue?["truncated"]?.boolValue, true)
        XCTAssertEqual(bounded.surfaces, state.surfaces)

        let small = Self.windowState(threadCount: 6).boundingAgentThreads(recentPerWorkspace: 50)
        XCTAssertEqual(small.agentThreads.first?.items.count, 6)
        XCTAssertEqual(small.agentThreads.first?.jsonValue.objectValue?["truncated"]?.boolValue, false)

        for value in [bounded, small] {
            XCTAssertNoThrow(try ConnectionTransportFrame.snapshot(ConnectionSnapshotFrame(
                protocolVersion: 3, type: "snapshot", connectionId: "c", hostId: "h", bootEpoch: 1,
                sequence: 1, snapshotId: "s", generatedAtEpochMs: 1, stateVersion: 3,
                state: value.jsonValue(domainRevisions: .zero)
            )).encoded(), "a bounded group must satisfy the strict wire contract")
        }
        // Without the window the group keeps the legacy exact key set.
        XCTAssertEqual(Set(state.agentThreads[0].jsonValue.objectValue.map { Array($0.keys) } ?? []), ["workspaceId", "items"])
    }

    func test_threadWindow_parameterParsing() {
        XCTAssertEqual(ConnectionSnapshotThreadWindow.parse(NSNumber(value: 5)), 5)
        XCTAssertEqual(ConnectionSnapshotThreadWindow.parse(NSNumber(value: 10_000)),
                       ConnectionSnapshotThreadWindow.maximumRecentPerWorkspace)
        XCTAssertNil(ConnectionSnapshotThreadWindow.parse(NSNumber(value: 0)))
        XCTAssertNil(ConnectionSnapshotThreadWindow.parse(NSNumber(value: -1)))
        XCTAssertNil(ConnectionSnapshotThreadWindow.parse(NSNumber(value: 1.5)))
        XCTAssertNil(ConnectionSnapshotThreadWindow.parse(NSNumber(value: true)))
        XCTAssertNil(ConnectionSnapshotThreadWindow.parse("5"))
    }

    // MARK: - HTTP

    @MainActor
    private final class WindowHTTPRouter: FakeRouter, ConnectionSnapshotRouting {
        func readConnectionSnapshotState() async throws -> ConnectionSnapshotReadState {
            ConnectionSnapshotJoinFenceTests.windowState(threadCount: 40)
        }
    }

    /// WHY: older iOS builds never send the parameter and must keep the full
    /// list with the legacy group keys; new builds find the capability on
    /// welcome before sending it, and a bad value is rejected, not ignored.
    @MainActor
    func test_http_threadWindowIsOptInAndAdvertised() async throws {
        XCTAssertTrue(DirectHTTPServer.welcomeCapabilities().contains(ConnectionSnapshotThreadWindow.capability))
        let router = WindowHTTPRouter()
        var server: DirectHTTPServer?
        var port: UInt16 = 0
        for _ in 0..<20 {
            port = UInt16.random(in: 33_000...44_000)
            let candidate = DirectHTTPServer(
                port: port,
                loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: router),
                serverId: "window-host",
                bootEpoch: 1
            )
            if (try? candidate.start()) != nil { server = candidate; break }
        }
        let running = try XCTUnwrap(server)
        defer { running.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)

        func threadGroup(_ response: [String: Any]) throws -> [String: Any] {
            let result = try XCTUnwrap(response["result"] as? [String: Any], "\(response)")
            let state = try XCTUnwrap(result["state"] as? [String: Any])
            return try XCTUnwrap((state["agentThreads"] as? [[String: Any]])?.first)
        }

        let legacy = try threadGroup(try await rpc(port: port, method: "sync.snapshot", params: ["supportedStateVersion": 3]))
        XCTAssertEqual(Set(legacy.keys), ["workspaceId", "items"])
        XCTAssertEqual((legacy["items"] as? [Any])?.count, 40)

        let window = try threadGroup(try await rpc(port: port, method: "sync.snapshot", params: [
            "supportedStateVersion": 3, ConnectionSnapshotThreadWindow.parameter: 5,
        ]))
        XCTAssertEqual((window["items"] as? [Any])?.count, 9)
        XCTAssertEqual(window["totalCount"] as? Int, 40)
        XCTAssertEqual(window["truncated"] as? Bool, true)

        let begin = try await rpc(port: port, method: "sync.snapshot.begin", params: [
            "supportedStateVersion": 3, ConnectionSnapshotThreadWindow.parameter: 5,
        ])
        XCTAssertNotNil(begin["result"], "\(begin)")

        for bad: Any in [0, true, 2.5, "5"] {
            let response = try await rpc(port: port, method: "sync.snapshot", params: [
                "supportedStateVersion": 3, ConnectionSnapshotThreadWindow.parameter: bad,
            ])
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602, "\(bad)")
        }
    }

    // MARK: - Chunk cap

    /// WHY: the chunked path used to refuse any frame over 1 MiB with -32603,
    /// so a host with many threads could never baseline. It now caches up to
    /// 4 MiB and grows chunks so the count stays within the 128 limit.
    func test_chunkCache_acceptsFramesAboveOneMiBAndGrowsChunks() throws {
        let cache = SnapshotChunkTransferCache()
        let frame = Data(repeating: 0x61, count: 3 * 1_024 * 1_024)
        let record = try cache.insert(
            frameBytes: frame,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1,
            snapshotId: "s",
            sequence: 1,
            generatedAtEpochMs: 1,
            stateVersion: 3,
            preferredChunkBytes: SnapshotChunkSizePolicy.minimumBytes
        ).record
        XCTAssertLessThanOrEqual(record.manifest.chunkCount, SnapshotChunkSizePolicy.maximumChunkCount)
        XCTAssertEqual(record.manifest.totalBytes, frame.count)
        XCTAssertLessThanOrEqual(record.manifest.chunkBytes, SnapshotChunkSizePolicy.maximumBytes)

        let small = try cache.insert(
            frameBytes: Data(repeating: 0x62, count: 100_000),
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1,
            snapshotId: "s2",
            sequence: 2,
            generatedAtEpochMs: 1,
            stateVersion: 3,
            preferredChunkBytes: SnapshotChunkSizePolicy.minimumBytes
        ).record
        XCTAssertEqual(small.manifest.chunkBytes, SnapshotChunkSizePolicy.minimumBytes,
                       "frames that fit keep the negotiated size")

        XCTAssertThrowsError(try cache.insert(
            frameBytes: Data(repeating: 0x63, count: SnapshotChunkSizePolicy.maximumTotalBytes + 1),
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1,
            snapshotId: "s3",
            sequence: 3,
            generatedAtEpochMs: 1,
            stateVersion: 3,
            preferredChunkBytes: nil
        ))
    }

    func test_requestPhaseMetricsJSON_reportsJoinAndTolerance() {
        let metrics = HTTPRequestPhaseMetrics()
        metrics.recordJoined()
        metrics.recordFenceTolerated()
        metrics.recordFenceTolerated()
        let object = DirectHTTPServer.requestPhaseMetricsJSON(metrics.snapshot())
        XCTAssertEqual(object["snapshot_joined_total"] as? UInt64, 1)
        XCTAssertEqual(object["fence_tolerated_total"] as? UInt64, 2)
    }

    // MARK: - Main actor stall

    /// WHY: on 2026-10-29 a modal alert opened inside a main-queue job kept
    /// the main actor busy for 84 minutes. The dispatcher's 5s snapshot
    /// deadline never started, so every iPhone baseline waited its full 60s
    /// and the connection never came up. The host must answer the retryable
    /// -32013 near its own budget even when the main actor cannot run.
    func test_http_snapshotAnswersRetryableTimeoutWhileMainActorIsStuck() async throws {
        let router = await MainActor.run { JoinFenceSnapshotRouter() }
        let dispatcher = await MainActor.run { JSONRPCDispatcher(router: router) }
        let server = DirectHTTPServer(
            port: 0,
            loopbackOnly: true,
            dispatcher: dispatcher,
            serverId: "stall-host",
            bootEpoch: 1
        )
        server.snapshotReadTimeoutNanosecondsForTesting = 300_000_000
        let body = Data(#"{"jsonrpc":"2.0","id":"stall","method":"sync.snapshot","params":{"supportedStateVersion":3}}"#.utf8)

        let release = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { _ = release.wait(timeout: .now() + 10) }

        let started = Date()
        let data = await server.dispatchRPC(bodyData: body)
        let elapsed = Date().timeIntervalSince(started)
        release.signal()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any], "\(object)")
        XCTAssertEqual(error["code"] as? Int, -32013)
        XCTAssertLessThan(elapsed, 3, "the hop to a stuck main actor must be bounded by the snapshot budget")
    }

    @MainActor
    private func rpc(port: UInt16, method: String, params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": "window", "method": method, "params": params,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
