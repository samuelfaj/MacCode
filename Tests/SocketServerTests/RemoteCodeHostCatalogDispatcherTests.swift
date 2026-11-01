import XCTest
import CoreModel
import Persistence
import AgentRuntime
@testable import SocketServer

@MainActor
final class RemoteCodeHostCatalogDispatcherTests: XCTestCase {
    func test_unixHostMutationsReplayMismatchAndUnknownOutcome() async throws {
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let capability = String(repeating: "ab", count: 32)
        func request(
            name: String,
            operationID: String,
            extra: [String: JSONValue] = [:]
        ) -> JSONRPCRequest {
            var params: [String: JSONValue] = [
                "thread_id": .string(threadID),
                "run_id": .string(runID),
                BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
                "client_request_id": .string(operationID),
                "name": .string(name),
            ]
            for (key, value) in extra { params[key] = value }
            return JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: RemoteCodeHostCatalog.botCreateRPC,
                params: params
            )
        }

        let first = await dispatcher.dispatchUnixSocket(request(name: "Oliver", operationID: "operation-1"))
        XCTAssertNil(first.error)
        XCTAssertEqual(first.result?.objectValue?["name"]?.stringValue, "Oliver")
        XCTAssertEqual(router.createCount, 1)

        let replay = await dispatcher.dispatchUnixSocket(request(name: "Oliver", operationID: "operation-1"))
        XCTAssertNil(replay.error)
        XCTAssertEqual(replay.result?.objectValue?["id"]?.stringValue, first.result?.objectValue?["id"]?.stringValue)
        XCTAssertEqual(router.createCount, 1, "same operation_id must not create a second Bot")

        let mismatch = await dispatcher.dispatchUnixSocket(request(name: "Nora", operationID: "operation-1"))
        XCTAssertEqual(mismatch.error?.code, -32093)
        XCTAssertEqual(mismatch.error?.data?.objectValue?["reason"]?.stringValue, "idempotencyRequestMismatch")
        XCTAssertEqual(router.createCount, 1)

