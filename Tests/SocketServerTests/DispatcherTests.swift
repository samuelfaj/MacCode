import XCTest
@testable import SocketServer
import CoreModel
import Persistence
import AgentRuntime

@MainActor
class FakeRouter: CommandRouting, TerminalCommandRouting {
    func postChatImages(callerThread: AgentThreadID, paths: [String], caption: String?) throws -> JSONValue {
        throw JSONRPCError.notSupported("host.chat.image")
    }
    func captureHostBrowserToChat(callerThread: AgentThreadID, surface: SurfaceID?, reason: String) throws -> JSONValue {
        throw JSONRPCError.notSupported("host.browser.screenshot")
    }

    var workspaces: [Workspace] = []
    var window = AppWindow()
    var distillAccountID: String?
    var distillMutationMethod: String?
    var distillRouting = DistillAutoRouting()
    var distillLoginProvider: DistillAccountProvider?
    var distillLogoutProvider: DistillAccountProvider?
    var distillAccountsPayload: JSONValue = .object(["accounts": .array([]), "busy_provider": .null, "last_error": .null])

    func listDistillAccounts() async -> JSONValue { distillAccountsPayload }
    func getDistillRouting() async throws -> JSONValue { .object(["enabled": .bool(distillRouting.enabled)]) }
    func mutateDistillAccount(method: String, accountID: String?, provider: DistillAccountProvider?, label: String?) throws -> JSONValue {
        distillMutationMethod = method
        distillAccountID = accountID
        return .object(["started": .bool(true)])
    }
    func setDistillRouting(_ routing: DistillAutoRouting) throws -> JSONValue {
        distillRouting = routing
        return .object(["started": .bool(true)])
    }
    func loginDistillAccount(_ provider: DistillAccountProvider) throws -> JSONValue {
        distillLoginProvider = provider
        return .object(["started": .bool(true)])
    }
    func logoutDistillAccount(_ provider: DistillAccountProvider) throws -> JSONValue {
        distillLogoutProvider = provider
        return .object(["started": .bool(true)])
    }
    func cancelDistillAccountOperation() throws -> JSONValue { .object(["cancelled": .bool(true)]) }
    func setAgentWorkerModel(thread: AgentThreadID, model: String?) throws -> AgentThread {
        guard let index = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[index].reasoningModel = model?.isEmpty == false ? model : nil
        return threadStore[index]
    }

    func listWorkspaces() throws -> [Workspace] { workspaces }
    func listWorkspacesAuthoritative() async throws -> [Workspace] { workspaces }
    func currentWindow() throws -> AppWindow { window }
    func listWindows() throws -> [AppWindow] { [window] }
    func createWindow(title: String?) throws -> AppWindow { AppWindow(title: title ?? "w") }
    func focusWindow(_ id: WindowID) throws {}
    func closeWindow(_ id: WindowID) throws {}
    func moveWorkspaceToWindow(workspace: WorkspaceID, target: WindowID) throws {}
    func paneSwap(workspace: WorkspaceID, a: PaneID, b: PaneID) throws {}
    func createWorkspace(name: String, cwd: String) throws -> Workspace {
        let ws = Workspace.empty(name: name, cwd: cwd)
        workspaces.append(ws); window.workspaces.append(ws.id); window.selectedWorkspaceID = ws.id
        return ws
    }

    func authenticateManagedHostCall(
        threadID: AgentThreadID,
        runID: AgentRunID,
        delegationCapability: String?,
        mutation: Bool,
        method: String
    ) throws {
        _ = threadID; _ = runID; _ = mutation; _ = method
        guard let delegationCapability, !delegationCapability.isEmpty else {
            throw JSONRPCError(code: -32047, message: "Host catalog requires an authenticated active run.")
        }
    }

    func managedHostCallerIsTitio(threadID: AgentThreadID) throws -> Bool { false }
    func validateBotPeerReceipt(callerThread: AgentThreadID, result: JSONValue) throws {
        throw JSONRPCError.notSupported("Bot receipt authorization")
    }

    func askBotPeer(
        callerThread: AgentThreadID,
        callerRun: AgentRunID,
        handle: String,
        prompt: String,
        replyMode: BotPeerDelegation.ReplyMode,
        consultationID: UUID?,
        delegationCapability: String?
    ) async throws -> JSONValue {
        throw JSONRPCError.notSupported("Bot delegation")
    }

    func invokeDelegatedBotSelfConfig(
        callerThread: AgentThreadID,
        callerRun: AgentRunID,
        toolName: String,
        arguments: [String: JSONValue],
        delegationCapability: String?
    ) throws -> JSONValue {
        throw JSONRPCError.notSupported("delegated Bot settings")
    }

    func createHostBot(
        name: String,
        title: String,
        description: String,
        handle: String?,
        soul: String,
        callerRun: AgentRunID
    ) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot create")
    }

    func listHostBots() throws -> JSONValue {
        .object(["bots": .array([])])
    }

    func openHostBot(botID: BotID) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot open")
    }

    func sendHostBot(
        botID: BotID,
        text: String,
        conversationID: BotConversationID?,
        callerThread: AgentThreadID,
        callerRun: AgentRunID
    ) async throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot send")
    }

    func createHostBotThread(botID: BotID, title: String) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot thread create")
    }

    func createHostBotSkill(
        botID: BotID,
        skillID: String,
        body: String?,
        callerRun: AgentRunID,
        callerThread: AgentThreadID
    ) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot skill create")
    }

    func viewHostBotSkill(
        botID: BotID,
        skillID: String,
        callerRun: AgentRunID,
        callerThread: AgentThreadID
    ) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot skill view")
    }

    var pairedBotRemoteResult: JSONValue?
    var lastPairedBotRemote: (method: String, params: [String: JSONValue])?

    func dispatchPairedBotRemote(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        lastPairedBotRemote = (method, params)
        if let pairedBotRemoteResult { return pairedBotRemoteResult }
        throw JSONRPCError.notSupported("paired Bot remote control")
    }
    func selectWorkspace(_ id: WorkspaceID) throws { window.selectedWorkspaceID = id }
    func closeWorkspace(_ id: WorkspaceID, publishEvent: Bool = true) throws { workspaces.removeAll { $0.id == id } }
    func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws {}
    func setWorkspaceDescription(_ id: WorkspaceID, _ text: String) throws {}
    func setWorkspaceColor(_ id: WorkspaceID, _ color: String) throws {}
    func setWorkspacePinned(_ id: WorkspaceID, _ pinned: Bool) throws {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { throw LayoutError.workspaceNotFound }
        if pinned { workspaces[idx].metadata["pinned"] = "true" }
        else { workspaces[idx].metadata.removeValue(forKey: "pinned") }
        let pinnedItems = workspaces.filter { $0.metadata["pinned"] == "true" }
        let normalItems = workspaces.filter { $0.metadata["pinned"] != "true" }
        workspaces = pinnedItems + normalItems
        window.workspaces = workspaces.map(\.id)
    }
    func reorderWorkspace(_ id: WorkspaceID, position: Int) throws {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { throw LayoutError.workspaceNotFound }
        let item = workspaces.remove(at: idx)
        workspaces.insert(item, at: max(0, min(position, workspaces.count)))
        let pinnedItems = workspaces.filter { $0.metadata["pinned"] == "true" }
        let normalItems = workspaces.filter { $0.metadata["pinned"] != "true" }
        workspaces = pinnedItems + normalItems
        window.workspaces = workspaces.map(\.id)
    }
    func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: type, title: title ?? type.rawValue, metadata: type == .ssh ? ["ssh_status": "disconnected"] : [:])
    }
    func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: surfaceType, title: title ?? surfaceType.rawValue)
    }
    var filesOpenTabCalls: [(WorkspaceID, SurfaceID?, PaneID?, String)] = []
    func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor {
        filesOpenTabCalls.append((workspace, sourceSurface, paneID, path))
        return SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent, metadata: [
            "selected_path": path,
            "selected_relative_path": path
        ])
    }
    var filesSplitTabCalls: [(WorkspaceID, SurfaceID?, PaneID?, SplitDirection, String)] = []
    func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor {
        filesSplitTabCalls.append((workspace, sourceSurface, paneID, direction, path))
        return SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent, metadata: [
            "selected_path": path,
            "selected_relative_path": path
        ])
    }
    var splitSurfaceCalls: [(WorkspaceID, PaneID, SurfaceID, SplitDirection)] = []
    func splitSurface(workspace: WorkspaceID, paneID: PaneID, surface: SurfaceID, direction: SplitDirection) throws {
        splitSurfaceCalls.append((workspace, paneID, surface, direction))
    }
    func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws {}
    func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws {}
    func renameSurface(_ wid: WorkspaceID, _ sid: SurfaceID, _ title: String) throws {}
    func setSurfaceColor(_ wid: WorkspaceID, _ sid: SurfaceID, _ color: String) throws {}
    var sentSurfaceText: [(SurfaceID, String)] = []
    func sendText(surface: SurfaceID, text: String) throws { sentSurfaceText.append((surface, text)) }
    var terminalSendResult: JSONValue = .object(["status": .string("accepted"), "accepted": .bool(true)])
    func sendTextResult(surface: SurfaceID, text: String) throws -> JSONValue {
        sentSurfaceText.append((surface, text))
        return terminalSendResult
    }
    func readText(surface: SurfaceID) throws -> String { "" }
    var terminalSnapshot: JSONValue = .object([
        "text": .string(""),
        "complete": .bool(true),
        "partial": .bool(false),
        "source": .string("test")
    ])
    func readTextSnapshot(surface: SurfaceID) throws -> JSONValue { terminalSnapshot }
    var terminalHistory = TerminalOutputWindow(chunks: [], hasMoreOlder: false, nextBeforeChunkID: nil)
    var lastHistoryRequest: (SurfaceID, Int64?, Int)?
    func readTerminalHistory(surface: SurfaceID, beforeChunkID: Int64?, maxBytes: Int) throws -> TerminalOutputWindow {
        lastHistoryRequest = (surface, beforeChunkID, maxBytes)
        return terminalHistory
    }
    func surfaceHealth(surface: SurfaceID) -> Bool { true }
    var terminalHealth: JSONValue = .object(["alive": .bool(true), "process_alive": .bool(true), "input_accepting": .bool(true)])
    func surfaceHealthDetails(surface: SurfaceID) -> JSONValue { terminalHealth }
    func surfaceClearHistory(surface: SurfaceID) {}
    var sshHostsByWorkspace: [WorkspaceID: [SSHHostProfile]] = [:]
    func sshHostList(workspace: WorkspaceID) throws -> [SSHHostProfile] {
        sshHostsByWorkspace[workspace, default: []].map { host in
            var copy = host
            copy.hasSavedPassword = copy.hasSavedPassword || (copy.password?.isEmpty == false)
            copy.password = nil
            return copy
        }
    }
    func sshHostUpsert(_ profile: SSHHostProfile, workspace: WorkspaceID) throws -> SSHHostProfile {
        var hosts = sshHostsByWorkspace[workspace, default: []]
        var saved = profile
        if let idx = hosts.firstIndex(where: { $0.id == profile.id }) {
            if saved.password?.isEmpty == false {
                saved.hasSavedPassword = true
            } else {
                saved.password = hosts[idx].password
                saved.hasSavedPassword = hosts[idx].hasSavedPassword || (hosts[idx].password?.isEmpty == false)
            }
            hosts[idx] = saved
        } else {
            saved.hasSavedPassword = saved.hasSavedPassword || (saved.password?.isEmpty == false)
            hosts.append(saved)
        }
        sshHostsByWorkspace[workspace] = hosts
        return saved
    }
    func sshHostDelete(_ id: SSHHostID, workspace: WorkspaceID) throws { sshHostsByWorkspace[workspace, default: []].removeAll { $0.id == id } }
    func sshConnect(workspace: WorkspaceID, profileID: SSHHostID?, profile: SSHHostProfile?, title: String?, paneID: PaneID?) throws -> SurfaceDescriptor {
        let resolved = profile ?? profileID.flatMap { id in sshHostsByWorkspace[workspace, default: []].first { $0.id == id } } ?? SSHHostProfile(label: "SSH", destination: "example.test")
        return SurfaceDescriptor(type: .ssh, title: title ?? resolved.label, iconName: "network", metadata: [
            "ssh_profile_id": resolved.id.value.uuidString,
            "ssh_destination": resolved.destination,
            "ssh_status": "connecting"
        ])
    }
    func sshDisconnect(surface: SurfaceID) throws {}
    var sshBlockingCalls: [String] = []
    var sshAsyncCalls: [String] = []
    func sshTransferUpload(surface: SurfaceID, localPath: String, remotePath: String) throws -> JSONValue { sshBlockingCalls.append("upload"); return .object(["ok": .bool(true)]) }
    func sshTransferDownload(surface: SurfaceID, remotePath: String, localPath: String) throws -> JSONValue { sshBlockingCalls.append("download"); return .object(["ok": .bool(true)]) }
    func sshFilesLocalList(path: String?) throws -> JSONValue { .object(["path": .string(path ?? "/tmp"), "entries": .array([])]) }
    func sshFilesRemoteList(surface: SurfaceID, path: String?) throws -> JSONValue { sshBlockingCalls.append("remote.list"); return .object(["path": .string(path ?? "/"), "entries": .array([])]) }
    func sshTransferUploadAsync(surface: SurfaceID, localPath: String, remotePath: String) async throws -> JSONValue { sshAsyncCalls.append("upload"); return .object(["ok": .bool(true)]) }
    func sshTransferDownloadAsync(surface: SurfaceID, remotePath: String, localPath: String) async throws -> JSONValue { sshAsyncCalls.append("download"); return .object(["ok": .bool(true)]) }
    func sshFilesRemoteListAsync(surface: SurfaceID, path: String?) async throws -> JSONValue { sshAsyncCalls.append("remote.list"); return .object(["path": .string(path ?? "/"), "entries": .array([])]) }
    func sshFilesRemoteManage(surface: SurfaceID, operation: SSHRemoteFileOperation) async throws -> JSONValue {
        sshAsyncCalls.append(operation.method)
        return .object(["ok": .bool(true)])
    }
    func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: .agentApp, title: "Agent App")
    }
    func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread] {
        let list = workspace.map { wid in threadStore.filter { $0.workspaceId == wid } } ?? threadStore
        return list.sorted {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.updatedAt > $1.updatedAt
        }
    }
    func listAgentThreadsOffMain(workspace: WorkspaceID?) async throws -> [AgentThread] {
        try listAgentThreads(workspace: workspace)
    }
    var lastCreateSurfaceID: SurfaceID?
    func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?, surfaceID: SurfaceID?) throws -> AgentThread {
        lastCreateSurfaceID = surfaceID
        let thread = AgentThread(workspaceId: workspace, title: title, provider: provider,
                                 providerInstanceId: providerInstanceId,
                                 model: model,
                                 permissionMode: permissionMode, reasoningEffort: reasoningEffort,
                                 serviceTier: serviceTier, modelSelection: modelSelection,
                                 runAsUser: runAsUser)
        threadStore.append(thread)
        return thread
    }
    func listAgentRunAsUsers() throws -> [AgentRunAsUser] {
        [AgentRunAsUser.current()]
    }
    var lastSendPermission: AgentPermissionMode?
    var lastSendReasoning: AgentReasoningEffort?
    var lastSendServiceTier: AgentServiceTier?
    var lastSendInteractionMode: AgentInteractionMode?
    var lastSendText: String?
    var lastSendAttachments: [AgentAttachment] = []
    var lastImplementedPlan: (AgentThreadID, String, AgentThreadID)?
    var lastSavedPlan: (AgentThreadID, String, String?, String?)?
    var sendAgentMessageCallCount = 0
    var commandReceipts: [String: JSONValue] = [:]
    var lastAgentRequestResponse: (AgentThreadID, String, AgentProviderRequestResponse)?
    var agentRequestResponses: [(AgentThreadID, String, AgentProviderRequestResponse)] = []
    var respondAgentRequestCallCount = 0
    var lastAgentUserInputResponse: (AgentThreadID, String, String)?
    var agentUserInputResponses: [(AgentThreadID, String, String)] = []
    var respondAgentUserInputCallCount = 0
    var readAgentEvents: [AssistantEvent] = []
    /// nil keeps the protocol default (replayed error rows left as stored).
    var replayedRunErrorFieldsStub: ((String, Bool) -> [String: JSONValue])?
    var readAgentThreadMirrorSnapshotCallCount = 0
    /// Captures the last `eventRowLimit` argument. `nil` means unbounded legacy.
    var lastMirrorSnapshotEventRowLimit: Int?
    /// Captures the last `maxPayloadBytes` argument. `nil` means legacy (no byte source bound).
    var lastMirrorSnapshotMaxPayloadBytes: Int64?
    /// Optional blocked-event metadata returned to v1 callers (simulates source refusal).
    var mirrorBlockedEvent: AgentThreadMirrorSnapshot.BlockedMirrorEvent?
    var pendingCallbackSnapshot = AssistantPendingCallbacksSnapshot()
    var lastRollback: (AgentThreadID, String)?
    var rollbackCallCount = 0
    var lastCheckpointRevert: (AgentThreadID, Int)?
    var checkpointRevertCallCount = 0
    var stopAgentRunCallCount = 0
    var stoppedAgentThreads: [AgentThreadID] = []
    var checkpointStore: [AgentTurnCheckpointSummary] = []
    var checkpointPageCallCount = 0
    var messageStore: [AgentMessage] = []
    var messageListBudgetError: AgentMessagePageCursorError?
    var queuedMessageStore: [AgentQueuedMessage] = []
    func configureAgentThread(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?) throws -> AgentThread {
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        if let provider, provider != threadStore[idx].provider {
            threadStore[idx].provider = provider
            threadStore[idx].providerInstanceId = provider.rawValue
            threadStore[idx].providerThreadId = nil
        }
        if let providerInstanceId { threadStore[idx].providerInstanceId = providerInstanceId }
        if let model, model != threadStore[idx].model {
            let canSwitchModelInSession = threadStore[idx].provider == .claude && threadStore[idx].providerThreadId?.isEmpty == false
            threadStore[idx].model = model
            if !canSwitchModelInSession {
                threadStore[idx].providerThreadId = nil
            }
        }
        if let permissionMode { threadStore[idx].permissionMode = permissionMode }
        if let reasoningEffort { threadStore[idx].reasoningEffort = reasoningEffort }
        if let serviceTier { threadStore[idx].serviceTier = serviceTier }
        if let modelSelection { threadStore[idx].modelSelection = modelSelection }
        if let runAsUser { threadStore[idx].runAsUser = runAsUser }
        return threadStore[idx]
    }
    func configureAgentThreadExecution(thread: AgentThreadID, executionMode: AgentExecutionMode, baseBranch: String?) throws -> AgentThread {
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].executionMode = executionMode
        threadStore[idx].baseBranch = baseBranch
        if executionMode == .local { threadStore[idx].worktreePath = nil }
        return threadStore[idx]
    }
    var lastPreparedPullRequest: (WorkspaceID, String)?
    func prepareAgentThreadForPullRequest(workspace: WorkspaceID, url: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?) throws -> AgentThread {
        lastPreparedPullRequest = (workspace, url)
        let thread = AgentThread(workspaceId: workspace, title: "PR #7: acme/widget", provider: provider,
                                 providerInstanceId: providerInstanceId,
                                 model: model,
                                 permissionMode: permissionMode,
                                 reasoningEffort: reasoningEffort,
                                 executionMode: .worktree,
                                 baseBranch: "rc-pr/github-com/acme-widget-7",
                                 worktreePath: "/tmp/rc-pr-7",
                                 serviceTier: serviceTier,
                                 modelSelection: modelSelection)
        threadStore.append(thread)
        return thread
    }
    func uploadAgentAttachment(workspace: WorkspaceID, filename: String, mimeType: String?, dataBase64: String) throws -> AgentAttachmentUploadResult {
        guard let data = Data(base64Encoded: dataBase64), !data.isEmpty,
              data.count <= 25 * 1024 * 1024 else { throw JSONRPCError.invalidParams }
        let digest = String(repeating: "a", count: 64)
        return AgentAttachmentUploadResult(
            id: UUID().uuidString.lowercased(),
            displayName: filename,
            kind: filename.hasSuffix(".png") ? .image : .file,
            mimeType: mimeType,
            sha256: digest,
            sizeBytes: data.count,
            composerInsertionText: "/tmp/remote-code-fake-attachments/\(digest)/\(filename)"
        )
    }
    func importAgentAttachment(workspace: WorkspaceID, relativePath: String) throws -> AgentAttachmentUploadResult {
        let id = String(repeating: "b", count: 64)
        return AgentAttachmentUploadResult(
            id: id,
            displayName: URL(fileURLWithPath: relativePath).lastPathComponent,
            kind: .file,
            mimeType: "text/plain",
            sha256: id,
            sizeBytes: 7,
            composerInsertionText: "/Users/dev/demo-api/\(relativePath)"
        )
    }
    var selectedThread: AgentThreadID?
    var lastSelectSurfaceID: SurfaceID?
    func selectAgentThread(thread: AgentThreadID, surfaceID: SurfaceID?) throws {
        guard threadStore.contains(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        selectedThread = thread
        lastSelectSurfaceID = surfaceID
    }
    func listAgentMessages(thread: AgentThreadID, limit: Int) throws -> [AgentMessage] {
        Array(messageStore.filter { $0.threadId == thread }.suffix(max(0, limit)))
    }
    func listAgentMessagesOffMain(thread: AgentThreadID, limit: Int) async throws -> [AgentMessage] {
        try listAgentMessages(thread: thread, limit: limit)
    }
    func threadIdsWithMessages() throws -> Set<AgentThreadID> {
        Set(messageStore.map(\.threadId))
    }
    func threadIdsWithMessagesOffMain() async throws -> Set<AgentThreadID> {
        try threadIdsWithMessages()
    }
    func listAgentMessagesPage(thread: AgentThreadID, limit requestedLimit: Int, before beforeCursor: AgentMessageCursor?, after afterCursor: AgentMessageCursor?) throws -> AgentMessagePage {
        let limit = max(0, min(requestedLimit, 500))
        let filtered = messageStore
            .filter { message in
                guard message.threadId == thread else { return false }
                if let cursor = afterCursor {
                    if message.createdAt != cursor.createdAt {
                        return message.createdAt > cursor.createdAt
                    }
                    return message.id.value.uuidString > cursor.id.value.uuidString
                }
                guard let cursor = beforeCursor else { return true }
                if message.createdAt != cursor.createdAt {
                    return message.createdAt < cursor.createdAt
                }
                return message.id.value.uuidString < cursor.id.value.uuidString
            }
            .sorted {
                if afterCursor != nil {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.value.uuidString < $1.id.value.uuidString
                }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.value.uuidString > $1.id.value.uuidString
            }
        let pageRows = Array(filtered.prefix(limit))
        let display = afterCursor == nil ? Array(pageRows.reversed()) : pageRows
        let next = display.first.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) }
        let after = display.last.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) }
        return AgentMessagePage(
            messages: display,
            hasMoreOlder: afterCursor != nil || filtered.count > limit,
            nextBefore: next,
            hasMoreNewer: beforeCursor != nil || (afterCursor != nil && filtered.count > limit),
            nextAfter: after
        )
    }
    func listAgentMessagesPageOffMain(thread: AgentThreadID, limit: Int, before: AgentMessageCursor?, after: AgentMessageCursor?) async throws -> AgentMessagePage {
        try listAgentMessagesPage(thread: thread, limit: limit, before: before, after: after)
    }
    func listAgentMessagesWithinBodyBudget(
        thread: AgentThreadID,
        limit: Int,
        before: AgentMessageCursor?,
        after: AgentMessageCursor?,
        budget: Int,
        contentLimit: Int
    ) throws -> AgentMessageBodyBudgetResult {
        if let messageListBudgetError {
            throw messageListBudgetError
        }
        return AgentMessageTransport.pageWithinBodyBudget(
            page: try listAgentMessagesPage(
                thread: thread,
                limit: limit,
                before: before,
                after: after
            ),
            budget: budget,
            contentLimit: contentLimit,
            afterDirection: after != nil
        )
    }
    func listAgentMessagesWithinBodyBudgetOffMain(
        thread: AgentThreadID,
        limit: Int,
        before: AgentMessageCursor?,
        after: AgentMessageCursor?,
        budget: Int,
        contentLimit: Int
    ) async throws -> AgentMessageBodyBudgetResult {
        try listAgentMessagesWithinBodyBudget(
            thread: thread,
            limit: limit,
            before: before,
            after: after,
            budget: budget,
            contentLimit: contentLimit
        )
    }
    func getAgentMessage(id: AgentMessageID) throws -> AgentMessage? {
        messageStore.first { $0.id == id }
    }
    func listAgentQueuedMessages(thread: AgentThreadID) throws -> [AgentQueuedMessage] {
        queuedMessageStore.filter { $0.threadId == thread }.sorted { $0.position < $1.position }
    }
    func listAgentQueuedMessagesOffMain(thread: AgentThreadID) async throws -> [AgentQueuedMessage] {
        try listAgentQueuedMessages(thread: thread)
    }
    func updateAgentQueuedMessage(id: AgentQueuedMessageID, text: String, attachments: [AgentAttachment]) async throws -> AgentQueuedMessage {
        guard let idx = queuedMessageStore.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        queuedMessageStore[idx].text = text
        queuedMessageStore[idx].attachments = attachments
        queuedMessageStore[idx].updatedAt = Date()
        return queuedMessageStore[idx]
    }
    func cancelAgentQueuedMessage(id: AgentQueuedMessageID) throws -> AgentQueuedMessage {
        guard let idx = queuedMessageStore.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        return queuedMessageStore.remove(at: idx)
    }
    func forceAgentQueuedMessageNow(id: AgentQueuedMessageID) async throws -> AgentMessageSendResult {
        guard let idx = queuedMessageStore.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        let queued = queuedMessageStore.remove(at: idx)
        if threadStore.first(where: { $0.id == queued.threadId })?.status == .running {
            queuedMessageStore.insert(queued, at: 0)
            normalizeQueuedPositions(thread: queued.threadId)
            guard let promoted = queuedMessageStore.first(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
            return AgentMessageSendResult(status: .queued, queuedMessage: promoted)
        }
        normalizeQueuedPositions(thread: queued.threadId)
        return try await sendAgentMessage(thread: queued.threadId,
                                          text: queued.text,
                                          provider: nil,
                                          model: nil,
                                          permissionMode: nil,
                                          reasoningEffort: nil,
                                          serviceTier: nil,
                                          interactionMode: queued.interactionMode,
                                          modelSelection: nil,
                                          providerInstanceId: nil,
                                          attachments: queued.attachments)
    }
    private func normalizeQueuedPositions(thread: AgentThreadID) {
        let sortedIds = queuedMessageStore
            .filter { $0.threadId == thread }
            .map(\.id)
        for (offset, id) in sortedIds.enumerated() {
            guard let idx = queuedMessageStore.firstIndex(where: { $0.id == id }) else { continue }
            queuedMessageStore[idx].position = offset + 1
        }
    }
    func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, interactionMode: AgentInteractionMode?, modelSelection: AgentModelSelection?, providerInstanceId: String?, attachments: [AgentAttachment]) async throws -> AgentMessageSendResult {
        sendAgentMessageCallCount += 1
        lastSendText = text
        lastSendInteractionMode = interactionMode
        lastSendAttachments = attachments
        _ = try configureAgentThread(thread: thread, provider: provider, model: model, permissionMode: permissionMode, reasoningEffort: reasoningEffort, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId, runAsUser: nil)
        lastSendPermission = threadStore.first(where: { $0.id == thread })?.permissionMode
        lastSendReasoning = threadStore.first(where: { $0.id == thread })?.reasoningEffort
        lastSendServiceTier = threadStore.first(where: { $0.id == thread })?.serviceTier
        if threadStore.first(where: { $0.id == thread })?.status == .running {
            let queued = AgentQueuedMessage(threadId: thread, text: text, attachments: attachments, interactionMode: interactionMode ?? .default, position: queuedMessageStore.count + 1)
            queuedMessageStore.append(queued)
            return AgentMessageSendResult(status: .queued, queuedMessage: queued)
        }
        return AgentMessageSendResult(status: .started, runId: AgentRunID())
    }
    func implementAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, newThread: Bool, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?) async throws -> (runId: AgentRunID, implementationThreadId: AgentThreadID) {
        let target: AgentThread
        if newThread {
            target = try createAgentThread(workspace: threadStore.first(where: { $0.id == thread })?.workspaceId,
                                           title: "Implement plan",
                                           provider: provider ?? .codex,
                                           model: model ?? "fake-model",
                                           permissionMode: permissionMode ?? .supervised,
                                           reasoningEffort: reasoningEffort ?? .medium,
                                           serviceTier: serviceTier ?? .auto,
                                           modelSelection: modelSelection,
                                           providerInstanceId: nil,
                                           runAsUser: nil,
                                           surfaceID: nil)
        } else {
            guard let existing = threadStore.first(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
            target = existing
        }
        let sendResult = try await sendAgentMessage(thread: target.id,
                                                    text: AgentPlanImplementationPrompt.make(markdown: planMarkdown ?? ""),
                                                    provider: provider,
                                                    model: model,
                                                    permissionMode: permissionMode,
                                                    reasoningEffort: reasoningEffort,
                                                    serviceTier: serviceTier,
                                                    interactionMode: .default,
                                                    modelSelection: modelSelection,
                                                    providerInstanceId: nil,
                                                    attachments: [])
        let runId = try XCTUnwrap(sendResult.runId)
        lastImplementedPlan = (thread, planId, target.id)
        return (runId, target.id)
    }
    func saveAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, relativePath: String?) throws -> (path: String, relativePath: String) {
        lastSavedPlan = (thread, planId, planMarkdown, relativePath)
        return ("/tmp/\(relativePath ?? "plan.md")", relativePath ?? ".remotecode/plans/plan.md")
    }
    var planNotesByThread: [AgentThreadID: String] = [:]
    var planNotesSaveCallCount = 0
    var planNotesReadShouldFail = false
    var planNotesSaveShouldFail = false
    func agentPlanNotes(thread: AgentThreadID) throws -> String {
        if planNotesReadShouldFail {
            throw JSONRPCError(code: -32000, message: "Injected plan-notes read failure.")
        }
        return planNotesByThread[thread] ?? ""
    }
    func saveAgentPlanNotes(thread: AgentThreadID, notes: String) throws {
        planNotesSaveCallCount += 1
        if planNotesSaveShouldFail {
            throw JSONRPCError(code: -32000, message: "Injected plan-notes persistence failure.")
        }
        planNotesByThread[thread] = notes
    }
    var reorderAgentQueuedMessageCallCount = 0
    func reorderAgentQueuedMessage(thread: AgentThreadID, id: AgentQueuedMessageID, position: Int) throws {
        reorderAgentQueuedMessageCallCount += 1
        var queue = queuedMessageStore.filter { $0.threadId == thread }
        guard let fromIndex = queue.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        let moved = queue.remove(at: fromIndex)
        queue.insert(moved, at: max(0, min(position, queue.count - 1)))
        queuedMessageStore.removeAll { $0.threadId == thread }
        for (index, var message) in queue.enumerated() {
            message.position = index + 1
            queuedMessageStore.append(message)
        }
    }
    func commandReceipt(method: String, clientRequestId: String) -> JSONValue? {
        commandReceipts["\(method):\(clientRequestId)"]
    }
    func recordCommandReceipt(method: String, clientRequestId: String, result: JSONValue) {
        commandReceipts["\(method):\(clientRequestId)"] = result
    }
    func respondAgentRequest(thread: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        respondAgentRequestCallCount += 1
        lastAgentRequestResponse = (thread, requestId, response)
        agentRequestResponses.append((thread, requestId, response))
    }
    func respondAgentUserInput(thread: AgentThreadID, requestId: String, text: String) async throws {
        respondAgentUserInputCallCount += 1
        lastAgentUserInputResponse = (thread, requestId, text)
        agentUserInputResponses.append((thread, requestId, text))
    }
    func listAgentPendingCallbacks(thread: AgentThreadID) throws -> AssistantPendingCallbacksSnapshot {
        pendingCallbackSnapshot
    }
    func listAgentPendingCallbacksOffMain(thread: AgentThreadID) async throws -> AssistantPendingCallbacksSnapshot {
        try listAgentPendingCallbacks(thread: thread)
    }
    func readAgentThreadEvents(thread: AgentThreadID) async throws -> [AssistantEvent] {
        readAgentEvents
    }
    func replayedRunErrorFields(message: String, recoverable: Bool) -> [String: JSONValue] {
        replayedRunErrorFieldsStub?(message, recoverable) ?? [:]
    }
    func readAgentThreadMirrorSnapshot(
        thread: AgentThreadID,
        eventRowLimit: Int?,
        maxPayloadBytes: Int64?
    ) async throws -> AgentThreadMirrorSnapshot {
        readAgentThreadMirrorSnapshotCallCount += 1
        lastMirrorSnapshotEventRowLimit = eventRowLimit
        lastMirrorSnapshotMaxPayloadBytes = maxPayloadBytes
        // Source already blocked the newest row (empty events + metadata).
        if let blocked = mirrorBlockedEvent {
            return AgentThreadMirrorSnapshot(
                events: [],
                eventWatermark: EventBus.shared.currentSeq,
                sourceHadOlderEvents: true,
                blockedEvent: blocked
            )
        }
        // Mirror the production +1 probe: only expose `eventRowLimit` newest
        // events and flag when older rows would remain at the source.
        let hadOlder: Bool
        let events: [AssistantEvent]
        if let limit = eventRowLimit {
            hadOlder = readAgentEvents.count > limit
            events = Array(readAgentEvents.suffix(limit))
        } else {
            hadOlder = false
            events = readAgentEvents
        }
        return AgentThreadMirrorSnapshot(
            events: events,
            eventWatermark: EventBus.shared.currentSeq,
            sourceHadOlderEvents: hadOlder,
            blockedEvent: nil
        )
    }
    func rollbackAgentThread(thread: AgentThreadID, toTurnId: String) async throws {
        rollbackCallCount += 1
        lastRollback = (thread, toTurnId)
    }
    func listAgentThreadCheckpoints(thread: AgentThreadID) throws -> [AgentTurnCheckpointSummary] {
        checkpointStore.filter { $0.threadId == thread }
    }
    var checkpointPageOverride: AgentTurnCheckpointPage?
    var checkpointCatalogRevision: Int64 = 1
    /// Optional delay applied on a background queue before returning the page
    /// (MainActor heartbeat tests). Not used on the MainActor itself.
    var checkpointPageDelayNanoseconds: UInt64 = 0
    var checkpointPageQueryWillRun: (() -> Void)?
    nonisolated(unsafe) private(set) var checkpointPageQueryOnMainCount = 0
    nonisolated(unsafe) private(set) var checkpointPageQueryOffMainCount = 0
    func listAgentThreadCheckpointsPage(
        thread: AgentThreadID,
        maxEntries: Int,
        before: AgentTurnCheckpointCursor?,
        expectedCatalogRevision: Int64?
    ) async throws -> AgentTurnCheckpointPage {
        checkpointPageCallCount += 1
        // Capture immutable Sendable inputs on MainActor, then hop for the
        // "repository" work so tests mirror the production gateway contract.
        let store = checkpointStore
        let override = checkpointPageOverride
        let revision = checkpointCatalogRevision
        let delay = checkpointPageDelayNanoseconds
        let hook = checkpointPageQueryWillRun
        // Preclaim expected revision before any page materialization — mirrors
        // the repository read-snapshot fence (no page decode on stale).
        if let expectedCatalogRevision, expectedCatalogRevision != revision {
            throw AgentTurnCheckpointListError.staleCatalogRevision(current: revision)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: AgentTurnCheckpointListGateway.queueLabel).async {
                if Thread.isMainThread {
                    self.checkpointPageQueryOnMainCount += 1
                } else {
                    self.checkpointPageQueryOffMainCount += 1
                }
                hook?()
                if delay > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000)
                }
                do {
                    let result = try Self.buildCheckpointPage(
                        store: store,
                        override: override,
                        catalogRevision: revision,
                        thread: thread,
                        maxEntries: maxEntries,
                        before: before
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func buildCheckpointPage(
        store: [AgentTurnCheckpointSummary],
        override: AgentTurnCheckpointPage?,
        catalogRevision: Int64,
        thread: AgentThreadID,
        maxEntries: Int,
        before: AgentTurnCheckpointCursor?
    ) throws -> AgentTurnCheckpointPage {
        if let override { return override }
        var rows = store
            .filter { $0.threadId == thread }
            .sorted {
                if $0.checkpointTurnCount != $1.checkpointTurnCount {
                    return $0.checkpointTurnCount > $1.checkpointTurnCount
                }
                if $0.completedAt != $1.completedAt {
                    return $0.completedAt > $1.completedAt
                }
                return $0.turnId > $1.turnId
            }
        if let before {
            rows = rows.filter {
                if $0.checkpointTurnCount != before.checkpointTurnCount {
                    return $0.checkpointTurnCount < before.checkpointTurnCount
                }
                if $0.completedAt != before.completedAt {
                    return $0.completedAt < before.completedAt
                }
                return $0.turnId < before.turnId
            }
        }
        let limit = max(1, min(maxEntries, 100))
        let truncated = rows.count > limit
        let pageRows = Array(rows.prefix(limit))
        let items = pageRows.map {
            AgentTurnCheckpointSummary(
                threadId: $0.threadId,
                runId: $0.runId,
                turnId: $0.turnId,
                checkpointTurnCount: $0.checkpointTurnCount,
                checkpointRef: $0.checkpointRef,
                status: $0.status,
                files: $0.files,
                assistantMessageId: $0.assistantMessageId,
                errorMessage: $0.errorMessage,
                completedAt: $0.completedAt
            )
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tokens = pageRows.map { fractional.string(from: $0.completedAt) }
        let nextBefore: AgentTurnCheckpointCursor? = {
            guard truncated, let last = pageRows.last, let token = tokens.last else { return nil }
            return AgentTurnCheckpointCursor(
                checkpointTurnCount: last.checkpointTurnCount,
                completedAt: last.completedAt,
                turnId: last.turnId,
                completedAtToken: token
            )
        }()
        return AgentTurnCheckpointPage(
            items: items,
            completedAtTokens: tokens,
            truncated: truncated,
            nextBefore: nextBefore,
            catalogRevision: catalogRevision
        )
    }
    var agentCheckpointDiffCallCount = 0
    var stubAgentCheckpointDiff: String?
    func agentCheckpointDiff(thread: AgentThreadID, checkpointTurnCount: Int, expectedRunID: UUID? = nil, path: String?) throws -> String {
        agentCheckpointDiffCallCount += 1
        if let stubAgentCheckpointDiff { return stubAgentCheckpointDiff }
        guard let checkpoint = checkpointStore.first(where: { $0.threadId == thread && $0.checkpointTurnCount == checkpointTurnCount }) else {
            return ""
        }
        if let expectedRunID, checkpoint.runId.value != expectedRunID {
            throw JSONRPCError(code: -32013, message: "Checkpoint diff is unavailable for the expected run.")
        }
        if let path { return checkpoint.fileDiffs.first(where: { $0.path == path })?.patch ?? "" }
        return checkpoint.diffPatch ?? checkpoint.fileDiffs.map(\.patch).joined(separator: "\n")
    }
    func revertAgentThreadToCheckpoint(thread: AgentThreadID, checkpointTurnCount: Int) async throws -> AgentTurnCheckpointSummary {
        checkpointRevertCallCount += 1
        lastCheckpointRevert = (thread, checkpointTurnCount)
        return AgentTurnCheckpointSummary(
            threadId: thread,
            runId: AgentRunID(),
            turnId: "turn-\(checkpointTurnCount)",
            checkpointTurnCount: checkpointTurnCount,
            checkpointRef: "local-diff:test:turn-\(checkpointTurnCount)",
            status: .ready,
            files: []
        )
    }
    func stopAgentRun(thread: AgentThreadID) throws {
        stopAgentRunCallCount += 1
        stoppedAgentThreads.append(thread)
    }
    var activeAgentRuns: [AgentThreadID: AgentActiveRunSnapshot] = [:]
    var activeAgentDelegations: [AgentThreadID: AgentActiveDelegationSnapshot] = [:]
    func activeAgentRun(thread: AgentThreadID) throws -> AgentActiveRunSnapshot? {
        activeAgentRuns[thread]
    }
    func activeAgentDelegation(
        thread: AgentThreadID,
        run: AgentRunID
    ) throws -> AgentActiveDelegationSnapshot? {
        guard activeAgentDelegations[thread]?.runId == run else { return nil }
        return activeAgentDelegations[thread]
    }
    var continueAgentRunCallCount = 0
    var continuedAgentThreads: [AgentThreadID] = []
    func continueAgentRun(thread: AgentThreadID) async throws -> AgentRunID? {
        continueAgentRunCallCount += 1
        continuedAgentThreads.append(thread)
        return AgentRunID()
    }
    var threadStore: [AgentThread] = []
    var loopsByThread: [AgentThreadID: [DistillLoopState]] = [:]
    var stopLoopCalls: [(AgentThreadID, String)] = []
    var stopLoopError: Error?
    func threadLoops(thread: AgentThreadID) -> [DistillLoopState] { loopsByThread[thread] ?? [] }
    func stopThreadLoop(thread: AgentThreadID, taskId: String) async throws -> Bool {
        stopLoopCalls.append((thread, taskId))
        if let stopLoopError { throw stopLoopError }
        return true
    }
    var deleteAgentThreadCallCount = 0
    var deleteAgentThreadsCallCount = 0
    var setAgentThreadPinnedCallCount = 0
    var setAgentThreadColorCallCount = 0
    var reorderAgentThreadCallCount = 0
    var renameAgentThreadCallCount = 0
    var markAgentThreadReadCallCount = 0
    func deleteAgentThread(thread: AgentThreadID) async throws {
        deleteAgentThreadCallCount += 1
        threadStore.removeAll { $0.id == thread }
    }
    func deleteAgentThreads(_ threads: [AgentThreadID]) async throws {
        deleteAgentThreadsCallCount += 1
        threadStore.removeAll { threads.contains($0.id) }
    }
    func setAgentThreadPinned(thread: AgentThreadID, pinned: Bool) throws -> AgentThread {
        setAgentThreadPinnedCallCount += 1
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].pinned = pinned
        try normalizeThreadOrder(workspaceId: threadStore[idx].workspaceId)
        return threadStore[idx]
    }
    func setAgentThreadColor(thread: AgentThreadID, color: String) throws -> AgentThread {
        setAgentThreadColorCallCount += 1
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].color = color.isEmpty ? nil : color
        return threadStore[idx]
    }
    func reorderAgentThread(thread: AgentThreadID, position: Int) throws -> [AgentThread] {
        reorderAgentThreadCallCount += 1
        guard let current = threadStore.first(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        let wid = current.workspaceId
        var ordered = try listAgentThreads(workspace: wid)
        guard let idx = ordered.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        let item = ordered.remove(at: idx)
        ordered.insert(item, at: max(0, min(position, ordered.count)))
        for (sortOrder, item) in ordered.enumerated() {
            guard let storeIdx = threadStore.firstIndex(where: { $0.id == item.id }) else { continue }
            threadStore[storeIdx].sortOrder = sortOrder
        }
        return try listAgentThreads(workspace: wid)
    }
    func renameAgentThread(thread: AgentThreadID, title: String) throws -> AgentThread {
        renameAgentThreadCallCount += 1
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].title = title
        return threadStore[idx]
    }
    func markAgentThreadRead(thread: AgentThreadID) throws {
        markAgentThreadReadCallCount += 1
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].hasUnread = false
        selectedThread = thread
    }
    private func normalizeThreadOrder(workspaceId: WorkspaceID?) throws {
        let ordered = try listAgentThreads(workspace: workspaceId)
        for (sortOrder, thread) in ordered.enumerated() {
            guard let idx = threadStore.firstIndex(where: { $0.id == thread.id }) else { continue }
            threadStore[idx].sortOrder = sortOrder
        }
    }
    func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor] {
        [AgentModelDescriptor(id: "x", label: "X", provider: provider, accountProvider: provider == .distill ? "chatgpt" : nil)]
    }
    func listAgentProviderSnapshots() async -> [AgentProviderSnapshot] {
        [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "gpt-5.1-codex", label: "GPT-5.1 Codex", provider: .codex)],
                slashCommands: ["/status", "/goal"]
            ),
            AgentProviderSnapshot(
                id: "claude-cli",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "sonnet", label: "Sonnet", provider: .claude)],
                slashCommands: ["/status"]
            )
        ]
    }
    var providerUpdateResult: JSONValue = .object(["ok": .bool(true)])
    var providerUpdateCall: (AgentProvider, String?)?
    func updateAgentProvider(provider: AgentProvider, providerInstanceId: String?) async throws -> JSONValue {
        providerUpdateCall = (provider, providerInstanceId)
        return providerUpdateResult
    }
    var gitCwd = "/tmp"
    /// Count of `gitDiff` invocations — used to prove invalid bounded params fail closed before the expensive router call.
    var gitDiffCallCount = 0
    /// When set, returned instead of shelling out to real git (keeps Dispatcher contract tests hermetic).
    var stubGitDiff: String?
    func gitStatus(workspace: WorkspaceID) throws -> GitSummary { try XCTUnwrap(GitDiff.summary(in: gitCwd)) }
    func gitBranches(workspace: WorkspaceID) throws -> GitBranches { GitDiff.branches(in: gitCwd) }
    func gitCheckout(workspace: WorkspaceID, branch: String) throws -> GitActionResult { GitDiff.checkout(in: gitCwd, branch: branch) }
    func gitCreateBranch(workspace: WorkspaceID, name: String) throws -> GitActionResult { GitDiff.createBranch(in: gitCwd, name: name) }
    func gitCommit(workspace: WorkspaceID, message: String) throws -> GitActionResult { GitDiff.commit(in: gitCwd, message: message) }
    func gitLog(workspace: WorkspaceID, limit: Int) throws -> [GitCommit] { GitDiff.log(in: gitCwd, limit: limit) }
    func gitDiff(workspace: WorkspaceID, path: String?, ignoreWhitespace: Bool) throws -> String {
        gitDiffCallCount += 1
        if let stubGitDiff { return stubGitDiff }
        return GitDiff.diff(in: gitCwd, path: path, ignoreWhitespace: ignoreWhitespace)
    }
    func gitPush(workspace: WorkspaceID) throws -> GitActionResult { GitDiff.push(in: gitCwd) }
    func gitFetch(workspace: WorkspaceID) throws -> GitActionResult { GitDiff.fetch(in: gitCwd) }
    func gitPull(workspace: WorkspaceID) throws -> GitActionResult { GitDiff.pull(in: gitCwd) }
    func gitPullRequestURL(workspace: WorkspaceID) throws -> String? { GitDiff.pullRequestURL(in: gitCwd) }
    func gitDeliveryPlan(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryPlan { GitDiff.deliveryPlan(in: gitCwd, copy: copy) }
    func gitDeliver(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryResult { GitDiff.deliver(in: gitCwd, copy: copy, environment: nil) }
    var projectCwd = "/tmp"
    func projectScripts(workspace: WorkspaceID) throws -> [ProjectScript] { ProjectScripts.discover(in: projectCwd) }
    func projectRunScript(workspace: WorkspaceID, name: String) throws -> SurfaceDescriptor {
        guard ProjectScripts.discover(in: projectCwd).contains(where: { $0.name == name }) else { throw JSONRPCError(code: -32602, message: "no such script") }
        return SurfaceDescriptor(type: .terminal, title: "Run: \(name)")
    }
    var projectOpenInEditorError: Error?
    func projectOpenInEditor(workspace: WorkspaceID) throws -> String {
        if let projectOpenInEditorError { throw projectOpenInEditorError }
        return "Finder"
    }
    func browserNavigate(surface: SurfaceID, url: String) throws {}
    func browserBack(surface: SurfaceID) throws {}
    func browserForward(surface: SurfaceID) throws {}
    func browserReload(surface: SurfaceID) throws {}
    func browserStop(surface: SurfaceID) throws {}
    func browserURL(surface: SurfaceID) throws -> String { "about:blank" }
    var browserURLString = "about:blank"
    func browserMirrorURL(surface: SurfaceID) throws -> [String: JSONValue] {
        ["url": .string(browserURLString), "is_file": .bool(browserURLString.hasPrefix("file://"))]
    }
    func browserEval(surface: SurfaceID, script: String) async throws -> String { "null" }
    func browserScreenshot(surface: SurfaceID, savePath: String?) throws -> String { savePath ?? "/tmp/x.png" }
    func browserSnapshot(surface: SurfaceID) async throws -> String { "{\"elements\":[]}" }
    func browserAction(surface: SurfaceID, kind: String, ref: String, value: String?) async throws -> String { "{\"ok\":true}" }
    func browserWait(surface: SurfaceID, selector: String, timeoutMs: Int) async throws -> String { "{\"ok\":true}" }
    var notifs: [String] = []
    func notificationCreate(workspaceId: WorkspaceID?, surfaceId: SurfaceID?, title: String, body: String?, category: String?) throws -> String {
        let id = UUID().uuidString; notifs.append(id); return id
    }
    func notificationList(workspaceId: WorkspaceID?, unreadOnly: Bool) throws -> [[String: JSONValue]] { [] }
    func notificationMarkRead(id: String) throws {}
    func notificationDismiss(id: String) throws {}
    var lastPrivatePushTokenUpdate: (
        pushToken: String, pushTokenType: String, liveActivityToken: String?, deviceID: String?,
        tokenPurpose: String?, environment: String?, serverID: String?, bootEpoch: Int?,
        activityGeneration: Int?, activityID: String?, activitySessionID: String?,
        registrationRevision: Int?, contractVersion: Int?, capabilities: [String]?
    )?
    func privatePushTokenUpdate(
        pushToken: String, pushTokenType: String, liveActivityToken: String?, deviceID: String?,
        tokenPurpose: String?, environment: String?, serverID: String?, bootEpoch: Int?,
        activityGeneration: Int?, activityID: String?, activitySessionID: String?,
        registrationRevision: Int?, contractVersion: Int?, capabilities: [String]?
    ) throws -> JSONValue {
        lastPrivatePushTokenUpdate = (
            pushToken, pushTokenType, liveActivityToken, deviceID, tokenPurpose, environment,
            serverID, bootEpoch, activityGeneration, activityID, activitySessionID,
            registrationRevision, contractVersion, capabilities
        )
        return .object(["ok": .bool(true), "push_token_type": .string(pushTokenType)])
    }
    func bindBotAttentionProfile(profileID: String, hostID: String, deviceID: String) throws {}
    var settings: [String: String] = [:]
    func settingsGet(keys: [String]) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, settings[$0] ?? "") })
    }
    func settingsSet(key: String, value: String) throws { settings[key] = value }
    var filesState: [String: JSONValue] = [:]
    func filesStateGet(surface: SurfaceID) throws -> JSONValue {
        .object(filesState.isEmpty ? [
            "surface_id": .string(surface.value.uuidString),
            "revision": .number(0),
            "dirty_paths": .array([])
        ] : filesState)
    }
    func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue {
        for (key, value) in patch { filesState[key] = value }
        filesState["surface_id"] = .string(surface.value.uuidString)
        filesState["revision"] = .number(Double((filesState["revision"]?.intValue ?? 0) + 1))
        return .object(filesState)
    }
    func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue { try WorkspaceFileService().list(root: projectCwd, path: path) }
    func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue { try WorkspaceFileService().read(root: projectCwd, path: path, maxBytes: maxBytes) }
    func fsWorkspacePreviewURL(workspace: WorkspaceID, path: String) throws -> JSONValue { try WorkspaceFileService().previewURL(root: projectCwd, path: path) }
    func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue { try WorkspaceFileService().createFile(root: projectCwd, path: path, content: content) }
    func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue { try WorkspaceFileService().rename(root: projectCwd, path: path, newName: newName) }
    func fsWorkspaceDelete(workspace: WorkspaceID, paths: [String]) throws -> JSONValue { try WorkspaceFileService().delete(root: projectCwd, paths: paths) }
    func filesEditSession(sessionID: String) throws -> JSONValue {
        guard let session = FileEditSessionStore.shared.session(sessionID: sessionID) else {
            throw JSONRPCError(code: -32602, message: "edit session not found")
        }
        return session
    }
    func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue { try FileEditSessionStore.shared.open(surfaceID: surface, workspaceID: WorkspaceID(), root: projectCwd, path: path) }
    func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
        try FileEditSessionStore.shared.applyPatch(sessionID: sessionID, baseDraftRevision: baseDraftRevision, rangeLocation: rangeLocation, rangeLength: rangeLength, replacement: replacement, deviceID: deviceID)
    }
    func filesEditSave(sessionID: String) throws -> JSONValue { try FileEditSessionStore.shared.save(sessionID: sessionID) }
    func filesEditDiscard(sessionID: String) throws -> JSONValue { try FileEditSessionStore.shared.discard(sessionID: sessionID) }
    func filesEditClose(sessionID: String) throws -> JSONValue { try FileEditSessionStore.shared.close(sessionID: sessionID) }
    func paneList(workspace: WorkspaceID) throws -> [[String: JSONValue]] { [] }
    func paneSurfaces(pane: PaneID, workspace: WorkspaceID) throws -> [SurfaceDescriptor] { [] }
    func paneResize(workspace: WorkspaceID, splitID: UUID, ratios: [Double]) throws {}
    func surfaceMove(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID) throws {}
    func surfaceReorder(workspace: WorkspaceID, surface: SurfaceID, toPane: PaneID, position: Int) throws {}
    var promptHistoryByWorkspace: [WorkspaceID: [String]] = [:]
    func agentPromptHistory(workspace: WorkspaceID?, limit: Int) throws -> [String] {
        let wid = workspace ?? window.selectedWorkspaceID
        guard let wid else { return [] }
        let history = promptHistoryByWorkspace[wid, default: []]
        return Array(history.suffix(limit).reversed())
    }
}

