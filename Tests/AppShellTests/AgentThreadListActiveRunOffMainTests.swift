import XCTest
import AgentRuntime
import CoreModel
import Persistence
@testable import SocketServer
@testable import AppShell

/// WHY: agent.thread.list (the iPhone thread list) is answered by the
/// main-actor dispatcher. Its batch encoder read each thread's active run
/// with `activeAgentRun`, which for every idle thread ran a SQLite
/// `latestActiveChrome` query on the main thread, waiting on the database
/// lock behind any streaming write. With hundreds of threads that is one
/// main-thread query per thread per list. The lookup must run off-main and
/// still report exactly the same active run per thread.
@MainActor
final class AgentThreadListActiveRunOffMainTests: XCTestCase {
    func test_threadListReadsActiveRunsOffMainWithTheSameResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ThreadListActiveRun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "list", cwd: root.path)

        var idle: [AgentThread] = []
        for index in 0..<20 {
            let thread = AgentThread(workspaceId: workspace.id, title: "idle \(index)", provider: .codex, model: "m")
            try ctx.threadRepo.upsert(thread)
            idle.append(thread)
        }
        // A run this process does not track in memory (LaunchAgent-owned or
        // left over): only the durable agent_runs row knows it.
        let durable = AgentThread(workspaceId: workspace.id, title: "durable", provider: .codex, model: "m")
        try ctx.threadRepo.upsert(durable)
        let durableRun = AgentRun(threadId: durable.id, provider: .codex, model: "m", status: .running)
        try ctx.runRepo.upsert(durableRun)
        let finished = AgentRun(threadId: idle[0].id, provider: .codex, model: "m", status: .completed)
        try ctx.runRepo.upsert(finished)

        let dispatcher = JSONRPCDispatcher(router: router)
        ctx.coordinator.durableActiveRunThreadProbeForTesting.reset()
        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "agent.thread.list",
            params: ["workspace_id": .string(workspace.id.value.uuidString)]
        ))

        XCTAssertEqual(
            ctx.coordinator.durableActiveRunThreadProbeForTesting.mainThreadCallCount,
            0,
            "agent.thread.list must not query the durable active run on the main thread"
        )
        XCTAssertGreaterThan(
            ctx.coordinator.durableActiveRunThreadProbeForTesting.backgroundCallCount,
            0,
            "the durable active run must still be consulted, off-main"
        )

        guard case .array(let rows)? = response.result else { return XCTFail("agent.thread.list must return an array") }
        XCTAssertEqual(rows.count, 21)
        var byID: [String: [String: JSONValue]] = [:]
        for row in rows {
            guard let object = row.objectValue, let id = object["id"]?.objectValue?["value"]?.stringValue ?? object["id"]?.stringValue else {
                return XCTFail("thread row without id: \(row)")
            }
            byID[id] = object
        }
        let durableRow = try XCTUnwrap(byID[durable.id.value.uuidString])
        XCTAssertEqual(durableRow["active_run_id"], .string(durableRun.id.value.uuidString),
                       "a durable running row is still advertised so the phone shows the run")
        XCTAssertEqual(durableRow["status"], .string(AgentRunStatus.running.rawValue))
        if case .number(let startedMs)? = durableRow["active_run_started_at_ms"] {
            XCTAssertEqual(startedMs, Double(Int64(durableRun.startedAt.timeIntervalSince1970 * 1_000)), accuracy: 1_000)
        } else {
            XCTFail("active_run_started_at_ms must be a number for an active run")
        }
        for thread in idle {
            let row = try XCTUnwrap(byID[thread.id.value.uuidString])
            XCTAssertEqual(row["active_run_id"], .null, "idle thread \(thread.title) has no active run")
            XCTAssertEqual(row["active_run_started_at_ms"], .null)
        }
    }
}
