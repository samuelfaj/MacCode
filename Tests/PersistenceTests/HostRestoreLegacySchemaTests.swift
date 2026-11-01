import Foundation
import XCTest
import CoreModel
@testable import Persistence

final class HostRestoreLegacySchemaTests: XCTestCase {
    private struct Fixture: Codable {
        let botA: BotID
        let botB: BotID
        let workspace: WorkspaceID
        let agentThread: AgentThreadID
        let botThread: AgentThreadID
        let conversation: BotConversationID
        let agentQueue: AgentQueuedMessageID
        let knownQueue: AgentQueuedMessageID
        let botQueue: String
        let message: AgentMessageID
        let stoppedRun: AgentRunID
        let importedRun: AgentRunID
        let routine: BotRoutineID
        let task: UUID
        let scheduledRun: UUID
    }

    private func makeFixture(_ root: URL) throws -> Fixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let attachmentStore = AgentAttachmentStore(root: root.appendingPathComponent("app-support/agent-attachments", isDirectory: true))
        let attachment = try attachmentStore.stage(data: Data("Synthetic legacy attachment".utf8), displayName: "legacy-attachment.txt", kind: .file, mimeType: "text/plain")
        let source = try SQLiteDB(path: root.appendingPathComponent("legacy93.sqlite").path)
        do {
            let legacy = try Schema.trustedRestoreSchema(version: 93)
            try legacy.backup(to: source)
        }
        let store = BotStore(db: source)
        let workspace = WorkspaceID()
        let a = try store.create(name: "Legacy affinity A", title: "A", description: "", soul: "", provider: .distill, model: "test", desktopKind: .logicalExecutionSpace, workspaceID: workspace)
        let b = try store.create(name: "Legacy B", title: "B", description: "", soul: "", provider: .distill, model: "test", desktopKind: .logicalExecutionSpace)
        var agent = AgentThread(title: "Legacy Agent", provider: .distill, model: "test")
        agent.status = .running
        var botThread = AgentThread(title: "Legacy Bot", provider: .distill, model: "test")
        botThread.status = .running
        let threads = AgentThreadRepository(db: source)
        try threads.upsert(agent)
        try threads.upsert(botThread)
        let actor = try source.prepare("UPDATE agent_threads SET actor_json = ?, actor_locked_at = ?, execution_target = ? WHERE id = ?;")
        try actor.bind(1, String(decoding: JSONEncoder().encode(RunActor.bot(b.id)), as: UTF8.self))
        try actor.bind(2, "2023-11-14T22:13:20Z")
        try actor.bind(3, ExecutionTarget.mac.rawValue)
        try actor.bind(4, botThread.id.value.uuidString)
        _ = try actor.step()
        let changed = try source.prepare("SELECT changes();")
        XCTAssertTrue(try changed.step())
        XCTAssertEqual(changed.columnInt64(0), 1, "The version-93 fixture must lock its actor using only columns that existed in that schema")
        let conversation = BotConversation(botID: b.id, title: "Legacy Bot", linkedAgentThreadID: botThread.id)
        try store.upsertConversation(conversation)
        let message = AgentMessage(threadId: agent.id, role: .user, content: "LEGACY_HISTORY_PRIVATE")
        try AgentMessageRepository(db: source).append(message)
        let queued = try AgentQueuedMessageRepository(db: source).enqueue(threadId: agent.id, text: "LEGACY_AGENT_QUEUE_PRIVATE", attachments: [], interactionMode: .default)
        let knownQueue = try AgentQueuedMessageRepository(db: source).enqueue(threadId: agent.id, text: "LEGACY_KNOWN_QUEUE_PRIVATE", attachments: [attachment], interactionMode: .default)
        let botQueue = try store.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(botID: b.id, conversationID: conversation.id.value.uuidString.lowercased(), text: "LEGACY_BOT_QUEUE_PRIVATE"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spec = BotScheduleSpec(provider: .distill, providerInstanceID: "distill-acp", model: "test", frequency: .daily, localTime: base.addingTimeInterval(60), timeZoneIdentifier: "UTC")
        let routine = BotRoutineDefinition(botID: b.id, name: "Legacy routine", prompt: "LEGACY_ROUTINE_PRIVATE", scheduleNote: spec.displayNote(), scheduleSpecJSON: spec.encodedJSON(), createdAt: base, updatedAt: base)
        try store.saveRoutine(routine, now: base)
        try store.setRoutineEnabled(id: routine.id, enabled: true, now: base)
        let task = ScheduledTask(title: "Legacy task", prompt: "LEGACY_TASK_PRIVATE", workspaceID: workspace,
                                 workspacePathSnapshot: root.path, runAsUser: "fixture-user", runAsUID: 501,
                                 provider: .distill, providerInstanceID: "distill-acp", model: "test", reasoningEffort: .high,
                                 recurrence: .daily(at: ScheduledLocalTime(hour: 8, minute: 15)!), timeZoneIdentifier: "UTC",
                                 isEnabled: true, nextRunAt: base, createdAt: base, updatedAt: base)
        // The store writes v100 run-option columns; a v93 source gets them only while seeding.
        let runOptionColumns = ["distill_ultracode INTEGER NOT NULL DEFAULT 0", "permission_mode TEXT NOT NULL DEFAULT 'full_access'",
                                "interaction_mode TEXT NOT NULL DEFAULT 'default'", "execution_mode TEXT NOT NULL DEFAULT 'local'", "base_branch TEXT"]
        for column in runOptionColumns { try source.execute("ALTER TABLE scheduled_tasks ADD COLUMN \(column);") }
        try ScheduledTaskStore(db: source).save(task)
        let stopped = AgentRun(threadId: agent.id, provider: .distill, model: "test", status: .running)
        let imported = AgentRun(threadId: botThread.id, provider: .distill, model: "test", status: .running)
        try AgentRunRepository(db: source).upsert(stopped)
        try AgentRunRepository(db: source).upsert(imported)
        let scheduleStore = ScheduledTaskStore(db: source)
        let scheduled = try XCTUnwrap(scheduleStore.claimDue(now: base, owner: "legacy-source").first)
        try scheduleStore.attachThread(runID: scheduled.run.id, threadID: agent.id)
        try scheduleStore.markStarted(runID: scheduled.run.id, threadID: agent.id, agentRunID: stopped.id)
        for column in runOptionColumns.reversed() {
            try source.execute("ALTER TABLE scheduled_tasks DROP COLUMN \(column.split(separator: " ")[0]);")
        }
        let authority = BotRemoteControlAuthority(db: source, store: store, settings: SettingsStore(db: source), appSupportDirectory: root)
        _ = try authority.dispatch(method: "bot.routing.set", params: ["client_request_id": "legacy-main-route", "host_id": "legacy-host", "bot_id": b.id.value.uuidString.lowercased(), "provider": "distill", "provider_instance_id": "distill-acp", "model": "test"])
        let current = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path)
        try source.backup(to: current)
        try Schema.migrate(current)
        let currentStore = BotStore(db: current)
        _ = try currentStore.grantContext(hostID: "legacy-host", botID: a.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        _ = try currentStore.revokeContext(hostID: "legacy-host", botID: a.id, context: .general, expectedRevision: 1)
        try AgentRunRepository(db: current).markStopped(id: stopped.id)
        let knownOutcome = AgentRun(id: AgentRunID(knownQueue.id.value), threadId: agent.id, provider: .distill, model: "test", status: .running)
        try AgentRunRepository(db: current).upsert(knownOutcome)
        try AgentRunRepository(db: current).markStopped(id: knownOutcome.id)
        try ScheduledTaskStore(db: current).finish(runID: scheduled.run.id, status: .cancelled, errorCode: "user_stop")
        do {
            let remove = try current.prepare("DELETE FROM agent_runs WHERE id=?;")
            defer { remove.reset() }
            try remove.bind(1, imported.id.value.uuidString)
            _ = try remove.step()
        }
        try SettingsRepository(db: current).set("server_id", "legacy-host")
        SettingsStore(db: current).update { settings in
            settings.botsControlPlaneEnabled = true
            settings.botsAutonomyEnabled = true
        }
        return Fixture(botA: a.id, botB: b.id, workspace: workspace, agentThread: agent.id, botThread: botThread.id,
                       conversation: conversation.id, agentQueue: queued.id, knownQueue: knownQueue.id, botQueue: botQueue.id,
                       message: message.id, stoppedRun: stopped.id, importedRun: imported.id, routine: routine.id, task: task.id, scheduledRun: scheduled.run.id)
    }

