import XCTest
import CoreModel
@testable import Persistence

final class BotRemoteControlAuthorityTests: XCTestCase {
    private let guestHostID = "test-host"
    private var db: SQLiteDB!
    private var store: BotStore!
    private var settings: SettingsStore!
    private var authority: BotRemoteControlAuthority!
    private var supportDir: URL!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
        settings = SettingsStore(db: db)
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
    }

    override func tearDown() {
        authority = nil
        settings = nil
        store = nil
        db = nil
        if let supportDir {
            try? FileManager.default.removeItem(at: supportDir)
        }
        supportDir = nil
    }

    func testTaskReadbackUsesExactRunAndRejectsForeignSource() throws {
        let bot = try store.create(name: "Reader", title: "Task", description: "", handle: "reader", avatarSymbol: "circle")
        let source = AgentThread(workspaceId: nil, title: "Parent", provider: .distill, model: "main")
        let child = AgentThread(workspaceId: nil, title: "Task", provider: .distill, model: "main")
        let threads = AgentThreadRepository(db: db)
        try threads.upsert(source); try threads.upsert(child)
        let conversation = BotConversation(botID: bot.id, title: "Task", linkedAgentThreadID: child.id)
        try store.upsertConversation(conversation)
        let run = AgentRun(threadId: child.id, provider: .distill, model: "main", status: .failed)
        try AgentRunRepository(db: db).upsert(run)
        let task = BotParallelTask(botID: bot.id, conversationID: conversation.id, threadID: child.id, runID: run.id, title: "Task")
        try AgentMessageRepository(db: db).append(AgentMessage(id: AgentMessageID(run.id.value),
            threadId: source.id, role: .assistant, content: task.transcript))
        let params: [String: Any] = ["bot_id": bot.id.value.uuidString,
            "source_thread_id": source.id.value.uuidString, "task_run_id": run.id.value.uuidString]
        let result = try authority.dispatch(method: "bot.conversation.list", params: params)
        XCTAssertEqual((result["task"] as? [String: Any])?["status"] as? String, "failed")
        XCTAssertEqual((result["task"] as? [String: Any])?["run_id"] as? String, run.id.value.uuidString.lowercased())
        var forged = params; forged["source_thread_id"] = child.id.value.uuidString
        XCTAssertThrowsError(try authority.dispatch(method: "bot.conversation.list", params: forged))
        let after = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id": bot.id.value.uuidString])
        XCTAssertNil(after["selected_id"], "Observing a task never selects the destination conversation")
    }

    func testTaskReadbackResolvesAuthorizedContextAndRefusesRevokedGrant() throws {
        let bot = try store.create(name: "Scoped Reader", title: "Task", description: "", handle: "scoped-reader")
        let source = AgentThread(workspaceId: nil, title: "Parent", provider: .distill, model: "main")
        try AgentThreadRepository(db: db).upsert(source)
        let grant = try store.grantContext(hostID: "audit-host", botID: bot.id, context: .general, actions: [.read, .send], expectedRevision: nil)
        let child = AgentThread(workspaceId: nil, title: "Scoped task", provider: .distill, model: "main")
        let conversation = BotConversation(botID: bot.id, title: "Scoped", linkedAgentThreadID: child.id)
        _ = try store.createContextualConversation(conversation, newThread: child, hostID: "audit-host", context: .general, policyRevision: grant.policyRevision)
        let run = AgentRun(threadId: child.id, provider: .distill, model: "main", status: .completed)
        try AgentRunRepository(db: db).upsert(run)
        let task = BotParallelTask(botID: bot.id, conversationID: conversation.id, threadID: child.id, runID: run.id, title: "Scoped")
        try AgentMessageRepository(db: db).append(AgentMessage(id: AgentMessageID(run.id.value), threadId: source.id, role: .assistant, content: task.transcript))
        let params: [String: Any] = ["bot_id":bot.id.value.uuidString, "source_thread_id":source.id.value.uuidString, "task_run_id":run.id.value.uuidString]
        let legacy = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id":bot.id.value.uuidString])
        XCTAssertTrue((legacy["conversations"] as? [[String:Any]])?.isEmpty == true)
        let result = try authority.dispatch(method: "bot.conversation.list", params: params)
        XCTAssertEqual((result["task"] as? [String:Any])?["status"] as? String, "completed")
        XCTAssertEqual((result["conversations"] as? [[String:Any]])?.first?["context_key"] as? String, "general:v1")
        _ = try store.grantContext(hostID: "audit-host", botID: bot.id, context: .general, actions: [], expectedRevision: grant.policyRevision)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.conversation.list", params: params), "A persisted source link is not a permanent authorization grant")
    }

    private func guestState(botID: String) throws -> [String: Any] {
        try authority.dispatch(method: "bot.guest.state", params: [
            "bot_id": botID,
            "host_id": guestHostID,
        ])
    }

    private func guestTask(botID: String, axis: String) throws -> [String: Any] {
        let state = try guestState(botID: botID)
        let catalog = try XCTUnwrap(state["task_catalog"] as? [String: Any])
        let tasks = try XCTUnwrap(catalog["tasks"] as? [[String: Any]])
        return try XCTUnwrap(tasks.first { $0["axis"] as? String == axis })
    }

    private func guestStartParams(botID: String, requestID: String) throws -> [String: Any] {
        let task = try guestTask(botID: botID, axis: "start")
        return [
            "client_request_id": requestID,
            "bot_id": botID,
            "host_id": guestHostID,
            "task_id": try XCTUnwrap(task["id"] as? String),
            "recipe_id": try XCTUnwrap(task["recipe_id"] as? String),
        ]
    }

    private func runningGuest(botID: String) throws -> [String: Any] {
        let started = try authority.dispatch(
            method: "bot.guest.start",
            params: guestStartParams(botID: botID, requestID: "prepare-\(UUID().uuidString)")
        )
        var state = try XCTUnwrap(started["readback"] as? [String: Any])
        let runtime = try XCTUnwrap(state["runtime"] as? [String: Any])
        state["status"] = "running"
        state["frame"] = [
            "runtime": runtime,
            "frame_id": UUID().uuidString.lowercased(),
            "sequence": 0,
            "pixel_width": 1_600,
            "pixel_height": 1_200,
            "png_base64": "",
            "png_hash": "test",
        ]
        authority.settle(
            requestID: try XCTUnwrap(started["request_id"] as? String),
            status: .completed,
            readback: state
        )
        return try guestState(botID: botID)
    }

    private func sidecarObject(_ key: String) throws -> [String: Any] {
        let statement = try db.prepare("SELECT value FROM settings WHERE key = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, key)
        guard try statement.step(),
              let text = statement.columnText(0),
              let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func sidecarStringSet(_ key: String) throws -> Set<String> {
        let statement = try db.prepare("SELECT value FROM settings WHERE key = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, key)
        guard try statement.step(),
              let text = statement.columnText(0),
              let data = text.data(using: .utf8),
              let values = try JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return Set(values)
    }

    private func createLiveBot(
        prefix: String,
        name: String
    ) throws -> (botID: String, conversationID: String, runID: String) {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "\(prefix)-create", "name": name,
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "\(prefix)-conversation", "bot_id": botID, "title": "\(name) thread",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let sent = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "\(prefix)-send", "bot_id": botID, "text": "\(name) work",
        ])
        let runID = try XCTUnwrap((sent["readback"] as? [String: Any])?["run_id"] as? String)
        return (botID, conversationID, runID)
    }

    private func createBotConversation(prefix: String) throws -> (botID: String, conversationID: String) {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "\(prefix)-create",
            "name": prefix,
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "\(prefix)-conversation",
            "bot_id": botID,
            "title": prefix,
        ])
        return (
            botID,
            try XCTUnwrap((conversation["readback"] as? [String: Any])?["conversation_id"] as? String)
        )
    }

    private func stageAttachment(
        prefix: String,
        botID: String,
        conversationID: String
    ) throws -> String {
        let staged = try authority.dispatch(method: "bot.attachment.stage", params: [
            "client_request_id": "\(prefix)-stage",
            "bot_id": botID,
            "conversation_id": conversationID,
            "attachment_id": "rcatt1_\(String(repeating: "a", count: 32))",
            "filename": "\(prefix).txt",
            "kind": "file",
            "digest": String(repeating: "b", count: 64),
            "size": 4,
        ])
        return try XCTUnwrap((staged["readback"] as? [String: Any])?["id"] as? String)
    }

    func test_settingsSet_failsWithoutRequestId_becauseSilentLocalSuccessIsForbidden() {
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.settings.set", params: [
                "key": "control_plane",
                "value": false,
            ])
        ) { error in
            let remote = error as? BotRemoteControlAuthority.Error
            XCTAssertEqual(remote, .missingRequest)
        }
    }

    func test_settingsSet_returnsReceiptAndEffectiveReadback_becauseOptimisticWriteCannotMaskFailure() throws {
        let result = try authority.dispatch(method: "bot.settings.set", params: [
            "client_request_id": "set-1",
            "key": "effects",
            "value": true,
        ])
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertNotNil(result["receipt_id"] as? String)
        let readback = result["readback"] as? [String: Any]
        let raw = readback?["raw"] as? [String: Bool]
        let effective = readback?["effective"] as? [String: Bool]
        XCTAssertEqual(raw?["effects"], true)
        XCTAssertEqual(effective?["effects"], false, "Effects stay unavailable even when raw persisted true")
        XCTAssertEqual(effective?["channels"], false)
    }

    func test_effectsAndChannels_remainIneffectiveWhenRawTrue() throws {
        _ = try authority.dispatch(method: "bot.settings.set", params: [
            "client_request_id": "ch-1",
            "key": "channels",
            "value": true,
        ])
        let read = try authority.dispatch(method: "bot.settings.get", params: [:])
        let effective = read["effective"] as? [String: Bool]
        XCTAssertEqual(effective?["channels"], false)
        XCTAssertEqual(effective?["effects"], false)
    }

    /// WHY: Studio's authored Instructions are revision-owned. A successful
    /// soul mutation is not authoritative to iOS unless both exact read paths
    /// expose the newly published revision for the same Bot.
    func test_soulSetExposesExactPublishedRevisionThroughGetAndList() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "soul-create",
            "name": "Soul Owner",
            "soul": "Original instructions",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let originalRevisionID = try XCTUnwrap(
            try store.get(id: BotID(try XCTUnwrap(UUID(uuidString: botID))))?.currentRevisionID
        )

        let changed = try authority.dispatch(method: "bot.soul.set", params: [
            "client_request_id": "soul-change",
            "bot_id": botID,
            "soul": "Own the exact support inbox.",
        ])
        let readback = try XCTUnwrap(changed["readback"] as? [String: Any])
        let publishedRevisionID = try XCTUnwrap(readback["current_revision_id"] as? String)
        XCTAssertEqual(readback["soul"] as? String, "Own the exact support inbox.")
        XCTAssertNotEqual(publishedRevisionID, originalRevisionID.value.uuidString.lowercased())

        let got = try authority.dispatch(method: "bot.get", params: ["bot_id": botID])
        XCTAssertEqual(got["id"] as? String, botID)
        XCTAssertEqual(got["soul"] as? String, "Own the exact support inbox.")
        XCTAssertEqual(got["current_revision_id"] as? String, publishedRevisionID)

        let listed = try authority.dispatch(method: "bot.list", params: [:])
        let row = try XCTUnwrap((listed["bots"] as? [[String: Any]])?.first {
            $0["id"] as? String == botID
        })
        XCTAssertEqual(row["soul"] as? String, "Own the exact support inbox.")
        XCTAssertEqual(row["current_revision_id"] as? String, publishedRevisionID)
    }

    func test_desktopSetPublishesDurableKindAndExactRevisionReadback() throws {
        // WHY: Studio Save must not report a desktop kind that bot.get/list
        // will immediately replace after the next refresh or host relaunch.
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "desktop-create", "name": "Desktop Bot",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let changed = try authority.dispatch(method: "bot.desktop.set", params: [
            "client_request_id": "desktop-set", "bot_id": botID,
            "kind": BotDesktopKind.dockerDesktop.rawValue,
        ])
        let readback = try XCTUnwrap(changed["readback"] as? [String: Any])
        let revisionID = try XCTUnwrap(readback["current_revision_id"] as? String)
        XCTAssertEqual(readback["kind"] as? String, BotDesktopKind.dockerDesktop.rawValue)
        XCTAssertEqual(readback["desktop_kind"] as? String, BotDesktopKind.dockerDesktop.rawValue)

        let get = try authority.dispatch(method: "bot.get", params: ["bot_id": botID])
        let listed = try authority.dispatch(method: "bot.list", params: [:])
        let row = try XCTUnwrap((listed["bots"] as? [[String: Any]])?.first { $0["id"] as? String == botID })
        XCTAssertEqual(get["desktop_kind"] as? String, BotDesktopKind.dockerDesktop.rawValue)
        XCTAssertEqual(row["desktop_kind"] as? String, BotDesktopKind.dockerDesktop.rawValue)
        XCTAssertEqual(get["current_revision_id"] as? String, revisionID)
        XCTAssertEqual(row["current_revision_id"] as? String, revisionID)

        let relaunched = BotRemoteControlAuthority(
            db: db, store: store, settings: settings, appSupportDirectory: supportDir
        )
        let restored = try relaunched.dispatch(method: "bot.get", params: ["bot_id": botID])
        XCTAssertEqual(restored["desktop_kind"] as? String, BotDesktopKind.dockerDesktop.rawValue)
        XCTAssertEqual(restored["current_revision_id"] as? String, revisionID)
    }

    /// WHY: process-local receipt state may disappear at relaunch, but the
    /// authored soul and its revision must remain recoverable from BotStore.
    func test_soulReadbackSurvivesAuthorityRelaunch() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "soul-relaunch-create",
            "name": "Durable Soul",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let changed = try authority.dispatch(method: "bot.soul.set", params: [
            "client_request_id": "soul-relaunch-change",
            "bot_id": botID,
            "soul": "Persist across authority reconstruction.",
        ])
        let revisionID = try XCTUnwrap(
            (changed["readback"] as? [String: Any])?["current_revision_id"] as? String
        )

        authority = BotRemoteControlAuthority(
            db: db,
            store: BotStore(db: db),
            settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )

        let got = try authority.dispatch(method: "bot.get", params: ["bot_id": botID])
        XCTAssertEqual(got["id"] as? String, botID)
        XCTAssertEqual(got["soul"] as? String, "Persist across authority reconstruction.")
        XCTAssertEqual(got["current_revision_id"] as? String, revisionID)
    }

    /// WHY: a corrupt cross-Bot revision pointer must never disclose another
    /// Bot's Instructions through get or through a partially successful list.
    func test_soulReadbackFailsClosedForCrossBotRevisionIdentity() throws {
        let first = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "soul-first",
            "name": "First Soul",
            "soul": "First private instructions",
        ])
        let second = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "soul-second",
            "name": "Second Soul",
            "soul": "Second private instructions",
        ])
        let firstID = try XCTUnwrap(first["bot_id"] as? String)
        let secondID = try XCTUnwrap(second["bot_id"] as? String)
        let secondRevisionID = try XCTUnwrap(
            try store.get(id: BotID(try XCTUnwrap(UUID(uuidString: secondID))))?.currentRevisionID
        )
        let statement = try db.prepare("UPDATE bots SET current_revision_id = ? WHERE id = ?;")
        defer { statement.reset() }
        try statement.bind(1, secondRevisionID.value.uuidString.lowercased())
        try statement.bind(2, firstID)
        _ = try statement.step()

        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.get", params: ["bot_id": firstID])
        ) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .notFound)
        }
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.list", params: [:])
        ) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .notFound)
        }
    }

    func test_sendWithoutRequestId_doesNotEnqueue() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "c1",
            "name": "Piper",
        ])
        let botID = created["bot_id"] as? String
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.send", params: [
                "bot_id": botID as Any,
                "text": "hello",
            ])
        )
        let queue = try authority.dispatch(method: "bot.queue.list", params: ["bot_id": botID as Any])
        XCTAssertEqual((queue["items"] as? [[String: Any]])?.count, 0)
    }

    func test_liveSend_enqueuesUnderHostAuthorityAndSurvivesRelaunch() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "c2",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "s1",
            "bot_id": botID,
            "text": "first turn",
        ])
        let queued = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "s2",
            "bot_id": botID,
            "text": "follow up",
        ])
        XCTAssertEqual((queued["readback"] as? [String: Any])?["enqueued"] as? Bool, true)
        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let list = try relaunched.dispatch(method: "bot.queue.list", params: ["bot_id": botID])
        let items = try XCTUnwrap(list["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["text"] as? String, "follow up")
        XCTAssertNotNil(items.first?["id"] as? String)
    }

    /// WHY: `bot.remote.queue` is the only copy of a queue that predates
    /// `bot_queued_follow_ups`. A launch that cannot write those rows must keep
    /// them (and retry later) instead of clearing the key — clearing it lost the
    /// user's pending follow-ups with no error and no retry.
    func test_legacyQueueMigrationKeepsRowsTheStoreRefused() throws {
        let live = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "migrate-live",
            "name": "Legacy Queue Bot",
        ])
        let liveID = try XCTUnwrap(live["bot_id"] as? String)
        let deleted = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "migrate-deleted",
            "name": "Deleted Legacy Bot",
        ])
        let deletedID = try XCTUnwrap(deleted["bot_id"] as? String)
        try store.delete(id: BotID(try XCTUnwrap(UUID(uuidString: deletedID))))

        try seedLegacySidecarQueue([
            liveID: [
                ["id": "legacy-1", "text": "first pending"],
                ["id": "legacy-2", "text": "second pending"],
            ],
            deletedID: [["id": "legacy-gone", "text": "belongs to a deleted bot"]],
        ])

        try db.execute("""
            CREATE TRIGGER fail_queue_insert
            BEFORE INSERT ON bot_queued_follow_ups
            BEGIN
                SELECT RAISE(ABORT, 'queue write blocked');
            END;
            """)

        _ = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )

        let kept = try legacySidecarQueue()
        // Anti-vacuity: the deleted bot's rows go away only because the run
        // reached them, so this cannot pass on a migration that never ran.
        XCTAssertNil(kept[deletedID], "a deleted bot's legacy rows are dropped during migration")
        XCTAssertEqual(
            kept[liveID]?.compactMap { $0["text"] as? String },
            ["first pending", "second pending"],
            "rows the store refused must stay in the sidecar"
        )
    }

    /// The healthy path is unchanged: rows land in the store and only then is
    /// the legacy key cleared.
    func test_legacyQueueMigrationMovesRowsAndClearsTheKeyOnceTheyLand() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "migrate-ok",
            "name": "Legacy Happy Path Bot",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        try seedLegacySidecarQueue([
            botID: [["id": "legacy-ok", "text": "pending turn"]],
        ])

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )

        let list = try relaunched.dispatch(method: "bot.queue.list", params: ["bot_id": botID])
        let items = try XCTUnwrap(list["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["text"] as? String }, ["pending turn"])
        XCTAssertEqual(try legacySidecarQueue().isEmpty, true)
    }

    private func seedLegacySidecarQueue(_ rows: [String: [[String: Any]]]) throws {
        let data = try JSONSerialization.data(withJSONObject: rows)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        try db.performSync { database in
            let statement = try database.prepare(
                "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
            )
            defer { statement.reset() }
            try statement.bind(1, "bot.remote.queue")
            try statement.bind(2, text)
            try statement.bind(3, ISO8601DateFormatter().string(from: Date()))
            _ = try statement.step()
        }
    }

    private func legacySidecarQueue() throws -> [String: [[String: Any]]] {
        let text: String? = try db.performSync { database in
            let statement = try database.prepare("SELECT value FROM settings WHERE key = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, "bot.remote.queue")
            guard try statement.step() else { return nil }
            return statement.columnText(0)
        }
        guard let text, let data = text.data(using: .utf8) else { return [:] }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else {
            return [:]
        }
        return rows
    }

    func test_queueControlsPreserveOwnershipOrderAndIdempotentForce() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "queue-create",
            "name": "Queue Bot",
        ])
        let other = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "queue-other",
            "name": "Other Bot",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let otherID = try XCTUnwrap(other["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "queue-live",
            "bot_id": botID,
            "text": "live",
        ])
        let first = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "queue-first",
            "bot_id": botID,
            "text": "first",
        ])
        let second = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "queue-second",
            "bot_id": botID,
            "text": "second",
        ])
        let firstID = try XCTUnwrap((first["readback"] as? [String: Any])?["id"] as? String)
        let secondID = try XCTUnwrap((second["readback"] as? [String: Any])?["id"] as? String)

        _ = try authority.dispatch(method: "bot.queue.update", params: [
            "client_request_id": "queue-update",
            "bot_id": botID,
            "id": secondID,
            "text": "edited second",
        ])
        let reordered = try authority.dispatch(method: "bot.queue.reorder", params: [
            "client_request_id": "queue-reorder",
            "bot_id": botID,
            "id": secondID,
            "position": 0,
        ])
        var rows = try XCTUnwrap((reordered["readback"] as? [String: Any])?["queue"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, [secondID, firstID])
        XCTAssertEqual(rows.first?["text"] as? String, "edited second")

        var forceCalls = 0
        authority.onForceQueuedFollowUp = { callbackBotID, callbackItemID in
            forceCalls += 1
            XCTAssertEqual(callbackBotID.value.uuidString.lowercased(), botID)
            XCTAssertEqual(callbackItemID, firstID)
            return ["force_status": "queued"]
        }
        let forcedParams: [String: Any] = [
            "client_request_id": "queue-force",
            "bot_id": botID,
            "id": firstID,
        ]
        let forced = try authority.dispatch(method: "bot.queue.force_now", params: forcedParams)
        rows = try XCTUnwrap((forced["readback"] as? [String: Any])?["queue"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, [firstID, secondID])
        _ = try authority.dispatch(method: "bot.queue.force_now", params: forcedParams)
        XCTAssertEqual(forceCalls, 1, "receipt replay must not force the same row twice")

        XCTAssertThrowsError(try authority.dispatch(method: "bot.queue.remove", params: [
            "client_request_id": "queue-cross-owner",
            "bot_id": otherID,
            "id": firstID,
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .invalidParams)
        }
        _ = try authority.dispatch(method: "bot.queue.remove", params: [
            "client_request_id": "queue-remove",
            "bot_id": botID,
            "id": firstID,
        ])
        let listed = try authority.dispatch(method: "bot.queue.list", params: ["bot_id": botID])
        XCTAssertEqual((listed["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [secondID])
    }

    /// WHY: iOS may only adopt a Bot turn when response, receipt status, and
    /// later stream frames share one exact authenticated execution tuple.
    func test_sendReceiptBindsStartedAndQueuedRuntimeEvidenceWithoutReplay() throws {
        let hostID = "runtime-host"
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "runtime-create",
            "name": "Runtime Bot",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "runtime-conversation",
            "bot_id": botID,
            "title": "Runtime",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let runID = UUID().uuidString.lowercased()
        let threadID = UUID().uuidString.lowercased()
        var sendCalls = 0
        authority.onSend = { callbackBotID, _, callbackConversationID, _, _, _ in
            sendCalls += 1
            XCTAssertEqual(callbackBotID.value.uuidString.lowercased(), botID)
            XCTAssertEqual(callbackConversationID?.value.uuidString.lowercased(), conversationID)
            return [
                "bot_id": botID,
                "conversation_id": conversationID,
                "thread_id": threadID,
                "run_id": runID,
                "enqueued": true,
                "queued_follow_up": false,
            ]
        }
        let params: [String: Any] = [
            "client_request_id": "runtime-send",
            "host_id": hostID,
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "Start exactly once",
        ]
        let started = try authority.dispatch(method: "bot.send", params: params)
        let replay = try authority.dispatch(method: "bot.send", params: params)
        XCTAssertEqual(started as NSDictionary, replay as NSDictionary)
        XCTAssertEqual(sendCalls, 1)
        XCTAssertEqual(started["host_id"] as? String, hostID)
        XCTAssertEqual(started["request_id"] as? String, "runtime-send")
        XCTAssertEqual(started["client_request_id"] as? String, "runtime-send")
        XCTAssertEqual(started["bot_id"] as? String, botID)
        let readback = try XCTUnwrap(started["readback"] as? [String: Any])
        XCTAssertEqual(readback["host_id"] as? String, hostID)
        XCTAssertEqual(readback["request_id"] as? String, "runtime-send")
        XCTAssertEqual(readback["client_request_id"] as? String, "runtime-send")
        XCTAssertEqual(readback["bot_id"] as? String, botID)
        XCTAssertEqual(readback["conversation_id"] as? String, conversationID)
        XCTAssertEqual(readback["run_id"] as? String, runID)
        XCTAssertEqual(readback["enqueued"] as? Bool, false)
        let run = try XCTUnwrap(readback["run"] as? [String: Any])
        XCTAssertEqual(run["host_id"] as? String, hostID)
        XCTAssertEqual(run["request_id"] as? String, "runtime-send")
        XCTAssertEqual(run["client_request_id"] as? String, "runtime-send")
        XCTAssertEqual(run["bot_id"] as? String, botID)
        XCTAssertEqual(run["conversation_id"] as? String, conversationID)
        XCTAssertEqual(run["run_id"] as? String, runID)
        XCTAssertEqual(run["thread_id"] as? String, threadID)

        authority.onSend = nil
        let queued = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "runtime-queued",
            "host_id": hostID,
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "Queue for the same conversation",
        ])
        let queuedReadback = try XCTUnwrap(queued["readback"] as? [String: Any])
        XCTAssertEqual(queuedReadback["enqueued"] as? Bool, true)
        XCTAssertEqual(queuedReadback["run_id"] as? String, runID)
        let itemID = try XCTUnwrap(queuedReadback["id"] as? String)
        let queue = try XCTUnwrap(queuedReadback["queue"] as? [[String: Any]])
        XCTAssertTrue(queue.contains {
            $0["id"] as? String == itemID
                && $0["bot_id"] as? String == botID
                && $0["conversation_id"] as? String == conversationID
        })
        let conversations = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id": botID])
        XCTAssertEqual(conversations["selected_id"] as? String, conversationID,
                       "the first host-admitted conversation becomes authoritative selection")

        XCTAssertFalse(authority.settleRuntime(botID: botID, runID: "wrong-run", failed: true))
        XCTAssertTrue(authority.settleRuntime(botID: botID, runID: runID.uppercased(), failed: true),
                      "Foundation UUID casing must not prevent exact runtime settlement")
        let attention = try authority.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((attention["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == botID
        })
        XCTAssertEqual(item["run_id"] as? String, runID)
        XCTAssertEqual(item["state"] as? String, "finished")
        XCTAssertEqual(item["outcome"] as? String, "failed")
    }

    /// WHY: `bot_ask_user` is a real MCP write, not a paired-RPC mutation.
    /// Its durable question must replace only the exact active run's working
    /// projection and remain the same needs-attention item after settlement
    /// and authority reconstruction.
    func test_botAskUserReachesExactPairedAttentionAndSurvivesRelaunch() throws {
        let hostID = "ask-user-host"
        let profileID = "ask-user-profile"
        try BotAttentionPushBindingStore(db: db).bind(
            profileID: profileID,
            hostID: hostID,
            deviceID: "ask-user-device"
        )

        let unrelated = try createLiveBot(prefix: "ask-user-b", name: "Unrelated B")
        XCTAssertTrue(authority.settleRuntime(
            botID: unrelated.botID,
            runID: unrelated.runID,
            failed: true
        ))
        let before = try authority.dispatch(method: "bot.attention.list", params: [:])
        let unrelatedBefore = try XCTUnwrap((before["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == unrelated.botID
        })
        let unrelatedBotID = BotID(try XCTUnwrap(UUID(uuidString: unrelated.botID)))
        let unrelatedAudit = BotAttentionItem(
            botID: unrelatedBotID,
            conversationID: BotConversationID(
                try XCTUnwrap(UUID(uuidString: unrelated.conversationID))
            ),
            kind: .blocked,
            title: "Historical B",
            detail: "Keep this audit row.",
            acknowledgedAt: Date()
        )
        try store.upsertAttention(unrelatedAudit)

        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "ask-user-a-create",
            "name": "Question A",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let bot = BotID(try XCTUnwrap(UUID(uuidString: botID)))
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "ask-user-a-conversation",
            "bot_id": botID,
            "title": "Exact active conversation",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let threadID = UUID()
        let runID = UUID()
        try AgentThreadRepository(db: db).upsert(AgentThread(id: AgentThreadID(threadID), title: "Question", provider: .codex, model: "test"))
        try AgentRunRepository(db: db).upsert(AgentRun(id: AgentRunID(runID), threadId: AgentThreadID(threadID), provider: .codex, model: "test", status: .running))
        authority.onSend = { callbackBotID, _, callbackConversationID, _, _, _ in
            XCTAssertEqual(callbackBotID, bot)
            XCTAssertEqual(callbackConversationID?.value.uuidString.lowercased(), conversationID)
            return [
                "bot_id": botID,
                "conversation_id": conversationID,
                "thread_id": threadID.uuidString.lowercased(),
                "run_id": runID.uuidString.lowercased(),
                "enqueued": true,
                "queued_follow_up": false,
            ]
        }
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "ask-user-a-send",
            "host_id": hostID,
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "Ask the user only if blocked.",
        ])
        var linked = try XCTUnwrap(try store.conversation(
            id: BotConversationID(try XCTUnwrap(UUID(uuidString: conversationID)))
        ))
        linked.linkedAgentThreadID = AgentThreadID(threadID)
        try store.upsertConversation(linked)

        // This sibling is deliberately newer. Ignoring the host-issued thread
        // context would attach the question to this unrelated conversation.
        try store.upsertConversation(BotConversation(
            botID: bot,
            title: "Newer sibling",
            updatedAt: Date().addingTimeInterval(60)
        ))
        let service = try BotSelfConfigService.make(environment: [
            BotSelfConfigCatalog.callerEnvironmentKey: botID,
            BotPeerDelegation.threadEnvironmentKey: threadID.uuidString.lowercased(),
            BotPeerDelegation.runEnvironmentKey: runID.uuidString.lowercased(),
        ], store: store)
        let asked = try service.invoke(
            name: BotSelfConfigCatalog.askUser,
            arguments: ["question": "Which repository should I use?"]
        )
        let itemID = try XCTUnwrap(asked["attention_id"] as? String)
        XCTAssertEqual(asked["thread_id"] as? String, threadID.uuidString.lowercased())
        XCTAssertEqual(asked["run_id"] as? String, runID.uuidString.lowercased())

        let awaiting = try authority.dispatch(method: "bot.attention.list", params: [:])
        let awaitingItem = try XCTUnwrap((awaiting["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == botID
        })
        XCTAssertEqual(awaitingItem["id"] as? String, itemID)
        XCTAssertEqual(awaitingItem["run_id"] as? String, runID.uuidString.lowercased())
        XCTAssertEqual(awaitingItem["state"] as? String, "needs_attention")

        XCTAssertTrue(authority.settleRuntime(
            botID: botID,
            runID: runID.uuidString.uppercased(),
            failed: false
        ))
        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((listed["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == botID
        })
        XCTAssertEqual(item["id"] as? String, itemID)
        XCTAssertEqual(item["attention_item_id"] as? String, itemID)
        XCTAssertEqual(item["bot_id"] as? String, botID)
        XCTAssertEqual(item["conversation_id"] as? String, conversationID)
        XCTAssertEqual(item["thread_id"] as? String, threadID.uuidString.lowercased())
        XCTAssertEqual(item["run_id"] as? String, runID.uuidString.lowercased())
        XCTAssertEqual(item["state"] as? String, "needs_attention")
        XCTAssertEqual(item["source"] as? String, "bot_ask_user")
        XCTAssertEqual(item["detail"] as? String, "Which repository should I use?")
        XCTAssertEqual(item["profile_id"] as? String, profileID)
        XCTAssertEqual(item["host_id"] as? String, hostID)
        XCTAssertTrue(item["finished_at"] is NSNull)

        let unrelatedAfter = try XCTUnwrap((listed["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == unrelated.botID
        })
        XCTAssertEqual(unrelatedAfter as NSDictionary, unrelatedBefore as NSDictionary)
        XCTAssertTrue(try store.listAttention(includeAcknowledged: true).contains {
            $0.id == unrelatedAudit.id && $0.acknowledgedAt != nil
        }, "unrelated audit history must not be rewritten while adopting A")

        authority = BotRemoteControlAuthority(
            db: db,
            store: BotStore(db: db),
            settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )
        let restored = try authority.dispatch(method: "bot.attention.list", params: [:])
        let restoredItem = try XCTUnwrap((restored["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == botID
        })
        XCTAssertEqual(restoredItem["id"] as? String, itemID)
        XCTAssertEqual(restoredItem["conversation_id"] as? String, conversationID)
        XCTAssertEqual(restoredItem["thread_id"] as? String, threadID.uuidString.lowercased())
        XCTAssertEqual(restoredItem["run_id"] as? String, runID.uuidString.lowercased())
        XCTAssertEqual(restoredItem["state"] as? String, "needs_attention")
        _ = try authority.dispatch(method: "bot.attention.ack", params: [
            "client_request_id": "dismiss-question",
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": itemID,
            "bot_id": botID,
        ])
        XCTAssertFalse(try store.listAttention().contains { $0.id.value.uuidString.lowercased() == itemID })
        let dismissed = try authority.dispatch(method: "bot.attention.list", params: [:])
        XCTAssertEqual((dismissed["items"] as? [[String: Any]])?.first { $0["bot_id"] as? String == botID }?["state"] as? String, "none")
    }

    /// WHY: run context is an identity fence. A Bot must not attach its
    /// question to a thread-owned conversation belonging to another Bot.
    func test_botAskUserRejectsCrossBotThreadContext() throws {
        let caller = try store.create(name: "Caller A", title: "", description: "")
        let owner = try store.create(name: "Owner B", title: "", description: "")
        let threadID = AgentThreadID()
        try store.upsertConversation(BotConversation(
            botID: owner.id,
            title: "Owner thread",
            linkedAgentThreadID: threadID
        ))
        let service = try BotSelfConfigService.make(environment: [
            BotSelfConfigCatalog.callerEnvironmentKey: caller.id.value.uuidString.lowercased(),
            BotPeerDelegation.threadEnvironmentKey: threadID.value.uuidString.lowercased(),
            BotPeerDelegation.runEnvironmentKey: AgentRunID().value.uuidString.lowercased(),
        ], store: store)

        XCTAssertThrowsError(try service.askUser(question: "Leak this question")) { error in
            XCTAssertEqual(error as? BotSelfConfigError, .crossBot)
        }
        XCTAssertTrue(try store.listAttention(includeAcknowledged: true).isEmpty)
    }

    /// WHY: a run may ask the user more than once (two `bot_ask_user` calls,
    /// or ask_user plus a desk "Needs you" row). That is normal, not a
    /// cross-target violation: the list must keep working and show the newest
    /// question, and the run must still settle so the Bot stops reading as live.
    func test_multipleQuestionsInOneRunPickNewestAndStillSettle() throws {
        let (botID, conversationID) = try createBotConversation(prefix: "multi-question")
        let bot = BotID(try XCTUnwrap(UUID(uuidString: botID)))
        let conversation = BotConversationID(try XCTUnwrap(UUID(uuidString: conversationID)))
        let threadID = UUID()
        let runID = UUID()
        try AgentThreadRepository(db: db).upsert(AgentThread(id: AgentThreadID(threadID), title: "Questions", provider: .codex, model: "test"))
        try AgentRunRepository(db: db).upsert(AgentRun(id: AgentRunID(runID), threadId: AgentThreadID(threadID), provider: .codex, model: "test", status: .running))
        authority.onSend = { _, _, _, _, _, _ in
            [
                "bot_id": botID,
                "conversation_id": conversationID,
                "thread_id": threadID.uuidString.lowercased(),
                "run_id": runID.uuidString.lowercased(),
                "enqueued": true,
                "queued_follow_up": false,
            ]
        }
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "multi-question-send",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "Ask whatever you need.",
        ])
        var linked = try XCTUnwrap(try store.conversation(id: conversation))
        linked.linkedAgentThreadID = AgentThreadID(threadID)
        try store.upsertConversation(linked)

        let older = BotAttentionItem(
            botID: bot,
            conversationID: conversation,
            kind: .question,
            title: "Needs you",
            detail: "First question",
            createdAt: Date().addingTimeInterval(5)
        )
        let newer = BotAttentionItem(
            botID: bot,
            conversationID: conversation,
            kind: .question,
            title: "Needs you",
            detail: "Second question",
            createdAt: Date().addingTimeInterval(10)
        )
        try store.upsertAttention(newer)
        try store.upsertAttention(older)

        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((listed["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == botID
        })
        XCTAssertEqual(item["id"] as? String, newer.id.value.uuidString.lowercased())
        XCTAssertEqual(item["state"] as? String, "needs_attention")

        XCTAssertTrue(
            authority.settleRuntime(botID: botID, runID: runID.uuidString, failed: false),
            "a second question must not block the terminal settle"
        )
        let settled = try authority.dispatch(method: "bot.attention.list", params: [:])
        let settledItem = try XCTUnwrap((settled["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == botID
        })
        XCTAssertEqual(settledItem["id"] as? String, newer.id.value.uuidString.lowercased())
        XCTAssertEqual(settledItem["state"] as? String, "needs_attention")
        XCTAssertFalse(
            authority.settleRuntime(botID: botID, runID: runID.uuidString, failed: false),
            "the live run entry must be gone after the first settle"
        )
    }

    /// WHY: peer descendants are real Bot work, but they must never inflate
    /// the primary count or lose their exact activity/conversation/run owner
    /// after the paired authority is reconstructed.
    func test_delegatedAttentionIsExactDeduplicatedAndSurvivesRelaunch() throws {
        let primary = try createLiveBot(prefix: "ownership-primary", name: "Primary B")
        XCTAssertTrue(authority.settleRuntime(
            botID: primary.botID,
            runID: primary.runID,
            failed: false
        ))
        let delegated = try createLiveBot(prefix: "ownership-peer", name: "Delegated A")
        let delegatedBot = BotID(try XCTUnwrap(UUID(uuidString: delegated.botID)))
        let delegatedConversationID = BotConversationID(
            try XCTUnwrap(UUID(uuidString: delegated.conversationID))
        )
        let delegatedThreadID = AgentThreadID()
        var delegatedConversation = try XCTUnwrap(
            try store.conversation(id: delegatedConversationID)
        )
        delegatedConversation.linkedAgentThreadID = delegatedThreadID
        try store.upsertConversation(delegatedConversation)

        let ownerThreadID = AgentThreadID()
        let primaryConversationID = BotConversationID(
            try XCTUnwrap(UUID(uuidString: primary.conversationID))
        )
        var primaryConversation = try XCTUnwrap(try store.conversation(id: primaryConversationID))
        primaryConversation.linkedAgentThreadID = ownerThreadID
        try store.upsertConversation(primaryConversation)
        let activityID = UUID()
        let ownerRunID = AgentRunID()
        let row: [String: Any] = [
            "id": activityID.uuidString.lowercased(),
            "lifecycle_receipt_id": activityID.uuidString.lowercased(),
            "bot_id": delegatedBot.value.uuidString.lowercased(),
            "conversation_id": delegatedConversationID.value.uuidString.lowercased(),
            "thread_id": delegatedThreadID.value.uuidString.lowercased(),
            "run_id": delegated.runID,
            "owner_bot_id": primary.botID,
            "owner_conversation_id": primary.conversationID,
            "owner_thread_id": ownerThreadID.value.uuidString.lowercased(),
            "owner_run_id": ownerRunID.value.uuidString.lowercased(),
            "state": "working",
            "finished_at": NSNull(),
            "ownership": "delegated",
            "primary": false,
            "delegated": true,
            "source": "bot_peer_handoff",
            "peer_phase": "peer_running",
        ]
        authority.onDelegatedAttentionSnapshot = { [row, row] }

        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let items = try XCTUnwrap(listed["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2, "the peer projection replaces its primary placeholder instead of double counting")
        let peer = try XCTUnwrap(items.first { $0["bot_id"] as? String == delegated.botID })
        XCTAssertEqual(peer["id"] as? String, activityID.uuidString.lowercased())
        XCTAssertEqual(peer["lifecycle_receipt_id"] as? String, activityID.uuidString.lowercased())
        XCTAssertEqual(peer["conversation_id"] as? String, delegated.conversationID)
        XCTAssertEqual(peer["thread_id"] as? String, delegatedThreadID.value.uuidString.lowercased())
        XCTAssertEqual(peer["run_id"] as? String, delegated.runID)
        XCTAssertEqual(peer["owner_bot_id"] as? String, primary.botID)
        XCTAssertEqual(peer["owner_conversation_id"] as? String, primary.conversationID)
        XCTAssertEqual(peer["owner_thread_id"] as? String, ownerThreadID.value.uuidString.lowercased())
        XCTAssertEqual(peer["owner_run_id"] as? String, ownerRunID.value.uuidString.lowercased())
        XCTAssertEqual(peer["ownership"] as? String, "delegated")
        XCTAssertEqual(peer["primary"] as? Bool, false)
        XCTAssertEqual(peer["delegated"] as? Bool, true)

        let primaryBefore = try XCTUnwrap(items.first { $0["bot_id"] as? String == primary.botID })
        XCTAssertEqual(primaryBefore["ownership"] as? String, "primary")
        XCTAssertEqual(primaryBefore["primary"] as? Bool, true)
        XCTAssertEqual(primaryBefore["delegated"] as? Bool, false)

        authority = BotRemoteControlAuthority(
            db: db,
            store: BotStore(db: db),
            settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )
        let restored = try authority.dispatch(method: "bot.attention.list", params: [:])
        let restoredItems = try XCTUnwrap(restored["items"] as? [[String: Any]])
        XCTAssertEqual(restoredItems.count, 2)
        let restoredPeer = try XCTUnwrap(restoredItems.first {
            $0["bot_id"] as? String == delegated.botID
        })
        XCTAssertEqual(restoredPeer["id"] as? String, activityID.uuidString.lowercased())
        XCTAssertEqual(restoredPeer["ownership"] as? String, "delegated")
        XCTAssertEqual(restoredPeer["run_id"] as? String, delegated.runID)
        XCTAssertEqual(restoredPeer["owner_run_id"] as? String, ownerRunID.value.uuidString.lowercased())
    }

    private func delegatedRow(
        peer: (botID: String, conversationID: String),
        peerThreadID: AgentThreadID,
        owner: (botID: String, conversationID: String),
        ownerThreadID: AgentThreadID,
        state: String
    ) -> (id: String, row: [String: Any]) {
        let activityID = UUID().uuidString.lowercased()
        return (activityID, [
            "id": activityID,
            "lifecycle_receipt_id": activityID,
            "bot_id": peer.botID,
            "conversation_id": peer.conversationID,
            "thread_id": peerThreadID.value.uuidString.lowercased(),
            "run_id": UUID().uuidString.lowercased(),
            "owner_bot_id": owner.botID,
            "owner_conversation_id": owner.conversationID,
            "owner_thread_id": ownerThreadID.value.uuidString.lowercased(),
            "owner_run_id": UUID().uuidString.lowercased(),
            "state": state,
            "finished_at": state == "finished" ? Date().timeIntervalSince1970 as Any : NSNull() as Any,
            "ownership": "delegated",
            "primary": false,
            "delegated": true,
            "source": "bot_peer_handoff",
            "peer_phase": state == "finished" ? "completed" : "peer_running",
        ])
    }

    private func linkConversation(_ conversationID: String, to threadID: AgentThreadID) throws {
        let id = BotConversationID(try XCTUnwrap(UUID(uuidString: conversationID)))
        var conversation = try XCTUnwrap(try store.conversation(id: id))
        conversation.linkedAgentThreadID = threadID
        try store.upsertConversation(conversation)
    }

    /// WHY (C28): the host keeps emitting the newest handoff per peer forever,
    /// including completed ones whose owner conversation was later relinked
    /// to a new Agent thread (provider switch) or whose Bot was deleted. One
    /// such historical row used to fail the whole bot.attention.list with
    /// -32084, so iOS lost every Working/Needs-you/Finished badge and showed
    /// "Attachment grant does not match" with nothing attached.
    func test_delegatedAttentionListSurvivesRelinkedAndDeletedHandoffRows() throws {
        let owner = try createLiveBot(prefix: "c28-owner", name: "Sam Twitter")
        let peer = try createBotConversation(prefix: "c28-writer")
        let gone = try createBotConversation(prefix: "c28-gone")
        let oldOwnerThread = AgentThreadID()
        let peerThread = AgentThreadID()
        let goneThread = AgentThreadID()
        try linkConversation(owner.conversationID, to: oldOwnerThread)
        try linkConversation(peer.conversationID, to: peerThread)
        try linkConversation(gone.conversationID, to: goneThread)
        let finished = delegatedRow(
            peer: peer, peerThreadID: peerThread,
            owner: (owner.botID, owner.conversationID), ownerThreadID: oldOwnerThread,
            state: "finished"
        )
        let deleted = delegatedRow(
            peer: gone, peerThreadID: goneThread,
            owner: (owner.botID, owner.conversationID), ownerThreadID: oldOwnerThread,
            state: "working"
        )
        authority.onDelegatedAttentionSnapshot = { [finished.row, deleted.row] }

        // Provider switch relinks the owner conversation; the Bot is deleted.
        try linkConversation(owner.conversationID, to: AgentThreadID())
        try store.delete(id: BotID(try XCTUnwrap(UUID(uuidString: gone.botID))))

        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let items = try XCTUnwrap(listed["items"] as? [[String: Any]])
        let peerItem = try XCTUnwrap(
            items.first { $0["bot_id"] as? String == peer.botID },
            "a finished handoff stays visible after its owner thread was relinked"
        )
        XCTAssertEqual(peerItem["id"] as? String, finished.id)
        XCTAssertEqual(peerItem["state"] as? String, "finished")
        XCTAssertEqual(peerItem["ownership"] as? String, "delegated")
        XCTAssertNil(
            items.first { $0["bot_id"] as? String == gone.botID },
            "a deleted peer's handoff is dropped, not surfaced"
        )
        XCTAssertNotNil(
            items.first { $0["bot_id"] as? String == owner.botID },
            "other bots' attention is still listed"
        )
    }

    /// WHY (C28 x C29): the host emits the newest handoff per peer forever.
    /// Once finished rows are no longer rejected for relinked threads, such an
    /// old finished row must not replace the peer's own newer bot.send run:
    /// settleRuntime matches that item's run_id, so the run would never
    /// settle and the Bot would read as working until the host restarts.
    func test_finishedHandoffDoesNotDisplaceNewerLiveRunSoItStillSettles() throws {
        let owner = try createBotConversation(prefix: "c28-live-owner")
        let peer = try createLiveBot(prefix: "c28-live-peer", name: "Writer")
        let ownerThread = AgentThreadID()
        let peerThread = AgentThreadID()
        try linkConversation(owner.conversationID, to: ownerThread)
        try linkConversation(peer.conversationID, to: peerThread)
        let oldHandoff = delegatedRow(
            peer: (peer.botID, peer.conversationID), peerThreadID: peerThread,
            owner: owner, ownerThreadID: ownerThread,
            state: "finished"
        )
        authority.onDelegatedAttentionSnapshot = { [oldHandoff.row] }
        try linkConversation(owner.conversationID, to: AgentThreadID())

        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let items = try XCTUnwrap(listed["items"] as? [[String: Any]])
        let peerItem = try XCTUnwrap(items.first { $0["bot_id"] as? String == peer.botID })
        XCTAssertEqual(peerItem["run_id"] as? String, peer.runID, "the live run keeps its own item")
        XCTAssertEqual(peerItem["state"] as? String, "working")
        XCTAssertTrue(
            authority.settleRuntime(botID: peer.botID, runID: peer.runID, failed: false),
            "the live run must still settle"
        )
    }

    /// WHY (C28): dropping a stale row must not widen authority. An active
    /// (working) handoff whose owner conversation no longer links the
    /// recorded owner thread is not adopted, yet the list still succeeds.
    func test_delegatedAttentionDropsActiveRowWithStaleOwnerThreadWithoutFailingList() throws {
        let owner = try createLiveBot(prefix: "c28-active-owner", name: "Owner")
        let peer = try createLiveBot(prefix: "c28-active-peer", name: "Peer")
        let ownerThread = AgentThreadID()
        let peerThread = AgentThreadID()
        try linkConversation(owner.conversationID, to: ownerThread)
        try linkConversation(peer.conversationID, to: peerThread)
        let active = delegatedRow(
            peer: (peer.botID, peer.conversationID), peerThreadID: peerThread,
            owner: (owner.botID, owner.conversationID), ownerThreadID: ownerThread,
            state: "working"
        )
        authority.onDelegatedAttentionSnapshot = { [active.row] }
        let adopted = try XCTUnwrap(
            try authority.dispatch(method: "bot.attention.list", params: [:])["items"] as? [[String: Any]]
        )
        XCTAssertEqual(
            adopted.first { $0["bot_id"] as? String == peer.botID }?["id"] as? String,
            active.id,
            "a live-matching active handoff is adopted"
        )

        try linkConversation(owner.conversationID, to: AgentThreadID())

        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let items = try XCTUnwrap(listed["items"] as? [[String: Any]])
        XCTAssertFalse(
            items.contains { $0["id"] as? String == active.id },
            "an active handoff that no longer matches live thread links is not adopted"
        )
        XCTAssertNotNil(items.first { $0["bot_id"] as? String == owner.botID })
    }

    /// WHY: ownership comes from the host, not from labels supplied by iOS.
    /// Missing or future ownership values must fail closed before any row is
    /// adopted or persisted; the bad row is dropped so the rest of the list
    /// still reaches the roster (C28).
    func test_delegatedAttentionRejectsMissingAndUnknownOwnership() throws {
        let delegated = try createLiveBot(prefix: "ownership-invalid", name: "Invalid Peer")
        let threadID = AgentThreadID()
        let conversationID = BotConversationID(
            try XCTUnwrap(UUID(uuidString: delegated.conversationID))
        )
        var conversation = try XCTUnwrap(try store.conversation(id: conversationID))
        conversation.linkedAgentThreadID = threadID
        try store.upsertConversation(conversation)
        let activityID = UUID().uuidString.lowercased()
        let base: [String: Any] = [
            "id": activityID,
            "lifecycle_receipt_id": activityID,
            "bot_id": delegated.botID,
            "conversation_id": delegated.conversationID,
            "thread_id": threadID.value.uuidString.lowercased(),
            "run_id": delegated.runID,
            "owner_bot_id": delegated.botID,
            "owner_conversation_id": delegated.conversationID,
            "state": "working",
            "finished_at": NSNull(),
            "primary": false,
            "delegated": true,
            "source": "bot_peer_handoff",
        ]

        authority.onDelegatedAttentionSnapshot = { [base] }
        let missing = try authority.dispatch(method: "bot.attention.list", params: [:])
        XCTAssertEqual((missing["items"] as? [[String: Any]])?.first?["ownership"] as? String, "primary")

        var unknown = base
        unknown["ownership"] = "descendant"
        authority.onDelegatedAttentionSnapshot = { [unknown] }
        let future = try authority.dispatch(method: "bot.attention.list", params: [:])
        XCTAssertEqual((future["items"] as? [[String: Any]])?.first?["ownership"] as? String, "primary")

        authority.onDelegatedAttentionSnapshot = nil
        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((listed["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["ownership"] as? String, "primary")
        XCTAssertNotEqual(item["id"] as? String, base["id"] as? String)
    }

    /// WHY: a routing choice is an admitted host capability, not an iOS hint.
    /// The exact outer receipt and run-as tuple must bind one conversation/run
    /// and must not be reusable after response loss or relaunch.
    func test_routingReceiptBindsExactSendTupleAndIsOneShotAcrossRelaunch() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "route-create",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "route-conversation",
            "bot_id": botID,
            "title": "Exact route",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let runAs: [String: Any] = [
            "generatedUID": "generated-user",
            "shortName": "runner",
            "uid": 501,
            "gid": 20,
            "homePath": "/Users/runner",
            "fullName": "Runner User",
        ]
        let admitted = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "route-admit",
            "bot_id": botID,
            "host_id": "host-exact",
            "provider": "grok",
            "provider_instance_id": "grok-work",
            "model": "grok-4",
            "routing_mode": "explicit",
            "permission_mode": "fullAccess",
            "reasoning_effort": "high",
            "service_tier": "priority",
            "run_as_user": runAs,
        ])
        let routingReceiptID = try XCTUnwrap(admitted["receipt_id"] as? String)
        let admittedReadback = try XCTUnwrap(admitted["readback"] as? [String: Any])
        XCTAssertEqual(admittedReadback["routing_receipt_id"] as? String, routingReceiptID,
                       "the outer durable receipt is the routing authority")
        XCTAssertEqual(admittedReadback["provider_instance_id"] as? String, "grok-work")
        XCTAssertEqual(admittedReadback["run_as_user"] as? NSDictionary, runAs as NSDictionary)

        let expectedRunID = UUID().uuidString.lowercased()
        let expectedThreadID = UUID().uuidString.lowercased()
        authority.onHasLiveRun = { _ in true }
        authority.onSend = { callbackBotID, callbackText, callbackConversationID, _, callbackRouting, _ in
            XCTAssertEqual(callbackBotID.value.uuidString.lowercased(), botID)
            XCTAssertEqual(callbackText, "Use this exact route")
            XCTAssertNil(callbackConversationID,
                         "the first send must let the host create and return the authoritative conversation")
            XCTAssertEqual(callbackRouting?["routing_receipt_id"] as? String, routingReceiptID)
            XCTAssertEqual(callbackRouting?["run_as_user"] as? NSDictionary, runAs as NSDictionary)
            return [
                "bot_id": botID,
                "conversation_id": conversationID,
                "thread_id": expectedThreadID,
                "run_id": expectedRunID,
                "enqueued": true,
                "queued_follow_up": false,
            ]
        }
        let sendParams: [String: Any] = [
            "client_request_id": "route-send",
            "bot_id": botID,
            "text": "Use this exact route",
            "host_id": "host-exact",
            "routing_receipt_id": routingReceiptID,
            "provider": "grok",
            "provider_instance_id": "grok-work",
            "model": "grok-4",
            "routing_mode": "explicit",
            "permission_mode": "fullAccess",
            "reasoning_effort": "high",
            "service_tier": "priority",
            "run_as_user": runAs,
        ]
        let sent = try authority.dispatch(method: "bot.send", params: sendParams)
        let sendReadback = try XCTUnwrap(sent["readback"] as? [String: Any])
        let run = try XCTUnwrap(sendReadback["run"] as? [String: Any])
        let runRouting = try XCTUnwrap(run["routing"] as? [String: Any])
        XCTAssertEqual(sendReadback["conversation_id"] as? String, conversationID)
        XCTAssertEqual(sendReadback["run_id"] as? String, expectedRunID)
        XCTAssertEqual(sendReadback["routing_receipt_id"] as? String, routingReceiptID)
        XCTAssertEqual(runRouting["routing_receipt_id"] as? String, routingReceiptID)
        XCTAssertEqual(runRouting["provider_instance_id"] as? String, "grok-work")
        XCTAssertEqual(runRouting["run_as_user"] as? NSDictionary, runAs as NSDictionary)

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        var stale = sendParams
        stale["client_request_id"] = "route-stale"
        XCTAssertThrowsError(try relaunched.dispatch(method: "bot.send", params: stale)) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget,
                           "routing receipts are one-shot across host relaunch")
        }
    }

    func test_attachmentGrant_rejectsCrossBotReuse() throws {
        let a = try authority.dispatch(method: "bot.create", params: ["client_request_id": "ca", "name": "A"])
        let b = try authority.dispatch(method: "bot.create", params: ["client_request_id": "cb", "name": "B"])
        let aID = try XCTUnwrap(a["bot_id"] as? String)
        let bID = try XCTUnwrap(b["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "att-conversation",
            "bot_id": aID,
            "title": "Attachments",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let staged = try authority.dispatch(method: "bot.attachment.stage", params: [
            "client_request_id": "att1",
            "bot_id": aID,
            "conversation_id": conversationID,
            "attachment_id": "rcatt1_abcdefghijklmnopqrstuvwxyz234567",
            "filename": "note.txt",
            "kind": "file",
            "digest": String(repeating: "a", count: 64),
            "size": 4,
        ])
        let grantID = try XCTUnwrap((staged["readback"] as? [String: Any])?["id"] as? String)
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.send", params: [
                "client_request_id": "steal",
                "bot_id": bID,
                "conversation_id": conversationID,
                "text": "use stolen grant",
                "attachment_ids": [grantID],
            ])
        ) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget)
        }
    }

    func test_attachmentList_restoresOnlyUnconsumedConversationGrantsAfterRelaunch() throws {
        let target = try createBotConversation(prefix: "attachment-restore")
        let grantID = try stageAttachment(
            prefix: "attachment-restore",
            botID: target.botID,
            conversationID: target.conversationID
        )

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let restored = try relaunched.dispatch(method: "bot.attachment.list", params: [
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
        ])
        let rows = try XCTUnwrap(restored["attachments"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, [grantID])
        XCTAssertEqual(rows.first?["filename"] as? String, "attachment-restore.txt")

        relaunched.onSend = { botID, _, conversationID, _, _, _ in
            [
                "bot_id": botID.value.uuidString.lowercased(),
                "conversation_id": conversationID?.value.uuidString.lowercased() as Any,
                "thread_id": UUID().uuidString.lowercased(),
                "run_id": UUID().uuidString.lowercased(),
                "queued_follow_up": false,
            ]
        }
        _ = try relaunched.dispatch(method: "bot.send", params: [
            "client_request_id": "attachment-restore-send",
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
            "text": "consume",
            "attachment_ids": [grantID],
        ])
        let consumed = try relaunched.dispatch(method: "bot.attachment.list", params: [
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
        ])
        XCTAssertEqual((consumed["attachments"] as? [[String: Any]])?.count, 0)
    }

    func test_attachmentImport_usesCurrentOpaqueMacFileAuthorityAndStagesGrant() throws {
        let target = try createBotConversation(prefix: "attachment-import")
        let root = try fileRootGrant(botID: target.botID, hostID: "host-a")
        let created = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "attachment-import-file",
            "host_id": "host-a",
            "bot_id": target.botID,
            "root_handle": root.handle,
            "expected_generation": root.generation,
            "expected_cas": root.cas,
            "relative_path": "report.md",
            "op": "write",
            "contents": "report",
        ])
        let file = try XCTUnwrap(created["readback"] as? [String: Any])
        authority.onImportFile = { botID, url in
            XCTAssertEqual(botID.value.uuidString.lowercased(), target.botID)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "report")
            return AgentAttachment(
                id: "rcatt1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                path: "",
                displayName: url.lastPathComponent,
                kind: .file,
                mimeType: "text/markdown",
                sha256: String(repeating: "b", count: 64),
                sizeBytes: 6
            )
        }
        let imported = try authority.dispatch(method: "bot.attachment.import", params: [
            "client_request_id": "attachment-import-grant",
            "host_id": "host-a",
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
            "root_handle": try XCTUnwrap(file["root_handle"] as? String),
            "handle": try XCTUnwrap(file["handle"] as? String),
            "expected_generation": try XCTUnwrap(file["generation"] as? Int),
            "expected_cas": try XCTUnwrap(file["root_cas"] as? String),
        ])
        let grant = try XCTUnwrap(imported["readback"] as? [String: Any])
        XCTAssertEqual(grant["filename"] as? String, "report.md")
        XCTAssertEqual(grant["conversation_id"] as? String, target.conversationID)
        XCTAssertEqual(grant["consumed"] as? Bool, false)
    }

    func test_attachmentBatchValidationIsAtomicAndRejectsDuplicateGrantIDs() throws {
        let target = try createBotConversation(prefix: "atomic-attachment")
        let grantID = try stageAttachment(
            prefix: "atomic-attachment",
            botID: target.botID,
            conversationID: target.conversationID
        )
        var sendCalls = 0
        authority.onSend = { _, _, _, attachments, _, _ in
            sendCalls += 1
            XCTAssertEqual(attachments.map(\.id), ["rcatt1_\(String(repeating: "a", count: 32))"])
            return [
                "bot_id": target.botID,
                "conversation_id": target.conversationID,
                "thread_id": UUID().uuidString.lowercased(),
                "run_id": UUID().uuidString.lowercased(),
                "queued_follow_up": false,
            ]
        }
        XCTAssertThrowsError(try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "atomic-missing-conversation",
            "bot_id": target.botID,
            "text": "must not retarget the grant",
            "attachment_ids": [grantID],
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget)
        }
        XCTAssertEqual(sendCalls, 0)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "atomic-invalid-batch",
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
            "text": "invalid batch",
            "attachment_ids": [grantID, "missing-grant"],
        ]))
        XCTAssertEqual(sendCalls, 0)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "atomic-duplicate-batch",
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
            "text": "duplicate batch",
            "attachment_ids": [grantID, grantID],
        ]))
        XCTAssertEqual(sendCalls, 0)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "atomic-valid-batch",
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
            "text": "valid batch",
            "attachment_ids": [grantID],
        ])
        XCTAssertEqual(sendCalls, 1, "failed batch validation must leave every grant intact")
    }

    func test_attachmentAdmissionFailureLeavesGrantRetryableAndSuccessfulAdmissionConsumesIt() throws {
        let target = try createBotConversation(prefix: "admission-attachment")
        let grantID = try stageAttachment(
            prefix: "admission-attachment",
            botID: target.botID,
            conversationID: target.conversationID
        )
        authority.onSend = { _, _, _, _, _, _ in throw BotRemoteControlAuthority.Error.invalidParams }
        XCTAssertThrowsError(try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "admission-fails",
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
            "text": "first",
            "attachment_ids": [grantID],
        ]))
        authority.onSend = { _, _, _, _, _, _ in [
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
            "thread_id": UUID().uuidString.lowercased(),
            "run_id": UUID().uuidString.lowercased(),
            "queued_follow_up": false,
        ] }
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "admission-retry",
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
            "text": "retry",
            "attachment_ids": [grantID],
        ])
        XCTAssertThrowsError(try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "admission-consumed",
            "bot_id": target.botID,
            "conversation_id": target.conversationID,
            "text": "reuse",
            "attachment_ids": [grantID],
        ]))
    }

    func test_attachmentStageAndRemoveRequireExactBotConversationOwner() throws {
        let a = try createBotConversation(prefix: "attachment-owner-a")
        let b = try createBotConversation(prefix: "attachment-owner-b")
        XCTAssertThrowsError(try authority.dispatch(method: "bot.attachment.stage", params: [
            "client_request_id": "attachment-owner-cross-stage",
            "bot_id": a.botID,
            "conversation_id": b.conversationID,
            "attachment_id": "rcatt1_\(String(repeating: "c", count: 32))",
            "filename": "wrong.txt",
            "kind": "file",
            "digest": String(repeating: "d", count: 64),
            "size": 4,
        ]))
        let grantID = try stageAttachment(
            prefix: "attachment-owner",
            botID: a.botID,
            conversationID: a.conversationID
        )
        XCTAssertThrowsError(try authority.dispatch(method: "bot.attachment.remove", params: [
            "client_request_id": "attachment-owner-cross-remove",
            "bot_id": b.botID,
            "conversation_id": b.conversationID,
            "id": grantID,
        ]))
        let removed = try authority.dispatch(method: "bot.attachment.remove", params: [
            "client_request_id": "attachment-owner-remove",
            "bot_id": a.botID,
            "conversation_id": a.conversationID,
            "id": grantID,
        ])
        XCTAssertEqual((removed["readback"] as? [String: Any])?["id"] as? String, grantID)
    }

    func test_conversationSelectionAndRoutineMutationsRejectCrossBotOwnership() throws {
        let a = try createBotConversation(prefix: "owner-a")
        let b = try createBotConversation(prefix: "owner-b")
        XCTAssertThrowsError(try authority.dispatch(method: "bot.conversation.select", params: [
            "client_request_id": "select-cross",
            "bot_id": a.botID,
            "conversation_id": b.conversationID,
        ]))
        XCTAssertThrowsError(try authority.dispatch(method: "bot.conversation.select", params: [
            "client_request_id": "select-missing",
            "bot_id": a.botID,
            "conversation_id": UUID().uuidString.lowercased(),
        ]))
        let routine = try authority.dispatch(method: "bot.routine.create", params: [
            "client_request_id": "routine-owner-create",
            "bot_id": a.botID,
            "name": "Owned",
            "prompt": "Only A",
            "schedule_spec_json": BotScheduleSpec(model: "auto").encodedJSON(),
        ])
        let routineID = try XCTUnwrap((routine["readback"] as? [String: Any])?["routine_id"] as? String)
        for (suffix, method, extra) in [
            ("update", "bot.routine.update", ["name": "Stolen", "prompt": "No", "schedule_spec_json": "{}"]),
            ("enable", "bot.routine.enable", ["enabled": true]),
            ("run", "bot.routine.run", [:]),
            ("delete", "bot.routine.delete", [:]),
        ] as [(String, String, [String: Any])] {
            var params: [String: Any] = [
                "client_request_id": "routine-owner-\(suffix)",
                "bot_id": b.botID,
                "routine_id": routineID,
            ]
            params.merge(extra) { _, new in new }
            XCTAssertThrowsError(try authority.dispatch(method: method, params: params), method)
        }
        for routineID: String? in [nil, "not-a-uuid"] {
            var params: [String: Any] = [
                "client_request_id": UUID().uuidString, "bot_id": a.botID,
                "name": "Edit", "prompt": "Only A",
                "schedule_spec_json": BotScheduleSpec(model: "auto").encodedJSON(),
            ]
            params["routine_id"] = routineID
            XCTAssertThrowsError(try authority.dispatch(method: "bot.routine.update", params: params))
        }
        let listed = try authority.dispatch(method: "bot.routine.list", params: ["bot_id": a.botID])
        XCTAssertEqual((listed["routines"] as? [[String: Any]])?.count, 1)
    }

    func test_routineUpdatePreservesOmittedOptionsAndHonorsExplicitNull() throws {
        let owner = try createBotConversation(prefix: "schedule-merge")
        let botID = BotID(try XCTUnwrap(UUID(uuidString: owner.botID)))
        var original = BotScheduleSpec(model: "original", distillMainEffortSelection: .fixed(.high))
        original.executionDestination = .mac
        original.distillExecutionMode = .ultrasave
        original.reasoningModel = "worker"
        original.additionalFrequencies = [ScheduledFrequencyRule(
            frequency: .weekly, scheduledDate: Date(timeIntervalSince1970: 1_800_000_000)
        )]
        let routine = BotRoutineDefinition(
            botID: botID, name: "Review", prompt: "Review changes", scheduleSpecJSON: original.encodedJSON()
        )
        try store.saveRoutine(routine)
        let incoming = BotScheduleSpec(model: "updated").encodedJSON()
        var params: [String: Any] = [
            "client_request_id": "schedule-merge-update", "bot_id": owner.botID,
            "routine_id": routine.id.value.uuidString, "name": "Review", "prompt": "Review changes",
            "schedule_spec_json": incoming,
        ]
        _ = try authority.dispatch(method: "bot.routine.update", params: params)
        let saved = try XCTUnwrap(store.listRoutines(botID: botID).first?.definition.scheduleSpec)
        XCTAssertEqual(saved.model, "updated")
        XCTAssertEqual(saved.executionDestination, .mac)
        XCTAssertEqual(saved.distillExecutionMode, .ultrasave)
        XCTAssertEqual(saved.reasoningModel, "worker")
        XCTAssertEqual(saved.additionalFrequencies, original.additionalFrequencies)
        XCTAssertEqual(saved.distillMainEffortSelection, .fixed(.high))

        var clear = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(incoming.utf8)) as? [String: Any])
        clear["executionDestination"] = NSNull()
        clear["reasoningModel"] = NSNull()
        clear["additionalFrequencies"] = NSNull()
        clear["distillUltracode"] = "ultrafast"
        params["client_request_id"] = "schedule-merge-clear"
        params["schedule_spec_json"] = String(decoding: try JSONSerialization.data(withJSONObject: clear), as: UTF8.self)
        _ = try authority.dispatch(method: "bot.routine.update", params: params)
        let cleared = try XCTUnwrap(store.listRoutines(botID: botID).first?.definition.scheduleSpec)
        XCTAssertNil(cleared.executionDestination)
        XCTAssertNil(cleared.reasoningModel)
        XCTAssertNil(cleared.additionalFrequencies)
        XCTAssertEqual(cleared.distillExecutionMode, .ultrafast)
        XCTAssertEqual(cleared.distillMainEffortSelection, .fixed(.high))
    }

    /// C30: a conversation cleared on the Mac used to fail select / send /
    /// attachment reads with -32084 "Attachment grant does not match…", so
    /// iOS showed attachment copy with nothing attached and never refreshed.
    /// A gone conversation or routine must carry its own code so the phone
    /// can re-read the list, while real grant mismatches stay -32084.
    func test_goneConversationAndRoutineReportDistinctErrorsNotAttachmentGrantMismatch() throws {
        let target = try createBotConversation(prefix: "gone")
        _ = try authority.dispatch(method: "bot.conversation.clear_all", params: [
            "client_request_id": "gone-clear",
            "bot_id": target.botID,
            "confirm": "clear",
        ])
        let conversationGone = BotRemoteControlAuthority.Error(
            code: -32080,
            message: "This Bot conversation no longer exists on the Mac. Refresh to continue."
        )
        for (method, extra) in [
            ("bot.conversation.select", [:]),
            ("bot.send", ["text": "still there?"]),
            ("bot.attachment.list", [:]),
            ("bot.attachment.stage", [
                "attachment_id": "rcatt1_\(String(repeating: "a", count: 32))",
                "filename": "gone.txt",
                "kind": "file",
                "digest": String(repeating: "b", count: 64),
                "size": 4,
            ]),
            ("bot.attachment.remove", ["id": "missing-grant"]),
            ("bot.attachment.import", ["root_handle": "root", "handle": "file"]),
        ] as [(String, [String: Any])] {
            var params: [String: Any] = [
                "client_request_id": "gone-\(method)",
                "bot_id": target.botID,
                "conversation_id": target.conversationID,
            ]
            params.merge(extra) { _, new in new }
            XCTAssertThrowsError(try authority.dispatch(method: method, params: params), method) { error in
                XCTAssertEqual(error as? BotRemoteControlAuthority.Error, conversationGone, method)
            }
            guard method != "bot.attachment.list" else { continue }
            // Paired mutations reach the phone as this failed receipt, not as
            // a JSON-RPC error, so the receipt must carry the code too.
            let failed = try authority.dispatch(method: "bot.receipt.status", params: [
                "client_request_id": "gone-\(method)",
            ])
            XCTAssertEqual(failed["status"] as? String, "failed", method)
            let readback = failed["readback"] as? [String: Any]
            XCTAssertEqual(readback?["error_code"] as? Int, -32080, method)
            XCTAssertEqual(readback?["error"] as? String, conversationGone.message, method)
        }

        let routineGone = BotRemoteControlAuthority.Error(
            code: -32079,
            message: "This routine no longer exists on the Mac."
        )
        let missingRoutineID = UUID().uuidString.lowercased()
        for (method, extra) in [
            ("bot.routine.update", ["name": "Gone", "prompt": "No", "schedule_spec_json": "{}"]),
            ("bot.routine.enable", ["enabled": true]),
            ("bot.routine.run", [:]),
            ("bot.routine.delete", [:]),
        ] as [(String, [String: Any])] {
            var params: [String: Any] = [
                "client_request_id": "gone-\(method)",
                "bot_id": target.botID,
                "routine_id": missingRoutineID,
            ]
            params.merge(extra) { _, new in new }
            XCTAssertThrowsError(try authority.dispatch(method: method, params: params), method) { error in
                XCTAssertEqual(error as? BotRemoteControlAuthority.Error, routineGone, method)
            }
        }

        // A live conversation owned by another Bot, or a grant that does not
        // exist, is still a real cross-target mismatch, not a gone conversation.
        let live = try createBotConversation(prefix: "gone-live")
        XCTAssertThrowsError(try authority.dispatch(method: "bot.conversation.select", params: [
            "client_request_id": "gone-live-foreign-select",
            "bot_id": target.botID,
            "conversation_id": live.conversationID,
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget)
        }
        XCTAssertThrowsError(try authority.dispatch(method: "bot.attachment.remove", params: [
            "client_request_id": "gone-live-remove",
            "bot_id": live.botID,
            "conversation_id": live.conversationID,
            "id": "missing-grant",
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget)
        }
    }

    func test_mutationReceiptReplayRejectsChangedMethodOrSemanticParams() throws {
        let params: [String: Any] = ["client_request_id": "semantic-replay", "name": "Original"]
        let first = try authority.dispatch(method: "bot.create", params: params)
        let replay = try authority.dispatch(method: "bot.create", params: params)
        XCTAssertEqual(first as NSDictionary, replay as NSDictionary)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "semantic-replay",
            "name": "Changed",
        ])) { error in
            XCTAssertEqual((error as? BotRemoteControlAuthority.Error)?.code, -32093)
        }
        XCTAssertThrowsError(try authority.dispatch(method: "bot.settings.set", params: [
            "client_request_id": "semantic-replay",
            "key": "memory",
            "value": true,
        ])) { error in
            XCTAssertEqual((error as? BotRemoteControlAuthority.Error)?.code, -32093)
        }
    }

    func test_duplicate_copiesScheduleSpecJSON() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "dup-src",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let spec = BotScheduleSpec(model: "auto", frequency: .weekly, weekdays: [.monday]).encodedJSON()
        _ = try authority.dispatch(method: "bot.routine.create", params: [
            "client_request_id": "r1",
            "bot_id": botID,
            "name": "Morning",
            "prompt": "scan",
            "schedule_spec_json": spec,
        ])
        let sourceRouting = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "dup-route",
            "bot_id": botID,
            "host_id": "host-duplicate",
            "provider": "grok",
            "provider_instance_id": "grok-team",
            "model": "grok-4",
            "routing_mode": "explicit",
            "permission_mode": "fullAccess",
            "reasoning_effort": "high",
            "service_tier": "priority",
            "run_as_user": ["generatedUID": "duplicate-user", "shortName": "runner", "uid": 501, "gid": 20, "homePath": "/Users/runner"],
        ])
        let copy = try authority.dispatch(method: "bot.duplicate", params: [
            "client_request_id": "dup",
            "bot_id": botID,
        ])
        let specs = (copy["readback"] as? [String: Any])?["schedule_spec_jsons"] as? [String]
        XCTAssertEqual(specs, [spec])
        let copyID = try XCTUnwrap(copy["bot_id"] as? String)
        let copyRouting = try XCTUnwrap(
            ((copy["readback"] as? [String: Any])?["routing"] as? [String: Any])
        )
        XCTAssertEqual(copyRouting["bot_id"] as? String, copyID)
        XCTAssertEqual(copyRouting["provider_instance_id"] as? String, "grok-team")
        XCTAssertNotEqual(copyRouting["routing_receipt_id"] as? String,
                          sourceRouting["receipt_id"] as? String,
                          "the duplicate gets independent routing authority")

        _ = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "dup-source-change",
            "bot_id": botID,
            "provider_instance_id": "grok-source-changed",
        ])
        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let readCopy = try relaunched.dispatch(method: "bot.get", params: ["bot_id": copyID])
        let persistedRouting = try XCTUnwrap(
            (readCopy["routing"] as? [String: Any])
        )
        XCTAssertEqual(persistedRouting["provider_instance_id"] as? String, "grok-team",
                       "source changes must not drift the duplicate")
    }

    /// WHY: duplicate admission must be atomic at the account cap. A rejected
    /// copy may not mint hidden routing state or alter the source.
    func test_duplicateAtCapLeavesSourceRoutingAndBotCountUnchanged() throws {
        let source = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "dup-cap-source", "name": "Source",
        ])
        let sourceID = try XCTUnwrap(source["bot_id"] as? String)
        let route = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "dup-cap-route",
            "bot_id": sourceID,
            "provider_instance_id": "grok-cap",
        ])
        for index in 1..<BotRemoteControlAuthority.liveAccountCap {
            _ = try authority.dispatch(method: "bot.create", params: [
                "client_request_id": "dup-cap-\(index)", "name": "Bot \(index)",
            ])
        }

        XCTAssertThrowsError(try authority.dispatch(method: "bot.duplicate", params: [
            "client_request_id": "dup-cap-reject", "bot_id": sourceID,
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .cap)
        }
        let listed = try authority.dispatch(method: "bot.list", params: [:])
        XCTAssertEqual((listed["bots"] as? [[String: Any]])?.count,
                       BotRemoteControlAuthority.liveAccountCap)
        let sourceRead = try authority.dispatch(method: "bot.get", params: ["bot_id": sourceID])
        XCTAssertEqual(((sourceRead["routing"] as? [String: Any])?["routing_receipt_id"] as? String),
                       route["receipt_id"] as? String)
    }

    func test_createAtCap_doesNotCreateBot() throws {
        for i in 0..<BotRemoteControlAuthority.liveAccountCap {
            _ = try authority.dispatch(method: "bot.create", params: [
                "client_request_id": "cap-\(i)",
                "name": "Bot \(i)",
            ])
        }
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.create", params: [
                "client_request_id": "cap-overflow",
                "name": "Overflow",
            ])
        ) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .cap)
        }
        let listed = try authority.dispatch(method: "bot.list", params: [:])
        XCTAssertEqual((listed["bots"] as? [[String: Any]])?.count, BotRemoteControlAuthority.liveAccountCap)
    }

    /// A bot with one enabled routine on a daily `base + 60` slot (UTC), the
    /// autonomy switch on, and a host send that records each routine it
    /// starts in a new conversation, like the Mac's `enqueueScheduledRoutine`.
    private func scheduleRoutine(
        prefix: String,
        base: Date,
        enabled: Bool = true
    ) throws -> (botID: String, routineID: String, sends: () -> [BotRoutine]) {
        settings.update {
            $0.botsControlPlaneEnabled = true
            $0.botsAutonomyEnabled = true
        }
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "\(prefix)-bot", "name": prefix,
        ], now: base)
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        var spec = BotScheduleSpec(
            frequency: .daily,
            localTime: base.addingTimeInterval(60),
            timeZoneIdentifier: "UTC"
        )
        spec.model = "scheduled-model"
        let routine = try authority.dispatch(method: "bot.routine.create", params: [
            "client_request_id": "\(prefix)-routine",
            "bot_id": botID,
            "name": "Daily review",
            "prompt": "Review the open PRs",
            "schedule_note": spec.displayNote(),
            "schedule_spec_json": spec.encodedJSON(),
        ], now: base)
        let routineID = try XCTUnwrap((routine["readback"] as? [String: Any])?["routine_id"] as? String)
        _ = try authority.dispatch(method: "bot.routine.enable", params: [
            "client_request_id": "\(prefix)-enable",
            "bot_id": botID,
            "routine_id": routineID,
            "enabled": enabled,
        ], now: base)
        var sends: [BotRoutine] = []
        let store = self.store!
        authority.onRoutineSend = { routine in
            sends.append(routine)
            let conversation = BotConversation(botID: routine.definition.botID, title: routine.definition.name)
            try store.upsertConversation(conversation)
            return [
                "bot_id": routine.definition.botID.value.uuidString.lowercased(),
                "conversation_id": conversation.id.value.uuidString.lowercased(),
                "run_id": "run-\(sends.count)",
            ]
        }
        return (botID, routineID, { sends })
    }

    private func tick(_ requestID: String, at date: Date, hostID: String? = nil) throws -> [[String: Any]] {
        var params: [String: Any] = ["client_request_id": requestID]
        if let hostID { params["host_id"] = hostID }
        let result = try authority.dispatch(method: "bot.scheduler.tick", params: params, now: date)
        return ((result["readback"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
    }

    private func routineRow(_ authority: BotRemoteControlAuthority, botID: String) throws -> [String: Any] {
        let listed = try authority.dispatch(method: "bot.routine.list", params: ["bot_id": botID])
        return try XCTUnwrap((listed["routines"] as? [[String: Any]])?.first)
    }

    /// WHY: scheduled tasks never ran. The tick recorded a fake "completed"
    /// and started nothing. A due slot must start ONE real run (the Instruction
    /// in a new conversation), report `started` with that run, and keep it, the
    /// next slot, and the attention identity across a relaunch, so iOS shows
    /// what really happened.
    func test_dueRoutineStartsOneRealRunAndPersistsItsResultNextRunAndAttention() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let profileID = "ios-schedule-profile"
        let hostID = "host-schedule"
        try BotAttentionPushBindingStore(db: db).bind(
            profileID: profileID,
            hostID: hostID,
            deviceID: "ios-schedule-device"
        )
        let fixture = try scheduleRoutine(prefix: "due", base: base)
        let slot = base.addingTimeInterval(60)

        XCTAssertTrue(try tick("early", at: base.addingTimeInterval(30), hostID: hostID).isEmpty,
                      "nothing runs before its slot")
        XCTAssertTrue(fixture.sends().isEmpty)
        let fired = try authority.dispatch(method: "bot.scheduler.tick", params: [
            "client_request_id": "due-tick",
            "host_id": hostID,
        ], now: slot.addingTimeInterval(5))
        let firedReadback = try XCTUnwrap(fired["readback"] as? [String: Any])
        let run = try XCTUnwrap((firedReadback["runs"] as? [[String: Any]])?.first)
        XCTAssertEqual(fixture.sends().map(\.definition.prompt), ["Review the open PRs"],
                       "the slot starts one real run with the Instruction")
        XCTAssertEqual(run["result"] as? String, "started", "never a fabricated completed")
        XCTAssertEqual(run["run_id"] as? String, "run-1")
        XCTAssertEqual(run["routine_id"] as? String, fixture.routineID)
        XCTAssertEqual(run["scheduled_at"] as? Double, slot.timeIntervalSince1970)
        let conversationID = try XCTUnwrap(run["conversation_id"] as? String)
        XCTAssertTrue((firedReadback["notifications"] as? [[String: Any]])?.isEmpty ?? false,
                      "a run that only started has finished nothing yet")

        let replay = try authority.dispatch(method: "bot.scheduler.tick", params: [
            "client_request_id": "due-tick",
            "host_id": hostID,
        ], now: slot.addingTimeInterval(5))
        XCTAssertEqual(replay["readback"] as? NSDictionary, fired["readback"] as? NSDictionary)
        XCTAssertTrue(try tick("same-slot", at: slot.addingTimeInterval(35)).isEmpty,
                      "a later tick in the same slot must not start it again")
        XCTAssertEqual(fixture.sends().count, 1)

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let persisted = try routineRow(relaunched, botID: fixture.botID)
        XCTAssertEqual(persisted["last_run_id"] as? String, "run-1")
        XCTAssertEqual(persisted["last_result"] as? String, "started")
        XCTAssertEqual(persisted["last_conversation_id"] as? String, conversationID)
        XCTAssertTrue(persisted["last_error"] is NSNull)
        XCTAssertEqual(persisted["next_run_at"] as? Double, slot.addingTimeInterval(86_400).timeIntervalSince1970,
                       "the next slot is tomorrow's, not the one just spent")
        let attention = try relaunched.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((attention["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["bot_id"] as? String, fixture.botID)
        XCTAssertEqual(item["conversation_id"] as? String, conversationID)
        XCTAssertEqual(item["run_id"] as? String, "run-1")
        XCTAssertEqual(item["state"] as? String, "working")
        XCTAssertEqual(item["source"] as? String, "routine")
        XCTAssertEqual(item["profile_id"] as? String, profileID)
        XCTAssertEqual(item["host_id"] as? String, hostID)
    }

    /// WHY: fail loud. A slot whose run could not start must say so on the
    /// phone (receipt, routine row, notification) and on the Mac (Activity),
    /// never vanish or look finished.
    func test_routineThatCannotStartIsRecordedFailedAndSurfaced() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let profileID = "ios-fail-profile"
        let hostID = "host-fail"
        try BotAttentionPushBindingStore(db: db).bind(profileID: profileID, hostID: hostID, deviceID: "ios-fail")
        let fixture = try scheduleRoutine(prefix: "fail", base: base)
        authority.onRoutineSend = { _ in
            throw BotRemoteControlAuthority.Error(code: -32091, message: "Docker desktop is not ready.")
        }
        XCTAssertTrue(try tick("fail-seed", at: base).isEmpty)

        let fired = try authority.dispatch(method: "bot.scheduler.tick", params: [
            "client_request_id": "fail-tick",
            "host_id": hostID,
        ], now: base.addingTimeInterval(61))
        let readback = try XCTUnwrap(fired["readback"] as? [String: Any])
        let run = try XCTUnwrap((readback["runs"] as? [[String: Any]])?.first)
        XCTAssertEqual(run["result"] as? String, "failed")
        XCTAssertEqual(run["error"] as? String, "Docker desktop is not ready.")
        let notification = try XCTUnwrap((readback["notifications"] as? [[String: Any]])?.first)
        XCTAssertEqual(notification["profile_id"] as? String, profileID)
        XCTAssertEqual(notification["host_id"] as? String, hostID)
        XCTAssertEqual(notification["bot_id"] as? String, fixture.botID)
        XCTAssertEqual(notification["source"] as? String, "routine")
        XCTAssertEqual(notification["body"] as? String, "Scheduled task did not start: Docker desktop is not ready.")
        XCTAssertNotNil(try NotificationRepository(db: db).list().first { $0.id == notification["id"] as? String })
        let row = try routineRow(authority, botID: fixture.botID)
        XCTAssertEqual(row["last_result"] as? String, "failed")
        XCTAssertEqual(row["last_error"] as? String, "Docker desktop is not ready.")
        let macItem = try XCTUnwrap(try store.listAttention().first)
        XCTAssertEqual(macItem.kind, .blocked, "the Mac Activity shows it as needing you")
        XCTAssertEqual(macItem.detail, "Daily review: Docker desktop is not ready.")
        XCTAssertTrue(try tick("fail-again", at: base.addingTimeInterval(90)).isEmpty,
                      "a failed slot is spent, not retried every tick")
        authority.onRoutineSend = { _ in
            ["bot_id": fixture.botID, "conversation_id": UUID().uuidString.lowercased(), "run_id": "retry"]
        }
        _ = try authority.dispatch(method: "bot.routine.run", params: [
            "client_request_id": "retry-failed-routine", "bot_id": fixture.botID,
            "routine_id": fixture.routineID, "host_id": hostID,
        ], now: base.addingTimeInterval(100))
        XCTAssertTrue(try store.listAttention().isEmpty, "an admitted retry resolves the previous failure")
        XCTAssertNotNil(try store.listAttention(includeAcknowledged: true).first { $0.id == macItem.id }?.acknowledgedAt)
    }

    /// WHY: only Active tasks of live bots run, and only while automatic runs
    /// are on. Pausing, disabling, or deleting must stop the next slot.
    func test_routineNeverFiresWhenAutonomyIsOffTheTaskIsDisabledOrTheBotIsDeleted() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let active = try scheduleRoutine(prefix: "active", base: base)
        let disabled = try scheduleRoutine(prefix: "disabled", base: base, enabled: false)
        let sends = disabled.sends // the host send both bots share from here on
        XCTAssertTrue(try tick("seed", at: base).isEmpty)

        settings.update { $0.botsAutonomyEnabled = false }
        XCTAssertTrue(try tick("paused", at: base.addingTimeInterval(61)).isEmpty)
        XCTAssertTrue(sends().isEmpty, "Scheduler paused must not run anything")

        settings.update { $0.botsAutonomyEnabled = true }
        XCTAssertEqual(try tick("resumed", at: base.addingTimeInterval(86_461)).count, 1)
        XCTAssertEqual(sends().map { $0.definition.botID.value.uuidString.lowercased() }, [active.botID],
                       "only the Active task runs, and the slot the pause skipped is not caught up")

        _ = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "delete-active", "bot_id": active.botID, "confirm": "delete",
        ], now: base.addingTimeInterval(86_500))
        XCTAssertTrue(try tick("deleted", at: base.addingTimeInterval(2 * 86_400 + 61)).isEmpty,
                      "a deleted bot's task must not run")
        XCTAssertEqual(sends().count, 1)
    }

    /// WHY: the copy promises "while RemoteCode is open". Slots that passed
    /// while the app was closed must not all run at launch; a slot missed by
    /// less than one tick (the app opened right after it) still runs once.
    func test_slotMissedWhileClosedIsSkippedAtRelaunch_butOneMissedByLessThanATickRuns() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try scheduleRoutine(prefix: "closed", base: base)
        XCTAssertTrue(try tick("closed-seed", at: base).isEmpty)

        // Closed for three days: three slots passed.
        authority = BotRemoteControlAuthority(db: db, store: store, settings: settings, appSupportDirectory: supportDir)
        var relaunchSends: [BotRoutine] = []
        authority.onRoutineSend = { routine in
            relaunchSends.append(routine)
            return ["bot_id": first.botID, "conversation_id": UUID().uuidString.lowercased(), "run_id": "late"]
        }
        let reopened = base.addingTimeInterval(3 * 86_400 + 600)
        XCTAssertTrue(try tick("reopen", at: reopened).isEmpty, "no catch-up storm after a relaunch")
        XCTAssertTrue(relaunchSends.isEmpty)
        XCTAssertEqual(try routineRow(authority, botID: first.botID)["next_run_at"] as? Double,
                       base.addingTimeInterval(4 * 86_400 + 60).timeIntervalSince1970)

        // Reopened 10 s after a slot: that slot still runs, once.
        authority = BotRemoteControlAuthority(db: db, store: store, settings: settings, appSupportDirectory: supportDir)
        authority.onRoutineSend = { routine in
            relaunchSends.append(routine)
            return ["bot_id": first.botID, "conversation_id": UUID().uuidString.lowercased(), "run_id": "just-missed"]
        }
        let justAfter = base.addingTimeInterval(4 * 86_400 + 70)
        XCTAssertEqual(try tick("just-after", at: justAfter).map { $0["run_id"] as? String }, ["just-missed"])
        XCTAssertTrue(try tick("just-after-again", at: justAfter.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(relaunchSends.count, 1)
    }

    /// WHY: moving a task to another time must stop the old slot and run the
    /// new one, even though the Mac editor never touches the host runtime.
    func test_editedScheduleRunsAtItsNewTime_notAtTheOldSlot() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try scheduleRoutine(prefix: "edit", base: base)
        XCTAssertTrue(try tick("edit-seed", at: base).isEmpty)

        let botID = BotID(try XCTUnwrap(UUID(uuidString: fixture.botID)))
        var routine = try XCTUnwrap(store.listRoutines(botID: botID).first).definition
        let moved = BotScheduleSpec(frequency: .daily, localTime: base.addingTimeInterval(120), timeZoneIdentifier: "UTC")
        routine.scheduleSpecJSON = moved.encodedJSON()
        routine.scheduleNote = moved.displayNote()
        routine.updatedAt = base.addingTimeInterval(30)
        try store.saveRoutine(routine, now: base.addingTimeInterval(30))

        XCTAssertTrue(try tick("old-slot", at: base.addingTimeInterval(61)).isEmpty, "the old time no longer runs")
        XCTAssertEqual(try tick("new-slot", at: base.addingTimeInterval(121)).count, 1)
        XCTAssertEqual(fixture.sends().count, 1)
    }

    /// WHY: iOS Run now answered "accepted" and ran nothing. It must start a
    /// real run like the Mac's Test run, and fail its receipt when it cannot.
    func test_routineRunFromThePhoneStartsARealRun_andFailsItsReceiptWhenItCannot() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try scheduleRoutine(prefix: "run-now", base: base, enabled: false)
        settings.update { $0.botsAutonomyEnabled = false }
        let ran = try authority.dispatch(method: "bot.routine.run", params: [
            "client_request_id": "run-now",
            "bot_id": fixture.botID,
            "routine_id": fixture.routineID,
        ], now: base)
        XCTAssertEqual(ran["status"] as? String, "completed")
        let readback = try XCTUnwrap(ran["readback"] as? [String: Any])
        XCTAssertEqual(readback["result"] as? String, "started")
        XCTAssertEqual(readback["run_id"] as? String, "run-1")
        XCTAssertEqual(readback["automatic"] as? Bool, false)
        XCTAssertEqual(fixture.sends().map(\.definition.prompt), ["Review the open PRs"],
                       "Run now is manual: it runs even with the task off and autonomy paused")
        XCTAssertNotNil(try store.listRoutines(botID: BotID(XCTUnwrap(UUID(uuidString: fixture.botID))))
            .first?.activation.lastTestRunRequestedAt, "Run now is stamped like the Mac's Test run")

        authority.onRoutineSend = { _ in throw BotStoreError.invalidRow("Bot runtime is unavailable") }
        let failed = try authority.dispatch(method: "bot.routine.run", params: [
            "client_request_id": "run-now-fail",
            "bot_id": fixture.botID,
            "routine_id": fixture.routineID,
        ], now: base)
        XCTAssertEqual(failed["status"] as? String, "failed")
        XCTAssertEqual((failed["readback"] as? [String: Any])?["result"] as? String, "failed")
        XCTAssertEqual(try routineRow(authority, botID: fixture.botID)["last_result"] as? String, "failed")
        // A manual run that failed is not a missed schedule: say which it was.
        XCTAssertEqual(try store.listAttention().first?.title, "Task run did not start")
        let item = try XCTUnwrap(
            (try authority.dispatch(method: "bot.attention.list", params: [:])["items"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(item["detail"] as? String, "Task run did not start: Invalid bot row: Bot runtime is unavailable")
    }

    /// WHY: every sidecar write re-encodes the scheduler history. Once tasks
    /// really run (hourly, for months), an unbounded history would make every
    /// bot.* mutation slower and the settings row grow without end.
    func test_schedulerRunHistoryKeepsOnlyRecentRuns() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try scheduleRoutine(prefix: "history", base: base)
        let limit = BotRemoteControlAuthority.schedulerRunHistoryLimit
        for index in 0..<(limit + 10) {
            _ = try authority.dispatch(method: "bot.routine.run", params: [
                "client_request_id": "history-\(index)",
                "bot_id": fixture.botID,
                "routine_id": fixture.routineID,
            ], now: base.addingTimeInterval(Double(index)))
        }
        let stored = try XCTUnwrap(SettingsRepository(db: db).get("bot.remote.scheduler_runs"))
        let runs = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(runs.count, limit)
        XCTAssertEqual(runs.last?["run_id"] as? String, "run-\(limit + 10)", "the newest run is kept")
    }

    /// WHY: Notify Off is a delivery preference, not permission to erase Bot
    /// attention. Muted work must remain authoritative across relaunch, while
    /// OS/private-push projection stays empty and a later enabled delivery
    /// resumes with the exact host/profile/item/Bot/source tuple.
    func test_notificationsPreferenceSuppressesDeliveryWithoutCorruptingAttentionOrReplay() throws {
        let profileID = "ios-muted-profile"
        let hostID = "host-muted"
        try BotAttentionPushBindingStore(db: db).bind(
            profileID: profileID,
            hostID: hostID,
            deviceID: "ios-muted-device"
        )
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "muted-create",
            "name": "Quiet Bot",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "muted-conversation",
            "bot_id": botID,
            "title": "Quiet work",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        _ = try authority.dispatch(method: "bot.notify.set", params: [
            "client_request_id": "muted-off",
            "bot_id": botID,
            "enabled": false,
        ])
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "muted-send",
            "host_id": hostID,
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "Complete without delivery",
        ])
        let mutedStop = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "muted-stop",
            "host_id": hostID,
            "bot_id": botID,
        ])
        XCTAssertNil((mutedStop["readback"] as? [String: Any])?["notification"])
        XCTAssertTrue(try NotificationRepository(db: db).list().isEmpty)

        let mutedList = try authority.dispatch(method: "bot.attention.list", params: [:])
        let mutedItem = try XCTUnwrap((mutedList["items"] as? [[String: Any]])?.first)
        let mutedItemID = try XCTUnwrap(mutedItem["id"] as? String)
        XCTAssertEqual(mutedItem["profile_id"] as? String, profileID)
        XCTAssertEqual(mutedItem["host_id"] as? String, hostID)
        XCTAssertEqual(mutedItem["attention_item_id"] as? String, mutedItemID)
        XCTAssertEqual(mutedItem["bot_id"] as? String, botID)
        XCTAssertEqual(mutedItem["source"] as? String, "bot")
        XCTAssertEqual(mutedItem["state"] as? String, "finished")

        authority = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let restored = try authority.dispatch(method: "bot.attention.list", params: [:])
        let restoredItem = try XCTUnwrap((restored["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(restoredItem as NSDictionary, mutedItem as NSDictionary)

        _ = try authority.dispatch(method: "bot.notify.set", params: [
            "client_request_id": "muted-on",
            "bot_id": botID,
            "enabled": true,
        ])
        let mutedReplay = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "muted-stop",
            "host_id": hostID,
            "bot_id": botID,
        ])
        XCTAssertEqual(
            mutedReplay["readback"] as? NSDictionary,
            mutedStop["readback"] as? NSDictionary
        )
        XCTAssertTrue(
            try NotificationRepository(db: db).list().isEmpty,
            "re-enabling must not replay an already suppressed terminal effect"
        )

        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "resumed-send",
            "host_id": hostID,
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "Complete with delivery",
        ])
        let resumedStop = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "resumed-stop",
            "host_id": hostID,
            "bot_id": botID,
        ])
        let notification = try XCTUnwrap(
            (resumedStop["readback"] as? [String: Any])?["notification"] as? [String: Any]
        )
        let notificationID = try XCTUnwrap(notification["id"] as? String)
        XCTAssertEqual(notification["profile_id"] as? String, profileID)
        XCTAssertEqual(notification["host_id"] as? String, hostID)
        XCTAssertEqual(notification["attention_item_id"] as? String, notificationID)
        XCTAssertEqual(notification["notification_id"] as? String, notificationID)
        XCTAssertEqual(notification["bot_id"] as? String, botID)
        XCTAssertEqual(notification["source"] as? String, "bot")
        XCTAssertEqual(try NotificationRepository(db: db).list().map(\.id), [notificationID])
    }

    /// WHY: a host can have multiple registered iOS devices. Without an exact
    /// target in the Bot mutation, selecting the latest registration would send
    /// another profile's notification, so ambiguous hosts must remain eventless.
    func test_finishedAttentionFailsClosedWithTwoRegisteredDevices() throws {
        let hostID = "host-two-devices"
        try BotAttentionPushBindingStore(db: db).bind(
            profileID: "profile-device-a",
            hostID: hostID,
            deviceID: "device-a"
        )
        try BotAttentionPushBindingStore(db: db).bind(
            profileID: "profile-device-b",
            hostID: hostID,
            deviceID: "device-b"
        )
        XCTAssertNil(BotAttentionPushBindingStore(db: db).unique(hostID: hostID))
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "ambiguous-bot",
            "name": "Ambiguous",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "ambiguous-send",
            "host_id": hostID,
            "bot_id": botID,
            "text": "Finish safely",
        ])
        let stopped = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "ambiguous-stop",
            "host_id": hostID,
            "bot_id": botID,
        ])
        XCTAssertEqual(stopped["status"] as? String, "completed")
        XCTAssertNil((stopped["readback"] as? [String: Any])?["notification"])
        XCTAssertTrue(try NotificationRepository(db: db).list().isEmpty)
        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((listed["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["host_id"] as? String, hostID)
        XCTAssertNil(item["profile_id"])
    }

    func test_reservedCapability_neverGetsPositiveParity() {
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.reserved.probe", params: ["capability_id": "U034"])
        ) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .reserved)
        }
        for id in ["U038", "U039", "U045"] {
            XCTAssertThrowsError(
                try authority.dispatch(method: "bot.create", params: [
                    "client_request_id": "res-\(id)",
                    "capability_id": id,
                    "name": "nope",
                ])
            )
        }
    }

    func test_avatar_requiresEachNamedShapeAndHue() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "av",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        XCTAssertEqual(BotRemoteControlAuthority.blobatarShapes, BotBlobatarShape.allCases.map(\.rawValue))
        XCTAssertEqual(BotRemoteControlAuthority.blobatarHues, ["auto"] + BotBlobatar.studioHues.map(\.id))
        for shape in BotRemoteControlAuthority.blobatarShapes {
            for hue in BotRemoteControlAuthority.blobatarHues {
                let result = try authority.dispatch(method: "bot.avatar.set", params: [
                    "client_request_id": "av-\(shape)-\(hue)",
                    "bot_id": botID,
                    "shape": shape,
                    "hue": hue,
                ])
                let readback = result["readback"] as? [String: Any]
                XCTAssertEqual(readback?["shape"] as? String, shape)
                XCTAssertEqual(readback?["hue"] as? String, hue)
                let token = try XCTUnwrap(readback?["avatar_symbol"] as? String)
                let spec = try XCTUnwrap(BotBlobatarSpec.parse(token), "remote saves must render on the host")
                XCTAssertEqual(spec.shape.rawValue, shape)
                XCTAssertEqual(spec.hue.token, hue)
                let stored = try XCTUnwrap(store.get(id: BotID(UUID(uuidString: botID)!)))
                XCTAssertEqual(stored.avatarSymbol, token)
            }
        }
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.avatar.set", params: [
                "client_request_id": "av-bad",
                "bot_id": botID,
                "shape": "invented",
                "hue": "auto",
            ])
        )
    }

    func test_avatar_remoteSavePreservesThePreviewSeedAfterRename() throws {
        let bot = try store.create(name: "Renamed Developer", title: "", description: "", handle: "elephant-developer")
        let preview = BotBlobatarSpec.default.selecting(shape: .ghost, hue: .named("cyan"), name: "Developer")
        let params: [String: Any] = [
            "client_request_id": "avatar-preview",
            "bot_id": bot.id.value.uuidString, "shape": "ghost", "hue": "cyan", "avatar_symbol": preview.token,
        ]
        _ = try authority.dispatch(method: "bot.avatar.set", params: params)
        let stored = try XCTUnwrap(store.get(id: bot.id))
        XCTAssertEqual(stored.avatarSymbol, preview.token)
        var invalid = params
        invalid["client_request_id"] = "avatar-invalid"
        invalid["hue"] = "red"
        XCTAssertThrowsError(try authority.dispatch(method: "bot.avatar.set", params: invalid))
        XCTAssertEqual(try store.get(id: bot.id)?.avatarSymbol, preview.token)
    }

    /// WHY: a transcript URL is untrusted prose until it is bound to the exact
    /// selected conversation and current host-owned Browser surface.
    func test_linkOpen_requiresExactConversationSurfaceAndGeneration() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "br",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.link.open", params: [
            "client_request_id": "link-unbound", "bot_id": botID,
            "url": "http://127.0.0.1:3000",
        ]), "unbound transcript prose must never enqueue a Browser open")

        let params = try webLinkParams(
            botID: botID,
            requestID: "link-1",
            url: "http://127.0.0.1:3000"
        )
        let result = try authority.dispatch(method: "bot.link.open", params: params)
        let readback = result["readback"] as? [String: Any]
        XCTAssertEqual(readback?["host_first"] as? Bool, true)
        XCTAssertEqual(readback?["action"] as? String, "open")
        XCTAssertEqual(readback?["conversation_id"] as? String, params["conversation_id"] as? String)
        XCTAssertEqual(readback?["surface_id"] as? String, params["surface_id"] as? String)
        XCTAssertEqual(readback?["url"] as? String, "http://127.0.0.1:3000")
        XCTAssertGreaterThan(readback?["generation"] as? Int ?? 0, 0)
        XCTAssertNotNil(result["receipt_id"] as? String)

        for (index, key) in ["host_id", "conversation_id", "surface_id"].enumerated() {
            var crossed = try webLinkParams(
                botID: botID,
                requestID: "link-cross-\(index)",
                url: "https://example.test/\(index)"
            )
            crossed[key] = "wrong-\(key)"
            XCTAssertThrowsError(try authority.dispatch(method: "bot.link.open", params: crossed))
        }
        var stale = try webLinkParams(botID: botID, requestID: "link-stale", url: "https://example.test/stale")
        stale["expected_generation"] = -1
        XCTAssertThrowsError(try authority.dispatch(method: "bot.link.open", params: stale))
        XCTAssertThrowsError(try authority.dispatch(
            method: "bot.link.open",
            params: webLinkParams(botID: botID, requestID: "link-missing-host", url: "https:///path")
        ))
    }

    /// WHY: a transcript file mention is not authority. Only a live opaque
    /// host grant can open it, and no raw path may cross the paired RPC.
    func test_linkOpen_fileGrantRejectsCrossBotStaleRevokedAndRelaunchUse() throws {
        let owner = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "file-link-owner", "name": "Owner",
        ])
        let ownerID = try XCTUnwrap(owner["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "file-link-conversation", "bot_id": ownerID, "title": "Files",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let root = try fileRootGrant(botID: ownerID, hostID: "host-a")
        let created = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "file-link-create",
            "host_id": "host-a",
            "bot_id": ownerID,
            "root_handle": root.handle,
            "expected_generation": root.generation,
            "expected_cas": root.cas,
            "relative_path": "report.md",
            "op": "write",
            "contents": "report",
        ])
        let fileState = try XCTUnwrap(created["readback"] as? [String: Any])
        var openedPath: String?
        authority.onOpenFile = { _, path, _, _ in openedPath = path }
        let exact: [String: Any] = [
            "client_request_id": "file-link-open",
            "host_id": "host-a",
            "bot_id": ownerID,
            "conversation_id": conversationID,
            "host_first": true,
            "link_kind": "file",
            "root": "bot_home",
            "root_handle": try XCTUnwrap(fileState["root_handle"] as? String),
            "handle": try XCTUnwrap(fileState["handle"] as? String),
            "expected_generation": try XCTUnwrap(fileState["generation"] as? Int),
            "expected_cas": try XCTUnwrap(fileState["root_cas"] as? String),
            "entry_generation": try XCTUnwrap(fileState["entry_generation"] as? Int),
            "entry_cas": try XCTUnwrap(fileState["entry_cas"] as? String),
        ]
        let opened = try authority.dispatch(method: "bot.link.open", params: exact)
        let readback = try XCTUnwrap(opened["readback"] as? [String: Any])
        XCTAssertEqual(openedPath, "report.md")
        XCTAssertEqual(readback["link_kind"] as? String, "file")
        XCTAssertEqual(readback["handle"] as? String, exact["handle"] as? String)
        XCTAssertNil(exact["path"])
        XCTAssertNil(exact["url"], "raw file paths and file URLs must never cross bot.link.open")
        XCTAssertNil(readback["path"], "the paired readback must retain only opaque file authority")

        let other = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "file-link-other", "name": "Other",
        ])
        let otherID = try XCTUnwrap(other["bot_id"] as? String)
        let otherConversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "file-link-other-conversation", "bot_id": otherID, "title": "Other",
        ])
        var crossed = exact
        crossed["client_request_id"] = "file-link-crossed"
        crossed["bot_id"] = otherID
        crossed["conversation_id"] = (otherConversation["readback"] as? [String: Any])?["conversation_id"]
        XCTAssertThrowsError(try authority.dispatch(method: "bot.link.open", params: crossed))

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        var afterRelaunch = exact
        afterRelaunch["client_request_id"] = "file-link-relaunch"
        XCTAssertThrowsError(try relaunched.dispatch(method: "bot.link.open", params: afterRelaunch),
                             "persisted grants must be reissued by a current-process files.list")

        let rotated = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "file-link-rotate",
            "host_id": "host-a",
            "bot_id": ownerID,
            "root_handle": fileState["root_handle"] as Any,
            "expected_generation": fileState["generation"] as Any,
            "expected_cas": fileState["root_cas"] as Any,
            "relative_path": "new.md",
            "op": "write",
            "contents": "new",
        ])
        var stale = exact
        stale["client_request_id"] = "file-link-stale"
        XCTAssertThrowsError(try authority.dispatch(method: "bot.link.open", params: stale))

        let rotatedState = try XCTUnwrap(rotated["readback"] as? [String: Any])
        _ = try authority.dispatch(method: "bot.files.location.set", params: [
            "client_request_id": "file-link-revoke",
            "host_id": "host-a",
            "bot_id": ownerID,
            "root": "docker_home",
            "previous_root_handle": rotatedState["root_handle"] as Any,
            "expected_generation": rotatedState["generation"] as Any,
            "expected_cas": rotatedState["root_cas"] as Any,
        ])
        var revoked = exact
        revoked["client_request_id"] = "file-link-revoked"
        XCTAssertThrowsError(try authority.dispatch(method: "bot.link.open", params: revoked))
    }

    func test_filesMutate_requiresOpaqueGenerationBoundGrantAndRejectsPathEscape() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "fl",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.files.mutate", params: [
                "client_request_id": "raw-path-bypass",
                "bot_id": botID,
                "path": "MEMORY.md",
                "op": "write",
            ])
        )
        let grant = try fileRootGrant(botID: botID)
        XCTAssertFalse(grant.cas.isEmpty)
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.files.mutate", params: [
                "client_request_id": "esc",
                "bot_id": botID,
                "root_handle": grant.handle,
                "expected_generation": grant.generation,
                "expected_cas": grant.cas,
                "relative_path": "../etc/passwd",
                "op": "write",
            ])
        )
        let wrote = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "ok",
            "bot_id": botID,
            "root_handle": grant.handle,
            "expected_generation": grant.generation,
            "expected_cas": grant.cas,
            "relative_path": "MEMORY.md",
            "op": "write",
        ])
        let handle = (wrote["readback"] as? [String: Any])?["handle"] as? String
        XCTAssertFalse(handle?.contains(botID) == true, "opaque grants must not encode Bot identity")
        XCTAssertFalse(handle?.contains("/Users") == true)
        XCTAssertEqual((wrote["readback"] as? [String: Any])?["generation"] as? Int, grant.generation + 1)
        XCTAssertNotEqual((wrote["readback"] as? [String: Any])?["root_cas"] as? String, grant.cas)
        XCTAssertEqual(
            (wrote["readback"] as? [String: Any])?["entry_cas"] as? String,
            (wrote["readback"] as? [String: Any])?["root_cas"] as? String
        )
    }

    func test_forceStop_returnsTerminalReadbackDistinctFromMissingRun() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "st",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "run",
            "bot_id": botID,
            "text": "go",
        ])
        let stopped = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "stop-1",
            "bot_id": botID,
        ])
        let readback = stopped["readback"] as? [String: Any]
        XCTAssertEqual(readback?["force"] as? Bool, true)
        XCTAssertEqual(readback?["terminal"] as? Bool, true)
        XCTAssertEqual(readback?["accepted"] as? Bool, true)
    }

    func test_peerAsk_storesDurableReceiptForLostResponseReplay() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "peer-bot",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.peer.ask", params: [
            "client_request_id": "peer-1",
            "bot_id": botID,
            "handle": "scout",
            "prompt": "status",
        ])
        let again = try authority.dispatch(method: "bot.peer.ask", params: [
            "client_request_id": "peer-1",
            "bot_id": botID,
            "handle": "scout",
            "prompt": "status",
        ])
        XCTAssertEqual(again["request_id"] as? String, "peer-1")
        let status = try authority.dispatch(method: "bot.peer.receipt.status", params: [
            "client_request_id": "peer-1",
        ])
        XCTAssertEqual(status["status"] as? String, "completed")
    }

    func test_guestUsesVncHtml_notEmbedHtml() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "guest",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let started = try authority.dispatch(
            method: "bot.guest.start",
            params: guestStartParams(botID: botID, requestID: "g1")
        )
        let readback = started["readback"] as? [String: Any]
        XCTAssertEqual(readback?["viewer"] as? String, "/vnc.html")
        XCTAssertEqual(readback?["embed_html_is_not_runtime"] as? Bool, true)
    }

    func test_pinHideDelete_areIndependentDirections() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "phd",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.set_pinned", params: [
            "client_request_id": "pin", "bot_id": botID, "pinned": true,
        ])
        _ = try authority.dispatch(method: "bot.set_hidden", params: [
            "client_request_id": "hide", "bot_id": botID, "hidden": true,
        ])
        let hiddenList = try authority.dispatch(method: "bot.list", params: ["include_hidden": false])
        XCTAssertEqual((hiddenList["bots"] as? [[String: Any]])?.count, 0)
        let shown = try authority.dispatch(method: "bot.list", params: ["include_hidden": true])
        XCTAssertEqual((shown["bots"] as? [[String: Any]])?.first?["pinned"] as? Bool, true)
        let pending = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "del-ask", "bot_id": botID,
        ])
        XCTAssertEqual((pending["readback"] as? [String: Any])?["confirm_required"] as? Bool, true)
        XCTAssertEqual(try store.list(includeHidden: true).count, 1)
        _ = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "del-yes", "bot_id": botID, "confirm": "delete",
        ])
        XCTAssertEqual(try store.list(includeHidden: true).count, 0)
    }

    func test_reorder_roundTripsThroughBotList_becauseClientsRefetchOrderFromTheHost() throws {
        var ids: [String] = []
        for (index, name) in ["Aaa", "Bbb", "Ccc"].enumerated() {
            let created = try authority.dispatch(method: "bot.create", params: [
                "client_request_id": "ro-create-\(index)", "name": name,
            ])
            ids.append(try XCTUnwrap(created["bot_id"] as? String))
        }
        let before = try authority.dispatch(method: "bot.list", params: [:])
        XCTAssertTrue((before["bots"] as? [[String: Any]])?.allSatisfy { $0["sort_order"] is NSNull } == true)

        let result = try authority.dispatch(method: "bot.reorder", params: [
            "client_request_id": "ro-1", "ordered_bot_ids": [ids[0], ids[2], ids[1]],
        ])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["status"] as? String, "completed")
        let listed = try XCTUnwrap(try authority.dispatch(method: "bot.list", params: [:])["bots"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["id"] as? String }, [ids[0], ids[2], ids[1]])
        XCTAssertEqual(listed.map { $0["sort_order"] as? Int }, [0, 1, 2])

        XCTAssertThrowsError(try authority.dispatch(method: "bot.reorder", params: [
            "client_request_id": "ro-2", "ordered_bot_ids": [UUID().uuidString.lowercased()],
        ]), "unknown id is rejected like other bot RPCs")
        XCTAssertThrowsError(try authority.dispatch(method: "bot.reorder", params: [
            "client_request_id": "ro-3", "ordered_bot_ids": ["nope"],
        ]))
    }

    func test_deleteClearsOnlyThatBotsLiveAttentionAndSelectionAcrossRelaunch() throws {
        // WHY: deleting one teammate must close its transient work without
        // erasing another teammate's active run, attention, or selection.
        let deleted = try createLiveBot(prefix: "delete-a", name: "Delete A")
        let survivor = try createLiveBot(prefix: "delete-b", name: "Keep B")

        _ = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "delete-a", "bot_id": deleted.botID, "confirm": "delete",
        ], now: Date(timeIntervalSince1970: 1_700_000_600))

        let remaining = try authority.dispatch(method: "bot.attention.list", params: [:])
        XCTAssertEqual(Set((remaining["items"] as? [[String: Any]] ?? []).compactMap { $0["bot_id"] as? String }), [survivor.botID])
        XCTAssertFalse(authority.settleRuntime(botID: deleted.botID, runID: deleted.runID, failed: false))
        XCTAssertTrue(authority.settleRuntime(botID: survivor.botID, runID: survivor.runID, failed: false))
        let selections = try sidecarObject("bot.remote.selected_conversations")
        XCTAssertNil(selections[deleted.botID])
        XCTAssertEqual(selections[survivor.botID] as? String, survivor.conversationID)
        XCTAssertNotEqual(deleted.conversationID, survivor.conversationID)

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let restored = try relaunched.dispatch(method: "bot.attention.list", params: [:])
        XCTAssertEqual(Set((restored["items"] as? [[String: Any]] ?? []).compactMap { $0["bot_id"] as? String }), [survivor.botID])
    }

    func test_deleteClearsOnlyExactRoutingAndConsumedReceiptAcrossRelaunch() throws {
        // WHY: deleting Bot A must not leave executable routing authority for
        // A or disturb Bot B's independent route, including after relaunch.
        let a = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "route-delete-a-create", "name": "Delete A",
        ])
        let b = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "route-delete-b-create", "name": "Keep B",
        ])
        let aID = try XCTUnwrap(a["bot_id"] as? String)
        let bID = try XCTUnwrap(b["bot_id"] as? String)
        let routeA = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "route-delete-a", "bot_id": aID,
            "provider": "grok", "provider_instance_id": "grok-a", "routing_mode": "auto",
        ])
        let routeB = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "route-delete-b", "bot_id": bID,
            "provider": "codex", "provider_instance_id": "codex-b", "routing_mode": "auto",
        ])
        let aReceipt = try XCTUnwrap(routeA["receipt_id"] as? String)
        let bReceipt = try XCTUnwrap(routeB["receipt_id"] as? String)
        var send = try XCTUnwrap(routeA["readback"] as? [String: Any])
        send["client_request_id"] = "route-delete-a-send"
        send["text"] = "consume exact route"
        _ = try authority.dispatch(method: "bot.send", params: send)
        XCTAssertTrue(try sidecarStringSet("bot.remote.routing_consumed").contains(aReceipt))

        _ = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "route-delete-a-confirm", "bot_id": aID, "confirm": "delete",
        ])

        let persisted = try sidecarObject("bot.remote.routing")
        XCTAssertNil(persisted[aID])
        XCTAssertEqual((persisted[bID] as? [String: Any])?["routing_receipt_id"] as? String, bReceipt)
        XCTAssertFalse(try sidecarStringSet("bot.remote.routing_consumed").contains(aReceipt))

        let relaunched = BotRemoteControlAuthority(
            db: db, store: store, settings: settings, appSupportDirectory: supportDir
        )
        let surviving = try relaunched.dispatch(method: "bot.get", params: ["bot_id": bID])
        XCTAssertEqual(
            ((surviving["routing"] as? [String: Any])?["routing_receipt_id"] as? String), bReceipt
        )
    }

    func test_deleteQuarantinesOnlyExactBotFileAndGuestAuthority() throws {
        // WHY: a terminal delete receipt must mean Bot A has no executable
        // file/viewer authority while Bot B's independent grants remain live.
        let a = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "cleanup-a-create", "name": "Delete A",
        ])
        let b = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "cleanup-b-create", "name": "Keep B",
        ])
        let aID = try XCTUnwrap(a["bot_id"] as? String)
        let bID = try XCTUnwrap(b["bot_id"] as? String)
        let aGrant = try fileRootGrant(botID: aID, hostID: "host-a")
        let bGrant = try fileRootGrant(botID: bID, hostID: "host-b")
        _ = try guestState(botID: aID)
        _ = try guestState(botID: bID)
        let aUUID = try XCTUnwrap(UUID(uuidString: aID))
        let bUUID = try XCTUnwrap(UUID(uuidString: bID))
        let aBot = try XCTUnwrap(store.get(id: BotID(aUUID)))
        let bBot = try XCTUnwrap(store.get(id: BotID(bUUID)))
        let aHome = BotHome(appSupportDirectory: supportDir, bot: aBot)
        let bHome = BotHome(appSupportDirectory: supportDir, bot: bBot)
        try aHome.ensure(name: aBot.name, handle: aBot.handle, title: aBot.title, description: "A", soul: "A")
        try bHome.ensure(name: bBot.name, handle: bBot.handle, title: bBot.title, description: "B", soul: "B")
        _ = try BotGuestHome.ensure(appSupport: supportDir, botID: BotID(aUUID))
        _ = try BotGuestHome.ensure(appSupport: supportDir, botID: BotID(bUUID))
        var teardownCount = 0
        authority.onDockerClear = { id in
            XCTAssertEqual(id, BotID(aUUID))
            XCTAssertFalse(self.authority.isFileHandleExecutableForTesting(aGrant.handle),
                           "A grants must be quarantined before external teardown")
            teardownCount += 1
        }

        let deleted = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "cleanup-a-delete", "bot_id": aID, "confirm": "delete",
        ])
        let readback = try XCTUnwrap(deleted["readback"] as? [String: Any])
        XCTAssertEqual(deleted["status"] as? String, "completed")
        XCTAssertEqual(readback["cleanup_complete"] as? Bool, true)
        XCTAssertEqual(teardownCount, 1)
        XCTAssertFalse(authority.isFileHandleExecutableForTesting(aGrant.handle))
        XCTAssertTrue(authority.isFileHandleExecutableForTesting(bGrant.handle))

        let grants = try sidecarObject("bot.remote.file_grants")
        XCTAssertFalse(grants.values.contains { ($0 as? [String: Any])?["bot_id"] as? String == aID })
        XCTAssertTrue(grants.values.contains { ($0 as? [String: Any])?["bot_id"] as? String == bID })
        XCTAssertFalse(try sidecarObject("bot.remote.file_generations").keys.contains { $0.hasPrefix("\(aID)|") })
        XCTAssertFalse(try sidecarObject("bot.remote.file_cas").keys.contains { $0.hasPrefix("\(aID)|") })
        XCTAssertNil(try sidecarObject("bot.remote.guest_state")[aID])
        XCTAssertNotNil(try sidecarObject("bot.remote.guest_state")[bID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: BotGuestHome.url(appSupport: supportDir, botID: BotID(aUUID)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: BotGuestHome.url(appSupport: supportDir, botID: BotID(bUUID)).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aHome.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bHome.root.path))

        _ = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "cleanup-b-write", "host_id": "host-b", "bot_id": bID,
            "root_handle": bGrant.handle, "expected_generation": bGrant.generation,
            "expected_cas": bGrant.cas, "relative_path": "preserved.txt", "op": "write",
            "contents": "B",
        ])
    }

    func test_deleteRestoresQuarantineWhenBotStoreDeleteFails() throws {
        // WHY: quarantine precedes BotStore deletion, but a failed durable
        // tombstone must restore A because no terminal delete receipt exists.
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "rollback-create", "name": "Rollback A",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let grant = try fileRootGrant(botID: botID, hostID: "host-a")
        _ = try guestState(botID: botID)
        try db.execute("""
            CREATE TRIGGER fail_bot_delete
            BEFORE UPDATE OF deleted_at ON bots
            WHEN OLD.id = '\(botID)'
            BEGIN SELECT RAISE(ABORT, 'injected bot delete failure'); END;
            """)
        var teardownCount = 0
        authority.onDockerClear = { _ in teardownCount += 1 }

        XCTAssertThrowsError(try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "rollback-delete", "bot_id": botID, "confirm": "delete",
        ]))
        XCTAssertEqual(teardownCount, 0, "external teardown starts only after the durable tombstone")
        XCTAssertNotNil(try store.get(id: BotID(try XCTUnwrap(UUID(uuidString: botID)))))
        _ = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "rollback-write", "host_id": "host-a", "bot_id": botID,
            "root_handle": grant.handle, "expected_generation": grant.generation,
            "expected_cas": grant.cas, "relative_path": "still-authorized.txt", "op": "write",
            "contents": "restored",
        ])
    }

    func test_deleteTeardownFailureIsPartialAndNeverReplays() throws {
        // WHY: response loss or an external teardown error must not dispatch a
        // destructive cleanup twice or masquerade as a fully completed delete.
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "partial-create", "name": "Partial A",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let botUUID = try XCTUnwrap(UUID(uuidString: botID))
        let grant = try fileRootGrant(botID: botID)
        _ = try guestState(botID: botID)
        _ = try BotGuestHome.ensure(appSupport: supportDir, botID: BotID(botUUID))
        var teardownCount = 0
        authority.onDockerClear = { _ in
            teardownCount += 1
            throw BotRemoteControlAuthority.Error(code: -32088, message: "injected teardown failure")
        }
        let params: [String: Any] = [
            "client_request_id": "partial-delete", "bot_id": botID, "confirm": "delete",
        ]

        let first = try authority.dispatch(method: "bot.delete", params: params)
        let replay = try authority.dispatch(method: "bot.delete", params: params)
        XCTAssertEqual(first["status"] as? String, "partial")
        XCTAssertEqual(replay["receipt_id"] as? String, first["receipt_id"] as? String)
        XCTAssertEqual(teardownCount, 1)
        let readback = try XCTUnwrap(first["readback"] as? [String: Any])
        XCTAssertEqual(readback["cleanup_complete"] as? Bool, false)
        XCTAssertEqual(readback["cleanup_residuals"] as? [String], ["container_runtime"])
        XCTAssertNotNil(
            try store.get(id: BotID(botUUID))?.deletedAt,
            "the durable Bot tombstone must survive partial teardown"
        )
        XCTAssertFalse(authority.isFileHandleExecutableForTesting(grant.handle))
        XCTAssertNil(try sidecarObject("bot.remote.guest_state")[botID])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: BotGuestHome.url(appSupport: supportDir, botID: BotID(botUUID)).path),
            "container teardown failure must not skip the independent Bot Home wipe"
        )
    }

    func test_deleteDockerBotWhoseGuestARunStarted_tearsDownItsContainer() throws {
        // WHY: in the sandbox E2E a group turn started a Docker bot's
        // container (no `bot.guest.start`, so no remote guest state). A paired
        // device's `bot.delete` then reported cleanup_complete while the
        // container kept running. A Logical-space bot must not pay a teardown.
        let docker = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "docker-create", "name": "Docker A",
        ])
        let dockerID = try XCTUnwrap(docker["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.desktop.set", params: [
            "client_request_id": "docker-desktop", "bot_id": dockerID, "kind": "dockerDesktop",
        ])
        let logical = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "logical-create", "name": "Logical B",
        ])
        let logicalID = try XCTUnwrap(logical["bot_id"] as? String)
        var cleared: [BotID] = []
        authority.onDockerClear = { cleared.append($0) }

        let deleted = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "docker-delete", "bot_id": dockerID, "confirm": "delete",
        ])
        _ = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "logical-delete", "bot_id": logicalID, "confirm": "delete",
        ])

        XCTAssertEqual(cleared, [BotID(try XCTUnwrap(UUID(uuidString: dockerID)))])
        XCTAssertEqual(deleted["status"] as? String, "completed")
    }

    func test_deleteSidecarFailureIsPartialAndRelaunchPrunesLegacyAuthority() throws {
        // WHY: a sidecar write can fail after BotStore commits. The receipt must
        // expose that residual, and relaunch must heal stale A without touching B.
        let a = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "sidecar-a-create", "name": "Delete A",
        ])
        let b = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "sidecar-b-create", "name": "Keep B",
        ])
        let aID = try XCTUnwrap(a["bot_id"] as? String)
        let bID = try XCTUnwrap(b["bot_id"] as? String)
        let aGrant = try fileRootGrant(botID: aID)
        let bGrant = try fileRootGrant(botID: bID)
        for (prefix, botID, grant) in [("a", aID, aGrant), ("b", bID, bGrant)] {
            _ = try authority.dispatch(method: "bot.files.mutate", params: [
                "client_request_id": "sidecar-\(prefix)-write", "bot_id": botID,
                "root_handle": grant.handle, "expected_generation": grant.generation,
                "expected_cas": grant.cas, "relative_path": "state.txt", "op": "write",
                "contents": prefix,
            ])
        }
        _ = try guestState(botID: aID)
        _ = try guestState(botID: bID)
        authority.onDockerClear = { _ in }
        try db.execute("""
            CREATE TRIGGER fail_cleanup_sidecars
            BEFORE UPDATE ON settings
            WHEN OLD.key IN (
                'bot.remote.file_grants', 'bot.remote.file_generations',
                'bot.remote.file_cas', 'bot.remote.guest_state'
            )
            BEGIN SELECT RAISE(ABORT, 'injected cleanup sidecar failure'); END;
            """)

        let deleted = try authority.dispatch(method: "bot.delete", params: [
            "client_request_id": "sidecar-a-delete", "bot_id": aID, "confirm": "delete",
        ])
        XCTAssertEqual(deleted["status"] as? String, "partial")
        let residuals = Set((deleted["readback"] as? [String: Any])?["cleanup_residuals"] as? [String] ?? [])
        XCTAssertEqual(residuals, [
            "sidecar:bot.remote.file_cas", "sidecar:bot.remote.file_generations",
            "sidecar:bot.remote.file_grants", "sidecar:bot.remote.guest_state",
        ])
        XCTAssertTrue(try sidecarObject("bot.remote.file_grants").values.contains {
            ($0 as? [String: Any])?["bot_id"] as? String == aID
        })
        XCTAssertNotNil(try sidecarObject("bot.remote.guest_state")[aID])

        try db.execute("DROP TRIGGER fail_cleanup_sidecars;")
        let relaunched = BotRemoteControlAuthority(
            db: db, store: store, settings: settings, appSupportDirectory: supportDir
        )
        let healedGrants = try sidecarObject("bot.remote.file_grants")
        XCTAssertFalse(healedGrants.values.contains { ($0 as? [String: Any])?["bot_id"] as? String == aID })
        XCTAssertTrue(healedGrants.values.contains { ($0 as? [String: Any])?["bot_id"] as? String == bID })
        XCTAssertFalse(try sidecarObject("bot.remote.file_generations").keys.contains { $0.hasPrefix("\(aID)|") })
        XCTAssertTrue(try sidecarObject("bot.remote.file_generations").keys.contains { $0.hasPrefix("\(bID)|") })
        XCTAssertFalse(try sidecarObject("bot.remote.file_cas").keys.contains { $0.hasPrefix("\(aID)|") })
        XCTAssertTrue(try sidecarObject("bot.remote.file_cas").keys.contains { $0.hasPrefix("\(bID)|") })
        XCTAssertNil(try sidecarObject("bot.remote.guest_state")[aID])
        XCTAssertNotNil(try sidecarObject("bot.remote.guest_state")[bID])
        let receipt = try relaunched.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "sidecar-a-delete",
        ])
        XCTAssertEqual(receipt["status"] as? String, "partial", "receipt history remains audit-only")
    }

    func test_discardNewClearsOnlyThatBotsTransientState() throws {
        // WHY: canceling an unpublished Bot uses the same destructive boundary
        // as delete and must not leave its run/attention beside another Bot.
        let discarded = try createLiveBot(prefix: "discard-a", name: "Discard A")
        let survivor = try createLiveBot(prefix: "discard-b", name: "Keep B")

        _ = try authority.dispatch(method: "bot.discard_new", params: [
            "client_request_id": "discard-a", "bot_id": discarded.botID,
        ], now: Date(timeIntervalSince1970: 1_700_000_700))

        let remaining = try authority.dispatch(method: "bot.attention.list", params: [:])
        XCTAssertEqual(Set((remaining["items"] as? [[String: Any]] ?? []).compactMap { $0["bot_id"] as? String }), [survivor.botID])
        XCTAssertFalse(authority.settleRuntime(botID: discarded.botID, runID: discarded.runID, failed: false))
        XCTAssertTrue(authority.settleRuntime(botID: survivor.botID, runID: survivor.runID, failed: false))
        let selections = try sidecarObject("bot.remote.selected_conversations")
        XCTAssertNil(selections[discarded.botID])
        XCTAssertEqual(selections[survivor.botID] as? String, survivor.conversationID)
    }

    func test_discardNewUsesTheSameExactGrantAndGuestCleanupBoundary() throws {
        // WHY: cancelling an unpublished Bot must not leave a weaker cleanup
        // boundary than confirmed delete.
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "discard-cleanup-create", "name": "Discard A",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let botUUID = try XCTUnwrap(UUID(uuidString: botID))
        let bot = try XCTUnwrap(store.get(id: BotID(botUUID)))
        let home = BotHome(appSupportDirectory: supportDir, bot: bot)
        try home.ensure(name: bot.name, handle: bot.handle, title: bot.title, description: "discard", soul: "discard")
        _ = try fileRootGrant(botID: botID)
        _ = try guestState(botID: botID)
        authority.onDockerClear = { _ in }

        let discarded = try authority.dispatch(method: "bot.discard_new", params: [
            "client_request_id": "discard-cleanup", "bot_id": botID,
        ])
        let replay = try authority.dispatch(method: "bot.discard_new", params: [
            "client_request_id": "discard-cleanup", "bot_id": botID,
        ])
        XCTAssertEqual(discarded["status"] as? String, "completed")
        XCTAssertEqual(replay["receipt_id"] as? String, discarded["receipt_id"] as? String)
        XCTAssertEqual((discarded["readback"] as? [String: Any])?["cleanup_complete"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.root.path))
        XCTAssertFalse(try sidecarObject("bot.remote.file_grants").values.contains {
            ($0 as? [String: Any])?["bot_id"] as? String == botID
        })
        XCTAssertNil(try sidecarObject("bot.remote.guest_state")[botID])
    }

    func test_discardNewClearsOnlyExactRoutingAcrossRelaunch() throws {
        // WHY: canceling unpublished Bot A shares the delete boundary and must
        // preserve unpublished Bot B's separate routing authority.
        let a = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "route-discard-a-create", "name": "Discard A",
        ])
        let b = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "route-discard-b-create", "name": "Keep B",
        ])
        let aID = try XCTUnwrap(a["bot_id"] as? String)
        let bID = try XCTUnwrap(b["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "route-discard-a", "bot_id": aID, "provider_instance_id": "grok-a",
        ])
        let routeB = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "route-discard-b", "bot_id": bID, "provider_instance_id": "grok-b",
        ])
        let bReceipt = try XCTUnwrap(routeB["receipt_id"] as? String)

        _ = try authority.dispatch(method: "bot.discard_new", params: [
            "client_request_id": "route-discard-a-confirm", "bot_id": aID,
        ])

        let persisted = try sidecarObject("bot.remote.routing")
        XCTAssertNil(persisted[aID])
        XCTAssertEqual((persisted[bID] as? [String: Any])?["routing_receipt_id"] as? String, bReceipt)
        let relaunched = BotRemoteControlAuthority(
            db: db, store: store, settings: settings, appSupportDirectory: supportDir
        )
        let surviving = try relaunched.dispatch(method: "bot.get", params: ["bot_id": bID])
        XCTAssertEqual(
            ((surviving["routing"] as? [String: Any])?["routing_receipt_id"] as? String), bReceipt
        )
    }

    func test_relaunchPrunesLegacyRoutingForDeletedBotWithoutTouchingLiveBot() throws {
        // WHY: installs upgrading from the defective build already contain
        // tombstones, so relaunch must heal them without rewriting live routes.
        let a = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "legacy-route-a-create", "name": "Deleted A",
        ])
        let b = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "legacy-route-b-create", "name": "Keep B",
        ])
        let aID = try XCTUnwrap(a["bot_id"] as? String)
        let bID = try XCTUnwrap(b["bot_id"] as? String)
        let aBot = try XCTUnwrap(store.get(id: BotID(try XCTUnwrap(UUID(uuidString: aID)))))
        let bBot = try XCTUnwrap(store.get(id: BotID(try XCTUnwrap(UUID(uuidString: bID)))))
        let aHome = BotHome(appSupportDirectory: supportDir, bot: aBot)
        let bHome = BotHome(appSupportDirectory: supportDir, bot: bBot)
        try aHome.ensure(name: aBot.name, handle: aBot.handle, title: aBot.title, description: "A", soul: "A")
        try bHome.ensure(name: bBot.name, handle: bBot.handle, title: bBot.title, description: "B", soul: "B")
        _ = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "legacy-route-a", "bot_id": aID, "provider_instance_id": "grok-a",
        ])
        let routeB = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "legacy-route-b", "bot_id": bID, "provider_instance_id": "grok-b",
        ])
        let bReceipt = try XCTUnwrap(routeB["receipt_id"] as? String)
        try store.delete(id: BotID(try XCTUnwrap(UUID(uuidString: aID))))

        _ = BotRemoteControlAuthority(
            db: db, store: store, settings: settings, appSupportDirectory: supportDir
        )

        let persisted = try sidecarObject("bot.remote.routing")
        XCTAssertNil(persisted[aID])
        XCTAssertEqual((persisted[bID] as? [String: Any])?["routing_receipt_id"] as? String, bReceipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aHome.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bHome.root.path))
    }

    func test_relaunchFiltersLegacyAttentionForDeletedBots() throws {
        // WHY: older sidecars may retain attention written before Bot deletion;
        // relaunch must heal that stale projection without touching live Bots.
        let deleted = try createLiveBot(prefix: "legacy-a", name: "Legacy A")
        let survivor = try createLiveBot(prefix: "legacy-b", name: "Keep B")
        try store.delete(id: BotID(try XCTUnwrap(UUID(uuidString: deleted.botID))))

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )

        let restored = try relaunched.dispatch(method: "bot.attention.list", params: [:])
        XCTAssertEqual(Set((restored["items"] as? [[String: Any]] ?? []).compactMap { $0["bot_id"] as? String }), [survivor.botID])
    }

    func test_newSaveAndExistingSave_areDistinctPres() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "new",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let first = try authority.dispatch(method: "bot.save", params: [
            "client_request_id": "save-new",
            "bot_id": botID,
            "name": "Piper",
        ])
        XCTAssertEqual((first["readback"] as? [String: Any])?["pre"] as? String, "UNPUBLISHED_NEW")
        let second = try authority.dispatch(method: "bot.save", params: [
            "client_request_id": "save-old",
            "bot_id": botID,
            "name": "Piper",
        ])
        XCTAssertEqual((second["readback"] as? [String: Any])?["pre"] as? String, "EXISTING")
    }

    func test_queuedFollowUp_isVisibleInBotStoreAfterEnqueue() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "store-q",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "store-q-1",
            "bot_id": botID,
            "text": "first turn",
        ])
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "store-q-2",
            "bot_id": botID,
            "text": "follow up",
        ])
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let stored = try store.listQueuedFollowUps(botID: BotID(uuid))
        XCTAssertEqual(stored.map(\.text), ["follow up"])
        XCTAssertFalse(stored.isEmpty, "queue must land in BotStore, not a sidecar map")
    }

    func test_filesMutate_writesBotHomeDiskAndSurvivesRelaunchList() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "disk",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let grant = try fileRootGrant(botID: botID)
        let wrote = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "disk-w",
            "bot_id": botID,
            "root_handle": grant.handle,
            "expected_generation": grant.generation,
            "expected_cas": grant.cas,
            "relative_path": "notes.txt",
            "op": "write",
            "contents": "from remote",
        ])
        let postCAS = try XCTUnwrap((wrote["readback"] as? [String: Any])?["root_cas"] as? String)
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let bot = try XCTUnwrap(store.get(id: BotID(uuid)))
        let home = BotHome(appSupportDirectory: supportDir, bot: bot)
        let url = try home.resolvedURL("notes.txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "from remote")

        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        let listed = try relaunched.dispatch(method: "bot.files.list", params: ["bot_id": botID])
        XCTAssertEqual(listed["root_cas"] as? String, postCAS, "CAS authority must survive host relaunch")
        let entries = try XCTUnwrap(listed["entries"] as? [[String: Any]])
        XCTAssertTrue(
            entries.contains { ($0["path"] as? String) == "notes.txt" },
            "files.list must read the Bot Home disk after relaunch, got \(entries.map { $0["path"] as? String })"
        )
        XCTAssertEqual(entries.first { ($0["path"] as? String) == "notes.txt" }?["cas"] as? String, postCAS)
    }

    /// WHY: SOUL.md and DESCRIPTION.md are authored Bot profile fields, not
    /// independent files. Their opaque CAS mutation must publish the same exact
    /// revision while leaving ordinary files and every other Bot untouched.
    func test_filesMutateProfileFilesPublishExactRevisionAndSurviveRelaunchWithoutCrossBotEffects() throws {
        let first = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "profile-files-a", "name": "Alpha",
            "description": "Original description", "soul": "Original soul",
        ])
        let second = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "profile-files-b", "name": "Beta",
            "description": "Beta description", "soul": "Beta soul",
        ])
        let firstID = try XCTUnwrap(first["bot_id"] as? String)
        let secondID = try XCTUnwrap(second["bot_id"] as? String)
        let firstBotID = BotID(try XCTUnwrap(UUID(uuidString: firstID)))
        let secondBotID = BotID(try XCTUnwrap(UUID(uuidString: secondID)))
        let firstOriginalRevision = try XCTUnwrap(try store.get(id: firstBotID)?.currentRevisionID)
        let secondOriginalRevision = try XCTUnwrap(try store.get(id: secondBotID)?.currentRevisionID)

        var grant = try fileRootGrant(botID: firstID, hostID: "profile-host")
        _ = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "profile-files-ordinary",
            "host_id": "profile-host", "bot_id": firstID,
            "root_handle": grant.handle, "expected_generation": grant.generation,
            "expected_cas": grant.cas, "relative_path": "notes.txt",
            "op": "write", "contents": "keep me",
        ])
        XCTAssertEqual(try store.get(id: firstBotID)?.currentRevisionID, firstOriginalRevision)

        grant = try fileRootGrant(botID: firstID, hostID: "profile-host")
        let soulMutation = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "profile-files-soul",
            "host_id": "profile-host", "bot_id": firstID,
            "root_handle": grant.handle, "expected_generation": grant.generation,
            "expected_cas": grant.cas, "relative_path": BotHome.soulName,
            "op": "write", "contents": "Own the support inbox.",
        ])
        let soulReadback = try XCTUnwrap(soulMutation["readback"] as? [String: Any])
        XCTAssertEqual(soulReadback["soul"] as? String, "Own the support inbox.")
        XCTAssertEqual(soulReadback["description"] as? String, "Original description")
        XCTAssertEqual(soulReadback["revision"] as? Int, 2)
        XCTAssertNotEqual(soulReadback["current_revision_id"] as? String, firstOriginalRevision.value.uuidString.lowercased())

        grant = try fileRootGrant(botID: firstID, hostID: "profile-host")
        let descriptionMutation = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "profile-files-description",
            "host_id": "profile-host", "bot_id": firstID,
            "root_handle": grant.handle, "expected_generation": grant.generation,
            "expected_cas": grant.cas, "relative_path": BotHome.descriptionName,
            "op": "write", "contents": "  Updated profile  ",
        ])
        let descriptionReadback = try XCTUnwrap(descriptionMutation["readback"] as? [String: Any])
        XCTAssertEqual(descriptionReadback["soul"] as? String, "Own the support inbox.")
        XCTAssertEqual(descriptionReadback["description"] as? String, "Updated profile")
        XCTAssertEqual(descriptionReadback["revision"] as? Int, 3)

        grant = try fileRootGrant(botID: firstID, hostID: "profile-host")
        let removedSoul = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "profile-files-soul-remove",
            "host_id": "profile-host", "bot_id": firstID,
            "root_handle": grant.handle, "expected_generation": grant.generation,
            "expected_cas": grant.cas, "relative_path": BotHome.soulName,
            "op": "delete",
        ])
        let removedReadback = try XCTUnwrap(removedSoul["readback"] as? [String: Any])
        XCTAssertEqual(removedReadback["soul"] as? String, "")
        XCTAssertEqual(removedReadback["description"] as? String, "Updated profile")
        XCTAssertEqual(removedReadback["revision"] as? Int, 4)

        authority = BotRemoteControlAuthority(
            db: db, store: BotStore(db: db), settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )
        let relaunched = try authority.dispatch(method: "bot.get", params: ["bot_id": firstID])
        XCTAssertEqual(relaunched["soul"] as? String, "")
        XCTAssertEqual(relaunched["description"] as? String, "Updated profile")
        XCTAssertEqual(relaunched["current_revision_id"] as? String, removedReadback["current_revision_id"] as? String)
        let firstBot = try XCTUnwrap(try store.get(id: firstBotID))
        XCTAssertEqual(
            try String(contentsOf: BotHome(appSupportDirectory: supportDir, bot: firstBot).root
                .appendingPathComponent("notes.txt"), encoding: .utf8),
            "keep me"
        )
        let secondBot = try XCTUnwrap(try store.get(id: secondBotID))
        let secondRevision = try XCTUnwrap(try store.getRevision(id: secondOriginalRevision))
        XCTAssertEqual(secondBot.currentRevisionID, secondOriginalRevision)
        XCTAssertEqual(secondBot.description, "Beta description")
        XCTAssertEqual(secondRevision.soul, "Beta soul")
    }

    /// WHY: disk authority must succeed before a profile revision can commit;
    /// otherwise an error receipt/event could hide a revision that did publish.
    func test_filesMutateProfileWriteAndRemoveFailuresPublishNoRevisionOrCompletedReceipt() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "profile-failure-create", "name": "Failure",
            "description": "Original description", "soul": "Original soul",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let typedID = BotID(try XCTUnwrap(UUID(uuidString: botID)))
        let bot = try XCTUnwrap(try store.get(id: typedID))
        let originalRevision = try XCTUnwrap(bot.currentRevisionID)
        let home = BotHome(appSupportDirectory: supportDir, bot: bot)
        try home.ensure(
            name: bot.name, handle: bot.handle, title: bot.title,
            description: bot.description, soul: "Original soul"
        )
        try FileManager.default.removeItem(at: home.soulURL)
        try FileManager.default.createDirectory(at: home.soulURL, withIntermediateDirectories: false)
        let grant = try fileRootGrant(botID: botID, hostID: "failure-host")

        XCTAssertThrowsError(try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "profile-write-failure",
            "host_id": "failure-host", "bot_id": botID,
            "root_handle": grant.handle, "expected_generation": grant.generation,
            "expected_cas": grant.cas, "relative_path": BotHome.soulName,
            "op": "write", "contents": "must not publish",
        ]))
        XCTAssertEqual(try store.get(id: typedID)?.currentRevisionID, originalRevision)
        XCTAssertNotEqual(
            try authority.dispatch(method: "bot.receipt.status", params: [
                "client_request_id": "profile-write-failure",
            ])["status"] as? String,
            "completed"
        )

        try FileManager.default.removeItem(at: home.soulURL)
        let outside = supportDir.appendingPathComponent("outside-profile.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: home.soulURL, withDestinationURL: outside)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "profile-remove-failure",
            "host_id": "failure-host", "bot_id": botID,
            "root_handle": grant.handle, "expected_generation": grant.generation,
            "expected_cas": grant.cas, "relative_path": BotHome.soulName,
            "op": "delete",
        ]))
        XCTAssertEqual(try store.get(id: typedID)?.currentRevisionID, originalRevision)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        XCTAssertNotEqual(
            try authority.dispatch(method: "bot.receipt.status", params: [
                "client_request_id": "profile-remove-failure",
            ])["status"] as? String,
            "completed"
        )
    }

    /// WHY: a SQLite failure after the atomic file replacement must restore the
    /// prior bytes as well as roll back the revision, never exposing split truth.
    func test_filesMutateProfileCommitFailureCompensatesDiskAndPublishesNoCompletedReceipt() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "profile-commit-create", "name": "Commit Failure",
            "description": "Original description", "soul": "Original soul",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let typedID = BotID(try XCTUnwrap(UUID(uuidString: botID)))
        let bot = try XCTUnwrap(try store.get(id: typedID))
        let originalRevision = try XCTUnwrap(bot.currentRevisionID)
        let home = BotHome(appSupportDirectory: supportDir, bot: bot)
        try home.ensure(
            name: bot.name, handle: bot.handle, title: bot.title,
            description: bot.description, soul: "Original soul"
        )
        let grant = try fileRootGrant(botID: botID, hostID: "commit-failure-host")
        struct InjectedCommitFailure: Error {}
        store.onBeforePublishCommitForTesting = { throw InjectedCommitFailure() }

        XCTAssertThrowsError(try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "profile-commit-failure",
            "host_id": "commit-failure-host", "bot_id": botID,
            "root_handle": grant.handle, "expected_generation": grant.generation,
            "expected_cas": grant.cas, "relative_path": BotHome.soulName,
            "op": "write", "contents": "must be compensated",
        ]))
        store.onBeforePublishCommitForTesting = nil

        XCTAssertEqual(try store.get(id: typedID)?.currentRevisionID, originalRevision)
        XCTAssertEqual(try String(contentsOf: home.soulURL, encoding: .utf8), "Original soul")
        XCTAssertNotEqual(
            try authority.dispatch(method: "bot.receipt.status", params: [
                "client_request_id": "profile-commit-failure",
            ])["status"] as? String,
            "completed"
        )
    }

    func test_browserAction_persistsBotBrowserStoreTarget() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "br-store",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        var params = try webLinkParams(botID: botID, requestID: "br-open", url: "http://127.0.0.1:3000")
        params["title"] = "Dev"
        _ = try authority.dispatch(method: "bot.link.open", params: params)
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let persisted = try XCTUnwrap(
            BotBrowserStore(appSupportDirectory: supportDir).loadTarget(botID: BotID(uuid))
        )
        XCTAssertEqual(persisted.url, "http://127.0.0.1:3000")
        XCTAssertEqual(persisted.title, "Dev")
        let pending = try BotBrowserStore(appSupportDirectory: supportDir).loadPendingOpens()
        XCTAssertEqual(pending.last?.url, "http://127.0.0.1:3000")
    }

    func test_browserAction_postsPendingOpenNotification() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "br-note",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        var posted: [Notification.Name] = []
        authority.notifyBrowserPendingOpen = { posted.append($0) }
        _ = try authority.dispatch(
            method: "bot.link.open",
            params: webLinkParams(botID: botID, requestID: "br-note-open", url: "http://127.0.0.1:4000")
        )
        XCTAssertEqual(posted, [BotBrowserHost.pendingOpenNotification])
        let state = try authority.dispatch(method: "bot.browser.state", params: ["bot_id": botID])
        XCTAssertEqual(state["url"] as? String, "http://127.0.0.1:4000")
        XCTAssertEqual(state["host_first"] as? Bool, true)
    }

    func test_dockerClear_wipesGuestHomeOnDisk() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "dock",
            "name": "Piper",
        ])
        let peer = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "dock-peer",
            "name": "Scout",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let peerID = try XCTUnwrap(peer["bot_id"] as? String)
        let initialGrant = try fileRootGrant(botID: botID)
        _ = try authority.dispatch(method: "bot.files.location.set", params: [
            "client_request_id": "dock-loc",
            "bot_id": botID,
            "root": "docker_home",
            "previous_root_handle": initialGrant.handle,
            "expected_generation": initialGrant.generation,
            "expected_cas": initialGrant.cas,
        ])
        let grant = try fileRootGrant(botID: botID)
        _ = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "dock-w",
            "bot_id": botID,
            "root_handle": grant.handle,
            "expected_generation": grant.generation,
            "expected_cas": grant.cas,
            "relative_path": "scratch.txt",
            "op": "write",
            "contents": "guest bytes",
        ])
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let guest = BotGuestHome.url(appSupport: supportDir, botID: BotID(uuid))
        let peerUUID = try XCTUnwrap(UUID(uuidString: peerID))
        let peerGuest = try BotGuestHome.ensure(appSupport: supportDir, botID: BotID(peerUUID))
        try Data("peer bytes".utf8).write(to: peerGuest.appendingPathComponent("keep.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guest.appendingPathComponent("scratch.txt").path))
        var clearedBots: [BotID] = []
        authority.onDockerClear = { clearedBots.append($0) }
        let params: [String: Any] = [
            "client_request_id": "dock-c",
            "bot_id": botID,
            "confirm": "clear",
        ]
        let cleared = try authority.dispatch(method: "bot.docker.clear", params: params)
        let replay = try authority.dispatch(method: "bot.docker.clear", params: params)
        let readback = try XCTUnwrap(cleared["readback"] as? [String: Any])
        XCTAssertEqual(cleared["status"] as? String, "completed")
        XCTAssertEqual(cleared as NSDictionary, replay as NSDictionary)
        XCTAssertEqual(readback["partial"] as? Bool, false)
        XCTAssertGreaterThanOrEqual(readback["removed_count"] as? Int ?? 0, 1)
        XCTAssertEqual(clearedBots, [BotID(uuid)], "response loss must not clear the exact Bot twice")
        XCTAssertFalse(FileManager.default.fileExists(atPath: guest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: peerGuest.appendingPathComponent("keep.txt").path))
    }

    func test_guestStart_createsGuestHomeAndKeepsVncViewer() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "g-home",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let started = try authority.dispatch(
            method: "bot.guest.start",
            params: guestStartParams(botID: botID, requestID: "g-start")
        )
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: BotGuestHome.url(appSupport: supportDir, botID: BotID(uuid)).path
            )
        )
        XCTAssertEqual((started["readback"] as? [String: Any])?["viewer"] as? String, "/vnc.html")
        XCTAssertEqual(started["status"] as? String, "accepted")
        XCTAssertEqual((started["readback"] as? [String: Any])?["status"] as? String, "starting")
    }

    func test_guestCatalogIsHostIssuedAndStartReturnsSecretFreeExactRuntime() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "guest-catalog",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let state = try guestState(botID: botID)
        let catalog = try XCTUnwrap(state["task_catalog"] as? [String: Any])
        let tasks = try XCTUnwrap(catalog["tasks"] as? [[String: Any]])
        XCTAssertEqual(Set(tasks.compactMap { $0["id"] as? String }).count, tasks.count)
        XCTAssertTrue(Set([
            "pointer", "key", "text", "drag", "start", "tryAgain",
            "rebuild", "stop", "fullscreen", "error",
        ]).isSubset(of: Set(tasks.compactMap { $0["axis"] as? String })))

        var bad = try guestStartParams(botID: botID, requestID: "guest-bad-recipe")
        bad["recipe_id"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try authority.dispatch(method: "bot.guest.start", params: bad))

        let started = try authority.dispatch(
            method: "bot.guest.start",
            params: guestStartParams(botID: botID, requestID: "guest-exact-start")
        )
        let readback = try XCTUnwrap(started["readback"] as? [String: Any])
        let runtime = try XCTUnwrap(readback["runtime"] as? [String: Any])
        XCTAssertEqual(runtime["host_id"] as? String, guestHostID)
        XCTAssertEqual(runtime["bot_id"] as? String, botID)
        XCTAssertEqual(runtime["viewer_path"] as? String, "/vnc.html")
        XCTAssertNotNil(runtime["container_id"] as? String)
        XCTAssertNotNil(runtime["app_run_id"] as? String)
        XCTAssertNotNil(runtime["viewer_id"] as? String)
        XCTAssertNotNil(runtime["session_id"] as? String)
        XCTAssertNotNil(runtime["grant_id"] as? String)
        XCTAssertEqual(runtime["grant_generation"] as? Int, 1)
        let json = try JSONSerialization.data(withJSONObject: readback)
        let wire = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(wire.contains("127.0.0.1"))
        XCTAssertFalse(wire.contains("screen_url"))
        XCTAssertFalse(wire.contains("bearer_token"))
    }

    func test_guestDragRequiresExactRuntimeAndFrameAndIsMarkedAtomic() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "guest-drag",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let state = try runningGuest(botID: botID)
        let runtime = try XCTUnwrap(state["runtime"] as? [String: Any])
        let frame = try XCTUnwrap(state["frame"] as? [String: Any])
        let task = try guestTask(botID: botID, axis: "drag")
        var hookedContext: [String: Any] = [:]
        authority.onGuestInput = { _, _, _, context in hookedContext = context }
        let base: [String: Any] = [
            "bot_id": botID,
            "host_id": guestHostID,
            "task_id": try XCTUnwrap(task["id"] as? String),
            "runtime": runtime,
            "before_frame_id": try XCTUnwrap(frame["frame_id"] as? String),
            "input": [
                "kind": "drag",
                "from_x": 10,
                "from_y": 20,
                "to_x": 30,
                "to_y": 40,
            ],
        ]
        let accepted = try authority.dispatch(
            method: "bot.guest.input",
            params: base.merging(["client_request_id": "guest-drag-ok"]) { _, new in new }
        )
        XCTAssertEqual(accepted["status"] as? String, "accepted")
        XCTAssertEqual((hookedContext["input"] as? [String: Any])?["atomic"] as? Bool, true)

        var stale = base
        stale["client_request_id"] = "guest-drag-stale"
        stale["before_frame_id"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try authority.dispatch(method: "bot.guest.input", params: stale))

        var crossRuntime = runtime
        crossRuntime["grant_id"] = UUID().uuidString.lowercased()
        var crossed = base
        crossed["client_request_id"] = "guest-drag-cross"
        crossed["runtime"] = crossRuntime
        XCTAssertThrowsError(try authority.dispatch(method: "bot.guest.input", params: crossed))

        var substitutedImage = runtime
        substitutedImage["image_reference"] = "untrusted/image:latest"
        var substituted = base
        substituted["client_request_id"] = "guest-drag-image-substitution"
        substituted["runtime"] = substitutedImage
        XCTAssertThrowsError(try authority.dispatch(method: "bot.guest.input", params: substituted))
    }

    func test_guestPointerKeyAndTextUseHostTasksAndCurrentFrame() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "guest-input-axes",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let state = try runningGuest(botID: botID)
        let runtime = try XCTUnwrap(state["runtime"] as? [String: Any])
        let frame = try XCTUnwrap(state["frame"] as? [String: Any])
        let beforeFrameID = try XCTUnwrap(frame["frame_id"] as? String)
        authority.onGuestInput = { _, _, _, _ in }
        let inputs: [(axis: String, input: [String: Any])] = [
            ("pointer", ["kind": "pointer", "x": 10, "y": 20]),
            ("key", ["kind": "key", "key": "Return"]),
            ("text", ["kind": "text", "text": "hello"]),
        ]

        for (index, item) in inputs.enumerated() {
            let task = try guestTask(botID: botID, axis: item.axis)
            let accepted = try authority.dispatch(method: "bot.guest.input", params: [
                "client_request_id": "guest-input-axis-\(index)",
                "bot_id": botID,
                "host_id": guestHostID,
                "task_id": try XCTUnwrap(task["id"] as? String),
                "runtime": runtime,
                "before_frame_id": beforeFrameID,
                "input": item.input,
            ])
            XCTAssertEqual(accepted["status"] as? String, "accepted")
        }
    }

    func test_guestPointerAndDragAcceptIntegralJSONNumbersAndRejectInvalidCoordinates() throws {
        // WHY: paired JSON numbers are decoded as Double on the macOS host;
        // valid integral coordinates must pass the authority boundary with
        // their exact values and retain the existing task/frame fences.
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "guest-json-number-input",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let state = try runningGuest(botID: botID)
        let runtime = try XCTUnwrap(state["runtime"] as? [String: Any])
        let frame = try XCTUnwrap(state["frame"] as? [String: Any])
        let beforeFrameID = try XCTUnwrap(frame["frame_id"] as? String)
        var received: [[String: Any]] = []
        authority.onGuestInput = { _, params, _, _ in
            if let input = params["input"] as? [String: Any] {
                received.append(input)
            }
        }

        func dispatchInput(
            requestID: String,
            axis: String,
            input: [String: Any]
        ) throws -> [String: Any] {
            let task = try guestTask(botID: botID, axis: axis)
            return try authority.dispatch(method: "bot.guest.input", params: [
                "client_request_id": requestID,
                "bot_id": botID,
                "host_id": guestHostID,
                "task_id": try XCTUnwrap(task["id"] as? String),
                "runtime": runtime,
                "before_frame_id": beforeFrameID,
                "input": input,
            ])
        }

        for (index, axis) in ["pointer", "drag"].enumerated() {
            let input: [String: Any] = axis == "pointer"
                ? ["kind": "pointer", "x": 320.0, "y": 480.0]
                : [
                    "kind": "drag",
                    "from_x": 40.0,
                    "from_y": 80.0,
                    "to_x": 640.0,
                    "to_y": 720.0,
                ]
            let accepted = try dispatchInput(
                requestID: "guest-json-number-\(index)",
                axis: axis,
                input: input
            )
            XCTAssertEqual(accepted["status"] as? String, "accepted")
        }

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0]["x"] as? Double, 320.0)
        XCTAssertEqual(received[0]["y"] as? Double, 480.0)
        XCTAssertEqual(received[1]["from_x"] as? Double, 40.0)
        XCTAssertEqual(received[1]["to_y"] as? Double, 720.0)

        let invalidInputs: [(requestID: String, axis: String, input: [String: Any])] = [
            ("guest-json-number-invalid-fractional", "pointer", ["kind": "pointer", "x": 320.5, "y": 480.0]),
            ("guest-json-number-invalid-negative", "pointer", ["kind": "pointer", "x": -1.0, "y": 480.0]),
            ("guest-json-number-invalid-malformed", "pointer", ["kind": "pointer", "x": 320.0]),
            ("guest-json-number-invalid-bounds", "drag", [
                "kind": "drag",
                "from_x": 40.0,
                "from_y": 80.0,
                "to_x": 1_600.0,
                "to_y": 720.0,
            ]),
        ]
        for item in invalidInputs {
            XCTAssertThrowsError(
                try dispatchInput(requestID: item.requestID, axis: item.axis, input: item.input),
                "invalid coordinate payload must be rejected"
            )
        }

        let failed = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": invalidInputs[0].requestID,
        ])
        XCTAssertEqual(failed["status"] as? String, "failed")
        XCTAssertEqual((failed["readback"] as? [String: Any])?["error"] as? String, "Invalid params")

        let afterInvalid = try guestState(botID: botID)
        XCTAssertEqual(afterInvalid["status"] as? String, "running")
        XCTAssertEqual(
            (afterInvalid["runtime"] as? [String: Any])?["grant_id"] as? String,
            runtime["grant_id"] as? String
        )
        XCTAssertEqual(
            (afterInvalid["frame"] as? [String: Any])?["frame_id"] as? String,
            beforeFrameID
        )
    }

    func test_guestRebuildRotatesRuntimeAndStopInvalidatesReplacementGrant() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "guest-lifecycle",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let running = try runningGuest(botID: botID)
        let originalRuntime = try XCTUnwrap(running["runtime"] as? [String: Any])
        let rebuildTask = try guestTask(botID: botID, axis: "rebuild")
        let rebuilt = try authority.dispatch(method: "bot.guest.rebuild", params: [
            "client_request_id": "guest-rebuild",
            "bot_id": botID,
            "host_id": guestHostID,
            "task_id": try XCTUnwrap(rebuildTask["id"] as? String),
            "runtime": originalRuntime,
        ])
        var rebuiltState = try XCTUnwrap(rebuilt["readback"] as? [String: Any])
        let replacementRuntime = try XCTUnwrap(rebuiltState["runtime"] as? [String: Any])
        XCTAssertNotEqual(replacementRuntime["app_run_id"] as? String, originalRuntime["app_run_id"] as? String)
        XCTAssertNotEqual(replacementRuntime["session_id"] as? String, originalRuntime["session_id"] as? String)
        XCTAssertNotEqual(replacementRuntime["grant_id"] as? String, originalRuntime["grant_id"] as? String)
        XCTAssertGreaterThan(
            try XCTUnwrap(replacementRuntime["grant_generation"] as? Int),
            try XCTUnwrap(originalRuntime["grant_generation"] as? Int)
        )
        rebuiltState["status"] = "running"
        rebuiltState["frame"] = [
            "runtime": replacementRuntime,
            "frame_id": "replacement-frame",
            "sequence": 0,
            "pixel_width": 1_600,
            "pixel_height": 1_200,
            "png_base64": "",
            "png_hash": "test",
        ]
        authority.settle(requestID: "guest-rebuild", status: .completed, readback: rebuiltState)

        let stopTask = try guestTask(botID: botID, axis: "stop")
        let stopped = try authority.dispatch(method: "bot.guest.stop", params: [
            "client_request_id": "guest-stop",
            "bot_id": botID,
            "host_id": guestHostID,
            "task_id": try XCTUnwrap(stopTask["id"] as? String),
            "runtime": replacementRuntime,
        ])
        let stoppedState = try XCTUnwrap(stopped["readback"] as? [String: Any])
        XCTAssertEqual(stoppedState["status"] as? String, "stopping")
        XCTAssertEqual(stoppedState["grant_invalidated"] as? Bool, true)
        XCTAssertNil(stoppedState["runtime"])
        XCTAssertNil(stoppedState["frame"])
    }

    func test_guestRevokeAndRelaunchInvalidateOldGrantAndRequireRecovery() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "guest-revoke",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let running = try runningGuest(botID: botID)
        let runtime = try XCTUnwrap(running["runtime"] as? [String: Any])
        let revoke = try guestTask(botID: botID, axis: "grantRevoke")
        let revoked = try authority.dispatch(method: "bot.guest.revoke", params: [
            "client_request_id": "guest-revoke-now",
            "bot_id": botID,
            "host_id": guestHostID,
            "task_id": try XCTUnwrap(revoke["id"] as? String),
            "runtime": runtime,
        ])
        let revokedState = try XCTUnwrap(revoked["readback"] as? [String: Any])
        XCTAssertEqual(revoked["status"] as? String, "completed")
        XCTAssertEqual(revokedState["status"] as? String, "revoked")
        XCTAssertEqual(revokedState["grant_invalidated"] as? Bool, true)
        XCTAssertNil(revokedState["runtime"])

        let beforeRelaunch = try runningGuest(botID: botID)
        let completedRequestID = try XCTUnwrap(beforeRelaunch["last_request_id"] as? String)
        let persistedGuestJSON = try db.performSync { database -> String? in
            let statement = try database.prepare(
                "SELECT value FROM settings WHERE key = 'bot.remote.guest_state' LIMIT 1;"
            )
            defer { statement.reset() }
            guard try statement.step() else { return nil }
            return statement.columnText(0)
        }
        XCTAssertFalse(try XCTUnwrap(persistedGuestJSON).contains("png_base64"))
        let relaunched = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
        authority = relaunched
        let recovered = try guestState(botID: botID)
        XCTAssertEqual(recovered["status"] as? String, "reconnect_required")
        XCTAssertEqual(recovered["grant_invalidated"] as? Bool, true)
        XCTAssertNil(recovered["runtime"])
        XCTAssertEqual(
            (recovered["recovery"] as? [String: Any])?["requires_new_start_grant"] as? Bool,
            true
        )
        let replayed = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": completedRequestID,
        ])
        XCTAssertEqual(replayed["status"] as? String, "completed")
        let replayedReadback = try XCTUnwrap(replayed["readback"] as? [String: Any])
        XCTAssertEqual(replayedReadback["status"] as? String, "reconnect_required")
        XCTAssertNil(replayedReadback["runtime"])
        XCTAssertNil(replayedReadback["frame"])
    }

    func test_filesOpenTabAndSplit_requireDiskAndCallLiveSurfaceHook() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "open-src",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let grant = try fileRootGrant(botID: botID)
        let wrote = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "open-w",
            "bot_id": botID,
            "root_handle": grant.handle,
            "expected_generation": grant.generation,
            "expected_cas": grant.cas,
            "relative_path": "notes.txt",
            "op": "write",
            "contents": "surface",
        ])
        let handle = try XCTUnwrap((wrote["readback"] as? [String: Any])?["handle"] as? String)
        let rootHandle = try XCTUnwrap((wrote["readback"] as? [String: Any])?["root_handle"] as? String)
        let generation = try XCTUnwrap((wrote["readback"] as? [String: Any])?["generation"] as? Int)
        let cas = try XCTUnwrap((wrote["readback"] as? [String: Any])?["root_cas"] as? String)
        var opened: [(String, Bool, String)] = []
        authority.onOpenFile = { _, path, split, root in
            opened.append((path, split, root))
        }
        let tab = try authority.dispatch(method: "bot.files.open_tab", params: [
            "client_request_id": "open-tab",
            "bot_id": botID,
            "root_handle": rootHandle,
            "handle": handle,
            "expected_generation": generation,
            "expected_cas": cas,
        ])
        XCTAssertEqual((tab["readback"] as? [String: Any])?["mounted"] as? Bool, true)
        XCTAssertEqual((tab["readback"] as? [String: Any])?["split"] as? Bool, false)
        let split = try authority.dispatch(method: "bot.files.split", params: [
            "client_request_id": "open-split",
            "bot_id": botID,
            "root_handle": rootHandle,
            "handle": handle,
            "expected_generation": generation,
            "expected_cas": cas,
        ])
        XCTAssertEqual((split["readback"] as? [String: Any])?["split"] as? Bool, true)
        XCTAssertEqual(opened.map(\.0), ["notes.txt", "notes.txt"])
        XCTAssertEqual(opened.map(\.1), [false, true])
        XCTAssertThrowsError(
            try authority.dispatch(method: "bot.files.open_tab", params: [
                "client_request_id": "open-missing",
                "bot_id": botID,
                "handle": UUID().uuidString.lowercased(),
            ])
        )
    }

    func test_dockerClear_isPartialWhenRuntimeTeardownFails() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "dock-p",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        authority.onDockerClear = { _ in
            throw BotRemoteControlAuthority.Error(code: -32088, message: "Docker home clear failed.")
        }
        let cleared = try authority.dispatch(method: "bot.docker.clear", params: [
            "client_request_id": "dock-p-c",
            "bot_id": botID,
            "confirm": "clear",
        ])
        XCTAssertEqual(cleared["status"] as? String, "partial")
        XCTAssertEqual((cleared["readback"] as? [String: Any])?["partial"] as? Bool, true)
        XCTAssertEqual((cleared["readback"] as? [String: Any])?["cleared"] as? Bool, true)
    }

    func test_forceStop_keepsQueueWhenLiveStopHookOwnsDrain() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "live-stop",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "live-stop-1",
            "bot_id": botID,
            "text": "go",
        ])
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "live-stop-2",
            "bot_id": botID,
            "text": "queued",
        ])
        var stopped = false
        authority.onStopRun = { _, _, _, _, force, _ in
            stopped = force
        }
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        let result = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "live-stop-go",
            "bot_id": botID,
        ])
        XCTAssertTrue(stopped)
        XCTAssertEqual(result["status"] as? String, "accepted")
        XCTAssertNil((result["readback"] as? [String: Any])?["drained"] as? [String: Any])
        XCTAssertEqual(try store.listQueuedFollowUps(botID: BotID(uuid)).map(\.text), ["queued"])
    }

    func test_scopedStopCannotTerminateANewerRunAfterNetworkDelay() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "scoped-stop-bot",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "scoped-stop-conversation",
            "bot_id": botID,
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let first = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "scoped-stop-run-1",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "first",
        ])
        let firstRunID = try XCTUnwrap(
            (first["readback"] as? [String: Any])?["run_id"] as? String
        )
        _ = try authority.dispatch(method: "bot.stop", params: [
            "client_request_id": "scoped-stop-first",
            "bot_id": botID,
        ])
        let second = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "scoped-stop-run-2",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "second",
        ])
        let secondRunID = try XCTUnwrap(
            (second["readback"] as? [String: Any])?["run_id"] as? String
        )

        XCTAssertThrowsError(try authority.dispatch(method: "bot.stop", params: [
            "client_request_id": "scoped-stop-delayed",
            "bot_id": botID,
            "conversation_id": conversationID,
            "run_id": firstRunID,
            "run_request_id": "scoped-stop-run-1",
        ]))

        let stopped = try authority.dispatch(method: "bot.stop", params: [
            "client_request_id": "scoped-stop-current",
            "bot_id": botID,
            "conversation_id": conversationID,
            "run_id": secondRunID,
            "run_request_id": "scoped-stop-run-2",
        ])
        let readback = try XCTUnwrap(stopped["readback"] as? [String: Any])
        XCTAssertEqual((readback["run"] as? [String: Any])?["run_id"] as? String, secondRunID)
        XCTAssertEqual(readback["terminal"] as? Bool, true)
    }

    func test_forceStop_drainsStoreQueue() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "drain",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "drain-1",
            "bot_id": botID,
            "text": "go",
        ])
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "drain-2",
            "bot_id": botID,
            "text": "queued",
        ])
        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        XCTAssertEqual(try store.listQueuedFollowUps(botID: BotID(uuid)).count, 1)
        let stopped = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "drain-stop",
            "bot_id": botID,
        ])
        let readback = stopped["readback"] as? [String: Any]
        XCTAssertEqual(readback?["terminal"] as? Bool, true)
        XCTAssertEqual((readback?["drained"] as? [String: Any])?["text"] as? String, "queued")
        XCTAssertEqual(try store.listQueuedFollowUps(botID: BotID(uuid)).count, 0)
    }

    func test_guestInput_requiresLiveHookAndCompletesWhenHookReturns() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "gin",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let state = try runningGuest(botID: botID)
        let task = try guestTask(botID: botID, axis: "text")
        let runtime = try XCTUnwrap(state["runtime"] as? [String: Any])
        let frame = try XCTUnwrap(state["frame"] as? [String: Any])
        let inputParams: [String: Any] = [
            "bot_id": botID,
            "host_id": guestHostID,
            "task_id": try XCTUnwrap(task["id"] as? String),
            "runtime": runtime,
            "before_frame_id": try XCTUnwrap(frame["frame_id"] as? String),
            "input": ["kind": "text", "text": "hello"],
        ]
        XCTAssertThrowsError(
            try authority.dispatch(
                method: "bot.guest.input",
                params: inputParams.merging(["client_request_id": "gin-miss"]) { _, new in new }
            )
        )
        var received = ""
        var hookedRequest = ""
        authority.onGuestInput = { _, params, requestID, _ in
            received = (params["input"] as? [String: Any])?["text"] as? String ?? ""
            hookedRequest = requestID
        }
        let sent = try authority.dispatch(
            method: "bot.guest.input",
            params: inputParams.merging(["client_request_id": "gin-ok"]) { _, new in new }
        )
        XCTAssertEqual(received, "hello")
        XCTAssertEqual(hookedRequest, "gin-ok")
        XCTAssertEqual(sent["status"] as? String, "accepted")
        XCTAssertEqual((sent["readback"] as? [String: Any])?["status"] as? String, "running")
        authority.settle(
            requestID: "gin-ok",
            status: .completed,
            readback: [
                "bot_id": botID,
                "status": "running",
                "viewer": "/vnc.html",
                "embed_html_is_not_runtime": true,
            ]
        )
        let status = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "gin-ok",
        ])
        XCTAssertEqual(status["status"] as? String, "completed")
    }

    func test_guestStart_acceptedThenSettleBecomesCompleted() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "g-set",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        var requestID = ""
        authority.onStartGuest = { _, _, id, _ in requestID = id }
        let started = try authority.dispatch(
            method: "bot.guest.start",
            params: guestStartParams(botID: botID, requestID: "g-set-1")
        )
        XCTAssertEqual(started["status"] as? String, "accepted")
        XCTAssertEqual(requestID, "g-set-1")
        authority.settle(
            requestID: requestID,
            status: .completed,
            readback: [
                "bot_id": botID,
                "status": "running",
                "viewer": "/vnc.html",
                "embed_html_is_not_runtime": true,
            ]
        )
        let status = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "g-set-1",
        ])
        XCTAssertEqual(status["status"] as? String, "completed")
        let guest = try guestState(botID: botID)
        XCTAssertEqual(guest["status"] as? String, "running")
    }

    func test_browserOpen_keepsPendingWhenNotifyFails() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "br-fail",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        authority.notifyBrowserPendingOpen = { _ in
            throw BotRemoteControlAuthority.Error(code: -32087, message: "Bot browser persist failed.")
        }
        XCTAssertThrowsError(
            try authority.dispatch(
                method: "bot.link.open",
                params: webLinkParams(botID: botID, requestID: "br-fail-1", url: "http://127.0.0.1:5000")
            )
        )
        XCTAssertEqual(
            try BotBrowserStore(appSupportDirectory: supportDir).loadPendingOpens().map(\.url),
            ["http://127.0.0.1:5000"]
        )
        let failed = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "br-fail-1",
        ])
        XCTAssertEqual(failed["status"] as? String, "failed")
    }

    func test_forceStop_acceptedSettlesToCompleted() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "stop-set",
            "name": "Piper",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "stop-set-run",
            "bot_id": botID,
            "text": "go",
        ])
        var requestID = ""
        authority.onStopRun = { _, _, _, _, _, id in requestID = id }
        let stopped = try authority.dispatch(method: "bot.force_stop", params: [
            "client_request_id": "stop-set-1",
            "bot_id": botID,
        ])
        XCTAssertEqual(stopped["status"] as? String, "accepted")
        authority.settle(requestID: requestID, status: .completed, readback: [
            "accepted": true,
            "force": true,
            "terminal": true,
        ])
        let status = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "stop-set-1",
        ])
        XCTAssertEqual(status["status"] as? String, "completed")
        let readback = try XCTUnwrap(status["readback"] as? [String: Any])
        let run = try XCTUnwrap(readback["run"] as? [String: Any])
        XCTAssertEqual(run["request_id"] as? String, "stop-set-run",
                       "async settlement must retain the original run identity")
        XCTAssertEqual(run["client_request_id"] as? String, "stop-set-run")
        XCTAssertEqual(readback["force"] as? Bool, true)
        XCTAssertEqual(readback["terminal"] as? Bool, true)
    }

    func test_conversationList_exposesLinkedAgentThreadID_soRemoteClientsCanReadTranscripts() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "conv-list-1",
            "name": "Piper",
        ])
        let botIDRaw = try XCTUnwrap(created["bot_id"] as? String)
        let botID = BotID(try XCTUnwrap(UUID(uuidString: botIDRaw)))
        let threadID = AgentThreadID()
        let linked = BotConversation(botID: botID, title: "Linked", linkedAgentThreadID: threadID)
        let unlinked = BotConversation(botID: botID, title: "Unlinked")
        try store.upsertConversation(linked)
        try store.upsertConversation(unlinked)

        let result = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id": botIDRaw])
        let rows = try XCTUnwrap(result["conversations"] as? [[String: Any]])
        let linkedRow = try XCTUnwrap(rows.first { $0["id"] as? String == linked.id.value.uuidString.lowercased() })
        let unlinkedRow = try XCTUnwrap(rows.first { $0["id"] as? String == unlinked.id.value.uuidString.lowercased() })

        XCTAssertEqual(
            linkedRow["linked_agent_thread_id"] as? String,
            threadID.value.uuidString.lowercased(),
            "Remote clients need the linked agent thread id to read the transcript via agent.message.list"
        )
        XCTAssertNil(
            unlinkedRow["linked_agent_thread_id"],
            "Conversations without a first run have no thread yet; the key must be absent, not fabricated"
        )
        XCTAssertNotNil(linkedRow["updated_at"] as? Double)
        XCTAssertNil(
            linkedRow["run_id"],
            "A stored thread without a live/pending run must not invent run_id"
        )
    }

    /// WHY: iOS queued promotion must see host run+thread on the conversation
    /// that is actually running, and must not treat the blocking live run as
    /// a queued follow-up's identity on the queue list.
    func test_conversationListAndQueueEmitLiveRunWithoutCopyingItOntoQueuedItems() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "queue-run-create",
            "name": "Queue Run",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "queue-run-conversation",
            "bot_id": botID,
            "title": "Live",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let runID = UUID().uuidString.lowercased()
        let threadID = UUID().uuidString.lowercased()
        authority.onSend = { _, _, _, _, _, _ in
            [
                "bot_id": botID,
                "conversation_id": conversationID,
                "thread_id": threadID,
                "run_id": runID,
                "enqueued": true,
                "queued_follow_up": false,
            ]
        }
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "queue-run-live",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "live",
        ])
        authority.onSend = nil
        let queued = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "queue-run-follow",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "follow up",
        ])
        let queuedReadback = try XCTUnwrap(queued["readback"] as? [String: Any])
        let queue = try XCTUnwrap(queuedReadback["queue"] as? [[String: Any]])
        let item = try XCTUnwrap(queue.first)
        XCTAssertEqual(item["conversation_id"] as? String, conversationID)
        XCTAssertEqual(item["client_request_id"] as? String, "queue-run-follow")
        XCTAssertNil(
            item["run_id"],
            "queue rows must not copy the blocking live run_id"
        )
        XCTAssertNil(
            item["thread_id"],
            "queue rows must not copy a live thread until this conversation stores one"
        )

        let listed = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id": botID])
        let rows = try XCTUnwrap(listed["conversations"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == conversationID })
        XCTAssertEqual(row["run_id"] as? String, runID)
        XCTAssertEqual(row["linked_agent_thread_id"] as? String, threadID)
    }

    /// WHY: an iOS retry must never overwrite bytes through a stale projection.
    /// The host returns durable conflict/recovery readback instead of silently
    /// accepting the old generation.
    func test_filesMutationCASConflictDoesNotChangeDiskAndSurvivesReceiptReplay() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "files-cas-bot", "name": "Files CAS",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let grant = try fileRootGrant(botID: botID)
        let first = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "files-cas-first",
            "bot_id": botID,
            "root_handle": grant.handle,
            "expected_generation": grant.generation,
            "expected_cas": grant.cas,
            "relative_path": "cas.txt",
            "op": "write",
            "contents": "authoritative",
        ])
        let firstReadback = try XCTUnwrap(first["readback"] as? [String: Any])
        let conflictParams: [String: Any] = [
            "client_request_id": "files-cas-stale",
            "bot_id": botID,
            "root_handle": firstReadback["root_handle"] as Any,
            "handle": firstReadback["handle"] as Any,
            "expected_generation": firstReadback["generation"] as Any,
            "expected_cas": grant.cas,
            "op": "write",
            "contents": "stale",
        ]
        let conflict = try authority.dispatch(method: "bot.files.mutate", params: conflictParams)
        let replay = try authority.dispatch(method: "bot.files.mutate", params: conflictParams)
        XCTAssertEqual(conflict["status"] as? String, "failed")
        XCTAssertEqual(conflict as NSDictionary, replay as NSDictionary)
        let readback = try XCTUnwrap(conflict["readback"] as? [String: Any])
        XCTAssertEqual(readback["conflict"] as? Bool, true)
        XCTAssertEqual(readback["expected_generation"] as? Int, firstReadback["generation"] as? Int,
                       "CAS must conflict even when generation is current")
        XCTAssertNotEqual(readback["expected_cas"] as? String, readback["current_cas"] as? String)
        XCTAssertEqual((readback["recovery"] as? [String: Any])?["method"] as? String, "bot.files.list")
        let bot = try XCTUnwrap(store.get(id: BotID(try XCTUnwrap(UUID(uuidString: botID)))))
        XCTAssertEqual(try String(contentsOf: BotHome(appSupportDirectory: supportDir, bot: bot).root
            .appendingPathComponent("cas.txt")), "authoritative")
    }

    func test_filesMutationAcceptsOnlyFreshProcessIssuedExactTuple() throws {
        // WHY: U057 file authority is a current-process capability. The exact
        // tuple returned by list/write must work, while rotated, cross-Bot, and
        // pre-relaunch handles must never regain authority from the sidecar.
        let owner = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "fresh-files-owner", "name": "Owner",
        ])
        let peer = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "fresh-files-peer", "name": "Peer",
        ])
        let ownerID = try XCTUnwrap(owner["bot_id"] as? String)
        let peerID = try XCTUnwrap(peer["bot_id"] as? String)
        let initial = try fileRootGrant(botID: ownerID, hostID: "host-a")
        let created = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "fresh-files-create", "host_id": "host-a", "bot_id": ownerID,
            "root_handle": initial.handle, "expected_generation": initial.generation,
            "expected_cas": initial.cas, "relative_path": "current.txt", "op": "write",
            "contents": "first",
        ])
        let current = try XCTUnwrap(created["readback"] as? [String: Any])

        let updated = try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "fresh-files-update", "host_id": "host-a", "bot_id": ownerID,
            "root_handle": current["root_handle"] as Any, "handle": current["handle"] as Any,
            "expected_generation": current["generation"] as Any,
            "expected_cas": current["root_cas"] as Any, "op": "write", "contents": "second",
        ])
        XCTAssertEqual(updated["status"] as? String, "completed",
                       "the exact tuple just issued by the host must remain usable")
        let latest = try XCTUnwrap(updated["readback"] as? [String: Any])

        XCTAssertThrowsError(try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "fresh-files-rotated", "host_id": "host-a", "bot_id": ownerID,
            "root_handle": initial.handle, "expected_generation": initial.generation,
            "expected_cas": initial.cas, "relative_path": "stale.txt", "op": "write",
        ]), "rotation must revoke the original root handle")
        XCTAssertThrowsError(try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "fresh-files-cross", "host_id": "host-a", "bot_id": peerID,
            "root_handle": latest["root_handle"] as Any, "handle": latest["handle"] as Any,
            "expected_generation": latest["generation"] as Any,
            "expected_cas": latest["root_cas"] as Any, "op": "write", "contents": "cross",
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget)
        }

        let relaunched = BotRemoteControlAuthority(
            db: db, store: store, settings: settings, appSupportDirectory: supportDir
        )
        XCTAssertThrowsError(try relaunched.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "fresh-files-relaunch-stale", "host_id": "host-a", "bot_id": ownerID,
            "root_handle": latest["root_handle"] as Any, "handle": latest["handle"] as Any,
            "expected_generation": latest["generation"] as Any,
            "expected_cas": latest["root_cas"] as Any, "op": "write", "contents": "stale",
        ]), "a persisted handle is data, not a process capability")

        let relisted = try relaunched.dispatch(method: "bot.files.list", params: [
            "host_id": "host-a", "bot_id": ownerID,
        ])
        let entry = try XCTUnwrap((relisted["entries"] as? [[String: Any]])?.first {
            $0["path"] as? String == "current.txt"
        })
        let afterRelaunch = try relaunched.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "fresh-files-relaunch-current", "host_id": "host-a", "bot_id": ownerID,
            "root_handle": relisted["root_handle"] as Any, "handle": entry["handle"] as Any,
            "expected_generation": relisted["generation"] as Any,
            "expected_cas": relisted["root_cas"] as Any, "op": "write", "contents": "third",
        ])
        XCTAssertEqual(afterRelaunch["status"] as? String, "completed")
    }

    /// WHY: a grant is authority, not a parseable path token. Its exact Bot,
    /// root, and containment fences remain mandatory while it is current.
    func test_fileGrantIsOpaqueAndRejectsCrossBotAndSymlinkEscape() throws {
        let first = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "files-owner", "name": "Owner",
        ])
        let second = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "files-thief", "name": "Thief",
        ])
        let ownerID = try XCTUnwrap(first["bot_id"] as? String)
        let thiefID = try XCTUnwrap(second["bot_id"] as? String)
        let grant = try fileRootGrant(botID: ownerID, hostID: "host-a")
        XCTAssertFalse(grant.handle.contains(ownerID))
        XCTAssertThrowsError(try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "files-cross-bot",
            "host_id": "host-a",
            "bot_id": thiefID,
            "root_handle": grant.handle,
            "expected_generation": grant.generation,
            "expected_cas": grant.cas,
            "relative_path": "stolen.txt",
            "op": "write",
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget)
        }

        let owner = try XCTUnwrap(store.get(id: BotID(try XCTUnwrap(UUID(uuidString: ownerID)))))
        let home = BotHome(appSupportDirectory: supportDir, bot: owner)
        try home.ensure(name: owner.name, handle: owner.handle, title: owner.title, description: owner.description, soul: "")
        let outside = supportDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "files-symlink",
            "bot_id": ownerID,
            "root_handle": grant.handle,
            "expected_generation": grant.generation,
            "expected_cas": grant.cas,
            "relative_path": "escape/payload.txt",
            "op": "write",
        ]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("payload.txt").path))

        XCTAssertThrowsError(try authority.dispatch(method: "bot.files.list", params: [
            "host_id": "host-b", "bot_id": ownerID,
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget)
        }

        _ = try authority.dispatch(method: "bot.files.location.set", params: [
            "client_request_id": "files-switch-docker",
            "host_id": "host-a",
            "bot_id": ownerID,
            "root": "docker_home",
            "previous_root_handle": grant.handle,
            "expected_generation": grant.generation,
            "expected_cas": grant.cas,
        ])
        let dockerGrant = try fileRootGrant(botID: ownerID, hostID: "host-a")
        _ = try authority.dispatch(method: "bot.files.location.set", params: [
            "client_request_id": "files-switch-back",
            "host_id": "host-a",
            "bot_id": ownerID,
            "root": "bot_home",
            "previous_root_handle": dockerGrant.handle,
            "expected_generation": dockerGrant.generation,
            "expected_cas": dockerGrant.cas,
        ])
        XCTAssertThrowsError(try authority.dispatch(method: "bot.files.mutate", params: [
            "client_request_id": "files-revoked-switch",
            "host_id": "host-a",
            "bot_id": ownerID,
            "handle": grant.handle,
            "relative_path": "revoked.txt",
            "op": "write",
        ]), "root switches must revoke every prior handle")

        let relaunched = BotRemoteControlAuthority(db: db, store: store, settings: settings, appSupportDirectory: supportDir)
        let listed = try relaunched.dispatch(method: "bot.files.list", params: ["bot_id": ownerID])
        XCTAssertGreaterThan(listed["generation"] as? Int ?? 0, grant.generation)
        XCTAssertEqual((listed["security"] as? [String: Any])?["symlink_safe"] as? Bool, true)
    }

    /// WHY: iOS may persist only a projection. Host relaunch must restore the
    /// exact Bot surface/session metadata without exporting website data.
    func test_browserStateRestoresExactHostBotSurfaceAndOpaqueSessionWithoutCookies() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "browser-restore", "name": "Browser",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        var openParams = try webLinkParams(
            botID: botID,
            requestID: "browser-open",
            url: "https://example.test/login"
        )
        openParams["title"] = "Sign in"
        let opened = try authority.dispatch(method: "bot.link.open", params: openParams)
        let openedState = try XCTUnwrap(opened["readback"] as? [String: Any])
        let surfaceID = try XCTUnwrap(openedState["surface_id"] as? String)
        let session = try XCTUnwrap(openedState["session"] as? [String: Any])
        XCTAssertNotNil(session["digest"] as? String)
        XCTAssertNil(openedState["cookies"])

        let relaunched = BotRemoteControlAuthority(db: db, store: store, settings: settings, appSupportDirectory: supportDir)
        let state = try relaunched.dispatch(method: "bot.browser.state", params: [
            "host_id": "host-a", "bot_id": botID,
        ])
        XCTAssertEqual(state["host_id"] as? String, "host-a")
        XCTAssertEqual(state["surface_id"] as? String, surfaceID)
        XCTAssertEqual(state["url"] as? String, "https://example.test/login")
        XCTAssertEqual((state["session"] as? [String: Any])?["digest"] as? String, session["digest"] as? String)
        XCTAssertEqual((state["security"] as? [String: Any])?["cookie_exported"] as? Bool, false)
        XCTAssertNil(state["cookies"])
        XCTAssertThrowsError(try relaunched.dispatch(method: "bot.browser.state", params: [
            "host_id": "host-b", "bot_id": botID,
        ])) { error in
            XCTAssertEqual(error as? BotRemoteControlAuthority.Error, .crossTarget)
        }
    }

    /// WHY: login completion comes from the host-owned page state, while stale
    /// snapshot actions fail with recovery and never enqueue a second action.
    func test_browserCASAndLoginCompletionUseAuthoritativeHostSession() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "browser-login", "name": "Login",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        var notifications = 0
        authority.notifyBrowserPendingOpen = { _ in notifications += 1 }
        let opened = try authority.dispatch(
            method: "bot.link.open",
            params: webLinkParams(
                botID: botID,
                requestID: "browser-login-open",
                url: "https://example.test/login"
            )
        )
        let before = try XCTUnwrap(opened["readback"] as? [String: Any])
        let stale = try authority.dispatch(method: "bot.browser.action", params: [
            "client_request_id": "browser-stale",
            "host_id": "host-a",
            "bot_id": botID,
            "surface_id": before["surface_id"] as Any,
            "snapshot_generation": 0,
            "expected_generation": 0,
            "action": "navigate",
            "url": "https://evil.invalid",
        ])
        XCTAssertEqual(stale["status"] as? String, "failed")
        XCTAssertEqual(((stale["readback"] as? [String: Any])?["recovery"] as? [String: Any])?["method"] as? String, "bot.browser.state")
        XCTAssertEqual(notifications, 1, "conflicts must not enqueue host work")

        let uuid = try XCTUnwrap(UUID(uuidString: botID))
        try BotBrowserStore(appSupportDirectory: supportDir).persistPageState(
            BotBrowserPageState(url: "https://example.test/home", title: "Home", cookies: ["session": "host-only"]),
            botID: BotID(uuid)
        )
        let completed = try authority.dispatch(method: "bot.browser.action", params: [
            "client_request_id": "browser-login-complete",
            "host_id": "host-a",
            "bot_id": botID,
            "surface_id": before["surface_id"] as Any,
            "snapshot_generation": before["generation"] as Any,
            "expected_generation": before["generation"] as Any,
            "action": "login.complete",
        ])
        let after = try XCTUnwrap(completed["readback"] as? [String: Any])
        XCTAssertEqual(completed["status"] as? String, "completed")
        XCTAssertEqual((after["session"] as? [String: Any])?["authenticated"] as? Bool, true)
        XCTAssertNotEqual(after["session_before_digest"] as? String, after["session_after_digest"] as? String)
        XCTAssertEqual(after["url"] as? String, "https://example.test/home")
        XCTAssertNil(after["cookies"])
        XCTAssertEqual(notifications, 1, "login verification must not reopen the page")
    }

    /// WHY: a notification acknowledgement is a security-sensitive remote
    /// mutation. It must clear only the exact host/item/Bot target for a
    /// profile learned from authenticated push registration, never a stale or
    /// client-invented profile/item tuple.
    func test_attentionAckRequiresRegisteredProfileAndExactHostItemBot() throws {
        let profileID = "ios-profile-1"
        let hostID = "host-attention-1"
        try BotAttentionPushBindingStore(db: db).bind(
            profileID: profileID,
            hostID: hostID,
            deviceID: "ios-device-1"
        )
        XCTAssertTrue(
            BotAttentionPushBindingStore(db: db).contains(profileID: profileID, hostID: hostID),
            "the authenticated registration binding must survive a new store instance"
        )
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "attention-bot",
            "name": "Attention Bot",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "attention-run",
            "host_id": hostID,
            "bot_id": botID,
            "text": "Finish this",
        ])
        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((listed["items"] as? [[String: Any]])?.first)
        let itemID = try XCTUnwrap(item["id"] as? String)
        XCTAssertEqual(item["profile_id"] as? String, profileID)
        XCTAssertEqual(item["host_id"] as? String, hostID)
        XCTAssertEqual(item["attention_item_id"] as? String, itemID)
        XCTAssertEqual(item["notification_id"] as? String, itemID)
        XCTAssertEqual(item["bot_id"] as? String, botID)
        XCTAssertEqual(item["source"] as? String, "bot")

        try BotAttentionPushBindingStore(db: db).bind(
            profileID: profileID,
            hostID: "host-attention-2",
            deviceID: "ios-device-2"
        )

        XCTAssertThrowsError(try authority.dispatch(method: "bot.attention.ack", params: [
            "client_request_id": "attention-wrong-profile",
            "profile_id": "invented-profile",
            "host_id": hostID,
            "attention_item_id": itemID,
            "bot_id": botID,
        ]))
        XCTAssertThrowsError(try authority.dispatch(method: "bot.attention.ack", params: [
            "client_request_id": "attention-wrong-item",
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": "stale-item",
            "bot_id": botID,
        ]))
        XCTAssertThrowsError(try authority.dispatch(method: "bot.attention.ack", params: [
            "client_request_id": "attention-wrong-host",
            "profile_id": profileID,
            "host_id": "host-attention-2",
            "attention_item_id": itemID,
            "bot_id": botID,
        ]))
        let otherBot = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "attention-other-bot",
            "name": "Other Attention Bot",
        ])
        let otherBotID = try XCTUnwrap(otherBot["bot_id"] as? String)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.attention.ack", params: [
            "client_request_id": "attention-wrong-bot",
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": itemID,
            "bot_id": otherBotID,
        ]))

        let acknowledged = try authority.dispatch(method: "bot.attention.ack", params: [
            "client_request_id": "attention-exact",
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": itemID,
            "bot_id": botID,
        ])
        let readback = try XCTUnwrap(acknowledged["readback"] as? [String: Any])
        XCTAssertEqual(acknowledged["status"] as? String, "completed")
        XCTAssertEqual(readback["state"] as? String, "none")
        XCTAssertEqual(readback["profile_id"] as? String, profileID)
        XCTAssertEqual(readback["host_id"] as? String, hostID)
        XCTAssertEqual(readback["attention_item_id"] as? String, itemID)
        XCTAssertEqual(readback["notification_id"] as? String, itemID)
        XCTAssertEqual(readback["bot_id"] as? String, botID)
        XCTAssertNil(readback["conversation_id"], "P003 has no conversation claim")
        let cleared = try authority.dispatch(method: "bot.attention.list", params: [:])
        let clearedItem = try XCTUnwrap((cleared["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(clearedItem["state"] as? String, "none")
        XCTAssertEqual(clearedItem["profile_id"] as? String, profileID)
        XCTAssertEqual(clearedItem["host_id"] as? String, hostID)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.attention.ack", params: [
            "client_request_id": "attention-stale-repeat",
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": itemID,
            "bot_id": botID,
        ]), "an already-cleared item is stale and must not emit another completed receipt")
    }

    private func fileRootGrant(
        botID: String,
        hostID: String = ""
    ) throws -> (handle: String, generation: Int, cas: String) {
        var params: [String: Any] = ["bot_id": botID]
        if !hostID.isEmpty { params["host_id"] = hostID }
        let listed = try authority.dispatch(method: "bot.files.list", params: params)
        return (
            try XCTUnwrap(listed["root_handle"] as? String),
            try XCTUnwrap(listed["generation"] as? Int),
            try XCTUnwrap(listed["root_cas"] as? String)
        )
    }

    private func webLinkParams(
        botID: String,
        requestID: String,
        url: String,
        hostID: String = "host-a"
    ) throws -> [String: Any] {
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "\(requestID)-conversation",
            "bot_id": botID,
            "title": "Link conversation",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let state = try authority.dispatch(method: "bot.browser.state", params: [
            "host_id": hostID,
            "bot_id": botID,
        ])
        return [
            "client_request_id": requestID,
            "host_id": hostID,
            "bot_id": botID,
            "conversation_id": conversationID,
            "surface_id": try XCTUnwrap(state["surface_id"] as? String),
            "expected_generation": try XCTUnwrap(state["generation"] as? Int),
            "snapshot_generation": try XCTUnwrap(state["snapshot_generation"] as? Int),
            "host_first": true,
            "link_kind": "web",
            "url": url,
        ]
    }
}
