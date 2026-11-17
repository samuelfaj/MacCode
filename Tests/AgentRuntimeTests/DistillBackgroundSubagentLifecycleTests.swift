import XCTest
@testable import AgentRuntime
@testable import CoreModel
@testable import Persistence

/// WHY (2026-11-17): a Distill turn ended while six background subagents kept
/// running. The Subagents rows turned "Unknown" in the same second, the 45 s
/// background-await nudge then started a new run, the new run restarted the
/// Distill process (every send carries a fresh delegation capability), and the
/// restart killed the subagents. Distill reported them `cancelled`, but that
/// report arrived after the turn and was dropped, so they stayed "Unknown".
final class DistillBackgroundSubagentLifecycleTests: ProviderProcessTestCase {
    private struct Harness {
        let root: URL
        let thread: AgentThread
        let runRepo: AgentRunRepository
        let runtime: AgentOrchestrationRuntime
        let adapter: DistillACPAdapter
        let coordinator: AgentRunCoordinator
    }

    func test_backgroundSubagentStaysWorkingAfterItsTurnAndEndsWithDistillsReport() async throws {
        let harness = try makeHarness()
        defer { dispose(harness) }
        let child = UUID()
        try plan(harness, spawn: [child], text: "Started a background helper.")

        let first = request(harness, prompt: "start a helper")
        _ = try await harness.coordinator.startRun(first)
        try await waitUntil { (try? harness.runRepo.status(of: first.runId)) == .completed }

        // The badge's persisting reconciliation must not demote a running child.
        _ = try harness.runtime.activityReceipts(threadIds: [harness.thread.id], persistLifecycleReconciliation: true)
        XCTAssertEqual(try receipt(harness, child).lifecycleStatus, .accepted, "a subagent Distill still runs is Working, not Unknown")
        XCTAssertTrue(harness.adapter.isNativeSubagentRunning(threadId: harness.thread.id, childRunId: AgentRunID(child)))
        XCTAssertEqual(
            harness.adapter.listSessions().first?.toolsMayStillRun, true,
            "the idle-session reaper must not release a process that runs a subagent"
        )

        try finish(harness, child, status: "completed")
        let ended = try await waitForReceipt(harness, child) { $0.lifecycleStatus == .finalized }
        XCTAssertEqual(ended.finalRunStatus, .completed, "Distill's report after the turn reaches the ledger")
        XCTAssertFalse(harness.adapter.isNativeSubagentRunning(threadId: harness.thread.id, childRunId: AgentRunID(child)))
    }

    func test_subagentKilledByAProcessRestartEndsCancelledInsteadOfUnknown() async throws {
        let harness = try makeHarness()
        defer { dispose(harness) }
        let child = UUID()
        try plan(harness, spawn: [child], text: "Started a background helper.")
        let first = request(harness, prompt: "start a helper")
        _ = try await harness.coordinator.startRun(first)
        try await waitUntil { (try? harness.runRepo.status(of: first.runId)) == .completed }

        // A user send restarts the process; the new one reports the child cancelled while loading.
        let second = request(harness, prompt: "how is it going?")
        _ = try await harness.coordinator.startRun(second)
        try await waitUntil { (try? harness.runRepo.status(of: second.runId)) == .completed }
        XCTAssertEqual(records(harness).filter { $0["method"] as? String == "session/load" }.count, 1)

        let ended = try await waitForReceipt(harness, child) { $0.lifecycleStatus == .finalized }
        XCTAssertEqual(ended.finalRunStatus, .cancelled, "the restart's real outcome, not Unknown")
    }

