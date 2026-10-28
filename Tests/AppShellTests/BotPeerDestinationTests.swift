import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import SocketServer

@MainActor
final class BotPeerDestinationTests: XCTestCase {
    func test_vmPeerUsesCurrentContextAndReceiptCannotReplayAfterPeerGrantRevocation() async throws {
        let fixture = try await makeFixture()
        let (ctx, router, runner, caller, peer, binding, callerDestination, peerDestination) = fixture
        defer { cleanUp(ctx) }
        let dispatcher = JSONRPCDispatcher(router: router)
        let identity: [String: JSONValue] = [
            "thread_id": .string(caller.threadId.value.uuidString.lowercased()),
            "run_id": .string(caller.runId.value.uuidString.lowercased()),
            BotPeerDelegation.capabilityRPCParameterKey: .string(try XCTUnwrap(
                caller.environment[AgentDelegationCapabilityTransport.environmentKey]
            )),
            "client_request_id": .string("vm-peer-consultation-1"),
        ]
        let ask = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "bot.peer.ask", params:
            identity.merging([
                "handle": .string(peer.handle),
                "prompt": .string("Inspect this workspace and report the result."),
                "reply_mode": .string("consult"),
            ], uniquingKeysWith: { _, value in value })
        )
        let pending = Task { @MainActor in await dispatcher.dispatchUnixSocket(ask) }
        defer { pending.cancel() }
        let started = await waitUntil { runner.requests.count == 2 }
        XCTAssertTrue(started, "An admitted peer must reach the provider runner")
        let request = try XCTUnwrap(runner.requests.first { $0.threadId != caller.threadId })
        XCTAssertNil(request.distillMainEffortSelection,
            "an omitted caller effort must not become a fixed effort unsupported by its selected model")
        let pin = try XCTUnwrap(try ctx.botStore.conversationContextPin(linkedTo: request.threadId))
        XCTAssertEqual(pin.hostID, binding.hostID)
        XCTAssertEqual(pin.botID, peer.id)
        XCTAssertEqual(pin.context, binding.context)
        XCTAssertEqual(pin.policyRevision, binding.policyRevision)
        XCTAssertEqual(try ctx.threadRepo.get(id: request.threadId)?.executionTarget, .vm)
        XCTAssertEqual(try ctx.botStore.threadExecutionDestination(request.threadId), peerDestination)
        XCTAssertEqual(try ctx.botStore.threadExecutionDestination(caller.threadId), callerDestination)
        XCTAssertTrue(runner.finish(runID: request.runId, status: .completed, reply: "Verified in the peer VM."))
        let completed = await pending.value
        XCTAssertNil(completed.error)
        XCTAssertEqual(completed.result?.objectValue?["status"]?.stringValue, "completed")
        XCTAssertEqual(completed.result?.objectValue?["reply"]?.stringValue, "Verified in the peer VM.")
        XCTAssertEqual(completed.result?.objectValue?["bot"]?.objectValue?["id"]?.stringValue,
                       peer.id.value.uuidString.lowercased())
        XCTAssertEqual(completed.result?.objectValue?["thread_id"]?.stringValue,
                       request.threadId.value.uuidString.lowercased())
        XCTAssertEqual(completed.result?.objectValue?["attributed_reply_already_displayed"]?.boolValue, true)

