import Foundation
import CoreModel
import Persistence
import CryptoKit
import os

private let distillAcpLog = Logger(subsystem: "io.remotecode.agent", category: "distill.acp")

public struct DistillACPDiscoveryResult: Sendable, Equatable {
    public let models: [AgentModelDescriptor]
    public let isFallback: Bool
    public let interactionModes: [AgentInteractionMode]
    public let permissionModes: [AgentPermissionMode]
    public let capabilities: AgentProviderCapabilities
    public let discoveryCacheKey: String

    public init(
        models: [AgentModelDescriptor],
        isFallback: Bool,
        interactionModes: [AgentInteractionMode],
        permissionModes: [AgentPermissionMode],
        capabilities: AgentProviderCapabilities,
        discoveryCacheKey: String
    ) {
        self.models = models
        self.isFallback = isFallback
        self.interactionModes = interactionModes
        self.permissionModes = permissionModes
        self.capabilities = capabilities
        self.discoveryCacheKey = discoveryCacheKey
    }
}

/// Bounded pull-history for Distill ACP sessions. The public read window matches
/// AgentRunCoordinator while a small high-water slack amortizes storage compaction.
struct DistillACPHistoryRetention: Sendable {
    static let eventPruneSlack = 1_024
    static let bytePruneSlack: Int64 = 1_024 * 1_024

    private var storage: [AssistantEvent] = []
    private var storageBytes: [Int64] = []
    private var startIndex = 0
    private var discardedBytes: Int64 = 0
    private var estimatedBytes: Int64 = 0
    private let eventLimit: Int
    private let byteLimit: Int64
    private let eventSlack: Int
    private let byteSlack: Int64

    init(
        eventLimit: Int = AgentRunCoordinator.hotReplayEventCount,
        byteLimit: Int64 = AgentRunCoordinator.hotReplayEventBytes,
        eventSlack: Int = eventPruneSlack,
        byteSlack: Int64 = bytePruneSlack
    ) {
        self.eventLimit = max(1, eventLimit)
        self.byteLimit = max(1, byteLimit)
        self.eventSlack = max(0, eventSlack)
        self.byteSlack = max(0, byteSlack)
    }

    var readableEvents: [AssistantEvent] {
        Array(storage[startIndex...])
    }

    var retainedEventCount: Int { storage.count - startIndex }
    var bufferedEventCount: Int { storage.count }
    var storageCapacityForTesting: Int { storage.capacity }
    var bufferedEstimatedBytes: Int64 { estimatedBytes + discardedBytes }

    mutating func append(_ event: AssistantEvent) {
        let eventBytes = Int64(max(1, event.estimatedHotQueueBytes))
        // Match boundedHotReplay: a frame larger than the whole window cannot
        // fit alone and must not evict a valid recent tail.
        guard eventBytes <= byteLimit else { return }
        // Grow with the session instead of reserving the whole window up front
        // (~750 KB per idle session); cap the last step at the window so a busy
        // session never doubles past it.
        let window = eventLimit + eventSlack + 1
        if storage.count == storage.capacity, storage.capacity * 2 > window {
            storage.reserveCapacity(window)
        }
        if storageBytes.count == storageBytes.capacity, storageBytes.capacity * 2 > window {
            storageBytes.reserveCapacity(window)
        }
        storage.append(event)
        storageBytes.append(eventBytes)
        estimatedBytes += eventBytes
        evictIfNeeded()
    }

    mutating func append(contentsOf newEvents: [AssistantEvent]) {
        for event in newEvents { append(event) }
    }

    private mutating func evictIfNeeded() {
        while retainedEventCount > eventLimit || estimatedBytes > byteLimit {
            let evictedBytes = storageBytes[startIndex]
            estimatedBytes -= evictedBytes
            discardedBytes += evictedBytes
            startIndex += 1
        }
        let crossedEventSlack = eventSlack == 0 ? startIndex > 0 : startIndex > eventSlack
        let crossedByteSlack = byteSlack == 0 ? discardedBytes > 0 : discardedBytes > byteSlack
        guard crossedEventSlack || crossedByteSlack else { return }
        storage.removeFirst(startIndex)
        storageBytes.removeFirst(startIndex)
        startIndex = 0
        discardedBytes = 0
    }
}

