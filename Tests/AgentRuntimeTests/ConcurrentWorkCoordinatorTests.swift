import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// The coordinator is the one place every provider's turn passes through, so the concurrent-work block
/// must reach the turn context there and a run must still start when the lookup finds similar work.
final class ConcurrentWorkCoordinatorTests: XCTestCase {
    private struct Harness {
        let db: SQLiteDB
        let coordinator: AgentRunCoordinator
        let threadRepo: AgentThreadRepository
        let runRepo: AgentRunRepository
        let runner: CapturingRunner
    }

    private func makeHarness(withContext: Bool = true, provider: AgentProvider = .codex) throws -> Harness {
        let db = try Bootstrap(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "cw-coord-" + UUID().uuidString).run().1
        let runner = CapturingRunner(provider: provider)
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: AgentMessageRepository(db: db), threadRepo: threadRepo,
            checkpointRepo: AgentTurnCheckpointRepository(db: db), providers: [provider: runner]
        )
        if withContext {
            let identity = RunRepoIdentity(repoRoot: "/work/app", gitCommonDir: "/work/app/.git", branch: "main")
            coordinator.concurrentWorkContext = ConcurrentWorkContext(db: db, resolveIdentity: { _ in identity })
        }
        return Harness(db: db, coordinator: coordinator, threadRepo: threadRepo, runRepo: runRepo, runner: runner)
    }

    private func seedOtherRun(_ h: Harness, title: String, request: String) throws {
        let thread = AgentThread(title: title, provider: .codex, model: "m")
        try h.threadRepo.upsert(thread)
        try AgentMessageRepository(db: h.db).append(AgentMessage(threadId: thread.id, role: .user, content: request))
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .running)
        try h.runRepo.upsert(run)
        let store = AgentRunFileTouchRepository(db: h.db)
        try store.saveIdentity(runId: run.id, threadId: thread.id, identity: RunRepoIdentity(repoRoot: "/work/app", gitCommonDir: "/work/app/.git", branch: "main"))
        try store.recordTouches(runId: run.id, threadId: thread.id, repoRoot: "/work/app", touches: [ProviderFileTouch(path: "Sources/Auth.swift", kind: .edit)])
    }

    private func start(_ h: Harness, prompt: String, environment: [String: String] = [:]) async throws -> AgentThread {
        let thread = AgentThread(title: "New", provider: .codex, model: "m")
        try h.threadRepo.upsert(thread)
        _ = try await h.coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "m", cwd: "/work/app", prompt: prompt, environment: environment))
        return thread
    }

    func test_everyProviderTurnCarriesTheBlockAfterTheExistingTurnContext() async throws {
        let h = try makeHarness()
        try seedOtherRun(h, title: "Refactor auth", request: "Split the auth module into packages")
        _ = try await start(h, prompt: "Add a settings screen", environment: [BotPeerDelegation.turnContextEnvironmentKey: "BOT IDENTITY"])
        let context = try XCTUnwrap(h.runner.lastEnvironment[BotPeerDelegation.turnContextEnvironmentKey])
        XCTAssertTrue(context.hasPrefix("BOT IDENTITY\n\n<concurrent_work>"), context)
        XCTAssertTrue(context.contains("thread 'Refactor auth'") && context.contains("`Sources/Auth.swift`"), context)
    }

    func test_withoutTheContextOrOtherRunsTheTurnContextIsUntouched() async throws {
        let off = try makeHarness(withContext: false)
        try seedOtherRun(off, title: "Refactor auth", request: "Split the auth module")
        _ = try await start(off, prompt: "Add a settings screen", environment: [BotPeerDelegation.turnContextEnvironmentKey: "BOT IDENTITY"])
        XCTAssertEqual(off.runner.lastEnvironment[BotPeerDelegation.turnContextEnvironmentKey], "BOT IDENTITY")

        let alone = try makeHarness()
        _ = try await start(alone, prompt: "Add a settings screen")
        XCTAssertNil(alone.runner.lastEnvironment[BotPeerDelegation.turnContextEnvironmentKey])
    }

    func test_similarWorkWarnsObserversAndStillStartsTheRun() async throws {
        let h = try makeHarness()
        try seedOtherRun(h, title: "Fix login redirect bug", request: "Fix the login redirect bug in the auth service")
        let observer = SimilarWorkObserver()
        h.coordinator.addObserver(observer)
        let thread = try await start(h, prompt: "Please fix the login redirect bug in the auth service")

        XCTAssertEqual(observer.detected.map(\.threadId), [thread.id])
        XCTAssertEqual(observer.detected.first?.work.first?.threadTitle, "Fix login redirect bug")
        XCTAssertNotNil(h.runner.lastRunId, "a warning never blocks the run")
        let context = try XCTUnwrap(h.runner.lastEnvironment[BotPeerDelegation.turnContextEnvironmentKey])
        XCTAssertTrue(context.contains("Check it first; do not redo it"), context)
    }

    func test_aGuestRunNeverSeesMacRunsOrTheToolsTheBlockNames() async throws {
        let h = try makeHarness(provider: .distill)
        try seedOtherRun(h, title: "Refactor auth", request: "Split the auth module")
        let thread = AgentThread(title: "Guest", provider: .distill, model: "m")
        try h.threadRepo.upsert(thread)
        let update = try h.db.prepare("UPDATE agent_threads SET execution_target = 'vm', guest_runtime = 'distill' WHERE id = ?;")
        try update.bind(1, thread.id.value.uuidString)
        _ = try update.step()
        do {
            _ = try await h.coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .distill, model: "m", cwd: "/work/app", prompt: "Add a settings screen"))
        } catch {
            // The guest launch itself is not under test; the environment is captured before it runs.
        }
        XCTAssertNil(h.runner.lastEnvironment[BotPeerDelegation.turnContextEnvironmentKey], "a VM-isolated Bot must not learn about Mac activity")
    }

    func test_aStartThatFailsDeliversNothingAndRaisesNoHint() async throws {
        let h = try makeHarness()
        h.runner.failStart = true
        try seedOtherRun(h, title: "Fix login redirect bug", request: "Fix the login redirect bug in the auth service")
        let observer = SimilarWorkObserver()
        h.coordinator.addObserver(observer)
        do { _ = try await start(h, prompt: "Please fix the login redirect bug in the auth service"); XCTFail("start should fail") } catch {}
        XCTAssertTrue(observer.detected.isEmpty, "no run started, so there is nothing to warn about")
    }

    func test_unrelatedRequestRaisesNoSimilarWorkWarning() async throws {
        let h = try makeHarness()
        try seedOtherRun(h, title: "Fix login redirect bug", request: "Fix the login redirect bug in the auth service")
        let observer = SimilarWorkObserver()
        h.coordinator.addObserver(observer)
        _ = try await start(h, prompt: "Add dark mode to the settings screen")
        XCTAssertTrue(observer.detected.isEmpty)
    }
}

private final class SimilarWorkObserver: AgentRunObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _detected: [(work: [SimilarWork], threadId: AgentThreadID)] = []
    var detected: [(work: [SimilarWork], threadId: AgentThreadID)] { lock.withLock { _detected } }
    func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {}
    func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {}
    func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {}
    func runCoordinator(_ c: AgentRunCoordinator, didDetectSimilarWork work: [SimilarWork], threadId: AgentThreadID) {
        lock.withLock { _detected.append((work, threadId)) }
    }
}

private final class CapturingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    var failStart = false
    init(provider: AgentProvider) { self.provider = provider }
    private let lock = NSLock()
    private var _environment: [String: String] = [:]
    private var _runId: AgentRunID?
    var lastEnvironment: [String: String] { lock.withLock { _environment } }
    var lastRunId: AgentRunID? { lock.withLock { _runId } }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.withLock { _environment = request.environment; _runId = request.runId }
        if failStart { throw AgentProviderAdapterError.unsupported("start refused") }
        Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000)
            onEvent(.finished(.completed, finalMessage: "done", providerThreadId: "provider-thread"))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
