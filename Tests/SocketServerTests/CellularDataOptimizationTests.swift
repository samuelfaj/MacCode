import XCTest
import CoreModel
@testable import SocketServer

final class CellularDataOptimizationTests: XCTestCase {
    func testPayloadCodecRoundTripsAndRejectsInvalidData() throws {
        let payload = Data(String(repeating: #"{"event":"same visible state"}"#, count: 40).utf8)
        let encoded = try PayloadCodec.lzfse.encode(payload)
        let gzip = try PayloadCodec.gzip.encode(payload)

        XCTAssertLessThan(encoded.count, payload.count)
        XCTAssertEqual(try PayloadCodec.lzfse.decode(encoded, expectedSize: payload.count), payload)
        XCTAssertThrowsError(try PayloadCodec.lzfse.decode(Data([0, 1, 2, 3]), expectedSize: payload.count))
        XCTAssertEqual(gzip.prefix(2), Data([0x1f, 0x8b]), "gzip history compression must use the standard gzip wire header")
        XCTAssertLessThan(gzip.count, payload.count)
        XCTAssertEqual(try PayloadCodec.gzip.decode(gzip, expectedSize: payload.count), payload)
    }

    func testWebSocketEnvelopeRoundTripsAndRejectsInvalidData() throws {
        let event = Data(String(repeating: #"{"seq":1,"kind":"surface.browser","payload":{"url":"https://example.test"}}"#, count: 20).utf8)
        let envelope = try PayloadCodec.encodeWebSocketEnvelope(event)

        XCTAssertLessThan(envelope.count, event.count,
                          "Mac WS compression must save bytes before it is sent on a cellular-optimized stream")
        XCTAssertEqual(try PayloadCodec.decodeWebSocketEnvelope(envelope), event)
        XCTAssertThrowsError(try PayloadCodec.decodeWebSocketEnvelope(Data("not-an-envelope".utf8)))
    }

    @MainActor
    func testEventsRecentHonorsSinceSeqAndMaxBytesWithTruncationMetadata() async throws {
        let bus = EventBus()
        bus.publishRawForTesting(kind: "a", payload: .string(String(repeating: "a", count: 500)))
        bus.publishRawForTesting(kind: "b", payload: .string(String(repeating: "b", count: 500)))
        bus.publishRawForTesting(kind: "c", payload: .string("small"))

        let result = bus.recentEvents(since: 1, maxBytes: 600)

        XCTAssertEqual(result.events.map(\.kind), ["b"])
        XCTAssertTrue(result.truncated,
                      "bounded cellular replay must say when history was truncated so iOS does not mark partial state live")
        XCTAssertTrue(result.requiresBaseline)
        XCTAssertEqual(result.lastSeq, 3)
    }

    @MainActor
    func testHTTPServerCompressesLargeAcceptedJSONResponses() throws {
        let port = UInt16.random(in: 33000...44000)
        let router = FakeRouter()
        router.workspaces = (0..<40).map { Workspace.empty(name: "workspace-\($0)-\(String(repeating: "x", count: 40))", cwd: "/tmp/project-\($0)") }
        let dispatcher = JSONRPCDispatcher(router: router)
        let server = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher, bootEpoch: 1)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let body = """
        {"jsonrpc":"2.0","id":"rpc-route","method":"workspace.list","params":{}}
        """
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue(PayloadCodec.acceptEncodingHeader, forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let done = expectation(description: "compressed response")
        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            let http = response as? HTTPURLResponse
            XCTAssertEqual(http?.value(forHTTPHeaderField: "Content-Encoding"), PayloadCodec.gzip.wireName,
                           "Mac must only compress after explicit iOS negotiation")
            do {
                let responseData = data ?? Data()
                let decoded = responseData.starts(with: Data([0x1f, 0x8b]))
                    ? try PayloadCodec.gzip.decode(responseData, expectedSize: nil)
                    : responseData
                let obj = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
                XCTAssertEqual(obj?["id"] as? String, "rpc-route")
            } catch {
                XCTFail("compressed JSON response should decode: \(error)")
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 4)
    }

    @MainActor
    func testHTTPServerDecodesCompressedRequestsAndRejectsBadEncodedBodies() async throws {
        let port = UInt16.random(in: 33000...44000)
        let router = FakeRouter()
        router.workspaces = [Workspace.empty(name: "compressed-request", cwd: "/tmp")]
        let server = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: JSONRPCDispatcher(router: router), bootEpoch: 1)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)

        let json = #"{"jsonrpc":"2.0","id":"rpc-route","method":"workspace.list","params":{"note":""# +
            String(repeating: "same visible state ", count: 200) +
            #""}}"#
        let body = Data(json.utf8)
        let compressed = try PayloadCodec.lzfse.encode(body)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(PayloadCodec.lzfse.wireName, forHTTPHeaderField: "Content-Encoding")
        request.httpBody = compressed

        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = obj?["result"] as? [[String: Any]]
        XCTAssertEqual(result?.first?["name"] as? String, "compressed-request",
                       "compressed read-only RPC requests must route to the exact same dispatcher result as plain JSON")

        request.httpBody = Data("corrupt".utf8)
        let (_, badResponse) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((badResponse as? HTTPURLResponse)?.statusCode, 400,
                       "corrupt compressed bodies must fail loudly instead of reaching RPC dispatch")

        request.httpBody = try PayloadCodec.lzfse.encode(
            Data(repeating: 0x41, count: DirectHTTPServer.maxRequestBodyBytes + 1)
        )
        let (_, oversizedResponse) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((oversizedResponse as? HTTPURLResponse)?.statusCode, 413,
                       "compressed expansion past the request limit must stop with payload-too-large")
    }

    @MainActor
    func testDispatcherReadOnlyBatchRejectsMutatingMethods() async {
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .string("batch"),
            method: "rpc.batch",
            params: ["calls": .array([
                .object(["method": .string("workspace.list"), "params": .object([:])]),
                .object(["method": .string("agent.run.stop"), "params": .object([:])])
            ])]
        ))

        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertEqual(response.error?.data, .string("agent.run.stop"),
                       "cellular batching must fail loudly instead of changing mutating RPC semantics")
    }

