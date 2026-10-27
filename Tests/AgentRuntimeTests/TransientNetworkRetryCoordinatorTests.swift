import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: Distill turns keep dying with "[retryable:network] Distill network
/// failure: ... error decoding response body" and wait on a red Retry. A
/// transient network drop must resume the turn by itself, a bounded number
/// of times, and never retry auth/other failures.
final class TransientNetworkRetryCoordinatorTests: XCTestCase {
    static let realFailure = "[retryable:network] Distill network failure: Distill ACP RPC error: reqwest error stream: Transport error: error decoding response body"

    /// Fails with `failure` for the first `failures` starts, then completes.
    private final class FlakyRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider
        let failure: String
        let failures: Int
        private let lock = NSLock()
        private var _requests: [AgentRunRequest] = []
        var requests: [AgentRunRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

        init(provider: AgentProvider = .codex, failure: String, failures: Int) {
            self.provider = provider
            self.failure = failure
            self.failures = failures
        }

        func listModels() async -> [AgentModelDescriptor] { [] }

        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            lock.lock(); _requests.append(request); let attempt = _requests.count; lock.unlock()
            let providerThreadId = request.providerThreadId ?? "session-1"
            let fail = attempt <= failures
            let message = failure
            Task.detached {
                onEvent(.status(.running))
                onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
                onEvent(.event(.turnStarted(turnId: "t\(attempt)")))
                if fail {
                    onEvent(.error(message))
                    onEvent(.finished(.failed, finalMessage: nil, providerThreadId: providerThreadId))
                } else {
                    onEvent(.event(.turnCompleted(turnId: "t\(attempt)", finalMessage: "done")))
                    onEvent(.finished(.completed, finalMessage: "done", providerThreadId: providerThreadId))
                }
            }
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }
    }

    private func start(_ runner: FlakyRunner, selection: AgentModelSelection? = nil) async throws -> (AgentRunCoordinator, AgentThread, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-net-retry-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        var thread = AgentThread(title: "net", provider: runner.provider, model: "fake-model")
        if let selection { thread.modelSelection = selection }
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [runner.provider: runner]
        )
        coordinator.networkRetryDelays = [0, 0, 0]
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: runner.provider, model: "fake-model", cwd: tmp, prompt: "do it",
            reasoningEffort: selection?.reasoningEffort,
            distillMainEffortSelection: selection?.distillMainEffortSelection,
            distillReasoningEffortSelection: selection?.distillReasoningEffortSelection,
            distillExecutionMode: selection?.distillExecutionMode ?? .normal
        ))
        return (coordinator, thread, threadRepo)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_networkDropMidTurn_resumesOnTheSameSessionAndCompletes() async throws {
        let runner = FlakyRunner(provider: .distill, failure: Self.realFailure, failures: 2)
        let selection = AgentModelSelection(
            provider: .distill, modelId: "fake-model", reasoningEffort: .high,
            distillMainEffortSelection: .automatic,
            distillReasoningEffortSelection: .fixed(.low),
            distillExecutionMode: .ultrafast
        )
        let (_, thread, threadRepo) = try await start(runner, selection: selection)

        await waitUntil { runner.requests.count >= 3 && (try? threadRepo.status(of: thread.id)) == .completed }

        XCTAssertEqual(runner.requests.count, 3, "two network failures, then the resumed turn completes")
        XCTAssertEqual(try threadRepo.status(of: thread.id), .completed)
        let resumed = runner.requests[1]
        XCTAssertEqual(resumed.providerThreadId, "session-1", "resume the same provider session")
        XCTAssertEqual(resumed.prompt, TransientNetworkRetry.prompt)
        XCTAssertEqual(resumed.reasoningEffort, .high)
        XCTAssertEqual(resumed.distillMainEffortSelection, .automatic)
        XCTAssertEqual(resumed.distillReasoningEffortSelection, .fixed(.low))
        XCTAssertEqual(resumed.distillExecutionMode, .ultrafast)
    }

    func test_providerOverload_resumesTheSameSessionAndCompletes() async throws {
        let failure = DistillACPFailureTaxonomy.normalize(
            DistillACPError.rpcError(code: -32603, message: "stream error (overloaded_error): Overloaded"),
            context: .turn
        )
        let runner = FlakyRunner(provider: .distill, failure: failure.message, failures: 1)
        let (_, thread, threadRepo) = try await start(runner)
        await waitUntil { runner.requests.count == 2 && (try? threadRepo.status(of: thread.id)) == .completed }
        XCTAssertEqual(runner.requests.count, 2)
        XCTAssertEqual(try threadRepo.status(of: thread.id), .completed)
        XCTAssertEqual(runner.requests.last?.providerThreadId, "session-1")
    }

    func test_providerHTTP503_isTransientAndResumes() async throws {
        // WHY: "API error (status 503 Service Unavailable): Grok is temporarily unavailable"
        // stopped a Bot run on a red Retry; an outage must resume by itself.
        let failure = DistillACPFailureTaxonomy.normalize(
            diagnostic: "Distill ACP RPC error: API error (status 503 Service Unavailable): Grok is temporarily unavailable. Please try again in a moment. (HTTP 503).",
            context: .turn
        )
        XCTAssertTrue(failure.message.hasPrefix(TransientNetworkRetry.marker))
        let runner = FlakyRunner(provider: .distill, failure: failure.message, failures: 1)
        let (_, thread, threadRepo) = try await start(runner)
        await waitUntil { runner.requests.count == 2 && (try? threadRepo.status(of: thread.id)) == .completed }
        XCTAssertEqual(runner.requests.count, 2)
        XCTAssertEqual(runner.requests.last?.providerThreadId, "session-1")
    }

    func test_acpStoppedRespondingTimeout_resumesTheSameSession() async throws {
        // WHY: "[retryable:timeout] Distill ACP stopped responding during session/prompt"
        // already killed the hung process; resuming the session is safe and expected.
        let runner = FlakyRunner(
            provider: .distill,
            failure: "[retryable:timeout] Distill request timed out: Distill ACP stopped responding during session/prompt. Status probe: Distill ACP _remotecode/status timed out",
            failures: 1
        )
        let (_, thread, threadRepo) = try await start(runner)
        await waitUntil { runner.requests.count == 2 && (try? threadRepo.status(of: thread.id)) == .completed }
        XCTAssertEqual(runner.requests.count, 2)
        XCTAssertEqual(try threadRepo.status(of: thread.id), .completed)
    }

    func test_persistentNetworkFailure_stopsAfterTheBound() async throws {
        let runner = FlakyRunner(failure: Self.realFailure, failures: 99)
        let (coordinator, thread, threadRepo) = try await start(runner)
        let expected = coordinator.networkRetryDelays.count + 1

        await waitUntil { runner.requests.count >= expected }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(runner.requests.count, expected, "never loops forever")
        XCTAssertEqual(try threadRepo.status(of: thread.id), .failed, "the Retry button stays for the user")
    }

    func test_guestProcessKill_resumesTheSameSessionAndCompletes() async throws {
        let runner = FlakyRunner(
            provider: .distill,
            failure: "\(TransientNetworkRetry.guestProcessMarker) Distill ACP process exited (signal 9).",
            failures: 1
        )
        let (_, thread, threadRepo) = try await start(runner)
        await waitUntil { runner.requests.count == 2 && (try? threadRepo.status(of: thread.id)) == .completed }
        XCTAssertEqual(runner.requests.count, 2)
        XCTAssertEqual(try threadRepo.status(of: thread.id), .completed)
        XCTAssertEqual(runner.requests.last?.providerThreadId, "session-1")
    }

    func test_nonNetworkFailure_isNotRetried() async throws {
        let runner = FlakyRunner(failure: "[auth-required] Distill authentication failed: 401", failures: 99)
        let (_, thread, threadRepo) = try await start(runner)

        await waitUntil { (try? threadRepo.status(of: thread.id)) == .failed }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(runner.requests.count, 1)
    }
}
