import Foundation
import CoreModel
import Persistence
import AgentRuntime
import RemoteCodeTreaty

public struct AgentActiveRunSnapshot: Sendable, Equatable {
    public let runId: AgentRunID
    public let startedAt: Date

    public init(runId: AgentRunID, startedAt: Date) {
        self.runId = runId
        self.startedAt = startedAt
    }
}

public struct AgentActiveDelegationSnapshot: Sendable, Equatable {
    public let threadId: AgentThreadID
    public let runId: AgentRunID
    public let hostId: String
    public let capability: String
    public let expiresAt: Date

    public init(
        threadId: AgentThreadID,
        runId: AgentRunID,
        hostId: String,
        capability: String,
        expiresAt: Date
    ) {
        self.threadId = threadId
        self.runId = runId
        self.hostId = hostId
        self.capability = capability
        self.expiresAt = expiresAt
    }
}

public struct AgentThreadMirrorSnapshot: Sendable, Equatable {
    public let events: [AssistantEvent]
    public let eventWatermark: Int64
    /// True when older source rows exist beyond this window (count probe and/or
    /// byte selection). Always false for unbounded legacy reads.
    public let sourceHadOlderEvents: Bool
    /// Populated when the newest persisted row exceeds the byte cap and was
    /// never decoded. Clients use this for a dedicated hydration path.
    public let blockedEvent: BlockedMirrorEvent?

    public struct BlockedMirrorEvent: Sendable, Equatable {
        public let id: Int64
        public let payloadBytes: Int64
        public let reason: String

        public init(id: Int64, payloadBytes: Int64, reason: String) {
            self.id = id
            self.payloadBytes = payloadBytes
            self.reason = reason
        }
    }

    public init(
        events: [AssistantEvent],
        eventWatermark: Int64,
        sourceHadOlderEvents: Bool = false,
        blockedEvent: BlockedMirrorEvent? = nil
    ) {
        self.events = events
        self.eventWatermark = eventWatermark
        self.sourceHadOlderEvents = sourceHadOlderEvents
        self.blockedEvent = blockedEvent
    }
}

public struct AgentRoutingRequest: Sendable, Equatable {
    public let mode: AgentRoutingMode
    public let expectedRevision: Int
    public let manualSelection: AgentModelSelection?
    public let eligibleProviders: [AgentProvider]?
    public let policyDigest: String?

    public init(
        mode: AgentRoutingMode,
        expectedRevision: Int,
        manualSelection: AgentModelSelection? = nil,
        eligibleProviders: [AgentProvider]? = nil,
        policyDigest: String? = nil
    ) {
        self.mode = mode
        self.expectedRevision = expectedRevision
        self.manualSelection = manualSelection
        self.eligibleProviders = eligibleProviders
        self.policyDigest = policyDigest
    }
}

@MainActor
public protocol CommandRouting: AnyObject {
    // window/workspace/pane/surface
    func listWorkspaces() throws -> [Workspace]
    func listWorkspacesAuthoritative() async throws -> [Workspace]
    func currentWindow() throws -> AppWindow
    func listWindows() throws -> [AppWindow]
    func createWindow(title: String?) throws -> AppWindow
    func focusWindow(_ id: WindowID) throws
    func closeWindow(_ id: WindowID) throws
    func moveWorkspaceToWindow(workspace: WorkspaceID, target: WindowID) throws
    func paneSwap(workspace: WorkspaceID, a: PaneID, b: PaneID) throws
    func createWorkspace(name: String, cwd: String) throws -> Workspace
    func selectWorkspace(_ id: WorkspaceID) throws
    func closeWorkspace(_ id: WorkspaceID, publishEvent: Bool) throws
    func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws
    func setWorkspaceDescription(_ id: WorkspaceID, _ text: String) throws
    func setWorkspaceColor(_ id: WorkspaceID, _ color: String) throws
    func setWorkspacePinned(_ id: WorkspaceID, _ pinned: Bool) throws
    func reorderWorkspace(_ id: WorkspaceID, position: Int) throws
    func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor
    func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor
    func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor
    func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor
    func splitSurface(workspace: WorkspaceID, paneID: PaneID, surface: SurfaceID, direction: SplitDirection) throws
    func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws
    func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws
    func renameSurface(_ wid: WorkspaceID, _ sid: SurfaceID, _ title: String) throws
    func setSurfaceColor(_ wid: WorkspaceID, _ sid: SurfaceID, _ color: String) throws
    func sendText(surface: SurfaceID, text: String) throws
    func readText(surface: SurfaceID) throws -> String
    func readTerminalHistory(surface: SurfaceID, beforeChunkID: Int64?, maxBytes: Int) async throws -> TerminalOutputWindow
    func surfaceHealth(surface: SurfaceID) -> Bool
    func surfaceClearHistory(surface: SurfaceID)
    // SSH
    func sshHostList(workspace: WorkspaceID) throws -> [SSHHostProfile]
    func sshHostUpsert(_ profile: SSHHostProfile, workspace: WorkspaceID) throws -> SSHHostProfile
    func sshHostDelete(_ id: SSHHostID, workspace: WorkspaceID) throws
    func sshConnect(workspace: WorkspaceID, profileID: SSHHostID?, profile: SSHHostProfile?, title: String?, paneID: PaneID?) throws -> SurfaceDescriptor
    func sshDisconnect(surface: SurfaceID) throws
    func sshTransferUpload(surface: SurfaceID, localPath: String, remotePath: String) throws -> JSONValue
    func sshTransferDownload(surface: SurfaceID, remotePath: String, localPath: String) throws -> JSONValue
    func sshTransferUploadAsync(surface: SurfaceID, localPath: String, remotePath: String) async throws -> JSONValue
    func sshTransferDownloadAsync(surface: SurfaceID, remotePath: String, localPath: String) async throws -> JSONValue
    func sshFilesLocalList(path: String?) throws -> JSONValue
    func sshFilesRemoteList(surface: SurfaceID, path: String?) throws -> JSONValue
    func sshFilesRemoteListAsync(surface: SurfaceID, path: String?) async throws -> JSONValue
    func sshFilesRemoteManage(surface: SurfaceID, operation: SSHRemoteFileOperation) async throws -> JSONValue
    // agent
    func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor
    func activityList(params: [String: JSONValue]) throws -> JSONValue
    func activityListOffMain(params: [String: JSONValue]) async throws -> JSONValue
    func activitySetViewed(params: [String: JSONValue]) throws -> JSONValue
    func activityAcknowledge(params: [String: JSONValue]) throws -> JSONValue
    /// `scheduled_task.*`: Schedule Tasks for the paired iPhone (capability `agent.scheduled_tasks_v1`).
    func listScheduledTasksRemote() throws -> JSONValue
    func saveScheduledTaskRemote(params: [String: JSONValue]) async throws -> JSONValue
    func deleteScheduledTaskRemote(id: UUID) throws -> JSONValue
    func enableScheduledTaskRemote(id: UUID, enabled: Bool) async throws -> JSONValue
    func runScheduledTaskRemote(id: UUID) throws -> JSONValue
    /// Sticky account usage digest for deterministic iOS pull (deprecated
    /// `token_saver.digest.get` name kept until iOS bumps its treaty pin).
    func tokenSaverDigest() -> JSONValue?
    func setAgentWorkerModel(thread: AgentThreadID, model: String?) throws -> AgentThread
    func listDistillAccounts() async -> JSONValue
    func getDistillRouting() async throws -> JSONValue
    func mutateDistillAccount(method: String, accountID: String?, provider: DistillAccountProvider?, label: String?) throws -> JSONValue
    func setDistillRouting(_ routing: DistillAutoRouting) throws -> JSONValue
    func loginDistillAccount(_ provider: DistillAccountProvider) throws -> JSONValue
    func logoutDistillAccount(_ provider: DistillAccountProvider) throws -> JSONValue
    func cancelDistillAccountOperation() throws -> JSONValue
    func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread]
    func listAgentThreadsOffMain(workspace: WorkspaceID?) async throws -> [AgentThread]
    func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?, surfaceID: SurfaceID?) throws -> AgentThread
    func createAgentThreadRouting(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?, surfaceID: SurfaceID?, routing: AgentRoutingRequest?, nestedRunContext: AgentNestedRunContext?) async throws -> AgentThread
    func forkAgentThread(sourceThreadId: AgentThreadID, messageID: String?) async throws -> AgentThread
    func sideAgentThread(sourceThreadId: AgentThreadID, text: String?) async throws -> AgentThread
    func closeSideThread(threadId: AgentThreadID) async throws
    func btwAgentThread(threadId: AgentThreadID, question: String) async throws -> String
    func configureAgentThread(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?) throws -> AgentThread
    func configureAgentThreadRouting(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?, routing: AgentRoutingRequest?) async throws -> AgentThread
    func listAgentRunAsUsers() throws -> [AgentRunAsUser]
    func configureAgentThreadExecution(thread: AgentThreadID, executionMode: AgentExecutionMode, baseBranch: String?) throws -> AgentThread
    func prepareAgentThreadForPullRequest(workspace: WorkspaceID, url: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?) throws -> AgentThread
    func uploadAgentAttachment(workspace: WorkspaceID, filename: String, mimeType: String?, dataBase64: String) throws -> AgentAttachmentUploadResult
    func importAgentAttachment(workspace: WorkspaceID, relativePath: String) throws -> AgentAttachmentUploadResult
    func selectAgentThread(thread: AgentThreadID, surfaceID: SurfaceID?) throws
    func listAgentMessages(thread: AgentThreadID, limit: Int) throws -> [AgentMessage]
    func listAgentMessagesOffMain(thread: AgentThreadID, limit: Int) async throws -> [AgentMessage]
    func listAgentMessagesPage(thread: AgentThreadID, limit: Int, before: AgentMessageCursor?, after: AgentMessageCursor?) throws -> AgentMessagePage
    func listAgentMessagesPageOffMain(thread: AgentThreadID, limit: Int, before: AgentMessageCursor?, after: AgentMessageCursor?) async throws -> AgentMessagePage
    /// Body-budgeted keyset page used by `agent.message.list` response_version=1.
    /// Hosts with SQLite should override to call `listPageWithinBodyBudget`; the
    /// protocol extension provides an in-memory default for test conformers.
    func listAgentMessagesWithinBodyBudget(
        thread: AgentThreadID,
        limit: Int,
        before: AgentMessageCursor?,
        after: AgentMessageCursor?,
        budget: Int,
        contentLimit: Int
    ) throws -> AgentMessageBodyBudgetResult
    func listAgentMessagesWithinBodyBudgetOffMain(
        thread: AgentThreadID,
        limit: Int,
        before: AgentMessageCursor?,
        after: AgentMessageCursor?,
        budget: Int,
        contentLimit: Int
    ) async throws -> AgentMessageBodyBudgetResult
    /// PERF-007: returns the set of thread IDs that have at least one message, via a
    /// single SQL query. Used by agent.thread.list to derive provider_locked for every
    /// thread without issuing one query per thread.
    func threadIdsWithMessages() throws -> Set<AgentThreadID>
    func threadIdsWithMessagesOffMain() async throws -> Set<AgentThreadID>
    /// Existence only for `provider_locked` on single-thread payloads.
    /// `agent.thread.list` uses `threadIdsWithMessages()` once instead.
    func agentThreadHasMessages(thread: AgentThreadID) throws -> Bool
    func getAgentMessage(id: AgentMessageID) throws -> AgentMessage?
    func getAgentMessageBodyChunk(
        id: AgentMessageID,
        offsetBytes: Int,
        maxContentBytes: Int,
        expectedBodyRevision: Int?,
        expectedBodySHA256: String?
    ) throws -> AgentMessageBodyChunk?
    func listAgentQueuedMessages(thread: AgentThreadID) throws -> [AgentQueuedMessage]
    func listAgentQueuedMessagesOffMain(thread: AgentThreadID) async throws -> [AgentQueuedMessage]
    func updateAgentQueuedMessage(id: AgentQueuedMessageID, text: String, attachments: [AgentAttachment]) async throws -> AgentQueuedMessage
    func cancelAgentQueuedMessage(id: AgentQueuedMessageID) throws -> AgentQueuedMessage
    func forceAgentQueuedMessageNow(id: AgentQueuedMessageID) async throws -> AgentMessageSendResult
    /// Moves a queued message to `position` (0-based target index) within its
    /// thread's queue, renumbering every affected message — the same repo
    /// mutation the mac queue drag-reorder performs.
    func reorderAgentQueuedMessage(thread: AgentThreadID, id: AgentQueuedMessageID, position: Int) throws
    func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, interactionMode: AgentInteractionMode?, modelSelection: AgentModelSelection?, providerInstanceId: String?, attachments: [AgentAttachment]) async throws -> AgentMessageSendResult
    func sendAgentMessageRouting(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, interactionMode: AgentInteractionMode?, modelSelection: AgentModelSelection?, providerInstanceId: String?, attachments: [AgentAttachment], routing: AgentRoutingRequest?, nestedRunContext: AgentNestedRunContext?) async throws -> AgentMessageSendResult
    func listBotPeers(callerThread: AgentThreadID, callerRun: AgentRunID, delegationCapability: String?) throws -> JSONValue
    func askBotPeer(callerThread: AgentThreadID, callerRun: AgentRunID, handle: String, prompt: String, replyMode: BotPeerDelegation.ReplyMode, delegationCapability: String?) async throws -> JSONValue
    func askBotPeer(callerThread: AgentThreadID, callerRun: AgentRunID, handle: String, prompt: String, replyMode: BotPeerDelegation.ReplyMode, consultationID: UUID?, delegationCapability: String?) async throws -> JSONValue
    func askBotPeer(callerThread: AgentThreadID, callerRun: AgentRunID, handle: String, prompt: String, replyMode: BotPeerDelegation.ReplyMode, consultationID: UUID?, wait: Bool, delegationCapability: String?) async throws -> JSONValue
    func observeBotPeer(callerThread: AgentThreadID, callerRun: AgentRunID, activityID: UUID, wait: Bool, cancel: Bool, delegationCapability: String?) async throws -> JSONValue
    func validateBotPeerReceipt(callerThread: AgentThreadID, result: JSONValue) throws
    func invokeDelegatedBotSelfConfig(callerThread: AgentThreadID, callerRun: AgentRunID, toolName: String, arguments: [String: JSONValue], delegationCapability: String?) throws -> JSONValue
    func authenticateManagedHostCall(threadID: AgentThreadID, runID: AgentRunID, delegationCapability: String?, mutation: Bool, method: String) throws
    /// True when the thread belongs to Titio, the only caller admitted to `host.call`.
    func managedHostCallerIsTitio(threadID: AgentThreadID) throws -> Bool
    func createHostBot(name: String, title: String, description: String, handle: String?, soul: String, callerRun: AgentRunID) throws -> JSONValue
    func listHostBots() throws -> JSONValue
    func openHostBot(botID: BotID) throws -> JSONValue
    func sendHostBot(botID: BotID, text: String, conversationID: BotConversationID?, callerThread: AgentThreadID, callerRun: AgentRunID) async throws -> JSONValue
    func createHostBotThread(botID: BotID, title: String) throws -> JSONValue
    func listHostActivity(params: [String: JSONValue]) async throws -> JSONValue
    func delegateHostBot(bot: String, text: String, conversationID: BotConversationID?, callerThread: AgentThreadID, callerRun: AgentRunID) async throws -> JSONValue
    func runNextHostScheduledTask(workspace: String, taskID: UUID?) throws -> JSONValue
    func captureHostBrowserToChat(callerThread: AgentThreadID, surface: SurfaceID?, reason: String) throws -> JSONValue
    func postChatImages(callerThread: AgentThreadID, paths: [String], caption: String?) throws -> JSONValue
    func createHostBotSkill(botID: BotID, skillID: String, body: String?, callerRun: AgentRunID, callerThread: AgentThreadID) throws -> JSONValue
    func viewHostBotSkill(botID: BotID, skillID: String, callerRun: AgentRunID, callerThread: AgentThreadID) throws -> JSONValue
    func dispatchPairedBotRemote(method: String, params: [String: JSONValue]) async throws -> JSONValue
    func implementAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, newThread: Bool, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?) async throws -> (runId: AgentRunID, implementationThreadId: AgentThreadID)
    func saveAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, relativePath: String?) throws -> (path: String, relativePath: String)
    /// Per-thread plan notes (mac plan sidebar). Returns "" when none exist.
    func agentPlanNotes(thread: AgentThreadID) throws -> String
    func saveAgentPlanNotes(thread: AgentThreadID, notes: String) throws
    func commandReceipt(method: String, clientRequestId: String) -> JSONValue?
    func recordCommandReceipt(method: String, clientRequestId: String, result: JSONValue)
    func respondAgentRequest(thread: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws
    func respondAgentUserInput(thread: AgentThreadID, requestId: String, text: String) async throws
    func listAgentPendingCallbacks(thread: AgentThreadID) throws -> AssistantPendingCallbacksSnapshot
    func listAgentPendingCallbacksOffMain(thread: AgentThreadID) async throws -> AssistantPendingCallbacksSnapshot
    func readAgentThreadEvents(thread: AgentThreadID) async throws -> [AssistantEvent]
    /// Mirror recovery snapshot.
    /// - Legacy (`eventRowLimit`/`maxPayloadBytes` both nil): full unbounded decode.
    /// - v1: metadata-first selection with both limits; oversized newest is never decoded.
    func readAgentThreadMirrorSnapshot(
        thread: AgentThreadID,
        eventRowLimit: Int?,
        maxPayloadBytes: Int64?
    ) async throws -> AgentThreadMirrorSnapshot
    func rollbackAgentThread(thread: AgentThreadID, toTurnId: String) async throws
    func listAgentThreadCheckpoints(thread: AgentThreadID) throws -> [AgentTurnCheckpointSummary]
    /// Metadata page for `agent.checkpoint.list` response_version 1.
    /// Must hop off MainActor for SQLite query/decode (see AgentTurnCheckpointListGateway).
    /// `expectedCatalogRevision` is preclaimed inside the read snapshot before page scan.
    func listAgentThreadCheckpointsPage(
        thread: AgentThreadID,
        maxEntries: Int,
        before: AgentTurnCheckpointCursor?,
        expectedCatalogRevision: Int64?
    ) async throws -> AgentTurnCheckpointPage
    func agentCheckpointDiff(thread: AgentThreadID, checkpointTurnCount: Int, expectedRunID: UUID?, path: String?) throws -> String
    func revertAgentThreadToCheckpoint(thread: AgentThreadID, checkpointTurnCount: Int) async throws -> AgentTurnCheckpointSummary
    func stopAgentRun(thread: AgentThreadID) throws
    func activeAgentRun(thread: AgentThreadID) throws -> AgentActiveRunSnapshot?
    func activeAgentDelegation(
        thread: AgentThreadID,
        run: AgentRunID
    ) throws -> AgentActiveDelegationSnapshot?
    /// Resume a relaunch-interrupted thread (the mac Continue button path):
    /// the coordinator replays the saved resume cursor without a new user
    /// message. Returns the new run id when one started.
    func continueAgentRun(thread: AgentThreadID) async throws -> AgentRunID?
    func deleteAgentThread(thread: AgentThreadID) async throws
    func deleteAgentThreads(_ threads: [AgentThreadID]) async throws
    func renameAgentThread(thread: AgentThreadID, title: String) throws -> AgentThread
    /// Distill `/loop` state folded for a thread (empty when none).
    func threadLoops(thread: AgentThreadID) -> [DistillLoopState]
    /// `agent.thread.loop.stop`: deletes the scheduled task in the thread's live agent session.
    func stopThreadLoop(thread: AgentThreadID, taskId: String) async throws -> Bool
    func setAgentThreadPinned(thread: AgentThreadID, pinned: Bool) throws -> AgentThread
    func setAgentThreadColor(thread: AgentThreadID, color: String) throws -> AgentThread
    func reorderAgentThread(thread: AgentThreadID, position: Int) throws -> [AgentThread]
    func markAgentThreadRead(thread: AgentThreadID) throws
    func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor]
    func listAgentProviderSnapshots() async -> [AgentProviderSnapshot]
    func updateAgentProvider(provider: AgentProvider, providerInstanceId: String?) async throws -> JSONValue
    func agentPromptHistory(workspace: WorkspaceID?, limit: Int) throws -> [String]
    // git
    func gitStatus(workspace: WorkspaceID) throws -> GitSummary
    func gitBranches(workspace: WorkspaceID) throws -> GitBranches
    func gitCheckout(workspace: WorkspaceID, branch: String) throws -> GitActionResult
    func gitCreateBranch(workspace: WorkspaceID, name: String) throws -> GitActionResult
    func gitCommit(workspace: WorkspaceID, message: String) throws -> GitActionResult
    func gitLog(workspace: WorkspaceID, limit: Int) throws -> [GitCommit]
    func gitDiff(workspace: WorkspaceID, path: String?, ignoreWhitespace: Bool) throws -> String
    func gitPush(workspace: WorkspaceID) throws -> GitActionResult
    func gitFetch(workspace: WorkspaceID) throws -> GitActionResult
    func gitPull(workspace: WorkspaceID) throws -> GitActionResult
    func ensureGitSurface(workspace: WorkspaceID) throws -> SurfaceDescriptor
    func gitPullRequestURL(workspace: WorkspaceID) throws -> String?
    func gitDeliveryPlan(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryPlan
    func gitDeliver(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryResult
    // project scripts / open-in-editor (RC2-069)
    func projectScripts(workspace: WorkspaceID) throws -> [ProjectScript]
    func projectRunScript(workspace: WorkspaceID, name: String) throws -> SurfaceDescriptor
    func projectOpenInEditor(workspace: WorkspaceID) throws -> String
    // browser P0
    func browserNavigate(surface: SurfaceID, url: String) throws
    func browserBack(surface: SurfaceID) throws
    func browserForward(surface: SurfaceID) throws
    func browserReload(surface: SurfaceID) throws
    func browserStop(surface: SurfaceID) throws
    func browserURL(surface: SurfaceID) throws -> String
    func browserMirrorURL(surface: SurfaceID) throws -> [String: JSONValue]
    func browserEval(surface: SurfaceID, script: String) async throws -> String
    func browserScreenshot(surface: SurfaceID, savePath: String?) throws -> String
    func browserSnapshot(surface: SurfaceID) async throws -> String
    func browserAction(surface: SurfaceID, kind: String, ref: String, value: String?) async throws -> String
    func browserWait(surface: SurfaceID, selector: String, timeoutMs: Int) async throws -> String
    // pane / window
    func paneList(workspace: WorkspaceID) throws -> [[String: JSONValue]]
    func paneSurfaces(pane: PaneID, workspace: WorkspaceID) throws -> [SurfaceDescriptor]
    func paneResize(workspace: WorkspaceID, splitID: UUID, ratios: [Double]) throws
    func surfaceMove(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID) throws
    func surfaceReorder(workspace: WorkspaceID, surface: SurfaceID, toPane: PaneID, position: Int) throws
    // notifications
    func notificationCreate(workspaceId: WorkspaceID?, surfaceId: SurfaceID?, title: String, body: String?, category: String?) throws -> String
    func notificationList(workspaceId: WorkspaceID?, unreadOnly: Bool) throws -> [[String: JSONValue]]
    func notificationMarkRead(id: String) throws
    func notificationDismiss(id: String) throws
    func privatePushTokenUpdate(
        pushToken: String,
        pushTokenType: String,
        liveActivityToken: String?,
        deviceID: String?,
        tokenPurpose: String?,
        environment: String?,
        serverID: String?,
        bootEpoch: Int?,
        activityGeneration: Int?,
        activityID: String?,
        activitySessionID: String?,
        registrationRevision: Int?,
        contractVersion: Int?,
        capabilities: [String]?
    ) throws -> JSONValue
    func bindBotAttentionProfile(profileID: String, hostID: String, deviceID: String) throws
    /// True only when the durable push target and attention binding already
    /// hold exactly what `probe` would write. Read-only.
    func privatePushRegistrationIsCurrent(_ probe: PrivatePushRegistrationProbe) -> Bool
    // settings
    func settingsGet(keys: [String]) throws -> [String: String]
    func settingsSet(key: String, value: String) throws
    // workspace Files surface
    func filesStateGet(surface: SurfaceID) throws -> JSONValue
    func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue
    func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue
    func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue
    func fsWorkspacePreviewURL(workspace: WorkspaceID, path: String) throws -> JSONValue
    func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue
    func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue
    func fsWorkspaceDelete(workspace: WorkspaceID, paths: [String]) throws -> JSONValue
    func filesEditSession(sessionID: String) throws -> JSONValue
    func filesAIComplete(sessionID: String, draftRevision: Int, caretUTF16: Int) async throws -> JSONValue
    func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue
    func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue
    func filesEditSave(sessionID: String) throws -> JSONValue
    func filesEditDiscard(sessionID: String) throws -> JSONValue
    func filesEditClose(sessionID: String) throws -> JSONValue
    // manual actions: a bot paused for the user (login, captcha, 2FA, payment, confirm)
    /// The thread's requests, oldest first. A taken request whose control was lost reads as open.
    func listManualActions(thread: AgentThreadID) throws -> [ManualActionSnapshot]
    /// Each thread's open or taken request, for `pending_manual_action` in thread payloads.
    func pendingManualActions(for threads: [AgentThread]) -> [AgentThreadID: ManualActionSnapshot]
    /// Single-winner transition shared with the Mac card; refusals are `DefiniteMutationRejection`.
    func resolveManualAction(thread: AgentThreadID, id: UUID, resolution: ManualActionResolution, note: String?) async throws -> ManualActionResolveOutcome
    // thread actor: who runs a thread (a bot), where (VM or Mac), and the bot's "run on the Mac?" request
    /// The thread's guest runtime marker (`BotGuestRuntime`), nil when none.
    func threadGuestRuntime(thread: AgentThreadID) -> String?
    /// Every marked thread's guest runtime, read off the main actor (agent.thread.list).
    func threadGuestRuntimesOffMain() async -> [AgentThreadID: String]
    /// The bot's pending "run on the Mac?" reason for this thread, nil when none.
    func pendingMacExecutionReason(thread: AgentThreadID) -> String?
    /// Locks the thread to `actor` with the composer's lock rules; refusals are `DefiniteMutationRejection`.
    func setAgentThreadActor(thread: AgentThreadID, actor: RunActor, executionTarget: ExecutionTarget?) async throws -> AgentThread
    /// Single-winner answer to the bot's Mac-execution request, shared with the Mac banner.
    func resolveMacExecutionRemote(thread: AgentThreadID, approve: Bool) async throws -> MacExecutionResolveOutcome
    /// `message` (display text) and `recovery_action` for a replayed `.error`
    /// event (host capability `agent.run_recovery_action_v1`), from the same
    /// classifier as the live `agent.run.error` event. Empty leaves the row as stored.
    func replayedRunErrorFields(message: String, recoverable: Bool) -> [String: JSONValue]
    /// `agent.attachment.get`: one message attachment's bytes (or a JPEG
    /// thumbnail), read off the main actor with `AgentAttachmentGetWire.load`.
    func getAgentAttachment(_ request: AgentAttachmentGetWire.Request) async throws -> JSONValue
    /// `agent.message.image.get`: a downsampled Mac-local image referenced by
    /// an assistant message, read off the main actor with `AgentMessageImageGetWire.load`.
    func getAgentMessageImage(_ request: AgentMessageImageGetWire.Request) async throws -> JSONValue
    /// `agent.account.usage.get`: stored provider account usage
    /// (`AgentAccountUsageWire.load`), read off the main actor, no provider probe.
    func getAgentAccountUsage() async throws -> JSONValue
}

/// One remote file change requested from iOS for an SSH surface.
public enum SSHRemoteFileOperation: Sendable, Equatable {
    case mkdir(path: String)
    case rename(from: String, to: String)
    case delete(path: String)

    public var method: String {
        switch self {
        case .mkdir: return "ssh.files.remote.mkdir"
        case .rename: return "ssh.files.remote.rename"
        case .delete: return "ssh.files.remote.delete"
        }
    }

    public var paths: [String] {
        switch self {
        case .mkdir(let path), .delete(let path): return [path]
        case .rename(let from, let to): return [from, to]
        }
    }
}

public extension CommandRouting {
    func filesAIComplete(sessionID: String, draftRevision: Int, caretUTF16: Int) async throws -> JSONValue {
        throw JSONRPCError.notSupported("files.ai.complete")
    }
    func threadLoops(thread: AgentThreadID) -> [DistillLoopState] { [] }
    func stopThreadLoop(thread: AgentThreadID, taskId: String) async throws -> Bool { throw JSONRPCError.notSupported("agent.thread.loop.stop") }
    func activityList(params: [String: JSONValue]) throws -> JSONValue { throw JSONRPCError.notSupported("agent.activity.list") }
    func captureHostBrowserToChat(callerThread: AgentThreadID, surface: SurfaceID?, reason: String) throws -> JSONValue { throw JSONRPCError.notSupported("host.browser.screenshot") }
    func postChatImages(callerThread: AgentThreadID, paths: [String], caption: String?) throws -> JSONValue { throw JSONRPCError.notSupported("host.chat.image") }
    func activityListOffMain(params: [String: JSONValue]) async throws -> JSONValue { try activityList(params: params) }
    func activitySetViewed(params: [String: JSONValue]) throws -> JSONValue { throw JSONRPCError.notSupported("agent.activity.viewed.set") }
    func activityAcknowledge(params: [String: JSONValue]) throws -> JSONValue { throw JSONRPCError.notSupported("agent.activity.acknowledge") }
    func listScheduledTasksRemote() throws -> JSONValue { throw JSONRPCError.notSupported("scheduled_task.list") }
    func saveScheduledTaskRemote(params: [String: JSONValue]) async throws -> JSONValue { throw JSONRPCError.notSupported("scheduled_task.save") }
    func deleteScheduledTaskRemote(id: UUID) throws -> JSONValue { throw JSONRPCError.notSupported("scheduled_task.delete") }
    func enableScheduledTaskRemote(id: UUID, enabled: Bool) async throws -> JSONValue { throw JSONRPCError.notSupported("scheduled_task.enable") }
    func runScheduledTaskRemote(id: UUID) throws -> JSONValue { throw JSONRPCError.notSupported("scheduled_task.run") }
    func listManualActions(thread: AgentThreadID) throws -> [ManualActionSnapshot] { [] }
    func pendingManualActions(for threads: [AgentThread]) -> [AgentThreadID: ManualActionSnapshot] { [:] }
    func resolveManualAction(thread: AgentThreadID, id: UUID, resolution: ManualActionResolution, note: String?) async throws -> ManualActionResolveOutcome {
        throw JSONRPCError.notSupported("agent.manual_action.resolve")
    }
    func threadGuestRuntime(thread: AgentThreadID) -> String? { nil }
    func threadGuestRuntimesOffMain() async -> [AgentThreadID: String] { [:] }
    func pendingMacExecutionReason(thread: AgentThreadID) -> String? { nil }
    func setAgentThreadActor(thread: AgentThreadID, actor: RunActor, executionTarget: ExecutionTarget?) async throws -> AgentThread {
        throw JSONRPCError.notSupported("agent.thread.actor.set")
    }
    func resolveMacExecutionRemote(thread: AgentThreadID, approve: Bool) async throws -> MacExecutionResolveOutcome {
        throw JSONRPCError.notSupported("agent.mac_execution.resolve")
    }
    func replayedRunErrorFields(message: String, recoverable: Bool) -> [String: JSONValue] { [:] }
    func getAgentAttachment(_ request: AgentAttachmentGetWire.Request) async throws -> JSONValue {
        throw JSONRPCError.notSupported("agent.attachment.get")
    }
    func getAgentMessageImage(_ request: AgentMessageImageGetWire.Request) async throws -> JSONValue {
        throw JSONRPCError.notSupported("agent.message.image.get")
    }
    func getAgentAccountUsage() async throws -> JSONValue {
        throw JSONRPCError.notSupported("agent.account.usage.get")
    }
    func forkAgentThread(sourceThreadId: AgentThreadID, messageID: String?) async throws -> AgentThread {
        throw JSONRPCError.notSupported("agent.thread.fork")
    }
    func sideAgentThread(sourceThreadId: AgentThreadID, text: String?) async throws -> AgentThread {
        throw JSONRPCError.notSupported("agent.thread.side")
    }
    func closeSideThread(threadId: AgentThreadID) async throws {
        throw JSONRPCError.notSupported("agent.thread.side.close")
    }
    func btwAgentThread(threadId: AgentThreadID, question: String) async throws -> String {
        throw JSONRPCError.notSupported("agent.thread.btw")
    }

    func sshTransferUploadAsync(surface: SurfaceID, localPath: String, remotePath: String) async throws -> JSONValue {
        try sshTransferUpload(surface: surface, localPath: localPath, remotePath: remotePath)
    }
    func sshTransferDownloadAsync(surface: SurfaceID, remotePath: String, localPath: String) async throws -> JSONValue {
        try sshTransferDownload(surface: surface, remotePath: remotePath, localPath: localPath)
    }
    func sshFilesRemoteListAsync(surface: SurfaceID, path: String?) async throws -> JSONValue {
        try sshFilesRemoteList(surface: surface, path: path)
    }
    func sshFilesRemoteManage(surface: SurfaceID, operation: SSHRemoteFileOperation) async throws -> JSONValue {
        throw JSONRPCError.notSupported(operation.method)
    }
    func gitFetch(workspace: WorkspaceID) throws -> GitActionResult { throw JSONRPCError.notSupported("git.fetch") }
    func gitPull(workspace: WorkspaceID) throws -> GitActionResult { throw JSONRPCError.notSupported("git.pull") }

    /// Test/fake hosts may omit the account usage digest entirely.
    func tokenSaverDigest() -> JSONValue? { nil }
    func setAgentWorkerModel(thread: AgentThreadID, model: String?) throws -> AgentThread { throw JSONRPCError.notSupported("Worker model selection") }
    func listDistillAccounts() async -> JSONValue { .object(["accounts": .array([]), "routing": .null, "busy": .bool(false), "busy_account_id": .null, "busy_provider": .null, "last_error": .null]) }
    func getDistillRouting() async throws -> JSONValue { .null }
    func mutateDistillAccount(method: String, accountID: String?, provider: DistillAccountProvider?, label: String?) throws -> JSONValue { throw JSONRPCError.notSupported("Distill account management") }
    func setDistillRouting(_ routing: DistillAutoRouting) throws -> JSONValue { throw JSONRPCError.notSupported("Distill Auto routing") }
    func loginDistillAccount(_ provider: DistillAccountProvider) throws -> JSONValue { throw JSONRPCError.notSupported("Distill account management") }
    func logoutDistillAccount(_ provider: DistillAccountProvider) throws -> JSONValue { throw JSONRPCError.notSupported("Distill account management") }
    func cancelDistillAccountOperation() throws -> JSONValue { throw JSONRPCError.notSupported("Distill account management") }

    func bindBotAttentionProfile(profileID: String, hostID: String, deviceID: String) throws {}
    func privatePushRegistrationIsCurrent(_ probe: PrivatePushRegistrationProbe) -> Bool { false }

    func agentThreadHasMessages(thread: AgentThreadID) throws -> Bool {
        !(try listAgentMessages(thread: thread, limit: 1).isEmpty)
    }

    func closeWorkspace(_ id: WorkspaceID) throws {
        try closeWorkspace(id, publishEvent: true)
    }

    func activeAgentRun(thread: AgentThreadID) throws -> AgentActiveRunSnapshot? {
        nil
    }

    func activeAgentDelegation(
        thread: AgentThreadID,
        run: AgentRunID
    ) throws -> AgentActiveDelegationSnapshot? {
        nil
    }

    func listBotPeers(callerThread: AgentThreadID, callerRun: AgentRunID, delegationCapability: String?) throws -> JSONValue {
        throw JSONRPCError.notSupported("Bot delegation")
    }

    func askBotPeer(callerThread: AgentThreadID, callerRun: AgentRunID, handle: String, prompt: String, replyMode: BotPeerDelegation.ReplyMode, delegationCapability: String?) async throws -> JSONValue {
        throw JSONRPCError.notSupported("Bot delegation")
    }

    func askBotPeer(callerThread: AgentThreadID, callerRun: AgentRunID, handle: String, prompt: String, replyMode: BotPeerDelegation.ReplyMode, consultationID: UUID?, wait: Bool, delegationCapability: String?) async throws -> JSONValue {
        guard wait else { throw JSONRPCError.notSupported("Asynchronous Bot delegation") }
        return try await askBotPeer(callerThread: callerThread, callerRun: callerRun, handle: handle,
            prompt: prompt, replyMode: replyMode, consultationID: consultationID, delegationCapability: delegationCapability)
    }

    func observeBotPeer(callerThread: AgentThreadID, callerRun: AgentRunID, activityID: UUID, wait: Bool, cancel: Bool, delegationCapability: String?) async throws -> JSONValue {
        throw JSONRPCError.notSupported("Bot activity observation")
    }

    func validateBotPeerReceipt(callerThread: AgentThreadID, result: JSONValue) throws {
        throw JSONRPCError.notSupported("Bot receipt authorization")
    }

    func askBotPeer(callerThread: AgentThreadID, callerRun: AgentRunID, handle: String, prompt: String, replyMode: BotPeerDelegation.ReplyMode, consultationID: UUID?, delegationCapability: String?) async throws -> JSONValue {
        try await askBotPeer(
            callerThread: callerThread,
            callerRun: callerRun,
            handle: handle,
            prompt: prompt,
            replyMode: replyMode,
            delegationCapability: delegationCapability
        )
    }

    func invokeDelegatedBotSelfConfig(callerThread: AgentThreadID, callerRun: AgentRunID, toolName: String, arguments: [String: JSONValue], delegationCapability: String?) throws -> JSONValue {
        throw JSONRPCError.notSupported("delegated Bot settings")
    }

    func authenticateManagedHostCall(threadID: AgentThreadID, runID: AgentRunID, delegationCapability: String?, mutation: Bool, method: String) throws {
        throw JSONRPCError.notSupported("managed host catalog")
    }

    func managedHostCallerIsTitio(threadID: AgentThreadID) throws -> Bool { false }

    func createHostBot(name: String, title: String, description: String, handle: String?, soul: String, callerRun: AgentRunID) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot create")
    }

    func listHostBots() throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot list")
    }

    func openHostBot(botID: BotID) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot open")
    }

    func sendHostBot(botID: BotID, text: String, conversationID: BotConversationID?, callerThread: AgentThreadID, callerRun: AgentRunID) async throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot send")
    }

    func createHostBotThread(botID: BotID, title: String) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot thread create")
    }

    func listHostActivity(params: [String: JSONValue]) async throws -> JSONValue {
        throw JSONRPCError.notSupported("host activity list")
    }

    func delegateHostBot(bot: String, text: String, conversationID: BotConversationID?, callerThread: AgentThreadID, callerRun: AgentRunID) async throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot delegate")
    }

    func runNextHostScheduledTask(workspace: String, taskID: UUID?) throws -> JSONValue {
        throw JSONRPCError.notSupported("host scheduled task run next")
    }

    func createHostBotSkill(botID: BotID, skillID: String, body: String?, callerRun: AgentRunID, callerThread: AgentThreadID) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot skill create")
    }

    func viewHostBotSkill(botID: BotID, skillID: String, callerRun: AgentRunID, callerThread: AgentThreadID) throws -> JSONValue {
        throw JSONRPCError.notSupported("host Bot skill view")
    }

    func dispatchPairedBotRemote(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        throw JSONRPCError.notSupported("paired Bot remote control")
    }

    /// Safe in-memory default so FakeRouter/test hosts need no SQL body-budget path.
    func listAgentMessagesWithinBodyBudget(
        thread: AgentThreadID,
        limit: Int,
        before: AgentMessageCursor?,
        after: AgentMessageCursor?,
        budget: Int,
        contentLimit: Int
    ) throws -> AgentMessageBodyBudgetResult {
        let page = try listAgentMessagesPage(
            thread: thread,
            limit: limit,
            before: before,
            after: after
        )
        return AgentMessageTransport.pageWithinBodyBudget(
            page: page,
            budget: budget,
            contentLimit: contentLimit,
            afterDirection: after != nil
        )
    }

    /// Fake/in-memory router compatibility. The production AppCommandRouter
    /// overrides this and reads a SQLite BLOB range directly.
    func getAgentMessageBodyChunk(
        id: AgentMessageID,
        offsetBytes: Int,
        maxContentBytes: Int,
        expectedBodyRevision: Int?,
        expectedBodySHA256: String?
    ) throws -> AgentMessageBodyChunk? {
        guard let message = try getAgentMessage(id: id) else { return nil }
        let digest = AgentMessageTransport.bodySHA256Hex(message.content)
        if offsetBytes > 0 {
            guard expectedBodyRevision == 1 else {
                throw AgentMessageBodyChunkError.bodyRevisionConflict
            }
            let accepted = expectedBodySHA256 == digest
                || expectedBodySHA256?.lowercased() == digest
            guard accepted else {
                throw AgentMessageBodyChunkError.bodyDigestMismatch
            }
        }
        return AgentMessageTransport.inMemoryBodyChunk(
            message: message,
            offsetBytes: offsetBytes,
            maxContentBytes: maxContentBytes
        )
    }

    func createAgentThreadRouting(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?, surfaceID: SurfaceID?, routing: AgentRoutingRequest?, nestedRunContext: AgentNestedRunContext? = nil) async throws -> AgentThread {
        guard routing == nil, nestedRunContext == nil else {
            throw JSONRPCError(code: -32020, message: "Model routing is not supported by this host.", data: .object(["domain": .string("routing"), "kind": .string("unsupported")]))
        }
        return try createAgentThread(workspace: workspace, title: title, provider: provider, model: model, permissionMode: permissionMode, reasoningEffort: reasoningEffort, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId, runAsUser: runAsUser, surfaceID: surfaceID)
    }

    func configureAgentThreadRouting(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?, routing: AgentRoutingRequest?) async throws -> AgentThread {
        guard routing == nil else {
            throw JSONRPCError(code: -32020, message: "Model routing is not supported by this host.", data: .object(["domain": .string("routing"), "kind": .string("unsupported")]))
        }
        return try configureAgentThread(thread: thread, provider: provider, model: model, permissionMode: permissionMode, reasoningEffort: reasoningEffort, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId, runAsUser: runAsUser)
    }

    func sendAgentMessageRouting(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, interactionMode: AgentInteractionMode?, modelSelection: AgentModelSelection?, providerInstanceId: String?, attachments: [AgentAttachment], routing: AgentRoutingRequest?, nestedRunContext: AgentNestedRunContext? = nil) async throws -> AgentMessageSendResult {
        guard routing == nil else {
            throw JSONRPCError(code: -32020, message: "Model routing is not supported by this host.", data: .object(["domain": .string("routing"), "kind": .string("unsupported")]))
        }
        guard nestedRunContext == nil else {
            throw JSONRPCError.notSupported("nested Agent App runs")
        }
        return try await sendAgentMessage(thread: thread, text: text, provider: provider, model: model, permissionMode: permissionMode, reasoningEffort: reasoningEffort, serviceTier: serviceTier, interactionMode: interactionMode, modelSelection: modelSelection, providerInstanceId: providerInstanceId, attachments: attachments)
    }

    func ensureGitSurface(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        guard let workspaceState = try listWorkspaces().first(where: { $0.id == workspace }) else {
            throw LayoutError.workspaceNotFound
        }
        if let surface = canonicalGitSurface(in: workspaceState.layout) {
            return surface
        }
        return try createSurface(
            workspace: workspaceState.id,
            type: .rightSidebarTool,
            paneID: nil,
            title: "Git"
        )
    }
}

