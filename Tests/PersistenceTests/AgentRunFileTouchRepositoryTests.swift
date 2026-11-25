import XCTest
import CoreModel
@testable import Persistence

/// Two runs in one repository must see each other; runs in other repositories must not.
final class AgentRunFileTouchRepositoryTests: XCTestCase {
    private func makeDB() throws -> SQLiteDB {
        let path = NSTemporaryDirectory() + "run-touches-" + UUID().uuidString
        return try Bootstrap(channel: .debug, appSupportOverride: path).run().1
    }

    private func makeRun(_ db: SQLiteDB, title: String = "Fix login", status: AgentRunStatus = .running, startedAt: TimeInterval = 100, firstMessage: String? = nil) throws -> AgentRun {
        let thread = AgentThread(title: title, provider: .distill, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        if let firstMessage {
            try AgentMessageRepository(db: db).append(AgentMessage(threadId: thread.id, role: .user, content: firstMessage))
        }
        let run = AgentRun(threadId: thread.id, provider: .distill, model: "m", status: status, startedAt: Date(timeIntervalSince1970: startedAt))
        try AgentRunRepository(db: db).upsert(run)
        return run
    }

    func test_migrationCreatesIdentityAndTouchTablesAtV105() throws {
        let db = try makeDB()
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 105)
        let statement = try db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('agent_run_file_touches', 'agent_run_repo_identity') ORDER BY name;")
        var names: [String] = []
        while try statement.step() { names.append(statement.columnText(0) ?? "") }
        XCTAssertEqual(names, ["agent_run_file_touches", "agent_run_repo_identity"])
    }