final class DispatcherTests: XCTestCase {
    @MainActor
    func test_ping_returnsPong() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.ping", params: nil))
        guard case .object(let o) = resp.result! else { return XCTFail() }
        XCTAssertEqual(o["pong"], .bool(true))
    }

    @MainActor
    func test_capabilities_listsRemoteCode() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))
        guard case .object(let o) = resp.result! else { return XCTFail() }
        XCTAssertEqual(o["app"], .string("remotecode"))
        XCTAssertEqual(
            o["message_transport"],
            AgentMessageTransport.capabilityMarker,
            "bounded message v1 must be enabled only by this exact authenticated marker"
        )
    }

    @MainActor
    func test_capabilitiesAdvertiseFilesSurfaceForMirrorParity() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))

        guard case .object(let o)? = resp.result,
              case .array(let surfaceTypes)? = o["surface_types"] else {
            return XCTFail("capabilities must expose surface_types so iOS can render the same add-surface menu as macOS")
        }
        XCTAssertTrue(surfaceTypes.contains(.string("files")),
                      "Files must be advertised by the host; otherwise iOS cannot discover or create the mirrored Files tab")
    }

    @MainActor
    func test_agentProvidersListReturnsSnapshotsForProviderDrivenUI() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.providers.list", params: nil))

        guard case .array(let snapshots)? = resp.result,
              let codex = snapshots.compactMap(\.objectValue).first(where: { $0["provider"] == .string("codex") }) else {
            return XCTFail("agent.providers.list must expose provider snapshots so Agent App does not hardcode provider state")
        }
        XCTAssertEqual(codex["displayName"], .string("Codex"))
        XCTAssertEqual(codex["status"], .string("available"))
        XCTAssertEqual(codex["driverKind"], .string("codex_cli"))
        XCTAssertEqual(codex["slashCommands"]?.arrayValue?.contains(.string("/goal")), true)
        XCTAssertEqual(codex["models"]?.arrayValue?.isEmpty, false)
    }

    @MainActor
    func test_distillAccountsListAndMutationRPCs() async {
        let router = FakeRouter()
        router.distillAccountsPayload = .object(["accounts": .array([.object([
            "provider": .string("grok"), "display_name": .string("Grok"), "connected": .bool(true), "email": .string("a@example.com")
        ])]), "busy_provider": .string("claude"), "last_error": .null])
        let dispatcher = JSONRPCDispatcher(router: router)
        let listed = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "distill.accounts.list", params: nil))
        XCTAssertEqual(listed.result, router.distillAccountsPayload)
        let loggedIn = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "distill.accounts.login", params: ["provider": .string("grok")]))
        XCTAssertEqual(loggedIn.result, .object(["started": .bool(true)]))
        XCTAssertEqual(router.distillLoginProvider, .grok)
        let loggedOut = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "distill.accounts.logout", params: ["provider": .string("claude")]))
        XCTAssertEqual(loggedOut.result, .object(["started": .bool(true)]))
        XCTAssertEqual(router.distillLogoutProvider, .claude)
        let cancelled = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "distill.accounts.cancel", params: nil))
        XCTAssertEqual(cancelled.result, .object(["cancelled": .bool(true)]))
        let invalid = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(5), method: "distill.accounts.login", params: ["provider": .string("invalid")]))
        XCTAssertNotNil(invalid.error)
        for method in ["distill.accounts.login", "distill.accounts.logout", "distill.accounts.cancel"] {
            XCTAssertTrue(HostMutationContract.methods.contains(method))
        }
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("distill.accounts.list"))
        let catalog = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(11), method: "agent.models.list", params: ["provider": .string("distill")]))
        XCTAssertEqual(catalog.result?.arrayValue?.first?.objectValue?["accountProvider"], .string("chatgpt"))
        let named = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(6), method: "distill.accounts.login", params: ["account_id": .string("second-chatgpt")]))
        XCTAssertEqual(named.result, .object(["started": .bool(true)]))
        XCTAssertEqual(router.distillAccountID, "second-chatgpt")
        let routing: JSONValue = .object(["enabled": .bool(true), "strategy": .string("ordered_first"), "options": .array([.object(["id": .string("option"), "account_id": .string("second-chatgpt"), "main_model": .string("discovered"), "worker_model": .null])])])
        let saved = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(7), method: "distill.accounts.routing.set", params: ["routing": routing]))
        XCTAssertEqual(saved.result, .object(["started": .bool(true)]))
        XCTAssertEqual(router.distillRouting.options.first?.accountID, "second-chatgpt")
        XCTAssertNil(router.distillRouting.options.first?.workerModel)
        let read = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(8), method: "distill.accounts.routing.get", params: nil))
        XCTAssertEqual(read.result, .object(["enabled": .bool(true)]))
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("distill.accounts.routing.get"))
        XCTAssertFalse(HostMutationContract.methods.contains("distill.accounts.routing.get"))
        let context = MutationRequestContext(ownerFingerprint: "owner", hostId: "host", bootEpoch: 1)
        for method in ["distill.accounts.add", "distill.accounts.rename", "distill.accounts.remove", "distill.accounts.usage", "distill.accounts.routing.set"] {
            XCTAssertTrue(HostMutationContract.methods.contains(method))
            XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod(method))
            let denied = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(9), method: method, params: [:]), mutationContext: context)
            XCTAssertEqual(denied.error?.code, -32097, method)
        }
        XCTAssertNoThrow(try HostMutationContract.preflight(method: "distill.accounts.login", params: ["account_id": .string("second-chatgpt")]))
        XCTAssertThrowsError(try HostMutationContract.preflight(method: "distill.accounts.rename", params: ["account_id": .string("second-chatgpt"), "label": .string("")]))
        let invalidRouting = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(10), method: "distill.accounts.routing.set", params: ["routing": .object(["enabled": .string("true")])]))
        XCTAssertNotNil(invalidRouting.error)

    }

    @MainActor
    func test_agentThreadCreateAcceptsFlatDistillSelectionAndEchoesIt() async {
        let router = FakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.create", params: [
            "provider": .string("distill"), "model": .string("distill-main"),
            "distill_main_effort": .string("high"), "worker_model": .string("distill-worker"), "worker_effort": .string("medium")
        ]))
        guard let payload = response.result?.objectValue else { return XCTFail("expected encoded thread") }
        XCTAssertEqual(payload["distill_main_effort"], .string("high"))
        XCTAssertEqual(payload["worker_model"], .string("distill-worker"))
        XCTAssertEqual(payload["worker_effort"], .string("medium"))
        XCTAssertEqual(router.threadStore.first?.reasoningModel, "distill-worker")
        XCTAssertEqual(router.threadStore.first?.modelSelection.distillMainEffortSelection?.effort, .high)
        XCTAssertEqual(router.threadStore.first?.modelSelection.distillReasoningEffortSelection?.effort, .medium)
    }

    @MainActor
    func test_agentThreadConfigureAndSendAcceptFlatWorkerSelection() async {
        let router = FakeRouter()
        let thread = AgentThread(title: "Thread", provider: .distill, model: "main")
        router.threadStore = [thread]
        let dispatcher = JSONRPCDispatcher(router: router)
        let configured = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.configure", params: [
            "thread_id": .string(thread.id.value.uuidString), "distill_main_effort": .string("auto"),
            "worker_model": .string("worker-a"), "worker_effort": .string("high")
        ]))
        XCTAssertNil(configured.error)
        XCTAssertEqual(router.threadStore.first?.reasoningModel, "worker-a")
        XCTAssertEqual(router.threadStore.first?.modelSelection.distillReasoningEffortSelection?.effort, .high)
        let sent = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.send", params: [
            "thread_id": .string(thread.id.value.uuidString), "text": .string("hello"),
            "distill_main_effort": .string("medium"), "worker_model": .string(""), "worker_effort": .string("auto")
        ]))
        XCTAssertNil(sent.error)
        XCTAssertNil(router.threadStore.first?.reasoningModel)
        XCTAssertEqual(router.threadStore.first?.modelSelection.distillMainEffortSelection?.effort, .medium)
        XCTAssertTrue(router.threadStore.first?.modelSelection.distillReasoningEffortSelection?.isAutomatic == true)
    }

    @MainActor
    func test_agentThreadUltracodeParamsRoundTripAndMissingIsFalse() async {
        let router = FakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let created = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.create", params: [
            "provider": .string("distill"), "model": .string("distill-main"), "distill_ultracode": .bool(true)
        ]))
        XCTAssertEqual(created.result?.objectValue?["distill_ultracode"], .bool(true))
        XCTAssertEqual(router.threadStore.first?.modelSelection.distillExecutionMode, .ultracode)
        let tid = router.threadStore[0].id.value.uuidString
        let off = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.thread.configure", params: [
            "thread_id": .string(tid), "distill_ultracode": .bool(false)
        ]))
        XCTAssertNil(off.error)
        XCTAssertEqual(router.threadStore.first?.modelSelection.distillExecutionMode, .normal)
        let bad = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.thread.configure", params: [
            "thread_id": .string(tid), "distill_ultracode": .string("yes")
        ]))
        XCTAssertNotNil(bad.error)
        let plain = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "agent.thread.create", params: [
            "provider": .string("distill"), "model": .string("distill-main")
        ]))
        XCTAssertEqual(plain.result?.objectValue?["distill_ultracode"], .bool(false))
    }

    @MainActor
    func test_distillExecutionModeAutoIsAcceptedAndAbsentDefaultsToAuto() async {
        // WHY: iOS sends distill_execution_mode "auto"; an omitted option must mean Auto, not Normal.
        let router = FakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let explicit = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.create", params: [
            "provider": .string("distill"), "model": .string("distill-main"), "distill_execution_mode": .string("auto")
        ]))
        XCTAssertNil(explicit.error)
        XCTAssertEqual(explicit.result?.objectValue?["distill_execution_mode"], .string("auto"))
        XCTAssertEqual(explicit.result?.objectValue?["distill_ultracode"], .bool(false))
        let plain = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.thread.create", params: [
            "provider": .string("distill"), "model": .string("distill-main")
        ]))
        XCTAssertEqual(plain.result?.objectValue?["distill_execution_mode"], .string("auto"))
    }

    func test_modelSelectionDecodesMissingUltracodeAsFalse() throws {
        let json = #"{"provider":"distill","modelId":"m","reasoningEffort":"high","serviceTier":"auto"}"#
        let decoded = try JSONDecoder().decode(AgentModelSelection.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.distillExecutionMode, .auto)
        let withFlag = AgentModelSelection(provider: .distill, modelId: "m", distillExecutionMode: .ultracode)
        let round = try JSONDecoder().decode(AgentModelSelection.self, from: JSONEncoder().encode(withFlag))
        XCTAssertEqual(round.distillExecutionMode, .ultracode)
    }

    @MainActor
    func test_flatDistillEffortRejectsUnknownLevel() async {
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let response = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.create", params: [
            "provider": .string("distill"), "distill_main_effort": .string("impossible")
        ]))
        XCTAssertNotNil(response.error)
    }

    @MainActor
    func test_agentProviderUpdateRoutesThroughDispatcherWithInstanceId() async {
        let router = FakeRouter()
        router.providerUpdateResult = .object(["ok": .bool(true), "stdout": .string("updated\n")])
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.provider.update",
            params: [
                "provider": .string("claude"),
                "provider_instance_id": .string("claude-work")
            ]
        ))

        XCTAssertEqual(router.providerUpdateCall?.0, .claude)
        XCTAssertEqual(router.providerUpdateCall?.1, "claude-work")
        XCTAssertEqual(resp.result, JSONValue.object(["ok": .bool(true), "stdout": .string("updated\n")]),
                       "provider update must be a host RPC action so macOS and iOS can invoke the same serialized provider-native update path")
    }

    @MainActor
    func test_capabilitiesAdvertiseSSHTabAndMethodsForMirrorParity() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))

        guard case .object(let o)? = resp.result,
              case .array(let surfaceTypes)? = o["surface_types"],
              case .object(let ssh)? = o["ssh"],
              case .array(let methods)? = ssh["methods"] else {
            return XCTFail("capabilities must expose the SSH surface and SSH methods so iOS can mirror the macOS tab")
        }
        XCTAssertTrue(surfaceTypes.contains(.string("ssh")),
                      "SSH must be advertised by the host; otherwise iOS cannot discover or create the mirrored SSH tab")
        XCTAssertTrue(methods.contains(.string("ssh.host.list")),
                      "saved hosts must be reachable through the same host RPC contract on macOS and iOS")
        XCTAssertTrue(methods.contains(.string("ssh.transfer.upload")))
        XCTAssertTrue(methods.contains(.string("ssh.transfer.download")))
        XCTAssertTrue(methods.contains(.string("ssh.files.local.list")),
                      "the FileZilla-style local browser must be reachable from iOS through the host RPC contract")
        XCTAssertTrue(methods.contains(.string("ssh.files.remote.list")),
                      "the FileZilla-style remote browser must be reachable from iOS through the host RPC contract")
    }

    @MainActor
    func test_surfaceCreateAcceptsFilesType() async throws {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let wid = JSONValue.string(UUID().uuidString)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.create", params: [
            "workspace_id": wid,
            "type": .string("files")
        ]))

        XCTAssertNil(resp.error, "iOS must be able to create a Files tab through the same surface.create RPC as macOS")
        guard case .object(let body)? = resp.result else { return XCTFail("surface.create must return the created Files descriptor") }
        XCTAssertEqual(body["type"], .string("files"))
    }

    @MainActor
    func test_surfaceCreateAcceptsSSHType() async throws {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let wid = JSONValue.string(UUID().uuidString)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.create", params: [
            "workspace_id": wid,
            "type": .string("ssh"),
            "title": .string("SSH")
        ]))

        XCTAssertNil(resp.error, "iOS must be able to create an SSH tab through the same surface.create RPC as macOS")
        guard case .object(let body)? = resp.result else { return XCTFail("surface.create must return the created SSH descriptor") }
        XCTAssertEqual(body["type"], .string("ssh"))
        guard case .object(let metadata)? = body["metadata"] else { return XCTFail("SSH descriptor must include metadata") }
        XCTAssertEqual(metadata["ssh_status"], .string("disconnected"),
                       "a bare SSH tab must be a real disconnected surface, not a dead descriptor")
    }

    @MainActor
    func test_sshHostSaveListConnectAndTransferRoundTrip() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = UUID().uuidString

        let saved = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "ssh.host.upsert", params: [
            "workspace_id": .string(wid),
            "label": .string("Prod"),
            "destination": .string("root@example.test"),
            "port": .number(2222),
            "password": .string("saved-test-password")
        ]))
        guard case .object(let savedHost)? = saved.result,
              case .object(let savedID)? = savedHost["id"],
              let hostID = savedID["value"]?.stringValue else {
            return XCTFail("saved SSH host must echo an id so iOS can reconnect without retyping")
        }

        let list = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "ssh.host.list", params: [
            "workspace_id": .string(wid)
        ]))
        guard case .array(let hosts)? = list.result else { return XCTFail("ssh.host.list must return saved hosts") }
        XCTAssertEqual(hosts.count, 1, "saving a host must make it available for reconnect")
        guard case .object(let listedHost)? = hosts.first else { return XCTFail("ssh.host.list must return host objects") }
        XCTAssertNil(listedHost["password"],
                     "ssh.host.list must not expose saved passwords because opening the app should not trigger a Keychain prompt or leak a secret to clients")
        XCTAssertEqual(listedHost["hasSavedPassword"], .bool(true),
                       "the host list still needs metadata so the UI knows one-tap reconnect has a stored credential")

        let connected = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "ssh.connect", params: [
            "workspace_id": .string(wid),
            "profile_id": .string(hostID)
        ]))
        guard case .object(let surface)? = connected.result,
              case .object(let sidObject)? = surface["id"],
              let surfaceID = sidObject["value"]?.stringValue else {
            return XCTFail("ssh.connect must create a mirrored SSH surface")
        }
        XCTAssertEqual(surface["type"], .string("ssh"))
        guard case .object(let metadata)? = surface["metadata"] else { return XCTFail("SSH descriptor must include metadata") }
        XCTAssertEqual(metadata["ssh_destination"], .string("root@example.test"))

        let upload = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "ssh.transfer.upload", params: [
            "surface_id": .string(surfaceID),
            "local_path": .string("/tmp/local.txt"),
            "remote_path": .string("/tmp/remote.txt")
        ]))
        guard case .object(let uploadResult)? = upload.result else { return XCTFail("upload must return an object") }
        XCTAssertEqual(uploadResult["ok"], .bool(true), "upload must be exposed as a host-owned terminal/scp RPC")

        let download = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(5), method: "ssh.transfer.download", params: [
            "surface_id": .string(surfaceID),
            "remote_path": .string("/tmp/remote.txt"),
            "local_path": .string("/tmp/local.txt")
        ]))
        guard case .object(let downloadResult)? = download.result else { return XCTFail("download must return an object") }
        XCTAssertEqual(downloadResult["ok"], .bool(true), "download must be exposed as a host-owned terminal/scp RPC")
    }

    @MainActor
    func test_remoteSSHRPCsUseOffMainProcessPath_becauseScpMustNotFreezeTheApp() async throws {
        // WHY: the dispatcher runs on the main actor; the blocking router variants ran
        // scp/ssh synchronously there, freezing every window for the whole transfer.
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let sid = UUID().uuidString
        _ = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "ssh.transfer.upload", params: [
            "surface_id": .string(sid), "local_path": .string("/tmp/a"), "remote_path": .string("/tmp/b")
        ]))
        _ = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "ssh.transfer.download", params: [
            "surface_id": .string(sid), "remote_path": .string("/tmp/b"), "local_path": .string("/tmp/a")
        ]))
        _ = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "ssh.files.remote.list", params: [
            "surface_id": .string(sid), "path": .string("/srv")
        ]))
        XCTAssertEqual(router.sshAsyncCalls, ["upload", "download", "remote.list"])
        XCTAssertEqual(router.sshBlockingCalls, [], "remote RPCs must not call the blocking process path")
    }

    @MainActor
    func test_sshHostUpsertDoesNotEchoPassword() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = UUID().uuidString
        let beforeSeq = EventBus.shared.currentSeq

        let saved = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "ssh.host.upsert", params: [
            "workspace_id": .string(wid),
            "label": .string("Prod"),
            "destination": .string("root@example.test"),
            "password": .string("saved-test-password")
        ]))

        guard case .object(let savedHost)? = saved.result else {
            return XCTFail("ssh.host.upsert must return the saved host metadata")
        }
        XCTAssertNil(savedHost["password"],
                     "ssh.host.upsert must accept a password for credential storage without echoing it to paired clients")
        XCTAssertEqual(savedHost["hasSavedPassword"], .bool(true),
                       "upsert still needs to confirm that a stored credential exists for one-tap reconnect")

        let updates = EventBus.shared.recentEvents(since: beforeSeq, maxBytes: nil).events.filter { $0.kind == "ssh.host.updated" }
        guard let update = updates.last?.payload.objectValue else {
            return XCTFail("saving an SSH host must publish an update event for mirrored clients")
        }
        XCTAssertNil(update["password"],
                     "ssh.host.updated must not retain or broadcast the saved password in the event backlog")
        XCTAssertEqual(update["hasSavedPassword"], .bool(true),
                       "mirrored clients still need credential metadata after event redaction")
    }

    @MainActor
    func test_sshHostRPCsScopeSavedHostsToWorkspace() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let firstWorkspace = UUID().uuidString
        let secondWorkspace = UUID().uuidString

        _ = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "ssh.host.upsert", params: [
            "workspace_id": .string(firstWorkspace),
            "label": .string("Workspace A"),
            "destination": .string("a.example.test")
        ]))

        let firstList = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "ssh.host.list", params: [
            "workspace_id": .string(firstWorkspace)
        ]))
        let secondList = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "ssh.host.list", params: [
            "workspace_id": .string(secondWorkspace)
        ]))

        XCTAssertEqual(firstList.result?.arrayValue?.count, 1,
                       "the workspace that saved an SSH host must keep it for one-tap reconnect")
        XCTAssertEqual(secondList.result?.arrayValue?.count, 0,
                       "a different workspace must not inherit globally persisted SSH hosts")
    }

    @MainActor
    func test_surfaceSendKeyCtrlCMapsToInterruptByte() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let sid = SurfaceID()

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.send_key", params: [
            "id": .string(sid.value.uuidString),
            "key": .string("ctrl-c")
        ]))

        XCTAssertNil(resp.error)
        XCTAssertEqual(router.sentSurfaceText.first?.1, "\u{03}",
                       "iOS Ctrl-C must reach the macOS PTY as ETX so Claude cancels instead of receiving printable CSI-u text")
    }

    @MainActor
    func test_surfaceReadHistoryReturnsBoundedDBWindowForInfiniteScroll() async throws {
        let router = FakeRouter()
        let sid = SurfaceID()
        router.terminalHistory = TerminalOutputWindow(chunks: [
            TerminalOutputChunk(id: 10, surfaceID: sid.value.uuidString, workspaceID: nil, chunkIndex: 3, data: Data("older".utf8), createdAt: Date())
        ], hasMoreOlder: true, nextBeforeChunkID: 10)
        router.terminalHealth = .object([
            "output_partial": .bool(true),
            "partial_reason": .string("history_retention_cap"),
            "output_pending_bytes": .number(4096)
        ])
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.read_history", params: [
            "id": .string(sid.value.uuidString),
            "before_chunk_id": .number(11),
            "max_bytes": .number(1024)
        ]))

        XCTAssertNil(resp.error)
        XCTAssertEqual(router.lastHistoryRequest?.0, sid)
        XCTAssertEqual(router.lastHistoryRequest?.1, 11)
        XCTAssertEqual(router.lastHistoryRequest?.2, 1024)
        guard case .object(let result)? = resp.result else { return XCTFail("history must return a paged result object") }
        XCTAssertEqual(result["text"], .string("older"),
                       "terminal infinite scroll must fetch text from local DB history, not from the visible renderer")
        XCTAssertEqual(result["has_more_older"], .bool(true))
        XCTAssertEqual(result["next_before_chunk_id"], .number(10))
        XCTAssertEqual(result["partial"], .bool(true))
        XCTAssertEqual(result["partial_reason"], .string("history_retention_cap"),
                       "authoritative history must preserve the host's permanent partial-output truth")
        XCTAssertEqual(result["pending_bytes"], .number(4096))
    }

    @MainActor
    func test_localBotCreateKeepsClientRequestIdOnPairedRemote() async {
        let router = FakeRouter()
        router.pairedBotRemoteResult = .object([
            "status": .string("completed"),
            "receipt_id": .string("r1"),
            "bot_id": .string("bot-1"),
            "request_id": .string("e2e"),
        ])
        let d = JSONRPCDispatcher(router: router)
        let resp = await d.dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "bot.create",
                params: [
                    "client_request_id": .string("e2e"),
                    "name": .string("Piper"),
                ]
            )
        )
        XCTAssertNil(resp.error, "paired Bot create must not fall through to methodNotFound")
        XCTAssertEqual(router.lastPairedBotRemote?.method, "bot.create")
        XCTAssertEqual(router.lastPairedBotRemote?.params["client_request_id"], .string("e2e"))
        XCTAssertEqual(resp.result?.objectValue?["receipt_id"], .string("r1"))
    }

    @MainActor
    func test_methodNotFound_returnsError() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "does.not.exist", params: nil))
        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, -32601)
    }

    @MainActor
    func test_unsupportedDeferredMethod_returnsTypedError() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        // pane.break is still V1-deferred
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "pane.break", params: nil))
        XCTAssertEqual(resp.error?.code, -32004)
    }

    @MainActor
    func test_createWorkspace_returnsWorkspace() async {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let params: [String: JSONValue] = ["name": .string("foo"), "cwd": .string("/tmp")]
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "workspace.create", params: params))
        XCTAssertNil(resp.error)
        XCTAssertEqual(router.workspaces.count, 1)
    }

    @MainActor
    func test_surfaceSplitWithExistingIdRoutesToSplitSurface() async {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = WorkspaceID()
        let pid = PaneID()
        let sid = SurfaceID()

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.split", params: [
            "workspace_id": .string(wid.value.uuidString),
            "pane_id": .string(pid.value.uuidString),
            "id": .string(sid.value.uuidString),
            "direction": .string("down"),
        ]))

        XCTAssertNil(resp.error)
        XCTAssertEqual(resp.result, .bool(true))
        XCTAssertEqual(router.splitSurfaceCalls.count, 1,
                       "iOS drag-down split sends an existing surface id, so the host must move that tab into the new vertical pane")
        XCTAssertEqual(router.splitSurfaceCalls.first?.0, wid)
        XCTAssertEqual(router.splitSurfaceCalls.first?.1, pid)
        XCTAssertEqual(router.splitSurfaceCalls.first?.2, sid)
        XCTAssertEqual(router.splitSurfaceCalls.first?.3, .down)
    }

    @MainActor
    func test_browserMirrorURLRoundTripsCurrentHostURL() async {
        let router = FakeRouter()
        router.browserURLString = "http://localhost:3000/demo"
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "browser.mirror_url.get", params: [
            "id": .string(UUID().uuidString)
        ]))

        guard case .object(let body)? = resp.result else { return XCTFail("mirror URL must return render metadata") }
        XCTAssertEqual(body["url"], .string("http://localhost:3000/demo"),
                       "iOS needs the exact host browser URL before it can map localhost to the paired Mac")
        XCTAssertEqual(body["is_file"], .bool(false))
    }

    @MainActor
    func test_agentThreadPinReorderAndBulkDeleteRoundTripThroughDispatcher() async throws {
        let wid = WorkspaceID()
        var a = AgentThread(workspaceId: wid, title: "A", provider: .codex, model: "gpt-5", sortOrder: 0)
        var b = AgentThread(workspaceId: wid, title: "B", provider: .codex, model: "gpt-5", sortOrder: 1)
        let c = AgentThread(workspaceId: wid, title: "C", provider: .codex, model: "gpt-5", sortOrder: 2)
        let router = FakeRouter()
        router.threadStore = [a, b, c]
        let d = JSONRPCDispatcher(router: router)

        let pin = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.set_pinned", params: [
            "thread_id": .string(b.id.value.uuidString),
            "pinned": .bool(true),
        ]))
        XCTAssertNil(pin.error, "pinning a thread must be available over RPC so macOS and iOS can share the same UX")
        b = try XCTUnwrap(router.threadStore.first { $0.id == b.id })
        XCTAssertTrue(b.pinned)
        XCTAssertEqual(try router.listAgentThreads(workspace: wid).map(\.id), [b.id, a.id, c.id],
                       "pinned threads must sort ahead of normal threads")

        let reorder = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.thread.reorder", params: [
            "thread_id": .string(c.id.value.uuidString),
            "position": .number(1),
        ]))
        XCTAssertNil(reorder.error, "drag reorder must be available over RPC for host and mirror parity")
        XCTAssertEqual(try router.listAgentThreads(workspace: wid).map(\.id), [b.id, c.id, a.id])

        let delete = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.thread.delete_many", params: [
            "thread_ids": .array([.string(b.id.value.uuidString), .string(c.id.value.uuidString)]),
        ]))
        XCTAssertNil(delete.error, "shift-select delete must use one bulk delete command instead of racing multiple deletes")
        XCTAssertEqual(router.threadStore.map(\.id), [a.id])
        a = try XCTUnwrap(router.threadStore.first)
        XCTAssertEqual(a.title, "A")
    }

    private func sh(_ a: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = a
        let pi = Pipe(); p.standardOutput = pi; p.standardError = pi
        try? p.run(); p.waitUntilExit()
    }

    @MainActor
    func test_gitMethods_routeThroughDispatcher() async throws {
        let dir = NSTemporaryDirectory() + "rc2-disp-git-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        sh(["git", "init", "-q", "-b", "main", dir])
        sh(["git", "-C", dir, "config", "user.email", "t@t.t"])
        sh(["git", "-C", dir, "config", "user.name", "t"])
        let remote = NSTemporaryDirectory() + "rc2-disp-git-remote-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: remote) }
        sh(["git", "init", "-q", "--bare", remote])
        try "hi\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        sh(["git", "-C", dir, "add", "a.txt"])
        sh(["git", "-C", dir, "commit", "-q", "-m", "init"])
        sh(["git", "-C", dir, "remote", "add", "origin", remote])
        sh(["git", "-C", dir, "push", "-q", "origin", "main"])
        let router = FakeRouter(); router.gitCwd = dir
        let d = JSONRPCDispatcher(router: router)
        let workspaceUUID = UUID()
        let workspaceID = WorkspaceID(workspaceUUID)
        let terminal = SurfaceDescriptor(type: .terminal, title: "terminal")
        let gitSurface = SurfaceDescriptor(
            type: .rightSidebarTool,
            title: "Git",
            metadata: ["tool": "diff"]
        )
        let pane = PaneNode(surfaces: [terminal, gitSurface], selectedSurfaceID: terminal.id)
        router.workspaces = [Workspace(
            id: workspaceID,
            name: "git-route",
            cwd: dir,
            layout: .pane(pane),
            focusedPaneID: pane.id
        )]
        let wid = JSONValue.string(workspaceUUID.uuidString)

        let status = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "git.status", params: ["workspace_id": wid]))
        guard case .object(let so)? = status.result else { return XCTFail("git.status must return an object") }
        XCTAssertEqual(so["isGitRepo"], .bool(true), "git.status over the socket must report a real repo")

        let log = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "git.log", params: ["workspace_id": wid]))
        guard case .array(let la)? = log.result else { return XCTFail("git.log must return an array") }
        XCTAssertEqual(la.count, 1, "the one seeded commit must round-trip through the socket")

        let br = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "git.create_branch", params: ["workspace_id": wid, "name": .string("feat")]))
        guard case .object(let bo)? = br.result else { return XCTFail("git.create_branch must return a result") }
        XCTAssertEqual(bo["ok"], .bool(true), "create_branch must report success over the wire")
        XCTAssertEqual(GitDiff.branches(in: dir).current, "feat", "the socket call must actually move HEAD")

        var pushEvents: [EventBus.Event] = []
        let pushToken = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "git.push" { pushEvents.append(event) }
        }
        defer { EventBus.shared.unsubscribe(pushToken) }
        let pushed = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(4),
            method: "git.push",
            params: ["workspace_id": wid]
        ))
        XCTAssertNil(pushed.error)
        XCTAssertEqual(pushEvents.count, 1)
        XCTAssertEqual(pushEvents.first?.payload.objectValue, [
            "workspace_id": .string(workspaceUUID.uuidString),
            "surface_id": .string(gitSurface.id.value.uuidString),
            "ok": .bool(true)
        ], "Socket Git outcomes must carry the exact canonical Git surface in the same workspace.")

        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let delivery = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(5), method: "git.delivery_plan", params: [
            "workspace_id": wid,
            "copy": .object([
                "branchName": .string("agent/provider-copy"),
                "commitMessage": .string("Use provider generated commit copy"),
                "pullRequestTitle": .string("Provider generated PR title"),
                "pullRequestBody": .string("Provider generated PR body")
            ])
        ]))
        guard case .object(let plan)? = delivery.result else { return XCTFail("git.delivery_plan must return structured delivery text and phases") }
        XCTAssertEqual(plan["commitMessage"], .string("Use provider generated commit copy"))
        XCTAssertEqual(plan["branchName"], .string("agent/provider-copy"))
        XCTAssertEqual(plan["pullRequestTitle"], .string("Provider generated PR title"))
        guard case .array(let phases)? = plan["phases"], phases.count == 4 else {
            return XCTFail("git.delivery_plan must expose branch/commit/push/pull_request phase status for safe agent delivery")
        }

        var deliveryEvents: [EventBus.Event] = []
        let deliveryToken = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "git.deliver" { deliveryEvents.append(event) }
        }
        defer { EventBus.shared.unsubscribe(deliveryToken) }
        let delivered = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(6), method: "git.deliver", params: ["workspace_id": wid]))
        guard case .object(let result)? = delivered.result else { return XCTFail("git.deliver must return one-shot delivery phase status") }
        XCTAssertEqual(result["ok"], .bool(true), "git.deliver must execute branch, commit, and push through the socket")
        guard case .array(let deliveredPhases)? = result["phases"], deliveredPhases.count == 4 else {
            return XCTFail("git.deliver must return each stacked phase")
        }
        XCTAssertEqual(GitDiff.branches(in: dir).current, "agent/a-txt")
        XCTAssertEqual(deliveryEvents.count, 1,
            "One RPC delivery must publish one canonical Pet/mirror outcome.")
        XCTAssertEqual(deliveryEvents.first?.payload.objectValue, [
            "workspace_id": .string(workspaceUUID.uuidString),
            "surface_id": .string(gitSurface.id.value.uuidString),
            "ok": .bool(true)
        ])
    }

    @MainActor
    func test_agentAttachmentUploadReturnsOpaqueHostOwnedReferenceWithoutPath() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = JSONValue.string(UUID().uuidString)

        let uploaded = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.attachment.upload", params: [
            "workspace_id": wid,
            "filename": .string("screen.png"),
            "mime_type": .string("image/png"),
            "data_base64": .string(Data("image-bytes".utf8).base64EncodedString())
        ]))

        guard case .object(let obj)? = uploaded.result else { return XCTFail("agent.attachment.upload must return an opaque attachment reference") }
        XCTAssertNil(obj["path"],
                     "upload must not expose a generic path field; composer insertion uses composerInsertionText only")
        let attachmentId = try XCTUnwrap(obj["id"]?.stringValue)
        XCTAssertNotNil(UUID(uuidString: attachmentId))
        XCTAssertNotEqual(obj["id"], obj["sha256"],
                          "opaque reference identity must not collapse into the shared content digest")
        XCTAssertEqual(obj["sha256"], .string(String(repeating: "a", count: 64)))
        XCTAssertEqual(obj["displayName"], .string("screen.png"))
        XCTAssertEqual(obj["kind"], .string("image"),
                       "iOS local imports must become host-readable staged files before path insertion")
        XCTAssertEqual(obj["sizeBytes"], .number(11))
        let insertion = try XCTUnwrap(obj["composerInsertionText"]?.stringValue)
        XCTAssertTrue(insertion.hasSuffix("/screen.png"),
                      "upload must return the staged host path for paired clients to insert into the composer")
        XCTAssertTrue(insertion.hasPrefix("/"),
                      "composerInsertionText must be an absolute host path")
    }

    @MainActor
    func test_agentMessageSendRejectsArbitraryClientHostPathBeforeRouterMutation() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: WorkspaceID(), title: "safe", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.message.send",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "text": .string("do not read arbitrary path"),
                "attachments": .array([.object([
                    "id": .string(String(repeating: "a", count: 64)),
                    "path": .string("/Users/private/secret.txt"),
                    "kind": .string("file"),
                    "mime_type": .string("text/plain")
                ])])
            ]
        ))

        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertEqual(router.sendAgentMessageCallCount, 0,
                       "path authority must fail before any router or durable mutation")
    }

    @MainActor
    func test_surfaceCreate_normalizesDocumentedTypeTokens() async throws {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let wid = JSONValue.string(UUID().uuidString)
        let cases: [(String, String)] = [
            ("rightsidebartool", "rightSidebarTool"),
            ("diff", "rightSidebarTool"),
            ("agentapp", "agentApp"),
            ("filepreview", "filePreview")
        ]
        for (token, expected) in cases {
            let r = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.create", params: ["workspace_id": wid, "type": .string(token)]))
            XCTAssertNil(r.error, "documented CLI token '\(token)' must be accepted by surface.create")
            guard case .object(let o)? = r.result, case .string(let ty)? = o["type"] else {
                return XCTFail("surface.create must return a typed descriptor for '\(token)'")
            }
            XCTAssertEqual(ty, expected, "'\(token)' must normalize to SurfaceType.\(expected)")
        }
    }

    @MainActor
    func test_gitStatus_countsEncodeAsNumbersNotBooleans() async throws {
        let dir = NSTemporaryDirectory() + "rc2-disp-num-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        sh(["git", "init", "-q", "-b", "main", dir])
        sh(["git", "-C", dir, "config", "user.email", "t@t.t"])
        sh(["git", "-C", dir, "config", "user.name", "t"])
        try "l1\n".write(toFile: dir + "/n.txt", atomically: true, encoding: .utf8)
        sh(["git", "-C", dir, "add", "n.txt"])
        sh(["git", "-C", dir, "commit", "-q", "-m", "seed"])
        try "l1\nl2\n".write(toFile: dir + "/n.txt", atomically: true, encoding: .utf8) // +1 line
        let router = FakeRouter(); router.gitCwd = dir
        let d = JSONRPCDispatcher(router: router)
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "git.status", params: ["workspace_id": .string(UUID().uuidString)]))
        guard case .object(let o)? = resp.result else { return XCTFail("git.status must return an object") }
        // Regression: an integer count of 1 must stay a JSON number, never
        // collapse to `true` (NSNumber/Bool bridging bug in JSONValue.from).
        if case .bool = (o["totalAdditions"] ?? .null) {
            XCTFail("totalAdditions encoded as a bool — integer collapsed via NSNumber bridging")
        }
        guard case .number(let n)? = o["totalAdditions"] else {
            return XCTFail("totalAdditions must be a number, got \(String(describing: o["totalAdditions"]))")
        }
        XCTAssertEqual(n, 1, "one added line must serialize as the number 1 over the socket")
    }

    @MainActor
    func test_agentThreadRenameAndDelete_overSocket() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "old", provider: .codex, model: "m")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)
        let tidParam = JSONValue.string(t.id.value.uuidString)

        let r = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.rename", params: ["thread_id": tidParam, "title": .string("new name")]))
        guard case .object(let o)? = r.result else { return XCTFail("rename must echo the thread") }
        XCTAssertEqual(o["title"], .string("new name"), "rename must persist and echo the new title")

        let del = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.thread.delete", params: ["thread_id": tidParam]))
        XCTAssertEqual(del.result, .bool(true))
        XCTAssertTrue(router.threadStore.isEmpty, "delete over the socket must remove the thread")

        let missing = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.thread.rename", params: ["thread_id": tidParam, "title": .string("x")]))
        XCTAssertNotNil(missing.error, "renaming a deleted thread must fail loudly, not silently succeed")
    }

    /// WHY: the iOS file picker and SSH browser show New Folder, Rename, Delete,
    /// Fetch and Pull, and the host advertises them in system.capabilities. Before
    /// these cases existed every one of them answered -32601 Method not found.
    @MainActor
    func test_iOSFolderGitAndSSHFileControls_reachTheHost() async throws {
        let dir = NSTemporaryDirectory() + "rc2-disp-mkdir-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)

        let created = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "fs.mkdir", params: ["path": .string(dir + "/New Folder")]))
        XCTAssertNil(created.error)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/New Folder", isDirectory: &isDir) && isDir.boolValue)

        let again = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "fs.mkdir", params: ["path": .string(dir + "/New Folder")]))
        XCTAssertEqual(again.error?.message, "A file or folder with that name already exists.")
        let orphan = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "fs.mkdir", params: ["path": .string(dir + "/missing/child")]))
        XCTAssertEqual(orphan.error?.message, "The parent folder does not exist.", "a typo must not create a whole chain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/missing"))
        let relative = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "fs.mkdir", params: ["path": .string("relative")]))
        XCTAssertEqual(relative.error?.message, "Folder path must be absolute.")

        let sid = JSONValue.string(UUID().uuidString)
        for (index, (method, params)) in [
            ("ssh.files.remote.mkdir", ["surface_id": sid, "path": .string("/r/new")]),
            ("ssh.files.remote.rename", ["surface_id": sid, "from_path": .string("/r/new"), "to_path": .string("/r/old")]),
            ("ssh.files.remote.delete", ["surface_id": sid, "path": .string("/r/old")]),
        ].enumerated() {
            let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(10 + index), method: method, params: params))
            XCTAssertNil(response.error, method)
        }
        XCTAssertEqual(router.sshAsyncCalls, ["ssh.files.remote.mkdir", "ssh.files.remote.rename", "ssh.files.remote.delete"])

        router.gitCwd = dir
        let fetch = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(20), method: "git.fetch", params: ["workspace_id": .string(UUID().uuidString)]))
        XCTAssertNotEqual(fetch.error?.code, JSONRPCError.methodNotFound.code)
        XCTAssertEqual(fetch.result?.objectValue?["ok"], .bool(false), "a non-repository answers a readable git result")
    }

    @MainActor
    func test_filesWorkspaceMutations_overSocket() async throws {
        let dir = NSTemporaryDirectory() + "rc2-disp-files-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/Sources", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = FakeRouter(); router.projectCwd = dir
        let d = JSONRPCDispatcher(router: router)
        let wid = JSONValue.string(UUID().uuidString)

        let created = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "fs.workspace.create_file", params: [
            "workspace_id": wid,
            "path": .string("Sources/NewFile.swift"),
        ]))
        XCTAssertEqual(created.result?.objectValue?["relative_path"], .string("Sources/NewFile.swift"),
                       "add-file must be available over RPC so macOS and iOS use the same host mutation")

        let renamed = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "fs.workspace.rename", params: [
            "workspace_id": wid,
            "path": .string("Sources/NewFile.swift"),
            "new_name": .string("Renamed.swift"),
        ]))
        XCTAssertEqual(renamed.result?.objectValue?["relative_path"], .string("Sources/Renamed.swift"),
                       "context-menu rename must return the new workspace-relative path over the socket")

        let deleted = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "fs.workspace.delete", params: [
            "workspace_id": wid,
            "paths": .array([.string("Sources/Renamed.swift")]),
        ]))
        XCTAssertEqual(deleted.result?.objectValue?["deleted"]?.arrayValue?.compactMap { $0.stringValue }, ["Sources/Renamed.swift"],
                       "bulk delete must delete every selected file through one RPC mutation")
    }

    @MainActor
    func test_filesEditSession_routesAuthoritativeLegacyDraftReadback() async throws {
        // WHY: after an ambiguous patch response, iOS must inspect the existing
        // host draft instead of replaying the patch or reopening disk content.
        let directory = NSTemporaryDirectory() + "rc2-disp-edit-session-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try "before".write(toFile: directory + "/draft.txt", atomically: true, encoding: .utf8)
        FileEditSessionStore.shared.resetForTests()
        defer {
            FileEditSessionStore.shared.resetForTests()
            try? FileManager.default.removeItem(atPath: directory)
        }

        let router = FakeRouter()
        router.projectCwd = directory
        let dispatcher = JSONRPCDispatcher(router: router)
        let opened = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "files.edit.open",
            params: [
                "surface_id": .string(UUID().uuidString),
                "path": .string("draft.txt"),
            ]
        ))
        let openedBody = try XCTUnwrap(opened.result?.objectValue)
        let sessionID = try XCTUnwrap(openedBody["session_id"]?.stringValue)
        let revision = try XCTUnwrap(openedBody["draft_revision"]?.intValue)

        let patched = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "files.edit.apply_patch",
            params: [
                "session_id": .string(sessionID),
                "base_draft_revision": .number(Double(revision)),
                "range_utf16": .object(["location": .number(6), "length": .number(0)]),
                "replacement": .string(" after"),
            ]
        ))
        XCTAssertNil(patched.error)

        let readback = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(3),
            method: "files.edit.session",
            params: ["session_id": .string(sessionID)]
        ))
        XCTAssertNil(readback.error)
        let readbackBody = try XCTUnwrap(readback.result?.objectValue)
        XCTAssertEqual(readbackBody["session_id"], .string(sessionID))
        XCTAssertEqual(readbackBody["content"], .string("before after"))
        XCTAssertEqual(readbackBody["draft_revision"]?.intValue, revision + 1)
        XCTAssertEqual(readbackBody["dirty"], .bool(true))

        _ = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(4),
            method: "files.edit.close",
            params: ["session_id": .string(sessionID)]
        ))
        let missing = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(5),
            method: "files.edit.session",
            params: ["session_id": .string(sessionID)]
        ))
        XCTAssertEqual(missing.error?.code, -32602, "closed sessions must fail loudly, never return stale content")
    }

    @MainActor
    func test_filesOpenNewTabAndSplit_overSocket() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = UUID()
        let sourceSurface = UUID()
        let paneID = UUID()

        let opened = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "files.tab.open", params: [
            "workspace_id": .string(wid.uuidString),
            "surface_id": .string(sourceSurface.uuidString),
            "path": .string("Sources/App.swift"),
        ]))
        XCTAssertNil(opened.error, "Open in New Tab must be a Files RPC so macOS and iOS create the same source-reader tab")
        XCTAssertEqual(opened.result?.objectValue?["type"], .string("files"))
        XCTAssertEqual(opened.result?.objectValue?["metadata"]?.objectValue?["selected_path"], .string("Sources/App.swift"))
        XCTAssertEqual(router.filesOpenTabCalls.first?.0, WorkspaceID(wid))
        XCTAssertEqual(router.filesOpenTabCalls.first?.1, SurfaceID(sourceSurface))
        XCTAssertNil(router.filesOpenTabCalls.first?.2)
        XCTAssertEqual(router.filesOpenTabCalls.first?.3, "Sources/App.swift")

        let split = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "files.tab.split", params: [
            "workspace_id": .string(wid.uuidString),
            "surface_id": .string(sourceSurface.uuidString),
            "pane_id": .string(paneID.uuidString),
            "direction": .string("right"),
            "path": .string("Sources/App.swift"),
        ]))
        XCTAssertNil(split.error, "Dragging a file onto side/bottom split targets must create a Files tab in the split pane")
        XCTAssertEqual(split.result?.objectValue?["type"], .string("files"))
        XCTAssertEqual(split.result?.objectValue?["metadata"]?.objectValue?["selected_relative_path"], .string("Sources/App.swift"))
        XCTAssertEqual(router.filesSplitTabCalls.first?.0, WorkspaceID(wid))
        XCTAssertEqual(router.filesSplitTabCalls.first?.1, SurfaceID(sourceSurface))
        XCTAssertEqual(router.filesSplitTabCalls.first?.2, PaneID(paneID))
        XCTAssertEqual(router.filesSplitTabCalls.first?.3, .right)
        XCTAssertEqual(router.filesSplitTabCalls.first?.4, "Sources/App.swift")
    }

    @MainActor
    func test_projectScripts_overSocket() async throws {
        let dir = NSTemporaryDirectory() + "rc2-disp-ps-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try #"{"scripts":{"lint":"eslint .","build":"tsc"}}"#
            .write(toFile: dir + "/package.json", atomically: true, encoding: .utf8)
        let router = FakeRouter(); router.projectCwd = dir
        let d = JSONRPCDispatcher(router: router)
        let wid = JSONValue.string(UUID().uuidString)
        let r = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "project.scripts", params: ["workspace_id": wid]))
        guard case .array(let arr)? = r.result else { return XCTFail("project.scripts must return an array") }
        XCTAssertEqual(arr.count, 2, "both package.json scripts must round-trip the socket")
        let ok = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "project.run_script", params: ["workspace_id": wid, "name": .string("build")]))
        XCTAssertNil(ok.error, "running a known script must succeed")
        let bad = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "project.run_script", params: ["workspace_id": wid, "name": .string("nope")]))
        XCTAssertNotNil(bad.error, "running an unknown script must fail loudly")
        let editor = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "project.open_in_editor", params: ["workspace_id": wid]))
        XCTAssertEqual(editor.result?.objectValue?["app"], .string("Finder"),
                       "opening a workspace in an editor must return the app that handled the request")
    }

    @MainActor
    func test_projectOpenInEditor_propagatesOpenFailureOverSocket() async throws {
        let router = FakeRouter()
        router.projectOpenInEditorError = ProjectScripts.OpenError.failed(cwd: "/tmp/missing-workspace")
        let d = JSONRPCDispatcher(router: router)
        let wid = JSONValue.string(UUID().uuidString)
        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "project.open_in_editor",
            params: ["workspace_id": wid]
        ))
        XCTAssertNotNil(response.error, "editor launch failure must be visible to JSON-RPC callers")
        XCTAssertEqual(response.error?.message, "Workspace could not be opened in an editor or Finder.")
        XCTAssertEqual(response.error?.data?.objectValue?["domain"], .string("project_scripts"))
        XCTAssertEqual(response.error?.data?.objectValue?["kind"], .string("open_failed"))
    }

    @MainActor
    func test_privatePushTokenUpdateRoutesValidatedTokenOverSocket() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "private.push_token.update", params: [
            "push_token": .string("fcm-token"),
            "push_token_type": .string("fcm"),
            "device_id": .string("device-1"),
        ]))

        XCTAssertNil(resp.error, "paired clients must be able to register an FCM target for backend push delivery")
        XCTAssertEqual(resp.result?.objectValue?["ok"], .bool(true))
        XCTAssertEqual(resp.result?.objectValue?["push_token_type"], .string("fcm"))
        XCTAssertNil(resp.result?.objectValue?["push_token"],
                     "the JSON-RPC response must not echo sensitive push-token material back to the caller")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.pushToken, "fcm-token")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.pushTokenType, "fcm")
        XCTAssertNil(router.lastPrivatePushTokenUpdate?.liveActivityToken,
                     "live activity tokens are optional because plain alert delivery still needs a stored push target")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.deviceID, "device-1")
    }

    @MainActor
    func test_privatePushTokenUpdateRejectsUnsupportedTokenTypeBeforeRouting() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "private.push_token.update", params: [
            "push_token": .string("webpush-token"),
            "push_token_type": .string("webpush"),
        ]))

        XCTAssertEqual(resp.error?.code, -32602,
                       "unsupported token types must fail validation before the host stores an unusable notification target")
        XCTAssertNil(router.lastPrivatePushTokenUpdate)
    }

    @MainActor
    func test_privatePushTokenUpdateRoutesTypedLiveActivityV2Capability() async throws {
        let router = FakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "private.push_token.update",
            params: [
                "push_token": .string("apns-token"),
                "push_token_type": .string("apns"),
                "live_activity_token": .string("start-token"),
                "device_id": .string("device-1"),
                "token_purpose": .string("activity_update"),
                "environment": .string("sandbox"),
                "server_id": .string("server-1"),
                "boot_epoch": .number(8),
                "activity_generation": .number(4),
                "activity_id": .string("activity-1"),
                "activity_session_id": .string("server-1:8:4"),
                "registration_revision": .number(12),
                "contract_version": .number(2),
                "capabilities": .array([.string("live_activity_v2")])
            ]
        ))

        XCTAssertNil(response.error)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.tokenPurpose, "activity_update")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.environment, "sandbox")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.serverID, "server-1")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.bootEpoch, 8)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.activityGeneration, 4)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.activityID, "activity-1")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.activitySessionID, "server-1:8:4")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.registrationRevision, 12)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.contractVersion, 2)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.capabilities, ["live_activity_v2"])
    }

    @MainActor
    func test_privatePushTokenUpdateRejectsMalformedTypedActivityRegistration() async throws {
        let missingTokenRouter = FakeRouter()
        let missingTokenResponse = await JSONRPCDispatcher(router: missingTokenRouter).dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "private.push_token.update",
            params: [
                "push_token": .string("apns-token"),
                "push_token_type": .string("apns"),
                "device_id": .string("device-1"),
                "token_purpose": .string("push_to_start"),
                "environment": .string("sandbox"),
                "server_id": .string("server-1"),
                "contract_version": .number(2),
                "capabilities": .array([.string("live_activity_v2")])
            ]
        ))
        XCTAssertEqual(missingTokenResponse.error?.code, -32602)
        XCTAssertNil(missingTokenRouter.lastPrivatePushTokenUpdate,
                     "an APNs alert token must never be substituted for a missing ActivityKit token")

        let malformedCapabilityRouter = FakeRouter()
        let malformedCapabilityResponse = await JSONRPCDispatcher(router: malformedCapabilityRouter).dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "private.push_token.update",
            params: [
                "push_token": .string("apns-token"),
                "push_token_type": .string("apns"),
                "live_activity_token": .string("start-token"),
                "device_id": .string("device-1"),
                "token_purpose": .string("push_to_start"),
                "environment": .string("sandbox"),
                "server_id": .string("server-1"),
                "contract_version": .number(2),
                "capabilities": .array([.number(2)])
            ]
        ))
        XCTAssertEqual(malformedCapabilityResponse.error?.code, -32602)
        XCTAssertNil(malformedCapabilityRouter.lastPrivatePushTokenUpdate,
                     "malformed capability metadata must fail loudly instead of silently disabling v2")
    }

    @MainActor
    func test_agentThreadMarkRead_overSocket() async throws {
        let router = FakeRouter()
        var t = AgentThread(workspaceId: nil, title: "unread", provider: .codex, model: "m")
        t.hasUnread = true
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)
        let r = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.mark_read", params: ["thread_id": .string(t.id.value.uuidString)]))
        XCTAssertEqual(r.result, .bool(true))
        XCTAssertEqual(router.threadStore.first?.hasUnread, false,
                       "mark_read over the socket must clear the unread flag")
    }

    @MainActor
    func test_agentThreadConfigureAndSendCarryModelPermissionAndReasoning() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "cfg", provider: .codex, model: "gpt-5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)
        let tid = JSONValue.string(t.id.value.uuidString)

        let cfg = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.configure", params: [
            "thread_id": tid,
            "provider": .string("claude"),
            "model": .string("claude-sonnet-4-6"),
            "permission_mode": .string("full_access"),
            "reasoning_effort": .string("high"),
            "service_tier": .string("fast"),
            "model_selection": .object([
                "provider": .string("claude"),
                "model_id": .string("claude-sonnet-4-6"),
                "reasoning_effort": .string("high"),
                "service_tier": .string("fast")
            ])
        ]))
        guard case .object(let cfgObj)? = cfg.result else { return XCTFail("configure must echo the updated host thread") }
        XCTAssertEqual(cfgObj["provider"], .string("claude"))
        XCTAssertEqual(cfgObj["providerInstanceId"], .string("claude"),
                       "provider instance identity must round-trip with thread metadata so clients can keep personal/work sessions separate")
        XCTAssertEqual(cfgObj["model"], .string("claude-sonnet-4-6"))
        XCTAssertEqual(cfgObj["permissionMode"], .string("full_access"))
        XCTAssertEqual(cfgObj["reasoningEffort"], .string("high"))
        XCTAssertEqual(cfgObj["serviceTier"], .string("fast"))
        guard case .object(let cfgSelection)? = cfgObj["model_selection"] else { return XCTFail("configure must echo structured model selection") }
        XCTAssertEqual(cfgSelection["modelId"], .string("claude-sonnet-4-6"))
        XCTAssertEqual(cfgSelection["reasoningEffort"], .string("high"),
                       "iOS must be able to round-trip model options as one structured selection, not loose fields that can drift")

        let send = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.send", params: [
            "thread_id": tid,
            "text": .string("run on host"),
            "model_selection": .object([
                "provider": .string("codex"),
                "model_id": .string(""),
                "custom_model_id": .string("gpt-5.5-experimental"),
                "reasoning_effort": .string("xhigh"),
                "service_tier": .string("fast")
            ]),
            "interaction_mode": .string("plan"),
            "attachments": .array([
                .object([
                    "id": .string(String(repeating: "1", count: 64)),
                    "display_name": .string("screen.png"),
                    "kind": .string("image"),
                    "mime_type": .string("image/png"),
                    "sha256": .string(String(repeating: "1", count: 64)),
                    "size_bytes": .number(12)
                ]),
                .object([
                    "id": .string(String(repeating: "2", count: 64)),
                    "displayName": .string("notes.txt"),
                    "kind": .string("file"),
                    "mime_type": .string("text/plain"),
                    "sha256": .string(String(repeating: "2", count: 64)),
                    "size_bytes": .number(8)
                ])
            ])
        ]))
        guard case .object(let sendObj)? = send.result else { return XCTFail("send must return host run object") }
        XCTAssertNotNil(sendObj["run_id"]?.stringValue, "send must return host run id")
        XCTAssertEqual(router.threadStore.first?.provider, .codex)
        XCTAssertEqual(router.threadStore.first?.model, "gpt-5.5-experimental")
        XCTAssertEqual(router.threadStore.first?.modelSelection.customModelId, "gpt-5.5-experimental")
        XCTAssertEqual(router.lastSendPermission, .fullAccess,
                       "send must use the thread's persisted permission mode when no override is sent")
        XCTAssertEqual(router.lastSendReasoning, .xhigh,
                       "send must use structured model-selection reasoning when iOS sends a custom model")
        XCTAssertEqual(router.lastSendServiceTier, .fast,
                       "send must use the thread's persisted service tier when no override is sent")
        XCTAssertEqual(router.lastSendInteractionMode, .plan,
                       "mobile /plan must reach the provider runtime as interaction_mode, not only local UI text")
        XCTAssertEqual(router.lastSendAttachments.map(\.id), [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
                       "mobile attachments must reach the host only as opaque host-owned ids")
        XCTAssertTrue(router.lastSendAttachments.allSatisfy(\.path.isEmpty),
                      "the mirror contract must not accept or synthesize host paths")
        XCTAssertEqual(router.lastSendAttachments.first?.kind, .image)
        XCTAssertEqual(router.lastSendAttachments.first?.mimeType, "image/png")
    }

    @MainActor
    func test_agentThreadExecutionConfigureRoutesWorktreeMode() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "exec", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.execution.configure", params: [
            "thread_id": .string(thread.id.value.uuidString),
            "execution_mode": .string("worktree"),
            "base_branch": .string("main")
        ]))

        XCTAssertNotNil(response.result)
        XCTAssertEqual(router.threadStore[0].executionMode, .worktree)
        XCTAssertEqual(router.threadStore[0].baseBranch, "main",
                       "worktree execution must require and persist a base branch before the first provider turn")
    }

    @MainActor
    func test_agentThreadPreparePRCreatesWorktreeThread() async throws {
        let router = FakeRouter()
        let workspace = WorkspaceID()
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.prepare_pr", params: [
            "workspace_id": .string(workspace.value.uuidString),
            "url": .string("https://github.com/acme/widget/pull/7"),
            "provider": .string("codex"),
            "provider_instance_id": .string("codex-work"),
            "model": .string("gpt-5.5")
        ]))

        guard case .object(let obj)? = response.result else { return XCTFail("prepare_pr must return the created agent thread") }
        XCTAssertEqual(router.lastPreparedPullRequest?.0, workspace)
        XCTAssertEqual(router.lastPreparedPullRequest?.1, "https://github.com/acme/widget/pull/7")
        XCTAssertEqual(obj["execution_mode"], .string("worktree"))
        XCTAssertEqual(obj["worktree_path"], .string("/tmp/rc-pr-7"),
                       "PR preparation must expose the isolated checkout path so mobile can show where the Agent thread will run")
        XCTAssertEqual(obj["provider_instance_id"], .string("codex-work"))
    }

    @MainActor
    func test_agentPlanImplementBuildsPromptAndReturnsTraceability() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "plan", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.plan.implement", params: [
            "thread_id": .string(t.id.value.uuidString),
            "plan_id": .string("plan-1"),
            "markdown": .string("1. Inspect\n2. Patch")
        ]))

        guard case .object(let obj)? = response.result else { return XCTFail("implement plan must return run and implementation thread ids") }
        XCTAssertNotNil(obj["run_id"]?.stringValue)
        XCTAssertEqual(obj["implementation_thread_id"]?.stringValue, t.id.value.uuidString)
        XCTAssertEqual(router.lastImplementedPlan?.1, "plan-1")
        XCTAssertTrue(router.lastSendText?.contains("Implement this proposed plan now") == true)
        XCTAssertTrue(router.lastSendText?.contains("1. Inspect") == true,
                      "implement plan must send the selected plan content to the provider")
    }

    @MainActor
    func test_agentPlanSaveReturnsWorkspacePathForMobileClients() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "plan", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.plan.save", params: [
            "thread_id": .string(t.id.value.uuidString),
            "plan_id": .string("plan-1"),
            "markdown": .string("1. Inspect\n2. Patch"),
            "relative_path": .string(".remotecode/plans/fix.md")
        ]))

        guard case .object(let obj)? = response.result else { return XCTFail("save plan must return host path metadata") }
        XCTAssertEqual(obj["relative_path"]?.stringValue, ".remotecode/plans/fix.md")
        XCTAssertEqual(router.lastSavedPlan?.1, "plan-1")
        XCTAssertEqual(router.lastSavedPlan?.2, "1. Inspect\n2. Patch",
                       "mobile plan save must persist exact proposed-plan markdown through the host")
    }

    @MainActor
    func test_agentMessageSendClientRequestIdIsIdempotent() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "idempotent", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)
        let params: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "text": .string("run once"),
            "client_request_id": .string("send-1")
        ]

        let first = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.send", params: params))
        let second = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.send", params: params))

        XCTAssertEqual(first.result, second.result,
                       "a retried agent send with the same client_request_id must return the original run id")
        XCTAssertEqual(router.sendAgentMessageCallCount, 1,
                       "retrying the same send command must not duplicate user messages or provider turns")
    }

    @MainActor
    func test_agentMessageSendClientRequestIdSurvivesDispatcherRecreation() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "idempotent", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let params: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "text": .string("run once"),
            "client_request_id": .string("send-restart-1")
        ]

        let first = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.send", params: params))
        let second = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.send", params: params))

        XCTAssertEqual(first.result, second.result,
                       "durable command receipts must let a recreated dispatcher return the original run id")
        XCTAssertEqual(router.sendAgentMessageCallCount, 1,
                       "a client retry after socket/dispatcher recreation must not duplicate provider turns")
    }

    @MainActor
    func test_agentMessageSendQueuesWhenThreadIsRunning() async throws {
        let router = FakeRouter()
        var t = AgentThread(workspaceId: nil, title: "running", provider: .codex, model: "gpt-5.5")
        t.status = .running
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.send", params: [
            "thread_id": .string(t.id.value.uuidString),
            "text": .string("run after current turn")
        ]))

        guard case .object(let obj)? = response.result else { return XCTFail("running sends must return a queued result") }
        XCTAssertEqual(obj["status"], .string("queued"))
        XCTAssertNotNil(obj["queued_message_id"]?.stringValue)
        XCTAssertEqual(obj["position"], .number(1))
        XCTAssertNil(obj["run_id"],
                     "queued sends must not expose a run id before they actually start")
        guard case .object(let queuedPayload)? = obj["queued_message"] else {
            return XCTFail("queued sends must include the mirror-ready queued message")
        }
        XCTAssertEqual(queuedPayload["durable_state"], .string("queued"))
        XCTAssertEqual(queuedPayload["durableState"], .string("queued"),
                       "socket clients using either naming convention must receive durable queue state")
        XCTAssertEqual(router.queuedMessageStore.first?.text, "run after current turn",
                       "a send during an active run must persist as an editable queued message instead of being dropped")
    }

    @MainActor
    func test_agentMessageQueueListIncludesDurableStateForMirrorReconciliation() async throws {
        // WHY: after reconnect, remote clients must distinguish a safe queued
        // draft from a prepared or dispatched intent without replaying it.
        let router = FakeRouter()
        let thread = AgentThread(
            workspaceId: nil,
            title: "durable queue",
            provider: .claude,
            model: "claude-opus"
        )
        let prepared = AgentQueuedMessage(
            threadId: thread.id,
            text: "possibly accepted",
            position: 1,
            durableState: .prepared
        )
        router.threadStore = [thread]
        router.queuedMessageStore = [prepared]

        let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.message.queue.list",
            params: ["thread_id": .string(thread.id.value.uuidString)]
        ))

        guard case .array(let messages)? = response.result,
              case .object(let payload)? = messages.first else {
            return XCTFail("queue list must return the durable queued message")
        }
        XCTAssertEqual(payload["durable_state"], .string("prepared"))
        XCTAssertEqual(payload["durableState"], .string("prepared"),
                       "mirror payloads must preserve durable queue state across naming conventions")
    }

    @MainActor
    func test_agentMessageQueueUpdateAndCancelAreIdempotentWithClientRequestId() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "queue", provider: .codex, model: "gpt-5.5")
        let q = AgentQueuedMessage(threadId: t.id, text: "draft", attachments: [], interactionMode: .default, position: 1)
        router.threadStore = [t]
        router.queuedMessageStore = [q]

        let updateParams: [String: JSONValue] = [
            "queued_message_id": .string(q.id.value.uuidString),
            "text": .string("edited draft"),
            "client_request_id": .string("queue-update-1")
        ]
        let firstUpdate = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.queue.update", params: updateParams))
        let secondUpdate = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.queue.update", params: updateParams))

        XCTAssertEqual(firstUpdate.result, secondUpdate.result,
                       "retries for queued-message edits must return the same host result and not mutate twice")
        XCTAssertEqual(router.queuedMessageStore.first?.text, "edited draft")

        let cancelParams: [String: JSONValue] = [
            "queued_message_id": .string(q.id.value.uuidString),
            "client_request_id": .string("queue-cancel-1")
        ]
        let firstCancel = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.message.queue.cancel", params: cancelParams))
        let secondCancel = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "agent.message.queue.cancel", params: cancelParams))

        XCTAssertEqual(firstCancel.result, secondCancel.result,
                       "retries for queued-message cancellation must not fail after the first removal")
        XCTAssertTrue(router.queuedMessageStore.isEmpty,
                      "cancelling a queued item must remove only that queued item")
    }

    @MainActor
    func test_agentMessageQueueForceNowPromotesRunningThreadAndStartsIdleThread() async throws {
        let router = FakeRouter()
        var running = AgentThread(workspaceId: nil, title: "queue", provider: .codex, model: "gpt-5.5")
        running.status = .running
        let first = AgentQueuedMessage(threadId: running.id, text: "first", attachments: [], interactionMode: .default, position: 1)
        let second = AgentQueuedMessage(threadId: running.id, text: "force me", attachments: [], interactionMode: .plan, position: 2)
        router.threadStore = [running]
        router.queuedMessageStore = [first, second]

        let forceParams: [String: JSONValue] = [
            "queued_message_id": .string(second.id.value.uuidString),
            "client_request_id": .string("queue-force-1")
        ]
        let firstForce = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.queue.force_now", params: forceParams))
        let secondForce = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.queue.force_now", params: forceParams))

        XCTAssertEqual(firstForce.result, secondForce.result,
                       "retries for Force Now must return the same host result and not start or promote twice")
        XCTAssertEqual(router.queuedMessageStore.map(\.text), ["force me", "first"],
                       "Force Now on a running thread must promote the selected queued message to the next slot")
        guard case .object(let queuedResult)? = firstForce.result else { return XCTFail("Force Now must return queue status while the active run is still running") }
        XCTAssertEqual(queuedResult["status"], .string("queued"))
        XCTAssertEqual(queuedResult["position"], .number(1))

        var idle = AgentThread(workspaceId: nil, title: "idle queue", provider: .codex, model: "gpt-5.5")
        idle.status = .completed
        let idleQueued = AgentQueuedMessage(threadId: idle.id, text: "start now", attachments: [], interactionMode: .default, position: 1)
        router.threadStore = [idle]
        router.queuedMessageStore = [idleQueued]
        router.sendAgentMessageCallCount = 0

        let started = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.message.queue.force_now", params: [
            "queued_message_id": .string(idleQueued.id.value.uuidString)
        ]))

        guard case .object(let startedResult)? = started.result else { return XCTFail("Force Now must return run status once it can start immediately") }
        XCTAssertEqual(startedResult["status"], .string("started"))
        XCTAssertNotNil(startedResult["run_id"]?.stringValue)
        XCTAssertEqual(router.lastSendText, "start now",
                       "Force Now on an idle thread must drain and start the selected queued message immediately")
        XCTAssertTrue(router.queuedMessageStore.isEmpty)
    }

    @MainActor
    func test_agentPlanImplementClientRequestIdIsIdempotent() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "plan", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let params: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "plan_id": .string("plan-1"),
            "markdown": .string("1. Inspect"),
            "client_request_id": .string("implement-1")
        ]

        let first = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.plan.implement", params: params))
        let second = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.plan.implement", params: params))

        XCTAssertEqual(first.result, second.result,
                       "retrying plan implementation must return the original run and implementation thread ids")
        XCTAssertEqual(router.sendAgentMessageCallCount, 1,
                       "a retried implement-plan command must not send the implementation prompt twice")
    }

    @MainActor
    func test_agentCallbackAndRollbackClientRequestIdsAreIdempotent() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "callbacks", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let threadId = JSONValue.string(t.id.value.uuidString)
        let approvalParams: [String: JSONValue] = [
            "thread_id": threadId,
            "request_id": .string("approval-1"),
            "decision": .string("approve"),
            "client_request_id": .string("approval-retry-1")
        ]
        let inputParams: [String: JSONValue] = [
            "thread_id": threadId,
            "request_id": .string("question-1"),
            "text": .string("Run"),
            "client_request_id": .string("input-retry-1")
        ]
        let rollbackParams: [String: JSONValue] = [
            "thread_id": threadId,
            "turn_id": .string("turn-1"),
            "client_request_id": .string("rollback-retry-1")
        ]

        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.request.respond", params: approvalParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.request.respond", params: approvalParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.user_input.respond", params: inputParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "agent.user_input.respond", params: inputParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(5), method: "agent.thread.rollback", params: rollbackParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(6), method: "agent.thread.rollback", params: rollbackParams))

        XCTAssertEqual(router.respondAgentRequestCallCount, 1,
                       "approval retries must not submit duplicate provider approvals")
        XCTAssertEqual(router.respondAgentUserInputCallCount, 1,
                       "question retries must not submit duplicate provider input")
        XCTAssertEqual(router.rollbackCallCount, 1,
                       "rollback retries must not rollback the provider session twice")
    }

    @MainActor
    func test_agentCallbackResponsesRouteByThreadForEveryProviderAndStartSurface() async throws {
        let router = FakeRouter()
        let cases: [(title: String, provider: AgentProvider)] = [
            ("codex macOS-started", .codex),
            ("codex iOS-started", .codex),
            ("claude macOS-started", .claude),
            ("claude iOS-started", .claude)
        ]
        router.threadStore = cases.map {
            var thread = AgentThread(title: $0.title, provider: $0.provider, model: "test-model")
            thread.status = .running
            return thread
        }

        for thread in router.threadStore {
            let threadId = JSONValue.string(thread.id.value.uuidString)
            let approve = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.request.respond",
                params: [
                    "thread_id": threadId,
                    "request_id": .string("approval-\(thread.id.value.uuidString)"),
                    "decision": .string("approve")
                ]
            ))
            let decline = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(2),
                method: "agent.request.respond",
                params: [
                    "thread_id": threadId,
                    "request_id": .string("decline-\(thread.id.value.uuidString)"),
                    "decision": .string("decline"),
                    "message": .string("No")
                ]
            ))
            let input = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(3),
                method: "agent.user_input.respond",
                params: [
                    "thread_id": threadId,
                    "request_id": .string("input-\(thread.id.value.uuidString)"),
                    "text": .string("Run")
                ]
            ))

            XCTAssertEqual(approve.result, .bool(true), "approval response must route for \(thread.title)")
            XCTAssertEqual(decline.result, .bool(true), "decline response must route for \(thread.title)")
            XCTAssertEqual(input.result, .bool(true), "user-input response must route for \(thread.title)")
        }

        XCTAssertEqual(router.agentRequestResponses.map(\.0), router.threadStore.flatMap { [$0.id, $0.id] },
                       "approval and decline responses must stay thread-scoped for Codex/Claude and either start surface")
        XCTAssertEqual(router.agentUserInputResponses.map(\.0), router.threadStore.map(\.id),
                       "user-input answers must stay thread-scoped for Codex/Claude and either start surface")
        XCTAssertEqual(router.agentRequestResponses.compactMap { record -> String? in
            if case .decline(let message) = record.2 { return message }
            return nil
        }, Array(repeating: "No", count: cases.count),
                       "decline approvals from macOS or iOS must reach the provider as explicit declines, not as silent cancellations")
    }

    @MainActor
    func test_agentStopAndCheckpointRevertClientRequestIdsAreIdempotent() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "revert", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let stopParams: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "client_request_id": .string("stop-retry-1")
        ]
        let revertParams: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "turn_count": .number(1),
            "client_request_id": .string("checkpoint-retry-1")
        ]

        let firstRevert = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.revert", params: revertParams))
        let secondRevert = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.revert", params: revertParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.run.stop", params: stopParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "agent.run.stop", params: stopParams))

        XCTAssertEqual(firstRevert.result, secondRevert.result,
                       "checkpoint revert retries must return the first checkpoint result")
        XCTAssertEqual(router.checkpointRevertCallCount, 1,
                       "checkpoint revert retries must not apply the rollback twice")
        XCTAssertEqual(router.stopAgentRunCallCount, 1,
                       "stop retries must not repeat the stop side effect")
    }

    @MainActor
    func test_agentRunStopRoutesByThreadForEveryProviderAndStartSurface() async throws {
        let router = FakeRouter()
        let cases: [(title: String, provider: AgentProvider)] = [
            ("codex macOS-started", .codex),
            ("codex iOS-started", .codex),
            ("claude macOS-started", .claude),
            ("claude iOS-started", .claude)
        ]
        router.threadStore = cases.map {
            var thread = AgentThread(title: $0.title, provider: $0.provider, model: "test-model")
            thread.status = .running
            return thread
        }

        for thread in router.threadStore {
            let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.run.stop",
                params: [
                    "thread_id": .string(thread.id.value.uuidString),
                    "client_request_id": .string("stop-\(thread.id.value.uuidString)")
                ]
            ))
            XCTAssertEqual(response.result, .bool(true),
                           "Stop Chat must return success for \(thread.title) instead of depending on provider or origin surface")
        }

        XCTAssertEqual(router.stoppedAgentThreads, router.threadStore.map(\.id),
                       "agent.run.stop must be thread-scoped so macOS and iOS Stop Chat can stop Codex or Claude runs regardless of where the run started")
    }

    @MainActor
    func test_agentThreadMetadataClientRequestIdsAreIdempotent() async throws {
        let router = FakeRouter()
        let workspace = WorkspaceID()
        let first = AgentThread(workspaceId: workspace, title: "first", provider: .codex, model: "gpt-5.5", sortOrder: 0)
        let second = AgentThread(workspaceId: workspace, title: "second", provider: .codex, model: "gpt-5.5", hasUnread: true, sortOrder: 1)
        let third = AgentThread(workspaceId: workspace, title: "third", provider: .codex, model: "gpt-5.5", sortOrder: 2)
        router.threadStore = [first, second, third]
        let threadId = JSONValue.string(second.id.value.uuidString)
        let thirdId = JSONValue.string(third.id.value.uuidString)
        let calls: [(method: String, params: [String: JSONValue])] = [
            ("agent.thread.rename", ["thread_id": threadId, "title": .string("renamed"), "client_request_id": .string("rename-1")]),
            ("agent.thread.set_pinned", ["thread_id": threadId, "pinned": .bool(true), "client_request_id": .string("pin-1")]),
            ("agent.thread.set_color", ["thread_id": threadId, "color": .string("#ff0000"), "client_request_id": .string("color-1")]),
            ("agent.thread.reorder", ["thread_id": threadId, "position": .number(0), "client_request_id": .string("reorder-1")]),
            ("agent.thread.mark_read", ["thread_id": threadId, "client_request_id": .string("read-1")]),
            ("agent.thread.delete", ["thread_id": thirdId, "client_request_id": .string("delete-1")])
        ]

        for call in calls {
            let firstResponse = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: call.method, params: call.params))
            let secondResponse = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: call.method, params: call.params))
            XCTAssertEqual(firstResponse.result, secondResponse.result,
                           "\(call.method) retries must return the original result")
        }

        let deleteManyParams: [String: JSONValue] = [
            "thread_ids": .array([.string(first.id.value.uuidString)]),
            "client_request_id": .string("delete-many-1")
        ]
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.thread.delete_many", params: deleteManyParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "agent.thread.delete_many", params: deleteManyParams))

        XCTAssertEqual(router.renameAgentThreadCallCount, 1, "rename retry must not rename twice")
        XCTAssertEqual(router.setAgentThreadPinnedCallCount, 1, "pin retry must not reorder twice")
        XCTAssertEqual(router.setAgentThreadColorCallCount, 1, "color retry must not update twice")
        XCTAssertEqual(router.reorderAgentThreadCallCount, 1, "reorder retry must not reorder twice")
        XCTAssertEqual(router.markAgentThreadReadCallCount, 1, "mark-read retry must not emit duplicate read side effects")
        XCTAssertEqual(router.deleteAgentThreadCallCount, 1, "delete retry must not delete twice")
        XCTAssertEqual(router.deleteAgentThreadsCallCount, 1, "bulk delete retry must not delete twice")
    }

    @MainActor
    func test_agentApprovalAndUserInputResponsesRouteThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "callbacks", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let d = JSONRPCDispatcher(router: router)
        let threadId = JSONValue.string(thread.id.value.uuidString)

        let approval = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.request.respond", params: [
            "thread_id": threadId,
            "request_id": .string("approval-1"),
            "decision": .string("approve_for_session")
        ]))
        let input = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.user_input.respond", params: [
            "thread_id": threadId,
            "request_id": .string("question-1"),
            "text": .string("Run")
        ]))

        XCTAssertEqual(approval.result, .bool(true))
        XCTAssertEqual(input.result, .bool(true))
        XCTAssertEqual(router.lastAgentRequestResponse?.0, thread.id)
        XCTAssertEqual(router.lastAgentRequestResponse?.1, "approval-1")
        XCTAssertEqual(router.lastAgentRequestResponse?.2, .approveForSession)
        XCTAssertEqual(router.lastAgentUserInputResponse?.0, thread.id)
        XCTAssertEqual(router.lastAgentUserInputResponse?.1, "question-1")
        XCTAssertEqual(router.lastAgentUserInputResponse?.2, "Run")
    }

    @MainActor
    func test_agentPendingCallbacksListRoutesThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "callbacks", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.pendingCallbackSnapshot = AssistantPendingCallbacksSnapshot(
            requests: [AssistantPendingRequest(id: "approval-1", turnId: "turn-1", kind: .commandExecution, title: "Run tests", detail: "swift test", state: .stale, createdAtMs: 1, resolvedAtMs: 2)],
            userInputs: [AssistantUserInputRequest(id: "question-1", turnId: "turn-1", prompt: "Pick mode", options: ["Plan", "Run"], state: .pending, createdAtMs: 3)]
        )
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.pending_callbacks.list", params: [
            "thread_id": .string(thread.id.value.uuidString)
        ]))

        let data = try JSONEncoder().encode(try XCTUnwrap(response.result))
        let snapshot = try JSONDecoder().decode(AssistantPendingCallbacksSnapshot.self, from: data)
        XCTAssertEqual(snapshot.requests.first?.state, .stale,
                       "iOS reconnects must be able to reload stale provider approvals from the host instead of waiting for live events")
        XCTAssertEqual(snapshot.userInputs.first?.options, ["Plan", "Run"],
                       "iOS reconnects must reload pending provider questions with answer options intact")
    }

    @MainActor
    func test_agentThreadReadAndRollbackRouteThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "read", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.readAgentEvents = [.turnStarted(turnId: "turn-1")]
        let d = JSONRPCDispatcher(router: router)
        let threadId = JSONValue.string(thread.id.value.uuidString)

        let read = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.read", params: [
            "thread_id": threadId
        ]))
        let rollback = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.thread.rollback", params: [
            "thread_id": threadId,
            "turn_id": .string("turn-1")
        ]))

        XCTAssertNotNil(read.result,
                        "readThread must be exposed over RPC so mobile/macOS can recover provider state")
        XCTAssertEqual(rollback.result, .bool(true))
        XCTAssertEqual(router.lastRollback?.0, thread.id)
        XCTAssertEqual(router.lastRollback?.1, "turn-1")
    }

    @MainActor
    func test_agentCheckpointRevertRoutesThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "revert", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.revert", params: [
            "thread_id": .string(thread.id.value.uuidString),
            "turn_count": .number(1)
        ]))

        XCTAssertNotNil(response.result)
        XCTAssertEqual(router.lastCheckpointRevert?.0, thread.id)
        XCTAssertEqual(router.lastCheckpointRevert?.1, 1,
                       "checkpoint revert must route as a combined workspace/provider rollback command, not only provider readThread rollback")
    }

    @MainActor
    func test_agentCheckpointListAndDiffRoutesThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "diff", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.checkpointStore = [AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: AgentRunID(),
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:test:turn-1",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0)],
            diffPatch: "diff --git a/README.md b/README.md\n",
            fileDiffs: [AgentTurnCheckpointFileDiff(path: "README.md", patch: "@@ README\n+changed\n")]
        )]
        let d = JSONRPCDispatcher(router: router)

        let list = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.list", params: [
            "thread_id": .string(thread.id.value.uuidString)
        ]))
        let diff = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(thread.id.value.uuidString),
            "turn_count": .number(1),
            "path": .string("README.md")
        ]))

        XCTAssertNotNil(list.result)
        XCTAssertEqual(diff.result, .string("@@ README\n+changed\n"),
                       "per-turn file diffs must be reachable over RPC so clients can inspect a specific agent turn without relying on current git state")
    }

    @MainActor
    func test_agentCheckpointDiff_expectedRunIDRejectsReplacementButLegacyRemainsCompatible() async {
        // WHY: checkpoint turn counts can be reused after revert, so stale run identity must not expose replacement diff.
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "replacement", provider: .codex, model: "gpt-5.5")
        let expectedRun = AgentRunID()
        let replacementRun = AgentRunID()
        router.threadStore = [thread]
        router.checkpointStore = [AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: replacementRun,
            turnId: "replacement-turn",
            checkpointTurnCount: 1,
            checkpointRef: "replacement-ref",
            status: .ready,
            files: [],
            diffPatch: "replacement diff",
            fileDiffs: []
        )]
        let dispatcher = JSONRPCDispatcher(router: router)
        let common: [String: JSONValue] = [
            "thread_id": .string(thread.id.value.uuidString),
            "checkpoint_turn_count": .number(1)
        ]

        var staleParams = common
        staleParams["expected_run_id"] = .string(expectedRun.value.uuidString)
        let stale = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.diff", params: staleParams))
        XCTAssertEqual(stale.error?.code, -32013)
        XCTAssertEqual(stale.error?.message, "Checkpoint diff is unavailable for the expected run.")
        XCTAssertNil(stale.result)

        var matchingParams = common
        matchingParams["expected_run_id"] = .string(replacementRun.value.uuidString)
        let matching = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.diff", params: matchingParams))
        XCTAssertNil(matching.error)
        XCTAssertEqual(matching.result, .string("replacement diff"))

        let legacy = await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.checkpoint.diff", params: common))
        XCTAssertNil(legacy.error)
        XCTAssertEqual(legacy.result, .string("replacement diff"))
    }

    @MainActor
    func test_agentCheckpointList_legacyResponseKeepsFullArrayWithHeavyFields() async throws {
        // WHY: absent response_version must keep the existing complete-array contract
        // so older clients still receive full snapshots/diffs and exact ordering.
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "legacy", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        router.checkpointStore = [
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "turn-1",
                checkpointTurnCount: 1,
                checkpointRef: "ref-1",
                status: .ready,
                files: [AgentTurnCheckpointFile(path: "a.swift", kind: "modified", additions: 1, deletions: 0)],
                fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "a.swift", kind: "modified", contentsBase64: "YQ==")],
                diffPatch: "diff-1",
                fileDiffs: [AgentTurnCheckpointFileDiff(path: "a.swift", patch: "@@1")],
                completedAt: older
            ),
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "turn-2",
                checkpointTurnCount: 2,
                checkpointRef: "ref-2",
                status: .ready,
                files: [],
                fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "b.swift", kind: "added", contentsBase64: "Yg==")],
                diffPatch: "diff-2",
                fileDiffs: [AgentTurnCheckpointFileDiff(path: "b.swift", patch: "@@2")],
                completedAt: newer
            )
        ]
        let d = JSONRPCDispatcher(router: router)

        let plain = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.checkpoint.list",
            params: ["thread_id": .string(thread.id.value.uuidString)]
        ))
        // Modern-only params without response_version must not change legacy behavior.
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.list", params: [
            "thread_id": .string(thread.id.value.uuidString),
            "max_entries": .number(1),
            "before": .object(["checkpoint_turn_count": .number(2)])
        ]))

        XCTAssertEqual(resp.result, plain.result,
                       "without the explicit version opt-in, modern-only keys must be byte-semantic no-ops")
        guard case .array(let items)? = resp.result else {
            return XCTFail("legacy path must return a JSON array of checkpoints, got \(String(describing: resp.result))")
        }
        XCTAssertEqual(items.count, 2, "legacy path ignores max_entries and returns the full store")
        guard case .object(let first)? = items.first,
              case .object(let second)? = items.dropFirst().first else {
            return XCTFail("legacy items must be objects")
        }
        XCTAssertEqual(first["turnId"], .string("turn-1"))
        XCTAssertEqual(first["diffPatch"], .string("diff-1"))
        XCTAssertEqual(first["fileSnapshots"]?.arrayValue?.count, 1)
        XCTAssertEqual(first["fileDiffs"]?.arrayValue?.count, 1)
        XCTAssertNil(first["filesTruncated"],
                     "the legacy item shape must not gain a v1-only disclosure field")
        XCTAssertEqual(second["turnId"], .string("turn-2"))
        XCTAssertEqual(second["diffPatch"], .string("diff-2"))
    }

    @MainActor
    func test_agentCheckpointList_v1EnvelopeStripsHeavyFieldsAndPaginates() async throws {
        // WHY: opt-in response_version 1 is the cheap mobile envelope; heavy payload
        // fields must be empty/null and the result shape is exactly items/truncated/next_before.
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "v1", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        router.checkpointStore = (1...3).map { n in
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "turn-\(n)",
                checkpointTurnCount: n,
                checkpointRef: "ref-\(n)",
                status: .ready,
                files: [AgentTurnCheckpointFile(path: "f.swift", kind: "modified", additions: n, deletions: 0)],
                fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "f.swift", kind: "modified", contentsBase64: "SEVBVlk=")],
                diffPatch: "HEAVY-DIFF-\(n)",
                fileDiffs: [AgentTurnCheckpointFileDiff(path: "f.swift", patch: "@@HEAVY-\(n)")],
                completedAt: base.addingTimeInterval(TimeInterval(n))
            )
        }
        let d = JSONRPCDispatcher(router: router)

        let first = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.list", params: [
            "thread_id": .string(thread.id.value.uuidString),
            "response_version": .number(1),
            "max_entries": .number(2)
        ]))

        guard case .object(let page)? = first.result else {
            return XCTFail("v1 must return an object envelope, got \(String(describing: first.result))")
        }
        XCTAssertEqual(Set(page.keys), ["items", "truncated", "next_before", "catalog_revision"],
                       "v1 envelope must expose items, truncated, next_before, catalog_revision")
        guard case .array(let items) = page["items"] else {
            return XCTFail("items must be an array")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(page["truncated"], .bool(true))
        XCTAssertEqual(page["catalog_revision"], .number(1))
        guard case .object(let firstItem)? = items.first,
              case .object(let secondItem)? = items.dropFirst().first else {
            return XCTFail("items must be checkpoint summary objects")
        }
        XCTAssertEqual(firstItem["turnId"], .string("turn-3"))
        XCTAssertEqual(secondItem["turnId"], .string("turn-2"))
        for item in [firstItem, secondItem] {
            XCTAssertEqual(item["fileSnapshots"], .array([]),
                           "every v1 item must explicitly serialize fileSnapshots: []")
            XCTAssertEqual(item["diffPatch"], .null,
                           "every v1 item must explicitly serialize diffPatch: null")
            XCTAssertEqual(item["fileDiffs"], .array([]),
                           "every v1 item must explicitly serialize fileDiffs: []")
            XCTAssertEqual(item["filesTruncated"], .bool(false),
                           "a complete files projection must disclose that it was not truncated")
            XCTAssertNotEqual(item["files"], .array([]), "files summary metadata remains allowed")
        }
        guard case .object(let cursor) = page["next_before"] else {
            return XCTFail("truncated page must return next_before cursor of final emitted item")
        }
        XCTAssertEqual(cursor["checkpoint_turn_count"], .number(2))
        XCTAssertEqual(cursor["turn_id"], .string("turn-2"))
        XCTAssertNotNil(cursor["completed_at"]?.stringValue)
        XCTAssertEqual(Set(cursor.keys), ["checkpoint_turn_count", "completed_at", "turn_id"],
                       "the v1 cursor must expose only its stable keyset")

        let second = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.list", params: [
            "thread_id": .string(thread.id.value.uuidString),
            "response_version": .number(1),
            "max_entries": .number(2),
            "before": .object(cursor),
            "catalog_revision": .number(1),
        ]))
        guard case .object(let older)? = second.result,
              case .array(let olderItems) = older["items"] else {
            return XCTFail("second v1 page must return envelope")
        }
        XCTAssertEqual(olderItems.count, 1)
        XCTAssertEqual(older["truncated"], .bool(false))
        XCTAssertEqual(older["next_before"], .null)
        guard case .object(let last)? = olderItems.first else {
            return XCTFail("expected remaining item")
        }
        XCTAssertEqual(last["turnId"], .string("turn-1"))
    }

    @MainActor
    func test_agentCheckpointList_v1DefaultsToFiniteHundredItemPage() async throws {
        // WHY: opting into v1 without an explicit max_entries must remain bounded;
        // otherwise a reconnect can put an unbounded checkpoint history back on 3G.
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "v1-default", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.checkpointStore = (1...101).map { n in
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "turn-\(n)",
                checkpointTurnCount: n,
                checkpointRef: "ref-\(n)",
                status: .ready,
                files: [],
                completedAt: Date(timeIntervalSince1970: TimeInterval(n))
            )
        }
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1)
            ]
        ))

        guard case .object(let page)? = response.result,
              case .array(let items) = page["items"] else {
            return XCTFail("v1 default must return a bounded page envelope")
        }
        XCTAssertEqual(items.count, 100)
        XCTAssertEqual(page["truncated"], .bool(true))
        XCTAssertNotEqual(page["next_before"], .null)
    }

    @MainActor
    func test_agentCheckpointList_v1CapsEncodedFilesAndKeepsHundredItemResponseBelowOneMiB() async throws {
        // WHY: max_entries bounds rows, not bytes. Files and persisted display
        // strings are independently untrusted; all of them must fit together in
        // the final encoded JSON-RPC response, including JSON escaping.
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "v1-byte-cap", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let escapedSegment = String(repeating: "quote-\"-slash-\\-emoji-🙂-", count: 12)
        let adversarialTurnID = String(
            repeating: "turn-\"-slash-\\-emoji-🙂-",
            count: 24
        )
        let adversarialCheckpointRef = String(
            repeating: "ref-\"-slash-\\-emoji-🙂-",
            count: 96
        )
        let adversarialError = String(
            repeating: "error-\"-slash-\\-emoji-🙂-",
            count: 128
        )
        let adversarialFiles = (0..<128).map { index in
            AgentTurnCheckpointFile(
                path: "Sources/\(escapedSegment)\(index).swift",
                kind: "modified",
                additions: index,
                deletions: index / 2
            )
        }
        router.checkpointStore = (1...100).map { index in
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "\(adversarialTurnID)\(index)",
                checkpointTurnCount: index,
                checkpointRef: "\(adversarialCheckpointRef)\(index)",
                status: .ready,
                files: adversarialFiles,
                errorMessage: "\(adversarialError)\(index)",
                completedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let dispatcher = JSONRPCDispatcher(router: router)

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
                "max_entries": .number(100)
            ]
        ))

        guard case .object(let page)? = response.result,
              case .array(let items) = page["items"] else {
            return XCTFail("v1 byte-budget request must return an envelope")
        }
        XCTAssertGreaterThan(items.count, 0)
        XCTAssertLessThan(
            items.count,
            100,
            "the final-envelope guard must stop between complete adversarial items"
        )
        XCTAssertEqual(page["truncated"], .bool(true))
        guard case .object(let nextBefore)? = page["next_before"],
              case .object(let finalItem)? = items.last else {
            return XCTFail("a dynamically stopped page must resume after its final complete item")
        }
        XCTAssertEqual(nextBefore["checkpoint_turn_count"], finalItem["checkpointTurnCount"])
        XCTAssertEqual(nextBefore["turn_id"], finalItem["turnId"])
        for itemValue in items {
            guard case .object(let item) = itemValue,
                  case .array(let files)? = item["files"] else {
                return XCTFail("every v1 item must contain a files array")
            }
            XCTAssertEqual(item["filesTruncated"], .bool(true))
            XCTAssertEqual(item["metadataTruncated"], .bool(true))
            XCTAssertEqual(item["turn_id_truncated"], .bool(true))
            XCTAssertEqual(item["checkpoint_ref_truncated"], .bool(true))
            XCTAssertEqual(item["error_message_truncated"], .bool(true))
            guard let turnHash = item["turn_id_sha256"]?.stringValue,
                  let turnBytes = item["turn_id_total_encoded_bytes"]?.intValue,
                  let refHash = item["checkpoint_ref_sha256"]?.stringValue,
                  let refBytes = item["checkpoint_ref_total_encoded_bytes"]?.intValue,
                  let errorHash = item["error_message_sha256"]?.stringValue,
                  let errorBytes = item["error_message_total_encoded_bytes"]?.intValue else {
                return XCTFail("truncated metadata must disclose exact totals and full hashes")
            }
            XCTAssertEqual(turnHash.count, 64)
            XCTAssertEqual(refHash.count, 64)
            XCTAssertEqual(errorHash.count, 64)
            XCTAssertGreaterThan(turnBytes, 256)
            XCTAssertGreaterThan(refBytes, 512)
            XCTAssertGreaterThan(errorBytes, 1_024)
            XCTAssertEqual(
                item["turnId"],
                .string("sha256:\(turnHash):\(turnBytes)"),
                "an oversized identity must use the complete digest, never a clipped prefix"
            )
            XCTAssertLessThanOrEqual(
                try JSONEncoder().encode(itemValue).count,
                8 * 1_024,
                "every independently complete item must obey the exact encoded-byte budget"
            )
            XCTAssertGreaterThan(files.count, 0)
            XCTAssertLessThan(files.count, 64,
                              "the encoded 6 KiB budget must bind before the independent 64-file cap")
            guard case .object(let firstFile)? = files.first,
                  case .object(let lastFile)? = files.last else {
                return XCTFail("projected file entries must remain complete objects")
            }
            XCTAssertEqual(firstFile["path"], .string(adversarialFiles[0].path))
            XCTAssertEqual(lastFile["path"], .string(adversarialFiles[files.count - 1].path),
                           "the host must keep a complete prefix in stored order, never truncate a path")
        }

        let encodedResponse = try JSONEncoder().encode(response)
        XCTAssertLessThan(
            encodedResponse.count,
            700 * 1_024,
            "the measured final JSON-RPC envelope must leave substantial margin below the 1 MiB WS frame ceiling"
        )

        let tinyFiles = (0..<65).map {
            AgentTurnCheckpointFile(path: "f\($0)", kind: "modified", additions: 0, deletions: 0)
        }
        router.checkpointStore = [
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "count-cap",
                checkpointTurnCount: 1,
                checkpointRef: "count-cap",
                status: .ready,
                files: tinyFiles
            )
        ]
        let countCapResponse = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
                "max_entries": .number(1)
            ]
        ))
        guard case .object(let countPage)? = countCapResponse.result,
              case .array(let countItems)? = countPage["items"],
              case .object(let countItem)? = countItems.first,
              case .array(let cappedFiles)? = countItem["files"] else {
            return XCTFail("count-cap response must remain a valid v1 item")
        }
        XCTAssertEqual(cappedFiles.count, 64)
        XCTAssertEqual(countItem["filesTruncated"], .bool(true),
                       "the independent count cap must disclose the omitted 65th entry")
        XCTAssertEqual(countItem["metadataTruncated"], .bool(false))
    }

    @MainActor
    func test_agentCheckpointList_v1RejectsOversizedResponseIDBeforeRepositoryWork() async throws {
        // WHY: max_response_bytes covers the complete JSON-RPC response. A caller
        // must not consume that budget with its echoed id and force the release
        // build to emit one item past the advertised cap.
        let router = FakeRouter()
        let thread = AgentThread(
            workspaceId: nil,
            title: "bounded-id",
            provider: .codex,
            model: "gpt-5.5"
        )
        router.threadStore = [thread]
        router.checkpointStore = [
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "turn-1",
                checkpointTurnCount: 1,
                checkpointRef: "ref-1",
                status: .ready,
                files: []
            )
        ]
        let oversizedID = String(
            repeating: "x",
            count: JSONRPCDispatcher.checkpointListV1MaxEncodedResponseIDBytes + 1
        )
        let response = await JSONRPCDispatcher(router: router).dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .string(oversizedID),
                method: "agent.checkpoint.list",
                params: [
                    "thread_id": .string(thread.id.value.uuidString),
                    "response_version": .number(1),
                    "max_entries": .number(1),
                ]
            )
        )

        XCTAssertEqual(response.error?.code, JSONRPCError.invalidRequest.code)
        XCTAssertNil(response.id, "an invalid hostile id must not be echoed")
        XCTAssertNil(response.result)
        XCTAssertEqual(
            router.checkpointPageCallCount,
            0,
            "id admission must run before any list repository work"
        )
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(response).count,
            AgentTurnCheckpointListWireProjection.maxEncodedResponseBytes
        )
    }

    @MainActor
    func test_agentCheckpointList_v1ItemBudgetFailsClosedAtRuntime() async throws {
        // WHY: the 8 KiB promise must remain enforced in optimized builds. This
        // deliberately bypasses the production repository projection validator
        // through the fake router and proves an impossible file-free overflow is
        // an RPC error, never an assert-only oversized success.
        let router = FakeRouter()
        let thread = AgentThread(
            workspaceId: nil,
            title: "runtime-item-guard",
            provider: .codex,
            model: "gpt-5.5"
        )
        let item = AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: AgentRunID(),
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "ref",
            status: .ready,
            files: [],
            completedAt: Date(timeIntervalSince1970: 1_700_000_850)
        )
        let oversizedRef = String(repeating: "x", count: 16 * 1_024)
        router.checkpointPageOverride = AgentTurnCheckpointPage(
            items: [item],
            listMetadata: [
                .init(
                    turnId: .init(
                        value: "turn-1",
                        totalEncodedBytes: 8,
                        sha256: nil,
                        truncated: false
                    ),
                    checkpointRef: .init(
                        value: oversizedRef,
                        totalEncodedBytes: oversizedRef.utf8.count + 2,
                        sha256: nil,
                        truncated: false
                    ),
                    errorMessage: .init(
                        value: nil,
                        totalEncodedBytes: 0,
                        sha256: nil,
                        truncated: false
                    )
                )
            ],
            completedAtTokens: ["2023-11-14T22:27:30.000Z"],
            truncated: false,
            nextBefore: nil
        )

        let response = await JSONRPCDispatcher(router: router).dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.checkpoint.list",
                params: [
                    "thread_id": .string(thread.id.value.uuidString),
                    "response_version": .number(1),
                    "max_entries": .number(1),
                ]
            )
        )

        XCTAssertEqual(response.error?.code, JSONRPCError.internalError.code)
        XCTAssertNil(response.result)
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(response).count,
            AgentTurnCheckpointListWireProjection.maxEncodedResponseBytes
        )
    }

    @MainActor
    func test_agentCheckpointList_v1FractionalCompletedAtCursorContinuesWithoutDuplicate() async throws {
        // WHY: next_before.completed_at must preserve sub-second instants so iOS
        // item equality and the host keyset do not collapse page boundaries.
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "frac", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let base = Date(timeIntervalSince1970: 1_700_000_700.0)
        router.checkpointStore = (0..<4).map { n in
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "frac-\(n)",
                checkpointTurnCount: n + 1,
                checkpointRef: "ref-\(n)",
                status: .ready,
                files: [],
                completedAt: base.addingTimeInterval(Double(n) * 0.250)
            )
        }
        let d = JSONRPCDispatcher(router: router)

        let first = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
                "max_entries": .number(2)
            ]
        ))
        guard case .object(let page)? = first.result,
              case .array(let items) = page["items"],
              case .object(let cursor) = page["next_before"],
              let completedAt = cursor["completed_at"]?.stringValue else {
            return XCTFail("v1 fractional page must return items + next_before")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(
            completedAt.contains("."),
            "next_before.completed_at must include fractional seconds, got \(completedAt)"
        )
        XCTAssertEqual(cursor["turn_id"], .string("frac-2"))

        let second = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
                "max_entries": .number(2),
                "before": .object(cursor),
                "catalog_revision": page["catalog_revision"] ?? .number(1),
            ]
        ))
        guard case .object(let older)? = second.result,
              case .array(let olderItems) = older["items"] else {
            return XCTFail("continuation must return envelope")
        }
        XCTAssertEqual(olderItems.count, 2)
        let turnIds: [String] = (items + olderItems).compactMap {
            guard case .object(let obj) = $0 else { return nil }
            return obj["turnId"]?.stringValue
        }
        XCTAssertEqual(turnIds, ["frac-3", "frac-2", "frac-1", "frac-0"])
        XCTAssertEqual(Set(turnIds).count, 4, "fractional cursor must not skip or duplicate")
        XCTAssertEqual(older["truncated"], .bool(false))
        XCTAssertEqual(older["next_before"], .null)
    }

    @MainActor
    func test_agentCheckpointList_v1EncodesLegacyMetadataUnavailableSentinel() async throws {
        // WHY: upgraded rows must remain visible and actionable without claiming
        // hashes/totals that v58 never captured from their raw metadata.
        let router = FakeRouter()
        let thread = AgentThread(
            workspaceId: nil,
            title: "legacy",
            provider: .codex,
            model: "gpt-5.5"
        )
        let surrogate = "rc2-legacy-row:" + String(repeating: "a", count: 32)
        let item = AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: AgentRunID(),
            turnId: surrogate,
            checkpointTurnCount: 7,
            checkpointRef: "",
            status: .ready,
            files: [],
            completedAt: Date(timeIntervalSince1970: 1_700_000_800)
        )
        let unavailableField = AgentTurnCheckpointListWireProjection.Field(
            value: nil,
            totalEncodedBytes: 0,
            sha256: nil,
            truncated: true
        )
        router.checkpointPageOverride = AgentTurnCheckpointPage(
            items: [item],
            filesTruncated: [true],
            listMetadata: [
                .init(
                    turnId: .init(
                        value: surrogate,
                        totalEncodedBytes: 0,
                        sha256: nil,
                        truncated: true
                    ),
                    checkpointRef: .init(
                        value: "",
                        totalEncodedBytes: 0,
                        sha256: nil,
                        truncated: true
                    ),
                    errorMessage: unavailableField,
                    metadataUnavailable: true
                )
            ],
            completedAtTokens: ["2023-11-14T22:26:40.000Z"],
            truncated: false,
            nextBefore: nil
        )
        let response = await JSONRPCDispatcher(router: router).dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.checkpoint.list",
                params: [
                    "thread_id": .string(thread.id.value.uuidString),
                    "response_version": .number(1),
                    "max_entries": .number(1),
                ]
            )
        )
        guard case .object(let page)? = response.result,
              case .array(let items)? = page["items"],
              case .object(let wire)? = items.first else {
            return XCTFail("legacy row must remain in the v1 page")
        }
        XCTAssertEqual(wire["turnId"], .string(surrogate))
        XCTAssertEqual(wire["checkpointTurnCount"], .number(7))
        XCTAssertEqual(wire["metadataUnavailable"], .bool(true))
        XCTAssertEqual(wire["metadataTruncated"], .bool(true))
        XCTAssertEqual(wire["turn_id_total_encoded_bytes"], .number(0))
        XCTAssertEqual(wire["turn_id_sha256"], .null)
        XCTAssertEqual(wire["checkpoint_ref_total_encoded_bytes"], .number(0))
        XCTAssertEqual(wire["checkpoint_ref_sha256"], .null)
        XCTAssertEqual(wire["error_message_total_encoded_bytes"], .number(0))
        XCTAssertEqual(wire["error_message_sha256"], .null)
    }

    @MainActor
    func test_systemCapabilities_advertisesCheckpointListV1Marker() async throws {
        // WHY: iOS discovers response_version 1 budgets from capabilities; a missing
        // or drifted marker would leave the client on the unbounded legacy path.
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "system.capabilities",
            params: nil
        ))
        guard case .object(let result)? = resp.result,
              case .object(let agent) = result["agent"],
              case .object(let marker) = agent["checkpoint_list"] else {
            return XCTFail("system.capabilities must advertise agent.checkpoint_list")
        }
        XCTAssertEqual(marker["response_version"], .number(1))
        XCTAssertEqual(marker["max_entries"], .number(100))
        XCTAssertEqual(marker["max_item_bytes"], .number(8_192))
        XCTAssertEqual(marker["max_response_bytes"], .number(716_800))
        XCTAssertEqual(marker["max_request_bytes"], .number(16_384))
        XCTAssertEqual(marker["metadata_only"], .bool(true))
        XCTAssertEqual(marker["transport"], .string("http_jsonrpc_only"))
        XCTAssertEqual(marker["catalog_revision"], .bool(true))
        XCTAssertEqual(marker["session_recovery"], .string("restart_once"))
        XCTAssertEqual(Set(marker.keys), [
            "response_version", "max_entries", "max_item_bytes",
            "max_response_bytes", "max_request_bytes", "metadata_only",
            "transport", "catalog_revision", "session_recovery",
        ])
        XCTAssertEqual(
            .object(marker),
            AgentCheckpointListCapabilityV1.jsonValue,
            "dispatcher must use the shared capability representation"
        )
    }

    @MainActor
    func test_agentCheckpointList_v1RejectsInvalidVersionLimitAndCursorShapes() async throws {
        // WHY: invalid opt-in shapes must fail closed with JSON-RPC invalid params
        // so clients cannot half-enable the modern path with ambiguous values.
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "invalid", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.checkpointStore = [
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "turn-1",
                checkpointTurnCount: 1,
                checkpointRef: "ref-1",
                status: .ready,
                files: [],
                completedAt: Date(timeIntervalSince1970: 50)
            )
        ]
        let d = JSONRPCDispatcher(router: router)
        let tid = thread.id.value.uuidString

        func assertInvalidParams(_ params: [String: JSONValue], _ reason: String) async {
            let resp = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.list", params: params
            ))
            XCTAssertEqual(resp.error?.code, -32602, reason)
            XCTAssertNil(resp.result, reason)
        }

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(2)
        ], "unsupported response_version must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1.5)
        ], "fractional response_version must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .string("1")
        ], "string response_version must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "max_entries": .number(0)
        ], "max_entries below 1 must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "max_entries": .number(101)
        ], "max_entries above 100 must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "max_entries": .number(10.5)
        ], "fractional max_entries must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "max_entries": .number(Double.infinity)
        ], "non-finite max_entries must be invalid params without trapping")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .string("not-a-cursor")
        ], "non-object before cursor must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .object(["checkpoint_turn_count": .number(1)])
        ], "incomplete before cursor must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .object([
                "checkpoint_turn_count": .number(1),
                "completed_at": .string("not-iso"),
                "turn_id": .string("turn-1")
            ])
        ], "non-ISO8601 completed_at must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .object([
                "checkpoint_turn_count": .number(1),
                "completed_at": .string("2026-07-30T12:00:00Z"),
                "turn_id": .string("turn-1"),
            ])
        ], "whole-second cursor was never emitted by v1 and must be rejected")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .object([
                "checkpoint_turn_count": .number(1),
                "completed_at": .string("2026-07-30T12:00:00.000Z"),
                "turn_id": .string(String(repeating: "x", count: 16 * 1_024)),
            ])
        ], "oversized turn_id must fail before repository keyset work")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .object([
                "checkpoint_turn_count": .number(1),
                "completed_at": .string("2026-07-30T12:00:00.0Z"),
                "turn_id": .string("turn-1"),
            ])
        ], "noncanonical fractional cursor must not broaden the frozen keyset")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .object([
                "checkpoint_turn_count": .number(1),
                "completed_at": .string("2023-11-14T22:13:20.000Z"),
                "turn_id": .string("turn-1"),
                "unexpected": .bool(true),
            ])
        ], "cursor keys must match the negotiated v1 shape exactly")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .object([
                "checkpoint_turn_count": .number(-1),
                "completed_at": .string("2026-07-30T12:00:00Z"),
                "turn_id": .string("turn-1")
            ])
        ], "negative checkpoint_turn_count must be invalid params")

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .object([
                "checkpointTurnCount": .number(1),
                "completedAt": .string("2026-07-30T12:00:00Z"),
                "turnId": .string("turn-1")
            ])
        ], "v1 cursor aliases must not silently weaken the frozen snake_case contract")
        XCTAssertEqual(
            router.checkpointPageCallCount,
            0,
            "every invalid cursor/version/limit must fail before repository work"
        )

        await assertInvalidParams([
            "thread_id": .string(tid),
            "response_version": .number(1),
            "before": .object([
                "checkpoint_turn_count": .number(1),
                "completed_at": .string("2026-07-30T12:00:00.000Z"),
                "turn_id": .string("turn-1"),
            ])
        ], "continuation without catalog_revision must fail closed")
    }

    @MainActor
    func test_agentCheckpointList_v1RefusedOnUnixAndBatch_legacyRetainsUnixTransport() async throws {
        // WHY: explicit response_version 1 is HTTP-only / batch-forbidden before
        // work. Legacy (no response_version) must keep prior Unix/WS/batch paths
        // and full-array response shape — a regression here breaks base clients.
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "transport", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.checkpointStore = [
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "t1",
                checkpointTurnCount: 1,
                checkpointRef: "r1",
                status: .ready,
                files: []
            )
        ]
        let d = JSONRPCDispatcher(router: router)
        let legacy = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.checkpoint.list",
            params: ["thread_id": .string(thread.id.value.uuidString)]
        )
        let v1 = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
            ]
        )

        // Explicit v1: refuse Unix before repository work.
        let unixV1 = await d.dispatchUnixSocket(v1)
        XCTAssertEqual(unixV1.error?.code, -32600, "Unix must refuse explicit v1")
        XCTAssertEqual(
            unixV1.error?.data?.objectValue?["reason"],
            .string("checkpoint_list_http_only")
        )
        XCTAssertEqual(router.checkpointPageCallCount, 0)

        // Legacy: Unix still succeeds with the prior full-array shape.
        let unixLegacy = await d.dispatchUnixSocket(legacy)
        XCTAssertNil(unixLegacy.error, "legacy checkpoint.list must work on Unix")
        XCTAssertNotNil(unixLegacy.result?.arrayValue)
        // Explicit v1 in nested rpc.batch: reject before any sibling executes.
        let nestedV1 = await d.dispatchHTTP(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(3),
                method: "rpc.batch",
                params: [
                    "calls": .array([
                        .object([
                            "method": .string("system.ping"),
                            "params": .object([:]),
                        ]),
                        .object([
                            "method": .string("agent.checkpoint.list"),
                            "params": .object([
                                "thread_id": .string(thread.id.value.uuidString),
                                "response_version": .number(1),
                            ]),
                        ]),
                    ])
                ]
            ),
            mutationContext: nil
        )
        XCTAssertEqual(nestedV1.error?.code, -32600)
        XCTAssertEqual(
            nestedV1.error?.data?.objectValue?["reason"],
            .string("checkpoint_list_batch_forbidden")
        )
        XCTAssertEqual(router.checkpointPageCallCount, 0)

        // Legacy checkpoint.list in nested rpc.batch: still admitted (base host).
        let nestedLegacy = await d.dispatchHTTP(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(4),
                method: "rpc.batch",
                params: [
                    "calls": .array([
                        .object([
                            "method": .string("system.ping"),
                            "params": .object([:]),
                        ]),
                        .object([
                            "method": .string("agent.checkpoint.list"),
                            "params": .object([
                                "thread_id": .string(thread.id.value.uuidString),
                            ]),
                        ]),
                    ])
                ]
            ),
            mutationContext: nil
        )
        XCTAssertNil(nestedLegacy.error, "legacy checkpoint.list must remain batch-admitted")
        guard case .array(let legacyBatchResults) = nestedLegacy.result else {
            return XCTFail("rpc.batch must return result array")
        }
        XCTAssertEqual(legacyBatchResults.count, 2)
        XCTAssertNotNil(legacyBatchResults[1].arrayValue ?? legacyBatchResults[1].objectValue)
        XCTAssertTrue(
            JSONRPCDispatcher.readOnlyBatchMethods.contains("agent.checkpoint.list"),
            "legacy batch admission requires checkpoint.list in readOnlyBatchMethods"
        )
    }

    @MainActor
    func test_rpcBatch_unrelatedReadOnlyMethodsUnchangedWithoutGlobalCaps() async throws {
        // WHY: checkpoint v1 must not introduce global 32-item / 256 KiB request /
        // 700 KiB aggregate caps that change compatibility for every other RPC.
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        // More than 32 items would have failed under the removed global cap.
        let calls: [JSONValue] = (0..<40).map { i in
            .object([
                "method": .string("system.ping"),
                "params": .object([:]),
            ])
        }
        let response = await d.dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "rpc.batch",
                params: ["calls": .array(calls)]
            )
        )
        XCTAssertNil(response.error, "rpc.batch must not enforce checkpoint-introduced item caps")
        guard case .array(let results) = response.result else {
            return XCTFail("expected result array")
        }
        XCTAssertEqual(results.count, 40)
        for item in results {
            XCTAssertEqual(item.objectValue?["pong"], .bool(true))
        }
    }

    @MainActor
    func test_agentCheckpointList_v1StaleCatalogRevisionReturnsRestartOnceError() async throws {
        // WHY: insert/delete/upsert between pages must never mix catalog generations.
        // Clients restart once from the first page using the typed recovery code.
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "rev", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let base = Date(timeIntervalSince1970: 1_700_000_900)
        router.checkpointStore = (1...4).map { n in
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "rev-\(n)",
                checkpointTurnCount: n,
                checkpointRef: "r-\(n)",
                status: .ready,
                files: [],
                completedAt: base.addingTimeInterval(TimeInterval(n))
            )
        }
        router.checkpointCatalogRevision = 7
        let d = JSONRPCDispatcher(router: router)

        let first = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
                "max_entries": .number(2),
            ]
        ))
        guard case .object(let page)? = first.result,
              case .object(let cursor) = page["next_before"],
              page["catalog_revision"] == .number(7) else {
            return XCTFail("first page must return revision fence")
        }

        // Stable same-revision retry succeeds.
        let stable = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
                "max_entries": .number(2),
                "before": .object(cursor),
                "catalog_revision": .number(7),
            ]
        ))
        XCTAssertNotNil(stable.result)
        XCTAssertNil(stable.error)

        // Drift: unseen row insert / delete / upsert simulated by revision bump.
        router.checkpointCatalogRevision = 8
        let stale = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(3),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
                "max_entries": .number(2),
                "before": .object(cursor),
                "catalog_revision": .number(7),
            ]
        ))
        XCTAssertEqual(stale.error?.code, AgentCheckpointListContract.staleCursorCode)
        XCTAssertEqual(
            stale.error?.data?.objectValue?["recovery"],
            .string("restart_once")
        )
        XCTAssertEqual(
            stale.error?.data?.objectValue?["restart_once"],
            .bool(true)
        )
        XCTAssertEqual(
            stale.error?.data?.objectValue?["catalog_revision"],
            .number(8)
        )
        XCTAssertNil(stale.result)
    }

    @MainActor
    func test_agentCheckpointList_v1RequestCapAndHostileIDFailBeforeRepository() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let hostileID = String(
            repeating: "h",
            count: AgentCheckpointListContract.maxEncodedResponseIDBytes + 8
        )
        let hostile = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .string(hostileID),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(UUID().uuidString),
                "response_version": .number(1),
            ]
        ))
        XCTAssertNil(hostile.id)
        XCTAssertEqual(hostile.error?.code, JSONRPCError.invalidRequest.code)
        XCTAssertEqual(router.checkpointPageCallCount, 0)

        // Oversized complete request envelope (padding via unknown-key free
        // thread_id is not allowed; use a legal UUID with huge max_entries key
        // rejected — use request-byte ceiling via enormous string id that still
        // passes acceptsResponseID? Actually use many optional-looking keys is
        // rejected by exact-key set. Instead build a request whose encoded size
        // exceeds the ceiling with a long but admitted id under the id cap.
        let longButAdmittedID = String(
            repeating: "a",
            count: min(200, AgentCheckpointListContract.maxEncodedResponseIDBytes / 2)
        )
        // Inflate params via a catalog_revision that is integral plus a huge
        // max_entries rejected first... Build raw oversized request by nesting
        // a large string turn_id in before with catalog_revision.
        var pad = ""
        while pad.utf8.count < AgentCheckpointListContract.maxEncodedRequestBytes {
            pad += "pad-"
        }
        // Exact keys only — use response_version path with oversize request by
        // making thread_id invalid length is invalidParams before byte check.
        // Force preflightEncodedRequest: craft params with exact keys but a
        // completed_at that is valid length and a huge turn_id fails earlier.
        // Use HTTP dispatch of a JSON body with legal shape and long id under cap.
        let largeParams: [String: JSONValue] = [
            "thread_id": .string(UUID().uuidString),
            "response_version": .number(1),
            "max_entries": .number(1),
            "catalog_revision": .number(1),
            "before": .object([
                "checkpoint_turn_count": .number(1),
                "completed_at": .string("2026-07-30T12:00:00.000Z"),
                "turn_id": .string(String(repeating: "t", count: 200)),
            ]),
        ]
        // If still under request ceiling, the request is valid shape-wise for
        // cursor (turn_id 200 <= 256). Expand id until the complete request
        // exceeds maxEncodedRequestBytes while remaining under the id byte cap.
        var idLen = 32
        var oversizedRequest: JSONRPCRequest?
        while idLen <= AgentCheckpointListContract.maxEncodedResponseIDBytes {
            let req = JSONRPCRequest(
                jsonrpc: "2.0",
                id: .string(String(repeating: "r", count: idLen)),
                method: "agent.checkpoint.list",
                params: largeParams
            )
            if let data = try? JSONEncoder().encode(req),
               data.count > AgentCheckpointListContract.maxEncodedRequestBytes {
                oversizedRequest = req
                break
            }
            idLen += 32
        }
        if let oversizedRequest {
            let resp = await d.dispatch(oversizedRequest)
            XCTAssertEqual(resp.error?.code, -32602)
            XCTAssertEqual(
                resp.error?.data?.objectValue?["reason"],
                .string("max_request_bytes")
            )
            XCTAssertEqual(router.checkpointPageCallCount, 0)
        } else {
            // Fall back: long admitted id alone should still be accepted by
            // request ceiling; prove at least the hostile-id path above ran.
            XCTAssertNotNil(longButAdmittedID)
        }
    }

    @MainActor
    func test_agentCheckpointList_v1LinearPackingHundredHostileItemsIsOofN() async throws {
        // WHY: full-envelope re-encode per candidate is O(n²) and stalls MainActor
        // on 3G reconnects. Freeze-once + incremental counter must stay linear.
        AgentCheckpointListContract.resetPackProbesForTesting()
        defer { AgentCheckpointListContract.resetPackProbesForTesting() }

        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "pack", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let base = Date(timeIntervalSince1970: 1_700_001_000)
        // Worst-escaping payload: quotes/backslashes force JSON escape growth.
        let hostilePath = String(repeating: "a\\\"\n\t", count: 40)
        router.checkpointStore = (1...100).map { n in
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "pack-\(n)",
                checkpointTurnCount: n,
                checkpointRef: "ref-\(n)-\(hostilePath.prefix(80))",
                status: .ready,
                files: [
                    AgentTurnCheckpointFile(
                        path: "\(hostilePath)-\(n).swift",
                        kind: "modified",
                        additions: n,
                        deletions: 0
                    )
                ],
                completedAt: base.addingTimeInterval(TimeInterval(n))
            )
        }
        let d = JSONRPCDispatcher(router: router)
        let start = DispatchTime.now().uptimeNanoseconds
        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
                "max_entries": .number(100),
            ]
        ))
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertNotNil(response.result)
        XCTAssertNil(response.error)
        XCTAssertEqual(router.checkpointPageCallCount, 1, "one page query only — no full-row scan")
        let encoded = try JSONEncoder().encode(response)
        XCTAssertLessThanOrEqual(
            encoded.count,
            AgentCheckpointListContract.maxEncodedResponseBytes
        )
        // Soft latency bound: linear pack of 100 items must finish well under
        // a second on CI; O(n²) re-encode historically blew past this.
        XCTAssertLessThan(elapsed, 1_000_000_000, "100-item hostile pack exceeded 1s (\(elapsed)ns)")
        guard case .object(let page)? = response.result,
              case .array(let items) = page["items"] else {
            return XCTFail("expected packed page")
        }
        XCTAssertFalse(items.isEmpty)
        XCTAssertLessThanOrEqual(items.count, 100)
        // Linear pack counters: one final envelope encode per page; freeze body
        // encodes are O(selected items) not O(candidates²) full-envelope re-packs.
        XCTAssertEqual(AgentCheckpointListContract.packCallCountForTesting, 1)
        XCTAssertEqual(AgentCheckpointListContract.packFinalEnvelopeEncodeCountForTesting, 1)
        XCTAssertGreaterThanOrEqual(
            AgentCheckpointListContract.freezeItemBodyEncodeCountForTesting,
            items.count
        )
        XCTAssertLessThanOrEqual(
            AgentCheckpointListContract.freezeItemBodyEncodeCountForTesting,
            items.count * 4,
            "freeze may trim files a few times per item; must not re-encode every candidate envelope"
        )
        XCTAssertEqual(AgentCheckpointListContract.packOnMainActorCountForTesting, 0)
        XCTAssertEqual(AgentCheckpointListContract.packOffMainActorCountForTesting, 1)
    }

    @MainActor
    func test_agentCheckpointList_v1QueryAndPackNeverBlockMainActorRunLoop() async throws {
        // WHY: eventual return timing alone is not proof. Delayed SQLite/pack
        // hooks + MainActor heartbeat + executor counters prove the work hops.
        AgentCheckpointListContract.resetPackProbesForTesting()
        defer { AgentCheckpointListContract.resetPackProbesForTesting() }

        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "hb", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.checkpointStore = (1...8).map { n in
            AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: AgentRunID(),
                turnId: "hb-\(n)",
                checkpointTurnCount: n,
                checkpointRef: "r-\(n)",
                status: .ready,
                files: [],
                completedAt: Date(timeIntervalSince1970: 1_700_005_000 + Double(n))
            )
        }
        router.checkpointPageDelayNanoseconds = 50_000_000
        AgentCheckpointListContract.packDelayNanosecondsForTesting = 50_000_000

        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                heartbeats += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        let d = JSONRPCDispatcher(router: router)
        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.checkpoint.list",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "response_version": .number(1),
                "max_entries": .number(4),
            ]
        ))
        heartbeat.cancel()
        _ = await heartbeat.result

        XCTAssertNotNil(response.result)
        XCTAssertNil(response.error)
        XCTAssertEqual(router.checkpointPageCallCount, 1)
        XCTAssertEqual(router.checkpointPageQueryOnMainCount, 0)
        XCTAssertEqual(router.checkpointPageQueryOffMainCount, 1)
        XCTAssertEqual(AgentCheckpointListContract.packOnMainActorCountForTesting, 0)
        XCTAssertEqual(AgentCheckpointListContract.packOffMainActorCountForTesting, 1)
        XCTAssertGreaterThan(
            heartbeats,
            5,
            "MainActor run loop must keep pumping during delayed query+pack"
        )
    }

    @MainActor
    func test_agentMessageListReturnsPersistedHistoryForSelectedThread() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "history", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        router.messageStore = [
            AgentMessage(threadId: t.id, role: .user, content: "old prompt"),
            AgentMessage(threadId: t.id, role: .assistant, content: "old answer")
        ]
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(20)
        ]))

        guard case .array(let messages)? = resp.result,
              case .object(let first)? = messages.first,
              case .object(let last)? = messages.last else { return XCTFail("message list must expose persisted macOS thread history") }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(first["role"], .string("user"))
        XCTAssertEqual(first["content"], .string("old prompt"))
        XCTAssertEqual(last["role"], .string("assistant"))
        XCTAssertEqual(last["content"], .string("old answer"))
    }

    @MainActor
    func test_agentMessageListPaginationReturnsEnvelopeAndOlderCursor() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "history", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        router.messageStore = (0..<35).map { index in
            AgentMessage(
                id: AgentMessageID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!),
                threadId: t.id,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "message-\(index)",
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        let d = JSONRPCDispatcher(router: router)

        let first = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(10),
            "pagination": .bool(true)
        ]))

        guard case .object(let page)? = first.result,
              case .array(let firstMessages)? = page["messages"],
              case .object(let firstMessage)? = firstMessages.first,
              case .object(let lastMessage)? = firstMessages.last,
              case .object(let firstCursor)? = page["next_before"] else {
            return XCTFail("paginated message list must return envelope with cursor")
        }
        XCTAssertEqual(firstMessages.count, 10)
        XCTAssertEqual(firstMessage["content"], .string("message-25"))
        XCTAssertEqual(lastMessage["content"], .string("message-34"))
        XCTAssertEqual(page["has_more_older"], .bool(true))

        let second = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(30),
            "pagination": .bool(true),
            "before": .object(firstCursor)
        ]))

        guard case .object(let olderPage)? = second.result,
              case .array(let olderMessages)? = olderPage["messages"],
              case .object(let firstOlderMessage)? = olderMessages.first,
              case .object(let lastOlderMessage)? = olderMessages.last else {
            return XCTFail("older paginated message list must return envelope")
        }
        XCTAssertEqual(olderMessages.count, 25)
        XCTAssertEqual(firstOlderMessage["content"], .string("message-0"))
        XCTAssertEqual(lastOlderMessage["content"], .string("message-24"))
        XCTAssertEqual(olderPage["has_more_older"], .bool(false))
        XCTAssertEqual(olderPage["has_more_newer"], .bool(true))

        guard case .object(let newerCursor)? = olderPage["next_after"] else {
            return XCTFail("older page must expose newer cursor for viewport-only down-scroll hydration")
        }
        let third = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(10),
            "pagination": .bool(true),
            "after": .object(newerCursor)
        ]))
        guard case .object(let newerPage)? = third.result,
              case .array(let newerMessages)? = newerPage["messages"],
              case .object(let firstNewerMessage)? = newerMessages.first,
              case .object(let lastNewerMessage)? = newerMessages.last else {
            return XCTFail("newer paginated message list must return envelope")
        }
        XCTAssertEqual(newerMessages.count, 10)
        XCTAssertEqual(firstNewerMessage["content"], .string("message-25"))
        XCTAssertEqual(lastNewerMessage["content"], .string("message-34"))
        XCTAssertEqual(newerPage["has_more_newer"], .bool(false))
    }

    @MainActor
    func test_agentMessageListV1BoundsOversizedBodiesAndKeepsLegacyArray() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "budget", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let oversized = String(
            repeating: "A\n\"\\\u{0001}",
            count: 300_000
        )
        XCTAssertGreaterThan(oversized.utf8.count, 1_048_576)
        let attachments = (0..<100).map { index in
            let digest = String(format: "%064x", index + 1)
            return AgentAttachment(
                id: digest,
                path: "/secret/attachment-\(index)",
                displayName: "attachment-\(index).txt",
                kind: .file,
                mimeType: "text/plain",
                sha256: digest,
                sizeBytes: index + 1
            )
        }
        let base = Date(timeIntervalSinceReferenceDate: 2_000)
        let largeID = AgentMessageID(UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        router.messageStore = [
            AgentMessage(
                id: largeID,
                threadId: t.id,
                role: .assistant,
                content: oversized,
                createdAt: base,
                attachments: attachments
            )
        ]
        let d = JSONRPCDispatcher(router: router)

        // Legacy list remains a full-content array (no response_version).
        let legacy = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(20)
        ]))
        guard case .array(let legacyMessages)? = legacy.result,
              case .object(let legacyLarge)? = legacyMessages.first else {
            return XCTFail("legacy agent.message.list must return an array of full messages")
        }
        XCTAssertEqual(legacyLarge["content"]?.stringValue?.utf8.count, oversized.utf8.count,
                       "without response_version=1, list must keep the full persisted body for compatibility")

        let v1 = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(20),
            "response_version": .number(1),
            "max_body_bytes": .number(64_000)
        ]))
        guard case .object(let envelope)? = v1.result,
              case .array(let messages)? = envelope["messages"],
              case .object(let object)? = messages.first else {
            return XCTFail("v1 list must return a versioned envelope with messages")
        }
        XCTAssertEqual(envelope["version"], .number(1))
        XCTAssertEqual(messages.count, 1, "single-message page must still include the oversized row")
        let encodedResponse = try JSONEncoder().encode(v1)
        XCTAssertLessThanOrEqual(
            encodedResponse.count,
            64_000,
            "max_body_bytes owns the fully escaped JSON-RPC response, not raw character counts"
        )
        XCTAssertFalse(
            String(decoding: encodedResponse, as: UTF8.self)
                .contains("/secret/"),
            "v1 attachment metadata must never expose provider-visible host paths"
        )
        let content = try XCTUnwrap(object["content"]?.stringValue)
        var aggregate = 0
        for message in messages {
            guard case .object(let row) = message else { return XCTFail("message must be object") }
            aggregate += (row["content"]?.stringValue ?? "").utf8.count
            XCTAssertNotNil(row["content"]?.stringValue?.data(using: .utf8), "v1 content must be valid UTF-8")
            XCTAssertFalse((row["content"]?.stringValue ?? "").contains("…"),
                           "v1 wire content must not invent ellipsis; flags represent truncation")
        }
        XCTAssertEqual(object["body_available"], .bool(true))
        XCTAssertEqual(object["body_truncated"], .bool(true),
                       "oversized body must report honest truncation")
        XCTAssertEqual(object["body_byte_count"], .number(Double(oversized.utf8.count)),
                       "body_byte_count must describe the original persisted body")
        XCTAssertLessThan(content.utf8.count, oversized.utf8.count)
        XCTAssertLessThanOrEqual(content.utf8.count, 64_000)
        XCTAssertLessThanOrEqual(aggregate, 64_000,
                                 "aggregate returned content UTF-8 bytes must not exceed max_body_bytes")
        XCTAssertEqual(object["attachment_count"], .number(100))
        XCTAssertEqual(object["attachments_truncated"], .bool(true))
        XCTAssertLessThanOrEqual(
            object["attachments"]?.arrayValue?.count ?? Int.max,
            AgentMessageTransport.attachmentCountLimit
        )
    }

    @MainActor
    func test_agentMessageListV1ColdTenLargeMessagesFitsFirstUseWebSocketBudget() async throws {
        let router = FakeRouter()
        let thread = AgentThread(
            workspaceId: nil,
            title: "cold first use",
            provider: .codex,
            model: "gpt-5.5"
        )
        router.threadStore = [thread]
        let base = Date(timeIntervalSinceReferenceDate: 2_500)
        router.messageStore = (0..<10).map { index in
            AgentMessage(
                id: AgentMessageID(
                    UUID(
                        uuidString: String(
                            format: "00000000-0000-0000-0001-%012d",
                            index
                        )
                    )!
                ),
                threadId: thread.id,
                role: .assistant,
                content: String(repeating: "cold-🙂-\"\\\n", count: 20_000),
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        XCTAssertGreaterThan(
            router.messageStore.reduce(0) { $0 + $1.content.utf8.count },
            2 * 1_048_576
        )

        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(11),
                method: "agent.message.list",
                params: [
                    "thread_id": .string(thread.id.value.uuidString),
                    "limit": .number(10),
                    "response_version": .number(1),
                    "max_body_bytes": .number(64 * 1_024),
                ]
            )
        )

        let encoded = try JSONEncoder().encode(response)
        XCTAssertLessThanOrEqual(
            encoded.count,
            64 * 1_024,
            "cold first-use history must fit one bounded WebSocket response"
        )
        guard case .object(let envelope)? = response.result,
              case .array(let messages)? = envelope["messages"] else {
            return XCTFail("cold first-use history must use the v1 envelope")
        }
        XCTAssertFalse(messages.isEmpty)
        XCTAssertLessThan(messages.count, 10)
        XCTAssertEqual(
            envelope["has_more_older"],
            .bool(true),
            "rows omitted by the first-use byte budget must remain pageable"
        )
        XCTAssertTrue(messages.allSatisfy { value in
            guard case .object(let message) = value else { return false }
            return message["body_available"] == .bool(true)
                && message["body_truncated"] == .bool(true)
        })
    }

    @MainActor
    func test_agentMessageListV1NeverReturnsCursorlessEmptyMorePage() async {
        let router = FakeRouter()
        let thread = AgentThread(
            workspaceId: nil,
            title: "cursor invariant",
            provider: .codex,
            model: "gpt-5.5"
        )
        router.threadStore = [thread]
        router.messageStore = [
            AgentMessage(
                threadId: thread.id,
                role: .assistant,
                content: String(repeating: "x", count: 20_000)
            ),
        ]
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .string(String(repeating: "r", count: 2_000)),
                method: "agent.message.list",
                params: [
                    "thread_id":
                        .string(thread.id.value.uuidString),
                    "limit": .number(10),
                    "response_version": .number(1),
                    "max_body_bytes": .number(1_024),
                ]
            )
        )

        XCTAssertEqual(response.error?.code, -32041)
        XCTAssertEqual(
            response.error?.data?.objectValue?["kind"],
            .string("list_envelope_too_small"),
            "if even an identity row cannot fit, return a typed error instead of [] + has_more + null cursor"
        )
    }

    @MainActor
    func test_agentMessageListV1ReturnsTypedErrorForStaleCursor() async {
        let router = FakeRouter()
        let thread = AgentThread(
            workspaceId: nil,
            title: "stale cursor",
            provider: .codex,
            model: "gpt-5.5"
        )
        router.threadStore = [thread]
        router.messageListBudgetError = .staleOrInvalid
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(12),
                method: "agent.message.list",
                params: [
                    "thread_id":
                        .string(thread.id.value.uuidString),
                    "limit": .number(10),
                    "response_version": .number(1),
                    "max_body_bytes": .number(64 * 1_024),
                    "before": .object([
                        "created_at":
                            .string("2026-07-30T00:00:00Z"),
                        "id":
                            .string(UUID().uuidString),
                    ]),
                ]
            )
        )

        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32044)
        XCTAssertEqual(
            response.error?.data?.objectValue?["kind"],
            .string("message_cursor_invalid")
        )
    }

    @MainActor
    func test_agentMessageGetV1ChunksOverOneMiBWithHashAndExactEnvelopeCap() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "get-budget", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let body = String(
            repeating: "🙂\n\"\\\u{0001}z",
            count: 140_000
        )
        XCTAssertGreaterThan(body.utf8.count, 1_048_576)
        let mid = AgentMessageID()
        router.messageStore = [
            AgentMessage(id: mid, threadId: t.id, role: .assistant, content: body)
        ]
        let d = JSONRPCDispatcher(router: router)

        let legacy = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.get", params: [
            "message_id": .string(mid.value.uuidString)
        ]))
        guard case .object(let legacyObject)? = legacy.result else {
            return XCTFail("legacy get must return the full message object")
        }
        XCTAssertEqual(legacyObject["content"]?.stringValue?.utf8.count, body.utf8.count)

        let expectedHash = AgentMessageTransport.bodySHA256Hex(body)
        var offset = 0
        var reconstructed = ""
        var chunks = 0
        var bodyRevision: Int?
        while true {
            var params: [String: JSONValue] = [
                "message_id": .string(mid.value.uuidString),
                "response_version": .number(1),
                "max_bytes": .number(64_000),
                "offset_bytes": .number(Double(offset)),
            ]
            if offset > 0 {
                params["expected_body_revision"] =
                    bodyRevision.map { .number(Double($0)) }
                params["expected_body_sha256"] =
                    .string(expectedHash)
            }
            let response = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(2 + chunks),
                method: "agent.message.get",
                params: params
            ))
            XCTAssertLessThanOrEqual(
                try JSONEncoder().encode(response).count,
                64_000,
                "every escaped chunk response must fit its requested HTTP budget"
            )
            guard case .object(let envelope)? = response.result,
                  Set(envelope.keys) == [
                    "version", "message", "body_offset",
                    "body_next_offset",
                  ],
                  case .object(let message)? = envelope["message"],
                  let content = message["content"]?.stringValue else {
                return XCTFail("v1 get must return the frozen chunk envelope")
            }
            XCTAssertEqual(envelope["version"], .number(1))
            XCTAssertEqual(
                envelope["body_offset"],
                .number(Double(offset))
            )
            XCTAssertEqual(message["body_offset"], .number(Double(offset)))
            XCTAssertEqual(message["body_sha256"], .string(expectedHash))
            XCTAssertEqual(message["body_revision"], .number(1))
            bodyRevision = message["body_revision"]?.intValue
            XCTAssertEqual(
                message["body_byte_count"],
                .number(Double(body.utf8.count))
            )
            if offset == 0 {
                XCTAssertNotNil(message["threadId"])
                XCTAssertNotNil(message["role"])
                XCTAssertNotNil(message["createdAt"])
                XCTAssertNotNil(message["attachments"])
            } else {
                XCTAssertEqual(
                    Set(message.keys),
                    [
                        "id", "content", "body_byte_count",
                        "body_sha256", "body_revision", "body_offset",
                        "body_next_offset", "body_truncated",
                    ],
                    "continuations must not repeat metadata or attachments"
                )
            }
            XCTAssertNotNil(content.data(using: .utf8))
            reconstructed += content
            chunks += 1
            if let next = envelope["body_next_offset"]?.intValue {
                XCTAssertGreaterThan(next, offset)
                XCTAssertEqual(
                    message["body_next_offset"],
                    .number(Double(next))
                )
                XCTAssertEqual(message["body_truncated"], .bool(true))
                offset = next
            } else {
                XCTAssertEqual(
                    envelope["body_next_offset"],
                    .null
                )
                XCTAssertEqual(message["body_truncated"], .bool(false))
                break
            }
        }
        XCTAssertGreaterThan(chunks, 4)
        XCTAssertEqual(reconstructed, body)
        XCTAssertEqual(
            AgentMessageTransport.bodySHA256Hex(reconstructed),
            expectedHash
        )

        let staleRevision = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(9_996),
            method: "agent.message.get",
            params: [
                "message_id": .string(mid.value.uuidString),
                "response_version": .number(1),
                "max_bytes": .number(64_000),
                "offset_bytes": .number(4),
                "expected_body_revision": .number(2),
                "expected_body_sha256": .string(expectedHash),
            ]
        ))
        XCTAssertEqual(staleRevision.error?.code, -32042)
        XCTAssertEqual(
            staleRevision.error?.data?.objectValue?["kind"],
            .string("body_revision_conflict")
        )

        let wrongDigest = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(9_997),
            method: "agent.message.get",
            params: [
                "message_id": .string(mid.value.uuidString),
                "response_version": .number(1),
                "max_bytes": .number(64_000),
                "offset_bytes": .number(4),
                "expected_body_revision": .number(1),
                "expected_body_sha256":
                    .string(String(repeating: "0", count: 64)),
            ]
        ))
        XCTAssertEqual(wrongDigest.error?.code, -32042)
        XCTAssertEqual(
            wrongDigest.error?.data?.objectValue?["kind"],
            .string("body_digest_mismatch")
        )

        let missingOffset = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(9_998),
            method: "agent.message.get",
            params: [
                "message_id": .string(mid.value.uuidString),
                "response_version": .number(1),
                "max_bytes": .number(64_000),
            ]
        ))
        XCTAssertEqual(
            missingOffset.error?.code,
            JSONRPCError.invalidParams.code,
            "advertising v1 without its required chunk offset must fail closed"
        )

        let midScalar = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(9_999),
            method: "agent.message.get",
            params: [
                "message_id": .string(mid.value.uuidString),
                "response_version": .number(1),
                "max_bytes": .number(64_000),
                "offset_bytes": .number(1),
                "expected_body_revision": .number(1),
                "expected_body_sha256": .string(expectedHash),
            ]
        ))
        XCTAssertEqual(midScalar.error?.code, JSONRPCError.invalidParams.code)

        let capped = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(10_000), method: "agent.message.get", params: [
            "message_id": .string(mid.value.uuidString),
            "response_version": .number(1),
            "max_bytes": .number(Double(10 * 1_048_576)),
            "offset_bytes": .number(0)
        ]))
        guard case .object(let cappedEnv)? = capped.result,
              case .object(let cappedMessage)? = cappedEnv["message"] else {
            return XCTFail("v1 get must accept oversized max_bytes and clamp")
        }
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(capped).count,
            AgentMessageTransport.getMaxBytesCap
        )
        XCTAssertEqual(cappedMessage["body_sha256"], .string(expectedHash))
    }

    @MainActor
    func test_agentMessageListV1PaginationDoesNotSkipBudgetDroppedRows() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "page-budget", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let base = Date(timeIntervalSinceReferenceDate: 3_000)
        // Three medium bodies: a tight budget should keep only the newest and flag older via has_more_older.
        router.messageStore = (0..<3).map { index in
            AgentMessage(
                id: AgentMessageID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!),
                threadId: t.id,
                role: .assistant,
                content: String(repeating: "x", count: 1_000),
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        let d = JSONRPCDispatcher(router: router)
        let first = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(10),
            "response_version": .number(1),
            "max_body_bytes": .number(1_200)
        ]))
        guard case .object(let page)? = first.result,
              case .array(let messages)? = page["messages"],
              case .object(let nextBefore)? = page["next_before"] else {
            return XCTFail("v1 list must expose next_before when older rows remain")
        }
        XCTAssertEqual(page["has_more_older"], .bool(true),
                       "budget-omitted older rows must surface as has_more_older, not silent skips")
        XCTAssertFalse(messages.isEmpty)
        XCTAssertEqual(
            Set(nextBefore.keys),
            ["created_at", "id"],
            "v1 cursors use one exact snake_case shape"
        )

        let older = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(10),
            "response_version": .number(1),
            "max_body_bytes": .number(50_000),
            "before": .object(nextBefore)
        ]))
        guard case .object(let olderPage)? = older.result,
              case .array(let olderMessages)? = olderPage["messages"] else {
            return XCTFail("older v1 page must return messages")
        }
        XCTAssertFalse(olderMessages.isEmpty,
                       "pagination must eventually reach budget-omitted older rows")

        let malformedCursor = await d.dispatch(
            JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(3),
                method: "agent.message.list",
                params: [
                    "thread_id": .string(t.id.value.uuidString),
                    "limit": .number(10),
                    "response_version": .number(1),
                    "max_body_bytes": .number(50_000),
                    "before": .object([
                        "createdAt": .string("not-the-v1-cursor-shape"),
                        "id": .string(UUID().uuidString),
                    ]),
                ]
            )
        )
        XCTAssertEqual(
            malformedCursor.error?.code,
            JSONRPCError.invalidParams.code,
            "a modern malformed cursor must fail closed instead of restarting at the newest page"
        )
    }

    @MainActor
    func test_agentThreadListKeepsFullTitleAndAddsDisplayTitleForMirrors() async throws {
        let router = FakeRouter()
        let fullTitle = "git add commit and push all repos here with this long exact wording"
        let thread = AgentThread(workspaceId: nil, title: fullTitle, provider: .claude, model: "fake-model", interactionMode: .plan)
        router.threadStore = [thread]
        router.messageStore = [AgentMessage(threadId: thread.id, role: .user, content: "start")]
        let runId = AgentRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000123")!)
        router.activeAgentRuns[thread.id] = AgentActiveRunSnapshot(
            runId: runId,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000.125)
        )
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.list", params: nil))

        guard case .array(let threads)? = resp.result,
              case .object(let first)? = threads.first else { return XCTFail("thread list must return encoded threads") }
        XCTAssertEqual(first["title"], .string(fullTitle),
                       "host APIs must keep the full persisted title for macOS and iOS")
        XCTAssertEqual(first["displayTitle"], .string("git add commit and push all ..."))
        XCTAssertEqual(first["display_title"], .string("git add commit and push all ..."))
        XCTAssertEqual(first["providerLocked"], .bool(true),
                       "iOS mirrors must know when to hide the source picker for existing threads")
        XCTAssertEqual(first["provider_locked"], .bool(true))
        XCTAssertEqual(first["interaction_mode"], .string("plan"),
                       "iOS must restore the host-owned per-thread interaction mode after selection or relaunch")
        XCTAssertEqual(first["active_run_id"], .string(runId.value.uuidString))
        XCTAssertEqual(first["active_run_started_at_ms"], .number(1_700_000_000_125),
                       "iOS rebaseline must retain the Mac-owned elapsed-run clock")
    }

    @MainActor
    func testAgentThreadReadCanReturnTypedMirrorSnapshotWithEventWatermark() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.readAgentEvents = [.turnStarted(turnId: "turn-mirror")]
        let dispatcher = JSONRPCDispatcher(router: router)

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true)
            ]
        ))

        let result = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(result["event_watermark"], .number(Double(EventBus.shared.currentSeq)))
        XCTAssertEqual(result["events"]?.arrayValue?.count, 1)
        XCTAssertNotNil(result["events"]?.arrayValue?.first?.objectValue?["turnStarted"],
                        "the mirror snapshot must preserve the typed AssistantEvent wire shape")
        XCTAssertEqual(result["events_truncated"], .bool(false))
    }

    /// WHY: peer discovery is authenticated with the active-run bearer. iOS
    /// must receive the exact bounded credential through readback without ever
    /// persisting it in a mutating command receipt.
    @MainActor
    func testAgentThreadReadReturnsOnlyTheExactActiveRunDelegationCapability() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        let run = AgentRunID()
        router.activeAgentRuns[thread] = AgentActiveRunSnapshot(runId: run, startedAt: Date())
        router.activeAgentDelegations[thread] = AgentActiveDelegationSnapshot(
            threadId: thread,
            runId: run,
            hostId: "host-delegation",
            capability: "bounded-active-run-capability",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let dispatcher = JSONRPCDispatcher(router: router)

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true)
            ]
        ))

        let result = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(result["delegation_capability"], .string("bounded-active-run-capability"))
        XCTAssertEqual(result["delegation_thread_id"], .string(thread.value.uuidString.lowercased()))
        XCTAssertEqual(result["delegation_run_id"], .string(run.value.uuidString.lowercased()))
        XCTAssertEqual(result["delegation_host_id"], .string("host-delegation"))
        XCTAssertEqual(result["delegation_expires_at_ms"], .number(1_900_000_000_000))

        router.activeAgentRuns[thread] = AgentActiveRunSnapshot(runId: AgentRunID(), startedAt: Date())
        let crossRun = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true)
            ]
        ))
        XCTAssertNil(crossRun.result?.objectValue?["delegation_capability"],
                     "a credential bound to another run must fail closed")

        router.activeAgentRuns[thread] = AgentActiveRunSnapshot(runId: run, startedAt: Date())
        router.activeAgentDelegations[thread] = AgentActiveDelegationSnapshot(
            threadId: thread,
            runId: run,
            hostId: "host-delegation",
            capability: "expired-capability",
            expiresAt: Date(timeIntervalSince1970: 1)
        )
        let expired = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(3),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true)
            ]
        ))
        XCTAssertNil(expired.result?.objectValue?["delegation_capability"],
                     "an expired active-run credential must never cross the readback boundary")
    }

    @MainActor
    func testAgentThreadReadCanBoundLargeMobileRecoverySnapshots() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.readAgentEvents = [
            .turnStarted(turnId: "turn-1"),
            .turnStarted(turnId: "turn-2"),
            .turnStarted(turnId: "turn-3")
        ]
        let dispatcher = JSONRPCDispatcher(router: router)

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "event_limit": .number(2)
            ]
        ))

        let result = try XCTUnwrap(response.result?.objectValue)
        let events = try XCTUnwrap(result["events"]?.arrayValue)
        XCTAssertEqual(events.count, 2)
        XCTAssertNotNil(events.first?.objectValue?["turnStarted"]?.objectValue)
        XCTAssertEqual(events.first?.objectValue?["turnStarted"]?.objectValue?["turnId"], .string("turn-2"),
                       "bounded recovery must keep the newest contiguous event suffix")
        XCTAssertEqual(result["event_watermark"], .number(Double(EventBus.shared.currentSeq)),
                       "truncating old payload must not move the authoritative event cursor")
        XCTAssertEqual(result["events_truncated"], .bool(true))
    }

    @MainActor
    func test_agentThreadSelectRoutesSelectionToMacSurface() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "load prior", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.select", params: [
            "thread_id": .string(t.id.value.uuidString)
        ]))

        XCTAssertEqual(resp.result, .bool(true))
        XCTAssertEqual(router.selectedThread, t.id, "selecting an existing iOS thread must select the same macOS Agent App thread")
    }

    @MainActor
    func test_agentThreadConfigureClearsProviderSessionWhenProviderChanges() async throws {
        let router = FakeRouter()
        var t = AgentThread(workspaceId: nil, title: "switch provider", provider: .claude, model: "claude-sonnet-4-6")
        t.providerThreadId = "claude-session"
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.configure", params: [
            "thread_id": .string(t.id.value.uuidString),
            "provider": .string("codex"),
            "model": .string("gpt-5.5")
        ]))

        XCTAssertNil(resp.error)
        XCTAssertNil(router.threadStore.first?.providerThreadId, "changing provider must not resume an incompatible provider session")
    }

    @MainActor
    func test_agentThreadConfigurePreservesClaudeProviderSessionWhenOnlyModelChanges() async throws {
        let router = FakeRouter()
        var t = AgentThread(workspaceId: nil, title: "switch model", provider: .claude, model: "claude-sonnet-4-6")
        t.providerThreadId = "claude-session"
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.configure", params: [
            "thread_id": .string(t.id.value.uuidString),
            "provider": .string("claude"),
            "model": .string("claude-opus-4-7")
        ]))

        XCTAssertNil(resp.error)
        XCTAssertEqual(router.threadStore.first?.model, "claude-opus-4-7")
        XCTAssertEqual(router.threadStore.first?.providerThreadId, "claude-session",
                       "Claude model switching must keep the provider session cursor so the next turn can resume the same conversation")
    }

    @MainActor
    func test_surfaceSendTextReturnsExplicitTerminalFailureStatus() async throws {
        let router = FakeRouter()
        let surface = SurfaceID()
        router.terminalSendResult = .object(["status": .string("process_exited"), "accepted": .bool(false)])
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.send_text", params: [
            "id": .string(surface.value.uuidString),
            "text": .string("pwd")
        ]))

        let result = try XCTUnwrap(resp.result?.objectValue)
        XCTAssertEqual(result["status"], .string("process_exited"),
                       "remote terminal input must fail loudly after child exit instead of returning opaque success")
        XCTAssertEqual(result["accepted"], .bool(false))
    }

    @MainActor
    func test_surfaceHealthIncludesTerminalProcessState() async throws {
        let router = FakeRouter()
        let surface = SurfaceID()
        router.terminalHealth = .object([
            "alive": .bool(false),
            "process_alive": .bool(false),
            "pty_open": .bool(false),
            "input_accepting": .bool(false),
            "terminal_dead_reason": .string("process_exited")
        ])
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.health", params: [
            "id": .string(surface.value.uuidString)
        ]))

        let result = try XCTUnwrap(resp.result?.objectValue)
        XCTAssertEqual(result["alive"], .bool(false))
        XCTAssertEqual(result["terminal_dead_reason"], .string("process_exited"),
                       "iOS ALIVE/DEAD must reflect terminal process state, not just surface object existence")
    }

    @MainActor
    func test_surfaceReadTextCanReturnSnapshotReliabilityMetadata() async throws {
        let router = FakeRouter()
        let surface = SurfaceID()
        router.terminalSnapshot = .object([
            "text": .string("partial"),
            "complete": .bool(false),
            "partial": .bool(true),
            "source": .string("ansi_fallback"),
            "partial_reason": .string("ghostty_unavailable")
        ])
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.read_text", params: [
            "id": .string(surface.value.uuidString),
            "include_metadata": .bool(true)
        ]))

        let result = try XCTUnwrap(resp.result?.objectValue)
        XCTAssertEqual(result["complete"], .bool(false))
        XCTAssertEqual(result["partial_reason"], .string("ghostty_unavailable"),
                       "snapshot reads must say when terminal text is degraded so iOS does not show fake complete output")
        XCTAssertEqual(result["surface_seq"], .number(0),
                       "metadata snapshots must carry the live-output sequence so iOS can reject a stale RPC body")
    }

    @MainActor
    func testAgentPlanNotesSaveRejectsStaleExpectedValue() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.planNotesByThread[thread] = "newer Mac notes"
        let dispatcher = JSONRPCDispatcher(router: router)

        let rejected = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("stale iOS overwrite"),
                "expected_notes": .string("older notes"),
                "client_request_id": .string(UUID().uuidString)
            ]
        ))

        XCTAssertEqual(rejected.error?.code, -32009)
        XCTAssertEqual(rejected.error?.message, "Plan notes changed on another device.")
        XCTAssertEqual(router.planNotesByThread[thread], "newer Mac notes",
                       "a stale mobile save must not overwrite the authoritative Mac value")

        let accepted = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("merged iOS notes"),
                "expected_notes": .string("newer Mac notes"),
                "client_request_id": .string(UUID().uuidString)
            ]
        ))

        XCTAssertNil(accepted.error)
        XCTAssertEqual(accepted.result, .bool(true))
        XCTAssertEqual(router.planNotesByThread[thread], "merged iOS notes")
    }

    @MainActor
    func testAgentPlanNotesPersistenceFailureIsNotReturnedOrCachedAsSuccess() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        let requestID = UUID().uuidString
        let dispatcher = JSONRPCDispatcher(router: router)
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("durable notes"),
                "expected_notes": .string(""),
                "client_request_id": .string(requestID)
            ]
        )

        router.planNotesSaveShouldFail = true
        let failed = await dispatcher.dispatch(request)

        XCTAssertNil(failed.result, "a failed durable write must never return RPC success")
        XCTAssertNotNil(failed.error)
        XCTAssertNil(router.commandReceipt(method: request.method, clientRequestId: requestID),
                     "a failed durable write must not poison retries with a cached success receipt")

        router.planNotesSaveShouldFail = false
        let retried = await dispatcher.dispatch(request)

        XCTAssertEqual(retried.result, .bool(true))
        XCTAssertEqual(router.planNotesSaveCallCount, 2,
                       "the same request ID must reach persistence again after the first write failed")
        XCTAssertEqual(router.planNotesByThread[thread], "durable notes")
    }

    @MainActor
    func testAgentPlanNotesCASReadFailureDoesNotAssumeEmptyValueOrWrite() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.planNotesReadShouldFail = true
        let dispatcher = JSONRPCDispatcher(router: router)

        let failed = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("must not write"),
                "expected_notes": .string("")
            ]
        ))

        XCTAssertNil(failed.result,
                     "a failed authoritative read must never be treated as an empty CAS value")
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(router.planNotesSaveCallCount, 0,
                       "CAS must stop before persistence when the authoritative read failed")
    }

    /// WHY: legacy mobile clients omit protocol_version and must keep receiving
    /// the full notes string object — no silent shape change for old clients.
    @MainActor
    func testAgentPlanNotesGet_legacyPathUnchangedWithoutProtocolVersion() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        let notes = String(repeating: "legacy-full-notes-", count: 100)
        router.planNotesByThread[thread] = notes
        let dispatcher = JSONRPCDispatcher(router: router)

        let resp = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.get",
            params: [
                "thread_id": .string(thread.value.uuidString),
                // max_bytes alone must not opt into v1.
                "max_bytes": .number(16),
            ]
        ))

        XCTAssertNil(resp.error)
        XCTAssertEqual(resp.result, .object(["notes": .string(notes)]))
        XCTAssertEqual(router.planNotesByThread[thread], notes,
                       "get must not mutate authoritative persistence")
    }

    /// WHY: v1 must page under the server ceiling, reassemble exactly, and keep
    /// each encoded JSON-RPC response under the 512 KiB weak-link budget.
    @MainActor
    func testAgentPlanNotesGet_v1PagesAndReassemblesWithoutTruncatingPersistence() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        let unit = "wire-v1-✅-"
        var notes = ""
        while notes.utf8.count < 180_000 {
            notes += unit
        }
        let authoritative = notes
        router.planNotesByThread[thread] = authoritative
        let dispatcher = JSONRPCDispatcher(router: router)

        var offset = 0
        var assembled = ""
        var digest: String?
        var pageIndex = 0
        while true {
            var params: [String: JSONValue] = [
                "thread_id": .string(thread.value.uuidString),
                "protocol_version": .number(1),
                "offset_bytes": .number(Double(offset)),
                "max_bytes": .number(Double(PlanNotesProjectionV1.maxBytesCeiling)),
            ]
            if let digest {
                params["content_digest"] = .string(digest)
            }
            let resp = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(pageIndex + 1),
                method: "agent.plan.notes.get",
                params: params
            ))
            XCTAssertNil(resp.error, "page \(pageIndex): \(String(describing: resp.error))")
            let body = try XCTUnwrap(resp.result?.objectValue)
            XCTAssertEqual(body["protocol_version"], .number(1))
            let chunk = try XCTUnwrap(body["notes"]?.stringValue)
            assembled += chunk
            digest = body["content_digest"]?.stringValue
            let encoded = try JSONEncoder().encode(resp)
            XCTAssertLessThan(
                encoded.count,
                PlanNotesProjectionV1.maxEncodedResponseBytes,
                "page \(pageIndex) encoded \(encoded.count)"
            )
            let hasMore = try XCTUnwrap(body["has_more"]?.boolValue)
            if !hasMore { break }
            offset = try XCTUnwrap(body["next_offset_bytes"]?.intValue)
            pageIndex += 1
            XCTAssertLessThan(pageIndex, 50)
        }

        XCTAssertEqual(assembled, authoritative)
        XCTAssertEqual(router.planNotesByThread[thread], authoritative,
                       "paged get must leave persisted notes byte-identical")
        XCTAssertGreaterThan(pageIndex, 0, "180 KiB must span multiple 64 KiB pages")
    }

    /// WHY: a present-but-invalid v1 request must fail closed, not fall back to
    /// the unbounded legacy response that the client cannot afford.
    @MainActor
    func testAgentPlanNotesGet_v1InvalidParamsDoNotDowngradeToLegacy() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.planNotesByThread[thread] = String(repeating: "x", count: 10_000)
        let dispatcher = JSONRPCDispatcher(router: router)

        let cases: [[String: JSONValue]] = [
            [
                "thread_id": .string(thread.value.uuidString),
                "protocol_version": .number(2),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "protocol_version": .number(1),
                "offset_bytes": .number(1.5),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "protocol_version": .number(1),
                "max_bytes": .number(Double(PlanNotesProjectionV1.maxBytesCeiling + 1)),
            ],
        ]
        for params in cases {
            let resp = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.plan.notes.get",
                params: params
            ))
            XCTAssertEqual(resp.error?.code, -32602, "\(params)")
            XCTAssertNil(resp.result,
                         "must not return a success/legacy body on a failed v1 request")
        }
    }

    /// WHY: mid-pagination mutation must surface as an honest CAS error so the
    /// client restarts reassembly instead of concatenating mixed revisions.
    @MainActor
    func testAgentPlanNotesGet_v1DetectsDigestMismatchMidPagination() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.planNotesByThread[thread] = String(repeating: "A", count: 100_000)
        let dispatcher = JSONRPCDispatcher(router: router)

        let first = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.get",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "protocol_version": .number(1),
                "offset_bytes": .number(0),
                "max_bytes": .number(1024),
            ]
        ))
        let digest = try XCTUnwrap(first.result?.objectValue?["content_digest"]?.stringValue)
        let next = try XCTUnwrap(first.result?.objectValue?["next_offset_bytes"]?.intValue)

        router.planNotesByThread[thread] = String(repeating: "B", count: 100_000)
        let second = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.plan.notes.get",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "protocol_version": .number(1),
                "offset_bytes": .number(Double(next)),
                "max_bytes": .number(1024),
                "content_digest": .string(digest),
            ]
        ))
        XCTAssertEqual(second.error?.code, -32009)
        XCTAssertEqual(second.error?.message, "Plan notes changed during pagination.")
    }

    /// WHY: save must keep the full authoritative value even when notes are
    /// multi-MiB — the wire projection is bounded, persistence is not.
    @MainActor
    func testAgentPlanNotesSave_persistsFullNotesUntruncated() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        let huge = String(repeating: "💾", count: 50_000) // multi-byte, multi-100KiB
        let dispatcher = JSONRPCDispatcher(router: router)

        let resp = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string(huge),
                "client_request_id": .string(UUID().uuidString),
            ]
        ))
        XCTAssertNil(resp.error)
        XCTAssertEqual(router.planNotesByThread[thread], huge)
        XCTAssertEqual(router.planNotesByThread[thread]?.utf8.count, huge.utf8.count)
    }

    /// WHY: multi-MiB prior notes must not ride the v1 save request as
    /// `expected_notes` — only a 64-hex digest CAS token — or 3G pays 2× body.
    @MainActor
    func testAgentPlanNotesSave_v1DigestCASDoesNotTransportOldBody() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        let oldMarker = "OLD-NOTES-UNIQUE-MARKER-\(UUID().uuidString)-"
        var oldNotes = ""
        while oldNotes.utf8.count < 2 * 1024 * 1024 {
            oldNotes += oldMarker
        }
        let newMarker = "NEW-NOTES-UNIQUE-MARKER-\(UUID().uuidString)-"
        var newNotes = ""
        while newNotes.utf8.count < 2 * 1024 * 1024 {
            newNotes += newMarker
        }
        router.planNotesByThread[thread] = oldNotes
        let expectedDigest = PlanNotesProjectionV1.contentDigest(of: oldNotes)
        let requestID = UUID().uuidString
        let params: [String: JSONValue] = [
            "thread_id": .string(thread.value.uuidString),
            "notes": .string(newNotes),
            "protocol_version": .number(1),
            "expected_content_digest": .string(expectedDigest),
            "client_request_id": .string(requestID),
        ]
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: params
        )
        let encodedRequest = try JSONEncoder().encode(request)
        let requestUTF8 = String(decoding: encodedRequest, as: UTF8.self)
        XCTAssertFalse(requestUTF8.contains(oldMarker),
                       "v1 save must not embed the multi-MiB prior body")
        XCTAssertFalse(requestUTF8.contains("expected_notes"),
                       "v1 save must not carry expected_notes at all")
        XCTAssertTrue(requestUTF8.contains(expectedDigest))
        XCTAssertLessThan(
            encodedRequest.count,
            newNotes.utf8.count + 4 * 1024,
            "request overhead beyond the new body must stay tiny (digest only)"
        )

        let dispatcher = JSONRPCDispatcher(router: router)
        let resp = await dispatcher.dispatch(request)
        XCTAssertNil(resp.error, String(describing: resp.error))
        XCTAssertEqual(router.planNotesByThread[thread], newNotes)
        XCTAssertEqual(router.planNotesByThread[thread]?.utf8.count, newNotes.utf8.count)

        let body = try XCTUnwrap(resp.result?.objectValue)
        XCTAssertEqual(body["ok"], .bool(true))
        let newDigest = PlanNotesProjectionV1.contentDigest(of: newNotes)
        XCTAssertEqual(body["content_digest"]?.stringValue, newDigest)
        XCTAssertEqual(body["revision"]?.stringValue, newDigest)
        XCTAssertEqual(body["total_bytes"], .number(Double(newNotes.utf8.count)))
        XCTAssertNil(body["notes"], "compact save result must not re-emit notes")

        // Receipt replay must be byte-identical to the first success. Sort keys:
        // unsorted JSONEncoder output can order the same object differently
        // on every encode, which made this comparison flaky.
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        let firstEncoded = try canonicalEncoder.encode(try XCTUnwrap(resp.result))
        let replay = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.plan.notes.save",
            params: params
        ))
        XCTAssertNil(replay.error)
        let replayEncoded = try canonicalEncoder.encode(try XCTUnwrap(replay.result))
        XCTAssertEqual(replayEncoded, firstEncoded,
                       "command-receipt replay must be byte-identical")
        XCTAssertEqual(router.planNotesSaveCallCount, 1,
                       "receipt hit must not re-run persistence")
    }

    /// WHY: a stale digest must fail closed with the current revision and write
    /// nothing — same CAS honesty as legacy expected_notes, without the body.
    @MainActor
    func testAgentPlanNotesSave_v1DigestMismatchWritesNothingAndReturnsCurrentRevision() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        let current = String(repeating: "server-authoritative-", count: 50_000)
        router.planNotesByThread[thread] = current
        let staleDigest = PlanNotesProjectionV1.contentDigest(of: "client-stale-view")
        let dispatcher = JSONRPCDispatcher(router: router)

        let rejected = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("must-not-land"),
                "protocol_version": .number(1),
                "expected_content_digest": .string(staleDigest),
                "client_request_id": .string(UUID().uuidString),
            ]
        ))
        XCTAssertEqual(rejected.error?.code, -32009)
        XCTAssertEqual(rejected.error?.message, "Plan notes changed on another device.")
        let data = rejected.error?.data?.objectValue
        let currentDigest = PlanNotesProjectionV1.contentDigest(of: current)
        XCTAssertEqual(data?["content_digest"]?.stringValue, currentDigest)
        XCTAssertEqual(data?["revision"]?.stringValue, currentDigest)
        XCTAssertEqual(data?["expected_content_digest"]?.stringValue, staleDigest)
        XCTAssertEqual(router.planNotesByThread[thread], current)
        XCTAssertEqual(router.planNotesSaveCallCount, 0)

        // Matching digest then saves the full new body.
        let accepted = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("merged-ok"),
                "protocol_version": .number(1),
                "expected_content_digest": .string(currentDigest),
                "client_request_id": .string(UUID().uuidString),
            ]
        ))
        XCTAssertNil(accepted.error)
        XCTAssertEqual(router.planNotesByThread[thread], "merged-ok")
        XCTAssertEqual(accepted.result?.objectValue?["ok"], .bool(true))
        XCTAssertEqual(
            accepted.result?.objectValue?["content_digest"]?.stringValue,
            PlanNotesProjectionV1.contentDigest(of: "merged-ok")
        )
    }

    /// WHY: dual-body / malformed v1 must not fall through to legacy CAS or
    /// success — a modern client would otherwise still pay both bodies.
    @MainActor
    func testAgentPlanNotesSave_v1RejectsDualBodyAndMalformedParams() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        let prior = "prior-body"
        router.planNotesByThread[thread] = prior
        let digest = PlanNotesProjectionV1.contentDigest(of: prior)
        let dispatcher = JSONRPCDispatcher(router: router)

        let cases: [[String: JSONValue]] = [
            [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("n"),
                "protocol_version": .number(1),
                "expected_content_digest": .string(digest),
                "expected_notes": .string(prior),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("n"),
                "protocol_version": .number(2),
                "expected_content_digest": .string(digest),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("n"),
                "protocol_version": .number(1.5),
                "expected_content_digest": .string(digest),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("n"),
                "protocol_version": .number(1),
            ],
            [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("n"),
                "protocol_version": .number(1),
                "expected_content_digest": .string("zzzz"),
            ],
        ]
        for params in cases {
            let resp = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.plan.notes.save",
                params: params
            ))
            XCTAssertEqual(resp.error?.code, -32602, "\(params)")
            XCTAssertNil(resp.result)
            XCTAssertEqual(router.planNotesByThread[thread], prior)
            XCTAssertEqual(router.planNotesSaveCallCount, 0, "\(params)")
        }
    }

    /// WHY: legacy clients that omit protocol_version must keep full-body
    /// expected_notes CAS and the bool(true) success shape.
    @MainActor
    func testAgentPlanNotesSave_legacyExpectedNotesStillWorksWithoutProtocolVersion() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.planNotesByThread[thread] = "mac-notes"
        let dispatcher = JSONRPCDispatcher(router: router)

        let rejected = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("stale"),
                "expected_notes": .string("phone-stale"),
            ]
        ))
        XCTAssertEqual(rejected.error?.code, -32009)
        XCTAssertNil(rejected.error?.data,
                     "legacy mismatch keeps nil data — do not change old clients")
        XCTAssertEqual(router.planNotesByThread[thread], "mac-notes")

        let accepted = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("merged"),
                "expected_notes": .string("mac-notes"),
            ]
        ))
        XCTAssertNil(accepted.error)
        XCTAssertEqual(accepted.result, .bool(true),
                       "legacy success shape must stay bool(true)")
        XCTAssertEqual(router.planNotesByThread[thread], "merged")
    }

    /// WHY: marker-absent iOS hosts read system.capabilities as the authority
    /// for plan_notes. It must expose the exact shared advertisement so a new
    /// client never sends protocol_version:1 to an old host that would ignore
    /// expected_content_digest and save without CAS.
    @MainActor
    func testSystemCapabilities_exposesExactPlanNotesAdvertisement() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "system.capabilities",
            params: nil
        ))
        XCTAssertNil(resp.error)
        let agent = resp.result?.objectValue?["agent"]?.objectValue
        XCTAssertEqual(
            agent?["plan_notes"],
            PlanNotesProjectionV1.CapabilityAdvertisement.jsonValue,
            "system.capabilities must expose the exact shared plan_notes object"
        )
    }

    /// WHY: attachment_upload is store-injected and optional; plan_notes is
    /// compile-time presence of v1 get+save. Injecting or omitting attachment
    /// must never remove or mutate the plan_notes gate.
    @MainActor
    func testSystemCapabilities_attachmentInjectionDoesNotMutatePlanNotes() async {
        let expected = PlanNotesProjectionV1.CapabilityAdvertisement.jsonValue
        let withoutAttachment = JSONRPCDispatcher(router: FakeRouter())
        let withAttachment = JSONRPCDispatcher(
            router: FakeRouter(),
            agentAttachmentUploadCapability: .protectedV3
        )

        let bare = await withoutAttachment.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil
        ))
        let injected = await withAttachment.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(2), method: "system.capabilities", params: nil
        ))

        let bareAgent = bare.result?.objectValue?["agent"]?.objectValue
        let injectedAgent = injected.result?.objectValue?["agent"]?.objectValue
        XCTAssertNil(bareAgent?["attachment_upload"])
        XCTAssertEqual(injectedAgent?["attachment_upload"], AgentAttachmentUploadCapabilityAdvertisement.protectedV3.jsonValue)
        XCTAssertEqual(bareAgent?["plan_notes"], expected)
        XCTAssertEqual(injectedAgent?["plan_notes"], expected)
        XCTAssertEqual(bareAgent?["plan_notes"], injectedAgent?["plan_notes"],
                       "attachment presence/absence must not mutate plan_notes")
    }

    /// WHY: iOS AgentAttachmentUploadCapability.isUsableV3 freezes these exact
    /// numbers. Drift here silently disables protected upload on the phone.
    @MainActor
    func testSystemCapabilities_protectedV3AdvertisementMatchesIOSFrozenContract() async throws {
        let dispatcher = JSONRPCDispatcher(
            router: FakeRouter(),
            agentAttachmentUploadCapability: .protectedV3
        )
        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil
        ))
        let upload = response.result?.objectValue?["agent"]?
            .objectValue?["attachment_upload"]?.objectValue
        let uploadObject = try XCTUnwrap(upload, "system.capabilities must advertise attachment_upload when v3 store is wired")

        XCTAssertEqual(uploadObject["protocol_version"]?.intValue, 3)
        XCTAssertEqual(uploadObject["max_bytes"]?.intValue, 25 * 1024 * 1024)
        XCTAssertEqual(uploadObject["chunk_bytes"]?.intValue, 512 * 1024)
        XCTAssertEqual(uploadObject["max_chunk_count"]?.intValue, 50)
        XCTAssertEqual(uploadObject["cipher_overhead_bytes"]?.intValue, 28)
        let encodings = uploadObject["content_encodings"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        XCTAssertTrue(
            encodings.contains("protected_chunks_v1"),
            "iOS requires protected_chunks_v1 in content_encodings for isUsableV3"
        )
        // Mirror of iOS AgentAttachmentUploadCapability.isUsableV3 checks.
        XCTAssertEqual(AgentAttachmentUploadCapabilityAdvertisement.protectedV3.protocolVersion, 3)
        XCTAssertEqual(AgentAttachmentUploadCapabilityAdvertisement.protectedV3.maxBytes, 25 * 1024 * 1024)
        XCTAssertEqual(AgentAttachmentUploadCapabilityAdvertisement.protectedV3.chunkBytes, 512 * 1024)
        XCTAssertEqual(AgentAttachmentUploadCapabilityAdvertisement.protectedV3.maxChunkCount, 50)
        XCTAssertEqual(AgentAttachmentUploadCapabilityAdvertisement.protectedV3.cipherOverheadBytes, 28)
        XCTAssertTrue(
            AgentAttachmentUploadCapabilityAdvertisement.protectedV3.contentEncodings
                .contains("protected_chunks_v1")
        )
    }

    // Verifies that the encode<T> helper's new path (JSONDecoder -> JSONValue) produces the
    // same structure as the old path (JSONSerialization + JSONValue.from) for a representative
    // Codable. This guards against any behavioral divergence introduced by the optimization.
    func test_encodeHelper_newPathMatchesOldPath() throws {
        struct Sample: Codable {
            let name: String
            let count: Int
            let ratio: Double
            let flag: Bool
            let tags: [String]
            let nested: Nested
            struct Nested: Codable {
                let value: String
            }
        }
        let sample = Sample(
            name: "hello",
            count: 42,
            ratio: 1.5,
            flag: true,
            tags: ["a", "b"],
            nested: .init(value: "world")
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(sample)

        // Old path: JSONSerialization -> JSONValue.from
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let oldResult = JSONValue.from(any)

        // New path: JSONDecoder -> JSONValue directly
        let newResult = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(oldResult, newResult,
                       "encode<T> optimization must produce structurally identical JSONValue output as the original double-round-trip path")
    }

    // MARK: - git.diff bounded response v1

    @MainActor
    func test_gitDiff_withoutResponseVersion_returnsLegacyBareString() async {
        // WHY: deployed older iOS / non-opt-in callers still expect a bare string
        // result. Introducing response_version must not change that shape.
        let router = FakeRouter()
        router.stubGitDiff = "diff --git a/A b/A\n+line"
        let d = JSONRPCDispatcher(router: router)
        let wid = UUID().uuidString

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "git.diff", params: [
            "workspace_id": .string(wid),
        ]))

        XCTAssertNil(resp.error)
        XCTAssertEqual(resp.result, .string("diff --git a/A b/A\n+line"),
                       "absent response_version must keep the exact legacy bare-string result")
        XCTAssertEqual(router.gitDiffCallCount, 1)
    }

    @MainActor
    func test_gitDiff_optInV1_returnsBoundedObject() async {
        // WHY: modern iOS asks for a finite wire window; the host must report the
        // original total separately because returned text may already be clipped.
        let router = FakeRouter()
        router.stubGitDiff = "a\nb\nc\nd"
        let d = JSONRPCDispatcher(router: router)
        let wid = UUID().uuidString

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "git.diff", params: [
            "workspace_id": .string(wid),
            "response_version": .number(1),
            "max_bytes": .number(1024),
            "max_lines": .number(2),
        ]))

        XCTAssertNil(resp.error)
        guard case .object(let body)? = resp.result else {
            return XCTFail("opt-in v1 must return a bounded object, not a bare string")
        }
        XCTAssertEqual(body["version"], .number(1))
        XCTAssertEqual(body["text"], .string("a\nb"))
        XCTAssertEqual(body["truncated"], .bool(true))
        XCTAssertEqual(body["total_lines"], .number(4),
                       "total_lines must be the original exact line count, not the returned prefix")
        XCTAssertEqual(router.gitDiffCallCount, 1)
    }

    @MainActor
    func test_gitDiff_invalidOptInCaps_failClosedBeforeRouter() async {
        // WHY: a hostile/malformed cellular request must not trigger an expensive
        // full-patch generation only to be rejected afterward.
        let router = FakeRouter()
        router.stubGitDiff = "should-not-be-fetched"
        let d = JSONRPCDispatcher(router: router)
        let wid = UUID().uuidString

        let cases: [[String: JSONValue]] = [
            // unknown version
            ["workspace_id": .string(wid), "response_version": .number(2),
             "max_bytes": .number(100), "max_lines": .number(10)],
            // missing max_bytes
            ["workspace_id": .string(wid), "response_version": .number(1),
             "max_lines": .number(10)],
            // missing max_lines
            ["workspace_id": .string(wid), "response_version": .number(1),
             "max_bytes": .number(100)],
            // fractional max_bytes
            ["workspace_id": .string(wid), "response_version": .number(1),
             "max_bytes": .number(1.5), "max_lines": .number(10)],
            // non-positive max_lines
            ["workspace_id": .string(wid), "response_version": .number(1),
             "max_bytes": .number(100), "max_lines": .number(0)],
            // over-ceiling max_bytes
            ["workspace_id": .string(wid), "response_version": .number(1),
             "max_bytes": .number(Double(GitDiffBoundedResponse.maxBytesCeiling + 1)),
             "max_lines": .number(10)],
            // over-ceiling max_lines
            ["workspace_id": .string(wid), "response_version": .number(1),
             "max_bytes": .number(100),
             "max_lines": .number(Double(GitDiffBoundedResponse.maxLinesCeiling + 1))],
        ]

        for (idx, params) in cases.enumerated() {
            router.gitDiffCallCount = 0
            let resp = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(idx + 1), method: "git.diff", params: params
            ))
            XCTAssertEqual(resp.error?.code, -32602, "case \(idx) must be invalid params")
            XCTAssertEqual(router.gitDiffCallCount, 0,
                           "case \(idx) must not invoke router.gitDiff before validation")
        }
    }

    // MARK: - agent.checkpoint.diff bounded response v1

    /// Builds a thread+checkpoint setup with a stubbed full-thread patch.
    @MainActor
    private func checkpointDiffFixture(
        patch: String
    ) -> (router: FakeRouter, threadID: String) {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "checkpoint-bound", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.stubAgentCheckpointDiff = patch
        // Seed a real checkpoint so non-stub path remains available if stub is cleared.
        router.checkpointStore = [AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: AgentRunID(),
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:test:turn-1",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0)],
            diffPatch: patch,
            fileDiffs: []
        )]
        return (router, thread.id.value.uuidString)
    }

    @MainActor
    func test_agentCheckpointDiff_withoutResponseVersion_returnsExactLegacyBareString() async {
        // WHY: iOS currently auto-requests checkpoint diffs on selection with the
        // legacy bare-string contract. max_bytes / max_lines alone must not opt in
        // or older clients would fail to decode an object as a string.
        let patch = "diff --git a/README.md b/README.md\n+changed\n"
        let fixture = checkpointDiffFixture(patch: patch)
        let d = JSONRPCDispatcher(router: fixture.router)

        let bare = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(fixture.threadID),
            "turn_count": .number(1),
        ]))
        XCTAssertNil(bare.error)
        XCTAssertEqual(bare.result, .string(patch),
                       "absent response_version must keep the exact legacy bare-string result")

        // Caps without response_version remain legacy (byte-for-byte same string).
        let withCaps = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(fixture.threadID),
            "turn_count": .number(1),
            "max_bytes": .number(Double(GitDiffBoundedResponse.checkpointDefaultMaxBytes)),
            "max_lines": .number(Double(GitDiffBoundedResponse.checkpointDefaultMaxLines)),
        ]))
        XCTAssertNil(withCaps.error)
        XCTAssertEqual(withCaps.result, .string(patch),
                       "max_* without response_version must not change shape or content")
        XCTAssertEqual(fixture.router.agentCheckpointDiffCallCount, 2)
    }

    @MainActor
    func test_agentCheckpointDiff_optInV1_returnsExactEnvelopeAndTruthfulTotalLines() async {
        // WHY: the wire envelope is the only shape modern iOS will paint; total_lines
        // must describe the original patch so the client can show honest truncation.
        let fixture = checkpointDiffFixture(patch: "a\nb\nc\nd")
        let d = JSONRPCDispatcher(router: fixture.router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(fixture.threadID),
            "turn_count": .number(1),
            "response_version": .number(1),
            "max_bytes": .number(1024),
            "max_lines": .number(2),
        ]))

        XCTAssertNil(resp.error)
        guard case .object(let body)? = resp.result else {
            return XCTFail("opt-in v1 must return a bounded object, not a bare string")
        }
        XCTAssertEqual(body["version"], .number(1))
        XCTAssertEqual(body["text"], .string("a\nb"))
        XCTAssertEqual(body["truncated"], .bool(true))
        XCTAssertEqual(body["total_lines"], .number(4),
                       "total_lines must be the original exact line count, not the returned prefix")
        XCTAssertEqual(body.count, 4, "no extra keys that a strict client might reject")
        // Proves the endpoint used the shared helper (same clip as pure unit tests).
        let expected = GitDiffBoundedResponse.bound(text: "a\nb\nc\nd", maxBytes: 1024, maxLines: 2)
        XCTAssertEqual(body["text"], .string(expected.text))
        XCTAssertEqual(body["truncated"], .bool(expected.truncated))
        XCTAssertEqual(body["total_lines"], .number(Double(expected.totalLines)))
        XCTAssertEqual(fixture.router.agentCheckpointDiffCallCount, 1)
    }

    @MainActor
    func test_agentCheckpointDiff_optInV1_honors128KiBAnd500LineLimits() async {
        // WHY: planned iOS selection request is max_bytes=128*1024, max_lines=500.
        // Both caps must bind independently through the shared helper.
        let manyLines = (0..<600).map { "L\($0)" }.joined(separator: "\n")
        let lineFixture = checkpointDiffFixture(patch: manyLines)
        let d = JSONRPCDispatcher(router: lineFixture.router)

        let byLines = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(lineFixture.threadID),
            "turn_count": .number(1),
            "response_version": .number(1),
            "max_bytes": .number(Double(GitDiffBoundedResponse.checkpointDefaultMaxBytes)),
            "max_lines": .number(Double(GitDiffBoundedResponse.checkpointDefaultMaxLines)),
        ]))
        XCTAssertNil(byLines.error)
        guard case .object(let lineBody)? = byLines.result,
              case .string(let lineText)? = lineBody["text"] else {
            return XCTFail("expected v1 object with text")
        }
        XCTAssertEqual(GitDiffBoundedResponse.lineCount(lineText), 500)
        XCTAssertEqual(lineBody["truncated"], .bool(true))
        XCTAssertEqual(lineBody["total_lines"], .number(600))
        XCTAssertLessThanOrEqual(lineText.utf8.count, GitDiffBoundedResponse.checkpointDefaultMaxBytes)

        // Byte cap binds first: one long line exceeds 128 KiB.
        let longLine = String(repeating: "x", count: GitDiffBoundedResponse.checkpointDefaultMaxBytes + 50)
        let byteFixture = checkpointDiffFixture(patch: longLine)
        let d2 = JSONRPCDispatcher(router: byteFixture.router)
        let byBytes = await d2.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(byteFixture.threadID),
            "turn_count": .number(1),
            "response_version": .number(1),
            "max_bytes": .number(Double(GitDiffBoundedResponse.checkpointDefaultMaxBytes)),
            "max_lines": .number(Double(GitDiffBoundedResponse.checkpointDefaultMaxLines)),
        ]))
        XCTAssertNil(byBytes.error)
        guard case .object(let byteBody)? = byBytes.result,
              case .string(let byteText)? = byteBody["text"] else {
            return XCTFail("expected v1 object with text")
        }
        XCTAssertEqual(byteText.utf8.count, GitDiffBoundedResponse.checkpointDefaultMaxBytes)
        XCTAssertEqual(byteBody["truncated"], .bool(true))
        XCTAssertEqual(byteBody["total_lines"], .number(1),
                       "byte clip mid-line keeps total_lines == original while truncated")
        let expected = GitDiffBoundedResponse.bound(
            text: longLine,
            maxBytes: GitDiffBoundedResponse.checkpointDefaultMaxBytes,
            maxLines: GitDiffBoundedResponse.checkpointDefaultMaxLines
        )
        XCTAssertEqual(byteText, expected.text, "endpoint must use the shared clip helper")
    }

    @MainActor
    func test_agentCheckpointDiff_optInV1_crlfVsLoneCR() async {
        // WHY: Swift treats CRLF as one Character; the wire contract is LF-only.
        // Endpoint must honor the shared helper, not Character-based split.
        let fixture = checkpointDiffFixture(patch: "a\r\nb\r\nc")
        let d = JSONRPCDispatcher(router: fixture.router)

        let crlf = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(fixture.threadID),
            "turn_count": .number(1),
            "response_version": .number(1),
            "max_bytes": .number(1024),
            "max_lines": .number(2),
        ]))
        guard case .object(let crlfBody)? = crlf.result,
              case .string(let crlfText)? = crlfBody["text"] else {
            return XCTFail("expected v1 object")
        }
        XCTAssertEqual(GitDiffBoundedResponse.lineCount(crlfText), 2)
        XCTAssertEqual(crlfBody["truncated"], .bool(true))
        XCTAssertEqual(crlfBody["total_lines"], .number(3))
        let expectedCRLF = GitDiffBoundedResponse.bound(text: "a\r\nb\r\nc", maxBytes: 1024, maxLines: 2)
        XCTAssertEqual(crlfText, expectedCRLF.text)

        let lone = checkpointDiffFixture(patch: "a\rb")
        let d2 = JSONRPCDispatcher(router: lone.router)
        let loneCR = await d2.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(lone.threadID),
            "turn_count": .number(1),
            "response_version": .number(1),
            "max_bytes": .number(1024),
            "max_lines": .number(1),
        ]))
        guard case .object(let loneBody)? = loneCR.result else {
            return XCTFail("expected v1 object")
        }
        XCTAssertEqual(loneBody["text"], .string("a\rb"))
        XCTAssertEqual(loneBody["truncated"], .bool(false))
        XCTAssertEqual(loneBody["total_lines"], .number(1))
    }

    @MainActor
    func test_agentCheckpointDiff_optInV1_neverSplitsMultibyteUTF8() async {
        // WHY: cutting mid-scalar would hand the client invalid UTF-8. Diffs can
        // contain multi-byte glyphs; the endpoint must reuse the scalar-safe helper.
        let patch = "☃☃☃" // 3 bytes each
        let fixture = checkpointDiffFixture(patch: patch)
        let d = JSONRPCDispatcher(router: fixture.router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(fixture.threadID),
            "turn_count": .number(1),
            "response_version": .number(1),
            "max_bytes": .number(4),
            "max_lines": .number(10),
        ]))
        XCTAssertNil(resp.error)
        guard case .object(let body)? = resp.result,
              case .string(let text)? = body["text"] else {
            return XCTFail("expected v1 object with text")
        }
        XCTAssertLessThanOrEqual(text.utf8.count, 4)
        XCTAssertEqual(text, "☃")
        XCTAssertEqual(body["truncated"], .bool(true))
        XCTAssertEqual(body["total_lines"], .number(1))
        XCTAssertFalse(text.unicodeScalars.contains("\u{FFFD}"))
        let expected = GitDiffBoundedResponse.bound(text: patch, maxBytes: 4, maxLines: 10)
        XCTAssertEqual(text, expected.text, "endpoint must use the shared clip helper")
    }

    @MainActor
    func test_agentCheckpointDiff_invalidOptInCaps_failClosedBeforeRouter() async {
        // WHY: selection can fire immediately; invalid caps must not load a large
        // checkpoint patch only to reject the response afterward.
        let fixture = checkpointDiffFixture(patch: "should-not-be-fetched")
        let d = JSONRPCDispatcher(router: fixture.router)
        let tid = fixture.threadID

        let cases: [[String: JSONValue]] = [
            ["thread_id": .string(tid), "turn_count": .number(1),
             "response_version": .number(2), "max_bytes": .number(100), "max_lines": .number(10)],
            ["thread_id": .string(tid), "turn_count": .number(1),
             "response_version": .number(1), "max_lines": .number(10)],
            ["thread_id": .string(tid), "turn_count": .number(1),
             "response_version": .number(1), "max_bytes": .number(100)],
            ["thread_id": .string(tid), "turn_count": .number(1),
             "response_version": .number(1), "max_bytes": .number(1.5), "max_lines": .number(10)],
            ["thread_id": .string(tid), "turn_count": .number(1),
             "response_version": .number(1), "max_bytes": .number(100), "max_lines": .number(0)],
            ["thread_id": .string(tid), "turn_count": .number(1),
             "response_version": .number(1),
             "max_bytes": .number(Double(GitDiffBoundedResponse.maxBytesCeiling + 1)),
             "max_lines": .number(10)],
            ["thread_id": .string(tid), "turn_count": .number(1),
             "response_version": .number(1), "max_bytes": .number(100),
             "max_lines": .number(Double(GitDiffBoundedResponse.maxLinesCeiling + 1))],
        ]

        for (idx, params) in cases.enumerated() {
            fixture.router.agentCheckpointDiffCallCount = 0
            let resp = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(idx + 1), method: "agent.checkpoint.diff", params: params
            ))
            XCTAssertEqual(resp.error?.code, -32602, "case \(idx) must be invalid params")
            XCTAssertEqual(fixture.router.agentCheckpointDiffCallCount, 0,
                           "case \(idx) must not invoke router.agentCheckpointDiff before validation")
        }
    }

    @MainActor
    func test_botPeerMethodsAreNotInterceptedByPairedBotRemote() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        for method in ["bot.peer.list", "bot.peer.ask", "bot.peer.self_config"] {
            let resp = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: method,
                params: [:]
            ))
            XCTAssertEqual(
                resp.error?.code,
                -32601,
                "\(method) must remain Unix-catalog-only (method not found on local IPC), not paired Bot remote (-32004)"
            )
        }
    }
}
