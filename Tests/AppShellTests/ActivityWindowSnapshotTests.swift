import AppKit
import CoreModel
import Persistence
import SwiftUI
@testable import Surfaces
import XCTest
@testable import AppShell
import SocketServer

/// Renders the Activity screen offscreen with worst-case data. Set
/// `REMOTE_CODE_ACTIVITY_ARTIFACT_DIR` to keep the PNGs for visual review.
@MainActor
final class ActivityWindowSnapshotTests: XCTestCase {
    private func item(
        _ id: String, kind: String = "agent", state: String, title: String, workspace: String? = "star",
        provider: String? = "distill", summary: String? = nil, at date: String = "2026-10-13T12:00:00Z",
        viewed: String? = nil, needsAction: Bool = false, error: String? = nil, origin: String? = nil,
        files: [String] = []
    ) -> ActivityWireItem {
        ActivityWireItem(
            id: id, kind: kind, run_id: "run", request_id: nil, notification_id: nil,
            workspace_id: workspace.map { _ in "workspace" }, thread_id: "thread", surface_id: nil, state: state,
            title: title, workspace_name: workspace, provider: provider, summary: summary,
            occurred_at: date, started_at: "2026-10-13T08:00:00Z", finished_at: "2026-10-13T12:00:00Z", viewed_at: viewed,
            attention_acknowledged_at: nil, needs_action: needsAction, blocking: false,
            final_message_id: nil, checkpoint_id: nil, checkpoint_turn_count: files.isEmpty ? nil : 3,
            changed_files: files, error: error, origin_label: origin
        )
    }

    /// One row per worst case, spread across the first rows so a single frame shows them all.
    private var worstCase: [ActivityWireItem] {
        let longText = String(repeating: "Refactored the checkout-address validation pipeline and re-ran every integration suite. ", count: 24)
        return [
            item("run:long", state: "failed", title: "María-José Hernández-Villanueva — Überprüfung der Rechtsschutzversicherungsgesellschaften für pamela-decoracao",
                 workspace: "new-remote-code-with-a-very-long-workspace-name", provider: "claude-opus-5-5",
                 summary: longText, needsAction: true,
                 error: "Claude Agent SDK bridge exited with status 1\nERR_REQUIRE_ESM: /Users/sam/Library/Application Support/RemoteCode/ClaudeAgentSDKBridge.mjs",
                 origin: "Scheduled task: Elephant - Task 2",
                 files: ["Sources/AppShell/A/Very/Deeply/Nested/Directory/Structure/That/Keeps/Going/ActivityWindowWithAnUnreasonablyLongFileName.swift", "README.md"]),
            item("run:one-letter", state: "completed", title: "J", workspace: nil, provider: nil, summary: ActivityWireItem.missingSummary, viewed: "2026-10-13T12:00:00Z"),
            item("run:cjk", state: "interrupted", title: "王秀英のタスク：決済フローの検証を完了してください", summary: "決済フローの検証", needsAction: true),
            item("run:rtl", state: "completed", title: "مراجعة تدفق الدفع وإصلاح التحقق من العنوان", summary: "تم"),
            item("run:emoji", state: "stopped", title: "👩🏽‍💻🚀 ship it", summary: nil, at: "2026-10-01T09:00:00Z", viewed: "2026-10-13T12:00:00Z"),
            item("run:blank", state: "failed", title: "  \n ", summary: nil, at: "1970-01-01T00:00:00Z", needsAction: true),
            item("run:markup", state: "completed", title: "<script>alert(1)</script> &amp; **bold** _under_", summary: "line one\nline two\nline three\nline four"),
            item("run:future", state: "completed", title: "Finished ahead of the local clock", summary: "Clock skew", at: "2099-01-01T00:00:00Z"),
            item("bot-attention:1", kind: "request", state: "waiting_answer", title: "Reply to Bot", workspace: nil, provider: nil, needsAction: true, origin: "Bot conversation: You are an autonomous GitHub PR maintenance agent. Your goal is to bring every open pull request to a mergeable state"),
            item("bot-attention:2", kind: "request", state: "needs_you", title: "Review Bot handoff", workspace: nil, provider: nil, needsAction: true),
            item("request:thread:1", kind: "request", state: "waiting_approval", title: "Approve or decline request", needsAction: true),
            item("request:thread:2", kind: "request", state: "expired", title: "Request expired"),
            item("run:running", state: "running", title: "Star - Task 1", origin: "Scheduled task: Star - Task 1"),
            item("run:queued", state: "queued", title: "Star - Testing to Review")
        ]
    }

