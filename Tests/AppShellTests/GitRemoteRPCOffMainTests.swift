import XCTest
import CoreModel
@testable import SocketServer
@testable import AppShell

/// WHY: the JSON-RPC dispatcher runs on the main actor. The git.* RPCs the
/// paired iPhone sends (Git view, thread header summary, push/pull buttons)
/// ran git synchronously there, so every git child process (five for one
/// git.status, up to 60 s each for reads, no deadline at all for push/pull)
/// froze every MacCode window until git exited. End to end through the real
/// router: while git is still running, the main thread must stay free.
@MainActor
final class GitRemoteRPCOffMainTests: XCTestCase {
    func test_gitRPCsLeaveTheMainThreadFreeWhileGitRuns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2GitRPCOffMain-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.git(["init", "-q", "-b", "main"], in: repo)
        try Self.git(["config", "user.email", "t@t.t"], in: repo)
        try Self.git(["config", "user.name", "t"], in: repo)
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "a.txt"], in: repo)
        try Self.git(["commit", "-q", "-m", "seed"], in: repo)
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // A slow git (a large repo, a cold disk, a remote): every call the
        // RPCs make through `/usr/bin/env git` takes at least 0.3 s.
        let slowGit = bin.appendingPathComponent("git")
        try "#!/bin/sh\nsleep 0.3\nexec /usr/bin/git \"$@\"\n".write(to: slowGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowGit.path)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(bin.path):\(originalPath)", 1)
        defer { setenv("PATH", originalPath, 1) }

        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "git-rpc", cwd: repo.path)
        let dispatcher = JSONRPCDispatcher(router: router)
        let workspaceID = JSONValue.string(workspace.id.value.uuidString)

        let requests: [(String, [String: JSONValue])] = [
            ("git.status", ["workspace_id": workspaceID]),
            ("git.branches", ["workspace_id": workspaceID]),
            ("git.log", ["workspace_id": workspaceID, "limit": .number(5)]),
            ("git.diff", ["workspace_id": workspaceID]),
            ("git.fetch", ["workspace_id": workspaceID]),
            ("git.commit", ["workspace_id": workspaceID, "message": .string("from the phone")]),
        ]
        for (index, (method, params)) in requests.enumerated() {
            var mainTurnAt: Date?
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { mainTurnAt = Date() }
            let response = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(index), method: method, params: params
            ))
            let finished = Date()
            XCTAssertNil(response.error, "\(method) must still answer")
            let turn = try XCTUnwrap(
                mainTurnAt,
                "\(method) held the main thread until git exited"
            )
            XCTAssertLessThan(
                turn.timeIntervalSince1970, finished.timeIntervalSince1970 - 0.1,
                "\(method): the main thread must run while git is still running"
            )
        }

        // Same results as before: the work moved threads, not semantics.
        let status = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(100), method: "git.status", params: ["workspace_id": workspaceID]
        ))
        XCTAssertEqual(status.result?.objectValue?["dirty"], .bool(false), "the commit above took the edit")
        let log = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(101), method: "git.log", params: ["workspace_id": workspaceID, "limit": .number(5)]
        ))
        guard case .array(let commits)? = log.result else { return XCTFail("git.log must return an array") }
        XCTAssertEqual(commits.count, 2)

        let missing = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(102), method: "git.status", params: ["workspace_id": .string(UUID().uuidString)]
        ))
        XCTAssertNotNil(missing.error, "an unknown workspace is still an error")
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
