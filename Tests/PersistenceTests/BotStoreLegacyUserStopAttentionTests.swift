import XCTest
import CoreModel
@testable import Persistence

/// Causal legacy `Run cancelled` repair. Copied from the live triplicate
/// (uppercase stored run/thread IDs, lowercase conversation linkage, matching
/// userStop ledger time). Tests never open the live user database.
final class BotStoreLegacyUserStopAttentionTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!
    private let stamp = ISO8601DateFormatter().date(from: "2026-08-21T02:54:43Z")!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
    }

    override func tearDown() {
        store = nil
        db = nil
    }

    func test_copiedLiveTriplicateWithUppercaseIdsAndMatchingLedgerClearsAtomically() throws {
        let fixture = try installLiveTriplicate()
        let proofs = [userStopProof(runId: fixture.run.id, threadId: fixture.thread.id)]
        XCTAssertNil(try AgentRunRepository(db: db).get(id: fixture.run.id)?.terminalReason)

        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: proofs, now: stamp), 3)
        XCTAssertTrue(try store.listAttention().isEmpty)
        XCTAssertEqual(try store.conversation(id: fixture.conversation.id)?.attentionState, BotAttentionState.none)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: fixture.run.id)?.status, .cancelled)
        XCTAssertEqual(
            try AgentRunRepository(db: db).get(id: fixture.run.id)?.terminalReason,
            BotStore.LegacyUserStopAttentionSignature.terminalReason
        )
        XCTAssertEqual(try AgentMessageRepository(db: db).list(threadId: fixture.thread.id).count, 2)

        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: proofs, now: stamp), 0)
        XCTAssertEqual(try store.conversation(id: fixture.conversation.id)?.attentionState, BotAttentionState.none)
    }

    func test_providerCancelledProofLeavesTriplicateActionable() throws {
        let fixture = try installLiveTriplicate()
        let proofs = [
            BotStore.LegacyUserStopLedgerProof(
                runId: fixture.run.id.value.uuidString,
                threadId: fixture.thread.id.value.uuidString,
                eventTime: stamp,
                reason: "providerCancelled"
            )
        ]
        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: proofs), 0)
        XCTAssertEqual(try store.listAttention().count, 3)
        XCTAssertEqual(try store.conversation(id: fixture.conversation.id)?.attentionState, .needsAttention)
    }

    func test_conflictingDurableTerminalReasonPreservesTriplicate() throws {
        // WHY: a ledger userStop proof cannot overrule a different durable
        // terminal cause on the exact run being repaired.
        let fixture = try installLiveTriplicate()
        var run = try XCTUnwrap(AgentRunRepository(db: db).get(id: fixture.run.id))
        run.terminalReason = "providerCancelled"
        try AgentRunRepository(db: db).upsert(run)

        XCTAssertEqual(
            try store.repairLegacyUserStopAttention(
                proofs: [userStopProof(runId: fixture.run.id, threadId: fixture.thread.id)]
            ),
            0
        )
        XCTAssertEqual(try store.listAttention().count, 3)
        XCTAssertEqual(try store.conversation(id: fixture.conversation.id)?.attentionState, .needsAttention)
    }

    func test_missingLedgerPreservesTriplicate() throws {
        let fixture = try installLiveTriplicate()
        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: []), 0)
        XCTAssertEqual(try store.listAttention().count, 3)
        XCTAssertEqual(try store.conversation(id: fixture.conversation.id)?.attentionState, .needsAttention)
    }

    func test_timestampMismatchPreservesRow() throws {
        let fixture = try installLiveTriplicate()
        let proofs = [
            BotStore.LegacyUserStopLedgerProof(
                runId: fixture.run.id.value.uuidString,
                threadId: fixture.thread.id.value.uuidString,
                eventTime: stamp.addingTimeInterval(60),
                reason: "userStop"
            )
        ]
        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: proofs), 0)
        XCTAssertEqual(try store.listAttention().count, 3)
    }

    func test_runIdMismatchPreservesRow() throws {
        let fixture = try installLiveTriplicate()
        let proofs = [userStopProof(runId: AgentRunID(), threadId: fixture.thread.id)]
        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: proofs), 0)
        XCTAssertEqual(try store.listAttention().count, 3)
    }

    func test_sessionStatusMismatchPreservesRow() throws {
        let fixture = try installLiveTriplicate()
        var session = try XCTUnwrap(ProviderSessionRuntimeRepository(db: db).get(threadId: fixture.thread.id))
        session.status = .running
        try ProviderSessionRuntimeRepository(db: db).upsert(session)
        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: [userStopProof(runId: fixture.run.id, threadId: fixture.thread.id)]), 0)
        XCTAssertEqual(try store.listAttention().count, 3)
    }

    func test_laterRunMismatchPreservesRow() throws {
        let fixture = try installLiveTriplicate()
        try AgentRunRepository(db: db).upsert(
            AgentRun(
                threadId: fixture.thread.id,
                provider: .grok,
                model: "test",
                status: .completed,
                startedAt: stamp.addingTimeInterval(30),
                finishedAt: stamp.addingTimeInterval(40)
            )
        )
        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: [userStopProof(runId: fixture.run.id, threadId: fixture.thread.id)]), 0)
        XCTAssertEqual(try store.listAttention().count, 3)
    }

    func test_distinctRunAtSamePersistedSecondPreservesRow() throws {
        // WHY: repository timestamps have second precision. A later run can
        // compare equal to the cancelled run's finish and must fail closed.
        let fixture = try installLiveTriplicate()
        try AgentRunRepository(db: db).upsert(
            AgentRun(
                threadId: fixture.thread.id,
                provider: .grok,
                model: "test",
                status: .running,
                startedAt: stamp
            )
        )
        XCTAssertEqual(
            try store.repairLegacyUserStopAttention(
                proofs: [userStopProof(runId: fixture.run.id, threadId: fixture.thread.id)]
            ),
            0
        )
        XCTAssertEqual(try store.listAttention().count, 3)
    }

    func test_pendingCallbackMismatchPreservesRow() throws {
        let fixture = try installLiveTriplicate()
        try db.execute("""
            INSERT INTO provider_pending_callbacks(
                thread_id, request_id, callback_kind, state, payload_json, created_at
            ) VALUES(
                '\(fixture.thread.id.value.uuidString)', 'cb-1', 'approval', 'pending', '{}',
                '2026-08-21T02:54:43Z'
            );
            """)
        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: [userStopProof(runId: fixture.run.id, threadId: fixture.thread.id)]), 0)
        XCTAssertEqual(try store.listAttention().count, 3)
        XCTAssertEqual(try store.conversation(id: fixture.conversation.id)?.attentionState, .needsAttention)
    }

    func test_otherActionableAttentionKeepsConversationNeedingYou() throws {
        let fixture = try installLiveTriplicate()
        let genuine = BotAttentionItem(
            botID: fixture.bot.id,
            conversationID: fixture.conversation.id,
            kind: .approval,
            title: "Approve this",
            detail: "A real callback",
            createdAt: stamp
        )
        try store.upsertAttention(genuine)
        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: [userStopProof(runId: fixture.run.id, threadId: fixture.thread.id)]), 3)
        XCTAssertEqual(try store.listAttention().map(\.id), [genuine.id])
        XCTAssertEqual(try store.conversation(id: fixture.conversation.id)?.attentionState, .needsAttention)
        XCTAssertEqual(try AgentMessageRepository(db: db).list(threadId: fixture.thread.id).count, 2)
    }

    func test_injectedTransactionFaultCannotSplitRowAndConversation() throws {
        let fixture = try installLiveTriplicate()
        store.legacyRepairFaultAfterAcknowledgeForTesting = true
        XCTAssertThrowsError(
            try store.repairLegacyUserStopAttention(proofs: [userStopProof(runId: fixture.run.id, threadId: fixture.thread.id)])
        )
        XCTAssertEqual(try store.listAttention().count, 3)
        XCTAssertEqual(try store.conversation(id: fixture.conversation.id)?.attentionState, .needsAttention)
        XCTAssertNil(try AgentRunRepository(db: db).get(id: fixture.run.id)?.terminalReason)
        store.legacyRepairFaultAfterAcknowledgeForTesting = false
        XCTAssertEqual(try store.repairLegacyUserStopAttention(proofs: [userStopProof(runId: fixture.run.id, threadId: fixture.thread.id)]), 3)
        XCTAssertTrue(try store.listAttention().isEmpty)
        XCTAssertEqual(try store.conversation(id: fixture.conversation.id)?.attentionState, BotAttentionState.none)
        XCTAssertEqual(
            try AgentRunRepository(db: db).get(id: fixture.run.id)?.terminalReason,
            BotStore.LegacyUserStopAttentionSignature.terminalReason
        )
    }

    func test_genuineQuestionApprovalFailedInterruptedRemainActionable() throws {
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .grok)
        let thread = AgentThread(title: "live", provider: .grok, model: "test")
        try AgentThreadRepository(db: db).upsert(thread)
        let conversation = BotConversation(
            botID: bot.id,
            title: "live",
            attentionState: .needsAttention,
            linkedAgentThreadID: thread.id
        )
        try store.upsertConversation(conversation)
        // The run that raised these items started before them; a newer run would resolve `blocked`.
        try AgentRunRepository(db: db).upsert(
            AgentRun(threadId: thread.id, provider: .grok, model: "test", status: .failed, startedAt: stamp.addingTimeInterval(-60), finishedAt: stamp)
        )
        let question = BotAttentionItem(
            botID: bot.id,
            conversationID: conversation.id,
            kind: .question,
            title: "Needs you",
            createdAt: stamp
        )
        let approval = BotAttentionItem(
            botID: bot.id,
            conversationID: conversation.id,
            kind: .approval,
            title: "Approve edit",
            createdAt: stamp
        )
        let blocked = BotAttentionItem(
            botID: bot.id,
            conversationID: conversation.id,
            kind: .blocked,
            title: "Run needs you",
            createdAt: stamp
        )
        try store.upsertAttention(question)
        try store.upsertAttention(approval)
        try store.upsertAttention(blocked)
        XCTAssertEqual(
            try store.repairLegacyUserStopAttention(proofs: [userStopProof(runId: AgentRunID(), threadId: thread.id)]),
            0
        )
        XCTAssertEqual(try store.listAttention().count, 3)
    }

    private func userStopProof(runId: AgentRunID, threadId: AgentThreadID) -> BotStore.LegacyUserStopLedgerProof {
        BotStore.LegacyUserStopLedgerProof(
            runId: runId.value.uuidString,
            threadId: threadId.value.uuidString,
            eventTime: stamp,
            reason: "userStop"
        )
    }

    private func installLiveTriplicate() throws -> (
        bot: BotDefinition,
        thread: AgentThread,
        run: AgentRun,
        conversation: BotConversation
    ) {
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .grok)
        let thread = AgentThread(
            title: "Delegated request",
            provider: .grok,
            model: "test",
            status: .cancelled,
            updatedAt: stamp
        )
        try AgentThreadRepository(db: db).upsert(thread)
        XCTAssertEqual(thread.id.value.uuidString, thread.id.value.uuidString.uppercased())
        let conversation = BotConversation(
            botID: bot.id,
            title: "Delegated request",
            unread: false,
            attentionState: .needsAttention,
            linkedAgentThreadID: thread.id,
            createdAt: stamp,
            updatedAt: stamp
        )
        try store.upsertConversation(conversation)
        let linkStatement = try db.prepare("SELECT linked_agent_thread_id FROM bot_conversations WHERE id = ?;")
        try linkStatement.bind(1, conversation.id.value.uuidString.lowercased())
        XCTAssertTrue(try linkStatement.step())
        XCTAssertEqual(linkStatement.columnText(0), thread.id.value.uuidString.lowercased())

        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "test",
            status: .cancelled,
            startedAt: stamp.addingTimeInterval(-30),
            finishedAt: stamp
        )
        try AgentRunRepository(db: db).upsert(run)
        let runStatement = try db.prepare("SELECT id FROM agent_runs WHERE id = ?;")
        try runStatement.bind(1, run.id.value.uuidString)
        XCTAssertTrue(try runStatement.step())
        XCTAssertEqual(runStatement.columnText(0), run.id.value.uuidString.uppercased())
        try AgentMessageRepository(db: db).append(
            AgentMessage(threadId: thread.id, role: .user, content: "please look", createdAt: stamp.addingTimeInterval(-20))
        )
        try AgentMessageRepository(db: db).append(
            AgentMessage(threadId: thread.id, role: .assistant, content: "working", createdAt: stamp.addingTimeInterval(-10))
        )
        try ProviderSessionRuntimeRepository(db: db).upsert(
            ProviderSessionRuntime(
                threadId: thread.id,
                provider: .grok,
                status: .cancelled,
                lastRunId: run.id,
                updatedAt: stamp
            )
        )
        for _ in 0..<3 {
            try store.upsertAttention(
                BotAttentionItem(
                    botID: bot.id,
                    conversationID: conversation.id,
                    kind: .question,
                    title: BotStore.LegacyUserStopAttentionSignature.title,
                    detail: BotStore.LegacyUserStopAttentionSignature.detail,
                    createdAt: stamp
                )
            )
        }
        XCTAssertEqual(try store.listAttention().count, 3)
        return (bot, thread, run, conversation)
    }
}