    func test_autoContinuationWaitsForBackgroundSubagentsInsteadOfRestartingDistill() async throws {
        let harness = try makeHarness(quietPeriod: 0.3)
        defer { dispose(harness) }
        harness.coordinator.backgroundAwaitContinuationDelay = 0.05
        harness.coordinator.backgroundWorkRecheckInterval = 0.05
        let child = UUID()
        try plan(harness, spawn: [child], text: "[[RC_AWAITING]]\n\nWaiting for the helper to finish.")

        let first = request(harness, prompt: "start a helper", permission: .fullAccess)
        _ = try await harness.coordinator.startRun(first)
        try await waitUntil { (try? harness.runRepo.status(of: first.runId)) == .completed }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(count(harness, "initialize"), 1, "the nudge must not restart Distill while its subagent runs")
        XCTAssertEqual(count(harness, "session/prompt"), 1)
        XCTAssertEqual(try receipt(harness, child).lifecycleStatus, .accepted)

        try finish(harness, child, status: "completed")
        try await waitUntil { self.count(harness, "session/prompt") == 2 }
        XCTAssertEqual(
            try receipt(harness, child).finalRunStatus, .completed,
            "the subagent ended on its own before the nudge ran"
        )
    }

    func test_subagentSpawnedAfterTheTurnEndedJoinsThatTurn() async throws {
        // WHY: a background workflow spawns its next phase after the turn ended.
        let harness = try makeHarness()
        defer { dispose(harness) }
        let first = request(harness, prompt: "run the workflow")
        _ = try await harness.coordinator.startRun(first)
        try await waitUntil { (try? harness.runRepo.status(of: first.runId)) == .completed }

        let child = UUID()
        try trigger(harness, "spawn-\(child.uuidString.lowercased())", "")
        let spawned = try await waitForReceipt(harness, child) { $0.lifecycleStatus == .accepted }
        let parent = try XCTUnwrap(harness.runtime.receipt(runId: first.runId))
        XCTAssertEqual(spawned.parentReceiptId, parent.id)
        XCTAssertEqual(spawned.provider, .distill)

        try finish(harness, child, status: "failed")
        let ended = try await waitForReceipt(harness, child) { $0.lifecycleStatus == .finalized }
        XCTAssertEqual(ended.finalRunStatus, .failed, "a failed helper never counts as done")
    }

    // MARK: - Harness

