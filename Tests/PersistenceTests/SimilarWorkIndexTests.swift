import XCTest
import CoreModel
@testable import Persistence

/// Duplicate work is only worth a warning when the other run is live or fresh and in the same repo,
/// workspace or Bot; everything else is noise or a privacy leak across contexts.
final class SimilarWorkIndexTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let commonDir = "/work/app/.git"

    private func makeDB() throws -> SQLiteDB {
        try Bootstrap(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "similar-" + UUID().uuidString).run().1
    }

    @discardableResult
    private func makeRun(
        _ db: SQLiteDB, title: String = "Fix login redirect bug", request: String? = "Fix the login redirect bug in the auth service",
        status: AgentRunStatus = .completed, finishedAgo: TimeInterval = 3600, repo: String? = nil, workspace: WorkspaceID? = nil,
        reply: String? = "Fixed the redirect in AuthController."
    ) throws -> AgentRun {
        let thread = AgentThread(workspaceId: workspace, title: title, provider: .distill, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let messages = AgentMessageRepository(db: db)
        if let request { try messages.append(AgentMessage(threadId: thread.id, role: .user, content: request)) }
        if let reply { try messages.append(AgentMessage(threadId: thread.id, role: .assistant, content: reply)) }
        let terminal = status != .running && status != .pending
        let run = AgentRun(threadId: thread.id, provider: .distill, model: "m", status: status,
                           startedAt: now.addingTimeInterval(-finishedAgo - 60), finishedAt: terminal ? now.addingTimeInterval(-finishedAgo) : nil)
        try AgentRunRepository(db: db).upsert(run)
        if let repo {
            try AgentRunFileTouchRepository(db: db).saveIdentity(runId: run.id, threadId: thread.id, identity: RunRepoIdentity(repoRoot: "/work/app", gitCommonDir: repo, branch: "main"))
            try AgentRunFileTouchRepository(db: db).recordTouches(runId: run.id, threadId: thread.id, repoRoot: "/work/app", touches: [ProviderFileTouch(path: "Sources/Auth.swift", kind: .edit)])
        }
        return run
    }

    private func find(_ index: SimilarWorkIndex, _ request: String = "Please fix the login redirect bug in the auth service", excluding: AgentThreadID? = nil, repo: String? = nil, workspace: String? = nil, bot: String? = nil) throws -> [SimilarWork] {
        try index.find(request: request, excludingThread: excluding, repoCommonDir: repo, workspaceID: workspace, botID: bot, now: now)
    }

    func test_finishedRunInTheSameRepoCarriesFilesAndResultSummary() throws {
        let db = try makeDB()
        let done = try makeRun(db, repo: commonDir)
        let found = try find(SimilarWorkIndex(db: db), repo: commonDir)
        XCTAssertEqual(found.map(\.threadID), [done.threadId])
        XCTAssertEqual(found.first?.files, ["Sources/Auth.swift"])
        XCTAssertEqual(found.first?.resultSummary, "Fixed the redirect in AuthController.")
        XCTAssertEqual(found.first?.isRunning, false)
    }

    func test_runsFinishedMoreThanADayAgoOrNotCompletedAreIgnored() throws {
        let db = try makeDB()
        try makeRun(db, finishedAgo: 25 * 3600, repo: commonDir)
        try makeRun(db, status: .failed, repo: commonDir)
        try makeRun(db, status: .cancelled, repo: commonDir)
        XCTAssertEqual(try find(SimilarWorkIndex(db: db), repo: commonDir), [])
        try makeRun(db, finishedAgo: 23 * 3600, repo: commonDir)
        XCTAssertEqual(try find(SimilarWorkIndex(db: db), repo: commonDir).count, 1)
    }

    func test_liveRunMatchesButARunningRowTheHostNoLongerOwnsDoesNot() throws {
        let db = try makeDB()
        let live = try makeRun(db, status: .running, repo: commonDir, reply: nil)
        let stale = try makeRun(db, status: .running, repo: commonDir, reply: nil)
        let index = SimilarWorkIndex(db: db, liveRunIDs: { [live.id] })
        let found = try find(index, repo: commonDir)
        XCTAssertEqual(found.map(\.threadID), [live.threadId])
        XCTAssertEqual(found.first?.isRunning, true)
        XCTAssertNotEqual(found.first?.threadID, stale.threadId)
        XCTAssertNil(found.first?.resultSummary, "a running thread has no result yet")
    }

    func test_otherReposAndUnrelatedRequestsAreIgnored() throws {
        let db = try makeDB()
        try makeRun(db, repo: "/other/.git")
        try makeRun(db, title: "Add token rate limiting", request: "Add rate limiting to the token endpoint", repo: commonDir)
        XCTAssertEqual(try find(SimilarWorkIndex(db: db), repo: commonDir), [])
    }

    func test_workspaceScopeMatchesWithoutAGitRepo() throws {
        let db = try makeDB()
        let workspace = WorkspaceID()
        let same = try makeRun(db, workspace: workspace)
        try makeRun(db, workspace: WorkspaceID())
        let found = try find(SimilarWorkIndex(db: db), workspace: workspace.value.uuidString)
        XCTAssertEqual(found.map(\.threadID), [same.threadId])
    }

    func test_botScopeMatchesOnlyThatBotsConversations() throws {
        let db = try makeDB()
        let store = BotStore(db: db)
        let mine = try store.create(name: "Mine", title: "", description: "")
        let other = try store.create(name: "Other", title: "", description: "")
        let sameBotRun = try makeRun(db)
        let otherBotRun = try makeRun(db)
        try store.upsertConversation(BotConversation(botID: mine.id, title: "a", linkedAgentThreadID: sameBotRun.threadId))
        try store.upsertConversation(BotConversation(botID: other.id, title: "b", linkedAgentThreadID: otherBotRun.threadId))
        let found = try find(SimilarWorkIndex(db: db), bot: mine.id.value.uuidString)
        XCTAssertEqual(found.map(\.threadID), [sameBotRun.threadId])
    }

    func test_theRequestingThreadIsNeverItsOwnDuplicate() throws {
        let db = try makeDB()
        let own = try makeRun(db, repo: commonDir)
        XCTAssertEqual(try find(SimilarWorkIndex(db: db), excluding: own.threadId, repo: commonDir), [])
    }

    func test_noScopeSearchesNothingAndFirstRunIsDetectedFromRunRows() throws {
        let db = try makeDB()
        let run = try makeRun(db, repo: commonDir)
        let index = SimilarWorkIndex(db: db)
        XCTAssertEqual(try find(index), [])
        XCTAssertFalse(try index.isFirstRun(ofThread: run.threadId))
        let fresh = AgentThread(title: "t", provider: .distill, model: "m")
        try AgentThreadRepository(db: db).upsert(fresh)
        XCTAssertTrue(try index.isFirstRun(ofThread: fresh.id))
    }
}