        let statusRequest = JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "bot.peer.receipt.status",
            params: identity.merging(["method": .string("bot.peer.ask")], uniquingKeysWith: { _, value in value }))
        let committed = await dispatcher.dispatchUnixSocket(statusRequest)
        XCTAssertNil(committed.error)
        XCTAssertEqual(committed.result?.objectValue?["result"]?.objectValue?["reply"]?.stringValue,
                       "Verified in the peer VM.")

        let settings = try router.invokeDelegatedBotSelfConfig(
            callerThread: caller.threadId, callerRun: caller.runId,
            toolName: BotSelfConfigCatalog.getSettings, arguments: ["bot_id": .string(peer.id.value.uuidString)],
            delegationCapability: caller.environment[AgentDelegationCapabilityTransport.environmentKey]
        )
        XCTAssertEqual(settings.objectValue?["memory_available"]?.boolValue, false,
            "delegated settings must keep the peer's workspace memory boundary")
        XCTAssertEqual(settings.objectValue?["memory"]?.arrayValue?.count, 0)

        // The caller remains authorized: revoking only the peer must also seal its cached reply.
        _ = try ctx.botStore.revokeContext(hostID: binding.hostID, botID: peer.id,
            context: binding.context, expectedRevision: binding.policyRevision)
        XCTAssertEqual(ctx.coordinator.activeRunId(threadId: caller.threadId), caller.runId)
        XCTAssertNoThrow(try router.listBotPeers(callerThread: caller.threadId, callerRun: caller.runId,
            delegationCapability: caller.environment[AgentDelegationCapabilityTransport.environmentKey]))
        let reloaded = JSONRPCDispatcher(router: router)
        let replay = await reloaded.dispatchUnixSocket(ask)
        XCTAssertEqual(replay.error?.code, -32050)
        XCTAssertNil(replay.result)
        let revokedStatus = await reloaded.dispatchUnixSocket(statusRequest)
        XCTAssertEqual(revokedStatus.error?.code, -32050)
        XCTAssertNil(revokedStatus.result)
        XCTAssertThrowsError(try router.invokeDelegatedBotSelfConfig(
            callerThread: caller.threadId, callerRun: caller.runId,
            toolName: BotSelfConfigCatalog.getSettings, arguments: ["bot_id": .string(peer.id.value.uuidString)],
            delegationCapability: caller.environment[AgentDelegationCapabilityTransport.environmentKey]
        ))
        XCTAssertEqual(runner.requests.count, 2)
        XCTAssertEqual(try ctx.botStore.listConversations(botID: peer.id).count, 1)
    }

    func test_vmCallerRefusesMacDestinationBeforeCreatingPeerWork() async throws {
        let (ctx, router, runner, caller, peer, _, _, _) = try await makeFixture()
        defer { cleanUp(ctx) }
        let messagesBefore = try ctx.messageRepo.list(threadId: caller.threadId).count
        let destinations: [(BotExecutionDestination, Int)] = [(.mac, -32052)]
        for (destination, errorCode) in destinations {
            _ = try ctx.botStore.setExecutionDestination(destination, botID: peer.id)
            do {
                _ = try await router.askBotPeer(callerThread: caller.threadId, callerRun: caller.runId,
                    handle: peer.handle, prompt: "Inspect the workspace.", replyMode: .consult,
                    consultationID: nil, wait: false,
                    delegationCapability: caller.environment[AgentDelegationCapabilityTransport.environmentKey])
                XCTFail("A VM caller must reject destination \(destination)")
            } catch let error as JSONRPCError {
                XCTAssertEqual(error.code, errorCode)
                XCTAssertEqual(error.data?.objectValue?["admission"]?.stringValue, "rejected")
            }
            XCTAssertTrue(try ctx.botStore.listConversations(botID: peer.id).isEmpty)
            XCTAssertEqual(try ctx.messageRepo.list(threadId: caller.threadId).count, messagesBefore)
            XCTAssertEqual(runner.requests.count, 1)
            XCTAssertEqual(ctx.coordinator.activeRunId(threadId: caller.threadId), caller.runId)
        }
    }

    func test_vmCallerConsultsPeerOnItsOwnVMWhileTheParentWaits() async throws {
        // WHY: "The caller and peer share one VM" refused every consultation
        // between two Bots on one VM. The delegated peer must run on that VM
        // concurrently with its waiting parent.
        let (ctx, router, runner, caller, peer, _, callerDestination, _) = try await makeFixture()
        defer { cleanUp(ctx) }
        _ = try ctx.botStore.setExecutionDestination(callerDestination, botID: peer.id)
        let pending = Task { @MainActor in
            try await router.askBotPeer(callerThread: caller.threadId, callerRun: caller.runId,
                handle: peer.handle, prompt: "Inspect the workspace.", replyMode: .consult,
                consultationID: nil, wait: true,
                delegationCapability: caller.environment[AgentDelegationCapabilityTransport.environmentKey])
        }
        defer { pending.cancel() }
        let started = await waitUntil { runner.requests.count == 2 }
        if !started, case .failure(let error) = await pending.result { XCTFail("peer ask failed: \(error)") }
        XCTAssertTrue(started, "the same-VM peer must reach the provider runner")
        XCTAssertEqual(ctx.coordinator.activeRunId(threadId: caller.threadId), caller.runId,
            "the parent keeps running while its peer runs on the same VM")
    }

    private func makeFixture() async throws -> (AppContext, AppCommandRouter, ControlledBotHandoffRunner,
        AgentRunRequest, BotDefinition, BotContextBinding, BotExecutionDestination, BotExecutionDestination) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RC2PeerDestination-\(UUID().uuidString)")
        let workspaceDirectory = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        var ready = false
        defer { if !ready { cleanUp(ctx) } }
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        ctx.coordinator.replaceProvider(.distill, runner: runner)
        router.rememberProviderSnapshotsForSend([AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: .distill)],
            binaryPath: "/usr/bin/true", authenticated: true, id: "distill"
        )])
        let workspace = try router.createWorkspace(name: "Peer destination", cwd: workspaceDirectory.path)
        let callerBot = try ctx.botStore.create(name: "Caller", title: "Coordinator", description: "")
        let peer = try ctx.botStore.create(name: "Peer", title: "Reviewer", description: "")
        let callerDestination = BotExecutionDestination.virtualMachine(try ctx.botStore.saveVirtualMachine(name: "Caller VM").id)
        let peerDestination = BotExecutionDestination.virtualMachine(try ctx.botStore.saveVirtualMachine(name: "Peer VM").id)
        _ = try ctx.botStore.setExecutionDestination(callerDestination, botID: callerBot.id)
        _ = try ctx.botStore.setExecutionDestination(peerDestination, botID: peer.id)
        let hostID = ctx.liveActivityHostIdentity.serverId
        let context = BotContext.workspace(workspace.id)
        let callerBinding = try ctx.botStore.grantContext(hostID: hostID, botID: callerBot.id, context: context,
            actions: [.read, .send, .configure, .files, .delegate], expectedRevision: nil)
        let peerBinding = try ctx.botStore.grantContext(hostID: hostID, botID: peer.id, context: context,
            actions: [.read, .send, .configure, .files], expectedRevision: nil)
        let thread = AgentThread(workspaceId: workspace.id, title: "VM caller", provider: .distill,
            model: "fake-model", status: .completed,
            modelSelection: AgentModelSelection(provider: .distill, modelId: "fake-model"))
        _ = try ctx.botStore.createContextualConversation(
            BotConversation(botID: callerBot.id, title: thread.title, linkedAgentThreadID: thread.id),
            newThread: thread, hostID: hostID, context: context,
            policyRevision: callerBinding.policyRevision, executionDestination: callerDestination
        )
        _ = try await router.sendAgentMessage(thread: thread.id, text: "Ask the peer to inspect this workspace.",
            provider: .distill, model: "fake-model", permissionMode: nil, reasoningEffort: nil)
        let started = await waitUntil { !runner.requests.isEmpty }
        XCTAssertTrue(started, "The contextual VM caller must start")
        let request = try XCTUnwrap(runner.requests.first)
        ready = true
        return (ctx, router, runner, request, peer, peerBinding, callerDestination, peerDestination)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func cleanUp(_ ctx: AppContext) {
        for threadID in ctx.coordinator.activeThreadIdsSnapshot() { ctx.coordinator.stopRun(threadId: threadID) }
        try? FileManager.default.removeItem(at: ctx.appSupportDirectory.deletingLastPathComponent())
    }
}
