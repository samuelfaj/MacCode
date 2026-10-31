import Foundation
import CoreFoundation
import CryptoKit
import CoreModel
import os

private let sidecarQueueLog = Logger(
    subsystem: "io.remotecode.persistence",
    category: "bot-sidecar-queue-migration"
)

private let botRemoteControlLog = Logger(
    subsystem: "io.remotecode.persistence",
    category: "bot-remote-control"
)

/// Host-authoritative paired Bot remote-control engine.
///
/// Mutations succeed only with a logical request id plus receipt/status/readback.
/// Silent local-only success is a contract failure. Effects/Channels stay
/// unavailable even when raw persisted true. Reserved IDs never get positive
/// product surfaces.
public final class BotRemoteControlAuthority: @unchecked Sendable {
    public static let liveAccountCap = BotDefinition.liveAccountCap
    public static let reservedCapabilityIDs: Set<String> = ["U034", "U038", "U039", "U045"]
    public static let blobatarShapes = BotBlobatarShape.allCases.map(\.rawValue)
    public static let blobatarHues = ["auto"] + BotBlobatar.studioHues.map(\.id)
    public static let sendKeys = ["button", "return", "keypad_enter", "command_return"]
    public static let newlineKeys = ["shift_return", "option_return"]
    public static let destinations = ["desk", "studio", "active", "schedule"]
    private static let guestSecurity: [String: Any] = [
        "bot_bound": true,
        "host_bound": true,
        "opaque_grant": true,
        "loopback_url_exported": false,
        "bearer_exported": false,
    ]

    public enum Status: String, Sendable {
        case accepted, completed, failed, unknown, partial
    }

    public struct Error: Swift.Error, Equatable, CustomStringConvertible {
        public let code: Int
        public let message: String
        public var description: String { message }
        public init(code: Int, message: String) {
            self.code = code
            self.message = message
        }
        public static let invalidParams = Error(code: -32602, message: "Invalid params")
        public static let controlPlaneOff = Error(code: -32081, message: "Bot control plane is off.")
        public static let notFound = Error(code: -32044, message: "MacCode Bot was not found.")
        public static let cap = Error(code: -32082, message: "Account limit of 50 live bots reached.")
        public static let reserved = Error(code: -32083, message: "Reserved capability has no positive Bot parity.")
        public static let missingRequest = Error(code: -32097, message: "Mutation requires a non-empty client_request_id.")
        public static let crossTarget = Error(code: -32084, message: "Attachment grant does not match this Bot or conversation.")
        public static let conversationGone = Error(code: -32080, message: "This Bot conversation no longer exists on the Mac. Refresh to continue.")
        public static let routineGone = Error(code: -32079, message: "This routine no longer exists on the Mac.")
        public static let handleConflict = Error(code: -32085, message: "Bot handle is already used or retired.")
        public static let guestConflict = Error(code: -32092, message: "Bot Guest authority is stale or does not match this host, Bot, task, runtime, grant, or frame.")
    }

    private let lock = NSLock()
    private let store: BotStore
    private let settings: SettingsStore
    private let db: SQLiteDB
    private let appSupport: URL
    private let browserStore: BotBrowserStore
    private let attentionBindings: BotAttentionPushBindingStore
    private let attentionNotificationMetadata: BotAttentionNotificationMetadataStore

    public var onVMWorkspaceExists: ((WorkspaceID) -> Bool)?
    public var onHasLiveRun: ((BotID) -> Bool)?
    public var onStopRun: ((BotID, String?, String?, String?, Bool, String) -> Void)?
    public var onContextBindingChanged: ((BotContextBinding) -> Bool)?
    public var onStartGuest: ((BotID, String, String, [String: Any]) -> Void)?
    public var onStopGuest: ((BotID, String, [String: Any]) -> Void)?
    public var onRebuildGuest: ((BotID, String, [String: Any]) -> Void)?
    public var onGuestInput: ((BotID, [String: Any], String, [String: Any]) throws -> Void)?
    /// Who drives each bot computer. `bot.guest.control` takes or releases it
    /// and `bot.guest.state` reports it as `controlled_by_user`.
    public var computerControl: BotComputerControl = .shared
    /// After `bot.guest.control` changed who drives (true: the user took it).
    /// Runs under the authority lock, so it must not call back into this authority.
    public var onGuestControlChanged: ((BotID, Bool) -> Void)?
    public var onDockerClear: ((BotID) throws -> Void)?
    /// Routing is nil when the send carries no routing receipt: the host then
    /// runs the conversation's own desk route (or the resolved Distill default)
    /// and reports it back as `effective_routing`.
    /// The last argument is the client's `client_capabilities` from `bot.send`
    /// (e.g. `titio_notice_act_v1`: the client taps Titio cards through
    /// `bot.notice.act`, so its text is never read as a card answer).
    public var onSend: ((BotID, String, BotConversationID?, [AgentAttachment], [String: Any]?, Set<String>) throws -> [String: Any])?
    /// A routine execution (scheduled slot or `bot.routine.run`): the same
    /// host send as `bot.send`, in a new conversation on the routine's own
    /// route. Returns the send's `bot_id`, `conversation_id` and `run_id`.
    public var onRoutineSend: ((BotRoutine) throws -> [String: Any])?
    /// `bot.routing.set` with `conversation_id`: the host adopts the route as
    /// that conversation's desk route and returns the resolved route.
    public var onConversationRoutingSet: ((BotID, BotConversationID, [String: Any]) throws -> [String: Any])?
    /// The route the next send to a desk conversation runs, for `bot.conversation.list`.
    public var onConversationRouting: ((BotConversation) -> [String: Any]?)?
    public var onForceQueuedFollowUp: ((BotID, String) throws -> [String: Any])?
    public var onDelegatedAttentionSnapshot: (() throws -> [[String: Any]])?
    public var onOpenFile: ((BotID, String, Bool, String) throws -> Void)?
    public var onImportFile: ((BotID, URL) throws -> AgentAttachment)?
    /// `bot.notice.act` (hub spec §7): Titio's notice hub claims the row and
    /// answers `{"outcome", "route"?}`. Runs off the MainActor under the
    /// authority lock, so it must not call back into this authority.
    public var onNoticeReply: ((BotID, String, String, Int?) throws -> [String: Any])?
    public var onNoticeContextualAct: ((BotID, String, Int) throws -> [String: Any]?)?
    public var onNoticeAct: ((BotID, String, Int) throws -> [String: Any])?
    /// `bot.notice.read`: the inbox unread count goes to 0.
    public var onNoticeRead: ((BotID, BotConversationID) throws -> [String: Any])?
    /// `bot.notice.clear` (contract §3): removes an assistant message from
    /// Titio's inbox and answers `{"thread_id"}`; throws `invalidParams` for
    /// any other message. Runs off the MainActor under the authority lock.
    public var onNoticeClear: ((BotID, String) throws -> [String: Any])?
    /// The `titio_inbox` object for Titio's `bot.list` row and the inbox's
    /// `bot.conversation.list` kind (in-memory, no SQLite). Nil: no inbox yet.
    public var onTitioInbox: (() -> [String: Any]?)?
    public var notifyBrowserPendingOpen: ((Notification.Name) throws -> Void)?

    private var receipts: [String: [String: Any]] = [:]
    private var receiptClaims: [String: [String: String]] = [:]
    private var unpublished: Set<String> = []
    private var attachments: [String: [String: Any]] = [:]
    private var files: [String: [String: Any]] = [:]
    private var browser: [String: [String: Any]] = [:]
    private var guest: [String: [String: Any]] = [:]
    /// Frames an observing viewer replaced, per bot and runtime grant (newest
    /// last). Input aimed at one of them is still on the screen the user saw,
    /// until an input settles a new frame.
    private var guestRecentFrames: [String: (grantID: String, frames: [RecentGuestFrame])] = [:]
    private var liveRuns: [String: [String: Any]] = [:]
    private var attention: [String: [String: Any]] = [:]
    private var peerReceipts: [String: [String: Any]] = [:]
    private var schedulerRuns: [[String: Any]] = []
    private var routineRuntime: [String: [String: Any]] = [:]
    /// True at launch and after automatic runs were paused: the next tick
    /// skips slots missed meanwhile instead of catching them up.
    private var routineSlotsNeedReseed = true
    private var filesLocation: [String: String] = [:]
    private var fileGenerations: [String: Int] = [:]
    private var fileCAS: [String: String] = [:]
    private var fileHosts: [String: String] = [:]
    /// File-link capabilities must be reissued by a current-process
    /// `bot.files.list`; persisted handles alone are never executable after relaunch.
    private var processIssuedFileHandles: Set<String> = []
    private var routingPref: [String: [String: Any]] = [:]
    private var consumedRoutingReceipts: Set<String> = []
    private var selectedConversation: [String: String] = [:]
    private var generation: Int = 1
    /// The JSON this process last committed for each sidecar key, so a
    /// mutation writes only the rows it changed. Empty at launch: the first
    /// persist writes every row.
    private var persistedSidecarJSON: [String: Data] = [:]

    private struct QuarantinedBotState {
        let wasUnpublished: Bool
        let attachments: [String: [String: Any]]
        let files: [String: [String: Any]]
        let fileHandles: Set<String>
        let filesLocation: String?
        let fileGenerations: [String: Int]
        let fileCAS: [String: String]
        let fileHost: String?
        let browser: [String: Any]?
        let guest: [String: Any]?
        let liveRun: [String: Any]?
        let attention: [String: Any]?
        let routing: [String: Any]?
        let routingReceiptWasConsumed: Bool
        let selectedConversation: String?
    }
#if DEBUG
    /// Exact per-write formatter path retained only for same-process A/B receipts.
    var useLegacySidecarDateFormatterForBenchmark = false

    func isFileHandleExecutableForTesting(_ handle: String) -> Bool {
        processIssuedFileHandles.contains(handle)
    }
#endif

    public init(db: SQLiteDB, store: BotStore, settings: SettingsStore, appSupportDirectory: URL) {
        self.db = db
        self.store = store
        self.settings = settings
        self.appSupport = appSupportDirectory
        self.browserStore = BotBrowserStore(appSupportDirectory: appSupportDirectory)
        self.attentionBindings = BotAttentionPushBindingStore(db: db)
        self.attentionNotificationMetadata = BotAttentionNotificationMetadataStore(db: db)
        loadSidecar()
        invalidateRestoredGuestGrants()
        migrateSidecarQueueIfNeeded()
    }