        router.markNextUnknown = true
        let lost = await dispatcher.dispatchUnixSocket(request(name: "Piper", operationID: "operation-2"))
        XCTAssertEqual(lost.error?.code, -32095)
        XCTAssertEqual(lost.error?.data?.objectValue?["requiresSnapshot"]?.boolValue, true)
        let retryLost = await dispatcher.dispatchUnixSocket(request(name: "Piper", operationID: "operation-2"))
        XCTAssertEqual(retryLost.error?.code, -32095)
        XCTAssertEqual(router.createCount, 2, "unknown outcomes must not be blindly retried as a new create")
    }

    private func hostCall(_ method: String, params: [String: JSONValue], operationID: String, router: HostCatalogReceiptRouter) -> JSONRPCRequest {
        JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: RemoteCodeHostCatalog.hostCallRPC, params: [
            "thread_id": .string(UUID().uuidString.lowercased()),
            "run_id": .string(router.fixedRunID),
            BotPeerDelegation.capabilityRPCParameterKey: .string(router.activeCapability),
            "client_request_id": .string(operationID),
            "method": .string(method),
            "params": .object(params),
        ])
    }

    func test_hostHelpDiscoversRealControlsWithoutMutatingAndRejectsUnknownTopics() async throws {
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        var params: [String: JSONValue] = [
            "thread_id": .string(UUID().uuidString),
            "run_id": .string(router.fixedRunID),
            BotPeerDelegation.capabilityRPCParameterKey: .string(router.activeCapability),
        ]
        let index = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(1), method: "host.help", params: params))
        XCTAssertNil(index.error)
        let topics = try XCTUnwrap(index.result?.objectValue?["topics"]?.arrayValue)
        XCTAssertEqual(Set(topics.compactMap { $0.objectValue?["id"]?.stringValue }), Set(TitioCapabilities.topics.map(\.id)))
        let methods = try XCTUnwrap(index.result?.objectValue?["methods"]?.arrayValue)
        XCTAssertTrue(methods.contains { $0.objectValue?["method"]?.stringValue == "scheduled_task.run" })
        XCTAssertTrue(methods.contains { $0.objectValue?["method"]?.stringValue == "bot.notice.act" })
        XCTAssertTrue(methods.contains {
            $0.objectValue?["method"]?.stringValue == "agent.thread.fork" && $0.objectValue?["mutation"]?.boolValue == true
        })
        XCTAssertFalse(methods.contains { $0.objectValue?["method"]?.stringValue?.hasPrefix("host.") == true })
        params["topic"] = .string("schedules")
        let schedules = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(2), method: "host.help", params: params))
        XCTAssertNil(schedules.error)
        XCTAssertTrue(schedules.result?.objectValue?["instructions"]?.stringValue?.contains("bot.routine.run") == true)
        let spec = try XCTUnwrap(schedules.result?.objectValue?["bot_schedule_spec_example"]?.stringValue)
        XCTAssertNotNil(BotScheduleSpec.decodeJSON(spec), "new Bot schedules get the real persisted format")
        params["topic"] = .string("invented")
        let invalid = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(3), method: "host.help", params: params))
        XCTAssertEqual(invalid.error?.code, -32602)
        XCTAssertEqual(router.authorizationMutations, [false, false, false])
        XCTAssertTrue(router.pairedBotCalls.isEmpty)
    }

    func test_hostCallRunsAnyUIMethodForTitioAsAFullAccessMutation() async throws {
        // WHY: Titio must be able to do anything the user can in RemoteCode,
        // e.g. rename a Bot, through the same paired-device mutation path.
        let router = HostCatalogReceiptRouter()
        router.callerIsTitio = true
        let dispatcher = JSONRPCDispatcher(router: router)
        let request = hostCall("bot.save", params: ["bot_id": .string(UUID().uuidString.lowercased()), "name": .string("Developer")], operationID: "rename-1", router: router)
        let response = await dispatcher.dispatchUnixSocket(request)
        XCTAssertNil(response.error)
        XCTAssertEqual(router.pairedBotCalls.map(\.method), ["bot.save"])
        XCTAssertEqual(router.pairedBotCalls.first?.params["name"]?.stringValue, "Developer")
        XCTAssertEqual(router.pairedBotCalls.first?.params["host_id"]?.stringValue, router.activeHostID, "host binding comes from the authenticated run")
        XCTAssertEqual(router.authorizationMutations, [true], "host.call always needs captured fullAccess")
        let replay = await dispatcher.dispatchUnixSocket(request)
        XCTAssertNil(replay.error)
        XCTAssertEqual(router.pairedBotCalls.count, 1, "the same operation_id must not run the method twice")
    }

    func test_hostCallBindsBotReadsToTheRunHost() async {
        let router = HostCatalogReceiptRouter()
        router.callerIsTitio = true
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatchUnixSocket(hostCall("bot.guest.state", params: ["bot_id": .string(UUID().uuidString.lowercased()), "host_id": .string("forged")], operationID: "read-guest-1", router: router))
        XCTAssertNil(response.error)
        XCTAssertEqual(router.pairedBotCalls.first?.params["host_id"]?.stringValue, router.activeHostID, "a caller-supplied host id is replaced")
        XCTAssertNil(router.pairedBotCalls.first?.params["client_request_id"], "reads get no receipt id")
        XCTAssertEqual(router.authorizationMutations, [false], "read-only inspection must work without Full Access")
    }

    func test_hostHelpSearchAndMethodRequirementsFollowTheAdmissionContract() async throws {
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        var params = hostCall("unused", params: [:], operationID: "unused", router: router).params ?? [:]
        params.removeValue(forKey: "method")
        params["query"] = .string("scheduled_task")
        let search = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(1), method: "host.help", params: params))
        let methods = try XCTUnwrap(search.result?.objectValue?["methods"]?.arrayValue)
        XCTAssertFalse(methods.isEmpty)
        XCTAssertTrue(methods.allSatisfy { $0.objectValue?["method"]?.stringValue?.hasPrefix("scheduled_task.") == true })
        params.removeValue(forKey: "query")
        params["method"] = .string("scheduled_task.save")
        let detail = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(2), method: "host.help", params: params))
        let requirements = try XCTUnwrap(detail.result?.objectValue?["validation_requirements"]?.arrayValue)
        XCTAssertTrue(requirements.contains { $0.stringValue?.contains("workspace_id, bot_id") == true })
        XCTAssertTrue(detail.result?.objectValue?["workflows"]?.arrayValue?.contains {
            $0.objectValue?["topic"] == .string("schedules")
        } == true)
    }

    func test_hostBatchReportsEachFailureAndReplaysSuccessfulActionsOnce() async throws {
        let router = HostCatalogReceiptRouter()
        router.callerIsTitio = true
        let dispatcher = JSONRPCDispatcher(router: router)
        let base = hostCall("bot.save", params: [:], operationID: "unused", router: router)
        var params = base.params ?? [:]
        params["calls"] = .array([
            .object(["method": .string("bot.save"), "operation_id": .string("batch-rename"),
                     "params": .object(["bot_id": .string(UUID().uuidString), "name": .string("Renamed")])]),
            .object(["method": .string("bot.save"), "operation_id": .string("batch-invalid"),
                     "params": .object(["bot_id": .string("not-a-uuid")])]),
            .object(["method": .string("bot.get"), "operation_id": .string("batch-read"),
                     "params": .object(["bot_id": .string(UUID().uuidString)])]),
        ])
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "host.batch", params: params)
        let first = await dispatcher.dispatchUnixSocket(request)
        XCTAssertNil(first.error)
        let results = try XCTUnwrap(first.result?.objectValue?["results"]?.arrayValue)
        XCTAssertEqual(results.count, 3)
        XCTAssertNotNil(results[0].objectValue?["result"])
        XCTAssertEqual(results[1].objectValue?["error"]?.objectValue?["code"], .number(-32602))
        XCTAssertNotNil(results[2].objectValue?["result"], "a failed independent action does not cancel the others")
        let replay = await dispatcher.dispatchUnixSocket(request)
        XCTAssertEqual(replay.result, first.result)
        XCTAssertEqual(router.pairedBotCalls.filter { $0.method == "bot.save" }.count, 1)
        XCTAssertEqual(router.pairedBotCalls.filter { $0.method == "bot.get" }.count, 2, "readbacks stay fresh")
        XCTAssertTrue(router.pairedBotCalls.allSatisfy { $0.params["host_id"] == .string(router.activeHostID) })
    }

    func test_hostBatchRejectsNestedCallsBeforeEffectsAndRequiresTitio() async throws {
        let router = HostCatalogReceiptRouter()
        router.callerIsTitio = true
        let dispatcher = JSONRPCDispatcher(router: router)
        var params = hostCall("bot.save", params: [:], operationID: "unused", router: router).params ?? [:]
        let valid: JSONValue = .object(["method": .string("bot.save"), "operation_id": .string("rename"),
                                       "params": .object(["bot_id": .string(UUID().uuidString)])])
        params["calls"] = .array([valid, .object(["method": .string("host.call"), "operation_id": .string("nested")])])
        let invalid = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(1), method: "host.batch", params: params))
        XCTAssertEqual(invalid.error?.code, -32602)
        XCTAssertTrue(router.pairedBotCalls.isEmpty)
        params["calls"] = .array([valid])
        router.callerIsTitio = false
        let denied = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(2), method: "host.batch", params: params))
        XCTAssertEqual(denied.error?.code, -32098)
        XCTAssertTrue(router.pairedBotCalls.isEmpty)
    }

    func test_supervisedTitioCanReadButCannotMutateThroughSingleOrBatchCalls() async throws {
        let router = HostCatalogReceiptRouter()
        router.callerIsTitio = true
        router.capturedFullAccess = false
        let dispatcher = JSONRPCDispatcher(router: router)
        let bot = ["bot_id": JSONValue.string(UUID().uuidString)]
        let read = await dispatcher.dispatchUnixSocket(hostCall("bot.get", params: bot, operationID: "inspect", router: router))
        XCTAssertNil(read.error)
        let mutation = await dispatcher.dispatchUnixSocket(hostCall("bot.save", params: bot, operationID: "edit", router: router))
        XCTAssertEqual(mutation.error?.code, -32048)
        var params = hostCall("unused", params: [:], operationID: "unused", router: router).params ?? [:]
        params["calls"] = .array([.object(["method": .string("bot.get"), "params": .object(bot), "operation_id": .string("inspect-batch")])])
        let batchRead = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(1), method: "host.batch", params: params))
        XCTAssertNil(batchRead.error)
        params["calls"] = .array([.object(["method": .string("bot.save"), "params": .object(bot), "operation_id": .string("edit-batch")])])
        let batchEdit = await dispatcher.dispatchUnixSocket(.init(jsonrpc: "2.0", id: .number(2), method: "host.batch", params: params))
        XCTAssertEqual(batchEdit.error?.code, -32048)
        XCTAssertEqual(router.pairedBotCalls.map(\.method), ["bot.get", "bot.get"])
    }

    func test_hostCallIsDeniedToEveryBotExceptTitio() async {
        let router = HostCatalogReceiptRouter()
        router.callerIsTitio = false
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatchUnixSocket(hostCall("bot.save", params: ["bot_id": .string("bot-1"), "name": .string("X")], operationID: "rename-2", router: router))
        XCTAssertEqual(response.error?.code, -32098)
        XCTAssertTrue(router.pairedBotCalls.isEmpty)
    }

    func test_hostCallCannotReenterManagedProviderMethods() async {
        let router = HostCatalogReceiptRouter()
        router.callerIsTitio = true
        let dispatcher = JSONRPCDispatcher(router: router)
        for method in [RemoteCodeHostCatalog.hostCallRPC, RemoteCodeHostCatalog.botCreateRPC, "bot.peer.ask", "rpc.batch"] {
            let response = await dispatcher.dispatchUnixSocket(hostCall(method, params: [:], operationID: "nested-\(method.count)", router: router))
            XCTAssertEqual(response.error?.code, -32602, method)
        }
        XCTAssertEqual(router.createCount, 0)
    }

    func test_hostBrowserScreenshotRequiresAuthenticatedActiveRun() async {
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "host.browser.screenshot",
            params: ["thread_id": .string(UUID().uuidString)]
        ))
        XCTAssertEqual(response.error?.code, -32047)
        XCTAssertEqual(router.screenshotCount, 0)
    }

    func test_hostBrowserScreenshotRoutesCallerAndReplaysReceipt() async throws {
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let surfaceID = UUID().uuidString.lowercased()
        let params: [String: JSONValue] = [
            "thread_id": .string(threadID),
            "run_id": .string(UUID().uuidString.lowercased()),
            BotPeerDelegation.capabilityRPCParameterKey: .string(router.activeCapability),
            "surface_id": .string(surfaceID),
            "reason": .string("Inspect browser"),
            "client_request_id": .string("screenshot-once"),
        ]
        func request() -> JSONRPCRequest {
            JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "host.browser.screenshot", params: params)
        }
        let first = await dispatcher.dispatchUnixSocket(request())
        XCTAssertNil(first.error)
        XCTAssertEqual(first.result?.objectValue?["captured"]?.boolValue, true)
        XCTAssertEqual(router.screenshotThread?.value.uuidString.lowercased(), threadID)
        XCTAssertEqual(router.screenshotSurface?.value.uuidString.lowercased(), surfaceID)
        XCTAssertEqual(router.screenshotReason, "Inspect browser")
        XCTAssertEqual(router.screenshotCount, 1)
        let replay = await dispatcher.dispatchUnixSocket(request())
        XCTAssertNil(replay.error)
        XCTAssertEqual(replay.result, first.result)
        XCTAssertEqual(router.screenshotCount, 1)
    }

    func test_hostBrowserScreenshotPreservesDefiniteMutationRejection() async {
        let router = HostCatalogReceiptRouter()
        router.screenshotError = DefiniteMutationRejection(JSONRPCError(code: -32047, message: "Preflight rejected"))
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "host.browser.screenshot",
            params: [
                "thread_id": .string(UUID().uuidString),
                "run_id": .string(UUID().uuidString),
                BotPeerDelegation.capabilityRPCParameterKey: .string(router.activeCapability),
                "client_request_id": .string("screenshot-rejected"),
            ]
        ))
        XCTAssertEqual(response.error?.code, -32047)
        XCTAssertNotEqual(response.error?.code, -32095)
        XCTAssertEqual(router.screenshotCount, 1)
    }

    func test_unixHostCallsRejectMissingCapability() async throws {
        let dispatcher = JSONRPCDispatcher(router: HostCatalogReceiptRouter())
        let response = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: RemoteCodeHostCatalog.botListRPC,
            params: [
                "thread_id": .string(UUID().uuidString),
                "run_id": .string(UUID().uuidString),
            ]
        ))
        XCTAssertEqual(response.error?.code, -32047)
    }

    func test_privateProviderNamespaceIsRejectedOutsideAuthenticatedUnixEntry() async {
        // WHY: host.* aliases must never become a second HTTP/local control
        // plane merely because the caller can spell their private method name.
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let capability = String(repeating: "ab", count: 32)
        let common: [String: JSONValue] = [
            "thread_id": .string(threadID),
            "run_id": .string(runID),
            BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
        ]
        let read = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: RemoteCodeHostCatalog.botListRPC,
            params: common
        )
        let local = await dispatcher.dispatchLocalIPC(read)
        let httpRead = await dispatcher.dispatchHTTP(read, mutationContext: nil)
        XCTAssertEqual(local.error?.code, -32601)
        XCTAssertEqual(httpRead.error?.code, -32601)

        var mutationParams = common
        mutationParams["name"] = .string("Forged HTTP Bot")
        mutationParams["client_request_id"] = .string("forged-http-op")
        let mutation = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: RemoteCodeHostCatalog.botCreateRPC,
            params: mutationParams
        )
        let response = await dispatcher.dispatchHTTP(
            mutation,
            mutationContext: MutationRequestContext(
                ownerFingerprint: "http-owner",
                hostId: "http-host",
                bootEpoch: 1
            )
        )
        XCTAssertEqual(response.error?.code, -32601)
        XCTAssertEqual(router.createCount, 0, "rejection must happen before receipt claim or domain mutation")
        XCTAssertTrue(router.authorizationMutations.isEmpty)
    }

    func test_privateProviderNamespaceCannotHideInsideUnixBatch() async {
        // WHY: authentication belongs to each named private call; a public
        // read-only batch must not smuggle a host call past the Unix seam.
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "rpc.batch",
            params: [
                "calls": .array([
                    .object([
                        "method": .string(RemoteCodeHostCatalog.botListRPC),
                        "params": .object([:]),
                    ]),
                ]),
            ]
        ))
        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertTrue(router.authorizationMutations.isEmpty)
    }

    func test_supervisedPeerMethodsAuthenticateAsBearerScopedNotFullAccessMutations() async {
        // WHY: peer consultation and its explicitly granted self-config tools
        // are supervised-run capabilities, not the cross-object host catalog.
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let capability = router.activeCapability
        func params(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
            var result: [String: JSONValue] = [
                "thread_id": .string(threadID),
                "run_id": .string(runID),
                BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
            ]
            for (key, value) in extra { result[key] = value }
            return result
        }

        _ = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "bot.peer.list", params: params()
        ))
        _ = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "bot.peer.ask",
            params: params([
                "client_request_id": .string("peer-ask-auth"),
                "handle": .string("qa"),
                "prompt": .string("Review this."),
                "reply_mode": .string("consult"),
            ])
        ))
        _ = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(3),
            method: "bot.peer.self_config",
            params: params([
                "client_request_id": .string("peer-self-config-auth"),
                "tool_name": .string("bot_get_settings"),
                "arguments": .object([:]),
            ])
        ))

        XCTAssertEqual(router.authorizationMutations, [false, false, false])
    }

    func test_peerMutationsUsePrivateDurableReceiptsWithoutRedispatch() async throws {
        // WHY: bot.peer.* is a supervised Unix capability, not a public HTTP
        // mutation. A lost response must be recoverable from the exact durable
        // terminal receipt without asking the Bot or applying self-config twice.
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let capability = router.activeCapability
        func params(_ requestID: String, extra: [String: JSONValue]) -> [String: JSONValue] {
            var values: [String: JSONValue] = [
                "thread_id": .string(threadID),
                "run_id": .string(runID),
                BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
                "client_request_id": .string(requestID),
            ]
            for (key, value) in extra { values[key] = value }
            return values
        }
        let askParams = params("peer-ask-1", extra: [
            "handle": .string("qa"),
            "prompt": .string("Review this."),
            "reply_mode": .string("consult"),
        ])

        let firstAsk = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "bot.peer.ask", params: askParams
        ))
        XCTAssertNil(firstAsk.error)
        XCTAssertEqual(router.peerAskCount, 1)
        let askReceipt = try XCTUnwrap(firstAsk.result?.objectValue?["command_receipt"]?.objectValue)
        XCTAssertEqual(askReceipt["client_request_id"]?.stringValue, "peer-ask-1")
        XCTAssertEqual(askReceipt["host_id"]?.stringValue, router.activeHostID)
        XCTAssertEqual(askReceipt["caller_thread_id"]?.stringValue, threadID)
        XCTAssertEqual(askReceipt["caller_run_id"]?.stringValue, runID)
        XCTAssertNotEqual(askReceipt["delegation_fingerprint"]?.stringValue, capability)
        XCTAssertEqual(firstAsk.result?.objectValue?["bot"]?.objectValue?["id"]?.stringValue,
                       "55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(firstAsk.result?.objectValue?["conversation_id"]?.stringValue,
                       "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(firstAsk.result?.objectValue?["thread_id"]?.stringValue,
                       "33333333-3333-3333-3333-333333333333")
        XCTAssertEqual(firstAsk.result?.objectValue?["run_id"]?.stringValue,
                       "44444444-4444-4444-4444-444444444444")

        let askStatus = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "bot.peer.receipt.status",
            params: params("peer-ask-1", extra: ["method": .string("bot.peer.ask")])
        ))
        XCTAssertNil(askStatus.error)
        XCTAssertEqual(askStatus.result?.objectValue?["status"]?.stringValue, "committed")
        XCTAssertEqual(
            askStatus.result?.objectValue?["result"]?.objectValue?["reply"]?.stringValue,
            "Reviewed once."
        )
        XCTAssertEqual(router.peerAskCount, 1, "status readback must not redispatch the consultation")

        let reloaded = JSONRPCDispatcher(router: router)
        let replayAsk = await reloaded.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(3), method: "bot.peer.ask", params: askParams
        ))
        XCTAssertEqual(replayAsk.result, firstAsk.result)
        XCTAssertEqual(router.peerAskCount, 1, "same logical id must replay the durable result after dispatcher recreation")

        let selfConfigParams = params("peer-config-1", extra: [
            "tool_name": .string("bot_set_settings"),
            "arguments": .object(["name": .string("Nova")]),
        ])
        let firstConfig = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(4), method: "bot.peer.self_config", params: selfConfigParams
        ))
        XCTAssertNil(firstConfig.error)
        XCTAssertEqual(router.peerSelfConfigCount, 1)
        let configStatus = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(5),
            method: "bot.receipt.status",
            params: params("peer-config-1", extra: ["method": .string("bot.peer.self_config")])
        ))
        XCTAssertEqual(configStatus.result?.objectValue?["status"]?.stringValue, "committed")
        XCTAssertEqual(
            configStatus.result?.objectValue?["result"]?.objectValue?["name"]?.stringValue,
            "Nova"
        )
        XCTAssertEqual(router.peerSelfConfigCount, 1)
        XCTAssertEqual(firstConfig.result?.objectValue?["id"]?.stringValue,
                       "55555555-5555-5555-5555-555555555555")

        var crossThreadStatusParams = params(
            "peer-ask-1",
            extra: ["method": .string("bot.peer.ask")]
        )
        crossThreadStatusParams["thread_id"] = .string(UUID().uuidString.lowercased())
        let crossThreadStatus = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(6),
            method: "bot.peer.receipt.status",
            params: crossThreadStatusParams
        ))
        XCTAssertEqual(crossThreadStatus.error?.code, -32094)
        XCTAssertEqual(router.peerAskCount, 1, "a cross-thread status probe must not expose or replay a result")

        let persistedReceiptText = try JSONEncoder().encode(firstAsk.result)
        XCTAssertFalse(
            String(decoding: persistedReceiptText, as: UTF8.self).contains(capability),
            "the raw bearer must never enter a persisted receipt result"
        )
    }

    func test_peerReceiptStatusNeverReplaysUnknownOrInProgressOperation() async {
        // WHY: a status poll is evidence, never permission to repeat an unknown
        // side effect. Only a committed receipt may return its cached result.
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        func params(_ requestID: String) -> [String: JSONValue] {
            [
                "thread_id": .string(threadID),
                "run_id": .string(runID),
                BotPeerDelegation.capabilityRPCParameterKey: .string(router.activeCapability),
                "client_request_id": .string(requestID),
                "method": .string("bot.peer.ask"),
            ]
        }

        router.seedReceipt(method: "bot.peer.ask", requestID: "in-progress", ownerParams: params("in-progress"), state: "claimed")
        router.seedReceipt(method: "bot.peer.ask", requestID: "unknown-request", ownerParams: params("unknown-request"), state: "unknown")

        let inProgress = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "bot.peer.receipt.status", params: params("in-progress")
        ))
        let unknown = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(2), method: "bot.peer.receipt.status", params: params("unknown-request")
        ))
        XCTAssertEqual(inProgress.result?.objectValue?["status"]?.stringValue, "inProgress")
        XCTAssertNil(inProgress.result?.objectValue?["result"])
        XCTAssertEqual(unknown.result?.objectValue?["status"]?.stringValue, "unknown")
        XCTAssertNil(unknown.result?.objectValue?["result"])
        XCTAssertEqual(router.peerAskCount, 0)
    }

    func test_privatePeerReceiptCatalogStaysOutsidePublicMutationManifest() {
        // WHY: durable receipts must not accidentally expose supervised peer
        // tools over the public HTTP mutation catalog.
        XCTAssertEqual(
            HostMutationContract.managedProviderMutationMethods,
            RemoteCodeHostCatalog.rpcMutationMethods.union(["bot.peer.ask", "bot.peer.self_config", "bot.peer.cancel"])
        )
        XCTAssertTrue(
            HostMutationContract.methods.isDisjoint(with: ["bot.peer.ask", "bot.peer.self_config", "bot.peer.cancel"])
        )
        XCTAssertEqual(
            JSONRPCDispatcher.managedPeerReceiptMethods,
            ["bot.peer.ask", "bot.peer.self_config", "bot.peer.cancel"]
        )
    }

    func test_peerContinuationRejectsMalformedOrWronglyTypedConsultationIDsBeforeDispatch() async {
        // WHY: consultation ids are opaque authority handles. A malformed or
        // non-string value must fail at the RPC boundary, before any provider
        // dispatch can be attempted.
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let common: [String: JSONValue] = [
            "thread_id": .string(UUID().uuidString.lowercased()),
            "run_id": .string(UUID().uuidString.lowercased()),
            BotPeerDelegation.capabilityRPCParameterKey: .string(String(repeating: "ab", count: 32)),
            "handle": .string("quinn"),
            "prompt": .string("continue the review"),
            "reply_mode": .string("consult"),
        ]

        for (index, malformed) in [JSONValue.string("not-a-uuid"), .bool(true), .number(1)].enumerated() {
            var params = common
            // A well-formed request id isolates the consultation-id defect.
            params["client_request_id"] = .string("malformed-\(index)")
            params[BotPeerDelegation.consultationIDParameterKey] = malformed
            let response = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(40),
                method: "bot.peer.ask",
                params: params
            ))
            XCTAssertEqual(response.error?.code, JSONRPCError.invalidParams.code)
            XCTAssertNil(response.result)
        }
        XCTAssertEqual(router.lastMethod, "", "malformed continuation must not reach peer dispatch")
    }

    func test_legacyUnixCLIReadsRemainOutsideManagedProviderAuthentication() async {
        // WHY: RC2CLI shares this socket and intentionally has no provider-run
        // bearer. The private host.* namespace must not capture its legacy API.
        let dispatcher = JSONRPCDispatcher(router: HostCatalogReceiptRouter())
        let workspaces = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "workspace.list",
            params: [:]
        ))
        XCTAssertNil(workspaces.error)

        let threads = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.thread.list",
            params: [:]
        ))
        XCTAssertNil(threads.error)
    }

    func test_namedHostReadsAndMutationsAreRouted() async throws {
        let router = HostCatalogReceiptRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let threadID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let capability = String(repeating: "ab", count: 32)
        func params(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
            var values: [String: JSONValue] = [
                "thread_id": .string(threadID),
                "run_id": .string(runID),
                BotPeerDelegation.capabilityRPCParameterKey: .string(capability),
            ]
            for (key, value) in extra { values[key] = value }
            return values
        }

        let listed = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: RemoteCodeHostCatalog.botListRPC, params: params()
        ))
        XCTAssertNil(listed.error)
        XCTAssertEqual(listed.result?.objectValue?["bots"]?.arrayValue?.isEmpty, true)

        let created = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: RemoteCodeHostCatalog.botCreateRPC,
            params: params([
                "name": .string("Oliver"),
                "client_request_id": .string("create-request-1"),
            ])
        ))
        let botID = try XCTUnwrap(created.result?.objectValue?["id"]?.stringValue)
        XCTAssertEqual(router.lastMethod, "create")

        let opened = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(3),
            method: RemoteCodeHostCatalog.botOpenRPC,
            params: params([
                "bot_id": .string(botID),
                "client_request_id": .string("open-request-1"),
            ])
        ))
        XCTAssertEqual(opened.result?.objectValue?["opened"]?.boolValue, true)

        let sent = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(31),
            method: RemoteCodeHostCatalog.botSendRPC,
            params: params([
                "bot_id": .string(botID),
                "text": .string("Use my exact provider"),
                "client_request_id": .string("send-request-1"),
            ])
        ))
        XCTAssertNil(sent.error)
        XCTAssertEqual(router.lastCallerThread?.value.uuidString.lowercased(), threadID)
        XCTAssertEqual(router.lastCallerRun?.value.uuidString.lowercased(), runID)

        let skill = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(4),
            method: RemoteCodeHostCatalog.botSkillCreateRPC,
            params: params([
                "bot_id": .string(botID),
                "skill_id": .string("qa"),
                "body": .string("skill-body"),
                "client_request_id": .string("skill-request-1"),
            ])
        ))
        XCTAssertEqual(skill.result?.objectValue?["body"]?.stringValue, "skill-body")
        XCTAssertEqual(
            skill.result?.objectValue?["digest"]?.stringValue,
            RemoteCodeHostCatalog.bodyDigest("skill-body")
        )

        let viewed = await dispatcher.dispatchUnixSocket(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(5),
            method: RemoteCodeHostCatalog.botSkillViewRPC,
            params: params([
                "bot_id": .string(botID),
                "skill_id": .string("qa"),
            ])
        ))
        XCTAssertEqual(viewed.result?.objectValue?["digest"]?.stringValue, RemoteCodeHostCatalog.bodyDigest("skill-body"))
    }
}

