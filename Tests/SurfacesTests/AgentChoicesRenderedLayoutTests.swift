import XCTest
import SwiftUI
import CoreModel
@testable import Surfaces
@testable import Persistence
@testable import AgentRuntime

@MainActor
final class AgentChoicesRenderedLayoutTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private struct Harness {
        let vm: AgentAppViewModel
        let threadRepo: AgentThreadRepository
        let messageRepo: AgentMessageRepository
        let thread: AgentThread
        let directory: String
    }

    private func makeHarness(withNotices: Bool = true) throws -> Harness {
        let tmp = NSTemporaryDirectory() + "rc2-choices-layout-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let thread = AgentThread(workspaceId: nil, title: "choices", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        if withNotices {
            for index in 0..<3 {
                let choices = TitioNoticeCopy.choicesBlock(
                    question: "Decision \(index)", options: ["Approve", "Decline"], notice: "fixture.notice.\(index)",
                    source: ["workspace": "MacCode", "bot": "Developer", "conversation": "Review deployment for staging"]
                )
                try messageRepo.append(AgentMessage(
                    threadId: thread.id, role: .assistant,
                    content: "Please decide.\n\n\(choices)",
                    createdAt: Date(timeIntervalSince1970: 1_792_094_460 + Double(index))
                ))
            }
        }
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db), messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let embedding = AgentAppEmbedding(
            pinnedThreadId: thread.id,
            noticeChoiceHandler: { _, _ in },
            noticeClearHandler: { _ in true }
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp, coordinator: coordinator,
            threadRepo: threadRepo, messageRepo: messageRepo,
            promptHistoryStore: PromptHistoryStore(db: db), embedding: embedding
        )
        vm.selectThread(thread.id)
        return Harness(vm: vm, threadRepo: threadRepo, messageRepo: messageRepo, thread: thread, directory: tmp)
    }

    private func render(_ vm: AgentAppViewModel, size: NSSize, name: String) throws -> (NSBitmapImageRep, NSWindow) {
        let root = AgentAppView(
            vm: vm,
            layout: AgentAppViewLayout(showsThreadRail: false, showsHeader: false)
        ).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc-choices-layout-\(name).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return (bitmap, window)
    }

    func testRenderedChoiceNoticesSitInTheTimelineAndPreserveTheComposer() async throws {
        let notices = try makeHarness()
        let empty = try makeHarness(withNotices: false)
        defer {
            try? FileManager.default.removeItem(atPath: notices.directory)
            try? FileManager.default.removeItem(atPath: empty.directory)
        }
        await notices.vm.waitForSelectThreadHydrationForTesting()
        await empty.vm.waitForSelectThreadHydrationForTesting()
        for (name, size) in [("wide", NSSize(width: 1_000, height: 700)), ("narrow", NSSize(width: 600, height: 400))] {
            let (actual, actualWindow) = try render(notices.vm, size: size, name: name)
            let (baseline, baselineWindow) = try render(empty.vm, size: size, name: name + "-empty")
            defer { actualWindow.contentView = nil; baselineWindow.contentView = nil }
            XCTAssertEqual(actual.pixelsWide, baseline.pixelsWide)
            XCTAssertEqual(actual.pixelsHigh, baseline.pixelsHigh)
            let scale = CGFloat(actual.pixelsWide) / size.width
            func differs(_ x: Int, _ y: Int) -> Bool {
                guard let a = actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = baseline.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return true }
                return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.04
            }
            // Compare the input region; footer locks intentionally differ once a thread has messages.
            let bottomRegion = Int(108 * scale)
            for y in stride(from: actual.pixelsHigh - Int(100 * scale), to: actual.pixelsHigh - Int(65 * scale), by: 12) {
                for x in stride(from: Int(16 * scale), to: actual.pixelsWide - Int(16 * scale), by: 24) {
                    XCTAssertFalse(differs(x, y), "notice stack moved or covered composer at \(name) \(x),\(y)")
                }
            }
            // A centered fixed-width card leaves both edge samples unchanged; a full-width card does not.
            let left = Int(30 * scale)
            let right = actual.pixelsWide - left
            let middle = actual.pixelsWide / 2
            let filledRows = stride(from: 0, to: actual.pixelsHigh - bottomRegion, by: 4).filter { y in
                differs(left, y) && differs(middle, y) && differs(right, y)
            }
            XCTAssertGreaterThan(filledRows.count, 4, "real card backgrounds must span the available chat width")
        }
    }

    func testEarlierQuestionsRemainPaintedWhileRunning() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(atPath: harness.directory) }
        await harness.vm.waitForSelectThreadHydrationForTesting()
        harness.vm.messages.append(AgentMessage(
            threadId: harness.thread.id, role: .user, content: "Staging",
            createdAt: Date(timeIntervalSince1970: 1_792_094_470)
        ))
        harness.vm.status = .running
        let size = NSSize(width: 1_000, height: 700)
        let (actual, actualWindow) = try render(harness.vm, size: size, name: "collapsed-running")
        defer { actualWindow.contentView = nil }
        harness.vm.messages = harness.vm.messages.map { message in
            var message = message
            message.content = BotChoicesBlock.parse(message.content).text
            return message
        }
        let (withoutQuestions, expectedWindow) = try render(harness.vm, size: size, name: "collapsed-running-without-questions")
        defer { expectedWindow.contentView = nil }
        let scale = CGFloat(actual.pixelsWide) / size.width
        // Earlier questions remain in the timeline after an answer starts a run.
        // Removing their cards must visibly change that retained history.
        var changedSamples = 0
        for y in stride(from: Int(200 * scale), to: Int(560 * scale), by: 16) {
            for x in stride(from: Int(30 * scale), to: actual.pixelsWide - Int(30 * scale), by: 24) {
                let a = try XCTUnwrap(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try XCTUnwrap(withoutQuestions.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let difference = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                if difference > 0.04 { changedSamples += 1 }
            }
        }
        XCTAssertGreaterThan(changedSamples, 4, "earlier question cards must remain visible during a follow-up")
    }
}
