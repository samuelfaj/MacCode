import XCTest
@testable import AppShell
@testable import AgentRuntime
@testable import CoreModel
@testable import SocketServer
@testable import Surfaces
import Persistence

@MainActor
final class PersistenceRestoreTests: XCTestCase {
    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    /// Workspaces and tabs must survive a process restart even without a
    /// clean quit — i.e. the snapshot is written on mutation, not only on
    /// applicationWillTerminate.
    func test_workspacesAndTabs_persistAcrossRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString

        // ── Session 1: create a workspace + two surfaces, flush snapshot.
        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let ws = try router.createWorkspace(name: "PERSISTME", cwd: NSTemporaryDirectory())
            _ = try router.createSurface(workspace: ws.id, type: .terminal, paneID: nil, title: "t")
            _ = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "b")
            ctx.saveSnapshot() // immediate flush (debounced timer would also fire)
            defer { closeAndUnregisterAllSurfaces() }
        }

        // ── Session 2: fresh AppContext on the SAME app-support dir.
        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let names = ctx2.state.workspaces.values.map { $0.name }
        XCTAssertTrue(names.contains("PERSISTME"),
                      "workspace must persist across restart, got \(names)")
        let restored = ctx2.state.workspaces.values.first { $0.name == "PERSISTME" }
        let restoredWS = try XCTUnwrap(restored)
        guard case .pane(let pane) = restoredWS.layout else {
            return XCTFail("expected the restored workspace to keep its pane")
        }
        // Default Agent App tab (createWorkspace) + the two added tabs (terminal, browser) = 3.
        XCTAssertEqual(pane.surfaces.count, 3, "all tabs must persist")
        XCTAssertEqual(Set(pane.surfaces.map(\.type)), [.agentApp, .terminal, .browser])
        // And the window selection points at the restored workspace.
        XCTAssertEqual(ctx2.state.window.selectedWorkspaceID, restoredWS.id)
    }

    func test_applyMutation_schedulesSnapshotSave() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        try ctx.apply(.createWorkspace(name: "A", cwd: "/tmp", initial: nil))
        // Force the debounced write immediately and confirm it lands.
        ctx.saveSnapshot()
        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        XCTAssertTrue(ctx2.state.workspaces.values.contains { $0.name == "A" })
    }

    func test_saveAgentPlanWritesExactMarkdownInsideWorkspace() throws {
        let support = NSTemporaryDirectory() + "RC2PlanSave-" + UUID().uuidString
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2PlanWorkspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let ctx = try AppContext(channel: .debug, appSupportOverride: support)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let ws = try router.createWorkspace(name: "PLAN", cwd: workspace.path)
        let thread = try router.createAgentThread(workspace: ws.id, title: "plan", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium, serviceTier: .auto, modelSelection: nil)
        let markdown = "\n# Keep exact markdown\n\n1. Inspect\n"
        try ctx.proposedPlanRepo.upsert(threadId: thread.id, plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: markdown))

        let saved = try router.saveAgentPlan(thread: thread.id, planId: "plan-1", planMarkdown: nil, relativePath: nil)

        XCTAssertEqual(saved.relativePath, ".remotecode/plans/keep-exact-markdown.md")
        XCTAssertEqual(try String(contentsOfFile: saved.path), markdown,
                       "mobile host-save must write the exact proposed-plan markdown, not a trimmed or rendered copy")
        XCTAssertThrowsError(try router.saveAgentPlan(thread: thread.id, planId: "plan-1", planMarkdown: markdown, relativePath: "../plan.md"),
                             "mobile clients must not be able to save plan markdown outside the workspace")
    }

    func test_browserLastURL_persistsAcrossRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString
        let target = "https://example.com/docs?tab=api"

        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let ws = try router.createWorkspace(name: "WEB", cwd: NSTemporaryDirectory())
            let browser = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "browser")
            let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(browser.id) as? BrowserSurface)

            surface.publishNavigationChange(url: try XCTUnwrap(URL(string: target)), title: "API Docs")
            ctx.saveSnapshot()
        }

        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let restored = try XCTUnwrap(ctx2.state.workspaces.values.first { $0.name == "WEB" })
        guard case .pane(let pane) = restored.layout else {
            return XCTFail("expected browser workspace to restore as pane")
        }
        let browser = try XCTUnwrap(pane.surfaces.first { $0.type == .browser })
        XCTAssertEqual(browser.metadata["url"], target,
                       "browser tabs must reopen on the last URL after RemoteCode restarts")
        XCTAssertEqual(browser.title, "API Docs",
                       "browser tab title must persist with the last visited page")
    }

    func test_filesReuseOneGlobalTabAndRestoreLegacyPathsInsideIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-unified-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); closeAndUnregisterAllSurfaces() }
        try "let first = 1".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "let second = 2".write(to: root.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "FILES", cwd: root.path)
        let a = try router.filesOpenTab(workspace: workspace.id, sourceSurface: nil, paneID: nil, path: "a.swift")
        let b = try router.filesOpenTab(workspace: workspace.id, sourceSurface: a.id, paneID: nil, path: "b.swift")
        let generic = try router.createSurface(workspace: workspace.id, type: .files, paneID: nil, title: "Files")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.id, generic.id)
        XCTAssertEqual(b.title, "Files")
        // Seed a descriptor from the older one-global-tab-per-file format.
        let legacy = SurfaceDescriptor(type: .files, title: "b.swift", metadata: ["selected_path": "b.swift"])
        let initialPane = try XCTUnwrap(ctx.state.workspaces[workspace.id]?.layout.paneIDs().first)
        try ctx.apply(.splitPane(workspace.id, paneID: initialPane, direction: .right, newSurface: legacy))
        try ctx.apply(.focusSurface(workspace.id, legacy.id))
        closeAndUnregisterAllSurfaces()
        router.reinstantiateRestoredSurfaces()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let restored = try XCTUnwrap(ctx.state.workspaces[workspace.id])
        let panes = restored.layout.paneIDs().compactMap { restored.layout.find(paneID: $0) }
        let files = panes.flatMap(\.surfaces).filter { $0.type == .files }
        let pane = try XCTUnwrap(panes.first { $0.surfaces.contains(where: { $0.id == legacy.id }) })
        XCTAssertEqual(files.count, 1, "legacy global tabs must become internal file tabs")
        let descriptor = try XCTUnwrap(files.first)
        XCTAssertEqual(descriptor.id, legacy.id, "the selected Files surface must keep its identity on restore")
        XCTAssertNotNil(SurfaceRegistry.shared.surface(descriptor.id), "restored tabs must have a mounted runtime")
        let state = try router.filesStateGet(surface: descriptor.id).objectValue
        XCTAssertEqual(Set(state?["open_tabs"]?.arrayValue?.compactMap(\.stringValue) ?? []), ["a.swift", "b.swift"])
        let split = try router.splitPane(workspace: workspace.id, paneID: pane.id, direction: .right, surfaceType: .files, title: nil)
        XCTAssertEqual(split.id, descriptor.id, "Split must move the unique Files surface")
        let layout = try XCTUnwrap(ctx.state.workspaces[workspace.id]?.layout)
        let left = try XCTUnwrap(layout.paneIDs().first { layout.find(paneID: $0)?.surfaces.contains(where: { $0.type == .agentApp }) == true })
        let openedFromOtherPane = try router.filesOpenTab(workspace: workspace.id, sourceSurface: nil, paneID: left, path: "a.swift")
        XCTAssertEqual(openedFromOtherPane.id, descriptor.id)
        let allFiles = layout.paneIDs().flatMap { layout.find(paneID: $0)?.surfaces ?? [] }.filter { $0.type == .files }
        XCTAssertEqual(allFiles.count, 1, "Files is unique across the entire workspace")
        try router.closeSurface(workspace: workspace.id, surface: descriptor.id)
        let fresh = try router.filesOpenTab(workspace: workspace.id, sourceSurface: nil, paneID: nil, path: "a.swift")
        let reopened = try XCTUnwrap(try router.reopenClosedSurface(workspace: workspace.id))
        XCTAssertEqual(reopened.id, fresh.id, "reopening must not duplicate an existing Files surface")
    }

    func test_terminalHistoryKeepsRestoredSurfaceIDAcrossRelaunch() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString
        let marker = "remote-code-update-history-marker\n"
        var terminalID: SurfaceID!

        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let ws = try router.createWorkspace(name: "UPDATE", cwd: NSTemporaryDirectory())
            let terminal = try router.createSurface(workspace: ws.id, type: .terminal, paneID: nil, title: "update-history-terminal")
            terminalID = terminal.id
            try ctx.terminalOutputRepo.append(surfaceID: terminal.id.value.uuidString, workspaceID: ws.id.value.uuidString, chunkIndex: 1, data: Data(marker.utf8))
            ctx.saveSnapshot()
            defer { closeAndUnregisterAllSurfaces() }
        }

        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let router2 = AppCommandRouter(context: ctx2)
        ctx2.router = router2
        router2.reinstantiateRestoredSurfaces()
        defer { closeAndUnregisterAllSurfaces() }

        let restored = try XCTUnwrap(ctx2.state.workspaces.values.first { $0.name == "UPDATE" })
        guard case .pane(let pane) = restored.layout else {
            return XCTFail("expected restored workspace to keep its terminal pane")
        }
        let restoredTerminal = try XCTUnwrap(pane.surfaces.first { $0.id == terminalID })
        XCTAssertEqual(restoredTerminal.id, terminalID,
                       "terminal restore must keep the persisted surface id because scrollback/history is keyed by surface id")
        let history = try ctx2.terminalOutputRepo.readWindow(surfaceID: restoredTerminal.id.value.uuidString)
        XCTAssertTrue(history.text.contains(marker),
                      "terminal scrollback must still be readable after a Sparkle update/relaunch instead of reopening as a clean terminal")
    }

    func test_providerCallbackState_persistsAndMarksOpenCallbacksStaleOnRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2Callbacks-" + UUID().uuidString
        let threadId: AgentThreadID
        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let thread = AgentThread(title: "callback", provider: .codex, model: "gpt-5.5")
            threadId = thread.id
            try ctx.threadRepo.upsert(thread)
            let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-5.5")
            try ctx.runRepo.upsert(run)

            ctx.coordinator.onAssistantEvent?(.requestOpened(AssistantPendingRequest(
                id: "approval-1",
                turnId: "turn-1",
                kind: .commandExecution,
                title: "Run command",
                detail: "swift test",
                createdAtMs: 1_000
            )), thread.id, run.id)
            ctx.coordinator.onAssistantEvent?(.userInputRequested(AssistantUserInputRequest(
                id: "question-1",
                turnId: "turn-1",
                prompt: "Continue?",
                options: ["Plan", "Run"],
                createdAtMs: 2_000
            )), thread.id, run.id)
            ctx.coordinator.onAssistantEvent?(.requestResolved(requestId: "approval-1", state: .approved), thread.id, run.id)
        }

        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let router2 = AppCommandRouter(context: ctx2)
        let approval = try XCTUnwrap(try ctx2.providerPendingCallbackRepo.get(threadId: threadId, requestId: "approval-1", kind: .approval))
        let question = try XCTUnwrap(try ctx2.providerPendingCallbackRepo.get(threadId: threadId, requestId: "question-1", kind: .userInput))
        let visible = try router2.listAgentPendingCallbacks(thread: threadId)

        XCTAssertEqual(approval.state, .approved,
                       "resolved provider approvals must not be resurrected when the app restarts")
        XCTAssertEqual(question.state, .stale,
                       "unresolved provider questions must become explicitly stale after restart instead of trapping the Agent App in dead callback UI")
        XCTAssertTrue(question.staleReason?.contains("Provider callback state does not survive app restarts") == true)
        XCTAssertEqual(visible.requests.map(\.id), [],
                       "host callback reload must hide resolved approvals after restart")
        XCTAssertEqual(visible.userInputs.first?.id, "question-1",
                       "host callback reload must expose stale unanswered provider questions for macOS/iOS recovery")
        XCTAssertEqual(visible.userInputs.first?.state, .stale)
    }

    /// The snapshot below is what the paired device hydrates. A pending callback
    /// whose stored payload no longer decodes must stay in it — the run is still
    /// waiting on the answer, and "payload unreadable" is not "no request".
    func test_pendingCallbacksWithUnreadablePayloadStayVisibleToThePairedDevice() async throws {
        let dir = NSTemporaryDirectory() + "RC2CallbackUnreadable-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        let thread = AgentThread(title: "callback", provider: .codex, model: "gpt-5.5")
        try ctx.threadRepo.upsert(thread)
        try ctx.providerPendingCallbackRepo.record(threadId: thread.id, request: AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1_000
        ))
        try ctx.providerPendingCallbackRepo.record(threadId: thread.id, request: AssistantPendingRequest(
            id: "approval-2",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1_500
        ))
        try ctx.providerPendingCallbackRepo.record(threadId: thread.id, userInput: AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Continue?",
            options: ["Plan", "Run"],
            createdAtMs: 2_000
        ))
        // "{}" is exactly what the row mapper yields for a payload that never
        // landed (`Repositories.row` falls back to "{}"); the truncated JSON is a
        // torn write. Neither decodes.
        try ctx.db.execute("UPDATE provider_pending_callbacks SET payload_json = '{}' WHERE request_id = 'approval-1';")
        try ctx.db.execute("UPDATE provider_pending_callbacks SET payload_json = '{\"id\": \"question-1\"' WHERE request_id = 'question-1';")
        let corrupted = try XCTUnwrap(try ctx.providerPendingCallbackRepo.get(
            threadId: thread.id,
            requestId: "approval-1",
            kind: .approval
        ))
        XCTAssertEqual(corrupted.payloadJSON, "{}", "fixture must actually corrupt the stored payload")

        let hydrated = try await router.listAgentPendingCallbacksOffMain(thread: thread.id)
        XCTAssertEqual(hydrated.requests.map(\.id), ["approval-1", "approval-2"],
                       "an unreadable payload must not erase a pending approval from the paired device's hydrate")
        XCTAssertEqual(hydrated.userInputs.map(\.id), ["question-1"],
                       "an unreadable payload must not erase a pending question from the paired device's hydrate")
        XCTAssertEqual(hydrated.requests.first?.state, .pending)
        XCTAssertEqual(hydrated.requests.first?.createdAtMs, 1_000,
                       "the degraded entry keeps the stored request identity and timing")
        XCTAssertTrue(hydrated.requests.first?.detail?.contains("could not be read") == true,
                      "the degraded entry must say the payload could not be read instead of inventing provider text")
        XCTAssertEqual(hydrated.requests.last?.title, "Run command",
                       "a readable payload still decodes exactly as before")
        XCTAssertEqual(hydrated.requests.last?.detail, "swift test",
                       "a readable payload still decodes exactly as before")

        // The host (MainActor) path must agree with the off-main gateway.
        let host = try router.listAgentPendingCallbacks(thread: thread.id)
        XCTAssertEqual(host.requests.map(\.id), ["approval-1", "approval-2"])
        XCTAssertEqual(host.userInputs.map(\.id), ["question-1"])
        XCTAssertEqual(host.userInputs.first?.prompt, "Input requested (stored payload could not be read)")
    }

    func test_failedProviderCallbackResponseMarksStoredCallbackStale() async throws {
        let dir = NSTemporaryDirectory() + "RC2CallbackFailure-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        let thread = AgentThread(title: "callback", provider: .codex, model: "gpt-5.5")
        try ctx.threadRepo.upsert(thread)
        try ctx.providerPendingCallbackRepo.record(threadId: thread.id, request: AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1
        ))
        try ctx.providerPendingCallbackRepo.record(threadId: thread.id, userInput: AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Continue?",
            options: ["Plan", "Run"],
            createdAtMs: 2
        ))

        do {
            try await router.respondAgentRequest(thread: thread.id, requestId: "approval-1", response: .approve)
            XCTFail("respondAgentRequest must throw when the provider session is gone")
        } catch {}
        do {
            try await router.respondAgentUserInput(thread: thread.id, requestId: "question-1", text: "Run")
            XCTFail("respondAgentUserInput must throw when the provider session is gone")
        } catch {}

        let approval = try XCTUnwrap(try ctx.providerPendingCallbackRepo.get(threadId: thread.id, requestId: "approval-1", kind: .approval))
        let question = try XCTUnwrap(try ctx.providerPendingCallbackRepo.get(threadId: thread.id, requestId: "question-1", kind: .userInput))
        let visible = try router.listAgentPendingCallbacks(thread: thread.id)
        XCTAssertEqual(approval.state, .stale,
                       "a failed provider approval response must not remain pending forever after the provider session is gone")
        XCTAssertEqual(question.state, .stale,
                       "a failed provider question response must not remain pending forever after the provider session is gone")
        XCTAssertTrue(visible.requests.first?.detail?.contains("Provider approval response failed") == true)
        XCTAssertEqual(visible.userInputs.first?.state, .stale)
    }

    func test_approveForSessionFromRemoteClientPromotesThreadToFullAccessAndMirrorsEvent() async throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let adapter = ApprovalCaptureAdapter(provider: .codex)
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        var thread = AgentThread(workspaceId: nil, title: "approval", provider: .codex, model: "gpt-5.5")
        thread.permissionMode = .supervised
        try ctx.threadRepo.upsert(thread)
        var mirroredEvents: [EventBus.Event] = []
        let lastSeq = EventBus.shared.snapshot().lastSeq
        let token = EventBus.shared.subscribe(since: lastSeq) { event in
            if event.kind == "agent.thread.updated" { mirroredEvents.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        try await router.respondAgentRequest(thread: thread.id, requestId: "approval-1", response: .approveForSession)

        XCTAssertEqual(adapter.lastRequestResponse?.response, .approveForSession,
                       "the iOS RPC path must still send the session-scoped approval to the live provider adapter")
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.permissionMode, .fullAccess,
                       "Approve Session from iOS must persist Full Access on the host thread")
        XCTAssertTrue(mirroredEvents.contains {
            $0.payload.objectValue?["thread_id"] == .string(thread.id.value.uuidString) &&
            $0.payload.objectValue?["permission_mode"] == .string("full_access")
        }, "Approve Session from iOS must emit a thread update so connected devices render Full Access")
    }

    func test_remoteUserInputResponseResolvesStoredCallbackAndMirrorsEvent() async throws {
        let dir = NSTemporaryDirectory() + "RC2UserInput-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let adapter = ApprovalCaptureAdapter(provider: .codex)
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        let thread = AgentThread(title: "callback", provider: .codex, model: "gpt-5.5")
        try ctx.threadRepo.upsert(thread)
        try ctx.providerPendingCallbackRepo.record(threadId: thread.id, userInput: AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Continue?",
            options: ["Plan", "Run"],
            createdAtMs: 2
        ))

        var mirroredEvents: [EventBus.Event] = []
        let lastSeq = EventBus.shared.snapshot().lastSeq
        let token = EventBus.shared.subscribe(since: lastSeq) { event in
            if event.kind == "agent.user_input.resolved" { mirroredEvents.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        try await router.respondAgentUserInput(thread: thread.id, requestId: "question-1", text: "Run")

        XCTAssertEqual(adapter.lastUserInputResponse?.text, "Run",
                       "the iOS RPC path must still send the answer to the live provider adapter")
        XCTAssertEqual(try ctx.providerPendingCallbackRepo.get(threadId: thread.id, requestId: "question-1", kind: .userInput)?.state, .resolved,
                       "answering from a remote client must resolve the stored callback so reloads do not resurrect the card")
        XCTAssertEqual(try router.listAgentPendingCallbacks(thread: thread.id).userInputs, [],
                       "resolved provider questions must disappear from macOS and iOS callback reloads")
        XCTAssertTrue(mirroredEvents.contains {
            $0.payload.objectValue?["thread_id"] == .string(thread.id.value.uuidString) &&
            $0.payload.objectValue?["request_id"] == .string("question-1") &&
            $0.payload.objectValue?["answer"] == .string("Run")
        }, "answering from iOS must emit a resolved event so all open Agent App mirrors clear the card")
    }
}

private final class ApprovalCaptureAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var _lastRequestResponse: (threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse)?
    private var _lastUserInputResponse: (threadId: AgentThreadID, requestId: String, text: String)?

    var lastRequestResponse: (threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse)? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestResponse
    }

    var lastUserInputResponse: (threadId: AgentThreadID, requestId: String, text: String)? {
        lock.lock(); defer { lock.unlock() }
        return _lastUserInputResponse
    }

    init(provider: AgentProvider) {
        self.provider = provider
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        lock.lock()
        _lastRequestResponse = (threadId, requestId, response)
        lock.unlock()
    }
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        lock.lock()
        _lastUserInputResponse = (threadId, requestId, text)
        lock.unlock()
    }
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { true }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}