    private func page(_ items: [ActivityWireItem], cursor: String? = nil, counts: ActivityWireCounts) -> JSONValue {
        JSONValue.decode(from: try! JSONEncoder().encode(ActivityWirePage(items: items, next_cursor: cursor, counts: counts, generated_at: "2026-10-13T12:00:00Z")))!
    }

    private func render(
        _ name: String, items: [ActivityWireItem], counts: ActivityWireCounts, cursor: String? = nil,
        size: CGSize, selecting selected: String? = nil, failing: Bool = false, clearAll: Bool = false,
        makeConversation: @escaping (ActivityWireItem) -> ActivityConversation? = { _ in nil },
        terminalSnapshot: @escaping (ActivityWireItem) -> TerminalTextSnapshot? = { _ in nil }
    ) async throws -> NSBitmapImageRep {
        let defaults = UserDefaults(suiteName: "activity-snapshot-\(UUID())")!
        defaults.set("needsYou", forKey: "activity.tab")
        var loaded = false
        let response = page(items, cursor: cursor, counts: counts)
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in
                if failing, loaded { throw NSError(domain: "offline", code: 2, userInfo: [NSLocalizedDescriptionKey: "The paired host is offline."]) }
                loaded = true
                return response
            },
            setViewed: { params in .object(["updated_ids": params["item_ids"] ?? .array([])]) },
            acknowledge: { params in .object(["updated_ids": params["item_ids"] ?? .array([])]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !(model.hasSuccessfulSnapshot && !model.loading), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if let selected, let item = model.page.items.first(where: { $0.id == selected }) { model.openDetail(item) }
        if clearAll {
            model.clearCurrentNeedsYou()
            while model.batchRunning, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }
        if failing {
            model.refreshAfterFrame()
            while model.error == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }

        let hosting = NSHostingView(rootView: ActivityRootView(model: model, workspaceOptions: { [("workspace", "star")] }, makeConversation: makeConversation, terminalSnapshot: terminalSnapshot)
            .frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        try await Task.sleep(for: .milliseconds(50))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["REMOTE_CODE_ACTIVITY_ARTIFACT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(name).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
        }
        return bitmap
    }

    /// Counts sampled pixels that differ from the flat page background: text and chrome that actually painted.
    private func inkSamples(in bitmap: NSBitmapImageRep, columns: ClosedRange<Double> = 0...1) -> Int {
        var count = 0
        let lower = Int(Double(bitmap.pixelsWide) * columns.lowerBound)
        let upper = Int(Double(bitmap.pixelsWide) * columns.upperBound)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(bitmap.pixelsHigh / 200, 1)) {
            for x in stride(from: lower, to: upper, by: max(bitmap.pixelsWide / 200, 1)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent > 1.2 { count += 1 }
            }
        }
        return count
    }

    func testWideWindowShowsListAndDetailSideBySideWithWorstCaseData() async throws {
        let bitmap = try await render(
            "wide-worst-case", items: worstCase, counts: ActivityWireCounts(running: 1, queued: 1, needs_you: 1_000_000, finished: 1_372),
            cursor: "next", size: CGSize(width: 1_560, height: 1_380), selecting: "run:long"
        )
        XCTAssertGreaterThan(inkSamples(in: bitmap, columns: 0...0.28), 150, "the list must paint rows on the left")
        XCTAssertGreaterThan(inkSamples(in: bitmap, columns: 0.4...1), 150,
                             "a wide window must show the selected result beside the list instead of an empty canvas")
    }

    func testChatItemOpensItsLiveConversationInTheDetailPaneWithoutAComposerOrDraftWrites() async throws {
        let directory = NSTemporaryDirectory() + "activity-conversation-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let thread = AgentThread(workspaceId: WorkspaceID(), title: "Star - Task 1", provider: .codex, model: "gpt-5")
        try context.threadRepo.upsert(thread)
        try context.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "Deploy the staging build and report back."))
        try context.messageRepo.append(AgentMessage(threadId: thread.id, role: .assistant, content: "Staging is deployed. All 214 checks passed and the smoke test is green."))
        let drafts = AgentThreadDraftRepository(db: context.db)
        try drafts.upsert(AgentThreadDraft(threadId: thread.id, providerInstanceId: "codex", text: "unsent reply"))

