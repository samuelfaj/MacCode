import XCTest
@testable import SocketServer
import CoreModel

/// Wire + bounding contract for agent.thread.read response_version=1.
///
/// WHY: weak-network iOS recovery must never force the host to load the full
/// event history or emit a multi-MiB response. Legacy callers omit
/// `response_version` and must keep the previous shapes/behavior. The envelope
/// cap must count JSON escaping, separators, and keys — not just payload sums.
@MainActor
final class AgentThreadReadV1Tests: XCTestCase {

    private let encoder = JSONEncoder()

    private func encodeEvent(_ event: AssistantEvent) -> JSONValue {
        guard let data = try? encoder.encode(event),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return value
    }

    private func measureEnvelope(id: JSONRPCID?, result: JSONValue) -> Int {
        let response = JSONRPCResponse(id: id, result: result)
        return (try? encoder.encode(response))?.count ?? Int.max
    }

    private let v1Keys: Set<String> = [
        "events",
        "event_watermark",
        "events_truncated",
        "response_truncated",
        "truncation_reason",
        "has_more",
        "blocked_event",
    ]

    // MARK: - parseCaps

    func test_parseCapsAbsentResponseVersionIsLegacy() throws {
        XCTAssertNil(try AgentThreadReadV1.parseCaps([
            "thread_id": .string(UUID().uuidString),
            "include_event_watermark": .bool(true),
            "event_limit": .number(2),
        ]))
    }

