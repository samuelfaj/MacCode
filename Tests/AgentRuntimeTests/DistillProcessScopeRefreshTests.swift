import XCTest
@testable import AgentRuntime
@testable import CoreModel
@testable import Persistence

/// WHY: every send carries a fresh delegation capability, so a Distill thread
/// whose session is still live always changes provider process scope on its
/// next turn. The coordinator refuses that turn ("Provider process scope
/// changed before a durable provider thread id was available") when it has no
/// cursor to reopen the session in the new process. A real Distill thread must
/// never hit that refusal: a session only lives in the adapter after Distill
/// answered session/new or session/load with a non-empty sessionId, and the
/// coordinator takes the cursor from the live session when the thread row has
/// none (a Stop before acceptance, a failed cursor write). If that ever breaks,
/// every follow-up send on the thread fails until the session is released.
final class DistillProcessScopeRefreshTests: ProviderProcessTestCase {
    func test_liveSessionWithoutDurableCursor_reopensInTheNewScopeInsteadOfRefusing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harness = try writeHarness(root: root, requestsURL: requestsURL)

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "scope refresh", provider: .distill, model: "main")
        try threadRepo.upsert(thread)
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            // A live runtime issues a fresh delegation capability per send, as in the app.
            orchestrationRuntime: AgentOrchestrationRuntime(
                repository: AgentOrchestrationRepository(db: db),
                packageVerification: { false },
                killSwitch: { true }
            ),
            providerAdapters: [.distill: adapter]
        )

        let first = request(thread: thread, cwd: root.path, prompt: "first")
        _ = try await coordinator.startRun(first)
        try await waitUntil { (try? runRepo.status(of: first.runId)) == .completed }
        XCTAssertTrue(adapter.hasSession(threadId: thread.id), "Distill keeps the thread's session live between turns")

        // The thread row and session row lose the cursor while Distill's session stays live.
        try threadRepo.updateProviderThreadId(id: thread.id, providerThreadId: nil)
        try providerSessionRepo.clearResumeCursor(threadId: thread.id)

        let second = request(thread: thread, cwd: root.path, prompt: "second")
        do {
            _ = try await coordinator.startRun(second)
        } catch {
            XCTFail("a live Distill session must supply the cursor for the new scope, got \(error)")
            return
        }
        try await waitUntil { (try? runRepo.status(of: second.runId)) == .completed }
        let records = records(requestsURL)
        XCTAssertEqual(
            records.filter { $0["method"] as? String == "initialize" }.count, 2,
            "the changed scope must restart the Distill process"
        )
        XCTAssertEqual(
            records.filter { $0["method"] as? String == "session/load" }.compactMap { $0["sessionId"] as? String },
            ["scope-session"],
            "the new process must reopen the same Distill session, not lose the conversation"
        )
        XCTAssertEqual(records.filter { $0["method"] as? String == "session/prompt" }.count, 2)
        XCTAssertEqual(try threadRepo.providerThreadId(of: thread.id), "scope-session")
    }

    private func request(thread: AgentThread, cwd: String, prompt: String) -> AgentRunRequest {
        AgentRunRequest(threadId: thread.id, provider: .distill, model: "main", cwd: cwd, prompt: prompt)
    }

    private func writeHarness(root: URL, requestsURL: URL) throws -> URL {
        let harnessURL = root.appendingPathComponent("distill-agent")
        let script = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        def send(value): print(json.dumps(value), flush=True)
        models = {"currentModelId":"main","availableModels":[{"modelId":"main","name":"Main"}]}
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            with requests.open("a") as output:
                output.write(json.dumps({"method":method, "sessionId":params.get("sessionId")}) + "\\n")
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True}}})
            elif method == "session/new":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"sessionId":"scope-session","models":models}})
            elif method == "session/load":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"models":models}})
            elif method == "session/prompt":
                send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"scope-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}})
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"stopReason":"end_turn"}})
            elif method == "_x.ai/session/execution_mode/set":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"mode":params.get("mode")}})
            elif "id" in message:
                send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
        """
        try script.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        return harnessURL
    }

    private func records(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
