import XCTest
import CoreModel
@testable import Persistence

/// The stored `bot.send` receipt proves admission only. A phone that missed
/// the live terminal event reads `bot.receipt.status`, so that answer must
/// carry the run's durable end or the entry cycles between unknown and
/// working with no exit.
final class BotSendReceiptRunOutcomeTests: XCTestCase {
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
            .appendingPathComponent("rc-bot-receipt-outcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = makeAuthority()
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

    private func makeAuthority() -> BotRemoteControlAuthority {
        BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
    }

    private struct StartedSend {
        let botID: String
        let conversationID: String
        let runID: AgentRunID
        let threadID: AgentThreadID
        let params: [String: Any]
        let result: [String: Any]
    }

    /// Admits one `bot.send` bound to an Agent run through `onSend`, the way
    /// the production hook binds the receipt to `prepared.runID`. The run row
    /// is written only when `rowStatus` is given: in production it is created
    /// after `bot.send` returns.
    private func startSend(prefix: String, rowStatus: AgentRunStatus?) throws -> StartedSend {
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
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let runID = AgentRunID()
        let threadID = AgentThreadID()
        try AgentThreadRepository(db: db).upsert(
            AgentThread(id: threadID, title: prefix, provider: .codex, model: "m")
        )
        if let rowStatus {
            try writeRun(runID, threadID: threadID, status: rowStatus)
        }
        authority.onSend = { _, _, _, _, _, _ in
            [
                "bot_id": botID,
                "conversation_id": conversationID,
                "thread_id": threadID.value.uuidString.lowercased(),
                "run_id": runID.value.uuidString.lowercased(),
                "enqueued": true,
                "queued_follow_up": false,
            ]
        }
        let params: [String: Any] = [
            "client_request_id": "\(prefix)-send",
            "host_id": "outcome-host",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "\(prefix) work",
        ]
        let result = try authority.dispatch(method: "bot.send", params: params)
        return StartedSend(
            botID: botID,
            conversationID: conversationID,
            runID: runID,
            threadID: threadID,
            params: params,
            result: result
        )
    }

    private func writeRun(
        _ runID: AgentRunID,
        threadID: AgentThreadID,
        status: AgentRunStatus,
        finishedAt: Date? = nil
    ) throws {
        try AgentRunRepository(db: db).upsert(AgentRun(
            id: runID,
            threadId: threadID,
            provider: .codex,
            model: "m",
            status: status,
            finishedAt: finishedAt
        ))
    }

    private func receiptReadback(
        _ requestID: String,
        from authority: BotRemoteControlAuthority
    ) throws -> [String: Any] {
        let status = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": requestID,
        ])
        return try XCTUnwrap(status["readback"] as? [String: Any])
    }

    /// WHY: admission is not completion. While the run is live the receipt
    /// must not claim an end; once the run row is terminal it must, or the
    /// phone keeps polling a run that already finished. The stored receipt is
    /// also the `bot.send` idempotent replay, so it must stay unchanged.
    func test_receiptStatus_reportsRunOutcomeOnceTheRunRowIsTerminal() throws {
        let send = try startSend(prefix: "outcome-terminal", rowStatus: .running)
        let sentReadback = try XCTUnwrap(send.result["readback"] as? [String: Any])

        let live = try receiptReadback("outcome-terminal-send", from: authority)
        XCTAssertNil(live["run_outcome"], "a running run has no outcome yet")
        XCTAssertNil(live["run_finished_at"])

        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try writeRun(send.runID, threadID: send.threadID, status: .completed, finishedAt: finishedAt)

        let status = try authority.dispatch(method: "bot.receipt.status", params: [
            "client_request_id": "outcome-terminal-send",
        ])
        let readback = try XCTUnwrap(status["readback"] as? [String: Any])
        XCTAssertEqual(readback["run_outcome"] as? String, "completed")
        XCTAssertEqual(readback["run_finished_at"] as? Double, finishedAt.timeIntervalSince1970)
        XCTAssertEqual(status["status"] as? String, send.result["status"] as? String)
        XCTAssertEqual(status["request_id"] as? String, "outcome-terminal-send")
        XCTAssertEqual(readback["run_id"] as? String, sentReadback["run_id"] as? String)
        XCTAssertEqual(
            try XCTUnwrap(readback["run"] as? [String: Any]) as NSDictionary,
            try XCTUnwrap(sentReadback["run"] as? [String: Any]) as NSDictionary,
            "the admitted run readback still decodes as the send result did"
        )

        let replay = try authority.dispatch(method: "bot.send", params: send.params)
        XCTAssertEqual(replay as NSDictionary, send.result as NSDictionary,
                       "the outcome is derived on read; the stored receipt is not rewritten")
    }

    /// WHY: a Mac relaunch drops every in-memory live run and the launch
    /// reconcile interrupts its row. A receipt stored before the relaunch is
    /// exactly the entry already stuck on the phone, so it must report the end.
    func test_receiptStatus_afterHostRelaunch_reportsInterrupted() throws {
        _ = try startSend(prefix: "outcome-relaunch", rowStatus: .running)

        XCTAssertEqual(try AgentRunRepository(db: db).reconcileRunningOnLaunch(), 1)
        let relaunched = makeAuthority()

        let readback = try receiptReadback("outcome-relaunch-send", from: relaunched)
        XCTAssertEqual(readback["run_outcome"] as? String, "interrupted")
        XCTAssertNotNil(readback["run_finished_at"] as? Double)
        XCTAssertEqual(readback["enqueued"] as? Bool, false)
    }

    /// WHY: the attention slot holds one item per Bot and a routine can
    /// replace it. The receipt is the per-request authority, so its outcome
    /// must not depend on what the slot currently shows.
    func test_receiptStatus_outcomeDoesNotDependOnTheAttentionSlot() throws {
        let send = try startSend(prefix: "outcome-slot", rowStatus: .running)
        try writeRun(send.runID, threadID: send.threadID, status: .failed, finishedAt: Date())

        let routine = try authority.dispatch(method: "bot.routine.create", params: [
            "client_request_id": "outcome-slot-routine",
            "bot_id": send.botID,
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
        _ = try authority.dispatch(method: "bot.routine.run", params: [
            "client_request_id": "outcome-slot-routine-run",
            "bot_id": send.botID,
            "routine_id": routineID,
        ])
        let attention = try authority.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((attention["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == send.botID
        })
        XCTAssertEqual(item["source"] as? String, "routine", "the slot no longer names the send's run")

        let readback = try receiptReadback("outcome-slot-send", from: authority)
        XCTAssertEqual(readback["run_outcome"] as? String, "failed")
    }

    /// WHY: a queued send carries the blocking run's id, not its own, and a
    /// missing run row can be a provider start that is still pending. Reporting
    /// an end in either case would mark a live or not-yet-started send as ended.
    func test_receiptStatus_addsNoOutcomeForQueuedSendOrMissingRunRow() throws {
        let send = try startSend(prefix: "outcome-queued", rowStatus: .running)
        try writeRun(send.runID, threadID: send.threadID, status: .completed, finishedAt: Date())
        authority.onSend = nil
        let queued = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "outcome-queued-follow-up",
            "host_id": "outcome-host",
            "bot_id": send.botID,
            "conversation_id": send.conversationID,
            "text": "Queue behind the live run",
        ])
        let queuedSent = try XCTUnwrap(queued["readback"] as? [String: Any])
        XCTAssertEqual(queuedSent["enqueued"] as? Bool, true)
        XCTAssertEqual(queuedSent["run_id"] as? String, send.runID.value.uuidString.lowercased())
        let queuedReadback = try receiptReadback("outcome-queued-follow-up", from: authority)
        XCTAssertNil(queuedReadback["run_outcome"], "the terminal row belongs to another request")

        _ = try startSend(prefix: "outcome-no-row", rowStatus: nil)
        let noRow = try receiptReadback("outcome-no-row-send", from: authority)
        XCTAssertEqual(noRow["enqueued"] as? Bool, false)
        XCTAssertNil(noRow["run_outcome"], "no durable row is not proof that the run ended")
    }
}
