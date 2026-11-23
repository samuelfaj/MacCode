import XCTest
import CoreModel
@testable import SocketServer
@testable import AppShell
@testable import Persistence

/// WHY: the paired iPhone marks Activity items viewed and acknowledges them
/// (agent.activity.viewed.set / agent.activity.acknowledge). The dispatcher
/// runs on the main actor and these writes ran there through
/// `db.performSync`, which waits for the database lock; while a run or a
/// scheduled task held a write transaction, every MacCode window froze until
/// it committed. The main thread must stay free while the write waits.
@MainActor
final class ActivityWriteRPCOffMainTests: XCTestCase {
    func test_activityWriteRPCsLeaveTheMainThreadFreeWhileTheDatabaseIsBusy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ActivityWriteOffMain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let thread = AgentThread(workspaceId: nil, title: "done", provider: .codex, model: "m")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .failed, startedAt: Date(), finishedAt: Date())
        try ctx.runRepo.upsert(run)
        let itemID = "run:\(run.id.description)"
        let dispatcher = JSONRPCDispatcher(router: router)

        // Same results as before: the item is viewed, then acknowledged.
        let requests: [(String, [String: JSONValue], (JSONValue?) -> Bool)] = [
            ("agent.activity.viewed.set", ["item_ids": .array([.string(itemID)]), "viewed": .bool(true)],
             { $0?.objectValue?["updated_ids"]?.arrayValue == [.string(itemID)] }),
            ("agent.activity.acknowledge", ["item_id": .string(itemID)],
             { $0?.objectValue?["acknowledged"] == .bool(true) && $0?.objectValue?["item_id"] == .string(itemID) }),
        ]
        for (index, (method, params, expected)) in requests.enumerated() {
            // Another writer (a streaming run) holds the database for 0.6 s.
            let writerHolds = expectation(description: "writer holds the lock")
            let db = ctx.db
            Thread.detachNewThread {
                try? db.transaction {
                    writerHolds.fulfill()
                    Thread.sleep(forTimeInterval: 0.6)
                }
            }
            await fulfillment(of: [writerHolds], timeout: 2)

            var mainTurnAt: Date?
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { mainTurnAt = Date() }
            let response = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(index), method: method, params: params
            ))
            let answeredAt = Date()
            XCTAssertNil(response.error, "\(method) failed: \(String(describing: response.error))")
            XCTAssertTrue(expected(response.result), "\(method) answered \(String(describing: response.result))")
            let mainRan = try XCTUnwrap(mainTurnAt, "\(method) held the main thread until the database was free")
            XCTAssertLessThan(mainRan, answeredAt, "\(method) must leave the main thread free while it waits")
        }

    }
}