    func testCellularSafeEventFilterDropsOnlyDiagnosticNonReducerEvents() {
        let bus = EventBus()
        var full: [String] = []
        var filtered: [String] = []
        _ = bus.subscribe(since: nil) { full.append($0.kind) }
        _ = bus.subscribe(since: nil, filter: .cellularSafe()) { filtered.append($0.kind) }

        bus.publish(kind: .diagnosticWSSlowClient, payload: .object(["sample": .string(String(repeating: "x", count: 200))]))
        bus.publish(kind: .surfaceOutput, payload: .object([
            "surface_id": .string("s1"),
            "seq": .number(7),
            "rows": .number(33),
            "cols": .number(101),
            "base64": .string(Data(String(repeating: "log ", count: 200).utf8).base64EncodedString())
        ]))
        bus.publish(kind: .surfaceBrowser, payload: .object(["surface_id": .string("s1"), "url": .string("https://example.test")]))
        bus.publish(kind: .agentRunCompleted, payload: .object(["thread_id": .string("t1")]))

        XCTAssertEqual(full, ["diagnostic.ws_slow_client", "surface.output", "surface.browser", "agent.run.completed"],
                       "old/unfiltered clients must keep receiving the full stream")
        XCTAssertEqual(filtered, ["surface.output.summary", "surface.browser", "agent.run.completed"],
                       "cellular-safe WS filtering may summarize passive terminal output and drop diagnostics while visible state and critical events pass")
    }

    func testCellularSafeFilterForwardsFutureUnknownKindsForSequenceContinuity() {
        let bus = EventBus()
        var delivered: [String] = []
        _ = bus.subscribe(since: nil, filter: .cellularSafe()) { delivered.append($0.kind) }

        bus.publishRawForTesting(
            kind: "future.event.kind",
            payload: .object(["value": .number(1)])
        )

        XCTAssertEqual(delivered, ["future.event.kind"])
    }

