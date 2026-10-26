import Foundation

public enum RemoteCodeEventKind: String, Codable, CaseIterable, Sendable {
    case agentAccountUsage = "agent.account.usage"
    case agentAccountUsageRefresh = "agent.account.usage.refresh"
    /// Activity rows or counts changed: payload `{workspace_id, counts, changed_thread_ids}`,
    /// `counts` in the `workspace_counts` entry shape. Host-debounced to 2/s per workspace.
    case agentActivityChanged = "agent.activity.changed"
    case agentAttachmentUploaded = "agent.attachment.uploaded"
    case agentCheckpointReverted = "agent.checkpoint.reverted"
    case agentContextCompaction = "agent.context.compaction"
    case agentItemCompleted = "agent.item.completed"
    case agentItemDelta = "agent.item.delta"
    case agentItemProgress = "agent.item.progress"
    case agentItemStarted = "agent.item.started"
    /// A bot's manual-action request opened, was taken or was resolved
    /// (`AgentManualActionUpdatedEvent`).
    case agentManualActionUpdated = "agent.manual_action.updated"
    /// A bot asked to run on the Mac (`AgentMacExecutionRequestedEvent`).
    case agentMacExecutionRequested = "agent.mac_execution.requested"
    case agentMessageAccepted = "agent.message.accepted"
    case agentMessageAppended = "agent.message.appended"
    case agentMessageQueueCancelled = "agent.message.queue.cancelled"
    case agentMessageQueueDrained = "agent.message.queue.drained"
    case agentMessageQueueFailed = "agent.message.queue.failed"
    case agentMessageQueueForceRequested = "agent.message.queue.force_requested"
    case agentMessageQueueUpdated = "agent.message.queue.updated"
    case agentMessageQueued = "agent.message.queued"
    /// Messages left a thread (a cleared Titio notice): payload
    /// `{thread_id, message_ids}`; clients drop those ids from transcripts.
    case agentMessagesRemoved = "agent.messages.removed"
    case agentPlanActiveUpdated = "agent.plan.active_updated"
    case agentPlanImplemented = "agent.plan.implemented"
    case agentPlanNotesUpdated = "agent.plan.notes.updated"
    case agentPlanProposed = "agent.plan.proposed"
    case agentPlanSaved = "agent.plan.saved"
    case agentProviderUpdated = "agent.provider.updated"
    case agentProviderRuntimeEvent = "agent.provider_runtime.event"
    case agentRequestOpened = "agent.request.opened"
    case agentRequestResolved = "agent.request.resolved"
    case agentRunError = "agent.run.error"
    case agentRunCancelled = "agent.run.cancelled"
    case agentRunCompleted = "agent.run.completed"
    case agentRunContinueRequested = "agent.run.continue_requested"
    case agentRunFailed = "agent.run.failed"
    case agentRunFinished = "agent.run.finished"
    case agentRunStarted = "agent.run.started"
    case agentRunStopRequested = "agent.run.stop_requested"
    case agentSR1Translation = "agent.sr1.translation"
    case agentThreadCreated = "agent.thread.created"
    case agentThreadDeleted = "agent.thread.deleted"
    case agentThreadDeletedMany = "agent.thread.deleted_many"
    case agentThreadLoopsUpdated = "agent.thread.loops.updated"
    case agentThreadRead = "agent.thread.read"
    case agentThreadRenamed = "agent.thread.renamed"
    case agentThreadReordered = "agent.thread.reordered"
    case agentThreadRolledBack = "agent.thread.rolled_back"
    case agentThreadSelected = "agent.thread.selected"
    case agentThreadTokenUsage = "agent.thread.token_usage"
    case agentThreadUpdated = "agent.thread.updated"
    case agentTurnCompleted = "agent.turn.completed"
    case agentTurnStarted = "agent.turn.started"
    case agentUserInputRequested = "agent.user_input.requested"
    case agentUserInputResolved = "agent.user_input.resolved"
    case agentWireTranslation = "agent.wire.translation"
    case botAttachmentUpdated = "bot.attachment.updated"
    case botAttentionUpdated = "bot.attention.updated"
    case botBrowserUpdated = "bot.browser.updated"
    case botConversationSelected = "bot.conversation.selected"
    case botConversationUpdated = "bot.conversation.updated"
    case botCreated = "bot.created"
    case botDeleted = "bot.deleted"
    case botDockerCleared = "bot.docker.cleared"
    case botFilesChanged = "bot.files.changed"
    case botFilesOpened = "bot.files.opened"
    case botFilesUpdated = "bot.files.updated"
    case botGroupTurnUpdated = "bot.group.turn.updated"
    case botGroupUpdated = "bot.group.updated"
    case botGuestUpdated = "bot.guest.updated"
    case botMessageAccepted = "bot.message.accepted"
    case botMessageQueued = "bot.message.queued"
    case botQueueUpdated = "bot.queue.updated"
    case botRoutineRunRequested = "bot.routine.run_requested"
    case botRoutineUpdated = "bot.routine.updated"
    case botRunCompleted = "bot.run.completed"
    case botRunFailed = "bot.run.failed"
    case botRunStarted = "bot.run.started"
    case botRunStopRequested = "bot.run.stop_requested"
    case botRunStream = "bot.run.stream"
    case botSchedulerUpdated = "bot.scheduler.updated"
    case botSettingsUpdated = "bot.settings.updated"
    case botTeamUpdated = "bot.team.updated"
    case botUpdated = "bot.updated"
    case botsAttentionChanged = "bots.attention.changed"
    case browserMirrorURLRegistered = "browser.mirror_url.registered"
    case browserScreenshotCreated = "browser.screenshot.created"
    case diagnosticHTTPClOExecFailed = "diagnostic.http_cloexec_failed"
    case diagnosticHTTPConnectionLimit = "diagnostic.http_connection_limit"
    case diagnosticUnixClientLimit = "diagnostic.unix_client_limit"
    case diagnosticUnixRequestLimit = "diagnostic.unix_request_limit"
    case diagnosticUnixRequestTimeout = "diagnostic.unix_request_timeout"
    case diagnosticUnixSlowClient = "diagnostic.unix_slow_client"
    case diagnosticWSConnectionClosed = "diagnostic.ws_connection_closed"
    case diagnosticWSOutboundPressure = "diagnostic.ws_outbound_pressure"
    case diagnosticWSSlowClient = "diagnostic.ws_slow_client"
    case deviceRevoke = "device.revoke"
    case eventsBaselineRequired = "events.baseline_required"
    case filesEditClosed = "files.edit.closed"
    case filesEditConflict = "files.edit.conflict"
    case filesEditDiscarded = "files.edit.discarded"
    case filesEditOpened = "files.edit.opened"
    case filesEditPatchApplied = "files.edit.patch_applied"
    case filesEditSaved = "files.edit.saved"
    case filesStateUpdated = "files.state.updated"
    case fsWorkspaceChanged = "fs.workspace.changed"
    case gitBranchCreated = "git.branch_created"
    case gitCheckout = "git.checkout"
    case gitCommit = "git.commit"
    case gitDeliver = "git.deliver"
    case gitPush = "git.push"
    case graphifyThreadRoots = "graphify.thread.roots"
    case hostBootEpoch = "host.boot_epoch"
    case notificationCreated = "notification.created"
    case notificationDismissed = "notification.dismissed"
    case notificationRead = "notification.read"
    case paneResized = "pane.resized"
    case paneSplit = "pane.split"
    case paneSwapped = "pane.swapped"
    case privatePushTokenUpdated = "private.push_token.updated"
    case projectOpenedInEditor = "project.opened_in_editor"
    case projectScriptFinished = "project.script.finished"
    case projectScriptStarted = "project.script_started"
    case serverListener = "server.listener"
    case serverListenerPublication = "server.listener.publication"
    case settingsUpdated = "settings.updated"
    case sshHostDeleted = "ssh.host.deleted"
    case sshHostUpdated = "ssh.host.updated"
    case sshSessionUpdated = "ssh.session.updated"
    case sshTransferFinished = "ssh.transfer.finished"
    case sshTransferCompleted = "ssh.transfer.completed"
    case sshTransferFailed = "ssh.transfer.failed"
    case sshTransferStarted = "ssh.transfer.started"
    case surfaceBrowser = "surface.browser"
    case surfaceClosed = "surface.closed"
    case surfaceCreated = "surface.created"
    case surfaceFocused = "surface.focused"
    case surfaceHealth = "surface.health"
    case surfaceMoved = "surface.moved"
    case surfaceOutput = "surface.output"
    case surfaceOutputSummary = "surface.output.summary"
    case surfaceRenamed = "surface.renamed"
    case surfaceReordered = "surface.reordered"
    case surfaceUpdated = "surface.updated"
    case tokenSaverDigest = "token_saver.digest"
    case windowClosed = "window.closed"
    case windowCreated = "window.created"
    case windowFocused = "window.focused"
    case workspaceClosed = "workspace.closed"
    case workspaceCreated = "workspace.created"
    case workspaceRenamed = "workspace.renamed"
    case workspaceReordered = "workspace.reordered"
    case workspaceSelected = "workspace.selected"
    case workspaceUpdated = "workspace.updated"
}