public final class DistillACPAdapter: AgentProviderAdapter, @unchecked Sendable {
    /// Discovery is still a provider runtime. It must enter the same durable
    /// ownership ledger as interactive distill sessions so a host crash cannot
    /// leave it untracked.
    static let discoveryProcessOwnershipTaggingEnabled = true
    private final class NotificationBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, Any?)] = []
        func append(method: String, params: Any?) { lock.lock(); items.append((method, params)); lock.unlock() }
        func drain() -> [(String, Any?)] { lock.lock(); defer { lock.unlock() }; let value = items; items.removeAll(); return value }
    }

    private final class PromptAcceptanceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var settled = false

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func settle(_ result: Result<Void, Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard !settled else { return nil }
                settled = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }
    }

    private final class Session: @unchecked Sendable {
        let threadId: AgentThreadID
        let providerThreadId: String
        let client: DistillACPClient
        /// Working directory the session was opened with; a provider fork needs it as the source cwd.
        let cwd: String
        /// In-guest run: the session lives for one turn, then the run finishes.
        let guestPlan: DistillGuestLaunchPlan?
        let capabilities: DistillACPInitializeResult
        let mapper: DistillACPEventMapper
        var model: String
        var mainModelSelection: String?
        /// Last effort bound via set_config_option or set_model `_meta.reasoningEffort`.
        var reasoningEffort: AgentReasoningEffort?
        var mainEffortSelection: AgentEffortSelection?
        var reasoningModel: String?
        var reasoningModelEffortSelection: AgentEffortSelection?
        /// Last confirmed mode; a loaded session's persisted mode is unknown until bound. Fresh sessions start in Auto.
        var executionMode: DistillExecutionMode? = .auto
        /// True when open advertised a selectable `reasoning_effort` config option.
        let advertisesReasoningEffortConfig: Bool
        /// Thought-level ids from the open-result config option (and live model catalog).
        let advertisedEfforts: [AgentReasoningEffort]
        /// Live catalog efforts per model id from session/new|load; the static policy only knows a few ids.
        let modelEfforts: [String: [AgentReasoningEffort]]
        /// The session's current model when `advertisedEfforts` was read.
        let advertisedEffortsModelId: String?
        let availableModeIDs: Set<String>
        let planModeID: String?
        var mode: String?
        var status: AgentRunStatus = .completed
        var isLive = true
        var inFlight = false
        var promptAccepted = false
        var cancelRequested = false
        var forcedKillByUs = false
        var turnTerminalEmitted = false
        /// Bumped on every `session/prompt` start so a late RPC result cannot
        /// finish a newer turn after the inactivity watchdog already closed the
        /// previous one (or the user started a follow-up).
        var promptGeneration: UInt64 = 0
        /// One per prompt generation: sendTurn cancels it under `lock` before
        /// bumping `promptGeneration`, so a live one always matches the turn.
        var turnWatchdog: ACPTurnInactivityDeadline?
        /// Force-kill armed for a specific `promptGeneration`. Cancelled when a
        /// newer generation starts so N's timer cannot kill N+1.
        var forceKillWorkItem: DispatchWorkItem?
        /// True while `fireTurnInactivityWatchdog` is synthesizing a terminal.
        /// Blocks emit→refresh→fire re-entry: finishTurn/emit used to re-arm the
        /// inactivity timer mid-synthesis and recurse until SIGBUS (stack guard).
        var turnWatchdogSynthesisInProgress = false
        /// Last event emitted for this session; an open tool call stays alive while it is recent.
        var lastEventAt = Date()
        var promptWritePermit = AgentRunAcceptancePermit()
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var history: DistillACPHistoryRetention
        var pendingPermissions: [String: PendingPermission] = [:]
        /// Provider failure text from `x.ai/session/prompt_complete`
        /// (`stopReason: "error"`) for `generation`. Fallback for peers that
        /// answer the failed `session/prompt` with a bare "Internal error".
        var promptFailureDetail: (generation: UInt64, text: String)?
        /// The inactivity watchdog ended this prompt generation while a tool call
        /// was still open: the tool (a long silent build, say) may still be
        /// running in this process tree until that prompt's response arrives.
        var abandonedOpenToolsGeneration: UInt64?
        /// The provider rejected this session's own history; never prompt it again.
        var historyIncompatible = false
        /// A replacement session publishes its id (the resume cursor) only once
        /// a prompt carrying the handoff is accepted. Until then the persisted
        /// cursor stays on the old session, so a failed switch is retried as a
        /// switch (with the handoff) instead of resuming an empty session.
        var holdsThreadStartedUntilPromptAccepted = false
        var heldThreadStarted = false
        /// Main model last reported in a session-state event for this session.
        var reportedAcceptedModel: String?
        /// Distill `/loop` tasks folded from scheduler notifications.
        var ledger = DistillLoopLedger()
        var loops: [DistillLoopState] { ledger.loops }
        /// Wake-turn (`subagent-completed-<id>`) updates seen while no turn adopts them, per prompt id.
        var pendingWake: [String: [[String: Any]]] = [:]
        var pendingWakeOrder: [String] = []
        /// Wake prompt ids already announced through `onProviderInitiatedTurn` and not yet attached.
        var wakeNotified: Set<String> = []
        /// Terminal of a buffered wake turn that finished before it was attached.
        var completedWake: [String: (stopReason: String, usage: [String: Any]?)] = [:]
        /// Wake prompt ids already adopted by a run; later updates for them are dropped.
        var handledWake: Set<String> = []
        var attachedPromptId: String?
        /// Attach bookkeeping + replay are running: live updates for `attachedPromptId`
        /// queue in `replayBuffer` and its terminal waits in `replayTerminal`.
        var attachReplaying = false
        var replayBuffer: [[String: Any]] = []
        var replayTerminal: (stopReason: String, usage: [String: Any]?)?
        /// Wake prompts the host failed to adopt; skipped until the next turn ends.
        var wakeFailed: Set<String> = []
        /// Wake the watchdog closed with tools still open; its real terminal clears them.
        var abandonedWake: (promptId: String, generation: UInt64)?

        init(
            threadId: AgentThreadID,
            providerThreadId: String,
            client: DistillACPClient,
            cwd: String,
            guestPlan: DistillGuestLaunchPlan? = nil,
            capabilities: DistillACPInitializeResult,
            mapper: DistillACPEventMapper,
            model: String,
            mainModelSelection: String?,
            reasoningEffort: AgentReasoningEffort? = nil,
            mainEffortSelection: AgentEffortSelection? = nil,
            reasoningModel: String? = nil,
            reasoningModelEffortSelection: AgentEffortSelection? = nil,
            advertisesReasoningEffortConfig: Bool = false,
            advertisedEfforts: [AgentReasoningEffort] = [],
            modelEfforts: [String: [AgentReasoningEffort]] = [:],
            advertisedEffortsModelId: String? = nil,
            availableModeIDs: Set<String>,
            planModeID: String?,
            mode: String?,
            maxReadableEvents: Int,
            maxReadableBytes: Int64,
            onEvent: @escaping @Sendable (AgentRunEvent) -> Void
        ) {
            self.threadId = threadId
            self.providerThreadId = providerThreadId
            self.client = client
            self.cwd = cwd
            self.guestPlan = guestPlan
            self.capabilities = capabilities
            self.mapper = mapper
            self.model = model
            self.mainModelSelection = mainModelSelection
            self.reasoningEffort = reasoningEffort
            self.mainEffortSelection = mainEffortSelection
            self.reasoningModel = reasoningModel
            self.reasoningModelEffortSelection = reasoningModelEffortSelection
            self.advertisesReasoningEffortConfig = advertisesReasoningEffortConfig
            self.advertisedEfforts = advertisedEfforts
            self.modelEfforts = modelEfforts
            self.advertisedEffortsModelId = advertisedEffortsModelId
            self.availableModeIDs = availableModeIDs
            self.planModeID = planModeID
            self.mode = mode
            self.history = DistillACPHistoryRetention(
                eventLimit: maxReadableEvents,
                byteLimit: maxReadableBytes
            )
            self.onEvent = onEvent
        }

        /// Live efforts for `modelId` (catalog by canonical or alias id, plus the
        /// open-time `reasoning_effort` option for the then-current model).
        func catalogEfforts(for modelId: String?) -> [AgentReasoningEffort] {
            DistillACPClient.advertisedEfforts(
                for: modelId,
                catalog: modelEfforts,
                currentModelId: advertisedEffortsModelId,
                currentModelEfforts: advertisedEfforts
            )
        }
    }

    private struct PendingPermission {
        let request: DistillACPPermissionRequest
        let continuation: CheckedContinuation<Any?, Error>
    }

    public let provider: AgentProvider = .distill
    private let binaryNameOverride: String?
    private let discoveryRunAsUser: AgentRunAsUser?
    private let cancellationGracePeriod: TimeInterval
    /// Inactivity bound while a prompt is in flight. Re-armed on every emitted
    /// turn event (tools, stream deltas). When `session/prompt` never returns
    /// after the model has finished streaming *and* events stop, this
    /// synthesizes the terminal so Working cannot stick forever (field: 70m
    /// distill zombie with full **COMPLETE** final). There is intentionally **no**
    /// absolute wall-clock max: long goals with continuous tool progress must
    /// not be cut mid-work (field: 15m false `completed` on starsac CI goal).
    private let turnInactivityTimeout: TimeInterval
    /// Silence allowed while a tool call is open (blocking tool waits emit nothing).
    private let openToolQuietLimit: TimeInterval
    private let discoveryCwd: String
    private let discoveryEnvironment: [String: String]
    private let modelCacheTTL: TimeInterval
    private let maxReadableEvents: Int
    private let maxReadableBytes: Int64
    var autoRoutingPreflight: @Sendable (URL) throws -> [DistillAccountStatus] = { try DistillAccounts.autoRoutingAccounts(home: $0) }
    private let lock = NSLock()
    private static let discoveryCacheLock = NSLock()
    private static let discoveryAccountEnvironmentKeys = ["HOME", "DISTILL_HOME", "GROK_HOME", "REMOTE_CODE_INSTANCE"]
    private static var sharedDiscoveryCache: [String: (result: DistillACPDiscoveryResult, fetchedAt: Date, scope: String)] = [:]
    private static var discoveryCacheGenerations: [String: UInt64] = [:]
    private var sessions: [AgentThreadID: Session] = [:]
    /// Loops seeded before the thread's session exists.
    private var pendingSeedLoops: [AgentThreadID: [DistillLoopState]] = [:]
    private var onLoopsChangedStorage: (@Sendable (AgentThreadID, [DistillLoopState]) -> Void)?
    private var onProviderInitiatedTurnStorage: (@Sendable (AgentThreadID, String, String) -> Void)?
    /// Called with the thread's full loop list whenever a scheduler notification changes it.
    public var onLoopsChanged: (@Sendable (AgentThreadID, [DistillLoopState]) -> Void)? {
        get { synchronized { onLoopsChangedStorage } }
        set { synchronized { onLoopsChangedStorage = newValue } }
    }
    /// Called once per provider-initiated (`/loop` wake) turn, after the previous turn ended.
    /// The host answers by starting a run with `attachToProviderPromptId == promptId`.
    public var onProviderInitiatedTurn: (@Sendable (_ threadId: AgentThreadID, _ promptId: String, _ label: String) -> Void)? {
        get { synchronized { onProviderInitiatedTurnStorage } }
        set { synchronized { onProviderInitiatedTurnStorage = newValue } }
    }
    /// Set by AppShell after the adapter is built; nil runs everything on the Mac.
    private var guestLaunchResolver: DistillGuestLaunchResolving?
    var guestRecoveryDiagnosis: @Sendable (DistillGuestRecoveryContext, AgentRunRequest) async throws -> DistillGuestRecoveryAction = {
        try await DistillGuestHostDiagnosis.diagnose($0, request: $1)
    }
    /// Provider sessions whose history the model rejected. A Retry (or a resume
    /// after the live process ended) must open a new session instead of
    /// replaying the same history into the same 400.
    private var retiredProviderThreadIds: Set<String> = []
    private var promptWriteAcceptanceCountForTestingStorage = 0
    var beforePromptWriteForTesting: (() -> Void)?
    /// Runs inside `attachWakeTurn` after adoption and before the replay; tests deliver live wake updates here.
    var beforeAttachReplayForTesting: (() -> Void)?
    var beforePhysicalPromptWriteForTesting: (() -> Void)?
    var afterPromptWriteForTesting: (() -> Void)?
    /// Runs on the cancel-write queue before `session/cancel`. Tests block here
    /// without stalling `interruptTurn`.
    var beforeCancelWriteForTesting: (() -> Void)?
    /// When set, the ACP cancel write is skipped and treated as a diagnostic
    /// failure. Teardown stays armed and the terminal stays cancelled.
    var cancelWriteErrorForTesting: Error?
    private var cancelWriteAttemptCountForTestingStorage = 0
    var cancelWriteAttemptCountForTesting: Int {
        synchronized { cancelWriteAttemptCountForTestingStorage }
    }
    var promptWriteAcceptanceCountForTesting: Int {
        synchronized { promptWriteAcceptanceCountForTestingStorage }
    }
    private var turnWatchdogTimersScheduledForTestingStorage = 0
    /// Inactivity timers the turn watchdog has created (one per prompt turn).
    var turnWatchdogTimersScheduledForTesting: Int {
        synchronized { turnWatchdogTimersScheduledForTestingStorage }
    }

    public init(
        binaryNameOverride: String? = nil,
        cancellationGracePeriod: TimeInterval = 2,
        turnInactivityTimeout: TimeInterval = 900,
        openToolQuietLimit: TimeInterval = 7_200,
        discoveryCwd: String = FileManager.default.temporaryDirectory.path,
        discoveryEnvironment: [String: String] = [:],
        discoveryRunAsUser: AgentRunAsUser? = nil,
        modelCacheTTL: TimeInterval = 300,
        maxReadableEvents: Int = AgentRunCoordinator.hotReplayEventCount,
        maxReadableBytes: Int64 = AgentRunCoordinator.hotReplayEventBytes
    ) {
        self.binaryNameOverride = binaryNameOverride
        self.cancellationGracePeriod = max(0.01, cancellationGracePeriod)
        self.turnInactivityTimeout = max(0.01, turnInactivityTimeout)
        self.openToolQuietLimit = max(0, openToolQuietLimit)
        self.discoveryCwd = discoveryCwd
        self.discoveryEnvironment = discoveryEnvironment
        self.discoveryRunAsUser = discoveryRunAsUser
        self.modelCacheTTL = max(0, modelCacheTTL)
        self.maxReadableEvents = max(1, maxReadableEvents)
        self.maxReadableBytes = max(1, maxReadableBytes)
    }

    public func setGuestLaunchResolver(_ resolver: DistillGuestLaunchResolving?) {
        synchronized { guestLaunchResolver = resolver }
    }

    private func isGuestThread(_ threadId: AgentThreadID) -> Bool {
        synchronized { guestLaunchResolver }?.isGuestThread(threadId) == true
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await listModelsResult().models
    }

    /// Built-in list shown when live discovery fails. Keeps Auto selectable so
    /// Auto routing still works (Distill resolves the route when the run starts).
    static var fallbackModels: [AgentModelDescriptor] {
        DistillRunner.listModels(installedVersion: nil)
            + [AgentModelDescriptor(id: "auto", label: "Auto", provider: .distill, supportsReasoning: true)]
    }

    public func listModelsResult() async -> ModelListResult {
        let discovery = await discoveryResult()
        return ModelListResult(models: discovery.models, isFallback: discovery.isFallback)
    }

    /// Refresh this account's catalog across working directories after account or routing changes.
    public func discoveryResult(forceRefresh: Bool = false) async -> DistillACPDiscoveryResult {
        let now = Date()
        let cacheKey = Self.discoveryCacheKey(
            binary: binaryNameOverride ?? DistillProvisioner.binaryName,
            cwd: discoveryCwd,
            environment: discoveryEnvironment
        )
        let scope = Self.discoveryCacheKey(
            binary: binaryNameOverride ?? DistillProvisioner.binaryName,
            cwd: "",
            environment: discoveryEnvironment.filter { Self.discoveryAccountEnvironmentKeys.contains($0.key) }
        )
        let generation = Self.discoveryCacheGeneration(for: scope, invalidating: forceRefresh)
        if !forceRefresh, let cached = Self.cachedDiscovery(for: cacheKey),
           now.timeIntervalSince(cached.fetchedAt) < modelCacheTTL {
            return cached.result
        }
        let result: DistillACPDiscoveryResult
        do {
            let client = try DistillACPClient(
                binary: binaryNameOverride ?? DistillProvisioner.binaryName,
                cwd: discoveryCwd,
                environment: discoveryEnvironment,
                runAsUser: discoveryRunAsUser,
                tagProcess: Self.discoveryProcessOwnershipTaggingEnabled
            )
            defer { client.stop() }
            let initialized = try await client.initialize()
            // The model-less session only adds its catalog and mode ids. Distill
            // can refuse it (auth_required when no account is routable); that
            // must not discard the catalog and capabilities initialize returned.
            let opened: DistillACPSessionOpenResult?
            do {
                opened = try await client.newSession(
                    cwd: discoveryCwd,
                    reasoningModelSelectionSupported: false
                )
            } catch {
                distillAcpLog.error("Distill discovery session/new failed: \(String(describing: error), privacy: .public)")
                opened = nil
            }
            let discovered = Self.mergeModelCatalogs(initialized.models, opened?.models ?? [])
            let modeIDs = Set(opened?.availableModes.map(\.id) ?? [])
            // Live distill builds often omit `modes.availableModes` from session/new
            // while still accepting session/set_mode for the CLI wire IDs
            // (default / acceptEdits / bypassPermissions / plan). Live canary
            // confirms set_mode plan succeeds when the catalog is omitted.
            // Empty catalog → open Plan (same pattern as permission modes).
            // When modes ARE advertised, only expose the negotiated subset
            // (fail-closed for Plan if plan is absent from the catalog).
            let interactionModes = Self.interactionModes(
                availableModeIDs: modeIDs,
                advertisedPlanModeID: opened?.planModeId
            )
            let permissionModes = Self.permissionModes(from: modeIDs)
            // Attachment kinds for iOS/macOS pickers.
            // distill reports promptCapabilities.image=false while still accepting
            // type=image blocks (live semantic canary). Advertise the effective
            // capability so Camera/Photos are not marked Unavailable on the mirror.
            var attachmentKinds: [AgentAttachmentKind] = []
            if initialized.embeddedContext { attachmentKinds.append(.file) }
            let imageEnabled = DistillACPImageCompatibility.effectiveImageEnabled(
                advertised: initialized.image,
                agentVersion: initialized.agentVersion
            )
            if imageEnabled { attachmentKinds.append(.image) }
            var mediaTypes = initialized.embeddedContext
                ? ["text/plain", "text/markdown", "application/json"]
                : []
            if imageEnabled {
                mediaTypes.append(contentsOf: DistillACPImageCompatibility.supportedImageMediaTypes)
            }
            let capabilities = AgentProviderCapabilities(
                supportsAttachments: !attachmentKinds.isEmpty,
                supportedAttachmentKinds: attachmentKinds,
                supportedAttachmentMediaTypes: mediaTypes,
                supportsApprovals: true,
                supportsUserInput: false,
                supportsStreaming: true,
                supportsFork: initialized.sessionForkDurable,
                supportsRollback: false,
                supportsPlanReview: interactionModes.contains(.plan),
                supportsDistillMainEffortAuto: true,
                supportsDistillReasoningModelEffort: initialized.sessionWorkerModel
            )
            result = discovered.isEmpty
                ? DistillACPDiscoveryResult(
                    models: Self.fallbackModels,
                    isFallback: true,
                    interactionModes: [.default],
                    permissionModes: Self.defaultPermissionModes,
                    capabilities: AgentProviderCapabilities(supportsDistillMainEffortAuto: true),
                    discoveryCacheKey: cacheKey
                )
                : DistillACPDiscoveryResult(
                    models: discovered,
                    isFallback: false,
                    interactionModes: interactionModes,
                    permissionModes: permissionModes,
                    capabilities: capabilities,
                    discoveryCacheKey: cacheKey
                )
        } catch {
            result = DistillACPDiscoveryResult(
                models: Self.fallbackModels,
                isFallback: true,
                interactionModes: [.default],
                permissionModes: Self.defaultPermissionModes,
                capabilities: AgentProviderCapabilities(supportsDistillMainEffortAuto: true),
                discoveryCacheKey: cacheKey
            )
        }
        // A fallback (e.g. initialize timed out while many Distill processes
        // start at app launch) must not stick for the TTL; the next open retries.
        if !result.isFallback {
            Self.storeDiscovery(result, for: cacheKey, scope: scope, generation: generation, fetchedAt: now, ttl: modelCacheTTL)
        }
        return result
    }

    /// Initialization and session/new can advertise different portions of the
    /// current account catalog. Keep the union and let the later session/new
    /// response own duplicate IDs because it is the current negotiated session
    /// metadata; do not infer authority from a metadata score.
    nonisolated static func mergeModelCatalogs(_ catalogs: [AgentModelDescriptor]...) -> [AgentModelDescriptor] {
        var merged: [AgentModelDescriptor] = []
        var indexes: [String: Int] = [:]
        for catalog in catalogs {
            for model in catalog {
                guard !model.id.isEmpty else { continue }
                if let index = indexes[model.id] {
                    merged[index] = model
                } else {
                    indexes[model.id] = merged.count
                    merged.append(model)
                }
            }
        }
        return merged
    }

    /// Opaque identity for one binary/account configuration. File metadata makes
    /// an in-place CLI update invalidate a still-live adapter's discovery cache;
    /// hashing prevents HOME or account-scoped environment values from leaking.
    nonisolated static func discoveryCacheKey(
        binary: String,
        cwd: String,
        environment: [String: String]
    ) -> String {
        let resolvedBinary = ProcessLocator.resolveDistillAgent(binary) ?? binary
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedBinary)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let environmentKeys = environment.keys.sorted().joined(separator: "\u{1f}")
        let accountSelectors = discoveryAccountEnvironmentKeys
            .map { "\($0)=\(environment[$0] ?? "")" }
            .joined(separator: "\u{1f}")
        let input = "distill-acp-v1\u{1e}\(resolvedBinary)\u{1e}\(size)\u{1e}\(modified)\u{1e}\(cwd)\u{1e}\(environmentKeys)\u{1e}\(accountSelectors)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        // PERF: nibble table avoids String(format:) per discovery; same lowercase 16-hex.
        let hex = DistillACPAdapter.hex16(hash)
        return "distill-acp-v1-\(hex)"
    }

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)
    private static func hex16(_ value: UInt64) -> String {
        var out: [UInt8] = Array(repeating: 0, count: 16)
        var v = value
        for i in (0..<16).reversed() {
            out[i] = hexAlphabet[Int(v & 0xf)]
            v >>= 4
        }
        return String(bytes: out, encoding: .utf8) ?? String(format: "%016llx", value)
    }

    private static func cachedDiscovery(for key: String) -> (result: DistillACPDiscoveryResult, fetchedAt: Date)? {
        discoveryCacheLock.lock()
        defer { discoveryCacheLock.unlock() }
        guard let cached = sharedDiscoveryCache[key] else { return nil }
        return (cached.result, cached.fetchedAt)
    }

    private static func discoveryCacheGeneration(for scope: String, invalidating: Bool) -> UInt64 {
        discoveryCacheLock.lock()
        defer { discoveryCacheLock.unlock() }
        if invalidating {
            discoveryCacheGenerations[scope, default: 0] &+= 1
            sharedDiscoveryCache = sharedDiscoveryCache.filter { $0.value.scope != scope }
        }
        return discoveryCacheGenerations[scope, default: 0]
    }

    private static func storeDiscovery(
        _ result: DistillACPDiscoveryResult,
        for key: String,
        scope: String,
        generation: UInt64,
        fetchedAt: Date,
        ttl: TimeInterval
    ) {
        discoveryCacheLock.lock()
        defer { discoveryCacheLock.unlock() }
        guard discoveryCacheGenerations[scope, default: 0] == generation else { return }
        // A discovery started before a forced refresh must not replace its newer result.
        if let cached = sharedDiscoveryCache[key], cached.fetchedAt > fetchedAt { return }
        sharedDiscoveryCache = sharedDiscoveryCache.filter {
            fetchedAt.timeIntervalSince($0.value.fetchedAt) < max(ttl, 1)
        }
        sharedDiscoveryCache[key] = (result, fetchedAt, scope)
    }

    private func validateAutoRouting(_ request: AgentRunRequest) throws {
        guard request.attachToProviderPromptId == nil,
              request.model.trimmingCharacters(in: .whitespacesAndNewlines) == "auto",
              request.runAsUser.map({ $0.uid == getuid() }) ?? true else { return }
        let environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, run in run }
        let userHome = request.runAsUser?.homePath ?? FileManager.default.homeDirectoryForCurrentUser.path
        _ = try autoRoutingPreflight(DistillProvisioner.homeURL(environment: environment, userHome: userHome))
    }

    public func startSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try validateAutoRouting(request)
        return try await openSession(request, loadExisting: false, onEvent: onEvent, startPrompt: true)
    }

    public func sendTurn(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderAdapterError.unsupported("Select an explicit Distill Main model before running.")
        }
        if request.attachToProviderPromptId == nil { try validateAutoRouting(request) }
        if let promptId = request.attachToProviderPromptId {
            return try attachWakeTurn(request, promptId: promptId, onEvent: onEvent)
        }
        let existing = synchronized { sessions[request.threadId] }
        guard let existing else {
            if let resumeId = request.providerThreadId, !resumeId.isEmpty {
                let retired = request.priorProviderSessionRetired
                    || synchronized { retiredProviderThreadIds.contains(resumeId) }
                let previousModel = request.priorProviderSessionModel
                let reason: FreshSessionReason?
                if retired {
                    reason = .incompatibleHistory
                } else if Self.isCrossModelFamilySwitch(from: previousModel, to: request.model) {
                    reason = .modelFamilySwitch(from: previousModel ?? "")
                } else {
                    reason = nil
                }
                if let reason {
                    return try await openFreshSession(request, reason: reason, onEvent: onEvent)
                }
            }
            return try await openSession(
                request,
                loadExisting: request.providerThreadId?.isEmpty == false,
                onEvent: onEvent,
                startPrompt: true
            )
        }
        let reason: FreshSessionReason? = synchronized {
            // An in-flight session is never replaced; startPrompt refuses it.
            guard !existing.inFlight else { return nil }
            if existing.historyIncompatible || retiredProviderThreadIds.contains(existing.providerThreadId) {
                return .incompatibleHistory
            }
            let previousModel = existing.mainModelSelection == "auto" && request.model != "auto"
                ? existing.model : (existing.mainModelSelection ?? existing.model)
            return Self.isCrossModelFamilySwitch(from: previousModel, to: request.model)
                ? .modelFamilySwitch(from: previousModel)
                : nil
        }
        if let reason {
            return try await openFreshSession(request, reason: reason, onEvent: onEvent)
        }
        try await startPrompt(request, session: existing, onEvent: onEvent)
        return handle(for: request.runId, session: existing)
    }

    /// Why a turn must run in a new Distill session instead of the thread's one.
    enum FreshSessionReason: Equatable {
        /// Main moved between model families. Distill replays the old family's
        /// reasoning items verbatim (Anthropic receives unsigned `thinking`
        /// blocks and rejects the whole request), so the old session cannot
        /// serve the new model.
        case modelFamilySwitch(from: String)
        /// The provider already rejected this session's history.
        case incompatibleHistory
    }

    enum ModelFamily: Equatable {
        /// `claude/*` models served through the Anthropic Messages API.
        case anthropicMessages
        case other
    }

    /// Distill has no backend field in its ACP model catalog, so the family is
    /// derived from the id prefix Distill gives its Anthropic models.
    static func modelFamily(of modelId: String) -> ModelFamily {
        let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id.hasPrefix("claude/") || id.hasPrefix("anthropic/") ? .anthropicMessages : .other
    }

    static func isCrossModelFamilySwitch(from previousModel: String?, to nextModel: String) -> Bool {
        let previous = previousModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let next = nextModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, !next.isEmpty, previous != "auto", next != "auto" else { return false }
        return modelFamily(of: previous) != modelFamily(of: next)
    }

    struct FreshSessionSeed: Sendable {
        let handoff: String
        let notice: String
    }

    static let modelFamilySwitchNotice = "Switched model family — started a new Distill session"
    static let incompatibleHistoryNotice = "The model rejected the previous Distill session's history — started a new Distill session"
    /// Appended to the notice: the new session got a compact summary of the
    /// conversation (the row renders as a compaction), or nothing at all.
    static let handoffCarriedNoticeSuffix = " with a summary of this conversation"
    static let handoffMissingNoticeSuffix = "; the earlier conversation could not be carried over"
    static let handoffMaxCharacters = 16_000
    static let handoffMaxItemCharacters = 2_000
    /// Newest prior messages the coordinator reads for a handoff.
    static let handoffMaxMessages = 60

    struct HandoffMessage: Equatable {
        let isUser: Bool
        let text: String
    }

    /// Compact handoff of the app's own transcript for the first prompt of a
    /// replacement session. `history` is oldest first; the newest messages win
    /// the budget. `olderHistoryExists` says messages before `history` exist.
    static func freshSessionHandoff(
        reason: FreshSessionReason,
        newModel: String,
        history: [HandoffMessage],
        olderHistoryExists: Bool = false
    ) -> String {
        var header = "[RemoteCode context handoff] This conversation started in an earlier Distill session"
        switch reason {
        case .modelFamilySwitch(let previousModel):
            header += " on \(previousModel). It moved to \(newModel), a different model family, so it continues in a new session."
        case .incompatibleHistory:
            header += " whose history \(newModel) rejected, so it continues in a new session."
        }
        header += " Earlier tool results and files read are not loaded here; re-read anything you need."
        let items = history.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !items.isEmpty else {
            return header + " The earlier conversation is not available; ask the user for any detail you need from it."
        }
        var budget = handoffMaxCharacters
        var kept: [String] = []
        for item in items.reversed() {
            let speaker = item.isUser ? "User" : "Assistant"
            var text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > handoffMaxItemCharacters {
                text = String(text.prefix(handoffMaxItemCharacters)) + "…"
            }
            let line = "\(speaker): \(text)"
            guard line.count <= budget else { break }
            budget -= line.count
            kept.append(line)
        }
        var body = header + " Earlier conversation, oldest first:"
        if olderHistoryExists || kept.count < items.count {
            body += "\n\n(earlier messages omitted)"
        }
        for line in kept.reversed() {
            body += "\n\n" + line
        }
        return body + "\n\n[End of handoff. The user's new message follows.]"
    }

    /// The coordinator's newest-first tail (no size ceiling) wins; the RCSEED
    /// snapshot, which is nil for long threads, is only a fallback.
    static func handoffHistory(for request: AgentRunRequest) -> (messages: [HandoffMessage], olderHistoryExists: Bool) {
        if let tail = request.priorConversationTail {
            let messages = tail.compactMap { message -> HandoffMessage? in
                switch message.role {
                case .user: return HandoffMessage(isUser: true, text: message.content)
                case .assistant: return HandoffMessage(isUser: false, text: message.content)
                case .system: return nil
                }
            }
            return (Array(messages.suffix(handoffMaxMessages)), messages.count > handoffMaxMessages)
        }
        let items = request.contextSnapshot?.items ?? []
        return (items.map { HandoffMessage(isUser: $0.role == .user, text: $0.canonicalText) }, false)
    }

    private func openFreshSession(
        _ request: AgentRunRequest,
        reason: FreshSessionReason,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        guard synchronized({ guestLaunchResolver })?.preservesSessionIdentity(request.threadId) != true else {
            throw DistillGuestLaunchError.unavailable("Scoped Distill sessions cannot be replaced with a fresh session.")
        }
        let reasonLabel: String
        let notice: String
        switch reason {
        case .modelFamilySwitch:
            reasonLabel = "model_family_switch"
            notice = Self.modelFamilySwitchNotice
        case .incompatibleHistory:
            reasonLabel = "incompatible_history"
            notice = Self.incompatibleHistoryNotice
        }
        let history = Self.handoffHistory(for: request)
        let carried = history.messages.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        distillAcpLog.info(
            "distill.session.fresh thread=\(request.threadId.value.uuidString, privacy: .public) reason=\(reasonLabel, privacy: .public) handoff_messages=\(history.messages.count, privacy: .public)"
        )
        return try await openSession(
            request,
            loadExisting: false,
            onEvent: onEvent,
            startPrompt: true,
            freshSession: FreshSessionSeed(
                handoff: Self.freshSessionHandoff(
                    reason: reason,
                    newModel: request.model,
                    history: history.messages,
                    olderHistoryExists: history.olderHistoryExists
                ),
                notice: notice + (carried ? Self.handoffCarriedNoticeSuffix : Self.handoffMissingNoticeSuffix)
            )
        )
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        let captured: (session: Session, generation: UInt64)? = synchronized {
            guard let session = sessions[threadId] else { return nil }
            let shouldCancel = session.inFlight && !session.cancelRequested
            guard shouldCancel else { return nil }
            session.cancelRequested = true
            let generation = session.promptGeneration
            armForceKillLocked(session: session, generation: generation)
            return (session, generation)
        }
        guard let captured else {
            if synchronized({ sessions[threadId] == nil }) {
                throw AgentProviderAdapterError.sessionNotFound(threadId)
            }
            return
        }
        enqueueCancelWrite(session: captured.session, generation: captured.generation)
    }

    private func armForceKillLocked(session: Session, generation: UInt64) {
        session.forceKillWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.forceKillIfCurrent(session: session, generation: generation)
        }
        session.forceKillWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + cancellationGracePeriod,
            execute: item
        )
        distillAcpLog.info(
            "distill.cancel.force.armed thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
        )
    }

    private func enqueueCancelWrite(session: Session, generation: UInt64) {
        distillAcpLog.info(
            "distill.cancel.enqueue thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
        )
        DispatchQueue.global(qos: .utility).async { [weak self, weak session] in
            guard let self, let session else { return }
            self.beforeCancelWriteForTesting?()
            if let injected = self.cancelWriteErrorForTesting {
                distillAcpLog.info(
                    "distill.cancel.write.failed thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public) injected=1"
                )
                _ = injected
                return
            }
            do {
                let wrote = try session.client.cancel(
                    sessionId: session.providerThreadId,
                    admittedBy: { [weak self, weak session] in
                        guard let self, let session else { return false }
                        return self.synchronized {
                            let current = self.sessions[session.threadId] === session
                                && session.promptGeneration == generation
                                && session.inFlight
                                && !session.turnTerminalEmitted
                                && session.cancelRequested
                            if current {
                                self.cancelWriteAttemptCountForTestingStorage += 1
                            }
                            return current
                        }
                    }
                )
                if !wrote {
                    distillAcpLog.info(
                        "distill.cancel.write.stale thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
                    )
                }
            } catch {
                distillAcpLog.info(
                    "distill.cancel.write.failed thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
                )
            }
        }
    }

    private func forceKillIfCurrent(session: Session, generation: UInt64) {
        lock.lock()
        let current = sessions[session.threadId] === session
            && session.promptGeneration == generation
            && session.inFlight
            && !session.turnTerminalEmitted
            && session.cancelRequested
        if current {
            session.forcedKillByUs = true
            // Retain map identity for handleTermination's one terminal, but
            // close reuse before dropping the lock. A natural N completion in
            // the tiny interval before client.stop cannot admit N+1.
            session.isLive = false
            session.promptWritePermit.invalidate()
        }
        lock.unlock()
        guard current else {
            distillAcpLog.info(
                "distill.cancel.force.stale thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
            )
            return
        }
        distillAcpLog.info(
            "distill.cancel.force.kill thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
        )
        pauseLoopsForStoppedSession(session: session)
        session.client.stop()
    }

    public func respondToRequest(
        threadId: AgentThreadID,
        requestId: String,
        response: AgentProviderRequestResponse
    ) async throws {
        let (session, pending): (Session, PendingPermission) = try synchronized {
            guard let session = sessions[threadId] else {
                throw AgentProviderAdapterError.sessionNotFound(threadId)
            }
            guard let pending = session.pendingPermissions.removeValue(forKey: requestId) else {
                throw AgentProviderAdapterError.unsupported("Distill ACP permission request not found: \(requestId)")
            }
            return (session, pending)
        }

        let result: [String: Any]
        let state: AssistantRequestState
        if case .cancel = response {
            result = ["outcome": ["outcome": "cancelled"]]
            state = .cancelled
        } else if let optionId = pending.request.optionId(for: response) {
            result = ["outcome": ["outcome": "selected", "optionId": optionId]]
            switch response {
            case .approve, .approveForSession: state = .approved
            case .decline: state = .declined
            case .cancel: state = .cancelled
            }
        } else {
            pending.continuation.resume(throwing: AgentProviderAdapterError.unsupported("Distill ACP permission option unavailable for response"))
            throw AgentProviderAdapterError.unsupported("Distill ACP permission option unavailable for response")
        }
        emit(.requestResolved(requestId: requestId, state: state), session: session)
        pending.continuation.resume(returning: result)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("Distill ACP 0.2.101 does not negotiate user-input elicitation")
    }

    public func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        guard let session = sessions.removeValue(forKey: threadId) else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        session.isLive = false
        session.promptWritePermit.invalidate()
        let pending = Array(session.pendingPermissions.values)
        session.pendingPermissions.removeAll()
        lock.unlock()
        for request in pending {
            request.continuation.resume(throwing: AgentProviderAdapterError.sessionNotFound(threadId))
        }
        // Before the client stops: its exit would otherwise finish the run first.
        session.guestPlan?.finish(.cancelled)
        // Hard teardown must never queue behind the cooperative cancel write.
        // The first Stop already enqueued session/cancel; a second Stop owns
        // transport termination and goes straight to the process tree.
        session.client.stop()
    }

    public func recoverSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Distill ACP recovery requires providerThreadId")
        }
        // A guest run holds the bot's guest, credentials and lease; none is
        // started to reopen a thread. The next send loads the session in the
        // guest, and the transcript comes from the app's own record.
        if isGuestThread(request.threadId) { return }
        _ = try await openSession(request, loadExisting: true, onEvent: onEvent, startPrompt: false)
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.map {
            AgentProviderSessionSummary(
                threadId: $0.threadId,
                provider: .distill,
                status: $0.status,
                providerThreadId: $0.providerThreadId,
                toolsMayStillRun: $0.abandonedOpenToolsGeneration != nil
            )
        }
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    /// True when a provider session exists for the thread. A guest thread has none until its next turn.
    public func hasLiveSession(threadId: AgentThreadID) -> Bool {
        synchronized { sessions[threadId]?.isLive ?? false }
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        if let events = synchronized({ sessions[threadId]?.history.readableEvents }) { return events }
        // recoverSession opens nothing for a guest thread.
        if isGuestThread(threadId) { return [] }
        throw AgentProviderAdapterError.sessionNotFound(threadId)
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        throw AgentProviderAdapterError.unsupported("Distill ACP 0.2.101 does not negotiate rollback")
    }

    /// Provider fork is keyed-idempotent: the child session id is UUIDv5(idempotencyKey), so a
    /// retried fork converges on the same child, and `compensateFork` deletes it.
    public var forkSafety: AgentProviderForkSafety { .keyedIdempotent(compensationSupported: true) }

    /// A guest thread has no Mac session to fork (`forkThread` refuses it), so it
    /// must not advertise a durable fork: the coordinator would write a fork intent first.
    public func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety {
        isGuestThread(threadId) ? .unsupported : .keyedIdempotent(compensationSupported: true)
    }

    /// Namespace for deterministic fork child session ids. Fixed so the same idempotency key
    /// always maps to the same Distill session id.
    static let forkChildNamespace = UUID(uuidString: "8f2a6c1e-4b3d-5a7f-9c0e-2d1b4a6f8c3e")!

    /// UUIDv5(namespace, name): SHA-1 based, deterministic.
    static func deterministicForkChildId(namespace: UUID = forkChildNamespace, idempotencyKey: String) -> String {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(idempotencyKey.utf8))
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)))
        digest[6] = (digest[6] & 0x0f) | 0x50 // version 5
        digest[8] = (digest[8] & 0x3f) | 0x80 // RFC 4122 variant
        let uuid = uuid_t(
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: uuid).uuidString.lowercased()
    }

    /// Forks the source thread's live Distill session into the request's deterministic child id.
    public func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        guard !isGuestThread(request.sourceThreadId) else {
            throw AgentProviderAdapterError.unsupported("Distill guest threads cannot fork a provider session")
        }
        let childId = Self.deterministicForkChildId(idempotencyKey: request.idempotencyKey)
        // A live session forks through its own client. Otherwise Distill forks
        // the saved session from disk, so a thread not used since launch can
        // still fork (a short-lived process, like `compensateFork`).
        if let source = synchronized({ sessions[request.sourceThreadId] }) {
            guard childId != source.providerThreadId else {
                throw AgentProviderAdapterError.unsupported("provider-native fork did not return a distinct child session")
            }
            let newCwd = request.workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? source.cwd
            return try await Self.rejectingFork {
                try await source.client.forkSession(
                    sourceSessionId: source.providerThreadId,
                    sourceCwd: source.cwd,
                    newCwd: newCwd,
                    newSessionId: childId,
                    kind: "fork"
                )
            }
        }
        guard let sourceSessionId = request.sourceProviderThreadId, !sourceSessionId.isEmpty else {
            throw AgentProviderAdapterError.forkRejected("this thread has no Distill session to fork yet")
        }
        guard childId != sourceSessionId else {
            throw AgentProviderAdapterError.unsupported("provider-native fork did not return a distinct child session")
        }
        // Distill stores sessions per directory: the source's own cwd finds it.
        guard let sourceCwd = request.sourceWorkingDirectory ?? request.workingDirectory.flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw AgentProviderAdapterError.forkRejected("the saved Distill session's folder is unknown")
        }
        let newCwd = request.workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? sourceCwd
        let client = try DistillACPClient(
            binary: binaryNameOverride ?? DistillProvisioner.binaryName,
            cwd: sourceCwd
        )
        defer { client.stop() }
        _ = try await client.initialize()
        return try await Self.rejectingFork {
            try await client.forkSession(
                sourceSessionId: sourceSessionId,
                sourceCwd: sourceCwd,
                newCwd: newCwd,
                newSessionId: childId,
                kind: "fork"
            )
        }
    }

    /// JSON-RPC refusals (method not found, invalid params or request) mean
    /// Distill created no child; anything else (timeouts, a dead process) may
    /// have, so it stays recoverable and retries converge on the same child.
    static func rejectingFork(_ body: () async throws -> String) async throws -> String {
        do {
            return try await body()
        } catch let DistillACPError.rpcError(code, message, detail, _) where [-32601, -32602, -32600].contains(code ?? 0) {
            throw AgentProviderAdapterError.forkRejected(ACPRPCErrorPayload.describe(message: message, detail: detail))
        }
    }

    /// Deletes the provider child session. Uses the live client when the source or child is
    /// resident; otherwise opens a short-lived Distill process, since `x.ai/session/delete`
    /// does not need the session to be resident.
    public func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws {
        let cwd = request.workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? discoveryCwd
        if let client = synchronized({
            sessions[request.childThreadId]?.client ?? sessions[request.sourceThreadId]?.client
        }) {
            try await client.deleteSession(sessionId: providerChildThreadId, cwd: cwd)
            return
        }
        let client = try DistillACPClient(
            binary: binaryNameOverride ?? DistillProvisioner.binaryName,
            cwd: cwd
        )
        defer { client.stop() }
        _ = try await client.initialize()
        try await client.deleteSession(sessionId: providerChildThreadId, cwd: cwd)
    }

    /// Side question against the thread's live Distill session; never interrupts the active turn.
    public func btw(threadId: AgentThreadID, question: String) async throws -> String {
        guard let session = synchronized({ sessions[threadId] }) else {
            throw AgentProviderAdapterError.unsupported("Distill ACP side question requires a live session")
        }
        return try await session.client.btw(sessionId: session.providerThreadId, question: question)
    }

    public func stopAll() {
        lock.lock()
        let all = Array(sessions.values)
        all.forEach {
            $0.isLive = false
            $0.promptWritePermit.invalidate()
        }
        sessions.removeAll()
        lock.unlock()
        all.forEach {
            $0.guestPlan?.finish(.cancelled)
            $0.client.stop()
        }
    }

    public func stopAllForAppTermination() {
        lock.lock()
        let all = Array(sessions.values)
        all.forEach {
            $0.isLive = false
            $0.promptWritePermit.invalidate()
        }
        sessions.removeAll()
        lock.unlock()
        all.forEach { $0.client.stopImmediatelyForAppTermination() }
    }

    public func streamEvents(
        threadId: AgentThreadID,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[threadId] else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        session.onEvent = onEvent
    }

    /// Stored-session cwd for a resume, or `request.cwd` when no stored session
    /// directory exists. Host runs only; the guest plan owns its own cwd.
    static func resumeCwd(for request: AgentRunRequest) -> String {
        guard let sessionId = request.providerThreadId, !sessionId.isEmpty else { return request.cwd }
        let userHome = request.runAsUser?.homePath ?? FileManager.default.homeDirectoryForCurrentUser.path
        let home = DistillProvisioner.homeURL(environment: request.environment, userHome: userHome)
        let sessionsRoot = home.appendingPathComponent("sessions", isDirectory: true)
        guard let stored = storedSessionCwd(sessionsRoot: sessionsRoot, sessionId: sessionId),
              stored != request.cwd else { return request.cwd }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stored, isDirectory: &isDirectory), isDirectory.boolValue else {
            return request.cwd
        }
        distillAcpLog.info(
            "Distill resume cwd switched to stored session cwd thread=\(request.threadId.description, privacy: .public) session=\(sessionId, privacy: .public)"
        )
        return stored
    }

    /// Finds `<sessionsRoot>/<encoded cwd>/<sessionId>` and returns its cwd:
    /// `summary.json` `info.cwd` first, else the percent-decoded parent name.
    public static func storedSessionCwd(sessionsRoot: URL, sessionId: String) -> String? {
        guard !sessionId.isEmpty, !sessionId.contains("/"), !sessionId.contains("..") else { return nil }
        let fileManager = FileManager.default
        guard let groups = try? fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for group in groups {
            let sessionDirectory = group.appendingPathComponent(sessionId, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sessionDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            if let data = try? Data(contentsOf: sessionDirectory.appendingPathComponent("summary.json")),
               let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let info = summary["info"] as? [String: Any],
               let cwd = info["cwd"] as? String, cwd.hasPrefix("/") {
                return cwd
            }
            if let cwd = group.lastPathComponent.removingPercentEncoding, cwd.hasPrefix("/") {
                return cwd
            }
        }
        return nil
    }

    private func openSession(
        _ request: AgentRunRequest,
        loadExisting: Bool,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void,
        startPrompt shouldStartPrompt: Bool,
        freshSession: FreshSessionSeed? = nil
    ) async throws -> AgentRunHandle {
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderAdapterError.unsupported("Select an explicit Distill Main model before running.")
        }
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.providerBinary!
            : (binaryNameOverride ?? DistillProvisioner.binaryName)
        let bufferedNotifications = NotificationBuffer()
        // Never falls back to the Mac: a guest thread that cannot run in its
        // guest fails here.
        let resolver = synchronized { guestLaunchResolver }
        // Acknowledge a guest send before any guest work: preparing the VM,
        // the agent binary and the sign-in can take seconds.
        if resolver?.isGuestThread(request.threadId) == true {
            onEvent(.event(DistillGuestStage.starting.runtimeEvent))
        }
        let guestPlan = try await resolver?.prepare(request, progress: { stage in
            onEvent(.event(stage.runtimeEvent))
        })
        // The resolver's two answers must agree. A guest thread without a plan
        // would run on the Mac; a plan on an open that sends no prompt would
        // hold the bot's guest, credentials and lease with no turn to end it.
        if guestPlan == nil, resolver?.isGuestThread(request.threadId) == true {
            throw AgentProviderAdapterError.unsupported(
                "This bot thread runs in its Linux guest, but no guest launch was prepared; it will not run on the Mac."
            )
        }
        if let guestPlan, !shouldStartPrompt {
            guestPlan.finish(.cancelled)
            throw AgentProviderAdapterError.unsupported(
                "A bot guest run was prepared for a session open that sends no prompt."
            )
        }
        // A resumed session runs in the cwd Distill stored it under; entry points
        // disagree on cwd and session/load fails when the path differs.
        let cwd = guestPlan == nil && loadExisting ? Self.resumeCwd(for: request) : request.cwd
        let client: DistillACPClient
        do {
            if let guestPlan {
                client = try DistillACPClient(
                    guest: guestPlan,
                    notificationHandler: { method, params in
                        if method == DistillACPClient.operationMethod {
                            onEvent(.event(Self.runtimeEvent(method: method, payload: params as? [String: Any] ?? [:])))
                        } else {
                            bufferedNotifications.append(method: method, params: params)
                        }
                    }
                )
            } else {
                let launchArguments = try DistillACPClient.launchArguments(for: request)
                let isForeignUser = request.runAsUser.map { $0.uid != getuid() } == true
                let askpass = isForeignUser
                    ? RunAsUserProcessBootstrap.materializeAskpass(
                        targetUser: request.runAsUser!.shortName
                    )
                    : nil
                client = try DistillACPClient(
                    binary: binary,
                    cwd: cwd,
                    environment: request.environment,
                    launchArguments: launchArguments,
                    runAsUser: request.runAsUser,
                    askpassPath: askpass,
                    notificationHandler: { method, params in
                        if method == DistillACPClient.operationMethod {
                            onEvent(.event(Self.runtimeEvent(method: method, payload: params as? [String: Any] ?? [:])))
                        } else {
                            bufferedNotifications.append(method: method, params: params)
                        }
                    }
                )
            }
        } catch {
            guestPlan?.finish(.failed)
            throw DistillACPFailureTaxonomy.normalize(
                error,
                context: loadExisting ? .resume : .start
            )
        }
        // Stop before the prompt is accepted ends the open now instead of after
        // initialize/session/new/set_model; the coordinator records the Stop.
        request.acceptancePermit?.onInvalidate { [weak client] in client?.stop() }
        // Both fresh and resumed turns validate the guest catalog before any
        // prompt is sent; the resolver verifies the live run's ownership.
        if guestPlan != nil, let resolver {
            let diagnose = synchronized { guestRecoveryDiagnosis }
            client.guestCatalogRecovery = {
                let work = Task {
                    try Task.checkCancellation()
                    var actions: [DistillGuestRecoveryAction] = [.refreshGuestCatalog, .stop]
                    if resolver.supportsGuestRecovery { actions.insert(.resynchronizeGuest, at: 0) }
                    onEvent(.event(DistillGuestStage.diagnosing.runtimeEvent))
                    let action = try await diagnose(.init(category: .catalog, availableActions: actions), request)
                    try Task.checkCancellation()
                    guard actions.contains(action), action != .stop else { return false }
                    onEvent(.event(DistillGuestStage.repairing.runtimeEvent))
                    if action == .resynchronizeGuest, try await !resolver.resynchronizeGuest(request) { return false }
                    try Task.checkCancellation()
                    onEvent(.event(DistillGuestStage.verifying.runtimeEvent))
                    return true
                }
                request.acceptancePermit?.onInvalidate { work.cancel() }
                return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            }
            client.guestCatalogRecoveryFinished = { restored in
                onEvent(.event((restored ? DistillGuestStage.recovered : .repairFailed).runtimeEvent))
            }
        }
        defer {
            client.guestCatalogRecovery = nil
            client.guestCatalogRecoveryFinished = nil
        }
        do {
            let capabilities = try await client.initialize(
                timeout: DistillGuestLaunchPlan.initializeTimeout
            )
            if let guestPlan {
                // The docker CLI read it before the guest could answer.
                unlink(guestPlan.envFileURL.path)
            }
            let opened: DistillACPSessionOpenResult
            let mainEffort = request.distillMainEffortSelection.map(\.effort) ?? request.reasoningEffort
            if loadExisting {
                guard capabilities.loadSession, let providerThreadId = request.providerThreadId, !providerThreadId.isEmpty else {
                    throw AgentProviderAdapterError.unsupported("Distill ACP session/load is not negotiated")
                }
                // Warm reattach + prompt: skip gateway replay cost (hydrate is local-only).
                // Recover without prompt: keep full replay so readThread has history.
                opened = try await client.loadSession(
                    sessionId: providerThreadId,
                    cwd: cwd,
                    noReplay: shouldStartPrompt,
                    yoloMode: request.permissionMode == .fullAccess,
                    modelId: request.model,
                    reasoningEffort: mainEffort,
                    mainEffortSelection: request.distillMainEffortSelection,
                    reasoningModel: request.reasoningModel,
                    reasoningModelEffortSelection: request.distillReasoningEffortSelection,
                    reasoningModelSelectionSupported: capabilities.sessionWorkerModel
                )
            } else {
                opened = try await client.newSession(
                    cwd: request.cwd,
                    yoloMode: request.permissionMode == .fullAccess,
                    modelId: request.model,
                    reasoningEffort: mainEffort,
                    mainEffortSelection: request.distillMainEffortSelection,
                    reasoningModel: request.reasoningModel,
                    reasoningModelEffortSelection: request.distillReasoningEffortSelection,
                    reasoningModelSelectionSupported: capabilities.sessionWorkerModel,
                    rules: BotRunMCPAdmission.distillSessionRules(environment: request.environment)
                )
            }
            try guestPlan?.recordSessionOpened(opened.sessionId)
            // The guest agent is up with its MCP servers: the strip goes back to the turn's own status.
            if guestPlan != nil { onEvent(.event(DistillGuestStage.ready.runtimeEvent)) }
            let mapper = DistillACPEventMapper(sessionId: opened.sessionId)
            // Seed mode so plan session updates can tell live progress from Plan review.
            let availableModeIDs = Set(opened.availableModes.map(\.id))
            let planModeID = Self.resolvedPlanModeID(
                availableModeIDs: availableModeIDs,
                advertisedPlanModeID: opened.planModeId
            )
            mapper.setCurrentModeId(opened.currentModeId)
            mapper.setPlanReviewModeId(planModeID)
            let seededEffort = DistillACPClient.seededReasoningEffort(
                models: opened.models,
                currentModelId: opened.currentModelId,
                currentEffortRaw: opened.currentReasoningEffortRaw
            )
            let advertisedEfforts = opened.advertisedReasoningEffortIds.compactMap(
                AgentReasoningEffort.init(rawValue:)
            )
            let session = Session(
                threadId: request.threadId,
                providerThreadId: opened.sessionId,
                client: client,
                cwd: cwd,
                guestPlan: guestPlan,
                capabilities: capabilities,
                mapper: mapper,
                model: opened.currentModelId ?? request.model,
                mainModelSelection: request.model.trimmingCharacters(in: .whitespacesAndNewlines) == "auto"
                    ? "auto" : opened.appliedMainModelId,
                reasoningEffort: request.model.trimmingCharacters(in: .whitespacesAndNewlines) == "auto"
                    ? (opened.appliedMainEffortSelection?.effort ?? seededEffort) : seededEffort,
                mainEffortSelection: opened.appliedMainEffortSelection,
                reasoningModel: capabilities.sessionWorkerModel && request.model.trimmingCharacters(in: .whitespacesAndNewlines) != "auto"
                    ? request.reasoningModel : nil,
                reasoningModelEffortSelection: opened.appliedReasoningModelEffortSelection,
                advertisesReasoningEffortConfig: opened.advertisesReasoningEffortConfig,
                advertisedEfforts: advertisedEfforts,
                modelEfforts: Dictionary(
                    opened.models.map { ($0.id, $0.supportedReasoningEfforts) },
                    uniquingKeysWith: { first, _ in first }
                ),
                advertisedEffortsModelId: opened.currentModelId,
                availableModeIDs: availableModeIDs,
                planModeID: planModeID,
                mode: opened.currentModeId,
                maxReadableEvents: maxReadableEvents,
                maxReadableBytes: maxReadableBytes,
                onEvent: onEvent
            )
            if loadExisting { session.executionMode = nil }
            session.holdsThreadStartedUntilPromptAccepted = freshSession != nil
            client.notificationHandler = { [weak self, weak session] method, params in
                guard let self, let session else { return }
                self.handleNotification(method: method, params: params, session: session)
            }
            client.serverRequestHandler = { [weak self, weak session] id, method, params in
                guard let self, let session else { throw AgentProviderAdapterError.unsupported("Distill ACP adapter released") }
                return try await self.handleServerRequest(id: id, method: method, params: params, session: session)
            }
            client.terminationHandler = { [weak self, weak session] reason, status, error in
                guard let self, let session else { return }
                self.handleTermination(session: session, reason: reason, status: status, error: error)
            }
            let replaced = synchronized { () -> Session? in
                if let seeded = pendingSeedLoops.removeValue(forKey: request.threadId), session.ledger.loops.isEmpty {
                    session.ledger = DistillLoopLedger(loops: seeded)
                }
                let replaced = sessions.updateValue(session, forKey: request.threadId)
                if let replaced {
                    replaced.isLive = false
                    replaced.promptWritePermit.invalidate()
                }
                return replaced
            }
            replaced?.client.stop()
            // session/load replays the full prior conversation as ordinary
            // session/update notifications (no reliable wire flag on every build).
            //
            // Contract: history is a *pull*
            // (`readThread`), never a push of historical tools into a live run.
            //
            // - load + prompt (sendTurn after process death): hydrate mapper
            //   state only — do not publish timeline items under the new bubble.
            // - load, no prompt (recoverSession): record replay into
            //   session.history for readThread, still no live onEvent push.
            // - session/new: publish pre-prompt notifications normally.
            // Then seal so beginTurn always mints a fresh user-facing turn.
            let loadNotifications = bufferedNotifications.drain()
            if loadExisting {
                for (method, params) in loadNotifications {
                    if shouldStartPrompt {
                        hydrateNotification(method: method, params: params, session: session)
                    } else {
                        recordHydratedTimeline(method: method, params: params, session: session)
                    }
                }
                // Silent/record paths discard mapper-emitted threadStarted; publish
                // identity once so resume-cursor persistence stays deterministic.
                emit(
                    .threadStarted(threadId: session.providerThreadId, providerThreadId: session.providerThreadId),
                    session: session
                )
            } else {
                for (method, params) in loadNotifications {
                    handleNotification(method: method, params: params, session: session)
                }
            }
            session.mapper.sealHydration()
            if shouldStartPrompt {
                try await startPrompt(request, session: session, onEvent: onEvent, freshSession: freshSession)
            } else {
                session.status = .completed
            }
            return handle(for: request.runId, session: session)
        } catch {
            synchronized {
                if sessions[request.threadId]?.client === client {
                    sessions.removeValue(forKey: request.threadId)
                }
            }
            guestPlan?.finish(.failed)
            client.stop()
            if error is AgentProviderAdapterError || error is AgentRunAcceptanceError { throw error }
            throw DistillACPFailureTaxonomy.normalize(
                error,
                context: loadExisting ? .resume : .start
            )
        }
    }

    private func startPrompt(
        _ request: AgentRunRequest,
        session: Session,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void,
        freshSession: FreshSessionSeed? = nil
    ) async throws {
        let promptGeneration: UInt64 = try synchronized {
            guard sessions[request.threadId] === session, session.isLive else {
                throw AgentProviderAdapterError.sessionNotFound(request.threadId)
            }
            guard !session.inFlight else {
                throw AgentProviderAdapterError.unsupported("Distill ACP session already has an in-flight prompt")
            }
            session.inFlight = true
            session.promptAccepted = false
            session.promptWritePermit = AgentRunAcceptancePermit()
            session.cancelRequested = false
            session.forcedKillByUs = false
            session.turnTerminalEmitted = false
            session.turnWatchdogSynthesisInProgress = false
            session.forceKillWorkItem?.cancel()
            session.forceKillWorkItem = nil
            session.promptGeneration &+= 1
            session.lastEventAt = Date()
            session.promptFailureDetail = nil
            session.onEvent = onEvent
            cancelTurnWatchdogLocked(session: session)
            return session.promptGeneration
        }

        do {
            let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let reasoningModel = request.reasoningModel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedReasoningModel = reasoningModel?.isEmpty == true ? nil : reasoningModel
            let currentModel = synchronized { session.model }
            let currentMainModelSelection = synchronized { session.mainModelSelection }
            let currentReasoningModel = synchronized { session.reasoningModel }
            let currentReasoningEffortSelection = synchronized { session.reasoningModelEffortSelection }
            let requestedMainEffort = request.distillMainEffortSelection.map(\.effort) ?? request.reasoningEffort
            let requestedReasoningEffortSelection = request.distillReasoningEffortSelection
                ?? (currentReasoningModel == normalizedReasoningModel
                    ? currentReasoningEffortSelection
                    : .automatic)
                ?? .automatic
            let reasoningEffortChanged = normalizedReasoningModel != nil
                && currentReasoningEffortSelection != requestedReasoningEffortSelection
            let reasoningModelChanged = model != "auto" && session.capabilities.sessionWorkerModel
                && (currentReasoningModel != normalizedReasoningModel || reasoningEffortChanged)
            let confirmedCurrentMainModel = currentMainModelSelection ?? currentModel
            let mainModelChanged = !model.isEmpty && model != confirmedCurrentMainModel
            let mainEffortNeedsBind = request.distillMainEffortSelection != nil
                && (mainModelChanged || request.distillMainEffortSelection != session.mainEffortSelection)
            let crossedSwap = reasoningModelChanged
                && mainModelChanged
                && normalizedReasoningModel == confirmedCurrentMainModel
                && model == currentReasoningModel
            if crossedSwap {
                let applied = try await session.client.setReasoningModel(
                    sessionId: session.providerThreadId,
                    modelId: nil,
                    effortSelection: .automatic
                )
                synchronized {
                    session.reasoningModel = applied.modelId
                    session.reasoningModelEffortSelection = .automatic
                }
            }
            // Distill rejects Reasoning equal to active Main, so crossed pairs briefly clear Reasoning.
            let reasoningMustFollowMainChange = reasoningModelChanged
                && normalizedReasoningModel == confirmedCurrentMainModel
                && mainModelChanged
            if reasoningModelChanged && !crossedSwap && !reasoningMustFollowMainChange {
                let applied = try await session.client.setReasoningModel(
                    sessionId: session.providerThreadId,
                    modelId: normalizedReasoningModel,
                    effortSelection: requestedReasoningEffortSelection,
                    advertisedEfforts: session.catalogEfforts(for: normalizedReasoningModel)
                )
                let appliedEffortSelection: AgentEffortSelection
                if normalizedReasoningModel == nil || applied.isAutomatic {
                    appliedEffortSelection = .automatic
                } else if let effort = applied.effort {
                    appliedEffortSelection = .fixed(effort)
                } else {
                    throw AgentProviderAdapterError.unsupported(
                        "Distill did not return the applied Worker-model effort"
                    )
                }
                synchronized {
                    session.reasoningModel = applied.modelId
                    session.reasoningModelEffortSelection = appliedEffortSelection
                }
            }
            if model == "auto" {
                // First let Distill select the route, then validate its concrete catalog's effort.
                if mainModelChanged {
                    let applied = try await session.client.setModel(sessionId: session.providerThreadId, modelId: "auto")
                    guard applied.canonicalModelId == "auto" else {
                        throw AgentProviderAdapterError.unsupported("Distill did not confirm Auto routing; prompt was not sent")
                    }
                    synchronized {
                        session.model = applied.activeModelId
                        session.mainModelSelection = "auto"
                        session.reasoningEffort = applied.effort
                        session.mainEffortSelection = nil
                    }
                }
                let selection = request.distillMainEffortSelection ?? requestedMainEffort.map { AgentEffortSelection.fixed($0) }
                if let selection, selection != synchronized({ session.mainEffortSelection }) {
                    let applied = try await session.client.setModel(
                        sessionId: session.providerThreadId, modelId: "auto",
                        reasoningEffort: selection.effort, reasoningEffortAuto: selection.isAutomatic,
                        advertisedEfforts: session.catalogEfforts(for: synchronized { session.model })
                    )
                    guard applied.canonicalModelId == "auto", applied.isAutomatic == selection.isAutomatic,
                          selection.effort == nil || applied.effort == selection.effort else {
                        throw AgentProviderAdapterError.unsupported("Distill did not confirm Auto Main effort; prompt was not sent")
                    }
                    synchronized {
                        session.model = applied.activeModelId
                        session.mainModelSelection = "auto"
                        session.reasoningEffort = applied.effort
                        session.mainEffortSelection = selection
                    }
                }
            } else if request.distillMainEffortSelection == nil {
                switch DistillACPClient.modelEffortBind(
                    requestModel: request.model,
                    sessionModel: session.model,
                    requestEffort: requestedMainEffort,
                    sessionEffort: session.reasoningEffort,
                    prefersConfigOptionEffort: session.advertisesReasoningEffortConfig,
                    advertisedEfforts: session.advertisedEfforts
                ) {
                case .none:
                    break
                case let .setConfigOption(configId, value, effort):
                    try await session.client.setConfigOption(
                        sessionId: session.providerThreadId,
                        configId: configId,
                        value: value
                    )
                    synchronized { session.reasoningEffort = effort }
                case let .setModel(modelId, reasoningEffort):
                    let applied = try await session.client.setModel(
                        sessionId: session.providerThreadId,
                        modelId: modelId,
                        reasoningEffort: reasoningEffort,
                        advertisedEfforts: session.catalogEfforts(for: modelId)
                    )
                    synchronized {
                        session.model = applied.activeModelId
                        session.mainModelSelection = applied.canonicalModelId
                        session.reasoningEffort = applied.effort
                    }
                }
            } else if mainEffortNeedsBind,
                      let mainEffortSelection = request.distillMainEffortSelection {
                let modelForEffort = request.model.isEmpty
                    ? (synchronized { session.mainModelSelection } ?? session.model)
                    : request.model
                let applied = try await session.client.setModel(
                    sessionId: session.providerThreadId,
                    modelId: modelForEffort,
                    reasoningEffort: mainEffortSelection.effort,
                    reasoningEffortAuto: mainEffortSelection.isAutomatic,
                    advertisedEfforts: session.catalogEfforts(for: modelForEffort)
                )
                guard applied.canonicalModelId == modelForEffort,
                      applied.canonicalModelId != normalizedReasoningModel,
                      applied.isAutomatic == mainEffortSelection.isAutomatic,
                      mainEffortSelection.effort == nil || applied.effort == mainEffortSelection.effort else {
                    throw AgentProviderAdapterError.unsupported(
                        "Distill did not confirm the requested Main model and effort; prompt was not sent"
                    )
                }
                synchronized {
                    session.model = applied.activeModelId
                    session.mainModelSelection = applied.canonicalModelId
                    session.reasoningEffort = applied.effort
                    session.mainEffortSelection = mainEffortSelection
                }
            }
            if reasoningMustFollowMainChange {
                let applied = try await session.client.setReasoningModel(
                    sessionId: session.providerThreadId,
                    modelId: normalizedReasoningModel,
                    effortSelection: requestedReasoningEffortSelection,
                    advertisedEfforts: session.catalogEfforts(for: normalizedReasoningModel)
                )
                let appliedEffortSelection: AgentEffortSelection
                if normalizedReasoningModel == nil || applied.isAutomatic {
                    appliedEffortSelection = .automatic
                } else if let effort = applied.effort {
                    appliedEffortSelection = .fixed(effort)
                } else {
                    throw AgentProviderAdapterError.unsupported(
                        "Distill did not return the applied Worker-model effort"
                    )
                }
                synchronized {
                    session.reasoningModel = applied.modelId
                    session.reasoningModelEffortSelection = appliedEffortSelection
                }
            }
            let wantedMode = request.distillExecutionMode
            if wantedMode != synchronized({ session.executionMode }) {
                do {
                    let applied = try await session.client.setExecutionMode(
                        sessionId: session.providerThreadId,
                        mode: wantedMode
                    )
                    synchronized { session.executionMode = applied }
                } catch DistillACPError.rpcError(let code, let message, _, _) where wantedMode == .auto && code == -32602 {
                    // Distill <= 2.0.54 rejects "auto"; reset a previously set mode to Normal, then record Auto so later turns do not retry.
                    distillAcpLog.info("Distill peer rejected Auto execution mode: \(message, privacy: .public)")
                    do {
                        try await session.client.setExecutionMode(sessionId: session.providerThreadId, mode: .normal)
                    } catch {
                        distillAcpLog.info("Distill peer could not reset to Normal after rejecting Auto: \(error.localizedDescription, privacy: .public)")
                    }
                    synchronized { session.executionMode = wantedMode }
                } catch DistillACPError.rpcError(let code, let message, _, _) where code == -32601 {
                    // Older Distill only knows the Ultracode flag; Ultrafast and Ultrasave cannot be applied there.
                    distillAcpLog.info("Distill peer lacks execution_mode/set: \(message, privacy: .public)")
                    guard wantedMode == .auto || wantedMode == .normal || wantedMode == .ultracode else {
                        throw DistillACPError.unsupported("Update Distill to use \(wantedMode.displayName) mode; prompt was not sent.")
                    }
                    do {
                        try await session.client.setUltracode(
                            sessionId: session.providerThreadId,
                            enabled: wantedMode == .ultracode
                        )
                        synchronized { session.executionMode = wantedMode }
                    } catch DistillACPError.rpcError(let legacyCode, _, _, _) where legacyCode == -32601 {
                        throw DistillACPError.unsupported("Update Distill to confirm \(wantedMode.displayName) mode; prompt was not sent.")
                    }
                }
            }
            let requestedMode: String?
            if request.interactionMode == .plan {
                guard let planModeID = session.planModeID else {
                    throw AgentProviderAdapterError.unsupported("Distill ACP did not advertise Plan mode for this session")
                }
                requestedMode = planModeID
            } else {
                requestedMode = try Self.resolvedPermissionModeID(
                    for: request.permissionMode,
                    availableModeIDs: session.availableModeIDs
                )
            }
            if let requestedMode, requestedMode != session.mode {
                try await session.client.setMode(sessionId: session.providerThreadId, modeId: requestedMode)
                synchronized {
                    session.mode = requestedMode
                    // Keep mapper mode in sync even when the peer omits current_mode_update.
                    session.mapper.setCurrentModeId(requestedMode)
                }
            }
            let acceptance = PromptAcceptanceGate()
            beforePromptWriteForTesting?()
            try synchronized {
                guard sessions[request.threadId] === session, session.isLive else {
                    throw AgentProviderAdapterError.sessionNotFound(request.threadId)
                }
            }
            try await withCheckedThrowingContinuation { continuation in
                acceptance.install(continuation)
                Task { [weak self, weak session] in
                    guard let self, let session else {
                        acceptance.settle(.failure(AgentProviderAdapterError.sessionNotFound(request.threadId)))
                        return
                    }
                    do {
                        let response = try await session.client.prompt(
                            sessionId: session.providerThreadId,
                            request: request,
                            capabilities: session.capabilities,
                            writePermit: session.promptWritePermit,
                            contextHandoff: freshSession?.handoff,
                            beforeWrite: { [weak self] in
                                self?.beforePhysicalPromptWriteForTesting?()
                                try self?.validateAutoRouting(request)
                            },
                            onAccepted: { [weak self, weak session] in
                                guard let self, let session else {
                                    throw AgentProviderAdapterError.sessionNotFound(request.threadId)
                                }
                                let (releaseThreadStarted, reportModel) = try self.synchronized {
                                    guard self.sessions[request.threadId] === session,
                                          session.isLive else {
                                        throw AgentProviderAdapterError.sessionNotFound(request.threadId)
                                    }
                                    session.promptAccepted = true
                                    session.status = .running
                                    self.promptWriteAcceptanceCountForTestingStorage += 1
                                    let release = session.heldThreadStarted
                                    session.holdsThreadStartedUntilPromptAccepted = false
                                    session.heldThreadStarted = false
                                    let requestedModel = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let model = requestedModel == "auto" ? session.model : requestedModel
                                    let report = !model.isEmpty && session.reportedAcceptedModel != model
                                    if report { session.reportedAcceptedModel = model }
                                    return (release, report ? model : nil)
                                }
                                if releaseThreadStarted {
                                    self.emit(
                                        .threadStarted(threadId: session.providerThreadId, providerThreadId: session.providerThreadId),
                                        session: session
                                    )
                                }
                                for event in session.mapper.beginTurn() {
                                    self.emit(event, session: session)
                                }
                                if let reportModel {
                                    self.emit(Self.sessionStateEvent([
                                        "sessionId": session.providerThreadId,
                                        "acceptedModel": reportModel
                                    ]), session: session)
                                }
                                if let notice = freshSession?.notice {
                                    self.emitFreshSessionNotice(notice, session: session)
                                }
                                onEvent(.status(.running))
                                self.refreshTurnWatchdog(session: session, generation: promptGeneration)
                                acceptance.settle(.success(()))
                            }
                        )
                        self.clearAbandonedOpenTools(session: session, generation: promptGeneration)
                        self.handlePromptResponse(response, session: session, generation: promptGeneration)
                    } catch {
                        self.clearAbandonedOpenTools(session: session, generation: promptGeneration)
                        acceptance.settle(.failure(error))
                        self.finishTransportFailure(session: session, error: error, forced: false)
                    }
                }
            }
            afterPromptWriteForTesting?()
        } catch {
            synchronized {
                if session.promptGeneration == promptGeneration {
                    session.inFlight = false
                    cancelTurnWatchdogLocked(session: session)
                }
            }
            if error is AgentProviderAdapterError { throw error }
            throw DistillACPFailureTaxonomy.normalize(error, context: .turn)
        }
    }

    private func handleNotification(method: String, params: Any?, session: Session) {
        if method == DistillACPClient.operationMethod {
            emit(Self.runtimeEvent(method: method, payload: params as? [String: Any] ?? [:]), session: session)
            return
        }
        foldLoops(method: method, params: params, session: session)
        if routeWakeNotification(method: method, params: params, session: session) { return }
        guard method == "session/update",
              let params = params as? [String: Any],
              params["sessionId"] as? String == session.providerThreadId,
              let update = params["update"] as? [String: Any] else {
            // Live grok-build emits `x.ai/*`; legacy/replay may use `_x.ai/*`.
            // Leader may nest live method under underscore envelope `{method,params}`.
            if Self.isDistillExtNotificationMethod(method) {
                let (resolvedMethod, resolvedPayload) = Self.unwrapDistillExtNotification(
                    method: method,
                    params: params
                )
                if let failure = ACPRPCErrorPayload.promptCompleteFailure(
                    method: resolvedMethod,
                    payload: resolvedPayload,
                    sessionId: session.providerThreadId
                ) {
                    synchronized { session.promptFailureDetail = (session.promptGeneration, failure) }
                }
                emit(Self.runtimeEvent(method: resolvedMethod, payload: resolvedPayload), session: session)
            }
            return
        }
        for event in session.mapper.consumeSessionUpdate(update) { emit(event, session: session) }
    }

    private func foldLoops(method: String, params: Any?, session: Session) {
        guard Self.isDistillExtNotificationMethod(method) else { return }
        let (resolvedMethod, resolvedParams) = Self.unwrapDistillExtNotification(method: method, params: params)
        guard let dict = resolvedParams as? [String: Any],
              dict["sessionId"] as? String == session.providerThreadId else { return }
        let changed: (loops: [DistillLoopState], callback: (@Sendable (AgentThreadID, [DistillLoopState]) -> Void)?)? = synchronized {
            let next = DistillLoopReducer.apply(method: resolvedMethod, params: dict, to: session.ledger)
            let loopsChanged = next.loops != session.ledger.loops
            session.ledger = next
            return loopsChanged ? (next.loops, onLoopsChangedStorage) : nil
        }
        if let changed { changed.callback?(session.threadId, changed.loops) }
    }

    /// The process is being killed for a stuck cancel: its scheduler dies with it, so loops
    /// pause with a visible reason instead of staying "active" on a dead session.
    private func pauseLoopsForStoppedSession(session: Session) {
        let changed: (loops: [DistillLoopState], callback: (@Sendable (AgentThreadID, [DistillLoopState]) -> Void)?)? = synchronized {
            var loops = session.ledger.loops
            var touched = false
            for index in loops.indices where loops[index].state == .active || loops[index].state == .paused {
                loops[index].state = .paused
                loops[index].pausedReason = Self.stoppedSessionPausedReason
                loops[index].nextFireAt = nil
                touched = true
            }
            guard touched else { return nil }
            session.ledger.loops = loops
            return (loops, onLoopsChangedStorage)
        }
        if let changed { changed.callback?(session.threadId, changed.loops) }
    }

    public static let stoppedSessionPausedReason = "Agent session stopped; resume to continue"

    /// Parent-session wake turns (agent-initiated, no `session/prompt`). Returns true when consumed.
    private func routeWakeNotification(method: String, params: Any?, session: Session) -> Bool {
        let (resolvedMethod, resolvedParams) = Self.isDistillExtNotificationMethod(method)
            ? Self.unwrapDistillExtNotification(method: method, params: params)
            : (method, params)
        guard let dict = resolvedParams as? [String: Any],
              dict["sessionId"] as? String == session.providerThreadId,
              let update = dict["update"] as? [String: Any] else { return false }
        if resolvedMethod == "session/update" {
            guard let promptId = (dict["_meta"] as? [String: Any])?["promptId"] as? String,
                  DistillLoopReducer.isWakePromptID(promptId) != nil else { return false }
            var dropped: [(promptId: String, reason: String)] = []
            let consumed: Bool = synchronized {
                if session.attachedPromptId == promptId {
                    guard session.attachReplaying else { return false }
                    session.replayBuffer.append(update)
                    return true
                }
                if session.handledWake.contains(promptId) { return true }
                if session.pendingWake[promptId] == nil {
                    while session.pendingWakeOrder.count >= Self.maxPendingWakePrompts,
                          let oldest = session.pendingWakeOrder.first(where: { !session.wakeNotified.contains($0) }) {
                        dropPendingWakeLocked(session: session, promptId: oldest)
                        dropped.append((oldest, "pending wake limit \(Self.maxPendingWakePrompts)"))
                    }
                    session.pendingWakeOrder.append(promptId)
                }
                while session.pendingWake.values.reduce(0, { $0 + $1.count }) >= Self.maxBufferedWakeUpdates {
                    guard let oldest = session.pendingWakeOrder.first(where: { $0 != promptId && !session.wakeNotified.contains($0) }) else {
                        dropped.append((promptId, "buffered update limit \(Self.maxBufferedWakeUpdates)"))
                        return true
                    }
                    dropPendingWakeLocked(session: session, promptId: oldest)
                    dropped.append((oldest, "buffered update limit \(Self.maxBufferedWakeUpdates)"))
                }
                session.pendingWake[promptId, default: []].append(update)
                return true
            }
            for drop in dropped { reportWakeDropped(session: session, promptId: drop.promptId, reason: drop.reason) }
            if consumed { notifyPendingWake(session: session) }
            return consumed
        }
        let name = resolvedMethod.hasPrefix("_") ? String(resolvedMethod.dropFirst()) : resolvedMethod
        guard name == "x.ai/session_notification",
              update["sessionUpdate"] as? String == "turn_completed",
              let promptId = update["prompt_id"] as? String,
              DistillLoopReducer.isWakePromptID(promptId) != nil else { return false }
        let stopReason = update["stop_reason"] as? String ?? "end_turn"
        let usage = update["usage"] as? [String: Any]
        let attached: Bool? = synchronized {
            if let abandoned = session.abandonedWake, abandoned.promptId == promptId {
                session.abandonedWake = nil
                if session.abandonedOpenToolsGeneration == abandoned.generation {
                    session.abandonedOpenToolsGeneration = nil
                }
                return false
            }
            if session.attachedPromptId == promptId {
                if session.attachReplaying {
                    session.replayTerminal = (stopReason, usage)
                    return false
                }
                return true
            }
            if session.pendingWake[promptId] != nil {
                session.completedWake[promptId] = (stopReason, usage)
                return false
            }
            return nil
        }
        guard let attached else { return false }
        if attached { completeWakeTurn(session: session, stopReason: stopReason, usage: usage) }
        return true
    }

    private static let maxBufferedWakeUpdates = 20_000
    private static let maxPendingWakePrompts = 8

    private func dropPendingWakeLocked(session: Session, promptId: String) {
        session.pendingWake.removeValue(forKey: promptId)
        session.pendingWakeOrder.removeAll { $0 == promptId }
        session.completedWake.removeValue(forKey: promptId)
        session.wakeFailed.remove(promptId)
        session.handledWake.insert(promptId)
    }

    /// Never silent: a dropped wake loses a loop iteration's output.
    private func reportWakeDropped(session: Session, promptId: String, reason: String) {
        distillAcpLog.error(
            "distill.loop.wake.dropped thread=\(session.threadId.value.uuidString, privacy: .public) prompt=\(promptId, privacy: .public) reason=\(reason, privacy: .public)"
        )
        let event = Self.runtimeEvent(
            method: "distill.loop.wake.dropped",
            payload: ["sessionId": session.providerThreadId, "promptId": promptId, "reason": reason]
        )
        let inTurn = synchronized { session.inFlight && !session.turnTerminalEmitted }
        if inTurn {
            emit(event, session: session)
        } else {
            synchronized { session.history.append(event) }
        }
    }

    /// The host could not adopt `promptId`: release the announcement so other wakes are not
    /// blocked. The failed wake is retried after the next turn ends.
    public func acknowledgeWakeFailed(threadId: AgentThreadID, promptId: String) {
        let session: Session? = synchronized {
            guard let session = sessions[threadId], session.wakeNotified.remove(promptId) != nil else { return nil }
            if session.pendingWake[promptId] != nil {
                session.wakeFailed.insert(promptId)
                session.pendingWakeOrder.removeAll { $0 == promptId }
                session.pendingWakeOrder.append(promptId)
            }
            return session
        }
        if let session { notifyPendingWake(session: session) }
    }

    private func completeWakeTurn(session: Session, stopReason: String, usage: [String: Any]?) {
        let current = synchronized { session.inFlight && !session.turnTerminalEmitted }
        guard current else { return }
        for event in session.mapper.finishTurn(stopReason: stopReason, usage: usage) { emit(event, session: session) }
        let status = DistillACPTerminalClassifier.status(stopReason: stopReason)
        if status == .failed {
            session.onEvent?(.error(DistillACPFailureTaxonomy.normalize(
                diagnostic: "Distill ACP stopped: \(stopReason)",
                context: .turn
            ).message))
        }
        finishTurn(session: session, status: status)
    }

    /// Announces the next buffered wake turn once no turn is in flight and none awaits adoption.
    private func notifyPendingWake(session: Session) {
        let announcement: (callback: @Sendable (AgentThreadID, String, String) -> Void, promptId: String, label: String)? = synchronized {
            guard let callback = onProviderInitiatedTurnStorage,
                  session.isLive, !session.inFlight, session.wakeNotified.isEmpty,
                  let promptId = session.pendingWakeOrder.first(where: {
                      !session.wakeNotified.contains($0) && !session.wakeFailed.contains($0)
                  }) else { return nil }
            session.wakeNotified.insert(promptId)
            let subagentId = DistillLoopReducer.isWakePromptID(promptId)
            let loop = session.loops.first { $0.lastIteration?.subagentID == subagentId }
            let label = loop.map { "Loop · \($0.humanSchedule) · iteration \($0.iterations)" } ?? "Loop iteration"
            return (callback, promptId, label)
        }
        if let announcement { announcement.callback(session.threadId, announcement.promptId, announcement.label) }
    }

    /// Adopts a buffered wake turn as this run: same bookkeeping as `startPrompt`, no `session/prompt`.
    private func attachWakeTurn(
        _ request: AgentRunRequest,
        promptId: String,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) throws -> AgentRunHandle {
        let adopted: (session: Session, updates: [[String: Any]], generation: UInt64, completed: (stopReason: String, usage: [String: Any]?)?) = try synchronized {
            guard let session = sessions[request.threadId], session.isLive else {
                throw AgentProviderAdapterError.sessionNotFound(request.threadId)
            }
            guard !session.inFlight else {
                throw AgentProviderAdapterError.unsupported("Distill ACP session already has an in-flight prompt")
            }
            guard let updates = session.pendingWake.removeValue(forKey: promptId) else {
                throw AgentProviderAdapterError.unsupported("Distill loop turn is no longer pending")
            }
            session.pendingWakeOrder.removeAll { $0 == promptId }
            session.wakeNotified.remove(promptId)
            session.wakeFailed.remove(promptId)
            session.handledWake.insert(promptId)
            let completed = session.completedWake.removeValue(forKey: promptId)
            session.inFlight = true
            session.promptAccepted = true
            session.status = .running
            session.cancelRequested = false
            session.forcedKillByUs = false
            session.turnTerminalEmitted = false
            session.turnWatchdogSynthesisInProgress = false
            session.forceKillWorkItem?.cancel()
            session.forceKillWorkItem = nil
            session.promptGeneration &+= 1
            session.lastEventAt = Date()
            session.promptFailureDetail = nil
            session.attachedPromptId = promptId
            session.attachReplaying = true
            session.replayBuffer = []
            session.replayTerminal = nil
            session.onEvent = onEvent
            cancelTurnWatchdogLocked(session: session)
            return (session, updates, session.promptGeneration, completed)
        }
        let session = adopted.session
        beforeAttachReplayForTesting?()
        for event in session.mapper.beginTurn() { emit(event, session: session) }
        onEvent(.status(.running))
        refreshTurnWatchdog(session: session, generation: adopted.generation)
        // Live updates for this prompt queue while we replay; drain in arrival order, then
        // flip live and finish with the terminal that arrived first (buffered or deferred).
        var batch = adopted.updates
        var terminal = adopted.completed
        while true {
            for update in batch {
                for event in session.mapper.consumeSessionUpdate(update) { emit(event, session: session) }
            }
            let next: (updates: [[String: Any]], terminal: (stopReason: String, usage: [String: Any]?)?) = synchronized {
                if session.replayBuffer.isEmpty {
                    session.attachReplaying = false
                    let deferred = session.replayTerminal
                    session.replayTerminal = nil
                    return ([], deferred)
                }
                let updates = session.replayBuffer
                session.replayBuffer = []
                return (updates, nil)
            }
            batch = next.updates
            if batch.isEmpty {
                terminal = terminal ?? next.terminal
                break
            }
        }
        if let terminal {
            completeWakeTurn(session: session, stopReason: terminal.stopReason, usage: terminal.usage)
        }
        return handle(for: request.runId, session: session)
    }

    public func loops(threadId: AgentThreadID) -> [DistillLoopState] {
        synchronized { sessions[threadId]?.loops ?? [] }
    }

    /// Restores persisted loops so a restarted session keeps iteration history. No-op when the
    /// session already has loops; applied at session creation when none exists yet.
    public func seedLoops(threadId: AgentThreadID, loops: [DistillLoopState]) {
        guard !loops.isEmpty else { return }
        synchronized {
            if let session = sessions[threadId] {
                if session.ledger.loops.isEmpty { session.ledger = DistillLoopLedger(loops: loops) }
            } else {
                pendingSeedLoops[threadId] = loops
            }
        }
    }

    public func threadIdsWithActiveLoops() -> Set<AgentThreadID> {
        synchronized {
            Set(sessions.values.filter { $0.isLive && $0.loops.contains { $0.state == .active } }.map(\.threadId))
        }
    }

    /// Deletes the scheduled task; the `scheduled_task_deleted` notification updates loop state.
    public func stopLoop(threadId: AgentThreadID, taskId: String) async throws -> Bool {
        guard let session = synchronized({ sessions[threadId] }), synchronized({ session.isLive }) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        return try await session.client.schedulerDelete(sessionId: session.providerThreadId, taskId: taskId)
    }

    /// Live (`x.ai/…`) and legacy (`_x.ai/…`) distill ACP extension notifications.
    private static func isDistillExtNotificationMethod(_ method: String) -> Bool {
        method.hasPrefix("x.ai/") || method.hasPrefix("_x.ai/")
    }

    /// Unwrap leader nested form: outer `_x.ai/…` with params `{ method, params }`.
    private static func unwrapDistillExtNotification(
        method: String,
        params: Any?
    ) -> (method: String, params: Any?) {
        guard let dict = params as? [String: Any],
              let nestedMethod = dict["method"] as? String,
              isDistillExtNotificationMethod(nestedMethod),
              dict.keys.contains("params") else {
            return (method, params)
        }
        return (nestedMethod, dict["params"])
    }

    /// Apply load-time `session/update` to mapper session state only.
    /// Does not publish timeline events onto the follow-up run's onEvent path.
    private func hydrateNotification(method: String, params: Any?, session: Session) {
        foldLoops(method: method, params: params, session: session)
        guard method == "session/update",
              let params = params as? [String: Any],
              params["sessionId"] as? String == session.providerThreadId,
              let update = params["update"] as? [String: Any] else {
            // Load-time `_x.ai/*` subagent rows are dropped here intentionally:
            // they already exist in durable history and must not re-enter a run.
            return
        }
        // Discard timeline events; mode/commands/usage still land on the mapper.
        _ = session.mapper.consumeSessionUpdate(update)
        if update["sessionUpdate"] as? String == "current_mode_update",
           let modeId = update["currentModeId"] as? String {
            session.mode = modeId
        }
    }

    /// `session/load` replay for recoverSession: keep history for `readThread`
    /// without pushing into the live `onEvent` path (avoids durable stream
    /// pollution / wire re-rendering of historical text).
    private func recordHydratedTimeline(method: String, params: Any?, session: Session) {
        foldLoops(method: method, params: params, session: session)
        guard method == "session/update",
              let params = params as? [String: Any],
              params["sessionId"] as? String == session.providerThreadId,
              let update = params["update"] as? [String: Any] else {
            return
        }
        let events = session.mapper.consumeSessionUpdate(update)
        if update["sessionUpdate"] as? String == "current_mode_update",
           let modeId = update["currentModeId"] as? String {
            session.mode = modeId
        }
        guard !events.isEmpty else { return }
        lock.lock()
        session.history.append(contentsOf: events)
        lock.unlock()
    }

    private func handleServerRequest(
        id: DistillACPRequestID,
        method: String,
        params: Any?,
        session: Session
    ) async throws -> Any? {
        guard method == "session/request_permission" else {
            throw AgentProviderAdapterError.unsupported("Unhandled Distill ACP request: \(method)")
        }
        let request = try DistillACPPermissionRequest.parse(id: id, params: params)
        guard request.sessionId == session.providerThreadId else {
            throw AgentProviderAdapterError.unsupported("Distill ACP permission session mismatch")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let key = id.stringValue
            let turnId = synchronized { () -> String? in
                session.pendingPermissions[key] = PendingPermission(request: request, continuation: continuation)
                return session.mapper.activeTurnId
            }
            emit(.requestOpened(AssistantPendingRequest(
                id: key,
                turnId: turnId,
                kind: .dynamic,
                title: request.title,
                detail: request.detail,
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                supportsSessionApproval: request.options.contains { $0.kind == "allow_always" }
            )), session: session)
        }
    }

    private func handlePromptResponse(
        _ response: [String: Any],
        session: Session,
        generation: UInt64
    ) {
        // Drop a stale result for a previous prompt after the inactivity
        // watchdog already released the turn (or a follow-up started).
        let stillCurrent = synchronized {
            session.promptGeneration == generation && !session.turnTerminalEmitted
        }
        guard stillCurrent else {
            distillAcpLog.info(
                "grok.turn.prompt_result.stale thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
            )
            return
        }
        let stopReason = response["stopReason"] as? String ?? "failed"
        let metadata = response["_meta"] as? [String: Any]
        let usage = metadata?["usage"] as? [String: Any]
        for event in session.mapper.finishTurn(stopReason: stopReason, usage: usage) { emit(event, session: session) }
        let status = DistillACPTerminalClassifier.status(stopReason: stopReason)
        if status == .failed {
            let detail = currentPromptFailureDetail(session: session).map { ": \($0)" } ?? ""
            let failure = DistillACPFailureTaxonomy.normalize(
                diagnostic: "Distill ACP stopped: \(stopReason)\(detail)",
                context: .turn
            )
            retireSessionIfHistoryIncompatible(failure, session: session)
            session.onEvent?(.error(failure.message))
        }
        finishTurn(session: session, status: status)
    }

    private func handleTermination(
        session: Session,
        reason: Process.TerminationReason,
        status: Int32,
        error: Error
    ) {
        lock.lock()
        let generation = session.promptGeneration
        let current = sessions[session.threadId] === session
        let active = current
            && session.inFlight
            && session.promptAccepted
            && !session.turnTerminalEmitted
        let forced = session.forcedKillByUs
        let cancelled = session.cancelRequested
        if current {
            sessions.removeValue(forKey: session.threadId)
        }
        session.isLive = false
        session.promptWritePermit.invalidate()
        session.forceKillWorkItem?.cancel()
        session.forceKillWorkItem = nil
        lock.unlock()
        guard active else {
            distillAcpLog.info(
                "grok.turn.termination.stale thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
            )
            // No-op when the turn or Stop already finished the run.
            session.guestPlan?.finish(.failed)
            return
        }
        let terminal = DistillACPTerminalClassifier.status(
            promptResolved: false,
            cancelRequested: cancelled,
            forcedKillByUs: forced,
            terminationReason: reason,
            exitStatus: status
        )
        if terminal == .failed {
            let failure = DistillACPFailureTaxonomy.normalize(error, context: .turn)
            let guestWasKilled = session.guestPlan != nil && !cancelled && !forced
                && (reason == .uncaughtSignal || (128...255).contains(status))
            let message = guestWasKilled
                ? "\(TransientNetworkRetry.guestProcessMarker) \(failure.message)"
                : failure.message
            session.onEvent?(.error(message))
        }
        for event in session.mapper.finishTurn(stopReason: terminal == .cancelled ? "cancelled" : "failed", usage: nil) {
            emit(event, session: session)
        }
        finishTurn(session: session, status: terminal)
    }

    private func finishTransportFailure(session: Session, error: Error, forced: Bool) {
        if forced { lock.lock(); session.forcedKillByUs = true; lock.unlock() }
        lock.lock()
        let terminal = session.cancelRequested && session.forcedKillByUs ? AgentRunStatus.cancelled : .failed
        let active = session.inFlight && session.promptAccepted && !session.turnTerminalEmitted
        lock.unlock()
        guard active else { return }
        if terminal == .failed {
            let failure = DistillACPFailureTaxonomy.normalize(
                Self.addingPromptFailureDetail(currentPromptFailureDetail(session: session), to: error),
                context: .turn
            )
            retireSessionIfHistoryIncompatible(failure, session: session)
            session.onEvent?(.error(failure.message))
        }
        for event in session.mapper.finishTurn(stopReason: terminal == .cancelled ? "cancelled" : "failed", usage: nil) {
            emit(event, session: session)
        }
        finishTurn(session: session, status: terminal)
    }

    /// `prompt_complete` failure text captured for the turn now in flight.
    private func currentPromptFailureDetail(session: Session) -> String? {
        synchronized {
            guard let captured = session.promptFailureDetail,
                  captured.generation == session.promptGeneration else { return nil }
            return captured.text
        }
    }

    /// A bare "Internal error" RPC failure borrows the provider text Distill
    /// already sent as `prompt_complete.agentResult` for the same prompt.
    static func addingPromptFailureDetail(_ detail: String?, to error: Error) -> Error {
        guard let detail,
              case let DistillACPError.rpcError(code, message, existing, httpStatus) = error,
              existing == nil else { return error }
        return DistillACPError.rpcError(code: code, message: message, detail: detail, httpStatus: httpStatus)
    }

    private func retireSessionIfHistoryIncompatible(_ failure: DistillACPFailure, session: Session) {
        guard failure.category == .incompatibleHistory else { return }
        synchronized {
            session.historyIncompatible = true
            retiredProviderThreadIds.insert(session.providerThreadId)
        }
        // Persisted by the coordinator, so Retry after a restart still opens a
        // new session instead of loading this one into the same 400.
        emit(Self.sessionStateEvent([
            "sessionId": session.providerThreadId,
            "historyRejected": true
        ]), session: session)
        distillAcpLog.info(
            "distill.session.retired thread=\(session.threadId.value.uuidString, privacy: .public) reason=incompatible_history"
        )
    }

    /// Visible transcript row for a replacement session (Agent App, bot desk
    /// and the iOS mirror all render the persisted item). `.contextCompaction`
    /// is the closest item type both decoders know (a new case would fail the
    /// iOS mirror's decode); the row's copy says what happened. No
    /// `.contextCompaction(summary:)` event: the context meter and the iOS
    /// compaction signal must not report a provider-side compaction.
    private func emitFreshSessionNotice(_ notice: String, session: Session) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let itemId = "distill-fresh-session-\(session.providerThreadId)"
        let turnId = session.mapper.activeTurnId ?? ""
        emit(.itemStarted(item: AssistantItem(
            id: itemId,
            turnId: turnId,
            type: .contextCompaction,
            state: .completed,
            summary: notice,
            body: notice,
            startedAtMs: now,
            finishedAtMs: now
        )), session: session)
        emit(.itemCompleted(itemId: itemId, finalState: .completed), session: session)
    }

    private static func sessionStateEvent(_ state: [String: Any]) -> AssistantEvent {
        let data = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data()
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .distill,
            source: "remotecode.distill",
            method: ProviderRuntimeEvent.distillSessionStateMethod,
            payloadJSON: String(data: data, encoding: .utf8) ?? "{}",
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    private func finishTurn(session: Session, status: AgentRunStatus) {
        lock.lock()
        guard sessions[session.threadId] === session || !session.isLive else {
            lock.unlock()
            return
        }
        guard !session.turnTerminalEmitted else { lock.unlock(); return }
        session.turnTerminalEmitted = true
        session.turnWatchdogSynthesisInProgress = false
        session.inFlight = false
        session.attachedPromptId = nil
        session.attachReplaying = false
        session.replayBuffer = []
        session.replayTerminal = nil
        session.wakeFailed.removeAll()
        session.status = status
        // A guest run ends with its turn: no idle guest process keeps the
        // bot's credentials. The next turn loads the session in a new one.
        // A live /loop keeps the process (and the guest) alive between turns.
        // A cancel ends the turn only; the force-kill path (isLive == false) already paused them.
        let keepsLoopsAlive = session.isLive && session.loops.contains { $0.state == .active || $0.state == .paused }
        let endsGuestRun = session.guestPlan != nil && !keepsLoopsAlive
        let stopRequested = status == .cancelled && session.cancelRequested && !keepsLoopsAlive
        let shouldStopOwnedTree = stopRequested || endsGuestRun
        if shouldStopOwnedTree {
            if sessions[session.threadId] === session {
                sessions.removeValue(forKey: session.threadId)
            }
            session.isLive = false
            session.promptWritePermit.invalidate()
        }
        session.forceKillWorkItem?.cancel()
        session.forceKillWorkItem = nil
        cancelTurnWatchdogLocked(session: session)
        let callback = session.onEvent
        let final = session.mapper.finalAssistantMessage
        let providerThreadId = session.providerThreadId
        let pending = Array(session.pendingPermissions.values)
        session.pendingPermissions.removeAll()
        lock.unlock()
        for request in pending {
            request.continuation.resume(throwing: AgentProviderAdapterError.unsupported("Distill ACP turn ended before permission response"))
        }
        // Started before the client stops, so this status (not the docker
        // client's exit) is the run's; teardown runs in the background under
        // the bot's lease, and the callbacks below are not delayed by it.
        // A turn that ended on its own closes stdin and lets Distill exit
        // first: a TERM right after the turn skips the session shutdown that
        // flushes what the next turn's `session/load` replays. Stop kills now.
        let gracefulGuestEnd = endsGuestRun && !stopRequested
        if gracefulGuestEnd, let guestPlan = session.guestPlan {
            let client = session.client
            let runID = guestPlan.runID
            guestPlan.finish(status, exitGracefully: {
                let exited = await client.closeInputAndWaitForExit(
                    timeout: DistillGuestLaunchPlan.gracefulExitTimeout
                )
                if !exited {
                    distillAcpLog.error(
                        "distill.guest.graceful_exit.timeout run=\(runID, privacy: .public)"
                    )
                }
                client.stop()
            })
        } else if !keepsLoopsAlive {
            session.guestPlan?.finish(status)
        }
        if shouldStopOwnedTree {
            distillAcpLog.info(
                "distill.cancel.ack.tree_stop thread=\(session.threadId.value.uuidString, privacy: .public) guest=\(endsGuestRun, privacy: .public)"
            )
            if !gracefulGuestEnd { session.client.stop() }
        }
        callback?(.status(status))
        callback?(.finished(status, finalMessage: final, providerThreadId: providerThreadId))
        notifyPendingWake(session: session)
    }

    /// (Re)arm the in-flight turn inactivity bound. No-op when the turn is no
    /// longer open. Stream/tool events fully reset the deadline so long-running
    /// goals stay live for as long as the provider keeps producing activity.
    private func refreshTurnWatchdog(session: Session, generation: UInt64) {
        // Negotiated providers are supervised by operation evidence and live ACP probes.
        guard !session.client.supportsOperationStatus else { return }
        lock.lock()
        guard sessions[session.threadId] === session,
              session.isLive,
              session.inFlight,
              session.promptAccepted,
              !session.turnTerminalEmitted,
              !session.turnWatchdogSynthesisInProgress,
              session.promptGeneration == generation else {
            lock.unlock()
            return
        }
        if session.turnWatchdog == nil {
            session.turnWatchdog = ACPTurnInactivityDeadline(timeout: turnInactivityTimeout) { [weak self, weak session] in
                guard let self, let session else { return }
                self.fireTurnInactivityWatchdog(session: session, generation: generation)
            }
            turnWatchdogTimersScheduledForTestingStorage += 1
        }
        session.turnWatchdog?.refresh()
        lock.unlock()
    }

    private func cancelTurnWatchdogLocked(session: Session) {
        session.turnWatchdog?.cancel()
        session.turnWatchdog = nil
    }

    /// Legacy providers without operation evidence have a bounded inactivity failure.
    /// A partial answer is never evidence that session/prompt completed.
    private func fireTurnInactivityWatchdog(session: Session, generation: UInt64) {
        lock.lock()
        guard sessions[session.threadId] === session,
              session.isLive,
              session.inFlight,
              session.promptAccepted,
              !session.turnTerminalEmitted,
              !session.turnWatchdogSynthesisInProgress,
              session.promptGeneration == generation else {
            lock.unlock()
            return
        }
        // Open tool call and recent activity: a blocking tool wait is healthy, so keep the turn open.
        if session.mapper.hasOpenToolCalls,
           session.client.runningProcess.isRunning,
           Date().timeIntervalSince(session.lastEventAt) < openToolQuietLimit {
            session.turnWatchdog?.refresh()
            lock.unlock()
            distillAcpLog.info("grok.turn.watchdog.extended_open_tool thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)")
            return
        }
        // Claim synthesis before any emit. emit re-arms the watchdog; without
        // this flag that re-arm can re-enter fire and overflow the GCD worker
        // stack (crash: RemoteCode.SQLiteDB stack guard via EventBus).
        session.turnWatchdogSynthesisInProgress = true
        cancelTurnWatchdogLocked(session: session)
        lock.unlock()
        // Silence cannot prove success, even when a partial answer was streamed.
        let hasOpenTools = session.mapper.hasOpenToolCalls
        if hasOpenTools {
            synchronized {
                session.abandonedOpenToolsGeneration = generation
                if let promptId = session.attachedPromptId {
                    session.abandonedWake = (promptId, generation)
                }
            }
        }
        let hasFinal = session.mapper.hasSpeakableFinalContent
        let status: AgentRunStatus
        let stopReason: String
        if hasOpenTools {
            status = .interrupted
            stopReason = "interrupted"
        } else {
            status = .failed
            stopReason = "failed"
        }
        distillAcpLog.info(
            "grok.turn.watchdog.synthesized thread=\(session.threadId.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) generation=\(generation, privacy: .public) openTools=\(hasOpenTools, privacy: .public)"
        )
        // Distinct runtime marker so field forensics can separate inferred
        // terminals from real session/prompt stopReason frames.
        emit(
            Self.runtimeEvent(
                method: "grok.turn.watchdog.synthesized",
                payload: [
                    "sessionId": session.providerThreadId,
                    "status": status.rawValue,
                    "stopReason": stopReason,
                    "hasSpeakableFinalContent": hasFinal,
                    "hasOpenToolCalls": hasOpenTools
                ]
            ),
            session: session
        )
        for event in session.mapper.finishTurn(stopReason: stopReason, usage: nil) {
            emit(event, session: session)
        }
        if status == .failed || status == .interrupted {
            session.onEvent?(.error(DistillACPFailureTaxonomy.normalize(
                diagnostic: hasOpenTools
                    ? "Distill ACP turn inactivity watchdog: open tool_call with no further events (session/prompt never returned)"
                    : "Distill ACP turn inactivity watchdog synthesized terminal (session/prompt never returned)",
                context: .turn
            ).message))
        }
        finishTurn(session: session, status: status)
    }

    private func emit(_ event: AssistantEvent, session: Session) {
        lock.lock()
        // Drop late ACP noise after the turn terminal was published. Post-finish
        // events were re-entering the coordinator with a cleared seq counter and
        // colliding on durable seq 1 (servers_updated vs turnStarted).
        if session.turnTerminalEmitted {
            lock.unlock()
            return
        }
        if session.holdsThreadStartedUntilPromptAccepted, case .threadStarted = event {
            session.heldThreadStarted = true
            lock.unlock()
            return
        }
        session.history.append(event)
        session.lastEventAt = Date()
        let generation = session.promptGeneration
        // Do not re-arm while the watchdog is synthesizing a terminal: that path
        // is what previously re-entered fireTurnInactivityWatchdog from emit.
        let shouldArmWatchdog = session.inFlight
            && session.promptAccepted
            && !session.turnWatchdogSynthesisInProgress
        let callback = session.onEvent
        lock.unlock()
        callback?(.event(event))
        if shouldArmWatchdog {
            refreshTurnWatchdog(session: session, generation: generation)
        }
    }

    private func handle(for runId: AgentRunID, session: Session) -> AgentRunHandle {
        AgentRunHandle(runId: runId, process: session.client.runningProcess) { [weak self, weak session] in
            guard let self, let session else { return }
            try? self.interruptTurn(threadId: session.threadId)
        }
    }

    /// CLI/ACP wire values accepted by the harness (`--permission-mode` / session/set_mode).
    static let defaultPermissionModes: [AgentPermissionMode] = AgentPermissionMode.allCases

    private static func mode(for permission: AgentPermissionMode) -> String {
        switch permission {
        case .supervised: return "default"
        case .autoAcceptEdits: return "acceptEdits"
        case .fullAccess: return "bypassPermissions"
        }
    }

    /// Map advertised ACP mode IDs to RemoteCode permission modes.
    /// Empty advertisement means the known CLI set is usable.
    static func permissionModes(from availableModeIDs: Set<String>) -> [AgentPermissionMode] {
        if availableModeIDs.isEmpty {
            return defaultPermissionModes
        }
        var modes: [AgentPermissionMode] = [.supervised]
        if availableModeIDs.contains(mode(for: .autoAcceptEdits)) {
            modes.append(.autoAcceptEdits)
        }
        if availableModeIDs.contains(mode(for: .fullAccess)) {
            modes.append(.fullAccess)
        }
        return modes
    }

    /// Map advertised ACP mode IDs to interaction modes.
    /// Empty advertisement: Plan is open via wire id `plan`.
    /// When modes are advertised without plan, stay fail-closed.
    static func interactionModes(
        availableModeIDs: Set<String>,
        advertisedPlanModeID: String?
    ) -> [AgentInteractionMode] {
        if availableModeIDs.isEmpty {
            return [.default, .plan]
        }
        return advertisedPlanModeID != nil ? [.default, .plan] : [.default]
    }

    /// Wire mode id for Plan when the session omits availableModes.
    static let emptyCatalogPlanModeID = "plan"

    /// Resolve Plan mode to an ACP mode ID for session/set_mode.
    /// Empty catalog → known wire `"plan"`. Advertised without plan → nil (fail-closed).
    static func resolvedPlanModeID(
        availableModeIDs: Set<String>,
        advertisedPlanModeID: String?
    ) -> String? {
        if availableModeIDs.isEmpty {
            return emptyCatalogPlanModeID
        }
        return advertisedPlanModeID
    }

    /// Resolve a permission mode to an ACP mode ID for session/set_mode.
    /// When the session omits availableModes, still apply the known wire ID —
    /// the harness accepts set_mode without advertising the catalog.
    static func resolvedPermissionModeID(
        for permission: AgentPermissionMode,
        availableModeIDs: Set<String>
    ) throws -> String? {
        let wireID = mode(for: permission)
        if availableModeIDs.isEmpty {
            return wireID
        }
        if availableModeIDs.contains(wireID) {
            return wireID
        }
        if permission == .supervised {
            return nil
        }
        throw AgentProviderAdapterError.unsupported(
            "Distill ACP did not advertise the \(permission.rawValue) permission mode for this session"
        )
    }

    private static func runtimeEvent(method: String, payload: Any?) -> AssistantEvent {
        let object = payload as? [String: Any] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .distill,
            source: "grok.acp",
            method: method,
            payloadJSON: String(data: data, encoding: .utf8) ?? "{}",
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    /// The abandoned prompt returned (or failed): its tools are no longer running.
    private func clearAbandonedOpenTools(session: Session, generation: UInt64) {
        synchronized {
            if session.abandonedOpenToolsGeneration == generation {
                session.abandonedOpenToolsGeneration = nil
            }
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
