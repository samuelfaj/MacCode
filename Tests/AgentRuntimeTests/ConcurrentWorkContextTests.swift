import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Each agent must learn at turn start who else works in its repository, hear once about files that
/// changed under it, and be warned (not blocked) when its request repeats earlier work.
final class ConcurrentWorkContextTests: XCTestCase {
    private let identity = RunRepoIdentity(repoRoot: "/work/app", gitCommonDir: "/work/app/.git", branch: "main")

    private struct Fixture {
        let db: SQLiteDB
        let touches: AgentRunFileTouchRepository
        let context: ConcurrentWorkContext
    }

    private func makeFixture(resolve: ConcurrentWorkContext.IdentityResolver? = nil) throws -> Fixture {
        let db = try Bootstrap(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "cw-ctx-" + UUID().uuidString).run().1
        let id = identity
        let context = ConcurrentWorkContext(db: db, resolveIdentity: resolve ?? { _ in id })
        return Fixture(db: db, touches: AgentRunFileTouchRepository(db: db), context: context)
    }

    @discardableResult
    private func liveRun(_ f: Fixture, title: String, request: String? = nil, files: [String] = [], identity: RunRepoIdentity? = nil) throws -> AgentRun {
        let thread = AgentThread(title: title, provider: .distill, model: "m")
        try AgentThreadRepository(db: f.db).upsert(thread)
        if let request { try AgentMessageRepository(db: f.db).append(AgentMessage(threadId: thread.id, role: .user, content: request)) }
        let run = AgentRun(threadId: thread.id, provider: .distill, model: "m", status: .running)
        try AgentRunRepository(db: f.db).upsert(run)
        let id = identity ?? self.identity
        try f.touches.saveIdentity(runId: run.id, threadId: thread.id, identity: id)
        if !files.isEmpty {
            try f.touches.recordTouches(runId: run.id, threadId: thread.id, repoRoot: id.repoRoot, touches: files.map { ProviderFileTouch(path: $0, kind: .edit) })
        }
        return run
    }

    private func newThread(_ f: Fixture) throws -> AgentThread {
        let thread = AgentThread(title: "New", provider: .distill, model: "m")
        try AgentThreadRepository(db: f.db).upsert(thread)
        return thread
    }

    func test_blockListsOtherLiveRunsInTheRepoOnlyAndNothingWhenAlone() async throws {
        let f = try makeFixture()
        let mine = try newThread(f)
        let alone = await f.context.turnContext(threadId: mine.id, runId: AgentRunID(), cwd: "/work/app", request: "x")
        XCTAssertNil(alone.block)

        try liveRun(f, title: "Fix login", files: ["Sources/Auth.swift"])
        try liveRun(f, title: "Elsewhere", files: ["z"], identity: RunRepoIdentity(repoRoot: "/other", gitCommonDir: "/other/.git", branch: nil))
        let context = await f.context.turnContext(threadId: mine.id, runId: AgentRunID(), cwd: "/work/app", request: "x")
        let block = try XCTUnwrap(context.block)
        XCTAssertTrue(block.contains("thread 'Fix login'") && block.contains("`Sources/Auth.swift`"), block)
        XCTAssertFalse(block.contains("Elsewhere"), "a run in another repository is not concurrent work")
    }

    func test_noGitCheckoutMeansNoBlock() async throws {
        let f = try makeFixture { _ in nil }
        try liveRun(f, title: "Fix login", files: ["a"])
        let context = await f.context.turnContext(threadId: try newThread(f).id, runId: AgentRunID(), cwd: "/tmp/plain", request: "x")
        XCTAssertNil(context.block)
    }

    func test_fileAnotherRunStartsEditingReachesTheRunThatTouchedItOnceAtItsNextTurn() async throws {
        let f = try makeFixture()
        let first = try liveRun(f, title: "Refactor auth", files: ["Sources/Auth.swift"])
        let second = try liveRun(f, title: "Fix login", files: ["Sources/Auth.swift"])
        f.context.runEdited(runId: second.id, threadId: second.threadId, identity: identity, paths: ["Sources/Auth.swift", "Sources/Unshared.swift"])

        let next = await f.context.turnContext(threadId: first.threadId, runId: AgentRunID(), cwd: "/work/app", request: "continue")
        let block = try XCTUnwrap(next.block)
        XCTAssertTrue(block.contains("`Sources/Auth.swift` was also edited by thread 'Fix login'"), block)
        XCTAssertFalse(block.contains("Unshared"), "only files this run touched are worth a notice")
        let again = await f.context.turnContext(threadId: first.threadId, runId: AgentRunID(), cwd: "/work/app", request: "continue")
        XCTAssertTrue(try XCTUnwrap(again.block).contains("was also edited"), "a turn that never starts keeps its notices")

        f.context.commit(next, threadId: first.threadId)
        f.context.runEdited(runId: second.id, threadId: second.threadId, identity: identity, paths: ["Sources/Auth.swift"])
        let after = await f.context.turnContext(threadId: first.threadId, runId: AgentRunID(), cwd: "/work/app", request: "continue")
        XCTAssertFalse((after.block ?? "").contains("was also edited"), "a delivered notice is not repeated when the other run edits the file again")

        let editor = await f.context.turnContext(threadId: second.threadId, runId: AgentRunID(), cwd: "/work/app", request: "continue")
        XCTAssertFalse((editor.block ?? "").contains("was also edited"), "the editing run is not told about its own edit")
    }

