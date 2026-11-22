import XCTest
import SwiftUI
import CoreModel
@testable import Surfaces
@testable import Persistence
@testable import AgentRuntime

/// WHY: a Bot conversation opened in an Agent App tab showed only the branch
/// and context strip, so the owner could not tell which Bot ran the chat. The
/// tab must wear the same Bot header as the Bots Desk, and a plain thread keeps
/// the workspace header.
@MainActor
final class AgentAppBotHeaderTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private let bot = BotDefinition(handle: "linear-master", name: "Linear Master", title: "Linear unblocker", description: "")

    func test_headerBotIsTheThreadsOwnBot() {
        let other = BotDefinition(handle: "writer", name: "Writer", title: "", description: "")
        XCTAssertEqual(AgentAppView.headerBot(actor: .bot(bot.id), bots: [other, bot])?.id, bot.id)
        XCTAssertNil(AgentAppView.headerBot(actor: RunActor.none, bots: [bot]), "a plain thread keeps the workspace header")
        XCTAssertNil(AgentAppView.headerBot(actor: nil, bots: [bot]), "no selected thread keeps the workspace header")
        XCTAssertNil(
            AgentAppView.headerBot(actor: .bot(BotID()), bots: [bot]),
            "a deleted Bot falls back to the workspace header instead of naming another Bot"
        )
    }

    private func makeViewModel(actor: RunActor, directory: String) throws -> AgentAppViewModel {
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: directory).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let workspace = WorkspaceID()
        let thread = AgentThread(workspaceId: workspace, title: "bot chat", provider: .codex, model: "gpt-5.5", actor: actor)
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db), messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspace, cwd: directory + "/project", coordinator: coordinator,
            threadRepo: threadRepo, messageRepo: messageRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        let bot = self.bot
        vm.mentionableBotsProvider = { [bot] }
        vm.openBotStudio = { _ in }
        vm.selectThread(thread.id)
        return vm
    }

    private func render(_ vm: AgentAppViewModel, name: String, width: CGFloat = 1_000) throws -> (NSBitmapImageRep, NSWindow) {
        let size = NSSize(width: width, height: 400)
        let root = AgentAppView(vm: vm, layout: AgentAppViewLayout(showsThreadRail: false, showsHeader: true))
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-bot-header-\(name).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return (bitmap, window)
    }

    func test_botThreadPaintsADifferentHeaderThanAPlainThread() async throws {
        let botDirectory = NSTemporaryDirectory() + "rc2-bot-header-" + UUID().uuidString
        let plainDirectory = NSTemporaryDirectory() + "rc2-bot-header-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: botDirectory)
            try? FileManager.default.removeItem(atPath: plainDirectory)
        }
        let botVM = try makeViewModel(actor: .bot(bot.id), directory: botDirectory)
        let plainVM = try makeViewModel(actor: .none, directory: plainDirectory)
        await botVM.waitForSelectThreadHydrationForTesting()
        await plainVM.waitForSelectThreadHydrationForTesting()
        XCTAssertNotNil(botVM.selectedThreadId)
        XCTAssertTrue((botVM.statusMessage ?? "").isEmpty, "the fixture thread must open, or both headers are the plain one")
        let (botImage, botWindow) = try render(botVM, name: "bot")
        let (plainImage, plainWindow) = try render(plainVM, name: "plain")
        defer { botWindow.contentView = nil; plainWindow.contentView = nil }
        let scale = CGFloat(botImage.pixelsWide) / 1_000
        var changed = 0
        for y in stride(from: 2, to: Int(40 * scale), by: 3) {
            for x in stride(from: 0, to: botImage.pixelsWide, by: 6) {
                guard let a = botImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = plainImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) > 0.1 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 40, "the Bot thread must paint its own header, not the branch strip")
        // A narrow tab still lays out the header inside its 44pt strip.
        let (narrow, narrowWindow) = try render(botVM, name: "bot-narrow", width: 420)
        defer { narrowWindow.contentView = nil }
        XCTAssertEqual(CGFloat(narrow.pixelsWide) / CGFloat(botImage.pixelsWide), 0.42, accuracy: 0.01)
    }
}
