import XCTest
import CoreModel
import Persistence
import Surfaces
@testable import AppShell

final class BotWorkspaceScopeAndMacFilesTests: XCTestCase {
    private func store() throws -> BotStore {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return BotStore(db: db)
    }

    private func binding(_ bot: BotDefinition, _ context: BotContext, state: BotContextBindingState = .active) -> BotContextBinding {
        BotContextBinding(hostID: "host", botID: bot.id, context: context, state: state, policyRevision: 1, actions: [.read, .send])
    }

    func test_insideAWorkspaceOnlyItsOwnBotsAndGeneralBotsAreAvailable() throws {
        // WHY: @ in workspace "star" listed Bots exclusive to "elephant". A workspace
        // must only offer its own Bots plus general ones; general Bots stay everywhere.
        let store = try store()
        let star = WorkspaceID(UUID()), elephant = WorkspaceID(UUID())
        let own = try store.create(name: "Dev", title: "", description: "", handle: "star-dev", workspaceID: star)
        let foreign = try store.create(name: "Dev", title: "", description: "", handle: "elephant-dev", workspaceID: elephant)
        let general = try store.create(name: "Writer", title: "", description: "", handle: "writer")
        let titio = try store.create(name: "Titio", title: "", description: "", handle: TitioIdentity.handle)

        XCTAssertTrue(SidebarViewModel.isAvailable(own, bindings: [binding(own, .workspace(star))], inWorkspace: star))
        XCTAssertFalse(SidebarViewModel.isAvailable(foreign, bindings: [binding(foreign, .workspace(elephant))], inWorkspace: star))
        XCTAssertTrue(SidebarViewModel.isAvailable(general, bindings: [], inWorkspace: star), "never-bound catalog Bots are general")
        XCTAssertTrue(SidebarViewModel.isAvailable(general, bindings: [binding(general, .general)], inWorkspace: star))
        XCTAssertTrue(SidebarViewModel.isAvailable(titio, bindings: [], inWorkspace: star))
        XCTAssertFalse(SidebarViewModel.isAvailable(foreign, bindings: [binding(foreign, .workspace(elephant), state: .revoked)], inWorkspace: star),
                       "a revoked workspace grant must not turn a scoped Bot into a general one")
    }

    func test_contextGrantsInvalidateTheCachedBotList() throws {
        // WHY: the @ list is cached by Bot-list revision; a new workspace grant must
        // change which Bots a workspace offers without restarting the app.
        let store = try store()
        let bot = try store.create(name: "Dev", title: "", description: "", handle: "dev")
        let before = store.botsListRevision
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .workspace(WorkspaceID(UUID())), actions: [.read], expectedRevision: 0)
        XCTAssertGreaterThan(store.botsListRevision, before)
        let afterGrant = store.botsListRevision
        _ = try store.revokeContext(hostID: "host", botID: bot.id, context: grant.context, expectedRevision: grant.policyRevision)
        XCTAssertGreaterThan(store.botsListRevision, afterGrant)
    }

    func test_macPathsInAMessageAreFoundWithSpacesAndFinderNarrowSpace() throws {
        // WHY: a VM Bot cannot read "/Users/.../Screenshot ... 1.58.25 PM.png"; the host
        // must find the real file (Finder writes U+202F before PM) to copy it in.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rc-macpaths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let desktop = home.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let shot = desktop.appendingPathComponent("Screenshot 2026-10-27 at 1.58.25\u{202F}PM.png")
        try Data("png".utf8).write(to: shot)
        let notes = home.appendingPathComponent("notes.txt")
        try Data("n".utf8).write(to: notes)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rc-outside-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let typed = "\(desktop.path)/Screenshot 2026-10-27 at 1.58.25 PM.png what should I reply? also ~/notes.txt, \(outside.path) and \(home.path)/missing.png"
        let found = MacPathReferences.files(in: typed, home: home.path)
        XCTAssertEqual(found.map(\.lastPathComponent), [shot.lastPathComponent, "notes.txt"],
                       "existing files under home only; never files outside home or missing paths")
        XCTAssertEqual(MacPathReferences.requestedFile(in: "Please send 'Screenshot 2026-10-27 at 1.58.25 PM.png' from your Mac Desktop", home: home.path)?.lastPathComponent,
                       shot.lastPathComponent, "a quoted file name in a file request resolves from Desktop")
    }

    func test_vmPromptCarriesCopiedPathsButMacPromptDoesNot() throws {
        // WHY: typing the path is the user's consent; the VM Bot must be told where
        // the copy landed, and a Mac run must never copy anything.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rc-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("a b.png")
        try Data("png".utf8).write(to: file)
        var imported: [URL] = []
        let importer: ([URL]) throws -> [String] = { urls in
            imported += urls
            return urls.map { "/home/remotecode/Downloads/\($0.lastPathComponent)" }
        }
        let text = "look at \(file.path) please"
        let vm = BotsViewModel.supervisedRunPrompt(userText: text, compiledPayload: "PAYLOAD", provider: .claude,
                                                   executionTarget: .vm, importMacFiles: importer, macHome: home.path)
        XCTAssertTrue(vm.contains("\(file.path) -> /home/remotecode/Downloads/a b.png"))
        XCTAssertEqual(imported, [file])

        imported = []
        let mac = BotsViewModel.supervisedRunPrompt(userText: text, compiledPayload: "PAYLOAD", provider: .claude,
                                                    executionTarget: .mac, importMacFiles: importer, macHome: home.path)
        XCTAssertEqual(mac, "PAYLOAD")
        XCTAssertTrue(imported.isEmpty)

        let failing = BotsViewModel.supervisedRunPrompt(userText: text, compiledPayload: "PAYLOAD", provider: .claude,
                                                        executionTarget: .vm, importMacFiles: { _ in throw CocoaError(.fileNoSuchFile) }, macHome: home.path)
        XCTAssertTrue(failing.contains("not copied"), "a failed copy is reported to the Bot, never blocks the send")
    }

    func test_replyQuoteTargetStillResolvesForTheJump() {
        // WHY: the quote jump now resolves on tap instead of on every paint; the
        // lookup itself must keep finding the quoted assistant message.
        let thread = AgentThreadID()
        let target = AgentMessage(threadId: thread, role: .assistant, content: "The build is green now.")
        let reply = AgentMessage(threadId: thread, role: .user, content: "ok")
        XCTAssertEqual(AgentReplyQuoteTarget.messageID(for: "build is green…", in: [target, reply], before: reply.id), target.id)
    }
}
