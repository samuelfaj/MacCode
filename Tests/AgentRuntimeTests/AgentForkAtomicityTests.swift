import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// AG031: provider/local fork must be one recoverable operation.
///
/// WHY: provider-first fork followed by a local transaction can orphan a
/// provider child when the process dies between those operations. These tests
/// pin the only safe contract: stable local child identity, keyed provider
/// idempotency, durable state transitions, atomic local graph commit, and
/// idempotent compensation when local completion becomes impossible.
final class AgentForkAtomicityTests: XCTestCase {
    private final class KeyedForkAdapter: AgentProviderAdapter, @unchecked Sendable {
        let provider: AgentProvider
        let forkSafety: AgentProviderForkSafety

        private let lock = NSLock()
        private var childrenByKey: [String: String] = [:]
        private var _forkRequests: [AgentProviderForkRequest] = []
        private var _providerCreations = 0
        private var _compensationCalls = 0
        private var _failForkCount = 0
        private var _rejectForkCount = 0
        private var _failCompensationCount = 0
        private var _onFork: (() throws -> Void)?

        init(
            provider: AgentProvider = .codex,
            safety: AgentProviderForkSafety = .keyedIdempotent(compensationSupported: true)
        ) {
            self.provider = provider
            self.forkSafety = safety
        }

        var forkRequests: [AgentProviderForkRequest] { withLock { _forkRequests } }
        var providerCreations: Int { withLock { _providerCreations } }
        var compensationCalls: Int { withLock { _compensationCalls } }
        var providerChildren: [String: String] { withLock { childrenByKey } }

        func failNextForks(_ count: Int) { withLock { _failForkCount = count } }
        func rejectNextForks(_ count: Int) { withLock { _rejectForkCount = count } }
        func failNextCompensations(_ count: Int) { withLock { _failCompensationCount = count } }
        func onFork(_ action: @escaping () throws -> Void) { withLock { _onFork = action } }

        func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
            let result: (String, (() throws -> Void)?) = try withLock {
                _forkRequests.append(request)
                if _failForkCount > 0 {
                    _failForkCount -= 1
                    throw TestFailure.provider
                }
                if _rejectForkCount > 0 {
                    _rejectForkCount -= 1
                    throw AgentProviderAdapterError.forkRejected("Method not found")
                }
                if let existing = childrenByKey[request.idempotencyKey] {
                    return (existing, _onFork)
                }
                let child = "provider-child-\(request.childThreadId.value.uuidString.lowercased())"
                childrenByKey[request.idempotencyKey] = child
                _providerCreations += 1
                return (child, _onFork)
            }
            try result.1?()
            return result.0
        }

        func compensateFork(
            _ request: AgentProviderForkRequest,
            providerChildThreadId: String
        ) async throws {
            try withLock {
                _compensationCalls += 1
                if _failCompensationCount > 0 {
                    _failCompensationCount -= 1
                    throw TestFailure.compensation
                }
                if childrenByKey[request.idempotencyKey] == providerChildThreadId {
                    childrenByKey.removeValue(forKey: request.idempotencyKey)
                }
            }
        }

