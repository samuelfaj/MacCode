import XCTest
import Foundation
import CoreModel
@testable import Persistence

/// One table of principal x context x policy-state x entry point, driven through the shipped
/// `BotRemoteControlAuthority.dispatch` and the real SQLite store. Every row states the decision
/// the host must make, so a change that widens access in any single entry point fails here.
final class BotContextAuthorityMatrixTests: XCTestCase {
    private struct Row {
        let name: String
        let method: String
        let bot: String      // "A" or "B"
        let context: String  // "general" or "workspace"
        let revision: Int    // policy revision sent
        let allowed: Bool
    }

    func testAllowDenyMatrixAcrossDirectQueueExportCreateAndNonContextualEntryPoints() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"])
        let directory = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("AuthorityMatrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try SQLiteDB(path: directory.appendingPathComponent("matrix.sqlite").path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let settings = SettingsStore(db: db)
        settings.update { $0.botsControlPlaneEnabled = true }
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: settings, appSupportDirectory: directory)
        let host = "host"
        let workspace = WorkspaceID(UUID())
        let workspaceKey = BotContext.workspace(workspace).storageKey

        func makeBot(_ name: String) throws -> String {
            let created = try authority.dispatch(method: "bot.create", params: ["client_request_id": "create-\(name)", "name": name])
            let id = try XCTUnwrap(created["bot_id"] as? String)
            _ = try authority.dispatch(method: "bot.routing.set", params: [
                "client_request_id": "route-\(name)", "bot_id": id, "host_id": host, "provider": "distill",
                "provider_instance_id": "distill", "model": "main-a", "routing_mode": "explicit"])
            return id
        }
        let botA = try makeBot("Matrix A")
        let botB = try makeBot("Matrix B")
        let botC = try makeBot("Matrix C")
        func grant(_ bot: String, key: String, actions: [String]) throws {
            _ = try authority.dispatch(method: "bot.context.grant", params: [
                "client_request_id": UUID().uuidString, "host_id": host, "bot_id": bot, "context_key": key,
                "context_version": 1, "policy_revision": 0, "actions": actions])
        }
        try grant(botA, key: "general:v1", actions: ["read", "send", "export"])
        try grant(botA, key: workspaceKey, actions: ["read", "send"])
        try grant(botB, key: "general:v1", actions: ["read"])  // read-only principal
        // C can read and send everywhere it is bound but never export: only the export check can deny it.
        try grant(botC, key: "general:v1", actions: ["read", "send"])
        try grant(botC, key: workspaceKey, actions: ["read", "send"])

