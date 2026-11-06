import Foundation
import XCTest
import CoreModel
@testable import AgentRuntime

/// Fork/side provider contract tests against the fake ACP harness: deterministic
/// child id from the coordinator idempotency key, the exact `_x.ai/session/fork`
/// wire method and params, and idempotent `_x.ai/session/delete` compensation.
/// The harness answers "Method not found" to an extension method without the
/// ACP `_` prefix, exactly like Distill 2.0.42 (the bug that broke every fork).
final class DistillACPForkTests: ProviderProcessTestCase {
    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-acp-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// WHY: same coordinator idempotency key must always map to the same child session id, so a
    /// retried fork converges instead of creating a second orphan session.
    func test_deterministicChildId_isStableAndDistinct() {
        let a = DistillACPAdapter.deterministicForkChildId(idempotencyKey: "remotecode-thread-fork:child-1")
        let again = DistillACPAdapter.deterministicForkChildId(idempotencyKey: "remotecode-thread-fork:child-1")
        let b = DistillACPAdapter.deterministicForkChildId(idempotencyKey: "remotecode-thread-fork:child-2")
        XCTAssertEqual(a, again)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 36, "must be a plain UUID string Distill accepts as a session id")
        // Version-5 marker nibble.
        XCTAssertEqual(Array(a)[14], "5")
    }

    func test_forkSafety_advertisesDurableForkOnceCompensationIsReal() {
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/distill-agent")
        XCTAssertTrue(adapter.forkSafety.supportsDurableFork)
        XCTAssertTrue(adapter.forkSafety(threadId: AgentThreadID()).supportsDurableFork)
    }

    func test_forkThread_sendsDeterministicNewSessionId_andReturnsChild() async throws {
        let root = try makeRoot("fork")
        defer { try? FileManager.default.removeItem(at: root) }
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            with requests.open("a") as output: output.write(json.dumps({"method":method,"params":params}) + "\\n")
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True}}})
            elif method == "session/new":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"sessionId":"sess-src","models":{"currentModelId":"m1"}}})
            elif method == "session/prompt":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"stopReason":"end_turn"}})
            elif method in ("session/set_mode", "session/set_config_option"):
                send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
            elif method == "_x.ai/session/fork":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"newSessionId":params.get("newSessionId")}})
            elif method == "_x.ai/session/delete":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"success":True}})
            elif method == "_x.ai/btw":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"result":{"answer":"4."}}})
            elif "id" in message:
                # Real Distill: extension methods without the ACP "_" prefix are unknown.
                send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32601,"message":"Method not found"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        let adapter = DistillACPAdapter(binaryNameOverride: harnessURL.path)
        defer { adapter.stopAll() }

        let sourceThreadId = AgentThreadID()
        _ = try await adapter.startSession(
            AgentRunRequest(threadId: sourceThreadId, provider: .distill, model: "m1", cwd: root.path, prompt: "Go")
        ) { _ in }

        let childThreadId = AgentThreadID()
        let key = "remotecode-thread-fork:\(childThreadId.value.uuidString.lowercased())"
        let expectedChild = DistillACPAdapter.deterministicForkChildId(idempotencyKey: key)
        let child = try await adapter.forkThread(AgentProviderForkRequest(
            sourceThreadId: sourceThreadId,
            childThreadId: childThreadId,
            idempotencyKey: key,
            workingDirectory: root.path,
            sourceProviderThreadId: "sess-src"
        ))
        XCTAssertEqual(child, expectedChild)

        let forks = try requests(requestsURL).filter { $0.method == "_x.ai/session/fork" }
        let params = try XCTUnwrap(forks.last?.params)
        XCTAssertEqual(params["sourceSessionId"] as? String, "sess-src")
        XCTAssertEqual(params["newSessionId"] as? String, expectedChild)
        XCTAssertEqual(params["sessionKind"] as? String, "fork")

        // WHY: the header side chat button is Distill /side; the message branch button is /fork.
        let sideThreadId = AgentThreadID()
        _ = try await adapter.forkThread(AgentProviderForkRequest(
            sourceThreadId: sourceThreadId,
            childThreadId: sideThreadId,
            idempotencyKey: "remotecode-thread-fork:\(sideThreadId.value.uuidString.lowercased())",
            workingDirectory: root.path,
            sourceProviderThreadId: "sess-src",
            isSide: true
        ))
        let sideParams = try XCTUnwrap(try requests(requestsURL).filter { $0.method == "_x.ai/session/fork" }.last?.params)
        XCTAssertEqual(sideParams["sessionKind"] as? String, "side")

        // Compensation is idempotent and issues the provider delete.
        try await adapter.compensateFork(AgentProviderForkRequest(
            sourceThreadId: sourceThreadId,
            childThreadId: childThreadId,
            idempotencyKey: key,
            workingDirectory: root.path,
            sourceProviderThreadId: "sess-src"
        ), providerChildThreadId: child)
        let deletes = try requests(requestsURL).filter { $0.method == "_x.ai/session/delete" }
        XCTAssertEqual((deletes.last?.params)?["sessionId"] as? String, child)
    }

    private func writeHarness(_ root: URL, forkError: Bool = false) throws -> (harness: URL, requests: URL) {
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let forkReply = forkError
            ? #"send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32602,"message":"Invalid params","data":"missing session"}})"#
            : #"send({"jsonrpc":"2.0", "id":message["id"], "result":{"newSessionId":params.get("newSessionId")}})"#
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys, os
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            with requests.open("a") as output: output.write(json.dumps({"method":method,"params":params,"cwd":os.getcwd()}) + "\\n")
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True}}})
            elif method == "_x.ai/session/fork":
                \(forkReply)
            elif "id" in message:
                send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32601,"message":"Method not found"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        return (harnessURL, requestsURL)
    }

    /// WHY: a thread not used since RemoteCode launched has no live Distill
    /// session. Distill forks the saved session from disk, so the fork must
    /// still work, opened in the source session's own folder.
    func test_forkWithoutALiveSessionForksTheSavedSessionInItsOwnFolder() async throws {
        let root = try makeRoot("cold-fork")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionFolder = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        let (harness, requestsURL) = try writeHarness(root)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let key = "remotecode-thread-fork:\(UUID().uuidString.lowercased())"
        let child = try await adapter.forkThread(AgentProviderForkRequest(
            sourceThreadId: AgentThreadID(),
            childThreadId: AgentThreadID(),
            idempotencyKey: key,
            sourceProviderThreadId: "sess-saved",
            sourceWorkingDirectory: sessionFolder.path
        ))
        XCTAssertEqual(child, DistillACPAdapter.deterministicForkChildId(idempotencyKey: key))
        let fork = try XCTUnwrap(try requests(requestsURL).last { $0.method == "_x.ai/session/fork" })
        XCTAssertEqual(fork.params["sourceSessionId"] as? String, "sess-saved")
        XCTAssertEqual(fork.params["sourceCwd"] as? String, sessionFolder.path)
    }

    /// WHY: when Distill refuses the fork (bad params, unknown method) nothing
    /// was created, so the coordinator may retire the intent; any other error
    /// must stay recoverable.
    func test_aRefusedForkIsReportedAsRejected() async throws {
        let root = try makeRoot("rejected-fork")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeHarness(root, forkError: true)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        do {
            _ = try await adapter.forkThread(AgentProviderForkRequest(
                sourceThreadId: AgentThreadID(),
                childThreadId: AgentThreadID(),
                idempotencyKey: "remotecode-thread-fork:x",
                sourceProviderThreadId: "sess-saved",
                sourceWorkingDirectory: root.path
            ))
            XCTFail("a refused fork must throw")
        } catch AgentProviderAdapterError.forkRejected {
        } catch {
            XCTFail("expected forkRejected, got \(error)")
        }
    }

    /// WHY: the ACP extension methods must carry the `_` prefix on the wire, or
    /// Distill answers "Method not found" (fork, delete and /btw were all broken).
    func test_distillExtensionMethodsUseTheACPUnderscorePrefix() {
        XCTAssertEqual(DistillACPClient.sessionForkMethod, "_x.ai/session/fork")
        XCTAssertEqual(DistillACPClient.sessionDeleteMethod, "_x.ai/session/delete")
        XCTAssertEqual(DistillACPClient.btwMethod, "_x.ai/btw")
    }

    private struct Recorded { let method: String; let params: [String: Any] }
    private func requests(_ url: URL) throws -> [Recorded] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Recorded? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let method = object["method"] as? String else { return nil }
                return Recorded(method: method, params: object["params"] as? [String: Any] ?? [:])
            }
    }
}
