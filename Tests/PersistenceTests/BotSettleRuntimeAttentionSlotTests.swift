import XCTest
import CoreModel
@testable import Persistence

/// The attention slot holds one item per Bot, and a routine can replace the
/// item of a live `bot.send` run. The run's terminal event must still release
/// the live run, or `bot.conversation.list` reports an ended run as live until
/// the Mac app restarts.
final class BotSettleRuntimeAttentionSlotTests: XCTestCase {
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
            .appendingPathComponent("rc-bot-settle-slot-\(UUID().uuidString)", isDirectory: true)
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

    private func conversationRow(botID: String, conversationID: String) throws -> [String: Any] {
        let listed = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id": botID])
        return try XCTUnwrap((listed["conversations"] as? [[String: Any]])?.first {
            $0["id"] as? String == conversationID
        })
    }

    private func attentionItem(botID: String) throws -> [String: Any] {
        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        return try XCTUnwrap((listed["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == botID
        })
    }

    /// WHY: the conversation row's `run_id` is what a client reads to decide
    /// whether a send is still running. The run ended, so the row must stop
    /// naming it even though the slot now belongs to a routine, and the
    /// routine's own item must be left alone.
    func test_settleRuntime_releasesTheLiveRunWhenARoutineReplacedItsAttentionItem() throws {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "slot-create",
            "name": "Slot Bot",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "slot-conversation",
            "bot_id": botID,
            "title": "Slot",
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
            "client_request_id": "slot-send",
            "host_id": "slot-host",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "Run while a routine fires",
        ])
        XCTAssertEqual(
            try conversationRow(botID: botID, conversationID: conversationID)["run_id"] as? String,
            runID,
            "the admitted run is reported as live"
        )

        let routine = try authority.dispatch(method: "bot.routine.create", params: [
            "client_request_id": "slot-routine",
            "bot_id": botID,
            "name": "Replace",
            "prompt": "Replace the slot",
            "schedule_spec_json": BotScheduleSpec().encodedJSON(),
        ])
        let routineID = try XCTUnwrap((routine["readback"] as? [String: Any])?["routine_id"] as? String)
        // The routine runs through the app runtime; this stands in for it.
        authority.onRoutineSend = { [store] routine in
            let conversation = BotConversation(botID: routine.definition.botID, title: routine.definition.name)
            try store!.upsertConversation(conversation)
            return [
                "bot_id": routine.definition.botID.value.uuidString.lowercased(),
                "conversation_id": conversation.id.value.uuidString.lowercased(),
                "run_id": UUID().uuidString.lowercased(),
            ]
        }
        let routineRun = try authority.dispatch(method: "bot.routine.run", params: [
            "client_request_id": "slot-routine-run",
            "bot_id": botID,
            "routine_id": routineID,
        ])
        let routineRunID = try XCTUnwrap((routineRun["readback"] as? [String: Any])?["run_id"] as? String)
        XCTAssertNotEqual(routineRunID, runID)

        XCTAssertTrue(
            authority.settleRuntime(botID: botID, runID: runID, failed: false),
            "the run ended even though its attention item was replaced"
        )
        XCTAssertNil(
            try conversationRow(botID: botID, conversationID: conversationID)["run_id"],
            "an ended run must not stay reported as live"
        )
        let item = try attentionItem(botID: botID)
        XCTAssertEqual(item["source"] as? String, "routine")
        XCTAssertEqual(item["run_id"] as? String, routineRunID)
        XCTAssertEqual(item["state"] as? String, "working")
        XCTAssertFalse(
            authority.settleRuntime(botID: botID, runID: runID, failed: false),
            "a second terminal event for the same run has nothing left to settle"
        )
    }
}