private func canonicalGitSurface(in node: LayoutNode) -> SurfaceDescriptor? {
    switch node {
    case .pane(let pane):
        return pane.surfaces.first {
            $0.type == .rightSidebarTool && $0.metadata["tool"] == "diff"
        }
    case .split(let split):
        return split.children.lazy.compactMap { canonicalGitSurface(in: $0) }.first
    }
}

@MainActor
public protocol TerminalCommandRouting: AnyObject {
    func sendTextResult(surface: SurfaceID, text: String) throws -> JSONValue
    func surfaceHealthDetails(surface: SurfaceID) -> JSONValue
    func readTextSnapshot(surface: SurfaceID) throws -> JSONValue
}

@MainActor
public protocol LayoutEventSuppressionRouting: AnyObject {
    func withSuppressedLayoutEvents<T>(_ body: () throws -> T) rethrows -> T
}

/// Marker for domain routers that already publish the canonical notification
/// projection events. Test/minimal routers omit it and use Dispatcher fallback.
public protocol NotificationEventPublishingRouting: AnyObject {}

/// Bounded idempotency cache with insertion-order eviction (oldest-first) and TTL.
/// - `cap`: maximum number of entries before the oldest is dropped.
/// - `ttl`: seconds after insertion at or beyond which an entry is treated as
///   absent (the retried command is allowed to re-execute). A `ttl` of 0 means
///   entries are never considered fresh.
struct BoundedReceiptCache {
    struct Entry {
        let value: JSONValue
        let insertedAt: Date
    }
    private(set) var cap: Int
    private(set) var ttl: TimeInterval
    private var store: [String: Entry] = [:]
    /// Insertion-ordered keys (oldest first).
    private var order: [String] = []

    init(cap: Int = 256, ttl: TimeInterval = 300) {
        self.cap = cap
        self.ttl = ttl
    }

    /// Returns the value for `key` if present AND within TTL; otherwise nil.
    func value(for key: String) -> JSONValue? {
        guard let entry = store[key] else { return nil }
        guard Date().timeIntervalSince(entry.insertedAt) < ttl else { return nil }
        return entry.value
    }

    /// Inserts `value` for `key`. Evicts oldest entry when at cap.
    mutating func insert(key: String, value: JSONValue) {
        if store[key] == nil {
            // Evict oldest when at cap.
            while order.count >= cap, !order.isEmpty {
                let oldest = order.removeFirst()
                store.removeValue(forKey: oldest)
            }
            order.append(key)
        }
        store[key] = Entry(value: value, insertedAt: Date())
    }

    var count: Int { store.count }
}

/// Per-request flag set when a remote mutation handler failed with a
/// `DefiniteMutationRejection` (no effect happened).
private final class DefiniteRejectionRecorder: @unchecked Sendable {
    var rejected = false
}

/// Bounded fence for unknown mutation outcomes. Stores only owner fingerprint +
/// params hash (never secrets or arbitrary payloads). Evicts oldest-first.
struct BoundedUnknownReceiptCache {
    struct Entry {
        let ownerFingerprint: String
        let paramsHash: String
    }
    private(set) var cap: Int
    private var store: [String: Entry] = [:]
    private var order: [String] = []

    init(cap: Int = 256) {
        self.cap = max(1, cap)
    }

    subscript(key: String) -> Entry? {
        store[key]
    }

    mutating func insert(
        key: String,
        ownerFingerprint: String,
        paramsHash: String
    ) {
        if store[key] == nil {
            while order.count >= cap, !order.isEmpty {
                let oldest = order.removeFirst()
                store.removeValue(forKey: oldest)
            }
            order.append(key)
        }
        store[key] = Entry(ownerFingerprint: ownerFingerprint, paramsHash: paramsHash)
    }

    var count: Int { store.count }
}

/// Pure coalesce-decision helper for device-initiated pairing requests.
///
/// When a device repeatedly connects (e.g. re-pair-every-connect, IP drift,
/// Bonjour TXT race), it sends a fresh POST /v1/pair each time. Without
/// coalescing, each POST creates a new `pairing_requests` row and fires a new
/// Mac modal -- the user sees a flood of identical prompts.
///
/// `coalescePairingRequest` answers: "is there already an outstanding,
/// non-expired pending request for `deviceName` within the TTL window?" If yes,
/// return it so the caller can reuse it (no new row, no new modal). If no,
/// return `nil` so the caller creates a new one as normal.
///
/// Pure, deterministic, no I/O. The `now` parameter is injected for
/// deterministic unit tests. Call-site feeds the live `outstanding` slice from
/// the repository query.
///
/// - Parameters:
///   - deviceName: Name sent by the device in the pairing POST body.
///   - outstanding: All currently-pending (non-decided) `PairingRequest` rows.
///   - now: Current time (injected so tests need no sleep).
///   - ttl: Maximum age of an existing request for it to be reused (seconds).
/// - Returns: An existing `PairingRequest` to reuse, or `nil` if a new one
///   should be created.
public func coalescePairingRequest(
    deviceName: String,
    outstanding: [PairingRequest],
    now: Date,
    ttl: TimeInterval
) -> PairingRequest? {
    outstanding.first { req in
        req.deviceName == deviceName
            && req.status == "pending"
            && now.timeIntervalSince(req.createdAt) < ttl
    }
}

private final class ConnectionSnapshotReadOutcome: @unchecked Sendable {
    typealias Value = EventBus.SnapshotBarrierResult<ConnectionSnapshotReadState>

    private let lock = NSLock()
    private var completion: Result<Value, Error>?
    private var continuation: CheckedContinuation<Result<Value, Error>, Never>?
    private var observers: [(Result<Value, Error>) -> Void] = []

    /// Calls `body` once with the completion: now if already resolved,
    /// otherwise when `resolve` first runs.
    func observe(_ body: @escaping (Result<Value, Error>) -> Void) {
        lock.lock()
        if let completion {
            lock.unlock()
            body(completion)
        } else {
            observers.append(body)
            lock.unlock()
        }
    }

    func wait() async -> Result<Value, Error> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let completion {
                lock.unlock()
                continuation.resume(returning: completion)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func resolve(_ completion: Result<Value, Error>) -> Bool {
        lock.lock()
        guard self.completion == nil else {
            lock.unlock()
            return false
        }
        self.completion = completion
        let continuation = self.continuation
        self.continuation = nil
        let observers = self.observers
        self.observers = []
        lock.unlock()
        continuation?.resume(returning: completion)
        observers.forEach { $0(completion) }
        return true
    }
}

/// One physical `sync.snapshot` state read and the callers waiting on it.
/// MainActor-owned: `waiters` is read by the read loop between attempts.
@MainActor
private final class ConnectionSnapshotSharedRead {
    let outcome = ConnectionSnapshotReadOutcome()
    var waiters = 0
}

@MainActor
public final class JSONRPCDispatcher {
    let router: CommandRouting
    public nonisolated let commandReceiptMetrics: CommandReceiptMetrics
    /// Store-independent capability injected by app wiring only while the
    /// matching upload store is available. HTTP reads the same immutable value
    /// so public, modern authenticated, and legacy authenticated authorities
    /// cannot disagree.
    public nonisolated let agentAttachmentUploadCapability:
        AgentAttachmentUploadCapabilityAdvertisement?
    /// A successful v1 response is measured with its JSON-RPC id. Bound the id
    /// before repository work so an attacker cannot consume the entire advertised
    /// response budget with correlation metadata.
    nonisolated static let checkpointListV1MaxEncodedResponseIDBytes =
        AgentCheckpointListContract.maxEncodedResponseIDBytes
    private var volatileCommandReceipts = BoundedReceiptCache()
    @TaskLocal private static var centralMutationExecution = false
    @TaskLocal private static var definiteRejectionRecorder: DefiniteRejectionRecorder?
    /// Transport context for methods that are HTTP-only (checkpoint list).
    /// Default `.localTest` keeps unit tests exerciseable; production entry
    /// points set unix / webSocket / http explicitly.
    @TaskLocal private static var rpcWireTransport:
        AgentCheckpointListContract.WireTransport = .localTest
    @TaskLocal private static var rpcInBatch = false
    /// Private provider methods are admitted only after the Unix entry point
    /// authenticates the exact live run bearer. HTTP, WebSocket, local IPC,
    /// and nested batches must not reach these aliases.
    @TaskLocal private static var managedProviderSocketAuthenticated = false
    private nonisolated static let managedProviderSocketMethods =
        RemoteCodeHostCatalog.rpcMethods.union([
            "bot.peer.list", "bot.peer.ask", "bot.peer.self_config", "bot.peer.status", "bot.peer.cancel",
            "bot.peer.receipt.status",
        ])
    nonisolated static let managedPeerReceiptMethods: Set<String> = [
        "bot.peer.ask", "bot.peer.self_config", "bot.peer.cancel",
    ]
    /// Bounded unknown-outcome fence (same cap as committed receipts). Does not
    /// store request payloads or secrets — only owner fingerprint + params hash.
    private var volatileUnknownReceipts = BoundedUnknownReceiptCache()
    /// The one physical snapshot state read. Every `sync.snapshot` caller that
    /// arrives while it runs joins it, and it is retained until the underlying
    /// router continuation finishes, so callers and timeouts never stack up
    /// SQLite reads.
    private var activeConnectionSnapshotRead: ConnectionSnapshotSharedRead?
    public nonisolated static let hostMutationMethods = HostMutationContract.methods
    private nonisolated static let durableSynchronousMutationMethods: Set<String> = [
        "workspace.create",
        "workspace.select",
        "workspace.close",
        "workspace.rename",
        "workspace.set_description",
        "workspace.set_color",
        "workspace.set_pinned",
        "workspace.reorder",
        "workspace.move_to_window",
        "window.create",
        "window.close",
        "window.focus",
        "pane.resize",
        "pane.swap",
        "surface.create",
        "surface.close",
        "surface.focus",
        "surface.move",
        "surface.rename",
        "surface.reorder",
        "surface.set_color",
        "surface.split",
        "surface.clear_history",
        "surface.send_key",
        "surface.send_text",
        "fs.workspace.create_file",
        "fs.workspace.delete",
        "fs.workspace.rename",
        "files.edit.open",
        "files.edit.apply_patch",
        "files.edit.save",
        "files.edit.discard",
        "files.edit.close",
        "files.state.update",
        "files.tab.open",
        "files.tab.split",
        "notification.create",
        "notification.dismiss",
        "notification.mark_read",
        "settings.set",
        "private.push_token.update",
        "project.open_in_editor",
        "git.checkout",
        "git.commit",
        "git.create_branch",
        "git.deliver",
        "git.push",
        "git.fetch",
        "git.pull",
        "fs.mkdir",
        "ssh.files.remote.mkdir",
        "ssh.files.remote.rename",
        "ssh.files.remote.delete",
        "ssh.connect",
        "ssh.disconnect",
        "ssh.host.upsert",
        "ssh.host.delete",
        "ssh.transfer.upload",
        "ssh.transfer.download",
        "project.run_script",
        "agent.open",
        "host.workspace.create",
        "host.agent.thread.create",
        "host.bot.create",
        "host.bot.open",
        "host.bot.send",
        "host.bot.thread.create",
        "host.bot.skill.create",
        "host.bot.delegate",
        "host.scheduled_task.run_next",
        "host.browser.screenshot",
        "host.chat.image",
        "bot.create",
        "bot.discard_new",
        "bot.save",
        "bot.delete",
        "bot.context.grant",
        "bot.context.revoke",
        "bot.set_pinned",
        "bot.set_hidden",
        "bot.reorder",
        "bot.duplicate",
        "bot.send",
        "bot.stop",
        "bot.force_stop",
        "bot.settings.set",
        "bot.queue.remove",
        "bot.queue.update",
        "bot.queue.reorder",
        "bot.queue.force_now",
        "bot.conversation.create",
        "bot.conversation.enqueue",
        "bot.conversation.select",
        "bot.conversation.clear_all",
        "bot.routine.create",
        "bot.routine.update",
        "bot.routine.enable",
        "bot.routine.run",
        "bot.routine.delete",
        "bot.attachment.stage",
        "bot.attachment.import",
        "bot.attachment.remove",
        "bot.link.open",
        "bot.browser.action",
        "bot.files.mutate",
        "bot.files.open_tab",
        "bot.files.split",
        "bot.files.location.set",
        "bot.guest.input",
        "bot.guest.start",
        "bot.guest.stop",
        "bot.guest.rebuild",
        "bot.guest.revoke",
        "bot.guest.control",
        "bot.docker.clear",
        "bot.notify.set",
        "bot.conversation.fork",
        "bot.verbosity.set",
        "bot.caveman.set",
        "bot.factory_reset",
        "bot.notice.act",
        "bot.notice.reply",
        "bot.notice.read",
        "bot.notice.clear",
        "bot.desktop.set",
        "bot.vm.save",
        "bot.execution.set",
        "bot.avatar.set",
        "bot.handle.set",
        "bot.soul.set",
        "bot.routing.set",
        "bot.attention.ack",
        "bot.self_config",
        "bot.scheduler.tick",
        "bot.team.create",
        "bot.team.update",
        "bot.team.set_members",
        "bot.team.delete",
        "bot.team.reorder",
        "bot.group.create",
        "bot.group.update",
        "bot.group.set_participants",
        "bot.group.send",
        "bot.group.stop",
        "bot.group.retry_turn",
        "bot.group.select",
        "bot.group.delete",
        "agent.thread.create",
        "agent.thread.prepare_pr",
        "agent.thread.rollback",
        "agent.thread.delete",
        "agent.thread.delete_many",
        "agent.thread.rename",
        "agent.thread.loop.stop",
        "agent.thread.set_pinned",
        "agent.thread.set_color",
        "agent.thread.reorder",
        "agent.thread.configure",
        "agent.thread.execution.configure",
        "agent.thread.mark_read",
        "agent.thread.select",
        "browser.navigate",
        "browser.back",
        "browser.forward",
        "browser.reload",
        "browser.stop",
        "browser.click",
        "browser.fill",
        "browser.type",
        "browser.focus",
        "browser.hover",
        "browser.check",
        "browser.uncheck",
        "browser.select",
        "browser.eval",
        "browser.screenshot",
        "browser.mirror_url.get",
        "agent.message.send",
        "agent.message.queue.cancel",
        "agent.message.queue.force_now",
        "agent.message.queue.reorder",
        "agent.message.queue.update",
        "agent.run.continue",
        "agent.run.stop",
        "agent.request.respond",
        "agent.user_input.respond",
        // Not canonical-immediate: the router publishes agent.manual_action.updated
        // inside the call, and the ledger captures it into the receipt.
        "agent.manual_action.resolve",
        // Not canonical-immediate either: the router publishes agent.thread.updated
        // inside the call, and the ledger captures it into the receipt.
        "agent.thread.actor.set",
        "agent.mac_execution.resolve",
        "agent.plan.implement",
        "agent.plan.save",
        "agent.plan.notes.save",
        "agent.checkpoint.revert",
        "agent.attachment.upload",
        "agent.attachment.import",
        "agent.provider.update",
        "distill.accounts.login",
        "distill.accounts.logout",
        "distill.accounts.cancel",
        "distill.accounts.add",
        "distill.accounts.rename",
        "distill.accounts.remove",
        "distill.accounts.usage",
        "distill.accounts.routing.set",
    ]
    private nonisolated static let canonicalImmediateEventMethods: Set<String> = Set([
        "agent.message.send",
        "agent.message.queue.cancel",
        "agent.message.queue.force_now",
        "agent.message.queue.reorder",
        "agent.message.queue.update",
        "agent.run.continue",
        "agent.run.stop",
        "agent.request.respond",
        "agent.user_input.respond",
        "agent.plan.implement",
        "agent.plan.save",
        "agent.plan.notes.save",
        "agent.checkpoint.revert",
        "agent.attachment.upload",
        "agent.attachment.import",
        "agent.provider.update",
    ]).union(durableSynchronousMutationMethods.filter {
        // Team and group mutations publish their own events from the shared
        // service; those are captured into the receipt, not re-derived here.
        $0.hasPrefix("bot.") && !$0.hasPrefix("bot.team.") && !$0.hasPrefix("bot.group.")
    })
    public init(
        router: CommandRouting,
        commandReceiptMetrics: CommandReceiptMetrics = CommandReceiptMetrics(),
        agentAttachmentUploadCapability:
            AgentAttachmentUploadCapabilityAdvertisement? = nil
    ) {
        self.router = router
        self.commandReceiptMetrics = commandReceiptMetrics
        self.agentAttachmentUploadCapability =
            agentAttachmentUploadCapability
    }

    /// Default wall budget for one `sync.snapshot` state capture (including
    /// fence retries). Matches the WS welcome lower bound (5s) and stays well
    /// below cellular transfer budgets so HTTP baseline cannot monopolize the
    /// host indefinitely.
    public nonisolated static let connectionSnapshotTimeoutNanoseconds: UInt64 = 5_000_000_000

    /// Retryable when the sequence fence cannot stabilize under concurrent
    /// host mutations. Clients should reconnect or re-issue baseline.
    public nonisolated static let snapshotSequenceFenceUnstable = JSONRPCError(
        code: -32012,
        message: "Snapshot sequence fence unstable; retry baseline.",
        data: .object([
            "reason": .string("snapshot_sequence_fence_unstable"),
            "retryable": .bool(true),
        ])
    )

    /// Retryable when the snapshot read exceeds the host wall budget.
    public nonisolated static let snapshotTimedOut = JSONRPCError(
        code: -32013,
        message: "Snapshot read timed out; retry baseline.",
        data: .object([
            "reason": .string("snapshot_timed_out"),
            "retryable": .bool(true),
        ])
    )

    /// Retryable when the peer disconnects (or the host cancels) mid-snapshot.
    public nonisolated static let snapshotCancelled = JSONRPCError(
        code: -32014,
        message: "Snapshot cancelled.",
        data: .object([
            "reason": .string("snapshot_cancelled"),
            "retryable": .bool(true),
        ])
    )

    func readConnectionSnapshot(
        timeoutNanoseconds: UInt64 = JSONRPCDispatcher.connectionSnapshotTimeoutNanoseconds,
        phaseMetrics: HTTPRequestPhaseMetrics? = nil
    ) async throws -> EventBus.SnapshotBarrierResult<ConnectionSnapshotReadState> {
        guard let snapshotRouter = router as? ConnectionSnapshotRouting else {
            throw JSONRPCError.notSupported("sync.snapshot")
        }

        // Snapshot reads can touch SQLite (off-MainActor via AgentThreadListGateway),
        // browser surfaces, and JSON conversion. Do not hold EventBus's publisher
        // lock across that work: compare the cheap metadata before/after the read
        // instead, retrying when an event crossed the capture window. The
        // watermark then remains an honest sequence fence without starving
        // event delivery or HTTP recovery while the snapshot is built.
        //
        // One physical read runs at a time. A caller that arrives while it runs
        // joins it and gets the same result: its pre-read watermark is honest
        // for every caller, because the client replays every event after it.
        // Each caller races the shared result against its own deadline and
        // cancellation, so one caller timing out or disconnecting never fails
        // another. The read stops before its next attempt once nobody waits.
        let readStarted = DispatchTime.now().uptimeNanoseconds
        do {
            let read: ConnectionSnapshotSharedRead
            if let active = activeConnectionSnapshotRead {
                read = active
                phaseMetrics?.recordJoined()
            } else {
                read = ConnectionSnapshotSharedRead()
                activeConnectionSnapshotRead = read
                Task { @MainActor [weak self] in
                    guard let self else {
                        read.outcome.resolve(.failure(Self.snapshotCancelled))
                        return
                    }
                    await self.runConnectionSnapshotRead(
                        read,
                        router: snapshotRouter,
                        phaseMetrics: phaseMetrics
                    )
                }
            }
            read.waiters += 1
            defer { read.waiters -= 1 }

            let outcome = ConnectionSnapshotReadOutcome()
            read.outcome.observe { outcome.resolve($0) }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    outcome.resolve(.failure(Self.snapshotTimedOut))
                } catch is CancellationError {
                    // Read/caller completed first; normal deadline teardown.
                } catch {
                    outcome.resolve(.failure(error))
                }
            }