        var chat = item("run:chat", state: "completed", title: "Star - Task 1", summary: "Staging deployed")
        chat.thread_id = thread.id.value.uuidString
        var orphan = chat
        orphan.thread_id = UUID().uuidString
        var threadless = chat
        threadless.thread_id = nil
        XCTAssertNil(router.makeActivityConversation(orphan), "a deleted thread has no conversation; the summary stays")
        XCTAssertNil(router.makeActivityConversation(threadless), "an item without a thread is not a chat")

        let conversation = try XCTUnwrap(router.makeActivityConversation(chat))
        XCTAssertFalse(conversation.showsComposer, "a thread with no open workspace stays read-only")
        XCTAssertEqual(conversation.viewModel.embedding?.pinnedThreadId, thread.id, "the pane must show exactly the item's thread")
        XCTAssertEqual(conversation.viewModel.selectedThreadId, thread.id)
        conversation.close()
        XCTAssertEqual(try drafts.get(threadId: thread.id, providerInstanceId: "codex")?.text, "unsent reply",
                       "closing the Activity pane must never replace the draft the real chat holds")

        // A thread whose workspace is open replies from Activity exactly like its workspace tab.
        let workspace = try router.createWorkspace(name: "star", cwd: NSTemporaryDirectory())
        let live = AgentThread(workspaceId: workspace.id, title: "Live", provider: .codex, model: "gpt-5")
        try context.threadRepo.upsert(live)
        var liveItem = chat
        liveItem.thread_id = live.id.value.uuidString
        let tabCount = context.state.workspaces[workspace.id]?.layout.paneIDs().flatMap { context.state.workspaces[workspace.id]?.layout.find(paneID: $0)?.surfaces ?? [] }.count
        let liveConversation = try XCTUnwrap(router.makeActivityConversation(liveItem))
        XCTAssertTrue(liveConversation.showsComposer, "an open-workspace thread must get the composer")
        XCTAssertNil(liveConversation.viewModel.embedding, "same unpinned Agent App a workspace tab runs")
        XCTAssertEqual(liveConversation.viewModel.selectedThreadId, live.id)
        XCTAssertNotNil(liveConversation.viewModel.botPromptTransform, "bot threads must compile the bot prompt like a tab")
        XCTAssertNotNil(liveConversation.viewModel.providerLaunchConfig, "sends need the tab's provider launch wiring")
        XCTAssertEqual(context.state.workspaces[workspace.id]?.layout.paneIDs().flatMap { context.state.workspaces[workspace.id]?.layout.find(paneID: $0)?.surfaces ?? [] }.count, tabCount,
                       "Activity must not add a tab to the workspace")
        liveConversation.close()

