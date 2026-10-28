import Foundation
import AppKit
import SwiftUI
import Security
import os
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import RemoteCodeTreaty
import Surfaces

private let appRouterLog = Logger(subsystem: "io.remotecode.appshell", category: "router")

private struct AgentProviderInstanceConfig: Decodable, Equatable {
    var id: String
    var provider: AgentProvider
    var displayName: String?
    var binaryPath: String?
    var homePath: String?
    var accentColor: String?
    var enabled: Bool?
    var env: [String: String]?
}

private struct ProviderProbeCacheKey: Hashable {
    var provider: AgentProvider
    var binaryPath: String
    var environment: [String]

    init(provider: AgentProvider, binaryPath: String, environment: [String: String]) {
        self.provider = provider
        self.binaryPath = binaryPath
        self.environment = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    }
}

private struct ProviderProbeCapabilities: Sendable {
    var version: String?
    var authenticated: Bool?
    var accountLabel: String?
    var accountAuthMethod: String?
    var updateState: String?
    var advisory: String?
    var slashCommands: [String]
    var skills: [String]
    var capturedAt: Date
}

/// Off-MainActor serial owner for durable command-receipt SQLite.
///
/// `AppCommandRouter` is `@MainActor`; running receipt get/claim/finalize on the
/// main run loop competed with Agent App paint. This gateway keeps SQLite on a
/// dedicated queue. Callers that need a return value still wait (sync RPC
/// contract), but the MainActor stack is no longer inside sqlite step.
/// Fire-and-forget `record` never blocks the UI at all.
public final class CommandReceiptPersistenceGateway: @unchecked Sendable {
    public static let shared = CommandReceiptPersistenceGateway()
    public static let queueLabel = "io.remotecode.command-receipt"

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueToken: UInt8 = 1

    public init() {
        let queue = DispatchQueue(label: Self.queueLabel, qos: .userInitiated)
        self.queue = queue
        queue.setSpecific(key: queueKey, value: queueToken)
    }

    public func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    public func sync<T>(_ work: @escaping () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            return work()
        }
        return queue.sync(execute: work)
    }

    public func syncThrowing<T>(_ work: @escaping () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    /// Runs `work` on the receipt queue and resumes the caller when it has
    /// landed. The awaiting actor (MainActor for the dispatcher) is suspended,
    /// not blocked, while SQLite runs.
    public func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// C6: the dispatcher's off-MainActor receipt writer. Claim and commit await
/// the receipt queue; finalize builds the transaction `EventBus` runs on its
/// delivery lane. Encoding uses sorted keys, like the router's synchronous
/// methods, so stored result and payload bytes are unchanged.
struct CommandReceiptOffMainWriter: CommandReceiptOffMainWriting {
    private final class RepositoryBox: @unchecked Sendable {
        let repo: CommandReceiptRepository
        init(_ repo: CommandReceiptRepository) { self.repo = repo }
    }

    private let box: RepositoryBox
    private let gateway: CommandReceiptPersistenceGateway

    init(repo: CommandReceiptRepository, gateway: CommandReceiptPersistenceGateway = .shared) {
        self.box = RepositoryBox(repo)
        self.gateway = gateway
    }

    private static func sortedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw JSONRPCError.internalError
        }
        return json
    }

    func claim(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) async throws -> CommandReceiptClaimResult {
        let box = box
        return try await gateway.perform {
            let signposter = PerfSwitchMetrics.signposter
            let interval = signposter.beginInterval("receipt_claim", id: signposter.makeSignpostID())
            defer { signposter.endInterval("receipt_claim", interval) }
            return try box.repo.claim(
                method: method,
                clientRequestId: clientRequestId,
                ownerFingerprint: ownerFingerprint,
                paramsHash: paramsHash
            )
        }
    }

    func commit(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) async throws {
        let box = box
        try await gateway.perform {
            try box.repo.commit(
                method: method,
                clientRequestId: clientRequestId,
                ownerFingerprint: ownerFingerprint,
                paramsHash: paramsHash,
                resultJSON: try Self.sortedJSON(result)
            )
        }
    }

    func finalizeTransaction(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent]
    ) -> @Sendable (Int64) throws -> [EventBus.Event] {
        let box = box
        let gateway = gateway
        return { minimumEventSequence in
            let signposter = PerfSwitchMetrics.signposter
            let interval = signposter.beginInterval("receipt_finalize", id: signposter.makeSignpostID())
            defer { signposter.endInterval("receipt_finalize", interval) }
            let resultJSON = try Self.sortedJSON(result)
            let intents = try events.map { event in
                CommandReceiptEventIntent(
                    kind: event.kind.rawValue,
                    payloadJSON: try Self.sortedJSON(event.payload),
                    createdAt: event.createdAt
                )
            }
            let persisted = try gateway.syncThrowing {
                try box.repo.finalize(
                    method: method,
                    clientRequestId: clientRequestId,
                    ownerFingerprint: ownerFingerprint,
                    paramsHash: paramsHash,
                    resultJSON: resultJSON,
                    events: intents,
                    minimumEventSequence: minimumEventSequence
                )
            }
            return try persisted.map { event in
                guard let payloadData = event.payloadJSON.data(using: .utf8),
                      let payload = JSONValue.decode(from: payloadData) else {
                    throw JSONRPCError.internalError
                }
                return EventBus.Event(
                    seq: event.seq,
                    kind: event.kind,
                    payload: payload,
                    ts: event.createdAt.timeIntervalSince1970
                )
            }
        }
    }
}

/// Off-MainActor owner for Agent App refresh/read RPC persistence work.
///
/// The dispatcher and router are MainActor-isolated, but these RPCs can read
/// large SQLite rows and decode provider JSON. Keep that work on one serial
/// queue and return only immutable Sendable values to the actor boundary.
public final class AgentAppReadGateway: @unchecked Sendable {
    public static let queueLabel = "io.remotecode.agent-app-read"

    // MARK: - Test probes (executor proof, not latency alone)

    nonisolated(unsafe) public static var readWillRunForTesting: (() -> Void)?
    nonisolated(unsafe) public static var readDelayNanosecondsForTesting: UInt64 = 0
    nonisolated(unsafe) public static private(set) var readCallCountForTesting = 0
    nonisolated(unsafe) public static private(set) var readOnMainActorCountForTesting = 0
    nonisolated(unsafe) public static private(set) var readOffMainActorCountForTesting = 0

    public static func resetExecutionProbesForTesting() {
        readWillRunForTesting = nil
        readDelayNanosecondsForTesting = 0
        readCallCountForTesting = 0
        readOnMainActorCountForTesting = 0
        readOffMainActorCountForTesting = 0
    }

    /// WAL reader. Every gateway method is a pure read, so paired-device
    /// list/page reads never wait on the writer connection's operation gate.
    private let readDB: SQLiteDB
    private let queue: DispatchQueue
    // PERF: listPendingCallbacks allocated JSONDecoder per off-MainActor poll.
    // Gateway work is serial on `queue`, so one instance decoder is safe and
    // avoids per-call codec construction while decode behavior is unchanged.
    private let pendingCallbackDecoder = JSONDecoder()

    public init(db: SQLiteDB, readDB: SQLiteDB? = nil) {
        self.readDB = readDB ?? db
        self.queue = DispatchQueue(label: Self.queueLabel, qos: .userInitiated)
    }

    public func listThreads(workspaceId: WorkspaceID?) async throws -> [AgentThread] {
        try await execute {
            try AgentThreadRepository(db: self.readDB).list(workspaceId: workspaceId)
        }
    }

    func listActivity(service: ActivityService, params: [String: JSONValue]) async throws -> JSONValue {
        try await execute { try service.list(params) }
    }

    func activityCounts(service: ActivityService) async throws -> (global: AgentActivityCounts, byWorkspace: [String: AgentActivityCounts]) {
        try await execute { try service.counts() }
    }

    public func message(id: AgentMessageID) async throws -> AgentMessage? {
        try await execute {
            try AgentMessageRepository(db: self.readDB).get(id: id)
        }
    }

    public func threadIdsWithMessages() async throws -> Set<AgentThreadID> {
        try await execute {
            try AgentMessageRepository(db: self.readDB).threadIdsWithMessages()
        }
    }

    public func guestRuntimesByThread() async throws -> [AgentThreadID: String] {
        try await execute {
            try AgentThreadRepository(db: self.readDB).guestRuntimesByThread()
        }
    }

    public func listMessages(threadId: AgentThreadID, limit: Int) async throws -> [AgentMessage] {
        try await execute {
            try AgentMessageRepository(db: self.readDB).listRecent(
                threadId: threadId,
                limit: max(0, min(limit, 500))
            )
        }
    }

    public func listMessagesPage(
        threadId: AgentThreadID,
        limit: Int,
        before: AgentMessageCursor?,
        after: AgentMessageCursor?
    ) async throws -> AgentMessagePage {
        try await execute {
            try AgentMessageRepository(db: self.readDB).listPage(
                threadId: threadId,
                limit: max(0, min(limit, 500)),
                before: before,
                after: after
            )
        }
    }

    public func listMessagesWithinBodyBudget(
        threadId: AgentThreadID,
        limit: Int,
        before: AgentMessageCursor?,
        after: AgentMessageCursor?,
        budget: Int,
        contentLimit: Int
    ) async throws -> AgentMessageBodyBudgetResult {
        try await execute {
            try AgentMessageRepository(db: self.readDB).listPageWithinBodyBudget(
                threadId: threadId,
                limit: max(1, min(limit, 500)),
                before: before,
                after: after,
                budget: budget,
                contentLimit: contentLimit,
                appendEllipsisOnCap: false,
                attachmentsByteLimit: AgentMessageTransport.attachmentJSONMaxBytes,
                attachmentsCountLimit: AgentMessageTransport.attachmentCountLimit
            )
        }
    }

    public func listQueuedMessages(threadId: AgentThreadID) async throws -> [AgentQueuedMessage] {
        try await execute {
            try AgentQueuedMessageRepository(db: self.readDB).list(threadId: threadId)
        }
    }

    public func listPendingCallbacks(threadId: AgentThreadID) async throws -> AssistantPendingCallbacksSnapshot {
        try await execute {
            PendingCallbackSnapshotMapper.snapshot(
                from: try ProviderPendingCallbackRepository(db: self.readDB).listVisible(threadId: threadId),
                decoder: self.pendingCallbackDecoder
            )
        }
    }

    private func execute<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                Self.readCallCountForTesting += 1
                if Thread.isMainThread {
                    Self.readOnMainActorCountForTesting += 1
                } else {
                    Self.readOffMainActorCountForTesting += 1
                }
                Self.readWillRunForTesting?()
                let delay = Self.readDelayNanosecondsForTesting
                if delay > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000)
                }
                do {
                    // The queue keeps the work off MainActor; performSync also
                    // takes the read connection's operation gate for the complete
                    // statement/decode sequence and resets its statements after,
                    // so no WAL read snapshot outlives the call.
                    let result = try self.readDB.performSync { _ in try work() }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Maps stored provider callbacks into the snapshot the paired device hydrates.
///
/// A row whose `payload_json` no longer decodes still names a request the run is
/// waiting on (`Repositories.row` even normalizes a NULL payload to `"{}"`, which
/// does not decode either), so it must never be dropped from the snapshot: an
/// unreadable payload is not proof that the request does not exist. The degraded
/// entry keeps identity, state, and timing so the request stays answerable by id.
enum PendingCallbackSnapshotMapper {
    static func snapshot(
        from callbacks: [ProviderPendingCallback],
        decoder: JSONDecoder
    ) -> AssistantPendingCallbacksSnapshot {
        var requests: [AssistantPendingRequest] = []
        var userInputs: [AssistantUserInputRequest] = []
        for callback in callbacks {
            let data = Data(callback.payloadJSON.utf8)
            switch callback.kind {
            case .approval:
                var request: AssistantPendingRequest
                if let decoded = try? decoder.decode(AssistantPendingRequest.self, from: data) {
                    request = decoded
                } else {
                    reportUnreadable(callback)
                    request = AssistantPendingRequest(
                        id: callback.requestId,
                        turnId: nil,
                        kind: .dynamic,
                        title: "Approval request",
                        detail: Self.unreadablePayloadDetail,
                        createdAtMs: Int64(callback.createdAt.timeIntervalSince1970 * 1000)
                    )
                }
                request.state = callback.state
                request.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                if callback.state == .stale, let reason = callback.staleReason {
                    request.detail = [request.detail, reason].compactMap { $0 }.joined(separator: "\n")
                }
                requests.append(request)
            case .userInput:
                var input: AssistantUserInputRequest
                if let decoded = try? decoder.decode(AssistantUserInputRequest.self, from: data) {
                    input = decoded
                } else {
                    reportUnreadable(callback)
                    input = AssistantUserInputRequest(
                        id: callback.requestId,
                        turnId: nil,
                        prompt: Self.unreadableUserInputPrompt,
                        createdAtMs: Int64(callback.createdAt.timeIntervalSince1970 * 1000)
                    )
                }
                input.state = callback.state
                input.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                if callback.state == .stale, let reason = callback.staleReason, input.answer == nil {
                    input.answer = reason
                }
                userInputs.append(input)
            }
        }
        return AssistantPendingCallbacksSnapshot(requests: requests, userInputs: userInputs)
    }

    // English product copy, same as the rest of the callback surfaces. Never
    // carries payload text or paths.
    static let unreadablePayloadDetail = "Stored request payload could not be read; approve or decline to unblock the run."
    static let unreadableUserInputPrompt = "Input requested (stored payload could not be read)"

    private static func reportUnreadable(_ callback: ProviderPendingCallback) {
        appRouterLog.error(
            "pending_callback.payload_unreadable thread=\(callback.threadId.value.uuidString, privacy: .public) request=\(callback.requestId, privacy: .public) kind=\(callback.kind.rawValue, privacy: .public) state=\(callback.state.rawValue, privacy: .public) bytes=\(callback.payloadJSON.utf8.count, privacy: .public)"
        )
    }
}

struct ClaudeProviderRuntimePresentation: Equatable {
    let advisory: String?
    let interactionModes: [AgentInteractionMode]?
    let permissionModes: [AgentPermissionMode]?
    let capabilities: AgentProviderCapabilities?

    static func resolve(agentSDKEnabled: Bool, probeAdvisory: String?) -> Self {
        guard !agentSDKEnabled else {
            return Self(advisory: probeAdvisory, interactionModes: nil, permissionModes: nil, capabilities: nil)
        }
        let degraded = "Degraded text-only fallback: Claude Agent SDK is disabled."
        let advisory: String
        if let probeAdvisory, !probeAdvisory.isEmpty {
            advisory = "\(degraded) \(probeAdvisory)"
        } else {
            advisory = degraded
        }
        return Self(
            advisory: advisory,
            interactionModes: [.default],
            permissionModes: [.supervised],
            capabilities: AgentProviderCapabilities(
                supportsAttachments: false,
                supportedAttachmentKinds: [],
                supportedAttachmentMediaTypes: [],
                supportsApprovals: false,
                supportsUserInput: false,
                supportsStreaming: true,
                supportsFork: false,
                supportsRollback: false,
                supportsPlanReview: false
            )
        )
    }
}

/// Result of `AppCommandRouter.agentThreadOpenDestination(_:)`.
public enum AgentThreadOpenDestination: Equatable, Sendable {
    case workspace(WorkspaceID)
    case bot(BotID, BotConversationID)
    /// No open workspace and no owning bot conversation: `openAgentThread` would throw.
    case unavailable
}

/// Bridges the JSON-RPC dispatcher to the in-process domain state plus the
/// concrete Surface views. Lives on the main actor because it mutates UI.
@MainActor
public final class AppCommandRouter: CommandRouting, TerminalCommandRouting, LayoutEventSuppressionRouting, NotificationEventPublishingRouting, ConnectionSnapshotRouting, CommandReceiptStateRouting {
    typealias SSHCommandRunner = @Sendable (String, [String], String?) throws -> (exitCode: Int32, output: String)

    private static let minimizedPaneVisibilityThreshold = 0.08

    public weak var context: AppContext?

    /// Accounts & Auto lives in Settings; the Agent App's empty state links there.
    private var openAccountsSettings: (() -> Void)? {
        guard context != nil else { return nil }
        return { [weak self] in
            if let windowController = self?.windowController {
                windowController.presentSettingsInMainContent(route: .accounts)
                return
            }
            guard let settings = (NSApp.delegate as? AppDelegate)?.settings else { return }
            settings.show(route: .accounts)
        }
    }
    public weak var windowController: MainWindowController?
    /// H3: throttles terminal OSC title commits (persist + surface.renamed) per surface.
    let terminalTitleCoalescer = TerminalTitleCoalescer()
    public weak var botsViewModel: BotsViewModel?
    private let botComputerReconciliationQueue = DispatchQueue(
        label: "io.remotecode.bot-computer-reconciliation",
        qos: .utility
    )
    private var botComputerReconciliationScheduled = false
    /// Routes logical Desktop browser actions through app-managed headless
    /// Chrome CDP and preserves the existing Playwright local/guest lanes.
    /// Seam so tests inject a recorder instead of spawning a browser.
    lazy var botBrowserBridge: any BotBrowserBridging = ManagedChromeHostBrowserBridge()
    /// Replaces the real docker guest provision in tests (no docker in CI).
    var botBrowserGuestEnsureForTesting: (@Sendable (BotID) throws -> Void)?
    /// Replaces the real pending-action worker in tests without starting Docker.
    var botComputerReconciliationWorkerForTesting: (@Sendable () -> Void)?
    /// Who drives each bot computer. Shared with the guest service; tests inject their own.
    var botComputerControl: BotComputerControl = .shared
    /// Overrides the bot -> thread lookup for manual-action cards (tests). Default: newest linked conversation thread.
    var botActiveThreadResolverForTesting: (@Sendable (BotID) -> AgentThreadID?)?
    /// Runs on the background queue after guest provisioning, right before the bridge act (tests).
    var botBrowserBeforeBridgeActForTesting: (@Sendable () -> Void)?
    public private(set) var lastAgentAppHopTextForTesting: String?
    var destinationWindowIsKeyForTests: ((NSWindow) -> Bool)?
    var providerSignInTerminalInputSenderForTests: ((SurfaceID, String) -> TerminalInputStatus)?
    var terminalRestartRuntimePreparerForTesting: ((WorkspaceID, String, SurfaceID) -> TerminalPreparedPTYRuntime?)?
    var terminalRestartPreparedDiscardAdditionalBarrierForTesting: (() -> SurfaceTerminationBarrier?)?
    var queueDispatchBeforeProviderStartForTesting: (() async -> Void)?
    /// Bot desk hook for queue-drained sends: returns the compiled brain prompt and
    /// bot-home cwd for a bot-linked thread, nil for any other thread.
    struct BotThreadQueuedPrompt {
        let prompt: String
        let cwd: String?
    }
    /// Distill loop wakes waiting for the thread's current run to finish.
    var pendingProviderWakes: [AgentThreadID: [(promptId: String, label: String)]] = [:]
    /// Wake prompt ids already adopted (or being adopted) per thread, oldest first, capped.
    var startedProviderWakePromptIds: [AgentThreadID: [String]] = [:]
    var botThreadPromptTransform: (@MainActor (AgentThreadID, String, AgentRunID) async throws -> BotThreadQueuedPrompt?)?
    /// Fires after a queue-drained run starts on any thread; the bot desk records its receipt here.
    var botThreadRunStarted: (@MainActor (AgentRunID, AgentThreadID) -> Void)?
    /// Bot desk hooks for workspace Agent App threads run as a bot; installed by `BotsViewModel`.
    struct BotWorkspaceRunHooks {
        let link: @MainActor (BotID, AgentThreadID) throws -> Void
        let promptTransform: @MainActor (BotID, String, AgentThreadID, AgentRunID) async throws -> String
        let runStarted: @MainActor (BotID, AgentRunID, AgentThreadID) -> Void
    }
    var botWorkspaceRunHooks: BotWorkspaceRunHooks?
    /// The Bots model whose weak self the run hooks capture; nil once it is gone.
    weak var botWorkspaceRunHooksOwner: AnyObject?
    var beforePullRequestThreadCommitForTesting: (() throws -> Void)?
    /// Fires after inbound attachments pass `validatedForRetry` on the managed store.
    var sendAgentMessageResolvedAttachmentsProbeForTesting: (([AgentAttachment]) -> Void)?
    /// Fires after send preflight resolves, whether from cache or a catalog list.
    var sendAgentMessageAfterPreflightProbeForTesting: (() async -> Void)?
    var listAgentProviderSnapshotsCallCountForTesting = 0
    var preflightListedProviderSnapshotsForTesting = false
    private var cachedProviderSnapshots: [AgentProviderSnapshot] = []
    private var cachedProviderSnapshotsAt: Date?
    var codexForkProtocolSupportProbe: @Sendable (String, [String: String]) -> Bool = { binary, environment in
        CodexForkProtocolSupport.probe(binary: binary, environment: environment).isSupported
    }
    var claudeForkProtocolSupportProbe: () -> Bool = {
        ClaudeAgentSDKBridgeAdapter.installedForkProtocolSupported()
    }
    private let sshPasswordStore: SSHPasswordStoring
    private let sshCommandRunner: SSHCommandRunner
    private let botSecretStore: any BotSecretStore
    private let agentAppReadGateway: AgentAppReadGateway
    // PERF: publishQueuedMessage + notificationList constructed ISO8601DateFormatter
    // per date field. Construction is expensive; share one MainActor-isolated formatter.
    private let iso8601Formatter = ISO8601DateFormatter()
    // PERF: jsonValue converts attachments/model selection/surface payloads on
    // MainActor event publish paths — avoid allocating JSONEncoder per call.
    private let jsonValueEncoder = JSONEncoder()
    // PERF: every host mutation records/commits command receipts. Commit/finalize
    // require sortedKeys so digests stay stable; share one MainActor encoder each
    // instead of allocating per mutation.
    private let commandReceiptSortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    // PERF: provider instances, SSH hosts, and pending-callback list allocated
    // JSONDecoder/JSONEncoder per call. MainActor-isolated router — share one
    // pair (no lock; codecs are only touched on this actor).
    private let settingsJSONDecoder = JSONDecoder()
    private let settingsJSONEncoder = JSONEncoder()
    private var providerProbeCache: [ProviderProbeCacheKey: ProviderProbeCapabilities] = [:]
    private var providerUpdateLocks = Set<ProviderProbeCacheKey>()
    private let providerProbeCacheTTL: TimeInterval = 30
    /// Peak distinct provider probe keys retained on this long-lived router.
    /// Env/run-as fingerprint churn otherwise pins unbounded capability
    /// structs (slash commands + skills). 32 matches Grok ACP discovery /
    /// Codex fork probe / catalog verification order of magnitude.
    nonisolated static let providerProbeCacheCountLimit = 32
    private var suppressedLayoutEventDepth = 0
    private var closedTabBuffer = ClosedTabRingBuffer(capacity: 10)
    private var restartingSurfaceIDs = Set<SurfaceID>()
    /// Descriptors that failed to reinstantiate during session restore.
    /// Populated by `reinstantiateRestoredSurfaces`; readable by tests and diagnostics.
    public private(set) var restoreFailedSurfaceIDs: [SurfaceID] = []

    public convenience init(context: AppContext) {
        self.init(
            context: context,
            sshPasswordStore: KeychainSSHPasswordStore(),
            secretStore: BotKeychainSecretStore()
        )
    }

    init(
        context: AppContext,
        sshPasswordStore: SSHPasswordStoring,
        sshCommandRunner: @escaping SSHCommandRunner = { executable, arguments, password in
            try AppCommandRouter.runCommandBlocking(executable: executable, arguments: arguments, password: password)
        },
        secretStore: any BotSecretStore = BotKeychainSecretStore()
    ) {
        self.context = context
        self.sshPasswordStore = sshPasswordStore
        self.sshCommandRunner = sshCommandRunner
        self.botSecretStore = secretStore
        self.agentAppReadGateway = AgentAppReadGateway(db: context.db, readDB: context.readDB)
        botComputerControl.configureResourceLookup { [store = context.botStore] botID, threadID in
            (try? store.guestResourceID(botID: botID, threadID: threadID)) ?? botID
        }
        installBotHostObservers()
    }

    lazy var manualActionStore: ManualActionRequestStore = {
        ManualActionRequestStore(appSupportDirectory: context?.appSupportDirectory ?? AppPaths.appSupportDirectory(for: .debug, override: nil))
    }()
    private var botHostObservers: [NSObjectProtocol] = []
    /// Mac-execution approvals awaiting the user, per thread (reason text). Never auto-approved.
    var pendingMacExecution: [AgentThreadID: String] = [:]
    var botVMDocker: any BotComputerDockerClienting = BotComputerDockerCLI()
    var botVMProvisionServiceForTesting: BotComputerGuestService?

    deinit {
        for token in botHostObservers { NotificationCenter.default.removeObserver(token) }
    }

    /// Notifications arrive on the poster's thread; the store is thread-safe, UI work hops to MainActor.
    private func installBotHostObservers() {
        let center = NotificationCenter.default
        botHostObservers.append(center.addObserver(forName: .botManualActionRequested, object: nil, queue: nil) { [weak self] note in
            guard let request = note.userInfo?[BotHostNotificationKey.request] as? ManualActionRequest else { return }
            let threadIsFallback = note.userInfo?[BotHostNotificationKey.threadIsFallback] as? Bool ?? false
            Task { @MainActor [weak self] in
                self?.handleManualActionRequested(request, stopsRun: !threadIsFallback)
            }
        })
        // Synchronous on the poster's thread: an agent.manual_action.resolve call posts on the
        // main actor, so its event is published inside the call and lands in the receipt.
        botHostObservers.append(center.addObserver(forName: .manualActionStateChanged, object: nil, queue: nil) { [weak self] note in
            guard let request = note.userInfo?[BotHostNotificationKey.request] as? ManualActionRequest,
                  let threadID = request.threadID else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.manualActionStateChanged(request, thread: threadID) }
            } else {
                Task { @MainActor [weak self] in self?.manualActionStateChanged(request, thread: threadID) }
            }
        })
        // Hops even on the main thread: `bot.guest.control` changes control under the
        // paired authority's lock, and the event reads that authority.
        botHostObservers.append(center.addObserver(forName: .botComputerControlChanged, object: nil, queue: nil) { [weak self] note in
            guard let source = note.object as? BotComputerControl,
                  let botID = note.userInfo?[BotHostNotificationKey.botID] as? BotID else { return }
            Task { @MainActor [weak self] in
                guard let self, source === self.botComputerControl else { return }
                self.publishGuestControlChanged(botID: botID)
            }
        })
        botHostObservers.append(center.addObserver(forName: .botMacExecutionRequested, object: nil, queue: nil) { [weak self] note in
            guard let info = note.userInfo,
                  let threadID = info[BotHostNotificationKey.threadID] as? AgentThreadID else { return }
            let reason = info[BotHostNotificationKey.reason] as? String ?? ""
            Task { @MainActor [weak self] in self?.handleMacExecutionRequested(threadID: threadID, reason: reason) }
        })
        botHostObservers.append(center.addObserver(forName: .botScreenshotPosted, object: nil, queue: nil) { [weak self] note in
            guard let info = note.userInfo,
                  let threadID = info[BotHostNotificationKey.threadID] as? AgentThreadID,
                  let jpeg = info[BotHostNotificationKey.jpeg] as? Data else { return }
            let reason = info[BotHostNotificationKey.reason] as? String ?? ""
            Task { @MainActor [weak self] in self?.handleBotScreenshotPosted(threadID: threadID, jpeg: jpeg, reason: reason) }
        })
        // Same drain a finished run triggers (AppContext.onRunFinished) for the send that queued behind a rebuild.
        botHostObservers.append(center.addObserver(forName: .botVMRebuildReleased, object: nil, queue: nil) { [weak self] note in
            guard let threadID = note.userInfo?[BotHostNotificationKey.threadID] as? AgentThreadID,
                  let botID = note.userInfo?[BotHostNotificationKey.botID] as? BotID else { return }
            Task { @MainActor [weak self] in await self?.handOffBotVM(botID: botID, to: threadID) }
        })
    }

    /// `stopsRun` is false when the thread was guessed rather than named by the caller:
    /// stopping a guess could halt another of the bot's threads while the requester runs on.
    private func handleManualActionRequested(_ request: ManualActionRequest, stopsRun: Bool) {
        guard let threadID = request.threadID else { return }
        // A late main-actor hop must not overwrite or re-announce a request the user already
        // resolved. A Mac card that saved it first (its observer can run before this hop)
        // still gets its event and push here, once.
        if let existing = manualActionStore.all(threadID: threadID).first(where: { $0.id == request.id }) {
            guard existing.state.isOpen else { return }
        } else {
            do { try manualActionStore.upsert(request) } catch {
                NSLog("RemoteCode: manual action request could not be saved: \(error)")
            }
        }
        publishManualActionUpdated(thread: threadID, requestID: request.id)
        guard let ctx = context else { return }
        // The pausing turn may already have ended; a fresh run id still passes the nested-worker check.
        let activeRun = try? ctx.runRepo.latestActive(for: threadID)
        let reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        ctx.postAgentUserActionPushIfNeeded(
            threadId: threadID,
            runId: activeRun?.id ?? AgentRunID(),
            requestId: request.id.uuidString,
            facts: TitioRequestFacts(
                kind: .manualAction,
                legacyActionTitle: "Waiting for you",
                detail: reason.isEmpty ? nil : reason,
                botName: ((try? ctx.botStore.get(id: request.botID)) ?? nil)?.name
            )
        )
        // The tool only asks the model to end its turn; the host enforces the pause so the bot
        // stops acting on the shared computer. The user's answer sends the one follow-up turn,
        // and the queue drain holds while the card is open (`botThreadAwaitsUser`).
        if stopsRun, activeRun != nil {
            ctx.coordinator.stopRun(threadId: threadID)
        }
    }

    private func manualActionStateChanged(_ request: ManualActionRequest, thread: AgentThreadID) {
        publishManualActionUpdated(thread: thread, requestID: request.id)
        if !request.state.isOpen {
            context?.titioNoticeCenter.sourceResolved(
                key: TitioNoticeIDs.threadAttention(threadId: thread.value.uuidString, requestId: request.id.uuidString)
            )
        }
        // Continue and Decline send a follow-up whose finish drains the held queue, so the bot
        // hears the answer first. A request closed with no answer re-arms the drain here.
        if request.state == .expired {
            context?.ensureQueueDrainWaiterIfNeeded(threadId: thread)
        }
    }

    /// A bot paused for the user (an open handoff card or a pending "run on the Mac?" request):
    /// its queued messages must not start a turn before the bot hears the answer.
    func botThreadAwaitsUser(_ thread: AgentThreadID) -> Bool {
        pendingMacExecution[thread] != nil || manualActionStore.open(threadID: thread) != nil
    }

    private func handleBotScreenshotPosted(threadID: AgentThreadID, jpeg: Data, reason: String) {
        do {
            _ = try publishAssistantImage(
                threadID: threadID, data: jpeg, displayName: "screenshot.jpg",
                mimeType: "image/jpeg", content: "📷 \(reason)"
            )
        } catch {
            NSLog("RemoteCode: bot screenshot could not be saved: \(error)")
        }
    }

    func publishAssistantImage(
        threadID: AgentThreadID, data: Data, displayName: String, mimeType: String, content: String
    ) throws -> (message: AgentMessage, attachmentID: String) {
        guard let ctx = context else { throw LayoutError.invalidLayout }
        let attachment = try agentAttachmentStore().stage(
            data: data, displayName: displayName, kind: .image, mimeType: mimeType
        )
        guard let attachmentID = attachment.id else {
            throw JSONRPCError(code: -32044, message: "Image could not be stored.")
        }
        let message = AgentMessage(
            threadId: threadID, role: .assistant, content: content, attachments: [attachment]
        )
        try ctx.messageRepo.append(message)
        EventBus.shared.publish(
            kind: .agentMessageAppended,
            payload: AgentMessageTransport.appendedEventPayload(from: message)
        )
        refreshAgentSurfaces(thread: threadID, reloadTranscriptIfSelected: true)
        return (message, attachmentID)
    }

    func publishAgentThreadUpdated(_ thread: AgentThread) {
        EventBus.shared.publish(kind: .agentThreadUpdated, payload: agentThreadPayload(thread))
    }

    private func publishAgentPlanNotesUpdated(thread: AgentThreadID, notes: String) {
        // Compact metadata/digest/preview only. Full notes on the event used to
        // overflow the WS outbound budget; clients rehydrate via
        // agent.plan.notes.get protocol_version 1. Persistence remains full.
        EventBus.shared.publish(
            kind: .agentPlanNotesUpdated,
            payload: PlanNotesProjectionV1.compactUpdateEvent(threadId: thread, notes: notes)
        )
    }

    private func publishAgentThreadRead(_ threadID: AgentThreadID) {
        EventBus.shared.publish(kind: .agentThreadRead, payload: .object([
            "thread_id": .string(threadID.value.uuidString)
        ]))
    }

    /// Full thread payload for host-UI-driven thread mirror events. Shape is
    /// IDENTICAL to Dispatcher.threadPayload so iOS decodes RPC-driven and
    /// mac-UI-driven mutations with one code path. provider_locked derives
    /// best-effort from the message repo (false on error).
    ///
    /// Must include `status` + `active_run_id` — without them, iOS Workspaces
    /// blue badge and Live Activity never learn about live agent runs that
    /// only surface as coordinator-owned work on the Mac pet.
    private func agentThreadPayload(_ thread: AgentThread) -> JSONValue {
        let locked = (try? context?.messageRepo.hasAny(threadId: thread.id)) ?? false
        var payload: [String: JSONValue] = [
            "id": .string(thread.id.value.uuidString),
            "thread_id": .string(thread.id.value.uuidString),
            "workspace_id": thread.workspaceId.map { .string($0.value.uuidString) } ?? .null,
            "title": .string(thread.title),
            "display_title": .string(AgentThreadTitle.display(thread.title)),
            "displayTitle": .string(AgentThreadTitle.display(thread.title)),
            "provider": .string(thread.provider.rawValue),
            "provider_instance_id": thread.providerInstanceId.map { .string($0) } ?? .null,
            "providerInstanceId": thread.providerInstanceId.map { .string($0) } ?? .null,
            "model": .string(thread.model),
            "status": .string(thread.status.rawValue),
            "has_unread": .bool(thread.hasUnread),
            "hasUnread": .bool(thread.hasUnread),
            "provider_locked": .bool(locked),
            "providerLocked": .bool(locked),
            "permission_mode": .string(thread.permissionMode.rawValue),
            "reasoning_effort": .string(thread.reasoningEffort.rawValue),
            "service_tier": .string(thread.serviceTier.rawValue),
            "model_selection": jsonValue(thread.modelSelection),
            "execution_mode": .string(thread.executionMode.rawValue)
        ]
        payload["base_branch"] = thread.baseBranch.map { .string($0) } ?? .null
        payload["worktree_path"] = thread.worktreePath.map { .string($0) } ?? .null
        payload["color"] = thread.color.map { .string($0) } ?? .null
        payload["pinned"] = .bool(thread.pinned)
        payload["sort_order"] = .number(Double(thread.sortOrder))
        appendAgentRouting(thread.effectiveRoutingConfiguration, to: &payload)
        appendAgentActiveRun(to: &payload, thread: thread.id)
        payload["pending_manual_action"] = ManualActionWire.pendingRow(pendingManualActions(for: [thread])[thread.id])
        // Same shape as Dispatcher.threadPayload.
        ThreadActorWire.append(
            thread: thread,
            guestRuntime: threadGuestRuntime(thread: thread.id),
            pendingMacExecutionReason: pendingMacExecution[thread.id],
            to: &payload
        )
        return .object(payload)
    }

    /// Mirrors Dispatcher.appendActiveRun so agent.thread.updated events carry
    /// the same host-owned run identity that agent.thread.list / encodeThread do.
    private func appendAgentActiveRun(
        to payload: inout [String: JSONValue],
        thread: AgentThreadID
    ) {
        guard let active = try? activeAgentRun(thread: thread) else {
            payload["active_run_id"] = .null
            payload["active_run_started_at_ms"] = .null
            return
        }
        payload["active_run_id"] = .string(active.runId.value.uuidString)
        payload["activeRunId"] = .string(active.runId.value.uuidString)
        payload["active_run_started_at_ms"] = .number(Double(
            Int64(active.startedAt.timeIntervalSince1970 * 1_000)
        ))
        // Force wire status to running when a host-owned run is live so clients
        // that also gate on status never drop the blue badge under DB lag.
        payload["status"] = .string(AgentRunStatus.running.rawValue)
    }

    private func appendAgentRouting(_ routing: AgentRoutingConfiguration, to payload: inout [String: JSONValue]) {
        let manualSelection = jsonValue(routing.manualSelection)
        let eligibleProviders = JSONValue.array(routing.eligibleProviders.map { .string($0.rawValue) })
        payload["routing"] = .object([
            "mode": .string(routing.mode.rawValue),
            "revision": .number(Double(routing.revision)),
            "manualSelection": manualSelection,
            "eligibleProviders": eligibleProviders,
            "policyDigest": .string(routing.policyDigest)
        ])
        payload["routing_mode"] = .string(routing.mode.rawValue)
        payload["routing_revision"] = .number(Double(routing.revision))
        payload["manual_selection"] = manualSelection
        payload["eligible_providers"] = eligibleProviders
        payload["policy_digest"] = .string(routing.policyDigest)
    }

    /// Mirrors macOS-UI thread lifecycle mutations (AgentAppViewModel
    /// onThreadLifecycle) onto the EventBus with the same event kinds the
    /// RPC paths publish, so connected mirrors stay live for mac-side CRUD.
    private func publishAgentThreadLifecycle(_ event: AgentThreadLifecycleEvent) {
        switch event {
        case .created(let thread):
            EventBus.shared.publish(kind: .agentThreadCreated, payload: agentThreadPayload(thread))
        case .updated(let thread):
            EventBus.shared.publish(kind: .agentThreadUpdated, payload: agentThreadPayload(thread))
        case .reordered(let workspaceId, let order):
            EventBus.shared.publish(kind: .agentThreadReordered, payload: .object([
                "workspace_id": .string(workspaceId.value.uuidString),
                "order": .array(order.map { .string($0.value.uuidString) })
            ]))
        case .deleted(let ids):
            let rawIDs = ids.map { $0.value.uuidString }
            let kind = ids.count > 1 ? "agent.thread.deleted_many" : "agent.thread.deleted"
            for surface in SurfaceRegistry.shared.all() {
                guard let agent = surface as? AgentAppSurface else { continue }
                agent.viewModel.handleThreadLifecycleEvent(
                    kind: kind,
                    threadId: rawIDs.count == 1 ? rawIDs[0] : nil,
                    threadIds: rawIDs.count > 1 ? rawIDs : nil
                )
            }
            if ids.count > 1 {
                EventBus.shared.publish(kind: .agentThreadDeletedMany, payload: .object([
                    "thread_ids": .array(ids.map { .string($0.value.uuidString) })
                ]))
            } else if let id = ids.first {
                EventBus.shared.publish(kind: .agentThreadDeleted, payload: .object([
                    "thread_id": .string(id.value.uuidString)
                ]))
            }
        }
    }

    func publishAgentThreadDeletions(_ ids: [AgentThreadID]) {
        guard !ids.isEmpty else { return }
        publishAgentThreadLifecycle(.deleted(ids))
    }

    func publishQueuedMessage(kind: String, _ message: AgentQueuedMessage) {
        guard let eventKind = RemoteCodeEventKind(rawValue: kind) else {
            assertionFailure("Unknown productive Agent queue event kind: \(kind)")
            return
        }
        var payload: [String: JSONValue] = [
            "id": .string(message.id.value.uuidString),
            "queued_message_id": .string(message.id.value.uuidString),
            "thread_id": .string(message.threadId.value.uuidString),
            "text": .string(message.text),
            "attachments": jsonValue(message.attachments.compactMap(AgentAttachmentReference.init)),
            "interaction_mode": .string(message.interactionMode.rawValue),
            "position": .number(Double(message.position)),
            "created_at": .string(iso8601Formatter.string(from: message.createdAt)),
            "updated_at": .string(iso8601Formatter.string(from: message.updatedAt))
        ]
        if let durableState = message.durableState {
            payload["durable_state"] = .string(durableState.rawValue)
            payload["durableState"] = .string(durableState.rawValue)
        }
        // Queue EventBus only needs workspace membership for iOS/mirror
        // routing. A full 26-column + routing `get` hitchs MainActor, and
        // reorder republishes every queued row.
        if let workspaceId = try? context?.threadRepo.workspaceId(of: message.threadId) {
            payload["workspace_id"] = .string(workspaceId.value.uuidString)
        }
        // iOS parity: the reason a queued message is not starting (D12).
        if let wait = BotVMRunRegistry.shared.waitingHolder(threadID: message.threadId) {
            payload["waiting_for_bot_vm"] = .object([
                "bot_id": .string(wait.botID.value.uuidString),
                "holder_thread_id": .string(wait.holder.threadID.value.uuidString),
                "holder_title": .string(wait.holder.title),
                "notice": .string(Self.botVMBusyNotice(holderTitle: wait.holder.title))
            ])
        }
        EventBus.shared.publish(kind: eventKind, payload: .object(payload))
    }

    private func jsonValue<T: Encodable>(_ value: T) -> JSONValue {
        // PERF: encode once, then JSONSerialization + JSONValue.from — avoids a
        // second full Codable walk via JSONDecoder (same as connectionSnapshotJSON /
        // workspaceCreatedPayload). Reuse jsonValueEncoder (MainActor-isolated).
        guard let data = try? jsonValueEncoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .null
        }
        return JSONValue.from(object)
    }

    public func withSuppressedLayoutEvents<T>(_ body: () throws -> T) rethrows -> T {
        suppressedLayoutEventDepth += 1
        defer { suppressedLayoutEventDepth -= 1 }
        return try body()
    }

    private var shouldPublishLayoutEvents: Bool {
        suppressedLayoutEventDepth == 0
    }

    /// Refresh every Agent App surface's rail / queue state for a thread mutation.
    ///
    /// Selection is PER-SURFACE. This helper must never rebind a tab that is
    /// viewing a different thread — that residual fan-out (`select: true` for
    /// every surface) made an iOS/CLI/RPC reply yank every open Agent App tab
    /// onto the target thread, so a response in one conversation appeared to
    /// affect both.
    ///
    /// When `reloadTranscriptIfSelected` is true, only surfaces ALREADY bound
    /// to `thread` re-select (load messages + timeline) so a remote send is
    /// visible on those tabs without changing sibling bindings.
    private func refreshAgentSurfaces(
        thread: AgentThreadID,
        workspace: WorkspaceID? = nil,
        reloadTranscriptIfSelected: Bool = false
    ) {
        let resolvedWorkspace: WorkspaceID?
        if let workspace {
            resolvedWorkspace = workspace
        } else {
            // Chrome lives on the painted rail. This hop only needs workspace
            // membership; a full 26-column + routing `get` hitchs MainActor.
            resolvedWorkspace = try? context?.threadRepo.workspaceId(of: thread)
        }
        var workspacesNeedingRailReload = Set<WorkspaceID>()
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface,
                  resolvedWorkspace == nil || agent.viewModel.workspaceID == resolvedWorkspace! else { continue }
            workspacesNeedingRailReload.insert(agent.viewModel.workspaceID)
            if reloadTranscriptIfSelected,
               agent.viewModel.selectedThreadId == thread,
               !agent.viewModel.isHiddenFromSurface {
                agent.viewModel.selectThread(thread, markRead: false)
            }
        }
        for workspaceID in workspacesNeedingRailReload {
            AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: workspaceID)
            AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedQueueReload(workspaceID: workspaceID)
        }
        windowController?.refreshFromState()
    }

    /// Walk the restored layout state and instantiate fresh Surface
    /// views for every descriptor. Surfaces are rebuilt with new IDs
    /// (their old IDs were owned by surfaces that no longer exist), so
    /// we rewrite the layout state to refer to the new IDs and update
    /// selectedSurfaceID per pane.
    public func reinstantiateRestoredSurfaces() {
        guard let ctx = context else { return }
        let terminalFontSize = SettingsStore(db: ctx.db).load().terminalFontSize
        var idMap: [SurfaceID: SurfaceID] = [:]
        for (wid, ws) in ctx.state.workspaces {
            forEachSurface(in: ws.layout) { desc in
                let cwd = ws.cwd
                let title = desc.title
                do {
                    let surface: Surface
                    switch desc.type {
                    case .terminal:
                        surface = configureTerminalSurface(
                            try TerminalSurface(workspaceID: wid, title: title, launch: .shell(cwd: cwd), restoredSurfaceID: desc.id, historyRepo: ctx.terminalOutputRepo, settingsRepo: ctx.settingsRepo, terminalFontSize: terminalFontSize),
                            workspace: wid
                        )
                    case .ssh:
                        if let profile = sshProfile(from: desc) {
                            surface = configureTerminalSurface(
                                try TerminalSurface(workspaceID: wid, title: title, launch: .ssh(profile: profile, cwd: cwd), restoredSurfaceID: desc.id, historyRepo: ctx.terminalOutputRepo, settingsRepo: ctx.settingsRepo, terminalFontSize: terminalFontSize),
                                workspace: wid
                            )
                        } else {
                            let ssh = try SSHSurface(
                                workspaceID: wid,
                                cwd: cwd,
                                title: title,
                                router: self,
                                restoredSurfaceID: desc.id,
                                historyRepo: ctx.terminalOutputRepo,
                                settingsRepo: ctx.settingsRepo,
                                terminalFontSize: terminalFontSize
                            )
                            configureSSHBusy(ssh, workspace: wid)
                            surface = ssh
                        }
                    case .browser:
                        let botID = desc.metadata["bot_id"].flatMap { UUID(uuidString: $0) }.map(BotID.init)
                        var restored = restoredBrowserURL(from: desc)
                        if restored == nil, let botID, let ctx = context {
                            if let target = try? BotBrowserStore(appSupportDirectory: ctx.appSupportDirectory).loadTarget(botID: botID) {
                                restored = URL(string: target.url)
                            }
                        }
                        surface = configureBrowserSurface(
                            BrowserSurface(workspaceID: wid, initialURL: restored, title: title, botID: botID),
                            workspace: wid
                        )
                    case .agentApp:
                        // Per-surface thread binding restore: prefer the persisted
                        // `selected_thread`. Legacy surfaces (saved before binding
                        // existed) have no metadata — fall back ONCE to the
                        // workspace's first thread so the tab isn't blank, then
                        // future selections self-persist. New tabs that were never
                        // bound restore to the fresh-composer state (nil).
                        let restoredThreadId: AgentThreadID? = {
                            if let raw = desc.metadata["selected_thread"], let uuid = UUID(uuidString: raw) {
                                return AgentThreadID(uuid)
                            }
                            if desc.metadata["selected_thread"] == nil {
                                return (try? ctx.threadRepo.list(workspaceId: wid))?.first?.id
                            }
                            return nil
                        }()
                        let agent = AgentAppSurface(workspaceID: wid, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, queuedMessageRepo: ctx.queuedMessageRepo, providerSessionRepo: ctx.providerSessionRuntimeRepo, pendingCallbackRepo: ctx.providerPendingCallbackRepo, proposedPlanRepo: ctx.proposedPlanRepo, checkpointRepo: ctx.turnCheckpointRepo, promptHistoryStore: PromptHistoryStore(db: ctx.db), customModelStore: AgentCustomModelStore(repo: ctx.settingsRepo), planNotesStore: PlanNotesStore(db: ctx.db), title: title, initialThreadId: restoredThreadId, orchestrationRuntime: ctx.orchestrationRuntime, openAccountsSettings: openAccountsSettings)
                        agent.viewModel.onSelectedThreadChanged = { [weak self, weak agent] threadID in
                            guard let self, let agent else { return }
                            self.persistAgentSelectedThread(surfaceID: agent.descriptor.id, threadID: threadID)
                        }
                        // Restore-time select does not re-fire onSelectedThreadChanged;
                        // still arm live retention protection for the restored thread.
                        ctx.threadRepo.setLiveSurfaceBinding(
                            surfaceID: agent.descriptor.id,
                            threadID: agent.viewModel.selectedThreadId
                        )
                        agent.viewModel.markThreadRead = { [weak self] threadID in
                            guard let self else { throw LayoutError.workspaceNotFound }
                            try self.markAgentThreadRead(thread: threadID)
                        }
                        let queueSubscriptionToken = EventBus.shared.subscribe(
                            since: nil,
                            filter: .agentThreadAndQueue
                        ) { [weak agent] ev in
                            guard Self.shouldAdmitAgentLifecycleEvent(
                                payload: ev.payload,
                                workspaceID: wid
                            ) else { return }
                            DispatchQueue.main.async {
                                guard let agent else { return }
                                agent.viewModel.handleThreadLifecycleEvent(
                                    kind: ev.kind,
                                    threadId: ev.payload.objectValue?["thread_id"]?.stringValue,
                                    threadIds: ev.payload.objectValue?["thread_ids"]?.arrayValue?.compactMap(\.stringValue)
                                )
                                agent.viewModel.handleQueueLifecycleEvent(
                                    kind: ev.kind,
                                    threadId: ev.payload.objectValue?["thread_id"]?.stringValue,
                                    message: ev.payload.objectValue?["message"]?.stringValue
                                )
                                // Coalesce N open Agent tabs → one cap+list + queue reload per workspace.
                                AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(
                                    workspaceID: agent.viewModel.workspaceID
                                )
                                AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedQueueReload(
                                    workspaceID: agent.viewModel.workspaceID
                                )
                            }
                        }
                        agent.subscriptionToken = AnyHashable(queueSubscriptionToken)
                        agent.onClose = { EventBus.shared.unsubscribe(queueSubscriptionToken) }
                        agent.viewModel.providerSnapshotLoader = { [weak self, weak agent] in
                            // Probe as the composer run-as-user so Auto admission
                            // matches the account Claude will actually exec as.
                            await self?.listAgentProviderSnapshots(runAsUser: agent?.viewModel.runAsUser) ?? []
                        }
                        agent.viewModel.refreshProviderSnapshotsInBackground()
                        agent.viewModel.providerLaunchConfig = { [weak self] provider, instanceId in
                            (
                                self?.providerBinary(provider: provider, instanceId: instanceId),
                                self?.providerEnvironment(provider: provider, instanceId: instanceId) ?? [:]
                            )
                        }
                        agent.viewModel.providerRecoveryAction = { [weak self] provider, instanceId in
                            guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
                            let result = try await self.updateAgentProvider(provider: provider, providerInstanceId: instanceId)
                            return result.objectValue?["stdout"]?.stringValue ?? ""
                        }
                        agent.viewModel.providerSignInAction = { [weak self] provider in
                            guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
                            try self.openProviderSignInTerminal(workspace: wid, provider: provider)
                        }
                        agent.viewModel.providerAuthenticationRefresher = { [weak self] provider in
                            await self?.refreshAgentProviderAuthentication(provider) ?? []
                        }
                        agent.viewModel.pullRequestThreadPreparer = { [weak self] url, provider, model, permission, reasoning, serviceTier, modelSelection, providerInstanceId in
                            guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
                            return try self.prepareAgentThreadForPullRequest(workspace: wid, url: url, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId)
                        }
                        agent.viewModel.onReviewRequested = { [weak self] in
                            _ = try? self?.createSurface(workspace: wid, type: .rightSidebarTool, paneID: nil, title: "Git")
                        }
                        // UX-MAC_AGENT-OPEN-SPLIT: clicked file mentions / links open
                        // (or reuse) a split panel to the right of this agent surface.
                        agent.viewModel.onOpenFileInSplit = { [weak self, weak agent] path in
                            guard let self, let agent else { return }
                            self.openFileInAdjacentSplit(workspace: wid, sourceSurface: agent.descriptor.id, absolutePath: path)
                        }
                        agent.viewModel.onOpenURLInSplit = { [weak self, weak agent] url in
                            guard let self, let agent else { return }
                            self.openURLInAdjacentSplit(workspace: wid, sourceSurface: agent.descriptor.id, url: url)
                        }
                        agent.viewModel.onForkInNewChat = { [weak self, weak agent] messageID in
                            guard let self, let agent, let source = agent.viewModel.selectedThreadId else { return }
                            Task { @MainActor in
                                do {
                                    let child = try await self.forkAgentThread(sourceThreadId: source, messageID: messageID)
                                    agent.viewModel.selectThread(child.id)
                                } catch {
                                    agent.viewModel.statusMessage = "Could not fork thread: \(error)"
                                }
                            }
                        }
                        agent.viewModel.onRequestSideChat = { [weak self, weak agent] text in
                            guard let self, let agent, let source = agent.viewModel.selectedThreadId else { return }
                            Task { @MainActor in
                                do {
                                    let child = try await self.sideAgentThread(sourceThreadId: source, text: text.isEmpty ? nil : text)
                                    self.openSideChatSplit(workspace: wid, sourceSurface: agent.descriptor.id, threadId: child.id, seed: text.isEmpty ? nil : text)
                                } catch {
                                    agent.viewModel.statusMessage = "Could not open side chat: \(error)"
                                }
                            }
                        }
                        agent.viewModel.onRequestBtw = { [weak self, weak agent] question in
                            guard let self, let agent, let source = agent.viewModel.selectedThreadId else { return }
                            Task { @MainActor in
                                do {
                                    let answer = try await self.btwAgentThread(threadId: source, question: question)
                                    agent.viewModel.appendBtwNote(question: question, answer: answer)
                                } catch {
                                    agent.viewModel.statusMessage = "Could not get side answer: \(error)"
                                }
                            }
                        }
                        agent.viewModel.onRunStateChange = { [weak self] in
                            guard let self else { return }
                            if !self.promoteWorkspaceIfBusy(wid) {
                                self.windowController?.refreshSurfaceRuntimeState()
                            }
                        }
                        agent.viewModel.onRunCompleted = { [weak self] in
                            self?.promoteWorkspaceAfterCompletedRun(wid)
                        }
                        agent.viewModel.onThreadConfigPersisted = { [weak self] thread in
                            self?.publishAgentThreadUpdated(thread)
                        }
                        agent.viewModel.onThreadLifecycle = { [weak self] event in
                            self?.publishAgentThreadLifecycle(event)
                        }
                        agent.viewModel.onThreadChromeWritten = { write in
                            write.publish()
                        }
                        agent.viewModel.retireDeletedThreadRuntime = { [weak ctx] ids, coordinatorAlreadyRetired in
                            ctx?.retireDeletedAgentThreads(
                                ids,
                                coordinatorAlreadyRetired: coordinatorAlreadyRetired
                            )
                        }
                        Self.wireScheduledRunControl(on: agent.viewModel, db: ctx.db)
                        wireQueueDrainControl(on: agent.viewModel, context: ctx)
                        wireBotPeerHandoffDeletion(on: agent.viewModel, context: ctx)
                        configureAgentAppBotMentions(agent)
                        agent.viewModel.onPlanNotesPersisted = { [weak self] thread, notes in
                            self?.publishAgentPlanNotesUpdated(thread: thread, notes: notes)
                        }
                        agent.viewModel.onQueuedMessageEvent = { [weak self] kind, message in
                            self?.publishQueuedMessage(kind: kind, message)
                        }
                        surface = agent
                    case .files:
                        surface = FilesSurface(workspaceID: wid, cwd: cwd, title: title, router: self, initialState: desc.metadata["files_state"], selectedPath: desc.metadata["selected_path"] ?? desc.metadata["selected_relative_path"])
                    case .markdown:
                        surface = MarkdownSurface(workspaceID: wid, filePath: desc.metadata["path"], title: title)
                    case .filePreview:
                        surface = FilePreviewSurface(workspaceID: wid, filePath: desc.metadata["path"], title: title)
                    case .rightSidebarTool where WorkspaceTool.from(metadata: desc.metadata, title: title) != nil:
                        surface = WorkspaceToolSurface(tool: WorkspaceTool.from(metadata: desc.metadata, title: title)!, workspaceID: wid, title: title, router: self)
                    case .rightSidebarTool:
                        let diff = DiffPanelSurface(workspaceID: wid, cwd: cwd, title: title, settings: SettingsStore(db: ctx.db))
                        diff.onBusyStateChanged = { [weak self, weak diff] busy in
                            guard let self, let diff else { return }
                            self.surfaceBusyDidChange(workspace: wid, surface: diff.descriptor.id, busy: busy)
                        }
                        surface = diff
                    }
                    idMap[desc.id] = surface.descriptor.id
                    SurfaceRegistry.shared.register(surface)
                } catch {
                    appRouterLog.error("surface.restore.failed id=\(desc.id, privacy: .public) type=\(String(describing: desc.type), privacy: .public) error=\(String(describing: error), privacy: .public)")
                    restoreFailedSurfaceIDs.append(desc.id)
                }
            }
        }
        guard !idMap.isEmpty else { return }
        for (wid, ws) in ctx.state.workspaces {
            var copy = ws
            copy.layout = remapIDs(in: copy.layout, idMap: idMap)
            ctx.state.workspaces[wid] = copy
        }
        reconcileSurfaceVisibility()
    }

    private func forEachSurface(in node: LayoutNode, _ visit: (SurfaceDescriptor) -> Void) {
        switch node {
        case .pane(let p): for s in p.surfaces { visit(s) }
        case .split(let s): for c in s.children { forEachSurface(in: c, visit) }
        }
    }

    public func reconcileSurfaceVisibility() {
        guard let ctx = context else {
            SurfaceRegistry.shared.setVisibleSurfaceIDs([])
            return
        }
        let workspaceIDs = visibleWorkspaceIDs()
        let visibleIDs = workspaceIDs.reduce(into: Set<SurfaceID>()) { ids, workspaceID in
            guard let ws = ctx.state.workspaces[workspaceID] else { return }
            ids.formUnion(selectedSurfaceIDs(in: ws.layout))
        }
        SurfaceRegistry.shared.setVisibleSurfaceIDs(visibleIDs)
    }

    /// Workspace IDs with a selected workspace across windows plus detached
    /// visible ones. Single pass with a reserved set; no compactMap intermediate.
    private func visibleWorkspaceIDs() -> Set<WorkspaceID> {
        guard let ctx = context else { return [] }
        var workspaceIDs = Set<WorkspaceID>()
        workspaceIDs.reserveCapacity(ctx.state.windows.count)
        for window in ctx.state.windows {
            if let selected = window.selectedWorkspaceID {
                workspaceIDs.insert(selected)
            }
        }
        if let detached = windowController?.detachedVisibleWorkspaceIDsForSurfaceReconciliation() {
            workspaceIDs.formUnion(detached)
        }
        return workspaceIDs
    }

    private func selectedSurfaceIDs(in node: LayoutNode) -> Set<SurfaceID> {
        selectedSurfaceIDs(in: node, paneVisible: true)
    }

    private func selectedSurfaceIDs(in node: LayoutNode, paneVisible: Bool) -> Set<SurfaceID> {
        switch node {
        case .pane(let pane):
            guard paneVisible else { return [] }
            if let selected = pane.selectedSurfaceID ?? pane.surfaces.first?.id {
                return [selected]
            }
            return []
        case .split(let split):
            let ratios = SplitNode.normalize(split.ratios)
            return split.children.enumerated().reduce(into: Set<SurfaceID>()) { ids, item in
                let ratio = ratios.indices.contains(item.offset) ? ratios[item.offset] : 0
                let childVisible = paneVisible && ratio > Self.minimizedPaneVisibilityThreshold
                ids.formUnion(selectedSurfaceIDs(in: item.element, paneVisible: childVisible))
            }
        }
    }

    private func focusedSelectedSurfaceID(in workspace: Workspace) -> SurfaceID? {
        if let focusedPaneID = workspace.focusedPaneID,
           let pane = workspace.layout.find(paneID: focusedPaneID) {
            return pane.selectedSurfaceID ?? pane.surfaces.first?.id
        }
        return selectedSurfaceIDs(in: workspace.layout).first
    }

    private func remapIDs(in node: LayoutNode, idMap: [SurfaceID: SurfaceID]) -> LayoutNode {
        switch node {
        case .pane(var p):
            p.surfaces = p.surfaces.map { d in
                let new = idMap[d.id] ?? d.id
                return SurfaceDescriptor(id: new, type: d.type, title: d.title, iconName: d.iconName,
                                          isDirty: d.isDirty, hasUnreadActivity: d.hasUnreadActivity, metadata: d.metadata)
            }
            if let sel = p.selectedSurfaceID { p.selectedSurfaceID = idMap[sel] ?? sel }
            return .pane(p)
        case .split(var s):
            s.children = s.children.map { remapIDs(in: $0, idMap: idMap) }
            return .split(s)
        }
    }

    public func listWorkspaces() throws -> [Workspace] {
        guard let ctx = context else { return [] }
        let ids = ctx.state.window.workspaces
        return ids.compactMap { id in
            guard var ws = ctx.state.workspaces[id] else { return nil }
            // This synchronous path feeds local UI/layout callers only. Combine
            // live surface activity with the lifecycle-time, in-memory agent-run
            // projection. Do not synchronously read durable thread rows here.
            let busySurface = ws.layout.paneIDs().contains { pid in
                (ws.layout.find(paneID: pid)?.surfaces ?? []).contains { isWorkspaceActivitySurface($0) }
            }
            let busy = busySurface || ctx.hasActiveAgentRun(in: id)
            if busy { ws.metadata["busy"] = "true" }
            else { ws.metadata.removeValue(forKey: "busy") }
            return ws
        }
    }

    /// Authoritative workspace.list read for request/response transports.
    /// MainActor captures the live layout and surface activity inputs; durable
    /// thread state and the busy projection are completed by the gateway off
    /// MainActor before the response is encoded.
    public func listWorkspacesAuthoritative() async throws -> [Workspace] {
        guard let ctx = context else { return [] }
        let snapshots = ctx.state.window.workspaces.compactMap { id -> WorkspaceListReadSnapshot? in
            guard let workspace = ctx.state.workspaces[id] else { return nil }
            var busySurfaceIDs = Set<SurfaceID>()
            forEachSurface(in: workspace.layout) { descriptor in
                if isWorkspaceActivitySurface(descriptor) {
                    busySurfaceIDs.insert(descriptor.id)
                }
            }
            return WorkspaceListReadSnapshot(
                workspace: workspace,
                busySurfaceIDs: busySurfaceIDs
            )
        }
        return try await ctx.workspaceListGateway.list(snapshots: snapshots)
    }

    public func readConnectionSnapshotState() async throws -> ConnectionSnapshotReadState {
        guard let ctx = context else {
            return ConnectionSnapshotReadState(
                selectedWorkspaceId: nil,
                workspaces: [],
                surfaces: [],
                agentThreads: [],
                browserStates: [],
                filesStates: []
            )
        }
        let signposter = PerfSwitchMetrics.signposter
        let captureInterval = signposter.beginInterval(
            "connection_snapshot_capture",
            id: signposter.makeSignpostID()
        )
        let workspaceIDs = ctx.state.window.workspaces
        let workspaces = workspaceIDs.compactMap { ctx.state.workspaces[$0] }
        let selectedWorkspaceId = ctx.state.window.selectedWorkspaceID?.value.uuidString
        // Capture all MainActor-owned layout/surface inputs before suspending for
        // SQLite. Otherwise a local persistence/layout callback can run during
        // the await and mix two host-state versions in one snapshot.
        var descriptorsByWorkspace: [String: [SurfaceDescriptor]] = [:]
        var browserURLs: [String: String] = [:]
        for workspace in workspaces {
            var descriptors: [SurfaceDescriptor] = []
            forEachSurface(in: workspace.layout) { descriptors.append(Self.clientSurfaceDescriptor($0)) }
            descriptorsByWorkspace[workspace.id.value.uuidString] = descriptors
            for descriptor in descriptors where descriptor.type == .browser {
                browserURLs[descriptor.id.value.uuidString] =
                    (try? browserSurface(descriptor.id).currentURL())
                    ?? descriptor.metadata["url"]
                    ?? ""
            }
        }
        let openManualActions = manualActionStore.openByThread()
        let pendingMacExecutions = pendingMacExecution
        signposter.endInterval("connection_snapshot_capture", captureInterval)
        // SQLite list/decode must never run on MainActor (Dispatcher is @MainActor).
        let threads = try await ctx.agentThreadListGateway.list(workspaceId: nil)
        let guestRuntimes = await threadGuestRuntimesOffMain()
        let manualActionsByThread = pendingManualActions(for: threads, open: openManualActions)
        // Grouping and the per-row JSON round trip are pure work on the
        // captured values: run them detached so MainActor stays free.
        return await Task.detached(priority: .userInitiated) {
            let encodeInterval = signposter.beginInterval(
                "connection_snapshot_encode",
                id: signposter.makeSignpostID()
            )
            defer { signposter.endInterval("connection_snapshot_encode", encodeInterval) }
            return Self.connectionSnapshotState(
                selectedWorkspaceId: selectedWorkspaceId,
                workspaces: workspaces,
                descriptorsByWorkspace: descriptorsByWorkspace,
                browserURLs: browserURLs,
                threads: threads,
                manualActionsByThread: manualActionsByThread,
                guestRuntimes: guestRuntimes,
                pendingMacExecutions: pendingMacExecutions
            )
        }.value
    }

    nonisolated private static func connectionSnapshotState(
        selectedWorkspaceId: String?,
        workspaces: [Workspace],
        descriptorsByWorkspace: [String: [SurfaceDescriptor]],
        browserURLs: [String: String],
        threads: [AgentThread],
        manualActionsByThread: [AgentThreadID: ManualActionSnapshot],
        guestRuntimes: [AgentThreadID: String],
        pendingMacExecutions: [AgentThreadID: String]
    ) -> ConnectionSnapshotReadState {
        var surfaceGroups: [ConnectionSnapshotWorkspaceItems] = []
        var threadGroups: [ConnectionSnapshotWorkspaceItems] = []
        var browserStates: [ConnectionSnapshotSurfaceState] = []
        var filesStates: [ConnectionSnapshotSurfaceState] = []

        for workspace in workspaces {
            let descriptors = descriptorsByWorkspace[workspace.id.value.uuidString] ?? []
            let workspaceThreads = threads
                .filter { $0.workspaceId == workspace.id }
                .sorted { $0.id.value.uuidString < $1.id.value.uuidString }
            // Drop dangling selected_thread metadata so iOS snapshot validation
            // does not reject the whole connection when a bound thread is gone.
            let validThreadIds = Set(workspaceThreads.map { $0.id.value.uuidString })
            surfaceGroups.append(ConnectionSnapshotWorkspaceItems(
                workspaceId: workspace.id.value.uuidString,
                items: descriptors.map {
                    Self.connectionSnapshotSurface($0, validSelectedThreadIds: validThreadIds)
                }
            ))
            threadGroups.append(ConnectionSnapshotWorkspaceItems(
                workspaceId: workspace.id.value.uuidString,
                items: workspaceThreads.map {
                    Self.connectionSnapshotThread(
                        $0,
                        pendingManualAction: manualActionsByThread[$0.id],
                        guestRuntime: guestRuntimes[$0.id],
                        pendingMacExecutionReason: pendingMacExecutions[$0.id]
                    )
                }
            ))

            for descriptor in descriptors {
                switch descriptor.type {
                case .browser:
                    let url = browserURLs[descriptor.id.value.uuidString]
                        ?? descriptor.metadata["url"]
                        ?? ""
                    browserStates.append(ConnectionSnapshotSurfaceState(
                        workspaceId: workspace.id.value.uuidString,
                        surfaceId: descriptor.id.value.uuidString,
                        state: .object(["url": .string(url)])
                    ))
                case .files:
                    let stored = Self.decodeFilesState(descriptor.metadata["files_state"])
                    let stableState = stored ?? [
                        "surface_id": .string(descriptor.id.value.uuidString),
                        "workspace_id": .string(workspace.id.value.uuidString),
                        "selected_path": descriptor.metadata["selected_path"].map(JSONValue.string) ?? .null,
                        "revision": .number(Double(
                            descriptor.metadata["files_state_revision"].flatMap(Int.init) ?? 0
                        )),
                    ]
                    filesStates.append(ConnectionSnapshotSurfaceState(
                        workspaceId: workspace.id.value.uuidString,
                        surfaceId: descriptor.id.value.uuidString,
                        state: .object(stableState)
                    ))
                case .terminal, .ssh, .agentApp, .markdown, .filePreview, .rightSidebarTool:
                    break
                }
            }
        }

        return ConnectionSnapshotReadState(
            selectedWorkspaceId: selectedWorkspaceId,
            workspaces: workspaces.map(Self.connectionSnapshotWorkspace),
            surfaces: surfaceGroups,
            agentThreads: threadGroups,
            browserStates: browserStates,
            filesStates: filesStates
        )
    }

    // PERF: sync.snapshot maps every workspace/surface/thread through
    // connectionSnapshotJSON. JSONEncoder is not thread-safe — share one under
    // a short lock instead of allocating per row.
    private static let connectionSnapshotEncodeLock = NSLock()
    private static let connectionSnapshotEncoder = JSONEncoder()

    nonisolated private static func connectionSnapshotJSON<T: Encodable>(_ value: T) -> JSONValue {
        connectionSnapshotEncodeLock.lock()
        let data = try? connectionSnapshotEncoder.encode(value)
        connectionSnapshotEncodeLock.unlock()
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .null
        }
        return JSONValue.from(object)
    }

    nonisolated private static func connectionSnapshotWorkspace(_ workspace: Workspace) -> JSONValue {
        guard case .object(var object) = connectionSnapshotJSON(workspace) else { return .null }
        object["id"] = .string(workspace.id.value.uuidString)
        return .object(object)
    }

    nonisolated private static func connectionSnapshotSurface(
        _ surface: SurfaceDescriptor,
        validSelectedThreadIds: Set<String> = []
    ) -> JSONValue {
        guard case .object(var object) = connectionSnapshotJSON(surface) else { return .null }
        object["id"] = .string(surface.id.value.uuidString)
        object["type"] = .string(surface.type.rawValue)
        if case .object(var metadata) = object["metadata"],
           case .string(let selected) = metadata["selected_thread"],
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !validSelectedThreadIds.contains(selected) {
            metadata.removeValue(forKey: "selected_thread")
            object["metadata"] = .object(metadata)
        }
        return .object(object)
    }

    nonisolated private static func connectionSnapshotThread(
        _ thread: AgentThread,
        pendingManualAction: ManualActionSnapshot?,
        guestRuntime: String?,
        pendingMacExecutionReason: String?
    ) -> JSONValue {
        guard case .object(var object) = connectionSnapshotJSON(thread) else { return .null }
        object["id"] = .string(thread.id.value.uuidString)
        object["workspaceId"] = thread.workspaceId
            .map { .string($0.value.uuidString) }
            ?? .null
        object["pending_manual_action"] = ManualActionWire.pendingRow(pendingManualAction)
        ThreadActorWire.append(
            thread: thread,
            guestRuntime: guestRuntime,
            pendingMacExecutionReason: pendingMacExecutionReason,
            to: &object
        )
        return .object(object)
    }

    public func isWorkspaceBusy(_ id: WorkspaceID) -> Bool {
        guard let ctx = context,
              let ws = ctx.state.workspaces[id] else { return false }
        if ctx.hasActiveAgentRun(in: id) { return true }
        return ws.layout.paneIDs().contains { pid in
            (ws.layout.find(paneID: pid)?.surfaces ?? []).contains {
                isWorkspaceActivitySurface($0)
            }
        }
    }

    private func isWorkspaceActivitySurface(_ descriptor: SurfaceDescriptor) -> Bool {
        guard SurfaceRegistry.shared.surface(descriptor.id)?.isBusy == true else { return false }
        switch descriptor.type {
        case .terminal, .agentApp:
            return true
        case .ssh, .browser, .files, .markdown, .filePreview, .rightSidebarTool:
            return false
        }
    }

    public func currentWindow() throws -> AppWindow {
        context?.state.window ?? AppWindow()
    }

    public func listWindows() throws -> [AppWindow] {
        context?.state.windows ?? []
    }

    public func createWindow(title: String?) throws -> AppWindow {
        try context?.apply(.createWindow(title: title))
        let w = try currentWindow()
        windowController?.openAdditionalWindow(for: w)
        reconcileSurfaceVisibility()
        return w
    }

    public func focusWindow(_ id: WindowID) throws {
        try context?.apply(.focusWindow(id))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        windowController?.repairSelectedTerminalFocus(reason: "window_focus")
    }

    public func closeWindow(_ id: WindowID) throws {
        try context?.apply(.closeWindow(id))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
    }

    public func moveWorkspaceToWindow(workspace: WorkspaceID, target: WindowID) throws {
        try context?.apply(.moveWorkspaceToWindow(workspace, target))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
    }

    public func paneSwap(workspace: WorkspaceID, a: PaneID, b: PaneID) throws {
        try context?.apply(.swapPanes(workspace, a, b))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
    }

    public func createWorkspace(name: String, cwd: String) throws -> Workspace {
        guard let ctx = context else { throw NSError(domain: "rc2", code: 0) }
        try ctx.apply(.createWorkspace(name: name, cwd: cwd, initial: nil))
        guard let id = ctx.state.window.selectedWorkspaceID else { throw LayoutError.workspaceNotFound }
        // A new workspace opens with Agent App as the default selected tab.
        let agent = makeSurface(type: .agentApp, title: defaultTitle(for: .agentApp), workspace: id, cwd: cwd)
        try ctx.apply(.addSurface(id, paneID: nil, descriptor: agent))
        guard let ws = ctx.state.workspaces[id] else { throw LayoutError.workspaceNotFound }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishWorkspaceCreated(ws)
        return ws
    }

    public func createWorkspace(fromFolder url: URL) throws -> Workspace {
        let folder = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard folder.isFileURL,
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LayoutError.workspaceNotFound
        }
        return try createWorkspace(name: folder.lastPathComponent, cwd: folder.path)
    }

    public func selectWorkspace(_ id: WorkspaceID) throws {
        if context?.state.window.selectedWorkspaceID == id {
            return
        }
        try context?.apply(.selectWorkspace(id))
        windowController?.refreshFromState()
        if shouldPublishLayoutEvents {
            // The canonical mirror must be observable before selectWorkspace
            // returns so paired terminal clients cannot lag behind local state.
            EventBus.shared.publish(kind: .workspaceSelected, payload: .object([
                "workspace_id": .string(id.value.uuidString)
            ]))
        }
        // The reducer is the synchronous selection authority; surface
        // reconciliation and focus repair are freshness work. Deferring them
        // lets the cached content paint before any surface walk or focus repair
        // runs. The canonical mirror remains synchronous for terminal clients.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconcileSurfaceVisibility()
            self.windowController?.repairSelectedTerminalFocus(reason: "workspace_select")
        }
    }

    public func closeWorkspace(_ id: WorkspaceID, publishEvent: Bool = true) throws {
        // Collect surface IDs before the layout is mutated so we can purge their
        // terminal history after the workspace is removed. Guard: only surfaces that
        // belong to this workspace are collected; live surfaces in other workspaces
        // are never touched.
        var surfaceIDsToDelete: [SurfaceID] = []
        if let ws = context?.state.workspaces[id] {
            forEachSurface(in: ws.layout) { desc in
                surfaceIDsToDelete.append(desc.id)
            }
        }
        try context?.apply(.closeWorkspace(id))
        if let ctx = context {
            try? PromptHistoryStore(db: ctx.db).delete(workspaceID: id)
            surfaceIDsToDelete.forEach(permanentlyCloseRuntimeSurface)
        }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        if publishEvent {
            publishWorkspaceClosed(id)
        }
    }

    public func closeWorkspaces(_ ids: [WorkspaceID]) throws {
        guard let ctx = context else { throw NSError(domain: "rc2", code: 0) }
        var seen: Set<WorkspaceID> = []
        let uniqueIds = ids.filter { seen.insert($0).inserted }
        guard !uniqueIds.isEmpty else { return }
        guard uniqueIds.allSatisfy({ ctx.state.workspaces[$0] != nil }) else { throw LayoutError.workspaceNotFound }
        // Collect surface IDs before the layout is mutated.
        var surfaceIDsToDelete: [SurfaceID] = []
        for id in uniqueIds {
            if let ws = ctx.state.workspaces[id] {
                forEachSurface(in: ws.layout) { desc in
                    surfaceIDsToDelete.append(desc.id)
                }
            }
        }
        for id in uniqueIds {
            try ctx.apply(.closeWorkspace(id))
        }
        let store = PromptHistoryStore(db: ctx.db)
        uniqueIds.forEach { try? store.delete(workspaceID: $0) }
        surfaceIDsToDelete.forEach(permanentlyCloseRuntimeSurface)
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        uniqueIds.forEach(publishWorkspaceClosed)
    }

    public func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws {
        try context?.apply(.renameWorkspace(id, newName))
        windowController?.refreshFromState()
        publishWorkspaceRenamed(id, newName)
    }

    public func setWorkspaceDescription(_ id: WorkspaceID, _ text: String) throws {
        try context?.apply(.setWorkspaceDescription(id, text))
        windowController?.refreshFromState()
        publishWorkspaceUpdated(id, metadata: ["description": .string(text)])
    }

    public func setWorkspaceColor(_ id: WorkspaceID, _ color: String) throws {
        try context?.apply(.setWorkspaceColor(id, color))
        windowController?.refreshFromState()
        publishWorkspaceUpdated(id, metadata: ["color": .string(color)])
    }

    private func publishWorkspaceClosed(_ id: WorkspaceID) {
        EventBus.shared.publish(kind: .workspaceClosed, payload: .object([
            "workspace_id": .string(id.value.uuidString)
        ]))
    }

    // P1: publish workspace.created/renamed/updated/reordered from the router's
    // own mutation paths so iOS mirrors mac-local sidebar edits live. The
    // payloads below must match the Dispatcher schema exactly (Dispatcher.swift
    // workspace.* cases) so iOS consumes router- and dispatcher-originated
    // events through the same reducer. Builders are pure + nonisolated so they
    // can be unit-tested without the main actor.
    nonisolated static func workspaceCreatedPayload(_ workspace: Workspace) -> JSONValue {
        // Mirrors Dispatcher's `encode(ws)` byte-for-byte: JSONEncoder ->
        // JSONSerialization -> JSONValue.from (NOT JSONValue's own Decodable,
        // which structures the object differently and dropped the top-level id).
        // PERF: same encode path as connectionSnapshotJSON — reuse the locked
        // shared encoder instead of allocating per workspace.created publish.
        return connectionSnapshotJSON(workspace)
    }

    nonisolated static func workspaceRenamedPayload(id: WorkspaceID, name: String) -> JSONValue {
        .object([
            "workspace_id": .string(id.value.uuidString),
            "name": .string(name)
        ])
    }

    nonisolated static func workspaceUpdatedPayload(id: WorkspaceID, metadata: [String: JSONValue]) -> JSONValue {
        .object([
            "workspace_id": .string(id.value.uuidString),
            "metadata": .object(metadata)
        ])
    }

    /// iOS applies `workspace.updated` metadata; an empty string removes the key.
    nonisolated static func workspaceBusyMetadata(_ busy: Bool) -> [String: JSONValue] {
        ["busy": .string(busy ? "true" : "")]
    }

    /// Non-persisted per-surface busy event; shape matches `surface.updated` metadata (empty string clears the key on iOS).
    nonisolated static func surfaceBusyPayload(workspace: WorkspaceID, surface: SurfaceID, busy: Bool) -> JSONValue {
        .object([
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surface.value.uuidString),
            "surface_id": .string(surface.value.uuidString),
            "metadata": .object(workspaceBusyMetadata(busy))
        ])
    }

    nonisolated static func workspaceReorderedPayload(id: WorkspaceID, position: Int?, order: [WorkspaceID]) -> JSONValue {
        var payload: [String: JSONValue] = [
            "workspace_id": .string(id.value.uuidString),
            "order": .array(order.map { .string($0.value.uuidString) })
        ]
        if let position {
            payload["position"] = .number(Double(position))
        }
        return .object(payload)
    }

    private func publishWorkspaceCreated(_ workspace: Workspace) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: .workspaceCreated, payload: Self.workspaceCreatedPayload(workspace))
    }

    private func publishWorkspaceRenamed(_ id: WorkspaceID, _ name: String) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: .workspaceRenamed, payload: Self.workspaceRenamedPayload(id: id, name: name))
    }

    private func publishWorkspaceUpdated(_ id: WorkspaceID, metadata: [String: JSONValue]) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: .workspaceUpdated, payload: Self.workspaceUpdatedPayload(id: id, metadata: metadata))
    }

    private func publishWorkspaceReordered(_ id: WorkspaceID, position: Int?) {
        guard shouldPublishLayoutEvents else { return }
        let order = context?.state.window.workspaces ?? []
        EventBus.shared.publish(kind: .workspaceReordered, payload: Self.workspaceReorderedPayload(id: id, position: position, order: order))
    }

    public func setWorkspacePinned(_ id: WorkspaceID, _ pinned: Bool) throws {
        try context?.apply(.setWorkspacePinned(id, pinned))
        windowController?.refreshFromState()
        publishWorkspaceUpdated(id, metadata: ["pinned": pinned ? .string("true") : .string("")])
        publishWorkspaceReordered(id, position: nil)
    }

    public func reorderWorkspace(_ id: WorkspaceID, position: Int) throws {
        try context?.apply(.reorderWorkspace(id, position: position))
        windowController?.refreshFromState()
        publishWorkspaceReordered(id, position: position)
    }

    public func renameSurface(_ wid: WorkspaceID, _ sid: SurfaceID, _ title: String) throws {
        // H3: an explicit rename is newer than any OSC title still pending.
        terminalTitleCoalescer.dropPending(sid)
        try context?.apply(.renameSurface(wid, sid, title))
        windowController?.refreshFromState()
    }

    public func setSurfaceColor(_ wid: WorkspaceID, _ sid: SurfaceID, _ color: String) throws {
        try context?.apply(.setSurfaceColor(wid, sid, color))
        windowController?.refreshFromState()
    }

    private func publishSurfaceCreated(workspace: WorkspaceID, surface: SurfaceDescriptor) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: .surfaceCreated, payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "surface": jsonValue(surface)
        ]))
    }

    private func publishPaneSplit(workspace: WorkspaceID, surface: SurfaceDescriptor) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: .paneSplit, payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "surface": jsonValue(surface)
        ]))
    }

    private func publishSurfaceClosed(workspace: WorkspaceID, surface: SurfaceID) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: .surfaceClosed, payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surface.value.uuidString)
        ]))
    }

    private func publishSurfaceFocused(workspace: WorkspaceID, surface: SurfaceID) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: .surfaceFocused, payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surface.value.uuidString)
        ]))
    }

    private func publishSurfaceMoved(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID? = nil) {
        guard shouldPublishLayoutEvents else { return }
        var payload: [String: JSONValue] = [
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surface.value.uuidString)
        ]
        if let targetPane {
            payload["target_pane_id"] = .string(targetPane.value.uuidString)
        }
        EventBus.shared.publish(kind: .surfaceMoved, payload: .object(payload))
    }

    private func publishSurfaceReordered(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID, position: Int) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: .surfaceReordered, payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surface.value.uuidString),
            "target_pane_id": .string(targetPane.value.uuidString),
            "position": .number(Double(position))
        ]))
    }

    private func publishPaneResized(workspace: WorkspaceID, splitID: UUID) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: .paneResized, payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "split_id": .string(splitID.uuidString)
        ]))
    }

    public func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        // Refuse a pane id that is not in the layout BEFORE building the
        // runtime: `surface.create` / `files.open_tab` take a client-supplied
        // pane id, and a stale one used to no-op inside the reducer while this
        // method still returned a created descriptor (and registered a live
        // surface) for a tab the layout never gained.
        if let paneID, let ws = ctx.state.workspaces[workspace], ws.layout.find(paneID: paneID) == nil {
            throw LayoutError.paneNotFound
        }
        let desc = makeSurface(type: type, title: title, workspace: workspace, cwd: ctx.state.workspaces[workspace]?.cwd ?? "/")
        try ctx.apply(.addSurface(workspace, paneID: paneID, descriptor: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: desc)
        return desc
    }

    /// Opens provider authentication in RemoteCode's integrated Terminal.
    /// Authentication CLIs are interactive; they must not run through a hidden
    /// Process or be reduced to a clipboard instruction.
    @discardableResult
    func openProviderSignInTerminal(
        workspace: WorkspaceID,
        provider: AgentProvider
    ) throws -> SurfaceDescriptor {
        let descriptor = try createSurface(
            workspace: workspace,
            type: .terminal,
            paneID: nil,
            title: "Sign in: \(provider.rawValue.capitalized)"
        )
        try focusSurface(workspace: workspace, surface: descriptor.id)
        let input = Self.providerSignInTerminalInput(for: provider)
        let status: TerminalInputStatus
        if let providerSignInTerminalInputSenderForTests {
            status = providerSignInTerminalInputSenderForTests(descriptor.id, input)
        } else if let terminal = SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface {
            status = terminal.sendTextStatus(input)
        } else {
            status = .surfaceNotFound
        }
        guard status == .accepted else {
            throw JSONRPCError(
                code: -32000,
                message: "Sign-in Terminal rejected input: \(status.rawValue)."
            )
        }
        return descriptor
    }

    static func providerSignInTerminalInput(for provider: AgentProvider) -> String {
        switch provider {
        case .codex:
            return "codex login\n"
        case .claude:
            return "claude auth login\n"
        case .grok:
            return "grok login\n"
        case .distill:
            return "distill login\n"
        }
    }

    public func ensureGitSurface(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        guard let ctx = context,
              let workspaceState = ctx.state.workspaces[workspace] else {
            throw LayoutError.workspaceNotFound
        }
        var existing: SurfaceDescriptor?
        forEachSurface(in: workspaceState.layout) { descriptor in
            guard existing == nil,
                  descriptor.type == .rightSidebarTool,
                  descriptor.metadata["tool"] == "diff" else { return }
            existing = descriptor
        }
        if let existing { return existing }

        let targetPaneID = workspaceState.focusedPaneID ?? workspaceState.layout.paneIDs().first
        let previousSurfaceID = targetPaneID.flatMap {
            workspaceState.layout.find(paneID: $0)?.selectedSurfaceID
        }
        let descriptor = makeSurface(
            type: .rightSidebarTool,
            title: "Git",
            workspace: workspace,
            cwd: workspaceState.cwd
        )
        try ctx.apply(.addSurface(workspace, paneID: targetPaneID, descriptor: descriptor))
        if let previousSurfaceID {
            try ctx.apply(.focusSurface(workspace, previousSurfaceID))
        }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: descriptor)
        return descriptor
    }

    public func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        // Same refusal as createSurface: `surface.split` supplies the pane id, and
        // a stale one must not build a runtime for a pane that is not there.
        if let ws = ctx.state.workspaces[workspace], ws.layout.find(paneID: paneID) == nil {
            throw LayoutError.paneNotFound
        }
        let desc = makeSurface(type: surfaceType, title: title, workspace: workspace, cwd: ctx.state.workspaces[workspace]?.cwd ?? "/")
        try ctx.apply(.splitPane(workspace, paneID: paneID, direction: direction, newSurface: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneSplit(workspace: workspace, surface: desc)
        return desc
    }

    public func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else { throw LayoutError.workspaceNotFound }
        let info = try fileTabInfo(workspace: workspace, path: path)
        let desc = makeFilesSurface(workspace: workspace, cwd: ws.cwd, title: info.title, selectedPath: info.relativePath)
        let targetPane = paneID ?? sourceSurface.flatMap { paneIDContaining(surface: $0, in: ws.layout) }
        try ctx.apply(.addSurface(workspace, paneID: targetPane, descriptor: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: desc)
        return desc
    }

    public func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else { throw LayoutError.workspaceNotFound }
        let info = try fileTabInfo(workspace: workspace, path: path)
        let targetPane = paneID ?? sourceSurface.flatMap { paneIDContaining(surface: $0, in: ws.layout) } ?? ws.focusedPaneID ?? ws.layout.paneIDs().first
        guard let targetPane else { throw LayoutError.paneNotFound }
        let desc = makeFilesSurface(workspace: workspace, cwd: ws.cwd, title: info.title, selectedPath: info.relativePath)
        try ctx.apply(.splitPane(workspace, paneID: targetPane, direction: direction, newSurface: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneSplit(workspace: workspace, surface: desc)
        return desc
    }

    // MARK: Agent App "open in adjacent split" (UX-MAC_AGENT-OPEN-SPLIT)
    // A clicked file mention / link in the Agent App transcript opens in a split
    // panel to the RIGHT of the agent surface. Reuse order: an existing
    // Files/Browser surface in the right-neighbor pane is navigated + focused; a
    // right-neighbor pane without one gets a new tab; no right neighbor creates
    // a right split from the agent's pane.

    public func openFileInAdjacentSplit(workspace: WorkspaceID, sourceSurface: SurfaceID, absolutePath: String) {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace],
              let info = workspaceRelativeTarget(workspace: workspace, path: absolutePath) else {
            // Outside the workspace root the root-scoped Files panel can't show
            // it — hand the (already validated to exist) path to the system.
            NSWorkspace.shared.open(URL(fileURLWithPath: absolutePath))
            return
        }
        let sourcePane = paneIDContaining(surface: sourceSurface, in: ws.layout)
        if let sourcePane, let neighbor = ws.layout.rightNeighborPane(of: sourcePane) {
            if let filesDesc = neighbor.surfaces.first(where: { $0.type == .files }),
               let files = SurfaceRegistry.shared.surface(filesDesc.id) as? FilesSurface {
                files.reveal(relativePath: info.relativePath)
                updateSurfaceDescriptor(workspace: workspace, surface: filesDesc.id) { descriptor in
                    descriptor.title = info.title
                    descriptor.metadata["selected_path"] = info.relativePath
                    descriptor.metadata["selected_relative_path"] = info.relativePath
                }
                try? ctx.apply(.focusSurface(workspace, filesDesc.id))
                windowController?.refreshFromState()
                reconcileSurfaceVisibility()
                return
            }
            let desc = makeFilesSurface(workspace: workspace, cwd: ws.cwd, title: info.title, selectedPath: info.relativePath)
            try? ctx.apply(.addSurface(workspace, paneID: neighbor.id, descriptor: desc))
            windowController?.refreshFromState()
            reconcileSurfaceVisibility()
            publishSurfaceCreated(workspace: workspace, surface: desc)
            return
        }
        guard let targetPane = sourcePane ?? ws.focusedPaneID ?? ws.layout.paneIDs().first else { return }
        let desc = makeFilesSurface(workspace: workspace, cwd: ws.cwd, title: info.title, selectedPath: info.relativePath)
        try? ctx.apply(.splitPane(workspace, paneID: targetPane, direction: .right, newSurface: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneSplit(workspace: workspace, surface: desc)
    }

    public func openURLInAdjacentSplit(workspace: WorkspaceID, sourceSurface: SurfaceID, url: URL) {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else {
            NSWorkspace.shared.open(url)
            return
        }
        let title = url.host ?? "browser"
        let sourcePane = paneIDContaining(surface: sourceSurface, in: ws.layout)
        if let sourcePane, let neighbor = ws.layout.rightNeighborPane(of: sourcePane) {
            if let browserDesc = neighbor.surfaces.first(where: { $0.type == .browser }),
               let browser = SurfaceRegistry.shared.surface(browserDesc.id) as? BrowserSurface {
                browser.navigate(to: url)
                persistBrowserNavigation(surfaceID: browserDesc.id, url: url.absoluteString, title: nil)
                try? ctx.apply(.focusSurface(workspace, browserDesc.id))
                windowController?.refreshFromState()
                reconcileSurfaceVisibility()
                return
            }
            let desc = makeBrowserSurface(workspace: workspace, url: url, title: title)
            try? ctx.apply(.addSurface(workspace, paneID: neighbor.id, descriptor: desc))
            windowController?.refreshFromState()
            reconcileSurfaceVisibility()
            publishSurfaceCreated(workspace: workspace, surface: desc)
            return
        }
        guard let targetPane = sourcePane ?? ws.focusedPaneID ?? ws.layout.paneIDs().first else {
            NSWorkspace.shared.open(url)
            return
        }
        let desc = makeBrowserSurface(workspace: workspace, url: url, title: title)
        try? ctx.apply(.splitPane(workspace, paneID: targetPane, direction: .right, newSurface: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneSplit(workspace: workspace, surface: desc)
    }

    // MARK: Agent App side chat (ephemeral right split)

    /// Opens the ephemeral side chat in a right split pane bound to `threadId`.
    /// Reuses a side-chat agent surface already in the right neighbor; never
    /// repurposes a normal agent tab. Its close calls `closeSideThread`.
    public func openSideChatSplit(workspace: WorkspaceID, sourceSurface: SurfaceID, threadId: AgentThreadID, seed: String?) {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else { return }
        let sourcePane = paneIDContaining(surface: sourceSurface, in: ws.layout)
        if let sourcePane, let neighbor = ws.layout.rightNeighborPane(of: sourcePane),
           let agentDesc = neighbor.surfaces.first(where: { $0.type == .agentApp && $0.metadata["side_thread"] != nil }),
           let agent = SurfaceRegistry.shared.surface(agentDesc.id) as? AgentAppSurface {
            agent.viewModel.selectThread(threadId)
            updateSurfaceDescriptor(workspace: workspace, surface: agentDesc.id) { descriptor in
                descriptor.title = "Side chat"
                descriptor.iconName = "plus.circle"
                descriptor.metadata["selected_thread"] = threadId.value.uuidString
                descriptor.metadata["side_thread"] = threadId.value.uuidString
            }
            try? ctx.apply(.focusSurface(workspace, agentDesc.id))
            windowController?.refreshFromState()
            reconcileSurfaceVisibility()
            registerSideChatClose(surface: agent)
            seedSideSurface(agent, seed: seed)
            return
        }
        var desc = makeSurface(type: .agentApp, title: "Side chat", workspace: workspace, cwd: ws.cwd, sideThreadId: threadId)
        desc.iconName = "plus.circle"
        desc.metadata["side_thread"] = threadId.value.uuidString
        guard let targetPane = sourcePane ?? ws.focusedPaneID ?? ws.layout.paneIDs().first else { return }
        try? ctx.apply(.splitPane(workspace, paneID: targetPane, direction: .right, newSurface: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneSplit(workspace: workspace, surface: desc)
        if let agent = SurfaceRegistry.shared.surface(desc.id) as? AgentAppSurface {
            registerSideChatClose(surface: agent)
            seedSideSurface(agent, seed: seed)
        }
    }

    /// Closing the side chat pane deletes the ephemeral thread (local delete +
    /// provider compensation). Chains onto the surface's existing onClose.
    private func registerSideChatClose(surface: AgentAppSurface) {
        let previous = surface.onClose
        surface.onClose = { [weak self, weak surface] in
            previous?()
            guard let self, let threadId = surface?.viewModel.selectedThreadId else { return }
            Task { @MainActor in
                try? await self.closeSideThread(threadId: threadId)
            }
        }
    }

    private func seedSideSurface(_ agent: AgentAppSurface, seed: String?) {
        guard let seed, !seed.isEmpty else { return }
        agent.viewModel.seedSideChatMessage(seed)
    }

    /// Workspace-relative path + tab title for an absolute target. Files resolve
    /// via `fileTabInfo`; directories (which `read` rejects) via `list`. When the
    /// path is under the workspace but not yet on disk (e.g. planned `./plan`),
    /// still return a relative target so the Files split opens at the parent.
    private func workspaceRelativeTarget(workspace: WorkspaceID, path: String) -> (relativePath: String, title: String)? {
        if let info = try? fileTabInfo(workspace: workspace, path: path) { return info }
        if let cwd = try? workspaceCwd(workspace),
           let listed = try? WorkspaceFileService().list(root: cwd, path: path).objectValue,
           let relativePath = listed["relative_path"]?.stringValue {
            let title = (relativePath as NSString).lastPathComponent
            return (relativePath, title.isEmpty ? "Files" : title)
        }
        guard let cwd = try? workspaceCwd(workspace) else { return nil }
        let root = (cwd as NSString).standardizingPath
        let target = (path as NSString).standardizingPath
        if target == root {
            return ("", "Files")
        }
        guard target.hasPrefix(root + "/") else { return nil }
        let relativePath = String(target.dropFirst(root.count + 1))
        let title = (relativePath as NSString).lastPathComponent
        return (relativePath, title.isEmpty ? "Files" : title)
    }

    /// Layout-descriptor mutation (title/metadata) for an existing surface,
    /// mirroring persistBrowserNavigation's persistence path.
    private func updateSurfaceDescriptor(workspace: WorkspaceID, surface: SurfaceID, _ mutate: (inout SurfaceDescriptor) -> Void) {
        guard let ctx = context, var ws = ctx.state.workspaces[workspace] else { return }
        let result = updateSurface(in: ws.layout, surfaceID: surface, mutate)
        guard result.changed else { return }
        ws.layout = result.node
        ws.updatedAt = Date()
        ctx.state.workspaces[workspace] = ws
        ctx.scheduleSnapshotSave()
    }

    private func makeBrowserSurface(workspace: WorkspaceID, url: URL, title: String) -> SurfaceDescriptor {
        let browser = configureBrowserSurface(BrowserSurface(workspaceID: workspace, initialURL: url, title: title), workspace: workspace)
        SurfaceRegistry.shared.register(browser)
        var desc = browser.descriptor
        // Persist the target up front so an app restart before the first
        // navigation callback still restores this tab to its URL.
        desc.metadata["url"] = url.absoluteString
        return desc
    }

    public func splitSurface(workspace: WorkspaceID, paneID: PaneID, surface: SurfaceID, direction: SplitDirection) throws {
        try context?.apply(.splitSurface(workspace, paneID: paneID, surface: surface, direction: direction))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceMoved(workspace: workspace, surface: surface, targetPane: paneID)
    }

    public func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws {
        // Capture the descriptor before removing it from the layout so
        // reopenClosedSurface can re-create the tab with cwd restored.
        let closedDescriptor = (try? locateSurface(surface))?.descriptor
            ?? SurfaceRegistry.shared.surface(surface)?.descriptor
        let workspaceCwdForReopen = context?.state.workspaces[workspace]?.cwd ?? ""
        try context?.apply(.closeSurface(workspace, surface))
        permanentlyCloseRuntimeSurface(surface)
        if let desc = closedDescriptor {
            let entry = ClosedTabEntry(descriptor: desc, workspaceCwd: workspaceCwdForReopen)
            closedTabBuffer.push(entry, for: workspace)
        }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceClosed(workspace: workspace, surface: surface)
    }

    /// Close multiple surfaces in one batch, applying a single refreshFromState
    /// and reconcileSurfaceVisibility after all mutations instead of one per surface.
    /// Per-surface side effects (registry unregister, output-bus remove, closed-tab
    /// buffer push, event publish) are still performed individually, in order.
    public func closeSurfaces(workspace: WorkspaceID, surfaces: [SurfaceID]) throws {
        guard !surfaces.isEmpty else { return }
        let workspaceCwd = context?.state.workspaces[workspace]?.cwd ?? ""
        for surface in surfaces {
            let closedDescriptor = (try? locateSurface(surface))?.descriptor
                ?? SurfaceRegistry.shared.surface(surface)?.descriptor
            try context?.apply(.closeSurface(workspace, surface))
            permanentlyCloseRuntimeSurface(surface)
            if let desc = closedDescriptor {
                let entry = ClosedTabEntry(descriptor: desc, workspaceCwd: workspaceCwd)
                closedTabBuffer.push(entry, for: workspace)
            }
            publishSurfaceClosed(workspace: workspace, surface: surface)
        }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
    }

    /// Permanently disposes one layout surface. Terminal history deletion is
    /// serialized by its coordinator after any already-queued writer; all other
    /// surfaces have no terminal writer and can delete directly.
    private func permanentlyCloseRuntimeSurface(_ surfaceID: SurfaceID) {
        if let terminal = SurfaceRegistry.shared.surface(surfaceID) as? TerminalSurface {
            terminal.closeAndDeletePersistedHistory()
        } else if let ssh = SurfaceRegistry.shared.surface(surfaceID) as? SSHSurface {
            ssh.closeAndDeletePersistedHistory()
        } else {
            SurfaceRegistry.shared.surface(surfaceID)?.close()
            try? context?.terminalOutputRepo.delete(surfaceID: surfaceID.value.uuidString)
        }
        // Drop process-only retention protection once the surface is gone.
        context?.threadRepo.setLiveSurfaceBinding(surfaceID: surfaceID, threadID: nil)
        SurfaceRegistry.shared.unregister(surfaceID)
        SurfaceOutputBus.shared.remove(surfaceId: surfaceID)
    }

    /// Reopen the most-recently-closed tab in `workspace`, restoring its cwd.
    /// Returns the new descriptor, or nil when the closed-tab buffer is empty.
    @discardableResult
    public func reopenClosedSurface(workspace: WorkspaceID) throws -> SurfaceDescriptor? {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let entry = closedTabBuffer.pop(for: workspace) else { return nil }
        let cwd = entry.workspaceCwd.isEmpty
            ? (ctx.state.workspaces[workspace]?.cwd ?? "/")
            : entry.workspaceCwd
        // Restore the agent tab's bound thread so reopen-closed-tab returns to
        // the same conversation rather than a fresh composer.
        let reopenThreadId: AgentThreadID? = entry.descriptor.type == .agentApp
            ? entry.descriptor.metadata["selected_thread"].flatMap(UUID.init).map(AgentThreadID.init)
            : nil
        let desc = makeSurface(type: entry.descriptor.type, title: entry.descriptor.title,
                               workspace: workspace, cwd: cwd, initialThreadId: reopenThreadId,
                               restoringFrom: entry.descriptor)
        try ctx.apply(.addSurface(workspace, paneID: nil, descriptor: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: desc)
        return desc
    }

    /// Replaces a dead terminal surface with a fresh shell in the same pane
    /// and the same working directory. No-ops if the surface is not a
    /// restartable local terminal (SSH, wrong type, cwd missing).
    public func restartSurface(_ surfaceID: SurfaceID) {
        guard restartingSurfaceIDs.insert(surfaceID).inserted else { return }
        Task { @MainActor [weak self] in
            _ = await self?.performCoalescedTerminalRestart(surfaceID)
        }
    }

    @discardableResult
    func restartSurfaceAndWaitForTesting(_ surfaceID: SurfaceID) async -> Bool {
        guard restartingSurfaceIDs.insert(surfaceID).inserted else { return false }
        return await performCoalescedTerminalRestart(surfaceID)
    }

    private func performCoalescedTerminalRestart(_ surfaceID: SurfaceID) async -> Bool {
        defer { restartingSurfaceIDs.remove(surfaceID) }
        guard let ctx = context,
              let located = try? locateSurface(surfaceID),
              let (cwd, _) = TerminalRestartDecision.spawnRequest(from: located.descriptor),
              let oldRuntime = SurfaceRegistry.shared.surface(surfaceID) as? TerminalSurface else {
            return false
        }

        let workspaceID = located.workspaceID
        let preservedDescriptor = located.descriptor
        SurfaceOutputBus.shared.flushNow(surfaceID)
        let sequenceBeforeRestart = SurfaceOutputBus.shared.currentSequence(surfaceID)
        let historyPreflight = oldRuntime.runtimeRestartHistoryPreflightBarrier()
        let historyReady = await historyPreflight.waitAsync(until: .now() + 2)
        guard historyReady else {
            appRouterLog.error("terminal.restart.blocked surface=\(surfaceID.value.uuidString, privacy: .public) reason=history_preflight_timeout")
            return false
        }

        // The preflight is intentionally non-destructive. Revalidate after its
        // async wait before crossing the irreversible PTY teardown boundary.
        guard SurfaceRegistry.shared.surface(surfaceID) === oldRuntime,
              let preflightCurrent = try? locateSurface(surfaceID),
              preflightCurrent.workspaceID == workspaceID,
              preflightCurrent.descriptor == preservedDescriptor else {
            return false
        }
        func prepareRuntime(
            workspaceID: WorkspaceID,
            cwd: String
        ) -> TerminalPreparedPTYRuntime? {
            if let terminalRestartRuntimePreparerForTesting {
                return terminalRestartRuntimePreparerForTesting(
                    workspaceID,
                    cwd,
                    surfaceID
                )
            }
            return TerminalSurface.prepareShellRuntimeForRestart(
                workspaceID: workspaceID,
                cwd: cwd,
                surfaceID: surfaceID
            )
        }

        func discardPreparedRuntime(_ prepared: TerminalPreparedPTYRuntime?) async {
            guard let prepared else { return }
            var barriers: [SurfaceTerminationBarrier] = []
            if let cleanup = prepared.discard() {
                barriers.append(cleanup)
            }
            if let additional = terminalRestartPreparedDiscardAdditionalBarrierForTesting?() {
                barriers.append(additional)
            }
            guard !barriers.isEmpty else { return }
            let combined = SurfaceTerminationBarrier(combining: barriers)
            _ = await combined.waitForGroupsAsync(until: .distantFuture)
        }

        var preparedRuntime = prepareRuntime(workspaceID: workspaceID, cwd: cwd)
        guard let initialPreparedRuntime = preparedRuntime else {
            appRouterLog.error("terminal.restart.blocked surface=\(surfaceID.value.uuidString, privacy: .public) reason=spawn_prepare_failed")
            return false
        }
        guard initialPreparedRuntime.suspendIfOwnedAndAlive() else {
            appRouterLog.error("terminal.restart.blocked surface=\(surfaceID.value.uuidString, privacy: .public) reason=prepared_child_not_alive")
            return false
        }
        guard SurfaceRegistry.shared.surface(surfaceID) === oldRuntime,
              let preparedCurrent = try? locateSurface(surfaceID),
              preparedCurrent.workspaceID == workspaceID,
              preparedCurrent.descriptor == preservedDescriptor else {
            return false
        }
        let barrier = oldRuntime.closeForRuntimeRestart()
        var historyCompleted = true
        if let requiredHistory = oldRuntime.requiredHistoryBarrierForRuntimeRestart() {
            // Finalizing disables writes immediately and owns a bounded internal
            // retry. Wait for the group itself, not the caller's fast process
            // deadline: only group completion proves the old writer has stopped
            // and a replacement writer may safely take the same surface ID.
            let historyGroupsCompleted = await requiredHistory.waitForGroupsAsync(
                until: .distantFuture
            )
            historyCompleted = historyGroupsCompleted
                && requiredHistory.completionChecksSucceeded()
            if !historyCompleted {
                appRouterLog.error("terminal.restart.history_incomplete surface=\(surfaceID.value.uuidString, privacy: .public) action=replacement_continues_partial")
            }
        }
        let dispositionDeadline = DispatchTime.now() + 2
        var dispositionCompleted = true
        if let barrier {
            let dispositionGroupsCompleted = await barrier.waitForGroupsAsync(
                until: dispositionDeadline
            )
            dispositionCompleted = dispositionGroupsCompleted
                && barrier.completionChecksSucceeded()
            if !dispositionCompleted {
                let reason = dispositionGroupsCompleted
                    ? "disposition_check_failed"
                    : "disposition_group_timeout"
                appRouterLog.error("terminal.restart.cleanup_incomplete surface=\(surfaceID.value.uuidString, privacy: .public) reason=\(reason, privacy: .public) action=replacement_continues")
                oldRuntime.continueCleanupAfterFailedRuntimeRestart()
            }
        }

        let terminalFontSize = SettingsStore(db: ctx.db).load().terminalFontSize
        var preparedWorkspaceID = workspaceID
        var preparedCwd = cwd
        var recoveryAttempt = 0
        let maximumRecoveryAttempts = 5

        while true {
            // Actor reentrancy is intentional while history/process owners drain.
            // A close or a newer runtime wins; title/layout updates are adopted.
            guard SurfaceRegistry.shared.surface(surfaceID) === oldRuntime else {
                await discardPreparedRuntime(preparedRuntime)
                oldRuntime.relinquishRuntimeHealthOwnershipForReplacement()
                return false
            }
            guard let current = try? locateSurface(surfaceID),
                  let (currentCwd, _) = TerminalRestartDecision.spawnRequest(
                    from: current.descriptor
                  ) else {
                await discardPreparedRuntime(preparedRuntime)
                oldRuntime.relinquishRuntimeHealthOwnershipForReplacement()
                if SurfaceRegistry.shared.surface(surfaceID) === oldRuntime {
                    SurfaceRegistry.shared.unregister(surfaceID)
                }
                return false
            }

            if let ownedPreparedRuntime = preparedRuntime {
                let preparedMatchesCurrentState = preparedWorkspaceID == current.workspaceID
                    && preparedCwd == currentCwd
                guard preparedMatchesCurrentState,
                      ownedPreparedRuntime.isOwnedAndAlive() else {
                    await discardPreparedRuntime(ownedPreparedRuntime)
                    preparedRuntime = nil
                    // The await permits close/move/rename. Never use `current`
                    // again until registry and layout are re-read at loop top.
                    continue
                }
            } else if recoveryAttempt < maximumRecoveryAttempts {
                preparedRuntime = prepareRuntime(
                    workspaceID: current.workspaceID,
                    cwd: currentCwd
                )
                preparedWorkspaceID = current.workspaceID
                preparedCwd = currentCwd
                if let candidateRuntime = preparedRuntime,
                   !candidateRuntime.suspendIfOwnedAndAlive() {
                    await discardPreparedRuntime(candidateRuntime)
                    preparedRuntime = nil
                    recoveryAttempt += 1
                    continue
                }
            }

            let candidateRuntime: TerminalPreparedPTYRuntime?
            if let preparedRuntime {
                candidateRuntime = preparedRuntime
            } else {
                if recoveryAttempt < maximumRecoveryAttempts {
                    recoveryAttempt += 1
                }
                if recoveryAttempt == 1 || recoveryAttempt == maximumRecoveryAttempts {
                    appRouterLog.error("terminal.restart.recovery_wait surface=\(surfaceID.value.uuidString, privacy: .public) attempt=\(recoveryAttempt, privacy: .public) reason=spawn_prepare_failed")
                }
                guard recoveryAttempt >= maximumRecoveryAttempts else {
                    let delay = min(1.0, 0.05 * Double(recoveryAttempt))
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        // Cancellation must accelerate the finite fallback, not
                        // turn every subsequent sleep into a zero-delay spin.
                        recoveryAttempt = maximumRecoveryAttempts
                    }
                    continue
                }
                // The preparer can fail under transient descriptor/process
                // pressure. One final direct spawn produces either a healthy
                // successor or an explicit dead-but-retryable surface; it never
                // leaves an unbounded recovery Task resident.
                candidateRuntime = nil
            }

            do {
                let candidate = configureTerminalSurface(
                    try TerminalSurface(
                        workspaceID: current.workspaceID,
                        title: current.descriptor.title,
                        launch: .shell(cwd: currentCwd),
                        restoredSurfaceID: surfaceID,
                        historyRepo: ctx.terminalOutputRepo,
                        settingsRepo: ctx.settingsRepo,
                        terminalFontSize: terminalFontSize,
                        outputBus: .shared,
                        preservedDescriptor: current.descriptor,
                        preparedRuntime: candidateRuntime
                    ),
                    workspace: current.workspaceID
                )
                preparedRuntime = nil
                guard candidate.runtimeHealth().processAlive,
                      candidate.runtimeHealth().inputAccepting,
                      candidate.runtimeProcessIsOwnedAndAliveForRestartCommit() else {
                    appRouterLog.error("terminal.restart.recovery_wait surface=\(surfaceID.value.uuidString, privacy: .public) attempt=\(recoveryAttempt + 1, privacy: .public) reason=replacement_not_alive")
                    recoveryAttempt += 1
                    if recoveryAttempt >= maximumRecoveryAttempts {
                        oldRuntime.relinquishRuntimeHealthOwnershipForReplacement()
                        if !dispositionCompleted {
                            candidate.markRuntimeRestartDispositionIncomplete()
                        }
                        if !historyCompleted {
                            candidate.markRuntimeRestartHistoryIncomplete()
                        }
                        candidate.markRuntimeRestartRecoveryExhausted()
                        SurfaceRegistry.shared.register(candidate)
                        windowController?.refreshFromState()
                        reconcileSurfaceVisibility()
                        return false
                    }
                    let cleanup = candidate.closeForRuntimeRestart()
                    if let requiredHistory = candidate.requiredHistoryBarrierForRuntimeRestart() {
                        _ = await requiredHistory.waitForGroupsAsync(until: .distantFuture)
                    }
                    if let cleanup {
                        let groupsCompleted = await cleanup.waitForGroupsAsync(
                            until: .now() + 2
                        )
                        if !groupsCompleted || !cleanup.completionChecksSucceeded(),
                           let fallback = candidate.continueCleanupAfterFailedRuntimeRestart() {
                            _ = await fallback.waitForGroupsAsync(until: .distantFuture)
                        }
                    }
                    candidate.relinquishRuntimeHealthOwnershipForReplacement()
                    let delay = min(1.0, 0.05 * Double(recoveryAttempt))
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        recoveryAttempt = maximumRecoveryAttempts
                    }
                    continue
                }

                oldRuntime.relinquishRuntimeHealthOwnershipForReplacement()
                if !dispositionCompleted {
                    candidate.markRuntimeRestartDispositionIncomplete()
                }
                if !historyCompleted {
                    candidate.markRuntimeRestartHistoryIncomplete()
                }
                SurfaceRegistry.shared.register(candidate)
                windowController?.refreshFromState()
                reconcileSurfaceVisibility()
                let sequenceAfterRestart = SurfaceOutputBus.shared.currentSequence(surfaceID)
                guard sequenceAfterRestart >= sequenceBeforeRestart else {
                    appRouterLog.error("terminal.restart.sequence_regressed surface=\(surfaceID.value.uuidString, privacy: .public) before=\(sequenceBeforeRestart, privacy: .public) after=\(sequenceAfterRestart, privacy: .public)")
                    return false
                }
                return true
            } catch {
                // The current TerminalSurface initializer is effectively
                // nonthrowing, but retain ownership if that contract changes.
                await discardPreparedRuntime(preparedRuntime)
                preparedRuntime = nil
                recoveryAttempt += 1
                appRouterLog.error("terminal.restart.recovery_wait surface=\(surfaceID.value.uuidString, privacy: .public) attempt=\(recoveryAttempt, privacy: .public) error=\(String(describing: error), privacy: .public)")
                if recoveryAttempt >= maximumRecoveryAttempts {
                    oldRuntime.relinquishRuntimeHealthOwnershipForReplacement()
                    if SurfaceRegistry.shared.surface(surfaceID) === oldRuntime {
                        SurfaceRegistry.shared.unregister(surfaceID)
                    }
                    return false
                }
                let delay = min(1.0, 0.05 * Double(recoveryAttempt))
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    recoveryAttempt = maximumRecoveryAttempts
                }
            }
        }
    }

    public func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws {
        PerfSwitchMetrics.beginTabSwitch(surfaceID: surface.value.uuidString)
        if let ws = context?.state.workspaces[workspace],
           let paneID = ws.layout.paneIDs().first(where: { paneID in
               ws.layout.find(paneID: paneID)?.surfaces.contains(where: { $0.id == surface }) == true
           }),
           ws.focusedPaneID == paneID,
           ws.layout.find(paneID: paneID)?.selectedSurfaceID == surface {
            // Already the focused surface in the focused pane -- no state mutation needed.
            windowController?.focusSurface(surface)
            publishSurfaceFocused(workspace: workspace, surface: surface)
            PerfSwitchMetrics.endTabSwitchInstall()
            CATransaction.setCompletionBlock {
                PerfSwitchMetrics.endTabSwitchCommitted()
            }
            return
        }
        try context?.apply(.focusSurface(workspace, surface))
        // PERF-MAC_SHELL_WINDOW-125: focus/tab selection changes only the
        // selected-surface and focused-pane fields -- the structural signature
        // (pane id set, surface id set, order) is unchanged. Use the in-place
        // fast path instead of a full teardown/rebuild.
        reconcileSurfaceVisibility()
        windowController?.applyFocusChangeInPlace(surfaceToFocus: surface)
        publishSurfaceFocused(workspace: workspace, surface: surface)
    }

    /// Focus-follows-click: route a pane-content mouseDown to make the clicked
    /// pane the focused one so Cmd+W/Cmd+D act on the pane the user is typing in.
    public func focusPane(workspace: WorkspaceID, pane: PaneID) throws {
        try context?.apply(.focusPane(workspace, pane))
        // PERF-MAC_SHELL_WINDOW-125: pane focus changes only focusedPaneID --
        // structural signature unchanged. Reconcile in place (no rebuild).
        reconcileSurfaceVisibility()
        windowController?.applyFocusChangeInPlace(surfaceToFocus: nil)
    }

    public func repairSelectedTerminalFocus(reason: String) {
        guard context != nil else { return }
        let workspaceIDs = visibleWorkspaceIDs()
        for workspaceID in workspaceIDs {
            repairSelectedTerminalFocus(workspace: workspaceID, reason: reason)
        }
    }

    public func repairSelectedTerminalFocus(workspace workspaceID: WorkspaceID, reason: String) {
        guard let ws = context?.state.workspaces[workspaceID],
              let surfaceID = focusedSelectedSurfaceID(in: ws),
              SurfaceRegistry.shared.isVisible(surfaceID),
              let terminal = SurfaceRegistry.shared.surface(surfaceID) as? TerminalRuntimeRoutingSurface else { return }
        terminal.routedRepairTerminalFocus(reason: reason)
    }

    public func sendText(surface: SurfaceID, text: String) throws {
        guard let s = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        s.sendText(text)
    }

    public func sendTextResult(surface: SurfaceID, text: String) throws -> JSONValue {
        guard let s = SurfaceRegistry.shared.surface(surface) else {
            return terminalInputStatusJSON(.surfaceNotFound)
        }
        if let terminal = s as? TerminalRuntimeRoutingSurface {
            return terminalInputStatusJSON(terminal.routedSendTextStatus(text))
        }
        s.sendText(text)
        return terminalInputStatusJSON(.accepted)
    }

    public func readText(surface: SurfaceID) throws -> String {
        guard let s = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        return s.readText()
    }

    public func readTextSnapshot(surface: SurfaceID) throws -> JSONValue {
        guard let s = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        if let terminal = s as? TerminalRuntimeRoutingSurface {
            guard let snapshot = terminal.routedTextSnapshot() else {
                return disconnectedTerminalSnapshotJSON()
            }
            return terminalSnapshotJSON(snapshot)
        }
        return .object([
            "text": .string(s.readText()),
            "complete": .bool(true),
            "partial": .bool(false),
            "source": .string("surface_read_text"),
            "timestamp": .number(Date().timeIntervalSince1970),
            "pending_bytes": .number(0)
        ])
    }

    public func readTerminalHistory(
        surface: SurfaceID,
        beforeChunkID: Int64?,
        maxBytes: Int
    ) async throws -> TerminalOutputWindow {
        guard let surfaceObject = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        guard let terminal = surfaceObject as? TerminalRuntimeRoutingSurface else {
            throw LayoutError.surfaceNotFound
        }
        return try await terminal.routedReadPersistedHistory(
            beforeChunkID: beforeChunkID,
            maxBytes: maxBytes,
            timeout: 2
        )
    }

    public func surfaceHealth(surface: SurfaceID) -> Bool {
        SurfaceRegistry.shared.surface(surface) != nil
    }

    public func surfaceHealthDetails(surface: SurfaceID) -> JSONValue {
        guard let s = SurfaceRegistry.shared.surface(surface) else {
            return .object([
                "alive": .bool(false),
                "process_alive": .bool(false),
                "pty_open": .bool(false),
                "input_accepting": .bool(false),
                "terminal_dead_reason": .string(TerminalInputStatus.surfaceNotFound.rawValue)
            ])
        }
        guard let terminal = s as? TerminalRuntimeRoutingSurface else {
            return .object([
                "alive": .bool(true),
                "surface_type": .string(s.descriptor.type.rawValue)
            ])
        }
        guard let health = terminal.routedRuntimeHealth() else {
            return disconnectedTerminalHealthJSON()
        }
        return terminalHealthJSON(health)
    }

    public func surfaceClearHistory(surface: SurfaceID) {
        // Terminal-specific: discard pending + durable scrollback through the
        // history coordinator so an in-flight writer cannot repopulate after
        // delete, then clear the live viewport. Browser/agent surfaces ignore.
        if let s = SurfaceRegistry.shared.surface(surface), s.descriptor.type == .terminal || s.descriptor.type == .ssh {
            if let terminal = s as? TerminalRuntimeRoutingSurface {
                terminal.routedClearPersistedHistory()
            } else {
                try? context?.terminalOutputRepo.delete(surfaceID: surface.value.uuidString)
            }
            s.sendText("\u{0C}") // ctrl-L
        }
    }

    public func sshHostList(workspace: WorkspaceID) throws -> [SSHHostProfile] {
        guard let ctx = context else { return [] }
        try requireWorkspace(workspace, in: ctx)
        return try readSSHHosts(workspace: workspace, from: ctx.settingsRepo)
    }

    public func sshHostUpsert(_ profile: SSHHostProfile, workspace: WorkspaceID) throws -> SSHHostProfile {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try requireWorkspace(workspace, in: ctx)
        var hosts = try readSSHHosts(workspace: workspace, from: ctx.settingsRepo)
        var saved = profile
        saved.updatedAt = Date()
        if let index = hosts.firstIndex(where: { $0.id == saved.id }) {
            saved.createdAt = hosts[index].createdAt
            if saved.password?.isEmpty == false {
                saved.hasSavedPassword = true
            } else {
                saved.password = nil
                saved.hasSavedPassword = hosts[index].hasSavedPassword
            }
            hosts[index] = saved
        } else {
            saved.hasSavedPassword = saved.password?.isEmpty == false
            hosts.append(saved)
        }
        try writeSSHHosts(hosts, workspace: workspace, to: ctx.settingsRepo)
        return saved
    }

    func sshHostForConnection(_ profile: SSHHostProfile, workspace: WorkspaceID) throws -> SSHHostProfile {
        let saved = try sshHostUpsert(profile, workspace: workspace)
        return sshHostWithPasswordForConnection(saved)
    }

    public func sshHostDelete(_ id: SSHHostID, workspace: WorkspaceID) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try requireWorkspace(workspace, in: ctx)
        var hosts = try readSSHHosts(workspace: workspace, from: ctx.settingsRepo)
        hosts.removeAll { $0.id == id }
        sshPasswordStore.delete(account: id.value.uuidString)
        try writeSSHHosts(hosts, workspace: workspace, to: ctx.settingsRepo)
    }

    public func sshConnect(workspace: WorkspaceID, profileID: SSHHostID?, profile: SSHHostProfile?, title: String?, paneID: PaneID?) throws -> SurfaceDescriptor {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try requireWorkspace(workspace, in: ctx)
        let hosts = try readSSHHosts(workspace: workspace, from: ctx.settingsRepo)
        let resolved: SSHHostProfile
        if let profileID, let found = hosts.first(where: { $0.id == profileID }) {
            resolved = sshHostWithPasswordForConnection(found)
        } else if let profile {
            resolved = try sshHostForConnection(profile, workspace: workspace)
        } else {
            throw LayoutError.surfaceNotFound
        }
        let desc = try makeSSHSurface(profile: resolved, title: title, workspace: workspace, cwd: ctx.state.workspaces[workspace]?.cwd ?? "/")
        try ctx.apply(.addSurface(workspace, paneID: paneID, descriptor: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: desc)
        if shouldPublishLayoutEvents {
            EventBus.shared.publish(kind: .sshSessionUpdated, payload: .object([
                "surface_id": .string(desc.id.value.uuidString),
                "status": .string(desc.metadata["ssh_status"] ?? "connected"),
                "destination": .string(desc.metadata["ssh_destination"] ?? "")
            ]))
        }
        return desc
    }

    public func sshDisconnect(surface: SurfaceID) throws {
        guard let ssh = SurfaceRegistry.shared.surface(surface) as? SSHSurface else {
            throw LayoutError.surfaceNotFound
        }
        ssh.disconnectForRouter()
    }

    public func sshTransferUpload(surface: SurfaceID, localPath: String, remotePath: String) throws -> JSONValue {
        try runSSHTransfer(surface: surface, upload: true, localPath: localPath, remotePath: remotePath)
    }

    public func sshTransferDownload(surface: SurfaceID, remotePath: String, localPath: String) throws -> JSONValue {
        try runSSHTransfer(surface: surface, upload: false, localPath: localPath, remotePath: remotePath)
    }

    public func sshFilesLocalList(path: String?) throws -> JSONValue {
        try makeLocalSSHFileListing(path: path)
    }

    public func sshFilesRemoteList(surface: SurfaceID, path: String?) throws -> JSONValue {
        let profile = try sshTransferProfile(for: surface)
        let requested = (path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? path! : "."
        let script = """
        p=\(shellQuote(requested))
        [ -z "$p" ] && p=.
        cd "$p" 2>/dev/null || exit 2
        pwd
        for f in .. .* *; do
          [ "$f" = "." ] && continue
          [ -e "$f" ] || continue
          if [ -d "$f" ]; then
            kind=directory
            type="File folder"
            size=""
          else
            kind=file
            ext="${f##*.}"
            [ "$ext" = "$f" ] && type="File" || type="$ext file"
            size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          fi
          mod=$(date -r "$f" "+%Y-%m-%d %H:%M" 2>/dev/null || stat -c %y "$f" 2>/dev/null | cut -c1-16)
          printf '%s\t%s\t%s\t%s\n' "$f" "$kind" "$size" "$mod"
        done
        """
        let args = SSHCommandBuilder.sshArguments(for: profile) + ["sh", "-lc", script]
        let result = try runCommand(executable: "/usr/bin/ssh", arguments: args, password: profile.password)
        guard result.exitCode == 0 else {
            throw JSONRPCError(code: -32020, message: "remote list failed", data: .string(result.output))
        }
        return makeRemoteSSHFileListing(output: result.output, requestedPath: requested)
    }

    public func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        try createSurface(workspace: workspace, type: .agentApp, paneID: nil, title: "Agent App")
    }

    /// Legacy helper: open + focus an Agent App tab for a workspace.
    ///
    /// Scheduled fires no longer call this — they run headless via
    /// `createAgentThread` + `sendAgentMessage` so automatic work does not
    /// activate the app, switch workspaces, or steal the composer.
    /// Kept for manual deep-link / debug callers that intentionally want focus.
    @MainActor
    public func openAgentAppForSchedule(workspace: WorkspaceID) throws -> AgentAppSurface {
        guard context?.state.workspaces[workspace] != nil else {
            throw LayoutError.workspaceNotFound
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let detachedWindow = windowController?.workspaceWindow(for: workspace) {
            detachedWindow.makeKeyAndOrderFront(nil)
        } else {
            windowController?.show()
            try selectWorkspace(workspace)
            windowController?.presentWorkspaceContent()
            windowController?.flushPendingRefresh()
        }
        let descriptor = try openAgentApp(workspace: workspace)
        try focusSurface(workspace: workspace, surface: descriptor.id)
        windowController?.flushPendingRefresh()
        guard let surface = SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface else {
            throw LayoutError.surfaceNotFound
        }
        return surface
    }

    /// In-process schedule owner (main app). Run Now / ticks call this instead of XPC.
    public weak var scheduledTaskScheduler: ScheduledTaskScheduler?

    /// Fork, side and plan-implementation branch a pinned thread into another thread, which the pin does not authorize.
    private static func refuseContextPinnedGenericExecution(_ threadID: AgentThreadID, context ctx: AppContext) throws {
        guard let pin = try ctx.botStore.conversationContextPin(linkedTo: threadID) else { return }
        let authorized: Bool
        if let conversation = try ctx.botStore.conversation(id: pin.conversationID) {
            authorized = try ctx.botStore.authorizesConversation(conversation, hostID: ctx.liveActivityHostIdentity.serverId, action: .send)
        } else {
            authorized = false
        }
        throw JSONRPCError(code: -32602, message: authorized
                           ? "Contextual conversations cannot be forked or continued in another thread."
                           : "Contextual send authority is inactive or invalid.")
    }

    /// A pinned thread sends like any bot thread; only a revoked or foreign pin refuses.
    private static func requireContextPinnedSendAuthority(_ threadID: AgentThreadID, context ctx: AppContext) throws {
        guard let pin = try ctx.botStore.conversationContextPin(linkedTo: threadID) else { return }
        guard let conversation = try ctx.botStore.conversation(id: pin.conversationID),
              try ctx.botStore.authorizesConversation(conversation, hostID: ctx.liveActivityHostIdentity.serverId, action: .send) else {
            throw JSONRPCError(code: -32602, message: "Contextual send authority is inactive or invalid.")
        }
    }

    /// Resolve authorization for a context-pinned thread without applying legacy routing.
    static func contextPinnedThreadDestination(
        _ threadID: AgentThreadID,
        context ctx: AppContext
    ) throws -> AgentThreadOpenDestination? {
        guard let pin = try ctx.botStore.conversationContextPin(linkedTo: threadID) else { return nil }
        guard pin.hostID == ctx.liveActivityHostIdentity.serverId,
              let conversation = try ctx.botStore.conversation(id: pin.conversationID),
              conversation.linkedAgentThreadID == threadID,
              conversation.botID == pin.botID,
              let thread = try ctx.threadRepo.get(id: threadID),
              thread.actor == .bot(pin.botID),
              ((pin.context == .general && thread.workspaceId == nil)
               || (thread.workspaceId.map { pin.context == .workspace($0) } ?? false)),
              try ctx.botStore.authorizes(
                hostID: pin.hostID,
                botID: pin.botID,
                context: pin.context,
                action: .read,
                policyRevision: pin.policyRevision
              ) else {
            return .unavailable
        }
        return .bot(conversation.botID, conversation.id)
    }

    /// Where `openAgentThread` could land, checked before a caller leaves its own screen.
    public func agentThreadOpenDestination(_ threadID: AgentThreadID) throws -> AgentThreadOpenDestination {
        guard let ctx = context else { return .unavailable }
        if let pinned = try Self.contextPinnedThreadDestination(threadID, context: ctx) { return pinned }
        if let workspaceID = try ctx.threadRepo.workspaceId(of: threadID),
           ctx.state.workspaces[workspaceID] != nil {
            return .workspace(workspaceID)
        }
        if let conversation = try ctx.botStore.conversationLinked(to: threadID) {
            return .bot(conversation.botID, conversation.id)
        }
        return .unavailable
    }

    /// "+ New conversation" in the sidebar: the same Agent App `createThread` the command
    /// palette's "Agent: New Thread" runs, on this workspace's Agent App surface.
    @discardableResult
    public func createWorkspaceConversation(workspace workspaceID: WorkspaceID) throws -> AgentThreadID {
        guard let ctx = context, ctx.state.workspaces[workspaceID] != nil else {
            throw LayoutError.workspaceNotFound
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let detachedWindow = windowController?.workspaceWindow(for: workspaceID) {
            detachedWindow.makeKeyAndOrderFront(nil)
        } else {
            windowController?.show()
            try selectWorkspace(workspaceID)
            windowController?.presentWorkspaceContent()
            windowController?.flushPendingRefresh()
        }
        let surface: AgentAppSurface
        if let existing = preferredAgentAppSurface(in: workspaceID) {
            surface = existing
        } else {
            let descriptor = try openAgentApp(workspace: workspaceID)
            guard let created = SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface else {
                throw LayoutError.surfaceNotFound
            }
            surface = created
        }
        try focusSurface(workspace: workspaceID, surface: surface.descriptor.id)
        let previous = surface.viewModel.selectedThreadId
        surface.viewModel.createThread(title: "New thread")
        windowController?.flushPendingRefresh()
        guard let created = surface.viewModel.selectedThreadId, created != previous else {
            throw LayoutError.surfaceNotFound
        }
        return created
    }

    /// Open one exact agent thread in a concrete Agent App surface.
    ///
    /// This is the canonical deep-link path for system notifications and other
    /// attention surfaces. It deliberately keeps `selectAgentThread`'s nil-target
    /// behavior unchanged: remote mark-read/list refreshes must not yank an
    /// arbitrary macOS tab. A user-initiated open instead resolves one surface,
    /// focuses it, binds the thread to that surface ID, verifies the binding, and
    /// only then clears unread state when requested.
    @discardableResult
    public func openAgentThread(thread threadID: AgentThreadID, markRead: Bool = false) throws -> SurfaceDescriptor {
        guard let ctx = context,
              let workspaceID = try ctx.threadRepo.workspaceId(of: threadID),
              ctx.state.workspaces[workspaceID] != nil else {
            throw LayoutError.workspaceNotFound
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let destinationWindow: NSWindow?
        if let detachedWindow = windowController?.workspaceWindow(for: workspaceID) {
            detachedWindow.makeKeyAndOrderFront(nil)
            destinationWindow = detachedWindow
        } else {
            // Exact-route navigation must leave shell destinations (Schedule
            // Tasks) and mount workspace panes. Schedule Tasks replaces
            // workspaceContent; createSurface would otherwise register the
            // Agent App in layout state while surface.view.window stays nil,
            // and the markRead destination check throws surfaceNotFound.
            // Order: select the thread's workspace first, then present that
            // workspace's content (present is idempotent when already there).
            windowController?.show()
            try selectWorkspace(workspaceID)
            windowController?.presentWorkspaceContent()
            windowController?.flushPendingRefresh()
            destinationWindow = windowController?.window
        }
        guard let destinationWindow else {
            throw LayoutError.surfaceNotFound
        }

        let surface: AgentAppSurface
        if let existing = preferredAgentAppSurface(in: workspaceID) {
            surface = existing
        } else {
            let descriptor = try openAgentApp(workspace: workspaceID)
            guard let created = SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface else {
                throw LayoutError.surfaceNotFound
            }
            surface = created
        }

        try focusSurface(workspace: workspaceID, surface: surface.descriptor.id)
        try selectAgentThread(
            thread: threadID,
            surfaceID: surface.descriptor.id,
            markReadOnSelection: false
        )
        windowController?.flushPendingRefresh()
        guard surface.viewModel.selectedThreadId == threadID else {
            throw LayoutError.surfaceNotFound
        }
        destinationWindow.contentView?.layoutSubtreeIfNeeded()
        destinationWindow.makeKeyAndOrderFront(nil)
        guard destinationWindow.isVisible,
              destinationWindow.isMiniaturized == false else {
            throw LayoutError.surfaceNotFound
        }
        if markRead,
           (!destinationWindowIsKey(destinationWindow) || surface.view.window !== destinationWindow) {
            throw LayoutError.surfaceNotFound
        }

        if markRead {
            try markAgentThreadRead(thread: threadID)
        }
        return surface.descriptor
    }

    @discardableResult
    public func openBotsDesk(botID: BotID, conversationID: BotConversationID? = nil) throws -> Bool {
        guard let ctx = context,
              let bot = try ctx.botStore.get(id: botID) else { return false }
        if let conversationID {
            guard let conversation = try ctx.botStore.conversation(id: conversationID),
                  conversation.botID == botID else { return false }
            if try ctx.botStore.conversationContextPin(conversationID: conversationID) != nil {
                guard let threadID = conversation.linkedAgentThreadID,
                      try Self.contextPinnedThreadDestination(threadID, context: ctx)
                        == .bot(botID, conversationID) else { return false }
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        windowController?.show()
        windowController?.presentBotsInMainContent()
        windowController?.flushPendingRefresh()
        guard let vm = botsViewModel else { return false }
        vm.openDesk(bot)
        if let conversationID { vm.selectDeskThread(conversationID) }
        windowController?.flushPendingRefresh()
        guard vm.selectedBotID == botID, vm.screen == .desk else { return false }
        if let conversationID { guard vm.selectedConversation?.id == conversationID else { return false } }
        guard let destination = windowController?.window else { return false }
        return destination.isVisible && destination.isMiniaturized == false
    }

    /// Prefer the currently focused Agent App tab, then layout order. This makes
    /// an explicit deep link deterministic without changing any sibling surface.
    func preferredAgentAppSurface(in workspaceID: WorkspaceID) -> AgentAppSurface? {
        guard let workspace = context?.state.workspaces[workspaceID] else { return nil }
        let candidates = SurfaceRegistry.shared.all().compactMap { $0 as? AgentAppSurface }
            .filter { $0.viewModel.workspaceID == workspaceID }
        guard !candidates.isEmpty else { return nil }

        if let focusedPaneID = workspace.focusedPaneID,
           let selectedID = workspace.layout.find(paneID: focusedPaneID)?.selectedSurfaceID,
           let focused = candidates.first(where: { $0.descriptor.id == selectedID }) {
            return focused
        }

        for paneID in workspace.layout.paneIDs() {
            for descriptor in workspace.layout.find(paneID: paneID)?.surfaces ?? [] {
                if let candidate = candidates.first(where: { $0.descriptor.id == descriptor.id }) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Embedded bot desk hand-off: new thread in the source thread's workspace with
    /// the summary as draft and `actor` selected (unlocked). The source thread is untouched.
    @discardableResult
    func createBotHandoffThread(from oldThreadID: AgentThreadID, actor: RunActor) throws -> AgentThread {
        guard let ctx = context,
              let old = try ctx.threadRepo.get(id: oldThreadID),
              let workspaceID = old.workspaceId else {
            throw LayoutError.workspaceNotFound
        }
        let recent = (try? ctx.messageRepo.listRecent(threadId: oldThreadID, limit: 50)) ?? []
        let summary = AgentAppViewModel.handoffSummary(title: old.title, threadId: oldThreadID, messages: recent)
        var created = try createAgentThread(
            workspace: workspaceID,
            title: "New thread",
            provider: old.provider,
            model: old.model,
            permissionMode: old.permissionMode,
            reasoningEffort: old.reasoningEffort,
            reasoningModel: old.reasoningModel,
            serviceTier: old.serviceTier,
            modelSelection: old.modelSelection,
            providerInstanceId: old.providerInstanceId,
            runAsUser: old.runAsUser,
            routingConfiguration: old.routingConfiguration,
            quiet: true
        )
        if actor != created.actor {
            created.actor = actor
            try ctx.threadRepo.upsert(created)
        }
        try AgentThreadDraftRepository(db: ctx.db).upsert(AgentThreadDraft(
            threadId: created.id,
            providerInstanceId: created.providerInstanceId ?? created.provider.rawValue,
            text: summary
        ))
        return created
    }

    func startBotHandoff(from oldThreadID: AgentThreadID, actor: RunActor) throws {
        let created = try createBotHandoffThread(from: oldThreadID, actor: actor)
        try openAgentThread(thread: created.id)
    }

    private func destinationWindowIsKey(_ window: NSWindow) -> Bool {
        destinationWindowIsKeyForTests?(window) ?? window.isKeyWindow
    }

    /// `token_saver.digest.get` stays until iOS bumps its treaty pin. Token
    /// Saver is gone, so it answers `enabled: false` plus the cached account
    /// usage the iOS rings still read.
    public func tokenSaverDigest() -> JSONValue? {
        guard let context else { return nil }
        // Refresh from durable disk state so the RPC never keeps serving a
        // stale process cache after usage writes.
        context.publishAccountUsageDigestFromDisk()
        return .object(AccountUsageWidgetDigest.lastCachedBody() ?? ["enabled": .bool(false)])
    }

    public func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread] {
        guard let ctx = context else { return [] }
        return try ctx.threadRepo.list(workspaceId: workspace)
    }

    public func listAgentThreadsOffMain(workspace: WorkspaceID?) async throws -> [AgentThread] {
        try await agentAppReadGateway.listThreads(workspaceId: workspace)
    }

    /// Legacy Path B hooks (LaunchAgent foreign ownership). Schedules now run
    /// in-process through the normal Agent App coordinator, so stop/stream use
    /// the local session — leave these unset.
    private static func wireScheduledRunControl(on viewModel: AgentAppViewModel, db: SQLiteDB) {
        _ = viewModel
        _ = db
        viewModel.isScheduledThreadRunning = nil
        viewModel.stopScheduledThread = nil
    }

    /// `@handle` remains an autocomplete affordance. The provider receives the
    /// complete turn and decides whether to call the Bot delegation tool; this
    /// layer must not infer or pre-dispatch a peer prompt from user prose.
    /// Serves `BotStore.listCached()` so transcript bodies and keystrokes never
    /// hit SQLite (perf audit AA-01).
    /// Every host of a workspace's Agent App wires it here: workspace tabs and the
    /// Activity conversation pane, so a reply from either runs exactly the same way.
    func wireWorkspaceAgentSurface(_ agent: AgentAppSurface, workspace: WorkspaceID, ctx: AppContext) {
        // Per-surface thread binding: persist this surface's selected
        // thread into its descriptor metadata so app restart restores it.
        agent.viewModel.onSelectedThreadChanged = { [weak self, weak agent] threadID in
            guard let self, let agent else { return }
            self.persistAgentSelectedThread(surfaceID: agent.descriptor.id, threadID: threadID)
        }
        // Initial restore/create select may not re-fire onSelectedThreadChanged.
        ctx.threadRepo.setLiveSurfaceBinding(
            surfaceID: agent.descriptor.id,
            threadID: agent.viewModel.selectedThreadId
        )
        agent.viewModel.markThreadRead = { [weak self] threadID in
            guard let self else { throw LayoutError.workspaceNotFound }
            try self.markAgentThreadRead(thread: threadID)
        }
        // Socket-driven thread mutations (create/rename/delete/read)
        // refresh this already-open surface — fixes the stale-VM gap.
        let queueSubscriptionToken = EventBus.shared.subscribe(
            since: nil,
            filter: .agentThreadAndQueue
        ) { [weak agent] ev in
            guard Self.shouldAdmitAgentLifecycleEvent(
                payload: ev.payload,
                workspaceID: workspace
            ) else { return }
            DispatchQueue.main.async {
                guard let agent else { return }
                agent.viewModel.handleThreadLifecycleEvent(
                    kind: ev.kind,
                    threadId: ev.payload.objectValue?["thread_id"]?.stringValue,
                    threadIds: ev.payload.objectValue?["thread_ids"]?.arrayValue?.compactMap(\.stringValue)
                )
                agent.viewModel.handleQueueLifecycleEvent(
                    kind: ev.kind,
                    threadId: ev.payload.objectValue?["thread_id"]?.stringValue,
                    message: ev.payload.objectValue?["message"]?.stringValue
                )
                AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(
                    workspaceID: agent.viewModel.workspaceID
                )
                AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedQueueReload(
                    workspaceID: agent.viewModel.workspaceID
                )
            }
        }
        agent.subscriptionToken = AnyHashable(queueSubscriptionToken)
        agent.onClose = { EventBus.shared.unsubscribe(queueSubscriptionToken) }
        agent.viewModel.providerSnapshotLoader = { [weak self, weak agent] in
            await self?.listAgentProviderSnapshots(runAsUser: agent?.viewModel.runAsUser) ?? []
        }
        agent.viewModel.refreshProviderSnapshotsInBackground()
        agent.viewModel.providerLaunchConfig = { [weak self] provider, instanceId in
            (
                self?.providerBinary(provider: provider, instanceId: instanceId),
                self?.providerEnvironment(provider: provider, instanceId: instanceId) ?? [:]
            )
        }
        agent.viewModel.providerRecoveryAction = { [weak self] provider, instanceId in
            guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
            let result = try await self.updateAgentProvider(provider: provider, providerInstanceId: instanceId)
            return result.objectValue?["stdout"]?.stringValue ?? ""
        }
        agent.viewModel.providerSignInAction = { [weak self] provider in
            guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
            try self.openProviderSignInTerminal(workspace: workspace, provider: provider)
        }
        agent.viewModel.providerAuthenticationRefresher = { [weak self] provider in
            await self?.refreshAgentProviderAuthentication(provider) ?? []
        }
        agent.viewModel.pullRequestThreadPreparer = { [weak self] url, provider, model, permission, reasoning, serviceTier, modelSelection, providerInstanceId in
            guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
            return try self.prepareAgentThreadForPullRequest(workspace: workspace, url: url, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId)
        }
        agent.viewModel.onReviewRequested = { [weak self] in
            _ = try? self?.createSurface(workspace: workspace, type: .rightSidebarTool, paneID: nil, title: "Git")
        }
        // UX-MAC_AGENT-OPEN-SPLIT: clicked file mentions / links open
        // (or reuse) a split panel to the right of this agent surface.
        agent.viewModel.onOpenFileInSplit = { [weak self, weak agent] path in
            guard let self, let agent else { return }
            self.openFileInAdjacentSplit(workspace: workspace, sourceSurface: agent.descriptor.id, absolutePath: path)
        }
        agent.viewModel.onOpenURLInSplit = { [weak self, weak agent] url in
            guard let self, let agent else { return }
            self.openURLInAdjacentSplit(workspace: workspace, sourceSurface: agent.descriptor.id, url: url)
        }
        agent.viewModel.onForkInNewChat = { [weak self, weak agent] messageID in
            guard let self, let agent, let source = agent.viewModel.selectedThreadId else { return }
            Task { @MainActor in
                do {
                    let child = try await self.forkAgentThread(sourceThreadId: source, messageID: messageID)
                    agent.viewModel.selectThread(child.id)
                } catch {
                    agent.viewModel.statusMessage = "Could not fork thread: \(error)"
                }
            }
        }
        agent.viewModel.onRequestSideChat = { [weak self, weak agent] text in
            guard let self, let agent, let source = agent.viewModel.selectedThreadId else { return }
            Task { @MainActor in
                do {
                    let child = try await self.sideAgentThread(sourceThreadId: source, text: text.isEmpty ? nil : text)
                    self.openSideChatSplit(workspace: workspace, sourceSurface: agent.descriptor.id, threadId: child.id, seed: text.isEmpty ? nil : text)
                } catch {
                    agent.viewModel.statusMessage = "Could not open side chat: \(error)"
                }
            }
        }
        agent.viewModel.onRequestBtw = { [weak self, weak agent] question in
            guard let self, let agent, let source = agent.viewModel.selectedThreadId else { return }
            Task { @MainActor in
                do {
                    let answer = try await self.btwAgentThread(threadId: source, question: question)
                    agent.viewModel.appendBtwNote(question: question, answer: answer)
                } catch {
                    agent.viewModel.statusMessage = "Could not get side answer: \(error)"
                }
            }
        }
        agent.viewModel.onRunStateChange = { [weak self] in
            guard let self else { return }
            if !self.promoteWorkspaceIfBusy(workspace) {
                self.windowController?.refreshSurfaceRuntimeState()
            }
        }
        agent.viewModel.onRunCompleted = { [weak self] in
            self?.promoteWorkspaceAfterCompletedRun(workspace)
        }
        agent.viewModel.onThreadConfigPersisted = { [weak self] thread in
            self?.publishAgentThreadUpdated(thread)
        }
        agent.viewModel.onThreadLifecycle = { [weak self] event in
            self?.publishAgentThreadLifecycle(event)
        }
        agent.viewModel.onThreadChromeWritten = { write in
            write.publish()
        }
        agent.viewModel.retireDeletedThreadRuntime = { [weak ctx] ids, coordinatorAlreadyRetired in
            ctx?.retireDeletedAgentThreads(
                ids,
                coordinatorAlreadyRetired: coordinatorAlreadyRetired
            )
        }
        Self.wireScheduledRunControl(on: agent.viewModel, db: ctx.db)
        wireQueueDrainControl(on: agent.viewModel, context: ctx)
        wireBotPeerHandoffDeletion(on: agent.viewModel, context: ctx)
        configureAgentAppBotMentions(agent)
        agent.viewModel.onPlanNotesPersisted = { [weak self] thread, notes in
            self?.publishAgentPlanNotesUpdated(thread: thread, notes: notes)
        }
        agent.viewModel.onQueuedMessageEvent = { [weak self] kind, message in
            self?.publishQueuedMessage(kind: kind, message)
        }
    }

    /// A caller thread in a real workspace sees only that workspace's Bots and general Bots.
    static func peerIsInCallerScope(_ bot: BotDefinition, callerWorkspace: WorkspaceID?, ctx: AppContext) throws -> Bool {
        guard let callerWorkspace, callerWorkspace != BotsViewModel.botDeskWorkspaceID else { return true }
        let bindings = try ctx.botStore.listContextBindings(hostID: ctx.liveActivityHostIdentity.serverId, botID: bot.id)
        return SidebarViewModel.isAvailable(bot, bindings: bindings, inWorkspace: callerWorkspace)
    }

    private var mentionableBotsCache: [WorkspaceID: (revision: UInt64, bots: [BotDefinition])] = [:]

    /// Bots offered by @ in a workspace: its own Bots and general Bots. `keeping`
    /// is the selected thread's Bot, which stays resolvable for its chrome.
    /// Cached per Bot-list revision (grants bump it) so keystrokes never hit SQLite.
    func mentionableBots(inWorkspace workspace: WorkspaceID, keeping actor: BotID?) -> [BotDefinition] {
        guard let store = context?.botStore, let roster = try? store.listCached() else { return [] }
        guard workspace != BotsViewModel.botDeskWorkspaceID, let hostID = context?.liveActivityHostIdentity.serverId else { return roster }
        let revision = store.botsListRevision
        let scoped: [BotDefinition]
        if let cache = mentionableBotsCache[workspace], cache.revision == revision {
            scoped = cache.bots
        } else {
            scoped = roster.filter { bot in
                let bindings = (try? store.listContextBindings(hostID: hostID, botID: bot.id)) ?? []
                return SidebarViewModel.isAvailable(bot, bindings: bindings, inWorkspace: workspace)
            }
            mentionableBotsCache[workspace] = (revision, scoped)
        }
        guard let actor, !scoped.contains(where: { $0.id == actor }),
              let own = roster.first(where: { $0.id == actor }) else { return scoped }
        return scoped + [own]
    }

    func configureAgentAppBotMentions(_ agent: AgentAppSurface) {
        agent.viewModel.botComputerControl = botComputerControl
        agent.viewModel.manualActionStore = manualActionStore
        agent.viewModel.mentionableBotsProvider = { [weak self, weak vm = agent.viewModel] in
            guard let self, let vm else { return [] }
            let actor = vm.threads.first { $0.id == vm.selectedThreadId }?.actor.botID
            return self.mentionableBots(inWorkspace: vm.workspaceID, keeping: actor)
        }
        agent.viewModel.createBotInWorkspace = { [weak self] workspaceID in
            self?.windowController?.presentBotsInMainContent()
            self?.botsViewModel?.beginCreate(inWorkspace: workspaceID)
        }
        agent.viewModel.mentionableBotsRevisionProvider = { [weak self] in
            self?.context?.botStore.botsListRevision ?? 0
        }
        configureBotVMHooks(on: agent.viewModel)
        agent.viewModel.botIsAvailable = { [weak self] botID in
            guard let store = self?.context?.botStore else { return false }
            if ((try? store.listCached()) ?? []).contains(where: { $0.id == botID }) { return true }
            // Hidden bots are absent from the cached list; only a missing or deleted row is unavailable.
            guard let bot = (try? store.get(id: botID)) ?? nil else { return false }
            return bot.deletedAt == nil
        }
        agent.viewModel.botNameProvider = { [weak self] botID in
            (try? self?.context?.botStore.get(id: botID))??.name
        }
        agent.viewModel.botThreadLinker = { [weak self] botID, threadID in
            guard let hooks = self?.botWorkspaceRunHooks else { throw BotWorkspaceRunUnavailable() }
            try hooks.link(botID, threadID)
        }
        agent.viewModel.botPromptTransform = { [weak self] botID, text, threadID, runID in
            guard let hooks = self?.botWorkspaceRunHooks else { throw BotWorkspaceRunUnavailable() }
            return try await hooks.promptTransform(botID, text, threadID, runID)
        }
        // The VM claim (D12) is taken before the start (`botClaimVM`).
        agent.viewModel.botRunStarted = { [weak self] botID, runID, threadID in
            self?.botWorkspaceRunHooks?.runStarted(botID, runID, threadID)
        }
        agent.viewModel.openBotScreen = { [weak self] botID in self?.openBotGuestDesktopInNewWindow(botID) }
    }

    /// The bot VM hooks every Agent App that runs bot threads shares (Agent
    /// App tabs and the embedded Bots Desk): target default, the queue behind
    /// a VM rebuild or stop, Mac-execution approvals, and the VM gate behind the D11 banner.
    func configureBotVMHooks(on viewModel: AgentAppViewModel) {
        viewModel.importFilesToBotComputer = { [weak self] botID, threadID, urls in
            guard let context = self?.context else { throw BotWorkspaceRunUnavailable() }
            let resource = try context.botStore.guestResourceID(botID: botID, threadID: threadID)
            return try BotGuestHome.importFiles(urls, appSupport: context.appSupportDirectory, botID: resource)
        }
        viewModel.botExecutionTargetProvider = { [weak self] botID in
            guard let store = self?.context?.botStore else { return .mac }
            let revision = (try? store.get(id: botID))?.currentRevisionID.flatMap { try? store.getRevision(id: $0) }
            return BotExecutionDefault.target(for: revision ?? nil)
        }
        viewModel.botBusyMessage = { [weak self] botID, threadID in
            do {
                let resource = try self?.context?.botStore.guestResourceID(botID: botID, threadID: threadID)
                return BotVMRunRegistry.shared.busyMessage(botID: botID, threadID: threadID, resourceID: resource)
            } catch { return String(describing: error) }
        }
        viewModel.botWaitForVM = { [weak self] botID, threadID in
            let resource = try? self?.context?.botStore.guestResourceID(botID: botID, threadID: threadID)
            BotVMRunRegistry.shared.addWaiting(botID: botID, threadID: threadID, resourceID: resource)
            self?.publishBotVMWait(thread: threadID)
        }
        viewModel.botClaimVM = { [weak self] botID, entry in
            do {
                let resource = try self?.context?.botStore.guestResourceID(botID: botID, threadID: entry.threadID)
                return BotVMRunRegistry.shared.tryBegin(botID: botID, entry: entry, resourceID: resource)
            } catch {
                return BotVMRunRegistry.Entry(threadID: entry.threadID, runID: entry.runID,
                    title: String(describing: error), workspace: entry.workspace)
            }
        }
        viewModel.botReleaseVM = { [weak self] runID in self?.releaseBotVMRun(runID) }
        // iOS parity: the composer's bot lock and "Run this thread on the Mac"
        // reach paired devices from the Desk too, as from Agent App tabs.
        viewModel.onThreadConfigPersisted = { [weak self] thread in
            self?.publishAgentThreadUpdated(thread)
        }
        viewModel.botMacExecutionResolver = { [weak self] threadID, approve in
            // A store failure keeps the request open and puts the banner back.
            _ = try? await self?.resolveMacExecution(thread: threadID, approve: approve)
        }
        viewModel.botVMPreflight = { [weak self] botID, workspace, threadID in
            await self?.botVMPreflight(botID, workspace: workspace, threadID: threadID)
        }
        viewModel.botVMProvision = { [weak self] botID in await self?.provisionBotVM(botID) }
        viewModel.pendingMacExecutionByThread = pendingMacExecution
    }

    private struct BotWorkspaceRunUnavailable: LocalizedError {
        var errorDescription: String? { "Bot unavailable." }
    }

    private var hostCatalogCreatedBots: [AgentRunID: Set<BotID>] = [:]

    public func listBotPeers(
        callerThread: AgentThreadID,
        callerRun: AgentRunID,
        delegationCapability: String? = nil
    ) throws -> JSONValue {
        let ctx = try validatedBotPeerCaller(
            threadID: callerThread,
            runID: callerRun,
            delegationCapability: delegationCapability,
            mutation: false,
            method: "bot.peer.list"
        )
        let caller = try ctx.threadRepo.get(id: callerThread)
        let inheritsWorkspace = try caller.map {
            try ctx.botPeerHandoffAuthority.inheritedWorkspaceScope(thread: $0, runID: callerRun) != nil
        } ?? true
        return .object([
            "bots": .array(try ctx.botStore.list().filter { bot in
                try Self.peerIsInCallerScope(bot, callerWorkspace: caller?.workspaceId, ctx: ctx)
            }.map { bot in
                let skills = try ctx.botStore.listSkillBindings(botID: bot.id).filter(\.enabled).map(\.skillID)
                let binding: BotContextBinding?
                let unavailableReason: String?
                do {
                    binding = try ctx.botPeerHandoffAuthority.peerContextBinding(callerThread: callerThread, peerBotID: bot.id)
                    unavailableReason = nil
                } catch {
                    binding = nil
                    unavailableReason = (error as? JSONRPCError)?.message ?? "Current context access could not be verified."
                }
                let destination = try ctx.botStore.executionDestination(botID: bot.id)
                return .object([
                    "id": .string(bot.id.value.uuidString.lowercased()),
                    "handle": .string(bot.handle),
                    "name": .string(bot.name),
                    "title": .string(bot.title),
                    "description": .string(bot.description),
                    "revision_id": bot.currentRevisionID.map { .string($0.value.uuidString.lowercased()) } ?? .null,
                    "configured_skills": .array(skills.map(JSONValue.string)),
                    "execution_destination": .string(destination.storageValue),
                    "context_actions": binding.map { .array($0.actions.map(\.rawValue).sorted().map(JSONValue.string)) } ?? .null,
                    "context_available": .bool(unavailableReason == nil),
                    "unavailable_reason": unavailableReason.map(JSONValue.string) ?? .null,
                    "busy": .bool(ctx.botPeerHandoffAuthority.peerIsBusy(bot.id)),
                    "async_available": .bool(unavailableReason == nil && !inheritsWorkspace),
                    "execution_readiness": .string("validated_at_dispatch"),
                    "route": .string("inherits_current_caller"),
                    "consultations": .array(ctx.botPeerHandoffAuthority.availableConsultations(
                        callerThread: callerThread, callerRun: callerRun, peerBotID: bot.id)),
                ])
            }),
            "limits": .object(["root_admissions": .number(12), "root_active": .number(4),
                "depth": .number(4), "root_seconds": .number(900), "provider_usage": .string("unknown_until_reported")]),
        ])
    }

    public func botPeerAskProgress(threadID: String, runID: String) -> Date? {
        guard let runUUID = UUID(uuidString: runID) else { return nil }
        _ = threadID
        return context?.botPeerHandoffAuthority.latestPeerProgress(hostRunID: AgentRunID(runUUID))
    }

    public func botPeerActivityProgress(threadID: String, activityID: String) -> Date? {
        guard let thread = UUID(uuidString: threadID), let activity = UUID(uuidString: activityID) else { return nil }
        return context?.botPeerHandoffAuthority.activityProgress(activityID: activity, callerThread: AgentThreadID(thread))
    }

    public func askBotPeer(
        callerThread: AgentThreadID,
        callerRun: AgentRunID,
        handle: String,
        prompt: String,
        replyMode: BotPeerDelegation.ReplyMode,
        delegationCapability: String? = nil
    ) async throws -> JSONValue {
        try await askBotPeer(
            callerThread: callerThread,
            callerRun: callerRun,
            handle: handle,
            prompt: prompt,
            replyMode: replyMode,
            consultationID: nil,
            delegationCapability: delegationCapability
        )
    }

    public func askBotPeer(
        callerThread: AgentThreadID, callerRun: AgentRunID, handle: String, prompt: String,
        replyMode: BotPeerDelegation.ReplyMode, consultationID: UUID?, delegationCapability: String?
    ) async throws -> JSONValue {
        try await askBotPeer(callerThread: callerThread, callerRun: callerRun, handle: handle,
            prompt: prompt, replyMode: replyMode, consultationID: consultationID, wait: true,
            delegationCapability: delegationCapability)
    }

    public func askBotPeer(
        callerThread: AgentThreadID,
        callerRun: AgentRunID,
        handle: String,
        prompt: String,
        replyMode: BotPeerDelegation.ReplyMode,
        consultationID: UUID?,
        wait: Bool = true,
        delegationCapability: String? = nil
    ) async throws -> JSONValue {
        let ctx = try validatedBotPeerCaller(
            threadID: callerThread,
            runID: callerRun,
            delegationCapability: delegationCapability,
            mutation: false,
            method: "bot.peer.ask"
        )
        let peer: BotDefinition
        let delegatedPrompt: String
        let originThread: AgentThread
        var claimedConsultationID: UUID?
        defer {
            if let claimedConsultationID {
                ctx.botPeerHandoffAuthority.releaseContinuation(consultationID: claimedConsultationID)
            }
        }
        do {
            guard let normalizedHandle = BotHandle.normalize(handle),
                  let found = try ctx.botStore.list().first(where: { $0.handle == normalizedHandle }) else {
                throw JSONRPCError(code: -32044, message: "MacCode Bot @\(handle) was not found.")
            }
            peer = found
            guard try Self.peerIsInCallerScope(found, callerWorkspace: try ctx.threadRepo.get(id: callerThread)?.workspaceId, ctx: ctx) else {
                throw JSONRPCError(code: -32047, message: "@\(found.handle) belongs to another workspace; only this workspace's Bots and general Bots are available here.")
            }
            delegatedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !delegatedPrompt.isEmpty, wait || replyMode == .consult else {
                throw JSONRPCError(code: -32602, message: "Provide a prompt and use consult mode for asynchronous work.")
            }
            guard let thread = try ctx.threadRepo.get(id: callerThread) else {
                throw JSONRPCError(code: -32004, message: "The calling Agent thread no longer exists.")
            }
            originThread = thread
            _ = try ctx.botPeerHandoffAuthority.peerContextBinding(callerThread: callerThread, peerBotID: peer.id)
            if let consultationID {
                try ctx.botPeerHandoffAuthority.claimContinuation(consultationID: consultationID,
                    callerThread: callerThread, hostRunID: callerRun, peerBotID: peer.id)
                claimedConsultationID = consultationID
            }
        } catch let error as JSONRPCError {
            throw JSONRPCError(code: error.code, message: error.message,
                data: .object(["admission": .string("rejected")]))
        }
        ctx.botPeerHandoffAuthority.router = self
        let result = try await ctx.botPeerHandoffAuthority.askPeerFromActiveProvider(
            peer: peer,
            prompt: delegatedPrompt,
            originThread: originThread,
            hostRunID: callerRun,
            providerSnapshots: cachedProviderSnapshotsForSend(),
            delegationCapability: delegationCapability?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            consultationID: consultationID,
            wait: wait
        )
        _ = try validatedBotPeerCaller(threadID: callerThread, runID: callerRun,
            delegationCapability: delegationCapability, mutation: false, method: "bot.peer.ask")
        guard var object = result.objectValue else { throw JSONRPCError.internalError }
        if wait, object["status"] != .string("completed") {
            throw JSONRPCError(code: -32045, message: "The Bot activity did not produce a verified reply.", data: result)
        }
        if replyMode == .replyOnly { ctx.coordinator.suppressPrimaryAssistantReply(runId: callerRun) }
        object["reply_mode"] = .string(replyMode.rawValue)
        object["next"] = .string(!wait
            ? "Observe this activity with bot_peer_status before using its result."
            : (replyMode == .replyOnly
                ? "End the turn now. MacCode will keep only the attributed Bot reply."
                : "Continue the original user request using this reply."))
        return .object(object)
    }

    public func observeBotPeer(callerThread: AgentThreadID, callerRun: AgentRunID, activityID: UUID,
                               wait: Bool, cancel: Bool, delegationCapability: String?) async throws -> JSONValue {
        let ctx = try validatedBotPeerCaller(threadID: callerThread, runID: callerRun,
            delegationCapability: delegationCapability, mutation: false,
            method: cancel ? "bot.peer.cancel" : "bot.peer.status")
        let result = try await ctx.botPeerHandoffAuthority.observePeerActivity(activityID,
            callerThread: callerThread, wait: wait, cancel: cancel)
        _ = try validatedBotPeerCaller(threadID: callerThread, runID: callerRun,
            delegationCapability: delegationCapability, mutation: false,
            method: cancel ? "bot.peer.cancel" : "bot.peer.status")
        return result
    }

    public func validateBotPeerReceipt(callerThread: AgentThreadID, result: JSONValue) throws {
        guard let ctx = context,
              let activityID = result.objectValue?["activity_id"]?.stringValue.flatMap(UUID.init) else {
            throw JSONRPCError(code: -32050, message: "This Bot receipt cannot be authorized.")
        }
        _ = try ctx.botPeerHandoffAuthority.peerActivity(activityID, callerThread: callerThread)
    }

    public func invokeDelegatedBotSelfConfig(
        callerThread: AgentThreadID,
        callerRun: AgentRunID,
        toolName: String,
        arguments: [String: JSONValue],
        delegationCapability: String? = nil
    ) throws -> JSONValue {
        let isSecretTool = toolName == BotSelfConfigCatalog.listSecrets
            || toolName == BotSelfConfigCatalog.saveSecret
            || toolName == BotSelfConfigCatalog.deleteSecret
        let isSecretMutation = toolName == BotSelfConfigCatalog.saveSecret
            || toolName == BotSelfConfigCatalog.deleteSecret
        let ctx = try validatedBotPeerCaller(
            threadID: callerThread,
            runID: callerRun,
            delegationCapability: delegationCapability,
            mutation: isSecretMutation,
            method: "bot.peer.self_config"
        )
        guard isSecretTool
                || toolName == BotSelfConfigCatalog.getSettings
                || toolName == BotSelfConfigCatalog.setSettings else {
            throw JSONRPCError(code: -32602, message: "Tool is not available through a delegated Bot grant.")
        }
        let requestedID = arguments["bot_id"]?.stringValue
            .flatMap(UUID.init)
            .map(BotID.init)
        let targetID: BotID
        if isSecretTool {
            guard let candidate = requestedID ?? ctx.botPeerHandoffAuthority.delegatedBotID(
                forHostRunID: callerRun
            ) else {
                throw JSONRPCError(
                    code: -32046,
                    message: "This active run has no matching Bot grant."
                )
            }
            targetID = try authorizedHostSkillBot(
                botID: candidate,
                callerRun: callerRun,
                callerThread: callerThread
            )
        } else {
            guard let delegatedID = ctx.botPeerHandoffAuthority.delegatedBotID(
                forHostRunID: callerRun,
                requestedBotID: requestedID
            ) else {
                throw JSONRPCError(
                    code: -32046,
                    message: "This active run has no matching completed Bot consultation grant."
                )
            }
            targetID = delegatedID
        }
        var foundationArguments = arguments.mapValues(Self.botPeerFoundationValue)
        foundationArguments["bot_id"] = targetID.value.uuidString.lowercased()
        let delegatedContext = ctx.botPeerHandoffAuthority.delegatedContext(
            forHostRunID: callerRun, requestedBotID: targetID
        )
        guard isSecretTool || delegatedContext != nil else {
            throw JSONRPCError(code: -32046, message: "The consulted Bot context is no longer authorized.")
        }
        let service = BotSelfConfigService(
            callerBotID: targetID,
            callerThreadID: delegatedContext?.threadID,
            store: ctx.botStore,
            secretStore: botSecretStore,
            appSupportDirectory: ctx.appSupportDirectory
        )
        let result = try service.invoke(name: toolName, arguments: foundationArguments)
        if toolName == BotSelfConfigCatalog.setSettings {
            _ = botsViewModel?.refreshPublishedIdentity(for: targetID)
        }
        return JSONValue.from(result)
    }

    private func validatedBotPeerCaller(
        threadID: AgentThreadID,
        runID: AgentRunID,
        delegationCapability: String?,
        mutation: Bool,
        method: String
    ) throws -> AppContext {
        // Presence only. A full 26-column + routing `get` hitchs MainActor on
        // every bot.peer.list / self_config / ask admission.
        guard let ctx = context,
              try ctx.threadRepo.status(of: threadID) != nil else {
            throw JSONRPCError(code: -32004, message: "The calling Agent thread no longer exists.")
        }
        try authenticateManagedHostCall(
            threadID: threadID,
            runID: runID,
            delegationCapability: delegationCapability,
            mutation: mutation,
            method: method
        )
        if let pin = try ctx.botStore.conversationContextPin(linkedTo: threadID) {
            guard try ctx.botStore.authorizes(hostID: pin.hostID, botID: pin.botID, context: pin.context,
                    action: .read, policyRevision: pin.policyRevision),
                  try ctx.botStore.authorizesContextDelegation(hostID: pin.hostID, runID: runID, threadID: threadID) else {
                throw JSONRPCError(code: -32047, message: "The calling Bot context is no longer authorized.")
            }
        }
        return ctx
    }

    public func managedHostCallerIsTitio(threadID: AgentThreadID) throws -> Bool {
        guard let ctx = context,
              let conversation = try ctx.botStore.conversationLinked(to: threadID),
              let bot = try ctx.botStore.get(id: conversation.botID), bot.deletedAt == nil else { return false }
        return bot.handle.lowercased() == TitioIdentity.handle
    }

    public func authenticateManagedHostCall(
        threadID: AgentThreadID,
        runID: AgentRunID,
        delegationCapability: String?,
        mutation: Bool,
        method: String
    ) throws {
        guard let ctx = context else {
            throw JSONRPCError(code: -32004, message: "The calling Agent thread no longer exists.")
        }
        let runIDText = runID.value.uuidString.lowercased()
        let threadIDText = threadID.value.uuidString.lowercased()
        if RemoteCodeHostCatalog.rpcMethods.contains(method),
           !SettingsStore(db: ctx.db).load().botControlPlaneFlags.isBotControlPlaneActive {
            RemoteCodeHostCatalogDiagnostics.authorization(
                decision: "control_plane_off",
                method: method,
                runID: runIDText,
                threadID: threadIDText
            )
            throw JSONRPCError(code: -32049, message: "Bot control plane is off.")
        }
        guard let capability = delegationCapability?.trimmingCharacters(in: .whitespacesAndNewlines),
              !capability.isEmpty else {
            RemoteCodeHostCatalogDiagnostics.authorization(
                decision: "missing_capability",
                method: method,
                runID: runIDText,
                threadID: threadIDText
            )
            throw JSONRPCError(
                code: -32047,
                message: "Host catalog requires an authenticated active run."
            )
        }
        let receipt: AgentOrchestrationAdmissionReceipt?
        do {
            receipt = try ctx.orchestrationRuntime.activeReceipt(
                runId: runID,
                threadId: threadID,
                delegationCapability: capability
            )
        } catch {
            RemoteCodeHostCatalogDiagnostics.authorization(
                decision: "receipt_lookup_failed",
                method: method,
                runID: runIDText,
                threadID: threadIDText
            )
            throw JSONRPCError(
                code: -32047,
                message: "Host catalog requires an authenticated active run."
            )
        }
        guard let receipt else {
            RemoteCodeHostCatalogDiagnostics.authorization(
                decision: "inactive_or_mismatched_receipt",
                method: method,
                runID: runIDText,
                threadID: threadIDText
            )
            throw JSONRPCError(
                code: -32047,
                message: "Host catalog requires an authenticated active run."
            )
        }
        if mutation, receipt.permissionMode != .fullAccess {
            RemoteCodeHostCatalogDiagnostics.authorization(
                decision: "captured_permission_denied",
                method: method,
                runID: runIDText,
                threadID: threadIDText,
                receiptID: receipt.id.uuidString.lowercased(),
                permission: receipt.permissionMode.rawValue
            )
            throw JSONRPCError(
                code: -32048,
                message: "Host catalog mutations require the captured fullAccess permission."
            )
        }
        RemoteCodeHostCatalogDiagnostics.authorization(
            decision: mutation ? "authorized_mutation" : "authorized_read",
            method: method,
            runID: runIDText,
            threadID: threadIDText,
            receiptID: receipt.id.uuidString.lowercased(),
            permission: receipt.permissionMode.rawValue
        )
    }

    public func createHostBot(
        name: String,
        title: String,
        description: String,
        handle: String?,
        soul: String,
        callerRun: AgentRunID
    ) throws -> JSONValue {
        guard let ctx = context else { throw JSONRPCError(code: -32004, message: "The calling Agent thread no longer exists.") }
        let bot = try ctx.botStore.create(
            name: name,
            title: title,
            description: description,
            handle: handle,
            soul: soul,
            workspaceID: ctx.state.window.selectedWorkspaceID
        )
        let home = BotHome(appSupportDirectory: ctx.appSupportDirectory, bot: bot)
        try? home.ensure(
            name: bot.name,
            handle: bot.handle,
            title: bot.title,
            description: bot.description,
            soul: soul
        )
        hostCatalogCreatedBots[callerRun, default: []].insert(bot.id)
        botsViewModel?.reload()
        return Self.hostBotJSON(bot)
    }

    public func listHostBots() throws -> JSONValue {
        guard let ctx = context else { throw JSONRPCError(code: -32004, message: "The calling Agent thread no longer exists.") }
        return .object([
            "bots": .array(try ctx.botStore.list().map(Self.hostBotJSON)),
        ])
    }

    public func openHostBot(botID: BotID) throws -> JSONValue {
        let opened = try openBotsDesk(botID: botID)
        return .object([
            "bot_id": .string(botID.value.uuidString.lowercased()),
            "opened": .bool(opened),
        ])
    }

    public func sendHostBot(
        botID: BotID,
        text: String,
        conversationID: BotConversationID?,
        callerThread: AgentThreadID,
        callerRun: AgentRunID
    ) async throws -> JSONValue {
        guard let ctx = context,
              let botsViewModel,
              let route = try ctx.runRepo.route(of: callerRun),
              route.threadId == callerThread,
              let policy = try ctx.threadRepo.deskPolicy(of: callerThread) else {
            throw JSONRPCError(code: -32045, message: "MacCode Bot runtime is unavailable.")
        }
        return try botsViewModel.enqueueHostMessage(
            botID: botID,
            text: text,
            conversationID: conversationID,
            routing: BotDeskRouting(route: route, policy: policy)
        )
    }

    public func createHostBotThread(botID: BotID, title: String) throws -> JSONValue {
        guard let ctx = context else { throw JSONRPCError(code: -32004, message: "The calling Agent thread no longer exists.") }
        guard let bot = try ctx.botStore.get(id: botID), bot.deletedAt == nil else {
            throw JSONRPCError(code: -32044, message: "MacCode Bot was not found.")
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = BotConversation(
            botID: bot.id,
            title: trimmed.isEmpty ? "New thread" : trimmed
        )
        try ctx.botStore.upsertConversation(conversation)
        botsViewModel?.reload()
        return .object([
            "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "conversation_id": .string(conversation.id.value.uuidString.lowercased()),
            "title": .string(conversation.title),
        ])
    }

    public func createHostBotSkill(
        botID: BotID,
        skillID: String,
        body: String?,
        callerRun: AgentRunID,
        callerThread: AgentThreadID
    ) throws -> JSONValue {
        let target = try authorizedHostSkillBot(botID: botID, callerRun: callerRun, callerThread: callerThread)
        guard let ctx = context else { throw JSONRPCError(code: -32004, message: "The calling Agent thread no longer exists.") }
        let environment = [
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": ctx.appSupportDirectory.path,
            BotSelfConfigCatalog.callerEnvironmentKey: target.value.uuidString.lowercased(),
        ]
        let service = try BotSelfConfigService.make(environment: environment, store: ctx.botStore)
        let result = try service.createSkill(skillID: skillID, body: body)
        botsViewModel?.reload()
        return JSONValue.from(result)
    }

    private var pairedBotRemote: BotRemoteControlAuthority?
    private var pairedGuestObserver: BotGuestObserveCoordinator?
    private var pairedBotSettlementWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// False until the projector is created, which a paired `bot.send` does.
    /// Until then no run is bound and no settle is queued, so a read has
    /// nothing to wait for and must not be what subscribes it to every event.
    private(set) var botRuntimeEvidenceProjectorExists = false
    private lazy var botRuntimeEvidenceProjector: BotRuntimeEvidenceProjector = {
        botRuntimeEvidenceProjectorExists = true
        return BotRuntimeEvidenceProjector { [weak self] terminal in
            let signposter = PerfSwitchMetrics.signposter
            let interval = signposter.beginInterval("bot_settle", id: signposter.makeSignpostID())
            defer { signposter.endInterval("bot_settle", interval) }
            _ = self?.pairedBotRemote?.settleRuntime(
                botID: terminal.botID,
                runID: terminal.runID,
                failed: terminal.failed
            )
        }
    }()

    /// Paired-device `bot.*` reads that touch only the authority's own state
    /// and SQLite (no MainActor callback, no queue write). They run off
    /// MainActor and never reload the desk's queued follow-ups.
    /// `bot.attention.list` stays on MainActor: its delegated-attention
    /// snapshot callback reads router state. `bot.conversation.list` stays on
    /// MainActor too: each row's `desk_routing` comes from the
    /// `onConversationRouting` callback, which reads `BotsViewModel` state.
    nonisolated static let pairedBotOffMainReadMethods: Set<String> = [
        "bot.list",
        "bot.get",
        "bot.settings.get",
        "bot.queue.list",
        "bot.attachment.list",
        "bot.routine.list",
        "bot.files.list",
        "bot.browser.state",
        "bot.guest.state",
        "bot.receipt.status",
    ]
    /// Titio notice writes: the hub claims in SQLite on the caller's thread,
    /// so they run like the off-main reads, never on the MainActor.
    nonisolated static let pairedBotOffMainMutationMethods: Set<String> = [
        "bot.notice.act",
        "bot.notice.reply",
        "bot.notice.read",
        "bot.notice.clear",
    ]
    nonisolated static let pairedBotMainActorReadMethods: Set<String> = [
        "bot.attention.list",
        "bot.conversation.list",
        "bot.reserved.probe",
    ]
    /// Paired-device reads whose answer reports a run's status, attention
    /// state or `run_id`. `bot.run.completed` is published before the run is
    /// settled, so each first waits for the settles already queued when it
    /// arrives: a read made on that event never shows the run still working.
    /// `bot.receipt.status` reads `run_outcome` from the durable run row,
    /// already written when the event is published; it waits only so the
    /// three reads answer in one order.
    nonisolated static let pairedBotRunStateReadMethods: Set<String> = [
        "bot.attention.list",
        "bot.conversation.list",
        "bot.receipt.status",
    ]
    /// Test seam: the projector whose queued settles those reads wait for.
    var botRuntimeEvidenceProjectorForTesting: BotRuntimeEvidenceProjector { botRuntimeEvidenceProjector }

    /// `bot.conversation.fork {bot_id, conversation_id, message_id?}`: forks a
    /// Bot conversation from a paired device, like the Mac desk's fork button.
    /// The receipt names the new conversation so the phone can open it.
    func forkPairedBotConversation(params: [String: JSONValue]) async throws -> JSONValue {
        guard let botID = params["bot_id"]?.stringValue.flatMap(UUID.init).map(BotID.init),
              let conversationID = params["conversation_id"]?.stringValue.flatMap(UUID.init).map(BotConversationID.init) else {
            throw JSONRPCError.invalidParams
        }
        guard let vm = botsViewModel else {
            throw JSONRPCError(code: -32091, message: "Bot runtime is unavailable.")
        }
        guard (try? context?.botStore.conversation(id: conversationID))??.botID == botID else {
            throw JSONRPCError.invalidParams
        }
        let forked = try await vm.forkDeskConversation(
            conversationID: conversationID,
            messageID: params["message_id"]?.stringValue
        )
        let requestID = params["client_request_id"]?.stringValue ?? UUID().uuidString.lowercased()
        var readback: [String: JSONValue] = [
            "conversation_id": .string(forked.id.value.uuidString.lowercased()),
            "title": .string(forked.title),
            "route": .string("bot"),
        ]
        if let thread = forked.linkedAgentThreadID {
            readback["thread_id"] = .string(thread.value.uuidString.lowercased())
        }
        return .object([
            "request_id": .string(requestID),
            "receipt_id": .string(UUID().uuidString.lowercased()),
            "status": .string("completed"),
            "bot_id": .string(botID.value.uuidString.lowercased()),
            "readback": .object(readback),
        ])
    }

    public func dispatchPairedBotRemote(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        if BotTeamGroupService.handles(method) {
            guard let ctx = context, ctx.hostsBotGroupConversations else {
                // Nothing changed: a definite refusal, told apart from a
                // receipt failure by its data.
                throw DefiniteMutationRejection(JSONRPCError(
                    code: -32091,
                    message: "Bot runtime is unavailable.",
                    data: .object(["domain": .string("bot_group"), "kind": .string("runtime_unavailable")])
                ))
            }
            return try await ctx.botTeamGroupService.dispatchRemote(method: method, params: params)
        }
        if method == "bot.conversation.fork" {
            return try await forkPairedBotConversation(params: params)
        }
        let authority = try pairedBotAuthority()
        let foundation = Self.foundationObject(params)
        if botRuntimeEvidenceProjectorExists, Self.pairedBotRunStateReadMethods.contains(method) {
            // Suspends, never blocks: the MainActor stays free while a queued
            // settle waits for SQLite.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                botRuntimeEvidenceProjector.afterQueuedTerminals { continuation.resume() }
            }
        }
        // An observing `bot.guest.state` goes through the observe coordinator,
        // never the plain off-main read.
        let observesGuest = method == "bot.guest.state" && foundation["observe"] as? Bool == true
        if !observesGuest,
           Self.pairedBotOffMainReadMethods.contains(method) || Self.pairedBotOffMainMutationMethods.contains(method) {
            return try await dispatchPairedBotRead(authority: authority, method: method, params: foundation)
        }
        do {
            if observesGuest {
                let observed = try await pairedGuestObserveCoordinator(authority).state(params: foundation)
                return JSONValue.from(observed)
            }
            if Self.pairedBotMainActorReadMethods.contains(method) {
                return JSONValue.from(try authority.dispatch(method: method, params: foundation))
            }
            // `bot_send_ack`: the MainActor turn that acknowledges a paired
            // send, from admitting the run to registering its receipt.
            let signposter = PerfSwitchMetrics.signposter
            let sendAckInterval = method == "bot.send"
                ? signposter.beginInterval("bot_send_ack", id: signposter.makeSignpostID())
                : nil
            defer {
                if let sendAckInterval { signposter.endInterval("bot_send_ack", sendAckInterval) }
            }
            var result = try authority.dispatch(method: method, params: foundation)
            if method == "bot.stop" || method == "bot.force_stop",
               result["status"] as? String == BotRemoteControlAuthority.Status.accepted.rawValue,
               let requestID = foundation["client_request_id"] as? String {
                await waitForPairedBotSettlement(requestID: requestID)
                result = try authority.dispatch(
                    method: "bot.receipt.status",
                    params: ["client_request_id": requestID]
                )
            }
            reloadPairedBotQueue(params: foundation)
            if method == "bot.send" {
                result = enrichPairedBotAssistant(params: foundation, result: result)
            }
            if method == "bot.send" {
                botRuntimeEvidenceProjector.registerCompletedSend(JSONValue.from(result))
            }
            return JSONValue.from(result)
        } catch let error as BotRemoteControlAuthority.Error {
            if let requestID = foundation["client_request_id"] as? String,
               let failed = try? authority.dispatch(
                   method: "bot.receipt.status",
                   params: ["client_request_id": requestID]
               ),
               failed["status"] as? String == BotRemoteControlAuthority.Status.failed.rawValue {
                return JSONValue.from(failed)
            }
            let rejection = JSONRPCError(code: error.code, message: error.message)
            if method == "bot.conversation.enqueue" {
                // Domain errors precede enqueue or follow its transaction rollback.
                throw DefiniteMutationRejection(rejection)
            }
            throw rejection
        }
    }

    /// A write can change only its own bot's persisted queue; reload that bot
    /// (and publish only if its rows changed). Writes that name no bot keep the
    /// fleet-wide reload.
    private func reloadPairedBotQueue(params: [String: Any]) {
        guard let botsViewModel else { return }
        if let raw = params["bot_id"] as? String, let uuid = UUID(uuidString: raw) {
            botsViewModel.reloadQueuedFollowUpsFromStore(botID: BotID(uuid))
        } else {
            botsViewModel.reloadQueuedFollowUpsFromStore()
        }
    }

    private func dispatchPairedBotRead(
        authority: BotRemoteControlAuthority,
        method: String,
        params: [String: Any]
    ) async throws -> JSONValue {
        let request = PairedBotReadRequest(authority: authority, method: method, params: params)
        let outcome: PairedBotReadOutcome = await Task.detached(priority: .userInitiated) {
            do {
                return .value(try request.authority.dispatch(method: request.method, params: request.params))
            } catch {
                return .failure(error)
            }
        }.value
        switch outcome {
        case .value(let result):
            guard method == "bot.get" else { return JSONValue.from(result) }
            return JSONValue.from(enrichPairedBotAssistant(params: params, result: result))
        case .failure(let error as BotRemoteControlAuthority.Error):
            // Same contract as the write path: a request id whose receipt
            // already failed answers with that receipt.
            if let requestID = params["client_request_id"] as? String,
               let failed = try? authority.dispatch(
                   method: "bot.receipt.status",
                   params: ["client_request_id": requestID]
               ),
               failed["status"] as? String == BotRemoteControlAuthority.Status.failed.rawValue {
                return JSONValue.from(failed)
            }
            throw JSONRPCError(code: error.code, message: error.message)
        case .failure(let error):
            throw error
        }
    }

    private func enrichPairedBotAssistant(params: [String: Any], result: [String: Any]) -> [String: Any] {
        let rawID = (params["bot_id"] as? String)
            ?? (result["bot_id"] as? String)
            ?? (result["id"] as? String)
        guard let rawID, let uuid = UUID(uuidString: rawID),
              let reply = botsViewModel?.lastAssistantText(for: BotID(uuid)),
              !reply.isEmpty else {
            return result
        }
        var next = result
        next["last_reply"] = reply
        if var readback = next["readback"] as? [String: Any] {
            if readback["reply"] == nil {
                readback["reply"] = reply
                next["readback"] = readback
            }
        }
        return next
    }

    /// The bot routine scheduler fires through the paired authority, so the
    /// Mac timer and iOS `bot.routine.run` share one executor and one runtime.
    var botRoutineAuthority: BotRemoteControlAuthority? { try? pairedBotAuthority() }

    private func pairedBotAuthority() throws -> BotRemoteControlAuthority {
        if let pairedBotRemote { return pairedBotRemote }
        guard let ctx = context else {
            throw JSONRPCError(code: -32004, message: "The calling session no longer exists.")
        }
        let created = BotRemoteControlAuthority(
            db: ctx.db,
            store: ctx.botStore,
            settings: SettingsStore(db: ctx.db),
            appSupportDirectory: ctx.appSupportDirectory
        )
        created.onVMWorkspaceExists = { [weak self] id in self?.context?.state.workspaces[id] != nil }
        created.onHasLiveRun = { [weak self] id in
            self?.botsViewModel?.hasLiveRun(botID: id) ?? false
        }
        created.onContextBindingChanged = { [weak self] binding in
            guard let self, let ctx = self.context,
                  binding.hostID == ctx.liveActivityHostIdentity.serverId else { return false }
            do {
                let conversations = try ctx.botStore.listConversations(botID: binding.botID, includeGroupMembers: true)
                let threads = try conversations.compactMap { conversation -> AgentThreadID? in
                    guard let threadID = conversation.linkedAgentThreadID,
                          let pin = try ctx.botStore.conversationContextPin(conversationID: conversation.id),
                          pin.hostID == binding.hostID,
                          pin.botID == binding.botID,
                          pin.context == binding.context,
                          (binding.state != .active || pin.policyRevision != binding.policyRevision) else { return nil }
                    return threadID
                }
                for threadID in threads {
                    ctx.coordinator.stopRun(threadId: threadID)
                    try ctx.coordinator.stopDelegatedRunsForThread(threadId: threadID)
                }
                try BotContextGuestResources.requestRevocation(
                    binding: binding, store: ctx.botStore, appSupport: ctx.appSupportDirectory
                )
                return true
            } catch {
                return false
            }
        }
        created.onStopRun = { [weak self] id, conversationID, runID, runRequestID, force, requestID in
            guard let self else { return }
            guard let botsViewModel = self.botsViewModel else {
                self.settlePairedBot(
                    requestID: requestID,
                    ok: false,
                    readback: ["accepted": true, "force": force, "terminal": false]
                )
                return
            }
            botsViewModel.stopLiveRun(
                for: id,
                conversationID: conversationID,
                runID: runID,
                runRequestID: runRequestID,
                force: force
            ) { [weak self] ok in
                self?.settlePairedBot(
                    requestID: requestID,
                    ok: ok,
                    readback: [
                        "accepted": true,
                        "force": force,
                        "terminal": ok,
                    ]
                )
            }
        }
        created.onStartGuest = { [weak self] id, _, requestID, context in
            self?.botsViewModel?.presentGuestDesktop(botID: id) { ready in
                self?.settlePairedGuest(
                    botID: id,
                    requestID: requestID,
                    context: context,
                    ready: ready
                )
            }
        }
        created.onStopGuest = { [weak self] id, requestID, context in
            self?.botsViewModel?.stopDockerGuest(botID: id) { ok in
                var readback = context
                readback["last_request_id"] = requestID
                readback["status"] = ok ? "stopped" : "failed"
                readback["error_message"] = ok ? nil : "Could not stop the Linux desktop."
                self?.settlePairedBot(
                    requestID: requestID,
                    ok: ok,
                    readback: readback
                )
            }
        }
        created.onRebuildGuest = { [weak self] id, requestID, context in
            self?.botsViewModel?.rebuildDockerGuest(botID: id) { ready in
                self?.settlePairedGuest(
                    botID: id,
                    requestID: requestID,
                    context: context,
                    ready: ready
                )
            }
        }
        created.onGuestInput = { [weak self] id, params, requestID, context in
            guard let service = self?.botsViewModel?.computerGuestService else {
                throw BotRemoteControlAuthority.Error(
                    code: -32091,
                    message: "Bot guest input is unavailable."
                )
            }
            let steps = try Self.guestInputSteps(params)
            guard let store = self?.context?.botStore else { throw BotStoreError.notFound }
            let resourceID = try store.guestResourceID(botID: id)
            Task { @MainActor [weak self, service] in
                do {
                    let evidence = try await Task.detached { [service] in
                        try service.act(botID: resourceID, steps: steps)
                        return try service.remoteFrame(botID: resourceID)
                    }.value
                    var readback = Self.guestFrameReadback(context: context, evidence: evidence)
                    readback["last_request_id"] = requestID
                    self?.settlePairedBot(
                        requestID: requestID,
                        ok: true,
                        readback: readback
                    )
                } catch {
                    var readback = Self.guestFailureReadback(context: context, error: error)
                    readback["last_request_id"] = requestID
                    self?.settlePairedBot(
                        requestID: requestID,
                        ok: false,
                        readback: readback
                    )
                }
            }
        }
        created.computerControl = botComputerControl
        created.onGuestControlChanged = { [weak self] id, took in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.syncManualActionsAfterGuestControl(botID: id, took: took) }
            } else {
                Task { @MainActor [weak self] in self?.syncManualActionsAfterGuestControl(botID: id, took: took) }
            }
        }
        created.onDockerClear = { [weak self] id in
            guard let service = self?.botsViewModel?.computerGuestService else {
                throw BotRemoteControlAuthority.Error(
                    code: -32088,
                    message: "Docker home clear failed."
                )
            }
            try service.removeGuestRuntime(botID: id)
        }
        created.onSend = { [weak self] id, text, conversationID, attachmentReferences, routingValues, clientCapabilities in
            guard let self, let vm = self.botsViewModel else {
                throw BotRemoteControlAuthority.Error(
                    code: -32091,
                    message: "Bot runtime is unavailable."
                )
            }
            let routing = try routingValues.map(Self.pairedBotDeskRouting)
            let attachments = try self.resolveInboundAgentAttachments(attachmentReferences)
            // A receipt route becomes the conversation's desk route, unless an
            // older client sent a legacy provider: that route was reset to
            // Distill defaults and runs for this send only, never over the
            // Main/Worker saved on the Mac.
            let result = try vm.enqueueHostMessage(
                botID: id,
                text: text,
                conversationID: conversationID,
                attachments: attachments,
                routing: routing,
                adoptAsDeskRoute: routingValues.map(Self.pairedRouteKeepsItsProvider) ?? false,
                origin: .pairedClient(
                    tapsNoticeCards: clientCapabilities.contains(BotsViewModel.noticeActClientCapability),
                    bindsNoticeReplies: clientCapabilities.contains("bot.notice_reply_v1")
                )
            )
            return Self.foundationObject(result.objectValue ?? [:])
        }
        // Titio notice cards (hub spec §7, §8). `bot.notice.*` dispatch off the
        // MainActor (see `pairedBotOffMainMutationMethods`), so these only
        // touch the hub's thread-safe ledger and in-memory mirrors.
        let noticeCenter = ctx.titioNoticeCenter
        let noticeHostID = ctx.liveActivityHostIdentity.serverId
        created.onNoticeReply = { botID, messageID, text, revision in
            ["outcome": noticeCenter.replyNow(messageID: messageID, text: text, expectedQuestionRevision: revision).wireName,
             "host_id": noticeHostID, "bot_id": botID.value.uuidString.lowercased()]
        }
        created.onNoticeContextualAct = { _, messageID, optionIndex in
            noticeCenter.contextualReply(messageID: messageID, optionIndex: optionIndex)
        }
        created.onNoticeAct = { _, messageID, optionIndex in
            let outcome = noticeCenter.actNow(messageID: messageID, optionIndex: optionIndex)
            var answer: [String: Any] = ["outcome": outcome.wireName]
            if let route = outcome.route { answer["route"] = route }
            return answer
        }
        created.onNoticeRead = { _, conversationID in
            if let inbox = noticeCenter.inboxSnapshot, inbox.conversationID != conversationID {
                throw BotRemoteControlAuthority.Error.invalidParams
            }
            noticeCenter.markInboxRead()
            return ["unread_count": 0]
        }
        created.onNoticeClear = { _, messageID in
            guard case .cleared(let threadID) = noticeCenter.clearNow(messageID: messageID) else {
                throw BotRemoteControlAuthority.Error.invalidParams
            }
            return ["thread_id": threadID.value.uuidString.lowercased()]
        }
        created.onTitioInbox = {
            noticeCenter.inboxSnapshot?.foundationObject
        }
        created.onRoutineSend = { [weak self] routine in
            guard let vm = self?.botsViewModel else {
                throw BotRemoteControlAuthority.Error(
                    code: -32091,
                    message: "Bot runtime is unavailable."
                )
            }
            return Self.foundationObject(try vm.enqueueScheduledRoutine(routine).objectValue ?? [:])
        }
        created.onConversationRoutingSet = { [weak self] id, conversationID, routingValues in
            guard let vm = self?.botsViewModel else {
                throw BotRemoteControlAuthority.Error(
                    code: -32091,
                    message: "Bot runtime is unavailable."
                )
            }
            // A conversation's desk route is never a legacy-provider reset.
            guard Self.pairedRouteKeepsItsProvider(routingValues) else {
                throw BotRemoteControlAuthority.Error.invalidParams
            }
            let routing = try Self.pairedBotDeskRouting(routingValues)
            let adopted = try vm.adoptRemoteDeskRouting(routing, botID: id, conversationID: conversationID)
            return Self.foundationObject(adopted.remoteWireObject)
        }
        created.onConversationRouting = { [weak self] conversation in
            guard let routing = self?.botsViewModel?.effectiveDeskRouting(for: conversation) else {
                return nil
            }
            return Self.foundationObject(routing.remoteWireObject)
        }
        created.onForceQueuedFollowUp = { [weak self] id, itemID in
            guard let vm = self?.botsViewModel else {
                throw BotRemoteControlAuthority.Error(
                    code: -32091,
                    message: "Bot runtime is unavailable."
                )
            }
            return try vm.forceQueuedFollowUpFromStore(botID: id, id: itemID)
        }
        created.onDelegatedAttentionSnapshot = { [weak self] in
            self?.context?.botPeerHandoffAuthority.remoteAttentionOwnershipSnapshots() ?? []
        }
        created.onOpenFile = { [weak self] botID, path, split, root in
            guard let vm = self?.botsViewModel else {
                throw BotRemoteControlAuthority.Error(
                    code: -32089,
                    message: "Bot files surface is unavailable."
                )
            }
            try vm.openRemoteFile(botID: botID, relativePath: path, split: split, root: root)
        }
        created.onImportFile = { [weak self] _, url in
            guard let self else {
                throw BotRemoteControlAuthority.Error(
                    code: -32089,
                    message: "Bot files surface is unavailable."
                )
            }
            return try self.agentAttachmentStore().stage(path: url.path)
        }
        created.notifyBrowserPendingOpen = { [weak self] name in
            DistributedNotificationCenter.default().post(name: name, object: nil)
            _ = try self?.reconcileBotBrowserOpens()
        }
        pairedBotRemote = created
        return created
    }

    private func pairedGuestObserveCoordinator(
        _ authority: BotRemoteControlAuthority
    ) -> BotGuestObserveCoordinator {
        if let pairedGuestObserver { return pairedGuestObserver }
        let created = BotGuestObserveCoordinator(
            authority: authority,
            capture: { [weak self] botID in
                guard let service = self?.botsViewModel?.computerGuestService else {
                    throw BotRemoteControlAuthority.Error(code: -32091, message: "Bot guest is unavailable.")
                }
                guard let store = self?.context?.botStore else { throw BotStoreError.notFound }
                let resourceID = try store.guestResourceID(botID: botID)
                // One screenshot attempt: an observing viewer must not wait out the start retries.
                return try await Task.detached(priority: .userInitiated) { [service] in
                    let evidence = try service.remoteFrame(botID: resourceID, attempts: 1)
                    return BotRemoteControlAuthority.ObservedGuestFrame(
                        containerID: evidence.containerID,
                        viewerPath: evidence.viewerPath,
                        pixelWidth: evidence.pixelWidth,
                        pixelHeight: evidence.pixelHeight,
                        pngBase64: evidence.png.base64EncodedString(),
                        pngHash: evidence.pngHash
                    )
                }.value
            },
            isContainerRunning: { [weak self] botID in
                guard let service = self?.botsViewModel?.computerGuestService else { return false }
                guard let resourceID = try? self?.context?.botStore.guestResourceID(botID: botID) else { return false }
                return await Task.detached(priority: .userInitiated) { [service] in
                    service.isContainerRunning(botID: resourceID)
                }.value
            },
            onStopped: { [weak self] botID, hostID in
                self?.publishGuestObservedStopped(botID: botID, hostID: hostID)
            }
        )
        pairedGuestObserver = created
        return created
    }

    /// `bot.guest.updated` with `reason: "agent_step"` after the bot acted on
    /// its guest, sent only while a paired viewer is watching that bot (it then
    /// re-observes). Carries no frame: the next `bot.guest.state` observe does.
    func publishGuestAgentStep(botID: BotID, step: String) {
        guard let pairedGuestObserver, pairedGuestObserver.isWatching(botID) else { return }
        var payload: [String: JSONValue] = [
            "bot_id": .string(botID.value.uuidString.lowercased()),
            "reason": .string("agent_step"),
            "step": .string(step),
            "frame_stale": .bool(true),
            "controlled_by_user": .bool(botComputerControl.isControlledByUser(botID)),
        ]
        if let hostID = pairedBotRemote?.guestHostID(botID: botID) {
            payload["host_id"] = .string(hostID)
        }
        EventBus.shared.publish(kind: .botGuestUpdated, payload: .object(payload))
    }

    /// An observe saw the watched container gone and ended its grant as
    /// `stopped`: every paired client learns it, not only the one that polled.
    func publishGuestObservedStopped(botID: BotID, hostID: String) {
        EventBus.shared.publish(kind: .botGuestUpdated, payload: .object([
            "bot_id": .string(botID.value.uuidString.lowercased()),
            "host_id": .string(hostID),
            "method": .string("bot.guest.state"),
            "reason": .string("observe_stopped"),
            "status": .string("stopped"),
            "grant_invalidated": .bool(true),
            "controlled_by_user": .bool(botComputerControl.isControlledByUser(botID)),
        ]))
    }

    /// `bot.guest.updated` with `reason: "control"` whenever who drives the
    /// bot's computer changed, from the Mac (card, screen toggle) or a paired device.
    func publishGuestControlChanged(botID: BotID) {
        var payload: [String: JSONValue] = [
            "bot_id": .string(botID.value.uuidString.lowercased()),
            "reason": .string("control"),
            "controlled_by_user": .bool(botComputerControl.isControlledByUser(botID)),
        ]
        if let hostID = pairedBotRemote?.guestHostID(botID: botID) {
            payload["host_id"] = .string(hostID)
        }
        EventBus.shared.publish(kind: .botGuestUpdated, payload: .object(payload))
    }

    /// `bot.guest.control take` also takes the bot's open manual action, as the
    /// Mac card's Take does (never on a thread that runs on the Mac). `release`
    /// hands a taken request back to the bot as `open`, unanswered (the Mac
    /// card's Devolver continues it instead). Every Mac card refreshes its toggle.
    private func syncManualActionsAfterGuestControl(botID: BotID, took: Bool) {
        let threads = context?.threadRepo
        for request in manualActionStore.openByThread().values where request.botID == botID {
            if took, request.state == .open {
                guard let threadID = request.threadID,
                      let thread = try? threads?.get(id: threadID),
                      thread.executionTarget != .mac else { continue }
                if let taken = try? manualActionStore.take(id: request.id, control: botComputerControl) {
                    ManualActionRequestStore.postStateChanged(taken)
                }
            } else if !took, request.state == .taken {
                var reopened = request
                reopened.state = .open
                if (try? manualActionStore.upsert(reopened)) != nil {
                    ManualActionRequestStore.postStateChanged(reopened)
                }
            }
        }
        NotificationCenter.default.post(name: .manualActionStateChanged, object: nil)
    }

    /// Settle after `dispatch` returns. `mutate` overwrites in-flight settle,
    /// and `NSLock` is not recursive.
    private func settlePairedBot(requestID: String, ok: Bool, readback: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let settled = self.pairedBotRemote?.settle(
                requestID: requestID,
                status: ok ? .completed : .failed,
                readback: readback
            )
            if let settled,
               let payload = Self.pairedGuestTerminalEventPayload(settled) {
                EventBus.shared.publish(kind: .botGuestUpdated, payload: payload)
            }
            let waiters = self.pairedBotSettlementWaiters.removeValue(forKey: requestID) ?? []
            waiters.forEach { $0.resume() }
        }
    }

    static func pairedGuestTerminalEventPayload(_ receipt: [String: Any]) -> JSONValue? {
        guard let requestID = receipt["request_id"] as? String, !requestID.isEmpty,
              let receiptID = receipt["receipt_id"] as? String, !receiptID.isEmpty,
              let botID = receipt["bot_id"] as? String, !botID.isEmpty,
              let receiptStatus = receipt["status"] as? String,
              let readback = receipt["readback"] as? [String: Any],
              readback["bot_id"] as? String == botID,
              readback["last_request_id"] as? String == requestID,
              readback["viewer_path"] as? String == "/vnc.html",
              readback["task_catalog"] is [String: Any],
              let hostID = readback["host_id"] as? String, !hostID.isEmpty,
              let status = readback["status"] as? String,
              let generation = readback["grant_generation"] as? Int,
              generation >= 0 else { return nil }
        switch (receiptStatus, status) {
        case (BotRemoteControlAuthority.Status.completed.rawValue, "running"),
             (BotRemoteControlAuthority.Status.completed.rawValue, "stopped"),
             (BotRemoteControlAuthority.Status.failed.rawValue, "failed"):
            break
        default:
            return nil
        }
        let afterFrameID = readback["after_frame_id"] as? String
        if status == "running" {
            guard let afterFrameID, !afterFrameID.isEmpty,
                  let frame = readback["frame"] as? [String: Any],
                  frame["frame_id"] as? String == afterFrameID else { return nil }
        }
        var payload: [String: Any] = [
            "host_id": hostID,
            "bot_id": botID,
            "request_id": requestID,
            "client_request_id": requestID,
            "receipt_id": receiptID,
            "status": status,
            "grant_generation": generation,
        ]
        if let afterFrameID, !afterFrameID.isEmpty {
            payload["after_frame_id"] = afterFrameID
        }
        return JSONValue.from(payload)
    }

    private func waitForPairedBotSettlement(requestID: String) async {
        await withCheckedContinuation { continuation in
            pairedBotSettlementWaiters[requestID, default: []].append(continuation)
        }
    }

    private func settlePairedGuest(
        botID: BotID,
        requestID: String,
        context: [String: Any],
        ready: BotComputerGuestReady?
    ) {
        guard let ready,
              let service = botsViewModel?.computerGuestService else {
            var readback = Self.guestFailureReadback(
                context: context,
                message: "Could not start the Linux desktop."
            )
            readback["last_request_id"] = requestID
            settlePairedBot(
                requestID: requestID,
                ok: false,
                readback: readback
            )
            return
        }
        Task { @MainActor [weak self, service] in
            do {
                guard let resourceID = try self?.context?.botStore.guestResourceID(botID: botID) else { throw BotStoreError.notFound }
                let evidence = try await Task.detached { [service] in
                    try service.remoteFrame(botID: resourceID, ready: ready)
                }.value
                var readback = Self.guestFrameReadback(context: context, evidence: evidence)
                readback["last_request_id"] = requestID
                self?.settlePairedBot(
                    requestID: requestID,
                    ok: true,
                    readback: readback
                )
            } catch {
                var readback = Self.guestFailureReadback(context: context, error: error)
                readback["last_request_id"] = requestID
                self?.settlePairedBot(
                    requestID: requestID,
                    ok: false,
                    readback: readback
                )
            }
        }
    }

    static func guestFrameReadback(
        context: [String: Any],
        evidence: BotComputerGuestFrameEvidence
    ) -> [String: Any] {
        var readback = context
        var runtime = context["runtime"] as? [String: Any] ?? [:]
        runtime["container_id"] = evidence.containerID
        runtime["viewer_path"] = evidence.viewerPath
        let previousFrame = context["frame"] as? [String: Any]
        let sequence = (previousFrame?["sequence"] as? Int ?? -1) + 1
        let frameID = UUID().uuidString.lowercased()
        readback["runtime"] = runtime
        readback["frame"] = [
            "runtime": runtime,
            "frame_id": frameID,
            "sequence": sequence,
            "pixel_width": evidence.pixelWidth,
            "pixel_height": evidence.pixelHeight,
            "png_base64": evidence.png.base64EncodedString(),
            "png_hash": evidence.pngHash,
        ]
        readback["status"] = "running"
        readback["viewer"] = evidence.viewerPath
        readback["viewer_path"] = evidence.viewerPath
        readback["grant_generation"] = runtime["grant_generation"]
        readback["grant_invalidated"] = false
        readback["before_frame_id"] = previousFrame?["frame_id"]
        readback["after_frame_id"] = frameID
        readback["error_message"] = nil
        return readback
    }

    static func guestFailureReadback(
        context: [String: Any],
        error: Swift.Error
    ) -> [String: Any] {
        guestFailureReadback(context: context, message: String(describing: error))
    }

    static func guestFailureReadback(
        context: [String: Any],
        message: String
    ) -> [String: Any] {
        var readback = context
        let previousGeneration = (context["runtime"] as? [String: Any])?["grant_generation"] as? Int
            ?? context["grant_generation"] as? Int
            ?? 0
        readback["status"] = "failed"
        readback["error_message"] = message
        readback["runtime"] = nil
        readback["frame"] = nil
        readback["input"] = nil
        readback["grant_generation"] = previousGeneration + 1
        readback["grant_invalidated"] = true
        readback["recovery"] = [
            "method": "bot.guest.state",
            "requires_new_start_grant": true,
        ]
        return readback
    }

    static func guestInputSteps(_ params: [String: Any]) throws -> [BotComputerActStep] {
        if let input = params["input"] as? [String: Any],
            let kind = input["kind"] as? String {
            switch kind {
            case "pointer":
                guard let x = Self.integralGuestCoordinate(input["x"]),
                      let y = Self.integralGuestCoordinate(input["y"]) else {
                    throw BotRemoteControlAuthority.Error.invalidParams
                }
                return [BotComputerActStep(action: "click", x: x, y: y)]
            case "drag":
                guard let fromX = Self.integralGuestCoordinate(input["from_x"]),
                      let fromY = Self.integralGuestCoordinate(input["from_y"]),
                      let toX = Self.integralGuestCoordinate(input["to_x"]),
                      let toY = Self.integralGuestCoordinate(input["to_y"]) else {
                    throw BotRemoteControlAuthority.Error.invalidParams
                }
                return [BotComputerActStep(action: "drag", x: fromX, y: fromY, toX: toX, toY: toY)]
            case "text":
                guard let text = input["text"] as? String else {
                    throw BotRemoteControlAuthority.Error.invalidParams
                }
                return [BotComputerActStep(action: "type", text: text)]
            case "key":
                guard let key = input["key"] as? String else {
                    throw BotRemoteControlAuthority.Error.invalidParams
                }
                return [BotComputerActStep(action: "key", key: key)]
            default:
                throw BotRemoteControlAuthority.Error.invalidParams
            }
        }
        if let raw = params["steps"] as? [[String: Any]] {
            let steps = raw.map { dict in
                BotComputerActStep(
                    action: dict["action"] as? String ?? "",
                    x: Self.integralGuestCoordinate(dict["x"]),
                    y: Self.integralGuestCoordinate(dict["y"]),
                    text: dict["text"] as? String,
                    key: dict["key"] as? String
                )
            }
            try BotComputerGuestObserve.assertActStepCount(steps.count)
            return steps
        }
        if let text = params["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [BotComputerActStep(action: "type", text: text)]
        }
        if let key = params["key"] as? String, !key.isEmpty {
            return [BotComputerActStep(action: "key", key: key)]
        }
        if let x = Self.integralGuestCoordinate(params["x"]),
           let y = Self.integralGuestCoordinate(params["y"]) {
            return [BotComputerActStep(action: "click", x: x, y: y)]
        }
        throw BotRemoteControlAuthority.Error.invalidParams
    }

    private static func integralGuestCoordinate(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              let value = Int(exactly: number.doubleValue) else {
            return nil
        }
        return value
    }

    /// False when the paired route names a provider RemoteCode no longer
    /// runs; `BotDeskRouting` resets such a route to Distill defaults.
    private static func pairedRouteKeepsItsProvider(_ values: [String: Any]) -> Bool {
        (values["provider"] as? String).flatMap(AgentProvider.init(rawValue:))?.isSelectable == true
    }

    private static func pairedBotDeskRouting(
        _ values: [String: Any]
    ) throws -> BotDeskRouting {
        guard let providerRaw = values["provider"] as? String,
              let provider = AgentProvider(rawValue: providerRaw),
              let providerInstanceID = values["provider_instance_id"] as? String,
              !providerInstanceID.isEmpty,
              let routingRaw = values["routing_mode"] as? String,
              let routingMode = AgentRoutingMode(rawValue: routingRaw),
              let permissionRaw = values["permission_mode"] as? String,
              let permissionMode = AgentPermissionMode(rawValue: permissionRaw),
              let reasoningRaw = values["reasoning_effort"] as? String,
              let reasoningEffort = AgentReasoningEffort(rawValue: reasoningRaw),
              let runAsObject = values["run_as_user"],
              JSONSerialization.isValidJSONObject(runAsObject),
              let runAsData = try? JSONSerialization.data(withJSONObject: runAsObject),
              let runAsUser = try? JSONDecoder().decode(AgentRunAsUser.self, from: runAsData)
        else {
            throw BotRemoteControlAuthority.Error.invalidParams
        }
        var routing = BotDeskRouting(
            provider: provider,
            providerInstanceID: providerInstanceID,
            model: values["model"] as? String ?? "",
            routingMode: routingMode,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: (values["service_tier"] as? String)
                .flatMap(AgentServiceTier.init(rawValue:)) ?? .auto,
            runAsUser: runAsUser
        )
        // Only a Distill route carries a Worker; a legacy route was already
        // reset to Distill defaults by the initializer.
        if routing.provider == provider {
            do {
                try routing.applyRemoteWorkerFields(values)
            } catch {
                throw BotRemoteControlAuthority.Error.invalidParams
            }
        }
        return routing
    }

    private static func foundationObject(_ params: [String: JSONValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in params {
            out[key] = foundationValue(value)
        }
        return out
    }

    private static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .number(let number): return number
        case .string(let text): return text
        case .array(let items): return items.map(foundationValue)
        case .object(let object):
            var nested: [String: Any] = [:]
            for (key, nestedValue) in object {
                nested[key] = foundationValue(nestedValue)
            }
            return nested
        }
    }

    public func viewHostBotSkill(
        botID: BotID,
        skillID: String,
        callerRun: AgentRunID,
        callerThread: AgentThreadID
    ) throws -> JSONValue {
        let target = try authorizedHostSkillBot(botID: botID, callerRun: callerRun, callerThread: callerThread)
        guard let ctx = context else { throw JSONRPCError(code: -32004, message: "The calling Agent thread no longer exists.") }
        let environment = [
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": ctx.appSupportDirectory.path,
            BotSelfConfigCatalog.callerEnvironmentKey: target.value.uuidString.lowercased(),
        ]
        let service = try BotSelfConfigService.make(environment: environment, store: ctx.botStore)
        return JSONValue.from(try service.viewSkill(skillID: skillID))
    }

    private func authorizedHostSkillBot(
        botID: BotID,
        callerRun: AgentRunID,
        callerThread: AgentThreadID
    ) throws -> BotID {
        if let context,
           let conversation = try context.botStore.conversationLinked(to: callerThread),
           conversation.botID == botID {
            return botID
        }
        if hostCatalogCreatedBots[callerRun]?.contains(botID) == true {
            return botID
        }
        if let context,
           let delegatedID = context.botPeerHandoffAuthority.delegatedBotID(
               forHostRunID: callerRun,
               requestedBotID: botID
           ) {
            return delegatedID
        }
        throw JSONRPCError(
            code: -32046,
            message: "This active run has no matching Bot grant."
        )
    }

    private nonisolated static func hostBotJSON(_ bot: BotDefinition) -> JSONValue {
        .object([
            "id": .string(bot.id.value.uuidString.lowercased()),
            "handle": .string(bot.handle),
            "name": .string(bot.name),
            "title": .string(bot.title),
        ])
    }

    private nonisolated static func botPeerFoundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(botPeerFoundationValue)
        case .object(let values): return values.mapValues(botPeerFoundationValue)
        }
    }

    #if DEBUG
    /// Legacy handoff lifecycle seam for the existing authority regression
    /// suite. Product sends never call this; provider tool calls use
    /// `askBotPeer` with an AI-authored prompt.
    func dispatchAgentAppBotMentions(
        peers: [BotDefinition],
        text: String,
        threadId: AgentThreadID,
        onto agent: AgentAppSurface?,
        continueHost: Bool
    ) async {
        guard let agent,
              let ctx = context,
              let originThread = try? ctx.threadRepo.get(id: threadId) else { return }
        lastAgentAppHopTextForTesting = nil
        ctx.botPeerHandoffAuthority.router = self
        let providerSnapshots = cachedProviderSnapshotsForSend()
        var dispatchMilestones: [Task<Void, Never>] = []
        for peer in peers {
            guard let activityID = agent.viewModel.presentBotPeerActivity(
                peer: peer,
                phase: .waiting,
                threadId: threadId
            ) else { continue }
            if let milestone = ctx.botPeerHandoffAuthority.submitAgentAppMention(
                peer: peer,
                text: text,
                peerText: text,
                originThread: originThread,
                activityID: activityID,
                hostRunID: continueHost ? AgentRunID() : nil,
                providerSnapshots: providerSnapshots,
                resumeHostAfterPeer: continueHost
            ) {
                dispatchMilestones.append(milestone)
            }
        }
        for milestone in dispatchMilestones {
            await milestone.value
        }
    }
    #endif

    func recordAgentAppHop(_ hop: String) {
        lastAgentAppHopTextForTesting = hop
    }

    func agentAppThreadIsSelected(_ threadID: AgentThreadID) -> Bool {
        SurfaceRegistry.shared.all().contains { surface in
            guard let agent = surface as? AgentAppSurface else { return false }
            return agent.viewModel.selectedThreadId == threadID
        }
    }

    func projectAgentAppPeerMessage(
        threadID: AgentThreadID,
        messageID: AgentMessageID,
        terminalStatus: AgentRunStatus? = nil
    ) {
        botsViewModel?.applyDeskPeerMessage(
            messageID: messageID,
            threadID: threadID,
            terminalStatus: terminalStatus
        )
        for surface in SurfaceRegistry.shared.all() {
            guard let agent = surface as? AgentAppSurface else { continue }
            agent.viewModel.applyPersistedBotPeerMessage(
                messageID: messageID,
                threadId: threadID,
                terminalStatus: terminalStatus
            )
        }
    }

    func wireQueueDrainControl(on viewModel: AgentAppViewModel, context: AppContext) {
        wireDistillLoops(on: viewModel, context: context)
        viewModel.forceQueuedMessage = { [weak context] messageID in
            guard let router = context?.router else {
                throw JSONRPCError(code: -32000, message: "App router is not ready.")
            }
            return try await router.forceAgentQueuedMessageNow(id: messageID)
        }
        viewModel.acquireQueueDrainSuppression = { [weak context] threadID in
            guard let context else { return UUID() }
            return await context.acquireQueueDrainSuppression(threadId: threadID)
        }
        viewModel.acquireQueueDrainSuppressions = { [weak context] threadIDs in
            guard let context else { return [] }
            return await context.acquireQueueDrainSuppressions(threadIds: threadIDs)
        }
        viewModel.releaseQueueDrainSuppression = { [weak context] threadID, lease in
            context?.releaseQueueDrainSuppression(threadId: threadID, lease: lease)
        }
    }

    private func wireBotPeerHandoffDeletion(on viewModel: AgentAppViewModel, context: AppContext) {
        viewModel.beginBotPeerHandoffDeletion = { [weak context] threadIDs in
            context?.botPeerHandoffAuthority.beginDeletion(threadIDs: threadIDs) ?? UUID()
        }
        viewModel.finishBotPeerHandoffDeletion = { [weak context] token, sourceDeleted in
            guard let authority = context?.botPeerHandoffAuthority else { return }
            if sourceDeleted {
                _ = authority.commitDeletion(token)
            } else {
                authority.rollbackDeletion(token)
            }
        }
    }

    public func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier = .auto, modelSelection: AgentModelSelection? = nil, providerInstanceId: String? = nil, runAsUser: AgentRunAsUser? = nil, surfaceID: SurfaceID? = nil) throws -> AgentThread {
        try createAgentThread(
            workspace: workspace,
            title: title,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            modelSelection: modelSelection,
            providerInstanceId: providerInstanceId,
            runAsUser: runAsUser,
            surfaceID: surfaceID,
            routingConfiguration: nil,
            quiet: false
        )
    }

    private func validatedNestedParent(
        _ nestedRunContext: AgentNestedRunContext,
        requestedWorkspace: WorkspaceID?,
        requestedPermissionMode: AgentPermissionMode
    ) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let persistedRunIsActive: Bool
        if let parentThreadId = try ctx.runRepo.threadId(of: nestedRunContext.parentRunID) {
            let parentStatus = try ctx.runRepo.status(of: nestedRunContext.parentRunID)
            persistedRunIsActive = parentThreadId == nestedRunContext.parentThreadID
                && (parentStatus == .pending || parentStatus == .running)
        } else {
            persistedRunIsActive = true
        }
        let parentReceipt = try ctx.orchestrationRuntime.activeReceipt(
            runId: nestedRunContext.parentRunID,
            threadId: nestedRunContext.parentThreadID,
            delegationCapability: nestedRunContext.parentCapability
        )
        guard let parentReceipt,
              persistedRunIsActive,
              let parentThread = try ctx.threadRepo.get(id: nestedRunContext.parentThreadID),
              requestedWorkspace == nil || requestedWorkspace == parentThread.workspaceId else {
            throw JSONRPCError(
                code: -32020,
                message: "Nested Agent App parent is not active in this workspace.",
                data: .object([
                    "domain": .string("orchestration"),
                    "kind": .string("invalid_parent")
                ])
            )
        }
        let parentEffectiveUID = parentThread.runAsUser?.uid ?? getuid()
        guard parentEffectiveUID == getuid() else {
            throw JSONRPCError(
                code: -32020,
                message: "Nested Agent App cannot cross the host IPC user boundary.",
                data: .object([
                    "domain": .string("orchestration"),
                    "kind": .string("cross_user_parent")
                ])
            )
        }
        guard Self.permissionRank(requestedPermissionMode)
                <= Self.permissionRank(parentReceipt.permissionMode) else {
            throw JSONRPCError(
                code: -32020,
                message: "Child permission mode exceeds the parent.",
                data: .object([
                    "domain": .string("orchestration"),
                    "kind": .string("invalid_child_admission")
                ])
            )
        }
        return parentThread
    }

    private static func permissionRank(_ mode: AgentPermissionMode) -> Int {
        switch mode {
        case .supervised: return 0
        case .autoAcceptEdits: return 1
        case .fullAccess: return 2
        }
    }

    /// Path B / scheduled: same create as Agent App, optional Auto routing config persisted
    /// so `startRun` admits through the shared orchestration path.
    ///
    /// - Parameter quiet: when true (scheduled headless fires), skip rail select and
    ///   `refreshFromState` so automatic work does not rebuild workspace UI or steal focus.
    ///   Still persists the thread and publishes `agent.thread.created`.
    public func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, reasoningModel: String? = nil, serviceTier: AgentServiceTier = .auto, modelSelection: AgentModelSelection? = nil, providerInstanceId: String? = nil, runAsUser: AgentRunAsUser? = nil, surfaceID: SurfaceID? = nil, routingConfiguration: AgentRoutingConfiguration?, quiet: Bool = false, inheriting parentThread: AgentThread? = nil) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let resolvedWorkspace = parentThread?.workspaceId ?? workspace
        let resolvedRunAs: AgentRunAsUser?
        if let parentThread {
            resolvedRunAs = parentThread.runAsUser
        } else {
            resolvedRunAs = resolveRunAsUser(runAsUser)
        }
        let t = AgentThread(projectId: parentThread?.projectId,
                            workspaceId: resolvedWorkspace,
                            title: title,
                            provider: provider,
                            providerInstanceId: normalizedProviderInstanceId(provider: provider, requested: providerInstanceId),
                            model: model,
                            permissionMode: permissionMode, reasoningEffort: reasoningEffort,
                            reasoningModel: reasoningModel ?? parentThread?.reasoningModel,
                            executionMode: parentThread?.executionMode ?? .local,
                            baseBranch: parentThread?.baseBranch,
                            worktreePath: parentThread?.worktreePath,
                            serviceTier: serviceTier,
                            modelSelection: modelSelection ?? AgentModelSelection(provider: provider, modelId: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier),
                            runAsUser: resolvedRunAs,
                            routingConfiguration: routingConfiguration)
        let prunedThreadIDs = try ctx.threadRepo.upsertEnforcingWorkspaceThreadLimit(t)
        // Apply/publish victims before any fallible surface reload or selection.
        ctx.retireDeletedAgentThreads(prunedThreadIDs)
        if !prunedThreadIDs.isEmpty {
            publishAgentThreadLifecycle(.deleted(prunedThreadIDs))
        }
        if !quiet {
            // Only bind/select the new thread on the requesting surface (if any).
            // Without a surfaceID this just refreshes rails — a thread created from
            // one client no longer hijacks every other open agent tab.
            try selectAgentThread(thread: t.id, surfaceID: surfaceID)
        }
        // After rails reload: broadcast create so iOS mirrors and any EventBus
        // subscribers (including Agent App surfaces that listen for thread.*)
        // see scheduled / RPC-created threads immediately.
        EventBus.shared.publish(kind: .agentThreadCreated, payload: agentThreadPayload(t))
        return t
    }

    /// Builds a fork/side child from the source thread WITHOUT persisting it: the
    /// coordinator's durable fork persists the child graph atomically.
    private func makeForkChild(source: AgentThread, ephemeral: Bool, title: String) -> AgentThread {
        AgentThread(
            projectId: source.projectId,
            workspaceId: source.workspaceId,
            title: title,
            provider: source.provider,
            providerInstanceId: source.providerInstanceId,
            model: source.model,
            permissionMode: source.permissionMode,
            reasoningEffort: source.reasoningEffort,
            reasoningModel: source.reasoningModel,
            executionMode: source.executionMode,
            baseBranch: source.baseBranch,
            worktreePath: source.worktreePath,
            serviceTier: source.serviceTier,
            modelSelection: source.modelSelection,
            runAsUser: source.runAsUser,
            routingConfiguration: source.routingConfiguration,
            parentThreadId: source.id,
            isEphemeral: ephemeral
        )
    }

    /// Durable provider fork of a thread into a persisted child (`agent.thread.fork`).
    public func forkAgentThread(sourceThreadId: AgentThreadID, messageID: String?) async throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try Self.refuseContextPinnedGenericExecution(sourceThreadId, context: ctx)
        guard let source = try ctx.threadRepo.get(id: sourceThreadId) else {
            throw LayoutError.workspaceNotFound
        }
        let child = makeForkChild(source: source, ephemeral: false, title: source.title)
        let forked: AgentThread
        do {
            forked = try await ctx.coordinator.forkThread(sourceThreadId: sourceThreadId, childThread: child)
        } catch AgentThreadForkPersistenceError.recoverableIntentExists {
            // An earlier fork of this thread was interrupted (a crash, a
            // provider timeout). Finish it now in the background, the way
            // launch recovery would, and say so instead of an opaque error.
            let coordinator = ctx.coordinator
            Task { await coordinator.reconcileForkIntentsOnLaunch() }
            throw AgentProviderAdapterError.forkRejected(
                "an earlier fork of this thread is still finishing; it will appear in the list shortly"
            )
        }
        EventBus.shared.publish(kind: .agentThreadCreated, payload: agentThreadPayload(forked))
        return forked
    }

    /// Ephemeral fork of a thread (`agent.thread.side`). Hidden from the rail and swept at launch.
    public func sideAgentThread(sourceThreadId: AgentThreadID, text: String?) async throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try Self.refuseContextPinnedGenericExecution(sourceThreadId, context: ctx)
        guard let source = try ctx.threadRepo.get(id: sourceThreadId) else {
            throw LayoutError.workspaceNotFound
        }
        let child = makeForkChild(source: source, ephemeral: true, title: "Side · \(source.title)")
        return try await ctx.coordinator.forkThread(sourceThreadId: sourceThreadId, childThread: child)
    }

    /// Closes an ephemeral side thread (`agent.thread.side.close`).
    public func closeSideThread(threadId: AgentThreadID) async throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try await ctx.coordinator.closeSideThread(threadId: threadId)
    }

    /// Side question against a live thread session (`agent.thread.btw`).
    public func btwAgentThread(threadId: AgentThreadID, question: String) async throws -> String {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try await ctx.coordinator.btwThread(threadId: threadId, question: question)
    }

    public func createAgentThreadRouting(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?, surfaceID: SurfaceID?, routing: AgentRoutingRequest?, nestedRunContext: AgentNestedRunContext? = nil) async throws -> AgentThread {
        let parentThread = try nestedRunContext.map {
            try validatedNestedParent(
                $0,
                requestedWorkspace: workspace,
                requestedPermissionMode: permissionMode
            )
        }
        guard let routing else {
            // Nested orchestrate workers inherit the controller's workspace/user
            // scope but must NOT steal Agent App selection. The controller stays
            // selected so the Subagents badge on the parent is the live chrome
            // for every delegated worker (user rule: orchestrated agents always
            // appear as subagents under the orchestrator thread).
            return try createAgentThread(
                workspace: workspace,
                title: title,
                provider: provider,
                model: model,
                permissionMode: permissionMode,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier,
                modelSelection: modelSelection,
                providerInstanceId: providerInstanceId,
                runAsUser: runAsUser,
                surfaceID: surfaceID,
                routingConfiguration: nil,
                quiet: parentThread != nil,
                inheriting: parentThread
            )
        }
        guard let ctx = context, let manualSelection = routing.manualSelection else {
            throw JSONRPCError.invalidParams
        }
        let manualInstance = normalizedProviderInstanceId(
            provider: manualSelection.provider,
            requested: providerInstanceId
        )
        let current = AgentRoutingConfiguration.legacyManual(
            selection: manualSelection,
            providerInstanceId: manualInstance
        )
        let resolvedRouting = try await resolveAgentRouting(
            routing,
            current: current,
            manualSelection: manualSelection,
            manualProviderInstanceId: manualInstance
        )
        let resolvedWorkspace = parentThread?.workspaceId ?? workspace
        let resolvedRunAs: AgentRunAsUser?
        if let parentThread {
            resolvedRunAs = parentThread.runAsUser
        } else {
            resolvedRunAs = resolveRunAsUser(runAsUser)
        }
        let thread = AgentThread(
            projectId: parentThread?.projectId,
            workspaceId: resolvedWorkspace,
            title: title,
            provider: manualSelection.provider,
            providerInstanceId: manualInstance,
            model: manualSelection.effectiveModel,
            permissionMode: permissionMode,
            reasoningEffort: manualSelection.reasoningEffort,
            executionMode: parentThread?.executionMode ?? .local,
            baseBranch: parentThread?.baseBranch,
            worktreePath: parentThread?.worktreePath,
            serviceTier: manualSelection.serviceTier,
            modelSelection: manualSelection,
            runAsUser: resolvedRunAs,
            routingConfiguration: resolvedRouting
        )
        let prunedThreadIDs = try ctx.threadRepo.upsertEnforcingWorkspaceThreadLimit(thread)
        ctx.retireDeletedAgentThreads(prunedThreadIDs)
        if !prunedThreadIDs.isEmpty {
            publishAgentThreadLifecycle(.deleted(prunedThreadIDs))
        }
        if parentThread == nil {
            try selectAgentThread(thread: thread.id, surfaceID: surfaceID)
        } else {
            // Nested orchestrate worker: keep the controller selected so the
            // parent's Subagents surface owns live activity for this child.
            EventBus.shared.publish(kind: .agentThreadCreated, payload: agentThreadPayload(thread))
        }
        return thread
    }

    private func resolveAgentRouting(
        _ request: AgentRoutingRequest,
        current: AgentRoutingConfiguration,
        manualSelection: AgentModelSelection,
        manualProviderInstanceId: String?
    ) async throws -> AgentRoutingConfiguration {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        var base = current
        base.manualSelection = manualSelection
        base.manualProviderInstanceId = manualProviderInstanceId
        if let eligibleProviders = request.eligibleProviders {
            base.eligibleProviders = eligibleProviders
        }
        if let policyDigest = request.policyDigest {
            base.policyDigest = policyDigest
        }
        let runtime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: ctx.db),
            costEstimator: AgentOrchestrationRuntime.productionCostEstimator
        )
        switch request.mode {
        case .auto:
            if let policyDigest = request.policyDigest,
               !policyDigest.isEmpty,
               policyDigest != runtime.policyDigest {
                throw AgentOrchestrationAdmissionError.invalidPolicy
            }
            return try runtime.autoConfiguration(
                replacing: base,
                expectedRevision: request.expectedRevision,
                manualSelection: manualSelection,
                manualProviderInstanceId: manualProviderInstanceId,
                providerSnapshots: await listAgentProviderSnapshots()
            )
        case .manual:
            return try runtime.manualConfiguration(
                replacing: base,
                expectedRevision: request.expectedRevision
            )
        }
    }

    public func listAgentRunAsUsers() throws -> [AgentRunAsUser] {
        MacOSLocalUserCatalog.listEligibleUsers()
    }

    private func resolveRunAsUser(_ requested: AgentRunAsUser?) -> AgentRunAsUser? {
        guard let requested else { return AgentRunAsUser.current() }
        if let live = MacOSLocalUserCatalog.resolve(shortName: requested.shortName) {
            return live
        }
        if let live = MacOSLocalUserCatalog.resolve(
            generatedUID: requested.generatedUID,
            shortNameSnapshot: requested.shortName
        ) {
            return live
        }
        return requested
    }

    public func configureAgentThread(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier? = nil, modelSelection: AgentModelSelection? = nil, providerInstanceId: String? = nil, runAsUser: AgentRunAsUser? = nil) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard var t = try ctx.threadRepo.threadWithoutRouting(of: thread) else { throw LayoutError.workspaceNotFound }
        let before = t
        // Started lock is only for provider/instance/run-as-user mutations.
        // Typical send still calls configure with matching picker values; a
        // leftover `listRecent` hitchs MainActor SQLite (full latest body +
        // attachments JSON) on every no-op. Existence is `hasAny`.
        var startedMemo: Bool?
        func threadHasStarted() -> Bool {
            if let startedMemo { return startedMemo }
            let value = (try? ctx.messageRepo.hasAny(threadId: thread)) ?? false
            startedMemo = value
            return value
        }
        if let provider, provider != t.provider {
            // A1 (iOS+macOS parity): the provider is fixed once the
            // thread has a conversation. Only model/effort stay
            // changeable after that. Enforced host-side so no client
            // can bypass the UI lock.
            guard !threadHasStarted() else {
                throw JSONRPCError(code: -32010,
                    message: "Provider is locked once the thread has started; only model and effort can change.")
            }
            t.provider = provider
            t.providerInstanceId = normalizedProviderInstanceId(provider: provider, requested: providerInstanceId)
            t.providerThreadId = nil
        } else if let providerInstanceId {
            let normalized = normalizedProviderInstanceId(provider: t.provider, requested: providerInstanceId)
            if normalized != t.providerInstanceId {
                guard !threadHasStarted() else {
                    throw JSONRPCError(code: -32013,
                        message: "Provider instance is locked once the thread has started.")
                }
                t.providerInstanceId = normalized
                t.providerThreadId = nil
            }
        }
        if let runAsUser {
            let resolved = resolveRunAsUser(runAsUser)
            if resolved?.uid != t.runAsUser?.uid || resolved?.shortName != t.runAsUser?.shortName {
                guard !threadHasStarted() else {
                    throw JSONRPCError(code: -32014,
                        message: "macOS run-as user is locked once the thread has started.")
                }
                t.runAsUser = resolved
            }
        }
        if let model, model != t.model {
            let canSwitchModelInSession = t.provider == .claude && t.providerThreadId?.isEmpty == false
            t.model = model
            if !canSwitchModelInSession {
                t.providerThreadId = nil
            }
        }
        if let permissionMode {
            t.permissionMode = permissionMode
        }
        if let reasoningEffort {
            t.reasoningEffort = reasoningEffort
        }
        if let serviceTier {
            t.serviceTier = serviceTier
        }
        let persistedCustomModel = t.modelSelection.customModelId == t.model ? t.modelSelection.customModelId : nil
        t.modelSelection = modelSelection ?? AgentModelSelection(
            provider: t.provider,
            modelId: t.model,
            customModelId: persistedCustomModel,
            reasoningEffort: t.reasoningEffort,
            serviceTier: t.serviceTier
        )
        // Picker/permission/run-as-user only. A leftover full-row `upsert`
        // hitchs every send and rewrites routing JSON even when nothing
        // changed except `updatedAt`.
        if Self.threadConfigUnchanged(before, t) {
            return before
        }
        // Picker chrome only. A leftover 26-column upsert hitchs iOS/macOS
        // picker mutations and rewrites title/status/unread/color/pin/routing.
        let now = Date()
        guard try ctx.threadRepo.setPickerConfig(
            of: thread,
            provider: t.provider,
            providerInstanceId: t.providerInstanceId ?? t.provider.rawValue,
            runAsUser: t.runAsUser,
            model: t.model,
            permissionMode: t.permissionMode,
            reasoningEffort: t.reasoningEffort,
            serviceTier: t.serviceTier,
            modelSelection: t.modelSelection,
            interactionMode: t.effectiveInteractionMode,
            reasoningModel: t.reasoningModel,
            at: now
        ) else {
            throw LayoutError.workspaceNotFound
        }
        if before.providerThreadId != t.providerThreadId {
            try ctx.threadRepo.updateProviderThreadId(
                id: thread,
                providerThreadId: t.providerThreadId,
                at: now
            )
        }
        // A thread locked to a bot before its first send (agent.thread.actor.set)
        // gets its provider here: its guest marker follows, as at the lock.
        if before.actorLockedAt != nil, before.provider != t.provider || before.runAsUser != t.runAsUser {
            try AgentAppViewModel.resyncGuestRuntimeMarker(
                threadID: thread, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo
            )
        }
        t.updatedAt = now
        t.routingConfiguration = try ctx.threadRepo.routingConfiguration(of: thread)
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == t.workspaceId else { continue }
            if agent.viewModel.selectedThreadId == thread {
                if let provider { agent.viewModel.provider = provider }
                if let model { agent.viewModel.model = model }
                if let permissionMode { agent.viewModel.permissionMode = permissionMode }
                if let reasoningEffort { agent.viewModel.reasoningEffort = reasoningEffort }
                if let serviceTier { agent.viewModel.serviceTier = serviceTier }
                if let runAsUser = t.runAsUser { agent.viewModel.runAsUser = runAsUser }
            }
        }
        if let wid = t.workspaceId {
            AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: wid)
        }
        windowController?.refreshFromState()
        return t
    }

    nonisolated static func threadConfigUnchanged(_ before: AgentThread, _ after: AgentThread) -> Bool {
        before.provider == after.provider
            && before.providerInstanceId == after.providerInstanceId
            && before.providerThreadId == after.providerThreadId
            && before.model == after.model
            && before.permissionMode == after.permissionMode
            && before.reasoningEffort == after.reasoningEffort
            && before.serviceTier == after.serviceTier
            && before.modelSelection == after.modelSelection
            && before.runAsUser == after.runAsUser
    }

    public func configureAgentThreadRouting(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?, providerInstanceId: String?, runAsUser: AgentRunAsUser?, routing: AgentRoutingRequest?) async throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        // Routing chrome only. A leftover 26-column `get` before configure
        // and another `get` after CAS hitch Auto toggle / iOS routing RPC.
        let storedRouting = try ctx.threadRepo.routingConfiguration(of: thread)
        guard let routing else {
            guard storedRouting == nil else {
                throw AgentRoutingRevisionError.conflict(
                    expected: 0,
                    actual: storedRouting?.revision ?? 0
                )
            }
            return try configureAgentThread(thread: thread, provider: provider, model: model, permissionMode: permissionMode, reasoningEffort: reasoningEffort, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId, runAsUser: runAsUser)
        }
        guard let manualSelection = routing.manualSelection else {
            throw JSONRPCError.invalidParams
        }
        let currentEffective: AgentRoutingConfiguration
        if let storedRouting {
            currentEffective = storedRouting
        } else {
            guard let picker = try ctx.threadRepo.threadWithoutRouting(of: thread) else {
                throw LayoutError.workspaceNotFound
            }
            currentEffective = picker.effectiveRoutingConfiguration
        }
        let manualInstance = normalizedProviderInstanceId(
            provider: manualSelection.provider,
            requested: providerInstanceId ?? currentEffective.manualProviderInstanceId
        )
        let resolvedRouting = try await resolveAgentRouting(
            routing,
            current: currentEffective,
            manualSelection: manualSelection,
            manualProviderInstanceId: manualInstance
        )
        var updated = try configureAgentThread(
            thread: thread,
            provider: manualSelection.provider,
            model: manualSelection.effectiveModel,
            permissionMode: permissionMode,
            reasoningEffort: manualSelection.reasoningEffort,
            serviceTier: manualSelection.serviceTier,
            modelSelection: manualSelection,
            providerInstanceId: manualInstance,
            runAsUser: runAsUser
        )
        try ctx.threadRepo.setRoutingConfiguration(
            resolvedRouting,
            threadId: thread,
            expectedRevision: routing.expectedRevision
        )
        updated.routingConfiguration = resolvedRouting
        updated.updatedAt = resolvedRouting.updatedAt
        refreshAgentSurfaces(thread: thread, workspace: updated.workspaceId)
        return updated
    }

    public func configureAgentThreadExecution(thread: AgentThreadID, executionMode: AgentExecutionMode, baseBranch: String?) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        // Execution chrome only. A leftover 26-column + routing `get` then
        // full-row `upsert` hitchs iOS/macOS mode switches and rewrites routing.
        guard var t = try ctx.threadRepo.threadWithoutRouting(of: thread) else { throw LayoutError.workspaceNotFound }
        let started = (try? ctx.messageRepo.hasAny(threadId: thread)) ?? false
        guard !started else {
            throw JSONRPCError(code: -32011, message: "Execution mode is locked once the thread has started.")
        }
        let nextBranch: String?
        if executionMode == .worktree {
            let branch = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !branch.isEmpty else {
                throw JSONRPCError(code: -32012, message: "Worktree mode requires a base branch before the first agent prompt.")
            }
            nextBranch = branch
        } else {
            nextBranch = nil
        }
        let nextPath = executionMode == .local ? nil : t.worktreePath
        if t.executionMode == executionMode, t.baseBranch == nextBranch, t.worktreePath == nextPath {
            t.routingConfiguration = try ctx.threadRepo.routingConfiguration(of: thread)
            return t
        }
        let now = Date()
        guard try ctx.threadRepo.setExecutionConfig(
            of: thread,
            executionMode: executionMode,
            baseBranch: nextBranch,
            at: now
        ) else {
            throw LayoutError.workspaceNotFound
        }
        t.executionMode = executionMode
        t.baseBranch = nextBranch
        t.worktreePath = nextPath
        t.updatedAt = now
        t.routingConfiguration = try ctx.threadRepo.routingConfiguration(of: thread)
        if let wid = t.workspaceId {
            AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: wid)
        }
        windowController?.refreshFromState()
        return t
    }

    public func prepareAgentThreadForPullRequest(workspace: WorkspaceID, url: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try ctx.threadRepo.preflightWorkspaceThreadInsertion(workspaceId: workspace)
        let cwd = try workspaceCwd(workspace)
        let prep = GitDiff.preparePullRequestWorktree(in: cwd, urlString: url)
        guard prep.result.ok else {
            throw JSONRPCError(code: -32050, message: prep.result.message.isEmpty ? "Failed to prepare pull request worktree." : prep.result.message)
        }
        var thread = AgentThread(
            workspaceId: workspace,
            title: "PR #\(prep.ref.number): \(prep.ref.repositoryPath)",
            provider: provider,
            providerInstanceId: normalizedProviderInstanceId(provider: provider, requested: providerInstanceId),
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            executionMode: .worktree,
            baseBranch: prep.branch,
            worktreePath: prep.worktreePath,
            serviceTier: serviceTier,
            modelSelection: modelSelection ?? AgentModelSelection(provider: provider, modelId: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier)
        )
        thread.updatedAt = Date()
        let prunedThreadIDs: [AgentThreadID]
        do {
            try beforePullRequestThreadCommitForTesting?()
            prunedThreadIDs = try ctx.threadRepo.upsertEnforcingWorkspaceThreadLimit(thread)
        } catch {
            let cleanup = GitDiff.removeRegisteredWorktree(in: cwd, worktreePath: prep.worktreePath)
            if !cleanup.ok {
                throw JSONRPCError(
                    code: -32051,
                    message: "PR thread commit failed: \(error.localizedDescription) Worktree cleanup also failed: \(cleanup.message)"
                )
            }
            throw error
        }
        ctx.retireDeletedAgentThreads(prunedThreadIDs)
        publishAgentThreadDeletions(prunedThreadIDs)
        // Rail refresh only across surfaces; the initiating macOS surface (if
        // local) selects the PR thread through its own view-model path.
        try selectAgentThread(thread: thread.id)
        return thread
    }

    /// Reflect a thread selection across agent surfaces.
    ///
    /// Selection is PER-SURFACE: by default this only refreshes every agent
    /// surface's rail and selects the thread on the one surface identified by
    /// `surfaceID`. Passing `surfaceID == nil` performs a rail refresh only and
    /// selects nothing — so a thread created/selected by one client (or a
    /// mark-read) no longer force-switches every other macOS agent tab (the
    /// global fan-out that made iOS actions disturb macOS).
    public func selectAgentThread(thread: AgentThreadID, surfaceID: SurfaceID? = nil) throws {
        try selectAgentThread(thread: thread, surfaceID: surfaceID, markReadOnSelection: true)
    }

    private func selectAgentThread(
        thread: AgentThreadID,
        surfaceID: SurfaceID?,
        markReadOnSelection: Bool
    ) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        // Chrome lives on the painted rail. This hop only needs workspace
        // membership; a full 26-column + routing `get` hitchs MainActor.
        guard let workspaceID = try ctx.threadRepo.workspaceId(of: thread) else {
            throw LayoutError.workspaceNotFound
        }
        AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: workspaceID)
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == workspaceID else { continue }
            if let surfaceID, agent.descriptor.id == surfaceID {
                agent.viewModel.selectThread(thread, markRead: markReadOnSelection)
            }
        }
        windowController?.refreshFromState()
    }

    public func listAgentMessages(thread: AgentThreadID, limit: Int) throws -> [AgentMessage] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.listRecent(threadId: thread, limit: max(0, min(limit, 500)))
    }

    public func listAgentMessagesOffMain(thread: AgentThreadID, limit: Int) async throws -> [AgentMessage] {
        try await agentAppReadGateway.listMessages(threadId: thread, limit: limit)
    }

    public func agentThreadHasMessages(thread: AgentThreadID) throws -> Bool {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.hasAny(threadId: thread)
    }

    public func threadIdsWithMessages() throws -> Set<AgentThreadID> {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.threadIdsWithMessages()
    }

    public func threadIdsWithMessagesOffMain() async throws -> Set<AgentThreadID> {
        try await agentAppReadGateway.threadIdsWithMessages()
    }

    /// Off the main actor; an unreadable table reads as no markers.
    public func threadGuestRuntimesOffMain() async -> [AgentThreadID: String] {
        (try? await agentAppReadGateway.guestRuntimesByThread()) ?? [:]
    }

    public func listAgentMessagesPage(thread: AgentThreadID, limit: Int, before: AgentMessageCursor?, after: AgentMessageCursor? = nil) throws -> AgentMessagePage {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.listPage(threadId: thread, limit: max(0, min(limit, 500)), before: before, after: after)
    }

    public func listAgentMessagesPageOffMain(thread: AgentThreadID, limit: Int, before: AgentMessageCursor?, after: AgentMessageCursor? = nil) async throws -> AgentMessagePage {
        try await agentAppReadGateway.listMessagesPage(
            threadId: thread,
            limit: limit,
            before: before,
            after: after
        )
    }

    public func listAgentMessagesWithinBodyBudget(
        thread: AgentThreadID,
        limit: Int,
        before: AgentMessageCursor?,
        after: AgentMessageCursor?,
        budget: Int,
        contentLimit: Int
    ) throws -> AgentMessageBodyBudgetResult {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.listPageWithinBodyBudget(
            threadId: thread,
            limit: max(1, min(limit, 500)),
            before: before,
            after: after,
            budget: budget,
            contentLimit: contentLimit,
            appendEllipsisOnCap: false,
            attachmentsByteLimit:
                AgentMessageTransport.attachmentJSONMaxBytes,
            attachmentsCountLimit:
                AgentMessageTransport.attachmentCountLimit
        )
    }

    public func listAgentMessagesWithinBodyBudgetOffMain(
        thread: AgentThreadID,
        limit: Int,
        before: AgentMessageCursor?,
        after: AgentMessageCursor?,
        budget: Int,
        contentLimit: Int
    ) async throws -> AgentMessageBodyBudgetResult {
        try await agentAppReadGateway.listMessagesWithinBodyBudget(
            threadId: thread,
            limit: limit,
            before: before,
            after: after,
            budget: budget,
            contentLimit: contentLimit
        )
    }

    public func getAgentMessage(id: AgentMessageID) throws -> AgentMessage? {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.get(id: id)
    }

    public func getAgentMessageBodyChunk(
        id: AgentMessageID,
        offsetBytes: Int,
        maxContentBytes: Int,
        expectedBodyRevision: Int?,
        expectedBodySHA256: String?
    ) throws -> AgentMessageBodyChunk? {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.bodyChunk(
            id: id,
            offsetBytes: offsetBytes,
            maxContentBytes: maxContentBytes,
            expectedBodyRevision: expectedBodyRevision,
            expectedBodySHA256: expectedBodySHA256
        )
    }

    public func listAgentQueuedMessages(thread: AgentThreadID) throws -> [AgentQueuedMessage] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.queuedMessageRepo.list(threadId: thread)
    }

    public func listAgentQueuedMessagesOffMain(thread: AgentThreadID) async throws -> [AgentQueuedMessage] {
        try await agentAppReadGateway.listQueuedMessages(threadId: thread)
    }

    public func updateAgentQueuedMessage(id: AgentQueuedMessageID, text: String, attachments: [AgentAttachment]) async throws -> AgentQueuedMessage {
        guard let ctx = context,
              let queued = try ctx.queuedMessageRepo.get(id: id),
              let admission = try ctx.threadRepo.sendAdmission(of: queued.threadId) else {
            // Already drained or never queued: nothing was updated.
            throw DefiniteMutationRejection(JSONRPCError.invalidParams)
        }
        let resolved = try resolveInboundAgentAttachments(attachments)
        do {
            try await preflightAgentRun(
                fallbackProvider: admission.provider,
                fallbackProviderInstanceId: admission.providerInstanceId,
                provider: nil,
                providerInstanceId: nil,
                permissionMode: admission.permissionMode,
                interactionMode: queued.interactionMode,
                attachments: resolved
            )
        } catch {
            throw DefiniteMutationRejection(error)
        }
        guard let updated = try ctx.queuedMessageRepo.update(id: id, text: text, attachments: resolved) else {
            throw DefiniteMutationRejection(JSONRPCError.invalidParams)
        }
        publishQueuedMessage(kind: "agent.message.queue.updated", updated)
        refreshAgentSurfaces(thread: updated.threadId)
        return updated
    }

    public func cancelAgentQueuedMessage(id: AgentQueuedMessageID) throws -> AgentQueuedMessage {
        guard let ctx = context,
              let cancelled = try ctx.queuedMessageRepo.delete(id: id) else {
            // Already drained or never queued: nothing was deleted.
            throw DefiniteMutationRejection(JSONRPCError.invalidParams)
        }
        publishQueuedMessage(kind: "agent.message.queue.cancelled", cancelled)
        refreshAgentSurfaces(thread: cancelled.threadId)
        ctx.cancelQueueDrainWaiterIfQueueEmpty(threadId: cancelled.threadId)
        return cancelled
    }

    public func forceAgentQueuedMessageNow(id: AgentQueuedMessageID) async throws -> AgentMessageSendResult {
        guard let ctx = context,
              let queued = try ctx.queuedMessageRepo.get(id: id),
              let thread = try ctx.threadRepo.get(id: queued.threadId) else {
            throw JSONRPCError.invalidParams
        }
        try Self.requireContextPinnedSendAuthority(queued.threadId, context: ctx)
        if try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: id.value.uuidString, db: ctx.db) {
            let dispatch = try ctx.queuedMessageRepo.dispatch(id: id)
            guard dispatch?.state == .queued, dispatch?.runId == nil,
                  try ctx.runRepo.get(id: AgentRunID(id.value)) == nil else {
                throw JSONRPCError(code: -32602, message: "Restored queued outcome requires reconciliation before another send.")
            }
            try HostDatabaseRestore.approveQueue(kind: .agent, id: id.value.uuidString, db: ctx.db)
        }
        if let dispatch = try ctx.queuedMessageRepo.dispatch(id: queued.id),
           let runId = dispatch.runId {
            if dispatch.state == .dispatched {
                guard let drained = try ctx.queuedMessageRepo.acknowledgeDispatched(
                    id: queued.id,
                    runId: runId
                ) else {
                    throw JSONRPCError(
                        code: -32000,
                        message: "Queued message acknowledgement is already being recovered."
                    )
                }
                try promoteDeferredQueueMessage(
                    context: ctx,
                    ownerId: queued.id,
                    threadId: queued.threadId
                )
                publishQueuedMessage(kind: "agent.message.queue.drained", drained)
                refreshAgentSurfaces(thread: queued.threadId)
                ctx.ensureQueueDrainWaiterIfNeeded(threadId: queued.threadId)
                return AgentMessageSendResult(status: .started, runId: runId)
            }
            if dispatch.state == .prepared,
               try preparedQueueRunHasProviderEvidence(threadId: queued.threadId, runId: runId) {
                guard let drained = try ctx.queuedMessageRepo.acknowledgePreparedWithRunEvidence(id: queued.id, runId: runId) else {
                    throw JSONRPCError(code: -32000, message: "Queued message recovery is already being reconciled.")
                }
                try promoteDeferredQueueMessage(
                    context: ctx,
                    ownerId: queued.id,
                    threadId: queued.threadId
                )
                publishQueuedMessage(kind: "agent.message.queue.drained", drained)
                refreshAgentSurfaces(thread: queued.threadId)
                ctx.ensureQueueDrainWaiterIfNeeded(threadId: queued.threadId)
                return AgentMessageSendResult(status: .started, runId: runId)
            }
            if dispatch.state == .prepared {
                throw unconfirmedQueuedMessageStartError()
            }
        }
        let hasPendingProviderStart = ctx.coordinator.hasPendingProviderStart(threadId: queued.threadId)
        if thread.status == .running
            || hasPendingProviderStart
            || ctx.coordinator.hasProviderSession(threadId: queued.threadId) {
            let immediatePromotion = try ctx.queuedMessageRepo.promoteToFront(id: id)
            if immediatePromotion == nil, hasPendingProviderStart {
                let ownerId = try ctx.queuedMessageRepo.list(threadId: queued.threadId)
                    .first(where: { $0.durableState == .prepared })?
                    .id
                if let ownerId {
                    ctx.deferQueuePromotion(
                        id: id,
                        after: ownerId,
                        threadId: queued.threadId
                    )
                }
            }
            let promoted: AgentQueuedMessage?
            if let immediatePromotion {
                promoted = immediatePromotion
            } else if hasPendingProviderStart {
                promoted = try ctx.queuedMessageRepo.get(id: id)
            } else {
                promoted = nil
            }
            guard let promoted else {
                throw JSONRPCError.invalidParams
            }
            for message in try ctx.queuedMessageRepo.list(threadId: queued.threadId) {
                publishQueuedMessage(kind: "agent.message.queue.updated", message)
            }
            refreshAgentSurfaces(thread: queued.threadId)
            // Force = run now: interrupt the in-flight turn so the just-promoted
            // front-of-queue message starts immediately. stopRun resolves to a
            // .cancelled finish, which onRunFinished (AppContext) treats as
            // drain-eligible -> drainNextQueuedAgentMessage sends this message.
            // The synchronous result stays .queued; the new run begins via the
            // run-lifecycle events that follow.
            ctx.coordinator.stopRun(threadId: queued.threadId)
            return AgentMessageSendResult(status: .queued, queuedMessage: promoted)
        }
        guard let lease = try ctx.queuedMessageRepo.claim(id: queued.id) else {
            throw JSONRPCError(code: -32000, message: "Queued message is already processing.")
        }
        let dispatchRunId = AgentRunID(queued.id.value)
        try HostDatabaseRestore.recordQueueAttempt(kind: .agent, id: queued.id.value.uuidString, runID: dispatchRunId, db: ctx.db)
        guard try ctx.queuedMessageRepo.prepareDispatch(lease, runId: dispatchRunId) else {
            _ = try? ctx.queuedMessageRepo.release(lease)
            throw JSONRPCError(code: -32000, message: "Queued message dispatch could not be prepared.")
        }
        let acceptancePermit = AgentRunAcceptancePermit()
        var providerStartConfirmed = false
        do {
            let queuedRouting = try routingSnapshotForQueuedMessage(queued, context: ctx)
            let manualRouting = queuedRouting?.configuration.mode == .manual
                ? queuedRouting?.configuration
                : nil
            let manualSelection = manualRouting?.manualSelection
            let result = try await sendAgentMessage(
                thread: queued.threadId,
                text: queued.text,
                provider: manualSelection?.provider,
                model: manualSelection?.effectiveModel,
                permissionMode: queuedRouting?.permissionMode,
                reasoningEffort: manualSelection?.reasoningEffort,
                serviceTier: manualSelection?.serviceTier,
                interactionMode: queued.interactionMode,
                modelSelection: manualSelection,
                providerInstanceId: manualRouting?.manualProviderInstanceId,
                attachments: queued.attachments,
                queueMessageId: queued.id,
                queueAcceptancePermit: acceptancePermit,
                routingSnapshot: queuedRouting,
                allowProviderCatalogListingDuringPreflight: false
            )
            providerStartConfirmed = acceptancePermit.outcome == .accepted
            let drained = try finalizeQueueDispatchAfterProviderStart(
                context: ctx,
                lease: lease,
                runId: dispatchRunId,
                providerStartConfirmed: providerStartConfirmed
            )
            try promoteDeferredQueueMessage(
                context: ctx,
                ownerId: queued.id,
                threadId: queued.threadId
            )
            publishQueuedMessage(kind: "agent.message.queue.drained", drained)
            for message in try ctx.queuedMessageRepo.list(threadId: queued.threadId) {
                publishQueuedMessage(kind: "agent.message.queue.updated", message)
            }
            refreshAgentSurfaces(thread: queued.threadId)
            return result
        } catch {
            if !providerStartConfirmed {
                if let drained = try? reconcileSameCallPreparedDispatch(
                    context: ctx,
                    lease: lease,
                    runId: dispatchRunId,
                    acceptanceOutcome: acceptancePermit.outcome
                ) {
                    publishQueuedMessage(kind: "agent.message.queue.drained", drained)
                }
                if acceptancePermit.outcome == .notAccepted {
                    ctx.ensureQueueDrainWaiterIfNeeded(threadId: queued.threadId)
                }
            } else if let drained = try? finalizeQueueDispatchAfterProviderStart(
                context: ctx,
                lease: lease,
                runId: dispatchRunId,
                providerStartConfirmed: true
            ) {
                // Post-accept CAS races must not leave a prepared head while the
                // provider is already running; surface the original error only if
                // the queue intent is still present.
                try? promoteDeferredQueueMessage(
                    context: ctx,
                    ownerId: queued.id,
                    threadId: queued.threadId
                )
                publishQueuedMessage(kind: "agent.message.queue.drained", drained)
            }
            refreshAgentSurfaces(thread: queued.threadId)
            throw error
        }
    }

    /// Mirror-path equivalent of AgentAppViewModel.reorderQueuedMessage: moves
    /// the queued message to `position` (0-based target index, clamped) and
    /// renumbers every message in the thread's queue. Publishes
    /// agent.message.queue.updated for EVERY queued message so mirrors that
    /// upsert-by-id and sort-by-position converge on the new order.
    public func reorderAgentQueuedMessage(thread: AgentThreadID, id: AgentQueuedMessageID, position: Int) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let queue = try ctx.queuedMessageRepo.list(threadId: thread)
        guard let fromIndex = queue.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        let dest = max(0, min(position, queue.count - 1))
        let reordered = AgentAppViewModel.reorderQueue(queue, from: fromIndex, to: dest)
        let now = Date()
        for (index, var message) in reordered.enumerated() {
            message.position = index + 1
            message.updatedAt = now
            try ctx.queuedMessageRepo.upsert(message)
        }
        for message in try ctx.queuedMessageRepo.list(threadId: thread) {
            publishQueuedMessage(kind: "agent.message.queue.updated", message)
        }
        refreshAgentSurfaces(thread: thread)
    }

    public func agentPlanNotes(thread: AgentThreadID) throws -> String {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try PlanNotesStore(db: ctx.db).load(threadId: thread)
    }

    public func saveAgentPlanNotes(thread: AgentThreadID, notes: String) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try PlanNotesStore(db: ctx.db).save(notes, threadId: thread)
        // HC-5 spirit: a mirror-driven mutation must be visible on the Mac
        // immediately — refresh any open surface bound to this thread.
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.selectedThreadId == thread else { continue }
            agent.viewModel.applyMirroredPlanNotes(notes, threadId: thread)
        }
        publishAgentPlanNotesUpdated(thread: thread, notes: notes)
    }

    public func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier? = nil, interactionMode: AgentInteractionMode? = nil, modelSelection: AgentModelSelection? = nil, providerInstanceId: String? = nil, attachments: [AgentAttachment] = []) async throws -> AgentMessageSendResult {
        try await sendAgentMessage(
            thread: thread,
            text: text,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: interactionMode,
            modelSelection: modelSelection,
            providerInstanceId: providerInstanceId,
            attachments: attachments,
            queueMessageId: nil,
            orchestrationRoutingSnapshot: nil
        )
    }

    func sendAgentMessage(
        thread: AgentThreadID,
        text: String,
        provider: AgentProvider?,
        model: String?,
        permissionMode: AgentPermissionMode?,
        reasoningEffort: AgentReasoningEffort?,
        serviceTier: AgentServiceTier? = nil,
        interactionMode: AgentInteractionMode? = nil,
        modelSelection: AgentModelSelection? = nil,
        providerInstanceId: String? = nil,
        attachments: [AgentAttachment] = [],
        requestedRunID: AgentRunID,
        routingSnapshot: AgentQueuedMessageRoutingSnapshot? = nil,
        orchestrationRoutingSnapshot: AgentOrchestrationRoutingSnapshot? = nil,
        nestedRunContext: AgentNestedRunContext? = nil,
        executionCwdOverride: String? = nil,
        allowProviderCatalogListingDuringPreflight: Bool = true
    ) async throws -> AgentMessageSendResult {
        try await sendAgentMessage(
            thread: thread,
            text: text,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: interactionMode,
            modelSelection: modelSelection,
            providerInstanceId: providerInstanceId,
            attachments: attachments,
            queueMessageId: nil,
            routingSnapshot: routingSnapshot,
            requestedRunID: requestedRunID,
            orchestrationRoutingSnapshot: orchestrationRoutingSnapshot,
            nestedRunContext: nestedRunContext,
            executionCwdOverride: executionCwdOverride,
            allowProviderCatalogListingDuringPreflight: allowProviderCatalogListingDuringPreflight,
            // Desk, peer and hop callers send an already compiled bot prompt:
            // queued, it would show as the user's message and compile again at drain.
            queueBehindBusyBotVM: false
        )
    }

    struct ProviderWakeBusyError: Error {}

    /// Distill `/loop` wake the provider started on its own: the host adopts it as a run whose
    /// user row is `label`. A busy thread or busy bot VM keeps the wake pending until a run finishes.
    func startProviderInitiatedTurn(threadId: AgentThreadID, promptId: String, label: String) async {
        guard let ctx = context else { return }
        if startedProviderWakePromptIds[threadId]?.contains(promptId) == true
            || pendingProviderWakes[threadId]?.contains(where: { $0.promptId == promptId }) == true {
            return
        }
        if ctx.coordinator.hasProviderSession(threadId: threadId) || ctx.coordinator.hasPendingProviderStart(threadId: threadId)
            || (try? ctx.threadRepo.status(of: threadId)) == .running {
            pendingProviderWakes[threadId, default: []].append((promptId, label))
            return
        }
        markProviderWakeStarted(threadId: threadId, promptId: promptId)
        do {
            _ = try await sendAgentMessage(
                thread: threadId, text: label, provider: nil, model: nil, permissionMode: nil,
                reasoningEffort: nil, serviceTier: nil, interactionMode: nil, modelSelection: nil,
                providerInstanceId: nil, attachments: [], queueMessageId: nil,
                queueBehindBusyBotVM: false, attachToProviderPromptId: promptId
            )
        } catch is ProviderWakeBusyError {
            unmarkProviderWakeStarted(threadId: threadId, promptId: promptId)
            pendingProviderWakes[threadId, default: []].append((promptId, label))
        } catch is BotVMBusyError {
            unmarkProviderWakeStarted(threadId: threadId, promptId: promptId)
            pendingProviderWakes[threadId, default: []].append((promptId, label))
        } catch {
            unmarkProviderWakeStarted(threadId: threadId, promptId: promptId)
            appRouterLog.error("provider-initiated turn failed thread=\(threadId.value.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            ctx.distillAdapter.acknowledgeWakeFailed(threadId: threadId, promptId: promptId)
            appRouterLog.info("provider wake released for re-announce thread=\(threadId.value.uuidString, privacy: .public) prompt=\(promptId, privacy: .public)")
        }
    }

    private func markProviderWakeStarted(threadId: AgentThreadID, promptId: String) {
        var ids = startedProviderWakePromptIds[threadId] ?? []
        ids.append(promptId)
        if ids.count > 200 { ids.removeFirst(ids.count - 200) }
        startedProviderWakePromptIds[threadId] = ids
    }

    private func unmarkProviderWakeStarted(threadId: AgentThreadID, promptId: String) {
        startedProviderWakePromptIds[threadId]?.removeAll { $0 == promptId }
    }

    /// Starts the oldest wake that waited behind a run on `threadId`, then gives every other
    /// thread's pending wake one try: a finished run may have freed a bot VM they waited for.
    func startPendingProviderWake(threadId: AgentThreadID) async {
        await startOldestPendingProviderWake(threadId: threadId)
        for other in pendingProviderWakes.keys where other != threadId {
            await startOldestPendingProviderWake(threadId: other)
        }
    }

    private func startOldestPendingProviderWake(threadId: AgentThreadID) async {
        guard var wakes = pendingProviderWakes[threadId], !wakes.isEmpty else { return }
        let next = wakes.removeFirst()
        pendingProviderWakes[threadId] = wakes.isEmpty ? nil : wakes
        await startProviderInitiatedTurn(threadId: threadId, promptId: next.promptId, label: next.label)
    }

    /// A follow-up the host sends for the user (manual-action answers,
    /// Mac-execution approvals). On a bot thread it is a bot turn like the Mac
    /// card's: compiled brain, VM/guest rules, bot-home cwd and the desk's run
    /// bookkeeping. Any other thread gets the plain text.
    func sendBotThreadFollowUp(thread: AgentThreadID, text: String) async throws -> AgentMessageSendResult {
        try await sendAgentMessage(
            thread: thread,
            text: text,
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            interactionMode: nil,
            modelSelection: nil,
            providerInstanceId: nil,
            attachments: [],
            queueMessageId: nil,
            compilesBotPrompt: true
        )
    }

    /// Path B / scheduled Auto: same send as Agent App, with the preflight orchestration
    /// snapshot so admit + launch match what was verified.
    public func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier? = nil, interactionMode: AgentInteractionMode? = nil, modelSelection: AgentModelSelection? = nil, providerInstanceId: String? = nil, attachments: [AgentAttachment] = [], orchestrationRoutingSnapshot: AgentOrchestrationRoutingSnapshot?) async throws -> AgentMessageSendResult {
        try await sendAgentMessage(
            thread: thread,
            text: text,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: interactionMode,
            modelSelection: modelSelection,
            providerInstanceId: providerInstanceId,
            attachments: attachments,
            queueMessageId: nil,
            orchestrationRoutingSnapshot: orchestrationRoutingSnapshot
        )
    }

    public func sendAgentMessageRouting(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, interactionMode: AgentInteractionMode?, modelSelection: AgentModelSelection?, providerInstanceId: String?, attachments: [AgentAttachment], routing: AgentRoutingRequest?, nestedRunContext: AgentNestedRunContext? = nil) async throws -> AgentMessageSendResult {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        // Existence + routing row only. A leftover 26-column `get` hitchs every
        // `agent.message.send` just to check revision/mode before sendAgentMessage
        // loads the row again for mutate.
        // Only the remote agent.message.send handler calls this, so the
        // pre-write guards below are DefiniteMutationRejection: the request
        // ledger returns them as-is instead of commandOutcomeUnknown.
        guard try ctx.threadRepo.status(of: thread) != nil else {
            throw DefiniteMutationRejection(LayoutError.workspaceNotFound)
        }
        let storedRouting = try ctx.threadRepo.routingConfiguration(of: thread)
        if let routing {
            let currentRevision = storedRouting?.revision ?? 0
            let currentMode = storedRouting?.mode ?? .manual
            guard routing.expectedRevision == currentRevision else {
                throw DefiniteMutationRejection(AgentRoutingRevisionError.conflict(
                    expected: routing.expectedRevision,
                    actual: currentRevision
                ))
            }
            guard routing.mode == currentMode else {
                throw DefiniteMutationRejection(JSONRPCError(
                    code: -32020,
                    message: "Model routing mode changed on the host. Refresh the thread and try again.",
                    data: .object(["domain": .string("routing"), "kind": .string("mode_conflict")])
                ))
            }
        } else if storedRouting?.mode == .auto {
            throw DefiniteMutationRejection(JSONRPCError(
                code: -32020,
                message: "This thread requires an Auto routing revision. Refresh the thread and try again.",
                data: .object(["domain": .string("routing"), "kind": .string("routing_required")])
            ))
        }
        return try await sendAgentMessage(
            thread: thread,
            text: text,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: interactionMode,
            modelSelection: modelSelection,
            providerInstanceId: providerInstanceId,
            attachments: attachments,
            queueMessageId: nil,
            routingConfiguration: storedRouting,
            nestedRunContext: nestedRunContext,
            preflightRejectionIsDefinite: true,
            // A thread locked to a bot runs as that bot, as the Mac composer's
            // sends do (a paired device may have locked it with agent.thread.actor.set).
            compilesBotPrompt: try ctx.threadRepo.lockedBotActor(of: thread) != nil
        )
    }

    private func preflightAgentRun(
        fallbackProvider: AgentProvider,
        fallbackProviderInstanceId: String?,
        provider: AgentProvider?,
        providerInstanceId: String?,
        permissionMode: AgentPermissionMode,
        interactionMode: AgentInteractionMode,
        attachments: [AgentAttachment],
        allowProviderCatalogListing: Bool = true
    ) async throws {
        let desiredProvider = provider ?? fallbackProvider
        let desiredInstance = providerInstanceId
            ?? (desiredProvider == fallbackProvider ? fallbackProviderInstanceId : nil)
        // Agent App send uses the dest catalog already in memory. Desk used
        // to re-list every provider (Grok ACP + Anthropic + Codex) here and
        // wait on that before startRun.
        let snapshots: [AgentProviderSnapshot]
        if !cachedProviderSnapshots.isEmpty, providerSnapshotsAreFresh {
            snapshots = cachedProviderSnapshots
        } else if !cachedProviderSnapshots.isEmpty, !allowProviderCatalogListing {
            snapshots = cachedProviderSnapshots
        } else if !allowProviderCatalogListing {
            return
        } else {
            preflightListedProviderSnapshotsForTesting = true
            snapshots = await listAgentProviderSnapshots()
        }
        // Match AgentAppViewModel.selectedProviderSnapshot: prefer exact
        // instance+provider, then same provider. Do not fail closed on
        // "grok-cli" vs "grok" / stale instance ids when a live snapshot exists.
        let snapshot = AgentProviderSnapshotSelection.resolve(
            snapshots: snapshots,
            provider: desiredProvider,
            instanceId: desiredInstance
        )
        do {
            try AgentProviderRunPreflight.validate(
                snapshot: snapshot,
                interactionMode: interactionMode,
                permissionMode: permissionMode,
                attachments: attachments
            )
        } catch {
            throw JSONRPCError(code: -32013, message: String(describing: error))
        }
    }

    private func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, interactionMode: AgentInteractionMode?, modelSelection: AgentModelSelection?, providerInstanceId: String?, attachments: [AgentAttachment], queueMessageId: AgentQueuedMessageID?, queueAcceptancePermit: AgentRunAcceptancePermit? = nil, routingConfiguration: AgentRoutingConfiguration? = nil, routingSnapshot: AgentQueuedMessageRoutingSnapshot? = nil, requestedRunID: AgentRunID? = nil, orchestrationRoutingSnapshot: AgentOrchestrationRoutingSnapshot? = nil, nestedRunContext: AgentNestedRunContext? = nil, executionCwdOverride: String? = nil, allowProviderCatalogListingDuringPreflight: Bool = true, preflightRejectionIsDefinite: Bool = false, queueBehindBusyBotVM: Bool = true, compilesBotPrompt: Bool = false, attachToProviderPromptId: String? = nil, resumeInterrupted: Bool = false) async throws -> AgentMessageSendResult {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        do {
            try Self.requireContextPinnedSendAuthority(thread, context: ctx)
        } catch {
            if preflightRejectionIsDefinite { throw DefiniteMutationRejection(error) }
            throw error
        }
        // Status + permission + provider identity only. A leftover 26-column
        // + routing `get` hitchs every send before configureAgentThread loads
        // the row again for mutate.
        guard let admission = try ctx.threadRepo.sendAdmission(of: thread) else {
            throw LayoutError.workspaceNotFound
        }
        // A group room never runs a provider: its bots answer on their own threads.
        if try ctx.botStore.group(roomThreadID: thread) != nil {
            throw JSONRPCError(code: -32000, message: "This is a group conversation. Send to it with bot.group.send.")
        }
        let effectiveRouting: AgentRoutingConfiguration?
        if let passed = orchestrationRoutingSnapshot?.configuration
            ?? routingSnapshot?.configuration
            ?? routingConfiguration {
            effectiveRouting = passed
        } else {
            effectiveRouting = try ctx.threadRepo.routingConfiguration(of: thread)
        }
        let autoRoutingActive = effectiveRouting?.mode == .auto
        let resolvedAttachments = try resolveInboundAgentAttachments(attachments)
        sendAgentMessageResolvedAttachmentsProbeForTesting?(resolvedAttachments)
        if !autoRoutingActive {
            do {
                try await preflightAgentRun(
                    fallbackProvider: admission.provider,
                    fallbackProviderInstanceId: admission.providerInstanceId,
                    provider: modelSelection?.provider ?? provider,
                    providerInstanceId: providerInstanceId,
                    permissionMode: permissionMode ?? admission.permissionMode,
                    interactionMode: interactionMode ?? .default,
                    attachments: resolvedAttachments,
                    allowProviderCatalogListing: allowProviderCatalogListingDuringPreflight
                )
            } catch let error where preflightRejectionIsDefinite {
                // Nothing in this send has been written yet.
                throw DefiniteMutationRejection(error)
            }
        }
        if let probe = sendAgentMessageAfterPreflightProbeForTesting {
            await probe()
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        if resumeInterrupted, !ctx.coordinator.hasRecoverableContext(threadId: thread) {
            throw JSONRPCError(code: -32000, message: "The interrupted context changed while preparing to continue. Read the conversation again.")
        }
        func enqueueBehindActiveRun() throws -> AgentMessageSendResult {
            guard nestedRunContext == nil else {
                throw JSONRPCError(code: -32051, message: "The delegated thread is busy. Wait for its current run to finish before continuing.")
            }
            guard !resumeInterrupted else {
                throw JSONRPCError(code: -32000, message: "Thread became active before it could be continued.")
            }
            let queued = try ctx.queuedMessageRepo.enqueue(
                id: requestedRunID.map { AgentQueuedMessageID($0.value) },
                threadId: thread,
                text: text,
                attachments: resolvedAttachments,
                interactionMode: interactionMode ?? .default,
                routingSnapshot: routingSnapshot ?? AgentQueuedMessageRoutingSnapshot(
                    configuration: effectiveRouting ?? admission.legacyEffectiveRouting,
                    permissionMode: permissionMode ?? admission.permissionMode
                )
            )
            publishQueuedMessage(kind: "agent.message.queued", queued)
            refreshAgentSurfaces(thread: thread)
            ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread)
            return AgentMessageSendResult(status: .queued, runId: requestedRunID, queuedMessage: queued)
        }
        if admission.status == .running
            || ctx.coordinator.hasPendingProviderStart(threadId: thread)
            || ctx.coordinator.hasProviderSession(threadId: thread) {
            if queueMessageId != nil {
                throw JSONRPCError(code: -32000, message: "Thread became active before queued dispatch started.")
            }
            if attachToProviderPromptId != nil {
                throw ProviderWakeBusyError()
            }
            return try enqueueBehindActiveRun()
        }
        // D12: runs share a bot VM. A rebuild or stop holding it queues this
        // send until it lets go (its release drains the queue); a queued dispatch
        // was already claimed by the drain. Unstarted claims are freed below.
        let startRunID = requestedRunID ?? queueMessageId.map { AgentRunID($0.value) } ?? AgentRunID()
        let vmClaim = claimBotVMRun(thread: thread, runID: startRunID, firstMessage: text)
        if let vmClaim, let holder = vmClaim.holder {
            // Nothing was written: the caller keeps its text and shows the notice.
            guard queueBehindBusyBotVM else { throw BotVMBusyError(holder: holder) }
            if attachToProviderPromptId != nil { throw ProviderWakeBusyError() }
            let notice = waitForBotVM(botID: vmClaim.botID, thread: thread, holder: holder)
            if queueMessageId != nil { throw JSONRPCError(code: -32000, message: notice) }
            return try enqueueBehindActiveRun()
        }
        var vmRunStarted = false
        defer {
            if vmClaim != nil, !vmRunStarted { releaseBotVMRun(startRunID) }
        }
        // A message-send is not a provider-change gesture. The provider INSTANCE
        // is immutable once the thread has started (A1 parity), so never forward it
        // into configureAgentThread on a started thread: a mirror client that
        // re-derives its instance id from the provider snapshot list can carry an id
        // that no longer matches the thread's locked instance, and configureAgentThread
        // would otherwise reject the send with -32013 ("Provider instance is locked")
        // — leaving the user unable to send. Provider itself is still forwarded so a
        // genuine provider mismatch stays a loud -32010 rather than silently mutating
        // model/session state. The explicit agent.thread.configure RPC keeps enforcing
        // both locks for the UI's change-provider gesture.
        let alreadyStarted = (try? ctx.messageRepo.hasAny(threadId: thread)) ?? false
        var t = try configureAgentThread(
            thread: thread,
            provider: autoRoutingActive ? nil : provider,
            model: autoRoutingActive ? nil : model,
            permissionMode: permissionMode,
            reasoningEffort: autoRoutingActive ? nil : reasoningEffort,
            serviceTier: autoRoutingActive ? nil : serviceTier,
            modelSelection: autoRoutingActive ? nil : modelSelection,
            providerInstanceId: autoRoutingActive || alreadyStarted ? nil : providerInstanceId
        )
        let reconciled = try ctx.threadRepo.reconcileBotExecutionTarget(t, forUserSend: true)
        if reconciled.executionTarget != t.executionTarget {
            t = reconciled
            publishAgentThreadUpdated(t)
        }
        if AgentThreadTitle.isPlaceholder(t.title),
           !alreadyStarted {
            t.title = AgentThreadTitle.titleFromFirstMessage(text)
            try ctx.threadRepo.updateTitlePreservingActivity(thread, title: t.title)
            EventBus.shared.publish(kind: .agentThreadRenamed, payload: .object([
                "thread_id": .string(t.id.value.uuidString),
                "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                "title": .string(t.title),
                "display_title": .string(AgentThreadTitle.display(t.title)),
                "displayTitle": .string(AgentThreadTitle.display(t.title)),
                "provider_locked": .bool(true),
                "providerLocked": .bool(true)
            ]))
        }
        let prov = t.provider
        let m = t.model
        let cwd: String
        if let executionCwdOverride {
            cwd = GrokACPClient.resolvedSessionCwd(executionCwdOverride)
        } else {
            cwd = try prepareAgentExecutionCwd(thread: &t)
        }
        // Provider-instance host environment for the Source provider. Same-host
        // Auto never switches provider. The previous empty Auto base dropped
        // instance config (HOME/CODEX_HOME/GROK_HOME, custom env) from the
        // request shell, so nested CLI children could miss instance homes.
        // Always stamp the full base here.
        let hostProviderBase = providerEnvironment(
            provider: prov,
            instanceId: t.providerInstanceId,
            threadId: thread
        )
        let acceptancePermit = queueMessageId.map { _ in
            queueAcceptancePermit ?? AgentRunAcceptancePermit()
        }
        if let acceptancePermit {
            ctx.registerQueueDispatchAcceptancePermit(acceptancePermit, threadId: thread)
        }
        defer {
            if let acceptancePermit {
                ctx.unregisterQueueDispatchAcceptancePermit(acceptancePermit, threadId: thread)
            }
        }
        var providerRunEnvironment = hostProviderBase
        providerRunEnvironment.removeValue(
            forKey: AgentAppRuntimeProfile.environmentKey
        )
        if let runtimeProfile = nestedRunContext?.runtimeProfile {
            guard runtimeProfile == .samGrokWorkerV1,
                  prov == .grok,
                  GrokACPClient.admitsSamGrokWorker(model: m, effort: t.reasoningEffort),
                  t.permissionMode == .autoAcceptEdits,
                  t.providerThreadId == nil else {
                throw JSONRPCError.invalidParams
            }
            providerRunEnvironment[AgentAppRuntimeProfile.environmentKey] =
                runtimeProfile.rawValue
        }
        let requestedRunID = startRunID
        // Prefer a full orchestration snapshot (scheduled Path B / Auto admit)
        // so launch binary+catalog match preflight. Queued messages only carry
        // the lightweight admission fields and refill provider snapshots at start.
        let coordinatorSnapshot: AgentOrchestrationRoutingSnapshot?
        if let orchestrationRoutingSnapshot {
            coordinatorSnapshot = orchestrationRoutingSnapshot
        } else {
            coordinatorSnapshot = routingSnapshot.map {
                AgentOrchestrationRoutingSnapshot(
                    configuration: $0.configuration,
                    providerSnapshots: $0.configuration.mode == .manual
                        ? cachedProviderSnapshotsForSend()
                        : [],
                    admissionSnapshot: $0
                )
            }
        }
        if queueMessageId != nil {
            if let queueDispatchBeforeProviderStartForTesting {
                await queueDispatchBeforeProviderStartForTesting()
            }
            guard ctx.queueDrainAllowsWork(threadId: thread), !Task.isCancelled else {
                throw CancellationError()
            }
        }
        var nestedReceiptRegistered = false
        if let nestedRunContext {
            let parentThread = try validatedNestedParent(
                nestedRunContext,
                requestedWorkspace: t.workspaceId,
                requestedPermissionMode: t.permissionMode
            )
            let isBotPeer = try ctx.coordinator.isDelegatedRun(requestedRunID, threadId: t.id,
                parentRunId: nestedRunContext.parentRunID)
                && ctx.botStore.conversationLinked(to: t.id) != nil
            // Bot consultations inherit the execution scope but keep their
            // private thread out of the workspace's Agent App rail.
            guard (t.workspaceId == parentThread.workspaceId || (isBotPeer && t.workspaceId == nil)),
                  t.projectId == parentThread.projectId,
                  (t.runAsUser == parentThread.runAsUser
                    || (isBotPeer && (t.runAsUser ?? .current()) == (parentThread.runAsUser ?? .current()))),
                  t.executionMode == parentThread.executionMode,
                  t.worktreePath == parentThread.worktreePath else {
                throw JSONRPCError(
                    code: -32020,
                    message: "Nested Agent App child scope does not match its parent.",
                    data: .object([
                        "domain": .string("orchestration"),
                        "kind": .string("invalid_child_scope")
                    ])
                )
            }
            do {
                let childCapability = AgentDelegationCapability.issue()
                _ = try ctx.orchestrationRuntime.recordAuthorizedExternalChild(
                    runId: requestedRunID,
                    threadId: t.id,
                    provider: prov,
                    providerInstanceId: t.providerInstanceId ?? prov.rawValue,
                    model: m,
                    reasoningEffort: t.reasoningEffort,
                    nodeId: nestedRunContext.nodeID,
                    parentRunId: nestedRunContext.parentRunID,
                    parentThreadId: nestedRunContext.parentThreadID,
                    parentCapability: nestedRunContext.parentCapability,
                    childCapability: childCapability,
                    requestedPermissionMode: t.permissionMode
                )
                // Rebuild the host environment for the *child* thread so every
                // orchestrated worker gets the full surface, not a thinned
                // parent/Auto shell.
                providerRunEnvironment = completeOrchestratedWorkerEnvironment(
                    thread: t,
                    provider: prov,
                    childCapability: childCapability,
                    runtimeProfile: nestedRunContext.runtimeProfile
                )
                nestedReceiptRegistered = true
            } catch let error as AgentOrchestrationAdmissionError {
                let kind: String
                switch error {
                case .invalidChildAdmission:
                    kind = "invalid_child_admission"
                case .receiptPersistenceFailed:
                    kind = "receipt_persistence_failed"
                default:
                    kind = "nested_admission_failed"
                }
                throw JSONRPCError(
                    code: -32020,
                    message: error.description,
                    data: .object([
                        "domain": .string("orchestration"),
                        "kind": .string(kind)
                    ])
                )
            } catch {
                throw JSONRPCError(
                    code: -32020,
                    message: "Nested Agent App receipt could not be persisted.",
                    data: .object([
                        "domain": .string("orchestration"),
                        "kind": .string("receipt_persistence_failed")
                    ])
                )
            }
        }
        var runPrompt = text
        var runCwd = cwd
        var botPromptApplied = false
        if attachToProviderPromptId == nil, queueMessageId != nil || compilesBotPrompt,
           let transform = botThreadPromptTransform,
           let transformed = try await transform(thread, text, requestedRunID) {
            runPrompt = transformed.prompt
            if let botCwd = transformed.cwd { runCwd = GrokACPClient.resolvedSessionCwd(botCwd) }
            botPromptApplied = true
        }
        var req = AgentRunRequest(
            runId: requestedRunID,
            threadId: thread,
            provider: prov,
            providerInstanceId: t.providerInstanceId,
            model: m,
            cwd: runCwd,
            prompt: runPrompt,
            userMessageContent: botPromptApplied ? text : nil,
            attachments: resolvedAttachments,
            providerThreadId: resumeInterrupted ? nil : t.providerThreadId,
            permissionMode: t.permissionMode,
            reasoningEffort: t.reasoningEffort,
            reasoningModel: t.reasoningModel,
            distillMainEffortSelection: prov == .distill
                ? (modelSelection?.distillMainEffortSelection ?? t.modelSelection.distillMainEffortSelection) : nil,
            distillReasoningEffortSelection: prov == .distill
                ? (modelSelection?.distillReasoningEffortSelection ?? t.modelSelection.distillReasoningEffortSelection) : nil,
            distillExecutionMode: prov == .distill
                ? (modelSelection?.distillExecutionMode ?? t.modelSelection.distillExecutionMode) : .normal,
            serviceTier: t.serviceTier,
            interactionMode: interactionMode ?? .default,
            providerBinary: autoRoutingActive ? nil : providerBinary(provider: prov, instanceId: t.providerInstanceId),
            environment: providerRunEnvironment,
            runAsUser: t.runAsUser,
            acceptancePermit: acceptancePermit
        )
        req.attachToProviderPromptId = attachToProviderPromptId
        let runId: AgentRunID
        do {
            runId = try await ctx.coordinator.startRun(req, routingSnapshot: coordinatorSnapshot, recordUserMessage: !resumeInterrupted)
            vmRunStarted = true
        } catch {
            if nestedReceiptRegistered {
                try? ctx.orchestrationRuntime.finalizeReceipt(
                    runId: req.runId,
                    status: .failed
                )
            }
            throw error
        }
        // HC-5 (R1): a message sent from the mobile mirror / RPC must become
        // visible on the Mac host. Refresh every Agent App rail so the thread
        // list + running state update, and re-load the transcript ONLY on
        // surfaces already bound to this thread. Do NOT force-select every
        // Agent App tab onto this thread — that was residual Bug B and made a
        // reply in one conversation contaminate sibling tabs.
        refreshAgentSurfaces(
            thread: thread,
            workspace: t.workspaceId,
            reloadTranscriptIfSelected: true
        )
        if botPromptApplied { botThreadRunStarted?(runId, thread) }
        return AgentMessageSendResult(status: .started, runId: runId)
    }

    public func drainNextQueuedAgentMessage(
        thread: AgentThreadID,
        recoverPreparedFromPriorProcess: Bool = false,
        botVMHandOff: Bool = false
    ) async throws {
        if let ctx = context {
            try Self.requireContextPinnedSendAuthority(thread, context: ctx)
            if let head = try ctx.queuedMessageRepo.first(threadId: thread),
               try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: head.id.value.uuidString, db: ctx.db) {
                return
            }
        }
        // This gate only needs durable run-state. A full 26-column + routing
        // `get` hitchs MainActor before the next queued follow-up can start.
        // A D12 hand-off also drains a thread that never ran (still `.pending`
        // by default) when no start is in flight: its first send queued
        // behind the bot's VM. Launch recovery does the same for a VM-bot
        // thread, whose in-memory wait did not survive the relaunch.
        guard let ctx = context,
              ctx.queueDrainAllowsWork(threadId: thread),
              !Task.isCancelled,
              let status = try ctx.threadRepo.status(of: thread),
              status != .running,
              try status != .pending || (
                  (botVMHandOff || (recoverPreparedFromPriorProcess && botIDOfVMThread(thread) != nil))
                  && !ctx.coordinator.hasPendingProviderStart(threadId: thread)
                  && ctx.runRepo.latestActive(for: thread) == nil),
              !ctx.coordinator.hasProviderSession(threadId: thread) else { return }
        if let head = try ctx.queuedMessageRepo.first(threadId: thread),
           let dispatch = try ctx.queuedMessageRepo.dispatch(id: head.id),
           dispatch.state == .prepared,
           let runId = dispatch.runId {
            if let runStatus = try ctx.runRepo.status(of: runId) {
                guard try preparedQueueRunHasProviderEvidence(threadId: thread, runId: runId) else {
                    throw unconfirmedQueuedMessageStartError()
                }
                if let recovered = try ctx.queuedMessageRepo.acknowledgePreparedWithRunEvidence(id: head.id, runId: runId) {
                    try promoteDeferredQueueMessage(
                        context: ctx,
                        ownerId: head.id,
                        threadId: thread
                    )
                    publishQueuedMessage(kind: "agent.message.queue.drained", recovered)
                    refreshAgentSurfaces(thread: thread)
                }
                if runStatus == .running || runStatus == .pending {
                    return
                }
            } else {
                guard recoverPreparedFromPriorProcess else { return }
                guard try ctx.queuedMessageRepo.recoverPreparedBeforeProviderStart(id: head.id, runId: runId) != nil else {
                    throw JSONRPCError(code: -32000, message: "Queued message recovery is already being reconciled.")
                }
                publishQueuedMessage(kind: "agent.message.queue.updated", head)
                refreshAgentSurfaces(thread: thread)
            }
        }
        if let recovered = try ctx.queuedMessageRepo.acknowledgeFirstDispatched(threadId: thread) {
            try promoteDeferredQueueMessage(
                context: ctx,
                ownerId: recovered.id,
                threadId: thread
            )
            publishQueuedMessage(kind: "agent.message.queue.drained", recovered)
            refreshAgentSurfaces(thread: thread)
        }
        guard ctx.queueDrainAllowsWork(threadId: thread), !Task.isCancelled else { return }
        guard let lease = try ctx.queuedMessageRepo.claimFirst(threadId: thread) else { return }
        guard ctx.queueDrainAllowsWork(threadId: thread), !Task.isCancelled else {
            _ = try? ctx.queuedMessageRepo.release(lease)
            return
        }
        let queued = lease.message
        let dispatchRunId = AgentRunID(queued.id.value)
        // D12: a rebuild or stop holding the VM keeps the message queued; its
        // release drains it. A claim whose run never
        // started is freed on every exit.
        let vmClaim = claimBotVMRun(thread: thread, runID: dispatchRunId)
        if let vmClaim, let holder = vmClaim.holder {
            _ = try? ctx.queuedMessageRepo.release(lease)
            waitForBotVM(botID: vmClaim.botID, thread: thread, holder: holder)
            return
        }
        defer {
            if vmClaim != nil {
                let runStatus = (try? ctx.runRepo.status(of: dispatchRunId)) ?? nil
                if runStatus != .running, runStatus != .pending { releaseBotVMRun(dispatchRunId) }
            }
        }
        guard try ctx.queuedMessageRepo.prepareDispatch(lease, runId: dispatchRunId) else {
            _ = try? ctx.queuedMessageRepo.release(lease)
            throw JSONRPCError(code: -32000, message: "Queued message dispatch could not be prepared.")
        }
        let acceptancePermit = AgentRunAcceptancePermit()
        var providerStartConfirmed = false
        do {
            let queuedRouting = try routingSnapshotForQueuedMessage(queued, context: ctx)
            guard ctx.queueDrainAllowsWork(threadId: thread), !Task.isCancelled else {
                _ = try? ctx.queuedMessageRepo.releasePrepared(lease, runId: dispatchRunId)
                return
            }
            let manualRouting = queuedRouting?.configuration.mode == .manual
                ? queuedRouting?.configuration
                : nil
            let manualSelection = manualRouting?.manualSelection
            _ = try await sendAgentMessage(
                thread: thread,
                text: queued.text,
                provider: manualSelection?.provider,
                model: manualSelection?.effectiveModel,
                permissionMode: queuedRouting?.permissionMode,
                reasoningEffort: manualSelection?.reasoningEffort,
                serviceTier: manualSelection?.serviceTier,
                interactionMode: queued.interactionMode,
                modelSelection: manualSelection,
                providerInstanceId: manualRouting?.manualProviderInstanceId,
                attachments: queued.attachments,
                queueMessageId: queued.id,
                queueAcceptancePermit: acceptancePermit,
                routingSnapshot: queuedRouting,
                allowProviderCatalogListingDuringPreflight: false
            )
            providerStartConfirmed = acceptancePermit.outcome == .accepted
            let drained = try finalizeQueueDispatchAfterProviderStart(
                context: ctx,
                lease: lease,
                runId: dispatchRunId,
                providerStartConfirmed: providerStartConfirmed
            )
            try promoteDeferredQueueMessage(
                context: ctx,
                ownerId: queued.id,
                threadId: queued.threadId
            )
            publishQueuedMessage(kind: "agent.message.queue.drained", drained)
            refreshAgentSurfaces(thread: thread)
        } catch {
            if !providerStartConfirmed {
                if let drained = try? reconcileSameCallPreparedDispatch(
                    context: ctx,
                    lease: lease,
                    runId: dispatchRunId,
                    acceptanceOutcome: acceptancePermit.outcome
                ) {
                    publishQueuedMessage(kind: "agent.message.queue.drained", drained)
                }
            } else if let drained = try? finalizeQueueDispatchAfterProviderStart(
                context: ctx,
                lease: lease,
                runId: dispatchRunId,
                providerStartConfirmed: true
            ) {
                try? promoteDeferredQueueMessage(
                    context: ctx,
                    ownerId: queued.id,
                    threadId: queued.threadId
                )
                publishQueuedMessage(kind: "agent.message.queue.drained", drained)
            }
            refreshAgentSurfaces(thread: thread)
            throw error
        }
    }

    private func routingSnapshotForQueuedMessage(
        _ message: AgentQueuedMessage,
        context: AppContext
    ) throws -> AgentQueuedMessageRoutingSnapshot? {
        try context.queuedMessageRepo.routingSnapshot(id: message.id)
    }

    /// After `sendAgentMessage` returns for a prepared lease, remove the durable
    /// queue intent. Prefer the happy path (prepared → dispatched → delete). If
    /// that CAS loses a race or fails after provider acceptance, fall back to
    /// run-bound prepared/dispatched acknowledgement so a live turn never leaves
    /// a sticky "Start confirmation is pending" head.
    private func finalizeQueueDispatchAfterProviderStart(
        context: AppContext,
        lease: AgentQueuedMessageLease,
        runId: AgentRunID,
        providerStartConfirmed: Bool
    ) throws -> AgentQueuedMessage {
        if try context.queuedMessageRepo.markDispatched(lease, runId: runId),
           let drained = try context.queuedMessageRepo.acknowledge(lease) {
            return drained
        }
        let hasEvidence = (try? preparedQueueRunHasProviderEvidence(
            threadId: lease.message.threadId,
            runId: runId
        )) == true
        if providerStartConfirmed || hasEvidence {
            if let drained = try context.queuedMessageRepo.acknowledgePreparedWithRunEvidence(
                id: lease.message.id,
                runId: runId
            ) {
                return drained
            }
            if let drained = try context.queuedMessageRepo.acknowledgeDispatched(
                id: lease.message.id,
                runId: runId
            ) {
                return drained
            }
            // Concurrent recovery already removed the row (e.g. Force status check).
            if try context.queuedMessageRepo.get(id: lease.message.id) == nil {
                return lease.message
            }
        }
        throw JSONRPCError(
            code: -32000,
            message: "Provider started; queue acknowledgement needs recovery."
        )
    }

    /// A same-process start failure still leaves a durable run row before the
    /// provider accepts the turn. Only the same positive evidence used by Force
    /// and relaunch recovery may remove that prepared intent.
    private func reconcileSameCallPreparedDispatch(
        context: AppContext,
        lease: AgentQueuedMessageLease,
        runId: AgentRunID,
        acceptanceOutcome: AgentRunAcceptanceOutcome
    ) throws -> AgentQueuedMessage? {
        if acceptanceOutcome == .notAccepted {
            let promotedId = context.deferredQueuePromotion(
                threadId: lease.message.threadId,
                ownerId: lease.message.id
            )
            let released = try context.queuedMessageRepo.releasePrepared(
                lease,
                runId: runId,
                promoting: promotedId
            )
            if released {
                context.clearDeferredQueuePromotion(
                    threadId: lease.message.threadId,
                    ownerId: lease.message.id
                )
            }
            return nil
        }
        if acceptanceOutcome == .accepted {
            let acknowledged = try context.queuedMessageRepo.acknowledgePreparedWithRunEvidence(
                id: lease.message.id,
                runId: runId
            )
            try promoteDeferredQueueMessage(
                context: context,
                ownerId: lease.message.id,
                threadId: lease.message.threadId
            )
            return acknowledged
        }
        return nil
    }

    private func promoteDeferredQueueMessage(
        context: AppContext,
        ownerId: AgentQueuedMessageID,
        threadId: AgentThreadID
    ) throws {
        guard let promotedId = context.deferredQueuePromotion(
            threadId: threadId,
            ownerId: ownerId
        ) else { return }
        if try context.queuedMessageRepo.get(id: promotedId) == nil {
            context.clearDeferredQueuePromotion(threadId: threadId, ownerId: ownerId)
            return
        }
        guard try context.queuedMessageRepo.promoteToFront(id: promotedId) != nil else {
            return
        }
        context.clearDeferredQueuePromotion(threadId: threadId, ownerId: ownerId)
    }

    /// Relaunch recovery for queue rows left between durable prepare and provider
    /// start acknowledgement. Each head is reconciled before normal drain: no run
    /// row means safe CAS requeue; an existing deterministic run means ack-only,
    /// never provider replay.
    public func reconcileQueuedAgentMessagesOnLaunch() async {
        guard let ctx = context else { return }
        let threadIds: [AgentThreadID]
        do {
            threadIds = try ctx.queuedMessageRepo.threadIdsWithQueuedMessages()
        } catch {
            EventBus.shared.publish(kind: .agentMessageQueueFailed, payload: .object([
                "message": .string("Queue launch recovery failed: \(error)")
            ]))
            return
        }
        for threadId in threadIds {
            do {
                try await drainNextQueuedAgentMessage(
                    thread: threadId,
                    recoverPreparedFromPriorProcess: true
                )
            } catch {
                EventBus.shared.publish(kind: .agentMessageQueueFailed, payload: .object([
                    "thread_id": .string(threadId.value.uuidString),
                    "message": .string("Queue launch recovery failed: \(error)")
                ]))
            }
        }
    }

    /// A run row is written before `runner.sendTurn`, so it cannot by itself
    /// prove that the provider accepted a prepared queue dispatch. The provider
    /// session records `run.started`, a turn boundary, or `run.finished` only
    /// after that boundary succeeds. Missing, thread-started stream-event,
    /// start-failure, or still-pending evidence must preserve the queue row to
    /// avoid both silent loss and an unsafe replay after relaunch.
    private func preparedQueueRunHasProviderEvidence(
        threadId: AgentThreadID,
        runId: AgentRunID
    ) throws -> Bool {
        guard let ctx = context,
              try ctx.runRepo.threadId(of: runId) != nil,
              let session = try ctx.providerSessionRuntimeRepo.get(threadId: threadId),
              session.lastRunId == runId,
              let lastEventKind = session.lastEventKind?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !lastEventKind.isEmpty else {
            return false
        }
        return lastEventKind == "run.started"
            || lastEventKind == "run.finished"
            || lastEventKind.hasPrefix("turnStarted(")
            || lastEventKind.hasPrefix("turnCompleted(")
    }

    private func unconfirmedQueuedMessageStartError() -> JSONRPCError {
        JSONRPCError(
            code: -32000,
            message: "Provider start is unconfirmed. The message remains queued to prevent loss or duplicate execution."
        )
    }

    /// Full host environment for an orchestrated Agent App worker (nested child).
    ///
    /// Every worker gets the same host environment as a user-started primary
    /// turn (instance homes, managed PATH proxies, Subagents lifecycle keys).
    /// Rebuilds from the child thread identity after nested admission so
    /// cross-provider children are not stuck with a parent-only or Auto-thinned
    /// shell.
    private func completeOrchestratedWorkerEnvironment(
        thread: AgentThread,
        provider: AgentProvider,
        childCapability: String,
        runtimeProfile: AgentAppRuntimeProfile?
    ) -> [String: String] {
        var env = providerEnvironment(
            provider: provider,
            instanceId: thread.providerInstanceId,
            threadId: thread.id
        )
        env.removeValue(forKey: AgentAppRuntimeProfile.environmentKey)
        if let runtimeProfile {
            env[AgentAppRuntimeProfile.environmentKey] = runtimeProfile.rawValue
        }
        env[AgentDelegationCapabilityTransport.environmentKey] = childCapability
        // Re-assert managed wrappers first so nested PATH proxies stay in front.
        if let managedBin = env["RC_REMOTE_CODE_MANAGED_BIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !managedBin.isEmpty,
           let path = env["PATH"] {
            env["PATH"] = Self.providerPathWithManagedWrappers(
                currentPath: path,
                managedBin: managedBin
            )
        }
        return env
    }

    func effectiveAgentExecutionCwd(for thread: AgentThread) throws -> String {
        switch thread.executionMode {
        case .local:
            guard let workspaceID = thread.workspaceId else {
                throw LayoutError.workspaceNotFound
            }
            return try workspaceCwd(workspaceID)
        case .worktree:
            guard let path = thread.worktreePath,
                  FileManager.default.fileExists(atPath: path) else {
                throw JSONRPCError(
                    code: -32013,
                    message: "Agent worktree is unavailable."
                )
            }
            return path
        }
    }

    private func prepareAgentExecutionCwd(thread: inout AgentThread) throws -> String {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let workspaceCwd = ctx.state.workspaces.first { $0.value.id == thread.workspaceId }?.value.cwd ?? FileManager.default.currentDirectoryPath
        let cwd = GrokACPClient.resolvedSessionCwd(workspaceCwd)
        guard thread.executionMode == .worktree else { return cwd }
        if let path = thread.worktreePath, FileManager.default.fileExists(atPath: path) {
            return path
        }
        let base = thread.baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty else {
            throw JSONRPCError(code: -32012, message: "Worktree mode requires a base branch before the first agent prompt.")
        }
        let root = URL(fileURLWithPath: workspaceCwd)
        let parent = root.deletingLastPathComponent()
        let name = root.lastPathComponent.isEmpty ? "workspace" : root.lastPathComponent
        let shortId = String(thread.id.value.uuidString.prefix(8)).lowercased()
        let path = parent.appendingPathComponent("\(name)-agent-worktrees").appendingPathComponent(shortId).path
        let branch = "rc-agent/\(shortId)"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let result = GitDiff.createWorktree(in: workspaceCwd, path: path, branch: branch, baseBranch: base)
        guard result.ok || FileManager.default.fileExists(atPath: path) else {
            throw JSONRPCError(code: -32013, message: result.message.isEmpty ? "Failed to create agent worktree." : result.message)
        }
        // Path chrome only. A leftover 26-column upsert hitchs the first
        // worktree-mode send and rewrites title/status/unread/color/pin/routing.
        let now = Date()
        guard try ctx.threadRepo.setWorktreePath(of: thread.id, path: path, at: now) else {
            throw LayoutError.workspaceNotFound
        }
        thread.worktreePath = path
        thread.updatedAt = now
        return path
    }

    public func implementAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, newThread: Bool, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier? = nil, modelSelection: AgentModelSelection? = nil) async throws -> (runId: AgentRunID, implementationThreadId: AgentThreadID) {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let source = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        try Self.refuseContextPinnedGenericExecution(thread, context: ctx)
        let storedMarkdown: String?
        if let planMarkdown {
            storedMarkdown = planMarkdown
        } else {
            storedMarkdown = try ctx.proposedPlanRepo.list(threadId: thread).last(where: { $0.plan.id == planId })?.plan.markdown
        }
        let markdown = storedMarkdown
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONRPCError(code: -32030, message: "Proposed plan not found.")
        }
        let implementationThread: AgentThread
        if newThread {
            implementationThread = try createAgentThread(
                workspace: source.workspaceId,
                title: "Implement plan",
                provider: provider ?? source.provider,
                model: model ?? source.model,
                permissionMode: permissionMode ?? source.permissionMode,
                reasoningEffort: reasoningEffort ?? source.reasoningEffort,
                serviceTier: serviceTier ?? source.serviceTier,
                modelSelection: modelSelection ?? source.modelSelection,
                providerInstanceId: source.providerInstanceId
            )
        } else {
            implementationThread = source
        }
        let sendResult = try await sendAgentMessage(
            thread: implementationThread.id,
            text: AgentPlanImplementationPrompt.make(markdown: markdown),
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: .default,
            modelSelection: modelSelection,
            providerInstanceId: source.providerInstanceId,
            attachments: []
        )
        // Same-thread implement while a turn is live queues (sendAgentMessage). Treat that
        // as success: durable plan mark + track the queued message id as the future run id
        // (queue drain uses AgentRunID(queued.id.value)).
        let runId: AgentRunID
        if let started = sendResult.runId {
            runId = started
        } else if sendResult.status == .queued, let queued = sendResult.queuedMessage {
            runId = AgentRunID(queued.id.value)
        } else {
            throw JSONRPCError(code: -32032, message: "Plan implementation could not start or queue.")
        }
        try ctx.proposedPlanRepo.markImplemented(threadId: thread, planId: planId, implementationThreadId: implementationThread.id)
        return (runId, implementationThread.id)
    }

    public func saveAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, relativePath: String?) throws -> (path: String, relativePath: String) {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let source = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        let storedMarkdown = try ctx.proposedPlanRepo.list(threadId: thread).last(where: { $0.plan.id == planId })?.plan.markdown
        guard let markdown = planMarkdown ?? storedMarkdown,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONRPCError(code: -32030, message: "Proposed plan not found.")
        }
        let workspaceCwd = ctx.state.workspaces.first { $0.value.id == source.workspaceId }?.value.cwd
        guard let workspaceCwd, !workspaceCwd.isEmpty else { throw LayoutError.workspaceNotFound }
        let rootURL = URL(fileURLWithPath: workspaceCwd).standardizedFileURL
        let requestedRelative = relativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeRelative = requestedRelative?.isEmpty == false
            ? requestedRelative!
            : ".remotecode/plans/\(AssistantProposedPlan(id: planId, turnId: nil, markdown: markdown).exportFileName)"
        guard !safeRelative.hasPrefix("/") && !safeRelative.split(separator: "/").contains("..") else {
            throw JSONRPCError(code: -32031, message: "Plan save path must stay inside the workspace.")
        }
        let targetURL = rootURL.appendingPathComponent(safeRelative).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard targetURL.path == rootURL.path || targetURL.path.hasPrefix(rootPath) else {
            throw JSONRPCError(code: -32031, message: "Plan save path must stay inside the workspace.")
        }
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: targetURL, atomically: true, encoding: .utf8)
        let resolvedRelative = String(targetURL.path.dropFirst(rootPath.count))
        return (targetURL.path, resolvedRelative)
    }

    public func commandReceipt(method: String, clientRequestId: String) -> JSONValue? {
        guard let ctx = context else { return nil }
        // Durable get off MainActor: Dispatcher already has a volatile cache for
        // the hot retry path; this is the SQLite fallback and must not beachball.
        let repo = ctx.commandReceiptRepo
        let methodCopy = method
        let clientRequestIdCopy = clientRequestId
        return CommandReceiptPersistenceGateway.shared.sync {
            guard let json = try? repo.get(method: methodCopy, clientRequestId: clientRequestIdCopy),
                  let data = json.data(using: .utf8) else { return nil as JSONValue? }
            return JSONValue.decode(from: data)
        }
    }

    public func recordCommandReceipt(method: String, clientRequestId: String, result: JSONValue) {
        guard let ctx = context,
              let data = try? jsonValueEncoder.encode(result),
              let json = String(data: data, encoding: .utf8) else { return }
        // Fire-and-forget durable write: Dispatcher already mirrors into volatile
        // cache before this call, so the RPC response path does not wait on SQLite.
        let repo = ctx.commandReceiptRepo
        let methodCopy = method
        let clientRequestIdCopy = clientRequestId
        let jsonCopy = json
        CommandReceiptPersistenceGateway.shared.async {
            try? repo.record(method: methodCopy, clientRequestId: clientRequestIdCopy, resultJSON: jsonCopy)
        }
    }

    public func claimCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult {
        guard let context else { throw LayoutError.workspaceNotFound }
        let repo = context.commandReceiptRepo
        return try CommandReceiptPersistenceGateway.shared.syncThrowing {
            try repo.claim(
                method: method,
                clientRequestId: clientRequestId,
                ownerFingerprint: ownerFingerprint,
                paramsHash: paramsHash
            )
        }
    }

    public func commitCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) throws {
        guard let context else { throw LayoutError.workspaceNotFound }
        let data = try commandReceiptSortedEncoder.encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
            throw JSONRPCError.internalError
        }
        let repo = context.commandReceiptRepo
        try CommandReceiptPersistenceGateway.shared.syncThrowing {
            try repo.commit(
                method: method,
                clientRequestId: clientRequestId,
                ownerFingerprint: ownerFingerprint,
                paramsHash: paramsHash,
                resultJSON: json
            )
        }
    }

    public func finalizeCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent],
        minimumEventSequence: Int64
    ) throws -> [EventBus.Event] {
        guard let context else { throw LayoutError.workspaceNotFound }
        return try CommandReceiptOffMainWriter(repo: context.commandReceiptRepo).finalizeTransaction(
            method: method,
            clientRequestId: clientRequestId,
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            result: result,
            events: events
        )(minimumEventSequence)
    }

    public var commandReceiptOffMainWriter: (any CommandReceiptOffMainWriting)? {
        guard let context else { return nil }
        return CommandReceiptOffMainWriter(repo: context.commandReceiptRepo)
    }

    public func markCommandReceiptUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        guard let context else { throw LayoutError.workspaceNotFound }
        let repo = context.commandReceiptRepo
        try CommandReceiptPersistenceGateway.shared.syncThrowing {
            try repo.markUnknown(
                method: method,
                clientRequestId: clientRequestId,
                ownerFingerprint: ownerFingerprint,
                paramsHash: paramsHash
            )
        }
    }

    public func releaseCommandReceiptClaim(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        guard let context else { throw LayoutError.workspaceNotFound }
        let repo = context.commandReceiptRepo
        try CommandReceiptPersistenceGateway.shared.syncThrowing {
            try repo.releaseClaim(
                method: method,
                clientRequestId: clientRequestId,
                ownerFingerprint: ownerFingerprint,
                paramsHash: paramsHash
            )
        }
    }

    public func commandReceiptStatus(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult {
        guard let context else { throw LayoutError.workspaceNotFound }
        let repo = context.commandReceiptRepo
        return try CommandReceiptPersistenceGateway.shared.syncThrowing {
            try repo.status(
                method: method,
                clientRequestId: clientRequestId,
                ownerFingerprint: ownerFingerprint
            )
        }
    }

    public func respondAgentRequest(thread: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let state: AssistantRequestState = {
            switch response {
            case .approve, .approveForSession: return .approved
            case .decline: return .declined
            case .cancel: return .cancelled
            }
        }()
        do {
            try await ctx.coordinator.respondToRequest(threadId: thread, requestId: requestId, response: response)
            try? ctx.providerPendingCallbackRepo.resolve(threadId: thread, requestId: requestId, kind: .approval, state: state)
            EventBus.shared.publish(kind: .agentRequestResolved, payload: .object([
                "thread_id": .string(thread.value.uuidString),
                "request_id": .string(requestId),
                "state": .string(state.rawValue)
            ]))
            if response == .approveForSession {
                let updated = try configureAgentThread(
                    thread: thread,
                    provider: nil,
                    model: nil,
                    permissionMode: .fullAccess,
                    reasoningEffort: nil,
                    serviceTier: nil,
                    modelSelection: nil,
                    providerInstanceId: nil
                )
                publishAgentThreadUpdated(updated)
            }
        } catch {
            let reason = "Provider approval response failed: \(error)"
            try? ctx.providerPendingCallbackRepo.markStale(threadId: thread, requestId: requestId, kind: .approval, reason: reason)
            EventBus.shared.publish(kind: .agentRequestResolved, payload: .object([
                "thread_id": .string(thread.value.uuidString),
                "request_id": .string(requestId),
                "state": .string(AssistantRequestState.stale.rawValue),
                "error": .string(reason)
            ]))
            throw error
        }
    }

    public func respondAgentUserInput(thread: AgentThreadID, requestId: String, text: String) async throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        do {
            try await ctx.coordinator.respondToUserInput(threadId: thread, requestId: requestId, text: text)
            try? ctx.providerPendingCallbackRepo.resolve(threadId: thread, requestId: requestId, kind: .userInput, state: .resolved)
            EventBus.shared.publish(kind: .agentUserInputResolved, payload: .object([
                "thread_id": .string(thread.value.uuidString),
                "request_id": .string(requestId),
                "answer": .string(text)
            ]))
        } catch {
            let reason = "Provider user-input response failed: \(error)"
            try? ctx.providerPendingCallbackRepo.markStale(threadId: thread, requestId: requestId, kind: .userInput, reason: reason)
            EventBus.shared.publish(kind: .agentUserInputResolved, payload: .object([
                "thread_id": .string(thread.value.uuidString),
                "request_id": .string(requestId),
                "state": .string(AssistantRequestState.stale.rawValue),
                "error": .string(reason)
            ]))
            throw error
        }
    }

    public func listAgentPendingCallbacks(thread: AgentThreadID) throws -> AssistantPendingCallbacksSnapshot {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return PendingCallbackSnapshotMapper.snapshot(
            from: try ctx.providerPendingCallbackRepo.listVisible(threadId: thread),
            decoder: settingsJSONDecoder
        )
    }

    public func listAgentPendingCallbacksOffMain(thread: AgentThreadID) async throws -> AssistantPendingCallbacksSnapshot {
        try await agentAppReadGateway.listPendingCallbacks(threadId: thread)
    }

    public func readAgentThreadEvents(thread: AgentThreadID) async throws -> [AssistantEvent] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try await ctx.coordinator.readThread(threadId: thread)
    }

    public func readAgentThreadMirrorSnapshot(
        thread: AgentThreadID,
        eventRowLimit: Int?,
        maxPayloadBytes: Int64?
    ) async throws -> AgentThreadMirrorSnapshot {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        // v1: metadata-first length inspection + decode only the selected suffix.
        // Runs off MainActor: the barrier waits on this thread's mirror lock
        // (a long stream flush) and the selection reads SQLite, neither of
        // which may stall the UI or other paired-device RPCs.
        if let eventRowLimit, let maxPayloadBytes {
            let coordinator = ctx.coordinator
            return try await Task.detached(priority: .userInitiated) {
                let signposter = PerfSwitchMetrics.signposter
                let interval = signposter.beginInterval("thread_read_v1_snapshot", id: signposter.makeSignpostID())
                defer { signposter.endInterval("thread_read_v1_snapshot", interval) }
                return try coordinator.withMirrorEventSnapshotForThreadReadV1(
                    threadId: thread,
                    eventLimit: eventRowLimit,
                    maxPayloadBytes: maxPayloadBytes
                ) { selection in
                    let blocked = selection.blockedNewest.map {
                        AgentThreadMirrorSnapshot.BlockedMirrorEvent(
                            id: $0.id,
                            payloadBytes: $0.payloadBytes,
                            reason: $0.reason
                        )
                    }
                    return AgentThreadMirrorSnapshot(
                        events: selection.events,
                        eventWatermark: EventBus.shared.currentSeq,
                        sourceHadOlderEvents: selection.hasMoreOlder,
                        blockedEvent: blocked
                    )
                }
            }.value
        }
        // Legacy: unbounded (or optional count-only) decode path.
        let sqlLimit = eventRowLimit.map { max(1, $0) + 1 } ?? Int.max
        return try ctx.coordinator.withMirrorEventSnapshot(threadId: thread, limit: sqlLimit) { loaded in
            let hadOlder: Bool
            let events: [AssistantEvent]
            if let eventRowLimit, loaded.count > eventRowLimit {
                hadOlder = true
                events = Array(loaded.suffix(eventRowLimit))
            } else {
                hadOlder = false
                events = loaded
            }
            return AgentThreadMirrorSnapshot(
                events: events,
                eventWatermark: EventBus.shared.currentSeq,
                sourceHadOlderEvents: hadOlder,
                blockedEvent: nil
            )
        }
    }

    public func rollbackAgentThread(thread: AgentThreadID, toTurnId: String) async throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try await ctx.coordinator.rollbackThread(threadId: thread, toTurnId: toTurnId)
    }

    public func listAgentThreadCheckpoints(thread: AgentThreadID) throws -> [AgentTurnCheckpointSummary] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.turnCheckpointRepo.list(threadId: thread)
    }

    public func listAgentThreadCheckpointsPage(
        thread: AgentThreadID,
        maxEntries: Int,
        before: AgentTurnCheckpointCursor?,
        expectedCatalogRevision: Int64?
    ) async throws -> AgentTurnCheckpointPage {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        // SQLite query/decode must never run on MainActor (Dispatcher is @MainActor).
        return try await ctx.checkpointListGateway.listMetadataPage(
            threadId: thread,
            maxEntries: maxEntries,
            before: before,
            expectedCatalogRevision: expectedCatalogRevision
        )
    }

    public func agentCheckpointDiff(thread: AgentThreadID, checkpointTurnCount: Int, expectedRunID: UUID? = nil, path: String?) throws -> String {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let checkpoint = try ctx.turnCheckpointRepo.get(threadId: thread, checkpointTurnCount: checkpointTurnCount) else {
            if expectedRunID != nil {
                throw JSONRPCError(code: -32013, message: "Checkpoint diff is unavailable for the expected run.")
            }
            throw LayoutError.workspaceNotFound
        }
        if let expectedRunID, checkpoint.runId.value != expectedRunID {
            throw JSONRPCError(code: -32013, message: "Checkpoint diff is unavailable for the expected run.")
        }
        if let path {
            return checkpoint.fileDiffs.first(where: { $0.path == path })?.patch ?? ""
        }
        return checkpoint.diffPatch ?? checkpoint.fileDiffs.map(\.patch).joined(separator: "\n")
    }

    public func revertAgentThreadToCheckpoint(thread: AgentThreadID, checkpointTurnCount: Int) async throws -> AgentTurnCheckpointSummary {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let agentThread = try ctx.threadRepo.get(id: thread),
              let workspaceId = agentThread.workspaceId else { throw LayoutError.workspaceNotFound }
        return try await ctx.coordinator.revertThreadToCheckpoint(
            threadId: thread,
            checkpointTurnCount: checkpointTurnCount,
            cwd: try workspaceCwd(workspaceId)
        )
    }

    public func stopAgentRun(thread: AgentThreadID) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        ctx.coordinator.stopRun(threadId: thread)
    }

    /// Host-owned active run for mirror / Live Activity.
    ///
    /// WHY: iOS `authoritativeActiveThreads` is fail-closed on non-empty
    /// `active_run_id`. Emitting null when a real run exists (LaunchAgent /
    /// durable row, or missing `startedAt`) drops every running agent from the
    /// phone card and falls through to terminal inbox ("N done - M failed").
    /// Match Agent App surfaces: in-memory id first, then `durableActiveRun`.
    /// Never withhold identity just because the start clock is unavailable.
    public func activeAgentRun(thread: AgentThreadID) throws -> AgentActiveRunSnapshot? {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        if let runId = ctx.coordinator.activeRunId(threadId: thread) {
            let startedAt = (try? ctx.coordinator.runStartedAt(runId: runId)) ?? Date()
            return AgentActiveRunSnapshot(runId: runId, startedAt: startedAt)
        }
        if let durable = try ctx.coordinator.durableActiveRunChrome(threadId: thread) {
            return AgentActiveRunSnapshot(runId: durable.id, startedAt: durable.startedAt)
        }
        return nil
    }

    public func activeAgentDelegation(
        thread: AgentThreadID,
        run: AgentRunID
    ) throws -> AgentActiveDelegationSnapshot? {
        guard let ctx = context,
              let active = try ctx.coordinator.activeDelegationCapability(
                threadId: thread,
                runId: run
              ) else {
            return nil
        }
        return AgentActiveDelegationSnapshot(
            threadId: active.threadId,
            runId: active.runId,
            hostId: ctx.liveActivityHostIdentity.serverId,
            capability: active.capability,
            expiresAt: active.expiresAt
        )
    }

    /// Resume through the same saved-context path as the Mac Continue button,
    /// without recording the provider-only instruction as a user message.
    public func continueAgentRun(thread: AgentThreadID) async throws -> AgentRunID? {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        if (try ctx.threadRepo.status(of: thread)) == .running
            || ctx.coordinator.hasPendingProviderStart(threadId: thread)
            || ctx.coordinator.hasProviderSession(threadId: thread) {
            throw JSONRPCError(code: -32000, message: "Thread already has an active run.")
        }
        guard ctx.coordinator.hasRecoverableContext(threadId: thread) else {
            throw JSONRPCError(code: -32000, message: "No saved interrupted context is available. Read the conversation before sending a new message.")
        }
        let result = try await sendAgentMessage(
            thread: thread,
            text: "Continue the interrupted turn from the last saved context. Do not repeat completed work.",
            provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil,
            serviceTier: nil, interactionMode: nil, modelSelection: nil,
            providerInstanceId: nil, attachments: [], queueMessageId: nil,
            queueBehindBusyBotVM: false, compilesBotPrompt: true, resumeInterrupted: true
        )
        return result.runId
    }

    public func threadLoops(thread: AgentThreadID) -> [DistillLoopState] {
        context?.distillLoopStore.loops(for: thread) ?? []
    }

    public func stopThreadLoop(thread: AgentThreadID, taskId: String) async throws -> Bool {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        do {
            return try await ctx.distillAdapter.stopLoop(threadId: thread, taskId: taskId)
        } catch AgentProviderAdapterError.sessionNotFound {
            throw JSONRPCError(code: -32000, message: "Loop's agent session is not running")
        }
    }

    private func stopDistillLoops(threads: [AgentThreadID], ctx: AppContext) async {
        for thread in threads {
            for loop in ctx.distillAdapter.loops(threadId: thread) where loop.state == .active {
                _ = try? await ctx.distillAdapter.stopLoop(threadId: thread, taskId: loop.taskID)
            }
        }
    }

    public func deleteAgentThread(thread: AgentThreadID) async throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let handoffDeletion = ctx.botPeerHandoffAuthority.beginDeletion(threadIDs: [thread])
        var didDeleteSource = false
        defer {
            if !didDeleteSource {
                ctx.botPeerHandoffAuthority.rollbackDeletion(handoffDeletion)
            }
        }
        let suppressionLease = await ctx.acquireQueueDrainSuppression(threadId: thread)
        defer { ctx.releaseQueueDrainSuppression(threadId: thread, lease: suppressionLease) }
        await stopDistillLoops(threads: [thread], ctx: ctx)
        try await ctx.coordinator.stopAndAwaitTermination(threadId: thread)
        try ctx.threadRepo.delete(id: thread)
        didDeleteSource = true
        _ = ctx.botPeerHandoffAuthority.commitDeletion(handoffDeletion)
    }

    public func deleteAgentThreads(_ threads: [AgentThreadID]) async throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let handoffDeletion = ctx.botPeerHandoffAuthority.beginDeletion(threadIDs: Set(threads))
        var didDeleteSource = false
        defer {
            if !didDeleteSource {
                ctx.botPeerHandoffAuthority.rollbackDeletion(handoffDeletion)
            }
        }
        let suppressionLeases = await ctx.acquireQueueDrainSuppressions(threadIds: threads)
        defer {
            for (thread, lease) in suppressionLeases {
                ctx.releaseQueueDrainSuppression(threadId: thread, lease: lease)
            }
        }
        await stopDistillLoops(threads: threads, ctx: ctx)
        try await ctx.coordinator.stopAndAwaitTermination(threadIds: threads)
        try ctx.threadRepo.delete(ids: threads)
        didDeleteSource = true
        _ = ctx.botPeerHandoffAuthority.commitDeletion(handoffDeletion)
    }

    public func renameAgentThread(thread: AgentThreadID, title: String) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JSONRPCError.invalidParams }
        // Title only. A leftover 26-column + routing `get` then `upsert`
        // hitchs the rename RPC and clobbers concurrent persistThreadConfig /
        // run-start writes (PERSISTENCE-DATA-002).
        try ctx.threadRepo.updateTitlePreservingActivity(thread, title: trimmed)
        guard let t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        return t
    }

    public func setAgentThreadPinned(thread: AgentThreadID, pinned: Bool) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try ctx.threadRepo.setPinned(id: thread, pinned: pinned)
        guard let t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        if let wid = t.workspaceId {
            AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: wid)
        }
        windowController?.refreshFromState()
        return t
    }

    public func setAgentThreadColor(thread: AgentThreadID, color: String) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try ctx.threadRepo.setColor(id: thread, color: color.isEmpty ? nil : color)
        guard let t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        if let wid = t.workspaceId {
            AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: wid)
        }
        windowController?.refreshFromState()
        return t
    }

    public func reorderAgentThread(thread: AgentThreadID, position: Int) throws -> [AgentThread] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try ctx.threadRepo.reorder(id: thread, position: position)
        // Chrome lives on the painted rail. This hop only needs workspace
        // membership; a leftover 26-column + routing `get` hitchs MainActor.
        guard let wid = try ctx.threadRepo.workspaceId(of: thread) else { throw LayoutError.workspaceNotFound }
        let list = try ctx.threadRepo.list(workspaceId: wid)
        AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: wid)
        windowController?.refreshFromState()
        return list
    }

    public func markAgentThreadRead(thread: AgentThreadID) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        // Unread + workspace only. A leftover 26-column + routing `get` then
        // `upsert` hitchs every open/select and rewrites routing JSON just to
        // clear has_unread. Cosmetic open must not rewrite activity time.
        guard let result = try ctx.threadRepo.markReadPreservingActivity(of: thread) else {
            throw LayoutError.workspaceNotFound
        }
        if result.cleared {
            NSLog(
                "[AgentOpen] mark_read wrote unread=false thread=%@ preservedUpdatedAt=%.0f",
                String(thread.value.uuidString.prefix(8)),
                result.updatedAt.timeIntervalSince1970
            )
            if let wid = result.workspaceId {
                AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: wid)
            }
            publishAgentThreadRead(thread)
        }
        // Seen here is seen in Activity: its finished runs leave Just finished.
        let viewedRuns = (try? AgentRunResultRepository(db: ctx.db).markFinishedRunsViewed(threadId: thread)) ?? []
        if !viewedRuns.isEmpty {
            let ids = viewedRuns.map { "run:\($0.value.uuidString.lowercased())" }
            EventBus.shared.publish(kind: .notificationRead, payload: .object([
                "id": .string("activity:\(ids[0])"),
                "activity_item_ids": .array(ids.map(JSONValue.string)),
                "reason": .string("viewed")
            ]))
        }
    }

    public func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor] {
        if provider == .distill, let controller = context?.distillAccountsController {
            return await controller.discoverModels { await self.listAgentModels(provider: provider, runAsUser: nil) }
        }
        return await listAgentModels(provider: provider, runAsUser: nil)
    }

    public func listAgentModels(
        provider: AgentProvider,
        runAsUser: AgentRunAsUser?,
        forceCatalogRefresh: Bool = false
    ) async -> [AgentModelDescriptor] {
        let binary = configuredProviderBinary(provider) ?? provider.rawValue
        let binaryPath = Self.resolveProviderBinaryPath(binary: binary, runAsUser: runAsUser)
        let environment = Self.probeEnvironment(
            base: providerEnvironment(provider: provider, instanceId: nil),
            provider: provider,
            runAsUser: runAsUser
        )
        let cwd = context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory()
        switch provider {
        case .codex:
            let discovered = await CodexAppServerModelDiscovery.listModels(
                binary: binaryPath.isEmpty ? binary : binaryPath,
                cwd: cwd,
                environment: environment,
                runAsUser: runAsUser
            )
            return discovered.isEmpty
                ? await CodexRunner(binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath).listModels()
                : discovered
        case .claude:
            return await ClaudeRunner(binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath)
                .listModelsResult(
                    environment: environment,
                    cwd: cwd,
                    runAsUser: runAsUser
                ).models
        case .grok:
            return await GrokACPAdapter(
                binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath,
                discoveryCwd: cwd,
                discoveryEnvironment: environment,
                discoveryRunAsUser: runAsUser
            ).listModels()
        case .distill:
            return await DistillACPAdapter(
                binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath,
                discoveryCwd: cwd,
                discoveryEnvironment: environment,
                discoveryRunAsUser: runAsUser
            ).discoveryResult(forceRefresh: forceCatalogRefresh).models
        }
    }

    func refreshAgentProviderAuthentication(_ provider: AgentProvider) async -> [AgentProviderSnapshot] {
        let staleKeys = providerProbeCache.keys.filter { $0.provider == provider }
        for key in staleKeys {
            providerProbeCache.removeValue(forKey: key)
        }
        return await listAgentProviderSnapshots()
    }

    /// Resolves a provider CLI for the user who will execute it — same rules as
    /// ClaudeStreamingCLIAdapter / ProcessLocator.resolveForRunAsUser so Auto
    /// admission and helper-backed spawn agree.
    static func resolveProviderBinaryPath(
        binary: String,
        runAsUser: AgentRunAsUser?
    ) -> String {
        ProcessLocator.resolveForRunAsUser(binary, runAsUser: runAsUser) ?? ""
    }

    /// Environment for probing. Foreign run-as-user auth is executed via the
    /// installed helper (ProviderCLIProbe); HOME overrides remain for discovery
    /// that does not elevate (model list REST, skills paths).
    static func probeEnvironment(
        base: [String: String],
        provider: AgentProvider,
        runAsUser: AgentRunAsUser?
    ) -> [String: String] {
        guard let runAsUser, runAsUser.uid != getuid() else { return base }
        var env = base
        env["HOME"] = runAsUser.homePath
        switch provider {
        case .claude:
            break
        case .codex:
            env["CODEX_HOME"] = env["CODEX_HOME"] ?? "\(runAsUser.homePath)/.codex"
        case .grok:
            env["GROK_HOME"] = env["GROK_HOME"] ?? "\(runAsUser.homePath)/.grok"
        case .distill:
            env["DISTILL_HOME"] = env["DISTILL_HOME"] ?? "\(runAsUser.homePath)/.distill"
        }
        return env
    }

    /// Dest send already listed the catalog. Reuse it so startRun is not
    /// blocked on Grok/Anthropic/Codex discovery again.
    public func rememberProviderSnapshotsForSend(_ snapshots: [AgentProviderSnapshot]) {
        guard !snapshots.isEmpty else { return }
        cachedProviderSnapshots = snapshots
        cachedProviderSnapshotsAt = Date()
    }

    public func cachedProviderSnapshotsForSend() -> [AgentProviderSnapshot] {
        guard providerSnapshotsAreFresh, !cachedProviderSnapshots.isEmpty else { return [] }
        return cachedProviderSnapshots
    }

    private var providerSnapshotsAreFresh: Bool {
        !ModelListTTLDecision.shouldRefetch(
            lastFetchedAt: cachedProviderSnapshotsAt,
            ttl: ModelListTTLDecision.defaultCatalogTTL,
            now: Date()
        )
    }

    public func setAgentWorkerModel(thread: AgentThreadID, model: String?) throws -> AgentThread {
        guard let context, var threadValue = try context.threadRepo.threadWithoutRouting(of: thread) else { throw LayoutError.workspaceNotFound }
        let normalized = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        threadValue.reasoningModel = normalized?.isEmpty == false ? normalized : nil
        guard try context.threadRepo.setPickerConfig(
            of: thread,
            provider: threadValue.provider,
            providerInstanceId: threadValue.providerInstanceId ?? threadValue.provider.rawValue,
            runAsUser: threadValue.runAsUser,
            model: threadValue.model,
            permissionMode: threadValue.permissionMode,
            reasoningEffort: threadValue.reasoningEffort,
            serviceTier: threadValue.serviceTier,
            modelSelection: threadValue.modelSelection,
            interactionMode: threadValue.effectiveInteractionMode,
            reasoningModel: threadValue.reasoningModel
        ) else { throw LayoutError.workspaceNotFound }
        for surface in SurfaceRegistry.shared.all() {
            guard let agent = surface as? AgentAppSurface, agent.viewModel.selectedThreadId == thread else { continue }
            agent.viewModel.reasoningModel = threadValue.reasoningModel
        }
        EventBus.shared.publish(kind: .agentThreadUpdated, payload: agentThreadPayload(threadValue))
        return threadValue
    }

    private func distillRoutingJSON(_ routing: DistillAutoRouting) -> JSONValue {
        var value = jsonValue(routing).objectValue ?? [:]
        value["options"] = .array(routing.options.map { option in
            var row = jsonValue(option).objectValue ?? [:]
            row["worker_model"] = option.workerModel.map(JSONValue.string) ?? .null
            return .object(row)
        })
        return .object(value)
    }

    public func listDistillAccounts() async -> JSONValue {
        guard let controller = context?.distillAccountsController else {
            return .object(["accounts": .array([]), "routing": .null, "busy": .bool(false), "busy_account_id": .null, "busy_provider": .null, "last_error": .null])
        }
        await controller.refreshAndWait()
        let rows = controller.statuses.map { status -> JSONValue in
            var row = jsonValue(status).objectValue ?? [:]
            row["display_name"] = .string(status.provider.displayName)
            row["email"] = status.email.map(JSONValue.string) ?? .null
            row["connection_error"] = status.connectionError.map(JSONValue.string) ?? .null
            row["quota"] = status.quota.map { jsonValue($0) } ?? .null
            return .object(row)
        }
        return .object([
            "accounts": .array(rows),
            "routing": controller.hasLoadedState ? distillRoutingJSON(controller.routing) : .null,
            "busy": .bool(controller.isBusy),
            "busy_account_id": controller.busyAccountID.map(JSONValue.string) ?? .null,
            "busy_provider": controller.busyProvider.map { .string($0.rawValue) } ?? .null,
            "last_error": controller.lastError.map(JSONValue.string) ?? .null
        ])
    }

    public func getDistillRouting() async throws -> JSONValue {
        guard let controller = context?.distillAccountsController else { throw LayoutError.workspaceNotFound }
        await controller.refreshAndWait()
        guard controller.hasLoadedState, controller.stateError == nil else {
            throw JSONRPCError(code: -32041, message: controller.stateError ?? "Accounts are still loading. Refresh and try again.")
        }
        return distillRoutingJSON(controller.routing)
    }

    public func mutateDistillAccount(method: String, accountID: String?, provider: DistillAccountProvider?, label: String?) throws -> JSONValue {
        guard let controller = context?.distillAccountsController else { throw LayoutError.workspaceNotFound }
        guard !controller.isBusy else { throw JSONRPCError(code: -32041, message: "A Distill account operation is already running.") }
        if method == "distill.accounts.add" {
            guard let provider, let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JSONRPCError.invalidParams }
            controller.add(provider: provider, label: label)
        } else {
            guard let accountID, controller.statuses.contains(where: { $0.id == accountID }) else {
                throw JSONRPCError(code: -32602, message: "Unknown Distill account. Refresh Accounts and try again.")
            }
            switch method {
            case "distill.accounts.rename":
                guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JSONRPCError.invalidParams }
                controller.rename(accountID: accountID, label: label)
            case "distill.accounts.remove": controller.remove(accountID: accountID)
            case "distill.accounts.login": controller.login(accountID: accountID)
            case "distill.accounts.logout": controller.logout(accountID: accountID)
            case "distill.accounts.usage": controller.refreshUsage(accountID: accountID)
            default: throw JSONRPCError.invalidParams
            }
        }
        return .object(["started": .bool(true)])
    }

    public func setDistillRouting(_ routing: DistillAutoRouting) throws -> JSONValue {
        guard let controller = context?.distillAccountsController else { throw LayoutError.workspaceNotFound }
        guard controller.hasLoadedState else { throw JSONRPCError(code: -32041, message: "Accounts are still loading. Refresh and try again.") }
        guard !controller.isBusy else { throw JSONRPCError(code: -32041, message: "A Distill account operation is already running.") }
        if let error = DistillRoutingValidation.error(routing, saved: controller.routing, accounts: controller.statuses, models: controller.models) {
            throw JSONRPCError(code: -32602, message: error)
        }
        controller.saveRouting(routing)
        return .object(["started": .bool(true)])
    }

    public func loginDistillAccount(_ provider: DistillAccountProvider) throws -> JSONValue {
        try mutateDistillAccount(method: "distill.accounts.login", accountID: provider.legacyID, provider: nil, label: nil)
    }
    public func logoutDistillAccount(_ provider: DistillAccountProvider) throws -> JSONValue {
        try mutateDistillAccount(method: "distill.accounts.logout", accountID: provider.legacyID, provider: nil, label: nil)
    }

    public func cancelDistillAccountOperation() throws -> JSONValue {
        guard let controller = context?.distillAccountsController else { throw LayoutError.workspaceNotFound }
        controller.cancel()
        return .object(["cancelled": .bool(true)])
    }

    public func refreshDistillProviderCatalog() async {
        cachedProviderSnapshotsAt = nil
        providerProbeCache = providerProbeCache.filter { $0.key.provider != .distill }
        _ = await listAgentProviderSnapshots(runAsUser: nil, forceCatalogRefresh: true)
        for surface in SurfaceRegistry.shared.all() {
            guard let agent = surface as? AgentAppSurface else { continue }
            await agent.viewModel.loadProviderSnapshots(forceCatalogRefresh: true)
        }
        // The open Bot desk lists the same Distill models: Auto appears there
        // as soon as the profile is saved, not after the next desk rebuild.
        await botsViewModel?.deskAgentVM?.loadProviderSnapshots(forceCatalogRefresh: true)
        if let controller = context?.distillAccountsController {
            _ = await controller.discoverModels {
                await self.listAgentModels(provider: .distill, runAsUser: nil, forceCatalogRefresh: true)
            }
        }
    }

    /// Protocol/CommandRouting entry — probes as the app owner.
    public func listAgentProviderSnapshots() async -> [AgentProviderSnapshot] {
        await listAgentProviderSnapshots(runAsUser: nil)
    }

    /// Snapshot probe for Auto admission / Source UI. Pass `runAsUser` so binary
    /// + auth match the account Claude will actually run as through the helper.
    public func listAgentProviderSnapshots(runAsUser: AgentRunAsUser?, forceCatalogRefresh: Bool = false) async -> [AgentProviderSnapshot] {
        listAgentProviderSnapshotsCallCountForTesting += 1
        var snapshots: [AgentProviderSnapshot] = []
        let configuredInstances = providerInstanceConfigs().filter { $0.provider.isSelectable }
        if !configuredInstances.isEmpty {
            for instance in configuredInstances {
                let binary = providerBinary(instance: instance) ?? instance.provider.rawValue
                let binaryPath = Self.resolveProviderBinaryPath(binary: binary, runAsUser: runAsUser)
                let env = Self.probeEnvironment(
                    base: providerEnvironment(provider: instance.provider, instanceId: instance.id),
                    provider: instance.provider,
                    runAsUser: runAsUser
                )
                let capabilities = await providerProbeCapabilities(
                    provider: instance.provider,
                    binaryPath: binaryPath,
                    environment: env,
                    runAsUser: runAsUser
                )
                let claudeRuntime = instance.provider == .claude
                    ? ClaudeProviderRuntimePresentation.resolve(
                        agentSDKEnabled: ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_ENABLED"] != "0",
                        probeAdvisory: capabilities.advisory
                    )
                    : nil
                let grokDiscovery = instance.provider == .grok
                    ? await GrokACPAdapter(
                        binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath,
                        discoveryCwd: FileManager.default.currentDirectoryPath,
                        discoveryEnvironment: env,
                        discoveryRunAsUser: runAsUser
                    ).discoveryResult()
                    : nil
                let distillDiscovery = instance.provider == .distill
                    ? await DistillACPAdapter(
                        binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath,
                        discoveryCwd: FileManager.default.currentDirectoryPath,
                        discoveryEnvironment: env,
                        discoveryRunAsUser: runAsUser
                    ).discoveryResult(forceRefresh: forceCatalogRefresh)
                    : nil
                let models: [AgentModelDescriptor]
                let liveCatalogVerified: Bool
                if let grokDiscovery {
                    models = grokDiscovery.models
                    liveCatalogVerified = !grokDiscovery.isFallback && !grokDiscovery.models.isEmpty
                } else if let distillDiscovery {
                    models = distillDiscovery.models
                    liveCatalogVerified = !distillDiscovery.isFallback && !distillDiscovery.models.isEmpty
                } else if instance.provider == .claude {
                    let discovery = await ClaudeRunner(binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath)
                        .listModelsResult(
                            environment: env,
                            cwd: context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory(),
                            runAsUser: runAsUser
                        )
                    models = discovery.models
                    liveCatalogVerified = !discovery.isFallback && !discovery.models.isEmpty
                } else if instance.provider == .codex, !binaryPath.isEmpty {
                    let cwd = context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory()
                    let discovery = await CodexAppServerModelDiscovery.listModelsResult(
                        binary: binaryPath,
                        cwd: cwd,
                        environment: env,
                        runAsUser: runAsUser
                    )
                    if !discovery.models.isEmpty {
                        models = discovery.models
                        liveCatalogVerified = !discovery.isFallback
                    } else {
                        models = await listAgentModels(
                            provider: instance.provider,
                            installedVersion: capabilities.version,
                            binaryPath: binaryPath,
                            environment: env,
                            runAsUser: runAsUser
                        )
                        liveCatalogVerified = false
                    }
                } else {
                    models = await listAgentModels(
                        provider: instance.provider,
                        installedVersion: capabilities.version,
                        binaryPath: binaryPath,
                        environment: env,
                        runAsUser: runAsUser
                    )
                    liveCatalogVerified = false
                }
                let runtimeCapabilities = await providerRuntimeCapabilities(
                    provider: instance.provider,
                    binaryPath: binaryPath,
                    environment: env,
                    claudePresentation: claudeRuntime,
                    acpCapabilities: grokDiscovery?.capabilities ?? distillDiscovery?.capabilities
                )
                let runtimeSlashCommands = capabilities.slashCommands
                    + (runtimeCapabilities?.supportsFork == true ? ["/fork"] : [])
                let modelDiscoverySource: AgentModelDiscoverySource?
                switch instance.provider {
                case .claude, .codex:
                    modelDiscoverySource = liveCatalogVerified && runtimeCapabilities?.supportsStreaming == true
                        ? .live
                        : .builtInFallback
                case .grok:
                    modelDiscoverySource = grokDiscovery.map { $0.isFallback ? .builtInFallback : .live }
                case .distill:
                    modelDiscoverySource = distillDiscovery.map { $0.isFallback ? .builtInFallback : .live }
                }
                snapshots.append(AgentProviderSnapshotFactory.snapshot(
                    provider: instance.provider,
                    models: models,
                    binaryPath: binaryPath,
                    version: capabilities.version,
                    authenticated: capabilities.authenticated,
                    accountLabel: capabilities.accountLabel,
                    accountAuthMethod: capabilities.accountAuthMethod,
                    updateState: capabilities.updateState,
                    advisory: claudeRuntime?.advisory ?? capabilities.advisory,
                    slashCommands: runtimeSlashCommands,
                    skills: capabilities.skills,
                    id: instance.id,
                    displayName: instance.displayName,
                    accentColor: instance.accentColor,
                    enabled: instance.enabled ?? true,
                    homePath: instance.homePath,
                    // This snapshot surfaces per-instance ISOLATION keys (HOME/CODEX_HOME/
                    // REMOTE_CODE_INSTANCE). REMOTE_CODE_AGENT_PROVIDER is a constant attribution
                    // tag (same for every instance of a provider), not isolation — exclude it
                    // from the snapshot while it remains in the actual run environment.
                    environmentKeys: env.keys.filter { $0 != "REMOTE_CODE_AGENT_PROVIDER" }.sorted(),
                    interactionModesOverride: grokDiscovery?.interactionModes ?? distillDiscovery?.interactionModes ?? claudeRuntime?.interactionModes,
                    permissionModesOverride: grokDiscovery?.permissionModes ?? distillDiscovery?.permissionModes ?? claudeRuntime?.permissionModes,
                    capabilitiesOverride: runtimeCapabilities,
                    modelDiscoverySource: modelDiscoverySource,
                    modelDiscoveryCacheKey: grokDiscovery?.discoveryCacheKey ?? distillDiscovery?.discoveryCacheKey
                ))
            }
            rememberProviderSnapshotsForSend(snapshots)
            return snapshots
        }
        for provider in AgentProvider.selectable {
            let binary = configuredProviderBinary(provider) ?? provider.rawValue
            let binaryPath = Self.resolveProviderBinaryPath(binary: binary, runAsUser: runAsUser)
            let env = Self.probeEnvironment(base: [:], provider: provider, runAsUser: runAsUser)
            let capabilities = await providerProbeCapabilities(
                provider: provider,
                binaryPath: binaryPath,
                environment: env,
                runAsUser: runAsUser
            )
            let claudeRuntime = provider == .claude
                ? ClaudeProviderRuntimePresentation.resolve(
                    agentSDKEnabled: ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_ENABLED"] != "0",
                    probeAdvisory: capabilities.advisory
                )
                : nil
            let grokDiscovery = provider == .grok
                ? await GrokACPAdapter(
                    binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath,
                    discoveryCwd: FileManager.default.currentDirectoryPath,
                    discoveryEnvironment: env,
                    discoveryRunAsUser: runAsUser
                ).discoveryResult()
                : nil
            let distillDiscovery = provider == .distill
                ? await DistillACPAdapter(
                    binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath,
                    discoveryCwd: FileManager.default.currentDirectoryPath,
                    discoveryEnvironment: env,
                    discoveryRunAsUser: runAsUser
                ).discoveryResult(forceRefresh: forceCatalogRefresh)
                : nil
            let models: [AgentModelDescriptor]
            let liveCatalogVerified: Bool
            if let grokDiscovery {
                models = grokDiscovery.models
                liveCatalogVerified = !grokDiscovery.isFallback && !grokDiscovery.models.isEmpty
            } else if let distillDiscovery {
                models = distillDiscovery.models
                liveCatalogVerified = !distillDiscovery.isFallback && !distillDiscovery.models.isEmpty
            } else if provider == .claude {
                let discovery = await ClaudeRunner(binaryNameOverride: binaryPath.isEmpty ? binary : binaryPath)
                    .listModelsResult(
                        environment: env,
                        cwd: context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory(),
                        runAsUser: runAsUser
                    )
                models = discovery.models
                liveCatalogVerified = !discovery.isFallback && !discovery.models.isEmpty
            } else if provider == .codex, !binaryPath.isEmpty {
                let cwd = context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory()
                let discovery = await CodexAppServerModelDiscovery.listModelsResult(
                    binary: binaryPath,
                    cwd: cwd,
                    environment: env,
                    runAsUser: runAsUser
                )
                if !discovery.models.isEmpty {
                    models = discovery.models
                    liveCatalogVerified = !discovery.isFallback
                } else {
                    models = await listAgentModels(
                        provider: provider,
                        installedVersion: capabilities.version,
                        binaryPath: binaryPath,
                        environment: env,
                        runAsUser: runAsUser
                    )
                    liveCatalogVerified = false
                }
            } else {
                models = await listAgentModels(
                    provider: provider,
                    installedVersion: capabilities.version,
                    binaryPath: binaryPath,
                    environment: env,
                    runAsUser: runAsUser
                )
                liveCatalogVerified = false
            }
            let runtimeCapabilities = await providerRuntimeCapabilities(
                provider: provider,
                binaryPath: binaryPath,
                environment: env,
                claudePresentation: claudeRuntime,
                acpCapabilities: grokDiscovery?.capabilities ?? distillDiscovery?.capabilities
            )
            let runtimeSlashCommands = capabilities.slashCommands
                + (runtimeCapabilities?.supportsFork == true ? ["/fork"] : [])
            let modelDiscoverySource: AgentModelDiscoverySource?
            switch provider {
            case .claude, .codex:
                modelDiscoverySource = liveCatalogVerified && runtimeCapabilities?.supportsStreaming == true
                    ? .live
                    : .builtInFallback
            case .grok:
                modelDiscoverySource = grokDiscovery.map { $0.isFallback ? .builtInFallback : .live }
            case .distill:
                modelDiscoverySource = distillDiscovery.map { $0.isFallback ? .builtInFallback : .live }
            }
            snapshots.append(AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: models,
                binaryPath: binaryPath,
                version: capabilities.version,
                authenticated: capabilities.authenticated,
                accountLabel: capabilities.accountLabel,
                accountAuthMethod: capabilities.accountAuthMethod,
                updateState: capabilities.updateState,
                advisory: claudeRuntime?.advisory ?? capabilities.advisory,
                slashCommands: runtimeSlashCommands,
                skills: capabilities.skills,
                interactionModesOverride: grokDiscovery?.interactionModes ?? distillDiscovery?.interactionModes ?? claudeRuntime?.interactionModes,
                permissionModesOverride: grokDiscovery?.permissionModes ?? distillDiscovery?.permissionModes ?? claudeRuntime?.permissionModes,
                capabilitiesOverride: runtimeCapabilities,
                modelDiscoverySource: modelDiscoverySource,
                modelDiscoveryCacheKey: grokDiscovery?.discoveryCacheKey ?? distillDiscovery?.discoveryCacheKey
            ))
        }
        rememberProviderSnapshotsForSend(snapshots)
        return snapshots
    }

    private func providerRuntimeCapabilities(
        provider: AgentProvider,
        binaryPath: String,
        environment: [String: String],
        claudePresentation: ClaudeProviderRuntimePresentation?,
        acpCapabilities: AgentProviderCapabilities?
    ) async -> AgentProviderCapabilities? {
        switch provider {
        case .codex:
            return await codexRuntimeCapabilities(binaryPath: binaryPath, environment: environment)
        case .claude:
            if let degraded = claudePresentation?.capabilities { return degraded }
            return AgentProviderCapabilities(
                supportsAttachments: true,
                supportedAttachmentKinds: [.image],
                supportedAttachmentMediaTypes: ["image/jpeg", "image/png", "image/gif", "image/webp"],
                supportsApprovals: true,
                supportsUserInput: true,
                supportsStreaming: true,
                supportsFork: claudeForkProtocolSupportProbe(),
                supportsRollback: false,
                supportsPlanReview: true
            )
        case .grok, .distill:
            return acpCapabilities
        }
    }

    private func codexRuntimeCapabilities(
        binaryPath: String,
        environment: [String: String]
    ) async -> AgentProviderCapabilities {
        let probe = codexForkProtocolSupportProbe
        let supportsFork = await ProviderCLIProbe.runOffCooperativePool {
            probe(binaryPath, environment)
        }
        return AgentProviderCapabilities(
            supportsAttachments: true,
            supportedAttachmentKinds: [.file, .image],
            supportedAttachmentMediaTypes: ["*/*", "image/jpeg", "image/png", "image/gif", "image/webp"],
            supportsApprovals: true,
            supportsUserInput: true,
            supportsStreaming: true,
            supportsFork: supportsFork,
            supportsRollback: true,
            supportsPlanReview: true
        )
    }

    private func listAgentModels(
        provider: AgentProvider,
        installedVersion: String?,
        binaryPath: String,
        environment: [String: String],
        runAsUser: AgentRunAsUser? = nil
    ) async -> [AgentModelDescriptor] {
        switch provider {
        case .codex:
            if !binaryPath.isEmpty {
                let cwd = context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory()
                let appServerModels = await CodexAppServerModelDiscovery.listModels(
                    binary: binaryPath,
                    cwd: cwd,
                    environment: environment,
                    runAsUser: runAsUser
                )
                if !appServerModels.isEmpty {
                    return appServerModels
                }
            }
            return await listAgentModels(provider: provider, runAsUser: runAsUser)
        case .claude:
            return await ClaudeRunner(binaryNameOverride: binaryPath.isEmpty ? nil : binaryPath)
                .listModelsResult(
                    environment: environment,
                    cwd: context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory(),
                    runAsUser: runAsUser
                ).models
        case .grok:
            return GrokRunner.listModels(installedVersion: installedVersion)
        case .distill:
            return await DistillACPAdapter(
                binaryNameOverride: binaryPath.isEmpty ? nil : binaryPath,
                discoveryEnvironment: environment,
                discoveryRunAsUser: runAsUser
            ).listModels()
        }
    }

    /// CLI auth/version probes spawn `Process` and block until exit. Must not
    /// run under `@MainActor` (the Agent App send path awaits snapshot loads
    /// through this router). Cache hits stay on MainActor; misses hop to a
    /// detached task and only the dictionary write returns to MainActor.
    private func providerProbeCapabilities(
        provider: AgentProvider,
        binaryPath: String,
        environment: [String: String],
        runAsUser: AgentRunAsUser? = nil
    ) async -> ProviderProbeCapabilities {
        // Cache key includes the run-as-user so airtonempat and airtonjunior
        // never share a stale authenticated flag.
        let runAsKey = runAsUser.map { "\($0.uid):\($0.shortName)" } ?? "self"
        let key = ProviderProbeCacheKey(
            provider: provider,
            binaryPath: binaryPath + "#runas=\(runAsKey)",
            environment: environment
        )
        let now = Date()
        if let cached = providerProbeCache[key],
           now.timeIntervalSince(cached.capturedAt) < providerProbeCacheTTL {
            return cached
        }
        // Foreign identity: probe via the installed helper (same as spawn).
        // Avoids HOME-only false "not authenticated" that blocked Auto while
        // Manual spawn performs the one-time helper installation if needed.
        let skillsRoot = Self.providerSkillsRoot(
            provider: provider,
            environment: environment,
            defaultHome: FileManager.default.homeDirectoryForCurrentUser.path
        )
        let capabilities = await ProviderCLIProbe.runOffCooperativePool {
            let auth = ProviderCLIProbe.authStatus(
                provider: provider,
                binaryPath: binaryPath,
                environment: environment,
                runAsUser: runAsUser
            )
            let version = ProviderCLIProbe.versionStatus(binaryPath: binaryPath, environment: environment)
            return ProviderProbeCapabilities(
                version: version.version,
                authenticated: auth.authenticated,
                accountLabel: auth.accountLabel,
                accountAuthMethod: auth.accountAuthMethod,
                updateState: version.updateState,
                advisory: version.advisory,
                slashCommands: ProviderCLIProbe.slashCommands(
                    provider: provider,
                    binaryPath: binaryPath,
                    environment: environment
                ),
                skills: Self.discoverSkillNames(in: skillsRoot),
                capturedAt: now
            )
        }
        Self.noteProviderProbeCacheEntry(
            &providerProbeCache,
            key: key,
            value: capabilities
        )
        return capabilities
    }

    /// Pure insert/evict for the in-memory provider CLI probe cache.
    /// Keeps `key`; drops arbitrary other keys when over `countLimit`.
    /// Extracted for unit tests (TTL still applied by the call site on read).
    nonisolated static func noteProviderProbeCacheEntry<Key: Hashable, Value>(
        _ cache: inout [Key: Value],
        key: Key,
        value: Value,
        countLimit: Int = providerProbeCacheCountLimit
    ) {
        cache[key] = value
        let cap = max(1, countLimit)
        while cache.count > cap {
            if let victim = cache.keys.first(where: { $0 != key }) ?? cache.keys.first {
                cache.removeValue(forKey: victim)
            } else {
                break
            }
        }
    }

    private func providerSkills(provider: AgentProvider, environment: [String: String]) -> [String] {
        Self.discoverSkillNames(in: Self.providerSkillsRoot(
            provider: provider,
            environment: environment,
            defaultHome: FileManager.default.homeDirectoryForCurrentUser.path
        ))
    }

    nonisolated static func providerSkillsRoot(
        provider: AgentProvider,
        environment: [String: String],
        defaultHome: String
    ) -> URL {
        switch provider {
        case .codex:
            let root = environment["CODEX_HOME"]
                ?? URL(fileURLWithPath: defaultHome, isDirectory: true).appendingPathComponent(".codex", isDirectory: true).path
            return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("skills", isDirectory: true)
        case .claude:
            let home = environment["HOME"] ?? defaultHome
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude/skills", isDirectory: true)
        case .grok:
            if let root = environment["GROK_HOME"], !root.isEmpty {
                return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("skills", isDirectory: true)
            }
            let home = environment["HOME"] ?? defaultHome
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".grok/skills", isDirectory: true)
        case .distill:
            return DistillProvisioner.homeURL(
                environment: environment,
                userHome: environment["HOME"] ?? defaultHome
            ).appendingPathComponent("skills", isDirectory: true)
        }
    }

    nonisolated private static func discoverSkillNames(in root: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let names = entries.compactMap { url -> String? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let skillFile = url.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else { return nil }
            return url.lastPathComponent
        }
        return Array(Set(names)).sorted()
    }

    /// `updateAgentProvider` fails with this code while the same update runs.
    static let providerUpdateAlreadyRunningCode = -32041

    /// The binary and environment `updateAgentProvider` updates; nil when the
    /// CLI is not installed.
    func providerUpdateTarget(
        provider: AgentProvider, instanceId: String?
    ) -> (binaryPath: String, environment: [String: String])? {
        let binary = providerBinary(provider: provider, instanceId: instanceId) ?? provider.rawValue
        let binaryPath = (provider == .distill
            ? ProcessLocator.resolveDistillAgent(binary)
            : ProcessLocator.resolve(binary)) ?? ""
        guard !binaryPath.isEmpty else { return nil }
        return (binaryPath, providerEnvironment(provider: provider, instanceId: instanceId))
    }

    public func updateAgentProvider(provider: AgentProvider, providerInstanceId: String?) async throws -> JSONValue {
        try await updateAgentProvider(
            provider: provider, providerInstanceId: providerInstanceId, timeoutSeconds: 120, announcesFailure: true
        )
    }

    /// `timeoutSeconds` bounds the provider's `update` process; its tree is
    /// killed on expiry. `announcesFailure` false returns a failed update
    /// without publishing it: the event raises a "Provider update failed"
    /// alert, which is for an update the user asked for.
    func updateAgentProvider(
        provider: AgentProvider, providerInstanceId: String?, timeoutSeconds: TimeInterval, announcesFailure: Bool
    ) async throws -> JSONValue {
        guard let (binaryPath, env) = providerUpdateTarget(provider: provider, instanceId: providerInstanceId) else {
            throw JSONRPCError(code: -32040, message: "\(provider.rawValue) CLI binary is unavailable.")
        }
        let key = ProviderProbeCacheKey(provider: provider, binaryPath: binaryPath, environment: env)
        guard !providerUpdateLocks.contains(key) else {
            throw JSONRPCError(
                code: Self.providerUpdateAlreadyRunningCode, message: "\(provider.rawValue) update is already running."
            )
        }
        providerUpdateLocks.insert(key)
        defer { providerUpdateLocks.remove(key) }

        let result = await ProviderCLIProbe.runOffCooperativePool {
            ProviderCLIProbe.update(
                provider: provider, binaryPath: binaryPath, environment: env, timeoutSeconds: timeoutSeconds
            )
        }
        providerProbeCache.removeValue(forKey: key)
        let response = JSONValue.object([
            "provider": .string(provider.rawValue),
            "provider_instance_id": providerInstanceId.map { .string($0) } ?? .null,
            "binary_path": .string(binaryPath),
            "ok": .bool(result.ok),
            "status": .number(Double(result.status)),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr)
        ])
        if result.ok || announcesFailure {
            EventBus.shared.publish(kind: .agentProviderUpdated, payload: .object([
                "provider": .string(provider.rawValue),
                "ok": .bool(result.ok),
                "status": .number(Double(result.status))
            ]))
        }
        return response
    }

    public func agentPromptHistory(workspace: WorkspaceID?, limit: Int) throws -> [String] {
        guard let ctx = context else { throw NSError(domain: "rc2", code: 0) }
        // Resolve workspace: prefer explicit param, fall back to the currently
        // selected workspace. If neither is available (no workspace open yet),
        // return an empty list -- do not error, matching the iOS client's
        // empty-history graceful-fallback behaviour.
        let wid = workspace ?? ctx.state.window.selectedWorkspaceID
        guard let wid else { return [] }
        let store = PromptHistoryStore(db: ctx.db)
        let history = store.load(workspaceID: wid)
        // store.load returns oldest-first (chronological append order).
        // iOS expects most-recent-first (newest at index 0).
        let capped = Array(history.suffix(limit))
        return capped.reversed()
    }

    private func providerInstanceConfigs() -> [AgentProviderInstanceConfig] {
        guard let raw = try? context?.settingsRepo.get("agent.provider.instances")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? settingsJSONDecoder.decode([AgentProviderInstanceConfig].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return decoded.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted }
    }

    private func providerInstanceConfig(id: String?, provider: AgentProvider) -> AgentProviderInstanceConfig? {
        let instances = providerInstanceConfigs().filter { $0.provider == provider }
        guard !instances.isEmpty else { return nil }
        if let id, let exact = instances.first(where: { $0.id == id }) { return exact }
        return instances.first { $0.enabled != false } ?? instances.first
    }

    private func normalizedProviderInstanceId(provider: AgentProvider, requested: String?) -> String {
        providerInstanceConfig(id: requested, provider: provider)?.id ?? provider.rawValue
    }

    private func providerBinary(instance: AgentProviderInstanceConfig) -> String? {
        let configured = instance.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty { return configured }
        return configuredProviderBinary(instance.provider)
    }

    func providerBinary(provider: AgentProvider, instanceId: String?) -> String? {
        if let instance = providerInstanceConfig(id: instanceId, provider: provider) {
            return providerBinary(instance: instance)
        }
        return configuredProviderBinary(provider)
    }

    func providerEnvironment(
        provider: AgentProvider,
        instanceId: String?,
        threadId: AgentThreadID? = nil
    ) -> [String: String] {
        let instance = providerInstanceConfig(id: instanceId, provider: provider)
        var env = instance?.env ?? [:]
        let home = instance?.homePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !home.isEmpty {
            switch provider {
            case .codex:
                env["CODEX_HOME"] = env["CODEX_HOME"] ?? home
            case .claude:
                env["HOME"] = env["HOME"] ?? home
            case .grok:
                env["GROK_HOME"] = env["GROK_HOME"] ?? home
            case .distill:
                env["DISTILL_HOME"] = env["DISTILL_HOME"] ?? home
            }
        }
        // Tag the agent's environment with the provider so child tooling (provider
        // proxies, subagent telemetry) attributes work to claude/codex/grok instead
        // of "unknown". Set unconditionally — even with no instance config.
        env["REMOTE_CODE_AGENT_PROVIDER"] = provider.rawValue
        if let context, let threadId {
            let telemetryEnv = context.subagentTelemetryEnvironment(
                provider: provider,
                threadId: threadId,
                baseEnvironment: env
            )
            env.merge(telemetryEnv) { _, new in new }
            // Nested provider proxies (`grok`/`claude`/`codex` in managed bin) must
            // resolve for every thread-scoped provider environment.
            let managedBin = env["RC_REMOTE_CODE_MANAGED_BIN"]
                ?? AgentSkillInstaller.defaultManagedCLIBinDirectory().path
            let basePath = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            // Drop any optimization keys an older build left in the inherited
            // environment, then put managed bin back first on PATH so nested
            // provider proxies + Subagents telemetry work.
            var cleaned = Self.scrubProviderEnvironment(env)
            cleaned["PATH"] = Self.providerPathWithManagedWrappers(
                currentPath: cleaned["PATH"] ?? basePath,
                managedBin: managedBin
            )
            return applyDesktopChildEnvironment(cleaned, threadId: threadId, context: context)
        } else {
            // No thread context: keep provider tag only; no managed bin on PATH.
            return Self.scrubProviderEnvironment(env)
        }
    }

    /// Docker-with-GUI child: stub macos-harness and hide host docker. Other
    /// kinds pass through. Applied after PATH is finalized so stubs win.
    private func applyDesktopChildEnvironment(
        _ env: [String: String],
        threadId: AgentThreadID,
        context: AppContext
    ) -> [String: String] {
        guard let conversation = try? context.botStore.conversationLinked(to: threadId),
              let bot = try? context.botStore.get(id: conversation.botID),
              let revisionID = bot.currentRevisionID,
              let revision = try? context.botStore.getRevision(id: revisionID) else {
            return env
        }
        let stub = context.appSupportDirectory
            .appendingPathComponent("bot-desktop-stubs", isDirectory: true)
            .appendingPathComponent(revision.desktopKind.rawValue, isDirectory: true)
        return BotDesktopChildEnvironment.apply(
            kind: revision.desktopKind,
            env: env,
            stubDirectory: stub
        )
    }

    /// Drops the keys the removed Token Saver / Graphify / Distill compression
    /// lanes read (nothing sets them any more, but a value inherited from an
    /// older build's environment must never reach a provider) and the managed
    /// bin from PATH. No-thread contexts use it as is (no nested provider
    /// interception without thread scope); thread-scoped paths put managed bin
    /// back first so provider proxies stay available.
    nonisolated static func scrubProviderEnvironment(_ env: [String: String]) -> [String: String] {
        AgentHostEnvironmentMerge.scrubLegacyOptimizationKeys(env)
    }

    /// Prepends the managed CLI bin (`~/.remote-code/bin`) so nested provider proxies
    /// win PATH lookup inside the provider process. Host top-level launches use absolute binaries via
    /// `ProcessLocator` and skip provider proxy shims.
    static func providerPathWithManagedWrappers(currentPath: String, managedBin: String) -> String {
        let trimmed = managedBin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return currentPath }
        // PERF: single pass avoids the map + filter intermediates on the
        // pre-turn PATH build; joined PATH identical (empty segments preserved).
        var parts: [String] = []
        for part in currentPath.split(separator: ":", omittingEmptySubsequences: false) where part != trimmed {
            parts.append(String(part))
        }
        return ([trimmed] + parts).joined(separator: ":")
    }

    private func configuredProviderBinary(_ provider: AgentProvider) -> String? {
        let key: String
        switch provider {
        case .codex: key = "cli.codex.path"
        case .claude: key = "cli.claude.path"
        case .grok: key = "cli.grok.path"
        case .distill: key = "cli.distill.path"
        }
        guard let value = try? context?.settingsRepo.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: git (socket/CLI parity — same engine the diff panel uses)

    private func workspaceCwd(_ id: WorkspaceID) throws -> String {
        guard let cwd = context?.state.workspaces[id]?.cwd else { throw LayoutError.workspaceNotFound }
        return cwd
    }

    private func fileTabInfo(workspace: WorkspaceID, path: String) throws -> (relativePath: String, title: String) {
        let read = try WorkspaceFileService().read(root: try workspaceCwd(workspace), path: path, maxBytes: 0)
        guard let object = read.objectValue,
              let relativePath = object["relative_path"]?.stringValue else {
            throw JSONRPCError(code: -32602, message: "file path unavailable", data: .string(path))
        }
        let title = (relativePath as NSString).lastPathComponent
        return (relativePath, title.isEmpty ? "Files" : title)
    }

    public func gitStatus(workspace: WorkspaceID) throws -> GitSummary {
        guard let summary = GitDiff.summary(in: try workspaceCwd(workspace)) else {
            throw JSONRPCError(code: -32000, message: GitDiff.summaryTimedOutMessage)
        }
        return summary
    }
    public func gitBranches(workspace: WorkspaceID) throws -> GitBranches {
        GitDiff.branches(in: try workspaceCwd(workspace))
    }
    public func gitCheckout(workspace: WorkspaceID, branch: String) throws -> GitActionResult {
        GitDiff.checkout(in: try workspaceCwd(workspace), branch: branch)
    }
    public func gitCreateBranch(workspace: WorkspaceID, name: String) throws -> GitActionResult {
        GitDiff.createBranch(in: try workspaceCwd(workspace), name: name)
    }
    public func gitCommit(workspace: WorkspaceID, message: String) throws -> GitActionResult {
        GitDiff.commit(in: try workspaceCwd(workspace), message: message)
    }
    public func gitLog(workspace: WorkspaceID, limit: Int) throws -> [GitCommit] {
        GitDiff.log(in: try workspaceCwd(workspace), limit: limit)
    }
    public func gitDiff(workspace: WorkspaceID, path: String?, ignoreWhitespace: Bool) throws -> String {
        GitDiff.diff(in: try workspaceCwd(workspace), path: path, ignoreWhitespace: ignoreWhitespace)
    }
    public func gitPush(workspace: WorkspaceID) throws -> GitActionResult {
        GitDiff.push(in: try workspaceCwd(workspace))
    }
    public func gitPullRequestURL(workspace: WorkspaceID) throws -> String? {
        GitDiff.pullRequestURL(in: try workspaceCwd(workspace))
    }
    public func gitDeliveryPlan(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryPlan {
        GitDiff.deliveryPlan(in: try workspaceCwd(workspace), copy: copy)
    }
    public func gitDeliver(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryResult {
        GitDiff.deliver(in: try workspaceCwd(workspace), copy: copy, environment: nil)
    }

    public func uploadAgentAttachment(workspace: WorkspaceID, filename: String, mimeType: String?, dataBase64: String) throws -> AgentAttachmentUploadResult {
        guard let decodedSize = Self.decodedBase64Size(dataBase64),
              decodedSize <= AgentAttachmentStore.maximumSizeBytes else {
            throw JSONRPCError(code: -32602, message: "Attachment exceeds the 25 MB limit or has invalid data.")
        }
        guard let data = Data(base64Encoded: dataBase64), !data.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Invalid attachment data.")
        }
        let safeName = Self.safeAttachmentFilename(filename)
        let metadata = try Self.uploadAttachmentMetadata(filename: safeName, mimeType: mimeType)
        let attachment = try agentAttachmentStore().stage(
            data: data,
            displayName: safeName,
            kind: metadata.kind,
            mimeType: metadata.mimeType
        )
        guard let reference = AgentAttachmentReference(attachment) else {
            throw JSONRPCError(code: -32000, message: "Attachment staging produced incomplete metadata.")
        }
        // iOS (and other paired clients) insert this host path into the composer
        // as ordinary text — same UX as macOS Finder drop/paste. Prefer a
        // display-name hardlink so the path keeps a recognizable filename.
        let insertionPath = (try? Self.composerInsertionPath(for: attachment, store: agentAttachmentStore()))
            ?? attachment.path
        return AgentAttachmentUploadResult(reference, composerInsertionText: insertionPath)
    }

    /// Message lookup and file/image work both run off the main actor.
    public func getAgentAttachment(_ request: AgentAttachmentGetWire.Request) async throws -> JSONValue {
        let store = try agentAttachmentStore()
        let message = try await agentAppReadGateway.message(id: request.messageID)
        return try await Task.detached(priority: .userInitiated) {
            try AgentAttachmentGetWire.load(request, message: message, store: store)
        }.value
    }

    /// Message lookup on the read gateway; file checks, decode and encode off
    /// the main actor.
    public func getAgentMessageImage(_ request: AgentMessageImageGetWire.Request) async throws -> JSONValue {
        let message = try await agentAppReadGateway.message(id: request.messageID)
        return try await Task.detached(priority: .userInitiated) {
            try AgentMessageImageGetWire.load(request, message: message)
        }.value
    }

    /// Reads the stored usage file off the main actor; never probes a provider.
    public func getAgentAccountUsage() async throws -> JSONValue {
        guard let directory = context?.appSupportDirectory else {
            throw JSONRPCError.notSupported("agent.account.usage.get")
        }
        return await Task.detached(priority: .userInitiated) {
            AgentAccountUsageWire.load(appSupportDirectory: directory)
        }.value
    }

    public func importAgentAttachment(workspace: WorkspaceID, relativePath: String) throws -> AgentAttachmentUploadResult {
        let raw = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.split(separator: "/").contains("..") else {
            throw JSONRPCError(code: -32602, message: "Attachment import path must be workspace-relative.")
        }
        let root = URL(fileURLWithPath: try workspaceCwd(workspace))
            .standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(raw)
            .standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var isDirectory: ObjCBool = false
        guard target.path.hasPrefix(prefix),
              FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: target.path) else {
            throw JSONRPCError(code: -32602, message: "Attachment import target is not a readable workspace file.")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        if let size = (attributes?[.size] as? NSNumber)?.int64Value,
           size > Int64(AgentAttachmentStore.maximumSizeBytes) {
            throw JSONRPCError(code: -32602, message: "Attachment exceeds the 25 MB limit.")
        }
        // Prefer the original workspace path for composer insertion so agents
        // see a stable project path. Still stage a managed copy for any legacy
        // structured-attachment consumers of the opaque id.
        let attachment = try agentAttachmentStore().stage(path: target.path)
        guard let reference = AgentAttachmentReference(attachment) else {
            throw JSONRPCError(code: -32000, message: "Attachment import produced incomplete metadata.")
        }
        return AgentAttachmentUploadResult(reference, composerInsertionText: target.path)
    }

    private func agentAttachmentStore() throws -> AgentAttachmentStore {
        guard let context else { throw LayoutError.workspaceNotFound }
        return AgentAttachmentStore(
            root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
        )
    }

    /// Hardlink the content-addressed blob under a display-name path so paired
    /// clients can insert a human-recognizable absolute path into the composer.
    private static func composerInsertionPath(
        for attachment: AgentAttachment,
        store: AgentAttachmentStore
    ) throws -> String {
        let name = attachment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("\0") else {
            return attachment.path
        }
        let id = (attachment.id ?? attachment.sha256 ?? UUID().uuidString)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !id.isEmpty else { return attachment.path }
        let linkRoot = store.root
            .appendingPathComponent("composer-paths", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let link = linkRoot.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: link.path) {
            try FileManager.default.linkItem(atPath: attachment.path, toPath: link.path)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: link.path
            )
        }
        return link.path
    }

    private static func decodedBase64Size(_ value: String) -> Int? {
        let bytes = value.utf8
        let count = bytes.count
        guard count > 0, count.isMultiple(of: 4) else { return nil }
        let maximumEncodedCount = ((AgentAttachmentStore.maximumSizeBytes + 2) / 3) * 4
        guard count <= maximumEncodedCount else { return nil }
        var padding = 0
        if bytes.last == 61 { padding += 1 }
        if count > 1, bytes[bytes.index(bytes.endIndex, offsetBy: -2)] == 61 { padding += 1 }
        return (count / 4) * 3 - padding
    }

    private func resolveInboundAgentAttachments(_ attachments: [AgentAttachment]) throws -> [AgentAttachment] {
        try attachments.map { attachment in
            if attachment.path.isEmpty {
                return try agentAttachmentStore().resolveClientReference(attachment)
            }
            return try agentAttachmentStore().validatedForRetry(attachment)
        }
    }

    // PERF: compile once — was recompiled via range(of:options:.regularExpression)
    // on every attachment upload metadata validate (same contract as
    // AgentAttachmentStore / AttachmentUploadV2).
    private static let uploadAttachmentMIMETypeRegex = try! NSRegularExpression(
        pattern: #"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$"#
    )

    private static func uploadAttachmentMetadata(filename: String, mimeType: String?) throws -> (kind: AgentAttachmentKind, mimeType: String?) {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg", "avif"])
        let inferredImage = imageExtensions.contains(ext)
        let normalized = mimeType?.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalized {
            let full = NSRange(location: 0, length: (normalized as NSString).length)
            if uploadAttachmentMIMETypeRegex.firstMatch(in: normalized, options: [], range: full) == nil {
                throw JSONRPCError(code: -32602, message: "Invalid attachment media type.")
            }
        }
        let declaredImage = normalized?.hasPrefix("image/") == true
        guard normalized == nil || inferredImage == declaredImage else {
            throw JSONRPCError(code: -32602, message: "Attachment filename and media type disagree.")
        }
        let inferredMIME: String?
        switch ext {
        case "png": inferredMIME = "image/png"
        case "jpg", "jpeg": inferredMIME = "image/jpeg"
        case "gif": inferredMIME = "image/gif"
        case "webp": inferredMIME = "image/webp"
        case "md", "markdown": inferredMIME = "text/markdown"
        case "json": inferredMIME = "application/json"
        case "txt", "log", "csv": inferredMIME = "text/plain"
        case "pdf": inferredMIME = "application/pdf"
        default: inferredMIME = nil
        }
        guard normalized == nil || inferredMIME == nil || normalized == inferredMIME else {
            throw JSONRPCError(code: -32602, message: "Attachment filename and media type disagree.")
        }
        return (inferredImage ? .image : .file, normalized ?? inferredMIME)
    }

    private static func safeAttachmentFilename(_ filename: String) -> String {
        let raw = URL(fileURLWithPath: filename).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = raw.isEmpty ? "attachment" : raw
        let safe = fallback.map { char in
            char.isLetter || char.isNumber || ".-_ ".contains(char) ? char : "-"
        }
        let result = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "attachment" : String(result.prefix(120))
    }

    // MARK: project scripts / open-in-editor (RC2-069)

    public func projectScripts(workspace: WorkspaceID) throws -> [ProjectScript] {
        ProjectScripts.discover(in: try workspaceCwd(workspace))
    }

    public func projectRunScript(workspace: WorkspaceID, name: String) throws -> SurfaceDescriptor {
        let cwd = try workspaceCwd(workspace)
        guard let script = ProjectScripts.discover(in: cwd).first(where: { $0.name == name }) else {
            throw JSONRPCError(code: -32602, message: "no such script: \(name)")
        }
        // Run it in a fresh terminal surface (t3code ProjectScriptsControl).
        let desc = try createSurface(workspace: workspace, type: .terminal, paneID: nil, title: "Run: \(name)")
        guard let context, let terminal = SurfaceRegistry.shared.surface(desc.id) as? TerminalSurface else {
            throw LayoutError.surfaceNotFound
        }
        context.projectScriptRuns.register(workspaceID: workspace, surfaceID: desc.id, name: name)
        EventBus.shared.publish(kind: .projectScriptStarted, payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "surface_id": .string(desc.id.value.uuidString),
            "name": .string(name)
        ]))
        terminal.sendText(Self.projectScriptTerminalInput(command: script.command))
        return desc
    }

    static func projectScriptTerminalInput(command: String) -> String {
        "exec \(command)\n"
    }

    public func projectOpenInEditor(workspace: WorkspaceID) throws -> String {
        try ProjectScripts.openInEditor(cwd: try workspaceCwd(workspace))
    }

    private func browserSurface(_ id: SurfaceID) throws -> BrowserSurface {
        guard let s = SurfaceRegistry.shared.surface(id) as? BrowserSurface else { throw LayoutError.surfaceNotFound }
        return s
    }

    private func configureBrowserSurface(_ browser: BrowserSurface, workspace: WorkspaceID) -> BrowserSurface {
        browser.onBusyStateChanged = { [weak self, weak browser] busy in
            guard let self, let browser else { return }
            self.surfaceBusyDidChange(workspace: workspace, surface: browser.descriptor.id, busy: busy)
        }
        browser.onNavigationChange = { [weak self] surfaceID, url, title in
            self?.persistBrowserNavigation(surfaceID: surfaceID, url: url, title: title)
            let fields = BotBrowserHostState.makePayload(surfaceID: surfaceID, url: url, title: title)
            var payload: [String: JSONValue] = [:]
            for (key, value) in fields {
                payload[key] = .string(value)
            }
            EventBus.shared.publish(kind: .surfaceBrowser, payload: .object(payload))
        }
        browser.onHTTPCookiesCaptured = { [weak self] surfaceID, cookies, url, title in
            self?.persistBotBrowserCookies(surfaceID: surfaceID, cookies: cookies, url: url, title: title)
        }
        return browser
    }

    private func surfaceBusyDidChange(workspace: WorkspaceID, surface: SurfaceID, busy: Bool) {
        publishWorkspaceUpdated(workspace, metadata: Self.workspaceBusyMetadata(isWorkspaceBusy(workspace)))
        windowController?.activeThreadsDidChange()
        if shouldPublishLayoutEvents {
            EventBus.shared.publish(
                kind: .surfaceUpdated,
                payload: Self.surfaceBusyPayload(workspace: workspace, surface: surface, busy: busy)
            )
        }
    }

    private func configureSSHBusy(_ ssh: SSHSurface, workspace: WorkspaceID) {
        ssh.onBusyStateChanged = { [weak self, weak ssh] busy in
            guard let self, let ssh else { return }
            self.surfaceBusyDidChange(workspace: workspace, surface: ssh.descriptor.id, busy: busy)
        }
    }

    private func configureTerminalSurface(
        _ terminal: TerminalSurface,
        workspace: WorkspaceID
    ) -> TerminalSurface {
        if terminal.descriptor.type == .terminal {
            terminal.onRestartRequested = { [weak self, weak terminal] in
                guard let self, let terminal else { return }
                self.restartSurface(terminal.descriptor.id)
            }
            terminal.refreshRestartActionForCurrentHealth()
        }
        terminal.onBusyFinished = { [weak self, weak terminal] title, body, userIsLooking in
            guard let self, let terminal, !userIsLooking else { return }
            let surfaceID = terminal.descriptor.id
            try? self.context?.apply(.markUnread(workspace, surfaceID, true))
            self.windowController?.refreshFromState()
            _ = try? self.notificationCreate(
                workspaceId: workspace,
                surfaceId: surfaceID,
                title: title,
                body: body,
                category: "terminal"
            )
        }
        terminal.onBusyStateChanged = { [weak self, weak terminal] busy in
            guard let self, let terminal else { return }
            self.surfaceBusyDidChange(workspace: workspace, surface: terminal.descriptor.id, busy: busy)
        }
        terminal.onBecameFocused = { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            let surfaceID = terminal.descriptor.id
            guard let layout = self.context?.state.workspaces[workspace]?.layout,
                  self.findSurface(surfaceID, in: layout)?.hasUnreadActivity == true else { return }
            try? self.context?.apply(.markUnread(workspace, surfaceID, false))
            self.windowController?.refreshFromState()
        }
        terminal.onTitleChange = { [weak self, weak terminal] title in
            guard let self, let terminal else { return }
            let surfaceID = terminal.descriptor.id
            self.terminalTitleCoalescer.submit(surfaceID, title: title) { [weak self] latest in
                self?.commitTerminalTitle(workspace: workspace, surfaceID: surfaceID, title: latest)
            }
        }
        return terminal
    }

    /// H3: commits terminal titles still inside the throttle window, so the
    /// final snapshot before quit or update holds the newest title.
    func flushPendingTerminalTitles() {
        terminalTitleCoalescer.flushAll()
    }

    /// H3: a normalized terminal title change. Persists through one layout apply
    /// (one debounced snapshot save) and patches only the tab label -- no window
    /// refresh. Unchanged titles and surfaces that closed meanwhile are dropped.
    private func commitTerminalTitle(workspace: WorkspaceID, surfaceID: SurfaceID, title: String) {
        guard SurfaceRegistry.shared.surface(surfaceID) != nil else {
            terminalTitleCoalescer.cancel(surfaceID)
            return
        }
        if let layout = context?.state.workspaces[workspace]?.layout,
           findSurface(surfaceID, in: layout)?.title == title {
            return
        }
        do {
            try context?.apply(.renameSurface(workspace, surfaceID, title))
        } catch {
            NSLog(
                "RemoteCode terminal title persistence failed surface=%@ error=%@",
                surfaceID.value.uuidString,
                String(describing: error)
            )
            return
        }
        windowController?.updateSurfaceTabTitle(surfaceID, title: title)
        EventBus.shared.publish(kind: .surfaceRenamed, payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surfaceID.value.uuidString),
            "title": .string(title)
        ]))
    }

    private func restoredBrowserURL(from descriptor: SurfaceDescriptor) -> URL? {
        guard let raw = descriptor.metadata["url"], !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func persistBrowserNavigation(surfaceID: SurfaceID, url: String, title: String?) {
        guard let ctx = context else { return }
        for (wid, var ws) in ctx.state.workspaces {
            var botID: BotID?
            let result = updateSurface(in: ws.layout, surfaceID: surfaceID) { descriptor in
                descriptor.metadata["url"] = url
                if let title, !title.isEmpty {
                    descriptor.title = title
                }
                if let raw = descriptor.metadata["bot_id"], let uuid = UUID(uuidString: raw) {
                    botID = BotID(uuid)
                }
            }
            guard result.changed else { continue }
            ws.layout = result.node
            ws.updatedAt = Date()
            ctx.state.workspaces[wid] = ws
            ctx.scheduleSnapshotSave()
            if let botID {
                let store = BotBrowserStore(appSupportDirectory: ctx.appSupportDirectory)
                try? store.persistTarget(BotBrowserTarget(url: url, title: title ?? ""), botID: botID)
            }
            return
        }
    }

    func persistBotBrowserCookies(surfaceID: SurfaceID, cookies: [HTTPCookie], url: String, title: String?) {
        guard let ctx = context else { return }
        for (_, ws) in ctx.state.workspaces {
            var botID: BotID?
            forEachSurface(in: ws.layout) { descriptor in
                guard descriptor.id == surfaceID,
                      let raw = descriptor.metadata["bot_id"],
                      let uuid = UUID(uuidString: raw) else { return }
                botID = BotID(uuid)
            }
            if let botID {
                let store = BotBrowserStore(appSupportDirectory: ctx.appSupportDirectory)
                let state = BotBrowserPageState.fromHTTPCookies(cookies, url: url, title: title ?? "")
                try? store.persistPageState(state, botID: botID)
                return
            }
        }
    }

    /// Open or retarget this bot's browser. Last URL/title persist by bot id.
    /// Bots never get a RemoteCode in-app browser tab: logical-space bots use
    /// the native headless Chrome bridge.
    @discardableResult
    public func openBotBrowser(botID: BotID, url: String, title: String? = nil) throws -> BotBrowserTarget {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let store = BotBrowserStore(appSupportDirectory: ctx.appSupportDirectory)
        let service = BotBrowserService(callerBotID: botID, store: store)
        let target = try service.persistNavigation(url: url, title: title)
        let route = try botBrowserRoute(botID: botID)
        if case .refused(let message) = route {
            throw BotBrowserError.invalid(message)
        }
        // This legacy lane has no result channel, so the navigate is
        // fire-and-forget off-main; failures NSLog. Result-carrying opens go
        // through performBotBrowserPendingAction instead.
        scheduleBotBrowserBridgeNavigate(botID: botID, route: route, target: target)
        return target
    }

    /// Which executor serves this bot's browser. Same desktop-kind lookup as
    /// reconcileBotComputerActions; no published revision resolves to refused.
    private func botBrowserRoute(botID: BotID, threadID: AgentThreadID? = nil) throws -> BotBrowserRoute {
        guard let ctx = context,
              let bot = try ctx.botStore.get(id: botID),
              let revisionID = bot.currentRevisionID,
              let revision = try ctx.botStore.getRevision(id: revisionID) else {
            return .refused(BotBrowserRoute.refusedMessage)
        }
        if let threadID, let destination = try ctx.botStore.threadExecutionDestination(threadID) {
            if destination.target == .vm { return .playwrightGuest }
            if revision.desktopKind == .dockerDesktop { return .refused(BotBrowserRoute.refusedMessage) }
        }
        return BotBrowserRoute.forPublished(revision.desktopKind)
    }

    /// Docker route only: resume-or-create the bot's guest before the bridge
    /// spawns `docker exec`. Built like reconcileBotComputerActions builds it.
    /// Returned closure runs OFF-main (docker CLI work must never block MainActor).
    private func botBrowserGuestEnsure(route: BotBrowserRoute, botID: BotID, appSupport: URL, resourceID: BotID? = nil, threadID: AgentThreadID? = nil) -> (@Sendable () throws -> Void)? {
        guard route == .playwrightGuest else { return nil }
        if let fake = botBrowserGuestEnsureForTesting {
            return { try fake(botID) }
        }
        let service = BotComputerGuestService(
            appSupport: appSupport,
            docker: BotComputerDockerCLI(),
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL()
        )
        return {
            let resource = resourceID ?? botID
            if let holder = BotVMRunRegistry.shared.blocker(botID: resource, threadID: threadID) {
                throw BotComputerError.invalid("The VM is busy in \(holder.title)")
            }
            // Runs share the VM: never recreate the container under them.
            if BotVMRunRegistry.shared.active(botID: resource) != nil, service.isContainerRunning(botID: resource) { return }
            _ = try service.provision(botID: resource, requestingThreadID: threadID)
        }
    }

    private func scheduleBotBrowserBridgeNavigate(botID: BotID, route: BotBrowserRoute, target: BotBrowserTarget) {
        guard let ctx = context else { return }
        let appSupport = ctx.appSupportDirectory
        let bridge = botBrowserBridge
        let resourceID: BotID
        do { resourceID = route == .playwrightGuest ? try ctx.botStore.guestResourceID(botID: botID) : botID }
        catch { return }
        let mirroredBots = route == .playwrightGuest
            ? ((try? ctx.botStore.list()) ?? []).filter { (try? ctx.botStore.guestResourceID(botID: $0.id)) == resourceID }.map(\.id) : []
        let ensureGuest = botBrowserGuestEnsure(route: route, botID: botID, appSupport: appSupport, resourceID: resourceID)
        Task.detached(priority: .utility) {
            do {
                try ensureGuest?()
                let payload = try bridge.perform(
                    botID: resourceID,
                    route: route,
                    kind: BotBrowserCatalog.open,
                    action: "",
                    ref: "",
                    text: "",
                    url: target.url,
                    appSupport: appSupport
                )
                Self.persistBotBrowserBridgePageState(payload: payload, botID: botID, appSupport: appSupport, mirroredBots: mirroredBots)
            } catch {
                NSLog(
                    "RemoteCode bot browser navigate failed bot=%@ error=%@",
                    botID.value.uuidString,
                    String(describing: error)
                )
            }
        }
    }

    /// Mirror the bridge-reported page into the store so `bot_browser_get`
    /// and the login-wait fallback stay truthful. Cookies stay whatever the
    /// store already holds (Playwright lanes feed none; legacy tabs may).
    nonisolated private static func persistBotBrowserBridgePageState(
        payload: [String: Any],
        botID: BotID,
        appSupport: URL,
        mirroredBots: [BotID] = []
    ) {
        let url = payload["url"] as? String ?? ""
        guard !url.isEmpty else { return }
        let title = payload["title"] as? String ?? ""
        let store = BotBrowserStore(appSupportDirectory: appSupport)
        for destinationBot in Set(mirroredBots + [botID]) {
        try? store.persistTarget(BotBrowserTarget(url: url, title: title), botID: destinationBot)
        let cookies = (try? store.readWebsiteData(botID: destinationBot)) ?? [:]
        try? store.persistPageState(
            BotBrowserPageState(
                url: url,
                title: title,
                cookies: cookies,
                loading: payload["loading"] as? Bool
            ),
            botID: destinationBot
        )
        EventBus.shared.publish(kind: .botBrowserUpdated, payload: .object([
            "bot_id": .string(destinationBot.value.uuidString.lowercased()),
            "url": .string(url), "title": .string(title), "method": .string("browser.state")
        ]))
        }
    }

    /// Drain MCP pending open/snapshot/act/state commands onto this bot's
    /// app-owned Playwright MCP child.
    public func reconcileBotBrowserActions() async {
        guard let ctx = context else { return }
        let store = BotBrowserStore(appSupportDirectory: ctx.appSupportDirectory)
        let pending = (try? store.takePendingActions()) ?? []
        for item in pending {
            guard let uuid = UUID(uuidString: item.botID) else { continue }
            let botID = BotID(uuid)
            do {
                let payload = try await performBotBrowserPendingAction(botID: botID, action: item)
                try store.writeActionResult(
                    BotBrowserActionResult(id: item.id, botID: item.botID, payload: payload, error: "")
                )
            } catch {
                try? store.writeActionResult(
                    BotBrowserActionResult(
                        id: item.id,
                        botID: item.botID,
                        payload: "",
                        error: String(describing: error)
                    )
                )
            }
        }
    }

    nonisolated private static var botBrowserRefusalPayload: String {
        let data = try? JSONSerialization.data(withJSONObject: ["refusal": ManualActionRequest.refusalPhrase])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func performBotBrowserPendingAction(
        botID: BotID,
        action: BotBrowserPendingAction
    ) async throws -> String {
        guard let ctx = context else {
            throw BotBrowserError.invalid("Bot browser is not available. Keep the MacCode app running and try again.")
        }
        let threadID = action.threadID.flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
        let resourceID = try ctx.botStore.guestResourceID(botID: botID, threadID: threadID)
        if let holder = BotVMRunRegistry.shared.blocker(botID: resourceID, threadID: threadID) {
            throw BotBrowserError.invalid("The VM is busy in \(holder.title)")
        }
        if action.kind == BotBrowserCatalog.act, botComputerControl.isControlledByUser(botID, resourceID: resourceID) {
            return Self.botBrowserRefusalPayload
        }
        let route = try botBrowserRoute(botID: botID, threadID: threadID)
        if case .refused(let message) = route {
            throw BotBrowserError.invalid(message)
        }
        let supportedKinds: Set<String> = [
            BotBrowserCatalog.open,
            BotBrowserCatalog.snapshot,
            BotBrowserCatalog.act,
            BotBrowserCatalog.stateKind,
        ]
        guard supportedKinds.contains(action.kind) else {
            throw BotBrowserError.invalid("unknown bot browser action kind: \(action.kind)")
        }
        let appSupport = ctx.appSupportDirectory
        if action.kind == BotBrowserCatalog.stateKind, action.action == BotBrowserCatalog.waitLoginAction {
            let openedURL = (try? BotBrowserStore(appSupportDirectory: appSupport).loadTarget(botID: botID))?.url ?? ""
            let callerThread = action.threadID.flatMap { UUID(uuidString: $0) }.map { AgentThreadID($0) }
            ManualActionHost.request(
                control: botComputerControl,
                botID: botID,
                threadID: callerThread
                    ?? botActiveThreadResolverForTesting?(botID)
                    ?? ((try? ctx.botStore.listConversations(botID: botID)) ?? []).lazy
                        .compactMap(\.linkedAgentThreadID).first,
                kind: .login,
                reason: BotBrowserLoginWait.userPrompt(url: openedURL),
                screenshotPNG: nil,
                threadIsFallback: callerThread == nil
            )
        }
        if action.kind == BotBrowserCatalog.open {
            // Same URL validation + persist rule the old surface path applied.
            _ = try BotBrowserService(callerBotID: botID, store: BotBrowserStore(appSupportDirectory: appSupport))
                .persistNavigation(url: action.url, title: action.title.isEmpty ? nil : action.title)
        }
        let bridge = botBrowserBridge
        let mirroredBots = route == .playwrightGuest
            ? ((try? ctx.botStore.list()) ?? []).filter { (try? ctx.botStore.guestResourceID(botID: $0.id)) == resourceID }.map(\.id) : []
        let ensureGuest = botBrowserGuestEnsure(route: route, botID: botID, appSupport: appSupport, resourceID: resourceID, threadID: threadID)
        let control = botComputerControl
        let beforeAct = botBrowserBeforeBridgeActForTesting
        // Guest provisioning (docker CLI) and child-process IO must never run
        // on MainActor — hop to a utility queue and await the result.
        let payload: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try ensureGuest?()
                    beforeAct?()
                    // Provisioning can take seconds; the user may have taken control meanwhile.
                    if action.kind == BotBrowserCatalog.act, control.isControlledByUser(botID, resourceID: resourceID) {
                        continuation.resume(returning: Self.botBrowserRefusalPayload)
                        return
                    }
                    let payload = try bridge.perform(
                        botID: route == .playwrightGuest ? resourceID : botID,
                        route: route,
                        kind: action.kind,
                        action: action.action,
                        ref: action.ref,
                        text: action.text,
                        url: action.url,
                        appSupport: appSupport
                    )
                    Self.persistBotBrowserBridgePageState(payload: payload, botID: botID, appSupport: appSupport, mirroredBots: mirroredBots)
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "{}")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        if action.kind == BotBrowserCatalog.act, route == .playwrightGuest, payload != Self.botBrowserRefusalPayload {
            publishGuestAgentStep(botID: botID, step: "browser_act")
        }
        return payload
    }

    /// Drain MCP pending guest observe/act through the app-process Docker CLI.
    public func reconcileBotComputerActions() {
        guard let ctx = context else { return }
        guard !botComputerReconciliationScheduled else { return }
        botComputerReconciliationScheduled = true
        let appSupport = ctx.appSupportDirectory
        let botStore = ctx.botStore
        // The worker and its step hops live for one drain pass only (no cycle).
        let worker = botComputerReconciliationWorkerForTesting ?? {
            Self.reconcileBotComputerActions(appSupport: appSupport, botStore: botStore) { botID, step in
                Task { @MainActor in self.publishGuestAgentStep(botID: botID, step: step) }
            }
        }
        botComputerReconciliationQueue.async { [weak self] in
            worker()
            DispatchQueue.main.async {
                guard let self else { return }
                self.botComputerReconciliationScheduled = false
                if Self.hasPendingBotComputerActions(appSupport: appSupport) {
                    self.reconcileBotComputerActions()
                }
            }
        }
    }

    nonisolated private static let botComputerActionLanes = BotComputerActionLanes(
        label: "io.remotecode.bot-computer-action"
    )

    nonisolated private static func reconcileBotComputerActions(
        appSupport: URL,
        botStore: BotStore,
        onGuestStep: @escaping @Sendable (BotID, String) -> Void
    ) {
        let store = BotComputerStore(appSupportDirectory: appSupport)
        let service = BotComputerGuestService(
            appSupport: appSupport,
            docker: BotComputerDockerCLI(),
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL()
        )
        // The drain only hands actions to per-bot lanes and returns; a bot's
        // long exec or rebuild runs on that bot's lane alone.
        while true {
            let count = (try? BotComputerHost.dispatchPending(store: store, lanes: botComputerActionLanes) { action in
                guard let uuid = UUID(uuidString: action.botID) else {
                    throw BotComputerError.invalid("Invalid bot id.")
                }
                let botID = BotID(uuid)
                let threadID = action.threadID.flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
                let pinnedVM = try threadID.flatMap { try botStore.threadExecutionDestination($0) }?.target == .vm
                guard let bot = try botStore.get(id: botID),
                      let revisionID = bot.currentRevisionID,
                      let revision = try botStore.getRevision(id: revisionID),
                      pinnedVM || BotDesktopAdmission.forPublished(revision.desktopKind).allowsGuestComputer else {
                    throw BotComputerError.notDockerDesktop
                }
                let resourceID = try botStore.guestResourceID(botID: botID, threadID: threadID)
                let result = try service.apply(action, resourceID: resourceID)
                if result["refusal"] == nil {
                    switch action.kind {
                    case BotComputerCatalog.act: onGuestStep(botID, "act")
                    case BotComputerCatalog.exec: onGuestStep(botID, "exec")
                    default: break
                    }
                }
                return result
            }) ?? 0
            guard count > 0 else { return }
        }
    }

    nonisolated private static func hasPendingBotComputerActions(appSupport: URL) -> Bool {
        (try? BotComputerStore(appSupportDirectory: appSupport).hasPendingActions()) == true
    }

    /// Drain legacy MCP pending opens through the same `openBotBrowser`
    /// bridge path tests drive. This lane has no result channel, so a
    /// kind-refused or invalid open is skipped with an NSLog, never a surface.
    @discardableResult
    public func reconcileBotBrowserOpens() throws -> [BotBrowserTarget] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let store = BotBrowserStore(appSupportDirectory: ctx.appSupportDirectory)
        var applied: [BotBrowserTarget] = []
        for item in try store.takePendingOpens() {
            guard let uuid = UUID(uuidString: item.botID) else { continue }
            do {
                applied.append(
                    try openBotBrowser(
                        botID: BotID(uuid),
                        url: item.url,
                        title: item.title.isEmpty ? nil : item.title
                    )
                )
            } catch {
                NSLog(
                    "RemoteCode bot browser pending open skipped bot=%@ error=%@",
                    item.botID,
                    String(describing: error)
                )
            }
        }
        return applied
    }

    /// Persist a per-surface agent thread binding into the surface descriptor
    /// metadata (`selected_thread`), mirroring the browser-URL persistence path.
    /// This is what makes app restart restore each agent tab to its OWN thread
    /// instead of every tab converging on threads.first.
    func persistAgentSelectedThread(surfaceID: SurfaceID, threadID: AgentThreadID?) {
        guard let ctx = context else { return }
        // Process-only retention authority: cap victim selection must not delete
        // a thread currently bound in an open Agent App surface.
        ctx.threadRepo.setLiveSurfaceBinding(surfaceID: surfaceID, threadID: threadID)
        for (wid, var ws) in ctx.state.workspaces {
            let result = updateSurface(in: ws.layout, surfaceID: surfaceID) { descriptor in
                if let threadID {
                    descriptor.metadata["selected_thread"] = threadID.value.uuidString
                } else {
                    descriptor.metadata.removeValue(forKey: "selected_thread")
                }
            }
            guard result.changed else { continue }
            ws.layout = result.node
            ctx.state.workspaces[wid] = ws
            ctx.scheduleSnapshotSave()
            // Mirror the rebind: layout metadata mutations publish no event of
            // their own, so a mounted remote mirror of this surface would never
            // follow the mac-side thread selection. Shape matches the
            // surface.set_color emitter (Dispatcher "surface.updated"); an
            // empty selected_thread clears the binding on the client.
            EventBus.shared.publish(kind: .surfaceUpdated, payload: .object([
                "workspace_id": .string(wid.value.uuidString),
                "id": .string(surfaceID.value.uuidString),
                "surface_id": .string(surfaceID.value.uuidString),
                "metadata": .object(["selected_thread": .string(threadID?.value.uuidString ?? "")])
            ]))
            return
        }
    }

    private func updateSurface(in node: LayoutNode,
                               surfaceID: SurfaceID,
                               _ update: (inout SurfaceDescriptor) -> Void) -> (node: LayoutNode, changed: Bool) {
        switch node {
        case .pane(var pane):
            guard let index = pane.surfaces.firstIndex(where: { $0.id == surfaceID }) else {
                return (node, false)
            }
            update(&pane.surfaces[index])
            return (.pane(pane), true)
        case .split(var split):
            var changed = false
            split.children = split.children.map { child in
                guard !changed else { return child }
                let result = updateSurface(in: child, surfaceID: surfaceID, update)
                changed = result.changed
                return result.node
            }
            return (.split(split), changed)
        }
    }

    public func browserNavigate(surface: SurfaceID, url: String) throws {
        let b = try browserSurface(surface)
        if !b.navigate(string: url) { throw LayoutError.invalidLayout }
    }
    public func browserBack(surface: SurfaceID) throws { try browserSurface(surface).goBackAction() }
    public func browserForward(surface: SurfaceID) throws { try browserSurface(surface).goForwardAction() }
    public func browserReload(surface: SurfaceID) throws { try browserSurface(surface).reloadAction() }
    public func browserStop(surface: SurfaceID) throws { try browserSurface(surface).stopLoadingAction() }
    public func browserURL(surface: SurfaceID) throws -> String { try browserSurface(surface).currentURL() }
    public func browserMirrorURL(surface: SurfaceID) throws -> [String: JSONValue] {
        let raw = try browserSurface(surface).currentURL()
        var out: [String: JSONValue] = ["url": .string(raw), "is_file": .bool(false)]
        if let url = URL(string: raw), url.isFileURL,
           let grant = DirectStaticFileRegistry.shared.register(fileURL: url) {
            out["is_file"] = .bool(true)
            out["static_path"] = .string(grant.routePath)
        }
        return out
    }

    public func browserEval(surface: SurfaceID, script: String) async throws -> String {
        let s = try browserSurface(surface)
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            s.evaluate(script) { result, error in
                if let error = error {
                    cont.resume(returning: "error: \(error.localizedDescription)")
                } else if let result = result {
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
                       let s = String(data: data, encoding: .utf8) {
                        cont.resume(returning: s)
                    } else {
                        cont.resume(returning: String(describing: result))
                    }
                } else {
                    cont.resume(returning: "")
                }
            }
        }
    }

    static func hostBrowserScreenshotSurface(
        in surfaces: [SurfaceDescriptor], requested: SurfaceID?
    ) throws -> SurfaceID {
        let browsers = surfaces.filter { $0.type == .browser }
        if let requested {
            guard browsers.contains(where: { $0.id == requested }) else {
                throw JSONRPCError(code: -32047, message: "Browser surface does not belong to this conversation's workspace.")
            }
            return requested
        }
        guard browsers.count == 1, let browser = browsers.first else {
            throw JSONRPCError(
                code: -32044,
                message: browsers.isEmpty
                    ? "No browser is open in this conversation's workspace."
                    : "Choose a browser surface_id before capturing: " + browsers.map { "\($0.title) (\($0.id.value.uuidString))" }.joined(separator: ", ")
            )
        }
        return browser.id
    }

    public func captureHostBrowserToChat(
        callerThread: AgentThreadID, surface: SurfaceID?, reason: String
    ) throws -> JSONValue {
        guard let ctx = context else {
            throw DefiniteMutationRejection(JSONRPCError(code: -32044, message: "MacCode is unavailable."))
        }
        let selected: SurfaceID
        do {
            guard let thread = try ctx.threadRepo.get(id: callerThread),
                  let workspaceID = thread.workspaceId,
                  let workspace = ctx.state.workspaces[workspaceID] else {
                throw JSONRPCError(code: -32044, message: "This conversation has no Mac browser workspace.")
            }
            guard try ctx.threadRepo.guestPlacement(of: callerThread)?.runsInGuest != true else {
                throw JSONRPCError(code: -32052, message: "Capturing the Mac browser requires running this conversation on the Mac.")
            }
            guard !reason.isEmpty, reason.count <= 500 else { throw JSONRPCError.invalidParams }
            var surfaces: [SurfaceDescriptor] = []
            forEachSurface(in: workspace.layout) { surfaces.append($0) }
            selected = try Self.hostBrowserScreenshotSurface(in: surfaces, requested: surface)
        } catch {
            throw DefiniteMutationRejection(error)
        }
        let data: Data
        do {
            let path = try browserScreenshot(surface: selected, savePath: nil)
            let url = URL(fileURLWithPath: path)
            defer { try? FileManager.default.removeItem(at: url) }
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resource.isRegularFile == true,
                  let size = resource.fileSize, size > 0,
                  size <= AgentAttachmentStore.maximumSizeBytes else {
                throw JSONRPCError(code: -32044, message: "Browser screenshot exceeds the image attachment limit.")
            }
            data = try Data(contentsOf: url)
        } catch {
            throw DefiniteMutationRejection(error)
        }
        let published = try publishAssistantImage(
            threadID: callerThread, data: data, displayName: "mac-browser-screenshot.png",
            mimeType: "image/png", content: "Mac browser: \(reason)"
        )
        return .object([
            "thread_id": .string(callerThread.value.uuidString),
            "message_id": .string(published.message.id.value.uuidString),
            "attachment_id": .string(published.attachmentID),
            "surface_id": .string(selected.value.uuidString),
            "origin": .string("mac_browser")
        ])
    }

    public func browserScreenshot(surface: SurfaceID, savePath: String?) throws -> String {
        let s = try browserSurface(surface)
        guard let png = s.screenshotPNG() else { throw LayoutError.invalidLayout }
        let path = savePath ?? (NSTemporaryDirectory() + "rc2-screenshot-\(UUID().uuidString).png")
        try png.write(to: URL(fileURLWithPath: path))
        return path
    }

    public func browserSnapshot(surface: SurfaceID) async throws -> String {
        let s = try browserSurface(surface)
        return await withCheckedContinuation { cont in
            s.snapshot { json in cont.resume(returning: json) }
        }
    }

    public func browserAction(surface: SurfaceID, kind: String, ref: String, value: String?) async throws -> String {
        let s = try browserSurface(surface)
        return await withCheckedContinuation { cont in
            s.performAction(kind, ref: ref, value: value) { json in cont.resume(returning: json) }
        }
    }

    public func paneList(workspace: WorkspaceID) throws -> [[String: JSONValue]] {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else { return [] }
        let mobileGroups = mobilePaneGroups(in: ws.layout)
        var mobileGroupByPane: [PaneID: Int] = [:]
        for (index, group) in mobileGroups.enumerated() {
            for paneID in group { mobileGroupByPane[paneID] = index }
        }
        let panes: [[String: JSONValue]] = ws.layout.paneIDs().map { pid in
            let pane = ws.layout.find(paneID: pid)
            let count = pane?.surfaces.count ?? 0
            let selectedSurfaceID = pane.flatMap { pane in
                pane.selectedSurfaceID.flatMap { selected in
                    pane.surfaces.contains(where: { $0.id == selected }) ? selected : nil
                } ?? pane.surfaces.first?.id
            }
            return [
                "kind": .string("pane"),
                "id": .string(pid.value.uuidString),
                "surface_count": .number(Double(count)),
                "surface_ids": .array((pane?.surfaces ?? []).map { .string($0.id.value.uuidString) }),
                "selected_surface_id": selectedSurfaceID.map { .string($0.value.uuidString) } ?? .null,
                "mobile_group": .number(Double(mobileGroupByPane[pid] ?? 0))
            ]
        }
        let splits = splitEntries(in: ws.layout)
        return panes + splits
    }

    private func mobilePaneGroups(in node: LayoutNode) -> [[PaneID]] {
        let groups = uncappedMobilePaneGroups(in: node)
        guard groups.count > 2 else { return groups }
        return [groups[0], groups.dropFirst().flatMap { $0 }]
    }

    private func uncappedMobilePaneGroups(in node: LayoutNode) -> [[PaneID]] {
        switch node {
        case .pane(let pane):
            return [[pane.id]]
        case .split(let split):
            let childGroups = split.children.flatMap { uncappedMobilePaneGroups(in: $0) }
            switch split.orientation {
            case .horizontal:
                return [childGroups.flatMap { $0 }]
            case .vertical:
                return childGroups
            }
        }
    }

    private func splitEntries(in node: LayoutNode) -> [[String: JSONValue]] {
        switch node {
        case .pane:
            return []
        case .split(let split):
            var rows: [[String: JSONValue]] = [[
                "kind": .string("split"),
                "id": .string(split.id.uuidString),
                "orientation": .string(split.orientation.rawValue),
                "ratios": .array(split.ratios.map { .number($0) })
            ]]
            rows.append(contentsOf: split.children.flatMap { splitEntries(in: $0) })
            return rows
        }
    }

    public func paneSurfaces(pane: PaneID, workspace: WorkspaceID) throws -> [SurfaceDescriptor] {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else { return [] }
        return (ws.layout.find(paneID: pane)?.surfaces ?? []).map(Self.clientSurfaceDescriptor)
    }

    /// Client-facing copy: live surface busy is injected at read time, never persisted.
    static func clientSurfaceDescriptor(_ descriptor: SurfaceDescriptor) -> SurfaceDescriptor {
        guard descriptor.type != .agentApp,
              SurfaceRegistry.shared.surface(descriptor.id)?.isBusy == true else { return descriptor }
        var copy = descriptor
        copy.metadata["busy"] = "true"
        return copy
    }

    public func paneResize(workspace: WorkspaceID, splitID: UUID, ratios: [Double]) throws {
        try context?.apply(.resizeSplit(workspace, splitID: splitID, ratios: ratios))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneResized(workspace: workspace, splitID: splitID)
    }

    public func surfaceMove(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID) throws {
        try context?.apply(.moveSurfaceToPane(workspace, surface: surface, targetPane: targetPane))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceMoved(workspace: workspace, surface: surface, targetPane: targetPane)
    }

    public func surfaceReorder(workspace: WorkspaceID, surface: SurfaceID, toPane: PaneID, position: Int) throws {
        try context?.apply(.reorderSurface(workspace, surface: surface, toPane: toPane, position: position))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceReordered(workspace: workspace, surface: surface, targetPane: toPane, position: position)
    }

    public func openWorkspaceInNewWindow(_ workspace: WorkspaceID) {
        windowController?.openWorkspaceInNewWindow(workspace)
    }

    public func openBotInNewWindow(_ bot: BotID) {
        windowController?.openBotInNewWindow(bot)
    }

    public func openBotGuestDesktopInNewWindow(_ bot: BotID) {
        windowController?.openBotGuestDesktopInNewWindow(bot)
    }

    var activityWorkspaceOptions: [(id: String, name: String)] {
        context?.state.workspaces.values.map { ($0.id.value.uuidString, $0.name) } ?? []
    }

    /// Same color the sidebar paints the workspace folder with.
    func activityWorkspaceColor(_ id: String) -> Color? {
        guard let uuid = UUID(uuidString: id),
              let workspace = context?.state.workspaces[WorkspaceID(uuid)] else { return nil }
        return TabColor.from(workspace.metadata["color"]).map { Color(hex: $0.hex) }
    }

    /// In-memory, so Activity rows can ask on every render; `openAgentThread` checks the same.
    func activityWorkspaceIsOpen(_ id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return context?.state.workspaces[WorkspaceID(uuid)] != nil
    }

    public func activityList(params: [String: JSONValue]) throws -> JSONValue {
        guard let context else { throw LayoutError.workspaceNotFound }
        return try ActivityService(context: context).list(params)
    }

    public func activityListOffMain(params: [String: JSONValue]) async throws -> JSONValue {
        guard let context else { throw JSONRPCError.internalError }
        return try await agentAppReadGateway.listActivity(service: ActivityService(context: context), params: params)
    }

    func activityCountsOffMain() async throws -> (global: AgentActivityCounts, byWorkspace: [String: AgentActivityCounts]) {
        guard let context else { throw JSONRPCError.internalError }
        return try await agentAppReadGateway.activityCounts(service: ActivityService(context: context))
    }

    /// The full projection takes seconds on large histories; on the main actor it
    /// froze the app and every RPC behind it. The service snapshots main-actor
    /// state here and the projection runs on the read gateway queue.
    private func observeActivityChangesOffMain(_ context: AppContext) {
        let service = ActivityService(context: context)
        let gateway = agentAppReadGateway
        Task.detached(priority: .utility) { _ = try? await gateway.activityCounts(service: service) }
    }

    public func activitySetViewed(params: [String: JSONValue]) throws -> JSONValue {
        guard let context else { throw LayoutError.workspaceNotFound }
        let result = try ActivityService(context: context).setViewed(params)
        observeActivityChangesOffMain(context)
        let ids = result.objectValue?["updated_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !ids.isEmpty {
            EventBus.shared.publish(kind: .notificationRead, payload: .object([
                "id": .string("activity:\(ids[0])"),
                "activity_item_ids": .array(ids.map(JSONValue.string)),
                "reason": .string("viewed")
            ]))
        }
        return result
    }

    public func activityAcknowledge(params: [String: JSONValue]) throws -> JSONValue {
        guard let context else { throw LayoutError.workspaceNotFound }
        let result = try ActivityService(context: context).acknowledge(params)
        observeActivityChangesOffMain(context)
        let acknowledged = result.objectValue?["acknowledged"]?.boolValue == true
        let ids = result.objectValue?["item_id"]?.stringValue.map { [$0] }
            ?? result.objectValue?["updated_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !ids.isEmpty {
            EventBus.shared.publish(kind: .notificationRead, payload: .object([
                "id": .string("activity:\(ids[0])"), "activity_item_ids": .array(ids.map(JSONValue.string)),
                "reason": .string(acknowledged ? "acknowledged" : "reopened")
            ]))
            if ids.contains(where: { $0.hasPrefix("bot-attention:") }) {
                EventBus.shared.publish(kind: .botsAttentionChanged, payload: .object([:]))
            }
        }
        return result
    }

    public func notificationCreate(
        workspaceId: WorkspaceID?,
        surfaceId: SurfaceID? = nil,
        title: String,
        body: String?,
        category: String?
    ) throws -> String {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let repo = NotificationRepository(db: ctx.db)
        let n = AppNotification(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            title: title,
            body: body,
            category: category
        )
        try repo.insert(n)
        // bump workspace unread + flash
        if let wid = workspaceId, var ws = ctx.state.workspaces[wid] {
            ws.notificationsUnread += 1
            ctx.state.workspaces[wid] = ws
            windowController?.refreshFromState()
        }
        // Mirror into macOS notification center, or as a Titio notice (§5 "External").
        let titioNoticeKey: String?
        if ctx.titioNoticeCenter.isEnabled(SettingsStore(db: ctx.db).load()) {
            titioNoticeKey = TitioNoticeIDs.externalNotification(id: n.id)
            ctx.titioNoticeCenter.ingest(TitioNoticeFact(
                key: TitioNoticeIDs.externalNotification(id: n.id),
                kind: .external,
                source: TitioNoticeSource(workspaceId: workspaceId?.value.uuidString, notificationId: n.id),
                facts: TitioNoticeFacts(title: title, body: body)
            ))
        } else {
            titioNoticeKey = nil
            SystemNotifier.shared.post(
                SystemNotifier.legacyContent(title: title, body: body, category: category),
                settings: SettingsStore(db: ctx.db).load()
            )
        }
        var eventPayload: [String: JSONValue] = [
            "id": .string(n.id),
            "soundEnabled": .bool(SettingsStore(db: ctx.db).load().notificationSoundEnabled)
        ]
        // Titio owns the phone alert and retries relay failures from its ledger.
        // This key selects that path; it is not proof of OS presentation.
        // Without a push target the phone schedules its own local notification.
        if let titioNoticeKey, ctx.privateNotificationBridge.hasAlertPushTarget {
            eventPayload["titio_notice_key"] = .string(titioNoticeKey)
        }
        if let workspaceId { eventPayload["workspace_id"] = .string(workspaceId.value.uuidString) }
        if let surfaceId { eventPayload["surface_id"] = .string(surfaceId.value.uuidString) }
        if let category { eventPayload["category"] = .string(category) }
        EventBus.shared.publish(kind: .notificationCreated, payload: .object(eventPayload))
        return n.id
    }

    public func notificationList(workspaceId: WorkspaceID?, unreadOnly: Bool) throws -> [[String: JSONValue]] {
        guard let ctx = context else { return [] }
        let repo = NotificationRepository(db: ctx.db)
        let botMetadata = BotAttentionNotificationMetadataStore(db: ctx.db)
        let botMetadataByID = botMetadata.all()
        let list = try repo.list(workspaceId: workspaceId, unreadOnly: unreadOnly)
        return list.map { n in
            var d: [String: JSONValue] = [
                "id": .string(n.id),
                "title": .string(n.title),
                "created_at": .string(iso8601Formatter.string(from: n.createdAt))
            ]
            if let b = n.body { d["body"] = .string(b) }
            if let c = n.category { d["category"] = .string(c) }
            if let w = n.workspaceId { d["workspace_id"] = .string(w.value.uuidString) }
            if let s = n.surfaceId { d["surface_id"] = .string(s.value.uuidString) }
            if let r = n.readAt { d["read_at"] = .string(iso8601Formatter.string(from: r)) }
            if let metadata = botMetadataByID[n.id] {
                for (key, value) in metadata.fields { d[key] = .string(value) }
            }
            d["push_policy"] = .string("background_only")
            return d
        }
    }

    public func notificationMarkRead(id: String) throws {
        guard let ctx = context else { return }
        try NotificationRepository(db: ctx.db).markRead(id: id)
        EventBus.shared.publish(kind: .notificationRead, payload: .object(["id": .string(id)]))
    }

    public func notificationDismiss(id: String) throws {
        guard let ctx = context else { return }
        try NotificationRepository(db: ctx.db).dismiss(id: id)
        EventBus.shared.publish(kind: .notificationDismissed, payload: .object(["id": .string(id)]))
    }

    public func privatePushTokenUpdate(
        pushToken: String,
        pushTokenType: String,
        liveActivityToken: String?,
        deviceID: String?,
        tokenPurpose: String? = nil,
        environment: String? = nil,
        serverID: String? = nil,
        bootEpoch: Int? = nil,
        activityGeneration: Int? = nil,
        activityID: String? = nil,
        activitySessionID: String? = nil,
        registrationRevision: Int? = nil,
        contractVersion: Int? = nil,
        capabilities: [String]? = nil
    ) throws -> JSONValue {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let store = PrivatePushTargetStore(repo: ctx.settingsRepo)
        var ownership: LiveActivityTokenOwnership?
        if let tokenPurpose,
           let purpose = PrivatePushTokenPurpose(rawValue: tokenPurpose),
           let environment,
           let pushEnvironment = PrivatePushEnvironment(rawValue: environment),
           let deviceID,
           let serverID {
            let token = purpose == .alert ? pushToken : (liveActivityToken ?? pushToken)
            let target = PrivatePushTargetRecord(
                deviceId: deviceID,
                serverId: serverID,
                purpose: purpose,
                environment: pushEnvironment,
                token: token,
                activityGeneration: activityGeneration.flatMap { $0 >= 0 ? UInt64($0) : nil },
                activityId: activityID,
                bootEpoch: bootEpoch.flatMap { $0 >= 0 ? UInt64($0) : nil },
                activitySessionId: activitySessionID,
                contractVersion: contractVersion ?? 1,
                capabilities: capabilities
            )
            if target.supportsLiveActivityV2 {
                let bound = try ctx.liveActivitySyncCoordinator.submitTokenRegistration(target)
                guard purpose != .activityUpdate || bound.ownership != nil else {
                    throw LiveActivityTokenBindingError.unknownAuthoritativeScope
                }
                try store.upsert(bound)
                ownership = bound.ownership
            } else {
                try store.upsert(target)
            }
        }
        // Persist the legacy target before answering ok: iOS must not believe a
        // push registration landed when the settings write failed.
        try store.save(
            pushToken: pushToken,
            pushTokenType: pushTokenType,
            liveActivityToken: liveActivityToken,
            deviceId: deviceID
        )
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "push_token_type": .string(pushTokenType)
        ]
        if let registrationRevision {
            result["registration_revision"] = .number(Double(registrationRevision))
        }
        if let ownership {
            result["ownership"] = .object([
                "activity_id": .string(ownership.activityId),
                "host_id": .string(ownership.hostId),
                "boot_epoch": .number(Double(ownership.bootEpoch)),
                "activity_generation": .number(Double(ownership.activityGeneration)),
                "activity_session_id": .string(ownership.activitySessionId)
            ])
        }
        return .object(result)
    }

    public func bindBotAttentionProfile(profileID: String, hostID: String, deviceID: String) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try BotAttentionPushBindingStore(db: ctx.db).bind(
            profileID: profileID,
            hostID: hostID,
            deviceID: deviceID
        )
    }

    /// Reads on the WAL reader so a reconnect's unchanged push token never waits
    /// behind a long writer transaction. Any read failure answers false and the
    /// request takes the full durable path.
    public func privatePushRegistrationIsCurrent(_ probe: PrivatePushRegistrationProbe) -> Bool {
        guard let ctx = context else { return false }
        let store = PrivatePushTargetStore(repo: SettingsRepository(db: ctx.readDB))
        guard store.legacyTargetMatches(
            pushToken: probe.pushToken,
            pushTokenType: probe.pushTokenType,
            liveActivityToken: probe.liveActivityToken,
            deviceId: probe.deviceID
        ) else { return false }
        if let alert = probe.alert {
            guard let deviceID = probe.deviceID,
                  let environment = PrivatePushEnvironment(rawValue: alert.environment),
                  store.containsCurrentRecord(PrivatePushTargetRecord(
                      deviceId: deviceID,
                      serverId: alert.serverID,
                      purpose: .alert,
                      environment: environment,
                      token: probe.pushToken,
                      contractVersion: alert.contractVersion,
                      capabilities: alert.capabilities
                  )) else { return false }
        }
        if let binding = probe.profileBinding {
            guard BotAttentionPushBindingStore(db: ctx.readDB).contains(
                profileID: binding.profileID,
                hostID: binding.hostID,
                deviceID: binding.deviceID
            ) else { return false }
        }
        return true
    }

    public func settingsGet(keys: [String]) throws -> [String: String] {
        guard let ctx = context else { return [:] }
        var values: [String: String] = [:]
        for key in keys {
            // `titio_language` lives inside the AppSettings blob, not as its own row.
            if key == TitioLanguageSetting.wireKey {
                values[key] = SettingsStore(db: ctx.db).load().titioLanguage
                continue
            }
            values[key] = (try? ctx.settingsRepo.get(key)) ?? ""
        }
        return values
    }

    public func settingsSet(key: String, value: String) throws {
        guard let ctx = context else { return }
        if key == TitioLanguageSetting.wireKey {
            // `auto` or a well-formed BCP-47 tag, else invalidParams: a bad
            // value must never reach Titio's prompts.
            guard let tag = TitioLanguageSetting.normalized(value) else { throw JSONRPCError.invalidParams }
            let store = SettingsStore(db: ctx.db)
            var failure: Error?
            store.onWriteError = { failure = $0 }
            store.update { $0.titioLanguage = tag }
            if let failure { throw failure }
            return
        }
        try ctx.settingsRepo.set(key, value)
    }

    public func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue {
        try WorkspaceFileService().list(root: try workspaceCwd(workspace), path: path)
    }

    public func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue {
        try WorkspaceFileService().read(root: try workspaceCwd(workspace), path: path, maxBytes: maxBytes)
    }

    public func fsWorkspacePreviewURL(workspace: WorkspaceID, path: String) throws -> JSONValue {
        try WorkspaceFileService().previewURL(root: try workspaceCwd(workspace), path: path)
    }

    public func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue {
        try WorkspaceFileService().createFile(root: try workspaceCwd(workspace), path: path, content: content)
    }

    public func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue {
        try WorkspaceFileService().rename(root: try workspaceCwd(workspace), path: path, newName: newName)
    }

    public func fsWorkspaceDelete(workspace: WorkspaceID, paths: [String]) throws -> JSONValue {
        try WorkspaceFileService().delete(root: try workspaceCwd(workspace), paths: paths)
    }

    public func fsWorkspaceCreateDirectory(workspace: WorkspaceID, path: String) throws -> JSONValue {
        try WorkspaceFileService().createDirectory(root: try workspaceCwd(workspace), path: path)
    }

    public func fsWorkspaceMoveItem(workspace: WorkspaceID, sourcePath: String, destinationDirectoryPath: String) throws -> JSONValue {
        try WorkspaceFileService().moveItem(root: try workspaceCwd(workspace), sourcePath: sourcePath, destinationDirectoryPath: destinationDirectoryPath)
    }

    public func filesStateGet(surface: SurfaceID) throws -> JSONValue {
        let located = try locateSurface(surface)
        let root = try workspaceCwd(located.workspaceID)
        let state = Self.decodeFilesState(located.descriptor.metadata["files_state"])
            ?? defaultFilesState(surface: surface, workspace: located.workspaceID, root: root, descriptor: located.descriptor)
        return .object(state)
    }

    public func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue {
        let located = try locateSurface(surface)
        let root = try workspaceCwd(located.workspaceID)
        var state = Self.decodeFilesState(located.descriptor.metadata["files_state"])
            ?? defaultFilesState(surface: surface, workspace: located.workspaceID, root: root, descriptor: located.descriptor)
        let currentRevision = state["revision"]?.intValue ?? 0
        if let baseRevision, baseRevision != currentRevision {
            throw JSONRPCError(code: -32012, message: "files state revision conflict", data: .object(state))
        }
        for (key, value) in patch { state[key] = value }
        let revision = currentRevision + 1
        state["revision"] = .number(Double(revision))
        state["updated_at"] = .number(Date().timeIntervalSince1970)
        state["updated_by_device"] = deviceID.map { .string($0) } ?? .null
        try persistFilesState(surface: surface, workspace: located.workspaceID, state: state)
        EventBus.shared.publish(kind: .filesStateUpdated, payload: .object([
            "surface_id": .string(surface.value.uuidString),
            "workspace_id": .string(located.workspaceID.value.uuidString),
            "state": .object(state),
            "revision": .number(Double(revision)),
            "updated_by_device": deviceID.map { .string($0) } ?? .null
        ]))
        return .object(state)
    }

    public func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue {
        let located = try locateSurface(surface)
        let root = try workspaceCwd(located.workspaceID)
        let opened = try FileEditSessionStore.shared.open(surfaceID: surface, workspaceID: located.workspaceID, root: root, path: path)
        if let sessionID = opened.objectValue?["session_id"]?.stringValue {
            let _ = try filesStateUpdate(surface: surface, patch: [
                "selected_path": .string(path),
                "edit_session_id": .string(sessionID)
            ], baseRevision: nil, deviceID: "mac-host")
        }
        return opened
    }

    public func filesEditSession(sessionID: String) throws -> JSONValue {
        guard let session = FileEditSessionStore.shared.session(sessionID: sessionID) else {
            throw JSONRPCError(
                code: -32602,
                message: "edit session not found",
                data: .string(sessionID)
            )
        }
        return session
    }

    public func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
        let result = try FileEditSessionStore.shared.applyPatch(sessionID: sessionID, baseDraftRevision: baseDraftRevision, rangeLocation: rangeLocation, rangeLength: rangeLength, replacement: replacement, deviceID: deviceID)
        if let body = result.objectValue,
           let sid = body["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
           let path = body["path"]?.stringValue {
            try updateFilesDirty(surface: sid, path: path, dirty: true)
        }
        return result
    }

    public func filesEditSave(sessionID: String) throws -> JSONValue {
        let result = try FileEditSessionStore.shared.save(sessionID: sessionID)
        if let body = result.objectValue,
           let sid = body["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
           let path = body["path"]?.stringValue {
            try updateFilesDirty(surface: sid, path: path, dirty: false)
        }
        return result
    }

    public func filesEditDiscard(sessionID: String) throws -> JSONValue {
        let result = try FileEditSessionStore.shared.discard(sessionID: sessionID)
        if let body = result.objectValue,
           let sid = body["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
           let path = body["path"]?.stringValue {
            try updateFilesDirty(surface: sid, path: path, dirty: false)
        }
        return result
    }

    public func filesEditClose(sessionID: String) throws -> JSONValue {
        try FileEditSessionStore.shared.close(sessionID: sessionID)
    }

    public func browserWait(surface: SurfaceID, selector: String, timeoutMs: Int) async throws -> String {
        let s = try browserSurface(surface)
        return await withCheckedContinuation { cont in
            s.waitFor(selector, timeoutMs: timeoutMs) { json in cont.resume(returning: json) }
        }
    }

    /// `restoringFrom` carries the descriptor of a closed tab (⌘⇧T), so the new
    /// surface re-derives the target/state the descriptor kept (`url`, `path`,
    /// `files_state`, ssh profile) exactly like `reinstantiateRestoredSurfaces`.
    private func makeSurface(type: SurfaceType, title: String?, workspace: WorkspaceID, cwd: String, initialThreadId: AgentThreadID? = nil, sideThreadId: AgentThreadID? = nil, restoringFrom restore: SurfaceDescriptor? = nil) -> SurfaceDescriptor {
        let baseTitle = title ?? defaultTitle(for: type)
        let descriptor = SurfaceDescriptor(type: type, title: baseTitle, iconName: type.rawValue, metadata: ["workspace": workspace.value.uuidString, "cwd": cwd])
        let terminalFontSize = context.map { SettingsStore(db: $0.db).load().terminalFontSize } ?? 0
        // build concrete surface object now and register
        do {
            let surface: Surface
            switch type {
            case .terminal:
                surface = configureTerminalSurface(
                    try TerminalSurface(workspaceID: workspace, title: baseTitle, launch: .shell(cwd: cwd), historyRepo: context?.terminalOutputRepo, settingsRepo: context?.settingsRepo, terminalFontSize: terminalFontSize),
                    workspace: workspace
                )
            case .ssh:
                // A tab that was connected carries its profile in metadata:
                // reopen it as the live ssh terminal it was, not as the
                // profile picker (mirrors reinstantiateRestoredSurfaces).
                if let profile = restore.flatMap(sshProfile(from:)) {
                    surface = configureTerminalSurface(
                        try TerminalSurface(workspaceID: workspace, title: baseTitle, launch: .ssh(profile: profile, cwd: cwd), historyRepo: context?.terminalOutputRepo, settingsRepo: context?.settingsRepo, terminalFontSize: terminalFontSize),
                        workspace: workspace
                    )
                } else {
                    let ssh = try SSHSurface(
                        workspaceID: workspace,
                        cwd: cwd,
                        title: baseTitle,
                        router: self,
                        historyRepo: context?.terminalOutputRepo,
                        settingsRepo: context?.settingsRepo,
                        terminalFontSize: terminalFontSize
                    )
                    configureSSHBusy(ssh, workspace: workspace)
                    surface = ssh
                }
            case .browser:
                // bot_id keeps the reopened tab on the bot's WKWebView data
                // store (cookies/session) and its BotBrowserStore target.
                let botID = restore?.metadata["bot_id"].flatMap { UUID(uuidString: $0) }.map(BotID.init)
                surface = configureBrowserSurface(BrowserSurface(workspaceID: workspace, initialURL: restore.flatMap(restoredBrowserURL(from:)), title: baseTitle, botID: botID), workspace: workspace)
            case .agentApp:
                guard let ctx = context else { return descriptor }
                let agent = AgentAppSurface(workspaceID: workspace, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, draftRepo: AgentThreadDraftRepository(db: ctx.db), attachmentStore: AgentAttachmentStore(root: ctx.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)), queuedMessageRepo: ctx.queuedMessageRepo, providerSessionRepo: ctx.providerSessionRuntimeRepo, pendingCallbackRepo: ctx.providerPendingCallbackRepo, proposedPlanRepo: ctx.proposedPlanRepo, checkpointRepo: ctx.turnCheckpointRepo, promptHistoryStore: PromptHistoryStore(db: ctx.db), customModelStore: AgentCustomModelStore(repo: ctx.settingsRepo), planNotesStore: PlanNotesStore(db: ctx.db), title: baseTitle, initialThreadId: initialThreadId, sideThreadId: sideThreadId, orchestrationRuntime: ctx.orchestrationRuntime, openAccountsSettings: openAccountsSettings)
                wireWorkspaceAgentSurface(agent, workspace: workspace, ctx: ctx)
                surface = agent
            case .files:
                surface = FilesSurface(workspaceID: workspace, cwd: cwd, title: baseTitle, router: self, initialState: restore?.metadata["files_state"], selectedPath: restore?.metadata["selected_path"] ?? restore?.metadata["selected_relative_path"])
            case .markdown:
                let path = restore?.metadata["path"] ?? title // optional: pass file path via title for now
                surface = MarkdownSurface(workspaceID: workspace, filePath: path, title: baseTitle)
            case .filePreview:
                surface = FilePreviewSurface(workspaceID: workspace, filePath: restore?.metadata["path"] ?? title, title: baseTitle)
            case .rightSidebarTool:
                // Tool selection is encoded in the title for V1 — keeps
                // the JSON-RPC payload simple. Default is the diff panel.
                let tool = baseTitle.lowercased()
                if let workspaceTool = WorkspaceTool.from(metadata: restore?.metadata ?? [:], title: baseTitle) {
                    surface = WorkspaceToolSurface(tool: workspaceTool, workspaceID: workspace, title: baseTitle, router: self)
                } else if tool.contains("feed") {
                    let feed = FeedPanelSurface(workspaceID: workspace, title: baseTitle)
                    // Wire the in-process EventBus to the feed VM so any
                    // dispatcher mutation lights up the panel in real time.
                    // Start after the current seq so opening Feed does not
                    // replay retained backlog as if it were live activity.
                    let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { [weak feed] ev in
                        guard feed != nil else { return }
                        // Drop stream firehose on the delivery thread (same kinds
                        // as EventLog live-only / Pet prefilter) so each open Feed
                        // does not hop ~30 Hz item.delta onto main.
                        guard FeedPanelViewModel.shouldIngest(kind: ev.kind) else { return }
                        let kind = ev.kind
                        let summary = Self.summary(of: ev.payload)
                        DispatchQueue.main.async { [weak feed] in
                            feed?.viewModel.receive(seq: ev.seq, kind: kind, title: summary, ts: ev.ts)
                        }
                    }
                    feed.subscriptionToken = AnyHashable(token)
                    // Release the subscription when the surface is torn down so the
                    // panel/VM/NSHostingView don't leak for the app's lifetime.
                    feed.onClose = { EventBus.shared.unsubscribe(token) }
                    surface = feed
                } else {
                    let diff = DiffPanelSurface(workspaceID: workspace, cwd: cwd, title: baseTitle, settings: context.map { SettingsStore(db: $0.db) })
                    diff.onBusyStateChanged = { [weak self, weak diff] busy in
                        guard let self, let diff else { return }
                        self.surfaceBusyDidChange(workspace: workspace, surface: diff.descriptor.id, busy: busy)
                    }
                    surface = diff
                }
            }
            var finalDescriptor = SurfaceDescriptor(id: surface.descriptor.id, type: type, title: baseTitle, iconName: surface.descriptor.iconName, metadata: surface.descriptor.metadata)
            if let restore {
                // Two keys the surfaces cannot re-derive at init: the browser
                // target is only written on the first navigation callback (see
                // makeBrowserSurface), and the files revision mirrors the
                // restored blob for the connection snapshot.
                if finalDescriptor.metadata["url"] == nil {
                    finalDescriptor.metadata["url"] = restore.metadata["url"]
                }
                if finalDescriptor.metadata["files_state_revision"] == nil {
                    finalDescriptor.metadata["files_state_revision"] = restore.metadata["files_state_revision"]
                }
            }
            SurfaceRegistry.shared.register(surface)
            return finalDescriptor
        } catch {
            return descriptor
        }
    }

    private func makeFilesSurface(workspace: WorkspaceID, cwd: String, title: String, selectedPath: String) -> SurfaceDescriptor {
        let surface = FilesSurface(workspaceID: workspace, cwd: cwd, title: title, router: self, initialState: nil, selectedPath: selectedPath)
        SurfaceRegistry.shared.register(surface)
        return surface.descriptor
    }

    private func defaultTitle(for type: SurfaceType) -> String {
        type.displayLabel.lowercased() == "agent app" ? "Agent App" : type.displayLabel.lowercased()
    }

    /// Reject only events that carry a valid, known workspace identity for a
    /// different Agent surface. Legacy or malformed payloads stay fail-open.
    nonisolated static func shouldAdmitAgentLifecycleEvent(
        payload: JSONValue,
        workspaceID: WorkspaceID
    ) -> Bool {
        guard let workspaceValue = payload.objectValue?["workspace_id"]?.stringValue,
              let eventWorkspaceID = UUID(uuidString: workspaceValue) else {
            return true
        }
        return eventWorkspaceID == workspaceID.value
    }

    private func makeSSHSurface(profile: SSHHostProfile, title: String?, workspace: WorkspaceID, cwd: String) throws -> SurfaceDescriptor {
        let baseTitle = title ?? profile.label
        let terminalFontSize = context.map { SettingsStore(db: $0.db).load().terminalFontSize } ?? 0
        let surface = try SSHSurface(
            workspaceID: workspace,
            cwd: cwd,
            title: baseTitle,
            router: self,
            historyRepo: context?.terminalOutputRepo,
            settingsRepo: context?.settingsRepo,
            terminalFontSize: terminalFontSize
        )
        configureSSHBusy(surface, workspace: workspace)
        surface.connectForRouter(profile)
        SurfaceRegistry.shared.register(surface)
        return surface.descriptor
    }

    private func requireWorkspace(_ workspace: WorkspaceID, in context: AppContext) throws {
        guard context.state.workspaces[workspace] != nil else { throw LayoutError.workspaceNotFound }
    }

    private func sshHostsKey(workspace: WorkspaceID) -> String {
        "ssh.hosts.\(workspace.value.uuidString)"
    }

    private func readSSHHosts(workspace: WorkspaceID, from repo: SettingsRepository) throws -> [SSHHostProfile] {
        guard let raw = try repo.get(sshHostsKey(workspace: workspace)),
              let data = raw.data(using: .utf8) else { return [] }
        // A payload that cannot be read back is NOT an empty host list: upsert and
        // delete rewrite whatever this returns, so answering `[]` erased the saved
        // hosts the user still had (and orphaned their Keychain passwords). Fail
        // loudly and leave the stored bytes for the user to repair.
        do {
            return try settingsJSONDecoder.decode([SSHHostProfile].self, from: data)
        } catch {
            throw JSONRPCError(
                code: JSONRPCError.internalError.code,
                message: "The saved SSH hosts for this workspace could not be read, so MacCode left them untouched. The stored entry has to be repaired before hosts can be edited."
            )
        }
    }

    private func writeSSHHosts(_ hosts: [SSHHostProfile], workspace: WorkspaceID, to repo: SettingsRepository) throws {
        // Persist secrets in the Keychain, not as plaintext JSON on disk.
        let stripped: [SSHHostProfile] = hosts.map { host in
            var h = host
            if let pw = host.password, !pw.isEmpty {
                sshPasswordStore.save(account: host.id.value.uuidString, password: pw)
                h.hasSavedPassword = true
            } else if !host.hasSavedPassword {
                sshPasswordStore.delete(account: host.id.value.uuidString)
            } else {
                h.hasSavedPassword = true
            }
            h.password = nil
            return h
        }
        let data = try settingsJSONEncoder.encode(stripped)
        try repo.set(sshHostsKey(workspace: workspace), String(data: data, encoding: .utf8) ?? "[]")
    }

    private func sshHostWithPasswordForConnection(_ host: SSHHostProfile) -> SSHHostProfile {
        var resolved = host
        if (resolved.password == nil || resolved.password?.isEmpty == true), host.hasSavedPassword {
            resolved.password = sshPasswordStore.load(account: host.id.value.uuidString)
        }
        resolved.hasSavedPassword = resolved.hasSavedPassword || (resolved.password?.isEmpty == false)
        return resolved
    }

    private struct SSHTransferLifecycle {
        let workspaceID: WorkspaceID
        let surfaceID: SurfaceID
        let transferID: String
        let direction: String
        let startedAt: Date
    }

    private func beginSSHTransfer(surface: SurfaceID, direction: String) throws -> SSHTransferLifecycle {
        let workspaceID = try locateSurface(surface).workspaceID
        let lifecycle = SSHTransferLifecycle(
            workspaceID: workspaceID,
            surfaceID: surface,
            transferID: UUID().uuidString,
            direction: direction,
            startedAt: Date()
        )
        EventBus.shared.publish(kind: .sshTransferStarted, payload: .object([
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(surface.value.uuidString),
            "transfer_id": .string(lifecycle.transferID),
            "direction": .string(direction)
        ]))
        return lifecycle
    }

    private func finishSSHTransfer(_ lifecycle: SSHTransferLifecycle, exitCode: Int32?) {
        let succeeded = exitCode == 0
        let durationMilliseconds = max(0, Int64(Date().timeIntervalSince(lifecycle.startedAt) * 1_000))
        EventBus.shared.publish(kind: succeeded ? .sshTransferCompleted : .sshTransferFailed, payload: .object([
            "workspace_id": .string(lifecycle.workspaceID.value.uuidString),
            "surface_id": .string(lifecycle.surfaceID.value.uuidString),
            "transfer_id": .string(lifecycle.transferID),
            "direction": .string(lifecycle.direction),
            "exit_code": exitCode.map { .number(Double($0)) } ?? .null,
            "duration_ms": .number(Double(durationMilliseconds)),
            "result": .string(succeeded ? "success" : "failure")
        ]))
    }

    private func runSSHTransfer(surface: SurfaceID, upload: Bool, localPath: String, remotePath: String) throws -> JSONValue {
        let kind = upload ? "upload" : "download"
        let lifecycle = try beginSSHTransfer(surface: surface, direction: kind)
        var lease: SystemOutputLease?
        do {
            let (profile, appendOutput) = try sshTransferProfileAndOutput(for: surface)
            let args = upload
                ? SSHCommandBuilder.scpUploadArguments(profile: profile, localPath: localPath, remotePath: remotePath)
                : SSHCommandBuilder.scpDownloadArguments(profile: profile, remotePath: remotePath, localPath: localPath)
            lease = try reserveTransferOutput(for: surface)
            appendOutput("\n[ssh \(kind) started]\n")
            let result = try runCommand(executable: "/usr/bin/scp", arguments: args, password: profile.password)
            let ok = result.exitCode == 0
            deliverTransferOutput(lease, appendOutput, result.output, "[ssh \(kind) \(ok ? "completed" : "failed")]\n")
            finishSSHTransfer(lifecycle, exitCode: result.exitCode)
            return .object([
                "ok": .bool(ok),
                "exit_code": .number(Double(result.exitCode)),
                "output": .string(result.output)
            ])
        } catch {
            lease?.cancel()
            finishSSHTransfer(lifecycle, exitCode: nil)
            throw error
        }
    }

    private static let transferOutputBusyCode = -32021

    /// Reserves the terminal's system-output stream before scp runs. Nil means the
    /// surface has no terminal (legacy direct append); busy throws before any work.
    private func reserveTransferOutput(for surface: SurfaceID) throws -> SystemOutputLease? {
        guard let object = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        guard let terminal = (object as? TerminalSurface) ?? (object as? SSHTransferSurface)?.transferTerminal else {
            return nil
        }
        guard let lease = terminal.reserveSystemOutput() else {
            throw JSONRPCError(code: Self.transferOutputBusyCode, message: "terminal output busy")
        }
        return lease
    }

    /// Async callers wait (cancellably, bounded) for admission instead of failing.
    private func reserveTransferOutputAwaiting(for surface: SurfaceID) async throws -> SystemOutputLease? {
        for _ in 0..<600 {
            do { return try reserveTransferOutput(for: surface) }
            catch let error as JSONRPCError where error.code == Self.transferOutputBusyCode {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return try reserveTransferOutput(for: surface)
    }

    private func deliverTransferOutput(
        _ lease: SystemOutputLease?,
        _ appendOutput: (String) -> Void,
        _ output: String,
        _ notice: String
    ) {
        if let lease {
            lease.deliver(output, trailing: notice)
        } else {
            if !output.isEmpty { appendOutput(output) }
            appendOutput(notice)
        }
    }

    /// Async transfer: resolves actor state on the main actor, runs the scp
    /// process off the main run loop, then marshals results/output back. Used
    /// by the macOS SSH surface so transfers never freeze the UI.
    public func sshTransferUploadAsync(surface: SurfaceID, localPath: String, remotePath: String) async throws -> JSONValue {
        try await runSSHTransferAsync(surface: surface, upload: true, localPath: localPath, remotePath: remotePath)
    }

    public func sshTransferDownloadAsync(surface: SurfaceID, remotePath: String, localPath: String) async throws -> JSONValue {
        try await runSSHTransferAsync(surface: surface, upload: false, localPath: localPath, remotePath: remotePath)
    }

    private func runSSHTransferAsync(surface: SurfaceID, upload: Bool, localPath: String, remotePath: String) async throws -> JSONValue {
        let kind = upload ? "upload" : "download"
        let lifecycle = try beginSSHTransfer(surface: surface, direction: kind)
        var lease: SystemOutputLease?
        do {
            let (profile, appendOutput) = try sshTransferProfileAndOutput(for: surface)
            let args = upload
                ? SSHCommandBuilder.scpUploadArguments(profile: profile, localPath: localPath, remotePath: remotePath)
                : SSHCommandBuilder.scpDownloadArguments(profile: profile, remotePath: remotePath, localPath: localPath)
            lease = try await reserveTransferOutputAwaiting(for: surface)
            appendOutput("\n[ssh \(kind) started]\n")
            let password = profile.password
            let commandRunner = sshCommandRunner
            let result = try await ProviderCLIProbe.runOffCooperativePool {
                Result { try commandRunner("/usr/bin/scp", args, password) }
            }.get()
            let ok = result.exitCode == 0
            deliverTransferOutput(lease, appendOutput, result.output, "[ssh \(kind) \(ok ? "completed" : "failed")]\n")
            finishSSHTransfer(lifecycle, exitCode: result.exitCode)
            return .object([
                "ok": .bool(ok),
                "exit_code": .number(Double(result.exitCode)),
                "output": .string(result.output)
            ])
        } catch {
            lease?.cancel()
            finishSSHTransfer(lifecycle, exitCode: nil)
            throw error
        }
    }

    /// Async remote listing: spawns the remote shell off the main run loop.
    public func sshFilesRemoteListAsync(surface: SurfaceID, path: String?) async throws -> JSONValue {
        let profile = try sshTransferProfile(for: surface)
        let requested = (path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? path! : "."
        let script = """
        p=\(shellQuote(requested))
        [ -z "$p" ] && p=.
        cd "$p" 2>/dev/null || exit 2
        pwd
        for f in .. .* *; do
          [ "$f" = "." ] && continue
          [ -e "$f" ] || continue
          if [ -d "$f" ]; then
            kind=directory
            type="File folder"
            size=""
          else
            kind=file
            ext="${f##*.}"
            [ "$ext" = "$f" ] && type="File" || type="$ext file"
            size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          fi
          mod=$(date -r "$f" "+%Y-%m-%d %H:%M" 2>/dev/null || stat -c %y "$f" 2>/dev/null | cut -c1-16)
          printf '%s\t%s\t%s\t%s\n' "$f" "$kind" "$size" "$mod"
        done
        """
        let args = SSHCommandBuilder.sshArguments(for: profile) + ["sh", "-lc", script]
        let password = profile.password
        let result = try await ProviderCLIProbe.runOffCooperativePool {
            Result { try Self.runCommandBlocking(executable: "/usr/bin/ssh", arguments: args, password: password) }
        }.get()
        guard result.exitCode == 0 else {
            throw JSONRPCError(code: -32020, message: "remote list failed", data: .string(result.output))
        }
        return makeRemoteSSHFileListing(output: result.output, requestedPath: requested)
    }

    private func sshTransferProfile(for surface: SurfaceID) throws -> SSHHostProfile {
        try sshTransferProfileAndOutput(for: surface).profile
    }

    private func sshTransferProfileAndOutput(for surface: SurfaceID) throws -> (profile: SSHHostProfile, appendOutput: (String) -> Void) {
        guard let surfaceObject = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        let appendOutput: (String) -> Void
        if let terminal = surfaceObject as? TerminalSurface {
            guard let terminalProfile = sshProfile(from: terminal.descriptor) else { throw LayoutError.surfaceNotFound }
            return (terminalProfile, { terminal.appendSystemText($0) })
        } else if let sshSurface = surfaceObject as? SSHTransferSurface, let transferProfile = sshSurface.sshTransferProfile {
            appendOutput = { sshSurface.appendSystemText($0) }
            return (transferProfile, appendOutput)
        } else {
            throw LayoutError.surfaceNotFound
        }
    }

    private func runCommand(executable: String, arguments: [String], password: String?) throws -> (exitCode: Int32, output: String) {
        try sshCommandRunner(executable, arguments, password)
    }

    /// Off-actor process execution. Pure local work (no actor state), so it is
    /// safe to invoke from a detached task to keep blocking scp/ssh waits off
    /// the main run loop. The synchronous RPC path keeps calling `runCommand`.
    nonisolated static func runCommandBlocking(executable: String, arguments: [String], password: String?) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        var expectScriptURL: URL?
        if let password, !password.isEmpty, FileManager.default.fileExists(atPath: "/usr/bin/expect") {
            let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("remotecode-ssh-expect-\(UUID().uuidString).tcl")
            try """
            set timeout -1
            set password $env(RC_SSH_PASSWORD)
            spawn {*}$argv
            expect {
              -re {(?i)(password|passphrase).*:} { send -- "$password\\r"; exp_continue }
              eof
            }
            catch wait result
            exit [lindex $result 3]
            """.write(to: scriptURL, atomically: true, encoding: .utf8)
            expectScriptURL = scriptURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            process.arguments = [scriptURL.path, executable] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["RC_SSH_PASSWORD"] = password
            process.environment = environment
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let expectScriptURL { try? FileManager.default.removeItem(at: expectScriptURL) }
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func makeLocalSSHFileListing(path rawPath: String?) throws -> JSONValue {
        let fm = FileManager.default
        let fallback = context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory()
        let input = (rawPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? rawPath! : fallback
        let path = ((input as NSString).expandingTildeInPath as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "not a directory", data: .string(path))
        }
        // Avoid prefetching resource keys on network-mount children of a local
        // parent (e.g. ~/OrbStack NFS) — that re-triggers Network Volumes TCC.
        let listed = try HostSafeDirectoryListing.list(path: path, fileManager: fm)
        var entries: [JSONValue] = []
        if let parent = makeParentEntry(for: path) { entries.append(parent) }
        let children = listed.map { entry -> JSONValue in
            makeLocalEntry(from: entry)
        }.sorted(by: sortSSHEntries)
        return .object([
            "path": .string(path),
            "parent_path": path == "/" ? .null : .string((path as NSString).deletingLastPathComponent),
            "entries": .array(entries + children)
        ])
    }

    private func makeParentEntry(for path: String) -> JSONValue? {
        guard path != "/" else { return nil }
        return .object([
            "name": .string(".."),
            "path": .string((path as NSString).deletingLastPathComponent),
            "kind": .string("directory"),
            "size": .string(""),
            "file_type": .string("File folder"),
            "modified": .string("")
        ])
    }

    private func makeLocalEntry(_ url: URL) -> JSONValue {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values?.isDirectory == true
        let size = isDirectory ? "" : "\(values?.fileSize ?? 0)"
        let modified = values?.contentModificationDate.map(Self.shortDateFormatter.string(from:)) ?? ""
        let type = isDirectory ? "File folder" : fileType(for: url.lastPathComponent)
        return .object([
            "name": .string(url.lastPathComponent),
            "path": .string(url.path),
            "kind": .string(isDirectory ? "directory" : "file"),
            "size": .string(size),
            "file_type": .string(type),
            "modified": .string(modified)
        ])
    }

    /// Listing entry that never requires a second resourceValues pass (and never
    /// forces Network Volumes TCC for opaque NFS mount children of a local parent).
    private func makeLocalEntry(from entry: HostSafeDirectoryListing.Entry) -> JSONValue {
        let size = entry.isDirectory ? "" : "\(entry.fileSize ?? 0)"
        let modified = entry.contentModificationDate.map(Self.shortDateFormatter.string(from:)) ?? ""
        let type = entry.isDirectory
            ? (entry.isNetworkVolume ? "Network volume" : "File folder")
            : fileType(for: entry.name)
        return .object([
            "name": .string(entry.name),
            "path": .string(entry.path),
            "kind": .string(entry.isDirectory ? "directory" : "file"),
            "size": .string(size),
            "file_type": .string(type),
            "modified": .string(modified)
        ])
    }

    private func makeRemoteSSHFileListing(output: String, requestedPath: String) -> JSONValue {
        var lines = output
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while let first = lines.first, !first.hasPrefix("/") {
            lines.removeFirst()
        }
        let path = lines.isEmpty ? requestedPath : lines.removeFirst()
        let entries = lines.compactMap { line -> JSONValue? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            let name = parts[0]
            let kind = parts[1]
            let child = name == ".." ? ((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent)
                : (path as NSString).appendingPathComponent(name)
            return .object([
                "name": .string(name),
                "path": .string(child),
                "kind": .string(kind),
                "size": .string(parts[2]),
                "file_type": .string(kind == "directory" ? "File folder" : fileType(for: name)),
                "modified": .string(parts[3])
            ])
        }.sorted(by: sortSSHEntries)
        return .object([
            "path": .string(path),
            "parent_path": path == "/" ? .null : .string((path as NSString).deletingLastPathComponent),
            "entries": .array(entries)
        ])
    }

    private func sortSSHEntries(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        let lo = lhs.objectValue ?? [:]
        let ro = rhs.objectValue ?? [:]
        let ln = lo["name"]?.stringValue ?? ""
        let rn = ro["name"]?.stringValue ?? ""
        if ln == ".." { return true }
        if rn == ".." { return false }
        let ld = lo["kind"]?.stringValue == "directory"
        let rd = ro["kind"]?.stringValue == "directory"
        if ld != rd { return ld && !rd }
        return ln.localizedCaseInsensitiveCompare(rn) == .orderedAscending
    }

    private func fileType(for name: String) -> String {
        Self.fileTypeLabel(for: name)
    }

    /// Listing label matching NSString.pathExtension: a leading-dot basename
    /// (`.png`, `foo/.png`) has no extension and is "File", not "PNG File".
    nonisolated static func fileTypeLabel(for name: String) -> String {
        // PERF: file listings call this per row; NSString.pathExtension +
        // uppercased() allocated twice per file. Scan the suffix directly.
        let utf8 = name.utf8
        var componentStart = utf8.startIndex
        var lastDot: String.UTF8View.Index?
        var i = utf8.startIndex
        while i != utf8.endIndex {
            if utf8[i] == 0x2F {
                let next = utf8.index(after: i)
                componentStart = next
                lastDot = nil
            } else if utf8[i] == 0x2E {
                lastDot = i
            }
            i = utf8.index(after: i)
        }
        guard let lastDot,
              lastDot != componentStart,
              utf8.index(after: lastDot) != utf8.endIndex else {
            return "File"
        }
        return "\(name[utf8.index(after: lastDot)...].uppercased()) File"
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func sshProfile(from desc: SurfaceDescriptor) -> SSHHostProfile? {
        guard let destination = desc.metadata["ssh_destination"] else { return nil }
        let id = desc.metadata["ssh_profile_id"].flatMap(UUID.init).map(SSHHostID.init) ?? SSHHostID()
        let port = desc.metadata["ssh_port"].flatMap(Int.init)
        let options = desc.metadata["ssh_options"]?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return SSHHostProfile(id: id, label: desc.metadata["ssh_label"] ?? desc.title, destination: destination, port: port, identityFile: desc.metadata["ssh_identity_file"], options: options)
    }

    static func summary(of payload: JSONValue) -> String {
        if case .object(let o) = payload {
            if let s = o["title"]?.stringValue { return s }
            if let s = o["name"]?.stringValue { return s }
            if let s = o["id"]?.stringValue { return s }
        }
        return ""
    }

    private func locateSurface(_ surfaceID: SurfaceID) throws -> (workspaceID: WorkspaceID, descriptor: SurfaceDescriptor) {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        for (wid, ws) in ctx.state.workspaces {
            if let descriptor = findSurface(surfaceID, in: ws.layout) {
                return (wid, descriptor)
            }
        }
        if let surface = SurfaceRegistry.shared.surface(surfaceID),
           let raw = surface.descriptor.metadata["workspace"],
           let uuid = UUID(uuidString: raw) {
            return (WorkspaceID(uuid), surface.descriptor)
        }
        throw LayoutError.surfaceNotFound
    }

    private func findSurface(_ surfaceID: SurfaceID, in node: LayoutNode) -> SurfaceDescriptor? {
        switch node {
        case .pane(let pane):
            return pane.surfaces.first { $0.id == surfaceID }
        case .split(let split):
            for child in split.children {
                if let found = findSurface(surfaceID, in: child) { return found }
            }
            return nil
        }
    }

    private func paneIDContaining(surface surfaceID: SurfaceID, in node: LayoutNode) -> PaneID? {
        switch node {
        case .pane(let pane):
            return pane.surfaces.contains { $0.id == surfaceID } ? pane.id : nil
        case .split(let split):
            return split.children.compactMap { paneIDContaining(surface: surfaceID, in: $0) }.first
        }
    }

    private func defaultFilesState(surface: SurfaceID, workspace: WorkspaceID, root: String, descriptor: SurfaceDescriptor) -> [String: JSONValue] {
        let selected = descriptor.metadata["selected_path"] ?? descriptor.metadata["selected_relative_path"]
        return [
            "surface_id": .string(surface.value.uuidString),
            "workspace_id": .string(workspace.value.uuidString),
            "root": .string(root),
            "current_directory": .string(""),
            "expanded_dirs": .array([]),
            "selected_path": selected.map { .string($0) } ?? .null,
            "search_query": .string(""),
            "show_hidden": .bool(true),
            "sort_key": .string("name"),
            "sort_direction": .string("asc"),
            "reader_mode": .string("source"),
            "word_wrap": .bool(true),
            "preview_zoom": .number(1),
            "edit_session_id": descriptor.metadata["active_edit_session_id"].map { .string($0) } ?? .null,
            "dirty_paths": .array([]),
            "revision": .number(Double(descriptor.metadata["files_state_revision"].flatMap(Int.init) ?? 0)),
            "updated_at": .number(Date().timeIntervalSince1970),
            "updated_by_device": .null
        ]
    }

    nonisolated private static func decodeFilesState(_ raw: String?) -> [String: JSONValue]? {
        guard let raw, let data = raw.data(using: .utf8),
              case .object(let state) = JSONValue.decode(from: data) else {
            return nil
        }
        return state
    }

    private func encodeFilesState(_ state: [String: JSONValue]) -> String? {
        guard let data = try? jsonValueEncoder.encode(JSONValue.object(state)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func persistFilesState(surface: SurfaceID, workspace: WorkspaceID, state: [String: JSONValue], refreshWindow: Bool = true) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        var ws = try ctx.state.workspaces[workspace].orThrow(LayoutError.workspaceNotFound)
        let encoded = encodeFilesState(state)
        let result = updateSurface(in: ws.layout, surfaceID: surface) { descriptor in
            if let encoded { descriptor.metadata["files_state"] = encoded }
            descriptor.metadata["files_state_revision"] = "\(state["revision"]?.intValue ?? 0)"
            if let selected = state["selected_path"]?.stringValue {
                descriptor.metadata["selected_path"] = selected
                descriptor.metadata["selected_relative_path"] = selected
            }
            if let session = state["edit_session_id"]?.stringValue {
                descriptor.metadata["active_edit_session_id"] = session
            }
            if case .array(let dirty) = state["dirty_paths"] ?? .array([]) {
                descriptor.metadata["dirty_count"] = "\(dirty.count)"
                descriptor.isDirty = !dirty.isEmpty
            }
        }
        ws.layout = result.node
        ws.updatedAt = Date()
        ctx.state.workspaces[workspace] = ws
        ctx.scheduleSnapshotSave()
        if refreshWindow {
            windowController?.refreshFromState()
        }
    }

    private func updateFilesDirty(surface: SurfaceID, path: String, dirty: Bool) throws {
        let located = try locateSurface(surface)
        var state = try filesStateGet(surface: surface).objectValue ?? [:]
        var dirtyPaths: [String] = []
        if case .array(let values) = state["dirty_paths"] ?? .array([]) {
            dirtyPaths = values.compactMap(\.stringValue)
        }
        dirtyPaths = filesDirtyPathsAfterMutation(existing: dirtyPaths, path: path, dirty: dirty)
        state["dirty_paths"] = .array(dirtyPaths.map { .string($0) })
        state["revision"] = .number(Double((state["revision"]?.intValue ?? 0) + 1))
        state["updated_at"] = .number(Date().timeIntervalSince1970)
        try persistFilesState(surface: surface, workspace: located.workspaceID, state: state, refreshWindow: false)
        EventBus.shared.publish(kind: .filesStateUpdated, payload: .object([
            "surface_id": .string(surface.value.uuidString),
            "workspace_id": .string(located.workspaceID.value.uuidString),
            "state": .object(state),
            "revision": state["revision"] ?? .number(0),
            "updated_by_device": .string("mac-host")
        ]))
    }

    @discardableResult
    public func promoteWorkspaceIfBusy(_ id: WorkspaceID) -> Bool {
        guard let ctx = context,
              (isWorkspaceBusy(id)
               || ((try? ctx.threadRepo.runningWorkspaceIds(in: [id])) ?? []).contains(id)) else {
            return false
        }
        return promoteWorkspaceForActivity(id)
    }

    @discardableResult
    public func promoteWorkspaceContainingBusySurface(_ surfaceID: SurfaceID) -> Bool {
        guard let located = try? locateSurface(surfaceID),
              isWorkspaceActivitySurface(located.descriptor) else {
            return false
        }
        return promoteWorkspaceForActivity(located.workspaceID)
    }

    @discardableResult
    public func promoteWorkspaceAfterCompletedRun(_ id: WorkspaceID) -> Bool {
        promoteWorkspaceForActivity(id)
    }

    @discardableResult
    private func promoteWorkspaceForActivity(_ id: WorkspaceID) -> Bool {
        guard let ctx = context else { return false }
        let before = ctx.state.window.workspaces
        try? ctx.apply(.promoteWorkspace(id))
        let order = ctx.state.window.workspaces
        guard order != before else { return false }
        EventBus.shared.publish(kind: .workspaceReordered, payload: .object([
            "workspace_id": .string(id.value.uuidString),
            "order": .array(order.map { .string($0.value.uuidString) })
        ]))
        windowController?.refreshFromState()
        return true
    }
}

private extension Optional {
    func orThrow(_ error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}

private func terminalInputStatusJSON(_ status: TerminalInputStatus) -> JSONValue {
    .object([
        "status": .string(status.rawValue),
        "accepted": .bool(status == .accepted)
    ])
}

private func terminalHealthJSON(_ health: TerminalRuntimeHealth) -> JSONValue {
    .object([
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
        "cols": .number(Double(health.cols)),
        "render_diagnostics": health.renderDiagnostics.map(terminalRenderDiagnosticsJSON) ?? .null
    ])
}

private func disconnectedTerminalHealthJSON() -> JSONValue {
    .object([
        "alive": .bool(false),
        "process_alive": .bool(false),
        "child_pid": .null,
        "exit_status": .null,
        "termination_signal": .null,
        "pty_open": .bool(false),
        "input_accepting": .bool(false),
        "terminal_dead_reason": .string(TerminalInputStatus.processExited.rawValue),
        "last_output_at": .null,
        "output_partial": .bool(false),
        "partial_reason": .null,
        "output_pending_bytes": .number(0),
        "history_write_failures": .number(0),
        "dropped_output_bytes": .number(0),
        "rows": .number(0),
        "cols": .number(0),
        "render_diagnostics": .null
    ])
}

private func disconnectedTerminalSnapshotJSON() -> JSONValue {
    .object([
        "text": .string(""),
        "ansi_text": .null,
        "ansi_palette": .null,
        "complete": .bool(false),
        "partial": .bool(true),
        "source": .string("ssh_disconnected"),
        "timestamp": .number(Date().timeIntervalSince1970),
        "partial_reason": .string(TerminalInputStatus.processExited.rawValue),
        "pending_bytes": .number(0),
        "rows": .number(0),
        "cols": .number(0),
        "render_diagnostics": .null
    ])
}

func terminalSnapshotJSON(_ snapshot: TerminalTextSnapshot) -> JSONValue {
    var fields: [String: JSONValue] = [
        "text": .string(snapshot.text),
        "ansi_text": snapshot.ansiText.map { .string($0) } ?? .null,
        "complete": .bool(snapshot.complete),
        "partial": .bool(!snapshot.complete),
        "source": .string(snapshot.source),
        "timestamp": .number(snapshot.timestamp.timeIntervalSince1970),
        "partial_reason": snapshot.partialReason.map { .string($0) } ?? .null,
        "pending_bytes": .number(Double(snapshot.pendingBytes)),
        "rows": .number(Double(snapshot.rows)),
        "cols": .number(Double(snapshot.cols)),
        "render_diagnostics": snapshot.renderDiagnostics.map(terminalRenderDiagnosticsJSON) ?? .null
    ]
    // Emit null for the default theme so mirrors can clear a previously cached
    // custom palette on the same surface instead of keeping stale colors.
    fields["ansi_palette"] = snapshot.ansiPalette.map { palette in
        .array(palette.map { .string($0) })
    } ?? .null
    return .object(fields)
}

func filesDirtyPathsAfterMutation(existing: [String], path: String, dirty: Bool) -> [String] {
    var next = existing
    if dirty {
        if !next.contains(path) { next.append(path) }
    } else {
        next.removeAll { $0 == path }
    }
    return next
}

private func terminalRenderDiagnosticsJSON(_ diagnostics: TerminalRenderDiagnostics) -> JSONValue {
    .object([
        "logical_visible": .bool(diagnostics.logicalVisible),
        "registry_visible": .bool(diagnostics.registryVisible),
        "draining_hidden_backlog": .bool(diagnostics.drainingHiddenBacklog),
        "window_attached": .bool(diagnostics.windowAttached),
        "parked": .bool(diagnostics.parked),
        "has_usable_bounds": .bool(diagnostics.hasUsableBounds),
        "hidden_ancestor": .bool(diagnostics.hiddenAncestor),
        "can_render": .bool(diagnostics.canRender),
        "blocked_reason": diagnostics.blockedReason.map { .string($0) } ?? .null
    ])
}

/// Keychain-backed storage for SSH passwords so they are never persisted as
/// plaintext in the settings JSON (UX-MAC_SSH-002b). Generic-password items
/// keyed by host profile id. Failures are non-fatal: the in-memory session
/// still works; only durable persistence of the secret is lost.
protocol SSHPasswordStoring {
    func save(account: String, password: String)
    func load(account: String) -> String?
    func delete(account: String)
}

struct KeychainSSHPasswordStore: SSHPasswordStoring {
    private static let service = "com.remotecode.ssh.password"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func save(account: String, password: String) {
        let data = Data(password.utf8)
        SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
        var add = Self.baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func load(account: String) -> String? {
        var query = Self.baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    func delete(account: String) {
        SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
    }
}

/// Carries a paired `bot.*` read across the detached hop. The authority
/// serializes every dispatch under its own lock; the params dictionary is
/// built from JSON values and is never mutated after hand-off.
private struct PairedBotReadRequest: @unchecked Sendable {
    let authority: BotRemoteControlAuthority
    let method: String
    let params: [String: Any]
}

private enum PairedBotReadOutcome: @unchecked Sendable {
    case value([String: Any])
    case failure(Error)
}