    func test_parseCapsRejectsMalformedUnknownAndOutOfRange() {
        let tid = UUID().uuidString
        let cases: [[String: JSONValue]] = [
            ["response_version": .number(2), "thread_id": .string(tid), "include_event_watermark": .bool(true)],
            ["response_version": .number(1.5), "thread_id": .string(tid), "include_event_watermark": .bool(true)],
            ["response_version": .number(Double.infinity), "thread_id": .string(tid), "include_event_watermark": .bool(true)],
            ["response_version": .number(Double.nan), "thread_id": .string(tid), "include_event_watermark": .bool(true)],
            ["response_version": .string("1"), "thread_id": .string(tid), "include_event_watermark": .bool(true)],
            ["response_version": .bool(true), "thread_id": .string(tid), "include_event_watermark": .bool(true)],
            ["response_version": .null, "thread_id": .string(tid), "include_event_watermark": .bool(true)],
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true), "extra": .string("nope")],
            ["response_version": .number(1), "thread_id": .string(tid)], // missing watermark
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(false)],
            ["response_version": .number(1), "include_event_watermark": .bool(true)], // missing thread_id
            ["response_version": .number(1), "thread_id": .string("not-a-uuid"), "include_event_watermark": .bool(true)],
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true), "event_limit": .number(0)],
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true), "event_limit": .number(501)],
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true), "event_limit": .number(1.5)],
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true), "event_limit": .number(Double.infinity)],
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true), "max_bytes": .number(1024)],
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true), "max_bytes": .number(Double(256 * 1024 + 1))],
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true), "max_bytes": .string("65536")],
            ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true), "max_bytes": .number(Double.nan)],
        ]
        for (index, params) in cases.enumerated() {
            XCTAssertThrowsError(try AgentThreadReadV1.parseCaps(params), "case \(index)") { error in
                XCTAssertEqual((error as? JSONRPCError)?.code, JSONRPCError.invalidParams.code, "case \(index)")
            }
        }
    }

    func test_parseCapsAcceptsDefaultsAndBounds() throws {
        let tid = UUID()
        let defaults = try XCTUnwrap(try AgentThreadReadV1.parseCaps([
            "thread_id": .string(tid.uuidString),
            "include_event_watermark": .bool(true),
            "response_version": .number(1),
        ]))
        XCTAssertEqual(defaults.threadId.value, tid)
        XCTAssertEqual(defaults.eventLimit, AgentThreadReadV1.defaultEventLimit)
        XCTAssertEqual(defaults.eventLimit, 128)
        XCTAssertEqual(defaults.maxBytes, AgentThreadReadV1.maxMaxBytes)
        XCTAssertEqual(defaults.maxBytes, 128 * 1024)

        let custom = try XCTUnwrap(try AgentThreadReadV1.parseCaps([
            "thread_id": .string(tid.uuidString),
            "include_event_watermark": .bool(true),
            "response_version": .number(1),
            "event_limit": .number(1),
            "max_bytes": .number(Double(32 * 1024)),
        ]))
        XCTAssertEqual(custom.eventLimit, 1)
        XCTAssertEqual(custom.maxBytes, 32 * 1024)
    }

    // MARK: - boundToEnvelope

    func test_boundKeepsNewestContiguousSuffixUnderEnvelopeMaxBytes() {
        let events: [AssistantEvent] = [
            .turnStarted(turnId: "old"),
            .turnStarted(turnId: "mid"),
            .turnStarted(turnId: "new"),
        ]
        let encoded = events.map(encodeEvent)
        let id = JSONRPCID.number(1)
        let all = AgentThreadReadV1.boundToEnvelope(
            events: events,
            encodedEvents: encoded,
            sourceHadOlderEvents: false,
            blockedEvent: nil,
            maxBytes: Int.max / 4,
            eventWatermark: 7,
            responseId: id,
            measureEnvelope: { self.measureEnvelope(id: id, result: $0) }
        )
        XCTAssertEqual(all.events.count, 3)
        let allSize = measureEnvelope(
            id: id,
            result: AgentThreadReadV1.payload(window: all, eventWatermark: 7)
        )

        // Just under full three-event envelope → drop oldest, keep mid+new.
        let window = AgentThreadReadV1.boundToEnvelope(
            events: events,
            encodedEvents: encoded,
            sourceHadOlderEvents: false,
            blockedEvent: nil,
            maxBytes: allSize - 1,
            eventWatermark: 7,
            responseId: id,
            measureEnvelope: { self.measureEnvelope(id: id, result: $0) }
        )
        XCTAssertEqual(window.events.map {
            if case .turnStarted(let tid) = $0 { return tid }
            return "?"
        }, ["mid", "new"])
        XCTAssertTrue(window.eventsTruncated)
        XCTAssertTrue(window.responseTruncated)
        XCTAssertTrue(window.hasMore)
        XCTAssertEqual(window.truncationReason, .byteLimit)
        XCTAssertNil(window.blockedEvent)
        let finalSize = measureEnvelope(
            id: id,
            result: AgentThreadReadV1.payload(window: window, eventWatermark: 7)
        )
        XCTAssertLessThanOrEqual(finalSize, allSize - 1)
    }

    func test_boundReturnsEmptyHonestPartialWhenNewestBlockedAtSource() {
        let blocked = AgentThreadReadV1.BlockedEvent(id: 99, payloadBytes: 16_777_216, reason: "byte_limit")
        let id = JSONRPCID.number(3)
        let window = AgentThreadReadV1.boundToEnvelope(
            events: [],
            encodedEvents: [],
            sourceHadOlderEvents: true,
            blockedEvent: blocked,
            maxBytes: 32 * 1024,
            eventWatermark: 42,
            responseId: id,
            measureEnvelope: { self.measureEnvelope(id: id, result: $0) }
        )
        XCTAssertTrue(window.events.isEmpty)
        XCTAssertTrue(window.hasMore)
        XCTAssertEqual(window.truncationReason, .byteLimit)
        XCTAssertEqual(window.blockedEvent?.id, 99)
        XCTAssertEqual(window.blockedEvent?.payloadBytes, 16_777_216)
        let body = AgentThreadReadV1.payload(window: window, eventWatermark: 42).objectValue
        XCTAssertEqual(body?["blocked_event"]?.objectValue?["id"], .number(99))
        XCTAssertEqual(body?["has_more"], .bool(true))
    }

    func test_boundCountLimitReasonWhenSourceHadOlderAndBytesFit() {
        let events: [AssistantEvent] = [
            .turnStarted(turnId: "a"),
            .turnStarted(turnId: "b"),
        ]
        let encoded = events.map(encodeEvent)
        let id = JSONRPCID.number(2)
        let window = AgentThreadReadV1.boundToEnvelope(
            events: events,
            encodedEvents: encoded,
            sourceHadOlderEvents: true,
            blockedEvent: nil,
            maxBytes: AgentThreadReadV1.maxMaxBytes,
            eventWatermark: 1,
            responseId: id,
            measureEnvelope: { self.measureEnvelope(id: id, result: $0) }
        )
        XCTAssertEqual(window.events.count, 2)
        XCTAssertTrue(window.eventsTruncated)
        XCTAssertTrue(window.hasMore)
        XCTAssertEqual(window.truncationReason, .countLimit)
    }

    func test_boundEscapeHeavyEventsCountedInEnvelopeNotPayloadSum() {
        // Backslashes and quotes expand under JSON string escaping; a naive sum
        // of unescaped payload lengths undercounts the real envelope.
        let heavy = String(repeating: "\\\"", count: 4_000)
        let events: [AssistantEvent] = [
            .error(message: "old-\(heavy)", recoverable: false),
            .error(message: "new-\(heavy)", recoverable: false),
        ]
        let encoded = events.map(encodeEvent)
        let id = JSONRPCID.number(9)

        let both = AgentThreadReadV1.boundToEnvelope(
            events: events,
            encodedEvents: encoded,
            sourceHadOlderEvents: false,
            blockedEvent: nil,
            maxBytes: Int.max / 4,
            eventWatermark: 1,
            responseId: id,
            measureEnvelope: { self.measureEnvelope(id: id, result: $0) }
        )
        XCTAssertEqual(both.events.count, 2)
        let bothSize = measureEnvelope(
            id: id,
            result: AgentThreadReadV1.payload(window: both, eventWatermark: 1)
        )

        // Cap just under the full two-event envelope so only the newest remains.
        let window = AgentThreadReadV1.boundToEnvelope(
            events: events,
            encodedEvents: encoded,
            sourceHadOlderEvents: false,
            blockedEvent: nil,
            maxBytes: bothSize - 1,
            eventWatermark: 1,
            responseId: id,
            measureEnvelope: { self.measureEnvelope(id: id, result: $0) }
        )
        XCTAssertEqual(window.events.count, 1, "escape-heavy pair must collapse to newest under envelope cap")
        guard case .error(let message, _) = window.events.first else {
            return XCTFail("expected newest error event")
        }
        XCTAssertTrue(message.hasPrefix("new-"))
        let finalSize = measureEnvelope(
            id: id,
            result: AgentThreadReadV1.payload(window: window, eventWatermark: 1)
        )
        XCTAssertLessThanOrEqual(finalSize, bothSize - 1)
        XCTAssertEqual(window.truncationReason, .byteLimit)

        // Escaped wire size of one event exceeds its raw message UTF-8 length.
        if case .error(let raw, _) = events[1] {
            XCTAssertGreaterThan(finalSize, raw.utf8.count)
        }
    }

    // MARK: - Dispatcher integration

    func test_legacyWithoutResponseVersionUnchangedAndUnrestricted() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.readAgentEvents = [
            .turnStarted(turnId: "t1"),
            .turnStarted(turnId: "t2"),
            .turnStarted(turnId: "t3"),
        ]
        let dispatcher = JSONRPCDispatcher(router: router)

        let watermark = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "event_limit": .number(2),
            ]
        ))
        let result = try XCTUnwrap(watermark.result?.objectValue)
        XCTAssertEqual(Set(result.keys), ["events", "event_watermark", "events_truncated"],
                       "legacy watermark shape must not gain v1 keys")
        XCTAssertEqual(result["events"]?.arrayValue?.count, 2)
        XCTAssertEqual(result["events_truncated"], .bool(true))
        XCTAssertEqual(router.lastMirrorSnapshotEventRowLimit, 2,
                       "legacy event_limit reaches SQL; the shape stays legacy")
        XCTAssertNil(router.lastMirrorSnapshotMaxPayloadBytes)
        XCTAssertNil(result["response_truncated"])
        XCTAssertNil(result["truncation_reason"])
        XCTAssertNil(result["has_more"])
        XCTAssertNil(result["blocked_event"])

        let plain = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.thread.read",
            params: ["thread_id": .string(thread.value.uuidString)]
        ))
        XCTAssertEqual(plain.result?.arrayValue?.count, 3,
                       "legacy array path must still return every event")
    }

    func test_v1PushesEventAndByteLimitsIntoRouterAndReturnsExactEnvelope() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.readAgentEvents = (0..<5).map { .turnStarted(turnId: "turn-\($0)") }
        let dispatcher = JSONRPCDispatcher(router: router)

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(1),
                "event_limit": .number(2),
                "max_bytes": .number(Double(AgentThreadReadV1.maxMaxBytes)),
            ]
        ))

        let body = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(Set(body.keys), v1Keys)
        let events = try XCTUnwrap(body["events"]?.arrayValue)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(
            events.first?.objectValue?["turnStarted"]?.objectValue?["turnId"],
            .string("turn-3")
        )
        XCTAssertEqual(
            events.last?.objectValue?["turnStarted"]?.objectValue?["turnId"],
            .string("turn-4")
        )
        XCTAssertEqual(body["events_truncated"], .bool(true))
        XCTAssertEqual(body["response_truncated"], .bool(true))
        XCTAssertEqual(body["has_more"], .bool(true))
        XCTAssertEqual(body["truncation_reason"], .string("count_limit"))
        XCTAssertEqual(body["blocked_event"], .null)
        XCTAssertEqual(router.readAgentThreadMirrorSnapshotCallCount, 1)
        XCTAssertEqual(router.lastMirrorSnapshotEventRowLimit, 2)
        XCTAssertEqual(router.lastMirrorSnapshotMaxPayloadBytes, Int64(AgentThreadReadV1.maxMaxBytes))

        // Full response must fit the requested max_bytes.
        let envelope = JSONRPCResponse(id: .number(1), result: response.result)
        let size = try encoder.encode(envelope).count
        XCTAssertLessThanOrEqual(size, AgentThreadReadV1.maxMaxBytes)
    }

    func test_v1MalformedParamsNeverCallRouter() async {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.readAgentEvents = [.turnStarted(turnId: "seed")]
        let dispatcher = JSONRPCDispatcher(router: router)

        let cases: [[String: JSONValue]] = [
            [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(2),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(1.5),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(Double.infinity),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(1),
                "extra": .bool(true),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(1),
                "event_limit": .number(0),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(1),
                "max_bytes": .number(8),
            ],
        ]

        for (index, params) in cases.enumerated() {
            router.readAgentThreadMirrorSnapshotCallCount = 0
            let response = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(index),
                method: "agent.thread.read",
                params: params
            ))
            XCTAssertEqual(response.error?.code, -32602, "case \(index)")
            XCTAssertNil(response.result)
            XCTAssertEqual(router.readAgentThreadMirrorSnapshotCallCount, 0, "case \(index)")
        }
    }

    func test_v1ByteLimitDropsOldestAndOversizedNewestReturnsEmptyPartial() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        // ~20 KiB payloads so min legal max_bytes (32 KiB) keeps newest only.
        let pad = String(repeating: "x", count: 20_000)
        router.readAgentEvents = [
            .error(message: "old-\(pad)", recoverable: false),
            .error(message: "mid-\(pad)", recoverable: false),
            .error(message: "new-\(pad)", recoverable: false),
        ]
        let dispatcher = JSONRPCDispatcher(router: router)
        let maxBytes = 32 * 1024

        let truncated = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(1),
                "event_limit": .number(3),
                "max_bytes": .number(Double(maxBytes)),
            ]
        ))
        let body = try XCTUnwrap(truncated.result?.objectValue)
        let events = try XCTUnwrap(body["events"]?.arrayValue)
        XCTAssertEqual(events.count, 1, "32 KiB must fit only the newest ~20 KiB event")
        XCTAssertEqual(
            events.first?.objectValue?["error"]?.objectValue?["message"]?.stringValue?.hasPrefix("new-"),
            true
        )
        XCTAssertEqual(body["truncation_reason"], .string("byte_limit"))
        XCTAssertEqual(body["events_truncated"], .bool(true))
        XCTAssertEqual(body["response_truncated"], .bool(true))
        XCTAssertEqual(body["has_more"], .bool(true))
        let env1 = try encoder.encode(JSONRPCResponse(id: .number(1), result: truncated.result))
        XCTAssertLessThanOrEqual(env1.count, maxBytes)

        // Source-blocked oversized newest → empty events + blocked_event metadata.
        router.readAgentEvents = []
        router.mirrorBlockedEvent = .init(id: 77, payloadBytes: 16_777_216, reason: "byte_limit")
        let zero = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(1),
                "event_limit": .number(1),
                "max_bytes": .number(Double(maxBytes)),
            ]
        ))
        let zeroBody = try XCTUnwrap(zero.result?.objectValue)
        XCTAssertEqual(zeroBody["events"]?.arrayValue?.count, 0,
                       "when the newest event alone exceeds max_bytes, return zero events")
        XCTAssertEqual(zeroBody["truncation_reason"], .string("byte_limit"))
        XCTAssertEqual(zeroBody["events_truncated"], .bool(true))
        XCTAssertEqual(zeroBody["response_truncated"], .bool(true))
        XCTAssertEqual(zeroBody["has_more"], .bool(true))
        XCTAssertEqual(zeroBody["blocked_event"]?.objectValue?["id"], .number(77))
        XCTAssertEqual(zeroBody["blocked_event"]?.objectValue?["payload_bytes"], .number(16_777_216))
        XCTAssertEqual(zeroBody["blocked_event"]?.objectValue?["reason"], .string("byte_limit"))
    }

    func test_v1CanonicalChronologicalOrderPreserved() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.readAgentEvents = [
            .turnStarted(turnId: "first"),
            .turnCompleted(turnId: "first", finalMessage: nil),
            .turnStarted(turnId: "second"),
        ]
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(1),
                "event_limit": .number(3),
                "max_bytes": .number(Double(AgentThreadReadV1.maxMaxBytes)),
            ]
        ))
        let events = try XCTUnwrap(response.result?.objectValue?["events"]?.arrayValue)
        XCTAssertEqual(events.count, 3)
        XCTAssertNotNil(events[0].objectValue?["turnStarted"])
        XCTAssertNotNil(events[1].objectValue?["turnCompleted"])
        XCTAssertNotNil(events[2].objectValue?["turnStarted"])
        XCTAssertEqual(response.result?.objectValue?["truncation_reason"], .null)
        XCTAssertEqual(response.result?.objectValue?["events_truncated"], .bool(false))
        XCTAssertEqual(response.result?.objectValue?["response_truncated"], .bool(false))
        XCTAssertEqual(response.result?.objectValue?["has_more"], .bool(false))
        XCTAssertEqual(response.result?.objectValue?["blocked_event"], .null)
    }

    func test_v1ExactEnvelopeCapNeverExceededAfterEscaping() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        // Mix of multibyte + escape-heavy content.
        let multi = String(repeating: " ind\\", count: 800)
        router.readAgentEvents = (0..<6).map { index in
            .error(message: "e\(index)-\(multi)", recoverable: false)
        }
        let dispatcher = JSONRPCDispatcher(router: router)
        let maxBytes = 40 * 1024
        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(44),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "response_version": .number(1),
                "event_limit": .number(6),
                "max_bytes": .number(Double(maxBytes)),
            ]
        ))
        let body = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(Set(body.keys), v1Keys)
        let data = try encoder.encode(JSONRPCResponse(id: .number(44), result: response.result))
        XCTAssertLessThanOrEqual(data.count, maxBytes, "final envelope must respect max_bytes after escaping")
        XCTAssertGreaterThan(body["events"]?.arrayValue?.count ?? 0, 0)
        // Contiguous newest suffix: last event is e5.
        let lastMessage = body["events"]?.arrayValue?.last?
            .objectValue?["error"]?.objectValue?["message"]?.stringValue
        XCTAssertEqual(lastMessage?.hasPrefix("e5-"), true)
    }

    func test_defaultEventLimitIs128() {
        XCTAssertEqual(AgentThreadReadV1.defaultEventLimit, 128)
        XCTAssertEqual(AgentThreadReadV1.maxEventLimit, 128)
        XCTAssertEqual(AgentThreadReadV1.defaultEventLimit, AgentThreadReadV1.maxEventLimit)
    }

    func test_retentionEstimate_256EventsTo128Window() {
        let uncapped = 256 // prior default/max event limit
        let limit = AgentThreadReadV1.defaultEventLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128)
        // Basis: typical agent stream event payload ≈ 1KB after SQLite decode +
        // envelope encode work. Prior default/max was 256 events per read.
        // 256 × 1KB ≈ 256KB → 128 × 1KB ≈ 128KB (−50%) peak decode window.
        // Byte envelope still hard-caps at maxMaxBytes (128 KiB).
        let perEvent = 1_024
        XCTAssertEqual(uncapped * perEvent, 262_144)
        XCTAssertEqual(limit * perEvent, 131_072)
    }


    func test_retentionEstimate_maxMaxBytes_256KiBTo128KiB() {
        let prior = 256 * 1_024
        let limit = AgentThreadReadV1.maxMaxBytes
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128 * 1_024)
        XCTAssertEqual(AgentThreadReadV1.defaultMaxBytes, limit)

        // Basis: peak JSON-RPC agent.thread.read v1 envelope budget.
        // 256 KiB → 128 KiB (−50%) per read response.
        XCTAssertEqual(prior, 262_144)
        XCTAssertEqual(limit, 131_072)
    }

}