    func test_touchesKeepFirstSeenAndDedupePerRunPathKind() throws {
        let db = try makeDB()
        let repo = AgentRunFileTouchRepository(db: db)
        let run = try makeRun(db)
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        try repo.recordTouches(runId: run.id, threadId: run.threadId, repoRoot: "/r", touches: [ProviderFileTouch(path: "a.swift", kind: .edit)], at: early)
        try repo.recordTouches(runId: run.id, threadId: run.threadId, repoRoot: "/r", touches: [
            ProviderFileTouch(path: "a.swift", kind: .edit), ProviderFileTouch(path: "b.swift", kind: .write),
        ], at: late)
        let files = try repo.touches(runId: run.id)
        XCTAssertEqual(files.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(files.first?.since, early, "since is when the run first touched the file, not the latest edit")
        XCTAssertEqual(try repo.touches(runIds: []), [:])
    }

    func test_touchesCascadeWhenTheRunIsDeleted() throws {
        let db = try makeDB()
        let repo = AgentRunFileTouchRepository(db: db)
        let run = try makeRun(db)
        try repo.recordTouches(runId: run.id, threadId: run.threadId, repoRoot: "/r", touches: [ProviderFileTouch(path: "a", kind: .edit)])
        try repo.saveIdentity(runId: run.id, threadId: run.threadId, identity: RunRepoIdentity(repoRoot: "/r", gitCommonDir: "/r/.git", branch: "main"))
        let delete = try db.prepare("DELETE FROM agent_runs WHERE id = ?;")
        try delete.bind(1, run.id.description)
        _ = try delete.step()
        XCTAssertEqual(try repo.touches(runId: run.id), [])
        XCTAssertNil(try repo.identity(runId: run.id))
    }

    func test_liveRunsListsOnlyOtherLiveRunsOfTheSameRepoWithObjectiveBranchAndFiles() throws {
        let db = try makeDB()
        let repo = AgentRunFileTouchRepository(db: db)
        let me = try makeRun(db, title: "Mine", startedAt: 100)
        let other = try makeRun(db, title: "New thread", startedAt: 200, firstMessage: "Refactor the\nlogin screen")
        let worktree = try makeRun(db, title: "In a worktree", startedAt: 300)
        let elsewhere = try makeRun(db, title: "Other repo", startedAt: 400)
        let finished = try makeRun(db, title: "Done", status: .completed, startedAt: 50)
        let common = "/repos/app/.git"
        func identify(_ run: AgentRun, root: String, common: String, branch: String) throws {
            try repo.saveIdentity(runId: run.id, threadId: run.threadId, identity: RunRepoIdentity(repoRoot: root, gitCommonDir: common, branch: branch))
        }
        try identify(me, root: "/repos/app", common: common, branch: "main")
        try identify(other, root: "/repos/app", common: common, branch: "feat/login")
        try identify(worktree, root: "/repos/app-wt", common: common, branch: "feat/wt")
        try identify(elsewhere, root: "/repos/other", common: "/repos/other/.git", branch: "main")
        try identify(finished, root: "/repos/app", common: common, branch: "main")
        try repo.recordTouches(runId: other.id, threadId: other.threadId, repoRoot: "/repos/app", touches: [ProviderFileTouch(path: "Login.swift", kind: .edit)], at: Date(timeIntervalSince1970: 500))

        let index = ConcurrentWorkIndex(db: db)
        let runs = try index.liveRuns(repoCommonDir: common, excludingRun: me.id)
        XCTAssertEqual(runs.map(\.runID), [other.id, worktree.id], "same repo only, oldest first, never the caller, never a finished run")
        XCTAssertEqual(runs[0].objective, "Refactor the login screen")
        XCTAssertEqual(runs[0].branch, "feat/login")
        XCTAssertEqual(runs[0].worktreePath, "/repos/app")
        XCTAssertEqual(runs[0].editingFiles, [ConcurrentRunFile(path: "Login.swift", since: Date(timeIntervalSince1970: 500))])
        XCTAssertEqual(runs[1].worktreePath, "/repos/app-wt", "a linked worktree is reported with its own path")
        XCTAssertEqual(try index.liveRuns(repoCommonDir: common).count, 3, "no exclusion lists every live run")
        XCTAssertEqual(try index.repoCommonDir(ofRun: worktree.id), common)
    }

    func test_liveRunsIgnoresRowsTheHostNoLongerOwns() throws {
        let db = try makeDB()
        let repo = AgentRunFileTouchRepository(db: db)
        let ghost = try makeRun(db, title: "Crashed", startedAt: 100)
        let alive = try makeRun(db, title: "Alive", startedAt: 200)
        for run in [ghost, alive] {
            try repo.saveIdentity(runId: run.id, threadId: run.threadId, identity: RunRepoIdentity(repoRoot: "/r", gitCommonDir: "/r/.git", branch: nil))
        }
        let aliveID = alive.id
        let index = ConcurrentWorkIndex(db: db, liveRunIDs: { [aliveID] })
        XCTAssertEqual(try index.liveRuns(repoCommonDir: "/r/.git").map(\.runID), [alive.id],
                       "a run left 'running' by a crash must not look like a live editor")
    }

    func test_editingFilesAreCappedAtTheMostRecentTwenty() throws {
        let db = try makeDB()
        let repo = AgentRunFileTouchRepository(db: db)
        let run = try makeRun(db)
        try repo.saveIdentity(runId: run.id, threadId: run.threadId, identity: RunRepoIdentity(repoRoot: "/r", gitCommonDir: "/r/.git", branch: nil))
        for i in 0..<25 {
            try repo.recordTouches(runId: run.id, threadId: run.threadId, repoRoot: "/r", touches: [ProviderFileTouch(path: "f\(i).swift", kind: .edit)], at: Date(timeIntervalSince1970: Double(1_000 + i)))
        }
        let files = try ConcurrentWorkIndex(db: db).liveRuns(repoCommonDir: "/r/.git")[0].editingFiles
        XCTAssertEqual(files.count, 20)
        XCTAssertEqual(files.last?.path, "f24.swift")
        XCTAssertEqual(files.first?.path, "f5.swift")
    }

    func test_repoPathStripsDotGitSoWorktreesReportOneRepo() {
        XCTAssertEqual(ConcurrentWorkIndex.repoPath(forCommonDir: "/repos/app/.git"), "/repos/app")
        XCTAssertEqual(ConcurrentWorkIndex.repoPath(forCommonDir: "/repos/app.git"), "/repos/app.git")
    }
}