@MainActor
private final class HostCatalogReceiptRouter: FakeRouter, CommandReceiptStateRouting {
    private struct Receipt {
        var owner: String
        var hash: String
        var state: String
        var result: JSONValue?
    }

    var createCount = 0
    var lastMethod = ""
    var markNextUnknown = false
    var authorized = true
    var capturedFullAccess = true
    var authorizationMutations: [Bool] = []
    var lastCallerThread: AgentThreadID?
    var lastCallerRun: AgentRunID?
    let activeCapability = String(repeating: "ab", count: 32)
    let activeHostID = "host-peer-receipt-test"
    var peerAskCount = 0
    var peerSelfConfigCount = 0
    var screenshotCount = 0
    var screenshotThread: AgentThreadID?
    var screenshotSurface: SurfaceID?
    var screenshotReason: String?
    var screenshotError: Error?
    var callerIsTitio = false
    let fixedRunID = UUID().uuidString.lowercased()
    var pairedBotCalls: [(method: String, params: [String: JSONValue])] = []

    override func managedHostCallerIsTitio(threadID: AgentThreadID) throws -> Bool { callerIsTitio }

    /// The real host checks the activity belongs to the caller; this fake owns every receipt it issued.
    override func validateBotPeerReceipt(callerThread: AgentThreadID, result: JSONValue) throws {}