    func test_sameRelativePathInAnotherWorktreeIsNotAConflict() async throws {
        let f = try makeFixture()
        let first = try liveRun(f, title: "Main checkout", files: ["Sources/Auth.swift"])
        let wtIdentity = RunRepoIdentity(repoRoot: "/work/app-wt", gitCommonDir: "/work/app/.git", branch: "feat")
        let linked = try liveRun(f, title: "Linked worktree", files: ["Sources/Auth.swift"], identity: wtIdentity)
        f.context.runEdited(runId: linked.id, threadId: linked.threadId, identity: wtIdentity, paths: ["Sources/Auth.swift"])
        let next = await f.context.turnContext(threadId: first.threadId, runId: AgentRunID(), cwd: "/work/app", request: "go")
        XCTAssertFalse((next.block ?? "").contains("was also edited"))
        XCTAssertTrue((next.block ?? "").contains("worktree /work/app-wt"), "the run is still listed, with its own worktree")
    }

    func test_noticesExpireAfterADay() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000_000))
        let db = try Bootstrap(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "cw-ctx-" + UUID().uuidString).run().1
        let id = identity
        let context = ConcurrentWorkContext(db: db, resolveIdentity: { _ in id }, now: { clock.value })
        let f = Fixture(db: db, touches: AgentRunFileTouchRepository(db: db), context: context)
        let first = try liveRun(f, title: "A", files: ["f"])
        let second = try liveRun(f, title: "B", files: ["f"])
        context.runEdited(runId: second.id, threadId: second.threadId, identity: identity, paths: ["f"])
        clock.value = clock.value.addingTimeInterval(ConcurrentWorkContext.noticeLifetime + 60)
        let next = await context.turnContext(threadId: first.threadId, runId: AgentRunID(), cwd: "/work/app", request: "go")
        XCTAssertFalse((next.block ?? "").contains("was also edited"))
    }

    func test_firstRunOfAThreadGetsSimilarWorkAndLaterRunsDoNot() async throws {
        let f = try makeFixture()
        try liveRun(f, title: "Fix login redirect bug", request: "Fix the login redirect bug in the auth service")
        let thread = try newThread(f)
        let first = await f.context.turnContext(threadId: thread.id, runId: AgentRunID(), cwd: "/work/app", request: "Please fix the login redirect bug in the auth service")
        XCTAssertEqual(first.similar.count, 1)
        XCTAssertTrue(try XCTUnwrap(first.block).contains("Check it first; do not redo it"))

        try AgentRunRepository(db: f.db).upsert(AgentRun(threadId: thread.id, provider: .distill, model: "m", status: .completed))
        let later = await f.context.turnContext(threadId: thread.id, runId: AgentRunID(), cwd: "/work/app", request: "Please fix the login redirect bug in the auth service")
        XCTAssertEqual(later.similar, [], "the check runs at the start of a thread, not on every follow-up")
    }

    func test_appendingKeepsExistingTurnContextFirst() {
        XCTAssertEqual(ConcurrentWorkContext.appending("B", to: "A"), "A\n\nB")
        XCTAssertEqual(ConcurrentWorkContext.appending("B", to: nil), "B")
        XCTAssertEqual(ConcurrentWorkContext.appending(nil, to: "A"), "A")
        XCTAssertEqual(ConcurrentWorkContext.appending("B", to: "  "), "B")
    }

    func test_aRetriedRequestReplacesItsEarlierBlockInsteadOfDoublingIt() {
        let stale = "BOT\n\n<concurrent_work>\nold\n</concurrent_work>"
        XCTAssertEqual(ConcurrentWorkContext.appending("<concurrent_work>\nnew\n</concurrent_work>", to: stale), "BOT\n\n<concurrent_work>\nnew\n</concurrent_work>")
        XCTAssertEqual(ConcurrentWorkContext.appending(nil, to: stale), "BOT", "nothing to tell now means the stale block goes away")
        XCTAssertNil(ConcurrentWorkContext.appending(nil, to: "<concurrent_work>\nold\n</concurrent_work>"))
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return date }
        set { lock.lock(); date = newValue; lock.unlock() }
    }
}
