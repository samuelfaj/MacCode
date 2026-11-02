import XCTest
@testable import AppShell
@testable import CoreModel
@testable import Persistence
@testable import SocketServer

/// C3 wiring in the app: the Agent App read gateway (message pages, thread
/// list, queued messages, pending callbacks) runs on AppContext's WAL reader,
/// and LocalAuthAdapter request auth is served from the principal cache while
/// a revoke still locks the device out on its next request.
@MainActor
final class HostConnectionReadPathTests: XCTestCase {
    private func makeContext() throws -> AppContext {
        let dir = NSTemporaryDirectory() + "RC2HostReadPath-" + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return try AppContext(channel: .debug, appSupportOverride: dir)
    }

    private func holdWriter(_ writer: SQLiteDB) -> (release: DispatchSemaphore, done: DispatchSemaphore) {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            writer.performSync { db in
                try? db.execute("BEGIN IMMEDIATE;")
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                try? db.execute("COMMIT;")
            }
            done.signal()
        }
        started.wait()
        return (release, done)
    }

    func test_appContextUsesASeparateWALReader() throws {
        let context = try makeContext()
        XCTAssertFalse(context.readDB === context.db,
                       "file-backed hosts must give paired-device reads their own connection")
    }

    func test_messagePageAndThreadList_readWhileWriterHeld() async throws {
        let context = try makeContext()
        let thread = AgentThread(title: "paged", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        for index in 0..<30 {
            try context.messageRepo.append(AgentMessage(
                threadId: thread.id,
                role: .user,
                content: "message \(index)",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index))
            ))
        }
        let gateway = AgentAppReadGateway(db: context.db, readDB: context.readDB)
        let expected = try context.messageRepo.listPage(threadId: thread.id, limit: 10, before: nil, after: nil)

        let held = holdWriter(context.db)
        let t0 = DispatchTime.now()
        let page = try await gateway.listMessagesPage(threadId: thread.id, limit: 10, before: nil, after: nil)
        let threads = try await gateway.listThreads(workspaceId: nil)
        let locked = try await gateway.threadIdsWithMessages()
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000
        held.release.signal()
        held.done.wait()

        XCTAssertLessThan(ms, 250, "paired-device reads must not wait for the writer transaction (took \(ms) ms)")
        XCTAssertEqual(page.messages.map(\.id), expected.messages.map(\.id))
        XCTAssertEqual(threads.map(\.id), [thread.id])
        XCTAssertEqual(locked, [thread.id])
    }

    /// WHY: the gateway queue is serial and the paired device's snapshot waits on it.
    /// A refresh its caller already replaced must not run and delay that snapshot.
    func test_readCancelledWhileQueued_isSkipped() async throws {
        let context = try makeContext()
        try context.threadRepo.upsert(AgentThread(title: "queued", provider: .codex, model: "m"))
        let gateway = AgentAppReadGateway(db: context.db, readDB: context.readDB)
        AgentAppReadGateway.resetExecutionProbesForTesting()
        defer { AgentAppReadGateway.resetExecutionProbesForTesting() }
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        AgentAppReadGateway.readWillRunForTesting = {
            AgentAppReadGateway.readWillRunForTesting = nil
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 5)
        }

        let blocker = Task { try await gateway.listThreads(workspaceId: nil) }
        await Task.detached { firstStarted.wait() }.value
        let superseded = Task { try await gateway.listThreads(workspaceId: nil) }
        try await Task.sleep(nanoseconds: 50_000_000)
        superseded.cancel()
        releaseFirst.signal()

        _ = try await blocker.value
        do {
            _ = try await superseded.value
            XCTFail("a read cancelled while queued must not return a result")
        } catch is CancellationError {}
        let next = try await gateway.listThreads(workspaceId: nil)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(AgentAppReadGateway.readSkippedCancelledCountForTesting, 1)
        XCTAssertEqual(AgentAppReadGateway.readCallCountForTesting, 2, "only the blocker and the next read ran")
    }

    /// WHY: the HTTP auth cache and Settings' revoke live on different
    /// repository instances. A revoked iPhone must get 401 on its next request.
    func test_adapterCacheHit_thenRevokeFromSettingsRepository_refusesNextRequest() throws {
        let context = try makeContext()
        let authRepo = DeviceTrustRepository(db: context.db)
        let auth = LocalAuthAdapter(repo: authRepo)
        let code = try authRepo.createPairingCode()
        let paired = try XCTUnwrap(try authRepo.redeemPairingCode(code.code, deviceName: "iPhone"))

        XCTAssertNotNil(auth.authorizedRPCPrincipal(token: paired.token))
        XCTAssertTrue(auth.verify(token: paired.token))
        XCTAssertEqual(auth.authorizedOwnerFingerprint(token: paired.token),
                       auth.authorizedRPCPrincipal(token: paired.token)?.ownerFingerprint)
        XCTAssertGreaterThanOrEqual(authRepo.principalCacheHitCountForTesting, 3)

        try DeviceTrustRepository(db: context.db).revoke(id: paired.0.id)

        XCTAssertNil(auth.authorizedRPCPrincipal(token: paired.token))
        XCTAssertFalse(auth.verify(token: paired.token))
        XCTAssertNil(auth.authorizedOwnerFingerprint(token: paired.token))
    }

    func test_adapterRevokeDevice_refusesNextRequest() throws {
        let context = try makeContext()
        let auth = LocalAuthAdapter(repo: DeviceTrustRepository(db: context.db))
        let code = try XCTUnwrap(auth.createPairingCode())
        let paired = try XCTUnwrap(auth.redeemPairingCode(code, deviceName: "iPhone"))
        XCTAssertTrue(auth.verify(token: paired.token))
        XCTAssertTrue(auth.verify(token: paired.token))
        auth.revokeDevice(paired.deviceId)
        XCTAssertFalse(auth.verify(token: paired.token))
    }
}