    override func dispatchPairedBotRemote(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        pairedBotCalls.append((method, params))
        return .object(["status": .string("completed")])
    }

    override func captureHostBrowserToChat(callerThread: AgentThreadID, surface: SurfaceID?, reason: String) throws -> JSONValue {
        screenshotCount += 1
        screenshotThread = callerThread
        screenshotSurface = surface
        screenshotReason = reason
        if let screenshotError { throw screenshotError }
        return .object(["captured": .bool(true)])
    }
    private var receipts: [String: Receipt] = [:]
    private var bots: [String: String] = [:]
    private var skills: [String: String] = [:]

    override func authenticateManagedHostCall(
        threadID: AgentThreadID,
        runID: AgentRunID,
        delegationCapability: String?,
        mutation: Bool,
        method: String
    ) throws {
        authorizationMutations.append(mutation)
        guard authorized else {
            throw JSONRPCError(code: -32047, message: "Host catalog requires an authenticated active run.")
        }
        if mutation && !capturedFullAccess {
            throw JSONRPCError(code: -32048, message: "Host catalog mutations require the captured fullAccess permission.")
        }
        guard let capability = delegationCapability, !capability.isEmpty else {
            throw JSONRPCError(code: -32047, message: "Host catalog requires an authenticated active run.")
        }
        _ = method
        _ = threadID
        _ = runID
    }

