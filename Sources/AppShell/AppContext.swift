import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import RemoteCodeTreaty
import Surfaces
import os

private let appContextRuntimeLog = Logger(subsystem: "io.remotecode.agent", category: "app-context")

private final class AgentRunStartedDeduplicator: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    func insert(threadID: AgentThreadID, runID: AgentRunID) -> Bool {
        let key = "\(threadID.value.uuidString.lowercased()):\(runID.value.uuidString.lowercased())"
        lock.lock()
        defer { lock.unlock() }
        return keys.insert(key).inserted
    }
}

struct ProjectScriptRunOutcome: Sendable, Equatable {
    let workspaceID: WorkspaceID
    let surfaceID: SurfaceID
    let name: String
    let exitCode: Int32?
    let durationMilliseconds: Int64

    var result: String { exitCode == 0 ? "success" : "failure" }
}

final class ProjectScriptRunRegistry: @unchecked Sendable {
    private struct Entry {
        let workspaceID: WorkspaceID
        let name: String
        let startedAt: Date
    }

    private let lock = NSLock()
    private var entries: [SurfaceID: Entry] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func register(workspaceID: WorkspaceID, surfaceID: SurfaceID, name: String) {
        lock.lock()
        entries[surfaceID] = Entry(workspaceID: workspaceID, name: name, startedAt: now())
        lock.unlock()
    }

    func activeSnapshot() -> [(workspaceID: WorkspaceID, surfaceID: SurfaceID, name: String, startedAt: Date)] {
        lock.lock(); defer { lock.unlock() }
        return entries.map { ($0.value.workspaceID, $0.key, $0.value.name, $0.value.startedAt) }
    }

    func consumeTerminalDeath(surfaceID: SurfaceID, health: TerminalRuntimeHealth) -> ProjectScriptRunOutcome? {
        guard !health.processAlive else { return nil }
        // PTY EOF closes the descriptor before the asynchronous reaper owns an
        // authoritative wait status. Keep the correlated run registered until
        // that reaper publishes either a status, a consumed PID, or a terminal
        // failure reason; otherwise a provisional EOF becomes a false failure.
        let awaitsReaperStatus = health.exitStatus == nil
            && health.childPID != nil
            && health.terminalDeadReason == "process_exited"
        guard !awaitsReaperStatus else { return nil }
        lock.lock()
        let entry = entries.removeValue(forKey: surfaceID)
        lock.unlock()
        guard let entry else { return nil }

        let duration = max(0, Int64(now().timeIntervalSince(entry.startedAt) * 1_000))
        return ProjectScriptRunOutcome(
            workspaceID: entry.workspaceID,
            surfaceID: surfaceID,
            name: entry.name,
            exitCode: Self.exitCode(rawStatus: health.exitStatus, terminationSignal: health.terminationSignal),
            durationMilliseconds: duration
        )
    }

    private static func exitCode(rawStatus: Int32?, terminationSignal: Int32?) -> Int32? {
        guard let rawStatus else { return nil }
        let signal = terminationSignal ?? (rawStatus & 0x7F)
        guard signal == 0 else { return 128 + signal }
        return (rawStatus >> 8) & 0xFF
    }
}

@MainActor
public final class AppContext {
    private final class WeakReference: @unchecked Sendable {
        weak var value: AppContext?
    }

    /// Single source of truth for constructing the `.claude` provider adapter
    /// from the resolved engine, so init and the Settings live-swap can never
    /// diverge. `.cli` is the dependency-minimal default; `.sdk` is the advanced
    /// opt-in that requires the Node runtime bridge.
    static func makeClaudeAdapter(engine: ClaudeEngine, binary: String?) -> AgentProviderAdapter {
        switch engine {
        case .cli: return ClaudeStreamingCLIAdapter(binaryNameOverride: binary)
        case .sdk: return ClaudeAgentSDKBridgeAdapter(binaryNameOverride: binary)
        }
    }

    public let channel: ReleaseChannel
    public let db: SQLiteDB
    /// Readonly WAL connection for UI chrome reads (PF-30).
    public let readDB: SQLiteDB
    public let bootstrapReport: BootstrapReport
    public let appSupportDirectory: URL
    public let distillAdapter: DistillACPAdapter
    public let distillLoopStore: DistillLoopStore
    public let projectRepo: ProjectRepository
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository
    public let queuedMessageRepo: AgentQueuedMessageRepository
    public let runRepo: AgentRunRepository
    public let snapshotRepo: SessionSnapshotRepository
    public let settingsRepo: SettingsRepository
    public let eventLog: EventLogRepository
    public let terminalOutputRepo: TerminalOutputRepository
    public let providerSessionRuntimeRepo: ProviderSessionRuntimeRepository
    public let commandReceiptRepo: CommandReceiptRepository
    public let providerPendingCallbackRepo: ProviderPendingCallbackRepository
    public let proposedPlanRepo: AgentProposedPlanRepository
    public let turnCheckpointRepo: AgentTurnCheckpointRepository
    /// Off-MainActor owner for `agent.checkpoint.list` metadata pages.
    public let checkpointListGateway: AgentTurnCheckpointListGateway
    /// Off-MainActor owner for connection-snapshot AgentThread list/decode.
    public let agentThreadListGateway: AgentThreadListGateway
    /// Off-MainActor owner for the authoritative HTTP workspace list read.
    public let workspaceListGateway: WorkspaceListGateway
    public let botStore: BotStore
    let contextualSecretStore: any BotSecretStore
    let contextualRunAdmissions = BotContextRunAdmissions()
    /// Host MCP servers for bot agents running inside their Linux guest. Binds
    /// 127.0.0.1 on the first issued run bearer; stopped at app termination.
    public let botGuestMCPGateway = BotGuestMCPGateway()
    /// Shared orchestration receipt runtime for the coordinator and every
    /// Agent App surface. Subagent activity must read the same SQLite-backed
    /// receipts that provider launches write.
    public let orchestrationRuntime: AgentOrchestrationRuntime
    public let privateNotificationBridge: PrivateNotificationBridge
    public let liveActivityHostIdentity: LiveActivityHostIdentity
    /// Titio's notice hub (hub spec §3). Inert until `start()` (app launch):
    /// before that, and with the kill switch off, every hook keeps today's code.
    public nonisolated let titioNoticeCenter: TitioNoticeCenter
    private nonisolated let titioNoticeBox = TitioNoticeContextBox()
    public let liveActivityAcceptanceOutbox: LiveActivityAcceptanceOutbox
    public let liveActivitySyncCoordinator: LiveActivitySyncCoordinator
    public lazy var distillAccountsController: DistillAccountsController = {
        let environment = ProcessInfo.processInfo.environment
        let home = DistillProvisioner.homeURL(environment: environment)
        let configured = try? settingsRepo.get("cli.distill.path")
        let binary = DistillProvisioner.resolveInstalledBinary(override: configured ?? nil, environmentPath: environment["PATH"])
            ?? configured ?? "distill"
        let accounts = DistillAccounts(
            home: home,
            binaryPath: binary,
            environment: environment,
            openURL: { url in NSWorkspace.shared.open(url) }
        )
        return DistillAccountsController(accounts: accounts, configuredDistillPathOverride: configured ?? nil) { [weak self] _, succeeded in
            guard let self else { return }
            if succeeded { await self.router?.refreshDistillProviderCatalog() }
        }
    }()
    /// Opens once launch cleanup of bot guests is done; guest runs wait on it.
    public let botGuestLaunchBarrier = DistillGuestLaunchBarrier()
    let guestDocker: any BotComputerDockerClienting
    /// Decides and prepares in-guest Distill runs; quit ends the ones it owns.
    private(set) var botGuestRunResolver: BotGuestRunResolver?
    /// The Distill update schedule (`startDistillAutoUpdates`); nil in a
    /// process that must not touch the user's Distill.
    var distillAutoUpdates: Task<Void, Never>?
    /// Watches the Mac distill's bin directory so an update made outside
    /// MacCode starts the bot VMs' guest download at once.
    var distillHostWatch: DispatchSourceFileSystemObject?
    /// One per app so every bot shares the guest distill cache and its downloads.
    public lazy var distillGuestBinaries = DistillGuestBinaryProvisioner(
        guestToolsRoot: BotComputerGuestSpec.guestToolsURL(appSupport: appSupportDirectory)
    )
    let projectScriptRuns = ProjectScriptRunRegistry()
    public private(set) var remoteCodeOrchestrateInstallResult: RemoteCodeOrchestrateInstallResult?
    public private(set) var remoteCodeOrchestrateStatus: RemoteCodeOrchestrateStatus?
    public private(set) var remoteCodeOrchestrateInstallError: String?
    public private(set) var accountUsageRefreshCount = 0
    public private(set) var persistenceWriteErrorMessage: String?
    public var onPersistenceWriteError: ((String) -> Void)?

    public let reducer = LayoutReducer()
    public var state = LayoutState()

    public let coordinator: AgentRunCoordinator
    /// Set by the app host before anything builds `botPeerHandoffAuthority`
    /// when the event log is wired later; the host then calls
    /// `publishRestoredThreadChrome()` once it is.
    var holdsBotPeerThreadChromeUntilEventLogReady = false
    lazy var botPeerHandoffAuthority = BotPeerHandoffAuthority(
        botStore: botStore,
        threadRepo: threadRepo,
        runRepo: runRepo,
        messageRepo: messageRepo,
        queuedMessageRepo: queuedMessageRepo,
        checkpointRepo: turnCheckpointRepo,
        settingsRepo: settingsRepo,
        coordinator: coordinator,
        appSupportDirectory: appSupportDirectory,
        orchestrationRuntime: orchestrationRuntime,
        holdsThreadChromeUntilEventLogReady: holdsBotPeerThreadChromeUntilEventLogReady
    )
    lazy var botDraftPersistenceAuthority = BotDraftPersistenceAuthority()
    lazy var botGroupOrchestrator = BotGroupOrchestrator(
        botStore: botStore,
        threadRepo: threadRepo,
        runRepo: runRepo,
        messageRepo: messageRepo,
        checkpointRepo: turnCheckpointRepo,
        queuedMessageRepo: queuedMessageRepo,
        coordinator: coordinator,
        appSupportDirectory: appSupportDirectory
    )
    /// Teams and groups for the Mac UI and paired devices (one event source).
    lazy var botTeamGroupService = BotTeamGroupService(
        botStore: botStore,
        orchestrator: botGroupOrchestrator,
        isControlPlaneActive: { [db] in SettingsStore(db: db).load().isBotControlPlaneActive }
    )
    /// False for a background helper sharing this SQLite (Scheduled Task
    /// Agent): it never owns group conversation turns, so it never
    /// interrupts, starts or settles them.
    let hostsBotGroupConversations: Bool
    public var router: AppCommandRouter! {
        didSet {
            titioNoticeBox.context = self
            botPeerHandoffAuthority.router = router
            if hostsBotGroupConversations {
                botGroupOrchestrator.router = router
                _ = botTeamGroupService // installs the group attention hook
                botStore.onBotDeleted = { [weak self] botID, cancelledTurnIDs in
                    // A bot.delete RPC may be capturing events for its receipt;
                    // these settle later and must publish on their own.
                    EventBus.outsideMutationCapture {
                        Task { @MainActor [weak self] in
                            self?.botTeamGroupService.botWasDeleted(botID, cancelledTurnIDs: cancelledTurnIDs)
                        }
                    }
                }
            }
            drainRecoveredForkPrunedThreadIDsIfPossible()
            refreshActiveAgentWorkspaceProjection()
            startBotBrowserPendingOpenObserver()
            try? router?.reconcileBotBrowserOpens()
            router?.reconcileBotComputerActions()
        }
    }
    private var botBrowserOpenObserver: NSObjectProtocol?
    private struct ActiveAgentThreadContext {
        let workspaceID: WorkspaceID
        let title: String
    }

    /// Main-actor cache of coordinator-owned work. Workspace chrome reads the
    /// grouped projection instead of synchronously querying durable thread rows on
    /// every SwiftUI render. The per-thread cache ensures each newly active thread
    /// needs at most one lifecycle-time lookup even during large orchestrated bursts.
    private var activeAgentThreadContextByID: [AgentThreadID: ActiveAgentThreadContext] = [:]
    private var activeAgentThreadTitlesByWorkspace: [WorkspaceID: [String]] = [:]
    /// Last count fanned out to sidebar chrome (Active Threads badge). Tracks
    /// host snapshot size, not the workspace-title map size.
    private var lastPublishedActiveThreadCount: Int = 0
    private var pendingRecoveredForkPrunedThreadIDs: Set<AgentThreadID> = []
    public var socketServer: UnixSocketServer?
    private let accountUsageRefresher: ProviderAccountUsageRefreshing
    private var accountUsageRefreshTask: Task<Void, Never>?
    private var periodicGrokAccountUsageRefreshTask: Task<Void, Never>?
    private var grokAccountUsageRefreshGeneration: UInt64 = 0
    private struct PeriodicAccountUsageCycle {
        let id: UInt64
        var grokFinished = false
        var grokSucceeded = false
        var otherProvidersFinished = false
        var otherProvidersSucceeded = false
        var reconciledMiss = false
    }
    private var periodicAccountUsageCycleID: UInt64 = 0
    private var periodicAccountUsageCycle: PeriodicAccountUsageCycle?
    /// When a refresh was last allowed to launch `claude -p /usage`, and how
    /// many allowed refreshes in a row got no Claude answer.
    private var lastClaudeUsageCLIProbeAt: Date?
    private var claudeUsageCLIProbeMisses = 0
    /// Whether the in-flight full refresh may launch the Claude CLI, and an
    /// explicit refresh that arrived while it may not; that one runs next.
    private var accountUsageRefreshProbesClaude = false
    private var queuedClaudeAccountUsageRefresh: (reason: String, includeGrok: Bool)?
    /// Injectable so tests can step through the Claude CLI interval.
    var accountUsageNow: () -> Date = Date.init
    /// Injectable so tests never answer from the real `~/.claude.json`.
    var claudeUsageCacheURL: URL = AppContext.defaultClaudeUsageCacheURL
    private let accountUsagePublishes = AccountUsagePublishLedger()
    private var usageNotificationTask: Task<Void, Never>?
    private var lastUsageNotificationAt: Date = .distantPast
    /// Per-run usage state. Claude can emit independent per-request charges
    /// followed by an authoritative cumulative result, while Codex and Grok emit
    /// cumulative snapshots. Keep both tracks so the effective run total is the
    /// larger of the incremental sum and cumulative snapshot.
    private struct PendingUsage {
        var provider: AgentProvider
        var incremental = AssistantTokenUsage(semantics: .incremental)
        var cumulative = AssistantTokenUsage(semantics: .cumulative)
        var persisted = AssistantTokenUsage(semantics: .cumulative)
        var writeInFlight = false
        var finished = false
    }
    private struct UsageWriteSnapshot {
        var runId: AgentRunID
        var provider: AgentProvider
        var target: AssistantTokenUsage
        var delta: AssistantTokenUsage
        var deltaBilledTokenUnits: Double
        var currentSessionTokens: Int
        var currentSessionLimitTokens: Int?
    }
    private var pendingUsageByRun: [AgentRunID: PendingUsage] = [:]
    /// Recently completed run baselines accept a late cumulative provider
    /// receipt without double-counting. The bounded tombstone set avoids keeping
    /// every run for the lifetime of a long-running app.
    private var completedUsageByRun: [AgentRunID: PendingUsage] = [:]
    private var completedUsageRunOrder: [AgentRunID] = []
    private static let completedUsageTombstoneLimit = 256
    private var pendingUsageFlushTask: Task<Void, Never>?
    /// Consecutive failed usage writes, driving the retry backoff. Without it a
    /// failed write was retried every debounce window forever, which is ~80
    /// wakeups a minute — each one a cross-process flock, a decode and a failed
    /// atomic write — for as long as the store stays unwritable. Reset by a
    /// successful write.
    private var providerUsageConsecutiveWriteFailures = 0
    /// Test seam: retry delays scheduled after failed usage writes, in order.
    /// Production reads nothing from it.
    var providerUsageRetryDelaysForTesting: [TimeInterval] = []
    var providerUsageConsecutiveWriteFailuresForTesting: Int {
        providerUsageConsecutiveWriteFailures
    }
    /// Test seam used to deterministically fail a usage write before the real
    /// store mutation. Production never sets this.
    var beforeProviderUsageWriteForTesting: (@Sendable () throws -> Void)?
    var providerUsageTombstoneLimitForTesting: Int?
    var completedUsageTombstoneCountForTesting: Int { completedUsageByRun.count }
    func hasCompletedUsageTombstoneForTesting(runId: AgentRunID) -> Bool {
        completedUsageByRun[runId] != nil
    }
    var queueDrainProviderIdleTimeout: TimeInterval = 10
    var queueDrainBeforeDispatchForTesting: (() async -> Void)?
    /// Test seam for the single warning deadline; queue progress is causal.
    var queueDrainSleepForTesting: ((AgentThreadID, Duration) async throws -> Duration)?
    var queueDrainSuppressionAcquiredForTesting: ((AgentThreadID) async -> Void)?
    private struct QueueDrainWaiter {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var queueDrainWaiters: [AgentThreadID: QueueDrainWaiter] = [:]
    private var queueDrainSuppressionLeases: [AgentThreadID: Set<UUID>] = [:]
    private var queueDispatchAcceptancePermits: [AgentThreadID: AgentRunAcceptancePermit] = [:]
    private struct DeferredQueuePromotion {
        let ownerId: AgentQueuedMessageID
        let targetId: AgentQueuedMessageID
    }
    private var deferredQueuePromotions: [AgentThreadID: DeferredQueuePromotion] = [:]
    /// A transient thread readback failure cannot safely decide whether it may
    /// stop provider/queue ownership. Retain the exact deleted candidate until
    /// a later read proves it absent (retire) or present (drop the candidate).
    private struct PendingDeletedThreadRetirement {
        var retryLogged = false
    }
    private var pendingDeletedThreadRetirements: [AgentThreadID: PendingDeletedThreadRetirement] = [:]
    private var deletedThreadRetirementRetryTask: Task<Void, Never>?
    private static let deletedThreadRetirementRetryBaseDelayNanoseconds: UInt64 = 50_000_000
    private static let deletedThreadRetirementRetryMaximumDelayNanoseconds: UInt64 = 2_000_000_000
    private var isTerminating = false
    var queueDrainWaiterCountForTesting: Int { queueDrainWaiters.count }
    var queueDrainSuppressedThreadCountForTesting: Int { queueDrainSuppressionLeases.count }
    #if DEBUG
    var deletedThreadRetirementRetryDelayNanosecondsForTesting: UInt64?
    var pendingDeletedThreadRetirementIDsForTesting: Set<AgentThreadID> {
        Set(pendingDeletedThreadRetirements.keys)
    }