            let completion = await withTaskCancellationHandler {
                await outcome.wait()
            } onCancel: {
                timeoutTask.cancel()
                outcome.resolve(.failure(Self.snapshotCancelled))
            }
            timeoutTask.cancel()
            _ = await timeoutTask.result
            let result = try completion.get()
            phaseMetrics?.record(
                .snapshotRead,
                latencyMilliseconds: HTTPRequestPhaseMetrics.elapsedMilliseconds(since: readStarted)
            )
            return result
        } catch is CancellationError {
            phaseMetrics?.recordCancelled()
            phaseMetrics?.record(
                .snapshotRead,
                latencyMilliseconds: HTTPRequestPhaseMetrics.elapsedMilliseconds(since: readStarted)
            )
            throw Self.snapshotCancelled
        } catch let error as JSONRPCError {
            if error.code == Self.snapshotTimedOut.code {
                phaseMetrics?.recordTimedOut()
            } else if error.code == Self.snapshotCancelled.code {
                phaseMetrics?.recordCancelled()
            }
            phaseMetrics?.record(
                .snapshotRead,
                latencyMilliseconds: HTTPRequestPhaseMetrics.elapsedMilliseconds(since: readStarted)
            )
            throw error
        } catch {
            phaseMetrics?.record(
                .snapshotRead,
                latencyMilliseconds: HTTPRequestPhaseMetrics.elapsedMilliseconds(since: readStarted)
            )
            throw error
        }
    }

    /// The physical read behind `readConnectionSnapshot`: up to three fenced
    /// attempts. The fence ignores live-only stream kinds and idempotent
    /// last-writer-wins kinds (`EventBus.snapshotFenceIdempotentKinds`); the
    /// pre-read watermark makes the client replay those on top of the state.
    private func runConnectionSnapshotRead(
        _ read: ConnectionSnapshotSharedRead,
        router snapshotRouter: ConnectionSnapshotRouting,
        phaseMetrics: HTTPRequestPhaseMetrics?
    ) async {
        do {
            for attempt in 0..<3 {
                guard read.waiters > 0 else { throw Self.snapshotCancelled }
                let before = EventBus.shared.snapshotMetadata()
                let state = try await snapshotRouter.readConnectionSnapshotState()
                let after = EventBus.shared.snapshotMetadata()
                if before.fenceRevision == after.fenceRevision {
                    if before.stateRevision != after.stateRevision {
                        phaseMetrics?.recordFenceTolerated()
                    }
                    read.outcome.resolve(.success(EventBus.SnapshotBarrierResult(
                        state: state,
                        metadata: before
                    )))
                    finishConnectionSnapshotRead(read)
                    return
                }
                phaseMetrics?.recordFenceRetry()
                if attempt == 2 {
                    phaseMetrics?.recordFenceExhausted()
                }
            }
            throw Self.snapshotSequenceFenceUnstable
        } catch {
            read.outcome.resolve(.failure(error))
            finishConnectionSnapshotRead(read)
        }
    }

    private func finishConnectionSnapshotRead(_ read: ConnectionSnapshotSharedRead) {
        guard activeConnectionSnapshotRead === read else { return }
        activeConnectionSnapshotRead = nil
    }

    private func commandReceipt(method: String, params: [String: JSONValue]) -> (String, JSONValue)? {
        guard !Self.centralMutationExecution else { return nil }
        guard let receiptKey = params["client_request_id"]?.stringValue else { return nil }
        if let durable = router.commandReceipt(method: method, clientRequestId: receiptKey) {
            return (receiptKey, durable)
        }
        if let cached = volatileCommandReceipts.value(for: "\(method):\(receiptKey)") {
            return (receiptKey, cached)
        }
        return nil
    }

    private func recordCommandReceipt(method: String, clientRequestId: String?, result: JSONValue) {
        guard !Self.centralMutationExecution else { return }
        guard let clientRequestId else { return }
        volatileCommandReceipts.insert(key: "\(method):\(clientRequestId)", value: result)
        router.recordCommandReceipt(method: method, clientRequestId: clientRequestId, result: result)
    }

    private func withSuppressedLayoutEvents<T>(_ body: () throws -> T) rethrows -> T {
        if let suppressingRouter = router as? LayoutEventSuppressionRouting {
            return try suppressingRouter.withSuppressedLayoutEvents(body)
        }
        return try body()
    }

    private func publishCanonicalImmediateEvent(
        method: String,
        params: [String: JSONValue],
        result: JSONValue
    ) {
        func string(_ keys: String...) -> JSONValue? {
            keys.lazy.compactMap { params[$0]?.stringValue }.first.map(JSONValue.string)
        }
        func canonicalBotNotification(_ value: JSONValue) -> JSONValue? {
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let profileID = object["profile_id"]?.stringValue,
                  let hostID = object["host_id"]?.stringValue,
                  let attentionItemID = object["attention_item_id"]?.stringValue,
                  let notificationID = object["notification_id"]?.stringValue,
                  let botID = object["bot_id"]?.stringValue,
                  let source = object["source"]?.stringValue,
                  let title = object["title"]?.stringValue,
                  let category = object["category"]?.stringValue,
                  !id.isEmpty, notificationID == id, attentionItemID == id,
                  !profileID.isEmpty, !hostID.isEmpty, !botID.isEmpty,
                  source == "bot" || source == "routine" else {
                return nil
            }
            var payload: [String: JSONValue] = [
                "id": .string(id),
                "title": .string(title),
                "category": .string(category),
                "profile_id": .string(profileID),
                "host_id": .string(hostID),
                "attention_item_id": .string(attentionItemID),
                "notification_id": .string(notificationID),
                "bot_id": .string(botID),
                "source": .string(source),
            ]
            if let body = object["body"]?.stringValue { payload["body"] = .string(body) }
            return .object(payload)
        }
        func canonicalBotSendLifecycle(
            receipt: [String: JSONValue],
            readback: [String: JSONValue]
        ) -> (kind: RemoteCodeEventKind, payload: JSONValue)? {
            guard let hostID = receipt["host_id"]?.stringValue,
                  let botID = receipt["bot_id"]?.stringValue,
                  let requestID = receipt["request_id"]?.stringValue,
                  receipt["client_request_id"]?.stringValue == requestID,
                  readback["host_id"]?.stringValue == hostID,
                  readback["bot_id"]?.stringValue == botID,
                  readback["request_id"]?.stringValue == requestID,
                  readback["client_request_id"]?.stringValue == requestID,
                  let runID = readback["run_id"]?.stringValue,
                  !hostID.isEmpty, !botID.isEmpty, !requestID.isEmpty, !runID.isEmpty,
                  let enqueued = readback["enqueued"]?.boolValue else { return nil }
            let conversationID = readback["conversation_id"] ?? .null
            var payload: [String: JSONValue] = [
                "host_id": .string(hostID),
                "bot_id": .string(botID),
                "conversation_id": conversationID,
                "request_id": .string(requestID),
                "client_request_id": .string(requestID),
                "run_id": .string(runID),
            ]
            if enqueued {
                guard let itemID = readback["id"]?.stringValue, !itemID.isEmpty else { return nil }
                payload["queue_item_id"] = .string(itemID)
                return (.botMessageQueued, .object(payload))
            }
            guard let run = readback["run"]?.objectValue,
                  run["host_id"]?.stringValue == hostID,
                  run["bot_id"]?.stringValue == botID,
                  run["request_id"]?.stringValue == requestID,
                  run["client_request_id"]?.stringValue == requestID,
                  run["run_id"]?.stringValue == runID,
                  (run["conversation_id"] ?? .null) == conversationID else { return nil }
            if let threadID = run["thread_id"]?.stringValue, !threadID.isEmpty {
                payload["thread_id"] = .string(threadID)
            }
            return (.botRunStarted, .object(payload))
        }
        func canonicalBotStop(
            receipt: [String: JSONValue],
            readback: [String: JSONValue],
            force: Bool
        ) -> [String: JSONValue]? {
            guard readback["accepted"]?.boolValue == true,
                  readback["force"]?.boolValue == force,
                  readback["terminal"]?.boolValue == true,
                  let hostID = params["host_id"]?.stringValue,
                  let botID = receipt["bot_id"]?.stringValue,
                  let requestID = receipt["request_id"]?.stringValue,
                  let run = readback["run"]?.objectValue,
                  run["host_id"]?.stringValue == hostID,
                  run["bot_id"]?.stringValue == botID,
                  let runRequestID = run["request_id"]?.stringValue,
                  run["client_request_id"]?.stringValue == runRequestID,
                  let runID = run["run_id"]?.stringValue,
                  let conversationID = run["conversation_id"],
                  !hostID.isEmpty, !botID.isEmpty, !requestID.isEmpty,
                  !runRequestID.isEmpty, !runID.isEmpty else { return nil }
            return [
                "host_id": .string(hostID),
                "bot_id": .string(botID),
                "conversation_id": conversationID,
                "request_id": .string(runRequestID),
                "client_request_id": .string(runRequestID),
                "stop_request_id": .string(requestID),
                "run_id": .string(runID),
                "terminal": .bool(true),
                "force": .bool(force),
            ]
        }
        func project(_ value: JSONValue?, keys: [String]) -> JSONValue? {
            guard let object = value?.objectValue else { return nil }
            return .object(Dictionary(uniqueKeysWithValues: keys.compactMap { key in
                object[key].map { (key, $0) }
            }))
        }
        func guestTaskCatalog(_ value: JSONValue?) -> JSONValue? {
            guard let catalog = value?.objectValue,
                  let tasks = catalog["tasks"]?.arrayValue else { return nil }
            let projectedTasks = tasks.compactMap { task -> JSONValue? in
                guard var projected = project(
                    task,
                    keys: ["id", "title", "axis", "operation", "interaction_mode", "recipe_id"]
                )?.objectValue else { return nil }
                projected["recipe"] = project(
                    task.objectValue?["recipe"],
                    keys: ["id", "immutable", "image_reference", "container_id", "viewer_path"]
                )
                return .object(projected)
            }
            var projected = Dictionary(uniqueKeysWithValues: ["id", "generation"].compactMap { key in
                catalog[key].map { (key, $0) }
            })
            projected["tasks"] = .array(projectedTasks)
            return .object(projected)
        }
        var payload: [String: JSONValue] = [:]
        var botNotifications: [JSONValue] = []
        var botLifecycleEvents: [(kind: RemoteCodeEventKind, payload: JSONValue)] = []
        var botTerminalPayload: [String: JSONValue]?
        let kind: RemoteCodeEventKind
        switch method {
        case "agent.message.send":
            kind = .agentMessageAccepted
            payload["thread_id"] = string("thread_id")
        case "agent.message.queue.cancel":
            kind = .agentMessageQueueCancelled
            payload["queued_message_id"] = string("queued_message_id", "id")
        case "agent.message.queue.force_now":
            kind = .agentMessageQueueForceRequested
            payload["queued_message_id"] = string("queued_message_id", "id")
        case "agent.message.queue.reorder":
            kind = .agentMessageQueueUpdated
            payload["thread_id"] = string("thread_id")
            payload["queued_message_id"] = string("queued_message_id", "id")
        case "agent.message.queue.update":
            kind = .agentMessageQueueUpdated
            payload["queued_message_id"] = string("queued_message_id", "id")
        case "agent.run.continue":
            kind = .agentRunContinueRequested
            payload["thread_id"] = string("thread_id")
        case "agent.run.stop":
            kind = .agentRunStopRequested
            payload["thread_id"] = string("thread_id")
        case "agent.request.respond":
            kind = .agentRequestResolved
            payload["thread_id"] = string("thread_id")
            payload["request_id"] = string("request_id")
        case "agent.user_input.respond":
            kind = .agentUserInputResolved
            payload["thread_id"] = string("thread_id")
            payload["request_id"] = string("request_id")
        case "agent.plan.implement":
            kind = .agentPlanImplemented
            payload["thread_id"] = string("thread_id")
            payload["plan_id"] = string("plan_id")
            if let object = result.objectValue {
                payload["run_id"] = object["run_id"]
                payload["implementation_thread_id"] = object["implementation_thread_id"]
            }
        case "agent.plan.save":
            kind = .agentPlanSaved
            payload["thread_id"] = string("thread_id")
            payload["plan_id"] = string("plan_id")
            payload["relative_path"] = result.objectValue?["relative_path"]
        case "agent.plan.notes.save":
            kind = .agentPlanNotesUpdated
            // Compact metadata only — full notes on the wire drop the live stream
            // on weak links. Authoritative text stays on disk and is paged via
            // agent.plan.notes.get protocol_version 1.
            if let threadString = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
               let notes = params["notes"]?.stringValue {
                payload = PlanNotesProjectionV1.compactUpdateEvent(threadId: threadString, notes: notes).objectValue
                    ?? ["thread_id": .string(threadString.value.uuidString)]
            } else {
                payload["thread_id"] = string("thread_id")
                payload["rehydrate_required"] = .bool(true)
            }
        case "agent.checkpoint.revert":
            kind = .agentCheckpointReverted
            payload["thread_id"] = string("thread_id")
            if let object = result.objectValue {
                payload["turn_count"] = object["checkpointTurnCount"] ?? object["checkpoint_turn_count"]
                payload["turn_id"] = object["turnId"] ?? object["turn_id"]
                payload["checkpoint_ref"] = object["checkpointRef"] ?? object["checkpoint_ref"]
            }
        case "agent.attachment.upload", "agent.attachment.import":
            kind = .agentAttachmentUploaded
            payload["workspace_id"] = string("workspace_id")
            if let object = result.objectValue {
                payload["id"] = object["id"]
                payload["display_name"] = object["displayName"] ?? object["display_name"]
                payload["sha256"] = object["sha256"]
                payload["size_bytes"] = object["sizeBytes"] ?? object["size_bytes"]
            }
        case "agent.provider.update":
            kind = .agentProviderUpdated
            payload["provider"] = result.objectValue?["provider"] ?? string("provider") ?? .string("codex")
            payload["ok"] = result.objectValue?["ok"]
            payload["status"] = result.objectValue?["status"]
        case let botMethod where botMethod.hasPrefix("bot."):
            guard let object = result.objectValue else { return }
            let resultStatus = object["status"]?.stringValue
            let readback = object["readback"]?.objectValue
            let durablePartialDeletion = resultStatus == "partial"
                && (botMethod == "bot.delete" || botMethod == "bot.discard_new")
                && readback?["deleted"]?.boolValue == true
            guard resultStatus == "completed"
                    || (botMethod.hasPrefix("bot.guest.") && resultStatus == "accepted")
                    || durablePartialDeletion else {
                return
            }
            switch botMethod {
            case "bot.create", "bot.duplicate": kind = .botCreated
            case "bot.discard_new", "bot.delete": kind = .botDeleted
            case "bot.settings.set": kind = .botSettingsUpdated
            case "bot.send": kind = .botMessageAccepted
            case "bot.stop", "bot.force_stop":
                guard let readback = object["readback"]?.objectValue,
                      let terminal = canonicalBotStop(
                        receipt: object,
                        readback: readback,
                        force: method == "bot.force_stop"
                      ) else {
                    return
                }
                kind = .botRunStopRequested
                botTerminalPayload = terminal
            case "bot.conversation.enqueue": kind = .botQueueUpdated
            case "bot.queue.remove", "bot.queue.update", "bot.queue.reorder", "bot.queue.force_now":
                kind = .botQueueUpdated
            case "bot.conversation.select": kind = .botConversationSelected
            case "bot.conversation.create", "bot.conversation.clear_all":
                kind = .botConversationUpdated
            case "bot.routine.run": kind = .botRoutineRunRequested
            case "bot.routine.create", "bot.routine.update", "bot.routine.enable", "bot.routine.delete":
                kind = .botRoutineUpdated
            case "bot.attachment.stage", "bot.attachment.import", "bot.attachment.remove": kind = .botAttachmentUpdated
            case "bot.files.mutate": kind = .botFilesChanged
            case "bot.files.open_tab", "bot.files.split": kind = .botFilesOpened
            case "bot.files.location.set": kind = .botFilesUpdated
            case "bot.browser.action": kind = .botBrowserUpdated
            case "bot.link.open":
                kind = object["readback"]?.objectValue?["link_kind"]?.stringValue == "file"
                    ? .botFilesOpened
                    : .botBrowserUpdated
            case "bot.guest.input", "bot.guest.start", "bot.guest.stop", "bot.guest.rebuild", "bot.guest.revoke",
                 "bot.guest.control":
                kind = .botGuestUpdated
            case "bot.docker.clear": kind = .botDockerCleared
            case "bot.attention.ack": kind = .botAttentionUpdated
            case "bot.scheduler.tick": kind = .botSchedulerUpdated
            default: kind = .botUpdated
            }
            payload["method"] = .string(botMethod)
            payload["request_id"] = object["request_id"]
                ?? string("client_request_id")
            payload["client_request_id"] = object["client_request_id"]
                ?? object["request_id"]
                ?? string("client_request_id")
            payload["receipt_id"] = object["receipt_id"]
            payload["bot_id"] = object["bot_id"]
                ?? object["readback"]?.objectValue?["bot_id"]
                ?? string("bot_id")
            if let readback = object["readback"]?.objectValue {
                if botMethod == "bot.send",
                   let lifecycle = canonicalBotSendLifecycle(receipt: object, readback: readback) {
                    botLifecycleEvents.append(lifecycle)
                }
                if let notification = readback["notification"].flatMap(canonicalBotNotification) {
                    botNotifications.append(notification)
                }
                if let notifications = readback["notifications"]?.arrayValue {
                    botNotifications.append(contentsOf: notifications.compactMap(canonicalBotNotification))
                }
                if botMethod.hasPrefix("bot.guest.") {
                    for key in [
                        "host_id", "viewer_path", "grant_generation", "grant_invalidated",
                        "before_frame_id", "after_frame_id", "status", "error_message",
                        "controlled_by_user", "control_action",
                    ] {
                        payload[key] = readback[key]
                    }
                    payload["security"] = project(
                        readback["security"],
                        keys: [
                            "bot_bound", "host_bound", "opaque_grant",
                            "loopback_url_exported", "bearer_exported",
                        ]
                    )
                    payload["task_catalog"] = guestTaskCatalog(readback["task_catalog"])
                    payload["runtime"] = project(
                        readback["runtime"],
                        keys: [
                            "host_id", "bot_id", "container_id", "app_run_id", "viewer_id",
                            "viewer_path", "session_id", "grant_id", "grant_generation",
                            "recipe_id", "image_reference",
                        ]
                    )
                } else {
                    payload["conversation_id"] = readback["conversation_id"]
                        ?? readback["selected_id"]
                        ?? string("conversation_id")
                    payload["routine_id"] = readback["routine_id"]
                        ?? string("routine_id")
                    payload["run_id"] = readback["run_id"]
                    payload["routing_receipt_id"] = readback["routing_receipt_id"]
                    payload["key"] = readback["key"] ?? string("key")
                    for key in [
                        "host_id", "client_request_id", "root", "root_handle", "handle", "generation", "previous_generation",
                        "root_cas", "previous_cas", "expected_cas", "current_cas",
                        "entry_generation", "entry_cas", "path", "op",
                        "current_revision_id", "revision", "soul", "description",
                        "profile_id", "attention_item_id", "notification_id", "source", "enqueued", "id",
                        "surface_id", "snapshot_generation", "url", "title", "loading", "action", "link_kind",
                        "mounted", "split",
                        "session_before_digest", "session_after_digest", "cleared", "removed_count", "partial",
                        "deleted", "cleanup_complete", "cleanup_residuals", "unpublished",
                    ] {
                        payload[key] = readback[key]
                    }
                    payload["security"] = readback["security"]
                    payload["session"] = readback["session"]
                }
                if botMethod.hasPrefix("bot.guest."), let frame = readback["frame"]?.objectValue {
                    payload["frame"] = .object([
                        "frame_id": frame["frame_id"] ?? .null,
                        "sequence": frame["sequence"] ?? .null,
                        "pixel_width": frame["pixel_width"] ?? .null,
                        "pixel_height": frame["pixel_height"] ?? .null,
                        "png_hash": frame["png_hash"] ?? .null,
                    ])
                }
                if let botTerminalPayload {
                    for (key, value) in botTerminalPayload { payload[key] = value }
                }
            }
        default:
            return
        }
        EventBus.shared.publish(kind: kind, payload: .object(payload.compactMapValues { $0 }))
        for event in botLifecycleEvents {
            EventBus.shared.publish(kind: event.kind, payload: event.payload)
        }
        for notification in botNotifications {
            EventBus.shared.publish(kind: .notificationCreated, payload: notification)
        }
    }

    /// Translate symbolic key names (cmux v2 contract) into raw bytes
    /// the PTY-backed terminal understands. Anything we don't recognize
    /// passes through verbatim.
    private func encodeKey(_ key: String) -> String {
        switch key {
        case "enter", "return", "Enter", "Return": return "\r"
        case "tab", "Tab": return "\t"
        case "escape", "Escape", "esc", "Esc": return "\u{1B}"
        case "backspace", "Backspace": return "\u{7F}"
        case "space", "Space": return " "
        case "ctrl-c", "C-c": return "\u{03}"
        case "ctrl-d", "C-d": return "\u{04}"
        case "ctrl-z", "C-z": return "\u{1A}"
        case "ctrl-l", "C-l": return "\u{0C}"
        case "up", "Up", "ArrowUp": return "\u{1B}[A"
        case "down", "Down", "ArrowDown": return "\u{1B}[B"
        case "right", "Right", "ArrowRight": return "\u{1B}[C"
        case "left", "Left", "ArrowLeft": return "\u{1B}[D"
        case "home", "Home": return "\u{1B}[H"
        case "end", "End": return "\u{1B}[F"
        case "page-up", "PageUp": return "\u{1B}[5~"
        case "page-down", "PageDown": return "\u{1B}[6~"
        default: return key
        }
    }

    /// Local same-user IPC entry point. This path intentionally shares the
    /// AppCommandRouter domain handlers without fabricating remote transport
    /// identity or durable transport receipts. Network servers must call the
    /// mutation-context overload below.
    ///
    /// Explicit checkpoint-list v1 is HTTP-only; production Unix tags transport
    /// via `dispatchUnixSocket`. Unit tests keep the default `.localTest`
    /// transport so local harnesses can exercise v1 without HTTP framing.
    public func dispatchLocalIPC(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        await dispatchCore(req)
    }

    /// Production Unix-domain socket entry. Legacy checkpoint list retains
    /// prior behavior; explicit response_version 1 is refused before work.
    public func dispatchUnixSocket(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        await Self.$rpcWireTransport.withValue(.unix) {
            await dispatchManagedHostUnix(req)
        }
    }

    private func dispatchManagedHostUnix(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        let params = req.params ?? [:]
        if req.method == "bot.context.grant" || req.method == "bot.context.revoke" {
            return .init(id: req.id, error: JSONRPCError(code: -32098, message: "Bot context grants require an authenticated paired connection or native UI."))
        }
        if ["bot.conversation.enqueue", "bot.conversation.export.preview", "bot.conversation.export"].contains(req.method) {
            return .init(id: req.id, error: JSONRPCError(code: -32098, message: "Contextual data operations require an authenticated paired connection or native UI."))
        }
        let peerReceiptMethod = params["method"]?.stringValue
        let isPeerReceiptStatus = req.method == "bot.peer.receipt.status"
            || (req.method == "bot.receipt.status"
                && peerReceiptMethod.map(Self.managedPeerReceiptMethods.contains) == true)
        let isPeer = req.method == "bot.peer.list"
            || req.method == "bot.peer.ask"
            || req.method == "bot.peer.status"
            || req.method == "bot.peer.cancel"
            || req.method == "bot.peer.self_config"
            || isPeerReceiptStatus
        let isHost = RemoteCodeHostCatalog.rpcMethods.contains(req.method)
        guard isPeer || isHost else {
            return await dispatchLocalIPC(req)
        }
        // Peer consultation/self-configuration is already constrained by the
        // exact bearer and Bot grant. It remains available to supervised runs;
        // only host catalog mutations require full-access admission.
        let mutation: Bool
        if req.method == RemoteCodeHostCatalog.hostCallRPC {
            mutation = !Self.titioReadOnlyMethod(params["method"]?.stringValue ?? "")
        } else if req.method == RemoteCodeHostCatalog.hostBatchRPC {
            mutation = params["calls"]?.arrayValue?.contains {
                !Self.titioReadOnlyMethod($0.objectValue?["method"]?.stringValue ?? "")
            } ?? true
        } else {
            mutation = isHost && RemoteCodeHostCatalog.rpcMutationMethods.contains(req.method)
        }
        do {
            try authenticateManagedHostParams(params, mutation: mutation, method: req.method)
        } catch let error as JSONRPCError {
            return .init(id: req.id, error: error)
        } catch {
            return .init(id: req.id, error: Self.mapDomainError(error, method: req.method))
        }
        if req.method == RemoteCodeHostCatalog.hostCallRPC {
            return await dispatchTitioHostCall(req)
        }
        if req.method == RemoteCodeHostCatalog.hostBatchRPC {
            return await dispatchTitioHostBatch(req)
        }
        return await Self.$managedProviderSocketAuthenticated.withValue(true) {
            if Self.managedPeerReceiptMethods.contains(req.method) || isPeerReceiptStatus {
                let context: MutationRequestContext
                do {
                    context = try managedPeerMutationContext(params)
                } catch let error as JSONRPCError {
                    return .init(id: req.id, error: error)
                } catch {
                    return .init(id: req.id, error: Self.mapDomainError(error, method: req.method))
                }
                if isPeerReceiptStatus {
                    return commandReceiptStatus(
                        req,
                        context: context,
                        allowedMethods: Self.managedPeerReceiptMethods,
                        includeCommittedResult: true,
                        peerIdentity: params
                    )
                }
                guard let clientRequestId = params["client_request_id"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !clientRequestId.isEmpty else {
                    return .init(id: req.id, error: JSONRPCError(
                        code: -32097,
                        message: "Mutation requires a non-empty client_request_id."
                    ))
                }
                RemoteCodeHostCatalogDiagnostics.receipt(
                    decision: "claim",
                    method: req.method,
                    operationID: clientRequestId
                )
                return await dispatchRemoteMutation(req, context: context)
            }
            if isHost, RemoteCodeHostCatalog.rpcMutationMethods.contains(req.method) {
                guard let clientRequestId = params["client_request_id"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !clientRequestId.isEmpty else {
                    RemoteCodeHostCatalogDiagnostics.receipt(
                        decision: "missing_operation_id",
                        method: req.method,
                        operationID: "-"
                    )
                    return .init(id: req.id, error: JSONRPCError(
                        code: -32097,
                        message: "Mutation requires a non-empty client_request_id."
                    ))
                }
                RemoteCodeHostCatalogDiagnostics.receipt(
                    decision: "claim",
                    method: req.method,
                    operationID: clientRequestId
                )
                let runID = params["run_id"]?.stringValue ?? ""
                return await dispatchRemoteMutation(
                    req,
                    context: MutationRequestContext(
                        ownerFingerprint: runID.lowercased(),
                        hostId: "unix-host-catalog",
                        bootEpoch: 0
                    )
                )
            }
            return await dispatchLocalIPC(req)
        }
    }

    /// Inner methods `host.call` refuses: the managed provider aliases and batches,
    /// so a call cannot re-enter this path or skip its own authentication.
    nonisolated static func titioHostCallAdmits(_ method: String) -> Bool {
        !method.isEmpty && method != "rpc.batch"
            && !managedProviderSocketMethods.contains(method)
            && !method.hasPrefix("host.") && !method.hasPrefix("bot.peer.")
    }

    nonisolated private static func titioReadOnlyMethod(_ method: String) -> Bool {
        titioHostCallAdmits(method) && (readOnlyBatchMethods.contains(method) || method == "agent.activity.list")
    }

    nonisolated private static var titioHostMethods: [String] {
        readOnlyBatchMethods.union(HostMutationContract.methods)
            .union(["agent.activity.list", "agent.thread.fork", "agent.thread.side", "agent.thread.side.close", "agent.thread.btw"])
            .filter {
                titioHostCallAdmits($0)
                    && !["private.", "sync.", "events.", "token_saver.", "command."].contains(where: $0.hasPrefix)
            }.sorted()
    }

    /// Independent calls retain their own identities: a lost batch reply can be
    /// retried as a batch or as individual calls without repeating mutations.
    private func dispatchTitioHostBatch(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        let params = req.params ?? [:]
        do {
            guard let thread = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                  try router.managedHostCallerIsTitio(threadID: thread) else {
                throw JSONRPCError(code: -32098, message: "rc_host_batch is available only to Titio.")
            }
            guard let calls = params["calls"]?.arrayValue, (1...20).contains(calls.count) else {
                throw JSONRPCError.invalidParams
            }
            var operations = Set<String>()
            var requests: [JSONRPCRequest] = []
            for (index, call) in calls.enumerated() {
                guard let object = call.objectValue,
                      let method = object["method"]?.stringValue,
                      Self.titioHostMethods.contains(method),
                      Self.titioReadOnlyMethod(method) || Self.hostMutationMethods.contains(method),
                      object["params"] == nil || object["params"]?.objectValue != nil,
                      let operation = object["operation_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !operation.isEmpty, operations.insert(operation).inserted else {
                    throw JSONRPCError(code: -32602, message: "Each batch call needs a supported method, object params and a distinct non-empty operation_id.")
                }
                var child = params
                child.removeValue(forKey: "calls")
                child["method"] = .string(method)
                child["params"] = object["params"] ?? .object([:])
                child["client_request_id"] = .string(operation)
                requests.append(.init(jsonrpc: "2.0", id: .number(index), method: RemoteCodeHostCatalog.hostCallRPC, params: child))
            }
            var results: [JSONValue] = []
            for (index, request) in requests.enumerated() {
                // Reauthenticate every step: a previous action may stop this run
                // or revoke its permission. Never inherit an earlier admission.
                let response: JSONRPCResponse
                if Task.isCancelled {
                    response = .init(id: request.id, error: JSONRPCError(code: -32800, message: "Batch cancelled before this call started."))
                } else {
                    response = await dispatchManagedHostUnix(request)
                }
                var result: [String: JSONValue] = [
                    "index": .number(Double(index)),
                    "method": request.params?["method"] ?? .null,
                    "operation_id": request.params?["client_request_id"] ?? .null,
                ]
                if let error = response.error { result["error"] = encode(error) }
                else { result["result"] = response.result ?? .null }
                results.append(.object(result))
            }
            return .init(id: req.id, result: .object(["results": .array(results)]))
        } catch let error as JSONRPCError {
            return .init(id: req.id, error: error)
        } catch {
            return .init(id: req.id, error: .internalError)
        }
    }

    /// `host.call` lets Titio run any RemoteCode RPC the app UI or a paired
    /// device can, through the same paired-device mutation path (receipts, host
    /// binding, events). Mutations require fullAccess; known reads do not.
    private func dispatchTitioHostCall(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        let params = req.params ?? [:]
        guard let threadUUID = params["thread_id"]?.stringValue.flatMap(UUID.init),
              let runUUID = params["run_id"]?.stringValue.flatMap(UUID.init),
              let operationID = params["client_request_id"]?.stringValue,
              let method = params["method"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .init(id: req.id, error: .invalidParams)
        }
        let threadID = AgentThreadID(threadUUID)
        do {
            guard try router.managedHostCallerIsTitio(threadID: threadID) else {
                return .init(id: req.id, error: JSONRPCError(code: -32098, message: "rc_host_call is available only to Titio."))
            }
            guard Self.titioHostCallAdmits(method) else {
                return .init(id: req.id, error: JSONRPCError(code: -32602, message: "rc_host_call cannot run \(method)."))
            }
            guard let active = try router.activeAgentDelegation(thread: threadID, run: AgentRunID(runUUID)) else {
                return .init(id: req.id, error: JSONRPCError(code: -32047, message: "Host catalog requires an authenticated active run."))
            }
            var inner: [String: JSONValue] = params["params"]?.objectValue ?? [:]
            if method.hasPrefix("bot.") {
                // Paired devices send their host binding; Titio's is the run's host.
                inner["host_id"] = .string(active.hostId)
            }
            if Self.hostMutationMethods.contains(method) {
                // Deterministic per run, so a replayed operation_id reuses the receipt.
                inner["client_request_id"] = .string(AgentMessageTransport.bodySHA256Hex(
                    "titio-host-call-v1\u{0}\(runUUID.uuidString.lowercased())\u{0}\(operationID)"
                ))
            }
            RemoteCodeHostCatalogDiagnostics.authorization(
                decision: "titio_host_call",
                method: method,
                runID: runUUID.uuidString.lowercased(),
                threadID: threadUUID.uuidString.lowercased()
            )
            let response = await dispatch(
                JSONRPCRequest(jsonrpc: "2.0", id: req.id, method: method, params: inner),
                mutationContext: MutationRequestContext(
                    ownerFingerprint: Self.managedPeerOwnerFingerprint(
                        hostID: active.hostId,
                        threadID: threadUUID.uuidString.lowercased(),
                        runID: runUUID.uuidString.lowercased(),
                        capability: active.capability
                    ),
                    hostId: active.hostId,
                    bootEpoch: 0
                )
            )
            return response
        } catch let error as JSONRPCError {
            return .init(id: req.id, error: error)
        } catch {
            return .init(id: req.id, error: Self.mapDomainError(error, method: method))
        }
    }

    private func managedPeerMutationContext(
        _ params: [String: JSONValue]
    ) throws -> MutationRequestContext {
        guard let threadUUID = params["thread_id"]?.stringValue.flatMap(UUID.init),
              let runUUID = params["run_id"]?.stringValue.flatMap(UUID.init),
              let capability = params[BotPeerDelegation.capabilityRPCParameterKey]?.stringValue,
              !capability.isEmpty else {
            throw JSONRPCError(code: -32047, message: "Host catalog requires an authenticated active run.")
        }
        let threadID = AgentThreadID(threadUUID)
        let runID = AgentRunID(runUUID)
        guard let active = try router.activeAgentDelegation(thread: threadID, run: runID),
              active.threadId == threadID,
              active.runId == runID,
              active.capability == capability,
              active.expiresAt > Date() else {
            throw JSONRPCError(code: -32047, message: "Host catalog requires an authenticated active run.")
        }
        return MutationRequestContext(
            ownerFingerprint: Self.managedPeerOwnerFingerprint(
                hostID: active.hostId,
                threadID: threadUUID.uuidString.lowercased(),
                runID: runUUID.uuidString.lowercased(),
                capability: capability
            ),
            hostId: active.hostId,
            bootEpoch: 0
        )
    }

    nonisolated static func managedPeerOwnerFingerprint(
        hostID: String,
        threadID: String,
        runID: String,
        capability: String
    ) -> String {
        AgentMessageTransport.bodySHA256Hex(
            "peer-receipt-v1\u{0}\(hostID)\u{0}\(threadID.lowercased())\u{0}\(runID.lowercased())\u{0}\(capability)"
        )
    }

    private nonisolated static func managedPeerDelegationFingerprint(_ capability: String) -> String {
        AgentMessageTransport.bodySHA256Hex("peer-delegation-v1\u{0}\(capability)")
    }

    private func authenticateManagedHostParams(
        _ params: [String: JSONValue],
        mutation: Bool,
        method: String
    ) throws {
        guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
              let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init) else {
            RemoteCodeHostCatalogDiagnostics.authorization(
                decision: "missing_run_context",
                method: method,
                runID: params["run_id"]?.stringValue == nil ? "missing" : "present-invalid",
                threadID: params["thread_id"]?.stringValue == nil ? "missing" : "present-invalid"
            )
            throw JSONRPCError(
                code: -32047,
                message: "Host catalog requires an authenticated active run."
            )
        }
        try router.authenticateManagedHostCall(
            threadID: threadID,
            runID: runID,
            delegationCapability: params[BotPeerDelegation.capabilityRPCParameterKey]?.stringValue,
            mutation: mutation,
            method: method
        )
    }

    /// Production HTTP JSON-RPC entry (legacy + explicit v1 checkpoint list).
    public func dispatchHTTP(
        _ req: JSONRPCRequest,
        mutationContext: MutationRequestContext?
    ) async -> JSONRPCResponse {
        await Self.$rpcWireTransport.withValue(.http) {
            await dispatch(req, mutationContext: mutationContext)
        }
    }

    /// Backward-compatible local/test entry point. Production TCP/HTTP code
    /// must never use this context-free overload.
    public func dispatch(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        await dispatchLocalIPC(req)
    }

    public func dispatch(
        _ req: JSONRPCRequest,
        mutationContext: MutationRequestContext?
    ) async -> JSONRPCResponse {
        if Self.managedProviderSocketMethods.contains(req.method),
           !Self.managedProviderSocketAuthenticated {
            return .init(id: req.id, error: .methodNotFound)
        }
        guard let mutationContext else { return await dispatchCore(req) }
        if req.method == "command.receipt.status" {
            return commandReceiptStatus(
                req,
                context: mutationContext,
                allowedMethods: Self.hostMutationMethods
            )
        }
        guard Self.hostMutationMethods.contains(req.method) else {
            return await dispatchCore(req, eventIdentity: mutationContext)
        }
        return await dispatchRemoteMutation(req, context: mutationContext)
    }

    private func dispatchRemoteMutation(
        _ req: JSONRPCRequest,
        context: MutationRequestContext
    ) async -> JSONRPCResponse {
        let params = req.params ?? [:]
        guard let clientRequestId = mutationIdentity(params: params, context: context) else {
            return .init(id: req.id, error: JSONRPCError(
                code: -32097,
                message: "Mutation requires a non-empty client_request_id."
            ))
        }
        var businessParams = HostMutationContract.businessParams(params)
        if (req.method.hasPrefix("bot.") && !req.method.hasPrefix("bot.peer."))
            || (req.method == "scheduled_task.save" && businessParams["bot_id"] != nil) {
            // Paired Bot authority owns a second, user-visible receipt. Preserve
            // its request identity while the Phase 4 ledger supplies response-
            // loss safety, and inject the authenticated host binding rather
            // than accepting a client-declared host id.
            businessParams["client_request_id"] = .string(clientRequestId)
            businessParams["host_id"] = .string(context.hostId)
        } else if req.method == "private.push_token.update" {
            if let declaredHost = businessParams["server_id"]?.stringValue,
               declaredHost != context.hostId {
                return .init(id: req.id, error: JSONRPCError(
                    code: -32098,
                    message: "Push registration host does not match the authenticated host."
                ))
            }
            businessParams["authenticated_host_id"] = .string(context.hostId)
        }
        do {
            try HostMutationContract.preflight(method: req.method, params: businessParams)
        } catch let error as JSONRPCError {
            return .init(id: req.id, error: error)
        } catch {
            return .init(id: req.id, error: .invalidParams)
        }
        let paramsHash: String
        do {
            paramsHash = try HostMutationContract.paramsHash(method: req.method, params)
        } catch {
            return .init(id: req.id, error: .invalidParams)
        }
        let key = "\(req.method):\(clientRequestId)"
        if let unknown = volatileUnknownReceipts[key] {
            if unknown.ownerFingerprint != context.ownerFingerprint {
                commandReceiptMetrics.recordClaim(.ownerMismatch, latencyMilliseconds: 0)
                return receiptFailure(
                    id: req.id,
                    code: -32094,
                    reason: "idempotencyOwnerMismatch",
                    method: req.method,
                    clientRequestId: clientRequestId,
                    retryable: false,
                    requiresSnapshot: false
                )
            }
            if unknown.paramsHash != paramsHash {
                commandReceiptMetrics.recordClaim(.requestMismatch, latencyMilliseconds: 0)
                return receiptFailure(
                    id: req.id,
                    code: -32093,
                    reason: "idempotencyRequestMismatch",
                    method: req.method,
                    clientRequestId: clientRequestId,
                    retryable: false,
                    requiresSnapshot: false
                )
            }
            commandReceiptMetrics.recordClaim(.unknown, latencyMilliseconds: 0)
            return receiptFailure(
                id: req.id,
                code: -32095,
                reason: "commandOutcomeUnknown",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: false,
                requiresSnapshot: true
            )
        }
        // An unchanged alert/legacy push token re-sent on reconnect: the host
        // already holds this exact registration, so answer before the durable
        // claim. No receipt, settings write or private.push_token.updated event.
        if req.method == "private.push_token.update",
           let probe = PrivatePushRegistrationProbe.make(from: businessParams),
           router.privatePushRegistrationIsCurrent(probe) {
            commandReceiptMetrics.recordPushTokenUnchangedSkip()
            return .init(id: req.id, result: probe.result)
        }
        // workspace.select: reject a syntactically valid but absent workspace
        // before the durable claim so the failure is a stable domain error and
        // never becomes permanent commandOutcomeUnknown. Skip when a prior
        // receipt already exists so committed/unknown/in-progress replay paths
        // remain unchanged.
        if req.method == "workspace.select",
           let domainRejection = workspaceSelectAbsenceRejectionBeforeClaim(
            id: req.id,
            businessParams: businessParams,
            clientRequestId: clientRequestId,
            ownerFingerprint: context.ownerFingerprint
           ) {
            return domainRejection
        }
        guard let receiptRouter = router as? CommandReceiptStateRouting else {
            return receiptFailure(
                id: req.id,
                code: -32091,
                reason: "commandReceiptUnavailable",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: true,
                requiresSnapshot: false
            )
        }

        let claim: CommandReceiptClaimResult
        let claimStarted = DispatchTime.now().uptimeNanoseconds
        let offMainReceiptWriter = receiptRouter.commandReceiptOffMainWriter
        do {
            if let offMainReceiptWriter {
                claim = try await offMainReceiptWriter.claim(
                    method: req.method,
                    clientRequestId: clientRequestId,
                    ownerFingerprint: context.ownerFingerprint,
                    paramsHash: paramsHash
                )
            } else {
                claim = try receiptRouter.claimCommandReceipt(
                    method: req.method,
                    clientRequestId: clientRequestId,
                    ownerFingerprint: context.ownerFingerprint,
                    paramsHash: paramsHash
                )
            }
            commandReceiptMetrics.recordClaim(
                claim,
                latencyMilliseconds: Self.elapsedMilliseconds(since: claimStarted)
            )
        } catch {
            commandReceiptMetrics.recordClaimFailure(
                latencyMilliseconds: Self.elapsedMilliseconds(since: claimStarted)
            )
            return receiptFailure(
                id: req.id,
                code: -32091,
                reason: "commandReceiptUnavailable",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: true,
                requiresSnapshot: false
            )
        }

        switch claim {
        case .claimed:
            break
        case .inProgress:
            return receiptFailure(
                id: req.id,
                code: -32096,
                reason: "commandInProgress",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: true,
                requiresSnapshot: false
            )
        case .committed(let resultJSON):
            guard let data = resultJSON.data(using: .utf8),
                  let result = JSONValue.decode(from: data) else {
                return receiptFailure(
                    id: req.id,
                    code: -32092,
                    reason: "legacyReceiptUnverifiable",
                    method: req.method,
                    clientRequestId: clientRequestId,
                    retryable: false,
                    requiresSnapshot: true
                )
            }
            do { try validatePeerReceipt(method: req.method, params: params, result: result) }
            catch let error as JSONRPCError { return .init(id: req.id, error: error) }
            catch { return .init(id: req.id, error: Self.mapDomainError(error, method: req.method)) }
            return .init(id: req.id, result: result)
        case .unknown:
            return receiptFailure(
                id: req.id,
                code: -32095,
                reason: "commandOutcomeUnknown",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: false,
                requiresSnapshot: true
            )
        case .ownerMismatch:
            return receiptFailure(
                id: req.id,
                code: -32094,
                reason: "idempotencyOwnerMismatch",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: false,
                requiresSnapshot: false
            )
        case .requestMismatch:
            return receiptFailure(
                id: req.id,
                code: -32093,
                reason: "idempotencyRequestMismatch",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: false,
                requiresSnapshot: false
            )
        case .legacyUnverifiable:
            return receiptFailure(
                id: req.id,
                code: -32092,
                reason: "legacyReceiptUnverifiable",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: false,
                requiresSnapshot: true
            )
        }

        var executionParams = businessParams
        if Self.managedPeerReceiptMethods.contains(req.method),
           let capability = params[BotPeerDelegation.capabilityRPCParameterKey] {
            // The domain authority verifies the same live bearer again. It is
            // execution-only: paramsHash and durable receipt storage use the
            // stripped business params plus digest-only owner identity.
            executionParams[BotPeerDelegation.capabilityRPCParameterKey] = capability
        }
        let businessRequest = JSONRPCRequest(
            jsonrpc: req.jsonrpc,
            id: req.id,
            method: req.method,
            params: executionParams
        )
        let eventSink: EventBus.MutationEventSink? = Self.durableSynchronousMutationMethods.contains(req.method)
            ? EventBus.MutationEventSink()
            : nil
        let rejectionRecorder = DefiniteRejectionRecorder()
        let response: JSONRPCResponse
        response = await Self.$definiteRejectionRecorder.withValue(rejectionRecorder) {
            await Self.$centralMutationExecution.withValue(true) {
                if let eventSink {
                    return await EventBus.$activeMutationEventSink.withValue(eventSink) {
                        if Self.canonicalImmediateEventMethods.contains(req.method) {
                            let response = await EventBus.$suppressMutationEventCapture.withValue(true) {
                                await dispatchCore(businessRequest)
                            }
                            if response.error == nil, let result = response.result {
                                publishCanonicalImmediateEvent(
                                    method: req.method,
                                    params: businessParams,
                                    result: result
                                )
                            }
                            return response
                        }
                        return await dispatchCore(businessRequest)
                    }
                }
                return await dispatchCore(businessRequest)
            }
        }
        if response.error != nil, rejectionRecorder.rejected {
            // Rejected before any effect: the outcome is known, so return the
            // domain error and free the request id instead of fencing it as
            // a permanent commandOutcomeUnknown.
            do {
                try receiptRouter.releaseCommandReceiptClaim(
                    method: req.method,
                    clientRequestId: clientRequestId,
                    ownerFingerprint: context.ownerFingerprint,
                    paramsHash: paramsHash
                )
            } catch {
                // The claim may still be durable; fence the id in memory too so
                // a retry cannot read a stuck 'claimed' row as commandInProgress.
                volatileUnknownReceipts.insert(
                    key: key,
                    ownerFingerprint: context.ownerFingerprint,
                    paramsHash: paramsHash
                )
                try? receiptRouter.markCommandReceiptUnknown(
                    method: req.method,
                    clientRequestId: clientRequestId,
                    ownerFingerprint: context.ownerFingerprint,
                    paramsHash: paramsHash
                )
            }
            return response
        }
        guard response.error == nil, let result = response.result else {
            volatileUnknownReceipts.insert(
                key: key,
                ownerFingerprint: context.ownerFingerprint,
                paramsHash: paramsHash
            )
            commandReceiptMetrics.recordUnknownOutcome()
            try? receiptRouter.markCommandReceiptUnknown(
                method: req.method,
                clientRequestId: clientRequestId,
                ownerFingerprint: context.ownerFingerprint,
                paramsHash: paramsHash
            )
            if Self.managedPeerReceiptMethods.contains(req.method),
               response.error?.data?.objectValue?["activity_id"]?.stringValue != nil {
                return response
            }
            return receiptFailure(
                id: req.id,
                code: -32095,
                reason: "commandOutcomeUnknown",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: false,
                requiresSnapshot: true
            )
        }
        let committedResult = peerReceiptResult(
            result,
            method: req.method,
            clientRequestId: clientRequestId,
            context: context,
            params: params
        )
        let successfulResponse = JSONRPCResponse(id: req.id, result: committedResult)
        let finalizationStarted = DispatchTime.now().uptimeNanoseconds
        do {
            if let eventSink {
                let events = try eventSink.seal()
                if let offMainReceiptWriter {
                    // Queued on the delivery lane before this task suspends, so
                    // a later MainActor publish still sorts after these events.
                    _ = try await EventBus.shared.enqueuePersistedCommit(
                        offMainReceiptWriter.finalizeTransaction(
                            method: req.method,
                            clientRequestId: clientRequestId,
                            ownerFingerprint: context.ownerFingerprint,
                            paramsHash: paramsHash,
                            result: committedResult,
                            events: events
                        )
                    ).value()
                } else {
                    _ = try EventBus.shared.commitPersistedEvents { minimumEventSequence in
                        try receiptRouter.finalizeCommandReceipt(
                            method: req.method,
                            clientRequestId: clientRequestId,
                            ownerFingerprint: context.ownerFingerprint,
                            paramsHash: paramsHash,
                            result: committedResult,
                            events: events,
                            minimumEventSequence: minimumEventSequence
                        )
                    }
                }
            } else if let offMainReceiptWriter {
                try await offMainReceiptWriter.commit(
                    method: req.method,
                    clientRequestId: clientRequestId,
                    ownerFingerprint: context.ownerFingerprint,
                    paramsHash: paramsHash,
                    result: committedResult
                )
            } else {
                try receiptRouter.commitCommandReceipt(
                    method: req.method,
                    clientRequestId: clientRequestId,
                    ownerFingerprint: context.ownerFingerprint,
                    paramsHash: paramsHash,
                    result: committedResult
                )
            }
            commandReceiptMetrics.recordFinalization(
                success: true,
                latencyMilliseconds: Self.elapsedMilliseconds(since: finalizationStarted)
            )
            do { try validatePeerReceipt(method: req.method, params: params, result: committedResult) }
            catch let error as JSONRPCError { return .init(id: req.id, error: error) }
            catch { return .init(id: req.id, error: Self.mapDomainError(error, method: req.method)) }
            return successfulResponse
        } catch {
            commandReceiptMetrics.recordFinalization(
                success: false,
                latencyMilliseconds: Self.elapsedMilliseconds(since: finalizationStarted)
            )
            volatileUnknownReceipts.insert(
                key: key,
                ownerFingerprint: context.ownerFingerprint,
                paramsHash: paramsHash
            )
            commandReceiptMetrics.recordUnknownOutcome()
            try? receiptRouter.markCommandReceiptUnknown(
                method: req.method,
                clientRequestId: clientRequestId,
                ownerFingerprint: context.ownerFingerprint,
                paramsHash: paramsHash
            )
            return receiptFailure(
                id: req.id,
                code: -32095,
                reason: "commandOutcomeUnknown",
                method: req.method,
                clientRequestId: clientRequestId,
                retryable: false,
                requiresSnapshot: true
            )
        }
    }

    private nonisolated static func elapsedMilliseconds(since start: UInt64) -> Double {
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end >= start ? end - start : 0) / 1_000_000
    }

    /// Read-only existence preflight for `workspace.select` only.
    ///
    /// Returns a domain rejection when the UUID is valid but absent from host
    /// workspace state, and only when no durable receipt already exists for
    /// this request identity. Does not claim, mutate selection, or record
    /// unknown receipts.
    private func workspaceSelectAbsenceRejectionBeforeClaim(
        id: JSONRPCID?,
        businessParams: [String: JSONValue],
        clientRequestId: String,
        ownerFingerprint: String
    ) -> JSONRPCResponse? {
        if let receiptRouter = router as? CommandReceiptStateRouting,
           let status = try? receiptRouter.commandReceiptStatus(
            method: "workspace.select",
            clientRequestId: clientRequestId,
            ownerFingerprint: ownerFingerprint
           ),
           status != .absent {
            return nil
        }
        guard let wid = businessParams["id"]?.stringValue
            .flatMap(UUID.init)
            .map(WorkspaceID.init) else {
            return .init(id: id, error: .invalidParams)
        }
        let exists: Bool
        do {
            exists = try router.listWorkspaces().contains { $0.id == wid }
        } catch {
            return .init(id: id, error: Self.mapDomainError(error, method: "workspace.select"))
        }
        guard exists else {
            return .init(
                id: id,
                error: Self.mapDomainError(LayoutError.workspaceNotFound, method: "workspace.select")
            )
        }
        return nil
    }

    private func peerReceiptResult(
        _ result: JSONValue,
        method: String,
        clientRequestId: String,
        context: MutationRequestContext,
        params: [String: JSONValue]
    ) -> JSONValue {
        guard Self.managedPeerReceiptMethods.contains(method),
              var object = result.objectValue,
              let threadID = params["thread_id"]?.stringValue,
              let runID = params["run_id"]?.stringValue,
              let capability = params[BotPeerDelegation.capabilityRPCParameterKey]?.stringValue else {
            return result
        }
        object["command_receipt"] = .object([
            "client_request_id": .string(clientRequestId),
            "host_id": .string(context.hostId),
            "caller_thread_id": .string(threadID.lowercased()),
            "caller_run_id": .string(runID.lowercased()),
            "delegation_fingerprint": .string(Self.managedPeerDelegationFingerprint(capability)),
        ])
        return .object(object)
    }

    private func commandReceiptStatus(
        _ req: JSONRPCRequest,
        context: MutationRequestContext,
        allowedMethods: Set<String>,
        includeCommittedResult: Bool = false,
        peerIdentity: [String: JSONValue]? = nil
    ) -> JSONRPCResponse {
        let params = req.params ?? [:]
        guard let clientRequestId = mutationIdentity(params: params, context: context),
              let method = params["method"]?.stringValue,
              allowedMethods.contains(method),
              let receiptRouter = router as? CommandReceiptStateRouting else {
            return .init(id: req.id, error: .invalidParams)
        }
        let status: CommandReceiptStatusResult
        do {
            status = try receiptRouter.commandReceiptStatus(
                method: method,
                clientRequestId: clientRequestId,
                ownerFingerprint: context.ownerFingerprint
            )
        } catch {
            return receiptFailure(
                id: req.id,
                code: -32091,
                reason: "commandReceiptUnavailable",
                method: method,
                clientRequestId: clientRequestId,
                retryable: true,
                requiresSnapshot: false
            )
        }
        if status == .ownerMismatch {
            return receiptFailure(
                id: req.id,
                code: -32094,
                reason: "idempotencyOwnerMismatch",
                method: method,
                clientRequestId: clientRequestId,
                retryable: false,
                requiresSnapshot: false
            )
        }
        let values: (String, Bool, Bool)
        switch status {
        case .absent: values = ("absent", true, false)
        case .inProgress: values = ("inProgress", true, false)
        case .committed: values = ("committed", false, false)
        case .unknown: values = ("unknown", false, true)
        case .legacyUnverifiable: values = ("legacyUnverifiable", false, true)
        case .ownerMismatch: fatalError("handled above")
        }
        var result: [String: JSONValue] = [
            "status": .string(values.0),
            "method": .string(method),
            "clientRequestId": .string(clientRequestId),
            "retryable": .bool(values.1),
            "requiresSnapshot": .bool(values.2),
        ]
        if let peerIdentity {
            if let threadID = peerIdentity["thread_id"]?.stringValue {
                result["caller_thread_id"] = .string(threadID.lowercased())
            }
            if let runID = peerIdentity["run_id"]?.stringValue {
                result["caller_run_id"] = .string(runID.lowercased())
            }
        }
        if includeCommittedResult, status == .committed {
            guard let committed = router.commandReceipt(
                method: method,
                clientRequestId: clientRequestId
            ) else {
                return receiptFailure(
                    id: req.id,
                    code: -32092,
                    reason: "legacyReceiptUnverifiable",
                    method: method,
                    clientRequestId: clientRequestId,
                    retryable: false,
                    requiresSnapshot: true
                )
            }
            do { try validatePeerReceipt(method: method, params: peerIdentity ?? [:], result: committed) }
            catch let error as JSONRPCError { return .init(id: req.id, error: error) }
            catch { return .init(id: req.id, error: Self.mapDomainError(error, method: method)) }
            result["result"] = committed
        }
        return .init(id: req.id, result: .object(result))
    }

    private func validatePeerReceipt(method: String, params: [String: JSONValue], result: JSONValue) throws {
        guard method == "bot.peer.ask" || method == "bot.peer.cancel" else { return }
        guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else {
            throw JSONRPCError.invalidParams
        }
        try router.validateBotPeerReceipt(callerThread: threadID, result: result)
    }

    /// HTTP-authoritative mutation identity.
    ///
    /// Requires a Stage 3-valid `client_request_id` (trim, length 8...128,
    /// UUID/hex/dash/alnum/`_`). Legacy transport fields (`connection_id`,
    /// `expected_host_id`, `expected_boot_epoch`) are optional and never
    /// authorize or block — WS registry, host/boot freshness, and connection
    /// ownership are not HTTP preconditions.
    private func mutationIdentity(
        params: [String: JSONValue],
        context: MutationRequestContext
    ) -> String? {
        _ = context
        guard let raw = params["client_request_id"]?.stringValue,
              let clientRequestId = MutationClientRequestID.validate(raw) else {
            return nil
        }
        return clientRequestId
    }

    /// Public wrapper over the Stage 3 `client_request_id` gate used by
    /// `mutationIdentity` before receipt claim.
    nonisolated public static func mutationClientRequestID(_ raw: String) -> String? {
        MutationClientRequestID.validate(raw)
    }

    private func receiptFailure(
        id: JSONRPCID?,
        code: Int,
        reason: String,
        method: String,
        clientRequestId: String,
        retryable: Bool,
        requiresSnapshot: Bool
    ) -> JSONRPCResponse {
        .init(id: id, error: JSONRPCError(
            code: code,
            message: reason,
            data: .object([
                "reason": .string(reason),
                "method": .string(method),
                "clientRequestId": .string(clientRequestId),
                "retryable": .bool(retryable),
                "requiresSnapshot": .bool(requiresSnapshot),
            ])
        ))
    }

    private func dispatchCore(
        _ req: JSONRPCRequest,
        eventIdentity: MutationRequestContext? = nil
    ) async -> JSONRPCResponse {
        let id = req.id
        var params = req.params ?? [:]
        do {
            if Self.managedProviderSocketMethods.contains(req.method),
               !Self.managedProviderSocketAuthenticated {
                throw JSONRPCError.methodNotFound
            }
            // Explicit v1 only: HTTP-only + batch-forbidden before repository work.
            // Legacy checkpoint.list keeps prior Unix/WS/batch admission.
            if req.method == AgentCheckpointListContract.method {
                try AgentCheckpointListContract.preflightTransport(
                    method: req.method,
                    transport: Self.rpcWireTransport,
                    inBatch: Self.rpcInBatch,
                    isExplicitV1: AgentCheckpointListContract.isExplicitV1(params: params)
                )
            }
            let hasScopedContext = ["context_key", "context_version", "policy_revision"].contains(where: { params[$0] != nil })
            if req.method.hasPrefix("bot."), !req.method.hasPrefix("bot.context."), hasScopedContext {
                let admitted = (["bot.conversation.list", "bot.conversation.export.preview", "bot.conversation.export"].contains(req.method) && eventIdentity != nil)
                    || ((req.method == "bot.conversation.create" || req.method == "bot.conversation.select" || req.method == "bot.conversation.enqueue") && Self.centralMutationExecution)
                guard admitted else {
                    throw JSONRPCError(code: -32602, message: "Context resource unavailable.")
                }
            }
            if req.method == "bot.context.list", let eventIdentity {
                params["host_id"] = .string(eventIdentity.hostId)
            } else if req.method == "bot.conversation.enqueue", let eventIdentity {
                params["host_id"] = .string(eventIdentity.hostId)
            } else if ["bot.conversation.list", "bot.conversation.export.preview", "bot.conversation.export"].contains(req.method), hasScopedContext, let eventIdentity {
                params["host_id"] = .string(eventIdentity.hostId)
            }
            if req.method.hasPrefix("bot."), !req.method.hasPrefix("bot.peer.") {
                let result = try await router.dispatchPairedBotRemote(method: req.method, params: params)
                return .init(id: id, result: result)
            }
            switch req.method {
            case "rpc.batch":
                guard case .array(let calls) = params["calls"] ?? .null else { throw JSONRPCError.invalidParams }
                // Checkpoint-specific admission only: reject explicit v1 items
                // before any sibling executes. Do not apply global item/byte caps
                // here — those would change compatibility for every other RPC.
                for callValue in calls {
                    guard let call = callValue.objectValue,
                          let method = call["method"]?.stringValue else {
                        throw JSONRPCError.invalidParams
                    }
                    let callParams = call["params"]?.objectValue ?? [:]
                    try AgentCheckpointListContract.preflightTransport(
                        method: method,
                        transport: Self.rpcWireTransport,
                        inBatch: true,
                        isExplicitV1: AgentCheckpointListContract.isExplicitV1(params: callParams)
                    )
                    guard Self.isReadOnlyBatchMethod(method) else {
                        return .init(id: id, error: JSONRPCError(
                            code: -32602,
                            message: "Batch only supports read-only RPC methods.",
                            data: .string(method)
                        ))
                    }
                }
                var results: [JSONValue] = []
                for (index, callValue) in calls.enumerated() {
                    guard let call = callValue.objectValue,
                          let method = call["method"]?.stringValue else {
                        throw JSONRPCError.invalidParams
                    }
                    let callParams = call["params"]?.objectValue ?? [:]
                    let response = await Self.$rpcInBatch.withValue(true) {
                        await dispatchCore(JSONRPCRequest(
                            jsonrpc: "2.0",
                            id: .number(index),
                            method: method,
                            params: callParams
                        ), eventIdentity: eventIdentity)
                    }
                    if let error = response.error {
                        results.append(.object([
                            "error": .object([
                                "code": .number(Double(error.code)),
                                "message": .string(error.message)
                            ])
                        ]))
                    } else {
                        results.append(response.result ?? .null)
                    }
                }
                return .init(id: id, result: .array(results))
            case "system.ping":
                return .init(id: id, result: .object(["pong": .bool(true), "ts": .number(Date().timeIntervalSince1970)]))
            case "system.capabilities":
                var agentCapabilities: [String: JSONValue] = [
                    "providers": .array([.string("codex"), .string("claude"), .string("grok")]),
                    "supports_stream_events": .bool(true),
                    "supports_resume": .bool(true),
                    // Always present while PlanNotesProjectionV1 is compiled in
                    // this target. Same helper as DirectHTTPServer.capabilitiesPayload
                    // so authorities cannot drift on the old-host negotiation gate.
                    "plan_notes": PlanNotesProjectionV1.CapabilityAdvertisement.jsonValue,
                    "checkpoint_list": AgentCheckpointListCapabilityV1.jsonValue,
                    // Same flag as DirectHTTPServer.capabilitiesProjection.
                    "manual_actions_v1": .bool(true),
                    // Same flag as DirectHTTPServer.capabilitiesProjection.
                    "thread_actor_v1": .bool(true),
                    // Same flag as DirectHTTPServer.capabilitiesProjection.
                    "run_recovery_action_v1": .bool(true),
                    // Same flag as DirectHTTPServer.capabilitiesProjection.
                    "attachment_get_v1": .bool(true),
                    // Same flag as DirectHTTPServer.capabilitiesProjection.
                    "message_image_get_v1": .bool(true),
                    // Same flag as DirectHTTPServer.capabilitiesProjection.
                    "account_usage_get_v1": .bool(true),
                    "agent_activity": .object(["protocol_version": .number(1)]),
                    // Same flag as DirectHTTPServer.capabilitiesProjection.
                    "scheduled_tasks_v1": .bool(true),
                    // agent.activity.list section "just_finished".
                    "activity_just_finished_v1": .bool(true)
                ]
                if let attachmentUpload =
                    agentAttachmentUploadCapability {
                    agentCapabilities["attachment_upload"] =
                        attachmentUpload.jsonValue
                }
                return .init(id: id, result: .object([
                    "app": .string("remotecode"),
                    "api_version": .string("2"),
                    "surface_types": .array([.string("terminal"), .string("ssh"), .string("browser"), .string("agentApp"), .string("files"), .string("markdown"), .string("filePreview"), .string("rightSidebarTool")]),
                    "ssh": .object([
                        "methods": .array([
                            .string("ssh.host.list"),
                            .string("ssh.host.upsert"),
                            .string("ssh.host.delete"),
                            .string("ssh.connect"),
                            .string("ssh.disconnect"),
                            .string("ssh.transfer.upload"),
                            .string("ssh.transfer.download"),
                            .string("ssh.files.local.list"),
                            .string("ssh.files.remote.list")
                        ])
                    ]),
                    "agent": .object(agentCapabilities),
                    "message_transport":
                        AgentMessageTransport.capabilityMarker,
                    "browser_automation": .object([
                        "p0": .array([.string("navigate"), .string("back"), .string("forward"), .string("reload"), .string("url.get"), .string("mirror_url.get")]),
                        "p1_unsupported": .bool(false)
                    ]),
                    "files": .object([
                        "methods": .array([
                            .string("fs.workspace.list"),
                            .string("fs.workspace.read"),
                            .string("fs.workspace.preview_url"),
                            .string("fs.workspace.create_file"),
                            .string("fs.workspace.rename"),
                            .string("fs.workspace.delete"),
                            .string("files.tab.open"),
                            .string("files.tab.split"),
                            .string("files.state.get"),
                            .string("files.state.update"),
                            .string("files.edit.session"),
                            .string("files.ai.complete"),
                            .string("files.edit.open"),
                            .string("files.edit.apply_patch"),
                            .string("files.edit.save"),
                            .string("files.edit.discard"),
                            .string("files.edit.close")
                        ])
                    ]),
                    "git": .object(["read_only": .bool(false)])
                ]))
            case "system.identify":
                return .init(id: id, result: .object([
                    "app": .string("remotecode"),
                    "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))
                ]))
            case "events.recent":
                let sinceSeq = params["since_seq"]?.intValue.map(Int64.init) ?? 0
                let maxBytes = params["max_bytes"]?.intValue
                // C8: `durable: true` (after the welcome capability
                // `events.durable_replay_v1`) replays the event log when the
                // ring no longer reaches the cursor. Absent keeps the old shape.
                let durable: Bool
                switch params["durable"] {
                case nil: durable = false
                case .bool(let value)?: durable = value
                default: throw JSONRPCError.invalidParams
                }
                let result: EventBus.RecentEventsResult
                var streamGaps: [EventBus.StreamGap] = []
                if durable {
                    // Only a cursor whose boot `resume_host_id` +
                    // `resume_boot_epoch` prove (this boot, or the clean
                    // previous one) may replay the event log; without them
                    // the ring serves it or the caller needs a baseline.
                    let resumeHost: String?
                    switch params["resume_host_id"] {
                    case nil: resumeHost = nil
                    case .string(let value)?: resumeHost = value
                    default: throw JSONRPCError.invalidParams
                    }
                    let resumeEpoch: Int64?
                    switch params["resume_boot_epoch"] {
                    case nil: resumeEpoch = nil
                    case let value?:
                        guard let epoch = value.intValue else { throw JSONRPCError.invalidParams }
                        resumeEpoch = Int64(epoch)
                    }
                    let identity = eventIdentity.map { ($0.hostId, Int64($0.bootEpoch)) }
                    // The event-log read uses the read-only connection, off main.
                    (result, streamGaps) = await Task.detached(priority: .userInitiated) {
                        let bus = EventBus.shared
                        guard resumeHost != nil || resumeEpoch != nil, let identity else {
                            return bus.durableRecentEvents(
                                since: sinceSeq, maxBytes: maxBytes, allowEventLog: false
                            )
                        }
                        let accepted = DurableReplayContract.acceptedResume(
                            requestedSinceSequence: sinceSeq,
                            requestedResumeHost: resumeHost,
                            requestedResumeBootEpoch: resumeEpoch,
                            serverId: identity.0,
                            bootEpoch: identity.1,
                            currentSequence: bus.currentSeq,
                            previousBoot: bus.previousBootReplay
                        )
                        guard accepted.eventLog else {
                            // A cursor from another host or an unrecoverable
                            // boot: nothing after it can be trusted.
                            let head = bus.currentSeq
                            return (EventBus.RecentEventsResult(
                                lastSeq: head, events: [], truncated: true, requiresBaseline: true
                            ), [])
                        }
                        return bus.durableRecentEvents(
                            since: accepted.since,
                            maxBytes: maxBytes,
                            previousBoot: accepted.previousBoot
                        )
                    }.value
                } else {
                    result = EventBus.shared.recentEvents(since: sinceSeq, maxBytes: maxBytes)
                }
                let arr: [JSONValue] = result.events.map { ev in
                    var envelope: [String: JSONValue] = [
                        "seq": .number(Double(ev.seq)),
                        "kind": .string(ev.kind),
                        "payload": ev.payload,
                        "ts": .number(ev.ts),
                        "treaty_version": .object([
                            "major": .number(1),
                            "minor": .number(0),
                        ]),
                    ]
                    if let eventIdentity {
                        envelope["host_id"] = .string(eventIdentity.hostId)
                        envelope["boot_epoch"] = .number(Double(eventIdentity.bootEpoch))
                    }
                    return .object(envelope)
                }
                var response: [String: JSONValue] = [
                    "last_seq": .number(Double(result.lastSeq)),
                    "events": .array(arr),
                    "truncated": .bool(result.truncated),
                    "requires_baseline": .bool(result.requiresBaseline),
                    "treaty_version": .object([
                        "major": .number(1),
                        "minor": .number(0),
                    ]),
                ]
                if durable {
                    response["stream_gaps"] = .array(streamGaps.map { gap in
                        var object: [String: JSONValue] = [
                            "since_seq": .number(Double(gap.sinceSequence)),
                            "through_seq": .number(Double(gap.throughSequence)),
                        ]
                        switch gap.stream {
                        case .thread(let id): object["thread_id"] = .string(id)
                        case .surface(let id): object["surface_id"] = .string(id)
                        }
                        return .object(object)
                    })
                }
                if let eventIdentity {
                    response["host_id"] = .string(eventIdentity.hostId)
                    response["boot_epoch"] = .number(Double(eventIdentity.bootEpoch))
                }
                return .init(id: id, result: .object(response))
            case "settings.get":
                let keys: [String]
                if case .array(let arr) = params["keys"] ?? .null {
                    keys = arr.compactMap { $0.stringValue }
                } else {
                    keys = ["theme", "remote_access_enabled", "provider.default", "first_run_completed"]
                }
                let values = try router.settingsGet(keys: keys)
                return .init(id: id, result: .object(values.mapValues { .string($0) }))
            case "settings.set":
                guard let key = params["key"]?.stringValue,
                      let value = params["value"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.settingsSet(key: key, value: value)
                EventBus.shared.publish(kind: .settingsUpdated, payload: .object([
                    "key": .string(key),
                    "value": .string(value)
                ]))
                return .init(id: id, result: .bool(true))
            case "ssh.host.list":
                let workspace = try workspaceID(from: params)
                let listed = try router.sshHostList(workspace: workspace).map { host -> SSHHostProfile in
                    var h = host; h.password = nil; return h
                }
                return .init(id: id, result: encode(listed))
            case "ssh.host.upsert":
                let workspace = try workspaceID(from: params)
                let profile = try sshProfile(from: params)
                let saved = try router.sshHostUpsert(profile, workspace: workspace)
                var redacted = saved
                redacted.password = nil
                var payload = encode(redacted).objectValue ?? [:]
                payload["workspace_id"] = .string(workspace.value.uuidString)
                EventBus.shared.publish(kind: .sshHostUpdated, payload: .object(payload))
                return .init(id: id, result: encode(redacted))
            case "ssh.host.delete":
                let workspace = try workspaceID(from: params)
                guard let raw = params["id"]?.stringValue,
                      let uuid = UUID(uuidString: raw) else { throw JSONRPCError.invalidParams }
                try router.sshHostDelete(SSHHostID(uuid), workspace: workspace)
                EventBus.shared.publish(kind: .sshHostDeleted, payload: .object([
                    "id": .string(raw),
                    "workspace_id": .string(workspace.value.uuidString)
                ]))
                return .init(id: id, result: .bool(true))
            case "ssh.connect":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                // UX-010: idempotent connect — a retried request must not
                // open a duplicate SSH surface.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let pid: PaneID? = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let profileID = params["profile_id"]?.stringValue.flatMap(UUID.init).map(SSHHostID.init)
                let profile = try optionalSSHProfile(from: params)
                let s = try withSuppressedLayoutEvents {
                    try router.sshConnect(workspace: wid, profileID: profileID, profile: profile, title: params["title"]?.stringValue, paneID: pid)
                }
                EventBus.shared.publish(kind: .surfaceCreated, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(s)
                ]))
                EventBus.shared.publish(kind: .sshSessionUpdated, payload: .object([
                    "surface_id": .string(s.id.value.uuidString),
                    "status": .string(s.metadata["ssh_status"] ?? "connected"),
                    "destination": .string(s.metadata["ssh_destination"] ?? "")
                ]))
                let result = encode(s)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "ssh.disconnect":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) ?? params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.sshDisconnect(surface: sid)
                EventBus.shared.publish(kind: .sshSessionUpdated, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "status": .string("disconnected")
                ]))
                return .init(id: id, result: .bool(true))
            case "ssh.transfer.upload":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) ?? params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let local = params["local_path"]?.stringValue,
                      let remote = params["remote_path"]?.stringValue else { throw JSONRPCError.invalidParams }
                EventBus.shared.publish(kind: .sshTransferStarted, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "direction": .string("upload"),
                    "local_path": .string(local),
                    "remote_path": .string(remote)
                ]))
                let result = try await router.sshTransferUploadAsync(surface: sid, localPath: local, remotePath: remote)
                EventBus.shared.publish(kind: .sshTransferFinished, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "direction": .string("upload"),
                    "result": result
                ]))
                return .init(id: id, result: result)
            case "ssh.transfer.download":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) ?? params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let remote = params["remote_path"]?.stringValue,
                      let local = params["local_path"]?.stringValue else { throw JSONRPCError.invalidParams }
                EventBus.shared.publish(kind: .sshTransferStarted, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "direction": .string("download"),
                    "local_path": .string(local),
                    "remote_path": .string(remote)
                ]))
                let result = try await router.sshTransferDownloadAsync(surface: sid, remotePath: remote, localPath: local)
                EventBus.shared.publish(kind: .sshTransferFinished, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "direction": .string("download"),
                    "result": result
                ]))
                return .init(id: id, result: result)
            case "ssh.files.local.list":
                return .init(id: id, result: try router.sshFilesLocalList(path: params["path"]?.stringValue))
            case "ssh.files.remote.mkdir", "ssh.files.remote.rename", "ssh.files.remote.delete":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) ?? params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let operation: SSHRemoteFileOperation
                switch req.method {
                case "ssh.files.remote.mkdir":
                    guard let path = params["path"]?.stringValue, !path.isEmpty else { throw JSONRPCError.invalidParams }
                    operation = .mkdir(path: path)
                case "ssh.files.remote.rename":
                    guard let from = params["from_path"]?.stringValue, !from.isEmpty,
                          let to = params["to_path"]?.stringValue, !to.isEmpty else { throw JSONRPCError.invalidParams }
                    operation = .rename(from: from, to: to)
                default:
                    guard let path = params["path"]?.stringValue, !path.isEmpty else { throw JSONRPCError.invalidParams }
                    operation = .delete(path: path)
                }
                let result = try await router.sshFilesRemoteManage(surface: sid, operation: operation)
                EventBus.shared.publish(kind: .sshFilesRemoteChanged, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "action": .string(String(req.method.dropFirst("ssh.files.remote.".count))),
                    "paths": .array(operation.paths.map { .string($0) })
                ]))
                return .init(id: id, result: result)
            case "ssh.files.remote.list":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) ?? params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try await router.sshFilesRemoteListAsync(surface: sid, path: params["path"]?.stringValue))
            case "fs.roots":
                return .init(id: id, result: .object(["roots": fsRoots()]))
            case "fs.list":
                let raw = params["path"]?.stringValue
                return .init(id: id, result: try fsList(raw))
            case "fs.mkdir":
                guard let raw = params["path"]?.stringValue, !raw.isEmpty else { throw JSONRPCError.invalidParams }
                let created = try fsMkdir(raw)
                EventBus.shared.publish(kind: .fsChanged, payload: .object([
                    "action": .string("mkdir"),
                    "paths": .array([.string(created)])
                ]))
                return .init(id: id, result: .object(["path": .string(created)]))
            case "fs.workspace.list":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.fsWorkspaceList(workspace: wid, path: params["path"]?.stringValue))
            case "fs.workspace.read":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.fsWorkspaceRead(workspace: wid, path: path, maxBytes: params["max_bytes"]?.intValue))
            case "fs.workspace.preview_url":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.fsWorkspacePreviewURL(workspace: wid, path: path))
            case "fs.workspace.create_file":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                let result = try router.fsWorkspaceCreateFile(workspace: wid, path: path, content: params["content"]?.stringValue ?? "")
                EventBus.shared.publish(kind: .fsWorkspaceChanged, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "action": .string("create_file"),
                    "paths": .array([.string(result.objectValue?["relative_path"]?.stringValue ?? path)])
                ]))
                return .init(id: id, result: result)
            case "fs.workspace.rename":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue,
                      let newName = params["new_name"]?.stringValue else { throw JSONRPCError.invalidParams }
                let result = try router.fsWorkspaceRename(workspace: wid, path: path, newName: newName)
                EventBus.shared.publish(kind: .fsWorkspaceChanged, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "action": .string("rename"),
                    "paths": .array([.string(path), .string(result.objectValue?["relative_path"]?.stringValue ?? newName)])
                ]))
                return .init(id: id, result: result)
            case "fs.workspace.delete":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let paths = params["paths"]?.arrayValue?.compactMap { $0.stringValue }
                    ?? params["path"]?.stringValue.map { [$0] }
                    ?? []
                let result = try router.fsWorkspaceDelete(workspace: wid, paths: paths)
                EventBus.shared.publish(kind: .fsWorkspaceChanged, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "action": .string("delete"),
                    "paths": result.objectValue?["deleted"] ?? .array(paths.map { .string($0) })
                ]))
                return .init(id: id, result: result)
            case "files.tab.open":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                let sourceSurface = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init)
                let pid = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let surface = try withSuppressedLayoutEvents {
                    try router.filesOpenTab(workspace: wid, sourceSurface: sourceSurface, paneID: pid, path: path)
                }
                EventBus.shared.publish(kind: .surfaceCreated, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(surface)
                ]))
                return .init(id: id, result: encode(surface))
            case "files.tab.split":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let dirStr = params["direction"]?.stringValue,
                      let dir = SplitDirection(rawValue: dirStr),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                let sourceSurface = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init)
                let pid = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let surface = try withSuppressedLayoutEvents {
                    try router.filesSplitTab(workspace: wid, sourceSurface: sourceSurface, paneID: pid, direction: dir, path: path)
                }
                EventBus.shared.publish(kind: .paneSplit, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(surface)
                ]))
                return .init(id: id, result: encode(surface))
            case "files.state.get":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesStateGet(surface: sid))
            case "files.state.update":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let patch = params["patch"]?.objectValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesStateUpdate(surface: sid, patch: patch, baseRevision: params["base_revision"]?.intValue, deviceID: params["device_id"]?.stringValue))
            case "files.edit.session":
                guard let sessionID = params["session_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditSession(sessionID: sessionID))
            case "files.ai.complete":
                guard let sessionID = params["session_id"]?.stringValue,
                      let revision = params["draft_revision"]?.intValue,
                      let caret = params["caret_utf16"]?.intValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try await router.filesAIComplete(sessionID: sessionID, draftRevision: revision, caretUTF16: caret))
            case "files.edit.open":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditOpen(surface: sid, path: path))
            case "files.edit.apply_patch":
                guard let sessionID = params["session_id"]?.stringValue,
                      let base = params["base_draft_revision"]?.intValue,
                      let range = params["range_utf16"]?.objectValue,
                      let location = range["location"]?.intValue,
                      let length = range["length"]?.intValue,
                      let replacement = params["replacement"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditApplyPatch(sessionID: sessionID, baseDraftRevision: base, rangeLocation: location, rangeLength: length, replacement: replacement, deviceID: params["device_id"]?.stringValue))
            case "files.edit.save":
                guard let sessionID = params["session_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditSave(sessionID: sessionID))
            case "files.edit.discard":
                guard let sessionID = params["session_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditDiscard(sessionID: sessionID))
            case "files.edit.close":
                guard let sessionID = params["session_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditClose(sessionID: sessionID))
            case "workspace.list", "host.workspace.list":
                let ws = try await router.listWorkspacesAuthoritative()
                return .init(id: id, result: encode(ws))
            case "workspace.current":
                let w = try router.currentWindow()
                return .init(id: id, result: encode(w))
            case "workspace.create", "host.workspace.create":
                // UX-010: idempotent create — a retried request over a flaky
                // mobile link must not produce a duplicate workspace.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let name = params["name"]?.stringValue ?? "workspace"
                let cwd = params["cwd"]?.stringValue ?? FileManager.default.currentDirectoryPath
                let ws = try withSuppressedLayoutEvents {
                    try router.createWorkspace(name: name, cwd: cwd)
                }
                EventBus.shared.publish(kind: .workspaceCreated, payload: encode(ws))
                let result = encode(ws)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "workspace.select":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.selectWorkspace(wid)
                }
                EventBus.shared.publish(kind: .workspaceSelected, payload: .object(["workspace_id": .string(wid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "workspace.close":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                try router.closeWorkspace(wid, publishEvent: false)
                EventBus.shared.publish(kind: .workspaceClosed, payload: .object(["workspace_id": .string(wid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "workspace.rename":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let name = params["name"]?.stringValue else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.renameWorkspace(wid, name)
                }
                EventBus.shared.publish(kind: .workspaceRenamed, payload: .object(["workspace_id": .string(wid.value.uuidString), "name": .string(name)]))
                return .init(id: id, result: .bool(true))
            case "workspace.set_description":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let text = params["description"]?.stringValue ?? params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.setWorkspaceDescription(wid, text)
                }
                EventBus.shared.publish(kind: .workspaceUpdated, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "metadata": .object(["description": .string(text)])
                ]))
                return .init(id: id, result: .bool(true))
            case "workspace.set_color":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let color = params["color"]?.stringValue else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.setWorkspaceColor(wid, color)
                }
                EventBus.shared.publish(kind: .workspaceUpdated, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "metadata": .object(["color": .string(color)])
                ]))
                return .init(id: id, result: .bool(true))
            case "workspace.set_pinned":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let pinned = params["pinned"]?.boolValue else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.setWorkspacePinned(wid, pinned)
                }
                EventBus.shared.publish(kind: .workspaceUpdated, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "metadata": .object(["pinned": pinned ? .string("true") : .string("")])
                ]))
                let order = try router.currentWindow().workspaces
                EventBus.shared.publish(kind: .workspaceReordered, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "order": .array(order.map { .string($0.value.uuidString) })
                ]))
                return .init(id: id, result: .bool(true))
            case "workspace.reorder":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let pos = params["position"]?.intValue ?? 0
                try withSuppressedLayoutEvents {
                    try router.reorderWorkspace(wid, position: pos)
                }
                let order = try router.currentWindow().workspaces
                EventBus.shared.publish(kind: .workspaceReordered, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "position": .number(Double(pos)),
                    "order": .array(order.map { .string($0.value.uuidString) })
                ]))
                return .init(id: id, result: .bool(true))
            case "surface.create":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let tStr = params["type"]?.stringValue,
                      let type = SurfaceType(rawValue: normalizeSurfaceTypeString(tStr)) else { throw JSONRPCError.invalidParams }
                // UX-010: idempotent create — a retried request must not
                // produce a duplicate surface/pane.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let pid: PaneID? = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let title = params["title"]?.stringValue
                let s = try withSuppressedLayoutEvents {
                    try router.createSurface(workspace: wid, type: type, paneID: pid, title: title)
                }
                EventBus.shared.publish(kind: .surfaceCreated, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(s)
                ]))
                let result = encode(s)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "surface.split":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let pid = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init),
                      let dirStr = params["direction"]?.stringValue,
                      let dir = SplitDirection(rawValue: dirStr) else { throw JSONRPCError.invalidParams }
                if let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) {
                    try withSuppressedLayoutEvents {
                        try router.splitSurface(workspace: wid, paneID: pid, surface: sid, direction: dir)
                    }
                    EventBus.shared.publish(kind: .surfaceMoved, payload: .object([
                        "workspace_id": .string(wid.value.uuidString),
                        "id": .string(sid.value.uuidString)
                    ]))
                    return .init(id: id, result: .bool(true))
                }
                guard let tStr = params["type"]?.stringValue,
                      let type = SurfaceType(rawValue: normalizeSurfaceTypeString(tStr)) else { throw JSONRPCError.invalidParams }
                let title = params["title"]?.stringValue
                let s = try withSuppressedLayoutEvents {
                    try router.splitPane(workspace: wid, paneID: pid, direction: dir, surfaceType: type, title: title)
                }
                EventBus.shared.publish(kind: .paneSplit, payload: .object(["workspace_id": .string(wid.value.uuidString), "surface": encode(s)]))
                return .init(id: id, result: encode(s))
            case "surface.close":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.closeSurface(workspace: wid, surface: sid)
                }
                EventBus.shared.publish(kind: .surfaceClosed, payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.focus":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.focusSurface(workspace: wid, surface: sid)
                }
                EventBus.shared.publish(kind: .surfaceFocused, payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.rename":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let title = params["title"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.renameSurface(wid, sid, title)
                EventBus.shared.publish(kind: .surfaceRenamed, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "id": .string(sid.value.uuidString),
                    "title": .string(title)
                ]))
                return .init(id: id, result: .bool(true))
            case "surface.set_color":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let color = params["color"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.setSurfaceColor(wid, sid, color)
                EventBus.shared.publish(kind: .surfaceUpdated, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "id": .string(sid.value.uuidString),
                    "metadata": .object(["color": .string(color)])
                ]))
                return .init(id: id, result: .bool(true))
            case "surface.send_text":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                let result: JSONValue
                if let terminalRouter = router as? TerminalCommandRouting {
                    result = try terminalRouter.sendTextResult(surface: sid, text: text)
                } else {
                    try router.sendText(surface: sid, text: text)
                    // UX-009: fold a liveness check into the response so a
                    // non-terminal surface reports "delivered" only when the
                    // target is alive; a dead surface reports "accepted" + a
                    // warning instead of falsely reading as success.
                    let alive = router.surfaceHealth(surface: sid)
                    result = .object([
                        "status": .string(alive ? "delivered" : "accepted"),
                        "accepted": .bool(true),
                        "delivered": .bool(alive),
                        "surface_alive": .bool(alive)
                    ])
                }
                EventBus.shared.publish(kind: .surfaceUpdated, payload: .object([
                    "id": .string(sid.value.uuidString),
                    "action": .string("send_text")
                ]))
                return .init(id: id, result: result)
            case "surface.send_key":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let key = params["key"]?.stringValue else { throw JSONRPCError.invalidParams }
                let sequence = encodeKey(key)
                let result: JSONValue
                if let terminalRouter = router as? TerminalCommandRouting {
                    result = try terminalRouter.sendTextResult(surface: sid, text: sequence)
                } else {
                    try router.sendText(surface: sid, text: sequence)
                    // UX-009: same delivered/accepted liveness contract as
                    // surface.send_text for non-terminal surfaces.
                    let alive = router.surfaceHealth(surface: sid)
                    result = .object([
                        "status": .string(alive ? "delivered" : "accepted"),
                        "accepted": .bool(true),
                        "delivered": .bool(alive),
                        "surface_alive": .bool(alive)
                    ])
                }
                EventBus.shared.publish(kind: .surfaceUpdated, payload: .object([
                    "id": .string(sid.value.uuidString),
                    "action": .string("send_key")
                ]))
                return .init(id: id, result: result)
            case "surface.health":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                if let terminalRouter = router as? TerminalCommandRouting {
                    return .init(id: id, result: terminalRouter.surfaceHealthDetails(surface: sid))
                }
                let alive = router.surfaceHealth(surface: sid)
                return .init(id: id, result: .object(["alive": .bool(alive)]))
            case "surface.clear_history":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                router.surfaceClearHistory(surface: sid)
                EventBus.shared.publish(kind: .surfaceUpdated, payload: .object([
                    "id": .string(sid.value.uuidString),
                    "action": .string("clear_history")
                ]))
                return .init(id: id, result: .bool(true))
            case "surface.read_text":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                if params["include_metadata"]?.boolValue == true,
                   let terminalRouter = router as? TerminalCommandRouting {
                    // Establish a sequence barrier before reading the main-actor snapshot.
                    // Any later live frame receives a greater sequence, so an iOS client
                    // can reject this body if the RPC response loses the race with newer
                    // output instead of overwriting the newer viewport with stale text.
                    SurfaceOutputBus.shared.flushNow(sid)
                    let snapshotSequence = SurfaceOutputBus.shared.currentSequence(sid)
                    let snapshot = try terminalRouter.readTextSnapshot(surface: sid)
                    guard var fields = snapshot.objectValue else {
                        return .init(id: id, result: snapshot)
                    }
                    fields["surface_seq"] = .number(Double(snapshotSequence))
                    // Optional bounded read, same discipline as surface.read_history.
                    // Absent max_bytes keeps the previous unbounded response, so older
                    // clients are byte-for-byte unaffected.
                    fields = SurfaceReadTextWindow.applied(
                        to: fields,
                        maxBytes: params["max_bytes"]?.intValue
                    )
                    return .init(id: id, result: .object(fields))
                }
                let text = try router.readText(surface: sid)
                let window = SurfaceReadTextWindow.tail(
                    of: text,
                    maxBytes: params["max_bytes"]?.intValue
                )
                return .init(id: id, result: .string(window.text))
            case "surface.read_history":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let before = params["before_chunk_id"]?.intValue.map(Int64.init)
                let maxBytes = params["max_bytes"]?.intValue ?? (256 * 1024)
                // Capture the mirror cursor before suspending. The coordinator
                // serializes its pending write and DB read at this boundary; if
                // the bounded read times out/throws, the outer error response has
                // neither text nor sequence and therefore cannot overwrite iOS.
                SurfaceOutputBus.shared.flushNow(sid)
                let capturedSequence = SurfaceOutputBus.shared.currentSequence(sid)
                let window = try await router.readTerminalHistory(
                    surface: sid,
                    beforeChunkID: before,
                    maxBytes: maxBytes
                )
                var result: [String: JSONValue] = [
                    "text": .string(window.text),
                    "chunks": .array(window.chunks.map { chunk in
                        .object([
                            "id": .number(Double(chunk.id)),
                            "chunk_index": .number(Double(chunk.chunkIndex)),
                            "byte_count": .number(Double(chunk.data.count))
                        ])
                    }),
                    "has_more_older": .bool(window.hasMoreOlder),
                    "next_before_chunk_id": window.nextBeforeChunkID.map { .number(Double($0)) } ?? .null
                ]
                let health = (router as? TerminalCommandRouting)?
                    .surfaceHealthDetails(surface: sid)
                    .objectValue
                result["partial"] = health?["output_partial"] ?? .bool(false)
                result["partial_reason"] = health?["partial_reason"] ?? .null
                result["pending_bytes"] = health?["output_pending_bytes"] ?? .number(0)
                result["surface_seq"] = .number(Double(capturedSequence))
                return .init(id: id, result: .object(result))
            case "agent.open":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let s = try withSuppressedLayoutEvents {
                    try router.openAgentApp(workspace: wid)
                }
                EventBus.shared.publish(kind: .surfaceCreated, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(s)
                ]))
                return .init(id: id, result: encode(s))
            case "token_saver.digest.get":
                return .init(id: id, result: router.tokenSaverDigest() ?? .object([:]))
            case "bot.peer.list":
                guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init) else {
                    throw JSONRPCError.invalidParams
                }
                return .init(
                    id: id,
                    result: try router.listBotPeers(
                        callerThread: threadID,
                        callerRun: runID,
                        delegationCapability: params[BotPeerDelegation.capabilityRPCParameterKey]?.stringValue
                    )
                )
            case "bot.peer.ask":
                guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init),
                      let handle = params["handle"]?.stringValue,
                      let prompt = params["prompt"]?.stringValue,
                      let rawMode = params["reply_mode"]?.stringValue,
                      let replyMode = BotPeerDelegation.ReplyMode(rawValue: rawMode) else {
                    throw JSONRPCError.invalidParams
                }
                let consultationID: UUID?
                if let rawConsultationID = params[BotPeerDelegation.consultationIDParameterKey] {
                    guard let rawValue = rawConsultationID.stringValue,
                          let value = UUID(uuidString: rawValue) else {
                        throw JSONRPCError.invalidParams
                    }
                    consultationID = value
                } else {
                    consultationID = nil
                }
                return .init(
                    id: id,
                    result: try await router.askBotPeer(
                        callerThread: threadID,
                        callerRun: runID,
                        handle: handle,
                        prompt: prompt,
                        replyMode: replyMode,
                        consultationID: consultationID,
                        wait: params["wait"]?.boolValue ?? true,
                        delegationCapability: params[BotPeerDelegation.capabilityRPCParameterKey]?.stringValue
                    )
                )
            case "bot.peer.status", "bot.peer.cancel":
                guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init),
                      let activityID = params["activity_id"]?.stringValue.flatMap(UUID.init) else {
                    throw JSONRPCError.invalidParams
                }
                return .init(id: id, result: try await router.observeBotPeer(
                    callerThread: threadID, callerRun: runID, activityID: activityID,
                    wait: params["wait"]?.boolValue ?? false, cancel: req.method == "bot.peer.cancel",
                    delegationCapability: params[BotPeerDelegation.capabilityRPCParameterKey]?.stringValue))
            case "bot.peer.self_config":
                guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init),
                      let toolName = params["tool_name"]?.stringValue,
                      let arguments = params["arguments"]?.objectValue else {
                    throw JSONRPCError.invalidParams
                }
                return .init(
                    id: id,
                    result: try router.invokeDelegatedBotSelfConfig(
                        callerThread: threadID,
                        callerRun: runID,
                        toolName: toolName,
                        arguments: arguments,
                        delegationCapability: params[BotPeerDelegation.capabilityRPCParameterKey]?.stringValue
                    )
                )
            case "host.bot.create":
                guard let name = params["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty,
                      let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init) else {
                    throw JSONRPCError.invalidParams
                }
                let result = try router.createHostBot(
                    name: name,
                    title: params["title"]?.stringValue ?? "",
                    description: params["description"]?.stringValue ?? "",
                    handle: params["handle"]?.stringValue,
                    soul: params["soul"]?.stringValue ?? "",
                    callerRun: runID
                )
                EventBus.shared.publish(kind: .botCreated, payload: result)
                return .init(id: id, result: result)
            case "host.bot.list":
                return .init(id: id, result: try router.listHostBots())
            case "host.bot.open":
                guard let botID = params["bot_id"]?.stringValue.flatMap(UUID.init).map(BotID.init) else {
                    throw JSONRPCError.invalidParams
                }
                return .init(id: id, result: try router.openHostBot(botID: botID))
            case "host.bot.send":
                guard let botID = params["bot_id"]?.stringValue.flatMap(UUID.init).map(BotID.init),
                      let text = params["text"]?.stringValue,
                      let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init) else {
                    throw JSONRPCError.invalidParams
                }
                let conversationID = params["conversation_id"]?.stringValue
                    .flatMap(UUID.init)
                    .map(BotConversationID.init)
                return .init(
                    id: id,
                    result: try await router.sendHostBot(
                        botID: botID,
                        text: text,
                        conversationID: conversationID,
                        callerThread: threadID,
                        callerRun: runID
                    )
                )
            case "host.activity.list":
                return .init(id: id, result: try await router.listHostActivity(params: params))
            case "host.help":
                let topic = params["topic"]?.stringValue
                let query = params["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let method = params["method"]?.stringValue
                if (params["topic"] != nil && topic == nil)
                    || (params["query"] != nil && query == nil)
                    || (params["method"] != nil && method == nil) { throw JSONRPCError.invalidParams }
                if let method {
                    guard Self.titioHostMethods.contains(method) else {
                        throw JSONRPCError(code: -32602, message: "Unknown host method. Search rc_host_help with query first.")
                    }
                    let mutation = !Self.titioReadOnlyMethod(method)
                    return .init(id: id, result: .object([
                        "method": .string(method),
                        "mutation": .bool(mutation),
                        "batch_supported": .bool(Self.titioReadOnlyMethod(method) || Self.hostMutationMethods.contains(method)),
                        "validation_requirements": .array(HostMutationContract.methods.contains(method)
                            ? HostMutationContract.parameterRequirements(for: method).map(JSONValue.string) : []),
                        "workflows": .array(TitioCapabilities.topics(forHostMethod: method).map {
                            .object(["topic": .string($0.id), "instructions": .string($0.instructions)])
                        }),
                        "usage": .string("Validation requirements describe host entrance checks, not all optional fields. Follow the workflow and preserve current configuration from live reads. The host supplies host_id and client_request_id. Every call needs operation_id; mutations require Full Access."),
                    ]))
                }
                if let topic {
                    guard let guide = TitioCapabilities.topics.first(where: { $0.id == topic }) else {
                        throw JSONRPCError(code: -32602, message: "Unknown topic. Call rc_host_help without topic to list supported interactions.")
                    }
                    var result: [String: JSONValue] = [
                        "topic": .string(guide.id),
                        "title": .string(guide.title),
                        "instructions": .string(guide.instructions),
                    ]
                    if topic == "schedules" {
                        result["bot_schedule_spec_example"] = .string(BotScheduleSpec().encodedJSON())
                    }
                    return .init(id: id, result: .object(result))
                }
                let search = query ?? ""
                let methods = Self.titioHostMethods.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
                let topics = TitioCapabilities.topics.filter {
                    search.isEmpty || "\($0.id) \($0.title) \($0.examples.joined(separator: " ")) \($0.instructions)".localizedCaseInsensitiveContains(search)
                }
                return .init(id: id, result: .object([
                    "topics": .array(topics.map { topic in
                        .object([
                            "id": .string(topic.id), "title": .string(topic.title),
                            "examples": .array(topic.examples.map(JSONValue.string)),
                        ])
                    }),
                    "methods": .array(methods.map { method in
                        .object(["method": .string(method), "mutation": .bool(!Self.titioReadOnlyMethod(method))])
                    }),
                    "usage": .string("Use topic for a workflow, method for validation requirements, or query to narrow this index. Resolve ids from live reads, preserve scope, supply operation_id, then verify outcomes. Use rc_host_batch for independent calls. Methods enforce their normal permissions and availability."),
                ]))
            case "host.bot.delegate":
                guard let bot = params["bot"]?.stringValue,
                      let text = params["text"]?.stringValue,
                      let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init) else {
                    throw JSONRPCError.invalidParams
                }
                return .init(
                    id: id,
                    result: try await router.delegateHostBot(
                        bot: bot,
                        text: text,
                        conversationID: params["conversation_id"]?.stringValue
                            .flatMap(UUID.init)
                            .map(BotConversationID.init),
                        callerThread: threadID,
                        callerRun: runID
                    )
                )
            case "host.browser.screenshot":
                guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else {
                    throw DefiniteMutationRejection(JSONRPCError.invalidParams)
                }
                let surface: SurfaceID?
                if let raw = params["surface_id"]?.stringValue {
                    guard let uuid = UUID(uuidString: raw) else { throw DefiniteMutationRejection(JSONRPCError.invalidParams) }
                    surface = SurfaceID(uuid)
                } else if params["surface_id"] != nil {
                    throw DefiniteMutationRejection(JSONRPCError.invalidParams)
                } else {
                    surface = nil
                }
                let reason = params["reason"]?.stringValue ?? "Screenshot of Mac browser"
                guard !reason.isEmpty, reason.count <= 500 else { throw DefiniteMutationRejection(JSONRPCError.invalidParams) }
                return .init(id: id, result: try router.captureHostBrowserToChat(callerThread: threadID, surface: surface, reason: reason))
            case "host.chat.image":
                guard let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let raw = params["paths"]?.arrayValue else {
                    throw DefiniteMutationRejection(JSONRPCError.invalidParams)
                }
                let paths = raw.compactMap(\.stringValue)
                guard paths.count == raw.count, !paths.isEmpty,
                      paths.count <= RemoteCodeHostCatalog.chatImageMaxPaths else {
                    throw DefiniteMutationRejection(JSONRPCError(
                        code: -32602,
                        message: "Pass 1-\(RemoteCodeHostCatalog.chatImageMaxPaths) image paths."
                    ))
                }
                let caption = params["caption"]?.stringValue
                guard (caption?.count ?? 0) <= 500 else { throw DefiniteMutationRejection(JSONRPCError.invalidParams) }
                return .init(id: id, result: try router.postChatImages(callerThread: threadID, paths: paths, caption: caption))
            case "host.scheduled_task.run_next":
                guard let workspace = params["workspace"]?.stringValue else {
                    throw JSONRPCError.invalidParams
                }
                let taskID: UUID?
                if let raw = params["task_id"]?.stringValue {
                    guard let parsed = UUID(uuidString: raw) else { throw JSONRPCError.invalidParams }
                    taskID = parsed
                } else {
                    taskID = nil
                }
                return .init(id: id, result: try router.runNextHostScheduledTask(workspace: workspace, taskID: taskID))
            case "host.bot.thread.create":
                guard let botID = params["bot_id"]?.stringValue.flatMap(UUID.init).map(BotID.init) else {
                    throw JSONRPCError.invalidParams
                }
                return .init(
                    id: id,
                    result: try router.createHostBotThread(
                        botID: botID,
                        title: params["title"]?.stringValue ?? "New thread"
                    )
                )
            case "host.bot.skill.create":
                guard let botID = params["bot_id"]?.stringValue.flatMap(UUID.init).map(BotID.init),
                      let skillID = params["skill_id"]?.stringValue,
                      let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init),
                      let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else {
                    throw JSONRPCError.invalidParams
                }
                return .init(
                    id: id,
                    result: try router.createHostBotSkill(
                        botID: botID,
                        skillID: skillID,
                        body: params["body"]?.stringValue,
                        callerRun: runID,
                        callerThread: threadID
                    )
                )
            case "host.bot.skill.view":
                guard let botID = params["bot_id"]?.stringValue.flatMap(UUID.init).map(BotID.init),
                      let skillID = params["skill_id"]?.stringValue,
                      let runID = params["run_id"]?.stringValue.flatMap(UUID.init).map(AgentRunID.init),
                      let threadID = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else {
                    throw JSONRPCError.invalidParams
                }
                return .init(
                    id: id,
                    result: try router.viewHostBotSkill(
                        botID: botID,
                        skillID: skillID,
                        callerRun: runID,
                        callerThread: threadID
                    )
                )
            case "agent.thread.list", "host.agent.thread.list":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let threads = try await router.listAgentThreadsOffMain(workspace: wid)
                // PERF-007: one batch query for all threads instead of N per-thread queries.
                let lockedThreads = (try? await router.threadIdsWithMessagesOffMain()) ?? []
                // One store read for every thread's pending_manual_action.
                let manualActions = router.pendingManualActions(for: threads)
                // One off-main query for every thread's guest_runtime.
                let guestRuntimes = await router.threadGuestRuntimesOffMain()
                return .init(id: id, result: .array(threads.map {
                    encodeThread($0, lockedThreads: lockedThreads, pendingManualActions: manualActions, guestRuntimes: guestRuntimes)
                }))
            case "agent.thread.fork", "host.agent.thread.fork":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let messageID = params["message_id"]?.stringValue
                let forked = try await router.forkAgentThread(sourceThreadId: tid, messageID: messageID)
                return .init(id: id, result: encodeThread(forked))
            case "agent.thread.side", "host.agent.thread.side":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let text = params["text"]?.stringValue
                let side = try await router.sideAgentThread(sourceThreadId: tid, text: text)
                return .init(id: id, result: encodeThread(side))
            case "agent.thread.side.close", "host.agent.thread.side.close":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                try await router.closeSideThread(threadId: tid)
                return .init(id: id, result: .object([:]))
            case "agent.thread.btw", "host.agent.thread.btw":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let question = params["question"]?.stringValue else { throw JSONRPCError.invalidParams }
                let answer = try await router.btwAgentThread(threadId: tid, question: question)
                return .init(id: id, result: .object(["answer": .string(answer)]))
            case "agent.thread.create", "host.agent.thread.create":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let title = params["title"]?.stringValue ?? "New thread"
                let modelSelection = try modelSelection(from: params)
                let provider = modelSelection?.provider ?? (AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue ?? "fake-model"
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init) ?? .fullAccess
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init) ?? .medium
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init) ?? .auto
                let providerInstanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let runAsUser = decodeRunAsUser(from: params["run_as_user"] ?? params["runAsUser"])
                let createSurfaceID = (params["surface_id"]?.stringValue ?? params["surfaceId"]?.stringValue).flatMap(UUID.init).map(SurfaceID.init)
                let routing = try routingRequest(from: params, requireManualSelection: true)
                let nestedRunContext = try nestedRunContext(from: params)
                var t = try await router.createAgentThreadRouting(workspace: wid, title: title, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId, runAsUser: runAsUser, surfaceID: createSurfaceID, routing: routing, nestedRunContext: nestedRunContext)
                if params["worker_model"] != nil { t = try router.setAgentWorkerModel(thread: t.id, model: workerModel(from: params)) }
                EventBus.shared.publish(kind: .agentThreadCreated, payload: threadPayload(t))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.configure":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let modelSelection = try modelSelection(from: params)
                let provider = modelSelection?.provider ?? params["provider"]?.stringValue.flatMap(AgentProvider.init)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init)
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init)
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init)
                let providerInstanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let runAsUser = decodeRunAsUser(from: params["run_as_user"] ?? params["runAsUser"])
                let routing = try routingRequest(from: params, requireManualSelection: true)
                var t = try await router.configureAgentThreadRouting(thread: tid, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId, runAsUser: runAsUser, routing: routing)
                if params["worker_model"] != nil { t = try router.setAgentWorkerModel(thread: tid, model: workerModel(from: params)) }
                var payload: [String: JSONValue] = [
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "provider": .string(t.provider.rawValue),
                    "model": .string(t.model)
                ]
                payload["provider_instance_id"] = t.providerInstanceId.map { .string($0) } ?? .null
                payload["providerInstanceId"] = t.providerInstanceId.map { .string($0) } ?? .null
                payload["permission_mode"] = .string(t.permissionMode.rawValue)
                payload["reasoning_effort"] = .string(t.reasoningEffort.rawValue)
                payload["service_tier"] = .string(t.serviceTier.rawValue)
                payload["model_selection"] = encode(t.modelSelection)
                payload["run_as_user"] = encodeRunAsUser(t.runAsUser)
                payload["runAsUser"] = encodeRunAsUser(t.runAsUser)
                payload["provider_locked"] = .bool(providerLocked(t))
                payload["providerLocked"] = .bool(providerLocked(t))
                appendFlatModelSelection(t, to: &payload)
                appendRouting(t.effectiveRoutingConfiguration, to: &payload)
                // A provider change can move a bot-locked thread's guest marker.
                appendThreadActor(t, guestRuntime: router.threadGuestRuntime(thread: t.id), to: &payload)
                EventBus.shared.publish(kind: .agentThreadUpdated, payload: .object(payload))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.execution.configure":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let modeValue = params["execution_mode"]?.stringValue,
                      let mode = AgentExecutionMode(rawValue: modeValue) else { throw JSONRPCError.invalidParams }
                let t = try router.configureAgentThreadExecution(thread: tid, executionMode: mode, baseBranch: params["base_branch"]?.stringValue)
                EventBus.shared.publish(kind: .agentThreadUpdated, payload: threadPayload(t))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.prepare_pr":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let url = params["url"]?.stringValue else { throw JSONRPCError.invalidParams }
                let modelSelection = try modelSelection(from: params)
                let provider = modelSelection?.provider ?? (AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue ?? "fake-model"
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init) ?? .fullAccess
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init) ?? .medium
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init) ?? .auto
                let providerInstanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let t = try router.prepareAgentThreadForPullRequest(workspace: wid, url: url, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId)
                EventBus.shared.publish(kind: .agentThreadCreated, payload: threadPayload(t))
                EventBus.shared.publish(kind: .agentThreadSelected, payload: .object([
                    "thread_id": .string(t.id.value.uuidString)
                ]))
                return .init(id: id, result: encodeThread(t))
            case "agent.attachment.upload":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let filename = params["filename"]?.stringValue,
                      let dataBase64 = params["data_base64"]?.stringValue ?? params["dataBase64"]?.stringValue else { throw JSONRPCError.invalidParams }
                let uploaded = try router.uploadAgentAttachment(workspace: wid, filename: filename, mimeType: params["mime_type"]?.stringValue ?? params["mimeType"]?.stringValue, dataBase64: dataBase64)
                EventBus.shared.publish(kind: .agentAttachmentUploaded, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "id": .string(uploaded.id),
                    "display_name": .string(uploaded.displayName),
                    "sha256": .string(uploaded.sha256),
                    "size_bytes": .number(Double(uploaded.sizeBytes))
                ]))
                return .init(id: id, result: encode(uploaded))
            case "agent.attachment.import":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let relativePath = params["relative_path"]?.stringValue else { throw JSONRPCError.invalidParams }
                let imported = try router.importAgentAttachment(workspace: wid, relativePath: relativePath)
                EventBus.shared.publish(kind: .agentAttachmentUploaded, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "id": .string(imported.id),
                    "display_name": .string(imported.displayName),
                    "sha256": .string(imported.sha256),
                    "size_bytes": .number(Double(imported.sizeBytes))
                ]))
                return .init(id: id, result: encode(imported))
            case "agent.thread.select":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let selectSurfaceID = (params["surface_id"]?.stringValue ?? params["surfaceId"]?.stringValue).flatMap(UUID.init).map(SurfaceID.init)
                do {
                    try router.selectAgentThread(thread: tid, surfaceID: selectSurfaceID)
                } catch LayoutError.workspaceNotFound {
                    // Missing thread: rejected before any selection changed.
                    throw DefiniteMutationRejection(LayoutError.workspaceNotFound)
                }
                EventBus.shared.publish(kind: .agentThreadSelected, payload: .object(["thread_id": .string(tid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "agent.message.send":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let modelSelection = try modelSelection(from: params)
                let provider = modelSelection?.provider ?? params["provider"]?.stringValue.flatMap(AgentProvider.init)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init)
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init)
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init)
                let interactionMode = params["interaction_mode"]?.stringValue.flatMap(AgentInteractionMode.init)
                let providerInstanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let attachments = try agentAttachments(from: params["attachments"])
                let routing = try routingRequest(from: params, requireManualSelection: false)
                let nestedRunContext = try nestedRunContext(from: params)
                if routing?.mode == .auto,
                   ["provider", "provider_instance_id", "providerInstanceId", "model", "reasoning_effort", "service_tier", "model_selection", "distill_main_effort", "worker_model", "worker_effort", "distill_ultracode"].contains(where: { params[$0] != nil }) {
                    throw JSONRPCError.invalidParams
                }
                if params["worker_model"] != nil { _ = try router.setAgentWorkerModel(thread: tid, model: workerModel(from: params)) }
                let sendResult: AgentMessageSendResult
                do {
                    sendResult = try await router.sendAgentMessageRouting(
                        thread: tid,
                        text: text,
                        provider: provider,
                        model: model,
                        permissionMode: permission,
                        reasoningEffort: reasoning,
                        serviceTier: serviceTier,
                        interactionMode: interactionMode,
                        modelSelection: modelSelection,
                        providerInstanceId: providerInstanceId,
                        attachments: attachments,
                        routing: routing,
                        nestedRunContext: nestedRunContext
                    )
                } catch let rejection as DefiniteMutationRejection where params["worker_model"] != nil {
                    // The worker model was already written above, so this
                    // request is no longer effect-free.
                    throw rejection.underlying
                }
                let result = messageSendResultPayload(sendResult)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.message.queue.list":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: .array(try await router.listAgentQueuedMessagesOffMain(thread: tid).map(queuedMessagePayload)))
            case "agent.message.queue.update":
                guard let qid = params["queued_message_id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init)
                        ?? params["id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init),
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let updated = try await router.updateAgentQueuedMessage(id: qid, text: text, attachments: try agentAttachments(from: params["attachments"]))
                let result = queuedMessagePayload(updated)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.message.queue.cancel":
                guard let qid = params["queued_message_id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init)
                        ?? params["id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let cancelled = try router.cancelAgentQueuedMessage(id: qid)
                let result = queuedMessagePayload(cancelled)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.message.queue.force_now":
                guard let qid = params["queued_message_id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init)
                        ?? params["id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let forced = try await router.forceAgentQueuedMessageNow(id: qid)
                let result = messageSendResultPayload(forced)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.message.queue.reorder":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let qid = params["queued_message_id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init)
                        ?? params["id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init),
                      let position = params["position"]?.intValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try router.reorderAgentQueuedMessage(thread: tid, id: qid, position: position)
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.plan.implement":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let planId = params["plan_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let modelSelection = try modelSelection(from: params)
                let provider = modelSelection?.provider ?? params["provider"]?.stringValue.flatMap(AgentProvider.init)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init)
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init)
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init)
                let implemented = try await router.implementAgentPlan(
                    thread: tid,
                    planId: planId,
                    planMarkdown: params["markdown"]?.stringValue,
                    newThread: params["new_thread"]?.boolValue ?? false,
                    provider: provider,
                    model: model,
                    permissionMode: permission,
                    reasoningEffort: reasoning,
                    serviceTier: serviceTier,
                    modelSelection: modelSelection
                )
                EventBus.shared.publish(kind: .agentPlanImplemented, payload: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "plan_id": .string(planId),
                    "implementation_thread_id": .string(implemented.implementationThreadId.value.uuidString),
                    "run_id": .string(implemented.runId.value.uuidString)
                ]))
                let result: JSONValue = .object([
                    "run_id": .string(implemented.runId.value.uuidString),
                    "implementation_thread_id": .string(implemented.implementationThreadId.value.uuidString)
                ])
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.plan.save":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let planId = params["plan_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let saved = try router.saveAgentPlan(
                    thread: tid,
                    planId: planId,
                    planMarkdown: params["markdown"]?.stringValue,
                    relativePath: params["relative_path"]?.stringValue
                )
                let result: JSONValue = .object([
                    "path": .string(saved.path),
                    "relative_path": .string(saved.relativePath)
                ])
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.plan.notes.get":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                // Opt-in protocol_version 1: bounded UTF-8 page. Absent version
                // keeps the legacy full-string shape so old clients stay green.
                // Present-but-invalid must not silently downgrade.
                let caps = try PlanNotesProjectionV1.parseCaps(params)
                let notes = try router.agentPlanNotes(thread: tid)
                if let caps {
                    let page = try PlanNotesProjectionV1.page(notes: notes, caps: caps)
                    return .init(id: id, result: page.json)
                }
                return .init(id: id, result: .object(["notes": .string(notes)]))
            case "agent.plan.notes.save":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let notes = params["notes"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                // Opt-in protocol_version 1: digest CAS (no full prior body on the
                // wire). Absent version keeps legacy expected_notes full-body CAS.
                // Present-but-invalid must not silently downgrade.
                if let saveCaps = try PlanNotesProjectionV1.parseSaveCaps(params) {
                    let current = try router.agentPlanNotes(thread: tid)
                    if PlanNotesProjectionV1.contentDigest(of: current) != saveCaps.expectedContentDigest {
                        throw DefiniteMutationRejection(PlanNotesProjectionV1.saveDigestMismatchError(
                            currentNotes: current,
                            expectedDigest: saveCaps.expectedContentDigest
                        ))
                    }
                    try router.saveAgentPlanNotes(thread: tid, notes: notes)
                    let result = PlanNotesProjectionV1.saveResult(notes: notes)
                    recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                    return .init(id: id, result: result)
                }
                if let expected = params["expected_notes"]?.stringValue,
                   try router.agentPlanNotes(thread: tid) != expected {
                    throw DefiniteMutationRejection(JSONRPCError(
                        code: -32009,
                        message: "Plan notes changed on another device.",
                        data: nil
                    ))
                }
                try router.saveAgentPlanNotes(thread: tid, notes: notes)
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.message.list":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let limit = params["limit"]?.intValue ?? 200
                if let responseVersion = params["response_version"] {
                    guard responseVersion.intValue == 1,
                          let rawBudget = params["max_body_bytes"]?.intValue else {
                        throw JSONRPCError.invalidParams
                    }
                    let maxBodyBytes = AgentMessageTransport.clampListMaxBodyBytes(rawBudget)
                    guard AgentMessageTransport.supportsResponseBudget(
                        maxBodyBytes
                    ) else {
                        throw JSONRPCError.invalidParams
                    }
                    let before = try v1MessageCursor(
                        from: params["before"]
                    )
                    let after = try v1MessageCursor(
                        from: params["after"]
                    )
                    guard before == nil || after == nil else {
                        throw JSONRPCError.invalidParams
                    }
                    let budgeted: AgentMessageBodyBudgetResult
                    do {
                        budgeted = try await router
                            .listAgentMessagesWithinBodyBudgetOffMain(
                                thread: tid,
                                limit: limit,
                                before: before,
                                after: after,
                                budget: maxBodyBytes,
                                contentLimit:
                                    AgentMessageTransport.sqlContentLimit(
                                        for: maxBodyBytes
                                    )
                            )
                    } catch AgentMessagePageCursorError.staleOrInvalid {
                        throw JSONRPCError(
                            code: -32044,
                            message:
                                "The message-list cursor is stale or invalid.",
                            data: .object([
                                "domain": .string("agent.message"),
                                "kind":
                                    .string("message_cursor_invalid"),
                            ])
                        )
                    }
                    guard let result = AgentMessageTransport.v1ListResult(
                        from: budgeted,
                        maxResponseBytes: maxBodyBytes,
                        responseID: id,
                        basePayload: messagePayload,
                        encodeCursor: v1MessageCursorPayload
                    ) else {
                        throw JSONRPCError(
                            code: -32041,
                            message:
                                "The requested message-list envelope is too small.",
                            data: .object([
                                "domain": .string("agent.message"),
                                "kind":
                                    .string("list_envelope_too_small"),
                                "min_bytes": .number(
                                    Double(
                                        AgentMessageTransport
                                            .minimumResponseBytes
                                    )
                                ),
                                "requested_bytes":
                                    .number(Double(maxBodyBytes)),
                            ])
                        )
                    }
                    return .init(id: id, result: result)
                }
                if params["pagination"]?.boolValue == true || params["page"]?.boolValue == true {
                    let page = try await router.listAgentMessagesPageOffMain(
                        thread: tid,
                        limit: limit,
                        before: messageCursor(from: params["before"]),
                        after: messageCursor(from: params["after"])
                    )
                    return .init(id: id, result: messagePagePayload(page))
                }
                return .init(id: id, result: .array(try await router.listAgentMessagesOffMain(thread: tid, limit: limit).map(messagePayload)))
            case "agent.message.get":
                guard let mid = params["message_id"]?.stringValue.flatMap(UUID.init).map(AgentMessageID.init) else { throw JSONRPCError.invalidParams }
                if let responseVersion = params["response_version"] {
                    guard responseVersion.intValue == 1,
                          let rawMaxBytes = params["max_bytes"]?.intValue,
                          let offsetBytes = params["offset_bytes"]?.intValue
                    else {
                        throw JSONRPCError.invalidParams
                    }
                    let maxBytes = AgentMessageTransport.clampGetMaxBytes(
                        rawMaxBytes
                    )
                    guard AgentMessageTransport.supportsResponseBudget(
                        maxBytes
                    ) else {
                        throw JSONRPCError.invalidParams
                    }
                    if offsetBytes > 0 {
                        guard params["expected_body_revision"]?.intValue != nil,
                              params["expected_body_sha256"]?.stringValue != nil else {
                            throw JSONRPCError.invalidParams
                        }
                    }
                    let chunk: AgentMessageBodyChunk
                    do {
                        guard let loaded = try router
                            .getAgentMessageBodyChunk(
                                id: mid,
                                offsetBytes: offsetBytes,
                                maxContentBytes: maxBytes,
                                expectedBodyRevision:
                                    params["expected_body_revision"]?
                                        .intValue,
                                expectedBodySHA256:
                                    params["expected_body_sha256"]?
                                        .stringValue
                            ) else {
                            throw JSONRPCError.invalidParams
                        }
                        chunk = loaded
                    } catch let error as AgentMessageBodyChunkError {
                        switch error {
                        case .invalidOffset:
                            throw JSONRPCError.invalidParams
                        case .bodyRevisionConflict:
                            throw JSONRPCError(
                                code: -32042,
                                message:
                                    "The message body changed while paging.",
                                data: .object([
                                    "domain": .string("agent.message"),
                                    "kind":
                                        .string("body_revision_conflict"),
                                ])
                            )
                        case .bodyDigestMismatch:
                            throw JSONRPCError(
                                code: -32042,
                                message:
                                    "The message body digest changed while paging.",
                                data: .object([
                                    "domain": .string("agent.message"),
                                    "kind":
                                        .string("body_digest_mismatch"),
                                ])
                            )
                        case .bodyIdentityUnavailable:
                            throw JSONRPCError(
                                code: -32043,
                                message:
                                    "The message body identity is unavailable.",
                                data: .object([
                                    "domain": .string("agent.message"),
                                    "kind":
                                        .string("body_identity_unavailable"),
                                ])
                            )
                        }
                    }
                    guard let result = AgentMessageTransport.v1GetResult(
                        chunk: chunk,
                        maxResponseBytes: maxBytes,
                        responseID: id,
                        basePayload: messagePayload
                    ) else {
                        throw JSONRPCError.invalidParams
                    }
                    return .init(id: id, result: result)
                }
                guard let message = try router.getAgentMessage(id: mid) else {
                    throw JSONRPCError.invalidParams
                }
                return .init(id: id, result: messagePayload(message))
            case "agent.run.stop":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try router.stopAgentRun(thread: tid)
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.run.continue":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let continuedRunId = try await router.continueAgentRun(thread: tid)
                let result: JSONValue = continuedRunId.map { .object(["run_id": .string($0.value.uuidString)]) } ?? .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.request.respond":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let requestId = params["request_id"]?.stringValue,
                      let decision = params["decision"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let response: AgentProviderRequestResponse
                switch decision {
                case "approve": response = .approve
                case "approve_for_session", "approveForSession": response = .approveForSession
                case "decline": response = .decline(params["message"]?.stringValue)
                case "cancel": response = .cancel
                default: throw JSONRPCError.invalidParams
                }
                try await router.respondAgentRequest(thread: tid, requestId: requestId, response: response)
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.user_input.respond":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let requestId = params["request_id"]?.stringValue,
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try await router.respondAgentUserInput(thread: tid, requestId: requestId, text: text)
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.pending_callbacks.list":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try await router.listAgentPendingCallbacksOffMain(thread: tid)))
            case "agent.attachment.get":
                let request = try AgentAttachmentGetWire.request(from: params)
                return .init(id: id, result: try await router.getAgentAttachment(request))
            case "agent.message.image.get":
                let request = try AgentMessageImageGetWire.request(from: params)
                return .init(id: id, result: try await router.getAgentMessageImage(request))
            case "agent.account.usage.get":
                return .init(id: id, result: try await router.getAgentAccountUsage())
            case "agent.activity.list":
                return .init(id: id, result: try await router.activityListOffMain(params: params))
            case "agent.activity.viewed.set":
                return .init(id: id, result: try router.activitySetViewed(params: params))
            case "agent.activity.acknowledge":
                return .init(id: id, result: try router.activityAcknowledge(params: params))
            case "scheduled_task.list":
                return .init(id: id, result: try router.listScheduledTasksRemote())
            case "scheduled_task.save":
                return .init(id: id, result: try await router.saveScheduledTaskRemote(params: params))
            case "scheduled_task.delete":
                guard let taskID = params["task_id"]?.stringValue.flatMap(UUID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.deleteScheduledTaskRemote(id: taskID))
            case "scheduled_task.enable":
                guard let taskID = params["task_id"]?.stringValue.flatMap(UUID.init),
                      let enabled = params["enabled"]?.boolValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try await router.enableScheduledTaskRemote(id: taskID, enabled: enabled))
            case "scheduled_task.run":
                guard let taskID = params["task_id"]?.stringValue.flatMap(UUID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.runScheduledTaskRemote(id: taskID))
            case "agent.manual_action.list":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let actions = try router.listManualActions(thread: tid)
                return .init(id: id, result: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "manual_actions": .array(actions.map(ManualActionWire.row)),
                    "pending_manual_action": ManualActionWire.pendingRow(actions.last { $0.request.state.isOpen }),
                ]))
            case "agent.manual_action.resolve":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let actionID = params["manual_action_id"]?.stringValue.flatMap(UUID.init),
                      let resolution = params["action"]?.stringValue.flatMap(ManualActionResolution.init) else {
                    throw JSONRPCError.invalidParams
                }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let outcome = try await router.resolveManualAction(
                    thread: tid, id: actionID, resolution: resolution, note: params["note"]?.stringValue
                )
                let followUp: JSONValue
                switch outcome.followUp {
                case nil:
                    followUp = .null
                case .sent(let sent)?:
                    var object = messageSendResultPayload(sent).objectValue ?? [:]
                    object["delivered"] = .bool(true)
                    followUp = .object(object)
                case .failed(let message)?:
                    followUp = .object(["delivered": .bool(false), "error": .string(message)])
                }
                let result: JSONValue = .object([
                    "thread_id": .string(tid.value.uuidString),
                    "manual_action": ManualActionWire.row(outcome.manualAction),
                    "pending_manual_action": ManualActionWire.pendingRow(outcome.pending),
                    "follow_up": followUp,
                ])
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.actor.set":
                // HostMutationContract preflight already checked the shapes.
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let actor = ThreadActorWire.parseActor(params["actor"]) else { throw JSONRPCError.invalidParams }
                let target = params["execution_target"]?.stringValue.flatMap(ExecutionTarget.init(rawValue:))
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let t = try await router.setAgentThreadActor(thread: tid, actor: actor, executionTarget: target)
                let result: JSONValue = .object(threadActorResult(t))
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.mac_execution.resolve":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let approve = params["approve"]?.boolValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let outcome = try await router.resolveMacExecutionRemote(thread: tid, approve: approve)
                let followUp: JSONValue
                switch outcome.followUp {
                case .sent(let sent):
                    var object = messageSendResultPayload(sent).objectValue ?? [:]
                    object["delivered"] = .bool(true)
                    followUp = .object(object)
                case .failed(let message):
                    followUp = .object(["delivered": .bool(false), "error": .string(message)])
                }
                var resolved = threadActorResult(outcome.thread)
                resolved["approved"] = .bool(outcome.approved)
                resolved["follow_up"] = followUp
                let result: JSONValue = .object(resolved)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.read":
                // response_version absent → exact legacy shapes (array or watermark object).
                // response_version present → integral 1 only; validate before repository work.
                if let caps = try AgentThreadReadV1.parseCaps(params) {
                    let snapshot = try await router.readAgentThreadMirrorSnapshot(
                        thread: caps.threadId,
                        eventRowLimit: caps.eventLimit,
                        maxPayloadBytes: Int64(caps.maxBytes)
                    )
                    // Run-error decoration needs the router (MainActor); resolve
                    // it per distinct error row here, then encode and
                    // envelope-bound off MainActor (up to 128 events,
                    // ~log2(N) full-envelope measurements per read).
                    var runErrorFields: [ReplayedRunErrorKey: [String: JSONValue]] = [:]
                    for event in snapshot.events {
                        guard case .error(let message, let recoverable) = event else { continue }
                        let key = ReplayedRunErrorKey(message: message, recoverable: recoverable)
                        if runErrorFields[key] == nil {
                            runErrorFields[key] = router.replayedRunErrorFields(message: message, recoverable: recoverable)
                        }
                    }
                    let maxBytes = caps.maxBytes
                    let result = await Task.detached(priority: .userInitiated) { [runErrorFields] in
                        Self.threadReadV1Result(
                            snapshot: snapshot,
                            maxBytes: maxBytes,
                            id: id,
                            runErrorFields: runErrorFields
                        )
                    }.value
                    return .init(id: id, result: result)
                }
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                if params["include_event_watermark"]?.boolValue == true {
                    let snapshot = try await router.readAgentThreadMirrorSnapshot(
                        thread: tid,
                        eventRowLimit: nil,
                        maxPayloadBytes: nil
                    )
                    let eventLimit = params["event_limit"]?.intValue
                    if let eventLimit, !(1...5_000).contains(eventLimit) {
                        throw JSONRPCError.invalidParams
                    }
                    let events = eventLimit.map { Array(snapshot.events.suffix($0)) }
                        ?? snapshot.events
                    var payload: [String: JSONValue] = [
                        "events": decorateReplayedRunErrors(encode(events)),
                        "event_watermark": .number(Double(snapshot.eventWatermark)),
                        "events_truncated": .bool(events.count < snapshot.events.count)
                    ]
                    appendActiveDelegation(to: &payload, thread: tid)
                    return .init(id: id, result: .object(payload))
                }
                return .init(id: id, result: decorateReplayedRunErrors(encode(try await router.readAgentThreadEvents(thread: tid))))
            case "agent.thread.rollback":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let turnId = params["turn_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try await router.rollbackAgentThread(thread: tid, toTurnId: turnId)
                EventBus.shared.publish(kind: .agentThreadRolledBack, payload: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "turn_id": .string(turnId)
                ]))
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.checkpoint.list":
                // Opt-in only: absent response_version keeps the legacy full-array path.
                // Modern-only params (max_entries/before) without the opt-in are ignored.
                if params["response_version"] != nil {
                    if !AgentCheckpointListContract.acceptsResponseID(id) {
                        // Hostile id cannot be echoed inside the complete-response
                        // cap. Fail closed with id:null and skip repository work.
                        return AgentCheckpointListContract.encodeBoundedErrorResponse(
                            id: nil,
                            error: .invalidRequest
                        )
                    }
                    let v1: AgentCheckpointListContract.V1Request
                    do {
                        v1 = try AgentCheckpointListContract.parseV1Request(
                            id: id,
                            params: params,
                            fullRequest: req
                        )
                    } catch let error as JSONRPCError {
                        return AgentCheckpointListContract.encodeBoundedErrorResponse(
                            id: id,
                            error: error
                        )
                    }
                    let page: AgentTurnCheckpointPage
                    do {
                        page = try await router.listAgentThreadCheckpointsPage(
                            thread: v1.threadId,
                            maxEntries: v1.maxEntries,
                            before: v1.before,
                            expectedCatalogRevision: v1.catalogRevision
                        )
                    } catch let error as AgentTurnCheckpointListError {
                        switch error {
                        case .staleCatalogRevision(let current):
                            return AgentCheckpointListContract.encodeBoundedErrorResponse(
                                id: id,
                                error: AgentCheckpointListContract.staleCursorError(
                                    currentRevision: current
                                )
                            )
                        }
                    }
                    // Freeze + pack on a dedicated non-MainActor queue.
                    let payload = try await AgentCheckpointListContract.freezeAndPackPageAsync(
                        page,
                        responseID: id
                    )
                    return AgentCheckpointListContract.enforceEncodedSuccessCeiling(
                        id: id,
                        result: payload
                    )
                }
                let tid = try AgentCheckpointListContract.preflightLegacyRequest(
                    id: id,
                    params: params,
                    fullRequest: req
                )
                return .init(id: id, result: encode(try router.listAgentThreadCheckpoints(thread: tid)))
            case "agent.checkpoint.diff":
                // QA-XPLAT :19 -- accept both `turn_count` (mac-native) and
                // `checkpoint_turn_count` (what the iOS client sends). Sending only
                // one key made revert/diff fail with -32602 against a real Mac while
                // the iOS fake (which uses checkpoint_turn_count) stayed green.
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let turnCount = (params["turn_count"] ?? params["checkpoint_turn_count"])?.intValue else { throw JSONRPCError.invalidParams }
                let expectedRunID: UUID?
                if let rawExpectedRunID = params["expected_run_id"] {
                    guard let value = rawExpectedRunID.stringValue, let parsed = UUID(uuidString: value) else {
                        throw JSONRPCError.invalidParams
                    }
                    expectedRunID = parsed
                } else {
                    expectedRunID = nil
                }
                // Opt-in v1 caps validated before the checkpoint patch load so a
                // malformed cellular request never pays for a full unbounded diff.
                // Shares GitDiffBoundedResponse with git.diff (one clip algorithm).
                let caps = try GitDiffBoundedResponse.parseOptInCaps(params)
                let diff = try router.agentCheckpointDiff(
                    thread: tid,
                    checkpointTurnCount: turnCount,
                    expectedRunID: expectedRunID,
                    path: params["path"]?.stringValue
                )
                if let caps {
                    let window = GitDiffBoundedResponse.bound(
                        text: diff,
                        maxBytes: caps.maxBytes,
                        maxLines: caps.maxLines
                    )
                    return .init(id: id, result: window.json)
                }
                // Legacy: bare string for callers that omit response_version
                // (even if max_bytes / max_lines happen to be present).
                return .init(id: id, result: .string(diff))
            case "agent.checkpoint.revert":
                // QA-XPLAT :19 -- accept both keys (see agent.checkpoint.diff above).
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let turnCount = (params["turn_count"] ?? params["checkpoint_turn_count"])?.intValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let checkpoint = try await router.revertAgentThreadToCheckpoint(thread: tid, checkpointTurnCount: turnCount)
                EventBus.shared.publish(kind: .agentCheckpointReverted, payload: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "turn_count": .number(Double(checkpoint.checkpointTurnCount)),
                    "turn_id": .string(checkpoint.turnId),
                    "checkpoint_ref": .string(checkpoint.checkpointRef)
                ]))
                let result = encode(checkpoint)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.delete":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try await router.deleteAgentThread(thread: tid)
                EventBus.shared.publish(kind: .agentThreadDeleted, payload: .object(["thread_id": .string(tid.value.uuidString)]))
                let result = JSONValue.bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.delete_many":
                guard case .array(let values) = params["thread_ids"] ?? .null else { throw JSONRPCError.invalidParams }
                let tids = values.compactMap { $0.stringValue.flatMap(UUID.init).map(AgentThreadID.init) }
                guard !tids.isEmpty else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try await router.deleteAgentThreads(tids)
                EventBus.shared.publish(kind: .agentThreadDeletedMany, payload: .object([
                    "thread_ids": .array(tids.map { .string($0.value.uuidString) })
                ]))
                let result = JSONValue.bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.rename":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let title = params["title"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let t = try router.renameAgentThread(thread: tid, title: title)
                EventBus.shared.publish(kind: .agentThreadRenamed, payload: threadPayload(t))
                let result = encodeThread(t)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.loop.stop":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let taskId = params["task_id"]?.stringValue, !taskId.isEmpty else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let deleted = try await router.stopThreadLoop(thread: tid, taskId: taskId)
                let result = JSONValue.object(["deleted": .bool(deleted)])
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.set_pinned":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let pinned = params["pinned"]?.boolValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let t = try router.setAgentThreadPinned(thread: tid, pinned: pinned)
                let order = try router.listAgentThreads(workspace: t.workspaceId).map { $0.id.value.uuidString }
                EventBus.shared.publish(kind: .agentThreadUpdated, payload: .object([
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "pinned": .bool(t.pinned),
                    "sort_order": .number(Double(t.sortOrder)),
                    "provider_locked": .bool(providerLocked(t)),
                    "providerLocked": .bool(providerLocked(t))
                ]))
                EventBus.shared.publish(kind: .agentThreadReordered, payload: .object([
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "order": .array(order.map { .string($0) })
                ]))
                let result = encodeThread(t)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.set_color":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let color = params["color"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let t = try router.setAgentThreadColor(thread: tid, color: color)
                EventBus.shared.publish(kind: .agentThreadUpdated, payload: .object([
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "color": t.color.map { .string($0) } ?? .string(""),
                    "provider_locked": .bool(providerLocked(t)),
                    "providerLocked": .bool(providerLocked(t))
                ]))
                let result = encodeThread(t)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.reorder":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let pos = params["position"]?.intValue ?? 0
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let list = try router.reorderAgentThread(thread: tid, position: pos)
                let wid = list.first(where: { $0.id == tid })?.workspaceId
                EventBus.shared.publish(kind: .agentThreadReordered, payload: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "workspace_id": wid.map { .string($0.value.uuidString) } ?? .null,
                    "position": .number(Double(pos)),
                    "order": .array(list.map { .string($0.id.value.uuidString) })
                ]))
                let result = JSONValue.bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.mark_read":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                do {
                    try router.markAgentThreadRead(thread: tid)
                } catch LayoutError.workspaceNotFound {
                    // Missing thread: rejected before unread state changed.
                    throw DefiniteMutationRejection(LayoutError.workspaceNotFound)
                }
                // has_unread + unread: iOS accepts both; markAgentThreadRead also
                // emits agent.thread.read. Keep updated for clients that only
                // watch thread.updated for rail badges.
                EventBus.shared.publish(kind: .agentThreadUpdated, payload: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "has_unread": .bool(false),
                    "hasUnread": .bool(false),
                    "unread": .bool(false)
                ]))
                let result = JSONValue.bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "git.status":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.gitStatus(workspace: wid)))
            case "git.branches":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.gitBranches(workspace: wid)))
            case "git.checkout":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let branch = params["branch"]?.stringValue else { throw JSONRPCError.invalidParams }
                let r = try router.gitCheckout(workspace: wid, branch: branch)
                EventBus.shared.publish(kind: .gitCheckout, payload: .object(["workspace_id": .string(wid.value.uuidString), "branch": .string(branch), "ok": .bool(r.ok)]))
                return .init(id: id, result: encode(r))
            case "git.create_branch":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let name = params["name"]?.stringValue else { throw JSONRPCError.invalidParams }
                let r = try router.gitCreateBranch(workspace: wid, name: name)
                EventBus.shared.publish(kind: .gitBranchCreated, payload: .object(["workspace_id": .string(wid.value.uuidString), "name": .string(name), "ok": .bool(r.ok)]))
                return .init(id: id, result: encode(r))
            case "git.commit":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let message = params["message"]?.stringValue else { throw JSONRPCError.invalidParams }
                // UX-010: idempotent commit — a retried request over a flaky
                // link must not double-commit.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let r = try router.gitCommit(workspace: wid, message: message)
                EventBus.shared.publish(kind: .gitCommit, payload: .object(["workspace_id": .string(wid.value.uuidString), "ok": .bool(r.ok)]))
                let result = encode(r)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "git.log":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let limit = params["limit"]?.intValue ?? 100
                return .init(id: id, result: encode(try router.gitLog(workspace: wid, limit: limit)))
            case "git.diff":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                // Opt-in v1 caps validated before the expensive router diff so a
                // malformed cellular request never pays for a full unbounded patch.
                let caps = try GitDiffBoundedResponse.parseOptInCaps(params)
                let path = params["path"]?.stringValue
                let iw = params["ignore_whitespace"]?.boolValue ?? false
                let diff = try router.gitDiff(workspace: wid, path: path, ignoreWhitespace: iw)
                if let caps {
                    let window = GitDiffBoundedResponse.bound(
                        text: diff,
                        maxBytes: caps.maxBytes,
                        maxLines: caps.maxLines
                    )
                    return .init(id: id, result: window.json)
                }
                // Legacy: bare string for callers that omit response_version.
                return .init(id: id, result: .string(diff))
            case "git.push":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                // UX-010: idempotent push — a retried request must not push
                // twice.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let destination = try withSuppressedLayoutEvents {
                    try router.ensureGitSurface(workspace: wid)
                }
                let r = try router.gitPush(workspace: wid)
                EventBus.shared.publish(kind: .gitPush, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface_id": .string(destination.id.value.uuidString),
                    "ok": .bool(r.ok)
                ]))
                let result = encode(r)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "git.fetch", "git.pull":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let r = req.method == "git.pull"
                    ? try router.gitPull(workspace: wid)
                    : try router.gitFetch(workspace: wid)
                EventBus.shared.publish(kind: req.method == "git.pull" ? .gitPull : .gitFetch, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "ok": .bool(r.ok)
                ]))
                return .init(id: id, result: encode(r))
            case "git.pull_request_url":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let url = try router.gitPullRequestURL(workspace: wid)
                return .init(id: id, result: .object(["url": url.map { .string($0) } ?? .null]))
            case "git.delivery_plan":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.gitDeliveryPlan(workspace: wid, copy: gitDeliveryCopy(from: params))))
            case "git.deliver":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let destination = try withSuppressedLayoutEvents {
                    try router.ensureGitSurface(workspace: wid)
                }
                let r = try router.gitDeliver(workspace: wid, copy: gitDeliveryCopy(from: params))
                EventBus.shared.publish(kind: .gitDeliver, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface_id": .string(destination.id.value.uuidString),
                    "ok": .bool(r.ok)
                ]))
                return .init(id: id, result: encode(r))
            case "project.scripts":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.projectScripts(workspace: wid)))
            case "project.run_script":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let name = params["name"]?.stringValue else { throw JSONRPCError.invalidParams }
                let s = try router.projectRunScript(workspace: wid, name: name)
                return .init(id: id, result: encode(s))
            case "project.open_in_editor":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let app = try router.projectOpenInEditor(workspace: wid)
                EventBus.shared.publish(kind: .projectOpenedInEditor, payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "app": .string(app)
                ]))
                return .init(id: id, result: .object(["app": .string(app)]))
            case "agent.models.list":
                let provider = AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex
                let models = await router.listAgentModels(provider: provider)
                return .init(id: id, result: encode(models))
            case "agent.providers.list":
                return .init(id: id, result: encode(await router.listAgentProviderSnapshots()))
            case "distill.accounts.list":
                return .init(id: id, result: await router.listDistillAccounts())
            case "distill.accounts.routing.get":
                return .init(id: id, result: try await router.getDistillRouting())
            case "distill.accounts.routing.set":
                guard let value = params["routing"],
                      let routing = try? JSONDecoder().decode(DistillAutoRouting.self, from: JSONEncoder().encode(value)) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.setDistillRouting(routing))
            case "distill.accounts.add", "distill.accounts.rename", "distill.accounts.remove", "distill.accounts.usage", "distill.accounts.login", "distill.accounts.logout":
                if (req.method == "distill.accounts.login" || req.method == "distill.accounts.logout"), params["account_id"] == nil {
                    guard let raw = params["provider"]?.stringValue, let provider = DistillAccountProvider(rawValue: raw) else { throw JSONRPCError.invalidParams }
                    return .init(id: id, result: try req.method == "distill.accounts.login" ? router.loginDistillAccount(provider) : router.logoutDistillAccount(provider))
                }
                let provider = params["provider"]?.stringValue.flatMap(DistillAccountProvider.init(rawValue:))
                return .init(id: id, result: try router.mutateDistillAccount(method: req.method, accountID: params["account_id"]?.stringValue, provider: provider, label: params["label"]?.stringValue))
            case "distill.accounts.cancel":
                return .init(id: id, result: try router.cancelDistillAccountOperation())
            case "agent.run_as_users.list":
                return .init(id: id, result: encode(try router.listAgentRunAsUsers()))
            case "agent.provider.update":
                let provider = AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex
                let instanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let result = try await router.updateAgentProvider(provider: provider, providerInstanceId: instanceId)
                return .init(id: id, result: result)
            case "agent.state.current":
                let w = try router.currentWindow()
                return .init(id: id, result: .object([
                    "selected_workspace_id": w.selectedWorkspaceID.map { .string($0.value.uuidString) } ?? .null
                ]))
            case "agent.prompt_history":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let limit = params["limit"]?.intValue ?? PromptHistoryStore.limit
                let prompts = try router.agentPromptHistory(workspace: wid, limit: limit)
                return .init(id: id, result: .object(["prompts": .array(prompts.map { .string($0) })]))
            case "browser.navigate":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let url = params["url"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.browserNavigate(surface: sid, url: url)
                EventBus.shared.publish(kind: .surfaceBrowser, payload: .object(["surface_id": .string(sid.value.uuidString), "url": .string(url)]))
                return .init(id: id, result: .bool(true))
            case "browser.back":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.browserBack(surface: sid)
                EventBus.shared.publish(kind: .surfaceBrowser, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "action": .string("back")
                ]))
                return .init(id: id, result: .bool(true))
            case "browser.forward":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.browserForward(surface: sid)
                EventBus.shared.publish(kind: .surfaceBrowser, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "action": .string("forward")
                ]))
                return .init(id: id, result: .bool(true))
            case "browser.reload":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.browserReload(surface: sid)
                EventBus.shared.publish(kind: .surfaceBrowser, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "action": .string("reload")
                ]))
                return .init(id: id, result: .bool(true))
            case "browser.stop":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.browserStop(surface: sid)
                EventBus.shared.publish(kind: .surfaceBrowser, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "action": .string("stop")
                ]))
                return .init(id: id, result: .bool(true))
            case "browser.url.get":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let url = try router.browserURL(surface: sid)
                return .init(id: id, result: .string(url))
            case "browser.mirror_url.get":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let mirror = try router.browserMirrorURL(surface: sid)
                EventBus.shared.publish(kind: .browserMirrorURLRegistered, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "is_file": mirror["is_file"] ?? .bool(false)
                ]))
                return .init(id: id, result: .object(mirror))
            case "browser.eval":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let script = params["script"]?.stringValue else { throw JSONRPCError.invalidParams }
                let s = try await router.browserEval(surface: sid, script: script)
                EventBus.shared.publish(kind: .surfaceBrowser, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "action": .string("eval")
                ]))
                return .init(id: id, result: .string(s))
            case "browser.screenshot":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                if let responseVersion = params["response_version"] {
                    guard case .number(let rawVersion) = responseVersion,
                          rawVersion.isFinite,
                          rawVersion == Double(BrowserScreenshotInlineV1.version)
                    else {
                        throw JSONRPCError.invalidParams
                    }
                    guard params["path"] == nil,
                          let maxBytes =
                              BrowserScreenshotInlineV1.boundedPositiveInteger(
                                  params["max_bytes"],
                                  maximum:
                                      BrowserScreenshotInlineV1.maximumResponseBytes
                              ),
                          let maxPixelDimension =
                              BrowserScreenshotInlineV1.boundedPositiveInteger(
                                  params["max_pixel_dimension"],
                                  maximum:
                                      BrowserScreenshotInlineV1.maximumPixelDimension
                              )
                    else {
                        throw JSONRPCError.invalidParams
                    }
                    let resolved = try router.browserScreenshot(
                        surface: sid,
                        savePath: nil
                    )
                    let screenshotURL = URL(fileURLWithPath: resolved)
                    defer { try? FileManager.default.removeItem(at: screenshotURL) }
                    let inlineResponse: [String: JSONValue]
                    do {
                        inlineResponse = try BrowserScreenshotInlineV1.makeResponse(
                            fileURL: screenshotURL,
                            requestedMaxBytes: maxBytes,
                            requestedMaxPixelDimension: maxPixelDimension
                        )
                    } catch {
                        throw JSONRPCError(
                            code: -32013,
                            message: "Browser screenshot could not be encoded within mobile limits."
                        )
                    }
                    EventBus.shared.publish(
                        kind: .browserScreenshotCreated,
                        payload: .object([
                            "surface_id": .string(sid.value.uuidString),
                            "filename": .string("screenshot.jpg")
                        ])
                    )
                    return .init(
                        id: id,
                        result: .object(inlineResponse)
                    )
                }
                let path = params["path"]?.stringValue
                let resolved = try router.browserScreenshot(
                    surface: sid,
                    savePath: path
                )
                EventBus.shared.publish(kind: .browserScreenshotCreated, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "filename": .string(URL(fileURLWithPath: resolved).lastPathComponent)
                ]))
                return .init(id: id, result: .object(["path": .string(resolved)]))
            case "browser.snapshot":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let json = try await router.browserSnapshot(surface: sid)
                return .init(id: id, result: .string(json))
            case "browser.click", "browser.fill", "browser.type", "browser.focus", "browser.hover", "browser.check", "browser.uncheck", "browser.select":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let ref = params["ref"]?.stringValue else { throw JSONRPCError.invalidParams }
                let kind = String(req.method.dropFirst("browser.".count))
                let value = params["value"]?.stringValue
                let json = try await router.browserAction(surface: sid, kind: kind, ref: ref, value: value)
                EventBus.shared.publish(kind: .surfaceBrowser, payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "action": .string(kind)
                ]))
                return .init(id: id, result: .string(json))
            case "browser.wait":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let sel = params["selector"]?.stringValue else { throw JSONRPCError.invalidParams }
                let timeout = params["timeout_ms"]?.intValue ?? 5000
                let json = try await router.browserWait(surface: sid, selector: sel, timeoutMs: timeout)
                return .init(id: id, result: .string(json))
            case "notification.create":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let surfaceID: SurfaceID? = (params["surface_id"]?.stringValue ?? params["surfaceId"]?.stringValue)
                    .flatMap(UUID.init).map(SurfaceID.init)
                let title = params["title"]?.stringValue ?? "Notification"
                let body = params["body"]?.stringValue
                let category = params["category"]?.stringValue
                let nid = try router.notificationCreate(
                    workspaceId: wid,
                    surfaceId: surfaceID,
                    title: title,
                    body: body,
                    category: category
                )
                if !(router is NotificationEventPublishingRouting) {
                    var payload: [String: JSONValue] = [
                        "id": .string(nid),
                        "workspace_id": wid.map { .string($0.value.uuidString) } ?? .null,
                        "title": .string(title)
                    ]
                    if let surfaceID { payload["surface_id"] = .string(surfaceID.value.uuidString) }
                    EventBus.shared.publish(kind: .notificationCreated, payload: .object(payload))
                }
                return .init(id: id, result: .object([
                    "id": .string(nid),
                    "push_policy": .string("background_only")
                ]))
            case "notification.list":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let unread = params["unread_only"]?.boolValue ?? false
                let list = try router.notificationList(workspaceId: wid, unreadOnly: unread)
                return .init(id: id, result: .array(list.map { .object($0) }))
            case "notification.mark_read":
                guard let nid = params["id"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.notificationMarkRead(id: nid)
                if !(router is NotificationEventPublishingRouting) {
                    EventBus.shared.publish(kind: .notificationRead, payload: .object([
                        "id": .string(nid)
                    ]))
                }
                return .init(id: id, result: .bool(true))
            case "notification.dismiss":
                guard let nid = params["id"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.notificationDismiss(id: nid)
                if !(router is NotificationEventPublishingRouting) {
                    EventBus.shared.publish(kind: .notificationDismissed, payload: .object([
                        "id": .string(nid)
                    ]))
                }
                return .init(id: id, result: .bool(true))
            case "private.push_token.update":
                guard let pushToken = params["push_token"]?.stringValue,
                      !pushToken.isEmpty,
                      let pushTokenType = params["push_token_type"]?.stringValue,
                      pushTokenType == "apns" || pushTokenType == "fcm" else { throw JSONRPCError.invalidParams }
                let tokenPurpose = params["token_purpose"]?.stringValue
                let profileID = params["profile_id"]?.stringValue
                let authenticatedHostID = params["authenticated_host_id"]?.stringValue
                var boundProfileID: String?
                var boundHostID: String?
                let environment = params["environment"]?.stringValue
                let serverID = params["server_id"]?.stringValue
                let bootEpoch = params["boot_epoch"]?.intValue
                let activityGeneration = params["activity_generation"]?.intValue
                let activityID = params["activity_id"]?.stringValue
                let activitySessionID = params["activity_session_id"]?.stringValue
                let registrationRevision = params["registration_revision"]?.intValue
                let contractVersion = params["contract_version"]?.intValue
                let capabilityValues = params["capabilities"]?.arrayValue
                let capabilities = capabilityValues?.compactMap(\.stringValue)
                let hasTypedMetadata = tokenPurpose != nil || environment != nil || serverID != nil ||
                    params["boot_epoch"] != nil || params["activity_generation"] != nil ||
                    params["activity_id"] != nil || params["activity_session_id"] != nil ||
                    params["registration_revision"] != nil ||
                    contractVersion != nil || params["capabilities"] != nil
                if hasTypedMetadata {
                    if params["activity_generation"] != nil, activityGeneration == nil {
                        throw JSONRPCError.invalidParams
                    }
                    if params["boot_epoch"] != nil, bootEpoch == nil { throw JSONRPCError.invalidParams }
                    if params["activity_session_id"] != nil, activitySessionID == nil { throw JSONRPCError.invalidParams }
                    if params["registration_revision"] != nil, registrationRevision == nil { throw JSONRPCError.invalidParams }
                    if params["activity_id"] != nil, activityID == nil {
                        throw JSONRPCError.invalidParams
                    }
                    if params["contract_version"] != nil, contractVersion == nil {
                        throw JSONRPCError.invalidParams
                    }
                    if params["capabilities"] != nil,
                       capabilityValues == nil || capabilityValues?.count != capabilities?.count {
                        throw JSONRPCError.invalidParams
                    }
                    guard let tokenPurpose,
                          ["alert", "push_to_start", "activity_update"].contains(tokenPurpose),
                          let environment,
                          ["sandbox", "production"].contains(environment),
                          let deviceID = params["device_id"]?.stringValue,
                          !deviceID.isEmpty,
                          let serverID,
                          !serverID.isEmpty,
                          bootEpoch.map({ $0 >= 0 }) ?? true,
                          activityGeneration.map({ $0 >= 0 }) ?? true,
                          registrationRevision.map({ $0 >= 0 }) ?? true,
                          contractVersion.map({ $0 >= 1 }) ?? true else {
                        throw JSONRPCError.invalidParams
                    }
                    if tokenPurpose != "alert" {
                        guard let activityToken = params["live_activity_token"]?.stringValue,
                              !activityToken.isEmpty else { throw JSONRPCError.invalidParams }
                    }
                    if capabilities?.contains("live_activity_v2") == true,
                       (contractVersion ?? 1) < 2 {
                        throw JSONRPCError.invalidParams
                    }
                }
                var result = try router.privatePushTokenUpdate(
                    pushToken: pushToken,
                    pushTokenType: pushTokenType,
                    liveActivityToken: params["live_activity_token"]?.stringValue,
                    deviceID: params["device_id"]?.stringValue,
                    tokenPurpose: tokenPurpose,
                    environment: environment,
                    serverID: serverID,
                    bootEpoch: bootEpoch,
                    activityGeneration: activityGeneration,
                    activityID: activityID,
                    activitySessionID: activitySessionID,
                    registrationRevision: registrationRevision,
                    contractVersion: contractVersion,
                    capabilities: capabilities
                )
                if tokenPurpose == nil || tokenPurpose == "alert", let profileID {
                    guard !profileID.isEmpty,
                          let authenticatedHostID, !authenticatedHostID.isEmpty,
                          let deviceID = params["device_id"]?.stringValue, !deviceID.isEmpty else {
                        throw JSONRPCError.invalidParams
                    }
                    try router.bindBotAttentionProfile(
                        profileID: profileID,
                        hostID: authenticatedHostID,
                        deviceID: deviceID
                    )
                    boundProfileID = profileID
                    boundHostID = authenticatedHostID
                    var readback = result.objectValue ?? [:]
                    readback["profile_id"] = .string(profileID)
                    readback["host_id"] = .string(authenticatedHostID)
                    readback["device_id"] = .string(deviceID)
                    result = .object(readback)
                }
                EventBus.shared.publish(kind: .privatePushTokenUpdated, payload: .object([
                    "push_token_type": .string(pushTokenType),
                    "device_id": params["device_id"] ?? .null,
                    "profile_id": boundProfileID.map(JSONValue.string) ?? .null,
                    "host_id": boundHostID.map(JSONValue.string) ?? .null,
                    "token_purpose": tokenPurpose.map(JSONValue.string) ?? .null,
                    "environment": environment.map(JSONValue.string) ?? .null
                ]))
                return .init(id: id, result: result)
            case "pane.list":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let panes = try router.paneList(workspace: wid)
                return .init(id: id, result: .array(panes.map { .object($0) }))
            case "pane.surfaces":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let surfaces: [SurfaceDescriptor]
                if let pid = params["id"]?.stringValue.flatMap(UUID.init).map(PaneID.init) {
                    surfaces = try router.paneSurfaces(pane: pid, workspace: wid)
                } else {
                    let paneIDs = try router.paneList(workspace: wid).compactMap { row in
                        row["kind"]?.stringValue == "pane"
                            ? row["id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                            : nil
                    }
                    surfaces = try paneIDs.flatMap { try router.paneSurfaces(pane: $0, workspace: wid) }
                }
                return .init(id: id, result: encode(surfaces))
            case "mirror.snapshot":
                // Collapses the iOS load() N per-pane pane.surfaces round-trips into ONE call.
                // "panes" is the verbatim pane.list encoding; each "surfaces" is the verbatim
                // pane.surfaces encoding so iOS reuses its existing decoders unchanged.
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let panes = try router.paneList(workspace: wid)
                let paneIDs = panes.compactMap { row in
                    row["kind"]?.stringValue == "pane"
                        ? row["id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                        : nil
                }
                let perPane: [JSONValue] = try paneIDs.map { pid in
                    let surfaces = try router.paneSurfaces(pane: pid, workspace: wid)
                    return .object([
                        "pane_id": .string(pid.value.uuidString),
                        "surfaces": encode(surfaces)
                    ])
                }
                return .init(id: id, result: .object([
                    "panes": .array(panes.map { .object($0) }),
                    "pane_surfaces": .array(perPane)
                ]))
            case "pane.resize":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let split = params["split_id"]?.stringValue.flatMap(UUID.init) else { throw JSONRPCError.invalidParams }
                var ratios: [Double] = []
                if case .array(let arr) = params["ratios"] ?? .null {
                    for v in arr { if case .number(let n) = v { ratios.append(n) } }
                }
                try withSuppressedLayoutEvents {
                    try router.paneResize(workspace: wid, splitID: split, ratios: ratios)
                }
                EventBus.shared.publish(kind: .paneResized, payload: .object(["workspace_id": .string(wid.value.uuidString), "split_id": .string(split.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.move":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let pid = params["target_pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init) else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.surfaceMove(workspace: wid, surface: sid, targetPane: pid)
                }
                EventBus.shared.publish(kind: .surfaceMoved, payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString), "target_pane_id": .string(pid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.reorder":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let pid = params["target_pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init) else { throw JSONRPCError.invalidParams }
                let pos = params["position"]?.intValue ?? 0
                try withSuppressedLayoutEvents {
                    try router.surfaceReorder(workspace: wid, surface: sid, toPane: pid, position: pos)
                }
                EventBus.shared.publish(kind: .surfaceReordered, payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString), "target_pane_id": .string(pid.value.uuidString), "position": .number(Double(pos))]))
                return .init(id: id, result: .bool(true))
            case "window.list":
                let ws = try router.listWindows()
                return .init(id: id, result: encode(ws))
            case "window.current":
                let w = try router.currentWindow()
                return .init(id: id, result: encode(w))
            case "window.create":
                let title = params["title"]?.stringValue
                let w = try router.createWindow(title: title)
                EventBus.shared.publish(kind: .windowCreated, payload: encode(w))
                return .init(id: id, result: encode(w))
            case "window.focus":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WindowID.init) else { throw JSONRPCError.invalidParams }
                try router.focusWindow(wid)
                EventBus.shared.publish(kind: .windowFocused, payload: .object([
                    "id": .string(wid.value.uuidString)
                ]))
                return .init(id: id, result: .bool(true))
            case "window.close":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WindowID.init) else { throw JSONRPCError.invalidParams }
                try router.closeWindow(wid)
                EventBus.shared.publish(kind: .windowClosed, payload: .object([
                    "id": .string(wid.value.uuidString)
                ]))
                return .init(id: id, result: .bool(true))
            case "workspace.move_to_window":
                guard let workspaceId = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let target = params["window_id"]?.stringValue.flatMap(UUID.init).map(WindowID.init) else { throw JSONRPCError.invalidParams }
                try router.moveWorkspaceToWindow(workspace: workspaceId, target: target)
                EventBus.shared.publish(kind: .workspaceUpdated, payload: .object([
                    "workspace_id": .string(workspaceId.value.uuidString),
                    "window_id": .string(target.value.uuidString)
                ]))
                return .init(id: id, result: .bool(true))
            case "pane.swap":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let a = params["a"]?.stringValue.flatMap(UUID.init).map(PaneID.init),
                      let b = params["b"]?.stringValue.flatMap(UUID.init).map(PaneID.init) else { throw JSONRPCError.invalidParams }
                try router.paneSwap(workspace: wid, a: a, b: b)
                EventBus.shared.publish(kind: .paneSwapped, payload: .object(["workspace_id": .string(wid.value.uuidString), "a": .string(a.value.uuidString), "b": .string(b.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            // V1 deferred families return a typed unsupported error.
            case "pane.break", "pane.join":
                throw JSONRPCError.notSupported(req.method)
            default:
                throw JSONRPCError.methodNotFound
            }
        } catch let rejection as DefiniteMutationRejection {
            Self.definiteRejectionRecorder?.rejected = true
            if let e = rejection.underlying as? JSONRPCError {
                return .init(id: id, error: e)
            }
            return .init(id: id, error: Self.mapDomainError(rejection.underlying, method: req.method))
        } catch let e as JSONRPCError {
            if req.method == "bot.peer.ask", e.data?.objectValue?["admission"] == .string("rejected") {
                Self.definiteRejectionRecorder?.rejected = true
            }
            return .init(id: id, error: e)
        } catch {
            // UX-005: map known domain errors to a stable code + concise,
            // user-presentable message + structured data so the client can
            // classify them and avoid surfacing raw Swift debug dumps. The
            // verbose form is logged separately; only truly unexpected
            // errors fall through to -32000/String(describing:).
            return .init(id: id, error: Self.mapDomainError(error, method: req.method))
        }
    }

    /// UX-005: translate known domain errors into stable JSON-RPC codes.
    /// `-32010` provider/agent, `-32011` persistence, `-32012` missing
    /// binary. Unknown errors return `-32000` + a generic user-safe message
    /// ("An unexpected error occurred on the host."); the verbose form is
    /// always logged host-side via NSLog so no internal detail leaks to iOS.
    static func mapDomainError(_ error: Error, method: String) -> JSONRPCError {
        let verbose = String(describing: error)
        switch error {
        case let error as JSONRPCError:
            return error
        case let error as AgentRoutingRevisionError:
            let expected: Int
            let actual: Int
            switch error {
            case .conflict(let requested, let current):
                expected = requested
                actual = current
            }
            return JSONRPCError(
                code: -32020,
                message: "Model routing changed on the host. Refresh the thread and try again.",
                data: .object([
                    "domain": .string("routing"),
                    "kind": .string("revision_conflict"),
                    "expected_revision": .number(Double(expected)),
                    "actual_revision": .number(Double(actual))
                ])
            )
        case let error as AgentOrchestrationAdmissionError:
            let kind: String
            switch error {
            case .packageUnavailable: kind = "package_unavailable"
            case .rolloutDisabled: kind = "rollout_disabled"
            case .killSwitchEnabled: kind = "kill_switch_enabled"
            case .invalidPolicy: kind = "invalid_policy"
            case .deadlineExpired: kind = "deadline_expired"
            case .invalidBudget: kind = "invalid_budget"
            case .costBudgetUnavailable: kind = "cost_budget_unavailable"
            case .quotaExceeded: kind = "quota_exceeded"
            case .invalidRoutingMode: kind = "invalid_mode"
            case .noEligibleProvider: kind = "no_eligible_provider"
            case .preferredSourceUnavailable: kind = "preferred_source_unavailable"
            case .receiptPersistenceFailed: kind = "receipt_persistence_failed"
            case .invalidChildAdmission: kind = "invalid_child_admission"
            }
            return JSONRPCError(
                code: -32020,
                message: error.description,
                data: .object(["domain": .string("routing"), "kind": .string(kind)])
            )
        case let e as AgentProviderAdapterError:
            switch e {
            case .sessionNotFound:
                NSLog("[RC2.Dispatch] %@ provider session not found: %@", method, verbose)
                return JSONRPCError(code: -32010, message: "Agent session not found.",
                                    data: .object(["domain": .string("agent"), "kind": .string("session_not_found")]))
            case .unsupported(let op):
                NSLog("[RC2.Dispatch] %@ provider unsupported: %@", method, verbose)
                return JSONRPCError(code: -32010, message: "Agent operation is not available right now.",
                                    data: .object(["domain": .string("agent"), "kind": .string("unsupported"), "detail": .string(op)]))
            case .forkRejected(let reason):
                NSLog("[RC2.Dispatch] %@ provider fork rejected: %@", method, verbose)
                return JSONRPCError(code: -32010, message: "This thread could not be forked: \(reason)",
                                    data: .object(["domain": .string("agent"), "kind": .string("fork_rejected"), "detail": .string(reason)]))
            }
        case let e as PersistenceDataError:
            NSLog("[RC2.Dispatch] %@ persistence error: %@", method, verbose)
            return JSONRPCError(code: -32011, message: "Stored data could not be read.",
                                data: .object(["domain": .string("persistence"), "detail": .string(e.description)]))
        case let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile:
            NSLog("[RC2.Dispatch] %@ file not found: %@", method, verbose)
            return JSONRPCError(code: -32012, message: "A required file was not found.",
                                data: .object(["domain": .string("filesystem"), "kind": .string("not_found")]))
        case let e as ProjectScripts.OpenError:
            NSLog("[RC2.Dispatch] %@ project editor open failed: %@", method, verbose)
            return JSONRPCError(code: -32012, message: "Workspace could not be opened in an editor or Finder.",
                                data: .object(["domain": .string("project_scripts"), "kind": .string("open_failed"), "detail": .string(e.localizedDescription)]))
        default:
            // Heuristic: provider binaries (codex/claude/git) report
            // "missing"/"not found" via untyped errors; classify those.
            if verbose.range(of: "missingbinary", options: .caseInsensitive) != nil
                || verbose.range(of: "binary not found", options: .caseInsensitive) != nil
                || verbose.range(of: "executable not found", options: .caseInsensitive) != nil {
                NSLog("[RC2.Dispatch] %@ missing binary: %@", method, verbose)
                return JSONRPCError(code: -32012, message: "A required command-line tool is not installed.",
                                    data: .object(["domain": .string("binary"), "detail": .string(verbose)]))
            }
            NSLog("[RC2.Dispatch] %@ unexpected error: %@", method, verbose)
            return JSONRPCError(code: -32000, message: "An unexpected error occurred on the host.")
        }
    }

    nonisolated public static let readOnlyBatchMethods: Set<String> = [
        "rpc.batch",
        "system.ping", "system.capabilities", "system.identify",
        "command.receipt.status",
        "events.recent", "settings.get", "token_saver.digest.get",
        "sync.snapshot", "sync.snapshot.begin", "sync.snapshot.chunk", "sync.snapshot.commit",
        "ssh.host.list", "ssh.files.local.list", "ssh.files.remote.list",
        "fs.roots", "fs.list", "fs.workspace.list", "fs.workspace.read", "fs.workspace.preview_url",
        "files.state.get", "files.edit.session",
        "workspace.list", "workspace.current",
        "surface.health", "surface.read_text", "surface.read_history",
        "agent.thread.list", "agent.message.queue.list", "agent.plan.notes.get",
        "agent.message.list", "agent.message.get", "agent.pending_callbacks.list", "agent.manual_action.list",
        "agent.attachment.get", "agent.message.image.get", "agent.account.usage.get",
        "scheduled_task.list",
        // Legacy agent.checkpoint.list remains batch-admitted. Explicit
        // response_version 1 is rejected by preflightTransport before execution.
        "agent.thread.read", "agent.checkpoint.list", "agent.checkpoint.diff",
        "git.status", "git.branches", "git.log", "git.diff", "git.pull_request_url", "git.delivery_plan",
        "project.scripts",
        "agent.models.list", "agent.providers.list", "distill.accounts.list", "distill.accounts.routing.get", "agent.run_as_users.list", "agent.state.current", "agent.prompt_history",
        "bot.vm.list", "bot.context.list", "bot.list", "bot.get", "bot.settings.get", "bot.queue.list", "bot.conversation.list", "bot.attachment.list",
        "bot.routine.list", "bot.files.list", "bot.browser.state", "bot.guest.state",
        "bot.receipt.status", "bot.peer.receipt.status", "bot.attention.list",
        "bot.team.list", "bot.group.list", "bot.group.get",
        "browser.url.get", "browser.snapshot", "browser.wait",
        "notification.list",
        "pane.list", "pane.surfaces", "mirror.snapshot",
        "window.list", "window.current",
    ]

    nonisolated public static func isReadOnlyBatchMethod(_ method: String) -> Bool {
        readOnlyBatchMethods.contains(method)
    }

    // MARK: - P2 per-route capability scopes

    /// RPC namespaces the dispatcher actually serves. A method whose namespace
    /// is not here is "unknown" and fails closed for any scoped device (only a
    /// "*" device may invoke it). Kept in sync with the dispatch `switch` by
    /// prefix, not an exact method list, so it tolerates the switch growing
    /// within an existing namespace.
    nonisolated private static let knownMethodNamespaces: Set<String> = [
        "system", "command", "events", "settings", "rpc",
        "ssh", "fs", "files",
        "workspace", "window", "surface", "pane",
        "agent", "git", "project", "browser", "mirror",
        "notification", "private", "sync", "token_saver", "bot", "scheduled_task"
    ]
    // PERF: nested-run RPC params validate subagent_node_id on every nested
    // agent.create/send; `"-_.".unicodeScalars.contains` built a temporary
    // view per scalar. Share one alphanumerics+`-_.` set (same membership).
    nonisolated private static let safeNodeIdScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_."))

    /// Required capability for a known method, or nil when the method is not
    /// recognized (unknown -> caller must hold "*").
    ///
    /// Buckets, matching the conventions already used elsewhere in this file:
    ///   - "file": filesystem + file-editor surface (`fs.*`, `files.*`).
    ///   - "read": read-only methods (`isReadOnlyBatchMethod`), e.g. *.list /
    ///     *.read / *.status / *.get, system.*, events.recent, settings.get.
    ///     Also HTTP-only read methods that are intentionally excluded from
    ///     `readOnlyBatchMethods` (e.g. `agent.checkpoint.list`).
    ///     `agent.attachment.get` is deliberately `read`: a read device can
    ///     download the bytes of attachments on threads it can read (including
    ///     imported workspace files), but no other host file.
    ///     `agent.message.image.get` is `read` on the same terms: only image
    ///     files an assistant message on a readable thread names literally.
    ///   - "write": every other known (mutating) method.
    ///   - "device-admin": HTTP device list/revoke only; not an RPC method
    ///     grant. `write`/`file`/`read` must not inherit it.
    nonisolated static let deviceAdminCapability = "device-admin"

    /// HTTP device-admin admission. `"*"` keeps already-paired full-access
    /// devices; a named `device-admin` grant is required otherwise.
    nonisolated static func isAuthorizedDeviceAdmin(grantedCapabilities: String) -> Bool {
        let granted = parseCapabilities(grantedCapabilities)
        return granted.contains("*") || granted.contains(deviceAdminCapability)
    }

    nonisolated static func requiredCapability(for method: String) -> String? {
        guard let namespace = method.split(separator: ".").first.map(String.init),
              knownMethodNamespaces.contains(namespace) else {
            return nil
        }
        if namespace == "fs" || namespace == "files" {
            return "file"
        }
        if isReadOnlyBatchMethod(method)
            || ["bot.conversation.export.preview", "bot.conversation.export"].contains(method) {
            return "read"
        }
        return "write"
    }

    /// Parse a stored `DeviceTrust.capabilities` string into a granted set.
    /// "*" (anywhere in the list) means "all capabilities". Tokens are
    /// separated by commas and/or whitespace; empty tokens are ignored.
    nonisolated static func parseCapabilities(_ raw: String) -> Set<String> {
        let tokens = raw
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.lowercased() }
        return Set(tokens)
    }

    /// Authorization decision for one RPC `method` given a device's stored
    /// `grantedCapabilities` string. Pure: no actor state, no I/O.
    ///
    /// Contract:
    ///   - "*" grants everything (back-compat: every already-paired device).
    ///   - otherwise the method's required capability (`requiredCapability`)
    ///     must be in the granted set; an unknown method has no required
    ///     capability and is denied (fail closed).
    nonisolated static func isAuthorized(method: String, grantedCapabilities: String) -> Bool {
        let granted = parseCapabilities(grantedCapabilities)
        if granted.contains("*") { return true }
        guard let needed = requiredCapability(for: method) else { return false }
        return granted.contains(needed)
    }

    /// Accept the lowercased/underscored tokens the CLI documents
    /// (`rightsidebartool`, `filepreview`, …) and map them to the
    /// `SurfaceType` raw values, which are camelCase. Without this the
    /// documented `rc2 new-surface --type rightsidebartool` fails.
    private func normalizeSurfaceTypeString(_ s: String) -> String {
        switch s.lowercased() {
        case "agent", "agent_app", "agentapp": return "agentApp"
        case "rightsidebartool", "right_sidebar_tool", "diff", "git": return "rightSidebarTool"
        case "filepreview", "file_preview": return "filePreview"
        case "files", "file_browser", "filebrowser": return "files"
        case "ssh": return "ssh"
        case "markdown": return "markdown"
        case "terminal": return "terminal"
        case "browser": return "browser"
        default: return s
        }
    }

    /// Top-level entry points the iOS file browser starts from. The app
    /// is not sandboxed, so any of these is fully readable.
    private func fsRoots() -> JSONValue {
        let home = NSHomeDirectory()
        let roots: [(String, String)] = [(home, "Home"), ("/", "Root"), ("/tmp", "/tmp")]
        return .array(roots.map { path, label in
            .object(["id": .string(path), "label": .string(label), "path": .string(path)])
        })
    }

    /// List one directory for the iOS workspace picker. Directories
    /// sort before files, then case-insensitive by name (parity with
    /// the remotecode.io desktop `listPath`). `parent` is null at "/".
    /// Creates one folder for the iOS file picker. Absolute or `~` paths only; the
    /// parent must already exist so a typo cannot create a whole directory chain.
    private func fsMkdir(_ raw: String) throws -> String {
        let path = ((raw as NSString).expandingTildeInPath as NSString).standardizingPath
        guard path.hasPrefix("/"), path != "/" else {
            throw JSONRPCError(code: -32602, message: "Folder path must be absolute.", data: .string(raw))
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: (path as NSString).deletingLastPathComponent, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "The parent folder does not exist.", data: .string(path))
        }
        guard !fm.fileExists(atPath: path) else {
            throw JSONRPCError(code: -32602, message: "A file or folder with that name already exists.", data: .string(path))
        }
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            throw JSONRPCError(code: -32020, message: "Could not create folder: \(error.localizedDescription)", data: .string(path))
        }
        return path
    }

    private func fsList(_ raw: String?) throws -> JSONValue {
        let fm = FileManager.default
        let input = (raw?.isEmpty == false) ? raw! : NSHomeDirectory()
        // expandingTildeInPath handles "~"/"~user"; standardizingPath
        // resolves "." / ".." and symlinks to a canonical absolute path.
        let path = ((input as NSString).expandingTildeInPath as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw JSONRPCError(code: -32602, message: "not found", data: .string(path))
        }
        guard isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "not a directory", data: .string(path))
        }
        // Name-only + mount-table skip: prefetching resource keys on NFS children
        // (e.g. ~/OrbStack) forces the Network Volumes TCC dialog.
        let listed = try HostSafeDirectoryListing.list(path: path, fileManager: fm)
        let entries = listed.map { entry -> (Bool, String, JSONValue) in
            (entry.isDirectory, entry.name, .object([
                "name": .string(entry.name),
                "path": .string(entry.path),
                "type": .string(entry.isDirectory ? "directory" : "file"),
            ]))
        }
        .sorted { l, r in
            if l.0 != r.0 { return l.0 && !r.0 }   // directories first
            return l.1.localizedCaseInsensitiveCompare(r.1) == .orderedAscending
        }
        .map { $0.2 }
        let parent: JSONValue = path == "/" ? .null
            : .string((path as NSString).deletingLastPathComponent)
        return .object([
            "path": .string(path),
            "parentPath": parent,
            "entries": .array(entries),
        ])
    }

    private let _encoder = JSONEncoder()
    private let _decoder = JSONDecoder()
    // PERF: agent.message list/cursor paths called ISO8601DateFormatter() per
    // field (2× per message). Formatter construction is expensive; share one
    // under a short lock (DateFormatters are not thread-safe).
    private let iso8601Lock = NSLock()
    private let iso8601Formatter = ISO8601DateFormatter()

    private func encode<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? _encoder.encode(value),
              let result = try? _decoder.decode(JSONValue.self, from: data) else {
            return .null
        }
        return result
    }

    /// agent.thread.read: a replayed `{"error": {message, recoverable}}` row gets
    /// the live event's display `message` and `recovery_action`, so a cold
    /// open or reconnect shows the same action as `agent.run.error`.
    func decorateReplayedRunError(_ event: JSONValue) -> JSONValue {
        Self.decorateReplayedRunError(event) { message, recoverable in
            router.replayedRunErrorFields(message: message, recoverable: recoverable)
        }
    }

    func decorateReplayedRunErrors(_ events: JSONValue) -> JSONValue {
        guard case .array(let rows) = events else { return events }
        return .array(rows.map(decorateReplayedRunError))
    }

    struct ReplayedRunErrorKey: Hashable, Sendable {
        let message: String
        let recoverable: Bool
    }

    nonisolated static func decorateReplayedRunError(
        _ event: JSONValue,
        fields fieldsFor: (String, Bool) -> [String: JSONValue]
    ) -> JSONValue {
        guard case .object(let outer) = event, outer.count == 1,
              case .object(var error)? = outer["error"],
              let message = error["message"]?.stringValue,
              let recoverable = error["recoverable"]?.boolValue else { return event }
        let fields = fieldsFor(message, recoverable)
        guard !fields.isEmpty else { return event }
        error.merge(fields) { $1 }
        return .object(["error": .object(error)])
    }

    /// `agent.thread.read` v1 result: encode each event, then bound the newest
    /// suffix to the full JSON-RPC envelope. Same bytes as the MainActor path
    /// (default JSONEncoder → JSONValue); its own coders, so it is safe off main.
    nonisolated static func threadReadV1Result(
        snapshot: AgentThreadMirrorSnapshot,
        maxBytes: Int,
        id: JSONRPCID?,
        runErrorFields: [ReplayedRunErrorKey: [String: JSONValue]] = [:]
    ) -> JSONValue {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encodedEvents: [JSONValue] = snapshot.events.map { event in
            guard let data = try? encoder.encode(event),
                  let value = try? decoder.decode(JSONValue.self, from: data) else {
                return .null
            }
            return decorateReplayedRunError(value) { message, recoverable in
                runErrorFields[ReplayedRunErrorKey(message: message, recoverable: recoverable)] ?? [:]
            }
        }
        let blocked = snapshot.blockedEvent.map {
            AgentThreadReadV1.BlockedEvent(
                id: $0.id,
                payloadBytes: $0.payloadBytes,
                reason: $0.reason
            )
        }
        let window = AgentThreadReadV1.boundToEnvelope(
            events: snapshot.events,
            encodedEvents: encodedEvents,
            sourceHadOlderEvents: snapshot.sourceHadOlderEvents,
            blockedEvent: blocked,
            maxBytes: maxBytes,
            eventWatermark: snapshot.eventWatermark,
            responseId: id,
            // Full JSON-RPC response UTF-8 size, measured structurally (~log2(N)
            // times per read) without allocating Data.
            measureEnvelope: { result in
                EventBus.jsonRPCResponseByteCount(id: id, result: result)
            }
        )
        return AgentThreadReadV1.payload(window: window, eventWatermark: snapshot.eventWatermark)
    }

    private func workspaceID(from params: [String: JSONValue]) throws -> WorkspaceID {
        guard let raw = params["workspace_id"]?.stringValue ?? params["workspaceId"]?.stringValue,
              let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError.invalidParams
        }
        return WorkspaceID(uuid)
    }

    private func optionalSSHProfile(from params: [String: JSONValue]) throws -> SSHHostProfile? {
        if params["destination"]?.stringValue == nil,
           params["host"]?.stringValue == nil,
           params["profile"]?.objectValue == nil {
            return nil
        }
        return try sshProfile(from: params)
    }

    private func sshProfile(from params: [String: JSONValue]) throws -> SSHHostProfile {
        let source = params["profile"]?.objectValue ?? params
        guard let destination = source["destination"]?.stringValue ?? source["host"]?.stringValue else {
            throw JSONRPCError.invalidParams
        }
        let id = (source["id"]?.stringValue).flatMap(UUID.init).map(SSHHostID.init) ?? SSHHostID()
        let label = source["label"]?.stringValue ?? source["title"]?.stringValue ?? destination
        let options = source["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return SSHHostProfile(
            id: id,
            label: label,
            destination: destination,
            port: source["port"]?.intValue,
            identityFile: source["identity_file"]?.stringValue ?? source["identityFile"]?.stringValue,
            password: source["password"]?.stringValue,
            options: options
        )
    }

    private func encodeThread(_ thread: AgentThread) -> JSONValue {
        guard case .object(var object) = encode(thread) else { return .null }
        let display = AgentThreadTitle.display(thread.title)
        object["displayTitle"] = .string(display)
        object["display_title"] = .string(display)
        object["model_selection"] = encode(thread.modelSelection)
        appendFlatModelSelection(thread, to: &object)
        object["provider_instance_id"] = thread.providerInstanceId.map { .string($0) } ?? .null
        object["execution_mode"] = .string(thread.executionMode.rawValue)
        object["base_branch"] = thread.baseBranch.map { .string($0) } ?? .null
        object["worktree_path"] = thread.worktreePath.map { .string($0) } ?? .null
        object["interaction_mode"] = .string(thread.effectiveInteractionMode.rawValue)
        object["interactionMode"] = .string(thread.effectiveInteractionMode.rawValue)
        object["run_as_user"] = encodeRunAsUser(thread.runAsUser)
        object["runAsUser"] = encodeRunAsUser(thread.runAsUser)
        let locked = providerLocked(thread)
        object["providerLocked"] = .bool(locked)
        object["provider_locked"] = .bool(locked)
        appendRouting(thread.effectiveRoutingConfiguration, to: &object)
        appendActiveRun(to: &object, thread: thread.id)
        object["pending_manual_action"] = ManualActionWire.pendingRow(router.pendingManualActions(for: [thread])[thread.id])
        appendThreadActor(thread, guestRuntime: router.threadGuestRuntime(thread: thread.id), to: &object)
        appendLoops(thread.id, to: &object)
        return .object(object)
    }

    /// Batch overload used by agent.thread.list (PERF-007): caller pre-fetches
    /// the locked set once; no additional query is issued per thread.
    private func encodeThread(
        _ thread: AgentThread,
        lockedThreads: Set<AgentThreadID>,
        pendingManualActions: [AgentThreadID: ManualActionSnapshot],
        guestRuntimes: [AgentThreadID: String]
    ) -> JSONValue {
        guard case .object(var object) = encode(thread) else { return .null }
        let display = AgentThreadTitle.display(thread.title)
        object["displayTitle"] = .string(display)
        object["display_title"] = .string(display)
        object["model_selection"] = encode(thread.modelSelection)
        appendFlatModelSelection(thread, to: &object)
        object["provider_instance_id"] = thread.providerInstanceId.map { .string($0) } ?? .null
        object["execution_mode"] = .string(thread.executionMode.rawValue)
        object["base_branch"] = thread.baseBranch.map { .string($0) } ?? .null
        object["worktree_path"] = thread.worktreePath.map { .string($0) } ?? .null
        object["interaction_mode"] = .string(thread.effectiveInteractionMode.rawValue)
        object["interactionMode"] = .string(thread.effectiveInteractionMode.rawValue)
        object["run_as_user"] = encodeRunAsUser(thread.runAsUser)
        object["runAsUser"] = encodeRunAsUser(thread.runAsUser)
        let locked = lockedThreads.contains(thread.id)
        object["providerLocked"] = .bool(locked)
        object["provider_locked"] = .bool(locked)
        appendRouting(thread.effectiveRoutingConfiguration, to: &object)
        appendActiveRun(to: &object, thread: thread.id)
        object["pending_manual_action"] = ManualActionWire.pendingRow(pendingManualActions[thread.id])
        appendThreadActor(thread, guestRuntime: guestRuntimes[thread.id], to: &object)
        appendLoops(thread.id, to: &object)
        return .object(object)
    }

    private func appendLoops(_ thread: AgentThreadID, to object: inout [String: JSONValue]) {
        let loops = router.threadLoops(thread: thread)
        guard !loops.isEmpty,
              let data = try? JSONEncoder().encode(loops),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        object["loops"] = value
    }

    /// `agent.thread.actor.set` / `agent.mac_execution.resolve` result: the
    /// thread's actor fields at the top level plus its full payload as `thread`.
    private func threadActorResult(_ thread: AgentThread) -> [String: JSONValue] {
        var result: [String: JSONValue] = ["thread_id": .string(thread.id.value.uuidString)]
        appendThreadActor(thread, guestRuntime: router.threadGuestRuntime(thread: thread.id), to: &result)
        result["thread"] = encodeThread(thread)
        return result
    }

    /// Same shape as AppCommandRouter.agentThreadPayload (ThreadActorWire).
    private func appendThreadActor(_ thread: AgentThread, guestRuntime: String?, to object: inout [String: JSONValue]) {
        ThreadActorWire.append(
            thread: thread,
            guestRuntime: guestRuntime,
            pendingMacExecutionReason: router.pendingMacExecutionReason(thread: thread.id),
            to: &object
        )
    }

    private func appendFlatModelSelection(_ thread: AgentThread, to object: inout [String: JSONValue]) {
        object["distill_main_effort"] = .string(thread.modelSelection.distillMainEffortSelection?.effort?.rawValue ?? "auto")
        object["worker_model"] = .string(thread.reasoningModel ?? "")
        object["worker_effort"] = .string(thread.modelSelection.distillReasoningEffortSelection?.effort?.rawValue ?? "auto")
        object["distill_ultracode"] = .bool(thread.modelSelection.distillExecutionMode == .ultracode)
        object["distill_execution_mode"] = .string(thread.modelSelection.distillExecutionMode.rawValue)
    }

    private func encodeRunAsUser(_ user: AgentRunAsUser?) -> JSONValue {
        guard let user else { return .null }
        return encode(user)
    }

    private func decodeRunAsUser(from value: JSONValue?) -> AgentRunAsUser? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard let data = try? _encoder.encode(value),
              let user = try? _decoder.decode(AgentRunAsUser.self, from: data) else {
            return nil
        }
        return user
    }

    private func appendActiveRun(
        to object: inout [String: JSONValue],
        thread: AgentThreadID
    ) {
        guard let active = try? router.activeAgentRun(thread: thread) else {
            object["active_run_id"] = .null
            object["active_run_started_at_ms"] = .null
            return
        }
        object["active_run_id"] = .string(active.runId.value.uuidString)
        object["active_run_started_at_ms"] = .number(Double(
            Int64(active.startedAt.timeIntervalSince1970 * 1_000)
        ))
        // DB status can lag the coordinator (still completed/idle while a run is
        // live). Mirror clients that gate on status would drop the blue badge /
        // Live Activity while the pet is correct — force the wire status to
        // running whenever we advertise a host-owned active_run_id.
        object["status"] = .string(AgentRunStatus.running.rawValue)
    }

    /// Raw delegation authority is added only to non-mutating active-run
    /// readback. Mutation receipts must never persist or replay this bearer.
    private func appendActiveDelegation(
        to object: inout [String: JSONValue],
        thread: AgentThreadID
    ) {
        guard let active = try? router.activeAgentRun(thread: thread),
              let delegation = try? router.activeAgentDelegation(
                thread: thread,
                run: active.runId
              ),
              delegation.threadId == thread,
              delegation.runId == active.runId,
              !delegation.capability.isEmpty,
              delegation.expiresAt > Date() else {
            return
        }
        object["delegation_capability"] = .string(delegation.capability)
        object["delegation_thread_id"] = .string(
            delegation.threadId.value.uuidString.lowercased()
        )
        object["delegation_run_id"] = .string(
            delegation.runId.value.uuidString.lowercased()
        )
        object["delegation_host_id"] = .string(delegation.hostId)
        object["delegation_expires_at_ms"] = .number(Double(
            Int64(delegation.expiresAt.timeIntervalSince1970 * 1_000)
        ))
    }

    private func messageSendResultPayload(_ result: AgentMessageSendResult) -> JSONValue {
        var payload: [String: JSONValue] = ["status": .string(result.status.rawValue)]
        if let runId = result.runId {
            payload["run_id"] = .string(runId.value.uuidString)
        }
        if let queued = result.queuedMessage {
            payload["queued_message_id"] = .string(queued.id.value.uuidString)
            payload["position"] = .number(Double(queued.position))
            payload["queued_message"] = queuedMessagePayload(queued)
        }
        return .object(payload)
    }

    private func queuedMessagePayload(_ message: AgentQueuedMessage) -> JSONValue {
        guard case .object(var object) = encode(message) else { return .null }
        object["id"] = .string(message.id.value.uuidString)
        object["thread_id"] = .string(message.threadId.value.uuidString)
        object["threadId"] = .string(message.threadId.value.uuidString)
        object["interaction_mode"] = .string(message.interactionMode.rawValue)
        object["interactionMode"] = .string(message.interactionMode.rawValue)
        object["attachments"] = attachmentPayload(message.attachments)
        object["position"] = .number(Double(message.position))
        object["created_at"] = .string(iso8601(message.createdAt))
        object["updated_at"] = .string(iso8601(message.updatedAt))
        if let durableState = message.durableState {
            object["durable_state"] = .string(durableState.rawValue)
            object["durableState"] = .string(durableState.rawValue)
        }
        return .object(object)
    }

    private func iso8601(_ date: Date) -> String {
        iso8601Lock.lock()
        defer { iso8601Lock.unlock() }
        return iso8601Formatter.string(from: date)
    }

    private func messageCursor(from value: JSONValue?) -> AgentMessageCursor? {
        guard case .object(let object) = value,
              let id = object["id"]?.stringValue.flatMap(UUID.init).map(AgentMessageID.init) else {
            return nil
        }
        if let created = object["created_at"]?.stringValue ?? object["createdAt"]?.stringValue {
            return AgentMessageCursor(createdAt: parseISO8601(created), id: id)
        }
        return nil
    }

    private func messageCursorPayload(_ cursor: AgentMessageCursor) -> JSONValue {
        .object([
            "created_at": .string(iso8601(cursor.createdAt)),
            "createdAt": .string(iso8601(cursor.createdAt)),
            "id": .string(cursor.id.value.uuidString)
        ])
    }

    private func v1MessageCursorPayload(
        _ cursor: AgentMessageCursor
    ) -> JSONValue {
        .object([
            "created_at": .string(iso8601(cursor.createdAt)),
            "id": .string(cursor.id.value.uuidString),
        ])
    }

    private func v1MessageCursor(
        from value: JSONValue?
    ) throws -> AgentMessageCursor? {
        guard let value else { return nil }
        if value == .null { return nil }
        guard case .object(let object) = value,
              Set(object.keys) == ["created_at", "id"],
              let id = object["id"]?.stringValue
                .flatMap(UUID.init)
                .map(AgentMessageID.init),
              let createdText = object["created_at"]?.stringValue,
              // parseISO8601 falls back to reference date on bad strings; v1
              // requires a real parse — reject when the shared formatter fails.
              let createdAt = parseISO8601Strict(createdText) else {
            throw JSONRPCError.invalidParams
        }
        return AgentMessageCursor(createdAt: createdAt, id: id)
    }

    nonisolated static func checkpointListV1AcceptsResponseID(
        _ responseID: JSONRPCID?
    ) -> Bool {
        AgentCheckpointListContract.acceptsResponseID(responseID)
    }

    private func parseISO8601(_ value: String) -> Date {
        iso8601Lock.lock()
        defer { iso8601Lock.unlock() }
        return iso8601Formatter.date(from: value) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private func parseISO8601Strict(_ value: String) -> Date? {
        iso8601Lock.lock()
        defer { iso8601Lock.unlock() }
        return iso8601Formatter.date(from: value)
    }

    private func messagePagePayload(_ page: AgentMessagePage) -> JSONValue {
        var object: [String: JSONValue] = [
            "messages": .array(page.messages.map(messagePayload)),
            "has_more_older": .bool(page.hasMoreOlder),
            "hasMoreOlder": .bool(page.hasMoreOlder),
            "has_more_newer": .bool(page.hasMoreNewer),
            "hasMoreNewer": .bool(page.hasMoreNewer)
        ]
        if let cursor = page.nextBefore {
            let encoded = messageCursorPayload(cursor)
            object["next_before"] = encoded
            object["nextBefore"] = encoded
        } else {
            object["next_before"] = .null
            object["nextBefore"] = .null
        }
        if let cursor = page.nextAfter {
            let encoded = messageCursorPayload(cursor)
            object["next_after"] = encoded
            object["nextAfter"] = encoded
        } else {
            object["next_after"] = .null
            object["nextAfter"] = .null
        }
        return .object(object)
    }

    private func modelSelection(from params: [String: JSONValue]) throws -> AgentModelSelection? {
        let nested = modelSelection(from: params["model_selection"])
        let hasFlat = params["distill_main_effort"] != nil || params["worker_model"] != nil || params["worker_effort"] != nil || params["distill_ultracode"] != nil || params["distill_execution_mode"] != nil
        guard nested != nil || hasFlat else { return nil }
        let provider = nested?.provider ?? AgentProvider(rawValue: params["provider"]?.stringValue ?? "distill") ?? .distill
        var selection = nested ?? AgentModelSelection(
            provider: provider,
            modelId: params["model"]?.stringValue ?? "",
            reasoningEffort: params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init) ?? .medium,
            serviceTier: params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init) ?? .auto
        )
        if let raw = params["distill_main_effort"] {
            guard let value = raw.stringValue else { throw JSONRPCError.invalidParams }
            selection.distillMainEffortSelection = try effortSelection(value)
        }
        if let raw = params["worker_effort"] {
            guard let value = raw.stringValue else { throw JSONRPCError.invalidParams }
            selection.distillReasoningEffortSelection = try effortSelection(value)
        }
        if let raw = params["distill_execution_mode"] {
            guard let value = raw.stringValue, let mode = DistillExecutionMode(rawValue: value) else { throw JSONRPCError.invalidParams }
            selection.distillExecutionMode = mode
        } else if let raw = params["distill_ultracode"] {
            guard case .bool(let enabled) = raw else { throw JSONRPCError.invalidParams }
            selection.distillExecutionMode = enabled ? .ultracode : .normal
        }
        return selection
    }

    private func effortSelection(_ raw: String) throws -> AgentEffortSelection {
        if raw == "auto" { return .automatic }
        guard let effort = AgentReasoningEffort(rawValue: raw) else { throw JSONRPCError.invalidParams }
        return .fixed(effort)
    }

    private func workerModel(from params: [String: JSONValue]) throws -> String? {
        guard let value = params["worker_model"] else { return nil }
        guard let model = value.stringValue else { throw JSONRPCError.invalidParams }
        return model.isEmpty ? nil : model
    }

    private func modelSelection(from value: JSONValue?) -> AgentModelSelection? {
        guard case .object(let object) = value else { return nil }
        guard let providerValue = object["provider"]?.stringValue,
              let provider = AgentProvider(rawValue: providerValue) else { return nil }
        let modelId = object["modelId"]?.stringValue ?? object["model_id"]?.stringValue ?? object["model"]?.stringValue ?? ""
        let customModelId = object["customModelId"]?.stringValue ?? object["custom_model_id"]?.stringValue
        let reasoning = (object["reasoningEffort"]?.stringValue ?? object["reasoning_effort"]?.stringValue)
            .flatMap(AgentReasoningEffort.init) ?? .medium
        let serviceTier = (object["serviceTier"]?.stringValue ?? object["service_tier"]?.stringValue)
            .flatMap(AgentServiceTier.init) ?? .auto
        return AgentModelSelection(
            provider: provider,
            modelId: modelId,
            customModelId: customModelId,
            reasoningEffort: reasoning,
            serviceTier: serviceTier
        )
    }

    private func nestedRunContext(
        from params: [String: JSONValue]
    ) throws -> AgentNestedRunContext? {
        let values = (
            parentRunID: params["parent_run_id"]?.stringValue,
            parentThreadID: params["parent_thread_id"]?.stringValue,
            nodeID: params["subagent_node_id"]?.stringValue,
            parentCapability: params[
                AgentDelegationCapabilityTransport.rpcParameterKey
            ]?.stringValue,
            runtimeProfile: params["runtime_profile"]?.stringValue
        )
        guard values.parentRunID != nil
                || values.parentThreadID != nil
                || values.nodeID != nil
                || values.parentCapability != nil
                || values.runtimeProfile != nil else {
            return nil
        }
        let runtimeProfile: AgentAppRuntimeProfile?
        if let rawProfile = values.runtimeProfile {
            guard let parsed = AgentAppRuntimeProfile(rawValue: rawProfile) else {
                throw JSONRPCError.invalidParams
            }
            runtimeProfile = parsed
        } else {
            runtimeProfile = nil
        }
        guard let parentRunUUID = values.parentRunID.flatMap(UUID.init),
              let parentThreadUUID = values.parentThreadID.flatMap(UUID.init),
              let nodeID = values.nodeID,
              let parentCapability = values.parentCapability,
              AgentDelegationCapabilityTransport.isWellFormed(parentCapability),
              !nodeID.isEmpty,
              nodeID.utf8.count <= 128,
              nodeID.unicodeScalars.allSatisfy({ Self.safeNodeIdScalars.contains($0) }) else {
            throw JSONRPCError.invalidParams
        }
        return AgentNestedRunContext(
            parentRunID: AgentRunID(parentRunUUID),
            parentThreadID: AgentThreadID(parentThreadUUID),
            nodeID: nodeID,
            parentCapability: parentCapability,
            runtimeProfile: runtimeProfile
        )
    }

    private func routingRequest(
        from params: [String: JSONValue],
        requireManualSelection: Bool
    ) throws -> AgentRoutingRequest? {
        let keys = ["routing_mode", "routingMode", "routing_revision", "routingRevision", "manual_selection", "manualSelection", "eligible_providers", "eligibleProviders", "policy_digest", "policyDigest"]
        guard keys.contains(where: { params[$0] != nil }) else { return nil }
        guard let rawMode = (params["routing_mode"] ?? params["routingMode"])?.stringValue,
              let mode = AgentRoutingMode(rawValue: rawMode),
              let revisionValue = params["routing_revision"] ?? params["routingRevision"],
              case .number(let rawRevision) = revisionValue,
              // `Int(_: Double)` traps on overflow, and `Double(Int.max)` rounds up
              // to 2^63, so a `<= Double(Int.max)` bound admits a value that then
              // traps. `Int(exactly:)` rejects non-finite, fractional, and
              // out-of-range doubles, closing the remote abort.
              let expectedRevision = Int(exactly: rawRevision),
              expectedRevision >= 0 else {
            throw JSONRPCError.invalidParams
        }
        let manualValue = params["manual_selection"] ?? params["manualSelection"]
        let manualSelection = modelSelection(from: manualValue)
        if requireManualSelection, manualSelection == nil {
            throw JSONRPCError.invalidParams
        }
        let eligibleValue = params["eligible_providers"] ?? params["eligibleProviders"]
        let eligibleProviders: [AgentProvider]?
        if let eligibleValue {
            guard case .array(let values) = eligibleValue else { throw JSONRPCError.invalidParams }
            eligibleProviders = try values.map { value in
                guard let raw = value.stringValue, let provider = AgentProvider(rawValue: raw) else {
                    throw JSONRPCError.invalidParams
                }
                return provider
            }
        } else {
            eligibleProviders = nil
        }
        let policyValue = params["policy_digest"] ?? params["policyDigest"]
        if let policyValue, policyValue.stringValue == nil { throw JSONRPCError.invalidParams }
        return AgentRoutingRequest(
            mode: mode,
            expectedRevision: expectedRevision,
            manualSelection: manualSelection,
            eligibleProviders: eligibleProviders,
            policyDigest: policyValue?.stringValue
        )
    }

    private func agentAttachments(from value: JSONValue?) throws -> [AgentAttachment] {
        guard let value else { return [] }
        guard case .array(let values) = value else { throw JSONRPCError.invalidParams }
        return try values.map { value -> AgentAttachment in
            guard case .object(let object) = value,
                  object["path"] == nil,
                  let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  id.count == 64,
                  id.allSatisfy({ $0.isHexDigit }) else { throw JSONRPCError.invalidParams }
            let kind: AgentAttachmentKind
            if let raw = object["kind"]?.stringValue {
                guard let parsed = AgentAttachmentKind(rawValue: raw) else { throw JSONRPCError.invalidParams }
                kind = parsed
            } else {
                kind = .file
            }
            let displayName = object["displayName"]?.stringValue
                ?? object["display_name"]?.stringValue
                ?? id
            let mimeType = object["mimeType"]?.stringValue ?? object["mime_type"]?.stringValue
            let sha256 = object["sha256"]?.stringValue
            let sizeBytes = object["sizeBytes"]?.intValue ?? object["size_bytes"]?.intValue
            return AgentAttachment(
                id: id,
                path: "",
                displayName: displayName,
                kind: kind,
                mimeType: mimeType,
                sha256: sha256,
                sizeBytes: sizeBytes
            )
        }
    }

    private func attachmentPayload(_ attachments: [AgentAttachment]) -> JSONValue {
        .array(attachments.compactMap { attachment in
            AgentAttachmentReference(attachment).map(encode)
        })
    }

    private func messagePayload(_ message: AgentMessage) -> JSONValue {
        guard case .object(var object) = encode(message) else { return .null }
        object["attachments"] = attachmentPayload(message.attachments)
        return .object(object)
    }

    private func gitDeliveryCopy(from params: [String: JSONValue]) -> GitDeliveryCopy? {
        let object = params["copy"]?.objectValue ?? params["delivery_copy"]?.objectValue ?? params
        let copy = GitDeliveryCopy(
            branchName: object["branchName"]?.stringValue ?? object["branch_name"]?.stringValue,
            commitMessage: object["commitMessage"]?.stringValue ?? object["commit_message"]?.stringValue,
            pullRequestTitle: object["pullRequestTitle"]?.stringValue ?? object["pull_request_title"]?.stringValue,
            pullRequestBody: object["pullRequestBody"]?.stringValue ?? object["pull_request_body"]?.stringValue
        )
        return copy.branchName == nil &&
            copy.commitMessage == nil &&
            copy.pullRequestTitle == nil &&
            copy.pullRequestBody == nil ? nil : copy
    }

    private func threadPayload(_ thread: AgentThread) -> JSONValue {
        let locked = providerLocked(thread)
        var payload: [String: JSONValue] = [
            "thread_id": .string(thread.id.value.uuidString),
            "workspace_id": thread.workspaceId.map { .string($0.value.uuidString) } ?? .null,
            "title": .string(thread.title),
            "display_title": .string(AgentThreadTitle.display(thread.title)),
            "displayTitle": .string(AgentThreadTitle.display(thread.title)),
            "provider": .string(thread.provider.rawValue),
            "provider_instance_id": thread.providerInstanceId.map { .string($0) } ?? .null,
            "providerInstanceId": thread.providerInstanceId.map { .string($0) } ?? .null,
            "model": .string(thread.model),
            "provider_locked": .bool(locked),
            "providerLocked": .bool(locked),
            "permission_mode": .string(thread.permissionMode.rawValue),
            "reasoning_effort": .string(thread.reasoningEffort.rawValue),
            "service_tier": .string(thread.serviceTier.rawValue),
            "model_selection": encode(thread.modelSelection),
            "distill_main_effort": .string(thread.modelSelection.distillMainEffortSelection?.effort?.rawValue ?? "auto"),
            "worker_model": .string(thread.reasoningModel ?? ""),
            "worker_effort": .string(thread.modelSelection.distillReasoningEffortSelection?.effort?.rawValue ?? "auto"),
            "distill_ultracode": .bool(thread.modelSelection.distillExecutionMode == .ultracode),
            "distill_execution_mode": .string(thread.modelSelection.distillExecutionMode.rawValue),
            "execution_mode": .string(thread.executionMode.rawValue),
            "interaction_mode": .string(thread.effectiveInteractionMode.rawValue),
            "interactionMode": .string(thread.effectiveInteractionMode.rawValue),
            "run_as_user": encodeRunAsUser(thread.runAsUser),
            "runAsUser": encodeRunAsUser(thread.runAsUser)
        ]
        payload["base_branch"] = thread.baseBranch.map { .string($0) } ?? .null
        payload["worktree_path"] = thread.worktreePath.map { .string($0) } ?? .null
        payload["color"] = thread.color.map { .string($0) } ?? .null
        payload["pinned"] = .bool(thread.pinned)
        payload["sort_order"] = .number(Double(thread.sortOrder))
        appendRouting(thread.effectiveRoutingConfiguration, to: &payload)
        payload["pending_manual_action"] = ManualActionWire.pendingRow(router.pendingManualActions(for: [thread])[thread.id])
        appendThreadActor(thread, guestRuntime: router.threadGuestRuntime(thread: thread.id), to: &payload)
        return .object(payload)
    }

    private func appendRouting(_ routing: AgentRoutingConfiguration, to object: inout [String: JSONValue]) {
        let manualSelection = encode(routing.manualSelection)
        let eligibleProviders = JSONValue.array(routing.eligibleProviders.map { .string($0.rawValue) })
        object["routing"] = .object([
            "mode": .string(routing.mode.rawValue),
            "revision": .number(Double(routing.revision)),
            "manualSelection": manualSelection,
            "eligibleProviders": eligibleProviders,
            "policyDigest": .string(routing.policyDigest)
        ])
        object["routing_mode"] = .string(routing.mode.rawValue)
        object["routingMode"] = .string(routing.mode.rawValue)
        object["routing_revision"] = .number(Double(routing.revision))
        object["routingRevision"] = .number(Double(routing.revision))
        object["manual_selection"] = manualSelection
        object["manualSelection"] = manualSelection
        object["eligible_providers"] = eligibleProviders
        object["eligibleProviders"] = eligibleProviders
        object["policy_digest"] = .string(routing.policyDigest)
        object["policyDigest"] = .string(routing.policyDigest)
    }

    private func providerLocked(_ thread: AgentThread) -> Bool {
        (try? router.agentThreadHasMessages(thread: thread.id)) ?? false
    }
}