public enum RemoteCodeEvent: Equatable, Sendable {
    case known(kind: RemoteCodeEventKind, payload: RemoteCodeJSONValue)
    case unknown(kind: String, payload: RemoteCodeJSONValue)
}

public struct RemoteCodeEventEnvelope: Codable, Equatable, Sendable {
    public let seq: Int64
    public let rawKind: String
    public let payload: RemoteCodeJSONValue
    public let ts: Double
    public let hostID: String?
    public let bootEpoch: UInt64?
    public let treatyVersion: TreatyVersion?

    public var kind: RemoteCodeEventKind? { RemoteCodeEventKind(rawValue: rawKind) }
    public var isUnknown: Bool { kind == nil }
    public var event: RemoteCodeEvent {
        if let kind { return .known(kind: kind, payload: payload) }
        return .unknown(kind: rawKind, payload: payload)
    }

    public init(
        seq: Int64,
        kind: RemoteCodeEventKind,
        payload: RemoteCodeJSONValue,
        ts: Double,
        hostID: String? = nil,
        bootEpoch: UInt64? = nil,
        treatyVersion: TreatyVersion? = nil
    ) {
        self.seq = seq
        self.rawKind = kind.rawValue
        self.payload = payload
        self.ts = ts
        self.hostID = hostID
        self.bootEpoch = bootEpoch
        self.treatyVersion = treatyVersion
    }

