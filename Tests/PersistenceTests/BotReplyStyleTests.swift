import XCTest
import CoreModel
@testable import Persistence

/// Per-Bot reply style (2026-10-15): Verbosity Human/Verbose and Caveman,
/// stored on the Bot row, editable from the Mac Studio and a paired device.
final class BotReplyStyleTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!
    private var authority: BotRemoteControlAuthority!
    private var supportDir: URL!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-reply-style-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )
    }

    override func tearDown() {
        authority = nil
        store = nil
        db = nil
        if let supportDir { try? FileManager.default.removeItem(at: supportDir) }
        supportDir = nil
    }

    func test_upgradeMakesEveryExistingBotHumanAndCavemanExceptTitio() throws {
        // WHY: the owner's defaults apply to Bots that already exist, not only
        // to new ones: every Bot speaks Human + caveman, Titio speaks Human in
        // full sentences.
        let old = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(old, Schema.steps.filter { $0.version < Schema.botReplyStyleSchemaVersion })
        for (id, handle) in [(UUID(), "ceo"), (UUID(), "titio")] {
            let insert = try old.prepare("""
                INSERT INTO bots(id, handle, name, title, description, avatar_symbol, created_at, updated_at)
                VALUES(?, ?, ?, '', '', 'person', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
                """)
            try insert.bind(1, id.uuidString.lowercased())
            try insert.bind(2, handle)
            try insert.bind(3, handle.capitalized)
            _ = try insert.step()
            insert.reset()
        }

        try Schema.migrateSteps(old, Schema.steps)

        let read = try old.prepare("SELECT handle, reply_verbosity, caveman_enabled FROM bots ORDER BY handle;")
        var rows: [String: (String, Int64)] = [:]
        while try read.step() {
            rows[read.columnText(0) ?? ""] = (read.columnText(1) ?? "", read.columnInt64(2))
        }
        XCTAssertEqual(rows["ceo"]?.0, "human")
        XCTAssertEqual(rows["ceo"]?.1, 1, "existing Bots become caveman")
        XCTAssertEqual(rows["titio"]?.0, "human")
        XCTAssertEqual(rows["titio"]?.1, 0, "Titio keeps full sentences")
    }

    func test_newBotsDefaultToSimpleAndTitioToHumanProse() throws {
        // WHY: Simple is the default reply style for every newly created Bot.
        let ceo = try store.create(name: "Ceo", title: "", description: "")
        XCTAssertEqual(ceo.verbosity, .human)
        XCTAssertEqual(try store.get(id: ceo.id)?.verbosity, .human, "the default is persisted")
        XCTAssertTrue(ceo.cavemanEnabled)
        let titio = try store.create(name: "Titio", title: "", description: "", handle: TitioIdentity.handle)
        XCTAssertEqual(titio.verbosity, .human)
        XCTAssertFalse(titio.cavemanEnabled)
        XCTAssertEqual(try store.get(id: titio.id)?.cavemanEnabled, false, "the default is persisted, not computed per read")
    }

    func test_replyStyleSurvivesReopenAndDuplicate() throws {
        // WHY: an explicit user choice must survive closing RemoteCode, and a
        // copied Bot behaves like its source.
        let bot = try store.create(name: "Dev", title: "", description: "")
        try store.setReplyStyle(id: bot.id, verbosity: .verbose, cavemanEnabled: false)
        let reopened = BotStore(db: db)
        let read = try XCTUnwrap(try reopened.get(id: bot.id))
        XCTAssertEqual(read.verbosity, .verbose)
        XCTAssertFalse(read.cavemanEnabled)
        let copy = try store.duplicate(id: bot.id)
        XCTAssertEqual(copy.verbosity, .verbose)
        XCTAssertFalse(copy.cavemanEnabled)
    }

    func test_pairedDeviceReadsAndSetsReplyStyle() throws {
        // WHY: iOS mirrors the Studio: the Bot dict carries both fields and the
        // two setters change exactly one field each.
        let bot = try store.create(name: "Dev", title: "", description: "")
        let botID = bot.id.value.uuidString.lowercased()
        let before = try authority.dispatch(method: "bot.get", params: ["bot_id": botID])
        let encoded = before
        XCTAssertEqual(encoded["verbosity"] as? String, "human")
        XCTAssertEqual(encoded["caveman_enabled"] as? Bool, true)

        let human = try authority.dispatch(method: "bot.verbosity.set", params: [
            "client_request_id": "v1", "bot_id": botID, "verbosity": "human",
        ])
        XCTAssertEqual((human["readback"] as? [String: Any])?["verbosity"] as? String, "human")
        XCTAssertEqual(try store.get(id: bot.id)?.verbosity, .human)
        XCTAssertEqual(try store.get(id: bot.id)?.cavemanEnabled, true, "verbosity leaves caveman alone")

        _ = try authority.dispatch(method: "bot.caveman.set", params: [
            "client_request_id": "c1", "bot_id": botID, "enabled": false,
        ])
        XCTAssertEqual(try store.get(id: bot.id)?.cavemanEnabled, false)
        XCTAssertEqual(try store.get(id: bot.id)?.verbosity, .human, "caveman leaves verbosity alone")

        XCTAssertThrowsError(try authority.dispatch(method: "bot.verbosity.set", params: [
            "client_request_id": "v2", "bot_id": botID, "verbosity": "loud",
        ]), "an unknown verbosity is rejected, not stored")
    }

    func test_factoryResetRestoresTitioAndKeepsConversations() throws {
        // WHY: a user who broke Titio from the phone gets the built-in Titio
        // back without losing chats; no other Bot can be overwritten with it.
        let titio = try store.create(
            name: TitioIdentity.name,
            title: TitioIdentity.title,
            description: TitioIdentity.description,
            handle: TitioIdentity.handle,
            soul: TitioIdentity.soul
        )
        let conversation = BotConversation(botID: titio.id, title: "oi")
        try store.upsertConversation(conversation)
        _ = try store.updateProfile(id: titio.id, name: "Gato", title: "Whatever", description: "", avatarSymbol: "cat")
        try store.setReplyStyle(id: titio.id, verbosity: .verbose, cavemanEnabled: true)

        let reply = try authority.dispatch(method: "bot.factory_reset", params: [
            "client_request_id": "reset", "bot_id": titio.id.value.uuidString.lowercased(),
        ])
        let readback = try XCTUnwrap((reply["readback"] as? [String: Any])?["bot"] as? [String: Any])
        XCTAssertEqual(readback["name"] as? String, TitioIdentity.name)
        XCTAssertEqual(readback["verbosity"] as? String, "human")
        XCTAssertEqual(readback["caveman_enabled"] as? Bool, false)

        let restored = try XCTUnwrap(try store.get(id: titio.id))
        XCTAssertEqual(restored.name, TitioIdentity.name)
        XCTAssertEqual(restored.title, TitioIdentity.title)
        XCTAssertEqual(restored.description, TitioIdentity.description)
        XCTAssertEqual(restored.avatarSymbol, BotBlobatarSpec.default.token)
        let revision = try XCTUnwrap(try store.getRevision(id: try XCTUnwrap(restored.currentRevisionID)))
        XCTAssertEqual(revision.soul, TitioIdentity.soul)
        XCTAssertEqual(try store.listConversations(botID: titio.id).map(\.id), [conversation.id])

        let other = try store.create(name: "Dev", title: "Builds", description: "")
        XCTAssertThrowsError(try authority.dispatch(method: "bot.factory_reset", params: [
            "client_request_id": "reset-other", "bot_id": other.id.value.uuidString.lowercased(),
        ]))
        XCTAssertEqual(try store.get(id: other.id)?.name, "Dev")
    }
}
