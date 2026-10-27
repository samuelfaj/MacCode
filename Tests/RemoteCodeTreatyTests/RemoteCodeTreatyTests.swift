import XCTest
@testable import RemoteCodeTreaty

final class RemoteCodeTreatyTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testCompatibilityUsesStableSnakeCaseWireKeys() throws {
        let value = TreatyCompatibility(
            current: TreatyVersion(major: 1, minor: 0),
            supportedMajors: [0, 1]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any]
        )
        XCTAssertEqual((object["current"] as? [String: Any])?["major"] as? Int, 1)
        XCTAssertEqual((object["current"] as? [String: Any])?["minor"] as? Int, 0)
        XCTAssertEqual(object["supported_majors"] as? [Int], [0, 1])
    }

    func testBotSendParamsPreserveExistingWireShape() throws {
        let params = BotSend.Params(
            botID: "bot-1",
            conversationID: "conversation-1",
            text: "hello",
            submitKey: "return",
            attachmentIDs: ["grant-1"]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(params)) as? [String: Any]
        )
        XCTAssertEqual(object["bot_id"] as? String, "bot-1")
        XCTAssertEqual(object["conversation_id"] as? String, "conversation-1")
        XCTAssertEqual(object["submit_key"] as? String, "return")
        XCTAssertEqual(object["attachment_ids"] as? [String], ["grant-1"])
        XCTAssertNil(object["client_request_id"])
    }

    func testBotSendParamsCarryTheDistillWorkerRoute() throws {
        // WHY: a paired send must be able to name the exact Worker/efforts the
        // routing receipt admitted; older clients omit them unchanged.
        let params = BotSend.Params(
            botID: "bot-1",
            text: "hello",
            submitKey: "return",
            workerModel: "worker-a",
            workerEffort: "high",
            distillMainEffort: "auto"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(params)) as? [String: Any]
        )
        XCTAssertEqual(object["worker_model"] as? String, "worker-a")
        XCTAssertEqual(object["worker_effort"] as? String, "high")
        XCTAssertEqual(object["distill_main_effort"] as? String, "auto")
        XCTAssertEqual(try JSONDecoder().decode(BotSend.Params.self, from: encoder.encode(params)), params)

        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(BotSend.Params(botID: "bot-1", text: "hi", submitKey: "return"))
        ) as? [String: Any])
        XCTAssertNil(legacy["worker_model"], "absent Worker fields stay off the wire")
    }

    func testBotSendResultDecodesCurrentStartedReceipt() throws {
        let data = Data(#"""
        {
          "request_id":"request-1","client_request_id":"request-1",
          "receipt_id":"receipt-1","status":"completed","host_id":"host-1","bot_id":"bot-1",
          "readback":{"host_id":"host-1","bot_id":"bot-1","request_id":"request-1",
            "client_request_id":"request-1","conversation_id":"conversation-1","run_id":"run-1",
            "enqueued":false,"run":{"host_id":"host-1","bot_id":"bot-1","request_id":"request-1",
              "client_request_id":"request-1","conversation_id":"conversation-1","run_id":"run-1",
              "thread_id":"thread-1"}}
        }
        """#.utf8)

        let result = try decoder.decode(BotSend.Result.self, from: data)
        XCTAssertEqual(result.requestID, "request-1")
        XCTAssertEqual(result.receiptID, "receipt-1")
        XCTAssertEqual(result.hostID, "host-1")
        XCTAssertEqual(result.botID, "bot-1")
        XCTAssertEqual(result.conversationID, "conversation-1")
        XCTAssertEqual(result.runID, "run-1")
        XCTAssertEqual(result.disposition, .started(threadID: "thread-1"))
    }

    func testBotSendResultDecodesCurrentQueuedReceipt() throws {
        let data = Data(#"""
        {
          "request_id":"request-2","client_request_id":"request-2",
          "receipt_id":"receipt-2","status":"completed","host_id":"host-1","bot_id":"bot-1",
          "readback":{"host_id":"host-1","bot_id":"bot-1","request_id":"request-2",
            "client_request_id":"request-2","conversation_id":"conversation-1","run_id":"run-1",
            "enqueued":true,"id":"queue-1","queue":[{"id":"queue-1","bot_id":"bot-1",
              "conversation_id":"conversation-1"}]}
        }
        """#.utf8)

        let result = try decoder.decode(BotSend.Result.self, from: data)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.runID, "run-1")
        XCTAssertEqual(result.disposition, .queued(queueID: "queue-1"))
    }

    func testBotSendResultRejectsUnownedQueueReadback() throws {
        let data = Data(#"""
        {
          "request_id":"request-2","client_request_id":"request-2",
          "receipt_id":"receipt-2","status":"completed","host_id":"host-1","bot_id":"bot-1",
          "readback":{"host_id":"host-1","bot_id":"bot-1","request_id":"request-2",
            "client_request_id":"request-2","conversation_id":"conversation-1","run_id":"run-1",
            "enqueued":true,"id":"queue-1","queue":[{"id":"queue-1","bot_id":"bot-2",
              "conversation_id":"conversation-1"}]}
        }
        """#.utf8)

        XCTAssertThrowsError(try decoder.decode(BotSend.Result.self, from: data))
    }

    func testBotUploadTargetAndGrantPreserveCurrentWire() throws {
        let target = BotUploadTarget(
            botID: "bot-1",
            conversationID: "conversation-1",
            attachmentID: "opaque-upload-1",
            filename: "proof.txt",
            kind: "file",
            digest: String(repeating: "a", count: 64),
            size: 5,
            mimeType: "text/plain"
        )
        let targetObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(target)) as? [String: Any]
        )
        XCTAssertEqual(targetObject["bot_id"] as? String, "bot-1")
        XCTAssertEqual(targetObject["conversation_id"] as? String, "conversation-1")
        XCTAssertEqual(targetObject["attachment_id"] as? String, "opaque-upload-1")
        XCTAssertEqual(targetObject["filename"] as? String, "proof.txt")
        XCTAssertEqual(targetObject["kind"] as? String, "file")
        XCTAssertEqual(targetObject["mime_type"] as? String, "text/plain")

        let grantData = Data(#"""
        {"id":"grant-1","bot_id":"bot-1","conversation_id":"conversation-1",
         "attachment_id":"opaque-upload-1","filename":"proof.txt","kind":"file",
         "digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "size":5,"mime_type":"text/plain","consumed":false}
        """#.utf8)
        let grant = try decoder.decode(BotAttachmentGrant.self, from: grantData)
        XCTAssertEqual(grant.attachmentID, "opaque-upload-1")
        XCTAssertEqual(grant.filename, "proof.txt")
        XCTAssertEqual(grant.mimeType, "text/plain")
        XCTAssertFalse(grant.consumed)
    }

    func testBotUploadTargetMapsTheExistingUploadResultStrictly() throws {
        let upload = try decoder.decode(RemoteCodeJSONValue.self, from: Data(#"""
        {"id":"opaque-upload-1","display_name":"proof.txt","kind":"file",
         "mime_type":"text/plain",
         "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "size_bytes":5,"composer_insertion_text":"/host/proof.txt"}
        """#.utf8))
        let target = try XCTUnwrap(BotUploadTarget(
            botID: "bot-1",
            conversationID: "conversation-1",
            uploadResult: upload
        ))
        XCTAssertEqual(target.attachmentID, "opaque-upload-1")
        XCTAssertEqual(target.filename, "proof.txt")
        XCTAssertEqual(target.digest, String(repeating: "a", count: 64))
        XCTAssertEqual(target.size, 5)

        XCTAssertNil(BotUploadTarget(
            botID: "bot-1",
            conversationID: "conversation-1",
            uploadResult: .object(["id": .string("opaque-upload-1")])
        ))
    }

    func testBotAttachmentStageAndRemoveReceiptsDecodeCurrentWire() throws {
        let stage = try decoder.decode(BotAttachmentStage.Result.self, from: Data(#"""
        {"request_id":"stage-1","receipt_id":"receipt-1","status":"completed","bot_id":"bot-1",
         "readback":{"id":"grant-1","bot_id":"bot-1","conversation_id":"conversation-1",
         "attachment_id":"opaque-upload-1","filename":"proof.txt","kind":"file",
         "digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "size":5,"mime_type":"text/plain","consumed":false}}
        """#.utf8))
        XCTAssertEqual(stage.botID, "bot-1")
        XCTAssertEqual(stage.readback.id, "grant-1")
        XCTAssertFalse(stage.readback.consumed)

        let remove = try decoder.decode(BotAttachmentRemove.Result.self, from: Data(#"""
        {"request_id":"remove-1","receipt_id":"receipt-2","status":"completed","bot_id":"bot-1",
         "readback":{"removed":true,"id":"grant-1","bot_id":"bot-1",
         "conversation_id":"conversation-1"}}
        """#.utf8))
        XCTAssertTrue(remove.readback.removed)
        XCTAssertEqual(remove.readback.id, "grant-1")
    }

    func testAuthenticatedCapabilitiesDecodeTreatyAndIdentity() throws {
        let data = Data(#"""
        {
          "authenticated":true,"server_id":"host-1","boot_epoch":42,
          "treaty":{"current":{"major":1,"minor":0},"supported_majors":[0,1]},
          "capabilities":{"surface_types":["terminal","agentApp"],
            "agent":{"providers":["codex"],"supports_stream_events":true,"supports_resume":true},
            "git":{"read_only":false},"feature_flags":{"remote_access_enabled":true},
            "bot":{"queue_controls":["remove","update","reorder","force_now"]}}
        }
        """#.utf8)

        let envelope = try decoder.decode(AuthenticatedCapabilities.self, from: data)
        XCTAssertTrue(envelope.authenticated)
        XCTAssertEqual(envelope.serverID, "host-1")
        XCTAssertEqual(envelope.bootEpoch, 42)
        XCTAssertEqual(envelope.treaty?.current, TreatyVersion(major: 1, minor: 0))
        XCTAssertEqual(envelope.capabilities.surfaceTypes, ["terminal", "agentApp"])
        XCTAssertEqual(envelope.capabilities.agent.providers, ["codex"])
        XCTAssertEqual(
            envelope.capabilities.bot?.queueControls,
            ["remove", "update", "reorder", "force_now"]
        )
    }

    /// C-W: the client compares this digest with the welcome's
    /// `capabilitiesDigest`; hosts that predate it must still decode (nil).
    func testAuthenticatedCapabilitiesDigestIsOptional() throws {
        func envelope(_ extra: String) throws -> AuthenticatedCapabilities {
            try decoder.decode(AuthenticatedCapabilities.self, from: Data(#"""
            {
              "authenticated":true,"server_id":"host-1","boot_epoch":42,\#(extra)
              "capabilities":{"surface_types":["terminal"],
                "agent":{"providers":["codex"],"supports_stream_events":true,"supports_resume":true}}
            }
            """#.utf8))
        }
        XCTAssertNil(try envelope("").capabilitiesDigest)
        XCTAssertEqual(
            try envelope(#""capabilities_digest":"abc123","#).capabilitiesDigest,
            "abc123"
        )
    }

    func testCompatibilityAcceptsLegacyV0V1AndFutureMinorButRejectsIncompatibleMajor() {
        XCTAssertEqual(TreatyCompatibility.evaluate(host: nil), .compatibleLegacyV0)
        XCTAssertEqual(
            TreatyCompatibility.evaluate(host: .v1),
            .compatible(TreatyVersion(major: 1, minor: 0))
        )
        let futureMinor = TreatyCompatibility(
            current: TreatyVersion(major: 1, minor: 9),
            supportedMajors: [0, 1]
        )
        XCTAssertEqual(
            TreatyCompatibility.evaluate(host: futureMinor),
            .compatible(TreatyVersion(major: 1, minor: 9))
        )
        let incompatible = TreatyCompatibility(
            current: TreatyVersion(major: 2, minor: 0),
            supportedMajors: [0, 2]
        )
        XCTAssertEqual(
            TreatyCompatibility.evaluate(host: incompatible),
            .updateRequired
        )
    }

    func testAuthenticatedCapabilitiesRejectsMalformedTreaty() {
        let data = Data(#"""
        {
          "authenticated":true,"server_id":"host-1","boot_epoch":42,
          "treaty":{"current":"1.0","supported_majors":[0,1]},
          "capabilities":{"surface_types":[],
            "agent":{"providers":[],"supports_stream_events":true,"supports_resume":true},
            "git":{"read_only":false},"feature_flags":{"remote_access_enabled":true}}
        }
        """#.utf8)
        XCTAssertThrowsError(try decoder.decode(AuthenticatedCapabilities.self, from: data))
    }

    func testEventEnvelopePreservesKnownAndUnknownKinds() throws {
        let known = try decoder.decode(
            RemoteCodeEventEnvelope.self,
            from: Data(#"{"seq":7,"kind":"agent.run.started","payload":{"run_id":"run-1"},"ts":1.5}"#.utf8)
        )
        XCTAssertEqual(known.kind, .agentRunStarted)
        XCTAssertFalse(known.isUnknown)

        let unknown = try decoder.decode(
            RemoteCodeEventEnvelope.self,
            from: Data(#"{"seq":8,"kind":"future.kind","payload":{"value":1},"ts":2}"#.utf8)
        )
        XCTAssertEqual(unknown.rawKind, "future.kind")
        XCTAssertTrue(unknown.isUnknown)
    }

    func testEveryKnownEventKindHasAnIdentityBearingGoldenEnvelope() throws {
        XCTAssertEqual(RemoteCodeEventKind.allCases.count, 153)
        XCTAssertEqual(
            Set(RemoteCodeEventKind.allCases.map(\.rawValue)).count,
            RemoteCodeEventKind.allCases.count
        )
        for (offset, kind) in RemoteCodeEventKind.allCases.enumerated() {
            let original = RemoteCodeEventEnvelope(
                seq: Int64(offset + 1),
                kind: kind,
                payload: .object(["fixture": .string(kind.rawValue)]),
                ts: 123.5,
                hostID: "host-1",
                bootEpoch: 42,
                treatyVersion: TreatyVersion(major: 1, minor: 0)
            )
            let decoded = try decoder.decode(
                RemoteCodeEventEnvelope.self,
                from: encoder.encode(original)
            )
            XCTAssertEqual(decoded, original, "event fixture failed for \(kind.rawValue)")
        }
    }

    func testKnownMalformedEventFailsButFutureUnknownPayloadIsPreserved() throws {
        XCTAssertThrowsError(try decoder.decode(
            RemoteCodeEventEnvelope.self,
            from: Data(#"{"seq":7,"kind":"agent.run.started","payload":null,"ts":1}"#.utf8)
        ))
        let future = try decoder.decode(
            RemoteCodeEventEnvelope.self,
            from: Data(#"{"seq":8,"kind":"future.scalar","payload":7,"ts":2}"#.utf8)
        )
        XCTAssertTrue(future.isUnknown)
        XCTAssertEqual(future.payload, .number(7))
    }

    func testLegacyEventEnvelopeStillDecodesWithoutIdentity() throws {
        let legacy = try decoder.decode(
            RemoteCodeEventEnvelope.self,
            from: Data(#"{"seq":1,"kind":"agent.run.started","payload":{},"ts":1}"#.utf8)
        )
        XCTAssertNil(legacy.hostID)
        XCTAssertNil(legacy.bootEpoch)
        XCTAssertNil(legacy.treatyVersion)
    }

    func testEventsRecentGoldenEnvelopeIsStrictAndIdentityBound() throws {
        let data = Data(#"""
        {
          "last_seq":8,"truncated":false,"requires_baseline":false,
          "host_id":"host-1","boot_epoch":42,"treaty_version":{"major":1,"minor":0},
          "events":[{"seq":8,"kind":"agent.run.started","payload":{},"ts":2,
            "host_id":"host-1","boot_epoch":42,"treaty_version":{"major":1,"minor":0}}]
        }
        """#.utf8)
        let result = try decoder.decode(EventsRecent.Result.self, from: data)
        XCTAssertEqual(result.lastSeq, 8)
        XCTAssertEqual(result.hostID, "host-1")
        XCTAssertEqual(result.events.first?.kind, .agentRunStarted)

        let params = EventsRecent.Params(sinceSeq: 7, maxBytes: 65_536)
        let paramsObject = try JSONSerialization.jsonObject(with: encoder.encode(params)) as? [String: Any]
        XCTAssertEqual(paramsObject?["since_seq"] as? Int, 7)
        XCTAssertEqual(paramsObject?["max_bytes"] as? Int, 65_536)
    }

    func testEventsRecentRejectsPartialMismatchedAndMalformedKnownEvents() throws {
        XCTAssertThrowsError(try decoder.decode(
            EventsRecent.Result.self,
            from: Data(#"{"last_seq":1,"events":[],"truncated":false,"requires_baseline":false,"host_id":"host-1"}"#.utf8)
        ))
        XCTAssertThrowsError(try decoder.decode(
            EventsRecent.Result.self,
            from: Data(#"{"last_seq":1,"events":[{"seq":1,"kind":"agent.run.started","payload":{},"ts":1,"host_id":"host-2","boot_epoch":42,"treaty_version":{"major":1,"minor":0}}],"truncated":false,"requires_baseline":false,"host_id":"host-1","boot_epoch":42,"treaty_version":{"major":1,"minor":0}}"#.utf8)
        ))
        XCTAssertThrowsError(try decoder.decode(
            EventsRecent.Result.self,
            from: Data(#"{"last_seq":1,"events":[{"seq":1,"kind":"agent.run.started","payload":null,"ts":1}],"truncated":false,"requires_baseline":false}"#.utf8)
        ))
    }

    func testRemoteCodeErrorPreservesUnknownHostCode() throws {
        let value = RemoteCodeError(code: -39999, message: "future", data: nil)
        XCTAssertEqual(value.kind, .unknown(-39999))
    }

    func testRemoteCodeErrorMapsCurrentCommonAndBotCodes() {
        let expected: [Int: RemoteCodeError.Kind] = [
            -32700: .parseError,
            -32600: .invalidRequest,
            -32601: .methodNotFound,
            -32602: .invalidParams,
            -32603: .internalError,
            -32044: .botNotFound,
            -32081: .botControlPlaneOff,
            -32082: .botLimit,
            -32083: .reservedCapability,
            -32084: .crossTarget,
            -32085: .botHandleConflict,
            -32086: .pathContainment,
            -32087: .botBrowserPersistence,
            -32088: .dockerHomeClear,
            -32090: .botFileNotFound,
            -32091: .commandReceiptUnavailable,
            -32092: .legacyReceiptUnverifiable,
            -32093: .idempotencyRequestMismatch,
            -32094: .idempotencyOwnerMismatch,
            -32095: .commandOutcomeUnknown,
            -32096: .commandInProgress,
            -32097: .missingRequestID,
            -32098: .authenticatedHostMismatch,
        ]
        for (code, kind) in expected {
            XCTAssertEqual(
                RemoteCodeError(code: code, message: "fixture", data: nil).kind,
                kind,
                "error fixture failed for \(code)"
            )
        }
    }

    func testActivityItemWorkspaceColorRoundTripsAndMissingKeyDecodesNil() throws {
        let item = AgentActivityItem(
            id: "run:1", kind: .agent, state: .running, title: "t", workspaceName: "api",
            workspaceColor: "blue", occurredAt: Date(timeIntervalSince1970: 1_792_094_460)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["workspace_color"] as? String, "blue")

        let decoded = try AgentActivityPage.makeJSONDecoder().decode(AgentActivityItem.self, from: data)
        XCTAssertEqual(decoded.workspaceColor, "blue")
        XCTAssertEqual(decoded, item)

        var legacy = object
        legacy.removeValue(forKey: "workspace_color")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let old = try AgentActivityPage.makeJSONDecoder().decode(AgentActivityItem.self, from: legacyData)
        XCTAssertNil(old.workspaceColor, "an older host omits workspace_color; the item must still decode")
    }
}