    private enum CodingKeys: String, CodingKey {
        case seq, kind, payload, ts
        case hostID = "host_id"
        case bootEpoch = "boot_epoch"
        case treatyVersion = "treaty_version"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int64.self, forKey: .seq)
        rawKind = try container.decode(String.self, forKey: .kind)
        payload = try container.decode(RemoteCodeJSONValue.self, forKey: .payload)
        if RemoteCodeEventKind(rawValue: rawKind) != nil, payload.objectValue == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .payload,
                in: container,
                debugDescription: "Known RemoteCode events require an object payload."
            )
        }
        ts = try container.decode(Double.self, forKey: .ts)
        hostID = try container.decodeIfPresent(String.self, forKey: .hostID)
        bootEpoch = try container.decodeIfPresent(UInt64.self, forKey: .bootEpoch)
        treatyVersion = try container.decodeIfPresent(
            TreatyVersion.self,
            forKey: .treatyVersion
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(rawKind, forKey: .kind)
        try container.encode(payload, forKey: .payload)
        try container.encode(ts, forKey: .ts)
        try container.encodeIfPresent(hostID, forKey: .hostID)
        try container.encodeIfPresent(bootEpoch, forKey: .bootEpoch)
        try container.encodeIfPresent(treatyVersion, forKey: .treatyVersion)
    }
}

public enum EventsRecent: RemoteCodeRPCContract {
    public static let method = "events.recent"

    public struct Params: Codable, Equatable, Sendable {
        public let sinceSeq: Int64
        public let maxBytes: Int?
        /// C8: replay the host event log past the in-memory ring. Send only
        /// after the welcome capability `events.durable_replay_v1`.
        public let durable: Bool?