    /// WHY: the cellular-safe filter legitimately skips seqs (diagnostic.*),
    /// and the host publishes diagnostic.ws_slow_client exactly under cellular
    /// load. A filter-dropped seq must advance the connection gap watermark
    /// without a frame, or the next delivered event reads as a gap, the server
    /// closes 1012, and the filtered client dead-loops on reconnect.
    func testCellularSafeFilteredSequenceHoleIsAccountedInsteadOfGapClosing() {
        let bus = EventBus()
        let watermark = ConnectionSequenceWatermark(initialSequence: 0)
        var delivered: [Int64] = []
        var gaps: [ConnectionSequenceRecordResult] = []
        _ = bus.subscribeDetectingReplayExpiry(
            since: 0,
            filter: .cellularSafe(),
            onReplayExpired: { _ in XCTFail("a fresh bus must not report replay expiry") },
            onFilteredEvent: { watermark.recordFilteredEvent(sequence: $0) }
        ) { event in
            let result = watermark.recordEnqueuedEvent(sequence: event.seq)
            if result != .advanced { gaps.append(result) }
            delivered.append(event.seq)
        }

        bus.publish(kind: .workspaceUpdated, payload: .object([:]))
        bus.publish(kind: .diagnosticWSSlowClient, payload: .object([:]))
        bus.publish(kind: .workspaceUpdated, payload: .object([:]))

        XCTAssertEqual(delivered, [1, 3],
                       "the filter must drop only the diagnostic seq while both critical events pass")
        XCTAssertEqual(gaps, [],
                       "a seq dropped by the connection's own filter is not a gap and must not trigger a 1012 close")
        XCTAssertEqual(watermark.value, 3,
                       "the watermark must account for the filtered seq so later events stay contiguous")
    }

    func testCellularSafeOutputSummaryKeepsSeqAndGeometry() {
        let source = EventBus.Event(seq: 1, kind: "surface.output", payload: .object([
            "surface_id": .string("s1"),
            "seq": .number(42),
            "rows": .number(34),
            "cols": .number(120),
            "base64": .string(Data("abc".utf8).base64EncodedString())
        ]), ts: 0)

        let mapped = EventStreamFilter.cellularSafe().map(source)
        let payload = mapped?.payload.objectValue

        XCTAssertEqual(mapped?.kind, "surface.output.summary")
        XCTAssertEqual(payload?["seq"], .number(42),
                       "summarized terminal output must keep per-surface seq so iOS knows whether read_history caught up")
        XCTAssertEqual(payload?["rows"], .number(34))
        XCTAssertEqual(payload?["cols"], .number(120))
    }

    func testCellularSafeGeometryOnlyOutputRemainsLossless() {
        // WHY: an idle resize contains no dropped terminal bytes. Mapping it to
        // a partial summary makes iOS request full history and show a false
        // partial-state warning for every window resize.
        let source = EventBus.Event(seq: 1, kind: "surface.output", payload: .object([
            "surface_id": .string("s1"),
            "seq": .number(43),
            "rows": .number(40),
            "cols": .number(132)
        ]), ts: 0)

        let mapped = EventStreamFilter.cellularSafe().map(source)

        XCTAssertEqual(mapped?.kind, source.kind)
        XCTAssertEqual(mapped?.seq, source.seq)
        XCTAssertEqual(mapped?.payload, source.payload)
        XCTAssertNil(mapped?.payload.objectValue?["base64"])
    }

    func testCellularWebSocketBatcherCoalescesTerminalSummariesPerSurface() {
        let sent = LockedStrings()
        let batcher = WebSocketEventBatcher(enabled: true, filter: .cellularSafe(), delay: 10) { data in
            sent.append(String(decoding: data, as: UTF8.self))
        }

        batcher.enqueue(event: EventBus.Event(seq: 1, kind: "surface.output.summary", payload: .object([
            "surface_id": .string("terminal-1"),
            "seq": .number(1)
        ]), ts: 0), data: Data("old-terminal-1".utf8))
        batcher.enqueue(event: EventBus.Event(seq: 2, kind: "surface.output.summary", payload: .object([
            "surface_id": .string("terminal-1"),
            "seq": .number(2)
        ]), ts: 0), data: Data("new-terminal-1".utf8))
        batcher.enqueue(event: EventBus.Event(seq: 3, kind: "agent.run.completed", payload: .object([
            "thread_id": .string("thread-1")
        ]), ts: 0), data: Data("critical".utf8))
        batcher.flush()

        XCTAssertEqual(sent.values, ["new-terminal-1", "critical"],
                       "on cellular WS, repeated terminal summaries for the same surface should collapse to the newest frame before critical events are sent")
    }