        func conversation(_ bot: String, key: String) throws -> (id: String, thread: AgentThreadID) {
            let made = try authority.dispatch(method: "bot.conversation.create", params: [
                "client_request_id": UUID().uuidString, "bot_id": bot, "title": "T", "host_id": host,
                "context_key": key, "context_version": 1, "policy_revision": 1])
            let id = try XCTUnwrap((made["readback"] as? [String: Any])?["conversation_id"] as? String)
            let thread = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((made["readback"] as? [String: Any])?["thread_id"] as? String)))
            return (id, AgentThreadID(thread))
        }
        let generalA = try conversation(botA, key: "general:v1")
        let workspaceA = try conversation(botA, key: workspaceKey)
        let generalC = try conversation(botC, key: "general:v1")
        let workspaceAWithoutExportSource = workspaceA
        let message = AgentMessage(threadId: generalA.thread, role: .assistant, content: "approved excerpt")
        let messageC = AgentMessage(threadId: generalC.thread, role: .assistant, content: "approved excerpt C")
        let messageWorkspaceA = AgentMessage(threadId: workspaceAWithoutExportSource.thread, role: .assistant, content: "workspace excerpt")
        for item in [message, messageC, messageWorkspaceA] { try AgentMessageRepository(db: db).append(item) }

        func params(_ method: String, bot: String, key: String, revision: Int, convo: String) -> [String: Any] {
            var p: [String: Any] = ["bot_id": bot, "host_id": host, "context_key": key, "context_version": 1, "policy_revision": revision]
            switch method {
            case "bot.conversation.list": break
            case "bot.conversation.select": p["conversation_id"] = convo; p["client_request_id"] = UUID().uuidString
            case "bot.conversation.create": p["title"] = "x"; p["client_request_id"] = UUID().uuidString
            case "bot.conversation.enqueue": p["conversation_id"] = convo; p["text"] = "hold"; p["client_request_id"] = UUID().uuidString
            default:
                p["conversation_id"] = convo
                p["target_context_key"] = key == workspaceKey ? "general:v1" : workspaceKey
                p["target_policy_revision"] = 1
                let item = convo == generalC.id ? messageC : (convo == workspaceA.id ? messageWorkspaceA : message)
                p["message_ids"] = [item.id.value.uuidString.lowercased()]
            }
            return p
        }
        let rows: [Row] = [
            Row(name: "list general A", method: "bot.conversation.list", bot: "A", context: "general", revision: 1, allowed: true),
            Row(name: "list general B read", method: "bot.conversation.list", bot: "B", context: "general", revision: 1, allowed: true),
            Row(name: "list workspace B no binding", method: "bot.conversation.list", bot: "B", context: "workspace", revision: 1, allowed: false),
            Row(name: "list stale revision", method: "bot.conversation.list", bot: "A", context: "general", revision: 9, allowed: false),
            Row(name: "select general A", method: "bot.conversation.select", bot: "A", context: "general", revision: 1, allowed: true),
            Row(name: "select general B lacks send", method: "bot.conversation.select", bot: "B", context: "general", revision: 1, allowed: false),
            Row(name: "create workspace A", method: "bot.conversation.create", bot: "A", context: "workspace", revision: 1, allowed: true),
            Row(name: "create general B lacks send", method: "bot.conversation.create", bot: "B", context: "general", revision: 1, allowed: false),
            Row(name: "create stale revision", method: "bot.conversation.create", bot: "A", context: "general", revision: 7, allowed: false),
            Row(name: "enqueue general A", method: "bot.conversation.enqueue", bot: "A", context: "general", revision: 1, allowed: true),
            Row(name: "enqueue workspace A", method: "bot.conversation.enqueue", bot: "A", context: "workspace", revision: 1, allowed: true),
            Row(name: "enqueue B lacks send", method: "bot.conversation.enqueue", bot: "B", context: "general", revision: 1, allowed: false),
            Row(name: "enqueue wrong context for conversation", method: "bot.conversation.enqueue", bot: "A", context: "workspace", revision: 1, allowed: false),
            Row(name: "export general A", method: "bot.conversation.export.preview", bot: "A", context: "general", revision: 1, allowed: true),
            Row(name: "export C has read and send but no export", method: "bot.conversation.export.preview", bot: "C", context: "general", revision: 1, allowed: false),
            Row(name: "export from workspace without export action", method: "bot.conversation.export.preview", bot: "A", context: "workspace", revision: 1, allowed: false),
            Row(name: "export stale revision", method: "bot.conversation.export.preview", bot: "A", context: "general", revision: 5, allowed: false),
        ]
        func run(_ row: Row, convoOverride: String? = nil) -> (allowed: Bool, code: Int?) {
            let bot = row.bot == "A" ? botA : (row.bot == "B" ? botB : botC)
            let key = row.context == "general" ? "general:v1" : workspaceKey
            var convo = row.context == "general" ? (row.bot == "C" ? generalC.id : generalA.id) : workspaceA.id
            if row.name == "enqueue wrong context for conversation" { convo = generalA.id }
            if let convoOverride { convo = convoOverride }
            do {
                _ = try authority.dispatch(method: row.method, params: params(row.method, bot: bot, key: key, revision: row.revision, convo: convo))
                return (true, nil)
            } catch let error as BotRemoteControlAuthority.Error {
                return (false, error.code)
            } catch { return (false, nil) }
        }
        for row in rows {
            let outcome = run(row)
            XCTAssertEqual(outcome.allowed, row.allowed, "\(row.name): expected \(row.allowed ? "allow" : "deny") (code \(String(describing: outcome.code)))")
        }

        // Entry points with no contextual contract must refuse a context instead of inferring a grant.
        for method in ["bot.send", "bot.routine.run", "bot.routine.create", "bot.files.list", "bot.conversation.fork", "bot.queue.force_now", "bot.guest.start", "bot.routine.update", "bot.routine.set_enabled"] {
            var p = params("bot.conversation.list", bot: botA, key: "general:v1", revision: 1, convo: generalA.id)
            p["client_request_id"] = UUID().uuidString
            p["text"] = "x"
            XCTAssertThrowsError(try authority.dispatch(method: method, params: p), "\(method) must not accept a contextual grant implicitly")
        }

        // Restricted/isolated execution is not offered: the contract has no such option, so a client that
        // asks for one is refused instead of silently getting broader or different access.
        func bindingCount() throws -> Int64 {
            let st = try db.prepare("SELECT COUNT(*) FROM bot_context_bindings;")
            defer { st.reset() }
            XCTAssertTrue(try st.step())
            return st.columnInt64(0)
        }
        let bindingsBeforeRestricted = try bindingCount()
        func restrictedGrant(_ extra: [String: Any]) -> [String: Any] {
            var p: [String: Any] = ["client_request_id": UUID().uuidString, "host_id": host, "bot_id": botB, "context_key": workspaceKey, "context_version": 1, "policy_revision": 0, "actions": ["read"]]
            p.merge(extra) { _, new in new }
            return p
        }
        for field in ["access_mode", "isolation", "restricted", "network_policy", "filesystem_mode"] {
            XCTAssertThrowsError(try authority.dispatch(method: "bot.context.grant", params: restrictedGrant([field: "restricted"])), "grant must refuse unknown \(field)")
            for method in ["bot.conversation.create", "bot.conversation.enqueue"] {
                var p = params(method, bot: botA, key: "general:v1", revision: 1, convo: generalA.id)
                p[field] = "restricted"
                XCTAssertThrowsError(try authority.dispatch(method: method, params: p), "\(method) must refuse unknown \(field)")
            }
        }
        XCTAssertEqual(try bindingCount(), bindingsBeforeRestricted, "refused restricted requests must not change any binding")
        // Control: the same grant without the extra field is valid, so the field alone caused each refusal.
        _ = try authority.dispatch(method: "bot.context.grant", params: restrictedGrant([:]))
        XCTAssertEqual(try bindingCount(), bindingsBeforeRestricted + 1)

        // A retried contextual mutation replays its stored outcome instead of repeating the write.
        let replayParams = params("bot.conversation.create", bot: botA, key: "general:v1", revision: 1, convo: generalA.id)
        let first = try authority.dispatch(method: "bot.conversation.create", params: replayParams)
        let conversationsBefore = try db.prepare("SELECT COUNT(*) FROM bot_conversations;")
        XCTAssertTrue(try conversationsBefore.step())
        let countBefore = conversationsBefore.columnInt64(0)
        conversationsBefore.reset()
        let replayed = try authority.dispatch(method: "bot.conversation.create", params: replayParams)
        XCTAssertEqual((replayed["readback"] as? [String: Any])?["conversation_id"] as? String,
                       (first["readback"] as? [String: Any])?["conversation_id"] as? String, "same request id must replay the same conversation")
        let conversationsAfter = try db.prepare("SELECT COUNT(*) FROM bot_conversations;")
        XCTAssertTrue(try conversationsAfter.step())
        XCTAssertEqual(conversationsAfter.columnInt64(0), countBefore, "replay must not create a second conversation")
        conversationsAfter.reset()

        // Revocation flips every previously allowed row to deny.
        let current = try XCTUnwrap(try store.getContextBinding(hostID: host, botID: BotID(UUID(uuidString: botA)!), context: .general))
        _ = try store.revokeContext(hostID: host, botID: current.botID, context: .general, expectedRevision: current.policyRevision)
        for row in rows where row.allowed && row.bot == "A" && row.context == "general" {
            XCTAssertFalse(run(row).allowed, "\(row.name) must deny after revocation")
        }
        let workspaceStillAllowed = run(Row(name: "enqueue workspace A after general revoke", method: "bot.conversation.enqueue", bot: "A", context: "workspace", revision: 1, allowed: true))
        XCTAssertTrue(workspaceStillAllowed.allowed, "revoking general must not revoke the independent workspace binding")
    }
}