        public init(sinceSeq: Int64, maxBytes: Int? = nil, durable: Bool? = nil) {
            self.sinceSeq = sinceSeq
            self.maxBytes = maxBytes
            self.durable = durable
        }

        private enum CodingKeys: String, CodingKey {
            case sinceSeq = "since_seq"
            case maxBytes = "max_bytes"
            case durable
        }
    }

    /// C8: replay-only events of one stream were lost after `sinceSeq`.
    /// Exactly one of `threadID` (refetch the thread tail) or `surfaceID`
    /// (refetch the terminal) is set.
    public struct StreamGap: Codable, Equatable, Sendable {
        public let threadID: String?
        public let surfaceID: String?
        public let sinceSeq: Int64
        public let throughSeq: Int64

        public init(threadID: String?, surfaceID: String?, sinceSeq: Int64, throughSeq: Int64) {
            self.threadID = threadID
            self.surfaceID = surfaceID
            self.sinceSeq = sinceSeq
            self.throughSeq = throughSeq
        }

        private enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case surfaceID = "surface_id"
            case sinceSeq = "since_seq"
            case throughSeq = "through_seq"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let lastSeq: Int64
        public let events: [RemoteCodeEventEnvelope]
        public let truncated: Bool
        public let requiresBaseline: Bool
        public let hostID: String?
        public let bootEpoch: UInt64?
        public let treatyVersion: TreatyVersion?
        /// C8: present only on a `durable: true` request.
        public let streamGaps: [StreamGap]?

        public init(
            lastSeq: Int64,
            events: [RemoteCodeEventEnvelope],
            truncated: Bool,
            requiresBaseline: Bool,
            hostID: String?,
            bootEpoch: UInt64?,
            treatyVersion: TreatyVersion?,
            streamGaps: [StreamGap]? = nil
        ) {
            self.lastSeq = lastSeq
            self.events = events
            self.truncated = truncated
            self.requiresBaseline = requiresBaseline
            self.hostID = hostID
            self.bootEpoch = bootEpoch
            self.treatyVersion = treatyVersion
            self.streamGaps = streamGaps
        }

        private enum CodingKeys: String, CodingKey {
            case lastSeq = "last_seq"
            case events, truncated
            case requiresBaseline = "requires_baseline"
            case hostID = "host_id"
            case bootEpoch = "boot_epoch"
            case treatyVersion = "treaty_version"
            case streamGaps = "stream_gaps"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastSeq = try container.decode(Int64.self, forKey: .lastSeq)
            events = try container.decode([RemoteCodeEventEnvelope].self, forKey: .events)
            truncated = try container.decode(Bool.self, forKey: .truncated)
            requiresBaseline = try container.decode(Bool.self, forKey: .requiresBaseline)
            hostID = try container.decodeIfPresent(String.self, forKey: .hostID)
            bootEpoch = try container.decodeIfPresent(UInt64.self, forKey: .bootEpoch)
            treatyVersion = try container.decodeIfPresent(TreatyVersion.self, forKey: .treatyVersion)
            streamGaps = try container.decodeIfPresent([StreamGap].self, forKey: .streamGaps)

            let hasAnyIdentity = hostID != nil || bootEpoch != nil || treatyVersion != nil
            let hasCompleteIdentity = hostID?.isEmpty == false
                && bootEpoch != nil
                && treatyVersion != nil
            guard !hasAnyIdentity || hasCompleteIdentity else {
                throw DecodingError.dataCorruptedError(
                    forKey: .hostID,
                    in: container,
                    debugDescription: "events.recent identity must be complete or absent"
                )
            }
            guard events.allSatisfy({ event in
                let eventHasAnyIdentity = event.hostID != nil
                    || event.bootEpoch != nil
                    || event.treatyVersion != nil
                guard hasCompleteIdentity else { return !eventHasAnyIdentity }
                return event.hostID == hostID
                    && event.bootEpoch == bootEpoch
                    && event.treatyVersion == treatyVersion
            }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .events,
                    in: container,
                    debugDescription: "events.recent event identity does not match its envelope"
                )
            }
        }
    }
}
