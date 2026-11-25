import XCTest
import GitTestSupport
@testable import AgentRuntime
import CoreModel
import Persistence

final class RunFileTouchTrackerTests: XCTestCase {
    private func makeStore() throws -> (SQLiteDB, AgentRunFileTouchRepository) {
        let path = NSTemporaryDirectory() + "rc2-tracker-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: path).run()
        return (db, AgentRunFileTouchRepository(db: db))
    }

    private func makeRun(_ db: SQLiteDB) throws -> AgentRun {
        let thread = AgentThread(title: "t", provider: .distill, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .distill, model: "m", status: .running)
        try AgentRunRepository(db: db).upsert(run)
        return run
    }

    func test_worktreesOfOneRepoShareTheCommonDirButNotTheCheckout() throws {
        let repo = try GitRepoFixture()
        try repo.commit(file: "a.swift")
        defer { repo.cleanup() }
        let worktree = NSTemporaryDirectory() + "rc2-wt-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        _ = repo.shell(["git", "-C", repo.path, "worktree", "add", "-q", "-b", "feature", worktree])

        let main = try XCTUnwrap(GitDiff.repoIdentity(in: repo.path))
        let linked = try XCTUnwrap(GitDiff.repoIdentity(in: worktree))
        XCTAssertEqual(main.gitCommonDir, linked.gitCommonDir, "same_repo and ConcurrentWorkIndex rely on one common dir per repository")
        XCTAssertNotEqual(main.repoRoot, linked.repoRoot)
        XCTAssertEqual(main.branch, "main")
        XCTAssertEqual(linked.branch, "feature")
        XCTAssertEqual(linked.repoRoot, URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path)

        let sub = repo.path + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        XCTAssertEqual(GitDiff.repoIdentity(in: sub), main, "a subdirectory resolves to the same checkout")
        XCTAssertNil(GitDiff.repoIdentity(in: NSTemporaryDirectory()), "outside git there is no identity")
    }

    func test_identityIsResolvedOnceAndTouchesAreStoredRelativeToTheRepoRoot() async throws {
        let (db, store) = try makeStore()
        let run = try makeRun(db)
        let calls = LockedCounter()
        let tracker = RunFileTouchTracker(store: store) { cwd in
            calls.increment()
            return RunRepoIdentity(repoRoot: "/work/app", gitCommonDir: "/work/app/.git", branch: "main")
        }
        tracker.begin(runId: run.id, threadId: run.threadId, cwd: "/work/app/pkg")
        tracker.begin(runId: run.id, threadId: run.threadId, cwd: "/work/app/pkg")
        tracker.record(runId: run.id, touches: [
            ProviderFileTouch(path: "/work/app/pkg/a.swift", kind: .edit),
            ProviderFileTouch(path: "/elsewhere/outside.txt", kind: .edit),
            ProviderFileTouch(path: "rel.swift", kind: .write),
        ])
        let completed = await tracker.complete(runId: run.id)
        let result = try XCTUnwrap(completed)
        XCTAssertEqual(calls.value, 1, "the repo identity is resolved once per run, not per tool call")
        XCTAssertEqual(result.touchedPaths, ["pkg/a.swift", "pkg/rel.swift"], "paths outside the checkout are dropped; relative paths resolve against the cwd")
        XCTAssertEqual(try store.identity(runId: run.id)?.gitCommonDir, "/work/app/.git")
        let again = await tracker.complete(runId: run.id)
        XCTAssertNil(again, "completing frees the run")
    }

    func test_recordedBatchIsReportedAfterItIsStoredWithRepoRelativePaths() async throws {
        let (db, store) = try makeStore()
        let run = try makeRun(db)
        let seen = LockedBatches()
        let tracker = RunFileTouchTracker(store: store) { _ in RunRepoIdentity(repoRoot: "/work/app", gitCommonDir: "/work/app/.git", branch: nil) }
        tracker.onRecorded = { runId, threadId, identity, paths in
            // The other run's notice depends on this run's touches already being readable.
            seen.append((runId, threadId, identity.repoRoot, paths, (try? store.touches(runId: runId).map(\.path)) ?? []))
        }
        tracker.begin(runId: run.id, threadId: run.threadId, cwd: "/work/app/pkg")
        tracker.record(runId: run.id, touches: [ProviderFileTouch(path: "/work/app/pkg/a.swift", kind: .edit), ProviderFileTouch(path: "/elsewhere/x", kind: .edit)])
        _ = await tracker.complete(runId: run.id)
        let batch = try XCTUnwrap(seen.values.first)
        XCTAssertEqual(batch.0, run.id)
        XCTAssertEqual(batch.2, "/work/app")
        XCTAssertEqual(batch.3, ["pkg/a.swift"])
        XCTAssertEqual(batch.4, ["pkg/a.swift"], "stored before reported")
    }

    func test_runOutsideGitHasNoIdentityAndRecordsNothing() async throws {
        let (db, store) = try makeStore()
        let run = try makeRun(db)
        let tracker = RunFileTouchTracker(store: store) { _ in nil }
        tracker.begin(runId: run.id, threadId: run.threadId, cwd: "/tmp/not-git")
        tracker.record(runId: run.id, touches: [ProviderFileTouch(path: "/tmp/not-git/a", kind: .edit)])
        let result = await tracker.complete(runId: run.id)
        XCTAssertNil(result, "no repo identity means the checkpoint keeps today's behavior")
        XCTAssertEqual(try store.touches(runId: run.id), [])
    }

    func test_recordForAnUnknownRunIsIgnored() async throws {
        let (db, store) = try makeStore()
        let run = try makeRun(db)
        let tracker = RunFileTouchTracker(store: store) { _ in RunRepoIdentity(repoRoot: "/r", gitCommonDir: "/r/.git", branch: nil) }
        tracker.record(runId: run.id, touches: [ProviderFileTouch(path: "/r/a", kind: .edit)])
        let result = await tracker.complete(runId: run.id)
        XCTAssertNil(result)
        XCTAssertEqual(try store.touches(runId: run.id), [])
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class LockedBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(AgentRunID, AgentThreadID, String, [String], [String])] = []
    func append(_ item: (AgentRunID, AgentThreadID, String, [String], [String])) { lock.lock(); items.append(item); lock.unlock() }
    var values: [(AgentRunID, AgentThreadID, String, [String], [String])] { lock.lock(); defer { lock.unlock() }; return items }
}
