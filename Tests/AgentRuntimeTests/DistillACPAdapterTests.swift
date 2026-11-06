import Foundation
import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime

private final class LockedAutoRoutingEnabled: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func set(_ value: Bool) { lock.withLock { self.value = value } }
    func get() -> Bool { lock.withLock { value } }
}

final class DistillACPAdapterTests: ProviderProcessTestCase {
    func test_emptyMainModelIsRejectedBeforeACPStarts_becauseDistillMustNotUseAccountDefault() async throws {
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/distill-agent")
        do {
            _ = try await adapter.startSession(
                AgentRunRequest(
                    threadId: AgentThreadID(),
                    provider: .distill,
                    model: "  ",
                    cwd: "/tmp",
                    prompt: "Do work"
                ),
                onEvent: { _ in }
            )
            XCTFail("An empty Main model must not fall back to the account default")
        } catch let error as AgentProviderAdapterError {
            guard case .unsupported(let message) = error else {
                return XCTFail("expected an explicit model-selection refusal, got \(error)")
            }
            XCTAssertEqual(message, "Select an explicit Distill Main model before running.")
        }
    }

    func test_discoverySkipsReasoningExtensionWhenOlderPeerOmitsCapability() async throws {
        // WHY: model discovery must preserve a valid catalog from older Distill ACP peers that do not implement the optional Reasoning selector.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-acp-old-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let modelsURL = root.appendingPathComponent("models.json")
        try #"{"availableModels":[{"modelId":"live-distill-model","name":"Live Distill Model"}],"currentModelId":"live-distill-model"}"#
            .write(to: modelsURL, atomically: true, encoding: .utf8)
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        models = pathlib.Path(\(String(reflecting: modelsURL.path)))
        def record(value):
            with requests.open("a") as output:
                output.write(json.dumps(value) + "\\n")
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            record({"method":method})
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True,"sessionCapabilities":{"resume":True},"promptCapabilities":{}}}})
            elif method == "session/new":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"sessionId":"old-distill-session","models":json.loads(models.read_text())}})
            elif method == "_x.ai/session/worker_model/set":
                send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32601,"message":"method not found"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        let adapter = DistillACPAdapter(
            binaryNameOverride: harnessURL.path,
            discoveryCwd: root.path
        )
        let result = await adapter.discoveryResult()

        XCTAssertFalse(result.isFallback, "an old peer's live model catalog must survive optional-extension absence")
        XCTAssertEqual(result.models.map(\.id), ["live-distill-model"])
        let otherCwd = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCwd, withIntermediateDirectories: true)
        let workspaceAdapter = DistillACPAdapter(binaryNameOverride: harnessURL.path, discoveryCwd: otherCwd.path)
        let workspaceBefore = await workspaceAdapter.discoveryResult()
        XCTAssertEqual(workspaceBefore.models.map(\.id), result.models.map(\.id))
        // Account/routing state changes without changing the CLI executable or cache scope.
        try Self.autoCatalog.write(to: modelsURL, atomically: true, encoding: .utf8)
        let cached = await adapter.discoveryResult()
        XCTAssertEqual(cached.models.map(\.id), ["live-distill-model"])
        let refreshed = await adapter.discoveryResult(forceRefresh: true)
        XCTAssertFalse(refreshed.isFallback)
        XCTAssertEqual(refreshed.models.map(\.id), ["auto", "chatgpt/fixture-main"])
        let shared = await DistillACPAdapter(binaryNameOverride: harnessURL.path, discoveryCwd: root.path).discoveryResult()
        XCTAssertEqual(shared.models.map(\.id), refreshed.models.map(\.id))
        let workspaceAfter = await workspaceAdapter.discoveryResult()
        XCTAssertEqual(workspaceAfter.models.map(\.id), refreshed.models.map(\.id),
                       "the picker in another working directory must discard the same account's old catalog")
        let methods = try String(contentsOf: requestsURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
            .compactMap { $0["method"] }
        XCTAssertFalse(methods.contains("_x.ai/session/worker_model/set"),
                       "discovery must not call an extension the peer did not advertise")
        XCTAssertEqual(methods.filter { $0 == "session/new" }.count, 4,
                       "forced refresh must replace the warm cache for subsequent adapters")
    }

    func test_discoveryKeepsTheInitializeCatalogWhenTheModelLessSessionIsRefused_becauseThePickerMustKeepAutoAndAccountModels() async throws {
        // WHY: a Distill with no routable account answers the model-less
        // session/new with auth_required. Discovery only needs that session for
        // mode ids; throwing away the catalog initialize already returned would
        // replace "auto" and every subscription model in the picker with the
        // static built-in list.
        let root = try makeTempRoot("distill-acp-discovery-auth-required")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requests) = try writeDiscoveryHarness(
            root: root,
            initializeReply: #"{"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True,"promptCapabilities":{"embeddedContext":True},"_meta":{"x.ai/capabilities":{"sessionWorkerModel":True}}},"_meta":{"modelState":json.loads(catalog)}}}"#
        )

        let result = await DistillACPAdapter(binaryNameOverride: harness.path, discoveryCwd: root.path).discoveryResult()

        XCTAssertEqual(try recordedRequests(requests).compactMap { $0["method"] as? String }, ["initialize", "session/new"],
                       "the refused session/new is the path under test")
        XCTAssertFalse(result.isFallback, "a live catalog from initialize is not the static fallback")
        XCTAssertEqual(result.models.map(\.id), ["auto", "chatgpt/fixture-main"])
        XCTAssertEqual(result.models.last?.accountProvider, "chatgpt",
                       "the picker groups subscription models by this account metadata")
        XCTAssertEqual(result.models.last?.supportedReasoningEfforts, [.low, .high])
        XCTAssertTrue(result.capabilities.supportsDistillReasoningModelEffort, "capabilities come from initialize")
        XCTAssertEqual(result.capabilities.supportedAttachmentKinds, [.file], "capabilities come from initialize")
        // No session, no advertised modes: same as a session that omits them.
        XCTAssertEqual(result.interactionModes, [.default, .plan])
        XCTAssertEqual(result.permissionModes, DistillACPAdapter.defaultPermissionModes)
    }

    func test_discoveryStillFallsBackWhenInitializeFails_becauseThereIsNoLiveCatalogToKeep() async throws {
        // WHY: the session/new failure is tolerated only because initialize
        // already produced a catalog; without one the picker must say it is
        // showing the built-in list.
        let root = try makeTempRoot("distill-acp-discovery-init-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeDiscoveryHarness(
            root: root,
            initializeReply: #"{"error":{"code":-32603,"message":"Internal error"}}"#
        )

        let result = await DistillACPAdapter(binaryNameOverride: harness.path, discoveryCwd: root.path).discoveryResult()

        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.models, DistillACPAdapter.fallbackModels)
        XCTAssertTrue(result.models.contains { $0.id == "auto" }, "Auto routing must stay selectable on the built-in list")
        XCTAssertEqual(result.capabilities, AgentProviderCapabilities(supportsDistillMainEffortAuto: true))
    }

    func test_fallbackDiscoveryIsNotCached_soTheNextOpenRetriesLive() async throws {
        // WHY: at app launch many Distill processes start at once and one
        // initialize can time out; caching that built-in list hid the live
        // catalog (and every account-routed model) for the whole TTL.
        let root = try makeTempRoot("distill-acp-discovery-fallback-nocache")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requests) = try writeDiscoveryHarness(
            root: root,
            initializeReply: #"{"error":{"code":-32603,"message":"Internal error"}}"#
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path, discoveryCwd: root.path)
        _ = await adapter.discoveryResult()
        _ = await adapter.discoveryResult()
        let log = (try? String(contentsOf: requests, encoding: .utf8)) ?? ""
        XCTAssertEqual(log.components(separatedBy: "\"initialize\"").count - 1, 2, log)
    }

    /// A peer whose model-less session/new is refused with ACP `auth_required`.
    /// `initializeReply` is a Python dict literal merged into the JSON-RPC reply.
    private func writeDiscoveryHarness(root: URL, initializeReply: String) throws -> (harness: URL, requests: URL) {
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        catalog = \(String(reflecting: Self.autoCatalog))
        def send(message, reply): print(json.dumps({"jsonrpc":"2.0", "id":message["id"], **reply}), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            with requests.open("a") as output: output.write(json.dumps({"method":method}) + "\\n")
            if method == "initialize":
                send(message, \(initializeReply))
            elif method == "session/new":
                send(message, {"error":{"code":-32000,"message":"Authentication required"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        return (harnessURL, requestsURL)
    }

    private func writeWorkerHarness(
        root: URL,
        initializeCapabilities: String,
        workerResult: String,
        sessionModels: String = #"{"currentModelId":"main"}"#,
        setModelResult: String? = nil,
        setModelDelay: TimeInterval = 0,
        sessionOpenJSON: String? = nil,
        ultracodeReplyJSON: String = #"{"jsonrpc":"2.0","id":message["id"],"result":{"enabled":params.get("enabled")}}"#,
        executionModeReplyJSON: String = #"{"jsonrpc":"2.0","id":message["id"],"result":{"mode":params.get("mode")}}"#
    ) throws -> (harness: URL, requests: URL) {
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys, time
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            with requests.open("a") as output: output.write(json.dumps({"method":method,"params":params}) + "\\n")
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"protocolVersion":1,"agentCapabilities":\(initializeCapabilities)}})
            elif method in ("session/new", "session/load"):
                result = {"sessionId":"worker-session","models":\(sessionModels)}
                extra = \(String(reflecting: sessionOpenJSON ?? ""))
                if extra: result.update(json.loads(extra))
                send({"jsonrpc":"2.0", "id":message["id"], "result":result})
            elif method == "session/set_model":
                time.sleep(\(setModelDelay))
                fixed = \(String(reflecting: setModelResult ?? ""))
                result = json.loads(fixed) if fixed else {"_meta":{"model":params.get("modelId"),"contextWindow":1000}}
                if not fixed and params.get("modelId") == "auto":
                    meta = params.get("_meta", {})
                    active = "fixture-high" if meta.get("reasoningEffort") == "high" else "fixture-main"
                    result["_meta"].update({"model":{"Ok":active},"canonicalModelId":"auto","reasoningEffort":meta.get("reasoningEffort","high"),"reasoningEffortAuto":meta.get("reasoningEffortAuto",False)})
                send({"jsonrpc":"2.0", "id":message["id"], "result":result})
            elif method == "_x.ai/session/worker_model/set":
                send({"jsonrpc":"2.0", "id":message["id"], "result":\(workerResult)})
            elif method == "_x.ai/session/ultracode/set":
                send(\(ultracodeReplyJSON))
            elif method == "_x.ai/session/execution_mode/set":
                send(\(executionModeReplyJSON))
            elif method in ("session/set_mode", "session/set_config_option"):
                send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
            elif method == "session/prompt":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"stopReason":"end_turn"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        return (harnessURL, requestsURL)
    }

    private func recordedRequests(_ url: URL) throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return try text.split(whereSeparator: \.isNewline)
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func makeTempRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let autoCatalog = #"{"currentModelId":"chatgpt/fixture-main","availableModels":[{"modelId":"auto","name":"Auto"},{"modelId":"chatgpt/fixture-main","name":"Fixture","_meta":{"accountProvider":"chatgpt","reasoningEfforts":["low","high"]}}]}"#

    func test_autoNewAndColdLoadKeepLogicalMainAndConcreteEffortWithoutManualWorkerReapplication() async throws {
        let root = try makeTempRoot("distill-acp-auto-open")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(root: root,
            initializeCapabilities: #"{"_meta":{"x.ai/capabilities":{"sessionWorkerModel":True}}}"#, workerResult: "{}", sessionModels: Self.autoCatalog)
        let client = try DistillACPClient(binary: harness.path, cwd: root.path)
        defer { client.stop() }
        _ = try await client.initialize()
        let opened = try await client.newSession(cwd: root.path, modelId: "auto",
            mainEffortSelection: .fixed(.low), reasoningModel: "stale-worker")
        XCTAssertEqual(opened.appliedMainModelId, "auto")
        XCTAssertEqual(opened.currentModelId, "fixture-main")
        XCTAssertEqual(opened.appliedMainEffortSelection, .fixed(.low))
        let loaded = try await client.loadSession(sessionId: opened.sessionId, cwd: root.path, modelId: "auto",
            mainEffortSelection: .fixed(.low), reasoningModel: nil)
        XCTAssertEqual(loaded.appliedMainModelId, "auto")
        XCTAssertEqual(loaded.currentModelId, "fixture-main")
        let implicitEffort = try await client.loadSession(sessionId: opened.sessionId, cwd: root.path,
            modelId: "auto", reasoningModel: "stale-worker")
        XCTAssertEqual(implicitEffort.appliedMainModelId, "auto")
        XCTAssertEqual(implicitEffort.currentModelId, "chatgpt/fixture-main")
        let requests = try recordedRequests(requestsURL)
        XCTAssertFalse(requests.contains { $0["method"] as? String == DistillACPClient.workerModelSetMethod })
        let bindings = requests.filter { $0["method"] as? String == "session/set_model" }
        XCTAssertEqual(bindings.count, 2)
        XCTAssertTrue(bindings.allSatisfy { ($0["params"] as? [String: Any])?["modelId"] as? String == "auto" })
    }

    func test_slowAutoModelBindingConfirmsSelectionBeforeSendingPromptOnce() async throws {
        let root = try makeTempRoot("distill-acp-slow-model-binding")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(root: root,
            initializeCapabilities: "{}", workerResult: "{}", sessionModels: Self.autoCatalog,
            setModelDelay: 16)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        adapter.autoRoutingPreflight = { _ in [] }
        let events = DistillACPAdapterEventBox()
        let request = AgentRunRequest(threadId: AgentThreadID(), provider: .distill, model: "auto",
            cwd: root.path, prompt: "Run once", distillMainEffortSelection: .automatic)
        _ = try await adapter.startSession(request) { events.append($0) }
        let finished = try await events.waitForFinish()
        XCTAssertEqual(finished.status, .completed)
        let requests = try recordedRequests(requestsURL)
        let bindings = requests.indices.filter { requests[$0]["method"] as? String == "session/set_model" }
        let prompts = requests.indices.filter { requests[$0]["method"] as? String == "session/prompt" }
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertLessThan(try XCTUnwrap(bindings.first), try XCTUnwrap(prompts.first))
    }

    func test_autoTurnRechecksAdmissionBeforePhysicalPromptAfterHandshake() async throws {
        let root = try makeTempRoot("distill-acp-auto-admission-handshake")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(root: root,
            initializeCapabilities: #"{"_meta":{"x.ai/capabilities":{"sessionWorkerModel":True}}}"#,
            workerResult: "{}", sessionModels: Self.autoCatalog)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let enabled = LockedAutoRoutingEnabled()
        adapter.autoRoutingPreflight = { _ in
            guard enabled.get() else { throw DistillAutoRoutingError.disabled }
            return []
        }
        adapter.beforePhysicalPromptWriteForTesting = { enabled.set(false) }
        let request = AgentRunRequest(threadId: AgentThreadID(), provider: .distill, model: "auto", cwd: root.path, prompt: "Run")
        do {
            _ = try await adapter.startSession(request) { _ in }
            XCTFail("Auto routing disabled during handshake must prevent physical prompt")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Auto routing is off"), error.localizedDescription)
        }
        let requests = try recordedRequests(requestsURL)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/new" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/prompt" }.count, 0)
    }

    func test_cachedAutoSessionRechecksAdmissionBetweenTurns() async throws {
        let root = try makeTempRoot("distill-acp-auto-cached-admission")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(root: root,
            initializeCapabilities: "{}", workerResult: "{}", sessionModels: Self.autoCatalog)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let enabled = LockedAutoRoutingEnabled()
        adapter.autoRoutingPreflight = { _ in
            guard enabled.get() else { throw DistillAutoRoutingError.disabled }
            return []
        }
        let thread = AgentThreadID()
        let request = AgentRunRequest(threadId: thread, provider: .distill, model: "auto", cwd: root.path, prompt: "Run")
        let first = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(request) { first.append($0) }
        let finished = try await first.waitForFinish()
        enabled.set(false)
        do {
            _ = try await adapter.sendTurn(AgentRunRequest(threadId: thread, provider: .distill, model: "auto", cwd: root.path, prompt: "Again", providerThreadId: finished.providerThreadId)) { _ in }
            XCTFail("A cached Auto session must recheck admission before each turn")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Auto routing is off"), error.localizedDescription)
        }
        let requests = try recordedRequests(requestsURL)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/new" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/prompt" }.count, 1)
    }

    func test_autoRepeatedTurnsDoNotRebindConcreteMainOrStaleWorker_andChangedEffortUsesConcreteCatalog() async throws {
        let root = try makeTempRoot("distill-acp-auto-turns")
        defer { try? FileManager.default.removeItem(at: root) }
        // The selected route changes from a high-only model to a low-only model.
        let changingCatalog = #"{"currentModelId":"chatgpt/fixture-high","availableModels":[{"modelId":"auto","name":"Auto"},{"modelId":"chatgpt/fixture-high","name":"High route","_meta":{"accountProvider":"chatgpt","reasoningEfforts":["high"]}},{"modelId":"chatgpt/fixture-main","name":"Low route","_meta":{"accountProvider":"chatgpt","reasoningEfforts":["low"]}}]}"#
        let (harness, requestsURL) = try writeWorkerHarness(root: root,
            initializeCapabilities: #"{"_meta":{"x.ai/capabilities":{"sessionWorkerModel":True}}}"#, workerResult: "{}", sessionModels: changingCatalog)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        adapter.autoRoutingPreflight = { _ in [] }
        defer { adapter.stopAll() }
        let thread = AgentThreadID()
        func request(_ effort: AgentReasoningEffort, worker: String?) -> AgentRunRequest {
            AgentRunRequest(threadId: thread, provider: .distill, model: "auto", cwd: root.path,
                prompt: "Turn", reasoningModel: worker, distillMainEffortSelection: .fixed(effort))
        }
        let first = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(request(.high, worker: "stale-worker")) { first.append($0) }
        _ = try await first.waitForFinish()
        XCTAssertEqual(first.acceptedSessionModels.last?.model, "fixture-high")
        let second = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(request(.high, worker: nil)) { second.append($0) }
        _ = try await second.waitForFinish()
        let third = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(request(.low, worker: "another-stale-worker")) { third.append($0) }
        _ = try await third.waitForFinish()
        let requests = try recordedRequests(requestsURL)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/new" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/prompt" }.count, 3)
        XCTAssertFalse(requests.contains { $0["method"] as? String == DistillACPClient.workerModelSetMethod })
        let bindings = requests.filter { $0["method"] as? String == "session/set_model" }
        XCTAssertEqual(bindings.count, 2, "Only opening and the changed effort bind Main")
        XCTAssertTrue(bindings.allSatisfy { ($0["params"] as? [String: Any])?["modelId"] as? String == "auto" })
        XCTAssertEqual(((bindings.last?["params"] as? [String: Any])?["_meta"] as? [String: Any])?["reasoningEffort"] as? String, "low")
        XCTAssertEqual(third.acceptedSessionModels.last?.model, "fixture-main")
        XCTAssertFalse(DistillACPAdapter.isCrossModelFamilySwitch(from: "claude/actual", to: "auto"))
    }

    func test_initializeParsesSessionWorkerModelCapability() async throws {
        // WHY: the Worker selector and /fork, /side must only be offered when the harness advertises them.
        for advertised in [true, false] {
            let root = try makeTempRoot("distill-acp-worker-cap")
            defer { try? FileManager.default.removeItem(at: root) }
            let flag = advertised ? "True" : "False"
            let (harness, _) = try writeWorkerHarness(
                root: root,
                initializeCapabilities: "{\"_meta\":{\"x.ai/capabilities\":{\"sessionWorkerModel\":\(flag),\"sessionForkDurable\":\(flag),\"sessionReasoningModel\":True}}}",
                workerResult: "{}"
            )
            let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
            defer { client.stop() }
            let initialized = try await client.initialize()
            XCTAssertEqual(initialized.sessionWorkerModel, advertised)
            XCTAssertEqual(initialized.sessionForkDurable, advertised)
        }
    }

    func test_workerSetSendsWireParamsAndValidatesResponse() async throws {
        // WHY: the app must never claim a Worker model the harness did not confirm.
        let root = try makeTempRoot("distill-acp-worker-wire")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{\"_meta\":{\"x.ai/capabilities\":{\"sessionWorkerModel\":True}}}",
            workerResult: "{\"modelId\":params.get(\"modelId\") or None,\"effort\":params.get(\"effort\") or \"auto\",\"source\":\"session\"}"
        )
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        let fixed = try await client.setReasoningModel(sessionId: "s", modelId: "grok-4.5", effortSelection: .fixed(.high))
        XCTAssertEqual(fixed.modelId, "grok-4.5")
        XCTAssertEqual(fixed.effort, .high)
        XCTAssertFalse(fixed.isAutomatic)
        let auto = try await client.setReasoningModel(sessionId: "s", modelId: "grok-4.5", effortSelection: .automatic)
        XCTAssertTrue(auto.isAutomatic)
        let off = try await client.setReasoningModel(sessionId: "s", modelId: nil)
        XCTAssertNil(off.modelId)
        let params = try recordedRequests(requestsURL)
            .filter { $0["method"] as? String == DistillACPClient.workerModelSetMethod }
            .compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(params.map { $0["modelId"] as? String }, ["grok-4.5", "grok-4.5", ""])
        XCTAssertEqual(params[0]["effort"] as? String, "high")
        XCTAssertEqual(params[1]["effort"] as? String, "auto")
        XCTAssertTrue(params[2]["effort"] is NSNull, "Off inherits effort from the Distill config")
    }

    func test_workerSetRejectsMismatchedResponse() async throws {
        let root = try makeTempRoot("distill-acp-worker-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{\"_meta\":{\"x.ai/capabilities\":{\"sessionWorkerModel\":True}}}",
            workerResult: "{\"modelId\":\"other\",\"effort\":\"auto\",\"source\":\"config\"}"
        )
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        do {
            _ = try await client.setReasoningModel(sessionId: "s", modelId: "grok-4.5")
            XCTFail("A different Worker model in the response must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not confirm the requested Worker model"))
        }
        let root2 = try makeTempRoot("distill-acp-worker-mismatch-effort")
        defer { try? FileManager.default.removeItem(at: root2) }
        let (harness2, _) = try writeWorkerHarness(
            root: root2,
            initializeCapabilities: "{\"_meta\":{\"x.ai/capabilities\":{\"sessionWorkerModel\":True}}}",
            workerResult: "{\"modelId\":params.get(\"modelId\"),\"effort\":\"low\",\"source\":\"session\"}"
        )
        let client2 = try DistillACPClient(binary: harness2.path, cwd: root2.path, tagProcess: false)
        defer { client2.stop() }
        _ = try await client2.initialize()
        do {
            _ = try await client2.setReasoningModel(sessionId: "s", modelId: "grok-4.6", effortSelection: .fixed(.high))
            XCTFail("A different Worker effort in the response must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not confirm the requested Worker-model effort"), "\(error)")
        }
    }

    func test_setModelAcceptsDistill2024MinimalResponseForFixedAndAutoEffort() async throws {
        // WHY: Distill 2.0.24 answers set_model with only {model, contextWindow}; Auto main effort must not need extra acks.
        let root = try makeTempRoot("distill-acp-setmodel-2024")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}"
        )
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        let auto = try await client.newSession(cwd: root.path, modelId: "grok-4.6", mainEffortSelection: .automatic)
        XCTAssertEqual(auto.appliedMainModelId, "grok-4.6")
        XCTAssertEqual(auto.appliedMainEffortSelection, .automatic)
        let fixed = try await client.setModel(sessionId: "worker-session", modelId: "grok-4.6", reasoningEffort: .high)
        XCTAssertEqual(fixed.canonicalModelId, "grok-4.6")
        XCTAssertEqual(fixed.effort, .high)
        let setModels = try recordedRequests(requestsURL).filter { $0["method"] as? String == "session/set_model" }
        let meta = try XCTUnwrap((setModels.first?["params"] as? [String: Any])?["_meta"] as? [String: Any])
        XCTAssertEqual(meta["reasoningEffortAuto"] as? Bool, true)
    }

    func test_mainEffortForCatalogModelUnknownToStaticPolicy_isSentFromLiveCatalog_becauseUIOffersCatalogEfforts() async throws {
        // WHY: the Main effort menu lists the efforts the live Distill catalog advertises for the model.
        // The send path must honor that same catalog; a model the built-in policy does not know
        // (chatgpt/gpt-6-luna) failed with "Selected Main model does not advertise that effort".
        let root = try makeTempRoot("distill-acp-catalog-effort")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}",
            sessionModels: #"{"currentModelId":"chatgpt/gpt-6-luna","availableModels":[{"modelId":"chatgpt/gpt-6-luna","name":"GPT-6 Luna","_meta":{"reasoningEfforts":["low","medium","high"]}}]}"#
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .distill,
                model: "chatgpt/gpt-6-luna",
                cwd: root.path,
                prompt: "Go",
                distillMainEffortSelection: .fixed(.medium)
            )
        ) { events.append($0) }
        _ = try await events.waitForFinish()
        let setModels = try recordedRequests(requestsURL).filter { $0["method"] as? String == "session/set_model" }
        let params = try XCTUnwrap(setModels.last?["params"] as? [String: Any])
        XCTAssertEqual(params["modelId"] as? String, "chatgpt/gpt-6-luna")
        XCTAssertEqual((params["_meta"] as? [String: Any])?["reasoningEffort"] as? String, "medium")
        let methods = try recordedRequests(requestsURL).compactMap { $0["method"] as? String }
        XCTAssertTrue(methods.contains("session/prompt"), "the prompt must be sent once the catalog effort is bound")
    }

    /// WHY: Distill's system-level caveman `<output_style>` outranks the bot
    /// persona sent as the user turn, so bots answered in fragments. The run
    /// path must put the human reply rules on a bot's session/new, and never
    /// on a normal Agent App thread's.
    func test_botRunSessionNewCarriesHumanReplyRules_nonBotRunDoesNot() async throws {
        for isBot in [true, false] {
            let root = try makeTempRoot("distill-acp-reply-rules")
            defer { try? FileManager.default.removeItem(at: root) }
            let (harness, requestsURL) = try writeWorkerHarness(root: root, initializeCapabilities: "{}", workerResult: "{}")
            let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
            defer { adapter.stopAll() }
            let events = DistillACPAdapterEventBox()
            _ = try await adapter.startSession(
                AgentRunRequest(
                    threadId: AgentThreadID(),
                    provider: .distill,
                    model: "main",
                    cwd: root.path,
                    prompt: "bom dia",
                    environment: isBot ? [BotSelfConfigCatalog.callerEnvironmentKey: "bot-proof"] : [:]
                )
            ) { events.append($0) }
            _ = try await events.waitForFinish()
            let opens = try recordedRequests(requestsURL).filter { $0["method"] as? String == "session/new" }
            XCTAssertEqual(opens.count, 1)
            let rules = ((opens.first?["params"] as? [String: Any])?["_meta"] as? [String: Any])?["rules"] as? String
            if isBot {
                XCTAssertEqual(rules, BotRunMCPAdmission.distillBotReplyRules)
            } else {
                XCTAssertNil(rules, "a non-bot Agent App thread keeps Distill's own style")
            }
        }
    }

    /// `chatgpt/gpt-6-luna` as the live Mac distill 2.0.33 session/new advertises it (captured 2026-10-07).
    private static let liveLunaCatalogEntry = #"{"modelId":"chatgpt/gpt-6-luna","name":"GPT-6-Luna (ChatGPT)","_meta":{"totalContextTokens":872000,"agentType":"distill-plan","supportsReasoningEffort":true,"reasoningEffort":"medium","reasoningEfforts":[{"id":"low","value":"low","label":"low","default":false},{"id":"medium","value":"medium","label":"medium","default":true},{"id":"high","value":"high","label":"high","default":false},{"id":"xhigh","value":"xhigh","label":"xhigh","default":false},{"id":"max","value":"max","label":"max","default":false}]}}"#

    func test_mainEffortAdvertisedOnlyByTheSessionEffortOption_isSent_becauseTheUIOffersIt() async throws {
        // WHY: a build may list a model's efforts only in the session `reasoning_effort` option
        // (no per-model `_meta.reasoningEfforts`). The static policy does not know gpt-6-luna, so
        // reading only the per-model catalog failed with "Selected Main model does not advertise that effort".
        let root = try makeTempRoot("distill-acp-config-effort")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}",
            setModelResult: #"{"_meta":{"model":{"Ok":"gpt-6-luna"},"contextWindow":872000,"canonicalModelId":"chatgpt/gpt-6-luna","reasoningEffort":"medium","reasoningEffortAuto":false}}"#,
            sessionOpenJSON: #"{"models":{"currentModelId":"chatgpt/gpt-6-luna","availableModels":[{"modelId":"chatgpt/gpt-6-luna","name":"GPT-6-Luna (ChatGPT)"}]},"configOptions":[{"id":"reasoning_effort","type":"select","currentValue":"medium","options":[{"value":"low","name":"low"},{"value":"medium","name":"medium"},{"value":"high","name":"high"}]}]}"#
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .distill,
                model: "chatgpt/gpt-6-luna",
                cwd: root.path,
                prompt: "Go",
                distillMainEffortSelection: .fixed(.medium)
            )
        ) { events.append($0) }
        _ = try await events.waitForFinish()
        let requests = try recordedRequests(requestsURL)
        let setModel = try XCTUnwrap(requests.last { $0["method"] as? String == "session/set_model" }?["params"] as? [String: Any])
        XCTAssertEqual(setModel["modelId"] as? String, "chatgpt/gpt-6-luna")
        XCTAssertEqual((setModel["_meta"] as? [String: Any])?["reasoningEffort"] as? String, "medium")
        XCTAssertTrue(requests.contains { $0["method"] as? String == "session/prompt" },
                      "the prompt must be sent once the advertised effort is bound")
    }

    func test_mainEffortForBareModelAlias_usesTheCanonicalCatalogEntry_becauseAcksUseTheBareId() async throws {
        // WHY: Distill acks a switch with the bare id (`{"Ok":"gpt-6-luna"}`) while the catalog
        // keys the canonical `chatgpt/gpt-6-luna`. A Main selection carrying the bare id must still
        // find that model's live efforts instead of failing the turn.
        let root = try makeTempRoot("distill-acp-alias-effort")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}",
            setModelResult: #"{"_meta":{"model":{"Ok":"gpt-6-luna"},"contextWindow":872000}}"#,
            sessionOpenJSON: #"{"models":{"currentModelId":"chatgpt/gpt-6-luna","availableModels":["# + Self.liveLunaCatalogEntry + #"]}}"#
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .distill,
                model: "gpt-6-luna",
                cwd: root.path,
                prompt: "Go",
                distillMainEffortSelection: .fixed(.medium)
            )
        ) { events.append($0) }
        _ = try await events.waitForFinish()
        let requests = try recordedRequests(requestsURL)
        let setModel = try XCTUnwrap(requests.last { $0["method"] as? String == "session/set_model" }?["params"] as? [String: Any])
        XCTAssertEqual((setModel["_meta"] as? [String: Any])?["reasoningEffort"] as? String, "medium")
        XCTAssertTrue(requests.contains { $0["method"] as? String == "session/prompt" })
    }

    func test_liveLunaCatalogShape_bindsMediumAndSendsPrompt() async throws {
        // WHY: locks the exact catalog shape the Mac's distill advertises for chatgpt/gpt-6-luna
        // (object effort entries, set_model `{"Ok": bare}` + canonical ack).
        let root = try makeTempRoot("distill-acp-live-luna")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}",
            setModelResult: #"{"_meta":{"model":{"Ok":"gpt-6-luna"},"contextWindow":872000,"canonicalModelId":"chatgpt/gpt-6-luna","reasoningEffort":"medium","reasoningEffortAuto":false}}"#,
            sessionOpenJSON: #"{"models":{"currentModelId":"chatgpt/gpt-6-luna","availableModels":["# + Self.liveLunaCatalogEntry + #"]},"configOptions":[{"id":"reasoning_effort","type":"select","currentValue":"max","options":[{"value":"low"},{"value":"medium"},{"value":"high"},{"value":"xhigh"},{"value":"max"}]}]}"#
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .distill,
                model: "chatgpt/gpt-6-luna",
                cwd: root.path,
                prompt: "Go",
                distillMainEffortSelection: .fixed(.medium)
            )
        ) { events.append($0) }
        _ = try await events.waitForFinish()
        let requests = try recordedRequests(requestsURL)
        let setModel = try XCTUnwrap(requests.last { $0["method"] as? String == "session/set_model" }?["params"] as? [String: Any])
        XCTAssertEqual(setModel["modelId"] as? String, "chatgpt/gpt-6-luna")
        XCTAssertEqual((setModel["_meta"] as? [String: Any])?["reasoningEffort"] as? String, "medium")
        XCTAssertTrue(requests.contains { $0["method"] as? String == "session/prompt" })
    }

    func test_setModelAcceptsDistill2025ResultWrappedModelAck_becauseLatestDistillAnswersOkObject() async throws {
        // WHY: Distill 2.0.25 answers set_model with `"model": {"Ok": "<model>"}` (captured from the real binary).
        // Rejecting that shape failed every send with "model acknowledgement response had an unexpected shape".
        let root = try makeTempRoot("distill-acp-setmodel-2025")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}",
            setModelResult: #"{"_meta":{"model":{"Ok":"gpt-6-luna"},"contextWindow":872000,"canonicalModelId":"chatgpt/gpt-6-luna","reasoningEffort":"medium","reasoningEffortAuto":false}}"#
        )
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        let applied = try await client.setModel(
            sessionId: "worker-session",
            modelId: "chatgpt/gpt-6-luna",
            reasoningEffort: .medium,
            advertisedEfforts: [.low, .medium, .high]
        )
        XCTAssertEqual(applied.activeModelId, "gpt-6-luna")
        XCTAssertEqual(applied.canonicalModelId, "chatgpt/gpt-6-luna")
        XCTAssertEqual(applied.effort, .medium)
    }

    func test_setModelSurfacesDistillErrResult_becauseARejectedSwitchMustNotLookLikeAShapeBug() async throws {
        let root = try makeTempRoot("distill-acp-setmodel-err")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}",
            setModelResult: #"{"_meta":{"model":{"Err":"model unavailable"},"canonicalModelId":"chatgpt/gpt-6-luna"}}"#
        )
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        do {
            _ = try await client.setModel(sessionId: "worker-session", modelId: "chatgpt/gpt-6-luna")
            XCTFail("an Err switch result must fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("model unavailable"), "\(error)")
        }
    }

    func test_setModelStillRefusesEffortWithoutCatalogOrPolicy_becauseUnadvertisedEffortsCannotBeAcknowledged() async throws {
        let root = try makeTempRoot("distill-acp-unadvertised-effort")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeWorkerHarness(root: root, initializeCapabilities: "{}", workerResult: "{}")
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        do {
            _ = try await client.setModel(sessionId: "worker-session", modelId: "chatgpt/gpt-6-luna", reasoningEffort: .medium)
            XCTFail("an effort neither the catalog nor the policy advertises must not be sent")
        } catch {
            XCTAssertTrue(String(describing: error).contains("does not advertise that effort"), "\(error)")
        }
    }

    func test_adapterNeverCallsWorkerMethodOrThrowsWhenPeerDoesNotAdvertiseIt() async throws {
        // WHY: older Distill builds inherit Worker from config; a selected Worker model must not block or fail the session.
        let root = try makeTempRoot("distill-acp-worker-unsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}"
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .distill,
                model: "grok-4.6",
                cwd: root.path,
                prompt: "Go",
                reasoningModel: "grok-4.5",
                distillMainEffortSelection: .automatic,
                distillReasoningEffortSelection: .fixed(.high)
            )
        ) { events.append($0) }
        _ = try await events.waitForFinish()
        let methods = try recordedRequests(requestsURL).compactMap { $0["method"] as? String }
        XCTAssertFalse(methods.contains(DistillACPClient.workerModelSetMethod))
        XCTAssertTrue(methods.contains("session/set_model"), "Auto main effort binds through set_model without a capability flag")
    }

    private func modeSets(_ url: URL) throws -> [String] {
        try recordedRequests(url)
            .filter { $0["method"] as? String == DistillACPClient.executionModeSetMethod }
            .compactMap { ($0["params"] as? [String: Any])?["mode"] as? String }
    }

    private func legacyUltracodeSets(_ url: URL) throws -> [Bool] {
        try recordedRequests(url)
            .filter { $0["method"] as? String == DistillACPClient.ultracodeSetMethod }
            .compactMap { ($0["params"] as? [String: Any])?["enabled"] as? Bool }
    }

    func test_executionModeIsAppliedOnlyOnChange_becauseTurnsMustNotResendUnchangedMode() async throws {
        // WHY: the mode is session state in Distill; the host sends it only when the thread's mode differs from the ACP session.
        let root = try makeTempRoot("distill-acp-mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(root: root, initializeCapabilities: "{}", workerResult: "{}")
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let threadID = AgentThreadID()
        func request(_ mode: DistillExecutionMode, providerThreadId: String? = nil) -> AgentRunRequest {
            AgentRunRequest(
                threadId: threadID, provider: .distill, model: "grok-4.6", cwd: root.path, prompt: "Go",
                providerThreadId: providerThreadId, distillExecutionMode: mode
            )
        }
        let first = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(request(.auto)) { first.append($0) }
        let firstFinished = try await first.waitForFinish()
        XCTAssertEqual(try modeSets(requestsURL), [], "Auto on a fresh session sends nothing")

        var last = firstFinished.providerThreadId
        for mode in [DistillExecutionMode.ultrafast, .ultrafast, .ultrasave, .ultracode, .ultracode, .normal] {
            let box = DistillACPAdapterEventBox()
            _ = try await adapter.sendTurn(request(mode, providerThreadId: last)) { box.append($0) }
            last = try await box.waitForFinish().providerThreadId
        }
        XCTAssertEqual(try modeSets(requestsURL), ["ultrafast", "ultrasave", "ultracode", "normal"])
        XCTAssertEqual(try legacyUltracodeSets(requestsURL), [], "the legacy endpoint is only a fallback")
    }

    func test_ultrasaveOnFreshSessionIsSentBeforePrompt() async throws {
        let root = try makeTempRoot("distill-acp-mode-first")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(root: root, initializeCapabilities: "{}", workerResult: "{}")
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            AgentRunRequest(threadId: AgentThreadID(), provider: .distill, model: "grok-4.6", cwd: root.path,
                            prompt: "Go", distillExecutionMode: .ultrasave)
        ) { events.append($0) }
        _ = try await events.waitForFinish()
        let methods = try recordedRequests(requestsURL).compactMap { $0["method"] as? String }
        XCTAssertEqual(try modeSets(requestsURL), ["ultrasave"])
        let setIndex = try XCTUnwrap(methods.firstIndex(of: DistillACPClient.executionModeSetMethod))
        let promptIndex = try XCTUnwrap(methods.firstIndex(of: "session/prompt"))
        XCTAssertLessThan(setIndex, promptIndex)
    }

    func test_olderDistillWithoutExecutionModeFallsBackToTheUltracodeFlag_becauseThatIsTheOnlyModeItKnows() async throws {
        let root = try makeTempRoot("distill-acp-mode-old")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root, initializeCapabilities: "{}", workerResult: "{}",
            executionModeReplyJSON: #"{"jsonrpc":"2.0","id":message["id"],"error":{"code":-32601,"message":"method not found"}}"#
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            AgentRunRequest(threadId: AgentThreadID(), provider: .distill, model: "grok-4.6", cwd: root.path,
                            prompt: "Go", distillExecutionMode: .ultracode)
        ) { events.append($0) }
        let finished = try await events.waitForFinish()
        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(try modeSets(requestsURL), ["ultracode"])
        XCTAssertEqual(try legacyUltracodeSets(requestsURL), [true])
    }

    func test_unsupportedExecutionModeDoesNotSendPrompt() async throws {
        let root = try makeTempRoot("distill-acp-mode-none")
        defer { try? FileManager.default.removeItem(at: root) }
        let notFound = #"{"jsonrpc":"2.0","id":message["id"],"error":{"code":-32601,"message":"method not found"}}"#
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root, initializeCapabilities: "{}", workerResult: "{}",
            ultracodeReplyJSON: notFound, executionModeReplyJSON: notFound
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        do {
            _ = try await adapter.startSession(
                AgentRunRequest(threadId: AgentThreadID(), provider: .distill, model: "grok-4.6", cwd: root.path,
                                prompt: "Go", distillExecutionMode: .ultrafast)
            ) { _ in }
            XCTFail("An unavailable mode must not silently run with another mode")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Ultrafast"), error.localizedDescription)
        }
        XCTAssertFalse(try recordedRequests(requestsURL).contains { $0["method"] as? String == "session/prompt" })
    }

    func test_executionModeRequiresMatchingAcknowledgementBeforePrompt() async throws {
        let root = try makeTempRoot("distill-acp-mode-confirmation")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root, initializeCapabilities: "{}", workerResult: "{}",
            executionModeReplyJSON: #"{"jsonrpc":"2.0","id":message["id"],"result":{"mode":"normal"}}"#
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        do {
            _ = try await adapter.startSession(
                AgentRunRequest(threadId: AgentThreadID(), provider: .distill, model: "grok-4.6", cwd: root.path,
                                prompt: "Go", distillExecutionMode: .ultrasave)
            ) { _ in }
            XCTFail("A different acknowledged mode must not accept the prompt")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Ultrasave"), error.localizedDescription)
        }
        XCTAssertFalse(try recordedRequests(requestsURL).contains { $0["method"] as? String == "session/prompt" })
    }

    func test_autoRejectedByOlderDistillDoesNotFailTheTurnAndIsNotRetried() async throws {
        // WHY: Distill <= 2.0.54 rejects "auto" with invalid params; the turn must still run and not re-send every turn.
        let root = try makeTempRoot("distill-acp-mode-auto-old")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root, initializeCapabilities: "{}", workerResult: "{}",
            executionModeReplyJSON: #"{"jsonrpc":"2.0","id":message["id"],"error":{"code":-32602,"message":"unknown variant auto"}} if params.get("mode") == "auto" else {"jsonrpc":"2.0","id":message["id"],"result":{"mode":params.get("mode")}}"#
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let threadID = AgentThreadID()
        func request(_ mode: DistillExecutionMode, providerThreadId: String? = nil) -> AgentRunRequest {
            AgentRunRequest(threadId: threadID, provider: .distill, model: "grok-4.6", cwd: root.path, prompt: "Go",
                            providerThreadId: providerThreadId, distillExecutionMode: mode)
        }
        let first = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(request(.ultracode)) { first.append($0) }
        var last = try await first.waitForFinish().providerThreadId
        for _ in 0..<2 {
            let box = DistillACPAdapterEventBox()
            _ = try await adapter.sendTurn(request(.auto, providerThreadId: last)) { box.append($0) }
            let finished = try await box.waitForFinish()
            XCTAssertEqual(finished.status, .completed)
            last = finished.providerThreadId
        }
        XCTAssertEqual(try modeSets(requestsURL), ["ultracode", "auto", "normal"],
                       "Auto is attempted once, followed by one reset to Normal, then recorded as applied")
        XCTAssertEqual(try legacyUltracodeSets(requestsURL), [])
    }

    func test_clientSetExecutionModeAcceptsAutoChoiceWithEffectiveMode() async throws {
        // WHY: Distill 2.0.55 answers Auto with the effective fixed mode plus choice "auto"; that must confirm Auto.
        let root = try makeTempRoot("distill-acp-mode-auto-wire")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root, initializeCapabilities: "{}", workerResult: "{}",
            executionModeReplyJSON: #"{"jsonrpc":"2.0","id":message["id"],"result":{"mode":"normal","choice":"auto"}}"#
        )
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        let applied = try await client.setExecutionMode(sessionId: "s1", mode: .auto)
        XCTAssertEqual(applied, .auto)
        let sent = try recordedRequests(requestsURL).first { $0["method"] as? String == DistillACPClient.executionModeSetMethod }
        XCTAssertEqual((sent?["params"] as? [String: Any])?["mode"] as? String, "auto")
    }

    func test_resumedSessionExplicitlyRestoresNormalBeforePrompt() async throws {
        let root = try makeTempRoot("distill-acp-mode-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root, initializeCapabilities: #"{"loadSession":True}"#, workerResult: "{}"
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            AgentRunRequest(threadId: AgentThreadID(), provider: .distill, model: "grok-4.6", cwd: root.path,
                            prompt: "Go", providerThreadId: "worker-session", distillExecutionMode: .normal)
        ) { events.append($0) }
        _ = try await events.waitForFinish()
        XCTAssertEqual(try modeSets(requestsURL), ["normal"], "a saved session can still have a previous non-Normal mode")
        let methods = try recordedRequests(requestsURL).compactMap { $0["method"] as? String }
        if let modeIndex = methods.firstIndex(of: DistillACPClient.executionModeSetMethod) {
            XCTAssertLessThan(modeIndex, try XCTUnwrap(methods.firstIndex(of: "session/prompt")))
        }
    }

    func test_clientSetExecutionModeSendsSessionAndModeAndReturnsTheConfirmedMode() async throws {
        let root = try makeTempRoot("distill-acp-mode-wire")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(root: root, initializeCapabilities: "{}", workerResult: "{}")
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        let applied = try await client.setExecutionMode(sessionId: "s1", mode: .ultrafast)
        XCTAssertEqual(applied, .ultrafast)
        let params = try recordedRequests(requestsURL)
            .filter { $0["method"] as? String == "_x.ai/session/execution_mode/set" }
            .compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(params.first?["sessionId"] as? String, "s1")
        XCTAssertEqual(params.first?["mode"] as? String, "ultrafast")
    }

    func test_selectedModelRunsTurnsAndResumesOnTheSameACPThread() async throws {
        // WHY: provider selection must reach the harness, and follow-up turns must
        // reuse its session rather than starting a disconnected conversation.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-acp-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        count = 0
        state = {"main": None, "reasoning": None}
        def record(value):
            with requests.open("a") as output:
                output.write(json.dumps(value) + "\\n")
        def prompt_text(blocks):
            if isinstance(blocks, str): return blocks
            if isinstance(blocks, dict): return blocks.get("text", "")
            if isinstance(blocks, list): return " ".join(prompt_text(block) for block in blocks)
            return ""
        def send(value):
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{
                    "protocolVersion":1,
                    "agentCapabilities":{"loadSession":True,"sessionCapabilities":{"resume":True},"promptCapabilities":{},"_meta":{"x.ai/capabilities":{"sessionWorkerModel":True}}}
                }})
            elif method == "session/new":
                params = message.get("params", {})
                meta = params.get("_meta", {})
                state["main"] = meta.get("modelId")
                record({"method":method,"modelId":state["main"]})
                send({"jsonrpc":"2.0", "id":message["id"], "result":{
                    "sessionId":"distill-session-1",
                    "models":{"availableModels":[{"modelId":"gpt-6-luna","name":"GPT-6 Luna"}],"currentModelId":"gpt-6-luna"}
                }})
            elif method == "_x.ai/session/worker_model/set":
                params = message.get("params", {})
                reasoning_model = params.get("modelId") or None
                record({"method":method,"sessionId":params.get("sessionId"),"reasoningModelId":params.get("modelId"),"effort":params.get("effort")})
                if reasoning_model is not None and reasoning_model == state["main"]:
                    send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32602,"message":"Reasoning model must differ from the Main model"}})
                else:
                    state["reasoning"] = reasoning_model
                    send({"jsonrpc":"2.0", "id":message["id"], "result":{"modelId":reasoning_model,"effort":params.get("effort") or "auto","source":"session"}})
            elif method == "session/set_model":
                params = message.get("params", {})
                next_main = params.get("modelId")
                record({"method":method,"modelId":next_main})
                if next_main is not None and next_main == state["reasoning"]:
                    send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32602,"message":"Main model must differ from the Reasoning model"}})
                else:
                    state["main"] = next_main
                    send({"jsonrpc":"2.0", "id":message["id"], "result":{"meta":{"model":next_main,"canonicalModelId":next_main}}})
            elif method == "_x.ai/session/execution_mode/set":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"mode":message.get("params", {}).get("mode")}})
            elif method in ("session/set_mode", "session/set_config_option"):
                send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
            elif method == "session/prompt":
                count += 1
                params = message.get("params", {})
                text = prompt_text(params.get("prompt", []))
                record({"method":method,"sessionId":params.get("sessionId"),"firstRequestPresent":"First request" in text,"followUpPresent":"Follow-up request" in text})
                send({"jsonrpc":"2.0", "method":"session/update", "params":{
                    "sessionId":"distill-session-1",
                    "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Distill reply " + str(count)}}
                }})
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"stopReason":"end_turn"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)

        let adapter = DistillACPAdapter(binaryNameOverride: harnessURL.path)
        defer { adapter.stopAll() }
        let threadID = AgentThreadID()
        let request = AgentRunRequest(
            threadId: threadID,
            provider: .distill,
            model: "gpt-6-luna",
            cwd: root.path,
            prompt: "First request",
            reasoningModel: "grok-4.5"
        )
        let first = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(request) { first.append($0) }
        let firstFinished = try await first.waitForFinish()
        XCTAssertEqual(firstFinished.providerThreadId, "distill-session-1")
        XCTAssertEqual(firstFinished.finalMessage, "Distill reply 1")

        let second = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            AgentRunRequest(
                threadId: threadID,
                provider: .distill,
                model: "gpt-6-luna",
                cwd: root.path,
                prompt: "Follow-up request",
                providerThreadId: firstFinished.providerThreadId,
                reasoningModel: "grok-4.6"
            )
        ) { second.append($0) }
        let secondFinished = try await second.waitForFinish()
        XCTAssertEqual(secondFinished.providerThreadId, "distill-session-1")
        XCTAssertEqual(secondFinished.finalMessage, "Distill reply 2")
        let third = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            AgentRunRequest(
                threadId: threadID,
                provider: .distill,
                model: "grok-4.6",
                cwd: root.path,
                prompt: "Third request swaps Main and Reasoning",
                providerThreadId: secondFinished.providerThreadId,
                reasoningModel: "gpt-6-luna"
            )
        ) { third.append($0) }
        let thirdFinished = try await third.waitForFinish()
        XCTAssertEqual(thirdFinished.finalMessage, "Distill reply 3")
        let fourth = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            AgentRunRequest(
                threadId: threadID,
                provider: .distill,
                model: "grok-4.6",
                cwd: root.path,
                prompt: "Fourth request disables Reasoning",
                providerThreadId: thirdFinished.providerThreadId,
                reasoningModel: nil
            )
        ) { fourth.append($0) }
        let fourthFinished = try await fourth.waitForFinish()
        XCTAssertEqual(fourthFinished.finalMessage, "Distill reply 4")

        let requests = try String(contentsOf: requestsURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let sessionOpen = try XCTUnwrap(requests.first { $0["method"] as? String == "session/new" })
        XCTAssertEqual(sessionOpen["modelId"] as? String, "gpt-6-luna",
                       "the selected Distill main model must reach session/new")
        let reasoningSelections = requests.filter { $0["method"] as? String == "_x.ai/session/worker_model/set" }
        XCTAssertEqual(reasoningSelections.map { $0["reasoningModelId"] as? String }, ["grok-4.5", "grok-4.6", "", "gpt-6-luna", ""],
                       "a crossed swap must clear Reasoning, change Main, apply the new Reasoning model, and then support Off")
        XCTAssertEqual(reasoningSelections.map { $0["sessionId"] as? String }, Array(repeating: "distill-session-1", count: 5))
        let crossSwapMainIndex = try XCTUnwrap(requests.firstIndex { $0["method"] as? String == "session/set_model" && $0["modelId"] as? String == "grok-4.6" })
        let crossSwapReasoningIndex = try XCTUnwrap(requests.firstIndex { $0["method"] as? String == "_x.ai/session/worker_model/set" && $0["reasoningModelId"] as? String == "gpt-6-luna" })
        XCTAssertLessThan(crossSwapMainIndex, crossSwapReasoningIndex,
                          "when the new Reasoning model equals the currently active Main model, switch Main first")
        let prompts = requests.filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.count, 4, "all user turns must use the selected Distill session")
        XCTAssertEqual(prompts.map { $0["sessionId"] as? String }, Array(repeating: "distill-session-1", count: 4))
        XCTAssertEqual(prompts.map { $0["firstRequestPresent"] as? Bool }, [true, false, false, false])
        XCTAssertEqual(prompts.map { $0["followUpPresent"] as? Bool }, [false, true, false, false])
        XCTAssertTrue(second.assistantText.contains("Distill reply 2"))
        XCTAssertTrue(third.assistantText.contains("Distill reply 3"))
        XCTAssertTrue(fourth.assistantText.contains("Distill reply 4"))
        let history = try await adapter.readThread(threadId: threadID)
        XCTAssertTrue(history.contains {
            if case .itemDelta(_, let body, _, _) = $0 { return body == "Distill reply 1" || body == "Distill reply 2" }
            return false
        }, "the resumed ACP session must retain its readable conversation history")
    }

    // MARK: - Real provider errors and cross-family sessions

    /// One harness process per adapter session (the adapter spawns a client per
    /// session), so session ids come from a shared counter file.
    private func writeFailureHarness(root: URL) throws -> (harness: URL, requests: URL) {
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let counterURL = root.appendingPathComponent("sessions.count")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        counter = pathlib.Path(\(String(reflecting: counterURL.path)))
        def record(value):
            with requests.open("a") as output:
                output.write(json.dumps(value) + "\\n")
        def send(value): print(json.dumps(value), flush=True)
        def prompt_text(blocks):
            if isinstance(blocks, str): return blocks
            if isinstance(blocks, dict): return blocks.get("text", "")
            if isinstance(blocks, list): return "\\n".join(prompt_text(block) for block in blocks)
            return ""
        def next_session():
            count = int(counter.read_text()) + 1 if counter.exists() else 1
            counter.write_text(str(count))
            return "distill-session-%d" % count
        def fail(message_id, data):
            error = {"code":-32603,"message":"Internal error"}
            if data is not None: error["data"] = data
            send({"jsonrpc":"2.0","id":message_id,"error":error})
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {}) or {}
            if "id" not in message:
                continue
            if method == "initialize":
                send({"jsonrpc":"2.0","id":message["id"],"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True,"promptCapabilities":{}}}})
            elif method in ("session/new", "session/load"):
                model = (params.get("_meta") or {}).get("modelId")
                session = params.get("sessionId") or next_session()
                record({"method":method,"sessionId":session,"modelId":model})
                if method == "session/new":
                    # Real Distill announces commands before the first prompt; the
                    # mapper turns that into threadStarted for the new session.
                    send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":session,"update":{"sessionUpdate":"available_commands_update","availableCommands":[]}}})
                send({"jsonrpc":"2.0","id":message["id"],"result":{"sessionId":session,"models":{"availableModels":[],"currentModelId":model}}})
            elif method == "session/set_model":
                record({"method":method,"sessionId":params.get("sessionId"),"modelId":params.get("modelId")})
                send({"jsonrpc":"2.0","id":message["id"],"result":{"meta":{"model":params.get("modelId"),"canonicalModelId":params.get("modelId")}}})
            elif method == "_x.ai/session/execution_mode/set":
                send({"jsonrpc":"2.0","id":message["id"],"result":{"mode":params.get("mode")}})
            elif method == "session/prompt":
                session = params.get("sessionId")
                text = prompt_text(params.get("prompt", []))
                record({"method":method,"sessionId":session,"text":text})
                if "EXIT_143" in text:
                    print("\\x1b[31mold tool_error: missing field tool_input\\x1b[0m", file=sys.stderr, flush=True)
                    print("old recovered API error: HTTP 429 Too Many Requests; authentication required", file=sys.stderr, flush=True)
                    print("previous output " * 150, file=sys.stderr, flush=True)
                    print("MacCode guest lease expired: no host renewal for 50 seconds", file=sys.stderr, flush=True)
                    sys.exit(143)
                elif "FAIL_DATA" in text:
                    fail(message["id"], {"message":"API error (status 400 Bad Request): invalid_request_error: model not allowed for this account","http_status":400})
                elif "FAIL_AUTH" in text:
                    fail(message["id"], {"message":"upstream rejected the request","http_status":401})
                elif "FAIL_SIGNATURE" in text:
                    fail(message["id"], {"message":"API error (status 400 Bad Request): invalid_request_error: messages.1.content.3: Invalid `signature` in `thinking` block","http_status":400})
                elif "FAIL_ENCRYPTED" in text:
                    fail(message["id"], {"message":"API error (status 400 Bad Request): invalid_request_error: The encrypted content for item rs_test_encrypted could not be verified. Reason: Encrypted content could not be decrypted or parsed.","http_status":400})
                elif "FAIL_BARE" in text:
                    send({"jsonrpc":"2.0","method":"_x.ai/session/prompt_complete","params":{"sessionId":"some-other-session","promptId":"p0","stopReason":"error","agentResult":"stale failure from another session"}})
                    send({"jsonrpc":"2.0","method":"_x.ai/session/prompt_complete","params":{"sessionId":session,"promptId":"p1","stopReason":"error","agentResult":"API error (status 404 Not Found): Provider returned error"}})
                    fail(message["id"], None)
                elif "BURST_HANG" in text:
                    # A long stream whose session/prompt never returns.
                    for _ in range(2000):
                        send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":session,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x"}}}})
                elif "TOOL_HANG" in text:
                    # A blocking tool call that stays open silently, then completes.
                    import time
                    send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":session,"update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"get_command_or_subagent_output","status":"in_progress"}}})
                    time.sleep(2.5)
                    send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":session,"update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed"}}})
                    send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":session,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}})
                    send({"jsonrpc":"2.0","id":message["id"],"result":{"stopReason":"end_turn"}})
                else:
                    send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":session,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"reply from " + session}}}})
                    send({"jsonrpc":"2.0","id":message["id"],"result":{"stopReason":"end_turn"}})
            else:
                send({"jsonrpc":"2.0","id":message["id"],"result":{}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        return (harnessURL, requestsURL)
    }

    private func distillRequest(
        thread: AgentThreadID,
        model: String,
        prompt: String,
        root: URL,
        providerThreadId: String? = nil
    ) -> AgentRunRequest {
        AgentRunRequest(
            threadId: thread,
            provider: .distill,
            model: model,
            cwd: root.path,
            prompt: prompt,
            providerThreadId: providerThreadId
        )
    }

    func test_processExitReportsOneFailureEvenWhenTheErrorConsumerIsSlow() async throws {
        let root = try makeTempRoot("distill-acp-exit-once")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        adapter.autoRoutingPreflight = { _ in [] }
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        let slowConsumer = DispatchSemaphore(value: 0)
        _ = try await adapter.startSession(
            distillRequest(thread: AgentThreadID(), model: "auto", prompt: "EXIT_143", root: root)
        ) { event in
            events.append(event)
            if case .error = event {
                // Give the failed prompt waiter time to race process termination.
                _ = slowConsumer.wait(timeout: .now() + 0.2)
            }
        }

        let finished = try await events.waitForFinish()
        XCTAssertEqual(finished.status, .failed)
        XCTAssertEqual(events.finishedCount, 1)
        XCTAssertEqual(events.errors.count, 1, "one process exit must produce one visible failure")
        let message = try XCTUnwrap(events.errors.first)
        XCTAssertTrue(message.hasPrefix("Distill ACP failure:"), "old API errors must not reclassify a killed process: \(message)")
        XCTAssertTrue(message.contains("exit 143"), message)
        XCTAssertTrue(message.contains("Last stderr (may precede the exit)"), message)
        XCTAssertTrue(message.contains("old tool_error: missing field tool_input"), message)
        XCTAssertTrue(message.contains("MacCode guest lease expired"), "the latest cause must survive diagnostic truncation: \(message)")
        XCTAssertFalse(message.contains("\u{001B}"), message)
    }

    func test_promptRPCErrorDataReplacesGenericInternalError_becauseUsersMustSeeTheProviderFailure() async throws {
        // WHY: Distill answers every failed turn with "-32603 Internal error" and
        // the real provider failure in error.data; showing only "Internal error"
        // hid 400/404/auth causes from users (13 masked runs in the field).
        let root = try makeTempRoot("distill-acp-error-data")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }

        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: AgentThreadID(), model: "claude/claude-opus-5-5", prompt: "FAIL_DATA", root: root)
        ) { events.append($0) }
        let finished = try await events.waitForFinish()
        XCTAssertEqual(finished.status, .failed)
        let error = try XCTUnwrap(events.errors.last)
        XCTAssertTrue(error.contains("model not allowed for this account"),
                      "error.data.message must reach the user, got: \(error)")
        XCTAssertFalse(error.contains("Internal error"),
                       "the generic JSON-RPC message must not mask the provider text, got: \(error)")

        let auth = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: AgentThreadID(), model: "claude/claude-opus-5-5", prompt: "FAIL_AUTH", root: root)
        ) { auth.append($0) }
        _ = try await auth.waitForFinish()
        let authError = try XCTUnwrap(auth.errors.last)
        XCTAssertTrue(authError.hasPrefix(DistillACPFailureTaxonomy.authRequiredMarker),
                      "an HTTP 401 carried only in error.data.http_status must classify as auth (Sign in), got: \(authError)")
    }

    func test_bareInternalErrorFallsBackToSameSessionPromptCompleteResult() async throws {
        // WHY: builds that send no error.data still announce the provider failure
        // as x.ai/session/prompt_complete; only this session's current prompt may
        // supply the text, never another session's stale result.
        let root = try makeTempRoot("distill-acp-prompt-complete")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }

        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: AgentThreadID(), model: "muse-spark-1.3-contributor", prompt: "FAIL_BARE", root: root)
        ) { events.append($0) }
        let finished = try await events.waitForFinish()
        XCTAssertEqual(finished.status, .failed)
        let error = try XCTUnwrap(events.errors.last)
        XCTAssertTrue(error.contains("404 Not Found): Provider returned error"),
                      "prompt_complete.agentResult must replace the bare Internal error, got: \(error)")
        XCTAssertFalse(error.contains("stale failure from another session"))
    }

    func test_switchingMainFromNonClaudeToClaudeOpensNewSessionWithHandoff_becauseAnthropicRejectsForeignReasoning() async throws {
        // WHY: Distill replays the old family's unsigned reasoning as Anthropic
        // `thinking` blocks; session/set_model on the old session made every
        // later Claude turn fail with HTTP 400. The thread must keep its context
        // through an app-built handoff and persist the new session id.
        let root = try makeTempRoot("distill-acp-family-switch")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let thread = AgentThreadID()

        let first = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: thread, model: "muse-spark-1.3-contributor", prompt: "First request", root: root)
        ) { first.append($0) }
        let firstFinished = try await first.waitForFinish()
        XCTAssertEqual(firstFinished.providerThreadId, "distill-session-1")

        var second = distillRequest(
            thread: thread,
            model: "claude/claude-opus-5-5",
            prompt: "Second request",
            root: root,
            providerThreadId: firstFinished.providerThreadId
        )
        second.contextSnapshot = ConversationContextSnapshot(
            items: [
                .init(messageId: "m1", role: .user, ordinal: 0, canonicalText: "First request"),
                .init(messageId: "m2", role: .assistant, ordinal: 1, canonicalText: "reply from distill-session-1")
            ],
            digest: "digest"
        )
        let secondEvents = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(second) { secondEvents.append($0) }
        let secondFinished = try await secondEvents.waitForFinish()
        XCTAssertEqual(secondFinished.status, .completed)
        XCTAssertEqual(secondFinished.providerThreadId, "distill-session-2",
                       "the coordinator persists this id, so a restart resumes the new session")

        let requests = try recordedRequests(requestsURL)
        XCTAssertFalse(requests.contains { $0["method"] as? String == "session/set_model" },
                       "the muse-spark session must never be switched to Claude in place")
        let opens = requests.filter { $0["method"] as? String == "session/new" }
        XCTAssertEqual(opens.map { $0["modelId"] as? String }, ["muse-spark-1.3-contributor", "claude/claude-opus-5-5"])
        let prompts = requests.filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.map { $0["sessionId"] as? String }, ["distill-session-1", "distill-session-2"])
        let seeded = try XCTUnwrap(prompts.last?["text"] as? String)
        XCTAssertTrue(seeded.contains("[RemoteCode context handoff]"))
        XCTAssertTrue(seeded.contains("User: First request") && seeded.contains("Assistant: reply from distill-session-1"),
                      "the new session must carry the earlier conversation forward")
        XCTAssertTrue(seeded.contains("Second request"))
        XCTAssertEqual(secondEvents.noticeSummaries,
                       [DistillACPAdapter.modelFamilySwitchNotice + DistillACPAdapter.handoffCarriedNoticeSuffix],
                       "the transcript must say a new Distill session was started and got the conversation")
        XCTAssertTrue(secondEvents.contextCompactionSummaries.isEmpty,
                      "a new session is not a provider compaction; the context meter and iOS must not report one")
        XCTAssertEqual(secondEvents.acceptedSessionModels.map(\.sessionId), ["distill-session-2"])
        XCTAssertEqual(secondEvents.acceptedSessionModels.map(\.model), ["claude/claude-opus-5-5"],
                       "the coordinator records the model the new session really accepted")

        // After an app restart the live session is gone; session/load would
        // replay the same foreign history, so the persisted cursor is not loaded.
        let restarted = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { restarted.stopAll() }
        var resumed = distillRequest(
            thread: AgentThreadID(),
            model: "claude/claude-opus-5-5",
            prompt: "After restart",
            root: root,
            providerThreadId: "distill-session-1"
        )
        resumed.priorProviderSessionModel = "muse-spark-1.3-contributor"
        let resumedEvents = DistillACPAdapterEventBox()
        _ = try await restarted.sendTurn(resumed) { resumedEvents.append($0) }
        let resumedFinished = try await resumedEvents.waitForFinish()
        XCTAssertEqual(resumedFinished.providerThreadId, "distill-session-3")
        let afterRestart = try recordedRequests(requestsURL)
        XCTAssertFalse(afterRestart.contains { $0["method"] as? String == "session/load" })
        let unseeded = try XCTUnwrap(afterRestart.last { $0["method"] as? String == "session/prompt" }?["text"] as? String)
        XCTAssertTrue(unseeded.contains("The earlier conversation is not available"),
                      "without a transcript snapshot the model must be told earlier context is not loaded")
        XCTAssertEqual(resumedEvents.noticeSummaries,
                       [DistillACPAdapter.modelFamilySwitchNotice + DistillACPAdapter.handoffMissingNoticeSuffix],
                       "the row must not claim a summary was carried over when none was")
    }

    func test_sameFamilySwitchStillUsesSetModelAndRestartStillLoads() async throws {
        // WHY: Claude-to-Claude (and non-Claude-to-non-Claude) switches keep their
        // history valid, so they must stay in the same session, live and resumed.
        let root = try makeTempRoot("distill-acp-same-family")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let thread = AgentThreadID()

        let first = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: thread, model: "claude/claude-sonnet-5", prompt: "First request", root: root)
        ) { first.append($0) }
        let firstFinished = try await first.waitForFinish()
        let second = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            distillRequest(thread: thread, model: "claude/claude-opus-5-5", prompt: "Second request", root: root,
                           providerThreadId: firstFinished.providerThreadId)
        ) { second.append($0) }
        let secondFinished = try await second.waitForFinish()
        XCTAssertEqual(secondFinished.providerThreadId, "distill-session-1")
        XCTAssertTrue(second.noticeSummaries.isEmpty)

        let restarted = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { restarted.stopAll() }
        var resumed = distillRequest(thread: AgentThreadID(), model: "claude/claude-opus-5-5",
                                     prompt: "After restart", root: root, providerThreadId: "distill-session-1")
        resumed.priorProviderSessionModel = "claude/claude-sonnet-5"
        let resumedEvents = DistillACPAdapterEventBox()
        _ = try await restarted.sendTurn(resumed) { resumedEvents.append($0) }
        _ = try await resumedEvents.waitForFinish()

        let requests = try recordedRequests(requestsURL)
        let setModels = requests.filter { $0["method"] as? String == "session/set_model" }
        XCTAssertEqual(setModels.map { $0["sessionId"] as? String }, ["distill-session-1"])
        XCTAssertEqual(setModels.map { $0["modelId"] as? String }, ["claude/claude-opus-5-5"])
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/new" }.count, 1)
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/load" }.map { $0["sessionId"] as? String },
                       ["distill-session-1"])
        let prompts = requests.filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.map { $0["sessionId"] as? String }, Array(repeating: "distill-session-1", count: 3))
        XCTAssertFalse(prompts.contains { ($0["text"] as? String)?.contains("[RemoteCode context handoff]") == true })
    }

    func test_rejectedThinkingSignatureRetiresSessionSoRetryRunsInANewSession() async throws {
        // WHY: Retry used to re-send into the same poisoned session and hit the
        // same 400 forever. The failure must say Retry starts a new session, and
        // the retry on the SAME thread (bot desk link intact) must do exactly that.
        let root = try makeTempRoot("distill-acp-signature")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let thread = AgentThreadID()

        let failed = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: thread, model: "claude/claude-opus-5-5", prompt: "FAIL_SIGNATURE", root: root)
        ) { failed.append($0) }
        let failedFinished = try await failed.waitForFinish()
        XCTAssertEqual(failedFinished.status, .failed)
        let error = try XCTUnwrap(failed.errors.last)
        XCTAssertTrue(error.hasPrefix(DistillACPFailureTaxonomy.incompatibleHistoryMarker), error)
        XCTAssertTrue(error.contains("Invalid `signature` in `thinking` block"), error)

        let retry = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            distillRequest(thread: thread, model: "claude/claude-opus-5-5", prompt: "Retry request", root: root,
                           providerThreadId: failedFinished.providerThreadId)
        ) { retry.append($0) }
        let retried = try await retry.waitForFinish()
        XCTAssertEqual(retried.status, .completed)
        XCTAssertEqual(retried.providerThreadId, "distill-session-2")
        XCTAssertEqual(retry.noticeSummaries,
                       [DistillACPAdapter.incompatibleHistoryNotice + DistillACPAdapter.handoffMissingNoticeSuffix])
        XCTAssertEqual(failed.rejectedSessionIds, ["distill-session-1"],
                       "the coordinator persists the rejection so Retry after a restart opens a new session too")
        let prompts = try recordedRequests(requestsURL).filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.map { $0["sessionId"] as? String }, ["distill-session-1", "distill-session-2"])
    }

    func test_rejectedEncryptedContentRetriesFreshWithLocalHistoryOnSameThread() async throws {
        // Reusing rejected encrypted history repeats the 400; only an explicit retry may start a replacement.
        let root = try makeTempRoot("distill-acp-encrypted-history")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let thread = AgentThreadID()
        let failed = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: thread, model: "chatgpt/gpt-6.1-sol", prompt: "FAIL_ENCRYPTED", root: root)
        ) { failed.append($0) }
        let failedFinished = try await failed.waitForFinish()
        XCTAssertEqual(failedFinished.status, .failed)
        let error = try XCTUnwrap(failed.errors.last)
        XCTAssertTrue(error.hasPrefix(DistillACPFailureTaxonomy.incompatibleHistoryMarker), error)
        XCTAssertTrue(error.contains("Encrypted content could not be decrypted or parsed"), error)
        XCTAssertEqual(failed.rejectedSessionIds, ["distill-session-1"],
                       "Rejection must persist so restart cannot reload the invalid session.")
        XCTAssertEqual(try recordedRequests(requestsURL).filter { $0["method"] as? String == "session/prompt" }.count, 1,
                       "Recovery must not automatically repeat possibly consequential work.")

        var retryRequest = distillRequest(
            thread: thread, model: "chatgpt/gpt-6.1-sol", prompt: "Retry request", root: root,
            providerThreadId: failedFinished.providerThreadId
        )
        retryRequest.priorConversationTail = [
            AgentMessage(threadId: thread, role: .user, content: "Prior task context"),
            AgentMessage(threadId: thread, role: .assistant, content: "Previously verified result")
        ]
        let retry = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(retryRequest) { retry.append($0) }
        let retried = try await retry.waitForFinish()
        XCTAssertEqual(retried.status, .completed)
        XCTAssertEqual(retried.providerThreadId, "distill-session-2")
        XCTAssertEqual(retry.noticeSummaries,
                       [DistillACPAdapter.incompatibleHistoryNotice + DistillACPAdapter.handoffCarriedNoticeSuffix])
        let requests = try recordedRequests(requestsURL)
        XCTAssertFalse(requests.contains { $0["method"] as? String == "session/load" })
        let prompts = requests.filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.map { $0["sessionId"] as? String }, ["distill-session-1", "distill-session-2"])
        let retryText = try XCTUnwrap(prompts.last?["text"] as? String)
        XCTAssertTrue(retryText.contains("Prior task context") && retryText.contains("Previously verified result"),
                      "Replacement must carry local text history, not rejected encrypted provider items.")
    }

    func test_longThreadHandoffCarriesNewestMessagesBeyondRCSEEDLimits() async throws {
        // WHY: the RCSEED snapshot is nil past 100 messages / 64 KB, which is
        // exactly the long bot desk thread most likely to switch families. The
        // coordinator's tail has no such ceiling; the newest messages must win.
        let root = try makeTempRoot("distill-acp-long-handoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let thread = AgentThreadID()
        let history = (0..<150).map { index in
            AgentMessage(
                threadId: thread,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "history-\(index)-marker " + String(repeating: "y", count: 1_000)
            )
        }
        XCTAssertNil(ConversationContextSnapshot.capture(
            messages: history, excludingCurrentUserText: nil
        ), "precondition: this history is past the RCSEED limits")

        var request = distillRequest(thread: thread, model: "claude/claude-opus-5-5", prompt: "Continue please",
                                     root: root, providerThreadId: "muse-session")
        request.priorProviderSessionModel = "muse-spark-1.3-contributor"
        request.priorConversationTail = Array(history.suffix(DistillACPAdapter.handoffMaxMessages + 1))
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(request) { events.append($0) }
        _ = try await events.waitForFinish()

        let seeded = try XCTUnwrap(try recordedRequests(requestsURL)
            .last { $0["method"] as? String == "session/prompt" }?["text"] as? String)
        XCTAssertTrue(seeded.contains("history-149-marker"), "the newest prior message must reach the new session")
        XCTAssertTrue(seeded.contains("(earlier messages omitted)"))
        XCTAssertFalse(seeded.contains("history-0-marker "), "the budget is spent on the newest messages")
        XCTAssertEqual(events.noticeSummaries,
                       [DistillACPAdapter.modelFamilySwitchNotice + DistillACPAdapter.handoffCarriedNoticeSuffix])
    }

    func test_switchThatFailsBeforeAcceptanceKeepsOldCursorAndRetriesWithHandoff() async throws {
        // WHY: if Stop (or a set_mode failure) ends the switch turn before Distill
        // accepts the seeded prompt, persisting the new session's id would make
        // the next send resume an empty session with no handoff. The cursor must
        // stay on the old session so the retry is again a switch with handoff.
        let root = try makeTempRoot("distill-acp-switch-pre-accept")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let thread = AgentThreadID()

        let first = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: thread, model: "muse-spark-1.3-contributor", prompt: "First request", root: root)
        ) { first.append($0) }
        _ = try await first.waitForFinish()

        var stopOnce = true
        adapter.beforePromptWriteForTesting = { [weak adapter] in
            guard stopOnce else { return }
            stopOnce = false
            try? adapter?.stopSession(threadId: thread)
        }
        var switchRequest = distillRequest(thread: thread, model: "claude/claude-opus-5-5", prompt: "Switch request",
                                           root: root, providerThreadId: "distill-session-1")
        switchRequest.priorProviderSessionModel = "muse-spark-1.3-contributor"
        switchRequest.priorConversationTail = [
            AgentMessage(threadId: thread, role: .user, content: "First request"),
            AgentMessage(threadId: thread, role: .assistant, content: "reply from distill-session-1")
        ]
        let aborted = DistillACPAdapterEventBox()
        do {
            _ = try await adapter.sendTurn(switchRequest) { aborted.append($0) }
            XCTFail("the stopped switch turn must fail")
        } catch {}
        XCTAssertTrue(try recordedRequests(requestsURL).contains {
            $0["method"] as? String == "session/new" && $0["sessionId"] as? String == "distill-session-2"
        }, "precondition: the replacement session was opened and announced commands")
        XCTAssertFalse(aborted.threadStartedIds.contains("distill-session-2"),
                       "an unseeded session must not become the persisted resume cursor")
        XCTAssertTrue(aborted.acceptedSessionModels.isEmpty, "nothing was accepted, so nothing may be recorded")

        let retried = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(switchRequest) { retried.append($0) }
        let finished = try await retried.waitForFinish()
        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.providerThreadId, "distill-session-3")
        XCTAssertTrue(retried.threadStartedIds.contains("distill-session-3"))
        let requests = try recordedRequests(requestsURL)
        XCTAssertFalse(requests.contains { $0["method"] as? String == "session/load" })
        let seeded = try XCTUnwrap(requests.last { $0["method"] as? String == "session/prompt" }?["text"] as? String)
        XCTAssertTrue(seeded.contains("[RemoteCode context handoff]") && seeded.contains("User: First request"),
                      "the retry must carry the conversation the failed attempt never delivered")
        XCTAssertEqual(retried.noticeSummaries,
                       [DistillACPAdapter.modelFamilySwitchNotice + DistillACPAdapter.handoffCarriedNoticeSuffix])
    }

    func test_persistedRetirementOpensNewSessionAfterRestart() async throws {
        // WHY: the in-memory retirement set is empty after a restart; the
        // coordinator's persisted flag must still keep Retry off `session/load`.
        let root = try makeTempRoot("distill-acp-retired-restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeFailureHarness(root: root)
        let restarted = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { restarted.stopAll() }
        var request = distillRequest(thread: AgentThreadID(), model: "claude/claude-opus-5-5", prompt: "Retry request",
                                     root: root, providerThreadId: "rejected-session")
        request.priorProviderSessionModel = "claude/claude-opus-5-5"
        request.priorProviderSessionRetired = true
        let events = DistillACPAdapterEventBox()
        _ = try await restarted.sendTurn(request) { events.append($0) }
        let finished = try await events.waitForFinish()
        XCTAssertEqual(finished.status, .completed)
        XCTAssertNotEqual(finished.providerThreadId, "rejected-session")
        XCTAssertFalse(try recordedRequests(requestsURL).contains { $0["method"] as? String == "session/load" })
        XCTAssertEqual(events.noticeSummaries,
                       [DistillACPAdapter.incompatibleHistoryNotice + DistillACPAdapter.handoffMissingNoticeSuffix])
    }

    func test_failedTurnKeepsItsSessionWarm_retryRunsInTheSameProcess() async throws {
        // WHY (S-F3 review): a TERM right after the turn skips Distill's session
        // shutdown, which flushes the records `session/load` replays. Killing a
        // failed turn's process made Retry reload a session that could miss the
        // failed prompt and the tool calls it already ran. The failed session
        // stays resident (listed as failed) so Retry runs warm; the idle reaper
        // releases it once it has been idle past idleReleaseAge.
        let root = try makeTempRoot("distill-acp-failed-warm")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }

        let thread = AgentThreadID()
        let failed = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: thread, model: "claude/claude-opus-5-5", prompt: "FAIL_DATA", root: root)
        ) { failed.append($0) }
        let failedFinished = try await failed.waitForFinish()
        XCTAssertEqual(failedFinished.status, .failed)
        XCTAssertTrue(adapter.hasSession(threadId: thread),
                      "a failed turn must not kill its process: Retry needs the warm session and its unflushed context")
        XCTAssertEqual(adapter.listSessions().first { $0.threadId == thread }?.status, .failed,
                       "the reaper finds the failed session by its adapter status and releases it after idle")

        let retry = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            distillRequest(thread: thread, model: "claude/claude-opus-5-5", prompt: "Retry request", root: root,
                           providerThreadId: failedFinished.providerThreadId)
        ) { retry.append($0) }
        let retried = try await retry.waitForFinish()
        XCTAssertEqual(retried.status, .completed)
        XCTAssertEqual(retried.providerThreadId, failedFinished.providerThreadId)
        let requests = try recordedRequests(requestsURL)
        XCTAssertFalse(requests.contains { $0["method"] as? String == "session/load" },
                       "Retry must reuse the live process, not reload the session in a new one")
        XCTAssertEqual(requests.filter { $0["method"] as? String == "session/prompt" }.count, 2)
    }

    func test_turnWatchdogKeepsOneTimerPerTurnAcrossAStreamBurst() async throws {
        // WHY: field 2026-10-14 — every streamed event scheduled a fresh 900 s
        // `asyncAfter` work item; cancelled ones stay queued in libdispatch until
        // their deadline, so one long distill run held ~12k live timers (~7 MB)
        // for 15 minutes. A burst must move one deadline, not queue a timer each.
        let root = try makeTempRoot("distill-acp-watchdog-burst")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }

        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: AgentThreadID(), model: "claude/claude-opus-5-5", prompt: "BURST_HANG", root: root)
        ) { events.append($0) }
        let deadline = Date().addingTimeInterval(10)
        while events.assistantText.count < 2_000, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(events.assistantText.count, 2_000, "every burst chunk must stream")
        // Exactly one: zero would mean the turn lost its inactivity bound.
        XCTAssertEqual(adapter.turnWatchdogTimersScheduledForTesting, 1,
                       "2,000 events must reuse one inactivity timer")
    }

    func test_turnInactivityWatchdogFailsAQuietTurnDespitePartialText() async throws {
        // WHY: when session/prompt never returns, the inactivity watchdog is the
        // only thing that ends the turn and releases Working. The burst test only
        // counts timers; this pins that stream events really arm the single
        // deadline, that a burst never trips it, and that quiet fires it once.
        let root = try makeTempRoot("distill-acp-watchdog-fires")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(
            binaryNameOverride: harness.path,
            cancellationGracePeriod: 0.05,
            turnInactivityTimeout: 1
        )
        defer { adapter.stopAll() }

        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: AgentThreadID(), model: "claude/claude-opus-5-5", prompt: "BURST_HANG", root: root)
        ) { events.append($0) }
        let finished = try await events.waitForFinish(timeout: 15)
        XCTAssertEqual(events.assistantText.count, 2_000,
                       "the window must not fire while the burst is still streaming")
        XCTAssertEqual(finished.status, .failed,
                       "partial text and silence cannot substitute for the provider's completion")
        XCTAssertTrue(events.hasWatchdogSynthesizedMarker,
                      "only the inactivity watchdog can end a turn whose prompt never returns")
        XCTAssertEqual(adapter.turnWatchdogTimersScheduledForTesting, 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(events.finishedCount, 1, "the watchdog must terminate the turn exactly once")
    }

    func test_turnWatchdogWaitsForAnOpenToolInsteadOfInterruptingIt() async throws {
        // WHY: a blocking tool wait (e.g. get_command_or_subagent_output with a long
        // timeout_ms) emits nothing while it runs. That silence is healthy, so the
        // watchdog must not end the turn as interrupted while the tool is open.
        let root = try makeTempRoot("distill-acp-watchdog-open-tool")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(
            binaryNameOverride: harness.path,
            cancellationGracePeriod: 0.05,
            turnInactivityTimeout: 1
        )
        defer { adapter.stopAll() }

        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: AgentThreadID(), model: "claude/claude-opus-5-5", prompt: "TOOL_HANG", root: root)
        ) { events.append($0) }

        let finished = try await events.waitForFinish(timeout: 15)
        XCTAssertEqual(finished.status, .completed,
                       "a healthy open tool call must finish through session/prompt, not be interrupted")
        XCTAssertFalse(events.hasWatchdogSynthesizedMarker,
                       "the watchdog must not synthesize a terminal while the tool is open and recent")
    }

    func test_turnWatchdogStillInterruptsAnOpenToolPastTheQuietLimit() async throws {
        // WHY: the open-tool allowance is bounded. A tool that stays silent past the
        // quiet limit is treated as stuck and must still be released as interrupted.
        let root = try makeTempRoot("distill-acp-watchdog-open-tool-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeFailureHarness(root: root)
        let adapter = DistillACPAdapter(
            binaryNameOverride: harness.path,
            cancellationGracePeriod: 0.05,
            turnInactivityTimeout: 1,
            openToolQuietLimit: 0.5
        )
        defer { adapter.stopAll() }

        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            distillRequest(thread: AgentThreadID(), model: "claude/claude-opus-5-5", prompt: "TOOL_HANG", root: root)
        ) { events.append($0) }

        let finished = try await events.waitForFinish(timeout: 15)
        XCTAssertEqual(finished.status, .interrupted,
                       "an open tool silent past the quiet limit must be released as interrupted")
        XCTAssertTrue(events.hasWatchdogSynthesizedMarker,
                      "only the watchdog can end a turn whose tool stays silent past the limit")
    }

    func test_historyRetentionGrowsWithItsEventsInsteadOfPreallocatingTheWindow() {
        // WHY: every resident session reserved the whole 5,121-slot window up
        // front (~750 KB of AssistantEvent storage) even for a one-message
        // thread. Small sessions must stay small; a full window must not grow
        // past the old reservation (the plain doubling would reach 8,192 slots).
        var history = DistillACPHistoryRetention()
        let window = AgentRunCoordinator.hotReplayEventCount + DistillACPHistoryRetention.eventPruneSlack + 1
        for index in 0..<10 {
            history.append(.itemDelta(itemId: "a", bodyAppend: "\(index)", outputAppend: nil, summary: nil))
        }
        XCTAssertLessThanOrEqual(history.storageCapacityForTesting, 64, "ten events must not pin the whole window")
        var reserved: [AssistantEvent] = []
        reserved.reserveCapacity(window)
        var peakCapacity = 0
        for index in 10..<(window * 3) {
            history.append(.itemDelta(itemId: "a", bodyAppend: "\(index)", outputAppend: nil, summary: nil))
            peakCapacity = max(peakCapacity, history.storageCapacityForTesting)
        }
        XCTAssertLessThanOrEqual(peakCapacity, reserved.capacity, "a full window must not outgrow the old reservation")
        XCTAssertEqual(history.retainedEventCount, AgentRunCoordinator.hotReplayEventCount)
    }

    func test_modelFamilyIsDerivedFromDistillClaudePrefix() {
        XCTAssertTrue(DistillACPAdapter.isCrossModelFamilySwitch(from: "muse-spark-1.3-contributor", to: "claude/claude-opus-5-5"))
        XCTAssertTrue(DistillACPAdapter.isCrossModelFamilySwitch(from: "claude/claude-opus-5-5", to: "gpt-6-luna"))
        XCTAssertFalse(DistillACPAdapter.isCrossModelFamilySwitch(from: "claude/claude-sonnet-5", to: "claude/claude-opus-5-5"))
        XCTAssertFalse(DistillACPAdapter.isCrossModelFamilySwitch(from: "gpt-6-luna", to: "grok-4.6"))
        XCTAssertFalse(DistillACPAdapter.isCrossModelFamilySwitch(from: nil, to: "claude/claude-opus-5-5"),
                       "an unknown previous model must keep the existing resume behavior")
    }
}

