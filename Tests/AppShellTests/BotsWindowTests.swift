import Darwin
import XCTest
import SwiftUI
import CoreModel
@testable import AgentRuntime
@testable import AppShell
@testable import Persistence
import SocketServer
@testable import Surfaces

@MainActor
final class BotsWindowTests: XCTestCase {
    func test_workspaceBusyMetadataClearsWithEmptyString_becauseIOSRemovesKeyOnEmpty() {
        // Terminal busy transitions reach iOS via workspace.updated; iOS
        // (MirrorEventReducer .workspaceUpdated) removes a key on "".
        XCTAssertEqual(AppCommandRouter.workspaceBusyMetadata(true), ["busy": .string("true")])
        XCTAssertEqual(AppCommandRouter.workspaceBusyMetadata(false), ["busy": .string("")])
        guard case .object(let payload) = AppCommandRouter.workspaceUpdatedPayload(
            id: WorkspaceID(UUID()), metadata: AppCommandRouter.workspaceBusyMetadata(false)
        ) else { return XCTFail("payload must be an object") }
        XCTAssertEqual(payload["metadata"], .object(["busy": .string("")]))
    }

    @MainActor
    func test_clientSurfaceDescriptorInjectsBusyForLiveNonAgentSurfaces_butNeverAgentApp() {
        final class BusyStub: Surface {
            let descriptor: SurfaceDescriptor
            let view = NSView()
            var isBusy: Bool { true }
            init(_ descriptor: SurfaceDescriptor) { self.descriptor = descriptor }
            func focus() {}
            func unfocus() {}
            func close() {}
            func sendText(_ text: String) {}
            func readText() -> String { "" }
            func snapshot() -> [String: String] { [:] }
        }
        let types: [SurfaceType] = [.terminal, .ssh, .browser, .rightSidebarTool, .agentApp]
        let descriptors = types.map { SurfaceDescriptor(type: $0, title: "t") }
        let stubs = descriptors.map(BusyStub.init)
        stubs.forEach { SurfaceRegistry.shared.register($0) }
        defer { descriptors.forEach { SurfaceRegistry.shared.unregister($0.id) } }

        for descriptor in descriptors {
            let client = AppCommandRouter.clientSurfaceDescriptor(descriptor)
            if descriptor.type == .agentApp {
                XCTAssertEqual(client, descriptor, "agent runs already list as threads")
            } else {
                XCTAssertEqual(client.metadata["busy"], "true", "\(descriptor.type) busy must reach iOS")
            }
        }
        let idle = SurfaceDescriptor(type: .browser, title: "idle")
        XCTAssertEqual(AppCommandRouter.clientSurfaceDescriptor(idle), idle, "unregistered surface stays unchanged")
    }

    func test_surfaceBusyPayloadCarriesSurfaceIDAndClearsWithEmptyString_becauseIOSListsBusyTerminals() {
        let ws = WorkspaceID(UUID())
        let sid = SurfaceID(UUID())
        XCTAssertEqual(
            AppCommandRouter.surfaceBusyPayload(workspace: ws, surface: sid, busy: true),
            .object([
                "workspace_id": .string(ws.value.uuidString),
                "id": .string(sid.value.uuidString),
                "surface_id": .string(sid.value.uuidString),
                "metadata": .object(["busy": .string("true")])
            ])
        )
        guard case .object(let idle) = AppCommandRouter.surfaceBusyPayload(workspace: ws, surface: sid, busy: false)
        else { return XCTFail("payload must be an object") }
        XCTAssertEqual(idle["metadata"], .object(["busy": .string("")]))
    }

    func test_supervisedRunPromptKeepsDistillSlashRaw_becausePairedDeviceSendsMustReachDistillCommands() {
        // iOS bot sends run startSupervisedRun, not the embedded desk; the brain
        // wrap would bury `/goal status` so Distill would treat it as a goal objective.
        XCTAssertEqual(
            BotsViewModel.supervisedRunPrompt(userText: "  /goal status", compiledPayload: "BRAIN\nUser request:\n/goal status", provider: .distill),
            "  /goal status"
        )
        XCTAssertEqual(
            BotsViewModel.supervisedRunPrompt(userText: "hello", compiledPayload: "BRAIN", provider: .distill),
            "BRAIN"
        )
        XCTAssertEqual(
            BotsViewModel.supervisedRunPrompt(userText: "/goal x", compiledPayload: "BRAIN", provider: .codex),
            "BRAIN"
        )
    }

    func test_botScheduleLegacyDistillInstanceResolvesModelsFromDistillACPSnapshot() {
        let snapshot = AgentProviderSnapshot(
            id: "distill-acp", provider: .distill, driverKind: .distillACP,
            displayName: "Distill", accentColor: "", continuationGroup: "distill",
            interactionModes: [.default], permissionModes: nil, enabled: true, installed: true,
            status: .available, models: [], slashCommands: [])
        XCTAssertEqual(
            BotScheduleSpecEditor.models(providers: [snapshot], provider: .distill, instanceID: "distill"),
            snapshot.models,
            "legacy bot schedules must resolve their provider's active instance instead of losing its model list")
    }

    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "rc-bots-window-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "bots.inspectorTab")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
        UserDefaults.standard.removeObject(forKey: "bots.screen")
        UserDefaults.standard.removeObject(forKey: "bots.studioTab")
        UserDefaults.standard.removeObject(forKey: "bots.deskSidePane")
        UserDefaults.standard.removeObject(forKey: "bots.deskSidePaneWidth")
        UserDefaults.standard.removeObject(forKey: "bots.showHidden")
        UserDefaults.standard.removeObject(forKey: "bots.brainPane")
        UserDefaults.standard.removeObject(forKey: "bots.queuedFollowUps")
        UserDefaults.standard.removeObject(forKey: "bots.composerDrafts")
        UserDefaults.standard.removeObject(forKey: "bots.inspectorDrafts")
        UserDefaults.standard.removeObject(forKey: "bots.studioDraft")
        UserDefaults.standard.removeObject(forKey: "bots.searchText")
        UserDefaults.standard.removeObject(forKey: "bots.deskRouting")
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        UserDefaults.standard.removeObject(forKey: "bots.studioFilesLocations")
        UserDefaults.standard.removeObject(forKey: "bots.unpublishedNewBotIDs")
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRail")
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRailWidth")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "bots.studioFilesLocations")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        if let directory {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directory = nil
    }

    func test_botDeskRoutingWithLegacyProviderRunsAsDistill_becauseSavedBotsMustNeverStartOtherProviders() throws {
        AgentProvider.selectableForTesting = nil
        defer { AgentProvider.selectableForTesting = AgentProvider.allCases }
        let legacy = BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus", routingMode: .auto)
        XCTAssertEqual(legacy.provider, .distill)
        XCTAssertEqual(legacy.providerInstanceID, "distill")
        XCTAssertEqual(legacy.model, "")
        XCTAssertEqual(legacy.routingMode, .manual)
        XCTAssertEqual(BotDeskRouting().provider, .distill)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(BotDeskRouting())) as? [String: Any]
        )
        object["provider"] = "codex"
        object["providerInstanceID"] = "codex-cli"
        object["model"] = "gpt-5.6-sol"
        let restored = try JSONDecoder().decode(
            BotDeskRouting.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(restored.provider, .distill)
        XCTAssertEqual(restored.model, "")
    }

    func test_deskSendAdmitsAndClearsAttachments_becauseAnexosMustReachTheTurn() async throws {
        // WHY: Desk must stage, preview, remove, and send files through the
        // real bot send path — not a decorative chip list. sendAgentMessage
        // only accepts blobs already in the managed agent-attachments store.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        let file = (directory as NSString).appendingPathComponent("brief.pdf")
        FileManager.default.createFile(atPath: file, contents: Data("hi".utf8))
        vm.addAttachments([file])
        XCTAssertEqual(vm.attachments.map(\.displayName), ["brief.pdf"])
        let staged = try XCTUnwrap(vm.attachments.first)
        XCTAssertNotEqual(staged.path, file, "raw user paths must be copied into the managed store")
        XCTAssertNotNil(staged.id)
        XCTAssertNotNil(staged.sha256)
        let store = AgentAttachmentStore(
            root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
        )
        XCTAssertEqual(try store.validatedForRetry(staged), staged)

        vm.removeAttachment(staged)
        XCTAssertTrue(vm.attachments.isEmpty)
        vm.addAttachments([file])
        vm.composerText = ""
        XCTAssertTrue(vm.deskSendEnabled)

        let exp = expectation(description: "sendAgentMessage resolved attachments")
        var received: [AgentAttachment] = []
        router.sendAgentMessageResolvedAttachmentsProbeForTesting = { attachments in
            received = attachments
            exp.fulfill()
        }
        vm.send()
        XCTAssertTrue(vm.deskShowsLoading,
                      "Agent App shows Loading… the instant the user sends, before sendAgentMessage returns")
        XCTAssertTrue(vm.attachments.isEmpty, "send must consume staged files")
        XCTAssertEqual(vm.deskMessages.first?.text, "📎 brief.pdf")
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(received.count, 1, "Bots send must call sendAgentMessage with the staged file")
        let sent = try XCTUnwrap(received.first)
        XCTAssertEqual(try store.validatedForRetry(sent), sent)
        XCTAssertTrue(sent.path.hasPrefix(store.root.path + "/"))
        router.sendAgentMessageResolvedAttachmentsProbeForTesting = nil
    }

    func test_pairedBotSendResolvesOpaqueUploadAndDeliversAttachmentToAgentRun() async throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let bot = try vm.create(name: "Piper", title: "Scout")
        let botID = bot.id.value.uuidString.lowercased()
        let conversation = try await router.dispatchPairedBotRemote(
            method: "bot.conversation.create",
            params: [
                "client_request_id": .string("paired-attachment-conversation"),
                "bot_id": .string(botID),
                "title": .string("Uploaded file"),
            ]
        )
        let conversationID = try XCTUnwrap(
            conversation.objectValue?["readback"]?.objectValue?["conversation_id"]?.stringValue
        )
        let attachmentStore = AgentAttachmentStore(
            root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
        )
        let uploaded = try attachmentStore.stage(
            data: Data("remote bytes".utf8),
            displayName: "remote.txt",
            kind: .file,
            mimeType: "text/plain"
        )
        let reference = try XCTUnwrap(AgentAttachmentReference(uploaded))
        let staged = try await router.dispatchPairedBotRemote(
            method: "bot.attachment.stage",
            params: [
                "client_request_id": .string("paired-attachment-stage"),
                "bot_id": .string(botID),
                "conversation_id": .string(conversationID),
                "attachment_id": .string(reference.id),
                "filename": .string(reference.displayName),
                "kind": .string(reference.kind.rawValue),
                "mime_type": .string(reference.mimeType ?? "application/octet-stream"),
                "digest": .string(reference.sha256),
                "size": .number(Double(reference.sizeBytes)),
            ]
        )
        let grantID = try XCTUnwrap(staged.objectValue?["readback"]?.objectValue?["id"]?.stringValue)
        let delivered = expectation(description: "paired attachment reached agent run")
        var resolved: [AgentAttachment] = []
        router.sendAgentMessageResolvedAttachmentsProbeForTesting = { attachments in
            resolved = attachments
            delivered.fulfill()
        }
        let sent = try await router.dispatchPairedBotRemote(method: "bot.send", params: [
            "client_request_id": .string("paired-attachment-send"),
            "host_id": .string("paired-host"),
            "bot_id": .string(botID),
            "conversation_id": .string(conversationID),
            "text": .string("Read the upload"),
            "attachment_ids": .array([.string(grantID)]),
        ])
        XCTAssertNotEqual(sent.objectValue?["status"]?.stringValue, "failed")
        await fulfillment(of: [delivered], timeout: 3)
        let attachment = try XCTUnwrap(resolved.first)
        XCTAssertEqual(attachment.id, reference.id)
        XCTAssertEqual(attachment.sha256, reference.sha256)
        XCTAssertEqual(attachment.sizeBytes, reference.sizeBytes)
        XCTAssertTrue(attachment.path.hasPrefix(attachmentStore.root.path + "/"))
        router.sendAgentMessageResolvedAttachmentsProbeForTesting = nil
    }

    /// WHY: The iOS BotRemoteHostState fixture returns a conversation row as
    /// `readback.id`, while the real paired host authority returns its typed
    /// mutation readback as `readback.conversation_id`. Exercise the actual
    /// public HTTP RPC serialization seam so the fixture cannot redefine the
    /// host wire contract.
    func test_pairedBotConversationCreateHTTPSerializesCanonicalConversationIDReceipt() async throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let bot = try vm.create(name: "Schema Probe", title: "Receipt")
        let botID = bot.id.value.uuidString.lowercased()
        let requestID = "schema-probe-create"
        let dispatcher = JSONRPCDispatcher(router: router)
        let server = DirectHTTPServer(
            port: UInt16.random(in: 33_000...44_000),
            loopbackOnly: true,
            dispatcher: dispatcher,
            bootEpoch: 1
        )
        let request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "schema-probe-rpc",
            "method": "bot.conversation.create",
            "params": [
                "client_request_id": requestID,
                "bot_id": botID,
                "title": "Receipt",
            ],
        ])

        let responseData = await server.dispatchRPC(bodyData: request)
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let readback = try XCTUnwrap(result["readback"] as? [String: Any])
        let conversationID = try XCTUnwrap(readback["conversation_id"] as? String)
        XCTAssertEqual(Set(result.keys), ["request_id", "receipt_id", "status", "bot_id", "readback"])
        XCTAssertEqual(Set(readback.keys), ["conversation_id", "title"])
        XCTAssertNil(readback["id"])
        XCTAssertEqual(result["request_id"] as? String, requestID)
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertEqual(result["bot_id"] as? String, botID)

        let statusRequest = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "schema-probe-status",
            "method": "bot.receipt.status",
            "params": ["client_request_id": requestID],
        ])
        let statusData = await server.dispatchRPC(bodyData: statusRequest)
        let statusResponse = try XCTUnwrap(
            JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        )
        let statusResult = try XCTUnwrap(statusResponse["result"] as? [String: Any])
        XCTAssertEqual(statusResult as NSDictionary, result as NSDictionary)
        XCTAssertEqual(
            (statusResult["readback"] as? [String: Any])?["conversation_id"] as? String,
            conversationID
        )
    }

    func test_deskSendWithImageShowsLiteralImageMarker_becauseBotsMustMatchAgentApp() async throws {
        // WHY: a one-image Desk turn must paint `[Image #1]` through the same
        // displayUserLine Agent App uses — not a 📎 filename.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        let file = (directory as NSString).appendingPathComponent("shot.png")
        FileManager.default.createFile(atPath: file, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        vm.addAttachments([file])
        vm.composerText = "What is in this picture?"
        let exp = expectation(description: "sendAgentMessage resolved image")
        var received: [AgentAttachment] = []
        router.sendAgentMessageResolvedAttachmentsProbeForTesting = { attachments in
            received = attachments
            exp.fulfill()
        }
        XCTAssertTrue(vm.send())
        XCTAssertEqual(
            vm.deskMessages.first?.text,
            "What is in this picture?\n\n[Image #1]"
        )
        let two = (directory as NSString).appendingPathComponent("diagram.jpg")
        FileManager.default.createFile(atPath: two, contents: Data([0xFF, 0xD8, 0xFF]))
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.kind, .image)
        router.sendAgentMessageResolvedAttachmentsProbeForTesting = nil

        let human = AgentChatTranscriptChrome.displayUserLine(
            text: "Compare",
            attachments: [
                AgentAttachment(path: file, displayName: "shot.png", kind: .image),
                AgentAttachment(path: two, displayName: "diagram.jpg", kind: .image),
            ]
        )
        XCTAssertTrue(human.contains("[Image #1]"))
        XCTAssertTrue(human.contains("[Image #2]"))
    }

    func test_deskSendLeavesOriginalPromptWithoutTokenSaverKeys() async throws {
        // WHY: Token Saver was removed; a Bot turn must carry the original
        // provider input and no Distill admission.
        let context = try makeContext()
        context.reconcileManagedIntegration()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.grok, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [AgentModelDescriptor(id: "grok-4.6", label: "Grok 4.6", provider: .grok)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "grok"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok, model: "grok-4.6")
        vm.openDesk(bot)
        vm.deskRouting = BotDeskRouting(
            provider: .grok,
            providerInstanceID: "grok",
            model: "grok-4.6",
            routingMode: .manual
        )
        vm.composerText = "FAIL-OPEN-BOT-PROMPT"
        XCTAssertTrue(vm.send())
        let started = await waitUntil(timeout: 5) { !runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertTrue(request.prompt.contains("FAIL-OPEN-BOT-PROMPT"))
        XCTAssertNil(
            request.environment["RC_TOKEN_SAVER_DISTILL_HINT"],
            "a bot provider turn must not admit Distill"
        )
        XCTAssertNil(request.environment["RC_TOKEN_SAVER_POST_TOOL_USE"])
    }

    func test_deskSendPersistsHumanUserRowAndColdRestoreKeepsIt() async throws {
        // WHY: the provider gets the compiled Bot brain, but the transcript must
        // keep the teammate's own words. A real send() must persist the human
        // row under the run id first, keep it out of the canonical seed, and a
        // cold restore must show that human text, never the brain envelope.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.grok, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [AgentModelDescriptor(id: "grok-4.6", label: "Grok 4.6", provider: .grok)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "grok"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok, model: "grok-4.6")
        vm.openDesk(bot)
        vm.deskRouting = BotDeskRouting(
            provider: .grok,
            providerInstanceID: "grok",
            model: "grok-4.6",
            routingMode: .manual
        )
        let humanText = "Summarize the overnight build failures for the team."
        vm.composerText = humanText
        XCTAssertTrue(vm.send())
        let started = await waitUntil(timeout: 8) { !runner.requests.isEmpty }
        XCTAssertTrue(started, "Desk send must reach the provider runner")
        let request = try XCTUnwrap(runner.requests.first)
        let threadID = try XCTUnwrap(vm.selectedConversation?.linkedAgentThreadID)
        let persisted = try XCTUnwrap(context.threadRepo.get(id: threadID))
        XCTAssertNil(persisted.workspaceId, "bot threads must stay off Agent App workspace rails")
        XCTAssertTrue(
            request.prompt.contains("User request:"),
            "Desk still compiles the Bot brain around the user turn"
        )
        let currentUserId = request.runId.value.uuidString
        XCTAssertFalse(
            request.contextSnapshot?.items.contains { $0.messageId == currentUserId } ?? false,
            "canonical seed must exclude the current run-id user row even when Human != compiled prompt"
        )
        let conversationID = try XCTUnwrap(vm.selectedConversation?.id)
        let hydrated = await waitUntil(timeout: 5) {
            vm.selectDeskThread(conversationID)
            return vm.deskMessages.contains {
                $0.role == .user && $0.agentMessageID?.value == request.runId.value
            }
        }
        XCTAssertTrue(hydrated, "restore must show the persisted human row for this run")
        let user = try XCTUnwrap(vm.deskMessages.first { $0.role == .user })
        XCTAssertTrue(
            user.text.contains(humanText),
            "Desk must keep the teammate line, not the provider-bound envelope"
        )
        XCTAssertFalse(user.text.contains("User request:"))
        XCTAssertEqual(user.agentMessageID?.value, request.runId.value)

        let cold = BotsViewModel(context: context, router: router)
        cold.openDesk(bot)
        cold.selectDeskThread(conversationID)
        let restored = try XCTUnwrap(cold.deskMessages.first { $0.role == .user })
        XCTAssertEqual(restored.agentMessageID?.value, request.runId.value)
        XCTAssertTrue(
            restored.text.contains(humanText),
            "cold restore must keep the human text"
        )
        XCTAssertFalse(
            restored.text.contains("You are Piper"),
            "cold restore must not surface the compiled brain envelope"
        )
    }

    func test_deskRestoreRebuildsImageMarkersFromCompiledPayload() throws {
        // WHY: after persist, Desk rereads the compiled provider envelope.
        // Image markers must come back from the shared displayUserLine using
        // the stored attachments, not vanish into the brain preamble.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        let png = (directory as NSString).appendingPathComponent("shot.png")
        FileManager.default.createFile(atPath: png, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        let attachment = AgentAttachment(
            path: png,
            displayName: "shot.png",
            kind: .image,
            mimeType: "image/png"
        )
        let thread = AgentThread(title: "bot-desk", provider: .codex, model: "test")
        try context.threadRepo.upsert(thread)
        let conversation = BotConversation(
            botID: bot.id,
            title: "Look at this",
            linkedAgentThreadID: thread.id
        )
        try context.botStore.upsertConversation(conversation)
        let compiled = """
        You are Piper — Scout.

        User request:

        Look at this
        """
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: compiled,
            attachments: [attachment]
        ))
        vm.openDesk(bot)
        vm.selectDeskThread(conversation.id)
        let user = try XCTUnwrap(vm.deskMessages.first { $0.role == .user })
        XCTAssertTrue(user.text.contains("[Image #1]"), "restore must keep the literal image marker")
        XCTAssertTrue(user.text.contains("Look at this"))
        XCTAssertFalse(user.text.contains("You are Piper"))
        XCTAssertEqual(user.agentMessageID != nil, true)
    }

    func test_botParallelTasksKeepBothRunsAndOpenTheirExactSideConversation() async throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(provider: .distill,
                models: [AgentModelDescriptor(id: "main-model", label: "Grok 4.6", provider: .distill)],
                binaryPath: "/usr/bin/true", authenticated: true, id: "distill")
        ])
        let bots = BotsViewModel(context: context, router: router)
        router.botsViewModel = bots
        let bot = try bots.create(name: "Task Bot", title: "Parallel work", provider: .distill)
        let caller = try seedBotCaller(context: context, provider: .distill,
            model: "main-model", permissionMode: .fullAccess)
        let origin = BotConversation(botID: bot.id, title: "Original chat", linkedAgentThreadID: caller.thread.id)
        try context.botStore.upsertConversation(origin)
        try context.messageRepo.append(AgentMessage(threadId: caller.thread.id, role: .user,
            content: "Inspect webhooks and review logs independently."))
        let first = try await router.sendHostBot(botID: bot.id, text: "Inspect webhooks",
            conversationID: nil, callerThread: caller.thread.id, callerRun: caller.run.id)
        let second = try await router.sendHostBot(botID: bot.id, text: "Review logs",
            conversationID: nil, callerThread: caller.thread.id, callerRun: caller.run.id)
        let bothStarted = await waitUntil(timeout: 5) { runner.requests.count == 2 }
        XCTAssertTrue(bothStarted, "The same Bot must start the second task before its first task finishes")
        let links = try context.messageRepo.listRecent(threadId: caller.thread.id, limit: 20)
            .compactMap { BotParallelTask.parse($0.content) }
        XCTAssertEqual(links.count, 2)
        XCTAssertNotEqual(links[0].threadID, links[1].threadID)
        XCTAssertEqual(Set(links.map(\.runID)), Set(runner.requests.map(\.runId)))
        XCTAssertNotEqual(first.objectValue?["conversation_id"], second.objectValue?["conversation_id"])
        XCTAssertTrue(runner.requests.allSatisfy { $0.model == "main-model" && $0.permissionMode == .fullAccess })
        XCTAssertEqual(try context.botStore.conversation(id: origin.id)?.linkedAgentThreadID, caller.thread.id)

        let parent = AgentAppViewModel(workspaceID: BotsViewModel.botDeskWorkspaceID, cwd: directory,
            coordinator: context.coordinator, threadRepo: context.threadRepo, messageRepo: context.messageRepo,
            initialThreadId: caller.thread.id,
            embedding: AgentAppEmbedding(pinnedThreadId: caller.thread.id, pinnedThread: caller.thread))
        defer { parent.closeParallelTask(); parent.dispose() }
        router.configureBotTaskLinks(on: parent)
        parent.prompt = "Keep this draft"
        parent.openParallelTask(links[0])
        XCTAssertEqual(parent.selectedThreadId, caller.thread.id, "Opening a task must leave the original chat selected")
        XCTAssertEqual(parent.parallelTaskPreview?.selectedThreadId, links[0].threadID)
        XCTAssertEqual(parent.prompt, "Keep this draft")
        XCTAssertEqual(parent.parallelTaskPreview?.embedding?.ownsComposerDraft, false)
        let firstPreview = parent.parallelTaskPreview
        parent.openParallelTask(links[1])
        XCTAssertEqual(parent.parallelTaskPreview?.selectedThreadId, links[1].threadID)
        XCTAssertFalse(parent.parallelTaskPreview === firstPreview)
        parent.closeParallelTask(clearSelection: false)
        parent.restoreParallelTask()
        XCTAssertEqual(parent.parallelTaskPreview?.selectedThreadId, links[1].threadID,
            "Reopening the original chat must restore its chosen parallel conversation")
        XCTAssertThrowsError(try router.authorizedBotTask(links[0], source: AgentThreadID()),
            "A task link must never open from an unrelated conversation")
        let forged = BotParallelTask(botID: links[0].botID, conversationID: links[0].conversationID,
            threadID: links[1].threadID, runID: links[0].runID, title: links[0].title)
        XCTAssertThrowsError(try router.authorizedBotTask(forged, source: caller.thread.id))

        for request in runner.requests {
            XCTAssertTrue(runner.finish(runID: request.runId, status: .completed,
                reply: request.prompt.contains("Inspect webhooks") ? "Webhook inspection complete." : "Log review complete."))
        }
        let settled = await waitUntil(timeout: 5) {
            links.allSatisfy { (try? context.runRepo.status(of: $0.runID)) == .completed }
        }
        XCTAssertTrue(settled)
        let status = try await parent.parallelTaskStatus?(links[0], caller.thread.id)
        XCTAssertEqual(status, .completed, "The card must use its exact child run's terminal state")
        if let receipt = ProcessInfo.processInfo.environment["RC_BOT_TASK_FIXTURE_RECEIPT"] {
            try context.runRepo.upsert(AgentRun(id: caller.run.id, threadId: caller.thread.id,
                provider: .distill, model: "main-model", status: .completed))
            var restoredOrigin = origin
            restoredOrigin.updatedAt = Date()
            restoredOrigin.pinned = true
            try context.botStore.upsertConversation(restoredOrigin)
            try context.threadRepo.updateStatusPreservingUnread(id: caller.thread.id, status: .completed, at: Date())
            try context.settingsRepo.set("shell.botsSelected", "bots")
            let fixture = URL(fileURLWithPath: receipt).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            let backup = Process()
            backup.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            backup.arguments = [context.db.path, ".backup '\(fixture.appendingPathComponent("fixture.sqlite").path)'"]
            try backup.run()
            backup.waitUntilExit()
            XCTAssertEqual(backup.terminationStatus, 0)
            try "\(bot.id.value.uuidString.lowercased())\n\(caller.thread.id.value.uuidString)".write(
                toFile: receipt, atomically: true, encoding: .utf8)
        }
    }

    func test_botParallelTaskKeepsItsContextGrantAndRejectsRevocation() async throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(provider: .distill,
                models: [AgentModelDescriptor(id: "main-model", label: "Main", provider: .distill)],
                binaryPath: "/usr/bin/true", authenticated: true, id: "distill")
        ])
        let bots = BotsViewModel(context: context, router: router)
        router.botsViewModel = bots
        let bot = try bots.create(name: "Context Task Bot", title: "Scoped work", provider: .distill)
        let workspace = try router.createWorkspace(name: "Task workspace", cwd: directory)
        let scope = BotContext.workspace(workspace.id)
        let hostID = context.liveActivityHostIdentity.serverId
        let grant = try context.botStore.grantContext(hostID: hostID, botID: bot.id, context: scope,
            actions: [.read, .send, .delegate, .files, .configure], expectedRevision: nil)
        let made = try bots.makeContextualConversation(bot: bot, context: scope,
            route: BotDeskRouting(provider: .distill, model: "main-model", routingMode: .manual),
            snapshot: nil, title: "Source")
        let threadID = try XCTUnwrap(made.conversation.linkedAgentThreadID)
        var pinnedSource = try XCTUnwrap(context.threadRepo.get(id: threadID))
        pinnedSource.executionMode = .worktree
        pinnedSource.worktreePath = directory
        pinnedSource.baseBranch = "main"
        try context.threadRepo.upsert(pinnedSource)
        let run = AgentRun(threadId: threadID, provider: .distill, model: "main-model", status: .running)
        try context.runRepo.upsert(run)
        let result = try await router.sendHostBot(botID: bot.id, text: "Scoped task",
            conversationID: nil, callerThread: threadID, callerRun: run.id)
        let childID = AgentThreadID(try XCTUnwrap(result.objectValue?["thread_id"]?.stringValue.flatMap(UUID.init)))
        let childPin = try XCTUnwrap(context.botStore.conversationContextPin(linkedTo: childID))
        XCTAssertEqual(childPin.context, scope)
        XCTAssertEqual(childPin.policyRevision, grant.policyRevision,
            "A parallel task must never silently escape its source's pinned context")
        let child = try XCTUnwrap(context.threadRepo.get(id: childID))
        XCTAssertEqual(child.executionMode, .worktree)
        XCTAssertEqual(child.worktreePath, directory)
        XCTAssertEqual(child.baseBranch, "main")
        let links = try context.messageRepo.listRecent(threadId: threadID, limit: 20)
            .compactMap { BotParallelTask.parse($0.content) }
        let link = try XCTUnwrap(links.first)
        _ = try router.authorizedBotTask(link, source: threadID)
        let source = try XCTUnwrap(context.threadRepo.get(id: threadID))
        let parent = AgentAppViewModel(workspaceID: BotsViewModel.botDeskWorkspaceID, cwd: directory,
            coordinator: context.coordinator, threadRepo: context.threadRepo, messageRepo: context.messageRepo,
            initialThreadId: threadID,
            embedding: AgentAppEmbedding(pinnedThreadId: threadID, pinnedThread: source))
        defer { parent.closeParallelTask(); parent.dispose() }
        router.configureBotTaskLinks(on: parent)
        parent.openParallelTask(link)
        XCTAssertNotNil(parent.parallelTaskPreview)
        _ = try context.botStore.grantContext(hostID: hostID, botID: bot.id, context: scope,
            actions: [], expectedRevision: grant.policyRevision)
        XCTAssertThrowsError(try router.authorizedBotTask(link, source: threadID),
            "Revoking a context must also revoke the parallel conversation preview")
        await parent.monitorParallelTaskAccess()
        XCTAssertNil(parent.parallelTaskPreview, "An already-open preview must close when its read grant is revoked")
        XCTAssertTrue(parent.statusMessage.contains("access is unavailable"))
        let count = try context.botStore.listConversations(botID: bot.id).count
        do {
            _ = try await router.sendHostBot(botID: bot.id, text: "Denied task",
                conversationID: nil, callerThread: threadID, callerRun: run.id)
            XCTFail("A revoked source must not start a task through a general fallback")
        } catch { }
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, count)
        for thread in context.coordinator.activeThreadIdsSnapshot() { context.coordinator.stopRun(threadId: thread) }
    }

    func test_hostCatalogBotSendUsesTheFullDeskBrainPipeline() async throws {
        // WHY: a host MCP send must not bypass the Bot's soul/skills/VM routing
        // by forwarding the user's raw text as a generic Agent App prompt.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.grok, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [AgentModelDescriptor(id: "grok-4.6", label: "Grok 4.6", provider: .grok)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "grok"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let callerRun = AgentRunID()
        let created = try router.createHostBot(
            name: "Oliver",
            title: "Critical QA",
            description: "Test everything end to end.",
            handle: "oliver",
            soul: "Never accept an unproven claim.",
            callerRun: callerRun
        )
        let botID = BotID(try XCTUnwrap(created.objectValue?["id"]?.stringValue.flatMap(UUID.init)))
        let skillMarker = "HOST-CATALOG-QA-SKILL"
        _ = try router.createHostBotSkill(
            botID: botID,
            skillID: "critical-qa",
            body: "---\nname: critical-qa\n---\n\(skillMarker)\n",
            callerRun: callerRun,
            callerThread: AgentThreadID()
        )

        let userText = "Inspect every path in the VM."
        let caller = try seedBotCaller(
            context: context,
            provider: .grok,
            model: "grok-4.6",
            permissionMode: .fullAccess
        )
        let result = try await router.sendHostBot(
            botID: botID,
            text: userText,
            conversationID: nil,
            callerThread: caller.thread.id,
            callerRun: caller.run.id
        )
        XCTAssertEqual(result.objectValue?["enqueued"]?.boolValue, true)
        XCTAssertEqual(result.objectValue?["queued_follow_up"]?.boolValue, false)
        let started = await waitUntil(timeout: 5) { runner.requests.count == 1 }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.provider, .grok, "the Bot must inherit the authenticated caller provider")
        XCTAssertEqual(request.model, "grok-4.6")
        XCTAssertEqual(request.permissionMode, .fullAccess)
        XCTAssertTrue(request.prompt.contains(userText))
        XCTAssertTrue(request.prompt.contains(skillMarker))
        XCTAssertTrue(request.prompt.contains("Never accept an unproven claim."))
        XCTAssertNotEqual(request.prompt, userText, "host send must compile the Bot brain")
        XCTAssertEqual(
            result.objectValue?["run_id"]?.stringValue,
            request.runId.value.uuidString.lowercased()
        )
        XCTAssertTrue(runner.finish(runID: request.runId, status: .completed, reply: "verified"))
    }

    func test_hostCatalogFollowUpDrainsOnItsConversationWhileAnotherBotIsSelected() async throws {
        // WHY: an accepted host follow-up must not wait forever for the user to
        // revisit that Bot, and must never borrow the currently selected Desk.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let created = try router.createHostBot(
            name: "Oliver",
            title: "Critical QA",
            description: "",
            handle: "oliver-queue",
            soul: "Be exact.",
            callerRun: AgentRunID()
        )
        let botID = BotID(try XCTUnwrap(created.objectValue?["id"]?.stringValue.flatMap(UUID.init)))
        let other = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude, model: "opus")
        let caller = try seedBotCaller(
            context: context,
            provider: .claude,
            model: "opus",
            permissionMode: .fullAccess
        )

        let first = try await router.sendHostBot(
            botID: botID,
            text: "first host task",
            conversationID: nil,
            callerThread: caller.thread.id,
            callerRun: caller.run.id
        )
        let firstStarted = await waitUntil(timeout: 5) { runner.requests.count == 1 }
        XCTAssertTrue(firstStarted)
        let firstRequest = try XCTUnwrap(runner.requests.first)
        let conversationID = BotConversationID(
            try XCTUnwrap(first.objectValue?["conversation_id"]?.stringValue.flatMap(UUID.init))
        )
        vm.openDesk(other)
        let queued = try await router.sendHostBot(
            botID: botID,
            text: "second exact follow-up",
            conversationID: conversationID,
            callerThread: caller.thread.id,
            callerRun: caller.run.id
        )
        XCTAssertEqual(queued.objectValue?["queued_follow_up"]?.boolValue, true)
        XCTAssertEqual(runner.requests.count, 1)

        XCTAssertTrue(runner.finish(runID: firstRequest.runId, status: .completed, reply: "first done"))
        let drained = await waitUntil(timeout: 5) { runner.requests.count == 2 }
        XCTAssertTrue(drained)
        XCTAssertEqual(vm.selectedBotID, other.id)
        let second = try XCTUnwrap(runner.requests.last)
        XCTAssertTrue(second.prompt.contains("second exact follow-up"))
        XCTAssertTrue(runner.finish(runID: second.runId, status: .completed, reply: "second done"))
    }

    func test_hostCatalogFollowUpDoesNotDrainAfterMasterControlPlaneDisabled() async throws {
        // WHY: disabling master control plane before completion must preserve accepted work without starting it.
        directory = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]))
            .appendingPathComponent("QueuePolicy-\(UUID().uuidString)").path
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true", authenticated: true, id: "claude"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let created = try router.createHostBot(
            name: "Oliver", title: "Critical QA", description: "", handle: "oliver-revoke",
            soul: "Be exact.", callerRun: AgentRunID()
        )
        let botID = BotID(try XCTUnwrap(created.objectValue?["id"]?.stringValue.flatMap(UUID.init)))
        let other = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude, model: "opus")
        let caller = try seedBotCaller(context: context, provider: .claude, model: "opus", permissionMode: .fullAccess)
        let first = try await router.sendHostBot(botID: botID, text: "first host task", conversationID: nil,
                                                 callerThread: caller.thread.id, callerRun: caller.run.id)
        let firstStarted = await waitUntil(timeout: 5) { runner.requests.count == 1 }
        XCTAssertTrue(firstStarted)
        let firstRequest = try XCTUnwrap(runner.requests.first)
        let conversationID = BotConversationID(try XCTUnwrap(first.objectValue?["conversation_id"]?.stringValue.flatMap(UUID.init)))
        vm.openDesk(other)
        let accepted = try await router.sendHostBot(botID: botID, text: "second exact follow-up", conversationID: conversationID,
                                                    callerThread: caller.thread.id, callerRun: caller.run.id)
        XCTAssertEqual(accepted.objectValue?["queued_follow_up"]?.boolValue, true)
        let queuedBefore = vm.queuedFollowUpsForTesting(botID: botID)
        XCTAssertEqual(queuedBefore.map(\.text), ["second exact follow-up"])

        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = false }
        let queuedRowsBefore = try context.botStore.listQueuedFollowUps(botID: botID)
        let callerRunBefore = try XCTUnwrap(context.runRepo.get(id: caller.run.id))
        let conversation = try XCTUnwrap(context.botStore.conversation(id: conversationID))
        let botThreadID = try XCTUnwrap(conversation.linkedAgentThreadID)
        let botMessagesBefore = try context.messageRepo.list(threadId: botThreadID)
        let followThroughBefore = vm.followThroughApplyCountForTesting
        XCTAssertTrue(runner.finish(runID: firstRequest.runId, status: .completed, reply: "first done"))
        let followThroughSettled = await waitUntil(timeout: 5) { vm.followThroughApplyCountForTesting > followThroughBefore }
        XCTAssertTrue(followThroughSettled)
        XCTAssertEqual(runner.requests.count, 1)
        XCTAssertEqual(vm.queuedFollowUpsForTesting(botID: botID).map(\.id), queuedBefore.map(\.id))
        XCTAssertEqual(vm.queuedFollowUpsForTesting(botID: botID).map(\.text), ["second exact follow-up"])
        XCTAssertEqual(try context.botStore.listQueuedFollowUps(botID: botID), queuedRowsBefore)
        XCTAssertEqual(try context.runRepo.get(id: caller.run.id), callerRunBefore)
        XCTAssertEqual(
            try context.runRepo.listRecentFinished(limit: 50).filter { $0.threadId == botThreadID }.map(\.id),
            [firstRequest.runId]
        )
        XCTAssertEqual(
            try context.messageRepo.list(threadId: botThreadID).filter { $0.content.contains("second exact follow-up") },
            botMessagesBefore.filter { $0.content.contains("second exact follow-up") }
        )
        XCTAssertEqual(vm.selectedBotID, other.id)
        let botMessages = try context.messageRepo.list(threadId: botThreadID)
        XCTAssertEqual(botMessages.filter { $0.role == .user }.count, 1)
        XCTAssertFalse(botMessages.contains { $0.content.contains("second exact follow-up") && $0.role == .user })
    }

    func test_hostSendToAnotherBotCompilesThatBotsBrowserPage_becauseOneBotsPageMustNeverReachAnothersPrompt() async throws {
        // WHY: the run prompt names the last page the Bot's browser had open.
        // It was read from the Bot selected on the Mac, so a paired send to
        // Quinn while Piper was open told Quinn's model that Piper's page was
        // its own. A Bot is only ever given its own data.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let store = BotBrowserStore(appSupportDirectory: context.appSupportDirectory)
        try store.persistTarget(
            BotBrowserTarget(url: "https://piper.example/inbox", title: "Piper Inbox"),
            botID: piper.id
        )
        try store.persistTarget(
            BotBrowserTarget(url: "https://quinn.example/review", title: "Quinn Review"),
            botID: quinn.id
        )
        vm.openDesk(piper)
        XCTAssertEqual(
            vm.advertisedBrowser?.url,
            "https://piper.example/inbox",
            "fixture: Piper is the Bot open on the Mac, with its own page"
        )

        _ = try vm.enqueueHostMessage(
            botID: quinn.id,
            text: "What page do you have open?",
            conversationID: nil,
            routing: BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        )
        let started = await waitUntil(timeout: 5) { runner.requests.count == 1 }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertTrue(
            request.prompt.contains("Browser: Quinn Review (https://quinn.example/review)"),
            "the send to Quinn must compile Quinn's own page"
        )
        XCTAssertFalse(
            request.prompt.contains("piper.example"),
            "the page of the Bot open on the Mac must never reach another Bot's prompt"
        )
        XCTAssertEqual(vm.selectedBotID, piper.id, "a host send never changes the Mac selection")
        XCTAssertTrue(runner.finish(runID: request.runId, status: .completed, reply: "done"))
    }

    func test_hostSendAcknowledgementDoesNotReadTheBotsBrain_becauseThePhoneWaitsOnThatAcknowledgement() async throws {
        // WHY: `bot.send` is acknowledged on the main actor, before the
        // provider starts, and the phone shows the send as confirmed only then.
        // The memory files and the skill and routine rows are used later, in
        // the start task. Reading them inside the acknowledgement made every
        // paired send to a Bot that is not open on the Mac wait on disk and on
        // two SQLite reads it did not use. They must still reach the prompt,
        // also when that Bot is opened on the Mac between the acknowledgement
        // and the start: a desk that has not loaded yet is not the Bot's brain.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        try vm.botHome(for: quinn).writeFile(
            relativePath: BotHome.memoryName,
            contents: "- Quinn reviews on Fridays\n"
        )
        let routine = BotRoutineDefinition(
            botID: quinn.id,
            name: "Release scan",
            prompt: "Read the release notes before review",
            scheduleNote: "Daily"
        )
        try context.botStore.saveRoutine(routine)
        try context.botStore.setRoutineEnabled(id: routine.id, enabled: true)
        vm.openDesk(piper)

        let skillListsBefore = vm.skillListCountForTesting
        let routineListsBefore = vm.routineListCountForTesting
        let mainSyncsBefore = PerfSwitchMetrics.mainThreadSyncCountForTesting()
        _ = try vm.enqueueHostMessage(
            botID: quinn.id,
            text: "When do you review?",
            conversationID: nil,
            routing: BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        )
        let acknowledgementMainSyncs = PerfSwitchMetrics.mainThreadSyncCountForTesting() - mainSyncsBefore
        XCTAssertFalse(vm.lastSendUsedDestBrainForTesting, "fixture: Quinn is not the Bot open on the Mac")
        XCTAssertEqual(
            vm.skillListCountForTesting,
            skillListsBefore,
            "the acknowledgement must not list the Bot's skills"
        )
        XCTAssertEqual(
            vm.routineListCountForTesting,
            routineListsBefore,
            "the acknowledgement must not list the Bot's routines"
        )
        // Every wait in this window is a main-thread SQLite sync. The print is
        // the count to compare before and after on the same machine.
        XCTAssertLessThanOrEqual(
            acknowledgementMainSyncs,
            5,
            "the acknowledgement must not gain main-thread SQLite reads"
        )
        print("PERF bot.send acknowledgement unselectedBot mainThreadSQLiteSyncs=\(acknowledgementMainSyncs)")

        // The user opens Quinn before the start task has run. The cache-first
        // desk shows no routines until its freshness pass.
        vm.enableNavigationFirstFrameDeferral()
        vm.openDesk(quinn)
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertTrue(vm.routines.isEmpty, "fixture: Quinn's desk has not loaded its routines yet")

        let started = await waitUntil(timeout: 5) { runner.requests.count == 1 }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertTrue(
            request.prompt.contains("Quinn reviews on Fridays"),
            "the Bot's memory must still reach the prompt"
        )
        XCTAssertTrue(
            request.prompt.contains("Read the release notes before review"),
            "the Bot's routines must come from the store, not from a desk that has not loaded"
        )
        XCTAssertTrue(runner.finish(runID: request.runId, status: .completed, reply: "done"))
    }

    func test_deskSendDoesNotRelistProviders_becauseAgentAppDoesNotProbeCatalogOnSend() async throws {
        // WHY: Agent App send uses the dest catalog already in memory.
        // Desk send used to listAgentProviderSnapshots inside preflight
        // (Grok ACP + Anthropic + Codex) before startRun — that is the
        // wait behind Loading….
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        context.coordinator.replaceProvider(
            .claude,
            runner: FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: "ok"))
        )
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "claude"
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.claude)
        let exp = expectation(description: "send preflight resolved from dest cache")
        router.sendAgentMessageAfterPreflightProbeForTesting = { exp.fulfill() }
        XCTAssertTrue(vm.send("oi"))
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertFalse(
            router.preflightListedProviderSnapshotsForTesting,
            "send preflight must use the dest catalog, not rediscover models"
        )
        router.sendAgentMessageAfterPreflightProbeForTesting = nil
    }

    func test_deskSendLoadingSurvivesRosterReopen_becauseSendMustStayAcknowledged() throws {
        // WHY: openDesk reloads the selected bot. That used to clear
        // deskSendInFlight, so Loading… vanished while sendAgentMessage was
        // still starting — dead time on the same click that should keep status.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("keep loading visible"))
        XCTAssertTrue(vm.deskShowsLoading, "send must acknowledge before the provider run exists")
        vm.openDesk(piper)
        XCTAssertTrue(
            vm.deskShowsLoading,
            "re-opening the sending Desk must not drop Loading… mid-start"
        )
        vm.openDesk(quinn)
        XCTAssertFalse(
            vm.deskShowsLoading,
            "Quinn's Desk must not inherit Piper's in-flight Loading…"
        )
        vm.openDesk(piper)
        XCTAssertTrue(
            vm.deskShowsLoading,
            "returning to Piper must restore Loading… until that send settles"
        )
    }

    func test_openStudioDoesNotRefetchDeskStream_becauseStudioMustNotWaitOnChatReplay() throws {
        // WHY: Studio dest is Profile/Brain/Desktop. Clicking Studio used to
        // force-replay the linked chat stream before the dest could paint —
        // dead time on a dest that does not show the timeline.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try seedLinkedTurn(context: context, bot: bot, extraReasoning: 8)
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        let afterDesk = vm.deskLiveReplayFetchCountForTesting
        XCTAssertGreaterThan(afterDesk, 0, "first Desk open must fetch the stream once")
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.name, "Piper")
        XCTAssertEqual(
            vm.deskLiveReplayFetchCountForTesting,
            afterDesk,
            "Studio dest must not refetch the desk stream"
        )
    }

    func test_reopeningDeskUsesCachedLiveTurn_becauseRosterSwitchMustNotReplayUnchangedStream() throws {
        // WHY: switching away and back used to force-replay the same stream
        // before Chat could paint. Cached timeline with unchanged event count
        // is already the honest desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        try seedLinkedTurn(context: context, bot: piper, extraReasoning: 8)
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        let afterFirst = vm.deskLiveReplayFetchCountForTesting
        vm.openDesk(quinn)
        XCTAssertEqual(vm.deskLiveReplayFetchCountForTesting, afterFirst)
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        XCTAssertEqual(
            vm.deskLiveReplayFetchCountForTesting,
            afterFirst,
            "reopening Piper must reuse the cached live turn when the stream did not grow"
        )
    }

    func test_reopeningDeskUsesCachedMessages_becauseRosterSwitchMustNotRereadTheThread() throws {
        // WHY: openDesk used to listRecent the linked thread on every roster
        // click even when messagesByBot already had the honest Desk. Warm
        // cache is the dest; first open and remount still read the store.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        try seedLinkedTurn(context: context, bot: piper, extraReasoning: 2)
        vm.openDesk(piper)
        XCTAssertFalse(vm.deskMessages.isEmpty)
        let afterFirst = vm.deskMessageRestoreCountForTesting
        XCTAssertGreaterThan(afterFirst, 0, "first Desk open must read the thread once")
        vm.openDesk(quinn)
        vm.openDesk(piper)
        XCTAssertFalse(vm.deskMessages.isEmpty)
        XCTAssertEqual(
            vm.deskMessageRestoreCountForTesting,
            afterFirst,
            "reopening Piper must not reread the thread when the cache is warm"
        )
    }

    func test_reopeningDeskDoesNotRescanFinishedRuns_becauseRosterSwitchMustNotListEveryRun() throws {
        // WHY: restoreDeskWorkLog fell through to listRecentFinished(80) on
        // every dest click when lastLinkedRunID was unset. The first lookup
        // must remember the run so roster switch does not rescan.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        try seedLinkedTurn(context: context, bot: piper, extraReasoning: 2)
        vm.openDesk(piper)
        let afterFirst = vm.deskFinishedRunScanCountForTesting
        XCTAssertGreaterThan(afterFirst, 0, "first Desk open must look up the finished run")
        vm.openDesk(quinn)
        vm.openDesk(piper)
        XCTAssertEqual(
            vm.deskFinishedRunScanCountForTesting,
            afterFirst,
            "reopening Piper must reuse lastLinkedRunID instead of listing finished runs"
        )
    }

    func test_reopeningDeskDoesNotReloadStudioSupport_becauseRosterSwitchMustNotRereadInspector() throws {
        // WHY: openDesk used to list conversations, revision, skills,
        // memory, routines, and the last brain receipt on every roster
        // click. Warm inspector is already the dest; first open still reads.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterPiper = vm.studioSupportReloadCountForTesting
        XCTAssertGreaterThan(afterPiper, 0, "first Desk open must read inspector once")
        vm.openDesk(quinn)
        let afterQuinn = vm.studioSupportReloadCountForTesting
        XCTAssertEqual(afterQuinn, afterPiper + 1, "first Quinn dest must read inspector once")
        vm.openDesk(piper)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.studioSupportReloadCountForTesting,
            afterQuinn,
            "reopening Piper must not reread inspector when the cache is warm"
        )
    }

    func test_openStudioUsesCachedRevision_becauseStudioDestMustNotRereadTheBrain() throws {
        // WHY: Studio dest called getRevision before the draft could paint
        // even when Desk chips already cached that immutable revision.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        vm.openDesk(bot)
        _ = vm.providerLabel(for: bot)
        let afterDesk = vm.rosterRevisionFetchCountForTesting
        XCTAssertGreaterThan(afterDesk, 0, "first Desk dest must read the revision once")
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.name, "Piper")
        XCTAssertEqual(
            vm.rosterRevisionFetchCountForTesting,
            afterDesk,
            "Studio dest must reuse the cached revision"
        )
    }

    func test_openStudioUsesCachedStudioSupport_becauseStudioDestMustNotRereadInspector() throws {
        // WHY: Studio dest needs the same inspector rows Desk already
        // loaded. Clicking Studio must paint from that cache, not wait on
        // another six store reads.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        let afterDesk = vm.studioSupportReloadCountForTesting
        XCTAssertGreaterThan(afterDesk, 0)
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.name, "Piper")
        XCTAssertEqual(
            vm.studioSupportReloadCountForTesting,
            afterDesk,
            "Studio dest must reuse the warm inspector snapshot"
        )
    }

    func test_saveStudioDoesNotReloadFleet_becauseSaveMustNotScanEveryRow() throws {
        // WHY: Save Bot dest used to reloadFleet (every teammate's
        // conversations + recent messages) before Studio could settle.
        // Publish already wrote this row; dest must not list every row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        let afterOpen = vm.fleetReloadCountForTesting
        vm.studioDraft.title = "Night scout"
        _ = try vm.saveStudio()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterOpen,
            "Save dest must not rescan the fleet"
        )
    }

    func test_saveStudioUpdatesRosterRow_becauseStaleNameMustNotLookCurrent() throws {
        // WHY: cache-first dest is honest only when Save Bot still
        // replaces the roster name/title the fleet would show.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.studioDraft.name = "Piper Night"
        vm.studioDraft.title = "Night scout"
        let saved = try vm.saveStudio()
        XCTAssertEqual(saved.name, "Piper Night")
        XCTAssertEqual(saved.title, "Night scout")
        let row = try XCTUnwrap(vm.publishedRoster.first(where: { $0.id == piper.id }))
        XCTAssertEqual(row.name, "Piper Night")
        XCTAssertEqual(row.title, "Night scout")
        XCTAssertTrue(vm.fleet.contains(where: { $0.name == "Quinn" }))
    }

    func test_saveStudioDoesNotReloadStudioSupport_becauseSaveDestMustNotRereadInspector() throws {
        // WHY: Save dest used to force-reload studio support after
        // publish already returned this revision. Dest must not reread
        // conversations, skills, memory, or routines.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        let afterOpen = vm.studioSupportReloadCountForTesting
        XCTAssertGreaterThan(afterOpen, 0)
        vm.studioDraft.title = "Night scout"
        _ = try vm.saveStudio()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.selectedRevision?.title, "Night scout")
        XCTAssertEqual(
            vm.studioSupportReloadCountForTesting,
            afterOpen,
            "Save dest must not reread inspector"
        )
    }

    func test_saveStudioKeepsExistingInspector_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first save is honest only when older inspector
        // rows stay visible and the new revision paints.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.memoryDraft = "Keeps the overnight brief"
        vm.addMemory()
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let afterInspector = vm.studioSupportReloadCountForTesting
        vm.studioDraft.title = "Night scout"
        _ = try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.title, "Night scout")
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Keeps the overnight brief"])
        XCTAssertEqual(vm.skillBindings.map(\.skillID), ["weekly-account-health"])
        XCTAssertEqual(vm.routines.map(\.definition.name), ["Morning scan"])
        XCTAssertEqual(vm.studioSupportReloadCountForTesting, afterInspector)
        XCTAssertEqual(vm.screen, .studio)
    }

    func test_reopeningDeskAfterMemoryAddUsesUpdatedCache_becauseStaleMemoryMustNotLookCurrent() throws {
        // WHY: write-behind dest cache must not resurrect forgotten
        // inspector rows. Adding memory then switching teammates must
        // still show the new note.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Piper keeps the overnight brief"
        vm.addMemory()
        XCTAssertEqual(vm.liveMemoryCount, 1)
        vm.openDesk(quinn)
        vm.openDesk(piper)
        XCTAssertEqual(vm.liveMemoryCount, 1)
        XCTAssertEqual(vm.memoryItems.first?.content, "Piper keeps the overnight brief")
    }

    func test_addMemoryDoesNotListMemory_becauseAddDestMustNotRereadFacts() throws {
        // WHY: Add dest used to listMemory after putMemory before the
        // new fact could paint. The store already returned the row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let afterDesk = vm.memoryListCountForTesting
        XCTAssertGreaterThan(afterDesk, 0)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers dark mode"])
        XCTAssertTrue(vm.memoryDraft.isEmpty)
        XCTAssertEqual(
            vm.memoryListCountForTesting,
            afterDesk,
            "add dest must not reread every memory row"
        )
        vm.memoryDraft = "Keeps the overnight brief"
        vm.addMemory()
        XCTAssertEqual(
            vm.memoryItems.map(\.content),
            ["Keeps the overnight brief", "Prefers dark mode"]
        )
        XCTAssertEqual(vm.memoryListCountForTesting, afterDesk)
    }

    func test_addMemoryKeepsExistingFacts_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first add is honest only when older facts stay
        // visible and the new row paints first.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try context.botStore.putMemory(
            botID: piper.id,
            content: "Older overnight brief",
            provenance: "user",
            trusted: true,
            source: "studio"
        )
        vm.openDesk(piper)
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Older overnight brief"])
        let afterDesk = vm.memoryListCountForTesting
        vm.memoryDraft = "Newer desk fact"
        vm.addMemory()
        XCTAssertEqual(vm.memoryItems.first?.content, "Newer desk fact")
        XCTAssertEqual(
            Set(vm.memoryItems.map(\.content)),
            Set(["Newer desk fact", "Older overnight brief"])
        )
        XCTAssertEqual(vm.liveMemoryCount, 2)
        XCTAssertEqual(vm.memoryListCountForTesting, afterDesk)
        XCTAssertEqual(
            Set(try context.botStore.listMemory(botID: piper.id).map(\.content)),
            Set(["Newer desk fact", "Older overnight brief"])
        )
    }

    func test_correctMemoryDoesNotListMemory_becauseCorrectDestMustNotRereadFacts() throws {
        // WHY: Correct dest used to listMemory after the store returned
        // the revised row. Dest must not reread every fact.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        let afterAdd = vm.memoryListCountForTesting
        let item = try XCTUnwrap(vm.memoryItems.first)
        vm.correctMemory(id: item.id, content: "Prefers light mode")
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers light mode"])
        XCTAssertEqual(
            vm.memoryListCountForTesting,
            afterAdd,
            "correct dest must not reread every memory row"
        )
    }

    func test_forgetMemoryDoesNotListMemory_becauseForgetDestMustNotRereadFacts() throws {
        // WHY: Forget dest used to listMemory after the store marked the
        // row forgotten. Dest must drop the row locally.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        let afterAdd = vm.memoryListCountForTesting
        vm.forgetMemory(id: try XCTUnwrap(vm.memoryItems.first).id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertTrue(vm.memoryItems.isEmpty)
        XCTAssertEqual(vm.liveMemoryCount, 0)
        XCTAssertEqual(
            vm.memoryListCountForTesting,
            afterAdd,
            "forget dest must not reread every memory row"
        )
    }

    func test_reopeningDeskAfterMemoryCorrectUsesUpdatedCache_becauseStaleFactMustNotLookCurrent() throws {
        // WHY: dest-first correct is honest only when the old wording
        // cannot come back from the inspector cache.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        vm.correctMemory(id: try XCTUnwrap(vm.memoryItems.first).id, content: "Prefers light mode")
        vm.openDesk(quinn)
        vm.openDesk(piper)
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers light mode"])
        XCTAssertEqual(vm.liveMemoryCount, 1)
    }

    func test_deskRefetchesLiveTurnWhenStreamGrows_becauseStaleThoughtMustNotLookCurrent() throws {
        // WHY: cache-first reopen is honest only when a newer stream still
        // replaces the cached Thought. A grown event count must refetch.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let seed = try seedLinkedTurn(context: context, bot: bot, extraReasoning: 2)
        vm.openDesk(bot)
        let afterFirst = vm.deskLiveReplayFetchCountForTesting
        try persistStreamEvents(
            context: context,
            run: seed.run,
            events: [
                .itemDelta(itemId: "r-desk", bodyAppend: " plus a later thought", outputAppend: nil, summary: nil),
            ],
            startSeq: seed.eventCount + 1
        )
        vm.openDesk(bot)
        XCTAssertEqual(vm.deskLiveReplayFetchCountForTesting, afterFirst + 1)
        let reasoning = try XCTUnwrap(vm.deskLiveTimeline.turns.first?.items.first { $0.type == .reasoning })
        XCTAssertTrue(
            AgentChatLiveTurnChrome.reasoningText(reasoning).contains("plus a later thought"),
            "grown stream must replace the cached Thought"
        )
    }

    func test_openStudioAnnouncesDestImmediately_becauseDestChangeIsTheAcknowledgement() throws {
        // WHY: Studio dest is a sync screen change. The acknowledgement is
        // the dest itself, not a spinner. Reduced-motion stays an instant
        // swap because nothing is animated.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.name, "Piper")
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("bots.desk.studio"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.studio"))
    }

    func test_distillRoutineEditorNeverRendersAutoModelState_becauseDistillRequiresExplicitRoles() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "struct BotScheduleSpecEditor: View") else {
            return XCTFail("Bot routine editor must exist")
        }
        let editor = source[start.lowerBound...]

        XCTAssertTrue(editor.contains("if spec.provider != .distill && spec.routingMode == .auto"))
        XCTAssertTrue(editor.contains("if spec.provider != .distill {\n                    formRow(\"Model routing\")"))
        XCTAssertTrue(editor.contains("AgentDistillModelSelectors("))
        XCTAssertTrue(editor.contains("mainEffortSelection: mainEffortSelection"))
        XCTAssertTrue(editor.contains("reasoningEffortSelection: reasoningEffortSelection"))
    }

    func test_deskIdentityOpensStudio() throws {
        // WHY: The labeled Studio button competed with Chat. Identity and a
        // cog must dest to Studio; the inspector toggle stays last on the right.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskChat")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("bots.desk.identity"))
        XCTAssertTrue(slice.contains("gearshape"))
        XCTAssertFalse(slice.contains("Button(\"Studio\")"))
        let studio = slice.range(of: "bots.desk.studio")?.lowerBound
        let toggle = slice.range(of: "bots.desk.inspectorToggle")?.lowerBound
        XCTAssertNotNil(studio)
        XCTAssertNotNil(toggle)
        XCTAssertLessThan(studio!, toggle!)
    }

    func test_deskSidePaneResizesLikeOtherPanels_becauseWidthMustNotStayCapped() throws {
        // WHY: Files and the shell sidebar drag with DSResizeDivider and
        // persist width. Desk inspector was a fixed 340–420 strip, so the
        // owner could not match those panels.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertEqual(vm.deskSidePaneWidth, BotsChrome.desktopPaneWidth)
        vm.resizeDeskSidePane(by: 80)
        XCTAssertEqual(vm.deskSidePaneWidth, 420)
        vm.resizeDeskSidePane(by: 400)
        XCTAssertEqual(vm.deskSidePaneWidth, BotsChrome.desktopPaneMaxWidth)
        vm.resizeDeskSidePane(by: -1000)
        XCTAssertEqual(vm.deskSidePaneWidth, BotsChrome.desktopPaneMinWidth)

        UserDefaults.standard.set(480.0, forKey: "bots.deskSidePaneWidth")
        let restored = BotsViewModel(context: context)
        XCTAssertEqual(restored.deskSidePaneWidth, 480)

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskChat") else {
            return XCTFail("desk chat must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskDesktopPane")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("DSResizeDivider"))
        XCTAssertTrue(slice.contains("Resize inspector"))
        XCTAssertTrue(slice.contains("resizeDeskSidePane(by: -delta)"))
        XCTAssertTrue(slice.contains(".frame(width: vm.deskSidePaneWidth)"))
        XCTAssertFalse(slice.contains("maxWidth: 420"))
    }

    func test_deskThreadRailResizesLikeAgentApp_becauseClearAllMustStayOneLine() throws {
        // WHY: dest dest dest dest fixed the rail at 220/320. Agent App
        // drags 320–360. dest dest dest dest must persist that range so
        // hide + Clear All + + stay on one line.
        XCTAssertEqual(BotsChrome.clampedThreadRailWidth(200), BotsChrome.threadRailMinWidth)
        XCTAssertEqual(BotsChrome.clampedThreadRailWidth(400), BotsChrome.threadRailMaxWidth)
        XCTAssertEqual(BotsChrome.clampedThreadRailWidth(340), 340)

        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertEqual(vm.deskThreadRailWidth, BotsChrome.threadRailWidth)
        vm.resizeDeskThreadRail(by: 40)
        XCTAssertEqual(vm.deskThreadRailWidth, 360)
        vm.resizeDeskThreadRail(by: 80)
        XCTAssertEqual(vm.deskThreadRailWidth, BotsChrome.threadRailMaxWidth)
        vm.resizeDeskThreadRail(by: -1000)
        XCTAssertEqual(vm.deskThreadRailWidth, BotsChrome.threadRailMinWidth)

        UserDefaults.standard.set(340.0, forKey: "bots.deskThreadRailWidth")
        let restored = BotsViewModel(context: context)
        XCTAssertEqual(restored.deskThreadRailWidth, 340)

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskChat") else {
            return XCTFail("desk chat must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskDesktopPane")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("Resize threads"))
        XCTAssertTrue(slice.contains("resizeDeskThreadRail(by: delta)"))
        XCTAssertTrue(slice.contains(".frame(width: vm.deskThreadRailWidth)"))
        XCTAssertFalse(slice.contains("BotsChrome.threadRailWidth)"))
    }

    func test_deskHeaderKeepsThreadToggleAndNewThread_becauseHideMustNotRemoveThem() throws {
        // WHY: hiding the rail used to remove the only header toggle, and
        // new thread lived only on the rail. Both must stay in the Desk
        // header; + sits after Open in New Window.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskChat")?.lowerBound ?? rest.endIndex
        let header = String(source[start.lowerBound..<end])
        XCTAssertFalse(header.contains("if !vm.isDeskThreadRailVisible"))
        XCTAssertTrue(header.contains("isDeskThreadRailVisible.toggle()"))
        XCTAssertTrue(header.contains("bots.desk.thread.toggle"))
        XCTAssertTrue(header.contains("bots.desk.openInNewWindow"))
        XCTAssertTrue(header.contains("bots.desk.thread.new.header"))
        XCTAssertTrue(header.contains("AgentChatThreadRailCopy.newHelp"))
        let window = try XCTUnwrap(header.range(of: "bots.desk.openInNewWindow"))
        let plus = try XCTUnwrap(header.range(of: "bots.desk.thread.new.header"))
        XCTAssertTrue(
            window.lowerBound < plus.lowerBound,
            "new thread must sit to the right of Open in New Window"
        )
    }

    func test_deskAlwaysDropsTitlebarInsetsInMainShell_becauseTheHeaderMustHugTheTrafficLightRow() throws {
        // WHY: the sidebar (open) or the 34pt restore bar (collapsed) owns
        // the traffic lights. Keeping the .top inset while the sidebar was
        // open parked the Ceo header a full titlebar below the traffic
        // lights — the vertical padding in the bug report. The edge set is
        // also state-independent so Desk stays still during the toggle.
        XCTAssertEqual(
            BotsViewModel.ignoredSafeAreaEdges(
                presentsAsDetachedWindow: false
            ),
            [.top, .leading, .trailing],
            "main-shell Desk owns its whole pane: no titlebar strip, no traffic-light gutter"
        )
        XCTAssertEqual(
            BotsViewModel.deskIdentityLeadingPadding(shellSidebarCollapsed: false),
            BotsViewModel.deskIdentityLeadingPadding(shellSidebarCollapsed: true),
            "Ceo leading padding must match open and collapsed — the gutter is not padding"
        )
        XCTAssertTrue(
            BotsViewModel.cancelsWindowLeadingTitlebarGutter(presentsAsDetachedWindow: false),
            "main-shell Desk must drop the window traffic-light inset"
        )
        XCTAssertFalse(
            BotsViewModel.cancelsWindowLeadingTitlebarGutter(presentsAsDetachedWindow: true)
        )
        XCTAssertEqual(
            BotsViewModel.addedLeadingInsetBeyondIdentityPadding(
                windowTitlebarLeading: 78,
                presentsAsDetachedWindow: false
            ),
            0,
            "open sidebar must not still reserve the titlebar gutter on Desk"
        )
        XCTAssertEqual(
            BotsViewModel.addedLeadingInsetBeyondIdentityPadding(
                windowTitlebarLeading: 78,
                presentsAsDetachedWindow: true
            ),
            78
        )
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        XCTAssertTrue(
            main.contains("ContentColumnHostingView"),
            "NSHostingView must override safeAreaInsets — ignoresSafeArea alone leaves the gutter"
        )
        XCTAssertTrue(main.contains("cancelHorizontalTitlebarGutter"))
        XCTAssertTrue(
            BotsViewModel.ignoredSafeAreaEdges(
                presentsAsDetachedWindow: true
            ).isEmpty,
            "a detached Desk window has its own titlebar and must keep its insets"
        )
        let context = try makeContext()
        try context.settingsRepo.set(MainWindowController.sidebarCollapsedSettingsKey, "1")
        let vm = BotsViewModel(context: context)
        XCTAssertTrue(vm.isShellSidebarCollapsed)
    }

    func test_deskHeaderIsToolbarSized_becauseTheShellTitlebarAlreadyWentAway() throws {
        // WHY: Removing the shell "Bots" bar left Desk in the titlebar
        // inset with title2 + xl padding. That read as a second titlebar.
        // Identity must sit in a 44pt chrome strip like a workspace row.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("ignoresSafeArea(.container, edges:"))
        guard let start = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskChat")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("DS.Font.bodyStrong"))
        XCTAssertTrue(slice.contains("size: 22"))
        XCTAssertTrue(slice.contains(".frame(height: 44)"))
        XCTAssertTrue(
            slice.contains("deskIdentityLeadingPadding"),
            "Desk identity must use the shared leading padding, not a sidebar-open gutter"
        )
        XCTAssertFalse(slice.contains("DS.Font.title2"))
        XCTAssertFalse(slice.contains("padding(.vertical, DS.Space.xl)"))
    }

    func test_deskThreadRowsMatchAgentAppRail_becauseTheDeskMustNotForkTheChrome() throws {
        // WHY: the Desk rail read as a different app — no provider
        // monogram, a time-only subtitle, no resting status dot. Desk and
        // Agent App mount the same AgentChatThreadRow, so the row inputs
        // must stay the Agent App ones (bug report: "deveria ser
        // exatamente igual ao do agent app").
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskThreadRow") else {
            return XCTFail("desk thread row must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private var filesTab")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("AgentThreadProviderMonogram(provider:"),
                      "desk rows need the same provider monogram chip as the Agent App rail")
        XCTAssertTrue(slice.contains("AgentThreadRailRowCopy.subtitle"),
                      "desk rows need the provider · model · time subtitle, not time alone")
        XCTAssertTrue(slice.contains("pin.fill"))
        XCTAssertTrue(slice.contains("circle.fill"),
                      "resting rows show the same neutral dot as the Agent App rail")
        XCTAssertTrue(slice.contains("AgentThreadTitle.display"))
        XCTAssertFalse(slice.contains("AgentChatTranscriptChrome.relativeTimestamp"),
                       "the time-only subtitle was the fork")
        let agent = try String(contentsOf: sourceURL("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        XCTAssertTrue(agent.contains("AgentThreadProviderMonogram(provider: t.provider)"),
                      "Agent App must mount the shared monogram, not an inline copy")
        XCTAssertTrue(agent.contains("onStop: running ? { vm.stopThread(t.id) } : nil"),
                      "Agent App must mount the shared stop, not a private overlay")
        XCTAssertFalse(
            agent.contains("accessibilityIdentifier(\"agent.thread.row.stop."),
            "the stop identifier must live on the shared row, not an Agent-App-only overlay"
        )

        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let conversation = BotConversation(botID: BotID(), title: "never ran")
        let routing = vm.deskThreadRailRouting(for: conversation)
        XCTAssertEqual(routing.provider, vm.deskRunProvider,
                       "a never-run conversation must show the routing the desk would use today")
        XCTAssertTrue(slice.contains("onStop:"))
        XCTAssertTrue(slice.contains("stopDeskThread"))
        XCTAssertTrue(slice.contains("isDeskConversationRunning"))
        XCTAssertTrue(slice.contains("runningIdentifier"))
        XCTAssertTrue(slice.contains("stopIdentifier"))
        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatSharedChrome.swift"), encoding: .utf8)
        XCTAssertTrue(chrome.contains("AgentChatThreadRowStopChrome"))
        XCTAssertTrue(chrome.contains("stop.circle"))
    }

    /// WHY: opening Desk used to full-get every linked thread just to paint
    /// provider · model on the rail. First paint must reuse batched listChrome
    /// so N rows cannot stall MainActor.
    func test_deskThreadRailRouting_usesListChromeWithoutDurableGet() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        var conversations: [BotConversation] = []
        conversations.reserveCapacity(20)
        for index in 0..<20 {
            let thread = AgentThread(
                title: "desk-\(index)",
                provider: .claude,
                model: "opus-\(index)"
            )
            try context.threadRepo.upsert(thread)
            let conversation = BotConversation(
                botID: bot.id,
                title: "desk-\(index)",
                linkedAgentThreadID: thread.id
            )
            try context.botStore.upsertConversation(conversation)
            conversations.append(conversation)
        }
        let getsBeforeOpen = context.threadRepo.durableGetCountForTesting
        let chromeBeforeOpen = context.threadRepo.listChromeCallCountForTesting
        vm.openDesk(bot)
        XCTAssertGreaterThanOrEqual(
            context.threadRepo.listChromeCallCountForTesting,
            chromeBeforeOpen + 1,
            "openDesk must prefetch rail routing with listChrome"
        )
        XCTAssertLessThan(
            context.threadRepo.durableGetCountForTesting - getsBeforeOpen,
            20,
            "openDesk must not full-get once per linked thread for rail chrome"
        )

        let getsBeforeRows = context.threadRepo.durableGetCountForTesting
        let chromeBeforeRows = context.threadRepo.listChromeCallCountForTesting
        let painted = vm.conversations.map { vm.deskThreadRailRouting(for: $0) }
        XCTAssertEqual(painted.count, 20)
        XCTAssertEqual(Set(painted.map(\.model)), Set((0..<20).map { "opus-\($0)" }))
        XCTAssertTrue(painted.allSatisfy { $0.provider == .claude })
        XCTAssertEqual(
            context.threadRepo.durableGetCountForTesting,
            getsBeforeRows,
            "desk thread rows must read rail routing from the prefetch cache"
        )
        XCTAssertEqual(
            context.threadRepo.listChromeCallCountForTesting,
            chromeBeforeRows,
            "row paint must not re-query listChrome after prefetch"
        )

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("prefetchDeskThreadRailRouting(for: conversations)"))
        XCTAssertTrue(source.contains("threadRepo.listChrome(ids: missing)"))
        let routingRange = try XCTUnwrap(source.range(of: "public func deskThreadRailRouting(for conversation: BotConversation)"))
        let routingBody = String(source[routingRange.lowerBound...].prefix(900))
        XCTAssertFalse(
            routingBody.contains("threadRepo.get(id:"),
            "deskThreadRailRouting must not full-get a thread for provider · model"
        )
        XCTAssertFalse(
            routingBody.contains("listChrome"),
            "row paint must not listChrome; prefetch after first frame fills the cache"
        )
    }

    func test_deskThreadRailRouting_followsTheModelTheSendWroteToTheThread() throws {
        // WHY: the memo is filled per id, and a send that drifts the model on
        // the existing thread was the one writer that never touched it. The rail
        // kept painting the model the thread had before the send, so the user
        // read a route their thread no longer used.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let conversation = BotConversation(
            botID: bot.id,
            title: "Standup",
            linkedAgentThreadID: thread.id
        )
        try context.botStore.upsertConversation(conversation)
        vm.openDesk(bot)
        let painted = try XCTUnwrap(vm.conversations.first(where: { $0.id == conversation.id }))

        vm.setDeskModel("sonnet")
        XCTAssertEqual(vm.deskThreadRailRouting(for: painted).model, "opus",
                       "fixture: a pending composer choice must not repaint a thread that has not run on it")

        vm.composerText = "ship it"
        XCTAssertTrue(vm.send())
        XCTAssertEqual(
            try context.threadRepo.get(id: thread.id)?.model,
            "sonnet",
            "fixture: the send must drift the linked thread onto the selected model"
        )
        XCTAssertEqual(
            vm.deskThreadRailRouting(for: painted).model,
            "sonnet",
            "WHY: the chip must follow the thread row the send just wrote, not the model it had before"
        )
    }

    func test_deskThreadRailOrdersWorkingFirst_becauseActiveMustStayOnTop() throws {
        // WHY: + / a newer idle dest thread used to insert at index 0 and
        // bury the live spinner. Dest must use the shared active-first sort
        // so Working rows stay at the top like Agent App.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        let idle = BotConversation(
            botID: piper.id,
            title: "Review idle",
            updatedAt: Date()
        )
        let working = BotConversation(
            botID: piper.id,
            title: "Review live",
            attentionState: .working,
            updatedAt: Date().addingTimeInterval(-120)
        )
        try context.botStore.upsertConversation(idle)
        try context.botStore.upsertConversation(working)
        vm.openDesk(piper)
        XCTAssertEqual(vm.filteredDeskConversations.map(\.title), ["Review live", "Review idle"])
        XCTAssertEqual(vm.deskThreadActiveCount, 1)
        XCTAssertTrue(vm.isDeskConversationRunning(working))
        XCTAssertFalse(vm.isDeskConversationRunning(idle))
    }

    func test_deskThreadRailTreatsCoordinatorLiveThreadAsRunning() throws {
        // WHY: attentionState can lag. A dest row linked to a live
        // coordinator thread must still sort and paint as active.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        let thread = AgentThread(title: "live", provider: .grok, model: "grok-4")
        let idle = BotConversation(botID: piper.id, title: "Idle", updatedAt: Date())
        let live = BotConversation(
            botID: piper.id,
            title: "Coordinator live",
            linkedAgentThreadID: thread.id,
            updatedAt: Date().addingTimeInterval(-60)
        )
        try context.botStore.upsertConversation(idle)
        try context.botStore.upsertConversation(live)
        vm.activeThreadIDsOverrideForTesting = [thread.id]
        vm.openDesk(piper)
        XCTAssertEqual(vm.filteredDeskConversations.map(\.title), ["Coordinator live", "Idle"])
        XCTAssertEqual(vm.deskThreadActiveCount, 1)
        XCTAssertTrue(vm.isDeskConversationRunning(live))
    }

    func test_deskHeaderOpenInNewWindowSitsAfterStudioCog() throws {
        // WHY: Agentic pops a workspace with rectangle.on.rectangle. The
        // cog row is the bot chrome; the pop-out must sit after Studio and
        // before the inspector toggle, and vanish in the detached window.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskChat")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        let studio = try XCTUnwrap(slice.range(of: "bots.desk.studio")?.lowerBound)
        let pop = try XCTUnwrap(slice.range(of: "bots.desk.openInNewWindow")?.lowerBound)
        let toggle = try XCTUnwrap(slice.range(of: "bots.desk.inspectorToggle")?.lowerBound)
        XCTAssertLessThan(studio, pop)
        XCTAssertLessThan(pop, toggle)
        XCTAssertTrue(slice.contains("rectangle.on.rectangle"))
        XCTAssertTrue(slice.contains("Open in New Window"))
        XCTAssertTrue(slice.contains("if !vm.presentsAsDetachedWindow"))
        XCTAssertTrue(source.contains("class BotDeskWindowController"))
        XCTAssertTrue(source.contains("BotsRootView(vm: vm)"))
        XCTAssertTrue(
            slice.contains("HStack(spacing: Self.deskHeaderIconSpacing)"),
            "Studio / pop-out / inspector must cluster, not inherit the header's Space.md"
        )
        XCTAssertTrue(
            source.contains("DS.Space.xs - (DSIconButton.hitTargetSize - DSIconButton.visualSize.width)"),
            "Desk header glyphs must sit Space.xs apart like workspace header icons"
        )
    }

    func test_openBotInNewWindowReusesWindow_andLeavesMainDesk() throws {
        // WHY: A second click must focus the same window. Pop-out is not
        // workspace eviction; the main Desk selection must stay put.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        defer {
            controller.botWindow(for: bot.id)?.orderOut(nil)
            controller.window.orderOut(nil)
        }
        controller.openBotInNewWindow(bot.id)
        let first = try XCTUnwrap(controller.botWindow(for: bot.id))
        controller.openBotInNewWindow(bot.id)
        XCTAssertTrue(controller.botWindow(for: bot.id) === first)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertFalse(vm.presentsAsDetachedWindow)
    }

    func test_openBotGuestDesktopInNewWindowReusesWindow() throws {
        // WHY: Open in New Window on the Linux desktop must pop only that
        // screen, and a second click must focus the same window.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        defer {
            controller.botGuestDesktopWindow(for: bot.id)?.orderOut(nil)
            controller.window.orderOut(nil)
        }
        controller.openBotGuestDesktopInNewWindow(bot.id)
        let first = try XCTUnwrap(controller.botGuestDesktopWindow(for: bot.id))
        XCTAssertEqual(first.accessibilityIdentifier(), "bots.desk.desktop.window")
        controller.openBotGuestDesktopInNewWindow(bot.id)
        XCTAssertTrue(controller.botGuestDesktopWindow(for: bot.id) === first)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("class BotGuestDesktopWindowController"))
        XCTAssertTrue(source.contains("BotGuestDesktopRoot"))
    }

    func test_botsHidesShellWorkspaceHeader_becauseDeskAlreadyHasTheBotHeader() throws {
        // WHY: The shell "Bots" bar sat above Desk's identity header.
        // Desk is the title. Hide that chrome row when the sidebar is open;
        // collapsed still needs it for the sidebar toggle.
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("applyWorkspaceHeaderVisibility"))
        XCTAssertTrue(
            main.contains("showCollapsed || shellContentMode == .bots"),
            "Bots must drop the visible workspace header, not only when the sidebar is collapsed"
        )
        XCTAssertTrue(
            main.contains("workspaceContentTopInset("),
            "hiding the bar without collapsing the inset leaves a 34pt gap"
        )
        XCTAssertEqual(
            ShellSidebarToggleMotion.workspaceContentTopInset(
                collapsed: false,
                hidesVisibleHeader: true,
                headerHeight: 34
            ),
            0,
            "open dest dest dest is full-bleed; dest dest dest already owns the title"
        )
        XCTAssertEqual(
            ShellSidebarToggleMotion.splitTopInset(collapsed: true, headerHeight: 34),
            34,
            "collapsed dest dest still needs the 34pt bar so the sidebar toggle remains reachable"
        )
    }

    func test_deskWorkingLabelFollowsALiveWorkLog_becauseDeskMustShowWorking() throws {
        // WHY: a supervised run in Working must surface the Agent App thinking
        // label on Desk, not only the work-log status pill.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: started
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskRunIsLive)
        XCTAssertEqual(
            vm.deskWorkingLabel(now: started.addingTimeInterval(9)),
            AgentWorkingStripPresentation.label(phase: .thinking, elapsedSeconds: 9)
        )
    }

    func test_groupMemberRunCountsForBotWideStopButNeverReachesTheDesk() throws {
        // WHY (T1 decision): bot-wide Stop and delete must reach the bot's
        // room turn, so a member-thread run counts as the bot's live run. The
        // member conversation is still hidden plumbing: it never shows on the
        // desk, does not make the desk look busy, and a desk send cannot
        // target it (that would bypass the group's sequential turns).
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let group = try context.botStore.createGroup(
            title: "Launch room",
            roomThreadID: AgentThreadID(),
            participantBotIDs: [bot.id]
        )
        var member = try XCTUnwrap(context.botStore.listGroupMemberConversations(groupID: group.id).first)
        let thread = AgentThread(title: "Launch room", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        member.linkedAgentThreadID = thread.id
        try context.botStore.upsertConversation(member)

        XCTAssertTrue(vm.hasLiveRun(botID: bot.id), "bot-wide stop must see the room turn")
        vm.openDesk(bot)
        XCTAssertTrue(vm.conversations.isEmpty)
        XCTAssertFalse(vm.deskRunIsLive)
        XCTAssertThrowsError(try vm.enqueueHostMessage(
            botID: bot.id,
            text: "hi",
            conversationID: member.id,
            routing: BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        )) { error in
            guard case BotStoreError.notFound = error else {
                return XCTFail("expected notFound for a member conversation, got \(error)")
            }
        }
    }

    func test_deskReplaysStreamEventsOnOpen_becauseThinkingMustSurviveClose() throws {
        // WHY: Desk is not a second Agent App window, but it must replay the
        // linked thread's persisted stream events so Thought / Worked remain
        // after close/reopen. A Working… bubble cannot do that.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_040)
        )
        try context.runRepo.upsert(run)
        try persistStreamEvents(
            context: context,
            run: run,
            events: [
                .turnStarted(turnId: "t-desk"),
                .itemStarted(item: AssistantItem(
                    id: "r-desk",
                    turnId: "t-desk",
                    type: .reasoning,
                    state: .streaming,
                    body: "",
                    startedAtMs: 1_700_000_010_000
                )),
                .itemDelta(itemId: "r-desk", bodyAppend: "Checking overnight failures", outputAppend: nil, summary: nil),
                .itemCompleted(itemId: "r-desk", finalState: .completed),
                .itemStarted(item: AssistantItem(
                    id: "tool-desk",
                    turnId: "t-desk",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    body: #"{"command":"swift test"}"#,
                    startedAtMs: 1_700_000_020_000,
                    finishedAtMs: 1_700_000_030_000
                )),
                .turnCompleted(turnId: "t-desk", finalMessage: "Three failing tests remain."),
            ]
        )
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Summarize overnight",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Summarize overnight", linkedAgentThreadID: thread.id)
        )

        vm.openDesk(bot)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome, "reopen must paint Work so far / Thought, not only bubbles")
        let turn = try XCTUnwrap(vm.deskLiveTimeline.turns.first)
        let reasoning = try XCTUnwrap(turn.items.first { $0.type == .reasoning })
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: reasoning.state == .streaming), "Thought")
        XCTAssertTrue(AgentChatLiveTurnChrome.reasoningText(reasoning).contains("Checking overnight"))
        XCTAssertTrue(AgentChatLiveTurnChrome.workItems(in: turn).contains { $0.type == .tool })
        XCTAssertEqual(turn.finalAssistantMessage, "Three failing tests remain.")
        XCTAssertFalse(
            vm.deskTimeline.contains { if case .workLog = $0 { return true }; return false },
            "Work so far replaces the generic Supervised-run card in the chat column"
        )
        XCTAssertTrue(vm.deskTimeline.contains { if case .liveTurn = $0 { return true }; return false })

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(bot)
        XCTAssertTrue(reopened.deskPaintsLiveTurnChrome)
        XCTAssertEqual(reopened.deskLiveTimeline.turns.first?.finalAssistantMessage, "Three failing tests remain.")
        XCTAssertEqual(reopened.deskStreamEventCount, vm.deskStreamEventCount)
    }

    func test_deskWorkingStripSeesStreamingTools_becauseComposerMustNotHardcodeThinking() throws {
        // WHY: a live tool stream must flip the composer phase to Tools. The old
        // Desk path always passed hasStreamingTools:false, so thinking never
        // looked like Agent App even while commands ran.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: started
        )
        try context.runRepo.upsert(run)
        try persistStreamEvents(
            context: context,
            run: run,
            events: [
                .turnStarted(turnId: "t-live"),
                .itemStarted(item: AssistantItem(
                    id: "r-live",
                    turnId: "t-live",
                    type: .reasoning,
                    state: .completed,
                    body: "Need to run tests",
                    startedAtMs: 1,
                    finishedAtMs: 2
                )),
                .itemStarted(item: AssistantItem(
                    id: "tool-live",
                    turnId: "t-live",
                    type: .tool,
                    state: .streaming,
                    summary: "Bash",
                    body: #"{"command":"swift test"}"#,
                    startedAtMs: 3
                )),
            ]
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskHasStreamingTools)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        XCTAssertEqual(
            vm.deskWorkingLabel(now: started.addingTimeInterval(9)),
            AgentWorkingStripPresentation.label(phase: .tools, elapsedSeconds: 9)
        )
        let live = try XCTUnwrap(vm.deskLiveTimeline.turns.first)
        let composition = AgentChatLiveTurnChrome.compose(live)
        XCTAssertEqual(composition.activity.map(\.type), [.reasoning, .tool])
        XCTAssertTrue(composition.outside.isEmpty)
    }

    func test_refreshDeskLiveTurnPicksUpNewStreamEvents_becauseThinkingMustAppearLive() throws {
        // WHY: followLinkedRun used to poll only run status. Thinking cannot
        // appear unless Desk also hydrates new stream events on the linked thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(run)
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertFalse(vm.deskPaintsLiveTurnChrome)

        try persistStreamEvents(
            context: context,
            run: run,
            events: [
                .turnStarted(turnId: "t-new"),
                .itemStarted(item: AssistantItem(
                    id: "r-new",
                    turnId: "t-new",
                    type: .reasoning,
                    state: .streaming,
                    body: "Looking at the brief",
                    startedAtMs: 10
                )),
            ]
        )
        vm.refreshDeskLiveTurn()
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        let reasoning = try XCTUnwrap(
            vm.deskLiveTimeline.turns.first?.items.first { $0.type == .reasoning }
        )
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: reasoning.state == .streaming), "Thinking…")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(reasoning), "Looking at the brief")
        XCTAssertTrue(
            vm.deskTimeline.contains { if case .liveTurn = $0 { return true }; return false },
            "a reasoning-only turn must still paint Thinking… in the transcript"
        )
    }

    func test_deskAppliesLiveCoordinatorEvents_becauseThinkingMustNotWaitForSQLite() throws {
        // WHY: Agent App paints from didReceive events. Polling latestStreamEvents
        // waits for the 250ms flush, so a live Thinking… row never appears on Desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertFalse(vm.deskPaintsLiveTurnChrome)

        vm.applyDeskLiveEventForTesting(.turnStarted(turnId: "t-live"), threadId: thread.id)
        vm.applyDeskLiveEventForTesting(.itemStarted(item: AssistantItem(
            id: "r-live",
            turnId: "t-live",
            type: .reasoning,
            state: .streaming,
            body: "Considering the failing test",
            startedAtMs: 10
        )), threadId: thread.id)

        XCTAssertTrue(vm.deskPaintsLiveTurnChrome, "live didReceive must paint Thinking… without a persist")
        let reasoning = try XCTUnwrap(
            vm.deskLiveTimeline.turns.first?.items.first { $0.type == .reasoning }
        )
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: true), "Thinking…")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(reasoning), "Considering the failing test")
        XCTAssertTrue(vm.deskTimeline.contains { if case .liveTurn = $0 { return true }; return false })

        vm.refreshDeskLiveTurn()
        XCTAssertEqual(
            AgentChatLiveTurnChrome.reasoningText(
                try XCTUnwrap(vm.deskLiveTimeline.turns.first?.items.first { $0.type == .reasoning })
            ),
            "Considering the failing test",
            "a lagging SQLite replay must not erase the live Thought row"
        )
    }

    func test_deskStreamObserverDropsUnmatchedThreadBeforeMainHop() async throws {
        // WHY: every Bots window observes the coordinator. Stream events for
        // other threads must not hop to MainActor or mutate the selected desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let threadA = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(threadA)
        let conversation = BotConversation(
            botID: bot.id,
            title: "Standup",
            linkedAgentThreadID: threadA.id
        )
        try context.botStore.upsertConversation(conversation)
        vm.openDesk(bot)
        vm.selectDeskThread(conversation.id)
        XCTAssertEqual(vm.selectedConversation?.linkedAgentThreadID, threadA.id)
        XCTAssertEqual(vm.screen, .desk)

        let unmatched = AssistantEvent.turnStarted(turnId: "t-unmatched")
        let runID = AgentRunID()
        let threadB = AgentThreadID()
        vm.resetDeskStreamMainHopCountForTesting()
        for _ in 0..<500 {
            vm.runCoordinator(
                context.coordinator,
                didReceive: unmatched,
                run: runID,
                threadId: threadB
            )
        }
        XCTAssertEqual(vm.deskStreamMainHopCountForTesting, 0)
        XCTAssertEqual(vm.applyIncomingDeskEventCountForTesting, 0)
        XCTAssertTrue(vm.deskLiveTimeline.turns.isEmpty)

        let matched = AssistantEvent.turnStarted(turnId: "t-matched")
        vm.runCoordinator(
            context.coordinator,
            didReceive: matched,
            run: runID,
            threadId: threadA.id
        )
        XCTAssertEqual(vm.deskStreamMainHopCountForTesting, 1)
        for _ in 0..<40 {
            if vm.applyIncomingDeskEventCountForTesting == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.applyIncomingDeskEventCountForTesting, 1)
        XCTAssertEqual(vm.deskLiveTimeline.turns.first?.turnId, "t-matched")
    }

    func test_deskLiveTurnWatchDoesNotPollOnQuarterSecondCadenceWhilePushIsFlowing() async throws {
        // WHY: didReceive already paints Desk. A 250ms SQLite poll on MainActor
        // must not run while the selected thread is receiving push events.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskRunIsLive)
        let watchApplies = vm.deskLiveTurnWatchApplyCountForTesting
        let replayFetches = vm.deskLiveReplayFetchCountForTesting
        vm.runCoordinator(
            context.coordinator,
            didReceive: .turnStarted(turnId: "t-push"),
            run: AgentRunID(),
            threadId: thread.id
        )
        for _ in 0..<40 {
            if vm.applyIncomingDeskEventCountForTesting >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.deskLiveTurnWatchApplyCountForTesting, watchApplies)
        XCTAssertEqual(
            vm.deskLiveReplayFetchCountForTesting,
            replayFetches,
            "pushing live events must not trigger the 250ms fallback poll"
        )
    }

    func test_deskLiveObserverWatermarkDoesNotReplayTheDurableCopy_becauseTheEventAlreadyPainted() throws {
        // WHY: coordinator observers paint stream events immediately. Once the same
        // ordered prefix reaches SQLite, the 250 ms watcher must advance its durable
        // watermark instead of decoding and replaying the whole hot window again.
        let fixture = try makeDeskReplayFixture()
        let replayCount = fixture.viewModel.deskLiveReplayFetchCountForTesting
        let delta = AssistantEvent.itemDelta(
            itemId: "r-watermark",
            bodyAppend: " observed-once",
            outputAppend: nil,
            summary: nil
        )

        fixture.viewModel.applyDeskLiveEventForTesting(delta, threadId: fixture.thread.id)
        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: [delta],
            startSeq: 3
        )
        fixture.viewModel.refreshDeskLiveTurn()

        XCTAssertEqual(
            fixture.viewModel.deskLiveReplayFetchCountForTesting,
            replayCount,
            "the durable copy of an already-observed event must not trigger a full hot-window replay"
        )
        XCTAssertEqual(fixture.viewModel.deskLiveIncrementalDecodeEventCountForTesting, 1)
        let reasoning = try XCTUnwrap(
            fixture.viewModel.deskLiveTimeline.turns.first?.items.first { $0.id == "r-watermark" }
        )
        XCTAssertEqual(reasoning.body, "seed observed-once", "a skipped replay must not duplicate the delta")
    }

    func test_deskLiveObserverWatermarkFallsBackWhenTheObserverMissedAnExternalEvent() throws {
        // WHY: another process can commit to the shared database while this view
        // has no matching observer callback. A watermark advance without a local
        // event must retain the full-replay recovery path.
        let fixture = try makeDeskReplayFixture()
        let replayCount = fixture.viewModel.deskLiveReplayFetchCountForTesting
        let external = AssistantEvent.itemDelta(
            itemId: "r-watermark",
            bodyAppend: " external",
            outputAppend: nil,
            summary: nil
        )

        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: [external],
            startSeq: 3
        )
        fixture.viewModel.refreshDeskLiveTurn()

        XCTAssertEqual(
            fixture.viewModel.deskLiveReplayFetchCountForTesting,
            replayCount + 1,
            "a durable advance with no observer receipt must fall back to full replay"
        )
        let reasoning = try XCTUnwrap(
            fixture.viewModel.deskLiveTimeline.turns.first?.items.first { $0.id == "r-watermark" }
        )
        XCTAssertEqual(reasoning.body, "seed external")
    }

    func test_deskLiveObserverWatermarkFallsBackWhenExternalAppendKeepsRetainedCountStable() throws {
        // WHY: production retention can insert one row while pruning one old row,
        // leaving COUNT(*) unchanged. Out-of-process recovery therefore needs the
        // durable tail identity, not count alone, to notice the missed event.
        let fixture = try makeDeskReplayFixture()
        let fill: [AssistantEvent] = (0..<98).map {
            .contextCompaction(summary: "retained-\($0)")
        }
        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: fill,
            startSeq: 3
        )
        fixture.viewModel.refreshDeskLiveTurn()
        XCTAssertEqual(fixture.context.coordinator.countStreamEvents(threadId: fixture.thread.id), 100)
        let replayCount = fixture.viewModel.deskLiveReplayFetchCountForTesting

        let external = AssistantEvent.contextCompaction(summary: "external-at-stable-count")
        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: [external],
            startSeq: 101
        )
        XCTAssertEqual(fixture.context.coordinator.countStreamEvents(threadId: fixture.thread.id), 100)
        fixture.viewModel.refreshDeskLiveTurn()

        XCTAssertEqual(fixture.viewModel.deskLiveReplayFetchCountForTesting, replayCount + 1)
        XCTAssertEqual(fixture.viewModel.deskLiveTimeline.contextCompactionSummary, "external-at-stable-count")
    }

    func test_deskLiveObserverWatermarkDetectsHistoricalRunMutationAtStableCount() throws {
        // WHY: presentation order follows run start time. A historical run can
        // append and prune at the 100-row cap while a newer run remains the same
        // visible tail, so the cursor also needs a thread-wide mutation watermark.
        let fixture = try makeDeskReplayFixture()
        let historicalFill: [AssistantEvent] = (0..<96).map {
            .contextCompaction(summary: "historical-\($0)")
        }
        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: historicalFill,
            startSeq: 3
        )
        let newerRun = AgentRun(
            threadId: fixture.thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: fixture.run.startedAt.addingTimeInterval(60),
            finishedAt: fixture.run.startedAt.addingTimeInterval(61)
        )
        try fixture.context.runRepo.upsert(newerRun)
        try persistStreamEvents(
            context: fixture.context,
            run: newerRun,
            events: [
                .turnStarted(turnId: "t-newer"),
                .turnCompleted(turnId: "t-newer", finalMessage: "newer-tail"),
            ]
        )
        fixture.viewModel.refreshDeskLiveTurn()
        XCTAssertEqual(fixture.context.coordinator.countStreamEvents(threadId: fixture.thread.id), 100)
        let before = fixture.context.coordinator.streamEventCursor(threadId: fixture.thread.id)
        let replayCount = fixture.viewModel.deskLiveReplayFetchCountForTesting

        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: [.contextCompaction(summary: "historical-external-at-stable-count")],
            startSeq: 99
        )
        XCTAssertEqual(fixture.context.coordinator.countStreamEvents(threadId: fixture.thread.id), 100)
        let after = fixture.context.coordinator.streamEventCursor(threadId: fixture.thread.id)
        XCTAssertEqual(after.rowId, before.rowId, "the newer presentation tail intentionally stays unchanged")
        XCTAssertEqual(after.runId, before.runId)
        XCTAssertEqual(after.sequence, before.sequence)
        XCTAssertNotEqual(after.mutationId, before.mutationId)

        fixture.viewModel.refreshDeskLiveTurn()

        XCTAssertEqual(fixture.viewModel.deskLiveReplayFetchCountForTesting, replayCount + 1)
        XCTAssertEqual(
            fixture.viewModel.deskLiveTimeline.contextCompactionSummary,
            "historical-external-at-stable-count"
        )
    }

    func test_deskLiveObserverWatermarkDoesNotMaskHistoricalMutationBehindObservedNewestAdvance() throws {
        // WHY: one poll may cover both an observed event on the presentation-tail
        // run and an unobserved append on a historical run. Confirming only the
        // newest suffix would consume the thread-wide watermark and lose the
        // external historical event permanently.
        let fixture = try makeDeskReplayFixture()
        let historicalRun = AgentRun(
            threadId: fixture.thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: fixture.run.startedAt.addingTimeInterval(-60),
            finishedAt: fixture.run.startedAt.addingTimeInterval(-59)
        )
        try fixture.context.runRepo.upsert(historicalRun)
        let historicalFill: [AssistantEvent] = (0..<98).map {
            .contextCompaction(summary: "historical-combined-\($0)")
        }
        try persistStreamEvents(
            context: fixture.context,
            run: historicalRun,
            events: historicalFill
        )
        fixture.viewModel.refreshDeskLiveTurn()
        XCTAssertEqual(fixture.context.coordinator.countStreamEvents(threadId: fixture.thread.id), 100)
        let replayCount = fixture.viewModel.deskLiveReplayFetchCountForTesting

        try persistStreamEvents(
            context: fixture.context,
            run: historicalRun,
            events: [.contextCompaction(summary: "historical-external-combined")],
            startSeq: 99
        )
        let observedNewest = AssistantEvent.itemStarted(item: AssistantItem(
            id: "newest-observed-combined",
            turnId: "t-watermark",
            type: .reasoning,
            state: .streaming,
            body: "newest local event",
            startedAtMs: 20
        ))
        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: [observedNewest],
            startSeq: 3
        )
        fixture.viewModel.applyDeskLiveEventForTesting(
            observedNewest,
            threadId: fixture.thread.id
        )
        XCTAssertEqual(fixture.context.coordinator.countStreamEvents(threadId: fixture.thread.id), 100)

        fixture.viewModel.refreshDeskLiveTurn()

        XCTAssertEqual(
            fixture.viewModel.deskLiveReplayFetchCountForTesting,
            replayCount + 1,
            "an observed newest-run suffix must not attest an unobserved historical mutation"
        )
        XCTAssertEqual(
            fixture.viewModel.deskLiveTimeline.contextCompactionSummary,
            "historical-external-combined"
        )
        XCTAssertNotNil(
            fixture.viewModel.deskLiveTimeline.turns
                .flatMap(\.items)
                .first { $0.id == "newest-observed-combined" }
        )
    }

    func test_deskLiveObserverWatermarkBoundsObservedBytesAndFallsBackAfterSwitch() throws {
        // WHY: observer confirmation is only an optimization. A large pending
        // event must fail closed without being retained beyond the byte budget,
        // and leaving the Desk must release a smaller pending prefix while a
        // later durable append still rehydrates through the full fallback.
        let fixture = try makeDeskReplayFixture()
        fixture.viewModel.deskLiveObservedEventByteLimitForTesting = 512
        let replayCount = fixture.viewModel.deskLiveReplayFetchCountForTesting
        let large = AssistantEvent.itemDelta(
            itemId: "r-watermark",
            bodyAppend: String(repeating: "x", count: 1_024),
            outputAppend: nil,
            summary: nil
        )
        fixture.viewModel.applyDeskLiveEventForTesting(large, threadId: fixture.thread.id)
        var buffer = fixture.viewModel.deskLiveObservedEventBufferForTesting(
            threadId: fixture.thread.id
        )
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.bytes, 0)
        XCTAssertEqual(buffer.totalBytes, 0)
        XCTAssertTrue(buffer.overflowed)

        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: [large],
            startSeq: 3
        )
        fixture.viewModel.refreshDeskLiveTurn()
        XCTAssertEqual(fixture.viewModel.deskLiveReplayFetchCountForTesting, replayCount + 1)
        XCTAssertFalse(
            fixture.viewModel.deskLiveObservedEventBufferForTesting(threadId: fixture.thread.id).overflowed
        )

        let pending = AssistantEvent.itemDelta(
            itemId: "r-watermark",
            bodyAppend: " pending-after-switch",
            outputAppend: nil,
            summary: nil
        )
        fixture.viewModel.applyDeskLiveEventForTesting(pending, threadId: fixture.thread.id)
        buffer = fixture.viewModel.deskLiveObservedEventBufferForTesting(threadId: fixture.thread.id)
        XCTAssertEqual(buffer.count, 1)
        XCTAssertGreaterThan(buffer.bytes, 0)
        XCTAssertEqual(buffer.totalBytes, buffer.bytes)

        _ = try fixture.viewModel.create(name: "Quinn", title: "Switch target", provider: .claude)
        buffer = fixture.viewModel.deskLiveObservedEventBufferForTesting(threadId: fixture.thread.id)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.bytes, 0)
        XCTAssertEqual(buffer.totalBytes, 0)
        XCTAssertFalse(buffer.overflowed)

        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: [pending],
            startSeq: 4
        )
        let fallbackCount = fixture.viewModel.deskLiveReplayFetchCountForTesting
        fixture.viewModel.openDesk(fixture.bot)
        XCTAssertEqual(fixture.viewModel.deskLiveReplayFetchCountForTesting, fallbackCount + 1)
        let reasoning = try XCTUnwrap(
            fixture.viewModel.deskLiveTimeline.turns.first?.items.first { $0.id == "r-watermark" }
        )
        XCTAssertTrue(reasoning.body.hasSuffix("pending-after-switch"))
    }

    func test_deskLiveObserverWatermarkPreservesOrderedTerminalTailWithoutReplay() throws {
        // WHY: eliminating redundant replay is safe only when ordered deltas and
        // the terminal event survive exactly once after the durability barrier.
        let fixture = try makeDeskReplayFixture()
        let replayCount = fixture.viewModel.deskLiveReplayFetchCountForTesting
        let tail: [AssistantEvent] = [
            .itemDelta(itemId: "r-watermark", bodyAppend: " A", outputAppend: nil, summary: nil),
            .itemDelta(itemId: "r-watermark", bodyAppend: " B", outputAppend: nil, summary: nil),
            .itemCompleted(itemId: "r-watermark", finalState: .completed),
            .turnCompleted(turnId: "t-watermark", finalMessage: "done"),
        ]
        for event in tail {
            fixture.viewModel.applyDeskLiveEventForTesting(event, threadId: fixture.thread.id)
        }
        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: tail,
            startSeq: 3
        )
        var terminal = fixture.run
        terminal.status = .completed
        terminal.finishedAt = Date()
        try fixture.context.runRepo.upsert(terminal)

        fixture.viewModel.adoptLinkedRunTerminalForTests(
            runId: terminal.id,
            threadId: fixture.thread.id
        )

        XCTAssertEqual(fixture.viewModel.deskLiveReplayFetchCountForTesting, replayCount)
        let turn = try XCTUnwrap(fixture.viewModel.deskLiveTimeline.turns.first)
        XCTAssertTrue(turn.finished)
        XCTAssertEqual(turn.finalAssistantMessage, "done")
        XCTAssertEqual(try XCTUnwrap(turn.items.first { $0.id == "r-watermark" }).body, "seed A B")
    }

    func test_terminalStatusBeforeDurableCommitDoesNotLeaveBotWorking() throws {
        // WHY: the provider's terminal status reaches the Bots view before the coordinator
        // commits the run row. Settling on that still-running row painted Working and
        // ignored the real finish, so finished Bots kept spinning for a minute or more.
        let fixture = try makeDeskReplayFixture()
        var run = fixture.run
        run.status = .running
        run.finishedAt = nil
        try fixture.context.runRepo.upsert(run)

        fixture.viewModel.adoptLinkedRunTerminalForTests(runId: run.id, threadId: fixture.thread.id)

        run.status = .completed
        run.finishedAt = Date()
        try fixture.context.runRepo.upsert(run)
        fixture.viewModel.adoptLinkedRunTerminalForTests(runId: run.id, threadId: fixture.thread.id)

        let conversation = try XCTUnwrap(
            fixture.context.botStore.listConversations(botID: fixture.bot.id)
                .first { $0.linkedAgentThreadID == fixture.thread.id }
        )
        XCTAssertNotEqual(conversation.attentionState, .working,
            "the durable finish must settle the conversation; an early terminal status must not pin it Working")
        XCTAssertNotEqual(fixture.viewModel.attentionState(for: fixture.bot), .working,
            "the Bot avatar must stop spinning once its run is durably finished")
    }

    func test_deskLiveObserverWatermarkReconcilesPersistPollObserverRaceAtTerminal() throws {
        // WHY: persistence can finish before its observer Task reaches MainActor.
        // If the poll replays first, the late callback paints the same delta a
        // second time while the cursor is already current. Terminal settlement
        // must authoritatively reconcile once and release that pending receipt.
        let fixture = try makeDeskReplayFixture()
        let delta = AssistantEvent.itemDelta(
            itemId: "r-watermark",
            bodyAppend: " once",
            outputAppend: nil,
            summary: nil
        )
        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: [delta],
            startSeq: 3
        )
        fixture.viewModel.refreshDeskLiveTurn()
        let afterPoll = fixture.viewModel.deskLiveReplayFetchCountForTesting
        XCTAssertEqual(
            try XCTUnwrap(
                fixture.viewModel.deskLiveTimeline.turns.first?.items
                    .first { $0.id == "r-watermark" }
            ).body,
            "seed once"
        )

        fixture.viewModel.applyDeskLiveEventForTesting(delta, threadId: fixture.thread.id)
        XCTAssertEqual(
            fixture.viewModel.deskLiveObservedEventBufferForTesting(
                threadId: fixture.thread.id
            ).count,
            1
        )

        fixture.viewModel.adoptLinkedRunTerminalForTests(
            runId: fixture.run.id,
            threadId: fixture.thread.id
        )

        XCTAssertEqual(fixture.viewModel.deskLiveReplayFetchCountForTesting, afterPoll + 1)
        XCTAssertEqual(
            try XCTUnwrap(
                fixture.viewModel.deskLiveTimeline.turns.first?.items
                    .first { $0.id == "r-watermark" }
            ).body,
            "seed once"
        )
        var buffer = fixture.viewModel.deskLiveObservedEventBufferForTesting(
            threadId: fixture.thread.id
        )
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.bytes, 0)
        XCTAssertFalse(buffer.overflowed)

        fixture.viewModel.adoptLinkedRunTerminalForTests(
            runId: fixture.run.id,
            threadId: fixture.thread.id
        )
        XCTAssertEqual(
            fixture.viewModel.deskLiveReplayFetchCountForTesting,
            afterPoll + 1,
            "an identical terminal read after cleanup must be a no-op"
        )
        buffer = fixture.viewModel.deskLiveObservedEventBufferForTesting(
            threadId: fixture.thread.id
        )
        XCTAssertEqual(buffer.count, 0)
        XCTAssertFalse(buffer.overflowed)
    }

    func test_deskLiveObserverWatermarkReconcilesObserverArrivingAfterTerminal() throws {
        // WHY: didReceive and didFinish reach MainActor through independent
        // Tasks. Terminal settlement may finish and stop the watcher before a
        // delayed didReceive runs, so that callback itself must close the race.
        let fixture = try makeDeskReplayFixture()
        let delta = AssistantEvent.itemDelta(
            itemId: "r-watermark",
            bodyAppend: " once",
            outputAppend: nil,
            summary: nil
        )
        try persistStreamEvents(
            context: fixture.context,
            run: fixture.run,
            events: [delta],
            startSeq: 3
        )
        fixture.viewModel.refreshDeskLiveTurn()
        let afterPoll = fixture.viewModel.deskLiveReplayFetchCountForTesting

        fixture.viewModel.adoptLinkedRunTerminalForTests(
            runId: fixture.run.id,
            threadId: fixture.thread.id
        )
        XCTAssertEqual(fixture.viewModel.deskLiveReplayFetchCountForTesting, afterPoll)

        fixture.viewModel.applyDeskLiveEventForTesting(
            delta,
            runId: fixture.run.id,
            threadId: fixture.thread.id
        )

        XCTAssertEqual(fixture.viewModel.deskLiveReplayFetchCountForTesting, afterPoll + 1)
        XCTAssertEqual(
            try XCTUnwrap(
                fixture.viewModel.deskLiveTimeline.turns.first?.items
                    .first { $0.id == "r-watermark" }
            ).body,
            "seed once"
        )
        let buffer = fixture.viewModel.deskLiveObservedEventBufferForTesting(
            threadId: fixture.thread.id
        )
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.bytes, 0)
        XCTAssertFalse(buffer.overflowed)

        fixture.viewModel.refreshDeskLiveTurn()
        fixture.viewModel.adoptLinkedRunTerminalForTests(
            runId: fixture.run.id,
            threadId: fixture.thread.id
        )
        XCTAssertEqual(
            fixture.viewModel.deskLiveReplayFetchCountForTesting,
            afterPoll + 1,
            "subsequent identical reads must remain no-ops after late-event cleanup"
        )
    }

    func test_currentGoalAndActivityDriveHomeFromRealConversations() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Ship the beta brief")
        XCTAssertEqual(vm.currentGoal(for: bot), "Ship the beta brief")
        XCTAssertFalse(vm.activityRows(for: bot).isEmpty)
        XCTAssertEqual(BotsChrome.hitTarget, 44)
        XCTAssertEqual(BotsChrome.Label.openChat, "Open Chat")
    }

    func test_openHomeShowsChat_becauseHomeIsNotADestination() throws {
        // WHY: Home/overview is gone. openHome is leftover API and must
        // land on Chat so roster/create never park on Goal cards.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        XCTAssertEqual(vm.screen, .desk)
        vm.openHome(bot)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.screen, BotsScreen.fleet.resolvedDestination)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.providerLabel(for: bot), "Codex", "the unopened thread uses the user's composer default")
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).title, "Scout")
    }

    func test_deskHeaderHasNoBack_becauseHomeIsGoneAndRosterIsTheSwitcher() throws {
        // WHY: Chat Back used to return to Fleet Home. Home is gone, so the
        // chevron called openDesk on the same bot — a visible no-op next to
        // the sidebar roster. Studio Back still returns to Chat.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let deskStart = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let deskRest = source[deskStart.upperBound...]
        let deskEnd = deskRest.range(of: "\n    private func ")?.lowerBound ?? deskRest.endIndex
        let desk = String(source[deskStart.lowerBound..<deskEnd])
        XCTAssertFalse(
            desk.contains("backButton"),
            "Chat must not paint a Back chevron that re-opens the same desk"
        )
        XCTAssertFalse(
            desk.contains("openDesk(bot)"),
            "desk header must not treat Back as a dest after Home was removed"
        )
        guard let studioStart = source.range(of: "private var studioHeader") else {
            return XCTFail("studio header must exist")
        }
        let studioRest = source[studioStart.upperBound...]
        let studioEnd = studioRest.range(of: "\n    private var studioTabs")?.lowerBound ?? studioRest.endIndex
        let studio = String(source[studioStart.lowerBound..<studioEnd])
        XCTAssertTrue(
            studio.contains("backButton"),
            "Studio Back is the real dest back to Chat"
        )
        XCTAssertTrue(
            studio.contains("requestLeaveUnsavedNewBot"),
            "Studio Back must confirm unsaved New Bot before desting Chat"
        )
        XCTAssertTrue(studio.contains("leaveStudioAfterUnsavedGate"))
        XCTAssertTrue(
            studio.contains("studioHeaderNotify"),
            "Notify lives in the header so it stays reachable on Files and Security"
        )
        XCTAssertTrue(studio.contains("bots.studio.notifications"))
        XCTAssertFalse(
            source.contains("private var studioNotifications"),
            "a Profile notifications section would bury the switch under the fold"
        )
    }

    func test_botDeleteUsesPendingConfirmation_becauseDeleteRemovesTheTeammate() throws {
        // WHY: right-click Delete is irreversible. It must go through the same
        // pendingDeleteID dialog as the Fleet overflow, not call delete(id:) now.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("bots.menu.delete"))
        XCTAssertTrue(
            source.contains("BotsDeleteConfirmation(vm: vm, enabled: !vm.presentsAsDetachedWindow)"),
            "BotsRootView owns the one delete dialog in the main shell, with no roster rail"
        )
        XCTAssertTrue(
            source.contains("BotTeamsGroupsSheets(vm: vm, teamsGroups: vm.teamsGroups, enabled: !vm.presentsAsDetachedWindow)"),
            "the Teams manager sheet stays attached once the rail is gone"
        )
        XCTAssertFalse(source.contains("BotsRosterList"), "the shell has no second Bots column")
        XCTAssertFalse(source.contains("showsRosterRail"))
    }

    func test_showHiddenSurvivesRelaunch_becauseShowHiddenIsUserWorkflowState() throws {
        // WHY: Hide is only recoverable from Show hidden. Closing RemoteCode
        // used to drop that toggle, so hidden teammates vanished again.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.setHidden(id: piper.id, hidden: true)
        XCTAssertTrue(vm.fleet.isEmpty)
        vm.showHidden = true
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])

        let reopened = BotsViewModel(context: context)
        XCTAssertTrue(reopened.showHidden)
        XCTAssertEqual(reopened.fleet.map(\.id), [piper.id])
        XCTAssertTrue(try XCTUnwrap(reopened.fleet.first).hidden)
    }

    func test_showHiddenDoesNotReloadFleet_becauseShowHiddenDestMustNotScanEveryRow() throws {
        // WHY: Show hidden dest used to reloadFleet (every teammate's
        // conversations + recent messages) before the roster could paint
        // Hidden rows. Off filters locally; on lists hidden teammates
        // without scanning every conversation.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.setHidden(id: quinn.id, hidden: true)
        let afterHide = vm.fleetReloadCountForTesting
        vm.showHidden = true
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == quinn.id }))
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first { $0.id == quinn.id }).hidden)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterHide,
            "Show hidden dest must not rescan the fleet"
        )
        vm.showHidden = false
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(vm.fleetReloadCountForTesting, afterHide)
    }

    func test_hidingFromRosterStaysRecoverable_becauseShowHiddenLivesOnTheList() throws {
        // WHY: Hide from the sidebar would vanish the row while Show hidden
        // only lived on the empty Fleet header. The roster toggle is the exit.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.setHidden(id: quinn.id, hidden: true)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertFalse(vm.showHidden)
        vm.showHidden = true
        XCTAssertEqual(Set(vm.fleet.map(\.id)), Set([piper.id, quinn.id]))
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(
            sidebar.contains("sidebar.generalBots.showHidden"),
            "Hide on a General Bot is only safe if Show hidden is reachable from the same section"
        )
    }

    func test_setHiddenDoesNotReloadFleet_becauseHideDestMustNotScanEveryRow() throws {
        // WHY: Hide dest used to reloadFleet (every teammate's conversations
        // + recent messages) before the roster could drop the row. The store
        // already wrote this row; dest must not list every row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterDesk = vm.fleetReloadCountForTesting
        vm.setHidden(id: quinn.id, hidden: true)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterDesk,
            "Hide dest must not rescan the fleet"
        )
    }

    func test_hidingSelectedBotOpensTheNextTeammate_becauseEmptyDeskIsNotADestinationWhenTheRosterStillHasRows() throws {
        // WHY: Hide of the open teammate used to clear selectedBotID and set
        // screen=.fleet. Home is gone, so Chat became "Select a teammate"
        // while other rows stayed in the sidebar.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(quinn)
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        vm.setHidden(id: quinn.id, hidden: true)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertFalse(vm.fleet.contains(where: { $0.id == quinn.id }))
    }

    func test_deleteDoesNotListInbox_becauseDeleteDestMustNotRereadQueue() throws {
        // WHY: Delete dest used to listAttention after dest already dested
        // the next row. Dest already dropped this teammate's inbox rows.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        XCTAssertEqual(vm.openAttentionCount, 1)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.delete(id: quinn.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "delete dest must not reread the inbox"
        )
    }

    func test_deleteKeepsDestInbox_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first delete is honest only when dest still shows
        // this teammate's inbox after the other row is gone.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        XCTAssertEqual(vm.attentionItems.first?.botID, piper.id)
        vm.delete(id: quinn.id)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.openAttentionCount, 1)
        XCTAssertEqual(vm.attentionItems.first?.title, "Bot could not start")
        XCTAssertEqual(vm.attentionItems.first?.botID, piper.id)
        XCTAssertEqual(try context.botStore.listAttention().count, 1)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
    }

    func test_deleteDoesNotReloadFleet_becauseDeleteDestMustNotScanEveryRow() throws {
        // WHY: Delete dest used to reloadFleet (every teammate's
        // conversations + recent messages) before Chat could dest the next
        // row. The store already removed this teammate; dest must not list
        // every remaining row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterDesk = vm.fleetReloadCountForTesting
        vm.delete(id: quinn.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterDesk,
            "Delete dest must not rescan the fleet"
        )
    }

    func test_refreshDockerGuestProbeIsSingleFlight_becauseEachProbeStartsADockerContainer() async throws {
        // WHY: every Studio open asks for a probe. Overlapping probes each create a
        // Docker container and raced on the service's published state (SIGSEGV).
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let docker = GatedInfoDocker()
        defer { docker.gate.signal(); docker.gate.signal() }
        vm.dockerGuestReadyOverrideForTesting = nil
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )

        vm.refreshDockerGuestProbe()
        vm.refreshDockerGuestProbe()
        vm.refreshDockerGuestProbe()
        XCTAssertEqual(docker.infoStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(docker.infoStarted.wait(timeout: .now() + 0.3), .timedOut, "a running probe must not start another")
        XCTAssertEqual(docker.infoCalls, 1)

        docker.gate.signal()
        for _ in 0..<200 where vm.dockerGuestProbeReason == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(vm.dockerGuestProbeReason, "the finished probe publishes its result")
        vm.refreshDockerGuestProbe()
        XCTAssertEqual(docker.infoStarted.wait(timeout: .now() + 2), .success, "a new probe may start once the last one finished")
        XCTAssertEqual(docker.infoCalls, 2)
    }

    private final class GatedInfoDocker: BotComputerDockerClienting, @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        let infoStarted = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _infoCalls = 0
        var infoCalls: Int { lock.withLock { _infoCalls } }

        func info() throws -> String {
            lock.withLock { _infoCalls += 1 }
            infoStarted.signal()
            _ = gate.wait(timeout: .now() + 5)
            throw BotComputerGuestError.dockerUnavailable
        }
        func imageExists(tag: String) throws -> Bool { true }
        func imageLabel(tag: String, key: String) throws -> String { "" }
        func imageID(tag: String) throws -> String { "img" }
        func build(context: URL, tag: String) throws {}
        func create(options: BotComputerContainerCreateOptions) throws -> String { options.name }
        func start(name: String) throws {}
        func stop(name: String) throws {}
        func inspect(name: String) throws -> BotComputerContainerInspect {
            BotComputerContainerInspect(running: false, imageID: "img", hostPort: 49152)
        }
        func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data { Data() }
        func rename(from: String, to: String) throws {}
        func ensureNetwork(name: String) throws {}
        func remove(name: String) throws {}
        func removeMatching(namePrefix: String) throws {}
    }

    func test_deleteRunsDockerTeardownOffMain_becauseAStuckDaemonMustNotFreezeTheRoster() async throws {
        // WHY: deleting a teammate is immediate durable UI work, while Docker
        // rm may consume resolver and command timeouts. The event loop must keep
        // ticking even when that cleanup is blocked.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let docker = RecordingDocker()
        let gate = DispatchSemaphore(value: 0)
        docker.blockedRemoveName = BotComputerGuestSpec.containerName(botID: bot.id)
        docker.removeGate = gate
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )

        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        let startedAt = Date()
        vm.delete(id: bot.id)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.1)
        XCTAssertNotNil(
            try context.botStore.get(id: bot.id)?.deletedAt,
            "the roster may return immediately only after the durable soft-delete commits"
        )
        XCTAssertEqual(docker.removeStarted.wait(timeout: .now() + 1), .success)
        await Task.yield()
        XCTAssertTrue(heartbeat, "blocked docker rm must not starve MainActor work")
        gate.signal()
        XCTAssertEqual(docker.removeFinished.wait(timeout: .now() + 1), .success)
    }

    func test_deletingSelectedBotOpensTheNextTeammate_becauseEmptyDeskIsNotADestinationWhenTheRosterStillHasRows() throws {
        // WHY: Delete of the open teammate shared Hide's empty-desk latch.
        // After confirm, Chat must land on a remaining row, not a blank dest.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(quinn)
        vm.delete(id: quinn.id)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_deleteDropsTheDeletedTeammatesResidentCaches_becauseTheWindowMustNotOutgrowTheRoster() throws {
        // WHY: delete dropped the row, the drafts, and the queue, but every
        // resident cache keyed to that teammate stayed for the life of the
        // window — the studio snapshot (conversations, memory facts, routines,
        // selected revision), each published revision, the desk preview, and
        // the per-conversation transcripts. A session that creates and deletes
        // teammates must not keep paying for rows that are gone.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)

        // Warm Piper alone first: its counts are the floor the delete of
        // another teammate must preserve exactly.
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        let studioFloor = vm.studioSupportCacheCountForTesting
        let revisionFloor = vm.revisionCacheCountForTesting
        let transcriptFloor = vm.transcriptCacheCountForTesting
        let previewFloor = vm.lastPreviewCacheCountForTesting

        // Then warm Quinn. These are the fixture proof: Quinn owns resident
        // entries the delete has something to drop, so a green after-assertion
        // cannot come from an empty cache.
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("Second teammate"))
        XCTAssertGreaterThan(
            vm.studioSupportCacheCountForTesting,
            studioFloor,
            "fixture: Quinn must own a studio snapshot to drop"
        )
        XCTAssertGreaterThan(
            vm.revisionCacheCountForTesting,
            revisionFloor,
            "fixture: Quinn must own a published revision to drop"
        )
        XCTAssertGreaterThan(
            vm.transcriptCacheCountForTesting,
            transcriptFloor,
            "fixture: Quinn must own a transcript to drop"
        )
        XCTAssertGreaterThan(
            vm.lastPreviewCacheCountForTesting,
            previewFloor,
            "fixture: Quinn must own a desk preview to drop"
        )
        // `attentionStateByBot` is a whole-roster projection, not a per-teammate
        // cache: one key per live teammate. Same invariant before and after.
        XCTAssertEqual(
            vm.attentionStateCacheCountForTesting,
            vm.fleet.count,
            "the attention projection must cover exactly the live roster"
        )
        XCTAssertEqual(vm.fleet.count, 2, "fixture: both teammates are live here")

        // Hand the desk back so the delete does not navigate and this spec
        // measures the caches rather than the adopt path.
        vm.openDesk(piper)
        XCTAssertEqual(vm.selectedBotID, piper.id)

        vm.delete(id: quinn.id)

        XCTAssertEqual(
            vm.studioSupportCacheCountForTesting,
            studioFloor,
            "delete must drop the deleted teammate's studio snapshot"
        )
        XCTAssertEqual(
            vm.revisionCacheCountForTesting,
            revisionFloor,
            "delete must drop the deleted teammate's published revisions"
        )
        XCTAssertEqual(
            vm.transcriptCacheCountForTesting,
            transcriptFloor,
            "delete must drop the deleted teammate's transcripts"
        )
        XCTAssertEqual(
            vm.lastPreviewCacheCountForTesting,
            previewFloor,
            "delete must drop the deleted teammate's desk preview"
        )
        XCTAssertEqual(
            vm.attentionStateCacheCountForTesting,
            vm.fleet.count,
            "delete must drop the deleted teammate's attention state"
        )
    }

    func test_hidingTheLastVisibleBotKeepsEmptyDesk_becauseTheRosterHasNoRemainingRow() throws {
        // WHY: empty desk is honest only when Hide leaves zero visible teammates.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.setHidden(id: piper.id, hidden: true)
        XCTAssertTrue(vm.fleet.isEmpty)
        XCTAssertNil(vm.selectedBotID)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_setPinnedDoesNotReloadFleet_becausePinDestMustNotScanEveryRow() throws {
        // WHY: Pin dest used to reloadFleet (every teammate's conversations
        // + recent messages) before the roster could resort. The store
        // already wrote this row; dest must not list every row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterDesk = vm.fleetReloadCountForTesting
        vm.setPinned(id: piper.id, pinned: true)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterDesk,
            "Pin dest must not rescan the fleet"
        )
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first).pinned)
    }

    func test_activeBotCountSurvivesPublishesWithoutRosterQueries_andTracksRunTransitions() throws {
        // WHY (perf BT-01): the roster body read `activeBotCount` up to 8× and
        // every read ran `liveWorkingBots()` — two SQLite queries plus a
        // coordinator lock — on every VM publish: per streamed token, per 250ms
        // live-turn tick, per roster-search keystroke. The stored count must
        // survive publishes with zero liveWorkingBots() runs and still track
        // run start/end transitions.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout")
        let otherBot = try vm.create(name: "Quinn", title: "Reviewer")
        let thread = AgentThread(title: "Run", provider: .codex, model: "test")
        try context.threadRepo.upsert(thread)
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Run chat", linkedAgentThreadID: thread.id)
        )
        let otherThread = AgentThread(title: "Other run", provider: .claude, model: "test")
        try context.threadRepo.upsert(otherThread)
        try context.botStore.upsertConversation(
            BotConversation(botID: otherBot.id, title: "Other chat", linkedAgentThreadID: otherThread.id)
        )
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: bot.id, kind: .approval, title: "Need you")
        )

        vm.activeThreadIDsOverrideForTesting = []
        vm.reload()
        XCTAssertEqual(vm.activeBotCount, 0)
        XCTAssertNotEqual(vm.activityState(for: bot), .working)
        XCTAssertEqual(vm.attentionState(for: otherBot), .none)
        let baseline = vm.liveWorkingBotsCountForTesting

        // 50 unrelated publishes (per-token desk timeline writes are the worst
        // case), each followed by the roster badge/subtitle/footer reads.
        for _ in 0..<50 {
            vm.objectWillChange.send()
            _ = vm.activeBotCount
            _ = vm.activeBotsSubtitle
            _ = vm.activeBotsFooterLine
        }
        XCTAssertEqual(
            vm.liveWorkingBotsCountForTesting, baseline,
            "50 VM publishes with badge/subtitle/footer reads must not run liveWorkingBots() (roster SQLite queries)"
        )

        // Run start: the linked thread joins the active set -> count 0 -> 1.
        vm.activeThreadIDsOverrideForTesting = [thread.id, otherThread.id]
        XCTAssertEqual(
            vm.activeBotCount, 2,
            "each bot whose linked thread starts running must count as active"
        )
        XCTAssertEqual(vm.attentionState(for: bot), .needsAttention,
                       "a live run must preserve its pending approval marker")
        XCTAssertEqual(vm.activityState(for: bot), .working,
                       "a live run must paint the avatar spinner over pending attention")
        XCTAssertEqual(vm.activityState(for: otherBot), .working,
                       "a nonselected bot's live run must update its avatar projection")

        // Run end: both threads leave the active set -> count back to 0.
        vm.activeThreadIDsOverrideForTesting = []
        XCTAssertEqual(
            vm.activeBotCount, 0,
            "bots whose linked runs finished must leave the active count"
        )
        XCTAssertEqual(vm.attentionState(for: bot), .needsAttention,
                       "completed run must retain pending approval state")
        XCTAssertNotEqual(vm.activityState(for: bot), .working,
                          "a completed run must stop painting the avatar as working")
        XCTAssertNotEqual(vm.activityState(for: otherBot), .working,
                          "a nonselected bot's completed run must stop its avatar spinner")
    }

    func test_reloadDoesNotRestoreTheSameDeskTwice_becauseRemountsRepeatTheReads() throws {
        // WHY (perf BT-12): reload() ran reloadSelectedBot before and after
        // reloadFleet; when the selected bot and conversation are unchanged the
        // second pass repeated the desk restore reads (messages, work log, live
        // turn, inspector support) for nothing on every remount.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)

        let before = vm.reloadSelectedBotCountForTesting
        vm.reload()
        XCTAssertEqual(
            vm.reloadSelectedBotCountForTesting - before, 1,
            "a remount that keeps the same bot and conversation must restore the desk once"
        )

        // Switching to a different bot must still restore that bot's desk.
        let quinn = try vm.create(name: "Quinn", title: "Reviewer")
        vm.openDesk(quinn)
        let beforeSwitch = vm.reloadSelectedBotCountForTesting
        vm.reload()
        XCTAssertEqual(
            vm.reloadSelectedBotCountForTesting - beforeSwitch, 1,
            "a remount after switching bots restores the newly selected bot's desk exactly once"
        )
    }

    func test_setPinnedStillSortsPinnedFirst_becauseStaleOrderMustNotLookCurrent() throws {
        // WHY: cache-first dest is honest only when Pin still jumps the
        // teammate to the top and Unpin puts them back with the live rows.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(quinn)
        vm.setPinned(id: piper.id, pinned: true)
        XCTAssertEqual(vm.fleet.first?.id, piper.id)
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first).pinned)
        vm.setPinned(id: piper.id, pinned: false)
        XCTAssertFalse(try XCTUnwrap(vm.fleet.first { $0.id == piper.id }).pinned)
        XCTAssertEqual(vm.fleet.first?.id, quinn.id)
    }

    func test_rosterPinShowsOnTheRow_becausePinMustNotBeASilentSort() throws {
        // WHY: Pin already sorts the fleet. Without a pin mark the user cannot
        // tell a pinned teammate from whoever happens to be first.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.setPinned(id: piper.id, pinned: true)
        XCTAssertEqual(vm.fleet.first?.id, piper.id)
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first).pinned)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("row.pinned"))
        XCTAssertTrue(source.contains("pin.fill"))
        XCTAssertTrue(
            source.contains("row.pinned ? \"Pinned. \""),
            "VoiceOver must hear Pinned so Pin is not sort-only"
        )
    }

    func test_rosterHiddenShowsOnTheRow_becauseShowHiddenMustNotLookLikeLiveTeammates() throws {
        // WHY: Show hidden puts hidden teammates back on the list. Without a
        // Hidden mark they look live, so Unhide is the only way to tell.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.setHidden(id: piper.id, hidden: true)
        vm.showHidden = true
        XCTAssertEqual(vm.fleet.first?.id, piper.id)
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first).hidden)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("row.hidden"))
        XCTAssertTrue(source.contains("eye.slash"))
        XCTAssertTrue(
            source.contains("row.hidden ? \"Hidden. \""),
            "VoiceOver must hear Hidden so Show hidden is not a silent list"
        )
    }

    func test_beginCreateDoesNotReloadFleet_becauseNewTeammateMustNotScanEveryRow() throws {
        // WHY: New Agent dest used to reloadFleet (every teammate's
        // conversations + recent messages) before Chat could paint. The
        // store already returned the row; dest inserts it locally.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let afterPiper = vm.fleetReloadCountForTesting
        XCTAssertGreaterThan(afterPiper, 0)
        vm.beginCreate()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).name, "New Agent")
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == vm.selectedBotID }))
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterPiper,
            "create dest must not rescan the fleet"
        )
    }

    func test_duplicateFromRosterDoesNotReloadFleet_becauseCopyDestMustNotScanEveryRow() throws {
        // WHY: roster copy dest used to reloadFleet before Chat painted.
        // The store already returned the copy; dest must not list every row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let afterPiper = vm.fleetReloadCountForTesting
        vm.duplicateFromRoster(piper)
        let copy = try XCTUnwrap(vm.selectedBot)
        XCTAssertNotEqual(copy.id, piper.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterPiper,
            "copy dest must not rescan the fleet"
        )
    }

    func test_duplicateFromRosterKeepsSourceAndCopy_becauseStaleRosterMustNotHideTheNewTeammate() throws {
        // WHY: cache-first dest is honest only when the new teammate
        // appears in the roster and the source row stays put.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.duplicateFromRoster(piper)
        let copy = try XCTUnwrap(vm.selectedBot)
        XCTAssertNotEqual(copy.id, piper.id)
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == copy.id }))
        XCTAssertEqual(vm.rosterPreview(for: piper), "Scout")
        XCTAssertEqual(vm.rosterPreview(for: copy), "Scout")
    }

    func test_openAttentionShowsConversationWithoutResolvingItsRequest() throws {
        // WHY: clicking an Attention row used to acknowledge and list the
        // queue before dest. Chat must paint first; store work follows.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        XCTAssertEqual(vm.screen, .studio)
        vm.send("Please look at the failing test")
        let item = try XCTUnwrap(context.botStore.listAttention().first)
        vm.openAttention(item)
        XCTAssertEqual(try context.botStore.listAttention().map(\.id), [item.id],
                       "Opening the conversation must not resolve the request")
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
    }

    func test_explicitAcknowledgementResolvesAttentionAfterOpening() throws {
        // WHY: dest-first dest is honest only when the inbox item is still
        // marked read after Chat paints.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.send("Please look at the failing test")
        let item = try XCTUnwrap(context.botStore.listAttention().first)
        vm.openAttention(item)
        XCTAssertEqual(vm.openAttentionCount, 1, "Opening alone is not resolution")
        vm.acknowledge(item)
        XCTAssertTrue(vm.attentionItems.isEmpty)
        XCTAssertEqual(try context.botStore.listAttention().count, 0)
    }

    func test_openAttentionDoesNotListInbox_becauseAcknowledgeDestMustNotRereadQueue() throws {
        // WHY: Acknowledge dest used to listAttention after dest already
        // painted Chat. Dest already has this inbox row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.send("Please look at the failing test")
        let item = try XCTUnwrap(context.botStore.listAttention().first)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.openAttention(item)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "acknowledge dest must not reread the inbox"
        )
    }

    func test_explicitAcknowledgementClearsTheBellAndKeepsTheConversation() throws {
        // WHY: dest-first acknowledge is honest only when dest still
        // hides this row after the store write.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.send("Please look at the failing test")
        let item = try XCTUnwrap(context.botStore.listAttention().first)
        XCTAssertEqual(vm.openAttentionCount, 1)
        vm.openAttention(item)
        XCTAssertEqual(vm.openAttentionCount, 1, "Opening alone is not resolution")
        vm.acknowledge(item)
        XCTAssertTrue(vm.attentionItems.isEmpty)
        XCTAssertEqual(vm.openAttentionCount, 0)
        XCTAssertEqual(try context.botStore.listAttention().count, 0)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
    }

    func test_openAttentionDoesNotListInbox_becauseBellDestMustNotRereadQueue() throws {
        // WHY: Bell dest used to listAttention (and then list every
        // teammate's conversations) before dest dested Chat. Dest
        // already has dest inbox from send dest.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.send("Please look at the failing test")
        XCTAssertEqual(vm.openAttentionCount, 1)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.openAttention()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "bell dest must not reread the inbox"
        )
        XCTAssertEqual(vm.openAttentionCount, 1, "opening the request does not resolve it")
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
    }

    func test_emptyAttentionStaysOnStudio_becauseTheBellIsNotADestWhenNothingNeedsYou() throws {
        // WHY: Home/Attention is gone. openAttention with an empty queue
        // used to call openDesk and yank the user out of Studio.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.openAttentionCount, 0)
        vm.openAttention()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_activeBotCountCountsWorkingOnly_notNeedsYou() throws {
        // WHY: Active Threads counts live runs. Active Bots used to mix
        // working + needs-you, so the badge said 2 while only one bot ran.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "live turn", attentionState: .working)
        )
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: quinn.id, kind: .approval, title: "Need you")
        )
        vm.reload()
        XCTAssertEqual(vm.attentionState(for: piper), .working)
        XCTAssertEqual(vm.attentionState(for: quinn), .needsAttention)
        XCTAssertEqual(vm.activeBotCount, 1)
        XCTAssertEqual(vm.liveWorkingBots().map(\.id), [piper.id])
    }

    func test_openActiveBotsOpensActiveBotsScreen() throws {
        // WHY: Active Threads opens an overview. Active Bots must not jump
        // to a needs-you Desk when the user asked for the live roster.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "live turn", attentionState: .working)
        )
        vm.reload()
        vm.openActiveBots()
        XCTAssertEqual(vm.screen, .activeBots)
        XCTAssertEqual(vm.activeBotItems.map(\.botID), [piper.id])
        XCTAssertEqual(vm.activeBotsSubtitle, "1 bot is running")
    }

    func test_deferredActiveBotsAppearanceAndTabCoalesce_onNextMainTurn() async throws {
        // WHY: ActiveBotsRootView used to synchronously scan active and
        // finished rows on appearance, then repeat the same work for a tab
        // change before the deferred main-actor turn could begin.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        _ = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.enableNavigationFirstFrameDeferral()

        let beforeNavigation = vm.activeBotsHydrationCountForTesting
        vm.openActiveBots()
        vm.scheduleActiveBotsFreshness() // ActiveBotsRootView.onAppear
        vm.activeBotsTab = .lastFinished
        vm.scheduleActiveBotsFreshness() // ActiveBotsRootView.onChange

        XCTAssertEqual(
            vm.activeBotsHydrationCountForTesting,
            beforeNavigation,
            "appearance and tab selection must do zero synchronous hydration"
        )
        await vm.waitForNavigationFreshnessForTesting()
        XCTAssertEqual(
            vm.activeBotsHydrationCountForTesting,
            beforeNavigation + 1,
            "generation coalescing must leave exactly one deferred hydration pass"
        )
        XCTAssertEqual(vm.screen, .activeBots)
        XCTAssertEqual(vm.activeBotsTab, .lastFinished)

        let beforeDestinationChange = vm.activeBotsHydrationCountForTesting
        vm.scheduleActiveBotsFreshness()
        vm.screen = .desk
        await vm.waitForNavigationFreshnessForTesting()
        XCTAssertEqual(
            vm.activeBotsHydrationCountForTesting,
            beforeDestinationChange,
            "a stale Active Bots task must not hydrate after the destination changes"
        )

        var didLeaveBots = false
        vm.onLeaveBots = { didLeaveBots = true }
        vm.openActiveBots()
        let beforeLeave = vm.activeBotsHydrationCountForTesting
        vm.requestLeaveBotsMode()
        await vm.waitForNavigationFreshnessForTesting()
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(didLeaveBots)
        XCTAssertEqual(
            vm.activeBotsHydrationCountForTesting,
            beforeLeave,
            "leaving for Workspaces must invalidate offscreen Active Bots hydration"
        )
    }

    func test_reloadActiveBotsScreenNoopsWhenScreenIsDesk() throws {
        // WHY: Active Bots hydration is a SQLite pass. Desk must not pay it
        // when a run-status broadcast asks to refresh the offscreen roster.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        XCTAssertEqual(vm.screen, .desk)
        let before = vm.activeBotsHydrationCountForTesting
        vm.reloadActiveBotsScreen()
        XCTAssertEqual(vm.activeBotsHydrationCountForTesting, before)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_handoffDeltaHydratesActiveBotsOnce_becauseOneDeltaIsOneTurn() async throws {
        // WHY: a peer-handoff delta carries both conversations, and the
        // observer settled each one with its own attention state — so a single
        // publish paid two full Active Bots roster passes (liveWorkingBots +
        // listRecentFinished) on the main actor with no run-loop turn between
        // them. Both states must still land; the roster must hydrate once.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.createDeskThread())
        let origin = try XCTUnwrap(vm.selectedConversation)

        vm.openActiveBots()
        XCTAssertEqual(vm.screen, .activeBots)
        vm.reconcilePeerHandoffsForTesting()
        let before = vm.activeBotsHydrationCountForTesting

        // The publish inside this call is synchronous, so the count read below
        // sees exactly the delta's own hydration — no async run-status traffic.
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) check the inbox"
        )

        // Fixture: the delta really carried two conversations and both rows
        // exist, so the observer's per-conversation pass was not a no-op.
        let snapshot = try XCTUnwrap(
            vm.peerHandoffSnapshotsForTesting(originConversationID: origin.id).first
        )
        XCTAssertNotNil(try? context.botStore.conversation(id: origin.id))
        XCTAssertNotNil(try? context.botStore.conversation(id: snapshot.peerConversationID))
        XCTAssertEqual(snapshot.peerBotID, quinn.id)

        XCTAssertEqual(
            vm.activeBotsHydrationCountForTesting,
            before + 1,
            "one handoff delta must hydrate Active Bots once, not once per conversation"
        )

        let peerStarted = await waitUntil(timeout: 5) { !peerRunner.requests.isEmpty }
        XCTAssertTrue(peerStarted)
        if let peerRunID = peerRunner.requests.first?.runId {
            _ = peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil)
        }
        await milestone.value
    }

    func test_deskSendIntoActiveBotsHydratesOncePerTurn_becauseThePersistAlreadyReloaded() async throws {
        // WHY: the persisted working conversation settles the bot's attention
        // state, and that already hydrates Active Bots while the roster is up —
        // the next line hydrated it a second time. One synchronous turn paid two
        // full roster passes (liveWorkingBots + listRecentFinished) for one row.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)

        vm.openActiveBots()
        XCTAssertEqual(vm.screen, .activeBots)
        let before = vm.activeBotsHydrationCountForTesting

        _ = try vm.enqueueHostMessage(
            botID: bot.id,
            text: "go",
            conversationID: nil,
            routing: BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        )

        let started = await waitUntil(timeout: 5) { vm.lastSendStartedProviderRun }
        XCTAssertTrue(started, "fixture: the send really reached the provider")
        // One pass for the run-status broadcast, one for the persisted working
        // conversation. Nothing else touches the roster before the run settles.
        XCTAssertEqual(
            vm.activeBotsHydrationCountForTesting,
            before + 2,
            "a desk send into Active Bots must hydrate the roster once per turn, not twice for the persist"
        )

        if let runID = runner.requests.first?.runId {
            _ = runner.finish(runID: runID, status: .cancelled, reply: nil)
        }
    }

    func test_didChangeStatusSkipsConversationLinkedWhenThreadHasNoBot() async throws {
        // WHY: every agent thread broadcasts status. Threads with no bot must
        // not hit SQLite conversationLinked or reload Active Bots.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let before = context.botStore.conversationLinkedQueryCountForTesting
        let hydration = vm.activeBotsHydrationCountForTesting
        vm.runCoordinator(
            context.coordinator,
            didChangeStatus: .running,
            runId: AgentRunID(),
            threadId: AgentThreadID()
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(context.botStore.conversationLinkedQueryCountForTesting, before)
        XCTAssertEqual(vm.activeBotsHydrationCountForTesting, hydration)
    }

    func test_openActiveBotItemOpensDesk() throws {
        // WHY: a row on the Active Bots screen must dest that teammate's
        // Desk, same as opening an Active Threads row dests the thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "live turn", attentionState: .working)
        )
        vm.reload()
        vm.openActiveBots()
        let item = try XCTUnwrap(vm.activeBotItems.first)
        vm.openActiveBotItem(item)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_liveWorkingBotsIncludesLinkedActiveRun() throws {
        // WHY: Active Threads counts coordinator live threads. A bot whose
        // conversation is not flagged .working must still appear when its
        // linked agent thread is actually running.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let idle = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.botStore.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Standup",
                attentionState: .none,
                linkedAgentThreadID: thread.id
            )
        )
        vm.reload()
        XCTAssertEqual(vm.attentionState(for: piper), .none)
        XCTAssertTrue(vm.liveWorkingBots().isEmpty)
        vm.activeThreadIDsOverrideForTesting = [thread.id]
        XCTAssertEqual(vm.liveWorkingBots().map(\.id), [piper.id])
        XCTAssertFalse(vm.liveWorkingBots().contains(where: { $0.id == idle.id }))
        XCTAssertEqual(vm.activeBotCount, 1)
        vm.openActiveBots()
        XCTAssertEqual(vm.activeBotItems.map(\.botID), [piper.id])
        XCTAssertEqual(vm.activeBotItems.first?.nextRunLabel, "Running now")
        XCTAssertNotEqual(vm.activeBotItems.first?.lastTriggeredLabel, "")
    }

    func test_activeBotsSearchFiltersLiveRoster() throws {
        // WHY: Scheduled Tasks search hides non-matches. Active Bots must
        // filter the live roster the same way, not keep showing every runner.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let piperThread = AgentThread(title: "Piper live", provider: .claude, model: "opus")
        let quinnThread = AgentThread(title: "Quinn live", provider: .claude, model: "opus")
        try context.threadRepo.upsert(piperThread)
        try context.threadRepo.upsert(quinnThread)
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "live turn", linkedAgentThreadID: piperThread.id)
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: quinn.id, title: "other turn", linkedAgentThreadID: quinnThread.id)
        )
        vm.activeThreadIDsOverrideForTesting = [piperThread.id, quinnThread.id]
        vm.reload()
        vm.openActiveBots()
        XCTAssertEqual(Set(vm.filteredActiveBotItems().map(\.botID)), [piper.id, quinn.id])
        vm.activeBotsSearchText = "piper"
        XCTAssertEqual(vm.filteredActiveBotItems().map(\.botID), [piper.id])
        vm.activeBotsSearchText = "no-such-bot"
        XCTAssertTrue(vm.filteredActiveBotItems().isEmpty)
    }

    func test_activeAndFinishedBots_batchLinkedConversations_withoutChangingOrderOrStatus() throws {
        // WHY: opening Active Bots must not issue one SQLite lookup per active
        // or recent run, while the projected links and finished-run ordering
        // remain identical to the durable run roster.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .grok)
        let active = AgentThread(title: "Active", provider: .grok, model: "test")
        let finishedNewer = AgentThread(title: "Newer", provider: .grok, model: "test")
        let finishedOlder = AgentThread(title: "Older", provider: .grok, model: "test")
        let finishedOldest = AgentThread(title: "Oldest", provider: .grok, model: "test")
        let unlinked = AgentThread(title: "Unlinked", provider: .grok, model: "test")
        for thread in [active, finishedNewer, finishedOlder, finishedOldest, unlinked] {
            try context.threadRepo.upsert(thread)
        }
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Active", linkedAgentThreadID: active.id)
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Newer", linkedAgentThreadID: finishedNewer.id)
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: quinn.id, title: "Older", linkedAgentThreadID: finishedOlder.id)
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: quinn.id, title: "Oldest", linkedAgentThreadID: finishedOldest.id)
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try context.runRepo.upsert(AgentRun(
            threadId: active.id,
            provider: .grok,
            model: "test",
            status: .running,
            startedAt: now
        ))
        try context.runRepo.upsert(AgentRun(
            threadId: finishedOlder.id,
            provider: .grok,
            model: "test",
            status: .completed,
            startedAt: now.addingTimeInterval(-30),
            finishedAt: now.addingTimeInterval(-20)
        ))
        try context.runRepo.upsert(AgentRun(
            threadId: finishedOldest.id,
            provider: .grok,
            model: "test",
            status: .completed,
            startedAt: now.addingTimeInterval(-40),
            finishedAt: now.addingTimeInterval(-30)
        ))
        try context.runRepo.upsert(AgentRun(
            threadId: finishedNewer.id,
            provider: .grok,
            model: "test",
            status: .failed,
            startedAt: now.addingTimeInterval(-20),
            finishedAt: now.addingTimeInterval(-10)
        ))
        try context.runRepo.upsert(AgentRun(
            threadId: unlinked.id,
            provider: .grok,
            model: "test",
            status: .completed,
            startedAt: now.addingTimeInterval(-10),
            finishedAt: now
        ))
        vm.activeThreadIDsOverrideForTesting = [active.id]
        vm.setHidden(id: quinn.id, hidden: true)

        var singleLookupSteps = 0
        var singleBotLookupSteps = 0
        var batchSQL = Set<String>()
        var botBatchSQL = Set<String>()
        context.db.beforeStatementStepForTesting = { sql in
            if sql.contains("WHERE linked_agent_thread_id = ? LIMIT 1") {
                singleLookupSteps += 1
            }
            if sql.contains("FROM bots"), sql.contains("WHERE id = ? LIMIT 1") {
                singleBotLookupSteps += 1
            }
            if sql.contains("WHERE linked_agent_thread_id IN (") {
                batchSQL.insert(sql)
            }
            if sql.contains("FROM bots"), sql.contains("WHERE id IN (") {
                botBatchSQL.insert(sql)
            }
        }
        vm.openActiveBots()
        context.db.beforeStatementStepForTesting = nil

        XCTAssertEqual(singleLookupSteps, 0)
        XCTAssertEqual(singleBotLookupSteps, 0, "repeated hidden finished bots must not issue per-run gets")
        XCTAssertEqual(batchSQL.count, 2, "active and finished projections each use one batched SQL shape")
        XCTAssertEqual(botBatchSQL.count, 1, "the missing hidden roster entry is prefetched once")
        XCTAssertEqual(vm.activeBotItems.map(\.botID), [piper.id])
        XCTAssertEqual(vm.finishedBotItems.map(\.botID), [piper.id, quinn.id, quinn.id])
        XCTAssertEqual(vm.finishedBotItems.map(\.status), [.failed, .completed, .completed])
        XCTAssertEqual(vm.finishedBotItems.map(\.title), ["Piper", "Quinn", "Quinn"])
    }

    func test_activeBots_batchColdStartedAt_withoutChangingLatestConversationTimestamp() throws {
        // WHY: a cold Active Bots screen has no lastUpdated cache. Computing
        // startedAt must not list every conversation once per active Bot, and
        // must still choose the exact newest conversation timestamp per Bot.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var activeThreadIDs = Set<AgentThreadID>()
        var expectedStartedAt: [BotID: Date] = [:]
        for index in 0..<10 {
            let bot = try vm.create(name: "Bot \(index)", title: "Worker")
            let thread = AgentThread(title: "Active \(index)", provider: .grok, model: "test")
            try context.threadRepo.upsert(thread)
            activeThreadIDs.insert(thread.id)
            let latest = base.addingTimeInterval(Double(index * 10))
            try context.botStore.upsertConversation(BotConversation(
                botID: bot.id,
                title: "Older \(index)",
                createdAt: latest.addingTimeInterval(-1_000),
                updatedAt: latest.addingTimeInterval(-1_000)
            ))
            try context.botStore.upsertConversation(BotConversation(
                botID: bot.id,
                title: "Active \(index)",
                linkedAgentThreadID: thread.id,
                createdAt: latest,
                updatedAt: latest
            ))
            expectedStartedAt[bot.id] = try XCTUnwrap(
                context.botStore.listConversations(botID: bot.id).first?.updatedAt
            )
        }
        vm.activeThreadIDsOverrideForTesting = activeThreadIDs

        var singleConversationListSteps = 0
        var latestBatchSQL = Set<String>()
        context.db.beforeStatementStepForTesting = { sql in
            if sql.contains("WHERE bot_id = ? ORDER BY updated_at DESC") {
                singleConversationListSteps += 1
            }
            if sql.contains("SELECT bot_id, MAX(updated_at)"), sql.contains("WHERE bot_id IN (") {
                latestBatchSQL.insert(sql)
            }
        }
        vm.openActiveBots()
        context.db.beforeStatementStepForTesting = nil

        XCTAssertEqual(singleConversationListSteps, 0)
        XCTAssertEqual(latestBatchSQL.count, 1)
        XCTAssertEqual(vm.activeBotItems.count, 10)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: vm.activeBotItems.compactMap { item in
                item.startedAt.map { (item.botID, $0) }
            }),
            expectedStartedAt
        )
    }

    func test_activeBots_batchOnlyActiveHandoffOrigins_withoutScanningHistoricalRows() throws {
        // WHY: the durable handoff snapshot retains terminal history. Opening
        // Active Bots must discard that history before SQLite, batch only live
        // origin existence checks, and preserve phase/orphan membership.
        let context = try makeContext()
        _ = context.botPeerHandoffAuthority
        let origin = try context.botStore.create(
            name: "Origin", title: "Controller", description: "", provider: .grok
        )
        let peer = try context.botStore.create(
            name: "Peer", title: "Worker", description: "", provider: .grok
        )
        let hostOnlyOrigin = try context.botStore.create(
            name: "Host", title: "Synthesizer", description: "", provider: .grok
        )
        let hostOnlyPeer = try context.botStore.create(
            name: "Finished Peer", title: "Worker", description: "", provider: .grok
        )
        let legacyOrigin = try context.botStore.create(
            name: "Legacy Origin", title: "Controller", description: "", provider: .grok
        )
        let legacyPeer = try context.botStore.create(
            name: "Legacy Peer", title: "Worker", description: "", provider: .grok
        )
        let orphanOrigin = try context.botStore.create(
            name: "Orphan Origin", title: "Controller", description: "", provider: .grok
        )
        let orphanPeer = try context.botStore.create(
            name: "Orphan Peer", title: "Worker", description: "", provider: .grok
        )
        let historicalOrigin = try context.botStore.create(
            name: "Historical Origin", title: "Controller", description: "", provider: .grok
        )
        let historicalPeer = try context.botStore.create(
            name: "Historical Peer", title: "Worker", description: "", provider: .grok
        )
        let route = T005PeerHandoffRouteFixture(
            provider: .grok,
            providerInstanceID: nil,
            model: "test",
            permissionMode: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            runAsUser: AgentRunAsUser(
                generatedUID: "active-handoff-batch",
                shortName: "fixture",
                uid: 0,
                gid: 0,
                homePath: "/tmp/active-handoff-batch"
            ),
            routingConfiguration: nil
        )
        func record(
            originBotID: BotID?,
            originConversationID: BotConversationID?,
            peerBotID: BotID,
            phase: BotPeerHandoffPhase,
            index: Int
        ) -> T005PeerHandoffRecordFixture {
            let activityID = UUID()
            return T005PeerHandoffRecordFixture(
                version: 2,
                activityID: activityID,
                originBotID: originBotID,
                originConversationID: originConversationID,
                originAgentThreadID: nil,
                peerBotID: peerBotID,
                peerConversationID: BotConversationID(),
                peerThreadID: nil,
                peerRunID: nil,
                inboundMessageID: activityID,
                peerName: "Peer \(index)",
                peerTitle: "Worker",
                peerHandle: "peer-\(index)",
                outboundText: "handoff \(index)",
                createdAt: Date(timeIntervalSinceReferenceDate: Double(index)),
                peerRoute: route,
                hostThreadID: nil,
                hostRunID: nil,
                hostRoute: nil,
                replyText: nil,
                replyCreatedAt: nil,
                phase: phase
            )
        }

        var rows: [UUID: T005PeerHandoffRecordFixture] = [:]
        for index in 0..<200 {
            let conversation = BotConversation(
                botID: origin.id,
                title: "Active peer \(index)"
            )
            try context.botStore.upsertConversation(conversation)
            let handoff = record(
                originBotID: origin.id,
                originConversationID: conversation.id,
                peerBotID: peer.id,
                phase: .peerRunning,
                index: index
            )
            rows[handoff.activityID] = handoff
        }
        let hostConversation = BotConversation(botID: hostOnlyOrigin.id, title: "Active host")
        try context.botStore.upsertConversation(hostConversation)
        let hostHandoff = record(
            originBotID: hostOnlyOrigin.id,
            originConversationID: hostConversation.id,
            peerBotID: hostOnlyPeer.id,
            phase: .hostRunning,
            index: 200
        )
        rows[hostHandoff.activityID] = hostHandoff
        let legacyHandoff = record(
            originBotID: legacyOrigin.id,
            originConversationID: nil,
            peerBotID: legacyPeer.id,
            phase: .peerPrepared,
            index: 201
        )
        rows[legacyHandoff.activityID] = legacyHandoff
        let orphanHandoff = record(
            originBotID: orphanOrigin.id,
            originConversationID: BotConversationID(),
            peerBotID: orphanPeer.id,
            phase: .peerRunning,
            index: 202
        )
        rows[orphanHandoff.activityID] = orphanHandoff
        for index in 0..<500 {
            let handoff = record(
                originBotID: historicalOrigin.id,
                originConversationID: BotConversationID(),
                peerBotID: historicalPeer.id,
                phase: index.isMultiple(of: 2) ? .completed : .needsAttention,
                index: 1_000 + index
            )
            rows[handoff.activityID] = handoff
        }
        let payload = try JSONEncoder().encode(rows)
        UserDefaults.standard.set(payload, forKey: "bots.peerTurns.v2")
        try context.settingsRepo.set(
            "bots.peerTurns.v2",
            "base64:\(payload.base64EncodedString())"
        )
        _ = context.botPeerHandoffAuthority.delegatedBotID(forHostRunID: AgentRunID())
        let vm = BotsViewModel(context: context)
        let restoredHandoffs = vm.peerHandoffSnapshotsForTesting()
        XCTAssertEqual(restoredHandoffs.count, rows.count)
        XCTAssertEqual(restoredHandoffs.filter { $0.phase == .peerRunning }.count, 201)
        XCTAssertEqual(restoredHandoffs.filter { $0.phase == .hostRunning }.count, 1)
        XCTAssertEqual(restoredHandoffs.filter { $0.phase == .completed }.count, 250)
        XCTAssertEqual(restoredHandoffs.filter { $0.phase == .needsAttention }.count, 250)

        var singleConversationSteps = 0
        var originBatchSQL = Set<String>()
        context.db.beforeStatementStepForTesting = { sql in
            if sql.contains("FROM bot_conversations"), sql.contains("WHERE id = ? LIMIT 1") {
                singleConversationSteps += 1
            }
            if sql.contains("FROM bot_conversations"), sql.contains("WHERE id IN (") {
                originBatchSQL.insert(sql)
            }
        }
        vm.openActiveBots()
        context.db.beforeStatementStepForTesting = nil

        XCTAssertEqual(singleConversationSteps, 0, "historical and active handoffs must not point-query")
        XCTAssertEqual(originBatchSQL.count, 2, "202 live origin IDs must use bounded chunks")
        XCTAssertEqual(originBatchSQL.map { $0.filter { $0 == "?" }.count }.max(), 200)
        XCTAssertEqual(
            Set(vm.activeBotItems.map(\.botID)),
            [origin.id, peer.id, hostOnlyOrigin.id, legacyOrigin.id, legacyPeer.id]
        )
        XCTAssertFalse(vm.activeBotItems.map(\.botID).contains(hostOnlyPeer.id))
        XCTAssertFalse(vm.activeBotItems.map(\.botID).contains(orphanOrigin.id))
        XCTAssertFalse(vm.activeBotItems.map(\.botID).contains(orphanPeer.id))
        XCTAssertFalse(vm.activeBotItems.map(\.botID).contains(historicalOrigin.id))
        XCTAssertFalse(vm.activeBotItems.map(\.botID).contains(historicalPeer.id))
    }

    func test_activeBotItemsClearWhenRunFinishes_becauseChipMustMatchFooter() throws {
        // WHY: Computer Use saw Active chip "1" while the footer said
        // "0 active" after a mention hop finished. The chip reads cached
        // activeBotItems; the footer reads liveWorkingBots(). Follow-through
        // must refresh that cache so chip, list, and footer agree.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let live = BotConversation(botID: piper.id, title: "live turn", attentionState: .working)
        try context.botStore.upsertConversation(live)
        vm.reload()
        vm.openActiveBots()
        XCTAssertEqual(vm.screen, .activeBots)
        XCTAssertEqual(vm.activeBotCount, 1)
        XCTAssertEqual(vm.filteredActiveBotItems().map(\.botID), [piper.id])
        XCTAssertEqual(vm.filteredActiveBotItems().count, vm.activeBotCount)

        vm.applyFollowThroughForTests(bot: piper, conversation: live, status: .completed)
        XCTAssertEqual(vm.attentionState(for: piper), .unreadActivity)
        XCTAssertEqual(vm.activeBotCount, 0)
        XCTAssertTrue(
            vm.filteredActiveBotItems().isEmpty,
            "Active chip/list must drop the finished bot without reopening the tab"
        )
        XCTAssertEqual(vm.filteredActiveBotItems().count, vm.activeBotCount)
        XCTAssertEqual(vm.activeBotsFooterLine.hasPrefix("0 active"), true)
    }

    func test_staleWorkingConversationSettlesWhenLinkedRunIsTerminal() throws {
        // WHY: Computer Use saw Piper Working + Active Bots 1 after the
        // work log said Done and no provider process was alive. Persist
        // working survived relaunch because didFinish only refreshed the
        // chip from that stale flag. Reload must settle the row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        let thread = AgentThread(title: "Night scan", provider: .grok, model: "grok-4.6")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "grok-4.6",
            status: .completed,
            startedAt: Date().addingTimeInterval(-120),
            finishedAt: Date().addingTimeInterval(-30)
        )
        try context.runRepo.upsert(run)
        try context.botStore.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Night scan",
                attentionState: .working,
                linkedAgentThreadID: thread.id
            )
        )
        let reopened = BotsViewModel(context: context)
        reopened.openDesk(piper)
        XCTAssertEqual(reopened.deskWorkLog.first?.statusLabel, "Done")
        XCTAssertNotEqual(reopened.attentionState(for: piper), .working)
        XCTAssertEqual(reopened.activeBotCount, 0)
        reopened.openActiveBots()
        XCTAssertTrue(reopened.filteredActiveBotItems().isEmpty)
        XCTAssertEqual(
            try context.botStore.listConversations(botID: piper.id).first?.attentionState,
            BotAttentionState.none
        )
    }

    func test_didFinishAppliesFollowThrough_soActiveChipDrops() throws {
        // WHY: followLinkedRun is cancelled on dest switch and process
        // death. didFinish used to reload Active Bots without leaving
        // .working, so the chip stayed at 1 after Done.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        let thread = AgentThread(title: "Night scan", provider: .grok, model: "grok-4.6")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "grok-4.6",
            status: .completed,
            finishedAt: Date()
        )
        try context.runRepo.upsert(run)
        try context.botStore.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Night scan",
                attentionState: .working,
                linkedAgentThreadID: thread.id
            )
        )
        vm.adoptLinkedRunTerminalForTests(runId: run.id, threadId: thread.id)
        XCTAssertNotEqual(vm.attentionState(for: piper), .working)
        XCTAssertEqual(vm.activeBotCount, 0)
        XCTAssertEqual(
            try context.botStore.listConversations(botID: piper.id).first?.attentionState,
            BotAttentionState.none
        )
    }

    func test_terminalDeliveredTwiceRefreshesActiveBotCountOnce_becauseTheSecondCallbackIsADuplicate() async throws {
        // WHY (perf BT-28): `didChangeStatus(terminal)` and `didFinish` deliver
        // the same terminal. `adoptLinkedRunTerminal` already dedupes the
        // settle (BT-24), but the refresh that followed re-ran
        // `liveWorkingBots()` — two roster SQLite queries plus the coordinator
        // lock — for the duplicate callback.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        let thread = AgentThread(title: "Night scan", provider: .grok, model: "grok-4.6")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "grok-4.6",
            status: .running
        )
        try context.runRepo.upsert(run)
        try context.botStore.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Night scan",
                attentionState: .working,
                linkedAgentThreadID: thread.id
            )
        )
        vm.openDesk(piper)
        XCTAssertEqual(
            vm.attentionState(for: piper), .working,
            "fixture: the terminal callback must have a live Working row to settle"
        )
        XCTAssertEqual(
            vm.followThroughApplyCountForTesting, 0,
            "fixture: no terminal settle may run before the terminal is persisted"
        )

        // The coordinator persists the terminal row first, then broadcasts the
        // two callbacks for the same run.
        var terminal = run
        terminal.status = .completed
        terminal.finishedAt = Date()
        try context.runRepo.upsert(terminal)

        let baseline = vm.liveWorkingBotsCountForTesting
        vm.runCoordinator(
            context.coordinator,
            didChangeStatus: .completed,
            runId: run.id,
            threadId: thread.id
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterFirst = vm.liveWorkingBotsCountForTesting
        XCTAssertGreaterThan(
            afterFirst, baseline,
            "fixture: the first terminal callback must refresh the live roster"
        )
        XCTAssertNotEqual(
            vm.attentionState(for: piper), .working,
            "fixture: the first callback must settle the terminal, not bounce off the dedupe"
        )

        vm.runCoordinator(
            context.coordinator,
            didFinish: run.id,
            threadId: thread.id,
            status: .completed,
            finalMessage: nil,
            providerThreadId: nil
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            vm.followThroughApplyCountForTesting, 1,
            "fixture: the second callback is the same terminal, not a second settle"
        )
        XCTAssertEqual(
            vm.liveWorkingBotsCountForTesting, afterFirst,
            "the duplicate terminal callback must not re-run the Active Bots roster queries"
        )
    }

    func test_workingConversationStaysLiveWhenLinkedRunIsRunning() throws {
        // WHY: settle must not drop a teammate whose provider turn is
        // still running. Only a terminal linked run clears Working.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        let thread = AgentThread(title: "Night scan", provider: .grok, model: "grok-4.6")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "grok-4.6",
            status: .running
        ))
        try context.botStore.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Night scan",
                attentionState: .working,
                linkedAgentThreadID: thread.id
            )
        )
        vm.openDesk(piper)
        XCTAssertEqual(vm.attentionState(for: piper), .working)
        XCTAssertEqual(vm.activeBotCount, 1)
        XCTAssertEqual(vm.deskWorkLog.first?.statusLabel, "Working")
    }

    func test_refreshPublishedIdentityPicksUpSelfConfigTitle() throws {
        // WHY: bot_set_settings publishes through a sidecar SQLite write.
        // Desk kept the stale name/title until remount. After a self-edit
        // the header and roster must show the new identity without relaunch.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "CEO", title: "", provider: .grok)
        vm.openDesk(bot)
        XCTAssertEqual(vm.selectedBot?.title, "")
        let service = BotSelfConfigService(callerBotID: bot.id, store: context.botStore)
        _ = try service.apply(BotSelfConfigPatch(title: "CEO da empresa"))
        XCTAssertEqual(vm.selectedBot?.title, "", "in-memory roster stays stale until refresh")
        let fresh = try XCTUnwrap(vm.refreshPublishedIdentity(for: bot.id))
        XCTAssertEqual(fresh.title, "CEO da empresa")
        XCTAssertEqual(vm.selectedBot?.title, "CEO da empresa")
        XCTAssertEqual(vm.selectedRevision?.title, "CEO da empresa")
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(
            source.contains("refreshPublishedIdentity(for: botID)"),
            "live desk watch must refresh identity when the turn streams or finishes"
        )
    }

    func test_openScheduleTasksOpensBotsScheduleScreen() throws {
        // WHY: Bots Schedule Tasks used to open Agent scheduled tasks.
        // The row must dest the bots routines overview instead.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Check overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        vm.setRoutineEnabled(id: try XCTUnwrap(vm.routines.first?.definition.id), enabled: true)
        vm.openScheduleTasks()
        XCTAssertEqual(vm.screen, .scheduleTasks)
        XCTAssertEqual(vm.scheduleTaskItems.map(\.name), ["Morning scan"])
        XCTAssertEqual(vm.scheduleTaskFilterCounts.active, 1)
        XCTAssertEqual(vm.scheduleTasksSubtitle, "Automatic runs paused — turn Active on when you're back")
    }

    func test_enabledTaskNextRunSaysSchedulerPaused_whenAutonomyIsOff_becauseOpenDoesNotMeanItRuns() throws {
        // WHY: Computer Use saw Next run "While RemoteCode is open" while
        // the global switch read Schedules paused. An enabled task is armed,
        // not running, so Next run must say the scheduler is paused.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Check overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: id, enabled: true)
        vm.openScheduleTasks()
        XCTAssertFalse(vm.isAutonomyActive)
        let armed = try XCTUnwrap(vm.scheduleTaskItems.first)
        XCTAssertTrue(armed.isEnabled)
        XCTAssertEqual(
            armed.nextRunLabel(isAutonomyActive: vm.isAutonomyActive),
            "Scheduler paused"
        )
        vm.setAutonomyActive(true)
        XCTAssertEqual(
            armed.nextRunLabel(isAutonomyActive: vm.isAutonomyActive),
            "While MacCode is open"
        )
        vm.setRoutineEnabled(id: id, enabled: false)
        let paused = try XCTUnwrap(vm.scheduleTaskItems.first)
        XCTAssertEqual(paused.nextRunLabel(isAutonomyActive: true), "Paused")
    }

    func test_botScheduleTasksFiltersAndToggle() throws {
        // WHY: All / Active / Paused must filter shipped routines, not a
        // decorative count, so the overview matches Agent Scheduled Tasks.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Live"
        vm.routinePrompt = "Ping"
        vm.saveRoutine()
        let liveID = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: liveID, enabled: true)
        vm.routineName = "Paused"
        vm.routinePrompt = "Wait"
        vm.saveRoutine()
        vm.openScheduleTasks()
        XCTAssertEqual(vm.scheduleTaskFilterCounts.all, 2)
        XCTAssertEqual(vm.scheduleTaskFilterCounts.active, 1)
        XCTAssertEqual(vm.scheduleTaskFilterCounts.paused, 1)
        vm.scheduleTaskStatusFilter = .paused
        XCTAssertEqual(vm.scheduleTaskItems.map(\.name), ["Paused"])
        let paused = try XCTUnwrap(vm.scheduleTaskItems.first)
        vm.setRoutineEnabled(id: paused.id, enabled: true)
        vm.scheduleTaskStatusFilter = .active
        XCTAssertEqual(Set(vm.scheduleTaskItems.map(\.name)), ["Live", "Paused"])
        vm.setAutonomyActive(true)
        XCTAssertTrue(vm.isAutonomyActive)
    }

    func test_botScheduleEditorCopiesAgentAppFrequencyAndRouting() throws {
        // WHY: Bot Schedule Tasks used a free-text When field. Owners need
        // the Agent App Frequency + Provider / Model Auto / Reasoning rows.
        let source = try String(
            contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"),
            encoding: .utf8
        )
        // WHY: one shared Frequency editor owns the rows (and their ids) for both schedule editors.
        XCTAssertTrue(source.contains("ScheduledFrequencyEditor("))
        XCTAssertTrue(source.contains("identifierPrefix: \"bots.scheduleTasks.editor\""))
        let workspaceSource = try String(
            contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(workspaceSource.contains("ScheduledFrequencyEditor("))
        XCTAssertTrue(source.contains("bots.scheduleTasks.editor.provider"))
        XCTAssertTrue(source.contains("bots.scheduleTasks.editor.autoRouting"))
        XCTAssertTrue(source.contains("bots.scheduleTasks.editor.reasoning"))
        XCTAssertTrue(source.contains("struct BotScheduleSpecEditor"))
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.createScheduleTask()
        var draft = try XCTUnwrap(vm.scheduleTaskDraft)
        draft.name = "Morning scan"
        draft.prompt = "Scan overnight"
        draft.spec.provider = .grok
        draft.spec.providerInstanceID = "grok"
        draft.spec.routingMode = .auto
        draft.spec.reasoningEffort = .medium
        draft.spec.frequency = .daily
        draft.spec.localTimeHour = 9
        draft.spec.localTimeMinute = 0
        vm.saveScheduleTask(draft)
        let saved = try XCTUnwrap(vm.scheduleTaskItems.first)
        let spec = try XCTUnwrap(BotScheduleSpec.decodeJSON(saved.scheduleSpecJSON))
        XCTAssertEqual(spec.provider, .grok)
        XCTAssertEqual(spec.routingMode, .auto)
        XCTAssertEqual(spec.frequency, .daily)
        XCTAssertEqual(saved.scheduleNote, "Daily 09:00")
    }

    func test_scheduleTaskEditorFieldsHaveVoiceOverNames_becauseVisualLabelIsNotTheControlName() throws {
        // WHY: Computer Use / VoiceOver saw New Scheduled Task Name, When,
        // and Instruction as unnamed fields. `labeled` painted a caption
        // but never named the control. Studio `labeledField` already hides
        // the caption and sets accessibilityLabel — this editor must too.
        let source = try String(
            contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "private func labeled<Content: View>") else {
            return XCTFail("schedule editor labeled helper must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex
        let helper = String(source[start.lowerBound..<end])
        XCTAssertTrue(
            helper.contains(".accessibilityHidden(true)"),
            "visual Name/When/Instruction captions must not double-speak"
        )
        XCTAssertTrue(
            helper.contains(".accessibilityLabel(title)"),
            "Name, When, and Instruction must expose the caption as the control name"
        )
        XCTAssertTrue(
            source.contains("Picker(\"\", selection: $draft.botID)"),
            "Picker title must stay empty so VoiceOver does not speak Bot, Bot"
        )
    }

    func test_botsSearchFieldsHaveVoiceOverNames_becausePlaceholderIsNotTheControlName() throws {
        // WHY: Computer Use / VoiceOver saw Search bots and Search tasks as
        // unnamed fields (AX label null). Placeholder is hint copy, not the
        // control name. Name the field so VoiceOver can land on it.
        let sidebar = try String(
            contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"),
            encoding: .utf8
        )
        let active = try String(
            contentsOf: sourceURL("Sources/AppShell/ActiveBotsWindow.swift"),
            encoding: .utf8
        )
        let schedule = try String(
            contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            sidebar.contains("setAccessibilityLabel(placeholder)"),
            "Sidebar Search bots / Filter workspaces must expose the placeholder as the AX name"
        )
        XCTAssertTrue(
            active.contains(".accessibilityLabel(\"Search bots\")"),
            "Active Bots search must expose Search bots as the control name"
        )
        XCTAssertTrue(
            schedule.contains(".accessibilityLabel(\"Search tasks\")"),
            "Schedule Tasks search must expose Search tasks as the control name"
        )
    }

    func test_studioRoutineActiveSwitchSaysActiveAndName_becauseTitleAloneHidesTheJob() throws {
        // WHY: Computer Use / VoiceOver named the Studio Active control
        // by the task title only. Studio now mounts the shared Schedule
        // Tasks card, so its status pill, toggle and title must keep
        // naming the job for the card in every surface.
        let source = try String(
            contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "struct BotScheduleTaskCard: View") else {
            return XCTFail("shared schedule task card must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "struct BotScheduleTaskEditorView")?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])
        XCTAssertTrue(
            body.contains("title: item.name"),
            "the card title must carry the task name"
        )
        XCTAssertTrue(
            body.contains("DSPill(\"Active\", tone: .success)"),
            "the visible status must say Active"
        )
        XCTAssertTrue(
            body.contains("Button(item.isEnabled ? \"Pause\" : \"Resume\", action: onToggle)"),
            "the card must expose the enable toggle as a named action"
        )
        XCTAssertTrue(
            body.contains("Button(\"Edit\", action: onEdit)"),
            "existing tasks must expose Edit, not only Run Now"
        )
    }

    func test_editScheduleTaskHydratesFrequencyFromNote_becauseEmptySpecMustNotBecomeDailyNow() throws {
        // WHY: Bot-created routines persist When as "Weekdays 9:00" with
        // empty schedule_spec_json. Fleet Edit used to open Daily at now,
        // so Save replaced the visible weekdays 9:00 schedule.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: piper.id,
                name: "QA morning scan",
                prompt: "Check overnight failures and reply with one short status.",
                scheduleNote: "Weekdays 9:00"
            )
        )
        vm.openScheduleTasks()
        let item = try XCTUnwrap(vm.scheduleTaskItems.first)
        XCTAssertEqual(item.scheduleNote, "Weekdays 9:00")
        XCTAssertTrue(item.scheduleSpecJSON.isEmpty)

        vm.editScheduleTask(item)

        let draft = try XCTUnwrap(vm.scheduleTaskDraft)
        XCTAssertEqual(draft.name, "QA morning scan")
        XCTAssertEqual(draft.spec.frequency, .weekdays)
        XCTAssertEqual(draft.spec.localTimeHour, 9)
        XCTAssertEqual(draft.spec.localTimeMinute, 0)
    }

    func test_studioEditRoutineOpensDedicatedEditor_becauseExistingTasksMustBeEditable() throws {
        // WHY: Studio Schedule Tasks only created new rows. Existing tasks
        // showed Test run and Active, so owners could not change name,
        // instruction, or frequency. Edit must open the dedicated
        // Edit Scheduled Task draft with the same id and saved spec.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.routineName = "QA morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineSpec.provider = .grok
        vm.routineSpec.providerInstanceID = "grok"
        vm.routineSpec.routingMode = .auto
        vm.routineSpec.frequency = .daily
        vm.routineSpec.localTimeHour = 9
        vm.routineSpec.localTimeMinute = 0
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: id, enabled: true)
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertEqual(vm.screen, .studio)

        vm.editRoutine(routine)

        XCTAssertEqual(vm.screen, .scheduleTasks)
        let draft = try XCTUnwrap(vm.scheduleTaskDraft)
        XCTAssertFalse(draft.isNew)
        XCTAssertEqual(draft.id, routine.definition.id)
        XCTAssertEqual(draft.botID, piper.id)
        XCTAssertEqual(draft.name, "QA morning scan")
        XCTAssertEqual(draft.prompt, "Scan overnight failures")
        XCTAssertTrue(draft.isEnabled)
        XCTAssertEqual(draft.spec.provider, .grok)
        XCTAssertEqual(draft.spec.routingMode, .auto)
        XCTAssertEqual(draft.spec.frequency, .daily)
        XCTAssertEqual(draft.spec.localTimeHour, 9)

        var edited = draft
        edited.name = "QA evening scan"
        edited.prompt = "Scan the afternoon queue"
        edited.spec.frequency = .weekdays
        vm.saveScheduleTask(edited)

        XCTAssertNil(vm.scheduleTaskDraft)
        XCTAssertEqual(vm.scheduleTaskItems.map(\.name), ["QA evening scan"])
        XCTAssertEqual(vm.scheduleTaskItems.count, 1)
        XCTAssertEqual(vm.routines.map(\.definition.name), ["QA evening scan"])
        XCTAssertEqual(vm.routines.count, 1)
        let saved = try XCTUnwrap(vm.scheduleTaskItems.first)
        XCTAssertEqual(saved.id, routine.definition.id)
        XCTAssertEqual(saved.prompt, "Scan the afternoon queue")
        XCTAssertEqual(saved.scheduleNote, "Weekdays 09:00")
        let spec = try XCTUnwrap(BotScheduleSpec.decodeJSON(saved.scheduleSpecJSON))
        XCTAssertEqual(spec.frequency, .weekdays)
    }

    func test_publishedRosterTracksSavedFleetAndSelectedSearchResult() throws {
        let (_, vm, bot, _) = try makeDockerStudio()
        vm.reload()

        XCTAssertEqual(vm.publishedRoster.map(\.id), vm.fleet.map(\.id))
        XCTAssertTrue(vm.publishedRoster.contains(where: { $0.id == bot.id }))

        vm.searchText = "no matching teammate"
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == bot.id }))
        XCTAssertTrue(vm.publishedRoster.contains(where: { $0.id == bot.id }))
    }

    func test_searchKeepsSelectedVisible_becauseChatMustMatchTheRoster() throws {
        // WHY: searching "copy" hid the open teammate while Desk still painted
        // their chat. Keep the selected row in the list so dest and roster agree.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.searchText = "quinn"
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == quinn.id }))
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_searchTextSurvivesRelaunch_becauseSearchIsUserWorkflowState() throws {
        // WHY: Show hidden and selected tabs persist. Roster search used to
        // vanish on remount, so the user re-typed the filter and the list
        // jumped back to the full fleet. Restore must keep the open
        // teammate even when the query does not match their name.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let copy = try vm.create(name: "New Agent copy", title: "", provider: .claude)
        vm.openDesk(piper)
        vm.searchText = "copy"
        XCTAssertEqual(vm.searchText, "copy")
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == copy.id }))
        XCTAssertEqual(vm.fleet.count, 2)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.searchText, "copy")
        XCTAssertTrue(reopened.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertTrue(reopened.fleet.contains(where: { $0.id == copy.id }))
        XCTAssertEqual(reopened.fleet.count, 2)

        reopened.searchText = ""
        let cleared = BotsViewModel(context: context)
        XCTAssertEqual(cleared.searchText, "")
        XCTAssertEqual(Set(cleared.fleet.map(\.id)), Set([piper.id, copy.id]))
    }

    func test_duplicateFromRosterOpensTheCopy_becauseStudioMustNotSaveTheSource() throws {
        // WHY: Fleet Duplicate runs on the no-selection list. Roster Duplicate
        // from Studio would leave studioDraft on the source; Save would publish
        // the original teammate.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        XCTAssertEqual(vm.screen, .studio)
        vm.duplicateFromRoster(piper)
        let copy = try XCTUnwrap(vm.selectedBot)
        XCTAssertNotEqual(copy.id, piper.id)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.botID, copy.id)
        vm.openDesk(piper)
        vm.duplicateFromRoster(piper)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertNotEqual(vm.selectedBotID, piper.id)
    }

    func test_providerChipFollowsTheCallingThread_becauseBotHasNoSavedProvider() throws {
        // WHY: the provider chip is the user's route for this conversation.
        // Creating or publishing Bot identity must not choose it implicitly.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer")
        vm.openDesk(quinn)
        XCTAssertEqual(vm.providerLabel(for: quinn), "Codex", "the unbound composer starts on its own default")
        XCTAssertNil(vm.resolvedProvider(for: quinn), "no conversation thread means no persisted route")

        vm.setDeskProvider(.grok)
        vm.createDeskThread()
        XCTAssertEqual(vm.providerLabel(for: quinn), "Grok")
        XCTAssertEqual(vm.resolvedProvider(for: quinn), .grok)

        let revision = try XCTUnwrap(
            try context.botStore.getRevision(id: try XCTUnwrap(quinn.currentRevisionID))
        )
        let revisionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(revision)) as? [String: Any]
        )
        XCTAssertNil(revisionObject["provider"])
        XCTAssertNil(revisionObject["model"])
    }

    func test_openFleetSelectsFirstTeammate_becauseHomeNeedsASelectedBot() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.selectedBotID = nil
        vm.openFleet()
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_reloadOnFleetSelectsFirstTeammate_becauseSidebarOpenMustLandOnChat() throws {
        // WHY: first paint of Bots is reload(). A leftover Home screen must
        // not stay Home; Chat is the only default destination.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.selectedBotID = nil
        vm.screen = .fleet
        vm.reload()
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_openChatFromHomeOpensDesk_becauseConversationLivesOnDeskNotFleet() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openHome(bot)
        XCTAssertEqual(vm.screen, .desk)
        vm.openDesk(bot)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.inspectorTab, .routines)
    }

    func test_deskInspectorKeepsChatVisible_becauseMemoryMustNotReplaceTheConversation() throws {
        // WHY: Grok keeps Memory beside the chat. Swapping the timeline out
        // for a Memory tab teaches the user the teammate conversation is gone.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Summarize overnight")
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(vm.inspectorTab, .routines)

        vm.inspectorTab = .routines
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(vm.inspectorTab, .routines)

        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers dark mode"])
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertTrue(vm.memoryDraft.isEmpty)
    }

    func test_deskAddScheduledTaskOpensStudio() throws {
        // WHY: Desk is the chat dest. Creating a schedule is Studio work.
        // A form in the inspector would keep the owner off Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.inspectorTab = .routines
        vm.routineName = "Leftover"
        vm.openStudioToAddRoutine()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .routines)
        XCTAssertTrue(vm.routineName.isEmpty)
        XCTAssertEqual(vm.selectedBotID, bot.id)
    }

    func test_deskInspectorListsRoutinesWithoutAForm() throws {
        // WHY: The inspector must show live tasks, not a second create form.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        XCTAssertEqual(vm.routines.map(\.definition.name), ["Morning scan"])
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private var inspectorRoutines") else {
            return XCTFail("desk inspector routines must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private var deskThreadRail")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertFalse(slice.contains("bots.routines.name"))
        XCTAssertFalse(slice.contains("bots.routines.save"))
        XCTAssertFalse(slice.contains("BotScheduleSpecEditor"))
        XCTAssertTrue(slice.contains("bots.desk.inspector.routines.add"))
        XCTAssertTrue(slice.contains("deskRoutineRow"))
    }

    func test_saveRoutineDoesNotListRoutines_becauseSaveDestMustNotRereadSchedules() throws {
        // WHY: Save dest used to listRoutines after the store wrote this
        // schedule. Dest must not reread every routine.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        let afterStudio = vm.routineListCountForTesting
        XCTAssertGreaterThan(afterStudio, 0)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.routines.first?.definition.name, "Morning scan")
        XCTAssertEqual(vm.routines.first?.definition.prompt, "Scan overnight failures")
        XCTAssertEqual(vm.routines.first?.definition.scheduleNote, "Weekdays 9:00")
        XCTAssertFalse(try XCTUnwrap(vm.routines.first).activation.isEnabled)
        XCTAssertTrue(vm.routineName.isEmpty)
        XCTAssertEqual(
            vm.routineListCountForTesting,
            afterStudio,
            "save dest must not reread every routine"
        )
    }

    func test_previewBrainIncludesAdvertisedWorkspace_becauseDestMustNotOmitTheRepo() throws {
        // WHY: Studio already shows Workspace. Brain compile never sent
        // name/cwd, so first-chat "which repo?" invented a folder. Dest
        // preview and compose must share the advertised workspace.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "macos-app", cwd: "/tmp/macos-app")
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "Which repo is this?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.advertisedWorkspace?.name, "macos-app")
        XCTAssertEqual(vm.advertisedWorkspace?.cwd, "/tmp/macos-app")
        XCTAssertEqual(vm.studioWorkspaceLabel, "macos-app")
        XCTAssertTrue(preview.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app)."))
        XCTAssertFalse(preview.compiledPayload.contains("Working space:"))
        XCTAssertTrue(preview.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.workspaceHostAssignedHonesty))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Which repo is this?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
        XCTAssertEqual(piper.workspaceID, workspace.id)
    }

    func test_previewBrainIncludesAdvertisedDesktop_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Desktop. Compile folded isolation into
        // Workspace, so first-chat "which Desktop?" invented a hop. Dest
        // preview and compose must share that advertised name.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "Which Desktop?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.studioDesktopSummary, BotDesktopKind.logicalExecutionSpace.displayTitle)
        XCTAssertTrue(preview.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(preview.compiledPayload.contains("Working space:"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Which Desktop?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedBrowser_becauseDestMustNotOmitTheLastWebsite() throws {
        // WHY: Tools already persist last website. Dest preview never sent
        // URL/title, so first-chat "what's open?" invented a hop. Dest
        // preview and compose must share the advertised last website.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        let store = BotBrowserStore(appSupportDirectory: context.appSupportDirectory)
        try store.persistTarget(
            BotBrowserTarget(url: "https://github.com/remotecode", title: "GitHub"),
            botID: piper.id
        )
        vm.composerText = "What's open?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.advertisedBrowser?.url, "https://github.com/remotecode")
        XCTAssertEqual(vm.advertisedBrowser?.title, "GitHub")
        XCTAssertTrue(preview.compiledPayload.contains("Browser: GitHub (https://github.com/remotecode)"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(preview.compiledPayload.contains("secret-token"), "cookies stay out")
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What's open?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace,
                browser: vm.advertisedBrowser
            )
        )
        XCTAssertEqual(
            preview.layers.first(where: { $0.kind == .browser })?.text,
            "Browser: GitHub (https://github.com/remotecode)"
        )
    }

    func test_previewBrainIncludesAdvertisedNotifications_becauseDestMustNotOmitAlerts() throws {
        // WHY: Studio already shows Notifications On/Off. Brain compile never
        // sent that toggle, so first-chat "will you notify me?" invented
        // alerts. Dest preview and compose must share the advertised state.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "Will you notify me?"
        let onPreview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(onPreview.compiledPayload.contains("Notifications: On. Alerts stay on this Mac; not an isolated Desktop."))
        XCTAssertTrue(onPreview.compiledPayload.contains("Own the inbox."))
        vm.openStudio(piper)
        vm.studioDraft.notificationsEnabled = false
        let draftPreview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(draftPreview.compiledPayload.contains("Notifications: Off. This Mac will not alert the owner."))
        XCTAssertFalse(draftPreview.compiledPayload.contains("Notifications: On."))
        _ = try vm.saveStudio()
        vm.openDesk(try XCTUnwrap(vm.selectedBot))
        vm.composerText = "Will you notify me?"
        let offPreview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(offPreview.compiledPayload.contains("Notifications: Off. This Mac will not alert the owner."))
        XCTAssertEqual(
            offPreview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: try XCTUnwrap(vm.selectedBot),
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Will you notify me?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedMemoryMutateKey_becauseDestMustNotOmitForgetKeys() throws {
        // WHY: Memory is the files. Dest preview and compose must share
        // MEMORY.md so first-chat "what's in Memory?" cannot invent a hop.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        try vm.botHome(for: piper).writeFile(
            relativePath: BotHome.memoryName,
            contents: "- Prefers dark mode\n"
        )
        vm.composerText = "Forget the dark-mode fact"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Memory:"))
        XCTAssertFalse(preview.compiledPayload.contains("Trusted memory:"))
        XCTAssertTrue(preview.compiledPayload.contains("### MEMORY.md"))
        XCTAssertTrue(preview.compiledPayload.contains("Prefers dark mode"))
        XCTAssertFalse(preview.compiledPayload.contains("Fact: Prefers dark mode"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertTrue(preview.compiledPayload.contains(BotStandingInstructions.writeMemoryFileTool))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Forget the dark-mode fact",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainPermissionFollowsCurrentConversationAndInvalidatesCachedReceipt() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Preview", title: "", provider: .distill)
        vm.openDesk(bot)
        vm.composerText = "permission preview"
        vm.deskRouting.permissionMode = .supervised
        let supervised = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(supervised.permissionMode, .supervised)
        XCTAssertEqual(vm.studioApprovalLabel, "Supervised")
        let before = vm.previewBrainAssembleCountForTesting
        vm.deskRouting.permissionMode = .fullAccess
        let full = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(full.permissionMode, .fullAccess)
        XCTAssertEqual(vm.studioApprovalLabel, "Full access")
        XCTAssertTrue(full.compiledPayload.contains("Full access. Run tools without asking."))
        XCTAssertGreaterThan(vm.previewBrainAssembleCountForTesting, before, "Changing the permission must retire the cached context receipt")
        XCTAssertNotEqual(full.payloadDigest, supervised.payloadDigest)
    }

    func test_previewBrainIncludesAdvertisedApprovalMode_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Approval mode. Compile listed Permission,
        // so first-chat "what's your Approval mode?" invented a hop. Dest
        // preview and compose must share that advertised name. Dest Source
        // title stays Permission.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.deskRouting.permissionMode = .supervised
        vm.composerText = "What's your Approval mode?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.studioApprovalLabel, "Supervised")
        XCTAssertTrue(preview.compiledPayload.contains("Approval mode: \(BotPermission.honestyLabel) \(BotBrainCompiler.approvalsHonesty) \(BotBrainCompiler.approvalModeHostAssignedHonesty)"))
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.approvalModeHostAssignedHonesty))
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.approvalsHonesty))
        XCTAssertFalse(preview.compiledPayload.contains("Permission:"))
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .permission })?.title, "Permission")
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotBrainCompiler.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What's your Approval mode?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace,
                liveRunMode: vm.deskRouting.permissionMode
            )
        )
    }

    func test_previewBrainIncludesAdvertisedApprovals_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio Security already says Approvals. Compile listed
        // Approval mode only, so first-chat "Allow once" invented a grant.
        // Dest preview and compose must share that advertised name. Dest
        // Source title stays Permission.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.deskRouting.permissionMode = .supervised
        vm.composerText = "Allow once"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.approvalsHonesty))
        XCTAssertTrue(preview.compiledPayload.contains("Allow once / Deny stay off until P1b"))
        XCTAssertTrue(preview.compiledPayload.contains("Approval mode: \(BotPermission.honestyLabel) \(BotBrainCompiler.approvalsHonesty) \(BotBrainCompiler.approvalModeHostAssignedHonesty)"))
        XCTAssertFalse(preview.compiledPayload.contains("Permission:"))
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .permission })?.title, "Permission")
        XCTAssertEqual(
            preview.layers.first(where: { $0.kind == .permission })?.text,
            "\(BotPermission.honestyLabel) \(BotBrainCompiler.approvalsHonesty) \(BotBrainCompiler.approvalModeHostAssignedHonesty)"
        )
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotBrainCompiler.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Allow once",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace,
                liveRunMode: vm.deskRouting.permissionMode
            )
        )
    }

    func test_previewBrainIncludesAdvertisedHandleCreateOnlyHonesty_becauseDestMustNotInviteAWrite() throws {
        // WHY: Studio Handle is create-only after first save. Compile already
        // showed @handle next to Role, so first-chat "change your handle"
        // invented a write. Dest preview and compose must share that honesty.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "Change your handle"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("@\(piper.handle)"))
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.handleCreateOnlyHonesty))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Change your handle",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedRole_becauseDestMustNotLeaveTheJobUnlabeled() throws {
        // WHY: Studio already says Role. Compile put the job unlabeled after
        // an em-dash, so first-chat "what's your Role?" invented a hop. Dest
        // preview and compose must share the advertised name. Empty stays out.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "What's your Role?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Role: Scout"))
        XCTAssertFalse(preview.compiledPayload.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What's your Role?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedInstructions_becauseDestMustNotSayStandingInstructions() throws {
        // WHY: Studio already says Instructions. Compile headed the soul
        // with Standing instructions, so first-chat "what are your
        // Instructions?" invented a hop. Dest preview and compose must
        // share the advertised name. Custom soul still wins the body.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "What are your Instructions?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Instructions:"))
        XCTAssertFalse(preview.compiledPayload.contains("Standing instructions:"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What are your Instructions?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedModel_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Model. Compile listed it unlabeled after
        // · on Default route, so first-chat "what's your Model?" invented a
        // hop. Dest preview and compose must share the advertised name.
        // Empty stays out. Dest Source title stays Route.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "What's your Model?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertFalse(preview.compiledPayload.contains("Model: opus"))
        XCTAssertFalse(preview.compiledPayload.contains("Default route:"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .route })?.included, false)
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What's your Model?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedFallbackOrder_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Fallback order is not shipped. Compile
        // listed Default route only, so first-chat "if Claude is down use
        // Grok" invented a second route. Dest preview and compose must
        // share that advertised honesty. Dest Source title stays Route.
        // Schema does not grow a fallback tool.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "If Claude is down use Grok"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertFalse(preview.compiledPayload.contains("Default route:"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(preview.compiledPayload.contains("bot_set_fallback"))
        XCTAssertFalse(preview.layers.contains { $0.title == "Fallback" })
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .route })?.included, false)
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "If Claude is down use Grok",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedRoutines_becauseDestMustNotSayActiveRoutines() throws {
        // WHY: Studio already says Routines. Compile listed Active routines,
        // so first-chat "what are your Routines?" invented a hop. Dest
        // preview and compose must share the advertised name. Active stays
        // on each live line. Dest Source title stays Routine.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: id, enabled: true)
        vm.composerText = "What are your Routines?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Routines (not while the app is closed):"))
        XCTAssertTrue(preview.compiledPayload.contains("Morning scan: Instruction: Scan overnight failures. When: Weekdays 9:00. Active."))
        XCTAssertFalse(preview.compiledPayload.contains("Active routines"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(preview.layers.contains { $0.title == "Routines" })
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .routine })?.title, "Routine")
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What are your Routines?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedTestRun_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Test run. Compile listed Active routines
        // only, so first-chat "test this routine" invented a hop or a
        // schedule fire. Dest preview and compose must share the advertised
        // name. Dest Source title stays Routine. Schema does not grow a
        // test tool.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: id, enabled: true)
        vm.composerText = "Test this routine"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.testRunHonesty))
        XCTAssertTrue(preview.compiledPayload.contains("Test run: only when the User request below explicitly asks to test or run a routine"))
        XCTAssertTrue(preview.compiledPayload.contains(BotRoutineCopy.testRunHonestyCaption))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(preview.compiledPayload.contains("bot_test_routine"))
        XCTAssertFalse(preview.layers.contains { $0.title == "Test run" })
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .routine })?.title, "Routine")
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Test this routine",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedSkills_becauseDestMustNotSayEnabledSkills() throws {
        // WHY: Studio already says Skills. Compile listed Enabled skills, so
        // first-chat "which Skills?" invented a hop. Dest preview and compose
        // must share the advertised name. Off stays out.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        vm.skillDraft = "off-skill"
        vm.addSkill()
        vm.setSkillEnabled(skillID: "off-skill", enabled: false)
        vm.composerText = "Which Skills?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertFalse(preview.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(preview.compiledPayload.contains("Enabled skills"))
        XCTAssertFalse(preview.compiledPayload.contains("off-skill"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Which Skills?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesEnabledRoutine_becauseDestMustNotOmitSchedules() throws {
        // WHY: Brain Inspector / Desk send used dest memory+skills and
        // skipped dest routines. Owner-authored Morning scan never reached
        // the model unless it called get_settings.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        let listsBefore = vm.routineListCountForTesting
        vm.setRoutineEnabled(id: id, enabled: true)
        vm.composerText = "What do you run?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Morning scan: Instruction: Scan overnight failures. When: Weekdays 9:00"))
        XCTAssertTrue(preview.compiledPayload.contains("not while the app is closed"))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What do you run?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
        XCTAssertEqual(
            vm.routineListCountForTesting,
            listsBefore,
            "preview dest must use dest-cached routines"
        )
    }

    func test_saveRoutineKeepsExistingRoutines_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first save is honest only when older schedules stay
        // visible and the new row paints first.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: piper.id,
                name: "Older scan",
                prompt: "Scan last night",
                scheduleNote: "Daily"
            )
        )
        vm.beginEdit(piper)
        XCTAssertEqual(vm.routines.map(\.definition.name), ["Older scan"])
        let afterStudio = vm.routineListCountForTesting
        vm.routineName = "Newer scan"
        vm.routinePrompt = "Scan this morning"
        vm.saveRoutine()
        XCTAssertEqual(vm.routines.first?.definition.name, "Newer scan")
        XCTAssertEqual(
            Set(vm.routines.map(\.definition.name)),
            Set(["Newer scan", "Older scan"])
        )
        XCTAssertEqual(vm.routineListCountForTesting, afterStudio)
        XCTAssertEqual(
            Set(try context.botStore.listRoutines(botID: piper.id).map(\.definition.name)),
            Set(["Newer scan", "Older scan"])
        )
    }

    func test_setRoutineEnabledDoesNotListRoutines_becauseEnableDestMustNotRereadSchedules() throws {
        // WHY: Enable dest used to listRoutines after the store wrote this
        // activation. Dest must not reread every schedule.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertFalse(routine.activation.isEnabled)
        let afterSave = vm.routineListCountForTesting
        vm.setRoutineEnabled(id: routine.definition.id, enabled: true)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.routines.first?.definition.name, "Morning scan")
        XCTAssertTrue(try XCTUnwrap(vm.routines.first).activation.isEnabled)
        XCTAssertEqual(vm.enabledRoutineCount, 1)
        XCTAssertEqual(
            vm.routineListCountForTesting,
            afterSave,
            "enable dest must not reread every routine"
        )
        XCTAssertTrue(
            try XCTUnwrap(context.botStore.listRoutines(botID: piper.id).first).activation.isEnabled
        )
    }

    func test_setRoutineEnabledKeepsExistingRoutines_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first enable is honest only when older schedules stay
        // visible and only this row flips Active.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: piper.id,
                name: "Older scan",
                prompt: "Scan last night",
                scheduleNote: "Daily"
            )
        )
        vm.beginEdit(piper)
        vm.routineName = "Newer scan"
        vm.routinePrompt = "Scan this morning"
        vm.saveRoutine()
        let newer = try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" })
        let afterSave = vm.routineListCountForTesting
        vm.setRoutineEnabled(id: newer.definition.id, enabled: true)
        XCTAssertEqual(
            Set(vm.routines.map(\.definition.name)),
            Set(["Newer scan", "Older scan"])
        )
        XCTAssertTrue(try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" }).activation.isEnabled)
        XCTAssertFalse(try XCTUnwrap(vm.routines.first { $0.definition.name == "Older scan" }).activation.isEnabled)
        XCTAssertEqual(vm.enabledRoutineCount, 1)
        XCTAssertEqual(vm.routineListCountForTesting, afterSave)
        vm.setRoutineEnabled(id: newer.definition.id, enabled: false)
        XCTAssertFalse(try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" }).activation.isEnabled)
        XCTAssertEqual(vm.enabledRoutineCount, 0)
        XCTAssertEqual(vm.routineListCountForTesting, afterSave)
        XCTAssertEqual(vm.screen, .studio)
    }

    func test_distillRoutineTestRunPersistsAndSendsRoleSpecificModelsAndEfforts() async throws {
        // WHY: a Bot routine test run must carry its stored Distill routing into the provider request and the new conversation.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        let efforts: [AgentReasoningEffort] = [.low, .high]
        let models = [
            AgentModelDescriptor(id: "main", label: "Main", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: efforts),
            AgentModelDescriptor(id: "reason", label: "Reason", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: efforts),
        ]
        let snapshot = AgentProviderSnapshot(
            id: "distill",
            provider: .distill,
            driverKind: .distillACP,
            displayName: "Distill",
            accentColor: "#6E56CF",
            continuationGroup: "distill",
            interactionModes: [.default],
            permissionModes: [.supervised, .fullAccess],
            enabled: true,
            installed: true,
            status: .available,
            authenticated: true,
            models: models,
            slashCommands: [],
            capabilities: AgentProviderCapabilities(
                supportsDistillMainEffortAuto: true,
                supportsDistillReasoningModelEffort: true
            )
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        let vm = BotsViewModel(context: context, router: router)
        vm.replaceProvidersForTests([snapshot])
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        vm.routineName = "Distill routine"
        vm.routinePrompt = "Inspect the scheduled change"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.routineSpec = BotScheduleSpec(
            provider: .distill,
            providerInstanceID: "distill",
            model: "main",
            reasoningEffort: .high,
            reasoningModel: "reason",
            distillMainEffortSelection: .fixed(.high),
            distillReasoningEffortSelection: .fixed(.low),
            routingMode: .manual
        )
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)

        vm.requestRoutineTestRun(id: routine.definition.id)
        let started = await waitUntil(timeout: 5) { !runner.requests.isEmpty }
        XCTAssertTrue(started, "the routine test must reach the Distill provider adapter")
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.provider, .distill)
        XCTAssertEqual(request.model, "main")
        XCTAssertEqual(request.reasoningModel, "reason")
        XCTAssertEqual(request.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(request.distillReasoningEffortSelection, .fixed(.low))
        let conversation = try XCTUnwrap(vm.selectedConversation)

        XCTAssertTrue(vm.createDeskThread())
        vm.selectDeskThread(conversation.id)
        XCTAssertEqual(vm.deskRouting.reasoningModel, "reason")
        XCTAssertEqual(vm.deskRouting.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(vm.deskRouting.distillReasoningEffortSelection, .fixed(.low))
    }

    func test_routineTestRunSendsTheInstruction_becauseTestRunsAreRealWork() throws {
        // WHY: Test run is a live supervised turn, not a fake schedule fire.
        // Enabling Active still must not imply the app runs while closed.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertFalse(routine.activation.isEnabled)
        XCTAssertNil(routine.activation.lastTestRunRequestedAt)

        vm.requestRoutineTestRun(id: routine.definition.id)

        XCTAssertEqual(vm.screen, .desk, "a test run is desk work, not a hidden schedule")
        XCTAssertEqual(vm.deskMessages.first?.text, "Scan overnight failures")
        XCTAssertEqual(vm.deskMessages.last?.text, BotsViewModel.assistantPlaceholder)
        let updated = try XCTUnwrap(vm.routines.first)
        XCTAssertNotNil(updated.activation.lastTestRunRequestedAt)
        XCTAssertFalse(updated.activation.isEnabled, "Test run must not silently enable a schedule")
        XCTAssertFalse(vm.isAutonomyActive)
        XCTAssertTrue(BotRoutineCopy.testRunHonestyCaption.contains("only while MacCode is open"))
    }

    func test_routineTestRunCreatesANewConversationForEveryExecution() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        XCTAssertTrue(vm.send("Continue the current investigation"))
        let original = try XCTUnwrap(vm.selectedConversation)
        let originalMessages = vm.deskMessages
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineSpec.provider = .grok
        vm.routineSpec.model = "grok-4.6"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)

        vm.requestRoutineTestRun(id: routine.definition.id)
        let first = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(first.id, original.id)
        XCTAssertEqual(vm.deskMessages.filter { $0.role == .user }.map(\.text), [routine.definition.prompt])
        XCTAssertEqual(vm.deskRouting.provider, .grok)
        XCTAssertEqual(vm.deskRouting.model, "grok-4.6")

        vm.requestRoutineTestRun(id: routine.definition.id)
        let second = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(second.id, original.id)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(vm.deskMessages.filter { $0.role == .user }.map(\.text), [routine.definition.prompt])
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, 3)

        vm.selectDeskThread(original.id)
        XCTAssertEqual(vm.deskMessages, originalMessages)
        XCTAssertEqual(vm.deskRouting.provider, .claude)
    }

    func test_routineTestRunFromFleetCreatesConversationForTheTaskBot() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout")
        let quinn = try vm.create(name: "Quinn", title: "Reviewer")
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Piper's existing conversation"))
        let piperConversation = try XCTUnwrap(vm.selectedConversation)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineSpec.provider = .grok
        vm.routineSpec.model = "grok-4.6"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("Quinn's existing conversation"))
        let quinnConversation = try XCTUnwrap(vm.selectedConversation)
        vm.openScheduleTasks()

        vm.requestRoutineTestRun(id: routine.definition.id)

        let created = try XCTUnwrap(vm.selectedConversation)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(created.botID, piper.id)
        XCTAssertNotEqual(created.id, piperConversation.id)
        XCTAssertNotEqual(created.id, quinnConversation.id)
        let threadID = try XCTUnwrap(created.linkedAgentThreadID)
        XCTAssertNotEqual(threadID, try XCTUnwrap(piperConversation.linkedAgentThreadID))
        XCTAssertNotEqual(threadID, try XCTUnwrap(quinnConversation.linkedAgentThreadID))
        XCTAssertEqual(try context.threadRepo.get(id: threadID)?.provider, .grok)
        XCTAssertEqual(vm.deskMessages.filter { $0.role == .user }.map(\.text), [routine.definition.prompt])
        XCTAssertEqual(vm.deskRouting.provider, .grok)
        XCTAssertEqual(vm.deskRouting.model, "grok-4.6")
        XCTAssertEqual(try context.botStore.listConversations(botID: quinn.id).map(\.id), [quinnConversation.id])
    }

    func test_routineTestRunAcknowledgesOnTheDeskThatOwnsTheTurn() throws {
        // WHY: a routine test is a real Desk turn. Its acknowledgement must
        // describe the destination that owns the persisted transcript.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertEqual(vm.screen, .studio)

        vm.requestRoutineTestRun(id: routine.definition.id)

        XCTAssertEqual(
            vm.lastSendAcknowledgedOnScreenForTesting,
            .desk,
            "the acknowledgement must identify the Desk that owns the turn"
        )
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Scan overnight failures")
    }

    func test_requestRoutineTestRunDoesNotListRoutines_becauseTestRunDestMustNotRereadSchedules() throws {
        // WHY: Test run dest used to listRoutines after the store stamped
        // this request. Dest must not reread every schedule.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertNil(routine.activation.lastTestRunRequestedAt)
        let afterSave = vm.routineListCountForTesting
        vm.requestRoutineTestRun(id: routine.definition.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.routines.first?.definition.name, "Morning scan")
        XCTAssertNotNil(try XCTUnwrap(vm.routines.first).activation.lastTestRunRequestedAt)
        XCTAssertFalse(try XCTUnwrap(vm.routines.first).activation.isEnabled)
        XCTAssertEqual(
            vm.routineListCountForTesting,
            afterSave,
            "test run dest must not reread every routine"
        )
        XCTAssertNotNil(
            try XCTUnwrap(context.botStore.listRoutines(botID: piper.id).first).activation.lastTestRunRequestedAt
        )
    }

    func test_requestRoutineTestRunKeepsExistingRoutines_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first test run is honest only when older schedules stay
        // visible and only this row stamps the request.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: piper.id,
                name: "Older scan",
                prompt: "Scan last night",
                scheduleNote: "Daily"
            )
        )
        vm.beginEdit(piper)
        vm.routineName = "Newer scan"
        vm.routinePrompt = "Scan this morning"
        vm.saveRoutine()
        let newer = try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" })
        let afterSave = vm.routineListCountForTesting
        vm.requestRoutineTestRun(id: newer.definition.id)
        XCTAssertEqual(
            Set(vm.routines.map(\.definition.name)),
            Set(["Newer scan", "Older scan"])
        )
        XCTAssertNotNil(try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" }).activation.lastTestRunRequestedAt)
        XCTAssertNil(try XCTUnwrap(vm.routines.first { $0.definition.name == "Older scan" }).activation.lastTestRunRequestedAt)
        XCTAssertFalse(try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" }).activation.isEnabled)
        XCTAssertEqual(vm.routineListCountForTesting, afterSave)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Scan this morning")
    }

    func test_runNowFromScheduleTasksEnqueuesARun_becauseItMustMatchAScheduledFire() async throws {
        // WHY: Run Now on a Schedule Tasks row did nothing visible. It must start the
        // routine through the scheduled-fire executor, in place, with one new conversation.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineSpec.provider = .claude
        vm.routineSpec.providerInstanceID = "claude"
        vm.routineSpec.model = "opus"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        vm.openScheduleTasks()
        let before = try context.botStore.listConversations(botID: bot.id).count

        vm.runRoutineNow(id: routine.definition.id)

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.screen, .scheduleTasks, "Run Now must not navigate to the desk")
        let started = await waitUntil(timeout: 5) { !runner.requests.isEmpty }
        XCTAssertTrue(started, "Run Now must reach the provider")
        XCTAssertEqual(runner.requests.first?.model, "opus")
        let conversations = try context.botStore.listConversations(botID: bot.id)
        XCTAssertEqual(conversations.count, before + 1, "exactly one new conversation, no empty New thread")
        XCTAssertTrue(vm.isRoutineRunning(id: routine.definition.id), "the row must show running")
        XCTAssertNotNil(
            try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first).activation.lastTestRunRequestedAt
        )
        if let runID = runner.requests.first?.runId {
            _ = runner.finish(runID: runID, status: .cancelled, reply: nil)
        }
    }

    func test_runNowSurfacesAFailedAdmission_becauseItMustNeverBeSilent() throws {
        // WHY: with no runtime router the send cannot start; the user must see why.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        vm.openScheduleTasks()
        vm.errorMessage = nil
        vm.dockerGuestReadyOverrideForTesting = false
        vm.desktopKindOverrideForTesting = .dockerDesktop

        vm.runRoutineNow(id: routine.definition.id)

        XCTAssertNotNil(vm.errorMessage, "a failed Run Now must be reported, not swallowed")
        XCTAssertFalse(vm.isRoutineRunning(id: routine.definition.id))
        XCTAssertEqual(vm.screen, .scheduleTasks)
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, 0)
    }

    func test_inspectorTabSurvivesRelaunch_becauseSelectedTabsAreUserWorkflowState() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.inspectorTab = .routines
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.inspectorTab, .routines)
    }

    func test_brainPaneSurvivesRelaunch_becauseSelectedTabsAreUserWorkflowState() throws {
        // WHY: Source vs Effective is a selected Brain pane. The Brain tab
        // is no longer user-facing, so leftover Brain persist remaps to
        // Routines while the pane choice still survives for compile receipts.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.inspectorTab = .brain
        vm.brainPane = .effective
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.inspectorTab, .routines)
        XCTAssertEqual(reopened.brainPane, .effective)
    }

    func test_leftoverBrainStudioTabOpensProfile_becauseBrainIsNotUserFacing() throws {
        // WHY: Brain is a compile inspector, not a Studio form. A leftover
        // persist must not reopen a tab the owner can no longer reach.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        _ = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        UserDefaults.standard.set("brain", forKey: "bots.studioTab")
        UserDefaults.standard.set("brain", forKey: "bots.inspectorTab")
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.studioTab, .profile)
        XCTAssertEqual(reopened.inspectorTab, .routines)
        XCTAssertFalse(BotStudioTab.brain.isUserFacing)
        XCTAssertFalse(BotDeskInspectorTab.brain.isUserFacing)
        XCTAssertTrue(BotStudioTab.files.isUserFacing)
        XCTAssertEqual(
            BotStudioTab.allCases.filter(\.isUserFacing).map(\.id),
            ["profile", "files", "routines", "security"]
        )
        XCTAssertEqual(
            BotDeskInspectorTab.allCases.filter(\.isUserFacing).map(\.id),
            ["routines"]
        )
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(
            bots.contains("ForEach(BotStudioTab.allCases.filter(\\.isUserFacing))"),
            "Brain stays on the enum for leftover persist; the Studio strip must not render it"
        )
        // Routines is the only user-facing inspector tab, so the Desk shows a
        // static section header instead of a one-chip tab strip. Brain stays
        // unreachable: there is no strip to render it, and the header title
        // resolves through the leftover-persist remap.
        XCTAssertFalse(
            bots.contains("ForEach(BotDeskInspectorTab.allCases"),
            "A single user-facing tab must render as a header, not a dead one-chip strip"
        )
        XCTAssertTrue(
            bots.contains("Text(resolvedInspectorTab.title)"),
            "The Desk inspector header must resolve through the leftover-persist remap"
        )
    }

    func test_soulFileSavePublishesSameRevisionAsStudioSave() throws {
        // WHY: Files SOUL.md must not fork a second soul from Save Bot.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.beginEdit(bot)
        let first = try XCTUnwrap(vm.selectedRevision?.revisionNumber)
        vm.homeDraft = "Stand up for the brief."
        vm.selectedHomePath = BotHome.soulName
        vm.saveHomeFile()
        let afterFiles = try XCTUnwrap(vm.selectedRevision)
        XCTAssertEqual(afterFiles.soul, "Stand up for the brief.")
        XCTAssertGreaterThan(afterFiles.revisionNumber, first)
        let home = vm.botHome(for: try XCTUnwrap(vm.selectedBot))
        XCTAssertEqual(try home.readSoul(), "Stand up for the brief.")
        vm.studioDraft.soul = "Own the inbox."
        _ = try vm.saveStudio()
        XCTAssertEqual(try home.readSoul(), "Own the inbox.")
        XCTAssertEqual(vm.selectedRevision?.soul, "Own the inbox.")

        vm.attachHomeFilesSurface(for: try XCTUnwrap(vm.selectedBot))
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        let surfaceID = SurfaceID(bot.id.value)
        let opened = try router.filesEditOpen(surface: surfaceID, path: BotHome.soulName)
        let sessionID = try XCTUnwrap(opened.objectValue?["session_id"]?.stringValue)
        let current = opened.objectValue?["content"]?.stringValue ?? ""
        _ = try router.filesEditApplyPatch(
            sessionID: sessionID,
            baseDraftRevision: opened.objectValue?["draft_revision"]?.intValue ?? 1,
            rangeLocation: 0,
            rangeLength: (current as NSString).length,
            replacement: "From FilesSurface.",
            deviceID: "test"
        )
        _ = try router.filesEditSave(sessionID: sessionID)
        XCTAssertEqual(vm.selectedRevision?.soul, "From FilesSurface.")
        XCTAssertEqual(try home.readSoul(), "From FilesSurface.")
        _ = try? router.filesEditClose(sessionID: sessionID)
    }

    func test_studioFilesSurfaceListsBotHomeNotAdvertisedWorkspace() throws {
        // WHY: Studio Files used a custom list. Owners asked for the Agentic
        // Files component. The model must list the exclusive bot home, not
        // the advertised workspace cwd, so edits cannot leak into the project.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        let home = vm.botHome(for: bot)
        XCTAssertEqual(model.root, home.root.path)
        XCTAssertTrue(model.root.contains("/bots/"))
        XCTAssertTrue(model.root.contains(bot.id.value.uuidString.lowercased()))
        model.loadDirectory("")
        XCTAssertTrue(
            Set(model.entries.map(\.name)).isSuperset(of: [
                BotHome.identityName,
                BotHome.descriptionName,
                BotHome.soulName,
                BotHome.memoryName,
                BotHome.skillsDirectoryName,
                BotHome.filesDirectoryName
            ])
        )
    }

    func test_studioDockerFilesSurfaceUsesPersistentGuestHome() throws {
        // WHY: Docker's real home is the existing /home/remotecode bind.
        // Studio must edit that exact host directory, including ordinary
        // files whose names are generated projections only in Bot files.
        let (_, vm, bot, _) = try makeDockerStudio()
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        let expected = BotComputerGuestSpec.guestHomeURL(
            appSupport: URL(fileURLWithPath: directory, isDirectory: true),
            botID: bot.id
        )
        XCTAssertEqual(vm.studioFilesLocation, .dockerHome)
        XCTAssertEqual(model.root, expected.path)

        _ = try router.fsWorkspaceCreateFile(
            workspace: router.workspaceID,
            path: BotHome.identityName,
            content: "ordinary docker file"
        )
        model.loadDirectory("")
        let identity = try XCTUnwrap(model.entries.first { $0.name == BotHome.identityName })
        XCTAssertTrue(identity.isEditable)
        let opened = try router.filesEditOpen(
            surface: SurfaceID(bot.id.value),
            path: BotHome.identityName
        )
        let sessionID = try XCTUnwrap(opened.objectValue?["session_id"]?.stringValue)
        let original = opened.objectValue?["content"]?.stringValue ?? ""
        _ = try router.filesEditApplyPatch(
            sessionID: sessionID,
            baseDraftRevision: opened.objectValue?["draft_revision"]?.intValue ?? 1,
            rangeLocation: 0,
            rangeLength: (original as NSString).length,
            replacement: "edited through Files",
            deviceID: "test"
        )
        _ = try router.filesEditSave(sessionID: sessionID)
        XCTAssertEqual(
            try String(contentsOf: expected.appendingPathComponent(BotHome.identityName), encoding: .utf8),
            "edited through Files"
        )
        _ = try? router.filesEditClose(sessionID: sessionID)
    }

    func test_studioDockerFilesSeedsRootDockerfileAndOpensItAsText() throws {
        // WHY: Dockerfile is per bot and extensionless. Studio must place it at the
        // exact persisted guest-home root, then promote it from unknown to editable text.
        let (context, vm, bot, docker) = try makeDockerStudio()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        model.loadDirectory("")

        let dockerfile = try XCTUnwrap(model.entries.first { $0.name == "Dockerfile" })
        XCTAssertEqual(dockerfile.relativePath, "Dockerfile")
        XCTAssertEqual(
            dockerfile.path,
            BotComputerGuestSpec.guestHomeURL(
                appSupport: context.appSupportDirectory,
                botID: bot.id
            ).appendingPathComponent("Dockerfile").path
        )
        XCTAssertFalse(dockerfile.isEditable, "directory listing should not read every file")

        model.select(dockerfile)

        XCTAssertEqual(model.selectedEntry?.kind, "text")
        XCTAssertTrue(model.selectedEntry?.isEditable == true)
        XCTAssertTrue(model.draftText.contains("FROM debian"))
    }

    func test_studioDockerFilesCanSwitchBackToBotHome() throws {
        // WHY: Docker home is the default, but the owner must be able to
        // return to the versioned bot configuration and keep that choice.
        let (context, vm, bot, _) = try makeDockerStudio()
        vm.attachHomeFilesSurface(for: bot)
        XCTAssertEqual(vm.studioFilesLocation, .dockerHome)

        vm.setStudioFilesLocation(.botFiles, for: bot)
        XCTAssertEqual(vm.studioFilesLocation, .botFiles)
        XCTAssertEqual(vm.homeFilesModel?.root, vm.botHome(for: bot).root.path)

        let reopened = BotsViewModel(context: context)
        reopened.dockerGuestReadyOverrideForTesting = true
        reopened.openStudio(bot)
        reopened.attachHomeFilesSurface(for: bot)
        XCTAssertEqual(reopened.studioFilesLocation, .botFiles)
        XCTAssertEqual(reopened.homeFilesModel?.root, reopened.botHome(for: bot).root.path)
        reopened.homeFilesModel?.close()
    }

    func test_dockerFilesPersistAcrossReopenUntilExplicitClear() async throws {
        // WHY: Stop and ordinary reopen preserve the bind. Only the confirmed
        // destructive action may tear it down and replace it with an empty home.
        let (context, vm, bot, docker) = try makeDockerStudio()
        vm.attachHomeFilesSurface(for: bot)
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        _ = try router.fsWorkspaceCreateFile(
            workspace: router.workspaceID,
            path: "sentinel.txt",
            content: "keep me"
        )
        let guestHome = BotComputerGuestSpec.guestHomeURL(
            appSupport: context.appSupportDirectory,
            botID: bot.id
        )
        let sentinel = guestHome.appendingPathComponent("sentinel.txt")
        vm.rememberGuestScreen(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:49152/vnc.html")),
            botID: bot.id,
            running: true
        )
        vm.stopDockerGuest(botID: bot.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        let reopened = BotsViewModel(context: context)
        reopened.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )
        reopened.dockerGuestReadyOverrideForTesting = true
        reopened.openStudio(bot)
        reopened.attachHomeFilesSurface(for: bot)
        XCTAssertEqual(reopened.homeFilesModel?.root, guestHome.path)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep me")
        let beforeClear = reopened.homeFilesModel
        reopened.rememberGuestScreen(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:49152/vnc.html")),
            botID: bot.id,
            running: true
        )

        let clearGate = DispatchSemaphore(value: 0)
        docker.blockedRemoveName = BotComputerGuestSpec.containerName(botID: bot.id)
        docker.removeGate = clearGate
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        let startedAt = Date()

        reopened.confirmClearDockerData(for: bot)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.1)
        XCTAssertEqual(docker.removeStarted.wait(timeout: .now() + 1), .success)
        await Task.yield()
        XCTAssertTrue(heartbeat, "confirmed cleanup must not block the Studio event loop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        clearGate.signal()
        let cleared = await waitUntil(timeout: 2) {
            !FileManager.default.fileExists(atPath: sentinel.path)
                && reopened.homeFilesModel != nil
                && reopened.homeFilesModel !== beforeClear
        }
        XCTAssertTrue(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guestHome.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: guestHome.path), [])
        XCTAssertEqual(reopened.homeFilesModel?.root, guestHome.path)
        XCTAssertFalse(reopened.homeFilesModel === beforeClear)
        XCTAssertFalse(reopened.isGuestRunning(bot.id))
        XCTAssertNil(reopened.guestScreenURL(for: bot.id))
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("pendingDockerDataClear"))
        XCTAssertTrue(source.contains("bots.studio.files.docker.clear"))
        reopened.homeFilesModel?.close()
    }

    func test_studioFilesSurfaceLocksIdentityOnly() throws {
        // WHY: IDENTITY.md is still generated. MEMORY.md is the bot's
        // own file — locking it would send Forget/Correct back to a store.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        model.loadDirectory("")
        let identity = try XCTUnwrap(model.entries.first { $0.name == BotHome.identityName })
        let memory = try XCTUnwrap(model.entries.first { $0.name == BotHome.memoryName })
        let soul = try XCTUnwrap(model.entries.first { $0.name == BotHome.soulName })
        XCTAssertFalse(identity.isEditable)
        XCTAssertTrue(memory.isEditable)
        XCTAssertTrue(soul.isEditable)
        XCTAssertEqual(BotHome.memoryName, "MEMORY.md")
    }

    func test_studioFilesIdentityOpensReadOnly_becauseGeneratedProjectionMustNotDumpRPCError() throws {
        // WHY: listing locks IDENTITY.md. Opening it used to re-read identity
        // as editable, call filesEditOpen, and replace the editor with
        // JSONRPCError "Generated projection".
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        defer { model.close() }
        model.loadDirectory("")
        let identity = try XCTUnwrap(model.entries.first { $0.name == BotHome.identityName })
        XCTAssertFalse(identity.isEditable)

        let read = try router.fsWorkspaceRead(
            workspace: router.workspaceID,
            path: BotHome.identityName,
            maxBytes: nil
        )
        XCTAssertEqual(
            read.objectValue?["identity"]?.objectValue?["is_editable"]?.boolValue,
            false,
            "read identity must stay locked so loadFile does not call filesEditOpen"
        )
        XCTAssertEqual(
            read.objectValue?["identity"]?.objectValue?["editability_reason"]?.stringValue,
            "Generated projection"
        )
        XCTAssertThrowsError(
            try router.filesEditOpen(surface: SurfaceID(bot.id.value), path: BotHome.identityName)
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("Generated projection"),
                "edit-open must still refuse IDENTITY.md"
            )
        }

        model.select(identity)
        XCTAssertNil(
            model.errorText,
            "IDENTITY.md must open as a read-only projection, not a Files error overlay"
        )
        XCTAssertFalse(try XCTUnwrap(model.selectedEntry).isEditable)
        XCTAssertTrue(model.visibleText.contains("Name: Piper"))
        XCTAssertFalse(model.isDirty)
    }

    func test_studioSkillsLiveInFilesNotASkillsTab() throws {
        // WHY: Owners already have Files. A leftover Skills tab must not
        // come back; persist remaps to Files.
        XCTAssertFalse(BotStudioTab.allCases.map(\.id).contains("skills"))
        XCTAssertTrue(BotStudioTab.files.isUserFacing)
        XCTAssertEqual(
            BotStudioTab.allCases.filter(\.isUserFacing).map(\.id),
            ["profile", "files", "routines", "security"]
        )
        UserDefaults.standard.set("skills", forKey: "bots.studioTab")
        let context = try makeContext()
        _ = try BotsViewModel(context: context).create(name: "Piper", title: "Scout", provider: .claude)
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.studioTab, .files)
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(bots.contains("private var skillsTab"))
        XCTAssertFalse(bots.contains("Skill catalog id"))
        XCTAssertFalse(bots.contains("bots.studio.tab.skills"))
        XCTAssertTrue(bots.contains("bots.studio.files"))
    }

    func test_studioMemoryLivesInFilesNotAMemoryTab() throws {
        // WHY: Owners already have Files. A leftover Memory tab must not
        // come back; persist remaps to Files / Routines.
        XCTAssertFalse(BotStudioTab.allCases.map(\.id).contains("memory"))
        XCTAssertFalse(BotDeskInspectorTab.allCases.map(\.id).contains("memory"))
        XCTAssertTrue(BotStudioTab.files.isUserFacing)
        XCTAssertEqual(
            BotStudioTab.allCases.filter(\.isUserFacing).map(\.id),
            ["profile", "files", "routines", "security"]
        )
        XCTAssertEqual(
            BotDeskInspectorTab.allCases.filter(\.isUserFacing).map(\.id),
            ["routines"]
        )
        UserDefaults.standard.set("memory", forKey: "bots.studioTab")
        UserDefaults.standard.set("memory", forKey: "bots.inspectorTab")
        let context = try makeContext()
        _ = try BotsViewModel(context: context).create(name: "Piper", title: "Scout", provider: .claude)
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.studioTab, .files)
        XCTAssertEqual(reopened.inspectorTab, .routines)
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(bots.contains("Remember a fact"))
        XCTAssertFalse(bots.contains("bots.studio.tab.memory"))
        XCTAssertFalse(bots.contains("bots.desk.inspector.tab.memory"))
        XCTAssertTrue(bots.contains("bots.studio.files"))
    }

    func test_studioFilesOpenTabDoesNotMountWorkspacePane() throws {
        // WHY: FilesViewModel "Open in New Tab" normally mounts a workspace
        // Files pane. Bot home is not an advertised workspace, so the same
        // control must stay inside Studio.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        defer { model.close() }
        model.loadDirectory("")
        let soul = try XCTUnwrap(model.entries.first { $0.name == BotHome.soulName })
        model.openInNewTab(soul)
        XCTAssertEqual(router.lastOpenTabPath, BotHome.soulName)
        XCTAssertNil(model.errorText)
    }

    func test_openRemoteFileFromDeskDestsStudioFilesAndRecordsTabVersusSplit() throws {
        // WHY: paired files.open_tab must not leave the user on Desk of the
        // same bot. Studio Files is the live surface; split is a distinct op.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openDesk(bot)
        XCTAssertEqual(vm.screen, .desk)
        let home = vm.botHome(for: bot)
        try home.ensure(
            name: bot.name,
            handle: bot.handle,
            title: bot.title,
            description: bot.description,
            soul: "Be brief."
        )
        try home.writeFile(relativePath: "notes.txt", contents: "from remote")
        try vm.openRemoteFile(botID: bot.id, relativePath: "notes.txt", split: false, root: "bot_home")
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .files)
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        XCTAssertEqual(router.lastOpenTabPath, "notes.txt")
        XCTAssertFalse(router.lastOpenWasSplit)
        try vm.openRemoteFile(botID: bot.id, relativePath: "notes.txt", split: true, root: "bot_home")
        XCTAssertTrue(router.lastOpenWasSplit)
        XCTAssertEqual(router.lastOpenTabPath, "notes.txt")
    }

    func test_stopDuringInFlightSendDoesNotStartProvider() async throws {
        // WHY: paired bot.stop during deskSendInFlight must not let the
        // unstructured send task start the provider after the stop receipt.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        var dispatches = 0
        vm.beforeBotRunDispatchForTesting = { _ in dispatches += 1 }
        _ = try vm.enqueueHostMessage(
            botID: bot.id,
            text: "go",
            conversationID: nil,
            routing: BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        )
        XCTAssertTrue(vm.deskSendInFlight)
        let settled = expectation(description: "stop settled after cancelling in-flight send")
        var settledOK: Bool?
        vm.stopLiveRuns(for: bot.id, force: true) { ok in
            settledOK = ok
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(dispatches, 0, "stop must cancel the send task before provider dispatch")
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertFalse(vm.lastSendStartedProviderRun)
        XCTAssertEqual(settledOK, true)
        vm.beforeBotRunDispatchForTesting = nil
    }

    func test_pairedExactStopDuringReservedPreflightSettlesAndDoesNotStartProvider() async throws {
        // WHY: bot.send returns the exact run identity before provider dispatch.
        // A paired bot.stop for that identity must cancel the reserved Desk work;
        // requiring activeRunId here rejects the valid preflight target and leaves
        // iOS permanently showing Working/Stop.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)

        let send = try vm.enqueueHostMessage(
            botID: bot.id,
            text: "go",
            conversationID: nil,
            routing: BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        )
        let payload = try XCTUnwrap(send.objectValue)
        let conversationID = try XCTUnwrap(payload["conversation_id"]?.stringValue)
        let runID = try XCTUnwrap(payload["run_id"]?.stringValue)
        XCTAssertTrue(vm.deskSendInFlight)

        let settled = expectation(description: "paired exact preflight stop settled")
        var settledOK: Bool?
        vm.stopLiveRun(
            for: bot.id,
            conversationID: conversationID,
            runID: runID,
            runRequestID: "send-request",
            force: false
        ) { ok in
            settledOK = ok
            settled.fulfill()
        }

        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(settledOK, true)
        XCTAssertTrue(runner.requests.isEmpty, "paired exact preflight stop must not reach the provider")
        XCTAssertFalse(vm.deskSendInFlight)
    }

    func test_hostBotRuntimeTaskDoesNotInheritMutationReceiptCapture() async throws {
        // WHY: bot.send admits synchronously, but provider lifecycle events can
        // occur after its receipt is sealed. Inheriting the receipt TaskLocals
        // made those events timing-dependent: suppressed before seal and only
        // published with a late-event warning after seal.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        let crossedBoundary = expectation(description: "runtime crossed receipt capture boundary")
        var inheritedSink = true
        var inheritedSuppression = true
        vm.beforeBotRunDispatchForTesting = { _ in
            inheritedSink = EventBus.activeMutationEventSink != nil
            inheritedSuppression = EventBus.suppressMutationEventCapture
            crossedBoundary.fulfill()
        }

        let sink = EventBus.MutationEventSink()
        _ = try EventBus.$activeMutationEventSink.withValue(sink) {
            try EventBus.$suppressMutationEventCapture.withValue(true) {
                try vm.enqueueHostMessage(
                    botID: bot.id,
                    text: "go",
                    conversationID: nil,
                    routing: BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
                )
            }
        }
        await fulfillment(of: [crossedBoundary], timeout: 5)
        XCTAssertFalse(inheritedSink)
        XCTAssertFalse(inheritedSuppression)
        let providerStarted = await waitUntil(timeout: 5) { !runner.requests.isEmpty }
        XCTAssertTrue(providerStarted)
        XCTAssertTrue(runner.finish(promptContaining: "go", status: .cancelled, reply: nil))
        let runtimeSettled = await waitUntil(timeout: 5) {
            !vm.hasLiveRun(botID: bot.id) && !vm.deskSendInFlight
        }
        XCTAssertTrue(runtimeSettled)
        vm.beforeBotRunDispatchForTesting = nil
    }

    func test_pairedStopVariantsReturnOnlyAfterAsyncReceiptSettlement() async throws {
        // WHY: Phase4 finalizes the value returned by this router. Returning
        // the initial accepted receipt would permanently omit the terminal
        // event range even though bot.receipt.status is promoted moments later.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        for (index, method) in ["bot.stop", "bot.force_stop"].enumerated() {
            let bot = try vm.create(name: "Piper \(index)", title: "Scout", provider: .claude)
            let requestID = "paired-stop-settlement-\(index)"
            let stopped = try await router.dispatchPairedBotRemote(method: method, params: [
                "client_request_id": .string(requestID),
                "host_id": .string("paired-test-host"),
                "bot_id": .string(bot.id.value.uuidString.lowercased()),
            ])
            let receipt = try XCTUnwrap(stopped.objectValue)
            XCTAssertEqual(receipt["status"]?.stringValue, "completed", method)
            XCTAssertEqual(receipt["request_id"]?.stringValue, requestID, method)
            XCTAssertEqual(
                receipt["readback"]?.objectValue?["force"]?.boolValue,
                method == "bot.force_stop",
                method
            )

            let status = try await router.dispatchPairedBotRemote(method: "bot.receipt.status", params: [
                "client_request_id": .string(requestID),
            ])
            XCTAssertEqual(status.objectValue?["status"]?.stringValue, "completed", method)
        }
    }

    func test_stopDuringPreflightDoesNotStartProvider() async throws {
        // WHY: bot.stop in the sendAgentMessage preflight window must cancel
        // before startRun, not complete and then let the send continue.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        let settled = expectation(description: "stop settled from preflight")
        var settledOK: Bool?
        router.sendAgentMessageAfterPreflightProbeForTesting = {
            vm.stopLiveRuns(for: bot.id, force: true) { ok in
                settledOK = ok
                settled.fulfill()
            }
        }
        _ = try vm.enqueueHostMessage(
            botID: bot.id,
            text: "go",
            conversationID: nil,
            routing: BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        )
        await fulfillment(of: [settled], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(runner.requests.isEmpty, "preflight stop must not reach startRun")
        XCTAssertFalse(vm.lastSendStartedProviderRun)
        XCTAssertEqual(settledOK, true)
        router.sendAgentMessageAfterPreflightProbeForTesting = nil
    }

    func test_stopJoinsOverlappingPreflightSends() async throws {
        // WHY: a second same-bot send must not overwrite the first task slot.
        // Stop has to cancel and join both preflight waits, or the older send
        // can start the provider after the stop receipt.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        let gate = OverlappingSendPreflightGate()
        router.sendAgentMessageAfterPreflightProbeForTesting = { await gate.park() }
        let routing = BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        _ = try vm.enqueueHostMessage(botID: bot.id, text: "first", conversationID: nil, routing: routing)
        _ = try vm.enqueueHostMessage(botID: bot.id, text: "second", conversationID: nil, routing: routing)
        await gate.waitUntilEntered(2)
        let settled = expectation(description: "stop joined both overlapping sends")
        var settledOK: Bool?
        vm.stopLiveRuns(for: bot.id, force: true) { ok in
            settledOK = ok
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(runner.requests.isEmpty, "neither overlapping send may start after stop")
        XCTAssertFalse(vm.lastSendStartedProviderRun)
        XCTAssertEqual(settledOK, true)
        router.sendAgentMessageAfterPreflightProbeForTesting = nil
    }

    func test_stopAwaitsCancelledSendsWhenLiveThreadDiscoveryFails() async throws {
        // WHY: a listConversations/durable lookup error must not settle stop
        // before the already-cancelled send task has left preflight.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        let gate = OverlappingSendPreflightGate()
        router.sendAgentMessageAfterPreflightProbeForTesting = { await gate.park() }
        let routing = BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        _ = try vm.enqueueHostMessage(botID: bot.id, text: "go", conversationID: nil, routing: routing)
        await gate.waitUntilEntered(1)
        vm.liveThreadDiscoveryErrorForTesting = NSError(
            domain: "BotStopDiscovery",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "conversation list failed"]
        )
        let settled = expectation(description: "stop failed after joining cancelled send")
        var settledOK: Bool?
        vm.stopLiveRuns(for: bot.id, force: true) { ok in
            settledOK = ok
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(settledOK, false)
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertFalse(vm.lastSendStartedProviderRun)
        vm.liveThreadDiscoveryErrorForTesting = nil
        router.sendAgentMessageAfterPreflightProbeForTesting = nil
    }

    func test_sendAfterStopWaitsUntilStopSettles() async throws {
        // WHY: a send admitted after stop takes its snapshot must not start
        // the provider until that stop has settled.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        let gate = OverlappingSendPreflightGate()
        var preflightCount = 0
        router.sendAgentMessageAfterPreflightProbeForTesting = {
            preflightCount += 1
            if preflightCount == 1 {
                await gate.park()
            }
        }
        let routing = BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        _ = try vm.enqueueHostMessage(botID: bot.id, text: "first", conversationID: nil, routing: routing)
        await gate.waitUntilEntered(1)
        let settled = expectation(description: "stop settled")
        var settledOK: Bool?
        vm.stopLiveRuns(for: bot.id, force: true) { ok in
            settledOK = ok
            settled.fulfill()
        }
        _ = try vm.enqueueHostMessage(botID: bot.id, text: "after-stop", conversationID: nil, routing: routing)
        XCTAssertTrue(runner.requests.isEmpty, "send-after-stop must not start while stop is joining")
        XCTAssertFalse(vm.lastSendStartedProviderRun)
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(settledOK, true)
        router.sendAgentMessageAfterPreflightProbeForTesting = nil
        _ = try vm.enqueueHostMessage(botID: bot.id, text: "after-settled", conversationID: nil, routing: routing)
        let startedAfter = await waitUntil(timeout: 3) { !runner.requests.isEmpty || vm.lastSendStartedProviderRun }
        XCTAssertTrue(startedAfter, "a send after stop has settled is new work and may start")
        router.sendAgentMessageAfterPreflightProbeForTesting = nil
    }

    func test_concurrentStopsJoinTheSameInFlightSend() async throws {
        // WHY: a second stop must not take an empty list and complete while
        // the first stop is still awaiting the cancelled send.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        let gate = OverlappingSendPreflightGate()
        router.sendAgentMessageAfterPreflightProbeForTesting = { await gate.park() }
        let routing = BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        _ = try vm.enqueueHostMessage(botID: bot.id, text: "go", conversationID: nil, routing: routing)
        await gate.waitUntilEntered(1)
        let first = expectation(description: "first stop settled")
        let second = expectation(description: "second stop settled")
        var firstOK: Bool?
        var secondOK: Bool?
        vm.stopLiveRuns(for: bot.id, force: true) { ok in
            firstOK = ok
            first.fulfill()
        }
        vm.stopLiveRuns(for: bot.id, force: false) { ok in
            secondOK = ok
            second.fulfill()
        }
        XCTAssertEqual(
            vm.deskStopJoinStartCountForTesting,
            1,
            "concurrent stop must share the in-flight join, not start a second empty-list stop"
        )
        await fulfillment(of: [first, second], timeout: 5)
        XCTAssertEqual(firstOK, true)
        XCTAssertEqual(secondOK, true)
        XCTAssertEqual(
            vm.deskStopJoinStartCountForTesting,
            1,
            "duplicate stop must attach to the same join result, not start a second generation"
        )
        XCTAssertTrue(runner.requests.isEmpty)
        router.sendAgentMessageAfterPreflightProbeForTesting = nil
    }

    func test_stopAfterSpawnClaimDoesNotStartProvider() async throws {
        // WHY: spawn claim unlocks before sendTurn. Desk stop must still
        // revoke that pending start while its join is outstanding, or the
        // provider write can begin after Stop.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        let park = SpawnClaimPark()
        context.coordinator.afterSpawnClaimForTesting = { _ in await park.park() }
        let routing = BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        _ = try vm.enqueueHostMessage(botID: bot.id, text: "go", conversationID: nil, routing: routing)
        await park.waitUntilEntered()
        let settled = expectation(description: "stop settled after spawn claim")
        var settledOK: Bool?
        vm.stopLiveRuns(for: bot.id, force: true) { ok in
            settledOK = ok
            settled.fulfill()
        }
        park.release()
        await fulfillment(of: [settled], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(runner.requests.isEmpty, "post-claim stop must not reach sendTurn")
        XCTAssertFalse(vm.lastSendStartedProviderRun)
        XCTAssertEqual(settledOK, true)
        context.coordinator.afterSpawnClaimForTesting = nil
    }

    func test_stopIssuesRunBeforeBlockedAcceptedSendSettles() async throws {
        // WHY: once a provider has claimed acceptance and blocked inside
        // sendTurn, Desk must still issue stopRun immediately — not only
        // after that blocked write is released.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = BlockingAcceptanceRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            )
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        let routing = BotDeskRouting(provider: .claude, providerInstanceID: "claude", model: "opus")
        _ = try vm.enqueueHostMessage(botID: bot.id, text: "go", conversationID: nil, routing: routing)
        await runner.waitUntilAcceptanceEntered()
        let settled = expectation(description: "stop settled after releasing claimed write")
        var settledOK: Bool?
        vm.stopLiveRuns(for: bot.id, force: true) { ok in
            settledOK = ok
            settled.fulfill()
        }
        XCTAssertGreaterThan(
            vm.deskStopRunIssuedCountForTesting,
            0,
            "stopRun must be issued while the claimed send is still blocked"
        )
        XCTAssertEqual(runner.physicalWrites, 0, "blocked claimed write must not finish before Stop")
        runner.releaseWrite()
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(settledOK, true)
    }

    func test_openHomeFileRevealsOwnedSkillInStudioFiles() throws {
        // WHY: Skills Open used to write homeDraft only. Studio Files now
        // hosts FilesSurfaceRoot, so that path left the preview on
        // "No file selected" instead of skills/<id>/SKILL.md. A Docker bot
        // must also leave its default Docker root before revealing Bot files.
        let (_, vm, bot, _) = try makeDockerStudio()
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        XCTAssertEqual(vm.studioFilesLocation, .dockerHome)
        vm.thisBotSkillDraft = "night-scan"
        vm.createThisBotSkill()
        let path = "skills/night-scan/SKILL.md"
        XCTAssertNil(vm.errorMessage, vm.errorMessage ?? "")
        XCTAssertEqual(vm.studioFilesLocation, .botFiles)
        XCTAssertEqual(vm.homeFilesModel?.root, vm.botHome(for: bot).root.path)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        XCTAssertEqual(model.selectedPath, path)
        XCTAssertEqual(vm.studioTab, .files)

        model.selectedEntry = nil
        XCTAssertNil(model.selectedPath)
        vm.openHomeFile(path)
        XCTAssertEqual(vm.homeFilesModel?.selectedPath, path)
        XCTAssertEqual(vm.homeFilesModel?.selectedEntry?.name, "SKILL.md")
    }

    func test_previewBrainReusesUnchangedAssembly_becauseBrainDestMustNotRecompile() throws {
        // WHY: Studio Brain dest called assemble on every SwiftUI body.
        // An unchanged bot/memory/composer is already the honest preview.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.beginEdit(bot)
        XCTAssertNotNil(vm.previewBrain())
        let afterFirst = vm.previewBrainAssembleCountForTesting
        XCTAssertGreaterThan(afterFirst, 0)
        XCTAssertNotNil(vm.previewBrain())
        XCTAssertEqual(
            vm.previewBrainAssembleCountForTesting,
            afterFirst,
            "Brain dest must not reassemble when inputs did not change"
        )
    }

    func test_previewBrainReassemblesWhenComposerChanges_becauseStalePreviewMustNotLookCurrent() throws {
        // WHY: cache-first preview is honest only when a new composer line
        // still replaces the compiled payload.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.beginEdit(bot)
        XCTAssertNotNil(vm.previewBrain())
        let afterFirst = vm.previewBrainAssembleCountForTesting
        vm.composerText = "What did you see last night?"
        let next = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.previewBrainAssembleCountForTesting, afterFirst + 1)
        XCTAssertTrue(next.compiledPayload.contains("What did you see last night?"))
    }

    func test_previewBrainReassemblesWhenCallingThreadProviderChanges_becauseBotHasNoSavedRoute() throws {
        // WHY: provider/model belong to the calling thread. Reusing a Bot-keyed
        // preview after the user changes that thread would advertise and run
        // the stale provider even though the Bot itself stores no route.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.")
        vm.openDesk(bot)
        vm.composerText = "Which provider is running this turn?"
        vm.setDeskProvider(.codex)
        let codex = try XCTUnwrap(vm.previewBrain())
        let afterCodex = vm.previewBrainAssembleCountForTesting
        XCTAssertEqual(codex.provider, .codex)
        XCTAssertEqual(codex.model, BotsViewModel.defaultModel(for: .codex))

        vm.setDeskProvider(.grok)
        let grok = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.previewBrainAssembleCountForTesting, afterCodex + 1)
        XCTAssertEqual(grok.provider, .grok)
        XCTAssertEqual(grok.model, BotsViewModel.defaultModel(for: .grok))

        vm.setDeskProvider(.distill)
        let distill = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(distill.provider, .distill)
        XCTAssertEqual(distill.model, BotsViewModel.defaultModel(for: .distill))
        XCTAssertEqual(vm.deskRouting.provider, .distill)
    }

    func test_reloadKeepsDesk_becauseRemountMustNotNavigateHome() throws {
        // WHY: installBotsContent remounts with reload() only. reload must
        // refresh the open Desk, not convert a paint into Fleet navigation.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Summarize overnight")
        vm.reload()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
    }

    func test_reloadingDeskDoesNotListFleetConversations_becauseRemountDestMustNotScanEveryTeammate() throws {
        // WHY: leaving Bots and coming back calls reload() on the same dest.
        // Remount dest used to list every teammate's conversations before
        // dest dested Chat. Dest already has dest cache and dest inbox.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Summarize overnight"))
        let afterDest = vm.conversationListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.reload()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(
            vm.conversationListCountForTesting,
            afterDest,
            "remount dest must not scan every teammate"
        )
    }

    func test_reloadingDeskKeepsChatAndRoster_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first remount is honest only when dest still dests this
        // teammate's bubble and the roster dest already dested.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Summarize overnight"))
        let destPreview = vm.rosterPreview(for: piper)
        XCTAssertFalse(destPreview.isEmpty)
        vm.reload()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(
            vm.rosterPreview(for: piper),
            destPreview,
            "remount dest must keep dest roster preview dest already dested"
        )
        XCTAssertEqual(Set(vm.fleet.map(\.id)), [piper.id, quinn.id])
        XCTAssertEqual(vm.fleet.map(\.name).sorted(), ["Piper", "Quinn"])
    }

    func test_reloadingDeskStillListsInbox_becauseStaleBellMustNotLookCurrent() throws {
        // WHY: remount dest skips the fleet conversation scan, but dest
        // inbox must still refresh so a new needs-you cannot look empty.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Summarize overnight"))
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: piper.id, kind: .approval, title: "Approve vendor brief")
        )
        XCTAssertFalse(vm.attentionItems.contains(where: { $0.title == "Approve vendor brief" }))
        vm.reload()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertTrue(
            vm.attentionItems.contains(where: { $0.title == "Approve vendor brief" }),
            "remount dest must still dest dest inbox"
        )
        XCTAssertEqual(vm.attentionState(for: piper), .needsAttention)
    }

    func test_deskScreenSurvivesRelaunch_becauseLeavingBotsMustNotDropTheChat() throws {
        // WHY: installBotsContent remounts after Agentic/workspace. Forcing
        // Fleet Home there (or on a new VM) throws away the open Desk turn.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Summarize overnight")
        XCTAssertEqual(vm.screen, .desk)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.screen, .desk)
        XCTAssertEqual(reopened.deskMessages.first?.text, "Summarize overnight")
    }

    func test_openingBotsDoesNotListOtherTeammateConversations_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint of Bots is a new dest. Dest used to list every
        // teammate's conversations before dest dested the open Chat.
        // Dest dests this teammate; dest dests the others when dest dests them.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("From Quinn"))
        vm.openDesk(piper)
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        let afterDest = dest.conversationListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        dest.openDesk(quinn)
        XCTAssertEqual(dest.selectedBotID, quinn.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Quinn")
        XCTAssertGreaterThan(
            dest.conversationListCountForTesting,
            afterDest,
            "dest dests Quinn when dest dests that row"
        )
    }

    func test_openingBotsKeepsSelectedChat_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first first paint is honest only when dest dests this
        // teammate's bubble and dest dests the roster dest already dested.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("From Quinn"))
        vm.openDesk(piper)
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertEqual(Set(dest.fleet.map(\.id)), [piper.id, quinn.id])
        XCTAssertEqual(dest.fleet.map(\.name).sorted(), ["Piper", "Quinn"])
        XCTAssertFalse(dest.rosterPreview(for: piper).isEmpty)
        XCTAssertNotEqual(dest.rosterPreview(for: piper), "No job yet")
        XCTAssertTrue(
            dest.rosterPreview(for: piper).contains("From Piper")
                || dest.deskMessages.contains(where: { $0.text == "From Piper" })
        )
    }

    func test_openingBotsStillDestsTheOtherTeammate_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: first paint dest skips Quinn's conversation scan, but dest
        // dests Quinn's thread when dest dests that row so dest cannot
        // look empty after dest dested Quinn.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("From Quinn"))
        vm.openDesk(piper)
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        dest.openDesk(quinn)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, quinn.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Quinn")
        XCTAssertTrue(dest.deskMessages.contains(where: { $0.text == "From Quinn" }))
    }

    func test_openingBotsRestoresChatBeforeInspector_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint dest used to dest inspector (six store
        // reads) before dest dested Chat. Dest dests this bubble
        // first; dest dests inspector after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("From Quinn"))
        vm.openDesk(piper)
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertGreaterThan(dest.deskRestoreInvokedCountForTesting, 0)
        XCTAssertEqual(
            dest.lastDeskRestoreStudioSupportCountForTesting,
            0,
            "dest dests Chat before dest dests inspector"
        )
        XCTAssertGreaterThan(
            dest.studioSupportReloadCountForTesting,
            dest.lastDeskRestoreStudioSupportCountForTesting,
            "dest dests inspector after dest dested Chat"
        )
    }

    func test_openingBotsStillDestsInspector_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first Chat is honest only when dest dests Brain
        // after dest dested this bubble. Dest dests inspector so
        // Memory/Skills cannot look empty after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        _ = try context.botStore.putMemory(
            botID: piper.id,
            content: "Prefers dark mode",
            provenance: "user",
            trusted: true,
            source: "studio"
        )
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: piper.id, skillID: "weekly-account-health", enabled: true)
        )
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertEqual(dest.liveMemoryCount, 1)
        XCTAssertEqual(dest.enabledSkillCount, 1)
    }

    func test_openingBotsRestoresChatBeforeInbox_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint dest used to dest inbox (listAttention)
        // before dest dested Chat. Dest dests this bubble first;
        // dest dests inbox after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: piper.id, kind: .approval, title: "Approve vendor brief")
        )
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertGreaterThan(dest.deskRestoreInvokedCountForTesting, 0)
        XCTAssertEqual(
            dest.lastDeskRestoreAttentionListCountForTesting,
            0,
            "dest dests Chat before dest dests inbox"
        )
        XCTAssertGreaterThan(
            dest.attentionListCountForTesting,
            dest.lastDeskRestoreAttentionListCountForTesting,
            "dest dests inbox after dest dested Chat"
        )
    }

    func test_openingBotsStillDestsInbox_becauseStaleBellMustNotLookCurrent() throws {
        // WHY: dest-first Chat is honest only when dest dests inbox
        // after dest dested this bubble. Dest dests the bell so a
        // needs-you cannot look empty after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: piper.id, kind: .approval, title: "Approve vendor brief")
        )
        XCTAssertFalse(vm.attentionItems.contains(where: { $0.title == "Approve vendor brief" }))
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertTrue(
            dest.attentionItems.contains(where: { $0.title == "Approve vendor brief" }),
            "first paint dest must still dest dest inbox"
        )
        XCTAssertEqual(dest.attentionState(for: piper), .needsAttention)
    }

    func test_openingBotsRestoresChatBeforeRosterPreview_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint dest used to dest dest preview
        // (listConversations + listRecent) before dest dested Chat.
        // Dest dests this bubble first; dest dests dest preview
        // from dest Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertGreaterThan(dest.deskRestoreInvokedCountForTesting, 0)
        XCTAssertEqual(
            dest.lastDeskRestoreConversationListCountForTesting,
            0,
            "dest dests Chat before dest dests dest preview"
        )
        XCTAssertGreaterThan(
            dest.conversationListCountForTesting,
            dest.lastDeskRestoreConversationListCountForTesting,
            "dest dests dest preview after dest dested Chat"
        )
        XCTAssertTrue(
            dest.rosterPreview(for: piper).contains("From Piper")
                || dest.deskMessages.contains(where: { $0.text == "From Piper" }),
            "dest dests dest preview from dest Chat"
        )
    }

    func test_openingBotsRestoresChatBeforeThread_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint dest used to dest dest thread (listRecent)
        // before dest dested Chat. Dest dests dest title first;
        // dest dests dest thread after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        try seedLinkedTurn(context: context, bot: piper, extraReasoning: 2)
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskMessages.contains(where: { $0.text == "Summarize overnight" }))
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertTrue(
            dest.deskMessages.contains(where: { $0.text == "Summarize overnight" }),
            "dest dests dest thread after dest dested dest title"
        )
        XCTAssertGreaterThan(dest.deskRestoreInvokedCountForTesting, 0)
        XCTAssertEqual(
            dest.lastDeskRestoreMessageListCountForTesting,
            0,
            "dest dests Chat from dest title before dest dests dest thread"
        )
        XCTAssertGreaterThan(
            dest.deskMessageRestoreCountForTesting,
            dest.lastDeskRestoreMessageListCountForTesting,
            "dest dests dest thread after dest dested Chat"
        )
    }

    func test_unpublishedStudioDraftSurvivesRelaunch_becauseDraftIsUserWorkflowState() throws {
        // WHY: composer and inspector drafts persist. Studio title/soul used
        // to vanish on remount because loadStudioDraft always reloaded the
        // published revision. Unpublished Brain is user workflow state.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(
            name: "Piper",
            title: "Scout",
            soul: "Be brief.",
            provider: .claude
        )
        vm.beginEdit(bot)
        vm.studioDraft.title = "Research lead"
        vm.studioDraft.soul = "Stand up for the brief."
        XCTAssertTrue(vm.studioHasUnpublishedChanges)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.screen, .studio)
        XCTAssertEqual(reopened.studioDraft.botID, bot.id)
        XCTAssertEqual(reopened.studioDraft.title, "Research lead")
        XCTAssertEqual(reopened.studioDraft.soul, "Stand up for the brief.")
        XCTAssertTrue(reopened.studioHasUnpublishedChanges)

        reopened.openDesk(bot)
        let fromDesk = BotsViewModel(context: context)
        fromDesk.openStudio(bot)
        XCTAssertEqual(fromDesk.studioDraft.title, "Research lead")
        XCTAssertEqual(fromDesk.studioDraft.soul, "Stand up for the brief.")
        XCTAssertTrue(fromDesk.studioHasUnpublishedChanges)
    }

    func test_unpublishedStudioDraftStaysOnOwningBot_becauseBrainEditsMustNotLeak() throws {
        // WHY: composer/inspector drafts are keyed by BotID. A single
        // studioDraft persist used to overwrite teammate A's Role when the
        // user typed on teammate B Studio.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", soul: "Be kind.", provider: .claude)
        vm.beginEdit(piper)
        vm.studioDraft.title = "Fire14 lead A"
        vm.openStudio(quinn)
        vm.studioDraft.title = "Fire14 lead B"
        XCTAssertEqual(vm.studioDraft.title, "Fire14 lead B")

        vm.openStudio(piper)
        XCTAssertEqual(vm.studioDraft.botID, piper.id)
        XCTAssertEqual(vm.studioDraft.title, "Fire14 lead A")
        XCTAssertEqual(vm.studioDraft.soul, "Be brief.")

        vm.openStudio(quinn)
        XCTAssertEqual(vm.studioDraft.botID, quinn.id)
        XCTAssertEqual(vm.studioDraft.title, "Fire14 lead B")
        XCTAssertEqual(vm.studioDraft.soul, "Be kind.")

        let reopened = BotsViewModel(context: context)
        reopened.openStudio(piper)
        XCTAssertEqual(reopened.studioDraft.title, "Fire14 lead A")
        reopened.openStudio(quinn)
        XCTAssertEqual(reopened.studioDraft.title, "Fire14 lead B")
    }

    func test_studioScreenAndTabSurviveRelaunch_becauseSelectedTabsAreUserWorkflowState() throws {
        // WHY: Studio Memory/Skills are selected tabs. A remount that lands
        // on Fleet + Profile makes the user re-find the Brain they were editing.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioTab = .files
        XCTAssertEqual(vm.screen, .studio)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.screen, .studio)
        XCTAssertEqual(reopened.studioTab, .files)
        XCTAssertEqual(reopened.studioDraft.name, "Piper")
    }

    func test_leftoverHomePersistOpensChat_becauseHomeIsNotADestination() throws {
        // WHY: UserDefaults may still store fleet/Home. Dropping that raw
        // value without remap would leave Bots stuck on a removed screen.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.openHome(bot)
        XCTAssertEqual(vm.screen, .desk)
        UserDefaults.standard.set(BotsScreen.fleet.rawValue, forKey: "bots.screen")

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.screen, .desk)
        XCTAssertEqual(BotsScreen(rawValue: "fleet")?.resolvedDestination, .desk)
    }

    func test_botsShellDestinationSurvivesRelaunch_becauseAgenticBotsIsUserWorkflowState() throws {
        // WHY: bots.screen already restores Fleet/Studio/Desk. The Agentic |
        // Bots switcher still dumped the user on the workspace after relaunch.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let first = MainWindowController(context: context, router: router)
        router.windowController = first
        first.presentBotsInMainContent()
        XCTAssertEqual(first.window.title, "Bots")
        XCTAssertEqual(
            try context.settingsRepo.get(MainWindowController.botsShellSettingsKey) ?? "",
            "bots"
        )

        let reopened = MainWindowController(context: context, router: router)
        XCTAssertEqual(reopened.window.title, "Bots", "relaunch must reopen the Bots destination")

        first.presentWorkspaceContent()
        XCTAssertEqual(
            try context.settingsRepo.get(MainWindowController.botsShellSettingsKey) ?? "",
            "workspace"
        )
        let workspace = MainWindowController(context: context, router: router)
        XCTAssertNotEqual(workspace.window.title, "Bots")
        XCTAssertNotEqual(workspace.window.title, "Schedule Tasks")
        XCTAssertNotEqual(workspace.window.title, "Active Threads")
    }

    func test_legacyBotsShellFlagStillRestoresBots_becauseOlderSettingsMustNotDropTheSwitcher() throws {
        // WHY: v72-era rows stored "1"/"0". A dest-string persist cannot
        // leave those users on the workspace after an upgrade.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        try context.settingsRepo.set(MainWindowController.botsShellSettingsKey, "1")
        let restored = MainWindowController(context: context, router: router)
        XCTAssertEqual(restored.window.title, "Bots")
    }

    func test_scheduleTasksDestinationSurvivesRelaunch_becauseShellDestIsUserWorkflowState() throws {
        // WHY: persist used to write "not Bots" for Schedule Tasks, so
        // relaunch dumped the user on the workspace.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let first = MainWindowController(context: context, router: router)
        router.windowController = first
        first.presentScheduledTasksInMainContent()
        XCTAssertEqual(first.window.title, "Schedule Tasks")
        XCTAssertEqual(
            try context.settingsRepo.get(MainWindowController.botsShellSettingsKey) ?? "",
            "scheduledTasks"
        )

        let reopened = MainWindowController(context: context, router: router)
        XCTAssertEqual(reopened.window.title, "Schedule Tasks")
    }

    func test_activeThreadsDestinationSurvivesRelaunch_becauseShellDestIsUserWorkflowState() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let first = MainWindowController(context: context, router: router)
        router.windowController = first
        first.presentActiveThreadsInMainContent()
        XCTAssertEqual(first.window.title, "Active Threads")
        XCTAssertEqual(
            try context.settingsRepo.get(MainWindowController.botsShellSettingsKey) ?? "",
            "activeThreads"
        )

        let reopened = MainWindowController(context: context, router: router)
        XCTAssertEqual(reopened.window.title, "Active Threads")
    }

    func test_deletedBotDoesNotRestoreItsDesk_becauseTheTeammateIsGone() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.delete(id: piper.id)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, quinn.id)
        XCTAssertEqual(reopened.screen, .desk)
    }

    func test_memoryCorrectAndForgetStayOnDesk_becauseTheInspectorOwnsBrainEdits() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Keep chatting")
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        let item = try XCTUnwrap(vm.memoryItems.first)
        vm.correctMemory(id: item.id, content: "Prefers light mode")
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers light mode"])
        vm.forgetMemory(id: try XCTUnwrap(vm.memoryItems.first).id)
        XCTAssertTrue(vm.memoryItems.isEmpty)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Keep chatting")
    }

    func test_studioFromHomeOpensStudio_becauseBrainEditsStayOffTheOverview() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openHome(bot)
        vm.beginEdit(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.botID, bot.id)
    }

    func test_studioDestKeepsLastTab_becauseStudioIsNotProfile() throws {
        // WHY: Chat's Studio button called beginEdit, which forced Profile.
        // Skills/Memory are selected tabs. Returning to Studio must keep them.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.studioTab = .files
        vm.openDesk(piper)
        XCTAssertEqual(vm.screen, .desk)
        vm.openStudio(piper)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .files)
        XCTAssertEqual(vm.studioDraft.botID, piper.id)
    }

    func test_editFromRosterOpensProfile_becauseEditIsIdentity() throws {
        // WHY: Roster Edit is "change this teammate's name", not "resume Skills".
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.studioTab = .files
        vm.beginEdit(piper)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .profile)
    }

    func test_fleetHomeCountsAreLive_becauseOverviewMustNotInventCapacity() throws {
        // WHY: Memory/Skills/Routines/Approvals are owner-facing truth.
        // Hardcoded 87% / 12 skills / "Running • macOS VM" would be a lie.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try context.botStore.putMemory(
            botID: bot.id,
            content: "Prefers dark mode",
            provenance: "user",
            trusted: true,
            source: "studio"
        )
        let forgotten = try context.botStore.putMemory(
            botID: bot.id,
            content: "Old secret",
            provenance: "user",
            trusted: true,
            source: "studio"
        )
        try context.botStore.forgetMemory(id: forgotten.id)
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        )
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)
        )
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: bot.id,
                name: "Morning scan",
                prompt: "Scan overnight failures",
                scheduleNote: "Weekdays 9:00"
            )
        )
        let routine = try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first)
        try context.botStore.setRoutineEnabled(id: routine.definition.id, enabled: true)
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: bot.id, kind: .approval, title: "Approve vendor brief")
        )
        vm.reload()

        vm.openHome(bot)

        XCTAssertEqual(vm.liveMemoryCount, 1, "forgotten facts must not inflate Memory")
        XCTAssertEqual(vm.enabledSkillCount, 1, "disabled skills must not inflate Skills")
        XCTAssertEqual(vm.enabledRoutineCount, 1)
        XCTAssertEqual(vm.pendingApprovalCount, 1)
        XCTAssertFalse(vm.isAutonomyActive, "P1a routines stay app-closed off")
    }

    func test_beginCreateOpensStudio_becauseNewBotIsAConfigureDest() throws {
        // WHY: New Bot used to skip Studio and land on Chat. Users need
        // Profile first so name, role, and provider are set before talking.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()

        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .profile)
        XCTAssertEqual(vm.studioDraft.botID, vm.selectedBotID)
        XCTAssertEqual(try context.botStore.list().count, 1)
        XCTAssertEqual(try context.botStore.list().first?.name, "New Agent")
        XCTAssertTrue(try context.threadRepo.list().isEmpty)
        XCTAssertTrue(
            vm.needsUnsavedNewBotConfirm,
            "New Bot is a placeholder until Save Bot; leaving must confirm"
        )
    }

    func test_beginCreateMarksUnpublished_andSaveClearsConfirm() throws {
        // WHY: Save Bot is the only first-class publish. After it, Back
        // must keep the teammate and must not ask again.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        XCTAssertTrue(vm.needsUnsavedNewBotConfirm)
        XCTAssertEqual(try context.botStore.list().count, 1)

        _ = try vm.saveStudio()
        XCTAssertFalse(vm.needsUnsavedNewBotConfirm, "Save Bot is the explicit keep")
        XCTAssertEqual(try context.botStore.list().count, 1)

        var left = false
        vm.requestLeaveUnsavedNewBot { left = true }
        XCTAssertTrue(left, "saved teammates leave Studio without a confirm")
        XCTAssertFalse(vm.pendingUnsavedNewBotConfirm)
        XCTAssertEqual(try context.botStore.list().first?.name, "New Agent")
    }

    func test_unsavedNewBotLeaveConfirms_andDiscardRemovesPlaceholder() throws {
        // WHY: Back used to openDesk the placeholder, so New Agent stayed
        // in the fleet without Save Bot. Don't Save must delete it; Cancel
        // must stay on Studio.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.beginCreate()
        XCTAssertEqual(try context.botStore.list().count, 2)
        XCTAssertTrue(vm.needsUnsavedNewBotConfirm)

        var left = false
        vm.requestLeaveUnsavedNewBot { left = true }
        XCTAssertTrue(vm.pendingUnsavedNewBotConfirm)
        XCTAssertFalse(left, "unsaved New Bot must not leave until the owner confirms")

        vm.cancelUnsavedNewBotLeave()
        XCTAssertFalse(vm.pendingUnsavedNewBotConfirm)
        XCTAssertFalse(left)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(try context.botStore.list().count, 2)

        vm.requestLeaveUnsavedNewBot {
            left = true
            vm.leaveStudioAfterUnsavedGate()
        }
        vm.discardUnsavedNewBotAndLeave()
        XCTAssertTrue(left)
        XCTAssertFalse(vm.needsUnsavedNewBotConfirm)
        XCTAssertFalse(vm.pendingUnsavedNewBotConfirm)
        let remaining = try context.botStore.list()
        XCTAssertEqual(remaining.map(\.name), ["Piper"])
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_unsavedNewBotConfirmChromeAndBackUseTheLeaveGate() throws {
        // WHY: A source-only dialog would regress to openDesk on Back.
        // The chevron and the chrome copy are the owner's named dest.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let chrome = try String(contentsOf: sourceURL("Sources/AppShell/BotsChrome.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("requestLeaveUnsavedNewBot"))
        XCTAssertTrue(bots.contains("BotsUnsavedNewBotConfirmation"))
        XCTAssertTrue(bots.contains("leaveStudioAfterUnsavedGate"))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.unsavedNewBotConfirmTitle))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.unsavedNewBotConfirmMessage))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.unsavedNewBotDontSave))
        XCTAssertTrue(BotsChrome.allVisibleLabels.contains(BotsChrome.Label.unsavedNewBotConfirmTitle))
        XCTAssertTrue(BotsChrome.allVisibleLabels.contains(BotsChrome.Label.unsavedNewBotConfirmMessage))
        XCTAssertTrue(BotsChrome.allVisibleLabels.contains(BotsChrome.Label.unsavedNewBotDontSave))
        let back = try XCTUnwrap(bots.range(of: "accessibilityLabel(\"Back\")"))
        let header = bots[bots.startIndex..<back.lowerBound]
        XCTAssertTrue(
            header.contains("requestLeaveUnsavedNewBot"),
            "Studio Back must confirm unsaved New Bot instead of openDesk"
        )
    }

    func test_beginCreateAgainConfirmsBeforeASecondPlaceholder() throws {
        // WHY: New Bot again is another leave-without-save. The first
        // placeholder must not silently stay in the fleet.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        let first = try XCTUnwrap(vm.selectedBotID)
        vm.beginCreate()
        XCTAssertTrue(vm.pendingUnsavedNewBotConfirm)
        XCTAssertEqual(try context.botStore.list().count, 1)
        XCTAssertEqual(vm.selectedBotID, first)
        vm.discardUnsavedNewBotAndLeave()
        XCTAssertEqual(try context.botStore.list().count, 1)
        XCTAssertNotEqual(vm.selectedBotID, first)
        XCTAssertTrue(vm.needsUnsavedNewBotConfirm)
    }

    func test_deskPermissionLabelUsesAgentAppDisplayName() throws {
        // WHY: the header used "Auto-accept edits" while the composer chip
        // said "Auto-edit". Both must use AgentPermissionMode.displayName.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        vm.setDeskPermissionMode(.autoAcceptEdits)
        XCTAssertEqual(vm.permissionLabel(for: bot), "Auto-edit")
        XCTAssertEqual(vm.permissionLabel(for: bot), AgentPermissionMode.autoAcceptEdits.displayName)
    }

    func test_unlinkedDeskFooterKeepsRunAsUserUltracodePermissionAndLocationControls() throws {
        // WHY: an empty thread still needs the execution controls before its first send.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let footerStart = try XCTUnwrap(source.range(of: "private var deskUnlinkedFooter: some View"))
        let footer = source[footerStart.lowerBound...]
        for identifier in [
            "bots.desk.runAsUser.menu", "bots.desk.distill.mode",
            "bots.desk.permission.menu", "bots.desk.execution.location",
        ] {
            XCTAssertTrue(footer.contains(identifier), "empty Desk footer must expose \\(identifier)")
        }
    }

    func test_deskRoutingExecutionModeRoundTripsAndMissingLegacyFieldDefaultsToAuto() throws {
        let routing = BotDeskRouting(provider: .distill, providerInstanceID: "distill", model: "main-a", distillExecutionMode: .ultrasave)
        let restored = try JSONDecoder().decode(BotDeskRouting.self, from: JSONEncoder().encode(routing))
        XCTAssertEqual(restored.distillExecutionMode, .ultrasave)
        XCTAssertEqual(restored.modelSelection.distillExecutionMode, .ultrasave, "first-thread model selection must receive the mode")
        XCTAssertNil(restored.modelSelection.distillMainEffortSelection,
            "an omitted effort must not become an unsupported fixed effort in Desk or group runs")
        let scheduled = BotsViewModel.routineRouting(BotScheduleSpec(), base: routing)
        XCTAssertNil(scheduled.modelSelection.distillMainEffortSelection,
            "scheduled Bot runs must preserve the same omitted effort")

        let legacy = Data(#"{"provider":"distill","providerInstanceID":"distill","model":"main-a","routingMode":"manual","permissionMode":"supervised"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BotDeskRouting.self, from: legacy).distillExecutionMode, .auto)
    }

    func test_deskRoutingDecodesLegacyPayloadWithoutRunAsUser() throws {
        // WHY: adding runAsUser to persisted desk routing must not drop
        // existing UserDefaults payloads from before the field existed.
        let json = Data(#"{"provider":"codex","providerInstanceID":"codex","model":"","routingMode":"auto","permissionMode":"supervised"}"#.utf8)
        let decoded = try JSONDecoder().decode(BotDeskRouting.self, from: json)
        XCTAssertEqual(decoded.provider, .codex)
        XCTAssertEqual(decoded.routingMode, .auto)
        XCTAssertEqual(decoded.runAsUser.id, AgentRunAsUser.current().id)
    }

    func test_distillDeskSelectionRejectsAutomaticModelRouting() throws {
        // WHY: a previously automatic Desk route must become an explicit
        // Distill model choice, while other providers retain model-auto.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.grok)
        vm.setDeskRoutingMode(.auto)
        XCTAssertEqual(vm.deskRouting.routingMode, .auto)

        vm.setDeskProvider(.distill)

        XCTAssertEqual(vm.deskRouting.routingMode, .manual)
        vm.setDeskRoutingMode(.auto)
        XCTAssertEqual(vm.deskRouting.routingMode, .manual)
        XCTAssertNotEqual(vm.deskModelDisplayLabel, "Auto")

        vm.setDeskProvider(.grok)
        vm.setDeskRoutingMode(.auto)
        XCTAssertEqual(vm.deskRouting.routingMode, .auto,
                       "other providers keep the existing automatic-routing behavior")
    }

    func test_savedDeskDistillAutoRouteRestoresItsPinnedModelsManually() throws {
        // WHY: old per-conversation Desk preferences may contain Distill Auto;
        // restoring them must retain both model choices without model-auto.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.createDeskThread()
        let conversation = try XCTUnwrap(vm.selectedConversation)
        let route: [String: Any] = [
            "provider": "distill",
            "providerInstanceID": "distill",
            "model": "gpt-6-luna",
            "routingMode": "auto",
            "permissionMode": "supervised",
            "reasoningModel": "gpt-6-sol",
        ]
        let key = conversation.id.value.uuidString.lowercased()
        UserDefaults.standard.set(
            try JSONSerialization.data(withJSONObject: [key: route]),
            forKey: "bots.deskThreadRouting"
        )

        let restored = BotsViewModel(context: context)
        restored.openDesk(bot)
        restored.selectDeskThread(conversation.id)

        XCTAssertEqual(restored.deskRouting.routingMode, .manual)
        XCTAssertEqual(restored.deskRunModel, "gpt-6-luna")
        XCTAssertEqual(restored.deskRouting.reasoningModel, "gpt-6-sol")
    }

    func test_deskRoutingRoundTripsIndependentReasoningModels() throws {
        // WHY: Desk stores routing per conversation; changing one Reasoning model must not replace another conversation's selection.
        let first = BotDeskRouting(
            provider: .distill,
            providerInstanceID: "distill",
            model: "grok-4.6",
            routingMode: .manual,
            reasoningModel: "grok-4.5",
            distillMainEffortSelection: .fixed(.high),
            distillReasoningEffortSelection: .automatic
        )
        let second = BotDeskRouting(
            provider: .distill,
            providerInstanceID: "distill",
            model: "grok-4.6",
            routingMode: .manual,
            reasoningModel: nil,
            distillMainEffortSelection: .automatic
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let restoredFirst = try decoder.decode(BotDeskRouting.self, from: encoder.encode(first))
        let restoredSecond = try decoder.decode(BotDeskRouting.self, from: encoder.encode(second))

        XCTAssertEqual(restoredFirst.reasoningModel, "grok-4.5")
        XCTAssertEqual(restoredFirst.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(restoredFirst.modelSelection.distillMainEffortSelection, .fixed(.high))
        XCTAssertEqual(restoredFirst.distillReasoningEffortSelection, .automatic)
        XCTAssertNil(restoredSecond.reasoningModel)
        XCTAssertEqual(restoredSecond.distillMainEffortSelection, .automatic)
        XCTAssertNil(restoredSecond.distillReasoningEffortSelection)
    }

    func test_newDeskThreadDoesNotSeedFromBotRevision_becauseProviderBelongsToTheThread() throws {
        // WHY: saving a Bot with a legacy Claude revision must never make
        // Claude that Bot's provider. The user chooses the execution route
        // on the new thread's composer.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        XCTAssertEqual(vm.deskRunProvider, .codex)
        XCTAssertEqual(vm.deskRouting.routingMode, .auto)
        XCTAssertEqual(vm.deskRunPermissionMode, .fullAccess, "new Desk threads default to Full Access")
        XCTAssertNil(vm.resolvedProvider(for: bot))
    }

    func test_distillACPBotDeskSendAndReopenUsesPersistedSession() async throws {
        // WHY: Bot Desk must run through Distill ACP, preserve the conversation on reopen, and keep compression off.
        let root = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("distill-bot-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        ProviderProcessOwnership.shared.configure(fileURL: root.appendingPathComponent("provider-processes.json"))
        let harnessURL = root.appendingPathComponent("distill-agent")
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let launchesURL = root.appendingPathComponent("launches.jsonl")
        let counterURL = root.appendingPathComponent("prompt-count")
        let harness = """
        #!/usr/bin/env python3
        import json, os, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        launches = pathlib.Path(\(String(reflecting: launchesURL.path)))
        counter = pathlib.Path(\(String(reflecting: counterURL.path)))
        launch = {}
        hint = os.environ.get("RC_TOKEN_SAVER_DISTILL_HINT")
        if hint is not None:
            launch["tokenSaverHint"] = hint
        with launches.open("a") as output:
            output.write(json.dumps(launch) + "\\n")
        def record(value):
            with requests.open("a") as output:
                output.write(json.dumps(value) + "\\n")
        def prompt_text(blocks):
            if isinstance(blocks, str): return blocks
            if isinstance(blocks, dict): return blocks.get("text", "")
            if isinstance(blocks, list): return " ".join(prompt_text(block) for block in blocks)
            return ""
        def send(value):
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True,"sessionCapabilities":{"resume":True},"promptCapabilities":{}}}})
            elif method in ("session/new", "session/load"):
                meta = params.get("_meta", {})
                record({"method":method,"sessionId":params.get("sessionId"),"modelId":meta.get("modelId")})
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"sessionId":params.get("sessionId", "bot-distill-session"),"models":{"availableModels":[{"modelId":"gpt-6-luna","name":"GPT-6 Luna"}],"currentModelId":"gpt-6-luna"}}})
            elif method == "session/set_model":
                # Distill 2.0.25 acknowledges the applied Main model; the adapter refuses to prompt without it.
                requested = params.get("modelId")
                ack = {"model":{"Ok":requested},"canonicalModelId":requested}
                auto = params.get("_meta", {}).get("reasoningEffortAuto")
                if auto is not None:
                    ack["reasoningEffortAuto"] = auto
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"_meta":ack}})
            elif method in ("session/set_mode", "session/set_config_option"):
                send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
            elif method == "session/prompt":
                count = int(counter.read_text()) if counter.exists() else 0
                count += 1
                counter.write_text(str(count))
                text = prompt_text(params.get("prompt", []))
                record({"method":method,"sessionId":params.get("sessionId"),"firstRequestPresent":"First Distill bot turn" in text,"followUpPresent":"Follow-up Distill bot turn" in text})
                send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":params["sessionId"],"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Bot Distill reply " + str(count)}}}})
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"stopReason":"end_turn"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)

        let context = try makeContext()
        context.reconcileManagedIntegration()
        let router = AppCommandRouter(context: context)
        context.router = router
        let adapter = DistillACPAdapter(binaryNameOverride: harnessURL.path)
        context.coordinator.replaceProviderAdapter(.distill, adapter: adapter)
        var reopenedAdapter: DistillACPAdapter?
        defer { adapter.stopAll(); reopenedAdapter?.stopAll() }
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "gpt-6-luna", label: "GPT-6 Luna", provider: .distill)],
            binaryPath: harnessURL.path,
            authenticated: true,
            id: "distill",
            capabilitiesOverride: AgentProviderCapabilities(
                supportsDistillMainEffortAuto: true,
                supportsDistillReasoningModelEffort: true
            )
        )
        router.rememberProviderSnapshotsForSend([snapshot])

        let vm = BotsViewModel(context: context, router: router)
        vm.replaceProvidersForTests([snapshot])
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .codex, model: "legacy-only")
        vm.openDesk(bot)
        vm.createDeskThread()
        vm.setDeskProvider(.distill)
        vm.setDeskRoutingMode(.manual)
        vm.setDeskModel("gpt-6-luna")
        let conversation = try XCTUnwrap(vm.selectedConversation)
        vm.composerText = "First Distill bot turn"
        XCTAssertTrue(vm.send())
        let firstReplyArrived = await waitUntil(timeout: 8) {
            vm.deskMessages.contains { $0.role == .assistant && $0.text == "Bot Distill reply 1" }
        }
        guard firstReplyArrived else {
            let messageSummary = vm.deskMessages.map(\.text).joined(separator: " | ")
            let failure = "the selected Distill ACP provider must return a visible Bot Desk response; error="
                + (vm.errorMessage ?? "nil") + "; provider=" + vm.deskRunProvider.rawValue + "; messages=" + messageSummary
            XCTFail(failure)
            return
        }
        let linkedThreadID = try XCTUnwrap(vm.selectedConversation?.linkedAgentThreadID)
        let providerThreadID = try XCTUnwrap(try context.threadRepo.get(id: linkedThreadID)?.providerThreadId)
        XCTAssertEqual(try context.threadRepo.get(id: linkedThreadID)?.provider, .distill)
        XCTAssertEqual(try context.threadRepo.get(id: linkedThreadID)?.model, "gpt-6-luna")
        adapter.stopAll()

        let reopenedContext = try makeContext()
        let reopenedRouter = AppCommandRouter(context: reopenedContext)
        reopenedContext.router = reopenedRouter
        reopenedAdapter = DistillACPAdapter(binaryNameOverride: harnessURL.path)
        reopenedContext.coordinator.replaceProviderAdapter(.distill, adapter: try XCTUnwrap(reopenedAdapter))
        reopenedRouter.rememberProviderSnapshotsForSend([snapshot])
        let reopenedVM = BotsViewModel(context: reopenedContext, router: reopenedRouter)
        reopenedVM.openDesk(bot)
        reopenedVM.selectDeskThread(conversation.id)
        XCTAssertEqual(reopenedVM.selectedConversation?.linkedAgentThreadID, linkedThreadID)
        let reopenedThread = try XCTUnwrap(reopenedContext.threadRepo.get(id: linkedThreadID))
        XCTAssertEqual(reopenedThread.providerThreadId, providerThreadID,
                       "the Distill provider session id must survive constructing a fresh AppContext")
        XCTAssertEqual(reopenedThread.provider, reopenedVM.deskRouting.provider)
        XCTAssertEqual(reopenedThread.providerInstanceId, reopenedVM.deskRouting.providerInstanceID)
        XCTAssertEqual((reopenedThread.runAsUser ?? AgentRunAsUser.current()).uid, reopenedVM.deskRouting.runAsUser.uid)
        XCTAssertEqual((reopenedThread.runAsUser ?? AgentRunAsUser.current()).shortName, reopenedVM.deskRouting.runAsUser.shortName)
        XCTAssertEqual(reopenedVM.deskRunProvider, .distill)
        XCTAssertEqual(reopenedVM.deskRunModel, "gpt-6-luna")
        // The Auto Main effort gate reads the Desk provider catalog, which a fresh
        // Bots window fills from the router's send cache on its next turn.
        let reopenedCatalogLoaded = await waitUntil(timeout: 5) { !reopenedVM.providers.isEmpty }
        XCTAssertTrue(reopenedCatalogLoaded, "the reopened Desk must load the cached Distill provider snapshot")
        reopenedVM.composerText = "Follow-up Distill bot turn"
        XCTAssertTrue(reopenedVM.send())
        let followUpReplyArrived = await waitUntil(timeout: 8) {
            reopenedVM.deskMessages.contains { $0.role == .assistant && $0.text == "Bot Distill reply 2" }
        }
        guard followUpReplyArrived else {
            let messageSummary = reopenedVM.deskMessages.map { $0.text }.joined(separator: " | ")
            XCTFail("Distill follow-up missing; error=" + (reopenedVM.errorMessage ?? "nil")
                + "; messages=" + messageSummary)
            return
        }

        let requests = try String(contentsOf: requestsURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let open = try XCTUnwrap(
            requests.first { $0["method"] as? String == "session/new" },
            "ACP should start exactly one new Distill session"
        )
        XCTAssertEqual(open["modelId"] as? String, "gpt-6-luna",
                       "the selected Distill main model must be used at session creation")
        let methods = requests.compactMap { $0["method"] as? String }
        let load = try XCTUnwrap(
            requests.first { $0["method"] as? String == "session/load" },
            "a fresh Bot Desk context must recover the persisted provider session; methods=" + methods.joined(separator: ",")
        )
        XCTAssertEqual(load["sessionId"] as? String, providerThreadID)
        let prompts = requests.filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts.map { $0["firstRequestPresent"] as? Bool }, [true, false])
        XCTAssertEqual(prompts.map { $0["followUpPresent"] as? Bool }, [false, true])
        let launches = try String(contentsOf: launchesURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(launches.count, 2, "both Bot Desk provider processes must be observed")
        XCTAssertTrue(launches.allSatisfy { $0["tokenSaverHint"] == nil },
                      "Token Saver off must not admit compression into either Distill ACP process")
    }

    func test_deskProviderChoicePersistsPerThread_notPerBot() async throws {
        // WHY: one Bot can be called from Grok in one thread and Claude in
        // another. Reopening either thread must restore that user's choice
        // without turning either provider into a Bot property.
        let context = try makeContext()
        let bot: BotDefinition
        let grokThread: BotConversation
        let claudeThread: BotConversation
        let distillThread: BotConversation
        do {
            let vm = BotsViewModel(context: context)
            bot = try vm.create(
                name: "Piper",
                title: "Scout",
                provider: .codex,
                model: "legacy-only"
            )
            vm.openDesk(bot)
            vm.createDeskThread()
            vm.setDeskProvider(.grok)
            vm.setDeskModel("grok-4.6")
            grokThread = try XCTUnwrap(vm.selectedConversation)

            vm.createDeskThread()
            vm.setDeskProvider(.claude)
            vm.setDeskModel("opus")
            claudeThread = try XCTUnwrap(vm.selectedConversation)

            vm.createDeskThread()
            vm.setDeskProvider(.distill)
            vm.setDeskRoutingMode(.manual)
            vm.setDeskModel("gpt-6-luna")
            distillThread = try XCTUnwrap(vm.selectedConversation)

            vm.selectDeskThread(grokThread.id)
            XCTAssertEqual(vm.deskRunProvider, .grok)
            XCTAssertEqual(vm.deskRunModel, "grok-4.6")
            vm.selectDeskThread(claudeThread.id)
            XCTAssertEqual(vm.deskRunProvider, .claude)
            XCTAssertEqual(vm.deskRunModel, "opus")
        }
        // Desk routes are written after the interaction turn.
        let stored = await waitUntil(timeout: 5) {
            (try? context.botStore.listDeskRoutingJSON().count) == 3
        }
        XCTAssertTrue(stored)

        let restored = BotsViewModel(context: context)
        restored.openDesk(bot)
        restored.selectDeskThread(grokThread.id)
        XCTAssertEqual(restored.deskRunProvider, .grok)
        restored.selectDeskThread(claudeThread.id)
        XCTAssertEqual(restored.deskRunProvider, .claude)
        restored.selectDeskThread(distillThread.id)
        XCTAssertEqual(restored.deskRunProvider, .distill)
        XCTAssertEqual(restored.deskRunModel, "gpt-6-luna")
    }

    func test_deskSendUsesComposerProvider_notPublishedRoute() throws {
        // WHY: Bots were locked to the published revision provider. Desk
        // must send with the composer chips so a teammate can use Codex
        // after Studio published Claude.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        vm.setDeskProvider(.grok)
        vm.setDeskRoutingMode(.auto)
        vm.setDeskPermissionMode(.fullAccess)
        XCTAssertEqual(vm.deskRunProvider, .grok)
        XCTAssertEqual(vm.deskRunModel, BotsViewModel.defaultModel(for: .grok))
        XCTAssertEqual(vm.deskRunPermissionMode, .fullAccess)
        XCTAssertNil(vm.resolvedProvider(for: bot), "an unsent Bot still has no provider")
        vm.setDeskReasoningEffort(.high)
        XCTAssertEqual(vm.deskRunReasoning, .high)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("AgentAppView("), "Desk composer chips are the Agent App ones")
        XCTAssertFalse(
            source.contains("func deskChipLabel"),
            "Desk must not keep a private capsule fork"
        )
        guard let start = source.range(of: "private func startSupervisedRun") else {
            return XCTFail("startSupervisedRun must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    private func followLinkedRun")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("provider: routing.provider"))
        XCTAssertTrue(slice.contains("permissionMode: routing.permissionMode"))
        XCTAssertTrue(
            slice.contains("liveRunMode: routing.permissionMode"),
            "Desk assemble must compile the composer chip, not leftover Supervised honesty"
        )
        XCTAssertTrue(slice.contains("reasoningEffort: effort"))
        XCTAssertTrue(source.contains("runAsUser: routing.runAsUser"))
        XCTAssertTrue(slice.contains("workspace: nil"))
        XCTAssertFalse(
            slice.contains("provider: revision.provider"),
            "Desk send must not stay locked to the published Studio route"
        )
        XCTAssertFalse(
            slice.contains("reasoningEffort: revision.reasoningEffort"),
            "Desk send must use the composer reasoning chip"
        )
        XCTAssertTrue(
            source.contains("recordNeedsAttention(bot: bot, conversation: prepared.conversation"),
            "a failed provider start must preserve the Agent thread linked during preparation"
        )
    }

    func test_codexDeskSendSharesWorkspaceLessStartContract() throws {
        // WHY: Codex Desk send uses the same create/send helpers as Grok.
        // Workspace stays unbound; execution cwd is sanitized by the shared
        // resolver so Codex does not inherit an empty/relative currentDirectory.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        vm.setDeskProvider(.codex)
        vm.setDeskRoutingMode(.manual)
        vm.setDeskPermissionMode(.supervised)
        XCTAssertEqual(vm.deskRunProvider, .codex)
        let routerSource = try String(contentsOf: sourceURL("Sources/AppShell/AppCommandRouter.swift"), encoding: .utf8)
        XCTAssertTrue(routerSource.contains("GrokACPClient.resolvedSessionCwd(workspaceCwd)"))
        let empty = GrokACPClient.resolvedSessionCwd("", home: "/Users/fixture", fileExists: { _ in false })
        XCTAssertEqual(empty, "/Users/fixture")
        XCTAssertTrue(empty.hasPrefix("/"))
    }

    func test_deskHeaderFollowsComposerRoute() throws {
        // WHY: the identity row used to keep Studio's published Claude/opus
        // after the footer switched to Grok. The live send route must show.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        vm.setDeskProvider(.grok)
        vm.setDeskRoutingMode(.manual)
        vm.setDeskModel(BotsViewModel.defaultModel(for: .grok))
        vm.setDeskPermissionMode(.fullAccess)
        XCTAssertEqual(vm.deskRunProvider, .grok)
        XCTAssertEqual(vm.deskRunModel, BotsViewModel.defaultModel(for: .grok))
        XCTAssertEqual(vm.permissionLabel(for: bot), "Full access")
        XCTAssertNil(
            vm.resolvedProvider(for: bot),
            "an unsent Bot has no resolved provider outside the calling thread"
        )
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("bots.desk.provider"))
    }

    func test_botMentionParserResolvesHandle_excludingOpenTeammate() throws {
        // WHY: @ in Desk must pick another teammate. Mentioning yourself
        // would loop the same run instead of starting a peer turn.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        XCTAssertEqual(
            BotMentionParser.mentionedBots(in: "@quinn ping the inbox", bots: vm.bots, excluding: piper.id).map(\.id),
            [quinn.id]
        )
        XCTAssertTrue(
            BotMentionParser.mentionedBots(in: "@piper stay here", bots: vm.bots, excluding: piper.id).isEmpty
        )
        vm.composerText = "@q"
        XCTAssertEqual(vm.botMentionSuggestions.map(\.id), [quinn.id])
        vm.applyBotMention(quinn)
        XCTAssertTrue(vm.composerText.contains("@\(quinn.handle)"))
        XCTAssertNil(BotMentionParser.activeQuery(in: vm.composerText))
        vm.composerText = "@q"
        XCTAssertEqual(vm.composerSuggestions.first?.botHandle, quinn.handle)
        XCTAssertEqual(vm.composerSuggestions.first?.botAvatarSymbol, quinn.avatarSymbol)
    }

    func test_deskComposerListsProviderSkills_becauseDeskMustMatchAgentAppSlash() throws {
        // WHY: Desk used a TextField with no AgentComposerSuggestions. Agent
        // App `/sam` lists provider skills. Same catalog must feed Desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        vm.setDeskProvider(.grok)
        vm.replaceProvidersForTests([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [],
                slashCommands: ["/goal"],
                skills: ["sam-work", "sam-codex-advisor"]
            )
        ])
        vm.composerText = "/sam"
        let inserts = vm.composerSuggestions.map { $0.insertText.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(inserts.contains("/sam-work"))
        XCTAssertTrue(inserts.contains("/sam-codex-advisor"))
        XCTAssertTrue(vm.composerSuggestions.contains { $0.kind == .skill })
    }

    func test_claudeComposerCachesUntilCatalogChanges_becauseTypingMustStayFastAndFresh() throws {
        // WHY: SwiftUI reevaluates composer suggestions while the user types.
        // Repeated reads of one catalog (including an empty one) must reuse
        // discovery, while the short freshness bound must also catch skill
        // manifests installed or removed inside a pre-existing directory.
        let home = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("claude-home", isDirectory: true)
        let skills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        let commands = home.appendingPathComponent(".claude/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)

        func installSkill(_ name: String) throws {
            let skill = skills.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("# \(name)".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        }

        try installSkill("sam-work")
        let stagedSkill = skills.appendingPathComponent("sam-new", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedSkill, withIntermediateDirectories: true)
        let oldCommand = commands.appendingPathComponent("old-command.md")
        try Data("# old".utf8).write(to: oldCommand)

        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller")
        vm.openDesk(piper)
        vm.setDeskProvider(.claude)
        var discoveryCount = 0
        var cacheTime: TimeInterval = 100
        vm.claudeSlashCatalogRevisionForTesting = { _ in
            BotsViewModel.claudeSlashCatalogRevision(home: home.path)
        }
        vm.claudeSlashCacheTimeForTesting = { cacheTime }
        vm.claudeSlashDiscoveryForTesting = { _ in
            discoveryCount += 1
            return ClaudeSlashCommandDiscovery.discover(cwd: nil, home: home.path)
        }

        vm.composerText = "/sam"
        let first = vm.composerSuggestions
        vm.composerText = "/sam-w"
        let second = vm.composerSuggestions

        XCTAssertEqual(discoveryCount, 1)
        XCTAssertTrue(first.contains { $0.insertText == "/sam-work " })
        XCTAssertTrue(second.contains { $0.insertText == "/sam-work " })

        let beforeInstall = BotsViewModel.claudeSlashCatalogRevision(home: home.path)
        try Data("# sam-new".utf8).write(to: stagedSkill.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(
            BotsViewModel.claudeSlashCatalogRevision(home: home.path),
            beforeInstall,
            "writing SKILL.md inside an existing skill directory does not mutate the parent revision"
        )
        vm.composerText = "/sam-n"
        XCTAssertFalse(vm.composerSuggestions.contains { $0.insertText == "/sam-new " })
        XCTAssertEqual(discoveryCount, 1, "a stable fingerprint must remain a per-keystroke cache hit before TTL")

        cacheTime += 2
        let refreshed = vm.composerSuggestions
        XCTAssertEqual(discoveryCount, 2)
        XCTAssertTrue(refreshed.contains { $0.insertText == "/sam-new " })

        let beforeManifestRemoval = BotsViewModel.claudeSlashCatalogRevision(home: home.path)
        try FileManager.default.removeItem(at: stagedSkill.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(
            BotsViewModel.claudeSlashCatalogRevision(home: home.path),
            beforeManifestRemoval,
            "removing only SKILL.md also leaves the parent revision unchanged"
        )
        XCTAssertTrue(vm.composerSuggestions.contains { $0.insertText == "/sam-new " })
        XCTAssertEqual(discoveryCount, 2)
        cacheTime += 2
        XCTAssertFalse(vm.composerSuggestions.contains { $0.insertText == "/sam-new " })
        XCTAssertEqual(discoveryCount, 3, "TTL must bound stale nested-manifest results")

        let beforeCommandRemoval = BotsViewModel.claudeSlashCatalogRevision(home: home.path)
        try FileManager.default.removeItem(at: oldCommand)
        XCTAssertNotEqual(
            BotsViewModel.claudeSlashCatalogRevision(home: home.path),
            beforeCommandRemoval,
            "removing a normal ~/.claude/commands/<name>.md file must invalidate the cache"
        )
        vm.composerText = "/old"
        XCTAssertFalse(vm.composerSuggestions.contains { $0.insertText == "/old-command " })
        XCTAssertEqual(discoveryCount, 4)

        try FileManager.default.removeItem(at: skills.appendingPathComponent("sam-work"))
        try FileManager.default.removeItem(at: stagedSkill)
        vm.composerText = "/sam"
        XCTAssertFalse(vm.composerSuggestions.contains { $0.kind == .skill })
        _ = vm.composerSuggestions
        XCTAssertEqual(discoveryCount, 5,
            "a stable empty catalog must not rescan once per composer reevaluation")
        cacheTime += 2
        _ = vm.composerSuggestions
        XCTAssertEqual(discoveryCount, 6,
            "an empty or transiently failed discovery must be retried after the short TTL")

        vm.setDeskProvider(.grok)
        _ = vm.composerSuggestions
        XCTAssertEqual(discoveryCount, 6, "non-Claude providers must not touch the Claude filesystem")
    }

    func test_deskComposerOrdinaryTypingDoesNotLoadTheClaudeCatalog_becauseEveryRepaintReevaluates() throws {
        // WHY: the Desk composer bar reads `composerSuggestions` on every
        // keystroke and on every repaint behind its TimelineView. Loading the
        // disk-backed Claude catalog before `suggestions` can short-circuit on
        // the active token made ordinary text pay the catalog fingerprint (two
        // filesystem stats) for a suggestion list that is always empty.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller")
        vm.openDesk(piper)
        vm.setDeskProvider(.claude)
        var revisionReads = 0
        var discoveries = 0
        vm.claudeSlashCacheTimeForTesting = { 100 }
        vm.claudeSlashCatalogRevisionForTesting = { _ in
            revisionReads += 1
            return "fingerprint"
        }
        vm.claudeSlashDiscoveryForTesting = { _ in
            discoveries += 1
            return ["sam-work"]
        }

        vm.composerText = "resuma o inbox do Quinn"
        XCTAssertTrue(vm.composerSuggestions.isEmpty)
        XCTAssertEqual(revisionReads, 0, "plain text must not fingerprint the Claude catalog")
        XCTAssertEqual(discoveries, 0, "plain text must not discover the Claude catalog")

        // Fixture: the same evaluation path loads the catalog as soon as the
        // active token can consume it — the zeros above are the gate, not a
        // dead catalog path.
        vm.composerText = "/sam"
        XCTAssertTrue(vm.composerSuggestions.contains { $0.insertText == "/sam-work " })
        XCTAssertEqual(revisionReads, 1)
        XCTAssertEqual(discoveries, 1)

        // The fingerprint still runs on every catalog evaluation: a commands
        // file installed or removed mid-TTL must invalidate before the bound.
        vm.composerText = "/sam-w"
        _ = vm.composerSuggestions
        XCTAssertEqual(revisionReads, 2)
        XCTAssertEqual(discoveries, 1, "an unchanged fingerprint must still reuse discovery")
    }

    func test_deskApplyComposerSuggestionUsesCursorOffset() throws {
        // WHY: Desk used to apply at endIndex. Mid-prompt `/sam` must
        // replace that token, not the word after the caret.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        vm.setDeskProvider(.grok)
        vm.replaceProvidersForTests([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [],
                slashCommands: ["/goal"],
                skills: ["sam-work", "sam-codex-advisor"]
            )
        ])
        vm.composerText = "hello /sam more"
        vm.composerCursorOffset = nil
        XCTAssertTrue(
            vm.composerSuggestions.isEmpty,
            "nil cursor still anchors at the last token (`more`)"
        )
        vm.composerCursorOffset = ("hello /sam" as NSString).length
        let skill = try XCTUnwrap(vm.composerSuggestions.first { $0.kind == .skill })
        vm.applyComposerSuggestion(skill)
        XCTAssertTrue(vm.composerText.hasPrefix("hello \(skill.insertText.trimmingCharacters(in: .whitespaces))"))
        XCTAssertTrue(vm.composerText.contains("more"))
        XCTAssertFalse(vm.composerText.contains("/sam more"))
    }

    func test_workspacePinnedDeskSendRunsLikeNormalBotSend() async throws {
        // WHY: a pinned conversation keeps its identity but must run through the
        // normal bot path; the old contextual-isolation refusal blocked every send.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        let models = [AgentModelDescriptor(id: "main-model", label: "Main", provider: .distill)]
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill, models: models, binaryPath: "/usr/bin/true", authenticated: true, id: "distill",
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        let vm = BotsViewModel(context: context, router: router)
        vm.replaceProvidersForTests([snapshot])
        let bot = try vm.create(name: "Pinned", title: "Context", provider: .distill, model: "main-model")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = try router.createWorkspace(name: "Pinned WS", cwd: dir.path)
        _ = try context.botStore.grantContext(
            hostID: context.liveActivityHostIdentity.serverId, botID: bot.id,
            context: .workspace(workspace.id), actions: [.read, .send], expectedRevision: nil
        )
        vm.openDesk(bot)
        vm.deskRouting = BotDeskRouting(
            provider: .distill, providerInstanceID: "distill", model: "main-model",
            routingMode: .manual, runAsUser: .current()
        )
        XCTAssertTrue(vm.createDeskThread(in: .workspace(workspace.id)))
        let conversation = try XCTUnwrap(vm.selectedConversation)
        let threadID = try XCTUnwrap(conversation.linkedAgentThreadID)
        XCTAssertNotNil(try context.botStore.conversationContextPin(conversationID: conversation.id))

        vm.composerText = "hello"
        XCTAssertTrue(vm.send(), vm.errorMessage ?? "send refused")
        let started = await waitUntil(timeout: 8) { !runner.requests.isEmpty }
        XCTAssertTrue(started, vm.errorMessage ?? "run never started")
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.threadId, threadID)
        XCTAssertTrue(request.prompt.contains("hello"))
        // A normal desk send runs in the bot's own home (no workspace cwd); pinned runs match it.
        XCTAssertTrue(request.cwd.contains("/bots/"), "cwd was \(request.cwd)")
        XCTAssertTrue(runner.finish(runID: request.runId, status: .completed, reply: "hi"))
        let completed = await waitUntil(timeout: 8) {
            (try? context.runRepo.get(id: request.runId))?.status == .completed
        }
        XCTAssertTrue(completed)
        XCTAssertFalse((vm.errorMessage ?? "").contains("Contextual execution"))
        XCTAssertNil(vm.errorMessage)
        XCTAssertNotNil(try context.botStore.conversationContextPin(conversationID: conversation.id))
    }

    func test_revokedPinnedDeskSendStillRefuses() throws {
        // WHY: a revoked grant must stop sends even though pinned sends now run normally.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Pinned", title: "Context", provider: .distill)
        let host = context.liveActivityHostIdentity.serverId
        let binding = try context.botStore.grantContext(
            hostID: host, botID: bot.id, context: .general, actions: [.read, .send], expectedRevision: nil
        )
        let thread = AgentThread(title: "Pinned", provider: .distill, model: "test-main")
        let conversation = BotConversation(botID: bot.id, title: "New thread", linkedAgentThreadID: thread.id)
        try context.botStore.createContextualConversation(
            conversation, newThread: thread, hostID: host, context: .general, policyRevision: binding.policyRevision
        )
        _ = try context.botStore.revokeContext(
            hostID: host, botID: bot.id, context: .general, expectedRevision: binding.policyRevision
        )
        vm.openDesk(bot)
        vm.replaceProvidersForTests([
            AgentProviderSnapshotFactory.snapshot(
                provider: .distill, models: [],
                capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
            )
        ])
        vm.selectDeskThread(conversation.id)
        vm.composerText = "Keep draft"

        XCTAssertFalse(vm.send())
        XCTAssertEqual(vm.errorMessage, "Bot conversation context is no longer authorized.")
        XCTAssertEqual(vm.composerText, "Keep draft")
        XCTAssertTrue(try context.messageRepo.listRecent(threadId: thread.id, limit: 10).isEmpty)
    }

    func test_createDeskThreadStartsEmptyConversation() throws {
        // WHY: Desk had no + thread. Agent App can start a blank thread
        // before the first send.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.conversations.isEmpty)
        vm.createDeskThread()
        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertEqual(vm.selectedConversation?.title, "New thread")
        XCTAssertTrue(vm.deskMessages.isEmpty)
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 1)
    }

    func test_selectDeskThreadRestoresThatConversation() throws {
        // WHY: dest cache was per-bot. Switching threads must not keep
        // the previous transcript.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("ALPHA"))
        let first = try XCTUnwrap(vm.selectedConversation)
        vm.createDeskThread()
        XCTAssertTrue(vm.send("BRAVO"))
        let second = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(first.id, second.id)
        vm.selectDeskThread(first.id)
        XCTAssertEqual(vm.selectedConversation?.id, first.id)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("ALPHA") })
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("BRAVO") })
        vm.selectDeskThread(second.id)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("BRAVO") })
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("ALPHA") })
    }

    func test_deferredSelectDeskThreadPaintsCachedConversationWithoutStoreRead() throws {
        // WHY: messagesByBot was per-teammate, so a rail click painted empty
        // (or the other thread) until listRecent ran after the first frame.
        // Warm conversation cache is the dest; SQLite belongs in freshness.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("ALPHA"))
        let first = try XCTUnwrap(vm.selectedConversation)
        vm.createDeskThread()
        XCTAssertTrue(vm.send("BRAVO"))
        let second = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(first.id, second.id)

        vm.enableNavigationFirstFrameDeferral()
        let restoresBefore = vm.deskMessageRestoreCountForTesting
        let getsBefore = context.threadRepo.durableGetCountForTesting
        vm.selectDeskThread(first.id)
        XCTAssertEqual(vm.selectedConversation?.id, first.id)
        XCTAssertTrue(
            vm.deskMessages.contains { $0.text.contains("ALPHA") },
            "first paint must already show the cached ALPHA thread"
        )
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("BRAVO") })
        XCTAssertEqual(
            vm.deskMessageRestoreCountForTesting,
            restoresBefore,
            "warm thread switch must not listRecent on the click turn"
        )
        XCTAssertEqual(
            context.threadRepo.durableGetCountForTesting,
            getsBefore,
            "warm thread switch must not get() routing on the click turn"
        )

        vm.selectDeskThread(second.id)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("BRAVO") })
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("ALPHA") })
        XCTAssertEqual(vm.deskMessageRestoreCountForTesting, restoresBefore)
    }

    func test_deferredOpenDeskPaintsCachedBotWithoutStoreRead() throws {
        // WHY: roster click still prefetched listChrome and could paint the
        // previous teammate's inspector until freshness. Warm dest must
        // publish Piper's transcript and conversations with no store read.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("PIPER-MSG"))
        let piperConversation = try XCTUnwrap(vm.selectedConversation)
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("QUINN-MSG"))
        let quinnConversation = try XCTUnwrap(vm.selectedConversation)
        vm.openDesk(piper)

        vm.enableNavigationFirstFrameDeferral()
        let restoresBefore = vm.deskMessageRestoreCountForTesting
        let chromeBefore = context.threadRepo.listChromeCallCountForTesting
        let getsBefore = context.threadRepo.durableGetCountForTesting
        let studioBefore = vm.studioSupportReloadCountForTesting

        vm.openDesk(quinn)
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedConversation?.id, quinnConversation.id)
        XCTAssertTrue(
            vm.conversations.allSatisfy { $0.botID == quinn.id },
            "first paint must not keep Piper's thread list"
        )
        XCTAssertTrue(
            vm.deskMessages.contains { $0.text.contains("QUINN-MSG") },
            "first paint must already show Quinn's cached transcript"
        )
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("PIPER-MSG") })
        XCTAssertEqual(vm.deskMessageRestoreCountForTesting, restoresBefore)
        XCTAssertEqual(
            context.threadRepo.listChromeCallCountForTesting,
            chromeBefore,
            "roster click must not prefetch rail chrome on the click turn"
        )
        XCTAssertEqual(
            context.threadRepo.durableGetCountForTesting,
            getsBefore,
            "roster click must not get() thread routing on the click turn"
        )
        XCTAssertEqual(
            vm.studioSupportReloadCountForTesting,
            studioBefore,
            "warm roster click must reuse the inspector snapshot"
        )

        vm.openDesk(piper)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.selectedConversation?.id, piperConversation.id)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("PIPER-MSG") })
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("QUINN-MSG") })
        XCTAssertTrue(vm.conversations.allSatisfy { $0.botID == piper.id })
        XCTAssertEqual(vm.deskMessageRestoreCountForTesting, restoresBefore)
        XCTAssertEqual(context.threadRepo.listChromeCallCountForTesting, chromeBefore)
        XCTAssertEqual(context.threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_deskThreadRailMountsSharedAgentChrome_becauseDestMustNotForkTheRail() throws {
        // WHY: dest asked for Agent App threads. A lookalike dest
        // header would drift from toggle, Clear All, search, and +.
        let dest = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let agent = try String(contentsOf: sourceURL("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatSharedChrome.swift"), encoding: .utf8)
        XCTAssertTrue(chrome.contains("public struct AgentChatThreadRail"))
        XCTAssertTrue(dest.contains("AgentChatThreadRail("))
        XCTAssertTrue(agent.contains("AgentChatThreadRail("))
        XCTAssertTrue(dest.contains("bots.desk.thread.clearAll"))
        XCTAssertTrue(dest.contains("bots.desk.thread.hide"))
        XCTAssertTrue(dest.contains("bots.desk.thread.search"))
        XCTAssertTrue(dest.contains("bots.desk.thread.new"))
    }

    func test_deskThreadSearchFiltersConversations_becauseRailMustReuseAgentSearch() throws {
        // WHY: dest rail copies Agent App search. Typing a title must hide
        // other dest threads so the user can find one conversation.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Standup notes"))
        vm.createDeskThread()
        XCTAssertTrue(vm.send("Invoice follow-up"))
        XCTAssertEqual(vm.conversations.count, 2)
        vm.deskThreadSearchQuery = "stand"
        XCTAssertEqual(vm.filteredDeskConversations.map(\.title), ["Standup notes"])
        vm.deskThreadSearchQuery = "auth"
        XCTAssertTrue(vm.filteredDeskConversations.isEmpty)
        vm.deskThreadSearchQuery = ""
        XCTAssertEqual(vm.filteredDeskConversations.count, 2)
    }

    func test_deskThreadRailVisibilityPersists_becauseClosingRemoteCodeMustRestoreTheChoice() throws {
        // WHY: user workflow state must survive reopen. Hide dest threads
        // must come back hidden.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertTrue(vm.isDeskThreadRailVisible)
        vm.isDeskThreadRailVisible = false
        let restored = BotsViewModel(context: context)
        XCTAssertFalse(restored.isDeskThreadRailVisible)
    }

    func test_createDeskThreadKeepsRailAndInspectorHidden_becausePlusMustNotOpenSidebars() throws {
        // WHY: the header + and the FAB exist so the user can start a thread
        // without opening the THREADS column. Forcing it open also overwrote
        // the saved hide choice, so the next launch came back with it shown.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        vm.isDeskThreadRailVisible = false
        vm.isDeskSidePaneVisible = false

        XCTAssertTrue(vm.createDeskThread())

        XCTAssertFalse(vm.isDeskThreadRailVisible, "+ must not open the threads rail")
        XCTAssertFalse(vm.isDeskSidePaneVisible, "+ must not open the inspector")
        XCTAssertEqual(vm.selectedConversation?.title, "New thread", "the chat still moves to the new thread")
        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertFalse(
            BotsViewModel(context: context).isDeskThreadRailVisible,
            "the hidden choice must survive reopen"
        )
    }

    func test_routineTestRunKeepsHiddenThreadRail_becauseTestRunMustNotOpenSidebars() throws {
        // WHY: a test run starts its own thread through the same path as +.
        // It must not open the rail nor rewrite the saved hide choice.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        vm.isDeskThreadRailVisible = false

        vm.requestRoutineTestRun(id: routine.definition.id)

        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.filter { $0.role == .user }.map(\.text), [routine.definition.prompt])
        XCTAssertFalse(vm.isDeskThreadRailVisible, "a test run must not open the threads rail")
        XCTAssertFalse(
            BotsViewModel(context: context).isDeskThreadRailVisible,
            "the hidden choice must survive reopen"
        )
    }

    func test_deskNewThreadFABSitsOnTheChatColumn_becauseAHiddenRailMustNotHideIt() throws {
        // WHY: the user keeps the THREADS rail hidden. A + inside the rail
        // would never show; the FAB lives on the chat column, outside the
        // rail branch, and runs the same action and copy as the other +.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let fabStart = try XCTUnwrap(source.range(of: "private var deskNewThreadFAB: some View {"))
        let fabRest = source[fabStart.upperBound...]
        let fabEnd = fabRest.range(of: "\n    private ")?.lowerBound ?? fabRest.endIndex
        let fab = String(source[fabStart.lowerBound..<fabEnd])
        XCTAssertTrue(fab.contains("vm.createDeskThread()"), "one action for every +")
        XCTAssertTrue(fab.contains("bots.desk.thread.new.fab"))
        XCTAssertTrue(fab.contains("AgentChatNewThreadFAB("), "the Agent App and the desk share one FAB")
        XCTAssertFalse(fab.contains("isDeskThreadRailVisible"), "the FAB must not touch panel visibility")

        let chatStart = try XCTUnwrap(source.range(of: "private func deskChat"))
        let chatRest = source[chatStart.upperBound...]
        let chatEnd = chatRest.range(of: "\n    private func deskUnlinkedComposer")?.lowerBound ?? chatRest.endIndex
        let chat = String(source[chatStart.lowerBound..<chatEnd])
        // The owner asked for it blue, bottom-right just above the composer:
        // the transcript's trailing accessory slot, where scroll-to-latest
        // stacks on top of it instead of overlapping it.
        let shared = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatNewThreadFAB.swift"), encoding: .utf8)
        XCTAssertTrue(shared.contains("DS.Palette.accent"), "the FAB is the accent (blue) action")
        let mount = try XCTUnwrap(
            chat.range(of: "timelineAccessory: AnyView(deskNewThreadFAB)"),
            "the linked chat mounts the FAB in the transcript's bottom-trailing slot"
        )
        let railBranch = try XCTUnwrap(chat.range(of: "deskThreadRail\n"))
        let inspector = try XCTUnwrap(chat.range(of: "if vm.isDeskSidePaneVisible"))
        XCTAssertLessThan(railBranch.lowerBound, mount.lowerBound, "mounted on the chat column, after the rail branch")
        XCTAssertLessThan(mount.lowerBound, inspector.lowerBound, "not inside the inspector branch")
        XCTAssertFalse(chat.contains(".overlay(alignment: .trailing) {\n                deskNewThreadFAB"),
                       "no mid-column float over the transcript")

        let unlinkedStart = try XCTUnwrap(source.range(of: "private func deskUnlinkedComposer"))
        let unlinkedRest = source[unlinkedStart.upperBound...]
        let composer = try XCTUnwrap(unlinkedRest.range(of: "AgentChatComposerBar("))
        XCTAssertTrue(String(unlinkedRest[..<composer.lowerBound]).contains("deskNewThreadFAB"),
                      "a thread with no run yet keeps the FAB in the same corner, above its composer")

        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatTimelineChrome.swift"), encoding: .utf8)
        let scrollDown = try XCTUnwrap(chrome.range(of: "accessibilityIdentifier(scrollToBottomIdentifier)"))
        let accessory = try XCTUnwrap(chrome.range(of: "if let trailingAccessory {"))
        XCTAssertLessThan(scrollDown.lowerBound, accessory.lowerBound,
                          "scroll-to-latest stacks above the accessory in the same corner")

        let rail = try XCTUnwrap(source.range(of: "private var deskThreadRail: some View {"))
        let railRest = source[rail.upperBound...]
        let railEnd = railRest.range(of: "\n    private ")?.lowerBound ?? railRest.endIndex
        XCTAssertFalse(String(source[rail.lowerBound..<railEnd]).contains("deskNewThreadFAB"),
                       "inside the rail it would vanish with the rail")
    }

    func test_clearAllDeskThreadsDeletesOnlyThatBot_becauseClearAllMustNotWipeTheFleet() throws {
        // WHY: dest Clear All is this teammate's dest list, not every bot
        // and not Agent App workspace threads.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        let quinn = try vm.create(name: "Quinn", title: "CRM", provider: .claude)
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("Quinn inbox"))
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Piper first"))
        vm.createDeskThread()
        XCTAssertTrue(vm.send("Piper second"))
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 2)
        XCTAssertEqual(try context.botStore.listConversations(botID: quinn.id).count, 1)
        vm.clearAllDeskThreads()
        XCTAssertTrue(vm.conversations.isEmpty)
        XCTAssertNil(vm.selectedConversation)
        XCTAssertTrue(vm.deskMessages.isEmpty)
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 0)
        XCTAssertEqual(try context.botStore.listConversations(botID: quinn.id).count, 1)
        XCTAssertEqual(try context.botStore.listConversations(botID: quinn.id).first?.title, "Quinn inbox")
        XCTAssertEqual(vm.attentionState(for: piper), .none)
        XCTAssertEqual(vm.openAttentionCount, 1, "only Quinn's live thread still needs attention")

        let reopened = BotsViewModel(context: context)
        let reopenedPiper = try XCTUnwrap(reopened.fleet.first(where: { $0.id == piper.id }))
        XCTAssertEqual(reopened.attentionState(for: reopenedPiper), .none)
        XCTAssertEqual(reopened.openAttentionCount, 1)
    }

    func test_clearAllDeskThreadsLeavesEmptyRail_becausePlusStartsTheNextConversation() throws {
        // WHY: after Clear All, dest should match Agent App empty state so
        // send/create can start a new thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("old work"))
        vm.clearAllDeskThreads()
        XCTAssertTrue(vm.conversations.isEmpty)
        vm.createDeskThread()
        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertEqual(vm.selectedConversation?.title, "New thread")
        XCTAssertTrue(vm.deskMessages.isEmpty)
        XCTAssertTrue(vm.send("fresh start"))
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 1)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("fresh start") })
    }

    func test_clearAllDeskThreadsRetiresOnlyVictimActiveHandoffWithoutResurrectionOrV1Rewrite() async throws {
        // WHY: Clear All is a real deletion boundary, not a cosmetic rail reset.
        // It must cancel the deleted conversation's exact continuation while a
        // sibling Bot handoff and the downgrade-readable v1 bytes remain intact.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let piperPeerRunner = ControlledBotHandoffRunner(provider: .codex)
        let roryPeerRunner = ControlledBotHandoffRunner(provider: .grok)
        let piperHostRunner = ControlledBotHandoffRunner(provider: .codex)
        let roryHostRunner = ControlledBotHandoffRunner(provider: .grok)
        let viewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = viewModel
        let piper = try viewModel.create(name: "Piper", title: "Seller", provider: .codex)
        let rory = try viewModel.create(name: "Rory", title: "Researcher", provider: .grok)
        let quinn = try viewModel.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        context.coordinator.replaceProvider(
            .codex,
            runner: CallerThreadHandoffRunner(
                hostRunner: piperHostRunner,
                peerRunners: [quinn.id: piperPeerRunner]
            )
        )
        context.coordinator.replaceProvider(
            .grok,
            runner: CallerThreadHandoffRunner(
                hostRunner: roryHostRunner,
                peerRunners: [quinn.id: roryPeerRunner]
            )
        )
        viewModel.openDesk(quinn)
        viewModel.setDeskProvider(.claude)
        viewModel.openDesk(piper)
        viewModel.setDeskProvider(.codex)
        viewModel.openDesk(rory)
        viewModel.setDeskProvider(.grok)

        viewModel.openDesk(piper)
        viewModel.setDeskProvider(.codex)
        viewModel.createDeskThread()
        let victimConversation = try XCTUnwrap(viewModel.selectedConversation)
        let victimMilestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: viewModel,
            peer: quinn,
            prompt: "@\(quinn.handle) T005_CLEAR_VICTIM"
        )
        let victimStarted = await waitUntil(timeout: 5) {
            piperPeerRunner.requests.contains { $0.prompt.contains("T005_CLEAR_VICTIM") }
        }
        XCTAssertTrue(victimStarted)

        viewModel.openDesk(rory)
        viewModel.setDeskProvider(.grok)
        viewModel.createDeskThread()
        let siblingConversation = try XCTUnwrap(viewModel.selectedConversation)
        let siblingMilestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: viewModel,
            peer: quinn,
            prompt: "@\(quinn.handle) T005_CLEAR_SIBLING"
        )
        let siblingStarted = await waitUntil(timeout: 5) {
            roryPeerRunner.requests.contains { $0.prompt.contains("T005_CLEAR_SIBLING") }
        }
        XCTAssertTrue(siblingStarted)
        let victim = try XCTUnwrap(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: victimConversation.id,
            originThreadID: nil
        ).first)
        let sibling = try XCTUnwrap(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: siblingConversation.id,
            originThreadID: nil
        ).first)
        let victimRunID = try XCTUnwrap(victim.peerRunID)
        let siblingRunID = try XCTUnwrap(sibling.peerRunID)
        let legacyBytes = Data(#"{"t005":"leave-v1-byte-exact"}"#.utf8)
        UserDefaults.standard.set(legacyBytes, forKey: "bots.peerTurns")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        viewModel.openDesk(piper)
        viewModel.selectDeskThread(victimConversation.id)
        viewModel.clearAllDeskThreads()
        let victimCancelled = await waitUntil(timeout: 2) {
            (try? context.runRepo.get(id: victimRunID)?.status) == .cancelled
        }
        XCTAssertTrue(victimCancelled, "Clear All must cancel the deleted origin's exact live run")
        XCTAssertTrue(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: victimConversation.id,
            originThreadID: nil
        ).isEmpty)
        XCTAssertEqual(
            viewModel.peerHandoffSnapshotsForTesting(
                originConversationID: siblingConversation.id,
                originThreadID: nil
            ).first?.peerRunID,
            siblingRunID,
            "the sibling handoff must remain owned and running"
        )
        XCTAssertEqual(try context.runRepo.get(id: siblingRunID)?.status, .running)
        XCTAssertFalse(
            piperPeerRunner.finish(runID: victimRunID, status: .completed, reply: "LATE_VICTIM_REPLY"),
            "provider cancellation must retire the victim callback so it cannot resurrect"
        )
        viewModel.reconcilePeerHandoffsForTesting()
        let reloaded = BotsViewModel(context: context, router: router)
        XCTAssertTrue(reloaded.peerHandoffSnapshotsForTesting(
            originConversationID: victimConversation.id,
            originThreadID: nil
        ).isEmpty)
        XCTAssertEqual(
            reloaded.peerHandoffSnapshotsForTesting(
                originConversationID: siblingConversation.id,
                originThreadID: nil
            ).first?.peerRunID,
            siblingRunID
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)

        XCTAssertTrue(roryPeerRunner.finish(
            runID: siblingRunID,
            status: .completed,
            reply: "sibling remains exact"
        ))
        let siblingCompleted = await waitUntil(timeout: 5) {
            reloaded.peerHandoffSnapshotsForTesting(
                originConversationID: siblingConversation.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(siblingCompleted)
        XCTAssertNil(reloaded.peerHandoffSnapshotsForTesting(
            originConversationID: siblingConversation.id,
            originThreadID: nil
        ).first?.hostRunID)
        XCTAssertTrue(piperHostRunner.requests.isEmpty)
        XCTAssertTrue(roryHostRunner.requests.isEmpty)
        await victimMilestone.value
        await siblingMilestone.value
    }

    func test_sendContinuesSelectedConversation() throws {
        // WHY: two ordinary sends on one dest thread must stay one row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("first"))
        XCTAssertTrue(vm.send("second"))
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 1)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("first") })
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("second") })
    }

    func test_deskMentionStartsWithPrimaryAI_becauseOnlyItMayAuthorThePeerPrompt() async throws {
        // WHY: the app cannot know whether an @mention is a direct ask, a
        // consultation, or merely context. The selected Bot's primary AI must
        // receive the complete request before any peer provider starts.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        context.coordinator.replaceProvider(
            .codex,
            runner: CallerThreadHandoffRunner(hostRunner: hostRunner, peerRunners: [quinn.id: peerRunner])
        )
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)
        vm.setDeskPermissionMode(.fullAccess)

        let prompt = "pergunte ao @\(quinn.handle) o nome dele e depois continue o trabalho"
        XCTAssertTrue(vm.send(prompt))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        XCTAssertTrue(hostRequest.prompt.hasSuffix("User request:\n\n\(prompt)"))
        XCTAssertEqual(hostRequest.permissionMode, .fullAccess)
        XCTAssertTrue(peerRunner.requests.isEmpty, "RemoteCode must not pre-dispatch a mention")
        XCTAssertTrue(vm.peerHandoffSnapshotsForTesting().isEmpty)
        XCTAssertTrue(hostRunner.finish(runID: hostRequest.runId, status: .completed, reply: "done"))
    }

    func test_deskCompoundMentionIsInterpretedByPrimaryAIThenDelegatesFocusedPrompt() async throws {
        // WHY: the original request contains two different jobs. Only the
        // primary AI may decide the peer ask; RemoteCode must transport that
        // new prompt literally and keep one primary run for the remaining work.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        let untouched = try vm.create(name: "Untouched", title: "Observer", provider: .grok)
        context.coordinator.replaceProvider(
            .codex,
            runner: CallerThreadHandoffRunner(hostRunner: hostRunner, peerRunners: [quinn.id: peerRunner])
        )
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        let prompt = "pergunte ao @\(quinn.handle) o nome dele e com base na resposta dê outro nome para ele. Faça a alteração agora sem pedir confirmação e no final diga qual nome foi aplicado."
        XCTAssertTrue(vm.send(prompt))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        XCTAssertTrue(
            hostRequest.prompt.hasSuffix("User request:\n\n\(prompt)"),
            "the primary AI must receive the complete turn first"
        )
        let turnDirective = try XCTUnwrap(BotPeerDelegation.turnDirective(mentionedBots: [quinn]))
        XCTAssertTrue(hostRequest.prompt.contains(turnDirective))
        XCTAssertEqual(BotDeskPeer(direction: .messaged, bot: quinn).caption, "Mentions Quinn")
        XCTAssertTrue(peerRunner.requests.isEmpty)

        let focusedPrompt = "Qual é o seu nome?"
        let ask = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: hostRequest.threadId,
                callerRun: hostRequest.runId,
                handle: "@\(quinn.handle)",
                prompt: focusedPrompt,
                replyMode: .consult,
                delegationCapability: hostRequest.environment[AgentDelegationCapabilityTransport.environmentKey]
            )
        }
        let peerStarted = await waitUntil(timeout: 5) { !peerRunner.requests.isEmpty }
        XCTAssertTrue(peerStarted)
        let peerRequest = try XCTUnwrap(peerRunner.requests.first)
        XCTAssertTrue(peerRequest.prompt.contains(focusedPrompt))
        XCTAssertFalse(peerRequest.prompt.contains("com base na resposta"))
        XCTAssertFalse(peerRequest.prompt.contains("Faça a alteração"))
        XCTAssertTrue(peerRunner.finish(
            runID: peerRequest.runId,
            status: .completed,
            reply: "Meu nome atual é Quinn."
        ))
        let result = try await ask.value
        XCTAssertEqual(result.objectValue?["reply"]?.stringValue, "Meu nome atual é Quinn.")

        _ = try router.invokeDelegatedBotSelfConfig(
            callerThread: hostRequest.threadId,
            callerRun: hostRequest.runId,
            toolName: BotSelfConfigCatalog.setSettings,
            arguments: [
                "bot_id": .string(quinn.id.value.uuidString.lowercased()),
                "name": .string("Nova"),
            ],
            delegationCapability: hostRequest.environment[AgentDelegationCapabilityTransport.environmentKey]
        )
        XCTAssertEqual(try context.botStore.get(id: quinn.id)?.name, "Nova")
        XCTAssertEqual(try context.botStore.get(id: untouched.id)?.name, "Untouched")
        XCTAssertEqual(hostRunner.requests.count, 1, "the original primary run must continue in place")

        XCTAssertTrue(hostRunner.finish(
            runID: hostRequest.runId,
            status: .completed,
            reply: "Nome aplicado: Nova."
        ))
        let hostCompleted = await waitUntil(timeout: 5) {
            context.coordinator.activeRunId(threadId: hostRequest.threadId) == nil
        }
        XCTAssertTrue(hostCompleted)

        let transcript = vm.deskTranscriptForTesting(botID: piper.id)
        XCTAssertEqual(transcript.filter {
            $0.role == .user
                && $0.peer?.direction == .messaged
                && $0.text == focusedPrompt
        }.count, 1)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant
                && $0.peer?.direction == .fromPeer
                && $0.text == "Meu nome atual é Quinn."
        }.count, 1)
        let originRows = try context.messageRepo.listRecent(threadId: hostRequest.threadId, limit: 16)
        XCTAssertEqual(originRows.filter { $0.role == .user && $0.content.contains(prompt) }.count, 1)
        XCTAssertEqual(originRows.filter { $0.role == .assistant }.count, 1)
    }

    func test_botPrimaryCanMediateMultiplePeersUntilConsensus() async throws {
        // WHY: a Bot-owned primary turn must be able to gather real input from
        // multiple peers without replacing its run or duplicating the durable
        // attributed replies when it publishes the mediated answer.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let quinnRunner = ControlledBotHandoffRunner(provider: .codex)
        let roryRunner = ControlledBotHandoffRunner(provider: .codex)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Mediator", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        let rory = try vm.create(name: "Rory", title: "Researcher", provider: .grok)
        context.coordinator.replaceProvider(
            .codex,
            runner: CallerThreadHandoffRunner(
                hostRunner: hostRunner,
                peerRunners: [quinn.id: quinnRunner, rory.id: roryRunner]
            )
        )
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        let original = "Consulte @\(quinn.handle) e @\(rory.handle), confronte as propostas e publique um consenso final."
        XCTAssertTrue(vm.send(original))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        let originConversation = try XCTUnwrap(vm.selectedConversation)
        XCTAssertTrue(hostRequest.prompt.hasSuffix("User request:\n\n\(original)"))
        let turnDirective = try XCTUnwrap(BotPeerDelegation.turnDirective(mentionedBots: [quinn, rory]))
        XCTAssertTrue(hostRequest.prompt.contains(turnDirective))
        XCTAssertTrue(quinnRunner.requests.isEmpty)
        XCTAssertTrue(roryRunner.requests.isEmpty)

        let quinnPrompt = "Proponha uma política de contato em uma frase e explique o principal benefício."
        let askQuinn = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: hostRequest.threadId,
                callerRun: hostRequest.runId,
                handle: quinn.handle,
                prompt: quinnPrompt,
                replyMode: .consult,
                delegationCapability: hostRequest.environment[AgentDelegationCapabilityTransport.environmentKey]
            )
        }
        let quinnStarted = await waitUntil(timeout: 5) { quinnRunner.requests.count == 1 }
        XCTAssertTrue(quinnStarted)
        let quinnRequest = try XCTUnwrap(quinnRunner.requests.first)
        XCTAssertTrue(quinnRequest.prompt.contains(quinnPrompt))
        XCTAssertFalse(quinnRequest.prompt.contains(original))
        let quinnWireReply = "Priorize clientes com consentimento recente para reduzir contato indesejado."
        XCTAssertTrue(quinnRunner.finish(
            runID: quinnRequest.runId,
            status: .completed,
            reply: quinnWireReply
        ))
        let quinnResult = try await askQuinn.value
        let quinnReply = try XCTUnwrap(quinnResult.objectValue?["reply"]?.stringValue)
        XCTAssertEqual(quinnReply, quinnWireReply)
        XCTAssertEqual(quinnResult.objectValue?["reply_mode"]?.stringValue, "consult")
        XCTAssertEqual(quinnResult.objectValue?["attributed_reply_already_displayed"]?.boolValue, true)
        XCTAssertEqual(context.coordinator.activeRunId(threadId: hostRequest.threadId), hostRequest.runId)

        let roryPrompt = "Quinn respondeu: \"\(quinnReply)\" Compare essa proposta com a evidência disponível e recomende um ajuste."
        let askRory = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: hostRequest.threadId,
                callerRun: hostRequest.runId,
                handle: "@\(rory.handle)",
                prompt: roryPrompt,
                replyMode: .consult,
                delegationCapability: hostRequest.environment[AgentDelegationCapabilityTransport.environmentKey]
            )
        }
        let roryStarted = await waitUntil(timeout: 5) { roryRunner.requests.count == 1 }
        XCTAssertTrue(roryStarted)
        let roryRequest = try XCTUnwrap(roryRunner.requests.first)
        XCTAssertTrue(roryRequest.prompt.contains(roryPrompt))
        XCTAssertTrue(roryRequest.prompt.contains(quinnReply), "the follow-up must use Quinn's real reply")
        XCTAssertFalse(roryRequest.prompt.contains(original))
        let roryWireReply = "Mantenha o consentimento recente e acrescente um limite semanal mensurável."
        XCTAssertTrue(roryRunner.finish(
            runID: roryRequest.runId,
            status: .completed,
            reply: roryWireReply
        ))
        let roryResult = try await askRory.value
        let roryReply = try XCTUnwrap(roryResult.objectValue?["reply"]?.stringValue)
        XCTAssertEqual(roryReply, roryWireReply)
        XCTAssertEqual(roryResult.objectValue?["reply_mode"]?.stringValue, "consult")
        XCTAssertEqual(roryResult.objectValue?["attributed_reply_already_displayed"]?.boolValue, true)
        XCTAssertEqual(hostRunner.requests.count, 1, "both consultations must keep the original primary run")
        XCTAssertEqual(context.coordinator.activeRunId(threadId: hostRequest.threadId), hostRequest.runId)

        let consensus = "Consenso: usar consentimento recente e limitar cada cliente a um contato por semana."
        XCTAssertTrue(consensus.contains("consentimento recente"), "the consensus must retain Quinn's recommendation")
        XCTAssertTrue(consensus.contains("um contato por semana"), "the consensus must apply Rory's adjustment")
        XCTAssertTrue(hostRunner.finish(
            runID: hostRequest.runId,
            status: .completed,
            reply: consensus
        ))
        let hostCompleted = await waitUntil(timeout: 5) {
            context.coordinator.activeRunId(threadId: hostRequest.threadId) == nil
        }
        XCTAssertTrue(hostCompleted)

        let handoffs = vm.peerHandoffSnapshotsForTesting(
            originConversationID: originConversation.id,
            originThreadID: nil
        )
        XCTAssertEqual(handoffs.count, 2)
        XCTAssertEqual(Set(handoffs.map(\.peerBotID)), Set([quinn.id, rory.id]))
        XCTAssertTrue(handoffs.allSatisfy {
            $0.originBotID == piper.id
                && $0.originConversationID == originConversation.id
                && $0.originThreadID == nil
                && $0.hostRunID == hostRequest.runId
                && $0.phase == .completed
        })

        let restored = BotsViewModel(context: context, router: router)
        restored.openDesk(piper)
        let transcript = restored.deskTranscriptForTesting(botID: piper.id)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant
                && $0.peer?.direction == .fromPeer
                && $0.peer?.botID == quinn.id
                && $0.text == quinnReply
        }.count, 1)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant
                && $0.peer?.direction == .fromPeer
                && $0.peer?.botID == rory.id
                && $0.text == roryReply
        }.count, 1)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant && $0.peer == nil && $0.text == consensus
        }.count, 1)
        let originRows = try context.messageRepo.listRecent(threadId: hostRequest.threadId, limit: 32)
        XCTAssertEqual(originRows.filter { $0.role == .user && $0.content.contains(original) }.count, 1)
        XCTAssertEqual(originRows.filter { $0.role == .assistant && $0.content == consensus }.count, 1)
    }

    func test_deskReplyOnlyShowsOneAttributedBotReplyWithoutPrimaryDuplicate() async throws {
        // WHY: the primary AI may decide that the named Bot's answer completes
        // the whole turn. The Bot row is then the answer; any generic primary
        // final must be suppressed from both storage and the live Desk.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        context.coordinator.replaceProvider(
            .codex,
            runner: CallerThreadHandoffRunner(hostRunner: hostRunner, peerRunners: [quinn.id: peerRunner])
        )
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        let original = "@\(quinn.handle) você está por aí?"
        XCTAssertTrue(vm.send(original))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        XCTAssertTrue(hostRequest.prompt.hasSuffix("User request:\n\n\(original)"))

        let focused = "Você está por aí?"
        let ask = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: hostRequest.threadId,
                callerRun: hostRequest.runId,
                handle: quinn.handle,
                prompt: focused,
                replyMode: .replyOnly,
                delegationCapability: hostRequest.environment[AgentDelegationCapabilityTransport.environmentKey]
            )
        }
        let peerStarted = await waitUntil(timeout: 5) { !peerRunner.requests.isEmpty }
        XCTAssertTrue(peerStarted)
        let peerRequest = try XCTUnwrap(peerRunner.requests.first)
        XCTAssertTrue(peerRequest.prompt.contains(focused))
        XCTAssertTrue(peerRunner.finish(
            runID: peerRequest.runId,
            status: .completed,
            reply: "Estou por aqui — manda o próximo."
        ))
        _ = try await ask.value

        let duplicate = "Sim, estou aqui. Como posso ajudar?"
        XCTAssertTrue(hostRunner.finish(
            runID: hostRequest.runId,
            status: .completed,
            reply: duplicate
        ))
        let completed = await waitUntil(timeout: 5) {
            context.coordinator.activeRunId(threadId: hostRequest.threadId) == nil
        }
        XCTAssertTrue(completed)
        let attentionSettled = await waitUntil(timeout: 5) {
            vm.attentionState(for: piper) == .none
        }
        XCTAssertTrue(
            attentionSettled,
            "the terminal callback must settle the primary Bot after reply-only completion"
        )
        XCTAssertEqual(
            vm.attentionState(for: piper),
            .none,
            "a clean reply-only turn must not leave the primary Bot as Needs you"
        )

        let transcript = vm.deskTranscriptForTesting(botID: piper.id)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant
                && $0.peer?.direction == .fromPeer
                && $0.text == "Estou por aqui — manda o próximo."
        }.count, 1)
        XCTAssertFalse(transcript.contains { $0.text.contains(duplicate) })
        let originRows = try context.messageRepo.listRecent(threadId: hostRequest.threadId, limit: 16)
        XCTAssertFalse(originRows.contains { $0.role == .assistant && $0.content.contains(duplicate) })
        XCTAssertFalse(
            vm.deskLiveTimeline.turns
                .flatMap(\.items)
                .contains { $0.body.contains(duplicate) || ($0.output?.contains(duplicate) == true) }
        )
    }

    func test_botMentionShowsNamedWaitingThenClearsWhenReplyArrives() async throws {
        // WHY: the originating Desk must name the teammate during the peer
        // run and clear that state only once the imported reply exists.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        let prompt = "@\(quinn.handle) check WhatsApp"
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: prompt
        )
        let outboundID = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: piper.id)
                .last(where: { $0.peer?.direction == .messaged })?.id
        )
        let waiting = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: piper.id).first { $0.id == outboundID }
        )
        XCTAssertEqual(waiting.peer?.name, "Quinn")
        XCTAssertEqual(waiting.peer?.activityPhase, .waiting)
        XCTAssertFalse(
            vm.deskShowsLoading,
            "the named peer spinner must replace the generic Loading row"
        )

        let peerStarted = await waitUntil(timeout: 5) { peerRunner.requests.count == 1 }
        XCTAssertTrue(peerStarted)
        let peerRunID = try XCTUnwrap(peerRunner.requests.first?.runId)
        XCTAssertTrue(peerRunner.finish(
            runID: peerRunID,
            status: .completed,
            reply: "PONG from Quinn"
        ))
        await milestone.value
        let receivedReply = await waitUntil(timeout: 8) {
            vm.deskTranscriptForTesting(botID: piper.id).contains {
                $0.peer?.direction == .fromPeer && $0.text == "PONG from Quinn"
            }
        }
        XCTAssertTrue(receivedReply)
        let settled = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: piper.id).first { $0.id == outboundID }
        )
        XCTAssertNil(settled.peer?.activityPhase)
        XCTAssertEqual(
            vm.deskTranscriptForTesting(botID: piper.id).filter {
                $0.peer?.direction == .fromPeer && $0.text == "PONG from Quinn"
            }.count,
            1,
            "settling the exact request must not duplicate the imported reply"
        )
    }

    func test_botMentionNeedsAttentionSurvivesReload() async throws {
        // WHY: a setup failure must replace the spinner with durable truth,
        // including after a new view model restores the same peer ledger.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        context.coordinator.replaceProvider(
            .claude,
            runner: FakeProviderRunner(provider: .claude, scenario: .error(message: "setup failed"))
        )
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) check WhatsApp"
        )
        await milestone.value
        let settled = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting().contains { $0.phase == .needsAttention }
        }
        XCTAssertTrue(settled)
        let failed = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: piper.id)
                .last(where: { $0.peer?.direction == .messaged })
        )
        XCTAssertEqual(failed.peer?.activityPhase, .needsAttention)

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(piper)
        let restored = try XCTUnwrap(
            reopened.deskTranscriptForTesting(botID: piper.id).first { $0.id == failed.id }
        )
        XCTAssertEqual(restored.peer?.name, "Quinn")
        XCTAssertEqual(restored.peer?.activityPhase, .needsAttention)
    }

    func test_legacyPeerTurnsRemainByteExactButNeverRenderIntoAnArbitraryConversation() throws {
        // WHY: v1 rows name only a Bot, not an owning conversation. Restoring
        // them into either of two threads invents ownership and mixes chats;
        // an upgrade must quarantine those bytes without rewriting them.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        let first = BotConversation(
            botID: piper.id,
            title: "First origin",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let second = BotConversation(
            botID: piper.id,
            title: "Second origin",
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        try context.botStore.upsertConversation(first)
        try context.botStore.upsertConversation(second)

        let legacyID = UUID()
        let legacyPayload: [String: Any] = [
            piper.id.value.uuidString.lowercased(): [[
                "id": legacyID.uuidString,
                "role": "user",
                "text": "@quinn legacy request with no conversation owner",
                "createdAt": 0,
                "direction": "messaged",
                "peerBotID": quinn.id.value.uuidString,
                "name": quinn.name,
                "title": quinn.title,
                "handle": quinn.handle,
                "activityPhase": "waiting",
            ]],
        ]
        let legacyBytes = try JSONSerialization.data(
            withJSONObject: legacyPayload,
            options: [.sortedKeys]
        )
        UserDefaults.standard.set(legacyBytes, forKey: "bots.peerTurns")

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(piper)
        reopened.selectDeskThread(first.id)
        XCTAssertFalse(
            reopened.deskMessages.contains { $0.id == legacyID },
            "a BotID-only v1 row cannot be attributed to the first conversation"
        )
        reopened.selectDeskThread(second.id)
        XCTAssertFalse(
            reopened.deskMessages.contains { $0.id == legacyID },
            "the same ambiguous row cannot be copied into a sibling conversation"
        )
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: "bots.peerTurns"),
            legacyBytes,
            "v2 rollout must leave the reversible v1 payload byte-for-byte unchanged"
        )
    }

    func test_malformedAndFutureV2AreQuarantinedWhileV1AndUnknownFieldsRemainByteExact() async throws {
        // WHY: rollout and downgrade must be reversible. A malformed/future v2
        // envelope cannot be rendered or rewritten, v1 remains available to an
        // older build, and an unknown additive v2 field must survive a read.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let bootstrap = BotsViewModel(context: context, router: router)
        let piper = try bootstrap.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try bootstrap.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        bootstrap.openDesk(quinn)
        bootstrap.setDeskProvider(.claude)
        bootstrap.openDesk(piper)
        bootstrap.setDeskProvider(.codex)
        bootstrap.createDeskThread()
        let origin = try XCTUnwrap(bootstrap.selectedConversation)

        let legacyMessageID = UUID()
        let legacyPayload: [String: Any] = [
            piper.id.value.uuidString.lowercased(): [[
                "id": legacyMessageID.uuidString,
                "role": "user",
                "text": "@quinn legacy downgrade row",
                "createdAt": 0,
                "direction": "messaged",
                "peerBotID": quinn.id.value.uuidString,
                "name": quinn.name,
                "title": quinn.title,
                "handle": quinn.handle,
                "activityPhase": "waiting",
            ]],
        ]
        let legacyBytes = try JSONSerialization.data(
            withJSONObject: legacyPayload,
            options: [.sortedKeys]
        )
        let malformedV2 = Data(#"{"truncated": "#.utf8)
        UserDefaults.standard.set(legacyBytes, forKey: "bots.peerTurns")
        UserDefaults.standard.set(malformedV2, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        let malformedRestore = BotsViewModel(context: context, router: router)
        malformedRestore.openDesk(piper)
        malformedRestore.selectDeskThread(origin.id)
        XCTAssertTrue(malformedRestore.peerHandoffSnapshotsForTesting().isEmpty)
        XCTAssertFalse(malformedRestore.deskMessages.contains { $0.id == legacyMessageID })
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"), malformedV2)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)

        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: malformedRestore,
            peer: quinn,
            prompt: "@\(quinn.handle) COMPAT_V2_RECORD"
        )
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("COMPAT_V2_RECORD") }
        }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(peerRunner.finish(
            promptContaining: "COMPAT_V2_RECORD",
            status: .failed,
            reply: nil
        ))
        let settled = await waitUntil(timeout: 5) {
            malformedRestore.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .needsAttention
        }
        XCTAssertTrue(settled)
        await milestone.value
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: "bots.peerTurns"),
            legacyBytes,
            "creating and settling v2 must not consume the v1 downgrade payload"
        )

        let validV2 = try XCTUnwrap(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"))
        var additiveEntries = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: validV2) as? [Any]
        )
        let recordIndex = try XCTUnwrap(additiveEntries.firstIndex { $0 is [String: Any] })
        var additiveRecord = try XCTUnwrap(additiveEntries[recordIndex] as? [String: Any])
        additiveRecord["futureAdditiveField"] = ["opaque": "preserve-for-newer-build"]
        additiveEntries[recordIndex] = additiveRecord
        let additiveBytes = try JSONSerialization.data(
            withJSONObject: additiveEntries,
            options: [.sortedKeys]
        )
        UserDefaults.standard.set(additiveBytes, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        let additiveRestore = BotsViewModel(context: context, router: router)
        XCTAssertEqual(
            additiveRestore.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase,
            .needsAttention,
            "a downgrade reader must accept an additive field it does not understand"
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"), additiveBytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)

        var futureEntries = additiveEntries
        var futureRecord = try XCTUnwrap(futureEntries[recordIndex] as? [String: Any])
        futureRecord["version"] = 3
        futureEntries[recordIndex] = futureRecord
        let futureVersionBytes = try JSONSerialization.data(
            withJSONObject: futureEntries,
            options: [.sortedKeys]
        )
        UserDefaults.standard.set(futureVersionBytes, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        let futureRestore = BotsViewModel(context: context, router: router)
        XCTAssertTrue(
            futureRestore.peerHandoffSnapshotsForTesting().isEmpty,
            "an unsupported future envelope is quarantined instead of mis-rendered"
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"), futureVersionBytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)
    }

    func test_waitingHandoffProjectsBothBotsActiveDespiteUnrelatedOriginAttention() async throws {
        // WHY: Active Bots describes live endpoints. A leftover Needs you on
        // another origin thread must not hide the waiting host from the live
        // roster or replace its Working spinner.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)

        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)
        vm.createDeskThread()
        let unrelated = try XCTUnwrap(vm.selectedConversation)
        vm.applyFollowThroughForTests(bot: piper, conversation: unrelated, status: .failed)
        vm.createDeskThread()
        let origin = try XCTUnwrap(vm.selectedConversation)

        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) DUAL_ACTIVE wait for release"
        )
        let peerBecameActive = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("DUAL_ACTIVE") }
                && vm.peerHandoffSnapshotsForTesting(
                    originConversationID: origin.id,
                    originThreadID: nil
                ).contains { $0.phase == .peerRunning }
        }
        XCTAssertTrue(peerBecameActive)

        XCTAssertEqual(
            vm.attentionState(for: piper),
            .working,
            "a live wait outranks leftover Needs you so the origin roster stays active"
        )
        XCTAssertTrue(BotsChrome.rosterShowsBusySpinner(for: vm.attentionState(for: piper)))
        XCTAssertEqual(
            Set(vm.liveWorkingBots().map(\.id)),
            Set([piper.id, quinn.id]),
            "the exact waiting origin and running peer both belong in Active Bots"
        )
        let handoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first)
        XCTAssertEqual(handoff.originConversationID, origin.id)
        XCTAssertEqual(handoff.peerBotID, quinn.id)
        XCTAssertEqual(
            handoff.peerRunID,
            peerRunner.requests.first { $0.prompt.contains("DUAL_ACTIVE") }?.runId,
            "the active projection must be backed by the exact pre-bound provider run"
        )

        router.botsViewModel = vm
        let activeRemote = try await router.dispatchPairedBotRemote(
            method: "bot.attention.list",
            params: [:]
        )
        let activeItems = try XCTUnwrap(activeRemote.objectValue?["items"]?.arrayValue)
        let delegated = try XCTUnwrap(activeItems.compactMap(\.objectValue).first {
            $0["bot_id"]?.stringValue == quinn.id.value.uuidString.lowercased()
        })
        XCTAssertEqual(delegated["id"]?.stringValue, handoff.activityID.uuidString.lowercased())
        XCTAssertEqual(delegated["conversation_id"]?.stringValue, handoff.peerConversationID.value.uuidString.lowercased())
        XCTAssertEqual(delegated["thread_id"]?.stringValue, handoff.peerThreadID?.value.uuidString.lowercased())
        XCTAssertEqual(delegated["run_id"]?.stringValue, handoff.peerRunID?.value.uuidString.lowercased())
        XCTAssertEqual(delegated["owner_bot_id"]?.stringValue, piper.id.value.uuidString.lowercased())
        XCTAssertEqual(delegated["owner_conversation_id"]?.stringValue, origin.id.value.uuidString.lowercased())
        XCTAssertEqual(delegated["ownership"]?.stringValue, "delegated")
        XCTAssertEqual(delegated["primary"]?.boolValue, false)
        XCTAssertEqual(delegated["delegated"]?.boolValue, true)
        XCTAssertEqual(
            activeItems.compactMap(\.objectValue).filter {
                $0["bot_id"]?.stringValue == quinn.id.value.uuidString.lowercased()
            }.count,
            1,
            "one delegated handoff must produce one attention owner"
        )

        XCTAssertTrue(peerRunner.finish(promptContaining: "DUAL_ACTIVE", reply: "released"))
        let handoffCompleted = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).contains { $0.phase == .completed }
        }
        XCTAssertTrue(handoffCompleted)
        let finishedRemote = try await router.dispatchPairedBotRemote(
            method: "bot.attention.list",
            params: [:]
        )
        let finishedItems = try XCTUnwrap(finishedRemote.objectValue?["items"]?.arrayValue)
        let finishedPeer = try XCTUnwrap(finishedItems.compactMap(\.objectValue).first {
            $0["bot_id"]?.stringValue == quinn.id.value.uuidString.lowercased()
        })
        XCTAssertEqual(finishedPeer["id"]?.stringValue, handoff.activityID.uuidString.lowercased())
        XCTAssertEqual(finishedPeer["state"]?.stringValue, "finished")
        XCTAssertEqual(finishedPeer["ownership"]?.stringValue, "delegated")
        await milestone.value
    }

    func test_samePeerOutOfOrderRepliesStayInTheirCapturedOriginConversations() async throws {
        // WHY: two Piper threads may ask the same Quinn concurrently. Finishing
        // them out of order while thread B is selected must not let Bot-global
        // "latest conversation/assistant" state choose either reply endpoint.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        vm.createDeskThread()
        let originA = try XCTUnwrap(vm.selectedConversation)
        let milestoneA = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) SAME_PEER_A"
        )
        let firstPeerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("SAME_PEER_A") }
        }
        XCTAssertTrue(firstPeerStarted)

        vm.createDeskThread()
        let originB = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(originA.id, originB.id)
        let milestoneB = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) SAME_PEER_B"
        )
        let secondPeerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("SAME_PEER_B") }
        }
        XCTAssertTrue(secondPeerStarted)

        XCTAssertTrue(peerRunner.finish(promptContaining: "SAME_PEER_B", reply: "REPLY_B"))
        let secondReplyArrived = await waitUntil(timeout: 5) {
            vm.deskMessages.contains {
                $0.peer?.direction == .fromPeer && $0.text == "REPLY_B"
            }
        }
        XCTAssertTrue(secondReplyArrived)
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "REPLY_A" })

        // Keep B selected while A terminates. Settlement must still use A's
        // immutable conversation/run/checkpoint tuple.
        XCTAssertEqual(vm.selectedConversation?.id, originB.id)
        XCTAssertTrue(peerRunner.finish(promptContaining: "SAME_PEER_A", reply: "REPLY_A"))
        let firstHandoffCompleted = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: originA.id,
                originThreadID: nil
            ).contains { $0.phase == .completed }
        }
        XCTAssertTrue(firstHandoffCompleted)
        XCTAssertEqual(vm.selectedConversation?.id, originB.id)
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "REPLY_A" })

        vm.selectDeskThread(originA.id)
        XCTAssertTrue(vm.deskMessages.contains {
            $0.peer?.direction == .fromPeer && $0.text == "REPLY_A"
        })
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "REPLY_B" })
        vm.selectDeskThread(originB.id)
        XCTAssertTrue(vm.deskMessages.contains {
            $0.peer?.direction == .fromPeer && $0.text == "REPLY_B"
        })
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "REPLY_A" })

        let handoffA = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: originA.id,
            originThreadID: nil
        ).first)
        let handoffB = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: originB.id,
            originThreadID: nil
        ).first)
        XCTAssertNotEqual(handoffA.peerConversationID, handoffB.peerConversationID)
        XCTAssertNotEqual(handoffA.peerThreadID, handoffB.peerThreadID)
        XCTAssertNotEqual(handoffA.peerRunID, handoffB.peerRunID)
        XCTAssertEqual(
            handoffA.peerRunID,
            peerRunner.requests.first { $0.prompt.contains("SAME_PEER_A") }?.runId
        )
        XCTAssertEqual(
            handoffB.peerRunID,
            peerRunner.requests.first { $0.prompt.contains("SAME_PEER_B") }?.runId
        )
        await milestoneA.value
        await milestoneB.value
    }

    func test_initiatingWindowDeallocatesWhileAuthorityFinishesItsExactPlanAndPreservesSibling() async throws {
        // WHY: a Bot handoff is durable work owned by the shared context, not
        // by the window that happened to submit it. Closing VM A while two
        // peers are pending must release that VM immediately; VM B may receive
        // unrelated selection/coordinator events without stealing either plan.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let quinnRunner = ControlledBotHandoffRunner(provider: .codex)
        let roryRunner = ControlledBotHandoffRunner(provider: .codex)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)

        var initiatingVM: BotsViewModel? = BotsViewModel(context: context, router: router)
        router.botsViewModel = initiatingVM
        let piper = try XCTUnwrap(initiatingVM).create(
            name: "Piper",
            title: "Seller",
            provider: .codex
        )
        let quinn = try XCTUnwrap(initiatingVM).create(
            name: "Quinn",
            title: "CRM Controller",
            provider: .claude
        )
        let rory = try XCTUnwrap(initiatingVM).create(
            name: "Rory",
            title: "Research Controller",
            provider: .grok
        )
        context.coordinator.replaceProvider(
            .codex,
            runner: CallerThreadHandoffRunner(
                hostRunner: hostRunner,
                peerRunners: [quinn.id: quinnRunner, rory.id: roryRunner]
            )
        )
        initiatingVM?.openDesk(quinn)
        initiatingVM?.setDeskProvider(.claude)
        initiatingVM?.openDesk(rory)
        initiatingVM?.setDeskProvider(.grok)
        initiatingVM?.openDesk(piper)
        initiatingVM?.setDeskProvider(.codex)

        initiatingVM?.createDeskThread()
        let mainOrigin = try XCTUnwrap(initiatingVM?.selectedConversation)
        let mainMilestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: try XCTUnwrap(initiatingVM),
            peer: quinn,
            prompt: "@\(quinn.handle) WINDOW_OWNER_MAIN"
        )
        let mainStarted = await waitUntil(timeout: 5) {
            quinnRunner.requests.contains { $0.prompt.contains("WINDOW_OWNER_MAIN") }
        }
        XCTAssertTrue(mainStarted)

        initiatingVM?.createDeskThread()
        let siblingOrigin = try XCTUnwrap(initiatingVM?.selectedConversation)
        let siblingMilestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: try XCTUnwrap(initiatingVM),
            peer: rory,
            prompt: "@\(rory.handle) WINDOW_OWNER_SIBLING"
        )
        let siblingStarted = await waitUntil(timeout: 5) {
            roryRunner.requests.contains { $0.prompt.contains("WINDOW_OWNER_SIBLING") }
        }
        XCTAssertTrue(siblingStarted)

        let mainHandoff = try XCTUnwrap(initiatingVM?.peerHandoffSnapshotsForTesting(
            originConversationID: mainOrigin.id,
            originThreadID: nil
        ).first)
        let siblingHandoff = try XCTUnwrap(initiatingVM?.peerHandoffSnapshotsForTesting(
            originConversationID: siblingOrigin.id,
            originThreadID: nil
        ).first)
        let mainPeerRunID = try XCTUnwrap(mainHandoff.peerRunID)
        let siblingPeerRunID = try XCTUnwrap(siblingHandoff.peerRunID)
        XCTAssertNil(mainHandoff.hostRunID)
        XCTAssertNil(siblingHandoff.hostRunID)

        let observingVM = BotsViewModel(context: context, router: router)
        router.botsViewModel = observingVM
        observingVM.openDesk(rory)
        observingVM.openActiveBots()
        weak var releasedInitiator = initiatingVM
        initiatingVM = nil

        let initiatorDeallocated = await waitUntil(timeout: 1) {
            releasedInitiator == nil
        }
        if !initiatorDeallocated {
            _ = quinnRunner.finish(runID: mainPeerRunID, status: .cancelled, reply: nil)
            _ = roryRunner.finish(runID: siblingPeerRunID, status: .cancelled, reply: nil)
            _ = await waitUntil(timeout: 2) { releasedInitiator == nil }
            XCTFail(
                "VM A must deallocate while both exact peer runs remain pending; lifecycle continuation belongs to context authority"
            )
            return
        }

        XCTAssertEqual(try context.runRepo.get(id: mainPeerRunID)?.status, .running)
        XCTAssertEqual(try context.runRepo.get(id: siblingPeerRunID)?.status, .running)
        XCTAssertTrue(quinnRunner.finish(
            runID: mainPeerRunID,
            status: .completed,
            reply: "authority-owned peer reply"
        ))

        let mainCompletedInNonOwner = await waitUntil(timeout: 5) {
            observingVM.peerHandoffSnapshotsForTesting(
                originConversationID: mainOrigin.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(
            mainCompletedInNonOwner,
            "VM B must receive the exact authority delta without becoming execution owner"
        )
        let preservedSibling = try XCTUnwrap(observingVM.peerHandoffSnapshotsForTesting(
            originConversationID: siblingOrigin.id,
            originThreadID: nil
        ).first)
        XCTAssertEqual(preservedSibling.activityID, siblingHandoff.activityID)
        XCTAssertEqual(preservedSibling.peerRunID, siblingPeerRunID)
        XCTAssertEqual(preservedSibling.phase, .peerRunning)
        XCTAssertTrue(hostRunner.requests.isEmpty)

        XCTAssertTrue(roryRunner.finish(
            runID: siblingPeerRunID,
            status: .cancelled,
            reply: nil
        ))
        let siblingSettled = await waitUntil(timeout: 5) {
            observingVM.peerHandoffSnapshotsForTesting(
                originConversationID: siblingOrigin.id,
                originThreadID: nil
            ).first?.phase == .needsAttention
        }
        XCTAssertTrue(siblingSettled)
        await mainMilestone.value
        await siblingMilestone.value
    }

    func test_authorityDeltaUpdatesTwoLiveWindowsWithoutReplacingLocalUIState() async throws {
        // WHY: peer handoff progress belongs to the shared context authority.
        // Its deltas must reach every live Bots window without using a whole-VM
        // reload that steals either window's selection or unsent local work.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            let model = BotsViewModel.defaultModel(for: provider)
            return AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: model, label: model, provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })

        let originWindow = BotsViewModel(context: context, router: router)
        let piper = try originWindow.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try originWindow.create(
            name: "Quinn",
            title: "CRM Controller",
            provider: .claude
        )
        let rory = try originWindow.create(
            name: "Rory",
            title: "Research Controller",
            provider: .grok
        )
        context.coordinator.replaceProvider(
            .codex,
            runner: CallerThreadHandoffRunner(
                hostRunner: hostRunner,
                peerRunners: [quinn.id: peerRunner]
            )
        )
        originWindow.openDesk(quinn)
        originWindow.setDeskProvider(.claude)
        originWindow.openDesk(piper)
        originWindow.setDeskProvider(.codex)
        originWindow.createDeskThread()
        let originConversation = try XCTUnwrap(originWindow.selectedConversation)

        let siblingWindow = BotsViewModel(context: context, router: router)
        siblingWindow.openStudio(rory)
        router.botsViewModel = originWindow

        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: originWindow,
            peer: quinn,
            prompt: "@\(quinn.handle) TWO_LIVE_WINDOWS"
        )
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("TWO_LIVE_WINDOWS") }
        }
        XCTAssertTrue(peerStarted)
        let running = try XCTUnwrap(originWindow.peerHandoffSnapshotsForTesting(
            originConversationID: originConversation.id,
            originThreadID: nil
        ).first)
        let peerRunID = try XCTUnwrap(running.peerRunID)
        XCTAssertNil(running.hostRunID)
        XCTAssertEqual(
            siblingWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first,
            running,
            "both windows must observe the same exact authority row"
        )

        let originAttachmentPath = (directory as NSString).appendingPathComponent("origin-window.txt")
        let siblingAttachmentPath = (directory as NSString).appendingPathComponent("sibling-window.txt")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: originAttachmentPath,
            contents: Data("origin".utf8)
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: siblingAttachmentPath,
            contents: Data("sibling".utf8)
        ))

        originWindow.openDesk(piper)
        originWindow.selectDeskThread(originConversation.id)
        originWindow.composerText = "ORIGIN_WINDOW_COMPOSER"
        originWindow.attachments = [AgentAttachment(
            path: originAttachmentPath,
            displayName: "origin-window.txt",
            kind: .file
        )]
        originWindow.memoryDraft = "ORIGIN_MEMORY_DRAFT"
        originWindow.skillDraft = "origin-skill-draft"
        originWindow.routineName = "Origin routine"
        originWindow.routinePrompt = "Origin routine prompt"
        originWindow.routineScheduleNote = "Origin routine schedule"

        siblingWindow.openStudio(rory)
        siblingWindow.composerText = "SIBLING_WINDOW_COMPOSER"
        siblingWindow.attachments = [AgentAttachment(
            path: siblingAttachmentPath,
            displayName: "sibling-window.txt",
            kind: .file
        )]
        siblingWindow.memoryDraft = "SIBLING_MEMORY_DRAFT"
        siblingWindow.skillDraft = "sibling-skill-draft"
        siblingWindow.routineName = "Sibling routine"
        siblingWindow.routinePrompt = "Sibling routine prompt"
        siblingWindow.routineScheduleNote = "Sibling routine schedule"

        let originReloadCounts = fullReloadCounts(originWindow)
        let siblingReloadCounts = fullReloadCounts(siblingWindow)
        let originDeskRestoreCount = originWindow.deskRestoreInvokedCountForTesting
        let siblingDeskRestoreCount = siblingWindow.deskRestoreInvokedCountForTesting
        let originSelection = originWindow.selectedBotID
        let siblingSelection = siblingWindow.selectedBotID
        let originScreen = originWindow.screen
        let siblingScreen = siblingWindow.screen
        let originAttachments = originWindow.attachments
        let siblingAttachments = siblingWindow.attachments

        XCTAssertTrue(peerRunner.finish(
            runID: peerRunID,
            status: .completed,
            reply: "TWO_WINDOW_EXACT_REPLY"
        ))
        let bothCompleted = await waitUntil(timeout: 5) {
            originWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first?.phase == .completed
                && siblingWindow.peerHandoffSnapshotsForTesting(
                    originConversationID: originConversation.id,
                    originThreadID: nil
                ).first?.phase == .completed
        }
        XCTAssertTrue(bothCompleted)
        let completedSnapshot = try XCTUnwrap(originWindow.peerHandoffSnapshotsForTesting(
            originConversationID: originConversation.id,
            originThreadID: nil
        ).first)
        XCTAssertEqual(
            siblingWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first,
            completedSnapshot
        )
        XCTAssertEqual(completedSnapshot.activityID, running.activityID)
        XCTAssertEqual(completedSnapshot.peerRunID, peerRunID)
        XCTAssertNil(completedSnapshot.hostRunID)
        XCTAssertTrue(hostRunner.requests.isEmpty)
        XCTAssertEqual(
            originWindow.deskMessages.filter {
                $0.peer?.direction == .fromPeer && $0.text == "TWO_WINDOW_EXACT_REPLY"
            }.count,
            1,
            "the selected origin window must paint one stable reply row"
        )
        XCTAssertEqual(
            try context.botStore.conversation(id: completedSnapshot.peerConversationID)?.attentionState,
            .unreadActivity,
            "the peer conversation attention must settle with the direct reply"
        )
        XCTAssertEqual(
            siblingWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first,
            originWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first
        )
        XCTAssertEqual(
            try context.botStore.conversation(id: originConversation.id)?.attentionState,
            BotAttentionState.none,
            "the open origin conversation must not gain stale unread attention after the direct reply"
        )

        XCTAssertEqual(originWindow.selectedBotID, originSelection)
        XCTAssertEqual(siblingWindow.selectedBotID, siblingSelection)
        XCTAssertEqual(originWindow.screen, originScreen)
        XCTAssertEqual(siblingWindow.screen, siblingScreen)
        XCTAssertEqual(originWindow.composerText, "ORIGIN_WINDOW_COMPOSER")
        XCTAssertEqual(siblingWindow.composerText, "SIBLING_WINDOW_COMPOSER")
        XCTAssertEqual(originWindow.attachments, originAttachments)
        XCTAssertEqual(siblingWindow.attachments, siblingAttachments)
        XCTAssertEqual(originWindow.memoryDraft, "ORIGIN_MEMORY_DRAFT")
        XCTAssertEqual(siblingWindow.memoryDraft, "SIBLING_MEMORY_DRAFT")
        XCTAssertEqual(originWindow.skillDraft, "origin-skill-draft")
        XCTAssertEqual(siblingWindow.skillDraft, "sibling-skill-draft")
        XCTAssertEqual(originWindow.routineName, "Origin routine")
        XCTAssertEqual(siblingWindow.routineName, "Sibling routine")
        XCTAssertEqual(originWindow.routinePrompt, "Origin routine prompt")
        XCTAssertEqual(siblingWindow.routinePrompt, "Sibling routine prompt")
        XCTAssertEqual(originWindow.routineScheduleNote, "Origin routine schedule")
        XCTAssertEqual(siblingWindow.routineScheduleNote, "Sibling routine schedule")
        XCTAssertEqual(fullReloadCounts(originWindow), originReloadCounts)
        XCTAssertEqual(fullReloadCounts(siblingWindow), siblingReloadCounts)
        XCTAssertGreaterThan(
            originWindow.deskRestoreInvokedCountForTesting,
            originDeskRestoreCount,
            "exact terminal events may refresh the owning Desk projection without reloading the VM"
        )
        XCTAssertGreaterThan(
            siblingWindow.deskRestoreInvokedCountForTesting,
            siblingDeskRestoreCount,
            "the second window may refresh its targeted Desk cache without losing local UI state"
        )
        await milestone.value
    }

    func test_peerHandoffMutationWithOneThousandRowsRetainsNineHundredNinetyNineUnderFiftyMillisecondP95() throws {
        // WHY: every authority mutation re-encodes and atomically commits the
        // complete v2 envelope. A large retained history must not turn one
        // background handoff delta into a visible main-thread stall.
        let settingsKey = "bots.peerTurns.v2"
        let targetOriginBotID = BotID()
        let (payload, targetActivityID, siblingActivityID) = try peerHandoffPerformancePayload(
            rowCount: 1_000,
            targetOriginBotID: targetOriginBotID
        )
        defer { UserDefaults.standard.removeObject(forKey: settingsKey) }

        // Inside a long suite the first commits still share the CPU with work the
        // previous test left draining; warm up past that so samples measure the commit.
        for warmup in 0..<3 {
            _ = try measurePeerHandoffDeletion(
                label: "warmup-\(warmup)",
                payload: payload,
                targetOriginBotID: targetOriginBotID,
                targetActivityID: targetActivityID,
                siblingActivityID: siblingActivityID
            )
        }

        var samples: [Double] = []
        for sample in 0..<20 {
            samples.append(try measurePeerHandoffDeletion(
                label: "sample-\(sample)",
                payload: payload,
                targetOriginBotID: targetOriginBotID,
                targetActivityID: targetActivityID,
                siblingActivityID: siblingActivityID
            ))
        }

        let p95 = percentile(samples, fraction: 0.95)
        let rawSamples = samples.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let evidence = "samples_ms=[\(rawSamples)] p95_ms=\(String(format: "%.3f", p95))"
        XCTAssertLessThan(p95, 50, evidence)
    }

    func test_exactCheckpointAssistantBeatsNewerAmbientAssistantInsertedBeforeTerminalFanout() async throws {
        // WHY: a thread-global "latest assistant" can belong to unrelated work.
        // Insert that adversary after the exact minimal checkpoint write but
        // before didFinish; only the checkpoint-owned assistant may cross Bots.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let viewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = viewModel
        let piper = try viewModel.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try viewModel.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        context.coordinator.replaceProvider(
            .codex,
            runner: CallerThreadHandoffRunner(
                hostRunner: hostRunner,
                peerRunners: [quinn.id: peerRunner]
            )
        )
        viewModel.openDesk(quinn)
        viewModel.setDeskProvider(.claude)
        viewModel.openDesk(piper)
        viewModel.setDeskProvider(.codex)
        viewModel.createDeskThread()
        let origin = try XCTUnwrap(viewModel.selectedConversation)

        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: viewModel,
            peer: quinn,
            prompt: "@\(quinn.handle) T005_EXACT_ORACLE"
        )
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_EXACT_ORACLE") }
        }
        XCTAssertTrue(peerStarted)
        let pending = try XCTUnwrap(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first)
        let peerRunID = try XCTUnwrap(pending.peerRunID)
        let peerThreadID = try XCTUnwrap(pending.peerThreadID)
        let ambientMessageID = AgentMessageID()
        try context.db.execute("""
            CREATE TRIGGER insert_t005_newer_ambient_assistant
            AFTER INSERT ON agent_turn_checkpoints
            WHEN NEW.run_id = '\(peerRunID.value.uuidString)'
            BEGIN
                INSERT INTO agent_messages(
                    id, thread_id, role, content, created_at, attachments_json,
                    body_sha256, body_bytes, body_revision
                ) VALUES(
                    '\(ambientMessageID.value.uuidString)',
                    '\(peerThreadID.value.uuidString)',
                    'assistant',
                    'NEWER_AMBIENT_MUST_LOSE',
                    '9999-12-31T23:59:59Z',
                    '[]',
                    't005-ambient',
                    23,
                    1
                );
            END;
        """)
        defer { try? context.db.execute("DROP TRIGGER insert_t005_newer_ambient_assistant;") }

        XCTAssertTrue(peerRunner.finish(
            runID: peerRunID,
            status: .completed,
            reply: "EXACT_CHECKPOINT_REPLY"
        ))
        let completed = await waitUntil(timeout: 5) {
            viewModel.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(completed)
        let checkpoint = try XCTUnwrap(
            context.turnCheckpointRepo.list(threadId: peerThreadID)
                .first { $0.runId == peerRunID }
        )
        let checkpointMessageID = try XCTUnwrap(checkpoint.assistantMessageId)
        XCTAssertNotEqual(checkpointMessageID, ambientMessageID)
        XCTAssertEqual(
            try context.messageRepo.get(id: checkpointMessageID)?.content,
            "EXACT_CHECKPOINT_REPLY"
        )
        XCTAssertEqual(
            try context.messageRepo.list(threadId: peerThreadID).last?.id,
            ambientMessageID,
            "precondition: the unrelated assistant is observably newer on the same thread"
        )
        XCTAssertTrue(viewModel.deskMessages.contains {
            $0.peer?.direction == .fromPeer && $0.text == "EXACT_CHECKPOINT_REPLY"
        })
        XCTAssertFalse(viewModel.deskMessages.contains { $0.text == "NEWER_AMBIENT_MUST_LOSE" })
        XCTAssertNil(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first?.hostRunID)
        XCTAssertTrue(hostRunner.requests.isEmpty)
        await milestone.value
    }

    func test_peerFailureAndCancellationSettleOnlyTheirExactOwningHandoffs() async throws {
        // WHY: two concurrent requests can share the same peer provider. A
        // failure or cancellation is scoped by the durable run ID, not by the
        // currently selected Bot, so neither terminal may settle its sibling.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        vm.createDeskThread()
        let failureOrigin = try XCTUnwrap(vm.selectedConversation)
        let failureMilestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) FAIL_ONLY_OWNER"
        )
        let failureStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("FAIL_ONLY_OWNER") }
        }
        XCTAssertTrue(failureStarted)

        vm.createDeskThread()
        let cancellationOrigin = try XCTUnwrap(vm.selectedConversation)
        let cancellationMilestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) CANCEL_ONLY_OWNER"
        )
        let cancellationStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("CANCEL_ONLY_OWNER") }
        }
        XCTAssertTrue(cancellationStarted)

        let failureHandoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: failureOrigin.id,
            originThreadID: nil
        ).first)
        let cancellationHandoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: cancellationOrigin.id,
            originThreadID: nil
        ).first)
        let failureRunID = try XCTUnwrap(failureHandoff.peerRunID)
        let cancellationRunID = try XCTUnwrap(cancellationHandoff.peerRunID)
        XCTAssertNotEqual(failureRunID, cancellationRunID)

        XCTAssertTrue(peerRunner.finish(runID: failureRunID, status: .failed, reply: nil))
        let failureSettled = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: failureOrigin.id,
                originThreadID: nil
            ).first?.phase == .needsAttention
        }
        XCTAssertTrue(failureSettled)
        XCTAssertEqual(try context.runRepo.get(id: failureRunID)?.status, .failed)
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: cancellationOrigin.id,
                originThreadID: nil
            ).first?.phase,
            .peerRunning,
            "failure of the first exact run must leave its sibling armed and running"
        )
        XCTAssertEqual(try context.runRepo.get(id: cancellationRunID)?.status, .running)

        XCTAssertTrue(peerRunner.finish(runID: cancellationRunID, status: .cancelled, reply: nil))
        let cancellationSettled = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: cancellationOrigin.id,
                originThreadID: nil
            ).first?.phase == .needsAttention
        }
        XCTAssertTrue(cancellationSettled)
        XCTAssertEqual(try context.runRepo.get(id: cancellationRunID)?.status, .cancelled)
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: failureOrigin.id,
                originThreadID: nil
            ).first?.phase,
            .needsAttention,
            "cancellation of the sibling exact run must not rewrite the first terminal"
        )

        for origin in [failureOrigin, cancellationOrigin] {
            vm.selectDeskThread(origin.id)
            XCTAssertFalse(
                vm.deskMessages.contains { $0.peer?.direction == .fromPeer },
                "failed/cancelled peers have no stable reply to leak into either origin"
            )
        }
        await failureMilestone.value
        await cancellationMilestone.value
    }

    func test_handoffOlderThanSixtyFiveLogicalSecondsStillSettlesFromExactTerminalsWithoutWallTimeout() async throws {
        // WHY: the former 120 x 500 ms polling loop fabricated a one-minute
        // boundary. Durable run age is not failure evidence; the directly
        // addressed peer must remain owned until its exact terminal arrives.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        context.coordinator.replaceProvider(
            .codex,
            runner: CallerThreadHandoffRunner(
                hostRunner: hostRunner,
                peerRunners: [quinn.id: peerRunner]
            )
        )
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)
        vm.createDeskThread()
        let origin = try XCTUnwrap(vm.selectedConversation)

        let wallStart = Date()
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) LOGICAL_65_SECONDS"
        )
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("LOGICAL_65_SECONDS") }
        }
        XCTAssertTrue(peerStarted)
        let peerRunID = try XCTUnwrap(
            peerRunner.requests.first { $0.prompt.contains("LOGICAL_65_SECONDS") }?.runId
        )
        let peerRunning = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .peerRunning
        }
        XCTAssertTrue(peerRunning, "the peer start must persist .peerRunning before logical age is applied")
        var peerRun = try XCTUnwrap(try context.runRepo.get(id: peerRunID))
        let peerLogicalNow = Date()
        peerRun.startedAt = peerLogicalNow.addingTimeInterval(-66)
        try context.runRepo.upsert(peerRun)
        XCTAssertGreaterThan(peerLogicalNow.timeIntervalSince(peerRun.startedAt), 65)
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase,
            .peerRunning,
            "logical age alone must not settle the peer leg"
        )

        XCTAssertTrue(peerRunner.finish(runID: peerRunID, status: .completed, reply: "reply after 65s"))
        let settled = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(settled)
        let handoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first)
        XCTAssertNil(handoff.hostRunID)
        XCTAssertTrue(hostRunner.requests.isEmpty)
        XCTAssertLessThan(
            Date().timeIntervalSince(wallStart),
            10,
            "the >65-second proof advances durable logical time and must never wall-sleep for the old timeout"
        )
        XCTAssertEqual(
            vm.deskTranscriptForTesting(botID: piper.id).filter {
                $0.peer?.direction == .fromPeer && $0.text == "reply after 65s"
            }.count,
            1
        )
        await milestone.value
    }

    func test_setPhaseRetriesOneTransientConflictFromCanonicalStateWithoutAlert() async throws {
        // WHY: another writer or the mirror can win one persistence attempt.
        // Retrying the phase intent from the freshly adopted canonical map
        // heals that bounded race without exposing a false save alert.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.setDeskModel("fake-model")
        let originThread = AgentThread(
            title: "Transient conflict origin",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        try context.threadRepo.upsert(originThread)

        var persistCount = 0
        context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
            persistCount += 1
            if persistCount == 2 {
                throw NSError(domain: "setPhaseTransientConflict", code: 1)
            }
            UserDefaults.standard.set(data, forKey: "bots.peerTurns.v2")
            guard UserDefaults.standard.synchronize(),
                  UserDefaults.standard.data(forKey: "bots.peerTurns.v2") == data else {
                throw NSError(domain: "setPhaseTransientConflict", code: 2)
            }
        }

        let milestone = try XCTUnwrap(
            context.botPeerHandoffAuthority.submitAgentAppMention(
                peer: quinn,
                text: "SETPHASE_TRANSIENT_RETRY",
                peerText: "SETPHASE_TRANSIENT_RETRY",
                originThread: originThread,
                activityID: AgentMessageID(),
                hostRunID: nil,
                providerSnapshots: [],
                resumeHostAfterPeer: false
            )
        )
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("SETPHASE_TRANSIENT_RETRY") }
        }
        XCTAssertTrue(peerStarted)
        let phaseAdvanced = await waitUntil(timeout: 5) {
            persistCount >= 3
                && vm.peerHandoffSnapshotsForTesting(
                    originConversationID: nil,
                    originThreadID: originThread.id
                ).first?.phase == .peerRunning
        }
        XCTAssertTrue(phaseAdvanced)
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: originThread.id
            ).first?.phase,
            .peerRunning
        )
        XCTAssertNil(vm.errorMessage, vm.errorMessage ?? "")

        context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = nil
        if let peerRunID = peerRunner.requests.first?.runId {
            _ = peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil)
        }
        await milestone.value
    }

    func test_setPhasePersistentConflictPublishesCanonicalSnapshotAndSaveAlert() async throws {
        // WHY: the bounded retry must not install an unpersisted phase or hide
        // a storage failure that remains after retrying from canonical state.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.setDeskModel("fake-model")
        let originThread = AgentThread(
            title: "Persistent conflict origin",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        try context.threadRepo.upsert(originThread)

        var persistCount = 0
        context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
            persistCount += 1
            if persistCount > 1 {
                throw NSError(domain: "setPhasePersistentConflict", code: 1)
            }
            UserDefaults.standard.set(data, forKey: "bots.peerTurns.v2")
            guard UserDefaults.standard.synchronize(),
                  UserDefaults.standard.data(forKey: "bots.peerTurns.v2") == data else {
                throw NSError(domain: "setPhasePersistentConflict", code: 2)
            }
        }

        let milestone = try XCTUnwrap(
            context.botPeerHandoffAuthority.submitAgentAppMention(
                peer: quinn,
                text: "SETPHASE_PERSISTENT_FAILURE",
                peerText: "SETPHASE_PERSISTENT_FAILURE",
                originThread: originThread,
                activityID: AgentMessageID(),
                hostRunID: nil,
                providerSnapshots: [],
                resumeHostAfterPeer: false
            )
        )
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("SETPHASE_PERSISTENT_FAILURE") }
        }
        XCTAssertTrue(peerStarted)
        let failurePublished = await waitUntil(timeout: 5) {
            persistCount >= 3
                && vm.errorMessage == "The bot handoff state could not be saved."
        }
        XCTAssertTrue(failurePublished, "setPhase must attempt once plus one bounded retry")
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: originThread.id
            ).first?.phase,
            .peerPrepared,
            "persistent failure must retain canonical state, not the failed candidate"
        )
        XCTAssertEqual(vm.errorMessage, "The bot handoff state could not be saved.")

        context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = nil
        if let peerRunID = peerRunner.requests.first?.runId {
            _ = peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil)
        }
        await milestone.value
    }

    func test_relaunchMissingPreparedPeerRunFinalizesExactAcceptedBotDelegationReceipt() throws {
        // WHY: the receipt id map is process-local. After a crash, a restored
        // peerPrepared row with no run is known to have failed before provider
        // start, so its exact Bot telemetry row must stop claiming Working.
        // Existing v2 rows predate service-tier routing, while canonical rows
        // may omit default route values. Both forms must decode without making
        // the whole handoff opaque.
        let context = try makeContext()
        let originThread = AgentThread(
            title: "Restored Bot host",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        let peerThread = AgentThread(
            title: "Restored Bot peer",
            provider: .claude,
            model: "fake-model",
            status: .completed
        )
        try context.threadRepo.upsert(originThread)
        try context.threadRepo.upsert(peerThread)
        let activityID = UUID()
        let peerRunID = AgentRunID()
        let hostRunID = AgentRunID()
        let route = T005PeerHandoffRouteFixture(
            provider: .claude,
            providerInstanceID: nil,
            model: "fake-model",
            permissionMode: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            runAsUser: AgentRunAsUser(
                generatedUID: "restored-bot-fixture",
                shortName: "fixture",
                uid: 0,
                gid: 0,
                homePath: "/tmp/restored-bot-fixture"
            ),
            routingConfiguration: nil
        )
        let payload = try JSONEncoder().encode([
            activityID: T005PeerHandoffRecordFixture(
                version: 2,
                activityID: activityID,
                originBotID: nil,
                originConversationID: nil,
                originAgentThreadID: originThread.id,
                peerBotID: BotID(),
                peerConversationID: BotConversationID(),
                peerThreadID: peerThread.id,
                peerRunID: peerRunID,
                inboundMessageID: activityID,
                peerName: "Restored Quinn",
                peerTitle: "CRM Controller",
                peerHandle: "restored-quinn",
                outboundText: "RESTORED_PRESTART_FAILURE",
                createdAt: Date(),
                peerRoute: route,
                hostThreadID: originThread.id,
                hostRunID: hostRunID,
                hostRoute: route,
                replyText: nil,
                replyCreatedAt: nil,
                phase: .peerPrepared
            ),
        ])
        let compactRoutePayload = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(compactRoutePayload.contains("\"serviceTier\""))
        XCTAssertFalse(compactRoutePayload.contains("\"providerInstanceID\""))
        XCTAssertFalse(compactRoutePayload.contains("\"permissionMode\""))
        XCTAssertFalse(compactRoutePayload.contains("\"reasoningEffort\""))
        UserDefaults.standard.set(payload, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())
        try context.settingsRepo.set(
            "bots.peerTurns.v2",
            "base64:\(payload.base64EncodedString())"
        )
        let receipt = try context.orchestrationRuntime.recordBotDelegationTelemetry(
            runId: peerRunID,
            hostThreadId: originThread.id,
            nodeId: "bot.restored-quinn.\(peerRunID.value.uuidString)",
            provider: .claude,
            providerInstanceId: "claude",
            model: "fake-model",
            reasoningEffort: .medium,
            permissionMode: .supervised
        )
        XCTAssertEqual(receipt.lifecycleStatus, .accepted)
        XCTAssertNil(try context.runRepo.get(id: peerRunID))

        let reopened = BotsViewModel(context: context)
        reopened.reconcilePeerHandoffsForTesting()
        XCTAssertEqual(
            reopened.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: originThread.id
            ).first?.phase,
            .needsAttention
        )
        let reconciledReceipt = try XCTUnwrap(
            context.orchestrationRuntime.recentReceipts(limit: 64).first {
                $0.id == receipt.id
                    && $0.runId == peerRunID
                    && $0.decisionReason == AgentOrchestrationRuntime.botDelegationDecisionReason
            }
        )
        XCTAssertEqual(reconciledReceipt.lifecycleStatus, .finalized)
        XCTAssertEqual(reconciledReceipt.finalRunStatus, .failed)
        XCTAssertFalse(
            try context.orchestrationRuntime.activityReceipts(
                threadIds: [originThread.id],
                limit: 16
            ).contains {
                $0.id == receipt.id && $0.lifecycleStatus == .accepted
            },
            "the exact restored Bot receipt must no longer project as active"
        )
    }

    func test_routeMutationAfterDurablePrebindCannotRerouteMentionedPeer() async throws {
        // WHY: the user can change the visible Desk route while a teammate is
        // starting. The addressed peer must keep its admission snapshot, and
        // no ambient or host provider may start a duplicate answer.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let claude = ControlledBotHandoffRunner(provider: .claude)
        let codex = ControlledBotHandoffRunner(provider: .codex)
        let grok = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.claude, runner: claude)
        context.coordinator.replaceProvider(.codex, runner: codex)
        context.coordinator.replaceProvider(.grok, runner: grok)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)
        vm.createDeskThread()
        let origin = try XCTUnwrap(vm.selectedConversation)

        var dispatches = 0
        vm.beforeBotRunDispatchForTesting = { _ in
            dispatches += 1
            vm.setDeskProvider(.grok)
        }
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) ROUTE_FREEZE"
        )
        let peerStarted = await waitUntil(timeout: 5) {
            codex.requests.contains { $0.prompt.contains("ROUTE_FREEZE") }
        }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(claude.requests.isEmpty)
        XCTAssertTrue(grok.requests.isEmpty)
        XCTAssertTrue(codex.finish(promptContaining: "ROUTE_FREEZE", reply: "frozen reply"))
        let completed = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(completed)

        let handoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first)
        XCTAssertEqual(handoff.peerProvider, .codex)
        XCTAssertNil(handoff.hostProvider)
        XCTAssertEqual(handoff.peerRunID, codex.requests.first?.runId)
        XCTAssertNil(handoff.hostRunID)
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(codex.requests.count, 1, "the caller provider must execute only the addressed peer")
        XCTAssertTrue(claude.requests.isEmpty, "the callee's legacy published provider must be inert")
        XCTAssertTrue(grok.requests.isEmpty, "ambient mutation must not reroute the peer to Grok")
        vm.beforeBotRunDispatchForTesting = nil
        await milestone.value
    }

    func test_agentAppAndBotHandoffsInheritEachCallerProvider_acrossAllProviders() async throws {
        // WHY: the callee Bot is identity/brain only. Whether the caller is an
        // Agent App thread or another Bot, the provider must be inherited from
        // the authenticated caller run, never from the callee revision.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let claude = ControlledBotHandoffRunner(provider: .claude)
        let codex = ControlledBotHandoffRunner(provider: .codex)
        let grok = ControlledBotHandoffRunner(provider: .grok)
        let distill = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.claude, runner: claude)
        context.coordinator.replaceProvider(.codex, runner: codex)
        context.coordinator.replaceProvider(.grok, runner: grok)
        context.coordinator.replaceProvider(.distill, runner: distill)
        let vm = BotsViewModel(context: context, router: router)
        let peer = try vm.create(
            name: "Oliver",
            title: "QA",
            provider: .claude,
            model: "legacy-callee-model"
        )

        func runner(for provider: AgentProvider) -> ControlledBotHandoffRunner {
            switch provider {
            case .claude: return claude
            case .codex: return codex
            case .grok: return grok
            case .distill: return distill
            }
        }

        for provider in AgentProvider.allCases {
            for callerKind in ["agent-app", "bot"] {
                let model = "caller-\(provider.rawValue)-model"
                let originThread = AgentThread(
                    title: "\(callerKind) \(provider.rawValue)",
                    provider: provider,
                    providerInstanceId: provider.rawValue,
                    model: model,
                    status: .running,
                    permissionMode: .fullAccess,
                    reasoningEffort: .high,
                    serviceTier: .fast
                )
                let hostRun = AgentRun(
                    threadId: originThread.id,
                    provider: provider,
                    providerInstanceId: provider.rawValue,
                    model: model,
                    status: .running
                )
                try context.threadRepo.upsert(originThread)
                try context.runRepo.upsert(hostRun)

                let originBot: BotDefinition?
                let originConversation: BotConversation?
                if callerKind == "bot" {
                    let bot = try vm.create(
                        name: "Caller \(provider.rawValue)",
                        title: "Caller",
                        provider: provider == .claude ? .grok : .claude
                    )
                    var conversation = BotConversation(
                        botID: bot.id,
                        title: originThread.title,
                        linkedAgentThreadID: originThread.id
                    )
                    try context.botStore.upsertConversation(conversation)
                    conversation = try XCTUnwrap(context.botStore.conversation(id: conversation.id))
                    originBot = bot
                    originConversation = conversation
                } else {
                    originBot = nil
                    originConversation = nil
                }

                let marker = "INHERIT_\(callerKind)_\(provider.rawValue)"
                let activityID = AgentMessageID()
                let milestone = try XCTUnwrap(
                    context.botPeerHandoffAuthority.submitAgentAppMention(
                        peer: peer,
                        text: marker,
                        peerText: marker,
                        originThread: originThread,
                        activityID: activityID,
                        hostRunID: hostRun.id,
                        providerSnapshots: [],
                        resumeHostAfterPeer: false,
                        originBot: originBot,
                        originConversation: originConversation
                    )
                )
                let selectedRunner = runner(for: provider)
                let started = await waitUntil(timeout: 5) {
                    selectedRunner.requests.contains { $0.prompt.contains(marker) }
                }
                XCTAssertTrue(started, "\(callerKind) \(provider.rawValue) did not start")
                let request = try XCTUnwrap(
                    selectedRunner.requests.first { $0.prompt.contains(marker) }
                )
                XCTAssertEqual(request.provider, provider)
                XCTAssertEqual(request.model, model)
                XCTAssertEqual(request.permissionMode, .fullAccess)
                XCTAssertEqual(request.serviceTier, .fast)
                XCTAssertFalse(
                    [claude, codex, grok]
                        .filter { $0.provider != provider }
                        .flatMap(\.requests)
                        .contains { $0.prompt.contains(marker) },
                    "the callee or ambient provider must never execute this handoff"
                )
                let handoff = try XCTUnwrap(
                    vm.peerHandoffSnapshotsForTesting(
                        originConversationID: originConversation?.id,
                        originThreadID: originConversation == nil ? originThread.id : nil
                    ).first { $0.activityID == activityID.value }
                )
                XCTAssertEqual(handoff.peerProvider, provider)
                XCTAssertEqual(handoff.peerModel, model)
                let peerThread = try XCTUnwrap(
                    try context.threadRepo.get(id: try XCTUnwrap(handoff.peerThreadID))
                )
                XCTAssertEqual(peerThread.provider, provider)
                XCTAssertEqual(peerThread.permissionMode, .fullAccess)
                XCTAssertEqual(peerThread.reasoningEffort, .high)
                XCTAssertTrue(selectedRunner.finish(
                    runID: request.runId,
                    status: .completed,
                    reply: "verified \(marker)"
                ))
                await milestone.value
            }
        }
    }

    func test_directPeerReplyDoesNotStartHostHop() async throws {
        // WHY: the From Quinn reply is the final answer. Feeding it back into
        // Piper creates a second un-attributed assistant response.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        let prompt = "@\(quinn.handle) what is in the inbox?"
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: prompt
        )
        let peerStarted = await waitUntil(timeout: 5) { peerRunner.requests.count == 1 }
        XCTAssertTrue(peerStarted)
        let peerRunID = try XCTUnwrap(peerRunner.requests.first?.runId)
        XCTAssertTrue(peerRunner.finish(
            runID: peerRunID,
            status: .completed,
            reply: "inbox is clear"
        ))
        await milestone.value
        let completed = await waitUntil(timeout: 8) {
            guard let handoff = vm.peerHandoffSnapshotsForTesting().first(where: {
                $0.originBotID == piper.id && $0.peerBotID == quinn.id
            }) else { return false }
            return handoff.phase == .completed
        }
        let observedHandoff = vm.peerHandoffSnapshotsForTesting().first {
            $0.originBotID == piper.id && $0.peerBotID == quinn.id
        }
        XCTAssertTrue(completed)
        XCTAssertNil(observedHandoff?.hostRunID)
        XCTAssertNil(vm.lastHopUserTextForTesting)
        let imported = await waitUntil(timeout: 5) {
            vm.deskTranscriptForTesting(botID: piper.id).contains {
                $0.role == .assistant
                    && $0.peer?.direction == .fromPeer
                    && $0.text.contains("inbox is clear")
            }
        }
        let observedHandoffs = vm.peerHandoffSnapshotsForTesting()
        let exactHandoff = observedHandoffs.first {
            $0.originBotID == piper.id && $0.peerBotID == quinn.id
        }
        let piperTranscript = vm.deskTranscriptForTesting(botID: piper.id)
        XCTAssertEqual(
            piperTranscript.filter {
                $0.role == .user
                    && $0.peer?.direction == .messaged
                    && $0.peer?.botID == quinn.id
                    && $0.text == "@\(quinn.handle) what is in the inbox?"
            }.count,
            1
        )
        XCTAssertEqual(
            piperTranscript.filter {
                $0.role == .assistant
                    && $0.peer?.direction == .fromPeer
                    && $0.peer?.botID == quinn.id
                    && $0.text == "inbox is clear"
            }.count,
            1
        )
        XCTAssertTrue(
            imported,
            "host desk must show the Message from peer reply; selectedConversationID=\(String(describing: vm.selectedConversation?.id)) observerSnapshotCount=\(observedHandoffs.count) phase=\(String(describing: exactHandoff?.phase)) inboundID=\(String(describing: exactHandoff?.inboundMessageID)) peerRunID=\(String(describing: exactHandoff?.peerRunID)) hostRunID=\(String(describing: exactHandoff?.hostRunID))"
        )
    }

    func test_peerReplySettleFindsTheReplyWithoutReadingCheckpointBlobs() async throws {
        // WHY: the settle runs on the MainActor and only needs one run's
        // assistant message id. Loading every checkpoint of the thread decoded
        // all of its file snapshots and diffs (tens of MB on a long thread).
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) what is in the inbox?"
        )
        let peerStarted = await waitUntil(timeout: 5) { peerRunner.requests.count == 1 }
        XCTAssertTrue(peerStarted)
        let blobReadsBefore = context.turnCheckpointRepo.fullRowListReadCountForTesting
        XCTAssertTrue(peerRunner.finish(
            runID: try XCTUnwrap(peerRunner.requests.first?.runId),
            status: .completed,
            reply: "inbox is clear"
        ))
        await milestone.value
        let completed = await waitUntil(timeout: 8) {
            vm.peerHandoffSnapshotsForTesting().first {
                $0.originBotID == piper.id && $0.peerBotID == quinn.id
            }?.phase == .completed
        }
        XCTAssertTrue(completed, "the exact reply must still be found and settle the hand-off")
        XCTAssertEqual(context.turnCheckpointRepo.fullRowListReadCountForTesting, blobReadsBefore,
                       "settling must not read checkpoint snapshot/diff columns")
    }

    func test_beginCreateTwiceAllocatesDistinctHandles_becauseNewAgentIsAPlaceholder() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        _ = try vm.saveStudio()
        vm.beginCreate()
        _ = try vm.saveStudio()
        let bots = try context.botStore.list()
        XCTAssertEqual(bots.count, 2)
        XCTAssertEqual(Set(bots.map(\.handle)).count, 2)
        XCTAssertTrue(bots.allSatisfy { $0.name == "New Agent" })
    }

    func test_studioSlugFollowsNameUntilOwnerEditsIt() throws {
        // WHY: CEO must become @ceo while the slug is unlocked. A typed
        // slug must stay put when the name changes again.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        vm.didEditStudioName("CEO")
        XCTAssertEqual(BotHandle.normalize(vm.studioDraft.handle), "ceo")
        XCTAssertTrue(vm.studioSlugFollowsName)
        vm.didEditStudioSlug("boss")
        XCTAssertFalse(vm.studioSlugFollowsName)
        vm.didEditStudioName("Chief")
        XCTAssertEqual(vm.studioDraft.handle, "boss")
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("labeledField(\"Slug\")"))
        XCTAssertTrue(bots.contains("bots.studio.slug"))
        XCTAssertFalse(bots.contains("labeledField(\"Handle\")"))
        XCTAssertFalse(bots.contains(".disabled(!vm.studioDraft.isNew)"))
    }

    func test_studioSavePersistsSlugRename() throws {
        // WHY: New Bot already has a uniqued handle. Studio Save must
        // write the owner slug, not keep new-agent-N.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        vm.didEditStudioName("CEO")
        XCTAssertEqual(BotHandle.normalize(vm.studioDraft.handle), "ceo")
        let saved = try vm.saveStudio()
        XCTAssertEqual(saved.handle, "ceo")
        XCTAssertEqual(try context.botStore.get(id: saved.id)?.handle, "ceo")
    }

    func test_studioDescriptionAndInstructionsCaptionsContrastWhoVersusHow() throws {
        // WHY: Description and Instructions sat unlabeled next to each
        // other. Owners wrote job prose in the about field and identity
        // into the soul. The captions must contrast who vs how.
        XCTAssertTrue(BotsChrome.Label.descriptionCaption.hasPrefix("Who this teammate is"))
        XCTAssertTrue(BotsChrome.Label.instructionsCaption.hasPrefix("How this teammate should work"))
        XCTAssertTrue(BotsChrome.Label.descriptionCaption.contains("Empty stays out of the prompt"))
        XCTAssertTrue(BotsChrome.Label.instructionsCaption.contains("Always sent"))
        XCTAssertTrue(BotsChrome.Label.instructionsCaption.contains("Empty uses the built-in teammate default"))
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("BotsChrome.Label.descriptionCaption"))
        XCTAssertTrue(bots.contains("BotsChrome.Label.instructionsCaption"))
        XCTAssertTrue(bots.contains(".accessibilityHint(BotsChrome.Label.descriptionCaption)"))
        XCTAssertTrue(bots.contains(".accessibilityHint(BotsChrome.Label.instructionsCaption)"))
    }

    func test_beginCreateSeedsStandingInstructions_becauseHermesDoesNotStartSoulless() throws {
        // WHY: Live Studio/Desk New Agent compiled with "No standing
        // instructions." Hermes seeds SOUL.md; we persist the starter so
        // first chat and Studio both show a replaceable default.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        let bot = try XCTUnwrap(try context.botStore.list().first)
        let revision = try XCTUnwrap(
            bot.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertTrue(BotStandingInstructions.looksGenerated(revision.soul))
        XCTAssertTrue(revision.soul.contains(BotStandingInstructions.generatedSignature))
        XCTAssertFalse(revision.soul.contains(BotStandingInstructions.rememberFactTool), "tools layer owns remember")
        XCTAssertFalse(revision.soul.contains(BotStandingInstructions.openBrowserTool), "tools layer owns browser")
        let preview = try XCTUnwrap(vm.previewBrain(userText: "Remember this"))
        XCTAssertTrue(preview.compiledPayload.contains(BotStandingInstructions.admittedToolsText))
        XCTAssertTrue(
            preview.compiledPayload.contains(BotStandingInstructions.computerUseObservationTool),
            "logical Desktop starter instructions must expose native observation before mutation"
        )
        vm.beginEdit(bot)
        XCTAssertEqual(vm.studioDraft.soul, revision.soul)
        vm.studioDraft.title = "Reviews PRs"
        vm.refreshGeneratedStandingInstructions()
        XCTAssertTrue(vm.studioDraft.soul.contains(BotStandingInstructions.generatedSignature))
        XCTAssertFalse(vm.studioDraft.soul.contains(BotStandingInstructions.changeJobTool), "tools layer owns job tool")
        XCTAssertFalse(vm.studioDraft.soul.contains("You are"), "Role must not rewrite identity into Instructions")
        vm.studioDraft.soul = "Speak plainly."
        vm.studioDraft.title = "Other job"
        vm.refreshGeneratedStandingInstructions()
        XCTAssertEqual(vm.studioDraft.soul, "Speak plainly.", "custom soul is the expert escape hatch")
    }

    func test_openDeskMarksUnreadConversationRead_becauseOpeningTheChatClearsFleetAttention() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", unread: true, attentionState: .unreadActivity)
        )
        vm.reload()
        vm.openDesk(bot)

        let conversation = try XCTUnwrap(context.botStore.listConversations(botID: bot.id).first)
        XCTAssertFalse(conversation.unread)
        XCTAssertEqual(conversation.attentionState, .none)
    }

    func test_createViaVM_persistsThroughBotStoreList_becauseATeammateIsNotAnAgentThread() throws {
        // WHY: a durable teammate must be creatable without becoming an AgentThread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)

        let bot = try vm.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            handle: "piper",
            soul: "Be brief.",
            provider: .claude
        )

        let listed = try context.botStore.list()
        XCTAssertEqual(listed.map(\.id), [bot.id])
        XCTAssertEqual(listed.first?.name, "Piper")
        XCTAssertEqual(listed.first?.handle, "piper")
        XCTAssertTrue(try context.threadRepo.list().isEmpty, "creating a Bot must not open an AgentThread")
        XCTAssertNotEqual(bot.id.value, AgentThreadID().value)
    }

    func test_duplicateDoesNotCopyConversationsOrMemory_becauseCopiesAreNewTeammates() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try context.botStore.putMemory(
            botID: bot.id,
            content: "Prefers dark mode",
            provenance: "user",
            trusted: true,
            source: "chat"
        )
        try context.botStore.upsertConversation(BotConversation(botID: bot.id, title: "Standup"))

        let copy = try vm.duplicate(id: bot.id)

        XCTAssertNotEqual(copy.id, bot.id)
        XCTAssertEqual(copy.name, "Piper copy")
        XCTAssertTrue(try context.botStore.listMemory(botID: copy.id).isEmpty)
        XCTAssertTrue(try context.botStore.listConversations(botID: copy.id).isEmpty)
        XCTAssertEqual(try context.botStore.listMemory(botID: bot.id).count, 1)
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, 1)
    }

    private final class RecordingDocker: BotComputerDockerClienting, @unchecked Sendable {
        var created: [String] = []
        var builds: [URL] = []
        var png = BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)
        var execCallCount = 0
        var failExecAfterCall: Int?
        var containers: [String: BotComputerContainerInspect] = [:]
        var startError: Error?
        var startCallCount = 0
        var blockedStartName: String?
        var startGate: DispatchSemaphore?
        let startStarted = DispatchSemaphore(value: 0)
        var stopCallCount = 0
        var stopGate: DispatchSemaphore?
        var blockedRemoveName: String?
        var removeGate: DispatchSemaphore?
        let removeStarted = DispatchSemaphore(value: 0)
        let removeFinished = DispatchSemaphore(value: 0)
        var blocksBuild = false
        let buildStarted = DispatchSemaphore(value: 0)
        let allowBuild = DispatchSemaphore(value: 0)

        func info() throws -> String { "ok" }
        func imageExists(tag: String) throws -> Bool { true }
        func imageLabel(tag: String, key: String) throws -> String {
            key == BotComputerGuestSpec.recipeLabelKey ? BotComputerGuestSpec.recipeRevision : ""
        }
        func imageID(tag: String) throws -> String { "img" }
        func build(context: URL, tag: String) throws {
            builds.append(context)
            if blocksBuild {
                buildStarted.signal()
                _ = allowBuild.wait(timeout: .now() + 2)
            }
        }
        func create(options: BotComputerContainerCreateOptions) throws -> String {
            created.append(options.name)
            containers[options.name] = BotComputerContainerInspect(running: false, imageID: "img", hostPort: 49152)
            return options.name
        }
        func start(name: String) throws {
            startCallCount += 1
            if name == blockedStartName, let startGate {
                startStarted.signal()
                startGate.wait()
            }
            if let startError { throw startError }
            containers[name] = BotComputerContainerInspect(running: true, imageID: "img", hostPort: 49152)
        }
        func stop(name: String) throws {
            stopCallCount += 1
            stopGate?.wait()
            if var value = containers[name] {
                value.running = false
                containers[name] = value
            }
        }
        func inspect(name: String) throws -> BotComputerContainerInspect {
            guard let value = containers[name] else { throw BotComputerGuestError.notReady }
            return value
        }
        func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data {
            execCallCount += 1
            if let failExecAfterCall, execCallCount > failExecAfterCall {
                throw BotComputerGuestError.observeFailed
            }
            return png
        }
        func rename(from: String, to: String) throws {
            containers[to] = containers[from]
            containers[from] = nil
        }
        func ensureNetwork(name: String) throws {}
        func remove(name: String) throws {
            if name == blockedRemoveName, let removeGate {
                removeStarted.signal()
                removeGate.wait()
            }
            containers[name] = nil
            removeFinished.signal()
        }
        func removeMatching(namePrefix: String) throws {
            for name in containers.keys where name.hasPrefix(namePrefix) {
                containers[name] = nil
            }
        }
    }

    private final class GuestEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [EventBus.Event] = []

        func append(_ event: EventBus.Event) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [EventBus.Event] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func test_e2eThreeRuntimesUseShippedStudioSaveAndSend() async throws {
        // WHY: the owner must persist and send on all three advertised
        // runtimes. this-Mac paths stay live without Docker; Docker-with-GUI
        // only after shipped proveReady + this-bot PNG.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.dockerGuestReadyOverrideForTesting = false

        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .logicalExecutionSpace
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .logicalExecutionSpace)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Open https://example.com in the default macOS browser."))
        XCTAssertEqual(
            BotStandingInstructions.admittedToolsText(for: .logicalExecutionSpace)
                .contains(BotStandingInstructions.computerUseObservationTool),
            true
        )

        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .botOwnedBrowser
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .botOwnedBrowser)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Open https://example.com in this teammate's own browser."))
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText(for: .botOwnedBrowser)
                .contains(BotStandingInstructions.generatedNativeHostComputerLine)
        )

        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            vm.openStudio(piper)
            vm.studioExecutionDestination = .ownVM
            XCTAssertThrowsError(try vm.saveStudio())
            return
        }
        let recipe = try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL())
        let service = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: BotComputerDockerCLI(),
            recipeContext: recipe
        )
        vm.computerGuestService = service
        vm.dockerGuestReadyOverrideForTesting = nil
        XCTAssertTrue(service.proveReady(), service.lastReason)
        XCTAssertEqual(service.lastReady?.pngMagic, "89504e47")
        XCTAssertEqual(service.lastReady?.screenURL.host, "127.0.0.1")
        vm.openStudio(piper)
        vm.studioExecutionDestination = .ownVM
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)
        let launched = await waitUntil(timeout: 30) { vm.isGuestRunning(piper.id) }
        XCTAssertTrue(launched)
        XCTAssertEqual(vm.lastGuestScreenURL?.host, "127.0.0.1")
        let shot = try service.observe(botID: piper.id)
        XCTAssertEqual(shot.magic, "89504e47")
        print("E2E_LOGICAL=1 E2E_BOT_BROWSER=1 E2E_DOCKER=1 PNG_MAGIC=\(shot.magic)")
        service.teardown(botID: piper.id)
    }

    func test_presentDockerGuestProvisionsThisBotOnLoopback() async throws {
        // WHY: Docker-with-GUI must provision THIS bot off-main and keep a
        // 127.0.0.1 viewer URL.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        vm.presentGuestDesktop(botID: piper.id)
        let launched = await waitUntil(timeout: 2) { vm.isGuestRunning(piper.id) }
        XCTAssertTrue(launched)
        XCTAssertEqual(vm.lastGuestScreenURL?.host, "127.0.0.1")
        XCTAssertTrue(fake.created.contains(BotComputerGuestSpec.containerName(botID: piper.id)))
        XCTAssertEqual(vm.guestScreenURL(for: piper.id)?.host, "127.0.0.1")
        XCTAssertTrue(vm.isGuestRunning(piper.id))
    }

    func test_pairedGuestStartSettlesOnlyWithExactRemoteFrameInReceiptAndState() async throws {
        // WHY: a terminal start receipt without a frame leaves iOS showing a
        // running guest it cannot observe or control. A delayed provision must
        // cross the real router -> VM provision -> remoteFrame -> receipt/state
        // boundary and publish one secret-free terminal hint without replaying Start.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let docker = RecordingDocker()
        docker.png = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x06, 0x40, 0x00, 0x00, 0x04, 0xb0,
        ])
        docker.failExecAfterCall = 1
        docker.blockedStartName = BotComputerGuestSpec.containerName(botID: bot.id)
        let startGate = DispatchSemaphore(value: 0)
        docker.startGate = startGate
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        let botID = bot.id.value.uuidString.lowercased()
        let hostID = "paired-guest-host"
        let initial = try await router.dispatchPairedBotRemote(method: "bot.guest.state", params: [
            "host_id": .string(hostID),
            "bot_id": .string(botID),
        ])
        let initialState = try XCTUnwrap(initial.objectValue)
        let tasks = try XCTUnwrap(initialState["task_catalog"]?.objectValue?["tasks"]?.arrayValue)
        let startTask = try XCTUnwrap(tasks.compactMap(\.objectValue).first {
            $0["operation"]?.stringValue == "bot.guest.start"
        })
        let catalogRecipe = try XCTUnwrap(startTask["recipe"]?.objectValue)
        XCTAssertEqual(catalogRecipe["image_reference"]?.stringValue, BotComputerGuestSpec.imageTag)
        XCTAssertNotEqual(
            catalogRecipe["image_reference"]?.stringValue,
            "img",
            "the host-authorized logical image must remain distinct from Docker's physical inspect identity"
        )
        let requestID = "paired-guest-frame"
        let recorder = GuestEventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "bot.guest.updated",
                  event.payload.objectValue?["request_id"]?.stringValue == requestID else { return }
            recorder.append(event)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        let accepted = try await router.dispatchPairedBotRemote(method: "bot.guest.start", params: [
            "client_request_id": .string(requestID),
            "host_id": .string(hostID),
            "bot_id": .string(botID),
            "task_id": try XCTUnwrap(startTask["id"]),
            "recipe_id": try XCTUnwrap(startTask["recipe_id"]),
        ])
        XCTAssertEqual(docker.startStarted.wait(timeout: .now() + 10), .success)
        let acceptedRuntime = try XCTUnwrap(
            accepted.objectValue?["readback"]?.objectValue?["runtime"]?.objectValue
        )
        for _ in 0..<40 {
            let pending = try await router.dispatchPairedBotRemote(method: "bot.receipt.status", params: [
                "client_request_id": .string(requestID),
            ])
            XCTAssertEqual(pending.objectValue?["status"]?.stringValue, "accepted")
        }
        XCTAssertEqual(docker.startCallCount, 1)
        XCTAssertTrue(recorder.events.isEmpty, "accepted is not a false terminal hint")
        startGate.signal()
        var receipt = accepted
        for _ in 0..<200 {
            receipt = try await router.dispatchPairedBotRemote(method: "bot.receipt.status", params: [
                "client_request_id": .string(requestID),
            ])
            if receipt.objectValue?["status"]?.stringValue != "accepted" { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let terminal = try XCTUnwrap(receipt.objectValue)
        XCTAssertEqual(terminal["status"]?.stringValue, "completed")
        let receiptReadback = try XCTUnwrap(terminal["readback"]?.objectValue)
        let receiptFrame = try XCTUnwrap(receiptReadback["frame"]?.objectValue)
        let receiptRuntime = try XCTUnwrap(receiptReadback["runtime"]?.objectValue)

        let state = try await router.dispatchPairedBotRemote(method: "bot.guest.state", params: [
            "host_id": .string(hostID),
            "bot_id": .string(botID),
        ])
        let stateObject = try XCTUnwrap(state.objectValue)
        let stateFrame = try XCTUnwrap(stateObject["frame"]?.objectValue)
        let stateRuntime = try XCTUnwrap(stateObject["runtime"]?.objectValue)
        XCTAssertEqual(stateObject["status"]?.stringValue, "running")
        XCTAssertEqual(receiptFrame, stateFrame)
        XCTAssertEqual(receiptRuntime, stateRuntime)
        for key in ["host_id", "bot_id", "app_run_id", "session_id", "grant_id", "grant_generation"] {
            XCTAssertEqual(receiptRuntime[key], acceptedRuntime[key], key)
        }
        XCTAssertEqual(receiptRuntime["host_id"]?.stringValue, hostID)
        XCTAssertEqual(receiptRuntime["bot_id"]?.stringValue, botID)
        XCTAssertEqual(receiptRuntime["container_id"]?.stringValue, BotComputerGuestSpec.containerName(botID: bot.id))
        XCTAssertEqual(receiptRuntime["image_reference"]?.stringValue, BotComputerGuestSpec.imageTag)
        XCTAssertEqual(
            receiptFrame["runtime"]?.objectValue?["image_reference"]?.stringValue,
            BotComputerGuestSpec.imageTag
        )
        XCTAssertEqual(receiptFrame["pixel_width"]?.intValue, 1_600)
        XCTAssertEqual(receiptFrame["pixel_height"]?.intValue, 1_200)
        XCTAssertEqual(receiptFrame["png_base64"]?.stringValue, docker.png.base64EncodedString())
        XCTAssertEqual(receiptFrame["png_hash"]?.stringValue?.count, 64)
        XCTAssertEqual(
            docker.execCallCount,
            1,
            "the exact frame proven during start readiness must settle the receipt without another capture"
        )
        let replay = try await router.dispatchPairedBotRemote(method: "bot.guest.start", params: [
            "client_request_id": .string(requestID),
            "host_id": .string(hostID),
            "bot_id": .string(botID),
            "task_id": try XCTUnwrap(startTask["id"]),
            "recipe_id": try XCTUnwrap(startTask["recipe_id"]),
        ])
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(docker.startCallCount, 1)

        XCTAssertEqual(recorder.events.count, 1)
        let event = try XCTUnwrap(recorder.events.first)
        let payload = try XCTUnwrap(event.payload.objectValue)
        XCTAssertEqual(payload["host_id"]?.stringValue, hostID)
        XCTAssertEqual(payload["bot_id"]?.stringValue, botID)
        XCTAssertEqual(payload["request_id"]?.stringValue, requestID)
        XCTAssertEqual(payload["client_request_id"]?.stringValue, requestID)
        XCTAssertEqual(payload["receipt_id"], terminal["receipt_id"])
        XCTAssertEqual(payload["status"]?.stringValue, "running")
        XCTAssertEqual(payload["after_frame_id"], receiptReadback["after_frame_id"])
        XCTAssertEqual(payload["grant_generation"], receiptReadback["grant_generation"])
        let eventWire = String(data: try JSONEncoder().encode(event.payload), encoding: .utf8) ?? ""
        for secretKey in ["png_base64", "bearer", "token", "http://", "https://", "viewer_path"] {
            XCTAssertFalse(eventWire.contains(secretKey), secretKey)
        }
    }

    func test_pairedGuestInputSettlementPublishesExactPointerRequestIDForSuccessAndFailure() async throws {
        // WHY: guest input settles asynchronously after the authority has
        // accepted it. Each terminal readback/event must retain that input's
        // request identity, rather than the Start (or preceding input) ID.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let docker = RecordingDocker()
        docker.png = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x06, 0x40, 0x00, 0x00, 0x04, 0xb0,
        ])
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        let botID = bot.id.value.uuidString.lowercased()
        let hostID = "paired-guest-input-host"
        let initial = try await router.dispatchPairedBotRemote(method: "bot.guest.state", params: [
            "host_id": .string(hostID),
            "bot_id": .string(botID),
        ])
        let initialState = try XCTUnwrap(initial.objectValue)
        let tasks = try XCTUnwrap(initialState["task_catalog"]?.objectValue?["tasks"]?.arrayValue)
        let startTask = try XCTUnwrap(tasks.compactMap(\.objectValue).first {
            $0["operation"]?.stringValue == "bot.guest.start"
        })
        let pointerTask = try XCTUnwrap(tasks.compactMap(\.objectValue).first {
            $0["operation"]?.stringValue == "bot.guest.input"
                && $0["axis"]?.stringValue == "pointer"
        })
        let startRequestID = "paired-guest-input-start"
        let successRequestID = "paired-guest-input-success"
        let failureRequestID = "paired-guest-input-failure"
        let recorder = GuestEventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "bot.guest.updated",
                  let requestID = event.payload.objectValue?["request_id"]?.stringValue,
                  [successRequestID, failureRequestID].contains(requestID) else { return }
            recorder.append(event)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        func terminalReceipt(requestID: String) async throws -> [String: JSONValue] {
            var latest = JSONValue.null
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                latest = try await router.dispatchPairedBotRemote(method: "bot.receipt.status", params: [
                    "client_request_id": .string(requestID),
                ])
                if let object = latest.objectValue,
                   object["status"]?.stringValue != "accepted" {
                    return object
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw NSError(domain: "BotsWindowTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "receipt remained accepted: \(requestID)",
            ])
        }

        _ = try await router.dispatchPairedBotRemote(method: "bot.guest.start", params: [
            "client_request_id": .string(startRequestID),
            "host_id": .string(hostID),
            "bot_id": .string(botID),
            "task_id": try XCTUnwrap(startTask["id"]),
            "recipe_id": try XCTUnwrap(startTask["recipe_id"]),
        ])
        let startTerminal = try await terminalReceipt(requestID: startRequestID)
        XCTAssertEqual(startTerminal["status"]?.stringValue, "completed")
        let startReadback = try XCTUnwrap(startTerminal["readback"]?.objectValue)
        let startRuntime = try XCTUnwrap(startReadback["runtime"]?.objectValue)
        let startFrameID = try XCTUnwrap(startReadback["frame"]?.objectValue?["frame_id"]?.stringValue)

        let pointerParams: [String: JSONValue] = [
            "client_request_id": .string(successRequestID),
            "host_id": .string(hostID),
            "bot_id": .string(botID),
            "task_id": try XCTUnwrap(pointerTask["id"]),
            "runtime": .object(startRuntime),
            "before_frame_id": .string(startFrameID),
            "input": .object([
                "kind": .string("pointer"),
                "x": .number(100.0),
                "y": .number(100.0),
            ]),
        ]
        let acceptedSuccess = try await router.dispatchPairedBotRemote(
            method: "bot.guest.input",
            params: pointerParams
        )
        XCTAssertEqual(acceptedSuccess.objectValue?["status"]?.stringValue, "accepted")
        let successTerminal = try await terminalReceipt(requestID: successRequestID)
        XCTAssertEqual(successTerminal["status"]?.stringValue, "completed")
        let successReadback = try XCTUnwrap(successTerminal["readback"]?.objectValue)
        XCTAssertEqual(successReadback["last_request_id"]?.stringValue, successRequestID)
        XCTAssertNotEqual(successReadback["last_request_id"]?.stringValue, startRequestID)
        let successFrameID = try XCTUnwrap(successReadback["frame"]?.objectValue?["frame_id"]?.stringValue)
        let successEvent = try XCTUnwrap(recorder.events.first {
            $0.payload.objectValue?["request_id"]?.stringValue == successRequestID
        })
        XCTAssertEqual(successEvent.payload.objectValue?["request_id"]?.stringValue, successRequestID)
        XCTAssertEqual(successEvent.payload.objectValue?["after_frame_id"]?.stringValue, successFrameID)

        docker.failExecAfterCall = docker.execCallCount
        let failureParams = pointerParams.merging([
            "client_request_id": .string(failureRequestID),
            "runtime": .object(try XCTUnwrap(successReadback["runtime"]?.objectValue)),
            "before_frame_id": .string(successFrameID),
        ]) { _, new in new }
        let acceptedFailure = try await router.dispatchPairedBotRemote(
            method: "bot.guest.input",
            params: failureParams
        )
        XCTAssertEqual(acceptedFailure.objectValue?["status"]?.stringValue, "accepted")
        let failureTerminal = try await terminalReceipt(requestID: failureRequestID)
        XCTAssertEqual(failureTerminal["status"]?.stringValue, "failed")
        let failureReadback = try XCTUnwrap(failureTerminal["readback"]?.objectValue)
        XCTAssertEqual(failureReadback["last_request_id"]?.stringValue, failureRequestID)
        XCTAssertNotEqual(failureReadback["last_request_id"]?.stringValue, startRequestID)
        XCTAssertNotEqual(failureReadback["last_request_id"]?.stringValue, successRequestID)
        let failureEvent = try XCTUnwrap(recorder.events.first {
            $0.payload.objectValue?["request_id"]?.stringValue == failureRequestID
        })
        XCTAssertEqual(failureEvent.payload.objectValue?["request_id"]?.stringValue, failureRequestID)
    }

    func test_pairedGuestStopSettlementPublishesExactRequestIDWithoutReplay() async throws {
        // WHY: stopping invalidates the grant before Docker finishes. The
        // terminal receipt/event must retain Stop's request identity instead
        // of the stale Start context, and replaying Stop must not publish it
        // twice.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let docker = RecordingDocker()
        docker.png = Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x06, 0x40, 0x00, 0x00, 0x04, 0xb0,
        ])
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        let botID = bot.id.value.uuidString.lowercased()
        let hostID = "paired-guest-stop-host"
        let initial = try await router.dispatchPairedBotRemote(method: "bot.guest.state", params: [
            "host_id": .string(hostID),
            "bot_id": .string(botID),
        ])
        let initialState = try XCTUnwrap(initial.objectValue)
        let tasks = try XCTUnwrap(initialState["task_catalog"]?.objectValue?["tasks"]?.arrayValue)
        let startTask = try XCTUnwrap(tasks.compactMap(\.objectValue).first {
            $0["operation"]?.stringValue == "bot.guest.start"
        })
        let stopTask = try XCTUnwrap(tasks.compactMap(\.objectValue).first {
            $0["operation"]?.stringValue == "bot.guest.stop"
        })
        let startRequestID = "paired-guest-stop-start"
        let stopRequestID = "paired-guest-stop"
        let recorder = GuestEventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "bot.guest.updated",
                  event.payload.objectValue?["request_id"]?.stringValue == stopRequestID else { return }
            recorder.append(event)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        func terminalReceipt(requestID: String) async throws -> [String: JSONValue] {
            var latest = JSONValue.null
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                latest = try await router.dispatchPairedBotRemote(method: "bot.receipt.status", params: [
                    "client_request_id": .string(requestID),
                ])
                if let object = latest.objectValue,
                   object["status"]?.stringValue != "accepted" {
                    return object
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw NSError(domain: "BotsWindowTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "receipt remained accepted: \(requestID)",
            ])
        }

        _ = try await router.dispatchPairedBotRemote(method: "bot.guest.start", params: [
            "client_request_id": .string(startRequestID),
            "host_id": .string(hostID),
            "bot_id": .string(botID),
            "task_id": try XCTUnwrap(startTask["id"]),
            "recipe_id": try XCTUnwrap(startTask["recipe_id"]),
        ])
        let startTerminal = try await terminalReceipt(requestID: startRequestID)
        XCTAssertEqual(startTerminal["status"]?.stringValue, "completed")
        let startReadback = try XCTUnwrap(startTerminal["readback"]?.objectValue)
        let runtime = try XCTUnwrap(startReadback["runtime"]?.objectValue)

        let stopParams: [String: JSONValue] = [
            "client_request_id": .string(stopRequestID),
            "host_id": .string(hostID),
            "bot_id": .string(botID),
            "task_id": try XCTUnwrap(stopTask["id"]),
            "runtime": .object(runtime),
        ]
        let accepted = try await router.dispatchPairedBotRemote(
            method: "bot.guest.stop",
            params: stopParams
        )
        XCTAssertEqual(accepted.objectValue?["status"]?.stringValue, "accepted")
        let terminal = try await terminalReceipt(requestID: stopRequestID)
        XCTAssertEqual(terminal["status"]?.stringValue, "completed")
        XCTAssertEqual(terminal["request_id"]?.stringValue, stopRequestID)
        let readback = try XCTUnwrap(terminal["readback"]?.objectValue)
        XCTAssertEqual(readback["status"]?.stringValue, "stopped")
        XCTAssertEqual(readback["last_request_id"]?.stringValue, stopRequestID)
        XCTAssertNotEqual(readback["last_request_id"]?.stringValue, startRequestID)
        XCTAssertNil(readback["runtime"])

        let stoppedState = try await router.dispatchPairedBotRemote(method: "bot.guest.state", params: [
            "host_id": .string(hostID),
            "bot_id": .string(botID),
        ])
        XCTAssertEqual(stoppedState.objectValue?["status"]?.stringValue, "stopped")
        XCTAssertEqual(stoppedState.objectValue?["last_request_id"]?.stringValue, stopRequestID)
        XCTAssertEqual(docker.stopCallCount, 1)

        let replay = try await router.dispatchPairedBotRemote(
            method: "bot.guest.stop",
            params: stopParams
        )
        XCTAssertEqual(replay.objectValue, terminal)
        XCTAssertEqual(recorder.events.count, 1)
        let event = try XCTUnwrap(recorder.events.first)
        let payload = try XCTUnwrap(event.payload.objectValue)
        XCTAssertEqual(payload["request_id"]?.stringValue, stopRequestID)
        XCTAssertEqual(payload["client_request_id"]?.stringValue, stopRequestID)
        XCTAssertEqual(payload["receipt_id"], terminal["receipt_id"])
        XCTAssertEqual(payload["status"]?.stringValue, "stopped")
    }

    func test_guestTerminalHintKeepsFailureAndStopSecretFreeAndRejectsMismatchedFrame() throws {
        // WHY: the terminal event is only a bounded reread hint. It must retain
        // exact request ownership for failure/stop without becoming a second
        // frame, URL, or capability transport.
        let requestID = "guest-terminal-request"
        let botID = UUID().uuidString.lowercased()
        let baseReadback: [String: Any] = [
            "host_id": "guest-terminal-host",
            "bot_id": botID,
            "last_request_id": requestID,
            "viewer_path": "/vnc.html",
            "task_catalog": ["tasks": []],
            "grant_generation": 3,
            "png_base64": "unsafe-frame",
            "bearer_token": "unsafe-bearer",
            "url": "http://127.0.0.1:6080/vnc.html",
        ]
        func receipt(status: String, readback: [String: Any]) -> [String: Any] {
            [
                "request_id": requestID,
                "receipt_id": "guest-terminal-receipt",
                "status": status,
                "bot_id": botID,
                "readback": readback,
            ]
        }

        var failedReadback = baseReadback
        failedReadback["status"] = "failed"
        let failedValue = try XCTUnwrap(AppCommandRouter.pairedGuestTerminalEventPayload(
            receipt(status: "failed", readback: failedReadback)
        ))
        let failed = try XCTUnwrap(failedValue.objectValue)
        XCTAssertEqual(Set(failed.keys), [
            "host_id", "bot_id", "request_id", "client_request_id",
            "receipt_id", "status", "grant_generation",
        ])
        XCTAssertEqual(failed["status"]?.stringValue, "failed")

        var stoppedReadback = baseReadback
        stoppedReadback["status"] = "stopped"
        stoppedReadback["after_frame_id"] = "last-visible-frame"
        let stoppedValue = try XCTUnwrap(AppCommandRouter.pairedGuestTerminalEventPayload(
            receipt(status: "completed", readback: stoppedReadback)
        ))
        let stopped = try XCTUnwrap(stoppedValue.objectValue)
        XCTAssertEqual(stopped["status"]?.stringValue, "stopped")
        XCTAssertEqual(stopped["after_frame_id"]?.stringValue, "last-visible-frame")

        var mismatchedRunning = baseReadback
        mismatchedRunning["status"] = "running"
        mismatchedRunning["after_frame_id"] = "authoritative-frame"
        mismatchedRunning["frame"] = ["frame_id": "other-frame"]
        XCTAssertNil(AppCommandRouter.pairedGuestTerminalEventPayload(
            receipt(status: "completed", readback: mismatchedRunning)
        ))
    }

    func test_presentGuestDesktopPublishesLaunchProgressAndSupportsRetry() async throws {
        // WHY: a slow or failed Docker launch must acknowledge the user's click
        // immediately, reject duplicate starts, and leave a working retry path.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        fake.startError = BotComputerGuestError.dockerUnavailable
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil

        vm.presentGuestDesktop(botID: piper.id)
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .starting)
        vm.presentGuestDesktop(botID: piper.id)

        var deadline = Date().addingTimeInterval(2)
        while vm.guestLaunchState(for: piper.id) == .starting, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(
            vm.guestLaunchState(for: piper.id),
            .failed(BotComputerDockerError.provisioningFailed.description)
        )
        XCTAssertEqual(fake.startCallCount, 1, "an acknowledged start must suppress duplicate work")
        XCTAssertFalse(vm.isGuestRunning(piper.id))

        fake.startError = nil
        vm.presentGuestDesktop(botID: piper.id)
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .starting)

        deadline = Date().addingTimeInterval(2)
        while !vm.isGuestRunning(piper.id), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(vm.isGuestRunning(piper.id))
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .idle)
        XCTAssertEqual(fake.startCallCount, 2)
        XCTAssertEqual(vm.guestScreenURL(for: piper.id)?.host, "127.0.0.1")
    }

    func test_saveStudioStartsFirstDockerProvisionOffMainAndMainActorKeepsTicking() async throws {
        // WHY: first publish may hit a long Docker build/start. Save must
        // persist promptly, show Starting, and leave the app event loop alive.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        let service = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.computerGuestService = service
        vm.dockerGuestReadyOverrideForTesting = nil
        XCTAssertTrue(service.proveReady())
        let startGate = DispatchSemaphore(value: 0)
        fake.blockedStartName = BotComputerGuestSpec.containerName(botID: bot.id)
        fake.startGate = startGate

        vm.openStudio(bot)
        vm.studioExecutionDestination = .ownVM
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        let startedAt = Date()
        _ = try vm.saveStudio()

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.1)
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)
        XCTAssertEqual(vm.guestLaunchState(for: bot.id), .starting)
        XCTAssertEqual(fake.startStarted.wait(timeout: .now() + 10), .success)
        await Task.yield()
        XCTAssertTrue(heartbeat, "a blocked Docker start must not starve MainActor work")

        startGate.signal()
        let launched = await waitUntil(timeout: 2) { vm.isGuestRunning(bot.id) }
        XCTAssertTrue(
            launched,
            "launch state=\(vm.guestLaunchState(for: bot.id)) reason=\(vm.dockerGuestProbeReason ?? "-")"
        )
    }

    func test_dockerDesktopAdmissionStartsGuestOffMainAndFailsClosedUntilReady() async throws {
        // WHY: pressing Send must never provision Docker synchronously on the
        // SwiftUI main thread; admission stays closed while the shared launch
        // task prepares and validates this bot's guest screen.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.desktopKindOverrideForTesting = .dockerDesktop
        vm.dockerGuestReadyOverrideForTesting = nil
        let fake = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )

        XCTAssertThrowsError(try vm.admitDesktopSend(bot: piper))
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .starting)
        XCTAssertFalse(vm.send("open the linux screen"))
        XCTAssertEqual(vm.errorMessage, "Linux desktop is starting. Try again when it is ready.")

        let deadline = Date().addingTimeInterval(2)
        while !vm.isGuestRunning(piper.id), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(vm.isGuestRunning(piper.id))
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .idle)
        XCTAssertEqual(fake.startCallCount, 1, "repeated admission must share the active launch")
        XCTAssertNoThrow(try vm.admitDesktopSend(bot: piper))
    }

    func test_deskDockerGuestScreenLivesOnMainCanvas() throws {
        // WHY: the live Linux screen belongs in the inspector desktop
        // pane, not above the chat timeline.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let chat = source.range(of: "private func deskChat") else {
            return XCTFail("desk chat must exist")
        }
        let paneStart = source.range(of: "private func deskDesktopPane")?.lowerBound ?? source.endIndex
        let chatSlice = String(source[chat.lowerBound..<paneStart])
        XCTAssertFalse(chatSlice.contains("BotComputerGuestCanvas"))
        let pane = String(source[paneStart...].prefix(2200))
        XCTAssertTrue(pane.contains("BotComputerGuestCanvas"))
        XCTAssertTrue(pane.contains("bots.desk.desktop.guestScreen"))
        // Plan A: the pane says where the selected thread's agent runs (guest or Mac).
        XCTAssertTrue(pane.contains("vm.deskRuntimeLabel"))
        XCTAssertTrue(pane.contains("bots.desk.desktop.runtime"))
        XCTAssertTrue(pane.contains("bots.desk.desktop.start"))
        XCTAssertTrue(source.contains("openGuestDesktopInNewWindow"))
        let canvas = try String(
            contentsOf: sourceURL("Sources/AppShell/BotComputerGuestScreenView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(canvas.contains("struct BotComputerGuestCanvas"))
        XCTAssertTrue(canvas.contains("rectangle.on.rectangle"))
        XCTAssertTrue(canvas.contains("bots.desk.desktop.openInNewWindow"))
        XCTAssertTrue(canvas.contains("acceptsFirstResponder"))
        XCTAssertFalse(canvas.contains("View-only noVNC"))
    }

    func test_guestCanvasAcknowledgesSlowStartAndOffersRetryAfterFailure() throws {
        // WHY: Docker may need minutes to prepare the first desktop. The click
        // must remain visibly acknowledged, and a failed launch must explain
        // the recovery path instead of leaving the unchanged Start screen.
        let canvas = try String(
            contentsOf: sourceURL("Sources/AppShell/BotComputerGuestScreenView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(canvas.contains("ProgressView()"))
        XCTAssertTrue(canvas.contains("Starting…"))
        XCTAssertTrue(canvas.contains("Try Again"))
        XCTAssertTrue(canvas.contains("First launch can take a few minutes"))
    }

    func test_filesLocationBarClaimsFullWidthForBothLocations() throws {
        // WHY: Docker home happened to expand the bar through its explanatory
        // HStack, while Bot files collapsed the same bar to the picker's width
        // and floated it above only the editor pane.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private var filesTab") else {
            return XCTFail("files tab must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n            Group {")?.lowerBound ?? rest.endIndex
        let bar = String(rest[..<end])

        XCTAssertTrue(
            bar.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
            "the location bar must claim the full Files width even when Bot files has no descriptive row"
        )
    }

    func test_guestCanvasOffersRebuildBeforeStopAndNoTerminalControl() throws {
        // WHY: Dockerfile changes need an explicit safe apply action beside the
        // running desktop; Terminal is unrelated and consumed scarce chrome.
        let source = try String(
            contentsOf: sourceURL("Sources/AppShell/BotComputerGuestScreenView.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "struct BotComputerGuestCanvas") else {
            return XCTFail("guest canvas must exist")
        }
        let canvas = String(source[start.lowerBound...])
        let rebuild = try XCTUnwrap(canvas.range(of: "Text(rebuilding ? \"Rebuilding…\" : \"Rebuild\")")?.lowerBound)
        let stop = try XCTUnwrap(canvas.range(of: "Button(\"Stop\"")?.lowerBound)
        XCTAssertLessThan(rebuild, stop, "Rebuild must sit immediately before Stop")
        XCTAssertFalse(canvas.contains("Button(\"Terminal\""))
    }

    func test_detachedGuestDesktopShowsRebuildFailureStrip_becauseItsRootMustNotSwallowTheError() throws {
        // WHY: the shared Rebuild control is also mounted in the detached
        // desktop window, whose root must not silently swallow vm.errorMessage.
        // It shows the shared strip, not an alert: an alert put an OK button
        // between the owner and the live desktop.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private struct BotGuestDesktopRoot") else {
            return XCTFail("detached guest root must exist")
        }
        let root = String(source[start.lowerBound...])
        XCTAssertTrue(root.contains("if let message = vm.errorMessage {"))
        XCTAssertTrue(root.contains("AgentChatErrorStrip("))
        XCTAssertTrue(root.contains("identifier: \"bots.desk.desktop.window.error\""))
        XCTAssertTrue(
            root.contains("onDismiss: { vm.errorMessage = nil }"),
            "the strip stays until dismissed, and dismissing clears the one error slot"
        )
        XCTAssertFalse(root.contains(".alert("), "a Bots error must not block the desktop window")
    }

    func test_botsErrorsShowAsNonModalStrip_becauseAnAlertBlockedTheWindowAndTookComposerFocus() throws {
        // WHY: dozens of sites write vm.errorMessage, including soft validation
        // such as "Name is required." Each one opened a modal alert, so the window
        // stopped answering and the composer lost focus until OK. The error is
        // now one row above the destination: it names the failure, stays until
        // dismissed, and leaves every control (and the first responder) alone.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(
            source.contains(".alert(\"Bots\""),
            "no Bots root may present vm.errorMessage as a modal alert"
        )
        let start = try XCTUnwrap(source.range(of: "public struct BotsRootView"))
        let end = try XCTUnwrap(source.range(
            of: ".modifier(BotsTitlebarBleed(edges: titlebarSafeAreaEdges))",
            range: start.upperBound..<source.endIndex
        ))
        let root = String(source[start.lowerBound..<end.lowerBound])
        let guardLine = try XCTUnwrap(
            root.range(of: "if let message = vm.errorMessage {"),
            "the root must mount the strip whenever vm.errorMessage is set"
        )
        let strip = try XCTUnwrap(root.range(of: "AgentChatErrorStrip("))
        let destination = try XCTUnwrap(root.range(of: "switch vm.screen.resolvedDestination"))
        XCTAssertLessThan(guardLine.lowerBound, strip.lowerBound)
        XCTAssertLessThan(
            strip.lowerBound, destination.lowerBound,
            "the strip is a row above the destination, so it covers neither the header nor the composer"
        )
        XCTAssertTrue(root.contains("identifier: \"bots.error\""))
        XCTAssertTrue(
            root.contains("onDismiss: { vm.errorMessage = nil }"),
            "dismissing the strip clears the one error slot, as OK did"
        )
        XCTAssertFalse(root.contains(".alert("), "the Bots root presents no alert at all")
        // The strip is the shared chat component, not a Bots lookalike.
        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatSharedChrome.swift"), encoding: .utf8)
        XCTAssertTrue(chrome.contains("public struct AgentChatErrorStrip"))
    }

    func test_rebuildDockerGuestPublishesProgressAndRejectsDuplicateWork() async throws {
        // WHY: image builds can take minutes. The first click must acknowledge
        // work immediately and a second click must not start a competing build.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        vm.presentGuestDesktop(botID: bot.id)
        let launched = await waitUntil(timeout: 2) { vm.isGuestRunning(bot.id) }
        XCTAssertTrue(launched)
        fake.blocksBuild = true

        vm.rebuildDockerGuest(botID: bot.id)
        XCTAssertTrue(vm.isGuestRebuilding(bot.id))
        XCTAssertEqual(fake.buildStarted.wait(timeout: .now() + 1), .success)
        vm.rebuildDockerGuest(botID: bot.id)
        XCTAssertEqual(fake.builds.count, 1, "a visible in-flight rebuild must reject duplicate clicks")
        fake.allowBuild.signal()

        let completed = await waitUntil(timeout: 2) { !vm.isGuestRebuilding(bot.id) }
        XCTAssertTrue(completed)
        XCTAssertEqual(
            fake.builds,
            [BotComputerGuestSpec.recipeURL(appSupport: context.appSupportDirectory, botID: bot.id)]
        )
        XCTAssertTrue(vm.isGuestRunning(bot.id))
        XCTAssertEqual(vm.guestScreenURL(for: bot.id)?.host, "127.0.0.1")
    }

    func test_rebuildDockerGuestFailureKeepsCurrentDesktopRunning() async throws {
        // WHY: a bad Dockerfile must report failure without taking down the
        // already-running desktop that the user can still repair.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        vm.presentGuestDesktop(botID: bot.id)
        let launched = await waitUntil(timeout: 2) { vm.isGuestRunning(bot.id) }
        XCTAssertTrue(launched)
        fake.startError = BotComputerGuestError.dockerUnavailable

        vm.rebuildDockerGuest(botID: bot.id)

        let completed = await waitUntil(timeout: 2) { !vm.isGuestRebuilding(bot.id) }
        XCTAssertTrue(completed)
        XCTAssertTrue(vm.isGuestRunning(bot.id), "the canonical desktop must survive a failed replacement")
        XCTAssertEqual(
            vm.errorMessage,
            "Could not rebuild the Linux desktop. The current desktop is still running."
        )
    }

    func test_guestCanvasStartingStateRendersOffscreen() throws {
        // WHY: the acknowledged launch state must produce a real macOS view,
        // not only compile-time copy that never reaches the rendered canvas.
        let canvas = BotComputerGuestCanvas(
            url: nil,
            running: false,
            rebuilding: false,
            launchState: .starting,
            startIdentifier: "test.desktop.start",
            rebuildIdentifier: "test.desktop.rebuild",
            stopIdentifier: "test.desktop.stop",
            screenIdentifier: "test.desktop.screen",
            onStart: {},
            onRebuild: {},
            onStop: {}
        )
        .frame(width: 360, height: 220)
        let hosting = NSHostingView(rootView: canvas)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("starting canvas must create an offscreen bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000)
        if let artifact = ProcessInfo.processInfo.environment["REMOTE_CODE_BOT_GUEST_ARTIFACT"] {
            try png.write(to: URL(fileURLWithPath: artifact), options: .atomic)
        }
    }

    func test_BotComputerDocker_typedCopyAndA11yReachDeskStudioAndDetachedSurfaces() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotComputerGuestScreenView.swift"), encoding: .utf8)
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("BotComputerDockerRecovery.matching"))
        XCTAssertTrue(source.contains("accessibilityAction"))
        XCTAssertTrue(bots.contains("BotComputerGuestCanvas("))
        XCTAssertTrue(bots.contains("bots.desk.desktop.window.start"))
        XCTAssertTrue(bots.contains("bots.studio.desktop"))
        XCTAssertTrue(bots.contains("bots.desk.desktop"))
        for recovery in [
            BotComputerDockerError.cliMissing,
            BotComputerDockerError.daemonUnavailable,
            BotComputerDockerError.probeTimedOut,
            BotComputerDockerError.provisioningFailed
        ] {
            let canvas = BotComputerGuestCanvas(
                url: nil,
                running: false,
                rebuilding: false,
                launchState: .failed(recovery.description),
                startIdentifier: "test.desktop.start",
                rebuildIdentifier: "test.desktop.rebuild",
                stopIdentifier: "test.desktop.stop",
                screenIdentifier: "test.desktop.screen",
                onStart: {},
                onRebuild: {},
                onStop: {}
            )
            .frame(width: 360, height: 220)
            let hosting = NSHostingView(rootView: canvas)
            hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
            let window = NSWindow(
                contentRect: hosting.bounds,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hosting
            window.layoutIfNeeded()
            XCTAssertEqual(
                BotComputerDockerRecovery.matching(recovery.description)?.accessibilityAction,
                recovery.recovery.accessibilityAction
            )
        }
    }

    func test_BotComputerDocker_stopDoesNotBlockMainActor() async throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        let gate = DispatchSemaphore(value: 0)
        fake.stopGate = gate
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        vm.presentGuestDesktop(botID: bot.id)
        let launched = await waitUntil(timeout: 10) { vm.isGuestRunning(bot.id) }
        XCTAssertTrue(launched)
        let started = Date()
        vm.stopDockerGuest(botID: bot.id)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        gate.signal()
    }

    func test_BotsWindow_secondStopInvokesTheForceTerminationPath() async throws {
        // WHY: the first Stop may durably cancel while provider teardown is
        // still stuck. A second Desk click must reach the same hard-stop path
        // as Agent App instead of becoming a no-op behind the UI latch.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .claude, defersCancellationForTesting: true)
        context.coordinator.replaceProvider(.claude, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        XCTAssertTrue(vm.send("block until force stop"))
        let started = await waitUntil(timeout: 5) { runner.requests.count == 1 }
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(runner.requests.first?.runId)

        vm.stopDeskRun()
        XCTAssertTrue(vm.isStopping)
        vm.stopDeskRun()
        let forced = await waitUntil(timeout: 5) {
            runner.cancellationRequestedRunIDs.filter { $0 == runID }.count >= 2
        }
        XCTAssertTrue(forced, "second Desk Stop must invoke provider force teardown")
        _ = runner.finish(runID: runID, status: .cancelled, reply: nil)
    }

    func test_botsNativeOffscreenCapturesActualRootStates() async throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["REMOTE_CODE_BOTS_CAPTURE_OUTPUT_DIRECTORY"] else {
            throw XCTSkip("Set REMOTE_CODE_BOTS_CAPTURE_OUTPUT_DIRECTORY to write capture artifacts")
        }
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["roster", "desk", "empty", "selected-row", "transcript", "scroll-control", "rail"]
        var manifest: [[String: Any]] = []
        var pngs: [String: Data] = [:]
        var fixtureWindows: [NSWindow] = []
        var fixtureAppSupports: [URL] = []
        defer {
            fixtureWindows.forEach { $0.close() }
            fixtureAppSupports.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        func allSubviews(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(allSubviews)
        }
        func accessibilityDescendants(of element: Any) -> [any NSAccessibilityProtocol] {
            guard let object = element as? any NSAccessibilityProtocol else { return [] }
            return [object] + (object.accessibilityChildren() ?? []).flatMap(accessibilityDescendants(of:))
        }
        func scrollToBottomButton(in hosting: NSView) -> (any NSAccessibilityProtocol)? {
            accessibilityDescendants(of: hosting).first {
                $0.accessibilityIdentifier() == "agent.timeline.scrollToBottom"
            }
        }
        for name in names {
            let context: AppContext
            let vm: BotsViewModel
            let bot: BotDefinition?
            let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("rc-bots-capture-\(UUID().uuidString)", isDirectory: true)
            fixtureAppSupports.append(appSupport)
            context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
            vm = BotsViewModel(context: context)
            if name == "empty" {
                bot = nil
            } else {
                let docker = RecordingDocker()
                vm.computerGuestService = BotComputerGuestService(
                    appSupport: context.appSupportDirectory,
                    docker: docker,
                    observeAttempts: 1,
                    observeDelay: 0
                )
                vm.dockerGuestReadyOverrideForTesting = true
                let created = try vm.create(name: "Piper", title: "Scout", provider: .claude)
                vm.openStudio(created)
                vm.studioExecutionDestination = .ownVM
                bot = try vm.saveStudio()
            }
            vm.reload()
            if name == "empty" {
                XCTAssertTrue(vm.bots.isEmpty, "empty capture must use an empty Bot database")
            } else {
                XCTAssertEqual(vm.bots.count, 1, "each capture state must own one Bot database")
            }
            if let bot {
                vm.openDesk(bot)
                if name == "desk" || name == "transcript" || name == "scroll-control" { _ = vm.createDeskThread() }
            }
            if name == "roster" || name == "empty" { vm.selectedBotID = nil }
            if name == "transcript" || name == "scroll-control" {
                let router = AppCommandRouter(context: context)
                context.router = router
                context.coordinator.replaceProvider(
                    .claude,
                    runner: FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: String(repeating: "Native fixture assistant transcript content. ", count: 200)))
                )
                router.rememberProviderSnapshotsForSend([
                    AgentProviderSnapshotFactory.snapshot(
                        provider: .claude,
                        models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                        binaryPath: "/usr/bin/true",
                        authenticated: true,
                        id: "claude"
                    ),
                ])
                router.preflightListedProviderSnapshotsForTesting = false
                vm.setDeskProvider(.claude)
                let threadID = try await linkDeskThreadByFirstSend(
                    vm,
                    context: context,
                    router: router,
                    providerAlreadyInstalled: true
                )
                let transcriptLoaded = await waitUntil(timeout: 15) {
                    guard let agent = vm.deskAgentVM, agent.selectedThreadId == threadID else { return false }
                    let hasReply = agent.timeline.turns.flatMap(\.items).contains {
                        $0.body.contains("Native fixture assistant transcript content.")
                    }
                    return hasReply
                        && agent.status == .completed
                        && !vm.deskSendInFlight
                        && context.coordinator.activeRunId(threadId: threadID) == nil
                }
                XCTAssertTrue(transcriptLoaded, "\(name) must finish loading the hosted Agent thread transcript")
                let transcriptText = vm.deskAgentVM?.timeline.turns.flatMap(\.items).map(\.body).joined(separator: "\\n") ?? ""
                XCTAssertTrue(transcriptText.contains("Native fixture assistant transcript content."), "\(name) capture needs real selected-thread transcript content")
                vm.isDeskSidePaneVisible = false
            }
            let rootView = BotsRootView(vm: vm)
            let sizingView = NSHostingView(rootView: rootView)
            let fittingSize = sizingView.fittingSize
            let captureWidth = max(1_600, ceil(fittingSize.width))
            let hosting = NSHostingView(rootView: rootView.frame(width: captureWidth, height: 760))
            hosting.frame = NSRect(x: 0, y: 0, width: captureWidth, height: 760)
            hosting.wantsLayer = true
            let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            fixtureWindows.append(window)
            window.orderBack(nil)
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            if name == "scroll-control" {
                let follower = try XCTUnwrap(allSubviews(of: hosting).first {
                    $0 is AgentChatTimelineScrollFollower.FollowerView
                } as? AgentChatTimelineScrollFollower.FollowerView, "scroll-control requires the actual timeline follower")
                let scrollView = try XCTUnwrap(follower.enclosingScrollView, "timeline follower must attach to its enclosing scroll view")
                let timelineRect = scrollView.convert(scrollView.bounds, to: hosting)
                let document = try XCTUnwrap(scrollView.documentView)
                XCTAssertGreaterThan(document.bounds.height, scrollView.contentView.bounds.height, "scroll-control transcript must extend beyond viewport")
                let bottom = ScrollBottomGeometry.maxScrollOriginY(
                    documentHeight: max(document.bounds.height, document.frame.height),
                    visibleHeight: scrollView.contentView.bounds.height,
                    isFlipped: document.isFlipped
                )
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                try await Task.sleep(nanoseconds: 100_000_000)
                let locationInWindow = scrollView.convert(
                    NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
                    to: nil
                )
                let locationOnScreen = window.convertPoint(toScreen: locationInWindow)
                let cgEvent = try XCTUnwrap(CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: 8,
                    wheel2: 0,
                    wheel3: 0
                ))
                cgEvent.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                cgEvent.location = CGPoint(x: locationOnScreen.x, y: locationOnScreen.y)
                cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(NSEvent.Phase.began.rawValue))
                cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(NSEvent.Phase([]).rawValue))
                let syntheticWheel = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
                let queuedWheel: NSEvent
                if NSApp.currentEvent !== syntheticWheel {
                    NSApp.postEvent(syntheticWheel, atStart: true)
                    queuedWheel = try XCTUnwrap(NSApp.nextEvent(
                        matching: .scrollWheel,
                        until: Date().addingTimeInterval(1),
                        inMode: .default,
                        dequeue: true
                    ), "posted synthetic wheel must be retrievable from the app event queue")
                } else {
                    queuedWheel = syntheticWheel
                }
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
                scrollView.scrollWheel(with: queuedWheel)
                try await Task.sleep(nanoseconds: 300_000_000)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
                try await Task.sleep(nanoseconds: 300_000_000)
                await Task.yield()
                window.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 10_000, "scroll-control screenshot must not be blank")
                pngs[name] = png
                let path = directory.appendingPathComponent("\(name).png")
                try png.write(to: path, options: .atomic)
                manifest.append(["state": "scroll-control-simulated-native-scroll", "event": "scrollWheel", "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "selectedBotID": vm.selectedBotID?.description as Any? ?? NSNull(), "screen": vm.screen.rawValue, "file": path.lastPathComponent])
                await Task.yield()
                let scrollButton = scrollToBottomButton(in: hosting)
                let beforeClickGap = ScrollBottomGeometry.gap(
                    documentHeight: max(document.bounds.height, document.frame.height),
                    visibleOriginY: scrollView.contentView.bounds.origin.y,
                    visibleHeight: scrollView.contentView.bounds.height,
                    isFlipped: document.isFlipped
                )
                XCTAssertGreaterThan(beforeClickGap, AgentChatTimelineScrollChrome.bottomRevealSlack, "viewport must be away from bottom before clicking scroll control")
                if let scrollButton {
                    XCTAssertTrue(scrollButton.accessibilityPerformPress(), "Scroll to latest message must support its real accessibility action")
                } else {
                    // The Desk's new-thread FAB sits under scroll-to-latest in
                    // the same corner, so the arrow is one 44pt slot higher.
                    let rise = AgentChatTimelineScrollChrome.scrollDownButtonBottomInset
                        + 44 + AgentChatTimelineScrollChrome.trailingAccessorySpacing + 22
                    let buttonCenter = NSPoint(
                        x: scrollView.bounds.maxX - 14 - 22,
                        y: scrollView.isFlipped ? scrollView.bounds.maxY - rise : scrollView.bounds.minY + rise
                    )
                    let location = scrollView.convert(buttonCenter, to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = try XCTUnwrap(NSEvent.mouseEvent(
                            with: type,
                            location: location,
                            modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber,
                            context: nil,
                            eventNumber: 1,
                            clickCount: 1,
                            pressure: type == .leftMouseDown ? 1 : 0
                        ))
                        window.sendEvent(event)
                    }
                }
                let returnedToBottom = await waitUntil(timeout: 2) {
                    ScrollBottomGeometry.gap(
                        documentHeight: max(document.bounds.height, document.frame.height),
                        visibleOriginY: scrollView.contentView.bounds.origin.y,
                        visibleHeight: scrollView.contentView.bounds.height,
                        isFlipped: document.isFlipped
                    ) <= AgentChatTimelineScrollChrome.bottomRevealSlack
                }
                XCTAssertTrue(returnedToBottom, "Scroll to latest message must return transcript to bottom")
                await Task.yield()
                window.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                let afterBitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: afterBitmap)
                let afterPNG = try XCTUnwrap(afterBitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(afterPNG.count, 10_000, "scroll-control after screenshot must not be blank")
                try afterPNG.write(to: directory.appendingPathComponent("scroll-control-after.png"), options: .atomic)
                manifest.append(["state": scrollButton == nil ? "scroll-control-native-window-click" : "scroll-control-ax-press", "event": scrollButton == nil ? "leftMouseDown+leftMouseUp" : "accessibilityPerformPress", "verification": "native viewport state; not AX-verified", "width": afterBitmap.pixelsWide, "height": afterBitmap.pixelsHigh, "selectedBotID": vm.selectedBotID?.description as Any? ?? NSNull(), "screen": vm.screen.rawValue, "file": "scroll-control-after.png"])
                let selectedThreadID = try XCTUnwrap(vm.deskAgentVM?.selectedThreadId)
                let previousDocumentHeight = max(document.bounds.height, document.frame.height)
                XCTAssertTrue(vm.send("Native follow after rejoin"))
                let appendedTurnCompleted = await waitUntil(timeout: 15) {
                    guard let agent = vm.deskAgentVM, agent.selectedThreadId == selectedThreadID else { return false }
                    let items = agent.timeline.turns.flatMap(\.items)
                    return items.contains { $0.body.contains("Native fixture assistant transcript content.") }
                        && agent.status == .completed
                        && !vm.deskSendInFlight
                        && context.coordinator.activeRunId(threadId: selectedThreadID) == nil
                        && items.filter { $0.body.contains("Native fixture assistant transcript content.") }.count >= 2
                }
                XCTAssertTrue(appendedTurnCompleted, "second harmless prompt must complete on the selected thread")
                let followedAppend = await waitUntil(timeout: 2) {
                    hosting.layoutSubtreeIfNeeded()
                    let height = max(document.bounds.height, document.frame.height)
                    return height > previousDocumentHeight
                        && ScrollBottomGeometry.gap(
                            documentHeight: height,
                            visibleOriginY: scrollView.contentView.bounds.origin.y,
                            visibleHeight: scrollView.contentView.bounds.height,
                            isFlipped: document.isFlipped
                        ) <= AgentChatTimelineScrollChrome.bottomRevealSlack
                }
                XCTAssertTrue(followedAppend, "new completed transcript content must remain followed without another click")
                await Task.yield()
                window.layoutIfNeeded()
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                let appendedBitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: appendedBitmap)
                let appendedPNG = try XCTUnwrap(appendedBitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(appendedPNG.count, 10_000, "post-append screenshot must not be blank")
                try appendedPNG.write(to: directory.appendingPathComponent("scroll-control-after-append.png"), options: .atomic)
                manifest.append(["state": "scroll-control-after-append", "width": appendedBitmap.pixelsWide, "height": appendedBitmap.pixelsHigh, "selectedBotID": vm.selectedBotID?.description as Any? ?? NSNull(), "screen": vm.screen.rawValue, "file": "scroll-control-after-append.png"])
            } else {
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 10_000, "\(name) screenshot must not be blank")
                pngs[name] = png
                let path = directory.appendingPathComponent("\(name).png")
                try png.write(to: path, options: .atomic)
                manifest.append(["state": name, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "selectedBotID": vm.selectedBotID?.description as Any? ?? NSNull(), "screen": vm.screen.rawValue, "file": path.lastPathComponent])
            }
            withExtendedLifetime(window) {}
        }
        for (lhs, rhs) in [("roster", "desk"), ("desk", "empty"), ("selected-row", "transcript"), ("transcript", "scroll-control"), ("rail", "selected-row")] {
            XCTAssertNotEqual(pngs[lhs], pngs[rhs], "\(lhs) and \(rhs) must show distinct native states")
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    func test_filesLocationBarRendersFullStudioWidthOffscreen() throws {
        // WHY: the modifier contract is also rendered through the real Studio
        // hierarchy so a passing source assertion cannot hide a broken view tree.
        let (_, vm, bot, _) = try makeDockerStudio()
        vm.setStudioFilesLocation(.botFiles, for: bot)
        vm.studioTab = .files
        let root = BotsRootView(vm: vm)
            .frame(width: 1_100, height: 760)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 1_100, height: 760)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        if let artifact = ProcessInfo.processInfo.environment["REMOTE_CODE_BOT_FILES_LAYOUT_ARTIFACT"] {
            try png.write(to: URL(fileURLWithPath: artifact), options: .atomic)
        }
    }

    func test_guestCanvasRunningControlsRenderOffscreen() throws {
        // WHY: Rebuild and Stop must materialize as macOS chrome, not only as
        // source copy that disappears under a conditional running branch.
        let canvas = BotComputerGuestCanvas(
            url: nil,
            running: true,
            rebuilding: false,
            launchState: .idle,
            startIdentifier: "test.desktop.start",
            rebuildIdentifier: "test.desktop.rebuild",
            stopIdentifier: "test.desktop.stop",
            screenIdentifier: "test.desktop.screen",
            onStart: {},
            onRebuild: {},
            onStop: {}
        )
        .frame(width: 640, height: 220)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: canvas)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 220)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000)
        if let artifact = ProcessInfo.processInfo.environment["REMOTE_CODE_BOT_GUEST_CONTROLS_ARTIFACT"] {
            try png.write(to: URL(fileURLWithPath: artifact), options: .atomic)
        }
    }

    func test_viewModelWiresBundledComputerGuestRecipe() throws {
        // WHY: recipeContext=nil left Studio unable to build the bundled
        // ComputerGuest image, so the Docker radio never enabled.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let wired = try XCTUnwrap(vm.computerGuestService?.recipeContextURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wired.appendingPathComponent("Dockerfile").path)
        )
        let dockerfile = try String(
            contentsOf: wired.appendingPathComponent("Dockerfile"),
            encoding: .utf8
        )
        XCTAssertTrue(dockerfile.lowercased().contains("debian"))
    }

    func test_thisMacRuntimesPersistWhenDockerIsUnavailable() throws {
        // WHY: this-Mac create/save/send must work with Docker forced off.
        // Docker-with-GUI Save/Send must be refused without a PNG.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.dockerGuestReadyOverrideForTesting = false
        vm.computerGuestService = nil
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .logicalExecutionSpace
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .logicalExecutionSpace)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("use the default browser"))

        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .botOwnedBrowser
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .botOwnedBrowser)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("use my own browser"))

        vm.openStudio(piper)
        vm.studioExecutionDestination = .ownVM
        XCTAssertThrowsError(try vm.saveStudio())
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .botOwnedBrowser)
        vm.desktopKindOverrideForTesting = .dockerDesktop
        XCTAssertFalse(vm.send("open the linux screen"))
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")
    }

    func test_saveStudioPersistsIdentityWhenPublishedDockerGuestIsNotReady() throws {
        // WHY: LinkedIn Controller already published Docker GUI. Save Bot on
        // Profile still threw notReady whenever the global proveReady probe
        // had not finished, so name/description/instructions never persisted.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.dockerGuestReadyOverrideForTesting = true
        vm.studioExecutionDestination = .ownVM
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)

        vm.dockerGuestReadyOverrideForTesting = false
        vm.computerGuestService = nil
        vm.studioDraft.name = "Piper Prime"
        vm.studioDraft.title = "Night scout"
        vm.studioDraft.description = "Identity only"
        vm.studioDraft.soul = "Do the job. Ask when blocked."
        let saved = try vm.saveStudio()
        XCTAssertEqual(saved.name, "Piper Prime")
        XCTAssertEqual(saved.title, "Night scout")
        XCTAssertEqual(saved.description, "Identity only")
        XCTAssertEqual(vm.selectedRevision?.soul, "Do the job. Ask when blocked.")
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)
        XCTAssertNil(vm.errorMessage)
    }

    func test_saveBotAlertKeepsStudioErrorCopy_becauseRawNotReadyMustNotSurface() throws {
        // WHY: Save Bot overwrote saveStudio's "Docker desktop is not ready."
        // with String(describing: BotComputerGuestError.notReady) → "notReady".
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.errorMessage = "Docker desktop is not ready."
        vm.presentAlertError(BotComputerGuestError.notReady)
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")

        vm.errorMessage = nil
        vm.presentAlertError(BotComputerGuestError.notReady)
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")
        XCTAssertNotEqual(vm.errorMessage, "notReady")

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("vm.presentAlertError(error)"))
        XCTAssertTrue(source.contains("bots.studio.save"))
    }

    func test_saveBotClearsAnOlderError_becauseTheStripIsNotModalAndWouldMaskThisSavesFailure() throws {
        // WHY: presentAlertError keeps a message that is already set, so the
        // copy saveStudio wrote survives. Under the modal alert that slot was
        // always empty when Save ran. The strip does not block the window, so
        // an older message can still be there: a failed save would show that
        // stale text instead of its own error, and a successful save would
        // leave it on screen.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.errorMessage = "Name is required."
        vm.presentAlertError(BotComputerGuestError.notReady)
        XCTAssertEqual(
            vm.errorMessage, "Name is required.",
            "the view model keeps the older message, so the Save action has to clear it first"
        )

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "Button(BotsChrome.Label.saveBot) {"))
        let end = try XCTUnwrap(source.range(
            of: ".accessibilityIdentifier(\"bots.studio.save\")",
            range: start.upperBound..<source.endIndex
        ))
        let save = String(source[start.lowerBound..<end.lowerBound])
        let clear = try XCTUnwrap(
            save.range(of: "vm.errorMessage = nil"),
            "Save must start from an empty error slot"
        )
        let attempt = try XCTUnwrap(save.range(of: "try vm.saveStudio()"))
        XCTAssertLessThan(clear.lowerBound, attempt.lowerBound)
    }

    func test_leftoverDedicatedLocalVMDoesNotBecomeDockerWhenGuestReady() throws {
        // WHY: leftover Dedicated local VM must stay leftover. A passing
        // probe must not rewrite it into Docker with GUI.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.dockerGuestReadyOverrideForTesting = true
        vm.studioDraft.desktopKind = .dedicatedLocalVM
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .logicalExecutionSpace)
        XCTAssertNotEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)
        XCTAssertFalse(
            BotDesktopKind.dedicatedLocalVM.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true),
                guestReady: true
            )
        )
    }

    func test_studioSavesBotOwnedAndDockerWhenReady() throws {
        // WHY: the owner must persist this Mac bot browser without Docker,
        // and Docker desktop only after the radio is enabled.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .botOwnedBrowser
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .botOwnedBrowser)

        vm.dockerGuestReadyOverrideForTesting = true
        vm.studioExecutionDestination = .ownVM
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)
    }

    func test_dockerDesktopSendFailsClosedWithoutGuestPNG() throws {
        // WHY: Codex advisor: published dockerDesktop must not compile/send
        // HID on this Mac when the guest cannot return a PNG.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.dockerGuestReadyOverrideForTesting = false
        vm.desktopKindOverrideForTesting = .dockerDesktop
        XCTAssertFalse(vm.send("open chrome"))
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")
        vm.desktopKindOverrideForTesting = nil
        vm.dockerGuestReadyOverrideForTesting = true
        XCTAssertTrue(vm.send("open chrome"))
    }

    func test_desktopLabelContainsNotIsolated_becauseP1aMustNotClaimAVM() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertTrue(
            vm.desktopHonestyLabel.lowercased().contains("not isolated"),
            "Studio must repeat the logical-space honesty label"
        )
        XCTAssertEqual(
            vm.desktopHonestyLabel,
            BotDesktopKind.logicalExecutionSpaceHonestyLabel
        )
        XCTAssertTrue(
            BotDesktopKind.logicalExecutionSpaceHonestyLabel.lowercased().contains("not isolated")
        )

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let settings = try String(contentsOf: sourceURL("Sources/AppShell/SettingsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("desktopHonestyLabel"))
        XCTAssertFalse(
            source.contains("private var studioSummary"),
            "Configuration summary is gone; it cannot repeat the Desktop honesty block"
        )
        XCTAssertTrue(source.contains("studioAvatarPane"))
        XCTAssertFalse(source.contains("studioRouteLabel"), "Studio must not publish a provider for a Bot")
        XCTAssertFalse(
            source.contains("Guest not running"),
            "Studio must not advertise a Dedicated local VM guest control"
        )
        XCTAssertFalse(
            source.contains("Managed remote Mac Desktop"),
            "Studio must not advertise Managed remote Mac"
        )
        XCTAssertFalse(source.contains("bots.studio.desktop.remote"))
        XCTAssertFalse(source.contains("bots.studio.desktop.vm"))
        XCTAssertFalse(source.contains("Dedicated local VM Desktop"))
        XCTAssertFalse(source.contains("Isolated / Dedicated VM"))
        XCTAssertFalse(source.contains("Isolated network"))
        XCTAssertFalse(source.contains("Take over"))
        XCTAssertFalse(source.contains("bots.desktop.vm.start"))
        XCTAssertFalse(source.contains("bots.desktop.vm.stop"))
        XCTAssertFalse(source.contains("bots.desktop.vm.identity"))
        XCTAssertFalse(settings.contains("settings.bots.desktopVM.toggle"))
        XCTAssertFalse(settings.contains("Dedicated local VM Desktop"))
        XCTAssertFalse(settings.contains("setBotsDesktopVMEnabled"))
        XCTAssertFalse(
            source.contains("Running • macOS VM"),
            "Fleet Home must not paint the concept's fake dedicated VM"
        )
        XCTAssertFalse(
            source.contains("Active now in macOS VM"),
            "select/persist must not claim a running guest"
        )
        XCTAssertFalse(
            source.contains("Dedicated Desktop"),
            "P1a has no dedicated Desktop; the concept screenshot is not the contract"
        )
        XCTAssertFalse(
            source.contains("bots.home.desktop.honesty"),
            "Home desktop honesty is gone with the Home screen"
        )
        XCTAssertTrue(source.contains("bots.studio.desktop.honesty") || source.contains("bots.desk.desktop"))
        // Studio mounts the shared Schedule Tasks screen; its editor carries the caption.
        let schedules = try String(contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(schedules.contains("BotRoutineCopy.testRunHonestyCaption"))
        XCTAssertFalse(
            source.contains("isAutonomyActive ? \"active\""),
            "autonomy-on must not imply app-closed execution"
        )
    }

    func test_attentionItemAppearsAfterSendThatNeedsTheUser() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Please look at the failing test")

        let attention = try context.botStore.listAttention()
        XCTAssertEqual(attention.count, 1, "a send that cannot start a provider run must land in Attention")
        XCTAssertEqual(attention.first?.botID, bot.id)
        XCTAssertEqual(attention.first?.kind, .blocked)
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, 1)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
        XCTAssertEqual(vm.deskMessages.last?.text, BotsViewModel.assistantPlaceholder)
        XCTAssertFalse(vm.lastSendStartedProviderRun)
    }

    func test_followThroughLeavesWorkingWhenRunCompletes_becauseTheDeskMustShowAResult() {
        // WHY: Grok Bot keeps the user in the same conversation until work
        // finishes; a started run that never leaves "Working…" is not a teammate.
        XCTAssertEqual(BotsDeskFollowThrough.conversationState(for: .running), .working)
        XCTAssertEqual(BotsDeskFollowThrough.conversationState(for: .completed), .unreadActivity)
        XCTAssertEqual(BotsDeskFollowThrough.conversationState(for: .failed), .needsAttention)
        XCTAssertEqual(
            BotsDeskFollowThrough.conversationState(for: .completed, viewingDesk: true),
            .none,
            "the open Desk is already being read; Unread is for the rest of the fleet"
        )
        XCTAssertEqual(
            BotsDeskFollowThrough.conversationState(for: .completed, viewingDesk: false),
            .unreadActivity
        )
        XCTAssertNil(BotsDeskFollowThrough.attentionKind(for: .completed))
        XCTAssertEqual(BotsDeskFollowThrough.attentionKind(for: .failed), .blocked)
        XCTAssertEqual(
            BotsDeskFollowThrough.conversationState(for: .cancelled, terminalReason: "userStop"),
            .none
        )
        XCTAssertNil(BotsDeskFollowThrough.attentionKind(for: .cancelled, terminalReason: "userStop"))
        XCTAssertEqual(
            BotsDeskFollowThrough.conversationState(for: .cancelled, terminalReason: "providerCancelled"),
            .needsAttention
        )
        XCTAssertEqual(
            BotsDeskFollowThrough.attentionKind(for: .cancelled, terminalReason: "providerCancelled"),
            .blocked
        )
        XCTAssertEqual(
            BotsDeskFollowThrough.conversationState(for: .cancelled),
            .needsAttention,
            "a cancelled run without a durable reason stays actionable"
        )
        XCTAssertTrue(BotsDeskFollowThrough.isTerminal(.completed))
        XCTAssertFalse(BotsDeskFollowThrough.isTerminal(.running))
    }

    func test_BotsWindowAttention_userStopWritesNoItemAndProviderCancelledStaysActionable() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        let conversation = BotConversation(botID: bot.id, title: "Desk")
        try context.botStore.upsertConversation(conversation)
        vm.reload()
        vm.openDesk(bot)
        vm.applyFollowThroughForTests(
            bot: bot,
            conversation: conversation,
            status: .cancelled,
            terminalReason: "userStop"
        )
        XCTAssertEqual(vm.attentionState(for: bot), .none)
        XCTAssertTrue(try context.botStore.listAttention().isEmpty)

        vm.applyFollowThroughForTests(
            bot: bot,
            conversation: conversation,
            status: .cancelled,
            terminalReason: "providerCancelled"
        )
        XCTAssertEqual(vm.attentionState(for: bot), .needsAttention)
        let items = try context.botStore.listAttention()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .blocked)
        XCTAssertEqual(items.first?.title, "Bot run interrupted")
    }

    func test_rosterPreviewPrefersLastDeskLine_becauseGrokShowsTheLastLine() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Say hello in one short sentence.")
        XCTAssertEqual(vm.rosterPreview(for: bot), BotsViewModel.assistantPlaceholder)
    }

    func test_openDeskHidesUnreadOnTheViewedBot_becauseYouAreAlreadyReadingIt() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", unread: true, attentionState: .unreadActivity)
        )
        vm.reload()
        XCTAssertEqual(vm.attentionState(for: bot), .unreadActivity)
        vm.openDesk(bot)
        XCTAssertEqual(vm.attentionState(for: bot), .none)
    }

    func test_viewingDeskHidesNeedsYouFromSiblingFailedRun_becauseTheOpenThreadDoesNotNeedYou() throws {
        // WHY: Ceo kept Needs you after a later thread completed. A leftover
        // Grok ACP crash on another conversation is not a live ask.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Ceo", title: "Chief of all bots", provider: .grok)
        let failed = BotConversation(
            botID: bot.id,
            title: "Melhore o oliver",
            attentionState: .needsAttention,
            updatedAt: Date().addingTimeInterval(-10_800)
        )
        let current = BotConversation(
            botID: bot.id,
            title: "Melhore o oliver",
            attentionState: .none,
            updatedAt: Date()
        )
        try context.botStore.upsertConversation(failed)
        try context.botStore.upsertConversation(current)
        try context.botStore.upsertAttention(
            BotAttentionItem(
                botID: bot.id,
                conversationID: failed.id,
                kind: .blocked,
                title: "Run needs you",
                detail: "Grok ACP process exited (exit 143)"
            )
        )
        vm.reload()
        vm.openDesk(bot)
        vm.selectDeskThread(current.id)
        XCTAssertEqual(vm.selectedConversation?.id, current.id)
        XCTAssertEqual(
            vm.attentionState(for: bot),
            .none,
            "the open completed thread must not inherit Needs you from a sibling failed run"
        )
        XCTAssertEqual(
            vm.conversations.first(where: { $0.id == failed.id })?.attentionState,
            .needsAttention,
            "the failed thread remains marked so the rail can still surface it"
        )
    }

    func test_viewingDeskKeepsNeedsYouWhenTheOpenThreadFailed() throws {
        // WHY: hiding sibling leftovers must not hide a failed run the user
        // is actually looking at.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Ceo", title: "Chief of all bots", provider: .grok)
        let failed = BotConversation(
            botID: bot.id,
            title: "Melhore o oliver",
            attentionState: .needsAttention
        )
        let current = BotConversation(
            botID: bot.id,
            title: "Melhore o oliver later",
            attentionState: .none,
            updatedAt: Date().addingTimeInterval(60)
        )
        try context.botStore.upsertConversation(failed)
        try context.botStore.upsertConversation(current)
        try context.botStore.upsertAttention(
            BotAttentionItem(
                botID: bot.id,
                conversationID: failed.id,
                kind: .blocked,
                title: "Run needs you",
                detail: "Grok ACP process exited (exit 143)"
            )
        )
        vm.reload()
        vm.openDesk(bot)
        vm.selectDeskThread(failed.id)
        XCTAssertEqual(vm.attentionState(for: bot), .needsAttention)
    }

    func test_viewingDeskKeepsNeedsYouForOpenApproval_becauseTheBotStillNeedsYou() throws {
        // WHY: a live approval is an actual ask. Viewing a later completed
        // thread must not swallow that inbox row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Ceo", title: "Chief of all bots", provider: .grok)
        let failed = BotConversation(
            botID: bot.id,
            title: "Melhore o oliver",
            attentionState: .needsAttention,
            updatedAt: Date().addingTimeInterval(-10_800)
        )
        let current = BotConversation(
            botID: bot.id,
            title: "Melhore o oliver",
            attentionState: .none,
            updatedAt: Date()
        )
        try context.botStore.upsertConversation(failed)
        try context.botStore.upsertConversation(current)
        try context.botStore.upsertAttention(
            BotAttentionItem(
                botID: bot.id,
                conversationID: failed.id,
                kind: .blocked,
                title: "Run needs you",
                detail: "Grok ACP process exited (exit 143)"
            )
        )
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: bot.id, kind: .approval, title: "Approve vendor brief")
        )
        vm.reload()
        vm.openDesk(bot)
        vm.selectDeskThread(current.id)
        XCTAssertEqual(vm.attentionState(for: bot), .needsAttention)
    }

    func test_reopeningDeskDoesNotRefetchRosterRevisions_becauseDestMustNotRereadEveryChip() throws {
        // WHY: dest paint called getRevision for every roster chip on every
        // click. Revisions are immutable by id; warm dest must reuse them.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .grok)
        vm.openDesk(piper)
        vm.setDeskProvider(.claude)
        vm.createDeskThread()
        vm.openDesk(quinn)
        vm.setDeskProvider(.grok)
        vm.createDeskThread()
        vm.openDesk(piper)
        for bot in vm.fleet {
            _ = vm.providerLabel(for: bot)
            _ = vm.modelLabel(for: bot)
        }
        let afterFirstPaint = vm.rosterRevisionFetchCountForTesting
        XCTAssertGreaterThan(afterFirstPaint, 0, "first dest paint must read revisions once")
        XCTAssertEqual(vm.providerLabel(for: piper), "Claude")
        XCTAssertEqual(vm.providerLabel(for: quinn), "Grok")
        vm.openDesk(quinn)
        for bot in vm.fleet {
            _ = vm.providerLabel(for: bot)
            _ = vm.modelLabel(for: bot)
        }
        XCTAssertEqual(
            vm.rosterRevisionFetchCountForTesting,
            afterFirstPaint,
            "switching dest must not reread every teammate revision"
        )
        vm.openDesk(piper)
        for bot in vm.fleet {
            _ = vm.providerLabel(for: bot)
            _ = vm.modelLabel(for: bot)
        }
        XCTAssertEqual(vm.rosterRevisionFetchCountForTesting, afterFirstPaint)
    }

    func test_saveStudioKeepsPublishedRoute_becauseProviderRoutingLivesInDesk() throws {
        // WHY: Profile has no provider field. Saving identity/brain must not
        // replace the route the user selected on the Desk thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        vm.openDesk(bot)
        vm.setDeskProvider(.grok)
        vm.createDeskThread()
        XCTAssertEqual(vm.providerLabel(for: bot), "Grok")
        let afterOpen = vm.rosterRevisionFetchCountForTesting
        vm.beginEdit(bot)
        _ = try vm.saveStudio()
        let saved = try XCTUnwrap(vm.selectedBot)
        XCTAssertEqual(vm.providerLabel(for: saved), "Grok")
        let revisionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(try XCTUnwrap(vm.selectedRevision))
            ) as? [String: Any]
        )
        XCTAssertNil(revisionObject["provider"])
        XCTAssertNil(revisionObject["model"])
        XCTAssertEqual(
            vm.rosterRevisionFetchCountForTesting,
            afterOpen,
            "Save dest must not reread the revision it just published"
        )
    }

    func test_reopeningDeskDoesNotRereadMarkRead_becauseRosterSwitchMustNotListConversations() throws {
        // WHY: openDesk listed conversations and attention on every roster
        // click even when that teammate was already read. Warm dest must
        // skip the store; first dest still marks unread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterPiper = vm.deskMarkReadStoreCountForTesting
        XCTAssertGreaterThan(afterPiper, 0, "first Desk open must mark-read from the store")
        vm.openDesk(quinn)
        let afterQuinn = vm.deskMarkReadStoreCountForTesting
        XCTAssertEqual(afterQuinn, afterPiper + 1, "first Quinn dest must mark-read from the store")
        vm.openDesk(piper)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.deskMarkReadStoreCountForTesting,
            afterQuinn,
            "reopening a read Piper must not list conversations again"
        )
    }

    func test_openDeskDoesNotListInbox_becauseMarkReadDestMustNotRereadQueue() throws {
        // WHY: Mark-read dest used to listAttention after dest already
        // dested Chat. Dest already has dest inbox.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let piperConversation = BotConversation(botID: piper.id, title: "From Piper")
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(quinn)
        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.openDesk(piper)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "mark-read dest must not reread the inbox"
        )
        XCTAssertEqual(vm.attentionState(for: piper), .none)
    }

    func test_openDeskStillMarksUnread_becauseStaleUnreadMustNotLookCurrent() throws {
        // WHY: cache-first dest is honest only when a completed turn on a
        // background teammate still clears unread when that Desk opens.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let piperConversation = BotConversation(botID: piper.id, title: "From Piper")
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(quinn)
        let afterSwitch = vm.deskMarkReadStoreCountForTesting
        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)
        XCTAssertEqual(vm.attentionState(for: piper), .unreadActivity)
        vm.openDesk(piper)
        XCTAssertEqual(
            vm.deskMarkReadStoreCountForTesting,
            afterSwitch + 1,
            "dest must reread mark-read when unread arrived in the background"
        )
        XCTAssertEqual(vm.attentionState(for: piper), .none)
        XCTAssertFalse(try XCTUnwrap(context.botStore.listConversations(botID: piper.id).first).unread)
    }

    func test_openDeskDoesNotReloadFleet_becauseRosterSwitchMustNotScanEveryTeammate() throws {
        // WHY: openDesk used to reloadFleet (every teammate's conversations
        // and recent messages) before Chat could paint. Mark-read is this
        // bot only; hide/pin/delete still reload the fleet.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let afterCreate = vm.fleetReloadCountForTesting
        XCTAssertGreaterThan(afterCreate, 0)
        vm.openDesk(piper)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterCreate,
            "opening Piper must not rescan the fleet"
        )
        vm.openDesk(quinn)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterCreate,
            "switching to Quinn must not rescan the fleet"
        )
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_deferredDetachedDeskCompletesExactOpenEffects_onNextMainTurn() async throws {
        // WHY: detached windows used to stop after their deferred reload, so
        // identity, mark-read, persisted selection, and Docker presentation
        // could all be skipped even though the requested Desk was visible.
        let (context, owner, piper, _) = try makeDockerStudio()
        let quinn = try owner.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let unread = BotConversation(
            botID: piper.id,
            title: "Unread",
            unread: true,
            attentionState: .unreadActivity
        )
        try context.botStore.upsertConversation(unread)

        let detached = BotsViewModel(context: context, loadImmediately: false)
        detached.enableNavigationFirstFrameDeferral()
        detached.prepareDetachedDesk(botID: piper.id)
        XCTAssertEqual(detached.selectedBotID, piper.id, "first paint must already belong to Piper")

        _ = try context.botStore.renameHandle(id: piper.id, handle: "piper-fresh")
        UserDefaults.standard.set(
            quinn.id.value.uuidString.lowercased(),
            forKey: "bots.selectedBotID"
        )
        detached.desktopKindOverrideForTesting = .dockerDesktop
        detached.dockerGuestReadyOverrideForTesting = false
        detached.scheduleFreshnessPass()
        await detached.waitForNavigationFreshnessForTesting()

        XCTAssertEqual(detached.selectedBotID, piper.id)
        XCTAssertEqual(detached.selectedBot?.handle, "piper-fresh", "deferred identity must be fresh")
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "bots.selectedBotID"),
            piper.id.value.uuidString.lowercased(),
            "the exact detached destination must win persisted selection"
        )
        XCTAssertFalse(try XCTUnwrap(
            context.botStore.conversation(id: unread.id)
        ).unread)
        XCTAssertEqual(
            detached.guestLaunchState(for: piper.id),
            .failed(BotComputerDockerError.cliMissing.description),
            "the original openDesk Docker presentation effect must still run"
        )
    }

    func test_deferredDeskRaceKeepsNewestBot_andOldTaskCannotClearItsHandle() async throws {
        // WHY: a cancelled freshness task could resume and nil the replacement
        // handle. Rapid Piper -> Quinn selection then skipped Quinn's effects
        // or briefly restored Piper's transcript.
        let context = try makeContext()
        let owner = BotsViewModel(context: context)
        let piper = try owner.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try owner.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let piperUnread = BotConversation(
            botID: piper.id,
            title: "Piper unread",
            unread: true,
            attentionState: .unreadActivity
        )
        try context.botStore.upsertConversation(piperUnread)
        let quinnUnread = BotConversation(
            botID: quinn.id,
            title: "Quinn unread",
            unread: true,
            attentionState: .unreadActivity
        )
        try context.botStore.upsertConversation(quinnUnread)

        let deferred = BotsViewModel(context: context, loadImmediately: false)
        deferred.enableNavigationFirstFrameDeferral()
        deferred.openDesk(piper)
        deferred.openDesk(quinn)
        await deferred.waitForNavigationFreshnessForTesting()

        XCTAssertEqual(deferred.selectedBotID, quinn.id)
        XCTAssertTrue(deferred.conversations.allSatisfy { $0.botID == quinn.id })
        XCTAssertTrue(try XCTUnwrap(
            context.botStore.conversation(id: piperUnread.id)
        ).unread, "the cancelled Piper task must have no mark-read side effect")
        XCTAssertFalse(try XCTUnwrap(
            context.botStore.conversation(id: quinnUnread.id)
        ).unread, "the newest Quinn task must complete its exact open effects")
    }

    func test_studioDoesNotHideUnread_becauseOnlyTheOpenDeskIsBeingRead() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", unread: true, attentionState: .unreadActivity)
        )
        vm.reload()
        vm.beginEdit(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.attentionState(for: bot), .unreadActivity)
    }

    func test_markingDeskReadDoesNotRewriteActivityTimestamp() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        try context.botStore.upsertConversation(
            BotConversation(
                botID: bot.id,
                title: "Standup",
                unread: true,
                attentionState: .unreadActivity,
                createdAt: stamped,
                updatedAt: stamped
            )
        )
        vm.openDesk(bot)
        let stored = try XCTUnwrap(context.botStore.listConversations(botID: bot.id).first)
        XCTAssertEqual(stored.updatedAt, stamped)
        XCTAssertFalse(stored.unread)
    }

    func test_followThroughOnBackgroundBotDoesNotOverwriteOpenDesk() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let piperConversation = BotConversation(botID: piper.id, title: "From Piper")
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(quinn)
        let quinnMessages = vm.deskMessages

        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)

        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertEqual(vm.deskMessages, quinnMessages)
        XCTAssertEqual(
            try context.botStore.listConversations(botID: piper.id).first?.attentionState,
            .unreadActivity
        )
        XCTAssertEqual(vm.attentionState(for: piper), .unreadActivity)
        XCTAssertEqual(vm.attentionState(for: quinn), .none)
    }

    func test_deskIdentityExposesJobProviderModelAndFullAccess() throws {
        // WHY: Desk is the live teammate, not a generic chat. The header must
        // show who is talking, their job, the real route, and the default Full Access mode.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).name, "Piper")
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).handle, "piper")
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).title, "Scout")
        XCTAssertEqual(vm.permissionLabel(for: bot), "Full access")
        XCTAssertEqual(vm.desktopHonestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)
    }

    func test_petOpenBotsDesk_destsThatBotsDesk() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        defer { controller.window.orderOut(nil) }
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(try router.openBotsDesk(botID: piper.id))
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertFalse(try router.openBotsDesk(botID: BotID()))
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_petOpenBotsDeskWithoutDestinationDoesNotClaimSuccess() throws {
        // WHY: Pet acknowledgement follows this boolean. Returning true when
        // no MainWindowController exists would clear durable Bot attention
        // without proving that the Bot Desk is visible to the user.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)

        XCTAssertFalse(try router.openBotsDesk(botID: piper.id))
    }

    func test_petProjectsDestAttention_andHidesDisabledBots() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let muted = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude, notificationsEnabled: false)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        let conversation = try XCTUnwrap(vm.selectedConversation)
        vm.openDesk(muted)
        vm.applyFollowThroughForTests(bot: piper, conversation: conversation, status: .completed)
        let dest = PetDestAttentionSnapshot(
            bots: try context.botStore.list(),
            conversations: try context.botStore.listConversations(
                attentionStates: [.unreadActivity, .needsAttention]
            ),
            attention: try context.botStore.listAttention(),
            linkedThreadIDs: try context.botStore.listLinkedAgentThreadIDs()
        )
        let items = PetAttentionStore.projectDest(dest)
        XCTAssertTrue(items.contains { $0.route == .botsDesk(botID: piper.id) })
        XCTAssertFalse(items.contains { $0.route == .botsDesk(botID: muted.id) })
        XCTAssertFalse(items.contains { $0.title.localizedCaseInsensitiveContains("from piper") })
    }

    func test_petMarkReadFollowsDestLedger() throws {
        let context = try makeContext()
        let store = PetAttentionStore(
            threadRepository: context.threadRepo,
            callbackRepository: context.providerPendingCallbackRepo,
            notificationRepository: NotificationRepository(db: context.db),
            destLookup: {
                PetDestAttentionSnapshot(
                    bots: try context.botStore.list(),
                    conversations: try context.botStore.listConversations(
                        attentionStates: [.unreadActivity, .needsAttention]
                    ),
                    attention: try context.botStore.listAttention(),
                    linkedThreadIDs: try context.botStore.listLinkedAgentThreadIDs()
                )
            },
            markBotConversationViewed: { id in
                guard var conversation = try context.botStore.conversation(id: id) else { return }
                conversation.unread = false
                conversation.attentionState = .none
                try context.botStore.upsertConversation(conversation)
            }
        )
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        // Dest unread is the dest ledger. send() without a router writes a
        // leftover dest question and would hide this completed row.
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Brief", unread: true, attentionState: .unreadActivity)
        )
        let item = try XCTUnwrap(try store.refresh().items.first { $0.route == .botsDesk(botID: piper.id) })
        XCTAssertEqual(item.classification, .completed)
        XCTAssertEqual(try store.openAndMarkRead(itemID: item.id) { _ in true }, .marked)
        XCTAssertTrue(try store.refresh().items.filter { $0.route == .botsDesk(botID: piper.id) }.isEmpty)
    }

    func test_shortDeskTimelineUsesSharedEagerHistoryLayoutToKeepScrollBounded() throws {
        // WHY: packaged Claude Bot E2E hit an unbounded LazyVStack/self-sizing
        // text AttributeGraph loop on a short Desk timeline. Agent App already
        // keeps <=8 history rows eager; Desk must use that same policy and
        // compute the timeline once per paint instead of always-Lazy placement.
        XCTAssertFalse(
            AgentChatTimelineHistoryLayout.usesLazyLayout(entryCount: 6),
            "the short-timeline reproduction must stay mounted while scrolling"
        )
        XCTAssertFalse(
            AgentChatTimelineHistoryLayout.usesLazyLayout(
                entryCount: AgentChatTimelineHistoryLayout.eagerEntryLimit
            )
        )
        XCTAssertFalse(
            AgentChatTimelineHistoryLayout.usesLazyLayout(entryCount: 9),
            "pid 36908 hung restoring a long thread in LazyVStack; Desk history must stay eager"
        )
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("AgentAppView("), "Desk must reuse Agent App, not fork its transcript")
        XCTAssertTrue(bots.contains("showsThreadRail: false"), "Desk embeds Agent App with the thread rail hidden")
    }

    func test_deskTimelineKeepsCurrentLiveTurnOutsideLazyHistory() {
        // WHY: the real Grok reproduction had more than eight transcript rows.
        // Putting the mutating live turn inside LazyVStack caused an AttributeGraph
        // placement loop that starved MainActor and timed out host MCP commands.
        let history: [BotDeskTimelineItem] = (0..<9).map { index in
            .message(BotDeskMessage(
                role: .assistant,
                text: "history-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        let live = AssistantTurnSnapshot(
            turnId: "current-live",
            items: [AssistantItem(
                id: "tool-live",
                turnId: "current-live",
                type: .mcpToolCall,
                state: .streaming,
                startedAtMs: 10_000
            )],
            finished: false
        )
        let afterLive = BotDeskTimelineItem.message(BotDeskMessage(
            role: .assistant,
            text: "peer reply after work",
            createdAt: Date(timeIntervalSince1970: 11)
        ))
        let items = history + [.liveTurn(live, hideAssistantOutput: false), afterLive]

        let split = BotsDeskFollowThrough.splitLiveTail(
            items,
            latestLiveTurnID: live.turnId
        )

        XCTAssertEqual(split.history.map(\.id), history.map(\.id))
        XCTAssertEqual(
            split.liveTail.map(\.id),
            ["turn-current-live", afterLive.id],
            "everything from the current turn onward must remain eager and chronological"
        )
        XCTAssertEqual(
            (split.history + split.liveTail).map(\.id),
            items.map(\.id),
            "splitting layout ownership must not change transcript order"
        )
        XCTAssertFalse(
            AgentChatTimelineHistoryLayout.usesLazyLayout(entryCount: split.history.count),
            "stable history must stay eager; LazyVStack placement of NSTextView rows hangs"
        )
    }

    func test_deskTimelineUsesSharedAgentAppScrollContainer_becauseChatMustFollowTheSamePin() throws {
        // WHY: Desk used a plain ScrollView. Agent App pin/FAB/BOTTOM lived
        // only in AgentAppSurface, so send did not auto-scroll. Same control
        // must be one shared container.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("AgentAppView("), "Desk must reuse Agent App, not fork its transcript")
        XCTAssertTrue(bots.contains("showsThreadRail: false"), "Desk embeds Agent App with the thread rail hidden")
        let agent = try String(contentsOf: sourceURL("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        XCTAssertTrue(agent.contains("AgentChatTimelineScrollContainer("))
        XCTAssertFalse(agent.contains("private struct TimelineScrollFollower"))
        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatTimelineChrome.swift"), encoding: .utf8)
        XCTAssertTrue(chrome.contains("struct AgentChatTimelineScrollFollower"))
        XCTAssertTrue(chrome.contains("Scroll to latest message"))
    }

    func test_deskTimelineUsesUserAssistantLabelsAndTimestamps() {
        // WHY: Grok Desk is a conversation log. A bubble without a time or
        // speaker turns the teammate into a generic agent transcript.
        let userAt = Date(timeIntervalSince1970: 1_700_000_000)
        let assistantAt = Date(timeIntervalSince1970: 1_700_000_030)
        let items = BotsDeskFollowThrough.timeline(
            messages: [
                BotDeskMessage(role: .user, text: "Summarize overnight", createdAt: userAt),
                BotDeskMessage(role: .assistant, text: "Three failing tests remain.", createdAt: assistantAt),
            ],
            workLog: []
        )
        XCTAssertEqual(items.count, 2)
        guard case .message(let user) = items[0] else {
            return XCTFail("first row must be the user line")
        }
        guard case .message(let assistant) = items[1] else {
            return XCTFail("second row must be the assistant line")
        }
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(user.createdAt, userAt)
        XCTAssertEqual(assistant.createdAt, assistantAt)
        XCTAssertEqual(
            AgentChatTranscriptChrome.relativeTimestamp(userAt, now: userAt),
            "just now",
            "Desk timestamps must use the Agent App 'just now' window"
        )
    }

    func test_deskWorkLogAppearsOnlyWhenALinkedRunExists() {
        // WHY: work-log rows are the linked provider turn. Inventing Desktop
        // clicks or showing a row with no run would fake computer-use.
        let started = Date(timeIntervalSince1970: 1_700_000_010)
        let user = BotDeskMessage(
            role: .user,
            text: "Summarize overnight",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let assistant = BotDeskMessage(
            role: .assistant,
            text: "Three failing tests remain.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        )
        XCTAssertTrue(
            BotsDeskFollowThrough.timeline(messages: [user, assistant], workLog: []).allSatisfy {
                if case .workLog = $0 { return false }
                return true
            }
        )
        let run = AgentRun(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: started
        )
        let withRun = BotsDeskFollowThrough.timeline(
            messages: [user, assistant],
            workLog: BotsDeskFollowThrough.workLogRows(for: run)
        )
        XCTAssertEqual(withRun.count, 3)
        guard case .workLog(let row) = withRun[1] else {
            return XCTFail("linked run must insert a work-log between You and the assistant")
        }
        XCTAssertEqual(row.title, "\(AgentPermissionMode.supervised.displayName) run")
        XCTAssertEqual(
            BotsDeskFollowThrough.workLogRow(for: run, mode: .fullAccess).title,
            "\(AgentPermissionMode.fullAccess.displayName) run"
        )
        XCTAssertEqual(row.detail, "Claude · opus")
        XCTAssertEqual(row.statusLabel, "Working")
        XCTAssertEqual(BotsDeskFollowThrough.workLogStatusLabel(for: .completed), "Done")
        XCTAssertTrue(BotsDeskFollowThrough.workLogRows(for: nil).isEmpty)
    }

    func test_openDeskRestoresTimelineAndWorkLogFromLinkedRun_becauseReopenMustNotLoseTheTurn() throws {
        // WHY: closing and reopening RemoteCode must keep the Desk conversation
        // and the honest work-log for the linked run — not an empty chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus", permissionMode: .supervised)
        try context.threadRepo.upsert(thread)
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_040)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: finishedAt
        )
        try context.runRepo.upsert(run)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "You are Piper — Scout.\n\nUser request:\n\nSummarize overnight",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: "Three failing tests remain.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        ))
        try context.botStore.upsertConversation(
            BotConversation(
                botID: bot.id,
                title: "Summarize overnight",
                linkedAgentThreadID: thread.id
            )
        )

        vm.openDesk(bot)
        XCTAssertEqual(vm.deskMessages.map(\.role), [.user, .assistant])
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(vm.deskMessages.last?.text, "Three failing tests remain.")
        XCTAssertEqual(vm.deskWorkLog.count, 1)
        XCTAssertEqual(vm.deskWorkLog.first?.statusLabel, "Done")
        XCTAssertEqual(vm.deskWorkLog.first?.detail, "Claude · opus")
        XCTAssertEqual(vm.deskWorkLog.first?.runID, run.id)
        XCTAssertEqual(vm.deskTimeline.count, 3)

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(bot)
        XCTAssertEqual(reopened.deskMessages.map(\.text), vm.deskMessages.map(\.text))
        XCTAssertEqual(reopened.deskWorkLog.map(\.runID), [run.id])
        XCTAssertEqual(reopened.deskWorkLog.first?.statusLabel, "Done")

        let context2 = try AppContext(channel: .debug, appSupportOverride: directory)
        let vm2 = BotsViewModel(context: context2)
        let listed = try XCTUnwrap(vm2.fleet.first(where: { $0.id == bot.id }))
        vm2.openDesk(listed)
        XCTAssertEqual(vm2.deskMessages.last?.text, "Three failing tests remain.")
        XCTAssertEqual(vm2.deskWorkLog.first?.statusLabel, "Done")
        XCTAssertEqual(vm2.permissionLabel(for: listed), "Supervised")
    }

    func test_followThroughWorkLogStaysOnOwningConversation() throws {
        // WHY: a finished run on Piper must not paint Quinn's open Desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let thread = AgentThread(title: "From Piper", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            finishedAt: Date()
        )
        try context.runRepo.upsert(run)
        var piperConversation = BotConversation(
            botID: piper.id,
            title: "From Piper",
            linkedAgentThreadID: thread.id
        )
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(quinn)
        XCTAssertTrue(vm.deskWorkLog.isEmpty)

        piperConversation.linkedAgentThreadID = thread.id
        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)

        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertTrue(vm.deskWorkLog.isEmpty, "Quinn's Desk must not inherit Piper's work-log")
        vm.openDesk(piper)
        XCTAssertEqual(vm.deskWorkLog.first?.runID, run.id)
        XCTAssertEqual(vm.deskWorkLog.first?.statusLabel, "Done")
    }

    func test_queuedFollowUpStaysOnOwningBot_becauseDrainMustNotSendToAnotherDesk() throws {
        // WHY: send-while-live queues the follow-up. Completing Piper's run
        // used selectedBot, so a switch to Quinn delivered Piper's words
        // to the wrong teammate. The queue is per Desk and only drains
        // onto the bot that accepted it.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let thread = AgentThread(title: "From Piper", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let piperRun = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(piperRun)
        let piperConversation = BotConversation(
            botID: piper.id,
            title: "From Piper",
            linkedAgentThreadID: thread.id
        )
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskRunIsLive)
        vm.composerText = "follow up for Piper"
        vm.send()
        XCTAssertEqual(vm.queuedFollowUps.map(\.text), ["follow up for Piper"])
        XCTAssertFalse(
            vm.deskMessages.contains { $0.text == "follow up for Piper" },
            "queued follow-ups wait in the queue, not as a sent bubble"
        )

        vm.openDesk(quinn)
        XCTAssertTrue(
            vm.queuedFollowUps.isEmpty,
            "Quinn's Desk must not inherit Piper's queue"
        )
        var finished = piperRun
        finished.status = .completed
        finished.finishedAt = Date()
        try context.runRepo.upsert(finished)
        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)
        XCTAssertFalse(
            vm.deskMessages.contains { $0.text == "follow up for Piper" },
            "Piper's drained follow-up must not land on Quinn"
        )
        XCTAssertFalse(
            (try context.botStore.listConversations(botID: quinn.id))
                .contains { $0.title.contains("follow up for Piper") }
        )

        vm.openDesk(piper)
        XCTAssertTrue(
            vm.queuedFollowUps.isEmpty,
            "returning to idle Piper drains the follow-up onto Piper, not Quinn"
        )
        XCTAssertTrue(
            vm.deskMessages.contains { $0.text == "follow up for Piper" },
            "Piper must receive the words that were queued on Piper"
        )
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_queuedFollowUpCanBeRemoved_becauseAHiddenQueueIsNotASend() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskRunIsLive)
        vm.composerText = "keep this off the wire"
        vm.send()
        let queued = try XCTUnwrap(vm.queuedFollowUps.first)
        vm.removeQueuedFollowUp(queued)
        XCTAssertTrue(vm.queuedFollowUps.isEmpty)
        vm.reload()
        XCTAssertTrue(vm.queuedFollowUps.isEmpty, "reload must not resurrect a cancelled follow-up")
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "keep this off the wire" })
    }

    func test_queuedFollowUpSurvivesRelaunch_becauseTypedWordsMustNotVanish() throws {
        // WHY: a follow-up typed during a live turn is user work. Closing
        // RemoteCode used to drop the in-memory queue.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskRunIsLive)
        vm.composerText = "keep after relaunch"
        vm.send()
        XCTAssertEqual(vm.queuedFollowUps.map(\.text), ["keep after relaunch"])

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(bot)
        XCTAssertTrue(reopened.deskRunIsLive, "the run is still live after relaunch")
        XCTAssertEqual(reopened.queuedFollowUps.map(\.text), ["keep after relaunch"])
        XCTAssertFalse(
            reopened.deskMessages.contains { $0.text == "keep after relaunch" },
            "relaunch must restore the queue, not send it onto a still-live turn"
        )
    }

    func test_queueMutationKeepsTheEnqueueMomentOfEveryRowItDidNotTouch() throws {
        // WHY: `created_at` is the moment the user's words entered the queue,
        // and it is what `bot.queue.list` reports to the paired device.
        // `persistQueuedFollowUps` rewrote every bot's table with
        // `createdAt: Date()`, so removing one follow-up re-dated the rows that
        // survived — and every other teammate's rows — to now.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)

        let queuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstID = "11111111-1111-1111-1111-111111111111"
        let secondID = "22222222-2222-2222-2222-222222222222"
        let otherID = "33333333-3333-3333-3333-333333333333"
        for (id, botID, text) in [
            (firstID, piper.id, "first on piper"),
            (secondID, piper.id, "second on piper"),
            (otherID, quinn.id, "only on quinn"),
        ] {
            try context.botStore.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(
                id: id,
                botID: botID,
                text: text,
                createdAt: queuedAt
            ))
        }
        vm.reloadQueuedFollowUpsFromStore()
        XCTAssertEqual(
            vm.queuedFollowUps.map { $0.id.uuidString.lowercased() },
            [firstID, secondID],
            "fixture: the queued words must be in memory, not only in SQLite"
        )

        vm.removeQueuedFollowUp(try XCTUnwrap(vm.queuedFollowUps.last))

        let stored = try context.botStore.listAllQueuedFollowUps()
        XCTAssertEqual(
            stored.first { $0.id == firstID }?.createdAt,
            queuedAt,
            "removing one follow-up must not re-date the survivor to now"
        )
        XCTAssertEqual(
            stored.first { $0.id == otherID }?.createdAt,
            queuedAt,
            "a queue mutation must not re-date another teammate's queued words"
        )
    }

    func test_queueingOneFollowUpWritesOneRow_becauseASendMustNotRewriteEveryBotsQueue() throws {
        // WHY: a message sent while the Bot is working is queued inside the
        // send's acknowledgement. Queueing it deleted and re-inserted the
        // queue of every Bot on the Mac, so the wait before "queued" grew with
        // the whole fleet's backlog (20 Bots, 200 rows: 201 inserts for one
        // message). The words other Bots are holding must not be touched.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        var bots: [BotDefinition] = []
        for index in 0..<20 {
            bots.append(try vm.create(name: "Queue Bot \(index)", title: "Queue", provider: .claude))
        }
        let queuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, bot) in bots.enumerated() {
            for item in 0..<10 {
                _ = try context.botStore.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(
                    botID: bot.id,
                    text: "queued \(index)-\(item)",
                    createdAt: queuedAt.addingTimeInterval(TimeInterval(index * 10 + item))
                ))
            }
        }
        vm.reloadQueuedFollowUpsFromStore()

        let target = bots[7]
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: target.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(target)
        XCTAssertTrue(vm.deskRunIsLive, "fixture: the send must take the queued branch")
        let seeded = try context.botStore.listAllQueuedFollowUps()
        XCTAssertEqual(seeded.count, 200, "fixture: 20 Bots with 10 queued rows each")
        XCTAssertEqual(vm.queuedFollowUps.count, 10, "fixture: the queue is in memory, not only in SQLite")

        let rowWritesBefore = context.botStore.queuedFollowUpRowWriteCountForTesting
        vm.composerText = "one more for the queue"
        XCTAssertTrue(vm.send())
        XCTAssertEqual(
            context.botStore.queuedFollowUpRowWriteCountForTesting - rowWritesBefore,
            1,
            "one queued message must write one row"
        )

        let stored = try context.botStore.listAllQueuedFollowUps()
        XCTAssertEqual(stored.count, 201)
        let untouched = stored.filter { $0.text != "one more for the queue" }
        XCTAssertEqual(
            untouched.map(\.id),
            seeded.map(\.id),
            "the rows already queued keep their order"
        )
        XCTAssertEqual(
            untouched.map(\.createdAt),
            seeded.map(\.createdAt),
            "the rows already queued keep the moment they were queued"
        )
        let targetRows = try context.botStore.listQueuedFollowUps(botID: target.id)
        XCTAssertEqual(targetRows.last?.text, "one more for the queue", "the new row is last in its Bot's queue")
        XCTAssertEqual(
            vm.queuedFollowUps.map(\.text),
            targetRows.map(\.text),
            "the queue on screen is the stored queue, in the same order"
        )

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(target)
        XCTAssertEqual(
            reopened.queuedFollowUps.map(\.text),
            targetRows.map(\.text),
            "the queued message survives a relaunch"
        )
    }

    func test_refusedOneRowQueueInsertFallsBackToTheRewrite_becauseQueuedWordsMustNotLiveOnlyInMemory() throws {
        // WHY: the one-row insert can be refused by SQLite. The message is
        // already shown as queued, so it must still reach the store through the
        // full rewrite; kept only in memory, a relaunch would lose words the
        // user saw accepted.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let target = try vm.create(name: "Queue Bot", title: "Queue", provider: .claude)
        for item in 0..<10 {
            _ = try context.botStore.enqueueQueuedFollowUp(
                BotQueuedFollowUpRecord(botID: target.id, text: "queued \(item)")
            )
        }
        vm.reloadQueuedFollowUpsFromStore()
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: target.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(target)
        XCTAssertTrue(vm.deskRunIsLive, "fixture: the send must take the queued branch")

        // A real refused write, not a mock. Only the appended row (order 110)
        // aborts; the rewrite numbers the queue 0...10 and goes through.
        try context.db.execute("UPDATE bot_queued_follow_ups SET sort_order = sort_order + 100;")
        try context.db.execute("""
            CREATE TRIGGER t_refuse_appended_queue_row
            BEFORE INSERT ON bot_queued_follow_ups
            WHEN NEW.sort_order = 110
            BEGIN
                SELECT RAISE(ABORT, 'refused');
            END;
            """)
        defer { try? context.db.execute("DROP TRIGGER t_refuse_appended_queue_row;") }

        vm.composerText = "one more for the queue"
        XCTAssertTrue(vm.send())

        let targetRows = try context.botStore.listQueuedFollowUps(botID: target.id)
        XCTAssertEqual(
            targetRows.map(\.sortOrder),
            Array(0...10),
            "fixture: the one-row insert was refused, so the rewrite renumbered the queue"
        )
        XCTAssertEqual(targetRows.last?.text, "one more for the queue", "the refused message is still stored, last")
        XCTAssertEqual(
            vm.queuedFollowUps.map(\.text),
            targetRows.map(\.text),
            "the queue on screen is the stored queue, in the same order"
        )
    }

    func test_deletedBotDropsItsQueuedFollowUp_becauseTheTeammateIsGone() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(piper)
        vm.composerText = "orphan this"
        vm.send()
        vm.delete(id: piper.id)

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(quinn)
        XCTAssertTrue(reopened.queuedFollowUps.isEmpty)
        XCTAssertFalse(reopened.deskMessages.contains { $0.text == "orphan this" })
    }

    func test_hidingATeammateKeepsTheQueuedFollowUp_becauseHideIsARosterViewNotADelete() throws {
        // WHY: hiding a teammate only filters the roster. reloadFleet pruned the
        // follow-up queue against that filtered list, so the next reload deleted
        // the rows the user typed — the queue was gone even after showing hidden.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(piper)
        vm.composerText = "keep while hidden"
        vm.send()
        XCTAssertEqual(vm.queuedFollowUps.map(\.text), ["keep while hidden"])

        vm.setHidden(id: piper.id, hidden: true)
        vm.reload()

        XCTAssertTrue(
            try context.botStore.listAllQueuedFollowUps().contains { $0.botID == piper.id },
            "hiding a teammate must not delete the follow-up the user queued"
        )

        vm.showHidden = true
        vm.reload()
        vm.openDesk(piper)
        XCTAssertEqual(vm.queuedFollowUps.map(\.text), ["keep while hidden"])

        let reopened = BotsViewModel(context: context)
        reopened.showHidden = true
        reopened.openDesk(piper)
        XCTAssertEqual(
            reopened.queuedFollowUps.map(\.text),
            ["keep while hidden"],
            "the queued line must survive relaunch after the teammate was hidden"
        )
    }

    func test_hidingATeammateKeepsTheComposerDraft_becauseHideIsARosterViewNotADelete() throws {
        // WHY: the unsent composer line is user work too. Hiding its teammate
        // dropped the stored draft on the next reload, so showing hidden again
        // gave back an empty composer.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "unsent on Piper"
        vm.openDesk(quinn)
        XCTAssertEqual(vm.composerText, "")

        vm.setHidden(id: piper.id, hidden: true)
        vm.reload()
        vm.showHidden = true
        vm.reload()
        vm.openDesk(piper)

        XCTAssertEqual(
            vm.composerText,
            "unsent on Piper",
            "hiding a teammate must not delete the draft the user typed"
        )
    }

    func test_composerDraftStaysOnOwningBot_becauseDeskMustNotLeakUnsentWords() throws {
        // WHY: composerText was process-wide. Typing on Piper then opening
        // Quinn sent Piper's unsent line to the wrong teammate.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "only Piper should see this"
        vm.openDesk(quinn)
        XCTAssertEqual(vm.composerText, "", "Quinn's Desk must not inherit Piper's unsent draft")
        XCTAssertTrue(vm.attachments.isEmpty)
        vm.composerText = "only Quinn should see this"
        vm.openDesk(piper)
        XCTAssertEqual(vm.composerText, "only Piper should see this")
        vm.openDesk(quinn)
        XCTAssertEqual(vm.composerText, "only Quinn should see this")
    }

    func test_composerDraftSurvivesRelaunch_becauseTypedWordsMustNotVanish() throws {
        // WHY: an unsent Desk line is user work. Closing RemoteCode used
        // to drop the in-memory composer, same class of loss as follow-ups.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.composerText = "keep after relaunch"
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.screen, .desk)
        XCTAssertEqual(reopened.composerText, "keep after relaunch")
        XCTAssertFalse(
            reopened.deskMessages.contains { $0.text == "keep after relaunch" },
            "relaunch must restore the draft, not send it"
        )
    }

    func test_sendClearsComposerDraft_becauseSentWordsAreNotADraft() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.composerText = "send then forget"
        XCTAssertTrue(vm.send())
        XCTAssertEqual(vm.composerText, "")
        let reopened = BotsViewModel(context: context)
        reopened.openDesk(bot)
        XCTAssertEqual(reopened.composerText, "", "a sent line must not come back as a draft")
        XCTAssertTrue(reopened.deskMessages.contains { $0.text == "send then forget" })
    }

    func test_failedSendKeepsComposerWordsAttachmentsAndDraft_becauseNothingWasWritten() throws {
        // WHY: send() used to empty the composer, drop the staged attachments and
        // flush the (then empty) draft BEFORE the durable write. When that write
        // failed the user got an error message over an empty composer: the line and
        // the files they had just sent were gone and had to be produced again.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        let file = (directory as NSString).appendingPathComponent("retry-me.txt")
        FileManager.default.createFile(atPath: file, contents: Data("keep me".utf8))
        vm.addAttachments([file])
        vm.composerText = "these words must survive a failed send"
        XCTAssertEqual(vm.attachments.map(\.displayName), ["retry-me.txt"],
                       "fixture: the staged file must be attached")

        // A real failing write, not a mock: the store's own conversation insert aborts.
        try context.db.execute("""
            CREATE TRIGGER t_fail_bot_conversation_insert
            BEFORE INSERT ON bot_conversations
            BEGIN
                SELECT RAISE(ABORT, 'send must fail');
            END;
            """)

        XCTAssertFalse(vm.send(), "the aborted conversation write must report failure")
        XCTAssertNotNil(vm.errorMessage)

        XCTAssertEqual(vm.composerText, "these words must survive a failed send",
                       "WHY: nothing was written, so the words are still the user's to retry")
        XCTAssertEqual(vm.attachments.map(\.displayName), ["retry-me.txt"],
                       "WHY: a failed send must not consume the staged files either")

        try context.db.execute("DROP TRIGGER t_fail_bot_conversation_insert")
        vm.flushDraftPersistenceForTesting()
        let reopened = BotsViewModel(context: context)
        reopened.openDesk(bot)
        XCTAssertEqual(reopened.composerText, "these words must survive a failed send",
                       "WHY: the failed send must not have consumed the persisted draft")
    }

    func test_inspectorDraftsStayOnOwningBot_becauseMemorySkillsRoutinesMustNotLeak() throws {
        // WHY: memory/skill/routine fields were process-wide. A fact typed
        // for New Agent appeared on Batatilson's Memory inspector.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.memoryDraft = "only-piper-memory-draft"
        vm.skillDraft = "only-piper-skill"
        vm.routineName = "Piper scan"
        vm.routinePrompt = "Scan Piper"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.beginEdit(quinn)
        XCTAssertEqual(vm.memoryDraft, "", "Quinn Studio must not inherit Piper's memory draft")
        XCTAssertEqual(vm.skillDraft, "", "Quinn Studio must not inherit Piper's skill draft")
        XCTAssertEqual(vm.routineName, "")
        XCTAssertEqual(vm.routinePrompt, "")
        XCTAssertEqual(vm.routineScheduleNote, "")
        vm.memoryDraft = "only-quinn-memory-draft"
        vm.skillDraft = "only-quinn-skill"
        vm.openDesk(piper)
        XCTAssertEqual(vm.memoryDraft, "only-piper-memory-draft")
        XCTAssertEqual(vm.skillDraft, "only-piper-skill")
        XCTAssertEqual(vm.routineName, "Piper scan")
        XCTAssertEqual(vm.routinePrompt, "Scan Piper")
        XCTAssertEqual(vm.routineScheduleNote, "Weekdays 9:00")
        vm.openDesk(quinn)
        XCTAssertEqual(vm.memoryDraft, "only-quinn-memory-draft")
        XCTAssertEqual(vm.skillDraft, "only-quinn-skill")
        XCTAssertEqual(vm.routineName, "")
    }

    func test_inspectorDraftSurvivesRelaunch_becauseUnsentFactsMustNotVanish() throws {
        // WHY: an unsent Memory/Skills/Routines field is user work, same
        // class of loss as an unsent Desk composer line.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.memoryDraft = "keep inspector after relaunch"
        vm.skillDraft = "weekly-account-health"
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight"
        vm.routineScheduleNote = "Weekdays 9:00"
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.memoryDraft, "keep inspector after relaunch")
        XCTAssertEqual(reopened.skillDraft, "weekly-account-health")
        XCTAssertEqual(reopened.routineName, "Morning scan")
        XCTAssertEqual(reopened.routinePrompt, "Scan overnight")
        XCTAssertEqual(reopened.routineScheduleNote, "Weekdays 9:00")
        XCTAssertTrue(reopened.memoryItems.isEmpty, "relaunch must restore the draft, not save it")
    }

    func test_draftPersistenceCoalescesUntilFakeClockDeadline_becauseTypingMustNotWritePerCharacter() throws {
        // WHY: a 25 Hz editor must update visible/in-memory state immediately
        // without rebuilding and writing the full 50-row JSON envelope per key.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        vm.flushDraftPersistenceForTesting()
        let clock = BotDraftManualClock()
        vm.draftPersistenceScheduleForTesting = { delay, action in
            clock.schedule(afterNanoseconds: delay, action)
        }
        vm.resetDraftPersistenceMetricsForTesting()

        for _ in 0..<6 {
            vm.composerText.append("x")
            clock.advance(byNanoseconds: 40_000_000)
        }
        XCTAssertEqual(vm.composerText, "xxxxxx", "the in-memory draft must be immediate")
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.setCount, 0)
        XCTAssertEqual(clock.pendingCount, 1)

        clock.advance(byNanoseconds: 10_000_000)
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.encodeCount, 1)
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.setCount, 1)
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "bots.composerDrafts"))
        let stored = try JSONDecoder().decode([String: BotComposerDraft].self, from: data)
        XCTAssertEqual(stored[bot.id.value.uuidString.lowercased()]?.text, "xxxxxx")
    }

    func test_searchTextCoalescesUntilDeadline_becauseTypingMustNotWritePerKey() throws {
        // WHY: `searchText` is a per-keystroke @Published field; every key used to
        // hit UserDefaults immediately, so typing a 30-char query wrote the plist
        // 30 times. The field must stay immediate; the write must be the settled one.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.flushDraftPersistenceForTesting()
        let clock = BotDraftManualClock()
        vm.draftPersistenceScheduleForTesting = { delay, action in
            clock.schedule(afterNanoseconds: delay, action)
        }
        vm.resetDraftPersistenceMetricsForTesting()

        for _ in 0..<6 {
            vm.searchText.append("x")
            clock.advance(byNanoseconds: 40_000_000)
        }
        XCTAssertEqual(vm.searchText, "xxxxxx", "the in-memory query must be immediate")
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.searchTextWrites, 0)
        XCTAssertEqual(clock.pendingCount, 1)

        clock.advance(byNanoseconds: 10_000_000)
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.searchTextWrites, 1)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "bots.searchText"),
            "xxxxxx",
            "fixture: the one coalesced write must carry the whole settled query"
        )
    }

    func test_pendingSearchTextFlushesOnCloseAndQuit_becauseTheQueryMustSurviveRelaunch() throws {
        // WHY: the roster query is workflow state; the deferred write must not be
        // lost when the window closes or the app quits before the deadline fires.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.flushDraftPersistenceForTesting()
        let clock = BotDraftManualClock()
        vm.draftPersistenceScheduleForTesting = { delay, action in
            clock.schedule(afterNanoseconds: delay, action)
        }

        vm.searchText = "piper"
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "bots.searchText"),
            "fixture: nothing is stored before the deadline or a lifecycle flush"
        )
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nil)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "bots.searchText"), "piper")

        vm.searchText = "quinn"
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "bots.searchText"), "quinn")

        vm.searchText = "   "
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nil)
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "bots.searchText"),
            "WHY: a blank query must clear the key instead of restoring whitespace"
        )
    }

    func test_searchTextPendingWriteIsVisibleToTheNextSurface_becauseADeferredQueryMustNotGoStale() throws {
        // WHY: the query lands in UserDefaults only after typing settles. A surface
        // opened inside that window must read the pending query, not the older value
        // the plist still holds.
        let context = try makeContext()
        let first = BotsViewModel(context: context)
        // Drop the deadline the restore already armed, so the fake clock owns it.
        first.flushDraftPersistenceForTesting()
        let clock = BotDraftManualClock()
        first.draftPersistenceScheduleForTesting = { delay, action in
            clock.schedule(afterNanoseconds: delay, action)
        }
        first.searchText = "piper"
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "bots.searchText"),
            "fixture: the write is still pending, so only the context holds the query"
        )

        let second = BotsViewModel(context: context)
        XCTAssertEqual(second.searchText, "piper",
                       "WHY: the newest surface must not resurrect the settled-out query")

        clock.advance(byNanoseconds: 250_000_000)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "bots.searchText"), "piper")
        let third = BotsViewModel(context: context)
        XCTAssertEqual(third.searchText, "piper", "the settled write must serve later surfaces")
    }

    func test_pendingDraftsFlushBeforeBotSwitch_becauseOwnershipMustNotLeakOrLoseWork() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.")
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", soul: "Be exact.")
        vm.openStudio(piper)
        vm.flushDraftPersistenceForTesting()
        let clock = BotDraftManualClock()
        vm.draftPersistenceScheduleForTesting = { delay, action in
            clock.schedule(afterNanoseconds: delay, action)
        }
        vm.resetDraftPersistenceMetricsForTesting()
        vm.composerText = "Piper composer"
        vm.memoryDraft = "Piper memory"
        vm.studioDraft.title = "Piper draft title"
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.setCount, 0)

        vm.openDesk(quinn)

        XCTAssertEqual(vm.composerText, "")
        XCTAssertEqual(vm.memoryDraft, "")
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.encodeCount, 3)
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.setCount, 3)
        let decoder = JSONDecoder()
        let composer = try decoder.decode(
            [String: BotComposerDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.composerDrafts"))
        )
        let inspector = try decoder.decode(
            [String: BotInspectorDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.inspectorDrafts"))
        )
        let studio = try decoder.decode(
            [String: BotStudioDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.studioDraft"))
        )
        let key = piper.id.value.uuidString.lowercased()
        XCTAssertEqual(composer[key]?.text, "Piper composer")
        XCTAssertEqual(inspector[key]?.memoryDraft, "Piper memory")
        XCTAssertEqual(studio[key]?.title, "Piper draft title")
    }

    func test_sendAndSaveSynchronouslyFlushPendingDraftState_becauseCommittedTextMustNotReturn() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.")
        vm.openDesk(bot)
        vm.flushDraftPersistenceForTesting()
        let clock = BotDraftManualClock()
        vm.draftPersistenceScheduleForTesting = { delay, action in
            clock.schedule(afterNanoseconds: delay, action)
        }

        vm.composerText = "send then forget"
        XCTAssertTrue(vm.send())
        XCTAssertNil(
            UserDefaults.standard.data(forKey: "bots.composerDrafts"),
            "Send must synchronously remove the consumed draft"
        )

        vm.beginEdit(bot)
        vm.studioDraft.title = "Published title"
        _ = try vm.saveStudio()
        let studioData = try XCTUnwrap(UserDefaults.standard.data(forKey: "bots.studioDraft"))
        let studio = try JSONDecoder().decode([String: BotStudioDraft].self, from: studioData)
        XCTAssertEqual(studio[bot.id.value.uuidString.lowercased()]?.title, "Published title")

        let writes = vm.draftPersistenceMetricsForTesting.setCount
        clock.advance(byNanoseconds: 1_000_000_000)
        XCTAssertEqual(
            vm.draftPersistenceMetricsForTesting.setCount,
            writes,
            "a cancelled deadline must not write a second time after explicit flush"
        )
    }

    func test_hideCloseAndQuitFlushPendingDrafts_becauseLifecycleMustPreserveLatestText() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.")
        vm.beginEdit(bot)
        vm.flushDraftPersistenceForTesting()
        let clock = BotDraftManualClock()
        vm.draftPersistenceScheduleForTesting = { delay, action in
            clock.schedule(afterNanoseconds: delay, action)
        }
        vm.resetDraftPersistenceMetricsForTesting()

        vm.studioDraft.title = "Before hide"
        NotificationCenter.default.post(name: NSApplication.willHideNotification, object: nil)
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.setCount, 1)

        vm.studioDraft.title = "Before close"
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nil)
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.setCount, 2)

        vm.studioDraft.title = "Before quit"
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(vm.draftPersistenceMetricsForTesting.setCount, 3)
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "bots.studioDraft"))
        let stored = try JSONDecoder().decode([String: BotStudioDraft].self, from: data)
        XCTAssertEqual(stored[bot.id.value.uuidString.lowercased()]?.title, "Before quit")
    }

    func test_olderPendingDraftFromAnotherViewModelCannotReplaceNewerCommittedText() throws {
        // WHY: Desk, sidebar, and guest windows share one AppContext. A delayed
        // write from an older surface must not undo text already committed by a
        // newer surface for the same bot.
        let context = try makeContext()
        let older = BotsViewModel(context: context)
        let bot = try older.create(name: "Piper", title: "Scout")
        older.beginEdit(bot)
        let newer = BotsViewModel(context: context)
        newer.beginEdit(bot)
        older.flushDraftPersistenceForTesting()
        newer.flushDraftPersistenceForTesting()

        let olderClock = BotDraftManualClock()
        older.draftPersistenceScheduleForTesting = { delay, action in
            olderClock.schedule(afterNanoseconds: delay, action)
        }
        older.composerText = "older pending"
        older.memoryDraft = "older memory"
        older.studioDraft.title = "Older title"
        newer.composerText = "newer committed"
        newer.memoryDraft = "newer memory"
        newer.studioDraft.title = "Newer title"
        newer.flushDraftPersistenceForTesting()
        older.flushDraftPersistenceForTesting()

        let decoder = JSONDecoder()
        let composer = try decoder.decode(
            [String: BotComposerDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.composerDrafts"))
        )
        let inspector = try decoder.decode(
            [String: BotInspectorDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.inspectorDrafts"))
        )
        let studio = try decoder.decode(
            [String: BotStudioDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.studioDraft"))
        )
        let key = bot.id.value.uuidString.lowercased()
        XCTAssertEqual(composer[key]?.text, "newer committed")
        XCTAssertEqual(inspector[key]?.memoryDraft, "newer memory")
        XCTAssertEqual(studio[key]?.title, "Newer title")
    }

    func test_differentBotDraftsFromDifferentViewModelsPersistAsOneUnion() throws {
        // WHY: independent windows may edit different teammates concurrently;
        // persisting either surface must preserve the other teammate's work.
        let context = try makeContext()
        let first = BotsViewModel(context: context)
        let piper = try first.create(name: "Piper", title: "Scout")
        let quinn = try first.create(name: "Quinn", title: "Reviewer")
        let second = BotsViewModel(context: context)
        first.beginEdit(piper)
        second.beginEdit(quinn)
        first.flushDraftPersistenceForTesting()
        second.flushDraftPersistenceForTesting()

        first.composerText = "Piper unfinished"
        first.memoryDraft = "Piper memory"
        first.studioDraft.title = "Piper title"
        second.composerText = "Quinn unfinished"
        second.memoryDraft = "Quinn memory"
        second.studioDraft.title = "Quinn title"
        first.flushDraftPersistenceForTesting()
        second.flushDraftPersistenceForTesting()

        let decoder = JSONDecoder()
        let composer = try decoder.decode(
            [String: BotComposerDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.composerDrafts"))
        )
        let inspector = try decoder.decode(
            [String: BotInspectorDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.inspectorDrafts"))
        )
        let studio = try decoder.decode(
            [String: BotStudioDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.studioDraft"))
        )
        let piperKey = piper.id.value.uuidString.lowercased()
        let quinnKey = quinn.id.value.uuidString.lowercased()
        XCTAssertEqual(composer[piperKey]?.text, "Piper unfinished")
        XCTAssertEqual(composer[quinnKey]?.text, "Quinn unfinished")
        XCTAssertEqual(inspector[piperKey]?.memoryDraft, "Piper memory")
        XCTAssertEqual(inspector[quinnKey]?.memoryDraft, "Quinn memory")
        XCTAssertEqual(studio[piperKey]?.title, "Piper title")
        XCTAssertEqual(studio[quinnKey]?.title, "Quinn title")
    }

    func test_staleEmptyDraftFromAnotherViewModelCannotDeleteNewerText() throws {
        // WHY: an empty local snapshot is a real tombstone only at the moment
        // the user clears it; it must not erase a later edit from another window.
        let context = try makeContext()
        let stale = BotsViewModel(context: context)
        let bot = try stale.create(name: "Piper", title: "Scout")
        stale.openDesk(bot)
        let newer = BotsViewModel(context: context)
        newer.openDesk(bot)
        stale.flushDraftPersistenceForTesting()
        newer.flushDraftPersistenceForTesting()

        stale.composerText = "temporary"
        stale.composerText = ""
        newer.composerText = "newer survives"
        newer.flushDraftPersistenceForTesting()
        stale.flushDraftPersistenceForTesting()

        let stored = try JSONDecoder().decode(
            [String: BotComposerDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.composerDrafts"))
        )
        XCTAssertEqual(stored[bot.id.value.uuidString.lowercased()]?.text, "newer survives")
    }

    func test_staleViewModelNavigationCannotRecaptureOlderComposerOrInspectorDraft() throws {
        // WHY: Desk, sidebar, and guest windows can keep local fields for the
        // same bot. Navigation from a stale window must not turn those fields
        // into a newer edit that replaces another window's immediate changes.
        let context = try makeContext()
        let stale = BotsViewModel(context: context)
        let piper = try stale.create(name: "Piper", title: "Scout")
        let quinn = try stale.create(name: "Quinn", title: "Reviewer")
        stale.beginEdit(piper)
        stale.composerText = "older composer"
        stale.memoryDraft = "older inspector"
        stale.flushDraftPersistenceForTesting()

        let newer = BotsViewModel(context: context)
        newer.beginEdit(piper)
        let clock = BotDraftManualClock()
        stale.draftPersistenceScheduleForTesting = { delay, action in
            clock.schedule(afterNanoseconds: delay, action)
        }
        newer.composerText = "newer composer"
        newer.memoryDraft = "newer inspector"

        stale.openDesk(quinn)

        XCTAssertEqual(
            context.botDraftPersistenceAuthority.composerDraftsByBot[piper.id]?.text,
            "newer composer"
        )
        XCTAssertEqual(
            context.botDraftPersistenceAuthority.inspectorDraftsByBot[piper.id]?.memoryDraft,
            "newer inspector"
        )
        let decoder = JSONDecoder()
        let composer = try decoder.decode(
            [String: BotComposerDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.composerDrafts"))
        )
        let inspector = try decoder.decode(
            [String: BotInspectorDraft].self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.inspectorDrafts"))
        )
        let key = piper.id.value.uuidString.lowercased()
        XCTAssertEqual(composer[key]?.text, "newer composer")
        XCTAssertEqual(inspector[key]?.memoryDraft, "newer inspector")
    }

    func test_hideCloseAndQuitWithMultipleViewModelsWriteSharedFinalStateOnce() throws {
        // WHY: every real surface sees app/window lifecycle notifications. One
        // AppContext owner must persist the union exactly once, independent of
        // NotificationCenter observer ordering.
        let context = try makeContext()
        let first = BotsViewModel(context: context)
        let piper = try first.create(name: "Piper", title: "Scout")
        let quinn = try first.create(name: "Quinn", title: "Reviewer")
        let second = BotsViewModel(context: context)
        first.beginEdit(piper)
        second.beginEdit(quinn)
        first.flushDraftPersistenceForTesting()
        second.flushDraftPersistenceForTesting()
        let clock = BotDraftManualClock()
        first.draftPersistenceScheduleForTesting = { delay, action in
            clock.schedule(afterNanoseconds: delay, action)
        }
        let events: [(Notification.Name, String)] = [
            (NSApplication.willHideNotification, "hide"),
            (NSWindow.willCloseNotification, "close"),
            (NSApplication.willTerminateNotification, "quit"),
        ]

        for (name, label) in events {
            first.composerText = "Piper before \(label)"
            first.memoryDraft = "Piper memory before \(label)"
            first.studioDraft.title = "Piper title before \(label)"
            second.composerText = "Quinn before \(label)"
            second.memoryDraft = "Quinn memory before \(label)"
            second.studioDraft.title = "Quinn title before \(label)"
            first.resetDraftPersistenceMetricsForTesting()
            NotificationCenter.default.post(name: name, object: nil)

            XCTAssertEqual(first.draftPersistenceMetricsForTesting.setCount, 3, label)
            XCTAssertEqual(second.draftPersistenceMetricsForTesting.setCount, 3, label)
            let decoder = JSONDecoder()
            let composer = try decoder.decode(
                [String: BotComposerDraft].self,
                from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.composerDrafts"))
            )
            let inspector = try decoder.decode(
                [String: BotInspectorDraft].self,
                from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.inspectorDrafts"))
            )
            let studio = try decoder.decode(
                [String: BotStudioDraft].self,
                from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.studioDraft"))
            )
            let piperKey = piper.id.value.uuidString.lowercased()
            let quinnKey = quinn.id.value.uuidString.lowercased()
            XCTAssertEqual(
                composer[piperKey]?.text,
                "Piper before \(label)"
            )
            XCTAssertEqual(
                composer[quinnKey]?.text,
                "Quinn before \(label)"
            )
            XCTAssertEqual(inspector[piperKey]?.memoryDraft, "Piper memory before \(label)")
            XCTAssertEqual(inspector[quinnKey]?.memoryDraft, "Quinn memory before \(label)")
            XCTAssertEqual(studio[piperKey]?.title, "Piper title before \(label)")
            XCTAssertEqual(studio[quinnKey]?.title, "Quinn title before \(label)")
        }
    }

    /// Paired proof for the three per-keystroke UserDefaults paths. Fifty rows
    /// is the production Bot cap; 500 mutations represent 20 seconds at 25 Hz.
    func test_microbenchDraftPersistenceCoalescingReducesRealWrites() throws {
        let context = try makeContext()
        var bots: [BotDefinition] = []
        for index in 0..<BotDefinition.liveAccountCap {
            bots.append(try context.botStore.create(
                name: "Draft Bot \(index)",
                title: "Production operations teammate \(index)",
                description: "Owns a realistic account workflow and keeps a concise handoff for the next shift.",
                soul: String(repeating: "Operate carefully, cite evidence, and preserve unfinished user work. ", count: 8)
            ))
        }
        let target = try XCTUnwrap(bots.last)
        let encoder = JSONEncoder()
        let composerPayload = Dictionary(uniqueKeysWithValues: bots.enumerated().map { index, bot in
            (bot.id.value.uuidString.lowercased(), BotComposerDraft(
                text: "Draft \(index): " + String(repeating: "check the deployment evidence before reporting completion. ", count: 6)
            ))
        })
        let inspectorPayload = Dictionary(uniqueKeysWithValues: bots.enumerated().map { index, bot in
            (bot.id.value.uuidString.lowercased(), BotInspectorDraft(
                memoryDraft: "Customer \(index) prefers a written audit trail.",
                skillDraft: "release-verification-\(index)",
                routineName: "Morning account review \(index)",
                routinePrompt: String(repeating: "Review alerts, reconcile ownership, and list blockers. ", count: 5),
                routineScheduleNote: "Weekdays at 09:00",
                routineSpec: BotScheduleSpec()
            ))
        })
        let studioPayload = Dictionary(uniqueKeysWithValues: bots.enumerated().map { index, bot in
            (bot.id.value.uuidString.lowercased(), BotStudioDraft(
                botID: bot.id,
                name: bot.name,
                title: bot.title,
                description: bot.description,
                handle: bot.handle,
                avatarSymbol: bot.avatarSymbol,
                soul: String(repeating: "Keep the owner informed, verify final state, and fail loud on uncertainty. ", count: 10),
                notificationsEnabled: bot.notificationsEnabled,
                expectedRevisionID: bot.currentRevisionID
            ))
        })
        let composerData = try encoder.encode(composerPayload)
        let inspectorData = try encoder.encode(inspectorPayload)
        let studioData = try encoder.encode(studioPayload)
        let targetKey = target.id.value.uuidString.lowercased()
        let expectedComposer = try XCTUnwrap(composerPayload[targetKey]).text
            + String(repeating: "c", count: 200)
        let expectedStudioSoul = try XCTUnwrap(studioPayload[targetKey]).soul
            + String(repeating: "s", count: 150)
        let expectedRoutinePrompt = try XCTUnwrap(inspectorPayload[targetKey]).routinePrompt
            + String(repeating: "i", count: 150)

        func measure(eager: Bool) throws -> (
            wallMs: Double,
            cpuMs: Double,
            metrics: BotDraftPersistenceMetrics
        ) {
            UserDefaults.standard.set(composerData, forKey: "bots.composerDrafts")
            UserDefaults.standard.set(inspectorData, forKey: "bots.inspectorDrafts")
            UserDefaults.standard.set(studioData, forKey: "bots.studioDraft")
            UserDefaults.standard.set(targetKey, forKey: "bots.selectedBotID")
            UserDefaults.standard.set(BotsScreen.studio.rawValue, forKey: "bots.screen")
            context.botDraftPersistenceAuthority.reloadFromUserDefaultsForTesting()
            let vm = BotsViewModel(context: context)
            vm.flushDraftPersistenceForTesting()
            let clock = BotDraftManualClock()
            if eager {
                vm.draftPersistenceScheduleForTesting = { _, action in action() }
            } else {
                vm.draftPersistenceScheduleForTesting = { delay, action in
                    clock.schedule(afterNanoseconds: delay, action)
                }
            }
            vm.resetDraftPersistenceMetricsForTesting()
            let cpuStart = Self.processCPUNanoseconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            Self.performDraftTypingWorkload(vm) {
                clock.advance(byNanoseconds: 40_000_000)
            }
            vm.flushDraftPersistenceForTesting()
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            let cpuEnd = Self.processCPUNanoseconds()

            let decoder = JSONDecoder()
            let storedComposer = try decoder.decode(
                [String: BotComposerDraft].self,
                from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.composerDrafts"))
            )
            let storedInspector = try decoder.decode(
                [String: BotInspectorDraft].self,
                from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.inspectorDrafts"))
            )
            let storedStudio = try decoder.decode(
                [String: BotStudioDraft].self,
                from: XCTUnwrap(UserDefaults.standard.data(forKey: "bots.studioDraft"))
            )
            XCTAssertEqual(storedComposer.count, BotDefinition.liveAccountCap)
            XCTAssertEqual(storedInspector.count, BotDefinition.liveAccountCap)
            XCTAssertEqual(storedStudio.count, BotDefinition.liveAccountCap)
            XCTAssertEqual(storedComposer[targetKey]?.text, expectedComposer)
            XCTAssertEqual(storedInspector[targetKey]?.routinePrompt, expectedRoutinePrompt)
            XCTAssertEqual(storedStudio[targetKey]?.soul, expectedStudioSoul)
            return (
                Double(wallEnd - wallStart) / 1_000_000,
                Double(cpuEnd - cpuStart) / 1_000_000,
                vm.draftPersistenceMetricsForTesting
            )
        }

        for index in 0..<2 {
            if index.isMultiple(of: 2) {
                _ = try measure(eager: true)
                _ = try measure(eager: false)
            } else {
                _ = try measure(eager: false)
                _ = try measure(eager: true)
            }
        }
        var eagerSamples: [(wallMs: Double, cpuMs: Double, metrics: BotDraftPersistenceMetrics)] = []
        var coalescedSamples: [(wallMs: Double, cpuMs: Double, metrics: BotDraftPersistenceMetrics)] = []
        for index in 0..<5 {
            if index.isMultiple(of: 2) {
                eagerSamples.append(try measure(eager: true))
                coalescedSamples.append(try measure(eager: false))
            } else {
                coalescedSamples.append(try measure(eager: false))
                eagerSamples.append(try measure(eager: true))
            }
        }
        XCTAssertTrue(eagerSamples.allSatisfy { $0.metrics.encodeCount == 500 })
        XCTAssertTrue(eagerSamples.allSatisfy { $0.metrics.setCount == 500 })
        XCTAssertTrue(coalescedSamples.allSatisfy { $0.metrics.encodeCount > 0 && $0.metrics.encodeCount < 100 })
        XCTAssertTrue(coalescedSamples.allSatisfy { $0.metrics.setCount == $0.metrics.encodeCount })

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }
        func reduction(before: Double, after: Double) -> Double {
            (before - after) / before * 100
        }
        let wallReduction = reduction(
            before: median(eagerSamples.map(\.wallMs)),
            after: median(coalescedSamples.map(\.wallMs))
        )
        let cpuReduction = reduction(
            before: median(eagerSamples.map(\.cpuMs)),
            after: median(coalescedSamples.map(\.cpuMs))
        )
        let setReduction = reduction(
            before: median(eagerSamples.map { Double($0.metrics.setCount) }),
            after: median(coalescedSamples.map { Double($0.metrics.setCount) })
        )
        let encodedBytesReduction = reduction(
            before: median(eagerSamples.map { Double($0.metrics.encodedBytes) }),
            after: median(coalescedSamples.map { Double($0.metrics.encodedBytes) })
        )
        XCTAssertGreaterThan(wallReduction, 5)
        XCTAssertGreaterThan(cpuReduction, 5)
        XCTAssertGreaterThan(setReduction, 5)
        XCTAssertGreaterThan(encodedBytesReduction, 5)
        NSLog(
            "[perf-proof] botDraftPersistence paired=true drafts=50 chars=500 cadence_hz=25 warmup=2 n=5 eager_wall_ms=%@ coalesced_wall_ms=%@ eager_cpu_ms=%@ coalesced_cpu_ms=%@ eager_encode_count=%@ coalesced_encode_count=%@ eager_set_count=%@ coalesced_set_count=%@ eager_encoded_bytes_proxy=%@ coalesced_encoded_bytes_proxy=%@ wall_reduction_pct=%.2f cpu_reduction_pct=%.2f set_reduction_pct=%.2f encoded_bytes_reduction_pct=%.2f",
            String(describing: eagerSamples.map(\.wallMs)),
            String(describing: coalescedSamples.map(\.wallMs)),
            String(describing: eagerSamples.map(\.cpuMs)),
            String(describing: coalescedSamples.map(\.cpuMs)),
            String(describing: eagerSamples.map(\.metrics.encodeCount)),
            String(describing: coalescedSamples.map(\.metrics.encodeCount)),
            String(describing: eagerSamples.map(\.metrics.setCount)),
            String(describing: coalescedSamples.map(\.metrics.setCount)),
            String(describing: eagerSamples.map(\.metrics.encodedBytes)),
            String(describing: coalescedSamples.map(\.metrics.encodedBytes)),
            wallReduction,
            cpuReduction,
            setReduction,
            encodedBytesReduction
        )
    }

    func test_studioScheduleSpecStaysOnOwningBot_becauseFrequencyMustNotLeak() throws {
        // WHY: Studio Schedule Tasks persist name/prompt/when-note per bot,
        // but Frequency + Provider live on routineSpec, which stayed
        // process-wide after the When field became BotScheduleSpecEditor.
        // Quinn must not inherit Piper's weekdays/Grok row, and coming
        // back must restore Piper's Frequency.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.routineName = "QA morning scan"
        vm.routinePrompt = "List failing tests from last night and name the file."
        vm.routineSpec.frequency = .weekdays
        vm.routineSpec.localTimeHour = 9
        vm.routineSpec.localTimeMinute = 0
        vm.routineSpec.provider = .grok
        vm.beginEdit(quinn)
        XCTAssertEqual(vm.routineName, "", "Quinn Studio must not inherit Piper's task name")
        XCTAssertNotEqual(
            vm.routineSpec.frequency,
            .weekdays,
            "Quinn must not inherit Piper's Frequency"
        )
        XCTAssertEqual(vm.routineSpec.frequency, .daily)
        vm.routineSpec.frequency = .hourly
        vm.beginEdit(piper)
        XCTAssertEqual(vm.routineName, "QA morning scan")
        XCTAssertEqual(vm.routineSpec.frequency, .weekdays)
        XCTAssertEqual(vm.routineSpec.localTimeHour, 9)
        XCTAssertEqual(vm.routineSpec.provider, .grok)
        vm.beginEdit(quinn)
        XCTAssertEqual(vm.routineSpec.frequency, .hourly)
    }

    func test_studioScheduleSpecSurvivesRelaunch_becauseFrequencyIsUserWork() throws {
        // WHY: an unfinished Frequency pick is the same class of loss as
        // an unsent task name. Relaunch must restore the spec, not the
        // process-wide default Daily-at-now.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.routineName = "QA morning scan"
        vm.routinePrompt = "List failing tests from last night and name the file."
        vm.routineSpec.frequency = .weekdays
        vm.routineSpec.localTimeHour = 9
        vm.routineSpec.localTimeMinute = 0
        vm.routineSpec.provider = .grok
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.routineName, "QA morning scan")
        XCTAssertEqual(reopened.routineSpec.frequency, .weekdays)
        XCTAssertEqual(reopened.routineSpec.localTimeHour, 9)
        XCTAssertEqual(reopened.routineSpec.provider, .grok)
    }

    func test_savingInspectorFieldsClearsOnlyThatBotDraft_becauseSentFactsAreNotDrafts() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        XCTAssertTrue(vm.memoryDraft.isEmpty)
        vm.beginEdit(quinn)
        vm.memoryDraft = "Quinn-only fact"
        vm.beginEdit(piper)
        XCTAssertEqual(vm.memoryDraft, "", "saved memory must not return as a draft")
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers dark mode"])
        vm.beginEdit(quinn)
        XCTAssertEqual(vm.memoryDraft, "Quinn-only fact")
    }

    func test_deletedBotDropsItsInspectorDraft_becauseTheTeammateIsGone() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.memoryDraft = "orphan this inspector draft"
        vm.delete(id: piper.id)
        let reopened = BotsViewModel(context: context)
        reopened.beginEdit(quinn)
        XCTAssertEqual(reopened.memoryDraft, "")
    }

    func test_deletedBotDropsItsComposerDraft_becauseTheTeammateIsGone() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "orphan this draft"
        vm.delete(id: piper.id)
        let reopened = BotsViewModel(context: context)
        reopened.openDesk(quinn)
        XCTAssertEqual(reopened.composerText, "")
        XCTAssertFalse(reopened.deskMessages.contains { $0.text == "orphan this draft" })
    }

    func test_deskTimelineHidesPersistedAssistantThatDuplicatesTheTurn_becauseRepliesMustNotDouble() {
        // WHY: Desk hydrates messageRepo AND replays stream events. The same
        // greeting must not appear as a bubble and again as the turn final.
        let user = BotDeskMessage(
            role: .user,
            text: "Qual seu nome?",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let assistant = BotDeskMessage(
            role: .assistant,
            text: "Meu nome é Batatilson da Silva — Gerente de Marketing.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        )
        let turn = AssistantTurnSnapshot(
            turnId: "t-name",
            items: [
                AssistantItem(
                    id: "r1",
                    turnId: "t-name",
                    type: .reasoning,
                    state: .completed,
                    body: "Introducing myself",
                    startedAtMs: 1_700_000_010_000,
                    finishedAtMs: 1_700_000_020_000
                ),
            ],
            finalAssistantMessage: "Meu nome é Batatilson da Silva — Gerente de Marketing.",
            finished: true
        )
        let items = BotsDeskFollowThrough.timeline(
            messages: [user, assistant],
            workLog: [],
            turns: [turn],
            hideWorkLog: true
        )
        let assistantRows = items.filter { item in
            if case .message(let message) = item, message.role == .assistant { return true }
            return false
        }
        XCTAssertTrue(assistantRows.isEmpty, "the persisted bubble must yield to the turn-owned answer")
        XCTAssertEqual(items.filter { if case .liveTurn = $0 { return true }; return false }.count, 1)
    }

    func test_deskTimelineHidesRepeatedTurnFinal_becauseTwoWorkedRowsMustNotRepeatTheAnswer() {
        // WHY: two finished turns with the same final would stack the greeting.
        // Keep each Worked disclosure; paint the answer once.
        let first = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(
                    id: "tool1",
                    turnId: "t1",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
            ],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        let second = AssistantTurnSnapshot(
            turnId: "t2",
            items: [
                AssistantItem(
                    id: "tool2",
                    turnId: "t2",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 3,
                    finishedAtMs: 4
                ),
            ],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        let items = BotsDeskFollowThrough.timeline(
            messages: [],
            workLog: [],
            turns: [first, second],
            hideWorkLog: true
        )
        let hidden = items.compactMap { item -> Bool? in
            if case .liveTurn(_, let hide) = item { return hide }
            return nil
        }
        XCTAssertEqual(hidden, [false, true])
    }

    func test_deskTimelinePaintsOneReplyWhenClaudeEmitsStreamAndSnapshot() {
        // WHY: live Batatilson turns persist one assistant row but Claude's
        // stream also writes two assistantMessage items. The teammate must
        // answer once.
        let answer = "Sou Batatilson da Silva, Gerente de Marketing, e não alterei nenhum arquivo."
        let user = BotDeskMessage(
            role: .user,
            text: "Brain inspector proof. Reply one short sentence. Do not change files.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let persisted = BotDeskMessage(
            role: .assistant,
            text: answer,
            createdAt: Date(timeIntervalSince1970: 1_700_000_007)
        )
        let turn = AssistantTurnSnapshot(
            turnId: "t-brain",
            items: [
                AssistantItem(
                    id: "stream",
                    turnId: "t-brain",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 1_700_000_004_000,
                    finishedAtMs: 1_700_000_006_000
                ),
                AssistantItem(
                    id: "snapshot",
                    turnId: "t-brain",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 1_700_000_005_000,
                    finishedAtMs: 1_700_000_006_000
                ),
            ],
            finalAssistantMessage: answer,
            finished: true
        )
        let items = BotsDeskFollowThrough.timeline(
            messages: [user, persisted],
            workLog: [],
            turns: [turn],
            hideWorkLog: true
        )
        let answers = items.compactMap { item -> String? in
            switch item {
            case .message(let message) where message.role == .assistant:
                return message.text
            case .liveTurn(let live, let hide):
                XCTAssertFalse(hide)
                let composition = AgentChatLiveTurnChrome.compose(live)
                XCTAssertTrue(
                    composition.outside.isEmpty,
                    "matching assistant items must yield to the turn final so Desk and Agent App paint one reply"
                )
                XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(live))
                return live.finalAssistantMessage
            default:
                return nil
            }
        }
        XCTAssertEqual(answers, [answer])
    }

    func test_openingAnotherBotDoesNotKeepPreviousLiveTurns_becauseEachDeskOwnsItsThread() throws {
        // WHY: applyDeskLiveReplay used the previous bot's deskLiveTimeline as
        // "current". isRicher then kept Batatilson's Worked rows on New Agent.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)

        let piperThread = AgentThread(title: "Piper", provider: .claude, model: "opus")
        let quinnThread = AgentThread(title: "Quinn", provider: .claude, model: "opus")
        try context.threadRepo.upsert(piperThread)
        try context.threadRepo.upsert(quinnThread)
        let piperRun = AgentRun(
            threadId: piperThread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_040)
        )
        let quinnRun = AgentRun(
            threadId: quinnThread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_110),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_120)
        )
        try context.runRepo.upsert(piperRun)
        try context.runRepo.upsert(quinnRun)
        try persistStreamEvents(
            context: context,
            run: piperRun,
            events: [
                .turnStarted(turnId: "piper-turn"),
                .itemStarted(item: AssistantItem(
                    id: "piper-tool",
                    turnId: "piper-turn",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1_700_000_010_000,
                    finishedAtMs: 1_700_000_020_000
                )),
                .turnCompleted(turnId: "piper-turn", finalMessage: "Piper only answer"),
            ]
        )
        try persistStreamEvents(
            context: context,
            run: quinnRun,
            events: [
                .turnStarted(turnId: "quinn-turn"),
                .itemStarted(item: AssistantItem(
                    id: "quinn-r",
                    turnId: "quinn-turn",
                    type: .reasoning,
                    state: .completed,
                    body: "Quinn thought",
                    startedAtMs: 1_700_000_110_000,
                    finishedAtMs: 1_700_000_111_000
                )),
                .turnCompleted(turnId: "quinn-turn", finalMessage: "Quinn only answer"),
            ]
        )
        try context.messageRepo.append(AgentMessage(
            threadId: piperThread.id,
            role: .user,
            content: "Piper ask",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.messageRepo.append(AgentMessage(
            threadId: quinnThread.id,
            role: .user,
            content: "P1a desk send check",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Piper ask", linkedAgentThreadID: piperThread.id)
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: quinn.id, title: "P1a desk send check", linkedAgentThreadID: quinnThread.id)
        )

        vm.openDesk(piper)
        XCTAssertTrue(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "Piper only answer" },
            "Piper's Desk must replay Piper's thread"
        )

        vm.openDesk(quinn)
        XCTAssertFalse(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "Piper only answer" },
            "Quinn must not inherit Piper's richer live timeline"
        )
        XCTAssertTrue(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "Quinn only answer" }
        )
        XCTAssertFalse(
            vm.deskMessages.contains { $0.text.contains("Piper") },
            "Quinn's persisted bubbles must stay on Quinn's thread"
        )
        XCTAssertTrue(vm.deskMessages.contains { $0.text == "P1a desk send check" })
    }

    func test_askedBotDeskShowsFromHostChromeNotAskPrompt() async throws {
        // WHY: the asked bot Desk painted "Ceo asked you:" as a raw user
        // bubble. It must show From <host> chrome and the actual ask.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        let prompt = "@\(quinn.handle) Pergunte ao bot seu nome e função"
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: prompt
        )
        let peerStarted = await waitUntil(timeout: 5) { peerRunner.requests.count == 1 }
        XCTAssertTrue(peerStarted)
        vm.openDesk(quinn)
        let inboundArrived = await waitUntil(timeout: 5) {
            vm.deskTranscriptForTesting(botID: quinn.id).contains { $0.role == .user }
        }
        XCTAssertTrue(inboundArrived)
        let inbound = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: quinn.id).first { $0.role == .user }
        )
        XCTAssertEqual(inbound.peer?.direction, .fromPeer)
        XCTAssertEqual(inbound.peer?.name, piper.name)
        XCTAssertEqual(inbound.peer?.handle, piper.handle)
        XCTAssertEqual(inbound.peer?.avatarSymbol, piper.avatarSymbol)
        XCTAssertFalse(inbound.peer?.avatarSymbol.isEmpty == true)
        XCTAssertEqual(inbound.peer?.caption, "From \(piper.name)")
        XCTAssertEqual(inbound.text, "@\(quinn.handle) Pergunte ao bot seu nome e função")
        XCTAssertFalse(inbound.text.contains("asked you:"))
        XCTAssertFalse(BotPeerTranscript.isPeerAskUserText(inbound.text))
        XCTAssertTrue(peerRunner.finish(
            runID: try XCTUnwrap(peerRunner.requests.first?.runId),
            status: .cancelled,
            reply: nil
        ))
        await milestone.value
    }

    func test_restoreHidesPeerAskPromptAndKeepsFromHostChrome() async throws {
        // WHY: the asked bot's thread stores the internal "Piper asked you:"
        // provider line. Reload must not paint that wrapper, and must keep
        // From-host chrome from the handoff.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) Pergunte ao bot seu nome e função"
        )

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(quinn)
        XCTAssertFalse(
            reopened.deskMessages.contains { BotPeerTranscript.isPeerAskUserText($0.text) },
            "internal peer-ask prompt must not paint as a Desk bubble"
        )
        let inbound = try XCTUnwrap(reopened.deskMessages.first { $0.role == .user })
        XCTAssertEqual(inbound.peer?.direction, .fromPeer)
        XCTAssertEqual(inbound.peer?.name, piper.name)
        XCTAssertEqual(inbound.peer?.handle, piper.handle)
        XCTAssertEqual(inbound.peer?.avatarSymbol, piper.avatarSymbol)
        XCTAssertTrue(inbound.text.contains("Pergunte ao bot seu nome e função"))
        XCTAssertFalse(inbound.text.contains("asked you:"))
        let peerStarted = await waitUntil(timeout: 5) { peerRunner.requests.count == 1 }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(peerRunner.finish(
            runID: try XCTUnwrap(peerRunner.requests.first?.runId),
            status: .cancelled,
            reply: nil
        ))
        await milestone.value
    }

    func test_waitingOriginRosterShowsWorkingSpinner() async throws {
        // WHY: Ceo stayed Needs you in the roster while the transcript
        // already said Waiting for Bot. Both endpoints of a live wait
        // must show Working with the busy spinner.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.claude)
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) WAIT_SPINNER ask the peer"
        )
        let peerBecameActive = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("WAIT_SPINNER") }
                && vm.peerHandoffSnapshotsForTesting().contains { $0.phase == .peerRunning }
        }
        XCTAssertTrue(peerBecameActive, "the peer start must persist .peerRunning before roster is judged")
        XCTAssertEqual(vm.attentionState(for: piper), .working)
        XCTAssertEqual(vm.attentionState(for: quinn), .working)
        XCTAssertTrue(BotsChrome.rosterShowsBusySpinner(for: vm.attentionState(for: piper)))
        XCTAssertTrue(BotsChrome.rosterShowsBusySpinner(for: vm.attentionState(for: quinn)))
        XCTAssertTrue(peerRunner.finish(
            promptContaining: "WAIT_SPINNER",
            status: .cancelled,
            reply: nil
        ))
        await milestone.value
    }

    func test_sendWithMentionStoresPeerAvatar() async throws {
        // WHY: hop chrome used initials because BotDeskPeer dropped the
        // blobatar token. The peer row must carry the published symbol.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.codex, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        let milestone = try submitPeerHandoffForTesting(
            context: context,
            router: router,
            viewModel: vm,
            peer: quinn,
            prompt: "@\(quinn.handle) check WhatsApp"
        )
        let outbound = try XCTUnwrap(vm.deskMessages.last)
        XCTAssertEqual(outbound.peer?.avatarSymbol, quinn.avatarSymbol)
        XCTAssertFalse(outbound.peer?.avatarSymbol.isEmpty == true)
        let peerStarted = await waitUntil(timeout: 5) { peerRunner.requests.count == 1 }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(peerRunner.finish(
            runID: try XCTUnwrap(peerRunner.requests.first?.runId),
            status: .cancelled,
            reply: nil
        ))
        await milestone.value
    }

    func test_restoreDeskMessagesHidesHostHopPrompt() throws {
        // WHY: the host hop is an internal prompt. Restoring it as a user
        // bubble showed raw markdown ("Bot replied: **Nome:**") on Desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let thread = AgentThread(title: "Ask", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Pergunte ao bot seu nome",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: BotPeerTranscript.hostHopPrompt(
                peerName: "Bot",
                reply: "**Nome:** Bot\n**Cargo:** vazio",
                userText: "Pergunte ao bot seu nome"
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Pergunte ao bot seu nome", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskMessages.contains { $0.text == "Pergunte ao bot seu nome" })
        XCTAssertFalse(
            vm.deskMessages.contains { BotPeerTranscript.isHostHopUserText($0.text) },
            "internal hop prompt must not paint as a Desk bubble"
        )
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("**Nome:**") })
    }

    func test_openingAnotherThreadDoesNotKeepPreviousLiveTurns_becauseEachConversationOwnsItsThread() throws {
        // WHY: liveTimelineByBot kept a hop's Worked rows after the user
        // opened a new Desk thread on the same teammate.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)

        let mentionThread = AgentThread(title: "Mention", provider: .claude, model: "opus")
        let oiThread = AgentThread(title: "oi", provider: .claude, model: "opus")
        try context.threadRepo.upsert(mentionThread)
        try context.threadRepo.upsert(oiThread)
        let mentionRun = AgentRun(
            threadId: mentionThread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_040)
        )
        let oiRun = AgentRun(
            threadId: oiThread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_110),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_120)
        )
        try context.runRepo.upsert(mentionRun)
        try context.runRepo.upsert(oiRun)
        try persistStreamEvents(
            context: context,
            run: mentionRun,
            events: [
                .turnStarted(turnId: "mention-turn"),
                .itemStarted(item: AssistantItem(
                    id: "mention-tool",
                    turnId: "mention-turn",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1_700_000_010_000,
                    finishedAtMs: 1_700_000_020_000
                )),
                .turnCompleted(turnId: "mention-turn", finalMessage: "I'll treat this as a CEO test run"),
            ]
        )
        try persistStreamEvents(
            context: context,
            run: oiRun,
            events: [
                .turnStarted(turnId: "oi-turn"),
                .turnCompleted(turnId: "oi-turn", finalMessage: "Oi. Sou o Ceo."),
            ]
        )
        try context.messageRepo.append(AgentMessage(
            threadId: mentionThread.id,
            role: .user,
            content: "Pergunte ao bot",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.messageRepo.append(AgentMessage(
            threadId: oiThread.id,
            role: .user,
            content: "oi",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        ))
        let mentionConversation = BotConversation(
            botID: piper.id,
            title: "Pergunte ao bot",
            linkedAgentThreadID: mentionThread.id
        )
        let oiConversation = BotConversation(
            botID: piper.id,
            title: "oi",
            linkedAgentThreadID: oiThread.id
        )
        try context.botStore.upsertConversation(mentionConversation)
        try context.botStore.upsertConversation(oiConversation)

        vm.openDesk(piper)
        vm.selectDeskThread(mentionConversation.id)
        XCTAssertTrue(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "I'll treat this as a CEO test run" },
            "mention thread must replay its own live turn"
        )

        vm.selectDeskThread(oiConversation.id)
        XCTAssertFalse(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "I'll treat this as a CEO test run" },
            "oi must not inherit the mention thread's richer live timeline"
        )
        XCTAssertTrue(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "Oi. Sou o Ceo." }
        )
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("Pergunte") })
        XCTAssertTrue(vm.deskMessages.contains { $0.text == "oi" })
    }

    func test_deskTimelineKeepsEachTurnBesideItsUser_becauseChatIsNotTwoColumns() {
        // WHY: replay used Date() as turnStarted, so every Worked row sorted
        // to now and all user bubbles stacked on the right.
        let userName = BotDeskMessage(
            role: .user,
            text: "Qual seu nome?",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let userJob = BotDeskMessage(
            role: .user,
            text: "Qual sua função?",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let nameTurn = AssistantTurnSnapshot(
            turnId: "t-name",
            items: [
                AssistantItem(
                    id: "r-name",
                    turnId: "t-name",
                    type: .reasoning,
                    state: .completed,
                    body: "intro",
                    startedAtMs: 1_700_000_001_000,
                    finishedAtMs: 1_700_000_002_000
                ),
            ],
            finalAssistantMessage: "Meu nome é Batatilson.",
            finished: true,
            startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        let jobTurn = AssistantTurnSnapshot(
            turnId: "t-job",
            items: [
                AssistantItem(
                    id: "r-job",
                    turnId: "t-job",
                    type: .reasoning,
                    state: .completed,
                    body: "role",
                    startedAtMs: 1_700_000_101_000,
                    finishedAtMs: 1_700_000_102_000
                ),
            ],
            finalAssistantMessage: "Gerente de Marketing.",
            finished: true,
            startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        let items = BotsDeskFollowThrough.timeline(
            messages: [userName, userJob],
            workLog: [],
            turns: [nameTurn, jobTurn],
            hideWorkLog: true
        )
        XCTAssertEqual(items.count, 4)
        guard case .message(let first) = items[0], first.text == "Qual seu nome?" else {
            return XCTFail("first row must be the name question")
        }
        guard case .liveTurn(let firstTurn, _) = items[1], firstTurn.turnId == "t-name" else {
            return XCTFail("name turn must follow its user bubble, not sink to the bottom")
        }
        guard case .message(let second) = items[2], second.text == "Qual sua função?" else {
            return XCTFail("job question must come after the name turn")
        }
        guard case .liveTurn(let secondTurn, _) = items[3], secondTurn.turnId == "t-job" else {
            return XCTFail("job turn must follow its user bubble")
        }
    }

    func test_visibleDeskMessagesPrefersPersistedAssistantOverWorkingCache() {
        // WHY: follow-through must replace the local "Working…" bubble with
        // the linked thread's assistant reply or the user cannot review the result.
        let cached = [
            BotDeskMessage(role: .user, text: "Summarize overnight"),
            BotDeskMessage(role: .assistant, text: BotsDeskFollowThrough.workingPlaceholder),
        ]
        let persisted = [
            BotDeskMessage(role: .user, text: "Summarize overnight"),
            BotDeskMessage(role: .assistant, text: "Three failing tests remain."),
        ]
        let visible = BotsDeskFollowThrough.visibleDeskMessages(cached: cached, persisted: persisted)
        XCTAssertEqual(visible.last?.text, "Three failing tests remain.")
        XCTAssertFalse(visible.contains { $0.text == BotsDeskFollowThrough.workingPlaceholder })
    }

    func test_displayUserTextStripsProviderEnvelope_becauseTheDeskMustShowTheTeammateLine() {
        let envelope = """
        You are Piper — Scout.

        User request:

        Summarize overnight
        """
        XCTAssertEqual(BotsDeskFollowThrough.displayUserText(from: envelope), "Summarize overnight")
        XCTAssertEqual(BotsDeskFollowThrough.displayUserText(from: "Just the ask"), "Just the ask")
    }

    func test_composeRunPromptIncludesTrustedMemoryAndEnabledSkills() {
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "Looks around")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let live = BotMemoryFileText(path: "MEMORY.md", body: "Prefers dark mode")
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)

        let prompt = BotsDeskFollowThrough.composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memoryFiles: [live],
            skills: [enabled, disabled]
        )

        XCTAssertTrue(prompt.contains("Prefers dark mode"))
        XCTAssertTrue(prompt.contains("### MEMORY.md"))
        XCTAssertTrue(prompt.contains("Role: Scout"))
        XCTAssertFalse(prompt.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(prompt.contains("Instructions:"))
        XCTAssertFalse(prompt.contains("Standing instructions:"))
        XCTAssertFalse(prompt.contains("Skills: weekly-account-health"))
        XCTAssertFalse(prompt.contains("Enabled skills"))
        XCTAssertFalse(prompt.contains("off-skill"))
        XCTAssertTrue(prompt.contains("Summarize overnight"))
    }

    func test_previewBrainMatchesSendReceipt_becauseSourceEffectiveMustBeTheAdapterPayload() throws {
        // WHY: owner-readable Brain Inspector is false if Studio preview
        // compiles a different envelope than Desk send persists.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude
        )
        vm.openDesk(bot)
        try vm.botHome(for: bot).writeFile(
            relativePath: BotHome.memoryName,
            contents: "- Prefers dark mode\n"
        )
        vm.composerText = "Summarize overnight"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(preview.compiledPayload, BotsDeskFollowThrough.composeRunPrompt(
            bot: bot,
            revision: try XCTUnwrap(vm.selectedRevision),
            userText: "Summarize overnight",
            memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
            skills: vm.skillBindings,
            workspace: vm.advertisedWorkspace
        ))
        XCTAssertTrue(preview.compiledPayload.contains("Prefers dark mode"))
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .user })?.text, "Summarize overnight")
        XCTAssertEqual(preview.payloadDigest.count, 64)
        try context.botStore.insertContextReceipt(preview)
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(
            reopened.lastContextReceipt?.payloadDigest,
            preview.payloadDigest,
            "Brain receipts are workflow state and must survive remount"
        )
        XCTAssertEqual(reopened.lastContextReceipt?.compiledPayload, preview.compiledPayload)

        reopened.beginEdit(bot)
        reopened.studioDraft.soul = "Stand up for the brief."
        let studioPreview = try XCTUnwrap(reopened.inspectedBrain)
        XCTAssertTrue(reopened.inspectedBrainIsPreview)
        XCTAssertFalse(reopened.inspectedBrainIsLastCall)
        XCTAssertTrue(
            studioPreview.layers.contains { $0.kind == .soul && $0.text == "Stand up for the brief." },
            "Studio Brain must compile the draft, not the last Desk send"
        )
    }

    func test_sendDoesNotListInbox_becauseNeedsYouDestMustNotRereadQueue() throws {
        // WHY: Needs-you dest used to listAttention after dest already
        // painted the bubble. Dest already has this inbox row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "needs-you dest must not reread the inbox"
        )
    }

    func test_sendKeepsNeedsYouInbox_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first needs-you is honest only when dest still
        // shows this inbox row after the store write.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        XCTAssertEqual(vm.openAttentionCount, 1)
        XCTAssertEqual(vm.attentionItems.first?.title, "Bot could not start")
        XCTAssertEqual(vm.attentionItems.first?.detail, "Check the Bot's configuration, then send your request again.")
        XCTAssertEqual(try context.botStore.listAttention().count, 1)
        XCTAssertEqual(vm.deskMessages.last?.text, BotsViewModel.assistantPlaceholder)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_sendDoesNotListMemoryOrSkills_becauseSendDestMustNotRereadBrain() throws {
        // WHY: Send dest used to listMemory/listSkillBindings after dest
        // painted the bubble. Dest already has this teammate's brain.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        let afterDest = vm.memoryListCountForTesting
        let afterSkills = vm.skillListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        XCTAssertGreaterThan(afterSkills, 0)
        XCTAssertTrue(vm.send("Summarize overnight"))
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertTrue(vm.lastSendUsedDestBrainForTesting)
        XCTAssertEqual(
            vm.memoryListCountForTesting,
            afterDest,
            "send dest must not reread memory"
        )
        XCTAssertEqual(
            vm.skillListCountForTesting,
            afterSkills,
            "send dest must not reread skills"
        )
    }

    func test_sendAssemblesFromDestCache_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first send is honest only when dest facts compile
        // into the same payload preview already showed.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        try vm.botHome(for: piper).writeFile(
            relativePath: BotHome.memoryName,
            contents: "- Prefers dark mode\n"
        )
        vm.composerText = "Summarize overnight"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Prefers dark mode"))
        XCTAssertTrue(vm.send("Summarize overnight"))
        XCTAssertTrue(vm.lastSendUsedDestBrainForTesting)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Summarize overnight",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                workspace: vm.advertisedWorkspace
            ),
            preview.compiledPayload
        )
    }

    func test_sendDoesNotListConversations_becausePersistDestMustNotRereadThreads() throws {
        // WHY: Persist dest used to listConversations after dest painted
        // the bubble. Dest already has this teammate's thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let afterDest = vm.conversationListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        XCTAssertTrue(vm.send("Summarize overnight"))
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(vm.selectedConversation?.botID, piper.id)
        XCTAssertEqual(
            vm.conversationListCountForTesting,
            afterDest,
            "persist dest must not reread every thread"
        )
    }

    func test_sendKeepsDestConversation_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first persist is honest only when dest still shows
        // this teammate's thread after the store write.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("First brief"))
        let thread = try XCTUnwrap(vm.selectedConversation)
        let afterFirst = vm.conversationListCountForTesting
        XCTAssertTrue(vm.send("Second brief"))
        XCTAssertEqual(vm.selectedConversation?.id, thread.id)
        XCTAssertEqual(vm.conversations.map(\.id), [thread.id])
        XCTAssertEqual(vm.deskMessages.first?.text, "First brief")
        XCTAssertTrue(vm.deskMessages.contains(where: { $0.text == "Second brief" }))
        XCTAssertEqual(vm.conversationListCountForTesting, afterFirst)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_followThroughDoesNotReloadFleet_becauseSettleDestMustNotScanEveryTeammate() throws {
        // WHY: Follow-through dest used to reloadFleet (every teammate's
        // conversations + recent messages) after dest already painted the
        // completed turn. Dest already has this thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        let conversation = try XCTUnwrap(vm.selectedConversation)
        XCTAssertEqual(conversation.botID, piper.id)
        XCTAssertEqual(vm.fleet.map(\.name).sorted(), ["Piper", "Quinn"])
        let afterDest = vm.fleetReloadCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.applyFollowThroughForTests(bot: piper, conversation: conversation, status: .completed)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.selectedConversation?.id, conversation.id)
        XCTAssertEqual(vm.selectedConversation?.botID, piper.id)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterDest,
            "settle dest must not scan every teammate"
        )
        XCTAssertEqual(vm.fleet.map(\.name).sorted(), ["Piper", "Quinn"])
    }

    func test_followThroughKeepsDestConversation_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first settle is honest only when dest still shows
        // this teammate's thread, and a background teammate's store
        // row stays the dest thread dest already wrote.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("First brief"))
        let destThread = try XCTUnwrap(vm.selectedConversation)
        XCTAssertEqual(destThread.botID, piper.id)
        vm.openDesk(quinn)
        let afterSwitch = vm.fleetReloadCountForTesting
        vm.applyFollowThroughForTests(bot: piper, conversation: destThread, status: .completed)
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertNotEqual(vm.selectedConversation?.botID, piper.id)
        XCTAssertTrue(
            try context.botStore.listConversations(botID: piper.id)
                .contains(where: { $0.id == destThread.id }),
            "dest-first settle must keep the dest thread dest already wrote"
        )
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterSwitch,
            "background settle dest must not scan every teammate"
        )
    }

    func test_followThroughDoesNotListConversations_becauseSettleDestMustNotRereadThreads() throws {
        // WHY: Settle dest used to listConversations after dest already
        // dested Chat — including when dest dested another teammate.
        // Dest already has this thread from persist dest.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        let destThread = try XCTUnwrap(vm.selectedConversation)
        XCTAssertEqual(destThread.botID, piper.id)
        vm.openDesk(quinn)
        let afterDest = vm.conversationListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.applyFollowThroughForTests(bot: piper, conversation: destThread, status: .completed)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertNotEqual(vm.selectedConversation?.botID, piper.id)
        XCTAssertEqual(
            vm.conversationListCountForTesting,
            afterDest,
            "settle dest must not reread dest threads"
        )
        XCTAssertTrue(
            try context.botStore.listConversations(botID: piper.id)
                .contains(where: { $0.id == destThread.id })
        )
    }

    func test_hiddenBotsAreExcludedFromDefaultFleet() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", handle: "piper", provider: .claude)
        XCTAssertEqual(vm.fleet.map(\.id), [bot.id])

        vm.setHidden(id: bot.id, hidden: true)

        XCTAssertTrue(vm.fleet.isEmpty, "hidden bots must not appear in the default fleet")
        XCTAssertTrue(try context.botStore.list().isEmpty)
        XCTAssertEqual(try context.botStore.list(includeHidden: true).map(\.id), [bot.id])

        vm.showHidden = true
        XCTAssertEqual(vm.fleet.map(\.id), [bot.id])
    }

    func test_saveStudioPublishesOneRevision_becauseBrainEditsAreVersioned() throws {
        // WHY: Studio Save is a publish, not a silent profile mutate. A second
        // updateProfile revision would make the digest history unreadable.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude
        )
        let first = try XCTUnwrap(bot.currentRevisionID)
        vm.beginEdit(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .profile)
        vm.studioDraft.title = "Research lead"
        vm.studioDraft.soul = "Stand up for the brief."
        vm.studioDraft.notificationsEnabled = false

        let saved = try vm.saveStudio()

        XCTAssertEqual(vm.screen, .studio, "Save stays in Studio so Brain tabs remain reachable")
        XCTAssertNotEqual(saved.currentRevisionID, first)
        XCTAssertEqual(vm.studioDraft.expectedRevisionID, saved.currentRevisionID)
        let revision = try XCTUnwrap(vm.selectedRevision)
        XCTAssertEqual(revision.revisionNumber, 2)
        XCTAssertEqual(revision.title, "Research lead")
        XCTAssertEqual(revision.soul, "Stand up for the brief.")
        XCTAssertEqual(revision.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(saved.notificationsEnabled, false)
        XCTAssertEqual(vm.studioDesktopSummary, BotDesktopKind.logicalExecutionSpace.displayTitle)
        XCTAssertEqual(vm.studioApprovalLabel, "Supervised")
    }

    func test_botCreateAndSaveDoNotPersistProviderOrModel() throws {
        // WHY: provider/model belong to the user's execution thread. Neither
        // creating nor publishing Bot identity may add a hidden route field.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertTrue(vm.providers.isEmpty)

        let created = try vm.create(name: "Quinn")
        let createdRevision = try XCTUnwrap(
            try context.botStore.getRevision(id: try XCTUnwrap(created.currentRevisionID))
        )
        let createdObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(createdRevision)) as? [String: Any]
        )
        XCTAssertNil(createdObject["provider"])
        XCTAssertNil(createdObject["providerInstanceID"])
        XCTAssertNil(createdObject["model"])

        vm.beginEdit(created)
        let saved = try vm.saveStudio()
        let savedRevision = try XCTUnwrap(
            try context.botStore.getRevision(id: try XCTUnwrap(saved.currentRevisionID))
        )
        let savedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(savedRevision)) as? [String: Any]
        )
        XCTAssertNil(savedObject["provider"])
        XCTAssertNil(savedObject["providerInstanceID"])
        XCTAssertNil(savedObject["model"])
    }

    func test_addSkillRejectsPathWithStudioCopy_becauseStoreErrorMustNotReachTheUser() throws {
        // WHY: BotStore already rejects "/", but Add showed "Invalid bot row: …"
        // instead of the Studio caption the tab already paints.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.skillDraft = "/tmp/not-a-skill.md"
        vm.addSkill()
        XCTAssertEqual(
            vm.errorMessage,
            "Catalog ids only. A skill id is not a filesystem path."
        )
        XCTAssertTrue(vm.skillBindings.isEmpty)
        XCTAssertEqual(vm.skillDraft, "/tmp/not-a-skill.md")
        XCTAssertTrue(try context.botStore.listSkillBindings(botID: bot.id).isEmpty)
    }

    func test_studioSkillsPersistAsCatalogBindings_becauseStudioOwnsTheBrain() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioTab = .files
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()

        XCTAssertEqual(vm.skillBindings.map(\.skillID), ["weekly-account-health"])
        XCTAssertEqual(vm.enabledSkillCount, 1)
        vm.setSkillEnabled(skillID: "weekly-account-health", enabled: false)
        XCTAssertEqual(vm.enabledSkillCount, 0)
        XCTAssertEqual(
            try context.botStore.listSkillBindings(botID: bot.id).first?.enabled,
            false
        )
    }

    func test_addSkillDoesNotListSkills_becauseAddDestMustNotRereadBindings() throws {
        // WHY: Add dest used to listSkillBindings after the store wrote
        // this binding. Dest must not reread every skill.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        let afterStudio = vm.skillListCountForTesting
        XCTAssertGreaterThan(afterStudio, 0)
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.skillBindings.first?.skillID, "weekly-account-health")
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first).enabled)
        XCTAssertTrue(vm.skillDraft.isEmpty)
        XCTAssertEqual(vm.enabledSkillCount, 1)
        XCTAssertEqual(
            vm.skillListCountForTesting,
            afterStudio,
            "add dest must not reread every skill"
        )
        XCTAssertEqual(
            try context.botStore.listSkillBindings(botID: piper.id).map(\.skillID),
            ["weekly-account-health"]
        )
    }

    func test_addSkillKeepsExistingSkills_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first add is honest only when older bindings stay
        // visible and the new row paints first.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: piper.id, skillID: "older-skill", enabled: true)
        )
        vm.beginEdit(piper)
        XCTAssertEqual(vm.skillBindings.map(\.skillID), ["older-skill"])
        let afterStudio = vm.skillListCountForTesting
        vm.skillDraft = "newer-skill"
        vm.addSkill()
        XCTAssertEqual(vm.skillBindings.first?.skillID, "newer-skill")
        XCTAssertEqual(
            Set(vm.skillBindings.map(\.skillID)),
            Set(["newer-skill", "older-skill"])
        )
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first { $0.skillID == "older-skill" }).enabled)
        XCTAssertEqual(vm.skillListCountForTesting, afterStudio)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertTrue(vm.skillDraft.isEmpty)
    }

    func test_setSkillEnabledDoesNotListSkills_becauseEnableDestMustNotRereadBindings() throws {
        // WHY: Enable dest used to listSkillBindings after the store wrote
        // this binding. Dest must not reread every skill.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first).enabled)
        let afterAdd = vm.skillListCountForTesting
        XCTAssertGreaterThan(afterAdd, 0)
        vm.setSkillEnabled(skillID: "weekly-account-health", enabled: false)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.skillBindings.first?.skillID, "weekly-account-health")
        XCTAssertFalse(try XCTUnwrap(vm.skillBindings.first).enabled)
        XCTAssertEqual(vm.enabledSkillCount, 0)
        XCTAssertEqual(
            vm.skillListCountForTesting,
            afterAdd,
            "enable dest must not reread every skill"
        )
        XCTAssertEqual(
            try context.botStore.listSkillBindings(botID: piper.id).first?.enabled,
            false
        )
    }

    func test_setSkillEnabledKeepsExistingSkills_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first enable is honest only when older bindings stay
        // visible and only this row flips On/Off.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: piper.id, skillID: "older-skill", enabled: true)
        )
        vm.beginEdit(piper)
        vm.skillDraft = "newer-skill"
        vm.addSkill()
        let afterAdd = vm.skillListCountForTesting
        vm.setSkillEnabled(skillID: "newer-skill", enabled: false)
        XCTAssertEqual(
            Set(vm.skillBindings.map(\.skillID)),
            Set(["newer-skill", "older-skill"])
        )
        XCTAssertFalse(try XCTUnwrap(vm.skillBindings.first { $0.skillID == "newer-skill" }).enabled)
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first { $0.skillID == "older-skill" }).enabled)
        XCTAssertEqual(vm.enabledSkillCount, 1)
        XCTAssertEqual(vm.skillListCountForTesting, afterAdd)
        vm.setSkillEnabled(skillID: "newer-skill", enabled: true)
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first { $0.skillID == "newer-skill" }).enabled)
        XCTAssertEqual(vm.enabledSkillCount, 2)
        XCTAssertEqual(vm.skillListCountForTesting, afterAdd)
        XCTAssertEqual(vm.screen, .studio)
    }

    func test_studioHasNoSkillToggle_becauseSkillsNowLiveInFiles() throws {
        // WHY: Skills moved to Files. A leftover binding toggle would recreate
        // the duplicate Off/On control and split the source of truth.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("private var skillsTab"))
        XCTAssertFalse(source.contains("Toggle(binding.enabled ? \"On\" : \"Off\""))
    }

    func test_removeSkillDoesNotListSkills_becauseRemoveDestMustNotRereadBindings() throws {
        // WHY: Remove dest must drop the row without listing every skill,
        // or the Skills tab looks current only after a reread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        let afterAdd = vm.skillListCountForTesting
        vm.removeSkill(skillID: "weekly-account-health")
        XCTAssertTrue(vm.skillBindings.isEmpty)
        XCTAssertEqual(vm.enabledSkillCount, 0)
        XCTAssertEqual(
            vm.skillListCountForTesting,
            afterAdd,
            "remove dest must not reread every skill"
        )
        XCTAssertTrue(try context.botStore.listSkillBindings(botID: piper.id).isEmpty)
    }

    func test_removeSkillKeepsExistingSkills_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first remove is honest only when the other bindings stay
        // visible after this catalog id leaves the list.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: piper.id, skillID: "keep-me", enabled: true)
        )
        vm.beginEdit(piper)
        vm.skillDraft = "drop-me"
        vm.addSkill()
        let afterAdd = vm.skillListCountForTesting
        vm.removeSkill(skillID: "drop-me")
        XCTAssertEqual(vm.skillBindings.map(\.skillID), ["keep-me"])
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first).enabled)
        XCTAssertEqual(vm.skillListCountForTesting, afterAdd)
        XCTAssertEqual(
            try context.botStore.listSkillBindings(botID: piper.id).map(\.skillID),
            ["keep-me"]
        )
    }

    func test_studioDoesNotPersistDedicatedLocalVM_becauseItIsNotAdvertised() throws {
        // WHY: Product must not advertise Dedicated local VM. A leftover draft
        // kind must fall back to logical space instead of publishing a hidden mode.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioDraft.desktopKind = .dedicatedLocalVM
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.studioDesktopSummary, BotDesktopKind.logicalExecutionSpace.displayTitle)
        XCTAssertEqual(vm.desktopHonestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)

        let saved = try vm.saveStudio()
        let revision = try XCTUnwrap(
            saved.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(revision.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.desktopHonestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)

        vm.openDesk(saved)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertTrue(vm.desktopHonestyLabel.localizedCaseInsensitiveContains("not isolated"))
    }

    func test_sharedVMDestinationShowsVMDesktopEvenWhenRevisionSnapshotIsLogical() throws {
        // WHY: the host-owned shared VM destination must drive the Desk pane even
        // when the cached revision snapshot still says logical (out-of-process publish).
        let context = try makeContext()
        let bot = try context.botStore.create(
            name: "Piper",
            title: "Scout",
            description: "",
            provider: .claude,
            desktopKind: .logicalExecutionSpace
        )
        let machine = try context.botStore.saveVirtualMachine(name: "Research")
        try context.botStore.writeExecutionDestination(.virtualMachine(machine.id), botID: bot.id)

        let vm = BotsViewModel(context: context)
        vm.openDesk(bot)
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.displayedDesktopKind, .dockerDesktop)
        XCTAssertEqual(vm.desktopStatusPill, BotDesktopKind.dockerDesktop.statusPill)
    }

    func test_leftoverStoredDedicatedLocalVMDisplaysAndPublishesAsLogical() throws {
        // WHY: Existing revisions may still store dedicatedLocalVM. Opening and
        // saving must not keep that kind as the live desktop.
        let context = try makeContext()
        let leftover = try context.botStore.create(
            name: "Piper",
            title: "Scout",
            description: "",
            provider: .claude,
            desktopKind: .dedicatedLocalVM
        )
        let stored = try XCTUnwrap(
            leftover.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(stored.desktopKind, .dedicatedLocalVM)

        let vm = BotsViewModel(context: context)
        vm.openDesk(leftover)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.desktopHonestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)
        XCTAssertEqual(vm.desktopStatusPill, BotDesktopKind.logicalExecutionSpace.statusPill)

        vm.beginEdit(leftover)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        let saved = try vm.saveStudio()
        let published = try XCTUnwrap(
            saved.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(published.desktopKind, .logicalExecutionSpace)
        XCTAssertFalse(vm.studioHasUnpublishedChanges)
    }

    func test_leftoverStudioDraftDesktopDoesNotKeepDraftPill_becauseDedicatedLocalVMIsNotAdvertised() throws {
        // WHY: Persist used to keep dedicatedLocalVM on the draft after Save
        // published logical space, so Studio showed Draft with no user edit.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioDraft.desktopKind = .dedicatedLocalVM
        XCTAssertFalse(vm.studioHasUnpublishedChanges)
        _ = try vm.saveStudio()
        XCTAssertEqual(vm.studioDraft.desktopKind, .logicalExecutionSpace)
        XCTAssertFalse(vm.studioHasUnpublishedChanges)

        let reopened = BotsViewModel(context: context)
        reopened.openStudio(bot)
        XCTAssertEqual(reopened.studioDraft.desktopKind, .logicalExecutionSpace)
        XCTAssertFalse(reopened.studioHasUnpublishedChanges)
    }

    func test_newStudioBotDesktopIsLogicalExecutionSpace() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.studioDraft.name = "Nova"
        vm.studioDraft.title = "Scout"

        let created = try vm.saveStudio()
        let revision = try XCTUnwrap(
            created.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(revision.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.studioDesktopSummary, BotDesktopKind.logicalExecutionSpace.displayTitle)
    }

    func test_studioDoesNotPersistManagedRemoteMac_becauseItIsNotAdvertised() throws {
        // WHY: Product must not advertise Managed remote Mac. A leftover draft
        // kind must fall back to logical space instead of publishing a hidden mode.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioDraft.desktopKind = .managedRemoteMac
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)

        let saved = try vm.saveStudio()
        let revision = try XCTUnwrap(
            saved.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(revision.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
    }

    func test_memoryTabHeaderSaysMemory_becauseMemoryMustNotNameTheBrainSiblingTab() throws {
        // WHY: Memory left Studio as a tab. A leftover "Brain / Memory"
        // header would still claim memory lives under Brain.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(
            source.contains("\"Brain / Memory\""),
            "Memory's header must not name the Brain sibling tab"
        )
        XCTAssertFalse(
            source.contains("private var memoryTab"),
            "Memory lives in Files, not a Studio tab body"
        )
    }

    func test_studioProfileHasNoProviderRouting() throws {
        // WHY: a published Default route locked teammates to one provider.
        // Studio Profile is identity + instructions. Account is the Desk
        // composer, per send.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("private var studioProvider"))
        XCTAssertFalse(source.contains("bots.studio.provider"))
        XCTAssertFalse(source.contains("bots.studio.routing"))
        XCTAssertFalse(source.contains("BotsChrome.Label.providerRouting"))
        let chrome = try String(contentsOf: sourceURL("Sources/AppShell/BotsChrome.swift"), encoding: .utf8)
        XCTAssertFalse(chrome.contains("Provider routing"))
    }

    func test_avatarSymbolNameIsHuman_becauseStudioMustNotAnnounceSFSymbolPaths() {
        XCTAssertEqual(
            BotsChrome.avatarSymbolName("person.crop.circle"),
            "Person",
            "VoiceOver on a leftover SF chip must say Person, not person.crop.circle"
        )
        XCTAssertEqual(
            BotsChrome.avatarSymbolName("blobatar:v1:cloud:idle:none:auto"),
            "Cloud",
            "VoiceOver on a blobatar must say Cloud, not the token"
        )
        for symbol in BotsChrome.avatarSymbols {
            XCTAssertFalse(
                BotsChrome.avatarSymbolName(symbol).contains("."),
                "\(symbol) must not leak an SF Symbol path into the Avatar name"
            )
        }
    }

    func test_studioAvatarPickerIsBlobatar_becauseStudioLetsTheUserComposeTheCreature() throws {
        // WHY: Studio Avatar used to be eight SF chips. The owner now
        // composes shape and hue on the right pane. Expression follows
        // live attention; the creature never has a plate.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let editor = try String(contentsOf: sourceURL("Sources/AppShell/BotsBlobatarView.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("BotBlobatarEditor"))
        XCTAssertTrue(bots.contains("studioAvatarPane"))
        XCTAssertTrue(bots.contains("bots.studio.avatar.pane"))
        XCTAssertTrue(bots.contains("BotBlobatarSpec.default.token"))
        XCTAssertTrue(editor.contains("bots.studio.avatar.shape"))
        XCTAssertFalse(editor.contains("bots.studio.avatar.expression"))
        XCTAssertFalse(editor.contains("bots.studio.avatar.background"))
        XCTAssertTrue(editor.contains("bots.studio.avatar.hue"))
        XCTAssertTrue(editor.contains("BotBlobatarShape.allCases"))
        XCTAssertTrue(editor.contains("bots.studio.avatar.shape.\\(shape.rawValue)"))
        XCTAssertFalse(
            bots.contains("studioField(placeholder: \"person.crop.circle\""),
            "users must not type person.crop.circle to set an Avatar"
        )
    }

    func test_botsOpensInMainContent_andSidebarSitsUnderScheduleTasks() throws {
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let chrome = try String(contentsOf: sourceURL("Sources/AppShell/BotsChrome.swift"), encoding: .utf8)
        let types = try String(contentsOf: sourceURL("Sources/CoreModel/BotTypes.swift"), encoding: .utf8)
        let chatChrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatTranscriptChrome.swift"), encoding: .utf8)

        XCTAssertTrue(main.contains("presentBotsInMainContent"))
        XCTAssertTrue(main.contains("installBotsContent"))
        XCTAssertTrue(main.contains("shell.botsSelected"))
        XCTAssertTrue(main.contains("restoreBotsShellDestinationIfNeeded"))
        XCTAssertFalse(
            main.contains("vm.openFleet()"),
            "remounting Bots must keep Desk/Studio, not force Fleet Home"
        )
        XCTAssertTrue(main.contains("case bots"))
        XCTAssertTrue(main.contains("let title = sidebar.botsViewModel.chromeTitle"))
        XCTAssertTrue(main.contains("visibleWorkspaceLabel.stringValue = title"))
        XCTAssertTrue(sidebar.contains("isBotsSelected"))
        XCTAssertTrue(sidebar.contains("setBotsSelected"))
        XCTAssertFalse(sidebar.contains("sidebar.manageBots"), "the Manage Bots and Teams footer is gone")
        XCTAssertFalse(sidebar.contains("BotsModeSwitcher"), "the Workspaces | Bots mode toggle is gone")
        XCTAssertFalse(bots.contains("bots.chrome.agentic"))
        XCTAssertFalse(main.contains("showsCatalogRail"), "the main shell shows no roster column beside Bots content")
        XCTAssertFalse(bots.contains("bots.fleet.row."), "Fleet Home row is not a destination")
        XCTAssertFalse(bots.contains("accessibilityIdentifier(\"bots.roster\")"), "no roster rail in the shell")
        XCTAssertFalse(bots.contains("accessibilityIdentifier(\"bots.home\")"))
        XCTAssertFalse(bots.contains("bots.home.chat"))
        XCTAssertFalse(bots.contains("bots.home.studio"))
        XCTAssertFalse(bots.contains("bots.home.desktop"))
        XCTAssertFalse(bots.contains("bots.home.activity"))
        XCTAssertFalse(bots.contains("bots.home.memory"))
        XCTAssertFalse(bots.contains("bots.home.skills"))
        XCTAssertFalse(bots.contains("bots.home.routines"))
        XCTAssertFalse(bots.contains("bots.home.approvals"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.studio\")"))
        XCTAssertTrue(bots.contains("bots.studio.tab.profile"))
        XCTAssertTrue(bots.contains("bots.studio.tab.brain"))
        XCTAssertTrue(
            bots.contains("ForEach(BotStudioTab.allCases.filter(\\.isUserFacing))"),
            "Brain stays on the enum for leftover persist; the Studio strip must not render it"
        )
        XCTAssertFalse(bots.contains("bots.studio.tab.memory"))
        XCTAssertFalse(bots.contains("bots.studio.tab.skills"))
        XCTAssertTrue(bots.contains("bots.studio.tab.routines"))
        XCTAssertFalse(
            bots.contains("bots.studio.tab.desktop"),
            "Desktop merged into the Security tab; a seventh tab must not come back"
        )
        XCTAssertTrue(bots.contains("bots.studio.tab.security"))
        XCTAssertTrue(
            bots.contains("bots.studio.desktop"),
            "the read-only Desktop card still ships inside the Security tab"
        )
        XCTAssertFalse(bots.contains("bots.home.goal"))
        XCTAssertTrue(bots.contains("accessibilityAddTraits(selected ? .isSelected : [])"))
        XCTAssertTrue(bots.contains("BotsChrome.hitTarget"))
        XCTAssertEqual(BotStudioTab.allCases.map(\.id), ["profile", "brain", "files", "routines", "security"])
        XCTAssertEqual(
            BotStudioTab.allCases.filter(\.isUserFacing).map(\.id),
            ["profile", "files", "routines", "security"]
        )
        XCTAssertEqual(
            BotDeskInspectorTab.allCases.filter(\.isUserFacing).map(\.id),
            ["routines"]
        )
        XCTAssertTrue(chrome.contains(BotsChrome.Label.agentic))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.currentGoal))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.todaysActivity))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.nextRoutine))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.myBots))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.openChat))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.saveBot))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.instructions))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.security))
        XCTAssertTrue(bots.contains("bots.studio.identity"))
        XCTAssertFalse(bots.contains("bots.studio.routing"))
        XCTAssertTrue(bots.contains("bots.studio.soul"))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.descriptionCaption))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.instructionsCaption))
        XCTAssertTrue(bots.contains("BotsChrome.Label.descriptionCaption"))
        XCTAssertTrue(bots.contains("BotsChrome.Label.instructionsCaption"))
        XCTAssertTrue(
            bots.contains("Empty uses the built-in teammate default")
                || chrome.contains("Empty uses the built-in teammate default")
        )
        XCTAssertTrue(
            BotsChrome.Label.descriptionCaption.contains("Who this teammate is"),
            "Description must say who, not how"
        )
        XCTAssertTrue(
            BotsChrome.Label.instructionsCaption.contains("How this teammate should work"),
            "Instructions must say how, not who"
        )
        XCTAssertTrue(bots.contains("refreshGeneratedStandingInstructions"))
        XCTAssertTrue(
            bots.contains(".accessibilityLabel(BotsChrome.Label.instructions)"),
            "Soul TextArea must name Instructions the way Description names Description"
        )
        XCTAssertFalse(
            bots.contains("Remember a fact"),
            "Memory CRUD left Studio; facts live in MEMORY.md"
        )
        XCTAssertFalse(
            bots.contains("bots.memory.correct.field"),
            "Correct memory left Studio; edit MEMORY.md in Files"
        )
        XCTAssertFalse(
            bots.contains("NSAlert()"),
            "Correct memory must not come back as a modal alert"
        )
        XCTAssertFalse(
            bots.contains(".accessibilityLabel(\"Skill catalog id\")"),
            "Skills catalog Add left Studio; skills live in skills/<slug>/SKILL.md"
        )
        XCTAssertFalse(
            bots.contains(".accessibilityLabel(binding.skillID)"),
            "Skills enable switch left Studio; skills live in Files"
        )
        XCTAssertTrue(
            bots.contains(".accessibilityLabel(\"Active, \\(routine.definition.name)\")"),
            "Routines Active switch must say Active plus the routine name, not only the title"
        )
        let labeledField = try XCTUnwrap(bots.range(of: "private func labeledField<Content: View>"))
        let labeledFieldTail = bots[labeledField.lowerBound...]
        let labeledFieldEnd = labeledFieldTail.range(of: "\n    private func studioField")?.lowerBound
            ?? labeledFieldTail.endIndex
        let labeledFieldSource = String(bots[labeledField.lowerBound..<labeledFieldEnd])
        XCTAssertTrue(labeledFieldSource.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(
            labeledFieldSource.contains(".accessibilityLabel(label)"),
            "labeledField must name the control the way studioFormRow does"
        )
        XCTAssertTrue(bots.contains("bots.studio.avatar.pane"))
        XCTAssertFalse(bots.contains("bots.studio.summary"))
        XCTAssertTrue(bots.contains("bots.studio.desktop.honesty"))
        XCTAssertTrue(
            bots.contains("BotsChrome.Label.roleAndIdentity") || chrome.contains("Role & Identity"),
            "Studio Profile header must use the Role & Identity token"
        )
        XCTAssertFalse(
            bots.contains("BotsChrome.Label.providerRouting") || chrome.contains("Provider routing"),
            "Studio must not mention a published provider"
        )
        XCTAssertTrue(
            bots.contains("studioAvatarPane"),
            "Studio Profile right pane must be the avatar, not Configuration summary"
        )
        XCTAssertFalse(
            bots.contains("AgentChatTranscriptChrome.composerPlaceholder("),
            "Bots Desk must not reuse the Agent App Ask <provider> for changes placeholder"
        )
        XCTAssertTrue(bots.contains("applyIncomingDeskEvent"))
        let liveChrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatLiveTurnChrome.swift"), encoding: .utf8)
        XCTAssertTrue(liveChrome.contains("bots.desk.thought"))
        XCTAssertTrue(liveChrome.contains("Thinking…"))
        XCTAssertTrue(liveChrome.contains("Work so far"))
        XCTAssertTrue(bots.contains("stopDeskRun"))
        XCTAssertTrue(bots.contains("attachments: attached") || bots.contains("attachments: attached,"))
        XCTAssertTrue(bots.contains("attachmentStore().stage"))
        XCTAssertTrue(chatChrome.contains("agent.attach"))
        XCTAssertTrue(chatChrome.contains("agent.workingPhase"))
        XCTAssertTrue(chatChrome.contains("agent.composer.stop"))
        XCTAssertTrue(chatChrome.contains("accessibilityIdentifier(composerIdentifier)"))
        XCTAssertTrue(chatChrome.contains("\"bots.desk.composer\""))
        XCTAssertTrue(chatChrome.contains("arrow.up"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk\")"))
        XCTAssertTrue(bots.contains("AgentAppView("), "Desk must reuse Agent App, not fork its transcript")
        XCTAssertTrue(bots.contains("showsThreadRail: false"), "Desk embeds Agent App with the thread rail hidden")
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.timeline\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.desktop\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.desktop.honesty\")"))
        XCTAssertTrue(
            bots.contains("bots.desk.desktop.guestScreen"),
            "Docker GUI must expose the live screen in the inspector desktop pane"
        )
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.name\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.handle\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.job\")"))
        XCTAssertFalse(bots.contains("accessibilityIdentifier(\"bots.desk.provider\")"))
        XCTAssertTrue(bots.contains("\"bots.desk.permission\""))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.inspector\")"))
        XCTAssertTrue(bots.contains("bots.studio.tab.brain"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.tab.brain"))
        XCTAssertFalse(
            bots.contains("ForEach(BotDeskInspectorTab.allCases"),
            "A single user-facing tab must render as a header, not a dead one-chip strip"
        )
        XCTAssertTrue(
            bots.contains("Text(resolvedInspectorTab.title)"),
            "The Desk inspector header must resolve through the leftover-persist remap"
        )
        XCTAssertFalse(bots.contains("bots.desk.inspector.tab.memory"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.tab.routines"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.brain"))
        XCTAssertFalse(bots.contains("bots.desk.inspector.memory"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.routines"))
        XCTAssertTrue(bots.contains("bots.brain.honesty"))
        XCTAssertTrue(bots.contains("bots.brain.source"))
        XCTAssertTrue(bots.contains("bots.brain.effective"))
        XCTAssertTrue(bots.contains("bots.brain.whyMemory"))
        XCTAssertTrue(bots.contains("bots.brain.digest"))
        XCTAssertFalse(bots.contains("bots.memory.field"))
        XCTAssertFalse(bots.contains("bots.memory.add"))
        XCTAssertFalse(bots.contains("bots.memory.list"))
        XCTAssertFalse(bots.contains("bots.memory.correct"))
        XCTAssertFalse(bots.contains("bots.memory.forget"))
        XCTAssertFalse(bots.contains("bots.studio.skills.remove"))
        XCTAssertTrue(bots.contains("BotScheduleTasksRootView(vm: vm, scopeBotID:"))
        let scheduleTasksSource = try String(contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(scheduleTasksSource.contains("bots.scheduleTasks.editor.name"))
        XCTAssertTrue(scheduleTasksSource.contains("bots.scheduleTasks.editor.instruction"))
        XCTAssertTrue(scheduleTasksSource.contains("bots.scheduleTasks.editor.spec"))
        XCTAssertTrue(scheduleTasksSource.contains("bots.scheduleTasks.editor.active"))
        XCTAssertTrue(scheduleTasksSource.contains("bots.scheduleTasks.new"))
        XCTAssertTrue(scheduleTasksSource.contains("BotRoutineCopy.testRunHonestyCaption"))
        XCTAssertTrue(bots.contains("bots.routines.active"))
        XCTAssertFalse(bots.contains("BotDetailTab"))
        XCTAssertFalse(bots.contains("detailTab = .desk"))
        XCTAssertTrue(bots.contains("BOT ROSTER") || chrome.contains("BOT ROSTER"))
        XCTAssertTrue(bots.contains(BotsChrome.Label.agentic) || chrome.contains(BotsChrome.Label.agentic))
        XCTAssertTrue(bots.contains(BotsChrome.Label.currentGoal) || chrome.contains(BotsChrome.Label.currentGoal))
        XCTAssertTrue(bots.contains(BotsChrome.Label.todaysActivity) || chrome.contains(BotsChrome.Label.todaysActivity))
        XCTAssertTrue(bots.contains(BotsChrome.Label.nextRoutine) || chrome.contains(BotsChrome.Label.nextRoutine))
        for label in BotsChrome.allVisibleLabels {
            XCTAssertTrue(
                chrome.contains(label) || bots.contains(label) || types.contains(label),
                "shipped Bots chrome must show \(label)"
            )
        }
        XCTAssertFalse(bots.contains("Take over"))
        XCTAssertFalse(bots.contains("Dedicated macOS VM"))
        XCTAssertFalse(bots.contains("Active now in macOS VM"))
        XCTAssertFalse(bots.contains("Managed remote Mac Desktop"))
        let settings = try String(contentsOf: sourceURL("Sources/AppShell/SettingsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(settings.contains("Managed remote Mac Desktop"))
        XCTAssertFalse(settings.contains("settings.bots.desktopRemote.toggle"))
        XCTAssertFalse(main.contains("SurfaceType.bot"))
        XCTAssertFalse(bots.contains("SurfaceType.bot"))
        XCTAssertTrue(
            bots.contains("BotBlobatarEditor"),
            "Studio Avatar is the blobatar composer, not a leftover SF chip row"
        )
        XCTAssertFalse(
            bots.contains("studioField(placeholder: \"person.crop.circle\""),
            "users must not type person.crop.circle to set an Avatar"
        )

        let scheduleTasks = try XCTUnwrap(sidebar.range(of: "accessibilityIdentifier(\"sidebar.scheduleTasks\")"))
        let reportBug = try XCTUnwrap(sidebar.range(of: "accessibilityIdentifier(\"sidebar.reportBug\")"))
        XCTAssertLessThan(reportBug.lowerBound, scheduleTasks.lowerBound,
                          "Report Bug is a header icon, not a dest row under Schedule Tasks")
        XCTAssertTrue(
            sidebar.contains("accessibilityIdentifier(\"sidebar.new\")"),
            "Bots are created from the New menu in the unified sidebar"
        )
    }

    func test_emptyDeskGroupsNewBotWithCopy_becauseAFooterPrimaryLooksOrphaned() throws {
        // WHY: DSEmptyState used to fill the pane, so New Bot sat on the
        // window bottom as a stock filled pill. The CTA belongs under the
        // empty-state copy, in DS chrome, with the same plus-person mark
        // as the sidebar row.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = bots.range(of: "private var emptyDesk: some View") else {
            return XCTFail("emptyDesk must exist")
        }
        let rest = bots[start.lowerBound...]
        guard let end = rest.range(of: "\n    @ViewBuilder\n    private func attentionBadge") else {
            return XCTFail("emptyDesk must end before attentionBadge")
        }
        let body = String(rest[..<end.lowerBound])
        XCTAssertTrue(body.contains("DSEmptyState("))
        XCTAssertTrue(
            body.contains("accessibilityIdentifier(\"bots.desk.empty.new\")"),
            "empty desk must keep the New Bot control"
        )
        XCTAssertTrue(
            body.contains("person.badge.plus"),
            "empty-desk New Bot must share the sidebar plus-person glyph"
        )
        XCTAssertTrue(
            body.contains("DSPrimaryButtonStyle()"),
            "empty-desk New Bot must use compact DS primary chrome, not a stock filled footer pill"
        )
        XCTAssertFalse(
            body.contains("BotsPrimaryButtonStyle()"),
            "BotsPrimaryButtonStyle is the 44pt studio save fill; it reads as a leftover footer here"
        )
    }

    func test_modeSwitcherShowsWorkspaces_becauseUsersSeeWorkspaceModeNotInternalAgenticName() {
        // WHY: the left mode is the workspace list. Shipping "Agentic" as the
        // visible tab name was product jargon; the control must say Workspaces.
        XCTAssertEqual(BotsChrome.Label.agentic, "Workspaces")
        XCTAssertEqual(BotsChrome.Label.bots, "Bots")
    }

    func test_botSearchMatchesWorkspaceFilter() throws {
        // WHY: Search bots and the sidebar search must share one field style.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(sidebar.contains("SidebarSearchField("))
        XCTAssertTrue(sidebar.contains("placeholder: \"Search workspaces and Bots\""))
        XCTAssertFalse(bots.contains("SidebarSearchField("), "the Bots shell has no second search field")
    }

    private struct SeededDeskTurn {
        let run: AgentRun
        let eventCount: Int
    }

    private struct DeskReplayFixture {
        let context: AppContext
        let viewModel: BotsViewModel
        let bot: BotDefinition
        let thread: AgentThread
        let run: AgentRun
    }

    private func makeDeskReplayFixture() throws -> DeskReplayFixture {
        let context = try makeContext()
        let viewModel = BotsViewModel(context: context)
        let bot = try viewModel.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Watermark", provider: .claude, model: "opus")
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(),
            finishedAt: Date()
        )
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(run)
        try persistStreamEvents(
            context: context,
            run: run,
            events: [
                .turnStarted(turnId: "t-watermark"),
                .itemStarted(item: AssistantItem(
                    id: "r-watermark",
                    turnId: "t-watermark",
                    type: .reasoning,
                    state: .streaming,
                    body: "seed",
                    startedAtMs: 10
                )),
            ]
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Watermark", linkedAgentThreadID: thread.id)
        )
        viewModel.openDesk(bot)
        return DeskReplayFixture(
            context: context,
            viewModel: viewModel,
            bot: bot,
            thread: thread,
            run: run
        )
    }

    @discardableResult
    private func seedLinkedTurn(
        context: AppContext,
        bot: BotDefinition,
        extraReasoning: Int
    ) throws -> SeededDeskTurn {
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_040)
        )
        try context.runRepo.upsert(run)
        var events: [AssistantEvent] = [
            .turnStarted(turnId: "t-desk"),
            .itemStarted(item: AssistantItem(
                id: "r-desk",
                turnId: "t-desk",
                type: .reasoning,
                state: .streaming,
                body: "",
                startedAtMs: 1_700_000_010_000
            )),
            .itemDelta(itemId: "r-desk", bodyAppend: "Checking overnight failures", outputAppend: nil, summary: nil),
        ]
        for index in 0..<extraReasoning {
            events.append(.itemDelta(
                itemId: "r-desk",
                bodyAppend: " chunk-\(index)",
                outputAppend: nil,
                summary: nil
            ))
        }
        events.append(contentsOf: [
            .itemCompleted(itemId: "r-desk", finalState: .completed),
            .itemStarted(item: AssistantItem(
                id: "tool-desk",
                turnId: "t-desk",
                type: .tool,
                state: .completed,
                summary: "Bash",
                body: #"{"command":"swift test"}"#,
                startedAtMs: 1_700_000_020_000,
                finishedAtMs: 1_700_000_030_000
            )),
            .turnCompleted(turnId: "t-desk", finalMessage: "Three failing tests remain."),
        ])
        try persistStreamEvents(context: context, run: run, events: events)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Summarize overnight",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Summarize overnight", linkedAgentThreadID: thread.id)
        )
        return SeededDeskTurn(run: run, eventCount: events.count)
    }

    private func persistStreamEvents(
        context: AppContext,
        run: AgentRun,
        events: [AssistantEvent],
        startSeq: Int = 1
    ) throws {
        for (index, event) in events.enumerated() {
            let data = try JSONEncoder().encode(event)
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            try context.runRepo.appendStreamEvent(
                runId: run.id,
                seq: startSeq + index,
                kind: event.debugDescription,
                payloadJSON: json
            )
        }
    }

    private func fullReloadCounts(_ viewModel: BotsViewModel) -> [Int] {
        [
            viewModel.fleetReloadCountForTesting,
            viewModel.studioSupportReloadCountForTesting,
        ]
    }

    private func peerHandoffPerformancePayload(
        rowCount: Int,
        targetOriginBotID: BotID
    ) throws -> (data: Data, targetActivityID: UUID, siblingActivityID: UUID) {
        precondition(rowCount >= 2)
        let targetActivityID = UUID()
        let siblingActivityID = UUID()
        let retainedOriginBotID = BotID()
        let route = T005PeerHandoffRouteFixture(
            provider: .codex,
            providerInstanceID: nil,
            model: "t005-model",
            permissionMode: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            runAsUser: AgentRunAsUser(
                generatedUID: "t005-fixture",
                shortName: "fixture",
                uid: 0,
                gid: 0,
                homePath: "/tmp/t005-fixture"
            ),
            routingConfiguration: nil
        )
        var rows: [UUID: T005PeerHandoffRecordFixture] = [:]
        rows.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let activityID: UUID
            if index == 0 {
                activityID = targetActivityID
            } else if index == 1 {
                activityID = siblingActivityID
            } else {
                activityID = UUID()
            }
            rows[activityID] = T005PeerHandoffRecordFixture(
                version: 2,
                activityID: activityID,
                originBotID: index == 0 ? targetOriginBotID : retainedOriginBotID,
                originConversationID: nil,
                originAgentThreadID: nil,
                peerBotID: BotID(),
                peerConversationID: BotConversationID(),
                peerThreadID: nil,
                peerRunID: nil,
                inboundMessageID: activityID,
                peerName: "Peer \(index)",
                peerTitle: "Performance fixture",
                peerHandle: "peer-\(index)",
                outboundText: "retained row \(index)",
                createdAt: Date(timeIntervalSinceReferenceDate: Double(index)),
                peerRoute: route,
                hostThreadID: nil,
                hostRunID: nil,
                hostRoute: nil,
                replyText: "completed row \(index)",
                replyCreatedAt: Date(timeIntervalSinceReferenceDate: Double(index + 1)),
                phase: .completed
            )
        }
        return (
            try JSONEncoder().encode(rows),
            targetActivityID,
            siblingActivityID
        )
    }

    private func measurePeerHandoffDeletion(
        label: String,
        payload: Data,
        targetOriginBotID: BotID,
        targetActivityID: UUID,
        siblingActivityID: UUID
    ) throws -> Double {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("peer-perf-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
            try? FileManager.default.removeItem(at: root)
        }

        UserDefaults.standard.set(payload, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())
        let (_, db) = try Bootstrap(
            channel: .debug,
            appSupportOverride: root.path
        ).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedMessageRepo = AgentQueuedMessageRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let settingsRepo = SettingsRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            checkpointRepo: checkpointRepo,
            providers: [:]
        )
        var authority: BotPeerHandoffAuthority? = BotPeerHandoffAuthority(
            botStore: BotStore(db: db),
            threadRepo: threadRepo,
            runRepo: runRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedMessageRepo,
            checkpointRepo: checkpointRepo,
            settingsRepo: settingsRepo,
            coordinator: coordinator,
            appSupportDirectory: root
        )
        weak var releasedAuthority = authority
        let deletion = try XCTUnwrap(authority).beginDeletion(originBotID: targetOriginBotID)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let committed = try XCTUnwrap(authority).commitDeletion(deletion)
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(committed, "\(label) must commit through the production authority path")

        let storedPayload = try XCTUnwrap(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"))
        let retained = try JSONDecoder().decode(
            [UUID: T005PeerHandoffRecordFixture].self,
            from: storedPayload
        )
        XCTAssertEqual(retained.count, 999, "\(label) must retain exactly 999 supported v2 rows")
        XCTAssertNil(retained[targetActivityID], "\(label) must delete the exact selected row")
        XCTAssertNotNil(retained[siblingActivityID], "\(label) must preserve an unrelated sibling")
        XCTAssertEqual(
            try settingsRepo.get("bots.peerTurns.v2"),
            "base64:\(storedPayload.base64EncodedString())",
            "\(label) SQLite and mirror must describe the same committed envelope"
        )

        authority = nil
        XCTAssertNil(releasedAuthority, "\(label) must not accumulate an authority between samples")
        return Double(finishedAt - startedAt) / 1_000_000
    }

    private func percentile(_ samples: [Double], fraction: Double) -> Double {
        let sorted = samples.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)
        return sorted[index]
    }

    private static func performDraftTypingWorkload(
        _ vm: BotsViewModel,
        advanceCadence: () -> Void
    ) {
        for index in 0..<500 {
            switch index {
            case 0..<200:
                vm.composerText.append("c")
            case 200..<350:
                vm.studioDraft.soul.append("s")
            default:
                vm.routinePrompt.append("i")
            }
            advanceCadence()
        }
    }

    private static func processCPUNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    /// Links the selected desk conversation through the real first-send path
    /// (the desk creates threads lazily) and waits for the fake run to settle.
    @discardableResult
    private func linkDeskThreadByFirstSend(
        _ vm: BotsViewModel,
        context: AppContext,
        router: AppCommandRouter,
        providerAlreadyInstalled: Bool = false
    ) async throws -> AgentThreadID {
        if !providerAlreadyInstalled {
            context.coordinator.replaceProvider(
                .claude,
                runner: FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: "ok"))
            )
            router.rememberProviderSnapshotsForSend([
                AgentProviderSnapshotFactory.snapshot(
                    provider: .claude,
                    models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                    binaryPath: "/usr/bin/true",
                    authenticated: true,
                    id: "claude"
                ),
            ])
            router.preflightListedProviderSnapshotsForTesting = false
            vm.setDeskProvider(.claude)
        }
        XCTAssertTrue(vm.send("hello"))
        let threadID = try XCTUnwrap(vm.selectedConversation?.linkedAgentThreadID,
                                     "first send links the thread")
        if !providerAlreadyInstalled {
            for _ in 0..<500 where context.coordinator.activeRunId(threadId: threadID) != nil
                || vm.deskSendInFlight {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        return threadID
    }

    func test_openingDeskPinsAgentAppToLinkedThreadAndCompilesBrainOnlyIntoPrompt_becauseDeskMustSendThroughAgentApp() async throws {
        // WHY: the desk must drive Agent App on the bot's own thread; the bot
        // brain belongs in the provider prompt while the user text stays raw.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        XCTAssertNil(vm.deskAgentVM, "unlinked desk has no embedded VM until the first send")
        let threadID = try await linkDeskThreadByFirstSend(vm, context: context, router: router)
        let agent = try XCTUnwrap(vm.deskAgentVM, "desk must own an Agent App VM")
        let embedding = try XCTUnwrap(agent.embedding)
        XCTAssertEqual(embedding.pinnedThreadId, threadID)
        XCTAssertEqual(agent.selectedThreadId, threadID)
        let transform = try XCTUnwrap(embedding.promptTransform)
        let raw = "Where is the report?"
        let payload = try await transform(raw, threadID, AgentRunID())
        XCTAssertNotEqual(payload, raw)
        XCTAssertTrue(payload.contains(raw))
        XCTAssertTrue(payload.contains("Piper"), "compiled payload carries the bot brain")
    }

    func test_linkedDeskKeepsMessageBotPlaceholderAndEmptyCopy_becauseTheInputMustNotFlipToTheProviderAfterTheFirstSend() async throws {
        // WHY: before the first message the Desk composer read "Message Piper…".
        // Once the thread was linked, the embedded Agent App fell back to
        // "Ask Claude for changes…" and an empty thread said "Start a new agent
        // run." In a Bot chat the Bot is who you talk to; the provider is a detail.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        try await linkDeskThreadByFirstSend(vm, context: context, router: router)
        let agent = try XCTUnwrap(vm.deskAgentVM, "desk must own an Agent App VM")
        XCTAssertEqual(agent.composerPlaceholder, "Message Piper…")
        XCTAssertEqual(agent.embedding?.emptyConversationTitle, "Message Piper")
        XCTAssertEqual(agent.embedding?.emptyConversationSubtitle, "This thread has no messages yet.")
        // The unlinked composer reads the same helper, so the two cannot drift.
        XCTAssertEqual(agent.composerPlaceholder, BotsViewModel.deskComposerPlaceholder(botName: bot.name))
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(
            source.contains("placeholder: BotsViewModel.deskComposerPlaceholder(botName: bot.name),"),
            "the unlinked Desk composer must use the shared placeholder"
        )
    }

    func test_groupRoomsPassTheirOwnEmptyCopy_becauseARoomNeverStartsAnAgentRun() throws {
        // WHY: the room and the private member thread mount the Agent App
        // surface, whose empty state says "Start a new agent run." A room only
        // relays to its bots and the private thread is read-only, so that line
        // told the owner to do something neither place can do.
        XCTAssertEqual(BotTeamsGroupsController.roomEmptyTitle, "Message the group")
        XCTAssertEqual(BotTeamsGroupsController.roomEmptySubtitle, "@mention a bot to choose who answers.")
        let groups = try String(contentsOf: sourceURL("Sources/AppShell/BotsTeamsGroups.swift"), encoding: .utf8)
        XCTAssertTrue(groups.contains("emptyConversationTitle: Self.roomEmptyTitle,"))
        XCTAssertTrue(groups.contains("emptyConversationSubtitle: Self.roomEmptySubtitle"))
        XCTAssertTrue(
            groups.contains("emptyConversationSubtitle: Self.privateThreadReadOnlyMessage"),
            "an empty private thread says it is read-only, as its composer does"
        )
        XCTAssertEqual(
            groups.components(separatedBy: "emptyConversationTitle:").count - 1,
            groups.components(separatedBy: "AgentAppEmbedding(").count - 1,
            "every embedded group surface names its own empty state"
        )
    }

    func test_botNameStaysOnOneLineWithAFallback_becauseALongNameWrappedOverTheChatAndAnEmptyOneHadNoLabel() throws {
        // WHY: the Desk header is a fixed 44pt bar. The Bot name had no line
        // limit, so a long name wrapped and spilled over the transcript. An
        // empty name left the roster row, the header and VoiceOver with nothing
        // to show or say.
        XCTAssertEqual(BotsViewModel.displayName(""), "Untitled")
        XCTAssertEqual(BotsViewModel.displayName("Piper"), "Piper")
        let long = String(repeating: "N", count: 200)
        XCTAssertEqual(BotsViewModel.displayName(long), long, "the view truncates; the name itself is never cut")
        XCTAssertEqual(BotsViewModel.deskComposerPlaceholder(botName: ""), "Message Untitled…")

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let headerStart = try XCTUnwrap(source.range(of: "private func deskHeader"))
        let headerRest = source[headerStart.upperBound...]
        let headerEnd = headerRest.range(of: "\n    private func deskChat")?.lowerBound ?? headerRest.endIndex
        let header = String(source[headerStart.lowerBound..<headerEnd])
        let name = try XCTUnwrap(header.range(of: "Text(BotsViewModel.displayName(bot.name))"))
        let nameID = try XCTUnwrap(header.range(
            of: ".accessibilityIdentifier(\"bots.desk.name\")",
            range: name.upperBound..<header.endIndex
        ))
        let nameModifiers = String(header[name.lowerBound..<nameID.lowerBound])
        XCTAssertTrue(nameModifiers.contains(".lineLimit(1)"), "a 200-character name must stay inside the 44pt bar")
        XCTAssertTrue(nameModifiers.contains(".truncationMode(.tail)"))
        XCTAssertTrue(
            nameModifiers.contains(".help(BotsViewModel.displayName(bot.name))"),
            "the truncated name stays readable as a tooltip"
        )
        XCTAssertTrue(header.contains(".frame(height: 44)"))
        XCTAssertTrue(
            header.contains(".layoutPriority(1)"),
            "the attention badge keeps its place when the name truncates"
        )
        XCTAssertTrue(header.contains("\"Open Studio for \\(BotsViewModel.displayName(bot.name))\""))
    }

    func test_rosterAndHeaderSubtitlesUseTextSecondary_becauseTertiaryIsUnreadableAt10pt() throws {
        // WHY: the Desk header's handle and permission and the group
        // subtitles are 10pt text the owner reads to pick a chat and
        // to see what a Bot may do. textTertiary is 3.72:1 on the rail
        // (DSContrastTests); information text needs 4.5:1, so these sites use
        // textSecondary. The token value itself does not change.
        func slice(_ source: String, from start: String, to end: String) throws -> String {
            let lower = try XCTUnwrap(source.range(of: start), "\(start) must exist")
            let upper = try XCTUnwrap(
                source.range(of: end, range: lower.upperBound..<source.endIndex),
                "\(end) must follow \(start)"
            )
            return String(source[lower.lowerBound..<upper.upperBound])
        }
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let groups = try String(contentsOf: sourceURL("Sources/AppShell/BotsTeamsGroups.swift"), encoding: .utf8)
        let sites = [
            try slice(bots, from: "Text(\"@\\(bot.handle)\")", to: "\"bots.desk.permission\""),
            try slice(groups, from: "Text(\"\\(members.count) bots · \\(group.policy.displayName)\")", to: ".lineLimit(1)"),
        ]
        for site in sites {
            XCTAssertTrue(site.contains(".foregroundColor(DS.Palette.textSecondary)"), site)
            XCTAssertFalse(site.contains("textTertiary"), site)
        }
    }

    func test_unlinkedDeskThreadShowsMessageBotEmptyState_becauseThatIsTheEmptyDeskTheOwnerSees() throws {
        // WHY: a Desk thread is linked by its first message, so the empty
        // state of the linked surface is almost never painted. The empty Desk
        // the owner opens is the unlinked one, and it was a blank column over
        // the composer. It names the Bot with the linked surface's copy, and
        // a long name is capped so it cannot push the composer.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func deskUnlinkedComposer"))
        let end = try XCTUnwrap(source.range(of: "AgentChatComposerBar(", range: start.upperBound..<source.endIndex))
        let empty = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(empty.contains("DSEmptyState("))
        XCTAssertTrue(empty.contains("title: \"Message \\(BotsViewModel.displayName(bot.name))\""))
        XCTAssertTrue(empty.contains("subtitle: \"This thread has no messages yet.\""))
        // The limit set from outside reaches the subtitle as well as the
        // title. Two lines cut "This thread has no messages yet." in the
        // 120pt column of the minimum window; three keep it whole.
        XCTAssertTrue(empty.contains(".lineLimit(3)"), "DSEmptyState's title has no line limit of its own")
        XCTAssertFalse(empty.contains(".lineLimit(2)"), "two lines truncate the fixed subtitle")
        XCTAssertTrue(
            empty.contains(".multilineTextAlignment(.center)"),
            "a name that wraps to the second line stays centred in the narrow chat column"
        )
        // A send can persist its message and then fail to link the thread
        // (no router, no published revision). The conversation stays unlinked
        // with a message in it, and "no messages yet" would be false.
        let guardLine = try XCTUnwrap(
            empty.range(of: "if vm.deskMessages.isEmpty {"),
            "the empty copy is shown only while the thread has no message"
        )
        let state = try XCTUnwrap(empty.range(of: "DSEmptyState("))
        XCTAssertLessThan(guardLine.lowerBound, state.lowerBound)
        // The linked surface must keep saying the same thing.
        XCTAssertEqual(
            source.components(separatedBy: "\"This thread has no messages yet.\"").count - 1, 2,
            "linked and unlinked Desk threads share one empty copy"
        )
    }

    func test_savesAndRosterNavigationStartFromAnEmptyErrorSlot_becauseTheStripIsNotModalAndWouldOutliveTheFix() throws {
        // WHY: under the modal alert, OK emptied the error slot before any
        // other action. The strip stays until dismissed, so "…are required."
        // survived the corrected save and stayed above a saved task, and an
        // error about one Bot moved above the next Bot the owner opened.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let nova = try vm.create(name: "Nova", title: "Writer", provider: .claude)
        vm.openDesk(piper)

        vm.createScheduleTask()
        var draft = try XCTUnwrap(vm.scheduleTaskDraft)
        vm.saveScheduleTask(draft)
        XCTAssertEqual(vm.errorMessage, "Task name and instruction are required.")
        draft.name = "Morning scan"
        draft.prompt = "Scan overnight"
        vm.saveScheduleTask(draft)
        XCTAssertNil(vm.scheduleTaskDraft, "fixture: the corrected task saved")
        XCTAssertNil(vm.errorMessage, "a saved task must not keep the earlier validation error")

        vm.saveRoutine()
        XCTAssertEqual(vm.errorMessage, "Routine name and prompt are required.")
        vm.routineName = "Evening scan"
        vm.routinePrompt = "Check the day's failures"
        vm.saveRoutine()
        XCTAssertTrue(vm.routines.contains { $0.definition.name == "Evening scan" }, "fixture: the routine saved")
        XCTAssertNil(vm.errorMessage, "a saved routine must not keep the earlier validation error")

        vm.errorMessage = "Force stop: timed out"
        vm.openDeskFromRoster(nova)
        XCTAssertEqual(vm.selectedBotID, nova.id)
        XCTAssertNil(vm.errorMessage, "Piper's error must not sit above Nova's Desk")
    }

    func test_ownerSendAndRowNavigationStartFromAnEmptyErrorSlot_becauseAStaleRefusalInvitesADuplicateSend() throws {
        // WHY: a Docker-desktop Bot refuses the first send while its guest
        // starts. The alert made the owner press OK before trying again. The
        // strip stays, so after the second, admitted send it still read as a
        // refusal above a working Bot, and "Try again" invites a duplicate
        // send. The same row followed the owner from the Active and Finished
        // lists into another Bot's Desk, and into a group room.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let nova = try vm.create(name: "Nova", title: "Writer", provider: .claude)
        vm.openDesk(piper)
        vm.dockerGuestReadyOverrideForTesting = false
        vm.desktopKindOverrideForTesting = .dockerDesktop
        XCTAssertFalse(vm.send("open chrome"))
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")
        vm.desktopKindOverrideForTesting = nil
        vm.dockerGuestReadyOverrideForTesting = true
        XCTAssertTrue(vm.send("open chrome"))
        XCTAssertEqual(
            vm.errorMessage, "Docker desktop is not ready.",
            "fixture: send() also drains queued follow-ups, which must not erase an error, so the composer clears it"
        )

        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let composerStart = try XCTUnwrap(bots.range(of: "private func deskUnlinkedComposer"))
        let onSend = try XCTUnwrap(bots.range(of: "onSend: {", range: composerStart.upperBound..<bots.endIndex))
        let onStop = try XCTUnwrap(bots.range(of: "onStop:", range: onSend.upperBound..<bots.endIndex))
        let ownerSend = String(bots[onSend.lowerBound..<onStop.lowerBound])
        let clear = try XCTUnwrap(
            ownerSend.range(of: "vm.errorMessage = nil"),
            "the owner's send must start from an empty error slot"
        )
        let attempt = try XCTUnwrap(ownerSend.range(of: "vm.send()"))
        XCTAssertLessThan(clear.lowerBound, attempt.lowerBound, "a refusal of this send must survive the clear")

        vm.openActiveBotItem(ActiveBotScreenItem(bot: nova, preview: "", providerName: "Claude"))
        XCTAssertEqual(vm.selectedBotID, nova.id)
        XCTAssertNil(vm.errorMessage, "Piper's refusal must not sit above Nova's Desk (Active list)")

        vm.errorMessage = "Docker desktop is not ready."
        let run = AgentRun(threadId: AgentThreadID(), provider: .claude, model: "opus", status: .completed)
        vm.openFinishedBotItem(FinishedBotScreenItem(run: run, bot: piper, conversationTitle: "Standup"))
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertNil(vm.errorMessage, "Nova's error must not sit above Piper's Desk (Finished list)")

        // openGroup is also the restore path, so the sidebar row clears.
        let groups = try String(contentsOf: sourceURL("Sources/AppShell/BotsTeamsGroups.swift"), encoding: .utf8)
        let rowStart = try XCTUnwrap(groups.range(of: "private func groupRow"))
        let open = try XCTUnwrap(groups.range(of: "vm.openGroup(group.id)", range: rowStart.upperBound..<groups.endIndex))
        let row = String(groups[rowStart.lowerBound..<open.lowerBound])
        XCTAssertTrue(
            row.contains("vm.errorMessage = nil"),
            "a Bot's error must not sit above a group's room"
        )
    }

    func test_slowStopIsReportedOverAnOlderError_becauseTheStripIsNotModalAndTheSlotMayBeTaken() throws {
        // WHY: "Stop is taking longer than expected" was written only into an
        // empty error slot, which the modal alert guaranteed. With the strip an
        // older undismissed error can still be there, and it hid the fact that
        // the run is still going. Only this Task's own "Force stop:" failure
        // may keep the slot.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func stopDeskThread"))
        let end = try XCTUnwrap(source.range(
            of: "\"Stop is taking longer than expected. Try again or restart the agent.\"",
            range: start.upperBound..<source.endIndex
        ))
        let forceStop = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(forceStop.contains("var forceStopFailed = false"))
        XCTAssertTrue(forceStop.contains("forceStopFailed = true"))
        XCTAssertTrue(forceStop.contains("if !forceStopFailed {"))
        XCTAssertFalse(
            forceStop.contains("if self.errorMessage == nil"),
            "an unrelated older error must not suppress the slow-stop message"
        )
    }

    func test_repeatedErrorIsAnnouncedAgain_becauseTheAlertItReplacedWasSpokenOnEveryAttempt() throws {
        // WHY: the strip spoke only when its message changed. A second failed
        // attempt writes the same string, the view sees an equal value and
        // VoiceOver says nothing, where the alert reappeared and was read each
        // time. Every write of the slot now moves a revision the strip keys on.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.errorMessage = "Task name and instruction are required."
        let first = vm.errorMessageRevision
        vm.errorMessage = "Task name and instruction are required."
        XCTAssertNotEqual(vm.errorMessageRevision, first, "an equal write must still move the revision")

        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertEqual(
            bots.components(separatedBy: "announcementToken: vm.errorMessageRevision,").count - 1, 2,
            "both Bots roots hand the revision to their strip"
        )
        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatSharedChrome.swift"), encoding: .utf8)
        let start = try XCTUnwrap(chrome.range(of: "public struct AgentChatErrorStrip"))
        let end = try XCTUnwrap(chrome.range(of: "private func announce()", range: start.upperBound..<chrome.endIndex))
        let strip = String(chrome[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(
            strip.contains(".onChange(of: \"\\(announcementToken ?? 0):\\(message)\") { _ in announce() }"),
            "the announcement is keyed on the token and the message together, so one write speaks once"
        )
        XCTAssertFalse(strip.contains(".onChange(of: message)"))
    }

    func test_renameWhileDeskStaysOpenRebuildsLinkedComposerCopy_becauseTheHeaderAndTheInputMustNameTheSameBot() async throws {
        // WHY: the linked Desk captures the Bot's name once for its composer
        // and empty copy. A detached Desk window has its own view model and
        // stays on .desk, so a rename saved in the main window's Studio
        // reached its header but left "Message <old name>…" in the input.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        try await linkDeskThreadByFirstSend(vm, context: context, router: router)
        XCTAssertEqual(vm.deskAgentVM?.composerPlaceholder, "Message Piper…")

        let studio = BotsViewModel(context: context, router: router)
        studio.beginEdit(bot)
        studio.studioDraft.name = "Nova"
        XCTAssertEqual(try studio.saveStudio().name, "Nova")

        // How the open Desk learns of a publish made elsewhere.
        vm.refreshPublishedIdentity(for: bot.id)
        XCTAssertEqual(vm.selectedBot?.name, "Nova", "fixture: the header reads the new name")
        XCTAssertEqual(vm.screen, .desk)
        let agent = try XCTUnwrap(vm.deskAgentVM)
        XCTAssertEqual(agent.composerPlaceholder, "Message Nova…")
        XCTAssertEqual(agent.embedding?.emptyConversationTitle, "Message Nova")
    }

    func test_queuedFollowUpOnBotThreadCompilesBrainButKeepsUserTextRaw_becauseQueueDrainBypassesEmbeddedComposer() async throws {
        // WHY: a follow-up typed while a run is live is drained by the host, not
        // the embedded composer; without the router hook the bot would answer
        // with no identity, memory or approval honesty.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.grok, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [AgentModelDescriptor(id: "grok-4.6", label: "Grok 4.6", provider: .grok)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "grok"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok, model: "grok-4.6")
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        let threadID = try await linkDeskThreadByFirstSend(
            vm, context: context, router: router, providerAlreadyInstalled: true
        )
        XCTAssertNotNil(vm.deskAgentVM)
        // Newly linked bot threads start .pending; the queue drain gate only
        // runs on idle threads, so settle it before draining.
        var settled = try XCTUnwrap(try context.threadRepo.get(id: threadID))
        settled.status = .completed
        // ensureLinkedThread keys the linked thread off the desk routing at
        // open time; the default desk route is not grok, so lock the row to
        // the test provider before draining.
        settled.provider = .grok
        settled.model = "grok-4.6"
        settled.providerInstanceId = "grok"
        settled.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(
                provider: .grok,
                modelId: "grok-4.6",
                reasoningEffort: .medium,
                serviceTier: .auto
            ),
            manualProviderInstanceId: "grok",
            revision: 0
        )
        try context.threadRepo.upsert(settled)
        let raw = "queued follow-up question"
        _ = try context.queuedMessageRepo.enqueue(
            threadId: threadID,
            text: raw,
            attachments: [],
            interactionMode: .default
        )
        try await router.drainNextQueuedAgentMessage(thread: threadID)
        let request = try XCTUnwrap(runner.requests.last, "drained follow-up is the newest request")
        XCTAssertNotEqual(request.prompt, raw)
        XCTAssertTrue(request.prompt.contains(raw))
        XCTAssertTrue(request.prompt.contains("Piper"), "queued send carries the bot brain")
        XCTAssertEqual(request.userMessageContent, raw, "visible user message stays the raw text")
        let home = BotHome(appSupportDirectory: context.appSupportDirectory, bot: bot).root
        XCTAssertTrue(request.cwd.hasSuffix(home.lastPathComponent),
                      "bot threads run in the bot home, not the process cwd")
    }

    func test_linkedDeskAgentCanForceQueuedMessageThroughRouter_becauseRecoveryMustNotBeUnavailable() async throws {
        // WHY: The embedded Desk VM owns queue recovery controls too; forcing a
        // queued row must route it to the provider instead of leaving it queued.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let setupRunner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.grok, runner: setupRunner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [AgentModelDescriptor(id: "grok-4.6", label: "Grok 4.6", provider: .grok)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "grok"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok, model: "grok-4.6")
        vm.openDesk(bot)
        vm.setDeskProvider(.grok, instanceID: "grok")
        vm.setDeskModel("grok-4.6")
        XCTAssertTrue(vm.createDeskThread())
        let threadID = try await linkDeskThreadByFirstSend(
            vm, context: context, router: router, providerAlreadyInstalled: true
        )
        let setupReachedFake = await waitUntil(timeout: 5) { setupRunner.requests.count == 1 }
        XCTAssertTrue(setupReachedFake, "setup first-send must reach configured Grok fake")
        XCTAssertTrue(setupRunner.finish(promptContaining: "hello", reply: "setup complete"))
        let firstRunSettled = await waitUntil(timeout: 5) {
            context.coordinator.activeRunId(threadId: threadID) == nil && !vm.deskSendInFlight
        }
        XCTAssertTrue(firstRunSettled, "the setup run must finish before idle recovery")
        let runner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.grok, runner: runner)
        var thread = try XCTUnwrap(try context.threadRepo.get(id: threadID))
        thread.status = .completed
        thread.provider = .grok
        thread.model = "grok-4.6"
        thread.providerInstanceId = "grok"
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(
                provider: .grok,
                modelId: "grok-4.6",
                reasoningEffort: .medium,
                serviceTier: .auto
            ),
            manualProviderInstanceId: "grok",
            revision: 0
        )
        try context.threadRepo.upsert(thread)
        let queuedText = "recover this queued message"
        _ = try context.queuedMessageRepo.enqueue(
            threadId: threadID,
            text: queuedText,
            attachments: [],
            interactionMode: .default
        )

        let deskAgent = try XCTUnwrap(vm.deskAgentVM)
        XCTAssertNotNil(deskAgent.forceQueuedMessage, "linked Desk VM must have router force wiring")
        deskAgent.reloadQueuedMessages()
        let queued = try XCTUnwrap(deskAgent.queuedMessages.first)
        let requestsBeforeForce = runner.requests.count
        await deskAgent.forceQueuedMessageNow(queued)

        let started = await waitUntil(timeout: 5) { runner.requests.count > requestsBeforeForce }
        XCTAssertTrue(started, "the linked Desk force action must reach the provider")
        let request = try XCTUnwrap(runner.requests.last)
        XCTAssertEqual(request.userMessageContent, queuedText, "forced queue text must not be lost")
        XCTAssertTrue(try context.queuedMessageRepo.list(threadId: threadID).isEmpty)
        XCTAssertFalse(
            deskAgent.queueStatusMessage?.contains("unavailable") ?? false,
            "embedded Desk queue recovery must have router wiring"
        )
    }

    func test_linkedDeskQueueDrainEventClearsDeskQueueRows_becauseDeskMustMirrorTabQueueSubscription() async throws {
        // WHY: the embedded Desk VM has no tab subscription of its own. A host drain
        // removes the queued row from the store; the Desk queue must learn from the
        // EventBus lifecycle event instead of keeping the stale row until a reselect.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let setupRunner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.grok, runner: setupRunner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [AgentModelDescriptor(id: "grok-4.6", label: "Grok 4.6", provider: .grok)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "grok"
            ),
        ])
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok, model: "grok-4.6")
        vm.openDesk(bot)
        vm.setDeskProvider(.grok, instanceID: "grok")
        vm.setDeskModel("grok-4.6")
        XCTAssertTrue(vm.createDeskThread())
        let threadID = try await linkDeskThreadByFirstSend(
            vm, context: context, router: router, providerAlreadyInstalled: true
        )
        let setupReachedFake = await waitUntil(timeout: 5) { setupRunner.requests.count == 1 }
        XCTAssertTrue(setupReachedFake, "setup first-send must reach configured Grok fake")
        XCTAssertTrue(setupRunner.finish(promptContaining: "hello", reply: "setup complete"))
        let firstRunSettled = await waitUntil(timeout: 5) {
            context.coordinator.activeRunId(threadId: threadID) == nil && !vm.deskSendInFlight
        }
        XCTAssertTrue(firstRunSettled, "the setup run must finish before queueing")

        _ = try context.queuedMessageRepo.enqueue(
            threadId: threadID,
            text: "drained by host",
            attachments: [],
            interactionMode: .default
        )
        let deskAgent = try XCTUnwrap(vm.deskAgentVM)
        deskAgent.reloadQueuedMessages()
        let queued = try XCTUnwrap(deskAgent.queuedMessages.first)

        // Drain the row the way the host does: claim, prepare, dispatch, acknowledge.
        let lease = try XCTUnwrap(try context.queuedMessageRepo.claimFirst(threadId: threadID))
        let dispatchRunId = AgentRunID()
        XCTAssertTrue(try context.queuedMessageRepo.prepareDispatch(lease, runId: dispatchRunId))
        XCTAssertTrue(try context.queuedMessageRepo.markDispatched(lease, runId: dispatchRunId))
        _ = try context.queuedMessageRepo.acknowledge(lease)
        XCTAssertTrue(try context.queuedMessageRepo.list(threadId: threadID).isEmpty)
        router.publishQueuedMessage(kind: AgentQueueEventKinds.drained, queued)

        let cleared = await waitUntil(timeout: 5) { deskAgent.queuedMessages.isEmpty }
        XCTAssertTrue(cleared, "the Desk queue must drop the drained row on the drain event")
        XCTAssertNil(deskAgent.queueStatusMessage)
    }

    func test_openingUnlinkedConversationDoesNotMarkItStarted_becauseViewingIsNotSending() async throws {
        // WHY: lastStartedConversationByBot drives "the bot just ran" bookkeeping
        // and must only move on a real send, never on viewing.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        XCTAssertNil(vm.selectedConversation?.linkedAgentThreadID, "viewing links no thread")
        XCTAssertNil(vm.lastStartedConversationForTesting(botID: bot.id))
        try await linkDeskThreadByFirstSend(vm, context: context, router: router)
        XCTAssertNotNil(vm.lastStartedConversationForTesting(botID: bot.id), "a real send marks it started")
    }

    func test_openingUnlinkedDeskConversationCreatesNoThreadOrHome() throws {
        // WHY: viewing an empty conversation must not leave an AgentThread row
        // or a BotHome directory behind for every "New thread" click.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout")
        let homeRoot = BotHome(appSupportDirectory: context.appSupportDirectory, bot: bot).root
        let threadsBefore = try context.threadRepo.list().count
        // Bot creation seeds the home; remove it so only the desk could recreate it.
        try? FileManager.default.removeItem(at: homeRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeRoot.path))
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        XCTAssertNil(vm.selectedConversation?.linkedAgentThreadID)
        XCTAssertNil(vm.deskAgentVM, "no thread to pin yet")
        XCTAssertEqual(try context.threadRepo.list().count, threadsBefore)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: homeRoot.path),
            "BotHome is created with the thread, not by viewing"
        )
        XCTAssertNil(vm.lastStartedConversationForTesting(botID: bot.id))
    }

    func test_firstSendOnUnlinkedDeskConversationCreatesExactlyOneLinkedThread() async throws {
        // WHY: lazy thread creation must still give the first message a thread,
        // and the embedded Agent App must attach to it afterwards.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        context.coordinator.replaceProvider(
            .claude,
            runner: FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: "ok"))
        )
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            ),
        ])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.setDeskProvider(.claude)
        XCTAssertTrue(vm.createDeskThread())
        XCTAssertNil(vm.selectedConversation?.linkedAgentThreadID)
        let threadsBefore = try context.threadRepo.list().count
        XCTAssertTrue(vm.send("first words"))
        let threadID = try XCTUnwrap(vm.selectedConversation?.linkedAgentThreadID,
                                     "first send links the thread")
        XCTAssertEqual(try context.threadRepo.list().count, threadsBefore + 1)
        XCTAssertEqual(vm.deskAgentVM?.embedding?.pinnedThreadId, threadID,
                       "embedded Agent App attaches once the thread exists")
        let home = BotHome(appSupportDirectory: context.appSupportDirectory, bot: bot).root
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try context.threadRepo.list().count, threadsBefore + 1)
    }

    private func unlinkedDeskDistillSnapshot(id: String = "distill-acp") -> AgentProviderSnapshot {
        AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [
                AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill),
                AgentModelDescriptor(id: "main-b", label: "Main B", provider: .distill),
            ],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: id,
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )
    }

    private func isolatedLastModelStore(distill: String?) -> AgentLastModelStore {
        let suiteName = "rc2-bots-last-model-" + UUID().uuidString
        let suite = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let store = AgentLastModelStore(defaults: suite)
        if let distill { store.remember(model: distill, for: .distill) }
        return store
    }

    func test_DistillModelSwitchClearsUnsupportedDeskMainEffort() throws {
        AgentProvider.selectableForTesting = nil
        defer { AgentProvider.selectableForTesting = AgentProvider.allCases }
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let models = [
            AgentModelDescriptor(id: "previous", label: "Previous", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: [.medium, .high]),
            AgentModelDescriptor(id: "deepseek-v4.1-flash", label: "DeepSeek V4.1 Flash", provider: .distill, supportsReasoning: true, supportedReasoningEfforts: [.low, .high, .max])
        ]
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: models,
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp",
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )
        let vm = BotsViewModel(context: context, router: router)
        vm.replaceProvidersForTests([snapshot])
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        vm.setDeskProvider(.distill, instanceID: "distill-acp")
        vm.setDeskModel("previous")
        vm.setDeskDistillMainEffortSelection(.fixed(.medium))

        vm.setDeskModel("deepseek-v4.1-flash")

        XCTAssertEqual(vm.deskRouting.model, "deepseek-v4.1-flash")
        XCTAssertEqual(vm.deskRouting.distillMainEffortSelection, .automatic)
        vm.setDeskDistillMainEffortSelection(.fixed(.high))
        XCTAssertEqual(vm.deskRouting.distillMainEffortSelection, .fixed(.high))
        vm.setDeskDistillMainEffortSelection(.automatic)
        XCTAssertEqual(vm.deskRouting.distillMainEffortSelection, .automatic)
        vm.setDeskModel("previous")
        vm.setDeskDistillMainEffortSelection(.fixed(.medium))
        vm.replaceProvidersForTests([])
        XCTAssertEqual(vm.deskRouting.distillMainEffortSelection, .fixed(.medium), "loading model metadata must not erase an explicit effort")
    }

    func test_unlinkedDeskMainModelPickIsTheModelTheFirstSendRuns() async throws {
        // WHY: an empty bot conversation has no embedded Agent App, so its
        // composer mounts the shared Main pill bound to deskRouting. Run 1 once
        // used a hidden route the user never saw; the model picked on the empty
        // conversation must be exactly the model the first send runs.
        AgentProvider.selectableForTesting = nil
        defer { AgentProvider.selectableForTesting = AgentProvider.allCases }
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        let snapshot = unlinkedDeskDistillSnapshot()
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        vm.lastModelStore = isolatedLastModelStore(distill: nil)
        vm.replaceProvidersForTests([snapshot])
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        XCTAssertNil(vm.selectedConversation?.linkedAgentThreadID)
        XCTAssertEqual(vm.deskRouting.model, "main-a",
                       "no last-used model: the pill opens on the first listed model, never an empty Main")

        // The pill's onSelectMainModel is vm.setDeskModel (source-pinned in AgentComposerChromeTests).
        vm.setDeskModel("main-b")
        XCTAssertTrue(vm.send("first words"))

        let started = await waitUntil(timeout: 5) { !runner.requests.isEmpty }
        XCTAssertTrue(started, "the first send must reach the Distill runner")
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.model, "main-b", "run 1 must use the model the empty-thread pill showed")
        let threadID = try XCTUnwrap(vm.selectedConversation?.linkedAgentThreadID)
        XCTAssertEqual(try context.threadRepo.get(id: threadID)?.model, "main-b",
                       "the lazily created thread must store the picked model, not a copied route")
        runner.finish(runID: request.runId, status: .completed, reply: "ok")
    }

    func test_newDeskConversationNeverRunsOnAnInvisibleEmptyOrStaleModel() throws {
        // WHY: a new conversation copies the previous route (sticky model). A
        // valid copied model must stay; an empty or unlisted one must resolve
        // like a new Agent App thread (last-used first) so shown == run.
        AgentProvider.selectableForTesting = nil
        defer { AgentProvider.selectableForTesting = AgentProvider.allCases }
        let snapshot = unlinkedDeskDistillSnapshot()
        let emptyRoute = BotDeskRouting(provider: .distill, providerInstanceID: "distill-acp", model: "")
        XCTAssertEqual(
            BotsViewModel.resolvedUnlinkedDeskModel(emptyRoute, snapshot: snapshot, lastUsed: "main-b"),
            "main-b", "an empty route takes the user's last-used Distill model")
        XCTAssertEqual(
            BotsViewModel.resolvedUnlinkedDeskModel(emptyRoute, snapshot: snapshot, lastUsed: nil),
            "main-a", "no last-used: first listed model, as AgentDefaultModelSelection does")
        var staleRoute = emptyRoute
        staleRoute.model = "retired-model"
        XCTAssertEqual(
            BotsViewModel.resolvedUnlinkedDeskModel(staleRoute, snapshot: snapshot, lastUsed: nil),
            "main-a", "a model the provider no longer lists (and no custom ids) must not run invisibly")
        var stickyRoute = emptyRoute
        stickyRoute.model = "main-b"
        XCTAssertEqual(
            BotsViewModel.resolvedUnlinkedDeskModel(stickyRoute, snapshot: snapshot, lastUsed: "main-a"),
            "main-b", "a valid copied model is the sticky-model feature and must win over last-used")
        var autoRoute = emptyRoute
        autoRoute.model = "auto"
        XCTAssertEqual(
            BotsViewModel.resolvedUnlinkedDeskModel(autoRoute, snapshot: snapshot, lastUsed: "main-b"),
            "auto", "a disabled or temporarily omitted Auto profile must not silently switch the Bot to a concrete model")

        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.lastModelStore = isolatedLastModelStore(distill: nil)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        XCTAssertEqual(vm.deskRouting.model, "",
                       "before snapshots load there is nothing honest to show yet")
        vm.replaceProvidersForTests([snapshot])
        XCTAssertEqual(vm.deskRouting.model, "main-a",
                       "late snapshots must fill the empty Main model of the open unlinked conversation")

        vm.setDeskModel("main-b")
        XCTAssertTrue(vm.createDeskThread())
        XCTAssertEqual(vm.deskRouting.model, "main-b",
                       "the next new conversation keeps the previous valid model, now visible on its pill")
    }

    private func makeWorkspaceLinkedDesk() throws -> (
        context: AppContext, router: AppCommandRouter, vm: BotsViewModel, bot: BotDefinition,
        thread: AgentThread, workspaceDir: String, runner: ControlledBotHandoffRunner
    ) {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.grok, runner: runner)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [AgentModelDescriptor(id: "grok-4.6", label: "Grok 4.6", provider: .grok)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "grok"
            ),
        ])
        let workspaceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BotDeskWS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "desk-ws", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Workspace thread",
            provider: .grok,
            model: "grok-4.6",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok, model: "grok-4.6")
        let conversation = BotConversation(
            botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id
        )
        try context.botStore.upsertConversation(conversation)
        return (context, router, vm, bot, thread, workspaceDir.path, runner)
    }

    func test_workspaceLinkedConversationSentFromDeskRunsInWorkspaceCwd_becauseBotHomeIsOnlyForWorkspacelessThreads() async throws {
        let f = try makeWorkspaceLinkedDesk()
        let homeRoot = BotHome(appSupportDirectory: f.context.appSupportDirectory, bot: f.bot).root
        try? FileManager.default.removeItem(at: homeRoot)
        f.vm.openDesk(f.bot)
        f.vm.selectDeskThread(try XCTUnwrap(f.context.botStore.conversationLinked(to: f.thread.id)).id)
        let agent = try XCTUnwrap(f.vm.deskAgentVM)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeRoot.path),
                       "workspace-linked desk must not create the bot home")
        agent.prompt = "run in workspace"
        await agent.send()
        for _ in 0..<500 where f.runner.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let request = try XCTUnwrap(f.runner.requests.first, "status: \(agent.statusMessage ?? "none")")
        XCTAssertEqual(
            URL(fileURLWithPath: request.cwd).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: f.workspaceDir).resolvingSymlinksInPath().path
        )
        XCTAssertTrue(request.prompt.contains("Piper"), "bot brain still reaches the prompt")
    }

    func test_embeddedDeskHandoffCreatesThreadInSourceWorkspaceWithSummaryDraft_becauseDeskWorkspaceIsSynthetic() async throws {
        let f = try makeWorkspaceLinkedDesk()
        try f.context.messageRepo.append(AgentMessage(threadId: f.thread.id, role: .user, content: "desk question"))
        f.vm.openDesk(f.bot)
        f.vm.selectDeskThread(try XCTUnwrap(f.context.botStore.conversationLinked(to: f.thread.id)).id)
        let agent = try XCTUnwrap(f.vm.deskAgentVM)
        XCTAssertNotNil(agent.handoffHost, "workspace-linked desk offers the hand-off")
        let oldBefore = try XCTUnwrap(try f.context.threadRepo.get(id: f.thread.id))
        let created = try f.router.createBotHandoffThread(from: f.thread.id, actor: .none)
        XCTAssertNotEqual(created.id, f.thread.id)
        XCTAssertEqual(created.workspaceId, f.thread.workspaceId)
        XCTAssertNotEqual(created.workspaceId, BotsViewModel.botDeskWorkspaceID)
        XCTAssertNil(created.actorLockedAt)
        let draft = try XCTUnwrap(try AgentThreadDraftRepository(db: f.context.db).get(
            threadId: created.id, providerInstanceId: created.providerInstanceId ?? created.provider.rawValue
        ))
        XCTAssertTrue(draft.text.hasPrefix("Continuação da thread \"Workspace thread\""))
        XCTAssertTrue(draft.text.contains("desk question"))
        let oldAfter = try XCTUnwrap(try f.context.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(oldAfter.actor, oldBefore.actor)
        XCTAssertEqual(oldAfter.actorLockedAt, oldBefore.actorLockedAt)
        XCTAssertEqual(oldAfter.title, oldBefore.title)
    }

    func test_embeddedDeskWithoutHandoffHostHidesContinueWithoutBot() throws {
        let f = try makeWorkspaceLinkedDesk()
        let bare = AgentAppViewModel(
            workspaceID: BotsViewModel.botDeskWorkspaceID,
            cwd: "/tmp",
            coordinator: f.context.coordinator,
            threadRepo: f.context.threadRepo,
            messageRepo: f.context.messageRepo,
            embedding: AgentAppEmbedding(pinnedThreadId: f.thread.id)
        )
        XCTAssertFalse(bare.canContinueWithoutBot)
    }

    func test_deskSelectionReadsTheThreadRowOnce_becauseTheClickWaitsBehindTheStreamWriter() async throws {
        // WHY: choosing a Bot builds its embedded Agent App on the click, and
        // each full read of the thread row waits on the queue the stream
        // writer uses while another Bot is answering. The build read the same
        // row four times (cwd, the embedded rail, the hand-off gate, the
        // runtime label). One read must serve all four, and the row handed to
        // the new view model must be this Bot's thread and no other.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let piperThread = AgentThread(title: "Piper standup", provider: .claude, model: "opus")
        let quinnThread = AgentThread(title: "Quinn review", provider: .claude, model: "opus")
        try context.threadRepo.upsert(piperThread)
        try context.threadRepo.upsert(quinnThread)
        let piperConversation = BotConversation(
            botID: piper.id, title: piperThread.title, linkedAgentThreadID: piperThread.id
        )
        let quinnConversation = BotConversation(
            botID: quinn.id, title: quinnThread.title, linkedAgentThreadID: quinnThread.id
        )
        try context.botStore.upsertConversation(piperConversation)
        try context.botStore.upsertConversation(quinnConversation)

        vm.openDesk(piper)
        vm.selectDeskThread(piperConversation.id)
        let piperAgent = try XCTUnwrap(vm.deskAgentVM)
        XCTAssertEqual(piperAgent.selectedThreadId, piperThread.id)
        // Let Piper's open settle so only Quinn's selection is counted.
        try await Task.sleep(for: .milliseconds(500))

        vm.openDesk(quinn)
        vm.selectDeskThread(quinnConversation.id)
        let quinnAgent = try XCTUnwrap(vm.deskAgentVM)
        XCTAssertFalse(quinnAgent === piperAgent, "each Bot gets its own embedded Agent App")
        XCTAssertEqual(
            vm.lastDeskAgentSyncThreadReadCountForTesting,
            1,
            "selecting a Bot must read its thread row once"
        )
        XCTAssertEqual(
            quinnAgent.durableThreadSelectionLookupCountForTesting,
            0,
            "the embedded Agent App must open from the row the desk already read"
        )
        XCTAssertEqual(quinnAgent.selectedThreadId, quinnThread.id)
        XCTAssertEqual(quinnAgent.threads.map(\.id), [quinnThread.id])
        XCTAssertEqual(quinnAgent.threads.first?.title, "Quinn review")
        XCTAssertEqual(
            piperAgent.selectedThreadId,
            piperThread.id,
            "the view model left behind must never be moved to another Bot's thread"
        )
        XCTAssertEqual(piperAgent.threads.map(\.id), [piperThread.id])
    }

    func test_botDesk2000DeltaDistillReplyPaintsThroughEmbeddedAgentAppWithoutDeskRepublish() async throws {
        // WHY (Distill terminal parity for Bots): a 2,000-token reply in the bot
        // desk must reach the embedded Agent App with bounded publishes and no
        // trailing paint lag, while BotsViewModel (the whole Bots tree) never
        // republishes per token.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        let threadID = try await linkDeskThreadByFirstSend(vm, context: context, router: router)
        let agentVM = try XCTUnwrap(vm.deskAgentVM)
        // Let desk open + embedded thread hydration settle so only streaming is measured.
        try await Task.sleep(for: .milliseconds(500))
        var deskPublishes = 0
        let deskSink = vm.objectWillChange.sink { _ in deskPublishes += 1 }
        defer { deskSink.cancel() }
        var agentPublishes = 0
        let agentSink = agentVM.transcriptState.$timeline.dropFirst().sink { _ in agentPublishes += 1 }
        defer { agentSink.cancel() }
        let run = AgentRunID()
        func deliver(_ event: AssistantEvent) {
            vm.runCoordinator(context.coordinator, didReceive: event, run: run, threadId: threadID)
            agentVM.runCoordinator(context.coordinator, didReceive: event, run: run, threadId: threadID)
        }
        deliver(.turnStarted(turnId: "t"))
        deliver(.itemStarted(item: AssistantItem(id: "a", turnId: "t", type: .assistantMessage, startedAtMs: 1)))
        let clock = ContinuousClock()
        let memBefore = botDeskPhysFootprintBytes()
        let start = clock.now
        for i in 0..<2_000 {
            deliver(.itemDelta(itemId: "a", bodyAppend: "w\(i) ", outputAppend: nil, summary: nil))
            if i % 50 == 49 { await Task.yield() }
        }
        let sentAt = clock.now
        for _ in 0..<5_000 {
            if agentVM.timeline.turns.first(where: { $0.turnId == "t" })?.items.first?.body.hasSuffix("w1999 ") == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let tailLag = sentAt.duration(to: clock.now)
        let memGrowth = Int64(botDeskPhysFootprintBytes()) - Int64(memBefore)
        print("PERF botDesk deltas=2000 agentPublishes=\(agentPublishes) deskPublishes=\(deskPublishes) tailLag=\(tailLag) elapsed=\(start.duration(to: clock.now)) memGrowthKB=\(memGrowth / 1024)")
        XCTAssertLessThan(memGrowth, 64 * 1024 * 1024, "a ~16 KB bot reply must not grow resident memory by tens of MB")
        let body = agentVM.timeline.turns.first(where: { $0.turnId == "t" })?.items.first?.body ?? ""
        XCTAssertTrue(body.hasPrefix("w0 ") && body.hasSuffix("w1999 "), "every delta must land in the embedded Agent App (sel=\(String(describing: agentVM.selectedThreadId)) tid=\(threadID) turns=\(agentVM.timeline.turns.map { "\($0.turnId):\($0.items.map { "\($0.id)/\($0.body.count)" })" }) status=\(agentVM.status))")
        XCTAssertEqual(deskPublishes, 0, "BotsViewModel must not republish per token")
        XCTAssertEqual(vm.deskStreamMainHopCountForTesting, 0)
        XCTAssertLessThan(agentPublishes, 200)
        XCTAssertLessThan(tailLag, .milliseconds(100), "the last token must paint right after it arrives")
    }

    func test_embeddedAgentAppOwnsLiveStream_becauseDeskMustNotRepublishPerTokenBesideAgentApp() async throws {
        // WHY: the embedded Agent App already paints this thread. A second desk
        // pipeline publishing deskLiveTimeline per token invalidates the whole
        // Bots tree that hosts the Agent App, which was the reported slowness.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout")
        vm.openDesk(bot)
        XCTAssertTrue(vm.createDeskThread())
        let threadID = try await linkDeskThreadByFirstSend(vm, context: context, router: router)
        XCTAssertNotNil(vm.deskAgentVM)
        var publishes = 0
        let sink = vm.$deskLiveTimeline.dropFirst().sink { _ in publishes += 1 }
        defer { sink.cancel() }
        vm.resetDeskStreamMainHopCountForTesting()
        let runID = AgentRunID()
        vm.runCoordinator(context.coordinator, didReceive: .turnStarted(turnId: "t1"), run: runID, threadId: threadID)
        for i in 0..<50 {
            vm.runCoordinator(
                context.coordinator,
                didReceive: .itemStarted(item: AssistantItem(id: "item-\(i)", turnId: "t1", type: .tool, startedAtMs: Int64(i))),
                run: runID,
                threadId: threadID
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(vm.deskStreamMainHopCountForTesting, 0, "events must drop at the nonisolated guard")
        XCTAssertEqual(vm.applyIncomingDeskEventCountForTesting, 0)
        XCTAssertEqual(publishes, 0)
        XCTAssertTrue(vm.deskLiveTimeline.turns.isEmpty)
    }

    func test_allowReadAndSendRequiresSelectedBotAndPreservesOnlyActiveMemoryGrant() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let botA = try vm.create(name: "A", title: "A")
        let botB = try vm.create(name: "B", title: "B")
        let hostID = context.liveActivityHostIdentity.serverId
        let target = BotContext.general

        XCTAssertNil(try context.botStore.getContextBinding(hostID: hostID, botID: botA.id, context: target))
        vm.openDesk(botB)
        XCTAssertFalse(vm.allowReadAndSend(botID: botA.id, context: target))
        XCTAssertNil(try context.botStore.getContextBinding(hostID: hostID, botID: botA.id, context: target))

        let memory = try context.botStore.grantContext(
            hostID: hostID, botID: botB.id, context: target,
            actions: [.memory], expectedRevision: nil
        )
        vm.openDesk(botB)
        XCTAssertTrue(vm.allowReadAndSend(botID: botB.id, context: target))
        let granted = try XCTUnwrap(context.botStore.getContextBinding(hostID: hostID, botID: botB.id, context: target))
        XCTAssertEqual(granted.actions, [.memory, .read, .send])
        XCTAssertEqual(granted.policyRevision, memory.policyRevision + 1)
        XCTAssertTrue(vm.allowReadAndSend(botID: botB.id, context: target))
        XCTAssertEqual(try context.botStore.getContextBinding(hostID: hostID, botID: botB.id, context: target)?.policyRevision, granted.policyRevision)

        let revoked = try context.botStore.revokeContext(
            hostID: hostID, botID: botB.id, context: target, expectedRevision: granted.policyRevision
        )
        XCTAssertTrue(vm.allowReadAndSend(botID: botB.id, context: target))
        let restored = try XCTUnwrap(context.botStore.getContextBinding(hostID: hostID, botID: botB.id, context: target))
        XCTAssertEqual(restored.actions, [.read, .send])
        XCTAssertEqual(restored.policyRevision, revoked.policyRevision + 1)
    }

    func test_revokedPinnedDeskSendRejectsExactConversationBeforeProviderOrReceiptAndKeepsDraft() async throws {
        // WHY: the embedded Agent App transform must enforce the canonical
        // conversation pin, even if another conversation is selected later.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "A", title: "A")
        let hostID = context.liveActivityHostIdentity.serverId
        _ = try context.botStore.grantContext(
            hostID: hostID, botID: bot.id, context: .general,
            actions: [.read, .send], expectedRevision: nil
        )
        vm.openDesk(bot)
        vm.deskRouting = BotDeskRouting(
            provider: .distill, providerInstanceID: "distill", model: "main-model",
            routingMode: .manual, runAsUser: .current()
        )
        XCTAssertTrue(vm.createDeskThread(in: .general))
        let pinned = try XCTUnwrap(vm.selectedConversation)
        let pinnedThreadID = try XCTUnwrap(pinned.linkedAgentThreadID)
        let agent = try XCTUnwrap(vm.deskAgentVM)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-desk-\(UUID().uuidString).txt")
        try Data("keep attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        agent.attachments = [AgentAttachment(path: file.path, kind: .file)]
        XCTAssertEqual(agent.attachments.map(\.displayName), [file.lastPathComponent])
        agent.prompt = "keep this draft"
        let transform = try XCTUnwrap(agent.embedding?.promptTransform)
        let otherBot = try vm.create(name: "B", title: "B", provider: .claude, model: "opus")
        let otherThread = AgentThread(title: "Other", provider: .claude, model: "opus")
        try context.threadRepo.upsert(otherThread)
        let other = BotConversation(botID: otherBot.id, title: "Other", linkedAgentThreadID: otherThread.id)
        try context.botStore.upsertConversation(other)
        vm.openDesk(otherBot)
        XCTAssertEqual(vm.selectedConversation?.id, other.id)
        XCTAssertNotEqual(other.id, pinned.id)
        _ = try context.botStore.revokeContext(
            hostID: hostID, botID: bot.id, context: .general,
            expectedRevision: try XCTUnwrap(context.botStore.getContextBinding(hostID: hostID, botID: bot.id, context: .general)).policyRevision
        )
        let messagesBefore = try context.messageRepo.listRecent(threadId: pinnedThreadID, limit: 100)
        let receiptBefore = try context.botStore.latestContextReceipt(botID: bot.id, conversationID: pinned.id)

        do {
            _ = try await transform("keep this draft", pinnedThreadID, AgentRunID())
            XCTFail("pinned conversation transform must reject before compile")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Bot conversation context is no longer authorized.")
        }

        XCTAssertNil(context.coordinator.activeRunId(threadId: pinnedThreadID), "revoked pinned send must not start provider")
        XCTAssertEqual(try context.messageRepo.listRecent(threadId: pinnedThreadID, limit: 100), messagesBefore)
        XCTAssertEqual(
            try context.botStore.latestContextReceipt(botID: bot.id, conversationID: pinned.id), receiptBefore,
            "rejected send must not compile a context receipt"
        )
        XCTAssertEqual(agent.prompt, "keep this draft")
        XCTAssertEqual(agent.attachments.map(\.displayName), [file.lastPathComponent])
    }

    func test_openDeskPinnedConversationDoesNotProvisionDockerGuest() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Pinned", title: "Context", provider: .distill)
        let binding = try context.botStore.grantContext(
            hostID: context.liveActivityHostIdentity.serverId,
            botID: bot.id,
            context: .general,
            actions: [.read, .send],
            expectedRevision: nil
        )
        let thread = AgentThread(title: "Pinned", provider: .distill, model: "test-main")
        let conversation = BotConversation(
            botID: bot.id,
            title: "Pinned",
            linkedAgentThreadID: thread.id
        )
        try context.botStore.createContextualConversation(
            conversation,
            newThread: thread,
            hostID: context.liveActivityHostIdentity.serverId,
            context: .general,
            policyRevision: binding.policyRevision
        )
        vm.desktopKindOverrideForTesting = .dockerDesktop
        vm.dockerGuestReadyOverrideForTesting = nil
        let fake = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )

        vm.openDesk(bot)

        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedConversation?.id, conversation.id)
        XCTAssertFalse((vm.errorMessage ?? "").contains("Contextual execution"))
    }

    func test_contextualDeskThreadCreatesPinnedLockedThreadForExplicitGrant() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let botA = try vm.create(name: "A", title: "A")
        let botB = try vm.create(name: "B", title: "B")
        let deskContext = BotContext.general
        let hostID = context.liveActivityHostIdentity.serverId
        for bot in [botA, botB] {
            _ = try context.botStore.grantContext(
                hostID: hostID, botID: bot.id, context: deskContext,
                actions: [.read, .send], expectedRevision: nil
            )
        }
        vm.openDesk(botA)
        vm.deskRouting = BotDeskRouting(
            provider: .distill, providerInstanceID: "distill", model: "main-model",
            routingMode: .manual, runAsUser: .current()
        )
        XCTAssertTrue(vm.createDeskThread(in: deskContext))
        let conversationA = try XCTUnwrap(vm.selectedConversation)
        vm.openDesk(botB)
        vm.deskRouting = BotDeskRouting(
            provider: .distill, providerInstanceID: "distill", model: "main-model",
            routingMode: .manual, runAsUser: .current()
        )
        XCTAssertTrue(vm.createDeskThread(in: deskContext))
        let conversationB = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(conversationA.id, conversationB.id)
        XCTAssertNotEqual(conversationA.linkedAgentThreadID, conversationB.linkedAgentThreadID)
        for conversation in [conversationA, conversationB] {
            let pin = try XCTUnwrap(context.botStore.conversationContextPin(conversationID: conversation.id))
            XCTAssertEqual(pin.context, deskContext)
            let threadID = try XCTUnwrap(conversation.linkedAgentThreadID)
            XCTAssertEqual(try context.botStore.conversationContextPin(linkedTo: threadID), pin)
            let thread = try XCTUnwrap(context.threadRepo.get(id: threadID))
            XCTAssertEqual(thread.actor, .bot(conversation.botID))
            XCTAssertNotNil(thread.actorLockedAt)
            XCTAssertEqual(thread.model, "main-model")
        }
    }

    func test_workspaceContextualDeskThreadPinsCurrentWorkspaceAndPreservesPriorPin() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "A", title: "A")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BotDeskContext-\(UUID().uuidString)", isDirectory: true)
        let dirA = base.appendingPathComponent("A", isDirectory: true)
        let dirB = base.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let workspaceA = try router.createWorkspace(name: "Workspace A", cwd: dirA.path)
        let workspaceB = try router.createWorkspace(name: "Workspace B", cwd: dirB.path)
        let hostID = context.liveActivityHostIdentity.serverId
        let contextA = BotContext.workspace(workspaceA.id)
        let contextB = BotContext.workspace(workspaceB.id)
        _ = try context.botStore.grantContext(hostID: hostID, botID: bot.id, context: contextA, actions: [.read, .send], expectedRevision: nil)
        _ = try context.botStore.grantContext(hostID: hostID, botID: bot.id, context: contextB, actions: [.read, .send], expectedRevision: nil)
        vm.openDesk(bot)
        vm.deskRouting = BotDeskRouting(provider: .distill, providerInstanceID: "distill", model: "main-model", routingMode: .manual, runAsUser: .current())
        XCTAssertTrue(vm.createDeskThread(in: contextA))
        let conversationA = try XCTUnwrap(vm.selectedConversation)
        let pinA = try XCTUnwrap(context.botStore.conversationContextPin(conversationID: conversationA.id))
        let threadA = try XCTUnwrap(context.threadRepo.get(id: try XCTUnwrap(conversationA.linkedAgentThreadID)))
        XCTAssertEqual(pinA.context, contextA)
        XCTAssertEqual(pinA.policyRevision, try XCTUnwrap(context.botStore.getContextBinding(hostID: hostID, botID: bot.id, context: contextA)).policyRevision)
        XCTAssertEqual(threadA.workspaceId, workspaceA.id)

        context.state.window.selectedWorkspaceID = workspaceB.id
        XCTAssertTrue(vm.createDeskThread(in: contextB))
        let conversationB = try XCTUnwrap(vm.selectedConversation)
        let pinB = try XCTUnwrap(context.botStore.conversationContextPin(conversationID: conversationB.id))
        let threadB = try XCTUnwrap(context.threadRepo.get(id: try XCTUnwrap(conversationB.linkedAgentThreadID)))
        XCTAssertEqual(vm.selectedPinnedContextLabel, "Workspace B")
        XCTAssertEqual(pinB.context, contextB)
        XCTAssertEqual(pinB.policyRevision, try XCTUnwrap(context.botStore.getContextBinding(hostID: hostID, botID: bot.id, context: contextB)).policyRevision)
        XCTAssertEqual(threadB.workspaceId, workspaceB.id)

        let priorID = conversationB.id
        XCTAssertTrue(vm.createDeskThread())
        let conversationB2 = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(conversationB2.id, priorID)
        XCTAssertEqual(try context.botStore.conversationContextPin(conversationID: conversationB2.id)?.context, contextB)
        XCTAssertEqual(try context.botStore.conversationContextPin(conversationID: conversationA.id), pinA)
        XCTAssertEqual(try context.botStore.conversationContextPin(conversationID: priorID), pinB)
        let threadB2 = try XCTUnwrap(context.threadRepo.get(id: try XCTUnwrap(conversationB2.linkedAgentThreadID)))
        XCTAssertEqual(threadB2.workspaceId, workspaceB.id)
    }

    func test_contextualDeskThreadWithoutGrantCreatesNothingOrChangesSelection() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "A", title: "A")
        vm.openDesk(bot)
        let selection = vm.selectedConversation?.id
        XCTAssertFalse(vm.createDeskThread(in: .general))
        XCTAssertEqual(vm.selectedConversation?.id, selection)
        XCTAssertTrue(try context.botStore.listConversations(botID: bot.id).isEmpty)
    }

    func test_createDeskThreadOnPinnedConversationPreservesContext() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "A", title: "A")
        let deskContext = BotContext.general
        let hostID = context.liveActivityHostIdentity.serverId
        _ = try context.botStore.grantContext(
            hostID: hostID, botID: bot.id, context: deskContext,
            actions: [.read, .send], expectedRevision: nil
        )
        vm.openDesk(bot)
        vm.deskRouting = BotDeskRouting(
            provider: .distill, providerInstanceID: "distill", model: "main-model",
            routingMode: .manual, runAsUser: .current()
        )
        XCTAssertTrue(vm.createDeskThread(in: deskContext))
        let old = try XCTUnwrap(vm.selectedConversation)
        XCTAssertTrue(vm.createDeskThread())
        let created = try XCTUnwrap(vm.selectedConversation)
        XCTAssertEqual(try context.botStore.conversationContextPin(conversationID: created.id)?.context, deskContext)
        XCTAssertNotEqual(old.id, created.id)
    }

    func test_missingWorkspaceGrantAndThreadCreationHaveNoEffects() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "A", title: "A")
        vm.openDesk(bot)
        vm.deskRouting = BotDeskRouting(
            provider: .distill, providerInstanceID: "distill", model: "main-model",
            routingMode: .manual, runAsUser: .current()
        )
        XCTAssertTrue(vm.createDeskThread())
        vm.composerText = "Keep"
        let selected = try XCTUnwrap(vm.selectedConversation?.id)
        let hostID = context.liveActivityHostIdentity.serverId
        let missingContext = BotContext.workspace(WorkspaceID(UUID()))
        let conversationsBefore = try context.botStore.listConversations(botID: bot.id).count
        let threadsBefore = try context.threadRepo.list().count

        XCTAssertFalse(vm.allowReadAndSend(botID: bot.id, context: missingContext))
        XCTAssertNil(try context.botStore.getContextBinding(hostID: hostID, botID: bot.id, context: missingContext))
        _ = try context.botStore.grantContext(
            hostID: hostID, botID: bot.id, context: missingContext,
            actions: [.read, .send], expectedRevision: nil
        )
        XCTAssertFalse(vm.createDeskThread(in: missingContext))
        XCTAssertEqual(vm.selectedConversation?.id, selected)
        XCTAssertEqual(vm.composerText, "Keep")
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, conversationsBefore)
        XCTAssertEqual(try context.threadRepo.list().count, threadsBefore)
    }

    func test_workspaceDeletedAfterGrantConfirmationRejectsGrantAndThreadCreation() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "A", title: "A")
        vm.openDesk(bot)
        vm.deskRouting = BotDeskRouting(
            provider: .distill, providerInstanceID: "distill", model: "main-model",
            routingMode: .manual, runAsUser: .current()
        )
        XCTAssertTrue(vm.createDeskThread())
        let selected = try XCTUnwrap(vm.selectedConversation?.id)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BotDeskDeleted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = try router.createWorkspace(name: "Grant target", cwd: base.path)
        let capturedBotID = bot.id
        let target = BotContext.workspace(workspace.id)
        try router.closeWorkspace(workspace.id)
        XCTAssertNil(context.state.workspaces[workspace.id])
        XCTAssertFalse(vm.allowReadAndSend(botID: capturedBotID, context: target))
        let hostID = context.liveActivityHostIdentity.serverId
        XCTAssertNil(try context.botStore.getContextBinding(hostID: hostID, botID: capturedBotID, context: target))
        _ = try context.botStore.grantContext(
            hostID: hostID, botID: capturedBotID, context: target,
            actions: [.read, .send], expectedRevision: nil
        )
        let conversationsBefore = try context.botStore.listConversations(botID: bot.id).count
        let threadsBefore = try context.threadRepo.list().count
        XCTAssertFalse(vm.createDeskThread(in: target))
        XCTAssertEqual(vm.selectedConversation?.id, selected)
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, conversationsBefore)
        XCTAssertEqual(try context.threadRepo.list().count, threadsBefore)
    }

    private func makeContext() throws -> AppContext {
        try AppContext(channel: .debug, appSupportOverride: directory)
    }

    private func seedBotCaller(
        context: AppContext,
        provider: AgentProvider,
        model: String,
        permissionMode: AgentPermissionMode
    ) throws -> (thread: AgentThread, run: AgentRun) {
        let thread = AgentThread(
            title: "Bot caller",
            provider: provider,
            model: model,
            status: .running,
            permissionMode: permissionMode
        )
        let run = AgentRun(
            threadId: thread.id,
            provider: provider,
            model: model,
            status: .running
        )
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(run)
        return (thread, run)
    }

    /// Exercises the durable handoff authority directly. Product Desk sends
    /// always start the selected Bot's primary AI first; the explicit
    /// `bot.peer.ask` path is covered above. These lifecycle regressions need a
    /// pending peer leg they can settle, reorder, restore, or delete themselves.
    @discardableResult
    private func submitPeerHandoffForTesting(
        context: AppContext,
        router: AppCommandRouter,
        viewModel: BotsViewModel,
        peer: BotDefinition,
        prompt: String
    ) throws -> Task<Void, Never> {
        let originBot = try XCTUnwrap(viewModel.selectedBot)
        if viewModel.selectedConversation == nil {
            viewModel.createDeskThread()
        }
        let originConversation = try XCTUnwrap(viewModel.selectedConversation)
        let routing = viewModel.deskRouting
        let originThread = AgentThread(
            title: originConversation.title,
            provider: routing.provider,
            providerInstanceId: routing.providerInstanceID,
            model: routing.resolvedModel(defaultModel: BotsViewModel.defaultModel(for:)),
            status: .running,
            permissionMode: routing.permissionMode,
            reasoningEffort: routing.reasoningEffort,
            serviceTier: routing.serviceTier,
            runAsUser: routing.runAsUser
        )
        try context.threadRepo.upsert(originThread)
        router.botsViewModel = viewModel
        context.botPeerHandoffAuthority.router = router
        viewModel.reconcilePeerHandoffsForTesting()
        return try XCTUnwrap(context.botPeerHandoffAuthority.submitAgentAppMention(
            peer: peer,
            text: prompt,
            peerText: prompt,
            originThread: originThread,
            activityID: AgentMessageID(),
            hostRunID: nil,
            providerSnapshots: [],
            resumeHostAfterPeer: false,
            originBot: originBot,
            originConversation: originConversation
        ))
    }

    private func makeDockerStudio() throws -> (AppContext, BotsViewModel, BotDefinition, RecordingDocker) {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let docker = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = true
        let created = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(created)
        vm.studioExecutionDestination = .ownVM
        let bot = try vm.saveStudio()
        return (context, vm, bot, docker)
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}

@MainActor
private final class BotDraftManualClock {
    private struct Scheduled {
        let deadlineNanoseconds: UInt64
        let action: () -> Void
    }

    private var nowNanoseconds: UInt64 = 0
    private var scheduled: [Scheduled] = []

    var pendingCount: Int { scheduled.count }

    func schedule(afterNanoseconds delay: UInt64, _ action: @escaping () -> Void) {
        scheduled.append(Scheduled(
            deadlineNanoseconds: nowNanoseconds + delay,
            action: action
        ))
    }

    func advance(byNanoseconds delta: UInt64) {
        nowNanoseconds += delta
        while let index = scheduled.indices.first(where: {
            scheduled[$0].deadlineNanoseconds <= nowNanoseconds
        }) {
            let action = scheduled.remove(at: index).action
            action()
        }
    }
}

/// Parks overlapping sendAgentMessage preflights until Task cancellation resumes them.
private final class SpawnClaimPark: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var entered = 0
    private var released = false

    func park() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            entered += 1
            let waiters = entryWaiters
            entryWaiters.removeAll()
            if released {
                lock.unlock()
                waiters.forEach { $0.resume() }
                cont.resume()
                return
            }
            parked.append(cont)
            lock.unlock()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered > 0 {
                lock.unlock()
                cont.resume()
                return
            }
            entryWaiters.append(cont)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let parked = self.parked
        self.parked.removeAll()
        lock.unlock()
        parked.forEach { $0.resume() }
    }
}

private final class OverlappingSendPreflightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    private var needed = 0
    private var parking: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false

    func park() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                entered += 1
                let ready = needed > 0 && entered >= needed
                let waiters = ready ? entryWaiters : []
                if ready { entryWaiters.removeAll() }
                if cancelled {
                    lock.unlock()
                    waiters.forEach { $0.resume() }
                    cont.resume()
                    return
                }
                parking.append(cont)
                lock.unlock()
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            lock.lock()
            let parked = parking
            parking.removeAll()
            cancelled = true
            lock.unlock()
            parked.forEach { $0.resume() }
        }
    }

    func waitUntilEntered(_ count: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            needed = count
            if entered >= count {
                lock.unlock()
                cont.resume()
                return
            }
            entryWaiters.append(cont)
            lock.unlock()
        }
    }
}

private struct T005PeerHandoffRouteFixture: Codable, Equatable {
    let provider: AgentProvider
    let providerInstanceID: String?
    let model: String
    let permissionMode: AgentPermissionMode?
    let reasoningEffort: AgentReasoningEffort?
    let serviceTier: AgentServiceTier?
    let runAsUser: AgentRunAsUser
    let routingConfiguration: AgentRoutingConfiguration?
}

private struct T005PeerHandoffRecordFixture: Codable, Equatable {
    let version: Int
    let activityID: UUID
    let originBotID: BotID?
    let originConversationID: BotConversationID?
    let originAgentThreadID: AgentThreadID?
    let peerBotID: BotID
    let peerConversationID: BotConversationID
    let peerThreadID: AgentThreadID?
    let peerRunID: AgentRunID?
    let inboundMessageID: UUID
    let peerName: String
    let peerTitle: String
    let peerHandle: String
    let outboundText: String
    let createdAt: Date
    let peerRoute: T005PeerHandoffRouteFixture
    let hostThreadID: AgentThreadID?
    let hostRunID: AgentRunID?
    let hostRoute: T005PeerHandoffRouteFixture?
    let replyText: String?
    let replyCreatedAt: Date?
    let phase: BotPeerHandoffPhase
}

private final class BlockingAcceptanceRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var writes = 0
    private var entered = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private let gate = DispatchSemaphore(value: 0)

    init(provider: AgentProvider) {
        self.provider = provider
    }

    var physicalWrites: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func waitUntilAcceptanceEntered() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered > 0 {
                lock.unlock()
                cont.resume()
                return
            }
            entryWaiters.append(cont)
            lock.unlock()
        }
    }

    func releaseWrite() {
        gate.signal()
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try await Task.detached { [self] in
            guard let permit = request.acceptancePermit else {
                throw AgentRunAcceptanceError.cancelled
            }
            try permit.withAcceptance {
                self.lock.lock()
                self.entered += 1
                let waiters = self.entryWaiters
                self.entryWaiters.removeAll()
                self.lock.unlock()
                waiters.forEach { $0.resume() }
                self.gate.wait()
                self.lock.lock()
                self.writes += 1
                self.lock.unlock()
            }
            onEvent(.status(.running))
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }.value
    }
}

final class ControlledBotHandoffRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider

    private struct PendingRun {
        let request: AgentRunRequest
        let turnID: String
        let onEvent: @Sendable (AgentRunEvent) -> Void
    }

    private let lock = NSLock()
    private var pendingByRunID: [AgentRunID: PendingRun] = [:]
    private var capturedRequests: [AgentRunRequest] = []
    private var capturedCancellationRequests: [AgentRunID] = []
    private let defersCancellationForTesting: Bool

    init(provider: AgentProvider, defersCancellationForTesting: Bool = false) {
        self.provider = provider
        self.defersCancellationForTesting = defersCancellationForTesting
    }

    var requests: [AgentRunRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    var cancellationRequestedRunIDs: [AgentRunID] {
        lock.withLock { capturedCancellationRequests }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let turnID = "turn-\(request.runId.value.uuidString.lowercased())"
        lock.lock()
        capturedRequests.append(request)
        pendingByRunID[request.runId] = PendingRun(
            request: request,
            turnID: turnID,
            onEvent: onEvent
        )
        lock.unlock()

        let providerThreadID = request.providerThreadId ?? request.threadId.value.uuidString
        onEvent(.status(.running))
        onEvent(.event(.threadStarted(
            threadId: providerThreadID,
            providerThreadId: providerThreadID
        )))
        onEvent(.event(.turnStarted(turnId: turnID)))
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            guard let self else { return }
            if self.defersCancellationForTesting {
                self.lock.withLock {
                    self.capturedCancellationRequests.append(request.runId)
                }
                return
            }
            _ = self.finish(runID: request.runId, status: .cancelled, reply: nil)
        }
    }

    @discardableResult
    func finish(
        promptContaining marker: String,
        status: AgentRunStatus = .completed,
        reply: String?
    ) -> Bool {
        let runID: AgentRunID?
        lock.lock()
        runID = capturedRequests.first {
            $0.prompt.contains(marker) && pendingByRunID[$0.runId] != nil
        }?.runId
        lock.unlock()
        guard let runID else { return false }
        return finish(runID: runID, status: status, reply: reply)
    }

    @discardableResult
    func finish(
        runID: AgentRunID,
        status: AgentRunStatus,
        reply: String?
    ) -> Bool {
        let pending: PendingRun?
        lock.lock()
        pending = pendingByRunID.removeValue(forKey: runID)
        lock.unlock()
        guard let pending else { return false }

        let providerThreadID = pending.request.providerThreadId
            ?? pending.request.threadId.value.uuidString
        if status == .completed, let reply {
            let itemID = "assistant-\(runID.value.uuidString.lowercased())"
            pending.onEvent(.event(.itemStarted(item: AssistantItem(
                id: itemID,
                turnId: pending.turnID,
                type: .assistantMessage,
                startedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
            ))))
            pending.onEvent(.event(.itemDelta(
                itemId: itemID,
                bodyAppend: reply,
                outputAppend: nil,
                summary: nil
            )))
            pending.onEvent(.event(.itemCompleted(itemId: itemID, finalState: .completed)))
            pending.onEvent(.event(.turnCompleted(turnId: pending.turnID, finalMessage: reply)))
        } else if status == .completed {
            pending.onEvent(.event(.turnCompleted(turnId: pending.turnID, finalMessage: nil)))
        } else if status == .failed {
            pending.onEvent(.event(.error(message: "controlled failure", recoverable: false)))
        }
        pending.onEvent(.status(status))
        pending.onEvent(.finished(
            status,
            finalMessage: status == .completed ? reply : nil,
            providerThreadId: providerThreadID
        ))
        return true
    }

    /// Streams one provider event into a still-running run.
    @discardableResult
    func emit(runID: AgentRunID, _ event: AssistantEvent) -> Bool {
        guard let pending = lock.withLock({ pendingByRunID[runID] }) else { return false }
        pending.onEvent(.event(event))
        return true
    }

}

/// Resident memory (phys_footprint), as Activity Monitor reports it.
private func botDeskPhysFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}
