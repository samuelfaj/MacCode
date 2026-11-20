import XCTest
import SwiftUI
import CoreModel
@testable import Surfaces
@testable import Persistence
@testable import AgentRuntime

@MainActor
final class SurfacesResponsiveRenderTests: XCTestCase {
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
        let tmp = NSTemporaryDirectory() + "rc2-responsive-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let thread = AgentThread(workspaceId: nil, title: "choices", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        if withNotices {
            for index in 0..<3 {
                let choices = TitioNoticeCopy.choicesBlock(
                    question: "Decision \(index)", options: ["Approve", "Decline"], notice: "fixture.notice.\(index)"
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

    private func fits(_ view: AnyView, _ name: String) throws {
        let artifacts = ProcessInfo.processInfo.environment["REMOTE_CODE_RESPONSIVE_ARTIFACT_DIR"]
        for width in [360.0, 500.0, 900.0] {
            let fit = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 700))
            XCTAssertLessThanOrEqual(fit.width, width + 0.5, "\(name) must fit \(Int(width)) pt")
            guard let artifacts else { continue }
            let host = NSHostingView(rootView: view.frame(width: width, height: 600))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: artifacts).appendingPathComponent("\(name)-\(Int(width)).png"))
            window.contentView = nil
        }
    }

    /// WHY: panes are split and resized; a populated Agent App (header, transcript,
    /// composer) and the Git panel must lay out inside 360, 500 and 900 pt.
    func test_populatedAgentAppAndGitPanelFitNarrowMediumAndWidePanes() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(atPath: h.directory) }
        await h.vm.waitForSelectThreadHydrationForTesting()
        try fits(AnyView(AgentAppView(vm: h.vm)), "agent-app")
        try fits(AnyView(DiffPanelView(vm: DiffPanelViewModel(cwd: h.directory))), "git-panel")
    }

    func test_autoRoutingOptionWithWorkerFallbackFitsNarrowMediumAndWidePanes() throws {
        let account = DistillAccountStatus(provider: .chatgpt, connected: true)
        let models = [
            AgentModelDescriptor(id: "main", label: "Main model", provider: .distill, accountProvider: "chatgpt"),
            AgentModelDescriptor(id: "worker", label: "Worker model", provider: .distill, accountProvider: "claude"),
            AgentModelDescriptor(id: "fallback", label: "Fallback model", provider: .distill, accountProvider: "grok")
        ]
        let route = DistillAutoRouting(enabled: true, options: [
            .init(id: "one", accountID: account.id, mainModel: "main", workerModel: "worker", workerFallbackModel: "fallback")
        ])
        let editor = DistillAutoRoutingEditor(draft: .constant(route), saved: route, statuses: [account], models: models)
        try fits(AnyView(editor), "auto-routing")
    }
}