private final class DistillACPAdapterEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentRunEvent] = []

    func append(_ event: AgentRunEvent) {
        lock.lock(); defer { lock.unlock() }
        values.append(event)
    }

    var errors: [String] {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event in
            guard case .error(let message) = event else { return nil }
            return message
        }
    }

    var noticeSummaries: [String] {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event in
            guard case .event(.itemStarted(let item)) = event, item.type == .contextCompaction else { return nil }
            return item.summary
        }
    }

    var contextCompactionSummaries: [String?] {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event in
            guard case .event(.contextCompaction(let summary)) = event else { return nil }
            return .some(summary)
        }
    }

    var threadStartedIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event in
            guard case .event(.threadStarted(_, let providerThreadId)) = event else { return nil }
            return providerThreadId
        }
    }

    private var sessionStates: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event in
            guard case .event(.providerRuntime(let runtime)) = event,
                  runtime.method == ProviderRuntimeEvent.distillSessionStateMethod,
                  let data = runtime.payloadJSON.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    var acceptedSessionModels: [(sessionId: String, model: String)] {
        sessionStates.compactMap { state in
            guard let id = state["sessionId"] as? String, let model = state["acceptedModel"] as? String else { return nil }
            return (id, model)
        }
    }

    var rejectedSessionIds: [String] {
        sessionStates.compactMap { state in
            state["historyRejected"] as? Bool == true ? state["sessionId"] as? String : nil
        }
    }

    var assistantText: String {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event in
            guard case .event(.itemDelta(_, let body, _, _)) = event else { return nil }
            return body
        }.joined()
    }

    var finishedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return values.filter {
            if case .finished = $0 { return true }
            return false
        }.count
    }

    var hasWatchdogSynthesizedMarker: Bool {
        lock.lock(); defer { lock.unlock() }
        return values.contains {
            if case .event(.providerRuntime(let runtime)) = $0 {
                return runtime.method == "grok.turn.watchdog.synthesized"
            }
            return false
        }
    }

    private func finishResult() -> (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)? {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event -> (AgentRunStatus, String?, String?)? in
            guard case .finished(let status, let finalMessage, let providerThreadId) = event else { return nil }
            return (status, finalMessage, providerThreadId)
        }.first
    }

    func waitForFinish(timeout: TimeInterval = 5) async throws -> (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = finishResult() { return result }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw DistillACPAdapterTestError.timedOut
    }
}

private enum DistillACPAdapterTestError: Error {
    case timedOut
}