    private func assertPaused(_ root: URL, _ fixture: Fixture) throws {
        let db = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path)
        let store = BotStore(db: db)
        XCTAssertEqual(try store.get(id: fixture.botA)?.workspaceID, fixture.workspace)
        XCTAssertEqual(try store.getContextBinding(hostID: "legacy-host", botID: fixture.botA, context: .general)?.state, .revoked)
        XCTAssertEqual(try store.getContextBinding(hostID: "legacy-host", botID: fixture.botA, context: .general)?.policyRevision, 2)
        XCTAssertTrue(try store.listContextBindings(hostID: "legacy-host", botID: fixture.botB).isEmpty)
        XCTAssertNil(try store.getContextBinding(hostID: "legacy-host", botID: fixture.botA, context: .workspace(fixture.workspace)))
        let history = try AgentMessageRepository(db: db).list(threadId: fixture.agentThread)
        XCTAssertEqual(history.map(\.id), [fixture.message])
        XCTAssertEqual(history.first?.content, "LEGACY_HISTORY_PRIVATE")
        XCTAssertEqual(try store.conversation(id: fixture.conversation)?.linkedAgentThreadID, fixture.botThread)
        XCTAssertEqual(try AgentThreadRepository(db: db).lockedBotActor(of: fixture.botThread), fixture.botB)
        let queue = AgentQueuedMessageRepository(db: db)
        let row = try XCTUnwrap(queue.get(id: fixture.agentQueue))
        XCTAssertEqual(row.text, "LEGACY_AGENT_QUEUE_PRIVATE")
        XCTAssertTrue(row.attachments.isEmpty)
        let historical = try XCTUnwrap(queue.get(id: fixture.knownQueue))
        XCTAssertEqual(historical.attachments.first?.displayName, "legacy-attachment.txt")
        let attachment = try XCTUnwrap(historical.attachments.first)
        let attachmentStore = AgentAttachmentStore(root: root.appendingPathComponent("app-support/agent-attachments", isDirectory: true))
        XCTAssertEqual(try attachmentStore.containedData(for: attachment), Data("Synthetic legacy attachment".utf8))
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: fixture.agentQueue.value.uuidString, db: db))
        XCTAssertNil(try queue.claimFirst(threadId: fixture.agentThread))
        XCTAssertNil(try queue.claim(id: fixture.agentQueue))
        XCTAssertEqual(try queue.get(id: fixture.agentQueue), row)
        let botRows = try store.listQueuedFollowUps(botID: fixture.botB)
        XCTAssertEqual(botRows.map(\.id), [fixture.botQueue])
        XCTAssertEqual(botRows.first?.text, "LEGACY_BOT_QUEUE_PRIVATE")
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: fixture.botQueue, db: db))
        XCTAssertNil(try store.dequeueQueuedFollowUp(botID: fixture.botB))
        XCTAssertEqual(try store.listQueuedFollowUps(botID: fixture.botB), botRows)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: fixture.stoppedRun)?.status, .cancelled)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: AgentRunID(fixture.knownQueue.value))?.status, .cancelled)
        XCTAssertEqual(try AgentRunRepository(db: db).get(id: fixture.importedRun)?.status, .interrupted)
        XCTAssertTrue(try store.listEnabledRoutines().isEmpty)
        XCTAssertNotNil(try store.listRoutines(botID: fixture.botB).first { $0.definition.id == fixture.routine })
        let tasks = ScheduledTaskStore(db: db)
        XCTAssertEqual(try tasks.get(id: fixture.task)?.isEnabled, false)
        XCTAssertTrue(try tasks.listActiveRuns().isEmpty)
        XCTAssertEqual(try tasks.listRuns(taskID: fixture.task).first(where: { $0.id == fixture.scheduledRun })?.status, .cancelled)
        XCTAssertTrue(try tasks.claimDue(now: Date(), owner: "legacy-review-test").isEmpty)
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: SettingsStore(db: db), appSupportDirectory: root)
        var sends = 0
        authority.onRoutineSend = { _ in sends += 1; return [:] }
        XCTAssertTrue(try authority.claimDueRoutines(now: Date()).isEmpty)
        XCTAssertEqual(sends, 0)
    }

    func testTrustedLegacySchemaRemainsLegacyUntilRealMigration() throws {
        for version in [93, 96, Schema.hostRestoreQueueHoldsSchemaVersion, Schema.relayKeysSchemaVersion, Schema.currentVersion] {
            let db = try Schema.trustedRestoreSchema(version: version)
            let meta = try db.prepare("SELECT MAX(version) FROM schema_meta;")
            XCTAssertTrue(try meta.step())
            XCTAssertEqual(meta.columnInt64(0), Int64(version))
            meta.reset()
            try Schema.migrate(db)
            let holds = try db.prepare("SELECT COUNT(*) FROM host_restore_queue_holds;")
            XCTAssertTrue(try holds.step())
            XCTAssertEqual(holds.columnInt64(0), 0)
            holds.reset()
        }
        XCTAssertThrowsError(try Schema.trustedRestoreSchema(version: 94))
    }

    func testLegacyAdoptionRequiresExactReviewAndNeverAutoResumes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostLegacy-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        let source = root.appendingPathComponent("legacy93.sqlite")
        let current = root.appendingPathComponent("current.sqlite")
        let before = try Data(contentsOf: source)
        let review = try HostDatabaseRestore.inspect(backupURL: source)
        XCTAssertEqual(review.schemaVersion, 93)
        XCTAssertEqual(try HostDatabaseRestore.inspect(backupURL: source).fingerprint, review.fingerprint)
        XCTAssertEqual(review.agentQueueIDs.sorted(), [fixture.agentQueue.value.uuidString, fixture.knownQueue.value.uuidString].sorted())
        XCTAssertEqual(review.botQueueIDs, [fixture.botQueue])
        XCTAssertEqual(review.routineIDs, [fixture.routine.value.uuidString.lowercased()])
        XCTAssertEqual(review.scheduledTaskIDs.map { $0.lowercased() }, [fixture.task.uuidString.lowercased()])
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: source, currentURL: current))
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: source, currentURL: current, reviewToken: String(repeating: "0", count: 64)))
        _ = try HostDatabaseRestore.restore(backupURL: source, currentURL: current, reviewToken: review.fingerprint)
        try assertPaused(root, fixture)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let reopened = try SQLiteDB(path: current.path)
        try Schema.migrate(reopened)
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: fixture.agentQueue.value.uuidString, db: reopened))
        let tasks = ScheduledTaskStore(db: reopened)
        try tasks.setEnabled(id: fixture.task, enabled: true, nextRunAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(try tasks.claimDue(now: Date(), owner: "spent-occurrence-test").isEmpty)
        let freshOccurrence = Date()
        try tasks.setEnabled(id: fixture.task, enabled: true, nextRunAt: freshOccurrence)
        XCTAssertEqual(try tasks.claimDue(now: freshOccurrence.addingTimeInterval(1), owner: "explicit-enable-test").map { $0.task.id }, [fixture.task])
        let store = BotStore(db: reopened)
        try store.setRoutineEnabled(id: fixture.routine, enabled: true)
        XCTAssertEqual(try store.listEnabledRoutines().map { $0.definition.id }, [fixture.routine])
    }

    func testChangedBackupOrConflictingCurrentQueueCannotBeAdopted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostLegacy-stale-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        let source = root.appendingPathComponent("legacy93.sqlite")
        let current = root.appendingPathComponent("current.sqlite")
        let oldReview = try HostDatabaseRestore.inspect(backupURL: source)
        do {
            let db = try SQLiteDB(path: source.path)
            _ = try AgentQueuedMessageRepository(db: db).update(id: fixture.agentQueue, text: "Changed after preview", attachments: [])
        }
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: source, currentURL: current, reviewToken: oldReview.fingerprint))
        let newReview = try HostDatabaseRestore.inspect(backupURL: source)
        XCTAssertNotEqual(newReview.fingerprint, oldReview.fingerprint)
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: source, currentURL: current, reviewToken: newReview.fingerprint)) {
            XCTAssertTrue(String(describing: $0).contains("current queued intent"))
        }
        let db = try SQLiteDB(path: current.path, readonly: true)
        XCTAssertEqual(try AgentQueuedMessageRepository(db: db).get(id: fixture.agentQueue)?.text, "LEGACY_AGENT_QUEUE_PRIVATE")
        XCTAssertEqual(try BotStore(db: db).getContextBinding(hostID: "legacy-host", botID: fixture.botA, context: .general)?.state, .revoked)
    }

    func testMalformedBotQueueIDCannotEscapeRestoreReviewHold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostLegacy-bad-id-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        let source = root.appendingPathComponent("legacy93.sqlite")
        let current = root.appendingPathComponent("current.sqlite")
        do {
            let db = try SQLiteDB(path: source.path)
            try db.execute("UPDATE bot_queued_follow_ups SET id='not-a-uuid';")
        }
        XCTAssertThrowsError(try HostDatabaseRestore.inspect(backupURL: source)) {
            XCTAssertTrue(String(describing: $0).contains("noncanonical identifier"))
        }
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: source, currentURL: current, reviewToken: String(repeating: "0", count: 64)))
        let db = try SQLiteDB(path: current.path, readonly: true)
        XCTAssertEqual(try BotStore(db: db).listQueuedFollowUps(botID: fixture.botB).map(\.id), [fixture.botQueue])
    }

    func testCurrentInteractionAndRoutingCannotBeSilentlyRolledBack() throws {
        for change in ["mode", "routing", "source-routing-case"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostLegacy-intent-\(change)-\(UUID())")
            defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
            let fixture = try makeFixture(root)
            let source = root.appendingPathComponent("legacy93.sqlite")
            let current = root.appendingPathComponent("current.sqlite")
            let review = try HostDatabaseRestore.inspect(backupURL: source)
            do {
                let db = try SQLiteDB(path: change == "source-routing-case" ? source.path : current.path)
                if change == "source-routing-case" {
                    let update = try db.prepare("UPDATE agent_queued_messages SET id=lower(id) WHERE id=?;")
                    defer { update.reset() }
                    try update.bind(1, fixture.agentQueue.value.uuidString)
                    _ = try update.step()
                }
                if change == "mode" {
                    let update = try db.prepare("UPDATE agent_queued_messages SET interaction_mode='plan' WHERE id=?;")
                    defer { update.reset() }
                    try update.bind(1, fixture.agentQueue.value.uuidString)
                    _ = try update.step()
                } else {
                    let insert = try db.prepare("INSERT INTO agent_queued_message_routing(queued_message_id,configuration_json,revision,created_at) VALUES(?, '{\"permission_mode\":\"read-only\"}', 7, '2026-01-01T00:00:00Z');")
                    defer { insert.reset() }
                    try insert.bind(1, change == "source-routing-case" ? fixture.agentQueue.value.uuidString.lowercased() : fixture.agentQueue.value.uuidString)
                    _ = try insert.step()
                }
            }
            let confirmed = change == "source-routing-case" ? try HostDatabaseRestore.inspect(backupURL: source) : review
            XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: source, currentURL: current, reviewToken: confirmed.fingerprint)) {
                XCTAssertTrue(String(describing: $0).contains("current queued intent"))
            }
            let db = try SQLiteDB(path: current.path, readonly: true)
            XCTAssertEqual(try BotStore(db: db).getContextBinding(hostID: "legacy-host", botID: fixture.botA, context: .general)?.policyRevision, 2)
        }
    }

    func testRecordQueueAttemptOnlyUpdatesExistingAgentRestoreHold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostLegacy-attempt-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: root.appendingPathComponent("current.sqlite").path)
        try Schema.migrate(db)
        let ordinary = AgentRunID()
        try HostDatabaseRestore.recordQueueAttempt(kind: .agent, id: "ordinary-agent-queue", runID: ordinary, db: db)
        let count = try db.prepare("SELECT COUNT(*) FROM host_restore_queue_holds WHERE kind='agent' AND queue_id='ordinary-agent-queue';")
        defer { count.reset() }
        XCTAssertTrue(try count.step())
        XCTAssertEqual(count.columnInt64(0), 0)
        XCTAssertNil(try HostDatabaseRestore.queueAttempt(kind: .agent, id: "ordinary-agent-queue", db: db))

        try HostDatabaseRestore.pauseQueue(kind: .agent, id: "restored-agent-queue", db: db)
        let restoredAttempt = AgentRunID()
        try HostDatabaseRestore.recordQueueAttempt(kind: .agent, id: "restored-agent-queue", runID: restoredAttempt, db: db)
        XCTAssertEqual(try HostDatabaseRestore.queueAttempt(kind: .agent, id: "restored-agent-queue", db: db), restoredAttempt)
    }

    func testSnapshotlessQueueRejectsChangedThreadFallbackExecutionSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostLegacy-fallback-\(UUID())")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let fixture = try makeFixture(root)
        let source = root.appendingPathComponent("legacy93.sqlite")
        let current = root.appendingPathComponent("current.sqlite")
        do {
            let db = try SQLiteDB(path: source.path)
            try db.execute("UPDATE agent_threads SET provider='claude',provider_instance_id='claude-acp',model='source-model',permission_mode='full_access' WHERE id='\(fixture.agentThread.value.uuidString)';")
        }
        do {
            let db = try SQLiteDB(path: current.path)
            try db.execute("UPDATE agent_threads SET provider='codex',provider_instance_id='codex-acp',model='current-model',permission_mode='supervised' WHERE id='\(fixture.agentThread.value.uuidString)';")
            let snapshot = try db.prepare("SELECT COUNT(*) FROM agent_queued_message_routing WHERE queued_message_id=?;")
            defer { snapshot.reset() }
            try snapshot.bind(1, fixture.agentQueue.value.uuidString)
            XCTAssertTrue(try snapshot.step())
            XCTAssertEqual(snapshot.columnInt64(0), 0)
        }
        let review = try HostDatabaseRestore.inspect(backupURL: source)
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: source, currentURL: current, reviewToken: review.fingerprint)) {
            XCTAssertTrue(String(describing: $0).contains("current queued intent"))
        }
        let db = try SQLiteDB(path: current.path, readonly: true)
        let thread = try db.prepare("SELECT provider,provider_instance_id,model,permission_mode FROM agent_threads WHERE id=?;")
        defer { thread.reset() }
        try thread.bind(1, fixture.agentThread.value.uuidString)
        XCTAssertTrue(try thread.step())
        XCTAssertEqual(thread.columnText(0), "codex")
        XCTAssertEqual(thread.columnText(1), "codex-acp")
        XCTAssertEqual(thread.columnText(2), "current-model")
        XCTAssertEqual(thread.columnText(3), "supervised")
    }

    func test_exportLegacyHostRestoreFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["RC_HOST_RESTORE_LEGACY_FIXTURE_ROOT"] else { throw XCTSkip("set isolated legacy restore fixture root") }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path.contains("/.sandbox-worktrees/"), root.path.contains("/.sandbox-state/host-legacy-"), !FileManager.default.fileExists(atPath: root.path) else { throw SQLiteError.open("legacy fixture requires a fresh isolated directory") }
        try JSONEncoder().encode(makeFixture(root)).write(to: root.appendingPathComponent("fixture.json"))
    }

    func test_verifyLegacyHostRestoreFixture() throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_RESTORE_LEGACY_VERIFY"] == "1",
              let path = ProcessInfo.processInfo.environment["RC_HOST_RESTORE_LEGACY_FIXTURE_ROOT"] else { throw XCTSkip("set isolated legacy restore verification") }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path.contains("/.sandbox-worktrees/"), root.path.contains("/.sandbox-state/host-legacy-") else { throw SQLiteError.open("legacy verification requires an isolated directory") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        try assertPaused(root, fixture)
    }
}