    func testCellularWebSocketBatcherReportsCoalescedAwayFramesForGapAccounting() {
        // WHY (C-14): last-write-wins collapses intermediate surface.output.summary
        // frames. Without onCoalescedAway → recordFilteredEvent, the host watermark
        // sees a hole and closes 1012 during cellular soak.
        let coalesced = LockedStrings()
        let sent = LockedStrings()
        let batcher = WebSocketEventBatcher(
            enabled: true,
            filter: .cellularSafe(),
            delay: 10,
            onCoalescedAway: { data in
                coalesced.append(String(decoding: data, as: UTF8.self))
            },
            send: { data in
                sent.append(String(decoding: data, as: UTF8.self))
            }
        )

        batcher.enqueue(event: EventBus.Event(seq: 10, kind: "surface.output.summary", payload: .object([
            "surface_id": .string("t1"),
            "seq": .number(1)
        ]), ts: 0), data: Data("summary-v1".utf8))
        batcher.enqueue(event: EventBus.Event(seq: 11, kind: "surface.output.summary", payload: .object([
            "surface_id": .string("t1"),
            "seq": .number(2)
        ]), ts: 0), data: Data("summary-v2".utf8))
        batcher.enqueue(event: EventBus.Event(seq: 12, kind: "surface.output.summary", payload: .object([
            "surface_id": .string("t1"),
            "seq": .number(3)
        ]), ts: 0), data: Data("summary-v3".utf8))
        batcher.flush()

        XCTAssertEqual(coalesced.values, ["summary-v1", "summary-v2"],
                       "each superseded summary must be reported so the gap watermark can advance")
        XCTAssertEqual(sent.values, ["summary-v3"],
                       "only the newest summary for the surface should leave the batcher")
    }

    func testCellularNilKeyWindowUsesCallerDelayNotCrossKindDefault() {
        // WHY (C-14/C-15): on cellular the nil-key window must use the longer
        // caller delay (100ms), not the 15ms Wi-Fi crossKindDelay — otherwise
        // agent.item.delta bursts barely coalesce and frames/sec stay high.
        XCTAssertEqual(WebSocketEventBatcher.crossKindDelay, 0.015)
        // Pure model: a 100ms window groups events that a 15ms window would split.
        let events: [(key: String?, data: Data, t: TimeInterval)] = [
            (nil, Data("a".utf8), 0.000),
            (nil, Data("b".utf8), 0.050),
            (nil, Data("c".utf8), 0.090),
        ]
        let short = WebSocketEventBatcher.groupFlushes(events: events, window: 0.015)
        let long = WebSocketEventBatcher.groupFlushes(events: events, window: 0.100)
        XCTAssertGreaterThan(short.count, 1,
                             "15ms window must split a 90ms burst so the cellular delay is load-bearing")
        XCTAssertEqual(long.count, 1,
                       "100ms cellular window must hold the same burst as one flush group")
    }

