import XCTest
import GitTestSupport
@testable import AgentRuntime
import CoreModel
import Persistence

/// Two agents share one checkout: a run's checkpoint must list the files that run edited,
/// not everything the other agent left dirty in the same tree.
final class RunFileTouchCoordinatorTests: XCTestCase {
    private struct Harness {
        let db: SQLiteDB
        let coordinator: AgentRunCoordinator
        let threadRepo: AgentThreadRepository
        let checkpoints: AgentTurnCheckpointRepository
        let touches: AgentRunFileTouchRepository
    }

    private func makeHarness(runner: AgentProviderRunner) throws -> Harness {
        let support = NSTemporaryDirectory() + "rc2-touch-coord-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support).run()
        let checkpoints = AgentTurnCheckpointRepository(db: db)
        let touches = AgentRunFileTouchRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db), messageRepo: AgentMessageRepository(db: db), threadRepo: threadRepo,
            checkpointRepo: checkpoints, providers: [.codex: runner]
        )
        coordinator.fileTouchTracker = RunFileTouchTracker(store: touches)
        return Harness(db: db, coordinator: coordinator, threadRepo: threadRepo, checkpoints: checkpoints, touches: touches)
    }

    private func dirtyRepo() throws -> GitRepoFixture {
        let repo = try GitRepoFixture()
        try repo.commit(files: [(name: "a.swift", content: "a\n"), (name: "b.swift", content: "b\n")])
        _ = try repo.writeUnstaged(file: "a.swift", content: "a edited by this run\n")
        _ = try repo.writeUnstaged(file: "b.swift", content: "b edited by another agent\n")
        try "new\n".write(toFile: repo.path + "/new.swift", atomically: true, encoding: .utf8)
        return repo
    }

    private func readyCheckpoint(_ h: Harness, thread: AgentThreadID) async throws -> AgentTurnCheckpointSummary {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let ready = try h.checkpoints.list(threadId: thread).first(where: { $0.status == .ready }) { return ready }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw XCTSkip("checkpoint never became ready")
    }

    private func start(_ h: Harness, cwd: String) async throws -> AgentThread {
        let thread = AgentThread(title: "touch run", provider: .codex, model: "m")
        try h.threadRepo.upsert(thread)
        _ = try await h.coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "m", cwd: cwd, prompt: "edit a"))
        return thread
    }

    func test_checkpointListsOnlyTheFilesTheRunEditedAndTouchEventsStayOutOfTheTranscript() async throws {
        let repo = try dirtyRepo()
        defer { repo.cleanup() }
        let runner = TouchingRunner(touches: [
            ProviderFileTouch(path: repo.path + "/a.swift", kind: .edit),
            ProviderFileTouch(path: repo.path + "/new.swift", kind: .write),
        ])
        let h = try makeHarness(runner: runner)
        let thread = try await start(h, cwd: repo.path)

        let checkpoint = try await readyCheckpoint(h, thread: thread.id)
        XCTAssertEqual(checkpoint.files.map(\.path).sorted(), ["a.swift", "new.swift"],
                       "b.swift was changed by someone else in the same tree and must not be attributed to this run")
        XCTAssertEqual(checkpoint.fileSnapshots.map(\.path).sorted(), ["a.swift", "new.swift"])
        XCTAssertNil(checkpoint.diffPatch, "a narrowed list must not ship the whole tree's patch")
        XCTAssertEqual(checkpoint.fileDiffs.map(\.path).sorted(), ["a.swift", "new.swift"])

        let runId = try XCTUnwrap(runner.lastRunId)
        XCTAssertEqual(try h.touches.touches(runId: runId).map(\.path).sorted(), ["a.swift", "new.swift"], "touches persist relative to the repo root")
        let identity = try XCTUnwrap(try h.touches.identity(runId: runId))
        XCTAssertEqual(identity.branch, "main")
        for table in ["agent_stream_events", "agent_provider_event_logs"] {
            let count = try h.db.prepare("SELECT COUNT(*) FROM \(table) WHERE payload_json LIKE '%rc.file_touch%' OR payload_json LIKE '%a.swift\",\"kind%';")
            XCTAssertTrue(try count.step())
            XCTAssertEqual(count.columnInt64(0), 0, "file-touch envelopes are host bookkeeping, not transcript content (\(table))")
        }
    }

    func test_checkpointKeepsTheWholeTreeWhenTheProviderReportedNoEdits() async throws {
        let repo = try dirtyRepo()
        defer { repo.cleanup() }
        let h = try makeHarness(runner: TouchingRunner(touches: []))
        let thread = try await start(h, cwd: repo.path)

        let checkpoint = try await readyCheckpoint(h, thread: thread.id)
        XCTAssertEqual(checkpoint.files.map(\.path).sorted(), ["a.swift", "b.swift", "new.swift"],
                       "a run whose edits went through a shell has no touch events, so the whole tree is the best evidence")
        XCTAssertNotNil(checkpoint.diffPatch)
    }

    func test_checkpointNarrowsFromASubdirectoryCwdForTrackedAndUntrackedFiles() async throws {
        let repo = try GitRepoFixture()
        try FileManager.default.createDirectory(atPath: repo.path + "/pkg", withIntermediateDirectories: true)
        try repo.commit(files: [(name: "pkg/a.swift", content: "a\n"), (name: "other.swift", content: "o\n")])
        defer { repo.cleanup() }
        _ = try repo.writeUnstaged(file: "pkg/a.swift", content: "changed\n")
        _ = try repo.writeUnstaged(file: "other.swift", content: "changed by another agent\n")
        try "fresh\n".write(toFile: repo.path + "/pkg/fresh.swift", atomically: true, encoding: .utf8)
        let runner = TouchingRunner(touches: [
            ProviderFileTouch(path: repo.path + "/pkg/a.swift", kind: .edit),
            ProviderFileTouch(path: repo.path + "/pkg/fresh.swift", kind: .write),
        ])
        let h = try makeHarness(runner: runner)
        let thread = try await start(h, cwd: repo.path + "/pkg")

        let checkpoint = try await readyCheckpoint(h, thread: thread.id)
        XCTAssertFalse(checkpoint.files.contains { $0.path.hasSuffix("other.swift") }, "another agent's file outside the run's touches")
        XCTAssertEqual(checkpoint.files.count, 2, "tracked pkg/a.swift and untracked pkg/fresh.swift (listed cwd-relative by git)")
    }
}

private final class TouchingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let touches: [ProviderFileTouch]
    private let lock = NSLock()
    private var _lastRunId: AgentRunID?
    var lastRunId: AgentRunID? { lock.withLock { _lastRunId } }

    init(touches: [ProviderFileTouch]) { self.touches = touches }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.withLock { _lastRunId = request.runId }
        let touches = touches
        Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let event = ProviderFileTouchParser.runtimeEvent(provider: .codex, touches: touches, itemId: "i1", receivedAtMs: 1) {
                onEvent(.event(event))
            }
            onEvent(.finished(.completed, finalMessage: "done", providerThreadId: "provider-thread"))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
