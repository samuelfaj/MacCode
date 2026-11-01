import XCTest
import CoreModel
@testable import Persistence

final class BotContextDelegationTests: XCTestCase {
    private struct Fixture {
        let db: SQLiteDB
        let store: BotStore
        let host = "delegation-test-host"
        let context: BotContext
        let parentRun: AgentRun
        let childRun: AgentRun
        let parentPin: BotConversationContextPin
        let childPin: BotConversationContextPin
    }

    private func fixture(path: String = ":memory:", context: BotContext = .workspace(WorkspaceID()), parentActions: Set<BotContextAction> = [.read, .send, .delegate], childActions: Set<BotContextAction> = [.read, .send]) throws -> Fixture {
        let db = try SQLiteDB(path: path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let parentBot = try store.create(name: "Parent", title: "Parent", description: "", handle: "parent", soul: "", provider: .claude, model: "opus")
        let childBot = try store.create(name: "Child", title: "Child", description: "", handle: "child", soul: "", provider: .claude, model: "opus")
        let parentGrant = try store.grantContext(hostID: "delegation-test-host", botID: parentBot.id, context: context, actions: parentActions, expectedRevision: nil)
        let childGrant = try store.grantContext(hostID: "delegation-test-host", botID: childBot.id, context: context, actions: childActions, expectedRevision: nil)
        let workspaceID: WorkspaceID? = { if case .workspace(let id) = context { return id }; return nil }()
        let parentThread = AgentThread(workspaceId: workspaceID, title: "Parent", provider: .distill, model: "distill")
        let childThread = AgentThread(workspaceId: workspaceID, title: "Child", provider: .distill, model: "distill")
        let parentConversation = BotConversation(botID: parentBot.id, title: "Parent", linkedAgentThreadID: parentThread.id)
        let childConversation = BotConversation(botID: childBot.id, title: "Child", linkedAgentThreadID: childThread.id)
        let parentPin = try store.createContextualConversation(parentConversation, newThread: parentThread, hostID: "delegation-test-host", context: context, policyRevision: parentGrant.policyRevision)
        let childPin = try store.createContextualConversation(childConversation, newThread: childThread, hostID: "delegation-test-host", context: context, policyRevision: childGrant.policyRevision)
        let parentRun = AgentRun(threadId: parentThread.id, provider: .distill, model: "distill", status: .running)
        let childRun = AgentRun(threadId: childThread.id, provider: .distill, model: "distill", status: .running)
        let runs = AgentRunRepository(db: db)
        try runs.upsert(parentRun)
        try runs.upsert(childRun)
        return Fixture(db: db, store: store, context: context, parentRun: parentRun, childRun: childRun, parentPin: parentPin, childPin: childPin)
    }

    func test_sameContextDelegationPersistsAndClosedEdgeCannotReopen() throws {
        let path = NSTemporaryDirectory().appending("BotContextDelegation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let f = try fixture(path: path)
        let first = try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.parentRun.id, childRunID: f.childRun.id, childThreadID: f.childRun.threadId)
        XCTAssertEqual(first.parentPin, f.parentPin)
        XCTAssertEqual(first.childPin, f.childPin)
        XCTAssertEqual(try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.parentRun.id, childRunID: f.childRun.id, childThreadID: f.childRun.threadId), first)
        XCTAssertTrue(try f.store.authorizesContextDelegation(hostID: f.host, runID: f.childRun.id, threadID: f.childRun.threadId))
        _ = try f.store.closeContextDelegationTree(runID: f.parentRun.id)
        XCTAssertThrowsError(try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.parentRun.id, childRunID: f.childRun.id, childThreadID: f.childRun.threadId))
        let reopenedDB = try SQLiteDB(path: path)
        try Schema.migrate(reopenedDB)
        let reopened = BotStore(db: reopenedDB)
        XCTAssertEqual(try reopened.conversationContextPin(linkedTo: f.parentRun.threadId), f.parentPin)
        XCTAssertEqual(try reopened.conversationContextPin(linkedTo: f.childRun.threadId), f.childPin)
        XCTAssertEqual(try reopened.contextDelegation(childRunID: f.childRun.id)?.closed, true)
        XCTAssertFalse(try reopened.authorizesContextDelegation(hostID: f.host, runID: f.childRun.id, threadID: f.childRun.threadId))
    }

    func test_mismatchedContextAndMissingOrRevokedDelegateRejectBeforeInsert() throws {
        let workspace = WorkspaceID()
        let mismatched = try fixture(context: .workspace(workspace))
        let otherBot = try mismatched.store.create(name: "Other", title: "Other", description: "", handle: "other", soul: "", provider: .claude, model: "opus")
        let otherWorkspace = WorkspaceID()
        let otherContext = BotContext.workspace(otherWorkspace)
        let otherGrant = try mismatched.store.grantContext(hostID: mismatched.host, botID: otherBot.id, context: otherContext, actions: [.read, .send], expectedRevision: nil)
        let otherThread = AgentThread(workspaceId: otherWorkspace, title: "Other", provider: .distill, model: "distill")
        let otherConversation = BotConversation(botID: otherBot.id, title: "Other", linkedAgentThreadID: otherThread.id)
        _ = try mismatched.store.createContextualConversation(otherConversation, newThread: otherThread, hostID: mismatched.host, context: otherContext, policyRevision: otherGrant.policyRevision)
        let otherRun = AgentRun(threadId: otherThread.id, provider: .distill, model: "distill", status: .running)
        try AgentRunRepository(db: mismatched.db).upsert(otherRun)
        XCTAssertThrowsError(try mismatched.store.recordContextDelegation(hostID: mismatched.host, parentRunID: mismatched.parentRun.id, childRunID: otherRun.id, childThreadID: otherThread.id))
        XCTAssertNil(try mismatched.store.contextDelegation(childRunID: otherRun.id))

        let noDelegate = try fixture(parentActions: [.read, .send])
        XCTAssertThrowsError(try noDelegate.store.recordContextDelegation(hostID: noDelegate.host, parentRunID: noDelegate.parentRun.id, childRunID: noDelegate.childRun.id, childThreadID: noDelegate.childRun.threadId))
        XCTAssertNil(try noDelegate.store.contextDelegation(childRunID: noDelegate.childRun.id))

        let revoked = try fixture()
        _ = try revoked.store.revokeContext(hostID: revoked.host, botID: revoked.parentPin.botID, context: revoked.context, expectedRevision: revoked.parentPin.policyRevision)
        XCTAssertThrowsError(try revoked.store.recordContextDelegation(hostID: revoked.host, parentRunID: revoked.parentRun.id, childRunID: revoked.childRun.id, childThreadID: revoked.childRun.threadId))
        XCTAssertNil(try revoked.store.contextDelegation(childRunID: revoked.childRun.id))
    }

    func test_nestedDelegationRevocationAndTreeCloseIncludesClosedIntermediate() throws {
        let f = try fixture(childActions: [.read, .send, .delegate])
        _ = try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.parentRun.id, childRunID: f.childRun.id, childThreadID: f.childRun.threadId)
        let thirdBot = try f.store.create(name: "Third", title: "Third", description: "", handle: "third", soul: "", provider: .claude, model: "opus")
        let thirdGrant = try f.store.grantContext(hostID: f.host, botID: thirdBot.id, context: f.context, actions: [.read, .send], expectedRevision: nil)
        let workspaceID: WorkspaceID? = { if case .workspace(let id) = f.context { return id }; return nil }()
        let thirdThread = AgentThread(workspaceId: workspaceID, title: "Third", provider: .distill, model: "distill")
        let thirdConversation = BotConversation(botID: thirdBot.id, title: "Third", linkedAgentThreadID: thirdThread.id)
        _ = try f.store.createContextualConversation(thirdConversation, newThread: thirdThread, hostID: f.host, context: f.context, policyRevision: thirdGrant.policyRevision)
        let thirdRun = AgentRun(threadId: thirdThread.id, provider: .distill, model: "distill", status: .running)
        try AgentRunRepository(db: f.db).upsert(thirdRun)
        _ = try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.childRun.id, childRunID: thirdRun.id, childThreadID: thirdThread.id)
        XCTAssertTrue(try f.store.authorizesContextDelegation(hostID: f.host, runID: thirdRun.id, threadID: thirdThread.id))
        _ = try f.store.revokeContext(hostID: f.host, botID: f.parentPin.botID, context: f.context, expectedRevision: f.parentPin.policyRevision)
        XCTAssertFalse(try f.store.authorizesContextDelegation(hostID: f.host, runID: thirdRun.id, threadID: thirdThread.id))
        XCTAssertTrue(try f.store.authorizes(hostID: f.host, botID: f.childPin.botID, context: f.context, action: .send, policyRevision: f.childPin.policyRevision))
        _ = try f.store.closeContextDelegationTree(runID: f.childRun.id)
        let closed = try f.store.closeContextDelegationTree(runID: f.parentRun.id)
        XCTAssertEqual(Set(closed.map(\.childRunID)), Set([f.childRun.id, thirdRun.id]))
        XCTAssertTrue(closed.allSatisfy(\.closed))
        XCTAssertEqual(try f.store.closeContextDelegationTree(runID: f.parentRun.id).count, 2)
        XCTAssertTrue(try f.store.authorizes(hostID: f.host, botID: f.childPin.botID, context: f.context, action: .send, policyRevision: f.childPin.policyRevision))
    }

    func test_cycleSelfAndForeignHostRejectWithoutWritingEdges() throws {
        let f = try fixture(childActions: [.read, .send, .delegate])
        _ = try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.parentRun.id, childRunID: f.childRun.id, childThreadID: f.childRun.threadId)
        XCTAssertThrowsError(try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.childRun.id, childRunID: f.parentRun.id, childThreadID: f.parentRun.threadId))
        let repeated = AgentThread(title: "Repeated bot", provider: .distill, model: "distill")
        let repeatedConversation = BotConversation(botID: f.parentPin.botID, title: "Repeated bot", linkedAgentThreadID: repeated.id)
        let repeatedWorkspaceID: WorkspaceID? = { if case .workspace(let id) = f.context { return id }; return nil }()
        _ = try f.store.createContextualConversation(repeatedConversation, newThread: AgentThread(id: repeated.id, workspaceId: repeatedWorkspaceID, title: "Repeated bot", provider: .distill, model: "distill"), hostID: f.host, context: f.context, policyRevision: f.parentPin.policyRevision)
        let repeatedRun = AgentRun(threadId: repeated.id, provider: .distill, model: "distill", status: .running)
        try AgentRunRepository(db: f.db).upsert(repeatedRun)
        XCTAssertThrowsError(try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.childRun.id, childRunID: repeatedRun.id, childThreadID: repeated.id))
        XCTAssertThrowsError(try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.parentRun.id, childRunID: f.parentRun.id, childThreadID: f.parentRun.threadId))
        XCTAssertThrowsError(try f.store.recordContextDelegation(hostID: "foreign-host", parentRunID: f.parentRun.id, childRunID: f.childRun.id, childThreadID: f.childRun.threadId))
        XCTAssertEqual(try f.store.contextDelegations().map(\.childRunID), [f.childRun.id])
    }

    func test_ancestorDepth64AcceptedAnd65Rejected() throws {
        let f = try fixture()
        var previousRun = f.parentRun
        var seededBots: [BotID] = []
        for index in 1...65 {
            // Exercise the ancestry ceiling independently of the live-account creation cap.
            for id in seededBots {
                try f.db.execute("UPDATE bots SET deleted_at=1 WHERE id='\(id.value.uuidString.lowercased())';")
            }
            let bot = try f.store.create(name: "Node \(index)", title: "Node \(index)", description: "", handle: "node-\(index)", soul: "", provider: .claude, model: "opus")
            seededBots.append(bot.id)
            for id in seededBots {
                try f.db.execute("UPDATE bots SET deleted_at=NULL WHERE id='\(id.value.uuidString.lowercased())';")
            }
            let grant = try f.store.grantContext(hostID: f.host, botID: bot.id, context: f.context, actions: [.read, .send, .delegate], expectedRevision: nil)
            let workspaceID: WorkspaceID? = { if case .workspace(let id) = f.context { return id }; return nil }()
            let thread = AgentThread(workspaceId: workspaceID, title: "Node \(index)", provider: .distill, model: "distill")
            let conversation = BotConversation(botID: bot.id, title: "Node \(index)", linkedAgentThreadID: thread.id)
            _ = try f.store.createContextualConversation(conversation, newThread: thread, hostID: f.host, context: f.context, policyRevision: grant.policyRevision)
            let run = AgentRun(threadId: thread.id, provider: .distill, model: "distill", status: .running)
            try AgentRunRepository(db: f.db).upsert(run)
            if index <= 64 {
                _ = try f.store.recordContextDelegation(hostID: f.host, parentRunID: previousRun.id, childRunID: run.id, childThreadID: thread.id)
                previousRun = run
            } else {
                XCTAssertThrowsError(try f.store.recordContextDelegation(hostID: f.host, parentRunID: previousRun.id, childRunID: run.id, childThreadID: thread.id))
                XCTAssertNil(try f.store.contextDelegation(childRunID: run.id))
            }
        }
        XCTAssertTrue(try f.store.authorizesContextDelegation(hostID: f.host, runID: previousRun.id, threadID: previousRun.threadId))
    }

    func test_migration95To96PreservesExistingBotBindingConversationAndPin() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 95 })
        // Seed with v95 SQL: head repositories write columns added after v95.
        let store = BotStore(db: db)
        let bot = BotID()
        let workspaceID = WorkspaceID()
        let context = BotContext.workspace(workspaceID)
        let thread = AgentThreadID()
        let conversation = BotConversationID()
        let botRaw = bot.value.uuidString.lowercased()
        let conversationRaw = conversation.value.uuidString.lowercased()
        try db.execute("""
            INSERT INTO bots(id, handle, name, title, description, avatar_symbol, created_at, updated_at)
            VALUES('\(botRaw)', 'migration', 'Migration', 'Migration', '', 'person', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
            INSERT INTO agent_threads(id, workspace_id, title, provider, provider_instance_id, model, status, created_at, updated_at)
            VALUES('\(thread.value.uuidString)', '\(workspaceID.value.uuidString)', 'Migration', 'distill', 'distill', 'distill', 'idle', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
            INSERT INTO bot_conversations(id, bot_id, title, linked_agent_thread_id, created_at, updated_at)
            VALUES('\(conversationRaw)', '\(botRaw)', 'Migration', '\(thread.value.uuidString)', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
            INSERT INTO bot_context_bindings(host_id, bot_id, context_key, contract_version, state, policy_revision, actions)
            VALUES('migration-host', '\(botRaw)', '\(context.storageKey)', \(BotContext.contractVersion), 'active', 1, 'read,send');
            INSERT INTO bot_conversation_contexts(conversation_id, host_id, bot_id, context_key, policy_revision, context_version, thread_id)
            VALUES('\(conversationRaw)', 'migration-host', '\(botRaw)', '\(context.storageKey)', 1, \(BotContext.contractVersion), '\(thread.value.uuidString)');
            """)
        let pin = BotConversationContextPin(conversationID: conversation, hostID: "migration-host", botID: bot, context: context, policyRevision: 1)
        try Schema.migrate(db)
        XCTAssertEqual(try store.get(id: bot)?.id, bot)
        XCTAssertTrue(try store.authorizes(hostID: "migration-host", botID: bot, context: context, action: .read, policyRevision: 1))
        XCTAssertTrue(try store.authorizes(hostID: "migration-host", botID: bot, context: context, action: .send, policyRevision: 1))
        let savedConversation = try store.conversation(id: conversation)
        XCTAssertEqual(savedConversation?.id, conversation)
        XCTAssertEqual(savedConversation?.botID, bot)
        XCTAssertEqual(savedConversation?.linkedAgentThreadID, thread)
        XCTAssertEqual(try store.conversationContextPin(linkedTo: thread), pin)
        XCTAssertTrue(try store.contextDelegations().isEmpty)
    }

    func test_sqlCannotMutateOrDeleteDelegationAndClosePersists() throws {
        let f = try fixture()
        let edge = try f.store.recordContextDelegation(hostID: f.host, parentRunID: f.parentRun.id, childRunID: f.childRun.id, childThreadID: f.childRun.threadId)
        let rowID = f.childRun.id.value.uuidString.lowercased()
        XCTAssertThrowsError(try f.db.execute("UPDATE bot_context_delegations SET payload_json='{}' WHERE child_run_id='\(rowID)';"))
        XCTAssertThrowsError(try f.db.execute("UPDATE bot_context_delegations SET parent_run_id='\(UUID().uuidString.lowercased())' WHERE child_run_id='\(rowID)';"))
        XCTAssertThrowsError(try f.db.execute("UPDATE bot_context_delegations SET child_run_id=upper(child_run_id) WHERE child_run_id='\(rowID)';"))
        XCTAssertThrowsError(try f.db.execute("UPDATE bot_context_delegations SET parent_run_id=upper(parent_run_id) WHERE child_run_id='\(rowID)';"))
        XCTAssertNoThrow(try f.db.execute("UPDATE bot_context_delegations SET closed=1 WHERE child_run_id='\(rowID)';"))
        _ = try f.store.closeContextDelegationTree(runID: f.parentRun.id)
        XCTAssertEqual(try f.store.contextDelegations().first(where: { $0.childRunID == edge.childRunID })?.closed, true)
        XCTAssertThrowsError(try f.db.execute("UPDATE bot_context_delegations SET closed=0 WHERE child_run_id='\(rowID)';"))
        XCTAssertThrowsError(try f.db.execute("DELETE FROM bot_context_delegations WHERE child_run_id='\(rowID)';"))
        XCTAssertEqual(try f.store.contextDelegations().first(where: { $0.childRunID == edge.childRunID })?.closed, true)
        XCTAssertThrowsError(try f.db.execute("INSERT OR REPLACE INTO bot_context_delegations(child_run_id,parent_run_id,payload_json,closed) VALUES('\(rowID)','\(f.parentRun.id.value.uuidString.lowercased())','{}',0);"))

        let malformedID = AgentRunID()
        let malformedRaw = malformedID.value.uuidString.lowercased()
        try f.db.execute("INSERT INTO bot_context_delegations(child_run_id,parent_run_id,payload_json,closed) VALUES('\(malformedRaw)','\(f.parentRun.id.value.uuidString.lowercased())','{}',0);")
        XCTAssertThrowsError(try f.store.contextDelegation(childRunID: malformedID))
        let uppercaseID = AgentRunID()
        let uppercaseRaw = uppercaseID.value.uuidString.uppercased()
        try f.db.execute("INSERT INTO bot_context_delegations(child_run_id,parent_run_id,payload_json,closed) VALUES('\(uppercaseRaw)','\(f.parentRun.id.value.uuidString.lowercased())','{}',0);")
        XCTAssertThrowsError(try f.store.contextDelegation(childRunID: uppercaseID))
    }
}