        func hasSession(threadId: AgentThreadID) -> Bool { true }
        func listModels() async -> [AgentModelDescriptor] { [] }
        func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            AgentRunHandle(runId: request.runId, process: nil, cancel: {})
        }
        func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            AgentRunHandle(runId: request.runId, process: nil, cancel: {})
        }
        func interruptTurn(threadId: AgentThreadID) throws {}
        func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
        func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
        func stopSession(threadId: AgentThreadID) throws {}
        func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
        func listSessions() -> [AgentProviderSessionSummary] { [] }
        func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
        func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
        func stopAll() {}
        func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}

        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try body()
        }
    }

    private enum TestFailure: Error { case provider, compensation }

    private struct Harness {
        let root: String
        let db: SQLiteDB
        let threadRepo: AgentThreadRepository
        let messageRepo: AgentMessageRepository
        let sessionRepo: ProviderSessionRuntimeRepository
        let parent: AgentThread
        let child: AgentThread

        func coordinator(adapter: AgentProviderAdapter) -> AgentRunCoordinator {
            AgentRunCoordinator(
                runRepo: AgentRunRepository(db: db),
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providerSessionRepo: sessionRepo,
                providerAdapters: [adapter.provider: adapter]
            )
        }
    }

    private func makeHarness(provider: AgentProvider = .codex) throws -> Harness {
        let root = NSTemporaryDirectory() + "rc2-fork-atomicity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let parent = AgentThread(
            workspaceId: WorkspaceID(),
            title: "parent",
            provider: provider,
            model: "model",
            providerThreadId: "provider-parent",
            status: .completed,
            worktreePath: root
        )
        let child = AgentThread(
            workspaceId: parent.workspaceId,
            title: "child",
            provider: provider,
            model: parent.model,
            status: .completed,
            worktreePath: root
        )
        try threadRepo.upsert(parent)
        try messageRepo.append(AgentMessage(threadId: parent.id, role: .user, content: "question"))
        try messageRepo.append(AgentMessage(threadId: parent.id, role: .assistant, content: "answer"))
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: parent.id,
            provider: provider,
            status: .completed,
            resumeCursor: "provider-parent",
            cwd: root,
            model: "model"
        ))
        return Harness(
            root: root,
            db: db,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            sessionRepo: sessionRepo,
            parent: parent,
            child: child
        )
    }

    private func stableKey(_ child: AgentThreadID) -> String {
        "remotecode-thread-fork:\(child.value.uuidString.lowercased())"
    }

    private func assertNoLocalChild(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(try harness.threadRepo.get(id: harness.child.id), file: file, line: line)
        XCTAssertTrue(try harness.messageRepo.list(threadId: harness.child.id).isEmpty, file: file, line: line)
        XCTAssertNil(try harness.sessionRepo.get(threadId: harness.child.id), file: file, line: line)
    }

    private func sourceMessagesJSONByteCount(_ harness: Harness) throws -> Int {
        let statement = try harness.db.prepare("""
            SELECT length(CAST(source_messages_json AS BLOB))
            FROM agent_thread_fork_intents WHERE child_thread_id = ?;
        """)
        try statement.bind(1, harness.child.id.value.uuidString)
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    private func forkIntentRowCount(_ harness: Harness, sourceThreadId: AgentThreadID) throws -> Int {
        let statement = try harness.db.prepare(
            "SELECT COUNT(*) FROM agent_thread_fork_intents WHERE source_thread_id = ?;"
        )
        defer { statement.reset() }
        try statement.bind(1, sourceThreadId.value.uuidString)
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    private func forkIntentPayloadBytes(_ harness: Harness, sourceThreadId: AgentThreadID) throws -> Int {
        let statement = try harness.db.prepare("""
            SELECT COALESCE(SUM(length(CAST(source_messages_json AS BLOB))), 0)
            FROM agent_thread_fork_intents WHERE source_thread_id = ?;
        """)
        defer { statement.reset() }
        try statement.bind(1, sourceThreadId.value.uuidString)
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    func test_unsafeProvidersFailClosedBeforeProviderOrLocalMutation() async throws {
        for provider in AgentProvider.allCases {
            let harness = try makeHarness(provider: provider)
            let adapter = KeyedForkAdapter(provider: provider, safety: .unsupported)
            do {
                _ = try await harness.coordinator(adapter: adapter).forkThread(
                    sourceThreadId: harness.parent.id,
                    childThread: harness.child
                )
                XCTFail("\(provider.rawValue) must reject a fork without a crash-safe adapter contract")
            } catch {
                XCTAssertTrue(String(describing: error).contains("not crash-safe"))
            }
            XCTAssertTrue(adapter.forkRequests.isEmpty,
                          "unsafe \(provider.rawValue) adapter must not receive a provider mutation")
            XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id),
                         "unsafe \(provider.rawValue) adapter must not create a misleading local intent")
            try assertNoLocalChild(harness)
        }
    }

    func test_productionAdaptersDeclareForkUnsafeAndCoordinatorNeverLaunchesThem() async throws {
        // The Claude CLI adapter implements a keyed, compensatable fork on purpose
        // (b602b3490); that contract is pinned by
        // ClaudeStreamingCLIAdapterInterruptTests.test_cliForkThread_isKeyedIdempotentAndCompensatable.
        // Only the adapters whose provider protocol exposes no keyed fork belong here.
        let adapters: [AgentProviderAdapter] = [
            CodexAppServerAdapter(binaryNameOverride: "/definitely/missing/codex"),
            GrokACPAdapter(binaryNameOverride: "/definitely/missing/grok")
        ]

        for adapter in adapters {
            XCTAssertEqual(adapter.forkSafety, .unsupported,
                           "\(adapter.provider.rawValue) must not claim a keyed contract its provider protocol does not expose")
            let harness = try makeHarness(provider: adapter.provider)
            do {
                _ = try await harness.coordinator(adapter: adapter).forkThread(
                    sourceThreadId: harness.parent.id,
                    childThread: harness.child
                )
                XCTFail("\(adapter.provider.rawValue) production adapter must fail closed")
            } catch {
                XCTAssertTrue(String(describing: error).contains("not crash-safe"),
                              "the safety gate must run before any missing-binary/provider call: \(error)")
            }
            XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id))
            try assertNoLocalChild(harness)
        }
    }

    func test_preparedIntentRelaunchCreatesProviderAndLocalChildExactlyOnce() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        _ = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(adapter.forkRequests.count, 1)
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        XCTAssertNotNil(try harness.threadRepo.get(id: harness.child.id))
        XCTAssertEqual(try harness.messageRepo.list(threadId: harness.child.id).map(\.content), ["question", "answer"])

        let secondRelaunch = harness.coordinator(adapter: adapter)
        try secondRelaunch.reconcileOnLaunch()
        await secondRelaunch.waitForForkReconciliation()
        XCTAssertEqual(adapter.forkRequests.count, 1,
                       "a locally committed intent is terminal and must not call the provider on later launches")
        XCTAssertEqual(adapter.providerCreations, 1)
    }

    func test_recoverableTranscriptsRemainExactAndCausalTerminalRowsDoNotSurvive() throws {
        let payloadBytes = 256 * 1024

        func prepareLargeIntent(_ harness: Harness, suffix: String) throws -> AgentThreadForkIntent {
            try harness.messageRepo.append(AgentMessage(
                threadId: harness.parent.id,
                role: .user,
                content: String(repeating: suffix, count: payloadBytes)
            ))
            return try harness.threadRepo.prepareForkIntent(
                sourceThreadId: harness.parent.id,
                childThread: harness.child,
                idempotencyKey: "\(stableKey(harness.child.id))-\(suffix)"
            )
        }

        let compensationHarness = try makeHarness()
        let prepared = try prepareLargeIntent(compensationHarness, suffix: "C")
        let preparedBytes = try sourceMessagesJSONByteCount(compensationHarness)
        XCTAssertGreaterThan(preparedBytes, payloadBytes,
                             "prepared must retain the complete fork-boundary transcript")
        XCTAssertFalse(prepared.providerCreationAttempted,
                       "a newly prepared intent proves no provider call has begun yet")
        let attempted = try compensationHarness.threadRepo.markForkProviderCreationAttempted(
            childThreadId: compensationHarness.child.id
        )
        XCTAssertTrue(attempted.providerCreationAttempted)
        XCTAssertEqual(try sourceMessagesJSONByteCount(compensationHarness), preparedBytes,
                       "the pre-call ambiguity marker must not alter recovery evidence")
        let providerCreated = try compensationHarness.threadRepo.recordForkProviderCreated(
            childThreadId: compensationHarness.child.id,
            providerChildThreadId: "provider-compensated"
        )
        XCTAssertEqual(providerCreated.state, .providerCreated)
        XCTAssertEqual(try sourceMessagesJSONByteCount(compensationHarness), preparedBytes,
                       "provider_created recovery still needs the exact prepared transcript")
        let compensating = try compensationHarness.threadRepo.markForkCompensating(
            childThreadId: compensationHarness.child.id,
            error: "local graph conflict"
        )
        XCTAssertEqual(compensating.state, .compensating)
        XCTAssertEqual(try sourceMessagesJSONByteCount(compensationHarness), preparedBytes,
                       "compensating retry must retain the exact recovery transcript")
        try compensationHarness.threadRepo.markForkCompensated(childThreadId: compensationHarness.child.id)
        XCTAssertNil(try compensationHarness.threadRepo.getForkIntent(childThreadId: compensationHarness.child.id),
                     "a confirmed provider deletion must remove its terminal local row")

        let unattemptedHarness = try makeHarness()
        _ = try prepareLargeIntent(unattemptedHarness, suffix: "A")
        try unattemptedHarness.threadRepo.delete(id: unattemptedHarness.parent.id)
        try unattemptedHarness.threadRepo.markPreparedForkAbandoned(
            childThreadId: unattemptedHarness.child.id,
            error: "source disappeared before any provider call"
        )
        XCTAssertNil(try unattemptedHarness.threadRepo.getForkIntent(childThreadId: unattemptedHarness.child.id),
                     "only a durably unattempted provider creation may be causally abandoned")

        let ambiguousHarness = try makeHarness()
        _ = try prepareLargeIntent(ambiguousHarness, suffix: "U")
        _ = try ambiguousHarness.threadRepo.markForkProviderCreationAttempted(
            childThreadId: ambiguousHarness.child.id
        )
        let ambiguousBytes = try sourceMessagesJSONByteCount(ambiguousHarness)
        try ambiguousHarness.threadRepo.delete(id: ambiguousHarness.parent.id)
        XCTAssertThrowsError(try ambiguousHarness.threadRepo.markPreparedForkAbandoned(
            childThreadId: ambiguousHarness.child.id,
            error: "provider call may have crossed the crash boundary"
        )) { error in
            XCTAssertEqual(error as? AgentThreadForkPersistenceError, .intentConflict)
        }
        XCTAssertEqual(try sourceMessagesJSONByteCount(ambiguousHarness), ambiguousBytes,
                       "an ambiguous keyed provider call must retain its full recovery transcript")

        let committedHarness = try makeHarness()
        _ = try prepareLargeIntent(committedHarness, suffix: "L")
        _ = try committedHarness.threadRepo.markForkProviderCreationAttempted(
            childThreadId: committedHarness.child.id
        )
        let committedProviderID = "provider-local-committed"
        _ = try committedHarness.threadRepo.recordForkProviderCreated(
            childThreadId: committedHarness.child.id,
            providerChildThreadId: committedProviderID
        )
        var committedChild = committedHarness.child
        committedChild.providerThreadId = committedProviderID
        _ = try committedHarness.threadRepo.persistForkedChildGraphReturningPrunedThreadIDs(
            sourceThreadId: committedHarness.parent.id,
            childThread: committedChild,
            providerSession: nil,
            forkIntentChildThreadId: committedChild.id
        )
        XCTAssertEqual(try committedHarness.threadRepo.getForkIntent(childThreadId: committedChild.id)?.state,
                       .localCommitted)
        XCTAssertEqual(try sourceMessagesJSONByteCount(committedHarness), 2,
                       "the retained local-child idempotency marker must not retain a transcript copy")

        try committedHarness.db.execute("""
            CREATE TRIGGER fail_local_committed_intent_delete
            BEFORE DELETE ON agent_thread_fork_intents
            WHEN OLD.child_thread_id = '\(committedChild.id.value.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected terminal intent delete failure'); END;
        """)
        XCTAssertThrowsError(try committedHarness.threadRepo.delete(id: committedChild.id)) { error in
            XCTAssertTrue(String(describing: error).contains("injected terminal intent delete failure"))
        }
        XCTAssertNotNil(try committedHarness.threadRepo.get(id: committedChild.id),
                        "the child delete must roll back when its terminal intent cannot delete")
        XCTAssertNotNil(try committedHarness.threadRepo.getForkIntent(childThreadId: committedChild.id),
                        "the terminal intent must roll back with the child delete")

        try committedHarness.db.execute("DROP TRIGGER fail_local_committed_intent_delete;")
        try committedHarness.threadRepo.delete(id: committedChild.id)
        XCTAssertNil(try committedHarness.threadRepo.get(id: committedChild.id))
        XCTAssertNil(try committedHarness.threadRepo.getForkIntent(childThreadId: committedChild.id),
                     "every child-delete path must leave no orphan local_committed row")
    }

    func test_parentRunCannotRaceAheadOfPreparedLaunchRecovery() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        _ = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        let coordinator = harness.coordinator(adapter: adapter)

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: harness.parent.id,
                provider: .codex,
                model: "model",
                cwd: harness.root,
                prompt: "must wait for relaunch recovery"
            ))
            XCTFail("a parent run must not change the provider snapshot before its prepared fork recovers")
        } catch {
            XCTAssertTrue(String(describing: error).contains("cannot overtake durable fork recovery"))
        }
        XCTAssertFalse(try harness.messageRepo.list(threadId: harness.parent.id).contains {
            $0.content == "must wait for relaunch recovery"
        })

        try coordinator.reconcileOnLaunch()
        await coordinator.waitForForkReconciliation()
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: harness.parent.id,
            provider: .codex,
            model: "model",
            cwd: harness.root,
            prompt: "allowed after fork recovery"
        ))
        XCTAssertTrue(try harness.messageRepo.list(threadId: harness.parent.id).contains {
            $0.content == "allowed after fork recovery"
        })
    }

    func test_providerCreatedIntentRelaunchCommitsLocallyWithoutReforking() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let intent = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        let request = AgentProviderForkRequest(
            sourceThreadId: harness.parent.id,
            childThreadId: harness.child.id,
            idempotencyKey: intent.idempotencyKey
        )
        let providerChild = try await adapter.forkThread(request)
        _ = try harness.threadRepo.recordForkProviderCreated(
            childThreadId: harness.child.id,
            providerChildThreadId: providerChild
        )

        let requestCountBeforeRelaunch = adapter.forkRequests.count
        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(adapter.forkRequests.count, requestCountBeforeRelaunch,
                       "provider_created must continue at the local commit, never fork again")
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        XCTAssertEqual(try harness.threadRepo.get(id: harness.child.id)?.providerThreadId, providerChild)
    }

    func test_recoveryCopiesPreparedTranscriptSnapshotNotLaterParentMessages() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let intent = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        let request = AgentProviderForkRequest(
            sourceThreadId: harness.parent.id,
            childThreadId: harness.child.id,
            idempotencyKey: intent.idempotencyKey
        )
        let providerChild = try await adapter.forkThread(request)
        _ = try harness.threadRepo.recordForkProviderCreated(
            childThreadId: harness.child.id,
            providerChildThreadId: providerChild
        )
        try harness.messageRepo.append(AgentMessage(
            threadId: harness.parent.id,
            role: .user,
            content: "later parent-only turn"
        ))

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(
            try harness.messageRepo.list(threadId: harness.child.id).map(\.content),
            ["question", "answer"],
            "recovery must copy the durable fork boundary, not history appended to the parent after provider fork"
        )
        XCTAssertEqual(
            try harness.messageRepo.list(threadId: harness.parent.id).map(\.content),
            ["question", "answer", "later parent-only turn"],
            "fork recovery must never rewrite or truncate parent identity/history"
        )
    }

    func test_crashWindowAfterProviderCreationReplaysSameKeyWithoutDuplicateProviderChild() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        try harness.db.execute("""
            CREATE TRIGGER fail_provider_created_transition
            BEFORE UPDATE ON agent_thread_fork_intents
            WHEN NEW.child_thread_id = '\(harness.child.id.value.uuidString)'
              AND NEW.state = 'provider_created'
            BEGIN SELECT RAISE(ABORT, 'injected provider-created persistence failure'); END;
        """)

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("provider-created transition fault must surface")
        } catch {
            XCTAssertTrue(String(describing: error).contains("injected provider-created persistence failure"))
        }
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .prepared)
        XCTAssertTrue(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.providerCreationAttempted == true,
                      "the crash window must remain durably marked as provider-call ambiguous")
        try assertNoLocalChild(harness)

        try harness.db.execute("DROP TRIGGER fail_provider_created_transition;")
        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(adapter.forkRequests.count, 2,
                       "relaunch must replay the original request key after the unrecorded response")
        XCTAssertEqual(Set(adapter.forkRequests.map(\.idempotencyKey)), [stableKey(harness.child.id)])
        XCTAssertEqual(adapter.providerCreations, 1,
                       "keyed replay must resolve to the original provider child, not create an orphan duplicate")
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
    }

    func test_eachLocalGraphWriteFaultRollsBackAndRelaunchFinishesWithoutProviderReplay() async throws {
        let stages: [(String, String)] = [
            ("child_thread", """
                CREATE TRIGGER fail_child_thread BEFORE INSERT ON agent_threads
                WHEN NEW.id = '%CHILD%'
                BEGIN SELECT RAISE(ABORT, 'injected child thread failure'); END;
                """),
            ("child_message", """
                CREATE TRIGGER fail_child_message BEFORE INSERT ON agent_messages
                WHEN NEW.thread_id = '%CHILD%'
                BEGIN SELECT RAISE(ABORT, 'injected child message failure'); END;
                """),
            ("child_session", """
                CREATE TRIGGER fail_child_session_atomic BEFORE INSERT ON provider_session_runtime
                WHEN NEW.thread_id = '%CHILD%'
                BEGIN SELECT RAISE(ABORT, 'injected child session failure'); END;
                """),
            ("intent_commit", """
                CREATE TRIGGER fail_fork_intent_commit BEFORE UPDATE ON agent_thread_fork_intents
                WHEN NEW.child_thread_id = '%CHILD%' AND NEW.state = 'local_committed'
                BEGIN SELECT RAISE(ABORT, 'injected intent commit failure'); END;
                """)
        ]

        for (name, rawTrigger) in stages {
            let harness = try makeHarness()
            let adapter = KeyedForkAdapter()
            let trigger = rawTrigger.replacingOccurrences(
                of: "%CHILD%",
                with: harness.child.id.value.uuidString
            )
            try harness.db.execute(trigger)

            do {
                _ = try await harness.coordinator(adapter: adapter).forkThread(
                    sourceThreadId: harness.parent.id,
                    childThread: harness.child
                )
                XCTFail("\(name) fault must abort the complete local graph")
            } catch {
                XCTAssertTrue(String(describing: error).contains("injected"), "\(name): \(error)")
            }
            try assertNoLocalChild(harness)
            XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .providerCreated,
                           "\(name) must retain provider-created recovery evidence")
            XCTAssertEqual(adapter.providerCreations, 1)

            let triggerName: String
            switch name {
            case "child_thread": triggerName = "fail_child_thread"
            case "child_message": triggerName = "fail_child_message"
            case "child_session": triggerName = "fail_child_session_atomic"
            default: triggerName = "fail_fork_intent_commit"
            }
            try harness.db.execute("DROP TRIGGER \(triggerName);")
            let relaunched = harness.coordinator(adapter: adapter)
            try relaunched.reconcileOnLaunch()
            await relaunched.waitForForkReconciliation()

            XCTAssertEqual(adapter.forkRequests.count, 1,
                           "\(name) recovery starts from provider_created and must not refork")
            XCTAssertEqual(adapter.providerCreations, 1)
            XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
            XCTAssertNotNil(try harness.threadRepo.get(id: harness.child.id))
        }
    }

    func test_prepareWriteFailureNeverCallsProvider() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        try harness.db.execute("""
            CREATE TRIGGER fail_fork_prepare BEFORE INSERT ON agent_thread_fork_intents
            BEGIN SELECT RAISE(ABORT, 'injected fork prepare failure'); END;
        """)

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("prepare fault must surface")
        } catch {
            XCTAssertTrue(String(describing: error).contains("injected fork prepare failure"))
        }
        XCTAssertTrue(adapter.forkRequests.isEmpty,
                      "provider mutation is forbidden until the durable local identity exists")
        XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id))
        try assertNoLocalChild(harness)
    }

    func test_providerFailureLeavesPreparedIntentAndRelaunchRetriesSameIdentity() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        adapter.failNextForks(1)

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("provider failure must surface")
        } catch TestFailure.provider {}
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .prepared)
        try assertNoLocalChild(harness)

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()
        XCTAssertEqual(adapter.forkRequests.count, 2)
        XCTAssertEqual(Set(adapter.forkRequests.map(\.idempotencyKey)), [stableKey(harness.child.id)])
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
    }

    func test_aProviderRefusalRetiresTheIntentSoTheNextForkOfTheThreadWorks() async throws {
        // WHY: Distill answered "Method not found" and the intent stayed
        // 'prepared', so every later fork of that thread failed with
        // recoverableIntentExists. A refusal creates nothing: retire it.
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        adapter.rejectNextForks(1)
        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("the refusal must surface")
        } catch AgentProviderAdapterError.forkRejected {}
        XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id),
                     "a refused fork leaves no recoverable intent behind")
        try assertNoLocalChild(harness)

        let retry = AgentThread(
            workspaceId: harness.parent.workspaceId,
            title: "retry",
            provider: harness.parent.provider,
            model: harness.parent.model,
            status: .completed,
            worktreePath: harness.root
        )
        let forked = try await harness.coordinator(adapter: adapter).forkThread(
            sourceThreadId: harness.parent.id,
            childThread: retry
        )
        XCTAssertEqual(forked.id, retry.id, "the next fork of the same thread goes through")
        XCTAssertEqual(adapter.providerCreations, 1)
    }

    func test_preparedIntentWithDeletedSourceAbandonsWithoutProviderMutation() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        _ = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        try harness.threadRepo.delete(id: harness.parent.id)

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertTrue(adapter.forkRequests.isEmpty,
                      "a missing source before provider creation must never create a detached provider child")
        XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id),
                     "a source that disappeared before an attempted provider call leaves no terminal tombstone")
        try assertNoLocalChild(harness)
    }

    func test_oneRecoverableIntentPerSourceRejectsDistinctChildBeforeProviderMutation() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let first = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        let rowsBefore = try forkIntentRowCount(harness, sourceThreadId: harness.parent.id)
        let payloadBefore = try forkIntentPayloadBytes(harness, sourceThreadId: harness.parent.id)

        let sameRetry = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        XCTAssertEqual(sameRetry, first,
                       "the same durable child/key retry must reuse the original recovery identity")
        XCTAssertEqual(try forkIntentRowCount(harness, sourceThreadId: harness.parent.id), rowsBefore)
        XCTAssertEqual(try forkIntentPayloadBytes(harness, sourceThreadId: harness.parent.id), payloadBefore)

        let distinctChild = AgentThread(
            workspaceId: harness.parent.workspaceId,
            title: "distinct child",
            provider: harness.parent.provider,
            model: harness.parent.model,
            status: .completed,
            worktreePath: harness.root
        )
        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: distinctChild
            )
            XCTFail("a source with recoverable fork evidence must reject a distinct child")
        } catch let error as AgentThreadForkPersistenceError {
            XCTAssertEqual(error, .recoverableIntentExists)
        }

        XCTAssertTrue(adapter.forkRequests.isEmpty,
                      "admission must fail before a distinct child reaches the provider")
        XCTAssertEqual(try forkIntentRowCount(harness, sourceThreadId: harness.parent.id), rowsBefore,
                       "rejected admission must not add a terminal or recoverable row")
        XCTAssertEqual(try forkIntentPayloadBytes(harness, sourceThreadId: harness.parent.id), payloadBefore,
                       "rejected admission must not duplicate the source transcript payload")
    }

    func test_concurrentDistinctForksLeaveOneRecoverableIntentAndOneProviderCall() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let providerEntered = expectation(description: "first provider fork entered")
        let releaseProvider = DispatchSemaphore(value: 0)
        adapter.onFork {
            providerEntered.fulfill()
            releaseProvider.wait()
        }
        let firstCoordinator = harness.coordinator(adapter: adapter)
        let secondCoordinator = harness.coordinator(adapter: adapter)
        let firstTask = Task {
            try await firstCoordinator.forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
        }
        await fulfillment(of: [providerEntered], timeout: 2)

        let distinctChild = AgentThread(
            workspaceId: harness.parent.workspaceId,
            title: "concurrent distinct child",
            provider: harness.parent.provider,
            model: harness.parent.model,
            status: .completed,
            worktreePath: harness.root
        )
        let rowsBefore = try forkIntentRowCount(harness, sourceThreadId: harness.parent.id)
        let payloadBefore = try forkIntentPayloadBytes(harness, sourceThreadId: harness.parent.id)
        do {
            _ = try await secondCoordinator.forkThread(
                sourceThreadId: harness.parent.id,
                childThread: distinctChild
            )
            XCTFail("a concurrent distinct child must not overtake the first durable intent")
        } catch let error as AgentThreadForkPersistenceError {
            XCTAssertEqual(error, .recoverableIntentExists)
        }
        XCTAssertEqual(adapter.forkRequests.count, 1,
                       "only the first admitted intent may call the provider")
        XCTAssertEqual(try forkIntentRowCount(harness, sourceThreadId: harness.parent.id), rowsBefore)
        XCTAssertEqual(try forkIntentPayloadBytes(harness, sourceThreadId: harness.parent.id), payloadBefore)

        releaseProvider.signal()
        let firstResult = try await firstTask.value
        XCTAssertEqual(firstResult.id, harness.child.id)
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
    }

    func test_preexistingChildConflictFailsBeforeProviderFork() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        _ = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        let payloadBefore = try sourceMessagesJSONByteCount(harness)
        var conflictingChild = harness.child
        conflictingChild.providerThreadId = "unexpected-provider-child"
        try harness.threadRepo.upsert(conflictingChild)

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("a preexisting local child with another provider identity must fail loudly")
        } catch let error as AgentThreadForkPersistenceError {
            XCTAssertEqual(error, .childThreadConflict)
        }
        XCTAssertTrue(adapter.forkRequests.isEmpty,
                      "a local child conflict must short-circuit before provider mutation")
        XCTAssertEqual(try sourceMessagesJSONByteCount(harness), payloadBefore,
                       "a conflict must preserve the recoverable transcript exactly")
    }

    func test_capDeletingLocalCommittedChildDeletesIntentInTheSameTransaction() throws {
        let harness = try makeHarness()
        var child = harness.child
        child.worktreePath = nil
        _ = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: child,
            idempotencyKey: stableKey(child.id)
        )
        _ = try harness.threadRepo.markForkProviderCreationAttempted(childThreadId: child.id)
        _ = try harness.threadRepo.recordForkProviderCreated(
            childThreadId: child.id,
            providerChildThreadId: "provider-cap-child"
        )
        child.providerThreadId = "provider-cap-child"
        _ = try harness.threadRepo.persistForkedChildGraphReturningPrunedThreadIDs(
            sourceThreadId: harness.parent.id,
            childThread: child,
            providerSession: nil,
            forkIntentChildThreadId: child.id
        )
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: child.id)?.state, .localCommitted)

        let prospective = AgentThread(
            workspaceId: harness.parent.workspaceId,
            title: "cap producer",
            provider: harness.parent.provider,
            model: harness.parent.model,
            status: .completed
        )
        let pruned = try harness.threadRepo.upsertEnforcingWorkspaceThreadLimit(prospective, limit: 2)

        XCTAssertEqual(pruned, [child.id],
                       "the completed child is the only cap-eligible row because its source owns a worktree")
        XCTAssertNil(try harness.threadRepo.get(id: child.id))
        XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: child.id),
                     "the cap's child DELETE must remove the local_committed identity marker atomically")
        XCTAssertNotNil(try harness.threadRepo.get(id: prospective.id))
    }

    func test_concurrentDuplicateCallsProduceOneProviderAndOneLocalChild() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let coordinator = harness.coordinator(adapter: adapter)

        let attempt: () async -> Result<AgentThread, Error> = {
            do {
                return .success(try await coordinator.forkThread(
                    sourceThreadId: harness.parent.id,
                    childThread: harness.child
                ))
            } catch {
                return .failure(error)
            }
        }
        async let first = attempt()
        async let second = attempt()
        let concurrentResults = await [first, second]
        XCTAssertEqual(concurrentResults.compactMap { try? $0.get() }.map(\.id), [harness.child.id])
        XCTAssertEqual(concurrentResults.filter {
            guard case .failure(let error) = $0 else { return false }
            return String(describing: error).contains("another provider mutation is active")
        }.count, 1, "the in-flight duplicate must fail loudly instead of racing the snapshot boundary")

        let retried = try await coordinator.forkThread(
            sourceThreadId: harness.parent.id,
            childThread: harness.child
        )

        XCTAssertEqual(retried.id, harness.child.id,
                       "retry after the first commit must resolve the durable child idempotently")
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(Set(adapter.forkRequests.map(\.idempotencyKey)), [stableKey(harness.child.id)])
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        XCTAssertEqual(try harness.threadRepo.list().filter { $0.id == harness.child.id }.count, 1)
        XCTAssertEqual(try harness.messageRepo.list(threadId: harness.child.id).map(\.content), ["question", "answer"])
    }

    /// The side chat button is meant for a thread that is still working. A
    /// branch still waits for an idle source; a side chat must not.
    func test_sideChatForksWhileTheSourceRunsButABranchStillWaits() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let coordinator = harness.coordinator(adapter: adapter)
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: harness.parent.id, provider: .codex, model: "model", cwd: harness.root, prompt: "long work"
        ))
        XCTAssertNotNil(coordinator.activeRunId(threadId: harness.parent.id), "positive control: the source is running")

        do {
            _ = try await coordinator.forkThread(sourceThreadId: harness.parent.id, childThread: harness.child)
            XCTFail("a branch of a running thread must wait for it to be idle")
        } catch {
            XCTAssertTrue(String(describing: error).contains("another provider mutation is active"))
        }

        let side = AgentThread(
            workspaceId: harness.parent.workspaceId, title: "side", provider: harness.parent.provider,
            model: harness.parent.model, status: .completed, worktreePath: harness.root, isEphemeral: true
        )
        let forked = try await coordinator.forkThread(sourceThreadId: harness.parent.id, childThread: side)
        XCTAssertEqual(forked.id, side.id)
        XCTAssertEqual(adapter.forkRequests.last?.isSide, true)
    }

    func test_runStartCannotOvertakeForkSnapshotBoundary() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let enteredProviderFork = expectation(description: "provider fork entered")
        let releaseProviderFork = DispatchSemaphore(value: 0)
        adapter.onFork {
            enteredProviderFork.fulfill()
            releaseProviderFork.wait()
        }
        let coordinator = harness.coordinator(adapter: adapter)
        let forkTask = Task {
            try await coordinator.forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
        }
        await fulfillment(of: [enteredProviderFork], timeout: 2)

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: harness.parent.id,
                provider: .codex,
                model: "model",
                cwd: harness.root,
                prompt: "must not overtake fork"
            ))
            XCTFail("run start must not mutate the parent while its fork boundary is in flight")
        } catch {
            XCTAssertTrue(String(describing: error).contains("cannot overtake durable fork recovery"))
        }

        releaseProviderFork.signal()
        _ = try await forkTask.value
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        XCTAssertFalse(try harness.messageRepo.list(threadId: harness.parent.id).contains {
            $0.content == "must not overtake fork"
        }, "rejected concurrent start must not persist a user message")
    }

    func test_unrecoverableLocalConflictCompensatesProviderExactlyOnce() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        adapter.onFork { try harness.threadRepo.delete(id: harness.parent.id) }

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("deleted source must prevent a detached local child")
        } catch let error as AgentThreadForkPersistenceError {
            XCTAssertEqual(error, .sourceThreadNotFound)
        }

        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(adapter.compensationCalls, 1)
        XCTAssertTrue(adapter.providerChildren.isEmpty)
        XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id),
                     "the intent is removable only after successful provider compensation")
        try assertNoLocalChild(harness)
    }

    func test_compensationFailureRelaunchRetriesDeleteWithoutReforking() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        adapter.failNextCompensations(1)
        adapter.onFork { try harness.threadRepo.delete(id: harness.parent.id) }

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("first compensation failure must surface")
        } catch TestFailure.compensation {}
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .compensating)
        XCTAssertEqual(adapter.providerChildren.count, 1)

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(adapter.forkRequests.count, 1,
                       "compensating recovery must not create another provider child")
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(adapter.compensationCalls, 2)
        XCTAssertTrue(adapter.providerChildren.isEmpty)
        XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id),
                     "a successful relaunch compensation must retire its terminal row")
        try assertNoLocalChild(harness)
    }
}
