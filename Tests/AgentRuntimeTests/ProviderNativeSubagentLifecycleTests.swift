import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime

final class ProviderNativeSubagentLifecycleTests: XCTestCase {
    func testBareSubagentMethodNameStillProjectsAChild() {
        // WHY: if a re-wrap is skipped and method is the kind name alone, the
        // orchestrated worker must still become a Subagents row.
        let childID = UUID()
        let payload: [String: Any] = [
            "child_session_id": childID.uuidString,
            "subagent_id": childID.uuidString,
            "status": "completed",
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let event = AssistantEvent.providerRuntime(ProviderRuntimeEvent(
            provider: .grok,
            source: "grok.acp",
            method: "subagent_finished",
            payloadJSON: String(decoding: data, as: UTF8.self),
            receivedAtMs: 1
        ))
        XCTAssertTrue(ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(event))
        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(from: event, parentProvider: .grok).first?.phase,
            .completed
        )
    }

    func testLiveXAISessionNotificationSpawnAndFinish() {
        // WHY: live grok-build emit_subagent_notification uses method
        // `x.ai/session_notification` (not the underscore legacy form). Dropping
        // that method left Subagents UI blind to native Grok children.
        let childID = UUID(uuidString: "019FB003-077E-7391-9013-BE1849DF3941")!
        let spawn = grokRuntimeEvent(
            update: [
                "sessionUpdate": "subagent_spawned",
                "subagent_id": childID.uuidString.lowercased(),
                "child_session_id": childID.uuidString.lowercased(),
                "description": "native explore",
            ],
            method: "x.ai/session_notification"
        )
        let finish = grokRuntimeEvent(
            update: [
                "sessionUpdate": "subagent_finished",
                "subagent_id": childID.uuidString.lowercased(),
                "child_session_id": childID.uuidString.lowercased(),
                "status": "completed",
            ],
            method: "x.ai/session_notification"
        )
        XCTAssertTrue(ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(spawn))
        XCTAssertTrue(ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(finish))
        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(from: spawn, parentProvider: .grok).first?.phase,
            .active
        )
        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(from: finish, parentProvider: .grok).first?.phase,
            .completed
        )
        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(from: spawn, parentProvider: .grok)
                .first?.childRunId.value,
            childID
        )
    }

    func testLiveXAISessionUpdateMethodAlsoProjectsChild() {
        // WHY: pager also classifies `x.ai/session/update` as a session-update
        // ext method carrier for subagent lifecycle payloads.
        let childID = UUID()
        let event = grokRuntimeEvent(
            update: [
                "sessionUpdate": "subagent_spawned",
                "subagent_id": childID.uuidString.lowercased(),
                "child_session_id": childID.uuidString.lowercased(),
            ],
            method: "x.ai/session/update"
        )
        XCTAssertTrue(ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(event))
        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(from: event, parentProvider: .grok).first?.phase,
            .active
        )
    }

    func testOrdinaryGrokSessionUpdateProjectsNoChild() {
        // WHY: live freeze pid 65678 decoded recentReceipts(limit: 500) on every
        // Grok `x.ai/session/update`. Those events are the token hot path; only
        // nested subagent_* kinds must persist a child.
        let event = grokRuntimeEvent(
            update: [
                "sessionUpdate": "agent_message_chunk",
                "content": ["type": "text", "text": "hello"],
            ],
            method: "x.ai/session/update"
        )
        XCTAssertTrue(
            ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(event),
            "session/update still has to be inspected for nested subagent payloads"
        )
        XCTAssertTrue(
            ProviderNativeSubagentLifecycle.updates(from: event, parentProvider: .grok).isEmpty,
            "ordinary Grok session chunks must not project a native child"
        )
    }

    func testOrdinaryProviderEventsSkipTheLifecyclePersistenceHotPath() {
        XCTAssertFalse(
            ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(
                .turnCompleted(turnId: "turn-ordinary", finalMessage: "ordinary assistant text")
            ),
            "ordinary provider output must not trigger orchestration repository reads"
        )
        XCTAssertFalse(
            ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(
                .itemDelta(
                    itemId: "shell",
                    bodyAppend: nil,
                    outputAppend: "large build output",
                    summary: "exec_command"
                )
            ),
            "ordinary tool output must not trigger lifecycle persistence"
        )
    }

    func testGrokNativeSubagentEventsPersistOneLiveThenCompletedChild() async throws {
        let childID = UUID(uuidString: "019FB003-077E-7391-9013-BE1849DF3941")!
        let events: [AssistantEvent] = [
            grokRuntimeEvent(
                update: [
                    "sessionUpdate": "subagent_spawned",
                    "subagent_id": childID.uuidString.lowercased(),
                    "child_session_id": childID.uuidString.lowercased(),
                    "description": "sam-task DEV-3995 full",
                ]
            ),
            // WHY: Grok may replay spawn/progress notifications. One provider
            // child must remain one durable Subagents row.
            grokRuntimeEvent(
                update: [
                    "sessionUpdate": "subagent_spawned",
                    "subagent_id": childID.uuidString.lowercased(),
                    "child_session_id": childID.uuidString.lowercased(),
                    "description": "sam-task DEV-3995 full",
                ],
                isReplay: true
            ),
            grokRuntimeEvent(
                update: [
                    "sessionUpdate": "subagent_progress",
                    "subagent_id": childID.uuidString.lowercased(),
                    "child_session_id": childID.uuidString.lowercased(),
                    "duration_ms": 2_581,
                ]
            ),
            grokRuntimeEvent(
                update: [
                    "sessionUpdate": "subagent_finished",
                    "subagent_id": childID.uuidString.lowercased(),
                    "child_session_id": childID.uuidString.lowercased(),
                    "status": "completed",
                    "duration_ms": 4_582,
                ]
            ),
        ]
        let harness = try makeHarness(provider: .grok, events: events)
        defer { try? FileManager.default.removeItem(atPath: harness.root) }

        _ = try await harness.coordinator.startRun(AgentRunRequest(
            threadId: harness.thread.id,
            provider: .grok,
            model: "grok-4.5",
            cwd: harness.root,
            prompt: "spawn native worker",
            reasoningEffort: .high
        ))

        let accepted = try await waitForReceipt(
            runtime: harness.runtime,
            childID: childID,
            lifecycle: .accepted
        )
        XCTAssertEqual(accepted.provider, .grok)
        XCTAssertEqual(accepted.threadId, harness.thread.id)
        XCTAssertNotEqual(accepted.nodeId, "root")
        XCTAssertNil(
            accepted.reasoningEffort,
            "native lifecycle events do not acknowledge the child's reasoning effort"
        )

        let finalized = try await waitForReceipt(
            runtime: harness.runtime,
            childID: childID,
            lifecycle: .finalized
        )
        XCTAssertEqual(finalized.finalRunStatus, .completed)
        XCTAssertEqual(
            try harness.runtime.recentReceipts().filter { $0.runId?.value == childID }.count,
            1,
            "replayed native lifecycle events must not duplicate the Subagents row"
        )

        let (_, reopenedDB) = try Bootstrap(
            channel: .debug,
            appSupportOverride: harness.root
        ).run()
        let reopenedRuntime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: reopenedDB),
            packageVerification: { true },
            killSwitch: { false }
        )
        let reopened = try XCTUnwrap(
            try reopenedRuntime.recentReceipts().first { $0.runId?.value == childID }
        )
        XCTAssertEqual(
            reopened.finalRunStatus,
            .completed,
            "native child lifecycle must survive closing and reopening RemoteCode"
        )
    }

    func testCodexNativeCollaborationTracksChildAcrossSpawnAndWait() async throws {
        let childID = UUID(uuidString: "019FAFB5-F152-7EC2-AA5F-0B2B40605AB7")!
        let spawnItemID = "exec-spawn"
        let waitItemID = "exec-wait"
        let events: [AssistantEvent] = [
            .itemStarted(item: AssistantItem(
                id: spawnItemID,
                turnId: "turn-1",
                type: .collabToolCall,
                state: .streaming,
                summary: "spawnAgent",
                startedAtMs: 1
            )),
            .itemDelta(
                itemId: spawnItemID,
                bodyAppend: nil,
                outputAppend: agentsStatesJSON(childID: childID, status: "pendingInit"),
                summary: "spawnAgent"
            ),
            .itemCompleted(itemId: spawnItemID, finalState: .completed),
            .itemStarted(item: AssistantItem(
                id: waitItemID,
                turnId: "turn-1",
                type: .collabToolCall,
                state: .streaming,
                summary: "wait",
                startedAtMs: 2
            )),
            .itemDelta(
                itemId: waitItemID,
                bodyAppend: nil,
                outputAppend: agentsStatesJSON(childID: childID, status: "completed"),
                summary: "wait"
            ),
            .itemCompleted(itemId: waitItemID, finalState: .completed),
        ]
        let harness = try makeHarness(provider: .codex, events: events)
        defer { try? FileManager.default.removeItem(atPath: harness.root) }

        _ = try await harness.coordinator.startRun(AgentRunRequest(
            threadId: harness.thread.id,
            provider: .codex,
            model: "gpt-5.6-sol",
            cwd: harness.root,
            prompt: "spawn codex collaborator"
        ))

        let accepted = try await waitForReceipt(
            runtime: harness.runtime,
            childID: childID,
            lifecycle: .accepted
        )
        XCTAssertEqual(accepted.provider, .codex)

        let finalized = try await waitForReceipt(
            runtime: harness.runtime,
            childID: childID,
            lifecycle: .finalized
        )
        XCTAssertEqual(finalized.finalRunStatus, .completed)
        XCTAssertEqual(
            try harness.runtime.recentReceipts().filter { $0.runId?.value == childID }.count,
            1
        )
    }

    func testCodexCallingGrokKeepsNestedProviderIdentity() throws {
        let root = NSTemporaryDirectory() + "rc-provider-cross-child-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false }
        )
        let threadID = AgentThreadID()
        let parentRunID = AgentRunID()
        let childRunID = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        let parent = try runtime.recordExternalRoot(
            runId: parentRunID,
            threadId: threadID,
            provider: .codex,
            providerInstanceId: "codex",
            model: "gpt-5.6-sol",
            permissionMode: .supervised,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapability
            )
        )
        let child = try runtime.recordProviderNativeChild(
            runId: childRunID,
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok",
            model: "unknown",
            nodeId: "nested.grok.worker",
            parentRunId: parentRunID
        )

        XCTAssertEqual(child.parentReceiptId, parent.id)
        XCTAssertEqual(child.provider, .grok)
        XCTAssertEqual(child.threadId, threadID)
        XCTAssertNotEqual(child.nodeId, "root")
    }

    func testTerminalNativeStatesPreserveFailureCancellationAndUncertainty() {
        let failedID = UUID()
        let cancelledID = UUID()
        let unknownID = UUID()

        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(
                from: grokRuntimeEvent(update: [
                    "sessionUpdate": "subagent_finished",
                    "child_session_id": failedID.uuidString,
                    "status": "failed",
                ]),
                parentProvider: .grok
            ).first?.phase,
            .failed,
            "a failed child must never inflate the Done-success count"
        )
        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(
                from: grokRuntimeEvent(update: [
                    "sessionUpdate": "subagent_finished",
                    "child_session_id": cancelledID.uuidString,
                    "status": "cancelled",
                ]),
                parentProvider: .grok
            ).first?.phase,
            .cancelled,
            "a cancelled child must stay distinguishable from completion"
        )
        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(
                from: .itemDelta(
                    itemId: "wait-item",
                    bodyAppend: nil,
                    outputAppend: agentsStatesJSON(childID: unknownID, status: "notFound"),
                    summary: "wait"
                ),
                parentProvider: .codex
            ).first?.phase,
            .unknown,
            "missing provider state must remain unknown instead of inventing success"
        )
    }

    func testTerminalOnlyUnknownCreatesDurableUnknownChild() async throws {
        let childID = UUID()
        let harness = try makeHarness(provider: .grok, events: [
            grokRuntimeEvent(update: [
                "sessionUpdate": "subagent_finished",
                "child_session_id": childID.uuidString,
                "status": "provider_status_not_recognized",
            ]),
        ])
        defer { try? FileManager.default.removeItem(atPath: harness.root) }

        _ = try await harness.coordinator.startRun(AgentRunRequest(
            threadId: harness.thread.id,
            provider: .grok,
            model: "grok-4.5",
            cwd: harness.root,
            prompt: "receive terminal event after reconnect"
        ))

        let receipt = try await waitForReceipt(
            runtime: harness.runtime,
            childID: childID,
            lifecycle: .unknown
        )
        XCTAssertEqual(receipt.provider, .grok)
        XCTAssertNil(
            receipt.finalRunStatus,
            "an unrecognized terminal status must not be reported as completed"
        )
    }

    private struct Harness {
        let root: String
        let thread: AgentThread
        let runtime: AgentOrchestrationRuntime
        let coordinator: AgentRunCoordinator
    }

    private func makeHarness(
        provider: AgentProvider,
        events: [AssistantEvent]
    ) throws -> Harness {
        let root = NSTemporaryDirectory() + "rc-provider-native-child-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let repository = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repository,
            packageVerification: { true },
            killSwitch: { false }
        )
        let thread = AgentThread(
            title: "native child",
            provider: provider,
            model: provider == .grok ? "grok-4.5" : "gpt-5.6-sol"
        )
        try threadRepo.upsert(thread)
        let runner = NativeSubagentFixtureRunner(provider: provider, events: events)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            orchestrationRuntime: runtime,
            providers: [provider: runner]
        )
        return Harness(root: root, thread: thread, runtime: runtime, coordinator: coordinator)
    }

    private func waitForReceipt(
        runtime: AgentOrchestrationRuntime,
        childID: UUID,
        lifecycle: AgentOrchestrationReceiptLifecycleStatus
    ) async throws -> AgentOrchestrationAdmissionReceipt {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let receipt = try runtime.recentReceipts().first(where: {
                $0.runId?.value == childID && $0.lifecycleStatus == lifecycle
            }) {
                return receipt
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(
            domain: "ProviderNativeSubagentLifecycleTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(lifecycle.rawValue) child receipt"]
        )
    }

    func testDistillSubagentLifecycleProjectsChildWithDistillProvider() {
        // WHY: Distill subagents must reach the Subagents badge ledger; the
        // receipt provider must match the event provider, not a hard-coded .grok.
        let childID = UUID()
        let spawn = runtimeEvent(
            provider: .distill,
            update: ["sessionUpdate": "subagent_spawned", "child_session_id": childID.uuidString],
            method: "x.ai/session_notification"
        )
        let finish = runtimeEvent(
            provider: .distill,
            update: [
                "sessionUpdate": "subagent_finished",
                "child_session_id": childID.uuidString,
                "status": "completed",
            ],
            method: "x.ai/session_notification"
        )
        XCTAssertTrue(ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(spawn))
        let active = ProviderNativeSubagentLifecycle.updates(from: spawn, parentProvider: .distill)
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.provider, .distill)
        XCTAssertEqual(active.first?.phase, .active)
        XCTAssertEqual(
            ProviderNativeSubagentLifecycle.updates(from: finish, parentProvider: .distill).first?.phase,
            .completed
        )
    }

    func testClaudeRuntimeEventProjectsNoSubagentChild() {
        // WHY: only Grok-family ACP carriers are parsed here; other providers
        // must not write Subagents receipts from the same method name.
        let childID = UUID()
        let event = runtimeEvent(
            provider: .claude,
            update: ["sessionUpdate": "subagent_spawned", "child_session_id": childID.uuidString],
            method: "x.ai/session_notification"
        )
        XCTAssertFalse(ProviderNativeSubagentLifecycle.isPotentialLifecycleEvent(event))
        XCTAssertTrue(ProviderNativeSubagentLifecycle.updates(from: event, parentProvider: .claude).isEmpty)
    }

    private func runtimeEvent(
        provider: AgentProvider,
        update: [String: Any],
        method: String
    ) -> AssistantEvent {
        let payload: [String: Any] = ["sessionId": "parent-session", "update": update]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return .providerRuntime(ProviderRuntimeEvent(
            provider: provider,
            source: "test.acp",
            method: method,
            payloadJSON: String(decoding: data, as: UTF8.self),
            receivedAtMs: 1
        ))
    }

    private func grokRuntimeEvent(
        update: [String: Any],
        isReplay: Bool = false,
        method: String = "_x.ai/session_notification"
    ) -> AssistantEvent {
        let payload: [String: Any] = [
            "_meta": ["isReplay": isReplay],
            "sessionId": "parent-session",
            "update": update,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .grok,
            source: "grok.acp",
            method: method,
            payloadJSON: String(decoding: data, as: UTF8.self),
            receivedAtMs: 1
        ))
    }

    private func agentsStatesJSON(childID: UUID, status: String) -> String {
        let object = [
            childID.uuidString.lowercased(): [
                "message": NSNull(),
                "status": status,
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private final class NativeSubagentFixtureRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    let events: [AssistantEvent]

    init(provider: AgentProvider, events: [AssistantEvent]) {
        self.provider = provider
        self.events = events
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let events = self.events
        Task.detached {
            onEvent(.status(.running))
            for event in events {
                onEvent(.event(event))
                try? await Task.sleep(nanoseconds: 75_000_000)
            }
            onEvent(.finished(.completed, finalMessage: "done", providerThreadId: "parent-session"))
        }
        return AgentRunHandle(runId: request.runId, process: nil, cancel: {})
    }
}
