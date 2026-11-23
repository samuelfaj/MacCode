import XCTest
import CoreModel
@testable import SocketServer
@testable import AppShell

/// WHY: the JSON-RPC dispatcher runs on the main actor. The git.* RPCs the
/// paired iPhone sends (Git view, thread header summary, push/pull buttons)
/// ran git synchronously there, so every git child process (five for one
/// git.status, up to 60 s each for reads, no deadline at all for push/pull)
/// froze every MacCode window until git exited. End to end through the real
/// router: while git is still running, the main thread must stay free, and
/// mutations must still run one at a time with their retry receipts intact.
@MainActor
final class GitRemoteRPCOffMainTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var originalPath: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2GitRPCOffMain-\(UUID().uuidString)", isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [repo!, remote, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Self.git(["init", "-q", "--bare", "-b", "main"], in: remote)
        try Self.git(["init", "-q", "-b", "main"], in: repo)
        try Self.git(["config", "user.email", "t@t.t"], in: repo)
        try Self.git(["config", "user.name", "t"], in: repo)
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Self.git(["add", "a.txt"], in: repo)
        try Self.git(["commit", "-q", "-m", "seed"], in: repo)
        try Self.git(["remote", "add", "origin", remote.path], in: repo)
        try Self.git(["push", "-q", "-u", "origin", "main"], in: repo)

        // A slow git (a large repo, a cold disk, a remote): every call the
        // RPCs make through `/usr/bin/env git` takes at least 0.3 s.
        let slowGit = bin.appendingPathComponent("git")
        try "#!/bin/sh\nsleep 0.3\nexec /usr/bin/git \"$@\"\n".write(to: slowGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowGit.path)
        originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(bin.path):\(originalPath!)", 1)
    }

    override func tearDown() async throws {
        setenv("PATH", originalPath, 1)
        try? FileManager.default.removeItem(at: root)
    }

    func test_gitRPCsLeaveTheMainThreadFreeWhileGitRuns() async throws {
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (ctx, dispatcher, workspaceID) = try makeDispatcher()
        _ = ctx

        let requests: [(String, [String: JSONValue])] = [
            ("git.status", ["workspace_id": workspaceID]),
            ("git.branches", ["workspace_id": workspaceID]),
            ("git.log", ["workspace_id": workspaceID, "limit": .number(5)]),
            ("git.diff", ["workspace_id": workspaceID]),
            ("git.pull_request_url", ["workspace_id": workspaceID]),
            ("git.delivery_plan", ["workspace_id": workspaceID]),
            ("git.create_branch", ["workspace_id": workspaceID, "name": .string("side")]),
            ("git.checkout", ["workspace_id": workspaceID, "branch": .string("main")]),
            ("git.commit", ["workspace_id": workspaceID, "message": .string("from the phone")]),
            ("git.fetch", ["workspace_id": workspaceID]),
            ("git.pull", ["workspace_id": workspaceID]),
            ("git.push", ["workspace_id": workspaceID]),
            ("git.deliver", ["workspace_id": workspaceID]),
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
        XCTAssertEqual(try Self.gitOutput(["rev-parse", "origin/main"], in: repo), try Self.gitOutput(["rev-parse", "main"], in: repo),
                       "git.push reached the remote")

        let missing = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(102), method: "git.status", params: ["workspace_id": .string(UUID().uuidString)]
        ))
        XCTAssertNotNil(missing.error, "an unknown workspace is still an error")
    }

    /// A client that times out and retries a slow commit with the same
    /// client_request_id must get the first commit's receipt, not a second
    /// run (which would report "nothing to commit" for a commit that landed).
    /// The retry arrives on another dispatcher: the Unix socket and HTTP
    /// servers each own one over the same router.
    func test_retriedCommitWhileTheFirstRunsReturnsItsReceiptAndCommitsOnce() async throws {
        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nsleep 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let (ctx, dispatcher, workspaceID) = try makeDispatcher()
        let otherDispatcher = JSONRPCDispatcher(router: try XCTUnwrap(ctx.router))
        let params: [String: JSONValue] = [
            "workspace_id": workspaceID,
            "message": .string("retried"),
            "client_request_id": .string("commit-\(UUID().uuidString)"),
        ]

        async let first = dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "git.commit", params: params))
        try await Task.sleep(nanoseconds: 300_000_000)
        async let retry = otherDispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "git.commit", params: params))
        let (firstResponse, retryResponse) = await (first, retry)

        XCTAssertEqual(firstResponse.result?.objectValue?["ok"], .bool(true))
        XCTAssertEqual(retryResponse.result, firstResponse.result, "the retry replays the first commit's receipt")
        XCTAssertEqual(try Self.gitOutput(["rev-list", "--count", "HEAD"], in: repo), "2", "exactly one new commit")
    }

    private func makeDispatcher() throws -> (AppContext, JSONRPCDispatcher, JSONValue) {
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "git-rpc", cwd: repo.path)
        return (ctx, JSONRPCDispatcher(router: router), .string(workspace.id.value.uuidString))
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        _ = try gitOutput(arguments, in: directory)
    }

    private static func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