    var deletedThreadQueueRuntimeResidueForTesting: Set<AgentThreadID> {
        Set(queueDrainWaiters.keys)
            .union(queueDrainSuppressionLeases.keys)
            .union(queueDispatchAcceptancePermits.keys)
            .union(deferredQueuePromotions.keys)
    }

    func seedDeletedThreadQueueRuntimeStateForTesting(_ threadId: AgentThreadID) {
        queueDrainWaiters[threadId] = QueueDrainWaiter(
            token: UUID(),
            task: Task<Void, Never> {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        queueDrainSuppressionLeases[threadId] = [UUID()]
        queueDispatchAcceptancePermits[threadId] = AgentRunAcceptancePermit()
        deferredQueuePromotions[threadId] = DeferredQueuePromotion(
            ownerId: AgentQueuedMessageID(),
            targetId: AgentQueuedMessageID()
        )
    }
    #endif
    /// Test seam: sandboxes the managed-skill/config install roots under a temp home so
    /// tests never write /distill state into the developer's real ~/.claude or
    /// ~/.codex. Production code never sets this (installs to the real provider dirs).
    var agentSkillsHomeOverrideForTesting: URL?
    /// The launch-time legacy purge (`startLegacyTokenSaverPurge`).
    private(set) var legacyTokenSaverPurgeTask: Task<Void, Never>?
    static let usageNotificationMinimumInterval: TimeInterval = 2
    /// Debounce window for coalescing per-token usage writes into one disk write.
    static let providerUsageDebounceInterval: TimeInterval = 0.75
    /// Ceiling for the failed-write retry backoff. The retry never gives up: the
    /// pending delta is real provider usage, and dropping it would understate the
    /// ledger. It just stops being retried at the debounce rate.
    private static let providerUsageRetryMaxInterval: TimeInterval = 60

    /// Delay before retrying a failed usage write: the debounce window doubled
    /// per consecutive failure, capped at `providerUsageRetryMaxInterval`. The
    /// first retry keeps the debounce window, so a single transient failure
    /// behaves exactly as it did before the backoff existed.
    nonisolated static func providerUsageRetryDelay(
        consecutiveFailures: Int
    ) -> TimeInterval {
        let failures = max(1, min(consecutiveFailures, 20))
        let doubled = providerUsageDebounceInterval * pow(2, Double(failures - 1))
        return min(doubled, providerUsageRetryMaxInterval)
    }

    // PERF: agent.item.started EventBus publish encodes AssistantItem on every
    // tool/assistant item during agent runs. Encode once then JSONSerialization +
    // JSONValue.from (avoids a second Codable walk). JSONEncoder is not
    // thread-safe — share one under a short lock instead of allocating per item.
    private static let assistantItemJSONEncodeLock = NSLock()
    private static let assistantItemJSONEncoder = JSONEncoder()

    private static func assistantItemJSON(_ item: AssistantItem) -> JSONValue {
        assistantItemJSONEncodeLock.lock()
        let data = try? assistantItemJSONEncoder.encode(item)
        assistantItemJSONEncodeLock.unlock()
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .null
        }
        return JSONValue.from(object)
    }

    /// Releases host-owned state after a cap transaction has committed its
    /// deletes. This deliberately has no EventBus/UI side effect: callers retain
    /// the existing delete-before-create publication order. A failed read or a
    /// restored row is not permission to cancel queue/provider ownership.
    func retireDeletedAgentThreads(
        _ ids: [AgentThreadID],
        coordinatorAlreadyRetired _: Bool = false
    ) {
        var seen: Set<AgentThreadID> = []
        let ordered = ids
            .filter { seen.insert($0).inserted }
            .sorted { $0.value.uuidString < $1.value.uuidString }
        for threadId in ordered {
            if pendingDeletedThreadRetirements[threadId] == nil {
                pendingDeletedThreadRetirements[threadId] = PendingDeletedThreadRetirement()
            }
        }
        drainPendingDeletedThreadRetirements()
        schedulePendingDeletedThreadRetirementRetry()
    }

    /// Drain in a stable order so concurrent cap/fork lifecycle paths cannot
    /// produce nondeterministic teardown. The coordinator is the sole durable
    /// verifier; AppContext clears queue ownership only after terminal retirement.
    private func drainPendingDeletedThreadRetirements() {
        let ordered = pendingDeletedThreadRetirements.keys.sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        for threadId in ordered {
            guard var pending = pendingDeletedThreadRetirements[threadId] else { continue }
            let outcome = coordinator.retireDeletedThreads(
                [threadId],
                scheduleRetries: false
            )[threadId] ?? .retryRequired
            switch outcome {
            case .retired:
                pendingDeletedThreadRetirements.removeValue(forKey: threadId)
                queueDrainWaiters.removeValue(forKey: threadId)?.task.cancel()
                queueDrainSuppressionLeases.removeValue(forKey: threadId)
                queueDispatchAcceptancePermits.removeValue(forKey: threadId)?.invalidate()
                deferredQueuePromotions.removeValue(forKey: threadId)
                appContextRuntimeLog.info(
                    "thread.retirement.outcome thread=\(threadId.value.uuidString, privacy: .public) outcome=retired"
                )
            case .confirmedPresent:
                // A restored row owns its queue/session state; only the stale
                // retirement candidate is terminally resolved.
                pendingDeletedThreadRetirements.removeValue(forKey: threadId)
                appContextRuntimeLog.info(
                    "thread.retirement.outcome thread=\(threadId.value.uuidString, privacy: .public) outcome=present"
                )
            case .retryRequired:
                if pending.retryLogged == false {
                    pending.retryLogged = true
                    pendingDeletedThreadRetirements[threadId] = pending
                    appContextRuntimeLog.info(
                        "thread.retirement.retry_pending thread=\(threadId.value.uuidString, privacy: .public)"
                    )
                }
            }
        }
    }

    private func schedulePendingDeletedThreadRetirementRetry() {
        guard deletedThreadRetirementRetryTask == nil,
              !pendingDeletedThreadRetirements.isEmpty else { return }
        deletedThreadRetirementRetryTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let delay = self?.deletedThreadRetirementRetryDelay(attempt: attempt) else {
                    return
                }
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled else { return }
                self.drainPendingDeletedThreadRetirements()
                guard !self.pendingDeletedThreadRetirements.isEmpty else {
                    self.deletedThreadRetirementRetryTask = nil
                    return
                }
                attempt = min(attempt + 1, 5)
            }
        }
    }

    private func deletedThreadRetirementRetryDelay(attempt: Int) -> UInt64 {
        #if DEBUG
        let baseDelay = deletedThreadRetirementRetryDelayNanosecondsForTesting
            ?? Self.deletedThreadRetirementRetryBaseDelayNanoseconds
        #else
        let baseDelay = Self.deletedThreadRetirementRetryBaseDelayNanoseconds
        #endif
        return min(
            baseDelay * UInt64(1 << min(attempt, 5)),
            Self.deletedThreadRetirementRetryMaximumDelayNanoseconds
        )
    }

    func enqueueRecoveredForkPrunedThreadIDs(_ ids: [AgentThreadID]) {
        // reconcileForkIntent already retired coordinator state immediately after
        // its local graph commit. Do the host queue portion even before a router
        // or Agent App surface exists; lifecycle publication remains deferred.
        retireDeletedAgentThreads(ids, coordinatorAlreadyRetired: true)
        pendingRecoveredForkPrunedThreadIDs.formUnion(ids)
        drainRecoveredForkPrunedThreadIDsIfPossible()
    }

    /// Interrupts the group turns a previous launch left running and resumes
    /// the planned and VM-waiting ones. The launch calls it once, after the
    /// event log is wired and its sequence restored, so iOS receives these
    /// changes from its cursor.
    public func reconcileBotGroupsAfterLaunch() {
        guard hostsBotGroupConversations, router != nil else { return }
        botGroupOrchestrator.reconcileAfterRelaunch()
    }

    /// Reloads the Distill session of every thread with a paused loop (any reason), so the
    /// scheduler re-announces its tasks. Failures leave the loop paused with the reason.
    public func resumeDistillLoopsAfterLaunch() {
        guard hostsBotGroupConversations else { return }
        let waiting = distillLoopStore.resumableThreadIDs()
        guard !waiting.isEmpty else { return }
        Task(priority: .utility) { @MainActor [weak self] in
            for threadId in waiting {
                guard let self else { return }
                await self.resumeDistillLoops(threadId: threadId)
            }
        }
    }

    /// Seeds the adapter with the stored history, reloads the session, and records a failed
    /// resume as a visible paused reason. Throws so a UI caller can show the error inline.
    @discardableResult
    public func resumeDistillLoops(threadId: AgentThreadID) async -> Error? {
        distillAdapter.seedLoops(threadId: threadId, loops: distillLoopStore.loops(for: threadId))
        do {
            try await coordinator.resumeSessionForScheduler(threadId: threadId)
            return nil
        } catch {
            let message = "Couldn't resume: \(error.localizedDescription)"
            let loops = distillLoopStore.loops(for: threadId).map { loop -> DistillLoopState in
                guard DistillLoopStore.resumable(loop) else { return loop }
                var failed = loop
                failed.pausedReason = error is AgentRunCoordinator.SchedulerResumeError
                    ? error.localizedDescription : message
                return failed
            }
            distillLoopStore.update(thread: threadId, loops: loops)
            return error
        }
    }

    private func drainRecoveredForkPrunedThreadIDsIfPossible() {
        guard let router, !pendingRecoveredForkPrunedThreadIDs.isEmpty else { return }
        let ids = pendingRecoveredForkPrunedThreadIDs.sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        pendingRecoveredForkPrunedThreadIDs.removeAll()
        router.publishAgentThreadDeletions(ids)
    }