    override func activeAgentDelegation(
        thread: AgentThreadID,
        run: AgentRunID
    ) throws -> AgentActiveDelegationSnapshot? {
        AgentActiveDelegationSnapshot(
            threadId: thread,
            runId: run,
            hostId: activeHostID,
            capability: activeCapability,
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    override func askBotPeer(
        callerThread: AgentThreadID,
        callerRun: AgentRunID,
        handle: String,
        prompt: String,
        replyMode: BotPeerDelegation.ReplyMode,
        consultationID: UUID?,
        delegationCapability: String?
    ) async throws -> JSONValue {
        peerAskCount += 1
        return .object([
            "lifecycle_receipt_id": .string("11111111-1111-1111-1111-111111111111"),
            "conversation_id": .string("22222222-2222-2222-2222-222222222222"),
            "thread_id": .string("33333333-3333-3333-3333-333333333333"),
            "run_id": .string("44444444-4444-4444-4444-444444444444"),
            "bot": .object([
                "id": .string("55555555-5555-5555-5555-555555555555"),
                "handle": .string(handle),
            ]),
            "reply": .string("Reviewed once."),
            "reply_mode": .string(replyMode.rawValue),
        ])
    }

    override func invokeDelegatedBotSelfConfig(
        callerThread: AgentThreadID,
        callerRun: AgentRunID,
        toolName: String,
        arguments: [String: JSONValue],
        delegationCapability: String?
    ) throws -> JSONValue {
        peerSelfConfigCount += 1
        return .object([
            "id": .string("55555555-5555-5555-5555-555555555555"),
            "name": arguments["name"] ?? .string("Nova"),
        ])
    }

    func seedReceipt(
        method: String,
        requestID: String,
        ownerParams: [String: JSONValue],
        state: String
    ) {
        let threadID = ownerParams["thread_id"]?.stringValue ?? ""
        let runID = ownerParams["run_id"]?.stringValue ?? ""
        let capability = ownerParams[BotPeerDelegation.capabilityRPCParameterKey]?.stringValue ?? ""
        let owner = JSONRPCDispatcher.managedPeerOwnerFingerprint(
            hostID: activeHostID,
            threadID: threadID,
            runID: runID,
            capability: capability
        )
        receipts["\(method):\(requestID)"] = Receipt(
            owner: owner,
            hash: "unused",
            state: state,
            result: nil
        )
    }

    override func createHostBot(
        name: String,
        title: String,
        description: String,
        handle: String?,
        soul: String,
        callerRun: AgentRunID
    ) throws -> JSONValue {
        createCount += 1
        lastMethod = "create"
        if markNextUnknown {
            markNextUnknown = false
            throw JSONRPCError.internalError
        }
        let id = UUID().uuidString.lowercased()
        bots[id] = name
        return .object(["id": .string(id), "name": .string(name), "handle": .string(handle ?? name.lowercased())])
    }

    override func listHostBots() throws -> JSONValue {
        lastMethod = "list"
        return .object(["bots": .array(bots.map { id, name in
            .object(["id": .string(id), "name": .string(name)])
        })])
    }

    override func openHostBot(botID: BotID) throws -> JSONValue {
        lastMethod = "open"
        return .object(["bot_id": .string(botID.value.uuidString.lowercased()), "opened": .bool(true)])
    }

    override func sendHostBot(
        botID: BotID,
        text: String,
        conversationID: BotConversationID?,
        callerThread: AgentThreadID,
        callerRun: AgentRunID
    ) async throws -> JSONValue {
        lastMethod = "send"
        lastCallerThread = callerThread
        lastCallerRun = callerRun
        return .object(["enqueued": .bool(true), "bot_id": .string(botID.value.uuidString.lowercased())])
    }

    override func createHostBotThread(botID: BotID, title: String) throws -> JSONValue {
        lastMethod = "thread"
        return .object([
            "bot_id": .string(botID.value.uuidString.lowercased()),
            "conversation_id": .string(UUID().uuidString.lowercased()),
            "title": .string(title),
        ])
    }

    override func createHostBotSkill(
        botID: BotID,
        skillID: String,
        body: String?,
        callerRun: AgentRunID,
        callerThread: AgentThreadID
    ) throws -> JSONValue {
        lastMethod = "skill-create"
        let written = body ?? "default"
        skills["\(botID.value.uuidString.lowercased()):\(skillID)"] = written
        return .object([
            "skill_id": .string(skillID),
            "body": .string(written),
            "digest": .string(RemoteCodeHostCatalog.bodyDigest(written)),
        ])
    }

    override func viewHostBotSkill(
        botID: BotID,
        skillID: String,
        callerRun: AgentRunID,
        callerThread: AgentThreadID
    ) throws -> JSONValue {
        lastMethod = "skill-view"
        let written = skills["\(botID.value.uuidString.lowercased()):\(skillID)"] ?? ""
        return .object([
            "skill_id": .string(skillID),
            "body": .string(written),
            "digest": .string(RemoteCodeHostCatalog.bodyDigest(written)),
        ])
    }

    func claimCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult {
        let key = "\(method):\(clientRequestId)"
        if let receipt = receipts[key] {
            guard receipt.owner == ownerFingerprint else { return .ownerMismatch }
            guard receipt.hash == paramsHash else { return .requestMismatch }
            switch receipt.state {
            case "claimed": return .inProgress
            case "committed":
                let data = try JSONEncoder().encode(receipt.result ?? .null)
                return .committed(resultJSON: String(decoding: data, as: UTF8.self))
            default:
                return .unknown
            }
        }
        receipts[key] = Receipt(owner: ownerFingerprint, hash: paramsHash, state: "claimed", result: nil)
        return .claimed
    }

    func commitCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) throws {
        let key = "\(method):\(clientRequestId)"
        receipts[key] = Receipt(owner: ownerFingerprint, hash: paramsHash, state: "committed", result: result)
    }

    func finalizeCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent],
        minimumEventSequence: Int64
    ) throws -> [EventBus.Event] {
        try commitCommandReceipt(
            method: method,
            clientRequestId: clientRequestId,
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            result: result
        )
        return events.enumerated().map { ordinal, event in
            EventBus.Event(
                seq: minimumEventSequence + Int64(ordinal) + 1,
                kind: event.kind.rawValue,
                payload: event.payload,
                ts: event.createdAt.timeIntervalSince1970
            )
        }
    }

    func markCommandReceiptUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        let key = "\(method):\(clientRequestId)"
        receipts[key] = Receipt(owner: ownerFingerprint, hash: paramsHash, state: "unknown", result: nil)
    }

    func releaseCommandReceiptClaim(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        receipts["\(method):\(clientRequestId)"] = nil
    }

    func commandReceiptStatus(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult {
        let key = "\(method):\(clientRequestId)"
        guard let receipt = receipts[key] else { return .absent }
        guard receipt.owner == ownerFingerprint else { return .ownerMismatch }
        switch receipt.state {
        case "claimed": return .inProgress
        case "committed": return .committed
        default: return .unknown
        }
    }

    override func commandReceipt(method: String, clientRequestId: String) -> JSONValue? {
        receipts["\(method):\(clientRequestId)"]?.result
    }
}