        var made: [String] = []
        let bitmap = try await render(
            "chat-conversation", items: [chat], counts: ActivityWireCounts(finished: 1), size: CGSize(width: 1_300, height: 800),
            selecting: "run:chat", makeConversation: { item in made.append(item.id); return router.makeActivityConversation(item) }
        )
        XCTAssertEqual(made, ["run:chat"], "one conversation per selected thread, built once")
        XCTAssertGreaterThan(inkSamples(in: bitmap, columns: 0.4...1), 150, "the conversation must paint in the detail pane")
    }

    /// WHY: a terminal run used to show only "Open terminal" and an empty summary; the right pane
    /// must show the terminal's own output, like a chat item shows its conversation.
    func testTerminalItemShowsItsLiveOutputInTheDetailPane() async throws {
        var terminal = item("surface:term", kind: "operation", state: "running", title: "npm run dev", workspace: "star", provider: nil, origin: "Terminal")
        terminal.thread_id = nil
        terminal.surface_id = UUID().uuidString
        let green = "\u{001B}[32m"
        let reset = "\u{001B}[0m"
        let output = "$ npm run dev\n\(green)ready\(reset) - started server on http://localhost:3000\ncompiled /page in 412ms"
        let snapshot = TerminalTextSnapshot(
            text: "$ npm run dev\nready - started server on http://localhost:3000\ncompiled /page in 412ms", ansiText: output,
            complete: true, source: "test", timestamp: Date(), partialReason: nil, pendingBytes: 0, rows: 24, cols: 80
        )
        var reads = 0
        let bitmap = try await render(
            "terminal-output", items: [terminal], counts: ActivityWireCounts(running: 1), size: CGSize(width: 1_300, height: 800),
            selecting: "surface:term", terminalSnapshot: { _ in reads += 1; return snapshot }
        )
        XCTAssertGreaterThan(reads, 0, "the pane must read the live terminal it mirrors")
        XCTAssertGreaterThan(inkSamples(in: bitmap, columns: 0.4...1), 40, "the terminal output must paint in the detail pane")
        let gone = try await render(
            "terminal-gone", items: [terminal], counts: ActivityWireCounts(running: 1), size: CGSize(width: 1_300, height: 800),
            selecting: "surface:term"
        )
        XCTAssertGreaterThan(inkSamples(in: gone, columns: 0.4...1), 40, "a closed terminal keeps the summary with its actions")
    }

    func testNarrowWindowKeepsListReadableAtMinimumWidth() async throws {
        let bitmap = try await render(
            "narrow-worst-case", items: worstCase, counts: ActivityWireCounts(running: 1, queued: 1, needs_you: 149, finished: 1_372),
            size: CGSize(width: 540, height: 900)
        )
        XCTAssertGreaterThan(inkSamples(in: bitmap), 300, "the minimum window width must still render the list")
    }

    func testActionableRequestShowsItsResolutionRule() async throws {
        let reply = item("bot-attention:reply", kind: "request", state: "waiting_answer", title: "Reply to Bot",
                         summary: BotAttentionItemKind.question.resolutionHint, needsAction: true, origin: "Bot conversation: Elephant - Task")
        XCTAssertEqual(reply.attentionInstruction, BotAttentionItemKind.question.resolutionHint)
        XCTAssertNil(item("request:expired", kind: "request", state: "expired", title: "Request expired").attentionInstruction)
        let bitmap = try await render(
            "actionable-request", items: [reply], counts: ActivityWireCounts(needs_you: 1),
            size: CGSize(width: 1_100, height: 700), selecting: reply.id
        )
        XCTAssertGreaterThan(inkSamples(in: bitmap, columns: 0.4...1), 80, "the request must render its actions and resolution guidance")
    }

    func testEmptySingleFailureAndUndoStatesRenderTheirOwnChrome() async throws {
        let empty = try await render("empty", items: [], counts: .init(), size: CGSize(width: 1_100, height: 700))
        XCTAssertGreaterThan(inkSamples(in: empty), 40, "an empty Needs you must say so instead of rendering blank")

        let single = try await render(
            "single", items: [worstCase[1]], counts: ActivityWireCounts(needs_you: 1), size: CGSize(width: 1_100, height: 700), selecting: "run:one-letter"
        )
        XCTAssertGreaterThan(inkSamples(in: single), 60)

        let offline = try await render(
            "offline-after-load", items: worstCase, counts: ActivityWireCounts(needs_you: 14), size: CGSize(width: 1_100, height: 700), failing: true
        )
        let cleared = try await render(
            "cleared-with-undo", items: worstCase, counts: ActivityWireCounts(needs_you: 14), size: CGSize(width: 1_100, height: 700), clearAll: true
        )
        XCTAssertGreaterThan(inkSamples(in: offline), 300, "a failed update keeps the saved rows visible under the error")
        XCTAssertGreaterThan(inkSamples(in: cleared), 60, "after Clear all the status strip must offer Undo")
    }
}