    func test_C16_agentItemDeltaMerge_concatenatesBodyNotLastWriteWins() throws {
        // WHY (C-16): cellular aggregation must preserve every token; LWW corrupts text.
        func frame(seq: Int64, body: String) throws -> Data {
            let object: [String: Any] = [
                "protocolVersion": 3,
                "type": "event",
                "connectionId": "c1",
                "hostId": "h1",
                "bootEpoch": 1,
                "sequence": seq,
                "eventId": "1:\(seq)",
                "occurredAtEpochMs": 0,
                "kind": "agent.item.delta",
                "payload": [
                    "thread_id": "t1",
                    "item_id": "i1",
                    "body_append": body,
                ],
            ]
            return try JSONSerialization.data(withJSONObject: object)
        }
        let a = try frame(seq: 10, body: "Hello")
        let b = try frame(seq: 11, body: " world")
        let c = try frame(seq: 12, body: "!")
        let merged = try XCTUnwrap(
            WebSocketEventBatcher.mergeAgentItemDeltaFrames(
                try XCTUnwrap(WebSocketEventBatcher.mergeAgentItemDeltaFrames(a, b)),
                c
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: merged) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["body_append"] as? String, "Hello world!")
        XCTAssertEqual(object["sequence"] as? Int, 12)

        let (frames, absorbed) = WebSocketEventBatcher.mergeAgentItemDeltasInOrder([a, b, c])
        XCTAssertEqual(frames.count, 1, "same item_id deltas collapse to one frame")
        XCTAssertEqual(absorbed.count, 2, "absorbed frames report their sequences for gap accounting")
        let outPayload = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: frames[0]) as? [String: Any])?["payload"] as? [String: Any]
        )
        XCTAssertEqual(outPayload["body_append"] as? String, "Hello world!",
                       "rendered text must be byte-identical to unaggregated stream")
    }

    func test_C16_deltaRunMerge_matchesPairwiseSemanticsAndAbsorbedSequenceOrder() throws {
        // WHY: the flush-time fast path must remain wire-compatible with the
        // established pairwise merge while reporting every skipped sequence.
        func frame(seq: Int64, payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "protocolVersion": 3,
                "type": "event",
                "connectionId": "connection-final-\(seq)",
                "sequence": seq,
                "eventId": "1:\(seq)",
                "kind": "agent.item.delta",
                "payload": payload,
            ])
        }

        let identity: [String: Any] = [
            "thread_id": "thread-a",
            "turn_id": "turn-a",
            "item_id": "item-a",
        ]
        let frames = try [
            frame(seq: 20, payload: identity.merging([
                "body_append": "A",
                "output_append": "alpha ",
                "text": "quoted: \\\"",
                "summary": "starting",
                "progress": 0.1,
            ]) { _, new in new }),
            frame(seq: 21, payload: identity.merging([
                "body_append": "",
                "output_append": "beta ",
                "text": "line\\n",
                "progress": 0.4,
            ]) { _, new in new }),
            frame(seq: 22, payload: identity.merging([
                "body_append": "B\\\\",
                "summary": NSNull(),
            ]) { _, new in new }),
            frame(seq: 23, payload: identity.merging([
                "body_append": "👩‍💻",
                "output_append": "gamma",
                "text": "done",
                "final_only": "preserved",
            ]) { _, new in new }),
        ]

        let legacy = try frames.dropFirst().reduce(frames[0]) { current, next in
            try XCTUnwrap(WebSocketEventBatcher.mergeAgentItemDeltaFrames(current, next))
        }
        let optimized = WebSocketEventBatcher.mergeAgentItemDeltasInOrder(frames)
        XCTAssertEqual(optimized.merged.count, 1)
        let output = try XCTUnwrap(optimized.merged.first)

        func canonicalJSON(_ data: Data) throws -> Data {
            let object = try JSONSerialization.jsonObject(with: data)
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        XCTAssertEqual(
            try canonicalJSON(output),
            try canonicalJSON(legacy),
            "linear accumulation must preserve the pairwise merge's complete JSON payload"
        )
        XCTAssertEqual(
            optimized.absorbed.compactMap(WebSocketOutboundQueue.eventSequence(in:)),
            [20, 21, 22],
            "gap accounting must observe every absorbed sequence in arrival order"
        )
        XCTAssertEqual(WebSocketOutboundQueue.eventSequence(in: output), 23,
                       "the emitted frame must retain the final sequence watermark")
    }

    func test_C16_cellularCoalescingKey_requiresThreadItemAndTurn() {
        // WHY: provider item IDs can repeat across both threads and turns. A
        // delta without turn identity must stay in arrival-order buffering so
        // an item-start event can fence a later reuse.
        let event = EventBus.Event(
            seq: 1,
            kind: "agent.item.delta",
            payload: .object([
                "thread_id": .string("thread-3"),
                "item_id": .string("item-9"),
                "body_append": .string("x"),
            ]),
            ts: 0
        )
        XCTAssertNil(
            EventStreamFilter.cellularSafe().coalescingKey(for: event),
            "ordinary deltas without turn_id must not enter cross-event keyed coalescing"
        )
        XCTAssertTrue(EventStreamFilter.cellularSafe().coalescingMergesByConcatenation(for: event))
        XCTAssertNil(EventStreamFilter.full.coalescingKey(for: event),
                     "Wi-Fi uses nil-key streaming coalesce + flush-time concat, not LWW keys")

        let missingThread = EventBus.Event(
            seq: 2,
            kind: "agent.item.delta",
            payload: .object([
                "item_id": .string("item-9"),
                "body_append": .string("legacy"),
            ]),
            ts: 0
        )
        XCTAssertNil(
            EventStreamFilter.cellularSafe().coalescingKey(for: missingThread),
            "a legacy delta without thread_id must stay uncoalesced instead of borrowing item identity"
        )

        let hostMetadata = EventBus.Event(
            seq: 3,
            kind: "agent.item.delta",
            payload: .object([
                "thread_id": .string("thread-3"),
                "turn_id": .string("turn-1"),
                "item_id": .string("item-9"),
                "distill_applied": .bool(true),
            ]),
            ts: 0
        )
        XCTAssertEqual(
            EventStreamFilter.cellularSafe().coalescingKey(for: hostMetadata),
            "agent.item.delta:8:thread-3:6:item-9:turn:6:turn-1",
            "turn-scoped host metadata may coalesce only inside its exact item occurrence"
        )
    }

    func test_C16_agentItemDeltaMerge_requiresSameThreadAndTurn() throws {
        // WHY: coalescing is lossy if an append-only frame erases the latest
        // summary/progress, and unsafe if equal item IDs from different threads
        // or turns mix.
        func frame(
            seq: Int64,
            threadId: String?,
            body: String,
            turnId: String? = nil,
            summary: String? = nil,
            progress: Double? = nil
        ) throws -> Data {
            var payload: [String: Any] = [
                "item_id": "shared-item",
                "body_append": body,
            ]
            if let threadId { payload["thread_id"] = threadId }
            if let turnId { payload["turn_id"] = turnId }
            if let summary { payload["summary"] = summary }
            if let progress { payload["progress"] = progress }
            return try JSONSerialization.data(withJSONObject: [
                "type": "event",
                "sequence": seq,
                "kind": "agent.item.delta",
                "payload": payload,
            ])
        }

        let trusted = try frame(
            seq: 1,
            threadId: "thread-a",
            body: "A",
            turnId: "turn-a",
            summary: "working",
            progress: 0.25
        )
        let laterFalse = try frame(
            seq: 2,
            threadId: "thread-a",
            body: "B",
            turnId: "turn-a"
        )
        let merged = try XCTUnwrap(
            WebSocketEventBatcher.mergeAgentItemDeltaFrames(trusted, laterFalse)
        )
        let mergedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: merged) as? [String: Any]
        )
        let mergedPayload = try XCTUnwrap(mergedObject["payload"] as? [String: Any])
        XCTAssertEqual(mergedPayload["body_append"] as? String, "AB")
        XCTAssertEqual(mergedPayload["summary"] as? String, "working")
        XCTAssertEqual(mergedPayload["progress"] as? Double, 0.25,
                       "an append-only frame must not erase the latest progress update")

        let laterProgress = try frame(
            seq: 3,
            threadId: "thread-a",
            body: "C",
            turnId: "turn-a",
            summary: "done",
            progress: 1
        )
        let completed = try XCTUnwrap(
            WebSocketEventBatcher.mergeAgentItemDeltaFrames(merged, laterProgress)
        )
        let completedPayload = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: completed) as? [String: Any])?["payload"] as? [String: Any]
        )
        XCTAssertEqual(completedPayload["body_append"] as? String, "ABC")
        XCTAssertEqual(completedPayload["summary"] as? String, "done")
        XCTAssertEqual(completedPayload["progress"] as? Double, 1,
                       "the latest explicit progress value remains last-write-wins")

        let otherThread = try frame(
            seq: 4,
            threadId: "thread-b",
            body: "X",
            turnId: "turn-a"
        )
        XCTAssertNil(
            WebSocketEventBatcher.mergeAgentItemDeltaFrames(completed, otherThread),
            "matching item_id values from different threads must never merge"
        )

        let missingThread = try frame(seq: 5, threadId: nil, body: "legacy")
        XCTAssertNil(
            WebSocketEventBatcher.mergeAgentItemDeltaFrames(trusted, missingThread),
            "a missing thread_id must fail safe and remain independently deliverable"
        )

        let missingTurn = try frame(
            seq: 6,
            threadId: "thread-a",
            body: "later turn"
        )
        XCTAssertNil(
            WebSocketEventBatcher.mergeAgentItemDeltaFrames(trusted, missingTurn),
            "a turn-scoped delta must remain a separate frame from ordinary deltas"
        )
    }

    func testCellularSafeInterestParseAndAdmission() {
        // WHY: on-screen interest must drop high-volume deltas for other threads
        // without disabling cellular-safe coalescing when interest is non-empty.
        let empty = EventStreamFilter.parse(filterHeader: "cellular-safe", interestThreadHeader: nil)
        XCTAssertTrue(empty.isCellularSafe)
        XCTAssertEqual(empty, .cellularSafe(interestThreadIds: []))

        let interested = EventStreamFilter.parse(
            filterHeader: "cellular-safe",
            interestThreadHeader: " t-live , t-live "
        )
        guard case .cellularSafe(let ids) = interested else {
            return XCTFail("expected cellularSafe")
        }
        XCTAssertEqual(ids, ["t-live"])
        XCTAssertTrue(interested.isCellularSafe,
                      "non-empty interest must still be isCellularSafe (not == .cellularSafe only)")

        let deltaOther = EventBus.Event(
            seq: 1,
            kind: "agent.item.delta",
            payload: .object([
                "thread_id": .string("t-other"),
                "item_id": .string("i1"),
                "body_append": .string("x"),
            ]),
            ts: 0
        )
        let deltaLive = EventBus.Event(
            seq: 2,
            kind: "agent.item.delta",
            payload: .object([
                "thread_id": .string("t-live"),
                "item_id": .string("i2"),
                "body_append": .string("y"),
            ]),
            ts: 0
        )
        let completedOther = EventBus.Event(
            seq: 3,
            kind: "agent.run.completed",
            payload: .object(["thread_id": .string("t-other")]),
            ts: 0
        )

        XCTAssertNil(interested.map(deltaOther), "non-interest delta must drop")
        XCTAssertEqual(interested.map(deltaLive)?.kind, "agent.item.delta")
        XCTAssertEqual(interested.map(completedOther)?.kind, "agent.run.completed",
                       "lifecycle still passes for non-selected threads")
        XCTAssertEqual(empty.map(deltaOther)?.kind, "agent.item.delta",
                       "empty interest fails open to prior cellular-safe behavior")
    }

    func testIsCellularSafeIgnoresInterestEqualityTrap() {
        // WHY: `filter == .cellularSafe` only matches empty interest Set default
        // and would disable coalescing/heartbeat cellular profiles after interest.
        let withInterest = EventStreamFilter.cellularSafe(interestThreadIds: ["t1"])
        XCTAssertTrue(withInterest.isCellularSafe)
        XCTAssertNotEqual(withInterest, .cellularSafe())
        XCTAssertEqual(
            DirectHTTPServer.heartbeatProfile(forWSFilter: withInterest),
            DirectHTTPServer.heartbeatProfile(forWSFilter: .cellularSafe())
        )
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

final class ActivityChangedAdmissionTests: XCTestCase {
    func testActivityChangedReachesFullAndCellularStreams() {
        // WHY: iOS mirrors Activity counts from this event on both the default and the
        // cellular stream; a filter that drops it leaves the phone on stale counts.
        let bus = EventBus()
        var full: [String] = []
        var cellular: [String] = []
        _ = bus.subscribe(since: nil) { full.append($0.kind) }
        _ = bus.subscribe(since: nil, filter: .cellularSafe()) { cellular.append($0.kind) }
        bus.publish(kind: .agentActivityChanged, payload: .object([
            "workspace_id": .string("ws"),
            "counts": .object(["running": .number(1)]),
            "changed_thread_ids": .array([.string("t")]),
        ]))
        XCTAssertEqual(full, ["agent.activity.changed"])
        XCTAssertEqual(cellular, ["agent.activity.changed"])
    }

    func testActivityChangedIsNotLiveOnlyOrRevisionExempt() {
        // WHY: it must stay in the durable log and advance the snapshot state, or a
        // reconnecting client cannot recover counts it missed.
        XCTAssertFalse(EventBus.liveOnlyStreamEventKinds.contains("agent.activity.changed"))
    }
}