    /// Upgrade an `accepted` receipt after `dispatch` returns. In-hook settle is
    /// overwritten by `mutate`, and `NSLock` is not recursive.
    @discardableResult
    public func settle(
        requestID: String,
        status: Status,
        readback: [String: Any]? = nil
    ) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard var existing = receipts[requestID],
              (existing["status"] as? String) == Status.accepted.rawValue else { return nil }
        existing["status"] = status.rawValue
        if let readback {
            if let botID = existing["bot_id"] as? String,
               var current = guest[botID],
               readback["viewer_path"] != nil || readback["viewer"] != nil {
                let shownFrame = current["frame"] as? [String: Any]
                for (key, value) in readback { current[key] = value }
                // An observing viewer may have replaced the frame this result
                // was built on: keep frame sequences strictly increasing.
                if var settledFrame = current["frame"] as? [String: Any],
                   let shownSequence = shownFrame?["sequence"] as? Int,
                   let settledSequence = settledFrame["sequence"] as? Int,
                   settledSequence <= shownSequence,
                   settledFrame["frame_id"] as? String != shownFrame?["frame_id"] as? String {
                    settledFrame["sequence"] = shownSequence + 1
                    current["frame"] = settledFrame
                }
                // A settled frame shows the screen after the input: frames an
                // observe replaced before it no longer match what is there.
                if (current["frame"] as? [String: Any])?["frame_id"] as? String
                    != shownFrame?["frame_id"] as? String {
                    guestRecentFrames[botID] = nil
                }
                current["viewer"] = "/vnc.html"
                current["viewer_path"] = "/vnc.html"
                current["security"] = Self.guestSecurity
                guest[botID] = current
                existing["readback"] = current
            } else if readback["force"] is Bool,
                      var current = existing["readback"] as? [String: Any] {
                for (key, value) in readback { current[key] = value }
                existing["readback"] = current
            } else {
                existing["readback"] = readback
            }
        }
        receipts[requestID] = existing
        persistSidecar()
        return existing
    }

    public func dispatch(method: String, params: [String: Any], now: Date = Date()) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if method.hasPrefix("bot.") == false {
            throw Error.invalidParams
        }
        let name = String(method.dropFirst(4))
        if Self.reservedCapabilityIDs.contains(params["capability_id"] as? String ?? "") {
            throw Error.reserved
        }
        let contextMethods: Set<String> = ["context.list", "context.grant", "context.revoke"]
        if name == "conversation.enqueue" {
            let fields: Set<String> = ["client_request_id", "host_id", "bot_id", "context_key", "context_version", "policy_revision", "conversation_id", "text"]
            guard Set(params.keys) == fields else { throw Error.invalidParams }
        }
        if contextMethods.contains(name) {
            guard Set(params.keys).isSubset(of: ["host_id", "bot_id", "context_key", "context_version", "policy_revision", "actions", "client_request_id"]) else { throw Error.invalidParams }
        }
        let hasContext = ["context_key", "context_version", "policy_revision"].contains(where: { params[$0] != nil })
        if hasContext && ["conversation.list", "conversation.select"].contains(name) {
            let fields: Set<String> = name == "conversation.list"
                ? ["host_id", "bot_id", "context_key", "context_version", "policy_revision"]
                : ["host_id", "bot_id", "context_key", "context_version", "policy_revision", "client_request_id", "conversation_id"]
            guard Set(params.keys).isSubset(of: fields) else { throw Error.invalidParams }
        }
        if hasContext, !contextMethods.contains(name) {
            guard let context = parseContext(params), let (hostID, botID) = contextIdentity(params),
                  let revision = integer(params["policy_revision"]), revision > 0,
                  let action = contextAction(for: name) else { throw Error.invalidParams }
            guard try store.authorizes(hostID: hostID, botID: botID, context: context, action: action, policyRevision: revision) else {
                throw Error(code: -32084, message: "Bot context authority is not active for this request.")
            }
            if !["conversation.create", "conversation.list", "conversation.select", "conversation.enqueue", "conversation.export.preview", "conversation.export"].contains(name) { throw Error(code: -32602, message: "Context resource unavailable.") }
            if name == "conversation.create" {
                guard Set(params.keys).isSubset(of: ["client_request_id", "bot_id", "title", "host_id", "context_key", "context_version", "policy_revision"]) else { throw Error.invalidParams }
            }
        }
        switch name {
        case "vm.list":
            let bot = params["bot_id"] == nil ? nil : try requireBot(params)
            let machines = try store.listVirtualMachines().filter { bot.map($0.allows) ?? true }
            return ["virtual_machines": machines.map(encodeVirtualMachine)]
        case "context.list":
            return try contextList(params: params)
        case "context.grant", "context.revoke":
            return try mutate(name: name, params: params, now: now)
        case "list":
            return try list(params: params)
        case "get":
            return try get(params: params)
        case "settings.get":
            return settingsReadback()
        case "queue.list":
            return try queueList(params: params)
        case "conversation.list":
            return try conversationList(params: params)
        case "conversation.export.preview", "conversation.export":
            return try conversationExport(params: params, confirmed: name == "conversation.export")
        case "attachment.list":
            return try attachmentList(params: params)
        case "routine.list":
            return try routineList(params: params)
        case "files.list":
            return try filesList(params: params)
        case "browser.state":
            return try browserState(params: params)
        case "guest.state":
            return try guestState(params: params)
        case "receipt.status":
            return receiptStatus(params: params)
        case "peer.receipt.status":
            return peerReceiptStatus(params: params)
        case "attention.list":
            try synchronizeDurableNeedsAttention()
            try synchronizeDelegatedAttention()
            settleOrphanedWorkingAttention(now: now)
            // Group items are opt-in (`include_kinds: ["group"]`): a client
            // without groups would show one as the bot's own attention and
            // could never clear it (bot.attention.ack is per bot).
            let kinds = (params["include_kinds"] as? [Any])?.compactMap { $0 as? String } ?? []
            let groups = kinds.contains("group") ? groupAttentionItems(hostID: string(params, "host_id")) : []
            return ["items": attention.values.map { canonicalAttentionItem($0) } + groups]
        case "reserved.probe":
            throw Error.reserved
        default:
            return try mutate(name: name, params: params, now: now)
        }
    }

    /// Settles only the exact live run previously admitted by `bot.send`.
    /// Generic Agent terminal events cannot move a different Bot or newer run.
    @discardableResult
    public func settleRuntime(
        botID: String,
        runID: String,
        failed: Bool,
        now: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let run = liveRuns[botID],
              let storedRunID = run["run_id"] as? String,
              runtimeIDsMatch(storedRunID, runID) else { return false }
        liveRuns.removeValue(forKey: botID)
        // The slot holds one item per Bot. When a routine or a delegated row
        // replaced it, the run has still ended; leave that item alone.
        guard var item = attention[botID],
              let attentionRunID = item["run_id"] as? String,
              runtimeIDsMatch(attentionRunID, runID) else { return true }
        // A projection read failure must not block the terminal settle;
        // otherwise liveRuns stays pinned until the host restarts.
        let durableQuestion: [String: Any]?
        do {
            durableQuestion = try durableNeedsAttention(
                botID: botID,
                run: run,
                items: store.listAttention()
            )
        } catch {
            botRemoteControlLog.error(
                "bot.attention.settle_projection_failed bot=\(botID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            durableQuestion = nil
        }
        if let durableQuestion {
            attention[botID] = durableQuestion
            persistSidecar()
            return true
        }
        item["state"] = "finished"
        item["finished_at"] = now.timeIntervalSince1970
        item["detail"] = failed ? "Run failed" : "Run completed"
        item["outcome"] = failed ? "failed" : "completed"
        attention[botID] = canonicalAttentionItem(item)
        persistSidecar()
        return true
    }

    private func runtimeIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let canonicalLeft = UUID(uuidString: lhs)?.uuidString.lowercased() ?? lhs
        let canonicalRight = UUID(uuidString: rhs)?.uuidString.lowercased() ?? rhs
        return canonicalLeft == canonicalRight
    }

    // MARK: - Routine scheduler

    /// A routine slot a tick claimed. It is spent once claimed: start it with
    /// `startRoutineFire` or record why it could not start.
    public struct RoutineFire: Sendable, Equatable {
        public let routine: BotRoutine
        public let scheduledAt: Date
    }

    /// The in-process timer's period. A slot missed by less than one tick
    /// still fires after a relaunch, a pause, or an edit.
    public static let routineTickInterval: TimeInterval = 30
    static let schedulerRunHistoryLimit = 50

    /// Claims every due routine slot with one store read, off the main thread.
    /// The claim writes `last_slot_at` and the next `next_run_at` before any
    /// run starts, so an overlapping tick or a relaunch never fires a slot twice.
    public func claimDueRoutines(now: Date = Date()) throws -> [RoutineFire] {
        lock.lock()
        defer { lock.unlock() }
        let pass = try claimDueRoutinesLocked(now: now)
        if pass.changed { persistSidecar() }
        return pass.claims
    }

    /// Starts a claimed slot as a real Bot run and records what happened:
    /// `started` with its run, or `failed` with the reason. Never `completed`.
    @discardableResult
    public func startRoutineFire(_ fire: RoutineFire, now: Date = Date()) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let started = startRoutineLocked(fire.routine, scheduledAt: fire.scheduledAt, hostID: nil, now: now)
        persistSidecar()
        return started.run
    }

    /// A claimed slot that never reached the send (its bot computer did not
    /// come up) is recorded as failed, never dropped.
    @discardableResult
    public func failRoutineFire(_ fire: RoutineFire, reason: String, now: Date = Date()) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let failed = recordRoutineRunLocked(
            routineRunRecord(fire.routine, scheduledAt: fire.scheduledAt, now: now, error: reason),
            routine: fire.routine,
            hostID: nil,
            now: now
        )
        persistSidecar()
        return failed.run
    }

    private func claimDueRoutinesLocked(now: Date) throws -> (claims: [RoutineFire], changed: Bool) {
        // Automatic runs follow the Schedule Tasks switch; after a pause the
        // first tick skips what the pause missed. `reload`: the switch is
        // written through another SettingsStore, whose cache is not ours.
        guard settings.reload().isBotAutonomyActive else {
            routineSlotsNeedReseed = true
            return ([], false)
        }
        let skipMissed = routineSlotsNeedReseed
        routineSlotsNeedReseed = false
        let routines = try store.listEnabledRoutines()
        let floor = now.addingTimeInterval(-Self.routineTickInterval)
        var changed = false
        // A disabled or deleted routine has no next run, so enabling it again
        // starts at its next slot, not at one it skipped while off.
        let enabledKeys = Set(routines.map { $0.definition.id.value.uuidString.lowercased() })
        for (key, runtime) in routineRuntime
        where !enabledKeys.contains(key) && runtime["next_run_at"] is Double {
            routineRuntime[key]?["next_run_at"] = NSNull()
            changed = true
        }
        var claims: [RoutineFire] = []
        for routine in routines {
            let definition = routine.definition
            let key = definition.id.value.uuidString.lowercased()
            var runtime = routineRuntime[key] ?? [:]
            let scheduleKey = definition.scheduleSpecJSON + "\n" + definition.scheduleNote
            var due = (runtime["next_run_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            if due == nil || runtime["schedule_key"] as? String != scheduleKey {
                // New, enabled again, or edited: the first slot after the edit
                // (or after the last tick), never an older one.
                due = nextRunDate(definition: definition, enabled: true, after: max(definition.updatedAt, floor))
                runtime["schedule_key"] = scheduleKey
            } else if skipMissed, let stale = due, stale < floor {
                // Missed while RemoteCode was closed or paused: skip, do not catch up.
                due = nextRunDate(definition: definition, enabled: true, after: floor)
            }
            if let slot = due, slot <= now {
                if runtime["last_slot_at"] as? Double != slot.timeIntervalSince1970 {
                    runtime["last_slot_at"] = slot.timeIntervalSince1970
                    claims.append(RoutineFire(routine: routine, scheduledAt: slot))
                }
                // A late slot (wake from sleep) fires once; the next one is
                // after now, so it never replays.
                due = nextRunDate(
                    definition: definition,
                    enabled: true,
                    after: max(slot.addingTimeInterval(ScheduledTaskOccurrenceCalculator.spentOccurrenceAdvance), now)
                )
            }
            runtime["next_run_at"] = dateValue(due)
            if !NSDictionary(dictionary: runtime).isEqual(to: routineRuntime[key] ?? [:]) {
                routineRuntime[key] = runtime
                changed = true
            }
        }
        return (claims, changed)
    }

    private func routineRunRecord(
        _ routine: BotRoutine,
        scheduledAt: Date?,
        now: Date,
        error: String? = nil
    ) -> [String: Any] {
        var run: [String: Any] = [
            "routine_id": routine.definition.id.value.uuidString.lowercased(),
            "bot_id": routine.definition.botID.value.uuidString.lowercased(),
            "executed_at": now.timeIntervalSince1970,
            "automatic": scheduledAt != nil,
            "schedule_spec_json": routine.definition.scheduleSpecJSON,
        ]
        if let scheduledAt { run["scheduled_at"] = scheduledAt.timeIntervalSince1970 }
        if let error {
            run["result"] = "failed"
            run["error"] = error
        }
        return run
    }

    private func startRoutineLocked(
        _ routine: BotRoutine,
        scheduledAt: Date?,
        hostID: String?,
        now: Date
    ) -> (run: [String: Any], notification: [String: Any]?) {
        var run = routineRunRecord(routine, scheduledAt: scheduledAt, now: now)
        do {
            if scheduledAt != nil {
                guard settings.reload().isBotAutonomyActive else {
                    routineSlotsNeedReseed = true
                    throw Error(code: -32081, message: "Automatic bot tasks are paused.")
                }
                guard let current = try store.listEnabledRoutines().first(where: { $0.definition.id == routine.definition.id }),
                      current.definition == routine.definition else {
                    throw Error(code: -32079, message: "Scheduled task changed, was disabled or was removed before execution.")
                }
            }
            guard let onRoutineSend else {
                throw Error(code: -32091, message: "Bot runtime is unavailable.")
            }
            let sent = try onRoutineSend(routine)
            guard let runID = sent["run_id"] as? String, !runID.isEmpty,
                  let conversationID = sent["conversation_id"] as? String, !conversationID.isEmpty else {
                throw Error(code: -32091, message: "Bot runtime did not start a run.")
            }
            run["run_id"] = runID
            run["conversation_id"] = conversationID
            run["result"] = "started"
        } catch let error as Error {
            run = routineRunRecord(routine, scheduledAt: scheduledAt, now: now, error: error.message)
        } catch {
            run = routineRunRecord(routine, scheduledAt: scheduledAt, now: now, error: String(describing: error))
        }
        return recordRoutineRunLocked(run, routine: routine, hostID: hostID, now: now)
    }

    /// The routine's runtime (what `bot.routine.list` shows), its attention
    /// item, and on failure a Mac Activity item plus the paired notification.
    private func recordRoutineRunLocked(
        _ run: [String: Any],
        routine: BotRoutine,
        hostID: String?,
        now: Date
    ) -> (run: [String: Any], notification: [String: Any]?) {
        let definition = routine.definition
        let routineKey = definition.id.value.uuidString.lowercased()
        let botID = definition.botID.value.uuidString.lowercased()
        let error = run["error"] as? String
        // Recent history only: every sidecar write re-encodes it, and each
        // routine row already carries its own last result.
        schedulerRuns.append(run)
        if schedulerRuns.count > Self.schedulerRunHistoryLimit {
            schedulerRuns.removeFirst(schedulerRuns.count - Self.schedulerRunHistoryLimit)
        }
        var runtime = routineRuntime[routineKey] ?? [:]
        let previousAttentionID = (runtime["attention_item_id"] as? String).flatMap(UUID.init(uuidString:))
        runtime["last_run_id"] = run["run_id"] ?? NSNull()
        runtime["last_execution_at"] = now.timeIntervalSince1970
        runtime["last_result"] = run["result"] ?? NSNull()
        runtime["last_error"] = error ?? NSNull()
        runtime["last_conversation_id"] = run["conversation_id"] ?? NSNull()
        routineRuntime[routineKey] = runtime
        let automatic = run["automatic"] as? Bool == true
        let notStarted = automatic ? "Scheduled task did not start" : "Task run did not start"
        let item = canonicalAttentionItem([
            "id": UUID().uuidString.lowercased(),
            "bot_id": botID,
            "conversation_id": run["conversation_id"] ?? NSNull(),
            "run_id": run["run_id"] ?? NSNull(),
            "state": error == nil ? "working" : "needs_attention",
            "finished_at": NSNull(),
            "ownership": "primary",
            "primary": true,
            "delegated": false,
            "title": definition.name,
            "detail": error.map { "\(notStarted): \($0)" }
                ?? (automatic ? "Scheduled task started" : "Task run started"),
            "source": "routine",
        ], hostID: hostID)
        attention[botID] = item
        guard let error else {
            if let previousAttentionID {
                do {
                    try store.acknowledgeAttention(id: BotAttentionItemID(previousAttentionID), now: now)
                    runtime.removeValue(forKey: "attention_item_id")
                    routineRuntime[routineKey] = runtime
                } catch {
                    botRemoteControlLog.error("bot_routine.attention_resolution_failed routine=\(routineKey, privacy: .public) error=\(String(describing: error), privacy: .public)")
                }
            }
            botRemoteControlLog.info(
                "bot_routine.started routine=\(routineKey, privacy: .public) bot=\(botID, privacy: .public) automatic=\(automatic, privacy: .public)"
            )
            return (run, nil)
        }
        botRemoteControlLog.error(
            "bot_routine.fire_failed routine=\(routineKey, privacy: .public) bot=\(botID, privacy: .public) automatic=\(automatic, privacy: .public) error=\(error, privacy: .public)"
        )
        var notification: [String: Any]?
        do {
            let attentionID = BotAttentionItemID(UUID(uuidString: item["id"] as? String ?? "") ?? UUID())
            try store.upsertAttention(BotAttentionItem(
                id: attentionID,
                botID: definition.botID,
                kind: .blocked,
                title: notStarted,
                detail: "\(definition.name): \(error)",
                createdAt: now
            ))
            if let previousAttentionID {
                try store.acknowledgeAttention(id: BotAttentionItemID(previousAttentionID), now: now)
            }
            runtime["attention_item_id"] = attentionID.value.uuidString.lowercased()
            routineRuntime[routineKey] = runtime
            notification = try persistAttentionNotification(item, now: now)
        } catch {
            botRemoteControlLog.error(
                "bot_routine.fire_failure_unsurfaced routine=\(routineKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
        return (run, notification)
    }

    private func synchronizeDurableNeedsAttention() throws {
        let items = try store.listAttention()
        var changed = false
        let openIDs = Set(items.map { $0.id.value.uuidString.lowercased() })
        let routineAttentionIDs = Set(routineRuntime.values.compactMap { $0["attention_item_id"] as? String })
        for (botID, item) in attention where item["state"] as? String == "needs_attention" {
            guard item["source"] as? String == "bot_ask_user"
                || routineAttentionIDs.contains(item["id"] as? String ?? "") else { continue }
            guard let itemID = item["id"] as? String, !openIDs.contains(itemID.lowercased()) else { continue }
            var resolved = item
            resolved["state"] = "none"
            attention[botID] = resolved
            changed = true
        }
        for (botID, run) in liveRuns {
            // One failing run must not fail the whole list.
            let projected: [String: Any]?
            do {
                projected = try durableNeedsAttention(botID: botID, run: run, items: items)
            } catch {
                botRemoteControlLog.error(
                    "bot.attention.durable_projection_failed bot=\(botID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                continue
            }
            guard let item = projected else { continue }
            if attention[botID]?["id"] as? String != item["id"] as? String
                || attention[botID]?["state"] as? String != "needs_attention" {
                attention[botID] = item
                changed = true
            }
        }
        if changed { persistSidecar() }
    }

    /// A `working` bot.send item whose run this process does not track (a host
    /// relaunch drops `liveRuns`) can never reach `settleRuntime`. Close it from
    /// the run's durable terminal status. A routine run is never in `liveRuns`.
    private func settleOrphanedWorkingAttention(now: Date) {
        var changed = false
        for (botID, item) in attention {
            guard item["state"] as? String == "working",
                  ["bot", "routine"].contains(item["source"] as? String ?? ""),
                  let runID = item["run_id"] as? String,
                  (liveRuns[botID]?["run_id"] as? String).map({ runtimeIDsMatch($0, runID) }) != true,
                  let terminal = terminalRunStatus(runID: runID) else { continue }
            let failed = terminal.status != "completed"
            var finished = item
            finished["state"] = "finished"
            finished["finished_at"] = terminal.finishedAt ?? now.timeIntervalSince1970
            finished["detail"] = failed ? "Run failed" : "Run completed"
            finished["outcome"] = failed ? "failed" : "completed"
            attention[botID] = canonicalAttentionItem(finished)
            changed = true
        }
        if changed { persistSidecar() }
    }

    private func synchronizeDelegatedAttention() throws {
        guard let onDelegatedAttentionSnapshot else { return }
        let snapshot = try onDelegatedAttentionSnapshot()
        var delegatedByBot: [String: [String: Any]] = [:]
        var conflictedBots: Set<String> = []
        for raw in snapshot {
            // One stale handoff (deleted Bot, cleared or relinked conversation)
            // must not fail the whole list; drop only that row.
            guard let item = try? validatedDelegatedAttention(raw),
                  let botID = item["bot_id"] as? String else {
                botRemoteControlLog.error(
                    "bot.attention.delegated_row_dropped id=\(String(describing: raw["id"] ?? "nil"), privacy: .public) bot=\(String(describing: raw["bot_id"] ?? "nil"), privacy: .public) state=\(String(describing: raw["state"] ?? "nil"), privacy: .public)"
                )
                continue
            }
            if let existing = delegatedByBot[botID],
               !NSDictionary(dictionary: existing).isEqual(to: item) {
                conflictedBots.insert(botID)
            }
            delegatedByBot[botID] = item
        }
        for botID in conflictedBots {
            // Ambiguous ownership for one Bot: show neither row for that Bot.
            botRemoteControlLog.error(
                "bot.attention.delegated_conflict_dropped bot=\(botID, privacy: .public)"
            )
            delegatedByBot.removeValue(forKey: botID)
        }

        var next = attention.filter { _, item in
            item["source"] as? String != "bot_peer_handoff"
        }
        for (botID, item) in delegatedByBot {
            // A historical finished handoff must not replace the item of a
            // newer live bot.send run: settleRuntime matches that item's
            // run_id, so the run would never settle and liveRuns would pin.
            if item["state"] as? String == "finished",
               let liveRunID = liveRuns[botID]?["run_id"] as? String,
               let delegatedRunID = item["run_id"] as? String,
               !runtimeIDsMatch(liveRunID, delegatedRunID) {
                continue
            }
            next[botID] = item
        }
        guard !NSDictionary(dictionary: attention).isEqual(to: next) else { return }
        attention = next
        persistSidecar()
    }

    /// One `kind: "group"` item per visible group whose attention is set,
    /// anchored on the turn that set it (its id is the item id). Cleared by
    /// `bot.group.select`. A read failure drops only the group rows. Only the
    /// turns that can anchor the item are read, never the group's history.
    private func groupAttentionItems(hostID: String?) -> [[String: Any]] {
        let groups: [BotGroupConversation]
        do {
            groups = try store.listGroups()
        } catch {
            botRemoteControlLog.error(
                "bot.attention.group_projection_failed error=\(String(describing: error), privacy: .public)"
            )
            return []
        }
        func key(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
        return groups.compactMap { group in
            let state: String
            let detail: String
            let anchor: BotGroupTurn?
            switch group.attentionState {
            case .none:
                return nil
            case .working:
                state = "working"
                detail = "Bots are answering"
                anchor = (try? store.listGroupTurns(
                    groupID: group.id,
                    states: BotGroupTurn.State.pending + [.running]
                ))?.first
            case .needsAttention:
                state = "needs_attention"
                detail = "A bot could not answer"
                anchor = (try? store.latestGroupTurn(groupID: group.id, states: [.failed, .interrupted])) ?? nil
            case .unreadActivity:
                state = "finished"
                detail = "New replies"
                anchor = (try? store.latestGroupTurn(groupID: group.id, states: [.completed])) ?? nil
            }
            guard let anchor else { return nil }
            return canonicalAttentionItem([
                "id": key(anchor.id.value),
                "kind": "group",
                "group_id": key(group.id.value),
                "thread_id": key(group.roomThreadID.value),
                "turn_id": key(anchor.id.value),
                "bot_id": key(anchor.botID.value),
                "run_id": anchor.memberRunID.map { key($0.value) as Any } ?? NSNull(),
                "state": state,
                "title": group.title,
                "detail": detail,
                "source": "bot_group",
                "ownership": "primary",
                "primary": true,
                "delegated": false,
                "created_at": anchor.createdAt.timeIntervalSince1970,
                "updated_at": group.updatedAt.timeIntervalSince1970,
                "finished_at": state == "working" ? NSNull() : anchor.updatedAt.timeIntervalSince1970 as Any,
            ], hostID: hostID)
        }
    }

    private func validatedDelegatedAttention(_ raw: [String: Any]) throws -> [String: Any] {
        guard raw["ownership"] as? String == "delegated",
              raw["primary"] as? Bool == false,
              raw["delegated"] as? Bool == true,
              raw["source"] as? String == "bot_peer_handoff",
              let itemID = stringUUID(raw, "id"),
              stringUUID(raw, "lifecycle_receipt_id") == itemID,
              let botID = stringUUID(raw, "bot_id"),
              let conversationID = stringUUID(raw, "conversation_id"),
              let threadID = stringUUID(raw, "thread_id"),
              stringUUID(raw, "run_id") != nil,
              let ownerBotID = stringUUID(raw, "owner_bot_id"),
              let ownerConversationID = stringUUID(raw, "owner_conversation_id"),
              let state = raw["state"] as? String,
              ["working", "finished", "needs_attention"].contains(state),
              let bot = try store.get(id: BotID(botID)), bot.deletedAt == nil,
              let conversation = try store.conversation(id: BotConversationID(conversationID)),
              conversation.botID == bot.id,
              let ownerBot = try store.get(id: BotID(ownerBotID)), ownerBot.deletedAt == nil,
              let ownerConversation = try store.conversation(id: BotConversationID(ownerConversationID)),
              ownerConversation.botID == ownerBot.id else {
            throw Error.crossTarget
        }
        if state == "finished" {
            guard raw["finished_at"] is Double else { throw Error.crossTarget }
        } else {
            guard raw["finished_at"] is NSNull else { throw Error.crossTarget }
        }
        // Finished rows are historical provenance: a conversation may since
        // have been relinked to a new Agent thread. Only active rows must
        // still match the live thread links.
        let requiresLiveLinks = state != "finished"
        if requiresLiveLinks {
            guard conversation.linkedAgentThreadID == AgentThreadID(threadID) else {
                throw Error.crossTarget
            }
        }
        if raw["owner_thread_id"] != nil && !(raw["owner_thread_id"] is NSNull) {
            guard let ownerThreadID = stringUUID(raw, "owner_thread_id"),
                  !requiresLiveLinks
                    || ownerConversation.linkedAgentThreadID == AgentThreadID(ownerThreadID) else {
                throw Error.crossTarget
            }
        }
        if raw["owner_run_id"] != nil && !(raw["owner_run_id"] is NSNull) {
            guard stringUUID(raw, "owner_run_id") != nil else { throw Error.crossTarget }
        }
        return canonicalAttentionItem(raw)
    }

    private func stringUUID(_ values: [String: Any], _ key: String) -> UUID? {
        guard let raw = values[key] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    private func durableNeedsAttention(
        botID: String,
        run: [String: Any],
        items: [BotAttentionItem]
    ) throws -> [String: Any]? {
        guard let botUUID = UUID(uuidString: botID),
              let conversationRaw = run["conversation_id"] as? String,
              let conversationUUID = UUID(uuidString: conversationRaw),
              let threadRaw = run["thread_id"] as? String,
              let threadUUID = UUID(uuidString: threadRaw),
              let runRaw = run["run_id"] as? String,
              let runUUID = UUID(uuidString: runRaw),
              let startedAt = run["started_at"] as? Double else {
            return nil
        }
        let exactBotID = BotID(botUUID)
        let exactConversationID = BotConversationID(conversationUUID)
        let exactThreadID = AgentThreadID(threadUUID)
        guard let conversation = try store.conversation(id: exactConversationID),
              conversation.botID == exactBotID,
              conversation.linkedAgentThreadID == exactThreadID else {
            return nil
        }
        let candidates = items.filter {
            $0.acknowledgedAt == nil
                && $0.botID == exactBotID
                && $0.conversationID == exactConversationID
                && $0.kind == .question
                && $0.createdAt.timeIntervalSince1970 >= floor(startedAt)
        }
        // A run may ask more than once (repeated bot_ask_user, desk "Needs
        // you" rows); the newest question wins, ids break same-second ties.
        guard let question = candidates.max(by: {
            ($0.createdAt, $0.id.value.uuidString) < ($1.createdAt, $1.id.value.uuidString)
        }) else { return nil }
        return canonicalAttentionItem([
            "id": question.id.value.uuidString.lowercased(),
            "bot_id": exactBotID.value.uuidString.lowercased(),
            "host_id": run["host_id"] as? String ?? "",
            "request_id": run["request_id"] as? String ?? "",
            "conversation_id": exactConversationID.value.uuidString.lowercased(),
            "thread_id": exactThreadID.value.uuidString.lowercased(),
            "run_id": runUUID.uuidString.lowercased(),
            "state": "needs_attention",
            "finished_at": NSNull(),
            "ownership": "primary",
            "primary": true,
            "delegated": false,
            "kind": question.kind.rawValue,
            "title": question.title,
            "detail": question.detail,
            "source": "bot_ask_user",
            "created_at": question.createdAt.timeIntervalSince1970,
        ], hostID: run["host_id"] as? String)
    }

    public func effectiveSettings() -> (raw: [String: Bool], effective: [String: Bool]) {
        let flags = settings.load().botControlPlaneFlags
        let raw: [String: Bool] = [
            "control_plane": flags.botsControlPlaneEnabled,
            "memory": flags.botsMemoryEnabled,
            "effects": flags.botsEffectsEnabled,
            "channels": flags.botsChannelsEnabled,
            "autonomy": flags.botsAutonomyEnabled,
        ]
        let effective: [String: Bool] = [
            "control_plane": flags.isBotControlPlaneActive,
            "memory": flags.isBotMemoryActive,
            "effects": false,
            "channels": false,
            "autonomy": flags.isBotAutonomyActive,
        ]
        return (raw, effective)
    }

    // MARK: - Reads

    private func contextList(params: [String: Any]) throws -> [String: Any] {
        guard Set(params.keys).isSubset(of: ["host_id", "bot_id"]),
              let (hostID, botID) = contextIdentity(params) else { throw Error.invalidParams }
        return ["bindings": try store.listContextBindings(hostID: hostID, botID: botID).map(encodeContextBinding)]
    }

    private func encodeContextBinding(_ binding: BotContextBinding) -> [String: Any] {
        ["host_id": binding.hostID, "bot_id": binding.botID.value.uuidString.lowercased(),
         "context_key": binding.context.storageKey, "context_version": BotContext.contractVersion,
         "policy_revision": binding.policyRevision, "state": binding.state.rawValue,
         "actions": binding.actions.map(\.rawValue).sorted()]
    }

    private func contextIdentity(_ params: [String: Any]) -> (String, BotID)? {
        guard let host = string(params, "host_id"), !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let raw = string(params, "bot_id"), let uuid = UUID(uuidString: raw) else { return nil }
        return (host, BotID(uuid))
    }

    private func contextTarget(_ params: [String: Any]) throws -> (String, BotID, BotContext) {
        guard let (host, botID) = contextIdentity(params), let context = parseContext(params) else { throw Error.invalidParams }
        return (host, botID, context)
    }

    private func contextAction(for method: String) -> BotContextAction? {
        switch method {
        case "get", "list", "settings.get", "queue.list", "conversation.list", "attachment.list", "routine.list", "files.list", "browser.state", "guest.state": return .read
        case "send", "queue.force_now", "conversation.create", "conversation.select", "conversation.clear_all", "conversation.fork", "conversation.enqueue": return .send
        case "attachment.stage", "attachment.import", "attachment.remove", "files.mutate", "files.open_tab", "files.split", "files.location.set", "browser.action", "link.open", "guest.input", "guest.start", "guest.stop", "guest.rebuild", "guest.revoke", "guest.control": return .files
        case "conversation.export.preview", "conversation.export": return .export
        case "soul.set": return .memory
        case "settings.set", "save", "set_pinned", "set_hidden", "reorder", "desktop.set", "avatar.set", "handle.set", "verbosity.set", "caveman.set", "routing.set": return .configure
        case "routine.create", "routine.update", "routine.enable", "routine.run", "routine.delete", "scheduler.tick": return .schedule
        case "peer.ask", "peer.self_config": return .delegate
        default: return nil
        }
    }

    private func parseContext(_ params: [String: Any]) -> BotContext? {
        guard let version = integer(params["context_version"]), version == BotContext.contractVersion,
              let key = string(params, "context_key") else { return nil }
        if key == "general:v1" { return .general }
        let prefix = "workspace:v1:"
        guard key.hasPrefix(prefix), let uuid = UUID(uuidString: String(key.dropFirst(prefix.count))),
              key == "workspace:v1:\(uuid.uuidString.lowercased())" else { return nil }
        return .workspace(WorkspaceID(uuid))
    }

    private func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int64.min), number.doubleValue < Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private func list(params: [String: Any]) throws -> [String: Any] {
        let includeHidden = (params["include_hidden"] as? Bool) ?? false
        let bots = try BotOrdering.sorted(store.list(includeHidden: includeHidden)).map { try encodeBot($0) }
        return ["bots": bots, "unpublished_ids": Array(unpublished).sorted()]
    }

    private func get(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        var encoded = try encodeBot(bot)
        encoded["unpublished"] = unpublished.contains(bot.id.value.uuidString.lowercased())
        return encoded
    }

    private func settingsReadback() -> [String: Any] {
        let pair = effectiveSettings()
        return [
            "raw": pair.raw,
            "effective": pair.effective,
            "effects_available": false,
            "channels_available": false,
        ]
    }

    private func queueList(params: [String: Any]) throws -> [String: Any] {
        guard let raw = string(params, "bot_id"), let uuid = UUID(uuidString: raw) else {
            return ["items": []]
        }
        let items = try store.listQueuedFollowUps(botID: BotID(uuid))
        return ["items": encodeQueue(items)]
    }

    private func conversationExport(params: [String: Any], confirmed: Bool) throws -> [String: Any] {
        var fields: Set<String> = ["host_id", "bot_id", "context_key", "context_version", "policy_revision", "conversation_id", "target_context_key", "target_policy_revision", "message_ids"]
        if confirmed { fields.formUnion(["approved", "selection_sha256"]) }
        guard Set(params.keys) == fields else { throw Error.invalidParams }
        return try db.transaction {
            try requireControlPlane()
            let denied = Error(code: -32084, message: "Contextual export is not authorized for this selection.")
            var targetParams = params
            targetParams["context_key"] = params["target_context_key"]
            guard let sourceContext = parseContext(params), let targetContext = parseContext(targetParams),
                  let (hostID, botID) = contextIdentity(params),
                  let revision = integer(params["policy_revision"]), revision > 0,
                  let targetRevision = integer(params["target_policy_revision"]), targetRevision > 0,
                  try store.authorizes(hostID: hostID, botID: botID, context: sourceContext, action: .read, policyRevision: revision),
                  try store.authorizes(hostID: hostID, botID: botID, context: sourceContext, action: .export, policyRevision: revision),
                  try store.authorizes(hostID: hostID, botID: botID, context: targetContext, action: .send, policyRevision: targetRevision),
                  let rawConversation = string(params, "conversation_id"), let conversationID = UUID(uuidString: rawConversation),
                  let conversation = try store.conversation(id: BotConversationID(conversationID)),
                  conversation.botID == botID, conversation.groupID == nil,
                  let threadID = conversation.linkedAgentThreadID,
                  let pin = try store.conversationContextPin(conversationID: conversation.id),
                  pin.hostID == hostID, pin.botID == botID, pin.context == sourceContext,
                  pin.contextVersion == BotContext.contractVersion, pin.policyRevision == revision,
                  let thread = try AgentThreadRepository(db: db).get(id: threadID),
                  thread.actor == .bot(botID), thread.actorLockedAt != nil,
                  thread.provider == .distill, thread.executionTarget != nil,
                  let rawIDs = params["message_ids"] as? [String], !rawIDs.isEmpty, rawIDs.count <= 32 else { throw denied }
            switch sourceContext {
            case .general: guard thread.workspaceId == nil else { throw denied }
            case .workspace(let workspace): guard thread.workspaceId == workspace else { throw denied }
            }
            let ids = rawIDs.compactMap(UUID.init(uuidString:))
            guard ids.count == rawIDs.count, Set(ids).count == ids.count else { throw denied }
            let repository = AgentMessageRepository(db: db)
            var messages: [[String: Any]] = []
            var excerpts: [String] = []
            var byteCount: Int64 = 0
            for id in ids {
                let membership = try db.prepare("SELECT length(CAST(content AS BLOB)) FROM agent_messages WHERE id=? COLLATE NOCASE AND thread_id=? COLLATE NOCASE;")
                defer { membership.reset() }
                try membership.bind(1, id.uuidString)
                try membership.bind(2, threadID.value.uuidString)
                guard try membership.step(), membership.columnInt64(0) >= 0 else { throw denied }
                byteCount += membership.columnInt64(0)
                guard byteCount <= 65_536,
                      let message = try repository.get(id: AgentMessageID(id)), message.threadId == threadID,
                      message.role == .user || message.role == .assistant,
                      !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw denied }
                messages.append(["id": id.uuidString.lowercased(), "role": message.role.rawValue, "text": message.content])
                excerpts.append("\(message.role.rawValue):\n\(message.content)")
            }
            var result: [String: Any] = [
                "host_id": hostID, "bot_id": botID.value.uuidString.lowercased(),
                "conversation_id": conversation.id.value.uuidString.lowercased(),
                "context_key": sourceContext.storageKey, "context_version": BotContext.contractVersion,
                "policy_revision": revision, "target_context_key": targetContext.storageKey,
                "target_policy_revision": targetRevision, "messages": messages,
            ]
            let canonical = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
            let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            if confirmed {
                guard let approved = params["approved"] as? NSNumber,
                      CFGetTypeID(approved) == CFBooleanGetTypeID(), approved.boolValue,
                      string(params, "selection_sha256") == digest else { throw denied }
            }
            if confirmed {
                // Receipt holds identifiers, counts and the digest only; never message text.
                let receipt: [String: Any] = [
                    "bot_id": botID.value.uuidString.lowercased(), "conversation_id": conversation.id.value.uuidString.lowercased(),
                    "source_context_key": sourceContext.storageKey, "source_policy_revision": revision,
                    "target_context_key": targetContext.storageKey, "target_policy_revision": targetRevision,
                    "message_ids": ids.map { $0.uuidString.lowercased() }, "bytes": byteCount, "selection_sha256": digest,
                ]
                let detail = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .withoutEscapingSlashes])
                try DeviceTrustRepository(db: db).audit(actor: "bot:\(hostID)", action: "bot.context.export", detail: String(decoding: detail, as: UTF8.self))
            }
            result["selection_sha256"] = digest
            result["summary"] = excerpts.joined(separator: "\n\n")
            result["exported"] = confirmed
            result["execution_available"] = false
            return result
        }
    }

    private func conversationList(params supplied: [String: Any]) throws -> [String: Any] {
        var params = supplied
        var taskReadback: [String: Any]?
        if supplied["task_run_id"] != nil || supplied["source_thread_id"] != nil {
            guard Set(supplied.keys).isSubset(of: ["bot_id", "task_run_id", "source_thread_id"]),
                  let runUUID = string(supplied, "task_run_id").flatMap(UUID.init(uuidString:)),
                  let sourceUUID = string(supplied, "source_thread_id").flatMap(UUID.init(uuidString:)),
                  let message = try AgentMessageRepository(db: db).get(id: AgentMessageID(runUUID)),
                  message.threadId == AgentThreadID(sourceUUID), message.role == .assistant,
                  let task = BotParallelTask.parse(message.content), task.runID.value == runUUID,
                  let requestedBot = string(supplied, "bot_id"), requestedBot.lowercased() == task.botID.value.uuidString.lowercased(),
                  let conversation = try store.conversation(id: task.conversationID),
                  conversation.botID == task.botID, conversation.linkedAgentThreadID == task.threadID,
                  let run = try AgentRunRepository(db: db).get(id: task.runID), run.threadId == task.threadID else {
                throw Error(code: -32084, message: "The task link is not available to this conversation.")
            }
            for threadID in [message.threadId, task.threadID] {
                if let pin = try store.conversationContextPin(linkedTo: threadID) {
                    guard try store.authorizes(hostID: pin.hostID, botID: pin.botID, context: pin.context,
                        action: .read, policyRevision: pin.policyRevision) else {
                        throw Error(code: -32084, message: "Task context read access was revoked.")
                    }
                }
            }
            if let pin = try store.conversationContextPin(linkedTo: task.threadID) {
                params["host_id"] = pin.hostID
                params["context_key"] = pin.context.storageKey
                params["context_version"] = pin.contextVersion
                params["policy_revision"] = pin.policyRevision
            }
            taskReadback = ["run_id": task.runID.value.uuidString.lowercased(),
                "thread_id": task.threadID.value.uuidString.lowercased(),
                "conversation_id": task.conversationID.value.uuidString.lowercased(),
                "status": run.status.rawValue]
        }
        let bot = try requireBot(params)
        let botID = id(bot)
        let inboxID = bot.handle.lowercased() == TitioIdentity.handle
            ? onTitioInbox?()?["conversation_id"] as? String : nil
        let scoped = ["context_key", "context_version", "policy_revision"].contains(where: { params[$0] != nil })
        let requestedContext = scoped ? parseContext(params) : nil
        let requestedHost = scoped ? string(params, "host_id") : nil
        let requestedRevision = scoped ? integer(params["policy_revision"]) : nil
        var selectedIsVisible = false
        let rows = try store.listConversations(botID: bot.id).compactMap { conversation -> [String: Any]? in
            let pin = try store.conversationContextPin(conversationID: conversation.id)
            if scoped {
                guard let pin, let requestedContext, let requestedHost, let requestedRevision,
                      let requestedVersion = integer(params["context_version"]),
                      pin.hostID == requestedHost, pin.botID == bot.id, pin.context == requestedContext,
                      Int64(pin.contextVersion) == requestedVersion, pin.policyRevision == requestedRevision else { return nil }
            } else if pin != nil { return nil }
            let conversationID = conversation.id.value.uuidString.lowercased()
            if selectedConversation[botID] == conversationID { selectedIsVisible = true }
            var row: [String: Any] = [
                "id": conversation.id.value.uuidString.lowercased(),
                "title": conversation.title,
                "bot_id": botID,
                "updated_at": conversation.updatedAt.timeIntervalSince1970,
            ]
            if row["id"] as? String == inboxID {
                row["kind"] = "titio_inbox"
            }
            if let pin {
                row["context_key"] = pin.context.storageKey
                row["context_version"] = pin.contextVersion
                row["policy_revision"] = pin.policyRevision
                row["host_id"] = pin.hostID
            }
            if let identity = liveConversationIdentity(
                botID: botID,
                conversationID: conversationID,
                storedThreadID: conversation.linkedAgentThreadID
            ) {
                row["linked_agent_thread_id"] = identity.threadID
                row["run_id"] = identity.runID
            } else if let threadID = conversation.linkedAgentThreadID {
                row["linked_agent_thread_id"] = threadID.value.uuidString.lowercased()
            }
            if let threadID = conversation.linkedAgentThreadID {
                let placement = try AgentThreadRepository(db: db).guestPlacement(of: threadID)
                let destination = try placement?.executionTarget == .mac ? BotExecutionDestination.mac
                    : (store.threadExecutionDestination(threadID) ?? store.executionDestination(botID: bot.id))
                row["execution_destination"] = destination.storageValue
            }
            if let routing = onConversationRouting?(conversation) {
                row["desk_routing"] = routing
            }
            return row
        }
        var result: [String: Any] = ["conversations": rows]
        if let taskReadback { result["task"] = taskReadback }
        if selectedIsVisible, let selected = selectedConversation[botID] { result["selected_id"] = selected }
        return result
    }

    private func routineList(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        let rows = try store.listRoutines(botID: bot.id).map { encodeRoutine($0) }
        return ["routines": rows]
    }

    private func filesList(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hostID = try requireFileHost(params: params, botID: botID)
        let root = filesLocation[botID] ?? "bot_home"
        let currentGeneration = fileGeneration(botID: botID, root: root)
        let paths = try listDiskPaths(bot: bot, root: root)
        let rootEntry = mintFileGrant(hostID: hostID, botID: botID, root: root, path: "", kind: "root")
        let entries = paths.map { mintFileGrant(hostID: hostID, botID: botID, root: root, path: $0, kind: "file") }
        persistSidecar()
        return [
            "bot_id": botID,
            "host_id": hostID,
            "root": root,
            "generation": currentGeneration,
            "root_cas": fileCASValue(botID: botID, root: root),
            "root_handle": rootEntry["handle"] as Any,
            "entries": entries,
            "security": fileSecurity(),
        ]
    }

    private func browserState(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        return try authoritativeBrowserState(bot: bot, hostID: string(params, "host_id"))
    }

    private func guestState(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hostID = try requireGuestHost(params)
        var state: [String: Any]
        let destination = try store.executionDestination(botID: bot.id).storageValue
        if let existing = guest[botID], existing["execution_destination"] as? String == destination {
            guard existing["host_id"] as? String == hostID else { throw Error.guestConflict }
            state = existing
        } else {
            state = makeStoppedGuestState(botID: botID, hostID: hostID)
            guest[botID] = state
            persistSidecar()
        }
        // Live, never stored: control is in-memory and a relaunch hands it back to the bot.
        state["controlled_by_user"] = computerControl.isControlledByUser(bot.id)
        return state
    }

    private func receiptStatus(params: [String: Any]) -> [String: Any] {
        let requestID = string(params, "client_request_id") ?? ""
        guard var stored = receipts[requestID] else {
            return ["status": Status.unknown.rawValue, "request_id": requestID]
        }
        // The stored bot.send receipt proves admission only. Report the run's
        // durable end on the returned copy so a client that missed the live
        // terminal event can settle. `receipts` itself is not changed.
        if stored["status"] as? String == Status.completed.rawValue,
           var readback = stored["readback"] as? [String: Any],
           readback["enqueued"] as? Bool == false,
           let runID = readback["run_id"] as? String,
           let terminal = terminalRunStatus(runID: runID) {
            readback["run_outcome"] = terminal.status
            if let finishedAt = terminal.finishedAt { readback["run_finished_at"] = finishedAt }
            stored["readback"] = readback
        }
        return stored
    }

    private func peerReceiptStatus(params: [String: Any]) -> [String: Any] {
        let requestID = string(params, "client_request_id") ?? ""
        return peerReceipts[requestID] ?? ["status": Status.unknown.rawValue, "request_id": requestID]
    }

    // MARK: - Mutations

    private func mutate(name: String, params: [String: Any], now: Date) throws -> [String: Any] {
        let requestID = string(params, "client_request_id")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requestID.isEmpty else { throw Error.missingRequest }
        let claim = try receiptClaim(name: name, params: params)
        if let existing = receipts[requestID] {
            guard let existingClaim = receiptClaims[requestID] else {
                throw Error(code: -32092, message: "Legacy receipt cannot be verified for idempotent replay.")
            }
            guard existingClaim == claim else {
                throw Error(code: -32093, message: "client_request_id was reused with different mutation parameters.")
            }
            return existing
        }
        if name == "conversation.enqueue" {
            let oldReceipts = receipts
            let oldClaims = receiptClaims
            let oldPersistedSidecarJSON = persistedSidecarJSON
            do {
                return try db.transaction {
                    receipts = oldReceipts
                    receiptClaims = oldClaims
                    persistedSidecarJSON = oldPersistedSidecarJSON
                    guard let context = parseContext(params),
                          let (hostID, botID) = contextIdentity(params),
                          let revision = integer(params["policy_revision"]), revision > 0,
                          try store.authorizes(hostID: hostID, botID: botID, context: context, action: .send, policyRevision: revision) else {
                        throw Error(code: -32084, message: "Bot context authority is not active for this request.")
                    }
                    let result = try perform(name: name, params: params, requestID: requestID, now: now)
                    receipts[requestID] = result
                    receiptClaims[requestID] = claim
                    guard persistSidecar(withinTransaction: true).isEmpty else { throw Error.invalidParams }
                    return result
                }
            } catch {
                receipts = oldReceipts
                receiptClaims = oldClaims
                persistedSidecarJSON = oldPersistedSidecarJSON
                throw error
            }
        }
        let result: [String: Any]
        do {
            result = try perform(name: name, params: params, requestID: requestID, now: now)
        } catch let error as Error {
            let failed = receipt(
                requestID: requestID,
                status: .failed,
                botID: string(params, "bot_id"),
                // Remote mutations answer with this failed receipt, not a
                // JSON-RPC error, so the code (e.g. -32080 conversation gone
                // vs -32084 grant mismatch) must travel in the readback.
                readback: ["error": error.message, "error_code": error.code]
            )
            receipts[requestID] = failed
            receiptClaims[requestID] = claim
            persistSidecar()
            throw error
        }
        receipts[requestID] = result
        receiptClaims[requestID] = claim
        persistSidecar()
        return result
    }

    private func receiptClaim(name: String, params: [String: Any]) throws -> [String: String] {
        var business = params
        business.removeValue(forKey: "client_request_id")
        guard JSONSerialization.isValidJSONObject(business) else { throw Error.invalidParams }
        let data = try JSONSerialization.data(
            withJSONObject: business,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        if name == "conversation.enqueue" {
            return ["method": name, "params_sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        guard let canonical = String(data: data, encoding: .utf8) else { throw Error.invalidParams }
        return ["method": name, "params": canonical]
    }

    private func perform(name: String, params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        switch name {
        case "vm.save":
            try requireControlPlane()
            let workspaceID = try virtualMachineWorkspace(params)
            let machineID: UUID?
            if let raw = string(params, "vm_id") {
                guard let id = UUID(uuidString: raw) else { throw Error.invalidParams }
                machineID = id
            } else { machineID = nil }
            guard let name = string(params, "name") else { throw Error.invalidParams }
            do {
                let machine = try store.saveVirtualMachine(id: machineID, name: name, workspaceID: workspaceID)
                return receipt(requestID: requestID, status: .completed, botID: nil, readback: encodeVirtualMachine(machine))
            } catch let error as BotStoreError { throw Error(code: -32602, message: error.description) }
        case "execution.set":
            let bot = try requireBot(params)
            guard let value = string(params, "execution_destination"),
                  let destination = BotExecutionDestination(storageValue: value) else { throw Error.invalidParams }
            if let id = destination.virtualMachineID, let workspace = try store.virtualMachine(id: id)?.workspaceID,
               onVMWorkspaceExists?(workspace) != true {
                throw Error(code: -32602, message: "This VM's workspace is no longer available.")
            }
            do {
                _ = try store.setExecutionDestination(destination, botID: bot.id)
                return receipt(requestID: requestID, status: .completed, botID: id(bot),
                    readback: try encodeBot(store.get(id: bot.id) ?? bot))
            } catch let error as BotStoreError { throw Error(code: -32602, message: error.description) }
        case "context.grant", "context.revoke":
            let (hostID, botID, context) = try contextTarget(params)
            guard let revision = integer(params["policy_revision"]) else { throw Error.invalidParams }
            let binding: BotContextBinding
            do {
                if name == "context.grant" {
                    guard let rawActions = params["actions"] as? [String], !rawActions.isEmpty,
                          rawActions.count == Set(rawActions).count,
                          let actions = Optional(Set(rawActions.compactMap(BotContextAction.init(rawValue:)))),
                          actions.count == rawActions.count else { throw Error.invalidParams }
                    binding = try store.grantContext(hostID: hostID, botID: botID, context: context, actions: actions, expectedRevision: revision)
                } else {
                    binding = try store.revokeContext(hostID: hostID, botID: botID, context: context, expectedRevision: revision)
                }
            } catch let error as BotStoreError {
                throw Error(code: -32602, message: error.description)
            }
            var readback = encodeContextBinding(binding)
            readback["run_cancellation_requested"] = onContextBindingChanged?(binding) ?? false
            return receipt(requestID: requestID, status: .completed, botID: botID.value.uuidString.lowercased(), readback: readback)
        case "create":
            return try create(params: params, requestID: requestID, now: now)
        case "discard_new":
            return try discardNew(params: params, requestID: requestID, now: now)
        case "save":
            return try save(params: params, requestID: requestID, now: now)
        case "delete":
            return try deleteBot(params: params, requestID: requestID, now: now)
        case "set_pinned":
            return try setPinned(params: params, requestID: requestID, now: now)
        case "set_hidden":
            return try setHidden(params: params, requestID: requestID, now: now)
        case "reorder":
            return try reorder(params: params, requestID: requestID)
        case "duplicate":
            return try duplicate(params: params, requestID: requestID, now: now)
        case "settings.set":
            return try settingsSet(params: params, requestID: requestID)
        case "send":
            return try send(params: params, requestID: requestID, now: now)
        case "queue.remove":
            return try queueRemove(params: params, requestID: requestID)
        case "queue.update":
            return try queueUpdate(params: params, requestID: requestID)
        case "queue.reorder":
            return try queueReorder(params: params, requestID: requestID)
        case "queue.force_now":
            return try queueForceNow(params: params, requestID: requestID)
        case "stop", "force_stop":
            return try stop(params: params, requestID: requestID, force: name == "force_stop", now: now)
        case "conversation.create":
            return try conversationCreate(params: params, requestID: requestID)
        case "conversation.enqueue":
            return try conversationEnqueue(params: params, requestID: requestID)
        case "conversation.select":
            return try conversationSelect(params: params, requestID: requestID)
        case "conversation.clear_all":
            return try conversationClearAll(params: params, requestID: requestID)
        case "routine.create", "routine.update":
            if name == "routine.update", string(params, "routine_id").flatMap(UUID.init) == nil {
                throw Error.invalidParams
            }
            return try routineUpsert(params: params, requestID: requestID, now: now)
        case "routine.enable":
            return try routineEnable(params: params, requestID: requestID, now: now)
        case "routine.run":
            return try routineRun(params: params, requestID: requestID, now: now)
        case "routine.delete":
            return try routineDelete(params: params, requestID: requestID)
        case "attachment.stage":
            return try attachmentStage(params: params, requestID: requestID)
        case "attachment.import":
            return try attachmentImport(params: params, requestID: requestID)
        case "attachment.remove":
            return try attachmentRemove(params: params, requestID: requestID)
        case "files.mutate":
            return try filesMutate(params: params, requestID: requestID)
        case "files.open_tab", "files.split":
            return try filesOpen(params: params, requestID: requestID, split: name == "files.split")
        case "files.location.set":
            return try filesLocationSet(params: params, requestID: requestID)
        case "browser.action":
            return try browserAction(params: params, requestID: requestID)
        case "link.open":
            return try linkOpen(params: params, requestID: requestID)
        case "guest.input", "guest.start", "guest.stop", "guest.rebuild", "guest.revoke":
            return try guestCommand(name: name, params: params, requestID: requestID)
        case "guest.control":
            return try guestControl(params: params, requestID: requestID)
        case "docker.clear":
            return try dockerClear(params: params, requestID: requestID)
        case "notify.set":
            return try notifySet(params: params, requestID: requestID, now: now)
        case "verbosity.set":
            return try verbositySet(params: params, requestID: requestID, now: now)
        case "caveman.set":
            return try cavemanSet(params: params, requestID: requestID, now: now)
        case "factory_reset":
            return try factoryReset(params: params, requestID: requestID, now: now)
        case "notice.reply":
            return try noticeReply(params: params, requestID: requestID)
        case "notice.act":
            return try noticeAct(params: params, requestID: requestID)
        case "notice.read":
            return try noticeRead(params: params, requestID: requestID)
        case "notice.clear":
            return try noticeClear(params: params, requestID: requestID)
        case "desktop.set":
            return try desktopSet(params: params, requestID: requestID)
        case "avatar.set":
            return try avatarSet(params: params, requestID: requestID, now: now)
        case "handle.set":
            return try handleSet(params: params, requestID: requestID)
        case "soul.set":
            return try soulSet(params: params, requestID: requestID)
        case "routing.set":
            return try routingSet(params: params, requestID: requestID)
        case "attention.ack":
            return try attentionAck(params: params, requestID: requestID)
        case "scheduler.tick":
            return try schedulerTick(params: params, now: now, requestID: requestID)
        case "peer.ask":
            return try peerAsk(params: params, requestID: requestID)
        case "self_config":
            return try selfConfig(params: params, requestID: requestID)
        default:
            throw Error.invalidParams
        }
    }

    private func create(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        try requireControlPlane()
        let live = try store.list()
        if live.count >= Self.liveAccountCap { throw Error.cap }
        let name = string(params, "name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "New Agent"
        let bot = try store.create(
            name: name.isEmpty ? "New Agent" : name,
            title: string(params, "title") ?? "",
            description: string(params, "description") ?? "",
            handle: string(params, "handle"),
            soul: string(params, "soul") ?? "",
            workspaceID: try virtualMachineWorkspace(params),
            now: now
        )
        unpublished.insert(id(bot))
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: try encodeBot(bot, extra: ["unpublished": true, "pre": "UNPUBLISHED_NEW"]))
    }

    private func discardNew(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        guard unpublished.contains(botID) else { throw Error.invalidParams }
        return try deleteAndClean(
            bot: bot,
            requestID: requestID,
            now: now,
            extraReadback: ["unpublished": false]
        )
    }

    private func save(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        try requireControlPlane()
        let bot = try requireBot(params)
        let botID = id(bot)
        let pre = unpublished.contains(botID) ? "UNPUBLISHED_NEW" : "EXISTING"
        if let name = string(params, "name") {
            _ = try store.updateProfile(
                id: bot.id,
                name: name,
                title: string(params, "title") ?? bot.title,
                description: string(params, "description") ?? bot.description,
                now: now
            )
        }
        unpublished.remove(botID)
        let fresh = try store.get(id: bot.id) ?? bot
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: try encodeBot(fresh, extra: ["unpublished": false, "pre": pre]))
    }

    private func deleteBot(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        if string(params, "confirm") != "delete" {
            return receipt(requestID: requestID, status: .accepted, botID: string(params, "bot_id"), readback: ["confirm_required": true])
        }
        let bot = try requireBot(params)
        return try deleteAndClean(bot: bot, requestID: requestID, now: now)
    }

    private func deleteAndClean(
        bot: BotDefinition,
        requestID: String,
        now: Date,
        extraReadback: [String: Any] = [:]
    ) throws -> [String: Any] {
        let botID = id(bot)
        let quarantined = quarantineBotState(botID: botID)
        // A Docker bot's container is also started by its runs (desk and
        // group turns), not only by `bot.guest.start`, so the remote guest
        // state alone does not say whether one exists.
        let ownsGuestRuntime = quarantined.guest != nil
            || ((try? bot.currentRevisionID.flatMap { try store.getRevision(id: $0) }) ?? nil)?
                .desktopKind == .dockerDesktop
        do {
            try store.delete(id: bot.id, now: now)
        } catch {
            restoreQuarantinedBotState(quarantined, botID: botID)
            throw error
        }
        try? store.deleteQueuedFollowUps(botID: bot.id)
        BotComputerControl.shared.forget(bot.id)
        do {
            // Another store instance: the router's re-reads the file it replaced.
            try ManualActionRequestStore(appSupportDirectory: appSupport).closeAll(botID: bot.id)
                .forEach(ManualActionRequestStore.postStateChanged)
        } catch {
            NSLog("RemoteCode: manual actions of deleted bot could not be closed: \(error)")
        }

        var residuals: [String] = []
        if ownsGuestRuntime {
            if let onDockerClear {
                do {
                    try onDockerClear(bot.id)
                } catch {
                    residuals.append("container_runtime")
                }
            } else {
                residuals.append("container_runtime")
            }
        }
        do {
            try BotHome.wipe(appSupportDirectory: appSupport, botID: bot.id)
        } catch {
            residuals.append("bot_home")
        }
        do {
            try BotGuestHome.wipe(appSupport: appSupport, botID: bot.id)
        } catch {
            residuals.append("guest_home")
        }
        residuals.append(contentsOf: persistSidecar().map { "sidecar:\($0)" })
        residuals.sort()

        var readback: [String: Any] = [
            "deleted": true,
            "cleanup_complete": residuals.isEmpty,
            "cleanup_residuals": residuals,
        ]
        readback.merge(extraReadback) { _, new in new }
        return receipt(
            requestID: requestID,
            status: residuals.isEmpty ? .completed : .partial,
            botID: botID,
            readback: readback
        )
    }

    private func quarantineBotState(botID: String) -> QuarantinedBotState {
        let botAttachments = attachments.filter { $0.value["bot_id"] as? String == botID }
        let botFiles = files.filter { $0.value["bot_id"] as? String == botID }
        let botFileHandles = Set(botFiles.keys)
        let keyPrefix = "\(botID)|"
        let botGenerations = fileGenerations.filter { $0.key.hasPrefix(keyPrefix) }
        let botCAS = fileCAS.filter { $0.key.hasPrefix(keyPrefix) }
        let routing = routingPref[botID]
        let routingReceiptID = routing?["routing_receipt_id"] as? String
        let quarantined = QuarantinedBotState(
            wasUnpublished: unpublished.contains(botID),
            attachments: botAttachments,
            files: botFiles,
            fileHandles: botFileHandles,
            filesLocation: filesLocation[botID],
            fileGenerations: botGenerations,
            fileCAS: botCAS,
            fileHost: fileHosts[botID],
            browser: browser[botID],
            guest: guest[botID],
            liveRun: liveRuns[botID],
            attention: attention[botID],
            routing: routing,
            routingReceiptWasConsumed: routingReceiptID.map(consumedRoutingReceipts.contains) ?? false,
            selectedConversation: selectedConversation[botID]
        )

        unpublished.remove(botID)
        for key in botAttachments.keys { attachments.removeValue(forKey: key) }
        for key in botFiles.keys { files.removeValue(forKey: key) }
        processIssuedFileHandles.subtract(botFileHandles)
        filesLocation.removeValue(forKey: botID)
        for key in botGenerations.keys { fileGenerations.removeValue(forKey: key) }
        for key in botCAS.keys { fileCAS.removeValue(forKey: key) }
        fileHosts.removeValue(forKey: botID)
        browser.removeValue(forKey: botID)
        guest.removeValue(forKey: botID)
        liveRuns.removeValue(forKey: botID)
        attention.removeValue(forKey: botID)
        selectedConversation.removeValue(forKey: botID)
        routingPref.removeValue(forKey: botID)
        if let routingReceiptID { consumedRoutingReceipts.remove(routingReceiptID) }
        return quarantined
    }

    private func restoreQuarantinedBotState(_ state: QuarantinedBotState, botID: String) {
        if state.wasUnpublished { unpublished.insert(botID) }
        attachments.merge(state.attachments) { _, restored in restored }
        files.merge(state.files) { _, restored in restored }
        processIssuedFileHandles.formUnion(state.fileHandles)
        if let value = state.filesLocation { filesLocation[botID] = value }
        fileGenerations.merge(state.fileGenerations) { _, restored in restored }
        fileCAS.merge(state.fileCAS) { _, restored in restored }
        if let value = state.fileHost { fileHosts[botID] = value }
        if let value = state.browser { browser[botID] = value }
        if let value = state.guest { guest[botID] = value }
        if let value = state.liveRun { liveRuns[botID] = value }
        if let value = state.attention { attention[botID] = value }
        if let value = state.routing {
            routingPref[botID] = value
            if state.routingReceiptWasConsumed,
               let receiptID = value["routing_receipt_id"] as? String {
                consumedRoutingReceipts.insert(receiptID)
            }
        }
        if let value = state.selectedConversation { selectedConversation[botID] = value }
    }

    private func setPinned(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let pinned = bool(params, "pinned") ?? false
        try store.setPinned(id: bot.id, pinned: pinned, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["pinned": pinned])
    }

    private func reorder(params: [String: Any], requestID: String) throws -> [String: Any] {
        guard let raw = params["ordered_bot_ids"] as? [String] else { throw Error.invalidParams }
        var ids: [BotID] = []
        for value in raw {
            guard let uuid = UUID(uuidString: value) else { throw Error.invalidParams }
            ids.append(BotID(uuid))
        }
        do { try store.reorder(orderedIDs: ids) } catch BotStoreError.notFound { throw Error.notFound }
        var result = receipt(requestID: requestID, status: .completed, botID: nil, readback: ["ok": true])
        result["ok"] = true
        return result
    }
    private func setHidden(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let hidden = bool(params, "hidden") ?? false
        try store.setHidden(id: bot.id, hidden: hidden, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["hidden": hidden])
    }

    private func duplicate(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        try requireControlPlane()
        if try store.list().count >= Self.liveAccountCap { throw Error.cap }
        let bot = try requireBot(params)
        let copy = try store.duplicate(id: bot.id, now: now)
        let routines = try store.listRoutines(botID: copy.id)
        let specs = routines.map { $0.definition.scheduleSpecJSON }
        let copiedRouting: [String: Any]?
        if var routing = routingPref[id(bot)] {
            routing.removeValue(forKey: "effective")
            routing["routing_receipt_id"] = UUID().uuidString.lowercased()
            routing["bot_id"] = id(copy)
            routing["effective"] = routing
            routingPref[id(copy)] = routing
            copiedRouting = routing
        } else {
            copiedRouting = nil
        }
        var duplicateReadback = try encodeBot(copy, extra: [
            "source_bot_id": id(bot),
            "schedule_spec_jsons": specs,
        ])
        if let copiedRouting { duplicateReadback["routing"] = copiedRouting }
        return receipt(
            requestID: requestID,
            status: .completed,
            botID: id(copy),
            readback: duplicateReadback
        )
    }

    private func settingsSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let key = string(params, "key") ?? ""
        let value = bool(params, "value")
        guard let value else { throw Error.invalidParams }
        var current = settings.load()
        switch key {
        case "control_plane": current.botsControlPlaneEnabled = value
        case "memory": current.botsMemoryEnabled = value
        case "effects": current.botsEffectsEnabled = value
        case "channels": current.botsChannelsEnabled = value
        case "autonomy": current.botsAutonomyEnabled = value
        default: throw Error.invalidParams
        }
        settings.save(current)
        let pair = effectiveSettings()
        return receipt(
            requestID: requestID,
            status: .completed,
            botID: nil,
            readback: [
                "raw": pair.raw,
                "effective": pair.effective,
                "key": key,
            ]
        )
    }

    private func send(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        try requireControlPlane()
        let bot = try requireBot(params)
        let text = string(params, "text")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw Error.invalidParams }
        let botID = id(bot)
        let hostID = string(params, "host_id") ?? ""
        let requestedConversationID = string(params, "conversation_id")
        let targetConversationID = requestedConversationID ?? selectedConversation[botID]
        if let targetConversationID, let uuid = UUID(uuidString: targetConversationID),
           let pin = try store.conversationContextPin(conversationID: BotConversationID(uuid)) {
            guard pin.botID == bot.id,
                  try store.authorizes(hostID: pin.hostID, botID: pin.botID, context: pin.context, action: .send, policyRevision: pin.policyRevision) else {
                throw Error(code: -32602, message: "Context resource unavailable.")
            }
        }
        let conversation: BotConversationID?
        if let requestedConversationID, !requestedConversationID.isEmpty {
            guard let uuid = UUID(uuidString: requestedConversationID),
                  let stored = try store.conversation(id: BotConversationID(uuid)) else {
                throw Error.conversationGone
            }
            // Group member conversations are reached only through the group RPCs.
            guard stored.botID == bot.id, stored.groupID == nil else { throw Error.crossTarget }
            conversation = stored.id
        } else {
            conversation = nil
        }
        let routing = try effectiveRouting(
            botID: botID,
            params: params
        )
        // 1.6: when conversation_id is absent but we have a selected
        // conversation on the host, use that target instead of creating a
        // duplicate conversation. The authoritative send path still
        // validates via BotsWindow.enqueueHostMessage's targetConversationID.
        let effectiveConversationID = targetConversationID
        let attachmentIDs = stringArray(params, "attachment_ids")
        guard Set(attachmentIDs).count == attachmentIDs.count else { throw Error.invalidParams }
        guard attachmentIDs.isEmpty || requestedConversationID != nil else {
            throw Error.crossTarget
        }
        var boundGrants: [[String: Any]] = []
        var boundAttachments: [AgentAttachment] = []
        for attachmentID in attachmentIDs {
            guard let grant = attachments[attachmentID],
                  grant["bot_id"] as? String == botID,
                  let conversationID = effectiveConversationID,
                  grant["conversation_id"] as? String == conversationID,
                  let referenceID = grant["attachment_id"] as? String,
                  !referenceID.isEmpty,
                  let filename = grant["filename"] as? String,
                  !filename.isEmpty,
                  let rawKind = grant["kind"] as? String,
                  let kind = AgentAttachmentKind(rawValue: rawKind),
                  let digest = grant["digest"] as? String,
                  let size = grant["size"] as? Int,
                  (grant["consumed"] as? Bool) != true else {
                throw Error.crossTarget
            }
            boundGrants.append(grant)
            boundAttachments.append(AgentAttachment(
                id: referenceID,
                path: "",
                displayName: filename,
                kind: kind,
                mimeType: grant["mime_type"] as? String,
                sha256: digest,
                sizeBytes: size
            ))
        }
        let live = onHasLiveRun?(bot.id) ?? (liveRuns[botID] != nil)
        // Production delegates live-run queueing to BotsViewModel so the
        // receipt can bind the authoritative conversation/thread/run. The
        // standalone path remains for persistence-level callers without a UI
        // runtime hook.
        if live, onSend == nil {
            var payload: [String: Any] = ["attachments": boundGrants]
            if let conversationID = requestedConversationID ?? selectedConversation[botID] {
                payload["conversation_id"] = conversationID
            }
            if let routing { payload["routing"] = routing }
            payload["client_request_id"] = requestID
            let payloadJSON = jsonString(payload) ?? "{}"
            let stored = try store.enqueueQueuedFollowUp(
                BotQueuedFollowUpRecord(
                    botID: bot.id,
                    conversationID: requestedConversationID ?? selectedConversation[botID],
                    text: text,
                    payloadJSON: payloadJSON,
                    createdAt: now
                )
            )
            consumeAttachments(attachmentIDs)
            if let routingReceiptID = routing?["routing_receipt_id"] as? String {
                consumedRoutingReceipts.insert(routingReceiptID)
            }
            let conversationID = requestedConversationID ?? selectedConversation[botID]
            let runID = liveRuns[botID]?["run_id"] as? String ?? ""
            return runtimeReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: botID,
                conversationID: conversationID,
                runID: runID,
                readback: [
                    "enqueued": true,
                    "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
                    "id": stored.id,
                    "routing_receipt_id": routing?["routing_receipt_id"] ?? NSNull(),
                    "effective_routing": routing ?? NSNull(),
                ]
            )
        }
        let authoritativeSend: [String: Any]
        if let onSend {
            let clientCapabilities = Set((params["client_capabilities"] as? [Any] ?? []).compactMap { $0 as? String })
            authoritativeSend = try onSend(bot.id, text, conversation, boundAttachments, routing, clientCapabilities)
            // Titio's inbox took the text for a notice (an armed "Reply here"
            // or an old build's option text, hub spec §7): no run starts, so
            // no live run or working attention is registered.
            if authoritativeSend["host_consumed"] as? Bool == true,
               authoritativeSend["bot_id"] as? String == botID {
                consumeAttachments(attachmentIDs)
                // The full send identity, so a paired client decodes this as
                // a delivered send (`BotSend.Result.Disposition.hostConsumed`)
                // instead of a failed one it would put back in the composer.
                var readback = authoritativeSend
                readback["host_id"] = hostID
                readback["bot_id"] = botID
                readback["request_id"] = requestID
                readback["client_request_id"] = requestID
                var consumed = receipt(requestID: requestID, status: .completed, botID: botID, readback: readback)
                consumed["host_id"] = hostID
                consumed["client_request_id"] = requestID
                return consumed
            }
            guard authoritativeSend["bot_id"] as? String == botID,
                  let admittedConversationID = authoritativeSend["conversation_id"] as? String,
                  let admittedConversationUUID = UUID(uuidString: admittedConversationID),
                  let admittedConversation = try store.conversation(
                    id: BotConversationID(admittedConversationUUID)
                  ),
                  admittedConversation.botID == bot.id,
                  let admittedRunID = authoritativeSend["run_id"] as? String,
                  !admittedRunID.isEmpty,
                  let admittedThreadID = authoritativeSend["thread_id"] as? String,
                  !admittedThreadID.isEmpty,
                  authoritativeSend["queued_follow_up"] as? Bool != nil else {
                throw Error.crossTarget
            }
        } else {
            authoritativeSend = [
                "bot_id": botID,
                "conversation_id": (requestedConversationID ?? selectedConversation[botID])
                    .map { $0 as Any } ?? NSNull(),
                "run_id": UUID().uuidString.lowercased(),
                "enqueued": false,
            ]
        }
        consumeAttachments(attachmentIDs)
        // The route that ran: the host's resolved route over the stored
        // receipt route, so a receipt-bound send keeps `routing_receipt_id`,
        // `host_id` and `bot_id` and both paths report one shape.
        let ranRouting = authoritativeSend["effective_routing"] as? [String: Any]
        let effectiveRouting: Any
        if let routing {
            effectiveRouting = routing.merging(ranRouting ?? [:]) { _, ran in ran }
        } else {
            effectiveRouting = ranRouting ?? NSNull()
        }
        let runID = authoritativeSend["run_id"] as? String
            ?? UUID().uuidString.lowercased()
        let conversationID = authoritativeSend["conversation_id"] as? String
            ?? requestedConversationID
            ?? selectedConversation[botID]
        if let conversationID {
            selectedConversation[botID] = conversationID
        }
        if authoritativeSend["queued_follow_up"] as? Bool == true {
            return runtimeReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: botID,
                conversationID: conversationID,
                runID: runID,
                readback: [
                    "enqueued": true,
                    "id": authoritativeSend["id"] ?? NSNull(),
                    "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
                    "routing_receipt_id": routing?["routing_receipt_id"] ?? NSNull(),
                    "effective_routing": effectiveRouting,
                ]
            )
        }
        var liveRun: [String: Any] = [
            "bot_id": botID,
            "host_id": hostID,
            "request_id": requestID,
            "client_request_id": requestID,
            "status": "working",
            "text": text,
            "started_at": now.timeIntervalSince1970,
            "run_id": runID,
            "conversation_id": conversationID ?? NSNull(),
            "routing": effectiveRouting,
        ]
        if let threadID = authoritativeSend["thread_id"] as? String, !threadID.isEmpty {
            liveRun["thread_id"] = threadID
        }
        liveRuns[botID] = liveRun
        attention[botID] = canonicalAttentionItem([
            "id": UUID().uuidString.lowercased(),
            "bot_id": botID,
            "conversation_id": conversationID ?? NSNull(),
            "run_id": runID,
            "state": "working",
            "finished_at": NSNull(),
            "ownership": "primary",
            "primary": true,
            "delegated": false,
            "title": bot.name,
            "detail": text,
            "source": "bot",
        ], hostID: string(params, "host_id"))
        if let routingReceiptID = routing?["routing_receipt_id"] as? String {
            consumedRoutingReceipts.insert(routingReceiptID)
        }
        return runtimeReceipt(
            requestID: requestID,
            hostID: hostID,
            botID: botID,
            conversationID: conversationID,
            runID: runID,
            readback: [
                "enqueued": false,
                "run": liveRuns[botID] as Any,
                "workspace": NSNull(),
                "routing_receipt_id": routing?["routing_receipt_id"] ?? NSNull(),
                "effective_routing": effectiveRouting,
            ]
        )
    }

    private func queueRemove(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let itemID = string(params, "id") ?? ""
        let rows = try store.listQueuedFollowUps(botID: bot.id)
        guard rows.contains(where: { $0.id == itemID }) else { throw Error.invalidParams }
        try store.removeQueuedFollowUp(botID: bot.id, id: itemID)
        return try queueReceipt(bot: bot, requestID: requestID)
    }

    private func queueUpdate(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let itemID = string(params, "id") ?? ""
        let text = string(params, "text")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw Error.invalidParams }
        var rows = try store.listQueuedFollowUps(botID: bot.id)
        guard let index = rows.firstIndex(where: { $0.id == itemID }) else { throw Error.invalidParams }
        rows[index].text = text
        try store.replaceQueuedFollowUps(botID: bot.id, items: rows)
        return try queueReceipt(bot: bot, requestID: requestID)
    }

    private func queueReorder(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let itemID = string(params, "id") ?? ""
        guard let requestedPosition = int(params, "position"), requestedPosition >= 0 else {
            throw Error.invalidParams
        }
        var rows = try store.listQueuedFollowUps(botID: bot.id)
        guard let source = rows.firstIndex(where: { $0.id == itemID }) else { throw Error.invalidParams }
        let row = rows.remove(at: source)
        rows.insert(row, at: min(requestedPosition, rows.count))
        try store.replaceQueuedFollowUps(botID: bot.id, items: rows)
        return try queueReceipt(bot: bot, requestID: requestID)
    }

    private func queueForceNow(params: [String: Any], requestID: String) throws -> [String: Any] {
        try requireControlPlane()
        let bot = try requireBot(params)
        let itemID = string(params, "id") ?? ""
        var rows = try store.listQueuedFollowUps(botID: bot.id)
        guard let source = rows.firstIndex(where: { $0.id == itemID }) else { throw Error.invalidParams }
        let originalRows = rows
        let row = rows.remove(at: source)
        rows.insert(row, at: 0)
        try store.replaceQueuedFollowUps(botID: bot.id, items: rows)
        let runtimeReadback: [String: Any]
        do {
            runtimeReadback = try onForceQueuedFollowUp?(bot.id, itemID)
                ?? ["force_status": "queued"]
        } catch {
            do {
                try store.replaceQueuedFollowUps(botID: bot.id, items: originalRows)
            } catch let rollbackError {
                // The forced order stays in the queue after a failed force; the
                // caller only sees the original error, so report the mismatch.
                botRemoteControlLog.error(
                    "bot.queue.force_now_rollback_failed bot=\(bot.id.value.uuidString, privacy: .public) item=\(itemID, privacy: .public) error=\(String(describing: rollbackError), privacy: .public)"
                )
            }
            throw error
        }
        var extra = runtimeReadback
        extra["queue"] = encodeQueue(try store.listQueuedFollowUps(botID: bot.id))
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: extra)
    }

    private func queueReceipt(bot: BotDefinition, requestID: String) throws -> [String: Any] {
        receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
        ])
    }

    private func stop(
        params: [String: Any],
        requestID: String,
        force: Bool,
        now: Date
    ) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let requestedConversationID = string(params, "conversation_id")
        let requestedRunID = string(params, "run_id")
        let requestedRunRequestID = string(params, "run_request_id")
        let run = liveRuns[botID]
        if requestedConversationID != nil || requestedRunID != nil || requestedRunRequestID != nil {
            guard let requestedRunID,
                  let requestedConversationID,
                  let run,
                  run["bot_id"] as? String == botID,
                  run["conversation_id"] as? String == requestedConversationID,
                  run["run_id"] as? String == requestedRunID,
                  requestedRunRequestID.map({ run["request_id"] as? String == $0 }) ?? true else {
                throw Error.crossTarget
            }
        }
        let hadLive = onHasLiveRun?(bot.id) ?? (liveRuns[botID] != nil)
        let liveStop = onStopRun != nil
        onStopRun?(
            bot.id,
            requestedConversationID,
            requestedRunID,
            requestedRunRequestID,
            force,
            requestID
        )
        liveRuns[botID] = nil
        var drained: [String: Any]?
        if !liveStop, let next = try store.dequeueQueuedFollowUp(botID: bot.id) {
            liveRuns[botID] = [
                "bot_id": botID,
                "status": "working",
                "text": next.text,
                "from_queue_id": next.id,
            ]
            drained = encodeQueue([next]).first
        }
        let item = canonicalAttentionItem([
            "id": attention[botID]?["id"] ?? UUID().uuidString.lowercased(),
            "bot_id": botID,
            "conversation_id": run?["conversation_id"] ?? NSNull(),
            "run_id": run?["run_id"] ?? NSNull(),
            "state": drained == nil ? "finished" : "working",
            "finished_at": drained == nil
                ? now.timeIntervalSince1970 as Any
                : NSNull(),
            "ownership": "primary",
            "primary": true,
            "delegated": false,
            "title": bot.name,
            "detail": drained == nil ? "Finished" : "Running queued follow-up",
            "source": "bot",
        ], hostID: string(params, "host_id"))
        attention[botID] = item
        let terminal = hadLive || run != nil
        let notification = drained == nil && !liveStop && terminal
            ? try persistAttentionNotification(item, now: now)
            : nil
        var readback: [String: Any] = [
            "accepted": true,
            "force": force,
            "terminal": terminal,
            "run": run as Any,
            "drained": drained as Any,
            "queue": encodeQueue(try store.listQueuedFollowUps(botID: bot.id)),
        ]
        if let notification { readback["notification"] = notification }
        return receipt(
            requestID: requestID,
            status: liveStop ? .accepted : .completed,
            botID: botID,
            readback: readback
        )
    }

    private func conversationCreate(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let title = string(params, "title") ?? "New thread"
        if ["context_key", "context_version", "policy_revision"].contains(where: { params[$0] != nil }) {
            guard Set(params.keys).isSubset(of: ["client_request_id", "bot_id", "title", "host_id", "context_key", "context_version", "policy_revision"]),
                  let context = parseContext(params), let (hostID, contextBotID) = contextIdentity(params),
                  contextBotID == bot.id, let revision = integer(params["policy_revision"]), revision > 0,
                  bot.currentRevisionID != nil,
                  try store.authorizes(hostID: hostID, botID: bot.id, context: context, action: .read, policyRevision: revision),
                  try store.authorizes(hostID: hostID, botID: bot.id, context: context, action: .send, policyRevision: revision) else {
                throw Error(code: -32084, message: "Bot context authority is not active for this request.")
            }
            let route = routingPref[id(bot)]
            guard route?["provider"] as? String == AgentProvider.distill.rawValue,
                  let model = route?["model"] as? String,
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error(code: -32602, message: "Select an explicit Distill Main model before creating a contextual conversation.")
            }
            let workspaceID: WorkspaceID?
            switch context {
            case .general: workspaceID = nil
            case .workspace(let workspace): workspaceID = workspace
            }
            let currentRevision = try bot.currentRevisionID.flatMap { try store.getRevision(id: $0) }
            let thread = AgentThread(workspaceId: workspaceID, title: title, provider: .distill, model: model,
                                     executionTarget: BotExecutionDefault.target(for: currentRevision))
            let conversation = BotConversation(botID: bot.id, title: title, linkedAgentThreadID: thread.id)
            let pin = try store.createContextualConversation(conversation, newThread: thread, hostID: hostID, context: context, policyRevision: revision)
            selectedConversation[id(bot)] = conversation.id.value.uuidString.lowercased()
            return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
                "conversation_id": conversation.id.value.uuidString.lowercased(), "thread_id": thread.id.value.uuidString.lowercased(),
                "context_key": pin.context.storageKey, "context_version": pin.contextVersion,
                "policy_revision": pin.policyRevision, "host_id": pin.hostID, "title": conversation.title,
            ])
        }
        let conversation = BotConversation(botID: bot.id, title: title)
        try store.upsertConversation(conversation)
        selectedConversation[id(bot)] = conversation.id.value.uuidString.lowercased()
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "conversation_id": conversation.id.value.uuidString.lowercased(),
            "title": conversation.title,
        ])
    }


    private func conversationEnqueue(params: [String: Any], requestID: String) throws -> [String: Any] {
        try requireControlPlane()
        let bot = try requireBot(params)
        guard let text = params["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let context = parseContext(params), let (hostID, botID) = contextIdentity(params),
              let revision = integer(params["policy_revision"]), revision > 0,
              let conversationRaw = params["conversation_id"] as? String,
              let conversationUUID = UUID(uuidString: conversationRaw),
              let conversation = try store.conversation(id: BotConversationID(conversationUUID)),
              bot.id == botID, conversation.botID == botID, conversation.groupID == nil,
              let threadID = conversation.linkedAgentThreadID,
              let pin = try store.conversationContextPin(conversationID: conversation.id),
              pin.hostID == hostID, pin.botID == botID, pin.context == context,
              Int64(pin.contextVersion) == integer(params["context_version"]), pin.policyRevision == revision,
              let thread = try AgentThreadRepository(db: db).get(id: threadID),
              thread.actor == .bot(botID), thread.actorLockedAt != nil,
              thread.executionTarget != nil, thread.provider == .distill,
              (context == .general ? thread.workspaceId == nil : { if case .workspace(let workspace) = context { return thread.workspaceId == workspace }; return false }()),
              thread.parentThreadId == nil,
              thread.isEphemeral == false,
              try store.authorizes(hostID: hostID, botID: botID, context: context, action: .send, policyRevision: revision) else {
            throw Error(code: -32084, message: "Bot context authority is not active for this request.")
        }
        let queued = try AgentQueuedMessageRepository(db: db).enqueueWithinTransaction(
            threadId: threadID, text: text, attachments: [], interactionMode: .default
        )
        try HostDatabaseRestore.pauseQueue(kind: .agent, id: queued.id.value.uuidString, db: db)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "enqueued": true,
            "queue_id": queued.id.value.uuidString.lowercased(),
            "conversation_id": conversation.id.value.uuidString.lowercased(),
            "thread_id": threadID.value.uuidString.lowercased(),
            "host_id": hostID,
            "context_key": context.storageKey,
            "context_version": pin.contextVersion,
            "policy_revision": pin.policyRevision,
            "execution_available": false,
            "requires_user_send": true,
        ])
    }

    private func conversationSelect(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let conversationID = string(params, "conversation_id") ?? ""
        guard let uuid = UUID(uuidString: conversationID),
              let conversation = try store.conversation(id: BotConversationID(uuid)) else { throw Error.conversationGone }
        guard conversation.botID == bot.id, conversation.groupID == nil else { throw Error.crossTarget }
        let scoped = ["context_key", "context_version", "policy_revision"].contains(where: { params[$0] != nil })
        let pin = try store.conversationContextPin(conversationID: conversation.id)
        if scoped {
            guard Set(params.keys).isSubset(of: ["client_request_id", "conversation_id", "bot_id", "host_id", "context_key", "context_version", "policy_revision"]),
                  let requestedContext = parseContext(params), let hostID = string(params, "host_id"),
                  let revision = integer(params["policy_revision"]),
                  let version = integer(params["context_version"]),
                  let pin, pin.hostID == hostID, pin.botID == bot.id, pin.context == requestedContext,
                  pin.contextVersion == version, pin.policyRevision == revision else {
                throw Error(code: -32602, message: "Context resource unavailable.")
            }
        } else if pin != nil {
            throw Error(code: -32602, message: "Context resource unavailable.")
        }
        let normalizedID = conversation.id.value.uuidString.lowercased()
        selectedConversation[id(bot)] = normalizedID
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "selected_id": normalizedID,
        ])
    }

    private func conversationClearAll(params: [String: Any], requestID: String) throws -> [String: Any] {
        if string(params, "confirm") != "clear" {
            return receipt(requestID: requestID, status: .accepted, botID: string(params, "bot_id"), readback: ["confirm_required": true])
        }
        let bot = try requireBot(params)
        try store.deleteConversations(botID: bot.id)
        selectedConversation[id(bot)] = nil
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["cleared": true])
    }

    private func routineUpsert(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let existingID = string(params, "routine_id").flatMap(UUID.init).map(BotRoutineID.init)
        let existing: BotRoutineDefinition?
        if let existingID {
            guard let routine = try store.listRoutines(botID: bot.id).first(where: {
                $0.definition.id == existingID
            }) else { throw Error.routineGone }
            existing = routine.definition
        } else {
            existing = nil
        }
        var specJSON = string(params, "schedule_spec_json") ?? existing?.scheduleSpecJSON ?? ""
        if !specJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard BotScheduleSpec.decodeJSON(specJSON) != nil else {
                throw Error(code: -32602, message: "Provide a valid Bot schedule.")
            }
            if let existing,
               let previous = try? JSONSerialization.jsonObject(with: Data(existing.scheduleSpecJSON.utf8)) as? [String: Any],
               var incoming = try? JSONSerialization.jsonObject(with: Data(specJSON.utf8)) as? [String: Any] {
                // Missing means an older editor did not know this option.
                // An explicit null remains present and clears an optional.
                for (key, value) in previous where incoming[key] == nil { incoming[key] = value }
                specJSON = String(
                    decoding: try JSONSerialization.data(withJSONObject: incoming, options: [.sortedKeys]), as: UTF8.self
                )
            }
            guard let spec = BotScheduleSpec.decodeJSON(specJSON) else {
                throw Error(code: -32602, message: "Provide a valid Bot schedule.")
            }
            do { _ = try spec.makeRecurrence() }
            catch { throw Error(code: -32602, message: error.localizedDescription) }
        }
        let definition = BotRoutineDefinition(
            id: existingID ?? BotRoutineID(),
            botID: bot.id,
            name: string(params, "name") ?? "Routine",
            prompt: string(params, "prompt") ?? "",
            scheduleNote: string(params, "schedule_note") ?? "",
            scheduleSpecJSON: specJSON,
            createdAt: now,
            updatedAt: now
        )
        try store.saveRoutine(definition, enabled: bool(params, "enabled"), now: now)
        let routineKey = definition.id.value.uuidString.lowercased()
        var runtime = routineRuntime[routineKey] ?? [:]
        runtime["next_run_at"] = dateValue(nextRunDate(
            definition: definition,
            enabled: (try store.listRoutines(botID: bot.id).first {
                $0.definition.id == definition.id
            })?.activation.isEnabled == true,
            after: now
        ))
        routineRuntime[routineKey] = runtime
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "routine_id": definition.id.value.uuidString.lowercased(),
            "schedule_spec_json": specJSON,
            "next_run_at": runtime["next_run_at"] ?? NSNull(),
        ])
    }

    private func routineEnable(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let raw = string(params, "routine_id"), let uuid = UUID(uuidString: raw) else { throw Error.invalidParams }
        guard try store.listRoutines(botID: bot.id).contains(where: {
            $0.definition.id == BotRoutineID(uuid)
        }) else { throw Error.routineGone }
        let enabled = bool(params, "enabled") ?? false
        try store.setRoutineEnabled(id: BotRoutineID(uuid), botID: bot.id, enabled: enabled)
        let stored = try store.listRoutines(botID: bot.id).first {
            $0.definition.id == BotRoutineID(uuid)
        }
        let nextRunAt = stored.flatMap {
            nextRunDate(definition: $0.definition, enabled: enabled, after: now)
        }
        var runtime = routineRuntime[raw.lowercased()] ?? [:]
        runtime["next_run_at"] = dateValue(nextRunAt)
        routineRuntime[raw.lowercased()] = runtime
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "routine_id": raw.lowercased(),
            "enabled": enabled,
            "next_run_at": dateValue(nextRunAt),
        ])
    }

    /// iOS Run now: the phone's Test run. A real send in a new conversation;
    /// the receipt fails with the reason when the run could not start.
    private func routineRun(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        try requireControlPlane()
        let bot = try requireBot(params)
        guard let routineID = string(params, "routine_id"),
              let routineUUID = UUID(uuidString: routineID),
              let routine = try store.listRoutines(botID: bot.id).first(where: {
                  $0.definition.id == BotRoutineID(routineUUID)
              }) else { throw Error.routineGone }
        try store.requestRoutineTestRun(id: routine.definition.id, now: now)
        let started = startRoutineLocked(routine, scheduledAt: nil, hostID: string(params, "host_id"), now: now)
        var readback = started.run
        if let notification = started.notification { readback["notification"] = notification }
        let failed = started.run["result"] as? String == "failed"
        return receipt(requestID: requestID, status: failed ? .failed : .completed, botID: id(bot), readback: readback)
    }

    private func routineDelete(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let raw = string(params, "routine_id"), let uuid = UUID(uuidString: raw) else { throw Error.invalidParams }
        guard try store.listRoutines(botID: bot.id).contains(where: {
            $0.definition.id == BotRoutineID(uuid)
        }) else { throw Error.routineGone }
        try store.deleteRoutine(id: BotRoutineID(uuid), botID: bot.id)
        routineRuntime.removeValue(forKey: raw.lowercased())
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["deleted": true])
    }

    /// The same pass the in-process timer runs, starting each claimed slot
    /// in place: `runs` holds what really happened to each one.
    private func schedulerTick(params: [String: Any], now: Date, requestID: String) throws -> [String: Any] {
        var runs: [[String: Any]] = []
        var notifications: [[String: Any]] = []
        for fire in try claimDueRoutinesLocked(now: now).claims {
            let started = startRoutineLocked(
                fire.routine,
                scheduledAt: fire.scheduledAt,
                hostID: string(params, "host_id"),
                now: now
            )
            runs.append(started.run)
            if let notification = started.notification { notifications.append(notification) }
        }
        return receipt(requestID: requestID, status: .completed, botID: nil, readback: [
            "runs": runs,
            "notifications": notifications,
        ])
    }

    private func attachmentStage(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let conversationRaw = string(params, "conversation_id"),
              let conversationUUID = UUID(uuidString: conversationRaw),
              let conversation = try store.conversation(id: BotConversationID(conversationUUID)) else { throw Error.conversationGone }
        guard conversation.botID == bot.id, conversation.groupID == nil else { throw Error.crossTarget }
        guard let attachmentID = string(params, "attachment_id"), !attachmentID.isEmpty,
              let filename = string(params, "filename"), !filename.isEmpty,
              let rawKind = string(params, "kind"), AgentAttachmentKind(rawValue: rawKind) != nil,
              let digest = string(params, "digest")?.lowercased(),
              digest.count == 64, digest.allSatisfy(\.isHexDigit),
              let size = int(params, "size"), size > 0,
              size <= AgentAttachmentStore.maximumSizeBytes else { throw Error.crossTarget }
        let grant = storeAttachmentGrant(
            botID: id(bot),
            conversationID: conversation.id.value.uuidString.lowercased(),
            attachmentID: attachmentID,
            filename: filename,
            kind: rawKind,
            digest: digest,
            size: size,
            mimeType: string(params, "mime_type")
        )
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: grant)
    }

    private func attachmentImport(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let conversationRaw = string(params, "conversation_id"),
              let conversationUUID = UUID(uuidString: conversationRaw),
              let conversation = try store.conversation(id: BotConversationID(conversationUUID)) else { throw Error.conversationGone }
        guard conversation.botID == bot.id, conversation.groupID == nil else { throw Error.crossTarget }
        let hostID = try requireFileHost(params: params, botID: id(bot))
        let rootHandle = string(params, "root_handle") ?? ""
        let handle = string(params, "handle") ?? ""
        guard !rootHandle.isEmpty, !handle.isEmpty else { throw Error.invalidParams }
        let rootEntry = try resolveFileEntry(bot: bot, handle: rootHandle)
        let entry = try resolveFileEntry(bot: bot, handle: handle)
        let root = (entry["root"] as? String) ?? (filesLocation[id(bot)] ?? "bot_home")
        let currentGeneration = fileGeneration(botID: id(bot), root: root)
        let currentCAS = fileCASValue(botID: id(bot), root: root)
        guard let expectedGeneration = int(params, "expected_generation"),
              let expectedCAS = string(params, "expected_cas"),
              root == (filesLocation[id(bot)] ?? "bot_home"),
              rootEntry["host_id"] as? String == hostID,
              rootEntry["root"] as? String == root,
              rootEntry["kind"] as? String == "root",
              rootEntry["generation"] as? Int == currentGeneration,
              rootEntry["cas"] as? String == currentCAS,
              entry["host_id"] as? String == hostID,
              entry["kind"] as? String == "file",
              entry["generation"] as? Int == currentGeneration,
              entry["cas"] as? String == currentCAS,
              expectedGeneration == currentGeneration,
              expectedCAS == currentCAS else { throw Error.crossTarget }
        let path = entry["path"] as? String ?? ""
        let rootURL = root == "docker_home"
            ? BotGuestHome.url(appSupport: appSupport, botID: try store.guestResourceID(botID: bot.id))
            : botHome(bot).root
        let url = try secureContainedURL(root: rootURL, path: path)
        guard FileManager.default.isReadableFile(atPath: url.path),
              let attachment = try onImportFile?(bot.id, url),
              let reference = AgentAttachmentReference(attachment) else {
            throw Error(code: -32090, message: "Bot file was not found.")
        }
        let grant = storeAttachmentGrant(
            botID: id(bot),
            conversationID: conversation.id.value.uuidString.lowercased(),
            attachmentID: reference.id,
            filename: reference.displayName,
            kind: reference.kind.rawValue,
            digest: reference.sha256,
            size: reference.sizeBytes,
            mimeType: reference.mimeType
        )
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: grant)
    }

    private func storeAttachmentGrant(
        botID: String,
        conversationID: String,
        attachmentID: String,
        filename: String,
        kind: String,
        digest: String,
        size: Int,
        mimeType: String?
    ) -> [String: Any] {
        let grantID = UUID().uuidString.lowercased()
        var grant: [String: Any] = [
            "id": grantID,
            "bot_id": botID,
            "conversation_id": conversationID,
            "attachment_id": attachmentID,
            "filename": filename,
            "kind": kind,
            "digest": digest,
            "size": size,
            "consumed": false,
        ]
        if let mimeType { grant["mime_type"] = mimeType }
        attachments[grantID] = grant
        return grant
    }

    private func attachmentList(params: [String: Any]) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let conversationRaw = string(params, "conversation_id"),
              let conversationUUID = UUID(uuidString: conversationRaw),
              let conversation = try store.conversation(id: BotConversationID(conversationUUID)) else { throw Error.conversationGone }
        guard conversation.botID == bot.id, conversation.groupID == nil else { throw Error.crossTarget }
        let botID = id(bot)
        let conversationID = conversation.id.value.uuidString.lowercased()
        let rows = attachments.values.filter {
            $0["bot_id"] as? String == botID
                && $0["conversation_id"] as? String == conversationID
                && $0["consumed"] as? Bool == false
        }.sorted {
            ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
        }
        return [
            "bot_id": botID,
            "conversation_id": conversationID,
            "attachments": rows,
        ]
    }

    private func attachmentRemove(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let conversationRaw = string(params, "conversation_id"),
              let conversationUUID = UUID(uuidString: conversationRaw),
              let conversation = try store.conversation(id: BotConversationID(conversationUUID)) else { throw Error.conversationGone }
        guard conversation.botID == bot.id, conversation.groupID == nil else { throw Error.crossTarget }
        let conversationID = conversation.id.value.uuidString.lowercased()
        let grantID = string(params, "id") ?? ""
        guard let grant = attachments[grantID],
              grant["bot_id"] as? String == id(bot),
              grant["conversation_id"] as? String == conversationID,
              grant["consumed"] as? Bool == false else { throw Error.crossTarget }
        attachments.removeValue(forKey: grantID)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "removed": true,
            "id": grantID,
            "bot_id": id(bot),
            "conversation_id": conversationID,
        ])
    }

    private func consumeAttachments(_ ids: [String]) {
        for id in ids {
            guard var grant = attachments[id] else { continue }
            grant["consumed"] = true
            attachments[id] = grant
        }
    }

    private func filesMutate(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hostID = try requireFileHost(params: params, botID: botID)
        let rootHandle = string(params, "root_handle") ?? ""
        let handle = string(params, "handle")
        guard !rootHandle.isEmpty,
              processIssuedFileHandles.contains(rootHandle),
              handle.map(processIssuedFileHandles.contains) ?? true else {
            throw Error.invalidParams
        }
        let rootEntry = try resolveFileEntry(bot: bot, handle: rootHandle)
        let entry = try handle.map { try resolveFileEntry(bot: bot, handle: $0) } ?? rootEntry
        guard entry["host_id"] as? String == hostID else { throw Error.crossTarget }
        let root = entry["root"] as? String ?? ""
        let selectedRoot = filesLocation[botID] ?? "bot_home"
        let currentGeneration = fileGeneration(botID: botID, root: root)
        let currentCAS = fileCASValue(botID: botID, root: root)
        let grantedGeneration = entry["generation"] as? Int ?? 0
        let grantedCAS = entry["cas"] as? String ?? ""
        guard let expectedGeneration = int(params, "expected_generation") ?? int(params, "generation"),
              let expectedCAS = string(params, "expected_cas") ?? string(params, "cas"),
              !expectedCAS.isEmpty else { throw Error.invalidParams }
        guard root == selectedRoot,
              rootEntry["host_id"] as? String == hostID,
              rootEntry["root"] as? String == selectedRoot,
              rootEntry["kind"] as? String == "root",
              rootEntry["generation"] as? Int == currentGeneration,
              rootEntry["cas"] as? String == currentCAS,
              grantedGeneration == currentGeneration,
              grantedCAS == currentCAS,
              expectedGeneration == currentGeneration,
              expectedCAS == currentCAS else {
            return fileConflictReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: botID,
                root: selectedRoot,
                expectedGeneration: expectedGeneration,
                expectedCAS: expectedCAS
            )
        }
        let kind = entry["kind"] as? String ?? "file"
        guard (handle == nil && kind == "root") || (handle != nil && kind == "file") else {
            throw Error.invalidParams
        }
        let path = kind == "root"
            ? (string(params, "relative_path") ?? "")
            : (entry["path"] as? String ?? "")
        guard !path.isEmpty else { throw Error.invalidParams }
        let op = string(params, "op") ?? "write"
        guard op == "write" || op == "delete" else { throw Error.invalidParams }
        let contents = string(params, "contents") ?? string(params, "body") ?? ""
        var profileRevision: BotRevision?
        if root == "bot_home", path == BotHome.soulName || path == BotHome.descriptionName {
            guard let revisionID = bot.currentRevisionID,
                  let current = try store.getRevision(id: revisionID),
                  current.botID == bot.id else {
                throw Error.notFound
            }
            let draft = BotRevisionDraft(
                name: current.name,
                title: current.title,
                description: path == BotHome.descriptionName ? (op == "delete" ? "" : contents) : current.description,
                soul: path == BotHome.soulName ? (op == "delete" ? "" : contents) : current.soul,
                permissionMode: current.permissionMode,
                desktopKind: current.desktopKind
            )
            let home = botHome(bot)
            try home.ensure(
                name: current.name,
                handle: bot.handle,
                title: current.title,
                description: current.description,
                soul: current.soul
            )
            let profileURL = try secureContainedURL(root: home.root, path: path)
            let previousContents = try Data(contentsOf: profileURL)
            profileRevision = try store.publish(
                botID: bot.id,
                expectedCurrentRevisionID: revisionID,
                draft: draft,
                beforeCommit: { [self] revision in
                    let publishedContents = path == BotHome.soulName ? revision.soul : revision.description
                    try applyDiskMutation(
                        bot: bot,
                        root: root,
                        path: path,
                        op: op,
                        contents: publishedContents
                    )
                },
                onRollback: {
                    try previousContents.write(to: profileURL, options: .atomic)
                }
            )
        } else {
            try applyDiskMutation(bot: bot, root: root, path: path, op: op, contents: contents)
        }
        revokeFileGrants(botID: botID, root: root)
        let nextGeneration = currentGeneration + 1
        fileGenerations[fileGenerationKey(botID: botID, root: root)] = nextGeneration
        let nextCAS = rotateFileCAS(botID: botID, root: root)
        let nextEntry = op == "delete"
            ? nil
            : mintFileGrant(hostID: hostID, botID: botID, root: root, path: path, kind: "file")
        var readback: [String: Any] = [
            "bot_id": botID,
            "host_id": hostID,
            "root": root,
            "path": path,
            "previous_generation": currentGeneration,
            "previous_cas": currentCAS,
            "generation": nextGeneration,
            "root_cas": nextCAS,
            "root_handle": mintFileGrant(hostID: hostID, botID: botID, root: root, path: "", kind: "root")["handle"] as Any,
            "op": op,
            "security": fileSecurity(),
        ]
        if let nextEntry {
            readback["handle"] = nextEntry["handle"]
            readback["entry_generation"] = nextEntry["generation"]
            readback["entry_cas"] = nextEntry["cas"]
        }
        if let profileRevision {
            readback["current_revision_id"] = profileRevision.id.value.uuidString.lowercased()
            readback["revision"] = profileRevision.revisionNumber
            readback["soul"] = profileRevision.soul
            readback["description"] = profileRevision.description
        }
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: readback)
    }

    private func filesOpen(params: [String: Any], requestID: String, split: Bool) throws -> [String: Any] {
        let bot = try requireBot(params)
        let hostID = try requireFileHost(params: params, botID: id(bot))
        let rootHandle = string(params, "root_handle") ?? ""
        let handle = string(params, "handle") ?? ""
        guard !rootHandle.isEmpty, !handle.isEmpty else { throw Error.invalidParams }
        let rootEntry = try resolveFileEntry(bot: bot, handle: rootHandle)
        let entry = try resolveFileEntry(bot: bot, handle: handle)
        guard entry["host_id"] as? String == hostID else { throw Error.crossTarget }
        let root = (entry["root"] as? String) ?? (filesLocation[id(bot)] ?? "bot_home")
        let currentGeneration = fileGeneration(botID: id(bot), root: root)
        let currentCAS = fileCASValue(botID: id(bot), root: root)
        guard let expectedGeneration = int(params, "expected_generation") ?? int(params, "generation"),
              let expectedCAS = string(params, "expected_cas") ?? string(params, "cas"),
              !expectedCAS.isEmpty else { throw Error.invalidParams }
        guard root == (filesLocation[id(bot)] ?? "bot_home"),
              rootEntry["host_id"] as? String == hostID,
              rootEntry["root"] as? String == root,
              rootEntry["kind"] as? String == "root",
              rootEntry["generation"] as? Int == currentGeneration,
              rootEntry["cas"] as? String == currentCAS,
              entry["kind"] as? String == "file",
              entry["generation"] as? Int == currentGeneration,
              entry["cas"] as? String == currentCAS,
              expectedGeneration == currentGeneration,
              expectedCAS == currentCAS else {
            return fileConflictReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: id(bot),
                root: filesLocation[id(bot)] ?? "bot_home",
                expectedGeneration: expectedGeneration,
                expectedCAS: expectedCAS
            )
        }
        let path = entry["path"] as? String ?? ""
        guard try diskFileExists(bot: bot, root: root, path: path) else {
            throw Error(code: -32090, message: "Bot file was not found.")
        }
        if let onOpenFile {
            try onOpenFile(bot.id, path, split, root)
        }
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "bot_id": id(bot),
            "mounted": true,
            "host_id": hostID,
            "split": split,
            "handle": handle,
            "path": path,
            "root": root,
            "generation": currentGeneration,
            "root_cas": currentCAS,
            "root_handle": rootHandle,
            "entry_generation": entry["generation"] as Any,
            "entry_cas": entry["cas"] as Any,
            "security": fileSecurity(),
        ])
    }

    private func filesLocationSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hostID = try requireFileHost(params: params, botID: botID)
        let root = string(params, "root") ?? "bot_home"
        guard root == "bot_home" || root == "docker_home" else { throw Error.invalidParams }
        let previousRoot = filesLocation[botID] ?? "bot_home"
        let currentGeneration = fileGeneration(botID: botID, root: previousRoot)
        let currentCAS = fileCASValue(botID: botID, root: previousRoot)
        let expectedHandle = string(params, "previous_root_handle") ?? string(params, "expected_handle") ?? ""
        guard let expectedGeneration = int(params, "expected_generation"),
              let expectedCAS = string(params, "expected_cas"),
              !expectedHandle.isEmpty, !expectedCAS.isEmpty,
              processIssuedFileHandles.contains(expectedHandle) else { throw Error.invalidParams }
        let previousGrant = try resolveFileEntry(bot: bot, handle: expectedHandle)
        if previousGrant["kind"] as? String != "root"
            || previousGrant["root"] as? String != previousRoot
            || previousGrant["generation"] as? Int != currentGeneration
            || previousGrant["cas"] as? String != currentCAS
            || expectedGeneration != currentGeneration
            || expectedCAS != currentCAS {
            return fileConflictReceipt(
                requestID: requestID,
                hostID: hostID,
                botID: botID,
                root: previousRoot,
                expectedGeneration: expectedGeneration,
                expectedCAS: expectedCAS
            )
        }
        if root == "docker_home" { _ = try BotGuestHome.ensure(appSupport: appSupport, botID: try store.guestResourceID(botID: bot.id)) }
        if root != previousRoot {
            fileGenerations[fileGenerationKey(botID: botID, root: previousRoot)] = currentGeneration + 1
            _ = rotateFileCAS(botID: botID, root: previousRoot)
            revokeFileGrants(botID: botID)
        }
        filesLocation[botID] = root
        let rootEntry = mintFileGrant(hostID: hostID, botID: botID, root: root, path: "", kind: "root")
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: [
            "bot_id": botID,
            "host_id": hostID,
            "root": root,
            "previous_root": previousRoot,
            "previous_generation": currentGeneration,
            "previous_cas": currentCAS,
            "generation": fileGeneration(botID: botID, root: root),
            "root_cas": fileCASValue(botID: botID, root: root),
            "root_handle": rootEntry["handle"] as Any,
            "security": fileSecurity(),
        ])
    }

    private func browserAction(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let before = try authoritativeBrowserState(bot: bot, hostID: string(params, "host_id"))
        let currentGeneration = before["generation"] as? Int ?? 0
        if let expected = int(params, "expected_generation"), expected != currentGeneration {
            return browserConflictReceipt(requestID: requestID, botID: botID, current: before, expected: expected)
        }
        if let surfaceID = string(params, "surface_id"), surfaceID != before["surface_id"] as? String {
            throw Error.crossTarget
        }
        if let snapshot = int(params, "snapshot_generation"), snapshot != currentGeneration {
            return browserConflictReceipt(requestID: requestID, botID: botID, current: before, expected: snapshot)
        }
        let action = (string(params, "action") ?? "navigate").lowercased()
        let url = string(params, "url") ?? (before["url"] as? String) ?? ""
        let title = string(params, "title") ?? (before["title"] as? String) ?? url
        let beforeSession = before["session"] as? [String: Any] ?? [:]
        if action == "login.complete" {
            let page = try browserStore.loadPageState(botID: bot.id) ?? BotBrowserPageState(url: url, title: title)
            guard BotBrowserLoginPredicate.standard.isLoggedIn(page, openedURL: url) else {
                return receipt(requestID: requestID, status: .failed, botID: botID, readback: [
                    "bot_id": botID,
                    "error": "Login is not complete in the host-owned Bot browser session.",
                    "login_state": "pending",
                    "recovery": ["method": "bot.browser.state", "bot_id": botID],
                ])
            }
        } else if action != "login.cancel" && action != "navigate" && action != "open" {
            return receipt(requestID: requestID, status: .failed, botID: botID, readback: [
                "bot_id": botID,
                "error": "Browser action is not admitted by the paired host.",
                "action": action,
                "recovery": ["method": "bot.browser.state", "bot_id": botID],
            ])
        }
        if action == "navigate" || action == "open" {
            guard !url.isEmpty else { throw Error.invalidParams }
        do {
            _ = try BotBrowserHost.requestOpen(
                store: browserStore,
                botID: bot.id,
                url: url,
                title: title.isEmpty ? nil : title,
                notify: { name in
                    if let notifyBrowserPendingOpen {
                        try notifyBrowserPendingOpen(name)
                    } else {
                        DistributedNotificationCenter.default().post(name: name, object: nil)
                    }
                }
            )
        } catch {
            throw Error(code: -32087, message: "Bot browser persist failed.")
        }
        if action == "login.cancel" {
            let remaining = try browserStore.loadPendingOpens().filter { $0.botID != botID }
            try browserStore.replacePendingOpens(remaining)
        }
        }
        let nextGeneration = currentGeneration + 1
        var persisted: [String: Any] = [
            "generation": nextGeneration,
            "session_id": beforeSession["id"] as? String ?? UUID().uuidString.lowercased(),
            "session_digest": UUID().uuidString.lowercased(),
            "login_state": action == "login.complete" ? "authenticated" : (action == "login.cancel" ? "cancelled" : "pending"),
            "host_id": string(params, "host_id") ?? before["host_id"] as? String ?? "",
        ]
        browser[botID] = persisted
        var state = try authoritativeBrowserState(bot: bot, hostID: string(params, "host_id"))
        state["action"] = action
        state["action_id"] = requestID
        state["session_before_digest"] = beforeSession["digest"] as Any
        state["session_after_digest"] = persisted["session_digest"]
        persisted["url"] = state["url"]
        persisted["title"] = state["title"]
        browser[botID] = persisted
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: state)
    }

    private func linkOpen(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let conversationID = string(params, "conversation_id") ?? ""
        guard !conversationID.isEmpty,
              selectedConversation[botID] == conversationID,
              params["host_first"] as? Bool == true else { throw Error.crossTarget }

        if string(params, "link_kind") == "file" {
            return try fileLinkOpen(
                bot: bot,
                conversationID: conversationID,
                params: params,
                requestID: requestID
            )
        }

        guard string(params, "link_kind") == "web",
              let urlString = string(params, "url"),
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let linkHost = url.host, !linkHost.isEmpty,
              url.user == nil,
              let hostID = string(params, "host_id"), !hostID.isEmpty,
              let surfaceID = string(params, "surface_id"), !surfaceID.isEmpty,
              let expectedGeneration = int(params, "expected_generation"),
              let snapshotGeneration = int(params, "snapshot_generation") else {
            throw Error.invalidParams
        }
        let before = try authoritativeBrowserState(bot: bot, hostID: hostID)
        guard before["host_id"] as? String == hostID,
              before["surface_id"] as? String == surfaceID,
              before["generation"] as? Int == expectedGeneration,
              before["snapshot_generation"] as? Int == snapshotGeneration else {
            throw Error.crossTarget
        }
        var result = try browserAction(
            params: params.merging(["action": "open", "url": urlString]) { _, new in new },
            requestID: requestID
        )
        if var readback = result["readback"] as? [String: Any] {
            readback["conversation_id"] = conversationID
            readback["link_kind"] = "web"
            result["readback"] = readback
        }
        return result
    }

    private func fileLinkOpen(
        bot: BotDefinition,
        conversationID: String,
        params: [String: Any],
        requestID: String
    ) throws -> [String: Any] {
        let botID = id(bot)
        guard params["url"] == nil, params["path"] == nil, params["relative_path"] == nil,
              let hostID = string(params, "host_id"), !hostID.isEmpty,
              let root = string(params, "root"),
              root == (filesLocation[botID] ?? "bot_home"),
              let rootHandle = string(params, "root_handle"),
              let handle = string(params, "handle"),
              processIssuedFileHandles.contains(rootHandle),
              processIssuedFileHandles.contains(handle),
              let expectedGeneration = int(params, "expected_generation"),
              let expectedCAS = string(params, "expected_cas"), !expectedCAS.isEmpty,
              let entryGeneration = int(params, "entry_generation"),
              let entryCAS = string(params, "entry_cas"), !entryCAS.isEmpty else {
            throw Error.invalidParams
        }
        let admittedHostID = try requireFileHost(params: params, botID: botID)
        let rootEntry = try resolveFileEntry(bot: bot, handle: rootHandle)
        let entry = try resolveFileEntry(bot: bot, handle: handle)
        let currentGeneration = fileGeneration(botID: botID, root: root)
        let currentCAS = fileCASValue(botID: botID, root: root)
        guard admittedHostID == hostID,
              rootEntry["host_id"] as? String == hostID,
              entry["host_id"] as? String == hostID,
              rootEntry["root"] as? String == root,
              entry["root"] as? String == root,
              rootEntry["kind"] as? String == "root",
              entry["kind"] as? String == "file",
              rootEntry["generation"] as? Int == currentGeneration,
              entry["generation"] as? Int == currentGeneration,
              rootEntry["cas"] as? String == currentCAS,
              entry["cas"] as? String == currentCAS,
              expectedGeneration == currentGeneration,
              entryGeneration == currentGeneration,
              expectedCAS == currentCAS,
              entryCAS == currentCAS,
              let path = entry["path"] as? String,
              try diskFileExists(bot: bot, root: root, path: path) else {
            throw Error.crossTarget
        }
        try onOpenFile?(bot.id, path, false, root)
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: [
            "bot_id": botID,
            "host_id": hostID,
            "conversation_id": conversationID,
            "link_kind": "file",
            "mounted": true,
            "split": false,
            "root": root,
            "root_handle": rootHandle,
            "handle": handle,
            "generation": currentGeneration,
            "root_cas": currentCAS,
            "entry_generation": currentGeneration,
            "entry_cas": currentCAS,
            "security": fileSecurity(),
        ])
    }

    private func guestCommand(name: String, params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hostID = try requireGuestHost(params)
        _ = try BotGuestHome.ensure(appSupport: appSupport, botID: try store.guestResourceID(botID: bot.id))
        var state = guest[botID] ?? makeStoppedGuestState(botID: botID, hostID: hostID)
        guard state["execution_destination"] as? String == (try store.executionDestination(botID: bot.id).storageValue),
              state["host_id"] as? String == hostID,
              let taskID = string(params, "task_id"),
              let task = guestTask(id: taskID, state: state),
              task["operation"] as? String == "bot.\(name)" else {
            throw Error.guestConflict
        }
        let status: String
        let receiptStatus: Status
        switch name {
        case "guest.start":
            guard let recipeID = string(params, "recipe_id"),
                  recipeID == task["recipe_id"] as? String else { throw Error.guestConflict }
            let runtime = makeGuestRuntime(
                botID: botID,
                hostID: hostID,
                recipeID: recipeID,
                previousState: state
            )
            state["runtime"] = runtime
            state["frame"] = nil
            state["error_message"] = nil
            state["recovery"] = nil
            state["grant_invalidated"] = false
            state["recipe"] = task["recipe"]
            onStartGuest?(bot.id, recipeID, requestID, state)
            status = "starting"
            receiptStatus = .accepted
        case "guest.rebuild":
            try requireGuestRuntime(params: params, state: state)
            let recipeID = ((state["runtime"] as? [String: Any])?["recipe_id"] as? String)
                ?? (task["recipe_id"] as? String)
                ?? ""
            state["runtime"] = makeGuestRuntime(
                botID: botID,
                hostID: hostID,
                recipeID: recipeID,
                previousState: state
            )
            state["frame"] = nil
            state["error_message"] = nil
            state["recovery"] = nil
            state["grant_invalidated"] = false
            onRebuildGuest?(bot.id, requestID, state)
            status = "starting"
            receiptStatus = .accepted
        case "guest.stop":
            try requireGuestRuntime(params: params, state: state)
            invalidateGuestGrant(state: &state, status: "stopping")
            onStopGuest?(bot.id, requestID, state)
            status = "stopping"
            receiptStatus = .accepted
        case "guest.revoke":
            try requireGuestRuntime(params: params, state: state)
            invalidateGuestGrant(state: &state, status: "revoked")
            status = "revoked"
            receiptStatus = .completed
        case "guest.input":
            guard let onGuestInput else {
                throw Error(code: -32091, message: "Bot guest input is unavailable.")
            }
            try validateGuestInput(params: params, task: task, state: state)
            state["input"] = [
                "task_id": taskID,
                "axis": task["axis"] as Any,
                "before_frame_id": string(params, "before_frame_id") as Any,
                "atomic": (task["axis"] as? String) == "drag",
            ]
            try onGuestInput(bot.id, params, requestID, state)
            status = "running"
            receiptStatus = .accepted
        default:
            throw Error.invalidParams
        }
        state["status"] = status
        state["viewer"] = "/vnc.html"
        state["viewer_path"] = "/vnc.html"
        state["last_request_id"] = requestID
        state["security"] = Self.guestSecurity
        state["embed_html_is_not_runtime"] = true
        guest[botID] = state
        return receipt(requestID: requestID, status: receiptStatus, botID: botID, readback: state)
    }

    /// `bot.guest.control`: the paired user takes the bot's computer (the bot's
    /// act and exec steps are refused while they drive) or hands it back.
    /// Release does not answer an open manual action; `agent.manual_action.resolve` does.
    private func guestControl(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let hostID = try requireGuestHost(params)
        let take: Bool
        switch string(params, "action") {
        case "take": take = true
        case "release": take = false
        default: throw Error.invalidParams
        }
        if guest[botID] == nil {
            guest[botID] = makeStoppedGuestState(botID: botID, hostID: hostID)
        }
        guard var readback = guest[botID], readback["host_id"] as? String == hostID else {
            throw Error.guestConflict
        }
        if take {
            computerControl.take(bot.id)
        } else {
            computerControl.release(bot.id)
        }
        onGuestControlChanged?(bot.id, take)
        // The receipt is stored and replayed: no screenshot in it (bot.guest.state serves the frame).
        readback["frame"] = nil
        readback["controlled_by_user"] = computerControl.isControlledByUser(bot.id)
        readback["control_action"] = take ? "take" : "release"
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: readback)
    }

    // MARK: - Guest observe (paired live viewer)

    /// A frame captured for a paired viewer (`bot.guest.state` with `observe: true`).
    public struct ObservedGuestFrame: Sendable, Equatable {
        public let containerID: String
        public let viewerPath: String
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let pngBase64: String
        public let pngHash: String

        public init(
            containerID: String,
            viewerPath: String,
            pixelWidth: Int,
            pixelHeight: Int,
            pngBase64: String,
            pngHash: String
        ) {
            self.containerID = containerID
            self.viewerPath = viewerPath
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.pngBase64 = pngBase64
            self.pngHash = pngHash
        }
    }

    public enum GuestObserveTarget: Equatable, Sendable {
        /// Running on this runtime grant and showing `frameID` (nil before the first frame).
        case running(grantID: String, frameID: String?)
        /// Not running here: if Docker runs the bot's container, a client may
        /// adopt it with `bot.guest.start` (observe itself never mints a grant).
        case adoptable
        /// Starting, stopping, revoked or never read by this host: nothing to capture.
        case unavailable
    }

    private static let adoptableGuestStatuses: Set<String> = ["stopped", "failed", "reconnect_required"]

    public func guestObserveTarget(botID: BotID, hostID: String) -> GuestObserveTarget {
        lock.lock()
        defer { lock.unlock() }
        guard let state = guest[botID.value.uuidString.lowercased()],
              state["host_id"] as? String == hostID,
              let status = state["status"] as? String else { return .unavailable }
        if status == "running" {
            guard state["grant_invalidated"] as? Bool == false,
                  let grantID = (state["runtime"] as? [String: Any])?["grant_id"] as? String else {
                return .unavailable
            }
            return .running(grantID: grantID, frameID: (state["frame"] as? [String: Any])?["frame_id"] as? String)
        }
        return Self.adoptableGuestStatuses.contains(status) ? .adoptable : .unavailable
    }

    /// Stores a frame captured for an observing viewer. Latest wins: the frame
    /// is dropped unless the guest still runs on `grantID` and still shows
    /// `expectedFrameID`. Kept in memory only (a relaunch invalidates grants).
    @discardableResult
    public func applyObservedGuestFrame(
        botID: BotID,
        grantID: String,
        expectedFrameID: String?,
        frame observed: ObservedGuestFrame
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = botID.value.uuidString.lowercased()
        guard var state = guest[key],
              state["status"] as? String == "running",
              state["grant_invalidated"] as? Bool == false,
              var runtime = state["runtime"] as? [String: Any],
              runtime["grant_id"] as? String == grantID else { return false }
        let previous = state["frame"] as? [String: Any]
        let previousID = previous?["frame_id"] as? String
        guard previousID == expectedFrameID else { return false }
        runtime["container_id"] = observed.containerID
        runtime["viewer_path"] = observed.viewerPath
        let frameID = UUID().uuidString.lowercased()
        state["runtime"] = runtime
        state["frame"] = [
            "runtime": runtime,
            "frame_id": frameID,
            "sequence": (previous?["sequence"] as? Int ?? -1) + 1,
            "pixel_width": observed.pixelWidth,
            "pixel_height": observed.pixelHeight,
            "png_base64": observed.pngBase64,
            "png_hash": observed.pngHash,
        ]
        state["before_frame_id"] = previousID
        state["after_frame_id"] = frameID
        if let previousID,
           let width = previous?["pixel_width"] as? Int,
           let height = previous?["pixel_height"] as? Int {
            var recent = guestRecentFrames[key]
            if recent?.grantID != grantID { recent = (grantID, []) }
            recent?.frames.append(RecentGuestFrame(id: previousID, width: width, height: height))
            if let kept = recent?.frames.suffix(Self.recentObservedFrameLimit) {
                recent?.frames = Array(kept)
            }
            guestRecentFrames[key] = recent
        }
        guest[key] = state
        return true
    }

    /// The container the viewer watched is gone: the grant ends as `stopped`.
    @discardableResult
    public func markObservedGuestStopped(botID: BotID, grantID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = botID.value.uuidString.lowercased()
        guard var state = guest[key],
              state["status"] as? String == "running",
              (state["runtime"] as? [String: Any])?["grant_id"] as? String == grantID else { return false }
        invalidateGuestGrant(state: &state, status: "stopped")
        guest[key] = state
        persistSidecar()
        return true
    }

    /// The paired host binding of the bot's guest state, nil before any client read it.
    public func guestHostID(botID: BotID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return guest[botID.value.uuidString.lowercased()]?["host_id"] as? String
    }

    /// Frames a viewer saw a moment ago stay valid input targets: at 1-2 fps an
    /// observe can replace the frame between the user's tap and its arrival.
    private static let recentObservedFrameLimit = 4

    private struct RecentGuestFrame {
        let id: String
        let width: Int
        let height: Int
    }

    /// Only a recent frame of the current frame's size: input coordinates are
    /// in the named frame's pixels and run on the screen as it is now.
    private func isRecentObservedFrame(
        _ frameID: String?,
        state: [String: Any],
        width: Int,
        height: Int
    ) -> Bool {
        guard let frameID,
              let botID = state["bot_id"] as? String,
              let grantID = (state["runtime"] as? [String: Any])?["grant_id"] as? String,
              let recent = guestRecentFrames[botID],
              recent.grantID == grantID,
              let named = recent.frames.last(where: { $0.id == frameID }) else { return false }
        return named.width == width && named.height == height
    }

    private func requireGuestHost(_ params: [String: Any]) throws -> String {
        let hostID = string(params, "host_id")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !hostID.isEmpty, hostID.count <= 256 else { throw Error.guestConflict }
        return hostID
    }

    private func makeStoppedGuestState(botID: String, hostID: String) -> [String: Any] {
        [
            "host_id": hostID,
            "bot_id": botID,
            "execution_destination": (try? store.executionDestination(botID: BotID(UUID(uuidString: botID)!)).storageValue) ?? "own_vm",
            "status": "stopped",
            "viewer": "/vnc.html",
            "viewer_path": "/vnc.html",
            "grant_generation": 0,
            "grant_invalidated": true,
            "task_catalog": makeGuestTaskCatalog(botID: botID),
            "security": Self.guestSecurity,
            "embed_html_is_not_runtime": true,
        ]
    }

    private func makeGuestTaskCatalog(botID: String) -> [String: Any] {
        let recipeID = UUID().uuidString.lowercased()
        let recipe: [String: Any] = [
            "id": recipeID,
            "immutable": true,
            "image_reference": BotComputerGuestSpec.imageTag,
            "container_id": BotComputerGuestSpec.containerName(botID: (try? store.guestResourceID(botID: BotID(UUID(uuidString: botID)!))) ?? BotID(UUID(uuidString: botID)!)),
            "viewer_path": "/vnc.html",
        ]
        func task(
            _ title: String,
            axis: String,
            operation: String,
            mode: String,
            includesRecipe: Bool = false
        ) -> [String: Any] {
            var result: [String: Any] = [
                "id": UUID().uuidString.lowercased(),
                "title": title,
                "axis": axis,
                "operation": operation,
                "interaction_mode": mode,
            ]
            if includesRecipe {
                result["recipe_id"] = recipeID
                result["recipe"] = recipe
            }
            return result
        }
        return [
            "id": UUID().uuidString.lowercased(),
            "generation": 1,
            "tasks": [
                task("Pointer", axis: "pointer", operation: "bot.guest.input", mode: "HOSTED_GUEST"),
                task("Key", axis: "key", operation: "bot.guest.input", mode: "HOSTED_GUEST"),
                task("Text", axis: "text", operation: "bot.guest.input", mode: "HOSTED_GUEST"),
                task("Drag", axis: "drag", operation: "bot.guest.input", mode: "HOSTED_GUEST"),
                task("Start", axis: "start", operation: "bot.guest.start", mode: "HOST_RUNTIME_RPC", includesRecipe: true),
                task("Try again", axis: "tryAgain", operation: "bot.guest.start", mode: "HOST_RUNTIME_RPC", includesRecipe: true),
                task("Rebuild", axis: "rebuild", operation: "bot.guest.rebuild", mode: "HOST_RUNTIME_RPC"),
                task("Stop", axis: "stop", operation: "bot.guest.stop", mode: "HOST_RUNTIME_RPC"),
                task("Fullscreen", axis: "fullscreen", operation: "bot.guest.state", mode: "HOST_RUNTIME_RPC"),
                task("Error", axis: "error", operation: "bot.guest.state", mode: "HOST_RUNTIME_RPC"),
                task("Refresh frame", axis: "frameObserve", operation: "bot.guest.state", mode: "HOST_RUNTIME_RPC"),
                task("Revoke access", axis: "grantRevoke", operation: "bot.guest.revoke", mode: "HOST_RUNTIME_RPC"),
                task("Reconnect", axis: "reconnect", operation: "bot.guest.state", mode: "HOST_RUNTIME_RPC"),
                task("Recover", axis: "recovery", operation: "bot.guest.start", mode: "HOST_RUNTIME_RPC", includesRecipe: true),
            ],
        ]
    }

    private func guestTask(id taskID: String, state: [String: Any]) -> [String: Any]? {
        guard let catalog = state["task_catalog"] as? [String: Any],
              let tasks = catalog["tasks"] as? [[String: Any]] else { return nil }
        return tasks.first { $0["id"] as? String == taskID }
    }

    private func makeGuestRuntime(
        botID: String,
        hostID: String,
        recipeID: String,
        previousState: [String: Any]
    ) -> [String: Any] {
        let previousRuntime = previousState["runtime"] as? [String: Any]
        let currentGeneration = previousRuntime?["grant_generation"] as? Int
            ?? previousState["grant_generation"] as? Int
            ?? 0
        return [
            "host_id": hostID,
            "bot_id": botID,
            "container_id": BotComputerGuestSpec.containerName(botID: (try? store.guestResourceID(botID: BotID(UUID(uuidString: botID)!))) ?? BotID(UUID(uuidString: botID)!)),
            "app_run_id": UUID().uuidString.lowercased(),
            "viewer_id": UUID().uuidString.lowercased(),
            "viewer_path": "/vnc.html",
            "session_id": UUID().uuidString.lowercased(),
            "grant_id": UUID().uuidString.lowercased(),
            "grant_generation": currentGeneration + 1,
            "recipe_id": recipeID,
            "image_reference": BotComputerGuestSpec.imageTag,
        ]
    }

    private func requireGuestRuntime(params: [String: Any], state: [String: Any]) throws {
        guard state["status"] as? String == "running",
              state["grant_invalidated"] as? Bool == false,
              let expected = state["runtime"] as? [String: Any],
              let supplied = params["runtime"] as? [String: Any] else {
            throw Error.guestConflict
        }
        for key in [
            "host_id", "bot_id", "container_id", "app_run_id", "viewer_id",
            "viewer_path", "session_id", "grant_id", "grant_generation",
            "recipe_id", "image_reference",
        ] where !Self.guestValuesEqual(expected[key], supplied[key]) {
            throw Error.guestConflict
        }
    }

    private func validateGuestInput(
        params: [String: Any],
        task: [String: Any],
        state: [String: Any]
    ) throws {
        try requireGuestRuntime(params: params, state: state)
        let beforeFrameID = string(params, "before_frame_id")
        guard let frame = state["frame"] as? [String: Any],
              let frameID = frame["frame_id"] as? String,
              let width = frame["pixel_width"] as? Int,
              let height = frame["pixel_height"] as? Int,
              frameID == beforeFrameID
                || isRecentObservedFrame(beforeFrameID, state: state, width: width, height: height),
              let input = params["input"] as? [String: Any],
              let kind = input["kind"] as? String,
              kind == task["axis"] as? String else { throw Error.guestConflict }
        func point(_ xKey: String, _ yKey: String) -> (x: Int, y: Int)? {
            guard let x = Self.integralGuestCoordinate(input[xKey], maximum: width - 1),
                  let y = Self.integralGuestCoordinate(input[yKey], maximum: height - 1) else {
                return nil
            }
            return (x, y)
        }
        switch kind {
        case "pointer":
            guard point("x", "y") != nil else { throw Error.invalidParams }
        case "drag":
            guard let from = point("from_x", "from_y"),
                  let to = point("to_x", "to_y"),
                  from.x != to.x || from.y != to.y else {
                throw Error.invalidParams
            }
        case "text":
            let text = (input["text"] as? String) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 2_000 else { throw Error.invalidParams }
        case "key":
            let allowed = Set(["Return", "Escape", "Tab", "Shift+Tab", "BackSpace", "Up", "Down", "Left", "Right"])
            guard let key = input["key"] as? String, allowed.contains(key) else { throw Error.invalidParams }
        default:
            throw Error.invalidParams
        }
    }

    private static func integralGuestCoordinate(_ raw: Any?, maximum: Int) -> Int? {
        guard maximum >= 0 else { return nil }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              let value = Int(exactly: number.doubleValue),
              (0...maximum).contains(value) else {
            return nil
        }
        return value
    }

    private func invalidateGuestGrant(state: inout [String: Any], status: String) {
        let previousGeneration = (state["runtime"] as? [String: Any])?["grant_generation"] as? Int
            ?? state["grant_generation"] as? Int
            ?? 0
        state["status"] = status
        state["grant_generation"] = previousGeneration + 1
        state["grant_invalidated"] = true
        state["runtime"] = nil
        state["frame"] = nil
        state["input"] = nil
    }

    private func invalidateRestoredGuestGrants() {
        guard !guest.isEmpty else { return }
        for botID in Array(guest.keys) {
            guard var state = guest[botID] else { continue }
            let hadRuntime = state["runtime"] != nil
            if hadRuntime {
                invalidateGuestGrant(state: &state, status: "reconnect_required")
                state["recovery"] = [
                    "method": "bot.guest.state",
                    "requires_new_start_grant": true,
                ]
            }
            state["security"] = Self.guestSecurity
            guest[botID] = state
        }
        persistSidecar()
    }

    private static func guestValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case let (left as String, right as String): return left == right
        case let (left as Int, right as Int): return left == right
        case let (left as NSNumber, right as NSNumber): return left == right
        default: return false
        }
    }

    private func dockerClear(params: [String: Any], requestID: String) throws -> [String: Any] {
        if string(params, "confirm") != "clear" {
            return receipt(requestID: requestID, status: .accepted, botID: string(params, "bot_id"), readback: ["confirm_required": true])
        }
        let bot = try requireBot(params)
        guard try store.executionDestination(botID: bot.id).virtualMachineID == nil else {
            throw Error(code: -32602, message: "Shared VM files cannot be cleared from one bot.")
        }
        let botID = id(bot)
        let removedPaths: [String]
        do {
            removedPaths = (try? listDiskPaths(bot: bot, root: "docker_home")) ?? []
            try BotGuestHome.wipe(appSupport: appSupport, botID: bot.id)
        } catch {
            throw Error(code: -32088, message: "Docker home clear failed.")
        }
        var partial = false
        if let onDockerClear {
            do {
                try onDockerClear(bot.id)
            } catch {
                partial = true
            }
        }
        let removed = files.keys.filter { key in
            (files[key]?["bot_id"] as? String) == botID && (files[key]?["root"] as? String) == "docker_home"
        }
        for key in removed { files[key] = nil }
        processIssuedFileHandles.subtract(removed)
        let dockerGeneration = fileGeneration(botID: botID, root: "docker_home") + 1
        fileGenerations[fileGenerationKey(botID: botID, root: "docker_home")] = dockerGeneration
        let dockerCAS = rotateFileCAS(botID: botID, root: "docker_home")
        if var guestState = guest[botID] {
            invalidateGuestGrant(state: &guestState, status: "stopped")
            guestState["security"] = Self.guestSecurity
            guest[botID] = guestState
        }
        return receipt(
            requestID: requestID,
            status: partial ? .partial : .completed,
            botID: botID,
            readback: [
                "bot_id": botID,
                "cleared": true,
                "removed_count": max(removed.count, removedPaths.count),
                "partial": partial,
                "generation": dockerGeneration,
                "root_cas": dockerCAS,
            ]
        )
    }

    private func notifySet(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let enabled = bool(params, "enabled") ?? true
        _ = try store.updateProfile(id: bot.id, notificationsEnabled: enabled, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "notifications_enabled": enabled,
            "route": "bot",
        ])
    }

    private func verbositySet(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let verbosity = string(params, "verbosity").flatMap(BotReplyVerbosity.init(rawValue:)) else {
            throw Error.invalidParams
        }
        _ = try store.setReplyStyle(id: bot.id, verbosity: verbosity, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "verbosity": verbosity.rawValue,
            "route": "bot",
        ])
    }

    private func cavemanSet(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let enabled = bool(params, "enabled") else {
            throw Error.invalidParams
        }
        _ = try store.setReplyStyle(id: bot.id, cavemanEnabled: enabled, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "caveman_enabled": enabled,
            "route": "bot",
        ])
    }

    /// Titio only: a paired device can put a broken Titio back to its
    /// built-in profile, like the Mac Studio's Restore Factory Settings.
    private func factoryReset(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard bot.handle.lowercased() == TitioIdentity.handle else {
            throw Error.invalidParams
        }
        let restored = try store.restoreTitioFactorySettings(id: bot.id, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "bot": try encodeBot(restored),
            "route": "bot",
        ])
    }

    /// A tap on a Titio notice card (hub spec §7). The receipt is completed
    /// once the host claimed (or navigated); Titio's result message reports
    /// the final outcome of an `accepted` act.
    private func noticeReply(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard bot.handle.lowercased() == TitioIdentity.handle,
              let messageID = string(params, "message_id"), UUID(uuidString: messageID) != nil,
              let text = string(params, "text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 65_536 else { throw Error.invalidParams }
        guard let onNoticeReply else { throw Error(code: -32091, message: "Bot runtime is unavailable.") }
        let revision = int(params, "question_revision")
        if params["question_revision"] != nil && (revision == nil || revision! < 0) { throw Error.invalidParams }
        let answer = try onNoticeReply(bot.id, messageID, text, revision)
        let outcome = answer["outcome"] ?? "not_found"
        var result = receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "message_id": messageID.lowercased(), "outcome": outcome, "route": "bot",
            "bot_id": id(bot), "host_id": answer["host_id"] ?? NSNull(),
        ])
        result["message_id"] = messageID.lowercased()
        result["host_id"] = answer["host_id"]
        result["outcome"] = outcome
        return result
    }

    private func noticeAct(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard bot.handle.lowercased() == TitioIdentity.handle,
              let messageID = string(params, "message_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: messageID) != nil,
              let optionIndex = int(params, "option_index"), optionIndex >= 0 else {
            throw Error.invalidParams
        }
        guard let onNoticeAct else { throw Error(code: -32091, message: "Bot runtime is unavailable.") }
        let contextual = (params["client_capabilities"] as? [String] ?? []).contains("bot.notice_reply_v1")
        let answer = try (contextual ? onNoticeContextualAct?(bot.id, messageID, optionIndex) : nil)
            ?? onNoticeAct(bot.id, messageID, optionIndex)
        var readback: [String: Any] = [
            "message_id": messageID.lowercased(),
            "option_index": optionIndex,
            "outcome": answer["outcome"] ?? "not_found",
            "route": "bot",
        ]
        // `route` in a readback names the readback route ("bot"); the
        // navigation target travels as `navigation` there and as `route` at
        // the receipt's top level (spec `{status, outcome, route?}`).
        if let navigation = answer["route"] { readback["navigation"] = navigation }
        var result = receipt(requestID: requestID, status: .completed, botID: id(bot), readback: readback)
        result["outcome"] = readback["outcome"]
        if let question = answer["question"] { result["question"] = question }
        if let navigation = answer["route"] { result["route"] = navigation }
        return result
    }

    /// iOS opened Titio's inbox: unread goes to 0 (hub spec §8 "Read state").
    private func noticeRead(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard bot.handle.lowercased() == TitioIdentity.handle,
              let raw = string(params, "conversation_id"),
              let uuid = UUID(uuidString: raw) else {
            throw Error.invalidParams
        }
        guard let onNoticeRead else { throw Error(code: -32091, message: "Bot runtime is unavailable.") }
        var readback = try onNoticeRead(bot.id, BotConversationID(uuid))
        readback["conversation_id"] = raw.lowercased()
        readback["route"] = "bot"
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: readback)
    }

    /// A trailing clear on a Titio inbox message (contract §3). The receipt
    /// reads back `{cleared, message_id, thread_id, route}`.
    private func noticeClear(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard bot.handle.lowercased() == TitioIdentity.handle,
              let messageID = string(params, "message_id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: messageID) != nil else {
            throw Error.invalidParams
        }
        guard let onNoticeClear else { throw Error(code: -32091, message: "Bot runtime is unavailable.") }
        let answer = try onNoticeClear(bot.id, messageID)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "cleared": true,
            "message_id": messageID.lowercased(),
            "thread_id": answer["thread_id"] ?? NSNull(),
            "route": "bot",
        ])
    }

    private func desktopSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let rawKind = string(params, "kind") ?? BotDesktopKind.logicalExecutionSpace.rawValue
        guard let kind = BotDesktopKind(rawValue: rawKind),
              BotDesktopKind.advertisedKinds.contains(kind),
              let revisionID = bot.currentRevisionID,
              let current = try store.getRevision(id: revisionID),
              current.botID == bot.id else {
            throw Error.invalidParams
        }
        let draft = BotRevisionDraft(
            name: bot.name,
            title: current.title,
            description: current.description,
            soul: current.soul,
            permissionMode: current.permissionMode,
            desktopKind: kind
        )
        let published = try store.publish(botID: bot.id, expectedCurrentRevisionID: revisionID, draft: draft,
            beforeCommit: { _ in try self.store.writeExecutionDestination(kind == .dockerDesktop ? .ownVM : .mac, botID: bot.id) })
        return receipt(
            requestID: requestID,
            status: .completed,
            botID: id(bot),
            readback: [
                "kind": published.desktopKind.advertisedOrLogical.rawValue,
                "desktop_kind": published.desktopKind.advertisedOrLogical.rawValue,
                "current_revision_id": published.id.value.uuidString.lowercased(),
            ]
        )
    }

    private func avatarSet(params: [String: Any], requestID: String, now: Date) throws -> [String: Any] {
        let bot = try requireBot(params)
        let shape = string(params, "shape") ?? "auto"
        let hue = string(params, "hue") ?? "auto"
        guard Self.blobatarShapes.contains(shape), Self.blobatarHues.contains(hue) else { throw Error.invalidParams }
        let base: BotBlobatarSpec
        if let symbol = string(params, "avatar_symbol") {
            guard let spec = BotBlobatarSpec.parse(symbol),
                  spec.shape.rawValue == shape, spec.hue.token == hue else { throw Error.invalidParams }
            base = spec
        } else {
            base = BotBlobatarSpec.parse(bot.avatarSymbol) ?? .default
        }
        let token = base.selecting(
            shape: BotBlobatarShape(rawValue: shape) ?? .auto,
            hue: hue == "auto" ? .auto : .named(hue),
            name: bot.name, handle: bot.handle
        ).token
        _ = try store.updateProfile(id: bot.id, avatarSymbol: token, now: now)
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: [
            "shape": shape,
            "hue": hue,
            "avatar_symbol": token,
        ])
    }

    private func handleSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        guard let handle = BotHandle.normalize(string(params, "handle") ?? "") else { throw Error.invalidParams }
        do {
            _ = try store.renameHandle(id: bot.id, handle: handle)
        } catch BotPublishError.handleConflict {
            throw Error.handleConflict
        }
        return receipt(requestID: requestID, status: .completed, botID: id(bot), readback: ["handle": handle])
    }

    private func soulSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let soul = string(params, "soul") ?? ""
        guard let revisionID = bot.currentRevisionID,
              let current = try store.getRevision(id: revisionID),
              current.botID == bot.id else {
            throw Error.notFound
        }
        let draft = BotRevisionDraft(
            name: bot.name,
            title: current.title,
            description: current.description,
            soul: soul,
            permissionMode: current.permissionMode,
            desktopKind: current.desktopKind
        )
        let published = try store.publish(botID: bot.id, expectedCurrentRevisionID: revisionID, draft: draft)
        return receipt(
            requestID: requestID,
            status: .completed,
            botID: id(bot),
            readback: [
                "soul": published.soul,
                "current_revision_id": published.id.value.uuidString.lowercased(),
            ]
        )
    }

    private func routingSet(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let provider = string(params, "provider") ?? AgentProvider.defaultProvider.rawValue
        let providerInstanceID = string(params, "provider_instance_id") ?? provider
        let routingReceiptID = UUID().uuidString.lowercased()
        let runAsUser = params["run_as_user"] ?? Self.runAsUserObject(AgentRunAsUser.current())
        var pref: [String: Any] = [
            "provider": provider,
            "provider_instance_id": providerInstanceID,
            "model": string(params, "model") ?? "",
            "routing_mode": string(params, "routing_mode") ?? "auto",
            "permission_mode": string(params, "permission_mode") ?? "full_access",
            "reasoning_effort": string(params, "reasoning_effort") ?? "medium",
            "service_tier": string(params, "service_tier") ?? "auto",
            "run_as_user": runAsUser,
            "routing_receipt_id": routingReceiptID,
            "host_id": string(params, "host_id") ?? "",
            "bot_id": id(bot),
        ]
        for key in Self.workerRoutingKeys where params[key] != nil {
            guard let value = string(params, key) else { throw Error.invalidParams }
            if key != "worker_model", value != "auto", AgentReasoningEffort(rawValue: value) == nil {
                throw Error.invalidParams
            }
            pref[key] = value
        }
        if let rawConversationID = string(params, "conversation_id") {
            guard let uuid = UUID(uuidString: rawConversationID),
                  let conversation = try store.conversation(id: BotConversationID(uuid)) else {
                throw Error.conversationGone
            }
            guard conversation.botID == bot.id, conversation.groupID == nil else { throw Error.crossTarget }
            pref["conversation_id"] = conversation.id.value.uuidString.lowercased()
            if let onConversationRoutingSet {
                // The receipt is the resolved desk route (an empty Main
                // resolves like the Mac desk), so the device echoes and the
                // send runs exactly this route. Receipt keys stay.
                let resolved = try onConversationRoutingSet(bot.id, conversation.id, pref)
                for key in ["model"] + Self.workerRoutingKeys {
                    if let value = resolved[key] { pref[key] = value }
                }
            }
        }
        pref["effective"] = pref
        routingPref[id(bot)] = pref
        return receipt(
            requestID: requestID,
            status: .completed,
            botID: id(bot),
            readback: pref,
            receiptID: routingReceiptID
        )
    }

    /// Optional Distill Worker/effort route fields, shared by `bot.routing.set`
    /// and the receipt check in `bot.send`.
    private static let workerRoutingKeys = ["worker_model", "worker_effort", "distill_main_effort"]

    private func attentionAck(params: [String: Any], requestID: String) throws -> [String: Any] {
        let bot = try requireBot(params)
        let botID = id(bot)
        let profileID = string(params, "profile_id") ?? ""
        let hostID = string(params, "host_id") ?? ""
        let itemID = string(params, "attention_item_id")
            ?? string(params, "notification_id")
            ?? string(params, "item_id")
            ?? ""
        guard !profileID.isEmpty, !hostID.isEmpty, !itemID.isEmpty,
              attentionBindings.contains(profileID: profileID, hostID: hostID),
              let stored = attention[botID] else { throw Error.crossTarget }
        let item = canonicalAttentionItem(stored)
        guard item["id"] as? String == itemID,
              item["bot_id"] as? String == botID,
              item["profile_id"] as? String == profileID,
              item["host_id"] as? String == hostID,
              item["state"] as? String != "none" else { throw Error.crossTarget }
        if let uuid = UUID(uuidString: itemID) {
            try store.acknowledgeAttention(id: BotAttentionItemID(uuid))
        }
        var cleared = item
        cleared["state"] = "none"
        attention[botID] = cleared
        return receipt(requestID: requestID, status: .completed, botID: botID, readback: [
            "state": "none",
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": itemID,
            "notification_id": itemID,
            "bot_id": botID,
            "source": item["source"] as? String ?? "bot",
        ])
    }

    private func canonicalAttentionItem(_ raw: [String: Any], hostID: String? = nil) -> [String: Any] {
        var item = raw
        guard let itemID = item["id"] as? String, !itemID.isEmpty else { return item }
        item["attention_item_id"] = itemID
        item["notification_id"] = itemID
        if item["profile_id"] as? String != nil,
           item["host_id"] as? String != nil {
            return item
        }
        let requestedHost = hostID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedHost = item["host_id"] as? String
        let selectedHost = storedHost?.isEmpty == false ? storedHost : requestedHost
        if let selectedHost, !selectedHost.isEmpty {
            item["host_id"] = selectedHost
            if let binding = attentionBindings.unique(hostID: selectedHost) {
                item["profile_id"] = binding.profileID
            }
        }
        return item
    }

    private func persistAttentionNotification(
        _ item: [String: Any],
        now: Date
    ) throws -> [String: Any]? {
        let state = item["state"] as? String ?? ""
        guard state == "finished" || state == "needs" || state == "needs_attention",
              let notificationID = item["notification_id"] as? String,
              let attentionItemID = item["attention_item_id"] as? String,
              let profileID = item["profile_id"] as? String,
              let hostID = item["host_id"] as? String,
              let botID = item["bot_id"] as? String,
              let botUUID = UUID(uuidString: botID),
              let bot = try store.get(id: BotID(botUUID)),
              bot.notificationsEnabled,
              let source = item["source"] as? String,
              !notificationID.isEmpty, !attentionItemID.isEmpty,
              !profileID.isEmpty, !hostID.isEmpty, !botID.isEmpty else {
            return nil
        }
        let title = item["title"] as? String ?? "Review Bot request"
        let body = item["detail"] as? String
        let category = "RemoteCodeThreadUpdate"
        let metadata = BotAttentionNotificationMetadata(
            notificationID: notificationID,
            profileID: profileID,
            hostID: hostID,
            attentionItemID: attentionItemID,
            botID: botID,
            source: source
        )
        let inserted = try db.transaction {
            let inserted = try NotificationRepository(db: db).insertIfAbsent(AppNotification(
                id: notificationID,
                title: title,
                body: body,
                category: category,
                createdAt: now
            ))
            if inserted { try attentionNotificationMetadata.record(metadata) }
            return inserted
        }
        guard inserted else { return nil }
        return [
            "id": notificationID,
            "title": title,
            "body": body as Any,
            "category": category,
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": attentionItemID,
            "notification_id": notificationID,
            "bot_id": botID,
            "source": source,
        ]
    }

    private func peerAsk(params: [String: Any], requestID: String) throws -> [String: Any] {
        let payload: [String: Any] = [
            "request_id": requestID,
            "status": Status.completed.rawValue,
            "handle": string(params, "handle") ?? "",
            "reply": "ok",
        ]
        peerReceipts[requestID] = payload
        return receipt(requestID: requestID, status: .completed, botID: string(params, "bot_id"), readback: payload)
    }

    private func selfConfig(params: [String: Any], requestID: String) throws -> [String: Any] {
        let payload: [String: Any] = [
            "request_id": requestID,
            "status": Status.completed.rawValue,
            "tool_name": string(params, "tool_name") ?? "",
        ]
        peerReceipts[requestID] = payload
        return receipt(requestID: requestID, status: .completed, botID: string(params, "bot_id"), readback: payload)
    }

    // MARK: - Helpers

    private func requireControlPlane() throws {
        guard settings.reload().isBotControlPlaneActive else { throw Error.controlPlaneOff }
    }

    private func requireBot(_ params: [String: Any]) throws -> BotDefinition {
        guard let raw = string(params, "bot_id"), let uuid = UUID(uuidString: raw),
              let bot = try store.get(id: BotID(uuid)), bot.deletedAt == nil else {
            throw Error.notFound
        }
        return bot
    }

    private func id(_ bot: BotDefinition) -> String {
        bot.id.value.uuidString.lowercased()
    }

    private func virtualMachineWorkspace(_ params: [String: Any]) throws -> WorkspaceID? {
        guard params["workspace_id"] != nil, !(params["workspace_id"] is NSNull) else { return nil }
        guard let raw = string(params, "workspace_id"), let uuid = UUID(uuidString: raw),
              onVMWorkspaceExists?(WorkspaceID(uuid)) == true else {
            throw Error(code: -32602, message: "Choose an available workspace.")
        }
        return WorkspaceID(uuid)
    }

    private func encodeVirtualMachine(_ machine: BotVirtualMachine) -> [String: Any] {
        ["id": machine.id.uuidString.lowercased(), "name": machine.name,
         "workspace_id": machine.workspaceID.map { $0.value.uuidString.lowercased() as Any } ?? NSNull(),
         "scope": machine.workspaceID == nil ? "general" : "workspace"]
    }

    private func encodeBot(_ bot: BotDefinition, extra: [String: Any] = [:]) throws -> [String: Any] {
        guard let revisionID = bot.currentRevisionID,
              let revision = try store.getRevision(id: revisionID),
              revision.botID == bot.id else {
            throw Error.notFound
        }
        var body: [String: Any] = [
            "id": id(bot),
            "handle": bot.handle,
            "name": bot.name,
            "title": bot.title,
            "description": bot.description,
            "avatar_symbol": bot.avatarSymbol,
            "pinned": bot.pinned,
            "hidden": bot.hidden,
            "notifications_enabled": bot.notificationsEnabled,
            "verbosity": bot.verbosity.rawValue,
            "caveman_enabled": bot.cavemanEnabled,
            "soul": revision.soul,
            "desktop_kind": revision.desktopKind.advertisedOrLogical.rawValue,
            "current_revision_id": revision.id.value.uuidString.lowercased(),
            "workspace_id": bot.workspaceID.map { $0.value.uuidString.lowercased() as Any } ?? NSNull(),
            "execution_destination": try store.executionDestination(botID: bot.id).storageValue,
            "sort_order": bot.sortOrder.map { $0 as Any } ?? NSNull(),
        ]
        if let routing = routingPref[id(bot)] {
            body["routing"] = routing
        }
        if bot.handle.lowercased() == TitioIdentity.handle, let inbox = onTitioInbox?() {
            body["titio_inbox"] = inbox
        }
        for (key, value) in extra { body[key] = value }
        return body
    }

    private func encodeRoutine(_ routine: BotRoutine) -> [String: Any] {
        var result: [String: Any] = [
            "id": routine.definition.id.value.uuidString.lowercased(),
            "bot_id": routine.definition.botID.value.uuidString.lowercased(),
            "name": routine.definition.name,
            "prompt": routine.definition.prompt,
            "schedule_note": routine.definition.scheduleNote,
            "schedule_spec_json": routine.definition.scheduleSpecJSON,
            "enabled": routine.activation.isEnabled,
        ]
        if let runtime = routineRuntime[routine.definition.id.value.uuidString.lowercased()] {
            result.merge(runtime) { _, runtimeValue in runtimeValue }
        }
        return result
    }

    private func nextRunDate(
        definition: BotRoutineDefinition,
        enabled: Bool,
        after date: Date
    ) -> Date? {
        guard enabled,
              let spec = definition.scheduleSpec,
              let recurrence = try? spec.makeRecurrence(),
              let timeZone = TimeZone(identifier: spec.timeZoneIdentifier) else {
            return nil
        }
        return ScheduledTaskOccurrenceCalculator.nextOccurrence(
            after: date,
            recurrence: recurrence,
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    private func dateValue(_ date: Date?) -> Any {
        if let date { return date.timeIntervalSince1970 }
        return NSNull()
    }

    private func receipt(
        requestID: String,
        status: Status,
        botID: String?,
        readback: [String: Any],
        receiptID: String = UUID().uuidString.lowercased()
    ) -> [String: Any] {
        [
            "request_id": requestID,
            "receipt_id": receiptID,
            "status": status.rawValue,
            "bot_id": botID as Any,
            "readback": readback,
        ]
    }

    private func runtimeReceipt(
        requestID: String,
        hostID: String,
        botID: String,
        conversationID: String?,
        runID: String,
        readback: [String: Any]
    ) -> [String: Any] {
        var exactReadback = readback
        exactReadback["host_id"] = hostID
        exactReadback["bot_id"] = botID
        exactReadback["request_id"] = requestID
        exactReadback["client_request_id"] = requestID
        exactReadback["conversation_id"] = conversationID ?? NSNull()
        exactReadback["run_id"] = runID
        var exactReceipt = receipt(
            requestID: requestID,
            status: .completed,
            botID: botID,
            readback: exactReadback
        )
        exactReceipt["host_id"] = hostID
        exactReceipt["client_request_id"] = requestID
        return exactReceipt
    }

    /// Nil without a routing receipt: the host runs the conversation's own
    /// desk route. A receipt pins the exact route `bot.routing.set` admitted.
    private func effectiveRouting(
        botID: String,
        params: [String: Any]
    ) throws -> [String: Any]? {
        guard let requestedReceipt = string(params, "routing_receipt_id") else { return nil }
        guard var routing = routingPref[botID],
              !requestedReceipt.isEmpty,
              !consumedRoutingReceipts.contains(requestedReceipt),
              routing["routing_receipt_id"] as? String == requestedReceipt,
              routing["host_id"] as? String == string(params, "host_id"),
              params["run_as_user"] != nil else {
            throw Error.crossTarget
        }
        for key in [
            "provider", "provider_instance_id", "model", "routing_mode",
            "permission_mode", "reasoning_effort", "service_tier",
        ] {
            guard let requested = params[key] as? String,
                  requested == routing[key] as? String else {
                throw Error.crossTarget
            }
        }
        for key in Self.workerRoutingKeys where routing[key] != nil || params[key] != nil {
            guard params[key] as? String == routing[key] as? String else { throw Error.crossTarget }
        }
        if let scoped = routing["conversation_id"] as? String,
           string(params, "conversation_id") != scoped {
            throw Error.crossTarget
        }
        if let requestedRunAs = params["run_as_user"],
           !Self.jsonObjectsEqual(requestedRunAs, routing["run_as_user"]) {
            throw Error.crossTarget
        }
        routing["routing_receipt_id"] = requestedReceipt
        return routing
    }

    private static func jsonObjectsEqual(_ lhs: Any, _ rhs: Any?) -> Bool {
        guard let rhs,
              JSONSerialization.isValidJSONObject(["value": lhs]),
              JSONSerialization.isValidJSONObject(["value": rhs]),
              let left = try? JSONSerialization.data(
                withJSONObject: ["value": lhs],
                options: [.sortedKeys]
              ),
              let right = try? JSONSerialization.data(
                withJSONObject: ["value": rhs],
                options: [.sortedKeys]
              ) else {
            return false
        }
        return left == right
    }

    private static let runAsUserEncoder = JSONEncoder()
    private static let runAsUserCodecLock = NSLock()

    private static func runAsUserObject(_ user: AgentRunAsUser) -> Any {
        // PERF: share one encoder under a short lock (JSONEncoder is not
        // thread-safe) instead of allocating per call.
        Self.runAsUserCodecLock.lock()
        let data = try? Self.runAsUserEncoder.encode(user)
        Self.runAsUserCodecLock.unlock()
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [String: Any]()
        }
        return object
    }

    private func string(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    private func bool(_ params: [String: Any], _ key: String) -> Bool? {
        if let value = params[key] as? Bool { return value }
        if let number = params[key] as? NSNumber { return number.boolValue }
        if let text = params[key] as? String {
            if text == "true" || text == "1" { return true }
            if text == "false" || text == "0" { return false }
        }
        return nil
    }

    private func int(_ params: [String: Any], _ key: String) -> Int? {
        if let value = params[key] as? Int { return value }
        if let number = params[key] as? NSNumber { return number.intValue }
        if let text = params[key] as? String { return Int(text) }
        return nil
    }

    private func stringArray(_ params: [String: Any], _ key: String) -> [String] {
        (params[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func encodeQueue(_ records: [BotQueuedFollowUpRecord]) -> [[String: Any]] {
        records.map { record in
            var item: [String: Any] = [
                "id": record.id,
                "bot_id": record.botID.value.uuidString.lowercased(),
                "text": record.text,
                "created_at": record.createdAt.timeIntervalSince1970,
            ]
            if let conversationID = record.conversationID {
                item["conversation_id"] = conversationID
            }
            let payload = record.payloadJSON.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            if let attachments = payload["attachments"] {
                item["attachments"] = attachments
            }
            if let requestID = nonemptyIdentity(payload["client_request_id"] as? String) {
                item["client_request_id"] = requestID
            }
            // Pass through identities bound to THIS queue row. Never copy the
            // blocking live run: that is a different send.
            if let runID = nonemptyIdentity(payload["run_id"] as? String) {
                item["run_id"] = runID
            }
            if let threadID = nonemptyIdentity(payload["thread_id"] as? String)
                ?? queuedConversationThreadID(record.conversationID) {
                item["thread_id"] = threadID
            }
            return item
        }
    }

    private func nonemptyIdentity(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func queuedConversationThreadID(_ conversationID: String?) -> String? {
        guard let conversationID,
              let uuid = UUID(uuidString: conversationID),
              let conversation = try? store.conversation(id: BotConversationID(uuid)),
              let threadID = conversation.linkedAgentThreadID else { return nil }
        return threadID.value.uuidString.lowercased()
    }

    /// Live execution for this conversation: in-memory send first, then a
    /// pending/running `agent_runs` row on the stored thread. Does not invent
    /// a run after the live turn has settled.
    private func liveConversationIdentity(
        botID: String,
        conversationID: String,
        storedThreadID: AgentThreadID?
    ) -> (runID: String, threadID: String)? {
        if let live = liveRuns[botID],
           live["conversation_id"] as? String == conversationID,
           let runID = nonemptyIdentity(live["run_id"] as? String) {
            let threadID = nonemptyIdentity(live["thread_id"] as? String)
                ?? storedThreadID?.value.uuidString.lowercased()
            if let threadID { return (runID, threadID) }
        }
        guard let storedThreadID,
              let runID = activeRunID(for: storedThreadID) else { return nil }
        return (runID, storedThreadID.value.uuidString.lowercased())
    }

    private func activeRunID(for threadID: AgentThreadID) -> String? {
        let raw = threadID.value.uuidString.lowercased()
        do {
            return try db.performSync { database -> String? in
                let statement = try database.prepare("""
                    SELECT id FROM agent_runs
                    WHERE thread_id = ? COLLATE NOCASE
                      AND status IN ('pending', 'running')
                    ORDER BY started_at DESC
                    LIMIT 1;
                    """)
                defer { statement.reset() }
                try statement.bind(1, raw)
                guard try statement.step() else { return nil }
                return nonemptyIdentity(statement.columnText(0))
            }
        } catch {
            return nil
        }
    }

    /// Terminal `agent_runs` status of an admitted run. Nil while the run is
    /// pending or running, while it has no row yet (the provider start is
    /// asynchronous), or when the read fails: only a durable terminal row ends a run.
    private func terminalRunStatus(runID: String) -> (status: String, finishedAt: Double?)? {
        let upper = UUID(uuidString: runID)?.uuidString ?? runID
        do {
            return try db.performSync { database -> (status: String, finishedAt: Double?)? in
                // Two exact probes keep the primary-key lookup; NOCASE would scan.
                let statement = try database.prepare("""
                    SELECT status, finished_at FROM agent_runs
                    WHERE id IN (?, ?)
                      AND status IN ('completed', 'failed', 'cancelled', 'interrupted')
                    LIMIT 1;
                    """)
                defer { statement.reset() }
                try statement.bind(1, upper)
                try statement.bind(2, upper.lowercased())
                guard try statement.step(),
                      let status = nonemptyIdentity(statement.columnText(0)) else { return nil }
                let finishedAt = statement.columnText(1).flatMap { iso.date(from: $0) }?.timeIntervalSince1970
                return (status: status, finishedAt: finishedAt)
            }
        } catch {
            return nil
        }
    }

    private func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func botHome(_ bot: BotDefinition) -> BotHome {
        BotHome(appSupportDirectory: appSupport, bot: bot)
    }

    private func resolveFileEntry(bot: BotDefinition, handle: String) throws -> [String: Any] {
        guard let entry = files[handle] else { throw Error.invalidParams }
        guard entry["bot_id"] as? String == id(bot) else { throw Error.crossTarget }
        return entry
    }

    private func diskFileExists(bot: BotDefinition, root: String, path: String) throws -> Bool {
        if root == "docker_home" {
            let url = try secureContainedURL(root: BotGuestHome.url(appSupport: appSupport, botID: try store.guestResourceID(botID: bot.id)), path: path)
            return FileManager.default.fileExists(atPath: url.path)
        }
        return FileManager.default.fileExists(atPath: try secureContainedURL(root: botHome(bot).root, path: path).path)
    }

    private func fileGenerationKey(botID: String, root: String) -> String {
        if root == "docker_home", let uuid = UUID(uuidString: botID),
           let resource = try? store.guestResourceID(botID: BotID(uuid)) {
            return "\(resource.value.uuidString.lowercased())|\(root)"
        }
        return "\(botID)|\(root)"
    }

    private func fileGeneration(botID: String, root: String) -> Int {
        fileGenerations[fileGenerationKey(botID: botID, root: root)] ?? 1
    }

    private func fileCASValue(botID: String, root: String) -> String {
        let key = fileGenerationKey(botID: botID, root: root)
        if let value = fileCAS[key], !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        fileCAS[key] = value
        return value
    }

    @discardableResult
    private func rotateFileCAS(botID: String, root: String) -> String {
        let value = UUID().uuidString.lowercased()
        fileCAS[fileGenerationKey(botID: botID, root: root)] = value
        return value
    }

    private func revokeFileGrants(botID: String, root: String? = nil) {
        let revoked = files.keys.filter { handle in
            guard files[handle]?["bot_id"] as? String == botID else { return false }
            return root == nil || files[handle]?["root"] as? String == root
        }
        for handle in revoked { files[handle] = nil }
        processIssuedFileHandles.subtract(revoked)
    }

    private func fileSecurity() -> [String: Any] {
        [
            "opaque_handle": true,
            "bot_bound": true,
            "root_bound": true,
            "generation_bound": true,
            "cas_bound": true,
            "symlink_safe": true,
        ]
    }

    private func requireFileHost(params: [String: Any], botID: String) throws -> String {
        let requested = string(params, "host_id")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let admitted = fileHosts[botID] ?? ""
        guard admitted.isEmpty || requested.isEmpty || admitted == requested else { throw Error.crossTarget }
        if admitted.isEmpty, !requested.isEmpty { fileHosts[botID] = requested }
        return admitted.isEmpty ? requested : admitted
    }

    private func mintFileGrant(hostID: String, botID: String, root: String, path: String, kind: String) -> [String: Any] {
        let currentGeneration = fileGeneration(botID: botID, root: root)
        let currentCAS = fileCASValue(botID: botID, root: root)
        if let existing = files.values.first(where: {
            $0["bot_id"] as? String == botID
                && $0["host_id"] as? String == hostID
                && $0["root"] as? String == root
                && $0["path"] as? String == path
                && $0["kind"] as? String == kind
                && $0["generation"] as? Int == currentGeneration
                && $0["cas"] as? String == currentCAS
        }) {
            if let handle = existing["handle"] as? String {
                processIssuedFileHandles.insert(handle)
            }
            return existing
        }
        let handle = UUID().uuidString.lowercased()
        let entry: [String: Any] = [
            "handle": handle,
            "host_id": hostID,
            "bot_id": botID,
            "root": root,
            "path": path,
            "kind": kind,
            "generation": currentGeneration,
            "cas": currentCAS,
            "security": fileSecurity(),
        ]
        files[handle] = entry
        processIssuedFileHandles.insert(handle)
        return entry
    }

    private func fileConflictReceipt(
        requestID: String,
        hostID: String,
        botID: String,
        root: String,
        expectedGeneration: Int,
        expectedCAS: String
    ) -> [String: Any] {
        let current = fileGeneration(botID: botID, root: root)
        let currentCAS = fileCASValue(botID: botID, root: root)
        return receipt(requestID: requestID, status: .failed, botID: botID, readback: [
            "bot_id": botID,
            "host_id": hostID,
            "conflict": true,
            "root": root,
            "root_handle": mintFileGrant(
                hostID: hostID,
                botID: botID,
                root: root,
                path: "",
                kind: "root"
            )["handle"] as Any,
            "generation": current,
            "root_cas": currentCAS,
            "expected_generation": expectedGeneration,
            "expected_cas": expectedCAS,
            "current_generation": current,
            "current_cas": currentCAS,
            "recovery": [
                "method": "bot.files.list",
                "bot_id": botID,
                "root": root,
                "current_generation": current,
                "current_cas": currentCAS,
            ],
        ])
    }

    private func applyDiskMutation(
        bot: BotDefinition,
        root: String,
        path: String,
        op: String,
        contents: String
    ) throws {
        let rootURL: URL
        if root == "docker_home" {
            rootURL = try BotGuestHome.ensure(appSupport: appSupport, botID: try store.guestResourceID(botID: bot.id))
        } else {
            let home = botHome(bot)
            try home.ensure(
                name: bot.name,
                handle: bot.handle,
                title: bot.title,
                description: bot.description,
                soul: ""
            )
            rootURL = home.root
        }
        let url = try secureContainedURL(root: rootURL, path: path)
        if op == "delete" {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func listDiskPaths(bot: BotDefinition, root: String) throws -> [String] {
        if root == "docker_home" {
            return try enumerateRegularFiles(root: BotGuestHome.url(appSupport: appSupport, botID: try store.guestResourceID(botID: bot.id)))
        }
        return try enumerateRegularFiles(root: botHome(bot).root)
    }

    private func enumerateRegularFiles(root: URL) throws -> [String] {
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolvedRoot.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var paths: [String] = []
        let rootPath = resolvedRoot.path
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator?.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return paths.sorted()
    }

    private func secureContainedURL(root: URL, path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("..") else {
            throw Error(code: -32086, message: "Path escapes Bot home containment.")
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let url = resolvedRoot.appendingPathComponent(trimmed).standardizedFileURL
        let resolvedCandidate = FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath()
            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        let rootPath = resolvedRoot.path
        guard resolvedCandidate.path == rootPath || resolvedCandidate.path.hasPrefix(rootPath + "/") else {
            throw Error(code: -32086, message: "Path escapes Bot home containment.")
        }
        return resolvedCandidate
    }

    private func browserSurfaceID(_ bot: BotDefinition) -> String {
        BotBrowserIdentity.dataStoreIdentifier(for: bot.id).uuidString.lowercased()
    }

    private func authoritativeBrowserState(bot: BotDefinition, hostID: String?) throws -> [String: Any] {
        let botID = id(bot)
        let stored = browser[botID] ?? [:]
        let storedSession = stored["session"] as? [String: Any] ?? [:]
        let admittedHostID = stored["host_id"] as? String ?? ""
        let requestedHostID = hostID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard admittedHostID.isEmpty || requestedHostID.isEmpty || admittedHostID == requestedHostID else {
            throw Error.crossTarget
        }
        let target = try browserStore.loadTarget(botID: bot.id)
        let page = try browserStore.loadPageState(botID: bot.id)
        let url = page?.url.isEmpty == false ? page?.url ?? "" : target?.url ?? stored["url"] as? String ?? ""
        let title = page?.title.isEmpty == false ? page?.title ?? "" : target?.title ?? stored["title"] as? String ?? ""
        let openedURL = target?.url ?? url
        let authenticated = page.map {
            BotBrowserLoginPredicate.standard.isLoggedIn($0, openedURL: openedURL)
        } ?? false
        let sessionID = stored["session_id"] as? String
            ?? storedSession["id"] as? String
            ?? UUID().uuidString.lowercased()
        let digest = stored["session_digest"] as? String
            ?? storedSession["digest"] as? String
            ?? UUID().uuidString.lowercased()
        let loginState = authenticated
            ? "authenticated"
            : (stored["login_state"] as? String ?? (url.isEmpty ? "empty" : "anonymous"))
        let currentGeneration = stored["generation"] as? Int ?? (url.isEmpty ? 0 : 1)
        var result: [String: Any] = [
            "host_id": admittedHostID.isEmpty ? requestedHostID : admittedHostID,
            "bot_id": botID,
            "surface_id": browserSurfaceID(bot),
            "url": url,
            "title": title,
            "generation": currentGeneration,
            "snapshot_generation": currentGeneration,
            "host_first": true,
            "security": [
                "bot_bound": true,
                "host_owned_website_data": true,
                "cookie_exported": false,
            ],
            "session": [
                "id": sessionID,
                "digest": digest,
                "state": loginState,
                "authenticated": authenticated,
                "cookie_exported": false,
            ],
        ]
        if let loading = page?.loading ?? stored["loading"] as? Bool {
            result["loading"] = loading
        }
        return result
    }

    private func browserConflictReceipt(
        requestID: String,
        botID: String,
        current: [String: Any],
        expected: Int
    ) -> [String: Any] {
        receipt(requestID: requestID, status: .failed, botID: botID, readback: [
            "bot_id": botID,
            "conflict": true,
            "expected_generation": expected,
            "current_generation": current["generation"] as? Int ?? 0,
            "surface_id": current["surface_id"] as Any,
            "recovery": ["method": "bot.browser.state", "bot_id": botID],
        ])
    }

    private func loadSidecar() {
        unpublished = Set(loadStringArray("bot.remote.unpublished"))
        if let data = loadData("bot.remote.receipts"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            receipts = decoded
        }
        if let data = loadData("bot.remote.receipt_claims"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            receiptClaims = decoded
        }
        if let data = loadData("bot.remote.attachments"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            attachments = decoded
        }
        if let data = loadData("bot.remote.files_location"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            filesLocation = decoded
        }
        if let data = loadData("bot.remote.file_grants"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            files = decoded
        }
        if let data = loadData("bot.remote.file_generations"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            fileGenerations = decoded
        }
        if let data = loadData("bot.remote.file_cas"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            fileCAS = decoded
        }
        if let data = loadData("bot.remote.file_hosts"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            fileHosts = decoded
        }
        if let data = loadData("bot.remote.browser_state"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            browser = decoded
        }
        if let data = loadData("bot.remote.guest_state"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            guest = decoded
        }
        if let data = loadData("bot.remote.routing"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            routingPref = decoded
        }
        if let data = loadData("bot.remote.routing_consumed"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] {
            consumedRoutingReceipts = Set(decoded)
        }
        if let data = loadData("bot.remote.selected_conversations"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            selectedConversation = decoded
        }
        if let data = loadData("bot.remote.attention"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            attention = decoded
        }
        if let data = loadData("bot.remote.scheduler_runs"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            schedulerRuns = decoded
        }
        if let data = loadData("bot.remote.routine_runtime"),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            routineRuntime = decoded
        }
        pruneRestoredSidecar()
    }

    private func pruneRestoredSidecar() {
        guard let liveBots = try? store.list(includeHidden: true) else { return }
        let liveBotIDs = Set(liveBots.map(id))
        pruneDeletedBotHomes(liveBotIDs: liveBotIDs)
        let staleGuestIDs = guest.keys.filter { !liveBotIDs.contains($0) }
        let staleRoutingReceiptIDs = Set<String>(routingPref.compactMap { botID, routing in
            guard !liveBotIDs.contains(botID) else { return nil }
            return routing["routing_receipt_id"] as? String
        })
        var removed = 0
        func retainLive<Value>(
            _ values: inout [String: Value],
            by botID: (String, Value) -> String?
        ) {
            let before = values.count
            values = values.filter { key, value in
                botID(key, value).map(liveBotIDs.contains) ?? false
            }
            removed += before - values.count
        }

        let unpublishedCount = unpublished.count
        unpublished.formIntersection(liveBotIDs)
        removed += unpublishedCount - unpublished.count

        retainLive(&filesLocation) { key, _ in key }
        retainLive(&attachments) { _, entry in entry["bot_id"] as? String }
        retainLive(&files) { _, entry in entry["bot_id"] as? String }
        retainLive(&fileGenerations) { key, _ in key.split(separator: "|", maxSplits: 1).first.map(String.init) }
        retainLive(&fileCAS) { key, _ in key.split(separator: "|", maxSplits: 1).first.map(String.init) }
        retainLive(&fileHosts) { key, _ in key }
        retainLive(&browser) { key, _ in key }
        retainLive(&guest) { key, _ in key }
        retainLive(&routingPref) { key, _ in key }

        let consumedCount = consumedRoutingReceipts.count
        consumedRoutingReceipts.subtract(staleRoutingReceiptIDs)
        removed += consumedCount - consumedRoutingReceipts.count

        retainLive(&selectedConversation) { key, _ in key }
        retainLive(&attention) { key, _ in key }

        for botID in staleGuestIDs {
            guard let uuid = UUID(uuidString: botID) else { continue }
            try? BotGuestHome.wipe(appSupport: appSupport, botID: BotID(uuid))
        }
        if removed > 0 { persistSidecar() }
    }

    private func pruneDeletedBotHomes(liveBotIDs: Set<String>) {
        let root = BotHome.botsRootURL(appSupportDirectory: appSupport)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let rawID = entry.lastPathComponent.lowercased()
            guard !liveBotIDs.contains(rawID), let uuid = UUID(uuidString: rawID) else { continue }
            try? BotHome.wipe(appSupportDirectory: appSupport, botID: BotID(uuid))
        }
    }

    /// Moves the legacy sidecar queue into `bot_queued_follow_ups`.
    ///
    /// The sidecar is the only copy of those pending follow-ups, so a row stays
    /// in it until the store accepted it: a failed read (bot lookup or queue
    /// list) or a failed insert must never erase it. Dropping the sidecar
    /// wholesale used to make a transient write failure lose the user's queue
    /// with no error and no retry.
    private func migrateSidecarQueueIfNeeded() {
        guard let data = loadData("bot.remote.queue"),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]]
        else { return }
        var unmigrated: [String: [[String: Any]]] = [:]
        for (botRaw, items) in decoded {
            guard let uuid = UUID(uuidString: botRaw) else { continue }
            let botID = BotID(uuid)
            // A failed read is not proof that the bot is gone: keep the rows.
            guard let bot = try? store.get(id: botID) else {
                unmigrated[botRaw] = items
                continue
            }
            guard bot.deletedAt == nil else { continue }
            // A failed read must not pass for an empty queue either: enqueueing
            // again would duplicate rows the store may already hold.
            guard let existing = try? store.listQueuedFollowUps(botID: botID) else {
                unmigrated[botRaw] = items
                continue
            }
            if !existing.isEmpty { continue }
            var pending: [[String: Any]] = []
            for item in items {
                let text = item["text"] as? String ?? ""
                guard !text.isEmpty else { continue }
                do {
                    _ = try store.enqueueQueuedFollowUp(
                        BotQueuedFollowUpRecord(
                            id: item["id"] as? String ?? UUID().uuidString.lowercased(),
                            botID: botID,
                            conversationID: item["conversation_id"] as? String,
                            text: text,
                            payloadJSON: jsonString(["attachments": item["attachments"] as Any]) ?? "{}",
                            createdAt: Date()
                        )
                    )
                } catch {
                    sidecarQueueLog.error(
                        "bot.remote.queue.migration.failed bot=\(botRaw, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    pending.append(item)
                }
            }
            if !pending.isEmpty { unmigrated[botRaw] = pending }
        }
        if unmigrated.isEmpty {
            saveJSON("bot.remote.queue", [String: Any]())
        } else {
            sidecarQueueLog.error(
                "bot.remote.queue.migration.deferred bots=\(unmigrated.count, privacy: .public)"
            )
            _ = saveJSON("bot.remote.queue", unmigrated)
        }
    }

    /// Writes the sidecar rows whose JSON changed since this process last
    /// committed them, in one transaction: one durable commit per mutation
    /// instead of one per key. Returns the keys that were not written; those
    /// stay out of `persistedSidecarJSON`, so the next persist writes them again.
    @discardableResult
    private func persistSidecar(withinTransaction: Bool = false) -> [String] {
        var failed: [String] = []
        var changed: [(key: String, json: Data)] = []
        func save(_ key: String, _ value: Any) {
            guard JSONSerialization.isValidJSONObject(value),
                  let json = try? JSONSerialization.data(withJSONObject: value) else {
                failed.append(key)
                return
            }
            if persistedSidecarJSON[key] != json { changed.append((key, json)) }
        }
        save("bot.remote.unpublished", Array(unpublished).sorted())
        save("bot.remote.receipts", persistentReceiptSnapshot())
        save("bot.remote.receipt_claims", receiptClaims)
        save("bot.remote.attachments", attachments)
        save("bot.remote.files_location", filesLocation)
        save("bot.remote.file_grants", files)
        save("bot.remote.file_generations", fileGenerations)
        save("bot.remote.file_cas", fileCAS)
        save("bot.remote.file_hosts", fileHosts)
        save("bot.remote.browser_state", browser)
        save("bot.remote.guest_state", guest.mapValues { state in
            var projected = state
            projected["frame"] = nil
            projected["input"] = nil
            return projected
        })
        save("bot.remote.routing", routingPref)
        save("bot.remote.routing_consumed", Array(consumedRoutingReceipts).sorted())
        save("bot.remote.selected_conversations", selectedConversation)
        save("bot.remote.attention", attention)
        save("bot.remote.scheduler_runs", schedulerRuns)
        save("bot.remote.routine_runtime", routineRuntime)
        guard !changed.isEmpty else { return failed }
        var rejected: [String] = []
        do {
            let writeRows = {
                rejected = []
                for row in changed {
                    do {
                        try self.writeSidecarRow(row.key, String(decoding: row.json, as: UTF8.self), database: self.db)
                    } catch {
                        rejected.append(row.key)
                    }
                }
            }
            if withinTransaction {
                writeRows()
                guard rejected.isEmpty else { return failed + rejected }
            } else {
                try db.transaction(writeRows)
            }
        } catch {
            // What reached the database is unknown: write these rows again next time.
            for row in changed { persistedSidecarJSON[row.key] = nil }
            return failed + changed.map { $0.key }
        }
        for row in changed where !rejected.contains(row.key) {
            persistedSidecarJSON[row.key] = row.json
        }
        return failed + rejected
    }

    /// Frame bytes stay available to the live receipt/state read path, but are
    /// never accumulated in SQLite. A receipt replay after process loss keeps
    /// its at-most-once identity while requiring a fresh host-issued grant.
    private func persistentReceiptSnapshot() -> [String: [String: Any]] {
        receipts.mapValues { receipt in
            guard var readback = receipt["readback"] as? [String: Any],
                  readback["task_catalog"] != nil,
                  readback["viewer_path"] as? String == "/vnc.html" else { return receipt }
            var projectedReceipt = receipt
            readback["frame"] = nil
            readback["input"] = nil
            if let runtime = readback["runtime"] as? [String: Any] {
                let generation = runtime["grant_generation"] as? Int
                    ?? readback["grant_generation"] as? Int
                    ?? 0
                readback["runtime"] = nil
                readback["status"] = "reconnect_required"
                readback["grant_generation"] = generation + 1
                readback["grant_invalidated"] = true
                readback["recovery"] = [
                    "method": "bot.guest.state",
                    "requires_new_start_grant": true,
                ]
                if receipt["status"] as? String == Status.accepted.rawValue {
                    projectedReceipt["status"] = Status.unknown.rawValue
                }
            }
            readback["security"] = Self.guestSecurity
            projectedReceipt["readback"] = readback
            return projectedReceipt
        }
    }

    private func loadData(_ key: String) -> Data? {
        try? db.performSync { database in
            let statement = try database.prepare("SELECT value FROM settings WHERE key = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, key)
            guard try statement.step(), let text = statement.columnText(0) else { return nil }
            return text.data(using: .utf8)
        } ?? nil
    }

    private func loadStringArray(_ key: String) -> [String] {
        guard let data = loadData(key),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return array
    }

    @discardableResult
    private func saveJSON(_ key: String, _ value: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return false }
        do {
            try db.performSync { database in
                try writeSidecarRow(key, text, database: database)
            }
            return true
        } catch {
            return false
        }
    }

    private func writeSidecarRow(_ key: String, _ text: String, database: SQLiteDB) throws {
#if DEBUG
        let timestamp = useLegacySidecarDateFormatterForBenchmark
            ? ISO8601DateFormatter().string(from: Date())
            : iso.string(from: Date())
#else
        let timestamp = iso.string(from: Date())
#endif
        let statement = try database.prepare(
            "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
        )
        defer { statement.reset() }
        try statement.bind(1, key)
        try statement.bind(2, text)
        try statement.bind(3, timestamp)
        _ = try statement.step()
    }
}