final class BotContextEnqueueReplayTests: XCTestCase {
    func testEnqueueReplayAfterReopenReturnsSameItemWithoutDuplicate() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"])
        let dir = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("EnqueueReplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("replay.sqlite").path
        func open() throws -> (SQLiteDB, BotRemoteControlAuthority) {
            let db = try SQLiteDB(path: path)
            try Schema.migrate(db)
            let settings = SettingsStore(db: db)
            settings.update { $0.botsControlPlaneEnabled = true }
            return (db, BotRemoteControlAuthority(db: db, store: BotStore(db: db), settings: settings, appSupportDirectory: dir))
        }
        let (db, authority) = try open()
        let host = "host"
        let bot = try XCTUnwrap(try authority.dispatch(method: "bot.create", params: ["client_request_id": "c", "name": "Replay"])["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.routing.set", params: ["client_request_id": "r", "bot_id": bot, "host_id": host, "provider": "distill", "provider_instance_id": "distill", "model": "m", "routing_mode": "explicit"])
        _ = try authority.dispatch(method: "bot.context.grant", params: ["client_request_id": "g", "host_id": host, "bot_id": bot, "context_key": "general:v1", "context_version": 1, "policy_revision": 0, "actions": ["read", "send"]])
        let made = try authority.dispatch(method: "bot.conversation.create", params: ["client_request_id": "mk", "bot_id": bot, "title": "T", "host_id": host, "context_key": "general:v1", "context_version": 1, "policy_revision": 1])
        let convo = try XCTUnwrap((made["readback"] as? [String: Any])?["conversation_id"] as? String)
        let params: [String: Any] = ["client_request_id": "enq-1", "bot_id": bot, "host_id": host, "context_key": "general:v1", "context_version": 1, "policy_revision": 1, "conversation_id": convo, "text": "hold me"]
        let first = try authority.dispatch(method: "bot.conversation.enqueue", params: params)
        func queued() throws -> Int64 {
            let st = try db.prepare("SELECT COUNT(*) FROM agent_queued_messages;")
            defer { st.reset() }
            XCTAssertTrue(try st.step())
            return st.columnInt64(0)
        }
        XCTAssertEqual(try queued(), 1)
        let (db2, reopened) = try open()
        let replay = try reopened.dispatch(method: "bot.conversation.enqueue", params: params)
        XCTAssertEqual((replay["readback"] as? [String: Any])?["queue_id"] as? String, (first["readback"] as? [String: Any])?["queue_id"] as? String)
        let st = try db2.prepare("SELECT COUNT(*) FROM agent_queued_messages;")
        XCTAssertTrue(try st.step())
        XCTAssertEqual(st.columnInt64(0), 1, "replay after reopen must not queue a second item")
    }
}

final class BotContextRoutinePeerReplayTests: XCTestCase {
    func testRoutineRunReplayAfterReopenDoesNotSendTwiceAndPeerRefusesRevokedContext() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"])
        let dir = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("RoutineReplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("routine.sqlite").path
        var sends = 0
        func open() throws -> BotRemoteControlAuthority {
            let db = try SQLiteDB(path: path)
            try Schema.migrate(db)
            let settings = SettingsStore(db: db)
            settings.update { $0.botsControlPlaneEnabled = true }
            let authority = BotRemoteControlAuthority(db: db, store: BotStore(db: db), settings: settings, appSupportDirectory: dir)
            authority.onRoutineSend = { _ in sends += 1; return [:] }
            return authority
        }
        let authority = try open()
        let host = "host"
        let bot = try XCTUnwrap(try authority.dispatch(method: "bot.create", params: ["client_request_id": "c", "name": "Routine"])["bot_id"] as? String)
        _ = try authority.dispatch(method: "bot.routing.set", params: ["client_request_id": "r", "bot_id": bot, "host_id": host, "provider": "distill", "provider_instance_id": "distill", "model": "m", "routing_mode": "explicit"])
        let created = try authority.dispatch(method: "bot.routine.create", params: ["client_request_id": "rc", "bot_id": bot, "name": "R", "prompt": "p", "schedule_spec_json": BotScheduleSpec().encodedJSON()])
        let routine = try XCTUnwrap((created["readback"] as? [String: Any])?["routine_id"] as? String)
        let run: [String: Any] = ["client_request_id": "run-1", "bot_id": bot, "routine_id": routine, "host_id": host]
        _ = try authority.dispatch(method: "bot.routine.run", params: run)
        XCTAssertEqual(sends, 1, "the first run sends once")
        let reopened = try open()
        _ = try reopened.dispatch(method: "bot.routine.run", params: run)
        XCTAssertEqual(sends, 1, "a replayed run request after reopen must not send again")

        // A contextual grant, once revoked, cannot be used to reach peer or routine entry points.
        _ = try reopened.dispatch(method: "bot.context.grant", params: ["client_request_id": "g", "host_id": host, "bot_id": bot, "context_key": "general:v1", "context_version": 1, "policy_revision": 0, "actions": ["read", "send", "delegate", "schedule"]])
        _ = try reopened.dispatch(method: "bot.context.revoke", params: ["client_request_id": "rv", "host_id": host, "bot_id": bot, "context_key": "general:v1", "context_version": 1, "policy_revision": 1])
        // Control: the peer entry point answers when no revoked context is attached.
        _ = try reopened.dispatch(method: "bot.peer.ask", params: ["client_request_id": "peer-ok", "bot_id": bot, "handle": "x"])
        for method in ["bot.peer.ask", "bot.routine.run"] {
            var p: [String: Any] = ["client_request_id": UUID().uuidString, "bot_id": bot, "host_id": host, "context_key": "general:v1", "context_version": 1, "policy_revision": 1, "routine_id": routine, "handle": "x", "text": "x"]
            if method == "bot.peer.ask" { p["client_request_id"] = "peer-\(UUID().uuidString)" }
            XCTAssertThrowsError(try reopened.dispatch(method: method, params: p), "\(method) must refuse a revoked contextual grant")
        }
        XCTAssertEqual(sends, 1, "no refused call may reach the host send")
    }
}

final class SocketPathOverrideGuardTests: XCTestCase {
    func testRegularFileIsRefusedAndSurvivesWhileAbsentPathIsHonored() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"])
        let dir = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("SockGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { unsetenv("RC2_SOCKET_PATH"); try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("precious.txt")
        try Data("keep".utf8).write(to: file)
        setenv("RC2_SOCKET_PATH", file.path, 1)
        let fallback = AppPaths.socketPath(for: .debug)
        XCTAssertNotEqual(fallback, file.path, "a regular file must never become the socket path")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
        let absent = dir.appendingPathComponent("new.sock").path
        setenv("RC2_SOCKET_PATH", absent, 1)
        XCTAssertEqual(AppPaths.socketPath(for: .debug), absent)
    }
}