    public init(
        channel: ReleaseChannel = .debug,
        dbPathOverride: String? = nil,
        appSupportOverride: String? = nil,
        accountUsageRefresher: ProviderAccountUsageRefreshing = ProviderAccountUsageRefresher(),
        privateAccountAPI: PrivateAccountAPI = URLSessionPrivateAccountAPI(),
        agentSkillsHomeOverrideForTesting: URL? = nil,
        /// Interactive RemoteCode must reconcile abandoned runs on launch.
        /// Background helpers that share the same SQLite (Scheduled Task Agent)
        /// must NOT flip every live interactive run to `interrupted`.
        performLaunchRunReconciliation: Bool = true,
        contextualSecretStore: any BotSecretStore = BotKeychainSecretStore(),
        guestDocker: any BotComputerDockerClienting = BotComputerDockerCLI(),
        titioVoice: (any TitioVoiceWriting)? = nil
    ) throws {
        self.channel = channel
        self.guestDocker = guestDocker
        self.contextualSecretStore = contextualSecretStore
        self.hostsBotGroupConversations = performLaunchRunReconciliation
        self.accountUsageRefresher = accountUsageRefresher
        self.agentSkillsHomeOverrideForTesting = agentSkillsHomeOverrideForTesting
        let bs = Bootstrap(channel: channel, dbPathOverride: dbPathOverride, appSupportOverride: appSupportOverride)
        let (rep, db) = try bs.run()
        self.bootstrapReport = rep
        self.appSupportDirectory = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
        self.db = db
        if db.path == ":memory:" {
            self.readDB = db
        } else {
            self.readDB = try SQLiteDB(path: db.path, readonly: true)
        }
        self.projectRepo = ProjectRepository(db: db)
        self.threadRepo = AgentThreadRepository(db: db, readDB: self.readDB)
        self.messageRepo = AgentMessageRepository(db: db)
        self.queuedMessageRepo = AgentQueuedMessageRepository(db: db)
        self.runRepo = AgentRunRepository(db: db, readDB: self.readDB)
        self.snapshotRepo = SessionSnapshotRepository(db: db)
        self.settingsRepo = SettingsRepository(db: db)
        self.eventLog = EventLogRepository(db: db)
        self.terminalOutputRepo = TerminalOutputRepository(db: db)
        TerminalSurface.replayPendingHistoryDeletes(repository: self.terminalOutputRepo)
        self.providerSessionRuntimeRepo = ProviderSessionRuntimeRepository(db: db)
        self.commandReceiptRepo = CommandReceiptRepository(db: db)
        self.providerPendingCallbackRepo = ProviderPendingCallbackRepository(db: db)
        self.proposedPlanRepo = AgentProposedPlanRepository(db: db)
        self.turnCheckpointRepo = AgentTurnCheckpointRepository(db: db)
        self.checkpointListGateway = AgentTurnCheckpointListGateway(db: db)
        self.agentThreadListGateway = AgentThreadListGateway(db: db, readDB: self.readDB)
        self.workspaceListGateway = WorkspaceListGateway(agentThreadListGateway: self.agentThreadListGateway)
        self.botStore = BotStore(db: db)
        let privatePushTargetStore = PrivatePushTargetStore(repo: self.settingsRepo)
        let privateNotificationBridge = PrivateNotificationBridge(
            accountStore: PrivateAccountSessionStore(repo: self.settingsRepo),
            pushTargetStore: privatePushTargetStore,
            api: privateAccountAPI
        )
        self.privateNotificationBridge = privateNotificationBridge
        let liveActivityIdentity = try LiveActivityIdentityStore.beginBoot(settings: self.settingsRepo)
        self.liveActivityHostIdentity = liveActivityIdentity
        self.titioNoticeCenter = TitioNoticeCenter(
            db: db,
            botStore: self.botStore,
            hooks: Self.makeTitioNoticeHooks(
                box: titioNoticeBox,
                db: db,
                botStore: self.botStore,
                messageRepo: self.messageRepo,
                runRepo: self.runRepo,
                bridge: privateNotificationBridge,
                hostID: liveActivityIdentity.serverId
            ),
            // Unit tests never spawn a real provider CLI.
            voice: titioVoice ?? (AppContext.isRunningUnitTests ? nil : Self.makeTitioVoiceWriter(box: titioNoticeBox, db: db))
        )
        titioNoticeCenter.installActions(Self.makeTitioNoticeActionHooks(
            box: titioNoticeBox,
            db: db,
            botStore: self.botStore
        ))
        privateNotificationBridge.setConnectionHintSources(
            hostId: { liveActivityIdentity.serverId },
            watermark: { String(EventBus.shared.currentSeq) },
            bootEpoch: { String(liveActivityIdentity.bootEpoch) }
        )
        // S-005a/S-006: Phase A silent wakes with silent_catchup.v1 wm/boot_epoch/since_seq.
        MaterialWakeCoordinator.shared.start(
            bridge: privateNotificationBridge,
            bootEpochProvider: { String(liveActivityIdentity.bootEpoch) },
            watermarkProvider: { String(EventBus.shared.currentSeq) }
        )
        // WHY: Mac relaunch invalidates every cached iOS surface/session view.
        // `host.boot_epoch` is the only `.silentForce` producer; without this
        // publish the force class has zero runtime coverage and suspended
        // phones never rebaseline on host restart.
        EventBus.shared.publish(
            kind: .hostBootEpoch,
            payload: .object([
                "boot_epoch": .number(Double(liveActivityIdentity.bootEpoch)),
                "server_id": .string(liveActivityIdentity.serverId),
            ])
        )
        let settingsRepo = self.settingsRepo
        let liveActivityAcceptanceOutbox = LiveActivityAcceptanceOutbox(
            store: LiveActivityAcceptanceOutboxStore(settings: settingsRepo),
            onError: { error, delivery in
                NSLog("Live Activity outbox error key=\(delivery?.idempotencyKey ?? "unknown"): \(error)")
            }
        ) { record in
            try await privateNotificationBridge.sendLiveActivityAcceptance(record)
        }
        self.liveActivityAcceptanceOutbox = liveActivityAcceptanceOutbox
        // Survive Mac app updates/relaunches: keep stored iOS push-to-start
        // tokens bound to this host identity before the sync coordinator boots.
        let reboundPushToStart = (try? privatePushTargetStore.rebindDurableTokens(
            toHostServerId: liveActivityIdentity.serverId
        )) ?? []
        do {
            _ = try privatePushTargetStore.pruneStaleActivityUpdateTargets()
        } catch {
            NSLog("Live Activity token prune failed during launch: \(error)")
        }
        self.liveActivitySyncCoordinator = LiveActivitySyncCoordinator(
            serverId: liveActivityIdentity.serverId,
            bootEpoch: liveActivityIdentity.bootEpoch,
            initialActivityGeneration: liveActivityIdentity.activityGeneration,
            initialTokenTargets: try privatePushTargetStore.records(),
            registerToken: { target in
                try privatePushTargetStore.upsert(target)
                try await privateNotificationBridge.registerLiveActivityTokenV2(target)
            },
            onTokenRegistrationError: { error, target in
                NSLog("Live Activity token registration failed device=\(target.deviceId): \(error)")
            },
            onDeliveryError: { error, delivery in
                NSLog("Live Activity durable acceptance failed key=\(delivery.idempotencyKey): \(error)")
            }
        ) { delivery in
            try LiveActivityIdentityStore.persistActivityGeneration(
                delivery.activityGeneration,
                settings: settingsRepo
            )
            let targets = try privateNotificationBridge.acceptanceTargets(for: delivery)
            try liveActivityAcceptanceOutbox.accept(delivery, targets: targets)
        }
        // Re-publish push-to-start tokens to the backend so a post-update Mac can
        // open Live Activities without the user launching iOS first.
        for target in reboundPushToStart {
            do {
                _ = try liveActivitySyncCoordinator.submitTokenRegistration(target)
            } catch {
                NSLog("Live Activity durable token restore failed device=\(target.deviceId): \(error)")
            }
        }
        let codex = CodexAppServerAdapter(binaryNameOverride: try? settingsRepo.get("cli.codex.path"))
        let configuredClaudeBinary = try? settingsRepo.get("cli.claude.path")
        let claudeEngine = ClaudeEnginePolicy.resolve(
            setting: (try? settingsRepo.get(ClaudeEnginePolicy.settingsKey)).flatMap { $0 },
            envOverride: ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_ENABLED"]
        )
        let claude: AgentProviderAdapter = AppContext.makeClaudeAdapter(engine: claudeEngine, binary: configuredClaudeBinary)
        let grok = GrokACPAdapter(binaryNameOverride: try? settingsRepo.get("cli.grok.path"))
        let distill = DistillACPAdapter(binaryNameOverride: try? settingsRepo.get("cli.distill.path"))
        self.distillAdapter = distill
        self.distillLoopStore = DistillLoopStore(directory: self.appSupportDirectory)
        let contextReference = WeakReference()
        self.orchestrationRuntime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: db),
            costEstimator: AgentOrchestrationRuntime.productionCostEstimator
        )
        self.coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providerSessionRepo: providerSessionRuntimeRepo,
            checkpointRepo: turnCheckpointRepo,
            orchestrationRuntime: self.orchestrationRuntime,
            providerSnapshotSupplier: {
                await contextReference.value?.router?.listAgentProviderSnapshots() ?? []
            },
            providerAdapters: [.codex: codex, .claude: claude, .grok: grok, .distill: distill]
        )
        let contextualBotStore = self.botStore
        let contextualAdmissions = self.contextualRunAdmissions
        // Only the internal isolated path scrubs the environment; a pinned thread otherwise runs like a normal bot thread.
        self.coordinator.botContextPinForThread = { [contextualBotStore, contextualAdmissions] threadID in
            guard contextualAdmissions.hasAdmission(threadID: threadID) else { return nil }
            return try contextualBotStore.conversationContextPin(linkedTo: threadID)
        }
        self.coordinator.onRecoveredForkPrunedThreadIDs = { [weak contextReference] ids in
            await MainActor.run {
                contextReference?.value?.enqueueRecoveredForkPrunedThreadIDs(ids)
            }
        }
        // plan-final W0: durable terminal ledger write-before-UI (diagnostics dir).
        let diagnosticsDir = self.appSupportDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        self.coordinator.terminalTransitionLedger = TerminalTransitionLedger(directory: diagnosticsDir)
        // A fresh Codex session (no resumable thread) is seeded with the prior
        // conversation; its receipts keep a restart from seeding twice.
        codex.contextSeedReceipts = self.runRepo.contextSeedReceipts()
        contextReference.value = self
        let guestRunResolver = makeBotGuestRunResolver(hostsGuestRuns: performLaunchRunReconciliation)
        botGuestRunResolver = guestRunResolver
        distill.setGuestLaunchResolver(guestRunResolver)
        let loopStore = self.distillLoopStore
        distill.onLoopsChanged = { threadId, loops in
            Task { @MainActor in loopStore.update(thread: threadId, loops: loops) }
        }
        distill.onProviderInitiatedTurn = { [weak contextReference] threadId, promptId, label in
            Task { @MainActor in
                await contextReference?.value?.router?.startProviderInitiatedTurn(
                    threadId: threadId, promptId: promptId, label: label)
            }
        }
        let liveActivitySyncCoordinator = self.liveActivitySyncCoordinator
        coordinator.onActiveRunProjectionChanged = { [weak contextReference] projection, cause in
            let syncCause: LiveActivitySyncCause
            switch cause {
            case .started:
                syncCause = .started
            case .finished(let status):
                syncCause = .finished(status)
            case .launchReconciliation:
                syncCause = .launchReconciliation
            }
            liveActivitySyncCoordinator.submit(projection, cause: syncCause)
            // Scheduled runs intentionally do not select/bind an Agent App tab. Keep
            // workspace-level chrome in parity with user-started runs by projecting
            // coordinator ownership independently of per-tab busy state.
            Task { @MainActor [weak contextReference] in
                contextReference?.value?.refreshActiveAgentWorkspaceProjection()
            }
        }
        liveActivityAcceptanceOutbox.resumePending()
        if performLaunchRunReconciliation {
            // Schedules run in-process. Prior-process provider sessions must be
            // interrupted on relaunch so scheduled_task_runs can finish instead of
            // being preserved forever as "foreign LaunchAgent" ownership.
            try coordinator.reconcileOnLaunch(preservingThreadIDs: [])
        } else {
            // Shared-DB background agents: never steal interactive ownership.
            // Publish an empty projection for this process only; leave durable
            // run/thread/session rows alone for the interactive host to own.
            coordinator.onActiveRunProjectionChanged?(
                ActiveRunProjection(runs: []),
                .launchReconciliation
            )
        }
        self.coordinator.recoveryEnvironmentProvider = { [weak self] provider, threadId in
            guard let self else { return [:] }
            return await MainActor.run {
                self.subagentTelemetryEnvironment(provider: provider, threadId: threadId)
            }
        }
        self.coordinator.runEnvironmentProvider = { [weak self] provider, threadId, base in
            guard let self else { return [:] }
            return await MainActor.run {
                self.subagentTelemetryEnvironment(
                    provider: provider,
                    threadId: threadId,
                    baseEnvironment: base
                )
            }
        }
        self.coordinator.autoContinuationClaimsBotVM = { [weak self] threadId, runId in
            await MainActor.run {
                self?.router?.claimBotVMForAutoContinuation(thread: threadId, runID: runId) ?? true
            }
        }
        self.coordinator.autoContinuationReleasesBotVM = { [weak self] runId in
            await MainActor.run { self?.router?.releaseBotVMRun(runId) }
        }
        _ = try providerPendingCallbackRepo.markOpenStale(
            reason: "Provider callback state does not survive app restarts or recovered sessions. Restart the turn to continue."
        )
        // The orchestration package is app-private and independent of Token Saver. Keep
        // XCTest isolated unless a sandboxed skills home was injected explicitly.
        if !AppContext.isRunningUnitTests || agentSkillsHomeOverrideForTesting != nil {
            reconcileRemoteCodeOrchestrate()
            reconcileComputerUseMCP()
        }
        // Token Saver was removed. The settings an older build persisted for it
        // (its API token among them) are dropped from the stored blob. Plain
        // unit tests keep their seeded settings; sandboxed-home tests and every
        // real launch, the isolated sandbox included, get the cleanup.
        if !AppContext.isRunningUnitTests || agentSkillsHomeOverrideForTesting != nil {
            dropLegacyTokenSaverSettings()
        }
        // The legacy purge touches the user's home, so it sits behind the same
        // gate as the always-on installs: skipped under XCTest unless a sandboxed
        // home was injected, and in processes that set
        // RC2_DISABLE_MANAGED_DISTILL_RECONCILE (isolated sandbox, scheduled-task agent).
        if AppContext.shouldReconcileManagedDistillIntegration(
            isRunningUnitTests: AppContext.isRunningUnitTests,
            hasSkillsHomeOverride: agentSkillsHomeOverrideForTesting != nil,
            environment: ProcessInfo.processInfo.environment
        ) {
            installAlwaysOnRouting(makeAgentSkillInstaller())
            startLegacyTokenSaverPurge()
        }

        // GAP-7: stream agent run lifecycle + timeline to the network
        // event bus so the iOS mirror renders agent output in real time
        // (kinds/payloads match the iOS MirrorEventReducer contract).
        func runtimeEventPayload(_ event: ProviderRuntimeEvent, threadId: String) -> JSONValue {
            var payload: [String: JSONValue] = [
                "thread_id": .string(threadId),
                "id": .string(event.id),
                "provider": .string(event.provider.rawValue),
                "source": .string(event.source),
                "method": .string(event.method),
                "payload_json": .string(event.payloadJSON),
                "received_at_ms": .number(Double(event.receivedAtMs))
            ]
            if let turn = event.providerTurnId { payload["provider_turn_id"] = .string(turn) }
            if let item = event.providerItemId { payload["provider_item_id"] = .string(item) }
            if let request = event.providerRequestId { payload["provider_request_id"] = .string(request) }
            return .object(payload)
        }
        func agentRunPayload(threadId: AgentThreadID, runId: AgentRunID? = nil, status: AgentRunStatus? = nil) -> JSONValue {
            var payload: [String: JSONValue] = ["thread_id": .string(threadId.value.uuidString.lowercased())]
            if let runId {
                payload["run_id"] = .string(runId.value.uuidString.lowercased())
                if let timing = try? runRepo.timing(of: runId) {
                    let startedAtMs = Int64(timing.startedAt.timeIntervalSince1970 * 1000)
                    payload["started_at_ms"] = .number(Double(startedAtMs))
                    payload["started_at"] = .number(Double(startedAtMs))
                    if let finishedAt = timing.finishedAt {
                        let finishedAtMs = Int64(finishedAt.timeIntervalSince1970 * 1000)
                        payload["finished_at_ms"] = .number(Double(finishedAtMs))
                        payload["duration_ms"] = .number(Double(max(0, finishedAtMs - startedAtMs)))
                    }
                }
            }
            let workspaceID: WorkspaceID? = try? threadRepo.workspaceId(of: threadId)
            payload["workspace_id"] = workspaceID.map {
                .string($0.value.uuidString.lowercased())
            } ?? .null
            if let status {
                payload["status"] = .string(status.rawValue)
            }
            return .object(payload)
        }
        // 1.7: onRunStarted + .threadStarted both mapped to agent.run.started.
        // Dedup by (threadId, runId) so one logical run emits one event even
        // though coordinator fires both callbacks within the same turn. Resume
        // paths only emit .threadStarted, so onRunStarted becomes the single
        // source for new runs.
        let runStartedDeduplicator = AgentRunStartedDeduplicator()
        // agent.run.error's action wins for its run (see AgentRunErrorWire).
        let runErrorActions = AgentRunErrorActionLedger()
        coordinator.onRunStarted = { tid, runId in
            guard runStartedDeduplicator.insert(threadID: tid, runID: runId) else { return }
            EventBus.shared.publish(kind: .agentRunStarted,
                                    payload: agentRunPayload(threadId: tid, runId: runId))
        }
        coordinator.onMessageAppended = { message in
            // Bounded wire policy: never put a multi-MiB body into EventBus.
            EventBus.shared.publish(
                kind: .agentMessageAppended,
                payload: AgentMessageTransport.appendedEventPayload(from: message)
            )
        }
        coordinator.onAssistantEvent = { ev, tid, runId in
            let t = tid.value.uuidString.lowercased()
            switch ev {
            case .threadStarted(let eventThreadId, let providerThreadId):
                guard runStartedDeduplicator.insert(threadID: tid, runID: runId) else {
                    // agent.run.started went out before the coordinator committed
                    // this provider cursor; mirror the cursor write itself, but only
                    // when it actually landed.
                    let cursor = providerThreadId ?? eventThreadId
                    if (try? self.threadRepo.providerThreadId(of: tid)) == cursor,
                       let updatedAt = try? self.threadRepo.updatedAt(of: tid) {
                        AgentThreadChromeWrite(
                            threadID: tid, providerThreadID: cursor, updatedAt: updatedAt
                        ).publish()
                    }
                    break
                }
                EventBus.shared.publish(kind: .agentRunStarted, payload: agentRunPayload(threadId: tid, runId: runId))
            case .turnStarted(let turnId):
                EventBus.shared.publish(kind: .agentTurnStarted,
                                        payload: .object(["thread_id": .string(t), "turn_id": .string(turnId)]))
            case .itemStarted(let item):
                EventBus.shared.publish(kind: .agentItemStarted,
                                        payload: .object(["thread_id": .string(t), "item": Self.assistantItemJSON(item)]))
            case .itemDelta(let itemId, let bodyAppend, let outputAppend, let summary):
                var p: [String: JSONValue] = ["thread_id": .string(t), "item_id": .string(itemId)]
                p["run_id"] = .string(runId.value.uuidString.lowercased())
                if let b = bodyAppend { p["body_append"] = .string(b) }
                if let o = outputAppend { p["output_append"] = .string(o) }
                if let s = summary { p["summary"] = .string(s) }
                EventBus.shared.publish(kind: .agentItemDelta, payload: .object(p))
            case .itemHostMetadata:
                // Decode-only: never minted since Token Saver was removed.
                break
            case .itemState(let itemId, let state):
                if state != .streaming {
                    EventBus.shared.publish(kind: .agentItemCompleted,
                                            payload: .object(["thread_id": .string(t), "item_id": .string(itemId)]))
                }
            case .itemProgress(let itemId, let progress):
                var p: [String: JSONValue] = ["thread_id": .string(t), "item_id": .string(itemId)]
                p["run_id"] = .string(runId.value.uuidString.lowercased())
                if let progress { p["progress"] = .number(progress) }
                EventBus.shared.publish(kind: .agentItemProgress, payload: .object(p))
            case .itemCompleted(let itemId, let state):
                EventBus.shared.publish(kind: .agentItemCompleted,
                                        payload: .object(["thread_id": .string(t), "item_id": .string(itemId), "state": .string(state.rawValue)]))
            case .turnCompleted(let turnId, let final):
                var p: [String: JSONValue] = ["thread_id": .string(t), "turn_id": .string(turnId)]
                if let f = final { p["final"] = .string(f) }
                EventBus.shared.publish(kind: .agentTurnCompleted, payload: .object(p))
                self.liveActivitySyncCoordinator.submitHeartbeat()
            case .proposedPlan(let plan):
                try? self.proposedPlanRepo.upsert(threadId: tid, plan: plan)
                var planPayload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "plan_id": .string(plan.id),
                    "markdown": .string(plan.markdown)
                ]
                if let turnId = plan.turnId { planPayload["turn_id"] = .string(turnId) }
                EventBus.shared.publish(kind: .agentPlanProposed, payload: .object(planPayload))
            case .activePlanUpdated(let plan):
                var payload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "steps": .array(plan.steps.map { step in
                        .object([
                            "id": .string(step.id),
                            "title": .string(step.title),
                            "status": .string(step.status.rawValue)
                        ])
                    }),
                    "updated_at_ms": .number(Double(plan.updatedAtMs))
                ]
                if let explanation = plan.explanation { payload["explanation"] = .string(explanation) }
                EventBus.shared.publish(kind: .agentPlanActiveUpdated, payload: .object(payload))
            case .requestOpened(let request):
                do {
                    try self.providerPendingCallbackRepo.record(threadId: tid, request: request)
                } catch {
                    // The row is what the paired device hydrates; log instead of
                    // letting a failed write vanish (the live stream still has it).
                    appContextRuntimeLog.error(
                        "provider_pending_callback.record_failed kind=approval thread=\(t, privacy: .public) request=\(request.id, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
                var requestPayload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "request_id": .string(request.id),
                    "run_id": .string(runId.value.uuidString),
                    "allows_session_approval": .bool(request.allowsSessionApproval),
                    "kind": .string(request.kind.rawValue),
                    "title": .string(request.title),
                    "detail": request.detail.map(JSONValue.string) ?? .null
                ]
                if let turnId = request.turnId { requestPayload["turn_id"] = .string(turnId) }
                EventBus.shared.publish(kind: .agentRequestOpened, payload: .object(requestPayload))
                // Visible push for main-agent approvals only (subagents stay quiet).
                self.postAgentUserActionPushIfNeeded(
                    threadId: tid,
                    runId: runId,
                    requestId: request.id,
                    facts: TitioRequestFacts(
                        kind: .approval,
                        legacyActionTitle: "Approve: \(PetApprovalActionLabel.label(for: request.kind))",
                        requestTitle: request.title,
                        detail: request.detail,
                        allowsSessionApproval: request.allowsSessionApproval,
                        requestKind: request.kind.rawValue
                    )
                )
            case .requestResolved(let requestId, let state):
                do {
                    try self.providerPendingCallbackRepo.resolve(threadId: tid, requestId: requestId, kind: .approval, state: state)
                } catch {
                    // A resolve that does not land leaves the request pending for the
                    // paired device's next hydrate; never swallow that silently.
                    appContextRuntimeLog.error(
                        "provider_pending_callback.resolve_failed kind=approval thread=\(t, privacy: .public) request=\(requestId, privacy: .public) state=\(state.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
                EventBus.shared.publish(kind: .agentRequestResolved, payload: .object([
                    "thread_id": .string(t),
                    "request_id": .string(requestId),
                    "run_id": .string(runId.value.uuidString),
                    "state": .string(state.rawValue)
                ]))
                // A Titio card for this request is now stale (§5 "Request resolutions").
                self.titioNoticeCenter.sourceResolved(
                    key: TitioNoticeIDs.threadAttention(threadId: tid.value.uuidString, requestId: requestId, runId: runId.value.uuidString)
                )
            case .userInputRequested(let request):
                do {
                    try self.providerPendingCallbackRepo.record(threadId: tid, userInput: request)
                } catch {
                    appContextRuntimeLog.error(
                        "provider_pending_callback.record_failed kind=user_input thread=\(t, privacy: .public) request=\(request.id, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
                var userInputPayload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "request_id": .string(request.id),
                    "run_id": .string(runId.value.uuidString),
                    "prompt": .string(request.prompt),
                    "options": .array(request.options.map(JSONValue.string)),
                    "allows_multiple_selection": .bool(request.allowsMultipleSelection),
                    "is_secret": .bool(request.isSecret),
                    // Structured AskUserQuestion payload: without it iOS can only
                    // render a degraded flat prompt for multi-question requests.
                    "questions": .array(request.questions.map { question in
                        var q: [String: JSONValue] = [
                            "id": .string(question.id),
                            "prompt": .string(question.prompt),
                            "options": .array(question.options.map { option in
                                var o: [String: JSONValue] = ["label": .string(option.label)]
                                if let detail = option.detail { o["detail"] = .string(detail) }
                                return .object(o)
                            }),
                            "allows_multiple_selection": .bool(question.allowsMultipleSelection)
                        ]
                        if let header = question.header { q["header"] = .string(header) }
                        return .object(q)
                    })
                ]
                if let turnId = request.turnId { userInputPayload["turn_id"] = .string(turnId) }
                EventBus.shared.publish(kind: .agentUserInputRequested, payload: .object(userInputPayload))
                let singleQuestion = request.questions.count == 1 ? request.questions.first : nil
                let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? singleQuestion?.prompt : request.prompt
                let options = request.options.isEmpty ? singleQuestion?.options.map(\.label) ?? [] : request.options
                let multiple = request.allowsMultipleSelection || singleQuestion?.allowsMultipleSelection == true
                self.postAgentUserActionPushIfNeeded(
                    threadId: tid,
                    runId: runId,
                    requestId: request.id,
                    facts: TitioRequestFacts(
                        kind: .userInput,
                        legacyActionTitle: request.isSecret ? "Secret input requested" : "Input requested",
                        prompt: prompt,
                        // A one-tap card cannot pick several options: multi-select answers as text.
                        options: multiple ? nil : options,
                        isSecret: request.isSecret,
                        questionCount: request.questions.count
                    )
                )
            case .userInputResolved(let requestId, let answer):
                do {
                    try self.providerPendingCallbackRepo.resolve(threadId: tid, requestId: requestId, kind: .userInput, state: .resolved)
                } catch {
                    appContextRuntimeLog.error(
                        "provider_pending_callback.resolve_failed kind=user_input thread=\(t, privacy: .public) request=\(requestId, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
                EventBus.shared.publish(kind: .agentUserInputResolved, payload: .object([
                    "thread_id": .string(t),
                    "request_id": .string(requestId),
                    "run_id": .string(runId.value.uuidString),
                    "answer": answer.map(JSONValue.string) ?? .null
                ]))
                self.titioNoticeCenter.sourceResolved(
                    key: TitioNoticeIDs.threadAttention(threadId: tid.value.uuidString, requestId: requestId, runId: runId.value.uuidString)
                )
            case .tokenUsage(let usage):
                self.recordProviderTokenUsage(usage, runId: runId)
                var p: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "input_tokens": .number(Double(usage.inputTokens)),
                    "output_tokens": .number(Double(usage.outputTokens)),
                    "total_tokens": .number(Double(usage.totalTokens)),
                    "semantics": .string(usage.resolvedSemantics.rawValue)
                ]
                if let window = usage.contextWindow { p["context_window"] = .number(Double(window)) }
                if let compactsAutomatically = usage.compactsAutomatically {
                    p["compacts_automatically"] = .bool(compactsAutomatically)
                }
                // Cache-token split (G3): mirrors the billed-unit breakdown so
                // remote clients can compute net dollars like the mac does.
                if let uncached = usage.uncachedInputTokens {
                    p["uncached_input_tokens"] = .number(Double(uncached))
                }
                if let creation = usage.cacheCreationInputTokens {
                    p["cache_creation_input_tokens"] = .number(Double(creation))
                }
                if let read = usage.cacheReadInputTokens {
                    p["cache_read_input_tokens"] = .number(Double(read))
                }
                EventBus.shared.publish(kind: .agentThreadTokenUsage, payload: .object(p))
            case .accountUsage(let usage):
                self.recordAccountUsage(usage)
                self.publishAccountUsage(threadId: t, usage: usage)
            case .contextCompaction(let summary):
                EventBus.shared.publish(kind: .agentContextCompaction, payload: .object([
                    "thread_id": .string(t),
                    "summary": summary.map(JSONValue.string) ?? .null
                ]))
            case .providerRuntime(let event):
                EventBus.shared.publish(kind: .agentProviderRuntimeEvent, payload: runtimeEventPayload(event, threadId: t))
            case .wireTranslation(let translation):
                var payload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "original_text": .string(AssistantTimelineState.cappedText(translation.originalText)),
                    "rewritten_text": .string(AssistantTimelineState.cappedText(translation.rewrittenText)),
                    "protocol_version": .string(translation.protocolVersion)
                ]
                if let itemId = translation.itemId { payload["item_id"] = .string(itemId) }
                if let messageId = translation.messageId { payload["message_id"] = .string(messageId) }
                if let fallbackReason = translation.fallbackReason { payload["fallback_reason"] = .string(fallbackReason) }
                if let wireRequestText = translation.wireRequestText {
                    payload["wire_request_text"] = .string(AssistantTimelineState.cappedText(wireRequestText))
                }
                EventBus.shared.publish(kind: .agentWireTranslation, payload: .object(payload))
            case .sr1Translation(let translation):
                // Historical replay only: paired clients still need to render
                // persisted pre-RCW1 transcript rows. Texts remain capped.
                var sr1Payload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "original_text": .string(AssistantTimelineState.cappedText(translation.originalText)),
                    "rewritten_text": .string(AssistantTimelineState.cappedText(translation.rewrittenText))
                ]
                if let itemId = translation.itemId { sr1Payload["item_id"] = .string(itemId) }
                if let messageId = translation.messageId { sr1Payload["message_id"] = .string(messageId) }
                EventBus.shared.publish(kind: .agentSR1Translation, payload: .object(sr1Payload))
            case .error(let message, let recoverable):
                // Carry the provider error text + recoverability so remote
                // clients can show the reason and a Retry affordance instead
                // of a bare FAIL badge.
                var errorPayload = agentRunPayload(threadId: tid, runId: runId).objectValue ?? [:]
                let errorFields = AgentRunErrorWire.errorEventFields(message: message, recoverable: recoverable)
                errorPayload.merge(errorFields) { $1 }
                runErrorActions.record(runId: runId, action: errorFields["recovery_action"] ?? .null)
                EventBus.shared.publish(kind: .agentRunError, payload: .object(errorPayload))
            }
        }
        coordinator.onRunFinished = { [weak self] tid, rid, status in
            if let self {
                BotContextGuestResources.requestFinish(
                    runID: rid, threadID: tid, store: self.botStore, appSupport: self.appSupportDirectory
                )
            }
            let retainsVMClaim = self?.botGuestRunResolver?.retainsExclusiveVMClaim(runID: rid) == true
            let nextWaiting = retainsVMClaim ? nil : BotVMRunRegistry.shared.releaseAndNextWaiter(runID: rid)
            let streamErrorAction = runErrorActions.take(runId: rid)
            // Read before the hop: closing a side chat stops its run and deletes
            // the row right after this callback returns.
            let isSideThread = (try? self?.threadRepo.isEphemeral(of: tid)) ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The hand-off starts the next thread (VM preflight, guest
                // launch) and can take minutes; it must never hold back this
                // run's terminal events, drain waiter or notification. Spawned
                // first so its synchronous start still runs ahead of this
                // thread's own queue drain.
                if let nextWaiting {
                    Task { @MainActor [weak self] in
                        await self?.router?.handOffBotVM(botID: nextWaiting.botID, to: nextWaiting.threadID)
                    }
                }
                let kind: RemoteCodeEventKind = status == .completed
                    ? .agentRunCompleted
                    : .agentRunFailed
                var failedPayload = agentRunPayload(threadId: tid, runId: rid, status: status)
                if kind == .agentRunFailed {
                    let storedMessage = status == .failed ? (try? self.runRepo.errorMessage(of: rid)) ?? nil : nil
                    var obj = failedPayload.objectValue ?? [:]
                    obj.merge(AgentRunErrorWire.failedEventFields(
                        status: status,
                        storedMessage: storedMessage,
                        streamErrorAction: streamErrorAction
                    )) { $1 }
                    failedPayload = .object(obj)
                }
                if isSideThread {
                    // The phone does not list side threads: their finish wakes no
                    // phone, so it takes no slot of the hourly silent-wake budget.
                    MaterialWakeCoordinator.shared.muteTerminalWake(runId: rid.value.uuidString.lowercased())
                }
                EventBus.shared.publish(kind: kind, payload: kind == .agentRunFailed ? failedPayload : agentRunPayload(threadId: tid, runId: rid, status: status))
                EventBus.shared.publish(kind: .agentRunFinished, payload: agentRunPayload(threadId: tid, runId: rid, status: status))
                // Flush any debounced usage for this run now that the run is done so
                // the final token batch is never stranded in the accumulator.
                self.finishPendingProviderUsage(runId: rid)
                // Grok has no live `.accountUsage` stream (Claude/Codex do). Re-read
                // the local billing snapshot after each Grok run so the account
                // usage ring updates without waiting for the next periodic probe.
                if (try? self.runRepo.provider(of: rid)) == .grok {
                    self.refreshGrokAccountUsage(reason: "run_finished")
                }
                // Drain the next queued message after ANY terminal status. stopRun
                // can publish its host terminal before a provider-native interrupt
                // makes the adapter idle. Wait through that bounded cancellation
                // window; otherwise Force gets one premature drain and the promoted
                // message remains stranded with no later lifecycle callback.
                self.cancelQueueDrainWaiter(threadId: tid)
                self.ensureQueueDrainWaiterIfNeeded(threadId: tid)
                if let router = self.router { await router.startPendingProviderWake(threadId: tid) }
                // The host stopped a bot that asked the user to step in: the phone already
                // has "Waiting for you", so the same pause sends no "Thread cancelled".
                let pausedForUser = status == .cancelled && self.router?.botThreadAwaitsUser(tid) == true
                // Main agent only: nested/subagent workers must not fire
                // system or private push banners (parent owns user-facing UX).
                // The notification is the last effect of this hop; its reads
                // (including the receipt scan under the process-wide receipt
                // lock) run off the MainActor. Runs finishing close together
                // gather concurrently, but each post waits for the previous
                // one so banners and grouped outcomes keep callback order.
                let previousPost = self.runFinishedNotificationPostTail
                self.runFinishedNotificationPostTail = Task { @MainActor in
                    let inputs = await self.runFinishedNotificationInputs(runId: rid, threadId: tid)
                    await previousPost?.value
                    let chrome = inputs.chrome
                    let notificationSettings = inputs.settings
                    if let content = RemoteCodeNotificationContent.threadOutcome(
                        threadId: tid.value.uuidString,
                        runId: rid.value.uuidString,
                        workspaceId: chrome?.workspaceId?.value.uuidString,
                        title: chrome?.title,
                        phase: status,
                        isNestedWorker: inputs.isNestedWorker,
                        finalMessageId: inputs.finalMessageId
                    ) {
                        let isFailureOrInterrupted = status == .failed || status == .interrupted
                        let isUserStop = status == .cancelled
                        let allowed = RemoteCodeNotificationContent.AgentAppPushPolicy.allowsNotification(
                            isAction: isFailureOrInterrupted || isUserStop,
                            workspaceId: chrome?.workspaceId?.value.uuidString,
                            settings: notificationSettings
                        )
                        // Titio hub branch (§5): the policy checks above stay
                        // first; a user stop and pausedForUser never notify.
                        if !isUserStop, !pausedForUser, !isSideThread,
                           self.titioNoticeCenter.isEnabled(notificationSettings),
                           self.ingestTitioRunOutcome(
                               threadId: tid,
                               runId: rid,
                               status: status,
                               workspaceId: chrome?.workspaceId,
                               threadTitle: chrome?.title,
                               finalMessageId: inputs.finalMessageId,
                               facts: inputs.titio,
                               legacy: content
                           ) {
                            return
                        }
                        if allowed {
                            if isFailureOrInterrupted {
                                SystemNotifier.shared.post(content, settings: notificationSettings)
                            } else if !isUserStop {
                                SystemNotifier.shared.postOutcomeGrouped(
                                    content,
                                    workspaceId: chrome?.workspaceId?.value.uuidString,
                                    settings: notificationSettings,
                                    remoteDelivery: !isSideThread && status == .completed ? { [weak bridge = self.privateNotificationBridge] grouped in
                                        Task { await bridge?.deliverThreadOutcomeRemote(grouped, phase: .completed) }
                                    } : nil
                                )
                            }
                            if !isSideThread && status != .completed && !pausedForUser {
                                Task {
                                    await self.privateNotificationBridge.deliverThreadOutcomeRemote(
                                        content,
                                        phase: status
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        coordinator.onProviderIdle = { [weak self] threadId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Adapters finalize their resident-session status immediately
                // after returning from the terminal callback.
                await Task.yield()
                await self.providerBecameIdle(threadId: threadId)
                if let router = self.router { await router.startPendingProviderWake(threadId: threadId) }
            }
        }

        // HC-1: stream terminal/surface frames to the mirror so iOS renders
        // a live terminal (not a poll). PTY bytes are base64; idle geometry
        // changes use the same monotonic per-surface sequence without bytes.
        SurfaceOutputBus.shared.sink = { frame in
            let key = frame.surfaceID.value.uuidString
            var payload: [String: JSONValue] = [
                "surface_id": .string(key),
                "seq": .number(Double(frame.sequence))
            ]
            if !frame.data.isEmpty {
                payload["base64"] = .string(frame.data.base64EncodedString())
            }
            if let rows = frame.rows, let cols = frame.cols {
                payload["rows"] = .number(Double(rows))
                payload["cols"] = .number(Double(cols))
            }
            EventBus.shared.publish(kind: .surfaceOutput, payload: .object(payload))
        }
        LocalGitActivityBus.shared.sink = { activity in
            guard let kind = RemoteCodeEventKind(rawValue: activity.kind),
                  [.gitCheckout, .gitBranchCreated, .gitCommit, .gitPush].contains(kind) else {
                return
            }
            EventBus.shared.publish(kind: kind, payload: .object([
                "workspace_id": .string(activity.workspaceID.value.uuidString),
                "surface_id": .string(activity.surfaceID.value.uuidString),
                "ok": .bool(activity.succeeded)
            ]))
        }
        let projectScriptRuns = self.projectScriptRuns
        SurfaceRuntimeBus.shared.sink = { sid, health in
            let projectScriptOutcome = projectScriptRuns.consumeTerminalDeath(surfaceID: sid, health: health)
            Task { @MainActor [weak self] in
                if self?.router?.promoteWorkspaceContainingBusySurface(sid) != true {
                    self?.router?.windowController?.refreshSurfaceRuntimeState()
                }
            }
            EventBus.shared.publish(kind: .surfaceHealth, payload: .object([
                "surface_id": .string(sid.value.uuidString),
                "alive": .bool(health.alive),
                "process_alive": .bool(health.processAlive),
                "child_pid": health.childPID.map { .number(Double($0)) } ?? .null,
                "exit_status": health.exitStatus.map { .number(Double($0)) } ?? .null,
                "termination_signal": health.terminationSignal.map { .number(Double($0)) } ?? .null,
                "pty_open": .bool(health.ptyOpen),
                "input_accepting": .bool(health.inputAccepting),
                "terminal_dead_reason": health.terminalDeadReason.map { .string($0) } ?? .null,
                "last_output_at": health.lastOutputAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                "output_partial": .bool(health.outputPartial),
                "partial_reason": health.outputPartialReason.map { .string($0) } ?? .null,
                "output_pending_bytes": .number(Double(health.outputPendingBytes)),
                "history_write_failures": .number(Double(health.historyWriteFailures)),
                "dropped_output_bytes": .number(Double(health.droppedOutputBytes)),
                "rows": .number(Double(health.rows)),
                "cols": .number(Double(health.cols))
            ]))
            if let outcome = projectScriptOutcome {
                EventBus.shared.publish(kind: .projectScriptFinished, payload: .object([
                    "workspace_id": .string(outcome.workspaceID.value.uuidString),
                    "surface_id": .string(outcome.surfaceID.value.uuidString),
                    "name": .string(outcome.name),
                    "exit_code": outcome.exitCode.map { .number(Double($0)) } ?? .null,
                    "duration_ms": .number(Double(outcome.durationMilliseconds)),
                    "result": .string(outcome.result)
                ]))
            }
        }

        // Flush any pending debounced usage writes before the process exits so no
        // token counts are lost at quit. The observer fires on MainActor (same as
        // AppContext), so `self` access is safe. NotificationCenter retains the
        // observer token; it lives as long as the app process does.
        if !AppContext.isRunningUnitTests {
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = self?.prepareForApplicationTermination()
                }
            }
            // Late iOS WS subscribers: re-push the account usage digest.
            NotificationCenter.default.addObserver(
                forName: EventBus.subscriberAddedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Prefer cached body (no disk). If never published this
                    // process, build once from disk so first connect still works.
                    if AccountUsageWidgetDigest.lastCachedBody() != nil {
                        AccountUsageWidgetDigest.republishLast()
                    } else {
                        self.publishAccountUsageDigestFromDisk()
                    }
                }
            }
            // Seed sticky digest at launch so the first remote subscriber has
            // something to replay even before the sidebar opens.
            Task { @MainActor [weak self] in
                self?.publishAccountUsageDigestFromDisk()
            }
            // Usage events (already throttled where they are posted) must reach
            // the iOS widget digest without waiting for the next account poll.
            NotificationCenter.default.addObserver(
                forName: .rc2AccountUsageChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishAccountUsageDigestFromDisk()
                }
            }
        }

        // restore last snapshot if any
        if let snap = try snapshotRepo.latest() {
            self.state = snap.layout
        }
    }

    /// Settings CLI-path commits replace the live Codex adapter through this owner.
    func replaceCodexProviderAdapter(_ adapter: CodexAppServerAdapter) {
        adapter.contextSeedReceipts = runRepo.contextSeedReceipts()
        coordinator.replaceProviderAdapter(.codex, adapter: adapter)
    }

    deinit {
        deletedThreadRetirementRetryTask?.cancel()
    }

    /// True while this process's shared coordinator owns any run in the workspace.
    /// Unlike AgentAppSurface.isBusy, this is deliberately workspace-wide so a
    /// headless scheduled thread and an interactively selected thread drive the
    /// same workspace spinner without making unrelated Agent App tabs spin.
    public func hasActiveAgentRun(in workspaceID: WorkspaceID) -> Bool {
        activeAgentThreadTitlesByWorkspace[workspaceID] != nil
    }

    /// Titles for workspace-level busy help/VoiceOver copy. The cache is refreshed
    /// once per coordinator lifecycle transition, never from a SwiftUI body read.
    public func activeAgentThreadTitles(in workspaceID: WorkspaceID) -> [String] {
        activeAgentThreadTitlesByWorkspace[workspaceID] ?? []
    }

    private func refreshActiveAgentWorkspaceProjection() {
        let activeThreadIDs = coordinator.activeThreadIdsSnapshot()
        let activeCount = activeThreadIDs.count
        let previousActiveCount = lastPublishedActiveThreadCount
        let cachedThreadIDs = Set(activeAgentThreadContextByID.keys)

        for threadID in cachedThreadIDs.subtracting(activeThreadIDs) {
            activeAgentThreadContextByID.removeValue(forKey: threadID)
        }
        let newlyActiveThreadIDs = activeThreadIDs.subtracting(cachedThreadIDs).sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        if !newlyActiveThreadIDs.isEmpty {
            let chromeByID = (try? threadRepo.listChrome(ids: newlyActiveThreadIDs)) ?? [:]
            for threadID in newlyActiveThreadIDs {
                guard let chrome = chromeByID[threadID],
                      let workspaceID = chrome.workspaceId else { continue }
                activeAgentThreadContextByID[threadID] = ActiveAgentThreadContext(
                    workspaceID: workspaceID,
                    title: chrome.title
                )
            }
        }

        var projected: [WorkspaceID: [String]] = [:]
        let orderedThreadIDs = activeAgentThreadContextByID.keys.sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        for threadID in orderedThreadIDs {
            guard let context = activeAgentThreadContextByID[threadID] else { continue }
            projected[context.workspaceID, default: []].append(context.title)
        }
        // WHY: Active Threads sidebar badge uses host snapshot count, not the
        // workspace-title map. Threads without workspaceId never enter the map,
        // so count-only transitions must still refresh sidebar chrome.
        let titlesChanged = projected != activeAgentThreadTitlesByWorkspace
        let countChanged = previousActiveCount != activeCount
        guard titlesChanged || countChanged else { return }
        if titlesChanged {
            activeAgentThreadTitlesByWorkspace = projected
        }
        lastPublishedActiveThreadCount = activeCount
        router?.windowController?.refreshSurfaceRuntimeState()
    }

    func ensureQueueDrainWaiterIfNeeded(threadId: AgentThreadID) {
        guard queueDrainAllowsWork(threadId: threadId) else { return }
        guard let queuedMessages = try? queuedMessageRepo.list(threadId: threadId),
              !queuedMessages.isEmpty else {
            cancelQueueDrainWaiterIfQueueEmpty(threadId: threadId)
            return
        }
        guard queueDrainWaiters[threadId] == nil else { return }
        let timeout = Duration.seconds(max(0.001, queueDrainProviderIdleTimeout))
        let token = UUID()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let queueDrainSleepForTesting = self.queueDrainSleepForTesting {
                    _ = try await queueDrainSleepForTesting(threadId, timeout)
                } else {
                    try await ContinuousClock().sleep(for: timeout)
                }
            } catch {
                return
            }
            guard self.queueDrainWaiters[threadId]?.token == token,
                  self.queueDrainAllowsWork(threadId: threadId),
                  self.coordinator.hasProviderSession(threadId: threadId) else { return }
            switch try? self.threadRepo.status(of: threadId) {
            case .completed, .failed, .cancelled, .interrupted:
                EventBus.shared.publish(kind: .agentMessageQueueFailed, payload: .object([
                    "thread_id": .string(threadId.value.uuidString),
                    "message": .string("Provider is still stopping. The queued message remains safe and will start when the provider becomes idle.")
                ]))
            case .pending, .running, nil:
                break
            }
        }
        queueDrainWaiters[threadId] = QueueDrainWaiter(token: token, task: task)
        if !coordinator.hasProviderSession(threadId: threadId) {
            Task { @MainActor [weak self] in
                await self?.finishScheduledQueueDrain(threadId: threadId, token: token)
            }
        }
    }

    private func providerBecameIdle(threadId: AgentThreadID) async {
        guard let waiter = queueDrainWaiters[threadId],
              !coordinator.hasProviderSession(threadId: threadId) else { return }
        await finishScheduledQueueDrain(threadId: threadId, token: waiter.token)
    }

    private func finishScheduledQueueDrain(threadId: AgentThreadID, token: UUID) async {
        guard queueDrainWaiters[threadId]?.token == token,
              queueDrainAllowsWork(threadId: threadId),
              !Task.isCancelled else {
            removeQueueDrainWaiter(threadId: threadId, token: token)
            return
        }
        defer { removeQueueDrainWaiter(threadId: threadId, token: token) }
        if let queueDrainBeforeDispatchForTesting {
            await queueDrainBeforeDispatchForTesting()
        }
        guard queueDrainAllowsWork(threadId: threadId), !Task.isCancelled else { return }
        do {
            try await router?.drainNextQueuedAgentMessage(thread: threadId)
        } catch is CancellationError {
            return
        } catch {
            EventBus.shared.publish(kind: .agentMessageQueueFailed, payload: .object([
                "thread_id": .string(threadId.value.uuidString),
                "message": .string(String(describing: error))
            ]))
        }
    }

    func cancelQueueDrainWaiterIfQueueEmpty(threadId: AgentThreadID) {
        // An unreadable queue is not an empty one. The waiter and the promotion it
        // owns are live scheduling state and the rows are still there to read
        // again, so a transient read failure retains both — same rule as
        // `pendingDeletedThreadRetirements`.
        guard let queued = try? queuedMessageRepo.list(threadId: threadId),
              queued.isEmpty else { return }
        deferredQueuePromotions.removeValue(forKey: threadId)
        cancelQueueDrainWaiter(threadId: threadId)
    }

    func cancelQueueDrainWaiter(threadId: AgentThreadID) {
        queueDrainWaiters.removeValue(forKey: threadId)?.task.cancel()
    }

    func registerQueueDispatchAcceptancePermit(
        _ permit: AgentRunAcceptancePermit,
        threadId: AgentThreadID
    ) {
        queueDispatchAcceptancePermits[threadId]?.invalidate()
        queueDispatchAcceptancePermits[threadId] = permit
    }

    func unregisterQueueDispatchAcceptancePermit(
        _ permit: AgentRunAcceptancePermit,
        threadId: AgentThreadID
    ) {
        guard queueDispatchAcceptancePermits[threadId] === permit else { return }
        queueDispatchAcceptancePermits.removeValue(forKey: threadId)
    }

    func deferQueuePromotion(
        id: AgentQueuedMessageID,
        after ownerId: AgentQueuedMessageID,
        threadId: AgentThreadID
    ) {
        deferredQueuePromotions[threadId] = DeferredQueuePromotion(
            ownerId: ownerId,
            targetId: id
        )
    }

    func deferredQueuePromotion(
        threadId: AgentThreadID,
        ownerId: AgentQueuedMessageID
    ) -> AgentQueuedMessageID? {
        guard deferredQueuePromotions[threadId]?.ownerId == ownerId else { return nil }
        return deferredQueuePromotions[threadId]?.targetId
    }

    func clearDeferredQueuePromotion(
        threadId: AgentThreadID,
        ownerId: AgentQueuedMessageID
    ) {
        guard deferredQueuePromotions[threadId]?.ownerId == ownerId else { return }
        deferredQueuePromotions.removeValue(forKey: threadId)
    }

    func acquireQueueDrainSuppression(threadId: AgentThreadID) async -> UUID {
        await acquireQueueDrainSuppressions(threadIds: [threadId])[0].1
    }

    /// Installs every lease and invalidates every pending provider acceptance
    /// before awaiting any one drain task. This prevents an idle sibling thread
    /// from starting while a stuck sibling is still cancelling.
    func acquireQueueDrainSuppressions(
        threadIds: [AgentThreadID]
    ) async -> [(AgentThreadID, UUID)] {
        var seen: Set<AgentThreadID> = []
        let ordered = threadIds.filter { seen.insert($0).inserted }
        var leases: [(AgentThreadID, UUID)] = []
        var waiters: [Task<Void, Never>] = []
        var acceptanceAttempts: [(AgentThreadID, AgentRunAcceptanceAttempt)] = []
        for threadId in ordered {
            let lease = UUID()
            queueDrainSuppressionLeases[threadId, default: []].insert(lease)
            leases.append((threadId, lease))
            if let attempt = queueDispatchAcceptancePermits
                .removeValue(forKey: threadId)?
                .invalidate() {
                acceptanceAttempts.append((threadId, attempt))
            }
            if let waiter = queueDrainWaiters.removeValue(forKey: threadId) {
                waiter.task.cancel()
                waiters.append(waiter.task)
            }
        }
        // A claimed write linearized before suppression. Stop every affected
        // provider before awaiting any write completion so a stuck pipe cannot
        // delay cancellation of its siblings.
        for (threadId, _) in acceptanceAttempts {
            coordinator.stopRun(threadId: threadId)
        }
        if let queueDrainSuppressionAcquiredForTesting {
            for threadId in ordered {
                await queueDrainSuppressionAcquiredForTesting(threadId)
            }
        }
        let acceptanceWaiters = acceptanceAttempts.map { _, attempt in
            Task.detached {
                await attempt.wait()
            }
        }
        for waiter in waiters {
            await waiter.value
        }
        for waiter in acceptanceWaiters {
            await waiter.value
        }
        return leases
    }

    func releaseQueueDrainSuppression(threadId: AgentThreadID, lease: UUID) {
        guard var leases = queueDrainSuppressionLeases[threadId],
              leases.remove(lease) != nil else { return }
        if leases.isEmpty {
            queueDrainSuppressionLeases.removeValue(forKey: threadId)
            ensureQueueDrainWaiterIfNeeded(threadId: threadId)
        } else {
            queueDrainSuppressionLeases[threadId] = leases
        }
    }

    func queueDrainAllowsWork(threadId: AgentThreadID) -> Bool {
        !isTerminating && queueDrainSuppressionLeases[threadId]?.isEmpty != false
            && router?.botThreadAwaitsUser(threadId) != true
    }

    private func removeQueueDrainWaiter(threadId: AgentThreadID, token: UUID) {
        guard queueDrainWaiters[threadId]?.token == token else { return }
        queueDrainWaiters.removeValue(forKey: threadId)?.task.cancel()
    }

    private func cancelAllQueueDrainWaiters() -> [Task<Void, Never>] {
        let permits = queueDispatchAcceptancePermits
        queueDispatchAcceptancePermits.removeAll()
        var tasks = queueDrainWaiters.values.map(\.task)
        queueDrainWaiters.removeAll()
        for task in tasks { task.cancel() }
        for (threadId, permit) in permits {
            guard let attempt = permit.invalidate() else { continue }
            coordinator.stopRun(threadId: threadId)
            tasks.append(Task.detached {
                await attempt.wait()
            })
        }
        return tasks
    }

    @discardableResult
    func prepareForApplicationTermination() -> [Task<Void, Never>] {
        isTerminating = true
        flushPendingProviderUsage()
        flushEventPersistence()
        return cancelAllQueueDrainWaiters()
    }

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    struct RunFinishedNotificationInputs: @unchecked Sendable {
        let chrome: AgentThreadRepository.ListChrome?
        let settings: AppSettings
        let isNestedWorker: Bool
        let finalMessageId: String?
        /// Bot link, summary and duration for the Titio notice (hub spec §5).
        let titio: TitioRunFacts
    }

    /// The latest run-finished notification post; the next one waits for it.
    private var runFinishedNotificationPostTail: Task<Void, Never>?

    #if DEBUG
    /// Records which thread the run-finished notification reads ran on.
    let runFinishedNotificationReadProbeForTesting = ActivityReceiptsThreadProbe()
    /// Runs off-main before a run's notification reads; tests hold one gather.
    var runFinishedNotificationWillGatherForTesting: (@Sendable (AgentRunID) -> Void)?
    #endif

    /// Reads the run-finished notification needs, off the MainActor. The
    /// nested-worker check scans orchestration receipts (`detail LIKE`, ~15 ms
    /// on an 8.9k-row log) under the process-wide receipt and file locks; on
    /// the MainActor that stalled every run completion.
    func runFinishedNotificationInputs(
        runId: AgentRunID,
        threadId: AgentThreadID
    ) async -> RunFinishedNotificationInputs {
        let threadRepo = threadRepo
        let db = db
        let orchestrationRuntime = orchestrationRuntime
        let runRepo = runRepo
        let botStore = botStore
        #if DEBUG
        let probe = runFinishedNotificationReadProbeForTesting
        let willGather = runFinishedNotificationWillGatherForTesting
        #endif
        return await Task.detached(priority: .userInitiated) {
            #if DEBUG
            willGather?(runId)
            probe.recordCurrentThread()
            #endif
            let finalMessageId = ((try? AgentRunResultRepository(db: db).get(runId: runId)) ?? nil)?.finalMessageId?.description
            return RunFinishedNotificationInputs(
                chrome: (try? threadRepo.listChrome(ids: [threadId]))?[threadId],
                settings: SettingsStore(db: db).load(),
                isNestedWorker: Self.isNestedAgentWorker(
                    runId: runId,
                    threadId: threadId,
                    orchestrationRuntime: orchestrationRuntime,
                    runRepo: runRepo
                ),
                finalMessageId: finalMessageId,
                titio: Self.titioRunFacts(
                    runId: runId,
                    threadId: threadId,
                    finalMessageId: finalMessageId,
                    db: db,
                    botStore: botStore,
                    runRepo: runRepo
                )
            )
        }.value
    }

    /// Nested orchestration workers (subagents) carry a parent receipt. Main
    /// agent root runs have `parentReceiptId == nil` and `nodeId == "root"`.
    func isNestedAgentWorker(runId: AgentRunID, threadId: AgentThreadID) -> Bool {
        Self.isNestedAgentWorker(
            runId: runId,
            threadId: threadId,
            orchestrationRuntime: orchestrationRuntime,
            runRepo: runRepo
        )
    }

    nonisolated static func isNestedAgentWorker(
        runId: AgentRunID,
        threadId: AgentThreadID,
        orchestrationRuntime: AgentOrchestrationRuntime,
        runRepo: AgentRunRepository
    ) -> Bool {
        if let receipt = try? orchestrationRuntime.admissionReceipt(for: runId),
           RemoteCodeNotificationContent.AgentAppPushPolicy.isNestedWorker(
            parentReceiptId: receipt.parentReceiptId,
            nodeId: receipt.nodeId
           ) {
            return true
        }
        // Fall back when the event only carries the thread id of a nested worker.
        if let active = try? runRepo.latestActive(for: threadId),
           let receipt = try? orchestrationRuntime.admissionReceipt(for: active.id),
           RemoteCodeNotificationContent.AgentAppPushPolicy.isNestedWorker(
            parentReceiptId: receipt.parentReceiptId,
            nodeId: receipt.nodeId
           ) {
            return true
        }
        return false
    }

    /// System + private APNs banner when the main agent needs the user.
    /// Subagent / nested workers never produce push (parent owns UX).
    func postAgentUserActionPushIfNeeded(
        threadId: AgentThreadID,
        runId: AgentRunID,
        requestId: String,
        facts: TitioRequestFacts
    ) {
        let nested = isNestedAgentWorker(runId: runId, threadId: threadId)
        let chrome = (try? threadRepo.listChrome(ids: [threadId]))?[threadId]
        let notificationSettings = SettingsStore(db: db).load()
        guard let content = RemoteCodeNotificationContent.userActionNeeded(
            threadId: threadId.value.uuidString,
            workspaceId: chrome?.workspaceId?.value.uuidString,
            threadTitle: chrome?.title,
            actionTitle: facts.legacyActionTitle,
            requestId: requestId,
            isNestedWorker: nested
        ) else { return }
        if titioNoticeCenter.isEnabled(notificationSettings),
           ingestTitioRequest(threadId: threadId, runId: runId, requestId: requestId, facts: facts, chrome: chrome, legacy: content) {
            return
        }
        guard RemoteCodeNotificationContent.AgentAppPushPolicy.allowsNotification(
            isAction: true,
            workspaceId: chrome?.workspaceId?.value.uuidString,
            settings: notificationSettings
        ) else { return }
        SystemNotifier.shared.post(content, settings: notificationSettings)
        Task {
            await privateNotificationBridge.deliver(content)
        }
    }

    /// Always-on, content-free metadata for the provider-neutral Subagents
    /// lifecycle bridge, so child activity always shows in the Agent App.
    func subagentTelemetryEnvironment(
        provider: AgentProvider,
        threadId: AgentThreadID,
        baseEnvironment: [String: String] = [:]
    ) -> [String: String] {
        let identity = try? threadRepo.identity(of: threadId)
        var environment = baseEnvironment
        environment.removeValue(forKey: AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey)
        environment.merge([
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": appSupportDirectory.path,
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": threadId.value.uuidString,
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
            "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": AppPaths.socketPath(for: channel),
            "REMOTE_CODE_AGENT_PROVIDER": provider.rawValue,
            "REMOTE_CODE_AGENT_MODEL": identity?.model ?? "unknown",
            "REMOTE_CODE_PROVIDER_INSTANCE_ID": identity?.providerInstanceId ?? provider.rawValue,
        ]) { _, new in new }
        if let conversation = try? botStore.conversationLinked(to: threadId) {
            environment[BotSelfConfigCatalog.callerEnvironmentKey] =
                conversation.botID.value.uuidString.lowercased()
            if let bot = try? botStore.get(id: conversation.botID) {
                environment[BotRunMCPAdmission.cavemanEnvironmentKey] = "0"
            }
            if let bot = try? botStore.get(id: conversation.botID),
               let revisionID = bot.currentRevisionID,
               let revision = try? botStore.getRevision(id: revisionID) {
                if revision.desktopKind == .logicalExecutionSpace {
                    // This is a per-run admission signal. Provider-global MCP
                    // config must never make Docker/VM/remote runs host-capable.
                    environment[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey] = "1"
                    // The helper this run spawns inherits THIS app's TCC grants.
                    // Ask from the app (once per launch) so the current code
                    // identity is registered and the owner sees the system prompt.
                    if !Self.isRunningUnitTests {
                        ComputerUsePermissionBroker.requestOnceIfMissing()
                    }
                }
            }
        }
        let installer = makeAgentSkillInstaller()
        do {
            // Same single pass as the pre-turn env: nested launches share the
            // provider configs, and each per-server call re-scanned both.
            try installer.stripManagedBotMCPResidue()
        } catch {
            NSLog(
                "RemoteCode: stripManagedBotMCPResidue before subagent env failed: \(error.localizedDescription)"
            )
        }
        let managedBin = installer.managedCLIBinURL.path
        let basePath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        environment["PATH"] = AppCommandRouter.providerPathWithManagedWrappers(
            currentPath: basePath,
            managedBin: managedBin
        )
        environment["RC_REMOTE_CODE_MANAGED_BIN"] = managedBin
        environment.removeValue(forKey: "RC_REMOTE_CODE_AGENT_APP_COMMAND")
        if let agentAppCommand = installer.verifiedAgentAppMiddlewareURL() {
            environment["RC_REMOTE_CODE_AGENT_APP_COMMAND"] = agentAppCommand.path
        }

        let shellBridge = installer.providerShellBridgeURL
        let shellBridgeFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"]
        if shellBridgeFiles.allSatisfy({
            FileManager.default.fileExists(atPath: shellBridge.appendingPathComponent($0).path)
        }) {
            let originalZDOTDIR = environment["ZDOTDIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let providerHome = environment["HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let processHome = ProcessInfo.processInfo.environment["HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveHome = (providerHome?.isEmpty == false)
                ? providerHome!
                : ((processHome?.isEmpty == false)
                    ? processHome!
                    : FileManager.default.homeDirectoryForCurrentUser.path)
            let originalDirectory = (originalZDOTDIR?.isEmpty == false)
                ? originalZDOTDIR!
                : effectiveHome
            environment["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"] =
                originalDirectory == shellBridge.path
                ? effectiveHome
                : originalDirectory
            environment["RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR"] =
                environment["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"]
            environment["RC_REMOTE_CODE_MANAGED_ZDOTDIR"] = shellBridge.path
            environment["ZDOTDIR"] = shellBridge.path
        } else {
            environment.removeValue(forKey: "RC_REMOTE_CODE_ORIGINAL_ZDOTDIR")
            environment.removeValue(forKey: "RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR")
            environment.removeValue(forKey: "RC_REMOTE_CODE_MANAGED_ZDOTDIR")
        }
        if let workspaceID = identity?.workspaceId?.value.uuidString {
            environment["RC_REMOTE_CODE_WORKSPACE_ID"] = workspaceID
        }
        if let telemetryExecutable = Self.subagentTelemetryExecutableURL()?.path {
            environment["REMOTE_CODE_SUBAGENT_TELEMETRY_COMMAND"] = telemetryExecutable
        }
        return environment
    }

    private static func subagentTelemetryExecutableURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("RemoteCodeDistillService"),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "")
                .deletingLastPathComponent()
                .appendingPathComponent("RemoteCodeDistillService"),
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    @discardableResult
    public func reconcileRemoteCodeOrchestrate() -> RemoteCodeOrchestrateStatus {
        let installer = makeAgentSkillInstaller()
        do {
            remoteCodeOrchestrateInstallResult = try installer.reconcileRemoteCodeOrchestrate()
            remoteCodeOrchestrateInstallError = nil
        } catch {
            NSLog("RemoteCode orchestrate package reconcile failed: \(error)")
            remoteCodeOrchestrateInstallResult = nil
            remoteCodeOrchestrateInstallError = (error as NSError).localizedDescription
        }
        let status = installer.remoteCodeOrchestrateStatus()
        remoteCodeOrchestrateStatus = status
        return status
    }

    /// Drops the Token Saver settings an older build persisted, its on switch
    /// and API token among them. No-op once they are gone.
    func dropLegacyTokenSaverSettings() {
        SettingsStore(db: db).dropRemovedLegacyKeys()
    }

    /// The launch purge: removes what older builds installed in the user's home
    /// (`LegacyTokenSaverPurge.purgeIntegration`) and their Application Support
    /// data (multi-GB model weights, Graphify graphs). File work only, on a
    /// utility task, so launch never waits on it. Tests await
    /// `legacyTokenSaverPurgeTask`.
    private func startLegacyTokenSaverPurge() {
        let purge = LegacyTokenSaverPurge(installer: makeAgentSkillInstaller())
        let appSupport = appSupportDirectory
        // Graphify always wrote under the stable app's folder; a sandboxed-home
        // test must never reach the developer's real Application Support.
        let graphifyGraphs = agentSkillsHomeOverrideForTesting == nil
            ? LegacyTokenSaverPurge.defaultGraphifyGraphsDirectory()
            : appSupport.appendingPathComponent("graphify-graphs", isDirectory: true)
        legacyTokenSaverPurgeTask = Task.detached(priority: .utility) {
            let failures = purge.purgeIntegration(defaults: .standard)
            if !failures.isEmpty {
                NSLog("RemoteCode legacy Token Saver purge incomplete: \(failures.joined(separator: "; "))")
            }
            let result = LegacyTokenSaverPurge.purgeAppSupportData(
                appSupportDirectory: appSupport,
                graphifyGraphsDirectory: graphifyGraphs
            )
            for path in result.removed {
                NSLog("RemoteCode removed legacy Token Saver data at \(path)")
            }
            if !result.failures.isEmpty {
                NSLog("RemoteCode legacy Token Saver data purge incomplete: \(result.failures.joined(separator: "; "))")
            }
            if let training = result.keptTrainingDirectory {
                NSLog("RemoteCode kept saved Token Saver training prompts at \(training)")
            }
        }
    }

    /// Removes the legacy Token Saver integration (`LegacyTokenSaverPurge`), then
    /// installs the always-on routing. Quit runs it synchronously.
    ///
    /// Nested provider PATH proxies (`grok`/`claude`/`codex`), the Agent App
    /// middleware and the shell bridge are not Token Saver. They only intercept
    /// shell-launched bare provider names inside a thread-scoped environment;
    /// host top-level turns keep absolute resolved binaries via ProcessLocator.
    ///
    /// Behind the same gate as launch: never under XCTest without a sandboxed
    /// home (that would be the developer's real home), never with
    /// RC2_DISABLE_MANAGED_DISTILL_RECONCILE=1.
    @discardableResult
    func reconcileManagedIntegration() -> String? {
        guard Self.shouldReconcileManagedDistillIntegration(
            isRunningUnitTests: Self.isRunningUnitTests,
            hasSkillsHomeOverride: agentSkillsHomeOverrideForTesting != nil,
            environment: ProcessInfo.processInfo.environment
        ) else { return nil }
        let installer = makeAgentSkillInstaller()
        let failures = LegacyTokenSaverPurge(installer: installer)
            .purgeIntegration(defaults: .standard)
        installAlwaysOnRouting(installer)

        let failure = failures.isEmpty ? nil : failures.joined(separator: "; ")
        if let failure {
            NSLog("RemoteCode legacy Token Saver purge incomplete: \(failure)")
        }
        return failure
    }

    /// Always-on subagent routing. Install each component separately so a
    /// failure cannot remove or suppress siblings.
    private func installAlwaysOnRouting(_ installer: AgentSkillInstaller) {
        let activeServiceBinary = AgentSkillInstaller.resolveServiceBinary()
        do {
            _ = try installer.installProviderProxies(
                serviceBinaryURL: activeServiceBinary
            )
        } catch {
            NSLog("RemoteCode provider proxy install failed: \(error)")
        }
        do {
            _ = try installer.installAgentAppMiddleware(
                serviceBinaryURL: activeServiceBinary
            )
        } catch {
            NSLog("RemoteCode Agent App middleware install failed: \(error)")
        }
        do {
            _ = try installer.installProviderShellBridge()
        } catch {
            NSLog("RemoteCode provider shell bridge install failed: \(error)")
        }
    }

    func startBotBrowserPendingOpenObserver() {
        guard botBrowserOpenObserver == nil else { return }
        botBrowserOpenObserver = DistributedNotificationCenter.default().addObserver(
            forName: BotBrowserHost.pendingOpenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            try? self?.router?.reconcileBotBrowserOpens()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: BotBrowserHost.pendingActionNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.router?.reconcileBotBrowserActions() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: BotComputerHost.pendingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.router?.reconcileBotComputerActions()
        }
    }

    func reconcileComputerUseMCP() {
        let installer = makeAgentSkillInstaller()
        do {
            try installer.uninstallLegacyExternalHostArtifacts()
        } catch {
            NSLog("RemoteCode: legacy external host artifact cleanup failed: \(error.localizedDescription)")
        }
        // Remove any pre-native managed host entry once. Runtime admission is
        // process-local; never re-add this global Claude/Codex configuration.
        do {
            try installer.uninstallComputerUseMCP()
        } catch {
            NSLog("RemoteCode: legacy computer-use MCP cleanup failed: \(error.localizedDescription)")
        }
        do {
            try installer.stripManagedBotMCPResidue()
        } catch {
            NSLog("RemoteCode: stripManagedBotMCPResidue failed: \(error.localizedDescription)")
        }
    }

    private func makeAgentSkillInstaller() -> AgentSkillInstaller {
        // App-private Distill + remote-code-orchestrate live under the same skills root.
        // Production uses the default Application Support path; unit tests with a
        // sandboxed home keep app-private packages under this AppContext's
        // appSupportDirectory so they never write into the developer's real tree.
        if let home = agentSkillsHomeOverrideForTesting {
            return AgentSkillInstaller(
                claudeSkillsRoot: home.appendingPathComponent(".claude/skills", isDirectory: true),
                codexSkillsRoot: home.appendingPathComponent(".codex/skills", isDirectory: true),
                claudeInstructionsURL: home.appendingPathComponent(".claude/CLAUDE.md"),
                codexInstructionsURL: home.appendingPathComponent(".codex/AGENTS.md"),
                cliBinDirectory: home.appendingPathComponent(".remote-code/bin", isDirectory: true),
                pathBinDirectory: home.appendingPathComponent(".local/bin", isDirectory: true),
                appPrivateSkillsRoot: appSupportDirectory.appendingPathComponent("AgentSkills", isDirectory: true)
            )
        }
        return AgentSkillInstaller()
    }

    nonisolated static func shouldReconcileManagedDistillIntegration(
        isRunningUnitTests: Bool,
        hasSkillsHomeOverride: Bool,
        environment: [String: String]
    ) -> Bool {
        guard environment["RC2_DISABLE_MANAGED_DISTILL_RECONCILE"] != "1" else { return false }
        return !isRunningUnitTests || hasSkillsHomeOverride
    }

    private func recordAccountUsage(_ usage: AssistantAccountUsage) {
        do {
            _ = try ProviderUsageStore(appSupportDirectory: appSupportDirectory).recordAccountUsage(
                provider: usage.provider,
                weeklyUsedPercent: usage.weeklyUsedPercent,
                weeklyWindowDurationMinutes: usage.weeklyWindowDurationMinutes,
                weeklyResetsAt: usage.weeklyResetsAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) },
                currentSessionUsedPercent: usage.currentSessionUsedPercent,
                currentSessionResetsAt: usage.currentSessionResetsAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
            )
            // WHY: live `.accountUsage` is emitted on the provider parse queue
            // (Codex handleLine → coordinator → this method). Synchronous
            // NotificationCenter.post waits for OperationQueue observers
            // (queue: .main UI reloads) via waitUntilFinished and can deadlock
            // the parse path against main/mirror locks (see hang evidence:
            // remotecode.codex-app-server.parse blocked 745s). Schedule so the
            // write returns without waiting on observers; MainActor Task +
            // debounce match the token-usage write completion path.
            scheduleUsageChangedNotification()
        } catch {
            NSLog("RemoteCode account usage record failed: \(error)")
        }
    }

    public func refreshAccountUsage(reason: String, includeGrok: Bool = true) {
        guard PrivateAccountSessionStore(repo: settingsRepo).load() != nil else {
            publishAccountUsageRefresh(state: "skipped", reason: reason, detail: "signed_out")
            return
        }
        guard accountUsageRefreshTask == nil else {
            // A timer tick inside the Claude CLI interval never asks Claude, so
            // its settle cannot answer an explicit refresh (the popover would
            // stamp "updated just now" on an old Claude percent). Run it next.
            if reason != "periodic", !accountUsageRefreshProbesClaude {
                queuedClaudeAccountUsageRefresh = (reason, includeGrok)
                return
            }
            publishAccountUsageRefresh(state: "skipped", reason: reason, detail: "busy")
            return
        }
        let grokRefreshGeneration: UInt64?
        if includeGrok {
            grokAccountUsageRefreshGeneration &+= 1
            grokRefreshGeneration = grokAccountUsageRefreshGeneration
            periodicAccountUsageCycle = nil
        } else {
            grokRefreshGeneration = nil
            if var cycle = periodicAccountUsageCycle {
                cycle.otherProvidersFinished = false
                periodicAccountUsageCycle = cycle
            }
        }
        let periodicCycleID = includeGrok ? nil : periodicAccountUsageCycle?.id
        // WHY: on macOS the Claude OAuth token is in the Keychain (not read), so
        // unless Claude Code's own usage cache is fresh, Claude usage means
        // launching `claude -p /usage`: ~5 CPU-s and ~450 MB each time. A timer
        // tick launches it at most once per interval (longer after misses), so
        // the ring is at most one interval old instead of one minute; launch and
        // an opened usage panel still probe right away.
        let isPeriodic = reason == "periodic"
        let now = accountUsageNow()
        let claudeCLIProbeDue = !isPeriodic || lastClaudeUsageCLIProbeAt.map {
            let elapsed = now.timeIntervalSince($0)
            let backoff = Double(1 << min(claudeUsageCLIProbeMisses, 2))
            return elapsed < 0 || elapsed >= Self.claudeUsageCLIProbeInterval * backoff
        } ?? true
        if claudeCLIProbeDue {
            lastClaudeUsageCLIProbeAt = now
        }
        accountUsageRefreshProbesClaude = claudeCLIProbeDue
        accountUsageRefreshCount += 1
        publishAccountUsageRefresh(state: "started", reason: reason, detail: nil)

        let codexBinary = (try? settingsRepo.get("cli.codex.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeBinary = (try? settingsRepo.get("cli.claude.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let grokBinary = (try? settingsRepo.get("cli.grok.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ProviderAccountUsageRefreshRequest(
            codexBinary: codexBinary?.isEmpty == false ? codexBinary! : "codex",
            claudeBinary: claudeBinary?.isEmpty == false ? claudeBinary! : "claude",
            grokBinary: grokBinary?.isEmpty == false ? grokBinary! : "grok",
            grokAuthFileURL: Self.defaultGrokAuthFileURL,
            claudeAuthFileURL: Self.defaultClaudeAuthFileURL,
            claudeUsageCacheURL: claudeUsageCacheURL,
            allowClaudeCLIProbe: claudeCLIProbeDue,
            allowClaudeUsageScreen: claudeCLIProbeDue,
            codexAuthFileURL: Self.defaultCodexAuthFileURL,
            includeGrok: includeGrok,
            cwd: state.workspaces.values.first?.cwd ?? NSHomeDirectory(),
            environment: [:]
        )
        let refresher = accountUsageRefresher

        accountUsageRefreshTask = Task { [weak self] in
            let usages = await Self.refreshAccountUsageWithTimeout(refresher: refresher, request: request)
            await MainActor.run {
                guard let self else { return }
                let acceptsGrok = includeGrok
                    && grokRefreshGeneration == self.grokAccountUsageRefreshGeneration
                let acceptedUsages = usages.filter { $0.provider != .grok || acceptsGrok }
                for usage in acceptedUsages {
                    self.recordAccountUsage(usage)
                    self.publishAccountUsage(reason: reason, usage: usage)
                }
                if acceptedUsages.contains(where: { $0.provider == .claude }) {
                    self.claudeUsageCLIProbeMisses = 0
                } else if claudeCLIProbeDue {
                    self.claudeUsageCLIProbeMisses += 1
                }
                // Partial success: providers that did not answer *and* have no
                // unexpired weekly window are inactive / signed-out / unreachable.
                // Clear their frozen weekly % so Claude does not stay locked at
                // 45% forever. Do not clear providers still inside a live weekly
                // window (especially Grok): a flaky billing-log scan must not
                // paint the purple ring as 0% while credits are mid-window.
                // Full empty/timeout leaves the cache alone — that is noise, not
                // proof every provider is inactive.
                if !acceptedUsages.isEmpty {
                    let store = ProviderUsageStore(appSupportDirectory: self.appSupportDirectory)
                    let existing = store.load().providers
                    let toClear = ProviderUsageStore.providersToClearAfterPartialAccountUsageRefresh(
                        returned: acceptedUsages.map(\.provider),
                        existing: existing
                    ).filter { acceptsGrok || $0 != .grok }
                        // Claude was not asked when its CLI was skipped: no
                        // answer is not proof the account went inactive.
                        .filter { claudeCLIProbeDue || $0 != .claude }
                    for provider in toClear {
                        self.clearAccountUsagePercentages(provider, reason: reason)
                    }
                }
                self.publishAccountUsageRefresh(
                    state: "finished",
                    reason: reason,
                    detail: acceptedUsages.isEmpty ? "empty" : nil,
                    providers: acceptedUsages.map(\.provider.rawValue)
                )
                // Only a real provider probe settles the details refresh. The
                // generic `.rc2AccountUsageChanged` is also posted by local
                // provider-usage writes, so waiting on it stamped a fresh
                // "updated just now" for a probe still running. A run that
                // skipped the Claude CLI says so: it settles no details refresh.
                NotificationCenter.default.post(
                    name: .rc2AccountUsageRefreshSettled,
                    object: nil,
                    userInfo: ["claudeProbed": claudeCLIProbeDue]
                )
                if let periodicCycleID,
                   self.periodicAccountUsageCycle?.id == periodicCycleID {
                    self.periodicAccountUsageCycle?.otherProvidersFinished = true
                    if !acceptedUsages.isEmpty {
                        self.periodicAccountUsageCycle?.otherProvidersSucceeded = true
                    }
                    _ = self.reconcilePeriodicGrokMissIfReady(cycleID: periodicCycleID)
                }
                let queued = self.queuedClaudeAccountUsageRefresh
                self.queuedClaudeAccountUsageRefresh = nil
                self.publishAccountUsageDigestFromDisk(isRefreshing: queued != nil)
                self.accountUsageRefreshTask = nil
                if let queued {
                    self.refreshAccountUsage(reason: queued.reason, includeGrok: queued.includeGrok)
                }
            }
        }
    }

    /// Keep the Grok ring fresh even when Codex/Claude are slow, without
    /// duplicating the Grok credits request inside the full refresh.
    public func refreshPeriodicAccountUsage() {
        let cycleFinished = periodicAccountUsageCycle.map {
            $0.grokFinished && $0.otherProvidersFinished
        } ?? true
        if periodicGrokAccountUsageRefreshTask == nil, cycleFinished {
            periodicAccountUsageCycleID &+= 1
            periodicAccountUsageCycle = PeriodicAccountUsageCycle(
                id: periodicAccountUsageCycleID
            )
        }
        refreshGrokAccountUsage(reason: "periodic", coalescePeriodic: true)
        refreshAccountUsage(reason: "periodic", includeGrok: false)
    }

    @discardableResult
    private func reconcilePeriodicGrokMissIfReady(cycleID: UInt64) -> Bool {
        guard var cycle = periodicAccountUsageCycle,
              cycle.id == cycleID,
              cycle.grokFinished,
              !cycle.grokSucceeded,
              cycle.otherProvidersSucceeded,
              !cycle.reconciledMiss else { return false }
        let store = ProviderUsageStore(appSupportDirectory: appSupportDirectory)
        let shouldClearGrok = ProviderUsageStore.providersToClearAfterPartialAccountUsageRefresh(
            returned: [],
            existing: store.load().providers,
            managed: [.grok]
        ).contains(.grok)
        if shouldClearGrok {
            clearAccountUsagePercentages(.grok, reason: "periodic")
        }
        cycle.reconciledMiss = true
        periodicAccountUsageCycle = cycle
        return shouldClearGrok
    }

    private func clearAccountUsagePercentages(_ provider: AgentProvider, reason: String) {
        do {
            let snapshot = try ProviderUsageStore(appSupportDirectory: appSupportDirectory)
                .clearAccountUsagePercentages(provider: provider)
            // Same non-blocking path as recordAccountUsage — account-
            // usage store mutations must not wait on NotificationCenter observers.
            scheduleUsageChangedNotification()
            // Paired devices fold live `agent.account.usage` events on top of
            // `agent.account.usage.get`; without this event the iPhone kept the
            // pre-clear percent while the Mac sidebar showed 0%.
            if let row = snapshot.providers.first(where: { $0.provider == provider }) {
                publishAccountUsage(reason: reason, usage: Self.clearedAccountUsage(row))
            }
        } catch {
            NSLog("RemoteCode account usage clear failed (\(provider.rawValue)): \(error)")
        }
    }

    /// Grok-only account-usage refresh from the live CLI credits API, with the
    /// local billing log as fallback.
    ///
    /// WHY: Claude/Codex push live `.accountUsage` during a turn. Grok ACP does
    /// not, so the purple weekly ring stayed stale until launch / periodic /
    /// details-open. Independent of `accountUsageRefreshTask`
    /// so a busy full refresh cannot skip Grok.
    ///
    /// - Parameters:
    ///   - reason: telemetry label (`run_finished`, tests, …)
    ///   - billingLogURL: override for tests; default is the user billing log.
    ///     When set, the live credits API is skipped so tests stay offline.
    ///   - coalescePeriodic: coalesce only timer ticks; run-finished refreshes
    ///     remain immediate so a new local billing record is never delayed.
    public func refreshGrokAccountUsage(
        reason: String,
        billingLogURL: URL? = nil,
        coalescePeriodic: Bool = false
    ) {
        guard PrivateAccountSessionStore(repo: settingsRepo).load() != nil else {
            publishAccountUsageRefresh(state: "skipped", reason: reason, detail: "signed_out")
            return
        }
        if coalescePeriodic, periodicGrokAccountUsageRefreshTask != nil {
            publishAccountUsageRefresh(state: "skipped", reason: reason, detail: "grok_busy")
            return
        }
        if !coalescePeriodic {
            periodicAccountUsageCycle = nil
        } else if var cycle = periodicAccountUsageCycle {
            cycle.grokFinished = false
            periodicAccountUsageCycle = cycle
        }
        grokAccountUsageRefreshGeneration &+= 1
        let refreshGeneration = grokAccountUsageRefreshGeneration
        let logURL = billingLogURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/logs/unified.jsonl")
        let request = ProviderAccountUsageRefreshRequest(
            grokBillingLogURL: logURL,
            grokAuthFileURL: billingLogURL == nil ? Self.defaultGrokAuthFileURL : nil,
            cwd: state.workspaces.values.first?.cwd ?? NSHomeDirectory(),
            environment: [:]
        )
        let detail = billingLogURL == nil ? "grok_credits_api" : "grok_billing_log"
        publishAccountUsageRefresh(state: "started", reason: reason, detail: detail)
        let refresher = accountUsageRefresher
        let task = Task { [weak self] in
            let usage = await refresher.grokAccountUsage(request)
            await MainActor.run {
                guard let self else { return }
                defer {
                    if coalescePeriodic {
                        self.periodicGrokAccountUsageRefreshTask = nil
                    }
                }
                guard refreshGeneration == self.grokAccountUsageRefreshGeneration else {
                    return
                }
                var shouldPublishWidgetDigest = false
                if let usage {
                    self.recordAccountUsage(usage)
                    shouldPublishWidgetDigest = true
                    self.publishAccountUsage(reason: reason, usage: usage)
                    self.publishAccountUsageRefresh(
                        state: "finished",
                        reason: reason,
                        detail: nil,
                        providers: [usage.provider.rawValue]
                    )
                } else {
                    self.publishAccountUsageRefresh(
                        state: "finished",
                        reason: reason,
                        detail: "empty",
                        providers: []
                    )
                }
                if coalescePeriodic,
                   var cycle = self.periodicAccountUsageCycle {
                    cycle.grokFinished = true
                    cycle.grokSucceeded = cycle.grokSucceeded || usage != nil
                    self.periodicAccountUsageCycle = cycle
                    shouldPublishWidgetDigest = self.reconcilePeriodicGrokMissIfReady(cycleID: cycle.id)
                        || shouldPublishWidgetDigest
                }
                if shouldPublishWidgetDigest,
                   !coalescePeriodic || self.accountUsageRefreshTask == nil {
                    self.publishAccountUsageDigestFromDisk(isRefreshing: false)
                }
            }
        }
        if coalescePeriodic {
            periodicGrokAccountUsageRefreshTask = task
        }
    }

    static var defaultGrokAuthFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    static var defaultClaudeAuthFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// Claude Code's config, which caches its last `/api/oauth/usage` answer.
    static var defaultClaudeUsageCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    /// Shortest gap between Claude usage CLI launches from the periodic timer;
    /// doubles after each launch that got no answer, up to 4×. Short enough
    /// that Claude used outside RemoteCode shows in the ring within minutes.
    static let claudeUsageCLIProbeInterval: TimeInterval = 5 * 60

    static var defaultCodexAuthFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    static func refreshAccountUsageWithTimeout(
        refresher: ProviderAccountUsageRefreshing,
        request: ProviderAccountUsageRefreshRequest,
        timeoutNanoseconds: UInt64 = 60_000_000_000
    ) async -> [AssistantAccountUsage] {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            var watchdog: Task<Void, Never>?
            func resume(_ usages: [AssistantAccountUsage]) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                watchdog?.cancel()
                continuation.resume(returning: usages)
            }

            let work = Task.detached {
                let usages = await refresher.refreshAccountUsage(request)
                resume(usages)
            }
            watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                work.cancel()
                resume([])
            }
        }
    }

    /// Publishes `agent.account.usage`. A periodic tick skips a value paired
    /// devices already have: unchanged usage used to add two rows a minute to
    /// the durable 5,000-row event log (PL-05). Every other path, and any value
    /// that differs from the last one published (a clear included), publishes.
    nonisolated private func publishAccountUsage(
        threadId: String? = nil,
        reason: String? = nil,
        usage: AssistantAccountUsage
    ) {
        let changed = accountUsagePublishes.record(usage.provider, Self.accountUsagePayload(usage: usage))
        guard changed || reason != "periodic" else { return }
        EventBus.shared.publish(kind: .agentAccountUsage,
            payload: .object(Self.accountUsagePayload(threadId: threadId, reason: reason, usage: usage)))
    }

    private func publishAccountUsageRefresh(
        state: String,
        reason: String,
        detail: String?,
        providers: [String] = []
    ) {
        let payload = Self.accountUsageRefreshPayload(
            state: state,
            reason: reason,
            detail: detail,
            providers: providers,
            refreshCount: accountUsageRefreshCount
        )
        EventBus.shared.publish(kind: .agentAccountUsageRefresh, payload: .object(payload))
    }

    /// Pure builder for the `agent.account.usage` event payload.
    ///
    /// WHY: the payload is constructed in two call sites (run-time event and
    /// refresh path). Extracting the builder lets golden contract tests pin
    /// the field names and types so silent schema drift fails a mac test.
    /// `threadId` is present only in the run-time path; `reason` only in the
    /// refresh path — both are optional.

    /// Disk-backed account usage digest for remote iOS clients.
    @MainActor
    public func publishAccountUsageDigestFromDisk(isRefreshing: Bool = false) {
        // EV-25: the account session and usage.json are read off the MainActor;
        // both inputs are thread-safe.
        let settingsRepo = settingsRepo
        let appSupportDirectory = appSupportDirectory
        let accounts = AccountUsageEntry.entries(distillAccountsController.statuses)
        Task.detached(priority: .utility) {
            let subscribed = PrivateAccountSessionStore(repo: settingsRepo).load()?.user.subscribed == true
            AccountUsageWidgetDigest.publishFromDisk(
                appSupportDirectory: appSupportDirectory,
                subscribed: subscribed,
                accounts: accounts,
                isRefreshing: isRefreshing,
                updatedAt: Date()
            )
        }
    }

    nonisolated static func accountUsagePayload(
        threadId: String? = nil,
        reason: String? = nil,
        usage: AssistantAccountUsage
    ) -> [String: JSONValue] {
        var p: [String: JSONValue] = [
            "provider": .string(usage.provider.rawValue),
            "weekly_used_percent": .number(usage.weeklyUsedPercent),
            "weekly_window_duration_minutes": usage.weeklyWindowDurationMinutes.map { .number(Double($0)) } ?? .null,
            "weekly_resets_at_ms": usage.weeklyResetsAtMs.map { .number(Double($0)) } ?? .null,
            "current_session_used_percent": usage.currentSessionUsedPercent.map { .number($0) } ?? .null,
            "current_session_resets_at_ms": usage.currentSessionResetsAtMs.map { .number(Double($0)) } ?? .null
        ]
        if let threadId { p["thread_id"] = .string(threadId) }
        if let reason   { p["reason"]    = .string(reason)   }
        return p
    }

    /// The live-event shape of a provider row as stored after
    /// `clearAccountUsagePercentages`. Both percents go out as numbers (0):
    /// clients fold events like the store does (null keeps the old value), so
    /// a null session percent would leave a stale session ring on the phone.
    nonisolated static func clearedAccountUsage(_ row: ProviderTokenUsage) -> AssistantAccountUsage {
        func milliseconds(_ date: Date?) -> Int64? {
            date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        }
        return AssistantAccountUsage(
            provider: row.provider,
            weeklyUsedPercent: row.weeklyUsedPercent ?? 0,
            weeklyWindowDurationMinutes: row.weeklyWindowDurationMinutes,
            weeklyResetsAtMs: milliseconds(row.weeklyResetsAt),
            currentSessionUsedPercent: row.currentSessionUsedPercent ?? 0,
            currentSessionResetsAtMs: milliseconds(row.currentSessionResetsAt)
        )
    }

    /// Pure builder for the `agent.account.usage.refresh` event payload.
    ///
    /// WHY: same extraction rationale as `accountUsagePayload` — lets a golden
    /// test pin `state`/`reason`/`refresh_count`/`detail`/`providers` field
    /// names independently of the private emit function.
    nonisolated static func accountUsageRefreshPayload(
        state: String,
        reason: String,
        detail: String?,
        providers: [String],
        refreshCount: Int
    ) -> [String: JSONValue] {
        var p: [String: JSONValue] = [
            "state": .string(state),
            "reason": .string(reason),
            "refresh_count": .number(Double(refreshCount))
        ]
        if let detail { p["detail"] = .string(detail) }
        if !providers.isEmpty { p["providers"] = .array(providers.map { .string($0) }) }
        return p
    }

    private func recordProviderTokenUsage(_ usage: AssistantTokenUsage, runId: AgentRunID) {
        guard usage.totalTokens > 0 else { return }
        var pending: PendingUsage
        if let active = pendingUsageByRun[runId] {
            pending = active
        } else if let completed = completedUsageByRun.removeValue(forKey: runId) {
            completedUsageRunOrder.removeAll { $0 == runId }
            pending = completed
        } else {
            // Once a terminal baseline ages out of the bounded tombstone cache,
            // fail closed for accounting. Reconstructing it from zero would
            // double-count a replayed provider receipt.
            guard let status = try? runRepo.status(of: runId),
                  status == .pending || status == .running,
                  let provider = try? runRepo.provider(of: runId) else { return }
            pending = PendingUsage(provider: provider)
        }
        // Incremental events have no provider event ID, so a replay after the
        // terminal callback cannot be distinguished from a new charge. Provider
        // lifecycles deliver legitimate increments before finish; ignore a late
        // incremental replay and continue accepting authoritative cumulative
        // receipts.
        if pending.finished, usage.resolvedSemantics == .incremental {
            archiveCompletedUsage(runId: runId, pending: pending)
            return
        }

        // The sidebar "used tokens" figure is the real provider-billed count,
        // recorded for every thread.
        switch usage.resolvedSemantics {
        case .incremental:
            pending.incremental = Self.addingUsage(pending.incremental, usage)
        case .cumulative:
            pending.cumulative = AssistantTokenUsage.merging(
                pending.cumulative,
                with: usage
            )
        }
        pendingUsageByRun[runId] = pending
        schedulePendingUsageFlush()
    }

    /// Schedules a debounced flush; resets the timer on each call so many rapid
    /// events coalesce into a single disk write after the quiet window. A retry
    /// after a failed write backs off instead of reusing the quiet window, so an
    /// unwritable store cannot spin at the debounce rate. New token events still
    /// schedule the quiet-window flush: they are real traffic, not a timer.
    private func schedulePendingUsageFlush(retryAfterFailure: Bool = false) {
        let delay = retryAfterFailure
            ? Self.providerUsageRetryDelay(
                consecutiveFailures: providerUsageConsecutiveWriteFailures
            )
            : Self.providerUsageDebounceInterval
        if retryAfterFailure {
            providerUsageRetryDelaysForTesting.append(delay)
        }
        pendingUsageFlushTask?.cancel()
        pendingUsageFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.flushPendingProviderUsage()
            }
        }
    }

    /// Writes all accumulated usage to disk off the main thread.
    /// Pass a specific `runId` to flush only that run (used at run-end);
    /// pass `nil` to flush every pending run (used at app quit).
    func flushPendingProviderUsage(runId: AgentRunID? = nil) {
        let keysToFlush: [AgentRunID]
        if let runId {
            guard pendingUsageByRun[runId] != nil else { return }
            keysToFlush = [runId]
        } else {
            keysToFlush = Array(pendingUsageByRun.keys)
        }
        guard !keysToFlush.isEmpty else { return }

        // Cancel the debounce timer -- the explicit flush supersedes it.
        if runId == nil {
            pendingUsageFlushTask?.cancel()
            pendingUsageFlushTask = nil
        }

        let snapshots: [UsageWriteSnapshot] = keysToFlush.compactMap { key in
            guard var pending = pendingUsageByRun[key],
                  !pending.writeInFlight else {
                return nil
            }
            let target = Self.effectiveUsage(pending)
            let delta = Self.usageGrowth(from: pending.persisted, to: target)
            let billedDelta = max(
                0,
                target.billedTotalTokenUnits - pending.persisted.billedTotalTokenUnits
            )
            guard delta.totalTokens > 0 || billedDelta > 0 else {
                if pending.finished {
                    archiveCompletedUsage(runId: key, pending: pending)
                }
                return nil
            }
            pending.writeInFlight = true
            pendingUsageByRun[key] = pending
            return UsageWriteSnapshot(
                runId: key,
                provider: pending.provider,
                target: target,
                delta: delta,
                deltaBilledTokenUnits: billedDelta,
                currentSessionTokens: target.totalTokens,
                currentSessionLimitTokens: target.contextWindow
            )
        }
        guard !snapshots.isEmpty else { return }

        let appSupportDir = appSupportDirectory
        let beforeWrite = beforeProviderUsageWriteForTesting
        backgroundWriterQueue.async { [weak self] in
            for snapshot in snapshots {
                let succeeded: Bool
                do {
                    try beforeWrite?()
                    // usage.json still carries the old savings columns; the raw
                    // estimate equals the actual count, so nothing is "saved".
                    _ = try ProviderUsageStore(appSupportDirectory: appSupportDir).record(
                        provider: snapshot.provider,
                        actualProviderTokens: snapshot.delta.totalTokens,
                        estimatedRawTokens: snapshot.delta.totalTokens,
                        actualProviderBilledTokenUnits: snapshot.deltaBilledTokenUnits,
                        estimatedRawBilledTokenUnits: snapshot.deltaBilledTokenUnits,
                        eligibleRuns: 0,
                        currentSessionTokens: snapshot.currentSessionTokens,
                        currentSessionLimitTokens: snapshot.currentSessionLimitTokens
                    )
                    succeeded = true
                } catch {
                    NSLog("RemoteCode provider usage record failed: \(error)")
                    succeeded = false
                }
                DispatchQueue.main.async { [weak self] in
                    self?.completeProviderUsageWrite(snapshot, succeeded: succeeded)
                }
            }
        }
    }

    private func finishPendingProviderUsage(runId: AgentRunID) {
        if var pending = pendingUsageByRun[runId] {
            pending.finished = true
            pendingUsageByRun[runId] = pending
        } else if completedUsageByRun[runId] == nil,
                  let provider = try? runRepo.provider(of: runId) {
            var pending = PendingUsage(provider: provider)
            pending.finished = true
            archiveCompletedUsage(runId: runId, pending: pending)
        }
        flushPendingProviderUsage(runId: runId)
        archiveCompletedUsageIfSettled(runId: runId)
    }

    private func completeProviderUsageWrite(
        _ snapshot: UsageWriteSnapshot,
        succeeded: Bool
    ) {
        guard var pending = pendingUsageByRun[snapshot.runId],
              pending.writeInFlight else {
            return
        }
        pending.writeInFlight = false
        if succeeded {
            providerUsageConsecutiveWriteFailures = 0
            pending.persisted = AssistantTokenUsage.merging(
                pending.persisted,
                with: snapshot.target
            )
        }
        pendingUsageByRun[snapshot.runId] = pending

        if succeeded {
            scheduleUsageChangedNotification()
        }

        let target = Self.effectiveUsage(pending)
        let remainingTokens = target.totalTokens - pending.persisted.totalTokens
        let remainingBilledUnits =
            target.billedTotalTokenUnits - pending.persisted.billedTotalTokenUnits
        if remainingTokens > 0 || remainingBilledUnits > 0 {
            if succeeded {
                flushPendingProviderUsage(runId: snapshot.runId)
            } else {
                providerUsageConsecutiveWriteFailures += 1
                schedulePendingUsageFlush(retryAfterFailure: true)
            }
        } else if pending.finished {
            archiveCompletedUsage(runId: snapshot.runId, pending: pending)
        }
    }

    private func archiveCompletedUsageIfSettled(runId: AgentRunID) {
        guard let pending = pendingUsageByRun[runId],
              !pending.writeInFlight else {
            return
        }
        let target = Self.effectiveUsage(pending)
        guard target.totalTokens <= pending.persisted.totalTokens,
              target.billedTotalTokenUnits <= pending.persisted.billedTotalTokenUnits else {
            return
        }
        archiveCompletedUsage(runId: runId, pending: pending)
    }

    private func archiveCompletedUsage(runId: AgentRunID, pending: PendingUsage) {
        var tombstone = pending
        tombstone.writeInFlight = false
        tombstone.finished = true
        pendingUsageByRun.removeValue(forKey: runId)
        completedUsageByRun[runId] = tombstone
        completedUsageRunOrder.removeAll { $0 == runId }
        completedUsageRunOrder.append(runId)

        let limit = max(
            0,
            providerUsageTombstoneLimitForTesting
                ?? Self.completedUsageTombstoneLimit
        )
        while completedUsageRunOrder.count > limit {
            let evicted = completedUsageRunOrder.removeFirst()
            completedUsageByRun.removeValue(forKey: evicted)
        }
    }

    private nonisolated static func effectiveUsage(_ pending: PendingUsage) -> AssistantTokenUsage {
        AssistantTokenUsage.merging(pending.incremental, with: pending.cumulative)
    }

    private nonisolated static func addingUsage(
        _ lhs: AssistantTokenUsage,
        _ rhs: AssistantTokenUsage
    ) -> AssistantTokenUsage {
        func add(_ lhs: Int, _ rhs: Int) -> Int {
            let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
            return overflow ? Int.max : sum
        }
        func addOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard lhs != nil || rhs != nil else { return nil }
            return add(lhs ?? 0, rhs ?? 0)
        }
        return AssistantTokenUsage(
            inputTokens: add(lhs.inputTokens, rhs.inputTokens),
            outputTokens: add(lhs.outputTokens, rhs.outputTokens),
            totalTokens: add(lhs.totalTokens, rhs.totalTokens),
            contextWindow: maxOptional(lhs.contextWindow, rhs.contextWindow),
            compactsAutomatically: rhs.compactsAutomatically ?? lhs.compactsAutomatically,
            uncachedInputTokens: addOptional(lhs.uncachedInputTokens, rhs.uncachedInputTokens),
            cacheCreationInputTokens: addOptional(
                lhs.cacheCreationInputTokens,
                rhs.cacheCreationInputTokens
            ),
            cacheReadInputTokens: addOptional(lhs.cacheReadInputTokens, rhs.cacheReadInputTokens),
            reportedCostMicros: addOptional(lhs.reportedCostMicros, rhs.reportedCostMicros),
            contextTokens: rhs.contextTokens ?? lhs.contextTokens,
            semantics: .incremental
        )
    }

    private nonisolated static func usageGrowth(
        from previous: AssistantTokenUsage,
        to latest: AssistantTokenUsage
    ) -> AssistantTokenUsage {
        func growth(_ old: Int?, _ new: Int?) -> Int? {
            guard old != nil || new != nil else { return nil }
            return max(0, (new ?? 0) - (old ?? 0))
        }
        return AssistantTokenUsage(
            inputTokens: max(0, latest.inputTokens - previous.inputTokens),
            outputTokens: max(0, latest.outputTokens - previous.outputTokens),
            totalTokens: max(0, latest.totalTokens - previous.totalTokens),
            contextWindow: latest.contextWindow,
            compactsAutomatically: latest.compactsAutomatically,
            uncachedInputTokens: growth(
                previous.uncachedInputTokens,
                latest.uncachedInputTokens
            ),
            cacheCreationInputTokens: growth(
                previous.cacheCreationInputTokens,
                latest.cacheCreationInputTokens
            ),
            cacheReadInputTokens: growth(
                previous.cacheReadInputTokens,
                latest.cacheReadInputTokens
            ),
            reportedCostMicros: growth(
                previous.reportedCostMicros,
                latest.reportedCostMicros
            ),
            contextTokens: latest.contextTokens,
            semantics: .incremental
        )
    }

    private nonisolated static func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return max(lhs ?? 0, rhs ?? 0)
    }

    private func scheduleUsageChangedNotification(now: Date = Date()) {
        let elapsed = now.timeIntervalSince(lastUsageNotificationAt)
        guard elapsed < Self.usageNotificationMinimumInterval else {
            lastUsageNotificationAt = now
            Task { @MainActor in
                NotificationCenter.default.post(name: .rc2AccountUsageChanged, object: nil)
            }
            return
        }
        guard usageNotificationTask == nil else { return }
        let delay = Self.usageNotificationMinimumInterval - elapsed
        usageNotificationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.usageNotificationTask = nil
                self.lastUsageNotificationAt = Date()
                NotificationCenter.default.post(name: .rc2AccountUsageChanged, object: nil)
            }
        }
    }

    private var pendingSave: DispatchWorkItem?
    private(set) var snapshotSaveScheduleCountForTesting = 0

    /// Serial utility queue for all event-log appends and snapshot writes.
    /// Keeping DB I/O off the main/publish thread avoids priority inversion
    /// during high-frequency event bursts. All writes must be dispatched here.
    public let backgroundWriterQueue = DispatchQueue(
        label: "io.remotecode.app.writer",
        qos: .utility
    )

    /// Cadence: prune the event log every N appends instead of on every append.
    /// Reducing prune frequency amortises the DELETE cost across many inserts.
    public static let eventLogPruneInterval: Int = 50

    /// Pure cadence gate: true iff `appendCount` is a positive multiple of
    /// `interval`. Zero-count never prunes (avoids prune-on-first-write).
    /// `interval` must be >= 1; values < 1 are treated as 1 (always prune).
    nonisolated public static func shouldPrune(appendCount: Int, interval: Int) -> Bool {
        let n = max(1, interval)
        return appendCount > 0 && appendCount % n == 0
    }

    /// Wire an EventBus persister to encode and append on the serial writer
    /// queue. Serial submission preserves event sequence while keeping payload
    /// encoding and SQLite transactions off the producer/delivery path.
    /// EV-25(c): events published while the writer queue is busy pile up here
    /// and land in ONE transaction when the scheduled flush runs. The flush is
    /// enqueued as soon as the buffer becomes non-empty, so an idle writer
    /// persists with the same latency as before and only storms coalesce.
    ///
    /// C6: each drained batch holds a completion token until its transaction
    /// returns. The receipt commit fence waits only for those in-flight
    /// batches and then writes any rows no writer has picked up yet itself,
    /// instead of `backgroundWriterQueue.sync {}`, which also waited behind
    /// unrelated utility work (snapshot saves, storage cleanup, usage files).
    final class PendingEventLogRows: @unchecked Sendable {
        private let condition = NSCondition()
        private var rows: [EventBus.Event] = []
        private var inFlightBatches = 0

        /// Returns true when this event opened a new batch (caller schedules the flush).
        func append(_ event: EventBus.Event) -> Bool {
            condition.lock(); defer { condition.unlock() }
            rows.append(event)
            return rows.count == 1
        }

        /// Takes every queued row as one batch. A non-empty batch stays in
        /// flight until the caller passes its token back to `finishBatch()`.
        func drainBatch() -> [EventBus.Event] {
            condition.lock(); defer { condition.unlock() }
            return takeRowsLocked()
        }

        /// Fence side: waits for batches already being written (they hold
        /// earlier sequences), then takes the remaining rows as a new batch.
        func drainBatchAfterInFlight() -> [EventBus.Event] {
            condition.lock(); defer { condition.unlock() }
            while inFlightBatches > 0 { condition.wait() }
            return takeRowsLocked()
        }

        func finishBatch() {
            condition.lock()
            inFlightBatches -= 1
            condition.broadcast()
            condition.unlock()
        }

        private func takeRowsLocked() -> [EventBus.Event] {
            let drained = rows
            rows.removeAll(keepingCapacity: true)
            if !drained.isEmpty { inFlightBatches += 1 }
            return drained
        }
    }

    /// Test seam: runs before each event-log batch transaction, on the thread
    /// that writes it (the writer queue, or a receipt commit's fence).
    nonisolated(unsafe) static var beforeEventLogBatchWriteForTesting: (() -> Void)?

    private let pendingEventLogRows = PendingEventLogRows()
    private let eventLogFlushLock = NSLock()
    nonisolated(unsafe) private var eventLogFlushCountValue = 0
    nonisolated(unsafe) private var eventLogPersistedRowCountValue = 0
    /// Test seams: flushes vs rows persisted through them.
    nonisolated var eventLogFlushCountForTesting: Int {
        eventLogFlushLock.lock(); defer { eventLogFlushLock.unlock() }
        return eventLogFlushCountValue
    }
    nonisolated var eventLogPersistedRowCountForTesting: Int {
        eventLogFlushLock.lock(); defer { eventLogFlushLock.unlock() }
        return eventLogPersistedRowCountValue
    }

    public func wireBackgroundPersister(eventBus: EventBus = .shared) {
        let log = eventLog
        let queue = backgroundWriterQueue
        let pending = pendingEventLogRows
        let flushLock = eventLogFlushLock
        // C8: durable replay reads the event log on the read-only connection.
        // Wired before the persister so every later durable event is tracked.
        let replayLog = EventLogRepository(db: readDB)
        eventBus.durableReplaySource = EventBus.DurableReplaySource(page: { after, through, limit in
            let page = try replayLog.readReplayPage(after: after, through: through, limit: limit)
            let events = try page.rows.map { row -> EventBus.Event in
                guard let data = row.payloadJSON.data(using: .utf8),
                      let payload = JSONValue.decode(from: data) else {
                    // A row that cannot be replayed must not be skipped silently.
                    throw SQLiteError.execute("Undecodable event log row \(row.seq).")
                }
                let ts = EventLogRepository.createdAtDate(row.createdAt)?.timeIntervalSince1970 ?? 0
                return EventBus.Event(seq: row.seq, kind: row.kind, payload: payload, ts: ts)
            }
            return EventBus.DurableReplaySourcePage(events: events, anchored: page.anchored)
        }, estimate: { after, through, rowLimit in
            try replayLog.estimateReplay(after: after, through: through, rowLimit: rowLimit)
        })
        let writeBatch: ([EventBus.Event]) -> Void = { [weak self, weak eventBus] batch in
            defer { pending.finishBatch() }
            Self.beforeEventLogBatchWriteForTesting?()
            let rows = batch.map { event in
                EventLogRepository.PendingRow(
                    seq: event.seq,
                    kind: event.kind,
                    payloadJSON: EventBus.encodePayloadForPersistence(event.payload)
                )
            }
            let written = (try? log.appendBatch(rows)) != nil
            // C8: durable replay only trusts the log up to acknowledged rows.
            eventBus?.acknowledgeDurablePersistence(
                sequences: batch.map(\.seq),
                succeeded: written
            )
            flushLock.lock()
            self?.eventLogFlushCountValue += 1
            self?.eventLogPersistedRowCountValue += rows.count
            flushLock.unlock()
        }
        // Runs on the EventBus delivery lane, so no new rows arrive meanwhile.
        eventBus.persistenceCommitFence = {
            let signposter = PerfSwitchMetrics.signposter
            let interval = signposter.beginInterval("event_log_commit_fence", id: signposter.makeSignpostID())
            defer { signposter.endInterval("event_log_commit_fence", interval) }
            let batch = pending.drainBatchAfterInFlight()
            guard !batch.isEmpty else { return }
            writeBatch(batch)
        }
        eventBus.persister = { ev in
            guard AppDelegate.shouldPersistEvent(ev) else { return }
            guard pending.append(ev) else { return }
            queue.async {
                let batch = pending.drainBatch()
                guard !batch.isEmpty else { return }
                writeBatch(batch)
            }
        }
    }

    public func apply(_ action: LayoutAction) throws {
        state = try reducer.reduce(state, action)
        // Every layout mutation (workspace create/close/select, surface
        // add/close/split/move, etc.) schedules a debounced snapshot
        // write so workspaces and tabs survive a restart even if the app
        // is killed before a clean quit.
        scheduleSnapshotSave()
    }

    public func scheduleSnapshotSave(delay: TimeInterval = 0.4) {
        snapshotSaveScheduleCountForTesting += 1
        pendingSave?.cancel()
        // Capture layout state on main, then write to DB off-main so the
        // debounced save does not block the main thread during event bursts.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snap = SessionSnapshot(layout: self.state)
            let repo = self.snapshotRepo
            self.backgroundWriterQueue.async { [weak self] in
                do {
                    try repo.save(snap)
                } catch {
                    Task { @MainActor [weak self] in
                        self?.recordPersistenceWriteError(error, operation: "Session layout")
                    }
                }
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func saveSnapshot() {
        pendingSave?.cancel()
        pendingSave = nil
        let snap = SessionSnapshot(layout: state)
        do {
            try snapshotRepo.save(snap)
        } catch {
            recordPersistenceWriteError(error, operation: "Session layout")
        }
    }

    func recordPersistenceWriteError(_ error: Error, operation: String) {
        let message = Self.persistenceWriteErrorMessage(operation: operation, error: error)
        persistenceWriteErrorMessage = message
        onPersistenceWriteError?(message)
    }

    static func persistenceWriteErrorMessage(operation: String, error: Error) -> String {
        "\(operation) could not be saved: \(error.localizedDescription)."
    }

    /// Drain backgroundWriterQueue synchronously. Use in tests that call
    /// saveSnapshot() / wireBackgroundPersister() and then immediately read
    /// back from a fresh AppContext; ensures all queued writes have landed
    /// before the assertion.
    public func flushWriterQueue() {
        backgroundWriterQueue.sync {}
    }

    /// Drain EventBus delivery first, then its serial persistence queue. The
    /// ordering closes the graceful-exit race where an accepted publish had not
    /// submitted its writer work when a plain writer barrier was inserted.
    public func flushEventPersistence(eventBus: EventBus = .shared) {
        eventBus.flushPersistenceSubmissions()
        flushWriterQueue()
    }

    @discardableResult
    public func reapIdleProviderSessions(now: Date = Date(), idleAge: TimeInterval = 6 * 60 * 60) throws -> ProviderSessionReaperResult {
        try Self.reapIdleProviderSessions(
            threadRepo: threadRepo,
            providerSessionRuntimeRepo: providerSessionRuntimeRepo,
            providerPendingCallbackRepo: providerPendingCallbackRepo,
            coordinator: coordinator,
            loopThreadIds: distillAdapter.threadIdsWithActiveLoops(),
            now: now,
            idleAge: idleAge
        )
    }

    /// Serial queue for the 30 s idle-session reaper (S-F6). Its SQLite reads
    /// and writes can wait out a busy writer, and releasing a session tears down
    /// a provider process tree, so none of it may run on the main thread.
    let providerSessionReaperQueue = DispatchQueue(
        label: "io.remotecode.app.provider-session-reaper",
        qos: .utility
    )
    private var providerSessionReapInFlight = false

    /// Runs the reap on `providerSessionReaperQueue` and hops back to the main
    /// actor only to hand over the result. A tick that lands while the previous
    /// reap is still running is dropped (returns false): the next tick rescans
    /// everything, so nothing is lost and two reaps never race each other.
    @discardableResult
    public func reapIdleProviderSessionsOffMain(
        now: Date = Date(),
        idleAge: TimeInterval,
        completion: @escaping @MainActor (Result<ProviderSessionReaperResult, Error>) -> Void
    ) -> Bool {
        guard !providerSessionReapInFlight else { return false }
        providerSessionReapInFlight = true
        let threadRepo = threadRepo
        let sessionRepo = providerSessionRuntimeRepo
        let pendingCallbackRepo = providerPendingCallbackRepo
        let coordinator = coordinator
        let loopThreadIds = distillAdapter.threadIdsWithActiveLoops()
        providerSessionReaperQueue.async {
            let result = Result {
                try Self.reapIdleProviderSessions(
                    threadRepo: threadRepo,
                    providerSessionRuntimeRepo: sessionRepo,
                    providerPendingCallbackRepo: pendingCallbackRepo,
                    coordinator: coordinator,
                    loopThreadIds: loopThreadIds,
                    now: now,
                    idleAge: idleAge
                )
            }
            Task { @MainActor in
                self.providerSessionReapInFlight = false
                completion(result)
            }
        }
        return true
    }

    nonisolated private static func reapIdleProviderSessions(
        threadRepo: AgentThreadRepository,
        providerSessionRuntimeRepo: ProviderSessionRuntimeRepository,
        providerPendingCallbackRepo: ProviderPendingCallbackRepository,
        coordinator: AgentRunCoordinator,
        loopThreadIds: Set<AgentThreadID>,
        now: Date,
        idleAge: TimeInterval
    ) throws -> ProviderSessionReaperResult {
        let cutoff = now.addingTimeInterval(-idleAge)
        let activeThreadIds = try threadRepo.runningThreadIds().union(loopThreadIds)
        let liveSessions = coordinator.liveProviderSessions()
        let reaper = ProviderSessionReaper(
            sessionRepo: providerSessionRuntimeRepo,
            pendingCallbackRepo: providerPendingCallbackRepo,
            liveSessions: { liveSessions }
        ) {
            activeThreadIds
        }
        let result = try reaper.reapIdleSessions(olderThan: cutoff)
        // Marking the session stopped in the DB does not free the underlying
        // provider process (codex app-server / node bridge). Release every
        // reaped thread's adapter session so the idle processes are actually
        // terminated. F19: use the lifecycle-silent release — routing this
        // through stopRun(threadId:) broadcast a spurious "Thread cancelled"
        // for threads that finished hours ago and could even respawn a provider
        // process for a dead thread via the recover-then-interrupt fallback.
        coordinator.releaseReapedProviderSessions(result)
        return result
    }

    /// A reap candidate, reduced to the only two facts that decide eligibility:
    /// the thread's last-activity timestamp and whether the thread is still
    /// active. Pure, DB-free, so the selection rule can be tested directly.
    public struct ReapCandidate: Sendable, Equatable {
        public let threadId: AgentThreadID
        public let lastActivityAt: Date
        public let isActive: Bool

        public init(threadId: AgentThreadID, lastActivityAt: Date, isActive: Bool) {
            self.threadId = threadId
            self.lastActivityAt = lastActivityAt
            self.isActive = isActive
        }
    }

    /// Pure selection mirroring ProviderSessionReaper.reapIdleSessions: a thread
    /// is reap-eligible iff it is idle strictly past the cutoff AND not active.
    /// The returned set is exactly the threads that get marked stopped AND have
    /// adapter.stopSession called on them.
    nonisolated public static func reapEligibleThreadIds(
        candidates: [ReapCandidate],
        idleCutoff: Date
    ) -> [AgentThreadID] {
        candidates
            .filter { !$0.isActive && $0.lastActivityAt < idleCutoff }
            .map(\.threadId)
    }
}

/// Last `agent.account.usage` value published per provider. Locked: the live
/// `.accountUsage` path publishes from the provider parse queue.
private final class AccountUsagePublishLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [AgentProvider: [String: JSONValue]] = [:]

    /// Records `payload` and reports whether it differs from the previous one.
    func record(_ provider: AgentProvider, _ payload: [String: JSONValue]) -> Bool {
        lock.withLock { last.updateValue(payload, forKey: provider) != payload }
    }
}