    private func makeHarness(quietPeriod: TimeInterval = 0) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let agent = try writeAgent(root: root)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "background subagents", provider: .distill, model: "main")
        try threadRepo.upsert(thread)
        let runtime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: db),
            packageVerification: { false },
            killSwitch: { true }
        )
        let adapter = DistillACPAdapter(binaryNameOverride: agent.path, backgroundWorkQuietPeriod: quietPeriod)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providerSessionRepo: ProviderSessionRuntimeRepository(db: db),
            orchestrationRuntime: runtime,
            providerAdapters: [.distill: adapter]
        )
        return Harness(root: root, thread: thread, runRepo: runRepo, runtime: runtime, adapter: adapter, coordinator: coordinator)
    }

    private func dispose(_ harness: Harness) {
        harness.adapter.stopAll()
        try? FileManager.default.removeItem(at: harness.root)
    }

    private func request(_ harness: Harness, prompt: String, permission: AgentPermissionMode = .supervised) -> AgentRunRequest {
        AgentRunRequest(
            threadId: harness.thread.id,
            provider: .distill,
            model: "main",
            cwd: harness.root.path,
            prompt: prompt,
            permissionMode: permission
        )
    }

    private func plan(_ harness: Harness, spawn: [UUID], text: String) throws {
        let plan: [String: Any] = ["spawn": spawn.map { $0.uuidString.lowercased() }, "text": text]
        try JSONSerialization.data(withJSONObject: plan)
            .write(to: harness.root.appendingPathComponent("next-prompt.json"))
    }

    private func finish(_ harness: Harness, _ child: UUID, status: String) throws {
        try trigger(harness, "finish-\(child.uuidString.lowercased())", status)
    }

    private func trigger(_ harness: Harness, _ name: String, _ contents: String) throws {
        let staging = harness.root.appendingPathComponent(".\(name)")
        try contents.write(to: staging, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: staging, to: harness.root.appendingPathComponent(name))
    }

    private func receipt(_ harness: Harness, _ child: UUID) throws -> AgentOrchestrationAdmissionReceipt {
        try XCTUnwrap(harness.runtime.receipt(runId: AgentRunID(child)))
    }

    private func waitForReceipt(
        _ harness: Harness,
        _ child: UUID,
        timeout: TimeInterval = 15,
        _ condition: @escaping (AgentOrchestrationAdmissionReceipt) -> Bool
    ) async throws -> AgentOrchestrationAdmissionReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let receipt = try harness.runtime.receipt(runId: AgentRunID(child)), condition(receipt) {
                return receipt
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let last = try harness.runtime.receipt(runId: AgentRunID(child))
        XCTFail("timed out; last receipt state: \(String(describing: last?.lifecycleStatus)) \(String(describing: last?.finalRunStatus))")
        throw CancellationError()
    }

    private func records(_ harness: Harness) -> [[String: Any]] {
        let url = harness.root.appendingPathComponent("requests.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func count(_ harness: Harness, _ method: String) -> Int {
        records(harness).filter { $0["method"] as? String == method }.count
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Distill-shaped ACP agent: subagents run in the agent process, keep
    /// reporting after the turn ends, and a new process reports the ones its
    /// predecessor was running as cancelled while it loads the session.
    private func writeAgent(root: URL) throws -> URL {
        let url = root.appendingPathComponent("distill-agent")
        let script = """
        #!/usr/bin/env python3
        import json, pathlib, sys, threading, time
        root = pathlib.Path(\(String(reflecting: root.path)))
        requests = root / "requests.jsonl"
        running = root / "running.txt"
        lock = threading.Lock()
        SESSION = "bg-session"
        models = {"currentModelId":"main","availableModels":[{"modelId":"main","name":"Main"}]}
        def send(value):
            with lock:
                sys.stdout.write(json.dumps(value) + "\\n")
                sys.stdout.flush()
        def notify(update):
            send({"jsonrpc":"2.0","method":"x.ai/session_notification","params":{"sessionId":SESSION,"update":update}})
        def running_children():
            return [c for c in running.read_text().split() if c] if running.exists() else []
        def set_running(children):
            running.write_text("\\n".join(children))
        def subagent(kind, child, **extra):
            update = {"sessionUpdate":kind,"subagent_id":child,"child_session_id":child}
            update.update(extra)
            return update
        def watch():
            while True:
                for trigger in sorted(root.glob("spawn-*")):
                    child = trigger.name[len("spawn-"):]
                    trigger.unlink()
                    set_running(running_children() + [child])
                    notify(subagent("subagent_spawned", child, subagent_type="general-purpose", description="review"))
                for trigger in sorted(root.glob("finish-*")):
                    child = trigger.name[len("finish-"):]
                    status = trigger.read_text().strip() or "completed"
                    trigger.unlink()
                    set_running([c for c in running_children() if c != child])
                    notify(subagent("subagent_finished", child, status=status))
                time.sleep(0.02)
        threading.Thread(target=watch, daemon=True).start()
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            with lock:
                with requests.open("a") as out:
                    out.write(json.dumps({"method":method, "sessionId":params.get("sessionId")}) + "\\n")
            if method == "initialize":
                send({"jsonrpc":"2.0","id":message["id"],"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True}}})
            elif method == "session/new":
                send({"jsonrpc":"2.0","id":message["id"],"result":{"sessionId":SESSION,"models":models}})
            elif method == "session/load":
                for child in running_children():
                    notify(subagent("subagent_finished", child, status="cancelled", error="interrupted by process restart"))
                set_running([])
                send({"jsonrpc":"2.0","id":message["id"],"result":{"models":models}})
            elif method == "session/prompt":
                plan_file = root / "next-prompt.json"
                plan = json.loads(plan_file.read_text()) if plan_file.exists() else {}
                if plan_file.exists():
                    plan_file.unlink()
                for child in plan.get("spawn", []):
                    set_running(running_children() + [child])
                    notify(subagent("subagent_spawned", child, subagent_type="general-purpose", description="impl"))
                text = plan.get("text", "done")
                send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":SESSION,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}})
                send({"jsonrpc":"2.0","id":message["id"],"result":{"stopReason":"end_turn"}})
            elif method == "_x.ai/session/execution_mode/set":
                send({"jsonrpc":"2.0","id":message["id"],"result":{"mode":params.get("mode")}})
            elif "id" in message:
                send({"jsonrpc":"2.0","id":message["id"],"result":{}})
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
